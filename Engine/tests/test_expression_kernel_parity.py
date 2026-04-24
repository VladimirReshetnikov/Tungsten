"""Regression tests for Tungsten expression parser/evaluator parity with the
live Wolfram kernel.

These tests were added as part of the 2026-04-24 external consultant review.
They fall into two groups:

1. ``*_current_behavior`` tests lock in what Tungsten does *today*, so that
   any accidental regression of current behavior is caught.
2. ``*_wolfram_target`` tests are decorated with ``@expectedFailure`` and
   express the Wolfram-correct target behavior. They will become
   ``unexpectedSuccess`` once the corresponding bug is fixed, which is the
   signal to remove the decorator and update the related ``*_current_behavior``
   tests accordingly.

Every ``*_wolfram_target`` test has a short comment pointing at the finding ID
in ``src/Tungsten/docs/reports/2026-04-24-parser-evaluator-kernel-parity.md``.
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
