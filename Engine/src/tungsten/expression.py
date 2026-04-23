from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence

from .wolfram_strings import has_inline_boxes
from .wolfram_strings import inline_box_segments
from .wolfram_strings import parse_wl_string_literal
from .wolfram_strings import wl_string


class WolframSyntaxError(ValueError):
    """Raised when Tungsten cannot parse a Wolfram expression."""


class WolframEvaluationError(ValueError):
    """Raised when Tungsten cannot structurally evaluate a built-in expression."""


class Expr:
    def head(self) -> Expr:
        raise NotImplementedError

    def args(self) -> tuple[Expr, ...]:
        return ()

    def is_atom(self) -> bool:
        return not self.args()

    def to_full_form(self) -> str:
        raise NotImplementedError

    def to_input_form(self) -> str:
        return self.to_full_form()

    def to_dict(self) -> dict[str, object]:
        raise NotImplementedError

    def has_head(self, name: str) -> bool:
        return False


@dataclass(frozen=True)
class Symbol(Expr):
    name: str

    def head(self) -> Expr:
        return Symbol("Symbol")

    def to_full_form(self) -> str:
        return self.name

    def to_input_form(self) -> str:
        return self.name

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "symbol",
            "name": self.name,
        }

    def has_head(self, name: str) -> bool:
        return self.name == name


@dataclass(frozen=True)
class Integer(Expr):
    value: int

    def head(self) -> Expr:
        return Symbol("Integer")

    def to_full_form(self) -> str:
        return str(self.value)

    def to_input_form(self) -> str:
        return str(self.value)

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "integer",
            "value": self.value,
        }


@dataclass(frozen=True)
class Real(Expr):
    text: str

    def head(self) -> Expr:
        return Symbol("Real")

    def to_full_form(self) -> str:
        return self.text

    def to_input_form(self) -> str:
        return self.text

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "real",
            "text": self.text,
        }


@dataclass(frozen=True)
class String(Expr):
    value: str

    def head(self) -> Expr:
        return Symbol("String")

    def to_full_form(self) -> str:
        return wl_string(self.value)

    def to_input_form(self) -> str:
        return wl_string(self.value)

    def to_dict(self) -> dict[str, object]:
        payload = {
            "type": "string",
            "value": self.value,
        }
        if has_inline_boxes(self.value):
            payload["inline_boxes"] = [
                segment.to_dict()
                for segment in inline_box_segments(self.value)
            ]
        return payload


@dataclass(frozen=True)
class Call(Expr):
    head_expr: Expr
    arguments: tuple[Expr, ...]

    def head(self) -> Expr:
        return self.head_expr

    def args(self) -> tuple[Expr, ...]:
        return self.arguments

    def has_head(self, name: str) -> bool:
        return isinstance(self.head_expr, Symbol) and self.head_expr.name == name

    def to_full_form(self) -> str:
        return f"{self.head_expr.to_full_form()}[{', '.join(arg.to_full_form() for arg in self.arguments)}]"

    def to_input_form(self) -> str:
        if isinstance(self.head_expr, Symbol):
            head_name = self.head_expr.name
            if head_name == "List":
                return "{" + ", ".join(arg.to_input_form() for arg in self.arguments) + "}"
            if head_name == "Association":
                return "<|" + ", ".join(arg.to_input_form() for arg in self.arguments) + "|>"
            if head_name == "Rule" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])} -> {_wrap_infix(self.arguments[1])}"
            if head_name == "RuleDelayed" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])} :> {_wrap_infix(self.arguments[1])}"
            if head_name == "Plus" and self.arguments:
                pieces: list[str] = []
                for index, arg in enumerate(self.arguments):
                    if index > 0 and _is_negative_term(arg):
                        pieces.append("- " + _wrap_infix(_strip_negative_term(arg)))
                    elif index > 0:
                        pieces.append("+ " + _wrap_infix(arg))
                    else:
                        pieces.append(_wrap_infix(arg))
                return " ".join(pieces)
            if head_name == "Times" and self.arguments:
                return " * ".join(_wrap_infix(arg) for arg in self.arguments)
            if head_name == "Power" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])}^{_wrap_infix(self.arguments[1])}"
            if head_name == "Not" and len(self.arguments) == 1:
                return "!" + _wrap_infix(self.arguments[0])
            if head_name == "Span" and self.arguments:
                return _format_span(self.arguments)
            if head_name == "Part" and len(self.arguments) >= 1:
                expr = _wrap_infix(self.arguments[0])
                spec = ", ".join(arg.to_input_form() for arg in self.arguments[1:])
                return f"{expr}[[{spec}]]"

        return f"{self.head_expr.to_input_form()}[{', '.join(arg.to_input_form() for arg in self.arguments)}]"

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "call",
            "head": self.head_expr.to_dict(),
            "args": [arg.to_dict() for arg in self.arguments],
        }


def _wrap_infix(expr: Expr) -> str:
    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr.to_input_form()
    return f"({expr.to_input_form()})"


def _is_negative_term(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.arguments) >= 1
        and isinstance(expr.arguments[0], Integer)
        and expr.arguments[0].value == -1
    )


def _strip_negative_term(expr: Expr) -> Expr:
    if not _is_negative_term(expr):
        return expr

    assert isinstance(expr, Call)
    if len(expr.arguments) == 2:
        return expr.arguments[1]
    return call("Times", *expr.arguments[1:])


def _format_span(arguments: Sequence[Expr]) -> str:
    if len(arguments) == 2:
        start, end = arguments
        if isinstance(start, Integer) and start.value == 1 and isinstance(end, Symbol) and end.name == "All":
            return ";;"
        if isinstance(start, Integer) and start.value == 1:
            return f";; {end.to_input_form()}"
        if isinstance(end, Symbol) and end.name == "All":
            return f"{start.to_input_form()} ;;"
        return f"{start.to_input_form()} ;; {end.to_input_form()}"

    if len(arguments) == 3:
        start, end, step = arguments
        return f"{start.to_input_form()} ;; {end.to_input_form()} ;; {step.to_input_form()}"

    return "Span[" + ", ".join(arg.to_input_form() for arg in arguments) + "]"


def symbol(name: str) -> Symbol:
    return Symbol(name)


def integer(value: int) -> Integer:
    return Integer(int(value))


def real(text: str) -> Real:
    return Real(text)


def string(value: str) -> String:
    return String(value)


_FLAT_HEADS = {"Plus", "Times", "And", "Or"}


def call(head: str | Expr, *arguments: Expr) -> Call:
    head_expr = Symbol(head) if isinstance(head, str) else head
    normalized: list[Expr] = []
    if isinstance(head_expr, Symbol) and head_expr.name in _FLAT_HEADS:
        for argument in arguments:
            if isinstance(argument, Call) and argument.has_head(head_expr.name):
                normalized.extend(argument.arguments)
            else:
                normalized.append(argument)
    else:
        normalized.extend(arguments)

    return Call(head_expr=head_expr, arguments=tuple(normalized))


