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

    def test_finalize_ask_payload_strips_chat_object(self) -> None:
        """`ask` (bare-prompt) returns response_text + code_blocks and
        drops the raw chat object string, mirroring ask-cell without
        the source-cell / notebook-insertion plumbing."""
        controller = NotebookAssistantController()
        payload = {
            "success": True,
            "prompt": "How do I integrate Log[t]/(1 - t) from 0 to 1?",
            "assistant_chat_object_string": (
                'ChatObject[<|"Messages" -> {'
                '<|"Role" -> "Assistant", "Content" -> {<|"Type" -> "Text", '
                '"Data" -> "Use Integrate.\\\\n```wolfram\\\\nIntegrate[Log[t]/(1-t), {t,0,1}]\\\\n```"|>}, '
                '"Metadata" -> <||>|>'
                '}|>]'
            ),
        }

        finalized = controller._finalize_ask_payload(payload=payload)

        self.assertTrue(finalized["success"])
        self.assertIn("Integrate.", finalized["response_text"])
        self.assertEqual(len(finalized["wolfram_code_blocks"]), 1)
        self.assertEqual(
            finalized["wolfram_code_blocks"][0]["code"],
            "Integrate[Log[t]/(1-t), {t,0,1}]",
        )
        self.assertNotIn("assistant_chat_object_string", finalized)
        # Preserved fields from the original payload.
        self.assertEqual(finalized["prompt"], "How do I integrate Log[t]/(1 - t) from 0 to 1?")

    def test_finalize_ask_payload_missing_chat_string(self) -> None:
        controller = NotebookAssistantController()
        finalized = controller._finalize_ask_payload(
            payload={"success": True, "prompt": "irrelevant"},
        )
        self.assertFalse(finalized["success"])
        self.assertEqual(finalized["error_type"], "AssistantResponseUnavailable")

    def test_finalize_ask_payload_passes_through_failure(self) -> None:
        controller = NotebookAssistantController()
        original = {
            "success": False,
            "error_type": "EvaluationUnavailable",
            "error": "kernel exploded",
        }
        finalized = controller._finalize_ask_payload(payload=dict(original))
        self.assertEqual(finalized, original)

    def test_build_ask_script_emits_expected_settings(self) -> None:
        """The bare `ask` script must wire up Wolfram`Chatbook`, write the
        prompt as a ChatInput cell, and call ChatCellEvaluate without
        any source-cell binding."""
        controller = NotebookAssistantController()
        script = controller._build_ask_script(
            prompt="What is Hypergeometric2F1[1, 1, 2, z] in closed form?",
            system_prompt="You answer Wolfram-Language questions.",
            extra_instructions="Use a fenced Wolfram code block.",
            model_service=None,
            model_name=None,
            tools=None,
        )
        self.assertIn('Needs["Wolfram`Chatbook`" -> None]', script)
        # Tool names appear inside an ImportString-encoded JSON, so the
        # quotes around "WolframLanguageEvaluator" are escaped one layer.
        self.assertIn('WolframLanguageEvaluator', script)
        self.assertIn('DocumentationSearcher', script)
        self.assertIn('Hypergeometric2F1', script)
        self.assertIn('You answer Wolfram-Language questions.', script)
        self.assertIn('"ChatInput"', script)
        self.assertIn('tungstenChatCellEvaluate[chatCell, assistantNotebook]', script)
        # No notebook path / cell selector references in the bare ask path.
        self.assertNotIn('tungstenResolveNotebook', script)
        self.assertNotIn('tungstenResolveCell', script)

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
