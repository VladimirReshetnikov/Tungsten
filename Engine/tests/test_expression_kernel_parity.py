"""Regression tests for Tungsten expression parser/evaluator parity with the
live Wolfram kernel.

These tests were added as part of the 2026-04-24 external consultant review.
Two groups:

1. ``*_current_behavior`` tests lock in what Tungsten does *today*, so that
   any accidental regression of current behavior is caught.
2. ``*_wolfram_target`` tests are decorated with ``@expectedFailure`` and
   express the Wolfram-correct target behavior. They will become
   ``unexpectedSuccess`` once the corresponding bug is fixed, which is the
   signal to remove the decorator and update the related ``*_current_behavior``
   tests accordingly.

Findings B1-B9 come from the original parity report
(``2026-04-24-parser-evaluator-kernel-parity.md``); findings B10-B18 come from
the evil-QA addendum (``2026-04-24-parser-evaluator-kernel-parity-evil-qa.md``).
Every ``*_wolfram_target`` test has a short comment pointing at its finding ID.
"""
from __future__ import annotations

import unittest

from tungsten.expression import (
    WolframEvaluationError,
    WolframSyntaxError,
    evaluate,
    parse_expression,
)


def _full(text: str) -> str:
    return evaluate(parse_expression(text, form="input")).to_full_form()


class ChainedComparisonTests(unittest.TestCase):
    """Finding B1: chained comparison operators parse left-associatively."""

    def test_chained_less_current_behavior(self) -> None:
        # Tungsten currently parses ``1 < 2 < 3`` as ``Less[Less[1, 2], 3]``,
        # evaluates the inner to ``True``, and leaves the outer inert.
        self.assertEqual(_full("1 < 2 < 3"), "Less[True, 3]")
        self.assertEqual(_full("1 < 3 < 2"), "Less[True, 2]")

    def test_chained_less_equal_current_behavior(self) -> None:
        self.assertEqual(_full("1 <= 1 <= 2"), "LessEqual[True, 2]")

    def test_chained_greater_current_behavior(self) -> None:
        self.assertEqual(_full("5 > 3 > 1"), "Greater[True, 1]")

    def test_chained_equal_current_behavior(self) -> None:
        self.assertEqual(_full("1 == 1 == 1"), "Equal[True, 1]")

    def test_chained_unequal_current_behavior(self) -> None:
        self.assertEqual(_full("1 != 2 != 3"), "Unequal[True, 3]")

    @unittest.expectedFailure
    def test_chained_less_wolfram_target(self) -> None:
        # Wolfram parses ``a < b < c`` as ``Less[a, b, c]`` (n-ary) and returns
        # True/False based on monotonicity. See finding B1.
        self.assertEqual(_full("1 < 2 < 3"), "True")

    @unittest.expectedFailure
    def test_chained_less_false_wolfram_target(self) -> None:
        self.assertEqual(_full("1 < 3 < 2"), "False")

    @unittest.expectedFailure
    def test_chained_equal_wolfram_target(self) -> None:
        self.assertEqual(_full("1 == 1 == 1"), "True")


class PositionDefaultLevelSpecTests(unittest.TestCase):
    """Finding B2: Position's default levelspec is ``{1}`` in Tungsten but
    ``{0, Infinity}`` in Wolfram."""

    def test_explicit_full_level_works(self) -> None:
        # With explicit ``{0, Infinity}`` Tungsten agrees with the kernel.
        self.assertEqual(
            _full("Position[f[a, g[b, a]], a, {0, Infinity}]"),
            "List[List[1], List[2, 2]]",
        )

    def test_position_default_current_behavior(self) -> None:
        # Tungsten today: default levelspec is {1}, so only the top-level match
        # is returned.
        self.assertEqual(
            _full("Position[f[a, g[b, a]], a]"),
            "List[List[1]]",
        )

    @unittest.expectedFailure
    def test_position_default_wolfram_target(self) -> None:
        # Wolfram's default for Position is ``{0, Infinity}`` (search everywhere
        # including heads). See finding B2.
        self.assertEqual(
            _full("Position[f[a, g[b, a]], a]"),
            "List[List[1], List[2, 2]]",
        )


