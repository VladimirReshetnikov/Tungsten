#include "tungsten/wolfram_processes.hpp"
#include "tungsten/detail/ascii.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <system_error>
#include <thread>
#include <unordered_set>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <csignal>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#endif
#endif

namespace tungsten {
namespace {

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

constexpr std::array<std::string_view, 10> wolfram_process_names{
    "mathkernel",
    "mathkernel.exe",
    "mathematica",
    "mathematica.exe",
    "wolfram",
    "wolfram.exe",
    "wolframdesktop",
    "wolframdesktop.exe",
    "wolframkernel",
    "wolframkernel.exe",
};

#ifdef _WIN32
constexpr std::string_view process_inspection_script = R"PS(
$all = Get-CimInstance Win32_Process | Select-Object `
    Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine,
    @{ Name = "StartedUtc"; Expression = {
        if ($_.CreationDate) {
            [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate).ToUniversalTime().ToString("o")
        }
        else {
            $null
        }
    }}
$all | ConvertTo-Json -Compress -Depth 3
)PS";
#endif

std::string lowercase(std::string_view value) {
    std::string result(value);
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char character) {
        return detail::ascii_lower(character);
    });
    return result;
}

std::string trim(std::string value) {
    const auto non_space = [](unsigned char character) {
        return !detail::ascii_is_space(character);
    };
    const auto first = std::find_if(value.begin(), value.end(), non_space);
    const auto last = std::find_if(value.rbegin(), value.rend(), non_space).base();
    if (first >= last) return {};
    return std::string(first, last);
}

JsonValue optional_string_json(const std::optional<std::string>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

std::optional<std::string> optional_text(const JsonValue* value) {
    if (value == nullptr || value->is_null()) return std::nullopt;
    if (value->is_string()) return value->as_string();
    if (value->is_boolean()) return value->as_boolean() ? "true" : "false";
    if (value->is_number()) return value->as_number().text;
    return value->dump();
}

std::uint32_t unsigned_integer(const JsonValue* value) {
    if (value == nullptr) return 0;
    const auto integer = value->as_uint64();
    if (!integer || *integer > std::numeric_limits<std::uint32_t>::max()) return 0;
    return static_cast<std::uint32_t>(*integer);
}

std::optional<std::uint32_t> positive_process_id(const JsonValue* value) {
    if (value == nullptr) return std::nullopt;
    const auto integer = value->as_uint64();
    if (!integer || *integer == 0
        || *integer > std::numeric_limits<std::uint32_t>::max()) {
        return std::nullopt;
    }
    return static_cast<std::uint32_t>(*integer);
}

bool is_wolfram_process(
    const std::optional<std::string>& name,
    const std::optional<std::string>& executable_path) {
    if (name) {
        const auto normalized = lowercase(*name);
        if (std::find(wolfram_process_names.begin(), wolfram_process_names.end(), normalized)
            != wolfram_process_names.end()) {
            return true;
        }
    }
    return executable_path
        && lowercase(*executable_path).find("wolfram") != std::string::npos;
}

bool is_controlling_process_candidate(
    std::string_view name,
    std::string_view lower_command) {
    const auto normalized = lowercase(name);
    if (normalized == "mathematica" || normalized == "mathematica.exe"
        || normalized == "wolframdesktop" || normalized == "wolframdesktop.exe") {
        return true;
    }
    if (normalized == "wolfram" || normalized == "wolfram.exe"
        || normalized == "wolframkernel" || normalized == "wolframkernel.exe"
        || normalized == "mathkernel" || normalized == "mathkernel.exe") {
        return lower_command.find(" -mathlink ") == std::string_view::npos
            && lower_command.find(" -subkernel ") == std::string_view::npos
            && lower_command.find("playerpass") == std::string_view::npos;
    }
    return false;
}

bool contains_any(
    std::string_view value,
    std::initializer_list<std::string_view> markers) {
    return std::any_of(markers.begin(), markers.end(), [&](std::string_view marker) {
        return value.find(marker) != std::string_view::npos;
    });
}

bool leap_year(std::int64_t year) {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

std::int64_t days_from_civil(
    std::int64_t year,
    std::int64_t month,
    std::int64_t day) {
    year -= month <= 2 ? 1 : 0;
    const auto era = (year >= 0 ? year : year - 399) / 400;
    const auto year_of_era = year - era * 400;
    const auto adjusted_month = month + (month > 2 ? -3 : 9);
    const auto day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    const auto day_of_era = year_of_era * 365 + year_of_era / 4
        - year_of_era / 100 + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

std::array<std::int64_t, 3> civil_from_days(std::int64_t days) {
    const auto shifted = days + 719468;
    const auto era = (shifted >= 0 ? shifted : shifted - 146096) / 146097;
    const auto day_of_era = shifted - era * 146097;
    const auto year_of_era = (day_of_era - day_of_era / 1460
        + day_of_era / 36524 - day_of_era / 146096) / 365;
    auto year = year_of_era + era * 400;
    const auto day_of_year = day_of_era
        - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const auto month_prime = (5 * day_of_year + 2) / 153;
    const auto day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    const auto month = month_prime + (month_prime < 10 ? 3 : -9);
    year += month <= 2 ? 1 : 0;
    return {year, month, day};
}

std::optional<std::int64_t> decimal_field(
    std::string_view value,
    std::size_t offset,
    std::size_t count) noexcept {
    if (offset + count > value.size()) return std::nullopt;
    std::int64_t result = 0;
    for (std::size_t index = offset; index < offset + count; ++index) {
        const auto character = static_cast<unsigned char>(value[index]);
        if (!detail::ascii_is_digit(character)) return std::nullopt;
        result = result * 10 + (character - static_cast<unsigned char>('0'));
    }
    return result;
}

std::optional<double> parse_rfc3339_seconds(std::string_view value) noexcept {
    if (value.size() < 20 || value[4] != '-' || value[7] != '-'
        || value[10] != 'T' || value[13] != ':' || value[16] != ':') {
        return std::nullopt;
    }
    const auto year = decimal_field(value, 0, 4);
    const auto month = decimal_field(value, 5, 2);
    const auto day = decimal_field(value, 8, 2);
    const auto hour = decimal_field(value, 11, 2);
    const auto minute = decimal_field(value, 14, 2);
    const auto second = decimal_field(value, 17, 2);
    if (!year || !month || !day || !hour || !minute || !second) return std::nullopt;
    static constexpr std::array<std::int64_t, 12> month_days{
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (*month < 1 || *month > 12 || *day < 1
        || *day > month_days[static_cast<std::size_t>(*month - 1)]
            + (*month == 2 && leap_year(*year) ? 1 : 0)
        || *hour > 23 || *minute > 59 || *second > 60) {
        return std::nullopt;
    }

    std::size_t cursor = 19;
    double fraction = 0.0;
    if (cursor < value.size() && value[cursor] == '.') {
        ++cursor;
        double place = 0.1;
        const auto fraction_start = cursor;
        while (cursor < value.size()
            && detail::ascii_is_digit(static_cast<unsigned char>(value[cursor]))) {
            fraction += static_cast<double>(value[cursor] - '0') * place;
            place *= 0.1;
            ++cursor;
        }
        if (cursor == fraction_start) return std::nullopt;
    }

    std::int64_t offset = 0;
    if (cursor >= value.size()) return std::nullopt;
    if (value[cursor] == 'Z') {
        ++cursor;
    } else if (value[cursor] == '+' || value[cursor] == '-') {
        const auto sign = value[cursor] == '+' ? 1 : -1;
        const auto offset_hour = decimal_field(value, cursor + 1, 2);
        if (!offset_hour) return std::nullopt;
        std::optional<std::int64_t> offset_minute;
        std::size_t consumed = 0;
        if (cursor + 3 < value.size() && value[cursor + 3] == ':') {
            offset_minute = decimal_field(value, cursor + 4, 2);
            consumed = 6;
        } else {
            offset_minute = decimal_field(value, cursor + 3, 2);
            consumed = 5;
        }
        if (!offset_minute || *offset_hour > 23 || *offset_minute > 59)
            return std::nullopt;
        offset = sign * (*offset_hour * 3600 + *offset_minute * 60);
        cursor += consumed;
    } else {
        return std::nullopt;
    }
    if (cursor != value.size()) return std::nullopt;

    const auto days = days_from_civil(*year, *month, *day);
    return static_cast<double>(days * 86400 + *hour * 3600 + *minute * 60
        + *second - offset) + fraction;
}

std::string format_system_time(std::chrono::system_clock::time_point value) {
    const auto since_epoch = value.time_since_epoch();
    const auto whole_seconds = std::chrono::duration_cast<std::chrono::seconds>(since_epoch);
    auto microseconds = std::chrono::duration_cast<std::chrono::microseconds>(
        since_epoch - whole_seconds).count();
    auto seconds = whole_seconds.count();
    if (microseconds < 0) {
        microseconds += 1000000;
        --seconds;
    }
    const auto days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400;
    const auto daytime = seconds - days * 86400;
    const auto date = civil_from_days(days);
    const auto hour = daytime / 3600;
    const auto minute = daytime % 3600 / 60;
    const auto second = daytime % 60;
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << std::setfill('0') << std::setw(4) << date[0] << '-'
           << std::setw(2) << date[1] << '-' << std::setw(2) << date[2] << 'T'
           << std::setw(2) << hour << ':' << std::setw(2) << minute << ':'
           << std::setw(2) << second;
    if (microseconds != 0) output << '.' << std::setw(6) << microseconds;
    output << 'Z';
    return output.str();
}

fs::path cache_path(const fs::path& root) {
    return root / "wolfram-license-cache.json";
}

void ensure_private_cache_root(const fs::path& root) {
    std::error_code error;
    fs::create_directories(root, error);
    if (error)
        throw fs::filesystem_error(
            "could not create Tungsten cache directory", root, error);
#ifndef _WIN32
    struct stat status {};
    if (::lstat(root.c_str(), &status) != 0)
        throw fs::filesystem_error(
            "could not inspect Tungsten cache directory", root,
            std::error_code(errno, std::generic_category()));
    if (!S_ISDIR(status.st_mode) || status.st_uid != ::geteuid())
        throw WolframProcessError(
            "Tungsten cache directory is not a private directory owned by the current user: "
            + root.u8string());
    if (::chmod(root.c_str(), S_IRWXU) != 0)
        throw fs::filesystem_error(
            "could not secure Tungsten cache directory", root,
            std::error_code(errno, std::generic_category()));
#endif
}

std::string read_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw WolframProcessError("could not open file: " + path.u8string());
    std::string contents{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.eof() && stream.fail())
        throw WolframProcessError("could not read file: " + path.u8string());
    return contents;
}

#ifdef _WIN32
class UniqueHandle {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE value) noexcept : value_(value) {}
    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : value_(other.release()) {}
    UniqueHandle& operator=(UniqueHandle&& other) noexcept {
        if (this != &other) {
            close();
            value_ = other.release();
        }
        return *this;
    }
    ~UniqueHandle() { close(); }

    [[nodiscard]] HANDLE get() const noexcept { return value_; }
    [[nodiscard]] explicit operator bool() const noexcept {
        return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
    }
    HANDLE release() noexcept {
        const auto value = value_;
        value_ = nullptr;
        return value;
    }
    bool close() noexcept {
        if (!*this) {
            value_ = nullptr;
            return true;
        }
        const auto value = release();
        return CloseHandle(value) != 0;
    }

private:
    HANDLE value_ = nullptr;
};
#endif

void write_file(const fs::path& path, std::string_view contents) {
    static std::atomic<std::uint64_t> sequence{0};
#ifdef _WIN32
    const auto process_id = static_cast<std::uint64_t>(GetCurrentProcessId());
#else
    const auto process_id = static_cast<std::uint64_t>(::getpid());
#endif
    const auto temporary = path.parent_path()
        / (path.filename().u8string() + ".tmp-" + std::to_string(process_id)
            + "-" + std::to_string(sequence.fetch_add(1)));

#ifdef _WIN32
    UniqueHandle file(CreateFileW(
        temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_TEMPORARY, nullptr));
    if (!file)
        throw WolframProcessError("could not create file: " + temporary.u8string());
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto count = static_cast<DWORD>(std::min<std::size_t>(
            contents.size() - offset, std::numeric_limits<DWORD>::max()));
        DWORD written = 0;
        if (WriteFile(file.get(), contents.data() + offset, count, &written, nullptr) == 0
            || written == 0) {
            file.close();
            DeleteFileW(temporary.c_str());
            throw WolframProcessError("could not write file: " + temporary.u8string());
        }
        offset += written;
    }
    const auto flushed = FlushFileBuffers(file.get()) != 0;
    const auto closed = file.close();
    if (!flushed || !closed) {
        DeleteFileW(temporary.c_str());
        throw WolframProcessError("could not flush file: " + temporary.u8string());
    }
    if (MoveFileExW(
            temporary.c_str(), path.c_str(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)
        == 0) {
        DeleteFileW(temporary.c_str());
        throw WolframProcessError("could not replace file: " + path.u8string());
    }
#else
    int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    const int file = ::open(temporary.c_str(), flags, S_IRUSR | S_IWUSR);
    if (file < 0)
        throw WolframProcessError(
            "could not create file: " + temporary.u8string() + ": "
            + std::error_code(errno, std::generic_category()).message());
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto written = ::write(
            file, contents.data() + offset, contents.size() - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            const auto error = std::error_code(
                written < 0 ? errno : EIO, std::generic_category());
            ::close(file);
            ::unlink(temporary.c_str());
            throw WolframProcessError(
                "could not write file: " + temporary.u8string() + ": "
                + error.message());
        }
        offset += static_cast<std::size_t>(written);
    }
    int flush_error = 0;
    if (::fsync(file) != 0) flush_error = errno;
    if (::close(file) != 0 && flush_error == 0) flush_error = errno;
    if (flush_error != 0) {
        const auto error = std::error_code(flush_error, std::generic_category());
        ::unlink(temporary.c_str());
        throw WolframProcessError(
            "could not flush file: " + temporary.u8string() + ": "
            + error.message());
    }
    if (::rename(temporary.c_str(), path.c_str()) != 0) {
        const auto error = std::error_code(errno, std::generic_category());
        ::unlink(temporary.c_str());
        throw WolframProcessError(
            "could not replace file: " + path.u8string() + ": "
            + error.message());
    }
#endif
}

#ifdef _WIN32

struct WindowsCommandResult {
    unsigned long exit_code = 0;
    std::string output;
    bool timed_out = false;
};

std::wstring widen_ascii(std::string_view value) {
    return std::wstring(value.begin(), value.end());
}

std::wstring quote_windows_argument(std::wstring_view argument) {
    if (argument.empty()) return L"\"\"";
    if (argument.find_first_of(L" \t\n\v\"") == std::wstring_view::npos)
        return std::wstring(argument);
    std::wstring result(1, L'\"');
    std::size_t backslashes = 0;
    for (wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
        } else if (character == L'\"') {
            result.append(backslashes * 2 + 1, L'\\');
            result.push_back(L'\"');
            backslashes = 0;
        } else {
            result.append(backslashes, L'\\');
            backslashes = 0;
            result.push_back(character);
        }
    }
    result.append(backslashes * 2, L'\\');
    result.push_back(L'\"');
    return result;
}

void drain_pipe(HANDLE pipe, std::string& output) {
    for (;;) {
        DWORD available = 0;
        if (PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr) == 0
            || available == 0) {
            return;
        }
        std::array<char, 4096> buffer{};
        DWORD read = 0;
        const auto requested = static_cast<DWORD>(
            std::min<std::size_t>(buffer.size(), available));
        if (ReadFile(pipe, buffer.data(), requested, &read, nullptr) == 0 || read == 0)
            return;
        output.append(buffer.data(), read);
    }
}

std::optional<WindowsCommandResult> run_windows_command(
    std::wstring_view executable,
    const std::vector<std::wstring>& arguments,
    std::chrono::milliseconds timeout) {
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;
    HANDLE raw_read_pipe = nullptr;
    HANDLE raw_write_pipe = nullptr;
    if (CreatePipe(&raw_read_pipe, &raw_write_pipe, &security, 0) == 0)
        throw WolframProcessError("could not create a process output pipe");
    UniqueHandle read_pipe(raw_read_pipe);
    UniqueHandle write_pipe(raw_write_pipe);
    if (SetHandleInformation(read_pipe.get(), HANDLE_FLAG_INHERIT, 0) == 0) {
        throw WolframProcessError("could not configure a process output pipe");
    }

    std::wstring command_line = quote_windows_argument(executable);
    for (const auto& argument : arguments) {
        command_line.push_back(L' ');
        command_line += quote_windows_argument(argument);
    }
    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = write_pipe.get();
    startup.hStdError = write_pipe.get();
    PROCESS_INFORMATION process{};
    const auto created = CreateProcessW(
        nullptr,
        mutable_command.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr,
        nullptr,
        &startup,
        &process);
    write_pipe.close();
    if (created == 0) return std::nullopt;

    UniqueHandle process_handle(process.hProcess);
    UniqueHandle thread_handle(process.hThread);

    WindowsCommandResult result;
    const auto start = Clock::now();
    for (;;) {
        drain_pipe(read_pipe.get(), result.output);
        const auto wait = WaitForSingleObject(process_handle.get(), 10);
        if (wait == WAIT_OBJECT_0) break;
        if (wait == WAIT_FAILED) {
            TerminateProcess(process_handle.get(), 1);
            WaitForSingleObject(process_handle.get(), INFINITE);
            throw WolframProcessError("failed while waiting for a child process");
        }
        if (Clock::now() - start >= timeout) {
            result.timed_out = true;
            TerminateProcess(process_handle.get(), 1);
            WaitForSingleObject(process_handle.get(), INFINITE);
            break;
        }
    }
    drain_pipe(read_pipe.get(), result.output);
    DWORD exit_code = 1;
    if (GetExitCodeProcess(process_handle.get(), &exit_code) == 0)
        throw WolframProcessError("could not read a child process exit code");
    result.exit_code = exit_code;
    return result;
}

std::string base64_encode(const std::vector<unsigned char>& source) {
    static constexpr std::string_view alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    result.reserve((source.size() + 2) / 3 * 4);
    for (std::size_t index = 0; index < source.size(); index += 3) {
        const auto remaining = source.size() - index;
        const auto value = static_cast<unsigned>(source[index]) << 16
            | (remaining > 1 ? static_cast<unsigned>(source[index + 1]) << 8 : 0)
            | (remaining > 2 ? static_cast<unsigned>(source[index + 2]) : 0);
        result.push_back(alphabet[(value >> 18) & 63]);
        result.push_back(alphabet[(value >> 12) & 63]);
        result.push_back(remaining > 1 ? alphabet[(value >> 6) & 63] : '=');
        result.push_back(remaining > 2 ? alphabet[value & 63] : '=');
    }
    return result;
}

std::string powershell_encoded_command(std::string_view script) {
    const std::string prefix =
        "$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);";
    const auto command = prefix + std::string(script);
    std::vector<unsigned char> utf16le;
    utf16le.reserve(command.size() * 2);
    for (unsigned char character : command) {
        utf16le.push_back(character);
        utf16le.push_back(0);
    }
    return base64_encode(utf16le);
}

std::optional<std::wstring> powershell_executable() {
    for (const auto* candidate : {L"pwsh", L"powershell"}) {
        const auto result = run_windows_command(
            candidate,
            {L"-NoLogo", L"-NoProfile", L"-Command",
             L"$PSVersionTable.PSVersion.ToString()"},
            std::chrono::seconds(5));
        if (result && !result->timed_out && result->exit_code == 0)
            return std::wstring(candidate);
    }
    return std::nullopt;
}

bool terminate_process_tree(std::uint32_t pid) {
    if (pid == 0) return false;
    const auto result = run_windows_command(
        L"taskkill",
        {L"/PID", std::to_wstring(pid), L"/T", L"/F"},
        std::chrono::seconds(15));
    return result && !result->timed_out && result->exit_code == 0;
}

#else

std::optional<std::string> read_optional_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return std::nullopt;
    std::string contents{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.eof() && stream.fail()) return std::nullopt;
    return contents;
}

JsonValue posix_process_row(
    std::uint32_t pid,
    std::uint32_t parent_pid,
    std::string name,
    std::optional<std::string> executable,
    std::optional<std::string> command,
    std::optional<std::string> started) {
    return JsonValue::object({
        {"Name", decode_utf8_lossy(name)},
        {"ProcessId", pid},
        {"ParentProcessId", parent_pid},
        {"ExecutablePath", executable
            ? JsonValue(decode_utf8_lossy(*executable)) : JsonValue()},
        {"CommandLine", command
            ? JsonValue(decode_utf8_lossy(*command)) : JsonValue()},
        {"StartedUtc", started ? JsonValue(*started) : JsonValue()},
    });
}

#ifdef __linux__

struct LinuxProcessStat {
    std::uint32_t parent_pid = 0;
    std::uint64_t start_ticks = 0;
};

std::optional<LinuxProcessStat> linux_process_stat(const fs::path& path) {
    const auto contents = read_optional_file(path);
    if (!contents) return std::nullopt;
    const auto name_end = contents->rfind(')');
    if (name_end == std::string::npos || name_end + 2 >= contents->size())
        return std::nullopt;
    std::istringstream fields(contents->substr(name_end + 2));
    std::vector<std::string> values;
    for (std::string value; fields >> value;) values.push_back(std::move(value));
    // The first token after the executable name is field 3 (state).  Parent
    // PID is field 4 and process start ticks are field 22.
    if (values.size() <= 19) return std::nullopt;
    try {
        const auto parent = std::stoull(values[1]);
        const auto start = std::stoull(values[19]);
        if (parent > std::numeric_limits<std::uint32_t>::max())
            return std::nullopt;
        return LinuxProcessStat{
            static_cast<std::uint32_t>(parent), start};
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<double> linux_uptime_seconds() {
    const auto contents = read_optional_file("/proc/uptime");
    if (!contents) return std::nullopt;
    std::istringstream input(*contents);
    input.imbue(std::locale::classic());
    double value = 0.0;
    if (!(input >> value) || value < 0.0) return std::nullopt;
    return value;
}

std::vector<WolframProcessInfo> list_posix_wolfram_processes() {
    const auto uptime = linux_uptime_seconds();
    const auto ticks_per_second = ::sysconf(_SC_CLK_TCK);
    JsonValue::Array rows;
    std::error_code error;
    fs::directory_iterator iterator(
        "/proc", fs::directory_options::skip_permission_denied, error);
    const fs::directory_iterator end;
    for (; !error && iterator != end; iterator.increment(error)) {
        const auto process_text = iterator->path().filename().string();
        if (process_text.empty()
            || !std::all_of(process_text.begin(), process_text.end(),
                [](unsigned char character) {
                    return detail::ascii_is_digit(character);
                })) {
            continue;
        }
        std::uint64_t parsed_pid = 0;
        try {
            parsed_pid = std::stoull(process_text);
        } catch (...) {
            continue;
        }
        if (parsed_pid > std::numeric_limits<std::uint32_t>::max()) continue;
        const auto pid = static_cast<std::uint32_t>(parsed_pid);
        const auto process_root = iterator->path();
        auto name = read_optional_file(process_root / "comm").value_or("");
        name = trim(std::move(name));
        auto command = read_optional_file(process_root / "cmdline");
        if (command) {
            std::replace(command->begin(), command->end(), '\0', ' ');
            *command = trim(std::move(*command));
            if (command->empty()) command.reset();
        }
        std::optional<std::string> executable;
        const auto target = fs::read_symlink(process_root / "exe", error);
        if (!error) executable = target.u8string();
        error.clear();

        const auto status = linux_process_stat(process_root / "stat");
        std::optional<std::string> started;
        if (status && uptime && ticks_per_second > 0) {
            const auto age = *uptime
                - static_cast<double>(status->start_ticks)
                    / static_cast<double>(ticks_per_second);
            if (age >= 0.0) {
                const auto point = std::chrono::time_point_cast<
                    std::chrono::system_clock::duration>(
                    std::chrono::system_clock::now()
                    - std::chrono::duration<double>(age));
                started = format_system_time(point);
            }
        }
        rows.push_back(posix_process_row(
            pid, status ? status->parent_pid : 0, std::move(name),
            std::move(executable), std::move(command), std::move(started)));
    }
    return normalize_wolfram_process_payload(JsonValue(std::move(rows)));
}

#elif defined(__APPLE__)

std::optional<std::string> mac_process_command(int pid) {
    int names[]{CTL_KERN, KERN_PROCARGS2, pid};
    std::size_t size = 0;
    if (::sysctl(names, 3, nullptr, &size, nullptr, 0) != 0 || size <= sizeof(int))
        return std::nullopt;
    std::vector<char> buffer(size);
    if (::sysctl(names, 3, buffer.data(), &size, nullptr, 0) != 0
        || size <= sizeof(int)) return std::nullopt;
    int argument_count = 0;
    std::memcpy(&argument_count, buffer.data(), sizeof(argument_count));
    if (argument_count <= 0) return std::nullopt;
    std::size_t cursor = sizeof(argument_count);
    while (cursor < size && buffer[cursor] != '\0') ++cursor;
    while (cursor < size && buffer[cursor] == '\0') ++cursor;
    std::string command;
    for (int index = 0; index < argument_count && cursor < size; ++index) {
        const auto start = cursor;
        while (cursor < size && buffer[cursor] != '\0') ++cursor;
        if (cursor > start) {
            if (!command.empty()) command.push_back(' ');
            command.append(buffer.data() + start, cursor - start);
        }
        while (cursor < size && buffer[cursor] == '\0') ++cursor;
    }
    return command.empty() ? std::nullopt
                           : std::optional<std::string>(std::move(command));
}

std::vector<WolframProcessInfo> list_posix_wolfram_processes() {
    const int estimate = ::proc_listallpids(nullptr, 0);
    if (estimate <= 0) return {};
    std::vector<pid_t> pids(static_cast<std::size_t>(estimate) + 64);
    if (pids.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())
            / sizeof(pid_t))
        return {};
    const int count = ::proc_listallpids(
        pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (count <= 0) return {};
    JsonValue::Array rows;
    for (int index = 0;
         index < count && static_cast<std::size_t>(index) < pids.size(); ++index) {
        const auto pid = pids[static_cast<std::size_t>(index)];
        if (pid <= 0) continue;
        proc_bsdinfo info{};
        if (::proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info))
            != sizeof(info)) continue;
        std::array<char, PROC_PIDPATHINFO_MAXSIZE> executable_buffer{};
        std::optional<std::string> executable;
        const int path_size = ::proc_pidpath(
            pid, executable_buffer.data(),
            static_cast<std::uint32_t>(executable_buffer.size()));
        if (path_size > 0)
            executable = std::string(
                executable_buffer.data(), static_cast<std::size_t>(path_size));
        const auto started = std::chrono::system_clock::time_point(
            std::chrono::seconds(info.pbi_start_tvsec)
            + std::chrono::microseconds(info.pbi_start_tvusec));
        rows.push_back(posix_process_row(
            static_cast<std::uint32_t>(pid), info.pbi_ppid,
            std::string(info.pbi_name), std::move(executable),
            mac_process_command(pid), format_system_time(started)));
    }
    return normalize_wolfram_process_payload(JsonValue(std::move(rows)));
}

#else

std::vector<WolframProcessInfo> list_posix_wolfram_processes() { return {}; }

#endif

bool terminate_process_tree(std::uint32_t pid) {
    if (pid == 0
        || static_cast<std::uintmax_t>(pid)
            > static_cast<std::uintmax_t>(std::numeric_limits<pid_t>::max())) {
        return false;
    }
    const auto native_pid = static_cast<pid_t>(pid);
    if (::kill(native_pid, SIGTERM) != 0) return errno == ESRCH;
    for (int attempt = 0; attempt < 20; ++attempt) {
        if (::kill(native_pid, 0) != 0 && errno == ESRCH) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (::kill(native_pid, SIGKILL) != 0 && errno != ESRCH) return false;
    return true;
}

#endif

} // namespace

WolframLaunchGateTimeout::WolframLaunchGateTimeout()
    : WolframProcessError("Timed out waiting for the Tungsten Wolfram launch gate.") {}

std::optional<double> WolframProcessInfo::age_seconds() const noexcept {
    if (!started_utc) return std::nullopt;
    const auto started = parse_rfc3339_seconds(*started_utc);
    if (!started) return std::nullopt;
    const auto now = std::chrono::duration<double>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return std::max(0.0, now - *started);
}

JsonValue WolframProcessInfo::to_json() const {
    const auto age = age_seconds();
    return JsonValue::object({
        {"pid", pid},
        {"parent_pid", parent_pid},
        {"name", name},
        {"executable_path", optional_string_json(executable_path)},
        {"command_line", optional_string_json(command_line)},
        {"started_utc", optional_string_json(started_utc)},
        {"tungsten_owned", tungsten_owned},
        {"headless_batch", headless_batch},
        {"parent_missing", parent_missing},
        {"controlling_process_candidate", controlling_process_candidate},
        {"age_seconds", age ? JsonValue(*age) : JsonValue()},
    });
}

std::size_t WolframProcessSnapshot::active_count() const noexcept {
    return static_cast<std::size_t>(std::count_if(
        processes.begin(), processes.end(), [](const WolframProcessInfo& process) {
            return process.controlling_process_candidate;
        }));
}

JsonValue WolframProcessSnapshot::to_json() const {
    JsonValue::Array values;
    values.reserve(processes.size());
    for (const auto& process : processes) values.push_back(process.to_json());
    return JsonValue::object({
        {"cached_max_license_processes", cached_max_license_processes
            ? JsonValue(*cached_max_license_processes) : JsonValue()},
        {"active_count", active_count()},
        {"processes", JsonValue(std::move(values))},
    });
}

fs::path wolfram_process_cache_root() {
    return wolfram_process_cache_root(DiscoveryEnvironment::current());
}

fs::path wolfram_process_cache_root(const DiscoveryEnvironment& environment) {
    if (environment.local_app_data) return *environment.local_app_data / "Tungsten";
#ifndef _WIN32
    if (environment.home) {
#ifdef __APPLE__
        return *environment.home / "Library" / "Caches" / "Tungsten";
#else
        return *environment.home / ".cache" / "Tungsten";
#endif
    }
    return fs::temp_directory_path()
        / ("Tungsten-" + std::to_string(static_cast<unsigned long long>(::geteuid())));
#else
    return fs::temp_directory_path() / "Tungsten";
#endif
}

std::optional<std::uint32_t> read_cached_max_license_processes() {
    return read_cached_max_license_processes_at(wolfram_process_cache_root());
}

std::optional<std::uint32_t> read_cached_max_license_processes_at(
    const fs::path& root) {
    try {
        const auto payload = JsonValue::parse(read_file(cache_path(root)));
        if (!payload.is_object()) return std::nullopt;
        const auto* value = payload.find("max_license_processes");
        if (value == nullptr) return std::nullopt;
        const auto integer = value->as_uint64();
        if (!integer || *integer == 0
            || *integer > std::numeric_limits<std::uint32_t>::max()) {
            return std::nullopt;
        }
        return static_cast<std::uint32_t>(*integer);
    } catch (...) {
        return std::nullopt;
    }
}

void write_cached_max_license_processes(std::uint32_t value) {
    write_cached_max_license_processes_at(wolfram_process_cache_root(), value);
}

void write_cached_max_license_processes_at(
    const fs::path& root,
    std::uint32_t value) {
    if (value == 0) return;
    const auto path = cache_path(root);
    ensure_private_cache_root(root);
    auto contents = JsonValue::object({
        {"max_license_processes", value},
        {"updated_utc", utc_now_string()},
    }).dump_pretty(2);
    contents.push_back('\n');
    write_file(path, contents);
}

std::string utc_now_string() {
    return format_system_time(std::chrono::system_clock::now());
}

std::vector<WolframProcessInfo> normalize_wolfram_process_payload(
    const JsonValue& payload) {
    std::vector<const JsonValue::Object*> rows;
    if (payload.is_array()) {
        for (const auto& value : payload.as_array()) {
            if (value.is_object()) rows.push_back(&value.as_object());
        }
    } else if (payload.is_object()) {
        rows.push_back(&payload.as_object());
    }

    std::unordered_set<std::uint32_t> live_pids;
    for (const auto* row : rows) {
        const auto found = row->find("ProcessId");
        if (found == row->end()) continue;
        if (const auto pid = positive_process_id(&found->second))
            live_pids.insert(*pid);
    }

    std::vector<WolframProcessInfo> processes;
    for (const auto* row : rows) {
        const auto find = [&](std::string_view key) -> const JsonValue* {
            const auto found = row->find(std::string(key));
            return found == row->end() ? nullptr : &found->second;
        };
        const auto pid = positive_process_id(find("ProcessId"));
        if (!pid) continue;
        auto name = optional_text(find("Name"));
        auto executable_path = optional_text(find("ExecutablePath"));
        if (!is_wolfram_process(name, executable_path)) continue;
        auto command_line = optional_text(find("CommandLine"));
        const auto lower_command = lowercase(command_line.value_or(""));
        const auto parent_pid = unsigned_integer(find("ParentProcessId"));
        const auto normalized_name = name.value_or("None");
        processes.push_back({
            *pid,
            parent_pid,
            normalized_name,
            std::move(executable_path),
            std::move(command_line),
            optional_text(find("StartedUtc")),
            contains_any(lower_command, {"tungsten-wrapper-", "tungsten-mathpass-"}),
            contains_any(lower_command, {" -script ", " -run ", " -runfile "}),
            parent_pid > 0 && live_pids.find(parent_pid) == live_pids.end(),
            is_controlling_process_candidate(normalized_name, lower_command),
        });
    }
    std::sort(processes.begin(), processes.end(), [](const auto& left, const auto& right) {
        return left.pid < right.pid;
    });
    return processes;
}

std::vector<WolframProcessInfo> list_wolfram_processes() {
#ifndef _WIN32
    return list_posix_wolfram_processes();
#else
    const auto powershell = powershell_executable();
    if (!powershell)
        throw WolframProcessError(
            "Could not find PowerShell for Wolfram process inspection.");
    const auto encoded = widen_ascii(powershell_encoded_command(process_inspection_script));
    const auto result = run_windows_command(
        *powershell,
        {L"-NoLogo", L"-NoProfile", L"-NonInteractive", L"-EncodedCommand", encoded},
        std::chrono::seconds(15));
    if (!result)
        throw WolframProcessError("PowerShell process inspection could not be started.");
    if (result->timed_out)
        throw WolframProcessError("PowerShell process inspection timed out.");
    if (result->exit_code != 0)
        throw WolframProcessError(
            "PowerShell process inspection failed: " + trim(result->output));
    const auto raw = trim(result->output);
    return raw.empty()
        ? std::vector<WolframProcessInfo>{}
        : normalize_wolfram_process_payload(JsonValue::parse(raw));
#endif
}

WolframProcessSnapshot snapshot_wolfram_processes() {
    return {list_wolfram_processes(), read_cached_max_license_processes()};
}

std::vector<std::uint32_t> cleanup_stale_tungsten_processes(
    double min_age_seconds) {
    const auto processes = list_wolfram_processes();
    return cleanup_stale_processes_with(
        processes,
        min_age_seconds,
        [](std::uint32_t pid) {
            return terminate_process_tree(pid);
        });
}

std::vector<std::uint32_t> cleanup_stale_processes_with(
    const std::vector<WolframProcessInfo>& processes,
    double min_age_seconds,
    const WolframProcessTerminator& terminate) {
    if (!terminate) throw std::invalid_argument("process terminator must be callable");
    std::vector<std::uint32_t> cleaned;
    for (const auto& process : processes) {
        if (!process.tungsten_owned || !process.headless_batch || !process.parent_missing)
            continue;
        if (process.pid == 0) continue;
        const auto age = process.age_seconds();
        if (age && *age < min_age_seconds) continue;
        if (terminate(process.pid)) cleaned.push_back(process.pid);
    }
    return cleaned;
}

struct WolframLaunchGate::State {
#ifdef _WIN32
    HANDLE file = INVALID_HANDLE_VALUE;
    OVERLAPPED range{};
    bool locked = false;

    ~State() {
        if (file == INVALID_HANDLE_VALUE) return;
        if (locked) UnlockFileEx(file, 0, 1, 0, &range);
        CloseHandle(file);
    }
#else
    int file = -1;
    bool locked = false;

    ~State() {
        if (file < 0) return;
        if (locked) ::flock(file, LOCK_UN);
        ::close(file);
    }
#endif
};

WolframLaunchGate WolframLaunchGate::acquire(
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds poll,
    std::optional<fs::path> requested_cache_root) {
#ifndef _WIN32
    const auto root = requested_cache_root.value_or(wolfram_process_cache_root());
    ensure_private_cache_root(root);
    const auto lock_path = root / "wolfram-launch.lock";
    int flags = O_RDWR | O_CREAT;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    auto state = std::make_unique<State>();
    state->file = ::open(lock_path.c_str(), flags, S_IRUSR | S_IWUSR);
    if (state->file < 0)
        throw WolframProcessError(
            "could not open the Tungsten Wolfram launch gate: "
            + std::error_code(errno, std::generic_category()).message());
    if (::fchmod(state->file, S_IRUSR | S_IWUSR) != 0)
        throw WolframProcessError(
            "could not secure the Tungsten Wolfram launch gate: "
            + std::error_code(errno, std::generic_category()).message());

    const auto start = Clock::now();
    for (;;) {
        if (::flock(state->file, LOCK_EX | LOCK_NB) == 0) {
            state->locked = true;
            return WolframLaunchGate(
                std::move(state),
                std::chrono::duration<double>(Clock::now() - start).count());
        }
        if (errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR)
            throw WolframProcessError(
                "could not lock the Tungsten Wolfram launch gate: "
                + std::error_code(errno, std::generic_category()).message());
        if (Clock::now() - start >= timeout) throw WolframLaunchGateTimeout();
        if (poll > std::chrono::milliseconds::zero()) std::this_thread::sleep_for(poll);
        else std::this_thread::yield();
    }
#else
    const auto root = requested_cache_root.value_or(wolfram_process_cache_root());
    const auto lock_path = root / "wolfram-launch.lock";
    ensure_parent_directory(lock_path);
    auto state = std::make_unique<State>();
    state->file = CreateFileW(
        lock_path.c_str(),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (state->file == INVALID_HANDLE_VALUE)
        throw WolframProcessError("could not open the Tungsten Wolfram launch gate");

    LARGE_INTEGER size{};
    if (GetFileSizeEx(state->file, &size) != 0 && size.QuadPart == 0) {
        const char marker = '0';
        DWORD written = 0;
        WriteFile(state->file, &marker, 1, &written, nullptr);
        FlushFileBuffers(state->file);
    }

    const auto start = Clock::now();
    for (;;) {
        state->range = {};
        if (LockFileEx(
                state->file,
                LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                0,
                1,
                0,
                &state->range) != 0) {
            state->locked = true;
            return WolframLaunchGate(
                std::move(state),
                std::chrono::duration<double>(Clock::now() - start).count());
        }
        const auto error = GetLastError();
        if (error != ERROR_LOCK_VIOLATION && error != ERROR_IO_PENDING)
            throw WolframProcessError("could not lock the Tungsten Wolfram launch gate");
        if (Clock::now() - start >= timeout) throw WolframLaunchGateTimeout();
        if (poll > std::chrono::milliseconds::zero()) std::this_thread::sleep_for(poll);
        else std::this_thread::yield();
    }
#endif
}

WolframLaunchGate::WolframLaunchGate(
    std::unique_ptr<State> state,
    double waited_seconds)
    : state_(std::move(state)), waited_seconds_(waited_seconds) {}

WolframLaunchGate::WolframLaunchGate(WolframLaunchGate&& other) noexcept
    : state_(std::move(other.state_)), waited_seconds_(other.waited_seconds_) {
    other.waited_seconds_ = 0.0;
}

WolframLaunchGate& WolframLaunchGate::operator=(WolframLaunchGate&& other) noexcept {
    if (this == &other) return *this;
    state_ = std::move(other.state_);
    waited_seconds_ = other.waited_seconds_;
    other.waited_seconds_ = 0.0;
    return *this;
}

WolframLaunchGate::~WolframLaunchGate() = default;

double WolframLaunchGate::waited_seconds() const noexcept {
    return waited_seconds_;
}

WolframLicenseSlotWaitResult wait_for_wolfram_license_slot(
    std::optional<std::uint32_t> cached_max_license_processes,
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds poll) {
    return wait_for_wolfram_license_slot_with(
        cached_max_license_processes,
        timeout,
        poll,
        [] { return snapshot_wolfram_processes(); },
        [](std::chrono::milliseconds duration) {
            if (duration > std::chrono::milliseconds::zero())
                std::this_thread::sleep_for(duration);
            else
                std::this_thread::yield();
        });
}

WolframLicenseSlotWaitResult wait_for_wolfram_license_slot_with(
    std::optional<std::uint32_t> cached_max_license_processes,
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds poll,
    const WolframSnapshotProvider& snapshot,
    const WolframSleepFunction& sleep) {
    if (!snapshot) throw std::invalid_argument("snapshot provider must be callable");
    if (!sleep) throw std::invalid_argument("sleep function must be callable");
    const auto start = Clock::now();
    auto current = snapshot();
    if (!cached_max_license_processes
        || current.active_count() < *cached_max_license_processes) {
        return {std::move(current), 0.0, true};
    }
    for (;;) {
        const auto elapsed = Clock::now() - start;
        if (elapsed >= timeout) {
            return {
                std::move(current),
                std::chrono::duration<double>(elapsed).count(),
                false,
            };
        }
        sleep(poll);
        current = snapshot();
        if (current.active_count() < *cached_max_license_processes) {
            return {
                std::move(current),
                std::chrono::duration<double>(Clock::now() - start).count(),
                true,
            };
        }
    }
}

} // namespace tungsten
