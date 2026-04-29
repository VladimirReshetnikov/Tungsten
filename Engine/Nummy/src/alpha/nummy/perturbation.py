"""Perturbation propagation through fixed-height base-10 power towers."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, localcontext

from .context import NummyContext
from .sparse_decimal import SparseDecimalInteger


@dataclass(frozen=True)
class FirstOrderTowerPerturbation:
    """First-order expansion data for ``f_{k+1}(x) = base^f_k(x)``."""

    base: int
    epsilon_exponent: int
    levels: int
    anchor: SparseDecimalInteger
    base_power_shift: int
    coefficient: Decimal
    coefficient_floor: int
    fractional_part: Decimal
    omitted_tail_log10_upper_bound: int


def first_order_tower_perturbation(
    *,
    base: int,
    epsilon_exponent: int,
    levels: int,
    context: NummyContext,
    max_dense_anchor_digits: int = 10_000,
) -> FirstOrderTowerPerturbation:
    """Compute the first-order effect of ``x = base^-epsilon_exponent``.

    The function evaluates the tower recurrence ``f_0(x)=x`` and
    ``f_{k+1}(x)=base^f_k(x)`` at ``x=0`` symbolically far enough to avoid
    materializing the final anchor. It returns the first-order correction at
    ``x=base^-epsilon_exponent``.

    The current exact sparse anchor path is implemented for base 10, because
    `SparseDecimalInteger` is decimal by design.
    """

    if base != 10:
        raise NotImplementedError("the sparse exact anchor path is currently base-10")
    if epsilon_exponent < 0:
        raise ValueError("epsilon_exponent must be nonnegative")
    if levels < 1:
        raise ValueError("levels must be positive")

    anchors: list[int] = [0]
    for _ in range(1, levels):
        previous = anchors[-1]
        dense_anchor_digits = previous + 1
        if dense_anchor_digits > max_dense_anchor_digits:
            raise ValueError(
                "exact first-order anchor path exceeded current dense-integer budget"
            )
        anchors.append(base**previous)

    final_exponent = anchors[-1]
    anchor = SparseDecimalInteger.power_of_ten(final_exponent)
    base_power_shift = sum(anchors) - epsilon_exponent

    with localcontext(context.decimal_context(extra_digits=20)):
        decimal_base = Decimal(base)
        ln_base = decimal_base.ln()
        coefficient = (decimal_base**base_power_shift) * (ln_base**levels)
        coefficient = +coefficient
        coefficient_floor = int(coefficient)
        fractional_part = coefficient - Decimal(coefficient_floor)

    omitted_tail_log10_upper_bound = _second_order_tail_scale_bound(
        anchors=anchors,
        epsilon_exponent=epsilon_exponent,
        levels=levels,
    )

    return FirstOrderTowerPerturbation(
        base=base,
        epsilon_exponent=epsilon_exponent,
        levels=levels,
        anchor=anchor,
        base_power_shift=base_power_shift,
        coefficient=coefficient,
        coefficient_floor=coefficient_floor,
        fractional_part=+fractional_part,
        omitted_tail_log10_upper_bound=omitted_tail_log10_upper_bound,
    )


def _second_order_tail_scale_bound(
    *, anchors: list[int], epsilon_exponent: int, levels: int
) -> int:
    """Return a conservative base-10 exponent bound for omitted terms.

    For the MathOverflow tower the second-order coefficient has base-10 scale
    at most ``N + 22`` before multiplying by ``x^2 = 10^-2N``. A small safety
    margin covers powers of ``ln(10)`` and low-level constants.
    """

    derivative_scale = 0
    second_scale: int | None = None
    for level in range(1, levels + 1):
        log_anchor_scale = anchors[level - 1]
        doubled_derivative_scale = 2 * derivative_scale
        if second_scale is None:
            second_scale = log_anchor_scale + doubled_derivative_scale
        else:
            second_scale = log_anchor_scale + max(
                second_scale, doubled_derivative_scale
            )
        derivative_scale = log_anchor_scale + derivative_scale

    if second_scale is None:
        return -epsilon_exponent
    return second_scale - 2 * epsilon_exponent + 8
