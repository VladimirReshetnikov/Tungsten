"""End-to-end test for the MathOverflow #79217 expression.

The published answer (https://mathoverflow.net/questions/79217) is:

* Integer part begins with the digit 1.
* Followed by ``10^10 - 13`` zeros.
* Followed by the 13-digit string ``2811012357389``.
* Then a decimal point and a fractional part starting ``.4407116278...``.

This test verifies that ``compute_mo_expression`` reproduces every part
of that answer.
"""

from __future__ import annotations

import unittest

from nummy import compute_mo_expression


class TestMathOverflowAnswer(unittest.TestCase):
    def test_integer_part_structure(self):
        result = compute_mo_expression()
        ld = result.leading
        self.assertEqual(ld.sign, 1)
        # Integer part has 10^10 + 1 digits.
        self.assertEqual(ld.integer_digit_count, 10**10 + 1)
        # Begins with "1".
        self.assertEqual(ld.leading_digit, "1")
        # Followed by 10^10 - 13 zeros.
        self.assertEqual(ld.zeros_count, 10**10 - 13)
        # Then "2811012357389".
        self.assertEqual(ld.trailing_int_digits, "2811012357389")

    def test_fractional_part_starts_with_published_digits(self):
        result = compute_mo_expression(fractional_dps=20)
        ld = result.leading
        # MathOverflow answer: ".4407116278..."  Match the first 10 digits exactly.
        self.assertTrue(
            ld.fractional_digits.startswith("4407116278"),
            f"fractional_digits={ld.fractional_digits!r} does not start with '4407116278'",
        )

    def test_higher_order_residual_is_negligible(self):
        # Confirm that the dropped higher-order series terms contribute
        # below 10^-10^10 magnitude, i.e., they cannot affect the integer
        # part.  residual_log10 should be very negative.
        result = compute_mo_expression(max_order=3)
        residual = result.leading.residual_log10
        self.assertIsNotNone(residual)
        # Dropped terms are at scale ~ 10^(-(j-1) * n_inner) for j >= 2,
        # so log10 should be at most around -10^10.
        self.assertLess(residual, -10**9)


class TestSummary(unittest.TestCase):
    def test_short_summary_is_a_string(self):
        result = compute_mo_expression()
        s = result.leading.short_summary()
        self.assertIsInstance(s, str)
        self.assertIn("9999999987", s)  # 10^10 - 13.
        self.assertIn("2811012357389", s)


if __name__ == "__main__":
    unittest.main()
