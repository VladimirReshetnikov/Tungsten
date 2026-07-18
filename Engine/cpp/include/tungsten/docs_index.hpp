#pragma once

#include "tungsten/discovery.hpp"
#include "tungsten/json.hpp"

#include <cstddef>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace tungsten {

enum class DocumentationErrorCode {
    NotFound,
    Io,
    Sql,
    Sqlite = Sql,
    Json,
};

class DocumentationError : public std::runtime_error {
public:
    DocumentationError(DocumentationErrorCode code, std::string message);

    [[nodiscard]] DocumentationErrorCode code() const noexcept;

private:
    DocumentationErrorCode code_;
};

struct DocumentationRecord {
    std::string title;
    std::string paclet;
    std::string kind;
    std::string category;
    std::string path;
    std::string preview;
    std::string text;

    [[nodiscard]] JsonValue to_json() const;

    friend bool operator==(
        const DocumentationRecord& left,
        const DocumentationRecord& right) noexcept {
        return left.title == right.title
            && left.paclet == right.paclet
            && left.kind == right.kind
            && left.category == right.category
            && left.path == right.path
            && left.preview == right.preview
            && left.text == right.text;
    }
};

class DocumentationIndex {
public:
    DocumentationIndex();
    explicit DocumentationIndex(WolframInstallation installation);

    [[nodiscard]] const WolframInstallation& installation() const noexcept;

    [[nodiscard]] std::filesystem::path ensure_index(
        const std::optional<std::filesystem::path>& index_path = std::nullopt,
        bool rebuild = false) const;
    [[nodiscard]] std::filesystem::path build_index(
        const std::optional<std::filesystem::path>& index_path = std::nullopt) const;

    [[nodiscard]] std::vector<JsonValue> search(
        const std::string& query,
        const std::optional<std::filesystem::path>& index_path = std::nullopt,
        std::size_t limit = 10,
        bool rebuild = false) const;
    [[nodiscard]] JsonValue read(
        const std::string& identifier,
        const std::optional<std::filesystem::path>& index_path = std::nullopt,
        bool rebuild = false) const;
    [[nodiscard]] std::string resolve_identifier(
        const std::string& identifier,
        const std::optional<std::filesystem::path>& index_path = std::nullopt) const;

    [[nodiscard]] DocumentationRecord record_from_path(
        const std::filesystem::path& notebook_path) const;

private:
    [[nodiscard]] std::vector<JsonValue> search_by_filename(
        const std::string& query, std::size_t limit) const;
    [[nodiscard]] std::vector<std::filesystem::path> find_notebook_paths(
        const std::string& stem, std::size_t limit) const;
    [[nodiscard]] std::pair<std::size_t, std::string> root_priority(
        const std::filesystem::path& path) const;

    WolframInstallation installation_;
};

} // namespace tungsten
