#include "tungsten/repl.hpp"
#include "tungsten/detail/ascii.hpp"

#include "tungsten/detail/numeric.hpp"
#include "tungsten/parser.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <stdexcept>
#include <system_error>

namespace tungsten {
namespace {

const std::set<std::string>& display_form_heads() {
    static const std::set<std::string> names{
        "AccountingForm", "BaseForm", "CForm", "DecimalForm", "DisplayForm",
        "EngineeringForm", "FortranForm", "FullForm", "InputForm", "MathMLForm",
        "MatrixForm", "NumberForm", "OutputForm", "PaddedForm", "PercentForm",
        "PrintForm", "ScientificForm", "SequenceForm", "StandardForm", "StringForm",
        "TableForm", "TextForm", "TeXForm", "TraditionalForm", "TreeForm",
    };
    return names;
}

const std::set<std::string>& value_stripping_display_form_heads() {
    static const std::set<std::string> names{
        "CForm", "FortranForm", "FullForm", "InputForm", "MathMLForm", "OutputForm",
        "PrintForm", "SequenceForm", "StandardForm", "TextForm", "TeXForm",
        "TraditionalForm",
    };
    return names;
}

std::optional<std::string> display_form_name(const Expr& expression) {
    if (expression.kind() != ExprKind::Call || expression.args().empty()) return std::nullopt;
    const auto* raw_name = expression.head().symbol_name();
    if (raw_name == nullptr) return std::nullopt;
    const auto name = system_dispatch_name(*raw_name);
    return display_form_heads().count(name) != 0 ? std::optional<std::string>(name)
                                                 : std::nullopt;
}

bool is_symbol(const Expr& expression, const std::string& expected) {
    const auto* name = expression.symbol_name();
    return name != nullptr && system_dispatch_name(*name) == expected;
}

bool is_numeric(const Expr& expression) {
    switch (expression.kind()) {
    case ExprKind::Integer:
    case ExprKind::Real:
    case ExprKind::Rational:
    case ExprKind::Complex:
    case ExprKind::Root:
    case ExprKind::SpecialReal: return true;
    default: return false;
    }
}

std::string join(const std::vector<std::string>& values, const std::string& separator) {
    std::ostringstream output;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) output << separator;
        output << values[index];
    }
    return output.str();
}

Expr row_box(std::vector<Expr> items) {
    return call("RowBox", {list(std::move(items))});
}

Expr traditional_boxes(const Expr& expression);

Expr traditional_separated_boxes(
    const std::vector<Expr>& expressions, const std::string& separator) {
    std::vector<Expr> pieces;
    for (std::size_t index = 0; index < expressions.size(); ++index) {
        if (index != 0) pieces.push_back(string(separator));
        pieces.push_back(traditional_boxes(expressions[index]));
    }
    return row_box(std::move(pieces));
}

Expr traditional_bracket_boxes(
    const std::string& open, const std::vector<Expr>& expressions, const std::string& close) {
    return row_box({string(open), traditional_separated_boxes(expressions, ","), string(close)});
}

Expr traditional_infix_boxes(
    const Expr& left, const std::string& operator_text, const Expr& right) {
    return row_box({traditional_boxes(left), string(operator_text), traditional_boxes(right)});
}

Expr traditional_boxes(const Expr& expression) {
    switch (expression.kind()) {
    case ExprKind::Symbol:
    case ExprKind::Integer:
    case ExprKind::Real:
    case ExprKind::Root:
    case ExprKind::SpecialReal: return string(expression.to_input_form());
    case ExprKind::String: return string(wl_string(expression.text()));
    case ExprKind::Rational:
        return call("FractionBox", {
            string(expression.rational_value().get_num().get_str()),
            string(expression.rational_value().get_den().get_str()),
        });
    case ExprKind::Complex:
        return traditional_boxes(call("Complex", {
            expression.real_part(), expression.imaginary_part()}));
    case ExprKind::ByteArray:
    case ExprKind::SparseArray: return string(expression.to_input_form());
    case ExprKind::Call: break;
    }

    const auto* raw_name = expression.head().symbol_name();
    const auto name = raw_name == nullptr ? std::string{} : system_dispatch_name(*raw_name);
    const auto& arguments = expression.args();
    if (name == "List") return traditional_bracket_boxes("{", arguments, "}");
    if (name == "Association") return traditional_bracket_boxes("<|", arguments, "|>");
    if (name == "Rule" && arguments.size() == 2)
        return traditional_infix_boxes(arguments[0], "->", arguments[1]);
    if (name == "RuleDelayed" && arguments.size() == 2)
        return traditional_infix_boxes(arguments[0], ":>", arguments[1]);
    if (name == "Plus" && arguments.size() >= 2) {
        std::vector<Expr> ordered;
        for (const auto& argument : arguments)
            if (!is_numeric(argument)) ordered.push_back(argument);
        for (const auto& argument : arguments)
            if (is_numeric(argument)) ordered.push_back(argument);
        return traditional_separated_boxes(ordered, "+");
    }
    if (name == "Times" && arguments.size() >= 2)
        return traditional_separated_boxes(arguments, " ");
    if (name == "Power" && arguments.size() == 2)
        return call("SuperscriptBox", {
            traditional_boxes(arguments[0]), traditional_boxes(arguments[1])});
    if (name == "Subscript" && arguments.size() == 2)
        return call("SubscriptBox", {
            traditional_boxes(arguments[0]), traditional_boxes(arguments[1])});

    return row_box({
        traditional_boxes(expression.head()), string("["),
        traditional_separated_boxes(arguments, ","), string("]"),
    });
}

