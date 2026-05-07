from __future__ import annotations

import math
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
        if expr.has_head("Solve"):
            return _solve_expr(expr.arguments)
        if expr.has_head("CountRoots"):
            return _count_roots_expr(expr.arguments)
        if expr.has_head("Root"):
            return _root_expr(expr.arguments)
        if expr.has_head("RootIntervals"):
            return _root_intervals_expr(expr.arguments)
        if expr.has_head("IsolatingInterval"):
            return _isolating_interval_expr(expr.arguments)
        if expr.has_head("RootSum"):
            return _root_sum_expr(expr.arguments)
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
        if expr.has_head("ToRadicals"):
            return _to_radicals_expr(expr.arguments)
    except Exception:
        # Algebraic-number conversion is intentionally best-effort. Unsupported or
        # unexpectedly hard cases must leave the expression inert, not crash the REPL.
        return None
    return None


def _solve_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    variables = _solve_variables(arguments[1])
    if variables is None or not variables:
        return None
    from . import expression_polynomial as _polynomial

    bridge = _polynomial._SympyBridge(variables)
    variable_symbols = tuple(bridge.expr_to_symbol[variable] for variable in variables)
    variable_map = dict(zip(variables, variable_symbols))
    try:
        equations = _solve_equation_exprs(arguments[0])
        if equations is None:
            return None
        if equations is False:
            return _evaluated_list_expr()
        polynomials = [_solve_polynomial_expr(equation, variable_map, set(variable_symbols)) for equation in equations]
        if not polynomials:
            return _evaluated_list_expr(_evaluated_list_expr())
        if len(variables) == 1:
            return _solve_univariate_polynomials(polynomials, variables[0], bridge, variable_symbols[0])
        return _solve_square_linear_system(polynomials, variables, bridge, variable_symbols)
    except (_AlgebraicConversionError, _sp.PolynomialError, ValueError, TypeError, NotImplementedError):
        return None


def _solve_variables(spec: Expr) -> tuple[Expr, ...] | None:
    if isinstance(spec, Call) and spec.has_head("List"):
        variables = tuple(spec.arguments)
    else:
        variables = (spec,)
    if len(set(variables)) != len(variables):
        return None
    return variables


def _solve_equation_exprs(spec: Expr) -> tuple[Expr, ...] | bool | None:
    if isinstance(spec, Symbol):
        truth = _truth_value(spec)
        if truth is True:
            return ()
        if truth is False:
            return False
    raw_equations = spec.arguments if isinstance(spec, Call) and spec.has_head("List") else (spec,)
    equations: list[Expr] = []
    for equation in raw_equations:
        if isinstance(equation, Symbol):
            truth = _truth_value(equation)
            if truth is True:
                continue
            if truth is False:
                return False
        if isinstance(equation, Call) and equation.has_head("Equal"):
            if len(equation.arguments) <= 1:
                continue
            for left, right in zip(equation.arguments, equation.arguments[1:]):
                equations.append(evaluate(call("Plus", left, call("Times", integer(-1), right))))
            continue
        equations.append(equation)
    return tuple(equations)


def _solve_polynomial_expr(expr: Expr, variable_map: dict[Expr, Any], variable_symbols: set[Any]) -> Any:
    sym_expr = _sp.expand(_solve_to_sympy(expr, variable_map))
    if sym_expr.free_symbols - variable_symbols:
        raise _AlgebraicConversionError(expr.to_full_form())
    return sym_expr


def _solve_to_sympy(expr: Expr, variable_map: dict[Expr, Any]) -> Any:
    explicit = variable_map.get(expr)
    if explicit is not None:
        return explicit
    if isinstance(expr, Integer):
        return _sp.Integer(expr.value)
    if isinstance(expr, RationalNumber):
        return _sp.Rational(expr.value.numerator, expr.value.denominator)
    if isinstance(expr, Real):
        return _expr_to_sympy_numeric(expr)
    if isinstance(expr, ComplexNumber):
        return _solve_to_sympy(expr.real_part, variable_map) + _sp.I * _solve_to_sympy(
            expr.imaginary_part,
            variable_map,
        )
    if isinstance(expr, RootNumber):
        return _root_to_sympy(expr)
    if isinstance(expr, Symbol):
        constant = _sympy_constant(_system_dispatch_name(expr))
        if constant is None:
            raise _AlgebraicConversionError(expr.to_full_form())
        return constant
    if isinstance(expr, Call):
        if not _solve_contains_variable(expr, variable_map):
            try:
                return _expr_to_sympy_numeric(expr)
            except _SympyNumericConversionError:
                pass
        head_name = _system_dispatch_name(expr.head_expr) if isinstance(expr.head_expr, Symbol) else None
        if head_name == "Plus":
            return _sp.Add(*(_solve_to_sympy(argument, variable_map) for argument in expr.arguments))
        if head_name == "Times":
            return _sp.Mul(*(_solve_to_sympy(argument, variable_map) for argument in expr.arguments))
        if head_name == "Power" and len(expr.arguments) == 2:
            return _sp.Pow(
                _solve_to_sympy(expr.arguments[0], variable_map),
                _solve_to_sympy(expr.arguments[1], variable_map),
            )
        if head_name == "Sqrt" and len(expr.arguments) == 1:
            return _sp.sqrt(_solve_to_sympy(expr.arguments[0], variable_map))
    raise _AlgebraicConversionError(expr.to_full_form())


