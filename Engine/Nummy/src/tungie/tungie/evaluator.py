from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from decimal import Decimal
from decimal import ROUND_CEILING
from decimal import ROUND_FLOOR
from decimal import ROUND_HALF_EVEN
from decimal import ROUND_DOWN
from decimal import InvalidOperation
from decimal import localcontext
from fractions import Fraction
import math
import re
from typing import Iterator

from .errors import TungieEvaluationError
from .errors import TungieExitRequested
from .values import Assignment
from .values import Call
from .values import Expr
from .values import Integer
from .values import Program
from .values import Rational
from .values import Real
from .values import Symbol
from .values import call
from .values import integer
from .values import list_expr
from .values import rational
from .values import real
from .values import symbol


MACHINE_PRECISION = 15.954589770191003
DEFAULT_PRECISION = 16
MAX_DIRECT_DECIMAL_EXPONENT = 999_999
MAX_WORKING_PRECISION = 1000
MAX_COMPACT_DECIMAL_PRECISION = 1000
_SYSTEM_SYMBOL_DEFAULTS = {
    "$Precision": integer(DEFAULT_PRECISION),
    "$MaxDirectDecimalExponent": integer(MAX_DIRECT_DECIMAL_EXPONENT),
    "$MaxDisplayedDigits": integer(MAX_COMPACT_DECIMAL_PRECISION),
}
_INFINITY = symbol("Infinity")
_NEGATIVE_INFINITY = call("Times", integer(-1), _INFINITY)
_TRUE = symbol("True")
_FALSE = symbol("False")
_NULL = symbol("Null")
_INDETERMINATE = symbol("Indeterminate")
_UNDEFINED = symbol("Undefined")

_PREDEFINED_SYMBOL_NAMES = frozenset(
    {
        "$MachineEpsilon",
        "$MachinePrecision",
        "$MaxMachineNumber",
        "$MinMachineNumber",
        "Abs",
        "Accuracy",
        "And",
        "Ceiling",
        "Clear",
        "Degree",
        "Divide",
        "E",
        "Equal",
        "ExactNumberQ",
        "Exit",
        "Exp",
        "False",
        "Floor",
        "FractionalPart",
        "Greater",
        "GreaterEqual",
        "I",
        "If",
        "InexactNumberQ",
        "Indeterminate",
        "Infinity",
        "IntegerPart",
        "IntegerQ",
        "Less",
        "LessEqual",
        "List",
        "Log",
        "MachineNumberQ",
        "MachinePrecision",
        "Max",
        "Min",
        "N",
        "Normal",
        "Not",
        "Null",
        "NumberQ",
        "NumericQ",
        "Or",
        "Out",
        "Pi",
        "Plus",
        "Power",
        "Pow10Tower",
        "Precision",
        "Rational",
        "Rationalize",
        "RealValuedNumberQ",
        "Round",
        "Set",
        "SetAccuracy",
        "SetPrecision",
        "Sign",
        "ScientificScale",
        "Sqrt",
        "Times",
        "True",
        "Undefined",
        "UndefinedQ",
        "Unequal",
    }
)

_PI_DIGITS = "3.14159265358979323846264338327950288419716939937510582097494459230781640628620899"
_E_DIGITS = "2.71828182845904523536028747135266249775724709369995957496696762772407663035354759"


@dataclass
class EvaluationSession:
    line: int = 0
    symbols: dict[str, Expr] | None = None
    outputs: dict[int, Expr] | None = None
    current_messages: list[str] | None = None
    precision_override: Decimal | None = None

    def __post_init__(self) -> None:
        if self.symbols is None:
            self.symbols = {}
        for name, value in _SYSTEM_SYMBOL_DEFAULTS.items():
            self.symbols.setdefault(name, value)
        if self.outputs is None:
            self.outputs = {}
        if self.current_messages is None:
            self.current_messages = []

    def evaluate_input(self, expr: Expr) -> tuple[int, Expr]:
        self.line += 1
        assert self.current_messages is not None
        self.current_messages.clear()
        result = evaluate(expr, session=self)
        assert self.outputs is not None
        self.outputs[self.line] = result
        return self.line, result

    def emit_error(self, message: str) -> None:
        assert self.current_messages is not None
        self.current_messages.append(f"Evaluate::error: {message}")

    def emit_warning(self, message: str) -> None:
        assert self.current_messages is not None
        self.current_messages.append(f"Evaluate::warning: {message}")

    def resolve_output(self, index: int | None) -> Expr:
        assert self.outputs is not None
        if index is None:
            if not self.outputs:
                return call("Out")
            return self.outputs[max(self.outputs)]
        target = self.line + index if index < 0 else index
        if target in self.outputs:
            return self.outputs[target]
        return call("Out", integer(index))


def evaluate(expr: Expr, *, session: EvaluationSession | None = None) -> Expr:
    if isinstance(expr, Program):
        result: Expr = _NULL
        for statement in expr.statements:
            result = evaluate(statement, session=session)
        return _NULL if expr.suppress_output else result

    if isinstance(expr, Assignment):
        if _is_predefined_symbol_name(expr.name):
            return _error_null(session, f"Cannot assign to predefined symbol {expr.name}.")
        if session is None:
            raise TungieEvaluationError("Assignments require an evaluation session.")
        value = evaluate(expr.value, session=session)
        assert session.symbols is not None
        session.symbols[expr.name] = value
        return value

    if isinstance(expr, Real):
        return _evaluate_real(expr, session)

    if isinstance(expr, (Integer, Rational)):
        return expr

    if isinstance(expr, Symbol):
        return _evaluate_symbol(expr, session)

    if isinstance(expr, Call):
        return _evaluate_call(expr, session=session)

    return expr


def _evaluate_symbol(expr: Symbol, session: EvaluationSession | None) -> Expr:
    if expr.name == "$Precision" and session is not None and session.precision_override is not None:
        return _decimal_measure_expr(max(Decimal(1), session.precision_override))
    if expr.name == "$MachinePrecision":
        return _evaluate_real(real(repr(MACHINE_PRECISION)), None)
    if expr.name == "$MachineEpsilon":
        return _evaluate_real(real("2.220446049250313*^-16"), None)
    if expr.name == "$MaxMachineNumber":
        return _evaluate_real(real("1.7976931348623157*^+308"), None)
    if expr.name == "$MinMachineNumber":
        return _evaluate_real(real("2.2250738585072014*^-308"), None)
    if expr.name == "Degree":
        return call("Times", rational(1, 180), symbol("Pi"))
    if session is not None and session.symbols is not None and expr.name in session.symbols:
        return session.symbols[expr.name]
    if expr.name in _SYSTEM_SYMBOL_DEFAULTS:
        return _SYSTEM_SYMBOL_DEFAULTS[expr.name]
    return expr


def _evaluate_call(expr: Call, *, session: EvaluationSession | None) -> Expr:
    head_name = expr.head.name if isinstance(expr.head, Symbol) else None

    if head_name == "Exit":
        raise TungieExitRequested(_exit_code(expr.args, session=session))
    if head_name == "Clear":
        return _clear(expr.args, session=session)
    if head_name == "If":
        return _if(expr.args, session=session)
    if head_name == "Out":
        return _out(expr.args, session=session)

    if head_name == "N":
        return _n(expr.args, session=session)
    if head_name == "SetPrecision":
        return _set_precision(expr.args, session=session)
    if head_name == "SetAccuracy":
        return _set_accuracy(expr.args, session=session)
    if head_name == "Precision":
        return _precision(expr.args, session=session)
    if head_name == "Accuracy":
        return _accuracy(expr.args, session=session)

    if head_name == "And":
        return _and(expr.args, session=session)
    if head_name == "Or":
        return _or(expr.args, session=session)
    if head_name == "Not":
        return _not(expr.args, session=session)
    if head_name == "ScientificScale":
        return _scientific_scale(_evaluate_scientific_scale_args(expr.args, session=session), session=session)

    evaluated_args = tuple(evaluate(argument, session=session) for argument in expr.args)

    if head_name == "List":
        return list_expr(evaluated_args)
    if head_name == "Rational":
        return _rational_constructor(evaluated_args, session=session)
    if head_name == "Plus":
        return _plus(evaluated_args, session=session)
    if head_name == "Times":
        return _times(evaluated_args, session=session)
    if head_name == "Divide":
        return _divide(evaluated_args, session=session)
    if head_name == "Power":
        return _power(evaluated_args, session=session)
    if head_name == "Pow10Tower":
        return _pow10_tower(evaluated_args, session=session)
    if head_name in {"Equal", "Unequal", "Less", "LessEqual", "Greater", "GreaterEqual"}:
        return _relation(head_name, evaluated_args)
    if head_name == "Abs":
        return _abs(evaluated_args)
    if head_name == "Sign":
        return _sign(evaluated_args)
    if head_name in {"Floor", "Ceiling", "Round", "IntegerPart", "FractionalPart"}:
        return _rounding(head_name, evaluated_args, session=session)
    if head_name == "Min" or head_name == "Max":
        return _min_max(head_name, evaluated_args)
    if head_name == "Sqrt":
        return _sqrt(evaluated_args, session=session)
    if head_name == "Exp":
        return _exp(evaluated_args)
    if head_name == "Log":
        return _log(evaluated_args)
    if head_name == "Rationalize":
        return _rationalize(evaluated_args)
    if head_name == "Normal":
        return evaluated_args[0] if len(evaluated_args) == 1 else Call(expr.head, evaluated_args)
    if head_name in {
        "IntegerQ",
        "NumberQ",
        "NumericQ",
        "MachineNumberQ",
        "ExactNumberQ",
        "InexactNumberQ",
        "RealValuedNumberQ",
        "UndefinedQ",
    }:
        return _predicate(head_name, evaluated_args)

    return Call(expr.head, evaluated_args)


