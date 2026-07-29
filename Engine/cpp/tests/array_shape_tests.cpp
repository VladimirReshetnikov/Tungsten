#include "tungsten/evaluator.hpp"
#include "tungsten/parser.hpp"

#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check_case(
    const std::string& source, const std::string& expected_result,
    std::vector<std::string> expected_messages = {},
    std::vector<std::string> expected_prints = {}) {
    tungsten::Evaluator evaluator;
    const auto evaluated = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    if (evaluated.result.to_full_form() != expected_result) {
        std::cerr << "FAIL: " << source << " result\n  expected: "
                  << expected_result << "\n  actual:   "
                  << evaluated.result.to_full_form() << '\n';
        ++failures;
    }

    std::vector<std::string> actual_messages;
    for (const auto& message : evaluated.messages)
        actual_messages.push_back(message.text);
    if (actual_messages != expected_messages) {
        std::cerr << "FAIL: " << source << " messages\n";
        ++failures;
    }
    if (evaluated.prints != expected_prints) {
        std::cerr << "FAIL: " << source << " prints\n";
        ++failures;
    }
}

void dense_shape_tests() {
    check_case("Dimensions[{{1,2},{3,4}}]", "List[2, 2]");
    check_case("Dimensions[{{1,2},{3}}]", "List[2]");
    check_case("Dimensions[{{{1}},{{2,3}}}]", "List[2, 1]");
    check_case(
        "Dimensions[{SparseArray[{}, {2,3}],SparseArray[{}, {2,3}]}]",
        "List[2]");
    check_case("Dimensions[f[a,b]]", "List[]");
    check_case("ArrayDepth[{{{1}},2}]", "3");
    check_case("ArrayDepth[{SparseArray[{}, {2,3}]}]", "3");
    check_case("ArrayQ[5]", "False");
    check_case("ArrayQ[f[a,b]]", "False");
    check_case("ArrayQ[Association[a->1]]", "False");
    check_case("ArrayQ[{{1},{2,3}}]", "False");
    check_case("VectorQ[{}]", "True");
    check_case("VectorQ[{f[a]}]", "True");
    check_case("MatrixQ[{}]", "False");
    check_case("MatrixQ[{{}}]", "True");
}

void sparse_shape_tests() {
    check_case(
        "Dimensions[SparseArray[{}, {18446744073709551616}]]",
        "List[18446744073709551616]");
    check_case(
        "Length[SparseArray[{}, {18446744073709551616}]]",
        "18446744073709551616");
    check_case(
        "Length[SparseArray[{}, {2,18446744073709551616}]]", "2");
    check_case(
        "AtomQ[SparseArray[{}, {18446744073709551616}]]", "True");
    check_case(
        "SparseArrayQ[SparseArray[{}, {18446744073709551616}]]", "True");
    check_case(
        "Dimensions[SparseArray[{}, {4294967296,4294967296}]]",
        "List[4294967296, 4294967296]");
    check_case(
        "ArrayDepth[SparseArray[{}, {0,1000000000}]]", "2");
    check_case(
        "ArrayQ[SparseArray[{}, {0,1000000000}],2,OddQ]", "True");
    check_case(
        "MatrixQ[SparseArray[{}, {0,1000000000}],OddQ]", "True");
    check_case(
        "MatrixQ[SparseArray[{}, {4294967296,4294967296}],OddQ]",
        "False");
    check_case(
        "SparseArray[{{1,1}->1},{4294967296,4294967296}]"
        "[\"Density\"]",
        "Rational[1, 18446744073709551616]");
    check_case(
        "SparseArray[{{2}->a,{1}->b},{3},z][\"ImplicitValue\"]",
        "z");
    check_case(
        "SparseArray[{{2}->a,{1}->b},{3},z][\"ExplicitLength\"]",
        "2");
    check_case(
        "SparseArray[{{2}->a,{1}->b},{3},z][\"ExplicitValues\"]",
        "List[b, a]");
    check_case(
        "SparseArray[{{2}->a,{1}->b},{3},z][\"ExplicitPositions\"]",
        "List[List[1], List[2]]");
    check_case(
        "SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}][\"ExplicitPositions\"]",
        "List[List[18446744073709551616]]");
    check_case(
        "SparseArray[{}, {0,1000000000},z][\"ExplicitLength\"]",
        "0");
    check_case(
        "SparseArray[{}, {0,1000000000},z][\"ExplicitValues\"]",
        "List[]");
}

