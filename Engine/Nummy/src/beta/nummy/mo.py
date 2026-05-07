"""Worked example: the MathOverflow #79217 expression.

Computes the leading digits of ``10^(10^(10^(10^(10^(-10^10)))))`` using
the asymptotic-series propagation defined in the rest of the package.

The published answer (see ``../../docs/how-to-calculate-1010101010-1010``):

* The integer part begins with ``1``.
* Then ``10^10 - 13`` zeros.
* Then the 13-digit string ``2811012357389``.
* The fractional part begins ``.4407116278...``.

This module is the end-to-end driver that hits exactly that result.
"""

from __future__ import annotations

import dataclasses

from mpmath import mp

from .asymptotic import AsymptoticTowerValue, apply_pow10
from .leading_digits import LeadingDigits, leading_digits_of


@dataclasses.dataclass(frozen=True)
class MOResult:
    """The full MO computation outcome.

    ``leading`` carries the structured digit report; ``num_levels`` and
    ``n_inner`` echo back the arguments so callers can include them in
    their own output.
    """

    num_levels: int
    n_inner: int
    leading: LeadingDigits

    def summary(self) -> str:
        return (
            f"10^^{self.num_levels}(-{self.n_inner}) "
            f"= {self.leading.short_summary()}\n"
            f"  integer length = {self.leading.integer_digit_count}\n"
            f"  trailing 13 integer digits = {self.leading.trailing_int_digits}\n"
            f"  first fractional digits   = {self.leading.fractional_digits}"
        )


def compute_mo_expression(
    num_levels: int = 5,
    n_inner: int = 10**10,
    *,
    precision_dps: int = 80,
    max_order: int = 3,
    fractional_dps: int = 16,
) -> MOResult:
    """Run the asymptotic propagation for ``10^^num_levels(-n_inner)``.

    Returns a ``MOResult`` whose ``leading`` field contains the structured
    digit pattern.  ``precision_dps`` sets the mpmath working precision
    (80 decimal digits is comfortably sufficient for ``num_levels = 5``).

    For ``num_levels >= 6`` the deferred-tower scale would need to be
    propagated through ``apply_pow10`` again, which is not implemented in
    this proposal; raises ``NotImplementedError``.
    """
    if num_levels < 1:
        raise ValueError("num_levels must be at least 1")
    if num_levels > 5:
        raise NotImplementedError(
            "compute_mo_expression currently supports num_levels up to 5; "
            "extending would require deferred-scale apply_pow10 support, "
            "see design proposal 4 section 4."
        )

    mp.dps = precision_dps

    # v_1 = 10^(-n_inner) = x.  Series: 0 + 1*x + ...
    value = AsymptoticTowerValue.seed_from_x(n_inner=n_inner, max_order=max_order)

    # Apply pow10 (num_levels - 1) more times to reach v_num_levels.
    for _ in range(num_levels - 1):
        value = apply_pow10(value, max_order=max_order)

    leading = leading_digits_of(value, fractional_dps=fractional_dps)
    return MOResult(num_levels=num_levels, n_inner=n_inner, leading=leading)


if __name__ == "__main__":
    result = compute_mo_expression()
    print(result.summary())
