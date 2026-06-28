(* ::Package:: *)

(* =====================================================================
   cross-from-inverse-2.wl

   Runs the test CASES of the GPT-5.5 reference implementation (IA-2, since
   removed; its cases are preserved here) against THIS package (IA-1),
   translated to IA-1's API.  Answers: "can IA-1 pass
   IA-2's tests?"  (Spoiler from the live kernel: yes, all 7 mathematically;
   the one caveat is that IA-1 does not accept IA-2's pure-function /
   ConditionalExpression input form -- see the FORM check.)

   Run:  & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/InverseAsymptotic/tests/cross-from-inverse-2.wl
   Exit 0 = all pass.  Loads ONLY IA-1 (no context collision).
   ===================================================================== *)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
Get[FileNameJoin[{ParentDirectory[here], "InverseAsymptotic.wl"}]];

fail = 0;
check[label_, cond_] := (Print[If[TrueQ[cond], "[PASS] ", "[FAIL] "], label];
   If[! TrueQ[cond], fail++]);

inv[f_, x_, y_, n_, o___] := Quiet@TimeConstrained[
   InverseAsymptotic[f, x, y, n, "Remainder" -> False, o], 30, $Failed];
eq[r_, exp_, as_] := r =!= $Failed && TrueQ[Quiet@Simplify[r - exp == 0, as]];

Print["=== IA-2's test cases against IA-1 ==="];

check["[IA2-1] x+x^2(1+Log x), goal 2",
  eq[inv[x + x^2 (1 + Log[x]), x, y, 2], y - y^2 (1 + Log[y]), y > 0]];

check["[IA2-2] x+x^2(1+Log x), goal 4 (full log-polynomial)",
  eq[inv[x + x^2 (1 + Log[x]), x, y, 4],
     y - y^2 + 3 y^3 - 23 y^4/2 - y^2 Log[y] + 5 y^3 Log[y] - 27 y^4 Log[y] +
       2 y^3 Log[y]^2 - 41 y^4 Log[y]^2/2 - 5 y^4 Log[y]^3, y > 0]];

check["[IA2-3] x+x^Sqrt[2], goal 4 (bare expression; see FORM note)",
  eq[inv[x + x^Sqrt[2], x, z, 4],
     z - z^Sqrt[2] + Sqrt[2] z^(2 Sqrt[2] - 1) - (6 - Sqrt[2]) z^(3 Sqrt[2] - 2)/2, z > 0]];

check["[IA2-4] x+x^2, goal 4",
  eq[inv[x + x^2, x, y, 4], y - y^2 + 2 y^3 - 5 y^4, y > 0]];

check["[IA2-5] 2x+x^2, goal 4",
  eq[inv[2 x + x^2, x, y, 4], y/2 - y^2/8 + y^3/16 - 5 y^4/128, y > 0]];

check["[IA2-6] x^2+x^3, goal 4",
  eq[inv[x^2 + x^3, x, y, 4], Sqrt[y] - y/2 + 5 y^(3/2)/8 - y^2, y > 0]];

check["[IA2-7] verify-equivalent (IA-1 self-verifies x+x^2(1+Log x))",
  TrueQ[Quiet@InverseAsymptoticData[x + x^2 (1 + Log[x]), x, y, 2]["Verified"]]];

(* FORM note (not counted as a failure): IA-2 accepts a pure function /
   ConditionalExpression; IA-1 takes a bare expression in x.  This documents the
   one input-form gap surfaced by IA-2's test 3. *)
Print["[FORM] IA-1 accepts ConditionalExpression[#+#^Sqrt2,#>=0]& as input? ",
  inv[ConditionalExpression[# + #^Sqrt[2], # >= 0] &, x, z, 4] =!= $Failed,
  "  (expected False -- IA-1 takes a bare expression; the math passes via [IA2-3])"];

Print["================================================================"];
Print[If[fail == 0, "ALL PASS -- IA-1 passes IA-2's tests", ToString[fail] <> " FAILURE(S)"]];
If[$ScriptCommandLine =!= {}, Exit[If[fail == 0, 0, 1]]];
