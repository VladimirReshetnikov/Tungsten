"""Leading-digit assembly for asymptotic tower values.

The result of ``apply_pow10`` propagation, after ``evaluate``, is a
dominant ``10^E`` plus a regular correction ``E_corr`` (or, for shallow
towers, just an ``mpf``).  When ``D = 10^E`` is an exact integer power of
10, ``D + E_corr`` has the digit pattern

    1 0 0 ... 0 [integer digits of E_corr] . [fractional digits of E_corr]

with a long run of zeros between the leading 1 and the trailing-end digits
of ``E_corr``.  This module assembles a structured ``LeadingDigits``
report that makes that pattern explicit -- including a Python ``int`` for
the number of zeros, even when astronomically large.
"""

from __future__ import annotations

import dataclasses
import sys
from typing import Optional

from mpmath import mpf, floor, nstr, log10

from .asymptotic import AsymptoticTowerValue, Decomposition, evaluate


@dataclasses.dataclass(frozen=True)
class LeadingDigits:
    """Structured report describing the leading digits of a positive number.

    Models a value of the form

        sign * (10^expo + correction)

    where ``expo`` is a Python ``int`` (so ``10^^k(small)`` shapes are fine)
    and ``correction`` is an ``mpmath.mpf`` whose magnitude is much
    smaller than ``10^expo``.

    For shallow towers where the whole value fits as ``mpf``, ``expo`` is
    still set (to ``floor(log10(value))``) and the digits are extracted
    directly.
    """

    sign: int
    integer_digit_count: int
    leading_digit: str
    zeros_count: int
    trailing_int_digits: str
    fractional_digits: str
    residual_log10: Optional[float] = None

    def summary(self, max_zeros_inline: int = 64) -> str:
        sign_str = "-" if self.sign < 0 else ""
        if self.zeros_count > max_zeros_inline:
            zeros_repr = f"<{self.zeros_count} zeros>"
        else:
            zeros_repr = "0" * self.zeros_count
        out = (
            f"{sign_str}{self.leading_digit}{zeros_repr}{self.trailing_int_digits}"
            f".{self.fractional_digits}"
        )
        return out

    def short_summary(self) -> str:
        sign_str = "-" if self.sign < 0 else ""
        first_part = f"{sign_str}{self.leading_digit}"
        if self.zeros_count == 0:
            zeros_part = ""
        else:
            zeros_part = f", followed by {self.zeros_count} zero(s),"
        trailing = (
            f" then {self.trailing_int_digits!r}"
            if self.trailing_int_digits
            else ""
        )
        return (
            f"integer part begins {first_part}{zeros_part}{trailing} "
            f"({self.integer_digit_count} digits total); "
            f"fractional part begins .{self.fractional_digits}..."
        )


def leading_digits_of(
    value: AsymptoticTowerValue,
    *,
    fractional_dps: int = 16,
    drop_below_log10: float = 0.0,
) -> LeadingDigits:
    """Assemble a ``LeadingDigits`` report from an ``AsymptoticTowerValue``.

    Calls ``evaluate`` to decompose the asymptotic value into a dominant
    ``10^E`` (or an ``mpf`` for shallow towers) plus a correction.
    """
    decomp = evaluate(value, drop_below_log10=drop_below_log10)
    return _from_decomposition(decomp, fractional_dps=fractional_dps)


def _from_decomposition(
    decomp: Decomposition, *, fractional_dps: int
) -> LeadingDigits:
    if decomp.dominant_log10 is not None:
        return _from_power_of_ten(
            expo=decomp.dominant_log10,
            correction=decomp.correction,
            fractional_dps=fractional_dps,
            residual_log10=decomp.residual_log10,
        )
    if decomp.dominant_mpf is not None:
        # Shallow case: full value fits as mpf.
        return _from_mpf(
            decomp.dominant_mpf + decomp.correction,
            fractional_dps=fractional_dps,
            residual_log10=decomp.residual_log10,
        )
    raise ValueError("Decomposition has neither dominant_log10 nor dominant_mpf")


