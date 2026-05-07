"""``PowerTower`` value class for general layer/magnitude work.

A ``PowerTower`` represents a real number as ``sign * 10^^layer(mag)``,
i.e., ``sign`` times ``layer`` nested applications of ``10^(.)`` to ``mag``.
``layer = 0`` means the value is just ``sign * mag``.

This is the "magnitude descriptor" half of the package: useful for
representing, comparing, and incrementing/decrementing tower heights, but
*not* for extracting leading digits from a tower with a sub-dominant
perturbation.  For that, see ``AsymptoticTowerValue`` in
``nummy.asymptotic``.
"""

from __future__ import annotations

import dataclasses
from typing import Union

from mpmath import mpf, log10, power


Number = Union[int, float, "mpf"]


@dataclasses.dataclass(frozen=True, init=False)
class PowerTower:
    """A real number ``sign * 10^^layer(mag)``.

    No automatic normalization is performed.  ``PowerTower(1, 0, mpf(7))``
    and ``PowerTower(1, 1, log10(mpf(7)))`` represent the same value but
    are not ``==`` to each other.  Use ``canonicalize`` to push the value
    to its preferred form (smallest layer with ``mag`` in a sane range).
    """

    sign: int
    layer: int
    mag: "mpf"

    def __init__(self, sign: int, layer: int, mag: Number):
        if sign not in (-1, 1):
            raise ValueError("sign must be -1 or +1")
        if layer < 0:
            raise ValueError("layer must be nonneg")
        object.__setattr__(self, "sign", int(sign))
        object.__setattr__(self, "layer", int(layer))
        object.__setattr__(self, "mag", mpf(mag))

    @classmethod
    def from_mpf(cls, value: Number) -> "PowerTower":
        v = mpf(value)
        if v >= 0:
            return cls(1, 0, v)
        return cls(-1, 0, -v)

    def to_mpf(self) -> "mpf":
        """Materialize as ``mpmath.mpf`` if the active precision allows.

        Raises ``OverflowError`` if any intermediate ``10^x`` exceeds what
        ``mpmath`` can represent.  For deep towers, this almost certainly
        will raise; use ``canonicalize`` and inspect ``layer``/``mag``
        instead.
        """
        v = self.mag
        for _ in range(self.layer):
            v = power(mpf(10), v)
        return v if self.sign > 0 else -v

    def pow10(self) -> "PowerTower":
        """Return the tower for ``10**self``.

        Increases ``layer`` by one when ``sign`` is positive.  Negative
        towers are not supported here -- ``10^(-x)`` is a tiny positive
        number rather than another tower of comparable height.
        """
        if self.sign < 0:
            raise NotImplementedError(
                "pow10 of a negative PowerTower is not supported in this proposal; "
                "use AsymptoticTowerValue for the structured cases that need it."
            )
        return PowerTower(1, self.layer + 1, self.mag)

    def log10(self) -> "PowerTower":
        """Return the tower for ``log10(self)`` (``self`` must be positive).

        Decrements ``layer`` when ``layer >= 1``; otherwise applies
        ``mpmath.log10`` to ``mag`` directly.
        """
        if self.sign < 0:
            raise ValueError("log10 of a negative number")
        if self.layer == 0:
            if self.mag <= 0:
                raise ValueError("log10 of zero or negative")
            return PowerTower.from_mpf(log10(self.mag))
        return PowerTower(1, self.layer - 1, self.mag)

    def canonicalize(self, mag_low: float = 1.0, mag_high: float = 1e15) -> "PowerTower":
        """Normalize so ``mag`` sits in a moderate range.

        Promotes ``mag > mag_high`` by taking ``log10`` and bumping the
        layer.  Demotes ``mag <= mag_low`` (when ``layer >= 1``) by
        applying ``10^`` and decrementing the layer, as long as the result
        remains representable.
        """
        sign, layer, mag = self.sign, self.layer, self.mag
        # Promote: large mag -> +1 layer.
        while mag > mag_high:
            mag = log10(mag)
            layer += 1
        # Demote: tiny positive mag at layer >= 1 collapses to ordinary number.
        while layer >= 1 and mag <= mag_low:
            try:
                mag = power(mpf(10), mag)
            except (OverflowError, ValueError):
                break
            layer -= 1
        return PowerTower(sign, layer, mag)

    def __lt__(self, other: "PowerTower") -> bool:
        a = self.canonicalize()
        b = other.canonicalize()
        if a.sign != b.sign:
            return a.sign < b.sign
        # Same sign; compare magnitudes, then flip if both negative.
        if a.layer != b.layer:
            mag_lt = a.layer < b.layer
        else:
            mag_lt = a.mag < b.mag
        return mag_lt if a.sign > 0 else not mag_lt

    def __le__(self, other: "PowerTower") -> bool:
        return self == other or self < other

    def __gt__(self, other: "PowerTower") -> bool:
        return not (self <= other)

    def __ge__(self, other: "PowerTower") -> bool:
        return not (self < other)

    def __eq__(self, other) -> bool:
        if not isinstance(other, PowerTower):
            return NotImplemented
        a = self.canonicalize()
        b = other.canonicalize()
        return a.sign == b.sign and a.layer == b.layer and a.mag == b.mag

    def __hash__(self) -> int:
        a = self.canonicalize()
        return hash((a.sign, a.layer, float(a.mag)))

    def __repr__(self) -> str:
        sign_str = "+" if self.sign > 0 else "-"
        return f"PowerTower({sign_str}1, layer={self.layer}, mag={self.mag!s})"

    def __str__(self) -> str:
        if self.layer == 0:
            return f"{self.sign * self.mag}"
        sign = "" if self.sign > 0 else "-"
        return f"{sign}10^^{self.layer}({self.mag})"
