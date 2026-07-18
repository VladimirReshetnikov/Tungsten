#!/usr/bin/env python3
"""Compare native evaluation with literal expectations in the Python tests.

This migration-only tool extracts standalone ``_full("...")`` assertions,
direct ``evaluate(parse_*()).to_full_form()`` assertions, and literal
``{source: expected}`` mappings consumed by evaluator assertion loops.
Stateful setup code, computed expected values, message assertions, and side
effects need dedicated native tests and are intentionally outside this quick
differential sample.
"""

from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path
import subprocess
import sys


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", type=Path, default=Path("tests"))
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        "--rust-binary",
        dest="native_binary",
        type=Path,
        default=Path("build/cpp/tungsten-cpp"),
    )
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=50)
    parser.add_argument(
        "--require-perfect",
        action="store_true",
        help="Return nonzero when any extracted comparison differs",
    )
    return parser.parse_args()


def _test_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(path.glob("test_*.py"))


def _literal_string(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _source_from_actual(node: ast.AST) -> str | None:
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id == "_full" and node.args:
            return _literal_string(node.args[0])

    if not (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "to_full_form"
        and isinstance(node.func.value, ast.Call)
        and isinstance(node.func.value.func, ast.Name)
        and node.func.value.func.id == "evaluate"
        and node.func.value.args
    ):
        return None
    parsed = node.func.value.args[0]
    if not (
        isinstance(parsed, ast.Call)
        and isinstance(parsed.func, ast.Name)
        and parsed.func.id in {"parse_input_form", "parse_expression"}
        and parsed.args
    ):
        return None
    return _literal_string(parsed.args[0])


def _source_from_evaluation(node: ast.AST) -> str | None:
    """Extract the literal source from ``evaluate(parse_*("..."))``."""
    if not (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "evaluate"
        and node.args
    ):
        return None
    parsed = node.args[0]
    if not (
        isinstance(parsed, ast.Call)
        and isinstance(parsed.func, ast.Name)
        and parsed.func.id in {"parse_input_form", "parse_expression"}
        and parsed.args
    ):
        return None
    return _literal_string(parsed.args[0])


def _assigned_actual_name(node: ast.AST) -> str | None:
    if not (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "to_full_form"
        and isinstance(node.func.value, ast.Name)
    ):
        return None
    return node.func.value.id


def _literal_string_mapping(node: ast.AST) -> list[tuple[str, str, int]] | None:
    if not isinstance(node, ast.Dict):
        return None
    cases: list[tuple[str, str, int]] = []
    for key, value in zip(node.keys, node.values, strict=True):
        source = _literal_string(key) if key is not None else None
        expected = _literal_string(value)
        if source is None or expected is None:
            return None
        cases.append((source, expected, getattr(key, "lineno", node.lineno)))
    return cases


def _loop_consumes_evaluator_mapping(
    loop: ast.For, source_name: str, expected_name: str
) -> bool:
    body = ast.Module(body=loop.body, type_ignores=[])
    nodes = list(ast.walk(body))
    evaluates_source = any(
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id in {"evaluate", "_full"}
        and any(
            isinstance(child, ast.Name) and child.id == source_name
            for child in ast.walk(node)
        )
        for node in nodes
    )
    asserts_expected = any(
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "assertEqual"
        and any(
            isinstance(argument, ast.Name) and argument.id == expected_name
            for argument in node.args
        )
        for node in nodes
    )
    return evaluates_source and asserts_expected


def _literal_mapping_cases(tree: ast.AST) -> list[tuple[str, str, int]]:
    mappings: dict[str, list[tuple[int, list[tuple[str, str, int]]]]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)) or node.value is None:
            continue
        cases = _literal_string_mapping(node.value)
        if cases is None:
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        for target in targets:
            if isinstance(target, ast.Name):
                mappings.setdefault(target.id, []).append((node.lineno, cases))

    result: list[tuple[str, str, int]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.For):
            continue
        if not (
            isinstance(node.target, (ast.Tuple, ast.List))
            and len(node.target.elts) == 2
            and all(isinstance(item, ast.Name) for item in node.target.elts)
            and isinstance(node.iter, ast.Call)
            and isinstance(node.iter.func, ast.Attribute)
            and node.iter.func.attr == "items"
            and isinstance(node.iter.func.value, ast.Name)
        ):
            continue
        source_name = node.target.elts[0].id
        expected_name = node.target.elts[1].id
        if not _loop_consumes_evaluator_mapping(node, source_name, expected_name):
            continue
        candidates = [
            entry
            for entry in mappings.get(node.iter.func.value.id, [])
            if entry[0] < node.lineno
        ]
        if candidates:
            result.extend(max(candidates, key=lambda entry: entry[0])[1])
    return result


