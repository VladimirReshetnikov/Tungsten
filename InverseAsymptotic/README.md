# InverseAsymptotic

- Created (UTC): 2026-06-26T04:13:47Z
- Repository HEAD: 3915ec6ce0cb1e3f3fc06c73b6d7ebeebae20f43

`InverseAsymptotic` is a Wolfram Language package for asymptotic expansions of
real local inverse branches.  It fills a gap where `InverseFunction`, `Series`,
`InverseSeries`, or `Asymptotic` either choose an unwanted complex branch or stop
because the inverse expansion is not an ordinary power series.

The main entry point is:

```wolfram
Get["src/InverseAsymptotic/InverseAsymptotic.wl"];

InverseAsymptotic[
  x + x^2 (1 + Log[x]),
  {x, 0},
  {y, 0},
  SeriesTermGoal -> 4,
  Assumptions -> y > 0
]
```

The package represents local expansions as finite generalized power-log series
in the output displacement `s = y - y0`, with terms of the form
`c s^a Log[s]^b`.  A hybrid Newton reversion loop delegates ordinary asymptotic
expansion to Wolfram Language's `Asymptotic`, then uses the package's
power-log term algebra to finish expansions that the kernel leaves in quotient
or binomial form, such as the real inverse of `x + x^Sqrt[2]`.

## API

- `InverseAsymptotic[f, {x, x0}, {y, y0}]` returns the inverse expansion.
- `InverseAsymptotic[f, {x, x0}, y]` computes `y0` with `Limit`.
- `InverseAsymptoticData[...]` returns diagnostics, retained terms, normalized
  input terms, and residual terms.
- `InverseAsymptoticTerms[...]` returns the retained canonical term table.
- `InverseAsymptoticVerify[f, approx, {x, x0}, {y, y0}]` checks whether the
  leading composition residual is smaller than the last retained term.

The first argument can be an expression in `x`, a pure function, or a
`ConditionalExpression`.  Conditions are folded into the assumptions used for
the local real branch.

## Examples

```wolfram
InverseAsymptotic[
  x + x^2 (1 + Log[x]),
  {x, 0},
  {y, 0},
  SeriesTermGoal -> 2,
  Assumptions -> y > 0
]
(* y - y^2 (1 + Log[y]) *)
```

```wolfram
InverseAsymptotic[
  ConditionalExpression[# + #^Sqrt[2], # >= 0] &,
  {x, 0},
  {z, 0},
  SeriesTermGoal -> 4,
  Assumptions -> z > 0
]
(* z - z^Sqrt[2] + Sqrt[2] z^(2 Sqrt[2] - 1)
     - (6 - Sqrt[2]) z^(3 Sqrt[2] - 2)/2 *)
```

The current method is intentionally local and asymptotic.  It is strongest for
finite compositions of algebraic powers and logarithms near a real branch where
the leading normalized term is `c (x - x0)^a` with no leading logarithmic factor.
Leading logarithmic inversions such as `x Log[x]` need a Lambert/log-log seed
strategy and are outside the first implementation.
