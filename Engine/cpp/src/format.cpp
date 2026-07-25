#include "tungsten/detail/format.hpp"

#include "tungsten/expression.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <optional>
#include <sstream>
#include <unordered_map>

namespace tungsten::detail {
namespace {

constexpr std::uint16_t prec_atom = 1000;
constexpr std::uint16_t prec_call = 190;
constexpr std::uint16_t prec_part = 190;
constexpr std::uint16_t prec_pattern = 185;
constexpr std::uint16_t prec_pattern_test = 184;
constexpr std::uint16_t prec_message_name = 183;
constexpr std::uint16_t prec_postfix_unary = 175;
constexpr std::uint16_t prec_power = 160;
constexpr std::uint16_t prec_prefix = 150;
constexpr std::uint16_t prec_noncommutative_times = 145;
constexpr std::uint16_t prec_times = 140;
constexpr std::uint16_t prec_plus = 120;
constexpr std::uint16_t prec_compare = 100;
constexpr std::uint16_t prec_and = 80;
constexpr std::uint16_t prec_or = 70;
constexpr std::uint16_t prec_alternatives = 65;
constexpr std::uint16_t prec_string_expression = 64;
constexpr std::uint16_t prec_named_pattern = 63;
constexpr std::uint16_t prec_condition = 62;
constexpr std::uint16_t prec_rule = 60;
constexpr std::uint16_t prec_two_way_rule = 61;
constexpr std::uint16_t prec_replace = 50;
constexpr std::uint16_t prec_map = 45;
constexpr std::uint16_t prec_apply = 44;
constexpr std::uint16_t prec_composition = 43;
constexpr std::uint16_t prec_assignment = 40;
constexpr std::uint16_t prec_put = 35;
constexpr std::uint16_t prec_postfix = 30;
constexpr std::uint16_t prec_function = 10;
// Linear-syntax sugar repeats one byte per derivative/history order.  Preserve
// ordinary Wolfram shorthand while avoiding attacker-controlled allocations
// for arbitrary-width integer expressions.
constexpr unsigned long max_repeated_shorthand = 4096;

struct Formatted {
    std::string text;
    std::uint16_t precedence;
};

std::optional<std::string> format_derivative(const Expr& head, const std::vector<Expr>& args);

std::string join(const std::vector<std::string>& values, const std::string& separator) {
    std::ostringstream output;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) output << separator;
        output << values[index];
    }
    return output.str();
}

bool is_integer(const Expr& expression, long value) {
    return expression.kind() == ExprKind::Integer && expression.integer_value() == value;
}

bool is_simple_file_name(const std::string& value) {
    if (value.empty()) return false;
    return std::all_of(value.begin(), value.end(), [](char character) {
        return (character >= 'a' && character <= 'z')
            || (character >= 'A' && character <= 'Z')
            || (character >= '0' && character <= '9')
            || character == '$' || character == '_' || character == '.'
            || character == '/' || character == '\\' || character == '-';
    });
}

std::optional<std::string> format_information(const std::vector<Expr>& args) {
    if (args.size() != 2 || args[0].kind() != ExprKind::String
        || !args[1].has_head("Rule") || args[1].args().size() != 2) {
        return std::nullopt;
    }
    const auto& option = args[1].args();
    const auto* option_name = option[0].symbol_name();
    const auto* option_value = option[1].symbol_name();
    if (!option_name || *option_name != "LongForm" || !option_value)
        return std::nullopt;
    const auto prefix = *option_value == "False" ? "?"
        : *option_value == "True" ? "??" : nullptr;
    if (!prefix) return std::nullopt;
    const auto name = is_simple_file_name(args[0].text())
        ? args[0].text() : format_input(args[0], 0);
    return std::string(prefix) + name;
}

std::optional<std::string> format_blank(const std::string& name, const std::vector<Expr>& args) {
    std::string prefix;
    if (name == "Blank") prefix = "_";
    else if (name == "BlankSequence") prefix = "__";
    else if (name == "BlankNullSequence") prefix = "___";
    else return std::nullopt;
    if (args.empty()) return prefix;
    if (args.size() == 1 && args[0].symbol_name() != nullptr) return prefix + *args[0].symbol_name();
    return std::nullopt;
}

std::string generic_call(const Expr& head, const std::vector<Expr>& args) {
    std::vector<std::string> values;
    for (const auto& argument : args) values.push_back(format_input(argument, 0));
    const auto formatted_head = head.kind() == ExprKind::Call
        && format_derivative(head.head(), head.args()).has_value()
        ? format_input(head, 0) : format_input(head, prec_call);
    return formatted_head + "[" + join(values, ", ") + "]";
}

