#include "tungsten/parser.hpp"

#include "tungsten/detail/ascii.hpp"
#include "tungsten/detail/unicode.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <optional>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace tungsten {
namespace {

enum class TokenKind { Integer, Real, String, Symbol, Percent, Filename, Operator, Eof };

struct Token {
    TokenKind kind;
    std::string text;
    std::size_t start = 0;
    std::size_t end = 0;
    std::string value;
};

[[noreturn]] void syntax(const std::string& message) { throw ParseError(message); }

bool starts_with(const std::string& text, std::size_t at, std::string_view value) {
    return at <= text.size() && value.size() <= text.size() - at
        && text.compare(at, value.size(), value) == 0;
}

std::size_t character_length(unsigned char first) {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

const std::vector<std::pair<std::string, std::string>>& token_names() {
    static const std::vector<std::pair<std::string, std::string>> values{
        {"And", "&&"}, {"Equal", "=="}, {"Function", "|->"},
        {"GreaterEqual", ">="}, {"InvisibleApplication", "@"},
        {"InvisibleTimes", "*"}, {"Rule", "->"}, {"RuleDelayed", ":>"},
        {"LessEqual", "<="}, {"LeftAssociation", "<|"}, {"NotEqual", "!="},
        {"Or", "||"}, {"RightAssociation", "|>"}};
    return values;
}

const std::vector<std::pair<std::string, std::string>>& alias_names() {
    static const std::vector<std::pair<std::string, std::string>> values{
        {"Degree", "Degree"}, {"ExponentialE", "E"}, {"ImaginaryI", "I"},
        {"ImaginaryJ", "I"}, {"Infinity", "Infinity"}, {"Pi", "Pi"}};
    return values;
}

const std::vector<std::string>& operator_names() {
    static const std::vector<std::string> values{
        "CenterDot", "CircleDot", "CircleMinus", "CirclePlus", "CircleTimes", "Congruent",
        "Cross", "Diamond", "DirectedEdge", "DiscreteRatio", "DiscreteShift", "DoubleLeftArrow",
        "DoubleLeftRightArrow", "DoubleRightArrow", "DoubleVerticalBar", "DownArrow", "Element",
        "Equivalent", "Implies", "Intersection", "LeftArrow", "LeftRightArrow", "LessEqualGreater",
        "LongLeftArrow", "LongLeftRightArrow", "LongRightArrow", "MinusPlus", "NotElement",
        "NotSubset", "NotSubsetEqual", "NotSuperset", "NotSupersetEqual", "PlusMinus", "Precedes",
        "PrecedesEqual", "Proportion", "RightArrow", "SmallCircle", "SquareIntersection",
        "SquareSubset", "SquareSubsetEqual", "SquareSuperset", "SquareSupersetEqual", "SquareUnion",
        "Star", "Subset", "SubsetEqual", "Succeeds", "SucceedsEqual", "Superset", "SupersetEqual",
        "TensorProduct", "Tilde", "TildeEqual", "TildeFullEqual", "TildeTilde", "UndirectedEdge",
        "Union", "UnionPlus", "UpArrow", "Vee", "VerticalBar", "VerticalSeparator", "Wedge"};
    return values;
}

std::optional<std::string> escaped_token(const std::string& name) {
    for (const auto& [candidate, value] : token_names()) if (candidate == name) return value;
    return std::nullopt;
}

std::optional<std::string> escaped_alias(const std::string& name) {
    for (const auto& [candidate, value] : alias_names()) if (candidate == name) return value;
    return std::nullopt;
}

bool escaped_operator(const std::string& name) {
    return std::find(operator_names().begin(), operator_names().end(), name) != operator_names().end();
}

std::optional<std::pair<std::string, std::string>> raw_named_token(
    const std::string& text, std::size_t start) {
    for (const auto& [name, normalized] : token_names()) {
        const auto value = named_character(name);
        if (value && starts_with(text, start, *value)) return {{*value, normalized}};
    }
    for (const auto& [name, alias] : alias_names()) {
        const auto value = named_character(name);
        if (value && starts_with(text, start, *value)) return {{*value, alias}};
    }
    for (const auto& name : operator_names()) {
        const auto value = named_character(name);
        if (value && starts_with(text, start, *value)) return {{*value, name}};
    }
    return std::nullopt;
}

std::optional<std::string> named_operator_head(const std::string& token) {
    if (token.size() >= 4 && token.compare(0, 2, R"(\[)") == 0 && token.back() == ']') {
        const auto name = token.substr(2, token.size() - 3);
        return escaped_operator(name) ? std::optional<std::string>(name) : std::nullopt;
    }
    for (const auto& name : operator_names()) {
        if (const auto value = named_character(name); value && *value == token) return name;
    }
    return std::nullopt;
}

std::optional<std::size_t> line_continuation_end(const std::string& text, std::size_t start) {
    std::size_t index = start + 1;
    while (index < text.size() && (text[index] == ' ' || text[index] == '\t')) ++index;
    if (index < text.size() && text[index] == '\r') {
        return index + 1 + (index + 1 < text.size() && text[index + 1] == '\n' ? 1 : 0);
    }
    if (index < text.size() && text[index] == '\n') return index + 1;
    return std::nullopt;
}

std::size_t skip_comment(const std::string& text, std::size_t start) {
    std::size_t index = start + 2;
    std::size_t depth = 1;
    while (index < text.size()) {
        if (starts_with(text, index, "(*")) { ++depth; index += 2; }
        else if (starts_with(text, index, "*)")) {
            --depth; index += 2;
            if (depth == 0) return index;
        } else index += character_length(static_cast<unsigned char>(text[index]));
    }
    syntax("Unterminated Wolfram comment at offset " + std::to_string(start) + ".");
}

std::pair<Token, std::size_t> scan_string(const std::string& text, std::size_t start) {
    std::size_t index = start + 1;
    while (index < text.size()) {
        if (text[index] == '\\') {
            ++index;
            if (index < text.size()) index += character_length(static_cast<unsigned char>(text[index]));
            continue;
        }
        const bool closing = text[index] == '"';
        index += character_length(static_cast<unsigned char>(text[index]));
        if (closing) {
            const auto raw = text.substr(start, index - start);
            return {{TokenKind::String, raw, start, index, parse_wl_string_literal(raw)}, index};
        }
    }
    syntax("Unterminated Wolfram string literal.");
}

int base_digit(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'z') return value - 'a' + 10;
    if (value >= 'A' && value <= 'Z') return value - 'A' + 10;
    return -1;
}

struct DecimalDigit {
    std::size_t length;
    std::optional<unsigned> value;
};

std::optional<DecimalDigit> decimal_digit_at(
    const std::string& text, std::size_t offset) {
    if (offset >= text.size()) return std::nullopt;
    const auto decoded = detail::decode_utf8_code_point(text, offset);
    if (!decoded.valid || !detail::unicode_is_digit(decoded.value))
        return std::nullopt;
    return DecimalDigit{
        decoded.length, detail::unicode_decimal_value(decoded.value)};
}

std::size_t scan_decimal_digits(
    const std::string& text, std::size_t offset) {
    while (const auto digit = decimal_digit_at(text, offset))
        offset += digit->length;
    return offset;
}

std::string normalized_decimal_digits(
    const std::string& text, std::size_t start, std::size_t end,
    const std::string& diagnostic) {
    std::string normalized;
    normalized.reserve(end - start);
    for (auto offset = start; offset < end;) {
        const auto digit = decimal_digit_at(text, offset);
        if (!digit || !digit->value) syntax(diagnostic);
        normalized.push_back(static_cast<char>('0' + *digit->value));
        offset += digit->length;
    }
    return normalized;
}

bool consists_of_decimal_digits(std::string_view text) {
    if (text.empty()) return false;
    for (std::size_t offset = 0; offset < text.size();) {
        const auto decoded = detail::decode_utf8_code_point(text, offset);
        if (!decoded.valid || !detail::unicode_decimal_value(decoded.value))
            return false;
        offset += decoded.length;
    }
    return true;
}

std::pair<Token, std::size_t> scan_number(const std::string& text, std::size_t start) {
    std::size_t index = scan_decimal_digits(text, start);
    if (index > start && starts_with(text, index, "^^")) {
        int base = 0;
        for (auto cursor = start; cursor < index;) {
            const auto scanned = decimal_digit_at(text, cursor);
            if (!scanned || !scanned->value)
                syntax("Wolfram base-number literals require a base between 2 and 36.");
            const auto digit = static_cast<int>(*scanned->value);
            if (base > (36 - digit) / 10)
                syntax("Wolfram base-number literals require a base between 2 and 36.");
            base = base * 10 + digit;
            cursor += scanned->length;
        }
        if (base < 2 || base > 36) syntax("Wolfram base-number literals require a base between 2 and 36.");
        const auto mantissa = index + 2;
        index = mantissa;
        bool dot = false;
        bool digits = false;
        while (index < text.size()) {
            const auto value = base_digit(text[index]);
            if (value >= 0) {
                if (value >= base) syntax("Malformed Wolfram base-" + std::to_string(base) + " literal.");
                digits = true; ++index;
            } else if (text[index] == '.' && !dot && !starts_with(text, index, "..")) {
                dot = true; ++index;
            } else break;
        }
        if (!digits || starts_with(text, index, "..")) syntax("Malformed Wolfram base-number literal.");
        bool precision = false;
        if (index < text.size() && text[index] == '`') {
            precision = true; ++index;
            const bool accuracy = index < text.size() && text[index] == '`';
            if (accuracy) ++index;
            const auto mark = index;
            index = scan_decimal_digits(text, index);
            if (index < text.size() && text[index] == '.' && !starts_with(text, index, "..")) {
                ++index;
                index = scan_decimal_digits(text, index);
            }
            if (accuracy && mark == index) syntax("Malformed Wolfram accuracy mark.");
        }
        bool magnitude = false;
        if (starts_with(text, index, "*^")) {
            magnitude = true; index += 2;
            if (index < text.size() && (text[index] == '+' || text[index] == '-')) ++index;
            const auto exponent = index;
            index = scan_decimal_digits(text, index);
            if (exponent == index) syntax("Malformed Wolfram numeric exponent.");
            if (index < text.size() && text[index] == '.' && !starts_with(text, index, ".."))
                syntax("Malformed Wolfram numeric exponent.");
        }
        const auto raw = text.substr(start, index - start);
        if (!dot && !precision && !magnitude) {
            mpz_class value;
            if (mpz_set_str(value.get_mpz_t(),
                    text.substr(mantissa, index - mantissa).c_str(), base) != 0)
                syntax("Malformed Wolfram base-number literal.");
            return {{TokenKind::Integer, raw, start, index, value.get_str()}, index};
        }
        return {{TokenKind::Real, raw, start, index, raw}, index};
    }
    bool dot = false;
    bool digits = index > start;
    if (index < text.size() && text[index] == '.' && !starts_with(text, index, "..")) {
        dot = true; ++index;
        while (const auto digit = decimal_digit_at(text, index)) {
            digits = true;
            index += digit->length;
        }
    }
    bool precision = false;
    if (index < text.size() && text[index] == '`') {
        precision = true; ++index;
        bool accuracy = false;
        if (index < text.size() && text[index] == '`') { accuracy = true; ++index; }
        const auto mark = index;
        index = scan_decimal_digits(text, index);
        if (index < text.size() && text[index] == '.' && !starts_with(text, index, "..")) {
            ++index;
            index = scan_decimal_digits(text, index);
        }
        if (accuracy && mark == index) syntax("Malformed Wolfram accuracy mark.");
    }
    bool magnitude = false;
    if (starts_with(text, index, "*^")) {
        magnitude = true; index += 2;
        if (index < text.size() && (text[index] == '+' || text[index] == '-')) ++index;
        const auto exponent = index;
        index = scan_decimal_digits(text, index);
        if (exponent == index) syntax("Malformed Wolfram numeric exponent.");
        if (index < text.size() && text[index] == '.' && !starts_with(text, index, ".."))
            syntax("Malformed Wolfram numeric exponent.");
    }
    const auto raw = text.substr(start, index - start);
    if (!digits || raw == ".") syntax("Malformed Wolfram number near " + raw + ".");
    const auto kind = dot || precision || magnitude ? TokenKind::Real : TokenKind::Integer;
    const auto value = kind == TokenKind::Integer
        ? normalized_decimal_digits(text, start, index,
            "Malformed Wolfram integer literal.")
        : raw;
    return {{kind, raw, start, index, value}, index};
}

bool ascii_symbol_start(char value) {
    return detail::ascii_is_alpha(static_cast<unsigned char>(value))
        || value == '$' || value == '`';
}
bool ascii_symbol_continue(char value) {
    return detail::ascii_is_alnum(static_cast<unsigned char>(value))
        || value == '$' || value == '`';
}

std::optional<std::pair<std::string, std::size_t>> symbol_escape(
    const std::string& text, std::size_t start) {
    if (!starts_with(text, start, R"(\[)")) return std::nullopt;
    const auto end = text.find(']', start + 2);
    if (end == std::string::npos) syntax("Unterminated Wolfram named character escape at offset " + std::to_string(start) + ".");
    const auto name = text.substr(start + 2, end - start - 2);
    if (escaped_operator(name) || escaped_token(name)) return std::nullopt;
    const auto value = named_character(name);
    if (!value) syntax("Unknown Wolfram named character escape \\[" + name + "].");
    return {{*value, end + 1}};
}

std::optional<std::pair<Token, std::size_t>> scan_symbol(
    const std::string& text, std::size_t start) {
    std::size_t index = start;
    std::string name;
    if (text[index] == '\\') {
        const auto escaped = symbol_escape(text, index);
        if (!escaped) return std::nullopt;
        name += escaped->first; index = escaped->second;
    } else if (static_cast<unsigned char>(text[index]) >= 0x80) {
        const auto length = character_length(static_cast<unsigned char>(text[index]));
        name.append(text, index, length); index += length;
    } else if (ascii_symbol_start(text[index])) name.push_back(text[index++]);
    else return std::nullopt;
    while (index < text.size()) {
        if (text[index] == '\\') {
            const auto escaped = symbol_escape(text, index);
            if (!escaped) break;
            name += escaped->first; index = escaped->second; continue;
        }
        if (static_cast<unsigned char>(text[index]) >= 0x80) {
            if (raw_named_token(text, index)) break;
            const auto length = character_length(static_cast<unsigned char>(text[index]));
            name.append(text, index, length); index += length; continue;
        }
        if (!ascii_symbol_continue(text[index])) break;
        name.push_back(text[index++]);
    }
    for (const auto& [named, alias] : alias_names()) {
        if (const auto value = named_character(named); value && *value == name) name = alias;
    }
    return {{{TokenKind::Symbol, text.substr(start, index - start), start, index, name}, index}};
}

std::optional<std::pair<Token, std::size_t>> scan_escaped_token(
    const std::string& text, std::size_t start) {
    if (!starts_with(text, start, R"(\[)")) return std::nullopt;
    const auto end_quote = text.find(']', start + 2);
    if (end_quote == std::string::npos) syntax("Unterminated Wolfram escaped token at offset " + std::to_string(start) + ".");
    const auto name = text.substr(start + 2, end_quote - start - 2);
    const auto end = end_quote + 1;
    if (const auto normalized = escaped_token(name))
        return {{{TokenKind::Operator, *normalized, start, end, *normalized}, end}};
    if (const auto alias = escaped_alias(name))
        return {{{TokenKind::Symbol, text.substr(start, end - start), start, end, *alias}, end}};
    if (escaped_operator(name)) {
        const auto raw = text.substr(start, end - start);
        return {{{TokenKind::Operator, raw, start, end, raw}, end}};
    }
    const auto value = named_character(name);
    if (!value) syntax("Unknown Wolfram named character escape \\[" + name + "].");
    return {{{TokenKind::Symbol, text.substr(start, end - start), start, end, *value}, end}};
}

std::vector<Token> tokenize(const std::string& text) {
    static const std::vector<std::string> multi{
        "===", "=!=" , "___", "^:=", "//=", "__", "##", "...", "//.", "//@", "@@@", ">>>", "<->", "..",
        "[[", "~~", "<>", "<|", "|>", "|->", "@*", "/*", ":=", "::", ":>", "->", "=.", "^=", "+=",
        "-=", "*=", "/=", "/:", "/;", "//", "/@", "/.", "@@", "++", "--", "**", "<<", ">>", "??", "<=",
        ">=", "==", "!=", "&&", "||", ";;"};
    std::vector<Token> tokens;
    for (std::size_t index = 0; index < text.size();) {
        const auto byte = static_cast<unsigned char>(text[index]);
        if (byte < 0x80 && detail::ascii_is_space(byte)) { ++index; continue; }
        if (text[index] == '\\') {
            if (const auto end = line_continuation_end(text, index)) { index = *end; continue; }
        }
        if (starts_with(text, index, "(*")) { index = skip_comment(text, index); continue; }
        if (text[index] == '"') {
            auto [token, end] = scan_string(text, index); tokens.push_back(std::move(token)); index = end; continue;
        }
        if (const auto named = raw_named_token(text, index)) {
            const auto end = index + named->first.size();
            const bool alias = std::any_of(alias_names().begin(), alias_names().end(),
                [&](const auto& entry) { return entry.second == named->second; });
            tokens.push_back({alias ? TokenKind::Symbol : TokenKind::Operator,
                alias ? named->first : (escaped_operator(named->second) ? named->first : named->second),
                index, end, named->second});
            index = end; continue;
        }
        if (const auto scanned = scan_symbol(text, index)) {
            tokens.push_back(scanned->first); index = scanned->second; continue;
        }
        if (const auto scanned = scan_escaped_token(text, index)) {
            tokens.push_back(scanned->first); index = scanned->second; continue;
        }
        if (detail::ascii_is_digit(byte) || (text[index] == '.'
                && decimal_digit_at(text, index + 1))) {
            auto [token, end] = scan_number(text, index); tokens.push_back(std::move(token)); index = end; continue;
        }
        if (text[index] == '%') {
            const auto start = index;
            while (index < text.size() && text[index] == '%') ++index;
            const auto count = index - start;
            std::string value;
            if (count == 1 && decimal_digit_at(text, index)) {
                const auto digits = index;
                index = scan_decimal_digits(text, index);
                value = normalized_decimal_digits(text, digits, index,
                    "Malformed Wolfram output-history index.");
            } else if (count > 1) value = "-" + std::to_string(count);
            tokens.push_back({TokenKind::Percent, text.substr(start, index - start), start, index, value}); continue;
        }
        const auto found = std::find_if(multi.begin(), multi.end(), [&](const auto& value) { return starts_with(text, index, value); });
        if (found != multi.end()) {
            const auto start = index; index += found->size();
            tokens.push_back({TokenKind::Operator, *found, start, index, *found});
            if ((*found == "<<" || *found == ">>" || *found == ">>>")) {
                while (index < text.size() && (text[index] == ' ' || text[index] == '\t')) ++index;
                if (index < text.size() && text[index] != '"') {
                    const auto name_start = index;
                    while (index < text.size() && (detail::ascii_is_alnum(
                            static_cast<unsigned char>(text[index]))
                        || std::string("_-*:/\\.`$!?~").find(text[index]) != std::string::npos)) ++index;
                    if (index > name_start) tokens.push_back({TokenKind::Filename,
                        text.substr(name_start, index - name_start), name_start, index,
                        text.substr(name_start, index - name_start)});
                }
            }
            continue;
        }
        if (std::string("[]{}(),.;:+-*/^!@<>_|&#=?~'").find(text[index]) != std::string::npos) {
            tokens.push_back({TokenKind::Operator, text.substr(index, 1), index, index + 1, text.substr(index, 1)});
            ++index; continue;
        }
        syntax("Unexpected Wolfram syntax character at offset " + std::to_string(index) + ".");
    }
    tokens.push_back({TokenKind::Eof, "", text.size(), text.size(), ""});
    return tokens;
}

struct Parsed {
    Expr expr;
    bool grouped = false;
    std::string operator_head;
    bool completed_span = false;

