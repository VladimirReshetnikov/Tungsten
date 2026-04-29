from __future__ import annotations

import sys
from dataclasses import dataclass
from decimal import Decimal, DivisionByZero, InvalidOperation, localcontext
from typing import Dict, List, Optional, Sequence, TextIO, Tuple

from nummy_tower import Pow10Tower, TowerLandmarkDecimal, compute_pow10_tower_small_bottom_linear


class GammaReplError(Exception):
    pass


class GammaSyntaxError(GammaReplError):
    pass


class GammaEvaluationError(GammaReplError):
    pass


def _d_from_number_token(token: str) -> Decimal:
    # We only accept decimal / integer literals; no exponent notation for now.
    # (This keeps the parser extremely small and deterministic.)
    return Decimal(token)


def _format_decimal(x: Decimal) -> str:
    if x.is_nan() or x.is_infinite():
        return str(x)
    if x == 0:
        return "0"
    # For a REPL, prefer a round-trip-safe decimal form:
    # - no scientific/engineering notation (we do not parse it on input),
    # - strip insignificant trailing zeros after the decimal point.
    text = format(x, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    if text == "-0":
        return "0"
    return text


def _format_pow10_tower(t: Pow10Tower) -> str:
    # Display using the REPL's own operator conventions:
    # - '^' is right-associative and binds tightly.
    # - Avoid `^^` which reads as "base^^digits" to Wolfram users.
    height = t.height
    top = t.top

    # Avoid trailing `...^1` when possible:
    #   10^(10^(10^1)) == 10^(10^10) and renders more naturally as `10^10^10`.
    try:
        while height > 1 and _is_effectively_integer(top) and int(top) == 1:
            height -= 1
            top = Decimal(10)
    except (InvalidOperation, ValueError):
        pass

    if height == 0:
        return _format_decimal(top)

    top_text = _format_decimal(top)
    parts = ["10"]
    parts.extend(["10"] * (height - 1))
    parts.append(top_text)
    return "^".join(parts)


def _format_out_value(v: GammaValue) -> str:
    return v.format_short()


@dataclass(frozen=True, slots=True)
class GammaValue:
    """
    Minimal numeric domain for the gamma REPL:

    - ordinary Decimal values (default)
    - a tower landmark + finite tail (for the MathOverflow-style regime)

    This is intentionally small: it exists to make the MO computation available
    while keeping the REPL syntax limited to arithmetic expressions.
    """

    scalar: Optional[Decimal] = None
    pow10_tower: Optional[Pow10Tower] = None
    landmark: Optional[TowerLandmarkDecimal] = None

    @staticmethod
    def from_decimal(x: Decimal) -> GammaValue:
        return GammaValue(scalar=x, pow10_tower=None, landmark=None)

    @staticmethod
    def from_pow10_tower(x: Pow10Tower) -> GammaValue:
        return GammaValue(scalar=None, pow10_tower=x, landmark=None)

    @staticmethod
    def from_landmark(x: TowerLandmarkDecimal) -> GammaValue:
        return GammaValue(scalar=None, pow10_tower=None, landmark=x)

    @property
    def is_scalar(self) -> bool:
        return self.scalar is not None

    @property
    def is_pow10_tower(self) -> bool:
        return self.pow10_tower is not None

    @property
    def is_landmark(self) -> bool:
        return self.landmark is not None

    def as_decimal(self) -> Decimal:
        if self.scalar is None:
            raise GammaEvaluationError("Value is not a finite Decimal scalar.")
        return self.scalar

    def format_short(self) -> str:
        if self.scalar is not None:
            return _format_decimal(self.scalar)
        if self.pow10_tower is not None:
            return _format_pow10_tower(self.pow10_tower)
        if self.landmark is not None:
            desc = self.landmark.describe_decimal(frac_digits=10, max_exponent_digits=64)
            landmark_text = _format_pow10_tower(self.landmark.landmark)
            return f"{landmark_text} + {desc.tail_string}"
        return "0"


def _is_effectively_integer(v: Decimal) -> bool:
    try:
        return v == v.to_integral_exact()
    except (InvalidOperation, ValueError):
        return False


def _value_add(a: GammaValue, b: GammaValue, *, prec: int) -> GammaValue:
    if a.is_scalar and b.is_scalar:
        with localcontext(prec=prec):
            return GammaValue.from_decimal(a.as_decimal() + b.as_decimal())
    raise GammaEvaluationError("Addition is only implemented for finite Decimal scalars.")


def _value_sub(a: GammaValue, b: GammaValue, *, prec: int) -> GammaValue:
    if a.is_scalar and b.is_scalar:
        with localcontext(prec=prec):
            return GammaValue.from_decimal(a.as_decimal() - b.as_decimal())
    raise GammaEvaluationError("Subtraction is only implemented for finite Decimal scalars.")


def _value_mul(a: GammaValue, b: GammaValue, *, prec: int) -> GammaValue:
    if a.is_scalar and b.is_scalar:
        with localcontext(prec=prec):
            return GammaValue.from_decimal(a.as_decimal() * b.as_decimal())
    raise GammaEvaluationError("Multiplication is only implemented for finite Decimal scalars.")


def _value_div(a: GammaValue, b: GammaValue, *, prec: int) -> GammaValue:
    if a.is_scalar and b.is_scalar:
        with localcontext(prec=prec):
            try:
                return GammaValue.from_decimal(a.as_decimal() / b.as_decimal())
            except DivisionByZero:
                raise GammaEvaluationError("Division by zero.")
    raise GammaEvaluationError("Division is only implemented for finite Decimal scalars.")


def _value_pow(a: GammaValue, b: GammaValue, *, prec: int) -> GammaValue:
    """
    Exponentiation operator '^'.

    Two regimes:
    - Scalar ^ Scalar: evaluated as Decimal power where possible.
    - 10 ^ TowerLandmarkDecimal: not supported.

    Special-case for the MathOverflow pattern:

      10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10^10)))))

    This is recognized structurally when the evaluator builds the exact base-10
    power tower:

      10^^5(-10^10)

    and routes it to the tower perturbation evaluator to recover the
    landmark+tail decomposition discussed in `docs/how-to-calculate-1010101010-1010/`.

    The REPL supports building this expression with '^' and parentheses. When
    the evaluator detects that it is about to compute 10^(10^(10^(10^(10^x))))
    for an astronomically small x=10^bottom_exponent, it routes to the tower
    evaluator and returns a tower value.
    """

    if a.is_scalar and b.is_scalar:
        with localcontext(prec=prec):
            base = a.as_decimal()
            exp = b.as_decimal()

            # Prefer structural representation for 10^x when x is far outside Decimal's default exponent range.
            if base == 10:
                if _is_effectively_integer(exp):
                    exp_int = int(exp)
                    # Decimal default Emax is 999999; beyond that we'd overflow/underflow.
                    if abs(exp_int) > 999_999:
                        return GammaValue.from_pow10_tower(Pow10Tower(1, Decimal(exp_int)))
                    return GammaValue.from_decimal(Decimal(10) ** exp_int)

                # 10^exp for non-integer exp: keep it scalar when reasonable; otherwise keep it structural.
                # (Pow10Tower(height=1, top=exp) is exactly 10^exp.)
                if abs(exp) > Decimal(999_999):
                    return GammaValue.from_pow10_tower(Pow10Tower(1, exp))
                return GammaValue.from_decimal((exp * Decimal(10).ln()).exp())

            # General scalar power:
            if _is_effectively_integer(exp):
                return GammaValue.from_decimal(base ** int(exp))

            if base <= 0:
                raise GammaEvaluationError("Non-integer exponent requires a positive base.")
            return GammaValue.from_decimal((exp * base.ln()).exp())

    # Structural tower building: 10^(10^^h(t)) == 10^^(h+1)(t)
    if a.is_scalar and a.as_decimal() == 10 and b.is_pow10_tower:
        t = b.pow10_tower
        assert t is not None
        next_t = Pow10Tower(t.height + 1, t.top)
        # If we hit the exact MathOverflow motivating case, compute it into landmark+tail.
        if next_t.height == 5 and _is_effectively_integer(next_t.top) and int(next_t.top) == -(10**10):
            mo = compute_pow10_tower_small_bottom_linear(
                height=5,
                bottom_exponent=-(10**10),
                precision=prec,
                max_tower_int_digits=64,
            )
            return GammaValue.from_landmark(mo)
        return GammaValue.from_pow10_tower(next_t)

    raise GammaEvaluationError("Exponentiation is only implemented for scalars and base-10 towers.")


Token = Tuple[str, str]  # (kind, text)


def _tokenize(text: str) -> List[Token]:
    tokens: List[Token] = []
    i = 0
    n = len(text)

    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
            continue

        if ch.isdigit() or ch == ".":
            start = i
            saw_dot = ch == "."
            saw_digit = ch.isdigit()
            i += 1
            while i < n:
                c = text[i]
                if c.isdigit():
                    saw_digit = True
                    i += 1
                    continue
                if c == "." and not saw_dot:
                    saw_dot = True
                    i += 1
                    continue
                break
            if not saw_digit:
                raise GammaSyntaxError("Malformed numeric literal.")
            tokens.append(("number", text[start:i]))
            continue

        if ch.isalpha() or ch == "_":
            start = i
            i += 1
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            tokens.append(("ident", text[start:i]))
            continue

        if ch == "%":
            start = i
            while i < n and text[i] == "%":
                i += 1
            percent_count = i - start
            if percent_count == 1:
                while i < n and text[i].isdigit():
                    i += 1
            tokens.append(("history", text[start:i]))
            continue

        if ch in "+-*/^()=":
            tokens.append(("op", ch))
            i += 1
            continue

        raise GammaSyntaxError(f"Unexpected character: {ch!r}")

    return tokens


class _Parser:
    def __init__(self, tokens: Sequence[Token]) -> None:
        self.tokens = list(tokens)
        self.pos = 0

    def _peek(self) -> Optional[Token]:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def _eat(self, expected: Optional[Tuple[str, str]] = None) -> Token:
        tok = self._peek()
        if tok is None:
            raise GammaSyntaxError("Unexpected end of input.")
        if expected is not None and tok != expected:
            raise GammaSyntaxError(f"Expected {expected}, got {tok}.")
        self.pos += 1
        return tok

    def parse_stmt(self) -> Tuple[Optional[str], "Expr"]:
        # assignment := ident '=' expr
        # otherwise: expr
        tok = self._peek()
        if tok is not None and tok[0] == "ident":
            # Lookahead for '='
            if self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1] == ("op", "="):
                name = self._eat()[1]
                self._eat(("op", "="))
                expr = self.parse_expr()
                if self._peek() is not None:
                    raise GammaSyntaxError("Unexpected token after expression.")
                return name, expr
        expr = self.parse_expr()
        if self._peek() is not None:
            raise GammaSyntaxError("Unexpected token after expression.")
        return None, expr

    def parse_expr(self) -> "Expr":
        return self._parse_add_sub()

    def _parse_add_sub(self) -> "Expr":
        node = self._parse_mul_div()
        while True:
            tok = self._peek()
            if tok in (("op", "+"), ("op", "-")):
                op = self._eat()[1]
                rhs = self._parse_mul_div()
                node = BinOp(op, node, rhs)
                continue
            return node

    def _parse_mul_div(self) -> "Expr":
        node = self._parse_unary()
        while True:
            tok = self._peek()
            if tok in (("op", "*"), ("op", "/")):
                op = self._eat()[1]
                rhs = self._parse_unary()
                node = BinOp(op, node, rhs)
                continue
            return node

    def _parse_unary(self) -> "Expr":
        tok = self._peek()
        if tok in (("op", "+"), ("op", "-")):
            op = self._eat()[1]
            inner = self._parse_unary()
            return UnaryOp(op, inner)
        return self._parse_pow()

    def _parse_pow(self) -> "Expr":
        # Right associative
        node = self._parse_primary()
        tok = self._peek()
        if tok == ("op", "^"):
            self._eat(("op", "^"))
            rhs = self._parse_unary()
            return BinOp("^", node, rhs)
        return node

    def _parse_primary(self) -> "Expr":
        tok = self._peek()
        if tok is None:
            raise GammaSyntaxError("Unexpected end of input.")

        if tok == ("op", "("):
            self._eat(("op", "("))
            inner = self.parse_expr()
            self._eat(("op", ")"))
            return inner

        if tok[0] == "number":
            self._eat()
            return NumberLit(tok[1])

        if tok[0] == "ident":
            self._eat()
            return Ident(tok[1])

        if tok[0] == "history":
            self._eat()
            return HistoryRef(tok[1])

        raise GammaSyntaxError(f"Unexpected token: {tok!r}")