std::string tex_form(const Expr& expression) {
    if (expression.kind() == ExprKind::Rational) {
        return "\\frac{" + expression.rational_value().get_num().get_str() + "}{"
            + expression.rational_value().get_den().get_str() + "}";
    }
    if (expression.kind() == ExprKind::String) return "\\text{" + wl_string(expression.text()) + "}";
    if (expression.kind() != ExprKind::Call) return expression.to_input_form();

    const auto* raw_name = expression.head().symbol_name();
    const auto name = raw_name == nullptr ? std::string{} : system_dispatch_name(*raw_name);
    const auto& arguments = expression.args();
    if (name == "List") {
        std::vector<std::string> values;
        for (const auto& argument : arguments) values.push_back(tex_form(argument));
        return "\\{" + join(values, ", ") + "\\}";
    }
    if (name == "Plus") {
        std::vector<const Expr*> ordered;
        for (const auto& argument : arguments)
            if (!is_numeric(argument)) ordered.push_back(&argument);
        for (const auto& argument : arguments)
            if (is_numeric(argument)) ordered.push_back(&argument);
        std::vector<std::string> values;
        for (const auto* argument : ordered) values.push_back(tex_form(*argument));
        return join(values, "+");
    }
    if (name == "Times") {
        std::vector<std::string> values;
        for (const auto& argument : arguments) values.push_back(tex_form(argument));
        return join(values, " ");
    }
    if (name == "Power" && arguments.size() == 2)
        return tex_form(arguments[0]) + "^{" + tex_form(arguments[1]) + "}";
    if ((name == "Sin" || name == "Cos" || name == "Tan" || name == "Log" || name == "Exp")
        && arguments.size() == 1) {
        auto function = name;
        std::transform(function.begin(), function.end(), function.begin(),
            [](unsigned char value) { return detail::ascii_lower(value); });
        if (function == "log") function = "ln";
        return "\\" + function + "\\left(" + tex_form(arguments[0]) + "\\right)";
    }
    std::vector<std::string> values;
    for (const auto& argument : arguments) values.push_back(tex_form(argument));
    return tex_form(expression.head()) + "\\left[" + join(values, ", ") + "\\right]";
}

std::string c_like_form(const Expr& expression, bool fortran) {
    if (expression.kind() == ExprKind::Real) {
        auto result = expression.text();
        if (const auto exponent = result.find("*^"); exponent != std::string::npos)
            result.replace(exponent, 2, "e");
        return result;
    }
    if (expression.kind() == ExprKind::Rational) {
        std::ostringstream output;
        output.imbue(std::locale::classic());
        try {
            output << std::setprecision(16)
                   << detail::correctly_rounded_double(expression.rational_value());
        } catch (const std::overflow_error&) {
            return expression.rational_value() < 0 ? "-inf" : "inf";
        }
        return output.str();
    }
    if (expression.kind() == ExprKind::Complex)
        return "Complex(" + c_like_form(expression.real_part(), fortran) + ","
            + c_like_form(expression.imaginary_part(), fortran) + ")";
    if (expression.kind() == ExprKind::String) return wl_string(expression.text());
    if (expression.kind() != ExprKind::Call) return expression.to_input_form();

    const auto* raw_name = expression.head().symbol_name();
    const auto name = raw_name == nullptr ? std::string{} : system_dispatch_name(*raw_name);
    const auto& arguments = expression.args();
    std::vector<std::string> values;
    for (const auto& argument : arguments) values.push_back(c_like_form(argument, fortran));
    if (name == "Plus") return join(values, " + ");
    if (name == "Times") return join(values, "*");
    if (name == "Power" && arguments.size() == 2) {
        if (fortran) return values[0] + "**" + values[1];
        return "Power(" + values[0] + "," + values[1] + ")";
    }
    return c_like_form(expression.head(), fortran) + "(" + join(values, ",") + ")";
}

