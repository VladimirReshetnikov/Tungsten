#include "tungsten/assistant.hpp"

#include "tungsten/parser.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

namespace fs = std::filesystem;
using namespace tungsten;

class TemporaryDirectory {
public:
    explicit TemporaryDirectory(const std::string& prefix) {
        static std::atomic<unsigned long long> sequence{0};
        const auto stamp = std::chrono::high_resolution_clock::now()
                               .time_since_epoch().count();
        for (unsigned attempt = 0; attempt < 1000; ++attempt) {
            path_ = fs::temp_directory_path() / (prefix + '-'
                + std::to_string(stamp) + '-'
                + std::to_string(sequence.fetch_add(1)) + '-'
                + std::to_string(attempt));
            std::error_code error;
            if (fs::create_directory(path_, error)) return;
            if (error && error != std::errc::file_exists)
                throw fs::filesystem_error("could not create test directory", path_, error);
        }
        throw std::runtime_error("could not allocate test directory");
    }

    ~TemporaryDirectory() {
        std::error_code error;
        fs::remove_all(path_, error);
    }

    [[nodiscard]] const fs::path& path() const noexcept { return path_; }

private:
    fs::path path_;
};

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void write_file(const fs::path& path, const std::string& contents) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("could not create notebook fixture");
    stream << contents;
    if (!stream) throw std::runtime_error("could not write notebook fixture");
}

std::string assistant_chat(const std::string& data) {
    return "ChatObject[<|\"Messages\" -> {<|\"Role\" -> \"Assistant\", "
        "\"Content\" -> {<|\"Type\" -> \"Text\", \"Data\" -> \""
        + data + "\"|>}, \"Metadata\" -> <||>|>}|>]";
}

KernelEvaluationResult evaluation_for(const JsonValue& payload) {
    KernelEvaluationResult result;
    result.exit_code = 0;
    result.success = true;
    result.result = wl_string(payload.dump());
    result.result_head = "String";
    result.evaluation_available = true;
    return result;
}

struct FakeEvaluatorState {
    std::vector<KernelEvaluationResult> replies;
    std::vector<std::string> scripts;
    std::vector<KernelEvaluationOptions> options;
    std::size_t cursor = 0;
};

NotebookAssistantController fake_controller(
    const std::shared_ptr<FakeEvaluatorState>& state) {
    return NotebookAssistantController(
        [state](const std::string& script, const KernelEvaluationOptions& options) {
            state->scripts.push_back(script);
            state->options.push_back(options);
            if (state->cursor >= state->replies.size())
                throw std::runtime_error("fake assistant evaluator exhausted");
            return state->replies[state->cursor++];
        });
}

fs::path make_notebook(const fs::path& root) {
    const auto path = root / "assistant fixture.nb";
    write_file(path, R"WL(Notebook[{
Cell["first", "Input", CellID->101, ExpressionUUID->"uuid-first", CellTags->{"shared", "one"}],
Cell[CellGroupData[{
Cell["second", "Text", CellID->202, ExpressionUUID->"uuid-second", CellTags->{"shared", "two"}],
Cell["third", "Output", CellTags->"three"]
}, Open]]
}, WindowTitle->"Assistant Fixture"]
)WL");
    return path;
}

