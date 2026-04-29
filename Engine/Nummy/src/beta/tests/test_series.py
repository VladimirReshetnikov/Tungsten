"""Tests for ``nummy.series``."""

from __future__ import annotations

import unittest

from mpmath import mp, mpf, exp, log

from nummy.series import (
    PerturbationSeries,
    exp_of_series,
    ln10,
    pow10_of_series,
)


class TestPerturbationSeries(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_construction_and_order(self):
        s = PerturbationSeries([1, 2, 3])
        self.assertEqual(s.order, 2)
        self.assertEqual(s.coeffs, (mpf(1), mpf(2), mpf(3)))

    def test_addition(self):
        a = PerturbationSeries([1, 2])
        b = PerturbationSeries([3, 4, 5])
        c = a + b
        self.assertEqual(c.coeffs, (mpf(4), mpf(6), mpf(5)))

    def test_subtraction(self):
        a = PerturbationSeries([5, 7])
        b = PerturbationSeries([2, 3, 4])
        c = a - b
        self.assertEqual(c.coeffs, (mpf(3), mpf(4), mpf(-4)))

    def test_scalar_multiplication(self):
        a = PerturbationSeries([1, 2, 3])
        c = a * 4
        self.assertEqual(c.coeffs, (mpf(4), mpf(8), mpf(12)))

    def test_cauchy_product(self):
        # (1 + 2x)(3 + 4x) = 3 + 10x + 8x^2
        a = PerturbationSeries([1, 2])
        b = PerturbationSeries([3, 4])
        c = a * b
        self.assertEqual(c.coeffs, (mpf(3), mpf(10), mpf(8)))

    def test_evaluate(self):
        # 1 + 2x + 3x^2 at x = 0.5 -> 1 + 1 + 0.75 = 2.75
        s = PerturbationSeries([1, 2, 3])
        self.assertEqual(s.evaluate(mpf("0.5")), mpf("2.75"))


class TestExpOfSeries(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_zero_constant_required(self):
        with self.assertRaises(ValueError):
            exp_of_series(PerturbationSeries([1, 1]))

    def test_exp_of_x_matches_taylor(self):
        # exp(x) = 1 + x + x^2/2 + x^3/6 + ...
        s = PerturbationSeries([0, 1, 0, 0, 0])
        result = exp_of_series(s)
        expected = [mpf(1), mpf(1), mpf("0.5"), mpf(1) / 6, mpf(1) / 24]
        for r, e in zip(result.coeffs, expected):
            self.assertAlmostEqual(float(r - e), 0.0, places=40)

    def test_exp_evaluation_matches_mpmath(self):
        # exp(2x) at x = 0.1 -> e^0.2.
        s = PerturbationSeries([0, 2] + [0] * 8)  # 0 + 2x; truncate at 10 orders.
        result = exp_of_series(s, max_order=10)
        x = mpf("0.1")
        approx = result.evaluate(x)
        truth = exp(mpf("0.2"))
        # Truncation error at order 10 of exp(0.2) is ~ 0.2^11/11! ~ tiny.
        self.assertLess(abs(approx - truth), mpf("1e-15"))


class TestPow10OfSeries(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_pow10_of_constant(self):
        # 10^(2 + 0*x) at any x -> 100.
        s = PerturbationSeries([2, 0, 0])
        result = pow10_of_series(s)
        self.assertEqual(result.coeffs[0], mpf(100))
        self.assertEqual(result.coeffs[1], mpf(0))
        self.assertEqual(result.coeffs[2], mpf(0))

    def test_pow10_of_x_first_terms(self):
        # 10^x = 1 + (ln 10) x + (ln 10)^2 x^2 / 2 + ...
        s = PerturbationSeries([0, 1, 0, 0, 0])
        result = pow10_of_series(s, max_order=4)
        c = ln10()
        self.assertAlmostEqual(float(result.coeffs[0] - 1), 0.0, places=40)
        self.assertAlmostEqual(float(result.coeffs[1] - c), 0.0, places=40)
        self.assertAlmostEqual(float(result.coeffs[2] - c * c / 2), 0.0, places=40)


if __name__ == "__main__":
    unittest.main()
