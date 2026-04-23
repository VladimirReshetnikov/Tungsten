from __future__ import annotations

import unittest
from pathlib import Path

from tungsten.discovery import discover_installation
from tungsten.notebook import NotebookDocument, apply_patch_spec


SAMPLE_NOTEBOOK = """(* sample header *)
Notebook[{
Cell["Welcome", "Title"],
Cell[CellGroupData[{
Cell["Section A", "Section"],
Cell["Body text", "Text"]
}, Open]],
Cell["2+2", "Input"]
}, WindowTitle->"Sample Notebook"]
"""


class NotebookDocumentTests(unittest.TestCase):
    def test_parse_and_flatten(self) -> None:
        document = NotebookDocument.from_text(SAMPLE_NOTEBOOK)
        summary = document.to_dict()

        self.assertEqual(summary["title"], "Sample Notebook")
        self.assertEqual(summary["group_count"], 1)
        self.assertEqual(summary["cell_count"], 4)
        self.assertEqual(summary["cells"][0]["style"], "Title")
        self.assertEqual(summary["cells"][1]["path"], [1, 0])

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