void test_response_and_code_block_extraction() {
    const std::string raw =
        "ChatObject[<|\"Messages\" -> {"
        "<|\"Role\" -> \"Assistant\", \"Content\" -> {"
        "<|\"Type\" -> \"Text\", \"Data\" -> \"old\"|>}, \"Metadata\" -> <||>|>,"
        "<|\"Role\" -> \"Assistant\", \"Content\" -> {"
        "<|\"Type\" -> \"Text\", \"Data\" -> \"first\\\\nline\"|>,"
        "<|\"Type\" -> \"Image\", \"Data\" -> \"ignore\"|>,"
        "<|\"Type\" -> \"Text\", \"Data\" -> \"```Wolfram   Language\\\\n2 + 2\\\\n```\"|>},"
        "\"Metadata\" -> <||>|>}|>]";
    const auto response = extract_assistant_text(raw);
    require(response == "first\nline\n\n```Wolfram   Language\n2 + 2\n```",
        "assistant response extraction did not use the final assistant section/text chunks");

    const auto blocks = extract_assistant_code_blocks(
        response + "\n```python\nprint(4)\n```\n```\nplain\n```");
    require(blocks.size() == 3, "fenced-code extraction returned the wrong count");
    require(blocks[0].at("language").as_string() == "Wolfram   Language"
            && blocks[0].at("code").as_string() == "2 + 2"
            && blocks[0].at("insertable").as_boolean(),
        "Wolfram Language code block metadata was incorrect");
    require(!blocks[1].at("insertable").as_boolean(),
        "non-Wolfram code was marked insertable");
    require(blocks[2].at("language").as_string() == "Unknown",
        "unlabelled code block did not use Unknown language");
    const auto unicode_whitespace = extract_assistant_code_blocks(
        u8"```\u3000Wolfram\u2003Language\u3000\n\u00a0 2 + 2 \u00a0\n```");
    require(unicode_whitespace.size() == 1
            && unicode_whitespace[0].at("language").as_string()
                == u8"Wolfram\u2003Language"
            && unicode_whitespace[0].at("code").as_string() == "2 + 2"
            && unicode_whitespace[0].at("insertable").as_boolean(),
        "assistant fenced-code handling matches Python Unicode whitespace semantics");
    require(extract_assistant_text("ChatObject[<||>]").empty(),
        "missing assistant section did not produce an empty response");
}

void test_payload_parsing_and_result_model() {
    KernelEvaluationResult unavailable;
    unavailable.stderr_text = "kernel absent";
    auto payload = parse_assistant_payload(unavailable);
    require(payload.at("error_type").as_string() == "EvaluationUnavailable"
            && payload.at("error").as_string() == "kernel absent",
        "unavailable evaluation failure shape diverged");

    KernelEvaluationResult failed;
    failed.evaluation_available = true;
    failed.success = false;
    failed.failure_type = "FrontEndFailure";
    failed.result = "$Failed";
    payload = parse_assistant_payload(failed);
    require(payload.at("error_type").as_string() == "FrontEndFailure"
            && payload.at("error").as_string() == "$Failed",
        "failed evaluation did not retain failure type/result fallback");

    KernelEvaluationResult missing;
    missing.evaluation_available = true;
    missing.success = true;
    require(parse_assistant_payload(missing).at("error_type").as_string()
            == "MissingAssistantPayload",
        "missing assistant result did not produce the expected failure");

    KernelEvaluationResult invalid;
    invalid.evaluation_available = true;
    invalid.success = true;
    invalid.result = "not-a-Wolfram-string";
    require(parse_assistant_payload(invalid).at("error_type").as_string()
            == "InvalidAssistantPayload",
        "invalid assistant payload did not produce a structured parse failure");

    KernelEvaluationResult non_object;
    non_object.evaluation_available = true;
    non_object.success = true;
    non_object.result = wl_string("[1,2]");
    const auto non_object_payload = parse_assistant_payload(non_object);
    require(non_object_payload.at("raw_payload").is_array(),
        "non-object payload was not retained for diagnostics");

    auto valid_evaluation = evaluation_for(JsonValue::object({
        {"success", true}, {"value", 42}}));
    payload = parse_assistant_payload(valid_evaluation);
    NotebookAssistantResult result{valid_evaluation, payload};
    require(result.assistant_success(), "assistant success model rejected true payload");
    require(result.to_json().at("assistant_success").as_boolean()
            && result.to_json().at("assistant").at("value").as_int64() == 42,
        "assistant result JSON shape was not preserved");
}