template<typename AtomFormatter>
std::string structured_text_with(
    const Expr& expression, const AtomFormatter& atom_formatter) {
    if (expression.kind() != ExprKind::Call) return atom_formatter(expression);

    const auto* raw_name = expression.head().symbol_name();
    const auto name = raw_name == nullptr ? std::string{} : system_dispatch_name(*raw_name);
    const auto& arguments = expression.args();
    std::vector<std::string> values;
    for (const auto& argument : arguments)
        values.push_back(structured_text_with(argument, atom_formatter));
    if (name == "List") return "{" + join(values, ", ") + "}";
    if (name == "Association") return "<|" + join(values, ", ") + "|>";
    if (name == "Rule" && values.size() == 2) return values[0] + " -> " + values[1];
    if (name == "RuleDelayed" && values.size() == 2) return values[0] + " :> " + values[1];
    if (name == "Plus") return join(values, " + ");
    if (name == "Times") return join(values, " ");
    if (name == "Power" && values.size() == 2) return values[0] + "^" + values[1];
    return structured_text_with(expression.head(), atom_formatter)
        + "[" + join(values, ", ") + "]";
}

std::string structured_text(const Expr& expression) {
    return structured_text_with(expression, [](const Expr& atom) {
        return atom.kind() == ExprKind::String ? atom.text() : atom.to_input_form();
    });
}

std::optional<double> numeric_value(const Expr& expression) {
    if (expression.kind() != ExprKind::Real) return std::nullopt;
    auto text = expression.text();
    text.erase(std::remove(text.begin(), text.end(), '`'), text.end());
    if (const auto exponent = text.find("*^"); exponent != std::string::npos)
        text.replace(exponent, 2, "e");
    return detail::parse_ascii_double(text);
}

std::optional<std::size_t> nonnegative_size(const mpz_class& integer) {
    if (integer < 0) return std::nullopt;
    const auto text = integer.get_str();
    std::size_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
        return std::nullopt;
    return value;
}

std::optional<std::size_t> nonnegative_size(const Expr& expression) {
    return expression.kind() == ExprKind::Integer
        ? nonnegative_size(expression.integer_value()) : std::nullopt;
}

std::optional<std::size_t> bounded_display_size(const Expr& expression) {
    constexpr std::size_t max_display_digits = 4096;
    const auto value = nonnegative_size(expression);
    return value && *value <= max_display_digits ? value : std::nullopt;
}

struct DigitSpecs {
    std::optional<std::size_t> total;
    std::optional<std::size_t> fraction;
};

DigitSpecs digit_specs(const std::vector<Expr>& specifications) {
    if (specifications.empty()) return {};
    if (const auto total = bounded_display_size(specifications[0]))
        return {*total, std::nullopt};
    if (!specifications[0].has_head("List") || specifications[0].args().empty()) return {};
    DigitSpecs result;
    result.total = bounded_display_size(specifications[0].args()[0]);
    if (specifications[0].args().size() > 1)
        result.fraction = bounded_display_size(specifications[0].args()[1]);
    return result;
}

