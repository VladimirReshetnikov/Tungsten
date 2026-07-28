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
    std::vector<std::string> expected_messages = {}) {
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
}

void reshape_tests() {
    check_case(
        "ArrayReshape[SparseArray[{}, {18446744073709551616}],"
        "{2,9223372036854775808}]",
        "SparseArray[List[], List[2, 9223372036854775808]]");
    check_case(
        "ArrayReshape[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],{2,9223372036854775808}]",
        "SparseArray[List[Rule[List[2, 9223372036854775808], a]], "
        "List[2, 9223372036854775808]]");
    check_case(
        "ArrayReshape[SparseArray[{{1}->a,{4}->d},{5}],{2,3}]",
        "SparseArray[List[Rule[List[1, 1], a], Rule[List[2, 1], d]], "
        "List[2, 3]]");
    check_case(
        "ArrayReshape[SparseArray[{{1}->a,{4}->d},{5}],{2,3},x]",
        "List[List[a, 0, 0], List[d, 0, x]]");
    check_case(
        "ArrayReshape[SparseArray[{{1000000000}->a},{1000000000}],"
        "{1000000,1000}]",
        "SparseArray[List[Rule[List[1000000, 1000], a]], "
        "List[1000000, 1000]]");
    check_case(
        "ArrayReshape[SparseArray[{}, {0},z],{}]", "0");
}

void padding_and_transpose_tests() {
    check_case(
        "ArrayPad[SparseArray[{}, {18446744073709551616}],1]",
        "SparseArray[List[], List[18446744073709551618]]");
    check_case(
        "ArrayPad[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],1]",
        "SparseArray[List[Rule[List[18446744073709551617], a]], "
        "List[18446744073709551618]]");
    check_case(
        "Transpose[SparseArray[{}, {18446744073709551616,2}]]",
        "SparseArray[List[], List[2, 18446744073709551616]]");
    check_case(
        "Transpose[SparseArray[{{18446744073709551616,2}->a},"
        "{18446744073709551616,2}]]",
        "SparseArray[List[Rule[List[2, 18446744073709551616], a]], "
        "List[2, 18446744073709551616]]");
    check_case(
        "ArrayPad[SparseArray[{{1,1}->a,{2,3}->f},{2,3}],"
        "{{1,0},{2,3}},0]",
        "SparseArray[List[Rule[List[2, 3], a], Rule[List[3, 5], f]], "
        "List[3, 8]]");
    check_case(
        "ArrayPad[SparseArray[{{1}->a,{4}->d},{5}],{1,2},x]",
        "List[x, a, 0, 0, d, 0, x, x]");
    check_case(
        "Transpose[SparseArray[{{1,1,2}->x,{2,3,4}->y},"
        "{2,3,4},z],{3,1,2}]",
        "SparseArray[List[Rule[List[2, 1, 1], x], "
        "Rule[List[4, 2, 3], y]], List[4, 2, 3], z]");
    check_case(
        "Transpose[SparseArray[{{1,1000000000}->a},"
        "{1000000000,1000000000}]]",
        "SparseArray[List[Rule[List[1000000000, 1], a]], "
        "List[1000000000, 1000000000]]");
}

void flatten_tests() {
    check_case(
        "Flatten[SparseArray[{}, {18446744073709551616,2}]]",
        "SparseArray[List[], List[36893488147419103232]]");
    check_case(
        "Flatten[SparseArray[{{18446744073709551616,2}->a},"
        "{18446744073709551616,2}]]",
        "SparseArray[List[Rule[List[36893488147419103232], a]], "
        "List[36893488147419103232]]");
    check_case(
        "Flatten[SparseArray[{{1,1,2}->x,{2,3,4}->y},{2,3,4},z],1]",
        "SparseArray[List[Rule[List[1, 2], x], Rule[List[6, 4], y]], "
        "List[6, 4], z]");
    check_case(
        "Flatten[SparseArray[{{1,1}->a},{1000000000,1000000000}]]",
        "SparseArray[List[Rule[List[1], a]], List[1000000000000000000]]");
    check_case(
        "Flatten[SparseArray[{{1}->a},{2}],1,List]",
        "Flatten[SparseArray[List[Rule[List[1], a]], List[2]], 1, List]",
        {"Flatten::error: Flatten currently does not implement the "
         "3-argument head-selecting form for SparseArray inputs."});
}

void block_tests() {
    check_case(
        "ArrayFlatten[{{SparseArray[{{1,1}->a},{2,2}],{{b},{c}}}}]",
        "SparseArray[List[Rule[List[1, 1], a], Rule[List[1, 3], b], "
        "Rule[List[2, 3], c]], List[2, 3]]");
    check_case(
        "ArrayFlatten[{{SparseArray[{{1,1}->a},{2,2},z]}}]",
        "List[List[a, z], List[z, z]]");
    check_case(
        "ArrayFlatten[{{SparseArray[{{1,1}->a},{1000000000,1}],"
        "SparseArray[{{1000000000,1}->b},{1000000000,1}]}}]",
        "SparseArray[List[Rule[List[1, 1], a], "
        "Rule[List[1000000000, 2], b]], List[1000000000, 2]]");
    check_case(
        "ArrayFlatten[{{SparseArray[{{18446744073709551616,1}->a},"
        "{18446744073709551616,1}],"
        "SparseArray[{{18446744073709551616,1}->b},"
        "{18446744073709551616,1}]}}]",
        "SparseArray[List[Rule[List[18446744073709551616, 1], a], "
        "Rule[List[18446744073709551616, 2], b]], "
        "List[18446744073709551616, 2]]");
}

void insert_tests() {
    check_case(
        "Insert[SparseArray[{{18446744073709551616}->a},"
        "{18446744073709551616}],z,18446744073709551616]",
        "SparseArray[List[Rule[List[18446744073709551616], z], "
        "Rule[List[18446744073709551617], a]], "
        "List[18446744073709551617]]");
}

void extract_tests() {
    check_case(
        "Extract[SparseArray[{{1}->a,{4}->d},{5}],{{4},{1},{2}}]",
        "List[d, a, 0]");
    check_case(
        "Extract[SparseArray[{{1,1}->a,{2,3}->f},{2,3}],{All,2}]",
        "SparseArray[List[], List[2]]");
    check_case(
        "Extract[SparseArray[{{1}->a},{1000000000}],{1000000000}]",
        "0");
}

} // namespace

int main() {
    reshape_tests();
    padding_and_transpose_tests();
    flatten_tests();
    block_tests();
    insert_tests();
    extract_tests();
    if (failures != 0)
        std::cerr << failures << " sparse-transform test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
