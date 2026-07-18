#include "tungsten/docs_index.hpp"
#include "tungsten/detail/ascii.hpp"

#include "tungsten/notebook.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <locale>
#include <memory>
#include <set>
#include <sstream>
#include <system_error>
#include <utility>

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace tungsten {
namespace {

namespace fs = std::filesystem;

struct sqlite3;
struct sqlite3_stmt;
using SqliteDestructor = void (*)(void*);

constexpr int sqlite_ok = 0;
constexpr int sqlite_row = 100;
constexpr int sqlite_done = 101;
constexpr int sqlite_null = 5;
constexpr int sqlite_open_readwrite = 0x00000002;
constexpr int sqlite_open_create = 0x00000004;

class SqliteApi {
public:
    using OpenV2 = int (*)(const char*, sqlite3**, int, const char*);
    using Close = int (*)(sqlite3*);
    using Errmsg = const char* (*)(sqlite3*);
    using Exec = int (*)(sqlite3*, const char*, int (*)(void*, int, char**, char**),
        void*, char**);
    using Free = void (*)(void*);
    using PrepareV2 = int (*)(sqlite3*, const char*, int, sqlite3_stmt**,
        const char**);
    using Step = int (*)(sqlite3_stmt*);
    using Finalize = int (*)(sqlite3_stmt*);
    using Reset = int (*)(sqlite3_stmt*);
    using ClearBindings = int (*)(sqlite3_stmt*);
    using BindText = int (*)(sqlite3_stmt*, int, const char*, int,
        SqliteDestructor);
    using BindInt64 = int (*)(sqlite3_stmt*, int, std::int64_t);
    using ColumnText = const unsigned char* (*)(sqlite3_stmt*, int);
    using ColumnBytes = int (*)(sqlite3_stmt*, int);
    using ColumnInt64 = std::int64_t (*)(sqlite3_stmt*, int);
    using ColumnDouble = double (*)(sqlite3_stmt*, int);
    using ColumnType = int (*)(sqlite3_stmt*, int);
    using LastInsertRowid = std::int64_t (*)(sqlite3*);

    OpenV2 open_v2 = nullptr;
    Close close = nullptr;
    Errmsg errmsg = nullptr;
    Exec exec = nullptr;
    Free free_memory = nullptr;
    PrepareV2 prepare_v2 = nullptr;
    Step step = nullptr;
    Finalize finalize = nullptr;
    Reset reset = nullptr;
    ClearBindings clear_bindings = nullptr;
    BindText bind_text = nullptr;
    BindInt64 bind_int64 = nullptr;
    ColumnText column_text = nullptr;
    ColumnBytes column_bytes = nullptr;
    ColumnInt64 column_int64 = nullptr;
    ColumnDouble column_double = nullptr;
    ColumnType column_type = nullptr;
    LastInsertRowid last_insert_rowid = nullptr;

    [[nodiscard]] static const SqliteApi& instance() {
        static const SqliteApi api;
        return api;
    }

    SqliteApi(const SqliteApi&) = delete;
    SqliteApi& operator=(const SqliteApi&) = delete;

    ~SqliteApi() {
#ifdef _WIN32
        if (library_ != nullptr) FreeLibrary(library_);
#else
        if (library_ != nullptr) dlclose(library_);
#endif
    }

private:
    SqliteApi() {
#ifdef _WIN32
        constexpr const char* candidates[] = {"sqlite3.dll", "winsqlite3.dll"};
#elif defined(__APPLE__)
        constexpr const char* candidates[] = {
            "libsqlite3.dylib", "/usr/lib/libsqlite3.dylib"};
#else
        constexpr const char* candidates[] = {"libsqlite3.so.0", "libsqlite3.so"};
#endif
        std::string last_error;
        for (const char* candidate : candidates) {
            if (!open_library(candidate, last_error)) continue;
            std::string missing;
            if (load_all(missing)) return;
            last_error = "SQLite runtime " + std::string(candidate)
                + " is missing required symbol " + missing;
            close_library();
        }
        std::string message = "No compatible SQLite runtime library is available";
        if (!last_error.empty()) message += ": " + last_error;
        throw DocumentationError(DocumentationErrorCode::Sqlite, message + ".");
    }

    bool open_library(const char* name, std::string& error) {
#ifdef _WIN32
        library_ = LoadLibraryA(name);
        if (library_ == nullptr) {
            error = "could not load " + std::string(name);
            return false;
        }
#else
        dlerror();
        library_ = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (library_ == nullptr) {
            const char* detail = dlerror();
            error = detail == nullptr ? "could not load " + std::string(name)
                                      : std::string(detail);
            return false;
        }
#endif
        return true;
    }

    void close_library() noexcept {
#ifdef _WIN32
        if (library_ != nullptr) FreeLibrary(library_);
#else
        if (library_ != nullptr) dlclose(library_);
#endif
        library_ = nullptr;
    }

    template<typename Function>
    bool load(Function& output, const char* name) noexcept {
#ifdef _WIN32
        const auto symbol = GetProcAddress(library_, name);
#else
        const auto symbol = dlsym(library_, name);
#endif
        if (symbol == nullptr) return false;
        static_assert(sizeof(output) == sizeof(symbol),
            "dynamic-library function pointers must fit in symbol pointers");
        std::memcpy(&output, &symbol, sizeof(output));
        return true;
    }

    bool load_all(std::string& missing) noexcept {
#define TUNGSTEN_LOAD_SQLITE(member, symbol_name) \
        if (!load(member, symbol_name)) {          \
            missing = symbol_name;                 \
            return false;                          \
        }
        TUNGSTEN_LOAD_SQLITE(open_v2, "sqlite3_open_v2")
        TUNGSTEN_LOAD_SQLITE(close, "sqlite3_close")
        TUNGSTEN_LOAD_SQLITE(errmsg, "sqlite3_errmsg")
        TUNGSTEN_LOAD_SQLITE(exec, "sqlite3_exec")
        TUNGSTEN_LOAD_SQLITE(free_memory, "sqlite3_free")
        TUNGSTEN_LOAD_SQLITE(prepare_v2, "sqlite3_prepare_v2")
        TUNGSTEN_LOAD_SQLITE(step, "sqlite3_step")
        TUNGSTEN_LOAD_SQLITE(finalize, "sqlite3_finalize")
        TUNGSTEN_LOAD_SQLITE(reset, "sqlite3_reset")
        TUNGSTEN_LOAD_SQLITE(clear_bindings, "sqlite3_clear_bindings")
        TUNGSTEN_LOAD_SQLITE(bind_text, "sqlite3_bind_text")
        TUNGSTEN_LOAD_SQLITE(bind_int64, "sqlite3_bind_int64")
        TUNGSTEN_LOAD_SQLITE(column_text, "sqlite3_column_text")
        TUNGSTEN_LOAD_SQLITE(column_bytes, "sqlite3_column_bytes")
        TUNGSTEN_LOAD_SQLITE(column_int64, "sqlite3_column_int64")
        TUNGSTEN_LOAD_SQLITE(column_double, "sqlite3_column_double")
        TUNGSTEN_LOAD_SQLITE(column_type, "sqlite3_column_type")
        TUNGSTEN_LOAD_SQLITE(last_insert_rowid, "sqlite3_last_insert_rowid")
#undef TUNGSTEN_LOAD_SQLITE
        return true;
    }

#ifdef _WIN32
    HMODULE library_ = nullptr;
#else
    void* library_ = nullptr;
#endif
};

std::string path_text(const fs::path& path) { return path.u8string(); }

std::string sqlite_message(
    const SqliteApi& api, sqlite3* database, const std::string& context, int code,
    const std::string& explicit_message = {}) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << context << " (SQLite error " << code << ')';
    const char* detail = database == nullptr ? nullptr : api.errmsg(database);
    if (!explicit_message.empty()) output << ": " << explicit_message;
    else if (detail != nullptr && *detail != '\0') output << ": " << detail;
    return output.str();
}

[[noreturn]] void throw_sqlite(
    const SqliteApi& api, sqlite3* database, const std::string& context, int code,
    const std::string& explicit_message = {}) {
    throw DocumentationError(DocumentationErrorCode::Sqlite,
        sqlite_message(api, database, context, code, explicit_message));
}

class Database;

class Statement {
public:
    Statement(Database& database, const std::string& sql);
    Statement(const Statement&) = delete;
    Statement& operator=(const Statement&) = delete;

    ~Statement();

    void bind_text(int index, const std::string& value);
    void bind_int64(int index, std::int64_t value);
    [[nodiscard]] int step();
    void expect_done();
    void reset_and_clear();
    [[nodiscard]] std::string column_string(int index) const;
    [[nodiscard]] std::int64_t column_integer(int index) const;
    [[nodiscard]] double column_real(int index) const;

private:
    static void release_bound_text(void* value) noexcept {
        delete[] static_cast<char*>(value);
    }

    Database& database_;
    sqlite3_stmt* statement_ = nullptr;
};

class Database {
public:
    explicit Database(const fs::path& path)
        : api_(SqliteApi::instance()) {
        const auto encoded = path_text(path);
        const int result = api_.open_v2(encoded.c_str(), &database_,
            sqlite_open_readwrite | sqlite_open_create, nullptr);
        if (result != sqlite_ok) {
            const auto message = sqlite_message(
                api_, database_, "could not open documentation index", result);
            if (database_ != nullptr) api_.close(database_);
            database_ = nullptr;
            throw DocumentationError(DocumentationErrorCode::Sqlite, message);
        }
    }

    Database(const Database&) = delete;
    Database& operator=(const Database&) = delete;

    ~Database() {
        if (database_ != nullptr) api_.close(database_);
    }

    void execute(const std::string& sql) {
        char* detail = nullptr;
        const int result = api_.exec(
            database_, sql.c_str(), nullptr, nullptr, &detail);
        if (result == sqlite_ok) return;
        std::string copied = detail == nullptr ? std::string{} : std::string(detail);
        if (detail != nullptr) api_.free_memory(detail);
        throw_sqlite(api_, database_, "documentation index query failed", result, copied);
    }

    [[nodiscard]] std::int64_t last_insert_rowid() const noexcept {
        return api_.last_insert_rowid(database_);
    }

    [[nodiscard]] const SqliteApi& api() const noexcept { return api_; }
    [[nodiscard]] sqlite3* handle() const noexcept { return database_; }

private:
    const SqliteApi& api_;
    sqlite3* database_ = nullptr;
};

Statement::Statement(Database& database, const std::string& sql)
    : database_(database) {
    const int result = database_.api().prepare_v2(database_.handle(), sql.c_str(),
        -1, &statement_, nullptr);
    if (result != sqlite_ok)
        throw_sqlite(database_.api(), database_.handle(),
            "could not prepare documentation index query", result);
}

Statement::~Statement() {
    if (statement_ != nullptr) database_.api().finalize(statement_);
}

void Statement::bind_text(int index, const std::string& value) {
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        throw DocumentationError(DocumentationErrorCode::Sqlite,
            "documentation index text exceeds SQLite's binding limit");
    auto copy = std::make_unique<char[]>(std::max<std::size_t>(value.size(), 1));
    if (!value.empty()) std::memcpy(copy.get(), value.data(), value.size());
    char* transferred = copy.release();
    const int result = database_.api().bind_text(statement_, index, transferred,
        static_cast<int>(value.size()), &Statement::release_bound_text);
    if (result != sqlite_ok)
        throw_sqlite(database_.api(), database_.handle(),
            "could not bind documentation index text", result);
}

void Statement::bind_int64(int index, std::int64_t value) {
    const int result = database_.api().bind_int64(statement_, index, value);
    if (result != sqlite_ok)
        throw_sqlite(database_.api(), database_.handle(),
            "could not bind documentation index integer", result);
}

int Statement::step() { return database_.api().step(statement_); }

void Statement::expect_done() {
    const int result = step();
    if (result != sqlite_done)
        throw_sqlite(database_.api(), database_.handle(),
            "documentation index query did not complete", result);
}

void Statement::reset_and_clear() {
    int result = database_.api().reset(statement_);
    if (result != sqlite_ok)
        throw_sqlite(database_.api(), database_.handle(),
            "could not reset documentation index query", result);
    result = database_.api().clear_bindings(statement_);
    if (result != sqlite_ok)
        throw_sqlite(database_.api(), database_.handle(),
            "could not clear documentation index bindings", result);
}

std::string Statement::column_string(int index) const {
    if (database_.api().column_type(statement_, index) == sqlite_null)
        throw DocumentationError(DocumentationErrorCode::Sqlite,
            "documentation index returned NULL for a required text field");
    const auto* text = database_.api().column_text(statement_, index);
    const int size = database_.api().column_bytes(statement_, index);
    if (text == nullptr || size < 0)
        throw DocumentationError(DocumentationErrorCode::Sqlite,
            "could not read documentation index text");
    return {reinterpret_cast<const char*>(text), static_cast<std::size_t>(size)};
}

std::int64_t Statement::column_integer(int index) const {
    return database_.api().column_int64(statement_, index);
}

double Statement::column_real(int index) const {
    return database_.api().column_double(statement_, index);
}

fs::path absolute_path(const fs::path& path) {
    std::error_code error;
    auto canonical = fs::canonical(path, error);
    if (!error) return canonical;
    if (path.is_absolute()) return path.lexically_normal();
    auto absolute = fs::absolute(path, error);
    return error ? path : absolute.lexically_normal();
}

std::string lowercase_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return detail::ascii_lower(character);
    });
    return value;
}

