#pragma once

#include "tungsten/json.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace tungsten {

enum class NotebookErrorCode {
    NotebookExpressionNotFound,
    NotNotebook,
    Syntax,
    InvalidOperation,
    Io,
    Json,
};

class NotebookError : public std::runtime_error {
public:
    explicit NotebookError(std::string message);
    NotebookError(NotebookErrorCode code, std::string message);

    [[nodiscard]] NotebookErrorCode code() const noexcept;

private:
    NotebookErrorCode code_;
};

// A byte range into a shared, immutable UTF-8 source buffer.  Parsed notebook
// values use spans so a large .nb file is retained once rather than copied into
// every cell, option, and group wrapper.
class SourceSpan {
public:
    SourceSpan();
    SourceSpan(std::shared_ptr<const std::string> source,
        std::size_t start, std::size_t end);
    SourceSpan(std::string source, std::size_t start, std::size_t end);
    SourceSpan(const SourceSpan&) noexcept = default;
    SourceSpan& operator=(const SourceSpan&) noexcept = default;
    SourceSpan(SourceSpan&& other) noexcept;
    SourceSpan& operator=(SourceSpan&& other) noexcept;

    [[nodiscard]] const std::string& source() const noexcept;
    [[nodiscard]] const std::shared_ptr<const std::string>& shared_source() const noexcept;
    [[nodiscard]] std::size_t start() const noexcept;
    [[nodiscard]] std::size_t end() const noexcept;
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] bool empty() const noexcept;
    [[nodiscard]] std::string_view view() const noexcept;
    [[nodiscard]] std::string text() const;
    [[nodiscard]] SourceSpan strip() const;
    [[nodiscard]] bool starts_with(std::string_view prefix) const noexcept;
    [[nodiscard]] bool ends_with(std::string_view suffix) const noexcept;
    explicit operator bool() const noexcept;
    operator std::string() const;

    friend bool operator==(const SourceSpan& left, const SourceSpan& right) noexcept;
    friend bool operator!=(const SourceSpan& left, const SourceSpan& right) noexcept {
        return !(left == right);
    }

private:
    std::shared_ptr<const std::string> source_;
    std::size_t start_ = 0;
    std::size_t end_ = 0;
};

// String-like public wrapper around either owned text (for edits) or a lazy
// source span (for parsed values).  text() materializes a span only on demand.
class SourceText {
public:
    SourceText();
    SourceText(const char* text);
    SourceText(std::string text);
    SourceText(SourceSpan span);

    SourceText& operator=(const char* text);
    SourceText& operator=(std::string text);
    SourceText& operator=(SourceSpan span);

    [[nodiscard]] bool is_span() const noexcept;
    [[nodiscard]] bool is_materialized() const noexcept;
    [[nodiscard]] const SourceSpan* span() const noexcept;
    [[nodiscard]] std::string_view view() const noexcept;
    [[nodiscard]] const std::string& text() const;
    [[nodiscard]] std::string str() const;
    [[nodiscard]] bool empty() const noexcept;
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] bool starts_with(std::string_view prefix) const noexcept;
    [[nodiscard]] bool ends_with(std::string_view suffix) const noexcept;
    [[nodiscard]] std::size_t find(
        std::string_view value, std::size_t position = 0) const noexcept;
    [[nodiscard]] std::string substr(
        std::size_t position = 0, std::size_t count = std::string::npos) const;
    [[nodiscard]] char front() const;
    [[nodiscard]] char back() const;
    [[nodiscard]] char operator[](std::size_t index) const noexcept;
    void append_to(std::string& destination) const;

    // Supports existing call sites that accepted std::string values.  Parsed
    // spans are materialized when this conversion is used.
    operator std::string() const;

    friend bool operator==(const SourceText& left, const SourceText& right) noexcept;
    friend bool operator!=(const SourceText& left, const SourceText& right) noexcept {
        return !(left == right);
    }
    friend bool operator==(const SourceText& left, std::string_view right) noexcept;
    friend bool operator==(std::string_view left, const SourceText& right) noexcept;
    friend bool operator!=(const SourceText& left, std::string_view right) noexcept {
        return !(left == right);
    }
    friend bool operator!=(std::string_view left, const SourceText& right) noexcept {
        return !(left == right);
    }

private:
    std::variant<std::string, SourceSpan> value_;
    mutable std::optional<std::string> materialized_;
};

