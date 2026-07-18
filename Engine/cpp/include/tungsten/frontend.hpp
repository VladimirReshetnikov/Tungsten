#pragma once

#include "tungsten/docs_index.hpp"
#include "tungsten/kernel.hpp"

#include <filesystem>
#include <optional>
#include <string>

namespace tungsten {

class FrontEndController {
public:
    FrontEndController();
    explicit FrontEndController(
        WolframKernelRunner runner,
        std::optional<DocumentationIndex> docs_index = std::nullopt);

    [[nodiscard]] const WolframKernelRunner& runner() const noexcept;
    [[nodiscard]] const DocumentationIndex& docs_index() const noexcept;

    [[nodiscard]] KernelEvaluationResult probe() const;
    [[nodiscard]] KernelEvaluationResult run(
        const std::string& code,
        bool wrap_using_front_end = true) const;
    [[nodiscard]] KernelEvaluationResult open_notebook(
        const std::filesystem::path& path) const;
    [[nodiscard]] KernelEvaluationResult open_documentation(
        const std::string& identifier,
        const std::optional<std::filesystem::path>& index_path = std::nullopt) const;
    [[nodiscard]] KernelEvaluationResult execute_token(
        const std::string& token,
        const std::optional<std::filesystem::path>& notebook_path = std::nullopt) const;

private:
    WolframKernelRunner runner_;
    DocumentationIndex docs_index_;
};

[[nodiscard]] std::string front_end_open_notebook_code(
    const std::filesystem::path& path);
[[nodiscard]] std::string front_end_execute_token_code(
    const std::string& token,
    const std::optional<std::filesystem::path>& notebook_path = std::nullopt);

} // namespace tungsten
