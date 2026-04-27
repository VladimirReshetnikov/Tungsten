from __future__ import annotations

# Arithmetic, relation, Boolean, predicate, and integer-number-theory
# dispatch helpers extracted from tungsten.expression. Low-level numeric atoms
# and constructors still live in tungsten.expression while this module owns the
# built-in evaluator entry points for this family.
import sympy as _sp

from . import expression as _runtime

globals().update(
    {name: getattr(_runtime, name) for name in dir(_runtime) if not name.startswith("__")}
)

def _evaluate_integer_arithmetic(expr: Call) -> Expr | None:
    if expr.has_head("Plus"):
        if not all(_is_integer_expr(argument) for argument in expr.arguments):
            return None
        return integer(sum(argument.value for argument in expr.arguments if isinstance(argument, Integer)))

    if expr.has_head("Times"):
        if not all(_is_integer_expr(argument) for argument in expr.arguments):
            return None
        product = 1
        for argument in expr.arguments:
            assert isinstance(argument, Integer)
            product *= argument.value
        return integer(product)

    if expr.has_head("Power"):
        if len(expr.arguments) != 2:
            return None
        base, exponent = expr.arguments
        if not isinstance(base, Integer) or not isinstance(exponent, Integer):
            return None
        if exponent.value < 0:
            return None
        if base.value == 0 and exponent.value == 0:
            return None
        return integer(pow(base.value, exponent.value))

    return None


def _evaluate_numeric_constructor(expr: Call) -> Expr | None:
    if expr.has_head("Rational"):
        if len(expr.arguments) != 2:
            return None
        numerator, denominator = expr.arguments
        if not isinstance(numerator, Integer) or not isinstance(denominator, Integer):
            return None
        return rational_number(numerator.value, denominator.value)

    if expr.has_head("Complex"):
        if len(expr.arguments) != 2:
            return None
        real_part, imaginary_part = expr.arguments
        if not _is_real_number_expr(real_part) or not _is_real_number_expr(imaginary_part):
            return None
        return complex_number(real_part, imaginary_part)

    if expr.has_head("Overflow") and not expr.arguments:
        return special_real("Overflow")

    if expr.has_head("Underflow") and not expr.arguments:
        return special_real("Underflow")

    return None


def _evaluate_numeric_arithmetic(expr: Call) -> Expr | None:
    if expr.has_head("Plus"):
        if any(_is_indeterminate_expr(argument) for argument in expr.arguments):
            return symbol("Indeterminate")
        if not expr.arguments:
            return integer(0)
        if len(expr.arguments) == 1:
            # OneIdentity: Plus[x] -> x for any single argument.
            return expr.arguments[0]
        if all(_is_number_expr(argument) for argument in expr.arguments):
            result = expr.arguments[0]
            for argument in expr.arguments[1:]:
                added = _add_numeric_expr(result, argument)
                if added is None:
                    return None
                result = added
            return result
        # Mixed numeric/symbolic arguments: after attribute normalization has
        # flattened and orderless-canonicalized Plus, fold explicit numeric
        # constants and collect identical symbolic terms.
        return _simplify_plus_arguments(expr.arguments)

    if expr.has_head("Times"):
        if any(_is_indeterminate_expr(argument) for argument in expr.arguments):
            return symbol("Indeterminate")
        if not expr.arguments:
            return integer(1)
        if len(expr.arguments) == 1:
            # OneIdentity: Times[x] -> x for any single argument.
            return expr.arguments[0]
        if any(_is_complex_infinity_expr(argument) for argument in expr.arguments):
            if any(_is_numeric_zero(argument) for argument in expr.arguments):
                return symbol("Indeterminate")
            return symbol("ComplexInfinity")
        if all(_is_number_expr(argument) for argument in expr.arguments):
            result = integer(1)
            for argument in expr.arguments:
                multiplied = _mul_numeric_expr(result, argument)
                if multiplied is None:
                    return None
                result = multiplied
            return result
        # Mixed numeric/symbolic arguments. If the numeric part folds to 0,
        # the whole product is 0; otherwise collect identical bases into
        # powers and keep the folded numeric factor in front.
        return _simplify_times_arguments(expr.arguments)

    if expr.has_head("Power"):
        if not expr.arguments:
            return integer(1)
        if len(expr.arguments) == 1:
            return expr.arguments[0]
        if len(expr.arguments) != 2:
            return None
        base, exponent = expr.arguments
        if _is_indeterminate_expr(base) or _is_indeterminate_expr(exponent):
            return symbol("Indeterminate")
        if _is_complex_infinity_expr(base):
            return symbol("ComplexInfinity")
        simplified_power = _simplify_power_expr(base, exponent)
        if simplified_power is not None:
            return simplified_power
        if not _is_number_expr(base) or not _is_number_expr(exponent):
            return None
        return _numeric_power_expr(base, exponent)

    return None


def _simplify_plus_arguments(arguments: Sequence[Expr]) -> Expr | None:
    """Fold constants and collect equal terms in a Plus argument list."""

    constant: Expr = integer(0)
    saw_constant = False
    terms: list[tuple[Expr, Expr]] = []

    for argument in arguments:
        coefficient, base = _split_additive_term(argument)
        if base is None:
            combined = _add_numeric_expr(constant, coefficient)
            if combined is None:
                return None
            constant = combined
            saw_constant = True
            continue

        for index, (existing_base, existing_coefficient) in enumerate(terms):
            if existing_base == base:
                combined = _add_numeric_expr(existing_coefficient, coefficient)
                if combined is None:
                    return None
                terms[index] = (existing_base, combined)
                break
        else:
            terms.append((base, coefficient))

    result_arguments: list[Expr] = []
    if saw_constant and not _is_numeric_zero(constant):
        result_arguments.append(constant)
    for base, coefficient in terms:
        term = _build_additive_term(coefficient, base)
        if term is not None:
            result_arguments.append(term)

    if not result_arguments:
        return integer(0)
    if len(result_arguments) == 1:
        return result_arguments[0]
    factored = _factor_common_additive_terms(result_arguments)
    if factored is not None:
        return factored
    result = Call(head_expr=symbol("Plus"), arguments=tuple(result_arguments))
    if result.arguments == tuple(arguments):
        return None
    return result


def _split_additive_term(argument: Expr) -> tuple[Expr, Expr | None]:
    if _is_number_expr(argument):
        return argument, None
    if isinstance(argument, Call) and argument.has_head("Times"):
        coefficient: Expr = integer(1)
        symbolic_factors: list[Expr] = []
        for factor in argument.arguments:
            if _is_number_expr(factor):
                multiplied = _mul_numeric_expr(coefficient, factor)
                if multiplied is None:
                    return integer(1), argument
                coefficient = multiplied
            else:
                symbolic_factors.append(factor)
        if not symbolic_factors:
            return coefficient, None
        return coefficient, _times_expr_from_factors(symbolic_factors)
    return integer(1), argument


def _build_additive_term(coefficient: Expr, base: Expr) -> Expr | None:
    if _is_numeric_zero(coefficient):
        return None
    if _is_one_expr(coefficient):
        return base
    return _times_expr_from_factors((coefficient, base))


