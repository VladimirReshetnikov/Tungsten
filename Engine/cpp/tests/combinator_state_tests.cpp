#include "tungsten/evaluator.hpp"
#include "tungsten/parser.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check_equal(
    const std::string& actual, const std::string& expected,
    const std::string& label) {
    if (actual == expected) return;
    std::cerr << "FAIL: " << label << "\n  expected: " << expected
              << "\n  actual:   " << actual << '\n';
    ++failures;
}

void check_effect_case(
    const std::string& source, const std::string& expected_result,
    std::vector<std::string> expected_prints, const std::string& label) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    check_equal(result.result.to_full_form(), expected_result,
        label + " result");
    if (result.prints != expected_prints) {
        std::cerr << "FAIL: " << label << " prints\n  expected:";
        for (const auto& value : expected_prints) std::cerr << ' ' << value;
        std::cerr << "\n  actual:  ";
        for (const auto& value : result.prints) std::cerr << ' ' << value;
        std::cerr << '\n';
        ++failures;
    }
    if (!result.messages.empty()) {
        std::cerr << "FAIL: " << label << " emitted an unexpected message\n";
        ++failures;
    }
}

void immediate_signal_tests() {
    check_effect_case(
        "Catch[Fold[Function[{acc,x},Print[InputForm[x]];"
        "If[SameQ[x,b],Throw[boom]];p[acc,x]],z,{a,b,c}]]",
        "boom", {"a", "b"}, "Fold stops after Throw");
    check_effect_case(
        "CheckAbort[FoldList[Function[{acc,x},Print[InputForm[x]];"
        "If[SameQ[x,b],Abort[]];p[acc,x]],z,{a,b,c}],caught]",
        "caught", {"a", "b"}, "FoldList stops after Abort");
    check_effect_case(
        "worker[]:=SequenceFoldList[Function[Null,Print[InputForm[#3]];"
        "If[SameQ[#3,b],Return[returned]];q[##]],{x0,x1},{a,b,c}];worker[]",
        "returned", {"a", "b"}, "SequenceFoldList stops after Return");
    check_effect_case(
        "Catch[FoldWhileList[Function[{acc,x},Print[InputForm[x]];"
        "If[SameQ[x,b],Throw[boom]];p[acc,x]],z,{a,b,c},Function[x,True]]]",
        "boom", {"a", "b"}, "FoldWhileList stops after Throw");
    check_effect_case(
        "Catch[ComposeList[{Function[x,Print[InputForm[x]];f[x]],"
        "Function[x,Print[InputForm[x]];Throw[boom]],"
        "Function[x,Print[InputForm[x]];h[x]]},z]]",
        "boom", {"z", "f[z]"}, "ComposeList stops after Throw");
    check_effect_case(
        "Catch[Comap[{Function[x,Print[\"a\"];f[x]],"
        "Function[x,Print[\"b\"];Throw[boom]],"
        "Function[x,Print[\"c\"];h[x]]},z]]",
        "boom", {"a", "b"}, "Comap stops after Throw");
    check_effect_case(
        "Catch[ComapApply[{Function[Null,Print[\"a\"];f[##]],"
        "Function[Null,Print[\"b\"];Throw[boom]],"
        "Function[Null,Print[\"c\"];h[##]]},{x,y}]]",
        "boom", {"a", "b"}, "ComapApply stops after Throw");
    check_effect_case(
        "Catch[Discard[{a,b,c},Function[x,Print[InputForm[x]];"
        "If[SameQ[x,b],Throw[boom]];False]]]",
        "boom", {"a", "b"}, "Discard stops after Throw");
    check_effect_case(
        "Discard[{a,b,c},Function[x,Print[InputForm[x]];True],1]",
        "List[b, c]", {"a"}, "Discard stops testing after its limit");
}

void deferred_abort_tests() {
    check_effect_case(
        "CheckAbort[AbortProtect[Fold[Function[{acc,x},Abort[];"
        "Print[InputForm[x]];p[acc,x]],z,{a,b,c}]],caught]",
        "caught", {"a", "b", "c"},
        "Fold does not treat a protected deferred abort as immediate");
    check_effect_case(
        "CheckAbort[AbortProtect[ComposeList[{"
        "Function[x,Abort[];Print[InputForm[x]];f[x]],"
        "Function[x,Abort[];Print[InputForm[x]];g[x]]},z]],caught]",
        "caught", {"z", "f[z]"},
        "ComposeList does not treat a protected deferred abort as immediate");
}

} // namespace

int main() {
    immediate_signal_tests();
    deferred_abort_tests();
    if (failures != 0) {
        std::cerr << failures << " combinator-state test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all combinator-state tests passed\n";
    return EXIT_SUCCESS;
}
