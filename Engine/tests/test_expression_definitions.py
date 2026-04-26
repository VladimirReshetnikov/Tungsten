"""Tests for the symbol-definition scaffolding and the SetDelayed / value
getter additions that prepare the field for the upcoming compound-LHS Set,
SetDelayed, UpSet, TagSet, and With / Module / Block work.

These tests exercise:

- The ``Definition`` dataclass and ``SymbolRecord.definitions_for_kind``
  storage shape.
- The Set / SetDelayed / Unset / Clear interaction with the canonical
  ``own_values_definitions`` list in addition to the legacy single-slot
  ``own_value`` field.
- The ``OwnValues`` / ``DownValues`` / ``UpValues`` / ``SubValues`` /
  ``NValues`` getters reading from the canonical storage.
- The ``With`` / ``Module`` / ``Block`` stubs that emit a clear
  not-yet-supported message instead of leaving calls silently inert.
- The compound-LHS classifier that surfaces ``f[x_] := ...`` as a
  recognized but unimplemented case rather than as an opaque error.

Behavioral changes that the actual compound-LHS rewriter will introduce
(pattern-matched DownValues, fresh Module symbols, dynamic Block scope)
are out of scope here; this file's job is to lock down the *infrastructure
surface* the upcoming pass will build on.
"""
from __future__ import annotations

import unittest

from tungsten.expression import (
    WolframEvaluationError,
    _SYMBOL_REGISTRY,
    evaluate,
    parse_expression,
    parse_input_form,
)
from tungsten.expression_definitions import (
    ALL_VALUE_KINDS,
    Definition,
    VALUE_KIND_DOWN,
    VALUE_KIND_OWN,
    VALUE_KIND_SUB,
    VALUE_KIND_UP,
    assign_definition,
    classify_assignment_lhs,
    clear_definitions,
    definitions_for_kind,
    remove_definition,
    rules_for_kind,
)


def _full(text: str) -> str:
    return evaluate(parse_expression(text, form="input")).to_full_form()


class DefinitionDataclassTests(unittest.TestCase):
    """The ``Definition`` record renders to a Wolfram-style RuleDelayed
    rule regardless of ``delayed`` flag, matching the kernel's stored
    format."""

    def test_definition_renders_as_rule_delayed_for_immediate_assignment(self) -> None:
        lhs = parse_input_form("HoldPattern[x]")
        rhs = parse_input_form("5")
        definition = Definition(hold_pattern=lhs, rhs=rhs, delayed=False)
        self.assertEqual(definition.to_rule_expr().to_full_form(), "RuleDelayed[HoldPattern[x], 5]")

    def test_definition_renders_with_condition_when_present(self) -> None:
        lhs = parse_input_form("HoldPattern[x]")
        rhs = parse_input_form("a")
        condition = parse_input_form("a > 0")
        definition = Definition(hold_pattern=lhs, rhs=rhs, delayed=True, condition=condition)
        self.assertEqual(
            definition.to_rule_expr().to_full_form(),
            "RuleDelayed[HoldPattern[x], Condition[a, Greater[a, 0]]]",
        )