struct InfixSpec {
    const char* op;
    std::uint16_t precedence;
    bool right_associative;
    bool spaced;
};

std::optional<InfixSpec> infix_spec(const std::string& name) {
    static const std::unordered_map<std::string, InfixSpec> specs{
        {"Equal", {"==", prec_compare, true, true}},
        {"Unequal", {"!=", prec_compare, true, true}},
        {"SameQ", {"===", prec_compare, true, true}},
        {"UnsameQ", {"=!=" , prec_compare, true, true}},
        {"Less", {"<", prec_compare, true, true}},
        {"LessEqual", {"<=", prec_compare, true, true}},
        {"Greater", {">", prec_compare, true, true}},
        {"GreaterEqual", {">=", prec_compare, true, true}},
        {"And", {"&&", prec_and, false, true}},
        {"Or", {"||", prec_or, false, true}},
        {"Alternatives", {"|", prec_alternatives, false, true}},
        {"StringExpression", {"~~", prec_string_expression, false, false}},
        {"TwoWayRule", {"<->", prec_two_way_rule, true, true}},
        {"Rule", {"->", prec_rule, true, true}},
        {"RuleDelayed", {":>", prec_rule, true, true}},
        {"ReplaceAll", {"/.", prec_replace, false, true}},
        {"ReplaceRepeated", {"//.", prec_replace, false, true}},
        {"Map", {"/@", prec_map, false, true}},
        {"MapAll", {"//@", prec_map, false, true}},
        {"Apply", {"@@", prec_apply, false, true}},
        {"MapApply", {"@@@", prec_apply, false, true}},
        {"Composition", {"@*", prec_composition, true, true}},
        {"RightComposition", {"/*", prec_composition, true, true}},
        {"Set", {"=", prec_assignment, true, true}},
        {"SetDelayed", {":=", prec_assignment, true, true}},
        {"UpSet", {"^=", prec_assignment, true, true}},
        {"UpSetDelayed", {"^:=", prec_assignment, true, true}},
        {"AddTo", {"+=", prec_assignment, true, true}},
        {"SubtractFrom", {"-=", prec_assignment, true, true}},
        {"TimesBy", {"*=", prec_assignment, true, true}},
        {"DivideBy", {"/=", prec_assignment, true, true}},
        {"NonCommutativeMultiply", {"**", prec_noncommutative_times, false, true}},
        {"Dot", {".", prec_times, false, true}},
        {"StringJoin", {"<>", prec_plus, false, true}},
    };
    const auto found = specs.find(name);
    return found == specs.end() ? std::nullopt : std::optional<InfixSpec>(found->second);
}

std::string format_infix(const std::vector<Expr>& args, const InfixSpec& spec) {
    const std::string separator = spec.spaced ? " " + std::string(spec.op) + " " : spec.op;
    std::vector<std::string> values;
    const auto last = args.size() - 1;
    for (std::size_t index = 0; index < args.size(); ++index) {
        auto operand_precedence = spec.right_associative
            ? (index == 0 ? spec.precedence + 1 : spec.precedence)
            : (index == 0 ? spec.precedence : spec.precedence + 1);
        if (index > 0 && index < last) operand_precedence = spec.precedence + 1;
        values.push_back(format_input(args[index], operand_precedence));
    }
    return join(values, separator);
}

std::optional<Expr> strip_negative_term(const Expr& expression) {
    if (!expression.has_head("Times") || expression.args().empty() || !is_integer(expression.args()[0], -1)) {
        return std::nullopt;
    }
    if (expression.args().size() == 2) return expression.args()[1];
    return call("Times", std::vector<Expr>(expression.args().begin() + 1, expression.args().end()));
}

std::string format_plus(const std::vector<Expr>& args) {
    std::vector<std::string> pieces;
    for (std::size_t index = 0; index < args.size(); ++index) {
        if (const auto stripped = strip_negative_term(args[index])) {
            const auto value = format_input(*stripped, index == 0 ? prec_prefix : prec_plus + 1);
            pieces.push_back(index == 0 ? "-" + value : "- " + value);
        } else if (index == 0) {
            pieces.push_back(format_input(args[index], prec_plus));
        } else {
            pieces.push_back("+ " + format_input(args[index], prec_plus + 1));
        }
    }
    return join(pieces, " ");
}

std::optional<Expr> inverse_denominator(const Expr& expression) {
    if (expression.has_head("Power") && expression.args().size() == 2
        && is_integer(expression.args()[1], -1)) {
        return expression.args()[0];
    }
    return std::nullopt;
}

