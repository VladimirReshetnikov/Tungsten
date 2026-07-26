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
    (
        "message ordering insertions and current-list snapshots",
        (
            "expr",
            "evaluate",
            "--code",
            "Message[f::tag, Part[], Print[\"insert\"]]; "
            "first = $MessageList; Message[g::other]; "
            "{first, $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "message suppression general tags and reactivation",
        (
            "expr",
            "evaluate",
            "--code",
            "Off[{f::tag, General::error}]; "
            "Message[f::tag, Print[\"suppressed\"]]; "
            "Part[f[a], 2]; Append[1, 2]; before = $MessageList; "
            "On[{f::tag, General::error}]; Message[f::tag]; "
            "{before, $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "message control partial mutations and update barrier",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; x = 1; Off[f::a, Part[], g::b]; "
            "Message[f::a]; Message[g::b]; Off[Part::error]; "
            "update = AddTo[x, Part[f[a], 2]]; "
            "{update, x, $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "message held-name validation and qualified display",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; x = f::tag; "
            "probe[Message[], Message[x, Print[\"bad\"]], "
            "Message[System`MessageName[f, \"tag\"]], "
            "Message[f::forms, InputForm[{1, 2}], FullForm[{1, 2}]], "
            "$MessageList]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "message qualification and alias dispatch boundaries",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[m, o]; m = Message; o = Off; "
            "{System`Message[f::one], Global`Message[f::two], "
            "m[f::three], System`Off[f::four], o[f::five], "
            "Message[f::four], Message[f::five], $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "message exact evaluated specs and final-tag suppression",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[t]; t = \"tag\"; Off[MessageName[f, t]]; "
            "Message[f::tag]; Message[MessageName[f, t]]; "
            "Off[General::other]; Message[g::x::other]; "
            "Message[g::kept]; $MessageList",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Quiet visibility and Check collector depth",
        (
            "expr",
            "evaluate",
            "--code",
            "{Check[Quiet[Part[]], outer], "
            "Quiet[Check[Part[], inner]], "
            "Quiet[Message[f::a]; Message[g::b], All, f::a], "
            "$MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Quiet and Check specification timing and arity barriers",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[x]; x = 0; "
            "first = Quiet[(x = 3; Message[f::a]), "
            "(x = 1; f::a), (x = 2; g::b)]; "
            "second = Check[Message[g::b], x = 4, (x = 5; g::b)]; "
            "probe[first, second, x, "
            "Quiet[Print[\"body\"], Print[\"off\"], Print[\"on\"], "
            "Print[\"extra\"]], Check[Print[\"check\"]], $MessageList]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Quiet nesting and qualified message specifications",
        (
            "expr",
            "evaluate",
            "--code",
            "{Quiet[Quiet[Message[f::tag], None, f::tag], All], "
            "Quiet[Quiet[Message[g::tag], All], All, g::tag], "
            "Quiet[Message[h::trace], System`All], "
            "Check[Message[i::trace], fallback, System`All], "
            "$MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Quiet and Check qualification and alias boundaries",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[q, c]; q = Quiet; c = Check; "
            "{System`Quiet[Part[]], Global`Quiet[Part[]], q[Part[]], "
            "System`Check[Part[], x], Global`Check[Part[], x], "
            "c[Part[], x], $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "Quiet and Check restore across non-local control",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[r]; r[] := Check[Return[x], fallback]; "
            "first = r[]; "
            "second = (Quiet[Goto[out]]; never; Label[out]; "
            "Message[f::a]; $MessageList); "
            "{first, second, Catch[Quiet[Throw[y]]], "
            "Message[g::b], $MessageList}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "abort protect ownership and compound re-deferral",
        (
            "expr",
            "evaluate",
            "--code",
            'CheckAbort[AbortProtect[AbortProtect[Abort[]; '
            'Print["innerTail"]]; Print["outerTail"]], fail]',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "same-depth check abort catches only its fresh abort",
        (
            "expr",
            "evaluate",
            "--code",
            "CheckAbort[AbortProtect[Abort[]; "
            "Print[CheckAbort[1, inner]]; "
            "Print[CheckAbort[Abort[], inner]]; "
            'Print["tail"]], fail]',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "abort scopes restore across throw and return",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f[] := AbortProtect[Return[returned]]; "
            "{Catch[AbortProtect[Throw[thrown]]], f[], "
            "CheckAbort[Abort[], caught]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "abort control arity diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{Abort[1], CheckAbort[1], AbortProtect[]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "with cleanup executes every stage exactly once",
        (
            "expr",
            "evaluate",
            "--code",
            "x = 0; result = WithCleanup[x = x + 1, x = x + 10, "
            "x = x + 100]; {result, x}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "with cleanup body and initializer abort effects",
        (
            "expr",
            "evaluate",
            "--code",
            'first = CheckAbort[WithCleanup[Print["expr1"]; Abort[]; '
            'Print["expr2"], Print["cleanup1"]], caught1]; '
            'second = CheckAbort[WithCleanup[Print["init1"]; Abort[]; '
            'Print["init2"], Print["body"], Print["cleanup2"]], caught2]; '
            "{first, second}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "with cleanup preserves an enclosing pending abort",
        (
            "expr",
            "evaluate",
            "--code",
            'CheckAbort[AbortProtect[Abort[]; WithCleanup[Print["init"], '
            'Print["body"], Print["cleanup"]]; Print["after"]], caught]',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "with cleanup covers every existing control exit",
        (
            "expr",
            "evaluate",
            "--code",
            'ClearAll[f]; f[] := WithCleanup[Return[returned], '
            'Print["returnCleanup"]]; '
            '{Catch[WithCleanup[Throw[thrown], Print["throwCleanup"]]], '
            'f[], Do[WithCleanup[Break[], Print["breakCleanup"]], {i, 3}], '
            '(WithCleanup[Goto[out], Print["gotoCleanup"]]; never; '
            "Label[out]; reached)}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "with cleanup signal precedence and arity diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f[] := WithCleanup[Return[body], Return[cleanup]]; "
            "{Catch[WithCleanup[Throw[body], Throw[cleanup]]], f[], "
            "CheckAbort[Catch[WithCleanup[Abort[], Throw[cleanup]]], caught], "
            "WithCleanup[1], WithCleanup[1, 2, 3, 4]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "timing zero duration qualification and structural timing",
        (
            "expr",
            "evaluate",
            "--code",
            "{Pause[0], TimeRemaining[], "
            "TimeConstrained[Pause[0]; 7, 1, fail], "
            "System`Pause[0], "
            "System`TimeConstrained[Pause[0]; 8, 1, fail], "
            "MatchQ[AbsoluteTiming[1 + 2], {_Real, 3}], "
            "MatchQ[TimeConstrained[TimeRemaining[], 1, fail], _Real]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "nested timing deadlines and abort protection",
        (
            "expr",
            "evaluate",
            "--code",
            "{TimeConstrained[Pause[.1]; 7, .02, timeout], "
            "TimeConstrained[TimeConstrained[Pause[.1]; 7, .02, inner], .2, outer], "
            "TimeConstrained[TimeConstrained[Pause[.1]; 7, .2, inner], .02, outer], "
            "CheckAbort[AbortProtect[TimeConstrained[Pause[.1], .02, inner]], fail]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "timed cleanup suppresses an expired deadline",
        (
            "expr",
            "evaluate",
            "--code",
            "TimeConstrained[WithCleanup[Pause[.1]; 7, "
            "Print[TimeRemaining[]]], .02, timeout]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "time scopes restore across every control signal",
        (
            "expr",
            "evaluate",
            "--code",
            "ClearAll[f]; f[] := TimeConstrained[Return[r], 1, timeout]; "
            "{Catch[TimeConstrained[Throw[t], 1, timeout]], "
            "Enclose[TimeConstrained[Confirm[$Failed], 1, timeout]], "
            "CheckAbort[TimeConstrained[Abort[], 1, timeout], a], "
            "Do[TimeConstrained[Break[], 1, timeout], {i, 1}], "
            "Do[TimeConstrained[Continue[], 1, timeout], {i, 1}], f[], "
            "(TimeConstrained[Goto[out], 1, timeout]; never; Label[out]; g)}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "timing diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{Pause[], Pause[-1], Pause[Infinity], TimeConstrained[1], "
            "TimeConstrained[1, x], TimeRemaining[1], AbsoluteTiming[], "
            "System`Pause[], System`TimeConstrained[1], "
            "System`TimeRemaining[1], System`AbsoluteTiming[]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "reap tag selectors and combiners",
        (
            "expr",
            "evaluate",
            "--code",
            "{Reap[Sow[1]; Sow[2]; 3], "
            "Reap[Sow[1, a]; Sow[2, b]; Sow[3, a]; 4], "
            "Reap[Sow[1, a]; Sow[2, 2]; 3, {_Symbol, _Integer}], "
            "Reap[Sow[1, a]; Sow[2, a]; 3, _, f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "nested reap chooses the nearest matching scope",
        (
            "expr",
            "evaluate",
            "--code",
            "{Reap[Reap[Sow[1, a]; 2, a], _], "
            "Reap[Reap[Sow[1, b]; 2, a], _], "
            "Reap[Sow[1, {a, b}]; 3, {a, b}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "reap pops before applying its combiner",
        (
            "expr",
            "evaluate",
            "--code",
            "Reap[Reap[Sow[1, a], a, "
            "Function[{tag, values}, Sow[values, outer]]], outer]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "reap effect order and control-scope restoration",
        (
            "expr",
            "evaluate",
            "--code",
            'first = Reap[Sow[(Print["value"]; 1), '
            '(Print["tag"]; a)]; 2]; '
            "second = Catch[Reap[Sow[1]; Throw[thrown]]]; "
            "third = CheckAbort[Reap[Sow[2]; Abort[]], caught]; "
            "fourth = (Reap[Sow[3]; Goto[out]]; never; Label[out]; reached); "
            "fifth = Catch[Reap[Sow[5, a], _, "
            "Function[{tag, values}, Throw[done]]]]; "
            "{first, second, third, fourth, fifth, Sow[4]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "qualified reap sow and arity diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{System`Reap[System`Sow[1]; 2], "
            "Sow[], Sow[1, 2, 3], Reap[], Reap[1, 2, 3, 4]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "failure predicates and properties",
        (
            "expr",
            "evaluate",
            "--code",
            '{FailureQ[Failure["x", <||>]], FailureQ[$Failed], '
            'FailureQ[$Canceled], FailureQ[$Aborted], '
            'FailureQ[Missing["x"]], MissingQ[Missing["x"]], '
            'MissingQ[$Failed], Failure["bad", <|"x" -> 1|>]["x"], '
            'Failure["bad", <||>]["Type"], '
            'Failure["bad", <||>]["absent"], '
            'System`FailureQ[System`Failure["x", <||>]]}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "failsafe guards and qualified operator",
        (
            "expr",
            "evaluate",
            "--code",
            '{Failsafe[f][1, 2], '
            'Failsafe[f][1, Missing["x"], Failure["bad", <||>]], '
            'Failsafe[f, SameQ][1, 1], '
            'Failsafe[f, SameQ][1, 2]["Type"], '
            'Failsafe[f, SameQ, g][1, 2], System`Failsafe[f][1, 2]}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "failsafe effects diagnostics and nonlocal exits",
        (
            "expr",
            "evaluate",
            "--code",
            'first = Failsafe[(Print["function"]; f), '
            '(Print["test"]; SameQ)][1, 1]; '
            'second = Catch[Failsafe[f, Function[x, Throw[x]]][1]]; '
            'third = CheckAbort[Failsafe[f, Function[x, Abort[]]][1], caught]; '
            'Failure["x", <||>][1]; '
            'Failsafe[Print["f"], Print["test"], Print["failure"], '
            'Print["extra"]]; {first, second, third}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "confirmation values predicates and property handlers",
        (
            "expr",
            "evaluate",
            "--code",
            '{Enclose[1 + Confirm[2]], '
            'Enclose[Confirm[Missing["Nope"], "info"], "Expression"], '
            'Enclose[Confirm[Missing["Nope"], "info"], "Information"], '
            'Enclose[ConfirmBy[3, IntegerQ]], '
            'Enclose[ConfirmBy[3, StringQ, "info"], "Function"], '
            'Enclose[ConfirmMatch[3, _Integer]], '
            'Enclose[ConfirmMatch[3, _String, "info"], "Pattern"]}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "tagged nested confirmation scopes and patterns",
        (
            "expr",
            "evaluate",
            "--code",
            'c = 0; first = Enclose[Confirm[$Failed, "info", tag], '
            '"Information", tag]; second = Enclose['
            'Enclose[Confirm[$Failed, "outer", outer], inner, inner], '
            '"Information", outer]; third = Enclose['
            'Confirm[$Failed, Null, 1], "Information", '
            'x_ /; (c = c + 1; True)]; '
            'fourth = Enclose[ConfirmMatch[1, '
            'x_ /; (c = c + 1; False), c], "Information"]; '
            '{first, second, third, fourth, c}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "confirmation effects cleanup and nonlocal exits",
        (
            "expr",
            "evaluate",
            "--code",
            'first = Enclose[Confirm[Missing["x"], '
            '(Print["info"]; "i"), (Print["tag"]; tag)], '
            '(Print["handler"]; "Information"), tag]; '
            'second = Enclose[WithCleanup[Confirm[$Failed, "bad"], '
            'Print["cleanup"]], "Information"]; '
            'third = Catch[Enclose[Throw[x]]]; '
            'fourth = CheckAbort[Enclose[Abort[]], caught]; '
            'fifth = (Enclose[Goto[out]]; never; Label[out]; reached); '
            '{first, second, third, fourth, fifth}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "confirmation messages malformed calls and unsupported heads",
        (
            "expr",
            "evaluate",
            "--code",
            'first = Quiet[Confirm[$Failed]]; '
            'second = Enclose[Confirm[$Failed], '
            'Function[failure, Confirm[$Failed]]]; '
            'malformed = {Enclose[], Confirm[], '
            'ConfirmBy[Print["value"]], ConfirmMatch[Print["value"]]}; '
            '{first, second, malformed, '
            'ConfirmQuiet[Failure["x", <||>]], FailWhen[1, True], '
            'System`Enclose[System`Confirm[$Failed], "Expression"]}',
            "--form",
            "input",
        ),
        0,
    ),
    (
        "dense array construction origins and callables",
        (
            "expr",
            "evaluate",
            "--code",
            "{Array[f,{2,2},{0,-1}], Array[Function[x,x^2],3], "
            "Array[f,{}], ConstantArray[x,{2,0,3}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "dense array shape predicates",
        (
            "expr",
            "evaluate",
            "--code",
            "{ArrayQ[{{1,2},{3,4}},2,IntegerQ], "
            "ArrayQ[{{1},{2,3}}], ArrayQ[{}], ArrayQ[x,bad], "
            "ArrayQ[{{1},{2,3}},bad], "
            "VectorQ[{1,a},IntegerQ], MatrixQ[{{}}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "rank N dense array transformations",
        (
            "expr",
            "evaluate",
            "--code",
            "{ArrayReshape[{{1,2},{3,4}},{3,2},x], "
            "ArrayReshape[{{}},{2,0,3}], "
            "ArrayPad[{{1,2},{3,4}},{{1,0},{0,1}},x], "
            "ArrayFlatten[{{{{1,2},{3,4}},{{5},{6}}},{{{7,8}},{{9}}}}], "
            "Transpose[{{{a,b},{c,d}},{{e,f},{g,h}}},{3,1,2}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "dense vector matrix and antisymmetric constructors",
        (
            "expr",
            "evaluate",
            "--code",
            "{IdentityMatrix[0], UnitVector[5,3], LeviCivitaTensor[0], "
            "LeviCivitaTensor[2], LeviCivitaTensor[2,f]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "dense array diagnostics remain nonfatal",
        (
            "expr",
            "evaluate",
            "--code",
            "{Array[f,{2,3},{4}], ArrayQ[{{1}},x], "
            "ArrayPad[{{1,2},{3}},1], ArrayFlatten[{{}}], "
            "Transpose[{{1,2},{3,4}},{1,1}], LeviCivitaTensor[-1]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "clipping splitting and contiguous subsequences",
        (
            "expr",
            "evaluate",
            "--code",
            "{Clip[-3],Clip[9,{-5,5}],Clip[-7,{-5,5},{100,200}], "
            "Split[{a,a,b,b,a}],SplitBy[{1,3,2,4,5},EvenQ], "
            "DeleteAdjacentDuplicates[{a,a,b,a,a}], "
            "Subsequences[{a,b,c},{0,2}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "alphabetic numerical and lexicographic ordering",
        (
            "expr",
            "evaluate",
            "--code",
            "{AlphabeticSort[{\"beta\",\"Alpha\",\"gamma\"}], "
            "NumericalSort[{\"x10\",\"x2\",\"x1\"}], "
            "LexicographicOrder[{1,2},{1,3}], "
            "LexicographicOrder[\"a\",\"aa\"], "
            "LexicographicSort[{{1,3},{1,2},{0,9}}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "duplicate containment counts and diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{DeleteDuplicates[{a,b,a,c,b}], "
            "DeleteDuplicatesBy[{{a},{b,c},{d},{e,f}},Length], "
            "DeleteDuplicatesBy[{1,2,3,4,5,6},Mod[#,3]&,SameQ], "
            "DuplicateFreeQ[{a,b,a}], "
            "ContainsOnly[{1.0,2},{1,2,3},SameTest->Equal], "
            "CountsBy[{1.5,1.7,1.9,2.5,3.7},Floor], "
            "Clip[x],Subsequences[{a,b},{0,1,2}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "quantiles and quartile interpolation",
        (
            "expr",
            "evaluate",
            "--code",
            "{Quantile[{1,2,3,4,5},2^-1], "
            "Quantile[{1,2,3,4,5},{4^-1,2^-1,3*4^-1}], "
            "Quantile[Range[10],2^-1,{{2^-1,0},{0,1}}], "
            "Quartiles[Range[10]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "numeric bin counts and lists",
        (
            "expr",
            "evaluate",
            "--code",
            "{BinCounts[Range[10],{0,10,2}], "
            "BinCounts[{1.1,2.5,3.7,4.0},{0,5,1}], "
            "BinCounts[Range[10],2], BinLists[Range[10],{0,10,2}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "permutation conversions and recoverable diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{PermutationCycles[{2,3,1,4}], "
            "PermutationList[Cycles[{{1,2},{3,4}}],4], "
            "PermutationOrder[Cycles[{{1,2,3,4,5},{6,7}}]], "
            "Quantile[{},2^-1], BinCounts[{},2], PermutationCycles[{1,1}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "exact integer arithmetic and number theory",
        (
            "expr",
            "evaluate",
            "--code",
            "{Binomial[-3,2],Multinomial[2,3,4],Fibonacci[-6],LucasL[-6],"
            "HarmonicNumber[5,2],Mod[-14,5],QuotientRemainder[-14,5],"
            "GCD[-12,18,30],LCM[-4,6],Divisors[-12],PrimeQ[1000000007],"
            "EulerPhi[12],CarmichaelLambda[12],MoebiusMu[6],"
            "JordanTotient[2,10],DivisorSigma[-1,6],PrimePi[100],Prime[10],"
            "NextPrime[10,3],PowerMod[3,-1,7],MultiplicativeOrder[2,7]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "structured exact number reducers",
        (
            "expr",
            "evaluate",
            "--code",
            "{FactorInteger[-12],FactorInteger[FromContinuedFraction[{0,1,1,17}]],"
            "FactorInteger[210,2],IntegerExponent[1000],"
            "ContinuedFraction[FromContinuedFraction[{4,2,6,7}]],"
            "FromContinuedFraction[{4,2,6,7}],IntegerPartitions[4,{2}],"
            "FromDigits[{1,2,3,4},16],FromDigits[\"abc\",16],"
            "ChineseRemainder[{2,3,2},{3,5,7}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "exact residue sequences and Gaussian factors",
        (
            "expr",
            "evaluate",
            "--code",
            "{JacobiSymbol[1001,9907],KroneckerSymbol[-1,2],BernoulliB[10],"
            "EulerE[6],PrimitiveRoot[7],PrimitiveRoot[8],RamanujanTau[5],"
            "FactorInteger[5,GaussianIntegers->True],"
            "FactorInteger[3+4 I,GaussianIntegers->True]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "FromDigits exact diagnostic parity",
        (
            "expr",
            "evaluate",
            "--code",
            "FromDigits[\"g\",16]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ChineseRemainder exact diagnostic parity",
        (
            "expr",
            "evaluate",
            "--code",
            "ChineseRemainder[{0,1},{2,4}]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "sparse array result JSON metadata",
        (
            "expr",
            "evaluate",
            "--code",
            "SparseArray[{{2}->a,{1}->b},{3},z]",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "sparse construction properties and selection",
        (
            "expr",
            "evaluate",
            "--code",
            "{Normal[SparseArray[{{1,2}->a,{2,3}->b},{2,3}]], "
            "ArrayRules[SparseArray[{{0,1},{2,0}}]], "
            "SparseArray[{{1,2}->a},{2,3}][[1]], "
            "Extract[SparseArray[{{2,3}->b},{2,3}],{2,3}], "
            "SparseArray[{{1}->a},{3}][\"Density\"]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "sparse structural transformations",
        (
            "expr",
            "evaluate",
            "--code",
            "{ArrayReshape[SparseArray[{{2}->a,{5}->b},{6}],{2,3}], "
            "ArrayPad[SparseArray[{{2}->a},{3}],1], "
            "Transpose[SparseArray[{{1,2}->a,{2,1}->b},{2,3}]], "
            "Flatten[SparseArray[{{1,2}->a,{2,1}->b},{2,3}]], "
            "ArrayFlatten[{{SparseArray[{{1,1}->a},{2,2}],{{b},{c}}}}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "sparse arithmetic and dot products",
        (
            "expr",
            "evaluate",
            "--code",
            "{SparseArray[{{1,2}->a},{2,3}] + "
            "SparseArray[{{2,3}->b},{2,3}], "
            "2 SparseArray[{{1}->a},{3}] + 1, "
            "z + SparseArray[{{1}->b},{2}], "
            "Dot[SparseArray[{{1}->a,{3}->c},{3}],"
            "SparseArray[{{1}->b,{2}->d},{3}]], "
            "Dot[SparseArray[{{1,2}->a},{2,3}],"
            "SparseArray[{{2,1}->b},{3,2}]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "huge sparse dimensions remain compact",
        (
            "expr",
            "evaluate",
            "--code",
            "{Part[SparseArray[{{1}->a},{1000000000}],1000000000], "
            "ArrayPad[SparseArray[{{1000000000}->a},{1000000000}],{2,3}], "
            "Flatten[SparseArray[{{1,1}->a},{1000000000,1000000000}]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "canonical interval construction and set operations",
        (
            "expr",
            "evaluate",
            "--code",
            "{Interval[], Interval[3], Interval[{3,1}], "
            "Interval[{1,3},{2,5}], Interval[{3,4},{1,2}], "
            "Interval[{-Infinity,0},{0,Infinity}], "
            "IntervalUnion[], "
            "IntervalUnion[Interval[{1,2}],Interval[{2,4}]], "
            "IntervalIntersection[], "
            "IntervalIntersection[Interval[{1,2},{4,5}],Interval[{2,4}]]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "interval scalar vector and subinterval membership",
        (
            "expr",
            "evaluate",
            "--code",
            "{IntervalMemberQ[Interval[{1,3}],2], "
            "IntervalMemberQ[Interval[{1,3}],{1,4}], "
            "IntervalMemberQ[Interval[{1,3}],Interval[{2,3}]], "
            "IntervalMemberQ[Interval[{1,3}],Interval[{0,2}]], "
            "IntervalMemberQ[Interval[],Interval[]], "
            "IntervalMemberQ[Interval[{1,3}],x], IntervalMemberQ[x,1]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "symbolic malformed and qualified intervals",
        (
            "expr",
            "evaluate",
            "--code",
            "{Interval[{a,b}], IntervalMemberQ[Interval[{1,3}]], "
            "System`Interval[{3,1}], "
            "System`IntervalMemberQ[Interval[{1,3}],2]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "collection statistics and vector norms",
        (
            "expr",
            "evaluate",
            "--code",
            "{Variance[{1,2,3,4,5}], StandardDeviation[{1,2,3,4,5}], "
            "Norm[{3,4}], Norm[{1,2,3},2], "
            "Norm[{1,-2,3},Infinity], Norm[{}]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ranked extrema modes and distinct counts",
        (
            "expr",
            "evaluate",
            "--code",
            "{MinMax[{3,1,4,1,5}], MinMax[{}], "
            "RankedMin[{3,1,4,1,5},2], RankedMax[{3,1,4,1,5},2], "
            "RankedMin[{3,1,4,1},-1], Mode[{3,1,3,2,1}], Mode[{}], "
            "CountDistinct[{a,b,a,c,b}], CountDistinct[<|a->1,b->2,c->1|>]}",
            "--form",
            "input",
        ),
        0,
    ),
    (
        "ratios subdivision and recoverable diagnostics",
        (
            "expr",
            "evaluate",
            "--code",
            "{Ratios[{2,6,3,12}], Ratios[{a,b,c}], Subdivide[4], "
            "Subdivide[10,4], Subdivide[1,10,4], Subdivide[x,4], "
            "Variance[{1}], Norm[x], RankedMin[{1},0], Subdivide[0]}",
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
