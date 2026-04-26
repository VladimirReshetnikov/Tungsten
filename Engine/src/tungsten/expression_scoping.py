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
        # ``Module[{}, body]`` is just ``body``.
        return evaluate(body)

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
    return evaluate(renamed_body)


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
    """Stub for the upcoming ``Block[locals, body]`` implementation.

    ``Block`` will rely on a context manager that saves the current
    ``own_value`` and ``own_values_definitions`` of each named symbol
    (and registry attributes that the body might mutate) before evaluating
    ``body``, and restores them on any exit path.
    """
    return _emit_unsupported_scoping("Block", arguments, plural="locals")


def _emit_unsupported_scoping(
    head_name: str,
    arguments: Sequence["Expr"],
    *,
    plural: str,
) -> "Expr":
    from .expression import call, emit_message, string, symbol

    emit_message(
        call("MessageName", symbol(head_name), string("nyet")),
        f"{head_name} with explicit {plural} is not implemented yet in this Tungsten subset.",
    )
    return call(head_name, *arguments)


__all__ = [
    "block_expr",
    "module_expr",
    "with_expr",
]
