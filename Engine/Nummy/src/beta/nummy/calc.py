"""Lexer, parser, and evaluator for the Nummy REPL calculator.

Grammar:

    input       = IDENT '=' expression | expression
    expression  = term (('+' | '-') term)*
    term        = unary (('*' | '/') unary)*
    unary       = ('-' | '+') unary | factor
    factor      = atom ('^' unary)?
    atom        = NUMBER | IDENT | HISTORY | '(' expression ')'
    NUMBER      = digits ('.' digits)? ([eE] [+-]? digits)? ('`' digits)?
    HISTORY     = '%'+ | '%' DIGITS

Numeric literals follow Mathematica conventions for precision:

* ``5`` -- exact integer (precision is treated as infinite).
* ``5.0`` -- floating-point literal at the *session* precision (which
  defaults to 16, "machine").
* ``5.0`30`` -- floating-point literal at 30 decimal digits of precision.

Operations propagate precision: the result's precision is the minimum of
the operand precisions, with ``EXACT`` integer values acting as
"infinite" precision (they do not pull the result down).  When two
exact integers combine via an operation that yields a non-integer
result (e.g., ``5 / 3``), the result's precision falls back to the
session precision.

The session precision is configurable via the magic identifier
``Precision``: ``Precision = 50`` sets the working precision.
``MachinePrecision`` is a read-only constant (always 16); display
omits the ``\\`prec`` suffix when the result's precision equals it.

Internal computation runs at ``claimed_precision + GUARD_DIGITS`` so
the displayed digits are correct up to the documented cascading-tail
caveat.
"""

from __future__ import annotations

import dataclasses
import enum
import sys
from typing import List, Optional, Union

from mpmath import mp, mpf, log10 as mp_log10, nstr

from .tower import PowerTower


#: Sentinel precision value for exact integers (treated as "infinite"
#: precision -- it never drags the result of an operation down).
EXACT: int = sys.maxsize

#: Fixed "machine precision" threshold.  Output omits the precision
#: suffix when the value's precision equals this.
MACHINE_PRECISION: int = 16

#: Extra working precision used during evaluation, on top of the
#: claimed precision of the result.  Ten digits is comfortably enough
#: to keep ordinary arithmetic correct up to the cascading-tail caveat;
#: heavy cancellation can still defeat it.
GUARD_DIGITS: int = 10


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------


class TokenType(enum.Enum):
    NUMBER = "NUMBER"
    IDENT = "IDENT"
    PERCENT = "PERCENT"
    PERCENT_NUM = "PERCENT_NUM"
    ASSIGN = "ASSIGN"
    PLUS = "PLUS"
    MINUS = "MINUS"
    STAR = "STAR"
    SLASH = "SLASH"
    CARET = "CARET"
    LPAREN = "LPAREN"
    RPAREN = "RPAREN"
    LBRACKET = "LBRACKET"
    RBRACKET = "RBRACKET"
    COMMA = "COMMA"
    EOF = "EOF"


@dataclasses.dataclass(frozen=True)
class Token:
    type: TokenType
    text: str
    column: int


class CalcSyntaxError(Exception):
    """Raised by the lexer or parser on malformed input."""


def _consume_digits(source: str, i: int) -> int:
    n = len(source)
    while i < n and source[i].isdigit():
        i += 1
    return i


def _consume_number(source: str, start: int) -> int:
    """Return the index just past a number literal beginning at ``start``.

    Recognises ``digits``, ``digits.digits``, ``.digits``, optional
    ``[eE][+-]?digits`` exponent, and a trailing ``\\`prec`` precision
    suffix (which is itself a non-negative integer).
    """
    n = len(source)
    i = start
    seen_dot = source[i] == "."
    if seen_dot:
        i += 1
        i = _consume_digits(source, i)
    else:
        i = _consume_digits(source, i)
        if i < n and source[i] == "." and (i + 1 >= n or source[i + 1].isdigit()):
            i += 1
            seen_dot = True
            i = _consume_digits(source, i)
    if i < n and source[i] in "eE":
        i += 1
        if i < n and source[i] in "+-":
            i += 1
        i = _consume_digits(source, i)
    if i < n and source[i] == "`":
        # Precision suffix.  Require at least one digit after the backtick.
        i += 1
        prec_start = i
        i = _consume_digits(source, i)
        if i == prec_start:
            raise CalcSyntaxError(
                f"expected precision digits after backtick at column {prec_start + 1}"
            )
    return i


