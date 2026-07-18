#!/usr/bin/env python3
"""Compare stateful native C++ evaluation with the Python reference engine."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


SCENARIOS: dict[str, list[str]] = {
    "symbol_registry": [
        'Symbol["TungstenStateRegistry`alpha"]',
        'Symbol["TungstenStateRegistry`beta"]',
        'Contexts["TungstenStateRegistry`*"]',
        'Names["TungstenStateRegistry`*"]',
        'NameQ["TungstenStateRegistry`alpha"]',
        'NameQ["TungstenStateRegistry`*"]',
    ],
    "definitions_and_return": [
        "TungstenStateF[x_] := If[x > 10, Return[big], x]",
        "TungstenStateF[5]",
        "TungstenStateF[20]",
        "TungstenStateG[x_] := Which[x > 0, Return[positive], x < 0, Return[negative], True, zero]",
        "TungstenStateG[5]",
        "TungstenStateG[-3]",
        "TungstenStateG[0]",
    ],
    "recursive_memoization": [
        "TungstenStateFib[0] = 0",
        "TungstenStateFib[1] = 1",
        "TungstenStateFib[n_Integer] := TungstenStateFib[n] = TungstenStateFib[n - 1] + TungstenStateFib[n - 2]",
        "TungstenStateFib[10]",
        "TungstenStateFib[20]",
        "TungstenStateFib[10]",
    ],
    "block_and_attributes": [
        "TungstenStateA = 100",
        "TungstenStateSquare[x_] := x^2",
        "Block[{TungstenStateA = 5}, TungstenStateA + TungstenStateSquare[3]]",
        "TungstenStateA",
        "SetAttributes[TungstenStateHeld, HoldAll]",
        "TungstenStateHeld[1 + 2, Evaluate[3 + 4]]",
        "ClearAttributes[TungstenStateHeld, HoldAll]",
        "TungstenStateHeld[1 + 2]",
    ],
    "iteration_state": [
        "TungstenStateX = 100",
        "Table[TungstenStateX + i, {i, 1, 3}]",
        "Sum[TungstenStateX + i, {i, 1, 3}]",
        "Product[i, {i, 1, 6}]",
        "TungstenStateTotal = 0",
        "Do[TungstenStateTotal = TungstenStateTotal + i, {i, 1, 5}]",
        "TungstenStateTotal",
    ],
    "tagged_definitions": [
        "TungstenStateTag /: TungstenStateH[TungstenStateTag[x_]] := x + 10",
        "TungstenStateH[TungstenStateTag[2]]",
        "UpValues[TungstenStateTag]",
        "TungstenStateTag /: TungstenStateH[TungstenStateTag[x_]] =.",
        "TungstenStateH[TungstenStateTag[2]]",
    ],
    "system_limits": [
        "$MaxExtraPrecision",
        "$MaxExtraPrecision = 12",
        "$MaxExtraPrecision = -1",
        "$MaxExtraPrecision",
        "$MaxRootDegree",
        "$MaxRootDegree = 3",
        "Root[#^4 - 2 &, 1]",
        "Root[#^2 - 2^(1/3) &, 2]",
        "$MaxRootDegree = Infinity",
        "$MaxRootDegree",
    ],
    "message_surface": [
        "Part[{a, b}, 9]",
        "Pick[{a, b}, {True}]",
        "Part[<|a -> 1, b -> 2|>, {1, Key[b]}]",
        "Function[Null, f[#1, #2], Listable][{a, b}, {c, d, e}]",
        'StringCases["abc", Optional["a"] ~~ "b"]',
    ],
    "print_surface": [
        'Print["a", 1 + 2, x]',
        "Print[InputForm[{1, 2/3, a + b}]]",
        "Print[FullForm[{1, 2/3, a + b}]]",
        "Do[Print[i], {i, 3}]",
        'Print["before"]; 2 + 3; Print[TeXForm[x^2]]',
    ],
    "message_control": [
        "Check[Part[f[a], 2], fallback]",
        "Check[Part[f[a], 2], fallback, Other::error]",
        "Check[Part[f[a], 2], $MessageList]",
        "Quiet[Part[f[a], 2]]",
        "Check[Quiet[Part[f[a], 2]], fallback]",
        "Quiet[Check[Part[f[a], 2], fallback]]",
        "Off[f::tag]",
        "Check[Message[f::tag], fallback]",
        "On[f::tag]",
        "Check[Message[f::tag], fallback]",
        "$MessagePrePrint = FullForm",
        "Message[f::formatted, {1 + 2}]",
        "$MessagePrePrint = Automatic",
        "On[Assert]",
        "Assert[True]",
        "Check[Assert[False, tag], msg]",
        "Off[Assert]",
        'Assert[Print["not evaluated"]; False]',
        'WithCleanup[1 + 2, Print["cleanup"]]',
        'CheckAbort[WithCleanup[Print["expr1"]; Abort[]; Print["expr2"], Print["cleanup"]], caught]',
        "TungstenStateAppend = {a}",
        "AppendTo[TungstenStateAppend, b]",
        "TungstenStateAppend",
    ],
}


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        "--rust-binary",
        dest="native_binary",
        type=Path,
        default=Path("build/cpp/tungsten-cpp"),
    )
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument(
        "--scenario",
        action="append",
        choices=sorted(SCENARIOS),
        help="Run only the named scenario; repeat to select more than one.",
    )
    parser.add_argument("--max-mismatches", type=int, default=50)
    parser.add_argument("--require-perfect", action="store_true")
    return parser.parse_args()


_PYTHON_ORACLE = r"""
import json
import sys
import tungsten.expression as runtime
from tungsten.expression import evaluate
from tungsten.expression_parser import parse_input_form

