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
    if expr.has_head("Numerator"):
        return _fraction_part_expr(expr.arguments, numerator=True)
    if expr.has_head("Denominator"):
        return _fraction_part_expr(expr.arguments, numerator=False)
    if expr.has_head("Together"):
        return _together_expr(expr.arguments)
    if expr.has_head("Apart"):
        return _apart_expr(expr.arguments)
    if expr.has_head("Cancel"):
        return _cancel_expr(expr.arguments)
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
    if expr.has_head("PolynomialGCD"):
        return _polynomial_gcd_lcm_expr(expr.arguments, use_lcm=False)
    if expr.has_head("PolynomialLCM"):
        return _polynomial_gcd_lcm_expr(expr.arguments, use_lcm=True)
    if expr.has_head("PolynomialMod"):
        return _polynomial_mod_expr(expr.arguments)
    if expr.has_head("PolynomialQuotient"):
        return _polynomial_division_expr(expr.arguments, quotient=True)
    if expr.has_head("PolynomialRemainder"):
        return _polynomial_division_expr(expr.arguments, quotient=False)
    if expr.has_head("PolynomialReduce"):
        return _polynomial_reduce_expr(expr.arguments)
    if expr.has_head("Resultant"):
        return _resultant_expr(expr.arguments)
    if expr.has_head("Discriminant"):
        return _discriminant_expr(expr.arguments)
    if expr.has_head("Subresultants"):
        return _subresultants_expr(expr.arguments)
    if expr.has_head("GroebnerBasis"):
        return _groebner_basis_expr(expr.arguments)
    return None


def _fraction_part_expr(arguments: Sequence[Expr], *, numerator: bool) -> Expr | None:
    if len(arguments) != 1:
        return None
    argument = arguments[0]
    if isinstance(argument, Call) and argument.has_head("List"):
        items = []
        for item in argument.arguments:
            part = _fraction_part_expr((item,), numerator=numerator)
            if part is None:
                return None
            items.append(part)
        return _evaluated_list_expr(*items)
    try:
        sym_expr, bridge = _to_sympy_expr(argument)
        sym_numerator, sym_denominator = _sp.fraction(sym_expr, exact=True)
        return bridge.from_sympy(sym_numerator if numerator else sym_denominator)
    except _PolynomialConversionError:
        return None


def _together_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    argument = arguments[0]
    if isinstance(argument, Call) and argument.has_head("List"):
        items = []
        for item in argument.arguments:
            simplified = _together_expr((item,))
            if simplified is None:
                return None
            items.append(simplified)
        return _evaluated_list_expr(*items)
    try:
        sym_expr, bridge = _to_sympy_expr(argument)
        return bridge.from_sympy(_sp.together(sym_expr))
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _cancel_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    argument = arguments[0]
    if isinstance(argument, Call) and argument.has_head("List"):
        items = []
        for item in argument.arguments:
            simplified = _cancel_expr((item,))
            if simplified is None:
                return None
            items.append(simplified)
        return _evaluated_list_expr(*items)
    try:
        sym_expr, bridge = _to_sympy_expr(argument)
        return bridge.from_sympy(_sp.cancel(sym_expr))
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _apart_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    try:
        if len(arguments) == 1:
            sym_expr, bridge = _to_sympy_expr(arguments[0])
            return bridge.from_sympy(_sp.apart(sym_expr))
        variables = _variable_exprs(arguments[1])
        if variables is None or len(variables) != 1:
            return None
        sym_expr, bridge = _to_sympy_expr(arguments[0], variables)
        sym_var = bridge.to_sympy(variables[0])
        return bridge.from_sympy(_sp.apart(sym_expr, sym_var))
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _expand_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    try:
        if len(arguments) == 1:
            sym_expr, bridge = _to_sympy_expr(arguments[0])
            return _expanded_expr_from_sympy(_sp.expand(sym_expr), bridge)
        pattern = arguments[1]
        target_exprs = _pattern_target_exprs(arguments[0], pattern)
        if target_exprs:
            sym_expr, bridge = _to_sympy_expr(arguments[0], target_exprs)
            target_symbols = {bridge.to_sympy(target) for target in target_exprs}
            protected, replacements = _protect_sympy_free_of(sym_expr, target_symbols)
            expanded = _sp.expand(protected).xreplace(replacements)
            return _expanded_expr_from_sympy(expanded, bridge)
        if _expr_contains_pattern(arguments[0], pattern):
            sym_expr, bridge = _to_sympy_expr(arguments[0])
            return _expanded_expr_from_sympy(_sp.expand(sym_expr), bridge)
        return arguments[0]
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
    if len(arguments) not in {1, 2, 3}:
        return None
    try:
        monomial_order = _monomial_order_name(arguments[-1]) if len(arguments) >= 2 else None
        if len(arguments) == 3:
            if monomial_order is None:
                return None
            variable_exprs = _variable_exprs(arguments[1])
        elif len(arguments) == 2:
            variable_exprs = None if monomial_order is not None else _variable_exprs(arguments[1])
        else:
            variable_exprs = None
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
        order_name, reverse = monomial_order or ("lex", True)
        order_function = getattr(_sp.polys.orderings, order_name)
        sorted_terms = sorted(poly.terms(), key=lambda term: order_function(term[0]), reverse=reverse)
        monomials: list[Expr] = []
        for powers, coefficient in sorted_terms:
            term = coefficient
            for variable, exponent in zip(variables, powers):
                if exponent:
                    term *= variable ** exponent
            monomials.append(bridge.from_sympy(term))
        return _evaluated_list_expr(*monomials)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _collect_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    variable_exprs = _variable_exprs(arguments[1])
    if variable_exprs is None:
        return None
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0], variable_exprs)
        sym_vars = [bridge.to_sympy(variable) for variable in variable_exprs]
        if len(arguments) == 3:
            return _collect_with_transform(sym_expr, sym_vars, bridge, arguments[2])
        collected = _sp.collect(_sp.expand(sym_expr), sym_vars, evaluate=True)
        return bridge.from_sympy(collected)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _coefficient_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    if len(arguments) == 3:
        per_variable = _coefficient_multi_exponent_expr(arguments)
        if per_variable is not None:
            return per_variable
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
    except (_PolynomialConversionError, _sp.PolynomialError, _sp.polys.polyerrors.NotInvertible, ValueError):
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
    except (_PolynomialConversionError, _sp.PolynomialError, _sp.polys.polyerrors.NotInvertible, ValueError):
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