bool ascii_alphanumeric(unsigned char character) noexcept {
    return (character >= 'a' && character <= 'z')
        || (character >= 'A' && character <= 'Z')
        || (character >= '0' && character <= '9');
}

bool identifier_character(unsigned char character) noexcept {
    return ascii_alphanumeric(character) || character == '_' || character == '.'
        || character == '-';
}

bool match_term_character(unsigned char character) noexcept {
    return identifier_character(character) || character == ':' || character == '/';
}

std::string build_match_query(const std::string& query) {
    std::vector<std::string> terms;
    for (std::size_t index = 0; index < query.size();) {
        while (index < query.size()
            && !match_term_character(static_cast<unsigned char>(query[index]))) ++index;
        const auto start = index;
        while (index < query.size()
            && match_term_character(static_cast<unsigned char>(query[index]))) ++index;
        if (index > start) terms.push_back(query.substr(start, index - start));
    }
    if (terms.empty()) return '"' + query + '"';
    std::string result;
    for (const auto& term : terms) {
        if (!result.empty()) result += " AND ";
        result += '"' + term + "\"*";
    }
    return result;
}

bool valid_identifier_stem(const std::string& value) noexcept {
    return !value.empty()
        && std::all_of(value.begin(), value.end(), [](unsigned char character) {
               return identifier_character(character);
           });
}

