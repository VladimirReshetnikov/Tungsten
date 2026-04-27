"""Iteration constructs ``Table``, ``Do``, ``Sum``, and ``Product``.

All four heads use Wolfram's standard iterator-spec vocabulary:

- ``n`` (or ``{n}``) — iterate ``n`` times with no iteration variable;
- ``{i, n}`` — ``i`` takes integer values ``1, 2, …, n``;
- ``{i, imin, imax}`` — ``i`` takes integer/rational/real values from
  ``imin`` to ``imax`` inclusive in steps of ``1``;
- ``{i, imin, imax, di}`` — same with explicit step ``di``;
- ``{i, list}`` — ``i`` takes the values from the explicit list.

``Sum`` and ``Product`` reject the bare-integer ``n`` form; the kernel
keeps ``Sum[a, 3]`` inert and only accepts the List-form
specifications, so Tungsten enforces the same discipline.

Multiple iterators nest; later iterators can depend on earlier
iteration variables (``Table[expr, {i, 3}, {j, i}]`` evaluates ``j`` 's
upper bound with ``i`` already bound to its current value).

The iteration variable is **Block-scoped**: Tungsten snapshots the
symbol's complete value state at entry, sets the iteration variable on
each iteration, and restores the snapshot on exit through Python
``try`` / ``finally`` so the restore survives non-local control flow
(``Throw`` / ``Abort`` / ``Confirm`` / time-constraint expirations).

``Table`` collects the iteration values into nested ``List`` results;
``Do`` evaluates the body for side effects only and returns ``Null``;
``Sum`` and ``Product`` evaluate the body once per (Block-scoped)
binding combination, collect each evaluated body in a flat list, and
fold the list with ``Plus`` (Sum, identity ``0``) or ``Times``
(Product, identity ``1``) so symbolic bodies like ``Sum[a, {3}]`` reduce
to ``Times[3, a]`` and rational/real bounds promote naturally.

The iterator-spec evaluation reuses Tungsten's existing numeric helpers
(``_compare_real_expr``, ``_add_numeric_expr``) so Integer, Rational,
and Real bounds and steps all promote correctly. An iteration safety
cap (``_ITERATION_SAFETY_LIMIT``) guards against accidental infinite
loops from incompatible bounds and steps.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Sequence

if TYPE_CHECKING:
    from .expression import Expr, Symbol


def table_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Table[body, iter1, iter2, …]``.

    Uses Block-like save-and-restore scoping for each iterator variable.
    Multiple iterators nest with the leftmost outermost; later iterators
    may depend on earlier iteration variables because each iter spec is
    resolved in the scope where its outer iterators are already bound.
    """
    from .expression import WolframEvaluationError

    if len(arguments) < 2:
        raise WolframEvaluationError(
            "Table expects a body and at least one iterator specification."
        )
    body = arguments[0]
    iter_specs = arguments[1:]
    return _table_loop(body, iter_specs)


def do_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Do[body, iter1, iter2, …]`` for side effects.

    Returns ``Null`` after every iteration completes. ``Throw`` and
    other non-local control flow propagate through Do (the variable
    save/restore happens in a ``try`` / ``finally``).
    """
    from .expression import WolframEvaluationError, symbol

    if len(arguments) < 2:
        raise WolframEvaluationError(
            "Do expects a body and at least one iterator specification."
        )
    body = arguments[0]
    iter_specs = arguments[1:]
    _do_loop(body, iter_specs)
    return symbol("Null")


def sum_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Sum[body, iter1, iter2, …]``.

    Walks the iterator nesting in Block-scoped fashion (each iterator
    variable is snapshotted/restored exactly like ``Table``/``Do``),
    collects every evaluated body into a flat list, and folds the list
    through ``Plus`` once at the end. ``Plus[]`` is ``0`` so an empty
    iteration range yields ``0``, matching the kernel.
    """
    return _accumulate_expr("Sum", "Plus", arguments)


def product_expr(arguments: Sequence["Expr"]) -> "Expr":
    """Evaluate ``Product[body, iter1, iter2, …]``.

    Same Block-scoped iteration walk as ``Sum`` but folds the collected
    bodies through ``Times`` so ``Product[a, {3}]`` reduces to
    ``Power[a, 3]``. ``Times[]`` is ``1`` so an empty iteration range
    yields ``1``, matching the kernel.
    """
    return _accumulate_expr("Product", "Times", arguments)


