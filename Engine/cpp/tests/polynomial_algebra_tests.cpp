#include "tungsten/evaluator.hpp"
#include "tungsten/parser.hpp"

#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check_case(const std::string& source, const std::string& expected) {
    tungsten::Evaluator evaluator;
    const auto result = evaluator.evaluate_result(
        tungsten::parse_input_form(source));
    if (result.result.to_full_form() != expected) {
        std::cerr << "FAIL: " << source << "\n  expected: " << expected
                  << "\n  actual:   " << result.result.to_full_form() << '\n';
        ++failures;
    }
    if (!result.messages.empty() || !result.prints.empty()) {
        std::cerr << "FAIL: " << source
                  << " produced an unexpected visible effect\n";
        ++failures;
    }
}

void apart_tests() {
    check_case(
        "Apart[(x+1)/(x(x-1)),x]",
        "Plus[Times[-1, Power[x, -1]], Times[2, Power[Plus[-1, x], -1]]]");
    check_case(
        "Apart[1/(x^2(x+1)),x]",
        "Plus[Power[x, -2], Power[Plus[1, x], -1], Times[-1, Power[x, -1]]]");
    check_case(
        "Apart[(x^2+y)/(x(x-1)),x]",
        "Plus[1, Times[-1, y, Power[x, -1]], Times[Plus[1, y], Power[Plus[-1, x], -1]]]");
    check_case(
        "Apart[(x+y)/(x(y-1)),y]",
        "Times[Plus[1, Times[Plus[1, x], Power[Plus[-1, y], -1]]], Power[x, -1]]");
    check_case(
        "Apart[1/(4x^2-1),x]",
        "Plus[Times[Rational[-1, 2], Power[Plus[1, Times[2, x]], -1]], Times[Rational[1, 2], Power[Plus[-1, Times[2, x]], -1]]]");
}

void factor_list_tests() {
    check_case(
        "FactorList[2x^2-2]",
        "List[List[2, 1], List[Plus[-1, x], 1], List[Plus[1, x], 1]]");
    check_case(
        "FactorList[x^4-1]",
        "List[List[1, 1], List[Plus[-1, x], 1], List[Plus[1, x], 1], List[Plus[1, Power[x, 2]], 1]]");
    check_case(
        "FactorList[(x-1)^2(x+2)^3]",
        "List[List[1, 1], List[Plus[-1, x], 2], List[Plus[2, x], 3]]");
    check_case(
        "FactorList[x^2-y^2]",
        "List[List[1, 1], List[Plus[x, Times[-1, y]], 1], List[Plus[x, y], 1]]");
    check_case(
        "FactorList[3x^2 y+6x y^2+3y^3]",
        "List[List[3, 1], List[y, 1], List[Plus[x, y], 2]]");
    check_case(
        "FactorList[x^2+1,Extension->{I}]",
        "List[List[1, 1], List[Plus[Complex[0, -1], x], 1], List[Plus[Complex[0, 1], x], 1]]");
    check_case(
        "FactorList[x^2+1,Modulus->2]",
        "List[List[1, 1], List[Plus[1, x], 2]]");
    check_case("FactorList[0]", "List[List[0, 1]]");
}

void resultant_contract_tests() {
    check_case(
        "Discriminant[a x^2+b x+c,x]",
        "Plus[Power[b, 2], Times[-4, a, c]]");
    check_case("Discriminant[x^3+x+1,x]", "-31");
    check_case("Discriminant[(1/2)x^2+3x+1,x]", "7");
    check_case("Discriminant[0,x]", "0");
    check_case(
        "Subresultants[x^2-1,x^2-2x+1,x]",
        "List[0, -2, 1]");
    check_case(
        "Subresultants[x^3+a x+b,x^2+c,x]",
        "List[Plus[Power[b, 2], Power[c, 3], Times[-2, a, Power[c, 2]], Times[c, Power[a, 2]]], Plus[a, Times[-1, c]], 1]");
    check_case(
        "Subresultants[a x^2+b x+c,d x+e,x]",
        "List[Plus[Times[-1, b, d, e], Times[a, Power[e, 2]], Times[c, Power[d, 2]]], d]");
    check_case("Subresultants[1,2,x]", "List[2]");
    check_case(
        "Subresultants[x^2-1,x-1,{x,y}]",
        "Subresultants[Plus[-1, Power[x, 2]], Plus[-1, x], List[x, y]]");
}

void root_interval_tests() {
    check_case(
        "RootIntervals[x^2-2]",
        "List[List[List[-2, -1], List[1, 2]], List[List[1], List[1]]]");
    check_case(
        "RootIntervals[x^3-x]",
        "List[List[List[-1, -1], List[0, 0], List[1, 1]], List[List[1], List[1], List[1]]]");
    check_case(
        "RootIntervals[(x-1)^2(x+1)]",
        "List[List[List[-1, -1], List[1, 1]], List[List[1], List[2]]]");
    check_case(
        "RootIntervals[(10x-1)(10x-2)]",
        "List[List[List[0, Rational[1, 5]], List[Rational[1, 5], Rational[1, 5]]], List[List[1], List[1]]]");
    check_case(
        "RootIntervals[(x^2-2)^2(x^2-3)^3]",
        "List[List[List[-2, Rational[-3, 2]], List[Rational[-3, 2], -1], List[1, Rational[3, 2]], List[Rational[3, 2], 2]], List[List[3], List[2], List[2], List[3]]]");
    check_case("RootIntervals[x^2+1]", "List[List[], List[]]");
    check_case("RootIntervals[1]", "RootIntervals[1]");
}

} // namespace

int main() {
    apart_tests();
    factor_list_tests();
    resultant_contract_tests();
    root_interval_tests();
    if (failures != 0)
        std::cerr << failures << " polynomial-algebra test(s) failed\n";
    return failures == 0 ? 0 : 1;
}