std::string stem_from_identifier(const std::string& identifier) {
    std::string candidate = identifier;
    if (identifier.rfind("paclet:", 0) == 0) {
        const auto separator = identifier.rfind('/');
        candidate = separator == std::string::npos
            ? identifier : identifier.substr(separator + 1);
    }
    const auto stem = path_text(fs::u8path(candidate).stem());
    return valid_identifier_stem(stem) ? stem : std::string{};
}

std::string read_utf8_lossy(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        throw DocumentationError(DocumentationErrorCode::Io,
            "could not open documentation notebook: " + path_text(path));
    const std::string bytes{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.eof() && stream.fail())
        throw DocumentationError(DocumentationErrorCode::Io,
            "could not read documentation notebook: " + path_text(path));
    return decode_utf8_lossy(bytes);
}

bool unicode_whitespace(std::uint32_t value) noexcept {
    return (value >= 0x09 && value <= 0x0d)
        || (value >= 0x1c && value <= 0x20) || value == 0x85
        || value == 0xa0 || value == 0x1680
        || (value >= 0x2000 && value <= 0x200a) || value == 0x2028
        || value == 0x2029 || value == 0x202f || value == 0x205f || value == 0x3000;
}

struct DecodedCharacter {
    std::uint32_t value;
    std::size_t length;
};

