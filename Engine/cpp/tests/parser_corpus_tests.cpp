#include "tungsten/parser_corpus.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;
int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual, const std::string& expected, const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

void check_paths(
    const std::vector<tungsten::CorpusFile>& files,
    const std::vector<std::string>& expected,
    const std::string& message) {
    std::vector<std::string> actual;
    for (const auto& file : files) actual.push_back(file.relative_path);
    if (actual == expected) return;
    std::cerr << "FAIL: " << message << "\n  expected:";
    for (const auto& path : expected) std::cerr << ' ' << path;
    std::cerr << "\n  actual:  ";
    for (const auto& path : actual) std::cerr << ' ' << path;
    std::cerr << '\n';
    ++failures;
}

class TestDirectory {
public:
    explicit TestDirectory(const std::string& prefix) {
        static std::atomic<std::uint64_t> sequence{0};
        const auto stamp = std::chrono::high_resolution_clock::now()
                               .time_since_epoch().count();
        path_ = fs::temp_directory_path()
            / (prefix + "-" + std::to_string(stamp) + "-"
                + std::to_string(sequence.fetch_add(1)));
        fs::create_directories(path_);
    }

    ~TestDirectory() {
        std::error_code error;
        fs::remove_all(path_, error);
    }

    [[nodiscard]] const fs::path& path() const noexcept { return path_; }

private:
    fs::path path_;
};

void write_file(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    stream << text;
    if (!stream) throw std::runtime_error("could not create test file");
}

std::string read_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

void discovery_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-discovery");
    const auto root = temporary.path();
    write_file(root / "github/sample/expr.wl", "1 + 2");
    write_file(root / "github/sample/upper.WLS", "3 + 4");
    write_file(root / "github/sample/notes.txt", "skip");
    write_file(root / "notebookarchive/demo/sample.nb",
        R"(Notebook[{Cell["Hello", "Text"]}])");
    write_file(root / "other/drop.m", "5");

    const auto files = discover_corpus_files(root);
    std::vector<std::string> paths;
    for (const auto& file : files) paths.push_back(file.relative_path);
    check(paths == std::vector<std::string>{
        "github/sample/expr.wl", "github/sample/upper.WLS",
        "notebookarchive/demo/sample.nb", "other/drop.m"},
        "discovery produces stable case-folded relative paths");
    check(files[0].kind == "source" && files[0].source == "github/sample",
        "source file metadata");
    check(files[2].kind == "notebook"
            && files[2].source == "notebookarchive/demo",
        "notebook metadata and source");

    CorpusDiscoveryOptions empty_extensions;
    empty_extensions.extensions.clear();
    const auto defaulted = discover_corpus_files(root, empty_extensions);
    check(defaulted.size() == files.size(),
        "an explicit empty extension list falls back to corpus defaults");

    CorpusDiscoveryOptions filtered;
    filtered.extensions = {u8"\u3000WL\u3000", ".wls"};
    filtered.include_globs = {u8"\u3000", "github/**/*.wl", "github/**/upper.[Ww][Ll][Ss]"};
    filtered.exclude_globs = {"**/upper.*"};
    const auto included = discover_corpus_files(root, filtered);
    check(included.size() == 1 && included[0].relative_path == "github/sample/expr.wl",
        "extension normalization and include/exclude globs");

    CorpusDiscoveryOptions sampled;
    sampled.shuffle = true;
    sampled.seed = 73;
    sampled.max_files = 2;
    const auto first_sample = discover_corpus_files(root, sampled);
    const auto second_sample = discover_corpus_files(root, sampled);
    check(first_sample.size() == 2, "max_files is applied after sampling");
    check(first_sample[0].relative_path == second_sample[0].relative_path
            && first_sample[1].relative_path == second_sample[1].relative_path,
        "sampling is deterministic for a fixed seed");

    const auto summary = summarize_discovery(files, root);
    check(summary.at("file_count").as_uint64() == 4, "discovery summary file count");
    check(summary.at("by_extension").at(".wl").as_uint64() == 1,
        "discovery summary extension count");
    check(summary.at("by_source").at("github/sample").as_uint64() == 2,
        "discovery summary source count");

    CorpusFile maximum_file;
    maximum_file.size_bytes = std::numeric_limits<std::uintmax_t>::max();
    const auto maximum_summary = summarize_discovery(
        {maximum_file, maximum_file}, root);
    const mpz_class expected_total(
        std::to_string(std::numeric_limits<std::uintmax_t>::max()), 10);
    const mpz_class doubled_total = expected_total * 2;
    check(maximum_summary.at("total_bytes").as_number().text
            == doubled_total.get_str(),
        "discovery byte totals do not wrap the platform file-size type");
}