    Parsed(Expr value, bool is_grouped = false, std::string head = {},
        bool span_complete = false)
        : expr(std::move(value)), grouped(is_grouped),
          operator_head(std::move(head)), completed_span(span_complete) {}
};

bool starts_primary(const Token& token) {
    return token.kind == TokenKind::Integer || token.kind == TokenKind::Real
        || token.kind == TokenKind::String || token.kind == TokenKind::Symbol
        || token.kind == TokenKind::Percent
        || token.text == "(" || token.text == "{" || token.text == "<|"
        || token.text == "#" || token.text == "##" || token.text == "_"
        || token.text == "__" || token.text == "___" || token.text == "<<";
}

bool can_start_expression(const Token& token) {
    return starts_primary(token) || token.text == "?" || token.text == "??"
        || token.text == "++" || token.text == "--" || token.text == "+"
        || token.text == "-" || token.text == "!" || token.text == ";;";
}

bool contains(const std::vector<std::string>& values, const std::string& value) {
    return std::find(values.begin(), values.end(), value) != values.end();
}

struct BinarySpec { int left; int right; std::string head; };

std::optional<BinarySpec> binary_spec(const std::string& text) {
    static const std::unordered_map<std::string, BinarySpec> specs{
        {"^",{160,160,"Power"}}, {"**",{146,147,"NonCommutativeMultiply"}},
        {"*",{140,141,"Times"}}, {"/",{140,141,""}}, {"+",{120,121,"Plus"}}, {"-",{120,121,""}},
        {"<>",{120,121,"StringJoin"}}, {"==",{100,100,"Equal"}}, {"===",{100,100,"SameQ"}},
        {"!=",{100,100,"Unequal"}}, {"=!=" ,{100,100,"UnsameQ"}}, {"<",{100,100,"Less"}},
        {"<=",{100,100,"LessEqual"}}, {">",{100,100,"Greater"}}, {">=",{100,100,"GreaterEqual"}},
        {"&&",{80,81,"And"}}, {"||",{70,71,"Or"}}, {"|",{65,66,"Alternatives"}},
        {"~~",{64,65,"StringExpression"}}, {":",{180,63,"Pattern"}}, {"/;",{62,63,"Condition"}},
        {"<->",{61,61,"TwoWayRule"}}, {"->",{60,60,"Rule"}}, {":>",{60,60,"RuleDelayed"}},
        {"/.",{50,51,"ReplaceAll"}}, {"//.",{50,51,"ReplaceRepeated"}}, {"/@",{45,45,"Map"}},
        {"//@",{45,45,"MapAll"}}, {"@@",{44,44,"Apply"}}, {"@@@",{44,44,"MapApply"}},
        {"@*",{43,44,"Composition"}}, {"/*",{43,43,"RightComposition"}}, {"@",{180,180,""}},
        {"//",{30,31,""}}, {".",{145,146,"Dot"}}, {"=",{40,40,"Set"}}, {":=",{40,40,"SetDelayed"}},
        {"^=",{40,40,"UpSet"}}, {"^:=",{40,40,"UpSetDelayed"}}, {"+=",{40,40,"AddTo"}},
        {"-=",{40,40,"SubtractFrom"}}, {"*=",{40,40,"TimesBy"}}, {"/=",{40,40,"DivideBy"}},
        {"//=",{40,40,"ApplyTo"}}, {"|->",{10,10,"Function"}}};
    const auto found = specs.find(text);
    return found == specs.end() ? std::nullopt : std::optional<BinarySpec>(found->second);
}

const std::vector<std::string> comparisons{
    "Equal", "Greater", "GreaterEqual", "Less", "LessEqual", "SameQ", "Unequal", "UnsameQ"};
const std::vector<std::string> flat_heads{
    "Plus", "Times", "Dot", "NonCommutativeMultiply", "Composition", "RightComposition"};

bool is_optional_dot_candidate(const Expr& expr) {
    if (expr.has_head("Blank") && expr.args().empty()) return true;
    return expr.has_head("Pattern") && expr.args().size() == 2
        && expr.args()[0].kind() == ExprKind::Symbol
        && expr.args()[1].has_head("Blank") && expr.args()[1].args().empty();
}

bool is_tag_prefix(const Expr& expr) { return expr.has_head("TagSetPrefix") && expr.args().size() == 2; }

class Parser {
public:
    explicit Parser(const std::string& source) : tokens_(tokenize(source)) {}

