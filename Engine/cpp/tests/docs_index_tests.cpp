#include "tungsten/docs_index.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <sys/resource.h>
#endif

namespace {

namespace fs = std::filesystem;
using tungsten::DocumentationError;
using tungsten::DocumentationErrorCode;
using tungsten::DocumentationIndex;
using tungsten::WolframInstallation;

class TemporaryDirectory {
public:
    explicit TemporaryDirectory(const std::string& prefix) {
        static std::atomic<unsigned long long> sequence{0};
        const auto stamp = std::chrono::high_resolution_clock::now()
                               .time_since_epoch().count();
        const auto root = fs::temp_directory_path();
        for (unsigned attempt = 0; attempt < 1000; ++attempt) {
            path_ = root / (prefix + '-' + std::to_string(stamp) + '-'
                + std::to_string(sequence.fetch_add(1)) + '-'
                + std::to_string(attempt));
            std::error_code error;
            if (fs::create_directory(path_, error)) return;
            if (error && error != std::errc::file_exists)
                throw fs::filesystem_error(
                    "could not create test directory", path_, error);
        }
        throw std::runtime_error("could not allocate test directory");
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

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void write_file(const fs::path& path, const std::string& contents) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("could not create " + path.string());
    stream.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    if (!stream) throw std::runtime_error("could not write " + path.string());
}

std::string read_prefix(const fs::path& path, std::size_t size) {
    std::ifstream stream(path, std::ios::binary);
    std::string result(size, '\0');
    stream.read(result.data(), static_cast<std::streamsize>(size));
    result.resize(static_cast<std::size_t>(stream.gcount()));
    return result;
}

std::string read_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("could not read " + path.string());
    std::ostringstream contents;
    contents << stream.rdbuf();
    if (stream.bad()) throw std::runtime_error("could not read " + path.string());
    return contents.str();
}

bool has_staging_artifacts(const fs::path& target) {
    auto parent = target.parent_path();
    if (parent.empty()) parent = fs::path(".");
    if (!fs::exists(parent)) return false;
    constexpr const char* prefix = ".tungsten-docs-index-staging-";
    for (const auto& entry : fs::directory_iterator(parent)) {
        const auto filename = entry.path().filename().u8string();
        if (filename.rfind(prefix, 0) == 0) return true;
    }
    return false;
}

#ifdef _WIN32
class HeldIndexReplacement {
public:
    explicit HeldIndexReplacement(const fs::path& path)
        : handle_(CreateFileW(path.c_str(), GENERIC_READ,
              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
              FILE_ATTRIBUTE_NORMAL, nullptr)) {
        if (handle_ == INVALID_HANDLE_VALUE)
            throw std::runtime_error(
                "could not hold the existing index against replacement");
    }

    HeldIndexReplacement(const HeldIndexReplacement&) = delete;
    HeldIndexReplacement& operator=(const HeldIndexReplacement&) = delete;

    ~HeldIndexReplacement() {
        if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
    }

    void restore() {
        if (handle_ == INVALID_HANDLE_VALUE) return;
        const HANDLE handle = handle_;
        handle_ = INVALID_HANDLE_VALUE;
        if (CloseHandle(handle) == 0)
            throw std::runtime_error(
                "could not release the held documentation index");
    }

private:
    HANDLE handle_ = INVALID_HANDLE_VALUE;
};
#else
class ScopedFileSizeLimit {
public:
    explicit ScopedFileSizeLimit(rlim_t limit) {
        if (getrlimit(RLIMIT_FSIZE, &original_) != 0)
            throw std::runtime_error("could not read the process file-size limit");
        if (original_.rlim_cur <= limit)
            throw std::runtime_error(
                "process file-size limit is too small for the preservation test");

        previous_handler_ = std::signal(SIGXFSZ, SIG_IGN);
        if (previous_handler_ == SIG_ERR)
            throw std::runtime_error("could not ignore SIGXFSZ");

        auto restricted = original_;
        restricted.rlim_cur = limit;
        if (setrlimit(RLIMIT_FSIZE, &restricted) != 0) {
            (void)std::signal(SIGXFSZ, previous_handler_);
            throw std::runtime_error("could not restrict the process file-size limit");
        }
        active_ = true;
    }

