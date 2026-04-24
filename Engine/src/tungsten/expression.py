from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence

from .wolfram_strings import has_inline_boxes
from .wolfram_strings import inline_box_segments
from .wolfram_strings import parse_wl_string_literal
from .wolfram_strings import skip_wl_comment
from .wolfram_strings import skip_wl_string
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

    def is_atom(self) -> bool:
        return False

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


_FLAT_HEADS = {"Plus", "Times", "And", "Or", "Alternatives"}

_LEVEL_INFINITY = 1_000_000_000


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


@dataclass(frozen=True)
class _AssociationEntry:
    rule_head: str
    key: Expr
    value: Expr

    def to_expr(self) -> Expr:
        return call(self.rule_head, self.key, self.value)


@dataclass(frozen=True)
class _IndexSelector:
    index: int


@dataclass(frozen=True)
class _KeySelector:
    key: Expr


@dataclass(frozen=True)
class _SelectedPart:
    selector: _IndexSelector | _KeySelector
    child: Expr
    entry: _AssociationEntry | None = None


def _rule_entry(expr: Expr) -> _AssociationEntry | None:
    if not isinstance(expr, Call):
        return None
    if not expr.has_head("Rule") and not expr.has_head("RuleDelayed"):
        return None
    if len(expr.arguments) != 2:
        return None
    return _AssociationEntry(
        rule_head=expr.head_expr.name,
        key=expr.arguments[0],
        value=expr.arguments[1],
    )


def _association_entries(expr: Expr) -> tuple[_AssociationEntry, ...] | None:
    if not isinstance(expr, Call) or not expr.has_head("Association"):
        return None

    entries: list[_AssociationEntry] = []
    for argument in expr.arguments:
        entry = _rule_entry(argument)
        if entry is None:
            return None
        entries.append(entry)
    return tuple(entries)


def _is_association(expr: Expr) -> bool:
    return _association_entries(expr) is not None


def _normalize_association_entries(entries: Iterable[_AssociationEntry]) -> tuple[_AssociationEntry, ...]:
    ordered: list[_AssociationEntry | None] = []
    last_positions: dict[Expr, int] = {}

    for entry in entries:
        previous = last_positions.get(entry.key)
        if previous is not None:
            ordered[previous] = None
        last_positions[entry.key] = len(ordered)
        ordered.append(entry)

    return tuple(entry for entry in ordered if entry is not None)


def _association_expr(entries: Iterable[_AssociationEntry]) -> Call:
    normalized = _normalize_association_entries(entries)
    return call("Association", *(entry.to_expr() for entry in normalized))


def _association_entry_map(entries: Sequence[_AssociationEntry]) -> dict[Expr, _AssociationEntry]:
    return {entry.key: entry for entry in entries}


def _association_values(expr: Expr) -> tuple[Expr, ...]:
    entries = _association_entries(expr)
    if entries is None:
        raise WolframEvaluationError(f"Expected an association, got {expr.to_input_form()}.")
    return tuple(entry.value for entry in entries)


def _association_from_arguments(arguments: Sequence[Expr]) -> Call | None:
    entries: list[_AssociationEntry] = []

    if len(arguments) == 1:
        source = arguments[0]
        nested_entries = _association_entries(source)
        if nested_entries is not None:
            return _association_expr(nested_entries)
        if isinstance(source, Call) and source.has_head("List"):
            for item in source.arguments:
                entry = _rule_entry(item)
                if entry is None:
                    return None
                entries.append(entry)
            return _association_expr(entries)

    for argument in arguments:
        nested_entries = _association_entries(argument)
        if nested_entries is not None:
            entries.extend(nested_entries)
            continue
        entry = _rule_entry(argument)
        if entry is None:
            return None
        entries.append(entry)

    return _association_expr(entries)


def _bool_symbol(value: bool) -> Symbol:
    return symbol("True" if value else "False")


_UNSUPPORTED_PATTERN_HEADS = {
    "BlankNullSequence",
    "BlankSequence",
    "Condition",
    "Longest",
    "OptionsPattern",
    "Optional",
    "PatternTest",
    "Repeated",
    "RepeatedNull",
    "Shortest",
}


def _unsupported_pattern(expr: Expr) -> WolframEvaluationError:
    return WolframEvaluationError(
        f"Unsupported Wolfram pattern form in the current Tungsten subset: {expr.to_input_form()}."
    )


def _match_pattern(
    expr: Expr,
    pattern: Expr,
    bindings: dict[str, Expr] | None = None,
) -> dict[str, Expr] | None:
    current = {} if bindings is None else dict(bindings)

    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name

        if head_name in _UNSUPPORTED_PATTERN_HEADS:
            raise _unsupported_pattern(pattern)

        if head_name == "HoldPattern":
            if len(pattern.arguments) != 1:
                raise WolframEvaluationError("HoldPattern expects exactly one argument.")
            return _match_pattern(expr, pattern.arguments[0], current)

        if head_name == "Verbatim":
            if len(pattern.arguments) != 1:
                raise WolframEvaluationError("Verbatim expects exactly one argument.")
            return current if expr == pattern.arguments[0] else None

        if head_name == "Except":
            if len(pattern.arguments) == 1:
                return current if _match_pattern(expr, pattern.arguments[0], current) is None else None
            if len(pattern.arguments) == 2:
                allowed = _match_pattern(expr, pattern.arguments[1], current)
                if allowed is None:
                    return None
                return allowed if _match_pattern(expr, pattern.arguments[0], current) is None else None
            raise WolframEvaluationError("Except expects one or two arguments.")

        if head_name == "Alternatives":
            if not pattern.arguments:
                return None
            for branch in pattern.arguments:
                matched = _match_pattern(expr, branch, current)
                if matched is not None:
                    return matched
            return None

        if head_name == "Pattern":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            matched = _match_pattern(expr, inner_pattern, current)
            if matched is None:
                return None
            bound = matched.get(name_expr.name)
            if bound is not None:
                return matched if bound == expr else None
            matched[name_expr.name] = expr
            return matched

        if head_name == "Blank":
            if len(pattern.arguments) == 0:
                return current
            if len(pattern.arguments) == 1:
                return _match_pattern(head_of(expr), pattern.arguments[0], current)
            raise WolframEvaluationError("Blank expects zero or one argument.")

    if isinstance(pattern, Call):
        if not isinstance(expr, Call):
            return None
        if len(expr.arguments) != len(pattern.arguments):
            return None
        matched = _match_pattern(head_of(expr), pattern.head_expr, current)
        if matched is None:
            return None
        for candidate_arg, pattern_arg in zip(expr.arguments, pattern.arguments, strict=True):
            matched = _match_pattern(candidate_arg, pattern_arg, matched)
            if matched is None:
                return None
        return matched

    return current if expr == pattern else None


