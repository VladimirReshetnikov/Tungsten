(* ::Package:: *)

(* Runnable demo for CommonFactor`.

   Run:
     & "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/CommonFactor/Demo.wl
*)

here = If[StringQ[$InputFileName] && $InputFileName =!= "",
   DirectoryName[$InputFileName], Directory[]];
Get[FileNameJoin[{here, "CommonFactor.wl"}]];

b = Table[Prime[50 + k], {k, 1, 9}];
seq = Table[10^k Factorial2[2 k + 1] k^2 b[[k]], {k, 1, Length[b]}];

Print["Input sequence:"];
Print[seq];
Print[];

data = CommonFactorReduce[seq, n];

Print["Discovered symbolic common factor:"];
Print[ToString[data["Factor"], InputForm]];
Print[];

Print["Remaining quotient sequence:"];
Print[data["QuotientSequence"]];
Print[];

Print["Selected symbolic factors:"];
Scan[
  Function[item,
    With[{exprText = ToString[item["Expression"], InputForm],
        expText = If[item["Exponent"] === 1, "",
          "^" <> ToString[item["Exponent"], InputForm]]},
    Print[
      "  ", exprText, expText,
      "   (", item["Kind"], ", score ",
      ToString[NumberForm[item["StepScore"], {8, 3}], OutputForm], ")"
    ]]],
  data["SelectedFactors"]];

If[$ScriptCommandLine =!= {}, Exit[0]];
