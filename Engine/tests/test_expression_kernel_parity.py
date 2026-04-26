"""Regression tests for Tungsten expression parser/evaluator parity with the
live Wolfram kernel.

These tests were added as part of the 2026-04-24 external consultant review.
Two groups:

1. Ordinary tests lock in the Wolfram-compatible behavior Tungsten supports
   today, especially where a review finding was fixed.
2. Remaining ``*_wolfram_target`` tests decorated with ``@expectedFailure``
   document known, intentional deferrals or compatibility gaps.

Findings B1-B9 come from the original parity report
(``2026-04-24-parser-evaluator-kernel-parity.md``); findings B10-B18 come from
the evil-QA addendum (``2026-04-24-parser-evaluator-kernel-parity-evil-qa.md``).
Remaining ``*_wolfram_target`` tests have short comments explaining the deferred gap.
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
    """Finding B1: same-head chained comparison operators parse as n-ary calls."""

    def test_chained_less(self) -> None:
        self.assertEqual(_full("1 < 2 < 3"), "True")
        self.assertEqual(_full("1 < 3 < 2"), "False")

    def test_chained_less_equal(self) -> None:
        self.assertEqual(_full("1 <= 1 <= 2"), "True")

    def test_chained_greater(self) -> None:
        self.assertEqual(_full("5 > 3 > 1"), "True")

    def test_chained_equal(self) -> None:
        self.assertEqual(_full("1 == 1 == 1"), "True")

    def test_chained_unequal(self) -> None:
        self.assertEqual(_full("1 != 2 != 3"), "True")


class PositionDefaultLevelSpecTests(unittest.TestCase):
    """Finding B2: Position's default levelspec is ``{0, Infinity}``."""

    def test_explicit_full_level_works(self) -> None:
        # With explicit ``{0, Infinity}`` Tungsten agrees with the kernel.
        self.assertEqual(
            _full("Position[f[a, g[b, a]], a, {0, Infinity}]"),
            "List[List[1], List[2, 2]]",
        )

    def test_position_default(self) -> None:
        self.assertEqual(
            _full("Position[f[a, g[b, a]], a]"),
            "List[List[1], List[2, 2]]",
        )


class LevelSemanticsTests(unittest.TestCase):
    """Finding B3 (Level negative-int spec) and B4 (Level traversal order)."""

    def test_level_minus_one(self) -> None:
        self.assertEqual(_full("Level[f[a, g[b]], -1]"), "List[a, b, g[b]]")

    def test_level_positive_two_order(self) -> None:
        self.assertEqual(_full("Level[f[a, g[b]], 2]"), "List[a, b, g[b]]")

    def test_level_infinity_order(self) -> None:
        self.assertEqual(
            _full("Level[f[a, g[b, c]], Infinity]"),
            "List[a, b, c, g[b, c]]",
        )

    def test_level_explicit_single_atoms_works(self) -> None:
        # ``Level[expr, {-1}]`` (single negative) currently returns atoms only.
        # This matches Wolfram's semantics for the single-level form and is not
        # affected by the B3 bug.
        self.assertEqual(_full("Level[f[a, g[b]], {-1}]"), "List[a, b]")

class DotEvaluationTests(unittest.TestCase):
    """Finding B5: Dot constructs ``Plus[Times[...], ...]`` but does not
    re-evaluate."""

    def test_dot_vector(self) -> None:
        self.assertEqual(_full("{1, 2, 3} . {4, 5, 6}"), "32")

    def test_dot_matrix_vector(self) -> None:
        self.assertEqual(
            _full("{{1, 2}, {3, 4}} . {5, 6}"),
            "List[17, 39]",
        )

    def test_explicit_plus_of_times_does_simplify(self) -> None:
        # Confirms that the simplification pipeline *does* exist and fires when
        # the same Plus/Times call is evaluated directly -- the Dot bug is the
        # missing re-evaluation pass, not a missing arithmetic feature.
        self.assertEqual(
            _full("Plus[Times[1, 4], Times[2, 5], Times[3, 6]]"),
            "32",
        )

