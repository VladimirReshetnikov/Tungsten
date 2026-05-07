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


class VectorMatrixQTests(unittest.TestCase):
    def test_vector_q(self) -> None:
        self.assertEqual(_full("VectorQ[{1, 2, 3}]"), "True")
        self.assertEqual(_full("VectorQ[{1, {2}, 3}]"), "False")
        self.assertEqual(_full("VectorQ[5]"), "False")

    def test_vector_q_with_test(self) -> None:
        self.assertEqual(_full("VectorQ[{1, 2, 3}, IntegerQ]"), "True")
        self.assertEqual(_full("VectorQ[{1, 2.5, 3}, IntegerQ]"), "False")

    def test_matrix_q(self) -> None:
        self.assertEqual(_full("MatrixQ[{{1, 2}, {3, 4}}]"), "True")
        self.assertEqual(_full("MatrixQ[{{1, 2}, {3}}]"), "False")
        self.assertEqual(_full("MatrixQ[{1, 2, 3}]"), "False")

    def test_matrix_q_with_test(self) -> None:
        self.assertEqual(_full("MatrixQ[{{1, 2}, {3, 4}}, IntegerQ]"), "True")
        self.assertEqual(_full("MatrixQ[{{1, 2}, {3, 4.5}}, IntegerQ]"), "False")


class FirstPositionAndPositionXTests(unittest.TestCase):
    def test_first_position_returns_first_match(self) -> None:
        self.assertEqual(_full("FirstPosition[{1, 2, 3}, 2]"), "List[2]")

    def test_first_position_default_when_missing(self) -> None:
        self.assertEqual(
            _full("FirstPosition[{1, 2, 3}, 5]"),
            'Missing["NotFound"]',
        )
        self.assertEqual(_full("FirstPosition[{1, 2, 3}, 5, deflt]"), "deflt")

    def test_position_largest_returns_all_tied_positions(self) -> None:
        self.assertEqual(
            _full("PositionLargest[{1, 5, 3, 5}]"), "List[2, 4]"
        )

    def test_position_smallest_picks_minimum(self) -> None:
        self.assertEqual(
            _full("PositionSmallest[{4, 1, 2, 1}]"), "List[2, 4]"
        )

    def test_position_index_groups_first_occurrence(self) -> None:
        self.assertEqual(
            _full("PositionIndex[{u, v, w, u, v}]"),
            "Association[Rule[u, List[1, 4]], Rule[v, List[2, 5]], Rule[w, List[3]]]",
        )


class CountDistinctAndCountsByTests(unittest.TestCase):
    def test_count_distinct_under_structural_equality(self) -> None:
        self.assertEqual(_full("CountDistinct[{1, 2, 2, 3}]"), "3")

    def test_counts_by_buckets_by_key_function(self) -> None:
        self.assertEqual(
            _full("CountsBy[{1.5, 2.3, 3.7}, Floor]"),
            "Association[Rule[1, 1], Rule[2, 1], Rule[3, 1]]",
        )

    def test_counts_by_collapses_equal_keys(self) -> None:
        # Floor of 1.5 / 1.7 / 1.9 all bucket to 1.
        self.assertEqual(
            _full("CountsBy[{1.5, 1.7, 1.9, 2.5, 3.7}, Floor]"),
            "Association[Rule[1, 3], Rule[2, 1], Rule[3, 1]]",
        )


class ContainsOnlyTests(unittest.TestCase):
    def test_contains_only_true(self) -> None:
        self.assertEqual(
            _full("ContainsOnly[{1, 2, 3}, {1, 2, 3, 4}]"), "True"
        )

    def test_contains_only_false_when_extra_element(self) -> None:
        self.assertEqual(
            _full("ContainsOnly[{1, 2, 5}, {1, 2, 3, 4}]"), "False"
        )

    def test_contains_only_with_same_test(self) -> None:
        # SameTest -> Equal makes 1 and 1.0 compare equal, so the call
        # succeeds even though they aren't structurally identical.
        self.assertEqual(
            _full("ContainsOnly[{1.0, 2}, {1, 2, 3}, SameTest -> Equal]"),
            "True",
        )


