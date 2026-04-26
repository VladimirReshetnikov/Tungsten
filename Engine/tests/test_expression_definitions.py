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
        self.x = f"tungstenX{suffix}"
        self.y = f"tungstenY{suffix}"
        for name in (self.f, self.g, self.x, self.y):
            evaluate(parse_input_form(f"ClearAll[{name}]"))

    def tearDown(self) -> None:
        for name in (self.f, self.g, self.x, self.y):
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

    def test_compound_unset_removes_matching_definition(self) -> None:
        evaluate(parse_input_form(f"{self.f}[1] = 10"))
        evaluate(parse_input_form(f"{self.f}[1] =."))
        self.assertEqual(_full(f"{self.f}[1]"), f"{self.f}[1]")
        self.assertEqual(_full(f"DownValues[{self.f}]"), "List[]")

    def test_value_q_recognizes_compound_definitions(self) -> None:
        evaluate(parse_input_form(f"{self.f}[{self.x}_] := {self.x}"))
        self.assertEqual(_full(f"ValueQ[{self.f}[2]]"), "True")
        self.assertEqual(_full(f"ValueQ[{self.g}[2]]"), "False")


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
    """With / Module / Block emit a clear not-yet-supported message and
    return the inert call. This is the scaffolding for the upcoming
    scoping pass; the messages let callers see exactly what they tried to
    do."""

    def test_with_returns_inert_form(self) -> None:
        # The current stub leaves the call inert; the message is recorded
        # but the test asserts on the structural shape only.
        self.assertEqual(
            _full("With[{x = 5}, x + 1]"),
            "With[List[Set[x, 5]], Plus[x, 1]]",
        )

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


if __name__ == "__main__":
    unittest.main()
