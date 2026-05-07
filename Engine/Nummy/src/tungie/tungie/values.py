from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from typing import Iterable


class Expr:
    """Base class for Tungie expressions and evaluated values."""

    def to_full_form(self) -> str:
        raise NotImplementedError

    def to_input_form(self) -> str:
        return self.to_full_form()


@dataclass(frozen=True)
class Symbol(Expr):
    name: str

    def to_full_form(self) -> str:
        return self.name


@dataclass(frozen=True)
class Integer(Expr):
    value: int

    def to_full_form(self) -> str:
        return str(self.value)


@dataclass(frozen=True)
class Rational(Expr):
    value: Fraction

    def to_full_form(self) -> str:
        return f"Rational[{self.value.numerator}, {self.value.denominator}]"

    def to_input_form(self) -> str:
        return f"{self.value.numerator}/{self.value.denominator}"


@dataclass(frozen=True)
class Real(Expr):
    text: str

    def to_full_form(self) -> str:
        return self.text

    def to_input_form(self) -> str:
        return _format_real(self.text)


@dataclass(frozen=True)
class Call(Expr):
    head: Expr
    args: tuple[Expr, ...]

    def has_head(self, name: str) -> bool:
        return isinstance(self.head, Symbol) and self.head.name == name

    def to_full_form(self) -> str:
        arguments = ", ".join(argument.to_full_form() for argument in self.args)
        return f"{self.head.to_full_form()}[{arguments}]"

    def to_input_form(self) -> str:
        if self.has_head("ScientificScale") and len(self.args) == 2:
            scale = _format_scientific_scale(self.args[0], self.args[1])
            if scale is not None:
                return scale
        if self.has_head("Pow10Tower") and len(self.args) == 2:
            tower = _format_pow10_tower(self.args[0], self.args[1])
            if tower is not None:
                return tower
        if self.has_head("List"):
            return "{" + ", ".join(argument.to_input_form() for argument in self.args) + "}"
        if self.has_head("Plus"):
            return _format_plus(self.args)
        if self.has_head("Times"):
            return _format_times(self.args)
        if self.has_head("Power") and len(self.args) == 2:
            exponent = _parenthesize(self.args[1], 79)
            if isinstance(self.args[1], Rational):
                exponent = f"({exponent})"
            return f"{_parenthesize(self.args[0], 80)}^{exponent}"
        binary_operator = _BINARY_OPERATOR_HEADS.get(_head_name(self.head))
        if binary_operator is not None and len(self.args) == 2:
            return f"{_parenthesize(self.args[0], 40)} {binary_operator} {_parenthesize(self.args[1], 40)}"
        if self.has_head("Not") and len(self.args) == 1:
            return "!" + _parenthesize(self.args[0], 70)

        arguments = ", ".join(argument.to_input_form() for argument in self.args)
        return f"{self.head.to_input_form()}[{arguments}]"


@dataclass(frozen=True)
class Assignment(Expr):
    name: str
    value: Expr

    def to_full_form(self) -> str:
        return f"Set[{self.name}, {self.value.to_full_form()}]"

    def to_input_form(self) -> str:
        return f"{self.name} = {self.value.to_input_form()}"


@dataclass(frozen=True)
class Program(Expr):
    statements: tuple[Expr, ...]
    suppress_output: bool = False

    def to_full_form(self) -> str:
        if not self.statements:
            return "Null"
        arguments: list[str] = [statement.to_full_form() for statement in self.statements]
        if self.suppress_output:
            arguments.append("Null")
        return "CompoundExpression[" + ", ".join(arguments) + "]"

    def to_input_form(self) -> str:
        if not self.statements:
            return "Null"
        text = "; ".join(statement.to_input_form() for statement in self.statements)
        if self.suppress_output:
            text += ";"
        return text


def symbol(name: str) -> Symbol:
    return Symbol(name)


def integer(value: int) -> Integer:
    return Integer(value)