std::string decimal_text(
    double value, const std::string& form_name, const DigitSpecs& specifications) {
    if (form_name == "PercentForm") value *= 100.0;
    std::ostringstream output;
    output.imbue(std::locale::classic());
    if (form_name == "ScientificForm") {
        const auto digits = std::max<std::size_t>(1, specifications.total.value_or(6));
        output << std::scientific << std::setprecision(static_cast<int>(digits - 1)) << value;
        auto result = output.str();
        if (const auto exponent = result.find('e'); exponent != std::string::npos)
            result.replace(exponent, 1, "*10^");
        return result;
    }
    if (form_name == "EngineeringForm" && value != 0.0) {
        const auto exponent = static_cast<int>(std::floor(std::log10(std::abs(value)) / 3.0) * 3.0);
        const auto mantissa = value / std::pow(10.0, exponent);
        const auto digits = std::max<std::size_t>(1, specifications.total.value_or(6));
        output << std::setprecision(static_cast<int>(std::max<std::size_t>(1, digits - 1)))
               << mantissa;
        return output.str() + "*10^" + std::to_string(exponent);
    }
    if (specifications.fraction) {
        output << std::fixed << std::setprecision(static_cast<int>(*specifications.fraction)) << value;
    } else if (specifications.total && *specifications.total > 0) {
        output << std::setprecision(static_cast<int>(*specifications.total)) << value;
    } else {
        output << std::setprecision(16) << value;
    }
    auto result = output.str();
    if (form_name == "AccountingForm" && !result.empty() && result.front() == '-')
        result = "(" + result.substr(1) + ")";
    if (form_name == "PercentForm") result += "%";
    if (form_name == "PaddedForm" && specifications.total && result.size() < *specifications.total)
        result.insert(result.begin(), *specifications.total - result.size(), ' ');
    return result;
}

std::string number_form_text(
    const Expr& expression, const std::string& form_name, const std::vector<Expr>& specs) {
    const auto specifications = digit_specs(specs);
    return structured_text_with(expression, [&](const Expr& atom) {
        if (atom.kind() == ExprKind::Real) {
            if (const auto value = numeric_value(atom))
                return decimal_text(*value, form_name, specifications);
        }
        if (atom.kind() == ExprKind::Integer) {
            auto value = atom.integer_value();
            if (form_name == "PercentForm") value *= 100;
            auto result = value.get_str();
            if (form_name == "AccountingForm" && !result.empty()
                && result.front() == '-')
                result = "(" + result.substr(1) + ")";
            if (form_name == "PercentForm") result += "%";
            if (form_name == "PaddedForm" && specifications.total
                && result.size() < *specifications.total)
                result.insert(
                    result.begin(), *specifications.total - result.size(), ' ');
            return result;
        }
        return atom.kind() == ExprKind::String
            ? atom.text() : atom.to_input_form();
    });
}

std::string integer_base_text(const mpz_class& value, unsigned base) {
    const auto negative = value < 0;
    auto body = (negative ? -value : value).get_str(static_cast<int>(base));
    return std::to_string(base) + "^^" + (negative ? "-" : "") + body;
}

std::string table_form_text(const Expr& expression) {
    if (!expression.has_head("List")) return structured_text(expression);
    std::vector<std::vector<std::string>> rows;
    bool matrix = true;
    for (const auto& row : expression.args()) matrix = matrix && row.has_head("List");
    if (matrix) {
        for (const auto& row : expression.args()) {
            std::vector<std::string> cells;
            for (const auto& cell : row.args()) cells.push_back(structured_text(cell));
            rows.push_back(std::move(cells));
        }
    } else {
        for (const auto& item : expression.args()) rows.push_back({structured_text(item)});
    }
    std::size_t columns = 0;
    for (const auto& row : rows) columns = std::max(columns, row.size());
    std::vector<std::size_t> widths(columns, 0);
    for (const auto& row : rows)
        for (std::size_t column = 0; column < row.size(); ++column)
            widths[column] = std::max(widths[column], row[column].size());
    std::vector<std::string> rendered;
    for (const auto& row : rows) {
        std::ostringstream line;
        for (std::size_t column = 0; column < row.size(); ++column) {
            if (column != 0) line << "   ";
            const auto width = std::min(
                widths[column], static_cast<std::size_t>(std::numeric_limits<int>::max()));
            line << std::left << std::setw(static_cast<int>(width)) << row[column];
        }
        auto text = line.str();
        while (!text.empty() && text.back() == ' ') text.pop_back();
        rendered.push_back(std::move(text));
    }
    return join(rendered, "\n");
}

