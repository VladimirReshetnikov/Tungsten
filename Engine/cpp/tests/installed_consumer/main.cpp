#include <tungsten/evaluator.hpp>
#include <tungsten/parser.hpp>

#include <algorithm>
#include <string>
#include <vector>

int main() {
    tungsten::Evaluator evaluator;
    const auto effects = evaluator.evaluate_result(tungsten::parse_input_form(
        R"WL(Print["installed"]; Part[{a}, 2])WL"));
    if (effects.result.to_full_form() != "Part[List[a], 2]") return 1;
    if (effects.prints != std::vector<std::string>{"installed"}) return 2;
    if (effects.messages.size() != 1
        || effects.messages.front().name.to_full_form()
            != "MessageName[Part, \"error\"]")
        return 3;

    (void)evaluator.evaluate(tungsten::parse_input_form(
        "installedApi = 12; SetAttributes[Global`installedApi, HoldAll]"));
    const auto info = evaluator.symbol_info(tungsten::symbol("Global`installedApi"));
    if (!info || info->full_name != "Global`installedApi"
        || info->context != "Global`" || info->short_name != "installedApi"
        || info->built_in || info->attributes.count("HoldAll") == 0)
        return 4;
    const auto rules = evaluator.value_rules(
        tungsten::symbol("installedApi"), tungsten::ValueKind::Own);
    if (rules.size() != 1
        || rules.front().to_full_form()
            != "RuleDelayed[HoldPattern[installedApi], 12]")
        return 5;
    (void)evaluator.evaluate(tungsten::parse_input_form(
        "installedFunction[x_] := x + 1"));
    const auto down_rules = evaluator.value_rules(
        tungsten::symbol("Global`installedFunction"), tungsten::ValueKind::Down);
    if (down_rules.size() != 1
        || down_rules.front().to_full_form()
            != "RuleDelayed[HoldPattern[installedFunction[Pattern[x, Blank[]]]], Plus[x, 1]]")
        return 6;
    return 0;
}
