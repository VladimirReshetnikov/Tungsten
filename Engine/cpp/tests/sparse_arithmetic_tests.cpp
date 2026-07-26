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
        for (const auto& message : actual_messages)
            std::cerr << "  actual: " << message << '\n';
        ++failures;
    }
    if (evaluated.prints != expected_prints) {
        std::cerr << "FAIL: " << source << " prints\n";
        ++failures;
    }
}

void constructor_success_tests() {
    check_case(
        "ArrayRules[SparseArray[{{0,1},{2,0}}]]",
        "List[Rule[List[1, 2], 1], Rule[List[2, 1], 2], "
        "Rule[List[Blank[], Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[Automatic,3,z]]",
        "List[Rule[List[Blank[]], z]]");
    check_case(
        "Dimensions[SparseArray[Automatic,{2,3},z]]",
        "List[2, 3]");
    check_case(
        "ArrayRules[SparseArray[1->a]]",
        "List[Rule[List[1], a], Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{1,3}->{a,b}]]",
        "List[Rule[List[1], a], Rule[List[3], b], "
        "Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{{1,2},{2,1}}->{a,b}]]",
        "List[Rule[List[1, 2], a], Rule[List[2, 1], b], "
        "Rule[List[Blank[], Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{1,2}->{a,b},{2,2}]]",
        "List[Rule[List[1, 2], List[a, b]], "
        "Rule[List[Blank[], Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->z,{1}->a,{2}->b},{3},z]]",
        "List[Rule[List[2], b], Rule[List[Blank[]], z]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a,{1}->b},{1}]]",
        "List[Rule[List[1], a], Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a,2},{2}]]",
        "List[Rule[List[1], Rule[List[1], a]], Rule[List[2], 2], "
        "Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{}, {0,4294967296},z]]",
        "List[Rule[List[Blank[], Blank[]], z]]");
}

void existing_sparse_constructor_tests() {
    check_case(
        "ArrayRules[SparseArray[SparseArray[{{1}->a},{3}],3]]",
        "List[Rule[List[1], a], Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[SparseArray[{{1}->a},{3},z],{3},q]]",
        "List[Rule[List[1], a], Rule[List[2], z], Rule[List[3], z], "
        "Rule[List[Blank[]], q]]");
    check_case(
        "ArrayRules[SparseArray[SparseArray[{}, {0,3},z],{0,3},q]]",
        "List[Rule[List[Blank[], Blank[]], q]]");
}

void constructor_diagnostic_tests() {
    check_case(
        "SparseArray[]", "SparseArray[]",
        {"SparseArray::error: SparseArray expects data, optional dimensions, "
         "and an optional implicit value."});
    check_case(
        "SparseArray[{}]", "SparseArray[List[]]",
        {"SparseArray::error: SparseArray dimensions cannot be inferred from "
         "an empty rule set."});
    check_case(
        "SparseArray[Automatic]", "SparseArray[Automatic]",
        {"SparseArray::error: SparseArray expects a rule specification or a "
         "rectangular dense list."});
    check_case(
        "SparseArray[{{1}->a},x]",
        "SparseArray[List[Rule[List[1], a]], x]",
        {"SparseArray::error: SparseArray expects an integer dimension or a "
         "list of dimensions."});
    check_case(
        "SparseArray[{{1}->a},{x}]",
        "SparseArray[List[Rule[List[1], a]], List[x]]",
        {"SparseArray::error: SparseArray expects an integer argument."});
    check_case(
        "SparseArray[{{1}->a},-1]",
        "SparseArray[List[Rule[List[1], a]], -1]",
        {"SparseArray::error: SparseArray expects non-negative dimensions."});
    check_case(
        "SparseArray[-1->a]", "SparseArray[Rule[-1, a]]",
        {"SparseArray::error: SparseArray dimensions must be non-negative."});
    check_case(
        "SparseArray[{{1}->a},{}]",
        "SparseArray[List[Rule[List[1], a]], List[]]",
        {"SparseArray::error: SparseArray currently supports explicit integer "
         "positions, not patterns or Band."});
    check_case(
        "SparseArray[{{1}->a,{1,2}->b}]",
        "SparseArray[List[Rule[List[1], a], Rule[List[1, 2], b]]]",
        {"SparseArray::error: SparseArray rule positions must have a "
         "consistent rank."});
    check_case(
        "SparseArray[{{1,2}->{a}},{2,2}]",
        "SparseArray[List[Rule[List[1, 2], List[a]]], List[2, 2]]",
        {"SparseArray::error: SparseArray position and value lists must have "
         "the same length."});
    check_case(
        "SparseArray[{{0}->a},{1}]",
        "SparseArray[List[Rule[List[0], a]], List[1]]",
        {"SparseArray::error: SparseArray rule positions must be inside the "
         "array dimensions."});
    check_case(
        "SparseArray[{{1,2}->a},{2}]",
        "SparseArray[List[Rule[List[1, 2], a]], List[2]]",
        {"SparseArray::error: SparseArray currently supports explicit integer "
         "positions, not patterns or Band."});
    check_case(
        "SparseArray[{{1},{2,3}}]",
        "SparseArray[List[List[1], List[2, 3]]]",
        {"SparseArray::error: SparseArray dense input must be rectangular."});
    check_case(
        "SparseArray[{{1,2},{3,4}},{4}]",
        "SparseArray[List[List[1, 2], List[3, 4]], List[4]]",
        {"SparseArray::error: SparseArray dense input dimensions do not match "
         "the explicit dimensions."});
    check_case(
        "SparseArray[SparseArray[{{1}->a},{3}],{2}]",
        "SparseArray[SparseArray[List[Rule[List[1], a]], List[3]], List[2]]",
        {"SparseArray::error: SparseArray cannot reinterpret an existing "
         "sparse array with different dimensions."});
}

