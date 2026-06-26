(* ::Package:: *)

(* =====================================================================
   smoke.wl  --  load InverseAsymptotic` and re-verify the whole supported
                 class in a fresh kernel.

   Run:  & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/InverseAsymptotic/tests/smoke.wl
   Exit code 0 = all pass; 1 = a structural or numeric check failed.

   Each positive case asserts (a) the package's own rate-based back-substitution
   verifier passed, and (b) where a closed-form inverse is known, the truncated
   expansion agrees with it numerically to high precision at a sample on the
   valid side of the image point.  A few flagship cases are also checked
   SYMBOLICALLY against the answer quoted in the source MSE question.  Negative
   cases assert the package refuses (returns $Failed) on out-of-scale inputs.
   ===================================================================== *)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
pkg = FileNameJoin[{ParentDirectory[here], "InverseAsymptotic.wl"}];
Get[pkg];

fail = 0;
check[label_, cond_] := (
   Print[If[TrueQ[cond], "[PASS] ", "[FAIL] "], label];
   If[! TrueQ[cond], fail++]);

(* a sample on the valid side, deep in the asymptotic regime so that a high-order
   truncation error stays far below the comparison tolerance *)
sampleY[d_] := With[{b = d["ImagePoint"], sig = d["Sigma"], inf = d["InfiniteImage"]},
   If[inf, sig 10^4, b + sig/10^4]];

(* numeric agreement of the truncated expansion with a known closed form *)
agreesWithKnown[f_, x_, n_, known_, opts___] := Quiet@Block[{$MaxExtraPrecision = 400},
  Module[{d, yv, a, kk},
    d = InverseAsymptoticData[f, x, \[FormalY], n, opts];
    If[! AssociationQ[d], Return[False]];
    yv = sampleY[d];
    a = N[d["Expansion"] /. \[FormalY] -> yv, 80];
    kk = N[known /. \[FormalY] -> yv, 80];
    TrueQ[Abs[a - kk] < 10^-12 Max[Abs[kk], 1]]]];

(* direct back-substitution residual (no known inverse needed) *)
residualSmall[f_, x_, n_, opts___] := Quiet@Block[{$MaxExtraPrecision = 400},
  Module[{d, yv, xa},
    d = InverseAsymptoticData[f, x, \[FormalY], n, opts];
    If[! AssociationQ[d], Return[False]];
    yv = sampleY[d];
    xa = d["Expansion"] /. \[FormalY] -> yv;
    TrueQ[Abs[N[(f /. x -> xa) - yv, 40]] < 10^-12 Max[Abs[N[yv]], 1]]]];

verifiedQ[f_, x_, n_, opts___] := TrueQ[InverseAsymptoticData[f, x, \[FormalY], n, opts]["Verified"]];

Print["================================================================"];
Print["InverseAsymptotic smoke tests"];
Print["================================================================"];

(* ---- flagship symbolic checks against the MSE-quoted answers ---------- *)
ex2 = InverseAsymptotic[x + x^Sqrt[2], x, y, 4, "Remainder" -> False];
check["x + x^Sqrt2 matches MSE answer symbolically",
  PossibleZeroQ[Simplify[ex2 - (y - y^Sqrt[2] + Sqrt[2] y^(2 Sqrt[2] - 1)
       - (6 - Sqrt[2])/2 y^(3 Sqrt[2] - 2))]]];

ex1 = InverseAsymptotic[x + x^2 (1 + Log[x]), x, y, 2, "Remainder" -> False];
check["x + x^2(1+Log x) leading two levels = y - y^2(1+Log y)",
  PossibleZeroQ[Simplify[ex1 - (y - y^2 (1 + Log[y]))]]];

(* ---- closed-form inverses: high-precision numeric agreement ---------- *)
check["Exp[x]-1  -> Log[1+y]",          agreesWithKnown[Exp[x] - 1, x, 7, Log[1 + \[FormalY]]]];
check["Sin[x]    -> ArcSin[y]",         agreesWithKnown[Sin[x], x, 6, ArcSin[\[FormalY]]]];
check["Tan[x]    -> ArcTan[y]",         agreesWithKnown[Tan[x], x, 6, ArcTan[\[FormalY]]]];
check["Sinh[x]   -> ArcSinh[y]",        agreesWithKnown[Sinh[x], x, 6, ArcSinh[\[FormalY]]]];
check["x - x^2   -> Catalan g.f.",      agreesWithKnown[x - x^2, x, 7, (1 - Sqrt[1 - 4 \[FormalY]])/2]];
check["2x + x^2  -> Sqrt[1+y]-1",       agreesWithKnown[2 x + x^2, x, 7, -1 + Sqrt[1 + \[FormalY]]]];
check["x Exp[x]  -> ProductLog[y]",     agreesWithKnown[x Exp[x], x, 7, ProductLog[\[FormalY]]]];
check["x^2 + x^3 -> sqrt branch",       residualSmall[x^2 + x^3, x, 6]];
check["Log[x] at 1 -> Exp[y]",          agreesWithKnown[Log[x], x, 6, Exp[\[FormalY]], "At" -> 1]];
check["Cos[x] at 0+ -> ArcCos[y]",      agreesWithKnown[Cos[x], x, 5, ArcCos[\[FormalY]]]];
check["x + Sqrt[x] at Inf",             agreesWithKnown[x + Sqrt[x], x, 6,
     ((-1 + Sqrt[1 + 4 \[FormalY]])/2)^2, "At" -> Infinity]];
check["x^2 at 0- -> -Sqrt[y]",          agreesWithKnown[x^2, x, 3, -Sqrt[\[FormalY]],
     Direction -> "FromBelow"]];

(* ---- rate-based self-verification across the scale types ------------- *)
check["verify: x + x^2(1+Log x)",       verifiedQ[x + x^2 (1 + Log[x]), x, 4]];
check["verify: x + x^Sqrt2",            verifiedQ[x + x^Sqrt[2], x, 5]];
check["verify: x + x^(3/2)",            verifiedQ[x + x^(3/2), x, 5]];
check["verify: x^Pi + x",               verifiedQ[x^Pi + x, x, 3]];
check["verify: x + x^2 Log[x]",         verifiedQ[x + x^2 Log[x], x, 4]];
check["verify: x + Log[x] at Inf",      verifiedQ[x + Log[x], x, 4, "At" -> Infinity]];
check["verify: x - Log[x] at Inf",      verifiedQ[x - Log[x], x, 4, "At" -> Infinity]];

(* ---- negative cases: out-of-scale inputs must be refused ------------- *)
check["refuse leading-log  x Log[x]",   InverseAsymptotic[x Log[x], x, y, 3] === $Failed];
check["refuse oscillatory  Sin[1/x]",   InverseAsymptotic[Sin[1/x] - 1, x, y, 3] === $Failed];
check["refuse x Log[x] at Inf",         InverseAsymptotic[x Log[x], x, y, 3, "At" -> Infinity] === $Failed];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS", ToString[fail] <> " FAILURE(S)"]];
Print["================================================================"];
(* Exit only under genuine `wolfram -script` execution, not an interactive Get *)
If[$ScriptCommandLine =!= {}, Exit[If[fail == 0, 0, 1]]];
