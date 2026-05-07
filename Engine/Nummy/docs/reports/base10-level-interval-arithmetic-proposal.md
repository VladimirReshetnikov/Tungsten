# Base-10 Level-Interval Arithmetic Proposal

Created (UTC): 2026-04-30T17:59:16Z

Repository HEAD: f405cf4f6567d91ea93f04a3e4a506f8706cd8cb

This document proposes an isolated arithmetic system for finite real numbers
whose exact endpoints are represented by base-10 level points. It deliberately
does not specify Tungie syntax, parsing, formatting, REPL behavior, or
compatibility with the current Python implementation. The goal is to describe a
base-independent-enough arithmetic kernel whose internal magnitude scale is
base 10 because that is the desired visualization basis.

## Summary

The system represents every computed value as a closed real interval:

```text
Interval[lower, upper]
```

Each endpoint is an exact level point of the form:

```text
sign * L_n(r)^orientation
```

where:

- `sign` is `+1` or `-1`;
- `orientation` is `+1` or `-1`, with `-1` meaning reciprocal;
- `n` is a non-negative integer;
- `r` is a reduced rational coordinate with `0 <= r < 1`;
- `L_0(r) = r`;
- `L_(n+1)(r) = 10^(L_n(r))`.

The zero value is represented uniformly as:

```text
+ L_0(0)^+1
```

Intervals with equal endpoints are exact values. Arithmetic on exact values is
allowed to produce inexact intervals when the exact mathematical result is not
representable by the endpoint family, or when representing it exactly would
exceed the rational-coordinate budget.

## Representation Budget

The coordinate rational `r = p/q` must fit within a fixed representation
budget. A useful first budget is:

```text
bitLength(abs(p)) <= 10000
bitLength(abs(q)) <= 10000
```

The integer level `n` may grow as high as memory allows. The budget applies to
coordinates, not to the level.

Whenever an operation would produce a coordinate outside the budget, the result
must be widened outward until both endpoints fit. This widening is the only
permitted precision degradation. It must preserve containment:

```text
exact mathematical result subset widened representable interval
```

The system should use a deterministic outward rounding policy. A simple policy
is dyadic coordinate rounding:

```text
lowerCoordinate -> floor(lowerCoordinate * 2^k) / 2^k
upperCoordinate -> ceil(upperCoordinate * 2^k) / 2^k
```

where `k` is chosen so that the numerator and denominator stay within the bit
budget. Dyadic rationals are still ordinary rationals; the choice is an
implementation convenience, not a semantic base for the arithmetic.

## Canonical Endpoint Form

The endpoint form is intentionally not a fully unique mathematical normal form
for all real constants. It should still have enough canonical rules to keep
common comparisons and equality checks stable.

Required endpoint invariants:

- `r` is reduced and satisfies `0 <= r < 1`;
- zero has positive sign and non-reciprocal orientation;
- reciprocal zero is invalid;
- `L_1(0)^-1`, which is reciprocal one, canonicalizes to `L_1(0)^+1`;
- negative zero canonicalizes to zero.

Recommended boundary preference:

- `1` is represented as `L_1(0)`;
- `10` is represented as `L_2(0)`;
- `10^10` is represented as `L_3(0)`;
- in general, the tower boundary `L_n(0)` is preferred for exact values of that
  shape;
- reciprocals of these boundary values use the same level point with reciprocal
  orientation, except that reciprocal one canonicalizes to one.

Level-zero reciprocals remain necessary. For example:

```text
2      = L_0(1/2)^-1
100    = L_0(1/100)^-1
3/2    = L_0(2/3)^-1
1/100  = L_0(1/100)^+1
```

The coordinate restriction `0 <= r < 1` means many exact values that would be
representable as `10^r` with `r >= 1` are not exact endpoints. For example,
`10^(8/5)` is not a canonical exact endpoint: level 1 cannot store coordinate
`8/5`, and the level 2 coordinate `log10(8/5)` is not rational. An operation
that produces this value must return an inexact interval unless a larger exact
expression language is added later.

## Ordering Endpoints

Endpoint comparison must be exact or certified.

The high-level order is:

```text
negative values < zero < positive values
```

