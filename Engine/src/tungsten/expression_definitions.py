"""Symbol-definition storage and Set / SetDelayed / Unset / Clear support.

This module is the home for everything related to how ``SymbolRecord`` stores
user-defined rules — own-values, down-values, up-values, sub-values — and the
public Set / SetDelayed / Unset / Clear / OwnValues / DownValues / UpValues /
SubValues / Definition surface that consumes that storage.

The current Tungsten subset keeps the *bare-symbol* own-value path that the
2026-04-23 review pass already shipped and extends the same storage model to
ordinary compound left-hand sides. The remaining nearby work is:

1. ``UpSet`` / ``UpSetDelayed`` / ``TagSet`` / ``TagSetDelayed`` writing to
   UpValues and SubValues respectively.
2. Non-read-only ``OwnValues``, ``DownValues``, ``UpValues``, ``SubValues``
   getters and assignment forms (e.g., ``DownValues[f] = {...}``).
3. ``Definition[sym]`` and the related introspection surface.

The design contract this module commits to up front:

- All stored rules are uniform ``Definition`` records: ``hold_pattern`` (a
  ``HoldPattern[...]`` wrapper around the LHS), ``rhs`` (the body), and
  ``delayed`` (a flag distinguishing ``Set`` from ``SetDelayed``).
- ``SymbolRecord.own_values_definitions`` and the analogous ``down``,
  ``up``, ``sub`` lists are *ordered* lists. Tungsten preserves assignment
  order except for the obvious Wolfram-style specificity case where a newly
  assigned literal rule, such as ``f[1]``, must be tried before an existing
  generic pattern rule such as ``f[x_]``.
- The shape of each rule is independent of the evaluator code that consumes
  it. The evaluator iterates the list and attempts to match each pattern
  using the existing ``tungsten.expression_patterns`` machinery.

This module exposes the API seam (``assign_definition``,
``definitions_for_kind``, ``clear_definitions``) so that assignment dispatch,
value-list readers, and pattern-matched evaluation all talk to the storage
through a single contract regardless of the value kind.

Importantly: this module re-exports the existing bare-symbol Set / Unset /
Clear / OwnValues path verbatim from ``tungsten.expression`` so the
established behavior is unchanged. The new ``Definition`` shape and routing
helpers are *additive*: they sit alongside the existing
``record.own_value`` slot and reflect into it for now. Once the remaining
scoping and value-list assignment work is complete, the legacy single-slot
field can be retired and the routing helpers can become the canonical write
path for own values too.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Iterable, Sequence

if TYPE_CHECKING:
    from .expression import Expr, SymbolRecord


VALUE_KIND_OWN = "OwnValues"
VALUE_KIND_DOWN = "DownValues"
VALUE_KIND_UP = "UpValues"
VALUE_KIND_SUB = "SubValues"
VALUE_KIND_N = "NValues"

ALL_VALUE_KINDS: tuple[str, ...] = (
    VALUE_KIND_OWN,
    VALUE_KIND_DOWN,
    VALUE_KIND_UP,
    VALUE_KIND_SUB,
    VALUE_KIND_N,
)


@dataclass
class Definition:
    """A single rule attached to a symbol.

    ``hold_pattern`` is the pattern the rule matches against, wrapped in
    ``HoldPattern[...]`` exactly as Wolfram's stored ``DownValues`` entries
    are. ``rhs`` is the right-hand side as the user wrote it. ``delayed``
    distinguishes ``SetDelayed`` rules (``:=``) — whose RHS is held until
    the rule fires — from ``Set`` rules (``=``) — whose RHS was already
    evaluated when the assignment was made.

    The optional ``condition`` field carries a top-level ``/;`` guard that
    was peeled off the LHS during assignment. The pattern-matched evaluator
    will check it after the body bindings have been resolved.

    Equality and hashing intentionally rely on the structural identity of
    the underlying expressions, so duplicate-rule detection is uniform with
    the rest of Tungsten's AST manipulation.
    """

    hold_pattern: "Expr"
    rhs: "Expr"
    delayed: bool
    condition: "Expr | None" = None
    metadata: dict[str, object] = field(default_factory=dict)

    def to_rule_expr(self) -> "Expr":
        """Render the definition as ``HoldPattern[lhs] :> rhs``.

        Wolfram's ``OwnValues`` / ``DownValues`` / ``UpValues`` /
        ``SubValues`` always present stored rules in delayed form
        regardless of whether the original assignment was ``Set`` or
        ``SetDelayed``; the ``delayed`` flag on the ``Definition`` is kept
        as evaluator metadata so pattern-matched definition dispatch can
        decide whether to re-evaluate the RHS at application time.
        """
        from .expression import call

        if self.condition is None:
            return call("RuleDelayed", self.hold_pattern, self.rhs)
        return call(
            "RuleDelayed",
            self.hold_pattern,
            call("Condition", self.rhs, self.condition),
        )


def definitions_for_kind(record: "SymbolRecord", kind: str) -> list[Definition]:
    """Return the ordered list of definitions of a given kind.

    The returned list is the live storage list; callers that mutate it are
    expected to know what they're doing. For read-only consumers,
    ``list(...)`` first or call :func:`rules_for_kind` to get rule
    expressions instead.

    For the legacy single-slot ``own_value`` path, this synthesizes a
    one-element list from the stored ``own_value`` so the new contract
    presents a uniform view. Future writes through
    :func:`assign_definition` will populate the canonical
    ``own_values_definitions`` list directly.
    """
    if kind not in ALL_VALUE_KINDS:
        raise ValueError(f"Unknown value kind: {kind!r}")
    return record.definitions_for_kind(kind)


def rules_for_kind(record: "SymbolRecord", kind: str) -> list["Expr"]:
    """Return rule expressions for the given value kind, mirroring what
    ``OwnValues[sym]`` / ``DownValues[sym]`` / etc. should return."""
    return [definition.to_rule_expr() for definition in definitions_for_kind(record, kind)]


def assign_definition(
    record: "SymbolRecord",
    *,
    kind: str,
    hold_pattern: "Expr",
    rhs: "Expr",
    delayed: bool,
    condition: "Expr | None" = None,
) -> Definition:
    """Append (or replace, for existing identical patterns) a definition.

    The contract this commits to is "kernel-style first match wins": when a
    definition with a structurally identical ``hold_pattern`` already
    exists, the new definition replaces it in place. Otherwise the new
    definition is inserted before the first existing definition that is
    clearly more general, and appended when the ordering is ambiguous. This
    mirrors the Wolfram principle that exact special cases should not be
    shadowed by earlier generic pattern definitions.
    """
    if kind not in ALL_VALUE_KINDS:
        raise ValueError(f"Unknown value kind: {kind!r}")
    definitions = record.definitions_for_kind(kind)
    new_definition = Definition(
        hold_pattern=hold_pattern,
        rhs=rhs,
        delayed=delayed,
        condition=condition,
    )
    for index, existing in enumerate(definitions):
        if existing.hold_pattern == hold_pattern:
            definitions[index] = new_definition
            return new_definition
    new_score = _definition_specificity_score(hold_pattern)
    for index, existing in enumerate(definitions):
        if new_score < _definition_specificity_score(existing.hold_pattern):
            definitions.insert(index, new_definition)
            return new_definition
    definitions.append(new_definition)
    return new_definition


def _definition_specificity_score(expr: "Expr") -> int:
    """Return a small heuristic score where lower means more specific.

    The full Wolfram definition-ordering algorithm is intentionally not
    replicated here. The evaluator only needs the common and important case:
    literal definitions should precede definitions containing blanks or other
    broad pattern constructs. Equal scores keep user assignment order.
    """
    from .expression import Call, Symbol

    if not isinstance(expr, Call):
        return 0
    head_name = expr.head_expr.name if isinstance(expr.head_expr, Symbol) else None
    if head_name == "HoldPattern" and len(expr.arguments) == 1:
        return _definition_specificity_score(expr.arguments[0])
    if head_name == "Pattern" and len(expr.arguments) == 2:
        return _definition_specificity_score(expr.arguments[1])
    if head_name == "Blank":
        return 12 if expr.arguments else 20
    if head_name == "BlankSequence":
        return 30 + sum(_definition_specificity_score(argument) for argument in expr.arguments)
    if head_name == "BlankNullSequence":
        return 35 + sum(_definition_specificity_score(argument) for argument in expr.arguments)
    if head_name == "Condition" and len(expr.arguments) == 2:
        return 2 + _definition_specificity_score(expr.arguments[0])
    if head_name == "PatternTest" and len(expr.arguments) == 2:
        return 3 + _definition_specificity_score(expr.arguments[0])
    if head_name == "Optional" and expr.arguments:
        return 5 + _definition_specificity_score(expr.arguments[0])
    if head_name == "Alternatives":
        return 4 + min(
            (_definition_specificity_score(argument) for argument in expr.arguments),
            default=0,
        )
    if head_name in {"Repeated", "RepeatedNull"} and expr.arguments:
        return 25 + _definition_specificity_score(expr.arguments[0])
    return sum(_definition_specificity_score(argument) for argument in expr.arguments)


def clear_definitions(record: "SymbolRecord", kinds: Iterable[str] | None = None) -> None:
    """Remove all definitions of the requested kinds (default: all four)."""
    target_kinds = tuple(kinds) if kinds is not None else ALL_VALUE_KINDS
    for kind in target_kinds:
        if kind not in ALL_VALUE_KINDS:
            raise ValueError(f"Unknown value kind: {kind!r}")
        record.definitions_for_kind(kind).clear()


def remove_definition(
    record: "SymbolRecord", kind: str, hold_pattern: "Expr"
) -> bool:
    """Remove the first definition with a structurally identical
    ``hold_pattern``. Returns True iff something was removed.
    """
    if kind not in ALL_VALUE_KINDS:
        raise ValueError(f"Unknown value kind: {kind!r}")
    definitions = record.definitions_for_kind(kind)
    for index, existing in enumerate(definitions):
        if existing.hold_pattern == hold_pattern:
            del definitions[index]
            return True
    return False


def classify_assignment_lhs(lhs: "Expr") -> tuple[str, "Expr | None"]:
    """Classify the left-hand side of a ``Set`` / ``SetDelayed`` assignment.

    Returns a ``(value_kind, target_symbol)`` pair where:

    - ``value_kind`` is one of the ``VALUE_KIND_*`` constants.
    - ``target_symbol`` is the symbol whose value list will receive the
      rule, or ``None`` when the LHS is malformed for a definition.

    The current implementation supports three value kinds:

    - ``OwnValues`` — bare symbol LHS.
    - ``DownValues`` — LHS of the form ``f[args...]`` where ``f`` is a
      symbol.
    - ``SubValues`` — curried LHS of the form ``f[args...][more...]``.

    Other LHS shapes (TagSet, UpSet, etc.) are surfaced through this same
    classifier so future passes can extend routing in one place.
    """
    from .expression import Call, Symbol

    if (
        isinstance(lhs, Call)
        and isinstance(lhs.head_expr, Symbol)
        and lhs.head_expr.name in {"Condition", "HoldPattern"}
        and lhs.arguments
    ):
        return classify_assignment_lhs(lhs.arguments[0])

    if isinstance(lhs, Symbol):
        return VALUE_KIND_OWN, lhs

    if isinstance(lhs, Call):
        head = lhs.head_expr
        if isinstance(head, Symbol):
            return VALUE_KIND_DOWN, head
        if isinstance(head, Call) and isinstance(head.head_expr, Symbol):
            # ``f[x_][y_] := ...`` writes a SubValues rule on ``f``.
            return VALUE_KIND_SUB, head.head_expr

    return VALUE_KIND_OWN, None


def coalesce_legacy_own_value(record: "SymbolRecord") -> None:
    """Ensure the legacy single-slot ``own_value`` reflects the canonical
    ordered list, and vice versa. Called from SymbolRegistry on writes to
    keep both views in sync until the legacy slot is retired.

    The contract: if ``own_values_definitions`` is non-empty, the legacy
    slot mirrors the *last* entry's RHS; if it is empty but the legacy
    slot has a value, the canonical list is hydrated with a one-element
    entry whose pattern is ``HoldPattern[sym]``.
    """
    from .expression import _SYMBOL_REGISTRY, call

    definitions = record.definitions_for_kind(VALUE_KIND_OWN)
    if definitions:
        record.own_value = definitions[-1].rhs
        return
    if record.own_value is not None:
        # Hydrate the canonical list from the legacy slot.
        display = _SYMBOL_REGISTRY.display_symbol_for_record(record)
        definitions.append(
            Definition(
                hold_pattern=call("HoldPattern", display),
                rhs=record.own_value,
                delayed=False,
            )
        )


__all__ = [
    "ALL_VALUE_KINDS",
    "Definition",
    "VALUE_KIND_DOWN",
    "VALUE_KIND_N",
    "VALUE_KIND_OWN",
    "VALUE_KIND_SUB",
    "VALUE_KIND_UP",
    "assign_definition",
    "classify_assignment_lhs",
    "clear_definitions",
    "coalesce_legacy_own_value",
    "definitions_for_kind",
    "remove_definition",
    "rules_for_kind",
]