    Expr parse() {
        if (peek().kind == TokenKind::Eof) return symbol("Null");
        const auto result = parse_bp(0, {"eof"}).expr;
        expect("eof");
        return result;
    }

private:
    class RecursionGuard {
    public:
        explicit RecursionGuard(std::size_t& depth) : depth_(depth) {
            if (depth_ >= 512)
                syntax("Wolfram expression nesting exceeds the parser safety limit.");
            ++depth_;
        }
        RecursionGuard(const RecursionGuard&) = delete;
        RecursionGuard& operator=(const RecursionGuard&) = delete;
        ~RecursionGuard() { --depth_; }

    private:
        std::size_t& depth_;
    };

    const Token& peek(std::size_t offset = 0) const { return tokens_.at(index_ + offset); }
    Token consume() { return tokens_.at(index_++); }
    bool terminates(const Token& token, const std::unordered_set<std::string>& ends) const {
        return token.kind == TokenKind::Eof || ends.count(token.text) != 0
            || (token.kind == TokenKind::Eof && ends.count("eof") != 0);
    }
    bool matches(const std::string& value) {
        const bool kind = (value == "eof" && peek().kind == TokenKind::Eof)
            || (value == "integer" && peek().kind == TokenKind::Integer)
            || (value == "real" && peek().kind == TokenKind::Real)
            || (value == "string" && peek().kind == TokenKind::String)
            || (value == "symbol" && peek().kind == TokenKind::Symbol);
        if (kind || peek().text == value) { consume(); return true; }
        return false;
    }
    Token expect(const std::string& value) {
        if (matches(value)) return tokens_[index_ - 1];
        syntax("Expected '" + value + "', found '" + peek().text + "' at offset " + std::to_string(peek().start) + ".");
    }

