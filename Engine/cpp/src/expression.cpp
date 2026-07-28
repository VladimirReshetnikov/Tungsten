#include "tungsten/expression.hpp"

#include "tungsten/detail/format.hpp"
#include "tungsten/detail/numeric.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <locale>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string_view>

namespace tungsten {

struct ExprNode {
    ExprKind kind = ExprKind::Symbol;
    std::string text = "Null";
    mpz_class integer = 0;
    mpq_class rational = 0;
    std::shared_ptr<const ExprNode> first;
    std::shared_ptr<const ExprNode> second;
    std::vector<mpz_class> coefficients;
    std::size_t index = 0;
    long method = 0;
    std::vector<std::uint8_t> byte_values;
    std::vector<mpz_class> dimensions;
    std::vector<std::size_t> native_dimensions;
    std::optional<std::size_t> native_length;
    std::vector<SparseEntry> entries;
    std::shared_ptr<const ExprNode> fill;
    std::vector<Expr> arguments;
};

namespace {

const std::vector<Expr> empty_arguments;

std::string join(const std::vector<std::string>& values, const std::string& separator) {
    std::ostringstream output;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index != 0) {
            output << separator;
        }
        output << values[index];
    }
    return output.str();
}

std::string json_escape(const std::string& value) {
    std::ostringstream output;
    output << '"';
    for (const unsigned char character : value) {
        switch (character) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (character < 0x20) {
                static constexpr char digits[] = "0123456789abcdef";
                output << "\\u00" << digits[character >> 4] << digits[character & 0x0f];
            } else {
                output << static_cast<char>(character);
            }
        }
    }
    output << '"';
    return output.str();
}

std::string base64(const std::vector<std::uint8_t>& input) {
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string output;
    output.reserve(((input.size() + 2) / 3) * 4);
    for (std::size_t index = 0; index < input.size(); index += 3) {
        const auto remaining = input.size() - index;
        const std::uint32_t value = static_cast<std::uint32_t>(input[index]) << 16
            | (remaining > 1 ? static_cast<std::uint32_t>(input[index + 1]) << 8 : 0)
            | (remaining > 2 ? static_cast<std::uint32_t>(input[index + 2]) : 0);
        output.push_back(alphabet[(value >> 18) & 0x3f]);
        output.push_back(alphabet[(value >> 12) & 0x3f]);
        output.push_back(remaining > 1 ? alphabet[(value >> 6) & 0x3f] : '=');
        output.push_back(remaining > 2 ? alphabet[value & 0x3f] : '=');
    }
    return output;
}

Expr polynomial_from_coefficients(const std::vector<mpz_class>& coefficients, const Expr& variable) {
    std::vector<Expr> terms;
    for (std::size_t exponent = 0; exponent < coefficients.size(); ++exponent) {
        const auto& coefficient = coefficients[exponent];
        if (coefficient == 0) {
            continue;
        }
        const auto coefficient_expression = integer(coefficient);
        if (exponent == 0) {
            terms.push_back(coefficient_expression);
            continue;
        }
        const auto power = exponent == 1
            ? variable
            : call("Power", {variable, integer(exponent)});
        if (coefficient == 1) {
            terms.push_back(power);
        } else if (coefficient == -1) {
            terms.push_back(call("Times", {integer(-1L), power}));
        } else {
            terms.push_back(call("Times", {coefficient_expression, power}));
        }
    }
    if (terms.empty()) {
        return integer(0L);
    }
    if (terms.size() == 1) {
        return terms.front();
    }
    return call("Plus", std::move(terms));
}

struct RealMarker {
    bool numeric = false;
    bool machine = false;
    bool explicit_precision = false;
    double value = 0.0;
};

