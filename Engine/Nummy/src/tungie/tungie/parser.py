from __future__ import annotations

from .errors import TungieSyntaxError
from .lexer import Token
from .lexer import lex
from .values import Assignment
from .values import Call
from .values import Expr
from .values import Integer
from .values import Program
from .values import Real
from .values import Symbol
from .values import call
from .values import integer
from .values import list_expr
from .values import real
from .values import symbol


_INFIX_BINDING_POWER = {
    "||": 20,
    "&&": 30,
    "==": 40,
    "!=": 40,
    "<": 40,
    "<=": 40,
    ">": 40,
    ">=": 40,
    "+": 50,
    "-": 50,
    "*": 60,
    "/": 60,
    "^": 80,
}

_INFIX_HEADS = {
    "||": "Or",
    "&&": "And",
    "==": "Equal",
    "!=": "Unequal",
    "<": "Less",
    "<=": "LessEqual",
    ">": "Greater",
    ">=": "GreaterEqual",
    "+": "Plus",
    "*": "Times",
    "^": "Power",
}

_COMPARISON_HEADS = {"Equal", "Unequal", "Less", "LessEqual", "Greater", "GreaterEqual"}
_COMPARISON_OPERATORS = {"==", "!=", "<", "<=", ">", ">="}


def parse(source: str) -> Expr:
    return Parser(lex(source)).parse_program()


class Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.tokens = tokens
        self.index = 0

    def parse_program(self) -> Expr:
        statements: list[Expr] = []
        suppress_output = False

        while not self._at("eof"):
            if self._text() == ";":
                self._consume()
                suppress_output = True
                continue

            statements.append(self._parse_statement())
            if self._text() == ";":
                self._consume()
                suppress_output = self._at("eof")
                continue
            suppress_output = False
            break

        self._expect_kind("eof")
        if not statements:
            return symbol("Null")
        if len(statements) == 1 and not suppress_output:
            return statements[0]
        return Program(tuple(statements), suppress_output=suppress_output)

    def _parse_statement(self) -> Expr:
        if self._at("symbol") and self._peek(1).text == "=":
            name = self._consume().text
            self._expect("=")
            if name in _PROTECTED_ASSIGNMENT_NAMES:
                raise TungieSyntaxError(f"Cannot assign to protected symbol {name}.")
            value = self._parse_expression(0, {";", "eof"})
            return Assignment(name, value)
        return self._parse_expression(0, {";", "eof"})

    def _parse_expression(self, min_bp: int, terminators: set[str]) -> Expr:
        left = self._parse_prefix(terminators)

        while True:
            token = self._peek()
            if self._terminates(token, terminators):
                break

            if token.text == "[":
                if 90 < min_bp:
                    break
                left = self._parse_call(left)
                continue

            if self._starts_primary(token):
                implicit_bp = 60
                if implicit_bp < min_bp:
                    break
                right = self._parse_expression(implicit_bp + 1, terminators)
                left = _flatten_call("Times", left, right)
                continue

            if token.kind != "operator" or token.text not in _INFIX_BINDING_POWER:
                break

            operator = token.text
            left_bp = _INFIX_BINDING_POWER[operator]
            if left_bp < min_bp:
                break
            if operator in _COMPARISON_OPERATORS and _is_comparison(left):
                raise TungieSyntaxError("Chained inequalities are not supported.")

            self._consume()
            right_bp = left_bp if operator == "^" else left_bp + 1
            right = self._parse_expression(right_bp, terminators)
            if operator in _COMPARISON_OPERATORS and _is_comparison(right):
                raise TungieSyntaxError("Chained inequalities are not supported.")
            left = self._make_infix(operator, left, right)

        return left

    def _parse_prefix(self, terminators: set[str]) -> Expr:
        token = self._peek()
        if self._terminates(token, terminators):
            raise TungieSyntaxError(f"Expected expression at offset {token.start}.")
        if token.kind == "integer":
            self._consume()
            return integer(int(token.text))
        if token.kind == "real":
            self._consume()
            return real(token.text)
        if token.kind == "symbol":
            self._consume()
            return symbol(token.text)
        if token.kind == "history":
            self._consume()
            return _history_call(token.text)
        if token.text == "(":
            self._consume()
            expr = self._parse_expression(0, {")"})
            self._expect(")")
            return expr
        if token.text == "{":
            return self._parse_list()
        if token.text == "+":
            self._consume()
            return self._parse_expression(70, terminators)
        if token.text == "-":
            self._consume()
            return _negate(self._parse_expression(70, terminators))
        if token.text == "!":
            self._consume()
            return call("Not", self._parse_expression(70, terminators))
        raise TungieSyntaxError(f"Expected expression at offset {token.start}.")

    def _parse_call(self, head: Expr) -> Expr:
        self._expect("[")
        arguments: list[Expr] = []
        if self._text() != "]":
            while True:
                arguments.append(self._parse_expression(0, {",", "]"}))
                if self._text() == ",":
                    self._consume()
                    if self._text() == "]":
                        raise TungieSyntaxError("Trailing commas are not supported in function arguments.")
                    continue
                break
        self._expect("]")
        return Call(head, tuple(arguments))

    def _parse_list(self) -> Expr:
        self._expect("{")
        items: list[Expr] = []
        if self._text() != "}":
            while True:
                items.append(self._parse_expression(0, {",", "}"}))
                if self._text() == ",":
                    self._consume()
                    if self._text() == "}":
                        raise TungieSyntaxError("Trailing commas are not supported in lists.")
                    continue
                break
        self._expect("}")
        return list_expr(items)

    def _make_infix(self, operator: str, left: Expr, right: Expr) -> Expr:
        if operator == "-":
            return _flatten_call("Plus", left, _negate(right))
        if operator == "/":
            return _flatten_call("Times", left, call("Power", right, integer(-1)))
        if operator in {"*", "+"}:
            return _flatten_call(_INFIX_HEADS[operator], left, right)
        return call(_INFIX_HEADS[operator], left, right)

    def _starts_primary(self, token: Token) -> bool:
        return token.kind in {"integer", "real", "symbol", "history"} or token.text in {"(", "{"}

    def _terminates(self, token: Token, terminators: set[str]) -> bool:
        return token.kind == "eof" and "eof" in terminators or token.text in terminators

    def _at(self, kind: str) -> bool:
        return self._peek().kind == kind

    def _text(self) -> str:
        return self._peek().text

    def _peek(self, offset: int = 0) -> Token:
        position = min(self.index + offset, len(self.tokens) - 1)
        return self.tokens[position]

    def _consume(self) -> Token:
        token = self._peek()
        self.index += 1
        return token

    def _expect(self, text: str) -> Token:
        token = self._peek()
        if token.text != text:
            raise TungieSyntaxError(f"Expected {text!r} at offset {token.start}.")
        return self._consume()

    def _expect_kind(self, kind: str) -> Token:
        token = self._peek()
        if token.kind != kind:
            raise TungieSyntaxError(f"Unexpected token {token.text!r} at offset {token.start}.")
        return self._consume()


def _history_call(text: str) -> Expr:
    if text == "%":
        return call("Out")
    if text == "%%":
        return call("Out", integer(-2))
    return call("Out", integer(int(text[1:])))


def _negate(expr: Expr) -> Expr:
    if isinstance(expr, Integer):
        return integer(-expr.value)
    if isinstance(expr, Real) and not expr.text.startswith("-"):
        return real("-" + expr.text)
    return call("Times", integer(-1), expr)


def _flatten_call(head: str, *arguments: Expr) -> Expr:
    flattened: list[Expr] = []
    for argument in arguments:
        if isinstance(argument, Call) and argument.has_head(head):
            flattened.extend(argument.args)
        else:
            flattened.append(argument)
    return call(head, *flattened)


def _is_comparison(expr: Expr) -> bool:
    return isinstance(expr, Call) and isinstance(expr.head, Symbol) and expr.head.name in _COMPARISON_HEADS


_PROTECTED_ASSIGNMENT_NAMES = {
    "E",
    "Pi",
    "Degree",
    "I",
    "True",
    "False",
    "Null",
    "Infinity",
    "MachinePrecision",
    "$MachinePrecision",
    "$MachineEpsilon",
    "$MaxMachineNumber",
    "$MinMachineNumber",
}