    Parsed parse_bp(int min_bp, const std::unordered_set<std::string>& ends) {
        RecursionGuard recursion(recursion_depth_);
        if (terminates(peek(), ends)) syntax("Unexpected '" + peek().text + "' at offset " + std::to_string(peek().start) + ".");
        auto left = parse_prefix(ends);
        while (!terminates(peek(), ends)) {
            const auto token = peek();
            if (token.text == "_" || token.text == "__" || token.text == "___") {
                if (185 < min_bp) break;
                const bool attached = left.expr.kind() == ExprKind::Symbol && index_ > 0
                    && tokens_[index_ - 1].end == token.start;
                if (attached) left = postfix_pattern(left);
                else {
                    if (140 < min_bp) break;
                    left = flat_call("Times", left, {prefix_blank_at_position()});
                }
                continue;
            }
            if (token.text == ".." || token.text == "...") {
                if (185 < min_bp) break;
                consume();
                if (token.text == "..." && is_optional_dot_candidate(left.expr))
                    left = {call("Repeated", {call("Optional", {left.expr})})};
                else left = {call(token.text == "..." ? "RepeatedNull" : "Repeated", {left.expr})};
                continue;
            }
            if (token.text == "?") {
                if (184 < min_bp) break;
                consume(); left = {call("PatternTest", {left.expr, parse_bp(185, ends).expr})}; continue;
            }
            if (token.text == "." && is_optional_dot_candidate(left.expr) && optional_dot_context(ends)) {
                if (185 < min_bp) break;
                consume(); left = {call("Optional", {left.expr})}; continue;
            }
            if (token.text == "!") {
                if (175 < min_bp) break;
                consume(); const bool twice = matches("!");
                left = {call(twice ? "Factorial2" : "Factorial", {left.expr})}; continue;
            }
            if (token.text == "'") {
                if (175 < min_bp) break;
                std::size_t count = 0; while (matches("'")) ++count;
                left = {call(call("Derivative", {integer(count)}), {left.expr})}; continue;
            }
            if (token.text == "++" || token.text == "--") {
                if (175 < min_bp) break;
                consume(); left = {call(token.text == "++" ? "Increment" : "Decrement", {left.expr})}; continue;
            }
            if (token.text == "=.") { if (175 < min_bp) break; consume(); left = unset(left); continue; }
            if (token.text == "[") {
                if (190 < min_bp) break;
                consume(); auto args = sequence("]"); expect("]"); left = {call(left.expr, std::move(args))}; continue;
            }
            if (token.text == "[[") {
                if (190 < min_bp) break;
                consume(); auto specs = sequence("]"); expect("]"); expect("]");
                std::vector<Expr> args{left.expr}; args.insert(args.end(), specs.begin(), specs.end());
                left = {call("Part", std::move(args))}; continue;
            }
            if (token.text == ";;") {
                if (110 < min_bp) break;
                consume();
                if (left.completed_span && !left.grouped) left = flat_call("Times", left, finish_span(integer(1L), ends));
                else left = finish_span(left.expr, ends);
                continue;
            }
            if (token.text == "&") { if (42 < min_bp) break; consume(); left = {call("Function", {left.expr})}; continue; }
            if (token.text == "~") {
                if (165 < min_bp) break;
                consume(); auto op_ends = ends; op_ends.insert("~");
                const auto op = parse_bp(0, op_ends).expr; expect("~");
                left = {call(op, {left.expr, parse_bp(166, ends).expr})}; continue;
            }
            if (starts_primary(token)) {
                if (140 < min_bp) break;
                left = flat_call("Times", left, parse_bp(141, ends)); continue;
            }
            const auto next = parse_infix(left, min_bp, ends);
            if (!next) break;
            left = *next;
        }
        if (is_tag_prefix(left.expr)) syntax("Expected '=', ':=', or '=.' after '/:'.");
        return left;
    }

