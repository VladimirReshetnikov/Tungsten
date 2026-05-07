"""Tests for ``nummy.tower``."""

from __future__ import annotations

import unittest

from mpmath import mp, mpf, log10

from nummy.tower import PowerTower


class TestPowerTower(unittest.TestCase):
    def setUp(self):
        mp.dps = 50

    def test_construction(self):
        t = PowerTower(1, 0, mpf(7))
        self.assertEqual(t.sign, 1)
        self.assertEqual(t.layer, 0)
        self.assertEqual(t.mag, mpf(7))

    def test_from_mpf_positive(self):
        t = PowerTower.from_mpf(3.14)
        self.assertEqual(t.sign, 1)
        self.assertEqual(t.layer, 0)

    def test_from_mpf_negative(self):
        t = PowerTower.from_mpf(-2.5)
        self.assertEqual(t.sign, -1)
        self.assertEqual(t.layer, 0)
        self.assertEqual(t.mag, mpf("2.5"))

    def test_pow10_increments_layer(self):
        t = PowerTower(1, 0, mpf(2))
        self.assertEqual(t.pow10().layer, 1)
        self.assertEqual(t.pow10().pow10().layer, 2)

    def test_log10_decrements_layer(self):
        t = PowerTower(1, 3, mpf(2))
        self.assertEqual(t.log10().layer, 2)

    def test_log10_at_layer_0_uses_mpmath(self):
        t = PowerTower(1, 0, mpf(100))
        result = t.log10()
        self.assertEqual(result.layer, 0)
        self.assertEqual(result.mag, log10(mpf(100)))  # 2.0

    def test_to_mpf_layer_0(self):
        t = PowerTower(1, 0, mpf("3.14"))
        self.assertEqual(t.to_mpf(), mpf("3.14"))

    def test_to_mpf_layer_2(self):
        # 10^^2(2) = 10^(10^2) = 10^100.
        t = PowerTower(1, 2, mpf(2))
        v = t.to_mpf()
        self.assertEqual(log10(v), mpf(100))

    def test_canonicalize_promotes_large_mag(self):
        # mag = 10^20 is too large for layer-0 storage; canonicalize
        # promotes it to layer 1 with mag = 20.
        t = PowerTower(1, 0, mpf(10) ** 20)
        c = t.canonicalize()
        self.assertEqual(c.layer, 1)
        self.assertEqual(c.mag, mpf(20))

    def test_ordering_same_layer(self):
        a = PowerTower(1, 1, mpf(5))
        b = PowerTower(1, 1, mpf(7))
        self.assertLess(a, b)

    def test_ordering_different_layers(self):
        # 10^^1(7) = 10^7 < 10^^2(2) = 10^100.
        a = PowerTower(1, 1, mpf(7))
        b = PowerTower(1, 2, mpf(2))
        self.assertLess(a, b)


if __name__ == "__main__":
    unittest.main()