def list_expr(*items: Expr) -> Call:
    return call("List", *items)


def head_of(expr: Expr) -> Expr:
    return expr.head()


def length(expr: Expr) -> int:
    return len(expr.args())


def depth(expr: Expr) -> int:
    if expr.is_atom():
        return 1
    return 1 + max(depth(argument) for argument in expr.args())


def part(expr: Expr, *specs: int | Expr) -> Expr:
    current = expr
    for spec in specs:
        normalized = integer(spec) if isinstance(spec, int) else spec
        current = _apply_part_spec(current, normalized)
    return current


def extract(expr: Expr, positions: Expr | Sequence[Expr | Sequence[int] | int]) -> Expr:
    if isinstance(positions, Expr):
        if _is_single_extract_position(positions):
            return part(expr, *_position_components_from_expr(positions))
        if isinstance(positions, Call) and positions.has_head("List"):
            return list_expr(*[part(expr, *_position_components_from_expr(item)) for item in positions.arguments])
        raise WolframEvaluationError("Extract positions must be a position list or a list of position lists.")

    extracted: list[Expr] = []
    for item in positions:
        if isinstance(item, Expr):
            extracted.append(part(expr, *_position_components_from_expr(item)))
            continue
        if isinstance(item, int):
            extracted.append(part(expr, item))
            continue
        extracted.append(part(expr, *item))
    return list_expr(*extracted)


def level(expr: Expr, spec: Expr | int | tuple[int, int] = 1) -> list[Expr]:
    records: list[_LevelRecord] = []
    _collect_levels(expr, 0, records)
    level_min, level_max = _normalize_level_spec(spec)
    return [record.expr for record in records if _level_matches(record, level_min, level_max)]


_MISSING = object()


def first(expr: Expr, default: Expr | object = _MISSING) -> Expr:
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take First of {expr.to_input_form()}.")


def last(expr: Expr, default: Expr | object = _MISSING) -> Expr:
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[-1]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take Last of {expr.to_input_form()}.")


def rest(expr: Expr) -> Expr:
    compound = _require_compound(expr, "Rest")
    if not compound.arguments:
        raise WolframEvaluationError(f"Cannot take Rest of {expr.to_input_form()} with length zero.")
    return _rebuild(compound, compound.arguments[1:])


def most(expr: Expr) -> Expr:
    compound = _require_compound(expr, "Most")
    if not compound.arguments:
        raise WolframEvaluationError(f"Cannot take Most of {expr.to_input_form()} with length zero.")
    return _rebuild(compound, compound.arguments[:-1])


def take(expr: Expr, *specs: Expr | int) -> Expr:
    compound = _require_compound(expr, "Take")
    if len(specs) != 1:
        raise WolframEvaluationError("Take currently supports exactly one specification.")
    return _take_or_drop(compound, specs, drop=False)


def drop(expr: Expr, *specs: Expr | int) -> Expr:
    compound = _require_compound(expr, "Drop")
    if len(specs) != 1:
        raise WolframEvaluationError("Drop currently supports exactly one specification.")
    return _take_or_drop(compound, specs, drop=True)


def append(expr: Expr, item: Expr) -> Expr:
    compound = _require_compound(expr, "Append")
    return _rebuild(compound, (*compound.arguments, item))


def prepend(expr: Expr, item: Expr) -> Expr:
    compound = _require_compound(expr, "Prepend")
    return _rebuild(compound, (item, *compound.arguments))


def join(*exprs: Expr) -> Expr:
    if not exprs:
        raise WolframEvaluationError("Join expects at least one expression.")

    compounds = [_require_compound(expr, "Join") for expr in exprs]
    head_expr = compounds[0].head_expr
    for compound in compounds[1:]:
        if compound.head_expr != head_expr:
            raise WolframEvaluationError("Join expects all expressions to have the same head.")

    arguments: list[Expr] = []
    for compound in compounds:
        arguments.extend(compound.arguments)
    return Call(head_expr=head_expr, arguments=tuple(arguments))


def reverse(expr: Expr) -> Expr:
    compound = _require_compound(expr, "Reverse")
    return _rebuild(compound, tuple(reversed(compound.arguments)))


def rotate_left(expr: Expr, amount: Expr | int = 1) -> Expr:
    compound = _require_compound(expr, "RotateLeft")
    if not compound.arguments:
        return compound

    count = len(compound.arguments)
    offset = _normalize_integer_argument(amount, "RotateLeft") % count
    if offset == 0:
        return compound
    return _rebuild(compound, compound.arguments[offset:] + compound.arguments[:offset])


def rotate_right(expr: Expr, amount: Expr | int = 1) -> Expr:
    return rotate_left(expr, -_normalize_integer_argument(amount, "RotateRight"))


def flatten(expr: Expr, level_spec: Expr | int | None = None) -> Expr:
    compound = _require_compound(expr, "Flatten")
    max_depth = _normalize_flatten_level(level_spec)
    if max_depth == 0:
        return compound
    return _flatten_same_head(compound, max_depth)


def delete(expr: Expr, positions: Expr | int) -> Expr:
    paths, invalid = _expand_position_spec(expr, integer(positions) if isinstance(positions, int) else positions)
    unique_paths = _dedupe_paths(paths)
    if invalid or any(not path for path in unique_paths):
        raise WolframEvaluationError(f"Delete positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(unique_paths):
        result, changed = _try_delete_at_path(result, path)
        if not changed:
            raise WolframEvaluationError(f"Delete positions are invalid for {expr.to_input_form()}.")
    return result


def replace_part(expr: Expr, replacements: Expr) -> Expr:
    rules = _normalize_replace_part_rules(replacements)
    planned: list[tuple[list[int], Expr]] = []
    seen_paths: set[tuple[int, ...]] = set()

    for position_spec, replacement in rules:
        paths, _invalid = _expand_position_spec(expr, position_spec)
        for path in paths:
            key = tuple(path)
            if key in seen_paths:
                continue
            seen_paths.add(key)
            planned.append((path, replacement))

    result = expr
    for path, replacement in _sort_path_items(planned):
        result, _changed = _try_replace_at_path(result, path, replacement)
    return result


def apply_head(new_head: Expr, expr: Expr) -> Expr:
    if not isinstance(expr, Call):
        return expr
    return Call(head_expr=new_head, arguments=expr.arguments)


def map_expr(function: Expr, expr: Expr) -> Expr:
    if not isinstance(expr, Call):
        return expr
    return _rebuild(expr, tuple(Call(head_expr=function, arguments=(argument,)) for argument in expr.arguments))


def map_at(function: Expr, expr: Expr, positions: Expr | int) -> Expr:
    paths, invalid = _expand_position_spec(expr, integer(positions) if isinstance(positions, int) else positions)
    if invalid:
        raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(paths):
        result, changed = _try_map_at_path(result, function, path)
        if not changed:
            raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")
    return result


def _require_compound(expr: Expr, function_name: str) -> Call:
    if isinstance(expr, Call):
        return expr
    raise WolframEvaluationError(f"{function_name} expects a nonatomic expression.")


def _rebuild(expr: Call, arguments: Sequence[Expr]) -> Call:
    return Call(head_expr=expr.head_expr, arguments=tuple(arguments))


def _normalize_integer_argument(value: Expr | int, function_name: str) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, Integer):
        return value.value
    raise WolframEvaluationError(f"{function_name} expects an integer argument.")


