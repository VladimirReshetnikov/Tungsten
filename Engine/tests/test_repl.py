from __future__ import annotations

import io
import unittest
from unittest.mock import patch

from tungsten.cli import main
from tungsten.repl import run_repl


class ReplTests(unittest.TestCase):
    def test_run_repl_tracks_history_and_quits(self) -> None:
        stdin = io.StringIO("1+2\n$Line\nInString[1]\n%1 + 10\nQuit\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertIn("In[1]:=", transcript)
        self.assertIn("Out[1]= 3", transcript)
        self.assertIn("Out[2]= 2", transcript)
        self.assertIn("Out[3]= 1+2", transcript)
        self.assertIn("Out[4]= 13", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_run_repl_uses_display_form_labels_and_print_text(self) -> None:
        stdin = io.StringIO(
            "InputForm[1 + x]\n"
            "FullForm[1 + x]\n"
            "Print[InputForm[1 + x]]\n"
            "Print[FullForm[1 + x]]\n"
            "Quit\n"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertIn("Out[1]//InputForm= 1 + x", transcript)
        self.assertIn("Out[2]//FullForm= Plus[1, x]", transcript)
        self.assertIn("In[3]:= 1 + x", transcript)
        self.assertIn("In[4]:= Plus[1, x]", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_cli_repl_subcommand_uses_repl(self) -> None:
        stdin = io.StringIO("Exit[7]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        with patch("sys.stdin", stdin), patch("sys.stdout", stdout), patch("sys.stderr", stderr):
            exit_code = main(["repl", "--no-banner"])

        self.assertEqual(exit_code, 7)
        self.assertIn("In[1]:=", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")