def _exit_code(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> int:
    if not args:
        return 0
    if len(args) != 1:
        return 0
    value = evaluate(args[0], session=session)
    if isinstance(value, Integer):
        return value.value
    return 0


def _clear(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if session is None:
        return _NULL
    assert session.symbols is not None
    for argument in args:
        if isinstance(argument, Symbol):
            if argument.name in _SYSTEM_SYMBOL_DEFAULTS:
                session.symbols[argument.name] = _SYSTEM_SYMBOL_DEFAULTS[argument.name]
                session.emit_warning(
                    f"Clear resets {argument.name} to its default value "
                    f"{_SYSTEM_SYMBOL_DEFAULTS[argument.name].to_input_form()}."
                )
            elif _is_predefined_symbol_name(argument.name):
                session.emit_error(f"Cannot clear predefined symbol {argument.name}.")
            else:
                session.symbols.pop(argument.name, None)
    return _NULL


def _if(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) not in {2, 3, 4}:
        return call("If", *args)
    condition = evaluate(args[0], session=session)
    if _is_undefined(condition):
        return _UNDEFINED
    if _truth(condition) is True:
        return evaluate(args[1], session=session)
    if _truth(condition) is False:
        if len(args) >= 3:
            return evaluate(args[2], session=session)
        return _NULL
    if len(args) == 4:
        return evaluate(args[3], session=session)
    return call("If", condition, *(evaluate(argument, session=session) for argument in args[1:]))


def _out(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if session is None:
        return call("Out", *args)
    if not args:
        return session.resolve_output(None)
    if len(args) == 1:
        index = evaluate(args[0], session=session)
        if isinstance(index, Integer):
            return session.resolve_output(index.value)
    return call("Out", *(evaluate(argument, session=session) for argument in args))


def _and(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    leftovers: list[Expr] = []
    for argument in args:
        value = evaluate(argument, session=session)
        truth = _truth(value)
        if truth is False:
            return _FALSE
        if truth is None:
            leftovers.append(value)
    if not leftovers:
        return _TRUE
    return call("And", *leftovers)


def _or(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    leftovers: list[Expr] = []
    for argument in args:
        value = evaluate(argument, session=session)
        truth = _truth(value)
        if truth is True:
            return _TRUE
        if truth is None:
            leftovers.append(value)
    if not leftovers:
        return _FALSE
    return call("Or", *leftovers)


def _not(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Not", *(evaluate(argument, session=session) for argument in args))
    value = evaluate(args[0], session=session)
    truth = _truth(value)
    if truth is True:
        return _FALSE
    if truth is False:
        return _TRUE
    return call("Not", value)


def _rational_constructor(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2 or not isinstance(args[0], Integer) or not isinstance(args[1], Integer):
        return call("Rational", *args)
    if args[1].value == 0:
        return _undefined(session, "Division by zero.")
    return rational(args[0].value, args[1].value)


def _plus(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if _any_undefined(args):
        return _UNDEFINED
    if threaded := _thread_listable("Plus", args, session=session):
        return threaded
    flattened = _flatten("Plus", args)
    scale_result = _try_scale_plus(flattened, session=session)
    if scale_result is not None:
        return scale_result
    if _all_approximable(flattened) and any(_contains_inexact(argument) for argument in flattened):
        result = _interval_plus(flattened, session=session)
        if result is not None:
            return result

    numeric: Expr = integer(0)
    non_numeric: list[Expr] = []
    saw_numeric = False
    for argument in flattened:
        if _is_numeric_atom(argument):
            combined = _add_numeric(numeric, argument, session=session)
            if combined is None:
                non_numeric.append(argument)
            else:
                numeric = combined
                saw_numeric = True
        else:
            non_numeric.append(argument)

    result_args: list[Expr] = []
    if saw_numeric and (not _is_zero(numeric) or not non_numeric):
        result_args.append(numeric)
    result_args.extend(non_numeric)
    return _one_identity("Plus", result_args, integer(0))


def _times(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if _any_undefined(args):
        return _UNDEFINED
    if threaded := _thread_listable("Times", args, session=session):
        return threaded
    flattened = _flatten("Times", args)
    scale_result = _try_scale_times(flattened, session=session)
    if scale_result is not None:
        return scale_result
    if _all_approximable(flattened) and any(_contains_inexact(argument) for argument in flattened):
        result = _interval_times(flattened, session=session)
        if result is not None:
            return result

    numeric: Expr = integer(1)
    non_numeric: list[Expr] = []
    saw_numeric = False
    for argument in flattened:
        if _is_numeric_atom(argument):
            combined = _mul_numeric(numeric, argument, session=session)
            if combined is None:
                non_numeric.append(argument)
            else:
                numeric = combined
                saw_numeric = True
        else:
            non_numeric.append(argument)

    if _is_zero(numeric):
        return integer(0)
    result_args: list[Expr] = []
    if saw_numeric and (not _is_one(numeric) or not non_numeric):
        result_args.append(numeric)
    result_args.extend(non_numeric)
    return _one_identity("Times", result_args, integer(1))


def _divide(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("Divide", *args)
    if _any_undefined(args):
        return _UNDEFINED
    numerator, denominator = args
    if _is_zero(denominator):
        return _undefined(session, "Division by zero.")
    scale_result = _try_scale_divide(numerator, denominator, session=session)
    if scale_result is not None:
        return scale_result
    result = _div_numeric(numerator, denominator, session=session)
    if result is not None:
        return result
    return call("Divide", numerator, denominator)


def _power(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("Power", *args)
    base, exponent = args
    if _any_undefined(args):
        return _UNDEFINED
    if threaded := _thread_listable("Power", args, session=session):
        return threaded
    if _is_zero(exponent):
        return integer(1)
    if _is_zero(base) and _is_negative_number(exponent):
        return _undefined(session, "Zero cannot be raised to a negative power.")
    if _is_zero(base) and _is_positive_number(exponent):
        return integer(0)
    if _is_one(exponent):
        return base
    if _is_exact_one(base):
        return integer(1)
    if _is_negative_number(base) and not _is_integer_number(exponent):
        return _undefined(session, "Negative numbers cannot be raised to non-integer powers.")

    scale_result = _try_scale_power(base, exponent, session=session)
    if scale_result is not None:
        return scale_result

    exact_base = _exact_fraction(base)
    exact_exponent = _exact_fraction(exponent)
    if exact_base is not None and exact_exponent is not None:
        exact = _exact_power(exact_base, exact_exponent)
        if exact is not None:
            return _fraction_expr(exact)
        requested_precision = _current_precision_measure(session)
        if _measure_exceeds_working_precision(requested_precision, session=session):
            return call(
                "SetPrecision",
                call("Power", _fraction_expr(exact_base), _fraction_expr(exact_exponent)),
                _decimal_measure_expr(requested_precision),
            )
        return _approximate_exact_power(exact_base, exact_exponent, precision=_current_precision(session))

    if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
        result = _interval_power(base, exponent, session=session)
        if result is not None:
            return result

    return call("Power", base, exponent)


def _evaluate_scientific_scale_args(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> tuple[Expr, ...]:
    if len(args) != 2:
        return tuple(evaluate(argument, session=session) for argument in args)
    return evaluate(args[0], session=session), _evaluate_scale_exponent(args[1], session=session)


def _evaluate_scale_exponent(expr: Expr, *, session: EvaluationSession | None) -> Expr:
    if isinstance(expr, Call) and expr.has_head("Pow10Tower") and len(expr.args) == 2:
        height = evaluate(expr.args[0], session=session)
        top = evaluate(expr.args[1], session=session)
        if isinstance(height, Integer) and height.value == 0:
            return top
        return call("Pow10Tower", height, top)
    if (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.args) == 2
        and isinstance(expr.args[0], Integer)
        and expr.args[0].value == -1
    ):
        return call("Times", integer(-1), _evaluate_scale_exponent(expr.args[1], session=session))
    return evaluate(expr, session=session)


def _pow10_tower(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("Pow10Tower", *args)
    height, top = args
    if not isinstance(height, Integer) or height.value < 0:
        return call("Pow10Tower", *args)
    if height.value == 0:
        return top
    integral_top = _integer_value(top)
    normalized_top = integer(integral_top) if integral_top is not None else top
    direct = _direct_pow10_tower_value(
        height.value,
        normalized_top,
        _current_max_direct_decimal_exponent(session),
    )
    return _fraction_expr(direct) if direct is not None else call("Pow10Tower", height, normalized_top)


def _scientific_scale(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("ScientificScale", *args)
    if _any_undefined(args):
        return _UNDEFINED
    mantissa, exponent = args
    nested = _scale_parts(mantissa)
    if nested is not None:
        return _scientific_scale(
            (nested.mantissa, _add_scale_exponents(nested.exponent, exponent, session=session)),
            session=session,
        )
    if _is_zero(mantissa):
        return integer(0)
    if _is_zero(exponent):
        return mantissa
    normalized = _normalize_scale_mantissa(mantissa, exponent, session=session)
    if normalized is not None:
        return _scientific_scale(normalized, session=session)

    max_direct_exponent = _current_max_direct_decimal_exponent(session)
    exponent_exact = _exact_fraction(exponent)
    exponent_value = exponent_exact.numerator if exponent_exact is not None and exponent_exact.denominator == 1 else None
    if exponent_value is None:
        exponent_value = _scale_exponent_exact_int(exponent)
    if exponent_value is None:
        return call("ScientificScale", mantissa, exponent)
    if abs(exponent_value) > max_direct_exponent:
        return call("ScientificScale", mantissa, _compact_scale_exponent(exponent_value, max_direct_exponent))

    mantissa_exact = _exact_fraction(mantissa)
    if mantissa_exact is not None:
        if _keeps_exact_scale_prefactored(mantissa_exact, exponent, exponent_value, session=session):
            return call("ScientificScale", mantissa, _prefactored_scale_exponent(exponent, exponent_value, session=session))
        scale = Fraction(10**exponent_value, 1) if exponent_value >= 0 else Fraction(1, 10 ** -exponent_value)
        return _fraction_expr(mantissa_exact * scale)

    info = _real_info_for_expr(mantissa)
    if info is None:
        return call("ScientificScale", mantissa, exponent)
    precision = _context_precision_from_measure(info.precision)
    try:
        with localcontext() as context:
            context.prec = _guarded_precision(precision)
            context.Emax = max(context.Emax, max_direct_exponent + context.prec + 8)
            context.Emin = min(context.Emin, -max_direct_exponent - context.prec - 8)
            value = +(info.value * (Decimal(10) ** exponent_value))
        return _decimal_real_with_accuracy(value, info.accuracy - Decimal(exponent_value))
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return call("ScientificScale", mantissa, exponent)


def _direct_pow10_tower_value(height: int, top: Expr, limit: int) -> Fraction | None:
    exact = _exact_fraction(top)
    if exact is None or exact.denominator != 1:
        return None
    value = exact
    for _ in range(height):
        if value.denominator != 1:
            return None
        exponent = value.numerator
        if exponent >= 0:
            if exponent > _max_pow10_exponent_for_limit(limit):
                return None
            value = Fraction(10**exponent, 1)
        else:
            if -exponent > _max_pow10_exponent_for_limit(limit):
                return None
            value = Fraction(1, 10 ** -exponent)
    return value if abs(value) <= limit else None


def _keeps_exact_scale_prefactored(
    mantissa: Fraction,
    exponent: Expr,
    exponent_value: int,
    *,
    session: EvaluationSession | None,
) -> bool:
    if _pow10_tower_parts(exponent) is not None:
        return True
    digit_budget = _current_max_displayed_digits(session)
    numerator_budget = digit_budget - max(exponent_value, 0)
    denominator_budget = digit_budget - max(-exponent_value, 0)
    return (
        _integer_decimal_digit_count_exceeds(mantissa.numerator, numerator_budget)
        or _integer_decimal_digit_count_exceeds(mantissa.denominator, denominator_budget)
    )


def _prefactored_scale_exponent(expr: Expr, exponent_value: int, *, session: EvaluationSession | None) -> Expr:
    if _pow10_tower_parts(expr) is not None:
        return expr
    display_limit = max(0, _current_max_displayed_digits(session) - 1)
    return _compact_scale_exponent(exponent_value, display_limit)


def _integer_decimal_digit_count_exceeds(value: int, limit: int) -> bool:
    if limit < 1:
        return True
    absolute = abs(value)
    if absolute == 0:
        return 1 > limit
    bit_limit = int((limit + 1) / math.log10(2)) + 2
    if absolute.bit_length() > bit_limit:
        return True
    return len(str(absolute)) > limit


def _max_pow10_exponent_for_limit(limit: int) -> int:
    return len(str(limit)) - 1


def _relation(head: str, args: tuple[Expr, ...]) -> Expr:
    if len(args) != 2:
        return call(head, *args)
    if _any_undefined(args):
        return _UNDEFINED
    comparison = _compare(args[0], args[1])
    if comparison is None:
        return call(head, *args)
    result = {
        "Equal": comparison == 0,
        "Unequal": comparison != 0,
        "Less": comparison < 0,
        "LessEqual": comparison <= 0,
        "Greater": comparison > 0,
        "GreaterEqual": comparison >= 0,
    }[head]
    return _bool(result)


def _abs(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call("Abs", *args)
    if _any_undefined(args):
        return _UNDEFINED
    value = args[0]
    exact = _exact_fraction(value)
    if exact is not None:
        return _fraction_expr(abs(exact))
    scale = _scale_parts(value)
    if scale is not None:
        return _scientific_scale((_abs_numeric(scale.mantissa), scale.exponent), session=None)
    real_info = _real_info_for_expr(value)
    if real_info is not None:
        return _decimal_real(abs(real_info.value), real_info.precision)
    return call("Abs", value)


def _sign(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call("Sign", *args)
    if _any_undefined(args):
        return _UNDEFINED
    comparison = _compare(args[0], integer(0))
    if comparison is None:
        return call("Sign", args[0])
    return integer((comparison > 0) - (comparison < 0))


def _rounding(head: str, args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) not in {1, 2}:
        return call(head, *args)
    if len(args) == 2 and head not in {"Floor", "Ceiling", "Round"}:
        return call(head, *args)
    if _any_undefined(args):
        return _UNDEFINED
    value = args[0]
    multiple = args[1] if len(args) == 2 else integer(1)
    if len(args) == 2:
        quotient = _div_numeric(value, multiple, session=session)
        if quotient is None:
            return call(head, *args)
        rounded = _rounding(head, (quotient,), session=session)
        if _is_undefined(rounded):
            return _UNDEFINED
        return _mul_numeric(rounded, multiple, session=session) or call(head, *args)

    exact = _exact_fraction(value)
    if exact is not None:
        if head == "Floor":
            return integer(math.floor(exact))
        if head == "Ceiling":
            return integer(math.ceil(exact))
        if head == "Round":
            return integer(round(exact))
        if head == "IntegerPart":
            return integer(math.trunc(exact))
        if head == "FractionalPart":
            return _fraction_expr(exact - math.trunc(exact))

    info = _real_info_for_expr(value)
    if info is None:
        return call(head, value)
    if head == "Floor":
        return integer(int(info.value.to_integral_value(rounding=ROUND_FLOOR)))
    if head == "Ceiling":
        return integer(int(info.value.to_integral_value(rounding=ROUND_CEILING)))
    if head == "Round":
        return integer(int(info.value.to_integral_value(rounding=ROUND_HALF_EVEN)))
    if head == "IntegerPart":
        return integer(int(info.value.to_integral_value(rounding=ROUND_DOWN)))
    integer_part = Decimal(int(info.value.to_integral_value(rounding=ROUND_DOWN)))
    return _decimal_real(info.value - integer_part, info.precision)


def _min_max(head: str, args: tuple[Expr, ...]) -> Expr:
    if _any_undefined(args):
        return _UNDEFINED
    if not args:
        return symbol("Infinity") if head == "Min" else _NEGATIVE_INFINITY
    best = args[0]
    for value in args[1:]:
        comparison = _compare(value, best)
        if comparison is None:
            return call(head, *args)
        if (head == "Min" and comparison < 0) or (head == "Max" and comparison > 0):
            best = value
    return best


def _sqrt(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Sqrt", *args)
    if _any_undefined(args):
        return _UNDEFINED
    return _power((args[0], rational(1, 2)), session=session)


def _exp(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call("Exp", *args)
    if _any_undefined(args):
        return _UNDEFINED
    value = args[0]
    if _is_zero(value):
        return integer(1)
    if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
        result = _interval_exp(value)
        if result is not None:
            return result
    if _is_one(value):
        return symbol("E")
    return call("Exp", value)


def _log(args: tuple[Expr, ...]) -> Expr:
    if len(args) not in {1, 2}:
        return call("Log", *args)
    if _any_undefined(args):
        return _UNDEFINED
    if len(args) == 1:
        value = args[0]
        if _is_one(value):
            return integer(0)
        if isinstance(value, Symbol) and value.name == "E":
            return integer(1)
        if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
            result = _interval_log(value)
            if result is not None:
                return result
        return call("Log", value)

    base, value = args
    if base == value:
        return integer(1)
    exact_base = _exact_fraction(base)
    exact_value = _exact_fraction(value)
    if exact_base is not None and exact_value is not None:
        power = _integer_log_exact(exact_base, exact_value)
        if power is not None:
            return integer(power)
    if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
        result = _inexact_result(args, lambda values: values[1].ln() / values[0].ln())
        if result is not None:
            return result
    return call("Log", base, value)


def _n(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) not in {1, 2}:
        return call("N", *args)
    precision: Decimal | None | float = _current_precision_measure(session)
    if len(args) == 2:
        precision = _precision_argument(evaluate(args[1], session=session))
        if precision == math.inf:
            expr = evaluate(args[0], session=session)
            return expr
    if precision is None:
        expr = evaluate(args[0], session=session)
    else:
        expr = _evaluate_with_precision(args[0], precision, session=session)
    if _is_undefined(expr):
        return _UNDEFINED
    return _approximate(expr, precision, session=session)


def _set_precision(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("SetPrecision", *args)
    precision = _precision_argument(evaluate(args[1], session=session))
    if precision is None:
        expr = evaluate(args[0], session=session)
        if _is_undefined(expr):
            return _UNDEFINED
        return _approximate(expr, None, session=session)
    if precision == math.inf:
        expr = evaluate(args[0], session=session)
        if _is_undefined(expr):
            return _UNDEFINED
        exact = _exact_from_decimal(expr)
        return exact if exact is not None else expr
    compact = _compact_precision_expr(args[0], precision, session=session)
    if compact is not None:
        return compact
    expr = evaluate(args[0], session=session)
    if _is_undefined(expr):
        return _UNDEFINED
    info = _real_info_for_expr(expr)
    if info is not None:
        target = _measure_decimal(precision)
        return _decimal_real(info.value, min(info.precision, target))
    exact = _exact_fraction(expr)
    if exact is not None and _measure_exceeds_working_precision(precision, session=session):
        if exact.denominator == 1 and abs(exact.numerator) < 10**18:
            return real(f"{exact.numerator}`{_format_measure(precision)}")
        return call("SetPrecision", _fraction_expr(exact), _decimal_measure_expr(precision))
    decimal_value = _decimal_for_expr(expr, _context_precision_from_measure(precision, session=session))
    if decimal_value is None:
        return call("SetPrecision", expr, args[1])
    return _decimal_real(decimal_value, _measure_decimal(precision))


def _set_accuracy(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("SetAccuracy", *args)
    accuracy = _precision_argument(evaluate(args[1], session=session))
    if accuracy is None:
        expr = evaluate(args[0], session=session)
        if _is_undefined(expr):
            return _UNDEFINED
        return _approximate(expr, None, session=session)
    if accuracy == math.inf:
        expr = evaluate(args[0], session=session)
        if _is_undefined(expr):
            return _UNDEFINED
        exact = _exact_from_decimal(expr)
        return exact if exact is not None else expr
    compact = _compact_accuracy_expr(args[0], accuracy, session=session)
    if compact is not None:
        return compact
    expr = evaluate(args[0], session=session)
    if _is_undefined(expr):
        return _UNDEFINED
    info = _real_info_for_expr(expr)
    if info is not None:
        target = _measure_decimal(accuracy)
        return _decimal_real_accuracy(info.value, min(info.accuracy, target))
    exact = _exact_fraction(expr)
    if exact is not None and _measure_exceeds_working_precision(accuracy, session=session):
        return call("SetAccuracy", _fraction_expr(exact), _decimal_measure_expr(accuracy))
    working_accuracy = _context_precision_from_measure(accuracy, session=session)
    decimal_probe = _decimal_for_expr(expr, working_accuracy + 8)
    if decimal_probe is None:
        return call("SetAccuracy", expr, args[1])
    precision = max(1, _bounded_int(_measure_decimal(accuracy) + max(_decimal_log10_abs(decimal_probe), Decimal(0))))
    decimal_value = _decimal_for_expr(expr, precision)
    if decimal_value is None:
        return call("SetAccuracy", expr, args[1])
    return _decimal_real_accuracy(decimal_value, _measure_decimal(accuracy))


def _precision(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Precision", *args)
    value = evaluate(args[0], session=session)
    if _exact_fraction(value) is not None:
        return _INFINITY
    certified = _certified_interval_for_expr(value)
    if certified is not None:
        return _plain_real(certified.precision)
    scale = _scale_parts(value)
    if scale is not None:
        if _exact_fraction(scale.mantissa) is not None:
            return _INFINITY
        info = _real_info_for_expr(scale.mantissa)
        if info is not None:
            return _plain_real(info.precision)
        return call("Precision", value)
    info = _real_info_for_expr(value)
    if info is None:
        return call("Precision", value)
    return _plain_real(info.precision)


def _accuracy(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Accuracy", *args)
    value = evaluate(args[0], session=session)
    if _exact_fraction(value) is not None:
        return _INFINITY
    certified = _certified_interval_for_expr(value)
    if certified is not None:
        return _plain_real(certified.accuracy)
    scale = _scale_parts(value)
    if scale is not None:
        if _exact_fraction(scale.mantissa) is not None:
            return _INFINITY
        info = _real_info_for_expr(scale.mantissa)
        if info is None:
            return call("Accuracy", value)
        exponent_exact = _exact_fraction(scale.exponent)
        if exponent_exact is not None and exponent_exact.denominator == 1:
            return _plain_real(info.accuracy - Decimal(exponent_exact.numerator))
        exponent_comparison = _compare_scale_exponents(scale.exponent, integer(0))
        if exponent_comparison is not None:
            return _NEGATIVE_INFINITY if exponent_comparison > 0 else _INFINITY
        return call("Accuracy", value)
    info = _real_info_for_expr(value)
    if info is None:
        return call("Accuracy", value)
    return _plain_real(info.accuracy)


def _rationalize(args: tuple[Expr, ...]) -> Expr:
    if len(args) not in {1, 2}:
        return call("Rationalize", *args)
    if _any_undefined(args):
        return _UNDEFINED
    exact = _exact_from_decimal(args[0])
    return exact if exact is not None else args[0]


def _predicate(head: str, args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call(head, *args)
    value = args[0]
    if head == "IntegerQ":
        return _bool(isinstance(value, Integer))
    if head == "NumberQ" or head == "NumericQ":
        return _bool(_is_numeric_atom(value))
    if head == "MachineNumberQ":
        return _FALSE
    if head == "ExactNumberQ":
        scale = _scale_parts(value)
        return _bool(
            _exact_fraction(value) is not None
            or (
                scale is not None
                and _exact_fraction(scale.mantissa) is not None
                and _scale_exponent_is_exact(scale.exponent)
            )
        )
    if head == "InexactNumberQ":
        return _bool(isinstance(value, Real) or (_scale_parts(value) is not None and _contains_inexact(value)))
    if head == "RealValuedNumberQ":
        return _bool(_is_numeric_atom(value))
    if head == "UndefinedQ":
        return _bool(_is_undefined(value))
    return call(head, value)


def _thread_listable(head: str, args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr | None:
    list_lengths = [len(argument.args) for argument in args if isinstance(argument, Call) and argument.has_head("List")]
    if not list_lengths:
        return None
    if len(set(list_lengths)) != 1:
        return call(head, *args)
    length = list_lengths[0]
    items: list[Expr] = []
    for index in range(length):
        threaded_args = [
            argument.args[index] if isinstance(argument, Call) and argument.has_head("List") else argument
            for argument in args
        ]
        items.append(evaluate(call(head, *threaded_args), session=session))
    return list_expr(items)


def _flatten(head: str, args: tuple[Expr, ...]) -> list[Expr]:
    result: list[Expr] = []
    for argument in args:
        if isinstance(argument, Call) and argument.has_head(head):
            result.extend(argument.args)
        else:
            result.append(argument)
    return result


def _one_identity(head: str, args: list[Expr], identity: Expr) -> Expr:
    if not args:
        return identity
    if len(args) == 1:
        return args[0]
    return call(head, *args)


@dataclass(frozen=True)
class ScaleParts:
    mantissa: Expr
    exponent: Expr


def _try_scale_plus(args: list[Expr], *, session: EvaluationSession | None) -> Expr | None:
    if not any(_scale_parts(argument) is not None for argument in args):
        return None

    terms: list[ScaleParts] = []
    for argument in args:
        parts = _scale_parts_or_numeric(argument)
        if parts is None:
            return None
        if not _is_zero(parts.mantissa):
            terms.append(parts)

    if not terms:
        return integer(0)

    combined: list[ScaleParts] = []
    for term in terms:
        for index, existing in enumerate(combined):
            if term.exponent == existing.exponent:
                mantissa = _add_numeric(existing.mantissa, term.mantissa, session=session)
                if mantissa is None:
                    return None
                combined[index] = ScaleParts(mantissa, existing.exponent)
                break
        else:
            combined.append(term)
    combined = [term for term in combined if not _is_zero(term.mantissa)]
    if not combined:
        return integer(0)
    if len(combined) == 1:
        return _scientific_scale((combined[0].mantissa, combined[0].exponent), session=session)

    aligned = _try_align_scale_terms(combined, session=session)
    if aligned is not None:
        return aligned

    dominant_index = _dominant_scale_term_index(combined)
    if dominant_index is not None:
        dominant = combined[dominant_index]
        precision = _scale_parts_precision(dominant)
        if all(
            index == dominant_index
            or _scale_separation_exceeds_precision(dominant.exponent, term.exponent, precision)
            for index, term in enumerate(combined)
        ):
            return _scientific_scale((dominant.mantissa, dominant.exponent), session=session)

    return None


def _try_scale_times(args: list[Expr], *, session: EvaluationSession | None) -> Expr | None:
    if not any(_scale_parts(argument) is not None for argument in args):
        return None

    mantissa: Expr = integer(1)
    exponent: Expr = integer(0)
    for argument in args:
        parts = _scale_parts(argument)
        if parts is not None:
            next_mantissa = _mul_numeric(mantissa, parts.mantissa, session=session)
            if next_mantissa is None:
                return None
            mantissa = next_mantissa
            exponent = _add_scale_exponents(exponent, parts.exponent, session=session)
            continue
        if not _is_numeric_atom(argument):
            return None
        next_mantissa = _mul_numeric(mantissa, argument, session=session)
        if next_mantissa is None:
            return None
        mantissa = next_mantissa

    return _scientific_scale((mantissa, exponent), session=session)


def _try_scale_divide(numerator: Expr, denominator: Expr, *, session: EvaluationSession | None) -> Expr | None:
    numerator_parts = _scale_parts_or_numeric(numerator)
    denominator_parts = _scale_parts_or_numeric(denominator)
    if numerator_parts is None or denominator_parts is None:
        return None
    if _scale_parts(numerator) is None and _scale_parts(denominator) is None:
        return None

    mantissa = _div_numeric(numerator_parts.mantissa, denominator_parts.mantissa, session=session)
    if mantissa is None:
        return None
    exponent = _add_scale_exponents(
        numerator_parts.exponent,
        _negate_expr(denominator_parts.exponent),
        session=session,
    )
    return _scientific_scale((mantissa, exponent), session=session)


def _try_scale_power(base: Expr, exponent: Expr, *, session: EvaluationSession | None) -> Expr | None:
    scale_base = _scale_parts(base)
    if scale_base is not None:
        if not _is_positive_number(scale_base.mantissa):
            return None
        inexact_result = _try_inexact_scale_power(scale_base, exponent, session=session)
        if inexact_result is not None:
            return inexact_result
        exponent_integer = _integer_value(exponent)
        if exponent_integer is None:
            return None
        mantissa_precision = _precision_for_inexact_expr(scale_base.mantissa)
        if _is_one(scale_base.mantissa) and mantissa_precision is not None:
            mantissa = _precision_one(mantissa_precision)
        else:
            mantissa = _power((scale_base.mantissa, integer(exponent_integer)), session=session)
        if _is_undefined(mantissa) or mantissa == call("Power", scale_base.mantissa, integer(exponent_integer)):
            return None
        scale_exponent = _multiply_scale_exponent(scale_base.exponent, integer(exponent_integer), session=session)
        return _scientific_scale((mantissa, scale_exponent), session=session)

    base_exact = _exact_fraction(base)
    base_info = _real_info_for_expr(base)
    exponent_value = _integer_value(exponent)
    if exponent_value is None:
        return None

    if base_exact != 10 and (base_info is None or base_info.value != 10):
        return _try_positive_numeric_power_scale(base, exponent, exponent_value, session=session)

    max_direct_exponent = _current_max_direct_decimal_exponent(session)
    precisions = [
        precision
        for precision in (_precision_for_inexact_expr(base), _precision_for_inexact_expr(exponent))
        if precision is not None
    ]
    precision = min(precisions) if precisions else None
    mantissa: Expr = _precision_one(precision) if precision is not None else integer(1)
    if abs(exponent_value) <= max_direct_exponent:
        return _scientific_scale((mantissa, integer(exponent_value)), session=session)
    return _scientific_scale(
        (mantissa, _compact_scale_exponent(exponent_value, max_direct_exponent)),
        session=session,
    )


def _try_inexact_scale_power(
    scale_base: ScaleParts,
    exponent: Expr,
    *,
    session: EvaluationSession | None,
) -> Expr | None:
    if not (_contains_inexact(scale_base.mantissa) or _contains_inexact(exponent)):
        return None
    base_log = _scale_log10_interval(scale_base)
    exponent_interval = _interval_for_expr(exponent)
    if base_log is None or exponent_interval is None:
        return None
    if exponent_interval.center <= 0:
        return None
    working_precision = _guarded_precision(
        max(
            50,
            _context_precision_from_measure(base_log.precision),
            _context_precision_from_measure(exponent_interval.precision),
        )
    )
    try:
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, base_log.center, exponent_interval.center)
            log_center = +(base_log.center * exponent_interval.center)
        log_accuracy = _accuracy_sum(
            [
                _multiplication_accuracy([base_log, exponent_interval]),
                _accuracy_from_radius(_decimal_rounding_radius(log_center, working_precision)),
            ]
        )
        precision = _precision_from_log10_uncertainty_accuracy(log_accuracy)
        scale = _scale_from_log10_center(log_center, precision, session=session)
        return scale
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _scale_log10_interval(parts: ScaleParts) -> DecimalInterval | None:
    exponent_value = _scale_exponent_exact_int(parts.exponent)
    if exponent_value is None:
        return None
    mantissa_exact = _exact_fraction(parts.mantissa)
    if mantissa_exact is not None:
        if mantissa_exact <= 0:
            return None
        mantissa = _decimal_for_fraction(mantissa_exact, DEFAULT_PRECISION)
        return DecimalInterval(Decimal(exponent_value) + _decimal_log10_abs(mantissa), Decimal("Infinity"))
    info = _real_info_for_expr(parts.mantissa)
    if info is None or info.value <= 0:
        return None
    log_accuracy = _log10_uncertainty_accuracy(info.value, info.accuracy)
    if log_accuracy is None:
        return None
    center = Decimal(exponent_value) + _decimal_log10_abs(info.value)
    return DecimalInterval(center, log_accuracy)


def _log10_uncertainty_accuracy(center: Decimal, accuracy: Decimal) -> Decimal | None:
    if center <= 0 or not _zero_excluded(center, accuracy):
        return None
    if accuracy == Decimal("Infinity"):
        return Decimal("Infinity")
    precision = _precision_from_accuracy(center, accuracy)
    if precision <= 0:
        return None
    log_ln10 = _decimal_log10_abs(_decimal_ln10())
    correction = _log10_relative_log_radius_correction(precision)
    return precision + log_ln10 + correction


def _log10_relative_log_radius_correction(precision: Decimal) -> Decimal:
    if precision > MAX_WORKING_PRECISION:
        return Decimal("-1e-30")
    working_precision = _guarded_precision(max(DEFAULT_PRECISION, _context_precision_from_measure(precision) + 4))
    exponent_bound = _bounded_int(precision, cap=MAX_WORKING_PRECISION) + 100
    with localcontext() as context:
        context.prec = working_precision
        context.Emax = max(context.Emax, exponent_bound)
        context.Emin = min(context.Emin, -exponent_bound)
        relative_radius = +(Decimal(10) ** (-precision))
        if relative_radius <= 0 or relative_radius >= 1:
            raise InvalidOperation
        scaled_log_radius = +(-(Decimal(1) - relative_radius).ln() / relative_radius)
    with localcontext() as context:
        context.prec = 50
        _configure_decimal_context(context, 50, scaled_log_radius)
        return -(scaled_log_radius.ln() / _decimal_ln10(context.prec))


def _precision_from_log10_uncertainty_accuracy(accuracy: Decimal) -> Decimal:
    if accuracy == Decimal("Infinity"):
        return Decimal("Infinity")
    if accuracy == Decimal("-Infinity"):
        return Decimal("-Infinity")
    return accuracy - _decimal_log10_abs(_decimal_ln10())


def _scale_from_log10_center(
    log_center: Decimal,
    precision: Decimal,
    *,
    session: EvaluationSession | None,
) -> Expr | None:
    max_direct_exponent = _current_max_direct_decimal_exponent(session)
    integral = log_center.to_integral_value(rounding=ROUND_FLOOR)
    fractional = log_center - integral
    try:
        exponent_value = int(integral)
    except (OverflowError, ValueError):
        return None

    with localcontext() as context:
        _configure_decimal_context(context, _guarded_precision(_context_precision_from_measure(precision)), fractional)
        mantissa_value = +(fractional * _decimal_ln10(context.prec)).exp()
    if mantissa_value == Decimal(10):
        mantissa_value = Decimal(1)
        exponent_value += 1

    return _scientific_scale(
        (
            _decimal_real(mantissa_value, precision),
            _compact_scale_exponent(exponent_value, max_direct_exponent),
        ),
        session=session,
    )


def _try_positive_numeric_power_scale(
    base: Expr,
    exponent: Expr,
    exponent_value: int,
    *,
    session: EvaluationSession | None,
) -> Expr | None:
    if not _is_positive_number(base):
        return None
    precision = _combined_precision((base, exponent))
    if precision is None:
        return None
    max_direct_exponent = _current_max_direct_decimal_exponent(session)
    working_precision = _guarded_precision(precision)
    baseline = _power_scale_decimal_parts(base, exponent_value, precision)
    guarded = _power_scale_decimal_parts(base, exponent_value, working_precision)
    if baseline is None or guarded is None:
        return None
    baseline_exponent, baseline_mantissa = baseline
    guarded_exponent, guarded_mantissa = guarded
    if abs(guarded_exponent) <= max_direct_exponent:
        return None
    if baseline_exponent != guarded_exponent:
        return None
    result_precision = _matching_precision(baseline_mantissa, guarded_mantissa, precision)
    return _scientific_scale(
        (
            _decimal_real(guarded_mantissa, result_precision),
            _compact_scale_exponent(guarded_exponent, max_direct_exponent),
        ),
        session=session,
    )


def _power_scale_decimal_parts(base: Expr, exponent_value: int, precision: int) -> tuple[int, Decimal] | None:
    base_value = _decimal_for_expr(base, precision)
    if base_value is None or base_value <= 0:
        return None
    try:
        with localcontext() as context:
            context.prec = max(precision, 1)
            log10_base = base_value.ln() / Decimal(10).ln()
            scale_log = log10_base * Decimal(exponent_value)
            scale_exponent = int(scale_log.to_integral_value(rounding=ROUND_FLOOR))
            fractional = scale_log - Decimal(scale_exponent)
            mantissa = +(Decimal(10).ln() * fractional).exp()
            if mantissa == Decimal(10):
                return scale_exponent + 1, Decimal(1)
            return scale_exponent, mantissa
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _scale_parts(expr: Expr) -> ScaleParts | None:
    if isinstance(expr, Call) and expr.has_head("ScientificScale") and len(expr.args) == 2:
        return ScaleParts(expr.args[0], expr.args[1])
    if isinstance(expr, Real):
        return _real_scale_parts(expr)
    return None


def _real_scale_parts(expr: Real) -> ScaleParts | None:
    match = _REAL_RE.match(expr.text)
    if match is None or match.group("magnitude") is None:
        return None
    exponent = int(match.group("magnitude")[2:])
    if exponent == 0:
        return None
    mantissa = real(f"{match.group('mantissa')}{match.group('mark') or ''}")
    return ScaleParts(mantissa, integer(exponent))


def _scale_parts_or_numeric(expr: Expr) -> ScaleParts | None:
    parts = _scale_parts(expr)
    if parts is not None:
        return parts
    if _is_numeric_atom(expr):
        return ScaleParts(expr, integer(0))
    return None


def _normalize_scale_mantissa(
    mantissa: Expr,
    exponent: Expr,
    *,
    session: EvaluationSession | None,
) -> tuple[Expr, Expr] | None:
    if isinstance(mantissa, Integer):
        value = mantissa.value
        if value == 0:
            return integer(0), exponent
        sign = -1 if value < 0 else 1
        absolute = abs(value)
        shift = 0
        while absolute >= 10 and absolute % 10 == 0:
            absolute //= 10
            shift += 1
        if shift:
            return integer(sign * absolute), _add_scale_exponents(exponent, integer(shift), session=session)
        return None

    info = _real_info_for_expr(mantissa)
    if info is None or info.value.is_zero():
        return None
    shift = info.value.adjusted()
    if shift == 0:
        return None
    precision = _context_precision_from_measure(info.precision)
    with localcontext() as context:
        context.prec = _guarded_precision(precision)
        normalized = +(info.value.scaleb(-shift))
    if normalized == normalized.to_integral_value():
        normalized_expr: Expr = real(f"{int(normalized)}`{_format_measure(info.precision)}")
    else:
        normalized_expr = _decimal_real(normalized, info.precision)
    return normalized_expr, _add_scale_exponents(exponent, integer(shift), session=session)


def _try_align_scale_terms(terms: list[ScaleParts], *, session: EvaluationSession | None) -> Expr | None:
    exponent_values = [_scale_exponent_exact_int(term.exponent) for term in terms]
    if any(value is None for value in exponent_values):
        return None
    assert all(value is not None for value in exponent_values)
    largest = max(exponent_values)
    span = largest - min(exponent_values)

    term_accuracies = [
        _scale_parts_accuracy_at_exponent(term, exponent_value, largest)
        for term, exponent_value in zip(terms, exponent_values)
    ]
    if any(accuracy is None for accuracy in term_accuracies):
        return None
    assert all(accuracy is not None for accuracy in term_accuracies)
    certified_accuracy = min(term_accuracies)
    alignment_limit = (
        DEFAULT_PRECISION
        if certified_accuracy == Decimal("Infinity")
        else max(0, int(certified_accuracy.to_integral_value(rounding=ROUND_CEILING)))
    )
    if span > alignment_limit:
        return None

    working_precision = _guarded_precision(max(1, alignment_limit + 2))
    with localcontext() as context:
        context.prec = working_precision
        context.Emax = max(context.Emax, span)
        context.Emin = min(context.Emin, -span)
        mantissa_sum_decimal = Decimal(0)
        for term, exponent_value in zip(terms, exponent_values):
            mantissa = _decimal_for_expr(term.mantissa, working_precision)
            if mantissa is None:
                return None
            mantissa_sum_decimal += mantissa * (Decimal(10) ** (exponent_value - largest))
        mantissa_sum_decimal = +mantissa_sum_decimal

    if mantissa_sum_decimal.is_zero():
        return integer(0)
    result_accuracy = certified_accuracy + Decimal(largest)
    mantissa_sum = _decimal_real_with_accuracy(mantissa_sum_decimal, result_accuracy - Decimal(largest))
    return _scientific_scale((mantissa_sum, integer(largest)), session=session)


def _scale_parts_accuracy_at_exponent(parts: ScaleParts, exponent_value: int, target_exponent: int) -> Decimal | None:
    if _is_zero(parts.mantissa):
        return Decimal("Infinity")
    exact = _exact_fraction(parts.mantissa)
    if exact is not None:
        return Decimal("Infinity")
    info = _real_info_for_expr(parts.mantissa)
    if info is None:
        return None
    return info.accuracy + Decimal(target_exponent - exponent_value)


def _dominant_scale_term_index(terms: list[ScaleParts]) -> int | None:
    dominant_index = 0
    dominant_abs = _scale_parts_abs(terms[0])
    for index, term in enumerate(terms[1:], start=1):
        comparison = _compare_scale_abs(_scale_parts_abs(term), dominant_abs)
        if comparison is None:
            return None
        if comparison > 0:
            dominant_index = index
            dominant_abs = _scale_parts_abs(term)
    return dominant_index


def _scale_parts_abs(parts: ScaleParts) -> ScaleParts:
    return ScaleParts(_abs_numeric(parts.mantissa), parts.exponent)


def _compare_scale_abs(left: ScaleParts, right: ScaleParts) -> int | None:
    left_zero = _is_zero(left.mantissa)
    right_zero = _is_zero(right.mantissa)
    if left_zero or right_zero:
        return (not left_zero) - (not right_zero)
    exponent_comparison = _compare_scale_exponents(left.exponent, right.exponent)
    if exponent_comparison is not None and exponent_comparison != 0:
        return exponent_comparison
    if exponent_comparison == 0:
        return _compare(left.mantissa, right.mantissa)
    return None


def _scale_parts_precision(parts: ScaleParts) -> Decimal:
    info = _real_info_for_expr(parts.mantissa)
    if info is None:
        return Decimal(DEFAULT_PRECISION)
    return info.precision


def _scale_separation_exceeds_precision(larger: Expr, smaller: Expr, precision: Decimal) -> bool:
    difference = _scale_exponent_difference(larger, smaller)
    if difference is None:
        return False
    exact = _exact_fraction(difference)
    if exact is not None and exact.denominator == 1:
        return Decimal(exact.numerator) > precision
    comparison = _compare_scale_exponents(difference, _decimal_measure_expr(precision))
    return comparison is not None and comparison > 0


def _scale_exponent_difference(larger: Expr, smaller: Expr) -> Expr | None:
    if larger == smaller:
        return integer(0)
    larger_int = _scale_exponent_exact_int(larger)
    smaller_int = _scale_exponent_exact_int(smaller)
    if larger_int is not None and smaller_int is not None:
        return integer(larger_int - smaller_int)
    larger_exact = _exact_fraction(larger)
    smaller_exact = _exact_fraction(smaller)
    if larger_exact is not None and smaller_exact is not None:
        return _fraction_expr(larger_exact - smaller_exact)
    if _is_zero(larger):
        return _negate_expr(smaller)
    if _is_zero(smaller):
        return larger
    return None if _compare_scale_exponents(larger, smaller) is None else larger


def _add_scale_exponents(left: Expr, right: Expr, *, session: EvaluationSession | None) -> Expr:
    combined = _combine_scale_exponent_terms(
        _flatten_scale_exponent_terms(left) + _flatten_scale_exponent_terms(right),
        session=session,
    )
    if combined is not None:
        return combined

    if _is_zero(left):
        return right
    if _is_zero(right):
        return left
    if left == _negate_expr(right) or _negate_expr(left) == right:
        return integer(0)
    if left == right:
        return _multiply_scale_exponent(left, integer(2), session=session)

    left_integer = _scale_exponent_exact_int(left)
    right_integer = _scale_exponent_exact_int(right)
    if left_integer is not None and right_integer is not None:
        return _compact_scale_exponent(
            left_integer + right_integer,
            _current_max_direct_decimal_exponent(session),
        )

    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return _fraction_expr(left_exact + right_exact)

    result = _add_numeric(left, right, session=session)
    if result is not None:
        return result
    return call("Plus", left, right)


def _flatten_scale_exponent_terms(expr: Expr) -> list[Expr]:
    if isinstance(expr, Call) and expr.has_head("Plus"):
        terms: list[Expr] = []
        for argument in expr.args:
            terms.extend(_flatten_scale_exponent_terms(argument))
        return terms
    return [expr]


def _combine_scale_exponent_terms(terms: list[Expr], *, session: EvaluationSession | None) -> Expr | None:
    numeric_total = Fraction(0)
    symbolic: list[Expr] = []
    changed = False

    for term in terms:
        if _is_zero(term):
            changed = True
            continue
        exact = _exact_fraction(term)
        if exact is not None:
            numeric_total += exact
            changed = True
            continue

        for index, existing in enumerate(symbolic):
            if existing == _negate_expr(term) or _negate_expr(existing) == term:
                del symbolic[index]
                changed = True
                break
            if existing == term:
                symbolic[index] = _multiply_scale_exponent(existing, integer(2), session=session)
                changed = True
                break
        else:
            symbolic.append(term)

    if numeric_total:
        symbolic.append(_fraction_expr(numeric_total))

    if not symbolic:
        return integer(0)
    if len(symbolic) == 1:
        return symbolic[0] if changed else None

    exact_values = [_scale_exponent_exact_int(term) for term in symbolic]
    if all(value is not None for value in exact_values):
        assert all(value is not None for value in exact_values)
        return _compact_scale_exponent(sum(exact_values), _current_max_direct_decimal_exponent(session))

    return call("Plus", *symbolic) if changed else None


def _multiply_scale_exponent(exponent: Expr, factor: Expr, *, session: EvaluationSession | None) -> Expr:
    if _is_zero(exponent) or _is_zero(factor):
        return integer(0)
    if _is_one(factor):
        return exponent
    if _is_one(exponent):
        return factor

    exponent_exact = _exact_fraction(exponent)
    factor_exact = _exact_fraction(factor)
    if exponent_exact is not None and factor_exact is not None:
        product = exponent_exact * factor_exact
        if product.denominator == 1:
            return _compact_scale_exponent(product.numerator, _current_max_direct_decimal_exponent(session))
        return _fraction_expr(product)

    exponent_integer = _scale_exponent_exact_int(exponent)
    if exponent_integer is not None and factor_exact is not None and factor_exact.denominator == 1:
        return _compact_scale_exponent(
            exponent_integer * factor_exact.numerator,
            _current_max_direct_decimal_exponent(session),
        )

    if factor_exact is not None and factor_exact.denominator == 1:
        tower = _pow10_tower_parts(exponent)
        if tower is not None:
            sign, height, top = tower
            mantissa = integer(sign * factor_exact.numerator)
            if height == 1:
                return _scientific_scale((mantissa, top), session=session)

    result = _mul_numeric(exponent, factor, session=session)
    if result is not None:
        return result
    return call("Times", factor, exponent)


def _compact_scale_exponent(value: int, max_direct_exponent: int) -> Expr:
    sign = -1 if value < 0 else 1
    absolute = abs(value)
    if absolute <= max_direct_exponent:
        return integer(value)
    power = _integer_power_of_ten_exponent(absolute)
    if power is not None:
        result: Expr = call("Pow10Tower", integer(1), integer(power))
    else:
        result = integer(absolute)
    return _negate_expr(result) if sign < 0 else result


def _integer_power_of_ten_exponent(value: int) -> int | None:
    if value <= 0:
        return None
    exponent = 0
    while value % 10 == 0:
        value //= 10
        exponent += 1
    return exponent if value == 1 else None


def _pow10_tower_parts(expr: Expr) -> tuple[int, int, Expr] | None:
    sign = 1
    if isinstance(expr, Call) and expr.has_head("Times") and len(expr.args) == 2:
        if isinstance(expr.args[0], Integer) and expr.args[0].value == -1:
            sign = -1
            expr = expr.args[1]
    if not isinstance(expr, Call) or not expr.has_head("Pow10Tower") or len(expr.args) != 2:
        return None
    height, top = expr.args
    if not isinstance(height, Integer) or height.value <= 0:
        return None
    return sign, height.value, top


def _scale_exponent_exact_int(expr: Expr) -> int | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact.numerator if exact.denominator == 1 else None
    if isinstance(expr, Call) and expr.has_head("Times") and len(expr.args) == 2:
        if isinstance(expr.args[0], Integer) and expr.args[0].value == -1:
            value = _scale_exponent_exact_int(expr.args[1])
            return -value if value is not None else None
    tower = _pow10_tower_parts(expr)
    if tower is not None:
        sign, height, top = tower
        top_value = _scale_exponent_exact_int(top)
        if height == 1 and top_value is not None and 0 <= top_value <= 18:
            return sign * (10**top_value)
    scale = _scale_parts(expr)
    if scale is not None:
        mantissa = _exact_fraction(scale.mantissa)
        exponent = _scale_exponent_exact_int(scale.exponent)
        if mantissa is not None and mantissa.denominator == 1 and exponent is not None and 0 <= exponent <= 18:
            return mantissa.numerator * (10**exponent)
    return None


def _integer_value(expr: Expr) -> int | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact.numerator if exact.denominator == 1 else None
    info = _real_info_for_expr(expr)
    if info is None:
        return None
    integral = info.value.to_integral_value()
    return int(integral) if info.value == integral else None


def _precision_for_inexact_expr(expr: Expr) -> Decimal | None:
    info = _real_info_for_expr(expr)
    if info is not None:
        return info.precision
    return None


def _precision_one(precision: Decimal | int | float | None) -> Expr:
    return real(f"1`{_format_measure(precision)}") if precision is not None else integer(1)


def _negate_expr(expr: Expr) -> Expr:
    exact = _exact_fraction(expr)
    if exact is not None:
        return _fraction_expr(-exact)
    if isinstance(expr, Real):
        return real(expr.text[1:] if expr.text.startswith("-") else "-" + expr.text)
    if isinstance(expr, Call) and expr.has_head("Plus"):
        return call("Plus", *(_negate_expr(argument) for argument in expr.args))
    if isinstance(expr, Call) and expr.has_head("Times") and len(expr.args) == 2:
        if isinstance(expr.args[0], Integer) and expr.args[0].value == -1:
            return expr.args[1]
    return call("Times", integer(-1), expr)


def _abs_numeric(expr: Expr) -> Expr:
    exact = _exact_fraction(expr)
    if exact is not None:
        return _fraction_expr(abs(exact))
    if isinstance(expr, Real) and expr.text.startswith("-"):
        return real(expr.text[1:])
    return expr


def _add_numeric(left: Expr, right: Expr, *, session: EvaluationSession | None = None) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return _fraction_expr(left_exact + right_exact)
    return _interval_plus((left, right), session=session)


def _mul_numeric(left: Expr, right: Expr, *, session: EvaluationSession | None = None) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return _fraction_expr(left_exact * right_exact)
    return _interval_times((left, right), session=session)


def _div_numeric(left: Expr, right: Expr, *, session: EvaluationSession | None = None) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        if right_exact == 0:
            return _undefined(session, "Division by zero.")
        return _fraction_expr(left_exact / right_exact)
    if _is_zero(right):
        return _undefined(session, "Division by zero.")
    return _interval_divide(left, right, session=session)


def _exact_power(base: Fraction, exponent: Fraction) -> Fraction | None:
    if base == 0 and exponent < 0:
        return None
    if exponent.denominator == 1:
        power = exponent.numerator
        if power >= 0:
            return base ** power
        return Fraction(1, 1) / (base ** -power)
    if base < 0:
        return None
    powered = base ** abs(exponent.numerator)
    root = exponent.denominator
    numerator_root = _integer_nth_root_exact(powered.numerator, root)
    denominator_root = _integer_nth_root_exact(powered.denominator, root)
    if numerator_root is None or denominator_root is None:
        return None
    result = Fraction(numerator_root, denominator_root)
    if exponent.numerator < 0:
        return Fraction(1, 1) / result
    return result


def _integer_nth_root_exact(value: int, root: int) -> int | None:
    if root <= 0 or value < 0:
        return None
    if root == 1:
        return value
    if value in {0, 1}:
        return value
    low = 0
    high = 1 << max(1, (value.bit_length() + root - 1) // root)
    while low <= high:
        candidate = (low + high) // 2
        powered = candidate ** root
        if powered == value:
            return candidate
        if powered < value:
            low = candidate + 1
        else:
            high = candidate - 1
    return None


def _approximate_exact_power(base: Fraction, exponent: Fraction, *, precision: int) -> Expr:
    with localcontext() as context:
        context.prec = _guarded_precision(precision)
        base_value = Decimal(base.numerator) / Decimal(base.denominator)
        exponent_value = Decimal(exponent.numerator) / Decimal(exponent.denominator)
        result = +_decimal_power([base_value, exponent_value])
    return _decimal_real(result, precision)


def _decimal_power(values: list[Decimal]) -> Decimal:
    base, exponent = values
    integral = exponent.to_integral_value()
    if exponent == integral:
        return base ** int(integral)
    if base <= 0:
        raise InvalidOperation
    return (base.ln() * exponent).exp()


def _integer_log_exact(base: Fraction, value: Fraction) -> int | None:
    if base <= 0 or base == 1 or value <= 0:
        return None
    current = Fraction(1, 1)
    for exponent in range(0, 4096):
        if current == value:
            return exponent
        if current > value and base > 1:
            return None
        current *= base
    return None


def _compare(left: Expr, right: Expr) -> int | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return (left_exact > right_exact) - (left_exact < right_exact)
    scale_comparison = _compare_scale_values(left, right)
    if scale_comparison is not None:
        return scale_comparison
    if _contains_inexact(left) or _contains_inexact(right):
        return _compare_interval_values(left, right)
    if _all_approximable((left, right)):
        left_value = _decimal_for_expr(left, 50)
        right_value = _decimal_for_expr(right, 50)
        if left_value is not None and right_value is not None:
            return (left_value > right_value) - (left_value < right_value)
    if left == right:
        return 0
    return None


def _compare_interval_values(left: Expr, right: Expr) -> int | None:
    left_interval = _interval_for_expr(left)
    right_interval = _interval_for_expr(right)
    if left_interval is None or right_interval is None:
        return None
    center = left_interval.center - right_interval.center
    accuracy = _accuracy_sum([left_interval.accuracy, right_interval.accuracy])
    if not _zero_excluded(center, accuracy):
        return None
    return (center > 0) - (center < 0)


def _compare_scale_values(left: Expr, right: Expr) -> int | None:
    left_parts = _scale_parts_or_numeric(left)
    right_parts = _scale_parts_or_numeric(right)
    if left_parts is None or right_parts is None:
        return None
    if _scale_parts(left) is None and _scale_parts(right) is None:
        return None

    left_sign = _numeric_sign(left_parts.mantissa)
    right_sign = _numeric_sign(right_parts.mantissa)
    if left_sign is None or right_sign is None:
        return None
    if left_sign != right_sign:
        return (left_sign > right_sign) - (left_sign < right_sign)
    if left_sign == 0:
        return 0

    exponent_comparison = _compare_scale_exponents(left_parts.exponent, right_parts.exponent)
    if exponent_comparison is not None and exponent_comparison != 0:
        return exponent_comparison if left_sign > 0 else -exponent_comparison
    if exponent_comparison == 0:
        return _compare(left_parts.mantissa, right_parts.mantissa)
    return None


def _compare_scale_exponents(left: Expr, right: Expr) -> int | None:
    if left == right:
        return 0
    left_int = _scale_exponent_exact_int(left)
    right_int = _scale_exponent_exact_int(right)
    if left_int is not None and right_int is not None:
        return (left_int > right_int) - (left_int < right_int)
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return (left_exact > right_exact) - (left_exact < right_exact)

    left_tower = _pow10_tower_parts(left)
    right_tower = _pow10_tower_parts(right)
    if left_tower is not None and right_tower is not None:
        left_sign, left_height, left_top = left_tower
        right_sign, right_height, right_top = right_tower
        if left_sign != right_sign:
            return (left_sign > right_sign) - (left_sign < right_sign)
        if left_height != right_height:
            comparison = (left_height > right_height) - (left_height < right_height)
            return comparison if left_sign > 0 else -comparison
        top_comparison = _compare(left_top, right_top)
        return None if top_comparison is None else (top_comparison if left_sign > 0 else -top_comparison)

    if left_tower is not None and right_exact is not None:
        sign, height, top = left_tower
        top_sign = _numeric_sign(top)
        if height > 0 and top_sign is not None and top_sign >= 0:
            return sign
    if right_tower is not None and left_exact is not None:
        sign, height, top = right_tower
        top_sign = _numeric_sign(top)
        if height > 0 and top_sign is not None and top_sign >= 0:
            return -sign

    left_scale = _scale_parts(left)
    right_scale = _scale_parts(right)
    if left_scale is not None or right_scale is not None:
        return _compare_scale_values(left, right)

    return None


def _approximate(
    expr: Expr,
    precision: Decimal | int | float | None,
    *,
    session: EvaluationSession | None = None,
) -> Expr:
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(_approximate(argument, precision, session=session) for argument in expr.args)
    if precision is None:
        precision = Decimal(DEFAULT_PRECISION)
    exact = _exact_fraction(expr)
    if exact is not None and _measure_exceeds_working_precision(precision, session=session):
        if exact.denominator == 1 and abs(exact.numerator) < 10**18:
            return real(f"{exact.numerator}`{_format_measure(precision)}")
        return call("SetPrecision", _fraction_expr(exact), _decimal_measure_expr(precision))
    certified = _certified_interval_for_expr(expr)
    if certified is not None and _measure_exceeds_working_precision(certified.precision, session=session):
        return _interval_to_expr(certified, session=session)
    compact = _compact_precision_expr(expr, precision, session=session)
    if compact is not None:
        return compact
    value = _decimal_for_expr(expr, _context_precision_from_measure(precision, session=session))
    return _decimal_real(value, _measure_decimal(precision)) if value is not None else expr


def _evaluate_with_precision(expr: Expr, precision: Decimal | int | None | float, *, session: EvaluationSession | None) -> Expr:
    if precision is None or precision == math.inf:
        return evaluate(expr, session=session)
    precision_measure = _measure_decimal(precision)
    working_precision = _context_precision_from_measure(precision_measure)
    if session is None:
        temp_session = EvaluationSession()
        temp_session.precision_override = max(Decimal(1), precision_measure)
        return evaluate(expr, session=temp_session)
    with _temporary_precision(session, max(Decimal(1), precision_measure), working_precision):
        return evaluate(expr, session=session)


@contextmanager
def _temporary_precision(session: EvaluationSession, precision: Decimal, working_precision: int) -> Iterator[None]:
    old_precision = session.precision_override
    session.precision_override = precision
    try:
        yield
    finally:
        session.precision_override = old_precision


def _inexact_result(args: tuple[Expr, ...] | list[Expr], operation) -> Expr | None:
    intervals = [_interval_for_expr(argument) for argument in args]
    if any(interval is None for interval in intervals):
        return None
    assert all(interval is not None for interval in intervals)
    try:
        working_precision = _interval_working_precision(intervals)
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, *(interval.center for interval in intervals))
            result = +operation([interval.center for interval in intervals])
        computation_radius = _decimal_rounding_radius(result, working_precision)
        accuracy = _accuracy_from_radius(computation_radius)
        return _decimal_real_with_accuracy(result, accuracy)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


@dataclass(frozen=True)
class DecimalInterval:
    center: Decimal
    accuracy: Decimal
    exact_center: Fraction | None = None
    compact_center: Expr | None = None

    @property
    def precision(self) -> Decimal:
        return _precision_from_accuracy(self.center, self.accuracy)


def _interval_for_expr(expr: Expr) -> DecimalInterval | None:
    certified = _certified_interval_for_expr(expr)
    if certified is not None:
        return certified
    exact = _exact_fraction(expr)
    if exact is not None:
        value = _decimal_for_fraction(exact, _working_precision_for_exact_fraction(exact))
        return DecimalInterval(value, Decimal("Infinity"), exact, _fraction_expr(exact))
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return None
        exact_center = _small_exact_fraction_from_decimal(info.value)
        return DecimalInterval(info.value, info.accuracy, exact_center)
    return None


def _interval_working_precision(intervals: list[DecimalInterval]) -> int:
    finite_precisions = [
        _context_precision_from_measure(interval.precision)
        for interval in intervals
        if interval.accuracy != Decimal("Infinity")
    ]
    if not finite_precisions:
        return _guarded_precision(DEFAULT_PRECISION)
    return _guarded_precision(max(finite_precisions))


def _certified_interval_for_expr(expr: Expr) -> DecimalInterval | None:
    if not isinstance(expr, Call) or len(expr.args) != 2:
        return None
    if not (expr.has_head("SetPrecision") or expr.has_head("SetAccuracy")):
        return None
    center_expr, measure_expr = expr.args
    measure = _precision_argument(measure_expr)
    if measure is None or measure == math.inf:
        return None
    measure_decimal = _measure_decimal(measure)
    exact = _exact_fraction(center_expr)
    if exact is not None:
        center = _decimal_for_fraction(exact, _context_precision_from_measure(DEFAULT_PRECISION))
        if expr.has_head("SetPrecision"):
            accuracy = _accuracy_from_precision_fraction(exact, measure_decimal)
        else:
            accuracy = measure_decimal
        return DecimalInterval(center, accuracy, exact, center_expr)
    compact_center = _exact_numeric_center_expr(center_expr)
    if compact_center is None:
        return None
    center = _decimal_for_expr(compact_center, DEFAULT_PRECISION + 8)
    if center is None:
        return None
    if expr.has_head("SetPrecision"):
        accuracy = _accuracy_from_precision(center, measure_decimal)
    else:
        accuracy = measure_decimal
    return DecimalInterval(center, accuracy, None, compact_center)


def _interval_to_expr(interval: DecimalInterval, *, session: EvaluationSession | None = None) -> Expr:
    precision = interval.precision
    if (
        interval.exact_center is None
        and interval.compact_center is not None
        and _measure_exceeds_working_precision(precision, session=session)
    ):
        return call("SetPrecision", interval.compact_center, _decimal_measure_expr(precision))
    if interval.exact_center is not None and _measure_exceeds_working_precision(precision, session=session):
        center_expr = interval.compact_center or _fraction_expr(interval.exact_center)
        if interval.exact_center.denominator == 1 and abs(interval.exact_center.numerator) < 10**18:
            return real(f"{interval.exact_center.numerator}`{_format_measure(precision)}")
        return call("SetPrecision", center_expr, _decimal_measure_expr(precision))
    return _decimal_real_with_accuracy(interval.center, interval.accuracy)


def _compact_precision_expr(
    expr: Expr,
    precision: Decimal | int | float,
    *,
    session: EvaluationSession | None = None,
) -> Expr | None:
    if not _measure_exceeds_working_precision(precision, session=session):
        return None
    exact = _exact_fraction(expr)
    if exact is not None:
        if exact.denominator == 1 and abs(exact.numerator) < 10**18:
            return real(f"{exact.numerator}`{_format_measure(precision)}")
        return call("SetPrecision", _fraction_expr(exact), _decimal_measure_expr(precision))
    center = _exact_numeric_center_expr(expr)
    if center is None:
        return None
    return call("SetPrecision", center, _decimal_measure_expr(precision))


def _compact_accuracy_expr(
    expr: Expr,
    accuracy: Decimal | int | float,
    *,
    session: EvaluationSession | None = None,
) -> Expr | None:
    if not _measure_exceeds_working_precision(accuracy, session=session):
        return None
    exact = _exact_fraction(expr)
    if exact is not None:
        return call("SetAccuracy", _fraction_expr(exact), _decimal_measure_expr(accuracy))
    center = _exact_numeric_center_expr(expr)
    if center is None:
        return None
    return call("SetAccuracy", center, _decimal_measure_expr(accuracy))


def _exact_numeric_center_expr(expr: Expr) -> Expr | None:
    if _contains_inexact(expr):
        return None
    try:
        center = _decimal_for_expr(expr, DEFAULT_PRECISION + 8)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None
    if center is None or not center.is_finite():
        return None
    return expr


def _sum_exact_centers(intervals: list[DecimalInterval]) -> Fraction | None:
    total = Fraction(0)
    for interval in intervals:
        if interval.exact_center is None:
            return None
        total += interval.exact_center
    return total


def _center_expr_for_interval(interval: DecimalInterval) -> Expr | None:
    if interval.compact_center is not None:
        return interval.compact_center
    if interval.exact_center is not None:
        return _fraction_expr(interval.exact_center)
    return None


def _sum_compact_centers(intervals: list[DecimalInterval]) -> Expr | None:
    exact_total = Fraction(0)
    terms: list[Expr] = []
    for interval in intervals:
        if interval.exact_center is not None:
            exact_total += interval.exact_center
            continue
        center = _center_expr_for_interval(interval)
        if center is None:
            return None
        terms.append(center)
    if exact_total:
        terms.append(_fraction_expr(exact_total))
    return _one_identity("Plus", terms, integer(0))


def _product_exact_centers(intervals: list[DecimalInterval]) -> Fraction | None:
    product = Fraction(1)
    for interval in intervals:
        if interval.exact_center is None:
            return None
        product *= interval.exact_center
    return product


def _product_compact_centers(intervals: list[DecimalInterval]) -> Expr | None:
    exact_product = Fraction(1)
    factors: list[Expr] = []
    for interval in intervals:
        if interval.exact_center is not None:
            exact_product *= interval.exact_center
            continue
        center = _center_expr_for_interval(interval)
        if center is None:
            return None
        factors.append(center)
    if exact_product == 0:
        return integer(0)
    if exact_product != 1 or not factors:
        factors.insert(0, _fraction_expr(exact_product))
    return _one_identity("Times", factors, integer(1))


def _divide_compact_centers(numerator: DecimalInterval, denominator: DecimalInterval) -> Expr | None:
    numerator_center = _center_expr_for_interval(numerator)
    denominator_center = _center_expr_for_interval(denominator)
    if numerator_center is None or denominator_center is None:
        return None
    if numerator.exact_center == 0:
        return integer(0)
    if denominator.exact_center == 1:
        return numerator_center
    if numerator.exact_center is not None and denominator.exact_center is not None:
        return _fraction_expr(numerator.exact_center / denominator.exact_center)
    return call("Times", numerator_center, call("Power", denominator_center, integer(-1)))


def _decimal_product(values) -> Decimal:
    result = Decimal(1)
    for value in values:
        result *= value
    return +result


def _accuracy_sum(accuracies: list[Decimal]) -> Decimal:
    if any(accuracy == Decimal("-Infinity") for accuracy in accuracies):
        return Decimal("-Infinity")
    finite = [accuracy for accuracy in accuracies if accuracy != Decimal("Infinity")]
    if not finite:
        return Decimal("Infinity")
    base = min(finite)
    with localcontext() as context:
        context.prec = 50
        total = Decimal(0)
        for accuracy in finite:
            delta = accuracy - base
            if delta > MAX_WORKING_PRECISION:
                continue
            total += Decimal(10) ** (-delta)
        return +(base - _decimal_log10_abs(total))


def _multiplication_accuracy(intervals: list[DecimalInterval]) -> Decimal:
    terms: list[Decimal] = []
    for index, interval in enumerate(intervals):
        if interval.accuracy == Decimal("Infinity"):
            continue
        others_log_abs = Decimal(0)
        for other_index, other in enumerate(intervals):
            if other_index != index:
                if other.center.is_zero():
                    others_log_abs = Decimal("-Infinity")
                    break
                others_log_abs += _decimal_log10_abs(other.center)
        terms.append(interval.accuracy - others_log_abs)
    finite_uncertain = [interval.accuracy for interval in intervals if interval.accuracy != Decimal("Infinity")]
    if len(finite_uncertain) >= 2:
        terms.append(sum(finite_uncertain, Decimal(0)))
    return _accuracy_sum(terms)


def _division_accuracy(numerator: DecimalInterval, denominator: DecimalInterval) -> Decimal:
    terms: list[Decimal] = []
    denominator_log_abs = _decimal_log10_abs(denominator.center)
    if numerator.accuracy != Decimal("Infinity"):
        terms.append(numerator.accuracy + denominator_log_abs)
    if denominator.accuracy != Decimal("Infinity"):
        numerator_log_abs = Decimal("-Infinity") if numerator.center.is_zero() else _decimal_log10_abs(numerator.center)
        terms.append(denominator.accuracy - numerator_log_abs + denominator_log_abs * 2)
    if numerator.accuracy != Decimal("Infinity") and denominator.accuracy != Decimal("Infinity"):
        terms.append(numerator.accuracy + denominator.accuracy + denominator_log_abs)
    return _accuracy_sum(terms)


def _zero_excluded(center: Decimal, accuracy: Decimal) -> bool:
    if center.is_zero():
        return False
    if accuracy == Decimal("Infinity"):
        return True
    if accuracy == Decimal("-Infinity"):
        return False
    return accuracy > -_decimal_log10_abs(center)


def _interval_plus(
    args: tuple[Expr, ...] | list[Expr],
    *,
    session: EvaluationSession | None = None,
) -> Expr | None:
    intervals = [_interval_for_expr(argument) for argument in args]
    if any(interval is None for interval in intervals):
        return None
    assert all(interval is not None for interval in intervals)
    working_precision = _interval_working_precision(intervals)
    try:
        exact_center = _sum_exact_centers(intervals)
        compact_center = _sum_compact_centers(intervals)
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, *(interval.center for interval in intervals))
            center = _decimal_for_fraction(exact_center, working_precision) if exact_center is not None else +sum((interval.center for interval in intervals), Decimal(0))
        accuracy = _accuracy_sum([interval.accuracy for interval in intervals])
        return _interval_to_expr(DecimalInterval(center, accuracy, exact_center, compact_center), session=session)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_times(
    args: tuple[Expr, ...] | list[Expr],
    *,
    session: EvaluationSession | None = None,
) -> Expr | None:
    intervals = [_interval_for_expr(argument) for argument in args]
    if any(interval is None for interval in intervals):
        return None
    assert all(interval is not None for interval in intervals)
    working_precision = _interval_working_precision(intervals)
    try:
        exact_center = _product_exact_centers(intervals)
        compact_center = _product_compact_centers(intervals)
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, *(interval.center for interval in intervals))
            center = _decimal_for_fraction(exact_center, working_precision) if exact_center is not None else _decimal_product(interval.center for interval in intervals)
        accuracy = _multiplication_accuracy(intervals)
        return _interval_to_expr(DecimalInterval(center, accuracy, exact_center, compact_center), session=session)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_divide(left: Expr, right: Expr, *, session: EvaluationSession | None) -> Expr | None:
    numerator = _interval_for_expr(left)
    denominator = _interval_for_expr(right)
    if numerator is None or denominator is None:
        return None
    if not _zero_excluded(denominator.center, denominator.accuracy):
        return _undefined(session, "Division by zero.")
    working_precision = _interval_working_precision([numerator, denominator])
    try:
        exact_center = None
        if numerator.exact_center is not None and denominator.exact_center not in {None, Fraction(0)}:
            exact_center = numerator.exact_center / denominator.exact_center
        compact_center = _divide_compact_centers(numerator, denominator)
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, numerator.center, denominator.center)
            center = _decimal_for_fraction(exact_center, working_precision) if exact_center is not None else +(numerator.center / denominator.center)
        accuracy = _division_accuracy(numerator, denominator)
        return _interval_to_expr(DecimalInterval(center, accuracy, exact_center, compact_center), session=session)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_power(base: Expr, exponent: Expr, *, session: EvaluationSession | None) -> Expr | None:
    base_interval = _interval_for_expr(base)
    exponent_interval = _interval_for_expr(exponent)
    if base_interval is None or exponent_interval is None:
        return None
    if base_interval.center < 0 and not _is_integer_number(exponent):
        return _undefined(session, "Negative numbers cannot be raised to non-integer powers.")
    if base_interval.center == 0 and exponent_interval.center < 0:
        return _undefined(session, "Zero cannot be raised to a negative power.")

    base_radius = _materialized_radius(base_interval.accuracy)
    exponent_radius = _materialized_radius(exponent_interval.accuracy)
    if base_radius is None or exponent_radius is None:
        return None

    exponent_exact = _exact_fraction(exponent)
    if exponent_exact is not None and exponent_exact.denominator == 1:
        if exponent_exact.numerator < 0 and not _zero_excluded(base_interval.center, base_interval.accuracy):
            return _undefined(session, "Zero cannot be raised to a negative power.")
        return _interval_integer_power(base_interval, exponent_exact.numerator, base_radius)
    exponent_integral = exponent_interval.center.to_integral_value()
    if exponent_interval.accuracy == Decimal("Infinity") and exponent_interval.center == exponent_integral:
        if exponent_integral < 0 and not _zero_excluded(base_interval.center, base_interval.accuracy):
            return _undefined(session, "Zero cannot be raised to a negative power.")
        return _interval_integer_power(base_interval, int(exponent_integral), base_radius)

    if not _zero_excluded(base_interval.center, base_interval.accuracy):
        return _undefined(session, "Negative numbers cannot be raised to non-integer powers.")

    working_precision = _interval_working_precision([base_interval, exponent_interval])
    try:
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, base_interval.center, exponent_interval.center)
            center = +_decimal_power([base_interval.center, exponent_interval.center])
            base_gap = base_interval.center - base_radius
            log_center = base_interval.center.ln()
            log_radius = _log_radius_for_positive_interval(base_interval.center, base_radius)
            power_radius = abs(center) * (
                abs(exponent_interval.center) * base_radius / base_gap
                + abs(log_center) * exponent_radius
                + exponent_radius * log_radius
            )
            radius = +power_radius + _decimal_rounding_radius(center, working_precision)
        return _decimal_real_with_accuracy(center, _accuracy_from_radius(radius))
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_exp(expr: Expr) -> Expr | None:
    interval = _interval_for_expr(expr)
    if interval is None:
        return None
    radius_value = _materialized_radius(interval.accuracy)
    if radius_value is None:
        return None
    working_precision = _interval_working_precision([interval])
    try:
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, interval.center, radius_value)
            center = +interval.center.exp()
            upper = (interval.center + radius_value).exp()
            lower = (interval.center - radius_value).exp()
            radius = max(abs(upper - center), abs(center - lower))
            radius = +radius + _decimal_rounding_radius(center, working_precision)
        return _decimal_real_with_accuracy(center, _accuracy_from_radius(radius))
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_log(expr: Expr) -> Expr | None:
    interval = _interval_for_expr(expr)
    if interval is None or interval.center <= 0 or not _zero_excluded(interval.center, interval.accuracy):
        return None
    radius_value = _materialized_radius(interval.accuracy)
    if radius_value is None:
        return None
    working_precision = _interval_working_precision([interval])
    try:
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, interval.center, radius_value)
            center = +interval.center.ln()
            upper = (interval.center + radius_value).ln()
            lower = (interval.center - radius_value).ln()
            radius = max(abs(upper - center), abs(center - lower))
            radius = +radius + _decimal_rounding_radius(center, working_precision)
        return _decimal_real_with_accuracy(center, _accuracy_from_radius(radius))
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _interval_integer_power(base: DecimalInterval, exponent: int, base_radius: Decimal) -> Expr | None:
    working_precision = _interval_working_precision([base])
    try:
        with localcontext() as context:
            _configure_decimal_context(context, working_precision, base.center)
            center = +(base.center ** exponent)
            if exponent == 0:
                radius = Decimal(0)
            elif exponent > 0:
                high = abs(base.center) + base_radius
                radius = (high ** exponent) - abs(center)
                if radius < 0:
                    radius = -radius
            else:
                if base_radius >= abs(base.center):
                    return None
                positive_power = -exponent
                low = abs(base.center) - base_radius
                high = abs(base.center) + base_radius
                reciprocal_span = (low ** -positive_power) - (high ** -positive_power)
                radius = abs(reciprocal_span)
            radius = +radius + _decimal_rounding_radius(center, working_precision)
        return _decimal_real_with_accuracy(center, _accuracy_from_radius(radius))
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _log_radius_for_positive_interval(center: Decimal, radius: Decimal) -> Decimal:
    if radius == 0:
        return Decimal(0)
    gap = center - radius
    if gap <= 0:
        raise InvalidOperation
    return (center + radius).ln() - gap.ln()


def _decimal_for_expr(expr: Expr, precision: int) -> Decimal | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return _decimal_for_fraction(exact, precision)
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return None
        with localcontext() as context:
            context.prec = max(precision, 1)
            return +info.value
    if isinstance(expr, Symbol):
        if expr.name == "Pi":
            return _decimal_constant(_PI_DIGITS, precision)
        if expr.name == "E":
            return _decimal_constant(_E_DIGITS, precision)
        if expr.name == "MachinePrecision":
            return Decimal(str(MACHINE_PRECISION))
        if expr.name == "Infinity":
            return None
    if isinstance(expr, Call):
        certified = _certified_interval_for_expr(expr)
        if certified is not None:
            if certified.exact_center is not None:
                return _decimal_for_fraction(certified.exact_center, precision)
            with localcontext() as context:
                context.prec = max(precision, 1)
                return +certified.center
        if expr.has_head("Times"):
            values = [_decimal_for_expr(argument, precision) for argument in expr.args]
            if any(value is None for value in values):
                return None
            result = Decimal(1)
            with localcontext() as context:
                context.prec = max(precision, 1)
                for value in values:
                    assert value is not None
                    result *= value
                return +result
        if expr.has_head("Plus"):
            values = [_decimal_for_expr(argument, precision) for argument in expr.args]
            if any(value is None for value in values):
                return None
            with localcontext() as context:
                context.prec = max(precision, 1)
                return +sum((value for value in values if value is not None), Decimal(0))
        if expr.has_head("Power") and len(expr.args) == 2:
            values = [_decimal_for_expr(argument, precision) for argument in expr.args]
            if any(value is None for value in values):
                return None
            with localcontext() as context:
                context.prec = max(precision, 1)
                try:
                    return +_decimal_power([value for value in values if value is not None])
                except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
                    return None
        if expr.has_head("Sqrt") and len(expr.args) == 1:
            value = _decimal_for_expr(expr.args[0], precision)
            if value is not None:
                with localcontext() as context:
                    context.prec = max(precision, 1)
                    try:
                        return +_decimal_power([value, Decimal("0.5")])
                    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
                        return None
        if expr.has_head("Exp") and len(expr.args) == 1:
            value = _decimal_for_expr(expr.args[0], precision)
            if value is not None:
                with localcontext() as context:
                    context.prec = max(precision, 1)
                    return +value.exp()
        if expr.has_head("Log"):
            values = [_decimal_for_expr(argument, precision) for argument in expr.args]
            if any(value is None for value in values):
                return None
            with localcontext() as context:
                context.prec = max(precision, 1)
                if len(values) == 1:
                    return +values[0].ln()  # type: ignore[union-attr]
                if len(values) == 2:
                    return +(values[1].ln() / values[0].ln())  # type: ignore[union-attr]
    return None


def _decimal_constant(text: str, precision: int) -> Decimal:
    with localcontext() as context:
        context.prec = max(precision, 1)
        return +Decimal(text)


def _evaluate_real(expr: Real, session: EvaluationSession | None) -> Real:
    match = _REAL_RE.match(expr.text)
    if match is None or match.group("mark"):
        return expr
    precision = _literal_precision(match.group("mantissa"), _current_precision_measure(session))
    return real(f"{match.group('mantissa')}`{_format_measure(precision)}{match.group('magnitude') or ''}")


def _decimal_real(value: Decimal, precision: Decimal | int | float) -> Expr:
    if not value.is_finite():
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    measure = _measure_decimal(precision)
    value = _round_decimal(value, _context_precision_from_measure(measure))
    return real(_mark_formatted_decimal(_format_decimal(value), f"`{_format_measure(measure)}"))


def _decimal_real_accuracy(value: Decimal, accuracy: Decimal | int | float) -> Expr:
    if not value.is_finite():
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    measure = _measure_decimal(accuracy)
    precision = _precision_from_accuracy(value, measure)
    value = _round_decimal(value, _context_precision_from_measure(precision))
    return real(_mark_formatted_decimal(_format_decimal(value), f"``{_format_measure(measure)}"))


def _decimal_real_with_accuracy(value: Decimal, accuracy: Decimal | int | float) -> Expr:
    if not value.is_finite():
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    accuracy_measure = _measure_decimal(accuracy)
    precision = _precision_from_accuracy(value, accuracy_measure)
    value = _round_decimal(value, _context_precision_from_measure(precision))
    return real(_mark_formatted_decimal(_format_decimal(value), f"`{_format_measure(precision)}"))


def _plain_real(value: Decimal | int | float) -> Real:
    text = _format_measure(value)
    if "." not in text and "e" not in text and "E" not in text:
        text += "."
    return real(text.replace("e", "*^").replace("E", "*^"))


def _decimal_measure_expr(value: Decimal | int | float) -> Expr:
    measure = _measure_decimal(value)
    if measure.is_finite() and measure == measure.to_integral_value():
        return integer(int(measure))
    return real(_format_measure(measure))


def _format_decimal(value: Decimal) -> str:
    if value.is_zero():
        return "0."
    adjusted = value.adjusted()
    if adjusted >= 16 or adjusted <= -6:
        text = format(value, "E")
        mantissa, exponent = text.split("E")
        exponent_value = int(exponent)
        mantissa = _trim_trailing_decimal_zeros(mantissa)
        return f"{mantissa}*^{exponent_value}"
    text = format(value, "f")
    if "." not in text:
        text += "."
    return text


def _mark_formatted_decimal(text: str, marker: str) -> str:
    if "*^" not in text:
        return f"{text}{marker}"
    mantissa, exponent = text.split("*^", 1)
    return f"{mantissa}{marker}*^{exponent}"


def _trim_trailing_decimal_zeros(text: str) -> str:
    if "." not in text:
        return text
    return text.rstrip("0").rstrip(".")


def _measure_decimal(value: Decimal | int | float | str) -> Decimal:
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _format_measure(value: Decimal | int | float) -> str:
    measure = _display_measure(value)
    if measure.is_infinite():
        return "Infinity" if measure > 0 else "-Infinity"
    if measure.is_zero():
        return "0"
    if measure != measure.to_integral_value():
        with localcontext() as context:
            context.prec = 18
            measure = +measure
    text = format(measure, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


def _display_measure(value: Decimal | int | float) -> Decimal:
    measure = _measure_decimal(value)
    if not measure.is_finite():
        return measure
    nearest = measure.to_integral_value()
    if abs(measure - nearest) <= Decimal("1e-7"):
        return nearest
    return measure


def _bounded_int(value: Decimal | int | float, *, cap: int = MAX_WORKING_PRECISION) -> int:
    measure = _measure_decimal(value)
    if not measure.is_finite():
        return cap
    if measure <= 0:
        return 0
    ceiling = measure.to_integral_value(rounding=ROUND_CEILING)
    if ceiling > cap:
        return cap
    return int(ceiling)


def _context_precision_from_measure(
    measure: Decimal | int | float | None,
    *,
    session: EvaluationSession | None = None,
    cap: int | None = None,
) -> int:
    if measure is None:
        return DEFAULT_PRECISION
    value = _measure_decimal(measure)
    if not value.is_finite() or value <= 0:
        return 1
    limit = cap if cap is not None else _current_max_displayed_digits(session)
    return max(1, _bounded_int(value, cap=limit))


def _measure_exceeds_working_precision(
    measure: Decimal | int | float,
    *,
    session: EvaluationSession | None = None,
) -> bool:
    value = _measure_decimal(measure)
    return value.is_finite() and value > Decimal(_current_max_displayed_digits(session))


def _configure_decimal_context(context, precision: int, *values: Decimal) -> None:
    context.prec = max(precision, 1)
    for value in values:
        if value.is_finite() and not value.is_zero():
            adjusted = value.adjusted()
            context.Emax = max(context.Emax, adjusted + context.prec + 8)
            context.Emin = min(context.Emin, adjusted - context.prec - 8)


def _decimal_for_fraction(value: Fraction, precision: int) -> Decimal:
    with localcontext() as context:
        context.prec = max(precision, 1)
        _configure_decimal_context(context, precision, Decimal(value.numerator), Decimal(value.denominator))
        return Decimal(value.numerator) / Decimal(value.denominator)


def _small_exact_fraction_from_decimal(value: Decimal) -> Fraction | None:
    if not value.is_finite():
        return None
    if value.is_zero():
        return Fraction(0)
    if abs(value.adjusted()) > MAX_COMPACT_DECIMAL_PRECISION:
        return None
    digits = len(value.as_tuple().digits)
    if digits > MAX_COMPACT_DECIMAL_PRECISION:
        return None
    return Fraction(value)


def _working_precision_for_exact_fraction(value: Fraction) -> int:
    return max(
        DEFAULT_PRECISION,
        len(str(abs(value.numerator))),
        len(str(abs(value.denominator))),
    )


def _materialized_radius(accuracy: Decimal | int | float) -> Decimal | None:
    accuracy_measure = _measure_decimal(accuracy)
    if accuracy_measure == Decimal("Infinity"):
        return Decimal(0)
    if accuracy_measure == Decimal("-Infinity"):
        return Decimal("Infinity")
    if abs(accuracy_measure) > MAX_WORKING_PRECISION:
        return None
    with localcontext() as context:
        context.prec = _guarded_precision(max(DEFAULT_PRECISION, _context_precision_from_measure(abs(accuracy_measure)) + 4))
        exponent_bound = _bounded_int(abs(accuracy_measure), cap=MAX_WORKING_PRECISION) + 100
        context.Emax = max(context.Emax, exponent_bound)
        context.Emin = min(context.Emin, -exponent_bound)
        return +(Decimal(10) ** (-accuracy_measure))


def _accuracy_from_radius(radius: Decimal) -> Decimal:
    if radius.is_zero():
        return Decimal("Infinity")
    return -_decimal_log10_abs(radius)


def _precision_from_accuracy(center: Decimal, accuracy: Decimal | int | float) -> Decimal:
    accuracy_measure = _measure_decimal(accuracy)
    if center.is_zero():
        return Decimal(0)
    return accuracy_measure + _decimal_log10_abs(center)


def _accuracy_from_precision(center: Decimal, precision: Decimal | int | float) -> Decimal:
    precision_measure = _measure_decimal(precision)
    if center.is_zero():
        return precision_measure
    return precision_measure - _decimal_log10_abs(center)


def _accuracy_from_precision_fraction(center: Fraction, precision: Decimal | int | float) -> Decimal:
    precision_measure = _measure_decimal(precision)
    if center == 0:
        return precision_measure
    return precision_measure - _decimal_log10_abs_fraction(center)


def _decimal_log10_abs_fraction(value: Fraction) -> Decimal:
    if value == 0:
        return Decimal("-Infinity")
    return _decimal_log10_abs(_decimal_for_fraction(abs(value), DEFAULT_PRECISION + 50))


def _decimal_rounding_radius(value: Decimal, precision: int) -> Decimal:
    if not value.is_finite() or value.is_zero():
        return Decimal(0)
    exponent = value.adjusted() - max(precision, 1)
    with localcontext() as context:
        _configure_decimal_context(context, _guarded_precision(max(precision, 1)), value)
        return +(Decimal("0.5") * (Decimal(10) ** exponent))


def _round_decimal(value: Decimal, precision: int) -> Decimal:
    with localcontext() as context:
        _configure_decimal_context(context, max(precision, 1), value)
        return +value


def _guarded_precision(precision: int) -> int:
    precision = max(precision, 1)
    return precision + max(8, precision // 10)


def _matching_precision(left: Decimal, right: Decimal, max_precision: int) -> int:
    if max_precision <= 0:
        return 0
    if not left.is_finite() or not right.is_finite():
        return max(1, max_precision)
    for precision in range(max(1, max_precision), 0, -1):
        if _round_decimal(left, precision) == _round_decimal(right, precision):
            return precision
    return 1


@dataclass(frozen=True)
class RealInfo:
    value: Decimal
    kind: str
    precision: Decimal
    accuracy: Decimal


_REAL_RE = re.compile(
    r"^(?P<mantissa>[+-]?(?:\d+(?:\.\d*)?|\.\d+))"
    r"(?P<mark>`{1,2}(?P<digits>[+-]?(?:\d+(?:\.\d*)?|\.\d+)?)?)?"
    r"(?P<magnitude>\*\^[+-]?\d+)?$"
)


def _real_info_for_expr(expr: Expr) -> RealInfo | None:
    return _real_info(expr) if isinstance(expr, Real) else None


def _real_info(expr: Real) -> RealInfo | None:
    match = _REAL_RE.match(expr.text)
    if match is None:
        return None
    mantissa = match.group("mantissa")
    magnitude = match.group("magnitude")
    exponent = int(magnitude[2:]) if magnitude else 0
    value = _decimal_literal_value(mantissa, exponent)
    mark = match.group("mark")
    if not mark:
        precision = _literal_precision(mantissa, DEFAULT_PRECISION)
        return RealInfo(
            value=value,
            kind="precision",
            precision=precision,
            accuracy=_accuracy_from_precision(value, precision),
        )
    digits = match.group("digits") or ""
    if mark.startswith("``"):
        accuracy = _measure_decimal(digits) if digits else _accuracy_from_precision(value, Decimal(DEFAULT_PRECISION))
        return RealInfo(
            value=value,
            kind="accuracy",
            precision=_precision_from_accuracy(value, accuracy),
            accuracy=accuracy,
        )
    precision = _measure_decimal(digits) if digits else Decimal(DEFAULT_PRECISION)
    return RealInfo(
        value=value,
        kind="precision",
        precision=precision,
        accuracy=_accuracy_from_precision(value, precision),
    )


def _decimal_literal_value(mantissa: str, exponent: int) -> Decimal:
    digit_count = _literal_digit_count(mantissa)
    with localcontext() as context:
        context.prec = max(digit_count, 1)
        return +(Decimal(mantissa) * (Decimal(10) ** exponent))


def _literal_precision(mantissa: str, floor: Decimal | int) -> Decimal:
    return max(_measure_decimal(floor), Decimal(_literal_digit_count(mantissa)))


def _literal_digit_count(mantissa: str) -> int:
    digits = "".join(char for char in mantissa if char.isdigit())
    significant_digits = digits.lstrip("0")
    return len(significant_digits) if significant_digits else 1


def _combined_precision(args: tuple[Expr, ...] | list[Expr]) -> int | None:
    precisions: list[int] = []
    for argument in args:
        if _exact_fraction(argument) is not None:
            continue
        info = _real_info_for_expr(argument)
        if info is None:
            return None
        precisions.append(_context_precision_from_measure(info.precision))
    return min(precisions) if precisions else None


def _contains_inexact(expr: Expr) -> bool:
    if isinstance(expr, Real):
        return True
    if _certified_interval_for_expr(expr) is not None:
        return True
    if isinstance(expr, Call):
        return any(_contains_inexact(argument) for argument in expr.args)
    return False


def _all_approximable(args: tuple[Expr, ...] | list[Expr]) -> bool:
    return all(_decimal_for_expr(argument, DEFAULT_PRECISION) is not None for argument in args)


def _precision_argument(expr: Expr) -> Decimal | None | float:
    exact = _exact_fraction(expr)
    if exact is not None:
        value = Decimal(exact.numerator) if exact.denominator == 1 else Decimal(int(exact))
        return max(Decimal(1), value)
    if isinstance(expr, Real):
        info = _real_info(expr)
        return max(Decimal(1), info.value) if info is not None else None
    if isinstance(expr, Symbol):
        if expr.name == "MachinePrecision":
            return Decimal(DEFAULT_PRECISION)
        if expr.name == "Infinity":
            return math.inf
    return None


def _decimal_log10_abs(value: Decimal | None) -> Decimal:
    if value is None:
        return Decimal(0)
    if value.is_zero():
        return Decimal("-Infinity")
    adjusted = value.adjusted()
    with localcontext() as context:
        context.prec = 50
        context.Emax = max(context.Emax, abs(adjusted) + 100)
        context.Emin = min(context.Emin, -abs(adjusted) - 100)
        leading = abs(value).scaleb(-adjusted)
        _configure_decimal_context(context, 50, leading)
        return +(Decimal(adjusted) + leading.ln() / _decimal_ln10(context.prec))


def _decimal_ln10(precision: int = 50) -> Decimal:
    with localcontext() as context:
        context.prec = max(precision, 1)
        return +Decimal(10).ln()


def _exact_fraction(expr: Expr) -> Fraction | None:
    if isinstance(expr, Integer):
        return Fraction(expr.value, 1)
    if isinstance(expr, Rational):
        return expr.value
    return None


def _is_exact_one(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    return exact == 1 if exact is not None else False


def _fraction_expr(value: Fraction) -> Expr:
    return rational(value.numerator, value.denominator)


def _exact_from_decimal(expr: Expr) -> Expr | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return _fraction_expr(exact)
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return None
        return _fraction_expr(Fraction(info.value))
    return None


def _is_numeric_atom(expr: Expr) -> bool:
    return isinstance(expr, (Integer, Rational, Real)) or _scale_parts(expr) is not None or _certified_interval_for_expr(expr) is not None


def _is_zero(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact == 0
    scale = _scale_parts(expr)
    if scale is not None:
        return _is_zero(scale.mantissa)
    certified = _certified_interval_for_expr(expr)
    if certified is not None:
        return certified.center == 0
    info = _real_info_for_expr(expr)
    return info is not None and info.value == 0


def _is_one(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact == 1
    scale = _scale_parts(expr)
    if scale is not None:
        return _is_one(scale.mantissa) and _is_zero(scale.exponent)
    certified = _certified_interval_for_expr(expr)
    if certified is not None:
        return certified.center == 1
    info = _real_info_for_expr(expr)
    return info is not None and info.value == 1


def _undefined(session: EvaluationSession | None, message: str) -> Symbol:
    if session is not None:
        session.emit_error(message)
    return _UNDEFINED


def _error_null(session: EvaluationSession | None, message: str) -> Symbol:
    if session is not None:
        session.emit_error(message)
    return _NULL


def _is_predefined_symbol_name(name: str) -> bool:
    return name in _PREDEFINED_SYMBOL_NAMES


def _is_undefined(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Undefined"


def _any_undefined(args: tuple[Expr, ...] | list[Expr]) -> bool:
    return any(_is_undefined(argument) for argument in args)


def _numeric_sign(expr: Expr) -> int | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return (exact > 0) - (exact < 0)
    scale = _scale_parts(expr)
    if scale is not None:
        return _numeric_sign(scale.mantissa)
    certified = _certified_interval_for_expr(expr)
    if certified is not None:
        return (certified.center > 0) - (certified.center < 0)
    info = _real_info_for_expr(expr)
    if info is not None:
        return (info.value > 0) - (info.value < 0)
    return None


def _is_negative_number(expr: Expr) -> bool:
    sign = _numeric_sign(expr)
    return sign is not None and sign < 0


def _is_positive_number(expr: Expr) -> bool:
    sign = _numeric_sign(expr)
    return sign is not None and sign > 0


def _is_integer_number(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact.denominator == 1
    if _scale_parts(expr) is not None:
        return False
    info = _real_info_for_expr(expr)
    if info is None:
        return False
    return info.value == info.value.to_integral_value()


def _truth(expr: Expr) -> bool | None:
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
    return None


def _bool(value: bool) -> Symbol:
    return _TRUE if value else _FALSE


def _current_precision_measure(session: EvaluationSession | None) -> Decimal:
    if session is not None and session.precision_override is not None:
        return max(Decimal(1), session.precision_override)
    value: Expr | None = None
    if session is not None and session.symbols is not None:
        value = session.symbols.get("$Precision")
    precision = _precision_argument(value) if value is not None else Decimal(DEFAULT_PRECISION)
    if precision is None or precision == math.inf:
        return Decimal(DEFAULT_PRECISION)
    return max(Decimal(1), _measure_decimal(precision))


def _current_precision(session: EvaluationSession | None) -> int:
    return _context_precision_from_measure(_current_precision_measure(session), session=session)


def _current_max_direct_decimal_exponent(session: EvaluationSession | None) -> int:
    value: Expr | None = None
    if session is not None and session.symbols is not None:
        value = session.symbols.get("$MaxDirectDecimalExponent")
    limit = _precision_argument(value) if value is not None else MAX_DIRECT_DECIMAL_EXPONENT
    if limit is None or limit == math.inf:
        return MAX_DIRECT_DECIMAL_EXPONENT
    return max(0, _bounded_int(_measure_decimal(limit), cap=10_000_000))


def _current_max_displayed_digits(session: EvaluationSession | None) -> int:
    value: Expr | None = None
    if session is not None and session.symbols is not None:
        value = session.symbols.get("$MaxDisplayedDigits")
    limit = _precision_argument(value) if value is not None else Decimal(MAX_COMPACT_DECIMAL_PRECISION)
    if limit is None or limit == math.inf:
        return MAX_COMPACT_DECIMAL_PRECISION
    return max(1, _bounded_int(_measure_decimal(limit), cap=MAX_WORKING_PRECISION))


def _reported_precision(precision: Decimal | int | float | None) -> int:
    if precision is None:
        return DEFAULT_PRECISION
    return _context_precision_from_measure(precision)


def _scale_exponent_is_exact(expr: Expr) -> bool:
    if _exact_fraction(expr) is not None:
        return True
    if isinstance(expr, Call):
        return all(_scale_exponent_is_exact(argument) for argument in expr.args)
    return False
