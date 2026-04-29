from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from decimal import Decimal, ROUND_FLOOR, localcontext
from typing import Iterable, Optional, Union


DecimalLike = Union[Decimal, int, str]


def _d(x: DecimalLike) -> Decimal:
    if isinstance(x, Decimal):
        return x
    if isinstance(x, int):
        return Decimal(x)
    if isinstance(x, str):
        return Decimal(x)
    raise TypeError(f"Unsupported DecimalLike: {type(x)}")


def _is_integer_decimal(x: Decimal) -> bool:
    # Avoid to_integral_value()/rounding behaviors; require exact integrality.
    return x == x.to_integral_exact()


def _decimal_to_int_exact(x: Decimal) -> int:
    if not _is_integer_decimal(x):
        raise ValueError(f"Expected an integral Decimal, got {x!r}")
    return int(x)


@dataclass(frozen=True, slots=True)
class Pow10Tower:
    """
    Structural base-10 power tower.

    Meaning:
      - height == 0: value == top
      - height == 1: value == 10^top
      - height == 2: value == 10^(10^top)
      - ...

    This is intentionally structural; no attempt is made to evaluate the numeric
    value unless explicitly requested via try_eval_* helpers.
    """

    height: int
    top: Decimal

    def __post_init__(self) -> None:
        if self.height < 0:
            raise ValueError(f"height must be >= 0, got {self.height}")
        if not isinstance(self.top, Decimal):
            object.__setattr__(self, "top", _d(self.top))  # type: ignore[arg-type]

    @staticmethod
    def scalar(x: DecimalLike) -> Pow10Tower:
        return Pow10Tower(0, _d(x))

    def log10_structural(self) -> Pow10Tower:
        """
        Structural log10 for towers: log10(10^^h(top)) == 10^^(h-1)(top).

        This is only valid structurally when height>0. It does not attempt to
        compute log10(top) when height==0.
        """

        if self.height == 0:
            raise ValueError("Structural log10 is only defined for height>0.")
        return Pow10Tower(self.height - 1, self.top)

    def pow10_structural(self) -> Pow10Tower:
        """Structural pow10: 10^(10^^h(top)) == 10^^(h+1)(top)."""

        return Pow10Tower(self.height + 1, self.top)

    def format_compact(self) -> str:
        if self.height == 0:
            return str(self.top)
        return f"10^^{self.height}({self.top})"

    def try_eval_int(self, *, max_digits: int = 50) -> Optional[int]:
        """
        Try to evaluate this tower to an exact Python int, but only when the
        result is small enough to be safely materialized.

        The guardrail is max_digits: the evaluated integer must have at most
        max_digits base-10 digits.
        """

        if max_digits < 1:
            raise ValueError("max_digits must be >= 1")

        if self.height == 0:
            if not _is_integer_decimal(self.top):
                return None
            n = _decimal_to_int_exact(self.top)
            if len(str(abs(n))) > max_digits:
                return None
            return n

        inner = Pow10Tower(self.height - 1, self.top).try_eval_int(max_digits=max_digits)
        if inner is None:
            return None
        if inner < 0:
            return None
        # 10**inner has (inner+1) digits.
        if inner + 1 > max_digits:
            return None
        return 10**inner