def _accumulate_expr(
    head_name: str,
    accumulator_head: str,
    arguments: Sequence["Expr"],
) -> "Expr":
    """Shared driver for ``Sum`` and ``Product``.

    The kernel rejects the bare-integer ``n`` form for these heads
    (``Sum[a, 3]`` stays inert while ``Sum[a, {3}]`` evaluates), so
    every iter spec must be a ``List`` call. When the spec or body
    cannot be reduced (symbolic bounds, non-numeric step), the
    ``WolframEvaluationError`` propagates and the top-level evaluator
    catches it and returns the original expression unchanged.
    """
    from .expression import Call, WolframEvaluationError, call, evaluate

    if len(arguments) < 2:
        raise WolframEvaluationError(
            f"{head_name} expects a body and at least one iterator specification."
        )
    body = arguments[0]
    iter_specs = arguments[1:]
    for spec in iter_specs:
        if not (isinstance(spec, Call) and spec.has_head("List")):
            raise WolframEvaluationError(
                f"{head_name} iterator specification must be a List."
            )
    terms: list["Expr"] = []
    _accumulate_loop(body, iter_specs, terms)
    return evaluate(call(accumulator_head, *terms))


def _accumulate_loop(
    body: "Expr",
    iter_specs: Sequence["Expr"],
    terms: list["Expr"],
) -> None:
    """Walk iterator nesting, evaluating ``body`` once per (Block-scoped)
    binding combination and appending the result to ``terms``.

    ``Sum`` and ``Product`` differ only in how the collected term list
    is folded at the end, so they share this walk verbatim.
    """
    from .expression import evaluate

    if not iter_specs:
        terms.append(evaluate(body))
        return

    spec = iter_specs[0]
    rest_specs = iter_specs[1:]
    var_symbol, values = _resolve_iter_spec(spec)

    if var_symbol is None:
        for _ in range(len(values)):
            _accumulate_loop(body, rest_specs, terms)
        return

    _iterate_with_block_scope(
        var_symbol,
        values,
        lambda: _accumulate_loop(body, rest_specs, terms),
    )


def _table_loop(body: "Expr", iter_specs: Sequence["Expr"]) -> "Expr":
    from .expression import _evaluated_list_expr, evaluate

    if not iter_specs:
        return evaluate(body)

    spec = iter_specs[0]
    rest_specs = iter_specs[1:]
    var_symbol, values = _resolve_iter_spec(spec)

    if var_symbol is None:
        return _evaluated_list_expr(
            *(_table_loop(body, rest_specs) for _ in range(len(values)))
        )

    results: list["Expr"] = []
    _iterate_with_block_scope(
        var_symbol,
        values,
        lambda: results.append(_table_loop(body, rest_specs)),
    )
    return _evaluated_list_expr(*results)


def _do_loop(body: "Expr", iter_specs: Sequence["Expr"]) -> None:
    from .expression import evaluate

    if not iter_specs:
        evaluate(body)
        return

    spec = iter_specs[0]
    rest_specs = iter_specs[1:]
    var_symbol, values = _resolve_iter_spec(spec)

    if var_symbol is None:
        for _ in range(len(values)):
            _do_loop(body, rest_specs)
        return

    _iterate_with_block_scope(
        var_symbol,
        values,
        lambda: _do_loop(body, rest_specs),
    )


def _iterate_with_block_scope(
    var_symbol: "Symbol",
    values: Sequence["Expr"],
    step: "callable[[], None]",
) -> None:
    """Run ``step()`` once per ``values`` entry with ``var_symbol``
    Block-scoped to the current value.

    ``var_symbol``'s prior state (own value plus every canonical
    value-list slot) is snapshotted at entry and restored on exit.
    The restore is exception-safe so non-local control flow still
    reverts the iteration variable to its outer state.
    """
    from .expression import _SYMBOL_REGISTRY, _refresh_canonical_own_values
    from .expression_scoping import _restore_record_values, _snapshot_record_values

    record = _SYMBOL_REGISTRY.record_for_symbol(var_symbol)
    snapshot = _snapshot_record_values(record)
    try:
        for value in values:
            record.own_value = value
            _refresh_canonical_own_values(record)
            step()
    finally:
        _restore_record_values(record, snapshot)


