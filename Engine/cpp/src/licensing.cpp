#include "tungsten/licensing.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <fstream>
#include <set>
#include <stdexcept>
#include <system_error>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace tungsten {
namespace {

namespace fs = std::filesystem;

std::string path_text(const fs::path& path) { return path.u8string(); }

bool path_exists(const fs::path& path) {
    std::error_code error;
    return fs::exists(path, error);
}

std::string read_binary_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("could not open mathpass file: " + path_text(path));
    std::string contents{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.eof() && stream.fail())
        throw std::runtime_error("could not read mathpass file: " + path_text(path));
    return contents;
}

std::vector<std::string> split_lines(const std::string& contents) {
    std::vector<std::string> lines;
    std::size_t start = 0;
    std::size_t position = 0;
    while (position < contents.size()) {
        std::size_t break_size = 0;
        const auto byte = static_cast<unsigned char>(contents[position]);
        if (byte == '\r') {
            break_size = position + 1 < contents.size()
                    && contents[position + 1] == '\n'
                ? 2
                : 1;
        } else if (byte == '\n' || byte == '\v' || byte == '\f'
            || byte == 0x1c || byte == 0x1d || byte == 0x1e) {
            break_size = 1;
        } else if (position + 1 < contents.size()
            && byte == 0xc2
            && static_cast<unsigned char>(contents[position + 1]) == 0x85) {
            break_size = 2; // U+0085 NEXT LINE
        } else if (position + 2 < contents.size()
            && byte == 0xe2
            && static_cast<unsigned char>(contents[position + 1]) == 0x80
            && (static_cast<unsigned char>(contents[position + 2]) == 0xa8
                || static_cast<unsigned char>(contents[position + 2]) == 0xa9)) {
            break_size = 3; // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR
        }
        if (break_size == 0) {
            ++position;
            continue;
        }
        lines.push_back(contents.substr(start, position - start));
        position += break_size;
        start = position;
    }
    // str.splitlines() omits a final empty element when the text ends in a
    // line boundary, but preserves empty elements between adjacent boundaries.
    if (start < contents.size()) lines.push_back(contents.substr(start));
    return lines;
}

std::vector<std::string> read_lossy_lines(const fs::path& path) {
    return split_lines(decode_utf8_lossy(read_binary_file(path)));
}

std::vector<std::string> stable_unique(
    const std::vector<std::string>& lines,
    std::size_t first) {
    std::set<std::string> seen;
    std::vector<std::string> output;
    for (std::size_t index = first; index < lines.size(); ++index) {
        if (seen.insert(lines[index]).second) output.push_back(lines[index]);
    }
    return output;
}

MathpassInspection inspection_for_lines(
    const fs::path& path,
    const std::vector<std::string>& lines) {
    const bool header = !lines.empty() && !lines.front().empty() && lines.front()[0] == '%';
    const auto first = header ? std::size_t{1} : std::size_t{0};
    const auto unique = stable_unique(lines, first);
    const auto entry_count = lines.size() - first;
    return {
        path_text(path),
        header,
        lines.size(),
        unique.size(),
        entry_count > unique.size() ? entry_count - unique.size() : 0,
    };
}

void write_text_file(const fs::path& path, const std::string& contents) {
#ifdef _WIN32
    // The per-user Windows temporary directory supplies the restrictive ACL.
    // Keep the filesystem path overload so non-ASCII paths use wide Win32 I/O.
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("could not create mathpass file: " + path_text(path));
    stream.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    if (!stream) throw std::runtime_error("could not write mathpass file: " + path_text(path));
#else
    int flags = O_WRONLY | O_CREAT | O_TRUNC;
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    const int descriptor = ::open(path.c_str(), flags, S_IRUSR | S_IWUSR);
    if (descriptor < 0)
        throw std::runtime_error(
            "could not create mathpass file: " + path_text(path) + ": "
            + std::error_code(errno, std::generic_category()).message());
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto written = ::write(
            descriptor, contents.data() + offset, contents.size() - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            const auto error = std::error_code(
                written < 0 ? errno : EIO, std::generic_category());
            ::close(descriptor);
            throw std::runtime_error(
                "could not write mathpass file: " + path_text(path) + ": "
                + error.message());
        }
        offset += static_cast<std::size_t>(written);
    }
    if (::close(descriptor) != 0)
        throw std::runtime_error(
            "could not close mathpass file: " + path_text(path) + ": "
            + std::error_code(errno, std::generic_category()).message());