For positive magnitudes, comparison can often be decided structurally:

- same `n` and same orientation: compare coordinates, reversing order for
  reciprocal orientation;
- non-reciprocal positive levels partition many common ranges:
  - `n = 0` covers `[0, 1)`;
  - `n = 1` covers `[1, 10)`;
  - `n = 2` covers `[10, 10^10)`;
  - `n = 3` covers `[10^10, 10^(10^10))`;
- reciprocal endpoints invert the positive magnitude order.

Some comparisons require certified transcendental comparison. For example,
comparing `L_0(1/100)^-1` with `L_2(r)` means comparing rational `100` with
`10^(10^r)`. The implementation can decide this by applying monotone `log10`
reductions and using certified interval enclosures until the order is known.

If exact comparison cannot be decided within the current budget, the system
should widen one or both values outward into a representable interval whose
ordering is decidable.

## Interval Invariants

An interval is valid when:

```text
lower <= upper
```

Special cases are ordinary intervals:

```text
exact zero:        [0, 0]
exact value x:     [x, x]
positive interval: [a, b] with 0 < a <= b
negative interval: [a, b] with a <= b < 0
zero-crossing:     [a, b] with a <= 0 <= b
```

There is no separate `AroundZero` representation. Intervals that include zero
are represented by endpoints on opposite sides of zero, or by zero as one
endpoint.

## Exactness Policy

The system distinguishes three cases:

1. The mathematical result is exactly representable and within budget.
   Return an exact interval with equal endpoints.
2. The mathematical result is exact but not representable by the endpoint
   family, or not representable within budget.
   Return the narrowest practical outward-rounded interval.
3. The mathematical result is not a finite real under the operation's domain
   rules.
   Return the system's undefined/error result, not an interval.

This means exact inputs can produce inexact outputs. That is not a bug; it is
the cost of using a compact endpoint family rather than an arbitrary symbolic
expression language.

Examples:

```text
1/2 + 1/3 -> exact 5/6, if the rational fits the budget

L_1(2/5) * L_1(3/10)
  = 10^(2/5) * 10^(3/10)
  = 10^(7/10)
  -> exact L_1(7/10)

L_1(4/5)^2
  = 10^(8/5)
  -> inexact interval, because coordinate 8/5 is outside [0, 1)
     and the normalized level-2 coordinate log10(8/5) is not rational
```

## Core Helper Operations

The arithmetic layer should be built around certified helpers over endpoint
expressions:

```text
negatePoint(p) -> exact point
reciprocalPoint(p) -> exact point or Undefined for zero
comparePoint(a, b) -> exact/certified ordering
encloseLower(expr) -> representable endpoint <= expr
encloseUpper(expr) -> representable endpoint >= expr
encloseExpr(expr) -> Interval[encloseLower(expr), encloseUpper(expr)]
fitBudget(interval) -> outward-rounded interval satisfying the budget
```

The helpers may internally use arbitrary-precision integer/rational arithmetic,
certified rational intervals for transcendental constants, and repeated
monotone reductions. The public invariant is containment, not a particular
algorithm.

## Addition And Subtraction

For intervals:

```text
[a, b] + [c, d] = [a + c, b + d]
[a, b] - [c, d] = [a - d, b - c]
```

The endpoint sums and differences are then enclosed outward:

```text
lower = encloseLower(a + c)
upper = encloseUpper(b + d)
```

Subtraction is addition after negating the second interval:

```text
-[c, d] = [-d, -c]
```

Exactness cases:

- level-0 rational plus level-0 rational is exact when the resulting rational
  fits the budget;
- adding exact opposites returns exact zero;
- adding same-scale level-1 powers may be exact only in special cases;
- most sums involving higher-level values become inexact intervals.

For positive operands, the enclosure should use a log-sum formula when direct
endpoint arithmetic is not closed:

```text
log10(x + y) = M + log10(1 + 10^(m - M))
M = max(log10(x), log10(y))
m = min(log10(x), log10(y))
```

If `M - m` is large, dominance allows the smaller addend to become a certified
outward widening of the larger term. If `M` and `m` are close, the helper must
evaluate `log10(1 + 10^(m - M))` with certified bounds.