def tokenize(source: str) -> List[Token]:
    """Convert ``source`` into a list of tokens ending with ``EOF``."""
    tokens: List[Token] = []
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        if c.isspace():
            i += 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and source[i + 1].isdigit()):
            start = i
            i = _consume_number(source, i)
            tokens.append(Token(TokenType.NUMBER, source[start:i], start))
            continue
        if c.isalpha() or c == "_":
            start = i
            while i < n and (source[i].isalnum() or source[i] == "_"):
                i += 1
            tokens.append(Token(TokenType.IDENT, source[start:i], start))
            continue
        if c == "%":
            start = i
            i += 1
            if i < n and source[i].isdigit():
                while i < n and source[i].isdigit():
                    i += 1
                tokens.append(Token(TokenType.PERCENT_NUM, source[start:i], start))
                continue
            while i < n and source[i] == "%":
                i += 1
            tokens.append(Token(TokenType.PERCENT, source[start:i], start))
            continue
        single = {
            "=": TokenType.ASSIGN,
            "+": TokenType.PLUS,
            "-": TokenType.MINUS,
            "*": TokenType.STAR,
            "/": TokenType.SLASH,
            "^": TokenType.CARET,
            "(": TokenType.LPAREN,
            ")": TokenType.RPAREN,
            "[": TokenType.LBRACKET,
            "]": TokenType.RBRACKET,
            ",": TokenType.COMMA,
        }
        kind = single.get(c)
        if kind is None:
            raise CalcSyntaxError(f"unexpected character {c!r} at column {i + 1}")
        tokens.append(Token(kind, c, i))
        i += 1
    tokens.append(Token(TokenType.EOF, "", n))
    return tokens


# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class NumberLiteral:
    """Numeric literal with deferred mpmath conversion.

    * ``mantissa_text`` is the source text up to (but not including) any
      ``\\`prec`` suffix -- e.g. ``"1.5"`` or ``"3"``.
    * ``explicit_precision`` is the precision that followed the backtick,
      or ``None`` if the literal had no backtick.
    * ``is_integer`` is ``True`` for literals with no decimal point or
      exponent, signalling "exact integer" when no precision suffix is
      present.
    """

    mantissa_text: str
    explicit_precision: Optional[int]
    is_integer: bool


@dataclasses.dataclass(frozen=True)
class VariableRef:
    name: str


@dataclasses.dataclass(frozen=True)
class HistoryRef:
    """Reference to a previous result.

    Exactly one of ``depth`` or ``line`` is set:

    * ``depth = k`` (for ``%`` repeated *k* times) names the *k*-th most
      recent result.
    * ``line = n`` (for ``%n``) names the result of line *n* (1-based).
    """

    depth: Optional[int] = None
    line: Optional[int] = None


@dataclasses.dataclass(frozen=True)
class UnaryOp:
    op: str
    operand: object


@dataclasses.dataclass(frozen=True)
class BinaryOp:
    op: str
    left: object
    right: object


@dataclasses.dataclass(frozen=True)
class Assignment:
    name: str
    expr: object


@dataclasses.dataclass(frozen=True)
class FunctionCall:
    """Mathematica-style function call ``Name[arg1, arg2, ...]``."""

    name: str
    args: tuple


Node = Union[
    NumberLiteral,
    VariableRef,
    HistoryRef,
    UnaryOp,
    BinaryOp,
    Assignment,
    FunctionCall,
]


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


def _split_number_literal(text: str) -> tuple[str, Optional[int], bool]:
    """Split a NUMBER token into ``(mantissa_text, precision, is_integer)``."""
    if "`" in text:
        mantissa, prec_text = text.split("`", 1)
        try:
            precision = int(prec_text)
        except ValueError as exc:
            raise CalcSyntaxError(f"invalid precision {prec_text!r}") from exc
        if precision <= 0:
            raise CalcSyntaxError(
                f"precision must be a positive integer (got {precision})"
            )
    else:
        mantissa = text
        precision = None
    is_integer = "." not in mantissa and "e" not in mantissa.lower()
    return mantissa, precision, is_integer