class AssociationDuplicateKeyTests(unittest.TestCase):
    """Finding B6: on duplicate keys, Tungsten moves the winning entry to the
    later position instead of preserving the first-occurrence position."""

    def test_duplicate_key_first_position_is_preserved(self) -> None:
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

    Tungsten now special-cases same-head comparison chains because that affects
    evaluation. Arithmetic n-ary flattening remains intentionally deferred to
    preserve the documented no-Flat/no-Orderless arithmetic boundary.
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
    """Finding B10: the ``@`` prefix operator binds tighter than arithmetic."""

    def test_at_plus(self) -> None:
        self.assertEqual(_full("f @ 1 + 2"), "Plus[f[1], 2]")

    def test_at_times(self) -> None:
        self.assertEqual(_full("f @ x * 2"), "Times[f[x], 2]")

    def test_at_right_assoc_still_works(self) -> None:
        # Right-associative chains of @ are unaffected by the precedence bug.
        self.assertEqual(_full("f @ g @ h @ x"), "f[g[h[x]]]")

    @unittest.expectedFailure
    def test_at_times_wolfram_target(self) -> None:
        # Wolfram additionally canonicalizes Times arguments via Orderless;
        # Tungsten intentionally does not implement Orderless attributes.
        self.assertEqual(_full("f @ x * 2"), "Times[2, f[x]]")


class SpanParserTests(unittest.TestCase):
    """Finding B11: ``;;`` parses to the Wolfram ternary Span shape."""

    def test_span_ternary(self) -> None:
        expr = parse_expression("1 ;; 5 ;; 2", form="input")
        self.assertEqual(expr.to_full_form(), "Span[1, 5, 2]")

    def test_span_reverse_ternary(self) -> None:
        expr = parse_expression("5 ;; 1 ;; -1", form="input")
        self.assertEqual(expr.to_full_form(), "Span[5, 1, -1]")

    def test_part_with_literal_reverse_span(self) -> None:
        self.assertEqual(
            _full("{a, b, c, d, e}[[5 ;; 1 ;; -1]]"),
            "List[e, d, c, b, a]",
        )

    def test_part_with_literal_step_span(self) -> None:
        self.assertEqual(
            _full("{a, b, c, d, e}[[1 ;; 5 ;; 2]]"),
            "List[a, c, e]",
        )

    def test_part_with_explicit_span_head_works(self) -> None:
        # Using Span[...] directly bypasses the parser bug.
        self.assertEqual(
            _full("Part[{a, b, c, d, e}, Span[1, 5, 2]]"),
            "List[a, c, e]",
        )

class KeyMapEvaluationTests(unittest.TestCase):
    """Finding B12: ``KeyMap[f, assoc]`` evaluates the mapped key expression."""

    def test_key_map_pure_fn(self) -> None:
        self.assertEqual(
            _full("KeyMap[# &, <|a -> 1, b -> 2|>]"),
            "Association[Rule[a, 1], Rule[b, 2]]",
        )

    def test_key_map_identity(self) -> None:
        self.assertEqual(
            _full("KeyMap[Identity, <|a -> 1|>]"),
            "Association[Rule[a, 1]]",
        )

    def test_key_map_symbol_head_passes_through(self) -> None:
        # For a plain symbol head, no further evaluation is needed, so the
        # bug is invisible here -- kernel also returns <|f[a] -> 1|>.
        self.assertEqual(
            _full("KeyMap[f, <|a -> 1|>]"),
            "Association[Rule[f[a], 1]]",
        )

class AssociationAsFunctionTests(unittest.TestCase):
    """Finding B13: Wolfram associations act as functions -- ``assoc[key]``
    returns the value for that key, including through the ``#name`` shorthand."""

    def test_assoc_call(self) -> None:
        self.assertEqual(
            _full("<|\"name\" -> x|>[\"name\"]"),
            "x",
        )

    def test_name_shorthand(self) -> None:
        self.assertEqual(
            _full("#name & [<|\"name\" -> x|>]"),
            "x",
        )

    def test_part_with_key_works(self) -> None:
        # Using Part[assoc, Key[k]] or the "k" shorthand *does* work today.
        self.assertEqual(
            _full("<|\"name\" -> x|>[[Key[\"name\"]]]"),
            "x",
        )