def _cases(path: Path) -> list[tuple[str, str, Path, int]]:
    cases: list[tuple[str, str, Path, int]] = []
    seen: set[tuple[str, str]] = set()
    for test_file in _test_files(path):
        tree = ast.parse(test_file.read_text(encoding="utf-8"), filename=str(test_file))
        assignments: dict[str, list[tuple[int, str]]] = {}
        for node in ast.walk(tree):
            if not isinstance(node, (ast.Assign, ast.AnnAssign)):
                continue
            value = node.value
            if value is None:
                continue
            source = _source_from_evaluation(value)
            if source is None:
                continue
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    assignments.setdefault(target.id, []).append((node.lineno, source))
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "assertEqual"
                and len(node.args) >= 2
            ):
                continue
            source = _source_from_actual(node.args[0])
            if source is None:
                assigned_name = _assigned_actual_name(node.args[0])
                if assigned_name is not None:
                    candidates = [
                        (line, assigned_source)
                        for line, assigned_source in assignments.get(assigned_name, [])
                        if line < node.lineno
                    ]
                    if candidates:
                        source = max(candidates)[1]
            expected = _literal_string(node.args[1])
            if source is None or expected is None or (source, expected) in seen:
                continue
            seen.add((source, expected))
            cases.append((source, expected, test_file, node.lineno))
        for source, expected, line in _literal_mapping_cases(tree):
            if (source, expected) in seen:
                continue
            seen.add((source, expected))
            cases.append((source, expected, test_file, line))
    return cases


def main() -> int:
    args = _arguments()
    if not args.no_build:
        subprocess.run(
            ["cmake", "--build", "build/cpp", "--target", "tungsten-cpp", "--parallel"],
            check=True,
        )

    cases = _cases(args.tests)
    request = "".join(json.dumps(source) + "\n" for source, *_rest in cases)
    native = subprocess.run(
        [str(args.native_binary), "eval-batch"],
        input=request,
        check=False,
        capture_output=True,
        text=True,
    )
    if native.returncode != 0:
        print(native.stderr, file=sys.stderr)
        return native.returncode
    responses = native.stdout.splitlines()
    if len(responses) != len(cases):
        print(
            f"Native batch evaluator returned {len(responses)} results for {len(cases)} cases.",
            file=sys.stderr,
        )
        return 2

    mismatches: list[str] = []
    for (source, expected, test_file, line), response in zip(cases, responses, strict=True):
        payload = json.loads(response)
        actual = payload.get("full_form") if payload.get("success") else f"ERROR: {payload.get('error', '')}"
        if actual != expected:
            mismatches.append(
                f"{test_file}:{line}: {source!r}\n  expected: {expected}\n  C++:      {actual}"
            )

    passed = len(cases) - len(mismatches)
    print(
        f"Matched {passed}/{len(cases)} extracted evaluator expectations; "
        f"{len(mismatches)} mismatches."
    )
    if mismatches and args.max_mismatches != 0:
        shown = mismatches[: args.max_mismatches]
        print("\n\n".join(shown))
        if len(shown) < len(mismatches):
            print(f"\n... {len(mismatches) - len(shown)} additional mismatches omitted")
    return int(args.require_perfect and bool(mismatches))


if __name__ == "__main__":
    sys.exit(main())
