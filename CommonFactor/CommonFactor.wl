(* ::Package:: *)

(* :Title: CommonFactor *)
(* :Context: CommonFactor` *)
(* :Author: OpenAI Codex, for Vladimir Reshetnikov *)
(* :Summary:
   Heuristic discovery of large symbolic common factors in finite integer
   sequences.

   Given exact integer data a_n, the package searches for a product F(n) built
   from symbolic sequence factors such as c^n, prime-valuation powers, linear
   terms, factorials, double factorials, Pochhammer/falling factorials, Gamma
   quotients, multinomials, Catalan numbers, BarnesG superfactorials, and
   periodic signs, such that F(n) divides every observed a_n.  The remaining
   quotient sequence is meant to be slower-growing and easier to inspect with
   FindSequenceFunction or by hand.

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
divides every observed exact integer term of seq, with indices n = 1, 2, ... . \
FindSymbolicCommonFactor[seq, n, \"IndexStart\" -> n0] uses indices n0, n0+1, ... . \
The result is the factor found by CommonFactorReduce.  Use CommonFactorReduce \
for the quotient sequence and diagnostics.";

CommonFactorReduce::usage =
  "CommonFactorReduce[seq, n] returns an Association describing a best-effort \
symbolic common-factor decomposition of a finite exact integer sequence.  Main \
keys include \"Factor\", \"QuotientSequence\", \"SelectedFactors\", \
\"ResidualGCD\", \"CandidateCount\", \"IndexRange\", and \"TimedOut\".  Options \
include \"IndexStart\", \"Bases\", \"CandidateShifts\", \
\"IncludeValuationCandidates\", \"IncludeDefaultCandidates\", \
\"IncludeExtendedCandidates\", \"ExtraCandidates\", \"IncludeConstantFactor\", \
\"MaxCandidatePower\", \"MaxSteps\", \"Progress\", and TimeConstraint.";

CommonFactorCandidateReport::usage =
  "CommonFactorCandidateReport[seq, n] returns the generated candidate factors \
that divide the original sequence, annotated with their observed values, maximum \
common exponent, growth score, and complexity.  It is useful for inspecting why \
CommonFactorReduce chose a particular factor.";

CommonFactorReduce::seq =
  "The input sequence must be a non-empty list of nonzero exact integers.";
CommonFactorReduce::start =
  "\"IndexStart\" must be an integer.";
CommonFactorReduce::opt =
  "Invalid option value for `1`: `2`.";
CommonFactorReduce::cand =
  "Ignoring candidate `1`, whose observed values are not nonzero integers on the requested index range.";
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
  "Progress" -> True,
  TimeConstraint -> Infinity
};
Options[FindSymbolicCommonFactor] = Options[CommonFactorReduce];
Options[CommonFactorCandidateReport] = Options[CommonFactorReduce];

SetAttributes[{FindSymbolicCommonFactor, CommonFactorReduce,
  CommonFactorCandidateReport}, HoldRest];

Begin["`Private`"];

validSequenceQ[seq_] := ListQ[seq] && seq =!= {} &&
  VectorQ[seq, IntegerQ] && FreeQ[seq, 0];

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

normalizeExtraCandidate[item_, n_Symbol, indices_] := Which[
  MatchQ[item, _Rule],
    makeCandidate[item[[2]], n, indices, "Extra", item[[1]], True],
  AssociationQ[item] && KeyExistsQ[item, "Expression"],
    makeCandidate[item["Expression"], n, indices,
      Lookup[item, "Kind", "Extra"], Lookup[item, "Label", Automatic], True],
  True,
    makeCandidate[item, n, indices, "Extra", Automatic, True]
];

candidateListFromRules[rules_, n_Symbol, indices_, deadline_,
   warn_: False, meta_: <||>] := Module[{out = {}, c},
  Do[
    If[expiredQ[deadline], Break[]];
    c = makeCandidate[First[rule], n, indices, Last[rule], Automatic, warn, meta];
    If[AssociationQ[c], AppendTo[out, c]],
    {rule, rules}];
  out];

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
   penalty, tc, known, seen, unknown},
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

CommonFactorReduce[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n}, reduceCore[seq, n, Flatten[{opts, Options[CommonFactorReduce]}]]];

FindSymbolicCommonFactor[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n},
    Module[{data = reduceCore[seq, n, Flatten[{opts, Options[CommonFactorReduce]}]]},
      If[AssociationQ[data], data["Factor"], $Failed]]];

CommonFactorCandidateReport[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  Block[{n},
    Module[{ov, start, indices, candidates, maxPower, penalty, available,
      deadline, tc, rounds, round = 0, roundOpts},
      If[! validSequenceQ[seq],
        Message[CommonFactorReduce::seq];
        Return[$Failed]];
      ov = Flatten[{opts, Options[CommonFactorReduce]}];
      If[! TrueQ[validateOptions[ov]], Return[$Failed]];
      start = "IndexStart" /. ov;
      If[! IntegerQ[start],
        Message[CommonFactorReduce::start];
        Return[$Failed]];
      tc = TimeConstraint /. ov;
      deadline = makeDeadline[tc];
      rounds = roundLimit["SearchRounds" /. ov, tc];
      indices = indexRange[start, Length[seq]];
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
      KeyDrop[#, {"ResidualAfter"}] & /@ SortBy[
        available,
        {-#["StepScore"] &, -#["TotalGrowth"] &, #["Complexity"] &, #["Label"] &}
      ]]];

End[];
EndPackage[];
