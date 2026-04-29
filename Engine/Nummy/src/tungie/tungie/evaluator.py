from __future__ import annotations

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
_MACHINE_PRECISION_SYMBOL = symbol("MachinePrecision")
_INFINITY = symbol("Infinity")
_NEGATIVE_INFINITY = call("Times", integer(-1), _INFINITY)
_TRUE = symbol("True")
_FALSE = symbol("False")
_NULL = symbol("Null")
_INDETERMINATE = symbol("Indeterminate")
_COMPLEX_INFINITY = symbol("ComplexInfinity")

_PI_DIGITS = "3.14159265358979323846264338327950288419716939937510582097494459230781640628620899"
_E_DIGITS = "2.71828182845904523536028747135266249775724709369995957496696762772407663035354759"


@dataclass
class EvaluationSession:
    line: int = 0
    symbols: dict[str, Expr] | None = None
    outputs: dict[int, Expr] | None = None

    def __post_init__(self) -> None:
        if self.symbols is None:
            self.symbols = {}
        if self.outputs is None:
            self.outputs = {}

    def evaluate_input(self, expr: Expr) -> tuple[int, Expr]:
        self.line += 1
        result = evaluate(expr, session=self)
        if not _is_null(result):
            assert self.outputs is not None
            self.outputs[self.line] = result
        return self.line, result

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
        if session is None:
            raise TungieEvaluationError("Assignments require an evaluation session.")
        value = evaluate(expr.value, session=session)
        assert session.symbols is not None
        session.symbols[expr.name] = value
        return value

    if isinstance(expr, (Integer, Rational, Real)):
        return expr

    if isinstance(expr, Symbol):
        return _evaluate_symbol(expr, session)

    if isinstance(expr, Call):
        return _evaluate_call(expr, session=session)

    return expr


def _evaluate_symbol(expr: Symbol, session: EvaluationSession | None) -> Expr:
    if expr.name == "$MachinePrecision":
        return real(repr(MACHINE_PRECISION))
    if expr.name == "$MachineEpsilon":
        return real("2.220446049250313*^-16")
    if expr.name == "$MaxMachineNumber":
        return real("1.7976931348623157*^+308")
    if expr.name == "$MinMachineNumber":
        return real("2.2250738585072014*^-308")
    if expr.name == "Degree":
        return call("Times", rational(1, 180), symbol("Pi"))
    if session is not None and session.symbols is not None and expr.name in session.symbols:
        return session.symbols[expr.name]
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

    evaluated_args = tuple(evaluate(argument, session=session) for argument in expr.args)

    if head_name == "List":
        return list_expr(evaluated_args)
    if head_name == "Rational":
        return _rational_constructor(evaluated_args)
    if head_name == "Plus":
        return _plus(evaluated_args, session=session)
    if head_name == "Times":
        return _times(evaluated_args, session=session)
    if head_name == "Power":
        return _power(evaluated_args, session=session)
    if head_name in {"Equal", "Unequal", "Less", "LessEqual", "Greater", "GreaterEqual"}:
        return _relation(head_name, evaluated_args)
    if head_name == "Abs":
        return _abs(evaluated_args)
    if head_name == "Sign":
        return _sign(evaluated_args)
    if head_name in {"Floor", "Ceiling", "Round", "IntegerPart", "FractionalPart"}:
        return _rounding(head_name, evaluated_args)
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
            session.symbols.pop(argument.name, None)
    return _NULL


def _if(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) not in {2, 3, 4}:
        return call("If", *args)
    condition = evaluate(args[0], session=session)
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


