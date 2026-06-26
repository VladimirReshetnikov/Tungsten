(* ::Package:: *)

(* =====================================================================
   Demo.wl  --  a runnable showcase of InverseAsymptotic.

   Run:  & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/InverseAsymptotic/Demo.wl
   ===================================================================== *)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
Get[FileNameJoin[{here, "InverseAsymptotic.wl"}]];

show[label_, expr_] := (
  Print["----------------------------------------------------------------"];
  Print[label];
  Print["  ", expr]);

Print["================================================================"];
Print["InverseAsymptotic -- real-branch asymptotics of inverse functions"];
Print["================================================================"];

Print["\n### The two Mathematica StackExchange #236367 examples ###"];

show["f(x) = x + x^2 (1 + Log x),  real branch of f^(-1)(y) as y -> 0+",
  InverseAsymptotic[x + x^2 (1 + Log[x]), x, y, 3]];

show["f(x) = x + x^Sqrt[2],  irrational-power scale  (matches the asker's answer)",
  InverseAsymptotic[x + x^Sqrt[2], x, y, 4]];

Print["\n### Classical inverses recovered exactly ###"];
show["Exp[x] - 1  ->  Log[1 + y]",        InverseAsymptotic[Exp[x] - 1, x, y, 5]];
show["Sin[x]      ->  ArcSin[y]",         InverseAsymptotic[Sin[x], x, y, 4]];
show["Tan[x]      ->  ArcTan[y]",         InverseAsymptotic[Tan[x], x, y, 4]];
show["x - x^2     ->  Catalan numbers",   InverseAsymptotic[x - x^2, x, y, 5]];
show["x Exp[x]    ->  ProductLog[y] (Lambert W Maclaurin)",
  InverseAsymptotic[x Exp[x], x, y, 6]];

Print["\n### Other power-log and irrational scales ###"];
show["x + x^(3/2)", InverseAsymptotic[x + x^(3/2), x, y, 4]];
show["x^Pi + x",    InverseAsymptotic[x^Pi + x, x, y, 3]];
show["x + x^2 Log[x]", InverseAsymptotic[x + x^2 Log[x], x, y, 3]];

Print["\n### Inversion at a nonzero point, and at infinity ###"];
show["Log[x] at x -> 1   ->  Exp[y]",
  InverseAsymptotic[Log[x], x -> 1, y, 5]];
show["x + Log[x] as x -> Infinity   (image -> Infinity)",
  InverseAsymptotic[x + Log[x], x, y, 4, "At" -> Infinity]];
show["x + Sqrt[x] as x -> Infinity",
  InverseAsymptotic[x + Sqrt[x], x, y, 5, "At" -> Infinity]];

Print["\n### One-sided real branch via Direction ###"];
show["x^2 from below  ->  -Sqrt[y]",
  InverseAsymptotic[x^2, x, y, 2, Direction -> "FromBelow"]];

Print["\n### Diagnostics association ###"];
Module[{d = InverseAsymptoticData[x + x^Sqrt[2], x, y, 4]},
  Print["  LeadingPower      = ", d["LeadingPower"]];
  Print["  Side              = ", d["Side"]];
  Print["  RemainderExponent = ", d["RemainderExponent"]];
  Print["  RealBranches      = ", d["RealBranches"]];
  Print["  Verified          = ", d["Verified"],
        "   (measured decay order ", N[d["MeasuredOrder"], 6], ")"]];

Print["\n### Out-of-scale inputs are refused, not guessed ###"];
Print["  x Log[x] (leading log -> Lambert-W regime):"];
Print["    ", Quiet@Check[InverseAsymptotic[x Log[x], x, y, 3], "$Failed + InverseAsymptotic::leadlog"]];

Print["\n### Merged idiomatic interface (IA-2 surface) ###"];
show["{x,x0},{y,y0} + SeriesTermGoal",
  InverseAsymptotic[x + x^2 (1 + Log[x]), {x, 0}, {y, 0}, SeriesTermGoal -> 3]];
show["ConditionalExpression input (the MSE form)",
  InverseAsymptotic[ConditionalExpression[# + #^Sqrt[2], # >= 0] &, {x, 0}, {z, 0}, SeriesTermGoal -> 4]];

Print["\n### Real branch, never InverseFunction's branch ###"];
show["Sin -> ArcSin (through 0, NOT the x=Pi branch)",
  InverseAsymptotic[Sin[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4]];
show["Sinh -> ArcSinh (real, NOT complex)",
  InverseAsymptotic[Sinh[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4]];

Print["\n### Gated system-inverse fallback (verified real branch through x0) ###"];
Module[{d = InverseAsymptoticData[Erf[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4]},
  Print["  Erf[x] -> ", d["Expansion"], "   [", d["Method"], "]  (= InverseErf series)"]];
Print["  x Log[x]: gate rejects the analytic x=1 branch -> ",
  Quiet@InverseAsymptotic[x Log[x], {x, 0}, {y, 0}, SeriesTermGoal -> 3]];

Print["================================================================"];
