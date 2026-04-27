"""Tests for the bucket-D extensions: ``MinMax``, ``RankedMin`` /
``RankedMax``, ``Mode``, ``Quantile`` / ``Quartiles``, ``BinCounts`` /
``BinLists``, ``Permute`` / ``Cycles`` / ``PermutationCycles`` /
``PermutationList`` / ``PermutationOrder``, ``SequenceCases`` /
``SequencePosition`` / ``SequenceCount``, plus argument-shape
extensions (``Total[..., levelspec]``, ``Differences[..., n]``,
``Accumulate[..., f]``, ``Subsets[..., {min, max, step}]``,
``Permutations[..., {min, max, step}]``, ``Tuples[seq, {n1, …}]``,
``Riffle[..., x, {a, b, s}]``, ``Tr[..., f, n]``,
``Through[..., head]``, ``RotateLeft[..., {n1, n2, …}]``,
``DeleteDuplicatesBy[..., f, test]``, ``Cases``/``DeleteCases``/
``Count``/``MemberQ`` Heads option, ``DeleteCases[..., {0}]``).
"""
from __future__ import annotations

import unittest

from tungsten.expression import (
    evaluate,
    parse_expression,
)


def _full(text: str) -> str:
    return evaluate(parse_expression(text, form="input")).to_full_form()


class StatisticsHeadsTests(unittest.TestCase):
    def test_min_max(self) -> None:
        self.assertEqual(_full("MinMax[{3, 1, 4, 1, 5, 9, 2, 6}]"), "List[1, 9]")
        self.assertEqual(_full("MinMax[{2.5}]"), "List[2.5, 2.5]")

    def test_min_max_empty_uses_inf_identities(self) -> None:
        # Empty list: Min identity is Infinity, Max identity is -Infinity.
        # Tungsten represents the result as ``Times[-1, Infinity]``
        # rather than the kernel's ``DirectedInfinity[-1]`` form.
        self.assertEqual(_full("MinMax[{}]"), "List[Infinity, Times[-1, Infinity]]")

    def test_ranked_min_keeps_duplicates(self) -> None:
        self.assertEqual(_full("RankedMin[{3, 1, 4, 1, 5, 9, 2, 6}, 1]"), "1")
        self.assertEqual(_full("RankedMin[{3, 1, 4, 1, 5, 9, 2, 6}, 2]"), "1")
        self.assertEqual(_full("RankedMin[{3, 1, 4, 1, 5, 9, 2, 6}, 3]"), "2")

    def test_ranked_max_descending(self) -> None:
        self.assertEqual(_full("RankedMax[{3, 1, 4, 1, 5, 9, 2, 6}, 1]"), "9")
        self.assertEqual(_full("RankedMax[{3, 1, 4, 1, 5, 9, 2, 6}, 2]"), "6")
        self.assertEqual(_full("RankedMax[{3, 1, 4, 1, 5, 9, 2, 6}, 3]"), "5")

    def test_mode_picks_most_common(self) -> None:
        self.assertEqual(_full("Mode[{1, 1, 2, 3, 3, 3, 4}]"), "3")

    def test_mode_breaks_ties_canonically(self) -> None:
        self.assertEqual(_full("Mode[{a, a, b, c, c}]"), "a")

    def test_mode_empty_stays_inert(self) -> None:
        self.assertEqual(_full("Mode[{}]"), "Mode[List[]]")