void cpython_shuffle_parity_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-python-shuffle");
    const auto root = temporary.path();
    for (std::size_t index = 0; index < 12; ++index) {
        const auto prefix = index < 10 ? "0" : "";
        write_file(root / (prefix + std::to_string(index) + ".wl"), "1");
    }

    const auto shuffled = [&](const mpz_class& seed) {
        CorpusDiscoveryOptions options;
        options.shuffle = true;
        options.seed = seed;
        return discover_corpus_files(root, options);
    };
    check_paths(shuffled(mpz_class("0", 10)), {
        "01.wl", "09.wl", "08.wl", "05.wl", "10.wl", "02.wl",
        "03.wl", "07.wl", "04.wl", "00.wl", "11.wl", "06.wl"},
        "seed zero reproduces random.Random(0).shuffle");
    check_paths(shuffled(mpz_class("73", 10)), {
        "06.wl", "05.wl", "10.wl", "00.wl", "11.wl", "09.wl",
        "03.wl", "02.wl", "07.wl", "08.wl", "01.wl", "04.wl"},
        "representative seed reproduces CPython shuffle");
    check_paths(shuffled(mpz_class("4294967296", 10)), {
        "11.wl", "10.wl", "07.wl", "03.wl", "09.wl", "02.wl",
        "04.wl", "08.wl", "00.wl", "06.wl", "05.wl", "01.wl"},
        "multiword integer seed reproduces CPython shuffle");
    check_paths(shuffled(mpz_class("18446744073709551615", 10)), {
        "01.wl", "08.wl", "06.wl", "09.wl", "02.wl", "11.wl",
        "04.wl", "07.wl", "10.wl", "05.wl", "03.wl", "00.wl"},
        "maximum API seed reproduces CPython shuffle");
    check_paths(shuffled(mpz_class("-1", 10)), {
        "07.wl", "11.wl", "00.wl", "08.wl", "05.wl", "06.wl",
        "03.wl", "10.wl", "04.wl", "01.wl", "09.wl", "02.wl"},
        "negative integer seed uses CPython's magnitude contract");
    check_paths(shuffled(mpz_class(
        "1361129467683753853853498429727072858169", 10)), {
        "01.wl", "09.wl", "10.wl", "06.wl", "03.wl", "05.wl",
        "00.wl", "02.wl", "04.wl", "11.wl", "07.wl", "08.wl"},
        "arbitrary-width integer seed reproduces CPython shuffle");
    check_paths(shuffled(mpz_class(
        "-1361129467683753853853498429727072858169", 10)), {
        "01.wl", "09.wl", "10.wl", "06.wl", "03.wl", "05.wl",
        "00.wl", "02.wl", "04.wl", "11.wl", "07.wl", "08.wl"},
        "negative arbitrary-width seed uses the same magnitude");
}

