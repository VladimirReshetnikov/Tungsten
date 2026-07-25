if(NOT DEFINED CLI OR CLI STREQUAL "")
    message(FATAL_ERROR "CLI executable was not provided")
endif()
if(NOT DEFINED SMOKE_ROOT OR SMOKE_ROOT STREQUAL "")
    message(FATAL_ERROR "CLI smoke root was not provided")
endif()

file(REMOVE_RECURSE "${SMOKE_ROOT}")
file(MAKE_DIRECTORY "${SMOKE_ROOT}")

execute_process(
    COMMAND "${CLI}" expr parse --code "1 + 2 x^3" --form input
    RESULT_VARIABLE expr_status
    OUTPUT_VARIABLE expr_json
    ERROR_VARIABLE expr_error)
if(NOT expr_status EQUAL 0)
    message(FATAL_ERROR "expr parse failed: ${expr_error}")
endif()
string(JSON expr_full_form GET "${expr_json}" full_form)
if(NOT expr_full_form STREQUAL "Plus[1, Times[2, Power[x, 3]]]")
    message(FATAL_ERROR "unexpected expr result: ${expr_full_form}")
endif()

execute_process(
    COMMAND "${CLI}" expr evaluate --code "$Line"
    RESULT_VARIABLE session_line_status
    OUTPUT_VARIABLE session_line_json
    ERROR_VARIABLE session_line_error)
if(NOT session_line_status EQUAL 0)
    message(FATAL_ERROR "session-backed expr evaluation failed: ${session_line_error}")
endif()
string(JSON session_line GET "${session_line_json}" result full_form)
if(NOT session_line STREQUAL "1")
    message(FATAL_ERROR "expr evaluation did not expose session line one")
endif()

execute_process(
    COMMAND "${CLI}" expr evaluate --code "InString[1]"
    RESULT_VARIABLE in_string_status
    OUTPUT_VARIABLE in_string_json
    ERROR_VARIABLE in_string_error)
if(NOT in_string_status EQUAL 0)
    message(FATAL_ERROR "session InString evaluation failed: ${in_string_error}")
endif()
string(JSON in_string_result GET "${in_string_json}" result full_form)
if(NOT in_string_result STREQUAL "\"InString[1]\"")
    message(FATAL_ERROR "expr evaluation did not record its exact source string")
endif()

execute_process(
    COMMAND "${CLI}" expr evaluate --code "DownValues[In]"
    RESULT_VARIABLE in_downvalues_status
    OUTPUT_VARIABLE in_downvalues_json
    ERROR_VARIABLE in_downvalues_error)
if(NOT in_downvalues_status EQUAL 0)
    message(FATAL_ERROR "session DownValues evaluation failed: ${in_downvalues_error}")
endif()
string(JSON in_downvalues_result GET "${in_downvalues_json}" result full_form)
if(NOT in_downvalues_result STREQUAL
    "List[RuleDelayed[HoldPattern[In[1]], DownValues[In]]]")
    message(FATAL_ERROR "expr evaluation did not record its parsed input tree")
endif()

execute_process(
    COMMAND "${CLI}" expr evaluate --code "Exit[x]"
    RESULT_VARIABLE invalid_exit_status
    OUTPUT_VARIABLE invalid_exit_json
    ERROR_VARIABLE invalid_exit_error)
if(NOT invalid_exit_status EQUAL 0)
    message(FATAL_ERROR "invalid Exit was treated as a process exit: ${invalid_exit_error}")
endif()
string(JSON invalid_exit_result GET "${invalid_exit_json}" result full_form)
string(JSON invalid_exit_name GET "${invalid_exit_json}" messages 0 full_name)
string(JSON invalid_exit_text GET "${invalid_exit_json}" messages 0 text)
if(NOT invalid_exit_result STREQUAL "Exit[x]"
    OR NOT invalid_exit_name STREQUAL "MessageName[Exit, \"error\"]"
    OR NOT invalid_exit_text STREQUAL
        "Exit::error: Exit and Quit expect an optional integer exit code.")
    message(FATAL_ERROR "invalid Exit did not remain inert with its exact diagnostic")
endif()

execute_process(
    COMMAND "${CLI}" expr evaluate --code "Exit[7]"
    RESULT_VARIABLE valid_exit_status
    OUTPUT_VARIABLE valid_exit_output
    ERROR_VARIABLE valid_exit_error)
if(NOT valid_exit_status EQUAL 7 OR NOT valid_exit_output STREQUAL ""
    OR NOT valid_exit_error STREQUAL "")
    message(FATAL_ERROR "valid Exit did not return its requested process status")
