from __future__ import annotations

from fractions import Fraction
from typing import Any, Sequence

import sympy as _sp
from sympy.polys.rootoftools import ComplexRootOf as _ComplexRootOf

from . import expression as _runtime

globals().update(
    {name: getattr(_runtime, name) for name in dir(_runtime) if not name.startswith("__")}
)

_X = _sp.Symbol("x")
_Y = _sp.Symbol("y")
_T = _sp.Symbol("t")
_ALGEBRAIC_ROOT_VARIABLE = _sp.Symbol("w")
_ROOT_COEFFICIENT_SYMBOL = _sp.Symbol("z")


class _AlgebraicConversionError(ValueError):
    """Raised when an expression is outside Tungsten's algebraic subset."""


def _evaluate_algebraic_functions(expr: Call) -> Expr | None:
    try:
        if expr.has_head("Root"):
            return _root_expr(expr.arguments)
        if expr.has_head("RootReduce"):
            return _root_reduce_expr(expr.arguments)
        if expr.has_head("MinimalPolynomial"):
            return _minimal_polynomial_expr(expr.arguments)
        if expr.has_head("Arg"):
            return _arg_expr(expr.arguments)
        if expr.has_head("ReIm"):
            return _re_im_expr(expr.arguments)
        if expr.has_head("ComplexExpand"):
            return _complex_expand_expr(expr.arguments)
    except Exception:
        # Algebraic-number conversion is intentionally best-effort. Unsupported or
        # unexpectedly hard cases must leave the expression inert, not crash the REPL.
        return None
    return None


def _root_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    if not isinstance(arguments[1], Integer):
        return None
    method = 0
    if len(arguments) == 3:
        if not isinstance(arguments[2], Integer):
            return None
        method = arguments[2].value
        if method not in {0, 1}:
            return None
    try:
        poly_expr = _polynomial_function_to_sympy(arguments[0], _X)
        index = arguments[1].value - 1
        if index < 0:
            return None
        _ensure_root_degree_allowed(_sp.Poly(poly_expr, _X).degree())
        root = _sp.CRootOf(poly_expr, index)
        return _expr_from_sympy_root_or_number(root, method=method)
    except Exception:
        pass
    try:
        return _algebraic_coefficient_root_expr(arguments[0], arguments[1].value - 1, method)
    except Exception:
        return None


def _root_reduce_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    expr = arguments[0]
    if isinstance(expr, Call) and expr.has_head("List"):
        return _evaluated_list_expr(*(_root_reduce_expr((argument,)) or argument for argument in expr.arguments))
    special = _root_reduce_special(expr)
    if special is not None:
        return special
    try:
        sym_expr = _to_sympy_algebraic(expr)
        return _root_reduce_sympy(sym_expr)
    except (_AlgebraicConversionError, _sp.PolynomialError, ValueError, NotImplementedError):
        return None


def _minimal_polynomial_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    variable = arguments[1] if len(arguments) == 2 else call("Slot", integer(1))
    try:
        sym_expr = _to_sympy_algebraic(arguments[0])
        poly_expr = _primitive_integer_poly_expr(_sp.minpoly(sym_expr, _X), _X)
        result = _polynomial_expr_from_sympy_poly(poly_expr, variable)
        return call("Function", result) if len(arguments) == 1 else result
    except (_AlgebraicConversionError, _sp.PolynomialError, ValueError, NotImplementedError):
        return None


def _arg_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    components = _complex_components_expr(arguments[0])
    if components is None:
        return None
    return _arg_from_components(*components)


def _re_im_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    components = _complex_components_expr(arguments[0])
    if components is None:
        return None
    return _evaluated_list_expr(*components)


def _complex_expand_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    return _complex_expand_scalar(arguments[0])


def _complex_expand_scalar(expr: Expr) -> Expr | None:
    if isinstance(expr, Call) and expr.has_head("List"):
        expanded_items = tuple(_complex_expand_scalar(argument) for argument in expr.arguments)
        if any(item is None for item in expanded_items):
            return None
        return _evaluated_list_expr(*(item for item in expanded_items if item is not None))
    components = _complex_components_expr(expr)
    if components is None:
        return None
    return _expr_from_components(*components)


def _complex_components_expr(expr: Expr) -> tuple[Expr, Expr] | None:
    if _is_exact_real_number(expr) or isinstance(expr, Real | SpecialReal):
        return expr, integer(0)
    if isinstance(expr, ComplexNumber):
        return expr.real_part, expr.imaginary_part
    if isinstance(expr, RootNumber):
        real = _component_expr(expr, "Re")
        imaginary = _component_expr(expr, "Im")
        if real is None or imaginary is None:
            return None
        return real, imaginary
    if _is_real_transcendental_expr(expr):
        return expr, integer(0)
    if isinstance(expr, Symbol):
        if _system_dispatch_name(expr) == "I":
            return integer(0), integer(1)
        return None
    if not isinstance(expr, Call):
        return None

    head_name = _system_dispatch_name(expr.head_expr) if isinstance(expr.head_expr, Symbol) else None
    if head_name == "Plus":
        components = tuple(_complex_components_expr(argument) for argument in expr.arguments)
        if any(component is None for component in components):
            return None
        real_terms = [component[0] for component in components if component is not None]
        imaginary_terms = [component[1] for component in components if component is not None]
        return _complex_simplify(call("Plus", *real_terms)), _complex_simplify(call("Plus", *imaginary_terms))
    if head_name == "Times":
        real_part: Expr = integer(1)
        imaginary_part: Expr = integer(0)
        for argument in expr.arguments:
            components = _complex_components_expr(argument)
            if components is None:
                return None
            real_part, imaginary_part = _complex_multiply_components(real_part, imaginary_part, *components)
        return real_part, imaginary_part
    if head_name == "Power" and len(expr.arguments) == 2:
        return _complex_power_components(expr.arguments[0], expr.arguments[1])
    if head_name == "Sqrt" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else _complex_sqrt_components(*components)
    if head_name == "Re" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else (components[0], integer(0))
    if head_name == "Im" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else (components[1], integer(0))
    if head_name == "Conjugate" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else (components[0], _complex_negate(components[1]))
    if head_name == "Abs" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else (_abs_from_components(*components), integer(0))
    if head_name == "Arg" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        return None if components is None else (_arg_from_components(*components), integer(0))
    if head_name == "Exp" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        if components is None:
            return None
        real, imaginary = components
        scale = _complex_simplify(call("Exp", real))
        return _complex_simplify(call("Times", scale, call("Cos", imaginary))), _complex_simplify(
            call("Times", scale, call("Sin", imaginary))
        )
    if head_name == "Log" and len(expr.arguments) == 1:
        components = _complex_components_expr(expr.arguments[0])
        if components is None:
            return None
        return _complex_simplify(call("Log", _abs_from_components(*components))), _arg_from_components(*components)
    if head_name == "Log" and len(expr.arguments) == 2:
        numerator = _complex_components_expr(call("Log", expr.arguments[1]))
        denominator = _complex_components_expr(call("Log", expr.arguments[0]))
        if numerator is None or denominator is None:
            return None
        return _complex_divide_components(*numerator, *denominator)
    if head_name in {"Sin", "Cos", "Sinh", "Cosh"} and len(expr.arguments) == 1:
        return _complex_direct_function_components(expr.arguments[0], head_name)

    rewritten = _complex_rewrite_elementary_call(head_name, expr.arguments)
    if rewritten is not None:
        return _complex_components_expr(rewritten)

    return None


