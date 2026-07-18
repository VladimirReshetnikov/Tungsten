#include "tungsten/kernel.hpp"

#include "tungsten/wolfram_processes.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cerrno>
#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <system_error>
#include <thread>
#include <utility>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifndef _WIN32
extern char** environ;
#endif

namespace tungsten {
namespace {

namespace fs = std::filesystem;

std::string path_text(const fs::path& path) { return path.u8string(); }

bool path_exists(const fs::path& path) {
    std::error_code error;
    return fs::exists(path, error);
}

fs::path absolute_path(const fs::path& path) {
    std::error_code error;
    auto canonical = fs::canonical(path, error);
    if (!error) return canonical;
    if (path.is_absolute()) return path.lexically_normal();
    auto absolute = fs::absolute(path, error);
    return error ? path : absolute.lexically_normal();
}

void write_text_file(const fs::path& path, const std::string& value) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream)
        throw KernelError("could not create file: " + path_text(path));
    stream.write(value.data(), static_cast<std::streamsize>(value.size()));
    if (!stream)
        throw KernelError("could not write file: " + path_text(path));
}

std::string read_binary_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        throw KernelError("could not open file: " + path_text(path));
    std::string contents{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.eof() && stream.fail())
        throw KernelError("could not read file: " + path_text(path));
    return contents;
}

class TemporaryDirectory {
public:
    explicit TemporaryDirectory(std::string prefix) {
        static std::atomic<std::uint64_t> sequence{0};
        const auto stamp = std::chrono::high_resolution_clock::now()
                               .time_since_epoch()
                               .count();
        const auto root = fs::temp_directory_path();
        for (std::size_t attempt = 0; attempt < 1000; ++attempt) {
            const auto name = prefix + "-" + std::to_string(stamp) + "-"
                + std::to_string(sequence.fetch_add(1)) + "-"
                + std::to_string(attempt);
            path_ = root / name;
#ifdef _WIN32
            std::error_code error;
            if (fs::create_directory(path_, error)) return;
            if (error && error != std::errc::file_exists)
                throw fs::filesystem_error(
                    "could not create temporary directory", path_, error);
#else
            if (::mkdir(path_.c_str(), S_IRWXU) == 0) return;
            if (errno != EEXIST)
                throw fs::filesystem_error(
                    "could not create temporary directory", path_,
                    std::error_code(errno, std::generic_category()));
#endif
        }
        throw KernelError("could not allocate a Tungsten temporary directory");
    }

    TemporaryDirectory(const TemporaryDirectory&) = delete;
    TemporaryDirectory& operator=(const TemporaryDirectory&) = delete;

    ~TemporaryDirectory() {
        std::error_code error;
        fs::remove_all(path_, error);
    }

    [[nodiscard]] const fs::path& path() const noexcept { return path_; }

private:
    fs::path path_;
};

struct CompletedProcess {
    int exit_code = -1;
    std::string stdout_text;
    std::string stderr_text;
};

#ifdef _WIN32

class UniqueHandle {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE value) noexcept : value_(value) {}
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : value_(other.release()) {}
    UniqueHandle& operator=(UniqueHandle&& other) noexcept {
        if (this != &other) reset(other.release());
        return *this;
    }
    ~UniqueHandle() { reset(); }

    [[nodiscard]] HANDLE get() const noexcept { return value_; }
    [[nodiscard]] explicit operator bool() const noexcept {
        return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
    }
    HANDLE release() noexcept {
        const auto value = value_;
        value_ = nullptr;
        return value;
    }
    void reset(HANDLE value = nullptr) noexcept {
        if (*this) CloseHandle(value_);
        value_ = value;
    }

private:
    HANDLE value_ = nullptr;
};

std::wstring utf8_to_wide(const std::string& value) {
    if (value.empty()) return {};
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        throw KernelError("process argument is too large to convert to UTF-16");
    const int length = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    if (length <= 0)
        throw KernelError("could not convert a process argument to UTF-16");
    std::wstring output(static_cast<std::size_t>(length), L'\0');
    if (MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), output.data(), length)
        != length)
        throw KernelError("could not convert a process argument to UTF-16");
    return output;
}

