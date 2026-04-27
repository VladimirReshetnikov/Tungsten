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
    """Finding B7: Wolfram performs selected n-ary normalization while parsing,
    including inside held expressions. Tungsten mirrors the arithmetic and
    comparison pieces now, while preserving explicit calls and parentheses as
    barriers."""

    def test_parser_plus_nary(self) -> None:
        expr = parse_expression("a + b + c", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[a, b, c]")

    def test_parser_times_nary(self) -> None:
        expr = parse_expression("a * b * c", form="input")
        self.assertEqual(expr.to_full_form(), "Times[a, b, c]")

    def test_parser_mixed_multiply_divide_factor_grouping(self) -> None:
        self.assertEqual(
            parse_expression("Hold[a*b/c*d/e]", form="input").to_full_form(),
            "Hold[Times[a, Times[b, Power[c, -1]], Times[d, Power[e, -1]]]]",
        )

    def test_parser_mixed_subtraction_nary(self) -> None:
        expr = parse_expression("a + b - c", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[a, b, Times[-1, c]]")

    def test_parser_parentheses_remain_barriers(self) -> None:
        self.assertEqual(
            parse_expression("Hold[a + (b + c)]", form="input").to_full_form(),
            "Hold[Plus[a, Plus[b, c]]]",
        )
        self.assertEqual(
            parse_expression("Hold[(a + b) + c]", form="input").to_full_form(),
            "Hold[Plus[Plus[a, b], c]]",
        )

    def test_parser_mixed_comparison_inequality(self) -> None:
        self.assertEqual(
            parse_expression("Hold[a < b <= c]", form="input").to_full_form(),
            "Hold[Inequality[a, Less, b, LessEqual, c]]",
        )


class ArithmeticPrefixFoldTests(unittest.TestCase):
    """Finding C6 (2026-04-26 deep parity review): mixed numeric/symbolic
    arguments to direct ``Plus[...]`` and ``Times[...]`` calls fold the
    numeric prefix into a single combined number that leads the result. This
    matches Wolfram's canonical ``Plus[3, a]`` shape. Attribute normalization
    now runs before the fold, so ``Orderless`` heads also canonicalize the
    symbolic remainder instead of preserving raw input order.
    """

    def test_plus_direct_call_mixed_folds_prefix(self) -> None:
        self.assertEqual(_full("Plus[1, 2, a]"), "Plus[3, a]")

    def test_plus_direct_call_with_symbolic_first(self) -> None:
        self.assertEqual(_full("Plus[a, 1, 2]"), "Plus[3, a]")

    def test_plus_direct_call_with_multiple_symbolic(self) -> None:
        self.assertEqual(_full("Plus[2, a, 3, b]"), "Plus[5, a, b]")

    def test_plus_direct_call_canonicalizes_symbolic_remainder(self) -> None:
        self.assertEqual(_full("Plus[2, b, 3, a]"), "Plus[5, a, b]")

    def test_plus_infix_mixed_simplifies_inner(self) -> None:
        self.assertEqual(_full("1 + 2 + a"), "Plus[3, a]")

    def test_times_direct_call_mixed_folds_prefix(self) -> None:
        self.assertEqual(_full("Times[2, 3, a, 4]"), "Times[24, a]")

    def test_times_direct_call_canonicalizes_symbolic_remainder(self) -> None:
        self.assertEqual(_full("Times[2, 3, b, a, 4]"), "Times[24, a, b]")

    def test_times_direct_zero_collapses_to_zero(self) -> None:
        # Times[0, a] is 0 because the numeric fold reaches an exact zero.
        self.assertEqual(_full("Times[0, a]"), "0")

    def test_plus_zero_drops(self) -> None:
        self.assertEqual(_full("Plus[0, a]"), "a")

    def test_times_one_drops(self) -> None:
        self.assertEqual(_full("Times[1, a]"), "a")

    def test_length_of_folded_plus(self) -> None:
        # After folding, Plus[1, 2, a] -> Plus[3, a]; length is 2.
        self.assertEqual(_full("Length[Plus[1, 2, a]]"), "2")

    def test_empty_power_returns_one(self) -> None:
        self.assertEqual(_full("Power[]"), "1")

    def test_unary_power_returns_argument(self) -> None:
        self.assertEqual(_full("Power[x]"), "x")


class ArithmeticAutomaticSimplificationTests(unittest.TestCase):
    """Common Wolfram arithmetic canonicalization beyond numeric folding."""

    def test_plus_collects_identical_symbolic_terms(self) -> None:
        self.assertEqual(_full("x + x"), "Times[2, x]")
        self.assertEqual(_full("x + x + x"), "Times[3, x]")
        self.assertEqual(_full("x + 2 x"), "Times[3, x]")
        self.assertEqual(_full("2 x + 3 x"), "Times[5, x]")
        self.assertEqual(_full("a x + a x"), "Times[2, a, x]")
        self.assertEqual(_full("x y + x y"), "Times[2, x, y]")

    def test_plus_cancels_opposite_terms(self) -> None:
        self.assertEqual(_full("x - x"), "0")
        self.assertEqual(_full("-x + x"), "0")
        self.assertEqual(_full("x - y + x"), "Plus[Times[2, x], Times[-1, y]]")
        self.assertEqual(_full("a x + (-a) x"), "0")

    def test_times_collects_identical_bases(self) -> None:
        self.assertEqual(_full("x*x"), "Power[x, 2]")
        self.assertEqual(_full("x*x*x"), "Power[x, 3]")
        self.assertEqual(_full("2*x*x"), "Times[2, Power[x, 2]]")
        self.assertEqual(_full("x^2*x"), "Power[x, 3]")
        self.assertEqual(_full("x^2*x^3"), "Power[x, 5]")
        self.assertEqual(_full("x^a*x^b"), "Power[x, Plus[a, b]]")
        self.assertEqual(_full("x^a*x^a"), "Power[x, Times[2, a]]")

    def test_times_cancels_reciprocal_powers(self) -> None:
        self.assertEqual(_full("1/x*x"), "1")
        self.assertEqual(_full("x/x"), "1")
        self.assertEqual(_full("x^-1*x"), "1")
        self.assertEqual(_full("x^-2*x^3"), "x")

    def test_power_identity_and_integer_exponent_rules(self) -> None:
        self.assertEqual(_full("x^0"), "1")
        self.assertEqual(_full("x^1"), "x")
        self.assertEqual(_full("1^x"), "1")
        self.assertEqual(_full("(x^2)^3"), "Power[x, 6]")
        self.assertEqual(_full("(x^a)^b"), "Power[Power[x, a], b]")
        self.assertEqual(_full("(a*b)^2"), "Times[Power[a, 2], Power[b, 2]]")
        self.assertEqual(_full("(-x)^3"), "Times[-1, Power[x, 3]]")


class AtPrefixPrecedenceTests(unittest.TestCase):
    """Finding B10: the ``@`` prefix operator binds tighter than arithmetic.

    Now also locks in the C6 numeric-prefix folding for the @ + numeric
    interaction; Tungsten matches the kernel's ``Plus[2, f[1]]`` canonical
    order for the supported subset.
    """

    def test_at_plus(self) -> None:
        self.assertEqual(_full("f @ 1 + 2"), "Plus[2, f[1]]")

    def test_at_times(self) -> None:
        self.assertEqual(_full("f @ x * 2"), "Times[2, f[x]]")

    def test_at_right_assoc_still_works(self) -> None:
        # Right-associative chains of @ are unaffected by the precedence bug.
        self.assertEqual(_full("f @ g @ h @ x"), "f[g[h[x]]]")


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

    def test_span_with_unary_minus_in_step(self) -> None:
        # ``1 ;; -1 ;; 2`` must bind unary minus tighter than ``;;`` so the step
        # is the literal ``-1`` rather than ``-Span[1, 2]``.
        expr = parse_expression("1 ;; -1 ;; 2", form="input")
        self.assertEqual(expr.to_full_form(), "Span[1, -1, 2]")

    def test_span_lower_precedence_than_plus(self) -> None:
        # ``;;`` is lower precedence than ``+``, so ``1 + 2 ;; 3`` is
        # ``Span[Plus[1, 2], 3]``, not ``Plus[1, Span[2, 3]]``.
        expr = parse_expression("1 + 2 ;; 3", form="input")
        self.assertEqual(expr.to_full_form(), "Span[Plus[1, 2], 3]")
        expr = parse_expression("1 ;; 2 + 3", form="input")
        self.assertEqual(expr.to_full_form(), "Span[1, Plus[2, 3]]")

    def test_span_all_middle_default(self) -> None:
        # ``a ;; ;; c`` is a single span with the missing middle defaulting to ``All``.
        expr = parse_expression("a ;; ;; c", form="input")
        self.assertEqual(expr.to_full_form(), "Span[a, All, c]")

    def test_span_complete_then_implicit_times(self) -> None:
        # Once a 3-part span is complete, a further ``;;`` starts a fresh span
        # that combines with the previous one via implicit Times.
        expr = parse_expression("a ;; b ;; c ;; d", form="input")
        self.assertEqual(expr.to_full_form(), "Times[Span[a, b, c], Span[1, d]]")


class CharacterEscapeParserTests(unittest.TestCase):
    """Wolfram character escape forms that work outside string literals."""

    def test_unicode_hex_escape(self) -> None:
        # ``\:XXXX`` decodes to a single Unicode character usable as a symbol.
        expr = parse_expression(r"\:ff0d", form="input")
        self.assertEqual(expr.to_full_form(), "－")

    def test_two_hex_escape(self) -> None:
        # ``\.XX`` decodes a 2-hex-digit ISO-Latin-1 character.
        expr = parse_expression(r"\.41", form="input")
        self.assertEqual(expr.to_full_form(), "A")

    def test_octal_escape(self) -> None:
        # ``\OOO`` decodes a 3-octal-digit character.
        expr = parse_expression(r"\041", form="input")
        self.assertEqual(expr.to_full_form(), "!")

    def test_long_hex_escape(self) -> None:
        # ``\|XXXXXX`` decodes a 6-hex-digit character (covers astral plane).
        expr = parse_expression(r"\|01F600", form="input")
        self.assertEqual(expr.to_full_form(), "\U0001f600")

    def test_escape_inside_string_literal(self) -> None:
        # The same escape forms decode inside string literals.
        expr = parse_expression(r'"a\:00b2"', form="input")
        self.assertEqual(expr.to_full_form(), '"a²"')


class InlineBoxParserTests(unittest.TestCase):
    """Wolfram inline-box constructs ``\\!\\(...\\)`` and bare ``\\(...\\)`` outside strings."""

    def test_inline_box_with_arithmetic_inner(self) -> None:
        expr = parse_expression(r"a + \!\(b + c\)", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[a, Plus[b, c]]")

    def test_inline_box_strips_traditional_form_prefix(self) -> None:
        expr = parse_expression(r"\!\(TraditionalForm\`{a, b}\)", form="input")
        self.assertEqual(expr.to_full_form(), "List[a, b]")

    def test_bare_box_escape_surfaces_as_inert_head(self) -> None:
        # Bare ``\(...\)`` is real notebook box syntax. Tungsten consumes it as an
        # opaque head so the surrounding parse can continue.
        expr = parse_expression(r'"intt" -> \(\[Integral] x\)', form="input")
        self.assertEqual(
            expr.to_full_form(),
            'Rule["intt", BareBoxEscape["\\\\[Integral] x"]]',
        )


class AdjacentTypedBlankParserTests(unittest.TestCase):
    """``_Eps _Pair`` (anonymous typed blanks) must parse as implicit Times."""

    def test_anonymous_typed_blanks_with_space(self) -> None:
        expr = parse_expression("_Eps _Pair", form="input")
        self.assertEqual(expr.to_full_form(), "Times[Blank[Eps], Blank[Pair]]")

    def test_named_blank_requires_adjacency(self) -> None:
        # ``x _Integer`` (with space) is implicit Times, not ``Pattern[x, Blank[Integer]]``.
        expr = parse_expression("x _Integer", form="input")
        self.assertEqual(expr.to_full_form(), "Times[x, Blank[Integer]]")
        expr = parse_expression("x_Integer", form="input")
        self.assertEqual(expr.to_full_form(), "Pattern[x, Blank[Integer]]")

    def test_implicit_times_optional_dot_is_absorbed(self) -> None:
        # ``_?Negative _.`` parses as Times of PatternTest and Optional, not as
        # a stray Dot operator after the second Blank.
        expr = parse_expression("_?Negative _.", form="input")
        self.assertEqual(
            expr.to_full_form(),
            "Times[PatternTest[Blank[], Negative], Optional[Blank[]]]",
        )


class TrailingFunctionAfterSemicolonTests(unittest.TestCase):
    """``a; &`` parses as ``Function[CompoundExpression[a, Null]]``."""

    def test_trailing_function_after_compound_expression(self) -> None:
        expr = parse_expression("a; &", form="input")
        self.assertEqual(expr.to_full_form(), "Function[CompoundExpression[a, Null]]")

    def test_grouping_preserves_compound_expression_nesting(self) -> None:
        expr = parse_expression("a; (b;)", form="input")
        self.assertEqual(
            expr.to_full_form(),
            "CompoundExpression[a, CompoundExpression[b, Null]]",
        )


class NamedSlotParserTests(unittest.TestCase):
    """``#name`` and ``#"name"`` parse as ``Slot["name"]``."""

    def test_named_slot_shorthand(self) -> None:
        expr = parse_expression("#name", form="input")
        self.assertEqual(expr.to_full_form(), 'Slot["name"]')

    def test_named_slot_string(self) -> None:
        expr = parse_expression('#"name"', form="input")
        self.assertEqual(expr.to_full_form(), 'Slot["name"]')

    def test_named_slot_with_space_is_implicit_times(self) -> None:
        expr = parse_expression("# name", form="input")
        self.assertEqual(expr.to_full_form(), "Times[Slot[1], name]")


class ColonChainParserTests(unittest.TestCase):
    """``:``-chains fold into ``Optional[Pattern[a, b], ...]`` like the kernel does."""

    def test_three_element_colon_chain(self) -> None:
        expr = parse_expression("a:b:c", form="input")
        self.assertEqual(expr.to_full_form(), "Optional[Pattern[a, b], c]")

    def test_four_element_colon_chain(self) -> None:
        expr = parse_expression("a:b:c:d", form="input")
        self.assertEqual(
            expr.to_full_form(),
            "Optional[Pattern[a, b], Pattern[c, d]]",
        )

    def test_six_element_colon_chain(self) -> None:
        expr = parse_expression("a:b:c:d:e:f", form="input")
        self.assertEqual(
            expr.to_full_form(),
            "Optional[Pattern[a, b], Optional[Pattern[c, d], Pattern[e, f]]]",
        )


class EofKindCollisionParserTests(unittest.TestCase):
    """A symbol literally named ``eof`` must not collide with the EOF kind sentinel."""

    def test_eof_symbol_in_compound_expression(self) -> None:
        expr = parse_expression(
            "Module[{eof}, eof = init; If[eof, x]]", form="input"
        )
        self.assertIn("Module", expr.to_full_form())
        self.assertIn("Set[eof, init]", expr.to_full_form())
        self.assertIn("If[eof, x]", expr.to_full_form())


class TrailingCommaSequenceParserTests(unittest.TestCase):
    """Wolfram emits a Syntax::com warning and treats absent comma operands as ``Null``."""

    def test_trailing_comma_in_call(self) -> None:
        expr = parse_expression("f[a, b,]", form="input")
        self.assertEqual(expr.to_full_form(), "f[a, b, Null]")

    def test_internal_empty_comma_in_list(self) -> None:
        expr = parse_expression("{a,,b}", form="input")
        self.assertEqual(expr.to_full_form(), "List[a, Null, b]")


class UnaryPlusParserTests(unittest.TestCase):
    """Unary ``+`` produces ``Plus[x]`` and folds into surrounding ``Plus`` chains."""

    def test_unary_plus_on_atom(self) -> None:
        expr = parse_expression("+x", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[x]")

    def test_unary_plus_inside_plus_chain_folds(self) -> None:
        expr = parse_expression("1 + +2", form="input")
        self.assertEqual(expr.to_full_form(), "Plus[1, 2]")


class ApplyToParserTests(unittest.TestCase):
    """``//=`` parses as ``ApplyTo[lhs, rhs]``."""

    def test_apply_to_basic(self) -> None:
        expr = parse_expression("a //= f", form="input")
        self.assertEqual(expr.to_full_form(), "ApplyTo[a, f]")

    def test_apply_to_right_associative(self) -> None:
        expr = parse_expression("a //= b //= c", form="input")
        self.assertEqual(expr.to_full_form(), "ApplyTo[a, ApplyTo[b, c]]")


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
    which makes them auto-thread over lists. Tungsten now applies the registry
    snapshot attributes before direct built-in evaluation."""

    def test_sign_on_list_threads(self) -> None:
        self.assertEqual(_full("Sign[{-3, 0, 5}]"), "List[-1, 0, 1]")

    def test_abs_on_list_threads(self) -> None:
        self.assertEqual(_full("Abs[{-3, 4}]"), "List[3, 4]")

    def test_plus_two_lists_threads(self) -> None:
        self.assertEqual(
            _full("Plus[{1, 2}, {3, 4}]"),
            "List[4, 6]",
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