class Expr:
    def eval(self, env: "GammaEnv") -> GammaValue:
        raise NotImplementedError


@dataclass(frozen=True, slots=True)
class NumberLit(Expr):
    text: str

    def eval(self, env: "GammaEnv") -> GammaValue:
        with localcontext(prec=env.precision):
            return GammaValue.from_decimal(_d_from_number_token(self.text))


@dataclass(frozen=True, slots=True)
class Ident(Expr):
    name: str

    def eval(self, env: "GammaEnv") -> GammaValue:
        return env.vars.get(self.name, GammaValue.from_decimal(Decimal(0)))


@dataclass(frozen=True, slots=True)
class HistoryRef(Expr):
    text: str

    def eval(self, env: "GammaEnv") -> GammaValue:
        if set(self.text) == {"%"}:
            return env.out_relative(len(self.text))
        if self.text.startswith("%") and self.text[1:].isdigit():
            n = int(self.text[1:])
            return env.out_absolute(n)
        raise GammaSyntaxError(f"Invalid history reference: {self.text!r}")


@dataclass(frozen=True, slots=True)
class UnaryOp(Expr):
    op: str
    inner: Expr

    def eval(self, env: "GammaEnv") -> GammaValue:
        v = self.inner.eval(env)
        if not v.is_scalar:
            raise GammaEvaluationError("Unary +/- only implemented for finite Decimal scalars.")
        with localcontext(prec=env.precision):
            d = v.as_decimal()
            return GammaValue.from_decimal(+d if self.op == "+" else -d)


