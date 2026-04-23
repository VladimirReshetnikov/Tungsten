from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from tungsten.inline_boxes import compose_inline_box_payload
from tungsten.inline_boxes import extract_inline_boxes_from_notebook_cell
from tungsten.notebook import NotebookDocument
from tungsten.notebook import extract_box_expressions
from tungsten.wolfram_strings import inline_box_segments
from tungsten.wolfram_strings import parse_wl_string_literal


SAMPLE_INLINE_BOX_NOTEBOOK = r"""Notebook[{
Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-graphic"],
Cell["prefix \!\(\*StyleBox[\"Hello\", FontWeight->Bold]\) suffix", "Text", CellID->2001]
}]"""


class InlineBoxStringTests(unittest.TestCase):
    def test_parse_wl_string_literal_preserves_inline_box_escape(self) -> None:
        literal = r'"hello \!\(\*GraphicsBox[{CircleBox[]}]\)"'
        decoded = parse_wl_string_literal(literal)

        self.assertEqual(decoded, r"hello \!\(\*GraphicsBox[{CircleBox[]}]\)")
        segments = inline_box_segments(decoded)
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0].box_expression, "GraphicsBox[{CircleBox[]}]")

    def test_extract_box_expressions_from_boxdata_and_inline_string(self) -> None:
        document = NotebookDocument.from_text(SAMPLE_INLINE_BOX_NOTEBOOK)

        graphic_cell = document.item_at_flat_index(0)
        text_cell = document.item_at_flat_index(1)

        self.assertEqual(
            extract_box_expressions(graphic_cell.content_expr),  # type: ignore[attr-defined]
            ["GraphicsBox[{CircleBox[]}]"],
        )
        self.assertEqual(
            extract_box_expressions(text_cell.content_expr),  # type: ignore[attr-defined]
            ['StyleBox["Hello", FontWeight->Bold]'],
        )

    def test_compose_inline_box_payload(self) -> None:
        payload = compose_inline_box_payload(
            box_expressions=["GraphicsBox[{CircleBox[]}]"],
            prefix="icon: ",
            suffix=".",
        )

        self.assertTrue(payload["success"])
        self.assertEqual(payload["box_count"], 1)
        self.assertEqual(payload["string_value"], r"icon: \!\(\*GraphicsBox[{CircleBox[]}]\).")
        self.assertEqual(payload["string_literal"], r'"icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)."')

    def test_extract_inline_boxes_from_notebook_cell(self) -> None:
        with TemporaryDirectory(prefix="tungsten-inline-box-") as temp_dir_name:
            notebook_path = Path(temp_dir_name) / "inline-box.nb"
            notebook_path.write_text(SAMPLE_INLINE_BOX_NOTEBOOK, encoding="utf-8")

            payload = extract_inline_boxes_from_notebook_cell(
                notebook_path=notebook_path,
                expression_uuid="uuid-graphic",
                prefix="icon: ",
            )

        self.assertTrue(payload["success"])
        self.assertEqual(payload["available_box_count"], 1)
        self.assertEqual(payload["selected_boxes"][0]["head"], "GraphicsBox")
        self.assertEqual(payload["string_value"], r"icon: \!\(\*GraphicsBox[{CircleBox[]}]\)")

    def test_extract_all_inline_boxes_from_string_cell(self) -> None:
        with TemporaryDirectory(prefix="tungsten-inline-box-") as temp_dir_name:
            notebook_path = Path(temp_dir_name) / "inline-box.nb"
            notebook_path.write_text(SAMPLE_INLINE_BOX_NOTEBOOK, encoding="utf-8")

            payload = extract_inline_boxes_from_notebook_cell(
                notebook_path=notebook_path,
                cell_id=2001,
                all_objects=True,
                prefix="rendered: ",
            )

        self.assertTrue(payload["success"])
        self.assertEqual(payload["selected_box_count"], 1)
        self.assertEqual(payload["selected_boxes"][0]["head"], "StyleBox")
        self.assertIn(r'\!\(\*StyleBox["Hello", FontWeight->Bold]\)', payload["string_value"])


if __name__ == "__main__":
    unittest.main()