def _take_or_drop(expr: Call, specs: Sequence[Expr | int], *, drop: bool) -> Expr:
    function_name = "Drop" if drop else "Take"
    selectors = _normalize_take_drop_selectors(expr, specs[0], function_name)
    if drop:
        removed = {_resolve_index(len(expr.arguments), selector) for selector in selectors}
        current = _rebuild(
            expr,
            tuple(argument for index, argument in enumerate(expr.arguments) if index not in removed),
        )
    else:
        current = _rebuild(expr, tuple(_select_single_part(expr, selector) for selector in selectors))
    return current


def _normalize_take_drop_selectors(expr: Call, spec: Expr | int, function_name: str) -> list[int]:
    count = len(expr.arguments)

    if isinstance(spec, int):
        selectors = list(range(1, spec + 1)) if spec >= 0 else list(range(count + spec + 1, count + 1))
        return _validate_selectors(expr, selectors, function_name)

    if isinstance(spec, Integer):
        return _normalize_take_drop_selectors(expr, spec.value, function_name)

    if isinstance(spec, Symbol) and spec.name == "All":
        return list(range(1, count + 1))

    if isinstance(spec, Call) and spec.has_head("Span"):
        return _validate_selectors(expr, _expand_span_spec(expr, spec), function_name)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1:
            item = spec.arguments[0]
            if isinstance(item, Integer):
                return _validate_selectors(expr, [item.value], function_name)
            if isinstance(item, Symbol) and item.name == "All":
                return list(range(1, count + 1))
            raise WolframEvaluationError(f"{function_name} single-element list specifications must contain an integer or All.")
        if len(spec.arguments) in {2, 3}:
            return _validate_selectors(expr, _expand_span_spec(expr, Call(head_expr=Symbol("Span"), arguments=spec.arguments)), function_name)
        raise WolframEvaluationError(f"{function_name} list specifications must contain one, two, or three items.")

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _validate_selectors(expr: Call, selectors: Sequence[int], function_name: str) -> list[int]:
    for selector in selectors:
        _resolve_index(len(expr.arguments), selector)
    return list(selectors)


def _normalize_flatten_level(level_spec: Expr | int | None) -> int | None:
    if level_spec is None:
        return None
    if isinstance(level_spec, int):
        if level_spec < 0:
            raise WolframEvaluationError("Flatten levels must be non-negative.")
        return level_spec
    if isinstance(level_spec, Integer):
        return _normalize_flatten_level(level_spec.value)
    if isinstance(level_spec, Symbol) and level_spec.name == "Infinity":
        return None
    raise WolframEvaluationError("Flatten levels must be a non-negative integer or Infinity.")


def _flatten_same_head(expr: Call, remaining: int | None) -> Expr:
    if remaining == 0:
        return expr

    arguments: list[Expr] = []
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == expr.head_expr:
            nested = _flatten_same_head(argument, None if remaining is None else remaining - 1)
            assert isinstance(nested, Call)
            arguments.extend(nested.arguments)
            continue
        arguments.append(argument)
    return _rebuild(expr, arguments)


def _normalize_replace_part_rules(replacements: Expr) -> list[tuple[Expr, Expr]]:
    if isinstance(replacements, Call) and (replacements.has_head("Rule") or replacements.has_head("RuleDelayed")):
        if len(replacements.arguments) != 2:
            raise WolframEvaluationError("ReplacePart rules must contain exactly two arguments.")
        return [(replacements.arguments[0], replacements.arguments[1])]

    if isinstance(replacements, Call) and replacements.has_head("List"):
        rules: list[tuple[Expr, Expr]] = []
        for item in replacements.arguments:
            if not isinstance(item, Call) or (not item.has_head("Rule") and not item.has_head("RuleDelayed")) or len(item.arguments) != 2:
                raise WolframEvaluationError("ReplacePart expects a rule or a list of rules.")
            rules.append((item.arguments[0], item.arguments[1]))
        return rules

    raise WolframEvaluationError("ReplacePart expects a rule or a list of rules.")


def _expand_position_spec(expr: Expr, spec: Expr) -> tuple[list[list[int]], bool]:
    if isinstance(spec, Integer):
        if not isinstance(expr, Call):
            return ([], True)
        resolved = _try_resolve_index(len(expr.arguments), spec.value)
        if resolved is None:
            return ([], True)
        return ([[resolved + 1]], False)

    if isinstance(spec, Call) and spec.has_head("List") and _is_collection_of_position_specs(spec):
        paths: list[list[int]] = []
        invalid = False
        for item in spec.arguments:
            expanded, had_invalid = _expand_position_spec(expr, item)
            paths.extend(expanded)
            invalid = invalid or had_invalid
        return (paths, invalid)

    if isinstance(spec, Call) and spec.has_head("List") and all(_is_position_component(item) for item in spec.arguments):
        return _expand_position_components(expr, list(spec.arguments))

    if isinstance(spec, Call) and spec.has_head("List"):
        paths: list[list[int]] = []
        invalid = False
        for item in spec.arguments:
            expanded, had_invalid = _expand_position_spec(expr, item)
            paths.extend(expanded)
            invalid = invalid or had_invalid
        return (paths, invalid)

    raise WolframEvaluationError(f"Unsupported position specification: {spec.to_input_form()}.")


def _expand_position_components(expr: Expr, components: Sequence[Expr]) -> tuple[list[list[int]], bool]:
    if not components:
        return ([[]], False)

    if not isinstance(expr, Call):
        return ([], True)

    paths: list[list[int]] = []
    invalid = False
    selectors = _selectors_from_position_component(expr, components[0])
    for selector in selectors:
        resolved = _try_resolve_index(len(expr.arguments), selector)
        if resolved is None:
            invalid = True
            continue
        child_paths, child_invalid = _expand_position_components(expr.arguments[resolved], components[1:])
        invalid = invalid or child_invalid
        for child_path in child_paths:
            paths.append([resolved + 1, *child_path])
    return (paths, invalid)


