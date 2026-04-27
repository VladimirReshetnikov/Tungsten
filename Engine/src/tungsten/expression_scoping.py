"""Scoping constructs ``With``, ``Module``, and ``Block`` — scaffolding home.

This module is the planned home for Tungsten's lexical and dynamic scoping
constructs. It is currently a *scaffold*: the dispatch entry points exist
and emit a clear "not yet supported in this Tungsten subset" message
rather than silently leaving the call inert. The shape of this module is
deliberately written so the upcoming implementation can fill in the
``apply_*`` functions without rewiring callers in
``tungsten.expression_evaluator``.

The Wolfram contract that the upcoming pass needs to honor is:

- ``With[{x = e1, y = e2, ...}, body]`` evaluates each binding's RHS once,
  in left-to-right order, with ``x`` already bound to the prior bindings'
  values. The bindings act as a *substitution*: the resulting expression
  replaces every occurrence of ``x``, ``y``, etc. in ``body`` with their
  values, then evaluates the substituted body. ``With`` does **not**
  introduce a fresh symbol; it is a pure local rewrite.
- ``Module[{x, y = init, ...}, body]`` introduces fresh per-invocation
  symbols ``x$N``, ``y$N``, etc., binds the explicit initializers, then
  evaluates ``body`` using those fresh symbols. The fresh symbols are
  *visible* in the registry while the Module is active and are normally
  cleaned up (or left dangling for inspection) on exit. Lexical scope.
- ``Block[{x = init, ...}, body]`` saves the current ``OwnValues`` of each
  named symbol, sets them to the initializer (or removes them if no
  initializer is given), evaluates ``body`` under that environment, and
  restores the saved values when ``body`` returns — even on exceptional
  control flow. Dynamic scope.

The shared infrastructure each implementation needs:

- A symbol-renaming pass for ``Module`` that walks ``body`` and rewrites
  occurrences of bound names. This is the same alpha-renaming machinery
  already used for nested named pure functions (see
  ``docs/named-pure-functions-spec.md``).
- A scoped-state context manager for ``Block`` that saves/restores
  ``record.own_value`` and the canonical
  ``record.own_values_definitions`` list. The ``Block`` exit must be
  exception-safe; the same pattern applies to ``With`` for the
  pre-evaluation step.
- A pluggable substitution operation that ``With`` uses to inline
  bindings. ``With`` does not need a registry write; it is a pure rewrite
  on the body expression.

Until the implementation lands, calling any of these heads from Tungsten
emits a Tungsten message and returns an inert call so callers can see
exactly what they tried to do.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Sequence

if TYPE_CHECKING:
    from .expression import Expr


def with_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``With[bindings, body]``.

    The bindings list is a ``List`` whose entries are ``Set[name, value]``
    or ``SetDelayed[name, value]``. ``Set`` bindings evaluate their RHS
    once in the outer scope and then substitute the resulting value
    everywhere ``name`` appears free in ``body``; ``SetDelayed`` bindings
    substitute the *unevaluated* RHS, so each in-body occurrence is
    re-evaluated where it lands. Bindings are independent — the second
    binding's RHS does not see the first binding's value.

    Substitution is capture-avoiding through ``Function`` (named pure
    functions) and through nested ``With`` / ``Module`` / ``Block``
    constructs: inner-bound names that would shadow the substitution are
    alpha-renamed to fresh names if they collide with a free variable in
    the substituted value. The capture-avoidance is delegated to the
    shared ``tungsten.expression._substitute_named_symbols_in_expr`` pass
    so this implementation stays in lockstep with how ``Function``
    application substitutes its arguments.
    """
    from .expression import (
        Call,
        Symbol,
        WolframEvaluationError,
        _collect_symbol_names,
        _substitute_named_symbols_in_expr,
        evaluate,
    )

    if len(arguments) != 2:
        raise WolframEvaluationError(
            "With expects a list of bindings and a body."
        )
    bindings_expr, body = arguments

    if not (isinstance(bindings_expr, Call) and bindings_expr.has_head("List")):
        raise WolframEvaluationError(
            "With expects a List of bindings as its first argument."
        )

    if not bindings_expr.arguments:
        # ``With[{}, body]`` is just ``body``.
        return evaluate(body)

    substitutions: dict[str, "Expr"] = {}
    unavailable_names: set[str] = set()
    seen_names: set[str] = set()

    for binding in bindings_expr.arguments:
        name, value, delayed = _parse_with_binding(binding)
        if name.name in seen_names:
            raise WolframEvaluationError(
                f"With has duplicate binding for {name.name!r}."
            )
        seen_names.add(name.name)

        if delayed:
            stored_value = value
        else:
            stored_value = evaluate(value)

        substitutions[name.name] = stored_value
        unavailable_names.add(name.name)
        _collect_symbol_names(stored_value, unavailable_names)

    substituted_body, _changed = _substitute_named_symbols_in_expr(
        body, substitutions, unavailable_names
    )
    return evaluate(substituted_body)