std::string display_form_text(
    const Expr& payload, const std::string& form_name, const std::vector<Expr>& specs) {
    if (form_name == "FullForm") return payload.to_full_form();
    if (form_name == "TraditionalForm")
        return "\\!\\(\\*FormBox[" + traditional_boxes(payload).to_input_form()
            + ", TraditionalForm]\\)";
    if (form_name == "TeXForm") return tex_form(payload);
    if (form_name == "CForm") return c_like_form(payload, false);
    if (form_name == "FortranForm") return c_like_form(payload, true);
    if (form_name == "OutputForm" || form_name == "TextForm" || form_name == "PrintForm")
        return structured_text(payload);
    if (form_name == "NumberForm" || form_name == "DecimalForm"
        || form_name == "ScientificForm" || form_name == "EngineeringForm"
        || form_name == "AccountingForm" || form_name == "PaddedForm"
        || form_name == "PercentForm")
        return number_form_text(payload, form_name, specs);
    if (form_name == "BaseForm") {
        const auto base_value = specs.empty() ? std::optional<std::size_t>{}
                                              : nonnegative_size(specs[0]);
        const auto base = static_cast<unsigned>(
            std::min<std::size_t>(36, std::max<std::size_t>(2, base_value.value_or(10))));
        return payload.kind() == ExprKind::Integer
            ? integer_base_text(payload.integer_value(), base) : structured_text(payload);
    }
    if (form_name == "TableForm" || form_name == "MatrixForm") return table_form_text(payload);
    if (form_name == "TreeForm" || form_name == "DisplayForm") return structured_text(payload);
    if (form_name == "SequenceForm") {
        std::string result = structured_text(payload);
        for (const auto& specification : specs) result += structured_text(specification);
        return result;
    }
    if (form_name == "StringForm" && payload.kind() == ExprKind::String) {
        auto result = payload.text();
        for (std::size_t index = 0; index < specs.size(); ++index) {
            const auto value = structured_text(specs[index]);
            const auto numbered = "`" + std::to_string(index + 1) + "`";
            std::size_t position = 0;
            while ((position = result.find(numbered, position)) != std::string::npos) {
                result.replace(position, numbered.size(), value);
                position += value.size();
            }
        }
        for (const auto& specification : specs) {
            const auto position = result.find("``");
            if (position == std::string::npos) break;
            result.replace(position, 2, structured_text(specification));
        }
        return result;
    }
    if (form_name == "MathMLForm") return "<math>\n " + structured_text(payload) + "\n</math>\n";
    return payload.to_input_form();
}

Expr history_output_expression(const Expr& expression) {
    const auto name = display_form_name(expression);
    if (name && value_stripping_display_form_heads().count(*name) != 0)
        return expression.args()[0];
    const auto* raw_name = expression.kind() == ExprKind::Call
        ? expression.head().symbol_name() : nullptr;
    if (raw_name != nullptr && !expression.args().empty()) {
        const auto short_name = system_dispatch_name(*raw_name);
        if (short_name == "Short" || short_name == "Shallow") return expression.args()[0];
    }
    return expression;
}

std::vector<std::size_t> utf8_boundaries(const std::string& text) {
    std::vector<std::size_t> result{0};
    std::size_t index = 0;
    while (index < text.size()) {
        const auto first = static_cast<unsigned char>(text[index]);
        std::size_t width = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
        if (index + width > text.size()) width = 1;
        else {
            for (std::size_t offset = 1; offset < width; ++offset) {
                if ((static_cast<unsigned char>(text[index + offset]) & 0xc0) != 0x80) {
                    width = 1;
                    break;
                }
            }
        }
        index += width;
        result.push_back(index);
    }
    return result;
}

std::string utf8_prefix(const std::string& text, std::size_t count) {
    const auto boundaries = utf8_boundaries(text);
    return text.substr(0, boundaries[std::min(count, boundaries.size() - 1)]);
}

std::string center_truncate(const std::string& text, std::size_t limit) {
    const auto boundaries = utf8_boundaries(text);
    const auto length = boundaries.size() - 1;
    if (length <= limit) return text;
    if (limit == 0) return "<<" + std::to_string(length) + ">> chars";
    const auto marker = " <<" + std::to_string(length - limit) + " chars>> ";
    const auto marker_length = utf8_boundaries(marker).size() - 1;
    if (marker_length >= limit) return utf8_prefix(marker, limit);
    const auto prefix_length = (limit - marker_length + 1) / 2;
    const auto suffix_length = limit - marker_length - prefix_length;
    const auto prefix = text.substr(0, boundaries[prefix_length]);
    const auto suffix = suffix_length == 0 ? std::string{}
        : text.substr(boundaries[length - suffix_length]);
    return prefix + marker + suffix;
}

std::string short_list_text(const Expr& expression) {
    if (!expression.has_head("List") || expression.args().size() <= 15) return {};
    std::vector<std::string> front;
    std::vector<std::string> back;
    for (std::size_t index = 0; index < 10; ++index)
        front.push_back(expression.args()[index].to_input_form());
    for (std::size_t index = expression.args().size() - 5;
         index < expression.args().size(); ++index)
        back.push_back(expression.args()[index].to_input_form());
    return "{" + join(front, ", ") + ", <<"
        + std::to_string(expression.args().size() - 15) + ">>, "
        + join(back, ", ") + "}";
}

