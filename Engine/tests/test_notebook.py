from __future__ import annotations

import json
import unittest
from pathlib import Path

from tungsten.discovery import discover_installation
from tungsten.notebook import NotebookDocument, SourceSpan, apply_patch_spec, parse_call


SAMPLE_NOTEBOOK = """(* sample header *)
Notebook[{
Cell["Welcome", "Title", CellID->1001, ExpressionUUID->"uuid-title", CellTags->{"intro", "top"}],
Cell[CellGroupData[{
Cell["Section A", "Section"],
Cell["Body text", "Text"]
}, Open]],
Cell["2+2", "Input"]
}, WindowTitle->"Sample Notebook"]
"""


class NotebookDocumentTests(unittest.TestCase):
    def test_parse_call_splits_arguments_in_one_pass_without_losing_edge_cases(self) -> None:
        head, args = parse_call('f[a, g[1, 2], {x, y}, "literal, comma", (* comment, *) h]')

        self.assertEqual(head, "f")
        self.assertEqual(args, ["a", "g[1, 2]", "{x, y}", '"literal, comma"', "(* comment, *) h"])
        self.assertEqual(parse_call("f[]"), ("f", []))
        self.assertEqual(parse_call("f[a,]"), ("f", ["a"]))
        self.assertEqual(parse_call("f[,a]"), ("f", ["", "a"]))
        self.assertEqual(parse_call("f[a] trailing"), ("f[a] trailing", []))

    def test_parse_and_flatten(self) -> None:
        document = NotebookDocument.from_text(SAMPLE_NOTEBOOK)
        summary = document.to_dict()

        self.assertEqual(summary["title"], "Sample Notebook")
        self.assertEqual(summary["group_count"], 1)
        self.assertEqual(summary["cell_count"], 4)
        self.assertEqual(summary["cells"][0]["style"], "Title")
        self.assertEqual(summary["cells"][0]["index"], 0)
        self.assertEqual(summary["cells"][0]["cell_id"], 1001)
        self.assertEqual(summary["cells"][0]["expression_uuid"], "uuid-title")
        self.assertEqual(summary["cells"][0]["cell_tags"], ["intro", "top"])
        self.assertEqual(summary["cells"][1]["path"], [1, 0])
        self.assertEqual(document.cell_at_flat_index(1)["path"], [1, 0])
        self.assertEqual(document.cell_at_path([1, 1])["preview"], "Body text")

    def test_notebook_parser_keeps_public_text_api_over_span_internals(self) -> None:
        document = NotebookDocument.from_text(SAMPLE_NOTEBOOK)
        cell = document.item_at_flat_index(0)

        self.assertIsInstance(cell.content_expr, str)  # type: ignore[attr-defined]
        self.assertIsInstance(cell.options[0], str)  # type: ignore[attr-defined]
        self.assertIsInstance(cell._content_expr, SourceSpan)  # type: ignore[attr-defined]
        self.assertEqual(document.summary()["cell_count"], 4)
        json.dumps(document.to_dict())

    def test_patch_operations(self) -> None:
        document = NotebookDocument.from_text(SAMPLE_NOTEBOOK)
        spec = {
            "operations": [
                {"op": "append_cell", "style": "Text", "text": "Tail cell"},
                {"op": "replace_cell", "path": [2], "style": "Input", "text": "Expand[2 (a+b)]"},
                {"op": "set_option", "name": "WindowTitle", "value_expr": "\"Patched Notebook\""},
            ]
        }

        apply_patch_spec(document, spec)
        summary = document.to_dict()

        self.assertEqual(summary["title"], "Patched Notebook")
        self.assertEqual(summary["cell_count"], 5)
        self.assertEqual(summary["cells"][-1]["preview"], "Tail cell")
        self.assertEqual(summary["cells"][3]["preview"], "Expand[2 (a+b)]")

    def test_inline_box_string_preview_collapses_to_placeholder(self) -> None:
        document = NotebookDocument.from_text(
            'Notebook[{Cell["hello \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)", "Text"]}]'
        )

        summary = document.to_dict()
        self.assertEqual(summary["cells"][0]["preview"], "hello [InlineBox]")

    def test_real_documentation_notebook_parses(self) -> None:
        installation = discover_installation()
        if not installation.docs_roots:
            self.skipTest("No local Wolfram documentation roots were discovered.")

        notebook_path = installation.docs_roots[0] / "ReferencePages" / "Symbols" / "NotebookGet.nb"
        if not notebook_path.exists():
            self.skipTest(f"Documentation notebook not present: {notebook_path}")

        document = NotebookDocument.load(notebook_path)
        summary = document.to_dict()

        self.assertEqual(summary["title"], "NotebookGet")
        self.assertGreater(summary["cell_count"], 10)


if __name__ == "__main__":
    unittest.main()
