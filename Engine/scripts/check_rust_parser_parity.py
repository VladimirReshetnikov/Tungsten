#!/usr/bin/env python3
"""Differentially check the native C++ parser against Python test inputs.

This is migration-only development tooling. The native engine never invokes
Python at runtime; this script deliberately treats the existing Python
implementation as an executable specification while the port is under
construction.
"""

from __future__ import annotations

import argparse
import ast
from pathlib import Path
import subprocess
import sys
from typing import Callable

from tungsten.expression import Expr
from tungsten.expression import parse_full_form
from tungsten.expression import parse_input_form
from tungsten.expression import parse_standard_form


Parser = Callable[[str], Expr]
PARSERS: dict[str, tuple[Parser, str]] = {
    "parse_input_form": (parse_input_form, "input"),
    "parse_full_form": (parse_full_form, "full"),
    "parse_standard_form": (parse_standard_form, "standard"),
}


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tests",
        type=Path,
        default=Path("tests"),
        help="Python test file or directory to scan (default: tests)",
    )
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        "--rust-binary",
        dest="native_binary",
        type=Path,
        default=Path("build/cpp/tungsten-cpp"),
        help="Path to the native Tungsten CLI",
    )
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="Do not build tungsten-cpp before running comparisons",
    )
    return parser.parse_args()


def _test_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(path.glob("test_*.py"))


def _literal_cases(path: Path) -> list[tuple[str, str, Path, int]]:
    cases: list[tuple[str, str, Path, int]] = []
    seen: set[tuple[str, str]] = set()
    for test_file in _test_files(path):
        tree = ast.parse(test_file.read_text(encoding="utf-8"), filename=str(test_file))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                continue
            if node.func.id not in PARSERS or not node.args:
                continue
            source_node = node.args[0]
            if not isinstance(source_node, ast.Constant) or not isinstance(source_node.value, str):
                continue
            key = (node.func.id, source_node.value)
            if key in seen:
                continue
            seen.add(key)
            cases.append((node.func.id, source_node.value, test_file, node.lineno))
    return cases


def _native_parse(binary: Path, source: str, form: str, output: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(binary),
            "parse",
            "--form",
            form,
            "--code",
            source,
            f"--{output}-form",
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> int:
    args = _arguments()
    if not args.no_build:
        subprocess.run(
            ["cmake", "--build", "build/cpp", "--target", "tungsten-cpp", "--parallel"],
            check=True,
        )

    cases = _literal_cases(args.tests)
    mismatches: list[str] = []
    shared_rejections = 0
    for parser_name, source, test_file, line in cases:
        python_parser, form = PARSERS[parser_name]
        try:
            python_expr = python_parser(source)
        except Exception as python_error:  # parity includes syntax rejection
            native = _native_parse(args.native_binary, source, form, "full")
            if native.returncode != 0:
                shared_rejections += 1
                continue
            mismatches.append(
                f"{test_file}:{line}: Python rejected {source!r} with {python_error!r}, "
                f"native C++ accepted it as {native.stdout.strip()!r}"
            )
            continue

        for output, expected in (
            ("full", python_expr.to_full_form()),
            ("input", python_expr.to_input_form()),
        ):
            native = _native_parse(args.native_binary, source, form, output)
            actual = (
                native.stdout.strip()
                if native.returncode == 0
                else f"ERROR: {native.stderr.strip()}"
            )
            if actual != expected:
                mismatches.append(
                    f"{test_file}:{line}: {parser_name}({source!r}) {output} form\n"
                    f"  Python: {expected}\n"
                    f"  C++:    {actual}"
                )

    print(
        f"Compared {len(cases)} unique literal parser calls; "
        f"{shared_rejections} shared rejections; {len(mismatches)} mismatches."
    )
    if mismatches:
        print("\n\n".join(mismatches))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