std::string normalize_print_text(const std::string& text) {
    try {
        const auto expression = parse_input_form(text);
        if (display_form_name(expression)) return display_output_parts(expression).second;
    } catch (const std::exception&) {
    }
    return text;
}

struct ExitResult {
    bool requested = false;
    int code = 0;
};

ExitResult exit_result(const Expr& expression) {
    if (expression.kind() == ExprKind::Symbol) {
        if (is_symbol(expression, "Exit") || is_symbol(expression, "Quit")) return {true, 0};
        return {};
    }
    if (expression.kind() != ExprKind::Call) return {};
    const auto* raw_name = expression.head().symbol_name();
    if (raw_name == nullptr) return {};
    const auto name = system_dispatch_name(*raw_name);
    if (name != "Exit" && name != "Quit") return {};
    if (expression.args().empty()) return {true, 0};
    if (expression.args().size() != 1 || expression.args()[0].kind() != ExprKind::Integer)
        throw std::runtime_error("Exit and Quit expect an optional integer exit code.");
    if (!expression.args()[0].integer_value().fits_sint_p())
        throw std::runtime_error("Exit code is outside the supported native integer range.");
    return {true, static_cast<int>(expression.args()[0].integer_value().get_si())};
}

bool blank_source(const std::string& source) {
    return std::all_of(source.begin(), source.end(), [](unsigned char value) {
        return detail::ascii_is_space(value);
    });
}

} // namespace

std::string repl_banner() {
    return std::string("Tungsten ") + repl_version
        + " Kernel-free Wolfram Language Interpreter for Microsoft Windows (64-bit)\n"
          "Copyright 2026 OpenAI Codex. Structural subset; not a Wolfram kernel.\n";
}

DisplayOutputParts display_output_parts(const Expr& expression) {
    if (const auto name = display_form_name(expression)) {
        std::vector<Expr> specifications;
        if (expression.args().size() > 1)
            specifications.assign(expression.args().begin() + 1, expression.args().end());
        return {*name, display_form_text(expression.args()[0], *name, specifications)};
    }
    const auto* raw_name = expression.kind() == ExprKind::Call
        ? expression.head().symbol_name() : nullptr;
    if (raw_name != nullptr && !expression.args().empty()) {
        const auto name = system_dispatch_name(*raw_name);
        if (name == "Short" || name == "Shallow")
            return {name, expression.args()[0].to_input_form()};
    }
    if (expression.kind() == ExprKind::String) return {std::nullopt, expression.text()};
    return {std::nullopt, expression.to_input_form()};
}

std::string apply_output_size_limit(
    const Expr& expression, const std::string& text, std::optional<std::size_t> limit) {
    if (!limit || utf8_boundaries(text).size() - 1 <= *limit) return text;
    const auto payload = history_output_expression(expression);
    const auto shortened = short_list_text(payload);
    if (!shortened.empty() && utf8_boundaries(shortened).size() - 1 <= *limit)
        return shortened;
    return center_truncate(shortened.empty() ? text : shortened, *limit);
}

EvaluationSession::EvaluationSession() {
    (void)evaluator_.evaluate(call("Set", {
        symbol("$OutputSizeLimit"), integer(12000L)}));
    (void)evaluator_.evaluate(call("Set", {
        symbol("$HistoryLength"), symbol("Infinity")}));
    (void)evaluator_.evaluate(call("Set", {
        symbol("$MessagePrePrint"), symbol("Automatic")}));
}

void EvaluationSession::collect_effects(
    std::vector<std::string>& prints,
    std::vector<Expr>& message_names,
    std::vector<std::string>& messages) const {
    for (const auto& print : evaluator_.prints()) prints.push_back(normalize_print_text(print));
    for (std::size_t index = 0; index < evaluator_.messages().size(); ++index) {
        const auto& name = evaluator_.messages()[index];
        message_names.push_back(name);
        messages.push_back(index < evaluator_.message_texts().size()
            ? evaluator_.message_texts()[index] : name.to_input_form());
    }
}

