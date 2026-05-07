# Beyond Floating Point (Clenshaw 1984)

Created (UTC): 2026-04-28T00:26:00Z

Repository HEAD: dad97d346dba0cc2ef8655f3527cb5fc37f61b72

This directory contains the paper "Beyond Floating Point" by C. W. Clenshaw
and F. W. J. Olver. It is the foundational Nummy reference for the
level-index idea: representing huge values through generalized logarithms and
exponentials rather than widening a conventional exponent field.

## Files

- [Markdown rendering](<Beyond Floating Point - Clenshaw 1984.md>) - generated from the TeX sidecar for easier reading and search.
- [TeX sidecar](<Beyond Floating Point - Clenshaw 1984.tex>) - searchable OCR/LaTeX source used to generate the Markdown rendering.
- [`images/`](images/) - extracted figures referenced by the TeX sidecar.

## Why It Matters

The paper motivates alternatives to ordinary floating point, introduces the
generalized exponential/logarithm machinery behind level-index arithmetic, and
explains why overflow and underflow avoidance changes the arithmetic trade-off:
addition and subtraction become harder, while multiplication, division, and
power-like operations align more naturally with the representation.