sources = json.load(sys.stdin)
results = []
for source in sources:
    try:
        value = evaluate(parse_input_form(source))
        results.append({
            "success": True,
            "full_form": value.to_full_form(),
            "messages": [message.name.to_full_form() for message in runtime._GLOBAL_VISIBLE_MESSAGES],
            "message_texts": [message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES],
            "prints": list(runtime._GLOBAL_PRINTS),
        })
    except Exception as error:
        results.append({
            "success": False,
            "error": f"{type(error).__name__}: {error}",
            "messages": [message.name.to_full_form() for message in runtime._GLOBAL_VISIBLE_MESSAGES],
            "message_texts": [message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES],
            "prints": list(runtime._GLOBAL_PRINTS),
        })
json.dump(results, sys.stdout)
"""


def _python_results(sources: list[str]) -> list[dict[str, object]]:
    completed = subprocess.run(
        [sys.executable, "-c", _PYTHON_ORACLE],
        input=json.dumps(sources),
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "Python oracle failed.")
    result = json.loads(completed.stdout)
    if not isinstance(result, list):
        raise RuntimeError("Python oracle returned a non-list payload.")
    return result


def _native_results(binary: Path, sources: list[str]) -> list[dict[str, object]]:
    request = "".join(json.dumps(source) + "\n" for source in sources)
    completed = subprocess.run(
        [str(binary), "eval-batch", "--stateful"],
        input=request,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "Native evaluator failed.")
    result = [json.loads(line) for line in completed.stdout.splitlines()]
    if len(result) != len(sources):
        raise RuntimeError(
            f"Native evaluator returned {len(result)} results for {len(sources)} expressions."
        )
    return result


def _display(payload: dict[str, object]) -> str:
    if payload.get("success"):
        value = str(payload.get("full_form"))
    else:
        value = f"ERROR: {payload.get('error', '')}"
    messages = payload.get("messages", [])
    message_texts = payload.get("message_texts", [])
    prints = payload.get("prints", [])
    return (
        f"{value}; messages={json.dumps(messages, ensure_ascii=False)}; "
        f"message_texts={json.dumps(message_texts, ensure_ascii=False)}; "
        f"prints={json.dumps(prints, ensure_ascii=False)}"
    )


def main() -> int:
    args = _arguments()
    if not args.no_build:
        subprocess.run(
            ["cmake", "--build", "build/cpp", "--target", "tungsten-cpp", "--parallel"],
            check=True,
        )

    selected = args.scenario or list(SCENARIOS)
    comparisons = 0
    mismatches: list[str] = []
    for scenario in selected:
        sources = SCENARIOS[scenario]
        python = _python_results(sources)
        native = _native_results(args.native_binary, sources)
        for index, (source, expected, actual) in enumerate(
            zip(sources, python, native, strict=True),
            start=1,
        ):
            comparisons += 1
            if _display(expected) != _display(actual):
                mismatches.append(
                    f"{scenario}:{index}: {source!r}\n"
                    f"  Python: {_display(expected)}\n"
                    f"  C++:    {_display(actual)}"
                )

    print(
        f"Matched {comparisons - len(mismatches)}/{comparisons} stateful evaluator steps "
        f"across {len(selected)} scenarios; {len(mismatches)} mismatches."
    )
    if mismatches and args.max_mismatches != 0:
        shown = mismatches[: args.max_mismatches]
        print("\n\n".join(shown))
        if len(shown) < len(mismatches):
            print(f"\n... {len(mismatches) - len(shown)} additional mismatches omitted")
    return int(args.require_perfect and bool(mismatches))


if __name__ == "__main__":
    sys.exit(main())
