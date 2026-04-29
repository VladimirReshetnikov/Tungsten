"""Sparse exact decimal integers.

The type stores exact integers as a sum of decimal blocks such as
``10^10000000000 + 2811012357389``. It is intentionally small: enough for
Nummy's first tower calculations without pretending to be a general sparse
integer algebra package.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import groupby
from typing import Iterable, Iterator, Tuple


Term = Tuple[int, int]


@dataclass(frozen=True)
class SparseDecimalInteger:
    """Exact nonnegative decimal integer stored by sparse decimal terms."""

    terms: tuple[Term, ...]

    def __post_init__(self) -> None:
        normalized = self._normalize(self.terms)
        object.__setattr__(self, "terms", normalized)
        self._validate_non_overlapping()

    @staticmethod
    def _normalize(terms: Iterable[Term]) -> tuple[Term, ...]:
        grouped: list[Term] = []
        sorted_terms = sorted(
            ((int(coeff), int(exp)) for coeff, exp in terms if int(coeff) != 0),
            key=lambda item: item[1],
            reverse=True,
        )
        for exp, exp_terms in groupby(sorted_terms, key=lambda item: item[1]):
            coeff = sum(term_coeff for term_coeff, _ in exp_terms)
            if coeff:
                grouped.append((coeff, exp))
        if not grouped:
            return ()
        return tuple(grouped)

    @classmethod
    def zero(cls) -> "SparseDecimalInteger":
        return cls(())

    @classmethod
    def from_int(cls, value: int) -> "SparseDecimalInteger":
        if value < 0:
            raise ValueError("SparseDecimalInteger only stores nonnegative integers")
        if value == 0:
            return cls.zero()
        return cls(((value, 0),))

    @classmethod
    def power_of_ten(cls, exponent: int) -> "SparseDecimalInteger":
        if exponent < 0:
            raise ValueError("Decimal exponent must be nonnegative")
        return cls(((1, exponent),))

    def __bool__(self) -> bool:
        return bool(self.terms)

    def __iter__(self) -> Iterator[Term]:
        return iter(self.terms)

    def __add__(self, other: "SparseDecimalInteger | int") -> "SparseDecimalInteger":
        if isinstance(other, int):
            other = SparseDecimalInteger.from_int(other)
        if not isinstance(other, SparseDecimalInteger):
            return NotImplemented
        return SparseDecimalInteger((*self.terms, *other.terms))

    def __radd__(self, other: int) -> "SparseDecimalInteger":
        return self + other

    @property
    def is_zero(self) -> bool:
        return not self.terms

    @property
    def digit_count(self) -> int:
        if not self.terms:
            return 1
        coeff, exp = self.terms[0]
        return len(str(abs(coeff))) + exp

    def suffix(self, digits: int) -> str:
        """Return the final ``digits`` decimal digits, padded with zeros."""

        if digits <= 0:
            return ""
        modulus = 10**digits
        value = 0
        for coeff, exp in self.terms:
            if exp >= digits:
                continue
            value = (value + coeff * (10**exp)) % modulus
        return f"{value:0{digits}d}"

    def leading_description(self) -> str:
        """Describe the common ``10^N + k`` shape without expanding it."""

        if len(self.terms) == 2 and self.terms[0][0] == 1 and self.terms[1][1] == 0:
            top_exp = self.terms[0][1]
            suffix = str(self.terms[1][0])
            zeros = top_exp - len(suffix)
            if zeros >= 0:
                return f"1 followed by {zeros} zeros, then {suffix}"
        return repr(self)

    def to_decimal_string(self, *, max_digits: int = 10_000) -> str:
        """Materialize the decimal string if it is below ``max_digits``."""

        digits = self.digit_count
        if digits > max_digits:
            raise ValueError(
                f"decimal expansion has {digits} digits; max_digits is {max_digits}"
            )
        slots = ["0"] * digits
        for coeff, exp in self.terms:
            text = str(coeff)
            start = digits - exp - len(text)
            if start < 0:
                raise ValueError("term overlaps beyond the leading digit boundary")
            for offset, ch in enumerate(text):
                pos = start + offset
                if slots[pos] != "0":
                    raise ValueError("term overlap prevents simple decimal rendering")
                slots[pos] = ch
        return "".join(slots) or "0"

    def _validate_non_overlapping(self) -> None:
        previous_low = None
        for coeff, exp in self.terms:
            if coeff < 0:
                raise ValueError("negative sparse coefficients are not supported")
            if exp < 0:
                raise ValueError("negative decimal exponents are not supported")
            high = exp + len(str(coeff))
            if previous_low is not None and high > previous_low:
                raise ValueError("sparse decimal terms overlap")
            previous_low = exp

    def __str__(self) -> str:
        if not self.terms:
            return "0"
        parts = []
        for coeff, exp in self.terms:
            if exp == 0:
                parts.append(str(coeff))
            elif coeff == 1:
                parts.append(f"10^{exp}")
            else:
                parts.append(f"{coeff}*10^{exp}")
        return " + ".join(parts)
