# Certified Exp10 And Log10 With Rational Intervals

Created (UTC): 2026-04-30T18:15:18Z

Repository HEAD: af8a60c1182cd728e87e6939274aac4639aa5e88

This document describes how to implement `exp10` and `log10` for the
base-10 level-interval arithmetic system without using existing floating-point,
decimal, MPFR, Arb, or transcendental-function libraries. It assumes only
integer arithmetic, exact rational arithmetic, interval arithmetic, and
outward rounding into the level endpoint representation described in
[`base10-level-interval-arithmetic-proposal.md`](base10-level-interval-arithmetic-proposal.md).

The central contract is containment:

```text
true mathematical result subset returned representable interval
```

Precision degradation is allowed only by outward widening. The algorithms below
prefer simple certifiable bounds over clever numerical performance.

## Scope

The algorithms cover:

- certified rational enclosures for `ln(q)`, `exp(q)`, `log10(q)`, and
  `10^q` for rational or rational-interval inputs;
- exact structural `exp10` and `log10` cases for level endpoints;
- conversion from rational enclosures to representable level endpoints;
- budget-driven precision degradation.

The algorithms deliberately avoid:

- binary floating-point;
- decimal floating-point;
- precomputed transcendental constants without proof intervals;
- machine `log`, `exp`, or `pow`;
- relying on a particular host language's rounding mode.

## Primitive Arithmetic

The implementation needs these exact primitives:

```text
Integer
  arbitrary-size signed integers

Rational
  numerator/denominator in lowest terms, denominator > 0

RationalInterval
  [lo, hi] with Rational endpoints and lo <= hi

LevelPoint
  sign * L_n(r)^orientation, 0 <= r < 1

LevelInterval
  [lowerPoint, upperPoint]
```

Every rational operation is exact until a budget check chooses to widen the
result.

Required interval operations:

```text
add, sub, mul, div
negate
positive reciprocal
integer power
min/max
contains zero
directed comparison
```

All interval operations must use exact rational endpoints. For example:

```text
[a, b] / [c, d]
```

is invalid if `[c, d]` contains zero; otherwise it multiplies by
`[1/d, 1/c]` after ordering the reciprocal endpoints.

## Budget Model

The coordinate budget is measured on exact rational endpoints:

```text
bitLength(abs(numerator)) <= CoordinateBitLimit
bitLength(denominator) <= CoordinateBitLimit
```

A first useful value is:

```text
CoordinateBitLimit = 10000
```

Internal working intervals may temporarily exceed this limit while proving a
result. Public level endpoints must not. A finalization step widens coordinate
intervals outward:

```text
fitBudgetLower(q) <= q <= fitBudgetUpper(q)
```

One simple directed fitting method is dyadic rounding:

```text
floorToDyadic(q, k) = floor(q * 2^k) / 2^k
ceilToDyadic(q, k)  = ceil(q * 2^k) / 2^k
```

Choose the largest `k` whose dyadic numerator and denominator fit the budget.
If the input rational already fits, keep it exactly.

Budget fitting must be monotone:

```text
if a <= b:
  fitLower(a) <= fitLower(b)
  fitUpper(a) <= fitUpper(b)
```

This avoids endpoint inversions during interval construction.

## Constants As Certified Intervals

`log10` and `exp10` can be implemented through natural `ln` and `exp`:

```text
log10(x) = ln(x) / ln(10)
10^x     = exp(x * ln(10))
```

This does not make the representation natural-log based. `ln` and `exp` are
only internal certified subroutines.

The constant `ln(10)` is not stored as an exact value. It is computed on demand
as a rational interval:

```text
ln10Interval(targetError) -> RationalInterval containing ln(10)
```

The interval must be narrow enough for the caller's requested proof. If a later
operation needs more certainty, recompute or refine it.

## Certified Logarithm Core

The basic identity is:

```text
ln(x) = 2 * atanh((x - 1) / (x + 1))
      = 2 * sum_{j=0..infinity} z^(2j + 1) / (2j + 1)

z = (x - 1) / (x + 1)
```

For `x > 0`, `abs(z) < 1`. The series has rational terms when `x` is rational.

After summing `N` terms, the absolute tail is bounded by:

```text
tail <= 2 * abs(z)^(2N + 1) / ((2N + 1) * (1 - z^2))
```

where the implemented partial sum is:

```text
partial_N = 2 * sum_{j=0..N-1} z^(2j + 1) / (2j + 1)
```

Therefore:

```text
ln(x) in [partial_N - tail, partial_N + tail]
```

### Range Reduction For ln

The atanh series is fastest when `x` is near `1`. Use powers of two for range
reduction because they are exact rationals:

```text
x = 2^k * u
ln(x) = k * ln(2) + ln(u)
```

Choose integer `k` such that:

```text
1/2 <= u <= 2
```

Then:

```text
abs((u - 1) / (u + 1)) <= 1/3
```

which gives rapid convergence and a simple tail bound.

`ln(2)` itself is computed by the same atanh series:

```text
ln(2) = 2 * atanh(1/3)
```

`ln(10)` can be computed more efficiently as:

```text
ln(10) = 3 * ln(2) + ln(5/4)
ln(5/4) = 2 * atanh(1/9)
```

This avoids the slower direct atanh argument `9/11`.

### Logarithm Of A Rational Interval

For a positive rational interval `[a, b]`:

```text
ln([a, b]) = [ln(a), ln(b)]
```

because `ln` is monotone. Compute a lower enclosure for `ln(a)` and an upper
enclosure for `ln(b)`:

```text
lnLower(a, epsilon)
lnUpper(b, epsilon)
```

The exact error allocation can be simple:

```text
epsilon per endpoint = callerTolerance / 4
```

If the tolerance is not known in advance, iterate:

```text
N = initialTermCount
repeat:
  compute interval
  if interval is narrow enough for downstream rounding:
    return interval
  N = 2 * N
```

The algorithm is terminating for finite positive rational inputs because the
atanh tail shrinks geometrically after range reduction.

## Certified Exponential Core

For bounded rational input `y`, compute `exp(y)` by range reduction and Taylor
series.

Use:

```text
y = k * ln(2) + r
exp(y) = 2^k * exp(r)
```

where `r` is forced into a small interval, for example:

```text
-ln(2)/2 <= r <= ln(2)/2
```

Because `ln(2)` is known only as an interval, choose `k` conservatively. One
robust method is:

1. Maintain a certified interval for `ln(2)`.
2. Compute a rational interval for `y / ln(2)`.
3. Pick any integer `k` that is certainly within one unit of the true quotient.
4. Compute:

```text
r = y - k * ln(2)
```

as a rational interval.

If the resulting `r` is not inside the desired small range, refine `ln(2)` and
retry.

### Taylor Series For exp

For `r` in a small interval with `abs(r) <= 1/2`:

```text
exp(r) = sum_{i=0..infinity} r^i / i!
```

For a point rational `r`, after summing terms `0..N`, a simple absolute tail
bound is:

```text
tail <= 2 * abs(r)^(N + 1) / (N + 1)!
```

because `exp(abs(r)) <= exp(1/2) < 2`.

For an interval `r = [lo, hi]`, use monotonicity:

```text
exp([lo, hi]) = [exp(lo), exp(hi)]
```

Compute the lower endpoint with a lower enclosure of `exp(lo)` and the upper
endpoint with an upper enclosure of `exp(hi)`.

For negative `lo`, the Taylor partial sum is alternating only in sign, but the
tail bound above remains an absolute bound. It is valid to compute a rational
partial sum and subtract/add the absolute tail.

### Avoiding Huge Rational Outputs

The exponential core should not try to return a giant rational interval when
the result is naturally a level endpoint.

If `y` is large enough that `exp(y)` cannot fit as a level-zero rational within
the coordinate budget, immediately switch to endpoint enclosure:

```text
exp(y) = 10^(y / ln(10))
```

Then enclose `y / ln(10)` as a level coordinate and return a level-1 or higher
endpoint interval. This is the first major precision-degradation point.

## Certified log10

`log10(x)` for positive rational or rational-interval input is:

```text
log10(x) = ln(x) / ln(10)
```

The denominator interval for `ln(10)` is strictly positive, so interval division
is valid.

Algorithm:

```text
log10RationalInterval([a, b], target):
  require 0 < a <= b
  repeat:
    lnX  = lnInterval([a, b], workingTarget)
    ln10 = ln10Interval(workingTarget)
    q    = lnX / ln10
    if q is narrow enough for target:
      return q
    refine workingTarget
```

The phrase "narrow enough" depends on the caller:

- for direct display, it means enough decimal digits;
- for endpoint construction, it means enough to choose outward-rounded
  coordinate endpoints;
- for comparison, it means the interval lies entirely on one side of the
  comparison target.

### Exact log10 Shortcuts

Before using `ln`, check exact structural cases:

```text
log10(L_(n+1)(r))      = L_n(r)
log10(L_(n+1)(r)^-1)   = -L_n(r)
```

For level-zero rationals, exact powers of ten can also be recognized:

```text
log10(1)       = 0
log10(10)      = 1
log10(1/10)    = -1
log10(10^k)    = k
log10(10^-k)   = -k
```

However, because canonical level coordinates require `0 <= r < 1`, the result
integer `k` may itself need endpoint normalization. For example, `k = 100` is a
level-zero rational value and may be exactly representable as a reciprocal of
`1/100` or as a tower boundary, according to the endpoint canonicalization
rules.

