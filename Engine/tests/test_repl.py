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
            "TeXForm[1 + x]\n"
            "TraditionalForm[1 + x]\n"
            "Print[InputForm[1 + x]]\n"
            "Print[FullForm[1 + x]]\n"
            "Print[TeXForm[1 + x]]\n"
            "Quit\n"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertIn("Out[1]//InputForm= 1 + x", transcript)
        self.assertIn("Out[2]//FullForm= Plus[1, x]", transcript)
        self.assertIn("Out[3]//TeXForm= x+1", transcript)
        self.assertIn("Out[4]//TraditionalForm= \\!\\(\\*FormBox", transcript)
        self.assertIn("In[5]:= 1 + x", transcript)
        self.assertIn("In[6]:= Plus[1, x]", transcript)
        self.assertIn("In[7]:= x+1", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_run_repl_shortens_large_output_with_output_size_limit(self) -> None:
        stdin = io.StringIO(
            "$OutputSizeLimit = 80\n"
            "Range[100]\n"
            "$OutputSizeLimit = Infinity\n"
            "$OutputSizeLimit = 12000\n"
            "Quit\n"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertIn("Out[1]= 80", transcript)
        self.assertIn("Out[2]= {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, <<85>>, 96, 97, 98, 99, 100}", transcript)
        self.assertIn("Out[3]= Infinity", transcript)
        self.assertIn("Out[4]= 12000", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_run_repl_applies_main_loop_hooks(self) -> None:
        stdin = io.StringIO(
            '$PreRead = Function[s, StringReplace[s, "aa" -> "1+2"]]\n'
            "aa\n"
            "InString[2]\n"
            "$PreRead =.\n"
            "$PrePrint = FullForm\n"
            "1+x\n"
            "$PrePrint =.\n"
            "Quit\n"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertIn("Out[2]= 3", transcript)
        self.assertIn("Out[3]= 1+2", transcript)
        self.assertIn("Out[6]= Plus[1, x]", transcript)
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