def _solve_contains_variable(expr: Expr, variable_map: dict[Expr, Any]) -> bool:
    if expr in variable_map:
        return True
    if isinstance(expr, Call):
        return any(_solve_contains_variable(argument, variable_map) for argument in expr.arguments)
    return False


def _solve_univariate_polynomials(polynomials: Sequence[Any], variable: Expr, bridge: Any, sym_var: Any) -> Expr | None:
    nonzero_polys: list[Any] = []
    for polynomial in polynomials:
        if _sp.expand(polynomial) == 0:
            continue
        poly = _sp.Poly(polynomial, sym_var, extension=True)
        if poly.degree() <= 0:
            return _evaluated_list_expr()
        nonzero_polys.append(poly)
    if not nonzero_polys:
        return _evaluated_list_expr(_evaluated_list_expr())
    common_poly = nonzero_polys[0]
    for polynomial in nonzero_polys[1:]:
        common_poly = _sp.gcd(common_poly, polynomial)
        if common_poly.degree() <= 0:
            return _evaluated_list_expr()
    roots = _solve_polynomial_roots(common_poly, bridge, sym_var)
    if roots is None:
        return None
    return _evaluated_list_expr(*(_evaluated_list_expr(call("Rule", variable, root)) for root in roots))


def _solve_polynomial_roots(poly: Any, bridge: Any, sym_var: Any) -> list[Expr] | None:
    if poly.degree() == 1:
        root = -poly.nth(0) / poly.nth(1)
        converted = _solve_value_from_sympy(root, bridge)
        return None if converted is None else [converted]
    try:
        rational_poly = _sp.Poly(poly.as_expr(), sym_var, domain=_sp.QQ)
        primitive_expr = _primitive_integer_poly_expr(rational_poly.as_expr(), sym_var)
        square_free_poly = _sp.Poly(primitive_expr, sym_var, domain=_sp.QQ).sqf_part()
        square_free_expr = _primitive_integer_poly_expr(square_free_poly.as_expr(), sym_var)
        degree = _sp.Poly(square_free_expr, sym_var, domain=_sp.QQ).degree()
        if degree > _max_root_degree():
            return None
        roots = [_expr_from_sympy_root_or_number(_sp.CRootOf(square_free_expr, index)) for index in range(degree)]
        if any(root is None for root in roots):
            return None
        return [root for root in roots if root is not None]
    except Exception:
        pass
    candidates: list[Any] = []
    for candidate, multiplicity in _sp.roots(poly.as_expr(), sym_var).items():
        candidates.extend([candidate] * int(multiplicity))
    if not candidates:
        candidates = list(_sp.solve(poly.as_expr(), sym_var))
    if not candidates:
        return None
    converted_roots: list[Expr] = []
    seen: set[Expr] = set()
    for candidate in candidates:
        try:
            converted = _root_reduce_sympy(candidate)
        except Exception:
            converted = _solve_value_from_sympy(candidate, bridge)
        if converted is None:
            return None
        if converted not in seen:
            seen.add(converted)
            converted_roots.append(converted)
    return converted_roots


def _solve_square_linear_system(
    polynomials: Sequence[Any],
    variables: Sequence[Expr],
    bridge: Any,
    variable_symbols: Sequence[Any],
) -> Expr | None:
    if len(polynomials) != len(variables):
        return None
    rows: list[list[Any]] = []
    rhs: list[Any] = []
    for polynomial in polynomials:
        poly = _sp.Poly(polynomial, *variable_symbols, extension=True)
        if poly.total_degree() > 1:
            return None
        rows.append([poly.coeff_monomial(variable) for variable in variable_symbols])
        rhs.append(-poly.coeff_monomial(1))
    matrix = _sp.Matrix(rows)
    if matrix.rows != matrix.cols:
        return None
    try:
        solution = matrix.LUsolve(_sp.Matrix(rhs))
    except Exception:
        return None
    rules: list[Expr] = []
    for variable, value in zip(variables, solution):
        if getattr(value, "free_symbols", set()):
            return None
        converted = _solve_value_from_sympy(value, bridge)
        if converted is None:
            return None
        rules.append(call("Rule", variable, converted))
    return _evaluated_list_expr(_evaluated_list_expr(*rules))