class FixedPointMaxIterationsTests(unittest.TestCase):
    """Finding B14: ``FixedPoint[f, x, n]`` treats ``n`` as a hard error cap.
    Wolfram treats ``n`` as a soft limit -- after n iterations, return the
    current value without error."""

    def test_fixed_point_soft_limit(self) -> None:
        self.assertEqual(_full("FixedPoint[# - 1 &, 5, 2]"), "3")

    def test_fixed_point_n_zero(self) -> None:
        self.assertEqual(_full("FixedPoint[# - 1 &, 5, 0]"), "5")

    def test_fixed_point_convergent_case_works(self) -> None:
        # When convergence happens before the cap, Tungsten returns correctly.
        self.assertEqual(_full("FixedPoint[Identity, 5, 10]"), "5")

class SequenceSplicingTests(unittest.TestCase):
    """Finding B15: ``Sequence[...]`` auto-splices as an argument."""

    def test_sequence_in_list(self) -> None:
        self.assertEqual(
            _full("{Sequence[1, 2], 3}"),
            "List[1, 2, 3]",
        )

    def test_sequence_in_call(self) -> None:
        self.assertEqual(
            _full("f[Sequence[1, 2], 3]"),
            "f[1, 2, 3]",
        )

    def test_sequence_in_pure_function_application(self) -> None:
        self.assertEqual(
            _full("(#2 &)[Sequence[1, 2]]"),
            "2",
        )

    def test_sequence_splices_inside_hold_but_not_holdcomplete(self) -> None:
        self.assertEqual(
            _full("Hold[Sequence[1 + 1, 2 + 2]]"),
            "Hold[Plus[1, 1], Plus[2, 2]]",
        )
        self.assertEqual(
            _full("HoldComplete[Sequence[1 + 1, 2 + 2]]"),
            "HoldComplete[Sequence[Plus[1, 1], Plus[2, 2]]]",
        )

    def test_nothing_drops_from_lists_but_not_ordinary_calls(self) -> None:
        self.assertEqual(_full("{Nothing, 1}"), "List[1]")
        self.assertEqual(_full("f[Nothing, 1]"), "f[Nothing, 1]")
        self.assertEqual(_full("{a, b} /. a -> Nothing"), "List[b]")
        self.assertEqual(_full("Hold[{a, b}] /. a -> Nothing"), "Hold[List[Nothing, b]]")


class DoubleUnaryMinusTests(unittest.TestCase):
    """Prefix decrement syntax is now parsed as its Wolfram operator head."""

    def test_prefix_decrement_is_not_double_unary_minus(self) -> None:
        self.assertEqual(_full("--5"), "PreDecrement[5]")


class HoldFamilySemanticsTests(unittest.TestCase):
    """Findings B17/B18: Hold-family heads hold arguments; ReleaseHold strips."""

    def test_hold_plus(self) -> None:
        self.assertEqual(_full("Hold[1 + 2]"), "Hold[Plus[1, 2]]")

    def test_hold_complete(self) -> None:
        self.assertEqual(_full("HoldComplete[1 + 2]"), "HoldComplete[Plus[1, 2]]")

    def test_hold_form(self) -> None:
        self.assertEqual(_full("HoldForm[1 + 2]"), "HoldForm[Plus[1, 2]]")

    def test_unevaluated(self) -> None:
        self.assertEqual(_full("Unevaluated[1 + 2]"), "Unevaluated[Plus[1, 2]]")

    def test_release_hold(self) -> None:
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

    def test_exact_division_normalizes_to_rational_or_integer(self) -> None:
        self.assertEqual(_full("6 / 2"), "3")
        self.assertEqual(_full("1 / 2"), "Rational[1, 2]")

    def test_named_sequence_patterns_match_and_substitute(self) -> None:
        self.assertEqual(_full("MatchQ[f[a, b, c], f[x__]]"), "True")
        self.assertEqual(
            _full("Cases[{f[a, b, c]}, f[x__, y__] :> HoldComplete[{x}, {y}]]"),
            "List[HoldComplete[List[a], List[b, c]]]",
        )
        self.assertEqual(
            _full("Cases[{f[a, b, a, b]}, f[x__, x__] :> HoldComplete[{x}]]"),
            "List[HoldComplete[List[a, b]]]",
        )

    def test_multiple_unbounded_string_patterns_match(self) -> None:
        self.assertEqual(
            _full("StringMatchQ[\"abc123\", LetterCharacter.. ~~ DigitCharacter..]"),
            "True",
        )
        self.assertEqual(
            _full("StringCases[\"abc123def45\", LetterCharacter.. ~~ DigitCharacter..]"),
            'List["abc123", "def45"]',
        )


if __name__ == "__main__":
    unittest.main()
