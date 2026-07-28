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

void check_case(
    const std::string& source, const std::string& expected,
    const std::string& label) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    check_equal(result.result.to_full_form(), expected, label + " result");
    if (!result.messages.empty()) {
        std::cerr << "FAIL: " << label << " emitted an unexpected message\n";
        ++failures;
    }
    if (!result.prints.empty()) {
        std::cerr << "FAIL: " << label << " emitted an unexpected print\n";
        ++failures;
    }
}

void check_message_case(
    const std::string& source, const std::string& expected,
    std::vector<std::string> expected_messages, const std::string& label) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    check_equal(result.result.to_full_form(), expected, label + " result");
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

void check_effect_case(
    const std::string& source, const std::string& expected,
    std::vector<std::string> expected_prints, const std::string& label) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    check_equal(result.result.to_full_form(), expected, label + " result");
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

void projection_tests() {
    check_case("TakeDrop[f[a,b,c,d],-2]",
        "List[f[c, d], f[a, b]]", "TakeDrop generic negative count");
    check_case("TakeDrop[f[a,b,c,d],Span[4,2,-1]]",
        "List[f[d, c, b], f[a]]", "TakeDrop descending span");
    check_case("TakeDrop[f[a,b,c,d],None]",
        "List[f[], f[a, b, c, d]]", "TakeDrop None selector");
    check_case("TakeDrop[<|a->1,b:>2,c->3|>,{2,3}]",
        "List[Association[RuleDelayed[b, 2], Rule[c, 3]], "
        "Association[Rule[a, 1]]]", "TakeDrop Association projections");

    check_case("TakeList[f[a,b,c,d],{2,1}]",
        "List[f[a, b], f[c]]", "TakeList sequential counts");
    check_case("TakeList[f[a,b,c,d],{{2,3},{-1},All}]",
        "List[f[b, c], f[d], f[a]]", "TakeList selector sequence");
    check_case("TakeList[f[a,b,c,d],{None,All}]",
        "List[f[], f[a, b, c, d]]", "TakeList None then All");
    check_case("TakeList[<|a->1,b:>2,c->3|>,{1,-1,All}]",
        "List[Association[Rule[a, 1]], Association[Rule[c, 3]], "
        "Association[RuleDelayed[b, 2]]]", "TakeList Association sequence");
    check_case("TakeList[a,{}]", "List[]",
        "TakeList empty specifications accept an atom");
    check_case("TakeList[a,{All,All}]", "List[a, a]",
        "TakeList All leaves an atom unchanged");
    check_case("TakeList[Nothing,{All}]", "List[]",
        "TakeList result applies evaluated List Nothing semantics");
    check_case("TakeList[Unevaluated[Sequence[a,b]],{All}]", "List[a, b]",
        "TakeList result splices Sequence");
    check_case("TakeList[Unevaluated[Splice[{a,b}]],{All}]", "List[a, b]",
        "TakeList result splices Splice into List");
    check_case("TakeList[Unevaluated[f[Sequence[a,b]]],{1}]", "List[f[a, b]]",
        "TakeList selected generic result splices Sequence");
    check_case("TakeList[Unevaluated[f[Sequence[a,b]]],{All}]",
        "List[f[Sequence[a, b]]]",
        "TakeList All keeps the remaining expression intact");
    check_case("TakeDrop[Unevaluated[f[Sequence[a,b]]],All]",
        "List[f[a, b], f[]]", "TakeDrop projections splice Sequence");
    check_case("TakeDrop[Unevaluated[f[Splice[{a,b},f]]],All]",
        "List[f[a, b], f[]]", "TakeDrop projections honor targeted Splice");
}