def match_q(expr: Expr, pattern: Expr) -> Symbol:
    return _bool_symbol(_match_pattern(expr, pattern) is not None)


@dataclass(frozen=True)
class _PatternRecord:
    expr: Expr
    positive_level: int


def _collect_pattern_records(
    expr: Expr,
    positive_level: int,
    target: list[_PatternRecord],
    *,
    heads: bool,
) -> None:
    if _is_association(expr):
        target.append(_PatternRecord(expr=expr, positive_level=positive_level))
        return

    if isinstance(expr, Call):
        if heads:
            _collect_pattern_records(expr.head_expr, positive_level + 1, target, heads=heads)
        for argument in expr.arguments:
            _collect_pattern_records(argument, positive_level + 1, target, heads=heads)

    target.append(_PatternRecord(expr=expr, positive_level=positive_level))


def _level_in_range(level_value: int, level_min: int, level_max: int) -> bool:
    return level_min <= level_value <= level_max


def free_q(expr: Expr, pattern: Expr, spec: Expr | int | tuple[int, int] | None = None) -> Symbol:
    level_spec = list_expr(integer(0), symbol("Infinity")) if spec is None else spec
    records: list[_PatternRecord] = []
    _collect_pattern_records(expr, 0, records, heads=True)
    level_min, level_max = _normalize_level_spec(level_spec)
    for record in records:
        if not _level_in_range(record.positive_level, level_min, level_max):
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


def _cases_pattern_spec(spec: Expr) -> tuple[Expr, Expr | None]:
    if isinstance(spec, Call) and spec.has_head("Rule"):
        if len(spec.arguments) != 2:
            raise WolframEvaluationError("Cases transformation rules must contain exactly two arguments.")
        return spec.arguments[0], evaluate(spec.arguments[1])
    if isinstance(spec, Call) and spec.has_head("RuleDelayed"):
        if len(spec.arguments) != 2:
            raise WolframEvaluationError("Cases transformation rules must contain exactly two arguments.")
        return spec.arguments[0], spec.arguments[1]
    return spec, None


def _substitute_pattern_bindings(expr: Expr, bindings: dict[str, Expr]) -> Expr:
    if isinstance(expr, Symbol):
        return bindings.get(expr.name, expr)
    if isinstance(expr, (Integer, Real, String)):
        return expr
    if not isinstance(expr, Call):
        return expr

    if expr.has_head("Pattern") and len(expr.arguments) == 2 and isinstance(expr.arguments[0], Symbol):
        return call(
            _substitute_pattern_bindings(expr.head_expr, bindings),
            expr.arguments[0],
            _substitute_pattern_bindings(expr.arguments[1], bindings),
        )

    return call(
        _substitute_pattern_bindings(expr.head_expr, bindings),
        *(_substitute_pattern_bindings(argument, bindings) for argument in expr.arguments),
    )


def cases(
    expr: Expr,
    pattern_spec: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
) -> Call:
    level_spec = integer(1) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)
    remaining = _normalize_match_limit(limit)
    pattern, template = _cases_pattern_spec(pattern_spec)

    records: list[_PatternRecord] = []
    _collect_pattern_records(expr, 0, records, heads=False)

    results: list[Expr] = []
    for record in records:
        if remaining == 0:
            break
        if not _level_in_range(record.positive_level, level_min, level_max):
            continue
        bindings = _match_pattern(record.expr, pattern)
        if bindings is None:
            continue
        if template is None:
            results.append(record.expr)
        else:
            results.append(evaluate(_substitute_pattern_bindings(template, bindings)))
        if remaining is not None:
            remaining -= 1

    return list_expr(*results)


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
    if _is_association(expr):
        if _level_in_range(positive_level, level_min, level_max) and remaining[0] != 0:
            if _match_pattern(expr, pattern) is not None:
                if positive_level == 0:
                    return _DELETE_SENTINEL
                if remaining[0] is not None:
                    remaining[0] -= 1
                return _DELETE_SENTINEL
        return expr

    if isinstance(expr, Call):
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

    if _level_in_range(positive_level, level_min, level_max) and _match_pattern(rebuilt, pattern) is not None:
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


def head_of(expr: Expr) -> Expr:
    return expr.head()


def length(expr: Expr) -> int:
    return len(expr.args())


def depth(expr: Expr) -> int:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return 2
        return 1 + max(depth(entry.value) for entry in entries)

    if not isinstance(expr, Call):
        return 1

    if not expr.arguments:
        return 2
    return 1 + max(depth(argument) for argument in expr.arguments)


