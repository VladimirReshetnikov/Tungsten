"""Power series with mpmath.mpf coefficients in a small parameter x.

A ``PerturbationSeries`` represents a finite Taylor polynomial
``a_0 + a_1 x + a_2 x^2 + ... + a_N x^N``.  Coefficients use ``mpmath.mpf``
so precision can be set globally with ``mpmath.mp.dps``.

The two operations that drive the asymptotic-tower propagation live here:
``exp_of_series`` (formal exponential of a series with no constant term)
and ``pow10_of_series`` (formal ``10^series`` when the constant term is
small enough to materialize as ``mpf``).

For series whose constant term is a deferred power tower, see the
``AsymptoticTowerValue`` interface in ``nummy.asymptotic``.
"""

from __future__ import annotations

import dataclasses
from typing import Iterable, Sequence, Union

from mpmath import mp, mpf


def ln10() -> "mpf":
    """Return ``ln(10)`` at the *current* mpmath precision.

    Module-level constants computed at import time are pinned to whatever
    precision was active then (usually 15 dps), which silently truncates
    coefficients that get multiplied by ``ln(10)`` later.  Always look
    this up via ``ln10()`` (or ``mp.ln10`` directly) at the point of use.
    """
    return mp.ln10

Number = Union[int, float, "mpf"]


@dataclasses.dataclass(frozen=True, init=False)
class PerturbationSeries:
    """Finite Taylor polynomial ``sum_j coeffs[j] * x^j``.

    Coefficients are coerced to ``mpmath.mpf`` on construction.  The order
    is ``len(coeffs) - 1``.  Trailing zero coefficients are kept verbatim
    so the order is exactly what the caller specified.
    """

    coeffs: tuple

    def __init__(self, coeffs: Iterable[Number]):
        materialized = tuple(mpf(c) for c in coeffs)
        if not materialized:
            materialized = (mpf(0),)
        object.__setattr__(self, "coeffs", materialized)

    @property
    def order(self) -> int:
        return len(self.coeffs) - 1

    def constant(self) -> "mpf":
        return self.coeffs[0]

    def truncate(self, max_order: int) -> "PerturbationSeries":
        if max_order < 0:
            raise ValueError("max_order must be nonneg")
        return PerturbationSeries(self.coeffs[: max_order + 1])

    @classmethod
    def constant_series(cls, value: Number, order: int = 0) -> "PerturbationSeries":
        return cls([mpf(value)] + [mpf(0)] * order)

    def __add__(self, other) -> "PerturbationSeries":
        if isinstance(other, PerturbationSeries):
            n = max(len(self.coeffs), len(other.coeffs))
            return PerturbationSeries(
                _coeff(self, i) + _coeff(other, i) for i in range(n)
            )
        return self + PerturbationSeries.constant_series(other, self.order)

    def __radd__(self, other) -> "PerturbationSeries":
        return self.__add__(other)

    def __neg__(self) -> "PerturbationSeries":
        return PerturbationSeries(-c for c in self.coeffs)

    def __sub__(self, other) -> "PerturbationSeries":
        return self + (-other if isinstance(other, PerturbationSeries) else -mpf(other))

    def __mul__(self, other) -> "PerturbationSeries":
        if isinstance(other, PerturbationSeries):
            n = len(self.coeffs) + len(other.coeffs) - 1
            buf = [mpf(0)] * n
            for i, a in enumerate(self.coeffs):
                if a == 0:
                    continue
                for j, b in enumerate(other.coeffs):
                    buf[i + j] += a * b
            return PerturbationSeries(buf)
        scalar = mpf(other)
        return PerturbationSeries(c * scalar for c in self.coeffs)

    def __rmul__(self, other) -> "PerturbationSeries":
        return self.__mul__(other)

    def evaluate(self, x: Number) -> "mpf":
        x = mpf(x)
        result = mpf(0)
        x_pow = mpf(1)
        for c in self.coeffs:
            result += c * x_pow
            x_pow *= x
        return result

    def __repr__(self) -> str:
        return f"PerturbationSeries({list(self.coeffs)!r})"


def _coeff(series: PerturbationSeries, i: int) -> "mpf":
    return series.coeffs[i] if i < len(series.coeffs) else mpf(0)


def exp_of_series(
    series: PerturbationSeries, max_order: int | None = None
) -> PerturbationSeries:
    """Return the formal Taylor series of ``exp(series(x))``.

    The input must have zero constant term (otherwise the result has an
    unbounded constant ``e^series(0)`` that would mix with the rest of the
    series unhelpfully -- callers who want that should multiply the result
    by the constant explicitly).

    Uses the standard recurrence derived from ``F'(x) = s'(x) F(x)``:
    ``F[n] = (1/n) * sum_{k=1..n} k * series[k] * F[n-k]``.
    """
    if max_order is None:
        max_order = series.order
    if series.coeffs[0] != 0:
        raise ValueError("exp_of_series requires zero constant term")
    F = [mpf(0)] * (max_order + 1)
    F[0] = mpf(1)
    inner_order = len(series.coeffs) - 1
    for n in range(1, max_order + 1):
        total = mpf(0)
        for k in range(1, min(n, inner_order) + 1):
            sk = series.coeffs[k]
            if sk != 0:
                total += k * sk * F[n - k]
        F[n] = total / n
    return PerturbationSeries(F)


def pow10_of_series(
    series: PerturbationSeries, max_order: int | None = None
) -> PerturbationSeries:
    """Return the formal Taylor series of ``10^series(x)``.

    Decomposes as ``10^M * exp(c * (series - M))`` where ``M`` is the
    constant term and ``c = ln(10)``.  Requires that ``10**M`` is
    representable as ``mpf`` at the active precision -- for towers above
    that range, see ``AsymptoticTowerValue.apply_pow10`` which defers the
    constant factor as a deferred power tower.
    """
    if max_order is None:
        max_order = series.order
    M = series.coeffs[0]
    rest = PerturbationSeries((mpf(0),) + series.coeffs[1:])
    factor = exp_of_series(rest * ln10(), max_order=max_order)
    ten_M = mpf(10) ** M
    return PerturbationSeries(ten_M * c for c in factor.coeffs)
