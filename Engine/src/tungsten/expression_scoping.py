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
    """Stub for the upcoming ``With[bindings, body]`` implementation.

    The dispatch entry point is wired so future work can fill in
    ``_apply_with_substitution`` and the existing call sites — both the
    standard ``With[...]`` form and any internal helpers that need
    lexical substitution — won't need to change.
    """
    return _emit_unsupported_scoping("With", arguments, plural="bindings")


def module_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Stub for the upcoming ``Module[locals, body]`` implementation.

    ``Module`` will use ``SymbolRegistry.unique_symbol`` (already shipped)
    to allocate the per-invocation fresh symbols, and the same
    capture-avoiding renaming pass already used for nested named pure
    functions to rewrite ``body`` accordingly.
    """
    return _emit_unsupported_scoping("Module", arguments, plural="locals")


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
