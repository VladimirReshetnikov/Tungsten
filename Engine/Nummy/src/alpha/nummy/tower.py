"""Structural base-10 tower arithmetic for very large magnitudes."""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal, localcontext
from functools import total_ordering
from typing import Iterable

from .context import DEFAULT_CONTEXT, NummyContext


DOMINATED_ADDEND = "dominated_addend"
INEXACT = "inexact"
ROUNDED = "rounded"
UNRESOLVED_CANCELLATION = "unresolved_cancellation"

TEN = Decimal(10)
ZERO = Decimal(0)
ONE = Decimal(1)


def _decimal(value: Decimal | int | str | float) -> Decimal:
    if isinstance(value, Decimal):
        return value
    if isinstance(value, float):
        return Decimal(str(value))
    return Decimal(value)


def _merge_flags(*sets: Iterable[str]) -> frozenset[str]:
    flags: set[str] = set()
    for flag_set in sets:
        flags.update(flag_set)
    return frozenset(flags)


@total_ordering
@dataclass(frozen=True)
class TowerReal:
    """A signed finite real represented by a base-10 tower coordinate."""

    sign: int
    layer: int
    mag: Decimal
    reciprocal: bool = False
    flags: frozenset[str] = field(default_factory=frozenset)

    def __post_init__(self) -> None:
        if self.sign not in (-1, 0, 1):
            raise ValueError("sign must be -1, 0, or 1")
        if self.layer < 0:
            raise ValueError("layer must be nonnegative")
        if self.mag.is_signed():
            raise ValueError("mag must be nonnegative; use sign/reciprocal fields")
        if self.sign == 0 and (self.layer != 0 or self.mag != ZERO or self.reciprocal):
            object.__setattr__(self, "layer", 0)
            object.__setattr__(self, "mag", ZERO)
            object.__setattr__(self, "reciprocal", False)

    @classmethod
    def zero(cls) -> "TowerReal":
        return cls(0, 0, ZERO)

    @classmethod
    def one(cls) -> "TowerReal":
        return cls(1, 0, ONE)

    @classmethod
    def from_int(
        cls, value: int, *, context: NummyContext = DEFAULT_CONTEXT
    ) -> "TowerReal":
        return cls.from_decimal(Decimal(value), context=context)

    @classmethod
    def from_decimal(
        cls,
        value: Decimal | int | str | float,
        *,
        context: NummyContext = DEFAULT_CONTEXT,
    ) -> "TowerReal":
        decimal = _decimal(value)
        if decimal.is_zero():
            return cls.zero()
        sign = -1 if decimal.is_signed() else 1
        return cls(sign, 0, abs(decimal)).normalize(context=context)

    @classmethod
    def from_layer(
        cls,
        layer: int,
        mag: Decimal | int | str | float = ONE,
        *,
        sign: int = 1,
        reciprocal: bool = False,
        flags: Iterable[str] = (),
    ) -> "TowerReal":
        return cls(sign, int(layer), abs(_decimal(mag)), reciprocal, frozenset(flags))

    def with_flags(self, *flags: str) -> "TowerReal":
        return TowerReal(
            self.sign,
            self.layer,
            self.mag,
            self.reciprocal,
            _merge_flags(self.flags, flags),
        )

    @property
    def is_zero(self) -> bool:
        return self.sign == 0

    @property
    def is_positive(self) -> bool:
        return self.sign > 0

    @property
    def is_negative(self) -> bool:
        return self.sign < 0

    def normalize(self, *, context: NummyContext = DEFAULT_CONTEXT) -> "TowerReal":
        if self.is_zero or self.mag.is_zero():
            return TowerReal.zero()

        sign = self.sign
        layer = self.layer
        mag = self.mag
        reciprocal = self.reciprocal
        flags = set(self.flags)

        with localcontext(context.decimal_context()):
            while layer == 0 and mag.adjusted() > context.promotion_decimal_exponent:
                mag = mag.log10()
                layer = 1
                flags.add(ROUNDED)
            while layer > 0 and mag > context.promotion_log10_threshold:
                mag = mag.log10()
                layer += 1
                flags.add(ROUNDED)

        return TowerReal(sign, layer, +mag, reciprocal, frozenset(flags))

    def abs(self) -> "TowerReal":
        if self.sign >= 0:
            return self
        return TowerReal(1, self.layer, self.mag, self.reciprocal, self.flags)

    def neg(self) -> "TowerReal":
        if self.is_zero:
            return self
        return TowerReal(-self.sign, self.layer, self.mag, self.reciprocal, self.flags)

    def reciprocal_value(self) -> "TowerReal":
        if self.is_zero:
            raise ZeroDivisionError("cannot take reciprocal of zero")
        return TowerReal(self.sign, self.layer, self.mag, not self.reciprocal, self.flags)

    def log10_abs(self, *, context: NummyContext = DEFAULT_CONTEXT) -> "TowerReal":
        if self.is_zero:
            raise ValueError("log10(0) is not finite")
        result_sign = -1 if self.reciprocal else 1
        if self.layer > 0:
            return TowerReal(result_sign, self.layer - 1, self.mag, False, self.flags)
        with localcontext(context.decimal_context()):
            value = self.mag.log10()
        return TowerReal.from_decimal(result_sign * value, context=context).with_flags(
            *self.flags
        )

    def log10(self, *, context: NummyContext = DEFAULT_CONTEXT) -> "TowerReal":
        if self.sign <= 0:
            raise ValueError("log10 is only defined for positive TowerReal values")
        return self.log10_abs(context=context)

    def pow10(self, *, context: NummyContext = DEFAULT_CONTEXT) -> "TowerReal":
        if self.is_zero:
            return TowerReal.one()
        if self.layer == 0:
            with localcontext(context.decimal_context()):
                exponent = self.to_decimal(context=context)
                if exponent < ZERO:
                    return TowerReal.from_decimal(-exponent, context=context).pow10(
                        context=context
                    ).reciprocal_value()
                if exponent > Decimal(context.promotion_decimal_exponent):
                    return TowerReal(1, 1, exponent, False, self.flags)
                value = (exponent * TEN.ln()).exp()
            return TowerReal.from_decimal(value, context=context).with_flags(*self.flags)
        if self.sign < 0:
            return self.abs().pow10(context=context).reciprocal_value()
        return TowerReal(1, self.layer + 1, self.mag, False, self.flags)

    def compare_abs(self, other: "TowerReal") -> int:
        if self.is_zero and other.is_zero:
            return 0
        if self.is_zero:
            return -1
        if other.is_zero:
            return 1
        if self.layer == 0 and other.layer == 0:
            left = abs(self.to_decimal())
            right = abs(other.to_decimal())
            if left == right:
                return 0
            return 1 if left > right else -1
        if self.reciprocal != other.reciprocal:
            return -1 if self.reciprocal else 1
        if self.layer != other.layer:
            cmp = 1 if self.layer > other.layer else -1
        elif self.mag != other.mag:
            cmp = 1 if self.mag > other.mag else -1
        else:
            cmp = 0
        return -cmp if self.reciprocal else cmp

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, TowerReal):
            try:
                other = TowerReal.from_decimal(other)  # type: ignore[arg-type]
            except Exception:
                return False
        return (
            self.sign == other.sign
            and self.layer == other.layer
            and self.mag == other.mag
            and self.reciprocal == other.reciprocal
        )

    def __lt__(self, other: "TowerReal | int | Decimal") -> bool:
        if not isinstance(other, TowerReal):
            other = TowerReal.from_decimal(other)
        if self.sign != other.sign:
            return self.sign < other.sign
        if self.sign == 0:
            return False
        cmp = self.compare_abs(other)
        return cmp < 0 if self.sign > 0 else cmp > 0

    def __neg__(self) -> "TowerReal":
        return self.neg()

    def __abs__(self) -> "TowerReal":
        return self.abs()

    def __add__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        if not isinstance(other, TowerReal):
            other = TowerReal.from_decimal(other)
        if self.is_zero:
            return other
        if other.is_zero:
            return self
        if self.layer == 0 and other.layer == 0:
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                value = self.to_decimal() + other.to_decimal()
            return TowerReal.from_decimal(value).with_flags(*self.flags, *other.flags)
        if self.sign != other.sign:
            return self - other.neg()

        a, b = (self, other) if self.compare_abs(other) >= 0 else (other, self)
        sign = a.sign

        if a.layer == 0 and b.layer == 0 and a.reciprocal == b.reciprocal:
            if not a.reciprocal:
                return TowerReal.from_decimal(sign * (a.mag + b.mag)).with_flags(
                    *a.flags, *b.flags
                )
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                value = ONE / a.mag + ONE / b.mag
            return TowerReal.from_decimal(sign * value).with_flags(*a.flags, *b.flags)

        if a == b:
            return a * 2

        if a.layer >= 2 or a.layer > b.layer:
            return TowerReal(
                sign,
                a.layer,
                a.mag,
                a.reciprocal,
                _merge_flags(a.flags, b.flags, (DOMINATED_ADDEND,)),
            )

        if a.layer == 1 and b.layer == 1 and not a.reciprocal and not b.reciprocal:
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                hi = a.mag
                lo = b.mag
                delta = lo - hi
                if delta < Decimal(-DEFAULT_CONTEXT.dominance_decimal_digits):
                    return a.with_flags(DOMINATED_ADDEND)
                mag = hi + (ONE + (TEN.ln() * delta).exp()).log10()
            return TowerReal(sign, 1, +mag).normalize()

        return TowerReal(
            sign,
            a.layer,
            a.mag,
            a.reciprocal,
            _merge_flags(a.flags, b.flags, (DOMINATED_ADDEND,)),
        )

    def __radd__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        return self + other

    def __sub__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        if not isinstance(other, TowerReal):
            other = TowerReal.from_decimal(other)
        if other.is_zero:
            return self
        if self.is_zero:
            return other.neg()
        if self == other:
            return TowerReal.zero()
        if self.layer == 0 and other.layer == 0:
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                value = self.to_decimal() - other.to_decimal()
            return TowerReal.from_decimal(value).with_flags(*self.flags, *other.flags)
        if self.sign != other.sign:
            return self + other.neg()

        cmp = self.compare_abs(other)
        if cmp == 0:
            return TowerReal.zero().with_flags(UNRESOLVED_CANCELLATION)
        a, b = (self, other) if cmp > 0 else (other, self)
        sign = self.sign if cmp > 0 else -self.sign

        if a.layer == 0 and b.layer == 0 and not a.reciprocal and not b.reciprocal:
            return TowerReal.from_decimal(sign * (a.mag - b.mag)).with_flags(
                *a.flags, *b.flags
            )

        return TowerReal(
            sign,
            a.layer,
            a.mag,
            a.reciprocal,
            _merge_flags(a.flags, b.flags, (DOMINATED_ADDEND,)),
        )

    def __rsub__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        return TowerReal.from_decimal(other) - self

    def __mul__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        if not isinstance(other, TowerReal):
            other = TowerReal.from_decimal(other)
        if self.is_zero or other.is_zero:
            return TowerReal.zero()
        sign = self.sign * other.sign
        if self.layer == 0 and other.layer == 0:
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                value = self.to_decimal() * other.to_decimal()
            return TowerReal.from_decimal(value).with_flags(*self.flags, *other.flags)
        log_product = self.log10_abs() + other.log10_abs()
        result = log_product.pow10()
        if sign < 0:
            result = result.neg()
        return result.with_flags(*self.flags, *other.flags, *log_product.flags)

    def __rmul__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        return self * other

    def __truediv__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        if not isinstance(other, TowerReal):
            other = TowerReal.from_decimal(other)
        if other.is_zero:
            raise ZeroDivisionError("cannot divide by zero")
        if self.layer == 0 and other.layer == 0:
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                value = self.to_decimal() / other.to_decimal()
            return TowerReal.from_decimal(value).with_flags(*self.flags, *other.flags)
        return self * other.reciprocal_value()

    def __rtruediv__(self, other: "TowerReal | int | Decimal") -> "TowerReal":
        return TowerReal.from_decimal(other) / self

    def __pow__(self, exponent: "TowerReal | int | Decimal") -> "TowerReal":
        if not isinstance(exponent, TowerReal):
            exponent = TowerReal.from_decimal(exponent)
        if exponent.is_zero:
            return TowerReal.one()
        if self.layer == 0 and exponent.layer == 0:
            if self.is_zero or self.sign < 0:
                with localcontext(DEFAULT_CONTEXT.decimal_context()):
                    value = self.to_decimal() ** exponent.to_decimal()
                return TowerReal.from_decimal(value).with_flags(
                    *self.flags, *exponent.flags
                )
            with localcontext(DEFAULT_CONTEXT.decimal_context()):
                exponent_decimal = exponent.to_decimal()
                result_log10 = self.to_decimal().log10() * exponent_decimal
                if abs(result_log10) > Decimal(DEFAULT_CONTEXT.promotion_decimal_exponent):
                    result = TowerReal.from_decimal(result_log10).pow10()
                    return result.with_flags(*self.flags, *exponent.flags)
                value = self.to_decimal() ** exponent_decimal
            return TowerReal.from_decimal(value).with_flags(*self.flags, *exponent.flags)
        if self.sign <= 0:
            raise ValueError("nonpositive bases are not supported by TowerReal.__pow__")
        return (self.log10() * exponent).pow10()

    def to_decimal(self, *, context: NummyContext = DEFAULT_CONTEXT) -> Decimal:
        if self.layer != 0:
            raise OverflowError("only layer-0 TowerReal values can be materialized")
        with localcontext(context.decimal_context()):
            value = +self.mag
            if self.reciprocal:
                value = ONE / value
        return value.copy_negate() if self.sign < 0 else value

    def to_tower_string(self) -> str:
        if self.is_zero:
            return "0"
        sign = "-" if self.sign < 0 else ""
        if self.layer == 0:
            body = format(self.mag, "f")
        elif self.layer <= 6:
            body = "e" * self.layer + format(self.mag, "f")
        else:
            body = f"{self.layer} PT {format(self.mag, 'f')}"
        if self.reciprocal:
            body = f"1/({body})"
        return sign + body

    def __str__(self) -> str:
        suffix = ""
        if self.flags:
            suffix = " [" + ", ".join(sorted(self.flags)) + "]"
        return self.to_tower_string() + suffix

    def __repr__(self) -> str:
        return (
            "TowerReal("
            f"sign={self.sign}, layer={self.layer}, mag={self.mag!r}, "
            f"reciprocal={self.reciprocal}, flags={sorted(self.flags)!r})"
        )
