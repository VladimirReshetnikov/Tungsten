#!/usr/bin/env python3
"""Differentially check the Haskell parser against Python test literals.

The Python implementation is the compatibility reference.  All Haskell
requests are sent to one JSON-lines protocol process so the full corpus can be
checked without paying process startup cost for every literal.
"""

from __future__ import annotations

import argparse
import ast
from collections import Counter
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Callable


ENGINE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE_ROOT / "src"))

from tungsten.expression import Expr  # noqa: E402
from tungsten.expression import parse_full_form  # noqa: E402
from tungsten.expression import parse_input_form  # noqa: E402
from tungsten.expression import parse_standard_form  # noqa: E402


Parser = Callable[[str], Expr]
PARSERS: dict[str, tuple[Parser, str]] = {
    "parse_input_form": (parse_input_form, "input"),
    "parse_full_form": (parse_full_form, "full"),
    "parse_standard_form": (parse_standard_form, "standard"),
}

# These are lower bounds, rather than exact counts, so adding parser cases does
# not require editing the gate.  They protect the established corpus and each
# source-form slice from silently shrinking when tests are reorganized.
MINIMUM_CASES = 1_414
MINIMUM_FORM_CASES = {
    "input": 1_396,
    "full": 4,
    "standard": 14,
}


class HarnessError(RuntimeError):
    """A parity run could not produce trustworthy comparison results."""


@dataclass(frozen=True)
class Case:
    parser_name: str
    form: str
    source: str
    test_file: Path
    line: int


@dataclass(frozen=True)
class Expected:
    accepted: bool
    full_form: str | None = None
    input_form: str | None = None
    error: str | None = None


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tests",
        type=Path,
        default=ENGINE_ROOT / "tests",
        help="Python test file or directory to scan (default: Engine/tests)",
    )
    parser.add_argument(
        "--haskell-binary",
        type=Path,
        help=(
            "Path to tungsten-hs. If omitted, resolve it with "
            "'cabal list-bin exe:tungsten-hs'."
        ),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=180.0,
        help="Seconds allowed for the batched protocol run (default: 180)",
    )
    parser.add_argument(
        "--max-mismatch-samples",
        type=int,
        default=20,
        help="Maximum mismatch samples to print; 0 suppresses them (default: 20)",
    )
    arguments = parser.parse_args()
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")
    if arguments.max_mismatch_samples < 0:
        parser.error("--max-mismatch-samples must be nonnegative")
    return arguments


def _test_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise HarnessError(f"test path does not exist: {path}")
    return sorted(path.glob("test_*.py"))


def _literal_cases(path: Path) -> list[Case]:
    cases: list[Case] = []
    seen: set[tuple[str, str]] = set()
    for test_file in _test_files(path):
        tree = ast.parse(
            test_file.read_text(encoding="utf-8"), filename=str(test_file)
        )
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                continue
            if node.func.id not in PARSERS or not node.args:
                continue
            source_node = node.args[0]
            if not isinstance(source_node, ast.Constant) or not isinstance(
                source_node.value, str
            ):
                continue
            key = (node.func.id, source_node.value)
            if key in seen:
                continue
            seen.add(key)
            _python_parser, form = PARSERS[node.func.id]
            cases.append(
                Case(
                    parser_name=node.func.id,
                    form=form,
                    source=source_node.value,
                    test_file=test_file,
                    line=node.lineno,
                )
            )
    return cases


def _guard_corpus(cases: list[Case]) -> Counter[str]:
    form_counts = Counter(case.form for case in cases)
    failures: list[str] = []
    if len(cases) < MINIMUM_CASES:
        failures.append(f"total {len(cases)} < {MINIMUM_CASES}")
    for form, minimum in MINIMUM_FORM_CASES.items():
        actual = form_counts[form]
        if actual < minimum:
            failures.append(f"{form} {actual} < {minimum}")
    if failures:
        raise HarnessError("parser corpus coverage shrank: " + "; ".join(failures))
    return form_counts