// Compatibility wrapper for the notebook module's original entry point.
[[nodiscard]] JsonValue parse_json(const std::string& text);
[[nodiscard]] JsonValue load_patch_spec(const std::filesystem::path& path);

struct NotebookCell {
    SourceText content_expr;
    std::optional<std::string> style;
    std::vector<SourceText> options;
    std::optional<SourceText> raw;

    NotebookCell() = default;
    explicit NotebookCell(
        std::string content,
        std::optional<std::string> cell_style = std::nullopt,
        std::vector<std::string> cell_options = {},
        std::optional<std::string> raw_source = std::nullopt);

    [[nodiscard]] std::string plain_text() const;
    [[nodiscard]] std::optional<std::int64_t> cell_id() const;
    [[nodiscard]] std::optional<std::string> expression_uuid() const;
    [[nodiscard]] std::vector<std::string> cell_tags() const;
    [[nodiscard]] std::string render() const;

    friend bool operator==(const NotebookCell& left, const NotebookCell& right);
};

struct NotebookItem;

struct NotebookGroup {
    std::vector<NotebookItem> children;
    std::vector<SourceText> group_tail;
    std::vector<SourceText> wrapper_options;
    std::optional<SourceText> raw;

    NotebookGroup() = default;
    explicit NotebookGroup(
        std::vector<NotebookItem> group_children,
        std::vector<std::string> tail = {},
        std::vector<std::string> options = {},
        std::optional<std::string> raw_source = std::nullopt);

    [[nodiscard]] std::string render() const;

    friend bool operator==(const NotebookGroup& left, const NotebookGroup& right);
};

struct NotebookRawItem {
    SourceText expression;

    NotebookRawItem() = default;
    explicit NotebookRawItem(std::string value) : expression(std::move(value)) {}
    explicit NotebookRawItem(SourceSpan value) : expression(std::move(value)) {}

    [[nodiscard]] std::string render() const { return expression.str(); }

    friend bool operator==(const NotebookRawItem& left, const NotebookRawItem& right);
};

enum class NotebookItemKind { Cell, Group, Raw };

struct NotebookItem {
    using Storage = std::variant<NotebookCell, NotebookGroup, NotebookRawItem>;
    Storage value;

    NotebookItem() : value(NotebookRawItem{}) {}
    NotebookItem(NotebookCell cell) : value(std::move(cell)) {}
    NotebookItem(NotebookGroup group) : value(std::move(group)) {}
    NotebookItem(NotebookRawItem raw_item) : value(std::move(raw_item)) {}

    [[nodiscard]] NotebookItemKind kind() const noexcept;
    [[nodiscard]] const char* kind_name() const noexcept;
    [[nodiscard]] NotebookCell* as_cell() noexcept;
    [[nodiscard]] const NotebookCell* as_cell() const noexcept;
    [[nodiscard]] NotebookGroup* as_group() noexcept;
    [[nodiscard]] const NotebookGroup* as_group() const noexcept;
    [[nodiscard]] NotebookRawItem* as_raw() noexcept;
    [[nodiscard]] const NotebookRawItem* as_raw() const noexcept;
    [[nodiscard]] std::string render() const;

    friend bool operator==(const NotebookItem& left, const NotebookItem& right);
};

struct NotebookSummary {
    std::optional<std::string> title;
    std::size_t cell_count = 0;
    std::size_t group_count = 0;
    std::size_t option_count = 0;

    friend bool operator==(const NotebookSummary& left, const NotebookSummary& right);
};

struct NotebookWalkItem {
    std::vector<std::size_t> path;
    NotebookItem* item = nullptr;
    std::size_t depth = 0;
};

struct ConstNotebookWalkItem {
    std::vector<std::size_t> path;
    const NotebookItem* item = nullptr;
    std::size_t depth = 0;
};

struct NotebookRow {
    std::size_t index = 0;
    NotebookItemKind kind = NotebookItemKind::Raw;
    std::vector<std::size_t> path;
    std::size_t depth = 0;
    std::optional<std::string> style;
    std::string preview;
    std::optional<std::int64_t> cell_id;
    std::optional<std::string> expression_uuid;
    std::vector<std::string> cell_tags;
    std::vector<std::string> options;

    [[nodiscard]] const char* kind_name() const noexcept;
    [[nodiscard]] JsonValue to_json_value() const;