def _polynomial_gcd_lcm_expr(arguments: Sequence[Expr], *, use_lcm: bool) -> Expr | None:
    if not arguments:
        return integer(1 if use_lcm else 0)
    try:
        bridge = _SympyBridge(())
        sym_exprs = [bridge.to_sympy(argument) for argument in arguments]
        result = _sp.lcm_list(sym_exprs) if use_lcm else _sp.gcd_list(sym_exprs)
        if use_lcm:
            result = _sp.factor(result)
        return bridge.from_sympy(result)
    except (_PolynomialConversionError, _sp.PolynomialError):
        return None


def _polynomial_mod_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    modulus_expr = arguments[1]
    if not isinstance(modulus_expr, Integer) or modulus_expr.value <= 1:
        return None
    modulus = modulus_expr.value
    try:
        sym_expr, bridge = _to_sympy_expr(arguments[0])
        variables = _free_symbols_as_variables(sym_expr, bridge)
        if not variables:
            residue = _coefficient_mod(sym_expr, modulus)
            return bridge.from_sympy(residue) if residue is not None else None
        poly = _sp.Poly(_sp.expand(sym_expr), *variables)
        result = _sp.Integer(0)
        for powers, coefficient in poly.terms():
            residue = _coefficient_mod(coefficient, modulus)
            if residue is None:
                return None
            if residue == 0:
                continue
            term = residue
            for variable, exponent in zip(variables, powers):
                if exponent:
                    term *= variable ** exponent
            result += term
        return bridge.from_sympy(_sp.expand(result))
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _polynomial_division_expr(arguments: Sequence[Expr], *, quotient: bool) -> Expr | None:
    if len(arguments) != 3:
        return None
    variables = _variable_exprs(arguments[2])
    if variables is None or len(variables) != 1:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_a = bridge.to_sympy(arguments[0])
        sym_b = bridge.to_sympy(arguments[1])
        sym_var = bridge.to_sympy(variables[0])
        result = _sp.quo(sym_a, sym_b, sym_var) if quotient else _sp.rem(sym_a, sym_b, sym_var)
        return bridge.from_sympy(_sp.expand(result))
    except (_PolynomialConversionError, _sp.PolynomialError, ZeroDivisionError):
        return None


