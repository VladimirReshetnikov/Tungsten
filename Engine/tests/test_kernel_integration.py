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
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.used_mathpass_workaround)

    def test_reports_message_failures(self) -> None:
        runner = WolframKernelRunner(self.installation)
        result = runner.evaluate_text("1/0")

        self.assertTrue(result.evaluation_available)
        self.assertFalse(result.success)
        self.assertIn("Power::infy", " ".join(result.messages))

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