class Parser:
    """Recursive-descent parser for the calculator grammar."""

    def __init__(self, tokens: List[Token]) -> None:
        self.tokens = tokens
        self.pos = 0

    def peek(self) -> Token:
        return self.tokens[self.pos]

    def lookahead(self, offset: int) -> Token:
        idx = self.pos + offset
        if idx < len(self.tokens):
            return self.tokens[idx]
        return self.tokens[-1]

    def advance(self) -> Token:
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def expect(self, kind: TokenType) -> Token:
        token = self.advance()
        if token.type != kind:
            raise CalcSyntaxError(
                f"expected {kind.name} but found {token.type.name} "
                f"({token.text!r}) at column {token.column + 1}"
            )
        return token

    def parse(self) -> Node:
        if (
            self.peek().type == TokenType.IDENT
            and self.lookahead(1).type == TokenType.ASSIGN
        ):
            ident = self.advance()
            self.advance()
            expr = self.parse_expression()
            self.expect(TokenType.EOF)
            return Assignment(ident.text, expr)
        node = self.parse_expression()
        self.expect(TokenType.EOF)
        return node

    def parse_expression(self) -> Node:
        node = self.parse_term()
        while self.peek().type in (TokenType.PLUS, TokenType.MINUS):
            op = self.advance().text
            right = self.parse_term()
            node = BinaryOp(op, node, right)
        return node

    def parse_term(self) -> Node:
        node = self.parse_unary()
        while self.peek().type in (TokenType.STAR, TokenType.SLASH):
            op = self.advance().text
            right = self.parse_unary()
            node = BinaryOp(op, node, right)
        return node

    def parse_unary(self) -> Node:
        if self.peek().type == TokenType.MINUS:
            self.advance()
            return UnaryOp("-", self.parse_unary())
        if self.peek().type == TokenType.PLUS:
            self.advance()
            return self.parse_unary()
        return self.parse_factor()

    def parse_factor(self) -> Node:
        atom = self.parse_atom()
        if self.peek().type == TokenType.CARET:
            self.advance()
            exponent = self.parse_unary()
            return BinaryOp("^", atom, exponent)
        return atom

    def parse_atom(self) -> Node:
        token = self.peek()
        if token.type == TokenType.NUMBER:
            self.advance()
            mantissa, precision, is_integer = _split_number_literal(token.text)
            return NumberLiteral(
                mantissa_text=mantissa,
                explicit_precision=precision,
                is_integer=is_integer,
            )
        if token.type == TokenType.IDENT:
            self.advance()
            if self.peek().type == TokenType.LBRACKET:
                return self._parse_function_call_tail(token.text)
            return VariableRef(token.text)
        if token.type == TokenType.PERCENT:
            self.advance()
            return HistoryRef(depth=len(token.text))
        if token.type == TokenType.PERCENT_NUM:
            self.advance()
            return HistoryRef(line=int(token.text[1:]))
        if token.type == TokenType.LPAREN:
            self.advance()
            inner = self.parse_expression()
            self.expect(TokenType.RPAREN)
            return inner
        raise CalcSyntaxError(
            f"unexpected token {token.text!r} at column {token.column + 1}"
        )

    def _parse_function_call_tail(self, name: str) -> Node:
        self.expect(TokenType.LBRACKET)
        args: List[Node] = []
        if self.peek().type != TokenType.RBRACKET:
            args.append(self.parse_expression())
            while self.peek().type == TokenType.COMMA:
                self.advance()
                args.append(self.parse_expression())
        self.expect(TokenType.RBRACKET)
        return FunctionCall(name=name, args=tuple(args))


def parse(source: str) -> Node:
    return Parser(tokenize(source)).parse()


# ---------------------------------------------------------------------------
# Precision-tracked values
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class PrecValue:
    """An ``mpf`` value paired with its claimed decimal-digit precision.

    ``precision == EXACT`` (i.e. ``sys.maxsize``) means the value is an
    exact integer; otherwise ``precision`` is the number of decimal
    digits of the value that are claimed correct (subject to the
    cascading 9-vs-0 tail caveat).
    """

    value: "mpf"
    precision: int

    @property
    def is_exact(self) -> bool:
        return self.precision == EXACT

    @property
    def is_integer_valued(self) -> bool:
        from mpmath import floor as mp_floor

        return self.value == mp_floor(self.value)


def _combine_precisions(a: int, b: int) -> int:
    if a == EXACT and b == EXACT:
        return EXACT
    if a == EXACT:
        return b
    if b == EXACT:
        return a
    return min(a, b)


# ---------------------------------------------------------------------------
# Evaluator
# ---------------------------------------------------------------------------


class CalcEvaluationError(Exception):
    """Raised on evaluation errors (division by zero, missing history, ...)."""


