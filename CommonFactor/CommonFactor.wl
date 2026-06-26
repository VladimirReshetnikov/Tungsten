(* ::Package:: *)

(* :Title: CommonFactor *)
(* :Context: CommonFactor` *)
(* :Author: OpenAI Codex, for Vladimir Reshetnikov *)
(* :Summary:
   Heuristic discovery of large symbolic common factors in finite integer
   sequences.

   Given exact integer data a_n, the package searches for a product F(n) built
   from simple symbolic sequence factors such as c^n, linear terms, factorials,
   double factorials, binomial coefficients, and Catalan numbers, such that
   F(n) divides every observed a_n.  The remaining quotient sequence is meant
   to be slower-growing and easier to inspect with FindSequenceFunction or by
   hand.

   The method is deliberately best-effort.  It generates candidate factors,
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
\"ResidualGCD\", \"CandidateCount\", and \"IndexRange\".  Options include \
\"IndexStart\", \"Bases\", \"CandidateShifts\", \"IncludeDefaultCandidates\", \
\"ExtraCandidates\", \"IncludeConstantFactor\", \"MaxCandidatePower\", and \
\"MaxSteps\".";

CommonFactorCandidateReport::usage =
  "CommonFactorCandidateReport[seq, n] returns the generated candidate factors \
that divide the original sequence, annotated with their observed values, maximum \
common exponent, growth score, and complexity.  It is useful for inspecting why \
CommonFactorReduce chose a particular factor.";

CommonFactorReduce::seq =
  "The input sequence must be a non-empty list of nonzero exact integers.";
CommonFactorReduce::start =
  "\"IndexStart\" must be an integer.";
CommonFactorReduce::cand =
  "Ignoring candidate `1`, whose observed values are not nonzero positive integers on the requested index range.";

Options[CommonFactorReduce] = {
  "IndexStart" -> 1,
  "Bases" -> Range[2, 12],
  "CandidateShifts" -> Range[-3, 5],
  "IncludeDefaultCandidates" -> True,
  "ExtraCandidates" -> {},
  "IncludeConstantFactor" -> False,
  "MaxCandidatePower" -> 64,
  "MaxSteps" -> 64,
  "ComplexityPenalty" -> 0.03
};
Options[FindSymbolicCommonFactor] = Options[CommonFactorReduce];
Options[CommonFactorCandidateReport] = Options[CommonFactorReduce];

Begin["`Private`"];

validSequenceQ[seq_] := ListQ[seq] && seq =!= {} &&
  VectorQ[seq, IntegerQ] && FreeQ[seq, 0];

indexRange[start_Integer, len_Integer] := Range[start, start + len - 1];

integerDivisibleQ[a_Integer, b_Integer] := b =!= 0 && Mod[a, b] === 0;

divideByValues[residuals_, values_] := MapThread[Quotient, {residuals, values}];

dividesAllQ[residuals_, values_] :=
  And @@ MapThread[integerDivisibleQ, {residuals, values}];

maxPowerAndResidual[residuals_, values_, maxPower_] := Module[
  {k = 0, r = residuals, cap},
  cap = Replace[maxPower, Infinity -> 10^9];
  While[k < cap && dividesAllQ[r, values],
    r = divideByValues[r, values];
    k++];
  {k, r}];

candidateComplexity[expr_] := LeafCount[Unevaluated[expr]];

candidateGrowth[values_] := N[Mean[Log[Abs[values]]], 40];

positiveIntegerValuesQ[values_] :=
  VectorQ[values, IntegerQ] && AllTrue[values, # > 0 &] &&
    AnyTrue[values, # > 1 &];

safeValues[expr_, n_Symbol, indices_] := Quiet[
  Check[expr /. n -> # & /@ indices, $Failed],
  {Power::infy, Infinity::indet, General::stop, Factorial::fact}
];

makeCandidate[expr_, n_Symbol, indices_, kind_, label_: Automatic, warn_: False] := Module[
  {values, heldLabel},
  values = safeValues[expr, n, indices];
  If[values === $Failed || ! positiveIntegerValuesQ[values],
    If[TrueQ[warn], Message[CommonFactorReduce::cand, HoldForm[expr]]];
    Return[Nothing]];
  heldLabel = If[label === Automatic, ToString[Unevaluated[expr], InputForm], ToString[label, InputForm]];
  <|
    "Expression" -> expr,
    "Label" -> heldLabel,
    "Kind" -> kind,
    "Values" -> values,
    "GrowthScore" -> candidateGrowth[values],
    "Complexity" -> candidateComplexity[expr]
  |>];

normalizeExtraCandidate[item_, n_Symbol, indices_] := Which[
  MatchQ[item, _Rule],
    makeCandidate[item[[2]], n, indices, "Extra", item[[1]], True],
  AssociationQ[item] && KeyExistsQ[item, "Expression"],
    makeCandidate[item["Expression"], n, indices,
      Lookup[item, "Kind", "Extra"], Lookup[item, "Label", Automatic], True],
  True,
    makeCandidate[item, n, indices, "Extra", Automatic, True]
];

defaultCandidateExpressions[n_Symbol, bases_, shifts_] := Module[
  {powerShifts, nonnegativeShifts, linear, powers, factorials, doubleFactorials,
   binomials, catalans, fibs},

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

dedupeCandidates[candidates_] := Module[{groups},
  groups = GatherBy[candidates, #["Values"] &];
  First@SortBy[#, {#["Complexity"] &, #["Label"] &}] & /@ groups
];

generateCandidates[n_Symbol, indices_, opts_List] := Module[
  {bases, shifts, includeDefaults, extra, defaults, cands},
  bases = "Bases" /. opts;
  shifts = "CandidateShifts" /. opts;
  includeDefaults = TrueQ["IncludeDefaultCandidates" /. opts];
  extra = Flatten@{"ExtraCandidates" /. opts};

  defaults = If[includeDefaults,
    makeCandidate[First[#], n, indices, Last[#]] & /@ defaultCandidateExpressions[n, bases, shifts],
    {}];

  cands = Join[defaults, normalizeExtraCandidate[#, n, indices] & /@ extra];
  dedupeCandidates[Cases[cands, _Association]]
];

candidateAvailableData[cand_, residuals_, maxPower_, penalty_] := Module[
  {pow, after, baseScore, stepScore},
  {pow, after} = maxPowerAndResidual[residuals, cand["Values"], maxPower];
  If[pow <= 0, Return[Nothing]];
  baseScore = N[cand["GrowthScore"] - penalty cand["Complexity"], 40];
  stepScore = N[pow baseScore, 40];
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

reduceCore[seq_, n_Symbol, opts_List] := Module[
  {start, indices, candidates, residuals, selected = {}, maxPower, maxSteps,
   penalty, step = 0, available, chosen, residualGCD, includeConstant, quotient,
   factor, selectedMerged},

  If[! validSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];

  start = "IndexStart" /. opts;
  If[! IntegerQ[start],
    Message[CommonFactorReduce::start];
    Return[$Failed]];

  indices = indexRange[start, Length[seq]];
  maxPower = "MaxCandidatePower" /. opts;
  maxSteps = "MaxSteps" /. opts;
  penalty = "ComplexityPenalty" /. opts;
  includeConstant = TrueQ["IncludeConstantFactor" /. opts];
  candidates = generateCandidates[n, indices, opts];
  residuals = seq;

  While[step < maxSteps,
    available = candidateAvailableData[#, residuals, maxPower, penalty] & /@ candidates;
    available = Cases[available, _Association];
    If[available === {}, Break[]];
    chosen = bestCandidate[available];
    AppendTo[selected, KeyDrop[chosen, "ResidualAfter"] ~Join~
      <|"Exponent" -> chosen["AvailableExponent"]|>];
    residuals = chosen["ResidualAfter"];
    step++];

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
    "IndexRange" -> indices,
    "InputSequence" -> seq
  |>];

CommonFactorReduce[seq_List, n_Symbol, opts : OptionsPattern[]] :=
  reduceCore[seq, n, Flatten[{opts, Options[CommonFactorReduce]}]];

FindSymbolicCommonFactor[seq_List, n_Symbol, opts : OptionsPattern[]] := Module[
  {data = CommonFactorReduce[seq, n, opts]},
  If[AssociationQ[data], data["Factor"], $Failed]
];

CommonFactorCandidateReport[seq_List, n_Symbol, opts : OptionsPattern[]] := Module[
  {ov, start, indices, candidates, maxPower, penalty, available},
  If[! validSequenceQ[seq],
    Message[CommonFactorReduce::seq];
    Return[$Failed]];
  ov = Flatten[{opts, Options[CommonFactorReduce]}];
  start = "IndexStart" /. ov;
  If[! IntegerQ[start],
    Message[CommonFactorReduce::start];
    Return[$Failed]];
  indices = indexRange[start, Length[seq]];
  candidates = generateCandidates[n, indices, ov];
  maxPower = "MaxCandidatePower" /. ov;
  penalty = "ComplexityPenalty" /. ov;
  available = candidateAvailableData[#, seq, maxPower, penalty] & /@ candidates;
  available = Cases[available, _Association];
  KeyDrop[#, {"ResidualAfter"}] & /@ SortBy[
    available,
    {-#["StepScore"] &, -#["TotalGrowth"] &, #["Complexity"] &, #["Label"] &}
  ]];

End[];
EndPackage[];