def _resolve_haskell_binary(explicit: Path | None) -> Path:
    if explicit is not None:
        binary = explicit.expanduser().resolve()
    else:
        try:
            completed = subprocess.run(
                ["cabal", "list-bin", "exe:tungsten-hs"],
                cwd=ENGINE_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError as error:
            raise HarnessError(
                "--haskell-binary was not supplied and cabal is unavailable"
            ) from error
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise HarnessError(
                "could not resolve tungsten-hs with cabal list-bin: "
                + (detail or f"exit {completed.returncode}")
            )
        output_lines = [
            line.strip()
            for line in completed.stdout.splitlines()
            if line.strip()
        ]
        if not output_lines:
            raise HarnessError("cabal list-bin returned no tungsten-hs path")
        binary = Path(output_lines[-1]).expanduser().resolve()

    if not binary.is_file():
        raise HarnessError(f"Haskell executable does not exist: {binary}")
    if not os.access(binary, os.X_OK):
        raise HarnessError(f"Haskell executable is not executable: {binary}")
    return binary


def _python_expectation(case: Case) -> Expected:
    parser, _form = PARSERS[case.parser_name]
    try:
        expression = parser(case.source)
    except Exception as error:  # syntax rejection is part of parser parity
        return Expected(
            accepted=False,
            error=f"{type(error).__name__}: {error}",
        )
    return Expected(
        accepted=True,
        full_form=expression.to_full_form(),
        input_form=expression.to_input_form(),
    )


def _haskell_results(
    binary: Path, cases: list[Case], timeout: float
) -> list[dict[str, object]]:
    requests = [
        {
            "id": index,
            "command": "parse",
            "form": case.form,
            "source": case.source,
        }
        for index, case in enumerate(cases)
    ]
    protocol_input = "".join(
        json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n"
        for request in requests
    )
    try:
        completed = subprocess.run(
            [str(binary), "protocol"],
            cwd=ENGINE_ROOT,
            input=protocol_input,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise HarnessError(
            f"Haskell protocol exceeded the {timeout:g}-second timeout"
        ) from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or "<no stderr>"
        raise HarnessError(
            f"Haskell protocol exited {completed.returncode}: {detail}"
        )

    response_lines = completed.stdout.splitlines()
    if len(response_lines) != len(cases):
        raise HarnessError(
            "Haskell protocol returned "
            f"{len(response_lines)} responses for {len(cases)} requests"
        )

    responses: list[dict[str, object]] = []
    for index, line in enumerate(response_lines):
        try:
            response = json.loads(line)
        except json.JSONDecodeError as error:
            raise HarnessError(
                f"Haskell protocol response {index} is not JSON: {error}"
            ) from error
        if not isinstance(response, dict):
            raise HarnessError(
                f"Haskell protocol response {index} is not an object"
            )
        if response.get("id") != index:
            raise HarnessError(
                "Haskell protocol response ID mismatch at position "
                f"{index}: {response.get('id')!r}"
            )
        responses.append(response)
    return responses


def _accepted_result(response: dict[str, object]) -> tuple[str, str] | None:
    if response.get("success") is not True:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        raise HarnessError("successful Haskell parse response has no result object")
    full_form = result.get("full_form")
    input_form = result.get("input_form")
    if not isinstance(full_form, str) or not isinstance(input_form, str):
        raise HarnessError(
            "successful Haskell parse response lacks textual full/input forms"
        )
    return full_form, input_form


def _preview(value: object, limit: int = 220) -> str:
    rendered = repr(value)
    if len(rendered) <= limit:
        return rendered
    return rendered[: limit - 3] + "..."


def _mismatch_sample(
    case: Case,
    expected: Expected,
    response: dict[str, object],
    actual_forms: tuple[str, str] | None,
) -> str:
    try:
        display_path = case.test_file.relative_to(ENGINE_ROOT)
    except ValueError:
        display_path = case.test_file
    location = f"{display_path}:{case.line} [{case.form}]"
    source = _preview(case.source)
    if expected.accepted:
        python_result = (
            f"full={_preview(expected.full_form)}, "
            f"input={_preview(expected.input_form)}"
        )
    else:
        python_result = f"rejected: {_preview(expected.error)}"
    if actual_forms is not None:
        haskell_result = (
            f"full={_preview(actual_forms[0])}, input={_preview(actual_forms[1])}"
        )
    else:
        haskell_result = f"rejected: {_preview(response.get('error'))}"
    return (
        f"{location}: {source}\n"
        f"  Python:  {python_result}\n"
        f"  Haskell: {haskell_result}"
    )


def _run(arguments: argparse.Namespace) -> int:
    cases = _literal_cases(arguments.tests.resolve())
    form_counts = _guard_corpus(cases)
    binary = _resolve_haskell_binary(arguments.haskell_binary)
    expectations = [_python_expectation(case) for case in cases]
    responses = _haskell_results(binary, cases, arguments.timeout)

    python_accepted = sum(expected.accepted for expected in expectations)
    haskell_accepted = 0
    shared_rejections = 0
    mismatch_cases = 0
    mismatch_kinds: Counter[str] = Counter()
    mismatches_by_form: Counter[str] = Counter()
    samples: list[str] = []

    for case, expected, response in zip(cases, expectations, responses, strict=True):
        success = response.get("success")
        if not isinstance(success, bool):
            raise HarnessError("Haskell parse response has a non-Boolean success field")
        actual_forms = _accepted_result(response)
        haskell_accepted += success

        case_kinds: list[str] = []
        if success != expected.accepted:
            case_kinds.append("acceptance")
        elif not success:
            shared_rejections += 1
        else:
            assert actual_forms is not None
            if actual_forms[0] != expected.full_form:
                case_kinds.append("full_form")
            if actual_forms[1] != expected.input_form:
                case_kinds.append("input_form")

        if not case_kinds:
            continue
        mismatch_cases += 1
        mismatches_by_form[case.form] += 1
        mismatch_kinds.update(case_kinds)
        if len(samples) < arguments.max_mismatch_samples:
            samples.append(
                _mismatch_sample(case, expected, response, actual_forms)
            )

    breakdown = ", ".join(
        f"{form}={form_counts[form]}" for form in ("input", "full", "standard")
    )
    mismatch_breakdown = ", ".join(
        f"{form}={mismatches_by_form[form]}"
        for form in ("input", "full", "standard")
    )
    print(f"Haskell executable: {binary}")
    print(f"Corpus: {len(cases)} unique literal parser calls ({breakdown}).")
    print(
        "Acceptance: "
        f"Python {python_accepted} accepted/{len(cases) - python_accepted} rejected; "
        f"Haskell {haskell_accepted} accepted/{len(cases) - haskell_accepted} rejected; "
        f"{shared_rejections} shared rejections."
    )
    print(
        f"Exact parity: {len(cases) - mismatch_cases}/{len(cases)} cases; "
        f"{mismatch_cases} mismatched ({mismatch_breakdown}); "
        f"acceptance={mismatch_kinds['acceptance']}, "
        f"FullForm={mismatch_kinds['full_form']}, "
        f"InputForm={mismatch_kinds['input_form']}."
    )
    if samples:
        print("\nMismatch samples:\n" + "\n\n".join(samples))
        omitted = mismatch_cases - len(samples)
        if omitted:
            print(f"\n... {omitted} additional mismatched cases omitted")
    return int(bool(mismatch_cases))


def main() -> int:
    arguments = _arguments()
    try:
        return _run(arguments)
    except HarnessError as error:
        print(f"parser parity harness error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
