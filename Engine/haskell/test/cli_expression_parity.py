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
    ("evaluation success", ("expr", "evaluate", "--code", "1 + 2", "--form", "input"), 0),
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
