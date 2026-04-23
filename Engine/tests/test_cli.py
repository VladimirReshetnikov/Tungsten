from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory

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


if __name__ == "__main__":
    unittest.main()