def _complex_rewrite_elementary_call(head_name: str | None, arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    argument = arguments[0]
    if head_name == "Tan":
        return call("Times", call("Sin", argument), call("Power", call("Cos", argument), integer(-1)))
    if head_name == "Cot":
        return call("Times", call("Cos", argument), call("Power", call("Sin", argument), integer(-1)))
    if head_name == "Sec":
        return call("Power", call("Cos", argument), integer(-1))
    if head_name == "Csc":
        return call("Power", call("Sin", argument), integer(-1))
    if head_name == "Tanh":
        return call("Times", call("Sinh", argument), call("Power", call("Cosh", argument), integer(-1)))
    if head_name == "Coth":
        return call("Times", call("Cosh", argument), call("Power", call("Sinh", argument), integer(-1)))
    if head_name == "Sech":
        return call("Power", call("Cosh", argument), integer(-1))
    if head_name == "Csch":
        return call("Power", call("Sinh", argument), integer(-1))
    if head_name == "ArcSin":
        return call(
            "Times",
            integer(-1),
            symbol("I"),
            call("Log", call("Plus", call("Times", symbol("I"), argument), call("Sqrt", call("Plus", integer(1), call("Times", integer(-1), call("Power", argument, integer(2))))))),
        )
    if head_name == "ArcCos":
        return call("Plus", call("Times", rational_number(1, 2), symbol("Pi")), call("Times", integer(-1), call("ArcSin", argument)))
    if head_name == "ArcTan":
        return call(
            "Times",
            rational_number(1, 2),
            symbol("I"),
            call(
                "Plus",
                call("Log", call("Plus", integer(1), call("Times", integer(-1), symbol("I"), argument))),
                call("Times", integer(-1), call("Log", call("Plus", integer(1), call("Times", symbol("I"), argument)))),
            ),
        )
    if head_name == "ArcCot":
        return call("Plus", call("Times", rational_number(1, 2), symbol("Pi")), call("Times", integer(-1), call("ArcTan", argument)))
    if head_name == "ArcSec":
        return call("ArcCos", call("Power", argument, integer(-1)))
    if head_name == "ArcCsc":
        return call("ArcSin", call("Power", argument, integer(-1)))
    if head_name == "ArcSinh":
        return call("Log", call("Plus", argument, call("Sqrt", call("Plus", call("Power", argument, integer(2)), integer(1)))))
    if head_name == "ArcCosh":
        return call(
            "Log",
            call(
                "Plus",
                argument,
                call(
                    "Times",
                    call("Sqrt", call("Plus", argument, integer(1))),
                    call("Sqrt", call("Plus", argument, integer(-1))),
                ),
            ),
        )
    if head_name == "ArcTanh":
        return call(
            "Times",
            rational_number(1, 2),
            call("Plus", call("Log", call("Plus", integer(1), argument)), call("Times", integer(-1), call("Log", call("Plus", integer(1), call("Times", integer(-1), argument))))),
        )
    if head_name == "ArcCoth":
        return call("ArcTanh", call("Power", argument, integer(-1)))
    if head_name == "ArcSech":
        return call("ArcCosh", call("Power", argument, integer(-1)))
    if head_name == "ArcCsch":
        return call("ArcSinh", call("Power", argument, integer(-1)))
    if head_name == "Haversine":
        return call("Times", rational_number(1, 2), call("Plus", integer(1), call("Times", integer(-1), call("Cos", argument))))
    if head_name == "InverseHaversine":
        return call("Times", integer(2), call("ArcSin", call("Sqrt", argument)))
    if head_name == "Gudermannian":
        return call("Times", integer(2), call("ArcTan", call("Tanh", call("Times", rational_number(1, 2), argument))))
    if head_name == "InverseGudermannian":
        return call("Log", call("Tan", call("Plus", call("Times", rational_number(1, 4), symbol("Pi")), call("Times", rational_number(1, 2), argument))))

    degree_base = _degree_transcendental_base_name(head_name or "")
    if degree_base is not None:
        if degree_base.startswith("Arc"):
            return call("Times", call(degree_base, argument), integer(180), call("Power", symbol("Pi"), integer(-1)))
        return call(degree_base, call("Times", argument, symbol("Degree")))
    return None


def _complex_direct_function_components(argument: Expr, function_name: str) -> tuple[Expr, Expr] | None:
    components = _complex_components_expr(argument)
    if components is None:
        return None
    real, imaginary = components
    if function_name == "Sin":
        return (
            _complex_simplify(call("Times", call("Sin", real), call("Cosh", imaginary))),
            _complex_simplify(call("Times", call("Cos", real), call("Sinh", imaginary))),
        )
    if function_name == "Cos":
        return (
            _complex_simplify(call("Times", call("Cos", real), call("Cosh", imaginary))),
            _complex_simplify(call("Times", integer(-1), call("Sin", real), call("Sinh", imaginary))),
        )
    if function_name == "Sinh":
        return (
            _complex_simplify(call("Times", call("Sinh", real), call("Cos", imaginary))),
            _complex_simplify(call("Times", call("Cosh", real), call("Sin", imaginary))),
        )
    if function_name == "Cosh":
        return (
            _complex_simplify(call("Times", call("Cosh", real), call("Cos", imaginary))),
            _complex_simplify(call("Times", call("Sinh", real), call("Sin", imaginary))),
        )
    return None


def _complex_power_components(base: Expr, exponent: Expr) -> tuple[Expr, Expr] | None:
    exponent_fraction = _exact_fraction(exponent)
    if exponent_fraction is not None and exponent_fraction.denominator == 1:
        power = exponent_fraction.numerator
        if power == 0:
            return integer(1), integer(0)
        if power < 0:
            positive = _complex_power_components(base, integer(-power))
            if positive is None:
                return None
            return _complex_divide_components(integer(1), integer(0), *positive)
        result = (integer(1), integer(0))
        factor = _complex_components_expr(base)
        if factor is None:
            return None
        remaining = power
        while remaining:
            if remaining & 1:
                result = _complex_multiply_components(*result, *factor)
            remaining >>= 1
            if remaining:
                factor = _complex_multiply_components(*factor, *factor)
        return result
    if exponent_fraction == Fraction(1, 2):
        components = _complex_components_expr(base)
        return None if components is None else _complex_sqrt_components(*components)
    exponent_components = _complex_components_expr(exponent)
    if exponent_components is None or not _is_effectively_zero(exponent_components[1]):
        return None
    return _complex_components_expr(call("Exp", call("Times", exponent_components[0], call("Log", base))))


def _complex_sqrt_components(real: Expr, imaginary: Expr) -> tuple[Expr, Expr]:
    real = _complex_simplify(real)
    imaginary = _complex_simplify(imaginary)
    imaginary_sign = _compare_real_expr(imaginary, integer(0))
    if imaginary_sign == 0:
        real_sign = _compare_real_expr(real, integer(0))
        if real_sign is not None and real_sign >= 0:
            return _real_sqrt_expr(real), integer(0)
        if real_sign is not None and real_sign < 0:
            return integer(0), _real_sqrt_expr(_complex_negate(real))
    magnitude = _abs_from_components(real, imaginary)
    real_part = _real_sqrt_expr(_complex_simplify(call("Times", rational_number(1, 2), call("Plus", magnitude, real))))
    imaginary_magnitude = _real_sqrt_expr(
        _complex_simplify(call("Times", rational_number(1, 2), call("Plus", magnitude, _complex_negate(real))))
    )
    if imaginary_sign is None:
        sign_expr = _complex_simplify(call("Sign", imaginary))
    else:
        sign_expr = integer(1 if imaginary_sign > 0 else -1)
    return real_part, _complex_simplify(call("Times", sign_expr, imaginary_magnitude))


def _complex_multiply_components(left_real: Expr, left_imaginary: Expr, right_real: Expr, right_imaginary: Expr) -> tuple[Expr, Expr]:
    real = call(
        "Plus",
        call("Times", left_real, right_real),
        call("Times", integer(-1), left_imaginary, right_imaginary),
    )
    imaginary = call(
        "Plus",
        call("Times", left_real, right_imaginary),
        call("Times", left_imaginary, right_real),
    )
    return _complex_simplify(real), _complex_simplify(imaginary)


def _complex_divide_components(left_real: Expr, left_imaginary: Expr, right_real: Expr, right_imaginary: Expr) -> tuple[Expr, Expr]:
    denominator = _complex_simplify(call("Plus", call("Power", right_real, integer(2)), call("Power", right_imaginary, integer(2))))
    real_numerator = _complex_simplify(call("Plus", call("Times", left_real, right_real), call("Times", left_imaginary, right_imaginary)))
    imaginary_numerator = _complex_simplify(call("Plus", call("Times", left_imaginary, right_real), call("Times", integer(-1), left_real, right_imaginary)))
    return (
        _complex_simplify(call("Times", real_numerator, call("Power", denominator, integer(-1)))),
        _complex_simplify(call("Times", imaginary_numerator, call("Power", denominator, integer(-1)))),
    )


def _abs_from_components(real: Expr, imaginary: Expr) -> Expr:
    return _real_sqrt_expr(_complex_simplify(call("Plus", call("Power", real, integer(2)), call("Power", imaginary, integer(2)))))


def _arg_from_components(real: Expr, imaginary: Expr) -> Expr | None:
    real = _complex_simplify(real)
    imaginary = _complex_simplify(imaginary)
    real_sign = _compare_real_expr(real, integer(0))
    imaginary_sign = _compare_real_expr(imaginary, integer(0))
    if real_sign == 0 and imaginary_sign == 0:
        return integer(0)
    if imaginary_sign == 0:
        if real_sign is None:
            return None
        return integer(0) if real_sign > 0 else symbol("Pi")
    if real_sign == 0:
        if imaginary_sign is None:
            return None
        return _complex_simplify(call("Times", rational_number(1 if imaginary_sign > 0 else -1, 2), symbol("Pi")))
    return _complex_simplify(call("ArcTan", real, imaginary))


def _expr_from_components(real: Expr, imaginary: Expr) -> Expr:
    real = _complex_simplify(real)
    imaginary = _complex_simplify(imaginary)
    if _is_effectively_zero(imaginary):
        return real
    return _complex_simplify(call("Plus", real, call("Times", symbol("I"), imaginary)))


def _real_sqrt_expr(expr: Expr) -> Expr:
    return _complex_simplify(call("Power", expr, rational_number(1, 2)))


def _complex_negate(expr: Expr) -> Expr:
    return _complex_simplify(call("Times", integer(-1), expr))


def _complex_simplify(expr: Expr) -> Expr:
    evaluated = evaluate(expr)
    if _contains_root_number(evaluated):
        return _root_reduce_expr((evaluated,)) or evaluated
    return evaluated


def _contains_root_number(expr: Expr) -> bool:
    if isinstance(expr, RootNumber):
        return True
    if isinstance(expr, ComplexNumber):
        return _contains_root_number(expr.real_part) or _contains_root_number(expr.imaginary_part)
    if isinstance(expr, Call):
        return any(_contains_root_number(argument) for argument in expr.arguments)
    return False


def _is_effectively_zero(expr: Expr) -> bool:
    simplified = _complex_simplify(expr)
    if _is_numeric_zero(simplified):
        return True
    comparison = _compare_real_expr(simplified, integer(0))
    return comparison == 0


def _numericize_algebraic_expr(expr: Expr, precision: int | None) -> Expr | None:
    if not isinstance(expr, RootNumber):
        return None
    root = _root_to_sympy(expr)
    digits = 16 if precision is None else max(1, precision)
    numeric = _sp.N(root, digits)
    real_part, imaginary_part = numeric.as_real_imag()
    real_expr = _real_from_sympy_float(real_part, precision)
    imaginary_expr = _real_from_sympy_float(imaginary_part, precision)
    if real_expr is None or imaginary_expr is None:
        return None
    if bool(root.is_real) or imaginary_part == 0:
        return real_expr
    return complex_number(real_expr, imaginary_expr)


def _is_real_algebraic_expr(expr: Expr) -> bool:
    return isinstance(expr, RootNumber) and bool(_root_to_sympy(expr).is_real)


def _compare_algebraic_real_expr(left: Expr, right: Expr) -> int | None:
    try:
        left_sym = _to_sympy_real_comparable(left)
        right_sym = _to_sympy_real_comparable(right)
    except _AlgebraicConversionError:
        return None
    difference = left_sym - right_sym
    if difference == 0:
        return 0
    sign = _sp.sign(difference)
    if sign in {_sp.Integer(-1), _sp.Integer(0), _sp.Integer(1)}:
        return int(sign)
    if difference.is_positive is True:
        return 1
    if difference.is_negative is True:
        return -1
    return None


def _conjugate_algebraic_expr(expr: Expr) -> Expr | None:
    if not isinstance(expr, RootNumber):
        return None
    return _conjugate_root(expr)


def _root_reduce_special(expr: Expr) -> Expr | None:
    if not isinstance(expr, Call) or len(expr.arguments) != 1:
        return None
    argument = expr.arguments[0]
    if expr.has_head("Re"):
        return _component_expr(argument, "Re")
    if expr.has_head("Im"):
        return _component_expr(argument, "Im")
    if expr.has_head("Conjugate"):
        return _conjugate_expr(argument)
    if expr.has_head("Abs") and isinstance(argument, RootNumber):
        return _root_component_expr(argument, "Abs")
    return None


def _component_expr(expr: Expr, component: str) -> Expr | None:
    if _is_exact_real_number(expr) or isinstance(expr, Real | SpecialReal):
        return expr if component == "Re" else integer(0)
    if isinstance(expr, RootNumber):
        return _root_component_expr(expr, component)
    if isinstance(expr, ComplexNumber):
        return expr.real_part if component == "Re" else expr.imaginary_part
    if not isinstance(expr, Call):
        return None
    if expr.has_head("Plus"):
        parts = [_component_expr(argument, component) for argument in expr.arguments]
        if any(part is None for part in parts):
            return None
        return _root_reduce_combination(call("Plus", *(part for part in parts if part is not None)))
    if expr.has_head("Times"):
        real_part: Expr = integer(1)
        imaginary_part: Expr = integer(0)
        for argument in expr.arguments:
            argument_real = _component_expr(argument, "Re")
            argument_imaginary = _component_expr(argument, "Im")
            if argument_real is None or argument_imaginary is None:
                return None
            next_real = call(
                "Plus",
                call("Times", real_part, argument_real),
                call("Times", integer(-1), imaginary_part, argument_imaginary),
            )
            next_imaginary = call(
                "Plus",
                call("Times", real_part, argument_imaginary),
                call("Times", imaginary_part, argument_real),
            )
            real_part = _root_reduce_combination(next_real)
            imaginary_part = _root_reduce_combination(next_imaginary)
        return real_part if component == "Re" else imaginary_part
    if expr.has_head("Conjugate") and len(expr.arguments) == 1:
        if component == "Re":
            return _component_expr(expr.arguments[0], "Re")
        imaginary = _component_expr(expr.arguments[0], "Im")
        return None if imaginary is None else _root_reduce_combination(call("Times", integer(-1), imaginary))
    return None


def _conjugate_expr(expr: Expr) -> Expr | None:
    if _is_exact_real_number(expr) or isinstance(expr, Real | SpecialReal):
        return expr
    if isinstance(expr, ComplexNumber):
        return complex_number(expr.real_part, _negate_real_expr(expr.imaginary_part))
    if isinstance(expr, RootNumber):
        return _conjugate_root(expr)
    if not isinstance(expr, Call):
        return None
    if expr.has_head("Plus") or expr.has_head("Times"):
        parts = [_conjugate_expr(argument) for argument in expr.arguments]
        if any(part is None for part in parts):
            return None
        return _root_reduce_combination(call(expr.head_expr, *(part for part in parts if part is not None)))
    if expr.has_head("Power") and len(expr.arguments) == 2 and isinstance(expr.arguments[1], Integer):
        conjugate_base = _conjugate_expr(expr.arguments[0])
        if conjugate_base is None:
            return None
        return _root_reduce_combination(call("Power", conjugate_base, expr.arguments[1]))
    return None


def _root_reduce_combination(expr: Expr) -> Expr:
    evaluated = evaluate(expr)
    return _root_reduce_expr((evaluated,)) or evaluated


def _root_component_expr(root: RootNumber, component: str) -> Expr | None:
    sym_root = _root_to_sympy(root)
    approx = complex(_sp.N(sym_root, 40))
    if component == "Re":
        if sym_root.is_real:
            return root
        candidate = _component_resultant_polynomial(root, component)
        return _root_from_polynomial_and_approx(candidate, approx.real, require_real=True)
    if component == "Im":
        if sym_root.is_real:
            return integer(0)
        candidate = _component_resultant_polynomial(root, component)
        return _root_from_polynomial_and_approx(candidate, approx.imag, require_real=True)
    if component == "Abs":
        if sym_root.is_real:
            return _root_reduce_sympy(abs(sym_root))
        candidate = _component_resultant_polynomial(root, component)
        return _root_from_polynomial_and_approx(candidate, abs(approx), require_real=True)
    return None


def _component_resultant_polynomial(root: RootNumber, component: str) -> Any:
    f = _poly_expr_from_coefficients(root.coefficients, _T)
    degree = _sp.Poly(f, _T).degree()
    if component == "Re":
        resultant = _sp.resultant(f, f.subs(_T, 2 * _Y - _T), _T)
    elif component == "Im":
        resultant = _sp.resultant(f, f.subs(_T, _T - 2 * _sp.I * _Y), _T)
    elif component == "Abs":
        resultant = _sp.resultant(f, (_T ** degree) * f.subs(_T, (_Y ** 2) / _T), _T)
    else:  # pragma: no cover - guarded by callers
        raise AssertionError(component)
    return _primitive_rational_poly_expr(resultant, _Y)


def _root_reduce_sympy(sym_expr: Any) -> Expr:
    sym_expr = _sp.sympify(sym_expr)
    direct = _expr_from_sympy_root_or_number(sym_expr)
    if direct is not None:
        return direct
    poly_expr = _primitive_integer_poly_expr(_sp.minpoly(sym_expr, _X), _X)
    approx = complex(_sp.N(sym_expr, 100))
    return _root_from_polynomial_and_approx(poly_expr, approx)


def _algebraic_coefficient_root_expr(function: Expr, index: int, method: int) -> Expr:
    if index < 0:
        raise _AlgebraicConversionError(function.to_full_form())
    variable = _ALGEBRAIC_ROOT_VARIABLE
    poly_expr = _polynomial_function_to_sympy(function, variable, algebraic_coefficients=True)
    poly = _sp.Poly(poly_expr, variable, extension=True)
    degree = poly.degree()
    _ensure_root_degree_allowed(degree)
    if index >= degree:
        raise _AlgebraicConversionError(function.to_full_form())
    roots = _numeric_roots_for_indexing(poly.as_expr(), variable, degree)
    target = roots[index]
    norm = _norm_poly(poly, poly_expr, variable)
    norm_expr = _primitive_integer_poly_expr(norm.as_expr(), variable)
    return _root_from_polynomial_and_approx(norm_expr, target, method=method)


def _numeric_roots_for_indexing(poly_expr: Any, variable: Any, degree: int) -> list[complex]:
    roots = _sp.nroots(poly_expr, n=50, maxsteps=200)
    if len(roots) != degree:
        raise _AlgebraicConversionError(str(poly_expr))
    return [complex(root) for root in roots]


def _norm_poly(poly: Any, poly_expr: Any, variable: Any) -> Any:
    try:
        return poly.norm()
    except Exception:
        # SymPy's ``extension=True`` uses Gaussian integer/rational domains for
        # pure I coefficients; retry as the algebraic field Q(I) so ``norm`` is
        # available and yields an ordinary rational polynomial.
        gaussian_poly = _sp.Poly(poly_expr, variable, extension=[_sp.I])
        return gaussian_poly.norm()


def _root_from_polynomial_and_approx(
    poly_expr: Any,
    approx: complex | float,
    *,
    require_real: bool = False,
    method: int = 0,
) -> Expr:
    free_symbols = sorted(_sp.sympify(poly_expr).free_symbols, key=lambda symbol: symbol.name)
    variable = free_symbols[0] if free_symbols else _X
    poly_expr = _primitive_integer_poly_expr(poly_expr, variable)
    poly = _sp.Poly(poly_expr, variable)
    square_free_expr = _primitive_integer_poly_expr(poly.sqf_part().as_expr(), variable)
    poly = _sp.Poly(square_free_expr, variable)
    degree = poly.degree()
    _ensure_root_degree_allowed(degree)
    if degree <= 0:
        raise _AlgebraicConversionError(str(poly_expr))
    target = complex(approx)
    fast_candidate = _root_by_numeric_index(poly.as_expr(), variable, degree, target, require_real=require_real)
    if fast_candidate is not None:
        return _expr_from_sympy_root_or_number(fast_candidate, method=method)
    factors = _sp.factor_list(poly.as_expr(), gens=(variable,))[1]
    candidates: list[tuple[Any, int]] = []
    for factor_expr, _multiplicity in factors:
        factor_poly = _sp.Poly(factor_expr, variable)
        if factor_poly.degree() <= 0:
            continue
        for index in range(factor_poly.degree()):
            try:
                candidate = _sp.CRootOf(factor_poly.as_expr(), index)
            except (IndexError, ValueError):
                continue
            if require_real and not bool(candidate.is_real):
                continue
            candidates.append((candidate, index))
    if not candidates:
        raise _AlgebraicConversionError(str(poly_expr))
    chosen = _choose_root_by_approximation([candidate for candidate, _ in candidates], target)
    return _expr_from_sympy_root_or_number(chosen, method=method)


def _root_by_numeric_index(
    poly_expr: Any,
    variable: Any,
    degree: int,
    target: complex,
    *,
    require_real: bool,
) -> Any | None:
    try:
        roots = _numeric_roots_for_indexing(poly_expr, variable, degree)
    except Exception:
        return None
    indexed_roots = list(enumerate(roots))
    if require_real:
        indexed_roots = [(index, root) for index, root in indexed_roots if abs(root.imag) < 1e-30]
    if not indexed_roots:
        return None
    chosen_index, _chosen_root = _choose_indexed_root_by_approximation(indexed_roots, target)
    try:
        return _sp.CRootOf(poly_expr, chosen_index)
    except Exception:
        return None


def _choose_indexed_root_by_approximation(candidates: Sequence[tuple[int, complex]], target: complex) -> tuple[int, complex]:
    distances = sorted(((abs(value - target), index, value) for index, value in candidates), key=lambda item: item[0])
    if not distances:
        raise _AlgebraicConversionError(str(target))
    return distances[0][1], distances[0][2]


def _choose_root_by_approximation(candidates: Sequence[Any], target: complex) -> Any:
    precision = 30
    for _attempt in range(6):
        distances: list[tuple[float, Any]] = []
        for candidate in candidates:
            value = complex(_sp.N(candidate, precision))
            distances.append((abs(value - target), candidate))
        distances.sort(key=lambda item: item[0])
        if len(distances) == 1 or distances[0][0] * 4 < distances[1][0]:
            return distances[0][1]
        precision *= 2
    return distances[0][1]


def _conjugate_root(root: RootNumber) -> Expr:
    sym_root = _root_to_sympy(root)
    if bool(sym_root.is_real):
        return root
    target = complex(_sp.N(sym_root, 100)).conjugate()
    poly_expr = _poly_expr_from_coefficients(root.coefficients, _X)
    candidates = [_sp.CRootOf(poly_expr, index) for index in range(_sp.Poly(poly_expr, _X).degree())]
    chosen = _choose_root_by_approximation(candidates, target)
    result = _expr_from_sympy_root_or_number(chosen)
    if result is None:
        raise _AlgebraicConversionError(root.to_full_form())
    return result


def _to_sympy_real_comparable(expr: Expr) -> Any:
    if _is_exact_real_number(expr):
        exact = _exact_fraction(expr)
        assert exact is not None
        return _sp.Rational(exact.numerator, exact.denominator)
    if isinstance(expr, RootNumber) and _is_real_algebraic_expr(expr):
        return _root_to_sympy(expr)
    raise _AlgebraicConversionError(expr.to_full_form())


def _to_sympy_algebraic(expr: Expr) -> Any:
    if isinstance(expr, Integer):
        return _sp.Integer(expr.value)
    if isinstance(expr, RationalNumber):
        return _sp.Rational(expr.value.numerator, expr.value.denominator)
    if isinstance(expr, ComplexNumber):
        return _to_sympy_algebraic(expr.real_part) + _sp.I * _to_sympy_algebraic(expr.imaginary_part)
    if isinstance(expr, RootNumber):
        return _root_to_sympy(expr)
    if isinstance(expr, Call):
        trig_value = _to_sympy_trig_algebraic(expr)
        if trig_value is not None:
            return trig_value
        if expr.has_head("Plus"):
            return _sp.Add(*(_to_sympy_algebraic(argument) for argument in expr.arguments))
        if expr.has_head("Times"):
            return _sp.Mul(*(_to_sympy_algebraic(argument) for argument in expr.arguments))
        if expr.has_head("Power") and len(expr.arguments) == 2:
            return _sp.Pow(_to_sympy_algebraic(expr.arguments[0]), _to_sympy_algebraic(expr.arguments[1]))
        if expr.has_head("Conjugate") and len(expr.arguments) == 1:
            return _to_sympy_conjugate(expr.arguments[0])
        if expr.has_head("Re") and len(expr.arguments) == 1:
            conjugate = _to_sympy_conjugate(expr.arguments[0])
            return (_to_sympy_algebraic(expr.arguments[0]) + conjugate) / 2
        if expr.has_head("Im") and len(expr.arguments) == 1:
            conjugate = _to_sympy_conjugate(expr.arguments[0])
            return (_to_sympy_algebraic(expr.arguments[0]) - conjugate) / (2 * _sp.I)
        if expr.has_head("Abs") and len(expr.arguments) == 1:
            value = _to_sympy_algebraic(expr.arguments[0])
            conjugate = _to_sympy_conjugate(expr.arguments[0])
            return _sp.sqrt(value * conjugate)
    raise _AlgebraicConversionError(expr.to_full_form())


def _to_sympy_trig_algebraic(expr: Call) -> Any | None:
    if len(expr.arguments) != 1:
        return None
    head_name = _system_dispatch_name(expr.head_expr) if isinstance(expr.head_expr, Symbol) else None
    direct_functions = {
        "Sin": _sp.sin,
        "Cos": _sp.cos,
        "Tan": _sp.tan,
        "Cot": _sp.cot,
        "Sec": _sp.sec,
        "Csc": _sp.csc,
    }
    if head_name in direct_functions:
        argument = _to_sympy_rational_pi_multiple(expr.arguments[0])
        if argument is None:
            return None
        return direct_functions[head_name](argument)
    degree_base = _degree_transcendental_base_name(head_name or "")
    if degree_base in direct_functions:
        degree_value = _exact_fraction(expr.arguments[0])
        if degree_value is None:
            return None
        return direct_functions[degree_base](_sp.Rational(degree_value.numerator, degree_value.denominator) * _sp.pi / 180)
    if head_name == "Haversine":
        argument = _to_sympy_rational_pi_multiple(expr.arguments[0])
        if argument is None:
            return None
        return (1 - _sp.cos(argument)) / 2
    return None


def _to_sympy_rational_pi_multiple(expr: Expr) -> Any | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        if exact == 0:
            return _sp.Integer(0)
        return None
    if isinstance(expr, Symbol):
        name = _system_dispatch_name(expr)
        if name == "Pi":
            return _sp.pi
        if name == "Degree":
            return _sp.pi / 180
        return None
    if not isinstance(expr, Call) or not expr.has_head("Times"):
        return None
    coefficient = Fraction(1, 1)
    pi_factor: Fraction | None = None
    for factor in expr.arguments:
        factor_fraction = _exact_fraction(factor)
        if factor_fraction is not None:
            coefficient *= factor_fraction
            continue
        if isinstance(factor, Symbol):
            name = _system_dispatch_name(factor)
            if name == "Pi" and pi_factor is None:
                pi_factor = Fraction(1, 1)
                continue
            if name == "Degree" and pi_factor is None:
                pi_factor = Fraction(1, 180)
                continue
        return None
    if pi_factor is None:
        return None
    multiple = coefficient * pi_factor
    return _sp.Rational(multiple.numerator, multiple.denominator) * _sp.pi


def _to_sympy_conjugate(expr: Expr) -> Any:
    if isinstance(expr, Integer | RationalNumber):
        return _to_sympy_algebraic(expr)
    if isinstance(expr, ComplexNumber):
        return _to_sympy_algebraic(complex_number(expr.real_part, _negate_real_expr(expr.imaginary_part)))
    if isinstance(expr, RootNumber):
        return _to_sympy_algebraic(_conjugate_root(expr))
    if isinstance(expr, Call):
        if expr.has_head("Plus"):
            return _sp.Add(*(_to_sympy_conjugate(argument) for argument in expr.arguments))
        if expr.has_head("Times"):
            return _sp.Mul(*(_to_sympy_conjugate(argument) for argument in expr.arguments))
        if expr.has_head("Power") and len(expr.arguments) == 2:
            exponent = _to_sympy_algebraic(expr.arguments[1])
            if exponent.is_Rational:
                return _sp.Pow(_to_sympy_conjugate(expr.arguments[0]), exponent)
    raise _AlgebraicConversionError(expr.to_full_form())


def _polynomial_function_to_sympy(function: Expr, variable: Any, *, algebraic_coefficients: bool = False) -> Any:
    if isinstance(function, Call) and function.has_head("Function"):
        if len(function.arguments) == 1:
            body = function.arguments[0]
            parameter: Expr | None = None
        elif len(function.arguments) >= 2:
            parameter_spec = function.arguments[0]
            body = function.arguments[1]
            if isinstance(parameter_spec, Symbol):
                parameter = parameter_spec
            elif isinstance(parameter_spec, Call) and parameter_spec.has_head("List") and len(parameter_spec.arguments) == 1:
                parameter = parameter_spec.arguments[0]
            else:
                raise _AlgebraicConversionError(function.to_full_form())
        else:
            raise _AlgebraicConversionError(function.to_full_form())
        poly_expr = _to_sympy_polynomial_body(
            body,
            variable,
            parameter,
            algebraic_coefficients=algebraic_coefficients,
        )
    else:
        poly_expr = _to_sympy_polynomial_body(
            function,
            variable,
            None,
            algebraic_coefficients=algebraic_coefficients,
        )
    if algebraic_coefficients:
        poly = _sp.Poly(poly_expr, variable, extension=True)
        if poly.degree() <= 0:
            raise _AlgebraicConversionError(function.to_full_form())
        return poly.as_expr()
    poly = _sp.Poly(poly_expr, variable, domain=_sp.QQ)
    if poly.degree() <= 0:
        raise _AlgebraicConversionError(function.to_full_form())
    return _primitive_integer_poly_expr(poly.as_expr(), variable)


def _to_sympy_polynomial_body(
    expr: Expr,
    variable: Any,
    parameter: Expr | None,
    *,
    algebraic_coefficients: bool = False,
) -> Any:
    if algebraic_coefficients and not _contains_polynomial_variable(expr, parameter):
        try:
            return _to_sympy_algebraic(evaluate(expr))
        except _AlgebraicConversionError:
            pass
    if isinstance(expr, Integer):
        return _sp.Integer(expr.value)
    if isinstance(expr, RationalNumber):
        return _sp.Rational(expr.value.numerator, expr.value.denominator)
    if isinstance(expr, ComplexNumber):
        return _to_sympy_algebraic(expr)
    if isinstance(expr, RootNumber):
        return _root_to_sympy(expr, _ROOT_COEFFICIENT_SYMBOL)
    if isinstance(expr, Symbol):
        if expr.name == "I":
            return _sp.I
        if parameter is not None and expr == parameter:
            return variable
        raise _AlgebraicConversionError(expr.to_full_form())
    if isinstance(expr, Call):
        if expr.has_head("Root") and algebraic_coefficients:
            root = _root_expr(expr.arguments)
            if root is None:
                raise _AlgebraicConversionError(expr.to_full_form())
            return _to_sympy_algebraic(root)
        if expr.has_head("Slot") and (not expr.arguments or expr.arguments == (integer(1),)):
            return variable
        if expr.has_head("Plus"):
            return _sp.Add(
                *(
                    _to_sympy_polynomial_body(
                        argument,
                        variable,
                        parameter,
                        algebraic_coefficients=algebraic_coefficients,
                    )
                    for argument in expr.arguments
                )
            )
        if expr.has_head("Times"):
            return _sp.Mul(
                *(
                    _to_sympy_polynomial_body(
                        argument,
                        variable,
                        parameter,
                        algebraic_coefficients=algebraic_coefficients,
                    )
                    for argument in expr.arguments
                )
            )
        if expr.has_head("Power") and len(expr.arguments) == 2:
            base = _to_sympy_polynomial_body(
                expr.arguments[0],
                variable,
                parameter,
                algebraic_coefficients=algebraic_coefficients,
            )
            exponent = _to_sympy_polynomial_body(
                expr.arguments[1],
                variable,
                parameter,
                algebraic_coefficients=algebraic_coefficients,
            )
            return _sp.Pow(base, exponent)
        if expr.has_head("Sqrt") and len(expr.arguments) == 1:
            base = _to_sympy_polynomial_body(
                expr.arguments[0],
                variable,
                parameter,
                algebraic_coefficients=algebraic_coefficients,
            )
            return _sp.sqrt(base)
    raise _AlgebraicConversionError(expr.to_full_form())


def _contains_polynomial_variable(expr: Expr, parameter: Expr | None) -> bool:
    if parameter is not None and expr == parameter:
        return True
    if isinstance(expr, Call):
        if expr.has_head("Slot") and (not expr.arguments or expr.arguments == (integer(1),)):
            return True
        return any(_contains_polynomial_variable(argument, parameter) for argument in expr.arguments)
    return False


def _root_to_sympy(root: RootNumber, variable: Any = _ROOT_COEFFICIENT_SYMBOL) -> Any:
    return _sp.CRootOf(_poly_expr_from_coefficients(root.coefficients, variable), root.index)


def _poly_expr_from_coefficients(coefficients: Sequence[int], variable: Any) -> Any:
    return _sp.Add(*(_sp.Integer(coefficient) * variable ** exponent for exponent, coefficient in enumerate(coefficients)))


def _primitive_integer_poly_expr(poly_expr: Any, variable: Any) -> Any:
    poly = _sp.Poly(poly_expr, variable, domain=_sp.QQ)
    _denominator, integer_poly = poly.clear_denoms(convert=True)
    _content, primitive_poly = integer_poly.primitive()
    if primitive_poly.LC() < 0:
        primitive_poly = -primitive_poly
    return primitive_poly.as_expr()


def _max_root_degree() -> int:
    value = _finite_system_limit_value("$MaxRootDegree")
    return 1000 if value is None else value


def _ensure_root_degree_allowed(degree: int) -> None:
    if degree < 1 or degree > _max_root_degree():
        raise _AlgebraicConversionError(f"Root degree {degree} exceeds $MaxRootDegree.")


def _primitive_rational_poly_expr(poly_expr: Any, variable: Any) -> Any:
    poly = _sp.Poly(_sp.expand(poly_expr), variable, extension=_sp.I)
    coeffs = [_sp.expand(coefficient) for coefficient in poly.all_coeffs()]
    real_coeffs = [_sp.expand(coefficient.as_real_imag()[0]) for coefficient in coeffs]
    imag_coeffs = [_sp.expand(coefficient.as_real_imag()[1]) for coefficient in coeffs]
    if all(coefficient == 0 for coefficient in imag_coeffs):
        rational_coeffs = real_coeffs
    elif all(coefficient == 0 for coefficient in real_coeffs):
        rational_coeffs = imag_coeffs
    else:
        raise _AlgebraicConversionError(str(poly_expr))
    rational_expr = _sp.Add(
        *(coefficient * variable ** exponent for exponent, coefficient in enumerate(reversed(rational_coeffs)))
    )
    return _primitive_integer_poly_expr(rational_expr, variable)


def _polynomial_expr_from_sympy_poly(poly_expr: Any, variable: Expr) -> Expr:
    poly = _sp.Poly(poly_expr, _X)
    coefficients = list(reversed(poly.all_coeffs()))
    terms: list[Expr] = []
    for exponent, coefficient in enumerate(coefficients):
        if coefficient == 0:
            continue
        coefficient_expr = _expr_from_sympy_root_or_number(coefficient)
        if coefficient_expr is None:
            raise _AlgebraicConversionError(str(poly_expr))
        if exponent == 0:
            terms.append(coefficient_expr)
            continue
        power_expr = variable if exponent == 1 else call("Power", variable, integer(exponent))
        if coefficient_expr == integer(1):
            terms.append(power_expr)
        elif coefficient_expr == integer(-1):
            terms.append(call("Times", integer(-1), power_expr))
        else:
            terms.append(call("Times", coefficient_expr, power_expr))
    if not terms:
        return integer(0)
    return evaluate(call("Plus", *terms))


def _expr_from_sympy_root_or_number(expr: Any, *, method: int = 0) -> Expr | None:
    expr = _sp.sympify(expr)
    if expr.is_Integer:
        return integer(int(expr))
    if expr.is_Rational:
        return rational_number(int(expr.p), int(expr.q))
    if isinstance(expr, _ComplexRootOf):
        poly = expr.poly
        if poly.degree() > _max_root_degree():
            return None
        coefficients = tuple(int(coefficient) for coefficient in reversed(poly.all_coeffs()))
        return root_number(coefficients, int(expr.index), method=method)
    if expr.is_number:
        real_part, imaginary_part = expr.as_real_imag()
        real_expr = _rational_expr_from_sympy(real_part)
        imaginary_expr = _rational_expr_from_sympy(imaginary_part)
        if real_expr is not None and imaginary_expr is not None:
            return complex_number(real_expr, imaginary_expr)
    return None


def _rational_expr_from_sympy(expr: Any) -> Expr | None:
    expr = _sp.sympify(expr)
    if expr.is_Integer:
        return integer(int(expr))
    if expr.is_Rational:
        return rational_number(int(expr.p), int(expr.q))
    return None


def _real_from_sympy_float(expr: Any, precision: int | None) -> Expr | None:
    expr = _sp.N(expr, 16 if precision is None else max(1, precision))
    if expr == 0:
        return _machine_real(0.0) if precision is None else real(f"0.`{max(1, precision)}.")
    text = _sp.sstr(expr, full_prec=True).replace("e", "*^").replace("E", "*^")
    if precision is None:
        try:
            return _machine_real(float(expr))
        except TypeError:
            return None
    return real(f"{text}`{max(1, precision)}.")