void sparse_elementwise_arithmetic_tests() {
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3},z]+"
        "SparseArray[{{2}->b},{3},q]]",
        "List[Rule[List[1], Plus[a, q]], Rule[List[2], Plus[b, z]], "
        "Rule[List[Blank[]], Plus[q, z]]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3},1]+"
        "SparseArray[{{1}->2,{2}->b},{3},3]]",
        "List[Rule[List[1], Plus[2, a]], Rule[List[2], Plus[1, b]], "
        "Rule[List[Blank[]], 4]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3},z]+q]",
        "List[Rule[List[1], Plus[a, q]], "
        "Rule[List[Blank[]], Plus[q, z]]]");
    check_case(
        "ArrayRules[2 SparseArray[{{1}->a},{3},z]]",
        "List[Rule[List[1], Times[2, a]], "
        "Rule[List[Blank[]], Times[2, z]]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3}]+"
        "SparseArray[{{2}->b},{3}]+1]",
        "List[Rule[List[1], Plus[1, a]], Rule[List[2], Plus[1, b]], "
        "Rule[List[Blank[]], 1]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->1},{3}]-1]",
        "List[Rule[List[1], 0], Rule[List[Blank[]], -1]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->2},{3},1]*0]",
        "List[Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->2},{3},1]*"
        "SparseArray[{{2}->3},{3},2]]",
        "List[Rule[List[1], 4], Rule[List[2], 3], "
        "Rule[List[Blank[]], 2]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3},z]*"
        "SparseArray[{{1}->b,{2}->c},{3},q]*r]",
        "List[Rule[List[1], Times[a, b, r]], "
        "Rule[List[2], Times[c, r, z]], "
        "Rule[List[Blank[]], Times[q, r, z]]]");
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{3},z]+"
        "SparseArray[{{1}->-a},{3},-z]]",
        "List[Rule[List[Blank[]], 0]]");
    check_case(
        "ArrayRules[Plus[SparseArray[{{1}->a},{3},z]]]",
        "List[Rule[List[1], a], Rule[List[Blank[]], z]]");
    check_case(
        "ArrayRules[Times[SparseArray[{{1}->a},{3},z]]]",
        "List[Rule[List[1], a], Rule[List[Blank[]], z]]");
}

void sparse_arithmetic_shape_and_scale_tests() {
    check_case(
        "ArrayRules[SparseArray[{{1}->a},{4294967296},z]+"
        "SparseArray[{{4294967296}->b},{4294967296},q]+r]",
        "List[Rule[List[1], Plus[a, q, r]], "
        "Rule[List[4294967296], Plus[b, r, z]], "
        "Rule[List[Blank[]], Plus[q, r, z]]]");
    check_case(
        "ArrayRules[SparseArray[{{1,1}->a},"
        "{4294967296,4294967296},z]+"
        "SparseArray[{{4294967296,4294967296}->b},"
        "{4294967296,4294967296},q]]",
        "List[Rule[List[1, 1], Plus[a, q]], "
        "Rule[List[4294967296, 4294967296], Plus[b, z]], "
        "Rule[List[Blank[], Blank[]], Plus[q, z]]]");
    check_case(
        "{1,2}+SparseArray[{{1}->a},{4294967296},z]",
        "List[SparseArray[List[Rule[List[1], Plus[1, a]]], "
        "List[4294967296], Plus[1, z]], "
        "SparseArray[List[Rule[List[1], Plus[2, a]]], "
        "List[4294967296], Plus[2, z]]]");
    check_case(
        "SparseArray[{{1}->a},{3},z]+SparseArray[{{1}->b},{4},q]",
        "Plus[SparseArray[List[Rule[List[1], a]], List[3], z], "
        "SparseArray[List[Rule[List[1], b]], List[4], q]]",
        {"Plus::error: Plus expects SparseArray dimensions to agree."});
}

} // namespace

int main() {
    constructor_success_tests();
    existing_sparse_constructor_tests();
    constructor_diagnostic_tests();
    sparse_elementwise_arithmetic_tests();
    sparse_arithmetic_shape_and_scale_tests();
    if (failures != 0)
        std::cerr << failures << " sparse-arithmetic test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