class QuantileTests(unittest.TestCase):
    def test_quantile_default_uses_inverse_cdf_form(self) -> None:
        # Type 1: result = s[[Ceiling[n*q]]] for n*q > 0.
        self.assertEqual(_full("Quantile[{1, 2, 3, 4, 5}, 1/2]"), "3")
        self.assertEqual(_full("Quantile[{1, 2, 3, 4, 5}, 1/4]"), "2")
        self.assertEqual(_full("Quantile[{1, 2, 3, 4, 5}, 3/4]"), "4")

    def test_quantile_integer_position_is_lower_value(self) -> None:
        # For n=6, q=1/2: n*q = 3 (integer) -> use s[[3]] = 3.
        self.assertEqual(_full("Quantile[{1, 2, 3, 4, 5, 6}, 1/2]"), "3")

    def test_quantile_list_threads(self) -> None:
        self.assertEqual(
            _full("Quantile[{1, 2, 3, 4, 5}, {1/4, 1/2, 3/4}]"),
            "List[2, 3, 4]",
        )

    def test_quantile_explicit_type1_parameters(self) -> None:
        self.assertEqual(
            _full("Quantile[{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 1/2, {{0, 0}, {1, 0}}]"),
            "5",
        )

    def test_quantile_type7_parameters_interpolate(self) -> None:
        # Type 7 = {{1/2, 0}, {0, 1}}: linear interpolation.
        self.assertEqual(
            _full("Quantile[{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 1/2, {{1/2, 0}, {0, 1}}]"),
            "Rational[11, 2]",
        )

    def test_quartiles(self) -> None:
        self.assertEqual(_full("Quartiles[Range[10]]"), "List[3, Rational[11, 2], 8]")
        self.assertEqual(_full("Quartiles[{1, 2, 3, 4, 5}]"), "List[Rational[7, 4], 3, Rational[17, 4]]")


class BinCountsAndListsTests(unittest.TestCase):
    def test_bin_counts_with_explicit_spec(self) -> None:
        self.assertEqual(
            _full("BinCounts[{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, {0, 10, 2}]"),
            "List[1, 2, 2, 2, 2]",
        )

    def test_bin_counts_with_real_inputs(self) -> None:
        self.assertEqual(
            _full("BinCounts[{1.1, 2.5, 3.7, 4.0}, {0, 5, 1}]"),
            "List[0, 1, 1, 1, 1]",
        )

    def test_bin_lists_collects_actual_elements(self) -> None:
        self.assertEqual(
            _full("BinLists[{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, {0, 10, 2}]"),
            "List[List[1], List[2, 3], List[4, 5], List[6, 7], List[8, 9]]",
        )


class PermutationFamilyTests(unittest.TestCase):
    def test_permute_with_positional_list(self) -> None:
        self.assertEqual(
            _full("Permute[{a, b, c, d}, {2, 3, 1, 4}]"),
            "List[c, a, b, d]",
        )

    def test_permute_with_cycles(self) -> None:
        self.assertEqual(
            _full("Permute[{a, b, c, d, e}, Cycles[{{1, 3, 5}}]]"),
            "List[e, b, a, d, c]",
        )

    def test_permutation_cycles_canonicalizes(self) -> None:
        self.assertEqual(
            _full("PermutationCycles[{2, 3, 1, 4}]"),
            "Cycles[List[List[1, 2, 3]]]",
        )

    def test_permutation_list_with_explicit_length(self) -> None:
        self.assertEqual(
            _full("PermutationList[Cycles[{{1, 2, 3}}], 4]"),
            "List[2, 3, 1, 4]",
        )

    def test_permutation_list_two_two_cycles(self) -> None:
        self.assertEqual(
            _full("PermutationList[Cycles[{{1, 2}, {3, 4}}], 4]"),
            "List[2, 1, 4, 3]",
        )

    def test_permutation_order_lcms_cycle_lengths(self) -> None:
        self.assertEqual(_full("PermutationOrder[Cycles[{{1, 2, 3}}]]"), "3")
        self.assertEqual(_full("PermutationOrder[Cycles[{{1, 2, 3, 4, 5}, {6, 7}}]]"), "10")