RealMarker real_marker(const Expr& expression) {
    if (expression.kind() != ExprKind::Real) return {};
    auto literal = expression.text();
    std::string exponent;
    if (const auto marker = literal.find("*^"); marker != std::string::npos) {
        exponent = literal.substr(marker + 2);
        literal.erase(marker);
    }

    bool machine = true;
    bool explicit_precision = false;
    if (const auto marker = literal.find('`'); marker != std::string::npos) {
        auto suffix = literal.substr(marker + 1);
        literal.erase(marker);
        const bool accuracy = !suffix.empty() && suffix.front() == '`';
        if (accuracy) suffix.erase(suffix.begin());
        if (!suffix.empty()) {
            machine = false;
            explicit_precision = !accuracy;
        }
    }
    if (literal.empty() || literal == "+" || literal == "-" || literal == ".") return {};
    if (!exponent.empty()) literal += "e" + exponent;
    const auto value = detail::parse_ascii_double(literal);
    return value ? RealMarker{true, machine, explicit_precision, *value}
                 : RealMarker{};
}

Expr machine_real(double value) {
    if (std::isnan(value)) return symbol("Indeterminate");
    if (std::isinf(value)) return special_real("Overflow");
    return real(detail::python_machine_real_text(value));
}

Expr normalize_machine_complex_component(const Expr& expression) {
    try {
        if (expression.kind() == ExprKind::Integer)
            return machine_real(detail::correctly_rounded_double(
                expression.integer_value()));
        if (expression.kind() == ExprKind::Rational)
            return machine_real(detail::correctly_rounded_double(
                expression.rational_value()));
    } catch (const std::overflow_error&) {
        return special_real("Overflow");
    }
    const auto marker = real_marker(expression);
    if (marker.numeric && marker.explicit_precision)
        return machine_real(marker.value);
    return expression;
}

std::shared_ptr<const ExprNode> require_node(const std::shared_ptr<const ExprNode>& value) {
    if (!value) {
        throw std::logic_error("Tungsten expression contains an empty node");
    }
    return value;
}

std::optional<std::size_t> native_dimension(const mpz_class& value) {
    static const mpz_class maximum(
        std::to_string(std::numeric_limits<std::size_t>::max()), 10);
    if (value < 0 || value > maximum) return std::nullopt;
    std::size_t result = 0;
    const auto text = value.get_str();
    const auto parsed = std::from_chars(
        text.data(), text.data() + text.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
        return std::nullopt;
    return result;
}

} // namespace

Expr::Expr() : node_(std::make_shared<ExprNode>()) {}
Expr::Expr(std::shared_ptr<const ExprNode> node) : node_(require_node(node)) {}
Expr::Expr(Expr&& other) noexcept : node_(other.node_) {}

Expr& Expr::operator=(Expr&& other) noexcept {
    if (this != &other) node_ = other.node_;
    return *this;
}

ExprKind Expr::kind() const noexcept { return node_->kind; }

std::size_t Expr::length() const noexcept {
    if (kind() == ExprKind::SparseArray) {
        if (node_->dimensions.empty()) return 0;
        return node_->native_length.value_or(
            std::numeric_limits<std::size_t>::max());
    }
    if (kind() == ExprKind::ByteArray) {
        return node_->byte_values.size();
    }
    return args().size();
}

std::size_t Expr::depth() const noexcept {
    if (kind() == ExprKind::SparseArray) {
        return node_->dimensions.size() + 1;
    }
    if (kind() == ExprKind::Call) {
        if (node_->arguments.empty()) {
            return 2;
        }
        std::size_t maximum = 1;
        for (const auto& argument : node_->arguments) {
            maximum = std::max(maximum, argument.depth());
        }
        return maximum + 1;
    }
    return 1;
}

