#include "tungsten/evaluator.hpp"
#include "tungsten/expression.hpp"
#include "tungsten/parser.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual, const std::string& expected, const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

} // namespace

int main() {
    using namespace tungsten;

    const auto expression = call("Plus", {
        symbol("x"), call("Times", {integer(-1L), symbol("y")})});
    check_equal(expression.to_full_form(), "Plus[x, Times[-1, y]]", "full form");
    check_equal(expression.to_input_form(), "x - y", "input form subtraction");
    check(expression.depth() == 3, "expression depth");
    check(expression.length() == 2, "expression length");
    check(expression.head() == symbol("Plus"), "call head");

    check_equal(rational(2, 6).to_full_form(), "Rational[1, 3]", "rational normalization");
    check_equal(rational(2, 1).to_full_form(), "2", "integral rational normalization");
    check_equal(complex(integer(2L), integer(-3L)).to_input_form(), "2 - 3 I", "complex form");
    check(complex(integer(2L), integer(0L)) == integer(2L), "zero imaginary normalization");

    const auto bytes = byte_array({0, 1, 2, 253, 254, 255});
    check_equal(bytes.to_full_form(), "ByteArray[\"AAEC/f7/\"]", "byte array full form");
    check_equal(bytes.to_json(),
        "{\"type\":\"byte_array\",\"values\":[0,1,2,253,254,255],"
        "\"base64\":\"AAEC/f7/\",\"length\":6}", "byte array JSON");

    const auto sparse = sparse_array({3, 4}, {{{1, 2}, integer(9L)}}, integer(-1L));
    check(sparse.length() == 3, "sparse length");
    check(sparse.depth() == 3, "sparse depth");
    check(sparse.fill_value() == integer(-1L), "sparse fill value");
    check_equal(sparse.to_full_form(),
        "SparseArray[List[Rule[List[1, 2], 9]], List[3, 4], -1]", "sparse full form");

    check_equal(wl_string("a\\b\n\"c"), "\"a\\\\b\\n\\\"c\"", "Wolfram string encoder");
    check_equal(parse_wl_string_literal("\"\\[Alpha]\\:03b2\\141\""), u8"\u03b1\u03b2a",
        "Wolfram character escape decoder");
    check_equal(parse_wl_string_literal("\"\\[NoSuchName]\""), "\\[NoSuchName]",
        "unknown named escape preservation");
    check_equal(encode_printable_ascii(u8"x\u03b1"), "x\\[Alpha]", "named character encoder");

    const auto boxed = compose_inline_box_string(
        "before ", {R"WL(RowBox[{"literal \\)", FormBox[\(x\), TraditionalForm]}])WL"}, " after");
    const auto segments = split_inline_boxes(boxed);
    check(segments.size() == 3, "inline box segment count");
    check(segments.size() == 3
        && segments[1].kind == WolframStringSegment::Kind::InlineBox,
        "inline box segment kind");
    check_equal(display_text(boxed, "[InlineBox]"), "before [InlineBox] after",
        "inline box display text");
    const auto decoded_boxed = parse_wl_string_literal(wl_string(boxed));
    check(inline_box_segments(decoded_boxed).size() == 1, "decoded inline box recognition");

    check_equal(symbol("System`Plus").to_json(),
        "{\"type\":\"symbol\",\"name\":\"System`Plus\"}", "symbol JSON");
    check_equal(call("f", {integer(1L), string("x")}).to_json(),
        "{\"type\":\"call\",\"head\":{\"type\":\"symbol\",\"name\":\"f\"},"
        "\"args\":[{\"type\":\"integer\",\"value\":1},{\"type\":\"string\",\"value\":\"x\"}]}",
        "call JSON");

    check_equal(parse_input_form("Plus[1, Times[2, x]]").to_full_form(),
        "Plus[1, Times[2, x]]", "full-form parser surface");
    check_equal(parse_input_form("1 + 2 x^3").to_full_form(),
        "Plus[1, Times[2, Power[x, 3]]]", "arithmetic parser");
    check_equal(parse_input_form("Hold[1 + (2 + 3)]").to_full_form(),
        "Hold[Plus[1, Plus[2, 3]]]", "grouping preserves nested flat head");
    check_equal(parse_input_form("Hold[16^^ff, 1.2``20*^-3]").to_full_form(),
        "Hold[255, 1.2``20*^-3]", "numeric parser surface");
    check_equal(parse_input_form("f[x_Integer, y_]").to_full_form(),
        "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]", "pattern parser");
    check_equal(parse_input_form("x_ /; x > 0").to_full_form(),
        "Condition[Pattern[x, Blank[]], Greater[x, 0]]", "condition parser");
    check_equal(parse_input_form("f[a] /. a -> b").to_full_form(),
        "ReplaceAll[f[a], Rule[a, b]]", "rule parser");
    check_equal(parse_input_form("expr[[1, 2 ;; -1]]").to_full_form(),
        "Part[expr, 1, Span[2, -1]]", "part and span parser");
    check_equal(parse_input_form("f @ # &").to_full_form(),
        "Function[f[Slot[1]]]", "slot and function parser");
    check_equal(parse_input_form("Hold[a < b <= c]").to_full_form(),
        "Hold[Inequality[a, Less, b, LessEqual, c]]", "comparison chain parser");
    check_equal(parse_input_form("<|a -> 1, b -> {2, 3}|>").to_full_form(),
        "Association[Rule[a, 1], Rule[b, List[2, 3]]]", "association parser");

    check_equal(evaluate(parse_input_form("1 + 2*3 + x + 2*x")).to_full_form(),
        "Plus[7, Times[3, x]]", "exact arithmetic evaluator");
    check_equal(evaluate(parse_input_form("(2/3)^-2")).to_full_form(),
        "Rational[9, 4]", "exact rational power evaluator");
    check_equal(evaluate(parse_input_form("Function[{x, y}, x + y][2, 3]")).to_full_form(),
        "5", "named pure function evaluator");
    check_equal(evaluate(parse_input_form("Reap[Sow[1]; Sow[2]; 3]")).to_full_form(),
        "List[3, List[List[1, 2]]]", "reap and sow evaluator");
    Evaluator stateful;
    check_equal(stateful.evaluate(parse_input_form("value = 12")).to_full_form(), "12", "set evaluator");
    check_equal(stateful.evaluate(parse_input_form("value + 3")).to_full_form(), "15", "stateful own value");

    check_equal(stateful.evaluate(parse_input_form("Check[Part[f[a], 2], fallback]")).to_full_form(),
        "fallback", "Check catches emitted messages");
    check(stateful.messages().size() == 1, "Check preserves the caught message");
    check_equal(stateful.message_texts().empty() ? "" : stateful.message_texts().front(),
        "Part::error: Part specifications are invalid for f[a].",
        "Part diagnostic text");
    check_equal(stateful.evaluate(parse_input_form("Quiet[Check[Part[f[a], 2], fallback]]")).to_full_form(),
        "fallback", "Quiet suppresses an inner Check message");
    check(stateful.messages().empty(), "Quiet hides visible messages");
    check_equal(stateful.evaluate(parse_input_form("Print[InputForm[{1, 2/3, a + b}]]")).to_full_form(),
        "Null", "Print returns Null");
    check_equal(stateful.prints().empty() ? "" : stateful.prints().front(),
        "{1, 2/3, a + b}", "InputForm print rendering");
    check_equal(stateful.evaluate(parse_input_form(
        "CheckAbort[WithCleanup[Print[\"expr1\"]; Abort[]; Print[\"expr2\"], "
        "Print[\"cleanup\"]], caught]")).to_full_form(),
        "caught", "WithCleanup preserves abort for CheckAbort");
    check(stateful.prints().size() == 2, "WithCleanup executes cleanup after abort");
    check(stateful.prints().size() == 2 && stateful.prints()[0] == "expr1"
            && stateful.prints()[1] == "cleanup",
        "WithCleanup skips the aborted tail and prints cleanup");

    check_equal(evaluate(parse_input_form(
        "Module[{i = 0, s = 0}, While[i < 5, i = i + 1; "
        "If[Mod[i, 2] == 0, Continue[]]; s = s + i]; s]")).to_full_form(),
        "9", "While catches Continue");
    check_equal(evaluate(parse_input_form(
        "Module[{s = 0}, For[i = 1, i <= 10, i++, "
        "If[i > 5, Break[]]; s = s + i]; s]")).to_full_form(),
        "15", "For catches Break");
    check_equal(evaluate(parse_input_form(
        "Module[{}, For[i = 1, i <= 10, i++, "
        "If[i == 4, Return[fourth, For]]]]")).to_full_form(),
        "fourth", "targeted Return exits For");
    check_equal(evaluate(parse_input_form(
        "Module[{x = 0}, Label[start]; x = x + 1; "
        "If[x < 3, Goto[start]]; x]")).to_full_form(),
        "3", "Goto resumes after a matching Label");
    check_equal(evaluate(parse_input_form("Table[Break[], {i, 1, 3}]")).to_full_form(),
        "Break[]", "Table propagates Break");

    check_equal(stateful.evaluate(parse_input_form(
        "tungstenReturn[x_] := (If[x > 0, Return[positive]]; negative)")).to_full_form(),
        "Null", "Return function definition");
    check_equal(stateful.evaluate(parse_input_form("tungstenReturn[1]")).to_full_form(),
        "positive", "definition boundary catches bare Return");
    check_equal(stateful.evaluate(parse_input_form("tungstenReturn[-1]")).to_full_form(),
        "negative", "definition continues without Return");

    const std::vector<std::pair<std::string, std::string>> exact_integer_cases{
        {"Binomial[-3, 2]", "6"},
        {"Binomial[3, -2]", "0"},
        {"Multinomial[2, 3, 4]", "1260"},
        {"JacobiSymbol[1001, 9907]", "-1"},
        {"KroneckerSymbol[-1, 2]", "1"},
        {"Fibonacci[-6]", "-8"},
        {"LucasL[-6]", "18"},
        {"BernoulliB[1]", "Rational[-1, 2]"},
        {"BernoulliB[10]", "Rational[5, 66]"},
        {"EulerE[6]", "-61"},
        {"HarmonicNumber[5]", "Rational[137, 60]"},
        {"HarmonicNumber[5, 2]", "Rational[5269, 3600]"},
        {"ContinuedFraction[415/93]", "List[4, 2, 6, 7]"},
        {"ContinuedFraction[415/93, 2]", "List[4, 2]"},
        {"ContinuedFraction[-415/93]", "List[-4, -2, -6, -7]"},
        {"FromContinuedFraction[{4, 2, 6, 7}]", "Rational[415, 93]"},
        {"FromContinuedFraction[{}]", "Infinity"},
        {"IntegerPartitions[4]",
            "List[List[4], List[3, 1], List[2, 2], List[2, 1, 1], List[1, 1, 1, 1]]"},
        {"IntegerPartitions[4, 2]", "List[List[4], List[3, 1], List[2, 2]]"},
        {"IntegerPartitions[4, {2}]", "List[List[3, 1], List[2, 2]]"},
        {"PartitionsP[10]", "42"},
        {"PartitionsQ[10]", "10"},
        {"MultiplicativeOrder[2, 7]", "3"},
        {"PrimitiveRoot[7]", "3"},
        {"CarmichaelLambda[12]", "2"},
        {"LiouvilleLambda[18]", "-1"},
        {"JordanTotient[2, 10]", "72"},
        {"RamanujanTau[5]", "4830"},
        {"DivisorSigma[2, 6]", "50"},
        {"DivisorSigma[-1, 6]", "2"},
        {"ModularInverse[3, 7]", "5"},
        {"PowerMod[2, -1, 4]", "PowerMod[2, -1, 4]"},
        {"IntegerReverse[1234]", "4321"},
        {"IntegerReverse[-1234]", "4321"},
        {"IntegerReverse[16, 2]", "1"},
        {"DigitCount[1122]", "List[2, 2, 0, 0, 0, 0, 0, 0, 0, 0]"},
        {"DigitCount[16, 2]", "List[1, 4]"},
        {"DigitCount[16, 2, 0]", "4"},
        {"BitNot[0]", "-1"},
        {"BitClear[15, 2]", "11"},
        {"BitSet[8, 1]", "10"},
        {"BitGet[-2, 1]", "1"},
        {"BitLength[-8]", "3"},
        {"BitLength[0]", "0"},
        {"FactorInteger[5, GaussianIntegers -> True]",
            "List[List[Complex[0, -1], 1], List[Complex[1, 2], 1], List[Complex[2, 1], 1]]"},
        {"FactorInteger[3 + 4 I, GaussianIntegers -> True]",
            "List[List[Complex[2, 1], 2]]"},
        {"FactorInteger[210, 2]", "List[List[2, 1], List[105, 1]]"},
        {"FactorInteger[210, 5]", "List[List[2, 1], List[3, 1], List[5, 1], List[7, 1]]"},
    };
    for (const auto& [source, expected] : exact_integer_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "exact integer evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> transcendental_cases{
        {"ComplexExpand[x + I]", "ComplexExpand[Plus[Complex[0, 1], x]]"},
        {"Arg[0]", "0"},
        {"Arg[1]", "0"},
        {"Arg[-1]", "Pi"},
        {"Arg[I]", "Times[Rational[1, 2], Pi]"},
        {"Arg[-I]", "Times[Rational[-1, 2], Pi]"},
        {"Arg[1 + I]", "Times[Rational[1, 4], Pi]"},
        {"Arg[1 + 2 I]", "ArcTan[1, 2]"},
        {"Arg[-1 + 2 I]", "ArcTan[-1, 2]"},
        {"ReIm[1 + 2 I]", "List[1, 2]"},
        {"ReIm[Pi]", "List[Pi, 0]"},
        {"ReIm[Root[#^2 + 1 &, 1]]", "List[0, -1]"},
        {"Arg[Root[#^2 + 1 &, 1]]", "Times[Rational[-1, 2], Pi]"},
        {"ComplexExpand[Re[1 + 2 I]]", "1"},
        {"ComplexExpand[Im[1 + 2 I]]", "2"},
        {"ComplexExpand[Conjugate[1 + 2 I]]", "Complex[1, -2]"},
        {"ComplexExpand[Abs[1 + 2 I]]", "Power[5, Rational[1, 2]]"},
        {"ComplexExpand[Arg[1 + I]]", "Times[Rational[1, 4], Pi]"},
        {"ComplexExpand[Exp[1 + 2 I]]", "Times[E, Plus[Cos[2], Times[Complex[0, 1], Sin[2]]]]"},
        {"ComplexExpand[Sin[1 + 2 I]]", "Plus[Times[Complex[0, 1], Cos[1], Sinh[2]], Times[Cosh[2], Sin[1]]]"},
        {"ComplexExpand[Cos[1 + 2 I]]", "Plus[Times[Complex[0, -1], Sin[1], Sinh[2]], Times[Cos[1], Cosh[2]]]"},
        {"ComplexExpand[Tan[1 + 2 I]]", "Times[Plus[Sin[2], Times[Complex[0, 1], Sinh[4]]], Power[Plus[Cos[2], Cosh[4]], -1]]"},
        {"ComplexExpand[Log[1 + 2 I]]", "Plus[Log[Power[5, Rational[1, 2]]], Times[Complex[0, 1], ArcTan[2]]]"},
        {"ComplexExpand[Sqrt[1 + 2 I]]", "Plus[Power[Times[Rational[1, 2], Plus[1, Power[5, Rational[1, 2]]]], Rational[1, 2]], Times[Complex[0, 1], Power[Times[Rational[1, 2], Plus[-1, Power[5, Rational[1, 2]]]], Rational[1, 2]]]]"},
        {"ComplexExpand[ArcSin[2]]", "Plus[Times[Complex[0, -1], Log[Plus[2, Power[3, Rational[1, 2]]]]], Times[Rational[1, 2], Pi]]"},
        {"ComplexExpand[Re[ArcSin[2]]]", "Times[Rational[1, 2], Pi]"},
        {"ComplexExpand[Im[ArcSin[2]]]", "Times[-1, Log[Plus[2, Power[3, Rational[1, 2]]]]]"},
        {"ComplexExpand[Re[Root[#^2 + 1 &, 1]]]", "0"},
        {"ComplexExpand[Conjugate[Root[#^2 + 1 &, 1]]]", "Complex[0, 1]"},
        {"ComplexExpand[Abs[Root[#^2 + 1 &, 1]]]", "1"},
        {"ComplexExpand[Arg[Root[#^2 + 1 &, 1]]]", "Times[Rational[-1, 2], Pi]"},
        {"ComplexExpand[{Re[1 + I], Im[1 + I], Abs[1 + I], Arg[1 + I]}]", "List[1, 1, Power[2, Rational[1, 2]], Times[Rational[1, 4], Pi]]"},
        {"Simplify[Sin[1]^2 + Cos[1]^2]", "1"},
        {"FullSimplify[Sin[1]^2 + Cos[1]^2]", "1"},
        {"Simplify[Sqrt[2]^2]", "2"},
        {"Simplify[E^Log[2]]", "2"},
        {"Simplify[Root[#^2 - 2 &, 2]^2]", "2"},
        {"Simplify[Sin[1]]", "Sin[1]"},
        {"Simplify[x + 1]", "Plus[1, x]"},
        {"Simplify[Sin[x]^2 + Cos[x]^2]", "Plus[Power[Cos[x], 2], Power[Sin[x], 2]]"},
        {"Exp[1]", "E"},
        {"Exp[2]", "Power[E, 2]"},
        {"Exp[I Pi]", "-1"},
        {"Log[E]", "1"},
        {"Log[10, 100]", "2"},
        {"Log[0]", "-Infinity"},
        {"Log[-1]", "Times[Complex[0, 1], Pi]"},
        {"Sin[0]", "0"},
        {"Sin[Pi/6]", "Rational[1, 2]"},
        {"Cos[Pi/3]", "Rational[1, 2]"},
        {"Tan[Pi/4]", "1"},
        {"Cot[Pi/4]", "1"},
        {"Sec[0]", "1"},
        {"Csc[Pi/2]", "1"},
        {"Tan[Pi/2]", "ComplexInfinity"},
        {"ArcSin[1/2]", "Times[Rational[1, 6], Pi]"},
        {"ArcCos[1/2]", "Times[Rational[1, 3], Pi]"},
        {"ArcTan[1, 1]", "Times[Rational[1, 4], Pi]"},
        {"ArcTan[-1, 1]", "Times[Rational[3, 4], Pi]"},
        {"ArcTan[1, -1]", "Times[Rational[-1, 4], Pi]"},
        {"ArcTan[0, 0]", "Indeterminate"},
        {"ArcCot[-1]", "Times[Rational[3, 4], Pi]"},
        {"ArcSec[2]", "Times[Rational[1, 3], Pi]"},
        {"ArcCsc[2]", "Times[Rational[1, 6], Pi]"},
        {"ArcSin[2]", "ArcSin[2]"},
        {"ArcCosh[2]", "ArcCosh[2]"},
        {"Sinh[0]", "0"},
        {"Cosh[0]", "1"},
        {"Tanh[0]", "0"},
        {"Coth[0]", "ComplexInfinity"},
        {"Sech[0]", "1"},
        {"Csch[0]", "ComplexInfinity"},
        {"ArcCoth[0]", "Times[Complex[0, Rational[1, 2]], Pi]"},
        {"ArcSech[2]", "Times[Complex[0, Rational[1, 3]], Pi]"},
        {"30 Degree", "Times[30, Degree]"},
        {"Sin[30 Degree]", "Rational[1, 2]"},
        {"SinDegrees[30]", "Rational[1, 2]"},
        {"CosDegrees[60]", "Rational[1, 2]"},
        {"TanDegrees[45]", "1"},
        {"CotDegrees[45]", "1"},
        {"SecDegrees[60]", "2"},
        {"CscDegrees[30]", "2"},
        {"ArcSinDegrees[1/2]", "30"},
        {"ArcCosDegrees[1/2]", "60"},
        {"ArcTanDegrees[1]", "45"},
        {"ArcCotDegrees[1]", "45"},
        {"ArcCotDegrees[-1]", "135"},
        {"ArcSecDegrees[2]", "60"},
        {"ArcCscDegrees[2]", "30"},
        {"Haversine[0]", "0"},
        {"Haversine[Pi]", "1"},
        {"Haversine[Pi/5]", "Plus[Rational[3, 8], Times[Rational[-1, 8], Power[5, Rational[1, 2]]]]"},
        {"Haversine[1]", "Haversine[1]"},
        {"InverseHaversine[1]", "Pi"},
        {"InverseHaversine[2]", "InverseHaversine[2]"},
        {"Gudermannian[0]", "0"},
        {"Gudermannian[1]", "Gudermannian[1]"},
        {"InverseGudermannian[0]", "0"},
        {"InverseGudermannian[1]", "InverseGudermannian[1]"},
        {"NumberQ[Pi]", "True"},
        {"NumberQ[I Pi]", "True"},
        {"ExactNumberQ[I Pi]", "True"},
        {"RealValuedNumberQ[Sin[1]]", "True"},
        {"Sin[1.]", "0.8414709848078965"},
        {"Cos[1.]", "0.5403023058681398"},
        {"Exp[1.]", "2.718281828459045"},
        {"Exp[50.]", "5.184705528587072*^+21"},
        {"Log[2.]", "0.6931471805599453"},
        {"ArcTan[1.]", "0.7853981633974483"},
        {"Sin[1`20]", "0.84147098480789650665`20."},
        {"N[Degree, 20]", "0.017453292519943295769`20."},
        {"N[Gudermannian[1], 30]", "0.865769483239658624289601846192`30."},
        {"N[ArcCoth[2], 30]", "0.549306144334054845697622618461`30."},
        {"N[Log[-1], 20]", "Complex[0.`20., 3.1415926535897932385`20.]"},
        {"Pi > 3", "True"},
        {"E < 3", "True"},
        {"Sin[1] > 0", "True"},
        {"UnitStep[Sin[1] - 1/2]", "1"},
        {"Max[Pi, E, 3]", "Pi"},
        {"Min[Sin[1], Cos[1]]", "Cos[1]"},
    };
    for (const auto& [source, expected] : transcendental_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "transcendental evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> algebraic_root_cases{
        {"Root[I # + 1 &, 1]",
            "Root[Function[Plus[1, Power[Slot[1], 2]]], 2, 0]"},
        {"Root[((1 + I)/2) #^2 + 1 &, 1]",
            "Root[Function[Plus[2, Times[2, Power[Slot[1], 2]], Power[Slot[1], 4]]], 1, 0]"},
        {"Root[#^2 - 2^(1/3) &, 2]",
            "Root[Function[Plus[-2, Power[Slot[1], 6]]], 2, 0]"},
        {"Root[#^2 - Root[#^3 - 2 &, 1] &, 1]",
            "Root[Function[Plus[-2, Power[Slot[1], 6]]], 1, 0]"},
        {"Root[(Root[#^2 - 2 &, 2] + I) #^2 + 1 &, 1]",
            "Root[Function[Plus[1, Times[-2, Power[Slot[1], 4]], Times[9, Power[Slot[1], 8]]]], 3, 0]"},
        {"MinimalPolynomial[Root[#^3 - 2 &, 1]^2, x]",
            "Plus[-4, Power[x, 3]]"},
        {"MinimalPolynomial[Root[#^2 - 2 &, 2] + Root[#^2 - 3 &, 2], x]",
            "Plus[1, Power[x, 4], Times[-10, Power[x, 2]]]"},
        {"RootReduce[Sin[Pi/5]]",
            "Root[Function[Plus[5, Times[-20, Power[Slot[1], 2]], Times[16, Power[Slot[1], 4]]]], 3, 0]"},
        {"RootReduce[Cos[2 Pi/7]]",
            "Root[Function[Plus[-1, Times[-4, Slot[1]], Times[4, Power[Slot[1], 2]], Times[8, Power[Slot[1], 3]]]], 3, 0]"},
        {"RootReduce[SinDegrees[20]]",
            "Root[Function[Plus[-3, Times[36, Power[Slot[1], 2]], Times[-96, Power[Slot[1], 4]], Times[64, Power[Slot[1], 6]]]], 4, 0]"},
        {"RootReduce[Haversine[Pi/5]]",
            "Root[Function[Plus[1, Times[-12, Slot[1]], Times[16, Power[Slot[1], 2]]]], 1, 0]"},
        {"CountRoots[x^3 - x, x]", "3"},
        {"CountRoots[x^2 + 1, x]", "0"},
        {"CountRoots[(x - 1)^2 (x + 1), {x, -2, 2}]", "3"},
        {"CountRoots[(x - 1)^2, {x, 1, 1}]", "2"},
        {"CountRoots[x^2 + 1, {x, -1 - I, 1 + I}]", "2"},
        {"RootIntervals[(x - 1)^2 (x + 1)]",
            "List[List[List[-1, -1], List[1, 1]], List[List[1], List[2]]]"},
        {"RootIntervals[x^2 + 1]", "List[List[], List[]]"},
        {"IsolatingInterval[Root[#^2 - 2 &, 1]]",
            "List[Rational[-91, 64], Rational[-45, 32]]"},
        {"IsolatingInterval[Root[#^2 + 1 &, 1]]",
            "List[Complex[Rational[-1, 128], Rational[-129, 128]], Complex[Rational[1, 128], Rational[-127, 128]]]"},
        {"Normal[RootSum[(# - 1)^2 &, f]]", "Times[2, f[1]]"},
        {"RootSum[#^2 - 2 &, (#^2 &)]", "4"},
        {"RootSum[#^3 - 2 &, (#^3 &)]", "6"},
        {"RootSum[(# - 1)^2 &, (# &)]", "2"},
        {"Conjugate[Root[#^3 - 2 &, 2]]",
            "Root[Function[Plus[-2, Power[Slot[1], 3]]], 3, 0]"},
        {"Root[#^3 - 3 # + 1 &, 1] < Root[#^3 - 3 # + 1 &, 2]", "True"},
        {"Max[Root[#^3 - 3 # + 1 &, 1], Root[#^3 - 3 # + 1 &, 3]]",
            "Root[Function[Plus[1, Times[-3, Slot[1]], Power[Slot[1], 3]]], 3, 0]"},
        {"N[Root[#^3 - 2 &, 1], 30]",
            "1.25992104989487316476721060728`30."},
    };
    for (const auto& [source, expected] : algebraic_root_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "algebraic root evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> kernel_parity_cases{
        {"Plus[x, Times[-1, y], x]", "Plus[Times[2, x], Times[-1, y]]"},
        {"Plus[Times[a, x], Times[b, x]]", "Times[x, Plus[a, b]]"},
        {"Plus[Times[a, x], Times[b, x], Times[c, y], Times[d, y]]",
            "Plus[Times[x, Plus[a, b]], Times[y, Plus[c, d]]]"},
        {"Power[1, x]", "1"},
        {"Power[Times[a, b], 2]", "Times[Power[a, 2], Power[b, 2]]"},
        {"Power[Times[-1, x], 3]", "Times[-1, Power[x, 3]]"},
        {"Times[Power[x, a], Power[x, b]]", "Power[x, Plus[a, b]]"},
        {"Times[Power[x, a], Power[x, a]]", "Power[x, Times[2, a]]"},
        {"Association[Rule[a, 1], Rule[b, 2], Rule[a, 3]]",
            "Association[Rule[a, 3], Rule[b, 2]]"},
        {"Association[Rule[\"name\", x]][\"name\"]", "x"},
        {"Function[Slot[\"name\"]][Association[Rule[\"name\", x]]]", "x"},
        {"Dot[List[List[1, 2], List[3, 4]], List[5, 6]]", "List[17, 39]"},
        {"FixedPoint[Function[Plus[Slot[1], -1]], 5, 0]", "5"},
        {"FixedPoint[Function[Plus[Slot[1], -1]], 5, 2]", "3"},
        {"FixedPointList[Function[Plus[Slot[1], -1]], 5, 2]", "List[5, 4, 3]"},
        {"Level[f[a, g[b]], List[-1]]", "List[a, b]"},
        {"Outer[f, List[List[a, b], List[c, d]], List[List[x, y], List[z, w]]]",
            "List[List[List[List[f[a, x], f[a, y]], List[f[a, z], f[a, w]]], List[List[f[b, x], f[b, y]], List[f[b, z], f[b, w]]]], List[List[List[f[c, x], f[c, y]], List[f[c, z], f[c, w]]], List[List[f[d, x], f[d, y]], List[f[d, z], f[d, w]]]]]"},
        {"Outer[f, List[List[a, b], List[c, d]], List[List[x, y], List[z, w]], 1]",
            "List[List[f[List[a, b], List[x, y]], f[List[a, b], List[z, w]]], List[f[List[c, d], List[x, y]], f[List[c, d], List[z, w]]]]"},
        {"Outer[f, List[a, List[b, c]], List[x, y], 1]",
            "List[List[f[a, x], f[a, y]], List[f[List[b, c], x], f[List[b, c], y]]]"},
        {"Outer[f, List[a, b], List[x, y], List[u, v], 1]",
            "List[List[List[f[a, x, u], f[a, x, v]], List[f[a, y, u], f[a, y, v]]], List[List[f[b, x, u], f[b, x, v]], List[f[b, y, u], f[b, y, v]]]]"},
        {"Part[List[a, b, c, d, e], Span[5, 1, -1]]", "List[e, d, c, b, a]"},
        {"Part[List[a, b, c, d, e], Span[1, 5, 2]]", "List[a, c, e]"},
        {"Part[List[a, b, c, d], Span[2, All]]", "List[b, c, d]"},
        {"Part[List[a, b, c, d], Span[All, 1, -1]]", "List[d, c, b, a]"},
        {"Part[List[a, b, c, d], All]", "List[a, b, c, d]"},
    };
    for (const auto& [source, expected] : kernel_parity_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "kernel parity evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> structural_selector_cases{
        {"Part[{a,b,c},{{1},{3}}]", "List[a, c]"},
        {"Part[<|a->1,b->2,c->3|>,0]", "Association"},
        {"Part[<|a->1,b->2,c->3|>,{1,-1}]",
            "Association[Rule[a, 1], Rule[c, 3]]"},
        {"Part[<|a->1,b->2,c->3|>,Span[1,2]]",
            "Association[Rule[a, 1], Rule[b, 2]]"},
        {"Extract[f[a,b,c],0]", "f"},
        {"Extract[f[a,b,c],{{1},{3}}]", "List[a, c]"},
        {"Delete[f[a,b,c],{{1},{3}}]", "f[b]"},
        {"Insert[f[a,b,c],z,0]", "f[z, a, b, c]"},
        {"Insert[f[a,b,c],z,{-1}]", "f[a, b, c, z]"},
        {"Insert[f[a,b,c],z,{{1},{3}}]", "f[z, a, b, z, c]"},
        {"Insert[<|a->1,b->2,c->3|>,z,{{1},{3}}]",
            "Association[z, Rule[a, 1], Rule[b, 2], z, Rule[c, 3]]"},
        {"ReplacePart[f[a,b,c],{{1},{3}}->z]", "f[z, b, z]"},
        {"ReplacePart[<|a->1,b->2,c->3|>,{{1},{3}}->z]",
            "Association[Rule[a, z], Rule[b, 2], Rule[c, z]]"},
    };
    for (const auto& [source, expected] : structural_selector_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "structural selector/path parity: " + source);

    const std::vector<std::pair<std::string, std::string>> conditional_same_q_cases{
        {"DeleteCases[{a,b,c},x_ /; x===b]", "List[a, c]"},
        {"DeleteCases[{a,b,c},x_ /; x===b,{0,Infinity}]", "List[a, c]"},
        {"Replace[{a,b,c},x_ /; x===b->z,{0,Infinity}]", "List[a, z, c]"},
        {"DeleteCases[f[a,b,c],x_ /; x===b]", "f[a, c]"},
        {"DeleteCases[f[a,b,c],x_ /; x===b,{0,Infinity}]", "f[a, c]"},
        {"Replace[f[a,b,c],x_ /; x===b->z,{0,Infinity}]", "f[a, z, c]"},
    };
    for (const auto& [source, expected] : conditional_same_q_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "conditional SameQ pattern parity: " + source);

    struct StructuralDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<StructuralDiagnosticCase> structural_diagnostic_cases{
        {"Part[{a,b,c},{0}]", "Part[List[a, b, c], List[0]]",
            "Part::error: Part does not support index 0 in this position."},
        {"Part[<|a->1,b->2,c->3|>,{{1},{3}}]",
            "Part[Association[Rule[a, 1], Rule[b, 2], Rule[c, 3]], List[List[1], List[3]]]",
            "Part::error: Unsupported selector inside Part specification: {{1}, {3}}."},
        {"Extract[{a,b,c},4]", "Extract[List[a, b, c], 4]",
            "Extract::error: Part specifications are invalid for {a, b, c}."},
        {"Extract[{a,b,c},All]", "Extract[List[a, b, c], All]",
            "Extract::error: Extract positions must be a position list or a list of position lists."},
        {"Delete[{a,b,c},0]", "Delete[List[a, b, c], 0]",
            "Delete::error: Position does not support index 0 in this position."},
        {"Delete[{a,b,c},4]", "Delete[List[a, b, c], 4]",
            "Delete::error: Delete positions are invalid for {a, b, c}."},
        {"Delete[{a,b,c},All]", "Delete[List[a, b, c], All]",
            "Delete::error: Unsupported position specification: All."},
        {"Delete[{a,b,c},Span[1,2]]", "Delete[List[a, b, c], Span[1, 2]]",
            "Delete::error: Unsupported position specification: ;; 2."},
        {"Insert[{a,b,c},z,5]", "Insert[List[a, b, c], z, 5]",
            "Insert::error: Insert positions are invalid for {a, b, c}."},
        {"Insert[{a,b,c},z,All]", "Insert[List[a, b, c], z, All]",
            "Insert::error: Insert expects an integer position, a position list, or a list of position lists."},
        {"ReplacePart[{a,b,c},0->z]", "ReplacePart[List[a, b, c], Rule[0, z]]",
            "ReplacePart::error: Position does not support index 0 in this position."},
        {"ReplacePart[{a,b,c},All->z]",
            "ReplacePart[List[a, b, c], Rule[All, z]]",
            "ReplacePart::error: Unsupported position specification: All."},
    };
    for (const auto& diagnostic : structural_diagnostic_cases) {
        Evaluator structural_diagnostics;
        check_equal(structural_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "structural failure remains inert: " + diagnostic.source);
        const auto function = diagnostic.source.substr(
            0, diagnostic.source.find('['));
        check_equal(structural_diagnostics.messages().empty() ? ""
                : structural_diagnostics.messages().front().to_full_form(),
            "MessageName[" + function + ", \"error\"]",
            "structural diagnostic message name: " + diagnostic.source);
        check_equal(structural_diagnostics.message_texts().empty() ? ""
                : structural_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "structural diagnostic text: " + diagnostic.source);
    }

    const std::vector<std::pair<std::string, std::string>> rounding_multiple_cases{
        {"Floor[-2.5,-2]", "-2"},
        {"Ceiling[.2,2]", "2"},
        {"Round[2.5,2]", "2"},
        {"Floor[3.7,.5]", "3.5"},
        {"Floor[3.7,0.5`20]", "3.5`20."},
    };
    for (const auto& [source, expected] : rounding_multiple_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "rounding multiple result type: " + source);

    check_equal(evaluate(parse_input_form("RankedMin[{3,1,2},2]")).to_full_form(),
        "2", "RankedMin selects a positive rank");
    check_equal(evaluate(parse_input_form(
        "RankedMax[<|a->3,b->1,c->2|>,-2]")).to_full_form(),
        "2", "RankedMax selects a negative rank from association values");

    struct RankedDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<RankedDiagnosticCase> ranked_diagnostic_cases{
        {"RankedMin[]", "RankedMin[]",
            "RankedMin::error: RankedMin expects a list and an integer rank."},
        {"RankedMax[x,1]", "RankedMax[x, 1]",
            "RankedMax::error: RankedMax expects a list or association."},
        {"RankedMin[{1,2},x]", "RankedMin[List[1, 2], x]",
            "RankedMin::error: RankedMin expects an explicit integer rank."},
        {"RankedMax[{},1]", "RankedMax[List[], 1]",
            "RankedMax::error: RankedMax requires a nonempty list."},
        {"RankedMin[{1,x},1]", "RankedMin[List[1, x], 1]",
            "RankedMin::error: RankedMin currently expects explicit real-valued numbers."},
        {"RankedMax[{1,2,3},4]", "RankedMax[List[1, 2, 3], 4]",
            "RankedMax::error: RankedMax rank 4 is out of range for a list of length 3."},
        {"RankedMin[{1,2,3},-5]", "RankedMin[List[1, 2, 3], -5]",
            "RankedMin::error: RankedMin rank -5 is out of range for a list of length 3."},
    };
    for (const auto& diagnostic : ranked_diagnostic_cases) {
        Evaluator ranked_diagnostics;
        check_equal(ranked_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "ranked selection failure remains inert: " + diagnostic.source);
        check_equal(ranked_diagnostics.messages().empty() ? ""
                : ranked_diagnostics.messages().front().to_full_form(),
            "MessageName[" + diagnostic.source.substr(0,
                diagnostic.source.find('[')) + ", \"error\"]",
            "ranked selection message name: " + diagnostic.source);
        check_equal(ranked_diagnostics.message_texts().empty() ? ""
                : ranked_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "ranked selection diagnostic: " + diagnostic.source);
    }

    const std::vector<std::pair<std::string, std::string>> take_drop_cases{
        {"Take[{a,b,c},{3,1,-1}]", "List[c, b, a]"},
        {"Drop[{a,b,c},{3,1,-1}]", "List[]"},
        {"Take[{a,b,c},{5,2}]", "List[]"},
        {"Drop[{a,b,c},{2,2,-1}]", "List[a, c]"},
        {"Take[{},0]", "List[]"},
        {"Take[g[a,b,c],None]", "g[]"},
        {"Drop[g[a,b,c],None]", "g[a, b, c]"},
        {"Take[g[g[a,b],g[c,d]],All,-1]", "g[g[b], g[d]]"},
        {"Drop[g[g[a,b],g[c,d]],None,1]", "g[g[b], g[d]]"},
        {"Take[Association[a->1,b->2,c->3],{3,1,-1}]",
            "Association[Rule[c, 3], Rule[b, 2], Rule[a, 1]]"},
        {"Drop[Association[a->1,b->2,c->3],{-1}]",
            "Association[Rule[a, 1], Rule[b, 2]]"},
        {"Take[{a,b,c},{x,y}]", "List[a, b, c]"},
        {"Take[{a,b,c},Span[All,1,-1]]", "List[c, b, a]"},
        {"Take[{a,b,c},{3,1,-9223372036854775808}]", "List[c]"},
    };
    for (const auto& [source, expected] : take_drop_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "Take/Drop selector parity: " + source);

    Evaluator take_drop_diagnostics;
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},4]")).to_full_form(), "Take[List[a, b, c], 4]",
        "Take out-of-range count remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Part index 4 is out of range for length 3.",
        "Take out-of-range count diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},-4]")).to_full_form(), "Take[List[a, b, c], -4]",
        "Take negative out-of-range count remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Only top-level Part specifications may use index 0.",
        "Take negative out-of-range diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},UpTo[5]]")).to_full_form(),
        "Take[List[a, b, c], UpTo[5]]", "unsupported Take UpTo remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Unsupported Take specification: 'UpTo[5]'.",
        "unsupported Take UpTo diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[g[a,b],1,All]")).to_full_form(), "Take[g[a, b], 1, All]",
        "Take multi-axis failure rolls back the complete call");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Take expects a nonatomic expression.",
        "Take multi-axis atomic-child diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},999999999999999999999999999999999]")).to_full_form(),
        "Take[List[a, b, c], 999999999999999999999999999999999]",
        "Take arbitrary-width count remains safe and inert");

    const std::vector<std::pair<std::string, std::string>> polynomial_boundary_cases{
        {"ToExpression[\"f[a]\", InputForm, List]", "List[f[a]]"},
        {"Coefficient[2 x^2 y + 3 x y + y, x, 1]", "Times[3, y]"},
        {"CoefficientList[x y + 2 y + 3, {x, y}]", "List[List[3, 2], List[0, 1]]"},
        {"Factor[2 x y + 2 y]", "Times[2, y, Plus[1, x]]"},
        {"Decompose[(x^2 + I x + 1)^2, x]",
            "List[Plus[1, Power[x, 2], Times[2, x]], Plus[Power[x, 2], Times[Complex[0, 1], x]]]"},
        {"Expand[(x + 1)^3]",
            "Plus[1, Power[x, 3], Times[3, x], Times[3, Power[x, 2]]]"},
        {"Expand[(x + 1)^2 (y + 1)^2, x]",
            "Plus[Power[Plus[1, y], 2], Times[2, x, Power[Plus[1, y], 2]], Times[Power[x, 2], Power[Plus[1, y], 2]]]"},
        {"Expand[(x + 1)^2 (y + 1)^2, _Plus]",
            "Plus[1, Power[x, 2], Power[y, 2], Times[2, x], Times[2, x, Power[y, 2]], Times[2, y], Times[2, y, Power[x, 2]], Times[4, x, y], Times[Power[x, 2], Power[y, 2]]]"},
    };
    for (const auto& [source, expected] : polynomial_boundary_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "expanded polynomial boundary: " + source);

    struct OperatorSurfaceExpectation {
        std::string head;
        std::string escaped;
        std::string tex;
        std::string mathml;
    };
    const std::vector<OperatorSurfaceExpectation> operator_surfaces{
        {"CirclePlus", R"(\[CirclePlus])", R"(\oplus)", "&#8853;"},
        {"CircleTimes", R"(\[CircleTimes])", R"(\otimes)", "&#8855;"},
        {"Diamond", R"(\[Diamond])", R"(\diamond)", "&#8900;"},
    };
    auto operator_row_matches = [](const Expr& boxes, const std::string& token) {
        return boxes.has_head("RowBox") && boxes.args().size() == 1
            && boxes.args()[0].has_head("List") && boxes.args()[0].args().size() == 3
            && boxes.args()[0].args()[1].kind() == ExprKind::String
            && boxes.args()[0].args()[1].text() == token;
    };
    for (const auto& surface : operator_surfaces) {
        const auto expression_source = surface.head + "[a, b]";
        const auto tex = evaluate(parse_input_form(
            "ToString[" + expression_source + ", TeXForm]"));
        check(tex.kind() == ExprKind::String && tex.text() == "a" + surface.tex + " b",
            surface.head + " TeX operator rendering");
        const auto mathml = evaluate(parse_input_form(
            "ToString[" + expression_source + ", MathMLForm]"));
        check(mathml.kind() == ExprKind::String
                && mathml.text().find(surface.mathml) != std::string::npos,
            surface.head + " MathML operator rendering");
        const auto traditional = evaluate(parse_input_form(
            "ToString[" + expression_source + ", TraditionalForm]"));
        check(traditional.kind() == ExprKind::String
                && traditional.text().find(surface.escaped) != std::string::npos,
            surface.head + " TraditionalForm operator rendering");
        const auto standard_boxes_value = evaluate(parse_input_form(
            "ToBoxes[" + expression_source + ", StandardForm]"));
        check(operator_row_matches(standard_boxes_value, surface.escaped),
            surface.head + " StandardForm operator boxes");
        const auto made_traditional = evaluate(parse_input_form(
            "MakeBoxes[" + expression_source + ", TraditionalForm]"));
        check(operator_row_matches(made_traditional, surface.escaped),
            surface.head + " MakeBoxes TraditionalForm operator boxes");
        const auto traditional_boxes_value = evaluate(parse_input_form(
            "ToBoxes[" + expression_source + ", TraditionalForm]"));
        check(traditional_boxes_value.has_head("FormBox")
                && traditional_boxes_value.args().size() == 2
                && operator_row_matches(traditional_boxes_value.args()[0], surface.escaped)
                && traditional_boxes_value.args()[1] == symbol("TraditionalForm"),
            surface.head + " ToBoxes TraditionalForm wrapper");
        const auto tex_round_trip = evaluate(parse_input_form(
            "ToExpression[" + wl_string("a" + surface.tex + " b")
                + ", TeXForm, HoldComplete]"));
        check_equal(tex_round_trip.to_full_form(),
            "HoldComplete[" + surface.head + "[a, b]]",
            surface.head + " TeX operator round trip");
    }

    const auto printable_alpha = evaluate(parse_input_form(
        R"WL(ToString["\[Alpha]", InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_alpha.kind() == ExprKind::String
            && printable_alpha.text() == R"WL("\[Alpha]")WL",
        "PrintableASCII named Alpha rendering");
    const auto printable_formal = evaluate(parse_input_form(
        R"WL(ToString["\[FormalA]", InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_formal.kind() == ExprKind::String
            && printable_formal.text() == R"WL("\[FormalA]")WL",
        "PrintableASCII formal character rendering");
    const auto printable_controls = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{0, 7, 8, 9, 10, 11, 12, 13, 27, 31, 127}], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_controls.kind() == ExprKind::String
            && printable_controls.text() == R"WL("\000\007\b\t\n\013\f\r\[RawEscape]\037\177")WL",
        "PrintableASCII control escapes");
    const auto printable_invalid_ascii = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{162}, "ASCII"], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_invalid_ascii.kind() == ExprKind::String
            && printable_invalid_ascii.text() == R"WL("\:f2a2")WL",
        "ASCII invalid byte private-use mapping");
    const auto printable_mixed_utf8 = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{195, 169, 945}, "UTF-8"], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_mixed_utf8.kind() == ExprKind::String
            && printable_mixed_utf8.text() == R"WL("\[EAcute]\[Alpha]")WL",
        "mixed UTF-8 bytes and Unicode code points");
    const auto format_type = evaluate(parse_input_form(
        "ToString[1 + x, FormatType -> TraditionalForm]"));
    check(format_type.kind() == ExprKind::String
            && format_type.text().find("TraditionalForm") != std::string::npos,
        "ToString FormatType option");
    const auto c_form_boxes = evaluate(parse_input_form("ToBoxes[CForm[x^2]]"));
    check(c_form_boxes.has_head("InterpretationBox") && c_form_boxes.args().size() == 4
            && c_form_boxes.args()[0].kind() == ExprKind::String
            && c_form_boxes.args()[0].text() == "Power(x,2)"
            && c_form_boxes.args()[1].has_head("CForm"),
        "CForm InterpretationBox surface");
    const auto mathml_form_boxes = evaluate(parse_input_form("ToBoxes[MathMLForm[1 + x]]"));
    check(mathml_form_boxes.has_head("InterpretationBox")
            && mathml_form_boxes.args().size() == 4
            && mathml_form_boxes.args()[0].kind() == ExprKind::String
            && mathml_form_boxes.args()[0].text().find("<math>") != std::string::npos
            && mathml_form_boxes.args()[1] == call("Plus", {integer(1L), symbol("x")}),
        "MathMLForm InterpretationBox surface");

    const auto shaped_tuples = evaluate(parse_input_form("Tuples[{1, 2}, {2, 3}]"));
    check(shaped_tuples.has_head("List") && shaped_tuples.args().size() == 64,
        "shaped Tuples has 64 outer combinations");
    check(shaped_tuples.has_head("List") && !shaped_tuples.args().empty()
            && shaped_tuples.args().front().to_full_form()
                == "List[List[1, 1, 1], List[1, 1, 1]]"
            && shaped_tuples.args().back().to_full_form()
                == "List[List[2, 2, 2], List[2, 2, 2]]",
        "shaped Tuples preserves tensor shape and lexical endpoints");

    check_equal(stateful.evaluate(parse_input_form("Protect[tungstenProtected]")).to_full_form(),
        "List[\"tungstenProtected\"]", "Protect reports a newly protected symbol");
    check_equal(stateful.evaluate(parse_input_form("tungstenProtected = 5")).to_full_form(),
        "Set[tungstenProtected, 5]", "Set leaves a protected assignment inert");
    check_equal(stateful.messages().empty() ? "" : stateful.messages().front().to_full_form(),
        "MessageName[Set, \"wrsym\"]", "protected Set message name");
    check_equal(stateful.message_texts().empty() ? "" : stateful.message_texts().front(),
        "Set::wrsym: Symbol tungstenProtected is Protected.", "protected Set message text");
    check_equal(stateful.evaluate(parse_input_form("Unprotect[tungstenProtected]")).to_full_form(),
        "List[\"tungstenProtected\"]", "Unprotect reports a changed symbol");
    check_equal(stateful.evaluate(parse_input_form("tungstenProtected = 5")).to_full_form(),
        "5", "Unprotect enables assignment");
    check_equal(stateful.evaluate(parse_input_form("SetAttributes[tungstenLocked, Locked]")).to_full_form(),
        "Null", "Locked attribute setup");
    check_equal(stateful.evaluate(parse_input_form("SetAttributes[tungstenLocked, HoldAll]")).to_full_form(),
        "Null", "locked attribute mutation returns Null");
    check_equal(stateful.messages().empty() ? "" : stateful.messages().front().to_full_form(),
        "MessageName[Attributes, \"locked\"]", "locked attribute message name");
    check_equal(stateful.evaluate(parse_input_form("Attributes[tungstenLocked]")).to_full_form(),
        "List[Locked]", "Locked prevents later attribute changes");
    check_equal(stateful.evaluate(parse_input_form("Plus = 5")).to_full_form(),
        "Set[Plus, 5]", "built-in Protected attribute blocks Set");
    check_equal(stateful.evaluate(parse_input_form("Plus = .")).to_full_form(),
        "$Failed", "built-in Protected attribute blocks Unset");
    check_equal(stateful.evaluate(parse_input_form("Clear[Plus]")).to_full_form(),
        "Null", "Clear of a protected symbol returns Null");
    check_equal(stateful.evaluate(parse_input_form("1 + 2")).to_full_form(),
        "3", "protected mutation attempts preserve built-ins");

    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ expression tests passed\n";
    return EXIT_SUCCESS;
}
