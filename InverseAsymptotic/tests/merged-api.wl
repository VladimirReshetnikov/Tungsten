(* ::Package:: *)

(* =====================================================================
   merged-api.wl  --  regression suite for the MERGED interface and the gated
   fallback (the "best of both" features added on top of the native engine).

   Run:  & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/InverseAsymptotic/tests/merged-api.wl
   Exit 0 = all pass.
   ===================================================================== *)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
Get[FileNameJoin[{ParentDirectory[here], "InverseAsymptotic.wl"}]];

fail = 0;
check[label_, cond_] := (Print[If[TrueQ[cond], "[PASS] ", "[FAIL] "], label];
   If[! TrueQ[cond], fail++]);

eq[r_, exp_, as_] := r =!= $Failed && TrueQ[Quiet@Simplify[r - exp == 0, as]];
nm[r_, y_, y0_, side_, known_, big_: False] := Quiet@Block[{$MaxExtraPrecision = 300},
  Module[{yv, a, k}, If[r === $Failed, Return[False]];
    yv = If[big, side*10^4, y0 + side/10^4];
    a = N[r /. y -> yv, 40]; k = N[known /. y -> yv, 40];
    NumericQ[a] && Im[N[a]] == 0 && TrueQ[Abs[a - k] < 10^-10 Max[Abs[k], 1]]]];

Print["================================================================"];
Print["InverseAsymptotic merged-API + gated-fallback tests"];
Print["================================================================"];

(* ---- IA-2's own 7 test cases, via the merged {x,x0},{y,y0} / SeriesTermGoal API
        (including the pure-Function / ConditionalExpression input form) -------- *)
Print["-- IA-2's test cases through the merged API --"];
check["[IA2-1] x+x^2(1+Log x) goal 2",
  eq[InverseAsymptotic[x + x^2 (1 + Log[x]), {x, 0}, {y, 0}, SeriesTermGoal -> 2,
      Assumptions -> y > 0, "Remainder" -> False], y - y^2 (1 + Log[y]), y > 0]];
check["[IA2-2] x+x^2(1+Log x) goal 4",
  eq[InverseAsymptotic[x + x^2 (1 + Log[x]), {x, 0}, {y, 0}, SeriesTermGoal -> 4,
      "Remainder" -> False], y - y^2 + 3 y^3 - 23 y^4/2 - y^2 Log[y] + 5 y^3 Log[y] -
       27 y^4 Log[y] + 2 y^3 Log[y]^2 - 41 y^4 Log[y]^2/2 - 5 y^4 Log[y]^3, y > 0]];
