"""Tests for the predicate-driven looping constructs and the
non-local control-flow primitives.

Covered constructs:

- ``While[test, body]`` / ``While[test]``
- ``For[init, test, incr, body]``
- ``Break[]``, ``Continue[]`` — caught by ``Do`` / ``While`` / ``For``;
  *not* caught by ``Table`` / ``Sum`` / ``Product``.
- ``Return[expr]`` — caught at the function-definition rule boundary.
- ``Return[expr, head]`` — caught by the named enclosing head
  (``Module``, ``Block``, ``For``, ``While``, ``Do``).
- ``Label[name]`` / ``Goto[name]`` — caught by ``CompoundExpression``.
- ``Increment[x]`` / ``Decrement[x]`` / ``PreIncrement[x]`` /
  ``PreDecrement[x]`` — needed for the canonical ``For`` idiom.

The tests rely on the same ``_full(text)`` evaluation harness as
``test_expression_iteration.py``: parse from input form, evaluate,
serialize as full form. Persistent global names use a process-unique
prefix so the registry does not leak across tests.
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


class WhileEvaluationTests(unittest.TestCase):
    """``While[test, body]`` runs body for side effects until ``test``
    no longer evaluates to literal ``True``; the result is always
    ``Null``."""

    def test_false_test_skips_body(self) -> None:
        self.assertEqual(_full("While[False, x = 1]"), "Null")

    def test_one_argument_form_runs_test_until_false(self) -> None:
        # While[test] with no body just iterates the test; useful when
        # ``test`` itself has side effects (e.g. PreIncrement).
        self.assertEqual(
            _full("Module[{i = 0}, While[++i < 5]; i]"),
            "5",
        )

    def test_loop_advances_outer_counter(self) -> None:
        self.assertEqual(
            _full("Module[{i = 0}, While[i < 5, i = i + 1]; i]"),
            "5",
        )

    def test_loop_accumulates_via_outer_variable(self) -> None:
        # 1 + 2 + 3 + 4 + 5 = 15.
        self.assertEqual(
            _full(
                "Module[{i = 0, s = 0}, While[i < 5, i = i + 1; s = s + i]; s]"
            ),
            "15",
        )

    def test_break_inside_while_exits_with_null(self) -> None:
        self.assertEqual(
            _full(
                "Module[{i = 0}, "
                "While[i < 10, i = i + 1; If[i == 5, Break[]]]; i]"
            ),
            "5",
        )

    def test_continue_inside_while_skips_rest_of_body(self) -> None:
        # Skip even i's; sum the odd ones from 1..5 = 1 + 3 + 5 = 9.
        self.assertEqual(
            _full(
                "Module[{i = 0, s = 0}, "
                "While[i < 5, i = i + 1; If[Mod[i, 2] == 0, Continue[]]; "
                "s = s + i]; s]"
            ),
            "9",
        )


class ForEvaluationTests(unittest.TestCase):
    """``For[init, test, incr, body]`` evaluates ``init`` once, then
    while ``test`` is ``True`` it runs ``body`` followed by ``incr``.
    Returns ``Null``."""

    def test_basic_summation(self) -> None:
        self.assertEqual(
            _full("Module[{s = 0}, For[i = 1, i <= 5, i++, s = s + i]; s]"),
            "15",
        )

    def test_for_with_explicit_increment_assignment(self) -> None:
        # Same loop using ``i = i + 1`` instead of ``i++``.
        self.assertEqual(
            _full(
                "Module[{s = 0}, For[i = 1, i <= 5, i = i + 1, s = s + i]; s]"
            ),
            "15",
        )

    def test_break_inside_for_exits_with_null(self) -> None:
        self.assertEqual(
            _full(
                "Module[{s = 0}, "
                "For[i = 1, i <= 10, i++, If[i > 5, Break[]]; s = s + i]; s]"
            ),
            "15",
        )

    def test_continue_inside_for_advances_increment(self) -> None:
        # Continue must allow the increment to run, otherwise the
        # loop never advances. Sum odd i in 1..10 = 1+3+5+7+9 = 25.
        self.assertEqual(
            _full(
                "Module[{s = 0}, "
                "For[i = 1, i <= 10, i++, "
                "If[Mod[i, 2] == 0, Continue[]]; s = s + i]; s]"
            ),
            "25",
        )

    def test_for_returns_null(self) -> None:
        # For always returns Null; the value of body / incr / test is
        # discarded.
        self.assertEqual(
            _full("Module[{s = 0}, For[i = 1, i <= 3, i++, s = s + 1]]"),
            "Null",
        )

    def test_for_with_break_in_first_iteration(self) -> None:
        # init is also inside the For's Break-catch boundary, so a
        # Break that fires before any iteration completes still
        # produces a clean Null exit and leaves outer state untouched.
        self.assertEqual(
            _full(
                "Module[{x = 0}, "
                "For[1, True, Null, Break[]; x = 1]; x]"
            ),
            "0",
        )


class ReturnInFunctionDefinitionTests(unittest.TestCase):
    """``Return[expr]`` (no head) is caught at the rule application
    boundary of the matched ``DownValues`` / ``SubValues`` / ``UpValues``
    definition, so an ordinary ``f[x_] := ...; Return[v]; ...`` returns
    ``v`` from ``f[...]``."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_return_inside_module_body_of_function(self) -> None:
        self._track("tungstenRetF1")
        evaluate(
            parse_input_form(
                "tungstenRetF1[x_] := Module[{r}, r = x; "
                "If[r > 10, Return[big]]; r]"
            )
        )
        self.assertEqual(_full("tungstenRetF1[5]"), "5")
        self.assertEqual(_full("tungstenRetF1[20]"), "big")

    def test_return_in_compound_expression_body(self) -> None:
        self._track("tungstenRetG1")
        evaluate(
            parse_input_form(
                "tungstenRetG1[x_] := (If[x > 0, Return[positive]]; "
                "If[x < 0, Return[negative]]; zero)"
            )
        )
        self.assertEqual(_full("tungstenRetG1[5]"), "positive")
        self.assertEqual(_full("tungstenRetG1[-3]"), "negative")
        self.assertEqual(_full("tungstenRetG1[0]"), "zero")

    def test_return_propagates_through_do_to_function_boundary(self) -> None:
        self._track("tungstenRetH1")
        evaluate(
            parse_input_form(
                "tungstenRetH1[x_] := Do[If[i == 3, Return[done]], {i, 1, 5}]"
            )
        )
        self.assertEqual(_full("tungstenRetH1[0]"), "done")

    def test_uncaught_return_at_top_level_is_inert(self) -> None:
        # Without an enclosing function-definition rule, Return is
        # not caught and falls through to its inert form.
        self.assertEqual(_full("Return[5]"), "Return[5]")
        self.assertEqual(_full("Return[]"), "Return[Null]")
        # Catch[] does not catch Return (only Throw), so this also
        # falls through.
        self.assertEqual(_full("Catch[Return[5]]"), "Return[5]")