def _solve_value_from_sympy(expr: Any, bridge: Any) -> Expr | None:
    converted = _expr_from_sympy_root_or_number(expr)
    if converted is not None:
        return converted
    converted = _sympy_exact_expr_to_tungsten(expr)
    if converted is not None:
        return converted
    try:
        converted = _sympy_number_to_expr(expr, None)
    except Exception:
        converted = None
    if converted is not None:
        return converted
    try:
        return bridge.from_sympy(expr)
    except Exception:
        return None


def _count_roots_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    polynomial, spec = arguments
    if isinstance(spec, Call) and spec.has_head("List") and len(spec.arguments) == 3:
        variable, lower, upper = spec.arguments
        poly = _sympy_poly_in_variable(polynomial, variable)
        lower_sym = _to_sympy_endpoint(lower)
        upper_sym = _to_sympy_endpoint(upper)
        if lower_sym is None or upper_sym is None:
            return None
        return integer(_count_roots_with_multiplicity(poly, lower_sym, upper_sym))
    poly = _sympy_poly_in_variable(polynomial, spec)
    return integer(_count_roots_with_multiplicity(poly, -_sp.oo, _sp.oo))


def _root_intervals_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    poly = _single_variable_sympy_poly(arguments[0])
    intervals = poly.intervals()
    interval_exprs: list[Expr] = []
    multiplicity_exprs: list[Expr] = []
    for (lower, upper), multiplicity in intervals:
        interval_exprs.append(_evaluated_list_expr(_expr_from_sympy_exact(lower), _expr_from_sympy_exact(upper)))
        multiplicity_exprs.append(_evaluated_list_expr(integer(int(multiplicity))))
    return _evaluated_list_expr(_evaluated_list_expr(*interval_exprs), _evaluated_list_expr(*multiplicity_exprs))


def _isolating_interval_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    target = arguments[0]
    if isinstance(target, Integer | RationalNumber):
        return _evaluated_list_expr(target, target)
    if not isinstance(target, RootNumber):
        return None
    root = _root_to_sympy(target)
    exponent = _isolating_interval_exponent(arguments[1]) if len(arguments) == 2 else 6
    approximation = complex(_sp.N(root, max(30, exponent + 10)))
    if bool(root.is_real):
        lower, upper = _dyadic_bounds(approximation.real, exponent)
        return _evaluated_list_expr(_expr_from_sympy_exact(lower), _expr_from_sympy_exact(upper))
    lower_real, upper_real = _dyadic_bounds(approximation.real, exponent)
    lower_imag, upper_imag = _dyadic_bounds(approximation.imag, exponent)
    lower = complex_number(_expr_from_sympy_exact(lower_real), _expr_from_sympy_exact(lower_imag))
    upper = complex_number(_expr_from_sympy_exact(upper_real), _expr_from_sympy_exact(upper_imag))
    return _evaluated_list_expr(lower, upper)


def _root_sum_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    function = arguments[1]
    if not _is_callable_expr(function):
        return None
    expanded = _normal_root_sum_expr(arguments)
    if expanded is None:
        return None
    return _root_reduce_expr((expanded,)) or expanded


def _to_radicals_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    return _to_radicals(arguments[0])


def _normal_root_sum_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    poly_expr = _polynomial_function_to_sympy(arguments[0], _X)
    poly = _sp.Poly(poly_expr, _X, domain=_sp.QQ)
    roots = [_expr_from_sympy_root_or_number(_sp.CRootOf(poly.as_expr(), index)) for index in range(poly.degree())]
    if any(root is None for root in roots):
        return None
    terms: list[Expr] = []
    for root in roots:
        assert root is not None
        radical_root = _to_radicals(root)
        if _is_callable_expr(arguments[1]):
            terms.append(_apply_callable(arguments[1], (radical_root,)))
        else:
            terms.append(evaluate(call(arguments[1], radical_root)))
    return evaluate(call("Plus", *terms)) if terms else integer(0)


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


def _sympy_poly_in_variable(polynomial: Expr, variable: Expr) -> Any:
    from . import expression_polynomial as _polynomial

    bridge = _polynomial._SympyBridge((variable,))
    sym_var = bridge.expr_to_symbol[variable]
    sym_expr = bridge.to_sympy(polynomial)
    if sym_expr.free_symbols - {sym_var}:
        raise _AlgebraicConversionError(polynomial.to_full_form())
    try:
        poly = _sp.Poly(sym_expr, sym_var, domain=_sp.QQ)
    except Exception:
        poly = _sp.Poly(sym_expr, sym_var, extension=_sp.I)
    if poly.degree() <= 0:
        raise _AlgebraicConversionError(polynomial.to_full_form())
    return poly


