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

void check_message_case(
    const std::string& source, const std::string& expected_result,
    std::vector<std::string> expected_messages, const std::string& label) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    check_equal(result.result.to_full_form(), expected_result,
        label + " result");
    std::vector<std::string> actual_messages;
    for (const auto& message : result.messages)
        actual_messages.push_back(message.text);
    if (actual_messages != expected_messages) {
        std::cerr << "FAIL: " << label << " messages\n  expected:";
        for (const auto& value : expected_messages) std::cerr << ' ' << value;
        std::cerr << "\n  actual:  ";
        for (const auto& value : actual_messages) std::cerr << ' ' << value;
        std::cerr << '\n';
        ++failures;
    }
    if (!result.prints.empty()) {
        std::cerr << "FAIL: " << label << " emitted an unexpected print\n";
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

void fold_while_tests() {
    check_effect_case(
        "FoldWhileList[Plus,0,{1,2,3,4},Function[x,Less[x,4]]]",
        "List[0, 1, 3, 6]", {}, "FoldWhileList default history");
    check_effect_case(
        "FoldWhile[Plus,0,{1,2,3,4},Function[x,Less[x,4]]]",
        "6", {}, "FoldWhile scalar result");
    check_effect_case(
        "FoldWhileList[Function[{a,x},Plus[a,x]],0,{1,2,3},"
        "Function[Null,Print[InputForm[{##}]];True],2]",
        "List[0, 1, 3, 6]", {"{0}", "{0, 1}", "{1, 3}", "{3, 6}"},
        "FoldWhileList bounded history argument order");
    check_effect_case(
        "FoldWhileList[Function[{a,x},Plus[a,x]],0,{1,2},"
        "Function[Null,Print[InputForm[{##}]];True],All]",
        "List[0, 1, 3]", {"{0}", "{0, 1}", "{0, 1, 3}"},
        "FoldWhileList All history argument order");
    check_effect_case(
        "FoldWhileList[Plus,0,{1,2,3,4,5},Function[x,Less[x,4]],1,1]",
        "List[0, 1, 3, 6, 10]", {}, "FoldWhileList positive trailing count");
    check_effect_case(
        "FoldWhileList[Plus,0,{1,2,3,4,5},Function[x,Less[x,4]],1,2]",
        "List[0, 1, 3, 6, 10, 15]", {}, "FoldWhileList bounded trailing count");
    check_effect_case(
        "FoldWhileList[Plus,0,{1,2,3,4},Function[x,Less[x,4]],1,-1]",
        "List[0, 1, 3]", {}, "FoldWhileList removes the failing result");
    check_effect_case(
        "FoldWhileList[Plus,0,{1,2,3,4},Function[x,Less[x,4]],1,-20]",
        "List[0]", {}, "FoldWhileList negative trailing count keeps initial");
    check_effect_case(
        "FoldWhileList[f,z,{},Function[x,Print[\"predicate\"];False]]",
        "List[z]", {"predicate"}, "FoldWhileList tests empty input initially");
    check_effect_case(
        "FoldWhileList[f,z,g[a,b],Function[x,True]]",
        "List[z, f[z, a], f[f[z, a], b]]", {},
        "FoldWhileList accepts a generic compound sequence");
    check_effect_case(
        "FoldWhileList[f,z,<|a->x,b:>y|>,Function[x,True]]",
        "List[z, f[z, x], f[f[z, x], y]]", {},
        "FoldWhileList consumes Association values");
    check_message_case(
        "FoldWhileList[f,z,{a}]",
        "FoldWhileList[f, z, List[a]]",
        {"FoldWhileList::error: FoldWhileList currently supports a function, an "
         "initial value, inputs, a test, and optional history and trailing counts."},
        "FoldWhileList arity diagnostic");
    check_message_case(
        "x=1;FoldWhile[f,z,x,p]",
        "FoldWhile[f, z, x, p]",
        {"FoldWhile::error: FoldWhileList expects a nonatomic expression."},
        "FoldWhile raw domain diagnostic");
    check_message_case(
        "FoldWhileList[f,z,{a},p,0]",
        "FoldWhileList[f, z, List[a], p, 0]",
        {"FoldWhileList::error: FoldWhileList expects a positive history length or All."},
        "FoldWhileList nonpositive history diagnostic");
    check_message_case(
        "FoldWhileList[f,z,{a},p,foo]",
        "FoldWhileList[f, z, List[a], p, foo]",
        {"FoldWhileList::error: FoldWhileList expects an integer argument."},
        "FoldWhileList history type diagnostic");
    check_message_case(
        "FoldWhileList[Plus,0,{1},Function[x,Less[x,1]],1,foo]",
        "FoldWhileList[Plus, 0, List[1], Function[x, Less[x, 1]], 1, foo]",
        {"FoldWhileList::error: FoldWhileList expects an integer argument."},
        "FoldWhileList trailing type diagnostic after failure");
    check_effect_case(
        "FoldWhileList[Plus,0,{1},Function[x,True],1,foo]",
        "List[0, 1]", {},
        "FoldWhileList does not validate unused trailing count");
}

} // namespace

int main() {
    immediate_signal_tests();
    deferred_abort_tests();
    fold_while_tests();
    if (failures != 0) {
        std::cerr << failures << " combinator-state test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all combinator-state tests passed\n";
    return EXIT_SUCCESS;
}