def _from_mpf(
    value: "mpf", *, fractional_dps: int, residual_log10: Optional[float]
) -> LeadingDigits:
    if value == 0:
        return LeadingDigits(
            sign=1,
            integer_digit_count=1,
            leading_digit="0",
            zeros_count=0,
            trailing_int_digits="",
            fractional_digits="0",
            residual_log10=residual_log10,
        )
    sign = -1 if value < 0 else 1
    abs_v = abs(value)
    int_part = int(floor(abs_v))
    # Guard against Python's int-to-str conversion limit; for shallow
    # towers we only get here when the value is mpf-representable, but
    # int(floor(...)) of a "mpf with huge exponent" can still produce a
    # multi-million-digit Python int.  Increase the limit on the fly.
    needed = int(abs_v.man.bit_length() // 3 + 50) if abs_v != 0 else 100
    try:
        prev_limit = sys.get_int_max_str_digits()
    except AttributeError:
        prev_limit = None
    if prev_limit is not None and (prev_limit == 0 or prev_limit > needed):
        pass
    elif prev_limit is not None:
        sys.set_int_max_str_digits(max(needed, 4300))
    int_str = str(int_part)
    integer_digit_count = len(int_str)
    leading_digit = int_str[0]
    trailing_int_digits = int_str[1:]
    zeros_count = 0
    frac_v = abs_v - int_part
    if frac_v == 0:
        fractional_digits = "0"
    else:
        s = nstr(frac_v, fractional_dps + 5, strip_zeros=False)
        if "." in s:
            after = s.split(".", 1)[1]
        else:
            after = ""
        fractional_digits = (after or "0")[:fractional_dps]
    return LeadingDigits(
        sign=sign,
        integer_digit_count=integer_digit_count,
        leading_digit=leading_digit,
        zeros_count=zeros_count,
        trailing_int_digits=trailing_int_digits,
        fractional_digits=fractional_digits,
        residual_log10=residual_log10,
    )


def _from_power_of_ten(
    *,
    expo: int,
    correction: "mpf",
    fractional_dps: int,
    residual_log10: Optional[float],
) -> LeadingDigits:
    """Compose digits of ``10^expo + correction`` for nonneg correction.

    Assumes ``0 <= correction < 10^expo`` (the typical regime).  Splits
    ``correction`` into integer and fractional parts and builds the digit
    string with explicit zeros count between the leading 1 and the
    trailing integer digits.
    """
    if correction < 0:
        raise NotImplementedError(
            "Negative correction handling is not implemented in this proposal; "
            "the MO expression yields a positive correction."
        )
    if expo < 0:
        raise NotImplementedError("Negative dominant exponent is not supported here.")
    integer_digit_count = expo + 1
    leading_digit = "1"

    int_corr = int(floor(correction))
    frac_corr = correction - int_corr

    trailing_int_digits = str(int_corr) if int_corr > 0 else ""
    if not trailing_int_digits:
        zeros_count = expo
    else:
        zeros_count = integer_digit_count - 1 - len(trailing_int_digits)
    if zeros_count < 0:
        raise NotImplementedError(
            "Correction is larger than 10^expo; this regime is not supported here."
        )

    if frac_corr == 0:
        fractional_digits = "0"
    else:
        s = nstr(frac_corr, fractional_dps + 5, strip_zeros=False)
        if "." in s:
            after = s.split(".", 1)[1]
        else:
            after = ""
        # nstr can produce exponential form for tiny fractions; handle that.
        if "e" in s.lower():
            # frac_corr is unusually small -- just emit zeros.
            fractional_digits = "0" * fractional_dps
        else:
            fractional_digits = (after or "0")[:fractional_dps]
            if len(fractional_digits) < fractional_dps:
                fractional_digits = fractional_digits.ljust(fractional_dps, "0")

    return LeadingDigits(
        sign=1,
        integer_digit_count=integer_digit_count,
        leading_digit=leading_digit,
        zeros_count=zeros_count,
        trailing_int_digits=trailing_int_digits,
        fractional_digits=fractional_digits,
        residual_log10=residual_log10,
    )
