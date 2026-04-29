from __future__ import annotations

import unittest
from decimal import Decimal
from io import StringIO

from nummy import (
    CalculatorSession,
    CalculatorSyntaxError,
    DOMINATED_ADDEND,
    NummyContext,
    SparseDecimalInteger,
    TowerReal,
    calculate_mathoverflow_integer_part,
    format_value,
)
from nummy.perturbation import first_order_tower_perturbation
from nummy.repl import run_repl


class TowerRealTests(unittest.TestCase):
    def test_pow10_and_log10_are_layer_shifts_for_large_values(self) -> None:
        value = TowerReal.from_layer(2, 3)
        self.assertEqual(value.pow10().layer, 3)
        self.assertEqual(value.pow10().mag, Decimal(3))
        self.assertEqual(value.log10().layer, 1)
        self.assertEqual(value.log10().mag, Decimal(3))

    def test_high_layer_addition_reports_dominance(self) -> None:
        large = TowerReal.from_layer(3, 1)
        result = large + TowerReal.from_int(1)
        self.assertEqual(result.layer, 3)
        self.assertIn(DOMINATED_ADDEND, result.flags)

    def test_multiplication_of_tower_by_two_stays_structural(self) -> None:
        value = TowerReal.from_layer(2, 1)
        doubled = value * 2
        self.assertGreaterEqual(doubled.layer, 1)
        self.assertFalse(doubled.is_zero)

    def test_hundreds_of_tower_layers_remain_structural(self) -> None:
        value = TowerReal.from_layer(250, 1)
        self.assertEqual(value.pow10().layer, 251)
        self.assertEqual(value.log10().layer, 249)
        self.assertIn("250 PT 1", value.to_tower_string())

    def test_layer_zero_arithmetic_uses_decimal_path(self) -> None:
        self.assertEqual(
            format_value(TowerReal.from_int(5) / TowerReal.from_int(2)),
            "2.5",
        )
        self.assertEqual(format_value(TowerReal.from_int(2) ** 3), "8")
        self.assertEqual(
            format_value(TowerReal.from_decimal("0.5") + TowerReal.from_decimal("0.25")),
            "0.75",
        )

    def test_pow10_promotes_before_decimal_overflow(self) -> None:
        value = TowerReal.from_decimal(121).pow10()
        self.assertGreaterEqual(value.layer, 1)

    def test_pow10_respects_layer_zero_reciprocal_values(self) -> None:
        value = TowerReal.from_decimal(10).reciprocal_value().pow10()
        self.assertTrue(format_value(value).startswith("1.2589254117"))


class SparseDecimalIntegerTests(unittest.TestCase):
    def test_sparse_power_plus_suffix(self) -> None:
        value = SparseDecimalInteger.power_of_ten(10) + 123
        self.assertEqual(value.digit_count, 11)
        self.assertEqual(value.suffix(5), "00123")
        self.assertEqual(value.to_decimal_string(), "10000000123")


class MathOverflowExampleTests(unittest.TestCase):
    def test_integer_part_matches_archived_answer(self) -> None:
        result = calculate_mathoverflow_integer_part(decimal_digits=100)
        self.assertEqual(result.correction_floor, 2811012357389)
        self.assertEqual(
            result.integer_part.terms,
            ((1, 10_000_000_000), (2811012357389, 0)),
        )
        self.assertEqual(result.zero_run_after_leading_one, 9_999_999_987)
        self.assertTrue(result.stable_floor)
        self.assertLess(result.omitted_tail_log10_upper_bound, -1_000_000)

    def test_perturbation_refuses_dense_anchor_explosion(self) -> None:
        with self.assertRaises(ValueError):
            first_order_tower_perturbation(
                base=10,
                epsilon_exponent=10**10,
                levels=5,
                context=NummyContext(decimal_digits=50),
            )


