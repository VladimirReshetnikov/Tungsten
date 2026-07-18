#pragma once

#include "tungsten/discovery.hpp"
#include "tungsten/json.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace tungsten {

class WolframProcessError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class WolframLaunchGateTimeout : public WolframProcessError {
public:
    WolframLaunchGateTimeout();
};

struct WolframProcessInfo {
    std::uint32_t pid = 0;
    std::uint32_t parent_pid = 0;
    std::string name;
    std::optional<std::string> executable_path;
    std::optional<std::string> command_line;
    std::optional<std::string> started_utc;
    bool tungsten_owned = false;
    bool headless_batch = false;
    bool parent_missing = false;
    bool controlling_process_candidate = false;

    [[nodiscard]] std::optional<double> age_seconds() const noexcept;
    [[nodiscard]] JsonValue to_json() const;

    friend bool operator==(
        const WolframProcessInfo& left,
        const WolframProcessInfo& right) noexcept {
        return left.pid == right.pid
            && left.parent_pid == right.parent_pid
            && left.name == right.name
            && left.executable_path == right.executable_path
            && left.command_line == right.command_line
            && left.started_utc == right.started_utc
            && left.tungsten_owned == right.tungsten_owned
            && left.headless_batch == right.headless_batch
            && left.parent_missing == right.parent_missing
            && left.controlling_process_candidate
                == right.controlling_process_candidate;
    }
};

struct WolframProcessSnapshot {
    std::vector<WolframProcessInfo> processes;
    std::optional<std::uint32_t> cached_max_license_processes;

    [[nodiscard]] std::size_t active_count() const noexcept;
    [[nodiscard]] JsonValue to_json() const;

    friend bool operator==(
        const WolframProcessSnapshot& left,
        const WolframProcessSnapshot& right) noexcept {
        return left.processes == right.processes
            && left.cached_max_license_processes
                == right.cached_max_license_processes;
    }
};

[[nodiscard]] std::filesystem::path wolfram_process_cache_root();
[[nodiscard]] std::filesystem::path wolfram_process_cache_root(
    const DiscoveryEnvironment& environment);

[[nodiscard]] std::optional<std::uint32_t>
read_cached_max_license_processes();
[[nodiscard]] std::optional<std::uint32_t>
read_cached_max_license_processes_at(const std::filesystem::path& cache_root);
void write_cached_max_license_processes(std::uint32_t value);
void write_cached_max_license_processes_at(
    const std::filesystem::path& cache_root,
    std::uint32_t value);

[[nodiscard]] std::string utc_now_string();

[[nodiscard]] std::vector<WolframProcessInfo>
normalize_wolfram_process_payload(const JsonValue& payload);
[[nodiscard]] std::vector<WolframProcessInfo> list_wolfram_processes();
[[nodiscard]] WolframProcessSnapshot snapshot_wolfram_processes();

using WolframProcessTerminator = std::function<bool(std::uint32_t)>;

[[nodiscard]] std::vector<std::uint32_t> cleanup_stale_tungsten_processes(
    double min_age_seconds = 30.0);
[[nodiscard]] std::vector<std::uint32_t> cleanup_stale_processes_with(
    const std::vector<WolframProcessInfo>& processes,
    double min_age_seconds,
    const WolframProcessTerminator& terminate);

class WolframLaunchGate {
public:
    static WolframLaunchGate acquire(
        std::chrono::milliseconds timeout = std::chrono::minutes(15),
        std::chrono::milliseconds poll = std::chrono::milliseconds(200),
        std::optional<std::filesystem::path> cache_root = std::nullopt);

    WolframLaunchGate(const WolframLaunchGate&) = delete;
    WolframLaunchGate& operator=(const WolframLaunchGate&) = delete;
    WolframLaunchGate(WolframLaunchGate&& other) noexcept;
    WolframLaunchGate& operator=(WolframLaunchGate&& other) noexcept;
    ~WolframLaunchGate();

    [[nodiscard]] double waited_seconds() const noexcept;

private:
    struct State;

    WolframLaunchGate(std::unique_ptr<State> state, double waited_seconds);

    std::unique_ptr<State> state_;
    double waited_seconds_ = 0.0;
};

struct WolframLicenseSlotWaitResult {
    WolframProcessSnapshot snapshot;
    double waited_seconds = 0.0;
    bool satisfied = false;
};

using WolframSnapshotProvider = std::function<WolframProcessSnapshot()>;
using WolframSleepFunction =
    std::function<void(std::chrono::milliseconds)>;

[[nodiscard]] WolframLicenseSlotWaitResult wait_for_wolfram_license_slot(
    std::optional<std::uint32_t> cached_max_license_processes,
    std::chrono::milliseconds timeout = std::chrono::seconds(30),
    std::chrono::milliseconds poll = std::chrono::milliseconds(500));
[[nodiscard]] WolframLicenseSlotWaitResult wait_for_wolfram_license_slot_with(
    std::optional<std::uint32_t> cached_max_license_processes,
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds poll,
    const WolframSnapshotProvider& snapshot,
    const WolframSleepFunction& sleep);

} // namespace tungsten