    friend bool operator==(const NotebookRow& left, const NotebookRow& right);
};

class NotebookDocument {
public:
    std::vector<NotebookItem> items;
    std::vector<SourceText> options;
    std::string preamble;
    std::optional<std::filesystem::path> path;

    NotebookDocument() = default;
    explicit NotebookDocument(
        std::vector<NotebookItem> document_items,
        std::vector<std::string> document_options = {},
        std::string document_preamble = {},
        std::optional<std::filesystem::path> document_path = std::nullopt);

    [[nodiscard]] static NotebookDocument from_text(
        const std::string& text,
        std::optional<std::filesystem::path> source_path = std::nullopt);
    [[nodiscard]] static NotebookDocument load(const std::filesystem::path& path);

    [[nodiscard]] std::optional<std::string> title() const;
    [[nodiscard]] NotebookSummary summary() const;
    [[nodiscard]] std::vector<NotebookWalkItem> walk_items(
        std::vector<NotebookItem>* selected_items = nullptr,
        const std::vector<std::size_t>& prefix = {},
        std::size_t depth = 0);
    [[nodiscard]] std::vector<ConstNotebookWalkItem> walk_items(
        const std::vector<NotebookItem>* selected_items = nullptr,
        const std::vector<std::size_t>& prefix = {},
        std::size_t depth = 0) const;
    [[nodiscard]] std::vector<NotebookRow> flattened_cells() const;
    [[nodiscard]] JsonValue to_json_value() const;
    [[nodiscard]] std::string to_json() const;

    [[nodiscard]] NotebookRow cell_at_flat_index(std::size_t index) const;
    [[nodiscard]] NotebookRow cell_at_path(const std::vector<std::size_t>& path) const;
    [[nodiscard]] const NotebookItem& item_at_flat_index(std::size_t index) const;
    [[nodiscard]] NotebookItem& item_at_flat_index(std::size_t index);
    [[nodiscard]] const NotebookItem& item_at_path(const std::vector<std::size_t>& path) const;
    [[nodiscard]] NotebookItem& item_at_path(const std::vector<std::size_t>& path);

    [[nodiscard]] std::string render() const;
    std::filesystem::path save(
        std::optional<std::filesystem::path> destination = std::nullopt);

    NotebookCell& append_cell(
        std::optional<std::string> text = std::nullopt,
        std::optional<std::string> style = std::string("Text"),
        std::optional<std::string> content_expr = std::nullopt,
        const std::vector<std::size_t>& container_path = {});
    NotebookCell& insert_cell(
        std::size_t index,
        std::optional<std::string> text = std::nullopt,
        std::optional<std::string> style = std::string("Text"),
        std::optional<std::string> content_expr = std::nullopt,
        const std::vector<std::size_t>& container_path = {});
    NotebookCell& replace_cell(
        const std::vector<std::size_t>& path,
        std::optional<std::string> text = std::nullopt,
        std::optional<std::string> style = std::nullopt,
        std::optional<std::string> content_expr = std::nullopt);
    void delete_item(const std::vector<std::size_t>& path);
    void set_option(const std::string& name, const std::string& value_expr);

private:
    [[nodiscard]] std::vector<NotebookItem>& resolve_container(
        const std::vector<std::size_t>& group_path);
    [[nodiscard]] const std::vector<NotebookItem>& resolve_container(
        const std::vector<std::size_t>& group_path) const;
    void clear_raw_ancestors(const std::vector<std::size_t>& group_path);
};

[[nodiscard]] std::vector<std::string> split_top_level(const std::string& text);
[[nodiscard]] std::pair<std::string, std::vector<std::string>> parse_call(
    const std::string& expression);
[[nodiscard]] std::vector<std::string> parse_list(const std::string& expression);
[[nodiscard]] std::vector<std::string> extract_string_literals(const std::string& text);
[[nodiscard]] std::vector<std::string> extract_box_expressions(
    const std::string& expression);
[[nodiscard]] std::optional<std::string> rule_value(
    const std::vector<std::string>& options, const std::string& name);
[[nodiscard]] std::optional<std::string> rule_value(
    const std::vector<SourceText>& options, const std::string& name);
[[nodiscard]] std::string collapse_text(const std::string& text, std::size_t limit = 160);

void apply_patch_spec(NotebookDocument& document, const JsonValue& spec);

} // namespace tungsten