endif()

execute_process(
    COMMAND "${CLI}" eval --code "10^400 + 1." --input-form
    RESULT_VARIABLE machine_overflow_status
    OUTPUT_VARIABLE machine_overflow_output
    ERROR_VARIABLE machine_overflow_error)
string(STRIP "${machine_overflow_output}" machine_overflow_output)
if(NOT machine_overflow_status EQUAL 0
    OR NOT machine_overflow_output STREQUAL "Overflow[]")
    message(FATAL_ERROR
        "huge exact plus machine real escaped or returned the wrong value: "
        "${machine_overflow_error}${machine_overflow_output}")
endif()

execute_process(
    COMMAND "${CLI}" expr parse --code "f["
    RESULT_VARIABLE expr_error_status
    OUTPUT_VARIABLE expr_error_json
    ERROR_VARIABLE expr_error_stderr)
if(NOT expr_error_status EQUAL 1)
    message(FATAL_ERROR
        "expr syntax failure returned ${expr_error_status}: ${expr_error_stderr}")
endif()
string(JSON expr_error_success GET "${expr_error_json}" success)
string(JSON expr_error_type GET "${expr_error_json}" error_type)
if(expr_error_success OR NOT expr_error_type STREQUAL "WolframSyntaxError")
    message(FATAL_ERROR "unexpected expr syntax failure payload")
endif()

foreach(group IN ITEMS
        env kernel notebook expr parser-corpus docs frontend assistant inline-box)
    execute_process(
        COMMAND "${CLI}" "${group}"
        RESULT_VARIABLE missing_subcommand_status
        OUTPUT_VARIABLE missing_subcommand_output
        ERROR_VARIABLE missing_subcommand_error)
    if(NOT missing_subcommand_status EQUAL 2)
        message(FATAL_ERROR
            "${group} without a subcommand returned ${missing_subcommand_status}; expected 2")
    endif()
endforeach()

execute_process(
    COMMAND "${CLI}" expr parse --code "1+1" --help
    RESULT_VARIABLE nested_help_status
    OUTPUT_VARIABLE nested_help_output
    ERROR_VARIABLE nested_help_error)
if(NOT nested_help_status EQUAL 0)
    message(FATAL_ERROR "expr nested help failed: ${nested_help_error}")
endif()

execute_process(
    COMMAND "${CLI}" expr parse --code "1" --form full
    RESULT_VARIABLE legacy_form_status
    OUTPUT_VARIABLE legacy_form_output
    ERROR_VARIABLE legacy_form_error)
if(NOT legacy_form_status EQUAL 2)
    message(FATAL_ERROR
        "Python-incompatible full form alias returned ${legacy_form_status}")
endif()

execute_process(
    COMMAND "${CLI}" expr parse --file "${SMOKE_ROOT}/missing-expression.wl"
    RESULT_VARIABLE missing_expr_file_status
    OUTPUT_VARIABLE missing_expr_file_output
    ERROR_VARIABLE missing_expr_file_error)
if(NOT missing_expr_file_status EQUAL 1)
    message(FATAL_ERROR
        "missing expression file returned ${missing_expr_file_status}; expected 1")
endif()

set(unicode_expr_file "${SMOKE_ROOT}/β-expression.wl")
file(WRITE "${unicode_expr_file}" "2 + 3\n")
execute_process(
    COMMAND "${CLI}" expr parse --file "${unicode_expr_file}"
    RESULT_VARIABLE unicode_expr_status
    OUTPUT_VARIABLE unicode_expr_json
    ERROR_VARIABLE unicode_expr_error)
if(NOT unicode_expr_status EQUAL 0)
    message(FATAL_ERROR
        "Unicode expression-file path failed: ${unicode_expr_error}")
endif()
string(JSON unicode_expr_full_form GET "${unicode_expr_json}" full_form)
if(NOT unicode_expr_full_form STREQUAL "Plus[2, 3]")
    message(FATAL_ERROR "unexpected Unicode-path expression result")
endif()

set(valid_batch_input "${SMOKE_ROOT}/valid-eval-batch.jsonl")
file(WRITE "${valid_batch_input}" [=["\"\ud83d\ude00\""
]=])
execute_process(
    COMMAND "${CLI}" eval-batch
    INPUT_FILE "${valid_batch_input}"
    RESULT_VARIABLE valid_batch_status
    OUTPUT_VARIABLE valid_batch_json
    ERROR_VARIABLE valid_batch_error)
