"""Interactive REPL for the Nummy calculator.

Run from the ``Engine/Nummy/src/beta`` directory with::

    PYTHONPATH=. python -m nummy

The REPL prints ``In[n]:= ``/``Out[n]= `` prompts in the spirit of
``tungsten.exe`` and ``wolfram.exe``.  Inputs are parsed by
:mod:`nummy.calc`; results land in ``session.history`` so subsequent
inputs can refer back to them with ``%``, ``%%``, or ``%n``.

This is a calculator, not a Wolfram-Language interpreter -- it only
supports the limited grammar described in :mod:`nummy.calc`.
"""

from __future__ import annotations

import sys
from typing import Optional, TextIO

from . import __version__
from .calc import (
    CalcEvaluationError,
    CalcSession,
    CalcSyntaxError,
    ExecutionResult,
    execute,
    format_value,
)


def _banner(version: str = __version__) -> str:
    return (
        f"Nummy {version} kernel-free arbitrary-precision calculator (beta)\n"
        "Limited syntax: number/identifier, + - * / ^, x = expr, %, %%, %n,\n"
        "Mathematica-style precision (1.5`30), function call Name[args].\n"
        "Builtins: LeadingDigits[k, n] for the MathOverflow tower.\n"
        "Press Ctrl+Z (Windows) or Ctrl+D (Unix) to exit.\n"
    )


def run_repl(
    *,
    stdin: Optional[TextIO] = None,
    stdout: Optional[TextIO] = None,
    stderr: Optional[TextIO] = None,
    show_banner: bool = True,
    precision_dps: int = 50,
) -> int:
    """Drive the REPL.

    Returns ``0`` on EOF / clean exit.  ``precision_dps`` sets the active
    mpmath precision for the session (default 50 decimal digits, plenty
    for ordinary calculator work).

    The streams default to ``sys.stdin``/``sys.stdout``/``sys.stderr`` but
    are taken as parameters so the function is straightforward to drive
    from tests.
    """
    in_stream = stdin or sys.stdin
    out_stream = stdout or sys.stdout
    err_stream = stderr or sys.stderr

    from mpmath import mp

    mp.dps = precision_dps
    session = CalcSession()

    if show_banner:
        out_stream.write(_banner())
        out_stream.write("\n")

    while True:
        out_stream.write(f"In[{session.next_line}]:= ")
        out_stream.flush()

        line = in_stream.readline()
        if line == "":
            out_stream.write("\n")
            out_stream.flush()
            return 0

        line = line.rstrip("\r\n")
        if not line.strip():
            out_stream.write("\n")
            continue

        try:
            result = execute(line, session)
        except CalcSyntaxError as exc:
            err_stream.write(f"Syntax::sntx: {exc}\n\n")
            err_stream.flush()
            continue
        except CalcEvaluationError as exc:
            err_stream.write(f"Eval::error: {exc}\n\n")
            err_stream.flush()
            continue

        _emit_result(result, session, out_stream)


def _emit_result(
    result: ExecutionResult, session: CalcSession, stream: TextIO
) -> None:
    messages = session.take_messages()
    if messages:
        stream.write("\n")
        for msg in messages:
            stream.write(msg)
            if not msg.endswith("\n"):
                stream.write("\n")
    if result.empty or result.value is None:
        stream.write("\n")
        stream.flush()
        return
    line_number = len(session.history)  # already advanced
    formatted = format_value(result.value)
    if result.assignment_target is not None:
        stream.write(
            f"\nOut[{line_number}]= {result.assignment_target} = {formatted}\n\n"
        )
    else:
        stream.write(f"\nOut[{line_number}]= {formatted}\n\n")
    stream.flush()


def main(argv: Optional[list] = None) -> int:
    """Console-script entry point.

    Currently ignores ``argv``; reserved for future flags.
    """
    return run_repl()


if __name__ == "__main__":
    raise SystemExit(main())
