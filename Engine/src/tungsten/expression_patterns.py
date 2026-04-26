from __future__ import annotations

# Ordinary expression pattern matching and rewrite helpers extracted from
# tungsten.expression. String-pattern primitives intentionally remain in
# tungsten.expression for this pass because they have a separate text-matching
# implementation surface.
from . import expression as _runtime

globals().update(
    {name: getattr(_runtime, name) for name in dir(_runtime) if not name.startswith("__")}
)

def _unsupported_pattern(expr: Expr) -> WolframEvaluationError:
    return WolframEvaluationError(
        f"Unsupported Wolfram pattern form in the current Tungsten subset: {expr.to_input_form()}."
    )


_SEQUENCE_PATTERN_HEADS = {
    "BlankSequence",
    "BlankNullSequence",
    "Repeated",
    "RepeatedNull",
    "PatternSequence",
    "OrderlessPatternSequence",
    "OptionsPattern",
}


def _direct_sequence_pattern_head_name(expr: Expr) -> str | None:
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _SEQUENCE_PATTERN_HEADS:
        return expr.head_expr.name
    return None


def _is_sequence_argument_pattern(pattern: Expr) -> bool:
    if _direct_sequence_pattern_head_name(pattern) is not None:
        return True
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name
        if head_name == "Optional":
            return True
        if head_name in {"HoldPattern", "Condition", "PatternTest", "Longest", "Shortest"} and pattern.arguments:
            return _is_sequence_argument_pattern(pattern.arguments[0])
        if head_name == "Pattern" and len(pattern.arguments) == 2:
            return _is_sequence_argument_pattern(pattern.arguments[1])
        if head_name == "Alternatives":
            return any(_is_sequence_argument_pattern(argument) for argument in pattern.arguments)
    return False


def _normalize_repetition_bound(expr: Expr, function_name: str) -> int:
    if isinstance(expr, Integer):
        if expr.value < 0:
            raise WolframEvaluationError(f"{function_name} repetition bounds must be non-negative.")
        return expr.value
    if isinstance(expr, Symbol) and expr.name == "Infinity":
        return _LEVEL_INFINITY
    raise WolframEvaluationError(f"{function_name} expects integer repetition bounds or Infinity.")


def _repetition_count_bounds(pattern: Call) -> tuple[int, int]:
    head_name = pattern.head_expr.name if isinstance(pattern.head_expr, Symbol) else ""
    if head_name not in {"Repeated", "RepeatedNull"}:
        raise WolframEvaluationError(f"Expected Repeated or RepeatedNull, got {pattern.to_input_form()}.")
    if len(pattern.arguments) == 1:
        return (1 if head_name == "Repeated" else 0, _LEVEL_INFINITY)
    if len(pattern.arguments) != 2:
        raise WolframEvaluationError(f"{head_name} expects one or two arguments.")

    default_min = 1 if head_name == "Repeated" else 0
    spec = pattern.arguments[1]
    if isinstance(spec, (Integer, Symbol)):
        return (default_min, _normalize_repetition_bound(spec, head_name))
    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1:
            value = _normalize_repetition_bound(spec.arguments[0], head_name)
            return (value, value)
        if len(spec.arguments) == 2:
            low = _normalize_repetition_bound(spec.arguments[0], head_name)
            high = _normalize_repetition_bound(spec.arguments[1], head_name)
            return (low, high)
    raise WolframEvaluationError(f"Unsupported {head_name} repetition specification.")


def _pattern_width_bounds(pattern: Expr) -> tuple[int, int]:
    if _is_sequence_argument_pattern(pattern):
        return _sequence_pattern_length_bounds(pattern)
    return (1, 1)


def _add_width_bounds(bounds: Iterable[tuple[int, int]]) -> tuple[int, int]:
    minimum = 0
    maximum = 0
    for low, high in bounds:
        minimum += low
        if maximum >= _LEVEL_INFINITY or high >= _LEVEL_INFINITY:
            maximum = _LEVEL_INFINITY
        else:
            maximum += high
    return (minimum, maximum)


def _sequence_pattern_length_bounds(pattern: Expr) -> tuple[int, int]:
    head_name = _direct_sequence_pattern_head_name(pattern)
    if head_name == "BlankSequence":
        return (1, _LEVEL_INFINITY)
    if head_name == "BlankNullSequence":
        return (0, _LEVEL_INFINITY)
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        wrapper_name = pattern.head_expr.name
        if wrapper_name in {"HoldPattern", "Condition", "PatternTest", "Longest", "Shortest"} and pattern.arguments:
            return _sequence_pattern_length_bounds(pattern.arguments[0])
        if wrapper_name == "Pattern" and len(pattern.arguments) == 2:
            return _sequence_pattern_length_bounds(pattern.arguments[1])
        if wrapper_name == "Alternatives" and pattern.arguments:
            branch_bounds = [_pattern_width_bounds(argument) for argument in pattern.arguments]
            return (min(low for low, _high in branch_bounds), max(high for _low, high in branch_bounds))
        if wrapper_name == "Optional":
            if len(pattern.arguments) not in {1, 2}:
                raise WolframEvaluationError("Optional expects one or two arguments.")
            inner_low, inner_high = _pattern_width_bounds(pattern.arguments[0])
            return (0 if len(pattern.arguments) == 2 else inner_low, inner_high)
        if wrapper_name in {"Repeated", "RepeatedNull"}:
            item_low, item_high = _pattern_width_bounds(pattern.arguments[0])
            count_low, count_high = _repetition_count_bounds(pattern)
            minimum = item_low * count_low
            maximum = _LEVEL_INFINITY if item_high >= _LEVEL_INFINITY or count_high >= _LEVEL_INFINITY else item_high * count_high
            return (minimum, maximum)
        if wrapper_name in {"PatternSequence", "OrderlessPatternSequence"}:
            return _add_width_bounds(_pattern_width_bounds(argument) for argument in pattern.arguments)
        if wrapper_name == "OptionsPattern":
            if len(pattern.arguments) > 1:
                raise WolframEvaluationError("OptionsPattern expects zero or one argument.")
            return (0, _LEVEL_INFINITY)
    raise WolframEvaluationError(f"Expected a sequence pattern, got {pattern.to_input_form()}.")


def _sequence_pattern_min_length(pattern: Expr) -> int:
    return _sequence_pattern_length_bounds(pattern)[0]


def _minimum_argument_count(pattern_arguments: Sequence[Expr]) -> int:
    count = 0
    for pattern_argument in pattern_arguments:
        if _is_sequence_argument_pattern(pattern_argument):
            count += _sequence_pattern_min_length(pattern_argument)
        else:
            count += 1
    return count


def _sequence_binding_value(exprs: Sequence[Expr]) -> Expr:
    if len(exprs) == 1:
        return exprs[0]
    return call("Sequence", *exprs)


def _bind_pattern_name(bindings: dict[str, Expr], name: str, value: Expr) -> dict[str, Expr] | None:
    bound = bindings.get(name)
    if bound is not None:
        return bindings if bound == value else None
    matched = dict(bindings)
    matched[name] = value
    return matched


