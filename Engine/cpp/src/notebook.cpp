#include "tungsten/notebook.hpp"
#include "tungsten/detail/ascii.hpp"

#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <fstream>
#include <limits>
#include <memory>
#include <sstream>
#include <string_view>

namespace tungsten {
namespace {

bool ascii_space(char value) {
    return detail::ascii_is_space(static_cast<unsigned char>(value));
}

struct Utf8CodePoint {
    std::uint32_t value = 0;
    std::size_t length = 1;
    bool valid = false;
};

Utf8CodePoint decode_utf8(
    const std::string& text, std::size_t index, std::size_t end) noexcept {
    if (index >= end) return {};
    const auto lead = static_cast<unsigned char>(text[index]);
    if (lead < 0x80U) return {lead, 1, true};
    std::size_t length = 0;
    std::uint32_t value = 0;
    std::uint32_t minimum = 0;
    if (lead >= 0xc2U && lead <= 0xdfU) {
        length = 2;
        value = lead & 0x1fU;
        minimum = 0x80U;
    } else if (lead >= 0xe0U && lead <= 0xefU) {
        length = 3;
        value = lead & 0x0fU;
        minimum = 0x800U;
    } else if (lead >= 0xf0U && lead <= 0xf4U) {
        length = 4;
        value = lead & 0x07U;
        minimum = 0x10000U;
    } else {
        return {lead, 1, false};
    }
    if (length > end - index) return {lead, 1, false};
    for (std::size_t offset = 1; offset < length; ++offset) {
        const auto continuation = static_cast<unsigned char>(text[index + offset]);
        if ((continuation & 0xc0U) != 0x80U) return {lead, 1, false};
        value = (value << 6U) | (continuation & 0x3fU);
    }
    if (value < minimum || value > 0x10ffffU
        || (value >= 0xd800U && value <= 0xdfffU)) {
        return {lead, 1, false};
    }
    return {value, length, true};
}

bool unicode_space(std::uint32_t value) noexcept {
    if (value <= 0x7fU) {
        return ascii_space(static_cast<char>(value))
            || (value >= 0x1cU && value <= 0x1fU);
    }
    return value == 0x85U || value == 0xa0U || value == 0x1680U
        || (value >= 0x2000U && value <= 0x200aU) || value == 0x2028U
        || value == 0x2029U || value == 0x202fU || value == 0x205fU
        || value == 0x3000U;
}

std::pair<std::size_t, std::size_t> trim_range(
    const std::string& text, std::size_t start, std::size_t end) {
    while (start < end) {
        const auto decoded = decode_utf8(text, start, end);
        if (!decoded.valid || !unicode_space(decoded.value)) break;
        start += decoded.length;
    }
    while (end > start) {
        auto character_start = end - 1;
        while (character_start > start
            && (static_cast<unsigned char>(text[character_start]) & 0xc0U) == 0x80U) {
            --character_start;
        }
        const auto decoded = decode_utf8(text, character_start, end);
        if (!decoded.valid || character_start + decoded.length != end
            || !unicode_space(decoded.value)) {
            break;
        }
        end = character_start;
    }
    return {start, end};
}

std::string trim_copy(const std::string& text) {
    const auto range = trim_range(text, 0, text.size());
    return text.substr(range.first, range.second - range.first);
}

std::size_t utf8_length(unsigned char lead) {
    if ((lead & 0x80U) == 0) return 1;
    if ((lead & 0xe0U) == 0xc0U) return 2;
    if ((lead & 0xf0U) == 0xe0U) return 3;
    if ((lead & 0xf8U) == 0xf0U) return 4;
    return 1;
}

bool starts_at(const std::string& text, std::size_t index, const std::string& value) {
    return index <= text.size() && text.compare(index, value.size(), value) == 0;
}

std::size_t skip_comment(const std::string& text, std::size_t start) {
    std::size_t depth = 1;
    std::size_t index = start + 2;
    while (index < text.size()) {
        if (starts_at(text, index, "(*")) {
            ++depth;
            index += 2;
        } else if (starts_at(text, index, "*)")) {
            --depth;
            index += 2;
            if (depth == 0) return index;
        } else {
            index += utf8_length(static_cast<unsigned char>(text[index]));
        }
    }
    throw NotebookError(
        NotebookErrorCode::Syntax, "Unterminated Wolfram comment.");
}

std::size_t skip_string(const std::string& text, std::size_t start) {
    std::size_t index = start + 1;
    while (index < text.size()) {
        if (text[index] == '\\') {
            ++index;
            if (index < text.size()) {
                index += utf8_length(static_cast<unsigned char>(text[index]));
            }
        } else if (text[index] == '"') {
            return index + 1;
        } else {
            index += utf8_length(static_cast<unsigned char>(text[index]));
        }
    }
    throw NotebookError(NotebookErrorCode::Syntax, "Unterminated Wolfram string.");
}

std::size_t skip_ws_comments(
    const std::string& text, std::size_t index, std::size_t end) {
    while (index < end) {
        const auto decoded = decode_utf8(text, index, end);
        if (decoded.valid && unicode_space(decoded.value)) {
            index += decoded.length;
        } else if (index + 1 < end && starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
        } else {
            break;
        }
    }
    return index;
}

std::vector<std::string> split_top_level_range(
    const std::string& text, std::size_t start, std::size_t end) {
    std::vector<std::string> parts;
    std::size_t part_start = start;
    std::size_t depth = 0;
    std::size_t index = start;
    while (index < end) {
        if (index + 1 < end && starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        const char character = text[index];
        if (character == '"') {
            index = skip_string(text, index);
            continue;
        }
        if (character == '[' || character == '{' || character == '(') {
            ++depth;
        } else if (character == ']' || character == '}' || character == ')') {
            if (depth != 0) --depth;
        } else if (character == ',' && depth == 0) {
            const auto range = trim_range(text, part_start, index);
            parts.push_back(text.substr(range.first, range.second - range.first));
            part_start = index + 1;
        }
        index += utf8_length(static_cast<unsigned char>(character));
    }
    const auto tail = trim_range(text, part_start, end);
    if (tail.first < tail.second) {
        parts.push_back(text.substr(tail.first, tail.second - tail.first));
    }
    return parts;
}

std::pair<std::size_t, std::vector<std::string>> split_call_arguments(
    const std::string& text, std::size_t open) {
    std::vector<std::string> parts;
    std::size_t start = open + 1;
    std::size_t index = start;
    std::size_t square_depth = 1;
    std::size_t nested_depth = 0;
    while (index < text.size()) {
        if (starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        const char character = text[index];
        if (character == '"') {
            index = skip_string(text, index);
            continue;
        }
        if (character == '[') {
            ++square_depth;
            ++nested_depth;
        } else if (character == ']') {
            --square_depth;
            if (square_depth == 0) {
                const auto tail = trim_range(text, start, index);
                if (tail.first < tail.second) {
                    parts.push_back(text.substr(tail.first, tail.second - tail.first));
                }
                return {index, std::move(parts)};
            }
            if (nested_depth != 0) --nested_depth;
        } else if (character == '{' || character == '(') {
            ++nested_depth;
        } else if (character == '}' || character == ')') {
            if (nested_depth != 0) --nested_depth;
        } else if (character == ',' && nested_depth == 0) {
            const auto range = trim_range(text, start, index);
            parts.push_back(text.substr(range.first, range.second - range.first));
            start = index + 1;
        }
        index += utf8_length(static_cast<unsigned char>(character));
    }
    throw NotebookError(
        NotebookErrorCode::Syntax, "Unmatched '[' in Wolfram expression.");
}

SourceSpan trim_span(const std::shared_ptr<const std::string>& source,
    std::size_t start, std::size_t end) {
    const auto range = trim_range(*source, start, end);
    return SourceSpan(source, range.first, range.second);
}

SourceSpan as_span(const SourceText& expression) {
    if (const auto* span = expression.span()) return span->strip();
    auto source = std::make_shared<const std::string>(expression.text());
    return trim_span(source, 0, source->size());
}

std::vector<SourceSpan> split_top_level_spans(const SourceSpan& input_span) {
    const auto span = input_span.strip();
    const auto& source = span.shared_source();
    const auto& text = *source;
    std::vector<SourceSpan> parts;
    std::size_t part_start = span.start();
    std::size_t depth = 0;
    std::size_t index = span.start();
    while (index < span.end()) {
        if (index + 1 < span.end() && starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        const char character = text[index];
        if (character == '"') {
            index = skip_string(text, index);
            continue;
        }
        if (character == '[' || character == '{' || character == '(') {
            ++depth;
        } else if (character == ']' || character == '}' || character == ')') {
            if (depth != 0) --depth;
        } else if (character == ',' && depth == 0) {
            parts.push_back(trim_span(source, part_start, index));
            part_start = index + 1;
        }
        index += utf8_length(static_cast<unsigned char>(character));
    }
    const auto tail = trim_span(source, part_start, span.end());
    if (tail) parts.push_back(tail);
    return parts;
}

std::pair<std::size_t, std::vector<SourceSpan>> split_call_argument_spans(
    const std::shared_ptr<const std::string>& source, std::size_t open,
    std::size_t end) {
    const auto& text = *source;
    std::vector<SourceSpan> parts;
    std::size_t start = open + 1;
    std::size_t index = start;
    std::size_t square_depth = 1;
    std::size_t nested_depth = 0;
    while (index < end) {
        if (index + 1 < end && starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        const char character = text[index];
        if (character == '"') {
            index = skip_string(text, index);
            continue;
        }
        if (character == '[') {
            ++square_depth;
            ++nested_depth;
        } else if (character == ']') {
            --square_depth;
            if (square_depth == 0) {
                const auto tail = trim_span(source, start, index);
                if (tail) parts.push_back(tail);
                return {index, std::move(parts)};
            }
            if (nested_depth != 0) --nested_depth;
        } else if (character == '{' || character == '(') {
            ++nested_depth;
        } else if (character == '}' || character == ')') {
            if (nested_depth != 0) --nested_depth;
        } else if (character == ',' && nested_depth == 0) {
            parts.push_back(trim_span(source, start, index));
            start = index + 1;
        }
        index += utf8_length(static_cast<unsigned char>(character));
    }
    throw NotebookError(
        NotebookErrorCode::Syntax, "Unmatched '[' in Wolfram expression.");
}

std::pair<std::string, std::vector<SourceSpan>> parse_call_span(
    const SourceText& source_text) {
    const auto span = as_span(source_text);
    const auto& source = span.shared_source();
    const auto& text = *source;
    auto index = skip_ws_comments(text, span.start(), span.end());
    while (index < span.end()) {
        if (index + 1 < span.end() && starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        if (text[index] == '"') {
            index = skip_string(text, index);
            continue;
        }
        if (text[index] == '[') {
            const auto head_range = trim_range(text, span.start(), index);
            const auto head = text.substr(
                head_range.first, head_range.second - head_range.first);
            auto arguments = split_call_argument_spans(source, index, span.end());
            const auto tail = skip_ws_comments(text, arguments.first + 1, span.end());
            if (tail != span.end()) return {span.text(), {}};
            return {head, std::move(arguments.second)};
        }
        index += utf8_length(static_cast<unsigned char>(text[index]));
    }
    return {span.text(), {}};
}

std::vector<SourceSpan> parse_list_span(const SourceText& source_text) {
    const auto span = as_span(source_text);
    if (span.size() < 2) return {};
    const auto& text = span.source();
    if (text[span.start()] != '{' || text[span.end() - 1] != '}') return {};
    return split_top_level_spans(SourceSpan(
        span.shared_source(), span.start() + 1, span.end() - 1));
}

bool has_call_head(const SourceText& expression, const std::string& expected) {
    const auto span = as_span(expression);
    const auto& text = span.source();
    auto index = skip_ws_comments(text, span.start(), span.end());
    if (index > span.end() || expected.size() > span.end() - index
        || text.compare(index, expected.size(), expected) != 0) {
        return false;
    }
    index = skip_ws_comments(text, index + expected.size(), span.end());
    return index < span.end() && text[index] == '[';
}

NotebookItem parse_item_span(const SourceSpan& expression) {
    const SourceText source_expression(expression);
    auto parsed = parse_call_span(source_expression);
    if (parsed.first != "Cell") return NotebookRawItem(expression);

    auto& arguments = parsed.second;
    if (!arguments.empty()
        && has_call_head(SourceText(arguments.front()), "CellGroupData")) {
        auto group = parse_call_span(SourceText(arguments.front()));
        if (group.first == "CellGroupData" && !group.second.empty()) {
            NotebookGroup parsed_group;
            for (const auto& child : parse_list_span(SourceText(group.second.front()))) {
                parsed_group.children.push_back(parse_item_span(child));
            }
            for (auto iterator = std::next(group.second.begin());
                 iterator != group.second.end(); ++iterator) {
                parsed_group.group_tail.emplace_back(*iterator);
            }
            for (auto iterator = std::next(arguments.begin());
                 iterator != arguments.end(); ++iterator) {
                parsed_group.wrapper_options.emplace_back(*iterator);
            }
            parsed_group.raw = source_expression;
            return parsed_group;
        }
    }

    NotebookCell parsed_cell;
    parsed_cell.content_expr = arguments.empty()
        ? SourceText(wl_string("")) : SourceText(arguments.front());
    if (arguments.size() > 1) {
        auto remaining = std::next(arguments.begin());
        if (remaining->view().find("->") == std::string_view::npos) {
            parsed_cell.style = parse_wl_string_literal(remaining->text());
            ++remaining;
        }
        for (; remaining != arguments.end(); ++remaining) {
            parsed_cell.options.emplace_back(*remaining);
        }
    }
    parsed_cell.raw = source_expression;
    return parsed_cell;
}

std::vector<std::string> string_list_value(const std::optional<std::string>& expression) {
    if (!expression) return {};
    const auto text = trim_copy(*expression);
    if (text.empty()) return {};
    if (text.size() >= 2 && text.front() == '"' && text.back() == '"') {
        return {parse_wl_string_literal(text)};
    }
    std::vector<std::string> result;
    for (const auto& item_value : parse_list(text)) {
        const auto item = trim_copy(item_value);
        if (item.size() >= 2 && item.front() == '"' && item.back() == '"') {
            result.push_back(parse_wl_string_literal(item));
        }
    }
    return result;
}

std::vector<std::string> source_text_list(const std::vector<SourceText>& values) {
    std::vector<std::string> result;
    result.reserve(values.size());
    for (const auto& value : values) result.push_back(value.str());
    return result;
}

std::string format_path(const std::vector<std::size_t>& path) {
    std::string result = "[";
    for (std::size_t index = 0; index < path.size(); ++index) {
        if (index != 0) result += ", ";
        result += std::to_string(path[index]);
    }
    return result + ']';
}

void walk_items_mutable(std::vector<NotebookItem>& items,
    const std::vector<std::size_t>& prefix, std::size_t depth,
    std::vector<NotebookWalkItem>& walked) {
    for (std::size_t index = 0; index < items.size(); ++index) {
        auto path = prefix;
        path.push_back(index);
        auto& item = items[index];
        walked.push_back({path, &item, depth});
        if (auto* group = item.as_group()) {
            walk_items_mutable(group->children, path, depth + 1, walked);
        }
    }
}

void walk_items_const(const std::vector<NotebookItem>& items,
    const std::vector<std::size_t>& prefix, std::size_t depth,
    std::vector<ConstNotebookWalkItem>& walked) {
    for (std::size_t index = 0; index < items.size(); ++index) {
        auto path = prefix;
        path.push_back(index);
        const auto& item = items[index];
        walked.push_back({path, &item, depth});
        if (const auto* group = item.as_group()) {
            walk_items_const(group->children, path, depth + 1, walked);
        }
    }
}

void flatten_items(const std::vector<NotebookItem>& items,
    const std::vector<std::size_t>& prefix, std::size_t depth,
    std::vector<NotebookRow>& rows) {
    for (std::size_t item_index = 0; item_index < items.size(); ++item_index) {
        auto path = prefix;
        path.push_back(item_index);
        const auto& item = items[item_index];
        if (const auto* cell = item.as_cell()) {
            rows.push_back({rows.size(), NotebookItemKind::Cell, std::move(path), depth,
                cell->style, cell->plain_text(), cell->cell_id(), cell->expression_uuid(),
                cell->cell_tags(), source_text_list(cell->options)});
        } else if (const auto* group = item.as_group()) {
            flatten_items(group->children, path, depth + 1, rows);
        } else if (const auto* raw = item.as_raw()) {
            rows.push_back({rows.size(), NotebookItemKind::Raw, std::move(path), depth,
                std::nullopt, collapse_text(raw->expression), std::nullopt, std::nullopt,
                {}, {}});
        }
    }
}

void extract_box_expressions_into(
    const std::string& source, std::vector<std::string>& collected) {
    const auto expression = trim_copy(source);
    if (expression.empty()) return;
    if (expression.size() >= 2 && expression.front() == '"' && expression.back() == '"') {
        for (const auto& segment : inline_box_segments(parse_wl_string_literal(expression))) {
            collected.push_back(segment.box_expression);
        }
        return;
    }
    const auto parsed = parse_call(expression);
    const auto& head = parsed.first;
    const auto& arguments = parsed.second;
    if (head == "BoxData" && !arguments.empty()) {
        collected.push_back(trim_copy(arguments.front()));
        return;
    }
    if (head.size() >= 3 && head.compare(head.size() - 3, 3, "Box") == 0
        && head != "BoxData") {
        collected.push_back(expression);
        return;
    }
    if ((head == "TextData" || head == "Row" || head == "List")
        && !arguments.empty()) {
        for (const auto& argument : arguments) {
            const auto trimmed = trim_copy(argument);
            if (trimmed.size() >= 2 && trimmed.front() == '{' && trimmed.back() == '}') {
                for (const auto& item : parse_list(trimmed)) {
                    extract_box_expressions_into(item, collected);
                }
            } else {
                extract_box_expressions_into(trimmed, collected);
            }
        }
        return;
    }
    if (head == "Cell" && !arguments.empty()) {
        extract_box_expressions_into(arguments.front(), collected);
        return;
    }
    if (expression.size() >= 2 && expression.front() == '{' && expression.back() == '}') {
        for (const auto& item : parse_list(expression)) {
            extract_box_expressions_into(item, collected);
        }
    }
}

std::optional<std::vector<std::size_t>> optional_path(
    const JsonValue* value, const std::string& name) {
    if (value == nullptr || value->is_null()) return std::nullopt;
    if (!value->is_array()) {
        throw NotebookError("Patch operation " + name
            + " values must be arrays of integers.");
    }
    const auto& array = value->as_array();
    std::vector<std::size_t> path;
    path.reserve(array.size());
    for (const auto& item : array) {
        const auto integer = item.as_uint64();
        if (!integer || *integer > std::numeric_limits<std::size_t>::max()) {
            throw NotebookError("Patch paths must contain non-negative integers.");
        }
        path.push_back(static_cast<std::size_t>(*integer));
    }
    return path;
}

const std::string* optional_string(const JsonValue::Object& object, const std::string& key) {
    const auto found = object.find(key);
    return found == object.end() || !found->second.is_string()
        ? nullptr : &found->second.as_string();
}

std::optional<std::string> copied_string(
    const JsonValue::Object& object, const std::string& key) {
    const auto* value = optional_string(object, key);
    return value == nullptr ? std::nullopt : std::optional<std::string>(*value);
}

std::string utf8_lossy(const std::string& bytes) {
    std::string result;
    result.reserve(bytes.size());
    for (std::size_t index = 0; index < bytes.size();) {
        const auto decoded = decode_utf8(bytes, index, bytes.size());
        if (decoded.valid) {
            result.append(bytes, index, decoded.length);
            index += decoded.length;
        } else {
            result += u8"\ufffd";
            const auto lead = static_cast<unsigned char>(bytes[index]);
            std::size_t expected = 0;
            if (lead >= 0xc2U && lead <= 0xdfU) expected = 2;
            else if (lead >= 0xe0U && lead <= 0xefU) expected = 3;
            else if (lead >= 0xf0U && lead <= 0xf4U) expected = 4;
            if (expected == 0) {
                ++index;
                continue;
            }
            std::size_t consumed = 1;
            while (consumed < expected && index + consumed < bytes.size()) {
                const auto continuation =
                    static_cast<unsigned char>(bytes[index + consumed]);
                if ((continuation & 0xc0U) != 0x80U) break;
                if (consumed == 1
                    && ((lead == 0xe0U && continuation < 0xa0U)
                        || (lead == 0xedU && continuation > 0x9fU)
                        || (lead == 0xf0U && continuation < 0x90U)
                        || (lead == 0xf4U && continuation > 0x8fU))) {
                    break;
                }
                ++consumed;
            }
            // A range-invalid first continuation leaves that continuation for
            // the next replacement, matching Python's errors="replace".
            index += consumed;
        }
    }
    return result;
}

bool valid_utf8(const std::string& bytes) noexcept {
    for (std::size_t index = 0; index < bytes.size();) {
        const auto decoded = decode_utf8(bytes, index, bytes.size());
        if (!decoded.valid) return false;
        index += decoded.length;
    }
    return true;
}

} // namespace

NotebookError::NotebookError(std::string message)
    : NotebookError(NotebookErrorCode::InvalidOperation, std::move(message)) {}

NotebookError::NotebookError(NotebookErrorCode code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

NotebookErrorCode NotebookError::code() const noexcept { return code_; }

SourceSpan::SourceSpan()
    : source_(std::make_shared<const std::string>()) {}

SourceSpan::SourceSpan(std::shared_ptr<const std::string> source,
    std::size_t start, std::size_t end)
    : source_(source ? std::move(source) : std::make_shared<const std::string>()),
      start_(start), end_(end) {
    if (start_ > end_ || end_ > source_->size()) {
        throw NotebookError(NotebookErrorCode::InvalidOperation,
            "Source span range is out of bounds.");
    }
}

SourceSpan::SourceSpan(std::string source, std::size_t start, std::size_t end)
    : SourceSpan(std::make_shared<const std::string>(std::move(source)), start, end) {}

SourceSpan::SourceSpan(SourceSpan&& other) noexcept
    : source_(other.source_), start_(other.start_), end_(other.end_) {}

SourceSpan& SourceSpan::operator=(SourceSpan&& other) noexcept {
    if (this != &other) {
        source_ = other.source_;
        start_ = other.start_;
        end_ = other.end_;
    }
    return *this;
}

const std::string& SourceSpan::source() const noexcept { return *source_; }

const std::shared_ptr<const std::string>& SourceSpan::shared_source() const noexcept {
    return source_;
}

std::size_t SourceSpan::start() const noexcept { return start_; }
std::size_t SourceSpan::end() const noexcept { return end_; }
std::size_t SourceSpan::size() const noexcept { return end_ - start_; }
bool SourceSpan::empty() const noexcept { return start_ == end_; }

std::string_view SourceSpan::view() const noexcept {
    return std::string_view(source_->data() + start_, size());
}

std::string SourceSpan::text() const { return std::string(view()); }

SourceSpan SourceSpan::strip() const {
    const auto range = trim_range(*source_, start_, end_);
    return SourceSpan(source_, range.first, range.second);
}

bool SourceSpan::starts_with(std::string_view prefix) const noexcept {
    const auto value = view();
    return prefix.size() <= value.size() && value.substr(0, prefix.size()) == prefix;
}

bool SourceSpan::ends_with(std::string_view suffix) const noexcept {
    const auto value = view();
    return suffix.size() <= value.size()
        && value.substr(value.size() - suffix.size()) == suffix;
}

SourceSpan::operator bool() const noexcept { return !empty(); }
SourceSpan::operator std::string() const { return text(); }

bool operator==(const SourceSpan& left, const SourceSpan& right) noexcept {
    return left.start_ == right.start_ && left.end_ == right.end_
        && left.source() == right.source();
}

SourceText::SourceText() : value_(std::string{}) {}
SourceText::SourceText(const char* text) : value_(std::string(text == nullptr ? "" : text)) {}
SourceText::SourceText(std::string text) : value_(std::move(text)) {}
SourceText::SourceText(SourceSpan span) : value_(std::move(span)) {}

SourceText& SourceText::operator=(const char* text) {
    value_ = std::string(text == nullptr ? "" : text);
    materialized_.reset();
    return *this;
}

SourceText& SourceText::operator=(std::string text) {
    value_ = std::move(text);
    materialized_.reset();
    return *this;
}

SourceText& SourceText::operator=(SourceSpan span) {
    value_ = std::move(span);
    materialized_.reset();
    return *this;
}

bool SourceText::is_span() const noexcept {
    return std::holds_alternative<SourceSpan>(value_);
}

bool SourceText::is_materialized() const noexcept {
    return std::holds_alternative<std::string>(value_) || materialized_.has_value();
}

const SourceSpan* SourceText::span() const noexcept {
    return std::get_if<SourceSpan>(&value_);
}

std::string_view SourceText::view() const noexcept {
    if (const auto* owned = std::get_if<std::string>(&value_)) return *owned;
    return std::get<SourceSpan>(value_).view();
}

const std::string& SourceText::text() const {
    if (const auto* owned = std::get_if<std::string>(&value_)) return *owned;
    if (!materialized_) materialized_.emplace(std::get<SourceSpan>(value_).text());
    return *materialized_;
}

std::string SourceText::str() const { return std::string(view()); }
bool SourceText::empty() const noexcept { return view().empty(); }
std::size_t SourceText::size() const noexcept { return view().size(); }

bool SourceText::starts_with(std::string_view prefix) const noexcept {
    const auto value = view();
    return prefix.size() <= value.size() && value.substr(0, prefix.size()) == prefix;
}

bool SourceText::ends_with(std::string_view suffix) const noexcept {
    const auto value = view();
    return suffix.size() <= value.size()
        && value.substr(value.size() - suffix.size()) == suffix;
}

std::size_t SourceText::find(std::string_view value, std::size_t position) const noexcept {
    return view().find(value, position);
}

std::string SourceText::substr(std::size_t position, std::size_t count) const {
    return std::string(view().substr(position, count));
}

char SourceText::front() const { return view().front(); }
char SourceText::back() const { return view().back(); }
char SourceText::operator[](std::size_t index) const noexcept { return view()[index]; }

void SourceText::append_to(std::string& destination) const {
    const auto value = view();
    destination.append(value.data(), value.size());
}

SourceText::operator std::string() const { return str(); }

bool operator==(const SourceText& left, const SourceText& right) noexcept {
    return left.view() == right.view();
}

bool operator==(const SourceText& left, std::string_view right) noexcept {
    return left.view() == right;
}

bool operator==(std::string_view left, const SourceText& right) noexcept {
    return left == right.view();
}

JsonValue parse_json(const std::string& text) {
    try {
        return JsonValue::parse(text);
    } catch (const JsonError& error) {
        throw NotebookError(NotebookErrorCode::Json, error.what());
    }
}

JsonValue load_patch_spec(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw NotebookError(NotebookErrorCode::Io,
            "Could not open JSON patch file: " + path.u8string());
    }
    std::ostringstream contents;
    contents << input.rdbuf();
    if (input.bad()) {
        throw NotebookError(NotebookErrorCode::Io,
            "Could not read JSON patch file: " + path.u8string());
    }
    const auto text = contents.str();
    if (!valid_utf8(text)) {
        throw NotebookError(
            NotebookErrorCode::Io,
            "JSON patch file is not valid UTF-8: " + path.u8string());
    }
    return parse_json(text);
}

NotebookCell::NotebookCell(std::string content,
    std::optional<std::string> cell_style,
    std::vector<std::string> cell_options,
    std::optional<std::string> raw_source)
    : content_expr(std::move(content)), style(std::move(cell_style)) {
    options.reserve(cell_options.size());
    for (auto& option : cell_options) options.emplace_back(std::move(option));
    if (raw_source) raw.emplace(std::move(*raw_source));
}

std::string NotebookCell::plain_text() const {
    std::string fragments;
    for (const auto& literal : extract_string_literals(content_expr)) {
        if (!fragments.empty()) fragments += ' ';
        fragments += display_text(literal, "[InlineBox]");
    }
    return collapse_text(fragments);
}

std::optional<std::int64_t> NotebookCell::cell_id() const {
    const auto expression = rule_value(options, "CellID");
    if (!expression) return std::nullopt;
    try {
        std::size_t consumed = 0;
        const auto value = std::stoll(trim_copy(*expression), &consumed);
        if (consumed != trim_copy(*expression).size()) return std::nullopt;
        return static_cast<std::int64_t>(value);
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

std::optional<std::string> NotebookCell::expression_uuid() const {
    const auto value = rule_value(options, "ExpressionUUID");
    if (!value) return std::nullopt;
    return parse_wl_string_literal(*value);
}

std::vector<std::string> NotebookCell::cell_tags() const {
    return string_list_value(rule_value(options, "CellTags"));
}

std::string NotebookCell::render() const {
    if (raw) return raw->str();
    std::string result = "Cell[";
    content_expr.append_to(result);
    if (style) {
        result += ", ";
        result += wl_string(*style);
    }
    for (const auto& option : options) {
        result += ", ";
        option.append_to(result);
    }
    return result + ']';
}

bool operator==(const NotebookCell& left, const NotebookCell& right) {
    return left.content_expr == right.content_expr && left.style == right.style
        && left.options == right.options && left.raw == right.raw;
}

NotebookGroup::NotebookGroup(std::vector<NotebookItem> group_children,
    std::vector<std::string> tail, std::vector<std::string> options,
    std::optional<std::string> raw_source)
    : children(std::move(group_children)) {
    group_tail.reserve(tail.size());
    for (auto& value : tail) group_tail.emplace_back(std::move(value));
    wrapper_options.reserve(options.size());
    for (auto& value : options) wrapper_options.emplace_back(std::move(value));
    if (raw_source) raw.emplace(std::move(*raw_source));
}

std::string NotebookGroup::render() const {
    if (raw) return raw->str();
    std::string children_text;
    for (std::size_t index = 0; index < children.size(); ++index) {
        if (index != 0) children_text += ",\n";
        children_text += children[index].render();
    }
    std::string group_data = "CellGroupData[{\n" + children_text + "\n}";
    for (const auto& tail : group_tail) {
        group_data += ", ";
        tail.append_to(group_data);
    }
    group_data += ']';
    std::string result = "Cell[" + group_data;
    for (const auto& option : wrapper_options) {
        result += ", ";
        option.append_to(result);
    }
    return result + ']';
}

bool operator==(const NotebookGroup& left, const NotebookGroup& right) {
    return left.children == right.children && left.group_tail == right.group_tail
        && left.wrapper_options == right.wrapper_options && left.raw == right.raw;
}

bool operator==(const NotebookRawItem& left, const NotebookRawItem& right) {
    return left.expression == right.expression;
}

NotebookItemKind NotebookItem::kind() const noexcept {
    if (std::holds_alternative<NotebookCell>(value)) return NotebookItemKind::Cell;
    if (std::holds_alternative<NotebookGroup>(value)) return NotebookItemKind::Group;
    return NotebookItemKind::Raw;
}

const char* NotebookItem::kind_name() const noexcept {
    switch (kind()) {
    case NotebookItemKind::Cell: return "cell";
    case NotebookItemKind::Group: return "group";
    case NotebookItemKind::Raw: return "raw";
    }
    return "raw";
}

NotebookCell* NotebookItem::as_cell() noexcept { return std::get_if<NotebookCell>(&value); }
const NotebookCell* NotebookItem::as_cell() const noexcept {
    return std::get_if<NotebookCell>(&value);
}
NotebookGroup* NotebookItem::as_group() noexcept { return std::get_if<NotebookGroup>(&value); }
const NotebookGroup* NotebookItem::as_group() const noexcept {
    return std::get_if<NotebookGroup>(&value);
}
NotebookRawItem* NotebookItem::as_raw() noexcept { return std::get_if<NotebookRawItem>(&value); }
const NotebookRawItem* NotebookItem::as_raw() const noexcept {
    return std::get_if<NotebookRawItem>(&value);
}

std::string NotebookItem::render() const {
    return std::visit([](const auto& item) { return item.render(); }, value);
}

bool operator==(const NotebookItem& left, const NotebookItem& right) {
    return left.value == right.value;
}

bool operator==(const NotebookSummary& left, const NotebookSummary& right) {
    return left.title == right.title && left.cell_count == right.cell_count
        && left.group_count == right.group_count && left.option_count == right.option_count;
}

const char* NotebookRow::kind_name() const noexcept {
    switch (kind) {
    case NotebookItemKind::Cell: return "cell";
    case NotebookItemKind::Group: return "group";
    case NotebookItemKind::Raw: return "raw";
    }
    return "raw";
}

JsonValue NotebookRow::to_json_value() const {
    JsonValue::Array json_path;
    for (const auto element : path)
        json_path.emplace_back(static_cast<unsigned long long>(element));
    JsonValue::Object object{
        {"index", static_cast<unsigned long long>(index)},
        {"kind", kind_name()},
        {"path", std::move(json_path)},
        {"depth", static_cast<unsigned long long>(depth)},
        {"preview", preview},
    };
    if (kind == NotebookItemKind::Cell) {
        object["style"] = style ? JsonValue(*style) : JsonValue(nullptr);
        object["cell_id"] = cell_id ? JsonValue(*cell_id) : JsonValue(nullptr);
        object["expression_uuid"] = expression_uuid
            ? JsonValue(*expression_uuid) : JsonValue(nullptr);
        JsonValue::Array tags;
        for (const auto& tag : cell_tags) tags.emplace_back(tag);
        object["cell_tags"] = std::move(tags);
        JsonValue::Array json_options;
        for (const auto& option : options) json_options.emplace_back(option);
        object["options"] = std::move(json_options);
    }
    return object;
}

bool operator==(const NotebookRow& left, const NotebookRow& right) {
    return left.index == right.index && left.kind == right.kind && left.path == right.path
        && left.depth == right.depth && left.style == right.style
        && left.preview == right.preview && left.cell_id == right.cell_id
        && left.expression_uuid == right.expression_uuid && left.cell_tags == right.cell_tags
        && left.options == right.options;
}

NotebookDocument::NotebookDocument(std::vector<NotebookItem> document_items,
    std::vector<std::string> document_options, std::string document_preamble,
    std::optional<std::filesystem::path> document_path)
    : items(std::move(document_items)), preamble(std::move(document_preamble)),
      path(std::move(document_path)) {
    options.reserve(document_options.size());
    for (auto& option : document_options) options.emplace_back(std::move(option));
}

NotebookDocument NotebookDocument::from_text(
    const std::string& text, std::optional<std::filesystem::path> source_path) {
    const auto notebook_start = text.find("Notebook[");
    if (notebook_start == std::string::npos) {
        throw NotebookError(NotebookErrorCode::NotebookExpressionNotFound,
            "Notebook expression not found.");
    }
    auto source = std::make_shared<const std::string>(text);
    const auto preamble = source->substr(0, notebook_start);
    const auto expression = trim_span(source, notebook_start, source->size());
    auto parsed = parse_call_span(SourceText(expression));
    if (parsed.first != "Notebook") {
        throw NotebookError(
            NotebookErrorCode::NotNotebook, "Top-level expression is not a Notebook.");
    }
    std::vector<NotebookItem> items;
    if (!parsed.second.empty()) {
        for (const auto& item : parse_list_span(SourceText(parsed.second.front()))) {
            items.push_back(parse_item_span(item));
        }
    }
    NotebookDocument document;
    document.items = std::move(items);
    if (parsed.second.size() > 1) {
        for (auto iterator = std::next(parsed.second.begin());
             iterator != parsed.second.end(); ++iterator) {
            document.options.emplace_back(*iterator);
        }
    }
    document.preamble = preamble;
    document.path = std::move(source_path);
    return document;
}

NotebookDocument NotebookDocument::load(const std::filesystem::path& source_path) {
    std::ifstream input(source_path, std::ios::binary);
    if (!input) {
        throw NotebookError(NotebookErrorCode::Io,
            "Could not open notebook: " + source_path.u8string());
    }
    std::ostringstream contents;
    contents << input.rdbuf();
    if (input.bad()) {
        throw NotebookError(NotebookErrorCode::Io,
            "Could not read notebook: " + source_path.u8string());
    }
    return from_text(utf8_lossy(contents.str()), source_path);
}

std::optional<std::string> NotebookDocument::title() const {
    if (const auto value = rule_value(options, "WindowTitle")) {
        return parse_wl_string_literal(*value);
    }
    if (path) return path->stem().u8string();
    return std::nullopt;
}

NotebookSummary NotebookDocument::summary() const {
    NotebookSummary result;
    result.title = title();
    result.option_count = options.size();
    for (const auto& walked : walk_items()) {
        if (walked.item->as_group() != nullptr) {
            ++result.group_count;
        } else {
            ++result.cell_count;
        }
    }
    return result;
}

std::vector<NotebookWalkItem> NotebookDocument::walk_items(
    std::vector<NotebookItem>* selected_items,
    const std::vector<std::size_t>& prefix, std::size_t depth) {
    std::vector<NotebookWalkItem> walked;
    walk_items_mutable(selected_items == nullptr ? items : *selected_items,
        prefix, depth, walked);
    return walked;
}

std::vector<ConstNotebookWalkItem> NotebookDocument::walk_items(
    const std::vector<NotebookItem>* selected_items,
    const std::vector<std::size_t>& prefix, std::size_t depth) const {
    std::vector<ConstNotebookWalkItem> walked;
    walk_items_const(selected_items == nullptr ? items : *selected_items,
        prefix, depth, walked);
    return walked;
}

std::vector<NotebookRow> NotebookDocument::flattened_cells() const {
    std::vector<NotebookRow> rows;
    flatten_items(items, {}, 0, rows);
    return rows;
}

JsonValue NotebookDocument::to_json_value() const {
    const auto rows = flattened_cells();
    JsonValue::Array json_options;
    for (const auto& option : options) json_options.emplace_back(option.str());
    JsonValue::Array cells;
    for (const auto& row : rows) cells.push_back(row.to_json_value());
    const auto notebook_summary = summary();
    return JsonValue::Object{
        {"path", path ? JsonValue(path->u8string()) : JsonValue(nullptr)},
        {"title", notebook_summary.title ? JsonValue(*notebook_summary.title) : JsonValue(nullptr)},
        {"cell_count", static_cast<unsigned long long>(rows.size())},
        {"group_count", static_cast<unsigned long long>(notebook_summary.group_count)},
        {"options", std::move(json_options)},
        {"cells", std::move(cells)},
    };
}

std::string NotebookDocument::to_json() const { return to_json_value().dump(); }

NotebookRow NotebookDocument::cell_at_flat_index(std::size_t index) const {
    const auto rows = flattened_cells();
    if (index >= rows.size()) {
        throw NotebookError("Cell index " + std::to_string(index)
            + " is out of range for notebook with " + std::to_string(rows.size()) + " cells.");
    }
    return rows[index];
}

NotebookRow NotebookDocument::cell_at_path(const std::vector<std::size_t>& target) const {
    for (const auto& row : flattened_cells()) {
        if (row.path == target) return row;
    }
    throw NotebookError("Notebook cell path " + format_path(target) + " was not found.");
}

const NotebookItem& NotebookDocument::item_at_flat_index(std::size_t index) const {
    return item_at_path(cell_at_flat_index(index).path);
}

NotebookItem& NotebookDocument::item_at_flat_index(std::size_t index) {
    const auto row = static_cast<const NotebookDocument&>(*this).cell_at_flat_index(index);
    return item_at_path(row.path);
}

const NotebookItem& NotebookDocument::item_at_path(
    const std::vector<std::size_t>& item_path) const {
    if (item_path.empty()) throw NotebookError("Notebook item lookup requires a non-empty path.");
    const std::vector<NotebookItem>* container = &items;
    const NotebookItem* item = nullptr;
    for (std::size_t depth = 0; depth < item_path.size(); ++depth) {
        const auto index = item_path[depth];
        if (index >= container->size()) {
            throw NotebookError(
                "Notebook item path " + format_path(item_path) + " was not found.");
        }
        item = &(*container)[index];
        if (depth + 1 < item_path.size()) {
            const auto* group = item->as_group();
            if (group == nullptr) {
                throw NotebookError("Notebook item path " + format_path(item_path)
                    + " does not resolve through a group.");
            }
            container = &group->children;
        }
    }
    return *item;
}

NotebookItem& NotebookDocument::item_at_path(const std::vector<std::size_t>& item_path) {
    if (item_path.empty()) throw NotebookError("Notebook item lookup requires a non-empty path.");
    std::vector<NotebookItem>* container = &items;
    NotebookItem* item = nullptr;
    for (std::size_t depth = 0; depth < item_path.size(); ++depth) {
        const auto index = item_path[depth];
        if (index >= container->size()) {
            throw NotebookError(
                "Notebook item path " + format_path(item_path) + " was not found.");
        }
        item = &(*container)[index];
        if (depth + 1 < item_path.size()) {
            auto* group = item->as_group();
            if (group == nullptr) {
                throw NotebookError("Notebook item path " + format_path(item_path)
                    + " does not resolve through a group.");
            }
            container = &group->children;
        }
    }
    return *item;
}

std::string NotebookDocument::render() const {
    std::string rendered_items;
    for (std::size_t index = 0; index < items.size(); ++index) {
        if (index != 0) rendered_items += ",\n";
        rendered_items += items[index].render();
    }
    std::string result = preamble + "Notebook[{\n" + rendered_items + "\n}";
    for (const auto& option : options) {
        result += ", ";
        option.append_to(result);
    }
    return result + "]\n";
}

std::filesystem::path NotebookDocument::save(
    std::optional<std::filesystem::path> destination) {
    auto target = destination ? std::move(*destination) : path.value_or(std::filesystem::path{});
    if (target.empty()) {
        throw NotebookError("A destination path is required to save the notebook.");
    }
    std::ofstream output(target, std::ios::binary | std::ios::trunc);
    if (!output) {
        throw NotebookError(NotebookErrorCode::Io,
            "Could not open notebook for writing: " + target.u8string());
    }
    output << render();
    if (!output) {
        throw NotebookError(
            NotebookErrorCode::Io, "Could not write notebook: " + target.u8string());
    }
    path = target;
    return target;
}

std::vector<NotebookItem>& NotebookDocument::resolve_container(
    const std::vector<std::size_t>& group_path) {
    auto* container = &items;
    for (const auto index : group_path) {
        if (index >= container->size()) {
            throw NotebookError(
                "Notebook group path " + format_path(group_path) + " was not found.");
        }
        auto* group = (*container)[index].as_group();
        if (group == nullptr) {
            throw NotebookError("Path " + format_path(group_path)
                + " does not identify a notebook group.");
        }
        container = &group->children;
    }
    return *container;
}

const std::vector<NotebookItem>& NotebookDocument::resolve_container(
    const std::vector<std::size_t>& group_path) const {
    const auto* container = &items;
    for (const auto index : group_path) {
        if (index >= container->size()) {
            throw NotebookError(
                "Notebook group path " + format_path(group_path) + " was not found.");
        }
        const auto* group = (*container)[index].as_group();
        if (group == nullptr) {
            throw NotebookError("Path " + format_path(group_path)
                + " does not identify a notebook group.");
        }
        container = &group->children;
    }
    return *container;
}

void NotebookDocument::clear_raw_ancestors(
    const std::vector<std::size_t>& group_path) {
    auto* container = &items;
    for (const auto index : group_path) {
        if (index >= container->size()) {
            throw NotebookError(
                "Notebook group path " + format_path(group_path) + " was not found.");
        }
        auto* group = (*container)[index].as_group();
        if (group == nullptr) {
            throw NotebookError("Path " + format_path(group_path)
                + " does not identify a notebook group.");
        }
        group->raw.reset();
        container = &group->children;
    }
}

NotebookCell& NotebookDocument::append_cell(std::optional<std::string> text,
    std::optional<std::string> cell_style, std::optional<std::string> content_expression,
    const std::vector<std::size_t>& container_path) {
    auto& container = resolve_container(container_path);
    const auto content = content_expression
        ? std::move(*content_expression) : wl_string(text.value_or(""));
    container.emplace_back(NotebookCell(std::move(content), std::move(cell_style)));
    clear_raw_ancestors(container_path);
    return *container.back().as_cell();
}

NotebookCell& NotebookDocument::insert_cell(std::size_t index,
    std::optional<std::string> text, std::optional<std::string> cell_style,
    std::optional<std::string> content_expression,
    const std::vector<std::size_t>& container_path) {
    auto& container = resolve_container(container_path);
    if (index > container.size()) {
        throw NotebookError(
            "Cell insertion index " + std::to_string(index) + " is out of range.");
    }
    const auto content = content_expression
        ? std::move(*content_expression) : wl_string(text.value_or(""));
    auto inserted = container.insert(container.begin() + static_cast<std::ptrdiff_t>(index),
        NotebookItem(NotebookCell(std::move(content), std::move(cell_style))));
    clear_raw_ancestors(container_path);
    return *inserted->as_cell();
}

NotebookCell& NotebookDocument::replace_cell(const std::vector<std::size_t>& cell_path,
    std::optional<std::string> text, std::optional<std::string> cell_style,
    std::optional<std::string> content_expression) {
    if (cell_path.empty()) throw NotebookError("Cell replacement requires a non-empty path.");
    const std::vector<std::size_t> parent_path(cell_path.begin(), std::prev(cell_path.end()));
    auto& container = resolve_container(parent_path);
    const auto index = cell_path.back();
    if (index >= container.size()) {
        throw NotebookError(
            "Notebook item path " + format_path(cell_path) + " was not found.");
    }
    if (const auto* existing = container[index].as_cell()) {
        if (!cell_style) cell_style = existing->style;
    } else if (container[index].as_raw() == nullptr) {
        throw NotebookError("replace_cell expects a cell or raw item target.");
    }
    const auto content = content_expression
        ? std::move(*content_expression) : wl_string(text.value_or(""));
    container[index] = NotebookCell(std::move(content), std::move(cell_style));
    clear_raw_ancestors(parent_path);
    return *container[index].as_cell();
}

void NotebookDocument::delete_item(const std::vector<std::size_t>& item_path) {
    if (item_path.empty()) throw NotebookError("Deletion requires a non-empty path.");
    const std::vector<std::size_t> parent_path(item_path.begin(), std::prev(item_path.end()));
    auto& container = resolve_container(parent_path);
    const auto index = item_path.back();
    if (index >= container.size()) {
        throw NotebookError(
            "Notebook item path " + format_path(item_path) + " was not found.");
    }
    container.erase(container.begin() + static_cast<std::ptrdiff_t>(index));
    clear_raw_ancestors(parent_path);
}

void NotebookDocument::set_option(const std::string& name, const std::string& value_expr) {
    const auto replacement = name + "->" + value_expr;
    const auto prefix = name + "->";
    for (auto& option : options) {
        auto compact = option.str();
        compact.erase(std::remove(compact.begin(), compact.end(), ' '), compact.end());
        if (compact.compare(0, prefix.size(), prefix) == 0) {
            option = replacement;
            return;
        }
    }
    options.push_back(replacement);
}

std::vector<std::string> split_top_level(const std::string& text) {
    const auto range = trim_range(text, 0, text.size());
    return split_top_level_range(text, range.first, range.second);
}

std::pair<std::string, std::vector<std::string>> parse_call(
    const std::string& source) {
    const auto expression = trim_copy(source);
    auto index = skip_ws_comments(expression, 0, expression.size());
    while (index < expression.size()) {
        if (starts_at(expression, index, "(*")) {
            index = skip_comment(expression, index);
            continue;
        }
        if (expression[index] == '"') {
            index = skip_string(expression, index);
            continue;
        }
        if (expression[index] == '[') {
            const auto head = trim_copy(expression.substr(0, index));
            auto arguments = split_call_arguments(expression, index);
            const auto tail = skip_ws_comments(
                expression, arguments.first + 1, expression.size());
            if (tail != expression.size()) return {expression, {}};
            return {head, std::move(arguments.second)};
        }
        index += utf8_length(static_cast<unsigned char>(expression[index]));
    }
    return {expression, {}};
}

std::vector<std::string> parse_list(const std::string& source) {
    const auto expression = trim_copy(source);
    if (expression.size() < 2 || expression.front() != '{' || expression.back() != '}') {
        return {};
    }
    return split_top_level_range(expression, 1, expression.size() - 1);
}

std::vector<std::string> extract_string_literals(const std::string& text) {
    std::vector<std::string> literals;
    std::size_t index = 0;
    while (index < text.size()) {
        if (starts_at(text, index, "(*")) {
            index = skip_comment(text, index);
            continue;
        }
        if (text[index] == '"') {
            const auto start = index;
            index = skip_string(text, index);
            literals.push_back(parse_wl_string_literal(text.substr(start, index - start)));
            continue;
        }
        index += utf8_length(static_cast<unsigned char>(text[index]));
    }
    return literals;
}

std::vector<std::string> extract_box_expressions(const std::string& expression) {
    std::vector<std::string> collected;
    extract_box_expressions_into(expression, collected);
    std::vector<std::string> result;
    for (const auto& item : collected) {
        const auto normalized = trim_copy(item);
        if (!normalized.empty()
            && std::find(result.begin(), result.end(), normalized) == result.end()) {
            result.push_back(normalized);
        }
    }
    return result;
}

std::optional<std::string> rule_value(
    const std::vector<std::string>& options, const std::string& name) {
    const auto prefix = name + "->";
    for (const auto& option : options) {
        auto compact = option;
        compact.erase(std::remove(compact.begin(), compact.end(), ' '), compact.end());
        if (compact.compare(0, prefix.size(), prefix) == 0) {
            const auto arrow = option.find("->");
            if (arrow != std::string::npos) return trim_copy(option.substr(arrow + 2));
        }
    }
    return std::nullopt;
}

std::optional<std::string> rule_value(
    const std::vector<SourceText>& options, const std::string& name) {
    const auto prefix = name + "->";
    for (const auto& option : options) {
        const auto option_text = option.str();
        auto compact = option_text;
        compact.erase(std::remove(compact.begin(), compact.end(), ' '), compact.end());
        if (compact.compare(0, prefix.size(), prefix) == 0) {
            const auto arrow = option_text.find("->");
            if (arrow != std::string::npos) {
                return trim_copy(option_text.substr(arrow + 2));
            }
        }
    }
    return std::nullopt;
}

std::string collapse_text(const std::string& text, std::size_t limit) {
    std::string collapsed;
    bool pending_space = false;
    for (std::size_t index = 0; index < text.size();) {
        const auto decoded = decode_utf8(text, index, text.size());
        const auto length = decoded.valid ? decoded.length : std::size_t{1};
        if (decoded.valid && unicode_space(decoded.value)) {
            pending_space = !collapsed.empty();
        } else {
            if (pending_space) collapsed.push_back(' ');
            pending_space = false;
            collapsed.append(text, index, length);
        }
        index += length;
    }
    std::size_t character_count = 0;
    for (std::size_t index = 0; index < collapsed.size();) {
        const auto decoded = decode_utf8(collapsed, index, collapsed.size());
        index += decoded.valid ? decoded.length : std::size_t{1};
        ++character_count;
    }
    if (character_count <= limit) return collapsed;
    if (limit == 0) return {};
    std::size_t byte_end = 0;
    for (std::size_t count = 0; count < limit - 1 && byte_end < collapsed.size(); ++count) {
        const auto decoded = decode_utf8(collapsed, byte_end, collapsed.size());
        byte_end += decoded.valid ? decoded.length : std::size_t{1};
    }
    auto result = collapsed.substr(0, byte_end);
    while (!result.empty() && result.back() == ' ') result.pop_back();
    return result + u8"…";
}

void apply_patch_spec(NotebookDocument& document, const JsonValue& spec) {
    const auto* operations_value = spec.is_object() ? spec.find("operations") : nullptr;
    if (spec.is_object() && operations_value == nullptr) return;
    if (operations_value == nullptr || !operations_value->is_array()) {
        throw NotebookError("Patch specification must contain an operations list.");
    }
    for (const auto& operation_value : operations_value->as_array()) {
        if (!operation_value.is_object()) {
            throw NotebookError("Patch operations must be JSON objects.");
        }
        const auto& operation = operation_value.as_object();
        const auto* op_value = optional_string(operation, "op");
        const auto op = op_value == nullptr ? std::string{} : trim_copy(*op_value);
        const auto path = optional_path(operation_value.find("path"), "path");
        const auto container_path = optional_path(
            operation_value.find("container_path"), "container_path");
        const auto text = copied_string(operation, "text");
        const auto content_expr = copied_string(operation, "content_expr");
        if (op == "append_cell") {
            auto style = copied_string(operation, "style");
            if (!style) style = "Text";
            document.append_cell(text, std::move(style), content_expr,
                container_path.value_or(std::vector<std::size_t>{}));
        } else if (op == "insert_cell") {
            const auto* index_value = operation_value.find("index");
            const auto index = index_value == nullptr
                ? std::optional<std::uint64_t>{} : index_value->as_uint64();
            if (!index || *index > std::numeric_limits<std::size_t>::max()) {
                throw NotebookError("insert_cell requires a non-negative integer index.");
            }
            auto style = copied_string(operation, "style");
            if (!style) style = "Text";
            document.insert_cell(static_cast<std::size_t>(*index), text, std::move(style),
                content_expr, container_path.value_or(std::vector<std::size_t>{}));
        } else if (op == "replace_cell") {
            if (!path) throw NotebookError("replace_cell requires a path.");
            document.replace_cell(*path, text, copied_string(operation, "style"), content_expr);
        } else if (op == "delete_item") {
            if (!path) throw NotebookError("delete_item requires a path.");
            document.delete_item(*path);
        } else if (op == "set_option") {
            const auto* name = optional_string(operation, "name");
            const auto* value_expr = optional_string(operation, "value_expr");
            if (name == nullptr) throw NotebookError("set_option requires a name.");
            if (value_expr == nullptr) throw NotebookError("set_option requires a value_expr.");
            document.set_option(*name, *value_expr);
        } else {
            throw NotebookError("Unsupported patch operation: " + op);
        }
    }
}

} // namespace tungsten
