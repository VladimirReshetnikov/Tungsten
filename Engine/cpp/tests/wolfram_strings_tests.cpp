#include "tungsten/wolfram_strings.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <locale>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

class GroupedNumbers : public std::numpunct<char> {
protected:
    char do_thousands_sep() const override { return '_'; }
    std::string do_grouping() const override { return "\1"; }
};

class GlobalLocaleGuard {
public:
    explicit GlobalLocaleGuard(const std::locale& replacement)
        : previous_(std::locale()) {
        std::locale::global(replacement);
    }
    ~GlobalLocaleGuard() {
        try {
            std::locale::global(previous_);
        } catch (...) {
        }
    }

private:
    std::locale previous_;
};

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

template<typename Actual, typename Expected>
void check_equal(const Actual& actual, const Expected& expected, const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_string(
    const std::string& actual, const std::string& expected, const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected bytes:";
        for (const unsigned char value : expected) std::cerr << ' ' << std::hex << int(value);
        std::cerr << "\n  actual bytes:  ";
        for (const unsigned char value : actual) std::cerr << ' ' << std::hex << int(value);
        std::cerr << std::dec << '\n';
        ++failures;
    }
}

std::string utf8(std::uint32_t codepoint) {
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

void test_named_characters() {
    using namespace tungsten;

    const auto& forward = named_character_codepoints();
    const auto& reverse = named_character_reverse_map();
    check(forward.size() == 1100, "named-character table has all 1100 usable names");
    check(reverse.size() == 1064, "named-character reverse map omits raw ASCII spellings");
    check(forward.at("Alpha") == 0x03b1, "Alpha codepoint");
    check(forward.at("Function") == 0xf4a1, "Function PUA codepoint");
    check(forward.at("DoubleStruckCapitalZ") == 0xf7bd,
        "DoubleStruckCapitalZ Wolfram PUA codepoint");

    {
        GlobalLocaleGuard guard(
            std::locale(std::locale::classic(), new GroupedNumbers));
        check_string(encode_printable_ascii(utf8(0x10ffff)), R"(\|10ffff)",
            "numeric Unicode escapes ignore global digit grouping");
        check_string(encode_printable_ascii(std::string(1, '\x1f')), R"(\037)",
            "octal control escapes ignore global digit grouping");
    }

    for (const auto& [name, codepoint] : forward) {
        const auto character = named_character(name);
        check(character.has_value(), "named character resolves: " + name);
        if (!character) continue;
        check_string(*character, utf8(codepoint), "named-character codepoint: " + name);

        const auto escape_source = "\\[" + name + "]";
        const auto decoded = decode_named_character_escape(escape_source, 0);
        check(decoded.has_value(), "named escape decodes: " + name);
        if (decoded) {
            check_string(decoded->character, *character, "named escape value: " + name);
            check(decoded->end == escape_source.size(), "named escape end: " + name);
        }

        const bool excluded_reverse = codepoint < 128 && name.compare(0, 3, "Raw") == 0;
        if (!excluded_reverse) {
            const auto reverse_name = named_character_name(*character);
            check(reverse_name && *reverse_name == name, "named reverse mapping: " + name);
        }
    }

    check(!named_character("NotARealName"), "unknown named character is absent");
    check(!named_character_name(""), "empty character has no reverse name");
    check(!named_character_name("ab"), "multiple characters have no reverse name");
    check(!named_character_escape_for_char("#"), "raw printable ASCII has no named escape");
    check_equal(named_character_escape_for_char(u8"\ufffd"),
        std::optional<std::string>("\\[UnknownGlyph]"),
        "valid U+FFFD is distinct from invalid UTF-8");

    const auto offset = decode_named_character_escape("x\\[Alpha]y", 1);
    check(offset && offset->character == u8"\u03b1" && offset->end == 9,
        "lenient decoder reports byte end from nonzero offset");
    check(!decode_named_character_escape("x", 0), "lenient decoder ignores non-escape");
    check(!decode_named_character_escape("\\[NoSuchName]", 0),
        "lenient decoder declines unknown name");
    check(!decode_named_character_escape("\\[Alpha", 0),
        "lenient decoder declines unterminated escape");

    const auto strict = decode_named_character_escape_strict("\\[Alpha]", 0);
    check(strict && strict->character == u8"\u03b1" && strict->end == 8,
        "strict decoder accepts known escape");
    check(!decode_named_character_escape_strict("Alpha", 0),
        "strict decoder ignores a position without named escape prefix");
    try {
        (void)decode_named_character_escape_strict("x\\[Alpha", 1);
        check(false, "strict decoder rejects unterminated escape");
    } catch (const std::invalid_argument& error) {
        check_string(error.what(),
            "Unterminated Wolfram named character escape at offset 1.",
            "strict unterminated diagnostic");
    }
    try {
        (void)decode_named_character_escape_strict("\\[]", 0);
        check(false, "strict decoder rejects empty name");
    } catch (const std::invalid_argument& error) {
        check_string(error.what(), "Unknown Wolfram named character escape \\[].",
            "strict empty-name diagnostic");
    }
    try {
        (void)decode_named_character_escape_strict("\\[NoSuchName]", 0);
        check(false, "strict decoder rejects unknown name");
    } catch (const std::invalid_argument& error) {
        check_string(error.what(),
            "Unknown Wolfram named character escape \\[NoSuchName].",
            "strict unknown-name diagnostic");
    }

    std::string printable = "A";
    printable += "\b\t\n\f\r\x1b\x7f";
    printable += u8"\u03b1\ufffd\u00b2\U0001f600";
    check_string(encode_printable_ascii(printable),
        "A\\b\\t\\n\\f\\r\\[RawEscape]\\177"
        "\\[Alpha]\\[UnknownGlyph]\\:00b2\\|01f600",
        "printable-ASCII encoder precedence and numeric widths");
}

void test_wolfram_string_literals() {
    using namespace tungsten;

    check_string(wl_string("a\\b\r\n\t\"c\b\f"),
        "\"a\\\\b\\r\\n\\t\\\"c\b\f\"", "narrow Wolfram string encoder");
    check_string(parse_wl_string_literal(R"("\b\f\r\n\t\\\"")"),
        std::string("\b\f\r\n\t\\\""), "mnemonic string escapes");
    check_string(parse_wl_string_literal(R"("\101\041\377\0008")"),
        std::string("A!\xc3\xbf\0" "8", 6), "three-digit octal escapes");
    check_string(parse_wl_string_literal(R"("\.41\.A9\.FF\.a9\.00")"),
        std::string("A\xc2\xa9\xc3\xbf\xc2\xa9\0", 8), "Latin-1 escapes");
    check_string(parse_wl_string_literal(R"("\:0041\:03C0\:F4A1\:03c0")"),
        std::string("A") + u8"\u03c0\uf4a1\u03c0", "four-digit Unicode escapes");
    check_string(parse_wl_string_literal(R"("\|000041\|01F600\|10FFFF")"),
        std::string("A") + u8"\U0001f600" + utf8(0x10ffff),
        "six-digit Unicode escapes");
    check_string(parse_wl_string_literal(R"("\:D800\|00DFFF")"),
        utf8(0xd800) + utf8(0xdfff), "isolated surrogates are preserved as WTF-8");
    check_string(encode_printable_ascii(utf8(0xd800) + utf8(0xdfff)),
        "\\:d800\\:dfff", "WTF-8 surrogates re-render as four-digit escapes");
    check_string(parse_wl_string_literal(R"("\[Alpha]\[Function]\[NoSuchName]\[]")"),
        std::string(u8"\u03b1\uf4a1") + R"(\[NoSuchName]\[])",
        "known and unknown named escapes");

    check_string(parse_wl_string_literal("\"a\\\nb\""), "ab", "LF continuation");
    check_string(parse_wl_string_literal("\"a\\\r\nb\""), "ab", "CRLF continuation");
    check_string(parse_wl_string_literal("\"a\\\rb\""), "ab", "CR continuation");
    check_string(parse_wl_string_literal(R"("\!\(\)\*\<\>")"),
        u8"\uf7c1\uf7c9\uf7c0\uf7c8", "linear-syntax escapes");
    check_string(parse_wl_string_literal(R"("\:003\.A\|0000\g")"),
        R"(\:003\.A\|0000\g)", "malformed and unknown escapes are preserved");
    check_string(parse_wl_string_literal("unquoted\\ntext"), "unquoted\ntext",
        "unquoted input follows the same decoding loop");
    check_string(parse_wl_string_literal("\""), "\"",
        "single quote byte is not stripped as a complete literal");
}

void test_inline_boxes() {
    using namespace tungsten;

    check(split_inline_boxes("").empty(), "empty value has no segments");
    const auto plain = split_inline_boxes("plain");
    check(plain == std::vector<WolframStringSegment>{
        WolframStringSegment::text_segment("plain")}, "plain text segment model");
    check_equal(plain[0].fields(), WolframStringSegment::Fields{
        {"kind", "text"}, {"text", "plain"}}, "text segment neutral fields");
    check(plain[0].kind_name() == std::string("text") && plain[0].is_text(),
        "text segment discriminators");
    const auto plain_models = split_inline_box_models("plain");
    check(plain_models.size() == 1
        && std::holds_alternative<StringTextSegment>(plain_models[0])
        && std::get<StringTextSegment>(plain_models[0]).text == "plain",
        "precise text dataclass-equivalent model");

    const auto first = R"(GraphicsBox[{CircleBox[]}])";
    const auto second = R"(StyleBox["x", Bold])";
    const auto composed = compose_inline_box_string("icon: ", {first, second}, ".");
    check_string(composed,
        R"(icon: \!\(\*GraphicsBox[{CircleBox[]}]\)\!\(\*StyleBox["x", Bold]\).)",
        "inline-box composition");
    check_string(compose_inline_box_string_literal("icon: ", {first, second}, "."),
        R"("icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)\\!\\(\\*StyleBox[\"x\", Bold]\\).")",
        "inline-box literal composition");

    const auto segments = split_inline_boxes(composed);
    check(segments.size() == 4, "composed string segment count");
    check(segments[1].is_inline_box() && segments[2].is_inline_box(),
        "inline segment discriminators");
    check_string(segments[1].box_expression(), first, "inline box expression accessor");
    check_string(segments[1].inline_box_escape(), inline_box_escape(first),
        "inline box source accessor");
    check_equal(segments[1].fields(), WolframStringSegment::Fields{
        {"kind", "inline_box"}, {"box_expression", first},
        {"inline_box_escape", inline_box_escape(first)}},
        "inline segment neutral fields");
    check(inline_box_segments(composed)
        == std::vector<StringInlineBoxSegment>{
            {segments[1].text, segments[1].source},
            {segments[2].text, segments[2].source}},
        "inline_box_segments preserves typed segment models");
    const auto precise_segments = split_inline_box_models(composed);
    check(precise_segments.size() == 4
        && std::holds_alternative<StringInlineBoxSegment>(precise_segments[1])
        && std::get<StringInlineBoxSegment>(precise_segments[1]).fields()
            == segments[1].fields(),
        "precise inline dataclass-equivalent model");
    check(has_inline_boxes(composed) && !has_inline_boxes("plain"),
        "inline-box predicate");
    check_string(display_text(composed), "icon: [InlineBox][InlineBox].",
        "default inline-box display placeholder");
    check_string(display_text(composed, "#"), "icon: ##.",
        "custom inline-box display placeholder");

    const auto decoded = parse_wl_string_literal(wl_string(inline_box_escape(first)));
    const auto decoded_segments = inline_box_segments(decoded);
    check(decoded_segments.size() == 1, "decoded PUA inline-box recognition");
    if (!decoded_segments.empty()) {
        check_string(decoded_segments[0].box_expression, first,
            "decoded inline box expression");
        check_string(decoded_segments[0].inline_box_escape(), decoded,
            "decoded inline box retains decoded source markers");
    }

    const auto nested =
        R"WL(before \!\(\*RowBox[{"literal \\)", (* ignored \) *) FormBox[\(x\), TraditionalForm]}]\) after)WL";
    const auto nested_segments = split_inline_boxes(nested);
    check(nested_segments.size() == 3 && nested_segments[1].is_inline_box(),
        "inline scanner skips quoted delimiters/comments and tracks nesting");
    check_string(display_text(nested), "before [InlineBox] after", "nested box display");

    const auto malformed = R"(before \!\(\*GraphicsBox[] after)";
    check(!has_inline_boxes(malformed), "unterminated inline box remains text");
    check(split_inline_boxes(malformed).size() == 1,
        "unterminated inline box yields one text segment");

    try {
        (void)plain[0].box_expression();
        check(false, "text segment rejects box expression accessor");
    } catch (const std::logic_error&) {
    }
}

