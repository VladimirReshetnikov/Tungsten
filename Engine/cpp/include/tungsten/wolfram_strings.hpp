#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace tungsten {

inline constexpr const char* inline_box_prefix = R"(\!\(\*)";
inline constexpr const char* inline_box_open = R"(\()";
inline constexpr const char* inline_box_close = R"(\))";
inline constexpr const char* inline_box_prefix_decoded = u8"\uf7c1\uf7c9\uf7c8";
inline constexpr const char* inline_box_open_decoded = u8"\uf7c1\uf7c9";
inline constexpr const char* inline_box_bare_open_decoded = u8"\uf7c9";
inline constexpr const char* inline_box_close_decoded = u8"\uf7c0";

using WolframStringSegmentFields = std::vector<std::pair<std::string, std::string>>;

struct StringTextSegment {
    std::string text;

    [[nodiscard]] const char* kind() const noexcept { return "text"; }
    [[nodiscard]] WolframStringSegmentFields fields() const;

    friend bool operator==(
        const StringTextSegment& left, const StringTextSegment& right) noexcept {
        return left.text == right.text;
    }
    friend bool operator!=(
        const StringTextSegment& left, const StringTextSegment& right) noexcept {
        return !(left == right);
    }
};

struct StringInlineBoxSegment {
    std::string box_expression;
    std::string source;

    [[nodiscard]] const char* kind() const noexcept { return "inline_box"; }
    [[nodiscard]] const std::string& inline_box_escape() const noexcept { return source; }
    [[nodiscard]] WolframStringSegmentFields fields() const;

    friend bool operator==(
        const StringInlineBoxSegment& left, const StringInlineBoxSegment& right) noexcept {
        return left.box_expression == right.box_expression && left.source == right.source;
    }
    friend bool operator!=(
        const StringInlineBoxSegment& left, const StringInlineBoxSegment& right) noexcept {
        return !(left == right);
    }
};

using WolframStringSegmentModel = std::variant<StringTextSegment, StringInlineBoxSegment>;

// Compatibility wrapper used by the initial C++ command surface. New code can
// obtain the precise Python-equivalent dataclass model with ``model()`` or
// ``split_inline_box_models`` below.
struct WolframStringSegment {
    enum class Kind { Text, InlineBox };

    using Fields = WolframStringSegmentFields;

    Kind kind;
    // For Text segments this is the text value. For InlineBox segments it is
    // the box expression, matching Python's ``box_expression`` field.
    std::string text;
    // Empty for Text segments. For InlineBox segments this is the complete
    // source escape, matching Python's ``inline_box_escape`` dictionary key.
    std::string source;

    [[nodiscard]] static WolframStringSegment text_segment(std::string text);
    [[nodiscard]] static WolframStringSegment inline_box_segment(
        std::string box_expression, std::string inline_box_escape);

    [[nodiscard]] bool is_text() const noexcept;
    [[nodiscard]] bool is_inline_box() const noexcept;
    [[nodiscard]] const char* kind_name() const noexcept;
    [[nodiscard]] const std::string& box_expression() const;
    [[nodiscard]] const std::string& inline_box_escape() const;
    [[nodiscard]] WolframStringSegmentModel model() const;
    // A serializer-neutral equivalent of the Python segment's ``to_dict``.
    [[nodiscard]] Fields fields() const;

    friend bool operator==(
        const WolframStringSegment& left, const WolframStringSegment& right) noexcept {
        return left.kind == right.kind && left.text == right.text && left.source == right.source;
    }
    friend bool operator!=(
        const WolframStringSegment& left, const WolframStringSegment& right) noexcept {
        return !(left == right);
    }
};

[[nodiscard]] std::string wl_string(const std::string& value);
[[nodiscard]] std::string parse_wl_string_literal(const std::string& value);
[[nodiscard]] std::string inline_box_escape(const std::string& box_expression);
[[nodiscard]] std::string compose_inline_box_string(
    const std::string& prefix = {},
    const std::vector<std::string>& box_expressions = {},
    const std::string& suffix = {});
[[nodiscard]] std::string compose_inline_box_string_literal(
    const std::string& prefix = {},
    const std::vector<std::string>& box_expressions = {},
    const std::string& suffix = {});
[[nodiscard]] std::vector<WolframStringSegment> split_inline_boxes(const std::string& value);
[[nodiscard]] std::vector<WolframStringSegmentModel> split_inline_box_models(
    const std::string& value);
[[nodiscard]] std::vector<StringInlineBoxSegment> inline_box_segments(const std::string& value);
[[nodiscard]] bool has_inline_boxes(const std::string& value);
[[nodiscard]] std::string display_text(
    const std::string& value, const std::string& placeholder = "[InlineBox]");
[[nodiscard]] std::size_t skip_wl_string(const std::string& text, std::size_t index);
[[nodiscard]] std::size_t skip_wl_comment(const std::string& text, std::size_t index);

using NamedCharacterCodepoints = std::map<std::string, std::uint32_t>;
using NamedCharacterReverseMap = std::map<std::uint32_t, std::string>;

struct DecodedNamedCharacterEscape {
    std::string character;
    std::size_t end;

    friend bool operator==(const DecodedNamedCharacterEscape& left,
        const DecodedNamedCharacterEscape& right) noexcept {
        return left.character == right.character && left.end == right.end;
    }
};

[[nodiscard]] const NamedCharacterCodepoints& named_character_codepoints();
[[nodiscard]] const NamedCharacterReverseMap& named_character_reverse_map();
[[nodiscard]] std::optional<std::string> named_character(const std::string& name);
[[nodiscard]] std::optional<std::string> named_character_name(const std::string& utf8_character);
[[nodiscard]] std::optional<std::string> named_character_escape_for_char(
    const std::string& utf8_character);
[[nodiscard]] std::optional<DecodedNamedCharacterEscape> decode_named_character_escape(
    std::string_view text, std::size_t index);
// Returns nullopt when ``index`` is not the start of a named-character escape.
// Throws std::invalid_argument for an unterminated, empty, or unknown escape.
[[nodiscard]] std::optional<DecodedNamedCharacterEscape> decode_named_character_escape_strict(
    std::string_view text, std::size_t index);
[[nodiscard]] std::string encode_printable_ascii(const std::string& text);

} // namespace tungsten
