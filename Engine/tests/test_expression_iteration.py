"""Tests for ``Table``, ``Do``, ``Sum``, and ``Product``.

All four heads share the iterator-spec vocabulary (``n``, ``{n}``,
``{i, n}``, ``{i, imin, imax}``, ``{i, imin, imax, di}``, ``{i,
list}``) and Block-scope each iteration variable so outer state is
restored on exit. ``Sum`` and ``Product`` reject the bare-integer
``n`` form (matching the kernel) and fold their collected bodies
through ``Plus`` / ``Times``, so empty iteration ranges yield ``0``
and ``1`` respectively.

The tests cover the iter-spec forms, multi-iterator nesting with
dependent inner specs, the Block-scope save/restore behavior, body
interactions with non-local control flow (``Throw`` / ``Catch``), and
the structural shape of the result for each head.
"""
from __future__ import annotations

import unittest

from tungsten.expression import (
    evaluate,
    parse_expression,
    parse_input_form,
)


def _full(text: str) -> str:
    return evaluate(parse_expression(text, form="input")).to_full_form()


class TableIteratorSpecTests(unittest.TestCase):
    """Exercise the full iter-spec vocabulary against the kernel's
    expected output."""

    def test_one_argument_count_iterates_n_times_with_no_variable(self) -> None:
        # ``Table[a, 3]`` and ``Table[a, {3}]`` both repeat the body
        # three times without binding any iteration variable.
        self.assertEqual(_full("Table[a, 3]"), "List[a, a, a]")
        self.assertEqual(_full("Table[a, {3}]"), "List[a, a, a]")

    def test_short_form_with_variable(self) -> None:
        # ``{i, n}`` is shorthand for ``{i, 1, n, 1}``.
        self.assertEqual(_full("Table[i, {i, 5}]"), "List[1, 2, 3, 4, 5]")

    def test_explicit_min_and_max(self) -> None:
        self.assertEqual(_full("Table[i^2, {i, 1, 5}]"), "List[1, 4, 9, 16, 25]")
        self.assertEqual(_full("Table[i, {i, 3, 6}]"), "List[3, 4, 5, 6]")
        self.assertEqual(_full("Table[i, {i, 1, 1}]"), "List[1]")

    def test_explicit_step(self) -> None:
        self.assertEqual(_full("Table[i, {i, 2, 8, 2}]"), "List[2, 4, 6, 8]")

    def test_negative_step(self) -> None:
        self.assertEqual(
            _full("Table[i, {i, 5, 1, -1}]"),
            "List[5, 4, 3, 2, 1]",
        )

    def test_empty_when_bounds_oppose_default_step(self) -> None:
        # Default step is +1; if min > max the iteration is empty.
        self.assertEqual(_full("Table[i, {i, 5, 1}]"), "List[]")
        self.assertEqual(_full("Table[i, {i, 0}]"), "List[]")

    def test_rational_step_produces_rational_values(self) -> None:
        # ``{i, 0, 1, 1/4}`` -> {0, 1/4, 1/2, 3/4, 1}
        self.assertEqual(
            _full("Table[i, {i, 0, 1, 1/4}]"),
            "List[0, Rational[1, 4], Rational[1, 2], Rational[3, 4], 1]",
        )

    def test_value_list_form_iterates_explicit_values(self) -> None:
        self.assertEqual(
            _full("Table[Sqrt[i], {i, {1, 4, 9, 16}}]"),
            "List[1, 2, 3, 4]",
        )
        # Symbolic values are passed through unchanged.
        self.assertEqual(
            _full("Table[i, {i, {a, b, c}}]"),
            "List[a, b, c]",
        )


class TableMultiIteratorTests(unittest.TestCase):
    """Multiple iter specs nest with the leftmost outermost; later
    iterators may depend on earlier iteration variables."""

    def test_two_iterators_produce_nested_lists(self) -> None:
        self.assertEqual(
            _full("Table[i + j, {i, 3}, {j, 2}]"),
            "List[List[2, 3], List[3, 4], List[4, 5]]",
        )

    def test_dependent_inner_iterator_sees_outer_value(self) -> None:
        # ``{j, i}``'s upper bound is the outer iterator's current value.
        self.assertEqual(
            _full("Table[{i, j}, {i, 2}, {j, i}]"),
            "List[List[List[1, 1]], List[List[2, 1], List[2, 2]]]",
        )

    def test_nested_table_is_equivalent_to_two_iterators(self) -> None:
        self.assertEqual(
            _full("Table[Table[i*j, {j, i}], {i, 3}]"),
            "List[List[1], List[2, 4], List[3, 6, 9]]",
        )


