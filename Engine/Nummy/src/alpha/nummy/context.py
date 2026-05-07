"""Context and precision policy for the Nummy Python reference implementation."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Context, Decimal, ROUND_HALF_EVEN


@dataclass(frozen=True)
class NummyContext:
    """Precision and policy settings for tower arithmetic.

    The context currently controls bounded ``Decimal`` work and the point at
    which ordinary layer-0 values are promoted into a tower coordinate. The
    promotion threshold is deliberately expressed as a decimal exponent, not as
    a maximum integer value, so it remains cheap to check.
    """

    decimal_digits: int = 80
    guard_digits: int = 20
    promotion_decimal_exponent: int = 120
    dominance_decimal_digits: int = 40
    max_algorithmic_level: int = 64

    def decimal_context(self, *, extra_digits: int = 0) -> Context:
        precision = max(1, self.decimal_digits + self.guard_digits + extra_digits)
        return Context(prec=precision, rounding=ROUND_HALF_EVEN)

    @property
    def promotion_log10_threshold(self) -> Decimal:
        return Decimal(self.promotion_decimal_exponent)


DEFAULT_CONTEXT = NummyContext()