Expr Expr::head() const {
    switch (kind()) {
    case ExprKind::Symbol: return symbol("Symbol");
    case ExprKind::Integer: return symbol("Integer");
    case ExprKind::Real:
    case ExprKind::SpecialReal: return symbol("Real");
    case ExprKind::Rational: return symbol("Rational");
    case ExprKind::Complex: return symbol("Complex");
    case ExprKind::Root: return symbol("Root");
    case ExprKind::String: return symbol("String");
    case ExprKind::ByteArray: return symbol("ByteArray");
    case ExprKind::SparseArray: return symbol("SparseArray");
    case ExprKind::Call: return Expr(node_->first);
    }
    throw std::logic_error("unreachable expression kind");
}

const std::vector<Expr>& Expr::args() const noexcept {
    return kind() == ExprKind::Call || kind() == ExprKind::Root
        ? node_->arguments : empty_arguments;
}

bool Expr::is_atom() const noexcept {
    return kind() != ExprKind::Call && kind() != ExprKind::Root;
}

const std::string* Expr::symbol_name() const noexcept {
    return kind() == ExprKind::Symbol ? &node_->text : nullptr;
}

bool Expr::has_head(const std::string& expected) const noexcept {
    if (kind() == ExprKind::Symbol) {
        return node_->text == expected;
    }
    if (kind() == ExprKind::Root) {
        return expected == "Root";
    }
    if (kind() != ExprKind::Call || !node_->first) {
        return false;
    }
    const Expr head_expression(node_->first);
    const auto* name = head_expression.symbol_name();
    if (name == nullptr) return false;
    constexpr std::string_view prefix = "System`";
    auto dispatch_name = std::string_view(*name);
    if (dispatch_name.compare(0, prefix.size(), prefix) == 0)
        dispatch_name.remove_prefix(prefix.size());
    return dispatch_name == expected;
}

const std::string& Expr::text() const {
    if (kind() != ExprKind::Symbol && kind() != ExprKind::Real
        && kind() != ExprKind::SpecialReal && kind() != ExprKind::String) {
        throw std::logic_error("expression does not carry text");
    }
    return node_->text;
}

const mpz_class& Expr::integer_value() const {
    if (kind() != ExprKind::Integer) throw std::logic_error("expression is not an integer");
    return node_->integer;
}

const mpq_class& Expr::rational_value() const {
    if (kind() != ExprKind::Rational) throw std::logic_error("expression is not rational");
    return node_->rational;
}

Expr Expr::real_part() const {
    if (kind() != ExprKind::Complex) throw std::logic_error("expression is not complex");
    return Expr(node_->first);
}

Expr Expr::imaginary_part() const {
    if (kind() != ExprKind::Complex) throw std::logic_error("expression is not complex");
    return Expr(node_->second);
}

const std::vector<mpz_class>& Expr::root_coefficients() const { return node_->coefficients; }
std::size_t Expr::root_index() const { return node_->index; }
long Expr::root_method() const { return node_->method; }
const std::vector<std::uint8_t>& Expr::bytes() const { return node_->byte_values; }
const std::vector<std::size_t>& Expr::dimensions() const {
    if (node_->native_dimensions.size() != node_->dimensions.size())
        throw std::overflow_error(
            "SparseArray dimensions exceed the native representation limit.");
    return node_->native_dimensions;
}
const std::vector<mpz_class>& Expr::sparse_dimensions() const noexcept {
    return node_->dimensions;
}
const std::vector<SparseEntry>& Expr::sparse_entries() const { return node_->entries; }

Expr Expr::fill_value() const {
    if (kind() != ExprKind::SparseArray) throw std::logic_error("expression is not sparse");
    return Expr(node_->fill);
}

