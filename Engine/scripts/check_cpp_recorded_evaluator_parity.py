#!/usr/bin/env python3
"""Replay evaluator calls made by the Python tests against native C++.

Unlike the fast literal extractor, this gate executes the Python tests and
records their top-level ``evaluate`` calls.  Each unittest method is then
replayed in a fresh native evaluator, preserving setup, cleanup, messages, and
prints within that test without leaking definitions between tests.
"""

from __future__ import annotations

import argparse
from collections import Counter, OrderedDict
import concurrent.futures
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from typing import Iterator

import tungsten.expression as runtime


def _clone_symbol_record(record: object) -> object:
    """Clone mutable registry state while sharing immutable expression values."""
    return replace(
        record,
        own_values_definitions=list(record.own_values_definitions),
        down_values_definitions=list(record.down_values_definitions),
        up_values_definitions=list(record.up_values_definitions),
        sub_values_definitions=list(record.sub_values_definitions),
        n_values_definitions=list(record.n_values_definitions),
    )


# Tests intentionally mutate System symbols and session settings.  Merely
# filtering the live registry down to ``built_in`` records keeps those
# mutations and makes later tests order-dependent, while every C++ replay
# starts with a fresh Evaluator.  Capture the fully initialized Python registry
# once and clone its mutable records before each unittest method instead.
_PRISTINE_BUILTIN_SYMBOLS = {
    name: _clone_symbol_record(record)
    for name, record in runtime._SYMBOL_REGISTRY._symbols.items()
    if record.built_in
}
_PRISTINE_CONTEXTS = {
    "System`",
    "Global`",
    *(record.context for record in _PRISTINE_BUILTIN_SYMBOLS.values()),
}


@dataclass(frozen=True)
class RecordedEvaluation:
    test_id: str
    source: str
    success: bool
    full_form: str | None
    error: str | None
    messages: tuple[str, ...]
    message_texts: tuple[str, ...]
    prints: tuple[str, ...]


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", type=Path, default=Path("tests"))
    parser.add_argument("--pattern", default="test_expression*.py")
    parser.add_argument(
        "--test",
        action="append",
        help="Replay only test IDs containing this text; repeat to select more.",
    )
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        dest="native_binary",
        type=Path,
        default=Path("build/cpp/tungsten-cpp"),
    )
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=50)
    parser.add_argument(
        "--summary-by-test",
        action="store_true",
        help="Print mismatch counts grouped by unittest method.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=min(8, os.cpu_count() or 1),
        help="Number of independent unittest-method replays to run concurrently.",
    )
    parser.add_argument("--require-perfect", action="store_true")
    return parser.parse_args()


def _flatten_suite(suite: unittest.TestSuite) -> Iterator[unittest.TestCase]:
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten_suite(item)
        else:
            assert isinstance(item, unittest.TestCase)
            yield item


def _visible_effects() -> tuple[tuple[str, ...], tuple[str, ...], tuple[str, ...]]:
    return (
        tuple(message.name.to_full_form() for message in runtime._GLOBAL_VISIBLE_MESSAGES),
        tuple(message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES),
        tuple(runtime._GLOBAL_PRINTS),
    )


def _reset_reference_evaluator() -> None:
    """Give each unittest the same fresh process-local state as C++ replay."""
    registry = runtime._SYMBOL_REGISTRY
    registry.current_context = "Global`"
    registry.context_path = ("System`", "Global`")
    registry._symbols = {
        name: _clone_symbol_record(record)
        for name, record in _PRISTINE_BUILTIN_SYMBOLS.items()
    }
    registry._contexts = set(_PRISTINE_CONTEXTS)
    registry._module_number = 0
    registry._string_unique_counters.clear()
    runtime._GLOBAL_MESSAGES.clear()
    runtime._GLOBAL_VISIBLE_MESSAGES.clear()
    runtime._GLOBAL_PRINTS.clear()
    runtime._GLOBAL_DISABLED_MESSAGES.clear()
    runtime._GLOBAL_ASSERT_ENABLED = False