void diagnostic_tests() {
    check_message_case("TakeList[]", "TakeList[]",
        {"TakeList::error: TakeList expects exactly two arguments."},
        "TakeList arity diagnostic");
    check_message_case("TakeList[f[a],x]", "TakeList[f[a], x]",
        {"TakeList::error: TakeList expects a list of specifications."},
        "TakeList specification-list diagnostic");
    check_message_case("TakeList[a,{0}]", "TakeList[a, List[0]]",
        {"TakeList::error: Take expects a nonatomic expression."},
        "TakeList reports the failed Take projection");
    check_message_case("TakeList[f[a],{{a}}]",
        "TakeList[f[a], List[List[a]]]",
        {"TakeList::error: Take single-element list specifications must contain "
         "an integer or All."},
        "TakeList selector diagnostic");
    check_message_case("TakeDrop[]", "TakeDrop[]",
        {"TakeDrop::error: TakeDrop expects exactly two arguments."},
        "TakeDrop arity diagnostic");
    check_message_case("TakeDrop[f[a],2]", "TakeDrop[f[a], 2]",
        {"TakeDrop::error: Part index 2 is out of range for length 1."},
        "TakeDrop emits one outer diagnostic");
    check_message_case("TakeDrop[f[a],UpTo[1]]",
        "TakeDrop[f[a], UpTo[1]]",
        {"TakeDrop::error: Unsupported Take specification: 'UpTo[1]'."},
        "TakeDrop preserves unsupported selector diagnostics");
    check_message_case("Check[TakeDrop[f[a],2],caught]", "caught",
        {"TakeDrop::error: Part index 2 is out of range for length 1."},
        "Check catches the single TakeDrop diagnostic");
    check_case("Quiet[TakeList[f[a],{{a}}]]",
        "TakeList[f[a], List[List[a]]]", "Quiet suppresses TakeList diagnostic");
}

void signal_and_effect_tests() {
    check_case("Catch[TakeDrop[f[a],Throw[tag]]]", "tag",
        "TakeDrop stops on Throw while evaluating its selector");
    check_case("CheckAbort[TakeDrop[f[a],Abort[]],caught]", "caught",
        "TakeDrop stops on Abort while evaluating its selector");
    check_case("Catch[TakeList[f[a],{Throw[tag]}]]", "tag",
        "TakeList stops on Throw while evaluating specifications");
    check_case("CheckAbort[TakeList[f[a],{Abort[]}],caught]", "caught",
        "TakeList stops on Abort while evaluating specifications");
    check_effect_case("Reap[TakeDrop[{Sow[a],b},All]]",
        "List[List[List[a, b], List[]], List[List[a]]]", {},
        "TakeDrop evaluates the subject once");
    check_effect_case("Reap[TakeList[{Sow[a],Sow[b],c},{1,All}]]",
        "List[List[List[a], List[b, c]], List[List[a, b]]]", {},
        "TakeList evaluates the subject once");
    check_effect_case("Do[TakeDrop[f[a],Break[]];Print[bad],{1}]",
        "Null", {}, "TakeDrop does not continue after Break");
}

void take_drop_regression_tests() {
    check_case("Take[{{a,b,c},{d,e,f}},2,{2,3}]",
        "List[List[b, c], List[e, f]]",
        "Take keeps multidimensional selector behavior");
    check_case("Drop[{{a,b,c},{d,e,f}},None,{2,3}]",
        "List[List[a], List[d]]",
        "Drop keeps multidimensional selector behavior");
    check_case("Take[<|a->1,b:>2,c->3|>,{2,3}]",
        "Association[RuleDelayed[b, 2], Rule[c, 3]]",
        "Take keeps Association selector behavior");
    check_case("Drop[f[a,b,c,d],Span[4,2,-1]]", "f[a]",
        "Drop keeps descending-span behavior");
    check_case("Take[Unevaluated[f[Sequence[a,b]]],All]", "f[a, b]",
        "Take rebuild keeps evaluated Sequence semantics");
    check_case("Drop[Unevaluated[f[Splice[{a,b},f],c]],{-1}]", "f[a, b]",
        "Drop rebuild keeps targeted Splice semantics");
}

} // namespace

int main() {
    projection_tests();
    diagnostic_tests();
    signal_and_effect_tests();
    take_drop_regression_tests();
    if (failures == 0) {
        std::cout << "take-list tests passed\n";
        return EXIT_SUCCESS;
    }
    std::cerr << failures << " take-list test(s) failed\n";
    return EXIT_FAILURE;
}