def part(expr: Expr, *specs: int | Expr) -> Expr:
    normalized = tuple(integer(spec) if isinstance(spec, int) else spec for spec in specs)
    if not normalized:
        return expr
    return _part_recursive(expr, normalized)


def extract(expr: Expr, positions: Expr | Sequence[Expr | Sequence[int] | int]) -> Expr:
    if isinstance(positions, Expr):
        if _is_collection_of_position_specs(positions):
            return list_expr(*[part(expr, *_position_components_from_expr(item)) for item in positions.arguments])
        if _is_single_position_spec_expr(positions):
            return part(expr, *_position_components_from_expr(positions))
        raise WolframEvaluationError("Extract positions must be a position list or a list of position lists.")

    extracted: list[Expr] = []
    for item in positions:
        if isinstance(item, Expr):
            if _is_collection_of_position_specs(item):
                extracted.extend(part(expr, *_position_components_from_expr(child)) for child in item.arguments)
            else:
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
    entries = _association_entries(expr)
    if entries is not None and entries:
        return entries[0].value
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take First of {expr.to_input_form()}.")


def last(expr: Expr, default: Expr | object = _MISSING) -> Expr:
    entries = _association_entries(expr)
    if entries is not None and entries:
        return entries[-1].value
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[-1]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take Last of {expr.to_input_form()}.")


