from __future__ import annotations

import unittest

from tungsten.discovery import discover_installation
from tungsten.kernel import WolframKernelRunner


class KernelIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installation = discover_installation()
        if cls.installation.kernel_cli is None or cls.installation.mathpass is None:
            raise unittest.SkipTest("Local Wolfram kernel or mathpass was not discovered.")

    def test_evaluates_basic_expression(self) -> None:
        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text("2+2")

        self.assertTrue(result.evaluation_available)
        self.assertEqual(result.result, "4")
        self.assertEqual(result.result_head, "Integer")
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.used_mathpass_workaround)

    def test_reports_result_heads_for_common_values(self) -> None:
        runner = WolframKernelRunner(self.installation)

        list_result = runner.evaluate_text("{1, 2}")
        string_result = runner.evaluate_text('"hello"')

        self.assertEqual(list_result.result_head, "List")
        self.assertEqual(string_result.result_head, "String")

    def test_reports_message_failures(self) -> None:
        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text("1/0")

        self.assertTrue(result.evaluation_available)
        self.assertFalse(result.success)
        self.assertIn("Power::infy", " ".join(result.messages))

    def test_print_captures_evaluated_arguments(self) -> None:
        """Print's args must evaluate before capture, matching stock Wolfram
        semantics (Print is not HoldAll). Regression: prior to this fix the
        capture shim was HoldAll, so Print[Prime[10]] surfaced the literal
        string "Prime[10]" in the output buffer instead of "29"."""
        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text("Print[Prime[10]]; Prime[20]")

        self.assertTrue(result.evaluation_available)
        self.assertEqual(result.result, "71")
        self.assertEqual(result.output, ["29"])

    def test_print_captures_multiple_args_after_evaluation(self) -> None:
        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text('Print["sum=", 1 + 2]; 0')

        self.assertTrue(result.evaluation_available)
        self.assertEqual(result.output, ["sum=3"])

    def test_front_end_round_trip(self) -> None:
        if self.installation.frontend_executable is None:
            self.skipTest("No local FrontEnd executable was discovered.")

        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text(
            'nb = UsingFrontEnd[CreateDocument[Notebook[{Cell["Hidden smoke", "Text"]}, Visible -> False]]];'
            " head = Head[nb];"
            " UsingFrontEnd[NotebookClose[nb]];"
            " head"
        )

        self.assertTrue(result.evaluation_available)
        self.assertEqual(result.result, "NotebookObject")


if __name__ == "__main__":
    unittest.main()