class CanonicalDefinitionsListTests(unittest.TestCase):
    """The canonical ``definitions_for_kind`` list backs OwnValues /
    DownValues / UpValues / SubValues / NValues storage. Set and Unset
    update this list in lockstep with the legacy ``own_value`` slot."""

    def setUp(self) -> None:
        # Use a fresh symbol per test so the global registry doesn't leak
        # state between tests.
        self.symbol_name = f"tungstenDefnTest{abs(hash((id(self), self._testMethodName))) % 1000000}"
        evaluate(parse_input_form(f"Clear[{self.symbol_name}]"))
        evaluate(parse_input_form(f"{self.symbol_name} =."))

    def tearDown(self) -> None:
        evaluate(parse_input_form(f"Clear[{self.symbol_name}]"))

    def test_set_writes_one_entry_into_canonical_own_values(self) -> None:
        evaluate(parse_input_form(f"{self.symbol_name} = 7"))
        record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        self.assertIsNotNone(record)
        self.assertEqual(len(record.own_values_definitions), 1)
        definition = record.own_values_definitions[0]
        self.assertEqual(definition.rhs.to_full_form(), "7")
        self.assertFalse(definition.delayed)

    def test_set_delayed_writes_definition_with_delayed_flag(self) -> None:
        evaluate(parse_input_form(f"{self.symbol_name} := 1 + 2"))
        record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        self.assertIsNotNone(record)
        self.assertEqual(len(record.own_values_definitions), 1)
        definition = record.own_values_definitions[0]
        # SetDelayed stores the RHS un-evaluated.
        self.assertEqual(definition.rhs.to_full_form(), "Plus[1, 2]")
        self.assertTrue(definition.delayed)

    def test_set_delayed_evaluates_rhs_each_time(self) -> None:
        seed = self.symbol_name + "Seed"
        evaluate(parse_input_form(f"{seed} = 5"))
        try:
            evaluate(parse_input_form(f"{self.symbol_name} := {seed} + 1"))
            self.assertEqual(_full(self.symbol_name), "6")
            evaluate(parse_input_form(f"{seed} = 10"))
            self.assertEqual(_full(self.symbol_name), "11")
        finally:
            evaluate(parse_input_form(f"Clear[{seed}]"))

    def test_unset_clears_canonical_storage(self) -> None:
        evaluate(parse_input_form(f"{self.symbol_name} = 1"))
        evaluate(parse_input_form(f"{self.symbol_name} =."))
        record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        self.assertIsNotNone(record)
        self.assertEqual(record.own_values_definitions, [])
        self.assertIsNone(record.own_value)

    def test_clear_clears_all_canonical_lists(self) -> None:
        evaluate(parse_input_form(f"{self.symbol_name} = 1"))
        record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        self.assertIsNotNone(record)
        # Pre-populate every canonical list to ensure Clear sweeps them all.
        for kind in ALL_VALUE_KINDS:
            assign_definition(
                record,
                kind=kind,
                hold_pattern=parse_input_form(f"HoldPattern[{self.symbol_name}]"),
                rhs=parse_input_form("99"),
                delayed=False,
            )
        evaluate(parse_input_form(f"Clear[{self.symbol_name}]"))
        for kind in ALL_VALUE_KINDS:
            self.assertEqual(definitions_for_kind(record, kind), [])


class CanonicalApiTests(unittest.TestCase):
    """Exercise the public ``assign_definition`` / ``remove_definition`` /
    ``clear_definitions`` / ``rules_for_kind`` API directly so the
    upcoming pattern-matched evaluator can plug in without surprises."""

    def setUp(self) -> None:
        self.symbol_name = f"tungstenApiTest{abs(hash((id(self), self._testMethodName))) % 1000000}"
        evaluate(parse_input_form(f"Clear[{self.symbol_name}]"))
        record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        if record is None:
            evaluate(parse_input_form(f"{self.symbol_name} = 0"))
            evaluate(parse_input_form(f"{self.symbol_name} =."))
            record = _SYMBOL_REGISTRY.resolve_existing(self.symbol_name)
        self.record = record
        # Reset the canonical lists explicitly in case prior tests left
        # entries via this same fresh-symbol naming convention.
        for kind in ALL_VALUE_KINDS:
            definitions_for_kind(self.record, kind).clear()

    def tearDown(self) -> None:
        for kind in ALL_VALUE_KINDS:
            definitions_for_kind(self.record, kind).clear()

    def test_assign_definition_appends_for_new_pattern(self) -> None:
        lhs1 = parse_input_form(f"HoldPattern[{self.symbol_name}[1]]")
        lhs2 = parse_input_form(f"HoldPattern[{self.symbol_name}[2]]")
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs1, rhs=parse_input_form("a"), delayed=False)
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs2, rhs=parse_input_form("b"), delayed=True)
        self.assertEqual(len(definitions_for_kind(self.record, VALUE_KIND_DOWN)), 2)
        self.assertEqual(rules_for_kind(self.record, VALUE_KIND_DOWN)[0].to_full_form(),
                         f"RuleDelayed[HoldPattern[{self.symbol_name}[1]], a]")

    def test_assign_definition_replaces_for_identical_pattern(self) -> None:
        lhs = parse_input_form(f"HoldPattern[{self.symbol_name}[1]]")
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs, rhs=parse_input_form("a"), delayed=False)
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs, rhs=parse_input_form("z"), delayed=False)
        defs = definitions_for_kind(self.record, VALUE_KIND_DOWN)
        self.assertEqual(len(defs), 1)
        self.assertEqual(defs[0].rhs.to_full_form(), "z")

    def test_remove_definition_returns_true_only_when_match_found(self) -> None:
        lhs = parse_input_form(f"HoldPattern[{self.symbol_name}[1]]")
        other = parse_input_form(f"HoldPattern[{self.symbol_name}[2]]")
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs, rhs=parse_input_form("a"), delayed=False)
        self.assertFalse(remove_definition(self.record, VALUE_KIND_DOWN, other))
        self.assertTrue(remove_definition(self.record, VALUE_KIND_DOWN, lhs))
        self.assertEqual(definitions_for_kind(self.record, VALUE_KIND_DOWN), [])

    def test_clear_definitions_kinds(self) -> None:
        lhs = parse_input_form(f"HoldPattern[{self.symbol_name}[1]]")
        assign_definition(self.record, kind=VALUE_KIND_DOWN, hold_pattern=lhs, rhs=parse_input_form("a"), delayed=False)
        assign_definition(self.record, kind=VALUE_KIND_UP, hold_pattern=lhs, rhs=parse_input_form("b"), delayed=False)
        clear_definitions(self.record, [VALUE_KIND_DOWN])
        self.assertEqual(definitions_for_kind(self.record, VALUE_KIND_DOWN), [])
        self.assertEqual(len(definitions_for_kind(self.record, VALUE_KIND_UP)), 1)
        clear_definitions(self.record)
        self.assertEqual(definitions_for_kind(self.record, VALUE_KIND_UP), [])