check["[IA2-3] ConditionalExpression[#+#^Sqrt2,#>=0]& goal 4",
  eq[InverseAsymptotic[ConditionalExpression[# + #^Sqrt[2], # >= 0] &, {x, 0}, {z, 0},
      SeriesTermGoal -> 4, "Remainder" -> False],
     z - z^Sqrt[2] + Sqrt[2] z^(2 Sqrt[2] - 1) - (6 - Sqrt[2]) z^(3 Sqrt[2] - 2)/2, z > 0]];
check["[IA2-4] x+x^2 goal 4",
  eq[InverseAsymptotic[x + x^2, {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False],
     y - y^2 + 2 y^3 - 5 y^4, y > 0]];
check["[IA2-5] 2x+x^2 goal 4",
  eq[InverseAsymptotic[2 x + x^2, {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False],
     y/2 - y^2/8 + y^3/16 - 5 y^4/128, y > 0]];
check["[IA2-6] x^2+x^3 goal 4",
  eq[InverseAsymptotic[x^2 + x^3, {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False],
     Sqrt[y] - y/2 + 5 y^(3/2)/8 - y^2, y > 0]];
check["[IA2-7] InverseAsymptoticVerify residual",
  TrueQ[InverseAsymptoticVerify[x + x^2 (1 + Log[x]), y - y^2 (1 + Log[y]),
     {x, 0}, {y, 0}]["ResidualSmallerThanLastTerm"]]];

(* ---- branch correctness through the merged API (where IA-2's fallback fails) -- *)
Print["-- real-branch correctness (native, no InverseFunction branch) --"];
check["Sin -> ArcSin (through 0, not Pi)",
  nm[InverseAsymptotic[Sin[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False],
     y, 0, 1, ArcSin[y]]];
check["Sinh -> ArcSinh (real, not complex)",
  nm[InverseAsymptotic[Sinh[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False],
     y, 0, 1, ArcSinh[y]]];
check["Cos at {x,0},{y,1} -> +ArcCos",
  nm[InverseAsymptotic[Cos[x], {x, 0}, {y, 1}, SeriesTermGoal -> 4, "Remainder" -> False],
     y, 1, -1, ArcCos[y]]];
check["x^2 Direction FromBelow -> -Sqrt[y]",
  nm[InverseAsymptotic[x^2, {x, 0}, {y, 0}, SeriesTermGoal -> 2, Direction -> "FromBelow",
      "Remainder" -> False], y, 0, 1, -Sqrt[y]]];

(* ---- gated system-inverse fallback ---------------------------------------- *)
Print["-- gated fallback --"];
Module[{d = InverseAsymptoticData[Erf[x], {x, 0}, {y, 0}, SeriesTermGoal -> 4]},
  check["Erf uses GatedSystemInverseFallback",
    AssociationQ[d] && d["Method"] === "GatedSystemInverseFallback"];
  check["Erf expansion matches InverseErf",
    AssociationQ[d] && TrueQ[Quiet@PossibleZeroQ[
       d["Expansion"] - Normal@Series[InverseErf[y], {y, 0, 4}]]]]];
check["x Log[x]: gate REJECTS the x=1 branch -> $Failed",
  InverseAsymptotic[x Log[x], {x, 0}, {y, 0}, SeriesTermGoal -> 3] === $Failed];
check["Sin[1/x]-1: oscillatory -> $Failed",
  InverseAsymptotic[Sin[1/x] - 1, {x, 0}, {y, 0}, SeriesTermGoal -> 3] === $Failed];

(* ---- Verify distinguishes a valid inverse from a wrong-branch one ---------- *)
Print["-- InverseAsymptoticVerify --"];
Module[{good = InverseAsymptoticVerify[x + x^2 (1 + Log[x]), y - y^2 (1 + Log[y]), {x, 0}, {y, 0}],
        wrong = InverseAsymptoticVerify[Sin[x], Pi - y - y^3/6, {x, 0}, {y, 0}]},
  check["Verify good approx: Satisfies & PassesThroughX0",
    TrueQ[good["SatisfiesEquation"]] && TrueQ[good["PassesThroughX0"]]];
  check["Verify pi-branch: Satisfies but NOT PassesThroughX0",
    TrueQ[wrong["SatisfiesEquation"]] && ! TrueQ[wrong["PassesThroughX0"]]]];

(* ---- Terms, and compat <-> spec API agreement ----------------------------- *)
Print["-- Terms and API equivalence --"];
check["InverseAsymptoticTerms returns a term table",
  MatchQ[InverseAsymptoticTerms[x + x^Sqrt[2], {x, 0}, {z, 0}, SeriesTermGoal -> 3],
    {__Association}]];
check["compat API == spec API (x+x^Sqrt2, n=4)",
  eq[InverseAsymptotic[x + x^Sqrt[2], x, y, 4, "Remainder" -> False],
     InverseAsymptotic[x + x^Sqrt[2], {x, 0}, {y, 0}, SeriesTermGoal -> 4, "Remainder" -> False], y > 0]];
check["rule form x->1 (Log[x] -> Exp[y])",
  nm[InverseAsymptotic[Log[x], x -> 1, y, SeriesTermGoal -> 5, "Remainder" -> False], y, 0, 1, Exp[y]]];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS", ToString[fail] <> " FAILURE(S)"]];
If[$ScriptCommandLine =!= {}, Exit[If[fail == 0, 0, 1]]];