    ScopedFileSizeLimit(const ScopedFileSizeLimit&) = delete;
    ScopedFileSizeLimit& operator=(const ScopedFileSizeLimit&) = delete;

    ~ScopedFileSizeLimit() {
        if (!active_) return;
        (void)setrlimit(RLIMIT_FSIZE, &original_);
        (void)std::signal(SIGXFSZ, previous_handler_);
    }

    void restore() {
        if (!active_) return;
        const bool limit_restored = setrlimit(RLIMIT_FSIZE, &original_) == 0;
        const bool handler_restored
            = std::signal(SIGXFSZ, previous_handler_) != SIG_ERR;
        active_ = false;
        if (!limit_restored || !handler_restored)
            throw std::runtime_error(
                "could not restore the process file-size limit");
    }

private:
    struct rlimit original_ {};
    void (*previous_handler_)(int) = SIG_DFL;
    bool active_ = false;
};
#endif

WolframInstallation installation_for(
    std::vector<fs::path> roots, const fs::path& index_path) {
    WolframInstallation installation;
    installation.docs_roots = std::move(roots);
    installation.default_index_path = index_path;
    return installation;
}

void test_records_and_category_inference() {
    TemporaryDirectory temporary("tungsten-cpp-doc-record");
    const auto root = temporary.path();
    const auto quoted = root / "ReferencePages" / "Programs" / "Quoted.nb";
    const std::string blob(200, 'A');
    write_file(quoted,
        "Notebook[{Cell[\"Quoted \\\"Title\\\"\",\"ObjectName\"],"
        "Cell[\" AnchorBar \",\"Text\"],Cell[\"AnchorBar\",\"Text\"],"
        "Cell[\"\x1f\",\"Text\"],"
        "Cell[\"123e4567-e89b-12d3-a456-426614174000\",\"Text\"],"
        "Cell[\"" + blob + "\",\"Text\"],"
        "Cell[\" Useful   words \",\"Usage\"]},"
        "WindowTitle->\"Quoted \\\"Title\\\"\"]");

    DocumentationIndex index(installation_for({root}, root / "docs.sqlite3"));
    const auto record = index.record_from_path(quoted);
    require(record.title == "Quoted \"Title\"", "quoted WindowTitle was not decoded");
    require(record.kind == "reference", "reference kind was not inferred");
    require(record.category == "Programs", "reference category was not inferred");
    require(record.paclet == "paclet:ref/program/Quoted",
        "reference paclet category was not mapped");
    require(record.preview.find("Useful words") != std::string::npos,
        "useful notebook strings were not collapsed into the preview");
    require(record.preview.find("123e4567") == std::string::npos,
        "UUID noise leaked into the preview");
    require(record.preview.find('\x1f') == std::string::npos,
        "Python-recognized control whitespace leaked into the preview");
    require(record.preview.find(blob) == std::string::npos,
        "compressed-blob noise leaked into the preview");
    require(record.to_json().at("text").as_string() == record.text,
        "documentation record JSON lost text");
    require(record.to_json().at("preview").as_string() == record.preview,
        "documentation record JSON lost preview");

    const auto custom = root / "ReferencePages" / "NewCategory" / "Custom.nb";
    write_file(custom, "Notebook[{},WindowTitle->Custom]");
    require(index.record_from_path(custom).paclet == "paclet:ref/newcategory/Custom",
        "unknown reference categories did not use the ref/<lowercase> fallback");

    const auto workflow = root / "WorkflowGuides" / "Flow.nb";
    write_file(workflow, "Notebook[{},WindowTitle->Flow]");
    const auto workflow_record = index.record_from_path(workflow);
    require(workflow_record.kind == "workflowguide"
            && workflow_record.category == "WorkflowGuides"
            && workflow_record.paclet == "paclet:workflowguide/Flow",
        "section category inference diverged from the Wolfram paclet mapping");

    const auto other = root / "Misc" / "Loose.nb";
    write_file(other, "Notebook[{}]");
    const auto other_record = index.record_from_path(other);
    require(other_record.title == "Loose" && other_record.kind == "document"
            && other_record.category == "Other"
            && other_record.paclet == "paclet:document/Loose",
        "generic documentation fallback was not preserved");
}

void test_build_search_read_and_resolve() {
    TemporaryDirectory temporary("tungsten-cpp-doc-search");
    const auto root = temporary.path();
    const auto symbols = root / "ReferencePages" / "Symbols";
    const auto guides = root / "Guides";
    write_file(symbols / "Foo.nb",
        "Notebook[{Cell[\"Foo\",\"ObjectName\"],"
        "Cell[\"Foo computes a symbolic bar.\",\"Usage\"]},WindowTitle->Foo]\n");
    write_file(symbols / "Bar.nb",
        "Notebook[{Cell[\"Bar\",\"ObjectName\"],"
        "Cell[\"Bar transforms a notebook.\",\"Usage\"]},WindowTitle->Bar]\n");
    write_file(guides / "Topic.nb",
        "Notebook[{Cell[\"UnusualNeedle phrase\",\"Text\"]},WindowTitle->Topic]");
    write_file(guides / "InternalName.nb",
        "Notebook[{Cell[\"FriendlyTitle details\",\"Text\"]},"
        "WindowTitle->FriendlyTitle]");
    const auto unicode_path = guides / fs::u8path(u8"βeta.nb");
    write_file(unicode_path,
        "Notebook[{Cell[\"Unicode path details\",\"Text\"]},WindowTitle->Beta]");

    const auto index_path = root / "state" / "docs.sqlite3";
    DocumentationIndex index(installation_for({root}, index_path));
    require(index.build_index() == index_path, "build_index returned the wrong path");
    require(fs::exists(index_path), "build_index did not create the index");
    require(read_prefix(index_path, 16) == std::string("SQLite format 3\0", 16),
        "documentation index is not a SQLite database");
    require(!has_staging_artifacts(index_path),
        "successful index build left a staging artifact");

    const auto filename_hits = index.search("foo", index_path, 5, false);
    require(filename_hits.size() == 1, "case-insensitive filename search missed Foo.nb");
    require(filename_hits.front().at("paclet").as_string() == "paclet:ref/Foo",
        "filename search returned the wrong paclet");
    require(filename_hits.front().at("score").as_double().value_or(1.0) == 0.0,
        "filename search did not retain its zero-score fast-path marker");
    require(filename_hits.front().at("snippet").as_string()
            == filename_hits.front().at("preview").as_string(),
        "filename search snippet did not mirror the preview");

    const auto full_text_hits = index.search("UnusualNeedle", index_path, 5, false);
    require(full_text_hits.size() == 1,
        "FTS fallback did not find content whose filename differs from the query");
    require(full_text_hits.front().at("paclet").as_string() == "paclet:guide/Topic",
        "FTS fallback returned the wrong guide");
    require(full_text_hits.front().at("snippet").as_string().find("[UnusualNeedle]")
            != std::string::npos,
        "FTS snippet did not contain the configured match markers");
    require(index.search("UnusualNeedle", index_path, 0, false).empty(),
        "zero search limit returned results");

    const auto fast_record = index.read("paclet:ref/Bar", index_path, false);
    require(fast_record.at("title").as_string() == "Bar",
        "paclet fast read returned the wrong record");
    require(fast_record.at("text").as_string().find("notebook") != std::string::npos,
        "read record omitted extracted notebook text");
    require(!fast_record.contains("id"),
        "filesystem fast read unexpectedly acquired a database row id");

    const auto database_record = index.read("FriendlyTitle", index_path, false);
    require(database_record.at("title").as_string() == "FriendlyTitle"
            && database_record.contains("id"),
        "title lookup did not fall back to the indexed documents table");
    require(index.resolve_identifier("Foo", index_path) == "paclet:ref/Foo",
        "identifier resolution returned the wrong paclet");
    require(index.resolve_identifier("paclet:made/up", index_path) == "paclet:made/up",
        "paclet identifiers were not passed through unchanged");
    const auto unicode_record = index.read(unicode_path.u8string(), index_path, false);
    require(unicode_record.at("title").as_string() == "Beta",
        "UTF-8 documentation paths survive the public string boundary");

    bool not_found = false;
    try {
        (void)index.read("DefinitelyMissing", index_path, false);
    } catch (const DocumentationError& error) {
        not_found = error.code() == DocumentationErrorCode::NotFound
            && std::string(error.what())
                == "No documentation page found for \"DefinitelyMissing\".";
    }
    require(not_found, "missing documentation did not report the typed not-found error");
}

void test_fast_path_root_priority_and_index_lifecycle() {
    TemporaryDirectory temporary("tungsten-cpp-doc-lifecycle");
    const auto first = temporary.path() / "first";
    const auto second = temporary.path() / "second";
    write_file(first / "ReferencePages" / "Symbols" / "Foo.nb",
        "Notebook[{Cell[\"from-first\",\"Usage\"]},WindowTitle->Foo]");
    write_file(second / "ReferencePages" / "Symbols" / "Foo.nb",
        "Notebook[{Cell[\"from-second\",\"Usage\"]},WindowTitle->Foo]");
    const auto index_path = temporary.path() / "index" / "docs.sqlite3";
    DocumentationIndex index(installation_for({second, first}, index_path));

    const auto hits = index.search("Foo", index_path, 1, true);
    require(hits.size() == 1
            && hits.front().at("preview").as_string().find("from-second")
                != std::string::npos,
        "filename search did not honor documentation-root priority");
    require(!fs::exists(index_path),
        "filename fast search incorrectly created/rebuilt the SQLite index");

    write_file(index_path, "sentinel");
    require(index.ensure_index(index_path, false) == index_path,
        "ensure_index returned the wrong existing path");
    require(read_prefix(index_path, 8) == "sentinel",
        "ensure_index rebuilt an existing index without rebuild=true");
    require(index.ensure_index(index_path, true) == index_path,
        "ensure_index rebuild returned the wrong path");
    require(read_prefix(index_path, 16) == std::string("SQLite format 3\0", 16),
        "ensure_index(rebuild=true) did not replace the existing file");
    require(!has_staging_artifacts(index_path),
        "successful index rebuild left a staging artifact");

    write_file(second / "Guides" / "Topic.nb",
        "Notebook[{Cell[\"OldNeedle\",\"Text\"]},WindowTitle->Topic]");
    (void)index.build_index(index_path);
    require(index.search("OldNeedle", index_path, 5, false).size() == 1,
        "initial full-text content was not indexed");
    write_file(second / "Guides" / "Topic.nb",
        "Notebook[{Cell[\"NewNeedle\",\"Text\"]},WindowTitle->Topic]");
    require(index.search("NewNeedle", index_path, 5, false).empty(),
        "search rebuilt an existing index without request");
    require(index.search("NewNeedle", index_path, 5, true).size() == 1,
        "search(rebuild=true) did not refresh full-text content");
}

void test_failed_publish_cleans_staging_artifacts() {
    TemporaryDirectory temporary("tungsten-cpp-doc-publish-failure");
    const auto docs_root = temporary.path() / "docs";
    write_file(docs_root / "Guides" / "Topic.nb",
        "Notebook[{Cell[\"PublishFailureNeedle\",\"Text\"]},"
        "WindowTitle->Topic]");

    const auto target = temporary.path() / "state" / "docs.sqlite3";
    const auto sentinel = target / "sentinel";
    write_file(sentinel, "existing target");
    DocumentationIndex index(installation_for({docs_root}, target));

    bool io_error = false;
    try {
        (void)index.build_index(target);
    } catch (const DocumentationError& error) {
        io_error = error.code() == DocumentationErrorCode::Io;
    }
    require(io_error,
        "failed staging publication did not report a typed I/O error");
    require(fs::is_directory(target) && read_file(sentinel) == "existing target",
        "failed staging publication modified the existing target");
    require(!has_staging_artifacts(target),
        "failed staging publication left a staging artifact");
}

void test_failed_rebuild_preserves_existing_database() {
    TemporaryDirectory temporary("tungsten-cpp-doc-preserve-index");
    const auto docs_root = temporary.path() / "docs";
    const auto notebook = docs_root / "Guides" / "Topic.nb";
    write_file(notebook,
        "Notebook[{Cell[\"OldTransactionalNeedle\",\"Text\"]},"
        "WindowTitle->Topic]");

    const auto state = temporary.path() / "state";
    const auto initial_target = state / "docs.sqlite3";
    DocumentationIndex index(installation_for({docs_root}, initial_target));
    (void)index.build_index(initial_target);

    const auto original_bytes = read_file(initial_target);
    write_file(notebook,
        "Notebook[{Cell[\"NewTransactionalNeedle\",\"Text\"]},"
        "WindowTitle->Topic]");

#ifdef _WIN32
    HeldIndexReplacement forced_failure(initial_target);
#else
    ScopedFileSizeLimit forced_failure(1024);
#endif

    bool expected_error = false;
    try {
        (void)index.build_index(initial_target);
    } catch (const DocumentationError& error) {
        expected_error = error.code()
#ifdef _WIN32
            == DocumentationErrorCode::Io;
#else
            == DocumentationErrorCode::Sqlite;
#endif
    }

    forced_failure.restore();

    require(expected_error, "forced rebuild failure reported the wrong error type");
    require(read_file(initial_target) == original_bytes,
        "failed rebuild changed the existing index bytes");
    require(!has_staging_artifacts(initial_target),
        "failed rebuild left a staging artifact");
    require(index.search("OldTransactionalNeedle", initial_target, 5, false).size()
            == 1,
        "failed rebuild left the existing index unusable");
}

void test_failure_semantics() {
    TemporaryDirectory temporary("tungsten-cpp-doc-errors");
    const auto index_path = temporary.path() / "broken.sqlite3";
    DocumentationIndex index(
        installation_for({temporary.path() / "empty"}, index_path));

    bool io_error = false;
    try {
        (void)index.record_from_path(temporary.path() / "missing.nb");
    } catch (const DocumentationError& error) {
        io_error = error.code() == DocumentationErrorCode::Io;
    }
    require(io_error, "missing notebook did not report a typed I/O error");

    write_file(index_path, "not a sqlite database");
    bool sqlite_error = false;
    try {
        (void)index.search("NoFilenameMatch", index_path, 5, false);
    } catch (const DocumentationError& error) {
        sqlite_error = error.code() == DocumentationErrorCode::Sqlite;
    }
    require(sqlite_error, "malformed existing index did not report a typed SQLite error");
}

void test_symlink_boundary_safety() {
    TemporaryDirectory temporary("tungsten-cpp-doc-symlinks");
    const auto root = temporary.path() / "docs";
    const auto sibling = temporary.path() / "docs-escaped";
    write_file(root / "Real.nb", "Notebook[{},WindowTitle->Real]");
    write_file(sibling / "Escaped.nb", "Notebook[{},WindowTitle->Escaped]");
    std::error_code error;
    fs::create_directory_symlink(sibling, root / "escape", error);
    if (error) return; // Creating symlinks can require an explicit Windows privilege.

    DocumentationIndex index(installation_for(
        {root}, temporary.path() / "index.sqlite3"));
    require(index.search("Real", std::nullopt, 5, false).size() == 1,
        "documentation traversal missed an in-root notebook");
    require(index.search("Escaped", std::nullopt, 5, false).empty(),
        "documentation traversal followed a symlink outside its root");
}

} // namespace

int main() {
    try {
        test_records_and_category_inference();
        test_build_search_read_and_resolve();
        test_fast_path_root_priority_and_index_lifecycle();
        test_failed_publish_cleans_staging_artifacts();
        test_failed_rebuild_preserves_existing_database();
        test_failure_semantics();
        test_symlink_boundary_safety();
        std::cout << "all C++ documentation-index tests passed\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "documentation-index test failure: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
