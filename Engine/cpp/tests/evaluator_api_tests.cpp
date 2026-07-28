#include "tungsten/evaluator.hpp"
#include "tungsten/parser.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& label) {
    if (condition) return;
    std::cerr << "FAIL: " << label << '\n';
    ++failures;
}

void check_equal(
    const std::string& actual, const std::string& expected, const std::string& label) {
    if (actual == expected) return;
    std::cerr << "FAIL: " << label << "\n  expected: " << expected
              << "\n  actual:   " << actual << '\n';
    ++failures;
}

tungsten::Expr evaluate(tungsten::Evaluator& evaluator, const std::string& source) {
    return evaluator.evaluate(tungsten::parse_input_form(source));
}

std::string rules_form(const std::vector<tungsten::Expr>& rules) {
    return tungsten::list(rules).to_full_form();
}

void evaluation_result_tests() {
    tungsten::Evaluator evaluator;
    const auto captured = evaluator.evaluate_result(tungsten::parse_input_form(
        R"WL(Print["captured"]; Part[{a}, 2])WL"));
    check_equal(captured.result.to_full_form(), "Part[List[a], 2]",
        "EvaluationResult stores the result");
    check(captured.prints == std::vector<std::string>{"captured"},
        "EvaluationResult stores print effects");
    check(captured.messages.size() == 1,
        "EvaluationResult stores structured messages");
    if (captured.messages.size() == 1) {
        check_equal(captured.messages.front().name.to_full_form(),
            "MessageName[Part, \"error\"]", "structured message name");
        check_equal(captured.messages.front().name_expr().to_full_form(),
            "HoldForm[MessageName[Part, \"error\"]]", "held message-name expression");
        check_equal(captured.messages.front().text,
            "Part::error: Part specifications are invalid for {a}.",
            "structured message text");
    }

    const auto clean = evaluator.evaluate_result(tungsten::parse_input_form("2 + 2"));
    check_equal(clean.result.to_full_form(), "4", "subsequent EvaluationResult value");
    check(clean.messages.empty() && clean.prints.empty(),
        "subsequent EvaluationResult has fresh effects");
    check(captured.messages.size() == 1 && captured.prints.size() == 1,
        "EvaluationResult owns independent effect snapshots");
}

