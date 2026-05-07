# Nummy Python Tower Arithmetic: Prior Art Summary

Created (UTC): 2026-04-28T20:05:20Z

Repository HEAD: 3c2a03b0e2fe1a8eadcd7407d2fd5fa01dfb3852

This document summarizes the prior art reviewed as input to a Nummy-owned Python implementation intended to handle **power-tower-scale values** (tower height up to a few hundred) *and* the specific MathOverflow motivating computation:

`10^(10^(10^(10^(10^(-10^10)))))`

The key requirement of that example is not merely “range”; it is preserving a **microscopic perturbation** (`10^(-10^10)`) through multiple stacked exponentials so that a **finite decimal tail** can be recovered near a tower landmark (`10^(10^10)`).

## What “break_*” / Hypercalc-style libraries do well

### `break_eternity.js` (vendored under `../../prior-art/break_eternity.js/`)

- Uses a practical **layer/magnitude** encoding (`sign, layer, mag`) where each increment of `layer` adds another `10^` in the exponent chain.
- Provides a wide surface area of operations (log/exp/pow, tetration-family operators, formatting) and is optimized for speed.
- Tradeoff: the scalar payload (`mag`) is a JS `Number` (double). The library is range-first, not precision-first.

### `hypernums.py` (vendored under `../../prior-art/python/`)

- Encodes a “power-tower height” (`pt`) plus a float scientific top (`mantissa * 10^expon`).
- Uses log-domain identities to implement magnitude arithmetic in certain regimes.
- Tradeoff: it is float-based and contains explicit cutoffs that treat extremely small quantities as `0` in the regimes that matter for the MathOverflow example.

## What `expol.py` shows (and why it’s not enough)

### `expol.py` (vendored under `../../prior-art/expol.py/`)

- Implements a Decimal mantissa + integer base-10 exponent style “big float”.
- Shows the familiar limitations of such schemes once exponentiation reaches tetration-scale, including overflows and precision collapse.

## A useful “symbolic integer” perspective

### `SparseNumerics` (vendored under `../../prior-art/SparseNumerics/`)

- Demonstrates a clean, recursively defined representation for *very large integers* without materializing their bits/digits, **when the representation is sparse in an appropriate base**.
- Although binary sparsity is not a good fit for powers of ten, the architectural idea (“landmark term(s) + structured remainder”) is directly relevant to representing values like:
  - `10^(10^10) + 2811012357389.4407…`
  - without allocating `10^10` zeros.

## Theory context (not reimplemented here)

Nummy’s documentation corpus includes Level-Index (LI) and Symmetric Level-Index (SLI) arithmetic references. These are conceptually adjacent to “layer/mag” libraries (they also rely on iterated log/exp to extend dynamic range), but:

- the MathOverflow example additionally needs **perturbation tracking** / dominance reasoning,
- while LI/SLI (as commonly implemented) targets “stable relative precision at extreme magnitudes”, not “carry an infinitesimal through multiple exponentials”.

## Conclusions for the Python implementation

The prior art suggests a hybrid is necessary:

1. A **tower-scale representation** for magnitude (so values like `10^^200` are representable compactly).
2. A **near-landmark / perturbation mode** that can retain and propagate a very small additive correction when a value is provably close to a tower landmark, and can convert the result to a structured “decimal description” (e.g. “1, then N zeros, then …”).

The implementation under `../nummy_tower/` follows that direction: it intentionally treats the MathOverflow computation as a first-class “acceptance test” that range-only float implementations cannot satisfy.
