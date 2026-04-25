from __future__ import annotations

import base64
import binascii
import bz2
import csv
from dataclasses import dataclass
import gzip
import io
import json
import math
import re
from typing import Callable, Iterable, Sequence

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
class ByteArrayExpr(Expr):
    values: tuple[int, ...]

    def head(self) -> Expr:
        return Symbol("ByteArray")

    def to_full_form(self) -> str:
        encoded = base64.b64encode(bytes(self.values)).decode("ascii")
        return f'ByteArray["{encoded}"]'

    def to_input_form(self) -> str:
        return self.to_full_form()

    def to_dict(self) -> dict[str, object]:
        encoded = base64.b64encode(bytes(self.values)).decode("ascii")
        return {
            "type": "byte_array",
            "values": list(self.values),
            "base64": encoded,
            "length": len(self.values),
        }


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
            if head_name == "StringExpression" and self.arguments:
                return " ~~ ".join(_wrap_infix(arg) for arg in self.arguments)
            if head_name == "SameQ" and len(self.arguments) >= 2:
                return " === ".join(_wrap_infix(arg) for arg in self.arguments)
            if head_name == "UnsameQ" and len(self.arguments) >= 2:
                return " =!= ".join(_wrap_infix(arg) for arg in self.arguments)
            if head_name == "Condition" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])} /; {_wrap_infix(self.arguments[1])}"
            if head_name == "Repeated" and len(self.arguments) == 1:
                return f"{_wrap_infix(self.arguments[0])}.."
            if head_name == "RepeatedNull" and len(self.arguments) == 1:
                return f"{_wrap_infix(self.arguments[0])}..."
            if head_name == "Rule" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])} -> {_wrap_infix(self.arguments[1])}"
            if head_name == "RuleDelayed" and len(self.arguments) == 2:
                return f"{_wrap_infix(self.arguments[0])} :> {_wrap_infix(self.arguments[1])}"
            if head_name == "Pattern" and len(self.arguments) == 2 and isinstance(self.arguments[0], Symbol):
                inner = self.arguments[1]
                if isinstance(inner, Call) and inner.has_head("Blank"):
                    if len(inner.arguments) == 0:
                        return f"{self.arguments[0].to_input_form()}_"
                    if len(inner.arguments) == 1:
                        return f"{self.arguments[0].to_input_form()}_{inner.arguments[0].to_input_form()}"
                return f"{self.arguments[0].to_input_form()} : {_wrap_infix(inner)}"
            if head_name == "Composition" and len(self.arguments) >= 2:
                return " @* ".join(_wrap_infix(arg) for arg in self.arguments)
            if head_name == "RightComposition" and len(self.arguments) >= 2:
                return " /* ".join(_wrap_infix(arg) for arg in self.arguments)
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
            if head_name == "Dot" and len(self.arguments) >= 2:
                return " . ".join(_wrap_infix(arg) for arg in self.arguments)
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


def byte_array_expr(values: Iterable[int]) -> ByteArrayExpr:
    normalized = tuple(int(value) for value in values)
    for value in normalized:
        if value < 0 or value > 255:
            raise WolframEvaluationError("ByteArray values must be integers between 0 and 255.")
    return ByteArrayExpr(normalized)


_FLAT_HEADS = {"Alternatives"}

_LEVEL_INFINITY = 1_000_000_000
_MISSING = object()
_ESCAPED_TOKEN_MAP = {
    r"\[Function]": "|->",
    r"\[Rule]": "->",
    r"\[RuleDelayed]": ":>",
    r"\[LeftAssociation]": "<|",
    r"\[RightAssociation]": "|>",
}


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


def _evaluated_list_expr(*items: Expr) -> Call:
    # Raw parser lists must preserve Nothing in held syntax. Evaluator-created
    # lists instead mirror Wolfram's ordinary List construction behavior.
    arguments = _normalize_arguments_for_head("List", items, evaluated=True)
    return call("List", *arguments)


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


@dataclass(frozen=True)
class _SelectionItem:
    index: int
    value: Expr
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
    ordered: list[_AssociationEntry] = []
    first_positions: dict[Expr, int] = {}

    for entry in entries:
        previous = first_positions.get(entry.key)
        if previous is None:
            first_positions[entry.key] = len(ordered)
            ordered.append(entry)
        else:
            # Wolfram associations keep the key's first slot and update the value.
            ordered[previous] = entry

    return tuple(ordered)


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


def _is_boolean_symbol(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name in {"True", "False"}


def _truth_value(expr: Expr) -> bool | None:
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
    return None


def _is_integer_expr(expr: Expr) -> bool:
    return isinstance(expr, Integer)


def _integer_values(arguments: Sequence[Expr]) -> list[int] | None:
    values: list[int] = []
    for argument in arguments:
        if not isinstance(argument, Integer):
            return None
        values.append(argument.value)
    return values


def _byte_array_values(expr: Expr) -> tuple[int, ...] | None:
    if isinstance(expr, ByteArrayExpr):
        return expr.values
    return None


def _normalize_base_encoding_name(value: Expr, function_name: str) -> str:
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the encoding name to be a string.")
    normalized = value.value.strip().lower()
    if normalized == "base16":
        return "Base16"
    if normalized == "base64":
        return "Base64"
    if normalized == "base85ascii":
        return "Base85ASCII"
    raise WolframEvaluationError(
        f'{function_name} currently supports only "Base16", "Base64", and "Base85ASCII".'
    )


_SINGLE_BYTE_ENCODINGS = {
    "ascii": "ascii",
    "iso8859-1": "latin-1",
    "iso-8859-1": "latin-1",
    "latin1": "latin-1",
    "latin-1": "latin-1",
    "iso8859-15": "iso8859_15",
    "iso-8859-15": "iso8859_15",
}

_MULTIBYTE_ENCODINGS = {
    "utf-8": "utf-8",
    "utf8": "utf-8",
    "utf-16le": "utf-16le",
    "utf16le": "utf-16le",
    "utf-16be": "utf-16be",
    "utf16be": "utf-16be",
    "utf-32le": "utf-32le",
    "utf32le": "utf-32le",
    "utf-32be": "utf-32be",
    "utf32be": "utf-32be",
}


def _normalize_character_encoding_name(
    value: Expr | None,
    function_name: str,
    *,
    default_unicode: bool = False,
) -> tuple[str, str]:
    if value is None:
        return ("Unicode", "Unicode") if default_unicode else ("utf-8", "UTF-8")
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the encoding name to be a string.")
    raw = value.value.strip()
    normalized = raw.lower()
    if normalized == "unicode":
        return "Unicode", "Unicode"
    single = _SINGLE_BYTE_ENCODINGS.get(normalized)
    if single is not None:
        return single, raw
    multi = _MULTIBYTE_ENCODINGS.get(normalized)
    if multi is not None:
        return multi, raw
    raise WolframEvaluationError(
        f'{function_name} currently supports "Unicode", "UTF-8", "UTF-16LE", "UTF-16BE", '
        '"UTF-32LE", "UTF-32BE", "ASCII", "ISO8859-1", and "ISO8859-15".'
    )


def _decode_bytes_to_string(data: bytes, codec_name: str) -> str:
    if codec_name == "Unicode":
        return "".join(chr(byte) for byte in data)
    decoded = data.decode(codec_name, errors="surrogateescape")
    return "".join(chr(ord(char) - 0xDC00) if 0xDC80 <= ord(char) <= 0xDCFF else char for char in decoded)


def _string_to_character_codes(value: str, encoding_name: str) -> list[Expr]:
    if encoding_name == "Unicode":
        return [integer(ord(char)) for char in value]
    if encoding_name in _SINGLE_BYTE_ENCODINGS.values():
        codes: list[Expr] = []
        for char in value:
            try:
                encoded = char.encode(encoding_name)
            except UnicodeEncodeError:
                codes.append(symbol("None"))
                continue
            assert len(encoded) == 1
            codes.append(integer(encoded[0]))
        return codes
    return [integer(byte) for byte in value.encode(encoding_name)]


def _evaluate_integer_arithmetic(expr: Call) -> Expr | None:
    if expr.has_head("Plus"):
        if not all(_is_integer_expr(argument) for argument in expr.arguments):
            return None
        return integer(sum(argument.value for argument in expr.arguments if isinstance(argument, Integer)))

    if expr.has_head("Times"):
        if not all(_is_integer_expr(argument) for argument in expr.arguments):
            return None
        product = 1
        for argument in expr.arguments:
            assert isinstance(argument, Integer)
            product *= argument.value
        return integer(product)

    if expr.has_head("Power"):
        if len(expr.arguments) != 2:
            return None
        base, exponent = expr.arguments
        if not isinstance(base, Integer) or not isinstance(exponent, Integer):
            return None
        if exponent.value < 0:
            return None
        if base.value == 0 and exponent.value == 0:
            return None
        return integer(pow(base.value, exponent.value))

    return None


def _evaluate_integer_relation(expr: Call) -> Expr | None:
    if not all(_is_integer_expr(argument) for argument in expr.arguments):
        return None

    values = [argument.value for argument in expr.arguments if isinstance(argument, Integer)]

    if expr.has_head("Equal"):
        return _bool_symbol(all(left == right for left, right in zip(values, values[1:])))
    if expr.has_head("Unequal"):
        return _bool_symbol(len(values) == len(set(values)))
    if expr.has_head("Less"):
        return _bool_symbol(all(left < right for left, right in zip(values, values[1:])))
    if expr.has_head("LessEqual"):
        return _bool_symbol(all(left <= right for left, right in zip(values, values[1:])))
    if expr.has_head("Greater"):
        return _bool_symbol(all(left > right for left, right in zip(values, values[1:])))
    if expr.has_head("GreaterEqual"):
        return _bool_symbol(all(left >= right for left, right in zip(values, values[1:])))

    return None


def _evaluate_boolean_logic(expr: Call) -> Expr | None:
    if expr.has_head("Not"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if not _is_boolean_symbol(argument):
            return None
        assert isinstance(argument, Symbol)
        return _bool_symbol(argument.name == "False")

    if expr.has_head("And"):
        if not all(_is_boolean_symbol(argument) for argument in expr.arguments):
            return None
        return _bool_symbol(all(isinstance(argument, Symbol) and argument.name == "True" for argument in expr.arguments))

    if expr.has_head("Or"):
        if not all(_is_boolean_symbol(argument) for argument in expr.arguments):
            return None
        return _bool_symbol(any(isinstance(argument, Symbol) and argument.name == "True" for argument in expr.arguments))

    return None


def _evaluate_simple_predicates(expr: Call) -> Expr | None:
    if len(expr.arguments) != 1:
        return None

    argument = expr.arguments[0]

    if expr.has_head("IntegerQ"):
        return _bool_symbol(isinstance(argument, Integer))

    if expr.has_head("StringQ"):
        return _bool_symbol(isinstance(argument, String))

    if expr.has_head("ByteArrayQ"):
        return _bool_symbol(isinstance(argument, ByteArrayExpr))

    if expr.has_head("EvenQ"):
        return _bool_symbol(isinstance(argument, Integer) and argument.value % 2 == 0)

    if expr.has_head("OddQ"):
        return _bool_symbol(isinstance(argument, Integer) and argument.value % 2 != 0)

    if expr.has_head("TrueQ"):
        return _bool_symbol(isinstance(argument, Symbol) and argument.name == "True")

    return None


def _evaluate_integer_special_functions(expr: Call) -> Expr | None:
    values = _integer_values(expr.arguments)
    if values is None:
        return None

    if expr.has_head("UnitStep"):
        return integer(1 if all(value >= 0 for value in values) else 0)

    if expr.has_head("Unitize"):
        if len(values) != 1:
            return None
        return integer(0 if values[0] == 0 else 1)

    if expr.has_head("Sign") or expr.has_head("RealSign"):
        if len(values) != 1:
            return None
        return integer((values[0] > 0) - (values[0] < 0))

    if expr.has_head("Abs") or expr.has_head("RealAbs"):
        if len(values) != 1:
            return None
        return integer(abs(values[0]))

    if expr.has_head("Ramp"):
        if len(values) != 1:
            return None
        return integer(max(values[0], 0))

    if expr.has_head("Mod"):
        if len(values) not in {2, 3}:
            return None
        dividend, divisor = values[0], values[1]
        if divisor == 0:
            return symbol("Indeterminate")
        offset = values[2] if len(values) == 3 else 0
        return integer(offset + ((dividend - offset) % divisor))

    if expr.has_head("Quotient"):
        if len(values) not in {2, 3}:
            return None
        dividend, divisor = values[0], values[1]
        if divisor == 0:
            return symbol("Indeterminate") if dividend == 0 else symbol("ComplexInfinity")
        offset = values[2] if len(values) == 3 else 0
        remainder = offset + ((dividend - offset) % divisor)
        return integer((dividend - remainder) // divisor)

    if expr.has_head("QuotientRemainder"):
        if len(values) != 2:
            return None
        dividend, divisor = values
        if divisor == 0:
            return None
        remainder = dividend % divisor
        quotient = (dividend - remainder) // divisor
        return list_expr(integer(quotient), integer(remainder))

    if expr.has_head("Min"):
        if not values:
            return symbol("Infinity")
        return integer(min(values))

    if expr.has_head("Max"):
        if not values:
            return symbol("-Infinity")
        return integer(max(values))

    if expr.has_head("Clip"):
        if len(values) == 1:
            return integer(min(max(values[0], -1), 1))
        return None

    if expr.has_head("KroneckerDelta"):
        if not values:
            return integer(1)
        if len(values) == 1:
            return integer(1 if values[0] == 0 else 0)
        return integer(1 if all(value == values[0] for value in values[1:]) else 0)

    if expr.has_head("DiscreteDelta"):
        return integer(1 if all(value == 0 for value in values) else 0)

    return None


def byte_array(arguments: Sequence[Expr]) -> ByteArrayExpr:
    if len(arguments) != 1:
        raise WolframEvaluationError("ByteArray expects exactly one argument.")
    source = arguments[0]
    if isinstance(source, ByteArrayExpr):
        return source
    if isinstance(source, String):
        try:
            decoded = base64.b64decode(source.value.encode("ascii"), validate=True)
        except (UnicodeEncodeError, binascii.Error) as exc:
            raise WolframEvaluationError("ByteArray string input must be valid Base64.") from exc
        return byte_array_expr(decoded)
    if isinstance(source, Call) and source.has_head("List"):
        values = _integer_values(source.arguments)
        if values is None:
            raise WolframEvaluationError("ByteArray list input must contain only integers.")
        return byte_array_expr(values)
    raise WolframEvaluationError("ByteArray expects a byte list, a Base64 string, or another ByteArray.")


def _require_byte_array(expr: Expr, function_name: str, *, allow_empty_list: bool = False) -> ByteArrayExpr:
    if isinstance(expr, ByteArrayExpr):
        return expr
    if allow_empty_list and isinstance(expr, Call) and expr.has_head("List") and not expr.arguments:
        return byte_array_expr(())
    raise WolframEvaluationError(f"{function_name} expects a ByteArray.")


def base_encode(byte_array_value: Expr, encoding_value: Expr | None = None) -> String:
    values = _require_byte_array(byte_array_value, "BaseEncode").values
    encoding_name = "Base64" if encoding_value is None else _normalize_base_encoding_name(encoding_value, "BaseEncode")
    payload = bytes(values)
    if encoding_name == "Base64":
        return string(base64.b64encode(payload).decode("ascii"))
    if encoding_name == "Base16":
        return string(base64.b16encode(payload).decode("ascii"))
    assert encoding_name == "Base85ASCII"
    return string(base64.a85encode(payload).decode("ascii"))


def _filter_base_decode_input(text: str, encoding_name: str) -> str:
    if encoding_name == "Base16":
        return "".join(character for character in text if character in "0123456789abcdefABCDEF")
    if encoding_name == "Base64":
        return "".join(
            character
            for character in text
            if character.isalnum() or character in "+/=_-"
        )
    return "".join(character for character in text if character == "z" or "!" <= character <= "u")


def base_decode(text_value: Expr, encoding_value: Expr | None = None) -> ByteArrayExpr:
    if not isinstance(text_value, String):
        raise WolframEvaluationError("BaseDecode expects the input data to be a string.")
    encoding_name = "Base64" if encoding_value is None else _normalize_base_encoding_name(encoding_value, "BaseDecode")
    filtered = _filter_base_decode_input(text_value.value, encoding_name)
    try:
        if encoding_name == "Base64":
            decoded = base64.b64decode(filtered.encode("ascii"), validate=False)
        elif encoding_name == "Base16":
            decoded = base64.b16decode(filtered.encode("ascii"), casefold=True)
        else:
            decoded = base64.a85decode(filtered.encode("ascii"), adobe=False, ignorechars=b" \t\n\r\v")
    except (UnicodeEncodeError, binascii.Error, ValueError) as exc:
        raise WolframEvaluationError(f"BaseDecode failed for {encoding_name}.") from exc
    return byte_array_expr(decoded)


def characters(expr: Expr) -> Expr:
    if isinstance(expr, String):
        return list_expr(*(string(character) for character in expr.value))
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(characters(item) for item in expr.arguments))
    raise WolframEvaluationError("Characters expects a string or a list of strings.")


def to_character_code(expr: Expr, encoding_value: Expr | None = None) -> Expr:
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "ToCharacterCode",
        default_unicode=True,
    )
    if isinstance(expr, String):
        return list_expr(*_string_to_character_codes(expr.value, encoding_name))
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(to_character_code(item, encoding_value) for item in expr.arguments))
    raise WolframEvaluationError("ToCharacterCode expects a string or a list of strings.")


def _int_list(expr: Expr, function_name: str) -> list[int]:
    if isinstance(expr, Integer):
        return [expr.value]
    if isinstance(expr, Call) and expr.has_head("List"):
        values = _integer_values(expr.arguments)
        if values is None:
            raise WolframEvaluationError(f"{function_name} expects an integer or a list of integers.")
        return values
    raise WolframEvaluationError(f"{function_name} expects an integer or a list of integers.")


def from_character_code(expr: Expr, encoding_value: Expr | None = None) -> String:
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "FromCharacterCode",
        default_unicode=True,
    )
    values = _int_list(expr, "FromCharacterCode")
    if encoding_name == "Unicode":
        try:
            return string("".join(chr(value) for value in values))
        except ValueError as exc:
            raise WolframEvaluationError("FromCharacterCode Unicode input must contain valid code points.") from exc
    if any(value < 0 or value > 255 for value in values):
        raise WolframEvaluationError("FromCharacterCode encoded input must contain integers between 0 and 255.")
    return string(_decode_bytes_to_string(bytes(values), encoding_name))