void symbol_info_tests() {
    tungsten::Evaluator evaluator;
    const auto plus = evaluator.symbol_info(tungsten::symbol("Plus"));
    check(plus.has_value(), "SymbolInfo exists for a symbol");
    if (plus) {
        check_equal(plus->full_name, "System`Plus", "built-in full name");
        check_equal(plus->context, "System`", "built-in context");
        check_equal(plus->short_name, "Plus", "built-in short name");
        check(plus->built_in, "System Plus is built in");
        check(plus->attributes.count("Protected") != 0,
            "SymbolInfo exposes effective built-in attributes");
    }

    (void)evaluate(evaluator,
        "ClearAll[Global`Plus, ApiContext`x]; Global`Plus = 9; "
        "SetAttributes[ApiContext`x, HoldAll]");
    const auto global_plus = evaluator.symbol_info(tungsten::symbol("Global`Plus"));
    check(global_plus.has_value() && !global_plus->built_in,
        "explicit Global shadow is not built in");
    if (global_plus) {
        check_equal(global_plus->full_name, "Global`Plus", "Global shadow full name");
        check(global_plus->attributes.count("Protected") == 0,
            "Global shadow does not inherit System attributes");
    }
    const auto custom = evaluator.symbol_info(tungsten::symbol("ApiContext`x"));
    check(custom.has_value(), "custom-context SymbolInfo exists");
    if (custom) {
        check_equal(custom->context, "ApiContext`", "custom context");
        check_equal(custom->short_name, "x", "custom short name");
        check(!custom->built_in && custom->attributes.count("HoldAll") != 0,
            "custom symbol metadata and attributes");
    }
    check(!evaluator.symbol_info(tungsten::integer(1L)).has_value(),
        "SymbolInfo rejects nonsymbol expressions");

    (void)evaluate(evaluator,
        "HoldComplete[{apiDynamic, System`apiDynamic}]");
    const auto dynamic = evaluator.symbol_info(tungsten::symbol("apiDynamic"));
    check(dynamic.has_value(), "dynamic System symbol resolves after held registration");
    if (dynamic) {
        check_equal(dynamic->full_name, "System`apiDynamic",
            "qualified names register before bare names across the root AST");
        check(!dynamic->built_in, "dynamic System symbol is not marked built in");
    }

    tungsten::Evaluator isolated;
    (void)evaluate(evaluator, R"WL(Symbol["OnlyFirstEvaluator`name"])WL");
    check_equal(evaluate(isolated, R"WL(Names["OnlyFirstEvaluator`*"])WL").to_full_form(),
        "List[]", "known-symbol registries are evaluator-local");

    (void)evaluate(evaluator,
        R"WL(Symbol["HiddenApiContext`hiddenOnly"]; HiddenApiContext`hiddenOnly = 7)WL");
    check_equal(evaluate(evaluator, R"WL(Names["hiddenOnly"])WL").to_full_form(),
        "List[]", "unqualified Names patterns exclude custom contexts");
    check_equal(evaluate(evaluator, R"WL(Names["HiddenApiContext`hiddenOnly"])WL")
            .to_full_form(),
        "List[\"HiddenApiContext`hiddenOnly\"]",
        "qualified Names patterns include custom contexts");
    check_equal(evaluate(evaluator,
        R"WL(Names[{"HiddenApiContext`*", "System`Plus"}])WL").to_full_form(),
        "List[\"HiddenApiContext`hiddenOnly\", \"Plus\"]",
        "Names unions and sorts a list of string patterns");
    check_equal(evaluate(evaluator,
        R"WL(NameQ[{"missingApiName", "System`Plus"}])WL").to_full_form(),
        "True", "NameQ accepts a list of string patterns");
    check_equal(evaluate(evaluator, R"WL(Names[{"Plus", 1}])WL").to_full_form(),
        "Names[List[\"Plus\", 1]]", "malformed Names pattern lists remain inert");
    check_equal(evaluate(evaluator, R"WL(Contexts["HiddenApiContext`"])WL")
            .to_full_form(),
        "List[\"HiddenApiContext`\"]", "Contexts patterns match context names");
    (void)evaluate(evaluator, R"WL(Clear["hiddenOnly"]; Protect["hiddenOnly"])WL");
    check_equal(evaluate(evaluator,
        "HiddenApiContext`hiddenOnly = 8; HiddenApiContext`hiddenOnly").to_full_form(),
        "8", "unqualified Clear and Protect patterns exclude custom contexts");

    (void)evaluate(evaluator,
        R"WL(Symbol["VisibleMultiStarName"]; Symbol["lowercasepattern"])WL");
    check_equal(evaluate(evaluator, R"WL(Names["V*i*Name"])WL").to_full_form(),
        "List[\"VisibleMultiStarName\"]", "Names supports multiple stars");
    check_equal(evaluate(evaluator, R"WL(Names["Visible\\*"])WL").to_full_form(),
        "List[]", "backslash escapes a name-pattern star");
    check_equal(evaluate(evaluator, R"WL(NameQ["lower@"])WL").to_full_form(),
        "True", "name-pattern at sign matches non-uppercase suffixes");
}

void concurrent_registry_isolation_tests() {
    std::string left_names;
    std::string left_value;
    std::string right_names;
    std::string right_value;
    bool left_attribute = false;
    bool right_attribute = false;
    std::thread left([&] {
        tungsten::Evaluator evaluator;
        (void)evaluate(evaluator,
            "ThreadLeft`shared = 11; shared = 101; "
            "SetAttributes[ThreadLeft`shared, HoldAll]");
        left_names = evaluate(evaluator, R"WL(Names["ThreadRight`*"])WL").to_full_form();
        left_value = evaluate(evaluator, "{ThreadLeft`shared, shared}").to_full_form();
        const auto info = evaluator.symbol_info(tungsten::symbol("ThreadLeft`shared"));
        left_attribute = info && info->attributes.count("HoldAll") != 0;
    });
    std::thread right([&] {
        tungsten::Evaluator evaluator;
        (void)evaluate(evaluator,
            "ThreadRight`shared = 22; shared = 202; "
            "SetAttributes[ThreadRight`shared, Listable]");
        right_names = evaluate(evaluator, R"WL(Names["ThreadLeft`*"])WL").to_full_form();
        right_value = evaluate(evaluator, "{ThreadRight`shared, shared}").to_full_form();
        const auto info = evaluator.symbol_info(tungsten::symbol("ThreadRight`shared"));
        right_attribute = info && info->attributes.count("Listable") != 0
            && info->attributes.count("HoldAll") == 0;
    });
    left.join();
    right.join();
    check_equal(left_names, "List[]", "parallel evaluator does not see right registry");
    check_equal(right_names, "List[]", "parallel evaluator does not see left registry");
    check_equal(left_value, "List[11, 101]", "left evaluator values remain isolated");
    check_equal(right_value, "List[22, 202]", "right evaluator values remain isolated");
    check(left_attribute && right_attribute,
        "parallel evaluator attribute stores remain isolated");
}