class ReturnWithHeadTests(unittest.TestCase):
    """The two-argument ``Return[expr, head]`` is caught by the
    nearest enclosing call whose head is ``head`` (``Module``,
    ``Block``, ``For``, ``While``, ``Do``)."""

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_return_module_exits_module(self) -> None:
        self._track("tungstenRetMod1")
        evaluate(
            parse_input_form(
                "tungstenRetMod1[x_] := Module[{}, Return[x, Module]; never]"
            )
        )
        self.assertEqual(_full("tungstenRetMod1[42]"), "42")

    def test_return_module_propagates_through_for(self) -> None:
        self._track("tungstenRetMod2")
        evaluate(
            parse_input_form(
                "tungstenRetMod2[x_] := Module[{}, "
                "For[i = 1, i <= 5, i++, "
                "If[i == 3, Return[i, Module]]]; nothere]"
            )
        )
        self.assertEqual(_full("tungstenRetMod2[0]"), "3")

    def test_return_for_exits_loop(self) -> None:
        # Return[expr, For] inside a For body exits the loop and the
        # entire For call evaluates to expr. Wrapped in a Module
        # because the For's own Return-target catch only fires for
        # Return[expr, For], not bare Return[expr].
        self.assertEqual(
            _full(
                "Module[{}, "
                "For[i = 1, i <= 10, i++, "
                "If[i == 4, Return[fourth, For]]]]"
            ),
            "fourth",
        )

    def test_return_while_exits_loop(self) -> None:
        self.assertEqual(
            _full(
                "Module[{i = 0}, "
                "While[True, i = i + 1; If[i == 7, Return[i, While]]]]"
            ),
            "7",
        )

    def test_return_do_exits_loop(self) -> None:
        self.assertEqual(
            _full(
                "Module[{}, "
                "Do[If[i == 4, Return[i, Do]], {i, 1, 10}]]"
            ),
            "4",
        )

    def test_return_block_exits_block(self) -> None:
        # Avoid ``_`` in the result symbol name to keep the parser
        # from reading it as a pattern blank.
        self.assertEqual(
            _full(
                "Block[{x = 0}, x = 1; Return[blockResult, Block]; x = 2]"
            ),
            "blockResult",
        )


