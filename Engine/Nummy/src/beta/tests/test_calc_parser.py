"""Tests for the calculator parser AST shape and precedence."""

from __future__ import annotations

import unittest

from mpmath import mpf

from nummy.calc import (
    Assignment,
    BinaryOp,
    CalcSyntaxError,
    HistoryRef,
    NumberLiteral,
    UnaryOp,
    VariableRef,
    parse,
)


class TestParser(unittest.TestCase):
    def test_integer_literal_is_marked_integer(self):
        node = parse("42")
        self.assertIsInstance(node, NumberLiteral)
        self.assertTrue(node.is_integer)
        self.assertIsNone(node.explicit_precision)
        self.assertEqual(node.mantissa_text, "42")

    def test_float_literal_is_not_marked_integer(self):
        node = parse("3.14")
        self.assertFalse(node.is_integer)
        self.assertIsNone(node.explicit_precision)

    def test_explicit_precision_split_out(self):
        node = parse("1.5`30")
        self.assertIsInstance(node, NumberLiteral)
        self.assertEqual(node.mantissa_text, "1.5")
        self.assertEqual(node.explicit_precision, 30)

    def test_explicit_precision_on_integer_literal(self):
        node = parse("3`50")
        self.assertIsInstance(node, NumberLiteral)
        self.assertEqual(node.mantissa_text, "3")
        self.assertEqual(node.explicit_precision, 50)
        # Integer with precision suffix is still flagged as integer-textually,
        # but the evaluator treats it as a precision-tracked float.
        self.assertTrue(node.is_integer)

    def test_variable_reference(self):
        self.assertEqual(parse("x"), VariableRef("x"))

    def test_history_depth(self):
        self.assertEqual(parse("%"), HistoryRef(depth=1))
        self.assertEqual(parse("%%"), HistoryRef(depth=2))
        self.assertEqual(parse("%%%"), HistoryRef(depth=3))

    def test_history_line(self):
        self.assertEqual(parse("%5"), HistoryRef(line=5))

    def test_simple_addition(self):
        ast = parse("1 + 2")
        self.assertIsInstance(ast, BinaryOp)
        self.assertEqual(ast.op, "+")

    def test_left_associative_addition(self):
        # 1 + 2 + 3  -> (1 + 2) + 3
        ast = parse("1 + 2 + 3")
        self.assertIsInstance(ast, BinaryOp)
        self.assertIsInstance(ast.left, BinaryOp)
        self.assertEqual(ast.left.op, "+")

    def test_precedence_mul_over_add(self):
        # 1 + 2 * 3  -> 1 + (2 * 3)
        ast = parse("1 + 2 * 3")
        self.assertEqual(ast.op, "+")
        self.assertIsInstance(ast.right, BinaryOp)
        self.assertEqual(ast.right.op, "*")

    def test_right_associative_caret(self):
        # 2 ^ 3 ^ 4  -> 2 ^ (3 ^ 4)
        ast = parse("2 ^ 3 ^ 4")
        self.assertEqual(ast.op, "^")
        self.assertIsInstance(ast.right, BinaryOp)
        self.assertEqual(ast.right.op, "^")

    def test_unary_minus_below_caret_precedence(self):
        # -2^4  -> -(2^4)  (math convention, NOT (-2)^4)
        ast = parse("-2^4")
        self.assertIsInstance(ast, UnaryOp)
        self.assertEqual(ast.op, "-")
        self.assertIsInstance(ast.operand, BinaryOp)
        self.assertEqual(ast.operand.op, "^")

    def test_negative_exponent_parses(self):
        # 2 ^ -3 should parse without error.
        ast = parse("2^-3")
        self.assertEqual(ast.op, "^")
        self.assertIsInstance(ast.right, UnaryOp)

    def test_parens_override_precedence(self):
        ast = parse("(1 + 2) * 3")
        self.assertEqual(ast.op, "*")

    def test_assignment(self):
        ast = parse("x = 1 + 2")
        self.assertIsInstance(ast, Assignment)
        self.assertEqual(ast.name, "x")
        self.assertIsInstance(ast.expr, BinaryOp)

    def test_assignment_only_at_top_level(self):
        # x = y = 3 is not allowed (no chained assignment).
        with self.assertRaises(CalcSyntaxError):
            parse("x = y = 3")

    def test_unbalanced_parens_raises(self):
        with self.assertRaises(CalcSyntaxError):
            parse("(1 + 2")

    def test_trailing_garbage_raises(self):
        with self.assertRaises(CalcSyntaxError):
            parse("1 + 2 garbage")


if __name__ == "__main__":
    unittest.main()
