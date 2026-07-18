#include "tungsten/kernel.hpp"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

namespace fs = std::filesystem;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

class TestDirectory {
public:
    TestDirectory() {
        const auto stamp = std::chrono::high_resolution_clock::now()
                               .time_since_epoch()
                               .count();
        path_ = fs::temp_directory_path()
            / ("tungsten-kernel-test-" + std::to_string(stamp));
        fs::create_directories(path_);
    }

    ~TestDirectory() {
        std::error_code error;
        fs::remove_all(path_, error);
    }

    const fs::path& path() const noexcept { return path_; }

private:
    fs::path path_;
};

tungsten::WolframInstallation installation_with_kernel(
    const fs::path& root,
    std::optional<fs::path> kernel) {
    tungsten::WolframInstallation installation;
    installation.install_dir = root;
    installation.kernel_cli = std::move(kernel);
    installation.kernel_executable = installation.kernel_cli;
    installation.default_index_path = root / "docs.sqlite";
    return installation;
}

void test_missing_kernel_result() {
    TestDirectory root;
    auto installation = installation_with_kernel(root.path(), std::nullopt);
    installation.mathpass = root.path() / "mathpass";
    {
        std::ofstream stream(*installation.mathpass, std::ios::binary);
        stream << "% header\nentry\nentry\n";
    }
    tungsten::WolframKernelRunner runner(std::move(installation));
    const auto result = runner.evaluate_text("2+2");
    require(result.exit_code == 127, "missing kernel exit code");
    require(result.failure_type == std::optional<std::string>("KernelNotFound"),
        "missing kernel failure type");
    require(!result.evaluation_available, "missing kernel availability");
    require(result.command.empty(), "missing kernel command");
    require(!result.success, "missing kernel success must be null");
    const auto payload = result.to_json();
    require(payload.at("success").is_null(), "missing result success JSON");
    require(payload.at("mathpass").at("original_line_count").as_uint64() == 0,
        "missing result mathpass JSON");
    require(payload.at("mathpass").at("path").as_string()
            == (root.path() / "mathpass").u8string(),
        "missing result retains the selected mathpass path");
    require(payload.at("observed_wolfram_processes").is_array(),
        "missing result process JSON");
}

void test_wrapper_contract() {
    const fs::path root = fs::temp_directory_path() / "tungsten kernel wrapper";
    const auto wrapper = tungsten::build_kernel_wrapper_script(
        root / "input.wl", root / "result.json", root, true);
    require(wrapper.find("SetDirectory[\"") != std::string::npos,
        "wrapper working directory");
    require(wrapper.find("tungsten kernel wrapper") != std::string::npos,
        "wrapper preserves spaces");
    require(wrapper.find(
                "HoldComplete[UsingFrontEnd[ReleaseHold[heldExpr]]]")
            != std::string::npos,
        "wrapper front-end branch");
    require(wrapper.find("EvaluationData[ReleaseHold[evalExpr]]")
            != std::string::npos,
        "wrapper evaluation data");
    require(wrapper.find("\"max_license_processes\"") != std::string::npos,
        "wrapper license metadata");
    require(wrapper.find("CapturedPrint[args___]") != std::string::npos,
        "wrapper print capture");
    require(wrapper.find("CompoundExpression[exprs]") != std::string::npos,
        "wrapper compound expression normalization");
}

#ifndef _WIN32
void test_fake_kernel_round_trip() {
    TestDirectory root;
    const auto kernel = root.path() / "fake-wolfram";
    {
        std::ofstream stream(kernel, std::ios::binary);
        stream << R"SH(#!/bin/sh
wrapper=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-script" ]; then
        shift
        wrapper="$1"
    fi
    shift
done
result=$(sed -n 's/^[[:space:]]*"\([^"]*result\.json\)".*/\1/p' "$wrapper" | head -n 1)
printf '%s' '{"success":true,"failure_type":null,"result":"4","result_head":"Integer","license_processes":-9223372036854775808.0,"max_license_processes":9223372036854775808.0,"messages":["Power::infy"],"messages_text":["Infinite expression"],"output":["hello"],"timing":0.25,"absolute_timing":0.5}' > "$result"
printf 'fake stdout \342\202\n'
printf 'fake stderr\n' >&2
exit 0
)SH";
    }
    fs::permissions(
        kernel,
        fs::perms::owner_read | fs::perms::owner_write
            | fs::perms::owner_exec,
        fs::perm_options::replace);

    tungsten::WolframKernelRunner runner(
        installation_with_kernel(root.path(), kernel));
    tungsten::KernelEvaluationOptions options;
    options.working_directory = root.path();
    const auto result = runner.evaluate_text("Print[2+2]; 2+2", options);
    require(result.exit_code == 0, "fake kernel exit code");
    require(result.success == std::optional<bool>(true), "fake kernel success");
    require(!result.failure_type, "fake kernel failure type");
    require(result.result == std::optional<std::string>("4"),
        "fake kernel result");
    require(result.result_head == std::optional<std::string>("Integer"),
        "fake kernel result head");
    require(result.messages == std::vector<std::string>{"Power::infy"},
        "fake kernel messages");
    require(result.messages_text
            == std::vector<std::string>{"Infinite expression"},
        "fake kernel message text");
    require(result.output == std::vector<std::string>{"hello"},
        "fake kernel output");
    require(result.timing == std::optional<double>(0.25),
        "fake kernel timing");
    require(result.absolute_timing == std::optional<double>(0.5),
        "fake kernel absolute timing");
    require(result.stdout_text == u8"fake stdout \ufffd\n",
        "fake kernel stdout uses Python-compatible lossy UTF-8 decoding");
    require(result.stderr_text == "fake stderr\n", "fake kernel stderr");
    require(result.evaluation_available, "fake kernel availability");
    require(result.license_wait_satisfied == std::optional<bool>(true),
        "fake kernel license wait");
    require(result.license_processes
            == std::optional<std::int64_t>(std::numeric_limits<std::int64_t>::min()),
        "minimum binary64 integer remains representable");
    require(!result.max_license_processes,
        "exclusive binary64 upper boundary is not narrowed to int64");
    require(result.command.size() >= 4, "fake kernel command shape");
    require(result.command.front() == kernel.u8string(),
        "fake kernel command executable");
    require(result.to_json().at("stdout").as_string() == u8"fake stdout \ufffd\n",
        "fake kernel JSON projection");
}
#endif

} // namespace

int main() {
    try {
        test_missing_kernel_result();
        test_wrapper_contract();
#ifndef _WIN32
        test_fake_kernel_round_trip();
#endif
        std::cout << "all C++ kernel tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "kernel test failure: " << error.what() << '\n';
        return 1;
    }
}