DecodedCharacter decode_utf8(const std::string& value, std::size_t position) noexcept {
    const auto lead = static_cast<unsigned char>(value[position]);
    if (lead < 0x80) return {lead, 1};
    std::size_t length = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
    std::uint32_t codepoint = lead & (length == 2 ? 0x1f : length == 3 ? 0x0f : 0x07);
    for (std::size_t index = 1; index < length && position + index < value.size(); ++index) {
        codepoint = (codepoint << 6)
            | (static_cast<unsigned char>(value[position + index]) & 0x3f);
    }
    return {codepoint, std::min(length, value.size() - position)};
}

std::string trim_unicode(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size()) {
        const auto decoded = decode_utf8(value, begin);
        if (!unicode_whitespace(decoded.value)) break;
        begin += decoded.length;
    }
    std::size_t end = begin;
    std::size_t last_non_space = begin;
    while (end < value.size()) {
        const auto decoded = decode_utf8(value, end);
        end += decoded.length;
        if (!unicode_whitespace(decoded.value)) last_non_space = end;
    }
    return value.substr(begin, last_non_space - begin);
}

bool is_uuid(const std::string& value) noexcept {
    constexpr std::size_t separators[] = {8, 13, 18, 23};
    if (value.size() != 36) return false;
    for (std::size_t index = 0; index < value.size(); ++index) {
        const bool separator = std::find(std::begin(separators), std::end(separators), index)
            != std::end(separators);
        const unsigned char character = static_cast<unsigned char>(value[index]);
        if (separator ? character != '-' : !detail::ascii_is_hex_digit(character)) return false;
    }
    return true;
}

bool is_compressed_blob(const std::string& value) noexcept {
    if (value.size() < 200) return false;
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return ascii_alphanumeric(character) || character == '+' || character == '/'
            || character == '=' || character == ':' || character == '.'
            || character == '_' || character == '-';
    });
}