string(JSON valid_batch_success GET "${valid_batch_json}" success)
if(NOT valid_batch_status EQUAL 0 OR NOT valid_batch_success)
    message(FATAL_ERROR
        "valid surrogate-pair eval-batch input failed: ${valid_batch_error}")
endif()

set(malformed_batch_input "${SMOKE_ROOT}/malformed-eval-batch.jsonl")
file(WRITE "${malformed_batch_input}" [=["\u1x00"
]=])
execute_process(
    COMMAND "${CLI}" eval-batch
    INPUT_FILE "${malformed_batch_input}"
    RESULT_VARIABLE malformed_batch_status
    OUTPUT_VARIABLE malformed_batch_json
    ERROR_VARIABLE malformed_batch_error)
string(JSON malformed_batch_success GET "${malformed_batch_json}" success)
string(JSON malformed_batch_message GET "${malformed_batch_json}" error)
if(NOT malformed_batch_status EQUAL 0 OR malformed_batch_success
    OR NOT malformed_batch_message MATCHES "Unicode escape")
    message(FATAL_ERROR
        "malformed JSON escape bypassed eval-batch validation: "
        "${malformed_batch_error}${malformed_batch_json}")
endif()

execute_process(
    COMMAND "${CLI}" --version
    RESULT_VARIABLE version_status
    OUTPUT_VARIABLE version_output
    ERROR_VARIABLE version_error)
if(NOT version_status EQUAL 0 OR NOT version_output MATCHES "^tungsten-cpp [0-9]+\\.[0-9]+\\.[0-9]+")
    message(FATAL_ERROR "native version action failed: ${version_error}${version_output}")
endif()

set(repl_input "${SMOKE_ROOT}/repl-input.txt")
file(WRITE "${repl_input}" "1 + 1\nQuit[]\n")
execute_process(
    COMMAND "${CLI}" repl --no-banner
    INPUT_FILE "${repl_input}"
    RESULT_VARIABLE repl_status
    OUTPUT_VARIABLE repl_output
    ERROR_VARIABLE repl_error)
if(NOT repl_status EQUAL 0 OR NOT repl_output MATCHES "Out\\[1\\]= 2")
    message(FATAL_ERROR "native REPL transcript failed: ${repl_error}${repl_output}")
endif()

set(corpus_root "${SMOKE_ROOT}/corpus")
file(MAKE_DIRECTORY "${corpus_root}")
file(WRITE "${corpus_root}/expr.wl" "1 + 2\n")
file(WRITE "${corpus_root}/ignored.txt" "not Wolfram\n")
execute_process(
    COMMAND "${CLI}" parser-corpus discover --corpus-root "${corpus_root}"
        --sample 1
    RESULT_VARIABLE corpus_discover_status
    OUTPUT_VARIABLE corpus_discover_json
    ERROR_VARIABLE corpus_discover_error)
if(NOT corpus_discover_status EQUAL 0)
    message(FATAL_ERROR "parser-corpus discover failed: ${corpus_discover_error}")
endif()
string(JSON corpus_count GET "${corpus_discover_json}" file_count)
string(JSON corpus_sample GET "${corpus_discover_json}" sample_files 0 relative_path)
if(NOT corpus_count EQUAL 1 OR NOT corpus_sample STREQUAL "expr.wl")
    message(FATAL_ERROR "unexpected parser-corpus discovery payload")
endif()

execute_process(
    COMMAND "${CLI}" parser-corpus compare --corpus-root "${corpus_root}"
        --skip-wolfram --no-write --include-results
    RESULT_VARIABLE corpus_compare_status
    OUTPUT_VARIABLE corpus_compare_json
    ERROR_VARIABLE corpus_compare_error)
if(NOT corpus_compare_status EQUAL 0)
    message(FATAL_ERROR "parser-corpus compare failed: ${corpus_compare_error}")
endif()
string(JSON corpus_parse_status GET "${corpus_compare_json}" results 0 tungsten status)
string(JSON corpus_wolfram_reason GET "${corpus_compare_json}" results 0 wolfram error_type)
if(NOT corpus_parse_status STREQUAL "success"
    OR NOT corpus_wolfram_reason STREQUAL "WolframComparisonDisabled")
    message(FATAL_ERROR "unexpected parser-corpus comparison payload")
endif()

set(seed_corpus_root "${SMOKE_ROOT}/seed-corpus")
file(MAKE_DIRECTORY "${seed_corpus_root}")
foreach(seed_index RANGE 0 11)
    if(seed_index LESS 10)
        set(seed_name "0${seed_index}.wl")
    else()
        set(seed_name "${seed_index}.wl")
    endif()
    file(WRITE "${seed_corpus_root}/${seed_name}" "1\n")