void canonical_own_attribute_and_scope_tests() {
    tungsten::Evaluator evaluator;
    check_equal(evaluate(evaluator,
        "ClearAll[x, Global`x]; x = 10; "
        "{x, Global`x, OwnValues[Global`x]}").to_full_form(),
        "List[10, 10, List[RuleDelayed[HoldPattern[x], 10]]]",
        "bare and explicit Global own values alias");
    check_equal(rules_form(evaluator.value_rules(
        tungsten::symbol("x"), tungsten::ValueKind::Own)),
        "List[RuleDelayed[HoldPattern[x], 10]]", "public Own value rules");
    check(evaluator.value_rules(tungsten::symbol("x"), tungsten::ValueKind::Own)
            == evaluator.value_rules(tungsten::symbol("Global`x"), tungsten::ValueKind::Own),
        "public Own rules share canonical owner identity");

    check_equal(evaluate(evaluator,
        "SetAttributes[Global`x, HoldAll]; {Attributes[x], Attributes[Global`x]}")
            .to_full_form(),
        "List[List[HoldAll], List[HoldAll]]", "attribute aliases share storage");
    const auto attributed = evaluator.symbol_info(tungsten::symbol("x"));
    check(attributed && attributed->attributes.count("HoldAll") != 0,
        "SymbolInfo observes aliased attributes");
    (void)evaluate(evaluator, "ClearAttributes[x, HoldAll]");
    check_equal(evaluate(evaluator, "Attributes[Global`x]").to_full_form(),
        "List[]", "ClearAttributes works through the other alias");

    (void)evaluate(evaluator, "Protect[x]");
    const auto protected_alias = evaluator.symbol_info(tungsten::symbol("Global`x"));
    check(protected_alias && protected_alias->attributes.count("Protected") != 0,
        "Protect uses canonical identity");
    (void)evaluate(evaluator, "Unprotect[Global`x]");
    const auto unprotected_alias = evaluator.symbol_info(tungsten::symbol("x"));
    check(unprotected_alias && unprotected_alias->attributes.count("Protected") == 0,
        "Unprotect uses canonical identity");

    check_equal(evaluate(evaluator,
        "x = 10; {Block[{Global`x = 20}, {x, Global`x}], x, "
        "Table[{x, Global`x}, {Global`x, 1, 2}], x}").to_full_form(),
        "List[List[20, 20], 10, List[List[1, 1], List[2, 2]], 10]",
        "Block and iterator snapshots use canonical identity");

    check(evaluator.value_rules(tungsten::symbol("x"), tungsten::ValueKind::N).empty(),
        "N value rules are an explicit empty surface");
    check(evaluator.value_rules(tungsten::integer(1L), tungsten::ValueKind::Own).empty(),
        "value_rules rejects nonsymbol expressions");
}

void canonical_definition_tests() {
    tungsten::Evaluator evaluator;
    check_equal(evaluate(evaluator,
        "ClearAll[f, Global`f]; f[x_] := bare[x]; "
        "Global`f[x_] := qualified[x]; {f[1], Global`f[1]}").to_full_form(),
        "List[bare[1], qualified[1]]",
        "canonical DownValue bucket preserves raw pattern matching");
    const std::string down_rules
        = "List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], bare[x]], "
          "RuleDelayed[HoldPattern[Global`f[Pattern[x, Blank[]]]], qualified[x]]]";
    check_equal(rules_form(evaluator.value_rules(
        tungsten::symbol("f"), tungsten::ValueKind::Down)), down_rules,
        "public Down rules preserve both LHS spellings");
    check_equal(rules_form(evaluator.value_rules(
        tungsten::symbol("Global`f"), tungsten::ValueKind::Down)), down_rules,
        "explicit Global query reaches canonical Down bucket");

    (void)evaluate(evaluator, "Unset[f[x_]]");
    check_equal(evaluate(evaluator, "{f[1], Global`f[1]}").to_full_form(),
        "List[f[1], qualified[1]]", "Unset removes only the exact raw LHS spelling");
    check_equal(rules_form(evaluator.value_rules(
        tungsten::symbol("f"), tungsten::ValueKind::Down)),
        "List[RuleDelayed[HoldPattern[Global`f[Pattern[x, Blank[]]]], qualified[x]]]",
        "selective Unset leaves the qualified rule");
    (void)evaluate(evaluator, "Clear[Global`f]");
    check(evaluator.value_rules(tungsten::symbol("f"), tungsten::ValueKind::Down).empty(),
        "Clear through either alias removes the canonical definition bucket");

    check_equal(evaluate(evaluator,
        "ClearAll[sv, Global`sv]; sv[x_][y_] := bare[x, y]; "
        "Global`sv[x_][y_] := qualified[x, y]; "
        "{sv[1][2], Global`sv[3][4]}").to_full_form(),
        "List[bare[1, 2], qualified[3, 4]]",
        "canonical SubValue bucket preserves raw pattern matching");
    const auto sub_rules = evaluator.value_rules(
        tungsten::symbol("Global`sv"), tungsten::ValueKind::Sub);
    check(sub_rules.size() == 2
            && sub_rules[0].to_full_form().find("HoldPattern[sv[") != std::string::npos
            && sub_rules[1].to_full_form().find("HoldPattern[Global`sv[") != std::string::npos,
        "public Sub rules retain bare and qualified LHS spellings");

    check_equal(evaluate(evaluator,
        "ClearAll[tag, Global`tag, h]; tag /: h[tag[x_]] := bare[x]; "
        "Global`tag /: h[Global`tag[x_]] := qualified[x]; "
        "{h[tag[1]], h[Global`tag[2]]}").to_full_form(),
        "List[bare[1], qualified[2]]",
        "canonical UpValue bucket preserves raw pattern matching");
    const auto up_rules = evaluator.value_rules(
        tungsten::symbol("tag"), tungsten::ValueKind::Up);
    check(up_rules.size() == 2
            && up_rules[0].to_full_form().find("h[tag[") != std::string::npos
            && up_rules[1].to_full_form().find("h[Global`tag[") != std::string::npos,
        "public Up rules retain bare and qualified LHS spellings");
}