    Parsed parse_prefix(const std::unordered_set<std::string>& ends) {
        const auto token = consume();
        if (token.kind == TokenKind::Integer) return {integer(mpz_class(token.value, 10))};
        if (token.kind == TokenKind::Real) return {real(token.value)};
        if (token.kind == TokenKind::String) return {string(token.value)};
        if (token.kind == TokenKind::Symbol) return {symbol(token.value)};
        if (token.kind == TokenKind::Percent) return {token.value.empty()
            ? call("Out") : call("Out", {integer(mpz_class(token.value, 10))})};
        if (token.text == "(") { auto value = parse_bp(0, {")"}); expect(")"); value.grouped = true; return value; }
        if (token.text == "{") { auto values = sequence("}"); expect("}"); return {list(std::move(values))}; }
        if (token.text == "<|") { auto values = sequence("|>"); expect("|>"); return {call("Association", std::move(values))}; }
        if (token.text == "_" || token.text == "__" || token.text == "___") {
            const auto head = token.text == "_" ? "Blank" : token.text == "__" ? "BlankSequence" : "BlankNullSequence";
            return {prefix_blank(head)};
        }
        if (token.text == "#" || token.text == "##") return {prefix_slot(token.text == "##")};
        if (token.text == "?" || token.text == "??") {
            const auto name = file_name("information");
            return {call("Information", {name, call("Rule", {symbol("LongForm"), symbol(token.text == "??" ? "True" : "False")})})};
        }
        if (token.text == "<<") return {call("Get", {file_name("Get")})};
        if (token.text == "++" || token.text == "--")
            return {call(token.text == "++" ? "PreIncrement" : "PreDecrement", {parse_bp(175, ends).expr})};
        if (token.text == "+") { auto result = Parsed{call("Plus", {parse_bp(142, ends).expr})}; result.operator_head = "Plus"; return result; }
        if (token.text == "-") {
            const auto operand = parse_bp(142, ends).expr;
            if (operand.kind() == ExprKind::Integer) return {integer(-operand.integer_value())};
            if (operand.kind() == ExprKind::Real) return {real(operand.text().front() == '-' ? operand.text().substr(1) : "-" + operand.text())};
            return {call("Times", {integer(-1L), operand})};
        }
        if (token.text == "!") return {call("Not", {parse_bp(90, ends).expr})};
        if (token.text == ";;") return finish_span(integer(1L), ends);
        syntax("Unexpected token '" + token.text + "' at offset " + std::to_string(token.start) + ".");
    }