std::vector<std::string> filter_useful_strings(
    const std::vector<std::string>& strings) {
    static const std::set<std::string> noise{
        "AnchorBar", "AnchorBarGrid", "Columns", "ExampleCount",
        "ExampleSection", "LinkHand", "ObjectNameTranslation", "PacletNameCell",
        "PrimaryExamplesSection", "Rows", "SeeAlsoRelated", "Spacer1"};
    std::vector<std::string> filtered;
    filtered.reserve(strings.size());
    for (const auto& value : strings) {
        auto trimmed = trim_unicode(value);
        if (trimmed.empty() || noise.count(trimmed) != 0 || is_uuid(trimmed)
            || is_compressed_blob(trimmed)) continue;
        filtered.push_back(std::move(trimmed));
    }
    return filtered;
}

std::string extract_title(const std::string& raw, const fs::path& notebook_path) {
    constexpr const char* marker = "WindowTitle->";
    std::size_t search = 0;
    while ((search = raw.find(marker, search)) != std::string::npos) {
        auto position = search + std::strlen(marker);
        if (position < raw.size() && raw[position] == '"') {
            ++position;
            const auto begin = position;
            while (position < raw.size()) {
                if (raw[position] == '\\' && position + 1 < raw.size()) {
                    position += 2;
                    continue;
                }
                if (raw[position] == '"') {
                    auto title = raw.substr(begin, position - begin);
                    std::size_t escaped = 0;
                    while ((escaped = title.find("\\\"", escaped)) != std::string::npos) {
                        title.replace(escaped, 2, "\"");
                        ++escaped;
                    }
                    return title;
                }
                ++position;
            }
        } else {
            const auto begin = position;
            while (position < raw.size()) {
                const unsigned char character = static_cast<unsigned char>(raw[position]);
                if (!(ascii_alphanumeric(character) || character == '`'
                        || character == '.' || character == '$' || character == '_'
                        || character == '-')) break;
                ++position;
            }
            if (position > begin) return raw.substr(begin, position - begin);
        }
        search += std::strlen(marker);
    }
    return path_text(notebook_path.stem());
}

struct DocumentIdentity {
    std::string kind;
    std::string category;
    std::string paclet;
};

DocumentIdentity infer_kind_and_paclet(const fs::path& notebook_path) {
    static const std::vector<std::pair<std::string, std::string>> references{
        {"Symbols", "ref"}, {"Programs", "ref/program"},
        {"MenuItems", "ref/menuitem"}, {"Characters", "ref/character"},
        {"Entities", "ref/entity"}, {"Interpreters", "ref/interpreter"},
        {"FrontEndObjects", "ref/frontendobject"}};
    static const std::vector<std::pair<std::string, std::string>> sections{
        {"Guides", "guide"}, {"Tutorials", "tutorial"},
        {"HowTos", "howto"}, {"Workflows", "workflow"},
        {"WorkflowGuides", "workflowguide"}, {"ExamplePages", "example"}};

    std::vector<std::string> parts;
    for (const auto& part : notebook_path) parts.push_back(path_text(part));
    const auto stem = path_text(notebook_path.stem());
    const auto reference = std::find(parts.begin(), parts.end(), "ReferencePages");
    if (reference != parts.end() && std::next(reference) != parts.end()) {
        const auto category = *std::next(reference);
        const auto known = std::find_if(references.begin(), references.end(),
            [&](const auto& item) { return item.first == category; });
        const auto paclet_category = known == references.end()
            ? "ref/" + lowercase_ascii(category) : known->second;
        return {"reference", category, "paclet:" + paclet_category + '/' + stem};
    }
    for (const auto& section : sections) {
        if (std::find(parts.begin(), parts.end(), section.first) != parts.end())
            return {section.second, section.first,
                "paclet:" + section.second + '/' + stem};
    }
    return {"document", "Other", "paclet:document/" + stem};
}

JsonValue document_row(Statement& statement) {
    return JsonValue::object({
        {"id", static_cast<long long>(statement.column_integer(0))},
        {"title", statement.column_string(1)},
        {"paclet", statement.column_string(2)},
        {"kind", statement.column_string(3)},
        {"category", statement.column_string(4)},
        {"path", statement.column_string(5)},
        {"preview", statement.column_string(6)},
        {"text", statement.column_string(7)},
    });
}

std::optional<JsonValue> query_document(
    Database& database, const std::string& sql, const std::string& value,
    bool bind_twice = false) {
    Statement statement(database, sql);
    statement.bind_text(1, value);
    if (bind_twice) statement.bind_text(2, value);
    const int result = statement.step();
    if (result == sqlite_row) return document_row(statement);
    if (result == sqlite_done) return std::nullopt;
    throw_sqlite(database.api(), database.handle(),
        "documentation index query failed", result);
}

