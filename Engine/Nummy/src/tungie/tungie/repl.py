from __future__ import annotations

import sys
from typing import TextIO

from .errors import TungieEvaluationError
from .errors import TungieExitRequested
from .errors import TungieSyntaxError
from .evaluator import EvaluationSession
from .parser import parse
from .values import Symbol


def banner() -> str:
    return (
        "Tungie 0.1.0 Lightweight Tungsten-inspired Calculator\n"
        "Dependency-light Nummy REPL; structural subset, not tungsten.exe.\n"
    )


def run_repl(
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    show_banner: bool = True,
) -> int:
    input_stream = stdin or sys.stdin
    output_stream = stdout or sys.stdout
    error_stream = stderr or sys.stderr
    session = EvaluationSession()

    if show_banner:
        output_stream.write(banner())
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

        try:
            expr = parse(source)
            line, result = session.evaluate_input(expr)
        except TungieSyntaxError as exc:
            error_stream.write(f"Syntax::sntxi: {exc}\n\n")
            error_stream.flush()
            continue
        except TungieExitRequested as exc:
            return exc.code
        except TungieEvaluationError as exc:
            error_stream.write(f"Evaluate::error: {exc}\n\n")
            error_stream.flush()
            continue

        if _should_print(result):
            output_stream.write(f"\nOut[{line}]= {result.to_input_form()}\n\n")
        else:
            output_stream.write("\n")
        output_stream.flush()


def _should_print(expr) -> bool:
    return not (isinstance(expr, Symbol) and expr.name == "Null")
