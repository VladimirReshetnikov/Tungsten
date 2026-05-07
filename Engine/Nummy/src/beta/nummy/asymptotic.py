"""Asymptotic-tower values: deferred power-tower scale + perturbation series.

An ``AsymptoticTowerValue`` represents a real number as

    value = scale * series(x)

where:

* ``scale = 10^^scale_layer(scale_base)`` is a *deferred* power-tower scale
  factor.  ``scale_layer = 0`` collapses to ``scale_base`` (an ordinary
  ``mpf``); higher layers represent values that cannot be materialized as
  ``mpf``.
* ``series`` is a ``PerturbationSeries`` in some small parameter ``x``.
* ``n_inner`` records the small parameter as ``x = 10^(-n_inner)`` so the
  consumer knows how to evaluate the series at the end.

The ``apply_pow10`` propagator implements the level-to-level update used by
the beta prototype and summarized in
``src/Tungsten/Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md``:

    v_in  = scale_in  * series_in(x)
    v_out = 10^v_in
          = 10^M * exp(c * (v_in - M))    where M = scale_in * series_in[0]
          = 10^M * exp(c * scale_in * (series_in[1] x + series_in[2] x^2 + ...))

The constant factor ``10^M`` becomes the new scale (with one more tower
layer when ``M`` is itself a deferred tower); the exponential becomes the
new series.  The ``scale_in`` factor is folded *into* the perturbation
series before the ``exp`` so the resulting series coefficients are again
ordinary ``mpf``.
"""

from __future__ import annotations

import dataclasses
from typing import Optional, Union

from mpmath import mpf, log10 as _log10

from .series import PerturbationSeries, exp_of_series, ln10
from .tower import PowerTower


Number = Union[int, float, "mpf"]


@dataclasses.dataclass(frozen=True)
class AsymptoticTowerValue:
    """Carrier for ``value = scale * series(x)`` with deferred scale.

    Invariants enforced by ``apply_pow10`` after the first level:

    * ``series.coeffs[0] == 1`` (the dominant term is the scale itself).
    * ``scale_layer >= 0``.
    * ``scale_layer == 0`` iff the scale is materialized as ``mpf`` in
      ``scale_base``; otherwise ``scale_base`` is the bottom of the
      deferred tower ``10^^scale_layer(scale_base)``.

    Construction outside ``apply_pow10`` is permitted (the series can have
    any constant term) and is mainly intended for the seed value before
    the first ``apply_pow10`` call.
    """

    scale_layer: int
    scale_base: "mpf"
    series: PerturbationSeries
    n_inner: int

    def __post_init__(self):
        if self.scale_layer < 0:
            raise ValueError("scale_layer must be nonneg")
        if self.n_inner < 0:
            raise ValueError("n_inner must be nonneg")

    @classmethod
    def seed_from_x(cls, n_inner: int, max_order: int = 3) -> "AsymptoticTowerValue":
        """Return the seed ``v_1 = x = 10^(-n_inner)`` after one ``10^`` of ``-n_inner``.

        The series is ``0 + 1*x + 0*x^2 + ...`` and the scale is ``1``.
        Truncation order ``max_order`` controls how many higher-order
        coefficients are tracked.  For typical leading-digit applications
        ``max_order = 1`` or ``2`` suffices, but the default ``3`` keeps a
        guard term.
        """
        coeffs = [mpf(0), mpf(1)] + [mpf(0)] * max(0, max_order - 1)
        return cls(
            scale_layer=0,
            scale_base=mpf(1),
            series=PerturbationSeries(coeffs),
            n_inner=int(n_inner),
        )

    def scale_as_tower(self) -> PowerTower:
        return PowerTower(1, self.scale_layer, self.scale_base)

    def __repr__(self) -> str:
        return (
            f"AsymptoticTowerValue(scale=10^^{self.scale_layer}({self.scale_base!s}), "
            f"series={self.series!r}, n_inner={self.n_inner})"
        )