def _rational_constructor(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 2 or not isinstance(args[0], Integer) or not isinstance(args[1], Integer):
        return call("Rational", *args)
    if args[1].value == 0:
        if args[0].value == 0:
            return _INDETERMINATE
        return _COMPLEX_INFINITY
    return rational(args[0].value, args[1].value)


def _plus(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if threaded := _thread_listable("Plus", args, session=session):
        return threaded
    flattened = _flatten("Plus", args)
    if _all_approximable(flattened) and any(_contains_inexact(argument) for argument in flattened):
        result = _inexact_result(
            flattened,
            lambda values: sum(values, values[0] * 0),
            lambda values: sum(values),
        )
        if result is not None:
            return result

    numeric: Expr = integer(0)
    non_numeric: list[Expr] = []
    saw_numeric = False
    for argument in flattened:
        if _is_numeric_atom(argument):
            combined = _add_numeric(numeric, argument)
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
    if threaded := _thread_listable("Times", args, session=session):
        return threaded
    flattened = _flatten("Times", args)
    if _all_approximable(flattened) and any(_contains_inexact(argument) for argument in flattened):
        def operation(values: list[Decimal]) -> Decimal:
            product = Decimal(1)
            for value in values:
                product *= value
            return product

        def machine_operation(values: list[float]) -> float:
            product = 1.0
            for value in values:
                product *= value
            return product

        result = _inexact_result(flattened, operation, machine_operation)
        if result is not None:
            return result

    numeric: Expr = integer(1)
    non_numeric: list[Expr] = []
    saw_numeric = False
    for argument in flattened:
        if _is_numeric_atom(argument):
            combined = _mul_numeric(numeric, argument)
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


def _power(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("Power", *args)
    base, exponent = args
    if threaded := _thread_listable("Power", args, session=session):
        return threaded
    if _is_zero(exponent):
        return _INDETERMINATE if _is_zero(base) else integer(1)
    if _is_one(exponent):
        return base
    if _is_one(base):
        return integer(1)

    exact_base = _exact_fraction(base)
    exact_exponent = _exact_fraction(exponent)
    if exact_base is not None and exact_exponent is not None:
        exact = _exact_power(exact_base, exact_exponent)
        if exact is not None:
            return _fraction_expr(exact)
        return call("Power", _fraction_expr(exact_base), _fraction_expr(exact_exponent))

    if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
        result = _inexact_result(args, _decimal_power, lambda values: math.pow(values[0], values[1]))
        if result is not None:
            return result

    return call("Power", base, exponent)


def _relation(head: str, args: tuple[Expr, ...]) -> Expr:
    if len(args) != 2:
        return call(head, *args)
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
    value = args[0]
    exact = _exact_fraction(value)
    if exact is not None:
        return _fraction_expr(abs(exact))
    real_info = _real_info_for_expr(value)
    if real_info is not None:
        if real_info.kind == "machine":
            return _machine_real(abs(float(real_info.value)))
        return _decimal_real(abs(real_info.value), max(1, int(real_info.precision or MACHINE_PRECISION)))
    return call("Abs", value)


def _sign(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call("Sign", *args)
    comparison = _compare(args[0], integer(0))
    if comparison is None:
        return call("Sign", args[0])
    return integer((comparison > 0) - (comparison < 0))


def _rounding(head: str, args: tuple[Expr, ...]) -> Expr:
    if len(args) not in {1, 2}:
        return call(head, *args)
    if len(args) == 2 and head not in {"Floor", "Ceiling", "Round"}:
        return call(head, *args)
    value = args[0]
    multiple = args[1] if len(args) == 2 else integer(1)
    if len(args) == 2:
        quotient = _div_numeric(value, multiple)
        if quotient is None:
            return call(head, *args)
        rounded = _rounding(head, (quotient,))
        return _mul_numeric(rounded, multiple) or call(head, *args)

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
    if info.kind == "machine":
        return _machine_real(float(info.value) - float(integer_part))
    precision = max(1, int(info.precision or MACHINE_PRECISION))
    return _decimal_real(info.value - integer_part, precision)


def _min_max(head: str, args: tuple[Expr, ...]) -> Expr:
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
    return _power((args[0], rational(1, 2)), session=session)


def _exp(args: tuple[Expr, ...]) -> Expr:
    if len(args) != 1:
        return call("Exp", *args)
    value = args[0]
    if _is_zero(value):
        return integer(1)
    if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
        result = _inexact_result(args, lambda values: values[0].exp(), lambda values: math.exp(values[0]))
        if result is not None:
            return result
    if _is_one(value):
        return symbol("E")
    return call("Exp", value)


def _log(args: tuple[Expr, ...]) -> Expr:
    if len(args) not in {1, 2}:
        return call("Log", *args)
    if len(args) == 1:
        value = args[0]
        if _is_one(value):
            return integer(0)
        if isinstance(value, Symbol) and value.name == "E":
            return integer(1)
        if _all_approximable(args) and any(_contains_inexact(argument) for argument in args):
            result = _inexact_result(args, lambda values: values[0].ln(), lambda values: math.log(values[0]))
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
        result = _inexact_result(
            args,
            lambda values: values[1].ln() / values[0].ln(),
            lambda values: math.log(values[1], values[0]),
        )
        if result is not None:
            return result
    return call("Log", base, value)


def _n(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) not in {1, 2}:
        return call("N", *args)
    expr = evaluate(args[0], session=session)
    precision = None
    if len(args) == 2:
        precision = _precision_argument(evaluate(args[1], session=session))
        if precision == math.inf:
            return expr
    return _approximate(expr, precision)


def _set_precision(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("SetPrecision", *args)
    expr = evaluate(args[0], session=session)
    precision = _precision_argument(evaluate(args[1], session=session))
    if precision is None:
        return _approximate(expr, None)
    if precision == math.inf:
        exact = _exact_from_decimal(expr)
        return exact if exact is not None else expr
    decimal_value = _decimal_for_expr(expr, int(precision))
    if decimal_value is None:
        return call("SetPrecision", expr, args[1])
    return _decimal_real(decimal_value, int(precision))


def _set_accuracy(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 2:
        return call("SetAccuracy", *args)
    expr = evaluate(args[0], session=session)
    accuracy = _precision_argument(evaluate(args[1], session=session))
    if accuracy is None:
        return _approximate(expr, None)
    if accuracy == math.inf:
        exact = _exact_from_decimal(expr)
        return exact if exact is not None else expr
    precision = max(1, int(accuracy + max(_decimal_log10_abs(_decimal_for_expr(expr, int(accuracy) + 8)), 0)))
    decimal_value = _decimal_for_expr(expr, precision)
    if decimal_value is None:
        return call("SetAccuracy", expr, args[1])
    return _decimal_real_accuracy(decimal_value, int(accuracy))


def _precision(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Precision", *args)
    value = evaluate(args[0], session=session)
    if _exact_fraction(value) is not None:
        return _INFINITY
    info = _real_info_for_expr(value)
    if info is None:
        return call("Precision", value)
    if info.kind == "machine":
        return _MACHINE_PRECISION_SYMBOL
    return real(f"{float(info.precision or MACHINE_PRECISION):g}.")


def _accuracy(args: tuple[Expr, ...], *, session: EvaluationSession | None) -> Expr:
    if len(args) != 1:
        return call("Accuracy", *args)
    value = evaluate(args[0], session=session)
    if _exact_fraction(value) is not None:
        return _INFINITY
    info = _real_info_for_expr(value)
    if info is None:
        return call("Accuracy", value)
    if info.kind == "accuracy" and info.accuracy is not None:
        return real(f"{float(info.accuracy):g}.")
    precision = info.precision if info.precision is not None else MACHINE_PRECISION
    return _machine_real(precision - _decimal_log10_abs(info.value))


def _rationalize(args: tuple[Expr, ...]) -> Expr:
    if len(args) not in {1, 2}:
        return call("Rationalize", *args)
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
        info = _real_info_for_expr(value)
        return _bool(info is not None and info.kind == "machine")
    if head == "ExactNumberQ":
        return _bool(_exact_fraction(value) is not None)
    if head == "InexactNumberQ":
        return _bool(isinstance(value, Real))
    if head == "RealValuedNumberQ":
        return _bool(_is_numeric_atom(value))
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


def _add_numeric(left: Expr, right: Expr) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return _fraction_expr(left_exact + right_exact)
    return _inexact_result((left, right), lambda values: values[0] + values[1], lambda values: values[0] + values[1])


def _mul_numeric(left: Expr, right: Expr) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        return _fraction_expr(left_exact * right_exact)
    return _inexact_result((left, right), lambda values: values[0] * values[1], lambda values: values[0] * values[1])


def _div_numeric(left: Expr, right: Expr) -> Expr | None:
    left_exact = _exact_fraction(left)
    right_exact = _exact_fraction(right)
    if left_exact is not None and right_exact is not None:
        if right_exact == 0:
            return _INDETERMINATE if left_exact == 0 else _COMPLEX_INFINITY
        return _fraction_expr(left_exact / right_exact)
    return _inexact_result((left, right), lambda values: values[0] / values[1], lambda values: values[0] / values[1])


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
    if value < 0:
        return None
    if value in {0, 1}:
        return value
    candidate = round(value ** (1 / root))
    for nearby in range(max(candidate - 2, 0), candidate + 3):
        if nearby ** root == value:
            return nearby
    return None


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
    if _all_approximable((left, right)):
        left_value = _decimal_for_expr(left, 50)
        right_value = _decimal_for_expr(right, 50)
        if left_value is not None and right_value is not None:
            return (left_value > right_value) - (left_value < right_value)
    if left == right:
        return 0
    return None


def _approximate(expr: Expr, precision: int | None) -> Expr:
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(_approximate(argument, precision) for argument in expr.args)
    if precision is None:
        value = _float_for_expr(expr)
        return _machine_real(value) if value is not None else expr
    value = _decimal_for_expr(expr, precision)
    return _decimal_real(value, precision) if value is not None else expr


def _inexact_result(args: tuple[Expr, ...] | list[Expr], operation, machine_operation=None) -> Expr | None:
    if any(_contains_machine_real(argument) for argument in args):
        values = [_float_for_expr(argument) for argument in args]
        if any(value is None for value in values):
            return None
        if machine_operation is not None:
            try:
                return _machine_real(float(machine_operation([float(value) for value in values if value is not None])))
            except (ArithmeticError, ValueError, OverflowError):
                return None
        try:
            decimal_values = [Decimal(str(value)) for value in values if value is not None]
            result = operation(decimal_values)
            return _machine_real(float(result))
        except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
            return None

    precision = _combined_precision(args)
    if precision is None:
        return None
    values = [_decimal_for_expr(argument, precision) for argument in args]
    if any(value is None for value in values):
        return None
    assert all(value is not None for value in values)
    try:
        with localcontext() as context:
            context.prec = max(precision, 1)
            result = +operation(list(values))
        return _decimal_real(result, precision)
    except (ArithmeticError, InvalidOperation, ValueError, OverflowError):
        return None


def _decimal_for_expr(expr: Expr, precision: int) -> Decimal | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        with localcontext() as context:
            context.prec = max(precision, 1)
            return Decimal(exact.numerator) / Decimal(exact.denominator)
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
                return +_decimal_power([value for value in values if value is not None])
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


def _float_for_expr(expr: Expr) -> float | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return float(exact)
    if isinstance(expr, Real):
        info = _real_info(expr)
        return float(info.value) if info is not None else None
    if isinstance(expr, Symbol):
        if expr.name == "Pi":
            return math.pi
        if expr.name == "E":
            return math.e
        if expr.name == "MachinePrecision":
            return MACHINE_PRECISION
    decimal_value = _decimal_for_expr(expr, 17)
    return float(decimal_value) if decimal_value is not None else None


def _decimal_constant(text: str, precision: int) -> Decimal:
    with localcontext() as context:
        context.prec = max(precision, 1)
        return +Decimal(text)


def _machine_real(value: float) -> Expr:
    if math.isnan(value):
        return _INDETERMINATE
    if math.isinf(value):
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    text = repr(float(value))
    if text.endswith(".0"):
        text = text[:-2] + "."
    text = text.replace("e", "*^").replace("E", "*^")
    if "." not in text and "*^" not in text:
        text += "."
    return real(text)


def _decimal_real(value: Decimal, precision: int) -> Expr:
    if not value.is_finite():
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    text = format(value, "f")
    if "." not in text:
        text += "."
    return real(f"{text}`{precision}.")


def _decimal_real_accuracy(value: Decimal, accuracy: int) -> Expr:
    if not value.is_finite():
        return symbol("Infinity") if value > 0 else call("Times", integer(-1), symbol("Infinity"))
    text = format(value, "f")
    if "." not in text:
        text += "."
    return real(f"{text}``{accuracy}.")


@dataclass(frozen=True)
class RealInfo:
    value: Decimal
    kind: str
    precision: float | None = None
    accuracy: float | None = None


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
    value = Decimal(mantissa) * (Decimal(10) ** exponent)
    mark = match.group("mark")
    if not mark:
        return RealInfo(value=value, kind="machine", precision=MACHINE_PRECISION)
    digits = match.group("digits") or ""
    if mark.startswith("``"):
        accuracy = float(digits) if digits else MACHINE_PRECISION - _decimal_log10_abs(value)
        return RealInfo(value=value, kind="accuracy", precision=accuracy + _decimal_log10_abs(value), accuracy=accuracy)
    precision = float(digits) if digits else MACHINE_PRECISION
    return RealInfo(value=value, kind="precision", precision=precision)


def _combined_precision(args: tuple[Expr, ...] | list[Expr]) -> int | None:
    precisions: list[int] = []
    for argument in args:
        if _exact_fraction(argument) is not None:
            continue
        info = _real_info_for_expr(argument)
        if info is None:
            return None
        if info.kind == "machine":
            return None
        precisions.append(max(1, int(info.precision or MACHINE_PRECISION)))
    return min(precisions) if precisions else None


def _contains_inexact(expr: Expr) -> bool:
    if isinstance(expr, Real):
        return True
    if isinstance(expr, Call):
        return any(_contains_inexact(argument) for argument in expr.args)
    return False


def _contains_machine_real(expr: Expr) -> bool:
    if isinstance(expr, Real):
        info = _real_info(expr)
        return info is not None and info.kind == "machine"
    if isinstance(expr, Call):
        return any(_contains_machine_real(argument) for argument in expr.args)
    return False


def _all_approximable(args: tuple[Expr, ...] | list[Expr]) -> bool:
    return all(_float_for_expr(argument) is not None for argument in args)


def _precision_argument(expr: Expr) -> int | None | float:
    if isinstance(expr, Integer):
        return max(1, expr.value)
    if isinstance(expr, Real):
        info = _real_info(expr)
        return max(1, int(info.value)) if info is not None else None
    if isinstance(expr, Symbol):
        if expr.name == "MachinePrecision":
            return None
        if expr.name == "Infinity":
            return math.inf
    return None


def _decimal_log10_abs(value: Decimal | None) -> float:
    if value is None:
        return 0.0
    if value.is_zero():
        return -math.inf
    try:
        return math.log10(abs(float(value)))
    except (OverflowError, ValueError):
        adjusted = value.adjusted()
        leading = value.scaleb(-adjusted)
        return adjusted + math.log10(abs(float(leading)))


def _exact_fraction(expr: Expr) -> Fraction | None:
    if isinstance(expr, Integer):
        return Fraction(expr.value, 1)
    if isinstance(expr, Rational):
        return expr.value
    return None


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
    return isinstance(expr, (Integer, Rational, Real))


def _is_zero(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact == 0
    info = _real_info_for_expr(expr)
    return info is not None and info.value == 0


def _is_one(expr: Expr) -> bool:
    exact = _exact_fraction(expr)
    if exact is not None:
        return exact == 1
    info = _real_info_for_expr(expr)
    return info is not None and info.value == 1


def _truth(expr: Expr) -> bool | None:
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
    return None


def _bool(value: bool) -> Symbol:
    return _TRUE if value else _FALSE


def _is_null(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Null"
