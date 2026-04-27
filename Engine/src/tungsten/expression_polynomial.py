from __future__ import annotations

from dataclasses import dataclass, field
from functools import cmp_to_key
from math import gcd
from typing import Any, Sequence

import sympy as _sp

from . import expression as _runtime

globals().update(
    {name: getattr(_runtime, name) for name in dir(_runtime) if not name.startswith("__")}
)


class _PolynomialConversionError(ValueError):
    """Raised when an expression is outside Tungsten's exact polynomial subset."""


@dataclass
class _SympyBridge:
    explicit_variables: Sequence[Expr] = ()
    expr_to_symbol: dict[Expr, Any] = field(default_factory=dict)
    symbol_to_expr: dict[Any, Expr] = field(default_factory=dict)
    name_to_symbol: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for index, variable in enumerate(self.explicit_variables):
            if isinstance(variable, Symbol):
                sym = self._symbol_for_name(variable.name)
            else:
                sym = _sp.Dummy(f"tungsten_var_{index}")
            self.expr_to_symbol[variable] = sym
            self.symbol_to_expr[sym] = variable

    def _symbol_for_name(self, name: str) -> Any:
        sym = self.name_to_symbol.get(name)
        if sym is None:
            sym = _sp.Symbol(name)
            self.name_to_symbol[name] = sym
            self.symbol_to_expr.setdefault(sym, symbol(name))
        return sym

    def to_sympy(self, expr: Expr) -> Any:
        explicit = self.expr_to_symbol.get(expr)
        if explicit is not None:
            return explicit
        if isinstance(expr, Integer):
            return _sp.Integer(expr.value)
        if isinstance(expr, RationalNumber):
            return _sp.Rational(expr.value.numerator, expr.value.denominator)
        if isinstance(expr, ComplexNumber):
            return self.to_sympy(expr.real_part) + _sp.I * self.to_sympy(expr.imaginary_part)
        if isinstance(expr, Symbol):
            return self._symbol_for_name(expr.name)
        if isinstance(expr, Call):
            if expr.has_head("Plus"):
                return _sp.Add(*(self.to_sympy(argument) for argument in expr.arguments))
            if expr.has_head("Times"):
                return _sp.Mul(*(self.to_sympy(argument) for argument in expr.arguments))
            if expr.has_head("Power") and len(expr.arguments) == 2:
                return _sp.Pow(self.to_sympy(expr.arguments[0]), self.to_sympy(expr.arguments[1]))
        raise _PolynomialConversionError(expr.to_full_form())

    def from_sympy(self, expr: Any) -> Expr:
        expr = _sp.sympify(expr)
        if expr is _sp.S.Infinity:
            return symbol("Infinity")
        if expr is _sp.S.NegativeInfinity:
            return symbol("-Infinity")
        number_expr = self._from_sympy_number(expr)
        if number_expr is not None:
            return number_expr
        if expr.is_number:
            raise _PolynomialConversionError(str(expr))
        if expr.is_Symbol:
            return self.symbol_to_expr.get(expr, symbol(str(expr)))
        if expr.is_Add:
            terms = tuple(self.from_sympy(term) for term in expr.as_ordered_terms())
            return evaluate(call("Plus", *terms))
        if expr.is_Mul:
            factors = tuple(self.from_sympy(factor) for factor in expr.as_ordered_factors())
            return evaluate(call("Times", *factors))
        if expr.is_Pow:
            return evaluate(call("Power", self.from_sympy(expr.base), self.from_sympy(expr.exp)))
        raise _PolynomialConversionError(str(expr))

    def _from_sympy_number(self, expr: Any) -> Expr | None:
        if expr.is_Integer:
            return integer(int(expr))
        if expr.is_Rational:
            return rational_number(int(expr.p), int(expr.q))
        if not expr.is_number:
            return None
        real_part, imaginary_part = expr.as_real_imag()
        real_expr = self._from_sympy_rational(real_part)
        imaginary_expr = self._from_sympy_rational(imaginary_part)
        if real_expr is None or imaginary_expr is None:
            return None
        return complex_number(real_expr, imaginary_expr)

    def _from_sympy_rational(self, expr: Any) -> Expr | None:
        expr = _sp.sympify(expr)
        if expr.is_Integer:
            return integer(int(expr))
        if expr.is_Rational:
            return rational_number(int(expr.p), int(expr.q))
        return None


