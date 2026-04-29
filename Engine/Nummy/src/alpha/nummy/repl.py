"""Console REPL for the Nummy alpha calculator."""

from __future__ import annotations

import re
import sys
from typing import TextIO

from . import __version__
from .calculator import (
    DEFAULT_CALCULATOR_PRECISION,
    CalculatorSession,
    CalculatorSyntaxError,
)


_EXIT_PATTERN = re.compile(r"^(?:Exit|Quit|exit|quit)(?:\[(?P<code>[+-]?\d+)\]|\(\))?$")


def banner(default_precision: int = DEFAULT_CALCULATOR_PRECISION) -> str:
    return (
        f"Nummy {__version__} Alpha Calculator for Microsoft Windows (64-bit)\n"
        "Structural base-10 tower arithmetic; experimental reference implementation.\n"
        f"Default output precision: {default_precision} decimal digits.\n"
    )


def run_repl(
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    show_banner: bool = True,
    default_precision: int = DEFAULT_CALCULATOR_PRECISION,
) -> int:
    input_stream = stdin or sys.stdin
    output_stream = stdout or sys.stdout
    error_stream = stderr or sys.stderr
    session = CalculatorSession(default_precision=default_precision)

    if show_banner:
        output_stream.write(banner(default_precision))
        output_stream.write("\n")

    while True:
        output_stream.write(f"In[{session.line + 1}]:= ")
        output_stream.flush()

        source = input_stream.readline()
        if source == "":
            output_stream.write("\n")
            output_stream.flush()
            return 0

        source = source.rstrip("\r\n")
        if not source.strip():
            output_stream.write("\n")
            continue

        exit_code = _try_parse_exit(source)
        if exit_code is not None:
            return exit_code

        try:
            evaluation = session.evaluate_line(source)
        except CalculatorSyntaxError as exc:
            error_stream.write(f"Syntax::sntxi: {exc}\n\n")
            error_stream.flush()
            continue
        except Exception as exc:
            error_stream.write(f"Evaluate::error: {exc}\n\n")
            error_stream.flush()
            continue

        output_stream.write(f"\nOut[{evaluation.line}]= {evaluation.display_text}\n\n")
        output_stream.flush()


def _try_parse_exit(source: str) -> int | None:
    match = _EXIT_PATTERN.match(source.strip())
    if not match:
        return None
    code = match.group("code")
    return int(code) if code is not None else 0
