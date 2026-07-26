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

void confirmation_value_tests() {
    const std::string basic_failure =
        "Failure[ConfirmationFailed, Association["
        "Rule[\"ConfirmationType\", Confirm], "
        "Rule[\"Expression\", $Failed], "
        "Rule[\"Information\", Null]]]";
    check_case(
        "Confirm[Print[\"no\"],a,b,c]",
        "Confirm[Print[\"no\"], a, b, c]",
        {"Confirm::error: Confirm expects one, two, or three arguments."});
    check_case(
        "Confirm[1,Print[\"info\"],Print[\"tag\"]]", "1");
    check_case(
        "Confirm[$Failed]", basic_failure,
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Confirm[Failure[\"original\",<||>]]",
        "Failure[\"original\", Association[]]",
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Confirm[Failure[\"original\",<||>],info]",
        "Failure[ConfirmationFailed, Association["
        "Rule[\"ConfirmationType\", Confirm], "
        "Rule[\"Expression\", Failure[\"original\", Association[]]], "
        "Rule[\"Information\", info]]]",
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Confirm[$Failed];Print[\"after\"];7", "7",
        {"Confirm::confirmnotag: Message generated."}, {"after"});

    check_case("Enclose[Confirm[$Failed]]", basic_failure);
    check_case("Enclose[Confirm[$Failed],\"Type\"]", "ConfirmationFailed");
    check_case("Enclose[Confirm[$Failed],\"Expression\"]", "$Failed");
    check_case("Enclose[Confirm[$Failed],\"Information\"]", "Null");
    check_case(
        "Enclose[Confirm[$Failed],\"Nope\"]",
        "Missing[\"KeyAbsent\", \"Nope\"]");
    check_case(
        "Enclose[Confirm[$Failed,info],f]",
        "f[Failure[ConfirmationFailed, Association["
        "Rule[\"ConfirmationType\", Confirm], "
        "Rule[\"Expression\", $Failed], "
        "Rule[\"Information\", info]]]]");
    check_case(
        "Enclose[Confirm[$Failed,info,tag],Identity,_Symbol]",
        "Failure[ConfirmationFailed, Association["
        "Rule[\"ConfirmationType\", Confirm], "
        "Rule[\"Expression\", $Failed], "
        "Rule[\"Information\", info]]]");
    check_case(
        "Enclose[Confirm[$Failed,info,tag];Print[\"after\"],"
        "Identity,other]",
        "Null", {"Confirm::confirmnotag: Message generated."}, {"after"});
}

void confirmation_family_tests() {
    check_case("Enclose[ConfirmBy[3,IntegerQ]]", "3");
    check_case(
        "Enclose[ConfirmBy[3,StringQ,info],\"Function\"]", "StringQ");
    check_case(
        "Enclose[ConfirmBy[3,Function[x,Print[InputForm[x]];False],"
        "info],\"Expression\"]",
        "3", {}, {"3"});
    check_case("Enclose[ConfirmMatch[3,_Integer]]", "3");
    check_case(
        "Enclose[ConfirmMatch[3,_String,info],\"Pattern\"]",
        "Blank[String]");
    check_case(
        "Enclose[ConfirmMatch[3,PatternTest[Blank[],"
        "Function[x,Print[InputForm[x]];IntegerQ[x]]]]]",
        "3", {}, {"3"});
    check_case(
        "Enclose[ConfirmMatch[3,Condition[Pattern[x,Blank[]],"
        "Print[InputForm[x]];Greater[x,2]]]]",
        "3", {}, {"3"});
    check_case("Enclose[ConfirmAssert[True]]", "Null");
    check_case(
        "Enclose[ConfirmAssert[False,info],\"Test\"]", "False");
    check_case(
        "ConfirmQuiet[Print[\"quiet\"];1]", "ConfirmQuiet[1]", {},
        {"quiet"});
    check_case(
        "FailWhen[Print[\"fail-when\"];False]", "FailWhen[False]", {},
        {"fail-when"});
}

void dynamic_scope_and_control_tests() {
    const std::string basic_failure =
        "Failure[ConfirmationFailed, Association["
        "Rule[\"ConfirmationType\", Confirm], "
        "Rule[\"Expression\", $Failed], "
        "Rule[\"Information\", Null]]]";
    check_case(
        "Enclose[Confirm[$Failed,Null,tag],Identity,"
        "PatternTest[Blank[],Function[x,Print[\"match\"];True]]]",
        basic_failure, {}, {"match", "match"});
    check_case(
        "Enclose[Enclose[Confirm[$Failed,Null,tag],Identity,"
        "PatternTest[Blank[],Function[x,Print[\"inner\"];False]]],"
        "Identity,PatternTest[Blank[],Function[x,Print[\"outer\"];True]]]",
        basic_failure, {}, {"outer", "inner", "outer"});
    check_case(
        "Catch[Enclose[Throw[x]]];Confirm[$Failed]", basic_failure,
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "CheckAbort[Enclose[Abort[]],caught];Confirm[$Failed]",
        basic_failure, {"Confirm::confirmnotag: Message generated."});
    check_case(
        "CheckAbort[Enclose[AbortProtect[Abort[];7]],caught];"
        "Confirm[$Failed]",
        basic_failure, {"Confirm::confirmnotag: Message generated."});
    check_case(
        "ClearAll[f];f[]:=Enclose[Return[x]];f[];Confirm[$Failed]",
        basic_failure, {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Do[Enclose[Break[]],{2}];Confirm[$Failed]", basic_failure,
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Do[Enclose[Continue[]],{2}];Confirm[$Failed]", basic_failure,
        {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Enclose[Goto[l];Print[\"bad\"];Label[l];7];Confirm[$Failed]",
        basic_failure, {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Enclose[WithCleanup[Confirm[$Failed,cleaned],"
        "Print[\"cleanup\"]],\"Information\"]",
        "cleaned", {}, {"cleanup"});
    check_case(
        "Enclose[Reap[Sow[a];Confirm[$Failed,reaped]],\"Information\"]",
        "reaped");
    check_case(
        "Reap[Enclose[Sow[a];Confirm[$Failed,reaped],\"Information\"]]",
        "List[reaped, List[List[a]]]");
    check_case(
        "Enclose[TimeConstrained[Confirm[$Failed,timed],1,timeout],"
        "\"Information\"]",
        "timed");
    check_case(
        "Catch[Enclose[ConfirmBy[1,Function[x,Throw[boom]]]]]",
        "boom");
    check_case(
        "CheckAbort[Enclose[ConfirmMatch[1,PatternTest[Blank[],"
        "Function[x,Abort[]]]]],caught]",
        "caught");
    check_case(
        "Enclose[Confirm[$Failed],Function[x,Confirm[$Failed]]]",
        basic_failure, {"Confirm::confirmnotag: Message generated."});
    check_case(
        "Enclose[Enclose[Confirm[$Failed],Function[x,Confirm[$Failed]]]]",
        basic_failure);
}

} // namespace

int main() {
    failure_value_tests();
    failsafe_tests();
    confirmation_value_tests();
    confirmation_family_tests();
    dynamic_scope_and_control_tests();
    if (failures != 0)
        std::cerr << failures << " failure/confirmation test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
