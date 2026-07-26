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

void failure_value_tests() {
    check_case("FailureQ[Failure[]]", "True");
    check_case("FailureQ[$Failed]", "True");
    check_case("FailureQ[$Canceled]", "True");
    check_case("FailureQ[$Aborted]", "True");
    check_case("FailureQ[Missing[\"x\"]]", "False");
    check_case("MissingQ[Missing[]]", "True");
    check_case("MissingQ[$Failed]", "False");

    check_case("Failure[x,<|\"A\"->1|>][\"Type\"]", "x");
    check_case("Failure[x,<|\"A\"->1|>][\"FailureType\"]", "x");
    check_case("Failure[x,<|\"A\"->1|>][\"A\"]", "1");
    check_case(
        "Failure[x,<|\"A\"->1|>][\"B\"]",
        "Missing[\"KeyAbsent\", \"B\"]");
    check_case("Failure[x,{\"A\"->1}][\"A\"]", "1");
    check_case(
        "Failure[x,{\"A\":>Print[\"late\"]}][\"A\"]",
        "Print[\"late\"]");
    check_case(
        "Failure[x,<||>][1]", "Failure[x, Association[]][1]",
        {"General::error: Failure property lookup expects a string key."});
    check_case(
        "Failure[x,<|\"A\"->1|>][\"A\",\"B\"]",
        "Failure[x, Association[Rule[\"A\", 1]]][\"A\", \"B\"]");
}

void failsafe_tests() {
    check_case(
        "Failsafe[Print[\"no\"],a,b,c]",
        "Failsafe[Print[\"no\"], a, b, c]",
        {"Failsafe::error: Failsafe expects one, two, or three arguments."});
    check_case("Failsafe[f][1,2]", "f[1, 2]");
    check_case(
        "Failsafe[f][1,Missing[\"x\"],Failure[bad,<||>]]",
        "Missing[\"x\"]");
    check_case("Failsafe[f][$Failed]", "$Failed");
    check_case("Failsafe[f][$Canceled]", "$Canceled");
    check_case("Failsafe[f][$Aborted]", "$Aborted");
    check_case("Failsafe[f,SameQ][1,1]", "f[1, 1]");
    check_case(
        "Failsafe[f,SameQ][1,2]",
        "Failure[FailsafeFailed, Association[Rule[\"Arguments\", Hold[1, 2]]]]");
    check_case(
        "Failsafe[f,SameQ][1,2][\"Arguments\"]", "Hold[1, 2]");
    check_case(
        "Failsafe[f,SameQ][1,2][\"Type\"]", "FailsafeFailed");
    check_case("Failsafe[f,SameQ,g][1,2]", "g[1, 2]");
    check_case("Failsafe[f,SameQ,g][1,1]", "f[1, 1]");
    check_case(
        "Failsafe[(Print[\"f\"];f),(Print[\"t\"];SameQ),"
        "(Print[\"g\"];g)][(Print[\"a\"];1),(Print[\"b\"];2)]",
        "g[1, 2]", {}, {"f", "t", "g", "a", "b"});
}

} // namespace

int main() {
    failure_value_tests();
    failsafe_tests();
    if (failures != 0)
        std::cerr << failures << " failure/confirmation test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