def string_to_byte_array(expr: Expr, encoding_value: Expr | None = None) -> ByteArrayExpr:
    if not isinstance(expr, String):
        raise WolframEvaluationError("StringToByteArray expects a string.")
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "StringToByteArray",
        default_unicode=False,
    )
    if encoding_name == "Unicode":
        raise WolframEvaluationError('StringToByteArray does not currently support the "Unicode" pseudo-encoding.')
    try:
        return byte_array_expr(expr.value.encode(encoding_name))
    except UnicodeEncodeError as exc:
        raise WolframEvaluationError(
            f'StringToByteArray could not represent the string in encoding {encoding_value.to_input_form() if encoding_value is not None else "\"UTF-8\""}.'
        ) from exc


def byte_array_to_string(expr: Expr, encoding_value: Expr | None = None) -> String:
    byte_values = _require_byte_array(expr, "ByteArrayToString", allow_empty_list=True).values
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "ByteArrayToString",
        default_unicode=False,
    )
    if encoding_name == "Unicode":
        raise WolframEvaluationError('ByteArrayToString does not currently support the "Unicode" pseudo-encoding.')
    return string(_decode_bytes_to_string(bytes(byte_values), encoding_name))


_TEXTUAL_EXPRESSION_FORM_NAMES = {
    "input": "InputForm",
    "inputform": "InputForm",
    "standard": "StandardForm",
    "standardform": "StandardForm",
}


def _normalize_textual_expression_form(value: Expr | None, function_name: str) -> str:
    if value is None:
        return "InputForm"
    if isinstance(value, Symbol):
        key = value.name.strip().lower()
    elif isinstance(value, String):
        key = value.value.strip().lower()
    else:
        raise WolframEvaluationError(f"{function_name} expects InputForm or StandardForm as the form specification.")
    normalized = _TEXTUAL_EXPRESSION_FORM_NAMES.get(key)
    if normalized is None:
        raise WolframEvaluationError(f"{function_name} currently supports only InputForm and StandardForm.")
    return normalized


_STANDARD_FORM_BOX_HEADS = {
    "AdjustmentBox",
    "BoxData",
    "FormBox",
    "FrameBox",
    "PaneBox",
    "StyleBox",
    "TagBox",
    "TooltipBox",
    "FractionBox",
    "InterpretationBox",
    "RadicalBox",
    "RowBox",
    "SqrtBox",
    "SuperscriptBox",
}


def _looks_like_standard_form_boxes(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and isinstance(expr.head_expr, Symbol)
        and expr.head_expr.name in _STANDARD_FORM_BOX_HEADS
    )


def to_string_expr(expr: Expr, form_value: Expr | None = None) -> String:
    form_name = _normalize_textual_expression_form(form_value, "ToString")
    if form_name == "InputForm":
        return string(expr.to_input_form())
    if form_name == "StandardForm":
        # Tungsten's StandardForm string subset intentionally renders as parseable WL text,
        # not as FrontEnd box escapes. The parser accepts it through parse_standard_form.
        return string(expr.to_input_form())
    raise AssertionError(f"Unhandled textual expression form: {form_name}")


def to_expression_expr(input_expr: Expr, form_value: Expr | None = None, wrapper_head: Expr | None = None) -> Expr:
    if isinstance(input_expr, Call) and input_expr.has_head("List"):
        return _evaluated_list_expr(
            *(to_expression_expr(item, form_value, wrapper_head) for item in input_expr.arguments)
        )

    if form_value is None and _looks_like_standard_form_boxes(input_expr):
        form_name = "StandardForm"
    else:
        form_name = _normalize_textual_expression_form(form_value, "ToExpression")

    try:
        if isinstance(input_expr, String):
            parsed = parse_input_form(input_expr.value) if form_name == "InputForm" else parse_standard_form(input_expr.value)
        elif form_name == "StandardForm" and _looks_like_standard_form_boxes(input_expr):
            parsed = _interpret_standard_form(input_expr)
        else:
            raise WolframEvaluationError("ToExpression expects a string or a supported StandardForm box expression.")
    except WolframSyntaxError as exc:
        raise WolframEvaluationError(f"ToExpression could not parse the input as {form_name}.") from exc

    if wrapper_head is not None:
        parsed = Call(head_expr=wrapper_head, arguments=(parsed,))
    return evaluate(parsed)


def _normalize_import_export_format_name(value: Expr, function_name: str) -> str:
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the format name to be a string.")
    normalized = _IMPORT_EXPORT_FORMAT_NAMES.get(value.value.strip().lower())
    if normalized is None:
        supported = ", ".join(f'"{name}"' for name in sorted(set(_IMPORT_EXPORT_FORMAT_NAMES.values())))
        raise WolframEvaluationError(f"{function_name} currently supports only {supported}.")
    return normalized


def _normalize_import_export_format_spec(value: Expr, function_name: str) -> _ImportExportFormatSpec:
    if isinstance(value, String):
        return _ImportExportFormatSpec(_normalize_import_export_format_name(value, function_name))
    if isinstance(value, Call) and value.has_head("List") and len(value.arguments) == 2:
        outer_name = _normalize_import_export_format_name(value.arguments[0], function_name)
        if outer_name not in _COMPRESSED_FORMAT_NAMES:
            raise WolframEvaluationError(
                f"{function_name} currently supports list format specifications only for compression wrappers such as {{\"GZIP\", \"Text\"}}."
            )
        return _ImportExportFormatSpec(
            outer_name,
            _normalize_import_export_format_spec(value.arguments[1], function_name),
        )
    raise WolframEvaluationError(
        f"{function_name} expects a format string or a compression-wrapper format specification."
    )


def _raw_bytes_to_string(data: bytes) -> String:
    return string("".join(chr(byte) for byte in data))


def _raw_string_to_bytes(value: Expr | str, function_name: str) -> bytes:
    text = value.value if isinstance(value, String) else value
    byte_values: list[int] = []
    for character in text:
        code_point = ord(character)
        if code_point < 0 or code_point > 255:
            raise WolframEvaluationError(
                f"{function_name} raw string data currently expects characters with code points between 0 and 255."
            )
        byte_values.append(code_point)
    return bytes(byte_values)


def _expr_to_byte_values(expr: Expr, function_name: str) -> tuple[int, ...]:
    if isinstance(expr, ByteArrayExpr):
        return expr.values
    if isinstance(expr, Call) and expr.has_head("List"):
        values = _integer_values(expr.arguments)
        if values is None:
            raise WolframEvaluationError(f"{function_name} expects a byte list or a ByteArray.")
        return byte_array_expr(values).values
    raise WolframEvaluationError(f"{function_name} expects a byte list or a ByteArray.")


def _real_from_float(value: float, function_name: str) -> Real:
    if not math.isfinite(value):
        raise WolframEvaluationError(f"{function_name} does not currently support infinite or indeterminate real values.")
    text = format(value, ".15g")
    if "E" in text:
        text = text.replace("E", "e")
    if "e" not in text and "." not in text:
        text += "."
    return real(text)


def _json_to_expr(data: object, *, raw_json: bool) -> Expr:
    if isinstance(data, _JsonObjectPairs):
        entries = [
            _AssociationEntry(rule_head="Rule", key=string(key), value=_json_to_expr(value, raw_json=raw_json))
            for key, value in data.pairs
        ]
        if raw_json:
            return _association_expr(entries)
        return list_expr(*(entry.to_expr() for entry in entries))
    if data is None:
        return symbol("Null")
    if isinstance(data, bool):
        return _bool_symbol(data)
    if isinstance(data, int):
        return integer(data)
    if isinstance(data, float):
        return _real_from_float(data, "ImportString")
    if isinstance(data, str):
        return string(data)
    if isinstance(data, list):
        return list_expr(*(_json_to_expr(item, raw_json=raw_json) for item in data))
    raise WolframEvaluationError("Unsupported JSON value encountered during import.")


def _rule_sequence_entries(expr: Expr) -> tuple[_AssociationEntry, ...] | None:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None
    entries: list[_AssociationEntry] = []
    for item in expr.arguments:
        entry = _rule_entry(item)
        if entry is None:
            return None
        entries.append(entry)
    return tuple(entries)


def _expr_to_json_value(expr: Expr, function_name: str, *, raw_json: bool) -> object:
    if isinstance(expr, String):
        return expr.value
    if isinstance(expr, Integer):
        return expr.value
    if isinstance(expr, Real):
        try:
            value = float(expr.text.replace("*^", "e"))
        except ValueError as exc:
            raise WolframEvaluationError(f"{function_name} could not convert {expr.to_input_form()} to a JSON number.") from exc
        if not math.isfinite(value):
            raise WolframEvaluationError(f"{function_name} does not currently support infinite or indeterminate JSON numbers.")
        return value
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
        if expr.name == "Null":
            return None
        raise WolframEvaluationError(f"{function_name} does not currently support exporting the symbol {expr.name} to JSON.")

    if isinstance(expr, Call) and expr.has_head("List"):
        entries = _rule_sequence_entries(expr)
        if entries is not None:
            if raw_json:
                raise WolframEvaluationError(f"{function_name} RawJSON export expects associations for JSON objects, not lists of rules.")
            result: dict[str, object] = {}
            for entry in entries:
                if not isinstance(entry.key, String):
                    raise WolframEvaluationError(f"{function_name} JSON object keys must be strings.")
                result[entry.key.value] = _expr_to_json_value(entry.value, function_name, raw_json=raw_json)
            return result
        return [_expr_to_json_value(item, function_name, raw_json=raw_json) for item in expr.arguments]

    association_entries = _association_entries(expr)
    if association_entries is not None:
        result: dict[str, object] = {}
        for entry in association_entries:
            if not isinstance(entry.key, String):
                raise WolframEvaluationError(f"{function_name} JSON object keys must be strings.")
            result[entry.key.value] = _expr_to_json_value(entry.value, function_name, raw_json=raw_json)
        return result

    raise WolframEvaluationError(f"{function_name} does not currently support exporting {expr.to_input_form()} as JSON.")


def _import_json_string(data: str, function_name: str, *, raw_json: bool) -> Expr:
    try:
        parsed = json.loads(data, object_pairs_hook=lambda pairs: _JsonObjectPairs(tuple(pairs)))
    except json.JSONDecodeError as exc:
        raise WolframEvaluationError(f"{function_name} could not parse the JSON payload.") from exc
    return _json_to_expr(parsed, raw_json=raw_json)


def _export_json_string(expr: Expr, function_name: str, *, raw_json: bool) -> String:
    value = _expr_to_json_value(expr, function_name, raw_json=raw_json)
    return string(json.dumps(value, ensure_ascii=False, indent="\t", separators=(",", ":")))


def _parse_tabular_atom(text: str) -> Expr:
    stripped = text.strip()
    if stripped == "":
        return string("")
    if re.fullmatch(r"[+-]?\d+", stripped):
        return integer(int(stripped))
    if _TABULAR_REAL_TOKEN.fullmatch(stripped):
        normalized = stripped.replace("*^", "e").replace("D", "e").replace("d", "e")
        try:
            return _real_from_float(float(normalized), "ImportString")
        except ValueError:
            pass
    return string(text)


def _import_delimited_string(data: str, delimiter: str) -> Expr:
    rows: list[Expr] = []
    reader = csv.reader(io.StringIO(data), delimiter=delimiter)
    for row in reader:
        rows.append(list_expr(*(_parse_tabular_atom(field) for field in row)))
    return list_expr(*rows)


def _import_table_string(data: str) -> Expr:
    rows: list[Expr] = []
    for line in data.splitlines():
        if line.strip() == "":
            rows.append(list_expr())
            continue
        rows.append(list_expr(*(_parse_tabular_atom(field) for field in line.split())))
    return list_expr(*rows)


def _tabular_export_rows(expr: Expr, function_name: str) -> list[list[str]]:
    def render_field(field: Expr) -> str:
        if isinstance(field, String):
            return field.value
        return field.to_input_form()

    if isinstance(expr, Call) and expr.has_head("List"):
        if not expr.arguments:
            return []
        if all(not (isinstance(item, Call) and item.has_head("List")) for item in expr.arguments):
            return [[render_field(item)] for item in expr.arguments]

        rows: list[list[str]] = []
        for row in expr.arguments:
            if not isinstance(row, Call) or not row.has_head("List"):
                raise WolframEvaluationError(f"{function_name} expects either a flat list or a list of rows.")
            rows.append([render_field(item) for item in row.arguments])
        return rows

    return [[render_field(expr)]]


def _export_delimited_string(expr: Expr, delimiter: str, function_name: str) -> String:
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter=delimiter, lineterminator="\n")
    writer.writerows(_tabular_export_rows(expr, function_name))
    return string(output.getvalue())


def _export_table_string(expr: Expr, function_name: str) -> String:
    rows = _tabular_export_rows(expr, function_name)
    return string("\n".join("\t".join(row) for row in rows))


def export_string(expr: Expr, format_value: Expr) -> String:
    spec = _normalize_import_export_format_spec(format_value, "ExportString")
    if spec.inner is not None:
        return _raw_bytes_to_string(export_byte_array(expr, format_value).values)

    if spec.name == "Text":
        return expr if isinstance(expr, String) else string(expr.to_input_form())
    if spec.name == "String":
        return expr if isinstance(expr, String) else string(expr.to_input_form())
    if spec.name == "Byte":
        return _raw_bytes_to_string(bytes(_expr_to_byte_values(expr, "ExportString")))
    if spec.name == "JSON":
        return _export_json_string(expr, "ExportString", raw_json=False)
    if spec.name == "RawJSON":
        return _export_json_string(expr, "ExportString", raw_json=True)
    if spec.name == "CSV":
        return _export_delimited_string(expr, ",", "ExportString")
    if spec.name == "TSV":
        return _export_delimited_string(expr, "\t", "ExportString")
    if spec.name == "Table":
        return _export_table_string(expr, "ExportString")
    if spec.name == "WL":
        return string(expr.to_input_form())
    raise WolframEvaluationError(f"Unsupported ExportString format: {spec.name}.")


def import_string_expr(data: Expr, format_value: Expr) -> Expr:
    if not isinstance(data, String):
        raise WolframEvaluationError("ImportString expects the source data to be a string.")
    spec = _normalize_import_export_format_spec(format_value, "ImportString")
    if spec.inner is not None:
        compressed = _raw_string_to_bytes(data, "ImportString")
        return import_byte_array(byte_array_expr(compressed), format_value)

    if spec.name == "Text" or spec.name == "String":
        return data
    if spec.name == "Byte":
        return list_expr(*(integer(value) for value in _raw_string_to_bytes(data, "ImportString")))
    if spec.name == "JSON":
        return _import_json_string(data.value, "ImportString", raw_json=False)
    if spec.name == "RawJSON":
        return _import_json_string(data.value, "ImportString", raw_json=True)
    if spec.name == "CSV":
        return _import_delimited_string(data.value, ",")
    if spec.name == "TSV":
        return _import_delimited_string(data.value, "\t")
    if spec.name == "Table":
        return _import_table_string(data.value)
    if spec.name == "WL":
        return parse_input_form(data.value)
    raise WolframEvaluationError(f"Unsupported ImportString format: {spec.name}.")


def _compress_bytes(data: bytes, format_name: str) -> bytes:
    if format_name == "GZIP":
        return gzip.compress(data)
    if format_name == "BZIP2":
        return bz2.compress(data)
    raise WolframEvaluationError(f"Unsupported compression wrapper: {format_name}.")


def _decompress_bytes(data: bytes, format_name: str, function_name: str) -> bytes:
    try:
        if format_name == "GZIP":
            return gzip.decompress(data)
        if format_name == "BZIP2":
            return bz2.decompress(data)
    except OSError as exc:
        raise WolframEvaluationError(f"{function_name} could not decompress the {format_name} payload.") from exc
    raise WolframEvaluationError(f"Unsupported compression wrapper: {format_name}.")


def export_byte_array(expr: Expr, format_value: Expr) -> ByteArrayExpr:
    spec = _normalize_import_export_format_spec(format_value, "ExportByteArray")
    if spec.inner is not None:
        inner_bytes = export_byte_array(expr, spec.inner.to_expr()).values
        return byte_array_expr(_compress_bytes(bytes(inner_bytes), spec.name))

    if spec.name == "Byte":
        return byte_array_expr(_expr_to_byte_values(expr, "ExportByteArray"))
    if spec.name == "String":
        if isinstance(expr, String):
            return byte_array_expr(_raw_string_to_bytes(expr, "ExportByteArray"))
        return byte_array_expr(_raw_string_to_bytes(expr.to_input_form(), "ExportByteArray"))
    if spec.name in _UTF8_TEXTUAL_FORMAT_NAMES:
        return byte_array_expr(export_string(expr, format_value).value.encode("utf-8"))
    raise WolframEvaluationError(f"Unsupported ExportByteArray format: {spec.name}.")


def import_byte_array(data: Expr, format_value: Expr) -> Expr:
    byte_values = _require_byte_array(data, "ImportByteArray").values
    spec = _normalize_import_export_format_spec(format_value, "ImportByteArray")
    if spec.inner is not None:
        decompressed = _decompress_bytes(bytes(byte_values), spec.name, "ImportByteArray")
        return import_byte_array(byte_array_expr(decompressed), spec.inner.to_expr())

    if spec.name == "Byte":
        return list_expr(*(integer(value) for value in byte_values))
    if spec.name == "String":
        return _raw_bytes_to_string(bytes(byte_values))
    if spec.name in _UTF8_TEXTUAL_FORMAT_NAMES:
        return import_string_expr(string(_decode_bytes_to_string(bytes(byte_values), "utf-8")), format_value)
    raise WolframEvaluationError(f"Unsupported ImportByteArray format: {spec.name}.")


def _string_thread(
    expr: Expr,
    function_name: str,
    scalar_function: Callable[[String], Expr],
) -> Expr:
    if isinstance(expr, String):
        return scalar_function(expr)
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(_string_thread(item, function_name, scalar_function) for item in expr.arguments))
    raise WolframEvaluationError(f"{function_name} expects a string or a list of strings.")


def string_length(expr: Expr) -> Expr:
    return _string_thread(expr, "StringLength", lambda item: integer(len(item.value)))