@dataclasses.dataclass
class CalcSession:
    """Mutable state shared across REPL inputs.

    ``history[i]`` is the result of evaluation line ``i + 1``.
    ``variables`` is a plain dict keyed by identifier; unassigned
    identifiers default to ``PrecValue(mpf(0), EXACT)`` at lookup time.
    ``precision`` is the session precision (default 16).  Assignment to
    the magic identifier ``Precision`` updates this attribute.
    ``messages`` is a list of textual side-effect outputs produced by
    builtins during evaluation; the REPL drains and displays them
    before printing ``Out[n]=``.
    """

    variables: dict
    history: List[PrecValue]
    precision: int
    messages: List[str]

    def __init__(self) -> None:
        self.variables = {}
        self.history = []
        self.precision = MACHINE_PRECISION
        self.messages = []

    @property
    def next_line(self) -> int:
        return len(self.history) + 1

    def take_messages(self) -> List[str]:
        """Return and clear the messages accumulated during the last
        evaluation."""
        out = list(self.messages)
        self.messages.clear()
        return out

    def lookup_history(self, ref: HistoryRef) -> PrecValue:
        if ref.depth is not None:
            depth = ref.depth
            if depth <= 0 or depth > len(self.history):
                raise CalcEvaluationError(
                    f"no history at depth {depth} "
                    f"(only {len(self.history)} previous result(s))"
                )
            return self.history[-depth]
        if ref.line is not None:
            line = ref.line
            if line < 1 or line > len(self.history):
                raise CalcEvaluationError(
                    f"no history for line {line} "
                    f"(only lines 1..{len(self.history)} are recorded)"
                )
            return self.history[line - 1]
        raise CalcEvaluationError("invalid history reference")


def _set_working_precision(target_precision: int) -> int:
    """Set ``mp.dps`` to ``target_precision + GUARD_DIGITS``; return prior dps."""
    prior = mp.dps
    mp.dps = max(target_precision + GUARD_DIGITS, MACHINE_PRECISION + GUARD_DIGITS)
    return prior


def _evaluate_number_literal(node: NumberLiteral, session: CalcSession) -> PrecValue:
    if node.is_integer and node.explicit_precision is None:
        # Exact integer.  mpmath represents it without precision loss.
        # Use a very high working precision so the integer-string round-trip
        # is unambiguous; the result is exact regardless.
        prior = mp.dps
        digits = max(len(node.mantissa_text), MACHINE_PRECISION)
        mp.dps = digits + GUARD_DIGITS
        try:
            value = mpf(node.mantissa_text)
        finally:
            mp.dps = prior
        return PrecValue(value=value, precision=EXACT)

    target_precision = node.explicit_precision
    if target_precision is None:
        target_precision = session.precision
    prior = _set_working_precision(target_precision)
    try:
        value = mpf(node.mantissa_text)
    finally:
        mp.dps = prior
    return PrecValue(value=value, precision=target_precision)


def _evaluate_variable(node: VariableRef, session: CalcSession) -> PrecValue:
    if node.name == "Precision":
        return PrecValue(value=mpf(session.precision), precision=EXACT)
    if node.name == "MachinePrecision":
        return PrecValue(value=mpf(MACHINE_PRECISION), precision=EXACT)
    return session.variables.get(node.name, PrecValue(value=mpf(0), precision=EXACT))


def _arith(op: str, lhs: PrecValue, rhs: PrecValue, session: CalcSession) -> PrecValue:
    target_precision = _combine_precisions(lhs.precision, rhs.precision)
    if target_precision == EXACT:
        working = session.precision
    else:
        working = target_precision
    prior = _set_working_precision(working)
    try:
        a, b = lhs.value, rhs.value
        if op == "+":
            result = a + b
        elif op == "-":
            result = a - b
        elif op == "*":
            result = a * b
        elif op == "/":
            if b == 0:
                raise CalcEvaluationError("division by zero")
            result = a / b
        elif op == "^":
            if abs(b) > mpf(10) ** 15:
                raise CalcEvaluationError(
                    "exponent magnitude exceeds the calculator's safe range "
                    "(|exponent| > 10^15); use nummy.compute_mo_expression "
                    "for tower-shaped computations"
                )
            result = a ** b
        else:
            raise CalcEvaluationError(f"unknown operator {op!r}")
    finally:
        mp.dps = prior

    if target_precision == EXACT:
        from mpmath import floor as mp_floor

        if result == mp_floor(result):
            return PrecValue(value=result, precision=EXACT)
        # Two exact operands produced a non-integer (e.g., 5/3).  Demote to
        # the session precision; the value's claimed digits still
        # respect that bound.
        return PrecValue(value=result, precision=session.precision)
    return PrecValue(value=result, precision=target_precision)