def _polynomial_reduce_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 3:
        return None
    reducers_expr = arguments[1]
    if not isinstance(reducers_expr, Call) or not reducers_expr.has_head("List"):
        return None
    variables = _variable_exprs(arguments[2])
    if variables is None or not variables:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_poly = bridge.to_sympy(arguments[0])
        sym_reducers = [bridge.to_sympy(reducer) for reducer in reducers_expr.arguments]
        sym_vars = [bridge.to_sympy(variable) for variable in variables]
        quotients, remainder = _sp.reduced(sym_poly, sym_reducers, *sym_vars)
        quotient_exprs = [bridge.from_sympy(_sp.expand(quotient)) for quotient in quotients]
        return _evaluated_list_expr(
            _evaluated_list_expr(*quotient_exprs),
            bridge.from_sympy(_sp.expand(remainder)),
        )
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _resultant_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 3:
        return None
    variables = _variable_exprs(arguments[2])
    if variables is None or len(variables) != 1:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_p = bridge.to_sympy(arguments[0])
        sym_q = bridge.to_sympy(arguments[1])
        sym_var = bridge.to_sympy(variables[0])
        return bridge.from_sympy(_sp.resultant(sym_p, sym_q, sym_var))
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _discriminant_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    variables = _variable_exprs(arguments[1])
    if variables is None or len(variables) != 1:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_poly = bridge.to_sympy(arguments[0])
        sym_var = bridge.to_sympy(variables[0])
        return bridge.from_sympy(_sp.discriminant(sym_poly, sym_var))
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _subresultants_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 3:
        return None
    variables = _variable_exprs(arguments[2])
    if variables is None or len(variables) != 1:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_p = bridge.to_sympy(arguments[0])
        sym_q = bridge.to_sympy(arguments[1])
        sym_var = bridge.to_sympy(variables[0])
        coeffs = _principal_subresultant_coefficients(sym_p, sym_q, sym_var)
        return _evaluated_list_expr(*(bridge.from_sympy(_sp.expand(coefficient)) for coefficient in coeffs))
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _groebner_basis_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 2:
        return None
    polys_expr = arguments[0]
    if not isinstance(polys_expr, Call) or not polys_expr.has_head("List"):
        return None
    variables = _variable_exprs(arguments[1])
    if variables is None or not variables:
        return None
    try:
        bridge = _SympyBridge(variables)
        sym_polys = [bridge.to_sympy(poly) for poly in polys_expr.arguments]
        sym_vars = [bridge.to_sympy(variable) for variable in variables]
        basis = _sp.groebner(sym_polys, *sym_vars)
        basis_exprs = [bridge.from_sympy(_sp.expand(poly.as_expr())) for poly in basis.polys]
        basis_exprs.sort(key=cmp_to_key(_canonical_compare))
        return _evaluated_list_expr(*basis_exprs)
    except (_PolynomialConversionError, _sp.PolynomialError, ValueError):
        return None


def _factor_options(option_exprs: Sequence[Expr]) -> dict[str, Any] | None:
    use_gaussian_extension = False
    modulus: int | None = None
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
        if _is_option_symbol(key, "Modulus"):
            if not isinstance(value, Integer) or value.value <= 1:
                return None
            modulus = value.value
            continue
        return None
    if modulus is not None and use_gaussian_extension:
        return None
    if modulus is not None:
        return {"modulus": modulus}
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


def _pattern_target_exprs(expr: Expr, pattern: Expr) -> tuple[Expr, ...]:
    targets: list[Expr] = []
    seen: set[Expr] = set()

    def visit(current: Expr) -> None:
        if _match_pattern(current, pattern) is not None and _is_expand_target_leaf(current):
            if current not in seen:
                seen.add(current)
                targets.append(current)
            return
        if isinstance(current, Call):
            for argument in current.arguments:
                visit(argument)

    visit(expr)
    targets.sort(key=cmp_to_key(_canonical_compare))
    return tuple(targets)


def _is_expand_target_leaf(expr: Expr) -> bool:
    if isinstance(expr, Symbol):
        return True
    if isinstance(expr, Call):
        return not expr.has_head("Plus") and not expr.has_head("Times") and not expr.has_head("Power")
    return False


def _expr_contains_pattern(expr: Expr, pattern: Expr) -> bool:
    if _match_pattern(expr, pattern) is not None:
        return True
    if isinstance(expr, Call):
        return any(_expr_contains_pattern(argument, pattern) for argument in expr.arguments)
    return False


def _protect_sympy_free_of(sym_expr: Any, target_symbols: set[Any]) -> tuple[Any, dict[Any, Any]]:
    replacements_by_expr: dict[Any, Any] = {}
    replacements_by_dummy: dict[Any, Any] = {}

    def visit(current: Any) -> Any:
        current = _sp.sympify(current)
        if current.is_number:
            return current
        if not (current.free_symbols & target_symbols):
            dummy = replacements_by_expr.get(current)
            if dummy is None:
                dummy = _sp.Dummy("tungsten_expand_hold")
                replacements_by_expr[current] = dummy
                replacements_by_dummy[dummy] = current
            return dummy
        if not current.args:
            return current
        return current.func(*(visit(argument) for argument in current.args))

    return visit(sym_expr), replacements_by_dummy


