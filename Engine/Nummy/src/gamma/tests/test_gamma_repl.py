import unittest
from decimal import Decimal

from gamma_repl import GammaEnv, eval_line


class TestGammaRepl(unittest.TestCase):
    def _eval_push(self, env: GammaEnv, text: str) -> Decimal:
        value = eval_line(env, text)
        env.push_out(value)
        self.assertTrue(value.is_scalar)
        return value.as_decimal()

    def test_basic_arithmetic_and_precedence(self) -> None:
        env = GammaEnv(precision=80)
        self.assertEqual(self._eval_push(env, "1 + 2 * 3"), Decimal(7))
        self.assertEqual(self._eval_push(env, "(1 + 2) * 3"), Decimal(9))

    def test_power_is_right_associative(self) -> None:
        env = GammaEnv(precision=80)
        self.assertEqual(self._eval_push(env, "2^3^2"), Decimal(512))

    def test_unary_minus_binds_outside_power(self) -> None:
        env = GammaEnv(precision=80)
        self.assertEqual(self._eval_push(env, "-10^2"), Decimal(-100))
        self.assertEqual(self._eval_push(env, "(-10)^2"), Decimal(100))

    def test_power_binds_tighter_than_unary_in_exponent(self) -> None:
        env = GammaEnv(precision=80)
        value = eval_line(env, "10^-10^10")
        self.assertTrue(value.is_pow10_tower)
        self.assertEqual(value.format_short(), "10^-10000000000")

    def test_assignment_and_default_variables(self) -> None:
        env = GammaEnv(precision=80)
        self.assertEqual(self._eval_push(env, "x = 5.77 * 2.11"), Decimal("12.1747"))
        self.assertEqual(self._eval_push(env, "x + 1"), Decimal("13.1747"))
        self.assertEqual(self._eval_push(env, "y"), Decimal(0))

    def test_history_percent_syntax(self) -> None:
        env = GammaEnv(precision=80)
        self.assertEqual(self._eval_push(env, "1 + 2"), Decimal(3))
        self.assertEqual(self._eval_push(env, "% * 2"), Decimal(6))
        self.assertEqual(self._eval_push(env, "%% + %"), Decimal(9))
        self.assertEqual(self._eval_push(env, "%1"), Decimal(3))
        self.assertEqual(self._eval_push(env, "%%%"), Decimal(6))
        self.assertEqual(self._eval_push(env, "%999"), Decimal(0))

    def test_repl_can_build_and_recognize_mo_tower(self) -> None:
        env = GammaEnv(precision=120)
        value = eval_line(env, "10^(10^(10^(10^(10^(-10^10)))))")
        self.assertTrue(value.is_landmark)
        self.assertEqual(value.format_short(), "10^10^10 + 2811012357389.4407116278")

    def test_output_format_is_roundtrip_friendly(self) -> None:
        env = GammaEnv(precision=80)
        value = eval_line(env, "10^3")
        self.assertTrue(value.is_scalar)
        self.assertEqual(value.format_short(), "1000")

        t = eval_line(env, "10^1000000")
        self.assertTrue(t.is_pow10_tower)
        self.assertEqual(t.format_short(), "10^1000000")


if __name__ == "__main__":
    unittest.main()
