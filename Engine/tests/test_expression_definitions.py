"""Tests for symbol-definition storage, compound-LHS Set / SetDelayed, and
the value getter additions that prepare the field for UpSet, TagSet, and
With / Module / Block work.

These tests exercise:

- The ``Definition`` dataclass and ``SymbolRecord.definitions_for_kind``
  storage shape.
- The Set / SetDelayed / Unset / Clear interaction with the canonical
  ``own_values_definitions`` list in addition to the legacy single-slot
  ``own_value`` field.
- The ``OwnValues`` / ``DownValues`` / ``UpValues`` / ``SubValues`` /
  ``NValues`` getters reading from the canonical storage, including
  DownValues and SubValues populated by compound-LHS assignments.
- The ``With`` / ``Module`` / ``Block`` stubs that emit a clear
  not-yet-supported message instead of leaving calls silently inert.
- The compound-LHS classifier and evaluator path for ``f[x_] := ...`` and
  ``f[x_][y_] := ...``.

Behavioral changes for fresh Module symbols and dynamic Block scope are out
of scope here; this file's job is to lock down definition storage and the
pattern-matched evaluator surface those later passes will use.
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
    """Set / SetDelayed with a compound LHS now writes DownValues or
    SubValues and the evaluator applies those rules through the ordinary
    pattern matcher."""

    def setUp(self) -> None:
        suffix = abs(hash((id(self), self._testMethodName))) % 1000000
        self.f = f"tungstenFn{suffix}"
        self.g = f"tungstenG{suffix}"
        self.h = f"tungstenH{suffix}"
        self.q = f"tungstenQ{suffix}"
        self.x = f"tungstenX{suffix}"
        self.y = f"tungstenY{suffix}"
        for name in (self.f, self.g, self.h, self.q, self.x, self.y):
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def tearDown(self) -> None:
        for name in (self.f, self.g, self.h, self.q, self.x, self.y):
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def test_set_with_pattern_lhs_assigns_downvalue(self) -> None:
        self.assertEqual(_full(f"{self.f}[{self.x}_] = {self.x} + 1"), f"Plus[1, {self.x}]")
        self.assertEqual(_full(f"{self.f}[3]"), "4")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]]], Plus[1, {self.x}]]]",
        )

    def test_set_evaluates_rhs_before_lhs_arguments(self) -> None:
        evaluate(parse_input_form(f"{self.x} = 10"))
        self.assertEqual(_full(f"{self.f}[{self.x}_] = {self.x} + 1"), "11")
        self.assertEqual(_full(f"{self.f}[3]"), "11")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]]], 11]]",
        )

    def test_set_delayed_with_pattern_lhs_evaluates_rhs_each_time(self) -> None:
        evaluate(parse_input_form(f"{self.y} = 5"))
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := {self.x} + {self.y}"))
        self.assertEqual(_full(f"{self.f}[3]"), "8")
        evaluate(parse_input_form(f"{self.y} = 10"))
        self.assertEqual(_full(f"{self.f}[3]"), "13")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]]], Plus[{self.x}, {self.y}]]]",
        )

    def test_lhs_arguments_are_evaluated_unless_head_holds_them(self) -> None:
        evaluate(parse_input_form(f"{self.x} = 1"))
        evaluate(parse_input_form(f"{self.f}[{self.x}] = 99"))
        self.assertEqual(_full(f"{self.f}[1]"), "99")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[1]], 99]]",
        )

        evaluate(parse_input_form(f"SetAttributes[{self.g}, HoldAll]"))
        evaluate(parse_input_form(f"{self.g}[{self.x}] = 77"))
        self.assertEqual(_full(f"{self.g}[1]"), f"{self.g}[1]")
        self.assertEqual(_full(f"{self.g}[{self.x}]"), "77")
        self.assertEqual(
            _full(f"DownValues[{self.g}]"),
            f"List[RuleDelayed[HoldPattern[{self.g}[{self.x}]], 77]]",
        )

    def test_lhs_head_own_value_is_used_for_assignment_tagging(self) -> None:
        evaluate(parse_input_form(f"{self.f} = List"))
        result = evaluate(parse_input_form(f"{self.f}[1] = 2"))
        self.assertEqual(result.to_full_form(), "Set[List[1], 2]")
        self.assertEqual(_full(f"DownValues[{self.f}]"), "List[]")

    def test_exact_definitions_are_ordered_before_generic_patterns(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := {self.x} * {self.f}[{self.x} - 1]"))
        evaluate(parse_input_form(f"{self.f}[1] = 1"))
        self.assertEqual(_full(f"{self.f}[4]"), "24")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[1]], 1], RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]]], Times[{self.x}, {self.f}[Plus[{self.x}, Times[-1, 1]]]]]]",
        )

    def test_lhs_condition_and_rhs_condition_are_applied(self) -> None:
        evaluate(parse_input_form(f"({self.f}[{self.x}_] /; {self.x} > 0) := {self.x}"))
        evaluate(parse_input_form(f"{self.g}[{self.x}_] := {self.x} /; {self.x} > 0"))
        self.assertEqual(_full(f"{{{self.f}[2], {self.f}[-1], {self.g}[2], {self.g}[-1]}}"), f"List[2, {self.f}[-1], 2, {self.g}[-1]]")

    def test_downvalues_support_conditions_at_multiple_levels(self) -> None:
        evaluate(parse_input_form(f"({self.f}[{self.x}_] /; {self.x} > 0) := lhsOuter[{self.x}]"))
        evaluate(parse_input_form(f"{self.g}[{self.x}_ /; {self.x} < 0] := lhsInner[{self.x}]"))
        evaluate(parse_input_form(f"{self.h}[{self.x}_] := rhsCondition[{self.x}] /; {self.x} > 10"))

        self.assertEqual(_full(f"{self.f}[2]"), "lhsOuter[2]")
        self.assertEqual(_full(f"{self.f}[-2]"), f"{self.f}[-2]")
        self.assertEqual(_full(f"{self.g}[-2]"), "lhsInner[-2]")
        self.assertEqual(_full(f"{self.g}[2]"), f"{self.g}[2]")
        self.assertEqual(_full(f"{self.h}[11]"), "rhsCondition[11]")
        self.assertEqual(_full(f"{self.h}[5]"), f"{self.h}[5]")

    def test_downvalue_multiple_equations_and_unset(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := positive /; {self.x} > 0"))
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := negative /; {self.x} < 0"))
        evaluate(parse_input_form(f"{self.f}[0] = zero"))

        self.assertEqual(_full(f"{self.f}[2]"), "positive")
        self.assertEqual(_full(f"{self.f}[-2]"), "negative")
        self.assertEqual(_full(f"{self.f}[0]"), "zero")
        self.assertEqual(_full(f"{self.f}[{self.x}_] =."), "Null")
        self.assertEqual(_full(f"{self.f}[2]"), f"{self.f}[2]")
        self.assertEqual(_full(f"{self.f}[-2]"), f"{self.f}[-2]")
        self.assertEqual(_full(f"{self.f}[0]"), "zero")

    def test_curried_lhs_assigns_subvalue(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_][{self.y}_] := {{{self.x}, {self.y}}}"))
        self.assertEqual(_full(f"{self.f}[1][2]"), "List[1, 2]")
        self.assertEqual(_full(f"DownValues[{self.f}]"), "List[]")
        self.assertEqual(
            _full(f"SubValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]][Pattern[{self.y}, Blank[]]]], List[{self.x}, {self.y}]]]",
        )

    def test_curried_lhs_head_retargets_through_existing_downvalue(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := {self.g}[{self.x}]"))
        evaluate(parse_input_form(f"{self.f}[{self.x}_][{self.y}_] := {{{self.x}, {self.y}}}"))
        self.assertEqual(_full(f"{self.f}[1][2]"), "List[1, 2]")
        self.assertEqual(_full(f"SubValues[{self.f}]"), "List[]")
        self.assertEqual(
            _full(f"SubValues[{self.g}]"),
            f"List[RuleDelayed[HoldPattern[{self.g}[Pattern[{self.x}, Blank[]]][Pattern[{self.y}, Blank[]]]], List[{self.x}, {self.y}]]]",
        )

    def test_subvalue_multiple_equations_and_unset(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_][{self.y}_] := positive[{self.y}] /; {self.x} > 0"))
        evaluate(parse_input_form(f"{self.f}[{self.x}_][{self.y}_] := negative[{self.y}] /; {self.x} < 0"))

        self.assertEqual(_full(f"{self.f}[2][9]"), "positive[9]")
        self.assertEqual(_full(f"{self.f}[-2][9]"), "negative[9]")
        self.assertEqual(_full(f"{self.f}[{self.x}_][{self.y}_] =."), "Null")
        self.assertEqual(_full(f"{self.f}[2][9]"), f"{self.f}[2][9]")
        self.assertEqual(_full(f"{self.f}[-2][9]"), f"{self.f}[-2][9]")

    def test_compound_unset_removes_matching_definition(self) -> None:
        evaluate(parse_input_form(f"{self.f}[1] = 10"))
        evaluate(parse_input_form(f"{self.f}[1] =."))
        self.assertEqual(_full(f"{self.f}[1]"), f"{self.f}[1]")
        self.assertEqual(_full(f"DownValues[{self.f}]"), "List[]")

    def test_value_q_recognizes_compound_definitions(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := {self.x}"))
        self.assertEqual(_full(f"ValueQ[{self.f}[2]]"), "True")
        self.assertEqual(_full(f"ValueQ[{self.g}[2]]"), "False")

    def test_tagset_redundant_own_down_and_sub_values(self) -> None:
        self.assertEqual(_full(f"{self.f} /: {self.f} = 7"), "7")
        self.assertEqual(_full(f"{self.f}"), "7")
        self.assertEqual(
            _full(f"OwnValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}], 7]]",
        )
        evaluate(parse_input_form(f"ClearAll[{self.f}]"))

        evaluate(parse_input_form(f"{self.f} /: {self.f}[{self.x}_] := {self.x} + 1"))
        self.assertEqual(_full(f"{self.f}[3]"), "4")
        self.assertEqual(
            _full(f"DownValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]]], Plus[{self.x}, 1]]]",
        )
        evaluate(parse_input_form(f"ClearAll[{self.f}]"))

        evaluate(parse_input_form(f"{self.f} /: {self.f}[{self.x}_][{self.y}_] := {{{self.x}, {self.y}}}"))
        self.assertEqual(_full(f"{self.f}[1][2]"), "List[1, 2]")
        self.assertEqual(
            _full(f"SubValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.f}[Pattern[{self.x}, Blank[]]][Pattern[{self.y}, Blank[]]]], List[{self.x}, {self.y}]]]",
        )

    def test_tagset_and_tagsetdelayed_create_upvalues(self) -> None:
        evaluate(parse_input_form(f"{self.y} = 5"))
        self.assertEqual(_full(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] = {self.x} + {self.y}"), f"Plus[5, {self.x}]")
        self.assertEqual(_full(f"{self.h}[{self.f}[3]]"), "8")
        evaluate(parse_input_form(f"{self.y} = 10"))
        self.assertEqual(_full(f"{self.h}[{self.f}[3]]"), "8")
        self.assertEqual(_full(f"DownValues[{self.h}]"), "List[]")
        self.assertEqual(
            _full(f"UpValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.h}[{self.f}[Pattern[{self.x}, Blank[]]]]], Plus[5, {self.x}]]]",
        )

        evaluate(parse_input_form(f"{self.g} /: {self.h}[{self.g}[{self.x}_]] := {self.x} + {self.y}"))
        self.assertEqual(_full(f"{self.h}[{self.g}[3]]"), "13")
        evaluate(parse_input_form(f"{self.y} = 20"))
        self.assertEqual(_full(f"{self.h}[{self.g}[3]]"), "23")

    def test_upvalues_apply_before_downvalues_and_respect_hold_all_complete(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := up[{self.x}]"))
        evaluate(parse_input_form(f"{self.h}[{self.x}_] := down[{self.x}]"))
        self.assertEqual(_full(f"{self.h}[{self.f}[1]]"), "up[1]")

        evaluate(parse_input_form(f"SetAttributes[{self.q}, HoldAll]"))
        evaluate(parse_input_form(f"{self.f} /: {self.q}[{self.f}[{self.x}_]] := heldUp[{self.x}]"))
        self.assertEqual(_full(f"{self.q}[{self.f}[2]]"), "heldUp[2]")

        evaluate(parse_input_form(f"SetAttributes[{self.g}, HoldAllComplete]"))
        evaluate(parse_input_form(f"{self.f} /: {self.g}[{self.f}[{self.x}_]] := suppressed[{self.x}]"))
        self.assertEqual(_full(f"{self.g}[{self.f}[2]]"), f"{self.g}[{self.f}[2]]")

    def test_tagset_supports_conditions_at_multiple_levels(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: ({self.h}[{self.f}[{self.x}_]] /; {self.x} > 0) := lhsOuter[{self.x}]"))
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_ /; {self.x} < 0]] := lhsInner[{self.x}]"))
        evaluate(parse_input_form(f"{self.f} /: condRhs[{self.f}[{self.x}_]] := rhsCondition[{self.x}] /; {self.x} > 10"))

        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), "lhsOuter[2]")
        self.assertEqual(_full(f"{self.h}[{self.f}[-2]]"), "lhsInner[-2]")
        self.assertEqual(_full(f"{self.h}[{self.f}[0]]"), f"{self.h}[{self.f}[0]]")
        self.assertEqual(_full(f"condRhs[{self.f}[11]]"), "rhsCondition[11]")
        self.assertEqual(_full(f"condRhs[{self.f}[5]]"), f"condRhs[{self.f}[5]]")

    def test_tagset_multiple_equations_and_exact_priority(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := positive /; {self.x} > 0"))
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := negative /; {self.x} < 0"))
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[0]] = zero"))

        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), "positive")
        self.assertEqual(_full(f"{self.h}[{self.f}[-2]]"), "negative")
        self.assertEqual(_full(f"{self.h}[{self.f}[0]]"), "zero")
        upvalues = _full(f"UpValues[{self.f}]")
        self.assertIn(f"RuleDelayed[HoldPattern[{self.h}[{self.f}[0]]], zero]", upvalues)
        self.assertIn(f"RuleDelayed[HoldPattern[{self.h}[{self.f}[Pattern[{self.x}, Blank[]]]]], Condition[positive, Greater[{self.x}, 0]]]", upvalues)
        self.assertIn(f"RuleDelayed[HoldPattern[{self.h}[{self.f}[Pattern[{self.x}, Blank[]]]]], Condition[negative, Less[{self.x}, 0]]]", upvalues)

    def test_tagset_head_chain_argument_and_deep_invalid_occurrence(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_][{self.y}_]] := {{{self.x}, {self.y}}}"))
        self.assertEqual(_full(f"{self.h}[{self.f}[1][2]]"), "List[1, 2]")
        self.assertEqual(
            _full(f"UpValues[{self.f}]"),
            f"List[RuleDelayed[HoldPattern[{self.h}[{self.f}[Pattern[{self.x}, Blank[]]][Pattern[{self.y}, Blank[]]]]], List[{self.x}, {self.y}]]]",
        )

        evaluate(parse_input_form(f"{self.g} /: {self.h}[deep[{self.g}[{self.x}_]]] := {self.x}"))
        self.assertEqual(_full(f"{self.h}[deep[{self.g}[1]]]"), f"{self.h}[deep[{self.g}[1]]]")
        self.assertEqual(_full(f"UpValues[{self.g}]"), "List[]")

    def test_tagunset_removes_tagged_values_only(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := {self.x}"))
        self.assertEqual(_full(f"{self.h}[{self.f}[2]] =."), "$Failed")
        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), "2")

        self.assertEqual(_full(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] =."), "Null")
        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), f"{self.h}[{self.f}[2]]")
        self.assertEqual(_full(f"UpValues[{self.f}]"), "List[]")

    def test_tagunset_removes_all_equations_for_same_lhs(self) -> None:
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := positive /; {self.x} > 0"))
        evaluate(parse_input_form(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] := negative /; {self.x} < 0"))
        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), "positive")
        self.assertEqual(_full(f"{self.h}[{self.f}[-2]]"), "negative")
        self.assertEqual(_full(f"{self.f} /: {self.h}[{self.f}[{self.x}_]] =."), "Null")
        self.assertEqual(_full(f"{self.h}[{self.f}[2]]"), f"{self.h}[{self.f}[2]]")
        self.assertEqual(_full(f"{self.h}[{self.f}[-2]]"), f"{self.h}[{self.f}[-2]]")
        self.assertEqual(_full(f"UpValues[{self.f}]"), "List[]")


class ValueGetterTests(unittest.TestCase):
    """OwnValues / DownValues / UpValues / SubValues / NValues read from
    the canonical lists. Unset user symbols still return empty lists, which
    matches the kernel's behavior for names without definitions."""

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
    """``Block`` is still a stub that emits a clear not-yet-supported
    message and returns the inert call. ``With`` and ``Module`` were
    implemented in follow-up passes; see ``WithEvaluationTests`` and
    ``ModuleEvaluationTests`` for their behavior."""

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


