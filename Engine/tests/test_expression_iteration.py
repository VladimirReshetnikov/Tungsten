"""Tests for ``Table`` and ``Do``.

Both heads share the iterator-spec vocabulary (``n``, ``{n}``,
``{i, n}``, ``{i, imin, imax}``, ``{i, imin, imax, di}``, ``{i,
list}``) and Block-scope each iteration variable so outer state is
restored on exit. The tests cover the iter-spec forms, multi-iterator
nesting with dependent inner specs, the Block-scope save/restore
behavior, body interactions with non-local control flow (``Throw`` /
``Catch``), and the structural shape of the result for ``Table``
versus the ``Null`` return for ``Do``.
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


if __name__ == "__main__":
    unittest.main()