void collect_named_notebooks(
    const fs::path& path, const std::string& stem, std::vector<fs::path>& output,
    std::set<fs::path>& visited_directories) {
    std::error_code error;
    const auto status = fs::symlink_status(path, error);
    if (error || fs::is_symlink(status)) return;
    if (fs::is_regular_file(status)) {
        if (lowercase_ascii(path_text(path.filename()))
                == lowercase_ascii(stem + ".nb")) output.push_back(path);
        return;
    }
    if (!fs::is_directory(status)) return;
    const auto resolved = fs::canonical(path, error);
    if (error || !visited_directories.insert(resolved).second) return;
    error.clear();
    fs::directory_iterator iterator(path, fs::directory_options::skip_permission_denied, error);
    if (error) return;
    for (const auto& entry : iterator)
        collect_named_notebooks(
            entry.path(), stem, output, visited_directories);
}

bool path_component_equal(const fs::path& left, const fs::path& right) {
#ifdef _WIN32
    return lowercase_ascii(path_text(left)) == lowercase_ascii(path_text(right));
#else
    return left == right;
#endif
}

bool path_is_within(const fs::path& candidate, const fs::path& root) {
    auto candidate_part = candidate.begin();
    for (auto root_part = root.begin(); root_part != root.end();
         ++root_part, ++candidate_part) {
        if (candidate_part == candidate.end()
            || !path_component_equal(*candidate_part, *root_part)) return false;
    }
    return true;
}

std::string quote_not_found(const std::string& identifier) {
    return "No documentation page found for " + JsonValue(identifier).dump() + ".";
}

} // namespace