class ClassifyAssignmentLhsTests(unittest.TestCase):
    """LHS classification surfaces what kind of value list a Set or
    SetDelayed assignment would write to."""

    def test_bare_symbol_classifies_as_own_values(self) -> None:
        kind, target = classify_assignment_lhs(parse_input_form("x"))
        self.assertEqual(kind, VALUE_KIND_OWN)
        self.assertIsNotNone(target)

    def test_function_call_classifies_as_down_values(self) -> None:
        kind, target = classify_assignment_lhs(parse_input_form("f[x_]"))
        self.assertEqual(kind, VALUE_KIND_DOWN)
        self.assertEqual(target.to_full_form(), "f")  # type: ignore[union-attr]

    def test_curried_call_classifies_as_sub_values(self) -> None:
        kind, target = classify_assignment_lhs(parse_input_form("f[x_][y_]"))
        self.assertEqual(kind, VALUE_KIND_SUB)
        self.assertEqual(target.to_full_form(), "f")  # type: ignore[union-attr]


class CompoundLhsAssignmentTests(unittest.TestCase):
    """Set / SetDelayed with a compound LHS routes through the classifier
    and currently raises a clear "not yet supported" error rather than
    silently leaving the call inert. The upcoming compound-LHS pass will
    replace this error with actual rule storage."""

    def test_set_with_function_lhs_raises(self) -> None:
        result = evaluate(parse_input_form("f[x_] = x + 1"))
        rendered = result.to_full_form()
        # The evaluator catches WolframEvaluationError and emits a
        # Head::error message before returning the inert form.
        self.assertEqual(rendered, "Set[f[Pattern[x, Blank[]]], Plus[x, 1]]")

    def test_set_delayed_with_function_lhs_raises(self) -> None:
        result = evaluate(parse_input_form("g[y_] := y * 2"))
        rendered = result.to_full_form()
        self.assertEqual(rendered, "SetDelayed[g[Pattern[y, Blank[]]], Times[y, 2]]")


class ValueGetterTests(unittest.TestCase):
    """OwnValues / DownValues / UpValues / SubValues / NValues read from
    the canonical lists. Until compound-LHS Set lands they are empty for
    user symbols, which matches the kernel's behavior for unset names."""

    def test_own_values_after_set_lists_one_rule(self) -> None:
        evaluate(parse_input_form("tungstenGet1 = 11"))
        try:
            self.assertEqual(
                _full("OwnValues[tungstenGet1]"),
                "List[RuleDelayed[HoldPattern[tungstenGet1], 11]]",
            )
        finally:
            evaluate(parse_input_form("Clear[tungstenGet1]"))

    def test_own_values_after_set_delayed_holds_rhs(self) -> None:
        evaluate(parse_input_form("tungstenGet2 := 1 + 2"))
        try:
            self.assertEqual(
                _full("OwnValues[tungstenGet2]"),
                "List[RuleDelayed[HoldPattern[tungstenGet2], Plus[1, 2]]]",
            )
        finally:
            evaluate(parse_input_form("Clear[tungstenGet2]"))

    def test_down_values_default_empty(self) -> None:
        self.assertEqual(_full("DownValues[unsetSymbolDV]"), "List[]")

    def test_up_values_default_empty(self) -> None:
        self.assertEqual(_full("UpValues[unsetSymbolUV]"), "List[]")

    def test_sub_values_default_empty(self) -> None:
        self.assertEqual(_full("SubValues[unsetSymbolSV]"), "List[]")

    def test_n_values_default_empty(self) -> None:
        self.assertEqual(_full("NValues[unsetSymbolNV]"), "List[]")


