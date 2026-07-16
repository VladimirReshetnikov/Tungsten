# Nummy Python Tower Arithmetic Implementation Approach

Created (UTC): 2026-04-28T19:31:12Z

Repository HEAD: 3c2a03b0e2fe1a8eadcd7407d2fd5fa01dfb3852

## Purpose

This note records the approach used for the first repository-owned Python
implementation under `Engine/Nummy/src/alpha`. The immediate target is not a
complete SLI implementation. It is a practical, inspectable core that can:

- represent base-10 power-tower magnitudes with heights in the low hundreds;
- perform ordinary range-safe operations without forcing huge decimal strings
  or dense integers into memory;
- keep dominance decisions explicit;
- compute the integer part of the MathOverflow example archived at
  `Engine/Nummy/docs/how-to-calculate-1010101010-1010` directly.

The implementation deliberately starts with a small surface area. It is a
reference kernel, not a performance library.

## Prior-Art Research Summary

The local Nummy archive already contains the important split:

- Hypercalc, `hypernums.py`, and `break_eternity.js` show practical
  base-10 power-tower arithmetic.
- GSLI and the MATLAB level-index simulator show the more principled
  symmetric level-index line.
- The MathOverflow example is a compact case where ordinary tower magnitude is
  not enough; the tiny perturbation has to be preserved symbolically long
  enough to affect the low decimal suffix of an enormous integer.

Public references checked during this pass reinforce the same conclusion.
`break_eternity.js` uses `sign`, `layer`, and `mag`, where layer `n` means
`10` exponentiated `n` times over the magnitude; it normalizes by logging large
`mag` values upward and exponentiating small layer payloads downward. Its README
also lists the familiar `eeX`, `N PT X`, and tetration-style input forms that
users expect for this domain: <https://github.com/Patashu/break_eternity.js/>.

HyperCalc is the older practical calculator ancestor for the same idea. Its
JavaScript page points back to the full Hypercalc lineage and help manual:
<https://www.mrob.com/pub/comp/hypercalc/hypercalc-javascript.html>.

The level-index papers supply the numerical-contract warning. Clenshaw and
Turner describe SLI as a system intended to virtually abolish overflow and
underflow by representing large magnitudes through generalized exponentials and
tiny magnitudes by reciprocation:
<https://academic.oup.com/imajna/article/8/4/517/758814>. Clenshaw and Olver's
level-index operations paper is the key source for basic arithmetic algorithms
in the repeated-exponential representation:
<https://epubs.siam.org/doi/10.1137/0724034>.

The newer MATLAB simulator paper is useful because it restates the modern
trade-off: level-index arithmetic moves overflow and underflow farther away,
but it spaces very large numbers sparsely and therefore is not a magic source
of ordinary decimal digits:
<https://arxiv.org/abs/2402.02301>.

On the Python side, `mpmath` and `gmpy2` remain valuable backends for bounded
high-precision coefficients. `mpmath` is an arbitrary-precision floating-point
library, but its own technical notes warn that attempting functions such as
`exp(10^100000)` is still resource-hungry because ordinary arbitrary precision
does not provide structural tower coordinates:
<https://mpmath.org/doc/current/> and
<https://mpmath.org/doc/current/technical.html>. `gmpy2.mpfr` provides MPFR
real numbers with explicit precision and rounding modes, and remains a likely
future backend if this Python reference grows beyond the standard library:
<https://gmpy2.readthedocs.io/en/latest/mpfr.html>.

## Chosen First Implementation

The Python implementation has four layers.

| Layer | Module | Responsibility |
| --- | --- | --- |
| Structural tower values | `nummy.tower` | Signed base-10 tower coordinate with explicit reciprocal state, dominance-aware addition, multiplication/division through logs, and compact tower formatting. |
| Sparse decimal integers | `nummy.sparse_decimal` | Exact integers such as `10^N + k` without materializing `N + 1` decimal digits. |
| Perturbation evaluator | `nummy.perturbation` and `nummy.mo` | First-order Taylor propagation through fixed-height `10^x` towers, with a conservative tail-scale estimate for the MathOverflow calculation. |
| Calculator surface | `nummy.calculator`, `nummy.repl`, and `nummy.cli` | A deliberately small Tungsten-style REPL over the tower arithmetic: numeric literals, variables, assignment, arithmetic operators, precision marks, perturbative tower states, `Floor`, and output history references. |

This is intentionally closer to Hypercalc / break_eternity at the
representation boundary than to full SLI. The important SLI-inspired choice is
the explicit reciprocal state and the explicit reporting of dominance. A later
implementation can replace the arithmetic kernel with Clenshaw-Turner bounded
sequence algorithms without changing the user-facing concepts.

## Representation

`TowerReal` represents a finite value as:

```text
sign * 10^10^...^mag       if reciprocal == false
sign / (10^10^...^mag)     if reciprocal == true
```

where `layer` is the number of `10^` applications. Layer `0` stores an ordinary
`Decimal` magnitude. Layer `1` stores `10^mag`; layer `2` stores
`10^(10^mag)`, and so on. This is a base-10 tower coordinate, not exact decimal
arithmetic.

