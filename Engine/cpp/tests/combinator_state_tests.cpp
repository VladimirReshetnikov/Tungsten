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

void sequence_fold_tests() {
    check_effect_case(
        "SequenceFoldList[f,{x0,x1},{a,b,c}]",
        "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b], "
        "f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]]",
        {}, "SequenceFoldList default state window");
    check_effect_case(
        "SequenceFold[f,{x0,x1},{a,b,c,d},4]",
        "f[x1, f[x0, x1, a, b], c, d]", {},
        "SequenceFold explicit argument count");
    check_effect_case(
        "SequenceFoldList[f,{x0,x1},{a,b,c,d,e},4]",
        "List[x0, x1, f[x0, x1, a, b], "
        "f[x1, f[x0, x1, a, b], c, d]]",
        {}, "SequenceFoldList ignores an incomplete trailing chunk");
    check_effect_case(
        "SequenceFoldList[f,g[x0,x1],h[a,b]]",
        "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b]]",
        {}, "SequenceFoldList accepts generic compound sequences");
    check_effect_case(
        "SequenceFoldList[f,<|a->x0,b:>x1|>,<|p->a,q:>b|>]",
        "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b]]",
        {}, "SequenceFoldList consumes Association values");
    check_effect_case(
        "SequenceFoldList[f,{s},SparseArray[{{2}->x},{3},z]]",
        "List[s, f[s, z], f[f[s, z], x], f[f[f[s, z], x], z]]",
        {}, "SequenceFoldList consumes a vector SparseArray");
    check_message_case(
        "SequenceFold[f,{x},{a},2,extra]",
        "SequenceFold[f, List[x], List[a], 2, extra]",
        {"SequenceFold::error: SequenceFold expects a function, initial values, "
         "inputs, and an optional argument count."},
        "SequenceFold arity diagnostic");
    check_message_case(
        "SequenceFoldList[f,{},{}]",
        "SequenceFoldList[f, List[], List[]]",
        {"SequenceFoldList::error: SequenceFoldList expects at least one initial value."},
        "SequenceFoldList empty initial diagnostic");
    check_message_case(
        "SequenceFoldList[f,{},x]",
        "SequenceFoldList[f, List[], x]",
        {"SequenceFoldList::error: SequenceFoldList expects a nonatomic expression."},
        "SequenceFoldList validates inputs before empty initial state");
    check_message_case(
        "SequenceFoldList[f,{s},SparseArray[{}, {2,2}, z]]",
        "SequenceFoldList[f, List[s], SparseArray[List[], List[2, 2], z]]",
        {"SequenceFoldList::error: SequenceFoldList expects a one-dimensional "
         "SparseArray sequence."},
        "SequenceFoldList SparseArray rank diagnostic");
    check_message_case(
        "SequenceFoldList[f,{x0,x1},{a},1]",
        "SequenceFoldList[f, List[x0, x1], List[a], 1]",
        {"SequenceFoldList::error: SequenceFoldList expects an argument count greater "
         "than or equal to the number of initial values."},
        "SequenceFoldList short argument-count diagnostic");
    check_message_case(
        "SequenceFoldList[f,{x0,x1},{a},2]",
        "SequenceFoldList[f, List[x0, x1], List[a], 2]",
        {"SequenceFoldList::error: SequenceFoldList currently expects each step to "
         "consume at least one input element."},
        "SequenceFoldList zero-consumption diagnostic");
    check_message_case(
        "SequenceFoldList[f,{x0},{a},foo]",
        "SequenceFoldList[f, List[x0], List[a], foo]",
        {"SequenceFoldList::error: SequenceFoldList expects an integer argument."},
        "SequenceFoldList argument-count type diagnostic");
}

void fold_pair_tests() {
    check_effect_case(
        "FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],z,{a,b,c}]",
        "List[emit[z, a], emit[state[z, a], b], "
        "emit[state[state[z, a], b], c]]",
        {}, "FoldPairList emission and state direction");
    check_effect_case(
        "FoldPair[Function[{s,x},{emit[s,x],state[s,x]}],z,g[a,b]]",
        "emit[state[z, a], b]", {}, "FoldPair accepts a generic sequence");
    check_effect_case(
        "FoldPairList[Function[{st,item},{emit[st,item],state[st,item]}],z,"
        "<|a->x,b:>y|>]",
        "List[emit[z, x], emit[state[z, x], y]]", {},
        "FoldPairList consumes Association values");
    check_effect_case(
        "FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],z,{a,b},Last]",
        "List[state[z, a], state[state[z, a], b]]", {},
        "FoldPairList applies Last as a projection");
    check_effect_case(
        "FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],z,{a,b},"
        "Function[p,h[p]]]",
        "List[h[List[emit[z, a], state[z, a]]], "
        "h[List[emit[state[z, a], b], state[state[z, a], b]]]]",
        {}, "FoldPairList applies a callable projection to each pair");
    check_effect_case(
        "FoldPairList[f,z,g[]]", "List[]", {},
        "FoldPairList empty sequence");
    check_effect_case(
        "FoldPair[f,z,g[]]", "FoldPair[f, z, g[]]", {},
        "FoldPair empty sequence stays inert");
    check_message_case(
        "FoldPairList[Function[{s,x},bad[s,x]],z,{a}]",
        "FoldPairList[Function[List[s, x], bad[s, x]], z, List[a]]",
        {"FoldPairList::error: FoldPairList expects each function application to "
         "return a list of two elements, got bad[z, a]."},
        "FoldPairList non-pair diagnostic");
    check_message_case(
        "FoldPair[Function[{s,x},{a,b,c}],z,{a}]",
        "FoldPair[Function[List[s, x], List[a, b, c]], z, List[a]]",
        {"FoldPair::error: FoldPairList expects each function application to return "
         "a list of two elements, got {a, b, c}."},
        "FoldPair exact pair-length diagnostic");
    check_message_case(
        "FoldPairList[f,z,x]",
        "FoldPairList[f, z, x]",
        {"FoldPairList::error: FoldPairList expects a nonatomic expression."},
        "FoldPairList domain diagnostic");
    check_message_case(
        "FoldPair[f,z,{a},p,q]",
        "FoldPair[f, z, List[a], p, q]",
        {"FoldPair::error: FoldPair currently supports a function, an initial value, "
         "inputs, and an optional projection."},
        "FoldPair arity diagnostic");
    check_effect_case(
        "Catch[FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],z,{a,b},"
        "Function[p,Print[InputForm[p]];If[SameQ[First[p],emit[z,a]],"
        "Throw[boom]];p]]]",
        "boom", {"{emit[z, a], state[z, a]}"},
        "FoldPairList stops after a projection signal");
}

} // namespace

int main() {
    immediate_signal_tests();
    deferred_abort_tests();
    fold_while_tests();
    sequence_fold_tests();
    fold_pair_tests();
    if (failures != 0) {
        std::cerr << failures << " combinator-state test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all combinator-state tests passed\n";
    return EXIT_SUCCESS;
}