def _validate_string_selectors(length_value: int, selectors: Sequence[int], function_name: str) -> list[int]:
    for selector in selectors:
        _resolve_index(length_value, selector)
    return list(selectors)


def _normalize_string_take_drop_selectors(text: str, spec: Expr | int, function_name: str) -> list[int]:
    count = len(text)

    if isinstance(spec, int):
        selectors = list(range(1, spec + 1)) if spec >= 0 else list(range(count + spec + 1, count + 1))
        return _validate_string_selectors(count, selectors, function_name)

    if isinstance(spec, Integer):
        return _normalize_string_take_drop_selectors(text, spec.value, function_name)

    if isinstance(spec, Symbol) and spec.name == "All":
        return list(range(1, count + 1))

    if isinstance(spec, Call) and spec.has_head("UpTo"):
        if len(spec.arguments) != 1 or not isinstance(spec.arguments[0], Integer):
            raise WolframEvaluationError(f"{function_name} currently supports only integer UpTo specifications.")
        limit = spec.arguments[0].value
        if limit >= 0:
            return list(range(1, min(count, limit) + 1))
        kept = min(count, -limit)
        return list(range(count - kept + 1, count + 1))

    if isinstance(spec, Call) and spec.has_head("Span"):
        return _validate_string_selectors(count, _expand_span_spec_from_count(count, spec), function_name)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1:
            item = spec.arguments[0]
            if isinstance(item, Integer):
                return _validate_string_selectors(count, [item.value], function_name)
            if isinstance(item, Symbol) and item.name == "All":
                return list(range(1, count + 1))
            if isinstance(item, Call) and item.has_head("UpTo"):
                return _normalize_string_take_drop_selectors(text, item, function_name)
            raise WolframEvaluationError(
                f"{function_name} single-element list specifications must contain an integer, All, or UpTo[n]."
            )
        if len(spec.arguments) in {2, 3}:
            return _validate_string_selectors(
                count,
                _expand_span_spec_from_count(count, Call(head_expr=Symbol("Span"), arguments=spec.arguments)),
                function_name,
            )
        raise WolframEvaluationError(f"{function_name} list specifications must contain one, two, or three items.")

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _string_take_or_drop_scalar(text: str, spec: Expr | int, *, drop: bool) -> String:
    function_name = "StringDrop" if drop else "StringTake"
    selectors = _normalize_string_take_drop_selectors(text, spec, function_name)
    if drop:
        removed = {_resolve_index(len(text), selector) for selector in selectors}
        return string("".join(character for index, character in enumerate(text) if index not in removed))
    return string("".join(text[_resolve_index(len(text), selector)] for selector in selectors))


def string_take(expr: Expr, spec: Expr | int) -> Expr:
    return _string_thread(expr, "StringTake", lambda item: _string_take_or_drop_scalar(item.value, spec, drop=False))


def string_drop(expr: Expr, spec: Expr | int) -> Expr:
    return _string_thread(expr, "StringDrop", lambda item: _string_take_or_drop_scalar(item.value, spec, drop=True))


def _flatten_string_join_items(expr: Expr) -> list[str]:
    if isinstance(expr, String):
        return [expr.value]
    if isinstance(expr, Call) and expr.has_head("List"):
        flattened: list[str] = []
        for item in expr.arguments:
            flattened.extend(_flatten_string_join_items(item))
        return flattened
    raise WolframEvaluationError("StringJoin expects strings or nested lists of strings.")


def string_join(*exprs: Expr) -> String:
    pieces: list[str] = []
    for expr in exprs:
        pieces.extend(_flatten_string_join_items(expr))
    return string("".join(pieces))


def _resolve_string_insert_index(length_value: int, position: int) -> int:
    if position > 0:
        resolved = position - 1
    elif position < 0:
        resolved = length_value + position + 1
    else:
        raise WolframEvaluationError("StringInsert positions must be nonzero integers.")

    if not 0 <= resolved <= length_value:
        raise WolframEvaluationError(f"StringInsert position {position} is out of range for length {length_value}.")
    return resolved


def _normalize_string_insert_positions(length_value: int, positions: Expr | int) -> list[int]:
    if isinstance(positions, int):
        return [_resolve_string_insert_index(length_value, positions)]

    if isinstance(positions, Integer):
        return [_resolve_string_insert_index(length_value, positions.value)]

    if isinstance(positions, Call) and positions.has_head("List"):
        normalized: list[int] = []
        for item in positions.arguments:
            if not isinstance(item, Integer):
                raise WolframEvaluationError("StringInsert position lists must contain only integers.")
            normalized.append(_resolve_string_insert_index(length_value, item.value))
        return normalized

    raise WolframEvaluationError("StringInsert expects an integer position or a list of integer positions.")


def _string_insert_scalar(text: str, insertion: str, positions: Expr | int) -> String:
    resolved_positions = _normalize_string_insert_positions(len(text), positions)
    grouped: dict[int, list[str]] = {}
    for resolved in resolved_positions:
        grouped.setdefault(resolved, []).append(insertion)

    pieces: list[str] = []
    for index in range(len(text) + 1):
        pieces.extend(grouped.get(index, ()))
        if index < len(text):
            pieces.append(text[index])
    return string("".join(pieces))


def string_insert(expr: Expr, insertion: Expr, positions: Expr | int) -> Expr:
    if not isinstance(insertion, String):
        raise WolframEvaluationError("StringInsert expects the inserted value to be a string.")
    return _string_thread(
        expr,
        "StringInsert",
        lambda item: _string_insert_scalar(item.value, insertion.value, positions),
    )


def string_reverse(expr: Expr) -> Expr:
    return _string_thread(expr, "StringReverse", lambda item: string(item.value[::-1]))


@dataclass
class _StringPatternState:
    end: int
    bindings: dict[str, Expr]


@dataclass(frozen=True)
class _StringPatternSpec:
    pattern: Expr
    template: Expr | None
    delayed: bool


@dataclass
class _StringFoundMatch:
    start: int
    end: int
    bindings: dict[str, Expr]
    spec: _StringPatternSpec


@dataclass(frozen=True)
class _ImportExportFormatSpec:
    name: str
    inner: _ImportExportFormatSpec | None = None

    def to_expr(self) -> Expr:
        if self.inner is None:
            return string(self.name)
        return list_expr(string(self.name), self.inner.to_expr())


@dataclass(frozen=True)
class _JsonObjectPairs:
    pairs: tuple[tuple[str, object], ...]


_STRING_CHARACTER_CLASS_SYMBOLS = {
    "DigitCharacter",
    "LetterCharacter",
    "WhitespaceCharacter",
    "WordCharacter",
}

_STRING_ZERO_WIDTH_SYMBOLS = {
    "StartOfString",
    "EndOfString",
}

_UNSUPPORTED_STRING_PATTERN_HEADS = {
    "Longest",
    "Optional",
    "OptionsPattern",
    "PatternTest",
    "RegularExpression",
    "Shortest",
}

_IMPORT_EXPORT_FORMAT_NAMES = {
    "byte": "Byte",
    "bzip2": "BZIP2",
    "csv": "CSV",
    "gzip": "GZIP",
    "json": "JSON",
    "rawjson": "RawJSON",
    "string": "String",
    "table": "Table",
    "text": "Text",
    "tsv": "TSV",
    "wl": "WL",
}

_COMPRESSED_FORMAT_NAMES = {"GZIP", "BZIP2"}
_UTF8_TEXTUAL_FORMAT_NAMES = {"CSV", "JSON", "RawJSON", "Table", "Text", "TSV", "WL"}
_TABULAR_REAL_TOKEN = re.compile(
    r"^[+-]?(?:\d+\.\d*|\.\d+|\d+(?:[eEdD][+-]?\d+)|\d+\*\^[+-]?\d+|\d+\.\d*(?:[eEdD][+-]?\d+)?|\.\d+(?:[eEdD][+-]?\d+)?)$"
)


def _unsupported_string_pattern(expr: Expr) -> WolframEvaluationError:
    return WolframEvaluationError(
        f"Unsupported Wolfram string-pattern form in the current Tungsten subset: {expr.to_input_form()}."
    )


def _normalize_string_pattern_element(pattern: Expr) -> Expr:
    if isinstance(pattern, Symbol) and pattern.name == "Whitespace":
        return call("Repeated", symbol("WhitespaceCharacter"))
    return pattern


def _flatten_string_expression_parts(pattern: Expr) -> list[Expr]:
    normalized = _normalize_string_pattern_element(pattern)
    if isinstance(normalized, Call) and normalized.has_head("StringExpression"):
        flattened: list[Expr] = []
        for item in normalized.arguments:
            flattened.extend(_flatten_string_expression_parts(item))
        return flattened
    return [normalized]


def _is_single_character_string_class_pattern(expr: Expr) -> bool:
    normalized = _normalize_string_pattern_element(expr)
    if isinstance(normalized, String):
        return len(normalized.value) == 1
    if isinstance(normalized, Symbol):
        return normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS
    if isinstance(normalized, Call) and isinstance(normalized.head_expr, Symbol):
        head_name = normalized.head_expr.name
        if head_name == "Blank":
            return len(normalized.arguments) == 0
        if head_name == "CharacterRange":
            return len(normalized.arguments) == 2
        if head_name == "HoldPattern":
            return len(normalized.arguments) == 1 and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name == "Pattern":
            return len(normalized.arguments) == 2 and _is_single_character_string_class_pattern(normalized.arguments[1])
        if head_name == "Condition":
            return len(normalized.arguments) == 2 and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name == "Alternatives":
            return bool(normalized.arguments) and all(
                _is_single_character_string_class_pattern(argument)
                for argument in normalized.arguments
            )
        if head_name == "Except":
            return len(normalized.arguments) == 1 and _is_single_character_string_class_pattern(normalized.arguments[0])
    return False


def _is_unbounded_string_pattern(expr: Expr) -> bool:
    normalized = _normalize_string_pattern_element(expr)
    return (
        isinstance(normalized, Call)
        and isinstance(normalized.head_expr, Symbol)
        and normalized.head_expr.name in {"BlankSequence", "BlankNullSequence", "Repeated", "RepeatedNull"}
    )


def _character_range_bounds(pattern: Call) -> tuple[str, str]:
    if len(pattern.arguments) != 2:
        raise WolframEvaluationError("CharacterRange expects exactly two arguments in string patterns.")
    start, end = pattern.arguments
    if not isinstance(start, String) or not isinstance(end, String) or len(start.value) != 1 or len(end.value) != 1:
        raise WolframEvaluationError("CharacterRange currently expects one-character string bounds.")
    return start.value, end.value


def _string_character_matches_symbol(name: str, character: str) -> bool:
    if name == "DigitCharacter":
        return character.isdigit()
    if name == "LetterCharacter":
        return character.isalpha()
    if name == "WhitespaceCharacter":
        return character.isspace()
    if name == "WordCharacter":
        return character.isalnum() or character == "_"
    return False


def _match_single_character_string_pattern(
    character: str,
    pattern: Expr,
    bindings: dict[str, Expr],
) -> list[dict[str, Expr]]:
    current = dict(bindings)
    normalized = _normalize_string_pattern_element(pattern)

    if isinstance(normalized, String):
        return [current] if normalized.value == character else []

    if isinstance(normalized, Symbol):
        if normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS:
            return [current] if _string_character_matches_symbol(normalized.name, character) else []
        if normalized.name in _STRING_ZERO_WIDTH_SYMBOLS or normalized.name == "Whitespace":
            raise _unsupported_string_pattern(normalized)
        raise _unsupported_string_pattern(normalized)

    if not isinstance(normalized, Call) or not isinstance(normalized.head_expr, Symbol):
        raise _unsupported_string_pattern(normalized)

    head_name = normalized.head_expr.name
    if head_name in _UNSUPPORTED_STRING_PATTERN_HEADS:
        raise _unsupported_string_pattern(normalized)

    if head_name == "HoldPattern":
        if len(normalized.arguments) != 1:
            raise WolframEvaluationError("HoldPattern expects exactly one argument.")
        return _match_single_character_string_pattern(character, normalized.arguments[0], current)

    if head_name == "Alternatives":
        matches: list[dict[str, Expr]] = []
        for branch in normalized.arguments:
            matches.extend(_match_single_character_string_pattern(character, branch, current))
        return matches

    if head_name == "Condition":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        matches = _match_single_character_string_pattern(character, normalized.arguments[0], current)
        return [
            match
            for match in matches
            if _condition_test_succeeds(normalized.arguments[1], match)
        ]

    if head_name == "Pattern":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Pattern expects exactly two arguments.")
        name_expr, inner_pattern = normalized.arguments
        if not isinstance(name_expr, Symbol):
            raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
        if _is_unbounded_string_pattern(inner_pattern):
            raise _unsupported_string_pattern(normalized)
        matches = _match_single_character_string_pattern(character, inner_pattern, current)
        bound_value = string(character)
        updated_matches: list[dict[str, Expr]] = []
        for match in matches:
            existing = match.get(name_expr.name)
            if existing is not None and existing != bound_value:
                continue
            updated = dict(match)
            updated[name_expr.name] = bound_value
            updated_matches.append(updated)
        return updated_matches

    if head_name == "Except":
        if len(normalized.arguments) != 1:
            raise WolframEvaluationError("Except expects exactly one argument in string patterns.")
        if not _is_single_character_string_class_pattern(normalized.arguments[0]):
            raise WolframEvaluationError("String-pattern Except currently supports only single-character subpatterns.")
        disallowed = _match_single_character_string_pattern(character, normalized.arguments[0], current)
        return [] if disallowed else [current]

    if head_name == "Blank":
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        return [current]

    if head_name == "CharacterRange":
        start_char, end_char = _character_range_bounds(normalized)
        return [current] if start_char <= character <= end_char else []

    raise _unsupported_string_pattern(normalized)


def _match_repeated_single_character_pattern(
    pattern: Call,
    text: str,
    start: int,
    bindings: dict[str, Expr],
) -> list[_StringPatternState]:
    head_name = pattern.head_expr.name
    assert head_name in {"Repeated", "RepeatedNull"}
    if len(pattern.arguments) != 1:
        raise WolframEvaluationError(f"{head_name} expects exactly one argument in string patterns.")
    inner = pattern.arguments[0]
    if not _is_single_character_string_class_pattern(inner):
        raise WolframEvaluationError(
            f"{head_name} currently supports only single-character subpatterns in Tungsten string patterns."
        )

    states: list[_StringPatternState] = [_StringPatternState(end=start, bindings=dict(bindings))]
    frontier: list[_StringPatternState] = [_StringPatternState(end=start, bindings=dict(bindings))]

    while frontier:
        next_frontier: list[_StringPatternState] = []
        for state in frontier:
            if state.end >= len(text):
                continue
            matches = _match_single_character_string_pattern(text[state.end], inner, state.bindings)
            for matched_bindings in matches:
                next_frontier.append(_StringPatternState(end=state.end + 1, bindings=matched_bindings))
        if not next_frontier:
            break
        states.extend(next_frontier)
        frontier = next_frontier

    minimum_length = 0 if head_name == "RepeatedNull" else 1
    return [
        state
        for state in sorted(states, key=lambda item: item.end, reverse=True)
        if state.end - start >= minimum_length
    ]


def _match_string_expression_parts(
    parts: Sequence[Expr],
    text: str,
    start: int,
    bindings: dict[str, Expr],
) -> list[_StringPatternState]:
    normalized_parts = [_normalize_string_pattern_element(part) for part in parts]
    unbounded_indexes = [
        index
        for index, item in enumerate(normalized_parts)
        if _is_unbounded_string_pattern(item)
    ]

    if len(unbounded_indexes) > 1:
        raise WolframEvaluationError(
            "Tungsten currently supports at most one unbounded string-pattern element per StringExpression."
        )

    if not unbounded_indexes:
        states = [_StringPatternState(end=start, bindings=dict(bindings))]
        for item in normalized_parts:
            next_states: list[_StringPatternState] = []
            for state in states:
                next_states.extend(_match_string_pattern_states(item, text, state.end, state.bindings))
            if not next_states:
                return []
            states = next_states
        return states

    variable_index = unbounded_indexes[0]
    prefix = normalized_parts[:variable_index]
    suffix = normalized_parts[variable_index + 1:]

    prefix_states = _match_string_expression_parts(prefix, text, start, bindings) if prefix else [
        _StringPatternState(end=start, bindings=dict(bindings))
    ]

    results: list[_StringPatternState] = []
    for prefix_state in prefix_states:
        variable_states = _match_string_pattern_states(
            normalized_parts[variable_index],
            text,
            prefix_state.end,
            prefix_state.bindings,
        )
        for variable_state in variable_states:
            if suffix:
                results.extend(_match_string_expression_parts(suffix, text, variable_state.end, variable_state.bindings))
            else:
                results.append(variable_state)
    return results