def rational(numerator: int, denominator: int) -> Expr:
    value = Fraction(numerator, denominator)
    if value.denominator == 1:
        return Integer(value.numerator)
    return Rational(value)


def real(text: str) -> Real:
    return Real(text)


def call(head: str | Expr, *args: Expr) -> Call:
    return Call(symbol(head) if isinstance(head, str) else head, tuple(args))


def list_expr(items: Iterable[Expr]) -> Call:
    return Call(symbol("List"), tuple(items))


def _head_name(expr: Expr) -> str | None:
    return expr.name if isinstance(expr, Symbol) else None


def _format_real(text: str) -> str:
    text = text.replace("*^+", "*^")
    if "*^-" not in text:
        return text
    mantissa, exponent = text.split("*^-", 1)
    if not exponent or not exponent[0].isdigit():
        return text
    return f"{mantissa}/^{exponent}"


_BINARY_OPERATOR_HEADS = {
    "And": "&&",
    "Or": "||",
    "Equal": "==",
    "Unequal": "!=",
    "Less": "<",
    "LessEqual": "<=",
    "Greater": ">",
    "GreaterEqual": ">=",
    "Divide": "/",
}


def _format_plus(arguments: tuple[Expr, ...]) -> str:
    if not arguments:
        return "0"
    pieces: list[str] = []
    for argument in arguments:
        sign, body = _split_negative(argument)
        if not pieces:
            pieces.append(("-" if sign < 0 else "") + _parenthesize(body, 50))
        elif sign < 0:
            pieces.append("- " + _parenthesize(body, 50))
        else:
            pieces.append("+ " + _parenthesize(body, 50))
    return " ".join(pieces)


def _format_times(arguments: tuple[Expr, ...]) -> str:
    if not arguments:
        return "1"
    scale = _format_scale_product(arguments)
    if scale is not None:
        return scale
    if len(arguments) == 2 and isinstance(arguments[1], Call) and arguments[1].has_head("Power"):
        base, exponent = arguments[1].args if len(arguments[1].args) == 2 else (None, None)
        if isinstance(exponent, Integer) and exponent.value == -1 and base is not None:
            return f"{_parenthesize(arguments[0], 60)} / {_parenthesize(base, 60)}"
    if len(arguments) == 2 and isinstance(arguments[0], Integer) and arguments[0].value == -1:
        return "-" + _parenthesize(arguments[1], 70)
    return " * ".join(_parenthesize(argument, 60) for argument in arguments)


def _format_scale_product(arguments: tuple[Expr, ...]) -> str | None:
    if len(arguments) != 2 or not isinstance(arguments[1], Call):
        return None
    scale = _scale_operator_and_top(arguments[1])
    if scale is None:
        return None
    operator, top = scale
    return f"{_parenthesize(arguments[0], 80)}{operator}{_parenthesize(top, 80)}"


def _format_scientific_scale(mantissa: Expr, exponent: Expr) -> str | None:
    sign, exponent = _strip_scale_exponent_minus(exponent)
    tower = _pow10_tower_height_and_top(exponent)
    if tower is None:
        return None
    height, top = tower
    if height == 0 and not isinstance(top, Integer):
        return None
    operator = ("*" if sign > 0 else "/") + "^" * (height + 1)
    return f"{_scale_mantissa_text(mantissa)}{operator}{_scale_coordinate_text(top)}"


def _format_pow10_tower(height: Expr, top: Expr) -> str | None:
    if not isinstance(height, Integer) or height.value <= 0:
        return None
    if height.value == 1 and not isinstance(top, Integer):
        return None
    operator = "*" + "^" * height.value
    return f"1{operator}{_scale_coordinate_text(top)}"


def _scale_coordinate_text(expr: Expr) -> str:
    if isinstance(expr, (Integer, Rational, Real, Symbol)):
        return _parenthesize(expr, 80)
    return f"({expr.to_input_form()})"