endforeach()
execute_process(
    COMMAND "${CLI}" parser-corpus discover --corpus-root "${seed_corpus_root}"
        --shuffle --seed -1 --sample 1
    RESULT_VARIABLE negative_seed_status
    OUTPUT_VARIABLE negative_seed_json
    ERROR_VARIABLE negative_seed_error)
if(NOT negative_seed_status EQUAL 0)
    message(FATAL_ERROR "negative parser-corpus seed failed: ${negative_seed_error}")
endif()
string(JSON negative_seed_first GET "${negative_seed_json}" sample_files 0 relative_path)
if(NOT negative_seed_first STREQUAL "07.wl")
    message(FATAL_ERROR "negative parser-corpus seed did not match CPython")
endif()
execute_process(
    COMMAND "${CLI}" parser-corpus discover --corpus-root "${seed_corpus_root}"
        --shuffle --seed 1361129467683753853853498429727072858169 --sample 1
    RESULT_VARIABLE wide_seed_status
    OUTPUT_VARIABLE wide_seed_json
    ERROR_VARIABLE wide_seed_error)
if(NOT wide_seed_status EQUAL 0)
    message(FATAL_ERROR "wide parser-corpus seed failed: ${wide_seed_error}")
endif()
string(JSON wide_seed_first GET "${wide_seed_json}" sample_files 0 relative_path)
if(NOT wide_seed_first STREQUAL "01.wl")
    message(FATAL_ERROR "wide parser-corpus seed did not match CPython")
endif()

set(empty_corpus_root "${SMOKE_ROOT}/empty-corpus")
file(MAKE_DIRECTORY "${empty_corpus_root}")
file(WRITE "${empty_corpus_root}/empty.wl" "")
execute_process(
    COMMAND "${CLI}" parser-corpus compare --corpus-root "${empty_corpus_root}"
        --max-bytes -1 --skip-wolfram --no-write --include-results
    RESULT_VARIABLE negative_bytes_status
    OUTPUT_VARIABLE negative_bytes_json
    ERROR_VARIABLE negative_bytes_error)
if(NOT negative_bytes_status EQUAL 0)
    message(FATAL_ERROR "negative parser-corpus byte limit failed: ${negative_bytes_error}")
endif()
string(JSON negative_bytes_attempt GET "${negative_bytes_json}" results 0 tungsten status)
string(JSON negative_bytes_option GET "${negative_bytes_json}" summary options max_bytes)
if(NOT negative_bytes_attempt STREQUAL "skipped" OR NOT negative_bytes_option EQUAL -1)
    message(FATAL_ERROR "negative byte limit did not preserve Python semantics")
endif()

set(notebook_path "${SMOKE_ROOT}/cli-test.nb")
execute_process(
    COMMAND "${CLI}" notebook create --file "${notebook_path}"
        --title "CLI Notebook" --cell "Text:Hello from the CLI"
    RESULT_VARIABLE create_status
    OUTPUT_VARIABLE create_json
    ERROR_VARIABLE create_error)
if(NOT create_status EQUAL 0)
    message(FATAL_ERROR "notebook create failed: ${create_error}")
endif()
string(JSON create_title GET "${create_json}" title)
string(JSON create_count GET "${create_json}" cell_count)
if(NOT create_title STREQUAL "CLI Notebook" OR NOT create_count EQUAL 1)
    message(FATAL_ERROR "unexpected notebook create payload")
endif()

set(empty_title_notebook "${SMOKE_ROOT}/empty-title.nb")
execute_process(
    COMMAND "${CLI}" notebook create --file "${empty_title_notebook}" --title ""
    RESULT_VARIABLE empty_title_status
    OUTPUT_VARIABLE empty_title_json
    ERROR_VARIABLE empty_title_error)
if(NOT empty_title_status EQUAL 0)
    message(FATAL_ERROR "empty-title notebook create failed: ${empty_title_error}")
endif()
string(JSON empty_title GET "${empty_title_json}" title)
string(JSON empty_title_option_count LENGTH "${empty_title_json}" options)
if(NOT empty_title STREQUAL "empty-title" OR NOT empty_title_option_count EQUAL 0)
    message(FATAL_ERROR "empty notebook title did not preserve Python CLI semantics")
endif()

execute_process(
    COMMAND "${CLI}" notebook inspect --file "${notebook_path}"
    RESULT_VARIABLE inspect_status
    OUTPUT_VARIABLE inspect_json
    ERROR_VARIABLE inspect_error)
