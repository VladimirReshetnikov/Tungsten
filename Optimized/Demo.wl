(* ::Package:: *)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
pkg = FileNameJoin[{here, "OptimizedExpressions.wl"}];
If[! FileExistsQ[pkg],
  pkg = FileNameJoin[{Directory[], "Optimized", "OptimizedExpressions.wl"}]
];
Get[pkg];

o1 = Experimental`OptimizeExpression[(x + y)^2 + z (x + y),
  "OptimizationSymbol" -> a];
o2 = Experimental`OptimizeExpression[(x + y)^3 + w (x + y),
  "OptimizationSymbol" -> b];

Print["Operand 1:"];
Print[o1 // InputForm];

Print["Operand 2:"];
Print[o2 // InputForm];

sum = OptimizedExpressions`OptimizedPlus[o1, o2];

Print["Merged sum with shared x+y temporary:"];
Print[sum // InputForm];

Print["Expanded for inspection only:"];
Print[OptimizedExpressions`OptimizedExpressionNormal[sum] // InputForm];

Print["Diagnostics:"];
Print[KeyTake[
  OptimizedExpressions`OptimizedExpressionData[sum],
  {"NodeCount", "TemporaryCount", "Roots"}
] // InputForm];