std::string Expr::to_full_form() const {
    switch (kind()) {
    case ExprKind::Symbol: return encode_printable_ascii(node_->text);
    case ExprKind::Integer: return node_->integer.get_str();
    case ExprKind::Real: return node_->text;
    case ExprKind::Rational:
        return "Rational[" + node_->rational.get_num().get_str() + ", "
            + node_->rational.get_den().get_str() + "]";
    case ExprKind::Complex:
        return "Complex[" + Expr(node_->first).to_full_form() + ", "
            + Expr(node_->second).to_full_form() + "]";
    case ExprKind::Root: {
        const auto body = polynomial_from_coefficients(
            node_->coefficients, call("Slot", {integer(1L)}));
        return "Root[Function[" + body.to_full_form() + "], "
            + node_->arguments[1].integer_value().get_str() + ", "
            + std::to_string(node_->method) + "]";
    }
    case ExprKind::SpecialReal: return node_->text + "[]";
    case ExprKind::String: return wl_string(node_->text);
    case ExprKind::ByteArray: return "ByteArray[" + wl_string(base64(node_->byte_values)) + "]";
    case ExprKind::SparseArray: {
        std::vector<Expr> rules;
        for (const auto& entry : node_->entries) {
            std::vector<Expr> indices;
            for (const auto index : entry.indices) indices.push_back(integer(index));
            rules.push_back(call("Rule", {list(std::move(indices)), entry.value}));
        }
        std::vector<Expr> dimensions;
        for (const auto& dimension : node_->dimensions)
            dimensions.push_back(integer(dimension));
        std::vector<Expr> arguments{list(std::move(rules)), list(std::move(dimensions))};
        if (Expr(node_->fill) != integer(0L)) arguments.push_back(Expr(node_->fill));
        return call("SparseArray", std::move(arguments)).to_full_form();
    }
    case ExprKind::Call: {
        std::vector<std::string> values;
        values.reserve(node_->arguments.size());
        for (const auto& argument : node_->arguments) values.push_back(argument.to_full_form());
        return Expr(node_->first).to_full_form() + "[" + join(values, ", ") + "]";
    }
    }
    throw std::logic_error("unreachable expression kind");
}

std::string Expr::to_input_form() const { return detail::format_input(*this, 0); }

std::string Expr::to_json() const {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    switch (kind()) {
    case ExprKind::Symbol:
        output << R"({"type":"symbol","name":)" << json_escape(node_->text) << '}'; break;
    case ExprKind::Integer:
        output << R"({"type":"integer","value":)" << node_->integer.get_str() << '}'; break;
    case ExprKind::Real:
        output << R"({"type":"real","text":)" << json_escape(node_->text) << '}'; break;
    case ExprKind::Rational:
        output << R"({"type":"rational","numerator":)" << node_->rational.get_num().get_str()
               << R"(,"denominator":)" << node_->rational.get_den().get_str() << '}'; break;
    case ExprKind::Complex:
        output << R"({"type":"complex","real":)" << Expr(node_->first).to_json()
               << R"(,"imaginary":)" << Expr(node_->second).to_json() << '}'; break;
    case ExprKind::Root:
        output << R"({"type":"root","coefficients":[)";
        for (std::size_t index = 0; index < node_->coefficients.size(); ++index) {
            if (index != 0) output << ',';
            output << node_->coefficients[index].get_str();
        }
        output << R"(],"index":)" << node_->arguments[1].integer_value().get_str()
               << R"(,"method":)" << node_->method << '}';
        break;
    case ExprKind::SpecialReal:
        output << R"({"type":"real","special":)" << json_escape(node_->text) << '}'; break;
    case ExprKind::String: {
        output << R"({"type":"string","value":)" << json_escape(node_->text);
        const auto boxes = inline_box_segments(node_->text);
        if (!boxes.empty()) {
            output << R"(,"inline_boxes":[)";
            for (std::size_t index = 0; index < boxes.size(); ++index) {
                if (index != 0) output << ',';
                output << R"({"kind":"inline_box","box_expression":)"
                       << json_escape(boxes[index].box_expression)
                       << R"(,"inline_box_escape":)" << json_escape(boxes[index].source)
                       << '}';
            }
            output << ']';
        }
        output << '}';
        break;
    }
    case ExprKind::ByteArray:
        output << R"({"type":"byte_array","values":[)";
        for (std::size_t index = 0; index < node_->byte_values.size(); ++index) {
            if (index != 0) output << ',';
            output << static_cast<unsigned>(node_->byte_values[index]);
        }
        output << R"(],"base64":)" << json_escape(base64(node_->byte_values))
               << R"(,"length":)" << node_->byte_values.size() << '}';
        break;
    case ExprKind::SparseArray:
        output << R"({"type":"sparse_array","dimensions":[)";
        for (std::size_t index = 0; index < node_->dimensions.size(); ++index) {
            if (index != 0) output << ',';
            output << node_->dimensions[index].get_str();
        }
        output << R"(],"fill_value":)" << Expr(node_->fill).to_json() << R"(,"entries":[)";
        for (std::size_t index = 0; index < node_->entries.size(); ++index) {
            if (index != 0) output << ',';
            output << R"({"indices":[)";
            for (std::size_t part = 0; part < node_->entries[index].indices.size(); ++part) {
                if (part != 0) output << ',';
                output << node_->entries[index].indices[part];
            }
            output << R"(],"value":)" << node_->entries[index].value.to_json() << '}';
        }
        output << R"(],"explicit_length":)" << node_->entries.size() << '}';
        break;
    case ExprKind::Call:
        output << R"({"type":"call","head":)" << Expr(node_->first).to_json() << R"(,"args":[)";
        for (std::size_t index = 0; index < node_->arguments.size(); ++index) {
            if (index != 0) output << ',';
            output << node_->arguments[index].to_json();
        }
        output << "]}";
        break;
    }
    return output.str();
}