class SequencePatternTests(unittest.TestCase):
    def test_sequence_cases_with_condition(self) -> None:
        self.assertEqual(
            _full("SequenceCases[{1, 2, 3, 4, 5, 6}, {a_, b_} /; b == a + 1]"),
            "List[List[1, 2], List[3, 4], List[5, 6]]",
        )

    def test_sequence_position(self) -> None:
        self.assertEqual(
            _full("SequencePosition[{1, 2, 3, 1, 2, 3}, {1, 2}]"),
            "List[List[1, 2], List[4, 5]]",
        )

    def test_sequence_count(self) -> None:
        self.assertEqual(_full("SequenceCount[{1, 2, 3, 1, 2, 3}, {1, 2}]"), "2")


class TotalLevelSpecTests(unittest.TestCase):
    def test_total_default_is_columnwise(self) -> None:
        # Default ``Total`` over a matrix is column-wise (level 1).
        self.assertEqual(_full("Total[{{1, 2}, {3, 4}}, {1}]"), "List[4, 6]")

    def test_total_at_level_2(self) -> None:
        # Level {2} is row-wise.
        self.assertEqual(_full("Total[{{1, 2}, {3, 4}}, {2}]"), "List[3, 7]")

    def test_total_to_level_2_collapses(self) -> None:
        # Integer 2 means levels 1..2: scalar sum of all leaves.
        self.assertEqual(_full("Total[{{1, 2}, {3, 4}}, 2]"), "10")

    def test_total_infinity_collapses_all_leaves(self) -> None:
        self.assertEqual(
            _full("Total[{{{1,2},{3,4}},{{5,6},{7,8}}}, Infinity]"),
            "36",
        )


class DifferencesAndAccumulateTests(unittest.TestCase):
    def test_differences_n_th(self) -> None:
        self.assertEqual(_full("Differences[{1, 4, 9, 16, 25}, 2]"), "List[2, 2, 2]")

    def test_differences_default(self) -> None:
        # ``Differences[list, 1]`` matches ``Differences[list]``.
        self.assertEqual(
            _full("Differences[{1, 1, 2, 3, 5, 8, 13}]"),
            _full("Differences[{1, 1, 2, 3, 5, 8, 13}, 1]"),
        )

    def test_accumulate_with_function(self) -> None:
        # Accumulate with Times: 1, 1*2=2, 2*3=6, 6*4=24.
        self.assertEqual(
            _full("Accumulate[{1, 2, 3, 4}, Times]"),
            "List[1, 2, 6, 24]",
        )


class SubsetsAndTuplesTests(unittest.TestCase):
    def test_subsets_step_variant(self) -> None:
        # ``Subsets[list, {1, 3, 2}]`` -> sizes 1 and 3.
        self.assertEqual(
            _full("Subsets[{a, b, c, d}, {1, 3, 2}]"),
            "List[List[a], List[b], List[c], List[d], "
            "List[a, b, c], List[a, b, d], List[a, c, d], List[b, c, d]]",
        )

    def test_tuples_per_position_widths(self) -> None:
        # ``Tuples[{1, 2}, {2, 3}]`` shape produces 2x3 tensor of choices.
        # 64 combinations total: 2^2 outer slots × 2^3 inner slots = 8 × 8 = 64.
        result = _full("Tuples[{1, 2}, {2, 3}]")
        self.assertTrue(result.startswith("List["))
        # Count top-level outer elements: each outer entry is a
        # 2-element ``List[List[…], List[…]]`` block.
        # Probe specific entries to confirm shape rather than relying on
        # substring counts.
        self.assertIn("List[List[1, 1, 1], List[1, 1, 1]]", result)
        self.assertIn("List[List[2, 2, 2], List[2, 2, 2]]", result)
        # The full output begins with "List[" + 64 inner blocks separated by ", ".
        # Count how many opening "List[List[1, 1, 1]" or similar occur to verify
        # outer cardinality is 64.
        outer_open_count = result.count("List[List[")
        # There are 64 outer-block openings for shape {2, 3}.
        self.assertEqual(outer_open_count, 64)