def _single_variable_sympy_poly(polynomial: Expr) -> Any:
    from . import expression_polynomial as _polynomial

    sym_expr, _bridge = _polynomial._to_sympy_expr(polynomial)
    free_symbols = sorted(sym_expr.free_symbols, key=lambda item: item.name)
    if len(free_symbols) != 1:
        raise _AlgebraicConversionError(polynomial.to_full_form())
    variable = free_symbols[0]
    poly = _sp.Poly(sym_expr, variable, domain=_sp.QQ)
    if poly.degree() <= 0:
        raise _AlgebraicConversionError(polynomial.to_full_form())
    return poly


def _to_sympy_endpoint(expr: Expr) -> Any | None:
    if _is_positive_infinity_expr(expr):
        return _sp.oo
    if _is_negative_infinity_expr(expr):
        return -_sp.oo
    if (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.arguments) == 2
        and expr.arguments[0] == integer(-1)
        and _is_positive_infinity_expr(expr.arguments[1])
    ):
        return -_sp.oo
    try:
        return _to_sympy_algebraic(expr)
    except _AlgebraicConversionError:
        return None


def _count_roots_with_multiplicity(poly: Any, lower: Any, upper: Any) -> int:
    variable = poly.gens[0]
    total = 0
    for factor_expr, multiplicity in poly.factor_list()[1]:
        if isinstance(factor_expr, _sp.Poly):
            factor_poly = factor_expr
        else:
            try:
                factor_poly = _sp.Poly(factor_expr, variable, domain=_sp.QQ)
            except Exception:
                factor_poly = _sp.Poly(factor_expr, variable, extension=_sp.I)
        total += int(multiplicity) * int(factor_poly.count_roots(lower, upper))
    return total


def _isolating_interval_exponent(expr: Expr) -> int:
    if isinstance(expr, Integer) and expr.value > 0:
        return min(max(expr.value, 6), 30)
    return 6


def _dyadic_bounds(value: float, exponent: int) -> tuple[Any, Any]:
    denominator = 2 ** exponent
    scaled = value * denominator
    nearest = round(scaled)
    if abs(scaled - nearest) < 1e-12:
        doubled_denominator = denominator * 2
        return (
            _sp.Rational(2 * nearest - 1, doubled_denominator),
            _sp.Rational(2 * nearest + 1, doubled_denominator),
        )
    lower_numerator = math.floor(scaled)
    return (
        _sp.Rational(lower_numerator, denominator),
        _sp.Rational(lower_numerator + 1, denominator),
    )


def _to_radicals(expr: Expr) -> Expr:
    if isinstance(expr, RootNumber):
        return _root_to_radicals(expr)
    if isinstance(expr, Call):
        converted_arguments = tuple(_to_radicals(argument) for argument in expr.arguments)
        if converted_arguments != expr.arguments:
            return evaluate(call(expr.head_expr, *converted_arguments))
    return expr


def _root_to_radicals(root: RootNumber) -> Expr:
    poly_expr = _poly_expr_from_coefficients(root.coefficients, _X)
    poly = _sp.Poly(poly_expr, _X, domain=_sp.QQ)
    degree = poly.degree()
    if degree < 1 or degree > 4:
        return root
    candidates: list[Any] = []
    for candidate, multiplicity in _sp.roots(poly.as_expr(), _X).items():
        candidates.extend([candidate] * int(multiplicity))
    if len(candidates) != degree:
        candidates = list(_sp.solve(poly.as_expr(), _X))
    if len(candidates) != degree:
        return root
    target = _root_to_sympy(root)
    chosen = _choose_root_by_approximation(candidates, complex(_sp.N(target, 80)))
    try:
        return evaluate(_expr_from_sympy_radical(chosen))
    except _AlgebraicConversionError:
        return root


def _expr_from_sympy_radical(expr: Any) -> Expr:
    expr = _sp.sympify(expr)
    direct = _expr_from_sympy_root_or_number(expr)
    if direct is not None:
        return direct
    if expr.is_Add:
        return evaluate(call("Plus", *(_expr_from_sympy_radical(term) for term in expr.as_ordered_terms())))
    if expr.is_Mul:
        return evaluate(call("Times", *(_expr_from_sympy_radical(factor) for factor in expr.as_ordered_factors())))
    if expr.is_Pow:
        return evaluate(call("Power", _expr_from_sympy_radical(expr.base), _expr_from_sympy_radical(expr.exp)))
    raise _AlgebraicConversionError(str(expr))


def _expr_from_sympy_exact(expr: Any) -> Expr:
    converted = _expr_from_sympy_root_or_number(expr)
    if converted is None:
        raise _AlgebraicConversionError(str(expr))
    return converted


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