class LevelSemanticsTests(unittest.TestCase):
    """Finding B3 (Level negative-int spec) and B4 (Level traversal order)."""

    def test_level_minus_one_current_behavior(self) -> None:
        # Tungsten today: ``Level[expr, -1]`` returns only atoms at depth 1.
        self.assertEqual(_full("Level[f[a, g[b]], -1]"), "List[a, b]")

    def test_level_positive_two_current_behavior_order(self) -> None:
        # Tungsten today: preorder traversal, so ``g[b]`` appears before its
        # child ``b``.
        self.assertEqual(_full("Level[f[a, g[b]], 2]"), "List[a, g[b], b]")

    def test_level_infinity_current_behavior_order(self) -> None:
        # Same preorder pattern at Infinity.
        self.assertEqual(
            _full("Level[f[a, g[b, c]], Infinity]"),
            "List[a, g[b, c], b, c]",
        )

    def test_level_explicit_single_atoms_works(self) -> None:
        # ``Level[expr, {-1}]`` (single negative) currently returns atoms only.
        # This matches Wolfram's semantics for the single-level form and is not
        # affected by the B3 bug.
        self.assertEqual(_full("Level[f[a, g[b]], {-1}]"), "List[a, b]")

    @unittest.expectedFailure
    def test_level_minus_one_wolfram_target(self) -> None:
        # Wolfram: ``Level[expr, -n]`` is shorthand for ``{1, -n}``. For
        # ``f[a, g[b]]`` it yields everything except the root. See finding B3.
        self.assertEqual(_full("Level[f[a, g[b]], -1]"), "List[a, b, g[b]]")

    @unittest.expectedFailure
    def test_level_positive_two_wolfram_target(self) -> None:
        # Wolfram uses postorder, so children appear before their container.
        self.assertEqual(_full("Level[f[a, g[b]], 2]"), "List[a, b, g[b]]")

    @unittest.expectedFailure
    def test_level_infinity_wolfram_target(self) -> None:
        self.assertEqual(
            _full("Level[f[a, g[b, c]], Infinity]"),
            "List[a, b, c, g[b, c]]",
        )


class DotEvaluationTests(unittest.TestCase):
    """Finding B5: Dot constructs ``Plus[Times[...], ...]`` but does not
    re-evaluate."""

    def test_dot_vector_current_behavior(self) -> None:
        # Tungsten today returns the unsimplified Plus/Times sum-of-products.
        self.assertEqual(
            _full("{1, 2, 3} . {4, 5, 6}"),
            "Plus[Times[1, 4], Times[2, 5], Times[3, 6]]",
        )

    def test_dot_matrix_vector_current_behavior(self) -> None:
        self.assertEqual(
            _full("{{1, 2}, {3, 4}} . {5, 6}"),
            "List[Plus[Times[1, 5], Times[2, 6]], Plus[Times[3, 5], Times[4, 6]]]",
        )

    def test_explicit_plus_of_times_does_simplify(self) -> None:
        # Confirms that the simplification pipeline *does* exist and fires when
        # the same Plus/Times call is evaluated directly -- the Dot bug is the
        # missing re-evaluation pass, not a missing arithmetic feature.
        self.assertEqual(
            _full("Plus[Times[1, 4], Times[2, 5], Times[3, 6]]"),
            "32",
        )

    @unittest.expectedFailure
    def test_dot_vector_wolfram_target(self) -> None:
        # Wolfram fully evaluates all-integer dot products. See finding B5.
        self.assertEqual(_full("{1, 2, 3} . {4, 5, 6}"), "32")

    @unittest.expectedFailure
    def test_dot_matrix_vector_wolfram_target(self) -> None:
        self.assertEqual(
            _full("{{1, 2}, {3, 4}} . {5, 6}"),
            "List[17, 39]",
        )