std::string format_times(const std::vector<Expr>& args) {
    if (args.size() == 2) {
        if (const auto denominator = inverse_denominator(args[1])) {
            return format_input(args[0], prec_times) + " / " + format_input(*denominator, prec_times + 1);
        }
    }
    if (!args.empty() && is_integer(args.front(), -1)) {
        const auto stripped = args.size() == 2
            ? args[1]
            : call("Times", std::vector<Expr>(args.begin() + 1, args.end()));
        return "-" + format_input(stripped, prec_prefix);
    }
    std::vector<std::string> values;
    for (std::size_t index = 0; index < args.size(); ++index) {
        values.push_back(format_input(args[index], prec_times + (index == 0 ? 0 : 1)));
    }
    return join(values, " * ");
}

std::string format_span(const std::vector<Expr>& args) {
    if (args.size() == 2) {
        if (is_integer(args[0], 1) && args[1].symbol_name() && *args[1].symbol_name() == "All") return ";;";
        if (is_integer(args[0], 1)) return ";; " + format_input(args[1], 0);
        if (args[1].symbol_name() && *args[1].symbol_name() == "All") return format_input(args[0], 0) + " ;;";
        return format_input(args[0], 0) + " ;; " + format_input(args[1], 0);
    }
    if (args.size() == 3) {
        return format_input(args[0], 0) + " ;; " + format_input(args[1], 0) + " ;; " + format_input(args[2], 0);
    }
    return generic_call(symbol("Span"), args);
}

std::string format_imaginary(const Expr& value) {
    if (is_integer(value, 1)) return "I";
    if (is_integer(value, -1)) return "-I";
    return format_input(value, prec_times) + " I";
}

std::optional<std::string> format_derivative(const Expr& head, const std::vector<Expr>& args) {
    if (args.size() != 1 || head.kind() != ExprKind::Call) return std::nullopt;
    const auto derivative = head.head();
    const auto& orders = head.args();
    const auto* derivative_name = derivative.symbol_name();
    if ((!derivative_name || system_dispatch_name(*derivative_name) != "Derivative")
        && !derivative.has_head("Derivative")) return std::nullopt;
    if (orders.size() != 1 || orders[0].kind() != ExprKind::Integer
        || orders[0].integer_value() <= 0 || !orders[0].integer_value().fits_ulong_p()) return std::nullopt;
    if (orders[0].integer_value().get_ui() > max_repeated_shorthand)
        return std::nullopt;
    return format_input(args[0], prec_postfix_unary)
        + std::string(orders[0].integer_value().get_ui(), '\'');
}

std::optional<std::pair<std::string, std::uint16_t>> escaped_infix_spec(const std::string& name) {
    static const std::vector<std::string> names{
        "CenterDot", "CircleDot", "CircleMinus", "CirclePlus", "CircleTimes", "Congruent",
        "Cross", "Diamond", "DirectedEdge", "DiscreteRatio", "DiscreteShift", "DoubleLeftArrow",
        "DoubleLeftRightArrow", "DoubleRightArrow", "DoubleVerticalBar", "DownArrow", "Element",
        "Equivalent", "Implies", "Intersection", "LessEqualGreater", "LongLeftArrow",
        "LongLeftRightArrow", "LongRightArrow", "MinusPlus", "NotElement", "NotSubset",
        "NotSubsetEqual", "NotSuperset", "NotSupersetEqual", "PlusMinus", "Precedes",
        "PrecedesEqual", "Proportion", "RightArrow", "SmallCircle", "SquareIntersection",
        "SquareSubset", "SquareSubsetEqual", "SquareSuperset", "SquareSupersetEqual", "SquareUnion",
        "Star", "Subset", "SubsetEqual", "Succeeds", "SucceedsEqual", "Superset", "SupersetEqual",
        "TensorProduct", "Tilde", "TildeEqual", "TildeFullEqual", "TildeTilde", "UndirectedEdge",
        "Union", "UpArrow", "Vee", "VerticalBar", "VerticalSeparator", "Wedge"};
    if (std::find(names.begin(), names.end(), name) == names.end()) return std::nullopt;
    const auto precedence = name == "CirclePlus" ? std::uint16_t{125}
        : name == "CircleTimes" ? std::uint16_t{142}
        : name == "Diamond" ? std::uint16_t{144} : prec_compare;
    return std::pair<std::string, std::uint16_t>{"\\[" + name + "]", precedence};
}

