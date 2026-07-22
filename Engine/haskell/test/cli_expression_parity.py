#!/usr/bin/env python3
"""Exact Python/Haskell golden checks for the expression CLI contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


CASES = (
    ("parse success", ("expr", "parse", "--code", "f[a, 2]", "--form", "input"), 0),
    (
        "tagged delayed assignment parser",
        (
            "expr",
            "parse",
            "--code",
            "f /: h[f[x_]] := x",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "tagged spaced unset parser",
        (
            "expr",
            "parse",
            "--code",
            "f /: h[f[x_]] = .",
            "--form",
            "input",
        ),
        0,
    ),
    ("evaluation success", ("expr", "evaluate", "--code", "1 + 2", "--form", "input"), 0),
    (
        "flat one-identity downvalue",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; "
            "f[x_, y_] := HoldComplete[x, y]; f[a, b, c]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "flat downvalue preserves unary wrapper",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; SetAttributes[f, Flat]; "
            "f[x_, y_] := HoldComplete[x, y]; f[a, b, c]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "orderless typed downvalue",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; SetAttributes[f, Orderless]; "
            "f[x_Symbol, y_Integer] := HoldComplete[x, y]; f[a, 1]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "catalog flat matching",
        (
            "expr",
            "evaluate",
            "--code",
            "MatchQ[HoldComplete[Plus[a, b, c]], "
            "HoldComplete[Plus[x_, y_]]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "orderless callback backtracking",
        (
            "expr",
            "evaluate",
            "--code",
            "c = 0; ClearAll[f, q]; SetAttributes[f, Orderless]; "
            "q[x_] := (c = c + 1; IntegerQ[x]); "
            "{MatchQ[HoldComplete[f[a, 1]], "
            "HoldComplete[f[x_?q, y_Symbol]]], c}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "pattern callbacks update later attributes",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, g, q]; "
            "q[x_] := (SetAttributes[g, {Flat, OneIdentity}]; True); "
            "MatchQ[HoldComplete[f[a, g[b, c, d]]], "
            "HoldComplete[f[x_?q, g[y_, z_]]]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "optional sequence width",
        (
            "expr",
            "evaluate",
            "--code",
            "Cases[{f[], f[a], f[a, b]}, "
            "f[x:Optional[__]] :> HoldComplete[x]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "flat sequence alternatives",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; "
            "f[x:Alternatives[__Integer, __Symbol]] := HoldComplete[x]; "
            "{f[1, 2], f[a, b], f[1, a]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "orderless pattern binding order",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; SetAttributes[f, Orderless]; "
            "ReplaceAll[HoldComplete[f[a, b, c]], "
            "HoldComplete[f[c, y_, z_]] :> HoldComplete[y, z]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "curried subvalue dispatch",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f[x_][y_] := {x, y}; "
            "{f[1][2], DownValues[f], SubValues[f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "evaluated subvalue owner",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, g]; f[x_] := g[x]; f[x_][y_] := {x, y}; "
            "{f[1][2], SubValues[f], SubValues[g]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "curried subvalue unset",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f[x_][y_] := {x, y}; "
            "first = Unset[f[x_][y_]]; "
            "{first, f[1][2], SubValues[f], Unset[f[x_][y_]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "normalized curried owner becomes downvalue",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, g]; f[x_] := g; f[u_][v_] := {u, v}; "
            "{f[1][2], DownValues[g], SubValues[g]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "subvalue fires inside deeper call",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, p]; f[x_][y_] := p[x, y]; f[1][2][3]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "curried attribute layers",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, a, b]; a = 1; b = 2; "
            "SetAttributes[f, HoldAll]; f[a][b] = rhs; "
            "{f[a][b], f[1][2], SubValues[f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "explicit subvalue context spelling",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[Global`sv]; Global`sv[x_][y_] := global[x, y]; "
            "{sv[1][2], Global`sv[1][2], SubValues[sv]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "natural tagged subvalue",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f /: f[x_][y_] := {x, y}; "
            "{f[1][2], SubValues[f], UpValues[f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "upvalue precedes downvalue",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, h]; f /: h[f] := up; h[x_] := down; "
            "{h[f], DownValues[h], UpValues[f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "upvalue HoldAllComplete suppression and tagged unset",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, h]; f /: h[f[x_]] := up[x]; "
            "SetAttributes[h, HoldAllComplete]; "
            "{h[f[2]], f /: h[f[x_]] =., h[f[2]], UpValues[f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "tagged own-value equation provenance",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f = 7; "
            "first = TagUnset[f, Condition[f, True]]; "
            "seeded = TagUnset[$RecursionLimit, $RecursionLimit]; "
            "{first, f, seeded, $RecursionLimit}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "explicit system tagged owner",
        (
            "expr",
            "evaluate",
            "--code",
            "TagSetDelayed[System`fresh, fresh[x_], x]; "
            "{fresh[1], DownValues[System`fresh], UpValues[System`fresh]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ValueQ definitions and effects",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f, g, h, q, c]; c = 0; "
            "f[x_] := (c = c + 1; x); h[x_][y_] := {x, y}; "
            "g /: q[g] := up; "
            "{ValueQ[f[2]], ValueQ[h[1][2]], ValueQ[q[g]], "
            "ValueQ[q[z]], c}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ValueQ atoms contexts and failure",
        (
            "expr",
            "evaluate",
            "--code",
            "{ValueQ[1], ValueQ[1 + 1], ValueQ[$Context], "
            "ValueQ[Global`$Context], ValueQ[Part[{1}, 2]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ValueQ print effect",
        (
            "expr",
            "evaluate",
            "--code",
            'ValueQ[Print["valueq"]]',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "context registry construction and queries",
        (
            "expr",
            "evaluate",
            "--code",
            "{$Context, $ContextPath, Context[], Context[Plus], Context[user], "
            "Symbol[\"PortContext`alpha\"], SymbolName[PortContext`alpha], "
            "Contexts[\"PortContext`*\"], "
            "Names[{\"PortContext`*\", \"System`Plus\"}], "
            "NameQ[\"PortContext`alpha\"]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "name visibility patterns and catalog",
        (
            "expr",
            "evaluate",
            "--code",
            "{Length[Names[\"System`*\"]], "
            "Names[{\"System`Plus\", \"System`Times\"}], "
            "NameQ[{\"Plus\", \"missing\"}], Context[Global`Plus], "
            "SymbolName[\"GhostContext`x\"], Names[\"GhostContext`*\"]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "context holding aliases and diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, n]; x = Plus; n = Names; "
            "{Context[x], Context[Evaluate[x]], "
            "System`Symbol[\"Global`qualifiedName\"], "
            "n[\"System`Plus\"], Global`Names[\"*\"], "
            "Context[x, Print[\"context-extra\"]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "context own value remains observationally implicit",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[$Context]; $Context = \"FakeContext`\"; "
            "{$Context, OwnValues[$Context], ValueQ[$Context]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "catalog formal symbol name resolution",
        (
            "expr",
            "evaluate",
            "--code",
            "{Symbol[\"System`\\[FormalA]\"], "
            "SymbolName[\"System`\\[FormalA]\"], "
            "Context[\"System`\\[FormalA]\"]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Unique forms and independent counters",
        (
            "expr",
            "evaluate",
            "--code",
            "{Unique[], Unique[x], Unique[FreshContext`x], "
            "Unique[\"x\"], Unique[\"x\"], Unique[\"y\"], "
            "Unique[{x, \"x\", FreshContext`x}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Unique shares Module counter and skips string collisions",
        (
            "expr",
            "evaluate",
            "--code",
            "Symbol[\"pre1\"]; Symbol[\"pre3\"]; "
            "{Unique[], Module[{a, b}, {a, b}], Unique[z], "
            "Unique[\"pre\"], Unique[\"pre\"], Unique[\"pre\"], "
            "Module[{q}, q], Unique[]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Unique retains partial allocation and evaluated effects",
        (
            "expr",
            "evaluate",
            "--code",
            "Unique[{\"partial\", 1}]; "
            "{Names[\"partial*\"], Unique[\"partial\"], "
            "Unique[Print[\"unique-effect\"]], "
            "Unique[Sequence[x, y]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Unique rejects invalid generated formal names after counting",
        (
            "expr",
            "evaluate",
            "--code",
            "Unique[{\\[FormalA], x}]; Unique[]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Evaluate transparently prepares ordinary arguments",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, e]; x = y; e = Evaluate; "
            "{Evaluate[x], System`Evaluate[x], "
            "Evaluate[Unevaluated[x]], e[x], Unique[Evaluate[x]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "callable Nothing retains effects across spellings",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, n]; x = 0; n = Nothing; "
            "{Nothing[x = x + 1, Print[\"nothing\"]], "
            "System`Nothing[x = x + 1], n[x = x + 1], "
            "Global`Nothing[x = x + 1], x}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "SameAs callable target and arity behavior",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; x = 1; "
            "{SameAs[1][], SameAs[1][1], SameAs[1][1, 1], "
            "SameAs[x][1], System`SameAs[1][1], "
            "SameAs[1, 2][1], SameAs[Sequence[1, 1]][1]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Composition callable direction and empty identity",
        (
            "expr",
            "evaluate",
            "--code",
            "{Composition[][x], Composition[][x, y], "
            "Composition[f][x, y], Composition[f, g][x, y], "
            "RightComposition[][x, y], "
            "RightComposition[f, g][x, y], "
            "Composition[Nothing, f][x], "
            "Composition[f, Nothing][x]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "empty Composition qualified Sequence and Splice normalization",
        (
            "expr",
            "evaluate",
            "--code",
            "{Composition[][System`Sequence[a, b], x], "
            "Composition[][System`Splice[{a, b}], x], "
            "Composition[][Splice[System`List[a, b]], x], "
            "RightComposition[][System`Splice[System`List[a, b]], x]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Composition named Function arity failure boundary",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[z, f]; z = 0; f[t_] := (z = 1; t); "
            "RightComposition[Function[{x, y}, x + y], f][1]; z",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Which held branches and unknown residual",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[u]; "
            "{Which[Print[\"c1\"]; False, Print[\"v1\"], "
            "Print[\"c2\"]; True, Print[\"v2\"], "
            "Print[\"c3\"]; True, Print[\"v3\"]], "
            "Which[False, a, u, 1/0, True, 2+2], "
            "Which[False, 1, False, 2]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Switch stateful pattern selection and control",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; "
            "{Switch[Print[\"subject\"]; 3, "
            "x_Integer /; (Print[x]; x > 3), a, "
            "y_Integer /; (Print[y]; y > 2), b], "
            "Switch[3, x_, x], "
            "Catch[Switch[1, _?(Function[t, Throw[tag]]), a, _, b]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Piecewise condition value and default timing",
        (
            "expr",
            "evaluate",
            "--code",
            "Piecewise[{{Print[\"vf\"], Print[\"cf\"]; False}, "
            "{Print[\"vu\"], Print[\"cu\"]; u}, "
            "{Print[\"vt\"], Print[\"ct\"]; True}, "
            "{Print[\"later\"], True}}, Print[\"default\"]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ReleaseHold exact one-layer behavior",
        (
            "expr",
            "evaluate",
            "--code",
            "{ReleaseHold[Hold[Hold[1+2]]], ReleaseHold[Hold[]], "
            "ReleaseHold[Hold[1, 2]], ReleaseHold[HoldPattern[1+2]], "
            "ReleaseHold[System`Hold[1+2]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Inactive holding application and atom behavior",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, i]; x = 0; i = Inactive; "
            "{Inactive[3], Inactive[f[x = x + 1]], x, "
            "Inactive[Evaluate[1+2]], Inactive[Plus][1, 2], "
            "System`Inactive[f], Global`Inactive[1+2], "
            "i[Sequence[Plus, Times]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Activate recursive selective traversal",
        (
            "expr",
            "evaluate",
            "--code",
            "{Activate[HoldComplete[Inactive[Plus][1, 2]]], "
            "Activate[Inactive[Plus][Inactive[Times][2, 3], 4], Times], "
            "Activate[Inactive[Plus][Inactive[Times][2, 3], 4], Plus], "
            "Activate[Inactive[f][Inactive[g][1], Inactive[h][2]], "
            "p_ /; (Print[p]; SameQ[p, g])], "
            "Switch[System`Inactive[f], IgnoringInactive[f], a, _, b], "
            "Activate[Inactive[System`Inactive[f]], IgnoringInactive[f]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "held head alias qualification and arity barriers",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, w, s, p, r, a, i]; x = 0; "
            "w = Which; s = Switch; p = Piecewise; "
            "r = ReleaseHold; a = Activate; i = Inactive; "
            "{w[False, 1, True, 2], s[3, _, 4], p[{{1, True}}], "
            "r[Hold[1+2]], a[Inactive[Plus][1, 2]], i[3], "
            "System`Which[True, 7], Global`Which[True, 8], "
            "Which[x = x + 1], Switch[x = x + 1, _], "
            "Piecewise[x = x + 1, 0, 1], "
            "ReleaseHold[x = x + 1, x = x + 1], Activate[], "
            "Inactive[x = x + 1, x = x + 1], x}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "held head direct and alias Sequence boundaries",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[qw, qs, qp, qr, qi, qa]; "
            "qw = Which; qs = Switch; qp = Piecewise; "
            "qr = ReleaseHold; qi = Inactive; qa = Activate; "
            "{Which[Sequence[False, a], True, b], "
            "Switch[Sequence[x], x, a], "
            "Piecewise[Sequence[{{1, True}}]], "
            "{ReleaseHold[Sequence[Hold[1+2]]]}, "
            "Inactive[Sequence[f]], Inactive[Sequence[f, g]], "
            "{Activate[Sequence[Inactive[Plus][1, 2]]]}, "
            "probe[qw[Sequence[False, a], True, b], "
            "qs[Sequence[x], x, a], "
            "qp[Sequence[{{1, True}}, 9]], "
            "qr[Sequence[Hold[1+2]]], qi[Sequence[f, g]], "
            "qa[Sequence[Inactive[Plus][1, 2]]]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "in-place arithmetic state and return values",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, y]; x = 5; "
            "first = {x++, x, x--, x, ++x, x, --x, x}; "
            "ClearAll[x]; second = {x++, x}; "
            "x = y; y = 5; third = {x++, x, y}; "
            "x = Unevaluated[5]; {first, second, third, "
            "{x++, x, OwnValues[x]}}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "AppendTo collection and definition targets",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, y, z, held, f, q]; x = {1, 2}; y = f[a]; "
            "z = <|a -> 1, b -> 2|>; f[t_] := {t}; "
            "SetAttributes[q, SequenceHold]; held = q[a]; "
            "{AppendTo[x, 3], x, AppendTo[y, b], y, "
            "AppendTo[z, b -> 9], z, AppendTo[f[q], 7], f[q], "
            "DownValues[f], AppendTo[held, Sequence[b, c]], held, "
            "AppendTo[z, c :> Print[\"late\"]], z[c]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "mutation qualification alias and Sequence boundaries",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, a, qi, qa]; x = 5; a = {1}; "
            "qi = Increment; qa = AppendTo; "
            "{System`Increment[x], System`Decrement[x], "
            "System`PreIncrement[x], System`PreDecrement[x], x, "
            "qi[x], Global`Increment[x], qi[Evaluate[x]], "
            "qi[Sequence[x, y]], qa[a, 2], Global`AppendTo[a, 2], "
            "qa[a, Sequence[b, c]], a}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "mutation validation and protection diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, y]; x = 5; y = {1}; Protect[x, y]; "
            "probe[Increment[x], AppendTo[y, 2], "
            "AppendTo[Print[\"append-arity\"]], "
            "Decrement[Print[\"left\"], Print[\"right\"]], "
            "PreIncrement[f[x]], x, y]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "mutation recovered errors and control timing",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, y]; x := Part[{1}, 2]; y = {1}; "
            "probe[x++, Catch[AppendTo[y, Throw[7]]], x, y, "
            "OwnValues[x], AppendTo[1, Print[\"item\"]], "
            "AppendTo[<|a -> 1|>, b], "
            "AppendTo[System`Association[a], Nothing]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "goto forward and backward control",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; first = (Goto[end]; never; Label[end]; reached); "
            "x = 0; second = (Label[start]; x = x + 1; "
            "If[x < 3, Goto[start]]; x); {first, second}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "goto nesting and scope restoration",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x, i, f]; x = 0; i = 99; "
            "duplicate = (Label[a]; x = x + 1; If[x == 1, Goto[a]]; "
            "Label[a]; x); "
            "nested = ((Goto[inner]; never; Label[inner]; reached)); "
            "x = 1; f[] := Goto[out]; "
            "scoped = (Block[{x = 2}, x = 3; Do[f[], {i, 1, 3}]]; "
            "never; Label[out]; {x, i}); {duplicate, nested, scoped}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "label qualification alias and trailing boundaries",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[l, g]; l = Label; g = Goto; "
            "{{Label[1 + 2], System`Label[1 + 2], Global`Label[1 + 2]}, "
            "{l[Sequence[a, b]], g[Sequence[a, b]]}, "
            "{(a; Label[end]), (Goto[end]; Label[end]), "
            "(System`Goto[end]; never; System`Label[end]; reached)}}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "label and goto arity barriers",
        (
            "expr",
            "evaluate",
            "--code",
            "probe[Label[Print[\"l1\"], Print[\"l2\"]], "
            "Goto[Print[\"g1\"], Print[\"g2\"]]]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "goto recovered target and nested effect timing",
        (
            "expr",
            "evaluate",
            "--code",
            "{(Goto[Part[]]; never; Label[Part[]]; reached), "
            "(Print[\"outer-before\"]; "
            "(Print[\"inner\"]; Goto[out]; Print[\"inner-never\"]; "
            "Label[other]); Print[\"outer-never\"]; Label[out]; "
            "Print[\"outer-after\"])}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "uncaught goto uses its evaluated raw-label target",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; x = end; (Goto[x]; never; Label[x]; reached)",
            "--form",
            "input",
        ),
        0,
    ),
    ("syntax error", ("expr", "parse", "--code", ")", "--form", "input"), 1),
    ("unfinished call", ("expr", "parse", "--code", "f[1", "--form", "input"), 1),
    ("unfinished operand", ("expr", "parse", "--code", "1 +", "--form", "input"), 1),
)


def _run(command: list[str]) -> tuple[int, object, str]:
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"command did not emit one JSON payload: {command!r}\n"
            f"stdout: {completed.stdout!r}\nstderr: {completed.stderr!r}"
        ) from error
    return completed.returncode, payload, completed.stderr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--haskell-executable",
        type=Path,
        required=True,
        help="Path returned by `cabal list-bin tungsten-hs`.",
    )
    arguments = parser.parse_args()

    haskell_executable = arguments.haskell_executable.resolve()
    if not haskell_executable.is_file():
        parser.error(f"Haskell executable does not exist: {haskell_executable}")

    for name, cli_arguments, expected_exit in CASES:
        python_result = _run([sys.executable, "-m", "tungsten", *cli_arguments])
        haskell_result = _run([str(haskell_executable), *cli_arguments])
        if python_result != haskell_result:
            raise AssertionError(
                f"{name} differs\n"
                f"Python:  {python_result!r}\n"
                f"Haskell: {haskell_result!r}"
            )
        if python_result[0] != expected_exit:
            raise AssertionError(
                f"{name} returned {python_result[0]}, expected {expected_exit}"
            )

    print(f"{len(CASES)} exact expression CLI parity checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
