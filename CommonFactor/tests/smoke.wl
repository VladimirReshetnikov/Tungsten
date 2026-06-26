(* ::Package:: *)

(* Smoke tests for CommonFactor`.

   Run:
     & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/CommonFactor/tests/smoke.wl

   Exit code 0 = all pass; 1 = at least one check failed.
*)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
pkg = FileNameJoin[{ParentDirectory[here], "CommonFactor.wl"}];
Get[pkg];

fail = 0;
check[label_, cond_] := (
  Print[If[TrueQ[cond], "[PASS] ", "[FAIL] "], label];
  If[! TrueQ[cond], fail++]);

sameValuesQ[expr1_, expr2_, n_, indices_] := Block[{$MaxExtraPrecision = 200},
  And @@ (PossibleZeroQ[(expr1 - expr2) /. n -> #] & /@ indices)];

Print["================================================================"];
Print["CommonFactor smoke tests"];
Print["================================================================"];

(* The motivating shape from the Mathematica StackExchange question. *)
b1 = Table[Prime[50 + k], {k, 1, 9}];
seq1 = Table[10^k Factorial2[2 k + 1] k^2 b1[[k]], {k, 1, Length[b1]}];
data1 = CommonFactorReduce[seq1, n, "Progress" -> False];
expected1 = 10^n Factorial2[2 n + 1] n^2;
check["recovers 10^n (2n+1)!! n^2 on the motivating shape",
  AssociationQ[data1] &&
    sameValuesQ[data1["Factor"], expected1, n, data1["IndexRange"]] &&
    data1["QuotientSequence"] === b1];

check["selected-factor diagnostics are a list",
  ListQ[data1["SelectedFactors"]] && Length[data1["SelectedFactors"]] >= 3 &&
    AllTrue[data1["SelectedFactors"], AssociationQ]];

report1 = CommonFactorCandidateReport[seq1, n, "Progress" -> False];
check["candidate report exposes the odd double factorial",
  AnyTrue[report1, sameValuesQ[#["Expression"], Factorial2[2 n + 1], n, data1["IndexRange"]] &]];

(* Shifted exponential plus Catalan numbers. *)
b2 = Table[Prime[70 + k], {k, 1, 8}];
seq2 = Table[7^(k - 1) CatalanNumber[k] b2[[k]], {k, 1, Length[b2]}];
data2 = CommonFactorReduce[seq2, n, "Progress" -> False];
expected2 = 7^(n - 1) CatalanNumber[n];
check["recovers shifted c^(n-1) and CatalanNumber[n]",
  AssociationQ[data2] &&
    sameValuesQ[data2["Factor"], expected2, n, data2["IndexRange"]] &&
    data2["QuotientSequence"] === b2];

(* Optional constant GCD inclusion is deliberately separate from symbolic peeling. *)
b3 = Table[Prime[90 + k], {k, 1, 7}];
seq3 = Table[42 Factorial[k] b3[[k]], {k, 1, Length[b3]}];
data3 = CommonFactorReduce[seq3, n, "IncludeConstantFactor" -> True, "Progress" -> False];
expected3 = 42 Factorial[n];
check["can include the residual numeric GCD on request",
  AssociationQ[data3] &&
    sameValuesQ[data3["Factor"], expected3, n, data3["IndexRange"]] &&
    data3["QuotientSequence"] === b3];

(* User-supplied candidate expressions extend the grammar without changing code. *)
b4 = Table[Prime[110 + k], {k, 1, 8}];
seq4 = Table[(k^2 + k + 1) b4[[k]], {k, 1, Length[b4]}];
data4 = CommonFactorReduce[seq4, n,
  "IncludeDefaultCandidates" -> False,
  "Progress" -> False,
  "ExtraCandidates" -> {"quadratic" -> n^2 + n + 1}];
check["accepts an explicit extra candidate expression",
  AssociationQ[data4] &&
    sameValuesQ[data4["Factor"], n^2 + n + 1, n, data4["IndexRange"]] &&
    data4["QuotientSequence"] === b4];

check["FindSymbolicCommonFactor returns just the factor expression",
  sameValuesQ[
    FindSymbolicCommonFactor[seq1, n, "Progress" -> False],
    expected1,
    n,
    data1["IndexRange"]]];

(* Valuation-driven discovery finds prime bases outside the default base list. *)
seq5 = Table[13^k Prime[130 + k], {k, 1, 7}];
data5 = CommonFactorReduce[seq5, n, "Progress" -> False];
check["valuation discovery recovers 13^n outside the default base range",
  AssociationQ[data5] &&
    sameValuesQ[data5["Factor"], 13^n, n, data5["IndexRange"]] &&
    data5["QuotientSequence"] === Table[Prime[130 + k], {k, 1, 7}]];

seq6 = Table[17^(k^2) Prime[150 + k], {k, 1, 5}];
data6 = CommonFactorReduce[seq6, n, "Progress" -> False];
check["valuation discovery recovers p^(n^2)",
  AssociationQ[data6] &&
    sameValuesQ[data6["Factor"], 17^(n^2), n, data6["IndexRange"]] &&
    data6["QuotientSequence"] === Table[Prime[150 + k], {k, 1, 5}]];

(* Extended grammar: Pochhammer, falling factorials, multinomials, BarnesG. *)
seq7 = Table[
  Pochhammer[k + 2, 3] FactorialPower[k + 5, 3] Prime[170 + k],
  {k, 1, 7}];
data7 = CommonFactorReduce[seq7, n, "Progress" -> False];
expected7 = Pochhammer[n + 2, 3] FactorialPower[n + 5, 3];
check["extended grammar recovers Pochhammer and falling factorial factors",
  AssociationQ[data7] &&
    sameValuesQ[data7["Factor"], expected7, n, data7["IndexRange"]] &&
    data7["QuotientSequence"] === Table[Prime[170 + k], {k, 1, 7}]];

seq8 = Table[Multinomial[k, k, k] BarnesG[k + 2] Prime[190 + k], {k, 1, 6}];
data8 = CommonFactorReduce[seq8, n, "Progress" -> False];
expected8 = Multinomial[n, n, n] BarnesG[n + 2];
check["extended grammar recovers multinomial and BarnesG factors",
  AssociationQ[data8] &&
    sameValuesQ[data8["Factor"], expected8, n, data8["IndexRange"]] &&
    data8["QuotientSequence"] === Table[Prime[190 + k], {k, 1, 6}]];

seq8b = Table[Pochhammer[k + 20, 3] Prime[210 + k], {k, 1, 6}];
report8b = CommonFactorCandidateReport[seq8b, n, "Progress" -> False, "SearchRounds" -> 5];
check["widened search rounds surface factors outside the default shift radius",
  AnyTrue[report8b,
    sameValuesQ[#["Expression"], Pochhammer[n + 20, 3], n, Range[1, 6]] &]];

seq9 = Table[(-1)^k 5^k Factorial[k], {k, 1, 7}];
data9 = CommonFactorReduce[seq9, n, "Progress" -> False];
check["periodic sign factor is peeled with the magnitude factor",
  AssociationQ[data9] &&
    data9["QuotientSequence"] === ConstantArray[1, 7] &&
    data9["FactorValues"] === seq9];

(* Held public API works even when the requested index symbol has an OwnValue. *)
n = 42;
heldData = CommonFactorReduce[{2, 4, 8}, n, "Progress" -> False];
Clear[n];
check["held index symbol works when n has an OwnValue",
  AssociationQ[heldData] && heldData["QuotientSequence"] === {1, 1, 1}];

timedData = Quiet[CommonFactorReduce[seq1, n, "Progress" -> False, TimeConstraint -> 0]];
check["TimeConstraint can return the best-so-far fallback",
  AssociationQ[timedData] && TrueQ[timedData["TimedOut"]] &&
    timedData["Factor"] === 1];

check["rejects unknown options",
  Quiet[CommonFactorReduce[{2, 4, 8}, n, "Progress" -> False,
    "NoSuchOption" -> 1]] === $Failed];

check["rejects unbounded rounds without a time limit",
  Quiet[CommonFactorReduce[{2, 4, 8}, n, "Progress" -> False,
    "SearchRounds" -> Infinity]] === $Failed];

check["rejects non-integer input",
  Quiet[CommonFactorReduce[{2, 3/2, 4}, n, "Progress" -> False]] === $Failed];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS", ToString[fail] <> " FAILURE(S)"]];
Print["================================================================"];
If[StringQ[$InputFileName] && $InputFileName =!= "", Exit[If[fail == 0, 0, 1]]];
