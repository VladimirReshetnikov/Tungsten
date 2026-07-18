#include "tungsten/inline_boxes.hpp"

#include "tungsten/notebook.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <functional>
#include <locale>
#include <optional>
#include <sstream>
#include <type_traits>

namespace tungsten {
namespace {

JsonValue string_segments_json(const std::string& value) {
    JsonValue::Array output;
    for (const auto& segment : split_inline_boxes(value)) {
        JsonValue::Object record;
        for (const auto& [name, field] : segment.fields()) record.emplace(name, field);
        output.emplace_back(std::move(record));
    }
    return JsonValue(std::move(output));
}

JsonValue box_record(std::size_t index, const std::string& box_expression) {
    const auto [head, arguments] = parse_call(box_expression);
    static_cast<void>(arguments);
    const auto escaped = inline_box_escape(box_expression);
    return JsonValue::object({
        {"index", index},
        {"head", head.empty() ? JsonValue() : JsonValue(head)},
        {"box_expression", box_expression},
        {"inline_box_escape", escaped},
        {"string_literal", wl_string(escaped)},
    });
}

JsonValue box_records(const std::vector<std::string>& expressions) {
    JsonValue::Array output;
    output.reserve(expressions.size());
    for (std::size_t index = 0; index < expressions.size(); ++index)
        output.push_back(box_record(index, expressions[index]));
    return JsonValue(std::move(output));
}

NotebookRow resolve_unique(
    const NotebookDocument& document,
    const std::function<bool(const NotebookRow&)>& predicate) {
    std::optional<NotebookRow> result;
    for (const auto& row : document.flattened_cells()) {
        if (!predicate(row)) continue;
        if (result) {
            throw NotebookError(
                "The requested notebook cell selector matched more than one cell in the notebook file.");
        }
        result = row;
    }
    if (!result) {
        throw NotebookError(
            "The requested notebook cell selector did not match any cell in the notebook file.");
    }
    return *result;
}

NotebookRow resolve_row(
    const NotebookDocument& document,
    const InlineBoxCellSelector& selector) {
    return std::visit([&](const auto& selected) -> NotebookRow {
        using Selector = std::decay_t<decltype(selected)>;
        if constexpr (std::is_same_v<Selector, InlineBoxFlatIndexSelector>) {
            return document.cell_at_flat_index(selected.index);
        } else if constexpr (std::is_same_v<Selector, InlineBoxPathSelector>) {
            return document.cell_at_path(selected.path);
        } else if constexpr (std::is_same_v<Selector, InlineBoxExpressionUuidSelector>) {
            return resolve_unique(document, [&](const NotebookRow& row) {
                return row.expression_uuid == selected.value;
            });
        } else if constexpr (std::is_same_v<Selector, InlineBoxCellIdSelector>) {
            return resolve_unique(document, [&](const NotebookRow& row) {
                return row.cell_id == selected.value;
            });
        } else {
            return resolve_unique(document, [&](const NotebookRow& row) {
                return std::find(row.cell_tags.begin(), row.cell_tags.end(), selected.value)
                    != row.cell_tags.end();
            });
        }
    }, selector);
}

std::string canonical_path_text(const std::filesystem::path& path) {
    std::error_code error;
    const auto canonical = std::filesystem::canonical(path, error);
    return (error ? path : canonical).u8string();
}

} // namespace

JsonValue compose_inline_box_payload(
    const std::vector<std::string>& box_expressions,
    const std::string& prefix,
    const std::string& suffix) {
    const auto string_value = compose_inline_box_string(prefix, box_expressions, suffix);
    return JsonValue::object({
        {"success", true},
        {"prefix", prefix},
        {"suffix", suffix},
        {"box_count", box_expressions.size()},
        {"boxes", box_records(box_expressions)},
        {"string_value", string_value},
        {"string_literal", compose_inline_box_string_literal(
            prefix, box_expressions, suffix)},
        {"string_segments", string_segments_json(string_value)},
    });
}

JsonValue extract_inline_boxes_from_notebook_cell(
    const std::filesystem::path& notebook_path,
    const InlineBoxCellSelector& selector,
    const InlineBoxExtractionOptions& options) {
    const auto document = NotebookDocument::load(notebook_path);
    const auto row = resolve_row(document, selector);
    const auto& item = document.item_at_path(row.path);
    std::string source_expression;
    if (const auto* cell = item.as_cell()) source_expression = cell->content_expr;
    else if (const auto* raw = item.as_raw()) source_expression = raw->expression;
    else {
        return JsonValue::object({
            {"success", false},
            {"error_type", "UnsupportedNotebookItem"},
            {"error", "The requested notebook selector did not resolve to a notebook cell item."},
            {"source_cell", row.to_json_value()},
        });
    }

    const auto expressions = extract_box_expressions(source_expression);
    if (expressions.empty()) {
        return JsonValue::object({
            {"success", false},
            {"error_type", "NoInlineBoxObjectsFound"},
            {"error", "The selected notebook cell did not contain any inline box objects or box-bearing string escapes."},
            {"source_cell", row.to_json_value()},
        });
    }

    const auto available_boxes = box_records(expressions);
    std::vector<std::string> selected_expressions;
    JsonValue selected_boxes;
    JsonValue object_index;
    std::string selection_mode;
    if (options.all_objects) {
        selected_expressions = expressions;
        selected_boxes = available_boxes;
        selection_mode = "all";
    } else {
        if (options.object_index < 0
            || static_cast<std::size_t>(options.object_index) >= expressions.size()) {
            std::ostringstream message;
            message.imbue(std::locale::classic());
            message << "Requested object index " << options.object_index
                    << ", but the selected cell only contains " << expressions.size()
                    << " inline box object(s).";
            return JsonValue::object({
                {"success", false},
                {"error_type", "InlineBoxObjectIndexOutOfRange"},
                {"error", message.str()},
                {"source_cell", row.to_json_value()},
                {"available_box_count", expressions.size()},
            });
        }
        const auto index = static_cast<std::size_t>(options.object_index);
        selected_expressions = {expressions[index]};
        selected_boxes = JsonValue::Array{available_boxes.at(index)};
        object_index = options.object_index;
        selection_mode = "index";
    }
    const auto composed = compose_inline_box_payload(
        selected_expressions, options.prefix, options.suffix);
    return JsonValue::object({
        {"success", true},
        {"notebook_path", canonical_path_text(notebook_path)},
        {"source_cell", row.to_json_value()},
        {"selection_mode", selection_mode},
        {"object_index", object_index},
        {"available_box_count", expressions.size()},
        {"available_boxes", available_boxes},
        {"selected_box_count", selected_expressions.size()},
        {"selected_boxes", selected_boxes},
        {"prefix", options.prefix},
        {"suffix", options.suffix},
        {"string_value", composed.at("string_value")},
        {"string_literal", composed.at("string_literal")},
        {"string_segments", composed.at("string_segments")},
    });
}

} // namespace tungsten
