"""Command-line interface for the Nummy alpha package."""

from __future__ import annotations

import argparse
import sys

from .calculator import DEFAULT_CALCULATOR_PRECISION
from .mo import main as mathoverflow_main
from .repl import run_repl


def _positive_int(text: str) -> int:
    try:
        value = int(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def _add_precision_argument(parser: argparse.ArgumentParser, *, dest: str) -> None:
    parser.add_argument(
        "--precision",
        type=_positive_int,
        default=None,
        dest=dest,
        help=(
            "Default decimal output precision for the calculator "
            f"(default: {DEFAULT_CALCULATOR_PRECISION})."
        ),
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nummy")
    _add_precision_argument(parser, dest="precision")
    subparsers = parser.add_subparsers(dest="command")

    repl_parser = subparsers.add_parser(
        "repl",
        help="Start the Nummy alpha calculator REPL.",
    )
    repl_parser.add_argument(
        "--no-banner",
        action="store_true",
        help="Suppress the startup banner.",
    )
    _add_precision_argument(repl_parser, dest="repl_precision")

    subparsers.add_parser(
        "mo",
        help="Print the archived MathOverflow power-tower integer-part calculation.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    effective_argv = sys.argv[1:] if argv is None else argv
    args = _build_parser().parse_args(effective_argv)
    default_precision = args.precision or DEFAULT_CALCULATOR_PRECISION
    if args.command is None:
        return run_repl(default_precision=default_precision)
    if args.command == "repl":
        return run_repl(
            show_banner=not args.no_banner,
            default_precision=args.repl_precision or default_precision,
        )
    if args.command == "mo":
        mathoverflow_main()
        return 0
    _build_parser().print_help()
    return 2
