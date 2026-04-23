from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .assistant import NotebookAssistantController
from .discovery import discover_installation
from .docs_index import DocumentationIndex
from .expression import depth as expression_depth
from .expression import evaluate as evaluate_expression
from .expression import length as expression_length
from .expression import parse_expression
from .expression import WolframEvaluationError
from .expression import WolframSyntaxError
from .frontend import FrontEndController
from .inline_boxes import compose_inline_box_payload
from .inline_boxes import extract_inline_boxes_from_notebook_cell
from .kernel import WolframKernelRunner
from .notebook import NotebookDocument, apply_patch_spec, load_patch_spec, wl_string


def _json_dump(payload: object) -> None:
    sys.stdout.write(json.dumps(payload, indent=2))
    sys.stdout.write("\n")


def _expr_error_payload(
    *,
    command: str,
    form: str,
    source: str,
    error: Exception,
    parsed: object | None = None,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "command": command,
        "form": form,
        "source": source,
        "success": False,
        "error_type": type(error).__name__,
        "error": str(error),
    }
    if parsed is not None:
        payload["parsed_input_form"] = parsed.to_input_form()
        payload["parsed_full_form"] = parsed.to_full_form()
        payload["parsed_tree"] = parsed.to_dict()
    return payload


def _parse_cell_path(value: str) -> list[int]:
    text = value.strip()
    if text.startswith("[") and text.endswith("]"):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise argparse.ArgumentTypeError(f"Invalid JSON cell path: {value!r}") from exc
        if not isinstance(parsed, list) or not all(isinstance(item, int) for item in parsed):
            raise argparse.ArgumentTypeError("JSON cell paths must be arrays of integers.")
        return [int(item) for item in parsed]

    parts = [part.strip() for part in text.split(",") if part.strip()]
    if not parts:
        raise argparse.ArgumentTypeError("Cell paths must contain at least one integer.")

    try:
        return [int(part) for part in parts]
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Invalid cell path: {value!r}") from exc


