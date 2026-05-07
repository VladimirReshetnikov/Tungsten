"""End-to-end REPL tests driven through StringIO streams."""

from __future__ import annotations

import io
import unittest

from nummy.repl import run_repl


def _drive(source: str, *, show_banner: bool = False) -> tuple[str, str, int]:
    stdin = io.StringIO(source)
    stdout = io.StringIO()
    stderr = io.StringIO()
    code = run_repl(
        stdin=stdin, stdout=stdout, stderr=stderr, show_banner=show_banner
    )
    return stdout.getvalue(), stderr.getvalue(), code


class TestREPL(unittest.TestCase):
    def test_eof_exits_cleanly(self):
        out, err, code = _drive("")
        self.assertEqual(code, 0)
        self.assertEqual(err, "")

    def test_integer_arithmetic_displays_as_integer(self):
        out, err, _ = _drive("1+2\n")
        self.assertIn("In[1]:= ", out)
        # Exact integer result: no decimal point, no precision suffix.
        self.assertIn("Out[1]= 3\n", out)
        self.assertEqual(err, "")

    def test_float_arithmetic_at_machine_precision(self):
        out, err, _ = _drive("5.77 * 2.11\n")
        self.assertIn("Out[1]= 12.1747", out)
        # Machine precision -> no backtick suffix.
        for line in out.splitlines():
            if line.startswith("Out["):
                self.assertNotIn("`", line)
        self.assertEqual(err, "")

    def test_assignment_shows_assignment_in_output(self):
        out, err, _ = _drive("x = 5.77 * 2.11\n")
        self.assertIn("Out[1]= x = 12.1747", out)
        self.assertEqual(err, "")

    def test_variable_recall_after_assignment(self):
        out, err, _ = _drive("x = 7\nx + 1\n")
        self.assertIn("Out[2]= 8\n", out)
        self.assertEqual(err, "")

    def test_history_percent_in_repl(self):
        out, err, _ = _drive("3\n7\n%\n%%\n")
        self.assertIn("Out[3]= 7\n", out)
        self.assertIn("Out[4]= 7\n", out)
        self.assertEqual(err, "")

    def test_unassigned_variable_defaults_to_zero(self):
        out, err, _ = _drive("z + 5\n")
        self.assertIn("Out[1]= 5\n", out)
        self.assertEqual(err, "")

    def test_blank_line_does_not_advance_line_number(self):
        out, err, _ = _drive("1+1\n\n2+2\n")
        self.assertIn("Out[1]= 2\n", out)
        self.assertIn("Out[2]= 4\n", out)
        self.assertNotIn("Out[3]=", out)

    def test_syntax_error_stays_alive(self):
        out, err, _ = _drive("@\n1+1\n")
        self.assertIn("Syntax::", err)
        self.assertIn("Out[1]= 2\n", out)

    def test_eval_error_stays_alive(self):
        out, err, _ = _drive("1/0\n3+4\n")
        self.assertIn("Eval::error", err)
        self.assertIn("Out[1]= 7\n", out)

    def test_banner_is_optional(self):
        out_no_banner, _, _ = _drive("1+1\n", show_banner=False)
        out_banner, _, _ = _drive("1+1\n", show_banner=True)
        self.assertNotIn("Nummy", out_no_banner)
        self.assertIn("Nummy", out_banner)

    def test_huge_tower_displays_tower_notation(self):
        out, err, _ = _drive("10 ^ (10 ^ 10)\n")
        self.assertIn("Out[1]= 10^^", out)
        self.assertEqual(err, "")

    def test_explicit_precision_literal_displays_with_suffix(self):
        out, err, _ = _drive("1.5`30 / 7\n")
        self.assertIn("`30", out)
        self.assertEqual(err, "")

    def test_session_precision_setter(self):
        out, err, _ = _drive("Precision = 50\n1 / 7\n")
        # Result of 1/7 at session precision 50 -> backtick suffix `50.
        self.assertIn("`50", out)
        # The displayed digits should match the first 50 of 0.142857142857...
        self.assertIn("0.142857142857142857142857142857142857142857142857", out)
        self.assertEqual(err, "")

    def test_machine_precision_constant_displays_as_integer(self):
        out, err, _ = _drive("MachinePrecision\n")
        self.assertIn("Out[1]= 16\n", out)
        self.assertEqual(err, "")


if __name__ == "__main__":
    unittest.main()
