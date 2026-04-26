"""Symbol-definition storage and Set / SetDelayed / Unset / Clear scaffolding.

This module is the home for everything related to how ``SymbolRecord`` stores
user-defined rules — own-values, down-values, up-values, sub-values — and the
public Set / SetDelayed / Unset / Clear / OwnValues / DownValues / UpValues /
SubValues / Definition surface that consumes that storage.

The current Tungsten subset keeps the *bare-symbol* own-value path that the
2026-04-23 review pass already shipped. The work that this module is being
prepared for is:

1. ``Set[lhs, rhs]`` and ``SetDelayed[lhs, rhs]`` (``:=``) for compound
   left-hand sides such as ``f[x_]``, ``g[1]``, ``h[x_, y_] /; condition``,
   including multi-equation function definitions (multiple ``f[...] := ...``
   statements that accumulate as DownValues entries).
2. ``UpSet`` / ``UpSetDelayed`` / ``TagSet`` / ``TagSetDelayed`` writing to
   UpValues and SubValues respectively.
3. Non-read-only ``OwnValues``, ``DownValues``, ``UpValues``, ``SubValues``
   getters and assignment forms (e.g., ``DownValues[f] = {...}``).
4. ``Definition[sym]`` and the related introspection surface.

The design contract this module commits to up front:

- All stored rules are uniform ``Definition`` records: ``hold_pattern`` (a
  ``HoldPattern[...]`` wrapper around the LHS), ``rhs`` (the body), and
  ``delayed`` (a flag distinguishing ``Set`` from ``SetDelayed``).
- ``SymbolRecord.own_values_definitions`` and the analogous ``down``,
  ``up``, ``sub`` lists are *ordered* lists. The order is the order in which
  rules were assigned; the kernel uses this same order to choose which rule
  to apply.
- The shape of each rule is independent of the eventual rewriter that
  consumes it. The rewriter — when it lands — will iterate the list and
  attempt to match each pattern using the existing
  ``tungsten.expression_patterns`` machinery.

Until the compound-LHS implementation lands, this module exposes the API
seam (``assign_definition``, ``definitions_for_kind``, ``clear_definitions``)
so that the dispatch in ``tungsten.expression_evaluator`` and the eventual
pattern-matched evaluation step can talk to the storage through a single
contract regardless of the value kind.

Importantly: this module re-exports the existing bare-symbol Set / Unset /
Clear / OwnValues path verbatim from ``tungsten.expression`` so the
established behavior is unchanged. The new ``Definition`` shape and routing
helpers are *additive*: they sit alongside the existing
``record.own_value`` slot and reflect into it for now. When the compound-LHS
implementation lands, the legacy single-slot field can be retired and the
routing helpers become the canonical write path.
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
        only as metadata so the upcoming pattern-matched evaluator can
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
    exists, the new definition replaces it in place; otherwise the new
    definition is appended to the end of the list. This matches Wolfram's
    practical behavior for re-assigning the same rule.
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
    definitions.append(new_definition)
    return new_definition


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

    The current implementation supports two value kinds:

    - ``OwnValues`` — bare symbol LHS. This is the only kind currently
      written by the shipped Set / SetDelayed dispatch.
    - ``DownValues`` — LHS of the form ``f[args...]`` where ``f`` is a
      symbol and at least one argument is non-trivial; this case is
      *recognized* for routing but the actual rule storage is still
      handled out-of-band by the upcoming compound-LHS pass. Until then
      the dispatch raises a clear "not yet supported" error.

    Other LHS shapes (TagSet, UpSet, SubValues via ``f[x_][y_]``, etc.) are
    surfaced through this same classifier so the upcoming pass can extend
    routing in one place.
    """
    from .expression import Call, Symbol

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