std::wstring quote_windows_argument(const std::wstring& argument) {
    if (argument.empty()) return L"\"\"";
    if (argument.find_first_of(L" \t\n\v\"") == std::wstring::npos)
        return argument;
    std::wstring output = L"\"";
    std::size_t backslashes = 0;
    for (const wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        if (character == L'\"') {
            output.append(backslashes * 2 + 1, L'\\');
            output.push_back(L'\"');
        } else {
            output.append(backslashes, L'\\');
            output.push_back(character);
        }
        backslashes = 0;
    }
    output.append(backslashes * 2, L'\\');
    output.push_back(L'\"');
    return output;
}

CompletedProcess run_process(
    const std::vector<std::string>& command,
    const fs::path& capture_directory) {
    if (command.empty()) throw KernelError("cannot run an empty command");
    const auto stdout_path = capture_directory / "stdout.txt";
    const auto stderr_path = capture_directory / "stderr.txt";
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;
    UniqueHandle stdout_handle(CreateFileW(
        stdout_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &security,
        CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr));
    if (!stdout_handle)
        throw KernelError("could not create the kernel stdout capture file");
    UniqueHandle stderr_handle(CreateFileW(
        stderr_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &security,
        CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr));
    if (!stderr_handle)
        throw KernelError("could not create the kernel stderr capture file");

    std::wstring command_line;
    for (const auto& argument : command) {
        if (!command_line.empty()) command_line.push_back(L' ');
        command_line += quote_windows_argument(utf8_to_wide(argument));
    }
    std::vector<wchar_t> mutable_command(
        command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = stdout_handle.get();
    startup.hStdError = stderr_handle.get();
    PROCESS_INFORMATION process{};
    const BOOL created = CreateProcessW(
        nullptr, mutable_command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    stdout_handle.reset();
    stderr_handle.reset();
    if (!created)
        throw KernelError("could not launch the Wolfram kernel process");

    UniqueHandle process_handle(process.hProcess);
    UniqueHandle thread_handle(process.hThread);
    if (WaitForSingleObject(process_handle.get(), INFINITE) != WAIT_OBJECT_0) {
        TerminateProcess(process_handle.get(), 127);
        WaitForSingleObject(process_handle.get(), INFINITE);
        throw KernelError("could not wait for the Wolfram kernel process");
    }
    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process_handle.get(), &exit_code))
        throw KernelError("could not read the Wolfram kernel exit code");
    return {
        static_cast<int>(exit_code),
        decode_utf8_lossy(read_binary_file(stdout_path)),
        decode_utf8_lossy(read_binary_file(stderr_path)),
    };
}

#else

class SpawnFileActions {
public:
    SpawnFileActions() {
        const int error = posix_spawn_file_actions_init(&actions_);
        if (error != 0)
            throw KernelError(
                "could not initialize Wolfram process file actions: "
                + std::error_code(error, std::generic_category()).message());
    }

    SpawnFileActions(const SpawnFileActions&) = delete;
    SpawnFileActions& operator=(const SpawnFileActions&) = delete;

    ~SpawnFileActions() { posix_spawn_file_actions_destroy(&actions_); }

    void add_open(int descriptor, const fs::path& path) {
        const int error = posix_spawn_file_actions_addopen(
            &actions_, descriptor, path.c_str(), O_CREAT | O_WRONLY | O_TRUNC,
            S_IRUSR | S_IWUSR);
        if (error != 0)
            throw KernelError(
                "could not configure Wolfram process output capture: "
                + std::error_code(error, std::generic_category()).message());
    }

    void close_nonstandard_descriptors() {
#ifdef TUNGSTEN_HAVE_POSIX_SPAWN_CLOSEFROM
        const int error = posix_spawn_file_actions_addclosefrom_np(&actions_, 3);
        if (error != 0)
            throw KernelError(
                "could not isolate Wolfram process file descriptors: "
                + std::error_code(error, std::generic_category()).message());
#endif
    }

    [[nodiscard]] const posix_spawn_file_actions_t* get() const noexcept {
        return &actions_;
    }

private:
    posix_spawn_file_actions_t actions_{};
};