def _record_python_tests(
    tests_path: Path, pattern: str, test_filters: list[str] | None
) -> list[RecordedEvaluation]:
    root = tests_path.resolve()
    if not root.is_dir():
        raise RuntimeError(f"Test path is not a directory: {root}")
    top_level = root.parent
    discovered = unittest.TestLoader().discover(
        str(root), pattern=pattern, top_level_dir=str(top_level)
    )
    tests = list(_flatten_suite(discovered))
    if test_filters:
        tests = [
            test
            for test in tests
            if any(fragment in test.id() for fragment in test_filters)
        ]
    if not tests:
        raise RuntimeError("No evaluator tests matched the requested pattern and filters.")
    suite = unittest.TestSuite(tests)
    modules = {sys.modules[test.__class__.__module__] for test in tests}
    original = runtime.evaluate
    current_test = [""]
    records: list[RecordedEvaluation] = []

    def recording_evaluate(expression: object, *args: object, **kwargs: object) -> object:
        # eval-batch represents the standalone evaluator.  Session-aware calls
        # additionally mutate In/Out, message, print, and hook histories and
        # therefore belong to the separate REPL/session differential.
        if args or kwargs:
            return original(expression, *args, **kwargs)
        # The public evaluator accepts Expr.  Keeping this check implicit lets
        # the Python implementation produce its normal diagnostic if a test
        # deliberately supplies another object.
        # FullForm is still valid InputForm syntax, while several variadic
        # infix renderings (notably Apply/Map with a level specification) are
        # not structurally round-trippable through their pretty InputForm.
        source = expression.to_full_form()  # type: ignore[attr-defined]
        try:
            result = original(expression, *args, **kwargs)
        except Exception as error:
            messages, message_texts, prints = _visible_effects()
            records.append(
                RecordedEvaluation(
                    current_test[0],
                    source,
                    False,
                    None,
                    f"{type(error).__name__}: {error}",
                    messages,
                    message_texts,
                    prints,
                )
            )
            raise
        messages, message_texts, prints = _visible_effects()
        records.append(
            RecordedEvaluation(
                current_test[0],
                source,
                True,
                result.to_full_form(),
                None,
                messages,
                message_texts,
                prints,
            )
        )
        return result

    patched: list[tuple[object, str]] = []
    for module in modules:
        for name, value in tuple(vars(module).items()):
            if value is original:
                setattr(module, name, recording_evaluate)
                patched.append((module, name))

    class RecordingResult(unittest.TestResult):
        def startTest(self, test: unittest.TestCase) -> None:  # noqa: N802
            _reset_reference_evaluator()
            current_test[0] = test.id()
            super().startTest(test)

    result = RecordingResult()
    try:
        suite.run(result)
    finally:
        for module, name in patched:
            setattr(module, name, original)

    if result.failures or result.errors or result.unexpectedSuccesses:
        diagnostics = [
            f"{test.id()}: {text}"
            for test, text in [*result.failures, *result.errors]
        ]
        diagnostics.extend(
            f"{test.id()}: unexpected success" for test in result.unexpectedSuccesses
        )
        raise RuntimeError(
            "Python evaluator tests did not complete successfully:\n"
            + "\n".join(diagnostics[:10])
        )
    return records


def _native_results(binary: Path, records: list[RecordedEvaluation]) -> list[dict[str, object]]:
    request = "".join(json.dumps(record.source) + "\n" for record in records)
    completed = subprocess.run(
        [str(binary), "eval-batch", "--stateful"],
        input=request,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "Native evaluator failed.")
    payloads = [json.loads(line) for line in completed.stdout.splitlines()]
    if len(payloads) != len(records):
        raise RuntimeError(
            f"Native evaluator returned {len(payloads)} results for {len(records)} calls."
        )
    return payloads


def _display_expected(record: RecordedEvaluation) -> str:
    value = record.full_form if record.success else f"ERROR: {record.error}"
    return (
        f"{value}; messages={json.dumps(record.messages, ensure_ascii=False)}; "
        f"message_texts={json.dumps(record.message_texts, ensure_ascii=False)}; "
        f"prints={json.dumps(record.prints, ensure_ascii=False)}"
    )