void system_and_custom_context_tests() {
    tungsten::Evaluator evaluator;
    const auto unqualified_clear = evaluator.evaluate_result(
        tungsten::parse_input_form(R"WL(Clear["Plus"])WL"));
    check(unqualified_clear.messages.size() == 1
            && unqualified_clear.messages.front().name.to_full_form()
                == "MessageName[Clear, \"wrsym\"]",
        "unqualified Clear patterns include the preloaded System registry");
    const auto qualified_clear = evaluator.evaluate_result(
        tungsten::parse_input_form(R"WL(Clear["System`Plus"])WL"));
    check(qualified_clear.messages.size() == 1
            && qualified_clear.messages.front().name.to_full_form()
                == "MessageName[Clear, \"wrsym\"]",
        "qualified Clear patterns include the preloaded System registry");
    check_equal(evaluate(evaluator,
        "ClearAll[Global`Plus]; Global`Plus = 9; "
        "{Plus, Global`Plus, Context[Plus], Context[Global`Plus]}").to_full_form(),
        "List[Plus, 9, \"System`\", \"Global`\"]",
        "System built-in and explicit Global shadow remain distinct");

    check_equal(evaluate(evaluator,
        "ClearAll[ApiOther`x, x]; ApiOther`x = 7; "
        "{x, ApiOther`x, Context[x], Context[ApiOther`x], "
        "OwnValues[x], OwnValues[ApiOther`x]}").to_full_form(),
        "List[x, 7, \"Global`\", \"ApiOther`\", List[], "
        "List[RuleDelayed[HoldPattern[ApiOther`x], 7]]]",
        "custom contexts do not alias Global");

    check_equal(evaluate(evaluator,
        "ClearAll[System`apiFresh]; System`apiFresh[x_] := x; "
        "{apiFresh[2], System`apiFresh[3], Context[apiFresh], DownValues[apiFresh]}")
            .to_full_form(),
        "List[apiFresh[2], 3, \"System`\", "
        "List[RuleDelayed[HoldPattern[System`apiFresh[Pattern[x, Blank[]]]], x]]]",
        "dynamic System owner aliases while raw qualified pattern remains exact");

    check_equal(rules_form(evaluator.value_rules(
        tungsten::symbol("System`$RecursionLimit"), tungsten::ValueKind::Own)),
        "List[RuleDelayed[HoldPattern[$RecursionLimit], 1024]]",
        "seeded System own values use canonical full-name storage");
}

void module_memoization_regression_tests() {
    tungsten::Evaluator evaluator;
    (void)evaluate(evaluator,
        "tungstenClosureMemo1 = Module[{cache, fib}, "
        "cache = <||>; "
        "fib[n_] := fib[n] = If[n < 2, n, fib[n - 1] + fib[n - 2]]; "
        "fib]");
    check_equal(evaluate(evaluator, "tungstenClosureMemo1[4]").to_full_form(),
        "3", "Module closure can memoize while applying its generic DownValue");
    check_equal(evaluate(evaluator, "tungstenClosureMemo1[5]").to_full_form(),
        "5", "Module closure reuses memoized DownValues on later calls");
}

} // namespace

int main() {
    evaluation_result_tests();
    symbol_info_tests();
    concurrent_registry_isolation_tests();
    canonical_own_attribute_and_scope_tests();
    canonical_definition_tests();
    system_and_custom_context_tests();
    module_memoization_regression_tests();
    if (failures != 0) {
        std::cerr << failures << " evaluator API test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ evaluator API tests passed\n";
    return EXIT_SUCCESS;
}
