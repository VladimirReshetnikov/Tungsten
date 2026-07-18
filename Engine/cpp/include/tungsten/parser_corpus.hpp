#pragma once

#include "tungsten/json.hpp"
#include "tungsten/kernel.hpp"
#include "tungsten/parser.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <gmpxx.h>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace tungsten {

inline constexpr const char* default_parser_corpus_root =
    R"(C:\TestData\wolfram\tungsten-wolfram-parser-corpus)";
inline constexpr const char* default_parser_corpus_output_directory = "validation";
inline constexpr std::size_t default_parser_corpus_max_bytes = 2 * 1024 * 1024;
inline constexpr std::size_t default_parser_corpus_kernel_batch_size = 100;
inline constexpr std::size_t default_parser_corpus_workers = 1;
inline constexpr std::size_t default_parser_corpus_preview_chars = 2000;

[[nodiscard]] const std::vector<std::string>& default_parser_corpus_extensions();
[[nodiscard]] const std::vector<std::string>& parser_corpus_notebook_extensions();

enum class ParserCorpusErrorKind {
    RootMissing,
    RootNotDirectory,
    Io,
    Json,
    Kernel,
};

class ParserCorpusError : public std::runtime_error {
public:
    ParserCorpusError(
        ParserCorpusErrorKind kind,
        std::string message,
        std::optional<std::filesystem::path> path = std::nullopt);

    [[nodiscard]] ParserCorpusErrorKind kind() const noexcept { return kind_; }
    [[nodiscard]] const std::optional<std::filesystem::path>& path() const noexcept {
        return path_;
    }

private:
    ParserCorpusErrorKind kind_;
    std::optional<std::filesystem::path> path_;
};

struct CorpusFile {
    std::filesystem::path path;
    std::string relative_path;
    std::string extension;
    std::string kind;
    std::string source;
    std::uintmax_t size_bytes = 0;

    [[nodiscard]] JsonValue to_json_value() const;
};

struct ParserAttempt {
    std::string parser;
    std::string status;
    std::optional<double> elapsed_ms;
    std::optional<std::string> error_type;
    std::optional<std::string> error;
    JsonValue summary = JsonValue::Object{};

    [[nodiscard]] static ParserAttempt success(
        std::string parser, double elapsed_ms, JsonValue summary);
    [[nodiscard]] static ParserAttempt failure(
        std::string parser, std::string error_type, std::string error,
        std::optional<double> elapsed_ms = std::nullopt,
        JsonValue summary = JsonValue::Object{});
    [[nodiscard]] static ParserAttempt skipped(
        std::string parser, std::string reason, std::string message);
    [[nodiscard]] JsonValue to_json_value() const;
};

struct ParserCorpusResult {
    CorpusFile file;
    ParserAttempt tungsten;
    ParserAttempt wolfram;
    std::string outcome;

    [[nodiscard]] JsonValue to_json_value() const;
};

struct ParserCorpusRun {
    JsonValue summary = JsonValue::Object{};
    std::vector<ParserCorpusResult> results;
    std::map<std::string, std::string> output_files;

    [[nodiscard]] JsonValue to_json_value(bool include_results = false) const;
};

struct CorpusDiscoveryOptions {
    std::vector<std::string> extensions = default_parser_corpus_extensions();
    std::vector<std::string> include_globs;
    std::vector<std::string> exclude_globs;
    std::optional<std::size_t> max_files;
    bool shuffle = false;
    mpz_class seed = 0;
};

struct ParserCorpusOptions {
    CorpusDiscoveryOptions discovery;
    std::optional<std::filesystem::path> out_dir;
    std::optional<mpz_class> max_bytes = mpz_class("2097152", 10);
    ParseForm source_form = ParseForm::Input;
    bool compare_wolfram = true;
    std::size_t kernel_batch_size = default_parser_corpus_kernel_batch_size;
    std::size_t tungsten_workers = default_parser_corpus_workers;
    std::size_t preview_chars = default_parser_corpus_preview_chars;
    bool write_outputs = true;
};

using WolframBatchParser = std::function<
    std::map<std::string, ParserAttempt>(const std::vector<CorpusFile>&)>;

[[nodiscard]] std::vector<CorpusFile> discover_corpus_files(
    const std::filesystem::path& corpus_root,
    const CorpusDiscoveryOptions& options = {});

[[nodiscard]] JsonValue summarize_discovery(
    const std::vector<CorpusFile>& files,
    const std::filesystem::path& corpus_root);

[[nodiscard]] ParserAttempt parse_file_with_tungsten(
    const CorpusFile& file,
    ParseForm source_form = ParseForm::Input,
    std::optional<mpz_class> max_bytes = mpz_class("2097152", 10),
    std::size_t preview_chars = default_parser_corpus_preview_chars);

[[nodiscard]] std::map<std::string, ParserAttempt> parse_files_with_wolfram_kernel(
    const std::vector<CorpusFile>& files,
    const WolframKernelRunner* runner = nullptr,
    std::size_t preview_chars = default_parser_corpus_preview_chars);

[[nodiscard]] ParserCorpusRun compare_parser_corpus(
    const std::filesystem::path& corpus_root,
    const ParserCorpusOptions& options = {},
    const WolframKernelRunner* runner = nullptr,
    const WolframBatchParser& batch_parser = {});

[[nodiscard]] std::map<std::string, std::string> write_parser_corpus_outputs(
    const std::filesystem::path& output_directory,
    const JsonValue& summary,
    const std::vector<ParserCorpusResult>& results);

[[nodiscard]] std::string build_wolfram_parse_batch_script(
    const std::vector<CorpusFile>& files,
    std::size_t preview_chars = default_parser_corpus_preview_chars);

[[nodiscard]] std::string classify_parser_corpus_outcome(
    const ParserAttempt& tungsten,
    const ParserAttempt& wolfram);

} // namespace tungsten
