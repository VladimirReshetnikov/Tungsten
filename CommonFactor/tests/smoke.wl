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
data1 = CommonFactorReduce[seq1, n];
expected1 = 10^n Factorial2[2 n + 1] n^2;
check["recovers 10^n (2n+1)!! n^2 on the motivating shape",
  AssociationQ[data1] &&
    sameValuesQ[data1["Factor"], expected1, n, data1["IndexRange"]] &&
    data1["QuotientSequence"] === b1];

check["selected-factor diagnostics are a list",
  ListQ[data1["SelectedFactors"]] && Length[data1["SelectedFactors"]] >= 3 &&
    AllTrue[data1["SelectedFactors"], AssociationQ]];

report1 = CommonFactorCandidateReport[seq1, n];
check["candidate report exposes the odd double factorial",
  AnyTrue[report1, sameValuesQ[#["Expression"], Factorial2[2 n + 1], n, data1["IndexRange"]] &]];

(* Shifted exponential plus Catalan numbers. *)
b2 = Table[Prime[70 + k], {k, 1, 8}];
seq2 = Table[7^(k - 1) CatalanNumber[k] b2[[k]], {k, 1, Length[b2]}];
data2 = CommonFactorReduce[seq2, n];
expected2 = 7^(n - 1) CatalanNumber[n];
check["recovers shifted c^(n-1) and CatalanNumber[n]",
  AssociationQ[data2] &&
    sameValuesQ[data2["Factor"], expected2, n, data2["IndexRange"]] &&
    data2["QuotientSequence"] === b2];

(* Optional constant GCD inclusion is deliberately separate from symbolic peeling. *)
b3 = Table[Prime[90 + k], {k, 1, 7}];
seq3 = Table[42 Factorial[k] b3[[k]], {k, 1, Length[b3]}];
data3 = CommonFactorReduce[seq3, n, "IncludeConstantFactor" -> True];
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
  "ExtraCandidates" -> {"quadratic" -> n^2 + n + 1}];
check["accepts an explicit extra candidate expression",
  AssociationQ[data4] &&
    sameValuesQ[data4["Factor"], n^2 + n + 1, n, data4["IndexRange"]] &&
    data4["QuotientSequence"] === b4];

check["FindSymbolicCommonFactor returns just the factor expression",
  sameValuesQ[
    FindSymbolicCommonFactor[seq1, n],
    expected1,
    n,
    data1["IndexRange"]]];

check["rejects non-integer input",
  Quiet[CommonFactorReduce[{2, 3/2, 4}, n]] === $Failed];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS", ToString[fail] <> " FAILURE(S)"]];
Print["================================================================"];
If[$ScriptCommandLine =!= {}, Exit[If[fail == 0, 0, 1]]];
