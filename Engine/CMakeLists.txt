cmake_minimum_required(VERSION 3.20)

project(TungstenEngine VERSION 0.1.0 LANGUAGES CXX)

include(GNUInstallDirs)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# A single-config generator otherwise has no configuration when users follow
# the portable `--config Release` build/install commands.  Giving an initially
# unset tree a real Release configuration keeps the generated export fragment
# and the installed archive in the same configuration.  Explicit Debug or
# other user-selected configurations remain untouched.
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(
        CMAKE_BUILD_TYPE Release CACHE STRING
        "Choose the type of build (Debug, Release, RelWithDebInfo, or MinSizeRel)"
        FORCE)
    set_property(
        CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
        Debug Release RelWithDebInfo MinSizeRel)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(MSVC)
    add_compile_options(/utf-8)
endif()

find_package(GMP REQUIRED)
find_package(Threads REQUIRED)

if(UNIX)
    include(CheckCXXSymbolExists)
    set(_TUNGSTEN_SAVED_REQUIRED_DEFINITIONS "${CMAKE_REQUIRED_DEFINITIONS}")
    list(APPEND CMAKE_REQUIRED_DEFINITIONS -D_GNU_SOURCE)
    check_cxx_symbol_exists(
        posix_spawn_file_actions_addclosefrom_np
        "spawn.h"
        TUNGSTEN_HAVE_POSIX_SPAWN_CLOSEFROM)
    set(CMAKE_REQUIRED_DEFINITIONS "${_TUNGSTEN_SAVED_REQUIRED_DEFINITIONS}")
    unset(_TUNGSTEN_SAVED_REQUIRED_DEFINITIONS)
endif()

# Keep the warning policy build-local: installed consumers inherit the language
# level required by the public headers, but not Tungsten's warning choices.
add_library(tungsten_project_warnings INTERFACE)
if(MSVC)
    target_compile_options(
        tungsten_project_warnings INTERFACE /W4 /permissive-)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "^(AppleClang|Clang|GNU)$")
    target_compile_options(
        tungsten_project_warnings INTERFACE -Wall -Wextra -Wpedantic)
endif()

function(tungsten_enable_project_warnings target)
    target_link_libraries(
        ${target} PRIVATE $<BUILD_INTERFACE:tungsten_project_warnings>)
endfunction()

file(READ
    "${CMAKE_CURRENT_SOURCE_DIR}/src/tungsten/data/system_symbols_wolfram_15_0.json"
    TUNGSTEN_SYSTEM_SYMBOLS_JSON)
file(READ
    "${CMAKE_CURRENT_SOURCE_DIR}/src/tungsten/data/wolfram_named_characters_15_0.json"
    TUNGSTEN_NAMED_CHARACTERS_JSON)

# Keep every generated string token comfortably below the implementation
# limits imposed by MSVC and the minimum guaranteed by the C++ standard. The
# split is made only at line boundaries, so UTF-8 code points remain intact;
# the generated runtime join preserves the original bytes exactly.
function(tungsten_raw_literal_chunks input_variable delimiter output_variable)
    set(remaining "${${input_variable}}")
    set(output "")
    while(NOT "${remaining}" STREQUAL "")
        string(LENGTH "${remaining}" remaining_length)
        if(remaining_length LESS_EQUAL 15000)
            set(line "${remaining}")
            set(remaining "")
        else()
            string(SUBSTRING "${remaining}" 15000 -1 tail)
            string(FIND "${tail}" "\n" newline_index)
            if(newline_index EQUAL -1 OR newline_index GREATER 1000)
                message(FATAL_ERROR
                    "Embedded JSON contains a line too long to split into portable C++ literals")
            endif()
            math(EXPR line_length "15000 + ${newline_index} + 1")
            string(SUBSTRING "${remaining}" 0 ${line_length} line)
            string(SUBSTRING "${remaining}" ${line_length} -1 remaining)
        endif()
        string(APPEND output "R\"${delimiter}(${line})${delimiter}\",\n")
    endwhile()
    set(${output_variable} "${output}" PARENT_SCOPE)
endfunction()

tungsten_raw_literal_chunks(
    TUNGSTEN_SYSTEM_SYMBOLS_JSON TUNGSTEN_SYS
    TUNGSTEN_SYSTEM_SYMBOLS_CPP_LITERAL)
tungsten_raw_literal_chunks(
    TUNGSTEN_NAMED_CHARACTERS_JSON TUNGSTEN_NAM
    TUNGSTEN_NAMED_CHARACTERS_CPP_LITERAL)
configure_file(
    cpp/src/bundled_data.cpp.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated/bundled_data.cpp"
    @ONLY)