void test_scanners() {
    using namespace tungsten;

    const std::string quoted = R"(xx"a\"b"tail)";
    check(skip_wl_string(quoted, 2) == quoted.find("tail"),
        "string scanner skips escaped quote");
    const std::string unicode = std::string("\"") + u8"\u03b1" + "\\" + u8"\u03b2" + "\"tail";
    check(skip_wl_string(unicode, 0) == unicode.find("tail"),
        "string scanner advances over UTF-8 and escaped UTF-8");
    check(skip_wl_string("\"x\\", 0) == 4,
        "malformed trailing escape preserves Python cursor semantics");

    const std::string comment = "xx(* a (* nested *) z *)tail";
    check(skip_wl_comment(comment, 2) == comment.find("tail"),
        "comment scanner tracks nesting");
    check(skip_wl_comment("(* unterminated", 0) == std::string("(* unterminated").size(),
        "unterminated comment scans to end");
    check(skip_wl_string("\"x\"", std::numeric_limits<std::size_t>::max())
            == std::numeric_limits<std::size_t>::max(),
        "string scanner cursor saturates instead of wrapping");
    check(skip_wl_comment("(*x*)", std::numeric_limits<std::size_t>::max())
            == std::numeric_limits<std::size_t>::max(),
        "comment scanner cursor saturates instead of wrapping");
}

} // namespace

int main() {
    test_named_characters();
    test_wolfram_string_literals();
    test_inline_boxes();
    test_scanners();
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ Wolfram string tests passed\n";
    return EXIT_SUCCESS;
}