def _selectors_from_position_component(expr: Call, component: Expr) -> list[int]:
    if isinstance(component, Integer):
        return [component.value]
    if isinstance(component, Symbol) and component.name == "All":
        return list(range(1, len(expr.arguments) + 1))
    if isinstance(component, Call) and component.has_head("Span"):
        return _expand_span_spec(expr, component)
    if isinstance(component, Call) and component.has_head("List"):
        return _expand_selector_list(expr, component.arguments)
    raise WolframEvaluationError(f"Unsupported position component: {component.to_input_form()}.")


def _is_position_component(expr: Expr) -> bool:
    return (
        isinstance(expr, Integer)
        or (isinstance(expr, Symbol) and expr.name == "All")
        or (isinstance(expr, Call) and expr.has_head("Span"))
        or (isinstance(expr, Call) and expr.has_head("List") and all(_is_selector_atom(item) for item in expr.arguments))
    )


def _is_collection_of_position_specs(expr: Call) -> bool:
    return bool(expr.arguments) and all(
        isinstance(item, Call) and item.has_head("List") and all(_is_position_component(component) for component in item.arguments)
        for item in expr.arguments
    )


def _is_selector_atom(expr: Expr) -> bool:
    return (
        isinstance(expr, Integer)
        or (isinstance(expr, Symbol) and expr.name == "All")
        or (isinstance(expr, Call) and expr.has_head("Span"))
    )


def _try_resolve_index(length_value: int, index: int) -> int | None:
    try:
        return _resolve_index(length_value, index)
    except WolframEvaluationError:
        return None


