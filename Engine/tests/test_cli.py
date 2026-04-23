from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from tungsten.cli import main


class CliTests(unittest.TestCase):
    def test_create_and_inspect_notebook(self) -> None:
        with TemporaryDirectory(prefix="tungsten-cli-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            notebook_path = temp_dir / "cli-test.nb"

            create_stdout = io.StringIO()
            with redirect_stdout(create_stdout):
                exit_code = main(
                    [
                        "notebook",
                        "create",
                        "--file",
                        str(notebook_path),
                        "--title",
                        "CLI Notebook",
                        "--cell",
                        "Text:Hello from the CLI",
                    ]
                )

            self.assertEqual(exit_code, 0)
            self.assertTrue(notebook_path.exists())

            inspect_stdout = io.StringIO()
            with redirect_stdout(inspect_stdout):
                exit_code = main(
                    [
                        "notebook",
                        "inspect",
                        "--file",
                        str(notebook_path),
                    ]
                )

            self.assertEqual(exit_code, 0)
            payload = json.loads(inspect_stdout.getvalue())
            self.assertEqual(payload["title"], "CLI Notebook")
            self.assertEqual(payload["cell_count"], 1)

    def test_assistant_command_uses_controller(self) -> None:
        with TemporaryDirectory(prefix="tungsten-cli-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            notebook_path = temp_dir / "assistant.nb"
            notebook_path.write_text('Notebook[{Cell["Hello", "Text"]}]', encoding="utf-8")

            with patch("tungsten.cli.NotebookAssistantController") as controller_type:
                controller = controller_type.return_value
                controller.ask_cell.return_value.to_dict.return_value = {
                    "assistant_success": True,
                    "assistant": {
                        "success": True,
                        "response_text": "Sample response",
                        "inserted": [],
                    },
                    "evaluation": {"success": True},
                }
                controller.ask_cell.return_value.assistant_success = True

                stdout = io.StringIO()
                with redirect_stdout(stdout):
                    exit_code = main(
                        [
                            "assistant",
                            "ask-cell",
                            "--file",
                            str(notebook_path),
                            "--cell-index",
                            "0",
                            "--question",
                            "What does this cell do?",
                            "--insert-wolfram-code-below",
                        ]
                    )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["assistant_success"])
        controller.ask_cell.assert_called_once()

    def test_assistant_prepare_inline_uses_controller(self) -> None:
        with TemporaryDirectory(prefix="tungsten-cli-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            notebook_path = temp_dir / "assistant-inline.nb"
            notebook_path.write_text('Notebook[{Cell["Hello", "Text"]}]', encoding="utf-8")

            with patch("tungsten.cli.NotebookAssistantController") as controller_type:
                controller = controller_type.return_value
                controller.prepare_inline.return_value.to_dict.return_value = {
                    "assistant_success": True,
                    "assistant": {
                        "success": True,
                        "window_title": "Assistant Notebook",
                    },
                    "evaluation": {"success": True},
                }
                controller.prepare_inline.return_value.assistant_success = True

                stdout = io.StringIO()
                with redirect_stdout(stdout):
                    exit_code = main(
                        [
                            "assistant",
                            "prepare-inline",
                            "--file",
                            str(notebook_path),
                            "--cell-index",
                            "0",
                        ]
                    )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["assistant_success"])
        controller.prepare_inline.assert_called_once()

    def test_assistant_capture_inline_uses_controller(self) -> None:
        with TemporaryDirectory(prefix="tungsten-cli-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            notebook_path = temp_dir / "assistant-inline.nb"
            notebook_path.write_text('Notebook[{Cell["Hello", "Text"]}]', encoding="utf-8")

            with patch("tungsten.cli.NotebookAssistantController") as controller_type:
                controller = controller_type.return_value
                controller.capture_inline.return_value.to_dict.return_value = {
                    "assistant_success": True,
                    "assistant": {
                        "success": True,
                        "completed": True,
                        "inserted": [{"expression_uuid": "abc"}],
                    },
                    "evaluation": {"success": True},
                }
                controller.capture_inline.return_value.assistant_success = True

                stdout = io.StringIO()
                with redirect_stdout(stdout):
                    exit_code = main(
                        [
                            "assistant",
                            "capture-inline",
                            "--file",
                            str(notebook_path),
                            "--cell-index",
                            "0",
                            "--insert-wolfram-code-below",
                            "--save",
                        ]
                    )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["assistant_success"])
        controller.capture_inline.assert_called_once()

    def test_expr_parse_command(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = main(
                [
                    "expr",
                    "parse",
                    "--code",
                    "1 + 2 x^3",
                    "--form",
                    "input",
                ]
            )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["full_form"], "Plus[1, Times[2, Power[x, 3]]]")
        self.assertEqual(payload["depth"], 4)

    def test_expr_evaluate_command(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = main(
                [
                    "expr",
                    "evaluate",
                    "--code",
                    "Level[f[a, g[b]], -1]",
                    "--form",
                    "input",
                ]
            )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["result"]["full_form"], "List[a, b]")

    def test_inline_box_compose_command(self) -> None:
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            exit_code = main(
                [
                    "inline-box",
                    "compose",
                    "--prefix",
                    "icon: ",
                    "--box-expr",
                    "GraphicsBox[{CircleBox[]}]",
                ]
            )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["success"])
        self.assertEqual(payload["box_count"], 1)
        self.assertEqual(payload["boxes"][0]["head"], "GraphicsBox")

    def test_inline_box_from_cell_command(self) -> None:
        with TemporaryDirectory(prefix="tungsten-cli-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            notebook_path = temp_dir / "inline-box.nb"
            notebook_path.write_text(
                'Notebook[{Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-graphic"]}]',
                encoding="utf-8",
            )

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                exit_code = main(
                    [
                        "inline-box",
                        "from-cell",
                        "--file",
                        str(notebook_path),
                        "--expression-uuid",
                        "uuid-graphic",
                        "--prefix",
                        "icon: ",
                    ]
                )

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["success"])
        self.assertEqual(payload["selected_boxes"][0]["head"], "GraphicsBox")
        self.assertEqual(payload["string_value"], r"icon: \!\(\*GraphicsBox[{CircleBox[]}]\)")


if __name__ == "__main__":
    unittest.main()
