#include "tungsten/evaluator.hpp"
#include "tungsten/parser.hpp"

#include <iostream>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check_case(const std::string &source, const std::string &expected_result,
                std::vector<std::string> expected_messages = {},
                std::vector<std::string> expected_prints = {}) {
  tungsten::Evaluator evaluator;
  const auto evaluated =
      evaluator.evaluate_result(tungsten::parse_input_form(source));
  if (evaluated.result.to_full_form() != expected_result) {
    std::cerr << "FAIL: " << source
              << " result\n  expected: " << expected_result
              << "\n  actual:   " << evaluated.result.to_full_form() << '\n';
    ++failures;
  }

  std::vector<std::string> actual_messages;
  for (const auto &message : evaluated.messages)
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

void contraction_tests() {
  check_case("Dot[{1,2,3},{4,5,6}]", "32");
  check_case("Dot[{{1,2},{3,4}},{5,6}]", "List[17, 39]");
  check_case("Dot[{1,2},{{3,4},{5,6}}]", "List[13, 16]");
  check_case("Dot[{{1,2},{3,4}},{{5,6},{7,8}}]",
             "List[List[19, 22], List[43, 50]]");
  check_case("Dot[{{1,2},{3,4}},{{0,1},{1,0}},{5,6}]", "List[16, 38]");
  check_case("Dot[{},{}]", "List[]");
  check_case("Dot[{{}},{}]", "List[List[]]");
  check_case("Dot[1,2]", "Dot[1, 2]",
             {"Dot::error: Dot currently supports List vectors and List "
              "matrices only."});
  check_case("Dot[{1,2},{3}]", "Dot[List[1, 2], List[3]]",
             {"Dot::error: Dot expects vectors of the same length."});

  check_case("Inner[f,{a,b},{c,d},g]", "g[f[a, c], f[b, d]]");
  check_case("Inner[Times,f[a,b],g[c,d],Plus]",
             "Plus[Times[a, c], Times[b, d]]");
  check_case("Inner[f,{a,b},{c},g]", "Inner[f, List[a, b], List[c], g]",
             {"Inner::error: Inner expects expressions with the same length."});
  check_case("Catch[Inner[Function[{x,y},Print[InputForm[{x,y}]];"
             "If[SameQ[x,b],Throw[stop]];f[x,y]],{a,b,c},{u,v,w},g]]",
             "stop", {}, {"{a, u}", "{b, v}"});

  check_case("Outer[f,{a,b}]", "List[f[a], f[b]]");
  check_case("Outer[f,f[a,b]]", "f[f[a], f[b]]");
  check_case("Outer[f,{a,b},{x,y}]",
             "List[List[f[a, x], f[a, y]], List[f[b, x], f[b, y]]]");
  check_case("Outer[f,{a,{b,c}},g[x,h[y,z]],2]",
             "List[g[f[a, x], h[f[a, y], f[a, z]]], "
             "List[g[f[b, x], h[f[b, y], f[b, z]]], "
             "g[f[c, x], h[f[c, y], f[c, z]]]]]");
  check_case("Catch[Outer[(Print[InputForm[{##}]];If[SameQ[#1,b],"
             "Throw[stop]];q[##])&,{a,b,c},{x,y}]]",
             "stop", {}, {"{a, x}", "{a, y}", "{b, x}"});
  check_case("CheckAbort[Outer[(Print[InputForm[{##}]];If[SameQ[#1,b],"
             "Abort[]];q[##])&,{a,b,c},{x,y}],caught]",
             "caught", {}, {"{a, x}", "{a, y}", "{b, x}"});

  check_case("Cross[{a,b},{c,d}]", "Plus[Times[-1, b, c], Times[a, d]]");
  check_case("Cross[{a,b,c},{d,e,f}]",
             "List[Plus[Times[-1, c, e], Times[b, f]], "
             "Plus[Times[-1, a, f], Times[c, d]], "
             "Plus[Times[-1, b, d], Times[a, e]]]");
  check_case("Cross[SparseArray[{{1}->a},{3}],{c,d,e}]",
             "SparseArray[List[Rule[List[2], Times[-1, a, e]], "
             "Rule[List[3], Times[a, d]]], List[3]]");
  check_case(
      "Cross[{a},{b}]", "Cross[List[a], List[b]]",
      {"Cross::error: Cross currently supports pairs of 2D or 3D vectors."});
}

void sparse_product_tests() {
  check_case("Dot[SparseArray[{{1}->a},{3}],SparseArray[{{1}->b},{3}]]",
             "Times[a, b]");
  check_case("Dot[SparseArray[{{1,2}->a},{2,3}],"
             "SparseArray[{{2,1}->b},{3,2}]]",
             "SparseArray[List[Rule[List[1, 1], Times[a, b]]], List[2, 2]]");
  check_case("Dot[SparseArray[{{1,2}->a},{2,3}],"
             "SparseArray[{{2}->b},{3}]]",
             "SparseArray[List[Rule[List[1], Times[a, b]]], List[2]]");
  check_case("Dot[SparseArray[{{1,2}->a},{2,3}],{x,y,z}]",
             "List[Times[a, y], 0]");
  check_case("Dot[SparseArray[{}, {1000000000}],"
             "SparseArray[{}, {1000000000}]]",
             "0");
}

void trace_tests() {
  check_case("Tr[{a,b,c}]", "Plus[a, b, c]");
  check_case("Tr[{}]", "0");
  check_case("Tr[{{a,b},{c,d}}]", "Plus[a, d]");
  check_case("Tr[{{a,b,c},{d,e,f}}]", "Plus[a, e]");
  check_case("Tr[{{a,b},{c,d}},f]", "f[a, d]");
  check_case("Tr[{{1,2},{3,4}},Plus,1]", "List[4, 6]");
  check_case("Tr[{{1,2},{3,4}},Times,1]", "List[3, 8]");
  check_case("Tr[{{{1,2},{3,4}},{{5,6},{7,8}}},Plus,2]", "List[16, 20]");
  check_case("Tr[{{{1,2},{3,4}},{{5,6},{7,8}}},Times,2]", "List[105, 384]");
  check_case("Tr[{{a,b},{c}},Plus,1]", "Plus[List[a, b], List[c]]",
             {"Plus::error: Listable Function arguments have incompatible list "
              "lengths."});
  check_case("Tr[{{1,2},{3,4}},Plus,0]",
             "Tr[List[List[1, 2], List[3, 4]], Plus, 0]",
             {"Tr::error: Tr level must be a positive integer."});
  check_case("Tr[SparseArray[{}, {1000000000,1000000000}]]", "0");
  check_case("Tr[{{a,b},{c,d}},Function[Null,Print[InputForm[{##}]];f[##]]]",
             "f[a, d]", {}, {"{a, d}"});
}

void exact_linear_algebra_tests() {
  check_case("Det[{}]", "1");
  check_case("Det[{{1,2},{3,4}}]", "-2");
  check_case("Det[{{1,2,3},{0,1,4},{5,6,0}}]", "1");
  check_case("Det[{{a,b,c},{d,e,f},{g,h,i}}]",
             "Plus[Times[a, Plus[Times[-1, f, h], Times[e, i]]], "
             "Times[b, Plus[Times[-1, d, i], Times[f, g]]], "
             "Times[c, Plus[Times[-1, e, g], Times[d, h]]]]");
  check_case("Det[{{1,2},{3}}]", "Det[List[List[1, 2], List[3]]]",
             {"Det::error: Det expects a rectangular matrix."});

  check_case("Inverse[{}]", "List[]");
  check_case("Inverse[{{2}}]", "List[List[Rational[1, 2]]]");
  check_case("Inverse[{{1,2,3},{0,1,4},{5,6,0}}]",
             "List[List[-24, 18, 5], List[20, -15, -4], "
             "List[-5, 4, 1]]");
  check_case("Inverse[{{a,b},{c,d}}]",
             "List[List[Times[d, Power[Plus[Times[-1, b, c], "
             "Times[a, d]], -1]], Times[-1, b, Power[Plus[Times[-1, b, c], "
             "Times[a, d]], -1]]], List[Times[-1, c, Power[Plus[Times[-1, "
             "b, c], Times[a, d]], -1]], Times[a, Power[Plus[Times[-1, b, "
             "c], Times[a, d]], -1]]]]");
  check_case("Inverse[{{1,2},{2,4}}]", "Inverse[List[List[1, 2], List[2, 4]]]",
             {"Inverse::error: Inverse expects a nonsingular matrix."});
  check_case("Inverse[SparseArray[{{1,1}->2,{2,2}->4},{2,2}]]",
             "SparseArray[List[Rule[List[1, 1], Rational[1, 2]], "
             "Rule[List[2, 2], Rational[1, 4]]], List[2, 2]]");
  check_case("Inverse[SparseArray[{}, {1000000000,1000000000}]]",
             "Inverse[SparseArray[List[], List[1000000000, 1000000000]]]",
             {"Inverse::error: Inverse expects a nonsingular matrix."});

  check_case("MatrixPower[{{1,2},{3,4}},0]", "List[List[1, 0], List[0, 1]]");
  check_case("MatrixPower[{{1,1},{1,0}},5]", "List[List[8, 5], List[5, 3]]");
  check_case("MatrixPower[{{2}},-3]", "List[List[Rational[1, 8]]]");
  check_case("MatrixPower[{{1,2,3},{0,1,4},{5,6,0}},-2]",
             "List[List[911, -682, -187], List[-760, 569, 156], "
             "List[195, -146, -40]]");
  check_case("MatrixPower[SparseArray[{{1,2}->1,{2,1}->1},{2,2}],2]",
             "SparseArray[List[Rule[List[1, 1], 1], Rule[List[2, 2], 1]], "
             "List[2, 2]]");
  check_case("MatrixPower[{{1,2},{3,4}},1/2]",
             "MatrixPower[List[List[1, 2], List[3, 4]], "
             "Times[1, Power[2, -1]]]",
             {"MatrixPower::error: MatrixPower expects an integer argument."});
}

void qualified_head_tests() {
  check_case("System`Dot[{1,2},{3,4}]", "System`Dot[List[1, 2], List[3, 4]]");
  check_case("System`Inner[f,{a,b},{c,d},g]",
             "System`Inner[f, List[a, b], List[c, d], g]");
  check_case("System`Outer[f,{a,b},{c,d}]",
             "System`Outer[f, List[a, b], List[c, d]]");
  check_case("System`Cross[{a,b},{c,d}]",
             "System`Cross[List[a, b], List[c, d]]");
  check_case("System`Tr[{{a,b},{c,d}}]",
             "System`Tr[List[List[a, b], List[c, d]]]");
  check_case("System`Det[{}]", "System`Det[List[]]");
  check_case("System`Inverse[{{2}}]", "System`Inverse[List[List[2]]]");
  check_case("System`MatrixPower[{{2}},-1]",
             "System`MatrixPower[List[List[2]], -1]");
}

} // namespace

int main() {
  contraction_tests();
  sparse_product_tests();
  trace_tests();
  exact_linear_algebra_tests();
  qualified_head_tests();
  if (failures != 0)
    std::cerr << failures << " tensor/matrix test(s) failed\n";
  return failures == 0 ? 0 : 1;
}