DocumentationError::DocumentationError(
    DocumentationErrorCode code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

DocumentationErrorCode DocumentationError::code() const noexcept { return code_; }

JsonValue DocumentationRecord::to_json() const {
    return JsonValue::object({
        {"title", title},
        {"paclet", paclet},
        {"kind", kind},
        {"category", category},
        {"path", path},
        {"preview", preview},
        {"text", text},
    });
}

DocumentationIndex::DocumentationIndex()
    : DocumentationIndex(discover_installation()) {}

DocumentationIndex::DocumentationIndex(WolframInstallation installation)
    : installation_(std::move(installation)) {}

const WolframInstallation& DocumentationIndex::installation() const noexcept {
    return installation_;
}

fs::path DocumentationIndex::ensure_index(
    const std::optional<fs::path>& index_path, bool rebuild) const {
    const auto target = index_path.value_or(installation_.default_index_path);
    try {
        if (rebuild || !fs::exists(target)) (void)build_index(target);
    } catch (const DocumentationError&) {
        throw;
    } catch (const fs::filesystem_error& error) {
        throw DocumentationError(DocumentationErrorCode::Io, error.what());
    }
    return target;
}

fs::path DocumentationIndex::build_index(
    const std::optional<fs::path>& index_path) const {
    const auto target = index_path.value_or(installation_.default_index_path);
    try {
        ensure_parent_directory(target);
        if (fs::exists(target)) fs::remove(target);
    } catch (const fs::filesystem_error& error) {
        throw DocumentationError(DocumentationErrorCode::Io, error.what());
    }

    Database database(target);
    database.execute(
        "CREATE TABLE documents ("
        "id INTEGER PRIMARY KEY,"
        "title TEXT NOT NULL,"
        "paclet TEXT NOT NULL,"
        "kind TEXT NOT NULL,"
        "category TEXT NOT NULL,"
        "path TEXT NOT NULL,"
        "preview TEXT NOT NULL,"
        "text TEXT NOT NULL"
        ");"
        "CREATE VIRTUAL TABLE documents_fts USING fts5("
        "title,paclet,kind,category,preview,text,"
        "content='documents',content_rowid='id'"
        ");"
        "CREATE TABLE metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL);");

    JsonValue::Array roots;
    roots.reserve(installation_.docs_roots.size());
    for (const auto& root : installation_.docs_roots) roots.emplace_back(path_text(root));
    {
        Statement metadata(database,
            "INSERT INTO metadata(key,value) VALUES(?1,?2)");
        metadata.bind_text(1, "docs_roots");
        metadata.bind_text(2, JsonValue(std::move(roots)).dump());
        metadata.expect_done();
    }

    database.execute("BEGIN");
    try {
        Statement documents(database,
            "INSERT INTO documents(title,paclet,kind,category,path,preview,text)"
            " VALUES(?1,?2,?3,?4,?5,?6,?7)");
        Statement full_text(database,
            "INSERT INTO documents_fts(rowid,title,paclet,kind,category,preview,text)"
            " VALUES(?1,?2,?3,?4,?5,?6,?7)");
        for (const auto& notebook_path : notebook_files(installation_.docs_roots)) {
            const auto record = record_from_path(notebook_path);
            documents.bind_text(1, record.title);
            documents.bind_text(2, record.paclet);
            documents.bind_text(3, record.kind);
            documents.bind_text(4, record.category);
            documents.bind_text(5, record.path);
            documents.bind_text(6, record.preview);
            documents.bind_text(7, record.text);
            documents.expect_done();
            const auto rowid = database.last_insert_rowid();
            documents.reset_and_clear();

            full_text.bind_int64(1, rowid);
            full_text.bind_text(2, record.title);
            full_text.bind_text(3, record.paclet);
            full_text.bind_text(4, record.kind);
            full_text.bind_text(5, record.category);
            full_text.bind_text(6, record.preview);
            full_text.bind_text(7, record.text);
            full_text.expect_done();
            full_text.reset_and_clear();
        }
        database.execute("COMMIT");
    } catch (...) {
        try {
            database.execute("ROLLBACK");
        } catch (...) {
        }
        throw;
    }
    return target;
}

std::vector<JsonValue> DocumentationIndex::search(
    const std::string& query, const std::optional<fs::path>& index_path,
    std::size_t limit, bool rebuild) const {
    auto fast = search_by_filename(query, limit);
    if (!fast.empty()) return fast;

    const auto target = ensure_index(index_path, rebuild);
    Database database(target);
    Statement statement(database,
        "SELECT documents.title,documents.paclet,documents.kind,documents.category,"
        "documents.path,documents.preview,"
        "snippet(documents_fts,5,'[',']',' … ',18) AS snippet,"
        "bm25(documents_fts) AS score "
        "FROM documents_fts JOIN documents ON documents.id=documents_fts.rowid "
        "WHERE documents_fts MATCH ?1 ORDER BY score LIMIT ?2");
    statement.bind_text(1, build_match_query(query));
    const auto sqlite_limit = limit > static_cast<std::size_t>(
            std::numeric_limits<std::int64_t>::max())
        ? std::numeric_limits<std::int64_t>::max()
        : static_cast<std::int64_t>(limit);
    statement.bind_int64(2, sqlite_limit);

    std::vector<JsonValue> hits;
    while (true) {
        const int result = statement.step();
        if (result == sqlite_done) break;
        if (result != sqlite_row)
            throw_sqlite(database.api(), database.handle(),
                "documentation search failed", result);
        hits.push_back(JsonValue::object({
            {"title", statement.column_string(0)},
            {"paclet", statement.column_string(1)},
            {"kind", statement.column_string(2)},
            {"category", statement.column_string(3)},
            {"path", statement.column_string(4)},
            {"preview", statement.column_string(5)},
            {"snippet", statement.column_string(6)},
            {"score", statement.column_real(7)},
        }));
    }
    return hits;
}

JsonValue DocumentationIndex::read(
    const std::string& identifier, const std::optional<fs::path>& index_path,
    bool rebuild) const {
    const auto stem = stem_from_identifier(identifier);
    if (!stem.empty()) {
        auto paths = find_notebook_paths(stem, 1);
        if (!paths.empty()) return record_from_path(paths.front()).to_json();
    }

    const auto target = ensure_index(index_path, rebuild);
    Database database(target);
    std::optional<JsonValue> row;
    std::error_code exists_error;
    const auto identifier_path = fs::u8path(identifier);
    const bool path_exists = fs::exists(identifier_path, exists_error);
    if (exists_error)
        throw DocumentationError(DocumentationErrorCode::Io,
            "could not inspect documentation path: " + exists_error.message());
    if (path_exists) {
        row = query_document(database,
            "SELECT * FROM documents WHERE path=?1",
            path_text(absolute_path(identifier_path)));
    } else if (identifier.rfind("paclet:", 0) == 0) {
        row = query_document(database,
            "SELECT * FROM documents WHERE paclet=?1 COLLATE NOCASE", identifier);
    } else {
        row = query_document(database,
            "SELECT * FROM documents WHERE title=?1 COLLATE NOCASE OR "
            "paclet=?2 COLLATE NOCASE LIMIT 1", identifier, true);
    }
    if (row) return std::move(*row);

    const auto hits = search(identifier, target, 1, false);
    if (hits.empty())
        throw DocumentationError(
            DocumentationErrorCode::NotFound, quote_not_found(identifier));
    const auto* paclet = hits.front().find("paclet");
    if (paclet == nullptr || !paclet->is_string())
        throw DocumentationError(
            DocumentationErrorCode::NotFound, quote_not_found(identifier));
    row = query_document(database,
        "SELECT * FROM documents WHERE paclet=?1", paclet->as_string());
    if (!row)
        throw DocumentationError(
            DocumentationErrorCode::NotFound, quote_not_found(identifier));
    return std::move(*row);
}

std::string DocumentationIndex::resolve_identifier(
    const std::string& identifier,
    const std::optional<fs::path>& index_path) const {
    if (identifier.rfind("paclet:", 0) == 0) return identifier;
    const auto record = read(identifier, index_path, false);
    const auto* paclet = record.find("paclet");
    if (paclet == nullptr || !paclet->is_string())
        throw DocumentationError(
            DocumentationErrorCode::NotFound, quote_not_found(identifier));
    return paclet->as_string();
}

DocumentationRecord DocumentationIndex::record_from_path(
    const fs::path& notebook_path) const {
    const auto raw = read_utf8_lossy(notebook_path);
    const auto title = extract_title(raw, notebook_path);
    const auto identity = infer_kind_and_paclet(notebook_path);
    const auto strings = filter_useful_strings(extract_string_literals(raw));

    std::string joined;
    std::string preview_source;
    for (const auto& fragment : strings) {
        if (!joined.empty()) joined.push_back(' ');
        joined += fragment;
        if (!fragment.empty() && fragment != title) {
            if (!preview_source.empty()) preview_source.push_back(' ');
            preview_source += fragment;
        }
    }
    return {
        title,
        identity.paclet,
        identity.kind,
        identity.category,
        path_text(absolute_path(notebook_path)),
        collapse_text(preview_source, 300),
        collapse_text(joined, 20'000),
    };
}

std::vector<JsonValue> DocumentationIndex::search_by_filename(
    const std::string& query, std::size_t limit) const {
    const auto stem = stem_from_identifier(query);
    if (stem.empty()) return {};
    const auto expanded_limit = limit > std::numeric_limits<std::size_t>::max() / 4
        ? std::numeric_limits<std::size_t>::max() : limit * 4;
    const auto paths = find_notebook_paths(stem, expanded_limit);
    std::vector<JsonValue> results;
    results.reserve(std::min(paths.size(), limit));
    for (std::size_t index = 0; index < paths.size() && index < limit; ++index) {
        const auto record = record_from_path(paths[index]);
        results.push_back(JsonValue::object({
            {"title", record.title},
            {"paclet", record.paclet},
            {"kind", record.kind},
            {"category", record.category},
            {"path", record.path},
            {"preview", record.preview},
            {"snippet", record.preview},
            {"score", 0.0},
        }));
    }
    return results;
}

std::vector<fs::path> DocumentationIndex::find_notebook_paths(
    const std::string& stem, std::size_t limit) const {
    std::vector<fs::path> roots;
    roots.reserve(installation_.docs_roots.size());
    for (const auto& root : installation_.docs_roots) roots.push_back(absolute_path(root));

    std::vector<fs::path> candidates;
    std::set<fs::path> visited_directories;
    for (const auto& root : roots)
        collect_named_notebooks(root, stem, candidates, visited_directories);

    std::set<fs::path> seen;
    std::vector<fs::path> filtered;
    for (const auto& candidate : candidates) {
        std::error_code error;
        const auto resolved = fs::canonical(candidate, error);
        if (error || !seen.insert(resolved).second) continue;
        if (lowercase_ascii(path_text(resolved.extension())) != ".nb"
            || lowercase_ascii(path_text(resolved.stem())) != lowercase_ascii(stem)) continue;
        const bool under_root = std::any_of(roots.begin(), roots.end(), [&](const auto& root) {
            return path_is_within(resolved, root);
        });
        if (under_root) filtered.push_back(resolved);
    }
    std::sort(filtered.begin(), filtered.end(), [&](const auto& left, const auto& right) {
        return root_priority(left) < root_priority(right);
    });
    if (filtered.size() > limit) filtered.resize(limit);
    return filtered;
}

std::pair<std::size_t, std::string> DocumentationIndex::root_priority(
    const fs::path& path) const {
    const auto normalized = lowercase_ascii(path_text(absolute_path(path)));
    const auto absolute = absolute_path(path);
    for (std::size_t index = 0; index < installation_.docs_roots.size(); ++index) {
        if (path_is_within(
                absolute, absolute_path(installation_.docs_roots[index])))
            return {index, normalized};
    }
    return {installation_.docs_roots.size(), normalized};
}

} // namespace tungsten