def apply_pow10(
    value: AsymptoticTowerValue, max_order: Optional[int] = None
) -> AsymptoticTowerValue:
    """Return ``10**value`` with deferred-tower bookkeeping.

    Algorithm (see design proposal 4):

    1. Compute the new scale's exponent ``M = scale_in * series_in[0]``.
    2. Compute the perturbation argument ``Y(x) = c * scale_in * (series_in
       without its constant term)``.  When the input scale is mpf this is
       an ordinary ``mpf`` series.
    3. ``new_series = exp(Y)``.
    4. ``new_scale = 10^M``.  The ``mpf`` representation is preferred when
       ``M`` is small enough; otherwise the new scale is deferred.

    The deferred-scale-input case is intentionally restricted: the MO
    problem reaches the deferred-scale state only at the *output* of the
    final level, so this implementation does not need to step through
    ``apply_pow10`` again on a deferred-scale input.  The guard is in
    ``_propagate_deferred``.
    """
    if max_order is None:
        max_order = value.series.order

    # Step 1 / 2: handle by scale_layer.
    if value.scale_layer != 0:
        return _propagate_deferred(value, max_order)

    M_value = value.scale_base * value.series.constant()
    rest_coeffs = (mpf(0),) + tuple(value.series.coeffs[1:])
    rest = PerturbationSeries(rest_coeffs) * value.scale_base
    Y = rest * ln10()
    new_series = exp_of_series(Y, max_order=max_order)

    # Step 3: choose new_scale_layer based on |M_value|.  If M_value is
    # huge enough that converting to a Python int for downstream digit
    # extraction is impractical, defer.  We use the mpmath log10 of the
    # would-be ``10**M_value`` as the test: that is just ``M_value``, so
    # we threshold ``M_value`` directly.  ``M_value > 10^6`` or so is
    # already "deferred-tower territory" for our purposes.
    DEFER_THRESHOLD = mpf(10) ** 6
    if abs(M_value) <= DEFER_THRESHOLD:
        new_scale_base = mpf(10) ** M_value
        new_scale_layer = 0
    else:
        new_scale_base = M_value
        new_scale_layer = 1

    return AsymptoticTowerValue(
        scale_layer=new_scale_layer,
        scale_base=new_scale_base,
        series=new_series,
        n_inner=value.n_inner,
    )


def _propagate_deferred(value: AsymptoticTowerValue, max_order: int) -> AsymptoticTowerValue:
    """Series propagation when the input scale is a deferred tower.

    Out of scope for the MO problem (which terminates at level 5 without
    needing this).  Implemented as a guard rather than a full algorithm.
    """
    raise NotImplementedError(
        "apply_pow10 on deferred-scale input is not implemented; "
        "the MathOverflow problem at K=5 does not require it.  Extending "
        "this would require tracking symbolic 10^^k factors inside the "
        "series coefficients, see design proposal 4 section 4."
    )


@dataclasses.dataclass(frozen=True)
class Decomposition:
    """Decomposition of an ``AsymptoticTowerValue`` into:

    * ``dominant_log10``: an exact Python ``int`` ``E`` such that the
      dominant term equals ``10^E``.  ``None`` if the dominant cannot be
      expressed as an integer power of 10 (in which case the caller
      should treat ``dominant_mpf`` instead).
    * ``dominant_mpf``: the dominant value as ``mpf``.  Materialized only
      when the dominant fits in ``mpf`` and ``dominant_log10`` is not
      enough on its own.  ``None`` when the dominant is too large to
      materialize.
    * ``correction``: leading correction ``sum_{j>=1} scale * series[j] *
      x^j`` as an ``mpf``.  May be zero if the series has zero
      higher-order terms or if all such terms underflow.
    * ``residual_log10``: ``None`` if the truncation order was sufficient;
      otherwise an upper bound on the log10 magnitude of dropped terms,
      so callers can verify the leading digits are unaffected.
    """

    dominant_log10: Optional[int]
    dominant_mpf: Optional["mpf"]
    correction: "mpf"
    residual_log10: Optional[float]