class ScopingStubTests(unittest.TestCase):
    """``Module`` and ``Block`` are still stubs that emit a clear
    not-yet-supported message and return the inert call. ``With`` was
    implemented in a follow-up pass and now performs capture-avoiding
    substitution; see ``WithEvaluationTests`` for its behavior."""

    def test_module_returns_inert_form(self) -> None:
        self.assertEqual(
            _full("Module[{x = 5}, x + 1]"),
            "Module[List[Set[x, 5]], Plus[x, 1]]",
        )

    def test_block_returns_inert_form(self) -> None:
        self.assertEqual(
            _full("Block[{x = 5}, x + 1]"),
            "Block[List[Set[x, 5]], Plus[x, 1]]",
        )


class WithEvaluationTests(unittest.TestCase):
    """``With[bindings, body]`` performs capture-avoiding substitution.

    The bindings list is a ``List`` whose entries are ``Set[name, value]``
    or ``SetDelayed[name, value]``. ``Set`` evaluates the RHS once in the
    outer scope and substitutes the resulting value; ``SetDelayed``
    substitutes the *unevaluated* RHS so each in-body occurrence
    re-evaluates where it lands.

    Substitution is capture-avoiding through ``Function`` and through
    nested ``With`` / ``Module`` / ``Block`` constructs.
    """

    def test_basic_immediate_binding(self) -> None:
        self.assertEqual(_full("With[{x = 5}, x + 1]"), "6")

    def test_multiple_independent_bindings(self) -> None:
        self.assertEqual(_full("With[{x = 5, y = 6}, x + y]"), "11")

    def test_symbolic_values_substitute(self) -> None:
        self.assertEqual(_full("With[{x = a, y = b}, x + y]"), "Plus[a, b]")

    def test_value_is_pre_evaluated_once(self) -> None:
        self.assertEqual(_full("With[{x = 1 + 2}, x * x]"), "9")

    def test_bindings_are_independent_so_second_does_not_see_first(self) -> None:
        # ``With[{x = 1, y = x + 1}, {x, y}]`` evaluates each binding's
        # RHS in the OUTER scope. The outer ``x`` is unbound, so ``y``
        # binds to the symbolic ``x + 1`` rather than ``2``.
        self.assertEqual(
            _full("With[{x = 1, y = x + 1}, {x, y}]"),
            "List[1, Plus[1, x]]",
        )

    def test_substitutes_through_hold_family(self) -> None:
        self.assertEqual(_full("With[{x = 5}, Hold[x]]"), "Hold[5]")
        self.assertEqual(_full("With[{x = 5}, HoldComplete[x]]"), "HoldComplete[5]")
        self.assertEqual(_full("With[{x = 5}, HoldPattern[x]]"), "HoldPattern[5]")
        # ``Unevaluated`` is substituted through too. The kernel strips
        # ``Unevaluated[5]`` at the top level to ``5``; Tungsten leaves
        # it as ``Unevaluated[5]`` (a pre-existing Unevaluated-handling
        # gap that is independent of With's substitution semantics).
        self.assertEqual(_full("With[{x = 5}, Unevaluated[x]]"), "Unevaluated[5]")

    def test_substitutes_through_pattern_name(self) -> None:
        # With substitutes into pattern-name positions; this is consistent
        # with treating ``Pattern[...]`` as an ordinary Call rather than a
        # binding form.
        self.assertEqual(_full("With[{x = 5}, x_]"), "Pattern[5, Blank[]]")

    def test_function_with_shadowing_parameter_blocks_substitution(self) -> None:
        # The Function's ``x`` parameter shadows With's ``x``; no
        # substitution flows in, and no rename happens either.
        self.assertEqual(
            _full("With[{x = 5}, Function[x, x + 1]]"),
            "Function[x, Plus[x, 1]]",
        )
        self.assertEqual(_full("With[{x = 5}, Function[x, x + 1][7]]"), "8")

    def test_function_with_non_shadowed_parameter_alpha_renames(self) -> None:
        # Substitution flows in; the inner Function's parameter ``y`` is
        # alpha-renamed to ``y$`` for kernel parity (the kernel always
        # renames Function parameters when substitution flows into the
        # body, even when no actual capture would occur).
        self.assertEqual(
            _full("With[{x = 5}, Function[y, x + y]]"),
            "Function[y$, Plus[5, y$]]",
        )
        self.assertEqual(_full("With[{x = 5}, Function[y, x + y][3]]"), "8")

    def test_capture_avoiding_rename_when_value_contains_inner_param_name(self) -> None:
        # The inner Function's parameter ``y`` would capture the free
        # ``y`` inside With's value ``y``; the rename is essential for
        # correctness here, not just cosmetic.
        self.assertEqual(
            _full("With[{x = y}, Function[y, x]]"),
            "Function[y$, y]",
        )
        # And the renamed function still passes its argument through
        # correctly: applied to 7 it should return the OUTER y (which is
        # the free symbol), not 7.
        self.assertEqual(_full("With[{x = y}, Function[y, x][7]]"), "y")

    def test_set_delayed_binding_holds_rhs(self) -> None:
        # ``SetDelayed`` substitutes the unevaluated RHS so each in-body
        # occurrence re-evaluates where it lands.
        self.assertEqual(_full("With[{x := 5}, x + 1]"), "6")
        self.assertEqual(
            _full("With[{x := a + b}, {x, x}]"),
            "List[Plus[a, b], Plus[a, b]]",
        )

    def test_nested_with_inner_shadows_outer(self) -> None:
        self.assertEqual(_full("With[{x = 5}, With[{x = 99}, x]]"), "99")

    def test_nested_with_chains_substitution(self) -> None:
        # Outer x flows into inner With's binding RHS but not its body
        # (which is shielded by the inner With's binding).
        self.assertEqual(_full("With[{x = 5}, With[{y = x + 1}, y * 2]]"), "12")
        self.assertEqual(_full("With[{x = 1}, With[{y = 2}, x + y]]"), "3")

    def test_function_argument_flows_into_with(self) -> None:
        # Function's positional slot is substituted at apply time; the
        # resulting With then evaluates normally.
        self.assertEqual(_full("(With[{x = #}, x + 1] &)[10]"), "11")

    def test_function_named_argument_is_shielded_inside_inner_with(self) -> None:
        # The outer Function's parameter ``t`` is substituted into the
        # inner With's binding RHS (``t + 1``); the inner With's ``u``
        # shadows the body but doesn't conflict with anything here.
        self.assertEqual(
            _full("Function[t, With[{u = t + 1}, u * 2]][10]"),
            "22",
        )

    def test_function_with_shadowing_inner_with_blocks_outer_substitution(self) -> None:
        # ``Function[x, With[{x = 5}, x + 1]][99]`` should evaluate to 6.
        # Function substitutes ``x = 99`` into its body; the inner With
        # rebinds ``x`` to ``5`` so the body becomes ``5 + 1 = 6``. If
        # substitution were not scope-aware, the inner With's ``x`` would
        # be clobbered to 99.
        self.assertEqual(
            _full("Function[x, With[{x = 5}, x + 1]][99]"),
            "6",
        )

    def test_empty_bindings_returns_evaluated_body(self) -> None:
        self.assertEqual(_full("With[{}, 7]"), "7")
        self.assertEqual(_full("With[{}, 1 + 2 + 3]"), "6")

    def test_substitution_preserves_held_function_inside_hold(self) -> None:
        # ``Hold[Function[x, x + 1]]`` is fully held; substitution
        # walks into ``Hold`` (Hold doesn't shadow With) but the inner
        # Function still shadows ``x`` so no substitution occurs there.
        self.assertEqual(
            _full("With[{x = 5}, Hold[Function[x, x + 1]]]"),
            "Hold[Function[x, Plus[x, 1]]]",
        )

    def test_set_with_substituted_lhs_emits_error(self) -> None:
        # ``With[{x = 5}, x = 99]`` substitutes to ``Set[5, 99]``, which
        # is not a valid bare-symbol Set. Tungsten's set_expr emits an
        # error and leaves the call inert.
        result = _full("With[{x = 5}, Set[x, 99]]")
        self.assertEqual(result, "Set[5, 99]")

    def test_invalid_bindings_list_raises(self) -> None:
        # First argument must be a List of Set/SetDelayed expressions.
        result = _full("With[5, x]")
        # The error path leaves the call inert.
        self.assertEqual(result, "With[5, x]")

    def test_duplicate_binding_name_raises(self) -> None:
        # Tungsten flags duplicate names rather than silently
        # last-wins-ing, since the kernel emits a duplicate-binding
        # error too. We assert on the inert fallback shape here.
        result = _full("With[{x = 1, x = 2}, x]")
        self.assertEqual(result, "With[List[Set[x, 1], Set[x, 2]], x]")


if __name__ == "__main__":
    unittest.main()