def _scale_mantissa_text(expr: Expr) -> str:
    if isinstance(expr, Real):
        return _parenthesize(Real(_trim_scale_mantissa_real(expr.text)), 80)
    return _parenthesize(expr, 80)


def _trim_scale_mantissa_real(text: str) -> str:
    if "*^" in text:
        return text
    marker_start = text.find("`")
    if marker_start >= 0:
        decimal = text[:marker_start]
        marker = text[marker_start:]
    else:
        decimal = text
        marker = ""
    if "." not in decimal:
        return text
    decimal = decimal.rstrip("0").rstrip(".")
    if decimal in {"", "-", "+"}:
        decimal += "0"
    return decimal + marker


def _scale_operator_and_top(expr: Call) -> tuple[str, Expr] | None:
    if not expr.has_head("Power") or len(expr.args) != 2:
        return None
    base, exponent = expr.args
    if not isinstance(base, Integer) or base.value != 10:
        return None

    sign = "*"
    exponent = _strip_scale_exponent_minus(exponent)
    if exponent[0] < 0:
        sign = "/"
    tower = _pow10_tower_height_and_top(exponent[1])
    if tower is None:
        return None
    height, top = tower
    return sign + "^" * (height + 1), top


def _strip_scale_exponent_minus(expr: Expr) -> tuple[int, Expr]:
    if isinstance(expr, Integer) and expr.value < 0:
        return -1, Integer(-expr.value)
    if isinstance(expr, Real) and expr.text.startswith("-"):
        return -1, Real(expr.text[1:])
    if (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.args) == 2
        and isinstance(expr.args[0], Integer)
        and expr.args[0].value == -1
    ):
        return -1, expr.args[1]
    if isinstance(expr, Call) and expr.has_head("Plus") and expr.args:
        positive_terms: list[Expr] = []
        for argument in expr.args:
            sign, body = _strip_scale_exponent_minus(argument)
            if sign > 0:
                return 1, expr
            positive_terms.append(body)
        return -1, Call(expr.head, tuple(positive_terms))
    return 1, expr


def _pow10_tower_height_and_top(expr: Expr) -> tuple[int, Expr] | None:
    if isinstance(expr, Call) and expr.has_head("Pow10Tower") and len(expr.args) == 2:
        height, top = expr.args
        if isinstance(height, Integer) and height.value >= 0:
            return height.value, top
        return None
    height = 0
    current = expr
    while isinstance(current, Call) and current.has_head("Power") and len(current.args) == 2:
        base, exponent = current.args
        if not isinstance(base, Integer) or base.value != 10:
            break
        height += 1
        current = exponent
    return height, current


def _split_negative(expr: Expr) -> tuple[int, Expr]:
    if isinstance(expr, Integer) and expr.value < 0:
        return -1, Integer(-expr.value)
    if isinstance(expr, Rational) and expr.value < 0:
        return -1, Rational(-expr.value)
    if isinstance(expr, Real) and expr.text.startswith("-"):
        return -1, Real(expr.text[1:])
    if (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and expr.args
        and isinstance(expr.args[0], Integer)
        and expr.args[0].value == -1
    ):
        if len(expr.args) == 2:
            return -1, expr.args[1]
        return -1, Call(expr.head, expr.args[1:])
    return 1, expr


def _precedence(expr: Expr) -> int:
    if isinstance(expr, Call):
        if expr.has_head("Or"):
            return 20
        if expr.has_head("And"):
            return 30
        if _head_name(expr.head) in _BINARY_OPERATOR_HEADS:
            return 40
        if expr.has_head("Plus"):
            return 50
        if expr.has_head("Divide"):
            return 60
        if expr.has_head("Times"):
            return 60
        if expr.has_head("Power"):
            return 80
    return 100


def _parenthesize(expr: Expr, parent_precedence: int) -> str:
    text = expr.to_input_form()
    return f"({text})" if _precedence(expr) < parent_precedence else text