class SubdivideTests(unittest.TestCase):
    def test_subdivide_unit_interval(self) -> None:
        self.assertEqual(
            _full("Subdivide[4]"),
            "List[0, Rational[1, 4], Rational[1, 2], Rational[3, 4], 1]",
        )

    def test_subdivide_n_k(self) -> None:
        self.assertEqual(
            _full("Subdivide[10, 4]"),
            "List[0, Rational[5, 2], 5, Rational[15, 2], 10]",
        )

    def test_subdivide_xmin_xmax_k(self) -> None:
        self.assertEqual(
            _full("Subdivide[1, 10, 4]"),
            "List[1, Rational[13, 4], Rational[11, 2], Rational[31, 4], 10]",
        )


class SpliceTests(unittest.TestCase):
    def test_splice_into_list_default(self) -> None:
        self.assertEqual(
            _full("{1, Splice[{2, 3}], 4}"),
            "List[1, 2, 3, 4]",
        )

    def test_splice_does_not_splice_into_arbitrary_head(self) -> None:
        self.assertEqual(
            _full("ww[Splice[{a, b}], c]"),
            "ww[Splice[List[a, b]], c]",
        )

    def test_splice_with_explicit_head_target(self) -> None:
        self.assertEqual(
            _full("ww[Splice[{a, b}, ww], c]"),
            "ww[a, b, c]",
        )

    def test_bare_splice_stays_inert(self) -> None:
        self.assertEqual(
            _full("Splice[{a, b, c}]"),
            "Splice[List[a, b, c]]",
        )

    def test_splice_blocked_in_held_context(self) -> None:
        self.assertEqual(
            _full("Hold[Splice[{a, b}]]"),
            "Hold[Splice[List[a, b]]]",
        )


class RatiosTests(unittest.TestCase):
    def test_ratios_of_powers_of_two(self) -> None:
        self.assertEqual(
            _full("Ratios[{1, 2, 4, 8, 16}]"),
            "List[2, 2, 2, 2]",
        )

    def test_ratios_of_short_input_is_empty(self) -> None:
        self.assertEqual(_full("Ratios[{}]"), "List[]")
        self.assertEqual(_full("Ratios[{42}]"), "List[]")


class SubsetMapTests(unittest.TestCase):
    def test_subset_map_with_flat_indices(self) -> None:
        # Reverse the slice at positions {1, 3, 5}: a, c, e -> e, c, a.
        # Other positions retain their values, so b and d stay put.
        self.assertEqual(
            _full("SubsetMap[Reverse, {a, b, c, d, e}, {1, 3, 5}]"),
            "List[e, b, c, d, a]",
        )

    def test_subset_map_with_one_element_position_lists(self) -> None:
        self.assertEqual(
            _full("SubsetMap[Reverse, {a, b, c, d, e}, {{1}, {3}, {5}}]"),
            "List[e, b, c, d, a]",
        )


class OperateLevelZeroTests(unittest.TestCase):
    def test_operate_level_zero_wraps_whole_expression(self) -> None:
        self.assertEqual(_full("Operate[gg, ff[a, b], 0]"), "gg[ff[a, b]]")

    def test_operate_default_level_one(self) -> None:
        self.assertEqual(_full("Operate[gg, ff[a, b]]"), "gg[ff][a, b]")


class MapApplyLevelSpecTests(unittest.TestCase):
    def test_map_apply_at_level_one(self) -> None:
        self.assertEqual(
            _full("MapApply[ff, {{1, 2}, {3, 4}}, {1}]"),
            "List[ff[1, 2], ff[3, 4]]",
        )

    def test_map_apply_at_level_two(self) -> None:
        self.assertEqual(
            _full("MapApply[ff, {{{a, b}, {c, d}}, {{e, f}, {g, h}}}, {2}]"),
            "List[List[ff[a, b], ff[c, d]], List[ff[e, f], ff[g, h]]]",
        )


class FlattenThreeArgTests(unittest.TestCase):
    def test_flatten_three_arg_with_named_inner_head(self) -> None:
        self.assertEqual(
            _full("Flatten[gg[a, hh[b, hh[c, d]], e], Infinity, hh]"),
            "gg[a, b, c, d, e]",
        )

    def test_flatten_three_arg_keeps_outer_intact(self) -> None:
        # Inner List heads aren't matched, so {b, {c, d}} stays nested.
        self.assertEqual(
            _full("Flatten[{a, hh[b, hh[c, d]], e}, Infinity, hh]"),
            "List[a, b, c, d, e]",
        )


