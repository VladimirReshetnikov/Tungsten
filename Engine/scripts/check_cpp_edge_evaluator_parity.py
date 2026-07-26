#!/usr/bin/env python3
"""Differentially exercise native evaluator edges beyond the recorded tests.

The recorded-test gate proves compatibility for calls that the Python unittest
suite happens to make.  This companion gate generates dense, deterministic
cross-products around sequence boundaries, selector direction, inexact
rounding, structural positions, and Unicode/string-pattern behavior.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import itertools
import json
from pathlib import Path
import subprocess
from typing import Callable, Iterable

import tungsten.expression as runtime
from tungsten.expression_parser import parse_input_form


ENGINE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE_BINARY = ENGINE_ROOT / "build" / "cpp" / "tungsten-cpp"


@dataclass(frozen=True)
class Expected:
    success: bool
    full_form: str | None
    messages: tuple[str, ...]
    message_texts: tuple[str, ...]
    prints: tuple[str, ...]


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        dest="native_binary",
        type=Path,
        default=DEFAULT_NATIVE_BINARY,
    )
    parser.add_argument(
        "--cluster",
        action="append",
        choices=("rounding", "take-drop", "list", "structural", "strings"),
        help="Run only this matrix; repeat to select multiple matrices.",
    )
    parser.add_argument("--max-mismatches", type=int, default=50)
    parser.add_argument("--require-perfect", action="store_true")
    return parser.parse_args()


def _unique(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(values))


def rounding_cases() -> list[str]:
    numbers = [
        "-3", "-2", "-1", "0", "1", "2", "3", "-2.5", "-1.5",
        "-.2", ".2", "1.5", "2.5", "3.7",
    ]
    cases: list[str] = []
    for head in ("Floor", "Ceiling", "Round", "IntegerPart", "FractionalPart", "Abs", "Sign"):
        cases.extend(f"{head}[{value}]" for value in numbers)
    for head in ("Floor", "Ceiling", "Round"):
        cases.extend(
            f"{head}[{value},{unit}]"
            for value, unit in itertools.product(
                numbers, ("-2", "-1", "-.5", ".2", ".5", "1", "2")
            )
        )
    for head in ("Mod", "Quotient", "QuotientRemainder"):
        cases.extend(
            f"{head}[{left},{right}]"
            for left, right in itertools.product(
                numbers[:8], ("-3", "-2", "-1", "1", "2", "3")
            )
        )
    for head in ("RotateLeft", "RotateRight"):
        cases.extend(
            f"{head}[{{a,b,c}},{amount}]"
            for amount in (-10, -4, -3, -2, -1, 0, 1, 2, 3, 4, 10)
        )
    for head in ("Take", "Drop"):
        cases.extend(
            f"{head}[{{a,b,c}},{amount}]"
            for amount in (-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5)
        )
    for head in ("RankedMin", "RankedMax"):
        cases.extend(
            f"{head}[{{3,1,2}},{rank}]"
            for rank in (-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5)
        )
    for head in ("NumericalSort", "AlphabeticSort"):
        cases.extend(
            f"{head}[{values}]"
            for values in (
                '{"x02","x2","x10","x1"}',
                '{"A2","a10","a1"}',
                '{2,"x1",1}',
            )
        )
    cases.extend(
        (
            "Floor[1.*^100]",
            "Ceiling[-1.*^100]",
            "Round[1.*^100]",
            "IntegerPart[-1.*^100]",
            'NumericalSort[{"x9999999999999999999999999999999999999999999","x2","x10"}]',
            "RotateLeft[{a,b,c},999999999999999999999999999999999999999]",
            "RotateRight[{a,b,c},999999999999999999999999999999999999999]",
        )
    )
    return _unique(cases)


def take_drop_cases() -> list[str]:
    sequences = (
        "{a,b,c}",
        "f[a,b,c]",
        "{}",
        "Association[a->1,b->2,c->3]",
    )
    specifications: list[str] = [str(value) for value in range(-5, 6)]
    specifications.append("All")
    specifications.extend(f"{{{value}}}" for value in range(-5, 6))
    specifications.extend(
        f"{{{first},{last}}}"
        for first, last in itertools.product(range(-4, 5), repeat=2)
    )
    specifications.extend(
        f"{{{first},{last},{step}}}"
        for first, last, step in itertools.product(
            range(-3, 4), range(-3, 4), (-2, -1, 1, 2)
        )
    )
    specifications.extend(f"UpTo[{value}]" for value in range(-2, 6))
    return [
        f"{head}[{sequence},{specification}]"
        for head, sequence, specification in itertools.product(
            ("Take", "Drop"), sequences, specifications
        )
    ]


def list_cases() -> list[str]:
    sequences = ("{a,b,c}", "f[a,b,c]", "{}", "Association[a->1,b->2,c->3]")
    cases: list[str] = []
    for head in ("First", "Last"):
        for value in (*sequences, "a"):
            cases.extend((f"{head}[{value}]", f"{head}[{value},z]"))
    for head in ("Rest", "Most"):
        cases.extend(f"{head}[{value}]" for value in (*sequences, "a"))
    for head in ("Append", "Prepend"):
        cases.extend(
            f"{head}[{value},{item}]"
            for value, item in itertools.product(
                (*sequences, "a"), ("x", "Sequence[x,y]", "Nothing")
            )
        )
    cases.extend(
        f"Join[{left},{right}]"
        for left, right in itertools.product(sequences, repeat=2)
    )
    for value in sequences:
        cases.append(f"Reverse[{value}]")
        cases.extend(
            f"Reverse[{value},{specification}]"
            for specification in ("0", "1", "2", "All", "{1}", "{1,2}")
        )
    for value in sequences[:3]:
        for separator in ("x", "{x,y}", "Sequence[x,y]"):
            cases.extend(
                (
                    f"Riffle[{value},{separator}]",
                    f"Riffle[{value},{separator},{{1,-1,2}}]",
                )
            )
    for value in sequences[:3]:
        cases.extend(f"Partition[{value},{width}]" for width in range(-1, 6))
        cases.extend(
            f"Partition[{value},{width},{step}]"
            for width, step in itertools.product(range(0, 5), repeat=2)
        )
    for head in ("PadLeft", "PadRight"):
        for value in sequences[:3]:
            cases.extend(f"{head}[{value},{width}]" for width in range(-1, 7))
            cases.extend(
                f"{head}[{value},{width},{padding}]"
                for width, padding in itertools.product(range(0, 6), ("x", "{x,y}"))
            )
    cases.extend(("GatherBy[{1,2,3}]", "Permute[{},{}]"))
    return _unique(cases)


def structural_cases() -> list[str]:
    sequences = ("{a,b,c}", "f[a,b,c]", "{}", "Association[a->1,b->2,c->3]")
    positions = (
        "-5", "-4", "-3", "-2", "-1", "0", "1", "2", "3", "4", "5",
        "{1}", "{-1}", "{0}", "{{1},{3}}", "All", "Span[1,2]",
    )
    cases: list[str] = []
    for head in ("Part", "Extract"):
        cases.extend(
            f"{head}[{value},{position}]"
            for value, position in itertools.product(sequences, positions)
        )
    for head in ("Delete", "Insert"):
        for value, position in itertools.product(sequences, positions):
            cases.append(
                f"Delete[{value},{position}]"
                if head == "Delete"
                else f"Insert[{value},z,{position}]"
            )
    cases.extend(
        f"ReplacePart[{value},{position}->z]"
        for value, position in itertools.product(sequences, positions)
    )
    for value in sequences:
        for pattern in ("a", "_Symbol", "_Integer", "x_ /; x===b"):
            cases.extend(
                (
                    f"DeleteCases[{value},{pattern}]",
                    f"DeleteCases[{value},{pattern},{{0,Infinity}}]",
                    f"Replace[{value},{pattern}->z,{{0,Infinity}}]",
                )
            )
    return _unique(cases)


def string_cases() -> list[str]:
    strings = ('""', '"a"', '"ab"', '"aba"', '"a b"', '"café λ"')
    patterns = (
        '"a"', '""', 'Alternatives["a","b"]', 'Repeated["a"]',
        "DigitCharacter", "LetterCharacter", "__",
    )
    cases: list[str] = []
    for head in (
        "StringLength", "Characters", "StringReverse", "ToUpperCase", "ToLowerCase",
        "LetterQ", "DigitQ",
    ):
        cases.extend(f"{head}[{value}]" for value in strings)
    cases.extend(
        f"CharacterRange[{left},{right}]"
        for left, right in itertools.product(('"a"', '"c"', '"A"', '"1"'), repeat=2)
    )
    for head in (
        "StringContainsQ", "StringFreeQ", "StringStartsQ", "StringEndsQ",
        "StringMatchQ", "StringPosition", "StringCases",
    ):
        for value, pattern in itertools.product(strings, patterns):
            cases.append(f"{head}[{value},{pattern}]")
            if head in ("StringPosition", "StringCases"):
                cases.append(f"{head}[{value},{pattern},2]")
    for value, pattern, replacement in itertools.product(
        strings, patterns[:4], ('"x"', 'f["x"]')
    ):
        cases.extend(
            (
                f"StringReplace[{value},{pattern}->{replacement}]",
                f"StringReplace[{value},{pattern}->{replacement},2]",
            )
        )
    for value in strings:
        cases.extend(
            f"StringSplit[{value},{separator}]"
            for separator in ("Whitespace", '"a"', '""')
        )
        for position in ("1", "-1", "0", "{1}", "{1,2}", "{{1},{-1}}"):
            cases.extend(
                (
                    f"StringTake[{value},{position}]",
                    f"StringDrop[{value},{position}]",
                )
            )
    cases.extend(
        (
            'StringJoin["a","b"]',
            'StringJoin["","a"]',
            'StringJoin["café","λ"]',
        )
    )
    return _unique(cases)


CLUSTERS: dict[str, Callable[[], list[str]]] = {
    "rounding": rounding_cases,
    "take-drop": take_drop_cases,
    "list": list_cases,
    "structural": structural_cases,
    "strings": string_cases,
}


def _clear_visible_effects() -> None:
    runtime._GLOBAL_MESSAGES.clear()
    runtime._GLOBAL_VISIBLE_MESSAGES.clear()
    runtime._GLOBAL_PRINTS.clear()


def _expected(source: str) -> Expected:
    _clear_visible_effects()
    try:
        result = runtime.evaluate(parse_input_form(source))
        success = True
        full_form = result.to_full_form()
    except Exception:
        success = False
        full_form = None
    return Expected(
        success=success,
        full_form=full_form,
        messages=tuple(
            message.name.to_full_form() for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        message_texts=tuple(
            message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        prints=tuple(runtime._GLOBAL_PRINTS),
    )


def _native(binary: Path, sources: list[str]) -> list[dict[str, object]]:
    completed = subprocess.run(
        [str(binary), "eval-batch"],
        input="".join(json.dumps(source) + "\n" for source in sources),
        text=True,
        capture_output=True,
        check=False,
        timeout=120,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"native batch exited {completed.returncode}: "
            f"{completed.stderr.strip() or '<no stderr>'}"
        )
    payloads = [json.loads(line) for line in completed.stdout.splitlines()]
    if len(payloads) != len(sources):
        raise RuntimeError(
            f"native evaluator returned {len(payloads)} results for {len(sources)} cases"
        )
    return payloads


def _matches(expected: Expected, actual: dict[str, object]) -> bool:
    if bool(actual.get("success")) != expected.success:
        return False
    if expected.success and actual.get("full_form") != expected.full_form:
        return False
    return (
        tuple(actual.get("messages", [])) == expected.messages
        and tuple(actual.get("message_texts", [])) == expected.message_texts
        and tuple(actual.get("prints", [])) == expected.prints
    )


def main() -> int:
    arguments = _arguments()
    selected = arguments.cluster or list(CLUSTERS)
    binary = arguments.native_binary.resolve()
    if not binary.is_file():
        raise RuntimeError(f"native binary does not exist: {binary}")

    cases: list[tuple[str, str]] = []
    for cluster in selected:
        cases.extend((cluster, source) for source in CLUSTERS[cluster]())
    expectations = [_expected(source) for _cluster, source in cases]
    payloads = _native(binary, [source for _cluster, source in cases])

    mismatches: list[str] = []
    mismatch_clusters: Counter[str] = Counter()
    for (cluster, source), expected, actual in zip(
        cases, expectations, payloads, strict=True
    ):
        if _matches(expected, actual):
            continue
        mismatch_clusters[cluster] += 1
        expected_value = expected.full_form if expected.success else "<failure>"
        actual_value = actual.get("full_form") if actual.get("success") else "<failure>"
        mismatches.append(
            f"[{cluster}] {source}\n"
            f"  Python: {expected_value}; messages={expected.messages!r}; "
            f"texts={expected.message_texts!r}; prints={expected.prints!r}\n"
            f"  C++:    {actual_value}; messages={actual.get('messages', [])!r}; "
            f"texts={actual.get('message_texts', [])!r}; prints={actual.get('prints', [])!r}"
        )

    print(
        f"Matched {len(cases) - len(mismatches)}/{len(cases)} generated edge cases; "
        f"{len(mismatches)} mismatches."
    )
    for cluster in selected:
        count = sum(1 for case_cluster, _source in cases if case_cluster == cluster)
        failures = mismatch_clusters[cluster]
        print(f"  {cluster}: {count - failures}/{count}")
    if mismatches and arguments.max_mismatches != 0:
        shown = mismatches[: arguments.max_mismatches]
        print("\n\n".join(shown))
        if len(shown) < len(mismatches):
            print(f"\n... {len(mismatches) - len(shown)} additional mismatches omitted")
    return int(arguments.require_perfect and bool(mismatches))


if __name__ == "__main__":
    raise SystemExit(main())