if(NOT inspect_status EQUAL 0)
    message(FATAL_ERROR "notebook inspect failed: ${inspect_error}")
endif()
string(JSON inspect_preview GET "${inspect_json}" cells 0 preview)
if(NOT inspect_preview STREQUAL "Hello from the CLI")
    message(FATAL_ERROR "unexpected notebook preview: ${inspect_preview}")
endif()

set(patch_path "${SMOKE_ROOT}/patch.json")
set(patched_path "${SMOKE_ROOT}/patched.nb")
file(WRITE "${patch_path}"
    "{\"operations\":[{\"op\":\"append_cell\",\"style\":\"Input\",\"text\":\"2+2\"}]}\n")
execute_process(
    COMMAND "${CLI}" notebook patch --file "${notebook_path}"
        --spec "${patch_path}" --out "${patched_path}"
    RESULT_VARIABLE patch_status
    OUTPUT_VARIABLE patch_json
    ERROR_VARIABLE patch_error)
if(NOT patch_status EQUAL 0)
    message(FATAL_ERROR "notebook patch failed: ${patch_error}")
endif()
string(JSON patched_count GET "${patch_json}" cell_count)
if(NOT patched_count EQUAL 2)
    message(FATAL_ERROR "unexpected patched notebook cell count: ${patched_count}")
endif()

set(empty_patch_path "${SMOKE_ROOT}/empty-patch.json")
set(empty_patched_path "${SMOKE_ROOT}/empty-patched.nb")
file(WRITE "${empty_patch_path}" "{}\n")
execute_process(
    COMMAND "${CLI}" notebook patch --file "${notebook_path}"
        --spec "${empty_patch_path}" --out "${empty_patched_path}"
    RESULT_VARIABLE empty_patch_status
    OUTPUT_VARIABLE empty_patch_json
    ERROR_VARIABLE empty_patch_error)
if(NOT empty_patch_status EQUAL 0)
    message(FATAL_ERROR "empty notebook patch failed: ${empty_patch_error}")
endif()
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E compare_files "${notebook_path}" "${empty_patched_path}"
    RESULT_VARIABLE empty_patch_compare)
if(NOT empty_patch_compare EQUAL 0)
    message(FATAL_ERROR "empty notebook patch changed source bytes")
endif()

execute_process(
    COMMAND "${CLI}" inline-box compose --prefix "icon: "
        --box-expr "GraphicsBox[{CircleBox[]}]"
    RESULT_VARIABLE compose_status
    OUTPUT_VARIABLE compose_json
    ERROR_VARIABLE compose_error)
if(NOT compose_status EQUAL 0)
    message(FATAL_ERROR "inline-box compose failed: ${compose_error}")
endif()
string(JSON compose_head GET "${compose_json}" boxes 0 head)
if(NOT compose_head STREQUAL "GraphicsBox")
    message(FATAL_ERROR "unexpected composed box head: ${compose_head}")
endif()

set(inline_notebook "${SMOKE_ROOT}/inline-box.nb")
file(WRITE "${inline_notebook}"
    "Notebook[{Cell[BoxData[GraphicsBox[{CircleBox[]}]], \"Output\", ExpressionUUID->\"uuid-graphic\"]}]\n")
execute_process(
    COMMAND "${CLI}" inline-box from-cell --file "${inline_notebook}"
        --expression-uuid "uuid-graphic" --prefix "icon: "
    RESULT_VARIABLE extract_status
    OUTPUT_VARIABLE extract_json
    ERROR_VARIABLE extract_error)
if(NOT extract_status EQUAL 0)
    message(FATAL_ERROR "inline-box extraction failed: ${extract_error}")
endif()
string(JSON extract_success GET "${extract_json}" success)
string(JSON extract_head GET "${extract_json}" selected_boxes 0 head)
if(NOT extract_success OR NOT extract_head STREQUAL "GraphicsBox")
    message(FATAL_ERROR "unexpected inline-box extraction payload")
endif()

execute_process(
    COMMAND "${CLI}" env show
    RESULT_VARIABLE env_status
    OUTPUT_VARIABLE env_json
    ERROR_VARIABLE env_error)
if(NOT env_status EQUAL 0)
    message(FATAL_ERROR "env show failed: ${env_error}")
endif()
string(JSON env_product GET "${env_json}" product)
if(env_product STREQUAL "")
    message(FATAL_ERROR "env show omitted product")
endif()

message(STATUS "native CLI smoke tests passed")