class AssociationDuplicateKeyTests(unittest.TestCase):
    """Finding B6: on duplicate keys, Tungsten moves the winning entry to the
    later position instead of preserving the first-occurrence position."""

    def test_duplicate_key_current_behavior(self) -> None:
        # Tungsten today: ``b`` keeps its position, ``a`` (duplicate) is
        # appended at the end with the later value.
        self.assertEqual(
            _full("<|a -> 1, b -> 2, a -> 3|>"),
            "Association[Rule[b, 2], Rule[a, 3]]",
        )

    @unittest.expectedFailure
    def test_duplicate_key_wolfram_target(self) -> None:
        # Wolfram preserves the *first-occurrence* position of the key and
        # updates its value to the last-occurrence value. See finding B6.
        self.assertEqual(
            _full("<|a -> 1, b -> 2, a -> 3|>"),
            "Association[Rule[a, 3], Rule[b, 2]]",
        )


class InfinityRenderingTests(unittest.TestCase):
    """Finding B8: ``Min[]`` / ``Max[]`` render Infinity as a raw symbol, but
    Wolfram's FullForm canonicalizes to ``DirectedInfinity[1]``."""

    def test_min_empty_current_behavior(self) -> None:
        self.assertEqual(_full("Min[]"), "Infinity")

    def test_max_empty_current_behavior(self) -> None:
        self.assertEqual(_full("Max[]"), "-Infinity")

    @unittest.expectedFailure
    def test_min_empty_wolfram_target(self) -> None:
        self.assertEqual(_full("Min[]"), "DirectedInfinity[1]")

    @unittest.expectedFailure
    def test_max_empty_wolfram_target(self) -> None:
        self.assertEqual(_full("Max[]"), "DirectedInfinity[-1]")


