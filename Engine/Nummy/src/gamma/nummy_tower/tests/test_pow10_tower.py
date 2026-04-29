import unittest
from decimal import Decimal

from nummy_tower.pow10_tower import ExponentSum
from nummy_tower.pow10_tower import Pow10Factor
from nummy_tower.pow10_tower import Pow10Tower


class TestPow10Tower(unittest.TestCase):
    def test_structural_ops_roundtrip(self) -> None:
        base = Pow10Tower.scalar(3)
        lifted = base.pow10_structural()
        self.assertEqual(lifted.height, 1)
        self.assertEqual(lifted.top, Decimal(3))
        self.assertEqual(lifted.log10_structural(), base)

        with self.assertRaises(ValueError):
            base.log10_structural()

    def test_try_eval_int_guards(self) -> None:
        self.assertEqual(Pow10Tower.scalar(123).try_eval_int(max_digits=3), 123)
        self.assertIsNone(Pow10Tower.scalar(123).try_eval_int(max_digits=2))
        self.assertIsNone(Pow10Tower.scalar(Decimal("1.2")).try_eval_int(max_digits=10))
        self.assertIsNone(Pow10Tower(1, Decimal(-3)).try_eval_int(max_digits=10))

    def test_try_eval_int_small_towers(self) -> None:
        self.assertEqual(Pow10Tower(1, Decimal(3)).try_eval_int(max_digits=10), 1000)
        self.assertEqual(Pow10Tower(2, Decimal(1)).try_eval_int(max_digits=32), 10**10)
        self.assertEqual(Pow10Tower(2, Decimal(2)).try_eval_int(max_digits=200), 10**100)

    def test_exponent_sum_cancellation(self) -> None:
        t = Pow10Tower(1, Decimal(5))
        exp = ExponentSum()
        exp.add(t, max_tower_int_digits=3)
        exp.add(t, max_tower_int_digits=3, count=-1)
        self.assertTrue(exp.is_pure_int())
        self.assertEqual(exp.as_int(), 0)

    def test_pow10_factor_to_decimal_if_possible(self) -> None:
        factor = Pow10Factor(coeff=Decimal(3), exp=ExponentSum(offset=2))
        self.assertEqual(factor.to_decimal_if_possible(), Decimal(300))

        t = Pow10Tower(2, Decimal(3))  # too large to evaluate under a small max_tower_int_digits
        factor2 = Pow10Factor(coeff=Decimal(1), exp=ExponentSum.from_value(t, max_tower_int_digits=1))
        self.assertIsNone(factor2.to_decimal_if_possible())


if __name__ == "__main__":
    unittest.main()
