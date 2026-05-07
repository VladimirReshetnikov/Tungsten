"""Tests for evaluation, history, and variables in the calculator."""

from __future__ import annotations

import unittest

from mpmath import mp, mpf

from nummy.calc import (
    EXACT,
    MACHINE_PRECISION,
    CalcEvaluationError,
    CalcSession,
    PrecValue,
    execute,
    format_value,
)


def _val(result):
    return result.value.value


def _prec(result):
    return result.value.precision


class TestEvaluator(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_simple_arithmetic_returns_prec_value(self):
        s = CalcSession()
        r = execute("1 + 2", s)
        self.assertIsInstance(r.value, PrecValue)
        self.assertEqual(_val(r), mpf(3))

    def test_integer_literals_are_exact(self):
        s = CalcSession()
        self.assertEqual(_prec(execute("3", s)), EXACT)

    def test_integer_arithmetic_stays_exact(self):
        s = CalcSession()
        self.assertEqual(_prec(execute("3 + 4 * 5", s)), EXACT)

    def test_integer_division_with_integer_result_stays_exact(self):
        s = CalcSession()
        self.assertEqual(_prec(execute("6 / 3", s)), EXACT)
        self.assertEqual(_val(execute("6 / 3", s)), mpf(2))

    def test_integer_division_with_non_integer_result_demotes_to_session(self):
        s = CalcSession()
        r = execute("5 / 3", s)
        self.assertEqual(_prec(r), s.precision)

    def test_float_literal_uses_session_precision(self):
        s = CalcSession()
        s.precision = 30
        r = execute("1.5", s)
        self.assertEqual(_prec(r), 30)

    def test_assignment_records_value(self):
        s = CalcSession()
        execute("x = 5.77 * 2.11", s)
        self.assertAlmostEqual(
            float(s.variables["x"].value), 5.77 * 2.11, places=10
        )

    def test_assignment_returns_value_with_assignment_target(self):
        s = CalcSession()
        r = execute("x = 7", s)
        self.assertEqual(_val(r), mpf(7))
        self.assertEqual(r.assignment_target, "x")

    def test_unassigned_variable_defaults_to_exact_zero(self):
        s = CalcSession()
        r = execute("undef", s)
        self.assertEqual(_val(r), mpf(0))
        self.assertEqual(_prec(r), EXACT)

    def test_history_percent_returns_last_result(self):
        s = CalcSession()
        execute("3", s)
        execute("7", s)
        self.assertEqual(_val(execute("%", s)), mpf(7))

    def test_history_double_percent_returns_two_back(self):
        s = CalcSession()
        execute("3", s)
        execute("7", s)
        execute("11", s)
        self.assertEqual(_val(execute("%%", s)), mpf(7))

    def test_history_triple_percent(self):
        s = CalcSession()
        for v in (3, 7, 11, 13):
            execute(str(v), s)
        self.assertEqual(_val(execute("%%%", s)), mpf(7))

    def test_history_by_line_number(self):
        s = CalcSession()
        for v in (3, 7, 11):
            execute(str(v), s)
        self.assertEqual(_val(execute("%2", s)), mpf(7))

    def test_history_too_far_back_raises(self):
        s = CalcSession()
        execute("3", s)
        with self.assertRaises(CalcEvaluationError):
            execute("%%", s)

    def test_history_unknown_line_raises(self):
        s = CalcSession()
        execute("3", s)
        with self.assertRaises(CalcEvaluationError):
            execute("%5", s)

    def test_division_by_zero_raises(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("1 / 0", s)

    def test_power_operator_right_associative(self):
        s = CalcSession()
        self.assertEqual(_val(execute("2 ^ 3 ^ 2", s)), mpf(512))

    def test_unary_minus_lower_than_power(self):
        s = CalcSession()
        self.assertEqual(_val(execute("-2^4", s)), mpf(-16))

    def test_negative_exponent(self):
        s = CalcSession()
        self.assertEqual(_val(execute("2^-3", s)), mpf("0.125"))

    def test_huge_exponent_is_rejected(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("10 ^ (10 ^ 16)", s)

    def test_chained_history_and_variables(self):
        s = CalcSession()
        execute("3", s)
        execute("x = % * 2", s)
        execute("%2 + x", s)
        self.assertEqual(s.history[-1].value, mpf(12))


class TestPrecisionPropagation(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_explicit_precision_literal(self):
        s = CalcSession()
        r = execute("1.5`30", s)
        self.assertEqual(_prec(r), 30)

    def test_min_of_two_explicit_precisions_wins(self):
        s = CalcSession()
        r = execute("1`30 + 2`50", s)
        self.assertEqual(_prec(r), 30)

    def test_exact_does_not_drag_down(self):
        s = CalcSession()
        # 5 is exact, 1.5`30 has precision 30 -- result should be 30.
        r = execute("5 * 1.5`30", s)
        self.assertEqual(_prec(r), 30)

    def test_session_precision_setter(self):
        s = CalcSession()
        execute("Precision = 50", s)
        self.assertEqual(s.precision, 50)
        # Subsequent literals pick up the new precision.
        r = execute("1.5", s)
        self.assertEqual(_prec(r), 50)

    def test_session_precision_returns_current_value(self):
        s = CalcSession()
        execute("Precision = 25", s)
        r = execute("Precision", s)
        self.assertEqual(_val(r), mpf(25))

    def test_machine_precision_is_constant(self):
        s = CalcSession()
        r = execute("MachinePrecision", s)
        self.assertEqual(_val(r), mpf(MACHINE_PRECISION))

    def test_machine_precision_assignment_rejected(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("MachinePrecision = 30", s)

    def test_precision_assignment_rejects_non_integer(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("Precision = 1.5", s)

    def test_precision_assignment_rejects_non_positive(self):
        s = CalcSession()
        with self.assertRaises(CalcEvaluationError):
            execute("Precision = 0", s)

    def test_high_precision_division_keeps_correct_digits(self):
        # 1/7 at 50 digits.  The first 50 digits of 1/7 = 0.142857142857...
        # (repeating 142857) -- last digit at position 50 should round
        # correctly.  142857 repeats every 6 digits; position 50 is in
        # the middle of the cycle.
        s = CalcSession()
        s.precision = 50
        r = execute("1 / 7", s)
        from mpmath import mpf as _mpf
        # With 50-digit precision, the result should agree with the
        # mathematical 1/7 to at least 49 digits (cascading-tail
        # caveat allows ~1 ULP in the last digit).
        from mpmath import mp as _mp
        prior = _mp.dps
        _mp.dps = 100
        try:
            truth = _mpf(1) / _mpf(7)
            err = abs(r.value.value - truth)
            self.assertLess(err, _mpf(10) ** -49)
        finally:
            _mp.dps = prior


class TestFormatValue(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_exact_integer_displays_without_dot(self):
        self.assertEqual(format_value(PrecValue(mpf(42), EXACT)), "42")

    def test_zero_displays_as_zero(self):
        self.assertEqual(format_value(PrecValue(mpf(0), EXACT)), "0")

    def test_machine_precision_omits_suffix(self):
        s = format_value(PrecValue(mpf("3.14159"), MACHINE_PRECISION))
        self.assertTrue(s.startswith("3.14159"))
        self.assertNotIn("`", s)

    def test_high_precision_includes_suffix(self):
        v = mpf("3.14159265358979323846")
        s = format_value(PrecValue(v, 20))
        self.assertTrue(s.endswith("`20"))

    def test_high_precision_keeps_trailing_zeros(self):
        # 1.5 stored at 30 digits should display 1.5 followed by trailing
        # zeros to make the precision visible.
        v = mpf("1.5")
        s = format_value(PrecValue(v, 30))
        self.assertTrue(s.endswith("`30"))
        # Strip the suffix and count significant digits before/after the dot.
        head = s.rsplit("`", 1)[0]
        digits_only = head.replace(".", "").lstrip("0")
        self.assertGreaterEqual(len(digits_only), 25)

    def test_huge_value_uses_tower_notation(self):
        v = mpf(10) ** mpf(10**10)
        s = format_value(PrecValue(v, MACHINE_PRECISION))
        self.assertTrue(s.startswith("10^^"))

    def test_negative_value(self):
        s = format_value(PrecValue(mpf("-2.5"), MACHINE_PRECISION))
        self.assertTrue(s.startswith("-2.5"))


if __name__ == "__main__":
    unittest.main()