def _resolve_iter_spec(
    spec: "Expr",
) -> tuple["Symbol | None", list["Expr"]]:
    """Validate and expand one iterator specification.

    Returns ``(iter_var_or_None, value_list)``. When the spec carries
    no iteration variable (``n`` or ``{n}`` form), the first element is
    ``None`` and the value list is a list of placeholder ``Expr`` s of
    the right length — only its length matters in that case.

    All bounds and step expressions are evaluated in the current scope
    so dependent iter specs (``{j, i}`` after ``{i, …}``) see the
    outer iterator's current binding.
    """
    from .expression import (
        Call,
        Integer,
        Symbol,
        WolframEvaluationError,
        evaluate,
        integer,
    )

    if isinstance(spec, Integer):
        count = max(spec.value, 0)
        return None, [integer(0)] * count

    if not (isinstance(spec, Call) and spec.has_head("List")):
        # Allow {n} / {i, ...} only; anything else is an error or an
        # evaluated count we can re-check.
        evaluated = evaluate(spec)
        if isinstance(evaluated, Integer):
            count = max(evaluated.value, 0)
            return None, [integer(0)] * count
        raise WolframEvaluationError(
            "Iterator specification must be an integer count or a List "
            "{n}, {i, n}, {i, imin, imax}, {i, imin, imax, di}, or {i, list}."
        )

    spec_args = spec.arguments
    if len(spec_args) == 0:
        raise WolframEvaluationError(
            "Iterator specification list cannot be empty."
        )

    if len(spec_args) == 1:
        # {n} — no variable, iterate n times.
        evaluated = evaluate(spec_args[0])
        if not isinstance(evaluated, Integer):
            raise WolframEvaluationError(
                "Iterator count must evaluate to an explicit integer."
            )
        count = max(evaluated.value, 0)
        return None, [integer(0)] * count

    var_expr = spec_args[0]
    if not isinstance(var_expr, Symbol):
        raise WolframEvaluationError(
            "Iterator variable must be a bare symbol."
        )

    rest = spec_args[1:]
    if len(rest) == 1:
        bound_or_list = evaluate(rest[0])
        if isinstance(bound_or_list, Call) and bound_or_list.has_head("List"):
            return var_expr, list(bound_or_list.arguments)
        # ``{i, n}`` is shorthand for ``{i, 1, n, 1}``.
        return var_expr, _generate_numeric_iter_values(integer(1), bound_or_list, integer(1))

    if len(rest) == 2:
        imin = evaluate(rest[0])
        imax = evaluate(rest[1])
        return var_expr, _generate_numeric_iter_values(imin, imax, integer(1))

    if len(rest) == 3:
        imin = evaluate(rest[0])
        imax = evaluate(rest[1])
        di = evaluate(rest[2])
        return var_expr, _generate_numeric_iter_values(imin, imax, di)

    raise WolframEvaluationError(
        "Iterator specification supports up to four arguments "
        "({i}, {i, n}, {i, imin, imax}, {i, imin, imax, di})."
    )


def _generate_numeric_iter_values(
    start: "Expr",
    end: "Expr",
    step: "Expr",
) -> list["Expr"]:
    """Build the inclusive value list for ``{start, end, step}``.

    Both endpoints are inclusive; positive step generates ``start, start +
    step, …`` while ``current <= end``; negative step generates the
    descending sequence while ``current >= end``. An iteration safety
    cap stops infinite loops from pathological step/bound combinations
    rather than letting the process spin forever.
    """
    from .expression import (
        WolframEvaluationError,
        _add_numeric_expr,
        _compare_real_expr,
        _is_real_number_expr,
        _ITERATION_SAFETY_LIMIT,
        integer,
    )

    if not (
        _is_real_number_expr(start)
        and _is_real_number_expr(end)
        and _is_real_number_expr(step)
    ):
        raise WolframEvaluationError(
            "Iterator bounds and step must be explicit real-valued numbers."
        )

    step_sign = _compare_real_expr(step, integer(0))
    if step_sign is None or step_sign == 0:
        raise WolframEvaluationError("Iterator step must be a nonzero real number.")

    values: list["Expr"] = []
    current = start
    iteration_index = 0
    while True:
        comparison = _compare_real_expr(current, end)
        if comparison is None:
            raise WolframEvaluationError(
                "Iterator bounds were not comparable; expected real-valued numbers."
            )
        if (step_sign > 0 and comparison > 0) or (step_sign < 0 and comparison < 0):
            break
        values.append(current)
        iteration_index += 1
        if iteration_index > _ITERATION_SAFETY_LIMIT:
            raise WolframEvaluationError(
                "Iterator exceeded the Tungsten iteration safety limit."
            )
        next_value = _add_numeric_expr(current, step)
        if next_value is None:
            raise WolframEvaluationError(
                "Iterator step could not be applied to the current value."
            )
        current = next_value
    return values


__all__ = [
    "do_expr",
    "product_expr",
    "sum_expr",
    "table_expr",
]