def _parse_with_binding(binding: "Expr") -> tuple["Symbol", "Expr", bool]:
    """Validate and extract ``(name, value, delayed)`` from one With binding.

    Accepted shapes:

    - ``Set[name, value]`` (parser form ``name = value``) — eager.
    - ``SetDelayed[name, value]`` (parser form ``name := value``) — delayed.

    The bare-symbol "no init" shape that ``Module`` and ``Block`` accept
    is intentionally rejected for ``With``: the kernel requires an
    explicit initial value for every With binding.
    """
    from .expression import Call, Symbol, WolframEvaluationError

    if isinstance(binding, Call) and (binding.has_head("Set") or binding.has_head("SetDelayed")):
        if len(binding.arguments) != 2:
            raise WolframEvaluationError(
                "With binding requires exactly two arguments."
            )
        name = binding.arguments[0]
        value = binding.arguments[1]
        if not isinstance(name, Symbol):
            raise WolframEvaluationError(
                "With binding names must be bare symbols."
            )
        return name, value, binding.has_head("SetDelayed")

    raise WolframEvaluationError(
        "With expects bindings of the form name = value or name := value."
    )


def module_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Module[locals, body]`` with lexical scoping.

    Each local is renamed to a fresh symbol ``name$N`` (where ``N`` is a
    shared per-invocation counter taken from ``SymbolRegistry``); the
    fresh symbols are real registry entries that participate normally in
    ``OwnValues`` lookup so the body can mutate them via ``Set`` and
    inspect them via ``OwnValues``. The body is rewritten through the
    capture-avoiding rename helper so inner ``Function`` / ``With`` /
    ``Module`` / ``Block`` constructs continue to shield names that
    shadow Module's locals.

    Initializer semantics match the kernel: each binding's RHS is
    evaluated in the **outer scope** (without any of the Module's locals
    in effect), and the resulting value (for ``Set``) or the held form
    (for ``SetDelayed``) becomes the fresh symbol's own value. Bindings
    are therefore *independent* — the second binding's RHS does not see
    the first binding's value, mirroring Wolfram's
    ``Module[{x = 1, y = x + 1}, ...]`` -> ``y = (outer) x + 1``
    behavior.

    The fresh symbols persist in the registry after Module returns so
    closures over them keep working (``Module[{x = 5}, Function[y, x +
    y]]`` returns a usable function), matching the kernel.

    Allowed bindings:

    - bare ``Symbol`` (no initializer);
    - ``Set[name, value]`` (eager initializer);
    - ``SetDelayed[name, value]`` (delayed initializer).
    """
    from .expression import (
        Call,
        Symbol,
        WolframEvaluationError,
        _SYMBOL_REGISTRY,
        _refresh_canonical_own_values,
        _rename_bound_symbols_in_expr,
        evaluate,
    )

    if len(arguments) != 2:
        raise WolframEvaluationError(
            "Module expects a list of locals and a body."
        )
    bindings_expr, body = arguments

    if not (isinstance(bindings_expr, Call) and bindings_expr.has_head("List")):
        raise WolframEvaluationError(
            "Module expects a List of locals as its first argument."
        )

    if not bindings_expr.arguments:
        # ``Module[{}, body]`` is just ``body``, but the empty-Module
        # call still defines a Return[expr, Module] catch boundary.
        from .expression import _TungstenReturnSignal

        try:
            return evaluate(body)
        except _TungstenReturnSignal as signal:
            if signal.head_name == "Module":
                return signal.value
            raise

    # Parse bindings. Each entry yields (Symbol name, value | None, delayed flag).
    parsed_bindings: list[tuple[Symbol, "Expr | None", bool]] = []
    seen_names: set[str] = set()
    for binding in bindings_expr.arguments:
        name, value, delayed = _parse_module_binding(binding)
        if name.name in seen_names:
            raise WolframEvaluationError(
                f"Module has duplicate binding for {name.name!r}."
            )
        seen_names.add(name.name)
        parsed_bindings.append((name, value, delayed))

    # Allocate the fresh per-invocation symbols with a shared counter
    # suffix so {x, y, z} become {x$N, y$N, z$N} for the same N.
    locals_in_order = tuple(name for name, _value, _delayed in parsed_bindings)
    fresh_symbols, fresh_records = _SYMBOL_REGISTRY.allocate_module_local_symbols(locals_in_order)

    # Build the rename map (original short name -> fresh display Symbol)
    # used both to install initializers (which can refer to other locals
    # from this Module's binding list — see the next paragraph) and to
    # rewrite the body.
    rename_map: dict[str, Symbol] = {
        name.name: fresh
        for (name, _value, _delayed), fresh in zip(parsed_bindings, fresh_symbols, strict=True)
    }

    # Install initializers. Each binding's RHS is evaluated in the
    # **outer scope**, *not* in a scope where prior locals are bound.
    # Wolfram's contract: ``Module[{x = 1, y = x + 1}, ...]`` ->
    # ``y = (outer x) + 1`` because each RHS is independent. So we do
    # NOT rename the RHS using the rename map.
    for (_name, value, delayed), fresh_record in zip(
        parsed_bindings, fresh_records, strict=True
    ):
        if value is None:
            continue
        if delayed:
            stored_value = value
        else:
            stored_value = evaluate(value)
        fresh_record.own_value = stored_value
        _refresh_canonical_own_values(fresh_record)
        if delayed and fresh_record.own_values_definitions:
            fresh_record.own_values_definitions[-1].delayed = True

    # Rewrite the body so every reference to a local name resolves to its
    # fresh symbol; capture-avoidance through inner ``Function`` / ``With``
    # / ``Module`` / ``Block`` is handled by the shared helper.
    renamed_body = _rename_bound_symbols_in_expr(body, rename_map)
    from .expression import _TungstenReturnSignal

    try:
        return evaluate(renamed_body)
    except _TungstenReturnSignal as signal:
        # ``Return[expr, Module]`` exits the nearest enclosing Module
        # call. Headed Returns targeting other heads, or bare
        # ``Return[expr]`` (which is caught at the function-definition
        # boundary instead), continue propagating outward.
        if signal.head_name == "Module":
            return signal.value
        raise


def _parse_module_binding(binding: "Expr") -> tuple["Symbol", "Expr | None", bool]:
    """Validate and extract one Module binding.

    Accepted shapes:

    - bare ``Symbol`` — no initializer; the local is allocated with no
      own value.
    - ``Set[name, value]`` (parser form ``name = value``) — eager
      initializer; the RHS is evaluated once in the outer scope and
      becomes the fresh symbol's own value.
    - ``SetDelayed[name, value]`` (parser form ``name := value``) —
      delayed initializer; the RHS is stored unevaluated and re-evaluates
      on each lookup.
    """
    from .expression import Call, Symbol, WolframEvaluationError

    if isinstance(binding, Symbol):
        return binding, None, False
    if isinstance(binding, Call) and (binding.has_head("Set") or binding.has_head("SetDelayed")):
        if len(binding.arguments) != 2:
            raise WolframEvaluationError(
                "Module binding requires exactly two arguments."
            )
        name = binding.arguments[0]
        value = binding.arguments[1]
        if not isinstance(name, Symbol):
            raise WolframEvaluationError(
                "Module binding names must be bare symbols."
            )
        return name, value, binding.has_head("SetDelayed")
    raise WolframEvaluationError(
        "Module bindings must be a bare symbol or name = value / name := value."
    )


def block_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Block[locals, body]`` with dynamic save-and-restore scoping.

    For each named local, Tungsten snapshots the symbol's complete value
    state (legacy ``own_value`` slot plus the canonical
    ``own_values_definitions``, ``down_values_definitions``,
    ``up_values_definitions``, ``sub_values_definitions``, and
    ``n_values_definitions`` lists) at entry, evaluates ``body``, and
    restores the snapshot on exit. The restore is exception-safe via
    Python ``try``/``finally`` so aborts, throws, and confirmations
    triggered inside the body still revert outer state.

    Bindings:

    - bare ``Symbol`` — save state, do not modify; the body sees the
      symbol's outer value, and any mutations during ``body`` are
      reverted on exit.
    - ``Set[name, value]`` — save state, set the symbol's own value to
      the (eagerly-evaluated) RHS; reverted on exit.
    - ``SetDelayed[name, value]`` — save state, set the symbol's own
      value to the (held) RHS so each lookup re-evaluates it; reverted
      on exit.

    Notable consequences confirmed against the live kernel:

    - Without an initializer, ``Block[{f}, f]`` returns the outer ``f``
      unchanged — Block does *not* clear values at entry, it only
      restores at exit.
    - With an initializer, ``Block[{f = 5}, f[1]]`` returns ``5[1]``:
      the OwnValue replaces the head dispatch so the symbol's existing
      DownValues are bypassed for the duration of the body.
    - DownValues / UpValues / SubValues additions inside the body are
      reverted on exit, so ``Block[{f}, f[1] = 100]`` does not leak.
    """
    return _block_implementation(arguments, head_name="Block")


