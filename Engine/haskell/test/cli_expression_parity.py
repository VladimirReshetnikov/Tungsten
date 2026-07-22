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
