#include "tungsten/evaluator.hpp"
#include "tungsten/expression.hpp"
#include "tungsten/detail/numeric.hpp"
#include "tungsten/json.hpp"
#include "tungsten/parser.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <locale>
#include <stdexcept>
#include <string>
#include <utility>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual,
    const std::string& expected,
    const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

template<typename Function>
void expect_invalid_argument(Function&& function, const std::string& message) {
    try {
        function();
        check(false, message);
    } catch (const std::invalid_argument&) {
    }
}

template<typename Function>
void expect_overflow_error(Function&& function, const std::string& message) {
    try {
        function();
        check(false, message);
    } catch (const std::overflow_error&) {
    }
}

mpq_class ratio(mpz_class numerator, mpz_class denominator) {
    mpq_class result(std::move(numerator), std::move(denominator));
    result.canonicalize();
    return result;
}

void integral_conversion_tests() {
    using tungsten::integer;
    check_equal(integer(false).to_full_form(), "0", "bool false conversion");
    check_equal(integer(true).to_full_form(), "1", "bool true conversion");
    check_equal(integer(std::numeric_limits<signed char>::min()).to_full_form(),
        std::to_string(static_cast<int>(std::numeric_limits<signed char>::min())),
        "signed-char minimum conversion");
    check_equal(integer(std::numeric_limits<unsigned long>::max()).to_full_form(),
        std::to_string(std::numeric_limits<unsigned long>::max()),
        "unsigned-long conversion is unambiguous on LP64 and LLP64");
    check_equal(integer(std::numeric_limits<long long>::min()).to_full_form(),
        std::to_string(std::numeric_limits<long long>::min()),
        "long-long minimum conversion");
    check_equal(integer(std::numeric_limits<unsigned long long>::max()).to_full_form(),
        std::to_string(std::numeric_limits<unsigned long long>::max()),
        "unsigned-long-long maximum conversion");
    const std::size_t size = std::numeric_limits<std::size_t>::max();
    check_equal(integer(size).to_full_form(), std::to_string(size),
        "size_t conversion avoids direct ambiguous GMP construction");
    const std::int64_t signed_width = std::numeric_limits<std::int64_t>::min();
    const std::uint64_t unsigned_width = std::numeric_limits<std::uint64_t>::max();
    check_equal(integer(signed_width).to_full_form(), std::to_string(signed_width),
        "int64_t conversion");
    check_equal(integer(unsigned_width).to_full_form(), std::to_string(unsigned_width),
        "uint64_t conversion");
}

