"""Tests for the calculator lexer."""

from __future__ import annotations

import unittest

from nummy.calc import CalcSyntaxError, TokenType, tokenize


class TestTokenize(unittest.TestCase):
    def types(self, source: str) -> list[TokenType]:
        return [t.type for t in tokenize(source)]

    def texts(self, source: str) -> list[str]:
        return [t.text for t in tokenize(source)]

    def test_empty_input_yields_only_eof(self):
        self.assertEqual(self.types(""), [TokenType.EOF])

    def test_whitespace_only_yields_only_eof(self):
        self.assertEqual(self.types("   \t  "), [TokenType.EOF])

    def test_integer_literal(self):
        self.assertEqual(self.texts("42"), ["42", ""])
        self.assertEqual(self.types("42"), [TokenType.NUMBER, TokenType.EOF])

    def test_float_literal_with_dot_prefix(self):
        self.assertEqual(self.texts(".5"), [".5", ""])

    def test_float_literal_with_exponent(self):
        self.assertEqual(self.texts("1.23e-4"), ["1.23e-4", ""])
        self.assertEqual(self.texts("1E+10"), ["1E+10", ""])

    def test_identifier(self):
        self.assertEqual(self.texts("foo_bar"), ["foo_bar", ""])
        self.assertEqual(self.types("foo_bar"), [TokenType.IDENT, TokenType.EOF])

    def test_identifier_starting_with_underscore(self):
        self.assertEqual(self.texts("_x1"), ["_x1", ""])

    def test_percent_history_depth(self):
        self.assertEqual(self.texts("%"), ["%", ""])
        self.assertEqual(self.types("%"), [TokenType.PERCENT, TokenType.EOF])
        self.assertEqual(self.texts("%%"), ["%%", ""])
        self.assertEqual(self.texts("%%%"), ["%%%", ""])

    def test_percent_number(self):
        toks = tokenize("%5")
        self.assertEqual(toks[0].type, TokenType.PERCENT_NUM)
        self.assertEqual(toks[0].text, "%5")

    def test_percent_followed_by_letter_is_history_then_ident(self):
        toks = tokenize("%x")
        self.assertEqual(toks[0].type, TokenType.PERCENT)
        self.assertEqual(toks[1].type, TokenType.IDENT)

    def test_operators(self):
        self.assertEqual(
            self.types("+ - * / ^ = ( )"),
            [
                TokenType.PLUS,
                TokenType.MINUS,
                TokenType.STAR,
                TokenType.SLASH,
                TokenType.CARET,
                TokenType.ASSIGN,
                TokenType.LPAREN,
                TokenType.RPAREN,
                TokenType.EOF,
            ],
        )

    def test_unknown_character_raises(self):
        with self.assertRaises(CalcSyntaxError):
            tokenize("@")

    def test_columns_are_recorded(self):
        toks = tokenize("  3 + 4")
        self.assertEqual(toks[0].column, 2)  # '3'
        self.assertEqual(toks[1].column, 4)  # '+'
        self.assertEqual(toks[2].column, 6)  # '4'

    def test_precision_suffix_is_part_of_number_token(self):
        toks = tokenize("1.5`30")
        self.assertEqual(toks[0].type, TokenType.NUMBER)
        self.assertEqual(toks[0].text, "1.5`30")

    def test_precision_suffix_on_integer_literal(self):
        toks = tokenize("3`50")
        self.assertEqual(toks[0].text, "3`50")

    def test_backtick_without_precision_digits_raises(self):
        with self.assertRaises(CalcSyntaxError):
            tokenize("1.5`")

    def test_backtick_followed_by_non_digit_raises(self):
        with self.assertRaises(CalcSyntaxError):
            tokenize("1.5`x")


if __name__ == "__main__":
    unittest.main()