def inherited_block_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Internal`InheritedBlock[locals, body]``.

    In modern Wolfram (14.x), ``Internal`InheritedBlock`` and ``Block``
    are functionally identical: both save the symbols' complete value
    state, optionally apply initializers, evaluate ``body``, and
    restore on exit. ``Block`` historically cleared values at entry
    while ``InheritedBlock`` did not; the cleared-at-entry behavior is
    no longer present in the kernel for either form, so Tungsten
    implements both via the same ``_block_implementation`` helper.

    The unqualified name ``InheritedBlock`` is accepted as an alias
    for ``Internal`InheritedBlock`` — Tungsten's evaluator dispatch
    matches on the short name regardless of context, mirroring the
    kernel's lookup behavior for both qualifiers.
    """
    return _block_implementation(arguments, head_name="InheritedBlock")


def _block_implementation(
    arguments: Sequence["Expr"],
    *,
    head_name: str,
) -> "Expr":
    from .expression import (
        Call,
        Symbol,
        WolframEvaluationError,
        _SYMBOL_REGISTRY,
        _refresh_canonical_own_values,
        evaluate,
    )

    if len(arguments) != 2:
        raise WolframEvaluationError(
            f"{head_name} expects a list of locals and a body."
        )
    bindings_expr, body = arguments

    if not (isinstance(bindings_expr, Call) and bindings_expr.has_head("List")):
        raise WolframEvaluationError(
            f"{head_name} expects a List of locals as its first argument."
        )

    if not bindings_expr.arguments:
        # Empty ``Block[{}, body]`` / ``InheritedBlock[{}, body]``
        # still defines a Return[expr, head_name] catch boundary.
        from .expression import _TungstenReturnSignal

        try:
            return evaluate(body)
        except _TungstenReturnSignal as signal:
            if signal.head_name == head_name:
                return signal.value
            raise

    # Parse bindings: bare Symbol | Set[name, value] | SetDelayed[name, value].
    parsed_bindings: list[tuple["Symbol", "Expr | None", bool]] = []
    seen_names: set[str] = set()
    for binding in bindings_expr.arguments:
        name, value, delayed = _parse_block_binding(binding, head_name)
        if name.name in seen_names:
            raise WolframEvaluationError(
                f"{head_name} has duplicate binding for {name.name!r}."
            )
        seen_names.add(name.name)
        parsed_bindings.append((name, value, delayed))

    # Snapshot every local's full value state.
    snapshots: list[tuple[object, dict[str, object]]] = []
    for name, _value, _delayed in parsed_bindings:
        record = _SYMBOL_REGISTRY.record_for_symbol(name)
        snapshots.append((record, _snapshot_record_values(record)))

    from .expression import _TungstenReturnSignal

    try:
        # Apply initializers. We bypass ``set_expr`` here because Block
        # is meant to override even Protected symbols (it's a save/
        # restore primitive, not a visible mutation), and we already
        # have the records resolved. ``_refresh_canonical_own_values``
        # keeps the canonical OwnValues list in sync with the legacy
        # slot so ``OwnValues[sym]`` reflects the active binding.
        for (_name, value, delayed), (record, _snapshot) in zip(
            parsed_bindings, snapshots, strict=True
        ):
            if value is None:
                continue
            if delayed:
                stored_value = value
            else:
                stored_value = evaluate(value)
            record.own_value = stored_value
            _refresh_canonical_own_values(record)
            if delayed and record.own_values_definitions:
                record.own_values_definitions[-1].delayed = True

        try:
            return evaluate(body)
        except _TungstenReturnSignal as signal:
            # ``Return[expr, Block]`` / ``Return[expr, InheritedBlock]``
            # exits the nearest enclosing Block-family call. Other
            # Returns continue propagating so the targeted head
            # upstream can catch them.
            if signal.head_name == head_name:
                return signal.value
            raise
    finally:
        for record, snapshot in snapshots:
            _restore_record_values(record, snapshot)


def _parse_block_binding(
    binding: "Expr",
    head_name: str,
) -> tuple["Symbol", "Expr | None", bool]:
    """Validate one Block / InheritedBlock binding and return its
    ``(name, value, delayed)`` triple. Bare-Symbol bindings carry a
    ``None`` value (no initializer)."""
    from .expression import Call, Symbol, WolframEvaluationError

    if isinstance(binding, Symbol):
        return binding, None, False
    if isinstance(binding, Call) and (binding.has_head("Set") or binding.has_head("SetDelayed")):
        if len(binding.arguments) != 2:
            raise WolframEvaluationError(
                f"{head_name} binding requires exactly two arguments."
            )
        name = binding.arguments[0]
        value = binding.arguments[1]
        if not isinstance(name, Symbol):
            raise WolframEvaluationError(
                f"{head_name} binding names must be bare symbols."
            )
        return name, value, binding.has_head("SetDelayed")
    raise WolframEvaluationError(
        f"{head_name} bindings must be a bare symbol or name = value / name := value."
    )


def _snapshot_record_values(record: object) -> dict[str, object]:
    """Capture the symbol's complete value state for save-and-restore.

    The snapshot covers the legacy single-slot ``own_value`` field plus
    every canonical ordered list (``own_values_definitions``,
    ``down_values_definitions``, ``up_values_definitions``,
    ``sub_values_definitions``, ``n_values_definitions``) and the older
    ``down_values`` / ``up_values`` / ``sub_values`` tuples. Lists are
    shallow-copied so callers can mutate the live storage without
    corrupting the snapshot.
    """
    return {
        "own_value": record.own_value,  # type: ignore[attr-defined]
        "own_values_definitions": list(record.own_values_definitions),  # type: ignore[attr-defined]
        "down_values_definitions": list(record.down_values_definitions),  # type: ignore[attr-defined]
        "up_values_definitions": list(record.up_values_definitions),  # type: ignore[attr-defined]
        "sub_values_definitions": list(record.sub_values_definitions),  # type: ignore[attr-defined]
        "n_values_definitions": list(record.n_values_definitions),  # type: ignore[attr-defined]
        "down_values": tuple(record.down_values),  # type: ignore[attr-defined]
        "up_values": tuple(record.up_values),  # type: ignore[attr-defined]
        "sub_values": tuple(record.sub_values),  # type: ignore[attr-defined]
    }


def _restore_record_values(record: object, snapshot: dict[str, object]) -> None:
    """Reinstate the snapshot taken by :func:`_snapshot_record_values`.

    The restore overwrites the live storage in place so external
    references to the SymbolRecord stay valid.
    """
    record.own_value = snapshot["own_value"]  # type: ignore[attr-defined]
    record.down_values = snapshot["down_values"]  # type: ignore[attr-defined]
    record.up_values = snapshot["up_values"]  # type: ignore[attr-defined]
    record.sub_values = snapshot["sub_values"]  # type: ignore[attr-defined]
    record.own_values_definitions[:] = snapshot["own_values_definitions"]  # type: ignore[attr-defined]
    record.down_values_definitions[:] = snapshot["down_values_definitions"]  # type: ignore[attr-defined]
    record.up_values_definitions[:] = snapshot["up_values_definitions"]  # type: ignore[attr-defined]
    record.sub_values_definitions[:] = snapshot["sub_values_definitions"]  # type: ignore[attr-defined]
    record.n_values_definitions[:] = snapshot["n_values_definitions"]  # type: ignore[attr-defined]


__all__ = [
    "block_expr",
    "inherited_block_expr",
    "module_expr",
    "with_expr",
]