class ParserNaryGroupingTests(unittest.TestCase):
    """Finding B7: the parser produces left-associative binary trees for
    chained infix operators, where Wolfram's parser produces flat n-ary calls.

    This is the structural root cause of B1 -- the comparison case surfaces as
    a semantic bug because ``Less[Less[1, 2], 3]`` cannot be evaluated. For
    ``Plus`` / ``Times`` the difference is mostly invisible because the
    evaluator recurses bottom-up, but the AST still differs from Wolfram's.
    """

    def test_parser_plus_binary_current_behavior(self) -> None:
        expr = parse_expression("a + b + c", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[Plus[a, b], c]")

    def test_parser_times_binary_current_behavior(self) -> None:
        expr = parse_expression("a * b * c", form="input")
        self.assertEqual(expr.to_full_form(), "Times[Times[a, b], c]")

    def test_parser_mixed_subtraction_current_behavior(self) -> None:
        expr = parse_expression("a + b - c", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[Plus[a, b], Times[-1, c]]")

    @unittest.expectedFailure
    def test_parser_plus_nary_wolfram_target(self) -> None:
        expr = parse_expression("a + b + c", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[a, b, c]")

    @unittest.expectedFailure
    def test_parser_times_nary_wolfram_target(self) -> None:
        expr = parse_expression("a * b * c", form="input")
        self.assertEqual(expr.to_full_form(), "Times[a, b, c]")


class InertArithmeticBoundariesTests(unittest.TestCase):
    """Documented boundary behavior: direct-call ``Plus[1, 2, a]`` stays inert,
    but infix ``1 + 2 + a`` evaluates to ``Plus[3, a]`` via the binary-tree
    evaluation pass. These tests lock in the current documented behavior so
    any change is conscious."""

    def test_plus_direct_call_mixed_inert(self) -> None:
        # Per docs: ``Plus[i1, ...]`` evaluates only when every argument is an
        # explicit integer. Mixed arguments remain inert.
        self.assertEqual(_full("Plus[1, 2, a]"), "Plus[1, 2, a]")

    def test_plus_infix_mixed_simplifies_inner(self) -> None:
        self.assertEqual(_full("1 + 2 + a"), "Plus[3, a]")

    def test_length_of_inert_plus(self) -> None:
        # Kernel: ``Length[Plus[1, 2, a]]`` = 2 after orderless flattening.
        # Tungsten leaves Plus inert so length counts the three raw args.
        self.assertEqual(_full("Length[Plus[1, 2, a]]"), "3")


class AtPrefixPrecedenceTests(unittest.TestCase):
    """Finding B10: the ``@`` prefix operator binds too loosely.

    In Wolfram, ``f @ 1 + 2`` means ``f[1] + 2`` (the ``@`` prefix application
    binds tighter than ``+`` and ``*``). Tungsten sets ``_AT_BP = 40``, which
    is *lower* than ``+`` (120) and ``*`` (140), so ``f @ 1 + 2`` parses as
    ``f[1 + 2] = f[3]``."""

    def test_at_plus_current_behavior(self) -> None:
        # Tungsten today: @ binds LOOSER than +, so f @ 1 + 2 = f[3].
        self.assertEqual(_full("f @ 1 + 2"), "f[3]")

    def test_at_times_current_behavior(self) -> None:
        self.assertEqual(_full("f @ x * 2"), "f[Times[x, 2]]")

    def test_at_right_assoc_still_works(self) -> None:
        # Right-associative chains of @ are unaffected by the precedence bug.
        self.assertEqual(_full("f @ g @ h @ x"), "f[g[h[x]]]")

    @unittest.expectedFailure
    def test_at_plus_wolfram_target(self) -> None:
        # Wolfram: f @ 1 + 2 = Plus[f[1], 2] (after Orderless canonicalization).
        # See finding B10.
        self.assertEqual(_full("f @ 1 + 2"), "Plus[f[1], 2]")

    @unittest.expectedFailure
    def test_at_times_wolfram_target(self) -> None:
        # Wolfram: f @ x * 2 = Times[2, f[x]].
        self.assertEqual(_full("f @ x * 2"), "Times[2, f[x]]")


class SpanParserTests(unittest.TestCase):
    """Finding B11: ``;;`` parses as left-associative binary, so
    ``1 ;; 5 ;; 2`` becomes ``Span[1, Span[5, 2]]`` instead of the Wolfram
    canonical ``Span[1, 5, 2]``. Same root cause as B1/B7."""

    def test_span_binary_current_behavior(self) -> None:
        expr = parse_expression("1 ;; 5 ;; 2", form="input")
        self.assertEqual(expr.to_full_form(), "Span[1, Span[5, 2]]")

    def test_span_reverse_binary_current_behavior(self) -> None:
        expr = parse_expression("5 ;; 1 ;; -1", form="input")
        self.assertEqual(expr.to_full_form(), "Span[5, Span[1, -1]]")

    def test_part_with_literal_reverse_span_current_behavior(self) -> None:
        # Tungsten's Part with the buggy nested span returns only the first element.
        self.assertEqual(
            _full("{a, b, c, d, e}[[5 ;; 1 ;; -1]]"),
            "List[e]",
        )

    def test_part_with_literal_step_span_current_behavior(self) -> None:
        # The step is effectively ignored because of the nested shape.
        self.assertEqual(
            _full("{a, b, c, d, e}[[1 ;; 5 ;; 2]]"),
            "List[a, b, c, d, e]",
        )

    def test_part_with_explicit_span_head_works(self) -> None:
        # Using Span[...] directly bypasses the parser bug.
        self.assertEqual(
            _full("Part[{a, b, c, d, e}, Span[1, 5, 2]]"),
            "List[a, c, e]",
        )

    @unittest.expectedFailure
    def test_span_ternary_wolfram_target(self) -> None:
        # Wolfram: 1 ;; 5 ;; 2 parses as Span[1, 5, 2]. See finding B11.
        expr = parse_expression("1 ;; 5 ;; 2", form="input")
        self.assertEqual(expr.to_full_form(), "Span[1, 5, 2]")

    @unittest.expectedFailure
    def test_part_reverse_span_wolfram_target(self) -> None:
        self.assertEqual(
            _full("{a, b, c, d, e}[[5 ;; 1 ;; -1]]"),
            "List[e, d, c, b, a]",
        )

    @unittest.expectedFailure
    def test_part_step_span_wolfram_target(self) -> None:
        self.assertEqual(
            _full("{a, b, c, d, e}[[1 ;; 5 ;; 2]]"),
            "List[a, c, e]",
        )


class KeyMapEvaluationTests(unittest.TestCase):
    """Finding B12: ``KeyMap[f, assoc]`` builds ``f[key]`` calls but never
    re-evaluates them, so calling with a pure function or ``Identity`` leaves
    a stale Call in each rule."""

    def test_key_map_pure_fn_current_behavior(self) -> None:
        self.assertEqual(
            _full("KeyMap[# &, <|a -> 1, b -> 2|>]"),
            "Association[Rule[Function[Slot[1]][a], 1], Rule[Function[Slot[1]][b], 2]]",
        )

    def test_key_map_identity_current_behavior(self) -> None:
        self.assertEqual(
            _full("KeyMap[Identity, <|a -> 1|>]"),
            "Association[Rule[Identity[a], 1]]",
        )

    def test_key_map_symbol_head_passes_through(self) -> None:
        # For a plain symbol head, no further evaluation is needed, so the
        # bug is invisible here -- kernel also returns <|f[a] -> 1|>.
        self.assertEqual(
            _full("KeyMap[f, <|a -> 1|>]"),
            "Association[Rule[f[a], 1]]",
        )

    @unittest.expectedFailure
    def test_key_map_pure_fn_wolfram_target(self) -> None:
        # Wolfram: ``KeyMap[# &, ...]`` returns the original association (identity
        # on keys). See finding B12.
        self.assertEqual(
            _full("KeyMap[# &, <|a -> 1, b -> 2|>]"),
            "Association[Rule[a, 1], Rule[b, 2]]",
        )

    @unittest.expectedFailure
    def test_key_map_identity_wolfram_target(self) -> None:
        self.assertEqual(
            _full("KeyMap[Identity, <|a -> 1|>]"),
            "Association[Rule[a, 1]]",
        )


class AssociationAsFunctionTests(unittest.TestCase):
    """Finding B13: Wolfram associations act as functions -- ``assoc[key]``
    returns the value for that key. Tungsten leaves the application inert,
    which breaks the ``#name`` shorthand documented in the parser guide."""

    def test_assoc_call_current_behavior(self) -> None:
        # Tungsten: the call expression is left as-is.
        self.assertEqual(
            _full("<|\"name\" -> x|>[\"name\"]"),
            'Association[Rule["name", x]]["name"]',
        )

    def test_name_shorthand_current_behavior(self) -> None:
        # #name & [assoc] expands to assoc["name"] which also stays inert.
        self.assertEqual(
            _full("#name & [<|\"name\" -> x|>]"),
            'Association[Rule["name", x]]["name"]',
        )

    def test_part_with_key_works(self) -> None:
        # Using Part[assoc, Key[k]] or the "k" shorthand *does* work today.
        self.assertEqual(
            _full("<|\"name\" -> x|>[[Key[\"name\"]]]"),
            "x",
        )

    @unittest.expectedFailure
    def test_assoc_call_wolfram_target(self) -> None:
        # Wolfram: assoc["key"] evaluates to the stored value. See finding B13.
        self.assertEqual(
            _full("<|\"name\" -> x|>[\"name\"]"),
            "x",
        )

    @unittest.expectedFailure
    def test_name_shorthand_wolfram_target(self) -> None:
        self.assertEqual(
            _full("#name & [<|\"name\" -> x|>]"),
            "x",
        )


class FixedPointMaxIterationsTests(unittest.TestCase):
    """Finding B14: ``FixedPoint[f, x, n]`` treats ``n`` as a hard error cap.
    Wolfram treats ``n`` as a soft limit -- after n iterations, return the
    current value without error."""

    def test_fixed_point_soft_limit_current_behavior_raises(self) -> None:
        # With n=2 and a function that never converges, Tungsten raises
        # rather than returning the value after 2 steps.
        with self.assertRaises(WolframEvaluationError):
            evaluate(parse_expression("FixedPoint[# - 1 &, 5, 2]", form="input"))

    def test_fixed_point_n_zero_current_behavior_raises(self) -> None:
        # Even n=0 raises, where Wolfram would return the starting value 5.
        with self.assertRaises(WolframEvaluationError):
            evaluate(parse_expression("FixedPoint[# - 1 &, 5, 0]", form="input"))

    def test_fixed_point_convergent_case_works(self) -> None:
        # When convergence happens before the cap, Tungsten returns correctly.
        self.assertEqual(_full("FixedPoint[Identity, 5, 10]"), "5")

    @unittest.expectedFailure
    def test_fixed_point_soft_limit_wolfram_target(self) -> None:
        # Wolfram: FixedPoint[# - 1 &, 5, 2] = 3 (5 -> 4 -> 3, stop).
        # See finding B14.
        self.assertEqual(_full("FixedPoint[# - 1 &, 5, 2]"), "3")

    @unittest.expectedFailure
    def test_fixed_point_n_zero_wolfram_target(self) -> None:
        # Wolfram: FixedPoint[f, x, 0] = x, no iterations.
        self.assertEqual(_full("FixedPoint[# - 1 &, 5, 0]"), "5")


class SequenceSplicingTests(unittest.TestCase):
    """Finding B15: Wolfram's ``Sequence[...]`` auto-splices when it appears
    as an argument of another call. Tungsten leaves it inert."""

    def test_sequence_in_list_current_behavior(self) -> None:
        self.assertEqual(
            _full("{Sequence[1, 2], 3}"),
            "List[Sequence[1, 2], 3]",
        )

    def test_sequence_in_call_current_behavior(self) -> None:
        self.assertEqual(
            _full("f[Sequence[1, 2], 3]"),
            "f[Sequence[1, 2], 3]",
        )

    @unittest.expectedFailure
    def test_sequence_in_list_wolfram_target(self) -> None:
        # Wolfram: {Sequence[1, 2], 3} splices to {1, 2, 3}. See finding B15.
        self.assertEqual(
            _full("{Sequence[1, 2], 3}"),
            "List[1, 2, 3]",
        )

    @unittest.expectedFailure
    def test_sequence_in_call_wolfram_target(self) -> None:
        self.assertEqual(
            _full("f[Sequence[1, 2], 3]"),
            "f[1, 2, 3]",
        )


class DoubleUnaryMinusTests(unittest.TestCase):
    """Finding B16: parser accepts ``--5`` where Wolfram rejects it as
    illegal syntax. Low-priority permissiveness."""

    def test_double_unary_minus_current_behavior_accepts(self) -> None:
        # Tungsten: --5 parses and evaluates to 5.
        self.assertEqual(_full("--5"), "5")

    @unittest.expectedFailure
    def test_double_unary_minus_wolfram_target_rejects(self) -> None:
        # Wolfram rejects --5 at parse time (it sees `--` as decrement, not
        # a double unary negation). See finding B16.
        with self.assertRaises((WolframSyntaxError, WolframEvaluationError)):
            evaluate(parse_expression("--5", form="input"))


class HoldFamilySemanticsTests(unittest.TestCase):
    """Finding B17: ``Hold``, ``HoldComplete``, ``HoldForm``, ``Unevaluated``
    all evaluate their arguments before wrapping them. Wolfram gives these
    heads the HoldAll attribute, so they keep their arguments unevaluated.

    Finding B18: ``ReleaseHold`` doesn't strip Hold-family heads.

    These together are a single missing-feature: Tungsten has no mechanism
    for hardcoded Hold-attribute heads. The workaround ``Function[body]`` is
    implemented for pure functions but not for the Hold family."""

    def test_hold_plus_current_behavior_evaluates(self) -> None:
        # Tungsten evaluates 1+2 first, then wraps in Hold.
        self.assertEqual(_full("Hold[1 + 2]"), "Hold[3]")

    def test_hold_complete_current_behavior_evaluates(self) -> None:
        self.assertEqual(_full("HoldComplete[1 + 2]"), "HoldComplete[3]")

    def test_hold_form_current_behavior_evaluates(self) -> None:
        self.assertEqual(_full("HoldForm[1 + 2]"), "HoldForm[3]")

    def test_unevaluated_current_behavior_evaluates(self) -> None:
        self.assertEqual(_full("Unevaluated[1 + 2]"), "Unevaluated[3]")

    def test_release_hold_current_behavior_passthrough(self) -> None:
        # Since Hold[1+2] already evaluates to Hold[3] in Tungsten,
        # ReleaseHold sees Hold[3] and leaves it as ReleaseHold[Hold[3]].
        self.assertEqual(
            _full("ReleaseHold[Hold[1 + 2]]"),
            "ReleaseHold[Hold[3]]",
        )

    @unittest.expectedFailure
    def test_hold_plus_wolfram_target(self) -> None:
        # Wolfram: Hold has HoldAll, keeps 1+2 unevaluated. See finding B17.
        self.assertEqual(_full("Hold[1 + 2]"), "Hold[Plus[1, 2]]")

    @unittest.expectedFailure
    def test_hold_form_wolfram_target(self) -> None:
        self.assertEqual(_full("HoldForm[1 + 2]"), "HoldForm[Plus[1, 2]]")

    @unittest.expectedFailure
    def test_release_hold_wolfram_target(self) -> None:
        # Wolfram: ReleaseHold strips Hold and evaluates. See finding B18.
        self.assertEqual(_full("ReleaseHold[Hold[1 + 2]]"), "3")

    def test_replace_through_hold_matches_today(self) -> None:
        # ReplaceAll traverses Hold and replaces symbols -- Tungsten and the
        # kernel agree here today because the starting Plus[1, x] stays inert
        # (x is unknown). Once B17 lands, the starting side changes but the
        # result should still match.
        self.assertEqual(
            _full("Hold[1 + x] /. x -> 2"),
            "Hold[Plus[1, 2]]",
        )


class ListableThreadingTests(unittest.TestCase):
    """Documented behavior: Wolfram gives many heads the ``Listable`` attribute,
    which makes them auto-thread over lists. Tungsten doesn't implement
    attributes, so these stay inert."""

    def test_sign_on_list_stays_inert(self) -> None:
        # Wolfram: Sign[{-3, 0, 5}] = {-1, 0, 1}. Tungsten: inert.
        self.assertEqual(_full("Sign[{-3, 0, 5}]"), "Sign[List[-3, 0, 5]]")

    def test_abs_on_list_stays_inert(self) -> None:
        self.assertEqual(_full("Abs[{-3, 4}]"), "Abs[List[-3, 4]]")

    def test_plus_two_lists_stays_inert(self) -> None:
        # Docs: Plus doesn't flatten/thread. Left as Plus[List, List].
        self.assertEqual(
            _full("Plus[{1, 2}, {3, 4}]"),
            "Plus[List[1, 2], List[3, 4]]",
        )


class TungstenDivergenceSmokeTests(unittest.TestCase):
    """Smoke tests for the broader differential-harness run. These are not
    exhaustive -- they act as a trip-wire that the harness categories still
    reproduce the documented gaps."""

    def test_integer_arithmetic_basic(self) -> None:
        self.assertEqual(_full("1 + 2 + 3"), "6")
        self.assertEqual(_full("2 * 3 * 4"), "24")
        self.assertEqual(_full("Plus[1, 2, 3]"), "6")
        self.assertEqual(_full("Times[2, 3, 4]"), "24")

    def test_integer_division_stays_inert_per_docs(self) -> None:
        # Docs: negative exponents remain inert -> division via Times*Power lowers
        # but does not simplify.
        self.assertEqual(_full("6 / 2"), "Times[6, Power[2, -1]]")

    def test_named_sequence_pattern_rejected_per_docs(self) -> None:
        with self.assertRaises((WolframSyntaxError, WolframEvaluationError)):
            parse_expression("MatchQ[f[a, b, c], f[x__]]", form="input")

    def test_two_unbounded_string_patterns_rejected_per_docs(self) -> None:
        with self.assertRaises((WolframSyntaxError, WolframEvaluationError)):
            evaluate(parse_expression(
                "StringMatchQ[\"abc123\", LetterCharacter.. ~~ DigitCharacter..]",
                form="input",
            ))


if __name__ == "__main__":
    unittest.main()
