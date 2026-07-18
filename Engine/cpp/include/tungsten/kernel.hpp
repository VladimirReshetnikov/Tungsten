#pragma once

#include "tungsten/discovery.hpp"
#include "tungsten/json.hpp"
#include "tungsten/licensing.hpp"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace tungsten {

class KernelError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct KernelEvaluationResult {
    std::vector<std::string> command;
    int exit_code = -1;
    std::optional<bool> success;
    std::optional<std::string> failure_type;
    std::optional<std::string> result;
    std::optional<std::string> result_head;
    std::vector<std::string> messages;
    std::vector<std::string> messages_text;
    std::vector<std::string> output;
    std::optional<double> timing;
    std::optional<double> absolute_timing;
    std::string stdout_text;
    std::string stderr_text;
    std::optional<std::string> json_path;
    bool evaluation_available = false;
    MathpassInspection mathpass;
    bool used_mathpass_workaround = false;
    std::optional<std::int64_t> license_processes;
    std::optional<std::int64_t> max_license_processes;
    double launch_gate_wait_seconds = 0.0;
    double license_wait_seconds = 0.0;
    std::optional<bool> license_wait_satisfied;
    std::optional<std::uint32_t> cached_max_license_processes;
    std::vector<std::uint32_t> cleaned_tungsten_processes;
    std::vector<JsonValue> observed_wolfram_processes;

    [[nodiscard]] JsonValue to_json() const;
};

struct KernelEvaluationOptions {
    std::optional<std::filesystem::path> working_directory;
    bool require_front_end = false;
};

class WolframKernelRunner {
public:
    WolframKernelRunner();
    explicit WolframKernelRunner(WolframInstallation installation);

    [[nodiscard]] const WolframInstallation& installation() const noexcept;
    [[nodiscard]] JsonValue probe() const;
    [[nodiscard]] KernelEvaluationResult evaluate_text(
        const std::string& code,
        const KernelEvaluationOptions& options = {}) const;
    [[nodiscard]] KernelEvaluationResult evaluate_file(
        const std::filesystem::path& path,
        const KernelEvaluationOptions& options = {}) const;

private:
    [[nodiscard]] KernelEvaluationResult evaluate_file_internal(
        const std::filesystem::path& code_path,
        const std::filesystem::path& result_path,
        const KernelEvaluationOptions& options) const;
    [[nodiscard]] KernelEvaluationResult kernel_not_found_result() const;
    [[nodiscard]] KernelEvaluationResult launch_timeout_result(
        const std::string& message,
        std::optional<std::uint32_t> cached_max_license_processes) const;

    WolframInstallation installation_;
};

[[nodiscard]] std::string build_kernel_wrapper_script(
    const std::filesystem::path& code_path,
    const std::filesystem::path& result_path,
    const std::filesystem::path& working_directory,
    bool require_front_end = false);

} // namespace tungsten