#endif
}

fs::path unique_temp_directory(std::string_view prefix) {
    const auto timestamp = std::chrono::high_resolution_clock::now()
        .time_since_epoch().count();
    const auto root = fs::temp_directory_path();
    for (std::size_t nonce = 0; nonce < 1000; ++nonce) {
        const auto candidate = root
            / (std::string(prefix) + "-" + std::to_string(timestamp) + "-"
                + std::to_string(nonce));
#ifdef _WIN32
        std::error_code error;
        if (fs::create_directory(candidate, error)) return candidate;
        if (error && error != std::errc::file_exists)
            throw fs::filesystem_error("could not create temporary directory", candidate, error);
#else
        if (::mkdir(candidate.c_str(), S_IRWXU) == 0) return candidate;
        if (errno != EEXIST)
            throw fs::filesystem_error("could not create temporary directory", candidate,
                std::error_code(errno, std::generic_category()));
#endif
    }
    throw std::runtime_error("could not allocate a unique Tungsten temporary directory");
}

} // namespace

JsonValue MathpassInspection::to_json() const {
    return JsonValue::object({
        {"path", path ? JsonValue(*path) : JsonValue()},
        {"header_present", header_present},
        {"original_line_count", original_line_count},
        {"unique_entry_count", unique_entry_count},
        {"duplicate_entry_count", duplicate_entry_count},
    });
}

MathpassInspection inspect_mathpass(const std::optional<fs::path>& path) {
    if (!path || !path_exists(*path)) return {};
    return inspection_for_lines(*path, read_lossy_lines(*path));
}

MathpassInspection write_deduped_mathpass(
    const fs::path& source,
    const fs::path& destination) {
    const auto lines = read_lossy_lines(source);
    const bool header = !lines.empty() && !lines.front().empty() && lines.front()[0] == '%';
    const auto first = header ? std::size_t{1} : std::size_t{0};
    const auto unique = stable_unique(lines, first);

    std::vector<std::string> output_lines;
    if (header) output_lines.push_back(lines.front());
    output_lines.insert(output_lines.end(), unique.begin(), unique.end());
    output_lines.emplace_back();
    std::string output;
    for (std::size_t index = 0; index < output_lines.size(); ++index) {
        if (index) output.push_back('\n');
        output += output_lines[index];
    }
    write_text_file(destination, output);
    return inspection_for_lines(source, lines);
}

DedupedMathpass DedupedMathpass::create(
    const std::optional<fs::path>& source) {
    auto inspection = inspect_mathpass(source);
    if (!source || !path_exists(*source))
        return DedupedMathpass(std::nullopt, std::move(inspection), std::nullopt);
    auto directory = unique_temp_directory("tungsten-mathpass");
    try {
        auto destination = directory / "mathpass.txt";
        inspection = write_deduped_mathpass(*source, destination);
        return DedupedMathpass(
            std::move(destination), std::move(inspection), std::move(directory));
    } catch (...) {
        std::error_code error;
        fs::remove_all(directory, error);
        throw;
    }
}

DedupedMathpass::DedupedMathpass(
    std::optional<fs::path> path,
    MathpassInspection inspection,
    std::optional<fs::path> temporary_directory)
    : path_(std::move(path)),
      inspection_(std::move(inspection)),
      temporary_directory_(std::move(temporary_directory)) {}

DedupedMathpass::DedupedMathpass(DedupedMathpass&& other) noexcept
    : path_(std::move(other.path_)),
      inspection_(std::move(other.inspection_)),
      temporary_directory_(std::move(other.temporary_directory_)) {
    other.temporary_directory_.reset();
}

DedupedMathpass& DedupedMathpass::operator=(DedupedMathpass&& other) noexcept {
    if (this == &other) return *this;
    cleanup();
    path_ = std::move(other.path_);
    inspection_ = std::move(other.inspection_);
    temporary_directory_ = std::move(other.temporary_directory_);
    other.temporary_directory_.reset();
    return *this;
}

DedupedMathpass::~DedupedMathpass() { cleanup(); }

const std::optional<fs::path>& DedupedMathpass::path() const noexcept { return path_; }
const MathpassInspection& DedupedMathpass::inspection() const noexcept { return inspection_; }

void DedupedMathpass::cleanup() noexcept {
    if (!temporary_directory_) return;
    std::error_code error;
    fs::remove_all(*temporary_directory_, error);
    temporary_directory_.reset();
}

} // namespace tungsten
