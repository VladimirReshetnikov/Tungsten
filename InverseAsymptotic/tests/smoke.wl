(* ::Package:: *)

(* Smoke tests for InverseAsymptotic.  This file is meant to be run with
   wolfram -script or Get.  It sets $InverseAsymptoticSmokeResult to the
   TestReport object and returns the same value. *)

testFile = FileNameJoin[{DirectoryName[$InputFileName], "inverse-asymptotic.wlt"}];

$InverseAsymptoticSmokeResult = TestReport[testFile];
$InverseAsymptoticSmokeResult