bool operator==(const Expr& left, const Expr& right) noexcept {
    if (left.node_ == right.node_) return true;
    if (left.kind() != right.kind()) return false;
    switch (left.kind()) {
    case ExprKind::Symbol:
    case ExprKind::Real:
    case ExprKind::SpecialReal:
    case ExprKind::String: return left.node_->text == right.node_->text;
    case ExprKind::Integer: return left.node_->integer == right.node_->integer;
    case ExprKind::Rational: return left.node_->rational == right.node_->rational;
    case ExprKind::Complex:
        return Expr(left.node_->first) == Expr(right.node_->first)
            && Expr(left.node_->second) == Expr(right.node_->second);
    case ExprKind::Root:
        return left.node_->coefficients == right.node_->coefficients
            && left.node_->index == right.node_->index && left.node_->method == right.node_->method;
    case ExprKind::ByteArray: return left.node_->byte_values == right.node_->byte_values;
    case ExprKind::SparseArray:
        return left.node_->dimensions == right.node_->dimensions
            && left.node_->entries == right.node_->entries
            && Expr(left.node_->fill) == Expr(right.node_->fill);
    case ExprKind::Call:
        return Expr(left.node_->first) == Expr(right.node_->first)
            && left.node_->arguments == right.node_->arguments;
    }
    return false;
}

