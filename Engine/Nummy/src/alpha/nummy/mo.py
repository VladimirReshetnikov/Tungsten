"""Direct calculation for the archived MathOverflow power-tower example."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from .context import NummyContext
from .perturbation import first_order_tower_perturbation
from .sparse_decimal import SparseDecimalInteger


@dataclass(frozen=True)
class MathOverflowCalculation:
    """Result of the direct MathOverflow integer-part calculation."""

    n: int
    expression: str
    correction: Decimal
    correction_floor: int
    correction_fractional_part: Decimal
    omitted_tail_log10_upper_bound: int
    integer_part: SparseDecimalInteger

    @property
    def digit_count(self) -> int:
        return self.integer_part.digit_count

    @property
    def zero_run_after_leading_one(self) -> int:
        return self.n - len(str(self.correction_floor))

    @property
    def suffix(self) -> str:
        return str(self.correction_floor)

    @property
    def stable_floor(self) -> bool:
        margin = min(
            self.correction_fractional_part,
            Decimal(1) - self.correction_fractional_part,
        )
        return margin > Decimal("1e-20") and self.omitted_tail_log10_upper_bound < -20

    def summary(self) -> str:
        return (
            f"floor({self.expression}) = {self.integer_part}\n"
            f"decimal shape: {self.integer_part.leading_description()}\n"
            f"digits: {self.digit_count}\n"
            f"first-order correction: {self.correction}\n"
            f"omitted tail < 10^{self.omitted_tail_log10_upper_bound}"
        )


def calculate_mathoverflow_integer_part(
    *, decimal_digits: int = 100
) -> MathOverflowCalculation:
    """Calculate the integer part of ``10^(10^(10^(10^(10^(-10^10)))))``."""

    context = NummyContext(decimal_digits=decimal_digits, guard_digits=30)
    n = 10**10
    perturbation = first_order_tower_perturbation(
        base=10,
        epsilon_exponent=n,
        levels=4,
        context=context,
    )
    correction_integer = SparseDecimalInteger.from_int(perturbation.coefficient_floor)
    integer_part = perturbation.anchor + correction_integer
    expression = "10^(10^(10^(10^(10^(-10^10)))))"
    return MathOverflowCalculation(
        n=n,
        expression=expression,
        correction=perturbation.coefficient,
        correction_floor=perturbation.coefficient_floor,
        correction_fractional_part=perturbation.fractional_part,
        omitted_tail_log10_upper_bound=perturbation.omitted_tail_log10_upper_bound,
        integer_part=integer_part,
    )


def main() -> None:
    result = calculate_mathoverflow_integer_part()
    print(result.summary())
    print(f"stable floor: {result.stable_floor}")


if __name__ == "__main__":
    main()