def _dedupe_paths(paths: Sequence[Sequence[int]]) -> list[list[int]]:
    seen: set[tuple[int, ...]] = set()
    unique: list[list[int]] = []
    for path in paths:
        key = tuple(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(list(path))
    return unique


def _sort_paths(paths: Sequence[Sequence[int]]) -> list[list[int]]:
    return [list(path) for path in sorted((tuple(path) for path in paths), key=lambda path: (len(path), path), reverse=True)]


def _sort_path_items(items: Sequence[tuple[Sequence[int], Expr]]) -> list[tuple[list[int], Expr]]:
    return [
        (list(path), value)
        for path, value in sorted(
            ((tuple(path), value) for path, value in items),
            key=lambda item: (len(item[0]), item[0]),
            reverse=True,
        )
    ]


def _try_delete_at_path(expr: Expr, path: Sequence[int]) -> tuple[Expr, bool]:
    if not path:
        return (expr, False)
    if not isinstance(expr, Call):
        return (expr, False)

    resolved = _try_resolve_index(len(expr.arguments), path[0])
    if resolved is None:
        return (expr, False)

    arguments = list(expr.arguments)
    if len(path) == 1:
        del arguments[resolved]
        return (_rebuild(expr, arguments), True)

    updated_child, changed = _try_delete_at_path(arguments[resolved], path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_replace_at_path(expr: Expr, path: Sequence[int], replacement: Expr) -> tuple[Expr, bool]:
    if not path:
        return (replacement, True)
    if not isinstance(expr, Call):
        return (expr, False)

    resolved = _try_resolve_index(len(expr.arguments), path[0])
    if resolved is None:
        return (expr, False)

    arguments = list(expr.arguments)
    updated_child, changed = _try_replace_at_path(arguments[resolved], path[1:], replacement)
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_map_at_path(expr: Expr, function: Expr, path: Sequence[int]) -> tuple[Expr, bool]:
    if not path:
        return (Call(head_expr=function, arguments=(expr,)), True)
    if not isinstance(expr, Call):
        return (expr, False)

    resolved = _try_resolve_index(len(expr.arguments), path[0])
    if resolved is None:
        return (expr, False)

    arguments = list(expr.arguments)
    updated_child, changed = _try_map_at_path(arguments[resolved], function, path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def evaluate(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    evaluated_head = evaluate(expr.head_expr)
    if not isinstance(evaluated_head, Symbol):
        return Call(head_expr=evaluated_head, arguments=tuple(evaluate(argument) for argument in expr.arguments))

    evaluated_arguments = tuple(evaluate(argument) for argument in expr.arguments)

    if evaluated_head.name == "Length":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Length expects exactly one argument.")
        return integer(length(evaluated_arguments[0]))

    if evaluated_head.name == "Depth":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Depth expects exactly one argument.")
        return integer(depth(evaluated_arguments[0]))

    if evaluated_head.name == "Head":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Head expects exactly one argument.")
        return head_of(evaluated_arguments[0])

    if evaluated_head.name == "First":
        if len(evaluated_arguments) == 1:
            return first(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return first(evaluated_arguments[0], default=evaluated_arguments[1])
        raise WolframEvaluationError("First expects an expression and an optional default.")

    if evaluated_head.name == "Last":
        if len(evaluated_arguments) == 1:
            return last(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return last(evaluated_arguments[0], default=evaluated_arguments[1])
        raise WolframEvaluationError("Last expects an expression and an optional default.")

    if evaluated_head.name == "Rest":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Rest expects exactly one argument.")
        return rest(evaluated_arguments[0])

    if evaluated_head.name == "Most":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Most expects exactly one argument.")
        return most(evaluated_arguments[0])

    if evaluated_head.name == "Part":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Part expects an expression and at least one part specification.")
        subject = evaluated_arguments[0]
        specs = evaluated_arguments[1:]
        return part(subject, *specs)

    if evaluated_head.name == "Extract":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Extract expects exactly two arguments.")
        subject = evaluated_arguments[0]
        positions = evaluated_arguments[1]
        return extract(subject, positions)

    if evaluated_head.name == "Level":
        if len(evaluated_arguments) not in {2, 3}:
            raise WolframEvaluationError("Level expects an expression, a level specification, and an optional heads flag.")
        subject = evaluated_arguments[0]
        spec = evaluated_arguments[1]
        if len(evaluated_arguments) == 3:
            heads = evaluated_arguments[2]
            if not isinstance(heads, Symbol) or heads.name not in {"True", "False"}:
                raise WolframEvaluationError("The optional third Level argument must be True or False.")
            if heads.name == "True":
                raise WolframEvaluationError("Level[..., ..., True] is not implemented yet.")
        return list_expr(*level(subject, spec))

    if evaluated_head.name == "Take":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Take currently supports exactly one specification.")
        return take(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Drop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Drop currently supports exactly one specification.")
        return drop(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Append":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Append expects exactly two arguments.")
        return append(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Prepend":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Prepend expects exactly two arguments.")
        return prepend(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Join":
        if len(evaluated_arguments) < 1:
            raise WolframEvaluationError("Join expects at least one argument.")
        return join(*evaluated_arguments)

    if evaluated_head.name == "Reverse":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Reverse currently supports exactly one argument.")
        return reverse(evaluated_arguments[0])

    if evaluated_head.name == "RotateLeft":
        if len(evaluated_arguments) == 1:
            return rotate_left(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return rotate_left(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("RotateLeft expects an expression and an optional integer offset.")

    if evaluated_head.name == "RotateRight":
        if len(evaluated_arguments) == 1:
            return rotate_right(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return rotate_right(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("RotateRight expects an expression and an optional integer offset.")

    if evaluated_head.name == "Flatten":
        if len(evaluated_arguments) == 1:
            return flatten(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return flatten(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Flatten currently supports an expression and an optional level specification.")

    if evaluated_head.name == "Delete":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Delete expects exactly two arguments.")
        return delete(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ReplacePart":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ReplacePart expects exactly two arguments.")
        return replace_part(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Apply":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Apply currently supports exactly two arguments.")
        return apply_head(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Map":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Map currently supports exactly two arguments.")
        return map_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "MapAt":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("MapAt currently supports exactly three arguments.")
        return map_at(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    return Call(head_expr=evaluated_head, arguments=evaluated_arguments)


def parse_expression(text: str, form: str = "input") -> Expr:
    normalized_form = form.strip().lower()
    if normalized_form not in {"input", "fullform", "full", "standard", "standardform"}:
        raise ValueError(f"Unsupported Wolfram expression form: {form!r}")

    parser = _Parser(text)
    expr = parser.parse()
    if normalized_form in {"standard", "standardform"}:
        return _interpret_standard_form(expr)
    return expr


def parse_input_form(text: str) -> Expr:
    return parse_expression(text, form="input")


def parse_full_form(text: str) -> Expr:
    return parse_expression(text, form="fullform")


def parse_standard_form(text: str) -> Expr:
    return parse_expression(text, form="standard")


_BOX_UNWRAP_HEADS = {
    "AdjustmentBox",
    "BoxData",
    "FormBox",
    "FrameBox",
    "PaneBox",
    "StyleBox",
    "TagBox",
    "TooltipBox",
}


def _interpret_standard_form(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    if expr.has_head("InterpretationBox") and len(expr.arguments) >= 2:
        return _interpret_standard_form(expr.arguments[1])

    if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _BOX_UNWRAP_HEADS and expr.arguments:
        return _interpret_standard_form(expr.arguments[0])

    if expr.has_head("RowBox"):
        return _interpret_row_box(expr)

    if expr.has_head("FractionBox"):
        return _interpret_fraction_box(expr)

    if expr.has_head("SqrtBox"):
        return _interpret_sqrt_box(expr)

    if expr.has_head("RadicalBox"):
        return _interpret_radical_box(expr)

    if expr.has_head("SuperscriptBox"):
        return _interpret_superscript_box(expr)

    return Call(
        head_expr=_interpret_standard_form(expr.head_expr),
        arguments=tuple(_interpret_standard_form(argument) for argument in expr.arguments),
    )


def _interpret_row_box(expr: Call) -> Expr:
    if len(expr.arguments) != 1:
        return expr

    items = expr.arguments[0]
    if not isinstance(items, Call) or not items.has_head("List"):
        return expr

    text = "".join(_box_item_to_standard_text(item) for item in items.arguments)
    stripped = text.strip()
    if not stripped:
        return string("")
    return parse_input_form(stripped)


def _interpret_fraction_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    numerator = _interpret_box_operand(expr.arguments[0])
    denominator = _interpret_box_operand(expr.arguments[1])
    return _make_division(numerator, denominator)


def _interpret_sqrt_box(expr: Call) -> Expr:
    if not expr.arguments:
        return expr
    radicand = _interpret_box_operand(expr.arguments[0])
    if _has_true_option(expr.arguments[1:], "SurdForm"):
        return call("Surd", radicand, integer(2))
    return call("Power", radicand, call("Rational", integer(1), integer(2)))


def _interpret_radical_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    radicand = _interpret_box_operand(expr.arguments[0])
    index = _interpret_box_operand(expr.arguments[1])
    if _has_true_option(expr.arguments[2:], "SurdForm"):
        return call("Surd", radicand, index)
    return call("Power", radicand, _make_division(integer(1), index))


def _interpret_superscript_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    base = _interpret_box_operand(expr.arguments[0])
    exponent = _interpret_box_operand(expr.arguments[1])
    return call("Power", base, exponent)


def _interpret_box_operand(expr: Expr) -> Expr:
    interpreted = _interpret_standard_form(expr)
    return _coerce_box_operand(interpreted)


def _coerce_box_operand(expr: Expr) -> Expr:
    if isinstance(expr, String):
        text = expr.value.strip()
        if not text:
            return string(expr.value)
        try:
            return _canonicalize_box_expression(parse_input_form(text))
        except WolframSyntaxError:
            return string(expr.value)

    return _canonicalize_box_expression(expr)


def _canonicalize_box_expression(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    normalized = call(
        _canonicalize_box_expression(expr.head_expr),
        *(_canonicalize_box_expression(argument) for argument in expr.arguments),
    )
    rational = _try_box_rational(normalized)
    if rational is not None:
        return rational
    return normalized


def _try_box_rational(expr: Call) -> Expr | None:
    if not expr.has_head("Times") or len(expr.arguments) != 2:
        return None

    numerator, denominator_power = expr.arguments
    if not isinstance(numerator, Integer):
        return None

    if (
        not isinstance(denominator_power, Call)
        or not denominator_power.has_head("Power")
        or len(denominator_power.arguments) != 2
    ):
        return None

    denominator, exponent = denominator_power.arguments
    if not isinstance(denominator, Integer):
        return None
    if not isinstance(exponent, Integer) or exponent.value != -1:
        return None

    return call("Rational", numerator, denominator)


def _box_item_to_standard_text(expr: Expr) -> str:
    if isinstance(expr, String):
        return _normalize_row_box_token(expr.value)

    if isinstance(expr, (Symbol, Integer, Real)):
        return expr.to_input_form()

    if isinstance(expr, Call):
        if expr.has_head("InterpretationBox") and len(expr.arguments) >= 2:
            return _interpret_standard_form(expr.arguments[1]).to_input_form()

        if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _BOX_UNWRAP_HEADS and expr.arguments:
            return _box_item_to_standard_text(expr.arguments[0])

        if expr.has_head("RowBox"):
            interpreted = _interpret_row_box(expr)
            return interpreted.to_input_form()

        if expr.has_head("FractionBox") and len(expr.arguments) >= 2:
            numerator = _box_item_to_standard_text(expr.arguments[0])
            denominator = _box_item_to_standard_text(expr.arguments[1])
            return f"(({numerator})/({denominator}))"

        if expr.has_head("SqrtBox") and expr.arguments:
            radicand = _box_item_to_standard_text(expr.arguments[0])
            if _has_true_option(expr.arguments[1:], "SurdForm"):
                return f"Surd[{radicand}, 2]"
            return f"(({radicand})^(1/2))"

        if expr.has_head("RadicalBox") and len(expr.arguments) >= 2:
            radicand = _box_item_to_standard_text(expr.arguments[0])
            index = _box_item_to_standard_text(expr.arguments[1])
            if _has_true_option(expr.arguments[2:], "SurdForm"):
                return f"Surd[{radicand}, {index}]"
            return f"(({radicand})^(1/({index})))"

        if expr.has_head("SuperscriptBox") and len(expr.arguments) >= 2:
            base = _box_item_to_standard_text(expr.arguments[0])
            exponent = _box_item_to_standard_text(expr.arguments[1])
            return f"(({base})^({exponent}))"

    return _interpret_standard_form(expr).to_input_form()


def _normalize_row_box_token(value: str) -> str:
    whitespace_tokens = {
        " ",
        "\t",
        "\n",
        r"\[InvisibleSpace]",
        r"\[InvisibleTimes]",
        r"\[NegativeMediumSpace]",
        r"\[NegativeThickSpace]",
        r"\[NegativeThinSpace]",
        r"\[NegativeVeryThinSpace]",
        r"\[NoBreak]",
        r"\[ThickSpace]",
        r"\[ThinSpace]",
        r"\[VeryThinSpace]",
    }
    if value in whitespace_tokens:
        return " "
    return value


def _make_division(numerator: Expr, denominator: Expr) -> Expr:
    if isinstance(numerator, Integer) and isinstance(denominator, Integer):
        return call("Rational", numerator, denominator)

    if isinstance(numerator, Integer) and numerator.value == 1:
        return call("Power", denominator, integer(-1))

    return call("Times", numerator, call("Power", denominator, integer(-1)))


def _has_true_option(arguments: Sequence[Expr], name: str) -> bool:
    for argument in arguments:
        if not isinstance(argument, Call):
            continue
        if not argument.has_head("Rule") and not argument.has_head("RuleDelayed"):
            continue
        if len(argument.arguments) != 2:
            continue
        option_name, option_value = argument.arguments
        if not isinstance(option_name, Symbol) or option_name.name != name:
            continue
        interpreted = _interpret_standard_form(option_value)
        if isinstance(interpreted, Symbol) and interpreted.name == "True":
            return True
    return False


@dataclass(frozen=True)
class _Token:
    kind: str
    text: str
    start: int
    end: int
    value: object | None = None


def _skip_string(text: str, index: int) -> int:
    index += 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "\"":
            return index + 1
        index += 1
    return index


def _skip_comment(text: str, index: int) -> int:
    depth = 1
    index += 2
    while index < len(text) and depth > 0:
        if text.startswith("(*", index):
            depth += 1
            index += 2
            continue
        if text.startswith("*)", index):
            depth -= 1
            index += 2
            continue
        if text[index] == "\"":
            index = _skip_string(text, index)
            continue
        index += 1
    return index


def _scan_string(text: str, start: int) -> tuple[_Token, int]:
    end = _skip_string(text, start)
    if end == len(text) and (not text or text[end - 1] != "\""):
        raise WolframSyntaxError("Unterminated Wolfram string literal.")
    raw = text[start:end]
    return _Token(kind="string", text=raw, start=start, end=end, value=parse_wl_string_literal(raw)), end


def _scan_number(text: str, start: int) -> tuple[_Token, int]:
    index = start
    saw_digits = False

    while index < len(text) and text[index].isdigit():
        saw_digits = True
        index += 1

    saw_dot = False
    if index < len(text) and text[index] == "." and index + 1 < len(text) and text[index + 1].isdigit():
        saw_dot = True
        index += 1
        while index < len(text) and text[index].isdigit():
            index += 1
    elif index < len(text) and text[index] == "." and saw_digits:
        saw_dot = True
        index += 1

    if index < len(text) and text[index] == "`":
        index += 1
        while index < len(text) and (text[index].isdigit() or text[index] == "."):
            index += 1

    if text.startswith("*^", index):
        saw_dot = True
        index += 2
        if index < len(text) and text[index] in "+-":
            index += 1
        exponent_start = index
        while index < len(text) and text[index].isdigit():
            index += 1
        if exponent_start == index:
            raise WolframSyntaxError("Malformed Wolfram numeric exponent.")

    token_text = text[start:index]
    if not token_text or token_text == ".":
        raise WolframSyntaxError(f"Malformed Wolfram number near {text[start:start + 8]!r}.")

    if not saw_dot and "`" not in token_text and "*^" not in token_text:
        return _Token(kind="integer", text=token_text, start=start, end=index, value=int(token_text)), index
    return _Token(kind="real", text=token_text, start=start, end=index, value=token_text), index


def _is_symbol_start(char: str) -> bool:
    return char.isalpha() or char in {"$", "`"}


def _is_symbol_continue(char: str) -> bool:
    return char.isalnum() or char in {"$", "`"}


_MULTI_TOKENS = (
    "[[",
    "<|",
    "|>",
    ":>",
    "->",
    "//.",
    "//@",
    "//",
    "/@",
    "/.",
    "@@@",
    "@@",
    "<=",
    ">=",
    "==",
    "!=",
    "&&",
    "||",
    ";;",
)


def _tokenize(text: str) -> list[_Token]:
    tokens: list[_Token] = []
    index = 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        if text.startswith("(*", index):
            index = _skip_comment(text, index)
            continue
        if text[index] == "\"":
            token, index = _scan_string(text, index)
            tokens.append(token)
            continue
        if text[index].isdigit() or (text[index] == "." and index + 1 < len(text) and text[index + 1].isdigit()):
            token, index = _scan_number(text, index)
            tokens.append(token)
            continue
        if _is_symbol_start(text[index]):
            start = index
            index += 1
            while index < len(text) and _is_symbol_continue(text[index]):
                index += 1
            token_text = text[start:index]
            tokens.append(_Token(kind="symbol", text=token_text, start=start, end=index, value=token_text))
            continue

        matched = False
        for candidate in _MULTI_TOKENS:
            if text.startswith(candidate, index):
                tokens.append(_Token(kind="operator", text=candidate, start=index, end=index + len(candidate), value=candidate))
                index += len(candidate)
                matched = True
                break
        if matched:
            continue

        char = text[index]
        if char in "[]{}(),+-*/^!@<>":
            tokens.append(_Token(kind="operator", text=char, start=index, end=index + 1, value=char))
            index += 1
            continue

        raise WolframSyntaxError(f"Unexpected Wolfram syntax character {char!r} at offset {index}.")

    tokens.append(_Token(kind="eof", text="", start=len(text), end=len(text)))
    return tokens


class _Parser:
    _PART_BP = 190
    _CALL_BP = 190
    _POWER_BP = 160
    _TIMES_BP = 140
    _PLUS_BP = 120
    _COMPARE_BP = 100
    _AND_BP = 80
    _OR_BP = 70
    _RULE_BP = 60
    _REPLACE_BP = 50
    _MAP_BP = 45
    _APPLY_BP = 44
    _AT_BP = 40
    _POSTFIX_BP = 30
    _SEMICOLON_BP = 20
    _SPAN_BP = 170
    _PREFIX_BP = 150

    def __init__(self, text: str) -> None:
        self.text = text
        self.tokens = _tokenize(text)
        self.index = 0

    def parse(self) -> Expr:
        expr = self._parse_expression(0, terminators={"eof"})
        self._expect("eof")
        return expr

    def _peek(self) -> _Token:
        return self.tokens[self.index]

    def _consume(self) -> _Token:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def _match(self, *values: str) -> _Token | None:
        token = self._peek()
        if token.text in values or token.kind in values:
            self.index += 1
            return token
        return None

    def _expect(self, value: str) -> _Token:
        token = self._peek()
        if token.text == value or token.kind == value:
            self.index += 1
            return token
        raise WolframSyntaxError(f"Expected {value!r}, found {token.text!r} at offset {token.start}.")

    def _parse_expression(self, min_bp: int, terminators: set[str]) -> Expr:
        token = self._peek()
        if token.text in terminators or token.kind in terminators:
            raise WolframSyntaxError(f"Unexpected {token.text!r} at offset {token.start}.")

        left = self._parse_prefix(terminators)

        while True:
            token = self._peek()
            if token.text in terminators or token.kind in terminators or token.kind == "eof":
                break

            if token.text == "[":
                if self._CALL_BP < min_bp:
                    break
                self._consume()
                arguments = self._parse_sequence("]")
                self._expect("]")
                left = Call(head_expr=left, arguments=tuple(arguments))
                continue

            if token.text == "[[":
                if self._PART_BP < min_bp:
                    break
                self._consume()
                specs = self._parse_sequence("]")
                self._expect("]")
                self._expect("]")
                left = call("Part", left, *specs)
                continue

            if token.text == ";;":
                if self._SPAN_BP < min_bp:
                    break
                left = self._parse_infix_span(left, min_bp, terminators)
                continue

            if self._starts_primary(token):
                if self._TIMES_BP < min_bp:
                    break
                right = self._parse_expression(self._TIMES_BP + 1, terminators)
                left = call("Times", left, right)
                continue

            handled = self._parse_infix_operator(left, min_bp, terminators)
            if handled is None:
                break
            left = handled

        return left

    def _parse_prefix(self, terminators: set[str]) -> Expr:
        token = self._consume()

        if token.kind == "integer":
            return integer(int(token.value))

        if token.kind == "real":
            return real(str(token.value))

        if token.kind == "string":
            return string(str(token.value))

        if token.kind == "symbol":
            return symbol(str(token.value))

        if token.text == "(":
            expr = self._parse_expression(0, terminators={")"})
            self._expect(")")
            return expr

        if token.text == "{":
            items = self._parse_sequence("}")
            self._expect("}")
            return list_expr(*items)

        if token.text == "<|":
            items = self._parse_sequence("|>")
            self._expect("|>")
            return call("Association", *items)

        if token.text == "+":
            return self._parse_expression(self._PREFIX_BP, terminators)

        if token.text == "-":
            operand = self._parse_expression(self._PREFIX_BP, terminators)
            if isinstance(operand, Integer):
                return integer(-operand.value)
            if isinstance(operand, Real):
                if operand.text.startswith("-"):
                    return real(operand.text[1:])
                return real(f"-{operand.text}")
            return call("Times", integer(-1), operand)

        if token.text == "!":
            return call("Not", self._parse_expression(self._PREFIX_BP, terminators))

        if token.text == ";;":
            return self._parse_prefix_span(terminators)

        raise WolframSyntaxError(f"Unexpected token {token.text!r} at offset {token.start}.")

    def _parse_sequence(self, end_token: str) -> list[Expr]:
        items: list[Expr] = []
        if self._peek().text == end_token:
            return items

        while True:
            items.append(self._parse_expression(0, terminators={",", end_token}))
            if self._match(",") is None:
                break
        return items

    def _starts_primary(self, token: _Token) -> bool:
        return token.kind in {"integer", "real", "string", "symbol"} or token.text in {"(", "{", "<|"}

    def _parse_infix_span(self, left: Expr, min_bp: int, terminators: set[str]) -> Expr:
        del min_bp
        self._expect(";;")
        end = self._parse_span_argument(default=symbol("All"), terminators=terminators)
        if self._match(";;") is not None:
            step = self._parse_span_argument(default=integer(1), terminators=terminators)
            return call("Span", left, end, step)
        return call("Span", left, end)

    def _parse_prefix_span(self, terminators: set[str]) -> Expr:
        end = self._parse_span_argument(default=symbol("All"), terminators=terminators)
        if self._match(";;") is not None:
            step = self._parse_span_argument(default=integer(1), terminators=terminators)
            return call("Span", integer(1), end, step)
        return call("Span", integer(1), end)

    def _parse_span_argument(self, *, default: Expr, terminators: set[str]) -> Expr:
        token = self._peek()
        if token.kind == "eof" or token.text in terminators or token.text in {",", "]", "]]", "}", "|>"}:
            return default
        return self._parse_expression(self._SPAN_BP, terminators | {",", "]", "]]", "}", "|>"})

    def _parse_infix_operator(self, left: Expr, min_bp: int, terminators: set[str]) -> Expr | None:
        del terminators
        token = self._peek()
        text = token.text

        binary_specs: dict[str, tuple[int, int, str | None]] = {
            "^": (self._POWER_BP, self._POWER_BP, "Power"),
            "*": (self._TIMES_BP, self._TIMES_BP + 1, "Times"),
            "/": (self._TIMES_BP, self._TIMES_BP + 1, None),
            "+": (self._PLUS_BP, self._PLUS_BP + 1, "Plus"),
            "-": (self._PLUS_BP, self._PLUS_BP + 1, None),
            "==": (self._COMPARE_BP, self._COMPARE_BP + 1, "Equal"),
            "!=": (self._COMPARE_BP, self._COMPARE_BP + 1, "Unequal"),
            "<": (self._COMPARE_BP, self._COMPARE_BP + 1, "Less"),
            "<=": (self._COMPARE_BP, self._COMPARE_BP + 1, "LessEqual"),
            ">": (self._COMPARE_BP, self._COMPARE_BP + 1, "Greater"),
            ">=": (self._COMPARE_BP, self._COMPARE_BP + 1, "GreaterEqual"),
            "&&": (self._AND_BP, self._AND_BP + 1, "And"),
            "||": (self._OR_BP, self._OR_BP + 1, "Or"),
            "->": (self._RULE_BP, self._RULE_BP, "Rule"),
            ":>": (self._RULE_BP, self._RULE_BP, "RuleDelayed"),
            "/.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceAll"),
            "//.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceRepeated"),
            "/@": (self._MAP_BP, self._MAP_BP + 1, "Map"),
            "//@": (self._MAP_BP, self._MAP_BP + 1, "MapAll"),
            "@@": (self._APPLY_BP, self._APPLY_BP + 1, "Apply"),
            "@@@": (self._APPLY_BP, self._APPLY_BP + 1, None),
            "@": (self._AT_BP, self._AT_BP, None),
            "//": (self._POSTFIX_BP, self._POSTFIX_BP + 1, None),
            ";": (self._SEMICOLON_BP, self._SEMICOLON_BP + 1, "CompoundExpression"),
        }

        spec = binary_specs.get(text)
        if spec is None:
            return None

        left_bp, right_bp, head_name = spec
        if left_bp < min_bp:
            return None

        self._consume()
        right = self._parse_expression(right_bp, terminators={"eof", ",", "]", "]]", "}", "|>"})

        if text == "/":
            return call("Times", left, call("Power", right, integer(-1)))
        if text == "-":
            return call("Plus", left, call("Times", integer(-1), right))
        if text == "@":
            return Call(head_expr=left, arguments=(right,))
        if text == "//":
            return Call(head_expr=right, arguments=(left,))
        if text == "@@@":
            return call("Apply", left, right, list_expr(integer(1)))
        if head_name is None:
            raise WolframSyntaxError(f"Unhandled Wolfram operator {text!r}.")
        return call(head_name, left, right)


def _apply_part_spec(expr: Expr, spec: Expr) -> Expr:
    if isinstance(spec, Integer):
        return _select_single_part(expr, spec.value)

    if isinstance(spec, Symbol) and spec.name == "All":
        if expr.is_atom():
            raise WolframEvaluationError("Part specification All cannot be applied to an atom.")
        return Call(head_expr=head_of(expr), arguments=expr.args())

    if isinstance(spec, Call) and spec.has_head("Span"):
        return _select_multiple_parts(expr, _expand_span_spec(expr, spec))

    if isinstance(spec, Call) and spec.has_head("List"):
        selectors = _expand_selector_list(expr, spec.arguments)
        return _select_multiple_parts(expr, selectors)

    raise WolframEvaluationError(f"Unsupported Part specification: {spec.to_input_form()}.")


def _select_single_part(expr: Expr, index: int) -> Expr:
    if index == 0:
        return head_of(expr)

    arguments = expr.args()
    if not arguments:
        raise WolframEvaluationError("Part specification is deeper than the expression.")

    resolved = _resolve_index(len(arguments), index)
    return arguments[resolved]


def _select_multiple_parts(expr: Expr, selectors: Sequence[int]) -> Expr:
    if expr.is_atom():
        raise WolframEvaluationError("Cannot extract multiple parts from an atom.")

    extracted = tuple(_select_single_part(expr, selector) for selector in selectors)
    return Call(head_expr=head_of(expr), arguments=extracted)


def _resolve_index(length_value: int, index: int) -> int:
    if index > 0:
        resolved = index - 1
    elif index < 0:
        resolved = length_value + index
    else:
        raise WolframEvaluationError("Only top-level Part specifications may use index 0.")

    if not 0 <= resolved < length_value:
        raise WolframEvaluationError(f"Part index {index} is out of range for length {length_value}.")
    return resolved


def _expand_selector_list(expr: Expr, items: Iterable[Expr]) -> list[int]:
    selectors: list[int] = []
    for item in items:
        if isinstance(item, Integer):
            selectors.append(item.value)
            continue
        if isinstance(item, Symbol) and item.name == "All":
            selectors.extend(range(1, length(expr) + 1))
            continue
        if isinstance(item, Call) and item.has_head("Span"):
            selectors.extend(_expand_span_spec(expr, item))
            continue
        raise WolframEvaluationError(f"Unsupported selector inside list Part specification: {item.to_input_form()}.")
    return selectors


def _expand_span_spec(expr: Expr, span: Call) -> list[int]:
    if expr.is_atom():
        raise WolframEvaluationError("Span cannot be applied to an atom.")

    if len(span.arguments) not in {2, 3}:
        raise WolframEvaluationError("Span must contain two or three arguments.")

    start_expr = span.arguments[0]
    end_expr = span.arguments[1]
    step_expr = span.arguments[2] if len(span.arguments) == 3 else integer(1)

    count = length(expr)
    start = _span_endpoint_value(start_expr, count, default=1)
    end = _span_endpoint_value(end_expr, count, default=count)
    step = _span_step_value(step_expr)

    if step == 0:
        raise WolframEvaluationError("Span step cannot be zero.")

    stop = end + (1 if step > 0 else -1)
    return list(range(start, stop, step))


def _span_endpoint_value(expr: Expr, length_value: int, *, default: int) -> int:
    if isinstance(expr, Symbol) and expr.name == "All":
        return length_value
    if isinstance(expr, Integer):
        value = expr.value
        if value < 0:
            return length_value + value + 1
        return value
    return default


def _span_step_value(expr: Expr) -> int:
    if isinstance(expr, Integer):
        return expr.value
    raise WolframEvaluationError("Span steps must be integers.")


def _is_single_extract_position(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("List") and all(
        isinstance(item, Integer) or (isinstance(item, Call) and item.has_head("Span")) or (isinstance(item, Symbol) and item.name == "All")
        for item in expr.arguments
    )


def _position_components_from_expr(expr: Expr) -> list[Expr]:
    if isinstance(expr, Integer):
        return [expr]
    if isinstance(expr, Call) and expr.has_head("List"):
        return list(expr.arguments)
    raise WolframEvaluationError(f"Expected a Wolfram position list, got {expr.to_input_form()}.")


@dataclass(frozen=True)
class _LevelRecord:
    expr: Expr
    positive_level: int
    negative_level: int


def _collect_levels(expr: Expr, positive_level: int, target: list[_LevelRecord]) -> None:
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))
    if isinstance(expr, Call):
        for argument in expr.arguments:
            _collect_levels(argument, positive_level + 1, target)


def _normalize_level_spec(spec: Expr | int | tuple[int, int]) -> tuple[int, int]:
    if isinstance(spec, int):
        if spec >= 0:
            return (0 if spec == 0 else 1, spec)
        return (spec, -1)

    if isinstance(spec, tuple):
        if len(spec) != 2:
            raise WolframEvaluationError("Python tuple level specifications must contain exactly two integers.")
        return spec

    if isinstance(spec, Integer):
        return _normalize_level_spec(spec.value)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1 and isinstance(spec.arguments[0], Integer):
            value = spec.arguments[0].value
            return (value, value)
        if len(spec.arguments) == 2 and all(isinstance(item, Integer) for item in spec.arguments):
            return (spec.arguments[0].value, spec.arguments[1].value)

    raise WolframEvaluationError(f"Unsupported Level specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _level_matches(record: _LevelRecord, level_min: int, level_max: int) -> bool:
    return (
        level_min <= record.positive_level <= level_max
        or level_min <= record.negative_level <= level_max
    )
