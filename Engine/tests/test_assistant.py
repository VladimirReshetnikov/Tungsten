from __future__ import annotations

import unittest
from pathlib import Path

from tungsten.assistant import NotebookAssistantController


class NotebookAssistantControllerTests(unittest.TestCase):
    def test_extract_assistant_text_and_code_blocks(self) -> None:
        controller = NotebookAssistantController()
        raw = (
            'ChatObject[<|"Messages" -> {'
            '<|"Role" -> "System", "Content" -> {<|"Type" -> "Text", "Data" -> "ignore"|>}, "Metadata" -> <||>|>, '
            '<|"Role" -> "Assistant", "Content" -> {<|"Type" -> "Text", "Data" -> "```wolfram\\\\n2 + 2\\\\n```"|>}, "Metadata" -> <||>|>'
            '}|>]'
        )

        response_text = controller._extract_assistant_text(raw)
        self.assertEqual(response_text, "```wolfram\n2 + 2\n```")

        blocks = controller._extract_code_blocks(response_text)
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0]["language"], "wolfram")
        self.assertEqual(blocks[0]["code"], "2 + 2")
        self.assertTrue(blocks[0]["insertable"])

    def test_finalize_ask_cell_payload_without_insertion(self) -> None:
        controller = NotebookAssistantController()
        payload = {
            "success": True,
            "source_cell": {
                "expression_uuid": "abc",
            },
            "assistant_chat_object_string": (
                'ChatObject[<|"Messages" -> {'
                '<|"Role" -> "Assistant", "Content" -> {<|"Type" -> "Text", "Data" -> "```wolfram\\\\n2 + 2\\\\n```"|>}, "Metadata" -> <||>|>'
                '}|>]'
            ),
        }

        finalized = controller._finalize_ask_cell_payload(
            payload=payload,
            notebook_path=Path("C:/Temp/example.nb"),
            source_row={
                "index": 0,
                "path": [0],
                "expression_uuid": "abc",
                "cell_tags": [],
            },
            insert_mode="none",
            save_notebook=False,
        )

        self.assertTrue(finalized["success"])
        self.assertEqual(finalized["response_text"], "```wolfram\n2 + 2\n```")
        self.assertEqual(len(finalized["wolfram_code_blocks"]), 1)
        self.assertEqual(finalized["inserted"], [])
        self.assertFalse(finalized["saved_notebook"])
        self.assertNotIn("assistant_chat_object_string", finalized)


if __name__ == "__main__":
    unittest.main()