CompletedProcess run_process(
    const std::vector<std::string>& command,
    const fs::path& capture_directory) {
    if (command.empty()) throw KernelError("cannot run an empty command");
    const auto stdout_path = capture_directory / "stdout.txt";
    const auto stderr_path = capture_directory / "stderr.txt";
    std::vector<char*> arguments;
    arguments.reserve(command.size() + 1);
    for (const auto& argument : command)
        arguments.push_back(const_cast<char*>(argument.c_str()));
    arguments.push_back(nullptr);

    SpawnFileActions actions;
    actions.add_open(STDOUT_FILENO, stdout_path);
    actions.add_open(STDERR_FILENO, stderr_path);
    actions.close_nonstandard_descriptors();

    pid_t child = -1;
    const int spawn_error = ::posix_spawn(
        &child, command.front().c_str(), actions.get(), nullptr,
        arguments.data(), environ);
    if (spawn_error != 0)
        throw KernelError(
            "could not launch the Wolfram kernel process: "
            + std::error_code(spawn_error, std::generic_category()).message());

    int status = 0;
    while (::waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        throw KernelError(
            "could not wait for the Wolfram kernel process: "
            + std::error_code(errno, std::generic_category()).message());
    }
    int exit_code = -1;
    if (WIFEXITED(status)) exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) exit_code = -WTERMSIG(status);
    return {
        exit_code,
        decode_utf8_lossy(read_binary_file(stdout_path)),
        decode_utf8_lossy(read_binary_file(stderr_path)),
    };
}

#endif

JsonValue string_array(const std::vector<std::string>& values) {
    JsonValue::Array output;
    output.reserve(values.size());
    for (const auto& value : values) output.emplace_back(value);
    return JsonValue(std::move(output));
}

JsonValue uint_array(const std::vector<std::uint32_t>& values) {
    JsonValue::Array output;
    output.reserve(values.size());
    for (const auto value : values) output.emplace_back(value);
    return JsonValue(std::move(output));
}

JsonValue json_array(const std::vector<JsonValue>& values) {
    return JsonValue(JsonValue::Array(values.begin(), values.end()));
}

