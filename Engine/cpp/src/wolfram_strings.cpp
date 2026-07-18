#include "tungsten/wolfram_strings.hpp"

#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>

namespace tungsten {
namespace {

const std::string linear_syntax_bang = u8"\uf7c1";
const std::string linear_syntax_open = u8"\uf7c9";
const std::string linear_syntax_close = u8"\uf7c0";
const std::string linear_syntax_star = u8"\uf7c8";

bool starts_with(const std::string& value, std::size_t index, const std::string& prefix) {
    return index <= value.size() && prefix.size() <= value.size() - index
        && value.compare(index, prefix.size(), prefix) == 0;
}

std::size_t utf8_character_length(unsigned char first) {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

std::string encode_utf8(std::uint32_t codepoint) {
    // Python strings can retain isolated UTF-16 surrogate codepoints. Encode
    // those as WTF-8 so the C++ byte-string model can preserve and re-render
    // the same value instead of silently treating the escape as malformed.
    if (codepoint > 0x10ffff) return {};
    std::string output;
    if (codepoint <= 0x7f) output.push_back(static_cast<char>(codepoint));
    else if (codepoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else if (codepoint <= 0xffff) {
        output.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else {
        output.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    }
    return output;
}

bool digit_for_radix(char value, int radix) {
    if (value >= '0' && value <= '9') return value - '0' < radix;
    if (radix == 16 && value >= 'a' && value <= 'f') return true;
    return radix == 16 && value >= 'A' && value <= 'F';
}

struct DecodedEscape {
    std::string text;
    std::size_t end;
};

std::optional<DecodedEscape> decode_character_escape(
    const std::string& text, std::size_t index) {
    if (!starts_with(text, index, "\\") || index + 1 >= text.size()) return std::nullopt;
    if (starts_with(text, index, R"(\[)")) {
        const auto end = text.find(']', index + 2);
        if (end == std::string::npos) return std::nullopt;
        const auto name = text.substr(index + 2, end - index - 2);
        const auto decoded = named_character(name);
        return DecodedEscape{decoded.value_or(text.substr(index, end + 1 - index)), end + 1};
    }

    const auto marker = text[index + 1];
    int radix = 0;
    std::size_t digits = 0;
    std::size_t start = 0;
    if (marker == ':') { radix = 16; digits = 4; start = index + 2; }
    else if (marker == '.') { radix = 16; digits = 2; start = index + 2; }
    else if (marker == '|') { radix = 16; digits = 6; start = index + 2; }
    else if (marker >= '0' && marker <= '7') { radix = 8; digits = 3; start = index + 1; }
    else return std::nullopt;
    if (start + digits > text.size()) return std::nullopt;
    for (std::size_t part = 0; part < digits; ++part) {
        if (!digit_for_radix(text[start + part], radix)) return std::nullopt;
    }
    const auto codepoint = static_cast<std::uint32_t>(
        std::stoul(text.substr(start, digits), nullptr, radix));
    const auto decoded = encode_utf8(codepoint);
    if (decoded.empty()) return std::nullopt;
    return DecodedEscape{decoded, start + digits};
}

std::size_t skip_string_value(const std::string& value, std::size_t start) {
    if (start == std::numeric_limits<std::size_t>::max()) return start;
    std::size_t index = start + 1;
    while (index < value.size()) {
        const auto character_length = utf8_character_length(
            static_cast<unsigned char>(value[index]));
        if (value[index] == '\\') {
            index += 1;
            if (index < value.size()) {
                index += utf8_character_length(static_cast<unsigned char>(value[index]));
            } else {
                // Python's code-point implementation advances by two for a
                // trailing backslash, so its returned cursor is one past the
                // byte/string end in this malformed-input case.
                ++index;
            }
            continue;
        }
        const bool close = value[index] == '"';
        index += character_length;
        if (close) break;
    }
    return index;
}

std::size_t skip_comment_value(const std::string& value, std::size_t start) {
    if (start > std::numeric_limits<std::size_t>::max() - 2) {
        return std::numeric_limits<std::size_t>::max();
    }
    std::size_t index = start + 2;
    std::size_t depth = 1;
    while (index < value.size()) {
        if (starts_with(value, index, "(*")) {
            ++depth;
            index += 2;
        } else if (starts_with(value, index, "*)")) {
            --depth;
            index += 2;
            if (depth == 0) break;
        } else {
            index += utf8_character_length(static_cast<unsigned char>(value[index]));
        }
    }
    return index;
}

struct ParsedSegment {
    WolframStringSegment segment;
    std::size_t end;
};

std::optional<ParsedSegment> parse_inline_box_segment(
    const std::string& value,
    std::size_t start,
    const std::string& prefix,
    const std::string& open,
    const std::string& close) {
    std::size_t index = start + prefix.size();
    std::size_t depth = 1;
    while (index < value.size()) {
        if (starts_with(value, index, open)) {
            ++depth;
            index += open.size();
            continue;
        }
        if (starts_with(value, index, close)) {
            --depth;
            index += close.size();
            if (depth == 0) {
                const auto expression_end = index - close.size();
                return ParsedSegment{
                    WolframStringSegment::inline_box_segment(
                        value.substr(start + prefix.size(), expression_end - start - prefix.size()),
                        value.substr(start, index - start)),
                    index};
            }
            continue;
        }
        if (value[index] == '"') {
            index = skip_string_value(value, index);
            continue;
        }
        if (starts_with(value, index, "(*")) {
            index = skip_comment_value(value, index);
            continue;
        }
        index += utf8_character_length(static_cast<unsigned char>(value[index]));
    }
    return std::nullopt;
}

} // namespace

WolframStringSegmentFields StringTextSegment::fields() const {
    return {{"kind", kind()}, {"text", text}};
}

WolframStringSegmentFields StringInlineBoxSegment::fields() const {
    return {{"kind", kind()}, {"box_expression", box_expression},
        {"inline_box_escape", source}};
}

WolframStringSegment WolframStringSegment::text_segment(std::string text) {
    return {Kind::Text, std::move(text), {}};
}

WolframStringSegment WolframStringSegment::inline_box_segment(
    std::string box_expression, std::string inline_box_escape) {
    return {Kind::InlineBox, std::move(box_expression), std::move(inline_box_escape)};
}

bool WolframStringSegment::is_text() const noexcept { return kind == Kind::Text; }

bool WolframStringSegment::is_inline_box() const noexcept { return kind == Kind::InlineBox; }

const char* WolframStringSegment::kind_name() const noexcept {
    return is_text() ? "text" : "inline_box";
}

const std::string& WolframStringSegment::box_expression() const {
    if (!is_inline_box()) {
        throw std::logic_error("a text Wolfram string segment has no box expression");
    }
    return text;
}

const std::string& WolframStringSegment::inline_box_escape() const {
    if (!is_inline_box()) {
        throw std::logic_error("a text Wolfram string segment has no inline-box escape");
    }
    return source;
}

WolframStringSegmentModel WolframStringSegment::model() const {
    if (is_text()) return StringTextSegment{text};
    return StringInlineBoxSegment{text, source};
}

WolframStringSegment::Fields WolframStringSegment::fields() const {
    if (is_text()) return {{"kind", kind_name()}, {"text", text}};
    return {{"kind", kind_name()}, {"box_expression", text},
        {"inline_box_escape", source}};
}

std::string wl_string(const std::string& value) {
    std::string output;
    output.reserve(value.size() + 2);
    output.push_back('"');
    for (const auto character : value) {
        switch (character) {
        case '\\': output += R"(\\)"; break;
        case '"': output += R"(\")"; break;
        case '\r': output += R"(\r)"; break;
        case '\n': output += R"(\n)"; break;
        case '\t': output += R"(\t)"; break;
        default: output.push_back(character); break;
        }
    }
    output.push_back('"');
    return output;
}

std::string parse_wl_string_literal(const std::string& value) {
    const bool quoted = value.size() >= 2 && value.front() == '"' && value.back() == '"';
    const auto begin = quoted ? std::size_t{1} : std::size_t{0};
    const auto end = quoted ? value.size() - 1 : value.size();
    const auto text = value.substr(begin, end - begin);

    std::string output;
    for (std::size_t index = 0; index < text.size();) {
        if (text[index] != '\\' || index + 1 >= text.size()) {
            const auto length = utf8_character_length(static_cast<unsigned char>(text[index]));
            output.append(text, index, length);
            index += length;
            continue;
        }
        const auto marker = text[index + 1];
        if (marker == '\n') { index += 2; continue; }
        if (marker == '\r') {
            index += 2;
            if (index < text.size() && text[index] == '\n') ++index;
            continue;
        }
        if (const auto decoded = decode_character_escape(text, index)) {
            output += decoded->text;
            index = decoded->end;
            continue;
        }
        switch (marker) {
        case 'b': output.push_back('\b'); break;
        case 'f': output.push_back('\f'); break;
        case 'r': output.push_back('\r'); break;
        case 'n': output.push_back('\n'); break;
        case 't': output.push_back('\t'); break;
        case '\\': output.push_back('\\'); break;
        case '"': output.push_back('"'); break;
        case '!': output += linear_syntax_bang; break;
        case '(': output += linear_syntax_open; break;
        case ')': output += linear_syntax_close; break;
        case '*': output += linear_syntax_star; break;
        case '<':
        case '>': break;
        default:
            output.push_back('\\');
            output.push_back(marker);
            break;
        }
        index += 2;
    }
    return output;
}

std::string inline_box_escape(const std::string& box_expression) {
    return std::string(inline_box_prefix) + box_expression + inline_box_close;
}

std::string compose_inline_box_string(
    const std::string& prefix,
    const std::vector<std::string>& box_expressions,
    const std::string& suffix) {
    std::string output = prefix;
    for (const auto& expression : box_expressions) output += inline_box_escape(expression);
    output += suffix;
    return output;
}

std::string compose_inline_box_string_literal(
    const std::string& prefix,
    const std::vector<std::string>& box_expressions,
    const std::string& suffix) {
    return wl_string(compose_inline_box_string(prefix, box_expressions, suffix));
}

std::vector<WolframStringSegment> split_inline_boxes(const std::string& value) {
    std::vector<WolframStringSegment> output;
    std::size_t text_start = 0;
    std::size_t index = 0;
    while (index < value.size()) {
        std::optional<ParsedSegment> parsed;
        if (starts_with(value, index, inline_box_prefix)) {
            parsed = parse_inline_box_segment(
                value, index, inline_box_prefix, inline_box_open, inline_box_close);
        } else if (starts_with(value, index, inline_box_prefix_decoded)) {
            parsed = parse_inline_box_segment(
                value, index, inline_box_prefix_decoded,
                inline_box_open_decoded, inline_box_close_decoded);
        }
        if (parsed) {
            if (text_start < index) {
                output.push_back(WolframStringSegment::text_segment(
                    value.substr(text_start, index - text_start)));
            }
            output.push_back(std::move(parsed->segment));
            index = parsed->end;
            text_start = index;
            continue;
        }
        index += utf8_character_length(static_cast<unsigned char>(value[index]));
    }
    if (text_start < value.size()) {
        output.push_back(WolframStringSegment::text_segment(value.substr(text_start)));
    }
    return output;
}

std::vector<WolframStringSegmentModel> split_inline_box_models(const std::string& value) {
    std::vector<WolframStringSegmentModel> output;
    for (const auto& segment : split_inline_boxes(value)) output.push_back(segment.model());
    return output;
}

std::vector<StringInlineBoxSegment> inline_box_segments(const std::string& value) {
    std::vector<StringInlineBoxSegment> output;
    for (const auto& segment : split_inline_boxes(value)) {
        if (segment.is_inline_box()) output.push_back(
            StringInlineBoxSegment{segment.text, segment.source});
    }
    return output;
}

bool has_inline_boxes(const std::string& value) {
    for (const auto& segment : split_inline_boxes(value)) {
        if (segment.is_inline_box()) return true;
    }
    return false;
}

std::string display_text(const std::string& value, const std::string& placeholder) {
    std::string output;
    for (const auto& segment : split_inline_boxes(value)) {
        output += segment.kind == WolframStringSegment::Kind::Text ? segment.text : placeholder;
    }
    return output;
}

std::size_t skip_wl_string(const std::string& text, std::size_t index) {
    return skip_string_value(text, index);
}

std::size_t skip_wl_comment(const std::string& text, std::size_t index) {
    return skip_comment_value(text, index);
}

} // namespace tungsten
