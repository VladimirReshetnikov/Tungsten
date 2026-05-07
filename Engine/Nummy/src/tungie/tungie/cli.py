from __future__ import annotations

import argparse
import sys

from .errors import TungieEvaluationError
from .errors import TungieExitRequested
from .errors import TungieSyntaxError
from .evaluator import EvaluationSession
from .parser import parse
from .repl import run_repl


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tungie")
    subparsers = parser.add_subparsers(dest="command")

    repl_parser = subparsers.add_parser("repl", help="start the Tungie calculator REPL")
    repl_parser.add_argument("--no-banner", action="store_true", help="suppress the startup banner")

    eval_parser = subparsers.add_parser("eval", help="evaluate one expression and print the result")
    eval_parser.add_argument("source", nargs="+", help="expression text")

    args = parser.parse_args(argv)
    if args.command is None or args.command == "repl":
        return run_repl(show_banner=not getattr(args, "no_banner", False))
    if args.command == "eval":
        source = " ".join(args.source)
        session = EvaluationSession()
        try:
            _line, result = session.evaluate_input(parse(source))
        except TungieSyntaxError as exc:
            print(f"Syntax::sntxi: {exc}", file=sys.stderr)
            return 2
        except TungieEvaluationError as exc:
            print(f"Evaluate::error: {exc}", file=sys.stderr)
            return 1
        except TungieExitRequested as exc:
            return exc.code
        assert session.current_messages is not None
        for message in session.current_messages:
            print(message, file=sys.stderr)
        print(result.to_input_form())
        return 0
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