@dataclass(frozen=True, slots=True)
class BinOp(Expr):
    op: str
    left: Expr
    right: Expr

    def eval(self, env: "GammaEnv") -> GammaValue:
        a = self.left.eval(env)
        b = self.right.eval(env)
        if self.op == "+":
            return _value_add(a, b, prec=env.precision)
        if self.op == "-":
            return _value_sub(a, b, prec=env.precision)
        if self.op == "*":
            return _value_mul(a, b, prec=env.precision)
        if self.op == "/":
            return _value_div(a, b, prec=env.precision)
        if self.op == "^":
            return _value_pow(a, b, prec=env.precision)
        raise GammaEvaluationError(f"Unsupported operator: {self.op!r}")


class GammaEnv:
    def __init__(self, *, precision: int = 80) -> None:
        self.precision = precision
        self.vars: Dict[str, GammaValue] = {}
        self._outs: List[GammaValue] = []  # 1-based Out[n]

    @property
    def line(self) -> int:
        return len(self._outs) + 1

    def push_out(self, value: GammaValue) -> None:
        self._outs.append(value)

    def out_relative(self, k: int) -> GammaValue:
        if k <= 0:
            raise GammaEvaluationError("History index must be positive.")
        idx = len(self._outs) - k
        if idx < 0:
            return GammaValue.from_decimal(Decimal(0))
        return self._outs[idx]

    def out_absolute(self, n: int) -> GammaValue:
        if n <= 0:
            return GammaValue.from_decimal(Decimal(0))
        idx = n - 1
        if idx < 0 or idx >= len(self._outs):
            return GammaValue.from_decimal(Decimal(0))
        return self._outs[idx]


