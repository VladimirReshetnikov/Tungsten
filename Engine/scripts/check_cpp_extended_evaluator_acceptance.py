#!/usr/bin/env python3
"""Development acceptance gate for uncovered native evaluator behavior.

The broad recorded differential deliberately relaxes random and wall-clock
results.  This companion gate covers those calls without making their
nondeterministic values exact:

* ``CompositeQ`` is compared exactly with the Python compatibility engine;
* ``RandomSample`` and ``RandomPermutation`` are checked for shape,
  cardinality, and without-replacement/permutation invariants;
* ``Pause``, ``AbsoluteTiming``, ``TimeConstrained``, and ``TimeRemaining``
  are checked with deliberately generous monotonic-clock tolerances; and
* invalid random/timing forms are compared exactly, including their inert
  results, message names, and message text.

This is a development-only Python-oracle gate.  The native executable does
not load Python and this script is not part of the installed runtime.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
import math
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from typing import Iterable

import tungsten.expression as runtime
from tungsten.expression_parser import parse_input_form


ENGINE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE_BINARY = ENGINE_ROOT / "build" / "cpp" / "tungsten-cpp"


@dataclass(frozen=True)
class Evaluation:
    success: bool
    full_form: str | None
    error: str | None
    messages: tuple[str, ...]
    message_texts: tuple[str, ...]
    prints: tuple[str, ...]


@dataclass(frozen=True)
class Check:
    cluster: str
    label: str
    passed: bool
    detail: str = ""


@dataclass(frozen=True)
class SampleInvariant:
    label: str
    source: str
    expected_head: str
    available_items: tuple[str, ...]
    expected_count: int
    require_every_item: bool = False


COMPOSITE_CASES = (
    "CompositeQ[-100]",
    "CompositeQ[-4]",
    "CompositeQ[-1]",
    "CompositeQ[0]",
    "CompositeQ[1]",
    "CompositeQ[2]",
    "CompositeQ[3]",
    "CompositeQ[4]",
    "CompositeQ[5]",
    "CompositeQ[6]",
    "CompositeQ[9]",
    "CompositeQ[25]",
    "CompositeQ[97]",
    "CompositeQ[561]",
    "CompositeQ[65537]",
    "CompositeQ[1000005]",
    "CompositeQ[18446744073709551615]",
    "CompositeQ[18446744073709551557]",
    "CompositeQ[2^16]",
    "CompositeQ[49/7]",
    "CompositeQ[]",
    "CompositeQ[x]",
    "CompositeQ[4.]",
    "CompositeQ[4,6]",
)


SAMPLE_INVARIANTS = (
    SampleInvariant(
        "full list is a permutation",
        "RandomSample[{a,b,c,d}]",
        "List",
        ("a", "b", "c", "d"),
        4,
        require_every_item=True,
    ),
    SampleInvariant(
        "All preserves the complete multiset",
        "RandomSample[{a,a,b,c},All]",
        "List",
        ("a", "a", "b", "c"),
        4,
        require_every_item=True,
    ),
    SampleInvariant(
        "bounded sample respects duplicate multiplicity",
        "RandomSample[{a,a,b,c},3]",
        "List",
        ("a", "a", "b", "c"),
        3,
    ),
    SampleInvariant(
        "zero count returns an empty list",
        "RandomSample[{a,b,c,d},0]",
        "List",
        ("a", "b", "c", "d"),
        0,
    ),
    SampleInvariant(
        "UpTo clips to the requested count",
        "RandomSample[{a,b,c,d},UpTo[2]]",
        "List",
        ("a", "b", "c", "d"),
        2,
    ),
    SampleInvariant(
        "UpTo clips at the sequence length",
        "RandomSample[{a,b},UpTo[5]]",
        "List",
        ("a", "b"),
        2,
        require_every_item=True,
    ),
    SampleInvariant(
        "an empty input remains empty",
        "RandomSample[{}]",
        "List",
        (),
        0,
        require_every_item=True,
    ),
    SampleInvariant(
        "a general expression preserves its head",
        "RandomSample[f[a,b,c,d],2]",
        "f",
        ("a", "b", "c", "d"),
        2,
    ),
    SampleInvariant(
        "an association samples complete entries",
        "RandomSample[Association[a->1,b->2,c->3],2]",
        "Association",
        ("Rule[a, 1]", "Rule[b, 2]", "Rule[c, 3]"),
        2,
    ),
)


PERMUTATION_LENGTHS = (0, 1, 2, 8, 32)


RANDOM_DIAGNOSTIC_CASES = (
    "RandomSample[]",
    "RandomSample[{a,b},All,1]",
    "RandomSample[a]",
    "RandomSample[{a,b},x]",
    "RandomSample[{a,b},UpTo[x]]",
    "RandomSample[{a,b},-1]",
    "RandomSample[{a,b},3]",
    "RandomSample[{a,b},UpTo[-1]]",
    "RandomPermutation[]",
    "RandomPermutation[1,2]",
    "RandomPermutation[-1]",
    "RandomPermutation[2.]",
    "RandomPermutation[x]",
)


DETERMINISTIC_TIMING_CASES = (
    "Pause[0]",
    "TimeRemaining[]",
    "TimeConstrained[7,Infinity,fail]",
)


TIMING_DIAGNOSTIC_CASES = (
    "Pause[]",
    "Pause[0,1]",
    "Pause[x]",
    "Pause[1/10]",
    "Pause[-1]",
    "Pause[Infinity]",
    "AbsoluteTiming[]",
    "AbsoluteTiming[1,2]",
    "TimeConstrained[]",
    "TimeConstrained[1]",
    "TimeConstrained[1,x]",
    "TimeConstrained[1,1,x,y]",
    "TimeRemaining[1]",
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        dest="native_binary",
        type=Path,
        default=DEFAULT_NATIVE_BINARY,
        help="Path to the already-built tungsten-cpp executable.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print successful checks as well as failures.",
    )
    return parser.parse_args()


def _clear_visible_effects() -> None:
    runtime._GLOBAL_MESSAGES.clear()
    runtime._GLOBAL_VISIBLE_MESSAGES.clear()
    runtime._GLOBAL_PRINTS.clear()


def _python_oracle(source: str) -> Evaluation:
    """Evaluate one deterministic case through the compatibility engine."""
    _clear_visible_effects()
    try:
        value = runtime.evaluate(parse_input_form(source))
        success = True
        full_form = value.to_full_form()
        error = None
    except Exception as exception:  # The native JSON protocol reports failures.
        success = False
        full_form = None
        error = str(exception)
    return Evaluation(
        success=success,
        full_form=full_form,
        error=error,
        messages=tuple(
            message.name.to_full_form()
            for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        message_texts=tuple(
            message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        prints=tuple(runtime._GLOBAL_PRINTS),
    )


def _string_tuple(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return (f"<invalid array: {value!r}>",)
    return tuple(item if isinstance(item, str) else repr(item) for item in value)


def _batch_evaluation(payload: dict[str, object]) -> Evaluation:
    success = payload.get("success") is True
    full_form = payload.get("full_form") if success else None
    error = None if success else payload.get("error")
    return Evaluation(
        success=success,
        full_form=full_form if isinstance(full_form, str) else None,
        error=error if isinstance(error, str) else None,
        messages=_string_tuple(payload.get("messages", [])),
        message_texts=_string_tuple(payload.get("message_texts", [])),
        prints=_string_tuple(payload.get("prints", [])),
    )


def _expr_evaluation(payload: dict[str, object]) -> Evaluation:
    if payload.get("success") is False:
        error = payload.get("error")
        return Evaluation(
            success=False,
            full_form=None,
            error=error if isinstance(error, str) else "invalid expr error payload",
            messages=(),
            message_texts=(),
            prints=(),
        )

    result = payload.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("full_form"), str):
        return Evaluation(
            success=False,
            full_form=None,
            error=f"invalid expr success payload: {payload!r}",
            messages=(),
            message_texts=(),
            prints=(),
        )

    raw_messages = payload.get("messages", [])
    messages: list[str] = []
    message_texts: list[str] = []
    if isinstance(raw_messages, list):
        for message in raw_messages:
            if not isinstance(message, dict):
                messages.append(repr(message))
                message_texts.append("")
                continue
            full_name = message.get("full_name")
            text = message.get("text")
            messages.append(full_name if isinstance(full_name, str) else repr(full_name))
            message_texts.append(text if isinstance(text, str) else repr(text))
    else:
        messages.append(f"<invalid array: {raw_messages!r}>")

    return Evaluation(
        success=True,
        full_form=result["full_form"],
        error=None,
        messages=tuple(messages),
        message_texts=tuple(message_texts),
        prints=_string_tuple(payload.get("prints", [])),
    )


def _run_eval_batch(binary: Path, sources: Iterable[str]) -> list[Evaluation]:
    source_list = list(sources)
    completed = subprocess.run(
        [str(binary), "eval-batch"],
        input="".join(json.dumps(source) + "\n" for source in source_list),
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"native eval-batch exited {completed.returncode}: "
            f"{completed.stderr.strip() or '<no stderr>'}"
        )
    lines = completed.stdout.splitlines()
    if len(lines) != len(source_list):
        raise RuntimeError(
            f"native eval-batch returned {len(lines)} results for "
            f"{len(source_list)} expressions"
        )
    evaluations: list[Evaluation] = []
    for index, line in enumerate(lines, start=1):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exception:
            raise RuntimeError(
                f"native eval-batch result {index} is not JSON: {exception}"
            ) from exception
        if not isinstance(payload, dict):
            raise RuntimeError(
                f"native eval-batch result {index} is not an object: {payload!r}"
            )
        evaluations.append(_batch_evaluation(payload))
    return evaluations


class _TimedEvalBatch:
    """Keep eval-batch warm so wall measurements exclude process startup.

    A reader thread makes the line protocol portable across POSIX and Windows
    while still giving every expression a bounded response wait.  The C++
    loop flushes each response when it begins its next tied ``std::cin`` read.
    """

    _RESPONSE_TIMEOUT_SECONDS = 5.0

    def __init__(self, binary: Path) -> None:
        self._binary = binary
        self._process: subprocess.Popen[str] | None = None
        self._responses: queue.Queue[str | None] = queue.Queue()
        self._stderr_lines: list[str] = []
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None

    def __enter__(self) -> _TimedEvalBatch:
        self._process = subprocess.Popen(
            [str(self._binary), "eval-batch"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._stdout_thread = threading.Thread(
            target=self._read_stdout,
            name="tungsten-eval-batch-stdout",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._read_stderr,
            name="tungsten-eval-batch-stderr",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()
        try:
            warmup, _elapsed = self.evaluate("1+1")
            problem = _clean_success(warmup)
            if problem is not None or warmup.full_form != "2":
                raise RuntimeError(
                    "native eval-batch warmup failed: " + _display(warmup)
                )
        except Exception:
            self.close()
            raise
        return self

    def __exit__(
        self,
        _exception_type: object,
        _exception: object,
        _traceback: object,
    ) -> None:
        self.close()

    def _read_stdout(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            self._responses.put(None)
            return
        try:
            for line in process.stdout:
                self._responses.put(line)
        finally:
            self._responses.put(None)

    def _read_stderr(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        for line in process.stderr:
            self._stderr_lines.append(line.rstrip("\n"))

    def _stderr_tail(self) -> str:
        return "\n".join(self._stderr_lines[-10:]) or "<no stderr>"

    def _stop_process(self) -> None:
        process = self._process
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)

    def evaluate(self, source: str) -> tuple[Evaluation, float]:
        process = self._process
        if process is None or process.stdin is None:
            return Evaluation(False, None, "eval-batch is not running", (), (), ()), 0.0
        if process.poll() is not None:
            return (
                Evaluation(
                    False,
                    None,
                    f"eval-batch exited {process.returncode}: {self._stderr_tail()}",
                    (),
                    (),
                    (),
                ),
                0.0,
            )

        started = time.perf_counter()
        try:
            process.stdin.write(json.dumps(source) + "\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exception:
            elapsed = time.perf_counter() - started
            return (
                Evaluation(
                    False,
                    None,
                    f"could not send eval-batch request: {exception}; "
                    f"stderr={self._stderr_tail()}",
                    (),
                    (),
                    (),
                ),
                elapsed,
            )

        try:
            line = self._responses.get(timeout=self._RESPONSE_TIMEOUT_SECONDS)
        except queue.Empty:
            elapsed = time.perf_counter() - started
            self._stop_process()
            return (
                Evaluation(
                    False,
                    None,
                    f"eval-batch response exceeded "
                    f"{self._RESPONSE_TIMEOUT_SECONDS:.1f}s",
                    (),
                    (),
                    (),
                ),
                elapsed,
            )
        elapsed = time.perf_counter() - started
        if line is None:
            return (
                Evaluation(
                    False,
                    None,
                    f"eval-batch closed stdout: {self._stderr_tail()}",
                    (),
                    (),
                    (),
                ),
                elapsed,
            )
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exception:
            return (
                Evaluation(
                    False,
                    None,
                    f"eval-batch returned invalid JSON: {exception}: {line!r}",
                    (),
                    (),
                    (),
                ),
                elapsed,
            )
        if not isinstance(payload, dict):
            return (
                Evaluation(
                    False,
                    None,
                    f"eval-batch JSON is not an object: {payload!r}",
                    (),
                    (),
                    (),
                ),
                elapsed,
            )
        return _batch_evaluation(payload), elapsed

    def close(self) -> None:
        process = self._process
        if process is None:
            return
        if process.stdin is not None and not process.stdin.closed:
            try:
                process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        if process.poll() is None:
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self._stop_process()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        if self._stdout_thread is not None:
            self._stdout_thread.join(timeout=1)
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=1)
        self._process = None


def _display(evaluation: Evaluation) -> str:
    value = evaluation.full_form if evaluation.success else f"ERROR: {evaluation.error}"
    return (
        f"{value}; messages={evaluation.messages!r}; "
        f"message_texts={evaluation.message_texts!r}; prints={evaluation.prints!r}"
    )


def _exact_check(cluster: str, source: str, actual: Evaluation) -> Check:
    expected = _python_oracle(source)
    passed = actual == expected
    detail = "" if passed else f"Python: {_display(expected)}\nC++:    {_display(actual)}"
    return Check(cluster, source, passed, detail)


def _clean_success(evaluation: Evaluation) -> str | None:
    if not evaluation.success:
        return f"evaluation failed: {evaluation.error}"
    if evaluation.messages or evaluation.message_texts or evaluation.prints:
        return f"unexpected effects: {_display(evaluation)}"
    if evaluation.full_form is None:
        return "successful evaluation omitted full_form"
    return None


def _canonical_item(source: str) -> str:
    return parse_input_form(source).to_full_form()


def _sample_check(specification: SampleInvariant, actual: Evaluation) -> Check:
    problem = _clean_success(actual)
    if problem is not None:
        return Check("random", specification.label, False, problem)
    try:
        result = parse_input_form(actual.full_form or "")
    except Exception as exception:
        return Check(
            "random",
            specification.label,
            False,
            f"could not parse native FullForm: {exception}",
        )
    if not isinstance(result, runtime.Call):
        return Check(
            "random",
            specification.label,
            False,
            f"expected a compound result, got {actual.full_form}",
        )
    actual_head = result.head_expr.to_full_form()
    if actual_head != specification.expected_head:
        return Check(
            "random",
            specification.label,
            False,
            f"expected head {specification.expected_head}, got {actual_head}",
        )
    actual_items = Counter(item.to_full_form() for item in result.arguments)
    available_items = Counter(
        _canonical_item(item) for item in specification.available_items
    )
    if len(result.arguments) != specification.expected_count:
        return Check(
            "random",
            specification.label,
            False,
            f"expected {specification.expected_count} items, got {len(result.arguments)}: "
            f"{actual.full_form}",
        )
    excess = actual_items - available_items
    if excess:
        return Check(
            "random",
            specification.label,
            False,
            f"sample contains unavailable or over-repeated items {dict(excess)}: "
            f"{actual.full_form}",
        )
    if specification.require_every_item and actual_items != available_items:
        return Check(
            "random",
            specification.label,
            False,
            f"sample changed the multiset: expected {dict(available_items)}, "
            f"got {dict(actual_items)}",
        )
    return Check("random", specification.label, True)


def _permutation_check(length: int, actual: Evaluation) -> Check:
    label = f"RandomPermutation[{length}] is a permutation of 1..{length}"
    problem = _clean_success(actual)
    if problem is not None:
        return Check("random", label, False, problem)
    try:
        result = parse_input_form(actual.full_form or "")
    except Exception as exception:
        return Check(
            "random", label, False, f"could not parse native FullForm: {exception}"
        )
    if not isinstance(result, runtime.Call) or not result.has_head("List"):
        return Check(
            "random",
            label,
            False,
            f"PermutationList did not produce a list: {actual.full_form}",
        )
    if not all(isinstance(item, runtime.Integer) for item in result.arguments):
        return Check(
            "random", label, False, f"permutation contains nonintegers: {actual.full_form}"
        )
    values = [item.value for item in result.arguments]
    expected = list(range(1, length + 1))
    if sorted(values) != expected:
        return Check(
            "random",
            label,
            False,
            f"expected each index exactly once; got {values}",
        )
    return Check("random", label, True)


def _parse_result(evaluation: Evaluation) -> tuple[runtime.Expr | None, str | None]:
    problem = _clean_success(evaluation)
    if problem is not None:
        return None, problem
    try:
        return parse_input_form(evaluation.full_form or ""), None
    except Exception as exception:
        return None, f"could not parse native FullForm: {exception}"


def _real_value(expression: runtime.Expr) -> float | None:
    if not isinstance(expression, runtime.Real):
        return None
    text = expression.text
    if "*^" in text:
        mantissa, exponent = text.split("*^", 1)
        text = f"{mantissa.split('`', 1)[0]}e{exponent}"
    else:
        text = text.split("`", 1)[0]
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def _timing_checks(batch: _TimedEvalBatch) -> list[Check]:
    checks: list[Check] = []

    pause_source = "Pause[.06]"
    pause, pause_wall = batch.evaluate(pause_source)
    pause_problem = _clean_success(pause)
    pause_passed = (
        pause_problem is None
        and pause.full_form == "Null"
        and 0.025 <= pause_wall <= 3.0
    )
    checks.append(
        Check(
            "timing",
            "Pause sleeps for a positive interval",
            pause_passed,
            "" if pause_passed else (
                f"result={_display(pause)}, wall={pause_wall:.6f}s; "
                "expected Null and wall time in [0.025, 3.0]s"
            ),
        )
    )

    absolute_source = "AbsoluteTiming[Pause[.06];7]"
    absolute, absolute_wall = batch.evaluate(absolute_source)
    absolute_expr, absolute_problem = _parse_result(absolute)
    reported: float | None = None
    value_matches = False
    if (
        isinstance(absolute_expr, runtime.Call)
        and absolute_expr.has_head("List")
        and len(absolute_expr.arguments) == 2
    ):
        reported = _real_value(absolute_expr.arguments[0])
        value_matches = absolute_expr.arguments[1].to_full_form() == "7"
    absolute_passed = (
        absolute_problem is None
        and reported is not None
        and 0.025 <= reported <= absolute_wall + 0.1
        and value_matches
        and 0.025 <= absolute_wall <= 3.0
    )
    checks.append(
        Check(
            "timing",
            "AbsoluteTiming reports elapsed time and the evaluated value",
            absolute_passed,
            "" if absolute_passed else (
                f"result={_display(absolute)}, reported={reported!r}, "
                f"wall={absolute_wall:.6f}s; expected List[real, 7] with both "
                "elapsed readings at least 0.025s"
            ),
        )
    )

    success_source = "TimeConstrained[Pause[.06];7,.5,timeout]"
    constrained, constrained_wall = batch.evaluate(success_source)
    constrained_problem = _clean_success(constrained)
    constrained_passed = (
        constrained_problem is None
        and constrained.full_form == "7"
        and 0.025 <= constrained_wall <= 3.0
    )
    checks.append(
        Check(
            "timing",
            "TimeConstrained returns an expression completed before its deadline",
            constrained_passed,
            "" if constrained_passed else (
                f"result={_display(constrained)}, wall={constrained_wall:.6f}s; "
                "expected 7 after a measurable pause"
            ),
        )
    )

    timeout_source = "TimeConstrained[Pause[2.];7,.05,timeout]"
    timeout, timeout_wall = batch.evaluate(timeout_source)
    timeout_problem = _clean_success(timeout)
    timeout_passed = (
        timeout_problem is None
        and timeout.full_form == "timeout"
        and 0.015 <= timeout_wall <= 1.0
    )
    checks.append(
        Check(
            "timing",
            "TimeConstrained interrupts work and evaluates its timeout fallback",
            timeout_passed,
            "" if timeout_passed else (
                f"result={_display(timeout)}, wall={timeout_wall:.6f}s; "
                "expected timeout in [0.015, 1.0]s"
            ),
        )
    )

    default_source = "TimeConstrained[Pause[2.];7,.05]"
    default_timeout, default_wall = batch.evaluate(default_source)
    default_problem = _clean_success(default_timeout)
    default_passed = (
        default_problem is None
        and default_timeout.full_form == "$Aborted"
        and 0.015 <= default_wall <= 1.0
    )
    checks.append(
        Check(
            "timing",
            "TimeConstrained defaults to $Aborted on timeout",
            default_passed,
            "" if default_passed else (
                f"result={_display(default_timeout)}, wall={default_wall:.6f}s; "
                "expected $Aborted in [0.015, 1.0]s"
            ),
        )
    )

    remaining_source = (
        "TimeConstrained[{TimeRemaining[],Pause[.06],TimeRemaining[]},.5,fail]"
    )
    remaining, remaining_wall = batch.evaluate(remaining_source)
    remaining_expr, remaining_problem = _parse_result(remaining)
    first_remaining: float | None = None
    second_remaining: float | None = None
    pause_value_matches = False
    if (
        isinstance(remaining_expr, runtime.Call)
        and remaining_expr.has_head("List")
        and len(remaining_expr.arguments) == 3
    ):
        first_remaining = _real_value(remaining_expr.arguments[0])
        pause_value_matches = remaining_expr.arguments[1].to_full_form() == "Null"
        second_remaining = _real_value(remaining_expr.arguments[2])
    remaining_passed = (
        remaining_problem is None
        and first_remaining is not None
        and second_remaining is not None
        and 0.0 <= second_remaining < first_remaining <= 0.5
        and first_remaining - second_remaining >= 0.025
        and pause_value_matches
        and 0.025 <= remaining_wall <= 3.0
    )
    checks.append(
        Check(
            "timing",
            "TimeRemaining decreases within the active constraint",
            remaining_passed,
            "" if remaining_passed else (
                f"result={_display(remaining)}, first={first_remaining!r}, "
                f"second={second_remaining!r}, wall={remaining_wall:.6f}s; "
                "expected two finite readings separated by at least 0.025s"
            ),
        )
    )

    return checks


def _print_summary(checks: list[Check], *, verbose: bool) -> None:
    for check in checks:
        if not verbose and check.passed:
            continue
        status = "PASS" if check.passed else "FAIL"
        print(f"{status} [{check.cluster}] {check.label}")
        if check.detail:
            for line in check.detail.splitlines():
                print(f"  {line}")

    print("\nC++ extended evaluator acceptance summary")
    for cluster in ("composite", "random", "timing"):
        cluster_checks = [check for check in checks if check.cluster == cluster]
        passed = sum(check.passed for check in cluster_checks)
        print(f"  {cluster}: {passed}/{len(cluster_checks)} passed")
    passed = sum(check.passed for check in checks)
    failures = len(checks) - passed
    verdict = "PASS" if failures == 0 else "FAIL"
    print(f"{verdict}: {passed}/{len(checks)} checks passed; {failures} failed.")


def main() -> int:
    arguments = _arguments()
    binary = arguments.native_binary.resolve()
    if not binary.is_file():
        print(f"ERROR: native binary does not exist: {binary}", file=sys.stderr)
        return 2

    checks: list[Check] = []
    try:
        composite_actual = _run_eval_batch(binary, COMPOSITE_CASES)
        checks.extend(
            _exact_check("composite", source, actual)
            for source, actual in zip(
                COMPOSITE_CASES, composite_actual, strict=True
            )
        )

        sample_actual = _run_eval_batch(
            binary, (specification.source for specification in SAMPLE_INVARIANTS)
        )
        checks.extend(
            _sample_check(specification, actual)
            for specification, actual in zip(
                SAMPLE_INVARIANTS, sample_actual, strict=True
            )
        )

        permutation_sources = tuple(
            f"PermutationList[RandomPermutation[{length}],{length}]"
            for length in PERMUTATION_LENGTHS
        )
        permutation_actual = _run_eval_batch(binary, permutation_sources)
        checks.extend(
            _permutation_check(length, actual)
            for length, actual in zip(
                PERMUTATION_LENGTHS, permutation_actual, strict=True
            )
        )

        random_diagnostics = _run_eval_batch(binary, RANDOM_DIAGNOSTIC_CASES)
        checks.extend(
            _exact_check("random", source, actual)
            for source, actual in zip(
                RANDOM_DIAGNOSTIC_CASES, random_diagnostics, strict=True
            )
        )

        deterministic_timing = _run_eval_batch(
            binary, DETERMINISTIC_TIMING_CASES
        )
        checks.extend(
            _exact_check("timing", source, actual)
            for source, actual in zip(
                DETERMINISTIC_TIMING_CASES, deterministic_timing, strict=True
            )
        )

        timing_diagnostics = _run_eval_batch(binary, TIMING_DIAGNOSTIC_CASES)
        checks.extend(
            _exact_check("timing", source, actual)
            for source, actual in zip(
                TIMING_DIAGNOSTIC_CASES, timing_diagnostics, strict=True
            )
        )

        with _TimedEvalBatch(binary) as timed_batch:
            checks.extend(_timing_checks(timed_batch))
    except (OSError, RuntimeError, subprocess.SubprocessError) as exception:
        print(f"ERROR: acceptance harness failed: {exception}", file=sys.stderr)
        return 2

    _print_summary(checks, verbose=arguments.verbose)
    return int(any(not check.passed for check in checks))


if __name__ == "__main__":
    raise SystemExit(main())