def _evaluate_polynomial_functions(expr: Call) -> Expr | None:
    if expr.has_head("Expand"):
        return _expand_expr(expr.arguments)
    if expr.has_head("PolynomialQ"):
        return _polynomial_q_expr(expr.arguments)
    if expr.has_head("Variables"):
        return _variables_expr(expr.arguments)
    if expr.has_head("MonomialList"):
        return _monomial_list_expr(expr.arguments)
    if expr.has_head("Collect"):
        return _collect_expr(expr.arguments)
    if expr.has_head("Coefficient"):
        return _coefficient_expr(expr.arguments)
    if expr.has_head("Exponent"):
        return _exponent_expr(expr.arguments)
    if expr.has_head("CoefficientList"):
        return _coefficient_list_expr(expr.arguments)
    if expr.has_head("Factor"):
        return _factor_expr(expr.arguments)
    if expr.has_head("FactorList"):
        return _factor_list_expr(expr.arguments)
    if expr.has_head("Decompose"):
        return _decompose_expr(expr.arguments)
    return None


def _expand_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0])
        return bridge.from_sympy(_sp.expand(sym_expr))
    except _PolynomialConversionError:
        return None


def _polynomial_q_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    variables = _variable_exprs(arguments[1]) if len(arguments) == 2 else ()
    if variables is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0], variables)
        if variables:
            sym_vars = [bridge.to_sympy(variable) for variable in variables]
        else:
            sym_vars = sorted(sym_expr.free_symbols, key=lambda item: str(item))
        return _bool_symbol(bool(sym_expr.is_polynomial(*sym_vars)))
    except _PolynomialConversionError:
        return _bool_symbol(False)


def _variables_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0])
    except _PolynomialConversionError:
        return None
    variables = [bridge.symbol_to_expr.get(sym, symbol(str(sym))) for sym in sym_expr.free_symbols]
    variables.sort(key=cmp_to_key(_canonical_compare))
    return _evaluated_list_expr(*variables)