class ModuleEvaluationTests(unittest.TestCase):
    """``Module[{locals}, body]`` allocates a fresh per-invocation symbol
    for every local, installs each binding's RHS as the fresh symbol's
    own value (in the *outer* scope, so bindings are independent), and
    rewrites ``body`` to refer to the fresh symbols.

    The fresh symbol's exact suffix number is process-counter-dependent,
    so tests that observe a fresh symbol's full form use a Tungsten-style
    sentinel (``x$N`` with ``N`` from the registry's
    ``allocate_module_local_symbols`` helper) and assert on shape rather
    than literal equality. Tests that observe only the *value* of a
    Module expression are unaffected by the suffix.
    """

    def test_basic_immediate_binding(self) -> None:
        self.assertEqual(_full("Module[{x = 5}, x + 1]"), "6")

    def test_multiple_independent_bindings(self) -> None:
        self.assertEqual(_full("Module[{x = 5, y = 6}, x + y]"), "11")

    def test_bindings_are_independent_so_second_does_not_see_first(self) -> None:
        # Each binding's RHS is evaluated in the OUTER scope, so the
        # second binding's ``x + 1`` sees the OUTER (free) ``x``, not
        # the local. The local ``x`` separately gets value 5.
        self.assertEqual(
            _full("Module[{x = 5, y = x + 1}, {x, y}]"),
            "List[5, Plus[1, x]]",
        )

    def test_set_delayed_binding_holds_rhs(self) -> None:
        self.assertEqual(
            _full("Module[{x := a + b}, {x, x}]"),
            "List[Plus[a, b], Plus[a, b]]",
        )

    def test_no_init_binding_returns_fresh_symbol(self) -> None:
        # The fresh symbol's exact name varies per session; assert on
        # the shape and on the ``x$`` prefix instead.
        rendered = _full("Module[{x}, x + 1]")
        self.assertTrue(
            rendered.startswith("Plus[1, x$") and rendered.endswith("]"),
            f"unexpected fresh-symbol shape: {rendered!r}",
        )

    def test_no_init_with_init_mixed(self) -> None:
        self.assertEqual(_full("Module[{x, y = 5}, y * 2]"), "10")

    def test_empty_bindings_returns_evaluated_body(self) -> None:
        self.assertEqual(_full("Module[{}, 7]"), "7")

    def test_local_can_be_mutated_in_body(self) -> None:
        # Module makes its locals real symbols, so the body can ``Set``
        # them. This is what distinguishes Module from With (whose body
        # would substitute the value directly).
        self.assertEqual(_full("Module[{x = 5}, x = 99; x]"), "99")

    def test_local_can_be_mutated_in_loop(self) -> None:
        self.assertEqual(
            _full(
                "Module[{counter = 0}, "
                "counter = counter + 1; counter = counter + 1; counter]"
            ),
            "2",
        )

    def test_nested_inner_module_shadows(self) -> None:
        self.assertEqual(_full("Module[{x = 1}, Module[{x = 2}, x]]"), "2")

    def test_nested_module_chains_through_outer_locals(self) -> None:
        # Outer ``x`` is in scope for the inner Module's RHS evaluation
        # because the inner RHS evaluates in the (outer-of-inner) scope,
        # which has the outer Module's local in scope.
        self.assertEqual(
            _full("Module[{x = 1}, Module[{y = x + 1}, x + y]]"),
            "3",
        )

    def test_function_with_shadowing_parameter_blocks_substitution(self) -> None:
        self.assertEqual(
            _full("Module[{x = 5}, Function[x, x + 1][7]]"),
            "8",
        )

    def test_function_with_non_shadowed_parameter_picks_up_local(self) -> None:
        self.assertEqual(
            _full("Module[{x = 5}, Function[y, x + y][3]]"),
            "8",
        )

    def test_with_evaluating_into_module_works(self) -> None:
        # ``With``'s substitution flows through the inner Module's
        # bindings RHS, then Module evaluates normally.
        self.assertEqual(_full("With[{x = 5}, Module[{y = x + 1}, y]]"), "6")

    def test_function_with_module_local_in_body(self) -> None:
        self.assertEqual(
            _full("Function[t, Module[{u = t + 1}, u * 2]][10]"),
            "22",
        )

    def test_three_locals_share_same_counter_suffix(self) -> None:
        self.assertEqual(
            _full("Module[{x = 1, y = 2, z = 3}, x + y + z]"),
            "6",
        )

    def test_set_delayed_function_uses_fresh_module_each_call(self) -> None:
        # ``f := Module[{x = 5}, x + 1]; f`` evaluates the Module on
        # every read of ``f``. Each read allocates a fresh ``x$N`` —
        # both reads still produce ``6`` because the body is identical.
        evaluate(parse_input_form("ClearAll[tungstenModuleF]"))
        try:
            evaluate(parse_input_form("tungstenModuleF := Module[{x = 5}, x + 1]"))
            self.assertEqual(_full("tungstenModuleF"), "6")
            self.assertEqual(_full("tungstenModuleF"), "6")
        finally:
            evaluate(parse_input_form("ClearAll[tungstenModuleF]"))

    def test_local_appears_in_own_values_under_fresh_name(self) -> None:
        # ``OwnValues[x]`` inside the Module body should report the
        # fresh ``x$N`` symbol's own value, not the original ``x``.
        rendered = _full("Module[{x = 5}, OwnValues[x]]")
        self.assertTrue(
            rendered.startswith("List[RuleDelayed[HoldPattern[x$"),
            f"unexpected OwnValues shape: {rendered!r}",
        )
        self.assertIn("], 5]]", rendered)

    def test_module_local_is_a_symbol(self) -> None:
        # ``Head[x]`` inside the Module body is ``Symbol`` — the fresh
        # ``x$N`` is a real registry symbol, not a special placeholder.
        self.assertEqual(_full("Module[{x}, Head[x]]"), "Symbol")
        self.assertEqual(_full("Module[{x}, x === x]"), "True")

    def test_substitutes_through_hold(self) -> None:
        # ``Module`` rewrites references to ``x`` even through ``Hold``;
        # the held form retains the fresh symbol.
        rendered = _full("Module[{x = 5}, Hold[x]]")
        self.assertTrue(
            rendered.startswith("Hold[x$") and rendered.endswith("]"),
            f"unexpected Hold shape: {rendered!r}",
        )

    def test_function_with_slot_initializer(self) -> None:
        self.assertEqual(_full("(Module[{x = #}, x + 1] &)[10]"), "11")

    def test_length_of_module_result(self) -> None:
        self.assertEqual(_full("Length[Module[{x = 5}, {x, x, x}]]"), "3")
        self.assertEqual(
            _full("Module[{x = 5}, {x, x, x}]"),
            "List[5, 5, 5]",
        )

    def test_independent_bindings_chain_falls_through_to_outer(self) -> None:
        # ``Module[{a = 1, b = a + 1, c = b + 1}, c]`` is independent
        # like With: the second and third RHS see the OUTER ``a`` and
        # ``b``, which are unbound, so ``c`` gets value ``b + 1``
        # where ``b`` is the outer (free) ``b``.
        self.assertEqual(
            _full("Module[{a = 1, b = a + 1, c = b + 1}, c]"),
            "Plus[1, b]",
        )

    def test_invalid_bindings_list_raises(self) -> None:
        result = _full("Module[5, x]")
        self.assertEqual(result, "Module[5, x]")

    def test_duplicate_binding_name_raises(self) -> None:
        result = _full("Module[{x = 1, x = 2}, x]")
        self.assertEqual(
            result,
            "Module[List[Set[x, 1], Set[x, 2]], x]",
        )