void predicate_and_message_tests() {
    check_case(
        "ArrayQ[{{1,2},{3,4}},2,"
        "Function[x,Print[InputForm[x]];IntegerQ[x]]]",
        "True", {}, {"1", "2", "3", "4"});
    check_case(
        "ArrayQ[SparseArray[{{2}->a},{3}],1,"
        "Function[x,Print[InputForm[x]];True]]",
        "True", {}, {"0", "a"});
    check_case(
        "ArrayQ[{{1}},foo]", "ArrayQ[List[List[1]], foo]",
        {"ArrayQ::error: ArrayQ currently expects an explicit integer depth."});
    check_case(
        "ArrayQ[]", "ArrayQ[]",
        {"ArrayQ::error: ArrayQ expects an expression, optional depth, and optional element test."});
    check_case(
        "VectorQ[]", "VectorQ[]",
        {"VectorQ::error: VectorQ expects an expression and an optional element predicate."});
    check_case(
        "MatrixQ[{{1}},IntegerQ,x]",
        "MatrixQ[List[List[1]], IntegerQ, x]",
        {"MatrixQ::error: MatrixQ expects an expression and an optional element predicate."});
    check_case(
        "Dimensions[]", "Dimensions[]",
        {"Dimensions::error: Dimensions expects exactly one argument."});
    check_case(
        "ArrayDepth[]", "ArrayDepth[]",
        {"ArrayDepth::error: ArrayDepth expects exactly one argument."});
    check_case(
        "SparseArray[{{2}->a},{3},z][bad]",
        "SparseArray[List[Rule[List[2], a]], List[3], z][bad]",
        {"General::error: SparseArray properties must be requested by string name."});
    check_case(
        "SparseArray[{{2}->a},{3},z][\"Unknown\"]",
        "SparseArray[List[Rule[List[2], a]], List[3], z][\"Unknown\"]",
        {"General::error: Unsupported SparseArray property: Unknown."});
}

void materialization_guard_tests() {
    check_case(
        "Normal[SparseArray[{}, {18446744073709551616}]]",
        "Normal[SparseArray[List[], List[18446744073709551616]]]",
        {"Normal::error: SparseArray dimensions exceed the native materialization limit."});
    check_case(
        "Part[SparseArray[{}, {18446744073709551616}],"
        "18446744073709551616]",
        "0");
    check_case(
        "Part[SparseArray[{}, {18446744073709551616}],-1]", "0");
    check_case(
        "Part[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],18446744073709551616]",
        "a");
    check_case(
        "Part[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],-1]",
        "a");
    check_case(
        "Part[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],All]",
        "SparseArray[List[Rule[List[18446744073709551616], a]], "
        "List[18446744073709551616]]");
    check_case(
        "Part[SparseArray[{}, {18446744073709551616}],"
        "18446744073709551617]",
        "Part[SparseArray[List[], List[18446744073709551616]], "
        "18446744073709551617]",
        {"Part::error: Part specifications are invalid for SparseArray."});
    check_case(
        "Normal[SparseArray[{}, {4294967296}]]",
        "Normal[SparseArray[List[], List[4294967296]]]",
        {"Normal::error: SparseArray dimensions exceed the native materialization limit."});
    check_case(
        "Part[SparseArray[{}, {4294967296}],1]",
        "0");
    check_case(
        "Normal[SparseArray[{}, {0,1000000000}]]", "List[]");
}

} // namespace

int main() {
    dense_shape_tests();
    sparse_shape_tests();
    predicate_and_message_tests();
    materialization_guard_tests();
    if (failures != 0)
        std::cerr << failures << " array-shape test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