    std::vector<Expr> sequence(const std::string& end) {
        std::vector<Expr> items;
        if (peek().text == end) return items;
        while (true) {
            if (peek().text == "," || peek().text == end) items.push_back(symbol("Null"));
            else items.push_back(parse_bp(0, {",", end}).expr);
            if (!matches(",")) break;
        }
        return items;
    }

    Expr prefix_blank(const std::string& head) {
        const auto& blank = tokens_[index_ - 1];
        if (peek().kind == TokenKind::Symbol && blank.end == peek().start) return call(head, {symbol(consume().value)});
        return call(head);
    }
    Expr prefix_blank_at_position() {
        const auto token = consume();
        const auto head = token.text == "_" ? "Blank" : token.text == "__" ? "BlankSequence" : "BlankNullSequence";
        return prefix_blank(head);
    }
    Expr prefix_slot(bool sequence_slot) {
        const auto head = sequence_slot ? "SlotSequence" : "Slot";
        if (peek().kind == TokenKind::Integer) return call(head, {integer(mpz_class(consume().value, 10))});
        if (peek().kind == TokenKind::Real && peek().text.size() > 1 && peek().text.back() == '.'
            && consists_of_decimal_digits(std::string_view(
                peek().text.data(), peek().text.size() - 1))) {
            const auto digits = peek().text.substr(0, peek().text.size() - 1);
            auto& token = tokens_[index_];
            token.kind = TokenKind::Operator;
            token.text = ".";
            token.value = ".";
            token.start = token.end - 1;
            return call(head, {integer(mpz_class(normalized_decimal_digits(
                digits, 0, digits.size(),
                "Malformed Wolfram slot index."), 10))});
        }
        if (!sequence_slot && (peek().kind == TokenKind::Symbol || peek().kind == TokenKind::String)
            && tokens_[index_ - 1].end == peek().start) return call(head, {string(consume().value)});
        return call(head, {integer(1L)});
    }
    Parsed postfix_pattern(Parsed left) {
        const auto token = consume();
        const auto name = *left.expr.symbol_name();
        const auto head = token.text == "_" ? "Blank" : token.text == "__" ? "BlankSequence" : "BlankNullSequence";
        return {call("Pattern", {symbol(name), prefix_blank(head)})};
    }
    bool optional_dot_context(const std::unordered_set<std::string>& ends) const {
        const auto& next = peek(1);
        static const std::vector<std::string> operators{",","]","}","|>",")",";","+","-","*","/","**","^","&&","||","|","~~","/;","->",":>","<->","/.","//.","/@","//@","@@","@@@","==","!=","===","=!=" ,"<","<=",">",">=","=",":="};
        return terminates(next, ends) || contains(operators, next.text)
            || (peek().end < next.start && starts_primary(next));
    }
    Expr span_argument(Expr fallback, const std::unordered_set<std::string>& ends) {
        if (terminates(peek(), ends) || peek().text == "," || peek().text == "]" || peek().text == "}"
            || peek().text == "|>" || peek().text == ";;" || peek().text == ";") return fallback;
        return parse_bp(111, ends).expr;
    }
    Parsed finish_span(Expr start, const std::unordered_set<std::string>& ends) {
        std::vector<Expr> args{start, span_argument(symbol("All"), ends)};
        if (peek().text == ";;" && can_start_expression(peek(1))) {
            consume(); args.push_back(span_argument(integer(1L), ends));
        }
        Parsed result{call("Span", std::move(args))}; result.completed_span = true; return result;
    }
    Expr file_name(const std::string& context) {
        if (peek().kind == TokenKind::Filename || peek().kind == TokenKind::Symbol || peek().kind == TokenKind::String)
            return string(consume().value);
        syntax("Expected " + context + " name at offset " + std::to_string(peek().start) + ".");
    }