Expr symbol(std::string name) {
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Symbol; node->text = std::move(name);
    return Expr(std::move(node));
}
Expr integer(mpz_class value) {
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Integer; node->integer = std::move(value);
    return Expr(std::move(node));
}
Expr real(std::string text) {
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Real; node->text = std::move(text);
    return Expr(std::move(node));
}
Expr rational(mpz_class numerator, mpz_class denominator) {
    if (denominator == 0) return numerator == 0 ? symbol("Indeterminate") : symbol("ComplexInfinity");
    mpq_class value(std::move(numerator), std::move(denominator)); value.canonicalize();
    if (value.get_den() == 1) return integer(value.get_num());
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Rational; node->rational = std::move(value);
    return Expr(std::move(node));
}
Expr complex(Expr real_value, Expr imaginary_value) {
    if ((imaginary_value.kind() == ExprKind::Integer && imaginary_value.integer_value() == 0)
        || (imaginary_value.kind() == ExprKind::Rational && imaginary_value.rational_value() == 0)) {
        return real_value;
    }
    const auto real_marker_value = real_marker(real_value);
    const auto imaginary_marker_value = real_marker(imaginary_value);
    if ((real_marker_value.numeric && real_marker_value.machine)
        || (imaginary_marker_value.numeric && imaginary_marker_value.machine)) {
        real_value = normalize_machine_complex_component(real_value);
        imaginary_value = normalize_machine_complex_component(imaginary_value);
    }
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Complex;
    node->first = real_value.node_; node->second = imaginary_value.node_; return Expr(std::move(node));
}
Expr special_real(std::string name) {
    if (name != "Overflow" && name != "Underflow")
        throw std::invalid_argument("Unsupported special real atom: " + name + ".");
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::SpecialReal; node->text = std::move(name);
    return Expr(std::move(node));
}
Expr string(std::string value) {
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::String; node->text = std::move(value);
    return Expr(std::move(node));
}
Expr byte_array(std::vector<std::uint8_t> values) {
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::ByteArray; node->byte_values = std::move(values);
    return Expr(std::move(node));
}
Expr root(std::vector<mpz_class> coefficients, std::size_t index, long method) {
    if (coefficients.size() < 2 || coefficients.back() == 0)
        throw std::invalid_argument(
            "Root expects a nonconstant polynomial with nonzero leading coefficient.");
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Root;
    node->coefficients = std::move(coefficients); node->index = index; node->method = method;
    const auto body = polynomial_from_coefficients(
        node->coefficients, call("Slot", {integer(1L)}));
    auto one_based_index = mpz_class(std::to_string(index), 10);
    ++one_based_index;
    node->arguments = {
        call("Function", {body}), integer(std::move(one_based_index)), integer(method)};
    return Expr(std::move(node));
}
Expr sparse_array(std::vector<mpz_class> dimensions, std::vector<SparseEntry> entries, Expr fill_value) {
    if (std::any_of(dimensions.begin(), dimensions.end(),
            [](const mpz_class& dimension) { return dimension < 0; }))
        throw std::invalid_argument(
            "SparseArray dimensions must be non-negative.");
    std::sort(entries.begin(), entries.end(),
        [](const SparseEntry& left, const SparseEntry& right) {
            return left.indices < right.indices;
        });
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::SparseArray;
    if (!dimensions.empty())
        node->native_length = native_dimension(dimensions.front());
    node->native_dimensions.reserve(dimensions.size());
    for (const auto& dimension : dimensions) {
        const auto native = native_dimension(dimension);
        if (!native) {
            node->native_dimensions.clear();
            break;
        }
        node->native_dimensions.push_back(*native);
    }
    node->dimensions = std::move(dimensions); node->entries = std::move(entries); node->fill = fill_value.node_;
    return Expr(std::move(node));
}
Expr call(Expr head, std::vector<Expr> args) {
    const auto* name = head.symbol_name();
    std::vector<Expr> normalized;
    const bool flat = name != nullptr && (system_dispatch_name(*name) == "Alternatives"
        || system_dispatch_name(*name) == "CompoundExpression");
    for (auto& argument : args) {
        if (flat && argument.has_head(system_dispatch_name(*name))) {
            normalized.insert(normalized.end(), argument.args().begin(), argument.args().end());
        } else {
            normalized.push_back(std::move(argument));
        }
    }
    auto node = std::make_shared<ExprNode>(); node->kind = ExprKind::Call;
    node->first = head.node_; node->arguments = std::move(normalized); return Expr(std::move(node));
}
Expr call(const std::string& head, std::vector<Expr> args) { return call(symbol(head), std::move(args)); }
Expr list(std::vector<Expr> items) { return call("List", std::move(items)); }

std::string system_dispatch_name(const std::string& name) {
    static const std::string prefix = "System`";
    return name.compare(0, prefix.size(), prefix) == 0 ? name.substr(prefix.size()) : name;
}

} // namespace tungsten