void expression_projection_tests() {
    using namespace tungsten;
    const auto boxed_value = compose_inline_box_string(
        "before ", {R"WL(RowBox[{"x","+","y"}])WL"}, " after");
    const auto boxed_json = JsonValue::parse(string(boxed_value).to_json());
    check(boxed_json.at("inline_boxes").size() == 1,
        "string JSON exposes inline-box records");
    check_equal(boxed_json.at("inline_boxes").at(0).at("kind").as_string(),
        "inline_box", "inline-box JSON kind");
    check_equal(boxed_json.at("inline_boxes").at(0).at("box_expression").as_string(),
        R"WL(RowBox[{"x","+","y"}])WL", "inline-box JSON expression");
    check(!JsonValue::parse(string("plain").to_json()).contains("inline_boxes"),
        "plain string JSON remains compact");

    const auto algebraic = root({-2, 0, 1}, 0, 7);
    check(algebraic.args().size() == 3 && algebraic.length() == 3,
        "Root exposes its three structural arguments");
    check(algebraic.depth() == 1, "Root preserves its atomic depth contract");
    check(!algebraic.is_atom(), "Root remains non-atomic");
    check(algebraic.has_head("Root"), "Root head predicate");
    check_equal(algebraic.args()[1].to_full_form(), "1", "Root one-based index argument");
    check_equal(algebraic.args()[2].to_full_form(), "7", "Root method argument");
    check(algebraic.args()[0].has_head("Function"), "Root function argument");

    const auto maximum_index_root = root(
        {-2, 0, 1}, std::numeric_limits<std::size_t>::max());
    auto expected_one_based_index = mpz_class(
        std::to_string(std::numeric_limits<std::size_t>::max()), 10);
    ++expected_one_based_index;
    check_equal(maximum_index_root.args()[1].to_full_form(),
        expected_one_based_index.get_str(),
        "maximum Root index increments without native-width wrap");
    check(maximum_index_root.to_full_form().find(expected_one_based_index.get_str())
            != std::string::npos,
        "maximum Root index full form retains the arbitrary-width one-based value");
    check_equal(JsonValue::parse(maximum_index_root.to_json())
            .at("index").as_number().text,
        expected_one_based_index.get_str(),
        "maximum Root index JSON retains the arbitrary-width one-based value");

    Expr move_source = call("f", {integer(1L)});
    Expr move_target(std::move(move_source));
    check_equal(move_target.to_full_form(), "f[1]", "move target remains valid");
    check_equal(move_source.to_full_form(), "f[1]", "move source remains valid");
    Expr move_assigned;
    move_assigned = std::move(move_target);
    check_equal(move_assigned.to_full_form(), "f[1]", "move-assigned target remains valid");
    check_equal(move_target.to_full_form(), "f[1]", "move-assigned source remains valid");

    const mpz_class enormous_order = mpz_class(1) << 200;
    check_equal(call(call("Derivative", {integer(enormous_order)}), {symbol("f")})
            .to_input_form(),
        "Derivative[" + enormous_order.get_str() + "][f]",
        "huge derivative orders use bounded generic formatting");
    check_equal(call("Out", {integer(-enormous_order)}).to_input_form(),
        "Out[-" + enormous_order.get_str() + "]",
        "huge output-history offsets use bounded generic formatting");

    check(symbol("x").has_head("x"), "Symbol.has_head matches its own name");
    check(!symbol("System`x").has_head("x"),
        "Symbol.has_head does not context-normalize atom names");
    check(call(symbol("System`f"), {}).has_head("f"),
        "Call.has_head context-normalizes System heads");

    expect_invalid_argument(
        [] { (void)root({1}, 0); }, "constant Root polynomial rejected");
    expect_invalid_argument(
        [] { (void)root({1, 0}, 0); }, "zero Root leading coefficient rejected");
    expect_invalid_argument(
        [] { (void)special_real("Unknown"); }, "unsupported special real rejected");
    check_equal(special_real("Overflow").to_full_form(), "Overflow[]",
        "supported special real retained");
}

void machine_complex_tests() {
    using namespace tungsten;
    const auto mixed = complex(integer(2), real("3."));
    check(mixed.kind() == ExprKind::Complex
            && mixed.real_part().kind() == ExprKind::Real,
        "machine complex converts an exact real component");
    check_equal(mixed.real_part().to_full_form(), "2.",
        "exact integer component receives machine precision");

    const auto rational_mixed = complex(rational(1, 2), real("1."));
    check_equal(rational_mixed.real_part().to_full_form(), "0.5",
        "exact rational component receives machine precision");

    const auto fixed_threshold = complex(rational(1, 10000), real("1."));
    check_equal(fixed_threshold.real_part().to_full_form(), "0.0001",
        "machine normalization follows Python's fixed-form threshold");
    const auto scientific_threshold = complex(rational(1, 100000), real("1."));
    check_equal(scientific_threshold.real_part().to_full_form(), "1*^-05",
        "machine normalization follows Python's scientific-form threshold");
    const auto large_fixed = complex(integer(1000000000000000LL), real("1."));
    check_equal(large_fixed.real_part().to_full_form(), "1000000000000000.",
        "machine normalization retains Python fixed form below exponent sixteen");

    const auto precision_mixed = complex(real("2.5`30."), real("1."));
    check_equal(precision_mixed.real_part().to_full_form(), "2.5",
        "arbitrary-precision real component is machine-normalized");

    const auto accuracy_mixed = complex(real("2.5``20."), real("1."));
    check_equal(accuracy_mixed.real_part().to_full_form(), "2.5``20.",
        "accuracy-marked real follows the Python constructor contract");

    check(complex(real("3."), integer(0)) == real("3."),
        "exact zero imaginary component still collapses before normalization");

    const mpz_class huge_component = mpz_class(1) << 2000;
    const auto overflow_mixed = complex(integer(huge_component), real("1."));
    check(overflow_mixed.kind() == ExprKind::Complex
            && overflow_mixed.real_part() == special_real("Overflow"),
        "machine complex overflow is represented without escaping an exception");
}