Cancellation is handled naturally by interval endpoints. If `x - y` cannot
certify a sign, the result interval crosses zero.

## Multiplication

For intervals:

```text
[a, b] * [c, d] =
  [min(a*c, a*d, b*c, b*d), max(a*c, a*d, b*c, b*d)]
```

Each endpoint product is enclosed outward. Products of exact points can often
be handled in log space:

```text
abs(x * y) = 10^(log10(abs(x)) + log10(abs(y)))
sign(x * y) = sign(x) * sign(y)
```

Exactness cases:

- level-0 rational times level-0 rational is exact when the resulting rational
  fits the budget;
- `L_1(a) * L_1(b)` is exact when `a + b` can be normalized to a representable
  exact endpoint;
- many higher-level products become inexact because
  `L_2(a) * L_2(b) = 10^(10^a + 10^b)`, and the coordinate sum is generally
  not an exact endpoint.

Budget pressure example:

```text
largeRational * largeRational
```

may mathematically be an exact rational but exceed the bit budget. In that
case, the exact rational is not stored. The product is enclosed by
representable endpoints, usually by locating its logarithmic level and
outward-rounding the coordinate.

## Division

Division is multiplication by a reciprocal:

```text
[a, b] / [c, d] = [a, b] * reciprocal([c, d])
```

Domain rule:

```text
if 0 in [c, d], division is Undefined
```

For an interval not containing zero:

```text
reciprocal([c, d]) = [1/d, 1/c]
```

Endpoint reciprocals are exact by toggling the orientation flag and then
canonicalizing. The only forbidden endpoint reciprocal is zero.

## Integer Powers

Integer powers should be special-cased before general power.

For exact point bases:

```text
(sign * magnitude)^k
```

has exact sign behavior:

- negative base and odd `k` stays negative;
- negative base and even `k` becomes positive;
- `k = 0` returns exact one;
- zero to positive `k` returns exact zero;
- zero to negative `k` is Undefined.

Magnitude can be computed through:

```text
log10(abs(x^k)) = k * log10(abs(x))
```

This is exact only when the resulting point is representable. Otherwise it is
enclosed outward.

For interval bases:

- odd positive powers are monotone over the whole real line;
- even positive powers need special handling if the interval crosses zero;
- negative powers require the base interval to exclude zero.

Examples:

```text
[a, b]^3 = [a^3, b^3]

[a, b]^2 =
  [0, max(a^2, b^2)] if 0 in [a, b]
  [min(a^2, b^2), max(a^2, b^2)] otherwise
```

The endpoints are still outward-rounded into representable level points.

## General Power

General power is defined primarily through:

```text
x^y = 10^(y * log10(x))
```

Domain rules:

- if `x` is strictly positive, this formula applies;
- if `x` contains zero and `y` can be nonpositive, the result is Undefined;
- if `x` is exactly zero and `y` is strictly positive, the result is zero;
- if `x` is negative, only exact integer exponents are supported by the real
  arithmetic layer;
- negative base with a non-integer exponent is Undefined.

For positive interval base and interval exponent:

1. Compute `log10(x)` by applying monotone `log10` to the base endpoints.
2. Multiply the resulting interval by `y`.
3. Apply `exp10` to the product interval.
4. Fit the result to the endpoint budget.

Exactness cases:

- `10^r` with exact rational `0 <= r < 1` returns exact `L_1(r)`;
- `10^L_n(r)` for exact nonnegative endpoint `L_n(r)` returns exact
  `L_(n+1)(r)`;
- `x^k` with exact integer `k` uses the integer-power path;
- most positive non-integer powers become inexact.

The coordinate restriction `0 <= r < 1` makes some mathematically exact powers
inexact. This is deliberate. The representation is a compact interval
arithmetic system, not a symbolic algebra system.

## Exp10 And Log10

The primitive monotone functions are `exp10` and `log10`.

For exact points:

```text
exp10(L_n(r)) = L_(n+1)(r)
```

when the argument is nonnegative and non-reciprocal. For negative arguments,
`exp10(x)` is a positive value below one and is represented through reciprocal
or level-zero rational enclosure after certified evaluation.

For positive exact points:

```text
log10(L_n(r)) = L_(n-1)(r), for n > 0 and non-reciprocal orientation
log10(L_n(r)^-1) = -L_(n-1)(r), for n > 0
```

For level-zero rational endpoints, `log10(r)` is usually not exact. It is exact
only for recognized powers of ten under the canonical boundary rules. Otherwise
it is enclosed by a rational-coordinate interval.

For intervals, use monotonicity:

```text
exp10([a, b]) = [exp10(a), exp10(b)]
log10([a, b]) = [log10(a), log10(b)] if a > 0
```

## Precision And Accuracy

Precision and accuracy are derived from intervals; they are not stored as
independent truth.

For intervals excluding zero, ordinary value-space relative precision can be
computed from the relative enclosure width:

```text
precision = -log10((upper - lower) / representativeMagnitude)
```

A log-space equivalent is often better for large magnitudes. For a positive
interval:

```text
delta = log10(upper) - log10(lower)
relativeWidth is approximately ln(10) * delta for small delta
precision is approximately -log10(delta) - log10(ln(10))
```

For intervals containing zero, relative precision is not meaningful as a count
of certified leading digits. The system should report zero or negative
precision according to the chosen presentation convention. Absolute accuracy is
still meaningful and can be derived from the largest endpoint magnitude or from
the interval radius.

Budget degradation widens intervals, so it can only reduce or preserve derived
precision. It must never increase certified precision.

## Precision Degradation

Precision degradation is required in these situations:

- a coordinate rational endpoint exceeds the bit budget;
- exact rational arithmetic produces a numerator or denominator outside the
  budget;
- an operation yields a value outside the endpoint family;
- deciding a comparison or domain condition requires an enclosure, not an exact
  point;
- a coordinate interval would leave the half-open range `0 <= r < 1`.

The degradation procedure is:

1. Choose a level and orientation that cover the mathematical result.
2. Compute a certified rational interval for the coordinate at that level.
3. If the coordinate interval lies partly outside `[0, 1)`, split or lift it to
   adjacent levels until the endpoint invariants hold.
4. Round coordinate endpoints outward to fit the bit budget.
5. Canonicalize endpoints.
6. Verify that the final interval still contains the mathematical result.

The procedure may choose a coarser but simpler interval when the narrowest
representable interval would be expensive to find. Correct containment is more
important than maximal precision.

## Suggested Implementation Layers

The implementation can be organized as:

```text
RationalBudget
  reduced rationals, bit-size checks, dyadic outward rounding

LevelPoint
  sign, level, orientation, coordinate, canonicalization, comparison

LevelInterval
  endpoint ordering, interval constructors, domain predicates

CertifiedFunctions
  exp10, log10, log1p10, addition dominance, comparison refinement

Arithmetic
  +, -, *, /, integer power, general power
```

The certified transcendental layer needs rational enclosures for:

- `log10(rational)`;
- `10^rational`;
- `log10(1 + 10^t)`;
- comparisons between rational values and level values.

Those can be built using range reduction and rational series bounds. The
proposal does not require a particular algorithm, only outward-rounded
containment.

## Open Design Questions

- Should level-zero exact rationals always be preserved when they fit, even if
  a tower-boundary representation also exists?
- How aggressively should the system search for the tightest representable
  interval before accepting a coarser enclosure?
- Should exact algebraic special cases such as odd rational roots be supported,
  or should non-integer powers always go through interval `log10`/`exp10`?
- Should a future exact expression layer sit above this interval system for
  values like `10^(8/5)`, or is inexact enclosure the intended behavior?
- What user-visible convention should report precision for intervals that
  contain zero?

## Conclusion

Uniform endpoint intervals over canonical base-10 level points give the system
a clean treatment of zero, huge magnitudes, tiny magnitudes, cancellation, and
base-10 tower visualization. The tradeoff is that exactness is intentionally
limited: exact inputs can become inexact whenever the exact result is outside
the endpoint family or outside the rational-coordinate budget.

The central implementation challenge is therefore not ordinary rational
arithmetic. It is certified outward enclosure: every arithmetic operator must
either produce an exact representable endpoint result or widen the result into
a representable interval that honestly contains the mathematical value.