    std::optional<Parsed> parse_infix(Parsed left, int min_bp, const std::unordered_set<std::string>& ends) {
        const auto token = peek();
        if (token.text == "::") {
            if (183 < min_bp) return std::nullopt;
            consume();
            if (peek().kind != TokenKind::Symbol && peek().kind != TokenKind::String)
                syntax("Expected message tag at offset " + std::to_string(peek().start) + ".");
            const auto tag = string(consume().value);
            if (left.expr.has_head("MessageName")) {
                auto args = left.expr.args(); args.push_back(tag); return Parsed{call("MessageName", std::move(args))};
            }
            return Parsed{call("MessageName", {left.expr, tag})};
        }
        if (token.text == ">>" || token.text == ">>>") {
            if (35 < min_bp) return std::nullopt;
            consume(); return Parsed{call(token.text == ">>" ? "Put" : "PutAppend", {left.expr, file_name("Put")})};
        }
        if (token.text == "/:") {
            if (40 < min_bp) return std::nullopt;
            consume(); auto tagged_ends = ends; tagged_ends.insert("=.");
            return Parsed{call("TagSetPrefix", {left.expr, parse_bp(41, tagged_ends).expr})};
        }
        if (token.text == ";") {
            if (20 < min_bp) return std::nullopt;
            consume(); const auto right = terminates(peek(), ends) || !can_start_expression(peek())
                ? Parsed{symbol("Null")} : parse_bp(21, ends);
            return compound(left, right);
        }
        if (token.text == "=" && peek(1).text == ".") {
            if (40 < min_bp) return std::nullopt;
            consume(); consume(); return unset(left);
        }
        auto spec = binary_spec(token.text);
        const auto named = named_operator_head(token.text);
        if (!spec && named) {
            const int bp = *named == "CirclePlus" ? 125 : *named == "CircleTimes" ? 142 : *named == "Diamond" ? 144 : 100;
            spec = BinarySpec{bp, bp + 1, *named};
        }
        if (!spec || spec->left < min_bp) return std::nullopt;
        consume();
        auto right = parse_bp(spec->right, ends);
        if (token.text == "/") return division(left, right);
        if (token.text == "-") return flat_call("Plus", left, {negate(right.expr)});
        if (token.text == ":") return left.expr.kind() == ExprKind::Symbol
            ? Parsed{call("Pattern", {left.expr, right.expr}), false, "Colon"}
            : Parsed{call("Optional", {left.expr, right.expr}), false, "Colon"};
        if (token.text == "@") return Parsed{call(left.expr, {right.expr})};
        if (token.text == "//") return Parsed{call(right.expr, {left.expr})};
        const auto head = spec->head;
        if ((head == "Set" || head == "SetDelayed") && is_tag_prefix(left.expr)) {
            return Parsed{call(head == "Set" ? "TagSet" : "TagSetDelayed",
                {left.expr.args()[0], left.expr.args()[1], right.expr})};
        }
        if (contains(comparisons, head)) return comparison(head, left, right);
        if (contains(flat_heads, head) || named) return flat_call(head, left, right);
        return Parsed{call(head, {left.expr, right.expr}), false, head};
    }

    Parsed flat_call(const std::string& head, Parsed left, Parsed right) const {
        std::vector<Expr> args;
        append_flat(args, left, head); append_flat(args, right, head);
        return {call(head, std::move(args)), false, head};
    }
    static void append_flat(std::vector<Expr>& args, const Parsed& parsed, const std::string& head) {
        if (parsed.operator_head == head && !parsed.grouped && parsed.expr.kind() == ExprKind::Call)
            args.insert(args.end(), parsed.expr.args().begin(), parsed.expr.args().end());
        else args.push_back(parsed.expr);
    }
    Parsed division(Parsed left, Parsed right) const {
        const auto reciprocal = call("Power", {right.expr, integer(-1L)});
        if (left.operator_head == "Times" && !left.grouped && !left.expr.args().empty()) {
            auto args = left.expr.args();
            args.back() = call("Times", {args.back(), reciprocal});
            return {call("Times", std::move(args)), false, "Times"};
        }
        return {call("Times", {left.expr, reciprocal})};
    }
    Parsed comparison(const std::string& head, Parsed left, Parsed right) const {
        if (right.operator_head == head && !right.grouped) {
            std::vector<Expr> args{left.expr}; args.insert(args.end(), right.expr.args().begin(), right.expr.args().end());
            return {call(head, std::move(args)), false, head};
        }
        if (contains(comparisons, right.operator_head) && !right.grouped) {
            std::vector<Expr> args{left.expr, symbol(head), right.expr.args()[0]};
            for (std::size_t i = 1; i < right.expr.args().size(); ++i) {
                args.push_back(symbol(right.operator_head)); args.push_back(right.expr.args()[i]);
            }
            return {call("Inequality", std::move(args)), false, "Inequality"};
        }
        if (right.operator_head == "Inequality" && !right.grouped) {
            std::vector<Expr> args{left.expr, symbol(head)}; args.insert(args.end(), right.expr.args().begin(), right.expr.args().end());
            return {call("Inequality", std::move(args)), false, "Inequality"};
        }
        return {call(head, {left.expr, right.expr}), false, head};
    }
    Parsed compound(Parsed left, Parsed right) const {
        std::vector<Expr> args; append_flat(args, left, "CompoundExpression"); append_flat(args, right, "CompoundExpression");
        return {call("CompoundExpression", std::move(args)), false, "CompoundExpression"};
    }
    static Expr negate(const Expr& value) {
        if (value.kind() == ExprKind::Integer && value.integer_value() >= 0) return integer(-value.integer_value());
        if (value.kind() == ExprKind::Real && (value.text().empty() || value.text().front() != '-')) return real("-" + value.text());
        return call("Times", {integer(-1L), value});
    }
    static Parsed unset(Parsed left) {
        if (is_tag_prefix(left.expr)) return {call("TagUnset", {left.expr.args()[0], left.expr.args()[1]})};
        return {call("Unset", {left.expr})};
    }

    std::vector<Token> tokens_;
    std::size_t index_ = 0;
    std::size_t recursion_depth_ = 0;
};

std::string trim(std::string value) {
    const auto begin = value.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) return {};
    const auto end = value.find_last_not_of(" \t\r\n");
    return value.substr(begin, end - begin + 1);
}