class RiffleSpanTests(unittest.TestCase):
    def test_riffle_with_span_to_natural_end(self) -> None:
        self.assertEqual(
            _full("Riffle[{a, b, c, d, e}, x, {2, -1, 2}]"),
            "List[a, x, b, x, c, x, d, x, e, x]",
        )

    def test_riffle_with_step_3(self) -> None:
        self.assertEqual(
            _full("Riffle[{a, b, c, d, e, f, g}, x, {2, -1, 3}]"),
            "List[a, x, b, c, x, d, e, x, f, g, x]",
        )


class TraceContractAndThroughTests(unittest.TestCase):
    def test_tr_columnwise_via_three_arg(self) -> None:
        # ``Tr[m, Plus, 1]`` of a matrix is column-wise sum.
        self.assertEqual(
            _full("Tr[{{1, 2}, {3, 4}}, Plus, 1]"),
            "List[4, 6]",
        )

    def test_through_two_arg_filter_preserves_when_head_mismatches(self) -> None:
        # Head is Plus, not List, so Through[..., List] returns expr unchanged.
        self.assertEqual(
            _full("Through[(f + g)[x, y], List]"),
            "Plus[f, g][x, y]",
        )


class RotatePerAxisTests(unittest.TestCase):
    def test_rotate_left_two_axes(self) -> None:
        self.assertEqual(
            _full("RotateLeft[{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}, {1, 2}]"),
            "List[List[6, 4, 5], List[9, 7, 8], List[3, 1, 2]]",
        )

    def test_rotate_right_two_axes(self) -> None:
        self.assertEqual(
            _full("RotateRight[{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}, {1, 2}]"),
            "List[List[8, 9, 7], List[2, 3, 1], List[5, 6, 4]]",
        )


class HeadsOptionTests(unittest.TestCase):
    def test_cases_heads_option(self) -> None:
        self.assertEqual(
            _full("Cases[{1, 2, 3, f[1], g[2]}, _Integer, Infinity, Heads -> True]"),
            "List[1, 2, 3, 1, 2]",
        )
        self.assertEqual(
            _full("Cases[{1, 2, 3, f[1], g[2]}, _Integer, Infinity, Heads -> False]"),
            "List[1, 2, 3, 1, 2]",
        )

    def test_count_heads_option(self) -> None:
        self.assertEqual(
            _full("Count[{1, 2, 3, f[1], g[2]}, _Integer, Infinity, Heads -> True]"),
            "5",
        )

    def test_memberq_heads_option(self) -> None:
        # ``MemberQ`` with ``Heads -> True`` finds the symbol heads of
        # subexpressions; here ``f`` is the head of ``f[1]``.
        self.assertEqual(
            _full("MemberQ[{f[1], g[2]}, f, {0, Infinity}, Heads -> True]"),
            "True",
        )
        self.assertEqual(
            _full("MemberQ[{f[1], g[2]}, f, {0, Infinity}, Heads -> False]"),
            "False",
        )


class DeleteCasesLevel0Tests(unittest.TestCase):
    def test_delete_cases_level_0_no_match_passthrough(self) -> None:
        # Whole expression doesn't match; result unchanged.
        self.assertEqual(
            _full("DeleteCases[{1, {2, 3}}, {2, 3}, {0}]"),
            "List[1, List[2, 3]]",
        )

    def test_delete_cases_level_0_match_yields_sequence(self) -> None:
        # Whole expression matches; the kernel returns ``Sequence[]``.
        self.assertEqual(
            _full("DeleteCases[{2, 3}, {2, 3}, {0}]"),
            "Sequence[]",
        )


class DeleteDuplicatesByTestArgTests(unittest.TestCase):
    def test_test_arg_uses_custom_equality(self) -> None:
        # Two values with the same Mod-3 key collapse under SameQ on
        # the keys; with a permissive ``a > b`` test we drop earlier
        # ones and keep only the largest.
        self.assertEqual(
            _full("DeleteDuplicatesBy[{1, 2, 3, 4, 5, 6}, Mod[#, 3] &, SameQ]"),
            "List[1, 2, 3]",
        )


if __name__ == "__main__":
    unittest.main()