The type is deliberately immutable. Operations return new values with flags
such as `dominated_addend` when an operand is discarded by a certified
large-scale dominance rule.

## Arithmetic Semantics

The implementation supports a modest but useful arithmetic subset.

- `pow10` and `log10` are structural level shifts whenever possible.
- Multiplication and division use `log10(abs(x)) +/- log10(abs(y))`, then
  `pow10`.
- Addition uses ordinary `Decimal` arithmetic in layer `0`, log-add-exp at
  layer `1`, exact doubling for identical high-layer operands through
  multiplication by `2`, and dominance for separated higher layers.
- Subtraction returns exact zero for structurally equal operands, ordinary
  decimal subtraction in layer `0`, and dominance or an unresolved-style
  approximation flag for high-layer cases.

This is not yet the full SLI addition/subtraction algorithm. That is an
intentional boundary: a few hundred tower levels mostly need structural
log/exp moves and dominance, while the MathOverflow example needs a
perturbation engine rather than a generic same-scale subtractor.

## Calculator Precision Contract

The calculator surface has a stricter display contract than the structural
tower kernel. Ordinary layer-0 calculations use exact `Fraction` arithmetic for
`+`, `-`, `*`, `/`, and integer powers. Results are rounded for display only,
so every decimal digit shown before the precision mark is derived from exact
integer arithmetic.

The syntax intentionally follows the familiar Wolfram Language forms:

```text
1.23`30
1.23`30*^6
N[1 / 3, 60]
SetPrecision[1 / 7, 80]
```

The REPL and CLI also accept `--precision N` for the default output precision.
Output is printed with a backtick precision mark, such as
``0.33333333333333333333`20``. A result marked with precision `0` is a
structural approximation whose ordinary decimal digits are not certified by the
current alpha evaluator. This avoids silently presenting approximate tower
coordinates as if they were trustworthy decimal expansions. Near a boundary
where a later interval implementation proves that a carry cascades through a
long repeated-9 or repeated-0 tail, the printed prefix may switch between those
equivalent tail descriptions; until then, uncertified cases keep precision `0`.

The REPL carries one perturbative tower state through ordinary syntax. When it
sees `10 ^ (-10 ^ 10)`, it records the exact tiny input `x = 10^-10000000000`;
each enclosing `10 ^ ...` advances the recurrence `f_{k+1}(x) = 10^f_k(x)`.
Displaying the value prints the sparse anchor plus the first-order correction.
Applying regular `Floor[...]` to that value returns the exact sparse integer
part with `precision: Infinity` and includes the omitted-tail bound that makes
the floor stable. This is intentionally the first narrow version of the
eventual general perturbation machinery, not a name-based shortcut for the
archived expression.

## MathOverflow Calculation

The archived expression is:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

Set:

```text
N = 10^10
x = 10^-N
c = ln(10)
```

Let `f_0(x) = x` and `f_{k+1}(x) = 10^(f_k(x))`. The expression is `f_4(x)`.
The anchors at `x = 0` are:

```text
f_0(0) = 0
f_1(0) = 1
f_2(0) = 10
f_3(0) = 10^10 = N
f_4(0) = 10^N
```

The first derivative recurrence is:

```text
f'_{k+1}(0) = ln(10) * 10^(f_k(0)) * f'_k(0)
```

Therefore:

```text
f'_4(0) * x = 10^11 * ln(10)^4
```

The implementation computes that coefficient with `Decimal` at the requested
precision, floors it, and returns the exact sparse integer:

```text
10^10000000000 + floor(10^11 * ln(10)^4)
```

The computed floor is:

```text
2811012357389
```

The second and higher terms are positive and sit at a scale far below one for
this `N`; the implementation reports a conservative decimal-exponent upper
bound for the omitted tail. The fractional part of the first-order correction
is far from the next integer, so the integer part is stable under the omitted
tail.

## Current Limits

This first Python implementation does not claim:

- rigorous interval arithmetic for all operations;
- exact symbolic equality beyond structural identity;
- full Clenshaw-Turner SLI add/sub;
- general floor/modulo for high-layer approximate tower values;
- arbitrary-base towers outside the documented base-10 path;
- certified decimal output for non-integer powers;
- a complete expression language; the REPL intentionally accepts only numeric
  literals, variables, assignment, `%` history references, parentheses,
  `N[...]`, `SetPrecision[...]`, `Floor[...]`, and `+`, `-`, `*`, `/`, `^`.

Those are deliberately left as follow-up seams. The code keeps the concerns
separate so each can grow without rewriting the whole package.

## Validation Strategy

The unit tests under `Engine/Nummy/src/alpha/tests/` cover:

- layer shifts through `pow10` and `log10`;
- high-layer dominance;
- sparse decimal integer structure;
- the MathOverflow calculation and its exact sparse integer suffix;
- layer-0 decimal arithmetic used by the calculator fast path;
- calculator parsing, assignment, default-zero variables, precision marks,
  configurable default precision, perturbative display for the archived
  MathOverflow expression, `Floor[...]`, power associativity, history
  references, and Tungsten-style REPL transcript behavior.

The validation target is behavior and representation correctness, not
benchmark speed.