def _match_string_pattern_states(
    pattern: Expr,
    text: str,
    start: int,
    bindings: dict[str, Expr] | None = None,
) -> list[_StringPatternState]:
    current = {} if bindings is None else dict(bindings)
    normalized = _normalize_string_pattern_element(pattern)

    if isinstance(normalized, String):
        if text.startswith(normalized.value, start):
            return [_StringPatternState(end=start + len(normalized.value), bindings=current)]
        return []

    if isinstance(normalized, Symbol):
        if normalized.name == "Whitespace":
            return _match_string_pattern_states(call("Repeated", symbol("WhitespaceCharacter")), text, start, current)
        if normalized.name == "StartOfString":
            return [_StringPatternState(end=start, bindings=current)] if start == 0 else []
        if normalized.name == "EndOfString":
            return [_StringPatternState(end=start, bindings=current)] if start == len(text) else []
        if normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS:
            if start >= len(text):
                return []
            matches = _match_single_character_string_pattern(text[start], normalized, current)
            return [_StringPatternState(end=start + 1, bindings=match) for match in matches]
        raise _unsupported_string_pattern(normalized)

    if not isinstance(normalized, Call) or not isinstance(normalized.head_expr, Symbol):
        raise _unsupported_string_pattern(normalized)

    head_name = normalized.head_expr.name
    if head_name in _UNSUPPORTED_STRING_PATTERN_HEADS:
        raise _unsupported_string_pattern(normalized)

    if head_name == "HoldPattern":
        if len(normalized.arguments) != 1:
            raise WolframEvaluationError("HoldPattern expects exactly one argument.")
        return _match_string_pattern_states(normalized.arguments[0], text, start, current)

    if head_name == "StringExpression":
        return _match_string_expression_parts(_flatten_string_expression_parts(normalized), text, start, current)

    if head_name == "Alternatives":
        matches: list[_StringPatternState] = []
        for branch in normalized.arguments:
            matches.extend(_match_string_pattern_states(branch, text, start, current))
        return matches

    if head_name == "Condition":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        matches = _match_string_pattern_states(normalized.arguments[0], text, start, current)
        return [
            state
            for state in matches
            if _condition_test_succeeds(normalized.arguments[1], state.bindings)
        ]

    if head_name == "Pattern":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Pattern expects exactly two arguments.")
        name_expr, inner_pattern = normalized.arguments
        if not isinstance(name_expr, Symbol):
            raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
        if _is_sequence_argument_pattern(inner_pattern):
            raise _unsupported_string_pattern(normalized)
        matches = _match_string_pattern_states(inner_pattern, text, start, current)
        updated_matches: list[_StringPatternState] = []
        for state in matches:
            bound_value = string(text[start:state.end])
            existing = state.bindings.get(name_expr.name)
            if existing is not None and existing != bound_value:
                continue
            updated_bindings = dict(state.bindings)
            updated_bindings[name_expr.name] = bound_value
            updated_matches.append(_StringPatternState(end=state.end, bindings=updated_bindings))
        return updated_matches

    if head_name == "Blank":
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        if start >= len(text):
            return []
        return [_StringPatternState(end=start + 1, bindings=current)]

    if head_name in {"BlankSequence", "BlankNullSequence"}:
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        minimum_length = 0 if head_name == "BlankNullSequence" else 1
        return [
            _StringPatternState(end=end, bindings=dict(current))
            for end in range(len(text), start + minimum_length - 1, -1)
        ]

    if head_name in {"Repeated", "RepeatedNull"}:
        return _match_repeated_single_character_pattern(normalized, text, start, current)

    if head_name == "Except":
        if start >= len(text):
            return []
        matches = _match_single_character_string_pattern(text[start], normalized, current)
        return [_StringPatternState(end=start + 1, bindings=match) for match in matches]

    if head_name == "CharacterRange":
        if start >= len(text):
            return []
        matches = _match_single_character_string_pattern(text[start], normalized, current)
        return [_StringPatternState(end=start + 1, bindings=match) for match in matches]

    raise _unsupported_string_pattern(normalized)


def _normalize_string_pattern_specs(pattern: Expr, function_name: str) -> list[_StringPatternSpec]:
    if isinstance(pattern, Call) and pattern.has_head("List"):
        return [_StringPatternSpec(item, None, False) for item in pattern.arguments]
    return [_StringPatternSpec(pattern, None, False)]


def _normalize_string_cases_specs(pattern_spec: Expr) -> list[_StringPatternSpec]:
    if isinstance(pattern_spec, Call) and pattern_spec.has_head("List"):
        specs: list[_StringPatternSpec] = []
        for item in pattern_spec.arguments:
            specs.extend(_normalize_string_cases_specs(item))
        return specs
    if _is_replacement_rule_expr(pattern_spec):
        assert isinstance(pattern_spec, Call)
        pattern, template = pattern_spec.arguments
        delayed = pattern_spec.has_head("RuleDelayed")
        if not delayed:
            template = evaluate(template)
        return [_StringPatternSpec(pattern, template, delayed)]
    return [_StringPatternSpec(pattern_spec, None, False)]


def _normalize_string_replace_specs(rules: Expr) -> list[_StringPatternSpec]:
    if isinstance(rules, Call) and rules.has_head("List"):
        specs: list[_StringPatternSpec] = []
        for item in rules.arguments:
            specs.extend(_normalize_string_replace_specs(item))
        return specs
    if not _is_replacement_rule_expr(rules):
        raise WolframEvaluationError("StringReplace expects a rule or a list of rules.")
    assert isinstance(rules, Call)
    pattern, template = rules.arguments
    delayed = rules.has_head("RuleDelayed")
    if not delayed:
        template = evaluate(template)
    return [_StringPatternSpec(pattern, template, delayed)]


def _first_string_match_at(
    text: str,
    start: int,
    specs: Sequence[_StringPatternSpec],
    *,
    require_end: bool = False,
) -> _StringFoundMatch | None:
    for spec in specs:
        matches = _match_string_pattern_states(spec.pattern, text, start)
        for match in matches:
            if require_end and match.end != len(text):
                continue
            return _StringFoundMatch(start=start, end=match.end, bindings=match.bindings, spec=spec)
    return None


def _collect_string_matches(
    text: str,
    specs: Sequence[_StringPatternSpec],
    *,
    overlaps: bool,
    limit: int | None = None,
    require_start: bool = False,
    require_end: bool = False,
) -> list[_StringFoundMatch]:
    matches: list[_StringFoundMatch] = []
    start = 0
    while start <= len(text):
        found = _first_string_match_at(text, start, specs, require_end=require_end)
        if found is None:
            if require_start:
                break
            start += 1
            continue
        matches.append(found)
        if limit is not None and len(matches) >= limit:
            break
        if require_start:
            break
        if overlaps:
            start += 1
        else:
            start = found.end if found.end > start else start + 1
    return matches


def _match_string_boolean(
    text: str,
    specs: Sequence[_StringPatternSpec],
    *,
    require_start: bool = False,
    require_end: bool = False,
) -> bool:
    return bool(_collect_string_matches(text, specs, overlaps=True, limit=1, require_start=require_start, require_end=require_end))


def _string_position_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    matches = _collect_string_matches(text, specs, overlaps=True, limit=limit)
    return list_expr(*(list_expr(integer(match.start + 1), integer(match.end)) for match in matches))


def _flatten_string_expression_pieces(expr: Expr) -> list[Expr]:
    if isinstance(expr, Call) and expr.has_head("StringExpression"):
        flattened: list[Expr] = []
        for item in expr.arguments:
            flattened.extend(_flatten_string_expression_pieces(item))
        return flattened
    return [expr]


def _string_expression_from_pieces(pieces: Sequence[Expr]) -> Expr:
    flattened: list[Expr] = []
    for piece in pieces:
        flattened.extend(_flatten_string_expression_pieces(piece))

    if not flattened:
        return string("")

    merged: list[Expr] = []
    string_buffer = ""
    for piece in flattened:
        if isinstance(piece, String):
            string_buffer += piece.value
            continue
        if string_buffer:
            merged.append(string(string_buffer))
            string_buffer = ""
        merged.append(piece)
    if string_buffer:
        merged.append(string(string_buffer))

    if not merged:
        return string("")
    if len(merged) == 1:
        return merged[0]
    if all(isinstance(piece, String) for piece in merged):
        return string("".join(piece.value for piece in merged if isinstance(piece, String)))
    return call("StringExpression", *merged)


def string_match_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringMatchQ")
    return _string_thread(
        expr,
        "StringMatchQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_start=True, require_end=True)),
    )


def string_free_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringFreeQ")
    return _string_thread(
        expr,
        "StringFreeQ",
        lambda item: _bool_symbol(not _match_string_boolean(item.value, specs)),
    )


def string_position(expr: Expr, pattern: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringPosition")
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringPosition",
        lambda item: _string_position_scalar(item.value, specs, normalized_limit),
    )


def string_contains_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringContainsQ")
    return _string_thread(
        expr,
        "StringContainsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs)),
    )


def string_starts_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringStartsQ")
    return _string_thread(
        expr,
        "StringStartsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_start=True)),
    )


def string_ends_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringEndsQ")
    return _string_thread(
        expr,
        "StringEndsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_end=True)),
    )


def _first_string_case_or_replacement_match_at(
    text: str,
    start: int,
    specs: Sequence[_StringPatternSpec],
) -> tuple[_StringFoundMatch, Expr] | None:
    for spec in specs:
        matches = _match_string_pattern_states(spec.pattern, text, start)
        for match in matches:
            found = _StringFoundMatch(start=start, end=match.end, bindings=match.bindings, spec=spec)
            if spec.template is None:
                return (found, string(text[start:match.end]))
            transformed, applied = _instantiate_replacement_template(
                spec.template,
                match.bindings,
                delayed=spec.delayed,
            )
            if not applied:
                continue
            assert transformed is not None
            return (found, transformed)
    return None


def _string_cases_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    results: list[Expr] = []
    position = 0
    while position <= len(text):
        if limit is not None and len(results) >= limit:
            break
        found = _first_string_case_or_replacement_match_at(text, position, specs)
        if found is None:
            if position >= len(text):
                break
            position += 1
            continue
        match, result = found
        results.append(result)
        position = match.end if match.end > position else position + 1
    return _evaluated_list_expr(*results)


def string_cases(expr: Expr, pattern_spec: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_cases_specs(pattern_spec)
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringCases",
        lambda item: _string_cases_scalar(item.value, specs, normalized_limit),
    )


def _string_replace_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    pieces: list[Expr] = []
    position = 0
    replacements = 0

    while position <= len(text):
        if limit is not None and replacements >= limit:
            break
        found = _first_string_case_or_replacement_match_at(text, position, specs)
        if found is None:
            if position >= len(text):
                break
            pieces.append(string(text[position]))
            position += 1
            continue
        match, transformed = found
        pieces.append(transformed)
        replacements += 1
        next_position = match.end if match.end > position else position + 1
        position = next_position

    if position < len(text):
        pieces.append(string(text[position:]))

    return _string_expression_from_pieces(pieces)


def string_replace(expr: Expr, rules: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_replace_specs(rules)
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringReplace",
        lambda item: _string_replace_scalar(item.value, specs, normalized_limit),
    )