class CalculatorSessionTests(unittest.TestCase):
    def test_assignment_variables_and_default_zero(self) -> None:
        session = CalculatorSession(default_precision=10)
        assigned = session.evaluate_line("x = 5.77 * 2.11")
        self.assertEqual(assigned.assigned_name, "x")
        self.assertEqual(assigned.display_text, "12.17470000`10")

        result = session.evaluate_line("x + y")
        self.assertEqual(result.display_text, "12.17470000`10")

    def test_history_references_follow_wolfram_style(self) -> None:
        session = CalculatorSession(default_precision=10)
        self.assertEqual(session.evaluate_line("2 + 3").display_text, "5.000000000`10")
        self.assertEqual(session.evaluate_line("% * 10").display_text, "50.00000000`10")
        self.assertEqual(session.evaluate_line("%% + 1").display_text, "6.000000000`10")
        self.assertEqual(session.evaluate_line("%2 + %1").display_text, "55.00000000`10")

    def test_power_is_right_associative_and_parentheses_work(self) -> None:
        session = CalculatorSession(default_precision=10)
        self.assertEqual(session.evaluate_line("2 ^ 3 ^ 2").display_text, "512.0000000`10")
        self.assertEqual(session.evaluate_line("(2 + 3) * 4").display_text, "20.00000000`10")

    def test_power_towers_stay_structural_past_decimal_range(self) -> None:
        session = CalculatorSession(default_precision=10)
        result = session.evaluate_line("10 ^ 10 ^ 10")
        self.assertGreaterEqual(result.value.tower.layer, 1)
        self.assertEqual(result.display_text, "e10000000000`10")

        tall_result = session.evaluate_line(" ^ ".join(["10"] * 220))
        self.assertGreaterEqual(tall_result.value.tower.layer, 200)

    def test_precision_syntax_and_n_function(self) -> None:
        session = CalculatorSession(default_precision=20)
        self.assertEqual(session.evaluate_line("1 / 3").display_text, "0.33333333333333333333`20")
        self.assertEqual(session.evaluate_line("1.23`8 * 2").display_text, "2.4600000`8")
        self.assertEqual(
            session.evaluate_line("N[1 / 3, 30]").display_text,
            "0.333333333333333333333333333333`30",
        )

    def test_non_integer_power_refuses_precision_claim(self) -> None:
        session = CalculatorSession(default_precision=20)
        with self.assertRaises(ValueError):
            session.evaluate_line("2 ^ 0.5")

    def test_floor_of_archived_mathoverflow_expression_returns_exact_report(self) -> None:
        session = CalculatorSession(default_precision=20)
        result = session.evaluate_line(
            "Floor[10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))]"
        )
        self.assertIn("10^10000000000 + 2811012357389", result.display_text)
        self.assertIn("precision: Infinity", result.display_text)
        self.assertIn("stable floor: True", result.display_text)

        with self.assertRaises(ValueError):
            session.evaluate_line("% + 1")

    def test_floor_works_for_exact_rational_values(self) -> None:
        session = CalculatorSession(default_precision=10)
        self.assertEqual(session.evaluate_line("Floor[7 / 3]").display_text, "2.000000000`10")
        self.assertEqual(session.evaluate_line("Floor[-7 / 3]").display_text, "-3.000000000`10")

    def test_archived_mathoverflow_expression_displays_perturbation(self) -> None:
        session = CalculatorSession(default_precision=20)
        result = session.evaluate_line(
            "10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))"
        )
        self.assertIn(
            "10^10000000000 + 2811012357389.4407116`20",
            result.display_text,
        )
        self.assertIn("omitted tail < 10^-9999999970", result.display_text)

    def test_syntax_errors_are_reported(self) -> None:
        session = CalculatorSession()
        with self.assertRaises(CalculatorSyntaxError):
            session.evaluate_line("2 + * 3")


class ReplTests(unittest.TestCase):
    def test_repl_uses_tungsten_style_prompts_and_history(self) -> None:
        stdin = StringIO("x = 5.77 * 2.11\nx + 1\n%\n%%\n%2\nQuit\n")
        stdout = StringIO()
        stderr = StringIO()

        exit_code = run_repl(
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            show_banner=False,
            default_precision=10,
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        transcript = stdout.getvalue()
        self.assertIn("In[1]:=", transcript)
        self.assertIn("Out[1]= 12.17470000`10", transcript)
        self.assertIn("Out[2]= 13.17470000`10", transcript)
        self.assertIn("Out[3]= 13.17470000`10", transcript)
        self.assertIn("Out[4]= 13.17470000`10", transcript)
        self.assertIn("Out[5]= 13.17470000`10", transcript)

    def test_repl_reports_syntax_error_without_advancing_line(self) -> None:
        stdin = StringIO("2 + * 3\n1 + 1\nQuit\n")
        stdout = StringIO()
        stderr = StringIO()

        exit_code = run_repl(
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            show_banner=False,
            default_precision=10,
        )

        self.assertEqual(exit_code, 0)
        self.assertIn("Syntax::sntxi:", stderr.getvalue())
        self.assertIn("In[1]:= In[1]:=", stdout.getvalue())
        self.assertIn("Out[1]= 2.000000000`10", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