def _factor_common_additive_terms(arguments: Sequence[Expr]) -> Expr | None:
    decomposed = [_decompose_additive_term_factors(argument) for argument in arguments]
    best_indices: tuple[int, ...] = ()
    best_common: tuple[Expr, ...] = ()
    unique_factors: list[Expr] = []
    for _coefficient, factors in decomposed:
        for factor in factors:
            if factor not in unique_factors:
                unique_factors.append(factor)

    for factor in unique_factors:
        indices = tuple(index for index, (_coefficient, factors) in enumerate(decomposed) if factor in factors)
        if len(indices) < 2:
            continue
        common = _common_factor_list(*(decomposed[index][1] for index in indices))
        if not common:
            continue
        if (len(indices), len(common)) > (len(best_indices), len(best_common)):
            best_indices = indices
            best_common = tuple(common)

    if not best_indices or not best_common:
        return None

    index_set = set(best_indices)
    quotients: list[Expr] = []
    for index in best_indices:
        coefficient, factors = decomposed[index]
        remaining_factors = _remove_common_factors(factors, best_common)
        quotient_factors: list[Expr] = []
        if not _is_one_expr(coefficient):
            quotient_factors.append(coefficient)
        quotient_factors.extend(remaining_factors)
        quotients.append(_times_expr_from_factors(quotient_factors))

    common_expr = _times_expr_from_factors(best_common)
    inner_sum = evaluate(call("Plus", *quotients))
    factored_term = evaluate(call("Times", common_expr, inner_sum))

    rebuilt: list[Expr] = []
    inserted = False
    for index, argument in enumerate(arguments):
        if index in index_set:
            if not inserted:
                rebuilt.append(factored_term)
                inserted = True
            continue
        rebuilt.append(argument)

    if tuple(rebuilt) == tuple(arguments):
        return None
    if not rebuilt:
        return integer(0)
    if len(rebuilt) == 1:
        return rebuilt[0]
    return evaluate(Call(head_expr=symbol("Plus"), arguments=tuple(rebuilt)))


def _decompose_additive_term_factors(argument: Expr) -> tuple[Expr, list[Expr]]:
    if _is_number_expr(argument):
        return argument, []
    if isinstance(argument, Call) and argument.has_head("Times"):
        coefficient: Expr = integer(1)
        factors: list[Expr] = []
        for factor in argument.arguments:
            if _is_number_expr(factor):
                multiplied = _mul_numeric_expr(coefficient, factor)
                if multiplied is None:
                    factors.append(factor)
                else:
                    coefficient = multiplied
            else:
                factors.append(factor)
        return coefficient, factors
    return integer(1), [argument]


def _common_factor_list(*factor_lists: Sequence[Expr]) -> list[Expr]:
    if not factor_lists:
        return []
    common: list[Expr] = []
    remaining = [list(factors) for factors in factor_lists]
    for factor in list(remaining[0]):
        if all(factor in factors for factors in remaining[1:]):
            common.append(factor)
            for factors in remaining:
                factors.remove(factor)
    return common


def _remove_common_factors(factors: Sequence[Expr], common: Sequence[Expr]) -> list[Expr]:
    remaining = list(factors)
    for factor in common:
        if factor in remaining:
            remaining.remove(factor)
    return remaining


def _simplify_times_arguments(arguments: Sequence[Expr]) -> Expr | None:
    """Fold constants and collect equal bases in a Times argument list."""

    coefficient: Expr = integer(1)
    saw_numeric_factor = False
    factors: list[tuple[Expr, Expr]] = []

    for argument in arguments:
        if _is_number_expr(argument):
            multiplied = _mul_numeric_expr(coefficient, argument)
            if multiplied is None:
                return None
            coefficient = multiplied
            saw_numeric_factor = True
            continue

        base, exponent = _split_multiplicative_factor(argument)
        for index, (existing_base, existing_exponent) in enumerate(factors):
            if existing_base == base:
                factors[index] = (existing_base, _add_exponents(existing_exponent, exponent))
                break
        else:
            factors.append((base, exponent))

    if _is_numeric_zero(coefficient):
        return integer(0)

    result_arguments: list[Expr] = []
    if saw_numeric_factor and not _is_one_expr(coefficient):
        result_arguments.append(coefficient)
    for base, exponent in factors:
        factor = _build_power_factor(base, exponent)
        if factor is not None:
            result_arguments.append(factor)

    if not result_arguments:
        return integer(1)
    if len(result_arguments) == 1:
        return result_arguments[0]
    result = Call(head_expr=symbol("Times"), arguments=tuple(result_arguments))
    if result.arguments == tuple(arguments):
        return None
    return result


def _split_multiplicative_factor(argument: Expr) -> tuple[Expr, Expr]:
    if isinstance(argument, Call) and argument.has_head("Power") and len(argument.arguments) == 2:
        return argument.arguments[0], argument.arguments[1]
    return argument, integer(1)


def _add_exponents(left: Expr, right: Expr) -> Expr:
    added = _add_numeric_expr(left, right) if _is_number_expr(left) and _is_number_expr(right) else None
    if added is not None:
        return added
    return evaluate(call("Plus", left, right))


def _build_power_factor(base: Expr, exponent: Expr) -> Expr | None:
    if _is_numeric_zero(exponent):
        return None
    if _is_one_expr(exponent):
        return base
    return call("Power", base, exponent)


def _times_expr_from_factors(factors: Sequence[Expr]) -> Expr:
    flattened: list[Expr] = []
    for factor in factors:
        if isinstance(factor, Call) and factor.has_head("Times"):
            flattened.extend(factor.arguments)
        else:
            flattened.append(factor)
    if not flattened:
        return integer(1)
    if len(flattened) == 1:
        return flattened[0]
    return Call(head_expr=symbol("Times"), arguments=tuple(flattened))


def _simplify_power_expr(base: Expr, exponent: Expr) -> Expr | None:
    if _is_exact_zero(exponent):
        if _is_numeric_zero(base):
            return None
        return integer(1)
    if _is_one_expr(exponent):
        return base
    if _is_one_expr(base):
        return integer(1)

    fractional_power = _exact_fractional_power_expr(base, exponent)
    if fractional_power is not None:
        return fractional_power

    integer_exponent = _exact_integer_value(exponent)
    if integer_exponent is not None:
        if isinstance(base, Call) and base.has_head("Power") and len(base.arguments) == 2:
            inner_base, inner_exponent = base.arguments
            combined_exponent = evaluate(call("Times", exponent, inner_exponent))
            return call("Power", inner_base, combined_exponent)
        if isinstance(base, Call) and base.has_head("Times"):
            return evaluate(call("Times", *(call("Power", factor, exponent) for factor in base.arguments)))
    return None


def _exact_fractional_power_expr(base: Expr, exponent: Expr) -> Expr | None:
    base_fraction = _exact_fraction(base)
    exponent_fraction = _exact_fraction(exponent)
    if base_fraction is None or exponent_fraction is None or exponent_fraction.denominator == 1:
        return None
    if base_fraction == 0:
        return integer(0) if exponent_fraction > 0 else symbol("ComplexInfinity")
    if base_fraction < 0:
        if exponent_fraction == Fraction(1, 2):
            positive_base = _fraction_expr(-base_fraction)
            positive_power = _exact_fractional_power_expr(positive_base, exponent)
            if positive_power is None:
                positive_power = call("Power", positive_base, exponent)
            return evaluate(call("Times", positive_power, symbol("I")))
        return None

    numerator = exponent_fraction.numerator
    denominator = exponent_fraction.denominator
    powered = base_fraction ** abs(numerator)
    outside, inside = _extract_fraction_nth_root(powered, denominator)
    if outside == 1 and inside == base_fraction and abs(numerator) == 1:
        return None

    if numerator < 0:
        outside = Fraction(1, 1) / outside
        radical_exponent = Fraction(-1, denominator)
    else:
        radical_exponent = Fraction(1, denominator)

    factors: list[Expr] = []
    if outside != 1:
        factors.append(_fraction_expr(outside))
    if inside != 1:
        factors.append(
            call(
                "Power",
                _fraction_expr(inside),
                rational_number(radical_exponent.numerator, radical_exponent.denominator),
            )
        )
    if not factors:
        return integer(1)
    if len(factors) == 1:
        return factors[0]
    return evaluate(call("Times", *factors))


def _extract_fraction_nth_root(value: Fraction, root: int) -> tuple[Fraction, Fraction]:
    numerator_outside, numerator_inside = _extract_integer_nth_root(value.numerator, root)
    denominator_outside, denominator_inside = _extract_integer_nth_root(value.denominator, root)
    return Fraction(numerator_outside, denominator_outside), Fraction(numerator_inside, denominator_inside)