def _add_cell_selector_arguments(parser: argparse.ArgumentParser) -> None:
    selector_group = parser.add_mutually_exclusive_group(required=True)
    selector_group.add_argument("--cell-index", type=int, help="Flat cell index from notebook inspect output.")
    selector_group.add_argument(
        "--cell-path",
        type=_parse_cell_path,
        help='Notebook cell path from inspect output, for example "1,0" or "[1, 0]".',
    )
    selector_group.add_argument("--expression-uuid", help="Notebook cell ExpressionUUID.")
    selector_group.add_argument("--cell-id", type=int, help="Notebook CellID value.")
    selector_group.add_argument("--cell-tag", help="Notebook cell tag.")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tungsten")
    subparsers = parser.add_subparsers(dest="command", required=True)

    env_parser = subparsers.add_parser("env", help="Inspect the local Tungsten/Wolfram environment.")
    env_subparsers = env_parser.add_subparsers(dest="env_command", required=True)
    env_show = env_subparsers.add_parser("show", help="Show discovered paths and optional live probes.")
    env_show.add_argument("--probe", action="store_true", help="Run live kernel and FrontEnd probes.")

    kernel_parser = subparsers.add_parser("kernel", help="Run Wolfram Language code through the local kernel.")
    kernel_subparsers = kernel_parser.add_subparsers(dest="kernel_command", required=True)
    kernel_eval = kernel_subparsers.add_parser("eval", help="Evaluate code or a file.")
    kernel_eval_group = kernel_eval.add_mutually_exclusive_group(required=True)
    kernel_eval_group.add_argument("--code", help="Inline Wolfram Language code to evaluate.")
    kernel_eval_group.add_argument("--file", type=Path, help="A file containing Wolfram Language code.")
    kernel_eval.add_argument(
        "--working-directory",
        type=Path,
        help="Working directory used during evaluation.",
    )
    kernel_eval.add_argument(
        "--front-end",
        action="store_true",
        help="Evaluate inside UsingFrontEnd.",
    )
    kernel_eval.add_argument(
        "--require-success",
        action="store_true",
        help="Return exit code 1 when the evaluation reports Success -> False.",
    )

    notebook_parser = subparsers.add_parser("notebook", help="Inspect or edit notebook files.")
    notebook_subparsers = notebook_parser.add_subparsers(dest="notebook_command", required=True)
    notebook_inspect = notebook_subparsers.add_parser("inspect", help="Inspect a notebook file.")
    notebook_inspect.add_argument("--file", type=Path, required=True)

    notebook_create = notebook_subparsers.add_parser("create", help="Create a notebook file.")
    notebook_create.add_argument("--file", type=Path, required=True)
    notebook_create.add_argument("--title", help="Notebook window title.")
    notebook_create.add_argument(
        "--cell",
        action="append",
        default=[],
        help="Cell specification in the form STYLE:TEXT. May be repeated.",
    )

    notebook_patch = notebook_subparsers.add_parser("patch", help="Apply a JSON patch spec to a notebook.")
    notebook_patch.add_argument("--file", type=Path, required=True)
    notebook_patch.add_argument("--spec", type=Path, required=True)
    notebook_patch.add_argument("--out", type=Path, help="Optional output file. Defaults to in-place.")

    expr_parser = subparsers.add_parser("expr", help="Parse and structurally evaluate Wolfram expressions.")
    expr_subparsers = expr_parser.add_subparsers(dest="expr_command", required=True)

    expr_parse = expr_subparsers.add_parser("parse", help="Parse a Wolfram expression without a kernel.")
    expr_parse_group = expr_parse.add_mutually_exclusive_group(required=True)
    expr_parse_group.add_argument("--code", help="Inline Wolfram expression text.")
    expr_parse_group.add_argument("--file", type=Path, help="A file containing a Wolfram expression.")
    expr_parse.add_argument(
        "--form",
        choices=["input", "fullform", "standard"],
        default="input",
        help="Syntax form to parse.",
    )

    expr_eval = expr_subparsers.add_parser(
        "evaluate",
        help="Structurally evaluate built-ins such as Length, Take, Flatten, ReplacePart, and MapAt.",
    )
    expr_eval_group = expr_eval.add_mutually_exclusive_group(required=True)
    expr_eval_group.add_argument("--code", help="Inline Wolfram expression text.")
    expr_eval_group.add_argument("--file", type=Path, help="A file containing a Wolfram expression.")
    expr_eval.add_argument(
        "--form",
        choices=["input", "fullform", "standard"],
        default="input",
        help="Syntax form to parse before evaluation.",
    )

    docs_parser = subparsers.add_parser("docs", help="Search and read the local Wolfram documentation corpus.")
    docs_subparsers = docs_parser.add_subparsers(dest="docs_command", required=True)
    docs_index = docs_subparsers.add_parser("index", help="Build or rebuild the local documentation index.")
    docs_index.add_argument("--path", type=Path, help="Index destination path.")

    docs_search = docs_subparsers.add_parser("search", help="Search the documentation index.")
    docs_search.add_argument("query")
    docs_search.add_argument("--limit", type=int, default=10)
    docs_search.add_argument("--index-path", type=Path)
    docs_search.add_argument("--rebuild", action="store_true")

    docs_read = docs_subparsers.add_parser("read", help="Read a documentation page.")
    docs_read.add_argument("identifier")
    docs_read.add_argument("--index-path", type=Path)
    docs_read.add_argument("--rebuild", action="store_true")

    docs_open = docs_subparsers.add_parser("open", help="Open a documentation page in the FrontEnd.")
    docs_open.add_argument("identifier")
    docs_open.add_argument("--index-path", type=Path)

    frontend_parser = subparsers.add_parser("frontend", help="Programmatically drive FrontEnd actions.")
    frontend_subparsers = frontend_parser.add_subparsers(dest="frontend_command", required=True)
    fe_probe = frontend_subparsers.add_parser("probe", help="Run a hidden FrontEnd availability probe.")
    fe_probe.add_argument("--require-success", action="store_true")

    fe_open_nb = frontend_subparsers.add_parser("open-notebook", help="Open a notebook in the FrontEnd.")
    fe_open_nb.add_argument("--file", type=Path, required=True)
    fe_open_nb.add_argument("--require-success", action="store_true")

    fe_open_doc = frontend_subparsers.add_parser("open-doc", help="Open documentation in the FrontEnd.")
    fe_open_doc.add_argument("identifier")
    fe_open_doc.add_argument("--index-path", type=Path)
    fe_open_doc.add_argument("--require-success", action="store_true")

    fe_run = frontend_subparsers.add_parser("run", help="Run arbitrary FrontEnd-targeted Wolfram code.")
    fe_run.add_argument("--code", required=True)
    fe_run.add_argument("--no-wrap", action="store_true", help="Do not wrap the code in UsingFrontEnd.")
    fe_run.add_argument("--require-success", action="store_true")

    fe_token = frontend_subparsers.add_parser("token", help="Execute a FrontEnd token.")
    fe_token.add_argument("token")
    fe_token.add_argument("--file", type=Path)
    fe_token.add_argument("--require-success", action="store_true")

    assistant_parser = subparsers.add_parser(
        "assistant",
        help="Drive the built-in Notebook Assistant against a notebook cell.",
    )
    assistant_subparsers = assistant_parser.add_subparsers(dest="assistant_command", required=True)
    assistant_ask = assistant_subparsers.add_parser(
        "ask-cell",
        help="Ask Notebook Assistant about a selected cell and optionally insert Wolfram Language code below it.",
    )
    assistant_ask.add_argument("--file", type=Path, required=True)
    _add_cell_selector_arguments(assistant_ask)
    assistant_ask.add_argument("--question", required=True)
    assistant_ask.add_argument(
        "--insert-wolfram-code-below",
        action="store_true",
        help="Insert the first Wolfram Language code block from the assistant response below the target cell.",
    )
    assistant_ask.add_argument(
        "--insert-all-wolfram-code-below",
        action="store_true",
        help="Insert every Wolfram Language code block from the assistant response below the target cell.",
    )
    assistant_ask.add_argument("--save", action="store_true", help="Save the notebook after insertion.")
    assistant_ask.add_argument(
        "--close-assistant-notebook",
        action="store_true",
        help="Close the temporary Notebook Assistant window after the request finishes.",
    )
    assistant_ask.add_argument(
        "--extra-instructions",
        help="Additional instructions appended to the assistant automation prompt.",
    )
    assistant_ask.add_argument(
        "--model-service",
        help="Optional service override passed to Notebook Assistant, for example OpenAI.",
    )
    assistant_ask.add_argument(
        "--model-name",
        help="Optional model name override passed to Notebook Assistant.",
    )
    assistant_ask.add_argument("--require-success", action="store_true")

    assistant_prepare = assistant_subparsers.add_parser(
        "prepare-inline",
        help="Open inline Notebook Assistant for a selected cell and focus its input field.",
    )
    assistant_prepare.add_argument("--file", type=Path, required=True)
    _add_cell_selector_arguments(assistant_prepare)
    assistant_prepare.add_argument("--require-success", action="store_true")

    assistant_capture = assistant_subparsers.add_parser(
        "capture-inline",
        help="Read the current inline Notebook Assistant state and optionally insert Wolfram code below the source cell.",
    )
    assistant_capture.add_argument("--file", type=Path, required=True)
    _add_cell_selector_arguments(assistant_capture)
    assistant_capture.add_argument(
        "--insert-wolfram-code-below",
        action="store_true",
        help="Insert the first Wolfram Language code block from the assistant response below the target cell.",
    )
    assistant_capture.add_argument(
        "--insert-all-wolfram-code-below",
        action="store_true",
        help="Insert every Wolfram Language code block from the assistant response below the target cell.",
    )
    assistant_capture.add_argument("--save", action="store_true", help="Save the notebook after insertion.")
    assistant_capture.add_argument("--require-success", action="store_true")

    inline_box_parser = subparsers.add_parser(
        "inline-box",
        help="Compose or extract Wolfram string literals that contain embedded inline box escapes.",
    )
    inline_box_subparsers = inline_box_parser.add_subparsers(dest="inline_box_command", required=True)

    inline_box_compose = inline_box_subparsers.add_parser(
        "compose",
        help="Build a Wolfram string literal from prefix/suffix text plus box expressions.",
    )
    inline_box_compose.add_argument("--prefix", default="")
    inline_box_compose.add_argument("--box-expr", action="append", default=[])
    inline_box_compose.add_argument("--suffix", default="")

    inline_box_from_cell = inline_box_subparsers.add_parser(
        "from-cell",
        help="Extract inline box objects from a notebook cell and compose a ready-to-use string literal.",
    )
    inline_box_from_cell.add_argument("--file", type=Path, required=True)
    _add_cell_selector_arguments(inline_box_from_cell)
    inline_box_from_cell.add_argument("--prefix", default="")
    inline_box_from_cell.add_argument("--suffix", default="")
    inline_box_from_cell.add_argument("--object-index", type=int, default=0)
    inline_box_from_cell.add_argument("--all-objects", action="store_true")
    inline_box_from_cell.add_argument("--require-success", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    installation = discover_installation()

    if args.command == "env":
        payload: dict[str, object] = installation.to_dict()
        if args.probe:
            runner = WolframKernelRunner(installation)
            payload["probe"] = runner.probe()
        _json_dump(payload)
        return 0

    if args.command == "kernel":
        runner = WolframKernelRunner(installation)
        if args.code is not None:
            result = runner.evaluate_text(
                args.code,
                working_directory=args.working_directory,
                require_front_end=args.front_end,
            )
        else:
            result = runner.evaluate_file(
                args.file,
                working_directory=args.working_directory,
                require_front_end=args.front_end,
            )

        _json_dump(result.to_dict())
        if args.require_success and result.success is False:
            return 1
        return 0 if result.evaluation_available else 2

    if args.command == "notebook":
        if args.notebook_command == "inspect":
            document = NotebookDocument.load(args.file)
            _json_dump(document.to_dict())
            return 0

        if args.notebook_command == "create":
            document = NotebookDocument(items=[], options=[])
            if args.title:
                document.set_option("WindowTitle", wl_string(args.title))
            for cell_spec in args.cell:
                style, separator, text = cell_spec.partition(":")
                if not separator:
                    raise ValueError(f"Invalid cell specification: {cell_spec!r}")
                document.append_cell(text=text, style=style)
            document.save(args.file)
            _json_dump(document.to_dict())
            return 0

        if args.notebook_command == "patch":
            document = NotebookDocument.load(args.file)
            spec = load_patch_spec(args.spec)
            apply_patch_spec(document, spec)
            destination = args.out or args.file
            document.save(destination)
            _json_dump(document.to_dict())
            return 0

    if args.command == "expr":
        source_text = args.code if args.code is not None else args.file.read_text(encoding="utf-8")
        try:
            parsed = parse_expression(source_text, form=args.form)
        except WolframSyntaxError as exc:
            _json_dump(
                _expr_error_payload(
                    command=args.expr_command,
                    form=args.form,
                    source=source_text,
                    error=exc,
                )
            )
            return 1

        if args.expr_command == "parse":
            _json_dump(
                {
                    "command": "parse",
                    "form": args.form,
                    "source": source_text,
                    "input_form": parsed.to_input_form(),
                    "full_form": parsed.to_full_form(),
                    "depth": expression_depth(parsed),
                    "length": expression_length(parsed),
                    "tree": parsed.to_dict(),
                }
            )
            return 0

        if args.expr_command == "evaluate":
            try:
                result = evaluate_expression(parsed)
            except WolframEvaluationError as exc:
                _json_dump(
                    _expr_error_payload(
                        command="evaluate",
                        form=args.form,
                        source=source_text,
                        error=exc,
                        parsed=parsed,
                    )
                )
                return 1
            _json_dump(
                {
                    "command": "evaluate",
                    "form": args.form,
                    "source": source_text,
                    "parsed_input_form": parsed.to_input_form(),
                    "parsed_full_form": parsed.to_full_form(),
                    "result": {
                        "input_form": result.to_input_form(),
                        "full_form": result.to_full_form(),
                        "depth": expression_depth(result),
                        "length": expression_length(result),
                        "tree": result.to_dict(),
                    },
                }
            )
            return 0

    if args.command == "inline-box":
        if args.inline_box_command == "compose":
            _json_dump(
                compose_inline_box_payload(
                    box_expressions=[str(item) for item in args.box_expr],
                    prefix=args.prefix,
                    suffix=args.suffix,
                )
            )
            return 0

        if args.inline_box_command == "from-cell":
            payload = extract_inline_boxes_from_notebook_cell(
                notebook_path=args.file,
                cell_index=args.cell_index,
                cell_path=args.cell_path,
                expression_uuid=args.expression_uuid,
                cell_id=args.cell_id,
                cell_tag=args.cell_tag,
                prefix=args.prefix,
                suffix=args.suffix,
                object_index=args.object_index,
                all_objects=args.all_objects,
            )
            _json_dump(payload)
            if args.require_success and payload.get("success") is False:
                return 1
            return 0

    if args.command == "docs":
        index = DocumentationIndex(installation)
        if args.docs_command == "index":
            path = index.build_index(args.path)
            _json_dump({"index_path": str(path)})
            return 0

        if args.docs_command == "search":
            hits = index.search(
                args.query,
                index_path=args.index_path,
                limit=args.limit,
                rebuild=args.rebuild,
            )
            _json_dump({"hits": hits})
            return 0

        if args.docs_command == "read":
            record = index.read(
                args.identifier,
                index_path=args.index_path,
                rebuild=args.rebuild,
            )
            _json_dump(record)
            return 0

        if args.docs_command == "open":
            controller = FrontEndController(
                runner=WolframKernelRunner(installation),
                docs_index=index,
            )
            result = controller.open_documentation(
                args.identifier,
                index_path=args.index_path,
            )
            _json_dump(result.to_dict())
            return 0

    if args.command == "frontend":
        controller = FrontEndController(
            runner=WolframKernelRunner(installation),
            docs_index=DocumentationIndex(installation),
        )
        if args.frontend_command == "probe":
            payload = controller.probe()
            _json_dump(payload)
            if args.require_success and payload.get("success") is False:
                return 1
            return 0

        if args.frontend_command == "open-notebook":
            result = controller.open_notebook(args.file)
            _json_dump(result.to_dict())
            if args.require_success and result.success is False:
                return 1
            return 0

        if args.frontend_command == "open-doc":
            result = controller.open_documentation(
                args.identifier,
                index_path=args.index_path,
            )
            _json_dump(result.to_dict())
            if args.require_success and result.success is False:
                return 1
            return 0

        if args.frontend_command == "run":
            result = controller.run(args.code, wrap_using_front_end=not args.no_wrap)
            _json_dump(result.to_dict())
            if args.require_success and result.success is False:
                return 1
            return 0

        if args.frontend_command == "token":
            result = controller.execute_token(args.token, notebook_path=args.file)
            _json_dump(result.to_dict())
            if args.require_success and result.success is False:
                return 1
            return 0

    if args.command == "assistant":
        controller = NotebookAssistantController(runner=WolframKernelRunner(installation))
        if args.assistant_command == "ask-cell":
            result = controller.ask_cell(
                notebook_path=args.file,
                question=args.question,
                cell_index=args.cell_index,
                cell_path=args.cell_path,
                expression_uuid=args.expression_uuid,
                cell_id=args.cell_id,
                cell_tag=args.cell_tag,
                insert_wolfram_code=args.insert_wolfram_code_below,
                insert_all_wolfram_code=args.insert_all_wolfram_code_below,
                save_notebook=args.save,
                close_assistant_notebook=args.close_assistant_notebook,
                extra_instructions=args.extra_instructions,
                model_service=args.model_service,
                model_name=args.model_name,
            )
            payload = result.to_dict()
            _json_dump(payload)
            if args.require_success and not result.assistant_success:
                return 1
            return 0

        if args.assistant_command == "prepare-inline":
            result = controller.prepare_inline(
                notebook_path=args.file,
                cell_index=args.cell_index,
                cell_path=args.cell_path,
                expression_uuid=args.expression_uuid,
                cell_id=args.cell_id,
                cell_tag=args.cell_tag,
            )
            payload = result.to_dict()
            _json_dump(payload)
            if args.require_success and not result.assistant_success:
                return 1
            return 0

        if args.assistant_command == "capture-inline":
            result = controller.capture_inline(
                notebook_path=args.file,
                cell_index=args.cell_index,
                cell_path=args.cell_path,
                expression_uuid=args.expression_uuid,
                cell_id=args.cell_id,
                cell_tag=args.cell_tag,
                insert_wolfram_code=args.insert_wolfram_code_below,
                insert_all_wolfram_code=args.insert_all_wolfram_code_below,
                save_notebook=args.save,
            )
            payload = result.to_dict()
            _json_dump(payload)
            if args.require_success and not result.assistant_success:
                return 1
            return 0

    raise RuntimeError(f"Unhandled command: {args.command!r}")
