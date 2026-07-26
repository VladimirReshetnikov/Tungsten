if(NOT DEFINED TUNGSTEN_BUILD_DIR
    OR NOT DEFINED TUNGSTEN_CONSUMER_SOURCE_DIR
    OR NOT DEFINED TUNGSTEN_CONSUMER_BUILD_DIR
    OR NOT DEFINED TUNGSTEN_INSTALL_PREFIX)
    message(FATAL_ERROR "Installed-consumer test paths were not provided")
endif()

file(REMOVE_RECURSE
    "${TUNGSTEN_CONSUMER_BUILD_DIR}"
    "${TUNGSTEN_INSTALL_PREFIX}")

set(install_command
    "${CMAKE_COMMAND}" --install "${TUNGSTEN_BUILD_DIR}"
    --prefix "${TUNGSTEN_INSTALL_PREFIX}")
if(DEFINED TUNGSTEN_CONFIG AND NOT TUNGSTEN_CONFIG STREQUAL "")
    list(APPEND install_command --config "${TUNGSTEN_CONFIG}")
endif()
execute_process(
    COMMAND ${install_command}
    RESULT_VARIABLE install_result
    OUTPUT_VARIABLE install_output
    ERROR_VARIABLE install_error)
if(NOT install_result EQUAL 0)
    message(FATAL_ERROR
        "Tungsten staged install failed (${install_result})\n${install_output}\n${install_error}")
endif()

set(configure_command
    "${CMAKE_COMMAND}"
    -S "${TUNGSTEN_CONSUMER_SOURCE_DIR}"
    -B "${TUNGSTEN_CONSUMER_BUILD_DIR}"
    "-DCMAKE_PREFIX_PATH=${TUNGSTEN_INSTALL_PREFIX}"
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF)
if(DEFINED TUNGSTEN_CXX_COMPILER AND NOT TUNGSTEN_CXX_COMPILER STREQUAL "")
    list(APPEND configure_command "-DCMAKE_CXX_COMPILER=${TUNGSTEN_CXX_COMPILER}")
endif()
execute_process(
    COMMAND ${configure_command}
    RESULT_VARIABLE configure_result
    OUTPUT_VARIABLE configure_output
    ERROR_VARIABLE configure_error)
if(NOT configure_result EQUAL 0)
    message(FATAL_ERROR
        "Installed consumer configure failed (${configure_result})\n${configure_output}\n${configure_error}")
endif()

set(build_command "${CMAKE_COMMAND}" --build "${TUNGSTEN_CONSUMER_BUILD_DIR}")
if(DEFINED TUNGSTEN_CONFIG AND NOT TUNGSTEN_CONFIG STREQUAL "")
    list(APPEND build_command --config "${TUNGSTEN_CONFIG}")
endif()
execute_process(
    COMMAND ${build_command}
    RESULT_VARIABLE build_result
    OUTPUT_VARIABLE build_output
    ERROR_VARIABLE build_error)
if(NOT build_result EQUAL 0)
    message(FATAL_ERROR
        "Installed consumer build failed (${build_result})\n${build_output}\n${build_error}")
endif()

set(test_command
    "${CMAKE_CTEST_COMMAND}"
    --test-dir "${TUNGSTEN_CONSUMER_BUILD_DIR}"
    --output-on-failure)
if(DEFINED TUNGSTEN_CONFIG AND NOT TUNGSTEN_CONFIG STREQUAL "")
    list(APPEND test_command -C "${TUNGSTEN_CONFIG}")
endif()
execute_process(
    COMMAND ${test_command}
    RESULT_VARIABLE test_result
    OUTPUT_VARIABLE test_output
    ERROR_VARIABLE test_error)
if(NOT test_result EQUAL 0)
    message(FATAL_ERROR
        "Installed consumer execution failed (${test_result})\n${test_output}\n${test_error}")
endif()