void test_finalize_bare_payload() {
    auto payload = JsonValue::object({
        {"success", true},
        {"prompt", "question"},
        {"assistant_chat_object_string", assistant_chat(
            "Use Integrate.\\\\n```wolfram\\\\nIntegrate[x,x]\\\\n```")},
    });
    auto finalized = finalize_assistant_ask_payload(payload);
    require(finalized.at("success").as_boolean(), "successful ask payload became a failure");
    require(finalized.at("wolfram_code_blocks").size() == 1
            && finalized.at("wolfram_code_blocks").at(0).at("code").as_string()
                == "Integrate[x,x]",
        "bare ask finalization lost its Wolfram code block");
    require(!finalized.contains("assistant_chat_object_string")
            && finalized.at("prompt").as_string() == "question",
        "bare ask finalization did not strip raw chat/preserve original fields");

    auto failure_payload = JsonValue::object({
        {"success", false}, {"error_type", "Original"}});
    require(finalize_assistant_ask_payload(failure_payload) == failure_payload,
        "failed payload was not passed through unchanged");
    finalized = finalize_assistant_ask_payload(
        JsonValue::object({{"success", true}}));
    require(finalized.at("error_type").as_string() == "AssistantResponseUnavailable",
        "missing chat string did not become a structured response failure");
}

void test_selector_resolution() {
    TemporaryDirectory temporary("tungsten-cpp-assistant-selector");
    const auto path = make_notebook(temporary.path());
    const auto document = NotebookDocument::load(path);

    const auto first = resolve_assistant_row(document, AssistantFlatIndexSelector{0});
    require(first.expression_uuid == "uuid-first", "flat selector resolved wrong row");
    const auto second = resolve_assistant_row(
        document, AssistantPathSelector{{1, 0}});
    require(second.cell_id == 202, "path selector resolved wrong row");
    require(resolve_assistant_row(document,
                AssistantExpressionUuidSelector{"uuid-second"}).index == 1,
        "expression UUID selector resolved wrong row");
    require(resolve_assistant_row(document, AssistantCellIdSelector{101}).index == 0,
        "CellID selector resolved wrong row");
    require(resolve_assistant_row(document, AssistantCellTagSelector{"three"}).index == 2,
        "cell-tag selector resolved wrong row");

    require(assistant_selector_from_row(first).at("expression_uuid").as_string()
            == "uuid-first",
        "stable selector did not prioritize ExpressionUUID");
    require(assistant_selector_for_kernel(first,
                AssistantCellIdSelector{999}).at("cell_id").as_int64() == 999,
        "explicit kernel selector was replaced with row metadata");
    require(assistant_insert_mode(true, true) == "all"
            && assistant_insert_mode(true, false) == "first"
            && assistant_insert_mode(false, false) == "none",
        "assistant insertion precedence was not preserved");

    bool ambiguous = false;
    try {
        (void)resolve_assistant_row(document, AssistantCellTagSelector{"shared"});
    } catch (const AssistantError& error) {
        ambiguous = error.code() == AssistantErrorCode::InvalidSelector
            && std::string(error.what()).find("more than one") != std::string::npos;
    }
    require(ambiguous, "ambiguous selector did not produce a typed error");
}

