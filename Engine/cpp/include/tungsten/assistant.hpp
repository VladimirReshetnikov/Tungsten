#pragma once

#include "tungsten/json.hpp"
#include "tungsten/kernel.hpp"
#include "tungsten/notebook.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

namespace tungsten {

enum class AssistantErrorCode {
    Kernel,
    Notebook,
    Json,
    InvalidSelector,
};

class AssistantError : public std::runtime_error {
public:
    AssistantError(AssistantErrorCode code, std::string message);

    [[nodiscard]] AssistantErrorCode code() const noexcept;

private:
    AssistantErrorCode code_;
};

struct AssistantFlatIndexSelector { std::size_t index = 0; };
struct AssistantPathSelector { std::vector<std::size_t> path; };
struct AssistantExpressionUuidSelector { std::string value; };
struct AssistantCellIdSelector { std::int64_t value = 0; };
struct AssistantCellTagSelector { std::string value; };

using AssistantCellSelector = std::variant<
    AssistantFlatIndexSelector,
    AssistantPathSelector,
    AssistantExpressionUuidSelector,
    AssistantCellIdSelector,
    AssistantCellTagSelector>;

struct AskOptions {
    std::string prompt;
    std::optional<std::string> system_prompt;
    std::optional<std::string> extra_instructions;
    std::optional<std::string> model_service;
    std::optional<std::string> model_name;
    std::optional<std::vector<std::string>> tools;
};

struct AskCellOptions {
    std::filesystem::path notebook_path;
    AssistantCellSelector selector;
    std::string question;
    bool insert_wolfram_code = false;
    bool insert_all_wolfram_code = false;
    bool save_notebook = false;
    bool close_assistant_notebook = false;
    std::optional<std::string> extra_instructions;
    std::optional<std::string> model_service;
    std::optional<std::string> model_name;
};

struct NotebookAssistantResult {
    KernelEvaluationResult evaluation;
    JsonValue payload;

    [[nodiscard]] bool assistant_success() const noexcept;
    [[nodiscard]] JsonValue to_json() const;
};

using AssistantEvaluationFunction = std::function<KernelEvaluationResult(
    const std::string&, const KernelEvaluationOptions&)>;

[[nodiscard]] std::string assistant_insert_mode(bool first, bool all);
[[nodiscard]] NotebookRow resolve_assistant_row(
    const NotebookDocument& document, const AssistantCellSelector& selector);
[[nodiscard]] JsonValue assistant_selector_from_row(const NotebookRow& row);
[[nodiscard]] JsonValue assistant_selector_for_kernel(
    const NotebookRow& row, const AssistantCellSelector& requested);

[[nodiscard]] JsonValue parse_assistant_payload(
    const KernelEvaluationResult& evaluation);
[[nodiscard]] std::string extract_assistant_text(
    const std::string& chat_object_string);
[[nodiscard]] std::vector<JsonValue> extract_assistant_code_blocks(
    const std::string& response_text);
[[nodiscard]] JsonValue finalize_assistant_ask_payload(JsonValue payload);

[[nodiscard]] std::string build_assistant_ask_script(const AskOptions& options);
[[nodiscard]] std::string build_assistant_ask_cell_script(
    const AskCellOptions& options, const JsonValue& selector);
[[nodiscard]] std::string build_assistant_insert_script(
    const std::filesystem::path& notebook_path,
    const JsonValue& selector,
    const std::vector<std::string>& code_strings,
    bool save_notebook);
[[nodiscard]] std::string build_assistant_prepare_inline_script(
    const std::filesystem::path& notebook_path, const JsonValue& selector);
[[nodiscard]] std::string build_assistant_capture_inline_script(
    const std::filesystem::path& notebook_path,
    const JsonValue& selector,
    const std::string& insert_mode,
    bool save_notebook);

class NotebookAssistantController {
public:
    NotebookAssistantController();
    explicit NotebookAssistantController(WolframKernelRunner runner);
    explicit NotebookAssistantController(AssistantEvaluationFunction evaluator);
    NotebookAssistantController(
        WolframKernelRunner runner, AssistantEvaluationFunction evaluator);

    [[nodiscard]] const WolframKernelRunner* runner() const noexcept;

    [[nodiscard]] NotebookAssistantResult ask(const AskOptions& options) const;
    [[nodiscard]] NotebookAssistantResult ask_cell(
        const AskCellOptions& options) const;
    [[nodiscard]] NotebookAssistantResult prepare_inline(
        const std::filesystem::path& notebook_path,
        const AssistantCellSelector& selector) const;
    [[nodiscard]] NotebookAssistantResult capture_inline(
        const std::filesystem::path& notebook_path,
        const AssistantCellSelector& selector,
        bool insert_wolfram_code = false,
        bool insert_all_wolfram_code = false,
        bool save_notebook = false) const;

    [[nodiscard]] std::string build_ask_script(
        const AskOptions& options) const;
    [[nodiscard]] JsonValue finalize_ask_payload(JsonValue payload) const;
    [[nodiscard]] JsonValue finalize_ask_cell_payload(
        JsonValue payload,
        const std::filesystem::path& notebook_path,
        const NotebookRow& source_row,
        const std::string& insert_mode,
        bool save_notebook) const;

private:
    [[nodiscard]] KernelEvaluationResult evaluate(
        const std::string& script) const;
    [[nodiscard]] JsonValue insert_code_blocks(
        const std::filesystem::path& notebook_path,
        const NotebookRow& source_row,
        const std::vector<JsonValue>& blocks,
        const std::string& insert_mode,
        bool save_notebook) const;

    std::optional<WolframKernelRunner> runner_;
    AssistantEvaluationFunction evaluator_;
};

} // namespace tungsten