std::optional<std::size_t> EvaluationSession::history_index(
    const std::vector<Expr>& arguments) const {
    if (arguments.empty()) return line_ == 0 ? std::optional<std::size_t>{0}
                                             : std::optional<std::size_t>{line_ - 1};
    if (arguments.size() != 1 || arguments[0].kind() != ExprKind::Integer) return std::nullopt;
    const auto& value = arguments[0].integer_value();
    if (value < 0) {
        const mpz_class target = value + mpz_class(std::to_string(line_));
        return nonnegative_size(target);
    }
    return nonnegative_size(value);
}

Expr EvaluationSession::replace_session_references(
    const Expr& expression, std::set<std::size_t>& expanding_inputs) {
    if (expression.kind() == ExprKind::Symbol && is_symbol(expression, "$Line"))
        return integer(line_);
    if (expression.kind() != ExprKind::Call) return expression;

    const auto* raw_name = expression.head().symbol_name();
    const auto name = raw_name == nullptr ? std::string{} : system_dispatch_name(*raw_name);
    if (name == "DownValues" && expression.args().size() == 1) {
        const auto* target_name = expression.args()[0].symbol_name();
        const auto target = target_name == nullptr
            ? std::string{} : system_dispatch_name(*target_name);
        std::vector<Expr> rules;
        if (target == "In") {
            for (const auto& [index, value] : inputs_)
                rules.push_back(call("RuleDelayed", {
                    call("HoldPattern", {call("In", {integer(index)})}), value}));
        } else if (target == "InString") {
            for (const auto& [index, value] : input_strings_)
                rules.push_back(call("RuleDelayed", {
                    call("HoldPattern", {call("InString", {integer(index)})}), string(value)}));
        } else if (target == "Out") {
            for (const auto& [index, value] : outputs_)
                rules.push_back(call("RuleDelayed", {
                    call("HoldPattern", {call("Out", {integer(index)})}), value}));
        } else {
            rules.clear();
        }
        if (target == "In" || target == "InString" || target == "Out")
            return list(std::move(rules));
    }
    if (name == "In" || name == "InString" || name == "Out") {
        const auto index = history_index(expression.args());
        if (index) {
            if (name == "In") {
                const auto found = inputs_.find(*index);
                if (found != inputs_.end() && expanding_inputs.insert(*index).second) {
                    const auto replacement = replace_session_references(found->second, expanding_inputs);
                    expanding_inputs.erase(*index);
                    return replacement;
                }
            } else if (name == "InString") {
                const auto found = input_strings_.find(*index);
                if (found != input_strings_.end()) return string(found->second);
            } else {
                const auto found = outputs_.find(*index);
                if (found != outputs_.end()) return found->second;
            }
            return call(expression.head(), {integer(*index)});
        }
    }
    if (name == "MessageList" && expression.args().size() == 1) {
        if (const auto index = history_index(expression.args())) {
            std::vector<Expr> held;
            if (const auto found = message_history_.find(*index); found != message_history_.end())
                for (const auto& message : found->second)
                    held.push_back(call("HoldForm", {message}));
            return list(std::move(held));
        }
    }

    std::vector<Expr> arguments;
    arguments.reserve(expression.args().size());
    for (const auto& argument : expression.args())
        arguments.push_back(replace_session_references(argument, expanding_inputs));
    return call(replace_session_references(expression.head(), expanding_inputs), std::move(arguments));
}

Expr EvaluationSession::apply_hook(
    const std::string& name,
    const Expr& expression,
    std::vector<std::string>* prints,
    std::vector<Expr>* message_names,
    std::vector<std::string>* messages) {
    const auto hook = evaluator_.evaluate(symbol(name));
    if (prints != nullptr && message_names != nullptr && messages != nullptr)
        collect_effects(*prints, *message_names, *messages);
    if (hook == symbol(name)) return expression;
    std::set<std::size_t> expanding_inputs;
    const auto invocation = replace_session_references(
        call(hook, {expression}), expanding_inputs);
    const auto result = evaluator_.evaluate(invocation);
    if (prints != nullptr && message_names != nullptr && messages != nullptr)
        collect_effects(*prints, *message_names, *messages);
    return result;
}

std::string EvaluationSession::apply_pre_read(
    const std::string& source,
    std::vector<std::string>& prints,
    std::vector<Expr>& message_names,
    std::vector<std::string>& messages) {
    const auto hook = evaluator_.evaluate(symbol("$PreRead"));
    collect_effects(prints, message_names, messages);
    if (hook == symbol("$PreRead")) return source;
    std::set<std::size_t> expanding_inputs;
    const auto invocation = replace_session_references(
        call(hook, {string(source)}), expanding_inputs);
    const auto result = evaluator_.evaluate(invocation);
    collect_effects(prints, message_names, messages);
    if (result.kind() == ExprKind::String) return result.text();
    const auto name = call("MessageName", {symbol("$PreRead"), string("prstr")});
    message_names.push_back(name);
    messages.push_back("$PreRead[" + wl_string(source) + "] returned "
        + result.to_input_form() + ", which is not a string.");
    return source;
}