class ModuleClosureTests(unittest.TestCase):
    """End-to-end closure scenarios where a Module-allocated fresh symbol
    is captured by an outer assignment and later called.

    The shape is::

        g = Module[{f}, f[...] := ...; ... (* more definitions *); f]
        g[...]   (* dispatches into f's DownValues stored on f$N *)

    The scenario depends on three independent pieces working together:

    1. Module rewrites every reference to a local in the body — including
       the LHS of nested ``Set`` / ``SetDelayed`` and any later occurrence
       in the body — to the fresh ``f$N`` symbol.
    2. The compound-LHS ``Set`` / ``SetDelayed`` dispatch installs the
       rewritten rule on ``f$N``'s ``DownValues`` storage.
    3. The Module returns the fresh ``f$N`` symbol; the outer ``Set[g, ...]``
       stores it as ``g``'s own value; later ``g[args]`` resolves ``g``
       to ``f$N`` and dispatches against ``f$N``'s ``DownValues``.

    These tests use process-unique global names (``tungstenClosure*``)
    rather than ``g`` / ``h`` so they don't bleed state across runs.
    """

    def setUp(self) -> None:
        self.names_to_clear: list[str] = []

    def tearDown(self) -> None:
        for name in self.names_to_clear:
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def _track(self, *names: str) -> None:
        self.names_to_clear.extend(names)

    def test_simple_closure_dispatches_one_definition(self) -> None:
        # The canonical user scenario: define a function inside a Module,
        # return it, call it through the outer assignment.
        self._track("tungstenClosureG1")
        evaluate(parse_input_form("tungstenClosureG1 = Module[{f}, f[x_] := x^2; f]"))
        self.assertEqual(_full("tungstenClosureG1[3]"), "9")
        self.assertEqual(
            _full("tungstenClosureG1[a + b]"),
            "Power[Plus[a, b], 2]",
        )

    def test_closure_with_multi_equation_definition_dispatches_each_branch(self) -> None:
        # Two ``f[...] := ...`` bindings in the same Module body install
        # two DownValues on the same ``f$N``. The literal-LHS (specific)
        # one wins for ``h[0]`` and the pattern-LHS one wins for ``h[5]``.
        self._track("tungstenClosureH1")
        evaluate(
            parse_input_form(
                "tungstenClosureH1 = Module[{f}, f[0] := 1; f[n_] := n * f[n - 1]; f]"
            )
        )
        self.assertEqual(_full("tungstenClosureH1[5]"), "120")
        self.assertEqual(_full("tungstenClosureH1[10]"), "3628800")

    def test_closure_mutual_recursion_through_two_module_locals(self) -> None:
        # Both ``e`` and ``o`` are Module locals. Module's rewrite gives
        # them ``e$N`` and ``o$N`` (same ``N``); references between them
        # in the body resolve consistently. The mutual recursion bottoms
        # out at the literal-LHS base cases.
        self._track("tungstenClosureE1")
        evaluate(
            parse_input_form(
                "tungstenClosureE1 = Module[{e, o}, "
                "e[0] := True; e[n_] := o[n - 1]; "
                "o[0] := False; o[n_] := e[n - 1]; "
                "e]"
            )
        )
        self.assertEqual(_full("tungstenClosureE1[10]"), "True")
        self.assertEqual(_full("tungstenClosureE1[7]"), "False")

    def test_closure_memoization_via_set_inside_set_delayed(self) -> None:
        # Wolfram's standard memoization idiom:
        #   fib[n_] := fib[n] = If[n < 2, n, fib[n-1] + fib[n-2]]
        # Each ``fib$N[k]`` evaluates once via the pattern rule, then the
        # inner ``fib$N[k] = ...`` Set installs a literal-LHS DownValue
        # so subsequent calls hit the cached result directly.
        self._track("tungstenClosureMemo1")
        evaluate(
            parse_input_form(
                "tungstenClosureMemo1 = Module[{cache, fib}, "
                "cache = <||>; "
                "fib[n_] := fib[n] = If[n < 2, n, fib[n - 1] + fib[n - 2]]; "
                "fib]"
            )
        )
        self.assertEqual(_full("tungstenClosureMemo1[10]"), "55")
        self.assertEqual(_full("tungstenClosureMemo1[20]"), "6765")

    def test_closure_with_function_capturing_module_local(self) -> None:
        # A ``Function`` returned from Module captures the local symbol;
        # each call mutates the same ``n$N`` because ``n`` was a Module
        # local, not a Function-bound parameter.
        self._track("tungstenClosureCounter1")
        evaluate(
            parse_input_form(
                "tungstenClosureCounter1 = Module[{n = 0}, "
                "Function[{}, n = n + 1; n]]"
            )
        )
        self.assertEqual(
            _full(
                "{tungstenClosureCounter1[], "
                "tungstenClosureCounter1[], "
                "tungstenClosureCounter1[]}"
            ),
            "List[1, 2, 3]",
        )

    def test_two_independent_closures_do_not_share_state(self) -> None:
        # Each Module call gets its own fresh ``f$N`` so the two closures
        # have completely separate DownValue tables.
        self._track("tungstenClosureA1", "tungstenClosureA2")
        evaluate(
            parse_input_form(
                "tungstenClosureA1 = Module[{f}, f[x_] := x + 1; f]"
            )
        )
        evaluate(
            parse_input_form(
                "tungstenClosureA2 = Module[{f}, f[x_] := x * 2; f]"
            )
        )
        self.assertEqual(
            _full("{tungstenClosureA1[5], tungstenClosureA2[5]}"),
            "List[6, 10]",
        )

    def test_immediate_call_inside_module_body(self) -> None:
        # The closure pattern still works when the function is called
        # directly inside the Module body rather than escaping outward.
        # ``f[0] := 1; f[n_] := n + f[n - 1]`` gives
        # ``f[n] = 1 + Sum[k, {k, 1, n}] = 1 + n(n+1)/2`` -> 56 at n=10.
        self.assertEqual(
            _full("Module[{f}, f[0] := 1; f[n_] := n + f[n - 1]; f[10]]"),
            "56",
        )

    def test_closure_with_multiple_arguments(self) -> None:
        self._track("tungstenClosureBin1")
        evaluate(
            parse_input_form(
                "tungstenClosureBin1 = Module[{f}, f[x_, y_] := x + y; f]"
            )
        )
        self.assertEqual(_full("tungstenClosureBin1[3, 4]"), "7")
        self.assertEqual(
            _full("tungstenClosureBin1[a, b]"),
            "Plus[a, b]",
        )


if __name__ == "__main__":
    unittest.main()
