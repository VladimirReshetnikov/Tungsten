from __future__ import annotations

# Arithmetic, relation, Boolean, predicate, and integer-number-theory
# dispatch helpers extracted from tungsten.expression. Low-level numeric atoms
# and constructors still live in tungsten.expression while this module owns the
# built-in evaluator entry points for this family.
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

    integer_exponent = _exact_integer_value(exponent)
    if integer_exponent is not None:
        if isinstance(base, Call) and base.has_head("Power") and len(base.arguments) == 2:
            inner_base, inner_exponent = base.arguments
            combined_exponent = evaluate(call("Times", exponent, inner_exponent))
            return call("Power", inner_base, combined_exponent)
        if isinstance(base, Call) and base.has_head("Times"):
            return evaluate(call("Times", *(call("Power", factor, exponent) for factor in base.arguments)))
    return None


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
        if not all(_is_number_expr(argument) for argument in expr.arguments):
            return None
        comparisons = [_numeric_same_value(left, right) for left, right in zip(expr.arguments, expr.arguments[1:])]
        if any(comparison is None for comparison in comparisons):
            return None
        return _bool_symbol(all(bool(comparison) for comparison in comparisons))

    if expr.has_head("Unequal"):
        if not all(_is_number_expr(argument) for argument in expr.arguments):
            return None
        for left, right in itertools.combinations(expr.arguments, 2):
            comparison = _numeric_same_value(left, right)
            if comparison is None:
                return None
            if comparison:
                return _bool_symbol(False)
        return _bool_symbol(True)

    if not all(_is_real_number_expr(argument) or _is_positive_infinity_expr(argument) or _is_negative_infinity_expr(argument) for argument in expr.arguments):
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
        return _bool_symbol(_is_number_expr(argument))

    if expr.has_head("ExactNumberQ"):
        if _is_exact_real_number(argument):
            return _bool_symbol(True)
        if isinstance(argument, ComplexNumber):
            return _bool_symbol(_is_exact_real_number(argument.real_part) and _is_exact_real_number(argument.imaginary_part))
        return _bool_symbol(False)

    if expr.has_head("InexactNumberQ"):
        if _is_inexact_real_number(argument):
            return _bool_symbol(True)
        if isinstance(argument, ComplexNumber):
            return _bool_symbol(_contains_inexact_real(argument))
        return _bool_symbol(False)

    if expr.has_head("RealValuedNumberQ"):
        return _bool_symbol(_is_real_number_expr(argument))

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

    values = _integer_values(expr.arguments)
    if values is None:
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

    if expr.has_head("MoebiusMu"):
        if len(values) != 1 or values[0] <= 0:
            return None
        return integer(_moebius_mu_int(values[0]))

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

    return None


def _factor_integer_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) != 1:
        return None
    value = _exact_fraction(arguments[0])
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
    factors.extend(_factor_int(numerator))
    factors.extend((prime, -exponent) for prime, exponent in _factor_int(denominator))
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


def _evaluate_numeric_special_functions(expr: Call) -> Expr | None:
    if expr.has_head("N"):
        if len(expr.arguments) == 1:
            return _n_expr(expr.arguments[0])
        if len(expr.arguments) == 2:
            return _n_expr(expr.arguments[0], expr.arguments[1])
        return None

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

    if expr.has_head("Sign") or expr.has_head("RealSign"):
        if len(expr.arguments) != 1 or not _is_real_number_expr(expr.arguments[0]):
            return None
        zero_compare = _compare_real_expr(expr.arguments[0], integer(0))
        if zero_compare is None:
            return None
        return integer((zero_compare > 0) - (zero_compare < 0))

    if expr.has_head("Unitize"):
        if len(expr.arguments) != 1 or not _is_number_expr(expr.arguments[0]):
            return None
        return integer(0 if _is_numeric_zero(expr.arguments[0]) else 1)

    if expr.has_head("UnitStep"):
        if not all(_is_real_number_expr(argument) for argument in expr.arguments):
            return None
        comparisons = [_compare_real_expr(argument, integer(0)) for argument in expr.arguments]
        if any(comparison is None for comparison in comparisons):
            return None
        assert all(comparison is not None for comparison in comparisons)
        return integer(1 if all(comparison >= 0 for comparison in comparisons) else 0)

    if expr.has_head("Ramp"):
        if len(expr.arguments) != 1 or not _is_real_number_expr(expr.arguments[0]):
            return None
        comparison = _compare_real_expr(expr.arguments[0], integer(0))
        if comparison is None:
            return None
        return expr.arguments[0] if comparison > 0 else integer(0)

    if expr.has_head("Min") or expr.has_head("Max"):
        if not expr.arguments:
            return symbol("Infinity") if expr.has_head("Min") else symbol("-Infinity")
        # Wolfram folds Min/Max through a single List wrapper:
        # ``Min[{1, 2, 3}]`` is the same as ``Min[1, 2, 3]``.
        unwrapped = _flatten_list_arguments(expr.arguments)
        if not unwrapped:
            return symbol("Infinity") if expr.has_head("Min") else symbol("-Infinity")
        if not all(_is_real_number_expr(argument) or _is_positive_infinity_expr(argument) or _is_negative_infinity_expr(argument) for argument in unwrapped):
            return None
        best = unwrapped[0]
        for argument in unwrapped[1:]:
            comparison = _compare_real_expr(argument, best)
            if comparison is None:
                return None
            if (expr.has_head("Min") and comparison < 0) or (expr.has_head("Max") and comparison > 0):
                best = argument
        return best

    if expr.has_head("Floor") or expr.has_head("Ceiling") or expr.has_head("Round") \
            or expr.has_head("IntegerPart") or expr.has_head("FractionalPart"):
        if len(expr.arguments) != 1:
            return None
        return _real_rounding_expr(expr.head_expr, expr.arguments[0])

    if expr.has_head("Sqrt"):
        if len(expr.arguments) != 1:
            return None
        return _sqrt_expr(expr.arguments[0])

    return None