void exact_binary64_tests() {
    using tungsten::detail::correctly_rounded_double;
    using tungsten::detail::parse_ascii_double;
    check(parse_ascii_double("+1.25") == 1.25,
        "ASCII double parser accepts a leading plus without using the locale");
    check(parse_ascii_double("-2.5e+2") == -250.0,
        "ASCII double parser accepts invariant exponent syntax");
    check(!parse_ascii_double("1,25") && !parse_ascii_double("1.25suffix"),
        "ASCII double parser rejects locale decimal and trailing text");
    check(!parse_ascii_double("+-1") && !parse_ascii_double("nan")
            && !parse_ascii_double("inf") && !parse_ascii_double("-inf"),
        "ASCII double parser rejects repeated signs and non-finite spellings");
    const auto infinity = std::numeric_limits<double>::infinity();
    const mpz_class two53 = mpz_class(1) << 53;
    const mpz_class two54 = mpz_class(1) << 54;
    check(correctly_rounded_double(ratio(two53 + 1, two53)) == 1.0,
        "binary64 halfway value rounds to the even lower significand");
    check(correctly_rounded_double(ratio(two53 + 3, two53))
            == std::nextafter(std::nextafter(1.0, infinity), infinity),
        "binary64 halfway value rounds to the even upper significand");
    check(correctly_rounded_double(ratio(two54 + 3, two54))
            == std::nextafter(1.0, infinity),
        "binary64 value above a midpoint rounds upward");

    const auto minimum_subnormal = std::numeric_limits<double>::denorm_min();
    const mpz_class two1075 = mpz_class(1) << 1075;
    const mpz_class two1076 = mpz_class(1) << 1076;
    check(correctly_rounded_double(ratio(1, two1075)) == 0.0,
        "half a minimum subnormal ties to even zero");
    check(correctly_rounded_double(ratio(3, two1076)) == minimum_subnormal,
        "value above the zero/subnormal midpoint rounds upward");
    check(correctly_rounded_double(ratio(3, two1075))
            == minimum_subnormal * 2.0,
        "subnormal halfway value rounds to the even significand");
    const auto negative_zero = correctly_rounded_double(ratio(-1, two1075));
    check(negative_zero == 0.0 && std::signbit(negative_zero),
        "negative underflow preserves the sign of zero");

    const auto maximum = std::numeric_limits<double>::max();
    mpq_class maximum_exact;
    mpq_set_d(maximum_exact.get_mpq_t(), maximum);
    mpq_class previous_exact;
    mpq_set_d(previous_exact.get_mpq_t(), std::nextafter(maximum, 0.0));
    const mpq_class overflow_threshold =
        maximum_exact + (maximum_exact - previous_exact) / 2;
    check(correctly_rounded_double(overflow_threshold - 1) == maximum,
        "value below the overflow midpoint rounds to maximum binary64");
    expect_overflow_error(
        [&] { (void)correctly_rounded_double(overflow_threshold); },
        "overflow midpoint follows CPython's OverflowError contract");
    expect_overflow_error(
        [] {
            const mpz_class huge_integer = mpz_class(1) << 2000;
            (void)correctly_rounded_double(huge_integer);
        },
        "arbitrary-width integer overflow is rejected like CPython");
}

void parser_helper_tests() {
    using namespace tungsten;
    bool classified_parse_error = false;
    try {
        (void)parse_input_form(std::string(10000, '9') + "^^1");
    } catch (const ParseError&) {
        classified_parse_error = true;
    }
    check(classified_parse_error,
        "arbitrarily long base prefixes retain the public ParseError taxonomy");

    classified_parse_error = false;
    try {
        (void)parse_input_form(std::string(600, '(') + "1" + std::string(600, ')'));
    } catch (const ParseError&) {
        classified_parse_error = true;
    }
    check(classified_parse_error,
        "deeply nested input is rejected before exhausting the native stack");

    const auto fraction_box = call("FractionBox", {string("1"), string("2")});
    check_equal(interpret_standard_form(fraction_box).to_full_form(),
        "Rational[1, 2]", "public StandardForm interpreter");
    check_equal(box_item_to_standard_text(fraction_box), "((1)/(2))",
        "public box-item text projection");
    const auto row = call("RowBox", {list({string("x"), string("+"), string("1")})});
    check_equal(interpret_standard_form(row).to_full_form(), "Plus[x, 1]",
        "public RowBox interpreter");
}