class TableScopingTests(unittest.TestCase):
    """``Table`` Block-scopes each iteration variable: the variable's
    outer state is snapshotted at entry and restored on exit."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_iteration_variable_outer_value_is_restored(self) -> None:
        self._track("tungstenTableI1")
        evaluate(parse_input_form("tungstenTableI1 = 99"))
        self.assertEqual(
            _full("Table[tungstenTableI1, {tungstenTableI1, 3}]"),
            "List[1, 2, 3]",
        )
        self.assertEqual(_full("tungstenTableI1"), "99")

    def test_outer_symbol_is_visible_inside_body(self) -> None:
        self._track("tungstenTableX1")
        evaluate(parse_input_form("tungstenTableX1 = 100"))
        self.assertEqual(
            _full("Table[tungstenTableX1 + i, {i, 1, 3}]"),
            "List[101, 102, 103]",
        )

    def test_module_inside_body_works(self) -> None:
        self.assertEqual(
            _full("Table[Module[{x = i}, x^2], {i, 4}]"),
            "List[1, 4, 9, 16]",
        )

    def test_body_can_mutate_global_down_values_across_iterations(self) -> None:
        # Only the iteration variable is Block-scoped; mutations to
        # other symbols propagate normally.
        self._track("tungstenTableT1")
        evaluate(parse_input_form("tungstenTableT1[1] = 99"))
        self.assertEqual(
            _full(
                "Table[tungstenTableT1[1] = i; tungstenTableT1[1], "
                "{i, 1, 3}]"
            ),
            "List[1, 2, 3]",
        )
        # The body's last write persists outside Table because tungstenTableT1
        # was not in the iterator scope.
        self.assertEqual(_full("tungstenTableT1[1]"), "3")


class TableErrorAndShapeTests(unittest.TestCase):
    def test_length_of_table_result(self) -> None:
        self.assertEqual(_full("Table[i, {i, 3}] // Length"), "3")

    def test_powers_of_two(self) -> None:
        self.assertEqual(
            _full("Table[Power[2, n], {n, 0, 10}]"),
            "List[1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]",
        )

    def test_zero_step_raises(self) -> None:
        # The step value must be nonzero; Tungsten falls through to the
        # inert form when the iterator is invalid.
        result = _full("Table[i, {i, 1, 5, 0}]")
        self.assertTrue(result.startswith("Table["))

    def test_missing_iterator_raises(self) -> None:
        result = _full("Table[i]")
        self.assertEqual(result, "Table[i]")


class DoEvaluationTests(unittest.TestCase):
    """``Do`` shares the iter-spec machinery with ``Table`` but evaluates
    the body for side effects only and returns ``Null``. Non-local
    control flow (``Throw``, ``Abort``, time constraints) propagates
    through Do and the iteration variable is still restored via the
    ``try`` / ``finally`` save/restore."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_basic_do_returns_null(self) -> None:
        self.assertEqual(_full("Do[Print[i], {i, 3}]"), "Null")

    def test_do_no_iterator_variable(self) -> None:
        self.assertEqual(_full("Do[i + 1, {3}]"), "Null")

    def test_do_accumulates_via_outer_variable(self) -> None:
        self._track("tungstenDoX1")
        evaluate(parse_input_form("tungstenDoX1 = 0"))
        evaluate(parse_input_form("Do[tungstenDoX1 = tungstenDoX1 + i, {i, 5}]"))
        self.assertEqual(_full("tungstenDoX1"), "15")

    def test_do_iterator_variable_is_block_scoped(self) -> None:
        self._track("tungstenDoI1")
        evaluate(parse_input_form("tungstenDoI1 = 99"))
        evaluate(parse_input_form("Do[Null, {tungstenDoI1, 5}]"))
        self.assertEqual(_full("tungstenDoI1"), "99")

    def test_do_throw_escapes_through_iterations(self) -> None:
        # Throw escapes both inner and outer iteration; Catch returns
        # the value of the first throw (i = 1, j = 1).
        self.assertEqual(
            _full("Catch[Do[Throw[i], {i, 5}, {j, 5}]]"),
            "1",
        )

    def test_do_with_throw_restores_iterator_variable(self) -> None:
        self._track("tungstenDoI2")
        evaluate(parse_input_form("tungstenDoI2 = 99"))
        evaluate(
            parse_input_form(
                "Catch[Do[Throw[escape], {tungstenDoI2, 1, 5}]]"
            )
        )
        self.assertEqual(_full("tungstenDoI2"), "99")

    def test_do_multiple_iterators(self) -> None:
        self._track("tungstenDoSum1")
        evaluate(parse_input_form("tungstenDoSum1 = 0"))
        evaluate(
            parse_input_form(
                "Do[tungstenDoSum1 = tungstenDoSum1 + i*j, "
                "{i, 1, 3}, {j, 1, 2}]"
            )
        )
        # 1*1 + 1*2 + 2*1 + 2*2 + 3*1 + 3*2 = 1+2+2+4+3+6 = 18
        self.assertEqual(_full("tungstenDoSum1"), "18")