def rest(expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            raise WolframEvaluationError(f"Cannot take Rest of {expr.to_input_form()} with length zero.")
        return _association_expr(entries[1:])

    compound = _require_compound(expr, "Rest")
    if not compound.arguments:
        raise WolframEvaluationError(f"Cannot take Rest of {expr.to_input_form()} with length zero.")
    return _rebuild(compound, compound.arguments[1:])


def most(expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            raise WolframEvaluationError(f"Cannot take Most of {expr.to_input_form()} with length zero.")
        return _association_expr(entries[:-1])

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
    entries = _association_entries(expr)
    if entries is not None:
        entry = _rule_entry(item)
        if entry is None:
            raise WolframEvaluationError("Append expects a rule when appending to an Association.")
        remaining = [existing for existing in entries if existing.key != entry.key]
        remaining.append(entry)
        return _association_expr(remaining)

    compound = _require_compound(expr, "Append")
    return _rebuild(compound, (*compound.arguments, item))


def prepend(expr: Expr, item: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        entry = _rule_entry(item)
        if entry is None:
            raise WolframEvaluationError("Prepend expects a rule when prepending to an Association.")
        remaining = [existing for existing in entries if existing.key != entry.key]
        return _association_expr([entry, *remaining])

    compound = _require_compound(expr, "Prepend")
    return _rebuild(compound, (item, *compound.arguments))


def join(*exprs: Expr) -> Expr:
    if not exprs:
        raise WolframEvaluationError("Join expects at least one expression.")

    if all(_is_association(expr) for expr in exprs):
        merged: list[_AssociationEntry] = []
        for expr in exprs:
            assert (entries := _association_entries(expr)) is not None
            merged.extend(entries)
        return _association_expr(merged)

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
    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(reversed(entries))

    compound = _require_compound(expr, "Reverse")
    return _rebuild(compound, tuple(reversed(compound.arguments)))


def rotate_left(expr: Expr, amount: Expr | int = 1) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return _association_expr(entries)
        count = len(entries)
        offset = _normalize_integer_argument(amount, "RotateLeft") % count
        if offset == 0:
            return _association_expr(entries)
        return _association_expr(entries[offset:] + entries[:offset])

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
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
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
    planned: list[tuple[list[_IndexSelector | _KeySelector], Expr]] = []
    seen_paths: set[tuple[_IndexSelector | _KeySelector, ...]] = set()

    for position_spec, replacement in rules:
        paths, _invalid = _expand_operation_paths(expr, position_spec)
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
    entries = _association_entries(expr)
    if entries is not None:
        return Call(head_expr=new_head, arguments=tuple(entry.value for entry in entries))
    if not isinstance(expr, Call):
        return expr
    return Call(head_expr=new_head, arguments=expr.arguments)


def map_expr(function: Expr, expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=Call(head_expr=function, arguments=(entry.value,)),
            )
            for entry in entries
        )
    if not isinstance(expr, Call):
        return expr
    return _rebuild(expr, tuple(Call(head_expr=function, arguments=(argument,)) for argument in expr.arguments))


def map_at(function: Expr, expr: Expr, positions: Expr | int) -> Expr:
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
    if invalid:
        raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(paths):
        result, changed = _try_map_at_path(result, function, path)
        if not changed:
            raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")
    return result


def association(*arguments: Expr) -> Expr:
    constructed = _association_from_arguments(arguments)
    if constructed is not None:
        return constructed
    return call("Association", *arguments)


def association_q(expr: Expr) -> Symbol:
    return _bool_symbol(_is_association(expr))


def keys_expr(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Keys")
    return list_expr(*(entry.key for entry in entries))


def values_expr(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Values")
    return list_expr(*(entry.value for entry in entries))


def normal(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Normal")
    return list_expr(*(entry.to_expr() for entry in entries))


def lookup(expr: Expr, key_spec: Expr, default: Expr | None = None) -> Expr:
    entries = _require_association_entries(expr, "Lookup")
    entry_map = _association_entry_map(entries)

    def lookup_one(key: Expr) -> Expr:
        entry = entry_map.get(key)
        if entry is not None:
            return entry.value
        if default is not None:
            return default
        return call("Missing", string("KeyAbsent"), key)

    if isinstance(key_spec, Call) and key_spec.has_head("List"):
        return list_expr(*(lookup_one(item) for item in key_spec.arguments))
    return lookup_one(key_spec)


def key_exists_q(expr: Expr, key: Expr) -> Symbol:
    entries = _require_association_entries(expr, "KeyExistsQ")
    return _bool_symbol(any(entry.key == key for entry in entries))


def key_member_q(expr: Expr, key: Expr) -> Symbol:
    return key_exists_q(expr, key)


def key_take(expr: Expr, key_spec: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyTake")
    entry_map = _association_entry_map(entries)
    selected: list[_AssociationEntry] = []
    for key in _key_spec_items(key_spec):
        entry = entry_map.get(key)
        if entry is not None:
            selected.append(entry)
    return _association_expr(selected)


def key_drop(expr: Expr, key_spec: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyDrop")
    keys_to_drop = set(_key_spec_items(key_spec))
    return _association_expr(entry for entry in entries if entry.key not in keys_to_drop)


def key_map(function: Expr, expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyMap")
    return _association_expr(
        _AssociationEntry(
            rule_head=entry.rule_head,
            key=Call(head_expr=function, arguments=(entry.key,)),
            value=entry.value,
        )
        for entry in entries
    )


def key_value_map(function: Expr, expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyValueMap")
    return list_expr(*(Call(head_expr=function, arguments=(entry.key, entry.value)) for entry in entries))


def association_thread(keys: Expr, values: Expr) -> Expr:
    if not isinstance(keys, Call) or not keys.has_head("List"):
        raise WolframEvaluationError("AssociationThread expects a list of keys.")
    if not isinstance(values, Call) or not values.has_head("List"):
        raise WolframEvaluationError("AssociationThread expects a list of values.")
    if len(keys.arguments) != len(values.arguments):
        raise WolframEvaluationError("AssociationThread expects key and value lists of equal length.")
    return _association_expr(
        _AssociationEntry("Rule", key, value)
        for key, value in zip(keys.arguments, values.arguments, strict=True)
    )


def association_map(function: Expr, keys: Expr) -> Expr:
    if not isinstance(keys, Call) or not keys.has_head("List"):
        raise WolframEvaluationError("AssociationMap currently supports only the key-list form.")
    return _association_expr(
        _AssociationEntry("Rule", key, Call(head_expr=function, arguments=(key,)))
        for key in keys.arguments
    )


def _require_compound(expr: Expr, function_name: str) -> Call:
    if isinstance(expr, Call):
        return expr
    raise WolframEvaluationError(f"{function_name} expects a nonatomic expression.")


def _require_association_entries(expr: Expr, function_name: str) -> tuple[_AssociationEntry, ...]:
    entries = _association_entries(expr)
    if entries is None:
        raise WolframEvaluationError(f"{function_name} expects an Association.")
    return entries


def _rebuild(expr: Call, arguments: Sequence[Expr]) -> Call:
    return Call(head_expr=expr.head_expr, arguments=tuple(arguments))


def _normalize_integer_argument(value: Expr | int, function_name: str) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, Integer):
        return value.value
    raise WolframEvaluationError(f"{function_name} expects an integer argument.")


def _sequence_length(expr: Expr) -> int:
    entries = _association_entries(expr)
    if entries is not None:
        return len(entries)
    if isinstance(expr, Call):
        return len(expr.arguments)
    return 0


def _take_or_drop(expr: Expr, specs: Sequence[Expr | int], *, drop: bool) -> Expr:
    function_name = "Drop" if drop else "Take"
    selectors = _normalize_take_drop_selectors(expr, specs[0], function_name)
    entries = _association_entries(expr)
    if entries is not None:
        if drop:
            removed = {_resolve_index(len(entries), selector) for selector in selectors}
            return _association_expr(entry for index, entry in enumerate(entries) if index not in removed)
        return _association_expr(entries[_resolve_index(len(entries), selector)] for selector in selectors)

    compound = _require_compound(expr, function_name)
    if drop:
        removed = {_resolve_index(len(compound.arguments), selector) for selector in selectors}
        return _rebuild(
            compound,
            tuple(argument for index, argument in enumerate(compound.arguments) if index not in removed),
        )
    return _rebuild(compound, tuple(_select_single_part_value(compound, selector) for selector in selectors))


def _normalize_take_drop_selectors(expr: Expr, spec: Expr | int, function_name: str) -> list[int]:
    count = _sequence_length(expr)

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
            return _validate_selectors(
                expr,
                _expand_span_spec_from_count(count, Call(head_expr=Symbol("Span"), arguments=spec.arguments)),
                function_name,
            )
        raise WolframEvaluationError(f"{function_name} list specifications must contain one, two, or three items.")

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _validate_selectors(expr: Expr, selectors: Sequence[int], function_name: str) -> list[int]:
    count = _sequence_length(expr)
    for selector in selectors:
        _resolve_index(count, selector)
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


def _expand_operation_paths(
    expr: Expr,
    positions: Expr | Sequence[Expr | Sequence[int] | int],
) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if isinstance(positions, Expr):
        return _expand_position_expr_to_exact_paths(expr, positions)

    paths: list[list[_IndexSelector | _KeySelector]] = []
    invalid = False
    for item in positions:
        if isinstance(item, Expr):
            expanded, had_invalid = _expand_position_expr_to_exact_paths(expr, item)
            paths.extend(expanded)
            invalid = invalid or had_invalid
            continue
        if isinstance(item, int):
            expanded, had_invalid = _expand_position_expr_to_exact_paths(expr, integer(item))
            paths.extend(expanded)
            invalid = invalid or had_invalid
            continue
        components = [integer(component) for component in item]
        expanded, had_invalid = _expand_exact_position_components(expr, components)
        paths.extend(expanded)
        invalid = invalid or had_invalid
    return (paths, invalid)


def _expand_position_expr_to_exact_paths(expr: Expr, spec: Expr) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if _is_collection_of_position_specs(spec):
        paths: list[list[_IndexSelector | _KeySelector]] = []
        invalid = False
        assert isinstance(spec, Call)
        for item in spec.arguments:
            expanded, had_invalid = _expand_exact_position_components(expr, _position_components_from_expr(item))
            paths.extend(expanded)
            invalid = invalid or had_invalid
        return (paths, invalid)

    if _is_single_position_spec_expr(spec):
        return _expand_exact_position_components(expr, _position_components_from_expr(spec))

    raise WolframEvaluationError(f"Unsupported position specification: {spec.to_input_form()}.")


def _expand_exact_position_components(
    expr: Expr,
    components: Sequence[Expr],
) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if not components:
        return ([[]], False)

    selections, invalid = _resolve_component_selections(expr, components[0], allow_head=False, function_name="Position")
    paths: list[list[_IndexSelector | _KeySelector]] = []
    for selection in selections:
        child_paths, child_invalid = _expand_exact_position_components(selection.child, components[1:])
        invalid = invalid or child_invalid
        for child_path in child_paths:
            paths.append([selection.selector, *child_path])
    return (paths, invalid)


def _resolve_component_selections(
    expr: Expr,
    component: Expr,
    *,
    allow_head: bool,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    if isinstance(component, Integer) and component.value == 0:
        if not allow_head:
            raise WolframEvaluationError(f"{function_name} does not support index 0 in this position.")
        return ([_SelectedPart(_IndexSelector(0), head_of(expr))], False)

    entries = _association_entries(expr)
    if entries is not None:
        return _resolve_association_component_selections(entries, component, function_name=function_name)

    if isinstance(expr, Call):
        return _resolve_call_component_selections(expr, component, function_name=function_name)

    return ([], True)


def _resolve_call_component_selections(
    expr: Call,
    component: Expr,
    *,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    selectors, invalid = _resolve_numeric_selectors(
        len(expr.arguments),
        component,
        function_name=function_name,
        allow_head=False,
    )
    return ([selection for selection in (_selected_part_from_exact_selector(expr, selector) for selector in selectors) if selection is not None], invalid)


def _resolve_association_component_selections(
    entries: Sequence[_AssociationEntry],
    component: Expr,
    *,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    if _is_key_selector_atom(component):
        key = _key_from_selector(component)
        selection = _selected_association_part(entries, _KeySelector(key))
        return ([selection], False) if selection is not None else ([], True)

    if isinstance(component, Call) and component.has_head("List"):
        kinds = {_selector_atom_kind(item) for item in component.arguments}
        if None in kinds:
            raise WolframEvaluationError(f"Unsupported selector inside {function_name} specification: {component.to_input_form()}.")
        if "numeric" in kinds and "key" in kinds:
            raise WolframEvaluationError("Association selector lists may not mix numeric and key selectors.")
        if kinds == {"key"}:
            selections: list[_SelectedPart] = []
            invalid = False
            for item in component.arguments:
                selection = _selected_association_part(entries, _KeySelector(_key_from_selector(item)))
                if selection is None:
                    invalid = True
                    continue
                selections.append(selection)
            return (selections, invalid)

    selectors, invalid = _resolve_numeric_selectors(
        len(entries),
        component,
        function_name=function_name,
        allow_head=False,
    )
    selections = [selection for selection in (_selected_association_part(entries, selector) for selector in selectors) if selection is not None]
    return (selections, invalid)


def _resolve_numeric_selectors(
    length_value: int,
    component: Expr,
    *,
    function_name: str,
    allow_head: bool,
) -> tuple[list[_IndexSelector], bool]:
    if isinstance(component, Integer):
        if component.value == 0:
            if allow_head:
                return ([_IndexSelector(0)], False)
            raise WolframEvaluationError(f"{function_name} does not support index 0 in this position.")
        resolved = _try_resolve_index(length_value, component.value)
        if resolved is None:
            return ([], True)
        return ([_IndexSelector(resolved + 1)], False)

    if isinstance(component, Symbol) and component.name == "All":
        return ([_IndexSelector(index) for index in range(1, length_value + 1)], False)

    if isinstance(component, Call) and component.has_head("Span"):
        selectors: list[_IndexSelector] = []
        invalid = False
        for index in _expand_span_spec_from_count(length_value, component):
            resolved = _try_resolve_index(length_value, index)
            if resolved is None:
                invalid = True
                continue
            selectors.append(_IndexSelector(resolved + 1))
        return (selectors, invalid)

    if isinstance(component, Call) and component.has_head("List"):
        selectors: list[_IndexSelector] = []
        invalid = False
        for item in component.arguments:
            kind = _selector_atom_kind(item)
            if kind == "key":
                raise WolframEvaluationError(f"Unsupported selector inside {function_name} specification: {item.to_input_form()}.")
            nested, nested_invalid = _resolve_numeric_selectors(
                length_value,
                item,
                function_name=function_name,
                allow_head=False,
            )
            selectors.extend(nested)
            invalid = invalid or nested_invalid
        return (selectors, invalid)

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {component.to_input_form()}.")


def _selector_atom_kind(expr: Expr) -> str | None:
    if isinstance(expr, Integer):
        return "numeric"
    if isinstance(expr, Symbol) and expr.name == "All":
        return "numeric"
    if isinstance(expr, Call) and expr.has_head("Span"):
        return "numeric"
    if _is_key_selector_atom(expr):
        return "key"
    return None


def _is_key_selector_atom(expr: Expr) -> bool:
    return isinstance(expr, String) or (
        isinstance(expr, Call)
        and expr.has_head("Key")
        and len(expr.arguments) == 1
    )


def _key_from_selector(expr: Expr) -> Expr:
    if isinstance(expr, String):
        return expr
    if isinstance(expr, Call) and expr.has_head("Key") and len(expr.arguments) == 1:
        return expr.arguments[0]
    raise WolframEvaluationError(f"Expected a key selector, got {expr.to_input_form()}.")


def _is_position_component(expr: Expr) -> bool:
    return _is_selector_atom(expr) or (
        isinstance(expr, Call)
        and expr.has_head("List")
        and all(_is_selector_atom(item) for item in expr.arguments)
    )


def _is_collection_of_position_specs(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and expr.has_head("List")
        and bool(expr.arguments)
        and all(
            isinstance(item, Call)
            and item.has_head("List")
            and all(_is_position_component(component) for component in item.arguments)
            for item in expr.arguments
        )
    )


def _is_selector_atom(expr: Expr) -> bool:
    return _selector_atom_kind(expr) is not None


def _is_single_position_spec_expr(expr: Expr) -> bool:
    if isinstance(expr, Integer) or _is_key_selector_atom(expr):
        return True
    return isinstance(expr, Call) and expr.has_head("List") and all(_is_position_component(item) for item in expr.arguments)


def _try_resolve_index(length_value: int, index: int) -> int | None:
    try:
        return _resolve_index(length_value, index)
    except WolframEvaluationError:
        return None


def _dedupe_paths(paths: Sequence[Sequence[_IndexSelector | _KeySelector]]) -> list[list[_IndexSelector | _KeySelector]]:
    seen: set[tuple[_IndexSelector | _KeySelector, ...]] = set()
    unique: list[list[_IndexSelector | _KeySelector]] = []
    for path in paths:
        key = tuple(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(list(path))
    return unique


def _sort_paths(
    paths: Sequence[Sequence[_IndexSelector | _KeySelector]],
) -> list[list[_IndexSelector | _KeySelector]]:
    return [
        list(path)
        for path in sorted(
            (tuple(path) for path in paths),
            key=lambda path: (len(path), tuple(_path_component_sort_key(component) for component in path)),
            reverse=True,
        )
    ]


def _sort_path_items(
    items: Sequence[tuple[Sequence[_IndexSelector | _KeySelector], Expr]],
) -> list[tuple[list[_IndexSelector | _KeySelector], Expr]]:
    return [
        (list(path), value)
        for path, value in sorted(
            ((tuple(path), value) for path, value in items),
            key=lambda item: (len(item[0]), tuple(_path_component_sort_key(component) for component in item[0])),
            reverse=True,
        )
    ]


def _path_component_sort_key(component: _IndexSelector | _KeySelector) -> tuple[int, int | str]:
    if isinstance(component, _IndexSelector):
        return (0, component.index)
    return (1, component.key.to_input_form())


def _try_delete_at_path(
    expr: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
) -> tuple[Expr, bool]:
    if not path:
        return (expr, False)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            del mutable[index]
            return (_association_expr(mutable), True)
        updated_child, changed = _try_delete_at_path(entry.value, path[1:])
        if not changed:
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
    if len(path) == 1:
        del arguments[resolved]
        return (_rebuild(expr, arguments), True)

    updated_child, changed = _try_delete_at_path(arguments[resolved], path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_replace_at_path(
    expr: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
    replacement: Expr,
) -> tuple[Expr, bool]:
    if not path:
        return (replacement, True)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            mutable[index] = _AssociationEntry(entry.rule_head, entry.key, replacement)
            return (_association_expr(mutable), True)
        updated_child, changed = _try_replace_at_path(entry.value, path[1:], replacement)
        if not changed:
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
    updated_child, changed = _try_replace_at_path(arguments[resolved], path[1:], replacement)
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_map_at_path(
    expr: Expr,
    function: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
) -> tuple[Expr, bool]:
    if not path:
        return (Call(head_expr=function, arguments=(expr,)), True)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            mutable[index] = _AssociationEntry(
                entry.rule_head,
                entry.key,
                Call(head_expr=function, arguments=(entry.value,)),
            )
            return (_association_expr(mutable), True)
        updated_child, changed = _try_map_at_path(entry.value, function, path[1:])
        if not changed:
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
    updated_child, changed = _try_map_at_path(arguments[resolved], function, path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _select_association_entry(
    entries: Sequence[_AssociationEntry],
    selector: _IndexSelector | _KeySelector,
) -> tuple[int, _AssociationEntry] | None:
    if isinstance(selector, _IndexSelector):
        index = selector.index - 1
        if 0 <= index < len(entries):
            return (index, entries[index])
        return None

    for index, entry in enumerate(entries):
        if entry.key == selector.key:
            return (index, entry)
    return None


def _selected_association_part(
    entries: Sequence[_AssociationEntry],
    selector: _IndexSelector | _KeySelector,
) -> _SelectedPart | None:
    selected = _select_association_entry(entries, selector)
    if selected is None:
        return None
    _index, entry = selected
    return _SelectedPart(selector=selector, child=entry.value, entry=entry)


def _selected_part_from_exact_selector(expr: Expr, selector: _IndexSelector) -> _SelectedPart | None:
    if selector.index == 0:
        return _SelectedPart(selector=selector, child=head_of(expr))
    if not isinstance(expr, Call):
        return None
    index = selector.index - 1
    if not 0 <= index < len(expr.arguments):
        return None
    return _SelectedPart(selector=selector, child=expr.arguments[index])


def _component_is_multi(component: Expr) -> bool:
    return (
        (isinstance(component, Symbol) and component.name == "All")
        or (isinstance(component, Call) and component.has_head("Span"))
        or (isinstance(component, Call) and component.has_head("List"))
    )


def _part_recursive(expr: Expr, specs: Sequence[Expr]) -> Expr:
    if not specs:
        return expr

    component = specs[0]
    selections, invalid = _resolve_component_selections(expr, component, allow_head=True, function_name="Part")
    multi = _component_is_multi(component)
    if invalid or (not selections and not multi):
        raise WolframEvaluationError(f"Part specifications are invalid for {expr.to_input_form()}.")

    remaining = specs[1:]
    if not multi:
        return _part_recursive(selections[0].child, remaining) if remaining else selections[0].child

    transformed = [(_part_recursive(selection.child, remaining) if remaining else selection.child) for selection in selections]
    return _rebuild_selected_parts(expr, selections, transformed)


def _rebuild_selected_parts(
    expr: Expr,
    selections: Sequence[_SelectedPart],
    values: Sequence[Expr],
) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        rebuilt_entries: list[_AssociationEntry] = []
        for selection, value in zip(selections, values, strict=True):
            if selection.entry is None:
                continue
            rebuilt_entries.append(
                _AssociationEntry(
                    rule_head=selection.entry.rule_head,
                    key=selection.entry.key,
                    value=value,
                )
            )
        return _association_expr(rebuilt_entries)

    if not isinstance(expr, Call):
        raise WolframEvaluationError("Cannot rebuild selected parts from an atom.")
    return _rebuild(expr, values)


def evaluate(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    if isinstance(expr.head_expr, Symbol):
        raw_head_name = expr.head_expr.name

        if raw_head_name == "MatchQ":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("MatchQ expects exactly two arguments.")
            return match_q(evaluate(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "FreeQ":
            if len(expr.arguments) == 2:
                return free_q(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return free_q(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("FreeQ expects an expression, a pattern, and an optional level specification.")

        if raw_head_name == "Cases":
            if len(expr.arguments) == 2:
                return cases(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return cases(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            if len(expr.arguments) == 4:
                return cases(
                    evaluate(expr.arguments[0]),
                    expr.arguments[1],
                    evaluate(expr.arguments[2]),
                    evaluate(expr.arguments[3]),
                )
            raise WolframEvaluationError(
                "Cases expects an expression, a pattern or transformation rule, and optional level and match limits."
            )

        if raw_head_name == "DeleteCases":
            if len(expr.arguments) == 2:
                return delete_cases(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return delete_cases(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            if len(expr.arguments) == 4:
                return delete_cases(
                    evaluate(expr.arguments[0]),
                    expr.arguments[1],
                    evaluate(expr.arguments[2]),
                    evaluate(expr.arguments[3]),
                )
            raise WolframEvaluationError(
                "DeleteCases expects an expression, a pattern, and optional level and match limits."
            )

    evaluated_head = evaluate(expr.head_expr)
    if not isinstance(evaluated_head, Symbol):
        return Call(head_expr=evaluated_head, arguments=tuple(evaluate(argument) for argument in expr.arguments))

    evaluated_arguments = tuple(evaluate(argument) for argument in expr.arguments)

    if evaluated_head.name == "Association":
        return association(*evaluated_arguments)

    if evaluated_head.name == "AssociationQ":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("AssociationQ expects exactly one argument.")
        return association_q(evaluated_arguments[0])

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

    if evaluated_head.name == "Keys":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Keys expects exactly one argument.")
        return keys_expr(evaluated_arguments[0])

    if evaluated_head.name == "Values":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Values expects exactly one argument.")
        return values_expr(evaluated_arguments[0])

    if evaluated_head.name == "Normal":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Normal expects exactly one argument.")
        return normal(evaluated_arguments[0])

    if evaluated_head.name == "Lookup":
        if len(evaluated_arguments) == 2:
            return lookup(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return lookup(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Lookup expects an association, a key specification, and an optional default.")

    if evaluated_head.name == "KeyExistsQ":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyExistsQ expects exactly two arguments.")
        return key_exists_q(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyMemberQ":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyMemberQ expects exactly two arguments.")
        return key_member_q(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyTake":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyTake expects exactly two arguments.")
        return key_take(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyDrop expects exactly two arguments.")
        return key_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyMap expects exactly two arguments.")
        return key_map(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyValueMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyValueMap expects exactly two arguments.")
        return key_value_map(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "AssociationThread":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AssociationThread expects exactly two arguments.")
        return association_thread(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "AssociationMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AssociationMap expects exactly two arguments.")
        return association_map(evaluated_arguments[0], evaluated_arguments[1])

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
        value = expr.value
        if value.startswith("\"") and value.endswith("\"") and len(value) >= 2:
            value = value[1:-1]
            if value.startswith(r"\<") and value.endswith(r"\>") and len(value) >= 4:
                return wl_string(value[2:-2])
            return wl_string(value)
        if value.startswith(r"\<") and value.endswith(r"\>") and len(value) >= 4:
            return wl_string(value[2:-2])
        return _normalize_row_box_token(value)

    if isinstance(expr, (Symbol, Integer, Real)):
        return expr.to_input_form()

    if isinstance(expr, Call):
        if expr.has_head("InterpretationBox") and len(expr.arguments) >= 2:
            return _interpret_standard_form(expr.arguments[1]).to_input_form()

        if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _BOX_UNWRAP_HEADS and expr.arguments:
            return _box_item_to_standard_text(expr.arguments[0])

        if expr.has_head("RowBox"):
            try:
                interpreted = _interpret_row_box(expr)
            except WolframSyntaxError:
                if len(expr.arguments) == 1 and isinstance(expr.arguments[0], Call) and expr.arguments[0].has_head("List"):
                    return "".join(_box_item_to_standard_text(item) for item in expr.arguments[0].arguments)
                raise
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
    token_map = {
        r"\[Rule]": "->",
        r"\[RuleDelayed]": ":>",
        r"\[LeftAssociation]": "<|",
        r"\[RightAssociation]": "|>",
    }
    if value in token_map:
        return token_map[value]
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


def _scan_string(text: str, start: int) -> tuple[_Token, int]:
    end = skip_wl_string(text, start)
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
    "___",
    "__",
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
            index = skip_wl_comment(text, index)
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
        if char in "[]{}(),+-*/^!@<>_|":
            tokens.append(_Token(kind="operator", text=char, start=index, end=index + 1, value=char))
            index += 1
            continue

        raise WolframSyntaxError(f"Unexpected Wolfram syntax character {char!r} at offset {index}.")

    tokens.append(_Token(kind="eof", text="", start=len(text), end=len(text)))
    return tokens


class _Parser:
    _PART_BP = 190
    _CALL_BP = 190
    _PATTERN_BP = 185
    _POWER_BP = 160
    _TIMES_BP = 140
    _PLUS_BP = 120
    _COMPARE_BP = 100
    _AND_BP = 80
    _OR_BP = 70
    _ALTERNATIVES_BP = 65
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

            if token.text in {"_", "__", "___"}:
                if self._PATTERN_BP < min_bp:
                    break
                left = self._parse_postfix_pattern(left)
                continue

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

        if token.text in {"__", "___"}:
            raise _unsupported_pattern(call("BlankSequence" if token.text == "__" else "BlankNullSequence"))

        if token.text == "_":
            return self._parse_prefix_blank()

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

    def _parse_prefix_blank(self) -> Expr:
        if self._peek().kind == "symbol":
            return call("Blank", symbol(str(self._consume().value)))
        return call("Blank")

    def _parse_postfix_pattern(self, left: Expr) -> Expr:
        token = self._consume()
        if token.text in {"__", "___"}:
            raise _unsupported_pattern(call("BlankSequence" if token.text == "__" else "BlankNullSequence"))
        if not isinstance(left, Symbol):
            raise WolframSyntaxError(
                f"Named pattern shorthand requires a symbol before '_' at offset {token.start}."
            )
        blank = self._parse_prefix_blank()
        return call("Pattern", left, blank)

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
            "|": (self._ALTERNATIVES_BP, self._ALTERNATIVES_BP + 1, "Alternatives"),
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


def _select_single_part_value(expr: Call, index: int) -> Expr:
    return expr.arguments[_resolve_index(len(expr.arguments), index)]


def _expand_span_spec(expr: Expr, span: Call) -> list[int]:
    count = _sequence_length(expr)
    if count == 0 and not _is_association(expr) and not isinstance(expr, Call):
        raise WolframEvaluationError("Span cannot be applied to an atom.")
    return _expand_span_spec_from_count(count, span)


def _expand_span_spec_from_count(length_value: int, span: Call) -> list[int]:
    if length_value < 0:
        raise WolframEvaluationError("Span cannot be applied to an atom.")

    if len(span.arguments) not in {2, 3}:
        raise WolframEvaluationError("Span must contain two or three arguments.")

    start_expr = span.arguments[0]
    end_expr = span.arguments[1]
    step_expr = span.arguments[2] if len(span.arguments) == 3 else integer(1)

    start = _span_endpoint_value(start_expr, length_value, default=1)
    end = _span_endpoint_value(end_expr, length_value, default=length_value)
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


def _position_components_from_expr(expr: Expr) -> list[Expr]:
    if isinstance(expr, Integer) or _is_key_selector_atom(expr):
        return [expr]
    if isinstance(expr, Call) and expr.has_head("List"):
        return list(expr.arguments)
    raise WolframEvaluationError(f"Expected a Wolfram position list, got {expr.to_input_form()}.")


def _key_spec_items(expr: Expr) -> list[Expr]:
    if isinstance(expr, Call) and expr.has_head("List"):
        return list(expr.arguments)
    return [expr]


@dataclass(frozen=True)
class _LevelRecord:
    expr: Expr
    positive_level: int
    negative_level: int


def _collect_levels(expr: Expr, positive_level: int, target: list[_LevelRecord]) -> None:
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))
    entries = _association_entries(expr)
    if entries is not None:
        for entry in entries:
            _collect_levels(entry.value, positive_level + 1, target)
        return
    if isinstance(expr, Call):
        for argument in expr.arguments:
            _collect_levels(argument, positive_level + 1, target)


def _normalize_level_bound(expr: Expr) -> int:
    if isinstance(expr, Integer):
        return expr.value
    if isinstance(expr, Symbol) and expr.name == "Infinity":
        return _LEVEL_INFINITY
    raise WolframEvaluationError(f"Unsupported level bound: {expr.to_input_form()}.")


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

    if isinstance(spec, Symbol) and spec.name == "Infinity":
        return (1, _LEVEL_INFINITY)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1 and isinstance(spec.arguments[0], (Integer, Symbol)):
            value = _normalize_level_bound(spec.arguments[0])
            return (value, value)
        if len(spec.arguments) == 2 and all(
            isinstance(item, Integer) or (isinstance(item, Symbol) and item.name == "Infinity")
            for item in spec.arguments
        ):
            return (_normalize_level_bound(spec.arguments[0]), _normalize_level_bound(spec.arguments[1]))

    raise WolframEvaluationError(f"Unsupported Level specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _level_matches(record: _LevelRecord, level_min: int, level_max: int) -> bool:
    return (
        level_min <= record.positive_level <= level_max
        or level_min <= record.negative_level <= level_max
    )