class CommaDecimalPoint final : public std::numpunct<char> {
protected:
    char do_decimal_point() const override { return ','; }
};

void evaluator_numeric_portability_tests() {
    using namespace tungsten;
    Evaluator evaluator;
    check_equal(evaluator.evaluate(call("N", {rational(1, 10000)})).to_full_form(),
        "0.0001", "N uses correctly rounded exact-to-machine conversion");

    const mpz_class two53 = mpz_class(1) << 53;
    check_equal(evaluator.evaluate(call("N", {
        rational(two53 + 1, two53)})).to_full_form(),
        "1.", "N honors ties-to-even at a lower binary64 midpoint");
    check_equal(evaluator.evaluate(call("N", {
        rational(two53 + 3, two53)})).to_full_form(),
        "1.0000000000000004",
        "N honors ties-to-even at an upper binary64 midpoint");

    const mpz_class huge_integer = mpz_class(1) << 2000;
    check_equal(evaluator.evaluate(call("Plus", {
        integer(huge_integer), real("1.")})).to_full_form(),
        "Overflow[]",
        "huge exact plus machine real produces Overflow without terminating");

    const auto saved_precision = mpf_get_default_prec();
    const auto saved_locale = std::locale();
    struct RestoreProcessSettings {
        mp_bitcnt_t precision;
        std::locale locale;
        ~RestoreProcessSettings() {
            mpf_set_default_prec(precision);
            std::locale::global(locale);
        }
    } restore{saved_precision, saved_locale};
    mpf_set_default_prec(80);
    const auto caller_precision = mpf_get_default_prec();
    check(caller_precision != 512,
        "test establishes a caller GMP default distinct from evaluator precision");
    std::locale::global(std::locale(saved_locale, new CommaDecimalPoint));

    Evaluator high_precision_evaluator;
    check_equal(high_precision_evaluator.evaluate(call("N", {
        symbol("Pi"), integer(30)})).to_full_form(),
        "3.14159265358979323846264338328`30.",
        "high-precision output is independent of caller GMP and decimal locale");
    check_equal(high_precision_evaluator.evaluate(call("N", {
        root({-2, 0, 1}, 1), integer(30)})).to_full_form(),
        "1.41421356237309504880168872421`30.",
        "Root high-precision seed text is locale independent");
    check(mpf_get_default_prec() == caller_precision,
        "evaluator leaves the caller's process-global GMP precision unchanged");
}