def _sequence_prefers_longest(pattern: Expr) -> bool:
    if not isinstance(pattern, Call) or not isinstance(pattern.head_expr, Symbol):
        return False
    head_name = pattern.head_expr.name
    if head_name == "Longest":
        return True
    if head_name == "Shortest":
        return False
    if head_name == "Optional" and len(pattern.arguments) == 2:
        return True
    if head_name in {"HoldPattern", "Condition", "PatternTest"} and pattern.arguments:
        return _sequence_prefers_longest(pattern.arguments[0])
    if head_name == "Pattern" and len(pattern.arguments) == 2:
        return _sequence_prefers_longest(pattern.arguments[1])
    return False


def _sequence_length_order(pattern: Expr, minimum: int, maximum: int) -> range:
    if _sequence_prefers_longest(pattern):
        return range(maximum, minimum - 1, -1)
    return range(minimum, maximum + 1)


def _bind_optional_default(pattern: Expr, default: Expr, bindings: dict[str, Expr]) -> dict[str, Expr] | None:
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name
        if head_name in {"HoldPattern", "Longest", "Shortest"} and pattern.arguments:
            return _bind_optional_default(pattern.arguments[0], default, bindings)
        if head_name == "PatternTest":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("PatternTest expects exactly two arguments.")
            matched = _bind_optional_default(pattern.arguments[0], default, bindings)
            if matched is None:
                return None
            return matched if _predicate_succeeds(pattern.arguments[1], default) else None
        if head_name == "Condition":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Condition expects exactly two arguments.")
            matched = _bind_optional_default(pattern.arguments[0], default, bindings)
            if matched is None:
                return None
            return matched if _condition_test_succeeds(pattern.arguments[1], matched) else None
        if head_name == "Pattern":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            matched = _bind_optional_default(inner_pattern, default, bindings)
            if matched is None:
                return None
            return _bind_pattern_name(matched, name_expr.name, default)
        if head_name == "Alternatives":
            for branch in pattern.arguments:
                matched = _bind_optional_default(branch, default, bindings)
                if matched is not None:
                    return matched
            return None
        if head_name in {
            "Blank",
            "BlankSequence",
            "BlankNullSequence",
            "Repeated",
            "RepeatedNull",
            "PatternSequence",
            "OrderlessPatternSequence",
            "OptionsPattern",
        }:
            return dict(bindings)
    return dict(bindings) if pattern == default else None