def _display_actual(payload: dict[str, object]) -> str:
    value = (
        str(payload.get("full_form"))
        if payload.get("success")
        else f"ERROR: {payload.get('error', '')}"
    )
    return (
        f"{value}; messages={json.dumps(payload.get('messages', []), ensure_ascii=False)}; "
        f"message_texts={json.dumps(payload.get('message_texts', []), ensure_ascii=False)}; "
        f"prints={json.dumps(payload.get('prints', []), ensure_ascii=False)}"
    )


_GENERATED_SYMBOL = re.compile(
    r"(?<![A-Za-z0-9`$])((?:[A-Za-z][A-Za-z0-9`]*|)\$)\d+(?![A-Za-z0-9`])"
)


def _normalize_generated_symbols(value: str) -> str:
    names: dict[str, str] = {}
    counts: Counter[str] = Counter()

    def replace(match: re.Match[str]) -> str:
        token = match.group(0)
        prefix = match.group(1)
        if token not in names:
            counts[prefix] += 1
            names[token] = f"{prefix}<generated-{counts[prefix]}>"
        return names[token]

    return _GENERATED_SYMBOL.sub(replace, value)


def _value_matches(record: RecordedEvaluation, payload: dict[str, object]) -> bool:
    if not record.success:
        return True
    # Wall-clock readings are intentionally nondeterministic.  Their result
    # shape and second elements have dedicated native tests; this differential
    # only requires successful evaluation for these calls.
    if record.source.startswith(
        ("AbsoluteTiming[", "Timing[", "TimeRemaining[", "TimeConstrained[TimeRemaining[")
    ):
        return True
    actual = payload.get("full_form")
    return isinstance(actual, str) and _normalize_generated_symbols(
        actual
    ) == _normalize_generated_symbols(record.full_form or "")


def _matches(record: RecordedEvaluation, payload: dict[str, object]) -> bool:
    if bool(payload.get("success")) != record.success:
        return False
    if not _value_matches(record, payload):
        return False
    # Exception class names are implementation-language details.  Requiring
    # both sides to fail is the portable semantic gate for the two recorded
    # exceptional calls.
    return (
        tuple(payload.get("messages", [])) == record.messages
        and tuple(payload.get("message_texts", [])) == record.message_texts
        and tuple(payload.get("prints", [])) == record.prints
    )


def main() -> int:
    args = _arguments()
    if not args.no_build:
        subprocess.run(
            ["cmake", "--build", "build/cpp", "--target", "tungsten-cpp", "--parallel"],
            check=True,
        )

    records = _record_python_tests(args.tests, args.pattern, args.test)
    grouped: OrderedDict[str, list[RecordedEvaluation]] = OrderedDict()
    for record in records:
        grouped.setdefault(record.test_id, []).append(record)

    mismatches: list[str] = []
    mismatch_tests: Counter[str] = Counter()
    comparisons = 0
    work = list(grouped.items())
    worker_count = max(1, args.workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
        native_groups = executor.map(
            lambda item: _native_results(args.native_binary, item[1]), work
        )
        replayed = zip(work, native_groups, strict=True)
        for (test_id, group), native in replayed:
            for index, (record, payload) in enumerate(
                zip(group, native, strict=True), start=1
            ):
                comparisons += 1
                if _matches(record, payload):
                    continue
                mismatch_tests[test_id] += 1
                mismatches.append(
                    f"{test_id}:{index}: {record.source!r}\n"
                    f"  Python: {_display_expected(record)}\n"
                    f"  C++:    {_display_actual(payload)}"
                )

    print(
        f"Matched {comparisons - len(mismatches)}/{comparisons} recorded evaluator calls "
        f"across {len(grouped)} tests; {len(mismatches)} mismatches."
    )
    if args.summary_by_test and mismatch_tests:
        print(
            f"Mismatches occur in {len(mismatch_tests)} tests "
            f"({len(grouped) - len(mismatch_tests)} tests are exact):"
        )
        for test_id, count in mismatch_tests.most_common():
            print(f"  {count:4}  {test_id}")
    if mismatches and args.max_mismatches != 0:
        shown = mismatches[: args.max_mismatches]
        print("\n\n".join(shown))
        if len(shown) < len(mismatches):
            print(f"\n... {len(mismatches) - len(shown)} additional mismatches omitted")
    return int(args.require_perfect and bool(mismatches))


if __name__ == "__main__":
    raise SystemExit(main())