Formatted format_call(const Expr& head, const std::vector<Expr>& args) {
    if (const auto derivative = format_derivative(head, args)) {
        return {*derivative, prec_postfix_unary};
    }
    if (const auto* raw_name = head.symbol_name()) {
        const auto name = system_dispatch_name(*raw_name);
        if (name == "List") {
            std::vector<std::string> values; for (const auto& arg : args) values.push_back(format_input(arg, 0));
            return {"{" + join(values, ", ") + "}", prec_atom};
        }
        if (name == "Association") {
            std::vector<std::string> values; for (const auto& arg : args) values.push_back(format_input(arg, 0));
            return {"<|" + join(values, ", ") + "|>", prec_atom};
        }
        if (const auto blank = format_blank(name, args)) return {*blank, prec_atom};
        if (name == "Slot") {
            if (args.empty() || (args.size() == 1 && is_integer(args[0], 1))) return {"#", prec_atom};
            if (args.size() == 1 && args[0].kind() == ExprKind::Integer) return {"#" + args[0].integer_value().get_str(), prec_atom};
            if (args.size() == 1 && args[0].kind() == ExprKind::String) return {"#" + args[0].text(), prec_atom};
        }
        if (name == "SlotSequence") {
            if (args.empty() || (args.size() == 1 && is_integer(args[0], 1))) return {"##", prec_atom};
            if (args.size() == 1 && args[0].kind() == ExprKind::Integer) return {"##" + args[0].integer_value().get_str(), prec_atom};
        }
        if (name == "Out") {
            if (args.empty()) return {"%", prec_atom};
            if (args.size() == 1 && args[0].kind() == ExprKind::Integer && args[0].integer_value() < 0) {
                const mpz_class magnitude = -args[0].integer_value();
                if (!magnitude.fits_ulong_p()
                    || magnitude.get_ui() > max_repeated_shorthand) {
                    return {generic_call(head, args), prec_call};
                }
                const auto count = magnitude.get_ui();
                return {std::string(count, '%'), prec_atom};
            }
        }
        if (name == "Pattern" && args.size() == 2 && args[0].symbol_name()) {
            if (args[1].kind() == ExprKind::Call && args[1].head().symbol_name()) {
                if (const auto blank = format_blank(system_dispatch_name(*args[1].head().symbol_name()), args[1].args())) {
                    return {*args[0].symbol_name() + *blank, prec_pattern};
                }
            }
            return {*args[0].symbol_name() + " : " + format_input(args[1], prec_named_pattern), prec_pattern};
        }
        if (name == "PatternTest" && args.size() == 2)
            return {format_input(args[0], prec_pattern_test) + "?" + format_input(args[1], prec_pattern_test + 1), prec_pattern_test};
        if (name == "Optional" && args.size() == 1) return {format_input(args[0], prec_pattern) + ".", prec_pattern};
        if (name == "Optional" && args.size() == 2)
            return {format_input(args[0], prec_named_pattern) + ":" + format_input(args[1], prec_named_pattern), prec_named_pattern};
        if (name == "Repeated" && args.size() == 1) return {format_input(args[0], prec_postfix) + "..", prec_postfix};
        if (name == "RepeatedNull" && args.size() == 1) return {format_input(args[0], prec_postfix) + "...", prec_postfix};
        if (name == "Condition" && args.size() == 2)
            return {format_input(args[0], prec_condition) + " /; " + format_input(args[1], prec_condition + 1), prec_condition};
        if (name == "Function" && args.size() == 1) return {format_input(args[0], prec_function + 1) + " &", prec_function};
        if (name == "Function" && args.size() == 2)
            return {format_input(args[0], prec_function + 1) + " |-> " + format_input(args[1], prec_function), prec_function};
        if (name == "Information") {
            if (const auto information = format_information(args))
                return {*information, prec_prefix};
        }
        if (name == "MessageName" && args.size() >= 2) {
            auto output = format_input(args[0], prec_message_name);
            for (std::size_t index = 1; index < args.size(); ++index) {
                if (args[index].kind() != ExprKind::String && args[index].kind() != ExprKind::Symbol)
                    return {generic_call(head, args), prec_call};
                output += "::" + args[index].text();
            }
            return {output, prec_message_name};
        }
        if (name == "Get" && args.size() == 1 && args[0].kind() == ExprKind::String)
            return {"<< " + args[0].text(), prec_prefix};
        if ((name == "Put" || name == "PutAppend") && args.size() == 2
            && args[1].kind() == ExprKind::String) {
            return {format_input(args[0], prec_put) + (name == "Put" ? " >> " : " >>> ")
                + args[1].text(), prec_put};
        }
        if ((name == "TagSet" || name == "TagSetDelayed") && args.size() == 3) {
            return {format_input(args[0], prec_assignment + 1) + " /: "
                + format_input(args[1], prec_assignment + 1)
                + (name == "TagSet" ? " = " : " := ") + format_input(args[2], prec_assignment),
                prec_assignment};
        }
        if (name == "TagUnset" && args.size() == 2) {
            return {format_input(args[0], prec_assignment + 1) + " /: "
                + format_input(args[1], prec_assignment + 1) + " =.", prec_assignment};
        }
        if ((name == "Increment" || name == "Decrement" || name == "Factorial" || name == "Factorial2" || name == "Unset") && args.size() == 1) {
            const auto op = name == "Increment" ? "++" : name == "Decrement" ? "--" : name == "Factorial" ? "!" : name == "Factorial2" ? "!!" : " =.";
            return {format_input(args[0], prec_postfix_unary) + op, prec_postfix_unary};
        }
        if ((name == "PreIncrement" || name == "PreDecrement") && args.size() == 1)
            return {(name == "PreIncrement" ? "++" : "--") + format_input(args[0], prec_postfix_unary), prec_postfix_unary};
        if (name == "Plus" && !args.empty()) return {format_plus(args), prec_plus};
        if (name == "Times" && !args.empty()) return {format_times(args), prec_times};
        if (name == "Power" && args.size() == 2) {
            const auto exponent = args[1].kind() == ExprKind::Integer && args[1].integer_value() < 0
                ? "(" + format_input(args[1], 0) + ")" : format_input(args[1], prec_power);
            return {format_input(args[0], prec_power + 1) + "^" + exponent, prec_power};
        }
        if (name == "Not" && args.size() == 1) return {"!" + format_input(args[0], prec_prefix), prec_prefix};
        if (name == "Span") return {format_span(args), prec_function};
        if (name == "Part" && !args.empty()) {
            std::vector<std::string> specs;
            for (std::size_t index = 1; index < args.size(); ++index) specs.push_back(format_input(args[index], 0));
            return {format_input(args[0], prec_part) + "[[" + join(specs, ", ") + "]]", prec_part};
        }
        if (const auto spec = infix_spec(name); spec && args.size() >= 2)
            return {format_infix(args, *spec), spec->precedence};
        if (const auto spec = escaped_infix_spec(name); spec && args.size() >= 2) {
            std::vector<std::string> values;
            for (const auto& argument : args) values.push_back(format_input(argument, spec->second + 1));
            return {join(values, " " + spec->first + " "), spec->second};
        }
    }
    return {generic_call(head, args), prec_call};
}

