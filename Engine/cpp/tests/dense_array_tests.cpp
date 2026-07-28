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

void constructor_tests() {
    check_case(
        "ArrayReshape[{{1,2},{3,{4,5}}},{2,3},x]",
        "List[List[1, 2, 3], List[4, 5, x]]");
    check_case("ArrayReshape[{1},{}]", "1");
    check_case("ArrayReshape[{},3,Nothing]", "List[]");
    check_case(
        "ArrayReshape[{a},x]", "ArrayReshape[List[a], x]",
        {"ArrayReshape::error: ArrayReshape expects an integer dimension or a list of dimensions."});
    check_case(
        "ArrayReshape[{a},1000000]", "ArrayReshape[List[a], 1000000]",
        {"ArrayReshape::error: ArrayReshape output exceeds the native materialization limit."});

    check_case("ConstantArray[x,{2,2}]", "List[List[x, x], List[x, x]]");
    check_case("ConstantArray[x,{}]", "x");
    check_case("ConstantArray[Nothing,{2,2}]", "List[List[], List[]]");
    check_case(
        "ConstantArray[x,{0,999999999999999999999999999}]", "List[]");
    check_case(
        "ConstantArray[x,-1]", "ConstantArray[x, -1]",
        {"ConstantArray::error: ConstantArray expects non-negative dimensions."});
    check_case(
        "ConstantArray[x,1000000]", "ConstantArray[x, 1000000]",
        {"ConstantArray::error: ConstantArray output exceeds the native materialization limit."});

    check_case(
        "Array[f,{2,2},{0,10}]",
        "List[List[f[0, 10], f[0, 11]], List[f[1, 10], f[1, 11]]]");
    check_case("Array[f,3,{5,99}]", "List[f[5], f[6], f[7]]");
    check_case("Array[f,{}]", "f[]");
    check_case(
        "Array[(Print[InputForm[#]];#)&,3]", "List[1, 2, 3]", {},
        {"1", "2", "3"});
    check_case(
        "Array[f,{2,2},{0}]", "Array[f, List[2, 2], List[0]]",
        {"Array::error: Array origin list must have one entry per array dimension."});
    check_case(
        "Array[f,1000000]", "Array[f, 1000000]",
        {"Array::error: Array output exceeds the native materialization limit."});
}

void padding_and_transpose_tests() {
    check_case(
        "ArrayPad[{{{a,b}}},{{1,0},{0,1},{2,0}},z]",
        "List[List[List[z, z, z, z], List[z, z, z, z]], "
        "List[List[z, z, a, b], List[z, z, z, z]]]");
    check_case(
        "ArrayPad[{{},{}} , {{1,0},{2,3}},x]",
        "List[List[x, x, x, x, x], List[x, x, x, x, x], "
        "List[x, x, x, x, x]]");
    check_case("ArrayPad[{a},1,Nothing]", "List[a]");
    check_case(
        "ArrayPad[{{1},{2,3}},1]",
        "ArrayPad[List[List[1], List[2, 3]], 1]",
        {"ArrayPad::error: SparseArray dense input must be rectangular."});
    check_case(
        "ArrayPad[{{a}},{{1,x},{2,2}}]",
        "ArrayPad[List[List[a]], List[List[1, x], List[2, 2]]]",
        {"ArrayPad::error: ArrayPad padding widths must be explicit integers."});
    check_case(
        "ArrayPad[{},1000000]", "ArrayPad[List[], 1000000]",
        {"ArrayPad::error: ArrayPad output exceeds the native materialization limit."});

    check_case("Transpose[{a,b}]", "List[a, b]");
    check_case(
        "Transpose[{{{1,2},{3,4}},{{5,6},{7,8}}},{3,1,2}]",
        "List[List[List[1, 3], List[5, 7]], "
        "List[List[2, 4], List[6, 8]]]");
    check_case("Transpose[{{},{}}]", "List[]");
    check_case(
        "Transpose[{{a}},{1,1}]", "Transpose[List[List[a]], List[1, 1]]",
        {"Transpose::error: Transpose expects a permutation of array axes."});
}

void flatten_and_levi_civita_tests() {
    check_case("ArrayFlatten[{}]", "List[]");
    check_case(
        "ArrayFlatten[{{{{1,2},{3,4}},{{5},{6}}},{{{7,8}},{{9}}}}]",
        "List[List[1, 2, 5], List[3, 4, 6], List[7, 8, 9]]");
    check_case(
        "ArrayFlatten[{{{{1},{2}},{{3}}}}]",
        "ArrayFlatten[List[List[List[List[1], List[2]], List[List[3]]]]]",
        {"ArrayFlatten::error: ArrayFlatten block row 1 has inconsistent heights."});
    check_case(
        "ArrayFlatten[{{{{1,2}}},{{{3}}}}]",
        "ArrayFlatten[List[List[List[List[1, 2]]], List[List[List[3]]]]]",
        {"ArrayFlatten::error: ArrayFlatten block column 1 has inconsistent widths."});

    check_case(
        "LeviCivitaTensor[3]",
        "List[List[List[0, 0, 0], List[0, 0, 1], List[0, -1, 0]], "
        "List[List[0, 0, -1], List[0, 0, 0], List[1, 0, 0]], "
        "List[List[0, 1, 0], List[-1, 0, 0], List[0, 0, 0]]]");
    check_case(
        "LeviCivitaTensor[2,SparseArray]",
        "SparseArray[List[Rule[List[1, 2], 1], Rule[List[2, 1], -1]], "
        "List[2, 2]]");
    check_case(
        "LeviCivitaTensor[0,SparseArray]",
        "LeviCivitaTensor[0, SparseArray]",
        {"LeviCivitaTensor::error: SparseArray rule positions must match the array rank."});
    check_case(
        "LeviCivitaTensor[8]", "LeviCivitaTensor[8]",
        {"LeviCivitaTensor::error: LeviCivitaTensor output exceeds the native materialization limit."});
}

void dispatch_and_control_tests() {
    check_case("System`Array[f,2]", "System`Array[f, 2]");
    check_case(
        "Check[ArrayPad[x,1],caught]", "caught",
        {"ArrayPad::error: ArrayPad expects a rectangular array."});
    check_case(
        "Reap[ConstantArray[Sow[a],2]]",
        "List[List[a, a], List[List[a]]]");
    check_case(
        "Catch[Array[(If[#==2,Throw[tag],#])&,3]]", "tag");
    check_case(
        "Catch[Array[(Print[InputForm[#]];If[#==2,Throw[tag],#])&,3]]",
        "tag", {}, {"1", "2"});
    check_case(
        "CheckAbort[Array[(If[#==2,Abort[],#])&,3],caught]", "caught");
    check_case(
        "CheckAbort[Array[(Print[InputForm[#]];If[#==2,Abort[],#])&,3],caught]",
        "caught", {}, {"1", "2"});
}

} // namespace

int main() {
    constructor_tests();
    padding_and_transpose_tests();
    flatten_and_levi_civita_tests();
    dispatch_and_control_tests();
    if (failures != 0)
        std::cerr << failures << " dense-array test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