_UNSUPPORTED_PATTERN_HEADS = {
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


_SEQUENCE_PATTERN_HEADS = {"BlankSequence", "BlankNullSequence"}


def _direct_sequence_pattern_head_name(expr: Expr) -> str | None:
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _SEQUENCE_PATTERN_HEADS:
        return expr.head_expr.name
    return None


def _is_sequence_argument_pattern(pattern: Expr) -> bool:
    if _direct_sequence_pattern_head_name(pattern) is not None:
        return True
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name
        if head_name in {"HoldPattern", "Condition"} and pattern.arguments:
            return _is_sequence_argument_pattern(pattern.arguments[0])
        if head_name == "Pattern" and len(pattern.arguments) == 2:
            return _is_sequence_argument_pattern(pattern.arguments[1])
        if head_name == "Alternatives":
            return any(_is_sequence_argument_pattern(argument) for argument in pattern.arguments)
    return False


def _sequence_pattern_min_length(pattern: Expr) -> int:
    head_name = _direct_sequence_pattern_head_name(pattern)
    if head_name == "BlankSequence":
        return 1
    if head_name == "BlankNullSequence":
        return 0
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        if pattern.head_expr.name in {"HoldPattern", "Condition"} and pattern.arguments:
            return _sequence_pattern_min_length(pattern.arguments[0])
        if pattern.head_expr.name == "Pattern" and len(pattern.arguments) == 2:
            return _sequence_pattern_min_length(pattern.arguments[1])
        if pattern.head_expr.name == "Alternatives" and pattern.arguments:
            return min(
                _sequence_pattern_min_length(argument) if _is_sequence_argument_pattern(argument) else 1
                for argument in pattern.arguments
            )
    raise WolframEvaluationError(f"Expected a sequence pattern, got {pattern.to_input_form()}.")


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


def _match_sequence_pattern_elements(
    exprs: Sequence[Expr],
    pattern: Expr,
    bindings: dict[str, Expr],
) -> dict[str, Expr] | None:
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = pattern.head_expr.name

        if head_name == "Alternatives":
            if not pattern.arguments:
                return None
            for branch in pattern.arguments:
                matched = _match_sequence_pattern_elements(exprs, branch, bindings)
                if matched is not None:
                    return matched
            return None

        if head_name == "HoldPattern":
            if len(pattern.arguments) != 1:
                raise WolframEvaluationError("HoldPattern expects exactly one argument.")
            return _match_sequence_pattern_elements(exprs, pattern.arguments[0], bindings)

        if head_name == "Condition":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Condition expects exactly two arguments.")
            matched = _match_sequence_pattern_elements(exprs, pattern.arguments[0], bindings)
            if matched is None:
                return None
            return matched if _condition_test_succeeds(pattern.arguments[1], matched) else None

        if head_name == "Pattern":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            if not _is_sequence_argument_pattern(inner_pattern):
                raise WolframEvaluationError("Pattern is not wrapping a sequence pattern.")
            matched = _match_sequence_pattern_elements(exprs, inner_pattern, bindings)
            if matched is None:
                return None
            return _bind_pattern_name(matched, name_expr.name, _sequence_binding_value(exprs))

    head_name = _direct_sequence_pattern_head_name(pattern)
    if head_name is None:
        if len(exprs) != 1:
            return None
        return _match_pattern(exprs[0], pattern, bindings)

    assert isinstance(pattern, Call)
    if len(pattern.arguments) > 1:
        raise WolframEvaluationError(f"{head_name} expects zero or one argument.")
    if not exprs and head_name == "BlankSequence":
        return None

    matched = dict(bindings)
    element_pattern = call("Blank", *pattern.arguments)
    for item in exprs:
        matched = _match_pattern(item, element_pattern, matched)
        if matched is None:
            return None
    return matched


def _match_call_arguments(
    expr_arguments: Sequence[Expr],
    pattern_arguments: Sequence[Expr],
    bindings: dict[str, Expr],
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
            matched = _match_pattern(expr_arguments[expr_index], pattern_argument, current)
            if matched is None:
                return None
            return recurse(expr_index + 1, pattern_index + 1, matched)

        min_length = _sequence_pattern_min_length(pattern_argument)
        remaining_minimum = _minimum_argument_count(pattern_arguments[pattern_index + 1:])
        max_length = len(expr_arguments) - expr_index - remaining_minimum
        for length in range(min_length, max_length + 1):
            segment = expr_arguments[expr_index:expr_index + length]
            matched = _match_sequence_pattern_elements(segment, pattern_argument, current)
            if matched is None:
                continue
            final = recurse(expr_index + length, pattern_index + 1, matched)
            if final is not None:
                return final
        return None

    return recurse(0, 0, dict(bindings))


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

        if head_name == "Condition":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Condition expects exactly two arguments.")
            matched = _match_pattern(expr, pattern.arguments[0], current)
            if matched is None:
                return None
            return matched if _condition_test_succeeds(pattern.arguments[1], matched) else None

        if head_name == "Pattern":
            if len(pattern.arguments) != 2:
                raise WolframEvaluationError("Pattern expects exactly two arguments.")
            name_expr, inner_pattern = pattern.arguments
            if not isinstance(name_expr, Symbol):
                raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
            if _is_sequence_argument_pattern(inner_pattern):
                return _match_sequence_pattern_elements((expr,), pattern, current)
            matched = _match_pattern(expr, inner_pattern, current)
            if matched is None:
                return None
            bound = matched.get(name_expr.name)
            if bound is not None:
                return matched if bound == expr else None
            return _bind_pattern_name(matched, name_expr.name, expr)

        if head_name == "Blank":
            if len(pattern.arguments) == 0:
                return current
            if len(pattern.arguments) == 1:
                return _match_pattern(head_of(expr), pattern.arguments[0], current)
            raise WolframEvaluationError("Blank expects zero or one argument.")

        if head_name in _SEQUENCE_PATTERN_HEADS:
            if len(pattern.arguments) > 1:
                raise WolframEvaluationError(f"{head_name} expects zero or one argument.")
            return _match_pattern(expr, call("Blank", *pattern.arguments), current)

    if isinstance(pattern, Call):
        if not isinstance(expr, Call):
            return None
        matched = _match_pattern(head_of(expr), pattern.head_expr, current)
        if matched is None:
            return None
        return _match_call_arguments(expr.arguments, pattern.arguments, matched)

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
    if _is_association(expr):
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
    if not isinstance(x, Integer):
        raise WolframEvaluationError("Clip currently evaluates only for explicit integer arguments.")

    if len(arguments) == 1:
        return integer(min(max(x.value, -1), 1))

    bounds = arguments[1]
    if not isinstance(bounds, Call) or not bounds.has_head("List") or len(bounds.arguments) != 2:
        raise WolframEvaluationError("Clip currently expects bounds of the form {min, max}.")
    lower, upper = bounds.arguments
    if not isinstance(lower, Integer) or not isinstance(upper, Integer):
        raise WolframEvaluationError("Clip currently evaluates only for explicit integer bounds.")

    if x.value < lower.value:
        if len(arguments) == 3:
            replacements = arguments[2]
            if not isinstance(replacements, Call) or not replacements.has_head("List") or len(replacements.arguments) != 2:
                raise WolframEvaluationError("Clip currently expects replacement values of the form {vmin, vmax}.")
            return replacements.arguments[0]
        return lower

    if x.value > upper.value:
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
) -> tuple[Expr | None, bool]:
    substituted = _substitute_pattern_bindings(template, bindings)
    if delayed and isinstance(substituted, Call) and substituted.has_head("Condition"):
        if len(substituted.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        body, test = substituted.arguments
        if not _condition_test_succeeds(test, {}):
            return (None, False)
        return _instantiate_replacement_template(body, {}, delayed=True)
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


def _apply_replacement_rules(expr: Expr, ruleset: Sequence[_ReplacementRule]) -> tuple[Expr, bool]:
    for rule in ruleset:
        bindings = _match_pattern(expr, rule.pattern)
        if bindings is None:
            continue
        replacement, applied = _instantiate_replacement_template(rule.template, bindings, delayed=rule.delayed)
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
        replaced, _did_replace = _apply_replacement_rules(rebuilt, ruleset)
        return replaced
    return rebuilt


def replace(
    expr: Expr,
    rules: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Expr:
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
    replaced, did_replace = _apply_replacement_rules(expr, ruleset)
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
    if _is_nested_replacement_rules_list(rules):
        assert isinstance(rules, Call)
        return _evaluated_list_expr(*(replace_all(expr, item) for item in rules.arguments))
    ruleset = _normalize_single_replacement_ruleset(rules, "ReplaceAll")
    return _replace_all_single_pass(expr, ruleset)[0]


def replace_repeated(expr: Expr, rules: Expr) -> Expr:
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
    if _is_association(expr):
        negative_level = -depth(expr)
        if _level_bounds_match(positive_level, negative_level, level_min, level_max) and remaining[0] != 0:
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


def head_of(expr: Expr) -> Expr:
    return expr.head()


def length(expr: Expr) -> int:
    byte_values = _byte_array_values(expr)
    if byte_values is not None:
        return len(byte_values)
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
            return _evaluated_list_expr(
                *[part(expr, *_position_components_from_expr(item)) for item in positions.arguments]
            )
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
    return _evaluated_list_expr(*extracted)


def level(expr: Expr, spec: Expr | int | tuple[int, int] = 1) -> list[Expr]:
    records: list[_LevelRecord] = []
    _collect_levels(expr, 0, records)
    level_min, level_max = _normalize_level_spec(spec)
    return [record.expr for record in records if _level_matches(record, level_min, level_max)]


_HELD_ARGUMENT_HEADS = {
    "Function",
    "Hold",
    "HoldComplete",
    "HoldForm",
    "HoldPattern",
    "Unevaluated",
}


_SEQUENCE_SUPPRESSING_HEADS = {
    "HoldComplete",
    "Rule",
    "RuleDelayed",
    "Unevaluated",
}


_RELEASE_HOLD_HEADS = {
    "Hold",
    "HoldComplete",
    "HoldForm",
    "Unevaluated",
}


def _splice_sequence_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    spliced: list[Expr] = []
    for argument in arguments:
        if isinstance(argument, Call) and argument.has_head("Sequence"):
            spliced.extend(argument.arguments)
        else:
            spliced.append(argument)
    return tuple(spliced)


def _is_nothing_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Nothing"


def _drop_nothing_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    return tuple(argument for argument in arguments if not _is_nothing_expr(argument))


def _normalize_arguments_for_head(
    head_name: str,
    arguments: Sequence[Expr],
    *,
    evaluated: bool,
) -> tuple[Expr, ...]:
    normalized = tuple(arguments)
    if head_name not in _SEQUENCE_SUPPRESSING_HEADS:
        normalized = _splice_sequence_arguments(normalized)
    if evaluated and head_name in {"Association", "List"}:
        normalized = _drop_nothing_arguments(normalized)
    return normalized


def release_hold(expr: Expr) -> Expr:
    if (
        isinstance(expr, Call)
        and isinstance(expr.head_expr, Symbol)
        and expr.head_expr.name in _RELEASE_HOLD_HEADS
    ):
        if len(expr.arguments) == 1:
            return evaluate(expr.arguments[0])
        return evaluate(call("Sequence", *expr.arguments))
    return expr


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


def select(expr: Expr, criterion: Expr, limit: Expr | int | None = None) -> Expr:
    selector, property_spec = _selection_spec(criterion, "Select")
    remaining = _normalize_match_limit(limit)
    selected: list[_SelectionItem] = []

    for item in _selection_items(expr, "Select"):
        if not _predicate_succeeds(selector, item.value):
            continue
        if remaining == 0:
            break
        selected.append(item)
        if remaining is not None:
            remaining -= 1

    return _selection_projection(expr, selected, "Select", property_spec)


def discard(expr: Expr, criterion: Expr, limit: Expr | int | None = None) -> Expr:
    selector, property_spec = _selection_spec(criterion, "Discard")
    remaining = _normalize_match_limit(limit)
    retained: list[_SelectionItem] = []

    for item in _selection_items(expr, "Discard"):
        if remaining != 0 and _predicate_succeeds(selector, item.value):
            if remaining is not None:
                remaining -= 1
            continue
        retained.append(item)

    return _selection_projection(expr, retained, "Discard", property_spec)


def select_first(expr: Expr, criterion: Expr, default: Expr | object = _MISSING) -> Expr:
    selector, property_spec = _selection_spec(criterion, "SelectFirst")
    for item in _selection_items(expr, "SelectFirst"):
        if _predicate_succeeds(selector, item.value):
            return _select_first_projection(item, property_spec, default)
    return _select_first_projection(None, property_spec, default)


def take_while(expr: Expr, criterion: Expr) -> Expr:
    retained: list[_SelectionItem] = []
    for item in _selection_items(expr, "TakeWhile"):
        if not _predicate_succeeds(criterion, item.value):
            break
        retained.append(item)
    return _selection_elements(expr, retained, "TakeWhile")


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


def _is_function_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Function")


def _is_positional_pure_function_expr(expr: Expr) -> bool:
    return _is_function_expr(expr) and len(expr.arguments) == 1


def _named_function_parameter_symbols(expr: Expr) -> tuple[Symbol, ...] | None:
    if not _is_function_expr(expr):
        return None

    assert isinstance(expr, Call)
    if len(expr.arguments) not in {2, 3}:
        return None

    parameter_expr = expr.arguments[0]
    if isinstance(parameter_expr, Symbol):
        return (parameter_expr,)

    if isinstance(parameter_expr, Call) and parameter_expr.has_head("List") and all(
        isinstance(argument, Symbol)
        for argument in parameter_expr.arguments
    ):
        return tuple(parameter_expr.arguments)

    return None


def _is_named_pure_function_expr(expr: Expr) -> bool:
    return _named_function_parameter_symbols(expr) is not None


def _is_pure_function_expr(expr: Expr) -> bool:
    return _is_positional_pure_function_expr(expr) or _is_named_pure_function_expr(expr)


def _named_function_body(expr: Call) -> Expr:
    return expr.arguments[1]


def _rebuild_named_parameter_expr(original: Expr, parameters: Sequence[Symbol]) -> Expr:
    if isinstance(original, Symbol):
        if len(parameters) != 1:
            raise WolframEvaluationError("Function with a single-symbol parameter specification expects exactly one parameter.")
        return parameters[0]
    if isinstance(original, Call) and original.has_head("List"):
        return list_expr(*parameters)
    raise WolframEvaluationError("Unsupported named Function parameter specification.")


def _rebuild_named_function(function: Call, parameters: Sequence[Symbol], body: Expr) -> Call:
    rebuilt_arguments: list[Expr] = [
        _rebuild_named_parameter_expr(function.arguments[0], parameters),
        body,
    ]
    if len(function.arguments) == 3:
        rebuilt_arguments.append(function.arguments[2])
    return Call(head_expr=function.head_expr, arguments=tuple(rebuilt_arguments))


def _collect_symbol_names(expr: Expr, target: set[str]) -> None:
    if isinstance(expr, Symbol):
        target.add(expr.name)
        return

    if isinstance(expr, Call):
        _collect_symbol_names(expr.head_expr, target)
        for argument in expr.arguments:
            _collect_symbol_names(argument, target)


def _fresh_symbol_name(base_name: str, unavailable_names: set[str]) -> str:
    candidate = f"{base_name}$"
    if candidate not in unavailable_names:
        unavailable_names.add(candidate)
        return candidate

    index = 1
    while True:
        candidate = f"{base_name}${index}"
        if candidate not in unavailable_names:
            unavailable_names.add(candidate)
            return candidate
        index += 1


def _fresh_parameter_symbols(
    parameters: Sequence[Symbol],
    unavailable_names: set[str],
) -> tuple[tuple[Symbol, ...], dict[str, Symbol]]:
    fresh_parameters: list[Symbol] = []
    rename_map: dict[str, Symbol] = {}
    for parameter in parameters:
        fresh_symbol = symbol(_fresh_symbol_name(parameter.name, unavailable_names))
        fresh_parameters.append(fresh_symbol)
        rename_map[parameter.name] = fresh_symbol
    return tuple(fresh_parameters), rename_map


def _rename_bound_symbols_in_expr(expr: Expr, rename_map: dict[str, Symbol]) -> Expr:
    if not rename_map:
        return expr

    if isinstance(expr, Symbol):
        return rename_map.get(expr.name, expr)

    if isinstance(expr, (Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    inner_parameters = _named_function_parameter_symbols(expr)
    if inner_parameters is not None:
        assert isinstance(expr, Call)
        shadowed_names = {parameter.name for parameter in inner_parameters}
        nested_rename_map = {
            name: replacement
            for name, replacement in rename_map.items()
            if name not in shadowed_names
        }
        if not nested_rename_map:
            return expr
        renamed_body = _rename_bound_symbols_in_expr(_named_function_body(expr), nested_rename_map)
        return _rebuild_named_function(expr, inner_parameters, renamed_body)

    renamed_head = _rename_bound_symbols_in_expr(expr.head_expr, rename_map)
    renamed_arguments = tuple(
        _rename_bound_symbols_in_expr(argument, rename_map)
        for argument in expr.arguments
    )
    return Call(head_expr=renamed_head, arguments=renamed_arguments)


def _substitute_named_symbols_in_expr(
    expr: Expr,
    substitutions: dict[str, Expr],
    unavailable_names: set[str],
) -> tuple[Expr, bool]:
    if not substitutions:
        return expr, False

    if isinstance(expr, Symbol):
        replacement = substitutions.get(expr.name)
        if replacement is None:
            return expr, False
        return replacement, True

    if isinstance(expr, (Integer, Real, String)):
        return expr, False

    if not isinstance(expr, Call):
        return expr, False

    inner_parameters = _named_function_parameter_symbols(expr)
    if inner_parameters is not None:
        assert isinstance(expr, Call)
        shadowed_names = {parameter.name for parameter in inner_parameters}
        active_substitutions = {
            name: replacement
            for name, replacement in substitutions.items()
            if name not in shadowed_names
        }
        if not active_substitutions:
            return expr, False

        _preview_body, body_changed = _substitute_named_symbols_in_expr(
            _named_function_body(expr),
            active_substitutions,
            unavailable_names | shadowed_names,
        )
        if not body_changed:
            return expr, False

        rename_unavailable = set(unavailable_names)
        _collect_symbol_names(expr.arguments[0], rename_unavailable)
        _collect_symbol_names(_named_function_body(expr), rename_unavailable)
        for replacement in active_substitutions.values():
            _collect_symbol_names(replacement, rename_unavailable)

        fresh_parameters, rename_map = _fresh_parameter_symbols(inner_parameters, rename_unavailable)
        renamed_body = _rename_bound_symbols_in_expr(_named_function_body(expr), rename_map)
        substituted_body, _ = _substitute_named_symbols_in_expr(
            renamed_body,
            active_substitutions,
            unavailable_names | {parameter.name for parameter in fresh_parameters},
        )
        return _rebuild_named_function(expr, fresh_parameters, substituted_body), True

    substituted_head, head_changed = _substitute_named_symbols_in_expr(expr.head_expr, substitutions, unavailable_names)
    changed = head_changed
    substituted_arguments: list[Expr] = []
    for argument in expr.arguments:
        substituted_argument, argument_changed = _substitute_named_symbols_in_expr(argument, substitutions, unavailable_names)
        substituted_arguments.append(substituted_argument)
        changed = changed or argument_changed

    if not changed:
        return expr, False
    return Call(head_expr=substituted_head, arguments=tuple(substituted_arguments)), True


def _slot_index(expr: Expr) -> int | None:
    if not isinstance(expr, Call) or not expr.has_head("Slot"):
        return None
    if len(expr.arguments) == 0:
        return 1
    if len(expr.arguments) != 1 or not isinstance(expr.arguments[0], Integer):
        raise WolframEvaluationError("Slot expects zero arguments or a single integer index.")
    return expr.arguments[0].value


def _replace_slots_in_expr(expr: Expr, arguments: Sequence[Expr], self_function: Expr) -> Expr:
    slot_index = _slot_index(expr)
    if slot_index is not None:
        if slot_index == 0:
            return self_function
        if slot_index < 0:
            raise WolframEvaluationError("Slot indices must be non-negative integers.")
        if slot_index > len(arguments):
            raise WolframEvaluationError(
                f"Slot {slot_index} cannot be filled from {len(arguments)} argument(s)."
            )
        return arguments[slot_index - 1]

    if isinstance(expr, (Symbol, Integer, Real, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    # Slots inside nested pure functions belong to the inner function and should remain untouched.
    if _is_positional_pure_function_expr(expr):
        return expr

    replaced_head = _replace_slots_in_expr(expr.head_expr, arguments, self_function)
    replaced_arguments = tuple(
        _replace_slots_in_expr(argument, arguments, self_function)
        for argument in expr.arguments
    )
    return Call(head_expr=replaced_head, arguments=replaced_arguments)


def _apply_pure_function(function: Expr, arguments: Sequence[Expr]) -> Expr:
    if not _is_positional_pure_function_expr(function):
        raise WolframEvaluationError("Expected a positional pure Function expression.")
    assert isinstance(function, Call)
    substituted = _replace_slots_in_expr(function.arguments[0], arguments, function)
    return evaluate(substituted)


def _apply_named_pure_function(function: Expr, arguments: Sequence[Expr]) -> Expr:
    parameter_symbols = _named_function_parameter_symbols(function)
    if parameter_symbols is None:
        raise WolframEvaluationError("Expected a named-parameter Function expression.")

    if len(arguments) < len(parameter_symbols):
        raise WolframEvaluationError(
            f"Function expects {len(parameter_symbols)} named argument(s), but only {len(arguments)} were supplied."
        )

    assert isinstance(function, Call)
    substitutions = {
        parameter.name: arguments[index]
        for index, parameter in enumerate(parameter_symbols)
    }
    unavailable_names = {parameter.name for parameter in parameter_symbols}
    for argument in arguments[:len(parameter_symbols)]:
        _collect_symbol_names(argument, unavailable_names)
    substituted, _ = _substitute_named_symbols_in_expr(
        _named_function_body(function),
        substitutions,
        unavailable_names,
    )
    return evaluate(substituted)


def _apply_callable(function: Expr, arguments: Sequence[Expr]) -> Expr:
    if _is_positional_pure_function_expr(function):
        return _apply_pure_function(function, arguments)
    if _is_named_pure_function_expr(function):
        return _apply_named_pure_function(function, arguments)
    if isinstance(function, Call) and function.has_head("SameAs") and len(function.arguments) == 1:
        return same_q(*arguments, function.arguments[0])
    if isinstance(function, Call) and function.has_head("Composition"):
        return composition_apply(function.arguments, arguments)
    if isinstance(function, Call) and function.has_head("RightComposition"):
        return right_composition_apply(function.arguments, arguments)
    if isinstance(function, Call) and function.has_head("Scan"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("Scan[f] expects exactly one argument when used as an operator.")
            return scan(function.arguments[0], arguments[0])
        if len(function.arguments) == 2:
            if len(arguments) != 1:
                raise WolframEvaluationError("Scan[f, levelspec] expects exactly one argument when used as an operator.")
            return scan(function.arguments[0], arguments[0], function.arguments[1])
    if isinstance(function, Call) and function.has_head("MapApply"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapApply[f] expects exactly one argument when used as an operator.")
            return map_apply(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("MapAll"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapAll[f] expects exactly one argument when used as an operator.")
            return map_all(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("MapIndexed"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapIndexed[f] expects exactly one argument when used as an operator.")
            return map_indexed(function.arguments[0], arguments[0])
        if len(function.arguments) == 2:
            if len(arguments) != 1:
                raise WolframEvaluationError(
                    "MapIndexed[f, levelspec] expects exactly one argument when used as an operator."
                )
            return map_indexed(function.arguments[0], arguments[0], function.arguments[1])
    if isinstance(function, Call) and function.has_head("Comap") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("Comap[functions] expects exactly one argument when used as an operator.")
        return comap(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("ComapApply") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "ComapApply[functions] expects exactly one argument when used as an operator."
            )
        return comap_apply(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("StringContainsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "StringContainsQ[patt] expects exactly one argument when used as an operator."
            )
        return string_contains_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringMatchQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringMatchQ[patt] expects exactly one argument when used as an operator.")
        return string_match_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringFreeQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringFreeQ[patt] expects exactly one argument when used as an operator.")
        return string_free_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringStartsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringStartsQ[patt] expects exactly one argument when used as an operator.")
        return string_starts_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringEndsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringEndsQ[patt] expects exactly one argument when used as an operator.")
        return string_ends_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringPosition") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "StringPosition[patt] expects exactly one argument when used as an operator."
            )
        return string_position(arguments[0], function.arguments[0])
    return evaluate(Call(head_expr=function, arguments=tuple(arguments)))


def _is_callable_expr(expr: Expr) -> bool:
    if _is_pure_function_expr(expr):
        return True
    if not isinstance(expr, Call):
        return False
    if expr.has_head("SameAs") and len(expr.arguments) == 1:
        return True
    if expr.has_head("Composition"):
        return True
    if expr.has_head("RightComposition"):
        return True
    if expr.has_head("MapApply") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MapAll") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MapIndexed") and len(expr.arguments) in {1, 2}:
        return True
    if expr.has_head("Scan") and len(expr.arguments) in {1, 2}:
        return True
    if expr.has_head("Comap") and len(expr.arguments) == 1:
        return True
    if expr.has_head("ComapApply") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringContainsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringMatchQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringFreeQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringStartsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringEndsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringPosition") and len(expr.arguments) == 1:
        return True
    return False


def same_q(*arguments: Expr) -> Symbol:
    if len(arguments) <= 1:
        return _bool_symbol(True)
    first_argument = arguments[0]
    return _bool_symbol(all(argument == first_argument for argument in arguments[1:]))


def unsame_q(*arguments: Expr) -> Symbol:
    seen: set[Expr] = set()
    for argument in arguments:
        if argument in seen:
            return _bool_symbol(False)
        seen.add(argument)
    return _bool_symbol(True)


def scan(function: Expr, expr: Expr, spec: Expr | int | tuple[int, int] | None = None) -> Symbol:
    level_spec = integer(1) if spec is None else spec
    for item in level(expr, level_spec):
        _apply_callable(function, (item,))
    return symbol("Null")


def map_apply(function: Expr, expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=apply_head(function, entry.value),
            )
            for entry in entries
        )
    if not isinstance(expr, Call):
        return expr
    return _rebuild(expr, tuple(apply_head(function, argument) for argument in expr.arguments))


def _map_all_recursive(function: Expr, expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        rebuilt = _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_map_all_recursive(function, entry.value),
            )
            for entry in entries
        )
        return _apply_callable(function, (rebuilt,))

    if isinstance(expr, Call):
        rebuilt = _rebuild(
            expr,
            tuple(_map_all_recursive(function, argument) for argument in expr.arguments),
        )
        return _apply_callable(function, (rebuilt,))

    return _apply_callable(function, (expr,))


def map_all(function: Expr, expr: Expr) -> Expr:
    return _map_all_recursive(function, expr)


def map_indexed(function: Expr, expr: Expr, spec: Expr | int | tuple[int, int] | None = None) -> Expr:
    if spec is not None and spec != integer(1) and spec != 1:
        raise WolframEvaluationError("MapIndexed currently supports only the default level specification.")

    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(function, (entry.value, list_expr(integer(index)))),
            )
            for index, entry in enumerate(entries, start=1)
        )

    compound = _require_compound(expr, "MapIndexed")
    return _rebuild(
        compound,
        tuple(
            _apply_callable(function, (argument, list_expr(integer(index))))
            for index, argument in enumerate(compound.arguments, start=1)
        ),
    )


def construct(function: Expr, *arguments: Expr) -> Expr:
    return _apply_callable(function, arguments)


def composition_apply(functions: Sequence[Expr], arguments: Sequence[Expr]) -> Expr:
    if not functions:
        if len(arguments) == 1:
            return arguments[0]
        return _evaluated_list_expr(*arguments)

    current = _apply_callable(functions[-1], arguments)
    for function in reversed(functions[:-1]):
        current = _apply_callable(function, (current,))
    return current


def right_composition_apply(functions: Sequence[Expr], arguments: Sequence[Expr]) -> Expr:
    if not functions:
        if len(arguments) == 1:
            return arguments[0]
        return _evaluated_list_expr(*arguments)

    current = _apply_callable(functions[0], arguments)
    for function in functions[1:]:
        current = _apply_callable(function, (current,))
    return current


def compose_list(functions_expr: Expr, initial: Expr) -> Expr:
    if not isinstance(functions_expr, Call):
        raise WolframEvaluationError("ComposeList expects a list or other nonatomic expression of functions.")

    current = initial
    results = [initial]
    for function in functions_expr.arguments:
        current = _apply_callable(function, (current,))
        results.append(current)
    return _evaluated_list_expr(*results)


def nest(function: Expr, expr: Expr, count: Expr | int) -> Expr:
    iterations = _normalize_integer_argument(count, "Nest")
    if iterations < 0:
        raise WolframEvaluationError("Nest expects a non-negative integer iteration count.")
    current = expr
    for _ in range(iterations):
        current = _apply_callable(function, (current,))
    return current


def nest_list(function: Expr, expr: Expr, count: Expr | int) -> Expr:
    iterations = _normalize_integer_argument(count, "NestList")
    if iterations < 0:
        raise WolframEvaluationError("NestList expects a non-negative integer iteration count.")
    current = expr
    results = [expr]
    for _ in range(iterations):
        current = _apply_callable(function, (current,))
        results.append(current)
    return _evaluated_list_expr(*results)


_ITERATION_SAFETY_LIMIT = 65536


def nest_while(function: Expr, expr: Expr, test: Expr) -> Expr:
    current = expr
    for _ in range(_ITERATION_SAFETY_LIMIT):
        if not _predicate_succeeds(test, current):
            return current
        current = _apply_callable(function, (current,))
    raise WolframEvaluationError("NestWhile exceeded the Tungsten iteration safety limit.")


def nest_while_list(function: Expr, expr: Expr, test: Expr) -> Expr:
    current = expr
    results = [expr]
    for _ in range(_ITERATION_SAFETY_LIMIT):
        if not _predicate_succeeds(test, current):
            return _evaluated_list_expr(*results)
        current = _apply_callable(function, (current,))
        results.append(current)
    raise WolframEvaluationError("NestWhileList exceeded the Tungsten iteration safety limit.")


def fixed_point(function: Expr, expr: Expr, max_iterations: Expr | int | None = None) -> Expr:
    explicit_limit = max_iterations is not None
    limit = _ITERATION_SAFETY_LIMIT if max_iterations is None else _normalize_integer_argument(max_iterations, "FixedPoint")
    if limit < 0:
        raise WolframEvaluationError("FixedPoint expects a non-negative maximum iteration count.")
    current = expr
    for _ in range(limit):
        updated = _apply_callable(function, (current,))
        if updated == current:
            return current
        current = updated
    if explicit_limit:
        return current
    raise WolframEvaluationError("FixedPoint exceeded the Tungsten iteration safety limit.")


def fixed_point_list(function: Expr, expr: Expr, max_iterations: Expr | int | None = None) -> Expr:
    explicit_limit = max_iterations is not None
    limit = _ITERATION_SAFETY_LIMIT if max_iterations is None else _normalize_integer_argument(max_iterations, "FixedPointList")
    if limit < 0:
        raise WolframEvaluationError("FixedPointList expects a non-negative maximum iteration count.")
    current = expr
    results = [expr]
    for _ in range(limit):
        updated = _apply_callable(function, (current,))
        results.append(updated)
        if updated == current:
            return _evaluated_list_expr(*results)
        current = updated
    if explicit_limit:
        return _evaluated_list_expr(*results)
    raise WolframEvaluationError("FixedPointList exceeded the Tungsten iteration safety limit.")


def operate(operator: Expr, expr: Expr, level_value: Expr | int = 1) -> Expr:
    level_number = _normalize_integer_argument(level_value, "Operate")
    if level_number < 1:
        raise WolframEvaluationError("Operate expects a positive integer level.")
    if not isinstance(expr, Call):
        return expr
    if level_number == 1:
        return Call(head_expr=_apply_callable(operator, (expr.head_expr,)), arguments=expr.arguments)
    if not isinstance(expr.head_expr, Call):
        return expr
    return Call(head_expr=operate(operator, expr.head_expr, level_number - 1), arguments=expr.arguments)


def comap(functions_expr: Expr, expr: Expr) -> Expr:
    entries = _association_entries(functions_expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(entry.value, (expr,)),
            )
            for entry in entries
        )
    if not isinstance(functions_expr, Call):
        return functions_expr
    return _rebuild(
        functions_expr,
        tuple(_apply_callable(function, (expr,)) for function in functions_expr.arguments),
    )


def comap_apply(functions_expr: Expr, expr: Expr) -> Expr:
    entries = _association_entries(functions_expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=apply_head(entry.value, expr),
            )
            for entry in entries
        )
    if not isinstance(functions_expr, Call):
        return functions_expr
    return _rebuild(
        functions_expr,
        tuple(apply_head(function, expr) for function in functions_expr.arguments),
    )


def through(expr: Expr) -> Expr:
    if not isinstance(expr, Call):
        return expr
    head_entries = _association_entries(expr.head_expr)
    if head_entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(entry.value, expr.arguments),
            )
            for entry in head_entries
        )
    if not isinstance(expr.head_expr, Call):
        return expr
    return _rebuild(
        expr.head_expr,
        tuple(_apply_callable(function, expr.arguments) for function in expr.head_expr.arguments),
    )


def _sequence_values(expr: Expr, function_name: str) -> tuple[Expr, ...]:
    return tuple(item.value for item in _selection_items(expr, function_name))


def map_thread(function: Expr, sequences_expr: Expr, level_value: Expr | int | None = None) -> Expr:
    if level_value is not None and _normalize_integer_argument(level_value, "MapThread") != 1:
        raise WolframEvaluationError("MapThread currently supports only level 1.")
    if not isinstance(sequences_expr, Call) or not sequences_expr.has_head("List"):
        raise WolframEvaluationError("MapThread expects a list of sequences.")

    sequences = list(sequences_expr.arguments)
    if not sequences:
        return _evaluated_list_expr()

    if not all(isinstance(sequence, Call) and sequence.has_head("List") for sequence in sequences):
        raise WolframEvaluationError("MapThread currently expects a list of List expressions.")

    lengths = {len(sequence.arguments) for sequence in sequences if isinstance(sequence, Call)}
    if len(lengths) != 1:
        raise WolframEvaluationError("MapThread expects sequences of the same length.")

    assert len(lengths) == 1
    length_value = lengths.pop()
    return _evaluated_list_expr(
        *(
            _apply_callable(
                function,
                tuple(sequence.arguments[index] for sequence in sequences if isinstance(sequence, Call)),
            )
            for index in range(length_value)
        )
    )


def thread(expr: Expr, thread_head: Expr | None = None) -> Expr:
    if not isinstance(expr, Call):
        return expr

    effective_head = symbol("List") if thread_head is None else thread_head
    lengths: set[int] = set()
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == effective_head:
            lengths.add(len(argument.arguments))

    if not lengths:
        return expr
    if len(lengths) != 1:
        raise WolframEvaluationError("Thread expects all threaded arguments to have the same length.")

    length_value = lengths.pop()
    results: list[Expr] = []
    for index in range(length_value):
        threaded_arguments: list[Expr] = []
        for argument in expr.arguments:
            if isinstance(argument, Call) and argument.head_expr == effective_head:
                threaded_arguments.append(argument.arguments[index])
            else:
                threaded_arguments.append(argument)
        results.append(Call(head_expr=expr.head_expr, arguments=tuple(threaded_arguments)))

    if isinstance(effective_head, Symbol) and effective_head.name == "List":
        return _evaluated_list_expr(*results)
    return Call(head_expr=effective_head, arguments=tuple(results))


def distribute(expr: Expr, distributed_head: Expr | None = None, outer_head: Expr | None = None) -> Expr:
    if not isinstance(expr, Call):
        return expr

    effective_distributed_head = symbol("Plus") if distributed_head is None else distributed_head
    if outer_head is not None and expr.head_expr != outer_head:
        return expr

    argument_options: list[tuple[Expr, ...]] = []
    found = False
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == effective_distributed_head:
            argument_options.append(argument.arguments)
            found = True
        else:
            argument_options.append((argument,))

    if not found:
        return expr

    distributed_arguments: list[Expr] = []

    def recurse(index: int, chosen: list[Expr]) -> None:
        if index == len(argument_options):
            distributed_arguments.append(Call(head_expr=expr.head_expr, arguments=tuple(chosen)))
            return
        for option in argument_options[index]:
            recurse(index + 1, [*chosen, option])

    recurse(0, [])
    return Call(head_expr=effective_distributed_head, arguments=tuple(distributed_arguments))


def outer(function: Expr, *sequences: Expr) -> Expr:
    if not sequences:
        raise WolframEvaluationError("Outer expects at least one sequence.")
    normalized_sequences: list[Call] = []
    for sequence in sequences:
        compound = _require_compound(sequence, "Outer")
        normalized_sequences.append(compound)

    def recurse(index: int, chosen: list[Expr]) -> Expr:
        if index == len(normalized_sequences):
            return _apply_callable(function, tuple(chosen))
        current = normalized_sequences[index]
        return _rebuild(
            current,
            tuple(recurse(index + 1, [*chosen, item]) for item in current.arguments),
        )

    return recurse(0, [])


def inner(function: Expr, left: Expr, right: Expr, combiner: Expr) -> Expr:
    left_compound = _require_compound(left, "Inner")
    right_compound = _require_compound(right, "Inner")
    if len(left_compound.arguments) != len(right_compound.arguments):
        raise WolframEvaluationError("Inner expects expressions with the same length.")
    combined = [
        _apply_callable(function, (left_item, right_item))
        for left_item, right_item in zip(left_compound.arguments, right_compound.arguments, strict=True)
    ]
    return _apply_callable(combiner, tuple(combined))


def tuples_expr(items: Expr, count: Expr | int | None = None) -> Expr:
    if count is None:
        if not isinstance(items, Call) or not items.has_head("List"):
            raise WolframEvaluationError("Tuples expects a list of sequences or a sequence with a repetition count.")
        sequences = [_sequence_values(item, "Tuples") for item in items.arguments]
    else:
        repetitions = _normalize_integer_argument(count, "Tuples")
        if repetitions < 0:
            raise WolframEvaluationError("Tuples expects a non-negative repetition count.")
        base_items = _sequence_values(items, "Tuples")
        sequences = [base_items] * repetitions

    results: list[Expr] = [_evaluated_list_expr()]
    for sequence in sequences:
        next_results: list[Expr] = []
        for prefix in results:
            assert isinstance(prefix, Call) and prefix.has_head("List")
            for item in sequence:
                next_results.append(_evaluated_list_expr(*prefix.arguments, item))
        results = next_results
    return _evaluated_list_expr(*results)


def _normalize_dimensions(dimensions: Expr | int, function_name: str) -> list[int]:
    if isinstance(dimensions, int):
        if dimensions < 0:
            raise WolframEvaluationError(f"{function_name} expects non-negative dimensions.")
        return [dimensions]
    if isinstance(dimensions, Integer):
        return _normalize_dimensions(dimensions.value, function_name)
    if isinstance(dimensions, Call) and dimensions.has_head("List"):
        values = [_normalize_integer_argument(item, function_name) for item in dimensions.arguments]
        if any(value < 0 for value in values):
            raise WolframEvaluationError(f"{function_name} expects non-negative dimensions.")
        return values
    raise WolframEvaluationError(f"{function_name} expects an integer dimension or a list of dimensions.")


def _build_array_from_dimensions(
    dimensions: Sequence[int],
    builder,
    indices: tuple[int, ...] = (),
) -> Expr:
    if not dimensions:
        return builder(indices)
    size = dimensions[0]
    return _evaluated_list_expr(*(
        _build_array_from_dimensions(dimensions[1:], builder, (*indices, index))
        for index in range(1, size + 1)
    ))


def array(function: Expr, dimensions: Expr | int) -> Expr:
    normalized_dimensions = _normalize_dimensions(dimensions, "Array")
    return _build_array_from_dimensions(
        normalized_dimensions,
        lambda indices: _apply_callable(function, tuple(integer(index) for index in indices)),
    )


def constant_array(value: Expr, dimensions: Expr | int) -> Expr:
    normalized_dimensions = _normalize_dimensions(dimensions, "ConstantArray")
    return _build_array_from_dimensions(normalized_dimensions, lambda _indices: value)


def range_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Range expects one, two, or three integer arguments.")
    values = _integer_values(arguments)
    if values is None:
        raise WolframEvaluationError("Range currently supports only explicit integer arguments.")
    if len(values) == 1:
        start, end, step = 1, values[0], 1
    elif len(values) == 2:
        start, end = values
        step = 1
    else:
        start, end, step = values
    if step == 0:
        raise WolframEvaluationError("Range step cannot be zero.")
    if (step > 0 and start > end) or (step < 0 and start < end):
        return _evaluated_list_expr()
    stop = end + (1 if step > 0 else -1)
    return _evaluated_list_expr(*(integer(item) for item in range(start, stop, step)))


def unit_vector(arguments: Sequence[Expr]) -> Expr:
    values = _integer_values(arguments)
    if values is None or len(values) != 2:
        raise WolframEvaluationError("UnitVector currently supports exactly two explicit integer arguments.")
    length_value, position = values
    if length_value < 0:
        raise WolframEvaluationError("UnitVector expects a non-negative length.")
    if position < 1 or position > length_value:
        raise WolframEvaluationError("UnitVector position must be between 1 and the vector length.")
    return _evaluated_list_expr(*(
        integer(1 if index == position else 0)
        for index in range(1, length_value + 1)
    ))


def identity_matrix(size: Expr | int) -> Expr:
    dimension = _normalize_integer_argument(size, "IdentityMatrix")
    if dimension < 0:
        raise WolframEvaluationError("IdentityMatrix expects a non-negative integer size.")
    return _evaluated_list_expr(*(
        _evaluated_list_expr(*(integer(1 if row == column else 0) for column in range(1, dimension + 1)))
        for row in range(1, dimension + 1)
    ))


def diagonal_matrix(values_expr: Expr) -> Expr:
    values = _sequence_values(values_expr, "DiagonalMatrix")
    return _evaluated_list_expr(
        *(
            _evaluated_list_expr(
                *(values[row - 1] if row == column else integer(0) for column in range(1, len(values) + 1))
            )
            for row in range(1, len(values) + 1)
        )
    )


def partition(expr: Expr, size: Expr | int, offset: Expr | int | None = None) -> Expr:
    window = _normalize_integer_argument(size, "Partition")
    step = window if offset is None else _normalize_integer_argument(offset, "Partition")
    if window <= 0 or step <= 0:
        raise WolframEvaluationError("Partition expects positive integer block sizes and offsets.")
    items = _selection_items(expr, "Partition")
    results: list[Expr] = []
    for start in range(0, len(items) - window + 1, step):
        chunk = items[start:start + window]
        results.append(_selection_elements(expr, chunk, "Partition"))
    return _evaluated_list_expr(*results)


def block_map(function: Expr, expr: Expr, size: Expr | int, offset: Expr | int | None = None) -> Expr:
    window = _normalize_integer_argument(size, "BlockMap")
    step = window if offset is None else _normalize_integer_argument(offset, "BlockMap")
    if window <= 0 or step <= 0:
        raise WolframEvaluationError("BlockMap expects positive integer block sizes and offsets.")
    items = _selection_items(expr, "BlockMap")
    results: list[Expr] = []
    for start in range(0, len(items) - window + 1, step):
        block_expr = _selection_elements(expr, items[start:start + window], "BlockMap")
        results.append(_apply_callable(function, (block_expr,)))
    return _evaluated_list_expr(*results)


def take_list(expr: Expr, specs_expr: Expr) -> Expr:
    if not isinstance(specs_expr, Call) or not specs_expr.has_head("List"):
        raise WolframEvaluationError("TakeList expects a list of specifications.")
    remaining = expr
    taken: list[Expr] = []
    for spec in specs_expr.arguments:
        if isinstance(spec, Symbol) and spec.name == "All":
            taken.append(remaining)
            entries = _association_entries(remaining)
            if entries is not None:
                remaining = _association_expr([])
            elif isinstance(remaining, Call):
                remaining = _rebuild(remaining, ())
            else:
                remaining = remaining
            continue
        taken.append(take(remaining, spec))
        remaining = drop(remaining, spec)
    return _evaluated_list_expr(*taken)


def take_drop(expr: Expr, spec: Expr) -> Expr:
    return _evaluated_list_expr(take(expr, spec), drop(expr, spec))


def fold(function: Expr, initial: Expr, expr: Expr) -> Expr:
    current = initial
    for item in _selection_items(expr, "Fold"):
        current = _apply_callable(function, (current, item.value))
    return current


def fold_list(function: Expr, initial: Expr, expr: Expr) -> Expr:
    current = initial
    results = [initial]
    for item in _selection_items(expr, "FoldList"):
        current = _apply_callable(function, (current, item.value))
        results.append(current)
    return _evaluated_list_expr(*results)


def sequence_fold(function: Expr, initial_expr: Expr, expr: Expr, arity: Expr | int | None = None) -> Expr:
    history_expr = sequence_fold_list(function, initial_expr, expr, arity)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    return history_expr.arguments[-1]


def sequence_fold_list(function: Expr, initial_expr: Expr, expr: Expr, arity: Expr | int | None = None) -> Expr:
    initial_values = _sequence_values(initial_expr, "SequenceFoldList")
    inputs = list(_sequence_values(expr, "SequenceFoldList"))
    if not initial_values:
        raise WolframEvaluationError("SequenceFoldList expects at least one initial value.")

    state_values = list(initial_values)
    results = list(initial_values)
    argument_count = len(initial_values) + 1 if arity is None else _normalize_integer_argument(arity, "SequenceFoldList")
    if argument_count < len(initial_values):
        raise WolframEvaluationError("SequenceFoldList expects an argument count greater than or equal to the number of initial values.")
    consumed_per_step = argument_count - len(initial_values)
    if consumed_per_step <= 0:
        raise WolframEvaluationError("SequenceFoldList currently expects each step to consume at least one input element.")

    index = 0
    while index + consumed_per_step <= len(inputs):
        step_arguments = tuple(state_values[-len(initial_values):]) + tuple(inputs[index:index + consumed_per_step])
        current = _apply_callable(function, step_arguments)
        results.append(current)
        state_values.append(current)
        index += consumed_per_step
    return _evaluated_list_expr(*results)


def _fold_while_history_arguments(results: Sequence[Expr], history_spec: Expr | int | None) -> tuple[Expr, ...]:
    if history_spec is None:
        return (results[-1],)
    if isinstance(history_spec, Symbol) and history_spec.name == "All":
        return tuple(results)
    history_length = _normalize_integer_argument(history_spec, "FoldWhileList")
    if history_length <= 0:
        raise WolframEvaluationError("FoldWhileList expects a positive history length or All.")
    return tuple(results[-min(history_length, len(results)):])


def fold_while_list(
    function: Expr,
    initial: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_results: Expr | int | None = None,
) -> Expr:
    inputs = [item.value for item in _selection_items(expr, "FoldWhileList")]
    results: list[Expr] = [initial]

    if not _predicate_succeeds_with_arguments(test, _fold_while_history_arguments(results, history_spec)):
        return _evaluated_list_expr(*results)

    failure_detected = False
    index = 0
    while index < len(inputs):
        updated = _apply_callable(function, (results[-1], inputs[index]))
        results.append(updated)
        index += 1
        if not _predicate_succeeds_with_arguments(test, _fold_while_history_arguments(results, history_spec)):
            failure_detected = True
            break

    if not failure_detected:
        return _evaluated_list_expr(*results)

    trailing = 0 if extra_results is None else _normalize_integer_argument(extra_results, "FoldWhileList")
    if trailing < 0:
        keep_count = max(1, len(results) + trailing)
        return _evaluated_list_expr(*results[:keep_count])

    while trailing > 0 and index < len(inputs):
        results.append(_apply_callable(function, (results[-1], inputs[index])))
        index += 1
        trailing -= 1
    return _evaluated_list_expr(*results)


def fold_while(
    function: Expr,
    initial: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_results: Expr | int | None = None,
) -> Expr:
    history_expr = fold_while_list(function, initial, expr, test, history_spec, extra_results)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    return history_expr.arguments[-1]


def _fold_pair_project(pair_values: tuple[Expr, Expr], projection: Expr | None) -> Expr:
    if projection is None:
        return pair_values[0]
    return _apply_callable(projection, (list_expr(*pair_values),))


def fold_pair_list(function: Expr, initial: Expr, expr: Expr, projection: Expr | None = None) -> Expr:
    inputs = [item.value for item in _selection_items(expr, "FoldPairList")]
    current = initial
    results: list[Expr] = []
    for input_value in inputs:
        pair_expr = _apply_callable(function, (current, input_value))
        if not isinstance(pair_expr, Call) or not pair_expr.has_head("List") or len(pair_expr.arguments) != 2:
            raise WolframEvaluationError(
                f"FoldPairList expects each function application to return a list of two elements, got {pair_expr.to_input_form()}."
            )
        pair_values = (pair_expr.arguments[0], pair_expr.arguments[1])
        results.append(_fold_pair_project(pair_values, projection))
        current = pair_values[1]
    return _evaluated_list_expr(*results)


def fold_pair(function: Expr, initial: Expr, expr: Expr, projection: Expr | None = None) -> Expr:
    history_expr = fold_pair_list(function, initial, expr, projection)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    if not history_expr.arguments:
        return call("FoldPair", function, initial, expr) if projection is None else call("FoldPair", function, initial, expr, projection)
    return history_expr.arguments[-1]


def length_while(expr: Expr, criterion: Expr) -> Integer:
    count = 0
    for item in _selection_items(expr, "LengthWhile"):
        if not _predicate_succeeds(criterion, item.value):
            break
        count += 1
    return integer(count)


def first_case(
    expr: Expr,
    pattern_spec: Expr,
    default: Expr | object = _MISSING,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Expr:
    results = cases(expr, pattern_spec, spec=spec, limit=1)
    if results.arguments:
        return results.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    return _missing_not_found()


def position(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
) -> Expr:
    level_spec: Expr | int | tuple[int, int] = (0, _LEVEL_INFINITY) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)
    remaining = _normalize_match_limit(limit)
    results: list[Expr] = []

    def recurse(current: Expr, positive_level: int, path: list[int]) -> None:
        nonlocal remaining
        if remaining == 0:
            return
        if _is_association(current):
            negative_level = -depth(current)
            if (
                _level_bounds_match(positive_level, negative_level, level_min, level_max)
                and _match_pattern(current, pattern) is not None
            ):
                results.append(list_expr(*(integer(index) for index in path)))
                if remaining is not None:
                    remaining -= 1
            return

        if isinstance(current, Call):
            for index, argument in enumerate(current.arguments, start=1):
                recurse(argument, positive_level + 1, [*path, index])
                if remaining == 0:
                    return

        negative_level = -depth(current)
        if (
            _level_bounds_match(positive_level, negative_level, level_min, level_max)
            and _match_pattern(current, pattern) is not None
        ):
            results.append(list_expr(*(integer(index) for index in path)))
            if remaining is not None:
                remaining -= 1

    recurse(expr, 0, [])
    return list_expr(*results)


def member_q(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Symbol:
    positions = position(expr, pattern, spec=spec, limit=1)
    assert isinstance(positions, Call) and positions.has_head("List")
    return _bool_symbol(bool(positions.arguments))


def _duplicate_test_succeeds(test: Expr | None, left: Expr, right: Expr) -> bool:
    if test is None:
        return left == right
    evaluated = evaluate(_apply_callable(test, (left, right)))
    return isinstance(evaluated, Symbol) and evaluated.name == "True"


def delete_duplicates(expr: Expr, test: Expr | None = None) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        kept: list[_AssociationEntry] = []
        seen_values: list[Expr] = []
        for entry in entries:
            if any(_duplicate_test_succeeds(test, entry.value, prior) for prior in seen_values):
                continue
            kept.append(entry)
            seen_values.append(entry.value)
        return _association_expr(kept)

    compound = _require_compound(expr, "DeleteDuplicates")
    kept_arguments: list[Expr] = []
    for argument in compound.arguments:
        if any(_duplicate_test_succeeds(test, argument, prior) for prior in kept_arguments):
            continue
        kept_arguments.append(argument)
    return _rebuild(compound, kept_arguments)


def delete_duplicates_by(expr: Expr, function: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        kept: list[_AssociationEntry] = []
        seen_keys: list[Expr] = []
        for entry in entries:
            key = _apply_callable(function, (entry.value,))
            if any(key == prior for prior in seen_keys):
                continue
            kept.append(entry)
            seen_keys.append(key)
        return _association_expr(kept)

    compound = _require_compound(expr, "DeleteDuplicatesBy")
    kept_arguments: list[Expr] = []
    seen_keys: list[Expr] = []
    for argument in compound.arguments:
        key = _apply_callable(function, (argument,))
        if any(key == prior for prior in seen_keys):
            continue
        kept_arguments.append(argument)
        seen_keys.append(key)
    return _rebuild(compound, kept_arguments)


def duplicate_free_q(expr: Expr, test: Expr | None = None) -> Symbol:
    entries = _association_entries(expr)
    values = [entry.value for entry in entries] if entries is not None else list(_require_compound(expr, "DuplicateFreeQ").arguments)
    for index, left in enumerate(values):
        for right in values[index + 1:]:
            if _duplicate_test_succeeds(test, left, right):
                return _bool_symbol(False)
    return _bool_symbol(True)


def _list_rows(expr: Expr, function_name: str) -> list[tuple[Expr, ...]] | None:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None
    rows: list[tuple[Expr, ...]] = []
    for argument in expr.arguments:
        if not isinstance(argument, Call) or not argument.has_head("List"):
            return None
        rows.append(argument.arguments)
    return rows


def dot(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) < 2:
        raise WolframEvaluationError("Dot expects at least two arguments.")

    def dot_two(left: Expr, right: Expr) -> Expr:
        left_rows = _list_rows(left, "Dot")
        right_rows = _list_rows(right, "Dot")

        if isinstance(left, Call) and left.has_head("List") and isinstance(right, Call) and right.has_head("List") and left_rows is None and right_rows is None:
            if len(left.arguments) != len(right.arguments):
                raise WolframEvaluationError("Dot expects vectors of the same length.")
            return call("Plus", *(
                call("Times", left_item, right_item)
                for left_item, right_item in zip(left.arguments, right.arguments, strict=True)
            ))

        if left_rows is not None and right_rows is None and isinstance(right, Call) and right.has_head("List"):
            return list_expr(*(dot_two(list_expr(*row), right) for row in left_rows))

        if left_rows is None and isinstance(left, Call) and left.has_head("List") and right_rows is not None:
            width = len(right_rows[0]) if right_rows else 0
            if any(len(row) != width for row in right_rows):
                raise WolframEvaluationError("Dot currently expects rectangular matrices.")
            columns = [
                list_expr(*(row[column_index] for row in right_rows))
                for column_index in range(width)
            ]
            return list_expr(*(dot_two(left, column) for column in columns))

        if left_rows is not None and right_rows is not None:
            width = len(left_rows[0]) if left_rows else 0
            if any(len(row) != width for row in left_rows):
                raise WolframEvaluationError("Dot currently expects rectangular matrices.")
            if any(len(row) != width for row in right_rows):
                raise WolframEvaluationError("Dot currently expects compatible matrix dimensions.")
            return list_expr(*(dot_two(list_expr(*row), right) for row in left_rows))

        raise WolframEvaluationError("Dot currently supports List vectors and List matrices only.")

    current = arguments[0]
    for argument in arguments[1:]:
        current = evaluate(dot_two(current, argument))
    return current


def apply_head(new_head: Expr, expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        return _apply_callable(new_head, tuple(entry.value for entry in entries))
    if not isinstance(expr, Call):
        return expr
    return _apply_callable(new_head, expr.arguments)


def map_expr(function: Expr, expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(function, (entry.value,)),
            )
            for entry in entries
        )
    if not isinstance(expr, Call):
        return expr
    return _rebuild(expr, tuple(_apply_callable(function, (argument,)) for argument in expr.arguments))


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
    return _evaluated_list_expr(*(entry.key for entry in entries))


def values_expr(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Values")
    return _evaluated_list_expr(*(entry.value for entry in entries))


def normal(expr: Expr) -> Expr:
    byte_values = _byte_array_values(expr)
    if byte_values is not None:
        return list_expr(*(integer(value) for value in byte_values))
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
        return _evaluated_list_expr(*(lookup_one(item) for item in key_spec.arguments))
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
            key=_apply_callable(function, (entry.key,)),
            value=entry.value,
        )
        for entry in entries
    )


def key_value_map(function: Expr, expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyValueMap")
    return _evaluated_list_expr(*(_apply_callable(function, (entry.key, entry.value)) for entry in entries))


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
        _AssociationEntry("Rule", key, _apply_callable(function, (key,)))
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
    if isinstance(expr.head_expr, Symbol):
        arguments = _normalize_arguments_for_head(expr.head_expr.name, arguments, evaluated=True)
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
        return (_apply_callable(function, (expr,)), True)

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
                _apply_callable(function, (entry.value,)),
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

        if raw_head_name in _HELD_ARGUMENT_HEADS:
            held_arguments = _normalize_arguments_for_head(raw_head_name, expr.arguments, evaluated=False)

            if raw_head_name == "Function" and len(held_arguments) not in {1, 2, 3}:
                raise WolframEvaluationError("Function expects one, two, or three arguments.")

            return Call(head_expr=expr.head_expr, arguments=held_arguments)

        if raw_head_name == "ReleaseHold":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("ReleaseHold expects exactly one argument.")
            return release_hold(evaluate(expr.arguments[0]))

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

        if raw_head_name == "Replace":
            if len(expr.arguments) == 2:
                return replace(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return replace(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError(
                "Replace expects an expression, replacement rules, and an optional level specification."
            )

        if raw_head_name == "ReplaceAll":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("ReplaceAll expects exactly two arguments.")
            return replace_all(evaluate(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "ReplaceRepeated":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("ReplaceRepeated expects exactly two arguments.")
            return replace_repeated(evaluate(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "ReplaceAt":
            if len(expr.arguments) != 3:
                raise WolframEvaluationError("ReplaceAt expects exactly three arguments.")
            return replace_at(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))

        if raw_head_name == "StringCases":
            if len(expr.arguments) == 2:
                return string_cases(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return string_cases(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("StringCases expects a string, a pattern or rule, and an optional match limit.")

        if raw_head_name == "StringReplace":
            if len(expr.arguments) == 2:
                return string_replace(evaluate(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return string_replace(evaluate(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("StringReplace expects a string, rules, and an optional replacement limit.")

        if raw_head_name == "Select":
            if len(expr.arguments) == 1:
                return call("Function", call("Select", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "Discard":
            if len(expr.arguments) == 1:
                return call("Function", call("Discard", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "SelectFirst":
            if len(expr.arguments) == 1:
                return call("Function", call("SelectFirst", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "If":
            return if_expr(expr.arguments)

        if raw_head_name == "Which":
            return which_expr(expr.arguments)

        if raw_head_name == "Switch":
            return switch_expr(expr.arguments)

        if raw_head_name == "Piecewise":
            return piecewise_expr(expr.arguments)

        if raw_head_name == "Pick":
            if len(expr.arguments) == 2:
                return pick(evaluate(expr.arguments[0]), evaluate(expr.arguments[1]))
            if len(expr.arguments) == 3:
                return pick(evaluate(expr.arguments[0]), evaluate(expr.arguments[1]), expr.arguments[2])
            raise WolframEvaluationError("Pick expects a data expression, a selector expression, and an optional pattern.")

    evaluated_head = evaluate(expr.head_expr)
    if isinstance(evaluated_head, Symbol) and evaluated_head.name == "Nothing":
        tuple(evaluate(argument) for argument in expr.arguments)
        return symbol("Nothing")

    if _is_callable_expr(evaluated_head):
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        return _apply_callable(evaluated_head, evaluated_arguments)
    if _is_function_expr(evaluated_head):
        raise WolframEvaluationError("Unsupported Function parameter specification.")

    association_head_entries = _association_entries(evaluated_head)
    if association_head_entries is not None:
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        if len(evaluated_arguments) == 1:
            return lookup(evaluated_head, evaluated_arguments[0])
        return Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    if not isinstance(evaluated_head, Symbol):
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        return Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    evaluated_arguments = tuple(evaluate(argument) for argument in expr.arguments)
    evaluated_arguments = _normalize_arguments_for_head(evaluated_head.name, evaluated_arguments, evaluated=True)
    evaluated_expr = Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    arithmetic_result = _evaluate_integer_arithmetic(evaluated_expr)
    if arithmetic_result is not None:
        return arithmetic_result

    relation_result = _evaluate_integer_relation(evaluated_expr)
    if relation_result is not None:
        return relation_result

    boolean_result = _evaluate_boolean_logic(evaluated_expr)
    if boolean_result is not None:
        return boolean_result

    predicate_result = _evaluate_simple_predicates(evaluated_expr)
    if predicate_result is not None:
        return predicate_result

    integer_special_result = _evaluate_integer_special_functions(evaluated_expr)
    if integer_special_result is not None:
        return integer_special_result

    if evaluated_head.name == "ByteArray":
        return byte_array(evaluated_arguments)

    if evaluated_head.name == "Identity":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Identity expects exactly one argument.")
        return evaluated_arguments[0]

    if evaluated_head.name == "ToString":
        if len(evaluated_arguments) == 1:
            return to_string_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_string_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ToString expects an expression and an optional InputForm or StandardForm specifier.")

    if evaluated_head.name == "ToExpression":
        if len(evaluated_arguments) == 1:
            return to_expression_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_expression_expr(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return to_expression_expr(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "ToExpression expects input, an optional InputForm or StandardForm specifier, and an optional wrapper head."
        )

    if evaluated_head.name == "SameQ":
        return same_q(*evaluated_arguments)

    if evaluated_head.name == "UnsameQ":
        return unsame_q(*evaluated_arguments)

    if evaluated_head.name == "Characters":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Characters expects exactly one argument.")
        return characters(evaluated_arguments[0])

    if evaluated_head.name == "StringLength":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StringLength expects exactly one argument.")
        return string_length(evaluated_arguments[0])

    if evaluated_head.name == "StringTake":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("StringTake expects exactly two arguments.")
        return string_take(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "StringDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("StringDrop expects exactly two arguments.")
        return string_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "StringJoin":
        return string_join(*evaluated_arguments)

    if evaluated_head.name == "StringInsert":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("StringInsert expects a source string, an insertion string, and positions.")
        return string_insert(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "StringReverse":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StringReverse expects exactly one argument.")
        return string_reverse(evaluated_arguments[0])

    if evaluated_head.name == "StringPosition":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_position(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_position(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringPosition expects a string, a pattern, and an optional match limit.")

    if evaluated_head.name == "StringContainsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_contains_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringContainsQ expects a string and a pattern.")

    if evaluated_head.name == "StringMatchQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_match_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringMatchQ expects a string and a pattern.")

    if evaluated_head.name == "StringFreeQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_free_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringFreeQ expects a string and a pattern.")

    if evaluated_head.name == "StringStartsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_starts_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringStartsQ expects a string and a pattern.")

    if evaluated_head.name == "StringEndsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_ends_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringEndsQ expects a string and a pattern.")

    if evaluated_head.name == "StringCases":
        if len(evaluated_arguments) == 2:
            return string_cases(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_cases(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringCases expects a string, a pattern or rule, and an optional match limit.")

    if evaluated_head.name == "StringReplace":
        if len(evaluated_arguments) == 2:
            return string_replace(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_replace(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringReplace expects a string, rules, and an optional replacement limit.")

    if evaluated_head.name == "ToCharacterCode":
        if len(evaluated_arguments) == 1:
            return to_character_code(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_character_code(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ToCharacterCode expects a string and an optional encoding.")

    if evaluated_head.name == "FromCharacterCode":
        if len(evaluated_arguments) == 1:
            return from_character_code(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return from_character_code(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("FromCharacterCode expects character codes and an optional encoding.")

    if evaluated_head.name == "StringToByteArray":
        if len(evaluated_arguments) == 1:
            return string_to_byte_array(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return string_to_byte_array(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringToByteArray expects a string and an optional encoding.")

    if evaluated_head.name == "ByteArrayToString":
        if len(evaluated_arguments) == 1:
            return byte_array_to_string(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return byte_array_to_string(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ByteArrayToString expects a byte array and an optional encoding.")

    if evaluated_head.name == "ExportString":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ExportString currently expects an expression and an explicit format specification.")
        return export_string(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ImportString":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ImportString currently expects a string and an explicit format specification.")
        return import_string_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ExportByteArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ExportByteArray currently expects an expression and an explicit format specification.")
        return export_byte_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ImportByteArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ImportByteArray currently expects a byte array and an explicit format specification.")
        return import_byte_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "BaseEncode":
        if len(evaluated_arguments) == 1:
            return base_encode(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return base_encode(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BaseEncode expects a byte array and an optional base encoding.")

    if evaluated_head.name == "BaseDecode":
        if len(evaluated_arguments) == 1:
            return base_decode(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return base_decode(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BaseDecode expects a string and an optional base encoding.")

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
        return _evaluated_list_expr(*level(subject, spec))

    if evaluated_head.name == "Take":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Take currently supports exactly one specification.")
        return take(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Drop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Drop currently supports exactly one specification.")
        return drop(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Select":
        if len(evaluated_arguments) == 2:
            return select(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return select(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Select expects an expression, a criterion or property specification, and an optional limit."
        )

    if evaluated_head.name == "Discard":
        if len(evaluated_arguments) == 2:
            return discard(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return discard(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Discard expects an expression, a criterion or property specification, and an optional limit."
        )

    if evaluated_head.name == "SelectFirst":
        if len(evaluated_arguments) == 2:
            return select_first(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return select_first(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "SelectFirst expects an expression, a criterion or property specification, and an optional default."
        )

    if evaluated_head.name == "TakeWhile":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeWhile expects exactly two arguments.")
        return take_while(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Boole":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Boole expects exactly one argument.")
        truth = _truth_value(evaluated_arguments[0])
        if truth is None:
            return evaluated_expr
        return integer(1 if truth else 0)

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

    if evaluated_head.name == "Scan":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return scan(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return scan(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Scan expects a function, an expression, and an optional level specification.")

    if evaluated_head.name == "Apply":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Apply currently supports exactly two arguments.")
        return apply_head(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "MapApply":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("MapApply currently supports exactly two arguments.")
        return map_apply(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Map":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Map currently supports exactly two arguments.")
        return map_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "MapAll":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("MapAll currently supports exactly two arguments.")
        return map_all(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "MapIndexed":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return map_indexed(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return map_indexed(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "MapIndexed expects a function, an expression, and an optional level specification."
        )

    if evaluated_head.name == "MapAt":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("MapAt currently supports exactly three arguments.")
        return map_at(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "Clip":
        return clip_expr(evaluated_arguments)

    if evaluated_head.name == "Construct":
        if not evaluated_arguments:
            raise WolframEvaluationError("Construct expects at least one argument.")
        return construct(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "ComposeList":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ComposeList expects exactly two arguments.")
        return compose_list(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Nest":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("Nest expects exactly three arguments.")
        return nest(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "NestList":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("NestList expects exactly three arguments.")
        return nest_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "NestWhile":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("NestWhile currently supports exactly three arguments.")
        return nest_while(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "NestWhileList":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("NestWhileList currently supports exactly three arguments.")
        return nest_while_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "FixedPoint":
        if len(evaluated_arguments) == 2:
            return fixed_point(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fixed_point(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("FixedPoint expects a function, an expression, and an optional iteration limit.")

    if evaluated_head.name == "FixedPointList":
        if len(evaluated_arguments) == 2:
            return fixed_point_list(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fixed_point_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "FixedPointList expects a function, an expression, and an optional iteration limit."
        )

    if evaluated_head.name == "Operate":
        if len(evaluated_arguments) == 2:
            return operate(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return operate(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Operate expects an operator, an expression, and an optional positive level.")

    if evaluated_head.name == "Comap":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Comap expects exactly two arguments.")
        return comap(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ComapApply":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ComapApply expects exactly two arguments.")
        return comap_apply(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Through":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Through currently supports exactly one argument.")
        return through(evaluated_arguments[0])

    if evaluated_head.name == "MapThread":
        if len(evaluated_arguments) == 2:
            return map_thread(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return map_thread(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("MapThread expects a function, a list of sequences, and an optional level.")

    if evaluated_head.name == "Thread":
        if len(evaluated_arguments) == 1:
            return thread(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return thread(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Thread expects an expression and an optional thread head.")

    if evaluated_head.name == "Distribute":
        if len(evaluated_arguments) == 1:
            return distribute(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return distribute(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return distribute(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Distribute currently supports an expression, an optional distributed head, and an optional outer head."
        )

    if evaluated_head.name == "Outer":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Outer expects a function and at least one sequence.")
        return outer(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Inner":
        if len(evaluated_arguments) != 4:
            raise WolframEvaluationError("Inner expects exactly four arguments.")
        return inner(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2], evaluated_arguments[3])

    if evaluated_head.name == "Dot":
        return dot(evaluated_arguments)

    if evaluated_head.name == "Tuples":
        if len(evaluated_arguments) == 1:
            return tuples_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return tuples_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Tuples expects a list of sequences or a sequence with a repetition count.")

    if evaluated_head.name == "Array":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Array currently supports exactly two arguments.")
        return array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ConstantArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ConstantArray currently supports exactly two arguments.")
        return constant_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Range":
        return range_expr(evaluated_arguments)

    if evaluated_head.name == "UnitVector":
        return unit_vector(evaluated_arguments)

    if evaluated_head.name == "IdentityMatrix":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("IdentityMatrix expects exactly one argument.")
        return identity_matrix(evaluated_arguments[0])

    if evaluated_head.name == "DiagonalMatrix":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("DiagonalMatrix expects exactly one argument.")
        return diagonal_matrix(evaluated_arguments[0])

    if evaluated_head.name == "Partition":
        if len(evaluated_arguments) == 2:
            return partition(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return partition(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Partition currently supports an expression, a block size, and an optional offset.")

    if evaluated_head.name == "BlockMap":
        if len(evaluated_arguments) == 3:
            return block_map(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return block_map(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError("BlockMap currently supports a function, an expression, a block size, and an optional offset.")

    if evaluated_head.name == "TakeList":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeList expects exactly two arguments.")
        return take_list(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "TakeDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeDrop expects exactly two arguments.")
        return take_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Fold":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("Fold expects exactly three arguments.")
        return fold(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "FoldList":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("FoldList expects exactly three arguments.")
        return fold_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "SequenceFold":
        if len(evaluated_arguments) == 3:
            return sequence_fold(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return sequence_fold(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "SequenceFold expects a function, initial values, inputs, and an optional argument count."
        )

    if evaluated_head.name == "SequenceFoldList":
        if len(evaluated_arguments) == 3:
            return sequence_fold_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return sequence_fold_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "SequenceFoldList expects a function, initial values, inputs, and an optional argument count."
        )

    if evaluated_head.name == "FoldWhile":
        if len(evaluated_arguments) == 4:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        if len(evaluated_arguments) == 5:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
            )
        if len(evaluated_arguments) == 6:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
                evaluated_arguments[5],
            )
        raise WolframEvaluationError(
            "FoldWhile currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
        )

    if evaluated_head.name == "FoldWhileList":
        if len(evaluated_arguments) == 4:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        if len(evaluated_arguments) == 5:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
            )
        if len(evaluated_arguments) == 6:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
                evaluated_arguments[5],
            )
        raise WolframEvaluationError(
            "FoldWhileList currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
        )

    if evaluated_head.name == "FoldPair":
        if len(evaluated_arguments) == 3:
            return fold_pair(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return fold_pair(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "FoldPair currently supports a function, an initial value, inputs, and an optional projection."
        )

    if evaluated_head.name == "FoldPairList":
        if len(evaluated_arguments) == 3:
            return fold_pair_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return fold_pair_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "FoldPairList currently supports a function, an initial value, inputs, and an optional projection."
        )

    if evaluated_head.name == "LengthWhile":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("LengthWhile expects exactly two arguments.")
        return length_while(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "FirstCase":
        if len(evaluated_arguments) == 2:
            return first_case(evaluated_arguments[0], expr.arguments[1])
        if len(evaluated_arguments) == 3:
            return first_case(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return first_case(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2], evaluated_arguments[3])
        raise WolframEvaluationError(
            "FirstCase expects an expression, a pattern, and optional default and level specification."
        )

    if evaluated_head.name == "Position":
        if len(evaluated_arguments) == 2:
            return position(evaluated_arguments[0], expr.arguments[1])
        if len(evaluated_arguments) == 3:
            return position(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return position(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2], evaluated_arguments[3])
        raise WolframEvaluationError(
            "Position expects an expression, a pattern, and optional level and result limits."
        )

    if evaluated_head.name == "MemberQ":
        if len(evaluated_arguments) == 2:
            return member_q(evaluated_arguments[0], expr.arguments[1])
        if len(evaluated_arguments) == 3:
            return member_q(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("MemberQ expects an expression, a pattern, and an optional level specification.")

    if evaluated_head.name == "DeleteDuplicates":
        if len(evaluated_arguments) == 1:
            return delete_duplicates(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return delete_duplicates(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("DeleteDuplicates expects an expression and an optional binary test.")

    if evaluated_head.name == "DeleteDuplicatesBy":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("DeleteDuplicatesBy expects exactly two arguments.")
        return delete_duplicates_by(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "DuplicateFreeQ":
        if len(evaluated_arguments) == 1:
            return duplicate_free_q(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return duplicate_free_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("DuplicateFreeQ expects an expression and an optional binary test.")

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

    return evaluated_expr


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
    if value in _ESCAPED_TOKEN_MAP:
        return _ESCAPED_TOKEN_MAP[value]
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
    "===",
    "=!=",
    "___",
    "__",
    "...",
    "..",
    "[[",
    "~~",
    "<>",
    "<|",
    "|>",
    "|->",
    "@*",
    "/*",
    ":>",
    "->",
    "/;",
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


_CHAINABLE_COMPARISON_HEADS = {
    "Equal",
    "Greater",
    "GreaterEqual",
    "Less",
    "LessEqual",
    "SameQ",
    "Unequal",
    "UnsameQ",
}


def _scan_escaped_token(text: str, start: int) -> tuple[_Token, int] | None:
    if not text.startswith(r"\[", start):
        return None

    end = text.find("]", start + 2)
    if end < 0:
        raise WolframSyntaxError(f"Unterminated Wolfram escaped token at offset {start}.")

    raw = text[start:end + 1]
    normalized = _ESCAPED_TOKEN_MAP.get(raw)
    if normalized is None:
        raise WolframSyntaxError(f"Unsupported Wolfram escaped token {raw!r} at offset {start}.")

    return _Token(kind="operator", text=normalized, start=start, end=end + 1, value=normalized), end + 1


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
        escaped_token = _scan_escaped_token(text, index)
        if escaped_token is not None:
            token, index = escaped_token
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
        if char in "[]{}(),.:+-*/^!@<>_|&#=":
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
    _STRING_EXPRESSION_BP = 64
    _NAMED_PATTERN_BP = 63
    _CONDITION_BP = 62
    _RULE_BP = 60
    _REPLACE_BP = 50
    _MAP_BP = 45
    _APPLY_BP = 44
    _COMPOSITION_BP = 43
    _AT_BP = 180
    _POSTFIX_BP = 30
    _SEMICOLON_BP = 20
    _FUNCTION_BP = 10
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

            if token.text in {"..", "..."}:
                if self._PATTERN_BP < min_bp:
                    break
                self._consume()
                left = call("RepeatedNull" if token.text == "..." else "Repeated", left)
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

            if token.text == "&":
                if self._FUNCTION_BP < min_bp:
                    break
                self._consume()
                left = call("Function", left)
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
            return self._parse_prefix_sequence_blank("BlankSequence" if token.text == "__" else "BlankNullSequence")

        if token.text == "_":
            return self._parse_prefix_blank()

        if token.text == "#":
            return self._parse_prefix_slot()

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

    def _parse_prefix_sequence_blank(self, head_name: str) -> Expr:
        if self._peek().kind == "symbol":
            return call(head_name, symbol(str(self._consume().value)))
        return call(head_name)

    def _parse_prefix_slot(self) -> Expr:
        next_token = self._peek()
        if next_token.kind == "integer":
            return call("Slot", integer(int(self._consume().value)))
        if next_token.kind == "symbol":
            key = string(str(self._consume().value))
            return Call(head_expr=call("Slot", integer(1)), arguments=(key,))
        return call("Slot", integer(1))

    def _parse_postfix_pattern(self, left: Expr) -> Expr:
        token = self._consume()
        if token.text in {"__", "___"}:
            if not isinstance(left, Symbol):
                raise WolframSyntaxError(
                    f"Named sequence pattern shorthand requires a symbol before {token.text!r} at offset {token.start}."
                )
            blank = self._parse_prefix_sequence_blank(
                "BlankSequence" if token.text == "__" else "BlankNullSequence"
            )
            return call("Pattern", left, blank)
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
        if isinstance(end, Call) and end.has_head("Span") and len(end.arguments) == 2:
            return call("Span", left, end.arguments[0], end.arguments[1])
        if self._match(";;") is not None:
            step = self._parse_span_argument(default=integer(1), terminators=terminators)
            return call("Span", left, end, step)
        return call("Span", left, end)

    def _parse_prefix_span(self, terminators: set[str]) -> Expr:
        end = self._parse_span_argument(default=symbol("All"), terminators=terminators)
        if isinstance(end, Call) and end.has_head("Span") and len(end.arguments) == 2:
            return call("Span", integer(1), end.arguments[0], end.arguments[1])
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
            "<>": (self._PLUS_BP, self._PLUS_BP + 1, "StringJoin"),
            "==": (self._COMPARE_BP, self._COMPARE_BP, "Equal"),
            "===": (self._COMPARE_BP, self._COMPARE_BP, "SameQ"),
            "!=": (self._COMPARE_BP, self._COMPARE_BP, "Unequal"),
            "=!=": (self._COMPARE_BP, self._COMPARE_BP, "UnsameQ"),
            "<": (self._COMPARE_BP, self._COMPARE_BP, "Less"),
            "<=": (self._COMPARE_BP, self._COMPARE_BP, "LessEqual"),
            ">": (self._COMPARE_BP, self._COMPARE_BP, "Greater"),
            ">=": (self._COMPARE_BP, self._COMPARE_BP, "GreaterEqual"),
            "&&": (self._AND_BP, self._AND_BP + 1, "And"),
            "||": (self._OR_BP, self._OR_BP + 1, "Or"),
            "|": (self._ALTERNATIVES_BP, self._ALTERNATIVES_BP + 1, "Alternatives"),
            "~~": (self._STRING_EXPRESSION_BP, self._STRING_EXPRESSION_BP + 1, "StringExpression"),
            ":": (self._NAMED_PATTERN_BP, self._NAMED_PATTERN_BP, "Pattern"),
            "/;": (self._CONDITION_BP, self._CONDITION_BP + 1, "Condition"),
            "->": (self._RULE_BP, self._RULE_BP, "Rule"),
            ":>": (self._RULE_BP, self._RULE_BP, "RuleDelayed"),
            "/.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceAll"),
            "//.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceRepeated"),
            "/@": (self._MAP_BP, self._MAP_BP + 1, "Map"),
            "//@": (self._MAP_BP, self._MAP_BP + 1, "MapAll"),
            "@@": (self._APPLY_BP, self._APPLY_BP + 1, "Apply"),
            "@@@": (self._APPLY_BP, self._APPLY_BP + 1, "MapApply"),
            "@*": (self._COMPOSITION_BP, self._COMPOSITION_BP, "Composition"),
            "/*": (self._COMPOSITION_BP, self._COMPOSITION_BP, "RightComposition"),
            "@": (self._AT_BP, self._AT_BP, None),
            "//": (self._POSTFIX_BP, self._POSTFIX_BP + 1, None),
            ";": (self._SEMICOLON_BP, self._SEMICOLON_BP + 1, "CompoundExpression"),
            ".": (self._TIMES_BP, self._TIMES_BP + 1, "Dot"),
            "|->": (self._FUNCTION_BP, self._FUNCTION_BP, "Function"),
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
        if text == ":":
            if not isinstance(left, Symbol):
                raise WolframSyntaxError(
                    f"Named pattern shorthand requires a symbol before ':' at offset {token.start}."
                )
            return call("Pattern", left, right)
        if text == "@":
            return Call(head_expr=left, arguments=(right,))
        if text == "//":
            return Call(head_expr=right, arguments=(left,))
        if head_name is None:
            raise WolframSyntaxError(f"Unhandled Wolfram operator {text!r}.")
        if (
            head_name in _CHAINABLE_COMPARISON_HEADS
            and isinstance(right, Call)
            and right.has_head(head_name)
        ):
            return call(head_name, left, *right.arguments)
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
    entries = _association_entries(expr)
    if entries is not None:
        for entry in entries:
            _collect_levels(entry.value, positive_level + 1, target)
        target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))
        return
    if isinstance(expr, Call):
        for argument in expr.arguments:
            _collect_levels(argument, positive_level + 1, target)
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))


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
        return (1, spec)

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
    return _level_bounds_match(record.positive_level, record.negative_level, level_min, level_max)