void fnmatch_parity_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-fnmatch");
    const auto root = temporary.path();
    for (const auto& path : std::vector<std::string>{
             "a.wl", "b.wl", "c.wl", "-.wl", "!.wl", "^.wl", "].wl",
             "[.wl", u8"é.wl", u8"ê.wl", u8"ë.wl", u8"α.wl", u8"β.wl",
             u8"γ.wl", u8"δ.wl", u8"éé.wl", "x/y.wl", "a/x/b.wl",
             "a/b.wl"})
        write_file(root / fs::u8path(path), "1");

    const auto included = [&](const std::string& pattern) {
        CorpusDiscoveryOptions options;
        options.include_globs = {pattern};
        return discover_corpus_files(root, options);
    };
    check_paths(included("[c-a].wl"), {},
        "invalid reversed range never matches");
    check_paths(included("[^a].wl"), {"^.wl", "a.wl"},
        "caret is literal rather than a negation marker");
    check_paths(included("[]a].wl"), {"].wl", "a.wl"},
        "a leading closing bracket is a class member");
    check_paths(included("[!]].wl"), {
        "!.wl", "-.wl", "[.wl", "^.wl", "a.wl", "b.wl", "c.wl",
        u8"é.wl", u8"ê.wl", u8"ë.wl", u8"α.wl", u8"β.wl",
        u8"γ.wl", u8"δ.wl"},
        "negated closing-bracket class follows fnmatchcase");
    check_paths(included("[a--b].wl"), {"b.wl"},
        "invalid overlapping ranges are removed like fnmatchcase");
    check_paths(included(u8"[é-ê].wl"), {u8"é.wl", u8"ê.wl"},
        "Unicode Latin range operates on code points");
    check_paths(included(u8"[α-γ].wl"), {u8"α.wl", u8"β.wl", u8"γ.wl"},
        "Unicode Greek range operates on code points");
    check_paths(included("?.wl"), {
        "!.wl", "-.wl", "[.wl", "].wl", "^.wl", "a.wl", "b.wl", "c.wl",
        u8"é.wl", u8"ê.wl", u8"ë.wl", u8"α.wl", u8"β.wl",
        u8"γ.wl", u8"δ.wl"},
        "question mark consumes one Unicode code point");
    check_paths(included("??.wl"), {u8"éé.wl"},
        "two question marks consume two Unicode code points");
    check_paths(included("*/*.wl"), {"a/b.wl", "a/x/b.wl", "x/y.wl"},
        "star matches path separators like fnmatchcase");
    check_paths(included("a/**/b.wl"), {"a/x/b.wl"},
        "double star has ordinary repeated-star semantics");
}

void unicode_path_parity_tests() {
    using namespace tungsten;
    TestDirectory sort_directory("tungsten-parser-corpus-unicode-sort");
    for (const auto& path : std::vector<std::string>{
             "z.wl", u8"ẞ-a.wl", u8"ſ-a.wl", u8"K-a.wl", u8"İ-a.wl",
             u8"Ä-a.wl", u8"Σ-a.wl", u8"𐐀-a.wl", "ff-a.wl",
             u8"ﬀ-b.wl", "r.wl"})
        write_file(sort_directory.path() / fs::u8path(path), "1");
    check_paths(discover_corpus_files(sort_directory.path()), {
        "ff-a.wl", u8"ﬀ-b.wl", u8"İ-a.wl", u8"K-a.wl", "r.wl",
        u8"ſ-a.wl", u8"ẞ-a.wl", "z.wl", u8"Ä-a.wl", u8"Σ-a.wl",
        u8"𐐀-a.wl"},
        "Unicode 15.1 casefold keys reproduce Python path sorting");

    TestDirectory extension_directory("tungsten-parser-corpus-unicode-extension");
    for (const auto& path : std::vector<std::string>{
             u8"one.ẞ", u8"two.ß", u8"three.İ", u8"four.i̇", u8"five.ΟΣ",
             u8"six.ος", u8"seven.𐐀", u8"eight.𐐨"})
        write_file(extension_directory.path() / fs::u8path(path), "1");

    const auto by_extension = [&](const std::string& extension) {
        CorpusDiscoveryOptions options;
        options.extensions = {extension};
        return discover_corpus_files(extension_directory.path(), options);
    };
    const auto sharp_s = by_extension(u8"ẞ");
    check_paths(sharp_s, {u8"one.ẞ", u8"two.ß"},
        "Unicode lowercase normalization handles capital sharp S");
    check(sharp_s.size() == 2 && sharp_s[0].extension == u8".ß"
            && sharp_s[1].extension == u8".ß",
        "normalized sharp-S extension metadata");
    const auto dotted_i = by_extension(u8"İ");
    check_paths(dotted_i, {u8"four.i̇", u8"three.İ"},
        "Unicode lowercase normalization preserves dotted-I expansion");
    check(dotted_i.size() == 2 && dotted_i[0].extension == u8".i̇"
            && dotted_i[1].extension == u8".i̇",
        "normalized dotted-I extension metadata");
    const auto final_sigma = by_extension(u8"ΟΣ");
    check_paths(final_sigma, {u8"five.ΟΣ", u8"six.ος"},
        "Unicode lowercase normalization applies final-sigma context");
    check(final_sigma.size() == 2 && final_sigma[0].extension == u8".ος"
            && final_sigma[1].extension == u8".ος",
        "normalized final-sigma extension metadata");
    const auto deseret = by_extension(u8"𐐀");
    check_paths(deseret, {u8"eight.𐐨", u8"seven.𐐀"},
        "Unicode lowercase normalization handles supplementary planes");
    check(deseret.size() == 2 && deseret[0].extension == u8".𐐨"
            && deseret[1].extension == u8".𐐨",
        "normalized supplementary-plane extension metadata");
}