def eval_line(env: GammaEnv, text: str) -> GammaValue:
    tokens = _tokenize(text)
    parser = _Parser(tokens)
    assign_to, expr = parser.parse_stmt()
    value = expr.eval(env)
    if assign_to is not None:
        env.vars[assign_to] = value
    return value


def _banner() -> str:
    return "Nummy Gamma Calculator (tower-scale prototype)\n"


def run_repl(
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    precision: int = 80,
    show_banner: bool = True,
) -> int:
    input_stream = stdin or sys.stdin
    output_stream = stdout or sys.stdout
    error_stream = stderr or sys.stderr

    env = GammaEnv(precision=precision)

    if show_banner:
        output_stream.write(_banner())
        output_stream.write("\n")
        output_stream.flush()

    while True:
        line_no = env.line
        output_stream.write(f"In[{line_no}]:= ")
        output_stream.flush()

        source = input_stream.readline()
        if source == "":
            output_stream.write("\n")
            output_stream.flush()
            return 0

        text = source.rstrip("\r\n")
        if not text.strip():
            output_stream.write("\n")
            output_stream.flush()
            continue
        if text.strip().lower() in ("quit", "quit()", "exit", "exit()"):
            output_stream.write("\n")
            output_stream.flush()
            return 0

        try:
            value = eval_line(env, text)
        except GammaSyntaxError as ex:
            error_stream.write(f"Syntax::sntxi: {ex}\n\n")
            error_stream.flush()
            env.push_out(GammaValue.from_decimal(Decimal(0)))
            continue
        except GammaEvaluationError as ex:
            error_stream.write(f"Evaluate::error: {ex}\n\n")
            error_stream.flush()
            env.push_out(GammaValue.from_decimal(Decimal(0)))
            continue
        except (DivisionByZero, InvalidOperation, ValueError) as ex:
            error_stream.write(f"Evaluate::error: {ex}\n\n")
            error_stream.flush()
            env.push_out(GammaValue.from_decimal(Decimal(0)))
            continue

        env.push_out(value)
        output_stream.write(f"\nOut[{line_no}]= {_format_out_value(value)}\n\n")
        output_stream.flush()


def repl(argv: Sequence[str]) -> int:
    precision = 80
    show_banner = True
    for arg in argv[1:]:
        if arg.startswith("--prec="):
            precision = int(arg.split("=", 1)[1])
        elif arg == "--no-banner":
            show_banner = False
    return run_repl(precision=precision, show_banner=show_banner)


def main() -> None:
    raise SystemExit(repl(sys.argv))


if __name__ == "__main__":
    main()