Formatted format_expression(const Expr& expression) {
    switch (expression.kind()) {
    case ExprKind::Symbol: return {expression.text(), prec_atom};
    case ExprKind::Integer: return {expression.integer_value().get_str(), prec_atom};
    case ExprKind::Real: return {expression.text(), prec_atom};
    case ExprKind::Rational:
        return {expression.rational_value().get_num().get_str() + "/" + expression.rational_value().get_den().get_str(), prec_times};
    case ExprKind::Complex: {
        const auto real_part = expression.real_part();
        const auto imaginary_part = expression.imaginary_part();
        if (is_integer(real_part, 0)) return {format_imaginary(imaginary_part), prec_plus};
        if ((imaginary_part.kind() == ExprKind::Integer && imaginary_part.integer_value() < 0)
            || (imaginary_part.kind() == ExprKind::Rational && imaginary_part.rational_value() < 0)) {
            const auto positive = imaginary_part.kind() == ExprKind::Integer
                ? integer(-imaginary_part.integer_value())
                : rational(-imaginary_part.rational_value().get_num(), imaginary_part.rational_value().get_den());
            return {format_input(real_part, prec_plus) + " - " + format_imaginary(positive), prec_plus};
        }
        return {format_input(real_part, prec_plus) + " + " + format_imaginary(imaginary_part), prec_plus};
    }
    case ExprKind::String: return {wl_string(expression.text()), prec_atom};
    case ExprKind::SpecialReal: return {expression.text() + "[]", prec_atom};
    case ExprKind::ByteArray:
    case ExprKind::SparseArray:
    case ExprKind::Root: return {expression.to_full_form(), prec_call};
    case ExprKind::Call: return format_call(expression.head(), expression.args());
    }
    return {expression.to_full_form(), prec_atom};
}

} // namespace

std::string format_input(const Expr& expression, std::uint16_t parent_precedence) {
    auto formatted = format_expression(expression);
    if (formatted.precedence < parent_precedence) return "(" + formatted.text + ")";
    return formatted.text;
}

} // namespace tungsten::detail
