"""Runnable example: compute and report the MathOverflow #79217 expression.

The expression: 10^(10^(10^(10^(10^(-10^10))))).

The published derivation -- archived under
``../../docs/how-to-calculate-1010101010-1010/`` -- gives the integer part
as ``1`` followed by ``10^10 - 13`` zeros followed by ``2811012357389``,
with a fractional part beginning ``.4407116278...``.

Run from this directory with::

    PYTHONPATH=.. python mo_question.py
"""

from __future__ import annotations

from nummy import compute_mo_expression


def main() -> int:
    result = compute_mo_expression()
    ld = result.leading

    print("MathOverflow #79217: 10^(10^(10^(10^(10^(-10^10)))))")
    print("=" * 60)
    print(f"Sign:                          {'+' if ld.sign > 0 else '-'}")
    print(f"Integer part has               {ld.integer_digit_count:,} digits")
    print(f"Leading digit:                 {ld.leading_digit}")
    print(f"Following zeros count:         {ld.zeros_count:,}")
    print(f"Trailing integer digits:       {ld.trailing_int_digits}")
    print(f"First fractional digits:       .{ld.fractional_digits}")
    if ld.residual_log10 is not None:
        print(
            f"Dropped higher-order terms:    "
            f"<= 10^({ld.residual_log10:.3f}) (negligible vs. integer part)"
        )
    print()
    print("Compact notation:")
    print(f"  {ld.short_summary()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