void evaluator_semantic_safety_tests() {
    using namespace tungsten;
    Evaluator evaluator;

    check_equal(evaluator.evaluate(call("Plus", {real(".1"), real(".2")}))
            .to_full_form(),
        "0.30000000000000004",
        "machine addition rounds each operand in binary64");
    check_equal(evaluator.evaluate(call("Times", {real(".2"), integer(28L)}))
            .to_full_form(),
        "5.6000000000000005",
        "machine multiplication follows binary64 operand rounding");

    check_equal(evaluator.evaluate(call("Floor", {real("5.5"), real(".2")}))
            .to_full_form(),
        "5.4", "Floor with an inexact multiple preserves an inexact result");
    check_equal(evaluator.evaluate(call("Ceiling", {real("5.5"), real(".2")}))
            .to_full_form(),
        "5.6000000000000005",
        "Ceiling with an inexact multiple uses machine multiplication");
    check_equal(evaluator.evaluate(call("Round", {real("5.5"), real(".2")}))
            .to_full_form(),
        "5.6000000000000005",
        "Round with an inexact multiple uses ties-to-even then machine multiplication");
    check_equal(evaluator.evaluate(call("Ceiling", {real("-.1"), real(".2")}))
            .to_full_form(),
        "0.", "inexact-multiple rounding normalizes an integer zero sign");

    mpz_class ten_to_one_hundred;
    mpz_ui_pow_ui(ten_to_one_hundred.get_mpz_t(), 10, 100);
    const mpz_class negative_ten_to_one_hundred = -ten_to_one_hundred;
    check_equal(evaluator.evaluate(call("Floor", {real("1.*^100")})).to_full_form(),
        ten_to_one_hundred.get_str(),
        "Floor converts a huge machine real to an arbitrary-width integer");
    check_equal(evaluator.evaluate(call("Round", {real("-1.*^100")})).to_full_form(),
        negative_ten_to_one_hundred.get_str(),
        "Round converts a negative huge machine real without signed overflow");
    check_equal(evaluator.evaluate(call("IntegerPart", {real("-1.*^100")}))
            .to_full_form(),
        negative_ten_to_one_hundred.get_str(),
        "IntegerPart converts a huge machine real without a host-long cast");

    const auto huge_digits = std::string(256, '9');
    check_equal(evaluator.evaluate(call("NumericalSort", {list({
            string("x" + huge_digits), string("x2")})})).to_full_form(),
        "List[\"x2\", \"x" + huge_digits + "\"]",
        "NumericalSort compares arbitrary-width digit runs without throwing");
    check_equal(evaluator.evaluate(call("NumericalSort", {list({
            string("x02"), string("x2")})})).to_full_form(),
        "List[\"x02\", \"x2\"]",
        "NumericalSort keeps equal numeric runs stable");
    check_equal(evaluator.evaluate(call("NumericalSort", {list({
            integer(2L), string("x1"), integer(1L)})})).to_full_form(),
        "List[\"x1\", 1, 2]",
        "NumericalSort includes non-string InputForm in the natural key");

    const auto long_minimum = std::numeric_limits<long>::min();
    const auto ranked_minimum = call("RankedMin", {
        list({integer(3L), integer(1L), integer(2L)}), integer(long_minimum)});
    check(evaluator.evaluate(ranked_minimum) == ranked_minimum,
        "out-of-range LONG_MIN rank remains symbolic without invalid indexing");
    const auto string_take_minimum = call("StringTake", {
        string("abc"), integer(long_minimum)});
    check(evaluator.evaluate(string_take_minimum) == string_take_minimum,
        "StringTake rejects LONG_MIN without signed-magnitude overflow");

    const mpz_class enormous_rotation = mpz_class(1) << 200;
    check_equal(evaluator.evaluate(call("RotateLeft", {
            list({symbol("a"), symbol("b"), symbol("c")}),
            integer(enormous_rotation)})).to_full_form(),
        "List[b, c, a]",
        "RotateLeft reduces arbitrary-width offsets modulo the sequence length");
    check_equal(evaluator.evaluate(call("RotateRight", {
            list({symbol("a"), symbol("b"), symbol("c")}),
            integer(long_minimum)})).to_full_form(),
        "List[c, a, b]",
        "RotateRight handles LONG_MIN without signed negation");

    check_equal(evaluator.evaluate(call("BitShiftLeft", {
            integer(1L), integer(long_minimum)})).to_full_form(),
        "0", "BitShiftLeft handles a huge negative shift as a bounded right shift");
    const auto prohibited_shift = call("BitShiftRight", {
        integer(1L), integer(long_minimum)});
    check(evaluator.evaluate(prohibited_shift) == prohibited_shift,
        "BitShiftRight leaves an infeasible LONG_MIN left shift symbolic");
    const auto prohibited_power = call("Power", {
        integer(2L), integer(long_minimum)});
    check(evaluator.evaluate(prohibited_power) == prohibited_power,
        "Power leaves an infeasible LONG_MIN exact exponent symbolic");

    const auto enormous_diagonal = call("DiagonalMatrix", {
        list({integer(1L)}), integer(long_minimum)});
    check(evaluator.evaluate(enormous_diagonal) == enormous_diagonal,
        "DiagonalMatrix rejects an infeasible LONG_MIN offset without allocation");
}

} // namespace

int main() {
    integral_conversion_tests();
    expression_projection_tests();
    machine_complex_tests();
    exact_binary64_tests();
    parser_helper_tests();
    evaluator_numeric_portability_tests();
    evaluator_semantic_safety_tests();
    if (failures != 0) {
        std::cerr << failures << " expression-model test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ expression-model tests passed\n";
    return EXIT_SUCCESS;
}