def _expanded_expr_from_sympy(sym_expr: Any, bridge: _SympyBridge) -> Expr:
    sym_expr = _sp.sympify(sym_expr)
    if not sym_expr.is_Add:
        return bridge.from_sympy(sym_expr)
    terms = [bridge.from_sympy(term) for term in sym_expr.as_ordered_terms()]
    terms.sort(key=cmp_to_key(_canonical_compare))
    return call("Plus", *terms)


def _monomial_order_name(order_expr: Expr) -> tuple[str, bool] | None:
    if not isinstance(order_expr, Symbol):
        return None
    order = _system_dispatch_name(order_expr)
    if order == "Lexicographic":
        return "lex", True
    if order == "DegreeLexicographic":
        return "grlex", True
    if order == "DegreeReverseLexicographic":
        return "grevlex", True
    if order == "NegativeLexicographic":
        return "lex", False
    if order == "NegativeDegreeLexicographic":
        return "grlex", False
    if order == "NegativeDegreeReverseLexicographic":
        return "grevlex", False
    return None


def _free_symbols_as_variables(sym_expr: Any, bridge: _SympyBridge) -> list[Any]:
    variables = sorted(
        sym_expr.free_symbols,
        key=lambda sym: cmp_to_key(_canonical_compare)(bridge.symbol_to_expr.get(sym, symbol(str(sym)))),
    )
    return variables


def _collect_with_transform(sym_expr: Any, variables: Sequence[Any], bridge: _SympyBridge, function: Expr) -> Expr:
    if not variables:
        return _apply_callable(function, (bridge.from_sympy(sym_expr),))
    poly = _sp.Poly(_sp.expand(sym_expr), *variables)
    terms: list[Expr] = []
    for powers, coefficient in poly.terms():
        coefficient_expr = _apply_callable(function, (bridge.from_sympy(coefficient),))
        monomial = _sp.Integer(1)
        for variable, exponent in zip(variables, powers):
            if exponent:
                monomial *= variable ** exponent
        if monomial == 1:
            terms.append(coefficient_expr)
        else:
            terms.append(evaluate(call("Times", bridge.from_sympy(monomial), coefficient_expr)))
    if not terms:
        return _apply_callable(function, (integer(0),))
    return evaluate(call("Plus", *terms))


def _coefficient_multi_exponent_expr(arguments: Sequence[Expr]) -> Expr | None:
    forms_expr = arguments[1]
    exponents_expr = arguments[2]
    if not (
        isinstance(forms_expr, Call)
        and forms_expr.has_head("List")
        and isinstance(exponents_expr, Call)
        and exponents_expr.has_head("List")
    ):
        return None
    if len(forms_expr.arguments) != len(exponents_expr.arguments):
        return None
    coefficients: list[Expr] = []
    for form, exponent in zip(forms_expr.arguments, exponents_expr.arguments):
        if not isinstance(exponent, Integer):
            return None
        coefficient = _coefficient_expr((arguments[0], form, exponent))
        if coefficient is None:
            return None
        coefficients.append(coefficient)
    return _evaluated_list_expr(*coefficients)


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


def _coefficient_mod(coefficient: Any, modulus: int) -> Any | None:
    coefficient = _sp.sympify(coefficient)
    if coefficient.is_Integer:
        return _sp.Integer(int(coefficient) % modulus)
    if coefficient.is_Rational:
        numerator = int(coefficient.p) % modulus
        denominator = int(coefficient.q) % modulus
        if denominator == 0:
            return None
        try:
            return _sp.Integer((numerator * pow(denominator, -1, modulus)) % modulus)
        except ValueError:
            return None
    return None


def _principal_subresultant_coefficients(sym_p: Any, sym_q: Any, sym_var: Any) -> list[Any]:
    poly_p = _sp.Poly(sym_p, sym_var)
    poly_q = _sp.Poly(sym_q, sym_var)
    degree_p = poly_p.degree()
    degree_q = poly_q.degree()
    if degree_p < 0 or degree_q < 0:
        raise _PolynomialConversionError("Subresultants are undefined for zero polynomials.")
    limit = min(int(degree_p), int(degree_q))
    degree_to_poly: dict[int, Any] = {}
    for subresultant in _sp.subresultants(sym_p, sym_q, sym_var):
        poly = _sp.Poly(subresultant, sym_var)
        degree = poly.degree()
        if degree < 0:
            continue
        degree = int(degree)
        if 0 <= degree <= limit:
            degree_to_poly[degree] = poly
    coefficients: list[Any] = []
    for index in range(limit + 1):
        poly = degree_to_poly.get(index)
        coefficients.append(_sp.Integer(0) if poly is None else poly.nth(index))
    return coefficients


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