add_library(tungsten_cpp STATIC
    "${CMAKE_CURRENT_BINARY_DIR}/generated/bundled_data.cpp"
    cpp/src/assistant.cpp
    cpp/src/discovery.cpp
    cpp/src/docs_index.cpp
    cpp/src/evaluator.cpp
    cpp/src/expression.cpp
    cpp/src/format.cpp
    cpp/src/frontend.cpp
    cpp/src/inline_boxes.cpp
    cpp/src/json.cpp
    cpp/src/kernel.cpp
    cpp/src/licensing.cpp
    cpp/src/named_characters.cpp
    cpp/src/notebook.cpp
    cpp/src/parser.cpp
    cpp/src/parser_corpus.cpp
    cpp/src/repl.cpp
    cpp/src/unicode.cpp
    cpp/src/wolfram_strings.cpp
    cpp/src/wolfram_processes.cpp
)
# GCC 11.4 takes roughly 14.5 minutes and 1.25 GiB to compile this large
# translation unit at -O3, while an otherwise identical -O2 compile takes
# 378 seconds.  Keep the mitigation source-, compiler-, and config-specific;
# RelWithDebInfo is already -O2, and Clang/MSVC retain their normal policy.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set_property(
        SOURCE cpp/src/evaluator.cpp APPEND PROPERTY
        COMPILE_OPTIONS "$<$<CONFIG:Release>:-O2>")
endif()
set_target_properties(
    tungsten_cpp PROPERTIES
        EXPORT_NAME Engine
        POSITION_INDEPENDENT_CODE ON)
target_compile_features(tungsten_cpp PUBLIC cxx_std_17)
if(TUNGSTEN_HAVE_POSIX_SPAWN_CLOSEFROM)
    target_compile_definitions(
        tungsten_cpp PRIVATE
            _GNU_SOURCE
            TUNGSTEN_HAVE_POSIX_SPAWN_CLOSEFROM=1)
endif()
target_include_directories(tungsten_cpp
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/cpp/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)
target_link_libraries(
    tungsten_cpp PUBLIC
        GMP::gmpxx
        GMP::gmp
        ${CMAKE_DL_LIBS}
        Threads::Threads)
tungsten_enable_project_warnings(tungsten_cpp)

add_executable(tungsten-cpp cpp/src/main.cpp)
target_link_libraries(tungsten-cpp PRIVATE tungsten_cpp)
tungsten_enable_project_warnings(tungsten-cpp)
add_library(Tungsten::Engine ALIAS tungsten_cpp)