class ExponentSum:
    """
    Represents an exponent expression of the form:

      offset + sum_i (count_i * tower_i)

    This is deliberately minimal: it exists to support "multiply by 10^E"
    bookkeeping and to simplify cancellations when identical tower terms occur
    with opposite signs.
    """

    def __init__(self, *, offset: int = 0, terms: Optional[Counter[Pow10Tower]] = None) -> None:
        self.offset = int(offset)
        self.terms: Counter[Pow10Tower] = terms if terms is not None else Counter()
        self._normalize_terms_in_place()

    @staticmethod
    def from_value(value: Union[int, Pow10Tower], *, max_tower_int_digits: int) -> ExponentSum:
        exp = ExponentSum()
        exp.add(value, max_tower_int_digits=max_tower_int_digits)
        return exp

    def copy(self) -> ExponentSum:
        return ExponentSum(offset=self.offset, terms=Counter(self.terms))

    def _normalize_terms_in_place(self) -> None:
        for k in list(self.terms.keys()):
            if self.terms[k] == 0:
                del self.terms[k]

    def add(self, value: Union[int, Pow10Tower], *, max_tower_int_digits: int, count: int = 1) -> None:
        if count == 0:
            return

        if isinstance(value, int):
            self.offset += count * value
            return

        if not isinstance(value, Pow10Tower):
            raise TypeError(f"Expected int or Pow10Tower, got {type(value)}")

        evaluated = value.try_eval_int(max_digits=max_tower_int_digits)
        if evaluated is not None:
            self.offset += count * evaluated
            return

        self.terms[value] += count
        if self.terms[value] == 0:
            del self.terms[value]

    def is_pure_int(self) -> bool:
        return not self.terms

    def as_int(self) -> int:
        if self.terms:
            raise ValueError("ExponentSum is not a pure integer.")
        return self.offset

    def __str__(self) -> str:
        if not self.terms:
            return str(self.offset)
        parts: list[str] = []
        if self.offset != 0:
            parts.append(str(self.offset))
        for tower, count in sorted(self.terms.items(), key=lambda kv: (kv[0].height, str(kv[0].top))):
            if count == 1:
                parts.append(tower.format_compact())
            else:
                parts.append(f"{count}*{tower.format_compact()}")
        return " + ".join(parts) if parts else "0"


@dataclass(frozen=True, slots=True)
class Pow10Factor:
    """
    Represents a value of the form:

      coeff * 10^exp

    where exp is an ExponentSum (potentially involving tower terms).
    """

    coeff: Decimal
    exp: ExponentSum

    def mul_decimal(self, x: DecimalLike) -> Pow10Factor:
        return Pow10Factor(self.coeff * _d(x), self.exp.copy())

    def mul_pow10_exponent(self, exponent: Union[int, Pow10Tower], *, max_tower_int_digits: int) -> Pow10Factor:
        exp = self.exp.copy()
        exp.add(exponent, max_tower_int_digits=max_tower_int_digits)
        return Pow10Factor(self.coeff, exp)

    def to_decimal_if_possible(self) -> Optional[Decimal]:
        if not self.exp.is_pure_int():
            return None
        power = self.exp.as_int()
        return self.coeff * (Decimal(10) ** power)


@dataclass(frozen=True, slots=True)
class TowerLandmarkDecimal:
    """
    A value represented as:

      landmark + tail

    where:
      - landmark is a (usually enormous) pure power-of-10 tower,
      - tail is a conventional high-precision Decimal small enough to compute.
    """

    landmark: Pow10Tower
    tail: Decimal

    def describe_decimal(self, *, frac_digits: int = 10, max_exponent_digits: int = 64) -> TowerDecimalDescription:
        return TowerDecimalDescription.from_landmark_tail(
            landmark=self.landmark,
            tail=self.tail,
            frac_digits=frac_digits,
            max_exponent_digits=max_exponent_digits,
        )