If no exact shortcut applies, return an interval.

## Certified exp10

`exp10(x)` is:

```text
exp10(x) = exp(x * ln(10))
```

but exact structural cases should be handled first.

### Exact exp10 Shortcuts

For exact nonnegative non-reciprocal level points:

```text
exp10(L_n(r)) = L_(n+1)(r)
```

This is exact and does not require transcendental computation.

For exact negative values:

```text
exp10(-L_n(r)) = L_(n+1)(r)^-1
```

when `L_n(r)` is nonnegative and non-reciprocal. This is also exact.

For level-zero rational `r` with `0 <= r < 1`:

```text
exp10(r) = L_1(r)
```

which is just the same rule with `n = 0`.

For positive reciprocal endpoints such as `L_n(r)^-1`, the result:

```text
10^(1 / L_n(r))
```

is generally not an exact endpoint in this representation. It must be enclosed
unless it simplifies to a recognized exact case.

### exp10 Of An Interval

Because `exp10` is monotone:

```text
exp10([a, b]) = [exp10(a), exp10(b)]
```

Compute a lower enclosure for `exp10(a)` and an upper enclosure for `exp10(b)`.
If an endpoint is an exact structural case, use it exactly. Otherwise:

1. Compute `y = endpoint * ln(10)` as a rational interval.
2. Compute `exp(y)` with certified range reduction and Taylor bounds.
3. Convert the resulting positive rational interval to level endpoints.
4. Fit the coordinate budget by outward rounding.

For very large positive inputs, do not materialize `exp(y)` as a rational.
Instead construct a level endpoint by locating:

```text
log10(exp10(x)) = x
```

So the result endpoint is directly the level representation of `x` shifted by
one level when `x` is already an exact nonnegative coordinate, or a rounded
level-coordinate interval when `x` is inexact.

## Converting Rational Intervals To Level Endpoints

Many subroutines produce a positive rational interval `[a, b]`. To return it as
a `LevelInterval`, convert each endpoint directionally.

For a positive lower endpoint:

```text
pointLower(a):
  find representable point p such that p <= a
```

For a positive upper endpoint:

```text
pointUpper(b):
  find representable point p such that b <= p
```

A practical algorithm:

1. If the rational fits level zero, return it exactly.
2. If the rational is greater than one and its reciprocal fits level zero,
   return the reciprocal representation exactly.
3. Otherwise, compute a certified interval for `log10(value)`.
4. Convert that logarithmic coordinate to a level endpoint recursively.
5. Apply outward coordinate rounding and canonicalization.

The recursion terminates for finite values because repeated `log10` reductions
eventually bring ordinary finite magnitudes into a level-zero-sized coordinate,
or the algorithm widens to a coarser endpoint first.

For values below one, use the reciprocal:

```text
pointLower(x), 0 < x < 1
  equals reciprocal of pointUpper(1/x)

pointUpper(x), 0 < x < 1
  equals reciprocal of pointLower(1/x)
```

This preserves directionality.

## Precision Degradation In exp10/log10

Precision degradation happens in five places.

### 1. Series Truncation

`ln` and `exp` series are truncated after finitely many terms. The truncation
tail is explicitly added to the result interval:

```text
computed = partial +/- tail
```

This is not optional rounding error; it is the proof envelope.

### 2. Constant Approximation

`ln(2)` and `ln(10)` are rational intervals. Any computation using them carries
their width forward. If their width dominates the final result, refine the
constant interval. If refinement would exceed working limits, return the wider
certified result.

### 3. Range-Reduction Ambiguity

When selecting an integer reduction parameter, such as `k` in:

```text
y = k ln(2) + r
```

the quotient interval may straddle two integers. The implementation may either
refine constants until `k` is determined, or choose either neighboring `k` and
accept a wider interval for `r`. The latter is valid if the Taylor tail bound
still applies.

### 4. Coordinate Budget Fitting

After an exact or certified coordinate interval is found, rational endpoints may
exceed the bit budget. Outward dyadic fitting widens the coordinate:

```text
[lo, hi] -> [floorToDyadic(lo, k), ceilToDyadic(hi, k)]
```

If the rounded coordinate reaches `1`, use the boundary normalization:

```text
L_n(1) = L_(n+1)(0)
```

If the rounded coordinate reaches below `0`, use the lower level boundary or a
coarser interval that preserves containment.

### 5. Endpoint Family Mismatch

Some exact values are not exact endpoints. For example:

```text
10^(8/5)
```

cannot be stored as `L_1(8/5)` because coordinates require `0 <= r < 1`, and
its normalized higher-level coordinate is not rational. The result must be an
interval even though the mathematical value is exact.

## Directed Algorithms

The implementation should provide directed variants rather than compute a
center and then guess an error:

```text
lnLower(x)
lnUpper(x)
expLower(x)
expUpper(x)
log10Lower(x)
log10Upper(x)
exp10Lower(x)
exp10Upper(x)
```

Internally these can share interval routines, but directed APIs make endpoint
construction less error-prone.

Example for `log10Lower(x)`:

```text
log10Lower(x):
  if exact structural lower shortcut applies:
    return exact shortcut

  repeat:
    lnX  = lnInterval(x, precision)
    ln10 = ln10Interval(precision)
    q    = lnX / ln10
    lower = q.lo
    candidate = fitBudgetLower(lower)
    if candidate is proven <= true log10(x):
      return candidate
    precision = 2 * precision
```

The final proof condition is usually automatic because `q.lo <= true q` and
`fitBudgetLower(q.lo) <= q.lo`.

## Comparison-Driven Refinement

Many callers do not need a final numeric interval. They only need to decide a
comparison, for example:

```text
log10(x) < r
```

Use interval refinement:

```text
repeat:
  q = log10Interval(x, precision)
  if q.hi < r:
    return True
  if q.lo >= r:
    return False
  precision = 2 * precision
```

If the comparison target is exactly equal to the transcendental value, the loop
would not terminate. For the important exact cases, structural recognition
should catch equality first. Otherwise, the implementation can impose a
refinement cap and return an enclosing interval instead of a boolean.

## Pseudocode

The following pseudocode sketches the exact-rational implementation style.

```text
lnAtanhInterval(x, terms):
  require x > 0
  z = (x - 1) / (x + 1)
  s = 0
  power = z
  for j in 0 .. terms - 1:
    s += power / (2*j + 1)
    power *= z*z
  partial = 2*s
  tail = 2 * abs(z)^(2*terms + 1) /
         ((2*terms + 1) * (1 - z*z))
  return [partial - tail, partial + tail]
```

```text
lnRationalInterval(x, targetWidth):
  require x > 0
  k = chooseIntegerSoThat(1/2 <= x / 2^k <= 2)
  u = x / 2^k
  repeat:
    ln2 = lnAtanhInterval(2, terms)
    lnu = lnAtanhInterval(u, terms)
    result = k * ln2 + lnu
    if width(result) <= targetWidth:
      return result
    terms *= 2
```

```text
expSmallInterval(r, terms):
  require abs(r) <= 1/2
  s = 0
  term = 1
  for i in 0 .. terms:
    if i > 0:
      term *= r / i
    s += term
  tail = 2 * abs(r)^(terms + 1) / factorial(terms + 1)
  return [s - tail, s + tail]
```

```text
expRationalInterval(y, targetWidth):
  repeat:
    ln2 = ln2Interval(terms)
    kInterval = y / ln2
    k = chooseNearbyInteger(kInterval)
    r = y - k * ln2
    if r subset [-1/2, 1/2]:
      e = expSmallInterval(r, terms)
      result = 2^k * e
      if width(result) <= targetWidth:
        return result
    terms *= 2
```

For interval inputs, call the point version on the lower and upper endpoints
using monotonicity, then combine directed lower and upper bounds.

## Testing Strategy

The implementation should be tested with containment and monotonicity, not only
with printed decimal examples.

Essential properties:

- `log10(exp10(x))` contains `x` for representative intervals;
- `exp10(log10(x))` contains `x` for positive representative intervals;
- `log10` is monotone;
- `exp10` is monotone;
- directed lower endpoints are never above independently refined results;
- directed upper endpoints are never below independently refined results;
- widening the coordinate budget never makes results less precise;
- reducing the coordinate budget never violates containment.

Important examples:

```text
log10(1) = 0
log10(10) = 1
log10(1/10) = -1
exp10(0) = 1
exp10(1) = 10
exp10(-1) = 1/10
log10(2) is inexact
exp10(1/2) = L_1(1/2)
exp10(8/5) is inexact under the endpoint-coordinate rule
```

The last example is intentional: `10^(8/5)` is mathematically exact as a real
expression but is not an exact endpoint when level coordinates must be rational
in `[0, 1)`.

## Conclusion

Certified `exp10` and `log10` can be implemented from scratch using only exact
integer and rational arithmetic. The reliable route is:

1. compute `ln` with range reduction plus the atanh series;
2. compute `exp` with range reduction plus Taylor series;
3. compute `ln(10)` as a certified interval;
4. define `log10(x) = ln(x) / ln(10)`;
5. define `exp10(x) = exp(x * ln(10))`;
6. handle exact level-structural shortcuts before invoking transcendental
   series;
7. outward-round final coordinates into the rational budget.

The core discipline is simple but unforgiving: every approximation is an
interval, every final coordinate is rounded outward, and every precision loss is
represented as widening rather than as an untracked decimal rounding artifact.