def _monomial_list_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    try:
        variable_exprs = _variable_exprs(arguments[1]) if len(arguments) == 2 else None
        if variable_exprs is None:
            sym_expr, bridge = _to_sympy_expr(arguments[0])
            variables = _free_symbols_as_variables(sym_expr, bridge)
        else:
            sym_expr, bridge = _to_sympy_expr(arguments[0], variable_exprs)
            variables = [bridge.to_sympy(variable) for variable in variable_exprs]
        if not variables:
            if sym_expr == 0:
                return _evaluated_list_expr()
            return _evaluated_list_expr(bridge.from_sympy(sym_expr))
        poly = _sp.Poly(sym_expr, *variables) if variables else _sp.Poly(sym_expr)
        monomials: list[Expr] = []
        for powers, coefficient in poly.terms():
            term = coefficient
            for variable, exponent in zip(variables, powers):
                if exponent:
                    term *= variable ** exponent
            monomials.append(bridge.from_sympy(term))
        return _evaluated_list_expr(*monomials)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _collect_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    variable_exprs = _variable_exprs(arguments[1])
    if variable_exprs is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0], variable_exprs)
        sym_vars = [bridge.to_sympy(variable) for variable in variable_exprs]
        collected = _sp.collect(_sp.expand(sym_expr), sym_vars, evaluate=True)
        return bridge.from_sympy(collected)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _coefficient_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    exponent = 1
    if len(arguments) == 3:
        if not isinstance(arguments[2], Integer):
            return None
        exponent = arguments[2].value
        if exponent < 0:
            return integer(0)
    try:
        sym_expr, sym_form, bridge = _to_sympy_expr_and_form(arguments[0], arguments[1])
        coefficient = _sp.expand(sym_expr).coeff(sym_form, exponent)
        return bridge.from_sympy(coefficient)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _exponent_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    forms = _variable_exprs(arguments[1])
    if forms is not None and isinstance(arguments[1], Call) and arguments[1].has_head("List"):
        return _evaluated_list_expr(
            *(
                _exponent_expr((arguments[0], form, *arguments[2:]))
                or call("Exponent", arguments[0], form)
                for form in forms
            )
        )
    try:
        sym_expr, sym_form, bridge = _to_sympy_expr_and_form(arguments[0], arguments[1])
        exponents = _monomial_exponents_for_form(_sp.expand(sym_expr), sym_form)
        if len(arguments) == 3:
            return _apply_callable(arguments[2], tuple(_exponent_value_expr(value) for value in sorted(exponents)))
        return _exponent_value_expr(max(exponents))
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _coefficient_list_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    variable_exprs = _variable_exprs(arguments[1])
    if variable_exprs is None:
        return None
    dimensions = _coefficient_dimensions(arguments[2], len(variable_exprs)) if len(arguments) == 3 else None
    if len(arguments) == 3 and dimensions is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0], variable_exprs)
        sym_vars = [bridge.to_sympy(variable) for variable in variable_exprs]
        return _coefficient_array_expr(_sp.expand(sym_expr), sym_vars, bridge, dimensions)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _factor_expr(arguments: Sequence[Expr]) -> Expr | None:
    if not arguments:
        return None
    options = _factor_options(arguments[1:])
    if options is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0])
        return bridge.from_sympy(_sp.factor(sym_expr, **options))
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _factor_list_expr(arguments: Sequence[Expr]) -> Expr | None:
    if not arguments:
        return None
    options = _factor_options(arguments[1:])
    if options is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0])
        coefficient, factors = _sp.factor_list(sym_expr, **options)
        entries = [_evaluated_list_expr(bridge.from_sympy(coefficient), integer(1))]
        for factor, exponent in factors:
            entries.append(_evaluated_list_expr(bridge.from_sympy(factor), integer(int(exponent))))
        return _evaluated_list_expr(*entries)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _decompose_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    variables = _variable_exprs(arguments[1])
    if variables is None or len(variables) != 1:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0], variables)
        sym_var = bridge.to_sympy(variables[0])
        decomposition = [_sp.expand(part) for part in _sp.decompose(_sp.expand(sym_expr), sym_var)]
        decomposition = _wolframize_decomposition(sym_expr, sym_var, decomposition)
        return _evaluated_list_expr(*(bridge.from_sympy(part) for part in decomposition))
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _factor_options(option_exprs: Sequence[Expr]) -> dict[str, Any] | None:
    use_gaussian_extension = False
    for option in option_exprs:
        if not isinstance(option, Call) or not option.has_head("Rule") or len(option.arguments) != 2:
            return None
        key, value = option.arguments
        if _is_option_symbol(key, "GaussianIntegers"):
            truth = _truth_value(value)
            if truth is None:
                return None
            use_gaussian_extension = use_gaussian_extension or truth
            continue
        if _is_option_symbol(key, "Extension"):
            extension = _extension_option_value(value)
            if extension is None:
                return None
            use_gaussian_extension = use_gaussian_extension or extension
            continue
        return None
    return {"extension": _sp.I} if use_gaussian_extension else {}


def _is_option_symbol(expr: Expr, name: str) -> bool:
    return isinstance(expr, Symbol) and _system_dispatch_name(expr) == name


def _extension_option_value(value: Expr) -> bool | None:
    if _is_option_symbol(value, "None"):
        return False
    if _is_gaussian_extension_generator(value):
        return True
    if isinstance(value, Call) and value.has_head("List"):
        if not value.arguments:
            return False
        if all(_is_gaussian_extension_generator(argument) for argument in value.arguments):
            return True
        return None
    return None


def _is_gaussian_extension_generator(expr: Expr) -> bool:
    if isinstance(expr, ComplexNumber):
        return _is_exact_zero(expr.real_part) and _is_exact_one(expr.imaginary_part)
    return False


