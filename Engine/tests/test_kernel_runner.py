from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tungsten.discovery import WolframInstallation
from tungsten.kernel import WolframKernelRunner


class KernelRunnerUnitTests(unittest.TestCase):
    def test_launch_gate_timeout_returns_structured_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fake_kernel = root / "wolfram.exe"
            fake_kernel.write_text("", encoding="utf-8")
            installation = WolframInstallation(
                install_dir=root,
                kernel_cli=fake_kernel,
                kernel_executable=fake_kernel,
                frontend_executable=None,
                wolframscript=None,
                mathpass=None,
                docs_roots=(),
                bundled_python_client=None,
                default_index_path=root / "docs.sqlite",
            )

            runner = WolframKernelRunner(installation)

            with patch("tungsten.kernel.tungsten_wolfram_launch_gate", side_effect=TimeoutError("gate busy")):
                result = runner.evaluate_text("2+2")

        self.assertFalse(result.evaluation_available)
        self.assertEqual(result.failure_type, "LaunchGateTimeout")
        self.assertEqual(result.exit_code, 124)
        self.assertIn("gate busy", result.stderr)


if __name__ == "__main__":
    unittest.main()
