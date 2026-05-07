"""Tests for ``nummy.asymptotic`` propagation."""

from __future__ import annotations

import unittest

from mpmath import mp, mpf

from nummy import AsymptoticTowerValue, apply_pow10
from nummy.asymptotic import evaluate


class TestAsymptoticPropagation(unittest.TestCase):
    def setUp(self):
        mp.dps = 80

    def test_seed_is_x(self):
        v = AsymptoticTowerValue.seed_from_x(n_inner=10**10, max_order=2)
        self.assertEqual(v.scale_layer, 0)
        self.assertEqual(v.scale_base, mpf(1))
        # Series: 0 + 1*x + 0*x^2.
        self.assertEqual(v.series.coeffs[0], mpf(0))
        self.assertEqual(v.series.coeffs[1], mpf(1))
        self.assertEqual(v.series.coeffs[2], mpf(0))

    def test_one_pow10_step_gives_10_to_x(self):
        # Starting from v_1 = x, applying pow10 yields v_2 = 10^x =
        # 1 + (ln 10) x + (ln 10)^2 x^2 / 2 + ...
        from nummy.series import ln10
        v = AsymptoticTowerValue.seed_from_x(n_inner=10**10, max_order=3)
        v = apply_pow10(v, max_order=3)
        c = ln10()
        # Series coefficients (after multiplying scale = 1):
        self.assertAlmostEqual(float(v.series.coeffs[0] - 1), 0.0, places=70)
        self.assertAlmostEqual(float(v.series.coeffs[1] - c), 0.0, places=70)
        self.assertAlmostEqual(float(v.series.coeffs[2] - c * c / 2), 0.0, places=60)
        # Scale is still 1 (mpf, layer 0).
        self.assertEqual(v.scale_layer, 0)
        self.assertEqual(v.scale_base, mpf(1))

    def test_two_steps_match_hand_derivation(self):
        # v_3 = 10^v_2 = 10 + 10 c^2 x + ... (per MO answer).
        from nummy.series import ln10
        v = AsymptoticTowerValue.seed_from_x(n_inner=10**10, max_order=3)
        v = apply_pow10(v, max_order=3)  # v_2
        v = apply_pow10(v, max_order=3)  # v_3
        c = ln10()
        # v_3 = 10 * (1 + c^2 x + ...).  Scale = 10, series[1] = c^2.
        self.assertEqual(v.scale_base, mpf(10))
        self.assertAlmostEqual(float(v.series.coeffs[1] - c * c), 0.0, places=60)

    def test_four_steps_match_hand_derivation(self):
        # v_5 = 10^^5(-10^10) = 10^(10^10) + 10^11 c^4 + smaller.
        # Scale should be 10^(10^10) (deferred); series[1] should be 10^11 c^4.
        from nummy.series import ln10
        n_inner = 10**10
        v = AsymptoticTowerValue.seed_from_x(n_inner=n_inner, max_order=2)
        for _ in range(4):
            v = apply_pow10(v, max_order=2)
        c = ln10()
        self.assertEqual(v.scale_layer, 1)
        self.assertEqual(v.scale_base, mpf(n_inner))
        expected_a1 = mpf(10) ** 11 * c ** 4
        self.assertAlmostEqual(
            float((v.series.coeffs[1] - expected_a1) / expected_a1), 0.0, places=60
        )

    def test_evaluate_yields_clean_dominant_for_mo(self):
        # After 5 pow10s starting from x = 10^(-10^10), the dominant should
        # be 10^(10^10) and the correction should be 10^11 * ln(10)^4.
        from nummy.series import ln10
        n_inner = 10**10
        v = AsymptoticTowerValue.seed_from_x(n_inner=n_inner, max_order=2)
        for _ in range(4):
            v = apply_pow10(v, max_order=2)
        decomp = evaluate(v)
        self.assertEqual(decomp.dominant_log10, n_inner)
        c = ln10()
        expected = mpf(10) ** 11 * c ** 4
        self.assertAlmostEqual(
            float((decomp.correction - expected) / expected), 0.0, places=60
        )


if __name__ == "__main__":
    unittest.main()
