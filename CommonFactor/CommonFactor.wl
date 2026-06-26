(* ::Package:: *)

(* :Title: CommonFactor *)
(* :Context: CommonFactor` *)
(* :Author: OpenAI Codex, for Vladimir Reshetnikov *)
(* :Summary:
   Heuristic discovery of large symbolic common factors in finite exact
   integer and rational sequences.

   Given exact data a_n, the package searches for a product F(n) built
   from symbolic sequence factors such as c^n, prime-valuation powers, linear
   terms, factorials, double factorials, Pochhammer/falling factorials, Gamma
   quotients, multinomials, Catalan numbers, BarnesG superfactorials, and
   periodic signs.  Integer data without zeros use a fast exact-divisibility
   path.  Rational data and data with zeros use a zero-aware rational path that
   optimizes residual complexity and can represent removable quotient values as
   holes.  The remaining quotient sequence is meant to be slower-growing and
   easier to inspect with FindSequenceFunction or by hand.

   The method is deliberately best-effort.  It discovers candidates in stages,
   tests exact divisibility on the observed index range, scores candidates by
   growth minus a small formula-complexity penalty, and greedily peels off the
   strongest currently available factor.  It returns diagnostics rather than a
   theorem: the selected product is a compact common factor supported by the
   sample, not a proof that no other symbolic factor exists.
*)

BeginPackage["CommonFactor`"];

FindSymbolicCommonFactor::usage =
  "FindSymbolicCommonFactor[seq, n] returns a symbolic expression F[n] that \
is a best-effort common symbolic factor of the observed exact integer or \
rational terms of seq, with indices n = 1, 2, ... . \
FindSymbolicCommonFactor[seq, n, \"IndexStart\" -> n0] uses indices n0, n0+1, ... . \
The result is the factor found by CommonFactorReduce.  Use CommonFactorReduce \
for the quotient sequence and diagnostics.";

CommonFactorReduce::usage =
  "CommonFactorReduce[seq, n] returns an Association describing a best-effort \
symbolic common-factor decomposition of a finite exact integer or rational \
sequence.  Main \
keys include \"Factor\", \"QuotientSequence\", \"SelectedFactors\", \
\"ResidualGCD\", \"CandidateCount\", \"IndexRange\", and \"TimedOut\".  Options \
include \"IndexStart\", \"Bases\", \"CandidateShifts\", \
\"IncludeValuationCandidates\", \"IncludeDefaultCandidates\", \
\"IncludeExtendedCandidates\", \"ExtraCandidates\", \"IncludeConstantFactor\", \
\"MaxCandidatePower\", \"MaxSteps\", \"Progress\", \"QuotientTarget\", \
\"BeamWidth\", \"RatioPairLimit\", \"TemporaryDamageAllowance\", and \
TimeConstraint.  Rational and zero-containing input returns additional \
diagnostics such as \"ResidualComplexity\", \"ZeroIndices\", \
\"UnknownQuotientIndices\", and \"KnownResidualPairs\".";

CommonFactorCandidateReport::usage =
  "CommonFactorCandidateReport[seq, n] returns the generated candidate factors \
that divide the original sequence, annotated with their observed values, maximum \
common exponent, growth score, and complexity.  It is useful for inspecting why \
CommonFactorReduce chose a particular factor.";

CommonFactorReduce::seq =
  "The input sequence must be a non-empty list of exact integers or rationals.";
CommonFactorReduce::start =
  "\"IndexStart\" must be an integer.";
CommonFactorReduce::opt =
  "Invalid option value for `1`: `2`.";
CommonFactorReduce::cand =
  "Ignoring candidate `1`, whose observed values are not valid exact values on the requested index range.";
CommonFactorReduce::timeout =
  "TimeConstraint elapsed; returning the best factor found so far.";

Options[CommonFactorReduce] = {
  "IndexStart" -> 1,
  "Bases" -> Range[2, 12],
  "CandidateShifts" -> Range[-3, 5],
  "IncludeValuationCandidates" -> True,
  "IncludeDefaultCandidates" -> True,
  "IncludeExtendedCandidates" -> True,
  "ExtraCandidates" -> {},
  "IncludeConstantFactor" -> False,
  "MaxCandidatePower" -> 64,
  "MaxSteps" -> 64,
  "SearchRounds" -> Automatic,
  "BaseGrowthStep" -> 12,
  "ShiftGrowthStep" -> 4,
  "ExtendedOrderMax" -> 6,
  "ComplexityPenalty" -> 0.03,
  "QuotientTarget" -> Automatic,
  "BeamWidth" -> 32,
  "RatioPairLimit" -> 64,
  "TemporaryDamageAllowance" -> Automatic,
  "Progress" -> True,
  TimeConstraint -> Infinity
};
Options[FindSymbolicCommonFactor] = Options[CommonFactorReduce];
Options[CommonFactorCandidateReport] = Options[CommonFactorReduce];

SetAttributes[{FindSymbolicCommonFactor, CommonFactorReduce,
  CommonFactorCandidateReport}, HoldRest];

Begin["`Private`"];

validIntegerSequenceQ[seq_] := ListQ[seq] && seq =!= {} &&
  VectorQ[seq, IntegerQ] && FreeQ[seq, 0];

exactRationalValueQ[x_] := IntegerQ[x] || Head[x] === Rational;

validExactRationalSequenceQ[seq_] := ListQ[seq] && seq =!= {} &&
  VectorQ[seq, exactRationalValueQ];

validSequenceQ[seq_] := validIntegerSequenceQ[seq];

indexRange[start_Integer, len_Integer] := Range[start, start + len - 1];

integerDivisibleQ[a_Integer, b_Integer] := b =!= 0 && Mod[a, b] === 0;

divideByValues[residuals_, values_] := MapThread[Quotient, {residuals, values}];

dividesAllQ[residuals_, values_] :=
  And @@ MapThread[integerDivisibleQ, {residuals, values}];

remainingTime[deadline_] :=
  If[deadline === Infinity, Infinity, Max[0., deadline - AbsoluteTime[]]];

expiredQ[deadline_] := deadline =!= Infinity && AbsoluteTime[] >= deadline;

makeDeadline[tc_] := Which[
  tc === Infinity, Infinity,
  NumericQ[tc] && TrueQ[tc >= 0], AbsoluteTime[] + N[tc],
  True, $Failed
];

maxPowerAndResidual[residuals_, values_, maxPower_] := Module[
  {k = 0, r = residuals, cap},
  cap = Replace[maxPower, Infinity -> 10^9];
  While[k < cap && dividesAllQ[r, values],
    r = divideByValues[r, values];
    k++];
  {k, r}];

candidateComplexity[expr_] := LeafCount[Unevaluated[expr]];

candidateGrowth[values_] := N[Mean[Log[Abs[values]]], 40];

rationalCandidateGrowth[values_] := Module[{nonzero},
  nonzero = DeleteCases[values, 0];
  If[nonzero === {}, 0,
    N[Mean[Log[Max[1, Abs[Numerator[#]], Abs[Denominator[#]]]] & /@ nonzero], 40]]
];

missingRemovableZeroQ[expr_] := MatchQ[expr, Missing["RemovableZero"]];

knownValues[seq_] := DeleteCases[seq, _Missing];

knownResidualPairs[residuals_, indices_] :=
  Cases[Transpose[{indices, residuals}],
    {i_, q_} /; ! MissingQ[q] :> {i, q}];

unknownQuotientIndices[residuals_, indices_] :=
  Cases[Transpose[{indices, residuals}],
    {i_, q_} /; missingRemovableZeroQ[q] :> i];

knownIntegerResidualQ[residuals_] :=
  AllTrue[knownValues[residuals], IntegerQ];

completeIntegerResidualQ[residuals_] :=
  FreeQ[residuals, _Missing] && knownIntegerResidualQ[residuals];

zeroAwareQuotient[residuals_, values_] := Module[{pairs},
  pairs = MapThread[
    Which[
      MissingQ[#1] && exactRationalValueQ[#2], Missing["RemovableZero"],
      ! exactRationalValueQ[#1] || ! exactRationalValueQ[#2], $Failed,
      #1 =!= 0 && #2 === 0, $Failed,
      #1 === 0 && #2 === 0, Missing["RemovableZero"],
      #2 =!= 0, #1/#2,
      True, $Failed
    ] &,
    {residuals, values}];
  If[MemberQ[pairs, $Failed], $Failed, pairs]
];

rationalHeight[q_] :=
  Log[Max[1, Abs[Numerator[q]], Abs[Denominator[q]]]];

rationalNumHeight[q_] := Log[Max[1, Abs[Numerator[q]]]];

rationalDenHeight[q_] := Log[Denominator[q]];

rationalValuationL1[_] := 0;

rationalComplexityVector[residuals_] := Module[{known, nonzero},
  known = knownValues[residuals];
  nonzero = DeleteCases[known, 0];
  <|
    "SizeHeight" -> N[Total[rationalHeight /@ known], 40],
    "NumeratorHeight" -> N[Total[rationalNumHeight /@ known], 40],
    "DenominatorHeight" -> N[Total[rationalDenHeight /@ known], 40],
    "ValuationL1" -> Total[rationalValuationL1 /@ nonzero],
    "UnknownCount" -> Count[residuals, _Missing],
    "KnownCount" -> Length[known],
    "KnownIntegerQ" -> AllTrue[known, IntegerQ],
    "CompleteIntegerQ" -> FreeQ[residuals, _Missing] && AllTrue[known, IntegerQ]
  |>
];

normalizeQuotientTarget[target_, seq_] := Which[
  target === Automatic && VectorQ[seq, IntegerQ], "Integer",
  target === Automatic, "Rational",
  MemberQ[{"Rational", "Integer", "PreferInteger"}, target], target,
  True, $Failed
];

rationalResidualScalar[vec_Association, target_] := Module[
  {base, integerBonus},
  base = vec["SizeHeight"] + 0.35 vec["DenominatorHeight"] +
    0.02 vec["ValuationL1"] + vec["UnknownCount"];
  integerBonus = Which[
    target === "PreferInteger" && TrueQ[vec["CompleteIntegerQ"]], 8,
    target === "PreferInteger" && TrueQ[vec["KnownIntegerQ"]], 3,
    target === "Integer" && TrueQ[vec["CompleteIntegerQ"]], 4,
    True, 0
  ];
  N[base - integerBonus, 40]
];

rationalStateObjective[scoreVector_, formulaComplexity_, penalty_, target_] :=
  N[rationalResidualScalar[scoreVector, target] + penalty formulaComplexity, 40];

rationalStateAllowedQ[residuals_, target_] := Which[
  target === "Integer", knownIntegerResidualQ[residuals],
  True, True
];

validCandidateValuesQ[values_, allowUnit_: False] :=
  VectorQ[values, IntegerQ] && AllTrue[values, # =!= 0 &] &&
    (AnyTrue[values, Abs[#] > 1 &] ||
      (TrueQ[allowUnit] && AnyTrue[values, Negative]));

safeValues[expr_, n_Symbol, indices_] := Quiet[
  Check[expr /. n -> # & /@ indices, $Failed],
  {Power::infy, Infinity::indet, General::stop, Factorial::fact,
   BarnesG::arg, Gamma::infy}
];

makeCandidate[expr_, n_Symbol, indices_, kind_, label_: Automatic,
   warn_: False, meta_: <||>] := Module[
  {values, heldLabel, allowUnit},
  allowUnit = TrueQ[Lookup[meta, "AllowUnitValues", False]];
  values = safeValues[expr, n, indices];
  If[values === $Failed || ! validCandidateValuesQ[values, allowUnit],
    If[TrueQ[warn], Message[CommonFactorReduce::cand, HoldForm[expr]]];
    Return[Nothing]];
  heldLabel = If[label === Automatic,
    ToString[Unevaluated[expr], InputForm], ToString[label, InputForm]];
  Join[
    <|
      "Expression" -> expr,
      "Label" -> heldLabel,
      "Kind" -> kind,
      "Values" -> values,
      "GrowthScore" -> candidateGrowth[values],
      "Complexity" -> candidateComplexity[expr]
    |>,
    KeyDrop[meta, "AllowUnitValues"]
  ]];

validRationalCandidateValuesQ[values_] :=
  VectorQ[values, exactRationalValueQ] && ! AllTrue[values, # === 1 &];

makeRationalCandidate[expr_, n_Symbol, indices_, kind_, label_: Automatic,
   warn_: False, meta_: <||>] := Module[{values, heldLabel},
  values = TimeConstrained[safeValues[expr, n, indices], 0.05, $Failed];
  If[values === $Failed || ! validRationalCandidateValuesQ[values],
    If[TrueQ[warn], Message[CommonFactorReduce::cand, HoldForm[expr]]];
    Return[Nothing]];
  heldLabel = If[label === Automatic,
    ToString[Unevaluated[expr], InputForm], ToString[label, InputForm]];
  Join[
    <|
      "Expression" -> expr,
      "Label" -> heldLabel,
      "Kind" -> kind,
      "Values" -> values,
      "GrowthScore" -> rationalCandidateGrowth[values],
      "Complexity" -> candidateComplexity[expr]
    |>,
    meta
  ]];

normalizeExtraCandidate[item_, n_Symbol, indices_] := Which[
  MatchQ[item, _Rule],
    makeCandidate[item[[2]], n, indices, "Extra", item[[1]], True],
  AssociationQ[item] && KeyExistsQ[item, "Expression"],
    makeCandidate[item["Expression"], n, indices,
      Lookup[item, "Kind", "Extra"], Lookup[item, "Label", Automatic], True],
  True,
    makeCandidate[item, n, indices, "Extra", Automatic, True]
];

normalizeRationalExtraCandidate[item_, n_Symbol, indices_] := Which[
  MatchQ[item, _Rule],
    makeRationalCandidate[item[[2]], n, indices, "Extra", item[[1]], True],
  AssociationQ[item] && KeyExistsQ[item, "Expression"],
    makeRationalCandidate[item["Expression"], n, indices,
      Lookup[item, "Kind", "Extra"], Lookup[item, "Label", Automatic], True],
  True,
    makeRationalCandidate[item, n, indices, "Extra", Automatic, True]
];

candidateListFromRules[rules_, n_Symbol, indices_, deadline_,
   warn_: False, meta_: <||>] := Module[{out = {}, c},
  Do[
    If[expiredQ[deadline], Break[]];
    c = makeCandidate[First[rule], n, indices, Last[rule], Automatic, warn, meta];
    If[AssociationQ[c], AppendTo[out, c]],
    {rule, rules}];
  out];

rationalCandidateListFromRules[rules_, n_Symbol, indices_, deadline_,
   warn_: False, meta_: <||>] := Module[{out = {}, c},
  Do[
    If[expiredQ[deadline], Break[]];
    c = makeRationalCandidate[First[rule], n, indices, Last[rule],
      Automatic, warn, meta];
    If[AssociationQ[c], AppendTo[out, c]],
    {rule, rules}];
  out];

withReciprocalRules[rules_] := Module[{recip},
  recip = Cases[rules, Rule[expr_, kind_] :> (1/expr -> kind <> "Reciprocal")];
  Join[rules, recip]
];

defaultCandidateExpressions[n_Symbol, bases_, shifts_] := Module[
  {powerShifts, nonnegativeShifts, linear, powers, factorials,
   doubleFactorials, binomials, catalans, fibs},

  powerShifts = Select[shifts, # >= -1 &];
  nonnegativeShifts = Select[shifts, # >= 0 &];

  linear = DeleteDuplicates@Join[
    Table[n + s, {s, shifts}],
    Table[2 n + s, {s, shifts}]
  ];

  powers = DeleteDuplicates@Flatten[
    Table[b^(n + s), {b, bases}, {s, powerShifts}]
  ];

  factorials = DeleteDuplicates@Join[
    Table[Factorial[n + s], {s, shifts}],
    Table[Factorial[2 n + s], {s, shifts}]
  ];

  doubleFactorials = DeleteDuplicates@Join[
    Table[Factorial2[n + s], {s, shifts}],
    Table[Factorial2[2 n + s], {s, shifts}]
  ];

  binomials = DeleteDuplicates@Join[
    Table[Binomial[2 n + s, n], {s, shifts}],
    Table[Binomial[2 n + s, n + s], {s, shifts}],
    Table[Binomial[3 n + s, n], {s, nonnegativeShifts}]
  ];

  catalans = DeleteDuplicates@Table[CatalanNumber[n + s], {s, shifts}];
  fibs = DeleteDuplicates@Join[
    Table[Fibonacci[n + s], {s, nonnegativeShifts}],
    Table[LucasL[n + s], {s, nonnegativeShifts}]
  ];

  Join[
    Thread[linear -> "Linear"],
    Thread[powers -> "Power"],
    Thread[factorials -> "Factorial"],
    Thread[doubleFactorials -> "DoubleFactorial"],
    Thread[binomials -> "Binomial"],
    Thread[catalans -> "Catalan"],
    Thread[fibs -> "Recurrence"]
  ]];

extendedCandidateExpressions[n_Symbol, bases_, shifts_, orderMax_] := Module[
  {orders, nonnegativeShifts, quadraticPowers, rising, falling, gammaQuot,
   multinomials, barnes},

  orders = Range[2, orderMax];
  nonnegativeShifts = Select[shifts, # >= 0 &];

  quadraticPowers = DeleteDuplicates@Flatten[{
    Table[b^(n^2 + s), {b, bases}, {s, Select[shifts, # >= 0 &]}],
    Table[b^(n^2 + n + s), {b, bases}, {s, nonnegativeShifts}],
    Table[b^(n^2 - n + s), {b, bases}, {s, nonnegativeShifts}],
    Table[b^(n (n + 1)/2 + s), {b, bases}, {s, nonnegativeShifts}],
    Table[b^(n (n - 1)/2 + s), {b, bases}, {s, nonnegativeShifts}]
  }];

  rising = DeleteDuplicates@Flatten[
    Table[Pochhammer[n + s, k], {s, shifts}, {k, orders}]
  ];

  falling = DeleteDuplicates@Flatten[
    Table[FactorialPower[n + s, k], {s, shifts}, {k, orders}]
  ];

  gammaQuot = DeleteDuplicates@Flatten[{
    Table[Gamma[n + s + k]/Gamma[n + s], {s, shifts}, {k, orders}],
    Table[Gamma[2 n + s + 1]/Gamma[n + s + 1], {s, shifts}],
    Table[Gamma[3 n + s + 1]/Gamma[n + s + 1], {s, shifts}],
    Table[Gamma[2 n + s + 1]/Gamma[n + 1], {s, shifts}]
  }];

  multinomials = DeleteDuplicates@Flatten[{
    {Multinomial[n, n], Multinomial[n, n, n], Multinomial[n, n, n, n]},
    Table[Multinomial[n + s, n, n], {s, shifts}],
    Table[Multinomial[n + s, n + s, n], {s, shifts}],
    Table[Multinomial[2 n + s, n, n], {s, shifts}]
  }];

  barnes = DeleteDuplicates@Join[
    Table[BarnesG[n + s], {s, shifts}],
    Table[BarnesG[n + s + 2], {s, shifts}]
  ];

  Join[
    Thread[quadraticPowers -> "QuadraticPower"],
    Thread[rising -> "Pochhammer"],
    Thread[falling -> "FallingFactorial"],
    Thread[gammaQuot -> "GammaQuotient"],
    Thread[multinomials -> "Multinomial"],
    Thread[barnes -> "BarnesG"]
  ]];

signCandidateExpressions[n_Symbol, periods_: Range[2, 6]] := Module[
  {basic, periodic},
  basic = {-1, (-1)^n, -(-1)^n, (-1)^(n + 1), -(-1)^(n + 1)};
  periodic = Flatten@Table[
    {(-1)^Mod[n - r, p], -(-1)^Mod[n - r, p]},
    {p, periods}, {r, 0, p - 1}];
  Thread[DeleteDuplicates@Join[basic, periodic] -> "Sign"]];

rationalRatioCandidateExpressions[n_Symbol, shifts_, orderMax_, limit_] := Module[
  {pairs, orders, nonnegativeShifts, linearRatios, factorialRatios,
   pochhammerRatios, fallingRatios, combinatorialRatios},

  pairs = DeleteCases[Tuples[shifts, 2], {s_, s_}];
  pairs = Take[pairs, UpTo[limit]];
  orders = Range[2, orderMax];
  nonnegativeShifts = Select[shifts, # >= 0 &];

  linearRatios = (n + #[[1]])/(n + #[[2]]) & /@ pairs;

  factorialRatios = Flatten[{
    Factorial[n + #[[1]]]/Factorial[n + #[[2]]] & /@ pairs,
    Flatten[Table[
      Factorial[2 n + s]/Factorial[n + t],
      {s, shifts}, {t, shifts}]]
  }];

  pochhammerRatios = Flatten[Table[
    Pochhammer[n + s, k]/Pochhammer[n + t, k],
    {s, shifts}, {t, shifts}, {k, orders}]];

  fallingRatios = Flatten[Table[
    FactorialPower[n + s, k]/FactorialPower[n + t, k],
    {s, shifts}, {t, shifts}, {k, orders}]];

  combinatorialRatios = Flatten[{
    Table[Binomial[2 n + s, n]/Factorial[n + t],
      {s, shifts}, {t, shifts}],
    Table[CatalanNumber[n + s]/Factorial[n + t],
      {s, nonnegativeShifts}, {t, shifts}]
  }];

  Join[
    Thread[DeleteDuplicates[linearRatios] -> "LinearRatio"],
    Thread[DeleteDuplicates[factorialRatios] -> "FactorialRatio"],
    Thread[DeleteDuplicates[pochhammerRatios] -> "PochhammerRatio"],
    Thread[DeleteDuplicates[fallingRatios] -> "FallingFactorialRatio"],
    Thread[DeleteDuplicates[combinatorialRatios] -> "CombinatorialRatio"]
  ]];

consecutiveRuns[values_] := Split[Sort[values], #2 === #1 + 1 &];

zeroMaskCandidateExpressions[n_Symbol, zeroIndices_] := Module[
  {roots, runs, singles, product, runFactors},
  roots = Sort@DeleteDuplicates[zeroIndices];
  If[roots === {}, Return[{}]];
  singles = (n - # -> "ZeroRoot") & /@ roots;
  product = If[Length[roots] > 1,
    {Times @@ ((n - #) & /@ roots) -> "ZeroRootProduct"},
    {}];
  runs = Select[consecutiveRuns[roots], Length[#] > 1 &];
  runFactors = Flatten[Function[run,
      {
        FactorialPower[n - First[run], Length[run]] -> "ZeroRootRun",
        Pochhammer[n - Last[run], Length[run]] -> "ZeroRootRun"
      }] /@ runs];
  DeleteDuplicates@Join[singles, product, runFactors]
];

integerPolynomialValuesQ[poly_, n_Symbol, indices_, vals_] := Module[
  {pv = Simplify[poly /. n -> #] & /@ indices},
  And @@ MapThread[TrueQ[#1 == #2] &, {pv, vals}] &&
    AllTrue[pv, IntegerQ[#] && # >= 0 &] && AnyTrue[pv, # > 0 &]];

exactValuationPolynomial[indices_, vals_, n_Symbol, degree_Integer] := Module[
  {poly},
  If[Length[indices] < degree + 1, Return[Nothing]];
  poly = Expand@InterpolatingPolynomial[
      Transpose[{Take[indices, degree + 1], Take[vals, degree + 1]}], n];
  If[Exponent[poly, n] > 0 && Exponent[poly, n] <= degree &&
      integerPolynomialValuesQ[poly, n, indices, vals],
    poly,
    Nothing
  ]];

lowerAffineValuationPolynomial[indices_, vals_, n_Symbol] := Module[
  {x, slopes, a, b, poly, pv},
  If[Length[indices] < 2, Return[Nothing]];
  x = indices - First[indices];
  slopes = MapThread[If[#2 > 0, Floor[#1/#2], Infinity] &, {vals, x}];
  slopes = DeleteCases[slopes, Infinity];
  If[slopes === {}, Return[Nothing]];
  a = Min[slopes];
  If[a <= 0, Return[Nothing]];
  b = Min[vals - a x];
  If[b < 0, Return[Nothing]];
  poly = Expand[a (n - First[indices]) + b];
  pv = poly /. n -> # & /@ indices;
  If[AllTrue[pv, IntegerQ[#] && # >= 0 &] &&
      And @@ MapThread[#1 <= #2 &, {pv, vals}] &&
      AnyTrue[pv, # > 0 &],
    poly,
    Nothing
  ]];

integerProfileValuesQ[poly_, n_Symbol, indices_, vals_] := Module[
  {pv = Simplify[poly /. n -> #] & /@ indices},
  And @@ MapThread[TrueQ[#1 == #2] &, {pv, vals}] &&
    AllTrue[pv, IntegerQ]
];

exactSignedValuationPolynomial[indices_, vals_, n_Symbol, degree_Integer] := Module[
  {poly, pv},
  If[Length[indices] < degree + 1, Return[Nothing]];
  poly = Expand@InterpolatingPolynomial[
      Transpose[{Take[indices, degree + 1], Take[vals, degree + 1]}], n];
  pv = Simplify[poly /. n -> #] & /@ indices;
  If[Exponent[poly, n] > 0 && Exponent[poly, n] <= degree &&
      integerProfileValuesQ[poly, n, indices, vals] &&
      AnyTrue[pv, # =!= 0 &],
    poly,
    Nothing
  ]];

valuationCandidateExpressions[seq_, n_Symbol, indices_, deadline_] := Module[
  {factorRows = {}, fi, primes, vals, polys, exprs = {}},

  Do[
    If[expiredQ[deadline], Return[{}]];
    fi = If[deadline === Infinity,
      FactorInteger[Abs[term]],
      TimeConstrained[FactorInteger[Abs[term]],
        Max[0.001, remainingTime[deadline]], $TimedOut]];
    If[fi === $TimedOut, Return[{}]];
    AppendTo[factorRows, Association[Rule @@@ fi]],
    {term, seq}];

  primes = Sort@Union[Flatten[Keys /@ factorRows]];
  Do[
    vals = Lookup[factorRows, p, 0];
    polys = DeleteDuplicates@Cases[
      {
        exactValuationPolynomial[indices, vals, n, 1],
        exactValuationPolynomial[indices, vals, n, 2],
        lowerAffineValuationPolynomial[indices, vals, n]
      },
      Except[Nothing]];
    exprs = Join[exprs, Thread[(p^# & /@ polys) -> "ValuationPower"]],
    {p, primes}];
  exprs];

signedValuationCandidateExpressions[seq_, n_Symbol, indices_, deadline_] := Module[
  {supportPairs, factorRows = {}, fiNum, fiDen, primes, vals, polys,
   exprs = {}, supportIndices, supportValues, row},

  supportPairs = Select[Transpose[{indices, seq}], Last[#] =!= 0 &];
  If[supportPairs === {}, Return[{}]];
  supportIndices = supportPairs[[All, 1]];
  supportValues = supportPairs[[All, 2]];

  Do[
    If[expiredQ[deadline], Return[{}]];
    fiNum = If[deadline === Infinity,
      FactorInteger[Abs[Numerator[term]]],
      TimeConstrained[FactorInteger[Abs[Numerator[term]]],
        Max[0.001, remainingTime[deadline]], $TimedOut]];
    If[fiNum === $TimedOut, Return[{}]];
    fiDen = If[deadline === Infinity,
      FactorInteger[Denominator[term]],
      TimeConstrained[FactorInteger[Denominator[term]],
        Max[0.001, remainingTime[deadline]], $TimedOut]];
    If[fiDen === $TimedOut, Return[{}]];
    row = Merge[
      Join[Rule @@@ fiNum, (#[[1]] -> -#[[2]] & /@ fiDen)],
      Total];
    AppendTo[factorRows, Association[row]],
    {term, supportValues}];

  primes = Sort@Union[Flatten[Keys /@ factorRows]];
  Do[
    vals = Lookup[factorRows, p, 0];
    polys = DeleteDuplicates@Cases[
      {
        exactSignedValuationPolynomial[supportIndices, vals, n, 1],
        exactSignedValuationPolynomial[supportIndices, vals, n, 2]
      },
      Except[Nothing]];
    exprs = Join[exprs, Thread[(p^# & /@ polys) -> "SignedValuationPower"]],
    {p, primes}];
  exprs];

dedupeCandidates[candidates_] := Module[{groups},
  groups = GatherBy[candidates, #["Values"] &];
  First@SortBy[#, {#["Complexity"] &, #["Label"] &}] & /@ groups
];

generateCandidates[seq_, n_Symbol, indices_, opts_List, deadline_] := Module[
  {bases, shifts, includeDefaults, includeExtended, includeValuation, extra,
   orderMax, cands = {}, valuationRules, defaultRules, extendedRules, signRules},

  bases = "Bases" /. opts;
  shifts = "CandidateShifts" /. opts;
  orderMax = "ExtendedOrderMax" /. opts;
  includeValuation = TrueQ["IncludeValuationCandidates" /. opts];
  includeDefaults = TrueQ["IncludeDefaultCandidates" /. opts];
  includeExtended = TrueQ["IncludeExtendedCandidates" /. opts];
  extra = Flatten@{"ExtraCandidates" /. opts};

  If[includeValuation && ! expiredQ[deadline],
    valuationRules = valuationCandidateExpressions[seq, n, indices, deadline];
    cands = Join[cands,
      candidateListFromRules[valuationRules, n, indices, deadline]]];

  If[includeDefaults && ! expiredQ[deadline],
    defaultRules = defaultCandidateExpressions[n, bases, shifts];
    cands = Join[cands,
      candidateListFromRules[defaultRules, n, indices, deadline]]];

  If[includeExtended && ! expiredQ[deadline],
    extendedRules = extendedCandidateExpressions[n, bases, shifts, orderMax];
    cands = Join[cands,
      candidateListFromRules[extendedRules, n, indices, deadline]]];

  If[! expiredQ[deadline],
    signRules = signCandidateExpressions[n];
    cands = Join[cands,
      candidateListFromRules[signRules, n, indices, deadline, False,
        <|"AllowUnitValues" -> True, "NonRepeatable" -> True|>]]];

  Do[
    If[expiredQ[deadline], Break[]];
    With[{c = normalizeExtraCandidate[item, n, indices]},
      If[AssociationQ[c], AppendTo[cands, c]]],
    {item, extra}];

  dedupeCandidates[Cases[cands, _Association]]
];

generateRationalCandidates[seq_, n_Symbol, indices_, opts_List, deadline_] := Module[
  {bases, shifts, includeDefaults, includeExtended, includeValuation, extra,
   orderMax, ratioLimit, zeroIndices, cands = {}, valuationRules, defaultRules,
   extendedRules, ratioRules, zeroRules, signRules},

  bases = "Bases" /. opts;
  shifts = "CandidateShifts" /. opts;
  orderMax = "ExtendedOrderMax" /. opts;
  ratioLimit = "RatioPairLimit" /. opts;
  includeValuation = TrueQ["IncludeValuationCandidates" /. opts];
  includeDefaults = TrueQ["IncludeDefaultCandidates" /. opts];
  includeExtended = TrueQ["IncludeExtendedCandidates" /. opts];
  extra = Flatten@{"ExtraCandidates" /. opts};
  zeroIndices = Pick[indices, seq, 0];

  If[includeValuation && ! expiredQ[deadline],
    valuationRules = signedValuationCandidateExpressions[seq, n, indices, deadline];
    cands = Join[cands,
      rationalCandidateListFromRules[valuationRules, n, indices, deadline]]];

  If[includeDefaults && ! expiredQ[deadline],
    defaultRules = withReciprocalRules@defaultCandidateExpressions[n, bases, shifts];
    cands = Join[cands,
      rationalCandidateListFromRules[defaultRules, n, indices, deadline]]];

  If[includeExtended && ! expiredQ[deadline],
    extendedRules = withReciprocalRules@
      extendedCandidateExpressions[n, bases, shifts, orderMax];
    cands = Join[cands,
      rationalCandidateListFromRules[extendedRules, n, indices, deadline]]];

  If[includeExtended && ! expiredQ[deadline],
    ratioRules = rationalRatioCandidateExpressions[n, shifts, orderMax, ratioLimit];
    cands = Join[cands,
      rationalCandidateListFromRules[ratioRules, n, indices, deadline]]];

  If[zeroIndices =!= {} && ! expiredQ[deadline],
    zeroRules = zeroMaskCandidateExpressions[n, zeroIndices];
    cands = Join[cands,
      rationalCandidateListFromRules[zeroRules, n, indices, deadline, False,
        <|"ZeroCovering" -> True|>]]];

  If[! expiredQ[deadline],
    signRules = signCandidateExpressions[n];
    cands = Join[cands,
      rationalCandidateListFromRules[signRules, n, indices, deadline, False,
        <|"AllowUnitValues" -> True, "NonRepeatable" -> True|>]]];

  Do[
    If[expiredQ[deadline], Break[]];
    With[{c = normalizeRationalExtraCandidate[item, n, indices]},
      If[AssociationQ[c], AppendTo[cands, c]]],
    {item, extra}];

  dedupeCandidates[Cases[cands, _Association]]
];

candidateAvailableData[cand_, residuals_, maxPower_, penalty_] := Module[
  {pow, after, baseScore, stepScore, values, signs},

  If[cand["Kind"] === "Sign",
    values = cand["Values"];
    signs = Sign[residuals];
    If[values =!= signs, Return[Nothing]];
    Return[Join[cand, <|
      "AvailableExponent" -> 1,
      "ResidualAfter" -> Abs[residuals],
      "StepScore" -> 0.0001,
      "TotalGrowth" -> 0
    |>]]];

  {pow, after} = maxPowerAndResidual[residuals, cand["Values"], maxPower];
  If[pow <= 0, Return[Nothing]];
  baseScore = N[cand["GrowthScore"] - penalty cand["Complexity"], 40];
  stepScore = N[pow baseScore, 40];
  If[! TrueQ[stepScore > 0], Return[Nothing]];
  Join[cand, <|
    "AvailableExponent" -> pow,
    "ResidualAfter" -> after,
    "StepScore" -> stepScore,
    "TotalGrowth" -> N[pow cand["GrowthScore"], 40]
  |>]];

rationalInitialState[seq_, indices_, penalty_, target_] := Module[
  {vec, obj},
  vec = rationalComplexityVector[seq];
  obj = rationalStateObjective[vec, 0, penalty, target];
  <|
    "Factor" -> 1,
    "FactorValues" -> ConstantArray[1, Length[seq]],
    "ResidualSequence" -> seq,
    "SupportIndices" -> Pick[indices, Unitize[seq], 1],
    "ZeroIndices" -> Pick[indices, seq, 0],
    "UnknownQuotientIndices" -> {},
    "KnownResidualPairs" -> knownResidualPairs[seq, indices],
    "ZeroFactors" -> {},
    "SelectedFactors" -> {},
    "SelectedLabels" -> {},
    "FormulaComplexity" -> 0,
    "ScoreVector" -> vec,
    "Objective" -> obj
  |>
];

rationalPowerCap[cand_, maxPower_] := Which[
  AnyTrue[cand["Values"], # === 0 &], 1,
  True, 1
];

rationalApplyCandidatePower[state_, cand_, exponent_Integer, indices_, penalty_,
   target_] := Module[
  {values, quotient, vec, complexity, obj, expr, zeroFactorQ, selected,
   selectedLabels, zeroFactors, unknowns, knownPairs, stepScore},

  values = cand["Values"]^exponent;
  quotient = zeroAwareQuotient[state["ResidualSequence"], values];
  If[quotient === $Failed || ! rationalStateAllowedQ[quotient, target],
    Return[Nothing]];

  vec = rationalComplexityVector[quotient];
  complexity = state["FormulaComplexity"] + exponent cand["Complexity"];
  obj = rationalStateObjective[vec, complexity, penalty, target];
  expr = cand["Expression"]^exponent;
  zeroFactorQ = AnyTrue[cand["Values"], # === 0 &];
  selected = Append[state["SelectedFactors"],
    KeyDrop[cand, {"Values"}] ~Join~ <|
      "Exponent" -> exponent,
      "StepScore" -> state["Objective"] - obj,
      "TotalGrowth" -> N[exponent cand["GrowthScore"], 40]
    |>];
  selectedLabels = Append[state["SelectedLabels"], cand["Label"]];
  zeroFactors = If[zeroFactorQ,
    Append[state["ZeroFactors"], cand["Expression"]],
    state["ZeroFactors"]];
  unknowns = unknownQuotientIndices[quotient, indices];
  knownPairs = knownResidualPairs[quotient, indices];

  <|
    "Factor" -> state["Factor"] expr,
    "FactorValues" -> state["FactorValues"] values,
    "ResidualSequence" -> quotient,
    "SupportIndices" -> state["SupportIndices"],
    "ZeroIndices" -> state["ZeroIndices"],
    "UnknownQuotientIndices" -> unknowns,
    "KnownResidualPairs" -> knownPairs,
    "ZeroFactors" -> zeroFactors,
    "SelectedFactors" -> selected,
    "SelectedLabels" -> selectedLabels,
    "FormulaComplexity" -> complexity,
    "ScoreVector" -> vec,
    "Objective" -> obj
  |>
];

rationalBestExpansion[state_, cand_, indices_, maxPower_, penalty_, target_,
   damage_] := Module[
  {cap, expansions},
  If[TrueQ[Lookup[cand, "NonRepeatable", False]] &&
      MemberQ[state["SelectedLabels"], cand["Label"]],
    Return[Nothing]];
  cap = rationalPowerCap[cand, maxPower];
  expansions = Cases[
    Table[
      rationalApplyCandidatePower[state, cand, k, indices, penalty, target],
      {k, cap}],
    _Association];
  expansions = Select[expansions, #["Objective"] <= state["Objective"] + damage &];
  If[expansions === {}, Nothing, First@SortBy[expansions, #["Objective"] &]]
];

rationalStateKey[state_] :=
  ToString[InputForm[{state["ResidualSequence"], Sort[state["SelectedLabels"]]}]];

dedupeRationalStates[states_] := Module[{groups},
  groups = GatherBy[states, rationalStateKey];
  First@SortBy[#, {#["Objective"] &, #["FormulaComplexity"] &}] & /@ groups
];

bestRationalState[states_] :=
  First@SortBy[states, {#["Objective"] &, #["FormulaComplexity"] &}];

zeroCoveringStateQ[state_] :=
  AnyTrue[state["SelectedFactors"], TrueQ[Lookup[#, "ZeroCovering", False]] &];

bestCandidate[available_] := First@SortBy[
  available,
  {-#["StepScore"] &, -#["TotalGrowth"] &, #["Complexity"] &, #["Label"] &}
];

mergeSelected[selected_] := Module[{groups},
  groups = GatherBy[selected, #["Expression"] &];
  Function[group,
    Join[First[group], <|
      "Exponent" -> Total[group[[All, "Exponent"]]],
      "StepScore" -> Total[group[[All, "StepScore"]]],
      "TotalGrowth" -> Total[group[[All, "TotalGrowth"]]]
    |>]] /@ groups
];

factorExpression[selected_, n_Symbol, start_Integer, includeConstant_, gcd_] := Module[
  {pieces, expr},
  pieces = (#["Expression"]^#["Exponent"]) & /@ selected;
  expr = Times @@ Join[pieces, If[includeConstant && gcd > 1, {gcd}, {}]];
  If[expr === 1, 1,
    FullSimplify[expr, Element[n, Integers] && n >= start]]
];

factorValuesFromQuotient[seq_, quotient_] := MapThread[Quotient, {seq, quotient}];

emitProgress[progress_, payload_Association] := Which[
  TrueQ[progress],
    Print[
      "CommonFactor: step ", payload["Step"],
      ", factor = ", ToString[payload["Factor"], InputForm],
      ", residual GCD = ", payload["ResidualGCD"]
    ],
  Head[progress] === Function,
    Quiet[progress[payload]],
  True,
    Null
];

validateOptions[opts_List] := Module[
  {bases, shifts, maxPower, maxSteps, rounds, baseStep, shiftStep, orderMax,
   penalty, quotientTarget, beamWidth, ratioLimit, damage, tc, known, seen,
   unknown},
  known = First /@ Options[CommonFactorReduce];
  seen = DeleteDuplicates@Cases[opts, (Rule | RuleDelayed)[k_, _] :> k];
  unknown = Complement[seen, known];
  If[unknown =!= {},
    Message[CommonFactorReduce::opt, "unknown option(s)", unknown];
    Return[False]];

  bases = "Bases" /. opts;
  shifts = "CandidateShifts" /. opts;
  maxPower = "MaxCandidatePower" /. opts;
  maxSteps = "MaxSteps" /. opts;
  rounds = "SearchRounds" /. opts;
  baseStep = "BaseGrowthStep" /. opts;
  shiftStep = "ShiftGrowthStep" /. opts;
  orderMax = "ExtendedOrderMax" /. opts;
  penalty = "ComplexityPenalty" /. opts;
  quotientTarget = "QuotientTarget" /. opts;
  beamWidth = "BeamWidth" /. opts;
  ratioLimit = "RatioPairLimit" /. opts;
  damage = "TemporaryDamageAllowance" /. opts;
  tc = TimeConstraint /. opts;

  If[! (ListQ[bases] && VectorQ[bases, IntegerQ] && AllTrue[bases, # > 1 &]),
    Message[CommonFactorReduce::opt, "\"Bases\"", bases]; Return[False]];
  If[! (ListQ[shifts] && VectorQ[shifts, IntegerQ]),
    Message[CommonFactorReduce::opt, "\"CandidateShifts\"", shifts]; Return[False]];
  If[! (maxPower === Infinity || (IntegerQ[maxPower] && maxPower >= 1)),
    Message[CommonFactorReduce::opt, "\"MaxCandidatePower\"", maxPower]; Return[False]];
  If[! (maxSteps === Infinity || (IntegerQ[maxSteps] && maxSteps >= 0)),
    Message[CommonFactorReduce::opt, "\"MaxSteps\"", maxSteps]; Return[False]];
  If[! (rounds === Automatic || rounds === Infinity || (IntegerQ[rounds] && rounds >= 1)),
    Message[CommonFactorReduce::opt, "\"SearchRounds\"", rounds]; Return[False]];
  If[! (IntegerQ[baseStep] && baseStep >= 0),
    Message[CommonFactorReduce::opt, "\"BaseGrowthStep\"", baseStep]; Return[False]];
  If[! (IntegerQ[shiftStep] && shiftStep >= 0),
    Message[CommonFactorReduce::opt, "\"ShiftGrowthStep\"", shiftStep]; Return[False]];
  If[! (IntegerQ[orderMax] && orderMax >= 2),
    Message[CommonFactorReduce::opt, "\"ExtendedOrderMax\"", orderMax]; Return[False]];
  If[! (NumericQ[penalty] && TrueQ[penalty >= 0]),
    Message[CommonFactorReduce::opt, "\"ComplexityPenalty\"", penalty]; Return[False]];
  If[! (quotientTarget === Automatic ||
      MemberQ[{"Rational", "Integer", "PreferInteger"}, quotientTarget]),
    Message[CommonFactorReduce::opt, "\"QuotientTarget\"", quotientTarget]; Return[False]];
  If[! (IntegerQ[beamWidth] && beamWidth >= 1),
    Message[CommonFactorReduce::opt, "\"BeamWidth\"", beamWidth]; Return[False]];
  If[! (IntegerQ[ratioLimit] && ratioLimit >= 0),
    Message[CommonFactorReduce::opt, "\"RatioPairLimit\"", ratioLimit]; Return[False]];
  If[! (damage === Automatic || (NumericQ[damage] && TrueQ[damage >= 0])),
    Message[CommonFactorReduce::opt, "\"TemporaryDamageAllowance\"", damage]; Return[False]];
  If[! (tc === Infinity || (NumericQ[tc] && TrueQ[tc >= 0])),
    Message[CommonFactorReduce::opt, "TimeConstraint", tc]; Return[False]];
  If[rounds === Infinity && tc === Infinity,
    Message[CommonFactorReduce::opt, "\"SearchRounds\"",
      "Infinity requires a finite TimeConstraint"];
    Return[False]];
  True
];

setOptionValue[opts_, key_, value_] :=
  Prepend[DeleteCases[opts, r_Rule /; First[r] === key], key -> value];

expandedOptionsForRound[opts_List, round_Integer] := Module[
  {bases, shifts, baseStep, shiftStep, orderMax, maxBase, radius, out},
  If[round <= 1, Return[opts]];
  bases = "Bases" /. opts;
  shifts = "CandidateShifts" /. opts;
  baseStep = "BaseGrowthStep" /. opts;
  shiftStep = "ShiftGrowthStep" /. opts;
  orderMax = "ExtendedOrderMax" /. opts;
  maxBase = Max[bases] + (round - 1) baseStep;
  radius = Max[Abs[shifts]] + (round - 1) shiftStep;
  out = setOptionValue[opts, "Bases", Range[2, maxBase]];
  out = setOptionValue[out, "CandidateShifts", Range[-radius, radius]];
  setOptionValue[out, "ExtendedOrderMax", orderMax + round - 1]
];

roundLimit[rounds_, tc_] := Which[
  rounds === Automatic && tc === Infinity, 1,
  rounds === Automatic, Infinity,
  True, rounds
];

finalAssociation[seq_, n_Symbol, start_Integer, selected_, residuals_, candidates_,
   includeConstant_, timedOut_, elapsed_, tc_] := Module[
  {selectedMerged, residualGCD, quotient, factor},
  selectedMerged = mergeSelected[selected];
  residualGCD = GCD @@ Abs[residuals];
  quotient = If[includeConstant && residualGCD > 1,
    divideByValues[residuals, ConstantArray[residualGCD, Length[residuals]]],
    residuals];
  factor = factorExpression[selectedMerged, n, start, includeConstant, residualGCD];

  <|
    "Factor" -> factor,
    "FactorValues" -> factorValuesFromQuotient[seq, quotient],
    "QuotientSequence" -> quotient,
    "ResidualSequence" -> residuals,
    "ResidualGCD" -> residualGCD,
    "SelectedFactors" -> (KeyDrop[#, {"Values"}] & /@ selectedMerged),
    "CandidateCount" -> Length[candidates],
    "IndexRange" -> indexRange[start, Length[seq]],
    "InputSequence" -> seq,
    "TimedOut" -> timedOut,
    "ElapsedTime" -> elapsed,
    "TimeConstraint" -> tc
  |>];

rationalFactorExpression[expr_, n_Symbol, start_Integer] :=
  If[expr === 1, 1, FullSimplify[expr, Element[n, Integers] && n >= start]];

finalRationalAssociation[seq_, n_Symbol, start_Integer, state_, candidates_,
   target_, timedOut_, elapsed_, tc_, diagnostic_: None] := Module[
  {factor},
  factor = rationalFactorExpression[state["Factor"], n, start];
  <|
    "Factor" -> factor,
    "FactorValues" -> state["FactorValues"],
    "QuotientSequence" -> state["ResidualSequence"],
    "ResidualSequence" -> state["ResidualSequence"],
    "ResidualComplexity" -> state["ScoreVector"],
    "ResidualGCD" -> Missing["NotApplicable"],
    "SelectedFactors" -> (KeyDrop[#, {"Values"}] & /@ state["SelectedFactors"]),
    "CandidateCount" -> Length[candidates],
    "IndexRange" -> indexRange[start, Length[seq]],
    "SupportIndices" -> state["SupportIndices"],
    "ZeroIndices" -> state["ZeroIndices"],
    "UnknownQuotientIndices" -> state["UnknownQuotientIndices"],
    "KnownResidualPairs" -> state["KnownResidualPairs"],
    "ZeroFactors" -> state["ZeroFactors"],
    "InputSequence" -> seq,
    "InputDomain" -> "Rational",
    "SearchMode" -> "Beam",
    "QuotientTarget" -> target,
    "KnownIntegerQuotient" -> knownIntegerResidualQ[state["ResidualSequence"]],
    "IntegerQuotientVerified" -> completeIntegerResidualQ[state["ResidualSequence"]],
    "TimedOut" -> timedOut,
    "ElapsedTime" -> elapsed,
    "TimeConstraint" -> tc,
    "Diagnostic" -> diagnostic
  |>
];

emitRationalProgress[progress_, payload_Association] := Which[
  TrueQ[progress],
    Print[
      "CommonFactor: step ", payload["Step"],
      ", factor = ", ToString[payload["Factor"], InputForm],
      ", residual height = ", NumberForm[payload["ResidualComplexity"]["SizeHeight"], {8, 3}],
      ", denominator height = ", NumberForm[payload["ResidualComplexity"]["DenominatorHeight"], {8, 3}],
      ", removable zeros = ", payload["ResidualComplexity"]["UnknownCount"]
    ],
  Head[progress] === Function,
    Quiet[progress[payload]],
  True,
    Null
];

rationalReduceCore[seq_, n_Symbol, opts_List] := Module[
  {start, indices, candidates = {}, maxPower, maxSteps, penalty, progress,
   tc, target, deadline, t0, timedOut = False, rounds, round = 0, roundOpts,
   newCandidates, beamWidth, damage, beam, expansions, best, newBest,
   initial, step = 0},

  t0 = AbsoluteTime[];
  If[! validExactRationalSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];
  If[! TrueQ[validateOptions[opts]], Return[$Failed]];

  start = "IndexStart" /. opts;
  If[! IntegerQ[start],
    Message[CommonFactorReduce::start];
    Return[$Failed]];

  indices = indexRange[start, Length[seq]];
  maxPower = "MaxCandidatePower" /. opts;
  maxSteps = "MaxSteps" /. opts;
  If[maxSteps === ("MaxSteps" /. Options[CommonFactorReduce]), maxSteps = 2];
  penalty = "ComplexityPenalty" /. opts;
  progress = "Progress" /. opts;
  tc = TimeConstraint /. opts;
  target = normalizeQuotientTarget["QuotientTarget" /. opts, seq];
  If[target === $Failed,
    Message[CommonFactorReduce::opt, "\"QuotientTarget\"", "QuotientTarget" /. opts];
    Return[$Failed]];
  rounds = roundLimit["SearchRounds" /. opts, tc];
  deadline = makeDeadline[tc];
  If[deadline === $Failed,
    Message[CommonFactorReduce::opt, "TimeConstraint", tc];
    Return[$Failed]];
  beamWidth = "BeamWidth" /. opts;
  damage = Replace["TemporaryDamageAllowance" /. opts, Automatic -> 10];

  initial = rationalInitialState[seq, indices, penalty, target];
  If[AllTrue[seq, # === 0 &],
    Return[finalRationalAssociation[seq, n, start, initial, {}, target, False,
      AbsoluteTime[] - t0, tc,
      "All observed terms are zero; common factors are not identifiable from the data."]]];

  beam = {initial};
  best = initial;

  While[round < rounds && step < maxSteps && ! expiredQ[deadline],
    round++;
    roundOpts = expandedOptionsForRound[opts, round];
    newCandidates = generateRationalCandidates[seq, n, indices, roundOpts, deadline];
    candidates = dedupeCandidates[Join[candidates, newCandidates]];

    While[step < maxSteps && ! expiredQ[deadline],
      expansions = Flatten[
        Table[
          If[expiredQ[deadline], Nothing,
            rationalBestExpansion[state, cand, indices, maxPower, penalty,
              target, damage]],
          {state, beam}, {cand, candidates}],
        1];
      expansions = Cases[expansions, _Association];
      If[expansions === {}, Break[]];
      expansions = SortBy[dedupeRationalStates[expansions],
        {#["Objective"] &, #["FormulaComplexity"] &}];
      beam = dedupeRationalStates@Join[
        Take[expansions, UpTo[beamWidth]],
        Take[
          Select[expansions,
            zeroCoveringStateQ[#] && #["Objective"] <= best["Objective"] + damage &],
          UpTo[8]]
      ];
      beam = SortBy[beam, {#["Objective"] &, #["FormulaComplexity"] &}];
      newBest = bestRationalState[Prepend[beam, best]];
      step++;
      If[newBest["Objective"] < best["Objective"],
        best = newBest;
        beam = Select[beam, #["Objective"] <= best["Objective"] + damage &];
        emitRationalProgress[progress, <|
          "Step" -> step,
          "Round" -> round,
          "Factor" -> rationalFactorExpression[best["Factor"], n, start],
          "ResidualSequence" -> best["ResidualSequence"],
          "ResidualComplexity" -> best["ScoreVector"],
          "KnownResidualPairs" -> best["KnownResidualPairs"],
          "UnknownQuotientIndices" -> best["UnknownQuotientIndices"]
        |>],
        beam = Select[beam, #["Objective"] <= best["Objective"] + damage &];
        If[step > 1, Break[]]];
      If[completeIntegerResidualQ[best["ResidualSequence"]] &&
          AllTrue[best["ResidualSequence"], Abs[#] === 1 &],
        Break[]]
    ];
  ];

  timedOut = expiredQ[deadline];
  If[timedOut, Message[CommonFactorReduce::timeout]];
  finalRationalAssociation[seq, n, start, best, candidates, target, timedOut,
    AbsoluteTime[] - t0, tc]
];

reduceCore[seq_, n_Symbol, opts_List] := Module[
  {start, indices, candidates, residuals, selected = {}, maxPower, maxSteps,
   penalty, step = 0, available, chosen, includeConstant, progress, tc,
   deadline, t0, timedOut = False, currentFactor, residualGCD, rounds,
   round = 0, roundOpts, newCandidates},

  t0 = AbsoluteTime[];
  If[! validSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];
  If[! TrueQ[validateOptions[opts]], Return[$Failed]];

  start = "IndexStart" /. opts;
  If[! IntegerQ[start],
    Message[CommonFactorReduce::start];
    Return[$Failed]];

  indices = indexRange[start, Length[seq]];
  maxPower = "MaxCandidatePower" /. opts;
  maxSteps = "MaxSteps" /. opts;
  penalty = "ComplexityPenalty" /. opts;
  includeConstant = TrueQ["IncludeConstantFactor" /. opts];
  progress = "Progress" /. opts;
  tc = TimeConstraint /. opts;
  rounds = roundLimit["SearchRounds" /. opts, tc];
  deadline = makeDeadline[tc];
  If[deadline === $Failed,
    Message[CommonFactorReduce::opt, "TimeConstraint", tc];
    Return[$Failed]];

  candidates = {};
  residuals = seq;

  While[round < rounds && step < maxSteps && ! expiredQ[deadline],
    round++;
    roundOpts = expandedOptionsForRound[opts, round];
    newCandidates = generateCandidates[seq, n, indices, roundOpts, deadline];
    candidates = dedupeCandidates[Join[candidates, newCandidates]];

    While[step < maxSteps && ! expiredQ[deadline],
      available = candidateAvailableData[#, residuals, maxPower, penalty] & /@ candidates;
      available = Cases[available, _Association];
      If[available === {}, Break[]];
      chosen = bestCandidate[available];
      AppendTo[selected, KeyDrop[chosen, "ResidualAfter"] ~Join~
        <|"Exponent" -> chosen["AvailableExponent"]|>];
      residuals = chosen["ResidualAfter"];
      step++;
      If[TrueQ[Lookup[chosen, "NonRepeatable", False]],
        candidates = DeleteCases[candidates, c_ /; c["Values"] === chosen["Values"]]];
      residualGCD = GCD @@ Abs[residuals];
      currentFactor = factorExpression[mergeSelected[selected], n, start, False, 1];
      emitProgress[progress, <|
        "Step" -> step,
        "Round" -> round,
        "Factor" -> currentFactor,
        "ChosenFactor" -> chosen["Expression"],
        "ResidualSequence" -> residuals,
        "ResidualGCD" -> residualGCD
      |>]];
    If[AllTrue[residuals, Abs[#] === 1 &], Break[]]];

  timedOut = expiredQ[deadline];
  If[timedOut, Message[CommonFactorReduce::timeout]];
  finalAssociation[seq, n, start, selected, residuals, candidates,
    includeConstant, timedOut, AbsoluteTime[] - t0, tc]
];

rationalCandidateReportData[cand_, initial_, indices_, maxPower_, penalty_,
   target_, damage_] := Module[{state, selected},
  state = rationalBestExpansion[initial, cand, indices, maxPower, penalty,
    target, damage];
  If[! AssociationQ[state], Return[Nothing]];
  selected = Last[state["SelectedFactors"]];
  Join[KeyDrop[cand, {"Values"}], <|
    "Values" -> cand["Values"],
    "AvailableExponent" -> selected["Exponent"],
    "StepScore" -> selected["StepScore"],
    "TotalGrowth" -> selected["TotalGrowth"],
    "QuotientSequence" -> state["ResidualSequence"],
    "ResidualComplexity" -> state["ScoreVector"],
    "Objective" -> state["Objective"],
    "UnknownQuotientIndices" -> state["UnknownQuotientIndices"],
    "KnownResidualPairs" -> state["KnownResidualPairs"]
  |>]
];

reduceDispatch[seq_, n_Symbol, opts_List] := Module[{target},
  If[! validExactRationalSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];
  target = "QuotientTarget" /. opts;
  If[validIntegerSequenceQ[seq] && ! MemberQ[{"Rational", "PreferInteger"}, target],
    reduceCore[seq, n, opts],
    rationalReduceCore[seq, n, opts]
  ]
];

candidateReportDispatch[seq_, n_Symbol, opts_List] := Module[
  {ov = opts, targetOpt, start, indices, candidates, maxPower, penalty,
   available, deadline, tc, rounds, round = 0, roundOpts, target, beamInitial,
   damage},

  If[! validExactRationalSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];
  If[! TrueQ[validateOptions[ov]], Return[$Failed]];
  start = "IndexStart" /. ov;
  If[! IntegerQ[start],
    Message[CommonFactorReduce::start];
    Return[$Failed]];
  tc = TimeConstraint /. ov;
  deadline = makeDeadline[tc];
  rounds = roundLimit["SearchRounds" /. ov, tc];
  indices = indexRange[start, Length[seq]];
  targetOpt = "QuotientTarget" /. ov;

  If[validIntegerSequenceQ[seq] && ! MemberQ[{"Rational", "PreferInteger"}, targetOpt],
    candidates = {};
    While[round < rounds && ! expiredQ[deadline],
      round++;
      roundOpts = expandedOptionsForRound[ov, round];
      candidates = dedupeCandidates@Join[candidates,
        generateCandidates[seq, n, indices, roundOpts, deadline]]];
    maxPower = "MaxCandidatePower" /. ov;
    penalty = "ComplexityPenalty" /. ov;
    available = candidateAvailableData[#, seq, maxPower, penalty] & /@ candidates;
    available = Cases[available, _Association];
    Return[KeyDrop[#, {"ResidualAfter"}] & /@ SortBy[
      available,
      {-#["StepScore"] &, -#["TotalGrowth"] &, #["Complexity"] &, #["Label"] &}
    ]]];

  target = normalizeQuotientTarget[targetOpt, seq];
  If[target === $Failed,
    Message[CommonFactorReduce::opt, "\"QuotientTarget\"", targetOpt];
    Return[$Failed]];
  candidates = {};
  While[round < rounds && ! expiredQ[deadline],
    round++;
    roundOpts = expandedOptionsForRound[ov, round];
    candidates = dedupeCandidates@Join[candidates,
      generateRationalCandidates[seq, n, indices, roundOpts, deadline]]];
  maxPower = "MaxCandidatePower" /. ov;
  penalty = "ComplexityPenalty" /. ov;
  damage = Replace["TemporaryDamageAllowance" /. ov, Automatic -> Infinity];
  beamInitial = rationalInitialState[seq, indices, penalty, target];
  available = rationalCandidateReportData[#, beamInitial, indices, maxPower,
      penalty, target, damage] & /@ candidates;
  available = Cases[available, _Association];
  SortBy[available, {#["Objective"] &, -#["StepScore"] &, #["Complexity"] &, #["Label"] &}]
];

CommonFactorReduce[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n},
    reduceDispatch[seq, n, Flatten[{opts, Options[CommonFactorReduce]}]]];

FindSymbolicCommonFactor[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n},
    Module[{data = reduceDispatch[seq, n,
        Flatten[{opts, Options[CommonFactorReduce]}]]},
      If[AssociationQ[data], data["Factor"], $Failed]]];

CommonFactorCandidateReport[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n},
    candidateReportDispatch[seq, n,
      Flatten[{opts, Options[CommonFactorReduce]}]]];

End[];
EndPackage[];