class SumIteratorSpecTests(unittest.TestCase):
    """Exercise the iter-spec vocabulary for ``Sum`` against the
    kernel's expected result. Sum rejects the bare-integer ``n`` form
    (only the ``{n}`` List form is accepted) and folds the collected
    bodies through ``Plus``."""

    def test_simple_integer_range(self) -> None:
        self.assertEqual(_full("Sum[i, {i, 1, 5}]"), "15")

    def test_squares_sum(self) -> None:
        self.assertEqual(_full("Sum[i^2, {i, 1, 5}]"), "55")

    def test_short_form_with_variable(self) -> None:
        self.assertEqual(_full("Sum[i, {i, 5}]"), "15")

    def test_explicit_step(self) -> None:
        # 2 + 4 + 6 + 8 = 20.
        self.assertEqual(_full("Sum[i, {i, 2, 8, 2}]"), "20")

    def test_negative_step_descends(self) -> None:
        self.assertEqual(_full("Sum[i, {i, 5, 1, -1}]"), "15")

    def test_empty_range_default_step_yields_zero(self) -> None:
        # Default step is +1 so {i, 5, 1} is empty; Sum identity is 0.
        self.assertEqual(_full("Sum[i, {i, 5, 1}]"), "0")
        self.assertEqual(_full("Sum[i, {i, 0}]"), "0")

    def test_singleton_range(self) -> None:
        self.assertEqual(_full("Sum[i, {i, 1, 1}]"), "1")

    def test_rational_step(self) -> None:
        # 0 + 1/4 + 1/2 + 3/4 + 1 = 5/2.
        self.assertEqual(
            _full("Sum[i, {i, 0, 1, 1/4}]"),
            "Rational[5, 2]",
        )

    def test_rational_bounds(self) -> None:
        # 1 + 3/2 + 2 + 5/2 = 7.
        self.assertEqual(_full("Sum[i, {i, 1, 5/2, 1/2}]"), "7")

    def test_value_list_form(self) -> None:
        self.assertEqual(
            _full("Sum[Sqrt[i], {i, {1, 4, 9, 16}}]"),
            "10",
        )

    def test_value_list_with_symbols(self) -> None:
        self.assertEqual(
            _full("Sum[i, {i, {a, b, c}}]"),
            "Plus[a, b, c]",
        )


class SumMultiIteratorTests(unittest.TestCase):
    """Multiple iter specs nest with the leftmost outermost; Sum
    accumulates each binding combination's body into a flat list and
    folds with ``Plus`` once at the end."""

    def test_two_iterators(self) -> None:
        # Sum of (i+j) for i in 1..3, j in 1..2 = 21.
        self.assertEqual(_full("Sum[i + j, {i, 3}, {j, 2}]"), "21")

    def test_two_iterators_explicit_bounds(self) -> None:
        # Sum of (i*j) for i in 1..3, j in 1..2 = 18.
        self.assertEqual(_full("Sum[i*j, {i, 1, 3}, {j, 1, 2}]"), "18")

    def test_constant_body_with_two_iterators(self) -> None:
        # 1 summed 5*4 = 20 times.
        self.assertEqual(_full("Sum[1, {i, 1, 5}, {j, 1, 4}]"), "20")