def evaluate(value: AsymptoticTowerValue, *, drop_below_log10: float = 0.0) -> Decomposition:
    """Decompose ``value`` into a dominant ``10^E`` plus a regular correction.

    ``drop_below_log10`` controls the threshold below which higher-order
    series terms are discarded as not affecting the leading digits.  By
    default any term of magnitude ``< 1`` is dropped (it cannot influence
    the integer part), but the residual log10 is reported for confirmation.

    The implementation supports:

    * ``scale_layer = 0`` with ``|scale_base * series[0]|`` representable
      as ``mpf``.  Returns ``(None, mpf_value + correction, ...)`` -- the
      caller treats the result as a regular number.
    * ``scale_layer = 0`` with ``log10(scale_base)`` an exact integer that
      makes the dominant a clean power of 10.  Returns
      ``(dominant_log10, None, correction, ...)``.
    * ``scale_layer = 1`` with ``scale_base`` a Python-int-valued ``mpf``
      and ``series[0] == 1``.  Returns ``(scale_base, None, correction, ...)``.
    """
    s = value.series
    n_inner = value.n_inner

    if value.scale_layer == 0:
        scale = value.scale_base
        j0 = scale * s.coeffs[0]
        # Sum the j >= 1 contribution as mpf.
        correction = mpf(0)
        residual_log10 = None
        x = mpf(10) ** -n_inner
        x_pow = x
        for j in range(1, len(s.coeffs)):
            sj = s.coeffs[j]
            if sj != 0:
                term = scale * sj * x_pow
                if abs(term) >= mpf(10) ** drop_below_log10:
                    correction += term
                else:
                    log_term = float(_log10(abs(term))) if term != 0 else float("-inf")
                    if residual_log10 is None or log_term > residual_log10:
                        residual_log10 = log_term
            x_pow *= x

        # Decide whether to express j0 as 10^E or as mpf.
        # If log10(j0) is an exact integer, prefer 10^E.
        try:
            log10_j0 = _log10(j0) if j0 > 0 else None
        except (ValueError, ZeroDivisionError):
            log10_j0 = None
        if log10_j0 is not None and log10_j0 == int(log10_j0):
            try:
                exp_int = int(log10_j0)
            except (OverflowError, ValueError):
                exp_int = None
            if exp_int is not None:
                # Dominant is exactly 10^exp_int.
                return Decomposition(
                    dominant_log10=exp_int,
                    dominant_mpf=None,
                    correction=correction,
                    residual_log10=residual_log10,
                )
        # Fall back: hand the caller the mpf value.
        return Decomposition(
            dominant_log10=None,
            dominant_mpf=j0,
            correction=correction,
            residual_log10=residual_log10,
        )

    # scale_layer == 1: scale = 10^scale_base.  We need scale_base to be a
    # nonneg integer for the dominant to be an integer power of 10.
    if value.scale_layer == 1:
        if value.series.constant() != 1:
            raise NotImplementedError(
                "evaluate at scale_layer=1 currently expects series[0] == 1 "
                "(post-apply_pow10 invariant)."
            )
        sb = value.scale_base
        try:
            exp_int = int(sb)
        except (OverflowError, ValueError) as e:
            raise NotImplementedError(
                f"Cannot extract integer dominant exponent from {sb!s}: {e}"
            ) from None
        if mpf(exp_int) != sb:
            raise NotImplementedError(
                f"Non-integer dominant exponent at scale_layer=1: {sb!s}"
            )
        # Higher-order terms: contribution at order j is
        #   scale * s[j] * x^j = 10^exp_int * s[j] * 10^(-j*n_inner)
        #                      = s[j] * 10^(exp_int - j*n_inner)
        correction = mpf(0)
        residual_log10 = None
        for j in range(1, len(s.coeffs)):
            sj = s.coeffs[j]
            if sj == 0:
                continue
            net_log10_int = exp_int - j * n_inner
            log_sj = float(_log10(abs(sj))) if sj != 0 else float("-inf")
            net_log10 = net_log10_int + log_sj
            if net_log10 < drop_below_log10:
                if residual_log10 is None or net_log10 > residual_log10:
                    residual_log10 = net_log10
                continue
            # Materialize as mpf.  net_log10_int is a Python int that may
            # be large in magnitude; mpmath handles large exponents
            # natively, but we guard anyway.
            term = sj * (mpf(10) ** net_log10_int)
            correction += term
        return Decomposition(
            dominant_log10=exp_int,
            dominant_mpf=None,
            correction=correction,
            residual_log10=residual_log10,
        )

    raise NotImplementedError(
        f"evaluate currently supports scale_layer in {{0, 1}}; got {value.scale_layer}"
    )
