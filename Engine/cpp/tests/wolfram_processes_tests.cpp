#include "tungsten/wolfram_processes.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <locale>
#include <string>
#include <vector>

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace {

namespace fs = std::filesystem;
using namespace std::chrono_literals;
int failures = 0;

class GroupedNumbers : public std::numpunct<char> {
protected:
    char do_decimal_point() const override { return ','; }
    char do_thousands_sep() const override { return '_'; }
    std::string do_grouping() const override { return "\1"; }
};

class GlobalLocaleGuard {
public:
    explicit GlobalLocaleGuard(const std::locale& replacement)
        : previous_(std::locale()) {
        std::locale::global(replacement);
    }
    ~GlobalLocaleGuard() {
        try {
            std::locale::global(previous_);
        } catch (...) {
        }
    }

private:
    std::locale previous_;
};

void check(bool condition, const std::string& message) {
    if (condition) return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
}

template<typename Actual, typename Expected>
void check_equal(
    const Actual& actual,
    const Expected& expected,
    const std::string& message) {
    if (actual == expected) return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
}

fs::path temporary_root(std::string_view prefix) {
    const auto stamp = std::chrono::high_resolution_clock::now()
        .time_since_epoch().count();
    for (std::size_t nonce = 0; nonce < 100; ++nonce) {
        const auto path = fs::temp_directory_path()
            / (std::string(prefix) + "-" + std::to_string(stamp) + "-"
                + std::to_string(nonce));
        std::error_code error;
        if (fs::create_directory(path, error)) return path;
    }
    throw std::runtime_error("could not create test directory");
}

tungsten::WolframProcessInfo process(std::uint32_t pid, bool controlling) {
    return {
        pid,
        0,
        "wolfram.exe",
        std::nullopt,
        std::nullopt,
        std::nullopt,
        false,
        true,
        false,
        controlling,
    };
}

void cache_tests() {
    using namespace tungsten;
    const auto root = temporary_root("tungsten-cpp-process-cache");
    check(!read_cached_max_license_processes_at(root),
        "missing license-process cache is empty");

    write_cached_max_license_processes_at(root, 2);
    check(read_cached_max_license_processes_at(root) == 2,
        "license-process cache round trips");
    const auto cache_path = root / "wolfram-license-cache.json";
    std::ifstream stream(cache_path, std::ios::binary);
    const std::string contents{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    const auto payload = JsonValue::parse(contents);
    check(payload.at("max_license_processes").as_uint64() == 2,
        "cache uses the shared JSON representation");
    check(payload.at("updated_utc").as_string().back() == 'Z',
        "cache timestamp is UTC");
#ifndef _WIN32
    struct stat root_status {};
    struct stat file_status {};
    check(::stat(root.c_str(), &root_status) == 0
            && (root_status.st_mode & 0777) == 0700,
        "process cache directory is private");
    check(::stat(cache_path.c_str(), &file_status) == 0
            && (file_status.st_mode & 0777) == 0600,
        "process cache file is private");
#endif

    write_cached_max_license_processes_at(root, 0);
    check(read_cached_max_license_processes_at(root) == 2,
        "nonpositive cache update is ignored");
    {
        std::ofstream invalid(cache_path, std::ios::binary | std::ios::trunc);
        invalid << "{not json";
    }
    check(!read_cached_max_license_processes_at(root),
        "malformed license-process cache is ignored");
    {
        std::ofstream invalid(cache_path, std::ios::binary | std::ios::trunc);
        invalid << R"({"max_license_processes":-1})";
    }
    check(!read_cached_max_license_processes_at(root),
        "negative license-process cache value is rejected");

    DiscoveryEnvironment environment{
        root / "Program Files",
        std::nullopt,
        root / "ProgramData",
        root / "Local",
        root / "Home",
        std::nullopt,
        std::nullopt,
    };
    check(wolfram_process_cache_root(environment) == root / "Local" / "Tungsten",
        "process cache root reuses discovery local-app-data policy");
    environment.local_app_data.reset();
#ifdef _WIN32
    check(wolfram_process_cache_root(environment)
            == fs::temp_directory_path() / "Tungsten",
        "process cache root has the Python-compatible temporary fallback");
#elif defined(__APPLE__)
    check(wolfram_process_cache_root(environment)
            == *environment.home / "Library" / "Caches" / "Tungsten",
        "process cache root uses the macOS per-user cache");
#else
    check(wolfram_process_cache_root(environment)
            == *environment.home / ".cache" / "Tungsten",
        "process cache root uses the POSIX per-user cache");
#endif

    std::error_code error;
    fs::remove_all(root, error);
}

void payload_and_projection_tests() {
    using namespace tungsten;
    const auto payload = JsonValue::parse(R"JSON([
        {"Name":"Mathematica.exe","ProcessId":10,"ParentProcessId":0,"ExecutablePath":null,"CommandLine":null,"StartedUtc":null},
        {"Name":"WolframKernel.exe","ProcessId":2,"ParentProcessId":10,"ExecutablePath":null,"CommandLine":"WolframKernel.exe -mathlink helper","StartedUtc":null},
        {"Name":"wolfram.exe","ProcessId":3,"ParentProcessId":99,"ExecutablePath":null,"CommandLine":"wolfram.exe -script C:\\Temp\\tungsten-wrapper-abc\\wrapper.wl","StartedUtc":"1970-01-01T01:00:00+01:00"},
        {"Name":"custom.exe","ProcessId":4,"ParentProcessId":0,"ExecutablePath":"C:\\Wolfram\\custom.exe","CommandLine":"custom.exe","StartedUtc":null},
        {"Name":"other.exe","ProcessId":5,"ParentProcessId":0,"ExecutablePath":null,"CommandLine":null,"StartedUtc":null},
        {"Name":"wolfram.exe","ParentProcessId":0},
        {"Name":"wolfram.exe","ProcessId":0,"ParentProcessId":0},
        {"Name":"wolfram.exe","ProcessId":-1,"ParentProcessId":0},
        {"Name":"wolfram.exe","ProcessId":1.5,"ParentProcessId":0},
        {"Name":"wolfram.exe","ProcessId":4294967296,"ParentProcessId":0},
        42
    ])JSON");
    const auto processes = normalize_wolfram_process_payload(payload);
    check(processes.size() == 4, "only Wolfram process rows are retained");
    check(processes.size() == 4 && processes[0].pid == 2 && processes[3].pid == 10,
        "process rows are sorted by pid");
    check(processes.size() == 4 && !processes[0].controlling_process_candidate,
        "MathLink helper kernel does not consume a controlling slot");
    check(processes.size() == 4 && processes[1].tungsten_owned
            && processes[1].headless_batch && processes[1].parent_missing
            && processes[1].controlling_process_candidate,
        "owned headless orphan is classified completely");
    check(processes.size() == 4 && !processes[2].controlling_process_candidate,
        "executable-path match alone does not imply controlling process");
    check(processes.size() == 4 && processes[3].controlling_process_candidate,
        "Mathematica front end consumes a controlling slot");
    check(processes.size() == 4 && processes[1].age_seconds().has_value(),
        "RFC 3339 timestamp with an offset yields an age");

    const WolframProcessSnapshot snapshot{processes, 2};
    check(snapshot.active_count() == 2,
        "snapshot counts only controlling process candidates");
    const auto json = snapshot.to_json();
    check(json.at("cached_max_license_processes").as_uint64() == 2,
        "snapshot projects cached license limit");
    check(json.at("active_count").as_uint64() == 2,
        "snapshot projects active count");
    check(json.at("processes").size() == 4,
        "snapshot projects process records");
    check(json.at("processes").at(0).at("age_seconds").is_null(),
        "process projection preserves unknown age as null");

    const auto singleton = normalize_wolfram_process_payload(JsonValue::parse(
        R"({"Name":"WolframDesktop.exe","ProcessId":7,"ParentProcessId":0})"));
    check(singleton.size() == 1 && singleton[0].controlling_process_candidate,
        "PowerShell singleton-object payload is normalized");
    check(normalize_wolfram_process_payload(JsonValue()).empty(),
        "null PowerShell payload is normalized to an empty list");
}

void cleanup_tests() {
    using namespace tungsten;
    auto stale = process(111, true);
    stale.parent_pid = 9;
    stale.tungsten_owned = true;
    stale.parent_missing = true;
    stale.started_utc = "1970-01-01T00:00:00Z";
    auto foreign = stale;
    foreign.pid = 222;
    foreign.tungsten_owned = false;
    auto attached = stale;
    attached.pid = 333;
    attached.parent_missing = false;
    auto young = stale;
    young.pid = 444;
    young.started_utc = utc_now_string();
    auto unknown_age = stale;
    unknown_age.pid = 555;
    unknown_age.started_utc = "not-a-time";
    auto failed = stale;
    failed.pid = 666;
    auto zero_pid = stale;
    zero_pid.pid = 0;

    std::vector<std::uint32_t> attempted;
    const auto cleaned = cleanup_stale_processes_with(
        {stale, foreign, attached, young, unknown_age, failed, zero_pid},
        30.0,
        [&](std::uint32_t pid) {
            attempted.push_back(pid);
            return pid != 666;
        });
    check_equal(attempted, std::vector<std::uint32_t>({111, 555, 666}),
        "cleanup attempts only old-or-unknown-age owned headless orphans");
    check_equal(cleaned, std::vector<std::uint32_t>({111, 555}),
        "cleanup reports only successful process-tree terminations");
}

void locale_independence_tests() {
    using namespace tungsten;
    GlobalLocaleGuard guard(std::locale(std::locale::classic(), new GroupedNumbers));
    const auto timestamp = utc_now_string();
    check(timestamp.size() >= 20 && timestamp[4] == '-' && timestamp[7] == '-'
            && timestamp[10] == 'T' && timestamp.back() == 'Z'
            && timestamp.find('_') == std::string::npos
            && timestamp.find(',') == std::string::npos,
        "UTC timestamps ignore the process-global numeric locale");
    const auto live = list_wolfram_processes();
    check(std::is_sorted(live.begin(), live.end(), [](const auto& left, const auto& right) {
            return left.pid < right.pid;
        }),
        "process enumeration parses platform numeric data under an invariant locale");
}

void license_wait_tests() {
    using namespace tungsten;
    const WolframProcessSnapshot blocked{{process(1, true), process(2, true)}, 2};
    const WolframProcessSnapshot free{{process(1, true), process(2, false)}, 2};

    std::size_t snapshots = 0;
    std::size_t sleeps = 0;
    const auto result = wait_for_wolfram_license_slot_with(
        2,
        5s,
        10ms,
        [&] {
            ++snapshots;
            return snapshots == 1 ? blocked : free;
        },
        [&](std::chrono::milliseconds duration) {
            ++sleeps;
            check(duration == 10ms, "license wait passes configured polling delay");
        });
    check(result.satisfied && result.snapshot.active_count() == 1,
        "license wait polls until the controlling count drops");
    check(snapshots == 2 && sleeps == 1,
        "license wait snapshot and sleep seams are deterministic");
    check(result.waited_seconds >= 0.0,
        "license wait reports nonnegative elapsed time");

    snapshots = 0;
    sleeps = 0;
    const auto unlimited = wait_for_wolfram_license_slot_with(
        std::nullopt,
        5s,
        10ms,
        [&] { ++snapshots; return blocked; },
        [&](std::chrono::milliseconds) { ++sleeps; });
    check(unlimited.satisfied && unlimited.waited_seconds == 0.0
            && snapshots == 1 && sleeps == 0,
        "unknown license limit admits immediately after one observation");

    const auto timed_out = wait_for_wolfram_license_slot_with(
        2,
        0ms,
        10ms,
        [&] { return blocked; },
        [](std::chrono::milliseconds) {});
    check(!timed_out.satisfied && timed_out.snapshot.active_count() == 2,
        "zero timeout returns the last blocked snapshot");
}

void platform_safety_and_gate_tests() {
    using namespace tungsten;
    const auto root = temporary_root("tungsten-cpp-launch-gate");
    {
        auto gate = WolframLaunchGate::acquire(10ms, 1ms, root);
        check(gate.waited_seconds() >= 0.0,
            "launch gate reports nonnegative acquisition time");
        bool blocked = false;
        try {
            auto second = WolframLaunchGate::acquire(0ms, 1ms, root);
            static_cast<void>(second);
        } catch (const WolframLaunchGateTimeout&) {
            blocked = true;
        }
        check(blocked, "launch gate excludes a concurrent acquisition");
        const auto live = list_wolfram_processes();
        check(std::is_sorted(live.begin(), live.end(), [](const auto& left, const auto& right) {
                return left.pid < right.pid;
            }),
            "platform process enumeration returns PID-sorted Wolfram processes");
        auto moved = std::move(gate);
        check(moved.waited_seconds() >= 0.0,
            "launch gate retains state across move construction");
    }
    std::error_code error;
    fs::remove_all(root, error);
}

} // namespace

int main() {
    cache_tests();
    payload_and_projection_tests();
    cleanup_tests();
    locale_independence_tests();
    license_wait_tests();
    platform_safety_and_gate_tests();
    if (failures != 0) {
        std::cerr << failures << " Wolfram process test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ Wolfram process tests passed\n";
    return EXIT_SUCCESS;
}
