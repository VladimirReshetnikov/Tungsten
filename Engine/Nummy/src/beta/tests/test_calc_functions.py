"""Tests for Mathematica-style function-call syntax and built-ins."""

from __future__ import annotations

import io
import unittest

from mpmath import mpf

from nummy.calc import (
    BUILTINS,
    BinaryOp,
    CalcEvaluationError,
    CalcSession,
    CalcSyntaxError,
    FunctionCall,
    NumberLiteral,
    PrecValue,
    execute,
    parse,
    tokenize,
    TokenType,
)
from nummy.repl import run_repl


class TestFunctionCallSyntax(unittest.TestCase):
    def test_lexer_recognises_brackets_and_commas(self):
        toks = tokenize("F[1, 2]")
        self.assertEqual(
            [t.type for t in toks],
            [
                TokenType.IDENT,
                TokenType.LBRACKET,
                TokenType.NUMBER,
                TokenType.COMMA,
                TokenType.NUMBER,
                TokenType.RBRACKET,
                TokenType.EOF,
            ],
        )

    def test_parser_builds_function_call_node(self):
        node = parse("F[1, 2]")
        self.assertIsInstance(node, FunctionCall)
        self.assertEqual(node.name, "F")
        self.assertEqual(len(node.args), 2)
        self.assertIsInstance(node.args[0], NumberLiteral)
        self.assertIsInstance(node.args[1], NumberLiteral)

    def test_function_call_with_no_args(self):
        node = parse("F[]")
        self.assertIsInstance(node, FunctionCall)
        self.assertEqual(node.args, ())

    def test_function_call_with_expression_args(self):
        node = parse("F[1 + 2, 3 * 4]")
        self.assertIsInstance(node, FunctionCall)
        self.assertIsInstance(node.args[0], BinaryOp)
        self.assertEqual(node.args[0].op, "+")

    def test_unknown_function_raises_eval_error(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("UnknownFn[1]", s)

    def test_unbalanced_brackets_raises_syntax_error(self):
        with self.assertRaises(CalcSyntaxError):
            parse("F[1, 2")

    def test_bare_identifier_is_not_function_call(self):
        # F (without []) should still parse as a VariableRef.
        from nummy.calc import VariableRef
        node = parse("F")
        self.assertIsInstance(node, VariableRef)


class TestLeadingDigitsBuiltin(unittest.TestCase):
    def test_returns_correction_value(self):
        s = CalcSession()
        r = execute("LeadingDigits[5, 10]", s)
        # The returned value approximates 10^11 * ln(10)^4 = 2811012357389.44...
        self.assertAlmostEqual(
            float(r.value.value) / 2811012357389.0, 1.0, places=8
        )

    def test_appends_summary_to_messages(self):
        s = CalcSession()
        execute("LeadingDigits[5, 10]", s)
        # take_messages drains; must have queued exactly one summary.
        msgs = s.take_messages()
        self.assertEqual(len(msgs), 1)
        summary = msgs[0]
        self.assertIn("10^^5(-10^10)", summary)
        self.assertIn("10,000,000,001", summary)
        self.assertIn("9,999,999,987", summary)
        self.assertIn("2811012357389", summary)
        self.assertIn(".4407116278", summary)

    def test_argument_validation_requires_two_integers(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[5]", s)
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[5, 10, 1]", s)
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[5.5, 10]", s)
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[0, 10]", s)
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[5, 0]", s)

    def test_levels_above_5_are_rejected(self):
        # The asymptotic engine currently only supports K up to 5.
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("LeadingDigits[6, 10]", s)

    def test_session_precision_controls_fractional_digit_count(self):
        s = CalcSession()
        execute("Precision = 30", s)
        s.take_messages()  # drain prior message
        execute("LeadingDigits[5, 10]", s)
        msgs = s.take_messages()
        self.assertEqual(len(msgs), 1)
        # At precision 30 the fractional digits in the summary should be
        # 30 chars long (matching the MO answer to 30 places).
        self.assertIn(".440711627818278478365617826416", msgs[0])


class TestREPLDisplaysSummary(unittest.TestCase):
    def test_repl_prints_summary_before_out(self):
        stdin = io.StringIO("LeadingDigits[5, 10]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()
        run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)
        text = stdout.getvalue()
        # Summary lines appear above Out[1]=.
        idx_summary = text.find("integer part has")
        idx_out = text.find("Out[1]=")
        self.assertNotEqual(idx_summary, -1)
        self.assertNotEqual(idx_out, -1)
        self.assertLess(idx_summary, idx_out)
        # Out[1]= shows the leading correction.
        self.assertIn("2811012357389", text)


if __name__ == "__main__":
    unittest.main()