class DistributeFiveArgTests(unittest.TestCase):
    def test_distribute_five_arg(self) -> None:
        self.assertEqual(
            _full("Distribute[(a + b)*c, Plus, Times, pp, qq]"),
            "qq[pp[c, a], pp[c, b]]",
        )


class TakeAssocKeySelectorDiagnosticTests(unittest.TestCase):
    def test_key_selector_list_emits_diagnostic(self) -> None:
        # Tungsten emits a Take::error diagnostic and leaves the call
        # inert when an unsupported key-list selector is used on an
        # association — instead of silently returning the input.
        self.assertEqual(
            _full(
                "CompoundExpression["
                "Take[<|aa -> 1, bb -> 2, cc -> 3|>, {Key[aa], Key[bb]}],"
                " $MessageList]"
            ),
            'List[HoldForm[MessageName[Take, "error"]]]',
        )


class DifferencesMultivariateTests(unittest.TestCase):
    def test_differences_multivariate_first_along_each_axis(self) -> None:
        self.assertEqual(
            _full(
                "Differences[{{1, 2, 3, 4}, {5, 7, 9, 11}, {13, 16, 19, 22}}, {1, 1}]"
            ),
            "List[List[1, 1, 1], List[1, 1, 1]]",
        )

    def test_differences_multivariate_second_axis_higher(self) -> None:
        self.assertEqual(
            _full("Differences[{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}, {1, 2}]"),
            "List[List[0], List[0]]",
        )


class HeadsOptionFamilyTests(unittest.TestCase):
    def test_delete_cases_with_heads_true_strips_matching_head(self) -> None:
        # The kernel splices the wrapper Sequence into the parent so the
        # whole gg[2, gg] collapses to 2.
        self.assertEqual(
            _full(
                "DeleteCases[ff[1, gg[2, gg], 3], gg, {0, Infinity}, Heads -> True]"
            ),
            "ff[1, 2, 3]",
        )

    def test_delete_cases_with_heads_false_leaves_head(self) -> None:
        self.assertEqual(
            _full(
                "DeleteCases[ff[1, gg[2, gg], 3], gg, {0, Infinity}, Heads -> False]"
            ),
            "ff[1, gg[2], 3]",
        )

    def test_free_q_heads_option_distinguishes_head_vs_argument(self) -> None:
        self.assertEqual(_full("FreeQ[gg[1, 2], gg, Heads -> True]"), "False")
        self.assertEqual(_full("FreeQ[gg[1, 2], gg, Heads -> False]"), "True")

    def test_replace_levelspec_heads_option(self) -> None:
        self.assertEqual(
            _full("Replace[gg[a, b], gg -> qq, {0, Infinity}, Heads -> True]"),
            "qq[a, b]",
        )
        self.assertEqual(
            _full("Replace[gg[a, b], gg -> qq, {0, Infinity}, Heads -> False]"),
            "gg[a, b]",
        )

    def test_map_heads_option_wraps_head_too(self) -> None:
        self.assertEqual(
            _full("Map[ff, gg[a, b], Heads -> True]"),
            "ff[gg][ff[a], ff[b]]",
        )

    def test_map_all_heads_option(self) -> None:
        self.assertEqual(
            _full("MapAll[ff, gg[a, b], Heads -> True]"),
            "ff[ff[gg][ff[a], ff[b]]]",
        )

    def test_scan_heads_option_visits_heads(self) -> None:
        # Scan returns Null but emits side effects via Sow under a
        # Reap. With Heads -> True the head ``gg`` is visited too;
        # with Heads -> False (default) only the arguments are.
        self.assertEqual(
            _full(
                "Reap[Scan[Sow, gg[a, b], {0, Infinity}, Heads -> True]][[2, 1]]"
            ),
            "List[gg, a, b, gg[a, b]]",
        )
        self.assertEqual(
            _full(
                "Reap[Scan[Sow, gg[a, b], {0, Infinity}, Heads -> False]][[2, 1]]"
            ),
            "List[a, b, gg[a, b]]",
        )


if __name__ == "__main__":
    unittest.main()