void structured_error_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-errors");
    const auto missing = temporary.path() / "missing";
    try {
        (void)discover_corpus_files(missing);
        check(false, "missing corpus root rejected");
    } catch (const ParserCorpusError& error) {
        check(error.kind() == ParserCorpusErrorKind::RootMissing,
            "missing root error kind");
        check(error.path() == std::optional<fs::path>(fs::absolute(missing)),
            "missing root error path");
    }

    const auto file = temporary.path() / "file.wl";
    write_file(file, "1");
    try {
        (void)discover_corpus_files(file);
        check(false, "non-directory corpus root rejected");
    } catch (const ParserCorpusError& error) {
        check(error.kind() == ParserCorpusErrorKind::RootNotDirectory,
            "not-directory error kind");
    }
}

void tungsten_parse_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-parse");
    const auto root = temporary.path();
    write_file(root / "expr.wl", "1 + 2 x");
    write_file(root / "empty.wl", "");
    write_file(root / "sample.nb", R"(Notebook[{Cell["Hello", "Text"]}])");
    write_file(root / "bad.wl", "x @= 1");
    auto files = discover_corpus_files(root);
    std::map<std::string, CorpusFile> indexed;
    for (auto& file : files) indexed.emplace(file.relative_path, std::move(file));

    const auto source = parse_file_with_tungsten(indexed.at("expr.wl"));
    const auto notebook = parse_file_with_tungsten(indexed.at("sample.nb"));
    const auto bad = parse_file_with_tungsten(indexed.at("bad.wl"));
    check(source.status == "success", "source parse succeeds");
    check_equal(source.summary.at("full_form_preview").as_string(),
        "Plus[1, Times[2, x]]", "source full-form summary");
    check(source.summary.at("depth").as_uint64() == 3, "source depth summary");
    check(notebook.status == "success"
            && notebook.summary.at("cell_count").as_uint64() == 1,
        "notebook parse and summary");
    check(bad.status == "failure"
            && bad.error_type == std::optional<std::string>("WolframSyntaxError"),
        "syntax failure attempt");

    const auto oversized = parse_file_with_tungsten(indexed.at("expr.wl"),
        ParseForm::Input, 2, 2000);
    check(oversized.status == "skipped"
            && oversized.error_type == std::optional<std::string>("FileTooLarge"),
        "oversized source skipped before reading");
    check(!oversized.to_json_value().contains("elapsed_ms"),
        "absent attempt values are omitted from JSON");

    const auto negative_limit = parse_file_with_tungsten(indexed.at("empty.wl"),
        ParseForm::Input, mpz_class("-1", 10), 2000);
    check(negative_limit.status == "skipped"
            && negative_limit.error_type == std::optional<std::string>("FileTooLarge"),
        "negative byte limit skips even a zero-byte file like Python");

    fs::remove(indexed.at("expr.wl").path);
    const auto missing = parse_file_with_tungsten(indexed.at("expr.wl"));
    check(missing.status == "failure"
            && missing.error_type == std::optional<std::string>("OSError"),
        "file read errors become structured attempts");
}