class SumScopingTests(unittest.TestCase):
    """``Sum`` shares the ``Table``/``Do`` Block-scoped iteration; the
    iterator variable's outer state is snapshotted at entry and
    restored on exit."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_iteration_variable_outer_value_is_restored(self) -> None:
        self._track("tungstenSumI1")
        evaluate(parse_input_form("tungstenSumI1 = 99"))
        self.assertEqual(
            _full("Sum[tungstenSumI1, {tungstenSumI1, 1, 3}]"),
            "6",
        )
        self.assertEqual(_full("tungstenSumI1"), "99")

    def test_outer_symbol_visible_inside_body(self) -> None:
        self._track("tungstenSumX1")
        evaluate(parse_input_form("tungstenSumX1 = 100"))
        # 101 + 102 + 103 = 306.
        self.assertEqual(
            _full("Sum[tungstenSumX1 + i, {i, 1, 3}]"),
            "306",
        )

    def test_module_inside_body_works(self) -> None:
        # 1 + 4 + 9 + 16 = 30.
        self.assertEqual(
            _full("Sum[Module[{x = i}, x^2], {i, 4}]"),
            "30",
        )


class SumErrorAndShapeTests(unittest.TestCase):
    def test_bare_integer_iter_spec_stays_inert(self) -> None:
        # Unlike Table/Do, Sum rejects the bare-integer iter spec; the
        # call falls through to its inert form.
        self.assertEqual(_full("Sum[a, 3]"), "Sum[a, 3]")

    def test_no_iterator_stays_inert(self) -> None:
        self.assertEqual(_full("Sum[a]"), "Sum[a]")
        self.assertEqual(_full("Sum[]"), "Sum[]")

    def test_count_only_form_repeats_body(self) -> None:
        # ``{3}`` form repeats body without binding any variable; the
        # resulting Plus[a, a, a] is simplified by the arithmetic evaluator.
        self.assertEqual(_full("Sum[a, {3}]"), "Times[3, a]")

    def test_zero_step_falls_through_to_inert(self) -> None:
        result = _full("Sum[i, {i, 1, 5, 0}]")
        self.assertTrue(result.startswith("Sum["))


class ProductIteratorSpecTests(unittest.TestCase):
    """Exercise the iter-spec vocabulary for ``Product``. Like Sum,
    Product rejects the bare-integer ``n`` form and folds the
    collected bodies through ``Times``."""

    def test_factorial(self) -> None:
        # 1*2*3*4*5 = 120.
        self.assertEqual(_full("Product[i, {i, 1, 5}]"), "120")

    def test_squares_product(self) -> None:
        # 1*4*9*16 = 576.
        self.assertEqual(_full("Product[i^2, {i, 1, 4}]"), "576")

    def test_short_form_with_variable(self) -> None:
        self.assertEqual(_full("Product[i, {i, 5}]"), "120")

    def test_explicit_step(self) -> None:
        # 2*4*6*8 = 384.
        self.assertEqual(_full("Product[i, {i, 2, 8, 2}]"), "384")

    def test_negative_step_descends(self) -> None:
        self.assertEqual(_full("Product[i, {i, 5, 1, -1}]"), "120")

    def test_empty_range_yields_one(self) -> None:
        # Empty iteration; Product identity is 1.
        self.assertEqual(_full("Product[i, {i, 5, 1}]"), "1")
        self.assertEqual(_full("Product[i, {i, 0}]"), "1")

    def test_singleton_range(self) -> None:
        self.assertEqual(_full("Product[i, {i, 1, 1}]"), "1")

    def test_zero_in_range_yields_zero(self) -> None:
        # ``{i, 0, 1, 1/4}`` includes 0, so the product collapses.
        self.assertEqual(_full("Product[i, {i, 0, 1, 1/4}]"), "0")

    def test_value_list_form(self) -> None:
        # 1 * 2 * 3 * 4 = 24.
        self.assertEqual(
            _full("Product[Sqrt[i], {i, {1, 4, 9, 16}}]"),
            "24",
        )

    def test_value_list_with_symbols(self) -> None:
        self.assertEqual(
            _full("Product[i, {i, {a, b, c}}]"),
            "Times[a, b, c]",
        )


class ProductMultiIteratorTests(unittest.TestCase):
    def test_two_iterators(self) -> None:
        # Product of (i+j) for i in 1..3, j in 1..2 =
        # (1+1)(1+2)(2+1)(2+2)(3+1)(3+2) = 2*3*3*4*4*5 = 1440.
        self.assertEqual(_full("Product[i + j, {i, 3}, {j, 2}]"), "1440")

    def test_two_iterators_explicit_bounds(self) -> None:
        # Product of (i*j) for i in 1..3, j in 1..2 =
        # 1*2*2*4*3*6 = 288.
        self.assertEqual(
            _full("Product[i*j, {i, 1, 3}, {j, 1, 2}]"),
            "288",
        )


class ProductScopingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_iteration_variable_outer_value_is_restored(self) -> None:
        self._track("tungstenProdI1")
        evaluate(parse_input_form("tungstenProdI1 = 99"))
        self.assertEqual(
            _full("Product[tungstenProdI1, {tungstenProdI1, 1, 3}]"),
            "6",
        )
        self.assertEqual(_full("tungstenProdI1"), "99")

    def test_outer_symbol_visible_inside_body(self) -> None:
        self._track("tungstenProdX1")
        evaluate(parse_input_form("tungstenProdX1 = 2"))
        # (2+1)(2+2)(2+3) = 3*4*5 = 60.
        self.assertEqual(
            _full("Product[tungstenProdX1 + i, {i, 1, 3}]"),
            "60",
        )

    def test_module_inside_body_works(self) -> None:
        # 1 * 4 * 9 * 16 = 576.
        self.assertEqual(
            _full("Product[Module[{x = i}, x^2], {i, 4}]"),
            "576",
        )


class ProductErrorAndShapeTests(unittest.TestCase):
    def test_bare_integer_iter_spec_stays_inert(self) -> None:
        self.assertEqual(_full("Product[a, 3]"), "Product[a, 3]")

    def test_no_iterator_stays_inert(self) -> None:
        self.assertEqual(_full("Product[a]"), "Product[a]")
        self.assertEqual(_full("Product[]"), "Product[]")

    def test_count_only_form_repeats_body(self) -> None:
        # ``{3}`` form repeats body 3 times; the resulting Times[a, a, a]
        # is simplified by the arithmetic evaluator.
        self.assertEqual(_full("Product[a, {3}]"), "Power[a, 3]")

    def test_zero_step_falls_through_to_inert(self) -> None:
        result = _full("Product[i, {i, 1, 5, 0}]")
        self.assertTrue(result.startswith("Product["))


class SumProductInteractionTests(unittest.TestCase):
    """Sum and Product compose with each other and with Catch/Throw the
    same way as Table/Do; iterator variables are restored even on
    non-local exit."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_sum_with_throw_restores_iterator_variable(self) -> None:
        self._track("tungstenSumI2")
        evaluate(parse_input_form("tungstenSumI2 = 99"))
        evaluate(
            parse_input_form(
                "Catch[Sum[Throw[escape], {tungstenSumI2, 1, 5}]]"
            )
        )
        self.assertEqual(_full("tungstenSumI2"), "99")

    def test_product_with_throw_restores_iterator_variable(self) -> None:
        self._track("tungstenProdI2")
        evaluate(parse_input_form("tungstenProdI2 = 99"))
        evaluate(
            parse_input_form(
                "Catch[Product[Throw[escape], {tungstenProdI2, 1, 5}]]"
            )
        )
        self.assertEqual(_full("tungstenProdI2"), "99")

    def test_sum_inside_product(self) -> None:
        # Product over j of (Sum over i in 1..j of i) for j in 1..3
        #   = (1) * (1+2) * (1+2+3) = 1 * 3 * 6 = 18.
        self.assertEqual(
            _full("Product[Sum[i, {i, 1, j}], {j, 1, 3}]"),
            "18",
        )

    def test_dependent_inner_iterator_in_sum(self) -> None:
        # Sum over i of (Sum over j in 1..i of i) for i in 1..3
        #   = 1 + (2+2) + (3+3+3) = 1 + 4 + 9 = 14.
        self.assertEqual(
            _full("Sum[Sum[i, {j, 1, i}], {i, 1, 3}]"),
            "14",
        )

    def test_powers_of_two_via_product(self) -> None:
        # Product of 2 over n in 0..10 = 2^11 = 2048.
        self.assertEqual(
            _full("Product[2, {n, 0, 10}]"),
            "2048",
        )


if __name__ == "__main__":
    unittest.main()