void test_wrapper_scripts() {
    AskOptions ask;
    ask.prompt = "What is Hypergeometric2F1[1, 1, 2, z]?";
    ask.system_prompt = "  You answer Wolfram-Language questions.  ";
    ask.extra_instructions = " Use a fenced block. ";
    ask.model_service = "OpenAI";
    ask.model_name = "model-name";
    ask.tools = std::vector<std::string>{"DocumentationSearcher"};
    const auto ask_script = build_assistant_ask_script(ask);
    (void)parse_input_form(ask_script);
    require(ask_script.find("Needs[\"Wolfram`Chatbook`\" -> None]")
                != std::string::npos
            && ask_script.find("Hypergeometric2F1") != std::string::npos
            && ask_script.find("DocumentationSearcher") != std::string::npos
            && ask_script.find("model-name") != std::string::npos
            && ask_script.find("tungstenChatCellEvaluate[chatCell, assistantNotebook]")
                != std::string::npos,
        "bare ask wrapper omitted prompt/settings/chat evaluation");
    require(ask_script.find("tungstenResolveNotebook") == std::string::npos
            && ask_script.find("__") == std::string::npos,
        "bare ask wrapper retained cell helpers/placeholders/template escapes");

    ask.system_prompt = u8"\u3000Unicode-trimmed\u3000";
    ask.extra_instructions = u8"\u00a0also-trimmed\u00a0";
    const auto unicode_trimmed_script = build_assistant_ask_script(ask);
    require(unicode_trimmed_script.find(u8"\u3000") == std::string::npos
            && unicode_trimmed_script.find(u8"\u00a0") == std::string::npos
            && unicode_trimmed_script.find("Unicode-trimmed") != std::string::npos
            && unicode_trimmed_script.find("also-trimmed") != std::string::npos,
        "assistant option trimming matches Python Unicode strip semantics");

    AskCellOptions cell;
    cell.notebook_path = fs::path("relative") / "example.nb";
    cell.selector = AssistantFlatIndexSelector{0};
    cell.question = "Explain this cell";
    cell.extra_instructions = "Be concise.";
    const auto selector = JsonValue::object({{"expression_uuid", "abc"}});
    const auto cell_script = build_assistant_ask_cell_script(cell, selector);
    (void)parse_input_form(cell_script);
    require(cell_script.find("tungstenCellToString") != std::string::npos
            && cell_script.find("Source notebook cell style") != std::string::npos
            && cell_script.find("Be concise.") != std::string::npos
            && cell_script.find("NotebookClose @ assistantNotebook") != std::string::npos
            && cell_script.find("abc") != std::string::npos,
        "ask-cell wrapper omitted source context or deterministic cleanup");

    const auto insert_script = build_assistant_insert_script(
        "example.nb", selector, {"2 + 2", "Integrate[x,x]"}, true);
    (void)parse_input_form(insert_script);
    require(insert_script.find("tungstenCodes") != std::string::npos
            && insert_script.find("2 + 2") != std::string::npos
            && insert_script.find("tungstenSaveNotebook = True") != std::string::npos
            && insert_script.find("ExpressionUUID -> uuid") != std::string::npos,
        "insert wrapper omitted code/save/stable inserted-cell metadata");

    const auto prepare = build_assistant_prepare_inline_script("example.nb", selector);
    (void)parse_input_form(prepare);
    require(prepare.find("ShowNotebookAssistance") != std::string::npos
            && prepare.find("MoveCursorToInputField") != std::string::npos,
        "inline prepare wrapper omitted assistant creation/focus");
    const auto capture = build_assistant_capture_inline_script(
        "example.nb", selector, "all", true);
    (void)parse_input_form(capture);
    require(capture.find("getCodeBlockContent") != std::string::npos
            && capture.find("insertAfterChatGeneratedCells") != std::string::npos
            && capture.find("has_progress_indicator") != std::string::npos
            && capture.find("MapIndexed") != std::string::npos
            && capture.find("tungstenInsertMode = \"all\"") != std::string::npos
            && capture.find("tungstenSaveNotebook = True") != std::string::npos,
        "inline capture wrapper omitted completion/code/insertion behavior");
}

void test_fake_ask_workflow() {
    auto state = std::make_shared<FakeEvaluatorState>();
    state->replies.push_back(evaluation_for(JsonValue::object({
        {"success", true},
        {"prompt", "question"},
        {"assistant_chat_object_string",
            assistant_chat("answer\\\\n```wl\\\\n2+2\\\\n```")},
    })));
    auto controller = fake_controller(state);
    AskOptions options;
    options.prompt = "question";
    const auto result = controller.ask(options);
    require(result.assistant_success()
            && result.payload.at("response_text").as_string().find("answer")
                != std::string::npos
            && result.payload.at("wolfram_code_blocks").size() == 1,
        "fake bare ask workflow did not parse/finalize the response");
    require(state->scripts.size() == 1 && state->options[0].require_front_end,
        "bare ask did not request a front-end evaluation exactly once");
}