def evaluate_node(node: Node, session: CalcSession) -> PrecValue:
    if isinstance(node, NumberLiteral):
        return _evaluate_number_literal(node, session)
    if isinstance(node, VariableRef):
        return _evaluate_variable(node, session)
    if isinstance(node, HistoryRef):
        return session.lookup_history(node)
    if isinstance(node, UnaryOp):
        operand = evaluate_node(node.operand, session)
        if node.op == "-":
            return PrecValue(value=-operand.value, precision=operand.precision)
        return operand
    if isinstance(node, BinaryOp):
        left = evaluate_node(node.left, session)
        right = evaluate_node(node.right, session)
        return _arith(node.op, left, right, session)
    if isinstance(node, Assignment):
        value = evaluate_node(node.expr, session)
        if node.name == "Precision":
            _set_session_precision(value, session)
            return PrecValue(value=mpf(session.precision), precision=EXACT)
        if node.name == "MachinePrecision":
            raise CalcEvaluationError("MachinePrecision is read-only")
        session.variables[node.name] = value
        return value
    if isinstance(node, FunctionCall):
        return _evaluate_function_call(node, session)
    raise CalcEvaluationError(f"unknown AST node {type(node).__name__}")


def _evaluate_function_call(node: FunctionCall, session: CalcSession) -> PrecValue:
    builtin = BUILTINS.get(node.name)
    if builtin is None:
        raise CalcEvaluationError(f"unknown function {node.name!r}")
    arg_values = tuple(evaluate_node(a, session) for a in node.args)
    return builtin(arg_values, session)


def _set_session_precision(value: PrecValue, session: CalcSession) -> None:
    if not value.is_integer_valued:
        raise CalcEvaluationError(
            f"Precision must be a positive integer (got {value.value})"
        )
    n = int(value.value)
    if n < 1:
        raise CalcEvaluationError(
            f"Precision must be a positive integer (got {n})"
        )
    session.precision = n


@dataclasses.dataclass(frozen=True)
class ExecutionResult:
    """One evaluation's outcome.

    * ``value`` is the resulting :class:`PrecValue`.
    * ``assignment_target`` is the variable name when the input was an
      assignment, otherwise ``None``.  ``"Precision"`` and other magic
      targets count as assignments.
    * ``empty`` is ``True`` if the input was blank or only whitespace
      (no value, nothing recorded in history).
    """

    value: Optional[PrecValue]
    assignment_target: Optional[str]
    empty: bool


def execute(source: str, session: CalcSession) -> ExecutionResult:
    """Tokenize, parse, evaluate, and append to history.

    Empty input (only whitespace) is a no-op: returns
    ``ExecutionResult(value=None, ..., empty=True)`` and does *not*
    advance the line number.
    """
    tokens = tokenize(source)
    if len(tokens) == 1:  # only EOF
        return ExecutionResult(value=None, assignment_target=None, empty=True)
    node = Parser(tokens).parse()
    value = evaluate_node(node, session)
    session.history.append(value)
    target = node.name if isinstance(node, Assignment) else None
    return ExecutionResult(value=value, assignment_target=target, empty=False)


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------


def format_value(
    prec_value: PrecValue,
    *,
    tower_threshold_log10: float = 1e6,
) -> str:
    """Format a :class:`PrecValue` for REPL display.

    Exact integer-valued results render as ordinary integers.

    Otherwise the value renders as ``digits``.  When the precision is
    not :data:`MACHINE_PRECISION`, a ``\\`prec`` suffix is appended so
    the reader can see how many digits are claimed correct.

    For results whose ``|log10|`` exceeds ``tower_threshold_log10`` the
    output uses :class:`PowerTower` notation (``10^^layer(mag)``)
    without a precision suffix -- towers are described structurally
    rather than digit-wise.
    """
    value = prec_value.value
    precision = prec_value.precision

    if precision == EXACT and prec_value.is_integer_valued:
        try:
            return str(int(value))
        except (OverflowError, ValueError):
            pass  # fall through to general handling

    if value == 0:
        return "0"

    abs_v = -value if value < 0 else value
    try:
        log = mp_log10(abs_v)
    except (ValueError, ZeroDivisionError):
        log = None
    if log is not None and abs(float(log)) > tower_threshold_log10:
        sign = "-" if value < 0 else ""
        tower = PowerTower.from_mpf(abs_v).canonicalize(mag_high=1e6)
        return f"{sign}{tower}"

    if precision == EXACT:
        # Integer-valued exact already handled; reaching here means the
        # value is exact integer that overflowed ``int``.  Fall back to
        # machine-precision-style display.
        return nstr(value, MACHINE_PRECISION)
    if precision == MACHINE_PRECISION:
        # Machine-style display: strip trailing zeros for readability.
        return nstr(value, MACHINE_PRECISION)
    # Arbitrary precision: keep trailing zeros so the displayed digit
    # count visibly matches the claimed precision.
    digits = nstr(value, precision, strip_zeros=False)
    return f"{digits}`{precision}"


