"""Additional tests for the existing tower / series / asymptotic modules.

These complement the per-module test files with cross-cutting checks:
edge cases on the canonicalize fixed point, comparison rules involving
sign and layer, identity / annihilator behavior on series, and the
``compute_mo_expression`` driver under varying ``num_levels``.
"""

from __future__ import annotations

import unittest

from mpmath import mp, mpf

from nummy import (
    AsymptoticTowerValue,
    PerturbationSeries,
    PowerTower,
    apply_pow10,
    compute_mo_expression,
    exp_of_series,
    pow10_of_series,
)


class TestPowerTowerEdges(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_canonicalize_fixed_point(self):
        # Idempotent: canonicalize(canonicalize(x)) == canonicalize(x).
        t = PowerTower(1, 0, mpf(10) ** 50)
        once = t.canonicalize()
        twice = once.canonicalize()
        self.assertEqual(once, twice)

    def test_negative_tower_compares_below_positive(self):
        a = PowerTower(-1, 1, mpf(5))
        b = PowerTower(1, 0, mpf("0.001"))
        self.assertLess(a, b)

    def test_two_negatives_order_inverted(self):
        # -(10^7) < -(10^5) (more negative is smaller).
        a = PowerTower(-1, 1, mpf(7))
        b = PowerTower(-1, 1, mpf(5))
        self.assertLess(a, b)

    def test_str_at_layer_zero(self):
        self.assertEqual(str(PowerTower(1, 0, mpf("3.14"))), "3.14")

    def test_str_at_higher_layer(self):
        s = str(PowerTower(1, 2, mpf(10)))
        self.assertEqual(s, "10^^2(10.0)")


class TestSeriesIdentities(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_constant_zero_series_neutral_under_addition(self):
        zero = PerturbationSeries.constant_series(0, order=3)
        s = PerturbationSeries([1, 2, 3, 4])
        self.assertEqual((zero + s).coeffs, s.coeffs)

    def test_multiplication_distributes_over_addition(self):
        a = PerturbationSeries([1, 2])
        b = PerturbationSeries([3, 4])
        c = PerturbationSeries([5, 6])
        lhs = a * (b + c)
        rhs = a * b + a * c
        # Pad rhs to match lhs's order if needed.
        n = max(len(lhs.coeffs), len(rhs.coeffs))
        for i in range(n):
            li = lhs.coeffs[i] if i < len(lhs.coeffs) else mpf(0)
            ri = rhs.coeffs[i] if i < len(rhs.coeffs) else mpf(0)
            self.assertEqual(li, ri)

    def test_exp_inverse_of_log_is_identity_on_constant(self):
        # 10^(log10(c)) = c for c > 0; check via pow10_of_series of a
        # constant series.
        s = PerturbationSeries([2, 0, 0])  # constant 2
        result = pow10_of_series(s)
        self.assertEqual(result.coeffs[0], mpf(100))  # 10^2

    def test_exp_of_zero_series_is_one(self):
        zero = PerturbationSeries.constant_series(0, order=3)
        result = exp_of_series(zero)
        # Constant 1, all higher terms 0.
        self.assertEqual(result.coeffs[0], mpf(1))
        for c in result.coeffs[1:]:
            self.assertEqual(c, mpf(0))


class TestAsymptoticDriverVariations(unittest.TestCase):
    def setUp(self):
        mp.dps = 80

    def test_compute_mo_at_lower_levels_returns_consistent_shape(self):
        # num_levels = 1 means v_1 = x = 10^(-n_inner); the dominant
        # term is essentially zero.  We test that the driver does not
        # crash and produces *some* leading-digits result.
        result = compute_mo_expression(num_levels=1, n_inner=10**3)
        self.assertEqual(result.num_levels, 1)
        self.assertEqual(result.n_inner, 10**3)

    def test_compute_mo_rejects_overshoot_levels(self):
        with self.assertRaises(NotImplementedError):
            compute_mo_expression(num_levels=6)


class TestApplyPow10Increment(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_apply_pow10_preserves_n_inner(self):
        v = AsymptoticTowerValue.seed_from_x(n_inner=100, max_order=2)
        v_next = apply_pow10(v, max_order=2)
        self.assertEqual(v_next.n_inner, 100)


if __name__ == "__main__":
    unittest.main()