SessionOutput EvaluationSession::evaluate_input(const std::string& source) {
    ++line_;
    std::vector<std::string> prints;
    std::vector<Expr> message_names;
    std::vector<std::string> messages;

    const auto prepared_source = apply_pre_read(source, prints, message_names, messages);
    const auto parsed = parse_input_form(prepared_source);
    input_strings_[line_] = prepared_source;
    inputs_[line_] = parsed;

    std::set<std::size_t> expanding_inputs;
    auto prepared_expression = replace_session_references(parsed, expanding_inputs);
    prepared_expression = apply_hook(
        "$Pre", prepared_expression, &prints, &message_names, &messages);
    auto result = evaluator_.evaluate(prepared_expression);
    collect_effects(prints, message_names, messages);
    if (const auto exit = exit_result(result); exit.requested)
        return {SessionOutput::Kind::Exit, exit.code, line_, result,
            std::move(prints), std::move(messages)};

    result = apply_hook("$Post", result, &prints, &message_names, &messages);
    if (const auto exit = exit_result(result); exit.requested)
        return {SessionOutput::Kind::Exit, exit.code, line_, result,
            std::move(prints), std::move(messages)};

    outputs_[line_] = history_output_expression(result);
    message_history_[line_] = message_names;
    prune_history();
    return {SessionOutput::Kind::Value, 0, line_, result,
        std::move(prints), std::move(messages)};
}

Expr EvaluationSession::preprint(const Expr& result) {
    return apply_hook("$PrePrint", result, nullptr, nullptr, nullptr);
}

std::optional<std::size_t> EvaluationSession::output_size_limit() {
    const auto value = evaluator_.evaluate(symbol("$OutputSizeLimit"));
    if (is_symbol(value, "Infinity")) return std::nullopt;
    if (const auto limit = nonnegative_size(value)) return *limit;
    return 12000;
}

void EvaluationSession::prune_history() {
    const auto value = evaluator_.evaluate(symbol("$HistoryLength"));
    if (is_symbol(value, "Infinity")) return;
    const auto supported_length = nonnegative_size(value);
    if (!supported_length) return;
    const auto length = *supported_length;
    const auto cutoff = length > line_ ? 0 : line_ - length + 1;
    const auto prune = [cutoff](auto& history) {
        while (!history.empty() && history.begin()->first < cutoff) history.erase(history.begin());
    };
    prune(input_strings_);
    prune(inputs_);
    prune(outputs_);
    prune(message_history_);
}

int run_repl(
    std::istream& input,
    std::ostream& output,
    std::ostream& error,
    bool show_banner) {
    EvaluationSession session;
    if (show_banner) output << repl_banner() << '\n';

    while (true) {
        output << "In[" << session.line() + 1 << "]:= ";
        output.flush();
        std::string source;
        if (!std::getline(input, source)) {
            output << '\n';
            output.flush();
            return 0;
        }
        if (!source.empty() && source.back() == '\r') source.pop_back();
        if (blank_source(source)) {
            output << '\n';
            continue;
        }

        try {
            auto result = session.evaluate_input(source);
            if (result.is_exit()) return result.exit_code;
            for (const auto& message : result.messages) error << message << '\n';
            error.flush();
            for (const auto& print : result.prints) output << print << '\n';
            if (result.result != symbol("Null")) {
                Expr print_result = result.result;
                try {
                    print_result = session.preprint(result.result);
                } catch (const std::exception&) {
                }
                const auto label = display_output_parts(result.result).first;
                auto text = display_output_parts(print_result).second;
                text = apply_output_size_limit(
                    print_result, text, session.output_size_limit());
                output << "\nOut[" << result.line << "]";
                if (label) output << "//" << *label;
                output << "= " << text << "\n\n";
            } else {
                output << '\n';
            }
            output.flush();
        } catch (const ParseError& exception) {
            error << "Syntax::sntxi: " << exception.what() << "\n\n";
            error.flush();
        } catch (const std::exception& exception) {
            error << "Evaluate::error: " << exception.what() << "\n\n";
            error.flush();
        }
    }
}

} // namespace tungsten