def _match_optional_sequence(
    exprs: Sequence[Expr],
    pattern: Call,
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    if len(pattern.arguments) not in {1, 2}:
        raise WolframEvaluationError("Optional expects one or two arguments.")
    if not exprs:
        if len(pattern.arguments) == 1:
            return None
        return _bind_optional_default(pattern.arguments[0], pattern.arguments[1], bindings)
    return _match_sequence_pattern_elements(
        exprs,
        pattern.arguments[0],
        bindings,
        ignore_inactive=ignore_inactive,
    )


def _is_option_expr(expr: Expr) -> bool:
    entry = _rule_entry(expr)
    if entry is not None:
        return isinstance(entry.key, (Symbol, String))
    if isinstance(expr, Call) and expr.has_head("List"):
        return all(_is_option_expr(argument) for argument in expr.arguments)
    return False


def _match_options_pattern_sequence(
    exprs: Sequence[Expr],
    pattern: Call,
    bindings: dict[str, Expr],
) -> dict[str, Expr] | None:
    if len(pattern.arguments) > 1:
        raise WolframEvaluationError("OptionsPattern expects zero or one argument.")
    return dict(bindings) if all(_is_option_expr(expr) for expr in exprs) else None


def _match_repeated_sequence(
    exprs: Sequence[Expr],
    pattern: Call,
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    if len(pattern.arguments) not in {1, 2}:
        raise WolframEvaluationError(f"{pattern.head_expr.name} expects one or two arguments.")
    item_pattern = pattern.arguments[0]
    count_min, count_max = _repetition_count_bounds(pattern)
    if count_min > count_max:
        return None

    item_min, item_max = _pattern_width_bounds(item_pattern)

    def recurse(position: int, count: int, current: dict[str, Expr]) -> dict[str, Expr] | None:
        if position == len(exprs):
            return current if count_min <= count <= count_max else None
        if count >= count_max:
            return None

        remaining = len(exprs) - position
        concrete_min = max(1, item_min)
        concrete_max = min(item_max, remaining)
        if concrete_min > concrete_max:
            return None
        for length in _sequence_length_order(item_pattern, concrete_min, concrete_max):
            matched = _match_sequence_pattern_elements(
                exprs[position:position + length],
                item_pattern,
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                continue
            result = recurse(position + length, count + 1, matched)
            if result is not None:
                return result
        return None

    if not exprs and count_min == 0:
        return dict(bindings)
    return recurse(0, 0, dict(bindings))


def _match_orderless_pattern_sequence(
    exprs: Sequence[Expr],
    pattern: Call,
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    if not pattern.arguments:
        return dict(bindings) if not exprs else None
    for permutation in itertools.permutations(pattern.arguments):
        matched = _match_call_arguments(exprs, permutation, bindings, ignore_inactive=ignore_inactive)
        if matched is not None:
            return matched
    return None


def _match_sequence_pattern_elements(
    exprs: Sequence[Expr],
    pattern: Expr,
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name

        if head_name == "Alternatives":
            if not pattern.arguments:
                return None
            for branch in pattern.arguments:
                matched = _match_sequence_pattern_elements(
                    exprs,
                    branch,
                    bindings,
                    ignore_inactive=ignore_inactive,
                )
                if matched is not None:
                    return matched
            return None

        if head_name == "HoldPattern":
            if len(pattern.arguments) != 1:
                raise WolframEvaluationError("HoldPattern expects exactly one argument.")
            return _match_sequence_pattern_elements(
                exprs,
                pattern.arguments[0],
                bindings,
                ignore_inactive=ignore_inactive,
            )

        if head_name == "IgnoringInactive":
            if len(pattern.arguments) != 1:
                raise WolframEvaluationError("IgnoringInactive expects exactly one pattern.")
            return _match_sequence_pattern_elements(
                exprs,
                pattern.arguments[0],
                bindings,
                ignore_inactive=True,
            )

        if head_name == "Condition":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Condition expects exactly two arguments.")
            matched = _match_sequence_pattern_elements(
                exprs,
                pattern.arguments[0],
                bindings,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return matched if _condition_test_succeeds(pattern.arguments[1], matched) else None

        if head_name in {"Longest", "Shortest"}:
            if len(pattern.arguments) not in {1, 2}:
                raise WolframEvaluationError(f"{head_name} expects one or two arguments.")
            return _match_sequence_pattern_elements(
                exprs,
                pattern.arguments[0],
                bindings,
                ignore_inactive=ignore_inactive,
            )

        if head_name == "PatternTest":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("PatternTest expects exactly two arguments.")
            matched = _match_sequence_pattern_elements(
                exprs,
                pattern.arguments[0],
                bindings,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return matched if all(_predicate_succeeds(pattern.arguments[1], expr) for expr in exprs) else None

        if head_name == "Optional":
            return _match_optional_sequence(exprs, pattern, bindings, ignore_inactive=ignore_inactive)

        if head_name == "Pattern":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            matched = _match_sequence_pattern_elements(
                exprs,
                inner_pattern,
                bindings,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return _bind_pattern_name(matched, name_expr.name, _sequence_binding_value(exprs))

        if head_name == "PatternSequence":
            return _match_call_arguments(exprs, pattern.arguments, bindings, ignore_inactive=ignore_inactive)

        if head_name == "OrderlessPatternSequence":
            return _match_orderless_pattern_sequence(exprs, pattern, bindings, ignore_inactive=ignore_inactive)

        if head_name == "OptionsPattern":
            return _match_options_pattern_sequence(exprs, pattern, bindings)

        if head_name in {"Repeated", "RepeatedNull"}:
            return _match_repeated_sequence(exprs, pattern, bindings, ignore_inactive=ignore_inactive)

    head_name = _direct_sequence_pattern_head_name(pattern)
    if head_name is None:
        if len(exprs) != 1:
            return None
        return _match_pattern(exprs[0], pattern, bindings, ignore_inactive=ignore_inactive)

    assert isinstance(pattern, Call)
    if len(pattern.arguments) > 1:
        raise WolframEvaluationError(f"{head_name} expects zero or one argument.")
    if not exprs and head_name == "BlankSequence":
        return None

    matched = dict(bindings)
    element_pattern = call("Blank", *pattern.arguments)
    for item in exprs:
        matched = _match_pattern(item, element_pattern, matched, ignore_inactive=ignore_inactive)
        if matched is None:
            return None
    return matched


def _match_call_arguments(
    expr_arguments: Sequence[Expr],
    pattern_arguments: Sequence[Expr],
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    def recurse(expr_index: int, pattern_index: int, current: dict[str, Expr]) -> dict[str, Expr] | None:
        if pattern_index == len(pattern_arguments):
            return current if expr_index == len(expr_arguments) else None
        if expr_index > len(expr_arguments):
            return None

        pattern_argument = pattern_arguments[pattern_index]
        if not _is_sequence_argument_pattern(pattern_argument):
            if expr_index >= len(expr_arguments):
                return None
            matched = _match_pattern(
                expr_arguments[expr_index],
                pattern_argument,
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return recurse(expr_index + 1, pattern_index + 1, matched)

        min_length, pattern_max_length = _sequence_pattern_length_bounds(pattern_argument)
        remaining_minimum = _minimum_argument_count(pattern_arguments[pattern_index + 1:])
        max_length = min(pattern_max_length, len(expr_arguments) - expr_index - remaining_minimum)
        for length in _sequence_length_order(pattern_argument, min_length, max_length):
            segment = expr_arguments[expr_index:expr_index + length]
            matched = _match_sequence_pattern_elements(
                segment,
                pattern_argument,
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                continue
            final = recurse(expr_index + length, pattern_index + 1, matched)
            if final is not None:
                return final
        return None

    return recurse(0, 0, dict(bindings))


def _minimum_flat_argument_count(pattern_arguments: Sequence[Expr]) -> int:
    count = 0
    for pattern_argument in pattern_arguments:
        if _is_sequence_argument_pattern(pattern_argument):
            count += _sequence_pattern_min_length(pattern_argument)
        else:
            count += 1
    return count


def _flat_segment_expr(head: Expr, segment: Sequence[Expr], attribute_names: set[str]) -> Expr:
    if len(segment) == 1 and "OneIdentity" in attribute_names:
        return segment[0]
    return Call(head_expr=head, arguments=tuple(segment))


def _match_flat_call_arguments(
    head: Expr,
    expr_arguments: Sequence[Expr],
    pattern_arguments: Sequence[Expr],
    bindings: dict[str, Expr],
    attribute_names: set[str],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    def recurse(expr_index: int, pattern_index: int, current: dict[str, Expr]) -> dict[str, Expr] | None:
        if pattern_index == len(pattern_arguments):
            return current if expr_index == len(expr_arguments) else None
        if expr_index > len(expr_arguments):
            return None

        pattern_argument = pattern_arguments[pattern_index]
        remaining_minimum = _minimum_flat_argument_count(pattern_arguments[pattern_index + 1:])
        max_length = len(expr_arguments) - expr_index - remaining_minimum

        if _is_sequence_argument_pattern(pattern_argument):
            min_length, pattern_max_length = _sequence_pattern_length_bounds(pattern_argument)
            max_length = min(max_length, pattern_max_length)
            for length in _sequence_length_order(pattern_argument, min_length, max_length):
                segment = expr_arguments[expr_index:expr_index + length]
                matched = _match_sequence_pattern_elements(
                    segment,
                    pattern_argument,
                    current,
                    ignore_inactive=ignore_inactive,
                )
                if matched is None:
                    continue
                final = recurse(expr_index + length, pattern_index + 1, matched)
                if final is not None:
                    return final
            return None

        if max_length < 1:
            return None
        for length in range(1, max_length + 1):
            segment = expr_arguments[expr_index:expr_index + length]
            matched = _match_pattern(
                _flat_segment_expr(head, segment, attribute_names),
                pattern_argument,
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                continue
            final = recurse(expr_index + length, pattern_index + 1, matched)
            if final is not None:
                return final
        return None

    return recurse(0, 0, dict(bindings))


def _unique_argument_permutations(arguments: Sequence[Expr]) -> Iterable[tuple[Expr, ...]]:
    seen: set[tuple[Expr, ...]] = set()
    for permutation in itertools.permutations(arguments):
        if permutation in seen:
            continue
        seen.add(permutation)
        yield permutation


def _match_call_arguments_with_attributes(
    head: Expr,
    expr_arguments: Sequence[Expr],
    pattern_arguments: Sequence[Expr],
    bindings: dict[str, Expr],
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    attribute_names = _attribute_names_for_symbol(head) if isinstance(head, Symbol) else set()
    if "Orderless" in attribute_names:
        argument_orders = _unique_argument_permutations(expr_arguments)
    else:
        argument_orders = (tuple(expr_arguments),)

    for ordered_arguments in argument_orders:
        if "Flat" in attribute_names:
            matched = _match_flat_call_arguments(
                head,
                ordered_arguments,
                pattern_arguments,
                bindings,
                attribute_names,
                ignore_inactive=ignore_inactive,
            )
        else:
            matched = _match_call_arguments(
                ordered_arguments,
                pattern_arguments,
                bindings,
                ignore_inactive=ignore_inactive,
            )
        if matched is not None:
            return matched
    return None


def _key_value_pattern_elements(expr: Expr) -> tuple[Expr, ...] | None:
    entries = _association_entries(expr)
    if entries is not None:
        return tuple(entry.to_expr() for entry in entries)

    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None

    elements: list[Expr] = []
    for argument in expr.arguments:
        if _rule_entry(argument) is None:
            return None
        elements.append(argument)
    return tuple(elements)


def _key_value_pattern_items(spec: Expr) -> tuple[Expr, ...]:
    if isinstance(spec, Call) and spec.has_head("List"):
        return spec.arguments
    return (spec,)


def _match_key_value_pattern(
    expr: Expr,
    spec: Expr,
    bindings: dict[str, Expr],
) -> dict[str, Expr] | None:
    elements = _key_value_pattern_elements(expr)
    if elements is None:
        return None

    patterns = _key_value_pattern_items(spec)

    def recurse(
        pattern_index: int,
        used_indices: frozenset[int],
        current: dict[str, Expr],
    ) -> dict[str, Expr] | None:
        if pattern_index == len(patterns):
            return current

        pattern = patterns[pattern_index]
        for index, element in enumerate(elements):
            if index in used_indices:
                continue
            matched = _match_pattern(element, pattern, current)
            if matched is None:
                continue
            result = recurse(pattern_index + 1, used_indices | {index}, matched)
            if result is not None:
                return result
        return None

    return recurse(0, frozenset(), dict(bindings))


def _active_view(expr: Expr) -> Expr:
    if _is_inactive_wrapper(expr):
        assert isinstance(expr, Call)
        return _active_view(expr.arguments[0])
    if isinstance(expr, Call):
        return Call(
            head_expr=_active_view(expr.head_expr),
            arguments=tuple(_active_view(argument) for argument in expr.arguments),
        )
    return expr


def _inactive_ignoring_argument_view(expr: Expr, structural_expr: Expr) -> tuple[Expr, ...]:
    if (
        isinstance(expr, Call)
        and isinstance(structural_expr, Call)
        and not _is_inactive_wrapper(expr)
        and len(expr.arguments) == len(structural_expr.arguments)
    ):
        return expr.arguments
    if isinstance(structural_expr, Call):
        return structural_expr.arguments
    return ()


def _inactive_ignoring_head_view(expr: Expr, structural_expr: Expr) -> Expr:
    if isinstance(structural_expr, Call) and _is_inactive_wrapper(expr):
        return structural_expr.head_expr
    return head_of(expr)


def _match_pattern(
    expr: Expr,
    pattern: Expr,
    bindings: dict[str, Expr] | None = None,
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    current = {} if bindings is None else dict(bindings)
    structural_expr = _active_view(expr) if ignore_inactive else expr
    structural_pattern = _active_view(pattern) if ignore_inactive else pattern

    if isinstance(structural_pattern, Call) and isinstance(structural_pattern.head_expr, Symbol):
        head_name = structural_pattern.head_expr.name

        if head_name == "IgnoringInactive":
            if len(structural_pattern.arguments) != 1:
                raise WolframEvaluationError("IgnoringInactive expects exactly one pattern.")
            assert isinstance(pattern, Call)
            return _match_pattern(expr, pattern.arguments[0], current, ignore_inactive=True)

        if head_name in _UNSUPPORTED_PATTERN_HEADS:
            raise _unsupported_pattern(structural_pattern)

        if head_name == "HoldPattern":
            if len(structural_pattern.arguments) != 1:
                raise WolframEvaluationError("HoldPattern expects exactly one argument.")
            return _match_pattern(
                expr,
                structural_pattern.arguments[0],
                current,
                ignore_inactive=ignore_inactive,
            )

        if head_name == "Verbatim":
            if len(structural_pattern.arguments) != 1:
                raise WolframEvaluationError("Verbatim expects exactly one argument.")
            if ignore_inactive:
                return current if _active_view(expr) == _active_view(structural_pattern.arguments[0]) else None
            return current if expr == structural_pattern.arguments[0] else None

        if head_name == "Except":
            if len(structural_pattern.arguments) == 1:
                return current if _match_pattern(
                    expr,
                    structural_pattern.arguments[0],
                    current,
                    ignore_inactive=ignore_inactive,
                ) is None else None
            if len(structural_pattern.arguments) == 2:
                allowed = _match_pattern(
                    expr,
                    structural_pattern.arguments[1],
                    current,
                    ignore_inactive=ignore_inactive,
                )
                if allowed is None:
                    return None
                return allowed if _match_pattern(
                    expr,
                    structural_pattern.arguments[0],
                    current,
                    ignore_inactive=ignore_inactive,
                ) is None else None
            raise WolframEvaluationError("Except expects one or two arguments.")

        if head_name == "Alternatives":
            if not structural_pattern.arguments:
                return None
            for branch in structural_pattern.arguments:
                matched = _match_pattern(expr, branch, current, ignore_inactive=ignore_inactive)
                if matched is not None:
                    return matched
            return None

        if head_name == "Condition":
            if len(structural_pattern.arguments) != 2:
                raise WolframEvaluationError("Condition expects exactly two arguments.")
            matched = _match_pattern(
                expr,
                structural_pattern.arguments[0],
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return matched if _condition_test_succeeds(structural_pattern.arguments[1], matched) else None

        if head_name in {"Longest", "Shortest"}:
            if len(structural_pattern.arguments) not in {1, 2}:
                raise WolframEvaluationError(f"{head_name} expects one or two arguments.")
            return _match_pattern(
                expr,
                structural_pattern.arguments[0],
                current,
                ignore_inactive=ignore_inactive,
            )

        if head_name == "PatternTest":
            if len(structural_pattern.arguments) != 2:
                raise WolframEvaluationError("PatternTest expects exactly two arguments.")
            matched = _match_pattern(
                expr,
                structural_pattern.arguments[0],
                current,
                ignore_inactive=ignore_inactive,
            )
            if matched is None:
                return None
            return matched if _predicate_succeeds(structural_pattern.arguments[1], expr) else None

        if head_name == "Optional":
            if len(structural_pattern.arguments) not in {1, 2}:
                raise WolframEvaluationError("Optional expects one or two arguments.")
            return _match_pattern(
                expr,
                structural_pattern.arguments[0],
                current,
                ignore_inactive=ignore_inactive,
            )

        if head_name == "KeyValuePattern":
            if len(structural_pattern.arguments) != 1:
                raise WolframEvaluationError("KeyValuePattern expects exactly one argument.")
            return _match_key_value_pattern(expr, structural_pattern.arguments[0], current)

        if head_name == "Pattern":
            if len(structural_pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = structural_pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            if _is_sequence_argument_pattern(inner_pattern):
                return _match_sequence_pattern_elements(
                    (expr,),
                    structural_pattern,
                    current,
                    ignore_inactive=ignore_inactive,
                )
            matched = _match_pattern(expr, inner_pattern, current, ignore_inactive=ignore_inactive)
            if matched is None:
                return None
            bound = matched.get(name_expr.name)
            if bound is not None:
                return matched if bound == expr else None
            return _bind_pattern_name(matched, name_expr.name, expr)

        if head_name == "Blank":
            if len(structural_pattern.arguments) == 0:
                return current
            if len(structural_pattern.arguments) == 1:
                return _match_pattern(
                    head_of(expr),
                    structural_pattern.arguments[0],
                    current,
                    ignore_inactive=ignore_inactive,
                )
            raise WolframEvaluationError("Blank expects zero or one argument.")

        if head_name in _SEQUENCE_PATTERN_HEADS:
            return _match_sequence_pattern_elements(
                (expr,),
                structural_pattern,
                current,
                ignore_inactive=ignore_inactive,
            )

    if isinstance(structural_pattern, Call):
        if not isinstance(structural_expr, Call):
            return None
        expr_head = _inactive_ignoring_head_view(expr, structural_expr) if ignore_inactive else head_of(expr)
        matched = _match_pattern(expr_head, structural_pattern.head_expr, current, ignore_inactive=ignore_inactive)
        if matched is None:
            return None
        assert isinstance(structural_expr, Call)
        return _match_call_arguments_with_attributes(
            expr_head,
            _inactive_ignoring_argument_view(expr, structural_expr),
            structural_pattern.arguments,
            matched,
            ignore_inactive=ignore_inactive,
        )

    if ignore_inactive:
        return current if structural_expr == structural_pattern else None
    return current if expr == pattern else None


def match_q(expr: Expr, pattern: Expr) -> Symbol:
    return _bool_symbol(_match_pattern(expr, pattern) is not None)


@dataclass(frozen=True)
class _PatternRecord:
    expr: Expr
    positive_level: int
    negative_level: int


def _collect_pattern_records(
    expr: Expr,
    positive_level: int,
    target: list[_PatternRecord],
    *,
    heads: bool,
) -> None:
    entries = _association_entries(expr)
    if entries is not None:
        if heads:
            _collect_pattern_records(expr.head_expr, positive_level + 1, target, heads=heads)
        for entry in entries:
            _collect_pattern_records(entry.value, positive_level + 1, target, heads=heads)
        target.append(_PatternRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))
        return

    if isinstance(expr, Call):
        if heads:
            _collect_pattern_records(expr.head_expr, positive_level + 1, target, heads=heads)
        for argument in expr.arguments:
            _collect_pattern_records(argument, positive_level + 1, target, heads=heads)

    target.append(_PatternRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))


def _level_bounds_match(positive_level: int, negative_level: int, level_min: int, level_max: int) -> bool:
    if level_min >= 0 and level_max >= 0:
        return level_min <= positive_level <= level_max
    if level_min < 0 and level_max < 0:
        return level_min <= negative_level <= level_max
    if level_min >= 0 and level_max < 0:
        return positive_level >= level_min and negative_level <= level_max
    return negative_level >= level_min or positive_level <= level_max


def free_q(expr: Expr, pattern: Expr, spec: Expr | int | tuple[int, int] | None = None) -> Symbol:
    level_spec = list_expr(integer(0), symbol("Infinity")) if spec is None else spec
    records: list[_PatternRecord] = []
    _collect_pattern_records(expr, 0, records, heads=True)
    level_min, level_max = _normalize_level_spec(level_spec)
    for record in records:
        if not _level_bounds_match(record.positive_level, record.negative_level, level_min, level_max):
            continue
        if _match_pattern(record.expr, pattern) is not None:
            return _bool_symbol(False)
    return _bool_symbol(True)


def _normalize_match_limit(limit: Expr | int | None) -> int | None:
    if limit is None:
        return None
    if isinstance(limit, int):
        if limit < 0:
            raise WolframEvaluationError("Match limits must be non-negative integers or Infinity.")
        return limit
    if isinstance(limit, Integer):
        return _normalize_match_limit(limit.value)
    if isinstance(limit, Symbol) and limit.name == "Infinity":
        return None
    raise WolframEvaluationError("Match limits must be non-negative integers or Infinity.")


def _cases_pattern_spec(spec: Expr) -> tuple[Expr, Expr | None, bool]:
    if isinstance(spec, Call) and spec.has_head("Rule"):
        if len(spec.arguments) != 2:
            raise WolframEvaluationError("Cases transformation rules must contain exactly two arguments.")
        return spec.arguments[0], evaluate(spec.arguments[1]), False
    if isinstance(spec, Call) and spec.has_head("RuleDelayed"):
        if len(spec.arguments) != 2:
            raise WolframEvaluationError("Cases transformation rules must contain exactly two arguments.")
        return spec.arguments[0], spec.arguments[1], True
    return spec, None, False


def _substitute_pattern_bindings(expr: Expr, bindings: dict[str, Expr]) -> Expr:
    if isinstance(expr, Symbol):
        return bindings.get(expr.name, expr)
    if isinstance(expr, (Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr
    if not isinstance(expr, Call):
        return expr

    if expr.has_head("Pattern") and len(expr.arguments) == 2 and isinstance(expr.arguments[0], Symbol):
        return call(
            _substitute_pattern_bindings(expr.head_expr, bindings),
            expr.arguments[0],
            _substitute_pattern_bindings(expr.arguments[1], bindings),
        )

    substituted_arguments: list[Expr] = []
    for argument in expr.arguments:
        if isinstance(argument, Symbol):
            bound = bindings.get(argument.name)
            if isinstance(bound, Call) and bound.has_head("Sequence"):
                substituted_arguments.extend(bound.arguments)
                continue
        substituted_arguments.append(_substitute_pattern_bindings(argument, bindings))

    return call(
        _substitute_pattern_bindings(expr.head_expr, bindings),
        *substituted_arguments,
    )


def _condition_test_succeeds(test: Expr, bindings: dict[str, Expr]) -> bool:
    evaluated = evaluate(_substitute_pattern_bindings(test, bindings))
    return isinstance(evaluated, Symbol) and evaluated.name == "True"


def _missing_not_found() -> Expr:
    return call("Missing", string("NotFound"))


def _selection_spec(
    criterion: Expr,
    function_name: str,
) -> tuple[Expr, Expr | tuple[Expr, ...] | None]:
    if isinstance(criterion, Call) and criterion.has_head("Rule"):
        if len(criterion.arguments) != 2:
            raise WolframEvaluationError(
                f"{function_name} property specifications must contain exactly two arguments."
            )
        selector, property_spec = criterion.arguments
    else:
        selector = criterion
        property_spec = None

    if property_spec is None:
        return selector, None

    if isinstance(property_spec, String):
        if property_spec.value not in {"Element", "Index"}:
            raise WolframEvaluationError(
                f'{function_name} currently supports only "Element" and "Index" properties.'
            )
        return selector, property_spec

    if isinstance(property_spec, Call) and property_spec.has_head("List"):
        normalized: list[Expr] = []
        for item in property_spec.arguments:
            if not isinstance(item, String) or item.value not in {"Element", "Index"}:
                raise WolframEvaluationError(
                    f'{function_name} currently supports only "Element" and "Index" properties.'
                )
            normalized.append(item)
        return selector, tuple(normalized)

    raise WolframEvaluationError(
        f'{function_name} currently supports only "Element" and "Index" properties.'
    )


def _selection_items(expr: Expr, function_name: str) -> tuple[_SelectionItem, ...]:
    entries = _association_entries(expr)
    if entries is not None:
        return tuple(
            _SelectionItem(index=index, value=entry.value, entry=entry)
            for index, entry in enumerate(entries, start=1)
        )

    compound = _require_compound(expr, function_name)
    return tuple(
        _SelectionItem(index=index, value=argument)
        for index, argument in enumerate(compound.arguments, start=1)
    )


def _selection_elements(expr: Expr, items: Sequence[_SelectionItem], function_name: str) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(item.entry for item in items if item.entry is not None)

    compound = _require_compound(expr, function_name)
    return _rebuild(compound, tuple(item.value for item in items))


def _selection_indices(items: Sequence[_SelectionItem]) -> Expr:
    return list_expr(*(integer(item.index) for item in items))


def _selection_projection(
    expr: Expr,
    items: Sequence[_SelectionItem],
    function_name: str,
    property_spec: Expr | tuple[Expr, ...] | None,
) -> Expr:
    if property_spec is None:
        return _selection_elements(expr, items, function_name)

    if isinstance(property_spec, String):
        if property_spec.value == "Element":
            return _selection_elements(expr, items, function_name)
        if property_spec.value == "Index":
            return _selection_indices(items)
        raise WolframEvaluationError(
            f'{function_name} currently supports only "Element" and "Index" properties.'
        )

    return _association_expr(
        _AssociationEntry(
            "Rule",
            property_name,
            _selection_projection(expr, items, function_name, property_name),
        )
        for property_name in property_spec
    )


def _select_first_projection(
    item: _SelectionItem | None,
    property_spec: Expr | tuple[Expr, ...] | None,
    default: Expr | object = _MISSING,
) -> Expr:
    missing = _missing_not_found()

    if property_spec is None:
        if item is not None:
            return item.value
        if default is not _MISSING:
            return default  # type: ignore[return-value]
        return missing

    if isinstance(property_spec, String):
        if property_spec.value == "Element":
            if item is not None:
                return item.value
            if default is not _MISSING:
                return default  # type: ignore[return-value]
            return missing
        if property_spec.value == "Index":
            return integer(item.index) if item is not None else missing
        raise WolframEvaluationError(
            'SelectFirst currently supports only "Element" and "Index" properties.'
        )

    return _association_expr(
        _AssociationEntry(
            "Rule",
            property_name,
            _select_first_projection(item, property_name, default),
        )
        for property_name in property_spec
    )


def _predicate_succeeds_with_arguments(criterion: Expr, arguments: Sequence[Expr]) -> bool:
    evaluated = evaluate(_apply_callable(criterion, arguments))
    return isinstance(evaluated, Symbol) and evaluated.name == "True"


def _predicate_succeeds(criterion: Expr, value: Expr) -> bool:
    return _predicate_succeeds_with_arguments(criterion, (value,))


def if_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3, 4}:
        raise WolframEvaluationError("If expects a condition, a true branch, and optional false and unknown branches.")

    condition = evaluate(arguments[0])
    truth = _truth_value(condition)
    if truth is True:
        return evaluate(arguments[1])
    if truth is False:
        if len(arguments) == 2:
            return symbol("Null")
        return evaluate(arguments[2])
    if len(arguments) == 4:
        return evaluate(arguments[3])
    return call("If", condition, *arguments[1:])


def which_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) == 0 or len(arguments) % 2 != 0:
        raise WolframEvaluationError("Which expects condition-value pairs.")

    for index in range(0, len(arguments), 2):
        condition = evaluate(arguments[index])
        truth = _truth_value(condition)
        if truth is True:
            return evaluate(arguments[index + 1])
        if truth is False:
            continue
        return call("Which", condition, arguments[index + 1], *arguments[index + 2:])
    return symbol("Null")


def switch_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) < 3 or len(arguments) % 2 == 0:
        raise WolframEvaluationError("Switch expects an expression followed by form-value pairs.")

    subject = evaluate(arguments[0])
    for index in range(1, len(arguments), 2):
        if _match_pattern(subject, arguments[index]) is not None:
            return evaluate(arguments[index + 1])
    return call("Switch", subject, *arguments[1:])


def piecewise_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2}:
        raise WolframEvaluationError("Piecewise expects a case list and an optional default value.")

    cases_expr = arguments[0]
    if not isinstance(cases_expr, Call) or not cases_expr.has_head("List"):
        raise WolframEvaluationError("Piecewise expects its first argument to be a list of {value, condition} pairs.")

    kept_cases: list[tuple[Expr, Expr]] = []
    for item in cases_expr.arguments:
        if not isinstance(item, Call) or not item.has_head("List") or len(item.arguments) != 2:
            raise WolframEvaluationError("Piecewise cases must be two-element lists of {value, condition}.")
        value_expr, condition_expr = item.arguments
        condition = evaluate(condition_expr)
        truth = _truth_value(condition)
        if truth is True:
            selected_value = evaluate(value_expr)
            if not kept_cases:
                return selected_value
            return call(
                "Piecewise",
                list_expr(*(list_expr(value, cond) for value, cond in kept_cases)),
                selected_value,
            )
        if truth is False:
            continue
        kept_cases.append((evaluate(value_expr), condition))

    default_value = evaluate(arguments[1]) if len(arguments) == 2 else integer(0)
    if not kept_cases:
        return default_value
    return call(
        "Piecewise",
        list_expr(*(list_expr(value, cond) for value, cond in kept_cases)),
        default_value,
    )


_PICK_NONE = object()


def _pick_recursive(
    expr: Expr,
    selector: Expr,
    pattern: Expr,
    *,
    top_level: bool,
) -> Expr | object:
    if _match_pattern(selector, pattern) is not None:
        return expr

    expr_entries = _association_entries(expr)
    selector_entries = _association_entries(selector)

    expr_arguments: tuple[Expr, ...] | None
    selector_arguments: tuple[Expr, ...] | None

    if expr_entries is not None:
        expr_arguments = tuple(entry.value for entry in expr_entries)
    elif isinstance(expr, Call):
        expr_arguments = expr.arguments
    else:
        expr_arguments = None

    if selector_entries is not None:
        selector_arguments = tuple(entry.value for entry in selector_entries)
    elif isinstance(selector, Call):
        selector_arguments = selector.arguments
    else:
        selector_arguments = None

    if expr_arguments is None or selector_arguments is None:
        if top_level:
            raise WolframEvaluationError("Pick currently expects selector parts compatible with the data shape.")
        return _PICK_NONE

    if len(expr_arguments) != len(selector_arguments):
        raise WolframEvaluationError("Pick currently expects selector parts compatible with the data shape.")

    picked_arguments: list[Expr] = []
    picked_entries: list[_AssociationEntry] = []

    for index, (child_expr, child_selector) in enumerate(zip(expr_arguments, selector_arguments, strict=True)):
        picked = _pick_recursive(child_expr, child_selector, pattern, top_level=False)
        if picked is _PICK_NONE:
            continue
        assert isinstance(picked, Expr)
        if expr_entries is not None:
            entry = expr_entries[index]
            picked_entries.append(
                _AssociationEntry(
                    rule_head=entry.rule_head,
                    key=entry.key,
                    value=picked,
                )
            )
        else:
            picked_arguments.append(picked)

    if expr_entries is not None:
        return _association_expr(picked_entries)
    assert isinstance(expr, Call)
    return _rebuild(expr, tuple(picked_arguments))


def pick(expr: Expr, selector: Expr, pattern: Expr | None = None) -> Expr:
    effective_pattern = pattern if pattern is not None else symbol("True")
    picked = _pick_recursive(expr, selector, effective_pattern, top_level=True)
    assert isinstance(picked, Expr)
    return picked


def clip_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Clip expects one, two, or three arguments.")

    x = arguments[0]
    if not _is_real_number_expr(x):
        raise WolframEvaluationError("Clip currently evaluates only for explicit real numeric arguments.")

    if len(arguments) == 1:
        lower = integer(-1)
        upper = integer(1)
        lower_compare = _compare_real_expr(x, lower)
        upper_compare = _compare_real_expr(x, upper)
        if lower_compare is None or upper_compare is None:
            raise WolframEvaluationError("Clip could not compare the input with default bounds.")
        if lower_compare < 0:
            return lower
        if upper_compare > 0:
            return upper
        return x

    bounds = arguments[1]
    if not isinstance(bounds, Call) or not bounds.has_head("List") or len(bounds.arguments) != 2:
        raise WolframEvaluationError("Clip currently expects bounds of the form {min, max}.")
    lower, upper = bounds.arguments
    if not _is_real_number_expr(lower) or not _is_real_number_expr(upper):
        raise WolframEvaluationError("Clip currently evaluates only for explicit real numeric bounds.")

    lower_compare = _compare_real_expr(x, lower)
    upper_compare = _compare_real_expr(x, upper)
    if lower_compare is None or upper_compare is None:
        raise WolframEvaluationError("Clip could not compare the input with the supplied bounds.")

    if lower_compare < 0:
        if len(arguments) == 3:
            replacements = arguments[2]
            if not isinstance(replacements, Call) or not replacements.has_head("List") or len(replacements.arguments) != 2:
                raise WolframEvaluationError("Clip currently expects replacement values of the form {vmin, vmax}.")
            return replacements.arguments[0]
        return lower

    if upper_compare > 0:
        if len(arguments) == 3:
            replacements = arguments[2]
            if not isinstance(replacements, Call) or not replacements.has_head("List") or len(replacements.arguments) != 2:
                raise WolframEvaluationError("Clip currently expects replacement values of the form {vmin, vmax}.")
            return replacements.arguments[1]
        return upper

    return x


def _instantiate_replacement_template(
    template: Expr,
    bindings: dict[str, Expr],
    *,
    delayed: bool,
    evaluate_result: bool = True,
) -> tuple[Expr | None, bool]:
    substituted = _substitute_pattern_bindings(template, bindings)
    if delayed and isinstance(substituted, Call) and substituted.has_head("Condition"):
        if len(substituted.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        body, test = substituted.arguments
        if not _condition_test_succeeds(test, {}):
            return (None, False)
        return _instantiate_replacement_template(body, {}, delayed=True, evaluate_result=evaluate_result)
    if delayed and not evaluate_result:
        return (substituted, True)
    return (evaluate(substituted), True)


@dataclass(frozen=True)
class _ReplacementRule:
    pattern: Expr
    template: Expr
    delayed: bool


_REPLACE_REPEATED_MAX_ITERATIONS = 65536


def _is_replacement_rule_expr(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and (expr.has_head("Rule") or expr.has_head("RuleDelayed"))
        and len(expr.arguments) == 2
    )


def _replacement_rule_from_expr(rule: Expr, function_name: str) -> _ReplacementRule:
    if not _is_replacement_rule_expr(rule):
        raise WolframEvaluationError(f"{function_name} expects a rule or a list of rules.")
    assert isinstance(rule, Call)
    pattern, template = rule.arguments
    delayed = rule.has_head("RuleDelayed")
    if rule.has_head("Rule"):
        template = evaluate(template)
    return _ReplacementRule(pattern=pattern, template=template, delayed=delayed)


def _normalize_single_replacement_ruleset(rules: Expr, function_name: str) -> list[_ReplacementRule]:
    if _is_replacement_rule_expr(rules):
        return [_replacement_rule_from_expr(rules, function_name)]
    if isinstance(rules, Call) and rules.has_head("List"):
        if not rules.arguments:
            return []
        if all(_is_replacement_rule_expr(item) for item in rules.arguments):
            return [_replacement_rule_from_expr(item, function_name) for item in rules.arguments]
    raise WolframEvaluationError(f"{function_name} expects a rule or a list of rules.")


def _is_replacement_rules_argument(expr: Expr) -> bool:
    return (
        _is_replacement_rule_expr(expr)
        or (
            isinstance(expr, Call)
            and expr.has_head("List")
            and (
                not expr.arguments
                or all(_is_replacement_rule_expr(item) for item in expr.arguments)
                or _is_nested_replacement_rules_list(expr)
            )
        )
    )


def _evaluate_replacement_rules_argument(rules: Expr) -> Expr:
    # Literal Rule/RuleDelayed expressions are definition-like data. Keep them
    # unevaluated so delayed RHS expressions stay delayed, but allow symbols or
    # calls such as DownValues[In] to resolve to the actual rules they denote.
    if _is_replacement_rules_argument(rules):
        return rules
    return evaluate(rules)


def _is_nested_replacement_rules_list(rules: Expr) -> bool:
    return (
        isinstance(rules, Call)
        and rules.has_head("List")
        and bool(rules.arguments)
        and not all(_is_replacement_rule_expr(item) for item in rules.arguments)
        and all(
            _is_replacement_rule_expr(item)
            or (isinstance(item, Call) and item.has_head("List"))
            for item in rules.arguments
        )
    )


def _apply_replacement_rules(
    expr: Expr,
    ruleset: Sequence[_ReplacementRule],
    *,
    held_context: bool = False,
) -> tuple[Expr, bool]:
    for rule in ruleset:
        bindings = _match_pattern(expr, rule.pattern)
        if bindings is None:
            continue
        replacement, applied = _instantiate_replacement_template(
            rule.template,
            bindings,
            delayed=rule.delayed,
            evaluate_result=not held_context,
        )
        if not applied:
            continue
        assert replacement is not None
        return (replacement, True)
    return (expr, False)


def _replace_recursive(
    expr: Expr,
    ruleset: Sequence[_ReplacementRule],
    *,
    positive_level: int,
    level_min: int,
    level_max: int,
    held_context: bool = False,
) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        mutable_entries: list[_AssociationEntry] = []
        changed = False
        for entry in entries:
            updated_value = _replace_recursive(
                entry.value,
                ruleset,
                positive_level=positive_level + 1,
                level_min=level_min,
                level_max=level_max,
                held_context=held_context,
            )
            mutable_entries.append(_AssociationEntry(entry.rule_head, entry.key, updated_value))
            changed = changed or updated_value != entry.value
        rebuilt = _association_expr(mutable_entries) if changed else expr
    elif isinstance(expr, Call):
        child_held_context = held_context or (
            isinstance(expr.head_expr, Symbol)
            and expr.head_expr.name in _HELD_ARGUMENT_HEADS
        )
        updated_arguments = tuple(
            _replace_recursive(
                argument,
                ruleset,
                positive_level=positive_level + 1,
                level_min=level_min,
                level_max=level_max,
                held_context=child_held_context,
            )
            for argument in expr.arguments
        )
        if updated_arguments != expr.arguments:
            rebuilt = (
                Call(head_expr=expr.head_expr, arguments=updated_arguments)
                if held_context
                else _rebuild(expr, updated_arguments)
            )
        else:
            rebuilt = expr
    else:
        rebuilt = expr

    negative_level = -depth(rebuilt)
    if _level_bounds_match(positive_level, negative_level, level_min, level_max):
        replaced, _did_replace = _apply_replacement_rules(rebuilt, ruleset, held_context=held_context)
        return replaced
    return rebuilt


def replace(
    expr: Expr,
    rules: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Expr:
    rules = _evaluate_replacement_rules_argument(rules)
    if _is_nested_replacement_rules_list(rules):
        assert isinstance(rules, Call)
        return _evaluated_list_expr(*(replace(expr, item, spec) for item in rules.arguments))
    ruleset = _normalize_single_replacement_ruleset(rules, "Replace")
    if spec is None:
        return _apply_replacement_rules(expr, ruleset)[0]
    level_min, level_max = _normalize_level_spec(spec)
    return _replace_recursive(expr, ruleset, positive_level=0, level_min=level_min, level_max=level_max)


def _replace_all_single_pass(
    expr: Expr,
    ruleset: Sequence[_ReplacementRule],
    *,
    held_context: bool = False,
) -> tuple[Expr, bool]:
    replaced, did_replace = _apply_replacement_rules(expr, ruleset, held_context=held_context)
    if did_replace:
        return (replaced, replaced != expr)

    entries = _association_entries(expr)
    if entries is not None:
        updated_head, head_changed = _replace_all_single_pass(expr.head_expr, ruleset, held_context=held_context)
        mutable_entries: list[_AssociationEntry] = []
        changed = head_changed
        for entry in entries:
            updated_value, value_changed = _replace_all_single_pass(entry.value, ruleset, held_context=held_context)
            mutable_entries.append(_AssociationEntry(entry.rule_head, entry.key, updated_value))
            changed = changed or value_changed
        if not changed:
            return (expr, False)
        if isinstance(updated_head, Symbol) and updated_head.name == "Association":
            return (_association_expr(mutable_entries), True)
        return (Call(head_expr=updated_head, arguments=tuple(entry.to_expr() for entry in mutable_entries)), True)

    if not isinstance(expr, Call):
        return (expr, False)

    updated_head, head_changed = _replace_all_single_pass(expr.head_expr, ruleset, held_context=held_context)
    updated_arguments: list[Expr] = []
    changed = head_changed
    child_held_context = held_context or (
        isinstance(expr.head_expr, Symbol)
        and expr.head_expr.name in _HELD_ARGUMENT_HEADS
    )
    for argument in expr.arguments:
        updated_argument, argument_changed = _replace_all_single_pass(
            argument,
            ruleset,
            held_context=child_held_context,
        )
        updated_arguments.append(updated_argument)
        changed = changed or argument_changed
    if not changed:
        return (expr, False)
    if not held_context:
        if isinstance(updated_head, Symbol):
            updated_arguments = list(
                _normalize_arguments_for_head(updated_head.name, updated_arguments, evaluated=True)
            )
        else:
            updated_arguments = list(_splice_sequence_arguments(updated_arguments))
    return (Call(head_expr=updated_head, arguments=tuple(updated_arguments)), True)


def replace_all(expr: Expr, rules: Expr) -> Expr:
    rules = _evaluate_replacement_rules_argument(rules)
    if _is_nested_replacement_rules_list(rules):
        assert isinstance(rules, Call)
        return _evaluated_list_expr(*(replace_all(expr, item) for item in rules.arguments))
    ruleset = _normalize_single_replacement_ruleset(rules, "ReplaceAll")
    return _replace_all_single_pass(expr, ruleset)[0]


def replace_repeated(expr: Expr, rules: Expr) -> Expr:
    rules = _evaluate_replacement_rules_argument(rules)
    if _is_nested_replacement_rules_list(rules):
        assert isinstance(rules, Call)
        return _evaluated_list_expr(*(replace_repeated(expr, item) for item in rules.arguments))
    ruleset = _normalize_single_replacement_ruleset(rules, "ReplaceRepeated")
    current = expr
    for _ in range(_REPLACE_REPEATED_MAX_ITERATIONS):
        updated, changed = _replace_all_single_pass(current, ruleset)
        if not changed:
            return current
        current = updated
    raise WolframEvaluationError("ReplaceRepeated exceeded the Tungsten iteration safety limit.")


def _try_replace_using_rules_at_path(
    expr: Expr,
    ruleset: Sequence[_ReplacementRule],
    path: Sequence[_IndexSelector | _KeySelector],
) -> tuple[Expr, bool]:
    if not path:
        return (_apply_replacement_rules(expr, ruleset)[0], True)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        updated_child, valid = _try_replace_using_rules_at_path(entry.value, ruleset, path[1:])
        if not valid:
            return (expr, False)
        mutable[index] = _AssociationEntry(entry.rule_head, entry.key, updated_child)
        return (_association_expr(mutable), True)

    if not isinstance(expr, Call):
        return (expr, False)
    selector = path[0]
    if not isinstance(selector, _IndexSelector):
        return (expr, False)
    resolved = selector.index - 1
    if not 0 <= resolved < len(expr.arguments):
        return (expr, False)

    arguments = list(expr.arguments)
    updated_child, valid = _try_replace_using_rules_at_path(arguments[resolved], ruleset, path[1:])
    if not valid:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def replace_at(expr: Expr, rules: Expr, positions: Expr | int) -> Expr:
    rules = _evaluate_replacement_rules_argument(rules)
    if _is_nested_replacement_rules_list(rules):
        raise WolframEvaluationError("ReplaceAt currently expects a rule or a flat list of rules.")
    ruleset = _normalize_single_replacement_ruleset(rules, "ReplaceAt")
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
    if invalid:
        raise WolframEvaluationError(f"ReplaceAt positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(paths):
        result, valid = _try_replace_using_rules_at_path(result, ruleset, path)
        if not valid:
            raise WolframEvaluationError(f"ReplaceAt positions are invalid for {expr.to_input_form()}.")
    return result


def cases(
    expr: Expr,
    pattern_spec: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
) -> Call:
    level_spec = integer(1) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)
    remaining = _normalize_match_limit(limit)
    pattern, template, delayed = _cases_pattern_spec(pattern_spec)

    records: list[_PatternRecord] = []
    _collect_pattern_records(expr, 0, records, heads=False)

    results: list[Expr] = []
    for record in records:
        if remaining == 0:
            break
        if not _level_bounds_match(record.positive_level, record.negative_level, level_min, level_max):
            continue
        bindings = _match_pattern(record.expr, pattern)
        if bindings is None:
            continue
        if template is None:
            results.append(record.expr)
        else:
            transformed, applied = _instantiate_replacement_template(template, bindings, delayed=delayed)
            if not applied:
                continue
            assert transformed is not None
            results.append(transformed)
        if remaining is not None:
            remaining -= 1

    return _evaluated_list_expr(*results)


_DELETE_SENTINEL = object()


def _delete_cases_recursive(
    expr: Expr,
    pattern: Expr,
    *,
    positive_level: int,
    level_min: int,
    level_max: int,
    remaining: list[int | None],
) -> Expr | object:
    entries = _association_entries(expr)
    if entries is not None:
        transformed_entries: list[_AssociationEntry] = []
        changed = False
        for entry in entries:
            transformed = _delete_cases_recursive(
                entry.value,
                pattern,
                positive_level=positive_level + 1,
                level_min=level_min,
                level_max=level_max,
                remaining=remaining,
            )
            if transformed is _DELETE_SENTINEL:
                changed = True
                continue
            assert isinstance(transformed, Expr)
            transformed_entries.append(_AssociationEntry(entry.rule_head, entry.key, transformed))
            changed = changed or transformed != entry.value
        rebuilt: Expr = _association_expr(transformed_entries) if changed else expr
    elif isinstance(expr, Call):
        transformed_args: list[Expr] = []
        for argument in expr.arguments:
            transformed = _delete_cases_recursive(
                argument,
                pattern,
                positive_level=positive_level + 1,
                level_min=level_min,
                level_max=level_max,
                remaining=remaining,
            )
            if transformed is _DELETE_SENTINEL:
                continue
            assert isinstance(transformed, Expr)
            transformed_args.append(transformed)
        rebuilt: Expr = call(expr.head_expr, *transformed_args)
    else:
        rebuilt = expr

    if remaining[0] == 0:
        return rebuilt

    negative_level = -depth(rebuilt)
    if (
        _level_bounds_match(positive_level, negative_level, level_min, level_max)
        and _match_pattern(rebuilt, pattern) is not None
    ):
        if positive_level == 0:
            return _DELETE_SENTINEL
        if remaining[0] is not None:
            remaining[0] -= 1
        return _DELETE_SENTINEL
    return rebuilt


def delete_cases(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
) -> Expr:
    level_spec = integer(1) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)
    remaining = [_normalize_match_limit(limit)]
    transformed = _delete_cases_recursive(
        expr,
        pattern,
        positive_level=0,
        level_min=level_min,
        level_max=level_max,
        remaining=remaining,
    )
    if transformed is _DELETE_SENTINEL:
        raise WolframEvaluationError(
            "DeleteCases does not currently support deleting the whole expression."
        )
    assert isinstance(transformed, Expr)
    return transformed