# ---------------------------------------------------------------------------
# Builtin functions (Mathematica-style ``Name[args]`` calls)
# ---------------------------------------------------------------------------


def _require_exact_integer(arg: PrecValue, context: str) -> int:
    if not arg.is_integer_valued:
        raise CalcEvaluationError(
            f"{context} expected an integer, got {arg.value}"
        )
    try:
        return int(arg.value)
    except (OverflowError, ValueError) as exc:
        raise CalcEvaluationError(
            f"{context} expected a representable integer ({exc})"
        ) from None


def _builtin_leading_digits(args, session: CalcSession) -> PrecValue:
    """``LeadingDigits[k, n]`` -- leading digits of ``10^^k(-10^n)``.

    The arguments are the iteration count ``k`` and the inner-magnitude
    exponent ``n``.  For the MathOverflow #79217 problem use
    ``LeadingDigits[5, 10]`` (i.e. inner = ``-10^10``).

    Side effect: appends a multi-line summary to ``session.messages``
    describing the integer-part length, leading digit, run of zeros,
    trailing integer digits, and leading fractional digits.

    Return value: the leading additive correction (``10^11 * ln(10)^4``
    for the MO defaults), as a precision-tagged ``PrecValue`` at the
    session precision.  This is the value that gets added to the
    dominant ``10^(10^n)`` to produce the integer-part trailing digits.
    """
    if len(args) != 2:
        raise CalcEvaluationError(
            f"LeadingDigits expects 2 arguments (k, n); got {len(args)}"
        )
    k = _require_exact_integer(args[0], "LeadingDigits k")
    n = _require_exact_integer(args[1], "LeadingDigits n")
    if k < 1:
        raise CalcEvaluationError("LeadingDigits k must be >= 1")
    if n < 1:
        raise CalcEvaluationError("LeadingDigits n must be >= 1")

    from .mo import compute_mo_expression

    # Use the session precision for both the internal mpmath computation
    # and the displayed fractional digit count, with a comfortable
    # working margin so the displayed digits stay provably correct.
    working_dps = max(session.precision + GUARD_DIGITS * 2, 80)
    try:
        result = compute_mo_expression(
            num_levels=k,
            n_inner=10 ** n,
            precision_dps=working_dps,
            fractional_dps=session.precision,
        )
    except NotImplementedError as exc:
        raise CalcEvaluationError(str(exc)) from None

    ld = result.leading
    summary = "\n".join(
        [
            f"  10^^{k}(-10^{n})",
            f"  integer part has {ld.integer_digit_count:,} digits",
            f"  leading digit:                 {ld.leading_digit}",
            f"  followed by zero(s):           {ld.zeros_count:,}",
            f"  trailing integer digits:       {ld.trailing_int_digits}",
            f"  fractional digits:             .{ld.fractional_digits}",
        ]
    )
    if ld.residual_log10 is not None:
        summary += (
            f"\n  dropped higher-order terms:  <= 10^({ld.residual_log10:.3f})"
        )
    session.messages.append(summary)

    # Return the leading additive correction.  We re-use the fractional
    # digits produced by the underlying engine: trailing_int_digits is
    # the integer part of (10^11 * ln(10)^4)-shape, fractional_digits
    # the digits after the point.
    correction_text = ld.trailing_int_digits + "." + ld.fractional_digits
    prior = mp.dps
    mp.dps = max(session.precision + GUARD_DIGITS, MACHINE_PRECISION + GUARD_DIGITS)
    try:
        correction = mpf(correction_text)
    finally:
        mp.dps = prior
    return PrecValue(value=correction, precision=session.precision)


BUILTINS = {
    "LeadingDigits": _builtin_leading_digits,
}