def _is_exact_one(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == 1
    if isinstance(expr, RationalNumber):
        return expr.value == 1
    return False


def _wolframize_decomposition(sym_expr: Any, sym_var: Any, decomposition: Sequence[Any]) -> list[Any]:
    if len(decomposition) != 1:
        return list(decomposition)
    fallback = _exponent_gcd_decomposition(sym_expr, sym_var)
    if fallback is not None:
        return fallback
    return list(decomposition)


def _exponent_gcd_decomposition(sym_expr: Any, sym_var: Any) -> list[Any] | None:
    poly = _sp.Poly(_sp.expand(sym_expr), sym_var)
    terms = poly.terms()
    nonzero_exponents = [int(powers[0]) for powers, coefficient in terms if powers[0] and coefficient != 0]
    if len(nonzero_exponents) < 2 and poly.as_dict().get((0,), _sp.Integer(0)) == 0:
        return None
    exponent_gcd = 0
    for exponent in nonzero_exponents:
        exponent_gcd = exponent if exponent_gcd == 0 else gcd(exponent_gcd, exponent)
    if exponent_gcd <= 1:
        return None
    outer = _sp.Integer(0)
    for (exponent,), coefficient in terms:
        if exponent % exponent_gcd != 0:
            return None
        outer += coefficient * sym_var ** (exponent // exponent_gcd)
    inner = sym_var ** exponent_gcd
    if _sp.expand(outer - sym_var) == 0:
        return None
    return [_sp.expand(outer), inner]


def _to_sympy_expr(expr: Expr, variables: Sequence[Expr] = ()) -> tuple[Any, _SympyBridge]:
    bridge = _SympyBridge(tuple(variables))
    return bridge.to_sympy(expr), bridge


def _to_sympy_expr_and_form(expr: Expr, form: Expr) -> tuple[Any, Any, _SympyBridge]:
    bridge = _SympyBridge(())
    try:
        return bridge.to_sympy(expr), bridge.to_sympy(form), bridge
    except _PolynomialConversionError:
        bridge = _SympyBridge((form,))
        return bridge.to_sympy(expr), bridge.to_sympy(form), bridge


def _variable_exprs(spec: Expr) -> tuple[Expr, ...] | None:
    if isinstance(spec, Call) and spec.has_head("List"):
        return tuple(spec.arguments)
    return (spec,)


def _free_symbols_as_variables(sym_expr: Any, bridge: _SympyBridge) -> list[Any]:
    variables = sorted(
        sym_expr.free_symbols,
        key=lambda sym: cmp_to_key(_canonical_compare)(bridge.symbol_to_expr.get(sym, symbol(str(sym)))),
    )
    return variables


def _monomial_exponents_for_form(sym_expr: Any, sym_form: Any) -> set[int]:
    if sym_expr == 0:
        return {-1_000_000_000}
    form_powers = _monomial_power_dict(sym_form)
    if form_powers is None:
        raise _PolynomialConversionError(str(sym_form))
    if not form_powers:
        return {0}
    exponents: set[int] = set()
    for term in _sp.Add.make_args(_sp.expand(sym_expr)):
        term_powers = term.as_powers_dict()
        per_factor: list[int] = []
        for variable, exponent in form_powers.items():
            term_exponent = term_powers.get(variable, _sp.Integer(0))
            if not term_exponent.is_integer:
                per_factor.append(0)
                continue
            per_factor.append(max(0, int(term_exponent) // exponent))
        exponents.add(min(per_factor) if per_factor else 0)
    return exponents or {0}


def _monomial_power_dict(sym_form: Any) -> dict[Any, int] | None:
    coefficient, factors = _sp.Mul(sym_form).as_coeff_mul()
    if coefficient != 1:
        return None
    powers: dict[Any, int] = {}
    for factor in factors:
        base, exponent = factor.as_base_exp()
        if not exponent.is_integer or int(exponent) <= 0:
            return None
        powers[base] = powers.get(base, 0) + int(exponent)
    return powers


def _exponent_value_expr(value: int) -> Expr:
    if value == -1_000_000_000:
        return symbol("-Infinity")
    return integer(value)


def _coefficient_dimensions(spec: Expr, variable_count: int) -> tuple[int, ...] | None:
    if isinstance(spec, Integer):
        if variable_count != 1:
            return None
        return (spec.value,)
    if not isinstance(spec, Call) or not spec.has_head("List"):
        return None
    dimensions: list[int] = []
    for argument in spec.arguments:
        if not isinstance(argument, Integer) or argument.value < 0:
            return None
        dimensions.append(argument.value)
    if len(dimensions) != variable_count:
        return None
    return tuple(dimensions)


def _coefficient_array_expr(
    sym_expr: Any,
    variables: Sequence[Any],
    bridge: _SympyBridge,
    dimensions: tuple[int, ...] | None,
) -> Expr:
    if not variables:
        return bridge.from_sympy(sym_expr)
    if sym_expr == 0 and dimensions is None:
        return _evaluated_list_expr()
    variable = variables[0]
    rest = variables[1:]
    if dimensions is None:
        degree = _sp.Poly(sym_expr, variable).degree()
        if degree < 0:
            return _evaluated_list_expr()
        count = int(degree) + 1
        rest_dimensions = None
    else:
        count = dimensions[0]
        rest_dimensions = dimensions[1:]
    items = [
        _coefficient_array_expr(_sp.expand(sym_expr).coeff(variable, index), rest, bridge, rest_dimensions)
        for index in range(count)
    ]
    return _evaluated_list_expr(*items)