class LabelGotoTests(unittest.TestCase):
    """``Goto[label]`` raises a control signal caught by the nearest
    enclosing ``CompoundExpression`` whose argument list contains
    ``Label[label]``. Evaluation resumes from the position after the
    matched ``Label``."""

    def test_forward_goto_skips_intermediate_arguments(self) -> None:
        # Goto[end] skips ``never`` and ``Label[end]``, resuming at
        # the next argument ``reached``.
        self.assertEqual(
            _full("(Goto[end]; never; Label[end]; reached)"),
            "reached",
        )

    def test_backward_goto_creates_loop(self) -> None:
        # Module[{x = 0}, Label[start]; x = x + 1; If[x < 3, Goto[start]]; x]
        # iterates the body until x reaches 3.
        self.assertEqual(
            _full(
                "Module[{x = 0}, Label[start]; x = x + 1; "
                "If[x < 3, Goto[start]]; x]"
            ),
            "3",
        )

    def test_label_alone_stays_inert(self) -> None:
        # Label outside any goto context is a no-op marker; matching
        # the kernel, it stays inert as ``Label[done]`` rather than
        # evaluating to ``Null``.
        self.assertEqual(_full("Label[done]"), "Label[done]")

    def test_goto_to_unknown_label_falls_through_to_inert(self) -> None:
        # Without an enclosing CompoundExpression that has a matching
        # Label, the goto signal propagates to the top-level evaluator
        # which converts it back to the inert ``Goto[label]`` form.
        self.assertEqual(_full("Goto[unreachable]"), "Goto[unreachable]")

    def test_goto_inside_nested_compound_expression(self) -> None:
        # The innermost CompoundExpression with a matching Label wins.
        # Avoid ``_`` in symbols so the parser doesn't treat them as
        # pattern blanks.
        self.assertEqual(
            _full(
                "((Goto[inner]; outerNever; Label[inner]; innerReached))"
            ),
            "innerReached",
        )


class BreakContinueOutsideLoopTests(unittest.TestCase):
    """``Break[]`` and ``Continue[]`` outside any loop fall through
    to their inert forms (matching the kernel's
    ``Break::nofwd`` / ``Continue::nofwd`` behavior)."""

    def test_bare_break_is_inert(self) -> None:
        self.assertEqual(_full("Break[]"), "Break[]")

    def test_bare_continue_is_inert(self) -> None:
        self.assertEqual(_full("Continue[]"), "Continue[]")

    def test_break_does_not_propagate_through_table(self) -> None:
        # Per the kernel docs, Break / Continue affect only
        # Do / For / While. Table does not catch Break, so the
        # signal propagates outward; the top-level evaluator's
        # fallback turns it back into the inert ``Break[]`` form.
        # The whole ``Table[Break[], ...]`` collapses to that
        # inert ``Break[]`` rather than producing partial results.
        self.assertEqual(_full("Table[Break[], {i, 1, 3}]"), "Break[]")


class IncrementDecrementTests(unittest.TestCase):
    """``Increment``, ``Decrement``, ``PreIncrement``, ``PreDecrement``
    mutate the target symbol's own value and return the old or new
    value depending on whether they're post- or pre- variants."""

    def test_post_increment_returns_old_value(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; x++]"), "5")

    def test_post_increment_advances_symbol(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; x++; x]"), "6")

    def test_pre_increment_returns_new_value(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; ++x]"), "6")

    def test_post_decrement_returns_old_value(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; x--]"), "5")

    def test_post_decrement_advances_symbol(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; x--; x]"), "4")

    def test_pre_decrement_returns_new_value(self) -> None:
        self.assertEqual(_full("Module[{x}, x = 5; --x]"), "4")

    def test_increment_on_unbound_symbol_proceeds_symbolically(self) -> None:
        # Unlike a hard error, Tungsten's Increment on a symbol with
        # no own value still records ``Plus[1, x]`` as the new own
        # value and returns the old (symbolic) value — i.e., the
        # rename target itself. This matches the kernel's "set the
        # symbol to ``1 + x``" behavior on initially-unbound targets.
        # We only assert that the result is a Module-renamed local
        # symbol (``x$N`` for some integer N) rather than pinning the
        # exact suffix.
        result = _full("Module[{x}, x++]")
        self.assertTrue(
            result.startswith("x$"),
            f"expected a Module-renamed x$N symbol, got {result!r}",
        )


if __name__ == "__main__":
    unittest.main()