include(CTest)
if(BUILD_TESTING)
    add_executable(tungsten_cpp_tests cpp/tests/expression_tests.cpp)
    target_link_libraries(tungsten_cpp_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_cpp_tests)
    add_test(NAME tungsten_cpp_tests COMMAND tungsten_cpp_tests)

    add_executable(tungsten_evaluator_api_tests
        cpp/tests/evaluator_api_tests.cpp)
    target_link_libraries(tungsten_evaluator_api_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_evaluator_api_tests)
    add_test(
        NAME tungsten_evaluator_api_tests
        COMMAND tungsten_evaluator_api_tests)

    add_executable(tungsten_combinator_state_tests
        cpp/tests/combinator_state_tests.cpp)
    target_link_libraries(tungsten_combinator_state_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_combinator_state_tests)
    add_test(
        NAME tungsten_combinator_state_tests
        COMMAND tungsten_combinator_state_tests)

    add_executable(
        tungsten_expression_model_tests
        cpp/tests/expression_model_tests.cpp)
    target_link_libraries(
        tungsten_expression_model_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_expression_model_tests)
    add_test(
        NAME tungsten_expression_model_tests
        COMMAND tungsten_expression_model_tests)

    add_executable(tungsten_json_tests cpp/tests/json_tests.cpp)
    target_link_libraries(tungsten_json_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_json_tests)
    add_test(NAME tungsten_json_tests COMMAND tungsten_json_tests)

    add_executable(tungsten_bundled_data_tests
        cpp/tests/bundled_data_tests.cpp)
    target_link_libraries(tungsten_bundled_data_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_bundled_data_tests)
    add_test(
        NAME tungsten_bundled_data_tests
        COMMAND tungsten_bundled_data_tests)

    add_executable(tungsten_runtime_foundation_tests
        cpp/tests/runtime_foundation_tests.cpp)
    target_link_libraries(tungsten_runtime_foundation_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_runtime_foundation_tests)
    add_test(
        NAME tungsten_runtime_foundation_tests
        COMMAND tungsten_runtime_foundation_tests)

    add_executable(tungsten_wolfram_strings_tests
        cpp/tests/wolfram_strings_tests.cpp)
    target_link_libraries(tungsten_wolfram_strings_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_wolfram_strings_tests)
    add_test(
        NAME tungsten_wolfram_strings_tests
        COMMAND tungsten_wolfram_strings_tests)

    add_executable(tungsten_notebook_tests cpp/tests/notebook_tests.cpp)
    target_link_libraries(tungsten_notebook_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_notebook_tests)
    add_test(NAME tungsten_notebook_tests COMMAND tungsten_notebook_tests)

    add_executable(tungsten_inline_boxes_tests cpp/tests/inline_boxes_tests.cpp)
    target_link_libraries(tungsten_inline_boxes_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_inline_boxes_tests)
    add_test(NAME tungsten_inline_boxes_tests COMMAND tungsten_inline_boxes_tests)

    add_executable(tungsten_wolfram_processes_tests
        cpp/tests/wolfram_processes_tests.cpp)
    target_link_libraries(tungsten_wolfram_processes_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_wolfram_processes_tests)
    add_test(
        NAME tungsten_wolfram_processes_tests
        COMMAND tungsten_wolfram_processes_tests)

    add_executable(tungsten_kernel_tests cpp/tests/kernel_tests.cpp)
    target_link_libraries(tungsten_kernel_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_kernel_tests)
    add_test(NAME tungsten_kernel_tests COMMAND tungsten_kernel_tests)

    add_executable(tungsten_repl_tests cpp/tests/repl_tests.cpp)
    target_link_libraries(tungsten_repl_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_repl_tests)
    add_test(NAME tungsten_repl_tests COMMAND tungsten_repl_tests)

    add_executable(tungsten_docs_index_tests cpp/tests/docs_index_tests.cpp)
    target_link_libraries(tungsten_docs_index_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_docs_index_tests)
    add_test(NAME tungsten_docs_index_tests COMMAND tungsten_docs_index_tests)

    add_executable(tungsten_frontend_tests cpp/tests/frontend_tests.cpp)
    target_link_libraries(tungsten_frontend_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_frontend_tests)
    add_test(NAME tungsten_frontend_tests COMMAND tungsten_frontend_tests)

    add_executable(tungsten_parser_corpus_tests
        cpp/tests/parser_corpus_tests.cpp)
    target_link_libraries(tungsten_parser_corpus_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_parser_corpus_tests)
    add_test(
        NAME tungsten_parser_corpus_tests
        COMMAND tungsten_parser_corpus_tests)

    add_executable(tungsten_assistant_tests cpp/tests/assistant_tests.cpp)
    target_link_libraries(tungsten_assistant_tests PRIVATE tungsten_cpp)
    tungsten_enable_project_warnings(tungsten_assistant_tests)
    add_test(NAME tungsten_assistant_tests COMMAND tungsten_assistant_tests)

    add_test(
        NAME tungsten_cli_smoke
        COMMAND
            ${CMAKE_COMMAND}
            -DCLI=$<TARGET_FILE:tungsten-cpp>
            -DSMOKE_ROOT=${CMAKE_CURRENT_BINARY_DIR}/tungsten-cli-smoke
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cpp/tests/cli_smoke.cmake)
    set_tests_properties(tungsten_cli_smoke PROPERTIES TIMEOUT 30)

    add_test(
        NAME tungsten_installed_consumer
        COMMAND
            ${CMAKE_COMMAND}
            -DTUNGSTEN_BUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}
            -DTUNGSTEN_CONSUMER_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/cpp/tests/installed_consumer
            -DTUNGSTEN_CONSUMER_BUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}/installed-consumer-build
            -DTUNGSTEN_INSTALL_PREFIX=${CMAKE_CURRENT_BINARY_DIR}/installed-consumer-prefix
            -DTUNGSTEN_CXX_COMPILER=${CMAKE_CXX_COMPILER}
            -DTUNGSTEN_CONFIG=$<CONFIG>
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cpp/tests/installed_consumer.cmake)
    set_tests_properties(
        tungsten_installed_consumer PROPERTIES RUN_SERIAL TRUE TIMEOUT 180)
endif()

install(
    TARGETS tungsten_cpp tungsten-cpp
    EXPORT TungstenEngineTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(
    DIRECTORY cpp/include/tungsten
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
    FILES_MATCHING PATTERN "*.hpp")
install(
    EXPORT TungstenEngineTargets
    FILE TungstenEngineTargets.cmake
    NAMESPACE Tungsten::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/TungstenEngine)

include(CMakePackageConfigHelpers)
configure_package_config_file(
    cmake/TungstenEngineConfig.cmake.in
    "${CMAKE_CURRENT_BINARY_DIR}/TungstenEngineConfig.cmake"
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/TungstenEngine)
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/TungstenEngineConfigVersion.cmake"
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion)
install(
    FILES
        "${CMAKE_CURRENT_BINARY_DIR}/TungstenEngineConfig.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/TungstenEngineConfigVersion.cmake"
        cmake/FindGMP.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/TungstenEngine)
