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


_BINARY_OPERATOR_HEADS = {
    "And": "&&",
    "Or": "||",
    "Equal": "==",
    "Unequal": "!=",
    "Less": "<",
    "LessEqual": "<=",
    "Greater": ">",
    "GreaterEqual": ">=",
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
    if len(arguments) == 2 and isinstance(arguments[1], Call) and arguments[1].has_head("Power"):
        base, exponent = arguments[1].args if len(arguments[1].args) == 2 else (None, None)
        if isinstance(exponent, Integer) and exponent.value == -1 and base is not None:
            return f"{_parenthesize(arguments[0], 60)} / {_parenthesize(base, 60)}"
    if len(arguments) == 2 and isinstance(arguments[0], Integer) and arguments[0].value == -1:
        return "-" + _parenthesize(arguments[1], 70)
    return " * ".join(_parenthesize(argument, 60) for argument in arguments)


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
        if expr.has_head("Times"):
            return 60
        if expr.has_head("Power"):
            return 80
    return 100


def _parenthesize(expr: Expr, parent_precedence: int) -> str:
    text = expr.to_input_form()
    return f"({text})" if _precedence(expr) < parent_precedence else text