Expr interpret_standard_form_impl(Expr expression);

std::string normalize_box_token(const std::string& value) {
    if (value == " " || value == "\t" || value == "\n" || value == R"(\[InvisibleSpace])"
        || value == R"(\[InvisibleTimes])" || value == R"(\[ThinSpace])") return " ";
    if (value.size() >= 4 && value.compare(0, 2, R"(\[)") == 0 && value.back() == ']') {
        const auto name = value.substr(2, value.size() - 3);
        if (const auto token = escaped_token(name)) return *token;
    }
    return value;
}

bool needs_box_separator(const std::string& left, const std::string& right) {
    if (trim(left).empty() || trim(right).empty()) return false;
    const auto left_last = left.back();
    const auto right_first = right.front();
    return std::string("[({<,.;+-*/^!@&|=_:").find(left_last) == std::string::npos
        && std::string("])}>,.;+-*/^!@&|=_:").find(right_first) == std::string::npos;
}

std::string box_item_text(const Expr& expression);

std::string row_box_text(const std::vector<Expr>& args) {
    if (args.size() != 1 || !args[0].has_head("List")) return call("RowBox", args).to_input_form();
    std::string output;
    std::string previous;
    for (const auto& item : args[0].args()) {
        const auto piece = box_item_text(item);
        if (piece.empty()) continue;
        if (!output.empty() && needs_box_separator(previous, piece)) output.push_back(' ');
        output += piece;
        previous = piece;
    }
    return output;
}

std::string box_item_text(const Expr& expression) {
    if (expression.kind() == ExprKind::String) return normalize_box_token(expression.text());
    if (expression.has_head("RowBox")) return row_box_text(expression.args());
    if (expression.has_head("FractionBox") && expression.args().size() >= 2) {
        return "((" + box_item_text(expression.args()[0]) + ")/("
            + box_item_text(expression.args()[1]) + "))";
    }
    return interpret_standard_form_impl(expression).to_input_form();
}

Expr coerce_box_operand(Expr expression) {
    if (expression.kind() == ExprKind::String) {
        try { return parse_input_form(trim(expression.text())); }
        catch (const ParseError&) { return expression; }
    }
    return expression;
}

Expr make_division(Expr numerator, Expr denominator) {
    if (numerator.kind() == ExprKind::Integer && denominator.kind() == ExprKind::Integer)
        return call("Rational", {numerator, denominator});
    if (numerator.kind() == ExprKind::Integer && numerator.integer_value() == 1)
        return call("Power", {denominator, integer(-1L)});
    return call("Times", {numerator, call("Power", {denominator, integer(-1L)})});
}

Expr interpret_standard_form_impl(Expr expression) {
    if (expression.kind() != ExprKind::Call) return expression;
    const auto head = expression.head();
    const auto args = expression.args();
    const auto* raw_name = head.symbol_name();
    const auto name = raw_name ? system_dispatch_name(*raw_name) : std::string{};
    if (name == "InterpretationBox" && args.size() >= 2) return interpret_standard_form_impl(args[1]);
    static const std::vector<std::string> wrappers{
        "AdjustmentBox", "BoxData", "FormBox", "FrameBox", "PaneBox", "StyleBox", "TagBox", "TooltipBox"};
    if (contains(wrappers, name) && !args.empty()) return interpret_standard_form_impl(args[0]);
    if (name == "RowBox" && args.size() == 1 && args[0].has_head("List")) {
        const auto text = trim(row_box_text(args));
        return text.empty() ? string("") : parse_standard_form(text);
    }
    if (name == "FractionBox" && args.size() >= 2) {
        return make_division(coerce_box_operand(interpret_standard_form_impl(args[0])),
            coerce_box_operand(interpret_standard_form_impl(args[1])));
    }
    if (name == "SqrtBox" && !args.empty()) return call("Power", {
        coerce_box_operand(interpret_standard_form_impl(args[0])),
        call("Rational", {integer(1L), integer(2L)})});
    if (name == "RadicalBox" && args.size() >= 2) return call("Power", {
        coerce_box_operand(interpret_standard_form_impl(args[0])),
        make_division(integer(1L), coerce_box_operand(interpret_standard_form_impl(args[1])))});
    if (name == "SuperscriptBox" && args.size() >= 2) return call("Power", {
        coerce_box_operand(interpret_standard_form_impl(args[0])),
        coerce_box_operand(interpret_standard_form_impl(args[1]))});
    if ((name == "SubscriptBox" || name == "OverscriptBox" || name == "UnderscriptBox")
        && args.size() >= 2) {
        const auto target = name.substr(0, name.size() - 3);
        return call(target, {coerce_box_operand(interpret_standard_form_impl(args[0])),
            coerce_box_operand(interpret_standard_form_impl(args[1]))});
    }
    if ((name == "SubsuperscriptBox" || name == "UnderoverscriptBox") && args.size() >= 3) {
        const auto target = name.substr(0, name.size() - 3);
        return call(target, {coerce_box_operand(interpret_standard_form_impl(args[0])),
            coerce_box_operand(interpret_standard_form_impl(args[1])),
            coerce_box_operand(interpret_standard_form_impl(args[2]))});
    }
    std::vector<Expr> mapped;
    mapped.reserve(args.size());
    for (const auto& argument : args) mapped.push_back(interpret_standard_form_impl(argument));
    return call(interpret_standard_form_impl(head), std::move(mapped));
}

} // namespace

Expr parse_expression(const std::string& text, ParseForm form) {
    auto expression = Parser(text).parse();
    return form == ParseForm::Standard
        ? interpret_standard_form_impl(std::move(expression)) : expression;
}
Expr parse_input_form(const std::string& text) { return parse_expression(text, ParseForm::Input); }
Expr parse_full_form(const std::string& text) { return parse_expression(text, ParseForm::Full); }
Expr parse_standard_form(const std::string& text) { return parse_expression(text, ParseForm::Standard); }
Expr interpret_standard_form(const Expr& expression) {
    return interpret_standard_form_impl(expression);
}
std::string box_item_to_standard_text(const Expr& expression) {
    return box_item_text(expression);
}

} // namespace tungsten
