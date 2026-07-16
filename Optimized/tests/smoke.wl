(* ::Package:: *)

(* Smoke tests for OptimizedExpressions`.

   Run:
     & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script Optimized/tests/smoke.wl

   Exit code 0 = all pass; 1 = at least one check failed.
*)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
pkg = FileNameJoin[{ParentDirectory[here], "OptimizedExpressions.wl"}];
If[! FileExistsQ[pkg],
  pkg = FileNameJoin[{Directory[], "Optimized", "OptimizedExpressions.wl"}]
];
Get[pkg];

fail = 0;
OptimizedExpressionsSmoke::fail =
  "OptimizedExpressions smoke test failed with `1` failing check(s).";
check[label_, cond_] := (
  Print[If[TrueQ[cond], "[PASS] ", "[FAIL] "], label];
  If[! TrueQ[cond], fail++]
);

assignmentCount[expr_] :=
  Length @ Cases[HoldComplete[expr], HoldPattern[Set[_Symbol, _]], Infinity];

sameNormalQ[optimized_, expected_] := Quiet @ TrueQ[
  FullSimplify[
    OptimizedExpressions`OptimizedExpressionNormal[optimized] == expected
  ]
];

Print["================================================================"];
Print["OptimizedExpressions smoke tests"];
Print["================================================================"];

basic = OptimizedExpressions`OptimizeExpressionDAG[(x + y)^2 + (x + y)^3];
check["basic result has Experimental`OptimizedExpression head",
  Head[basic] === Experimental`OptimizedExpression];
check["basic round-trip preserves expression",
  sameNormalQ[basic, (x + y)^2 + (x + y)^3]];
check["basic repeated x+y is extracted once",
  assignmentCount[basic] == 1];

ClearAll[aa, bb, p, q];
sys1 = Experimental`OptimizeExpression[(x + y)^2 + z (x + y),
  "OptimizationSymbol" -> aa];
sys2 = Experimental`OptimizeExpression[(x + y)^3 + w (x + y),
  "OptimizationSymbol" -> bb];
sum = OptimizedExpressions`OptimizedPlus[sys1, sys2];
check["system optimized operands combine without changing value",
  sameNormalQ[sum, Normal[sys1] + Normal[sys2]]];
check["system optimized operands share one x+y temp after merge",
  OptimizedExpressions`OptimizedExpressionData[sum]["TemporaryCount"] == 1];

prod = OptimizedExpressions`OptimizedTimes[sys1, sys2];
quo = OptimizedExpressions`OptimizedDivide[sys1, sys2];
check["OptimizedTimes preserves value",
  sameNormalQ[prod, Normal[sys1] Normal[sys2]]];
check["OptimizedDivide preserves value",
  sameNormalQ[quo, Normal[sys1]/Normal[sys2]]];

base = OptimizedExpressions`OptimizeExpressionDAG[(x + y)^2 + z (x + y)];
replacement = OptimizedExpressions`OptimizeExpressionDAG[(p + q)^2 + (p + q)^3];
sub = OptimizedExpressions`OptimizedSubstitute[base, x -> replacement];
check["OptimizedSubstitute exact-symbol rule preserves value",
  sameNormalQ[
    sub,
    ((x + y)^2 + z (x + y)) /. x ->
      OptimizedExpressions`OptimizedExpressionNormal[replacement]
  ]];

list1 = OptimizedExpressions`OptimizeExpressionDAG[{(x + y)^2, (x + y)^3}];
list2 = OptimizedExpressions`OptimizeExpressionDAG[{z (x + y), w (x + y)}];
listSum = OptimizedExpressions`OptimizedPlus[list1, list2];
check["OptimizedPlus is elementwise for equal-length list operands",
  sameNormalQ[listSum, {(x + y)^2 + z (x + y), (x + y)^3 + w (x + y)}]];

pure = OptimizedExpressions`OptimizedApply[
  Function[{u, v}, u^2 + 3 v],
  {sys1, sys2}
];
check["OptimizedApply pure Function preserves value",
  sameNormalQ[pure, Normal[sys1]^2 + 3 Normal[sys2]]];
check["OptimizedApply pure Function keeps shared x+y temp",
  OptimizedExpressions`OptimizedExpressionData[pure]["TemporaryCount"] == 1];

notExtracted = OptimizedExpressions`OptimizeExpressionDAG[
  (x + y)^2 + (x + y)^3,
  "MinCommonLeafCount" -> 100,
  "MaxInlineLeafCount" -> 100
];
check["MinCommonLeafCount can suppress small repeated extraction",
  assignmentCount[notExtracted] == 0];

opaque = OptimizedExpressions`OptimizeExpressionDAG[
  HoldForm[x + y]^2 + HoldForm[x + y]^3,
  "ExcludedHeads" -> {HoldForm}
];
check["ExcludedHeads keeps matching expressions opaque",
  assignmentCount[opaque] == 0 &&
    sameNormalQ[opaque, HoldForm[x + y]^2 + HoldForm[x + y]^3]];

data = OptimizedExpressions`OptimizedExpressionData[sum];
check["OptimizedExpressionData reports expected keys",
  AssociationQ[data] &&
    AllTrue[
      {"NodeCount", "TemporaryCount", "Roots", "OccurrenceCounts",
       "LeafCounts", "OptimizedExpression", "NormalExpression"},
      KeyExistsQ[data, #] &
    ]];
check["OptimizedExpressionData sees the merged shared temp",
  data["TemporaryCount"] == 1];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS", ToString[fail] <> " FAILURE(S)"]];
Print["================================================================"];

If[fail > 0, Message[OptimizedExpressionsSmoke::fail, fail]];
If[$ScriptCommandLine =!= {}, Exit[If[fail == 0, 0, 1]]];
