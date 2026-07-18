#include "tungsten/frontend.hpp"

#include "tungsten/wolfram_strings.hpp"

#include <system_error>
#include <utility>

namespace tungsten {
namespace {

namespace fs = std::filesystem;

fs::path absolute_path(const fs::path& path) {
    std::error_code error;
    auto canonical = fs::canonical(path, error);
    if (!error) return canonical;
    if (path.is_absolute()) return path.lexically_normal();
    auto absolute = fs::absolute(path, error);
    return error ? path : absolute.lexically_normal();
}

std::string resolved_posix(const fs::path& path) {
    auto value = absolute_path(path).generic_u8string();
    if (value.rfind("//?/UNC/", 0) == 0) value.replace(0, 8, "//");
    else if (value.rfind("//?/", 0) == 0) value.erase(0, 4);
    return value;
}

} // namespace

FrontEndController::FrontEndController()
    : runner_(), docs_index_(runner_.installation()) {}

FrontEndController::FrontEndController(
    WolframKernelRunner runner,
    std::optional<DocumentationIndex> docs_index)
    : runner_(std::move(runner)),
      docs_index_(docs_index
              ? std::move(*docs_index)
              : DocumentationIndex(runner_.installation())) {}

const WolframKernelRunner& FrontEndController::runner() const noexcept {
    return runner_;
}

const DocumentationIndex& FrontEndController::docs_index() const noexcept {
    return docs_index_;
}

KernelEvaluationResult FrontEndController::probe() const {
    return runner_.evaluate_text(
        "nb = UsingFrontEnd[CreateDocument[Notebook[{Cell[\"Tungsten probe\", "
        "\"Text\"]}, Visible -> False]]]; head = Head[nb]; "
        "UsingFrontEnd[NotebookClose[nb]]; head");
}

KernelEvaluationResult FrontEndController::run(
    const std::string& code,
    bool wrap_using_front_end) const {
    KernelEvaluationOptions options;
    options.require_front_end = wrap_using_front_end;
    return runner_.evaluate_text(code, options);
}

KernelEvaluationResult FrontEndController::open_notebook(
    const fs::path& path) const {
    KernelEvaluationOptions options;
    options.require_front_end = true;
    return runner_.evaluate_text(front_end_open_notebook_code(path), options);
}

KernelEvaluationResult FrontEndController::open_documentation(
    const std::string& identifier,
    const std::optional<fs::path>& index_path) const {
    const auto paclet = docs_index_.resolve_identifier(identifier, index_path);
    KernelEvaluationOptions options;
    options.require_front_end = true;
    return runner_.evaluate_text(
        "NotebookLocate[" + wl_string(paclet) + "]", options);
}

KernelEvaluationResult FrontEndController::execute_token(
    const std::string& token,
    const std::optional<fs::path>& notebook_path) const {
    KernelEvaluationOptions options;
    options.require_front_end = true;
    return runner_.evaluate_text(
        front_end_execute_token_code(token, notebook_path), options);
}

std::string front_end_open_notebook_code(const fs::path& path) {
    return "NotebookOpen[" + wl_string(resolved_posix(path)) + "]";
}

std::string front_end_execute_token_code(
    const std::string& token,
    const std::optional<fs::path>& notebook_path) {
    if (!notebook_path)
        return "FrontEndTokenExecute[" + wl_string(token) + "]";
    return "nb = NotebookOpen[" + wl_string(resolved_posix(*notebook_path))
        + "]; FrontEndTokenExecute[nb, " + wl_string(token) + "]; nb";
}

} // namespace tungsten
