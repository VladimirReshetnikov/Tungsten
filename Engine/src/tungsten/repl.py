from __future__ import annotations

import sys
from typing import TextIO

from . import __version__
from .expression import EvaluationSession
from .expression import Expr
from .expression import Symbol
from .expression import TungstenExitRequested
from .expression import WolframEvaluationError
from .expression import WolframSyntaxError
from .expression import display_output_parts
from .expression import evaluate
from .expression import parse_input_form


def _banner() -> str:
    return (
        f"Tungsten {__version__} Kernel-free Wolfram Language Interpreter for Microsoft Windows (64-bit)\n"
        "Copyright 2026 OpenAI Codex. Structural subset; not a Wolfram kernel.\n"
    )


def _format_output(expr: Expr) -> str:
    return display_output_parts(expr)[1]


def _output_label(line: int, expr: Expr) -> str:
    form_name, _text = display_output_parts(expr)
    if form_name is None:
        return f"Out[{line}]"
    return f"Out[{line}]//{form_name}"


def _should_print_output(expr: Expr) -> bool:
    return not (isinstance(expr, Symbol) and expr.name == "Null")


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
        output_stream.write(_banner())
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
            parsed = parse_input_form(source)
        except WolframSyntaxError as exc:
            error_stream.write(f"Syntax::sntxi: {exc}\n\n")
            error_stream.flush()
            continue

        line = session.begin_input(source, parsed)
        try:
            result = evaluate(parsed, session=session)
        except TungstenExitRequested as exc:
            return exc.code
        except WolframEvaluationError as exc:
            error_stream.write(f"Evaluate::error: {exc}\n\n")
            error_stream.flush()
            continue

        assert session.current_visible_messages is not None
        assert session.current_prints is not None
        for message in session.current_visible_messages:
            error_stream.write(message.text)
            error_stream.write("\n")
        error_stream.flush()
        for text in session.current_prints:
            output_stream.write(text)
            output_stream.write("\n")

        session.finish_output(result)
        if _should_print_output(result):
            output_stream.write(f"\n{_output_label(line, result)}= {_format_output(result)}\n\n")
        else:
            output_stream.write("\n")
        output_stream.flush()