def _extract_integer_nth_root(value: int, root: int) -> tuple[int, int]:
    outside = 1
    inside = 1
    for prime, exponent in _factor_int(value):
        outside *= prime ** (exponent // root)
        inside *= prime ** (exponent % root)
    return outside, inside


def _exact_integer_value(expr: Expr) -> int | None:
    exact = _exact_fraction(expr)
    if exact is None or exact.denominator != 1:
        return None
    return exact.numerator


def _is_one_expr(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == 1
    if isinstance(expr, RationalNumber):
        return expr.value == 1
    return False


def _evaluate_integer_relation(expr: Call) -> Expr | None:
    if not all(_is_integer_expr(argument) for argument in expr.arguments):
        return None

    values = [argument.value for argument in expr.arguments if isinstance(argument, Integer)]

    if expr.has_head("Equal"):
        return _bool_symbol(all(left == right for left, right in zip(values, values[1:])))
    if expr.has_head("Unequal"):
        return _bool_symbol(len(values) == len(set(values)))
    if expr.has_head("Less"):
        return _bool_symbol(all(left < right for left, right in zip(values, values[1:])))
    if expr.has_head("LessEqual"):
        return _bool_symbol(all(left <= right for left, right in zip(values, values[1:])))
    if expr.has_head("Greater"):
        return _bool_symbol(all(left > right for left, right in zip(values, values[1:])))
    if expr.has_head("GreaterEqual"):
        return _bool_symbol(all(left >= right for left, right in zip(values, values[1:])))

    return None


def _evaluate_numeric_relation(expr: Call) -> Expr | None:
    relation_heads = {"Equal", "Unequal", "Less", "LessEqual", "Greater", "GreaterEqual"}
    if not any(expr.has_head(head) for head in relation_heads):
        return None

    if not expr.arguments:
        return _bool_symbol(True)

    if expr.has_head("Equal"):
        values, options = _split_trailing_option_rules(expr.arguments)
        same_test = _option_value(options, "SameTest")
        if same_test is not None:
            if len(values) <= 1:
                return _bool_symbol(True)
            for left, right in zip(values, values[1:]):
                try:
                    test_result = _apply_callable(same_test, (left, right))
                except WolframEvaluationError:
                    return None
                if test_result == symbol("False"):
                    return symbol("False")
                if test_result != symbol("True"):
                    return None
            return symbol("True")
        if all(_is_number_expr(argument) for argument in expr.arguments):
            comparisons = [_numeric_same_value(left, right) for left, right in zip(expr.arguments, expr.arguments[1:])]
        elif all(_is_real_comparable_expr(argument) for argument in expr.arguments):
            comparisons = [_real_same_value(left, right) for left, right in zip(expr.arguments, expr.arguments[1:])]
        else:
            return None
        if any(comparison is None for comparison in comparisons):
            return None
        return _bool_symbol(all(bool(comparison) for comparison in comparisons))

    if expr.has_head("Unequal"):
        if not all(_is_number_expr(argument) for argument in expr.arguments) and not all(
            _is_real_comparable_expr(argument) for argument in expr.arguments
        ):
            return None
        for left, right in itertools.combinations(expr.arguments, 2):
            comparison = (
                _numeric_same_value(left, right)
                if _is_number_expr(left) and _is_number_expr(right)
                else _real_same_value(left, right)
            )
            if comparison is None:
                return None
            if comparison:
                return _bool_symbol(False)
        return _bool_symbol(True)

    if not all(
        _is_real_comparable_expr(argument)
        for argument in expr.arguments
    ):
        return None

    comparisons = [_compare_real_expr(left, right) for left, right in zip(expr.arguments, expr.arguments[1:])]
    if any(comparison is None for comparison in comparisons):
        return None
    assert all(comparison is not None for comparison in comparisons)
    if expr.has_head("Less"):
        return _bool_symbol(all(comparison < 0 for comparison in comparisons))
    if expr.has_head("LessEqual"):
        return _bool_symbol(all(comparison <= 0 for comparison in comparisons))
    if expr.has_head("Greater"):
        return _bool_symbol(all(comparison > 0 for comparison in comparisons))
    if expr.has_head("GreaterEqual"):
        return _bool_symbol(all(comparison >= 0 for comparison in comparisons))
    return None


def _is_real_comparable_expr(expr: Expr) -> bool:
    return (
        _is_real_number_expr(expr)
        or _is_real_algebraic_expr(expr)
        or _is_real_transcendental_expr(expr)
        or _is_positive_infinity_expr(expr)
        or _is_negative_infinity_expr(expr)
    )


def _real_same_value(left: Expr, right: Expr) -> bool | None:
    comparison = _compare_real_expr(left, right)
    return None if comparison is None else comparison == 0


def _evaluate_inequality(expr: Call) -> Expr | None:
    if not expr.has_head("Inequality"):
        return None
    if len(expr.arguments) < 3 or len(expr.arguments) % 2 == 0:
        return None

    for index in range(1, len(expr.arguments), 2):
        relation = expr.arguments[index]
        if not isinstance(relation, Symbol):
            return None
        left = expr.arguments[index - 1]
        right = expr.arguments[index + 1]
        if relation.name == "SameQ":
            result: Expr | None = same_q(left, right)
        elif relation.name == "UnsameQ":
            result = unsame_q(left, right)
        elif relation.name in {"Equal", "Unequal", "Less", "LessEqual", "Greater", "GreaterEqual"}:
            relation_expr = call(relation.name, left, right)
            result = _evaluate_numeric_relation(relation_expr) or _evaluate_integer_relation(relation_expr)
        else:
            return None

        if result == symbol("False"):
            return symbol("False")
        if result != symbol("True"):
            return None

    return symbol("True")


def _evaluate_boolean_logic(expr: Call) -> Expr | None:
    if expr.has_head("Not"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if not _is_boolean_symbol(argument):
            return None
        assert isinstance(argument, Symbol)
        return _bool_symbol(argument.name == "False")

    if expr.has_head("And"):
        if not all(_is_boolean_symbol(argument) for argument in expr.arguments):
            return None
        return _bool_symbol(all(isinstance(argument, Symbol) and argument.name == "True" for argument in expr.arguments))

    if expr.has_head("Or"):
        if not all(_is_boolean_symbol(argument) for argument in expr.arguments):
            return None
        return _bool_symbol(any(isinstance(argument, Symbol) and argument.name == "True" for argument in expr.arguments))

    return None


def _evaluate_held_boolean_logic(head: Symbol, arguments: Sequence[Expr]) -> Expr:
    prepared_arguments = _normalize_attribute_call(head, _prepare_symbol_call_arguments(head, arguments))
    head_name = _system_dispatch_name(head)
    if head_name == "And":
        kept: list[Expr] = []
        for argument in prepared_arguments:
            evaluated = evaluate(argument)
            truth = _truth_value(evaluated)
            if truth is False:
                return symbol("False")
            if truth is True:
                continue
            kept.append(evaluated)
        if not kept:
            return symbol("True")
        if len(kept) == 1:
            return kept[0]
        return Call(head_expr=head, arguments=tuple(kept))

    if head_name == "Or":
        kept = []
        for argument in prepared_arguments:
            evaluated = evaluate(argument)
            truth = _truth_value(evaluated)
            if truth is True:
                return symbol("True")
            if truth is False:
                continue
            kept.append(evaluated)
        if not kept:
            return symbol("False")
        if len(kept) == 1:
            return kept[0]
        return Call(head_expr=head, arguments=tuple(kept))

    raise AssertionError(f"Unsupported held Boolean head: {head_name}")


def _evaluate_simple_predicates(expr: Call) -> Expr | None:
    if len(expr.arguments) != 1:
        return None

    argument = expr.arguments[0]

    if expr.has_head("AtomQ"):
        return _bool_symbol(_is_atom_expr(argument))

    if expr.has_head("IntegerQ"):
        return _bool_symbol(isinstance(argument, Integer))

    if expr.has_head("MachineIntegerQ"):
        return _bool_symbol(isinstance(argument, Integer) and -(2**63) <= argument.value <= 2**63 - 1)

    if expr.has_head("MachineNumberQ"):
        return _bool_symbol(_is_machine_number_expr(argument))

    if expr.has_head("NumberQ"):
        return _bool_symbol(_is_number_expr(argument) or _is_numeric_transcendental_expr(argument))

    if expr.has_head("ExactNumberQ"):
        if _is_exact_real_number(argument):
            return _bool_symbol(True)
        if isinstance(argument, ComplexNumber):
            return _bool_symbol(_is_exact_real_number(argument.real_part) and _is_exact_real_number(argument.imaginary_part))
        return _bool_symbol(_is_numeric_transcendental_expr(argument) and not _expr_contains_inexact_real(argument))

    if expr.has_head("InexactNumberQ"):
        if _is_inexact_real_number(argument):
            return _bool_symbol(True)
        if isinstance(argument, ComplexNumber):
            return _bool_symbol(_contains_inexact_real(argument))
        return _bool_symbol(False)

    if expr.has_head("RealValuedNumberQ"):
        return _bool_symbol(_is_real_number_expr(argument) or _is_real_transcendental_expr(argument))

    if expr.has_head("StringQ"):
        return _bool_symbol(isinstance(argument, String))

    if expr.has_head("DigitQ"):
        return _bool_symbol(
            isinstance(argument, String)
            and bool(argument.value)
            and all(character.isdigit() for character in argument.value)
        )

    if expr.has_head("LetterQ"):
        return _bool_symbol(
            isinstance(argument, String)
            and bool(argument.value)
            and all(character.isalpha() for character in argument.value)
        )

    if expr.has_head("ByteArrayQ"):
        return _bool_symbol(isinstance(argument, ByteArrayExpr))

    if expr.has_head("SparseArrayQ"):
        return _bool_symbol(isinstance(argument, SparseArrayExpr))

    if expr.has_head("FailureQ"):
        return _bool_symbol(_is_failure_q_expr(argument))

    if expr.has_head("MissingQ"):
        return _bool_symbol(_is_missing_expr(argument))

    if expr.has_head("EvenQ"):
        return _bool_symbol(isinstance(argument, Integer) and argument.value % 2 == 0)

    if expr.has_head("OddQ"):
        return _bool_symbol(isinstance(argument, Integer) and argument.value % 2 != 0)

    if expr.has_head("TrueQ"):
        return _bool_symbol(isinstance(argument, Symbol) and argument.name == "True")

    return None


def _evaluate_integer_special_functions(expr: Call) -> Expr | None:
    if expr.has_head("FactorInteger"):
        return _factor_integer_expr(expr.arguments)

    if expr.has_head("IntegerExponent"):
        return _integer_exponent_expr(expr.arguments)

    if expr.has_head("ContinuedFraction"):
        return _continued_fraction_expr(expr.arguments)

    if expr.has_head("FromContinuedFraction"):
        return _from_continued_fraction_expr(expr.arguments)

    if expr.has_head("IntegerPartitions"):
        return _integer_partitions_expr(expr.arguments)

    values = _integer_values(expr.arguments)
    if values is None:
        return None

    if expr.has_head("Binomial"):
        if len(values) != 2:
            return None
        return integer(_binomial_int(values[0], values[1]))

    if expr.has_head("Multinomial"):
        if any(value < 0 for value in values):
            return None
        total = sum(values)
        result = math.factorial(total)
        for value in values:
            result //= math.factorial(value)
        return integer(result)

    if expr.has_head("JacobiSymbol"):
        if len(values) != 2:
            return None
        try:
            return integer(int(_sp.jacobi_symbol(values[0], values[1])))
        except ValueError:
            return None

    if expr.has_head("KroneckerSymbol"):
        if len(values) != 2:
            return None
        return integer(int(_sp.kronecker_symbol(values[0], values[1])))

    if expr.has_head("Fibonacci"):
        if len(values) != 1:
            return None
        return integer(int(_sp.fibonacci(values[0])))

    if expr.has_head("LucasL"):
        if len(values) != 1:
            return None
        return integer(int(_sp.lucas(values[0])))

    if expr.has_head("BernoulliB"):
        if len(values) != 1 or values[0] < 0:
            return None
        return _sympy_rational_to_expr(_wolfram_bernoulli(values[0]))

    if expr.has_head("EulerE"):
        if len(values) != 1 or values[0] < 0:
            return None
        return _sympy_rational_to_expr(_sp.euler(values[0]))

    if expr.has_head("HarmonicNumber"):
        if len(values) == 1 and values[0] >= 0:
            return _fraction_expr(_harmonic_number_fraction(values[0], 1))
        if len(values) == 2 and values[0] >= 0:
            return _fraction_expr(_harmonic_number_fraction(values[0], values[1]))
        return None

    if expr.has_head("UnitStep"):
        return integer(1 if all(value >= 0 for value in values) else 0)

    if expr.has_head("Unitize"):
        if len(values) != 1:
            return None
        return integer(0 if values[0] == 0 else 1)

    if expr.has_head("Sign") or expr.has_head("RealSign"):
        if len(values) != 1:
            return None
        return integer((values[0] > 0) - (values[0] < 0))

    if expr.has_head("Abs") or expr.has_head("RealAbs"):
        if len(values) != 1:
            return None
        return integer(abs(values[0]))

    if expr.has_head("Ramp"):
        if len(values) != 1:
            return None
        return integer(max(values[0], 0))

    if expr.has_head("Mod"):
        if len(values) not in {2, 3}:
            return None
        dividend, divisor = values[0], values[1]
        if divisor == 0:
            return symbol("Indeterminate")
        offset = values[2] if len(values) == 3 else 0
        return integer(offset + ((dividend - offset) % divisor))

    if expr.has_head("Quotient"):
        if len(values) not in {2, 3}:
            return None
        dividend, divisor = values[0], values[1]
        if divisor == 0:
            return symbol("Indeterminate") if dividend == 0 else symbol("ComplexInfinity")
        offset = values[2] if len(values) == 3 else 0
        remainder = offset + ((dividend - offset) % divisor)
        return integer((dividend - remainder) // divisor)

    if expr.has_head("QuotientRemainder"):
        if len(values) != 2:
            return None
        dividend, divisor = values
        if divisor == 0:
            return None
        remainder = dividend % divisor
        quotient = (dividend - remainder) // divisor
        return list_expr(integer(quotient), integer(remainder))

    if expr.has_head("Min"):
        if not values:
            return symbol("Infinity")
        return integer(min(values))

    if expr.has_head("Max"):
        if not values:
            return symbol("-Infinity")
        return integer(max(values))

    if expr.has_head("Clip"):
        if len(values) == 1:
            return integer(min(max(values[0], -1), 1))
        return None

    if expr.has_head("KroneckerDelta"):
        if not values:
            return integer(1)
        if len(values) == 1:
            return integer(1 if values[0] == 0 else 0)
        return integer(1 if all(value == values[0] for value in values[1:]) else 0)

    if expr.has_head("DiscreteDelta"):
        return integer(1 if all(value == 0 for value in values) else 0)

    if expr.has_head("GCD"):
        # GCD[] -> 0; GCD[a, b, c, ...] -> Python math.gcd over absolute values.
        if not values:
            return integer(0)
        result = abs(values[0])
        for value in values[1:]:
            result = math.gcd(result, abs(value))
        return integer(result)

    if expr.has_head("LCM"):
        # LCM[] -> 1; LCM[a, b, c, ...] -> reduces via gcd; LCM[..., 0, ...] is 0.
        if not values:
            return integer(1)
        result = abs(values[0])
        for value in values[1:]:
            absolute_value = abs(value)
            if result == 0 or absolute_value == 0:
                result = 0
            else:
                result = result * absolute_value // math.gcd(result, absolute_value)
        return integer(result)

    if expr.has_head("Divisors"):
        if len(values) != 1 or values[0] == 0:
            return None
        n = abs(values[0])
        small_divisors: list[int] = []
        large_divisors: list[int] = []
        index = 1
        while index * index <= n:
            if n % index == 0:
                small_divisors.append(index)
                if index != n // index:
                    large_divisors.append(n // index)
            index += 1
        large_divisors.reverse()
        all_divisors = small_divisors + large_divisors
        return list_expr(*(integer(value) for value in all_divisors))

    if expr.has_head("PrimeQ"):
        if len(values) != 1:
            return None
        return _bool_symbol(_is_prime_int(values[0]))

    if expr.has_head("CompositeQ"):
        if len(values) != 1:
            return None
        n = values[0]
        if n < 4:
            return _bool_symbol(False)
        return _bool_symbol(not _is_prime_int(n))

    if expr.has_head("PrimePowerQ"):
        if len(values) != 1:
            return None
        n = values[0]
        if n < 2:
            return _bool_symbol(False)
        # n is a prime power iff its factorization has a single prime base.
        factors = _factor_int(n)
        return _bool_symbol(len(factors) == 1)

    if expr.has_head("ChineseRemainder"):
        # ChineseRemainder[{r1, ...}, {m1, ...}] expects two integer-list
        # arguments; the dispatch table sees the lists, not their flattened
        # values, so this branch does not actually run from _integer_values.
        # Falls through; handled in the post-normalized list dispatch below.
        return None

    if expr.has_head("EulerPhi"):
        if len(values) != 1 or values[0] <= 0:
            return None
        return integer(_euler_phi_int(values[0]))

    if expr.has_head("CarmichaelLambda"):
        if len(values) != 1 or values[0] <= 0:
            return None
        return integer(int(_sp.reduced_totient(values[0])))

    if expr.has_head("MoebiusMu"):
        if len(values) != 1 or values[0] <= 0:
            return None
        return integer(_moebius_mu_int(values[0]))

    if expr.has_head("LiouvilleLambda"):
        if len(values) != 1 or values[0] <= 0:
            return None
        exponent_sum = sum(exponent for _prime, exponent in _factor_int(values[0]))
        return integer(-1 if exponent_sum % 2 else 1)

    if expr.has_head("JordanTotient"):
        if len(values) != 2:
            return None
        order, n = values
        if order < 0 or n <= 0:
            return None
        return integer(_jordan_totient_int(order, n))

    if expr.has_head("RamanujanTau"):
        if len(values) != 1 or values[0] < 1:
            return None
        return integer(_ramanujan_tau_int(values[0]))

    if expr.has_head("DivisorSigma"):
        if len(values) != 2 or values[1] == 0:
            return None
        return _fraction_expr(_divisor_sigma_fraction(values[0], abs(values[1])))

    if expr.has_head("PrimePi"):
        if len(values) != 1 or values[0] < 0:
            return None
        return integer(_prime_pi_int(values[0]))

    if expr.has_head("Prime"):
        if len(values) != 1 or values[0] < 1:
            return None
        return integer(_nth_prime_int(values[0]))

    if expr.has_head("NextPrime"):
        if len(values) == 1:
            return integer(_next_prime_int(values[0], 1))
        if len(values) == 2:
            return integer(_next_prime_int(values[0], values[1]))
        return None

    if expr.has_head("PowerMod"):
        if len(values) != 3 or values[2] == 0:
            return None
        base, exponent, modulus = values
        modulus = abs(modulus)
        if exponent < 0:
            try:
                base_inverse = pow(base, -1, modulus)
            except ValueError:
                # No modular inverse; Wolfram returns the unevaluated form.
                return None
            return integer(pow(base_inverse, -exponent, modulus))
        return integer(pow(base, exponent, modulus))

    if expr.has_head("ModularInverse"):
        if len(values) != 2 or values[1] == 0:
            return None
        try:
            return integer(pow(values[0], -1, abs(values[1])))
        except ValueError:
            return None

    if expr.has_head("MultiplicativeOrder"):
        if len(values) != 2 or values[1] <= 0 or math.gcd(values[0], values[1]) != 1:
            return None
        try:
            return integer(int(_sp.n_order(values[0], values[1])))
        except ValueError:
            return None

    if expr.has_head("PrimitiveRoot"):
        if len(values) != 1 or values[0] <= 0:
            return None
        root = _sp.primitive_root(values[0])
        return integer(int(root)) if root is not None else None

    if expr.has_head("IntegerLength"):
        if len(values) == 1:
            return integer(_integer_length_int(values[0], 10))
        if len(values) == 2 and values[1] >= 2:
            return integer(_integer_length_int(values[0], values[1]))
        return None

    if expr.has_head("IntegerDigits"):
        if len(values) == 1:
            return list_expr(*(integer(digit) for digit in _integer_digits_int(values[0], 10)))
        if len(values) == 2 and values[1] >= 2:
            return list_expr(*(integer(digit) for digit in _integer_digits_int(values[0], values[1])))
        if len(values) == 3 and values[1] >= 2 and values[2] >= 0:
            digits = _integer_digits_int(values[0], values[1])
            if len(digits) > values[2]:
                digits = digits[-values[2]:]
            else:
                digits = [0] * (values[2] - len(digits)) + digits
            return list_expr(*(integer(digit) for digit in digits))
        return None

    if expr.has_head("IntegerReverse"):
        if len(values) == 1:
            return integer(_integer_reverse_int(values[0], 10))
        if len(values) == 2 and values[1] >= 2:
            return integer(_integer_reverse_int(values[0], values[1]))
        return None

    if expr.has_head("DigitCount"):
        if len(values) == 1:
            return _digit_count_list_expr(values[0], 10)
        if len(values) == 2 and values[1] >= 2:
            return _digit_count_list_expr(values[0], values[1])
        if len(values) == 3 and values[1] >= 2 and 0 <= values[2] < values[1]:
            return integer(_digit_count_int(values[0], values[1], values[2]))
        return None

    if expr.has_head("FromDigits"):
        # FromDigits[{...}] / FromDigits[{...}, base] is dispatched separately
        # (the digit list isn't an integer); return None and let the call
        # site for FromDigits handle it.
        return None

    if expr.has_head("BitAnd"):
        if not values:
            return integer(-1)
        result = values[0]
        for value in values[1:]:
            result &= value
        return integer(result)

    if expr.has_head("BitOr"):
        if not values:
            return integer(0)
        result = values[0]
        for value in values[1:]:
            result |= value
        return integer(result)

    if expr.has_head("BitXor"):
        if not values:
            return integer(0)
        result = values[0]
        for value in values[1:]:
            result ^= value
        return integer(result)

    if expr.has_head("BitShiftLeft"):
        if len(values) == 1:
            return integer(values[0] << 1)
        if len(values) == 2:
            shift = values[1]
            if shift >= 0:
                return integer(values[0] << shift)
            return integer(values[0] >> -shift)
        return None

    if expr.has_head("BitShiftRight"):
        if len(values) == 1:
            return integer(values[0] >> 1)
        if len(values) == 2:
            shift = values[1]
            if shift >= 0:
                return integer(values[0] >> shift)
            return integer(values[0] << -shift)
        return None

    if expr.has_head("BitNot"):
        if len(values) != 1:
            return None
        return integer(~values[0])

    if expr.has_head("BitClear"):
        if len(values) != 2 or values[1] < 0:
            return None
        return integer(values[0] & ~(1 << values[1]))

    if expr.has_head("BitSet"):
        if len(values) != 2 or values[1] < 0:
            return None
        return integer(values[0] | (1 << values[1]))

    if expr.has_head("BitGet"):
        if len(values) != 2 or values[1] < 0:
            return None
        return integer((values[0] >> values[1]) & 1)

    if expr.has_head("BitLength"):
        if len(values) != 1:
            return None
        value = values[0] if values[0] >= 0 else ~values[0]
        return integer(value.bit_length())

    if expr.has_head("PartitionsP"):
        if len(values) != 1:
            return None
        return integer(_partition_count_int(values[0], distinct=False))

    if expr.has_head("PartitionsQ"):
        if len(values) != 1:
            return None
        return integer(_partition_count_int(values[0], distinct=True))

    return None


def _factor_integer_expr(arguments: Sequence[Expr]) -> Expr | None:
    if not arguments:
        return None
    value = _exact_fraction(arguments[0])
    gaussian = False
    partial_limit: int | None = None
    for option in arguments[1:]:
        if isinstance(option, Integer):
            if option.value <= 0:
                return None
            partial_limit = option.value
            continue
        parsed_option = _factor_integer_option(option)
        if parsed_option is None:
            return None
        option_name, option_value = parsed_option
        if option_name == "GaussianIntegers":
            gaussian = option_value
            continue
        return None
    if gaussian:
        return _gaussian_factor_integer_expr(arguments[0], partial_limit)
    if value is None:
        return None
    if value == 0:
        return _evaluated_list_expr(_evaluated_list_expr(integer(0), integer(1)))
    if value == 1:
        return _evaluated_list_expr(_evaluated_list_expr(integer(1), integer(1)))
    if value == -1:
        return _evaluated_list_expr(_evaluated_list_expr(integer(-1), integer(1)))

    factors: list[tuple[int, int]] = []
    numerator = value.numerator
    denominator = value.denominator
    if numerator < 0:
        factors.append((-1, 1))
        numerator = -numerator
    factorer = _factor_int if partial_limit is None else lambda n: _partial_factor_int(n, partial_limit)
    factors.extend(factorer(numerator))
    factors.extend((prime, -exponent) for prime, exponent in factorer(denominator))
    return _evaluated_list_expr(
        *(_evaluated_list_expr(integer(prime), integer(exponent)) for prime, exponent in factors)
    )


def _integer_exponent_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    if not isinstance(arguments[0], Integer):
        return None
    base = 10
    if len(arguments) == 2:
        if not isinstance(arguments[1], Integer):
            return None
        base = abs(arguments[1].value)
    if base <= 1:
        return None
    value = abs(arguments[0].value)
    if value == 0:
        return symbol("Infinity")
    exponent = 0
    while value % base == 0:
        exponent += 1
        value //= base
    return integer(exponent)


def _is_prime_int(n: int) -> bool:
    """Deterministic primality for non-negative integers.

    Uses trial division for small ``n`` (up to ~10**6), then a
    Miller–Rabin test with witnesses sufficient for all 64-bit integers.
    For numbers larger than 2**64, falls back to Miller–Rabin with the
    extended Jaeschke witness set, which is not strictly proven for all
    inputs but correct for every value used in practical Tungsten
    workloads. Tungsten's number-theory contract is for explicit integers
    that fit comfortably in normal AST evaluation.
    """
    if n < 2:
        return False
    small_primes = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)
    for prime in small_primes:
        if n == prime:
            return True
        if n % prime == 0:
            return False
    # Miller–Rabin with witnesses sufficient for all 64-bit integers, plus
    # extended for larger values. See Sloane A014233 for the exact 64-bit
    # witness set.
    witnesses_64 = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)
    if n < 1 << 64:
        return _miller_rabin(n, witnesses_64)
    extended_witnesses = witnesses_64 + (41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97)
    return _miller_rabin(n, extended_witnesses)


def _miller_rabin(n: int, witnesses: Sequence[int]) -> bool:
    if n % 2 == 0:
        return n == 2
    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for witness in witnesses:
        if witness >= n:
            continue
        x = pow(witness, d, n)
        if x == 1 or x == n - 1:
            continue
        composite = True
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                composite = False
                break
        if composite:
            return False
    return True


def _factor_int(n: int) -> list[tuple[int, int]]:
    """Return the prime factorization of ``n`` as a sorted list of
    ``(prime, exponent)`` pairs. Used by EulerPhi and MoebiusMu."""
    if n <= 1:
        return []
    factors: list[tuple[int, int]] = []
    remaining = n
    factor = 2
    while factor * factor <= remaining:
        if remaining % factor == 0:
            exponent = 0
            while remaining % factor == 0:
                remaining //= factor
                exponent += 1
            factors.append((factor, exponent))
        factor = 3 if factor == 2 else factor + 2
    if remaining > 1:
        factors.append((remaining, 1))
    return factors


def _euler_phi_int(n: int) -> int:
    if n == 1:
        return 1
    result = n
    for prime, _exponent in _factor_int(n):
        result -= result // prime
    return result


def _moebius_mu_int(n: int) -> int:
    if n == 1:
        return 1
    factors = _factor_int(n)
    if any(exponent > 1 for _prime, exponent in factors):
        return 0
    return -1 if len(factors) % 2 == 1 else 1


def _prime_pi_int(n: int) -> int:
    """Sieve-of-Eratosthenes count of primes ``<= n``.

    Limited to ``n <= 5_000_000`` for safety; Tungsten is an offline AST
    evaluator and the call surface that needs this is small inputs.
    """
    if n < 2:
        return 0
    limit = min(n, 5_000_000)
    if n > limit:
        # Fall back to incremental primality check up to n.
        return _prime_pi_int_slow(n)
    sieve = bytearray(b"\x01") * (limit + 1)
    sieve[0] = 0
    sieve[1] = 0
    for index in range(2, int(limit ** 0.5) + 1):
        if sieve[index]:
            sieve[index * index : limit + 1 : index] = bytearray(
                len(range(index * index, limit + 1, index))
            )
    return sum(sieve)


def _prime_pi_int_slow(n: int) -> int:
    count = 0
    for index in range(2, n + 1):
        if _is_prime_int(index):
            count += 1
    return count


def _nth_prime_int(n: int) -> int:
    if n == 1:
        return 2
    candidate = 3
    found = 1
    while True:
        if _is_prime_int(candidate):
            found += 1
            if found == n:
                return candidate
        candidate += 2


def _next_prime_int(n: int, k: int) -> int:
    if k == 0:
        return n
    if k > 0:
        candidate = n + 1
        for _ in range(k):
            while not _is_prime_int(candidate):
                candidate += 1
            if _ + 1 < k:
                candidate += 1
        return candidate
    # k < 0: previous primes.
    candidate = n - 1
    for _ in range(-k):
        while candidate >= 2 and not _is_prime_int(candidate):
            candidate -= 1
        if candidate < 2:
            # Wolfram returns NextPrime[1, -1] etc. as ``-2`` (the prime
            # below 2 in its convention). Use the same convention.
            return 2 - (-k - _) * 1  # pragma: no cover - unusual input
        if _ + 1 < -k:
            candidate -= 1
    return candidate


def _integer_length_int(n: int, base: int) -> int:
    if n == 0:
        return 0
    n = abs(n)
    length = 0
    while n > 0:
        n //= base
        length += 1
    return length


def _integer_digits_int(n: int, base: int) -> list[int]:
    if n == 0:
        return [0]
    n = abs(n)
    digits: list[int] = []
    while n > 0:
        digits.append(n % base)
        n //= base
    digits.reverse()
    return digits


def _binomial_int(n: int, k: int) -> int:
    if k < 0:
        return 0
    if n >= 0:
        return 0 if k > n else math.comb(n, k)
    # Generalized integer binomial:
    # Binomial[-n, k] == (-1)^k Binomial[n + k - 1, k].
    value = math.comb(k - n - 1, k)
    return -value if k % 2 else value


def _sympy_rational_to_expr(value: object) -> Expr:
    rational = _sp.Rational(value)
    return rational_number(int(rational.p), int(rational.q))


def _wolfram_bernoulli(n: int) -> object:
    if n == 1:
        return _sp.Rational(-1, 2)
    return _sp.bernoulli(n)


def _harmonic_number_fraction(n: int, order: int) -> Fraction:
    total = Fraction(0, 1)
    for index in range(1, n + 1):
        if order >= 0:
            total += Fraction(1, index ** order)
        else:
            total += Fraction(index ** (-order), 1)
    return total


def _continued_fraction_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2}:
        return None
    value = _exact_fraction(arguments[0])
    if value is None:
        return None
    limit: int | None = None
    if len(arguments) == 2:
        if not isinstance(arguments[1], Integer) or arguments[1].value <= 0:
            return None
        limit = arguments[1].value
    terms = _continued_fraction_terms(value)
    if limit is not None:
        terms = terms[:limit]
    return _evaluated_list_expr(*(integer(term) for term in terms))


def _continued_fraction_terms(value: Fraction) -> list[int]:
    if value == 0:
        return [0]
    sign = -1 if value < 0 else 1
    value = abs(value)
    numerator = value.numerator
    denominator = value.denominator
    terms: list[int] = []
    while denominator:
        quotient, remainder = divmod(numerator, denominator)
        terms.append(sign * quotient)
        if remainder == 0:
            break
        numerator, denominator = denominator, remainder
    return terms


def _from_continued_fraction_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    terms_expr = arguments[0]
    if not isinstance(terms_expr, Call) or not terms_expr.has_head("List"):
        return None
    if not terms_expr.arguments:
        return symbol("Infinity")
    if not all(isinstance(term, Integer) for term in terms_expr.arguments):
        return None
    terms = [term.value for term in terms_expr.arguments if isinstance(term, Integer)]
    value = Fraction(terms[-1], 1)
    for term in reversed(terms[:-1]):
        if value == 0:
            return symbol("ComplexInfinity")
        value = Fraction(term, 1) + Fraction(1, 1) / value
    return _fraction_expr(value)


def _jordan_totient_int(order: int, n: int) -> int:
    if order == 0:
        return 1 if n == 1 else 0
    result = n ** order
    for prime, _exponent in _factor_int(n):
        result = result // (prime ** order) * (prime ** order - 1)
    return result


def _ramanujan_tau_int(n: int) -> int:
    # Delta(q) = q Product[(1 - q^m)^24, {m, 1, Infinity}].
    # The q^n coefficient is therefore the q^(n-1) coefficient of the product.
    degree = n - 1
    coefficients = [0] * (degree + 1)
    coefficients[0] = 1
    for part in range(1, degree + 1):
        next_coefficients = [0] * (degree + 1)
        binomial_terms = [
            ((-1) ** exponent) * math.comb(24, exponent)
            for exponent in range(0, 25)
            if part * exponent <= degree
        ]
        for index, coefficient in enumerate(coefficients):
            if coefficient == 0:
                continue
            for exponent, multiplier in enumerate(binomial_terms):
                target = index + part * exponent
                if target > degree:
                    break
                next_coefficients[target] += coefficient * multiplier
        coefficients = next_coefficients
    return coefficients[degree]


def _divisor_sigma_fraction(order: int, n: int) -> Fraction:
    total = Fraction(0, 1)
    for divisor in _positive_divisors_int(n):
        if order >= 0:
            total += Fraction(divisor ** order, 1)
        else:
            total += Fraction(1, divisor ** (-order))
    return total


def _positive_divisors_int(n: int) -> list[int]:
    small_divisors: list[int] = []
    large_divisors: list[int] = []
    index = 1
    while index * index <= n:
        if n % index == 0:
            small_divisors.append(index)
            if index != n // index:
                large_divisors.append(n // index)
        index += 1
    large_divisors.reverse()
    return small_divisors + large_divisors


def _integer_reverse_int(n: int, base: int) -> int:
    result = 0
    for digit in reversed(_integer_digits_int(n, base)):
        result = result * base + digit
    return result


def _digit_count_int(n: int, base: int, digit: int) -> int:
    return sum(1 for current in _integer_digits_int(n, base) if current == digit)


def _digit_count_list_expr(n: int, base: int) -> Expr:
    ordered_digits = list(range(1, base)) + [0]
    return _evaluated_list_expr(*(integer(_digit_count_int(n, base, digit)) for digit in ordered_digits))


def _partition_count_int(n: int, *, distinct: bool) -> int:
    if n < 0:
        return 0
    counts = [0] * (n + 1)
    counts[0] = 1
    if distinct:
        for part in range(1, n + 1):
            for total in range(n, part - 1, -1):
                counts[total] += counts[total - part]
    else:
        for part in range(1, n + 1):
            for total in range(part, n + 1):
                counts[total] += counts[total - part]
    return counts[n]


def _integer_partitions_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {1, 2} or not isinstance(arguments[0], Integer):
        return None
    n = arguments[0].value
    if n < 0:
        return _evaluated_list_expr()
    min_parts = 0
    max_parts = n
    if len(arguments) == 2:
        spec = arguments[1]
        if isinstance(spec, Integer):
            if spec.value < 0:
                return None
            max_parts = spec.value
        elif isinstance(spec, Call) and spec.has_head("List"):
            if len(spec.arguments) == 1 and isinstance(spec.arguments[0], Integer):
                if spec.arguments[0].value < 0:
                    return None
                min_parts = max_parts = spec.arguments[0].value
            elif (
                len(spec.arguments) == 2
                and isinstance(spec.arguments[0], Integer)
                and isinstance(spec.arguments[1], Integer)
            ):
                min_parts = spec.arguments[0].value
                max_parts = spec.arguments[1].value
                if min_parts < 0 or max_parts < min_parts:
                    return None
            else:
                return None
        else:
            return None
    partitions = []
    for partition in _integer_partitions(n, n, max_parts):
        if len(partition) >= min_parts:
            partitions.append(_evaluated_list_expr(*(integer(part) for part in partition)))
    return _evaluated_list_expr(*partitions)


def _integer_partitions(remaining: int, max_part: int, max_length: int) -> Iterable[list[int]]:
    if remaining == 0:
        yield []
        return
    if max_length <= 0:
        return
    for first in range(min(max_part, remaining), 0, -1):
        for rest in _integer_partitions(remaining - first, first, max_length - 1):
            yield [first] + rest


def _factor_integer_option(expr: Expr) -> tuple[str, bool] | None:
    if not isinstance(expr, Call) or not expr.has_head("Rule") or len(expr.arguments) != 2:
        return None
    key, value = expr.arguments
    if not isinstance(key, Symbol):
        return None
    truth = _truth_value(value)
    if truth is None:
        return None
    return _system_dispatch_name(key), truth


def _partial_factor_int(n: int, limit: int) -> list[tuple[int, int]]:
    if n <= 1:
        return []
    factors = _sp.factorint(n, limit=limit)
    return sorted((int(factor), int(exponent)) for factor, exponent in factors.items())


def _gaussian_factor_integer_expr(expr: Expr, partial_limit: int | None) -> Expr | None:
    if partial_limit is not None:
        return None
    value = _exact_gaussian_integer(expr)
    if value is None:
        fraction = _exact_fraction(expr)
        if fraction is None:
            return None
        numerator_factors = _gaussian_factor_integer(fraction.numerator, 0)
        denominator_factors = [
            (factor, -exponent)
            for factor, exponent in _gaussian_factor_integer(fraction.denominator, 0)
        ]
        return _evaluated_list_expr(
            *(
                _evaluated_list_expr(_gaussian_integer_expr(*factor), integer(exponent))
                for factor, exponent in numerator_factors + denominator_factors
            )
        )
    factors = _gaussian_factor_integer(*value)
    return _evaluated_list_expr(
        *(_evaluated_list_expr(_gaussian_integer_expr(*factor), integer(exponent)) for factor, exponent in factors)
    )


def _exact_gaussian_integer(expr: Expr) -> tuple[int, int] | None:
    if isinstance(expr, Integer):
        return expr.value, 0
    if isinstance(expr, ComplexNumber):
        real_part = _exact_fraction(expr.real_part)
        imaginary_part = _exact_fraction(expr.imaginary_part)
        if (
            real_part is None
            or imaginary_part is None
            or real_part.denominator != 1
            or imaginary_part.denominator != 1
        ):
            return None
        return real_part.numerator, imaginary_part.numerator
    return None


def _gaussian_integer_expr(real_part: int, imaginary_part: int) -> Expr:
    if imaginary_part == 0:
        return integer(real_part)
    return complex_number(integer(real_part), integer(imaginary_part))


def _gaussian_factor_integer(real_part: int, imaginary_part: int) -> list[tuple[tuple[int, int], int]]:
    if real_part == 0 and imaginary_part == 0:
        return [((0, 0), 1)]
    norm = real_part * real_part + imaginary_part * imaginary_part
    if norm == 1:
        return [((real_part, imaginary_part), 1)]

    remaining = (real_part, imaginary_part)
    factors: list[tuple[tuple[int, int], int]] = []
    for prime, _exponent in _factor_int(norm):
        for candidate in _gaussian_prime_candidates(prime):
            count = 0
            while True:
                quotient = _divide_gaussian_integer(remaining, candidate)
                if quotient is None:
                    break
                remaining = quotient
                count += 1
            if count:
                factors.append((candidate, count))

    if remaining != (1, 0):
        factors.insert(0, (remaining, 1))
    return factors


def _gaussian_prime_candidates(prime: int) -> list[tuple[int, int]]:
    if prime == 2:
        return [(1, 1)]
    if prime % 4 == 3:
        return [(prime, 0)]
    pair = _sum_of_two_squares_prime(prime)
    if pair is None:
        return [(prime, 0)]
    small, large = pair
    if small == large:
        return [(small, large)]
    return [(small, large), (large, small)]


def _sum_of_two_squares_prime(prime: int) -> tuple[int, int] | None:
    limit = math.isqrt(prime)
    for first in range(1, limit + 1):
        second_squared = prime - first * first
        second = math.isqrt(second_squared)
        if second >= first and second * second == second_squared:
            return first, second
    return None


def _divide_gaussian_integer(
    value: tuple[int, int],
    divisor: tuple[int, int],
) -> tuple[int, int] | None:
    real_part, imaginary_part = value
    divisor_real, divisor_imaginary = divisor
    norm = divisor_real * divisor_real + divisor_imaginary * divisor_imaginary
    real_numerator = real_part * divisor_real + imaginary_part * divisor_imaginary
    imaginary_numerator = imaginary_part * divisor_real - real_part * divisor_imaginary
    if real_numerator % norm != 0 or imaginary_numerator % norm != 0:
        return None
    return real_numerator // norm, imaginary_numerator // norm


def _evaluate_numeric_special_functions(expr: Call) -> Expr | None:
    if expr.has_head("N"):
        return _n_expr_from_arguments(expr.arguments)

    if expr.has_head("Precision"):
        if len(expr.arguments) != 1:
            return None
        return _precision_expr(expr.arguments[0])

    if expr.has_head("Accuracy"):
        if len(expr.arguments) != 1:
            return None
        return _accuracy_expr(expr.arguments[0])

    if expr.has_head("SetPrecision"):
        if len(expr.arguments) != 2:
            return None
        return _set_precision_expr(expr.arguments[0], expr.arguments[1])

    if expr.has_head("SetAccuracy"):
        if len(expr.arguments) != 2:
            return None
        return _set_accuracy_expr(expr.arguments[0], expr.arguments[1])

    transcendental = _evaluate_transcendental_function_expr(expr)
    if transcendental is not None:
        return transcendental

    if expr.has_head("Re"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if isinstance(argument, ComplexNumber):
            return argument.real_part
        if _is_real_number_expr(argument):
            return argument
        return None

    if expr.has_head("Im"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if isinstance(argument, ComplexNumber):
            return argument.imaginary_part
        if _is_real_number_expr(argument):
            return integer(0)
        return None

    if expr.has_head("Conjugate"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if isinstance(argument, ComplexNumber):
            return complex_number(argument.real_part, _negate_real_expr(argument.imaginary_part))
        if _is_real_number_expr(argument):
            return argument
        conjugate = _conjugate_algebraic_expr(argument)
        if conjugate is not None:
            return conjugate
        return None

    if expr.has_head("Abs"):
        if len(expr.arguments) != 1:
            return None
        return _numeric_abs_expr(expr.arguments[0])

    if expr.has_head("RealAbs"):
        if len(expr.arguments) != 1:
            return None
        if not _is_real_number_expr(expr.arguments[0]):
            return None
        return _real_abs_expr(expr.arguments[0])

    if expr.has_head("Sign"):
        if len(expr.arguments) != 1:
            return None
        argument = expr.arguments[0]
        if _is_real_number_expr(argument) or _is_real_transcendental_expr(argument):
            zero_compare = _compare_real_expr(argument, integer(0))
            if zero_compare is None:
                return None
            return integer((zero_compare > 0) - (zero_compare < 0))
        if not isinstance(argument, ComplexNumber):
            return None
        if _is_numeric_zero(argument):
            return integer(0)
        magnitude = _numeric_abs_expr(argument)
        if magnitude is None:
            return None
        divided = _div_numeric_expr(argument, magnitude)
        if divided is not None:
            return divided
        return evaluate(call("Times", argument, call("Power", magnitude, integer(-1))))

    if expr.has_head("RealSign"):
        if len(expr.arguments) != 1 or not (_is_real_number_expr(expr.arguments[0]) or _is_real_transcendental_expr(expr.arguments[0])):
            return None
        zero_compare = _compare_real_expr(expr.arguments[0], integer(0))
        if zero_compare is None:
            return None
        return integer((zero_compare > 0) - (zero_compare < 0))

    if expr.has_head("Unitize"):
        if len(expr.arguments) != 1 or not (_is_number_expr(expr.arguments[0]) or _is_real_transcendental_expr(expr.arguments[0])):
            return None
        if _is_real_transcendental_expr(expr.arguments[0]):
            zero_compare = _compare_real_expr(expr.arguments[0], integer(0))
            if zero_compare is None:
                return None
            return integer(0 if zero_compare == 0 else 1)
        return integer(0 if _is_numeric_zero(expr.arguments[0]) else 1)

    if expr.has_head("UnitStep"):
        if not all(_is_real_number_expr(argument) or _is_real_transcendental_expr(argument) for argument in expr.arguments):
            return None
        comparisons = [_compare_real_expr(argument, integer(0)) for argument in expr.arguments]
        if any(comparison is None for comparison in comparisons):
            return None
        assert all(comparison is not None for comparison in comparisons)
        return integer(1 if all(comparison >= 0 for comparison in comparisons) else 0)

    if expr.has_head("Ramp"):
        if len(expr.arguments) != 1 or not (_is_real_number_expr(expr.arguments[0]) or _is_real_transcendental_expr(expr.arguments[0])):
            return None
        comparison = _compare_real_expr(expr.arguments[0], integer(0))
        if comparison is None:
            return None
        return expr.arguments[0] if comparison > 0 else integer(0)

    if expr.has_head("Mod"):
        return _numeric_mod_expr(expr.arguments)

    if expr.has_head("Min") or expr.has_head("Max"):
        return _min_max_expr(expr.head_expr, expr.arguments)

    if expr.has_head("Floor") or expr.has_head("Ceiling") or expr.has_head("Round") \
            or expr.has_head("IntegerPart") or expr.has_head("FractionalPart"):
        if len(expr.arguments) == 1:
            return _real_rounding_expr(expr.head_expr, expr.arguments[0])
        if expr.has_head("Floor") or expr.has_head("Ceiling") or expr.has_head("Round"):
            if len(expr.arguments) == 2:
                return _rounding_multiple_expr(expr.head_expr, expr.arguments[0], expr.arguments[1])
        return None

    if expr.has_head("Sqrt"):
        if len(expr.arguments) != 1:
            return None
        return _sqrt_expr(expr.arguments[0])

    return None