@dataclass(frozen=True, slots=True)
class TowerDecimalDescription:
    """
    A structured description of a number that is "10^E plus a small tail".

    This avoids constructing the literal digit string containing E zeros.
    """

    landmark: Pow10Tower
    exponent_E: Optional[int]
    zeros_between: Optional[int]
    tail_string: str

    @staticmethod
    def _format_decimal_fixed(x: Decimal, frac_digits: int) -> str:
        if frac_digits < 0:
            raise ValueError("frac_digits must be >= 0")
        quant = Decimal(1).scaleb(-frac_digits)  # 1E-frac_digits
        q = x.quantize(quant)
        return format(q, "f")

    @classmethod
    def from_landmark_tail(
        cls,
        *,
        landmark: Pow10Tower,
        tail: Decimal,
        frac_digits: int,
        max_exponent_digits: int,
    ) -> TowerDecimalDescription:
        if landmark.height < 1:
            raise ValueError("landmark must be a positive power of 10 (height>=1).")

        # landmark == 10^E where E == landmark.log10_structural().numeric_value
        exponent_tower = landmark.log10_structural()
        exponent_E = exponent_tower.try_eval_int(max_digits=max_exponent_digits)

        tail_str = cls._format_decimal_fixed(tail, frac_digits=frac_digits)

        zeros_between: Optional[int] = None
        if exponent_E is not None:
            if tail <= 0:
                zeros_between = exponent_E
            else:
                tail_int = int(tail.to_integral_value(rounding=ROUND_FLOOR))
                tail_int_digits = len(str(abs(tail_int)))
                zeros_between = exponent_E - tail_int_digits
                if zeros_between < 0:
                    zeros_between = 0

        return cls(
            landmark=landmark,
            exponent_E=exponent_E,
            zeros_between=zeros_between,
            tail_string=tail_str,
        )

    def to_text(self) -> str:
        if self.exponent_E is None or self.zeros_between is None:
            return (
                f"Value is {self.landmark.format_compact()} + {self.tail_string} (decimal-tail computed). "
                "Landmark exponent is too large to render as an integer."
            )

        return (
            "Decimal expansion shape: starts with '1', then "
            f"{self.zeros_between} zeros, then '{self.tail_string}'."
        )


def compute_pow10_tower_small_bottom_linear(
    *,
    height: int,
    bottom_exponent: int,
    precision: int = 80,
    max_tower_int_digits: int = 64,
) -> TowerLandmarkDecimal:
    """
    Compute a first-order expansion for a base-10 power tower:

      10^(10^(...^(10^(10^bottom_exponent))))

    where 'height' is the number of outer 10^(...) layers *including* the
    bottommost 10^bottom_exponent.

    This implements the same first-order perturbation propagation as in the
    archived MathOverflow answer, and returns a landmark+tail decomposition
    for cases where the tail becomes representable as a finite Decimal.

    Notes:
    - This is a *linear* approximation in x = 10^bottom_exponent.
    - It is intended for extremely negative bottom_exponent values where x is
      astronomically small.
    """

    if height < 2:
        raise ValueError("height must be >= 2 (otherwise there is no amplification regime).")

    with localcontext(prec=precision):
        c = Decimal(10).ln()

        # At level t1 = 10^x with x = 10^bottom_exponent:
        #   t1 = 1 + c*x + O(x^2)
        base = Pow10Tower.scalar(1)  # A1
        tail = Pow10Factor(coeff=c, exp=ExponentSum(offset=bottom_exponent))  # c * 10^bottom_exponent

        # Advance from t1 to t_(height-1). Each step:
        #   base_next = 10^base
        #   tail_next = base_next * c * tail
        for _ in range(height - 1 - 1):
            base_next = base.pow10_structural()
            # Multiplying by base_next == 10^base adds exponent +base (log10(base_next) == base).
            tail = tail.mul_decimal(c).mul_pow10_exponent(base, max_tower_int_digits=max_tower_int_digits)
            base = base_next

        tail_decimal = tail.to_decimal_if_possible()
        if tail_decimal is None:
            raise ValueError(
                "Tail could not be reduced to a finite Decimal (exponent expression still contains tower terms). "
                "Increase max_tower_int_digits or use a different evaluation strategy."
            )

        # Preserve the structural tower as the landmark so downstream formatting can choose
        # between `10^10^10`-style towers and `10^E`-style landmarks as appropriate.
        return TowerLandmarkDecimal(landmark=base, tail=tail_decimal)


def compute_mo_1010101010_1010(*, precision: int = 80, frac_digits: int = 10) -> TowerDecimalDescription:
    """
    Acceptance-path helper for the archived MathOverflow computation.

    Computes a structured decimal description of:

      10^(10^(10^(10^(10^(-10^10)))))

    using the same first-order mechanism as GH's MathOverflow answer.
    """

    bottom_exponent = -(10**10)
    tower_height = 5
    result = compute_pow10_tower_small_bottom_linear(
        height=tower_height,
        bottom_exponent=bottom_exponent,
        precision=precision,
        max_tower_int_digits=64,
    )
    return result.describe_decimal(frac_digits=frac_digits, max_exponent_digits=64)