JsonValue optional_string_json(const std::optional<std::string>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

JsonValue optional_bool_json(const std::optional<bool>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

JsonValue optional_double_json(const std::optional<double>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

template <typename Integer>
JsonValue optional_integer_json(const std::optional<Integer>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

const JsonValue* field(const JsonValue* payload, std::string_view key) {
    return payload && payload->is_object() ? payload->find(key) : nullptr;
}

std::optional<bool> optional_bool(
    const JsonValue* payload, std::string_view key) {
    const auto* value = field(payload, key);
    if (!value || !value->is_boolean()) return std::nullopt;
    return value->as_boolean();
}

std::optional<std::string> optional_string(
    const JsonValue* payload, std::string_view key) {
    const auto* value = field(payload, key);
    if (!value || value->is_null()) return std::nullopt;
    if (value->is_string()) return value->as_string();
    if (value->is_boolean()) return value->as_boolean() ? "true" : "false";
    if (value->is_number()) return value->as_number().text;
    return value->dump();
}

std::optional<double> optional_double(
    const JsonValue* payload, std::string_view key) {
    const auto* value = field(payload, key);
    return value ? value->as_double() : std::nullopt;
}

std::optional<std::int64_t> optional_integer(
    const JsonValue* payload, std::string_view key) {
    const auto* value = field(payload, key);
    if (!value) return std::nullopt;
    if (const auto integer = value->as_int64()) return integer;
    const auto number = value->as_double();
    const auto exclusive_upper_bound = std::ldexp(1.0, 63);
    if (!number || !std::isfinite(*number)
        || std::trunc(*number) != *number
        || *number < -exclusive_upper_bound
        || *number >= exclusive_upper_bound)
        return std::nullopt;
    return static_cast<std::int64_t>(*number);
}

std::string scalar_string(const JsonValue& value) {
    if (value.is_string()) return value.as_string();
    if (value.is_null()) return "None";
    if (value.is_boolean()) return value.as_boolean() ? "true" : "false";
    if (value.is_number()) return value.as_number().text;
    return value.dump();
}

std::vector<std::string> string_list(
    const JsonValue* payload, std::string_view key) {
    const auto* value = field(payload, key);
    if (!value || !value->is_array()) return {};
    std::vector<std::string> output;
    output.reserve(value->size());
    for (const auto& item : value->as_array())
        output.push_back(scalar_string(item));
    return output;
}

std::vector<JsonValue> observed_processes() {
    std::vector<JsonValue> output;
    const auto snapshot = snapshot_wolfram_processes();
    output.reserve(snapshot.processes.size());
    for (const auto& process : snapshot.processes)
        output.push_back(process.to_json());
    return output;
}

std::string wl_path(const fs::path& path) {
    return wl_string(absolute_path(path).generic_u8string());
}

MathpassInspection unavailable_mathpass_inspection(
    const std::optional<fs::path>& path) {
    MathpassInspection inspection;
    if (path) inspection.path = path_text(*path);
    return inspection;
}

} // namespace

JsonValue KernelEvaluationResult::to_json() const {
    return JsonValue::object({
        {"command", string_array(command)},
        {"exit_code", exit_code},
        {"success", optional_bool_json(success)},
        {"failure_type", optional_string_json(failure_type)},
        {"result", optional_string_json(result)},
        {"result_head", optional_string_json(result_head)},
        {"messages", string_array(messages)},
        {"messages_text", string_array(messages_text)},
        {"output", string_array(output)},
        {"timing", optional_double_json(timing)},
        {"absolute_timing", optional_double_json(absolute_timing)},
        {"stdout", stdout_text},
        {"stderr", stderr_text},
        {"json_path", optional_string_json(json_path)},
        {"evaluation_available", evaluation_available},
        {"mathpass", mathpass.to_json()},
        {"used_mathpass_workaround", used_mathpass_workaround},
        {"license_processes", optional_integer_json(license_processes)},
        {"max_license_processes", optional_integer_json(max_license_processes)},
        {"launch_gate_wait_seconds", launch_gate_wait_seconds},
        {"license_wait_seconds", license_wait_seconds},
        {"license_wait_satisfied", optional_bool_json(license_wait_satisfied)},
        {"cached_max_license_processes",
         optional_integer_json(cached_max_license_processes)},
        {"cleaned_tungsten_processes", uint_array(cleaned_tungsten_processes)},
        {"observed_wolfram_processes", json_array(observed_wolfram_processes)},
    });
}

WolframKernelRunner::WolframKernelRunner()
    : installation_(discover_installation()) {}

WolframKernelRunner::WolframKernelRunner(WolframInstallation installation)
    : installation_(std::move(installation)) {}

const WolframInstallation& WolframKernelRunner::installation() const noexcept {
    return installation_;
}

JsonValue WolframKernelRunner::probe() const {
    const auto evaluation = evaluate_text("2+2");
    const auto front_end = evaluate_text(
        "nb = UsingFrontEnd[CreateDocument[Notebook[{Cell[\"Tungsten probe\", "
        "\"Text\"]}, Visible -> False]]]; head = Head[nb]; "
        "UsingFrontEnd[NotebookClose[nb]]; head");
    return JsonValue::object({
        {"evaluation", evaluation.to_json()},
        {"front_end", front_end.to_json()},
    });
}

KernelEvaluationResult WolframKernelRunner::evaluate_text(
    const std::string& code,
    const KernelEvaluationOptions& options) const {
    TemporaryDirectory directory("tungsten-eval");
    const auto code_path = directory.path() / "input.wl";
    const auto result_path = directory.path() / "result.json";
    write_text_file(code_path, code);
    return evaluate_file_internal(code_path, result_path, options);
}

KernelEvaluationResult WolframKernelRunner::evaluate_file(
    const fs::path& path,
    const KernelEvaluationOptions& options) const {
    TemporaryDirectory directory("tungsten-eval");
    return evaluate_file_internal(
        path, directory.path() / "result.json", options);
}

KernelEvaluationResult WolframKernelRunner::evaluate_file_internal(
    const fs::path& code_path,
    const fs::path& result_path,
    const KernelEvaluationOptions& options) const {
    if (!installation_.kernel_cli || !path_exists(*installation_.kernel_cli))
        return kernel_not_found_result();

    const auto execution_directory = absolute_path(
        options.working_directory.value_or(fs::current_path()));
    const auto cached_max = read_cached_max_license_processes();
    std::vector<std::string> command;
    double launch_gate_wait_seconds = 0.0;
    std::vector<std::uint32_t> cleaned;
    WolframLicenseSlotWaitResult license_wait;
    MathpassInspection inspection;
    bool used_mathpass_workaround = false;
    CompletedProcess completed;
    try {
        auto gate = WolframLaunchGate::acquire();
        launch_gate_wait_seconds = gate.waited_seconds();
        cleaned = cleanup_stale_tungsten_processes();
        if (!cleaned.empty())
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        license_wait = wait_for_wolfram_license_slot(
            cached_max, std::chrono::seconds(15),
            std::chrono::milliseconds(500));
        auto deduped = DedupedMathpass::create(installation_.mathpass);
        inspection = deduped.inspection();
        used_mathpass_workaround = deduped.path().has_value();
        TemporaryDirectory wrapper_directory("tungsten-wrapper");
        const auto wrapper_path = wrapper_directory.path() / "wrapper.wl";
        write_text_file(
            wrapper_path,
            build_kernel_wrapper_script(
                absolute_path(code_path), absolute_path(result_path),
                execution_directory, options.require_front_end));

        command.push_back(path_text(*installation_.kernel_cli));
        command.emplace_back("-noprompt");
        if (deduped.path()) {
            command.emplace_back("-pwfile");
            command.push_back(path_text(*deduped.path()));
        }
        command.emplace_back("-script");
        command.push_back(path_text(wrapper_path));
        completed = run_process(command, wrapper_directory.path());
    } catch (const WolframLaunchGateTimeout& error) {
        return launch_timeout_result(error.what(), cached_max);
    }

    std::optional<JsonValue> parsed;
    if (path_exists(result_path)) {
        try {
            parsed = JsonValue::parse(read_binary_file(result_path));
        } catch (const std::exception& error) {
            throw KernelError(
                "could not parse the Wolfram kernel result: "
                + std::string(error.what()));
        }
    }
    const JsonValue* payload = parsed ? &*parsed : nullptr;
    const auto max_license_processes =
        optional_integer(payload, "max_license_processes");
    if (max_license_processes && *max_license_processes > 0
        && static_cast<std::uint64_t>(*max_license_processes)
            <= std::numeric_limits<std::uint32_t>::max())
        write_cached_max_license_processes(
            static_cast<std::uint32_t>(*max_license_processes));

    return {
        std::move(command),
        completed.exit_code,
        optional_bool(payload, "success"),
        optional_string(payload, "failure_type"),
        optional_string(payload, "result"),
        optional_string(payload, "result_head"),
        string_list(payload, "messages"),
        string_list(payload, "messages_text"),
        string_list(payload, "output"),
        optional_double(payload, "timing"),
        optional_double(payload, "absolute_timing"),
        std::move(completed.stdout_text),
        std::move(completed.stderr_text),
        path_exists(result_path)
            ? std::optional<std::string>(path_text(result_path))
            : std::nullopt,
        path_exists(result_path),
        std::move(inspection),
        used_mathpass_workaround,
        optional_integer(payload, "license_processes"),
        max_license_processes,
        launch_gate_wait_seconds,
        license_wait.waited_seconds,
        license_wait.satisfied,
        cached_max,
        std::move(cleaned),
        observed_processes(),
    };
}

KernelEvaluationResult WolframKernelRunner::kernel_not_found_result() const {
    KernelEvaluationResult output;
    output.exit_code = 127;
    output.failure_type = "KernelNotFound";
#ifdef _WIN32
    output.stderr_text =
        "No local wolfram.exe installation was discovered.";
#else
    output.stderr_text =
        "No local Wolfram kernel installation was discovered.";
#endif
    // No launch was attempted, so mirror the oracle's diagnostic model: keep
    // the selected mathpass path but do not imply that Tungsten inspected or
    // de-duplicated its contents.
    output.mathpass = unavailable_mathpass_inspection(installation_.mathpass);
    output.cached_max_license_processes =
        read_cached_max_license_processes();
    return output;
}

KernelEvaluationResult WolframKernelRunner::launch_timeout_result(
    const std::string& message,
    std::optional<std::uint32_t> cached_max_license_processes) const {
    KernelEvaluationResult output;
    output.exit_code = 124;
    output.failure_type = "LaunchGateTimeout";
    output.stderr_text = message;
    output.mathpass = unavailable_mathpass_inspection(installation_.mathpass);
    output.cached_max_license_processes = cached_max_license_processes;
    try {
        output.observed_wolfram_processes = observed_processes();
    } catch (...) {
        // Process diagnostics must not hide the structured launch-timeout result.
    }
    return output;
}

std::string build_kernel_wrapper_script(
    const fs::path& code_path,
    const fs::path& result_path,
    const fs::path& working_directory,
    bool require_front_end) {
    std::ostringstream script;
    script << R"WL($HistoryLength = 0;
SetDirectory[)WL"
           << wl_path(working_directory) << R"WL(];

userCode = Import[)WL"
           << wl_path(code_path) << R"WL(, "Text"];
output = {};

ClearAll[
    Tungsten`Private`CapturedPrint,
    Tungsten`Private`Stringify,
    Tungsten`Private`HeadStringify,
    Tungsten`Private`StringList
];
(* Stock Print is NOT HoldAll - its args evaluate before display. The capture
   shim must match that contract: callers writing Print[Prime[10]] expect "29"
   in the output buffer, not the string "Prime[10]". *)
Tungsten`Private`CapturedPrint[args___] := AppendTo[
    output,
    ToString[SequenceForm[args], OutputForm, PageWidth -> Infinity]
];
Tungsten`Private`Stringify[value_] := Quiet @ Check[
    ToString[Unevaluated[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
Tungsten`Private`HeadStringify[value_] := Quiet @ Check[
    ToString[Head[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
Tungsten`Private`StringList[value_] := If[
    ListQ[value],
    Map[Tungsten`Private`Stringify, value],
    {}
];

heldExpr = Quiet @ Check[ToExpression[userCode, InputForm, HoldComplete], $Failed];
If[
    heldExpr === $Failed,
    Export[
        )WL"
           << wl_path(result_path) << R"WL(,
        <|
            "success" -> False,
            "failure_type" -> "ParseFailure",
            "result" -> "$Failed",
            "result_head" -> "$Failed",
            "messages" -> {},
            "messages_text" -> {},
            "output" -> output,
            "timing" -> Null,
            "absolute_timing" -> Null
        |>,
        "RawJSON"
    ];
    Exit[2];
];
heldExpr = Replace[
    heldExpr,
    HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]
];

evalExpr = If[
    )WL"
           << (require_front_end ? "True" : "False") << R"WL(,
    HoldComplete[UsingFrontEnd[ReleaseHold[heldExpr]]],
    heldExpr
];

ed = Block[
    {Print = Tungsten`Private`CapturedPrint},
    EvaluationData[ReleaseHold[evalExpr]]
];

result = Lookup[ed, "Result", $Failed];
payload = <|
    "success" -> TrueQ[Lookup[ed, "Success", False]],
    "failure_type" -> Replace[
        Lookup[ed, "FailureType", None],
        {
            None -> Null,
            value_ :> Tungsten`Private`Stringify[value]
        }
    ],
    "result" -> Tungsten`Private`Stringify[result],
    "result_head" -> Tungsten`Private`HeadStringify[result],
    "license_processes" -> Quiet @ Check[$LicenseProcesses, Null],
    "max_license_processes" -> Quiet @ Check[$MaxLicenseProcesses, Null],
    "messages" -> Tungsten`Private`StringList[Lookup[ed, "Messages", {}]],
    "messages_text" -> Tungsten`Private`StringList[Lookup[ed, "MessagesText", {}]],
    "output" -> output,
    "timing" -> Replace[Lookup[ed, "Timing", Missing["NotAvailable"]], Missing[__] -> Null],
    "absolute_timing" -> Replace[
        Lookup[ed, "AbsoluteTiming", Missing["NotAvailable"]],
        Missing[__] -> Null
    ]
|>;

Export[)WL"
           << wl_path(result_path) << R"WL(, payload, "RawJSON"];
Exit[0];)WL";
    return script.str();
}

} // namespace tungsten
