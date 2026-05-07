"""Tiny expression parser and evaluator for the Nummy calculator REPL."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, localcontext
from enum import Enum
from fractions import Fraction
from typing import Iterable, Self

from .context import NummyContext
from .perturbation import first_order_tower_perturbation
from .sparse_decimal import SparseDecimalInteger
from .tower import INEXACT, TowerReal

DEFAULT_CALCULATOR_PRECISION = 50
MAX_EXACT_POWER_DIGITS = 10_000


class CalculatorSyntaxError(ValueError):
    """Raised when calculator input cannot be parsed."""


class TokenKind(Enum):
    NUMBER = "number"
    NAME = "name"
    HISTORY_RELATIVE = "history_relative"
    HISTORY_ABSOLUTE = "history_absolute"
    PLUS = "+"
    MINUS = "-"
    STAR = "*"
    SLASH = "/"
    CARET = "^"
    EQUALS = "="
    COMMA = ","
    LPAREN = "("
    RPAREN = ")"
    LBRACKET = "["
    RBRACKET = "]"
    EOF = "eof"


@dataclass(frozen=True)
class Token:
    kind: TokenKind
    text: str
    position: int


@dataclass(frozen=True)
class CalculatorEvaluation:
    line: int
    source: str
    value: "CalculatorValue"
    assigned_name: str | None = None

    @property
    def display_text(self) -> str:
        return format_value(self.value)


@dataclass(frozen=True)
class TowerPerturbationState:
    """A tiny base-10 perturbation being propagated by ordinary powers."""

    base: int
    epsilon_exponent: int
    levels: int = 0

    def advance(self) -> Self:
        return TowerPerturbationState(
            self.base,
            self.epsilon_exponent,
            self.levels + 1,
        )

    def anchor_tower(self) -> TowerReal:
        if self.base != 10:
            raise NotImplementedError("only base-10 perturbation anchors are supported")
        if self.levels == 0:
            return TowerReal.from_layer(1, self.epsilon_exponent, reciprocal=True)
        if self.levels == 1:
            return TowerReal.from_int(1).with_flags(INEXACT)
        if self.levels == 2:
            return TowerReal.from_int(10).with_flags(INEXACT)
        if self.levels == 3:
            return TowerReal.from_int(10_000_000_000).with_flags(INEXACT)
        return TowerReal.from_layer(self.levels - 3, 10_000_000_000).with_flags(
            INEXACT
        )


@dataclass(frozen=True)
class CalculatorValue:
    """A calculator value with a certified display precision contract."""

    tower: TowerReal
    precision: int
    exact_fraction: Fraction | None = None
    certified: bool = True
    display_override: str | None = None
    perturbation: TowerPerturbationState | None = None

    @classmethod
    def zero(cls, precision: int) -> Self:
        return cls.from_fraction(Fraction(0), precision=precision)

    @classmethod
    def from_fraction(cls, value: Fraction, *, precision: int) -> Self:
        return cls(
            _tower_from_fraction(value, precision=precision),
            precision,
            value,
            True,
        )

    @classmethod
    def from_tower(
        cls,
        value: TowerReal,
        *,
        precision: int,
        certified: bool = True,
        perturbation: TowerPerturbationState | None = None,
    ) -> Self:
        exact_fraction = _fraction_from_tower(value) if certified else None
        return cls(value, precision, exact_fraction, certified, None, perturbation)

    @classmethod
    def from_display(cls, text: str, *, precision: int) -> Self:
        return cls(TowerReal.zero(), precision, None, True, text)

    def with_precision(self, precision: int) -> Self:
        return CalculatorValue(
            self.tower,
            precision,
            self.exact_fraction,
            self.certified,
            self.display_override,
            self.perturbation,
        )

    def add(self, other: Self) -> Self:
        self._ensure_numeric()
        other._ensure_numeric()
        precision = min(self.precision, other.precision)
        if self.exact_fraction is not None and other.exact_fraction is not None:
            return CalculatorValue.from_fraction(
                self.exact_fraction + other.exact_fraction,
                precision=precision,
            )
        return CalculatorValue.from_tower(
            self.tower + other.tower,
            precision=precision,
            certified=False,
        )

    def subtract(self, other: Self) -> Self:
        self._ensure_numeric()
        other._ensure_numeric()
        precision = min(self.precision, other.precision)
        if self.exact_fraction is not None and other.exact_fraction is not None:
            return CalculatorValue.from_fraction(
                self.exact_fraction - other.exact_fraction,
                precision=precision,
            )
        return CalculatorValue.from_tower(
            self.tower - other.tower,
            precision=precision,
            certified=False,
        )

    def multiply(self, other: Self) -> Self:
        self._ensure_numeric()
        other._ensure_numeric()
        precision = min(self.precision, other.precision)
        if self.exact_fraction is not None and other.exact_fraction is not None:
            return CalculatorValue.from_fraction(
                self.exact_fraction * other.exact_fraction,
                precision=precision,
            )
        return CalculatorValue.from_tower(
            self.tower * other.tower,
            precision=precision,
            certified=False,
        )

    def divide(self, other: Self) -> Self:
        self._ensure_numeric()
        other._ensure_numeric()
        precision = min(self.precision, other.precision)
        if other.exact_fraction == 0 or other.tower.is_zero:
            raise ZeroDivisionError("cannot divide by zero")
        if self.exact_fraction is not None and other.exact_fraction is not None:
            return CalculatorValue.from_fraction(
                self.exact_fraction / other.exact_fraction,
                precision=precision,
            )
        return CalculatorValue.from_tower(
            self.tower / other.tower,
            precision=precision,
            certified=False,
        )

    def power(self, exponent: Self) -> Self:
        self._ensure_numeric()
        exponent._ensure_numeric()
        precision = min(self.precision, exponent.precision)
        if exponent.exact_fraction is not None and exponent.exact_fraction.denominator == 1:
            exponent_int = exponent.exact_fraction.numerator
            if self.exact_fraction is not None:
                estimated_digits = _estimate_integer_power_digits(
                    self.exact_fraction,
                    exponent_int,
                )
                if estimated_digits <= MAX_EXACT_POWER_DIGITS:
                    return CalculatorValue.from_fraction(
                        self.exact_fraction**exponent_int,
                        precision=precision,
                    )
                if self.exact_fraction == Fraction(10, 1) and exponent_int < 0:
                    state = TowerPerturbationState(
                        base=10,
                        epsilon_exponent=-exponent_int,
                    )
                    return CalculatorValue.from_tower(
                        state.anchor_tower(),
                        precision=precision,
                        certified=True,
                        perturbation=state,
                    )
            tower = self.tower ** exponent.tower
            certified = self.certified and exponent.certified and _is_power_exact(
                self,
                exponent_int,
                tower,
            )
            return CalculatorValue.from_tower(
                tower,
                precision=precision,
                certified=certified,
            )

        if self.exact_fraction == Fraction(10, 1) and exponent.perturbation is not None:
            state = exponent.perturbation.advance()
            return CalculatorValue.from_tower(
                state.anchor_tower(),
                precision=precision,
                certified=False,
                perturbation=state,
            )

        if self.exact_fraction == Fraction(10, 1) and exponent.certified:
            return CalculatorValue.from_tower(
                self.tower ** exponent.tower,
                precision=precision,
                certified=True,
            )

        raise ValueError(
            "non-integer powers are not precision-certified by the alpha calculator"
        )

    def negate(self) -> Self:
        self._ensure_numeric()
        if self.exact_fraction is not None:
            return CalculatorValue.from_fraction(-self.exact_fraction, precision=self.precision)
        return CalculatorValue.from_tower(
            -self.tower,
            precision=self.precision,
            certified=self.certified,
        )

    def _ensure_numeric(self) -> None:
        if self.display_override is not None:
            raise ValueError("cannot use a report value in arithmetic")


class CalculatorSession:
    """Stateful calculator session with variables and output history."""

    def __init__(self, *, default_precision: int = DEFAULT_CALCULATOR_PRECISION) -> None:
        self.default_precision = _validate_precision(default_precision)
        self.variables: dict[str, CalculatorValue] = {}
        self.inputs: list[str] = []
        self.outputs: list[CalculatorValue] = []

    @property
    def line(self) -> int:
        return len(self.inputs)

    def evaluate_line(self, source: str) -> CalculatorEvaluation:
        source = source.strip()
        if not source:
            raise CalculatorSyntaxError("empty input is not an expression")

        tokens = tokenize(source)
        assigned_name: str | None = None
        if (
            len(tokens) >= 3
            and tokens[0].kind == TokenKind.NAME
            and tokens[1].kind == TokenKind.EQUALS
        ):
            assigned_name = tokens[0].text
            parser = _Parser(tokens[2:], self)
            value = parser.parse()
            self.variables[assigned_name] = value
        else:
            parser = _Parser(tokens, self)
            value = parser.parse()

        self.inputs.append(source)
        self.outputs.append(value)
        return CalculatorEvaluation(
            line=self.line,
            source=source,
            value=value,
            assigned_name=assigned_name,
        )

    def variable_value(self, name: str) -> CalculatorValue:
        return self.variables.get(name, CalculatorValue.zero(self.default_precision))

    def history_relative(self, offset: int) -> CalculatorValue:
        if offset <= 0:
            raise CalculatorSyntaxError("history offset must be positive")
        index = len(self.outputs) - offset
        if index < 0:
            return CalculatorValue.zero(self.default_precision)
        return self.outputs[index]

    def history_absolute(self, line: int) -> CalculatorValue:
        if line <= 0:
            raise CalculatorSyntaxError("history line number must be positive")
        index = line - 1
        if index >= len(self.outputs):
            return CalculatorValue.zero(self.default_precision)
        return self.outputs[index]


def tokenize(source: str) -> list[Token]:
    tokens: list[Token] = []
    index = 0
    while index < len(source):
        ch = source[index]
        if ch.isspace():
            index += 1
            continue

        if ch.isdigit() or (
            ch == "." and index + 1 < len(source) and source[index + 1].isdigit()
        ):
            tokens.append(_read_number(source, index))
            index = tokens[-1].position + len(tokens[-1].text)
            continue

        if ch.isalpha() or ch == "_":
            start = index
            index += 1
            while index < len(source) and (
                source[index].isalnum() or source[index] == "_"
            ):
                index += 1
            tokens.append(Token(TokenKind.NAME, source[start:index], start))
            continue

        if ch == "%":
            start = index
            index += 1
            if index < len(source) and source[index] == "%":
                index += 1
                tokens.append(Token(TokenKind.HISTORY_RELATIVE, "2", start))
            else:
                number_start = index
                while index < len(source) and source[index].isdigit():
                    index += 1
                if index > number_start:
                    tokens.append(
                        Token(
                            TokenKind.HISTORY_ABSOLUTE,
                            source[number_start:index],
                            start,
                        )
                    )
                else:
                    tokens.append(Token(TokenKind.HISTORY_RELATIVE, "1", start))
            continue

        simple_tokens = {
            "+": TokenKind.PLUS,
            "-": TokenKind.MINUS,
            "*": TokenKind.STAR,
            "/": TokenKind.SLASH,
            "^": TokenKind.CARET,
            "=": TokenKind.EQUALS,
            ",": TokenKind.COMMA,
            "(": TokenKind.LPAREN,
            ")": TokenKind.RPAREN,
            "[": TokenKind.LBRACKET,
            "]": TokenKind.RBRACKET,
        }
        if ch in simple_tokens:
            tokens.append(Token(simple_tokens[ch], ch, index))
            index += 1
            continue

        raise CalculatorSyntaxError(f"unexpected character {ch!r} at column {index + 1}")

    tokens.append(Token(TokenKind.EOF, "", len(source)))
    return tokens


def format_value(value: TowerReal | CalculatorValue) -> str:
    """Format calculator output with an explicit precision mark."""

    if isinstance(value, CalculatorValue):
        if value.display_override is not None:
            return value.display_override
        if value.perturbation is not None:
            return _format_perturbation_value(value.perturbation, value.precision)
        if not value.certified:
            return f"{_format_tower(value.tower)}`0"
        if value.exact_fraction is not None:
            return _format_fraction(value.exact_fraction, value.precision)
        return f"{_format_tower(value.tower)}`{value.precision}"

    if value.layer == 0:
        return _format_decimal(value.to_decimal())
    return _format_tower(value)


def _format_decimal(value: Decimal) -> str:
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    if text == "-0":
        return "0"
    return text or "0"


def _read_number(source: str, start: int) -> Token:
    index = start
    saw_digits = False
    while index < len(source) and source[index].isdigit():
        saw_digits = True
        index += 1
    if index < len(source) and source[index] == ".":
        index += 1
        while index < len(source) and source[index].isdigit():
            saw_digits = True
            index += 1
    if not saw_digits:
        raise CalculatorSyntaxError(f"expected digits at column {start + 1}")

    if index < len(source) and source[index] == "`":
        index += 1
        if index < len(source) and source[index] == "`":
            raise CalculatorSyntaxError(
                f"accuracy marks are not supported; use precision syntax at column {index + 1}"
            )
        precision_start = index
        while index < len(source) and source[index].isdigit():
            index += 1
        if index == precision_start:
            pass

    if index < len(source) and source[index : index + 2] == "*^":
        index += 2
        index = _read_exponent_digits(source, index, start)
    elif index < len(source) and source[index] in "eE":
        index += 1
        index = _read_exponent_digits(source, index, start)

    return Token(TokenKind.NUMBER, source[start:index], start)


def _read_exponent_digits(source: str, index: int, start: int) -> int:
    exponent_marker = index
    if index < len(source) and source[index] in "+-":
        index += 1
    exponent_start = index
    while index < len(source) and source[index].isdigit():
        index += 1
    if index == exponent_start:
        raise CalculatorSyntaxError(
            f"missing exponent digits at column {exponent_marker + 1}"
        )
    return index


class _Parser:
    def __init__(self, tokens: Iterable[Token], session: CalculatorSession) -> None:
        self._tokens = list(tokens)
        if not self._tokens or self._tokens[-1].kind != TokenKind.EOF:
            position = self._tokens[-1].position if self._tokens else 0
            self._tokens.append(Token(TokenKind.EOF, "", position))
        self._position = 0
        self._session = session

    def parse(self) -> CalculatorValue:
        value = self._parse_additive()
        self._expect(TokenKind.EOF)
        return value

    def _parse_additive(self) -> CalculatorValue:
        value = self._parse_multiplicative()
        while self._peek().kind in (TokenKind.PLUS, TokenKind.MINUS):
            operator = self._advance()
            right = self._parse_multiplicative()
            if operator.kind == TokenKind.PLUS:
                value = value.add(right)
            else:
                value = value.subtract(right)
        return value

    def _parse_multiplicative(self) -> CalculatorValue:
        value = self._parse_unary()
        while self._peek().kind in (TokenKind.STAR, TokenKind.SLASH):
            operator = self._advance()
            right = self._parse_unary()
            if operator.kind == TokenKind.STAR:
                value = value.multiply(right)
            else:
                value = value.divide(right)
        return value

    def _parse_power(self) -> CalculatorValue:
        value = self._parse_primary()
        if self._peek().kind == TokenKind.CARET:
            self._advance()
            value = value.power(self._parse_unary())
        return value

    def _parse_unary(self) -> CalculatorValue:
        if self._peek().kind == TokenKind.PLUS:
            self._advance()
            return self._parse_unary()
        if self._peek().kind == TokenKind.MINUS:
            self._advance()
            return self._parse_unary().negate()
        return self._parse_power()

    def _parse_primary(self) -> CalculatorValue:
        token = self._advance()
        if token.kind == TokenKind.NUMBER:
            return _value_from_number_token(token, self._session.default_precision)
        if token.kind == TokenKind.NAME:
            if self._peek().kind == TokenKind.LBRACKET:
                return self._parse_function_call(token)
            return self._session.variable_value(token.text)
        if token.kind == TokenKind.HISTORY_RELATIVE:
            return self._session.history_relative(int(token.text))
        if token.kind == TokenKind.HISTORY_ABSOLUTE:
            return self._session.history_absolute(int(token.text))
        if token.kind == TokenKind.LPAREN:
            value = self._parse_additive()
            self._expect(TokenKind.RPAREN)
            return value
        raise CalculatorSyntaxError(
            f"expected a number, variable, history reference, or '(' at column {token.position + 1}"
        )

    def _parse_function_call(self, name_token: Token) -> CalculatorValue:
        self._expect(TokenKind.LBRACKET)
        if name_token.text == "Floor":
            return self._parse_floor_call(name_token)
        if name_token.text not in {"N", "SetPrecision"}:
            raise CalculatorSyntaxError(
                f"unsupported function {name_token.text!r} at column {name_token.position + 1}"
            )
        value = self._parse_additive()
        self._expect(TokenKind.COMMA)
        precision_value = self._parse_additive()
        self._expect(TokenKind.RBRACKET)
        precision = _precision_from_value(precision_value)
        return value.with_precision(precision)

    def _parse_floor_call(self, name_token: Token) -> CalculatorValue:
        argument_tokens = self._collect_function_argument_tokens(name_token)
        value = _Parser(argument_tokens, self._session).parse()
        value._ensure_numeric()
        if value.perturbation is not None:
            return _floor_perturbation_report_value(
                value.perturbation,
                decimal_digits=max(value.precision, 100),
                default_precision=self._session.default_precision,
            )
        if value.exact_fraction is None:
            raise ValueError("Floor is only certified for exact rational values")
        numerator = value.exact_fraction.numerator
        denominator = value.exact_fraction.denominator
        return CalculatorValue.from_fraction(
            Fraction(numerator // denominator, 1),
            precision=value.precision,
        )

    def _collect_function_argument_tokens(self, name_token: Token) -> list[Token]:
        start = self._position
        parenthesis_depth = 0
        bracket_depth = 0
        while True:
            token = self._peek()
            if token.kind == TokenKind.EOF:
                raise CalculatorSyntaxError(
                    f"missing ']' for function {name_token.text!r} at column {name_token.position + 1}"
                )
            if token.kind == TokenKind.LPAREN:
                parenthesis_depth += 1
            elif token.kind == TokenKind.RPAREN:
                parenthesis_depth -= 1
                if parenthesis_depth < 0:
                    raise CalculatorSyntaxError(
                        f"unmatched ')' at column {token.position + 1}"
                    )
            elif token.kind == TokenKind.LBRACKET:
                bracket_depth += 1
            elif token.kind == TokenKind.RBRACKET:
                if parenthesis_depth == 0 and bracket_depth == 0:
                    argument_tokens = self._tokens[start : self._position]
                    self._advance()
                    if not argument_tokens:
                        raise CalculatorSyntaxError(
                            f"function {name_token.text!r} expects an argument"
                        )
                    return [
                        *argument_tokens,
                        Token(TokenKind.EOF, "", token.position),
                    ]
                bracket_depth -= 1
            self._advance()

    def _peek(self) -> Token:
        return self._tokens[self._position]

    def _advance(self) -> Token:
        token = self._peek()
        self._position += 1
        return token

    def _expect(self, kind: TokenKind) -> Token:
        token = self._advance()
        if token.kind != kind:
            expected = kind.value
            actual = token.text or token.kind.value
            raise CalculatorSyntaxError(
                f"expected {expected!r} at column {token.position + 1}, got {actual!r}"
            )
        return token


def _validate_precision(precision: int) -> int:
    precision = int(precision)
    if precision <= 0:
        raise ValueError("precision must be a positive integer")
    return precision


def _value_from_number_token(token: Token, default_precision: int) -> CalculatorValue:
    decimal_text, explicit_precision = _split_number_text(token.text, token.position)
    precision = explicit_precision or default_precision
    fraction = Fraction(decimal_text)
    return CalculatorValue.from_fraction(fraction, precision=precision)


def _split_number_text(text: str, position: int) -> tuple[str, int | None]:
    precision: int | None = None
    if "`" in text:
        mantissa, rest = text.split("`", 1)
        exponent = ""
        if "*^" in rest:
            precision_text, exponent = rest.split("*^", 1)
            exponent = "E" + exponent
        elif "e" in rest or "E" in rest:
            marker = "e" if "e" in rest else "E"
            precision_text, exponent = rest.split(marker, 1)
            exponent = "E" + exponent
        else:
            precision_text = rest
        if precision_text:
            try:
                precision = _validate_precision(int(precision_text))
            except ValueError as exc:
                raise CalculatorSyntaxError(
                    f"invalid precision at column {position + 1}"
                ) from exc
        else:
            precision = _literal_significant_digits(mantissa)
        return mantissa + exponent, precision
    return text.replace("*^", "E"), None


def _literal_significant_digits(text: str) -> int:
    digits = [ch for ch in text if ch.isdigit()]
    while digits and digits[0] == "0":
        digits.pop(0)
    return max(1, len(digits))


def _precision_from_value(value: CalculatorValue) -> int:
    value._ensure_numeric()
    if value.exact_fraction is None or value.exact_fraction.denominator != 1:
        raise CalculatorSyntaxError("precision must be an integer")
    return _validate_precision(value.exact_fraction.numerator)


def _format_perturbation_value(
    state: TowerPerturbationState,
    precision: int,
) -> str:
    if state.levels == 0:
        return f"10^-{state.epsilon_exponent}`Infinity"
    perturbation = _calculate_perturbation(state, decimal_digits=max(precision, 100))
    correction = _format_decimal_significant(perturbation.coefficient, precision)
    return (
        f"{perturbation.anchor} + {correction}\n"
        f"correction precision: {precision}\n"
        f"omitted tail < 10^{perturbation.omitted_tail_log10_upper_bound}"
    )


def _floor_perturbation_report_value(
    state: TowerPerturbationState,
    *,
    decimal_digits: int,
    default_precision: int,
) -> CalculatorValue:
    if state.levels == 0:
        return CalculatorValue.from_fraction(Fraction(0), precision=default_precision)
    perturbation = _calculate_perturbation(state, decimal_digits=decimal_digits)
    integer_part = perturbation.anchor + SparseDecimalInteger.from_int(
        perturbation.coefficient_floor
    )
    stable_floor = _perturbation_floor_is_stable(perturbation)
    report = (
        f"{integer_part}\n"
        "precision: Infinity (exact sparse integer part)\n"
        f"stable floor: {stable_floor}\n"
        f"decimal shape: {integer_part.leading_description()}\n"
        f"digits: {integer_part.digit_count}\n"
        f"first-order correction: {perturbation.coefficient}`{decimal_digits}\n"
        f"omitted tail < 10^{perturbation.omitted_tail_log10_upper_bound}"
    )
    return CalculatorValue.from_display(report, precision=default_precision)


def _calculate_perturbation(
    state: TowerPerturbationState,
    *,
    decimal_digits: int,
):
    context = NummyContext(decimal_digits=decimal_digits, guard_digits=30)
    return first_order_tower_perturbation(
        base=state.base,
        epsilon_exponent=state.epsilon_exponent,
        levels=state.levels,
        context=context,
    )


def _perturbation_floor_is_stable(perturbation) -> bool:
    margin = min(
        perturbation.fractional_part,
        Decimal(1) - perturbation.fractional_part,
    )
    return margin > Decimal("1e-20") and perturbation.omitted_tail_log10_upper_bound < -20


def _tower_from_fraction(value: Fraction, *, precision: int) -> TowerReal:
    if value == 0:
        return TowerReal.zero()
    context = NummyContext(decimal_digits=max(precision, DEFAULT_CALCULATOR_PRECISION))
    with localcontext(context.decimal_context()):
        decimal = Decimal(value.numerator) / Decimal(value.denominator)
    return TowerReal.from_decimal(decimal, context=context)


def _fraction_from_tower(value: TowerReal) -> Fraction | None:
    if value.layer != 0:
        return None
    return Fraction(str(value.to_decimal()))


def _estimate_integer_power_digits(base: Fraction, exponent: int) -> int:
    if exponent == 0:
        return 1
    digit_factor = max(
        len(str(abs(base.numerator))),
        len(str(base.denominator)),
    )
    return max(1, digit_factor * abs(exponent))


def _is_power_exact(
    base: CalculatorValue,
    exponent: int,
    tower: TowerReal,
) -> bool:
    del tower
    if not base.certified or base.exact_fraction is None:
        return False
    if exponent == 0:
        return True
    return base.exact_fraction in {Fraction(10, 1), Fraction(1, 10)}


def _format_tower(value: TowerReal) -> str:
    if value.layer == 0:
        return _format_decimal(value.to_decimal())
    return str(value)


def _format_fraction(value: Fraction, precision: int) -> str:
    precision = _validate_precision(precision)
    if value == 0:
        zeros = "0" * max(0, precision - 1)
        body = "0" if precision == 1 else f"0.{zeros}"
        return f"{body}`{precision}"

    sign = "-" if value < 0 else ""
    magnitude = abs(value)
    exponent = _floor_log10_fraction(magnitude)
    scale = precision - 1 - exponent
    rounded = _round_fraction_to_integer(magnitude, scale)
    if rounded >= 10**precision:
        rounded //= 10
        exponent += 1
    digits = str(rounded).zfill(precision)
    return f"{sign}{_place_decimal_point(digits, exponent)}`{precision}"


def _format_decimal_significant(value: Decimal, precision: int) -> str:
    return _format_fraction(Fraction(str(value)), precision)


def _floor_log10_fraction(value: Fraction) -> int:
    numerator = value.numerator
    denominator = value.denominator
    exponent = len(str(numerator)) - len(str(denominator))
    if exponent >= 0:
        if numerator < denominator * (10**exponent):
            exponent -= 1
    elif numerator * (10 ** (-exponent)) < denominator:
        exponent -= 1
    return exponent


def _round_fraction_to_integer(value: Fraction, scale: int) -> int:
    if scale >= 0:
        numerator = value.numerator * (10**scale)
        denominator = value.denominator
    else:
        numerator = value.numerator
        denominator = value.denominator * (10 ** (-scale))
    quotient, remainder = divmod(numerator, denominator)
    doubled = remainder * 2
    if doubled > denominator or (doubled == denominator and quotient % 2):
        quotient += 1
    return quotient


def _place_decimal_point(digits: str, exponent: int) -> str:
    decimal_position = exponent + 1
    if decimal_position >= len(digits):
        return digits + ("0" * (decimal_position - len(digits)))
    if decimal_position > 0:
        return f"{digits[:decimal_position]}.{digits[decimal_position:]}"
    return "0." + ("0" * (-decimal_position)) + digits
