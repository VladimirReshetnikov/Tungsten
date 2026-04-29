# Nummy Python Tower Arithmetic: Proposed Approach

Created (UTC): 2026-04-28T20:06:10Z

Repository HEAD: 3c2a03b0e2fe1a8eadcd7407d2fd5fa01dfb3852

## Goal

Implement a small, Nummy-owned Python module that can:

1. Represent and manipulate **power-tower-scale values** (tower height up to a few hundred) without overflowing or allocating impossible digit arrays.
2. **Directly compute** the MathOverflow motivating expression:

`T := 10^(10^(10^(10^(10^(-10^10)))))`

in the specific sense discussed in `docs/how-to-calculate-1010101010-1010/`:

- express `T` as a tower landmark plus a finite tail,
- recover the tail digits (`2811012357389.4407116278…`),
- and produce a structured decimal description (“1, then `10^10-13` zeros, then …”) without materializing the full integer.

## Non-goals (for this first Python implementation)

- Full LI/SLI arithmetic with error bounds and rounding models.
- A complete “drop-in replacement” for `decimal.Decimal` / incremental-game libraries.
- Exact digit-level arithmetic for *generic* huge integers (that is a separate problem; this module is tower-focused).

## Core idea: two cooperating representations

### 1) Tower-scale magnitude (`Pow10Tower`)

We represent pure base-10 power towers as:

`Pow10Tower(height, top)`

meaning:

- `height = 0` represents the finite scalar `top` (a `Decimal`),
- `height = 1` represents `10^top`,
- `height = 2` represents `10^(10^top)`,
- etc.

This is intentionally structural: it can represent towers with hundreds of levels as a tiny object.

Operations we need:

- `log10()` and `iterated_log10(k)`:
  - `log10(Pow10Tower(h, t)) = Pow10Tower(h-1, t)` when `h > 0`.
- magnitude comparison (dominance) by comparing `(height, top)` lexicographically in the regimes where that is valid.
- formatting: produce concise strings like `10^^5(-10^10)` or `10^(10^(10^(10^(10^(-10^10)))))` for debugging.

### 2) Near-landmark “tower + tail” form (`TowerLandmarkDecimal`)

When a value is *provably* very close to an exact tower landmark such as `10^(10^10)`, we represent it as:

`L + tail`

where:

- `L` is a `Pow10Tower` (the landmark),
- `tail` is an ordinary high-precision `Decimal` whose magnitude is small enough to fully compute (and therefore to extract digits).

This form is what makes the MathOverflow computation tractable: the “interesting information” is in the tail, and the landmark carries the impossible part.

## Computing the MathOverflow expression: first-order perturbation propagation

Let:

- `x := 10^(-10^10)` (an astronomically small positive number),
- `c := ln(10)`.

Define the 5-level tower (bottom to top):

- `t0 = x`
- `t1 = 10^t0`
- `t2 = 10^t1`
- `t3 = 10^t2`
- `t4 = 10^t3`  (this is `T`)

Because `x` is extremely small, we expand each `10^u` to first order in `x`:

- `10^x = 1 + c x + O(x^2)`
- `10^(1 + ε) = 10 * (1 + c ε + O(ε^2))`

If we maintain an invariant of the form:

`ti = Ai + Bi * x + O(x^2)`

then:

- `A1 = 1`, `B1 = c`
- and for each step `i -> i+1`:
  - `A(i+1) = 10^(Ai)`
  - `B(i+1) = 10^(Ai) * c * Bi`

This is exactly the hand-derivation in the archived MathOverflow answer, but mechanized.

At the final step, the `x` factor cancels against the tower landmark scale, yielding a finite tail:

`T = 10^(10^10) + 10^11 * c^4 + (tiny positive correction)`

Therefore:

- the decimal expansion begins with `1`, then `10^10-13` zeros, then the digits of `10^11*c^4`,
- and the integer part is `10^(10^10) + floor(10^11*c^4 + tiny)`.

### Why first order is enough

The neglected term is `O(x^2)`. Even when multiplied by the largest scale appearing in the propagation, it remains far below `1`, so it does not affect the integer part (and, for the acceptance target, it does not affect the displayed tail digits we compute).

## Implementation sketch

### Decimal precision strategy

- Use Python’s `decimal.Decimal` for the tail computations.
- Select precision based on the number of tail digits requested (default: enough to reproduce the `2811012357389.4407116278…` prefix with margin).

### APIs

- `Pow10Tower(height: int, top: Decimal)`
  - `format_compact() -> str`
  - `log10() -> Pow10Tower`
- `TowerLandmarkDecimal(landmark: Pow10Tower, tail: Decimal)`
  - `describe_decimal(prefix_tail_digits: int) -> TowerDecimalDescription`
- `compute_mo_1010101010_1010(precision: int, tail_digits: int) -> TowerLandmarkDecimal`
  - returns `10^(10^10)` landmark + a `Decimal` tail (`10^11 * ln(10)^4 + ...`)

## Extensibility for “few hundred levels”

This module is designed so that:

- the tower representation supports very large heights structurally,
- the “landmark + tail” form can be reused whenever a computation naturally produces a value near a recognizable tower landmark,
- and additional perturbation modes (higher-order series, multiple small parameters, interval error tracking) can be layered on later without changing the core `Pow10Tower` abstraction.