void test_fake_ask_cell_and_insertion_workflow() {
    TemporaryDirectory temporary("tungsten-cpp-assistant-cell");
    const auto notebook = make_notebook(temporary.path());
    auto state = std::make_shared<FakeEvaluatorState>();
    state->replies.push_back(evaluation_for(JsonValue::object({
        {"success", true},
        {"source_cell", JsonValue::object({{"expression_uuid", "uuid-first"}})},
        {"assistant_chat_object_string", assistant_chat(
            "```wolfram\\\\n2 + 2\\\\n```\\\\n```wl\\\\n3 + 3\\\\n```")},
    })));
    state->replies.push_back(evaluation_for(JsonValue::object({
        {"success", true},
        {"inserted", JsonValue::Array{JsonValue::object({
            {"expression_uuid", "new-uuid"}, {"cell_id", 303}, {"code", "2 + 2"}})}},
        {"saved_notebook", true},
    })));
    auto controller = fake_controller(state);
    AskCellOptions options;
    options.notebook_path = notebook;
    options.selector = AssistantFlatIndexSelector{0};
    options.question = "What does this do?";
    options.insert_wolfram_code = true;
    options.save_notebook = true;
    const auto result = controller.ask_cell(options);
    require(result.assistant_success()
            && result.payload.at("insert_mode").as_string() == "first"
            && result.payload.at("inserted").size() == 1
            && result.payload.at("saved_notebook").as_boolean(),
        "ask-cell insertion result was not merged into the assistant payload");
    require(state->scripts.size() == 2
            && state->scripts[0].find("uuid-first") != std::string::npos
            && state->scripts[1].find("2 + 2") != std::string::npos
            && state->scripts[1].find("3 + 3") == std::string::npos
            && state->scripts[1].find("tungstenSaveNotebook = True")
                != std::string::npos,
        "first-code insertion did not issue the expected second wrapper evaluation");
    require(result.evaluation.result == state->replies[0].result,
        "ask-cell result did not retain the primary assistant evaluation");
}

void test_fake_inline_workflows_and_no_insert_finalization() {
    TemporaryDirectory temporary("tungsten-cpp-assistant-inline");
    const auto notebook = make_notebook(temporary.path());
    auto state = std::make_shared<FakeEvaluatorState>();
    state->replies.push_back(evaluation_for(JsonValue::object({
        {"success", true}, {"inline_cell_style", "AttachedChatInput"}})));
    state->replies.push_back(evaluation_for(JsonValue::object({
        {"success", true}, {"completed", false},
        {"has_progress_indicator", true}, {"inserted", JsonValue::Array{}}})));
    auto controller = fake_controller(state);

    const auto prepared = controller.prepare_inline(
        notebook, AssistantExpressionUuidSelector{"uuid-second"});
    require(prepared.assistant_success()
            && prepared.payload.at("inline_cell_style").as_string()
                == "AttachedChatInput",
        "prepare-inline workflow did not return structured payload");
    const auto captured = controller.capture_inline(notebook,
        AssistantCellIdSelector{202}, true, true, true);
    require(captured.assistant_success()
            && captured.payload.at("has_progress_indicator").as_boolean(),
        "capture-inline workflow did not return structured payload");
    require(state->scripts[1].find("tungstenInsertMode = \"all\"")
                != std::string::npos
            && state->scripts[1].find("tungstenSaveNotebook = True")
                != std::string::npos,
        "capture-inline workflow lost all-over-first insertion/save precedence");

    const auto document = NotebookDocument::load(notebook);
    const auto row = document.cell_at_flat_index(0);
    auto no_insert = controller.finalize_ask_cell_payload(JsonValue::object({
        {"success", true},
        {"source_cell", JsonValue::object({{"expression_uuid", "uuid-first"}})},
        {"assistant_chat_object_string",
            assistant_chat("```wolfram\\\\n4 + 4\\\\n```")},
    }), notebook, row, "none", false);
    require(no_insert.at("success").as_boolean()
            && no_insert.at("inserted").size() == 0
            && !no_insert.at("saved_notebook").as_boolean()
            && !no_insert.contains("assistant_chat_object_string"),
        "ask-cell no-insertion finalization did not mirror Python behavior");
    require(state->scripts.size() == 2,
        "no-insertion finalization unexpectedly evaluated an insertion wrapper");
}

} // namespace

int main() {
    try {
        test_response_and_code_block_extraction();
        test_payload_parsing_and_result_model();
        test_finalize_bare_payload();
        test_selector_resolution();
        test_wrapper_scripts();
        test_fake_ask_workflow();
        test_fake_ask_cell_and_insertion_workflow();
        test_fake_inline_workflows_and_no_insert_finalization();
        std::cout << "all C++ Notebook Assistant tests passed\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "Notebook Assistant test failure: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