void comparison_and_output_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-compare");
    const auto root = temporary.path() / "corpus";
    const auto output = temporary.path() / "out";
    write_file(root / "good.wl", "1 + 2");
    write_file(root / "bad.wl", "x @= 1");
    write_file(root / "third.wl", "3 + 4");

    std::size_t calls = 0;
    WolframBatchParser parser = [&](const std::vector<CorpusFile>& batch) {
        ++calls;
        std::map<std::string, ParserAttempt> attempts;
        for (const auto& file : batch)
            attempts.emplace(file.relative_path,
                ParserAttempt::success("wolfram", 0.25,
                    JsonValue::Object{{"fake", true}}));
        return attempts;
    };
    ParserCorpusOptions options;
    options.out_dir = output;
    options.kernel_batch_size = 2;
    options.tungsten_workers = 3;
    const auto run = compare_parser_corpus(root, options, nullptr, parser);
    check(calls == 2, "eligible files are sent in configured batches");
    check(run.results.size() == 3, "comparison result count");
    check(run.summary.at("outcomes").at("both_success").as_uint64() == 2,
        "both-success outcome count");
    check(run.summary.at("outcomes").at("tungsten_gap").as_uint64() == 1,
        "Tungsten gap outcome count");
    check(run.summary.at("options").at("tungsten_workers").as_uint64() == 3,
        "worker option retained in summary");
    const auto generated_utc = run.summary.at("generated_utc").as_string();
    check(generated_utc.size() == 20 && generated_utc.back() == 'Z'
            && generated_utc.find('.') == std::string::npos,
        "generated timestamp uses whole-second UTC precision");
    check(run.output_files.size() == 3, "three output projections written");

    const auto summary_path = fs::path(run.output_files.at("summary"));
    const auto results_path = fs::path(run.output_files.at("results_jsonl"));
    const auto report_path = fs::path(run.output_files.at("report"));
    const auto summary = JsonValue::parse(read_file(summary_path));
    check(summary.at("file_count").as_uint64() == 3, "summary output parses");
    check(summary.at("output_files").is_object(), "final summary includes output paths");
    std::size_t result_lines = 0;
    std::istringstream lines(read_file(results_path));
    std::string line;
    while (std::getline(lines, line)) {
        if (line.empty()) continue;
        ++result_lines;
        check(JsonValue::parse(line).is_object(), "JSONL result is valid JSON");
    }
    check(result_lines == 3, "one JSONL row per file");
    const auto report = read_file(report_path);
    check(report.find("# Tungsten Parser Corpus Comparison") == 0,
        "Markdown report heading");
    check(report.find("## First Wolfram-Accepted Tungsten Gaps") != std::string::npos,
        "Markdown gap section");
    check(run.to_json_value(true).at("results").size() == 3,
        "run model optionally projects results");
}

void skip_and_kernel_tests() {
    using namespace tungsten;
    TestDirectory temporary("tungsten-parser-corpus-kernel");
    const auto root = temporary.path();
    write_file(root / "large.wl", std::string(100, '1'));
    bool called = false;
    WolframBatchParser parser = [&](const std::vector<CorpusFile>&) {
        called = true;
        return std::map<std::string, ParserAttempt>{};
    };
    ParserCorpusOptions oversized;
    oversized.max_bytes = 10;
    oversized.write_outputs = false;
    const auto skipped = compare_parser_corpus(root, oversized, nullptr, parser);
    check(!called, "oversized files never reach Wolfram batch parser");
    check(skipped.results[0].outcome == "skipped"
            && skipped.results[0].tungsten.error_type
                == std::optional<std::string>("FileTooLarge"),
        "oversized comparison outcome");

    ParserCorpusOptions disabled;
    disabled.compare_wolfram = false;
    disabled.write_outputs = false;
    disabled.max_bytes = std::nullopt;
    const auto no_wolfram = compare_parser_corpus(root, disabled);
    check(no_wolfram.results[0].wolfram.error_type
            == std::optional<std::string>("WolframComparisonDisabled"),
        "disabled comparison reason");

    auto files = discover_corpus_files(root);
    WolframInstallation installation;
    installation.install_dir = root;
    installation.default_index_path = root / "docs.sqlite";
    WolframKernelRunner runner(installation);
    const auto kernel = parse_files_with_wolfram_kernel(files, &runner);
    check(kernel.at("large.wl").status == "skipped"
            && kernel.at("large.wl").error_type
                == std::optional<std::string>("KernelNotFound"),
        "missing kernel becomes a skipped Wolfram attempt");
    const auto script = build_wolfram_parse_batch_script(files, 77);
    check(script.find("tungstenParserCorpusPreviewChars = 77") != std::string::npos,
        "kernel batch script preview limit");
    check(script.find("HoldComplete[CompoundExpression[exprs]]") != std::string::npos,
        "kernel batch script normalizes multiple expressions");
    check(script.find("large.wl") != std::string::npos,
        "kernel batch script includes corpus path");
}

} // namespace

int main() {
    discovery_tests();
    cpython_shuffle_parity_tests();
    fnmatch_parity_tests();
    unicode_path_parity_tests();
    structured_error_tests();
    tungsten_parse_tests();
    comparison_and_output_tests();
    skip_and_kernel_tests();
    if (failures != 0) {
        std::cerr << failures << " C++ parser corpus test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ parser corpus tests passed\n";
    return EXIT_SUCCESS;
}
