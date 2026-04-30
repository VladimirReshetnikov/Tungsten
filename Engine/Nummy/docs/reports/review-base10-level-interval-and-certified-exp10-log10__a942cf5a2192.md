# Review: Base-10 Level-Interval Arithmetic and Certified Exp10/Log10 Proposals

Created (UTC): 2026-04-30T18:49:11Z

Repository HEAD: 57b27c74c850823d3dbaff361dab77ad915bce06

This document reviews two recent design proposals:

- [`base10-level-interval-arithmetic-proposal.md`](base10-level-interval-arithmetic-proposal.md) (commit `af8a60c1`)
- [`certified-exp10-log10-with-rational-intervals.md`](certified-exp10-log10-with-rational-intervals.md) (commit `57b27c74`)

It evaluates them against the trajectory of recent Tungie work
(`af70434b4` interval-precision model, `91d47c0e7` arbitrary-precision
metadata, `a44fbacb3` / `c576f1315` scale-literal binding fixes,
`ad94fbbab` / `f405cf4f6` log-space scale-power precision) and against the
contract documented in
[`tungie-interval-precision-spec.md`](tungie-interval-precision-spec.md).

The review is organized as:

1. What each proposal actually proposes.
2. Strengths.
3. Friction points and ambiguities.
4. Concrete amendments suggested for both documents.
5. Strategic recommendation.

## Summary Of Each Proposal

### Proposal 1 — Base-10 level-interval arithmetic kernel

The first document describes a self-contained arithmetic system over closed
real intervals `Interval[lower, upper]`, where each endpoint is a *level
point*:

```text
sign * L_n(r)^orientation
```

with `L_0(r) = r`, `L_(n+1)(r) = 10^L_n(r)`, `r ∈ [0, 1)` reduced rational,
`n` non-negative integer, `orientation ∈ {+1, -1}` (where `-1` means
reciprocal). Endpoint coordinates carry a bit budget (suggested 10 000 bits
each on numerator and denominator); operations that overrun the budget
must widen outward into a representable interval.

The kernel is deliberately base-10 because that matches the desired
visualization basis. It explicitly does not specify Tungie syntax,
parsing, formatting, REPL behavior, or compatibility with the current
Python implementation.

### Proposal 2 — Certified exp10 / log10 implementation spec

The second document supplies the missing transcendental subroutines for the
first. It commits to:

- `log10(x) = ln(x) / ln(10)` and `10^x = exp(x * ln(10))`, where `ln`/`exp`
  are internal-only.
- `ln` via `2 * atanh((x − 1) / (x + 1))` Taylor series, with range reduction
  `x = 2^k * u`, `1/2 ≤ u ≤ 2`.
- `ln(10) = 3 * ln(2) + ln(5/4)`, `ln(5/4) = 2 * atanh(1/9)`.
- `exp` via Taylor series with `y = k * ln(2) + r`, `|r| ≤ 1/2`.
- Integer- and rational-only working data; no float, no Decimal, no MPFR,
  no `pow`/`exp`/`ln` from the host.
- Five named precision-degradation points (series truncation, constant
  approximation, range-reduction ambiguity, coordinate-budget fitting,
  endpoint-family mismatch).
- Directed APIs (`lnLower`, `expUpper`, etc.).

Together the two proposals describe a kernel that is (a) representationally
compact, (b) self-bootstrapping, and (c) honest about every approximation it
makes.

## Strengths

These are real and worth keeping.

### Containment honesty

The shift from a center-plus-log-radius value (today's `DecimalInterval`)
to an explicit `Interval[lower, upper]` over a canonical level family takes
the half-bookkeeping smell out. The current model leans on `Decimal.ln`,
`Decimal.exp`, and `Decimal` rounding-mode choices that are not
correctly-directed in general. The level-interval kernel makes every
approximation an outward-rounded enclosure, with nothing implicit.

This also fixes a latent unsoundness in today's `_interval_exp` /
`_interval_log` (`evaluator.py:2508` / `evaluator.py:2529`): both compute
`(center ± radius).exp()` / `.ln()` using the local Decimal context, then
take a max-difference, with no proof the Decimal transcendentals are
outward-rounded. In practice this works because Decimal's transcendentals
target half-even at the requested precision and the radius is much wider
than one ulp, but it is not a *proof*. The new spec replaces it with a
proof.

### Self-bootstrapping log/exp

Avoiding `Decimal.ln()` and `Decimal.exp()` means there is no opaque
rounding-mode dependence. The atanh-with-range-reduction route is
textbook (it is essentially what mpmath's `mp.ln` does at low precision,
modulo binary splitting). The choice
`ln(10) = 3 * ln(2) + ln(5/4)` with `ln(5/4) = 2 * atanh(1/9)` is much
better than direct `2 * atanh(9/11)` and is justified in one line.

### Endpoint family hugs base 10

Tungie already uses `Pow10Tower[h, top]` and `ScientificScale` because the
target audience reads scale values in base-10 towers. `L_n(r)` is the same
shape, generalized by allowing the top coordinate `r` to be a rational in
`[0, 1)` rather than only `1`. The level-interval kernel is therefore a
natural extension of the existing display vocabulary, not a new one.

### Five named precision-degradation points

The exp10/log10 doc enumerates exactly where width can grow:
series truncation, constant approximation, range-reduction ambiguity,
budget fitting, endpoint-family mismatch. This is a level of explicitness
the current evaluator does not have — today, widening happens inside
`_log10_relative_log_radius_correction` and `_log10_uncertainty_accuracy`
(`evaluator.py:1296`–`1325`) and is hard to audit. Naming the five places
in the spec is a real architectural win.

### Companion structure

Splitting "what" (the interval kernel) from "how" (the transcendental
implementation) into two docs is good discipline. The first stands on its
own as a representation contract; the second proves the first is
implementable without library magic.

## Friction Points And Ambiguities

These are the places where the proposals leave choices to be made later
that will become hard to undo if punted.

### F1. Scope vs. existing Tungie is silent

The first doc says:

> It deliberately does not specify Tungie syntax, parsing, formatting,
> REPL behavior, or compatibility with the current Python implementation.

That is intellectually honest, but it leaves the reader unable to answer:
is this kernel intended to *replace* `DecimalInterval` /
`ScientificScale` / `Pow10Tower` in Tungie, sit *alongside* them as a
parallel certified backend, or live in a *future* sibling project that
Tungie may eventually consume? Recent commits
(`af70434b4`, `91d47c0e7`, `ad94fbbab`, `f405cf4f6`) have been hardening
the current center-plus-log-radius model. If the new proposal supersedes
that line of work, it should say so — and
[`tungie-interval-precision-spec.md`](tungie-interval-precision-spec.md)
should grow an "Implementation status" section pointing forward. If it
does not supersede, the new proposal should still say where it lives.

### F2. Multiple canonical forms per value

Several values can be written more than one way in the proposed system:

- `0.1 = L_0(1/10)^+1` (level-zero rational), or
- `0.1 = L_2(0)^-1` (reciprocal of `10`, since `L_2(0) = 10`).

The first doc lists "boundary preference" rules that prefer
`L_n(0)`-shaped values over level-zero rationals "for exact values of that
shape". That is a *selection* rule but not a *normalization* rule. Two
endpoints could be constructed by different code paths, end up in
different forms, and compare unequal even though they are mathematically
equal — unless `comparePoint` performs structural reductions. The spec
gestures at certified comparison but does not commit to a single canonical
form constructed at point-construction time.

### F3. Outward-rounding can promote a level (huge widening)

If a level-`n` upper endpoint with coordinate `1 − ε` is outward-rounded
because of the bit budget, and the rounded coordinate lands at exactly
`1`, the spec invokes `L_n(1) = L_(n+1)(0)`. That promotion is correct,
but the widening is not modest: from `10^L_n(1 − ε) ≈ 10^L_n(1)` to
`L_(n+1)(0)` is a power-tower step that can blow the interval up by
many orders of magnitude. A budget-driven outward rounding intended to
trim a coordinate by a handful of bits should not, even occasionally,
multiply the represented value by a power-tower factor.

The mitigation is straightforward but unstated: prefer to round outward
*strictly inside* `[0, 1)` at the current level, only promoting when the
mathematical result actually requires it (e.g., the operation produces a
value above the current level's range with no headroom). Today's spec
permits the dangerous round; the proposal should forbid it.

### F4. Interaction with negative-precision results in current Tungie

Today's Tungie produces, via the recent `f405cf4f6` log-space hardening:

```text
(1.*^^2)^(1.*^^2)  ->  1`-86.364097721838251*^^102
```

That is a value with *negative certified precision*: the relative width
of the certified interval exceeds the magnitude. The current display
shows a nominal mantissa and the negative-precision mark, which is
compact and informative.

In the new system, this same computation produces an
`Interval[lower, upper]` whose endpoints differ in log10 by ~86 — the
interval covers ~86 orders of magnitude. There is no `1`-86.36*^^102`
shortcut available unless the system *derives* a precision from
`(upper − lower)` and prints a midpoint with that mark. The proposal's
"Precision And Accuracy" section sketches such a derivation, but does
not commit to a formula compatible with today's Tungie display.

The new spec should include a precise mapping
`Interval[lower, upper] -> (center, precision)` that reproduces the
existing test-pinned strings, or document that those tests are expected
to change. Today the relevant tests are
`test_negative_precision_scale_power`
(`tests/test_tungie.py:384`–`402`) and
`test_very_large_scale_arithmetic` (`tests/test_tungie.py:158`–`196`).

### F5. Loss of exact-centered certified values

Today Tungie supports compact certified values with exact centers, e.g.:

```text
N[Sqrt[2], 10000000000000]
  -> SetPrecision[Power[2, Rational[1, 2]], 10000000000000]
```

The interval is never materialized as digits; the center is symbolic, the
precision is a metadata `Decimal`, and the value is exact-centered in the
sense of `_certified_interval_for_expr` (`evaluator.py:2158`). The
level-interval kernel has no place for symbolic centers — every value is a
pair of explicit endpoints. To preserve this in Tungie one would need a
companion "exact expression layer" sitting *above* the interval kernel,
which the proposal flags only as an open design question.

This is a real expressive loss if the level kernel directly replaces
`DecimalInterval`. The right move is probably: keep `Sqrt[2]` /
`Log[2]` / etc. symbolic at the Tungie layer, materialize endpoints
through the level kernel only when arithmetic forces it.

### F6. `0 ≤ r < 1` and negative coordinates

`0.9` has `log10(0.9) < 0`, so it cannot be `L_1(log10(0.9))` under the
nonnegative-coordinate rule. The doc handles this by storing it as
`L_0(0.9)^+1`. Correct, but the level-promotion logic in `log10` is then
asymmetric: `log10(L_1(r))` simply drops a level, while `log10(L_0(r))`
must produce a (negative) interval. The spec should call this out
explicitly so an implementer does not assume `log10` is purely structural.

### F7. Bit budget of 10 000 is illustrative, not normative

10 000 bits per numerator and 10 000 per denominator gives reduced
rationals up to ~10^3010. That is far larger than any of Tungie's existing
precision tests — the current `MAX_WORKING_PRECISION = 1000` (decimal
digits) and `MAX_COMPACT_DECIMAL_PRECISION = 1000`
(`evaluator.py:38`–`39`). Routine evaluation does not need anywhere near
10 000-bit coordinates.

The proposal says "A useful first budget is", which is the right framing,
but the doc reads as if 10 000 is the working number. Make explicit that
the budget is a configurable parameter analogous to `$Precision`, with a
much smaller routine default (say 256 or 512 bits) and an explicit
trade-off statement.

### F8. ln range reduction can be tighter

The doc reduces to `u ∈ [1/2, 2]`, giving `|z| ≤ 1/3` for the atanh
argument. Reducing instead to `u ∈ [1/√2, √2]` gives `|z| ≤ 0.172`, so
each pair of terms shrinks by `(0.172)^2 ≈ 0.0296` instead of
`(1/3)^2 = 0.111`. The choice of `k` only requires comparing `x^2` to a
power of two, which is still rational. About a 3× speedup per term, free.

### F9. Termination / cost are sketched but not proved

Several pseudocode loops use the pattern

```text
repeat:
  compute interval
  if narrow enough: return
  precision = 2 * precision
```

These terminate for finite rational inputs after range reduction, because
the truncation tail decays geometrically. The proof is a sentence; it
should be in the doc. Likewise, a one-paragraph cost estimate (e.g.,
"~`O(log(1/ε))` terms; each term has rational with `O(N log N)`-bit
denominator") would tell readers what they are signing up for.

### F10. Comparison-target equality is the only interesting deadlock

The doc notes that exact equality of a transcendental enclosure with a
rational target would prevent termination. By transcendence theorems the
only such cases are trivial (`log10(10^k) = k`), and structural recognition
catches them. Comparing two transcendental enclosures is similar: only
structural identity can prove equality; otherwise refinement separates
them. This is the right answer, but the doc should state the proof
obligation explicitly and recommend structural recognition before
launching refinement.

### F11. Working budget vs. user budget

"Internal working intervals may temporarily exceed this limit" is
correct but vague. `exp` Taylor terms have `r^N / N!`; for `N = 200` the
factorial denominator alone is ~1200 bits. For high-budget targets the
working precision must be a multiple of the user budget. State a
concrete relation, e.g., "intermediates may use up to 4× the user
budget", and define what happens at the cap.

## Concrete Amendments

### To `base10-level-interval-arithmetic-proposal.md`

1. **Add a "Coexistence and migration" section.** State whether the
   level-interval kernel (a) replaces `DecimalInterval` /
   `ScientificScale` / `Pow10Tower` in Tungie, (b) sits as a parallel
   backend, or (c) lives in a sibling project for a future Tungie
   migration. Without this the proposal floats free of project context.

2. **Define a single canonical form per value, constructed at point
   creation.** Suggested rule:

   - If the value fits as a level-zero rational within budget, prefer
     non-reciprocal level-zero unless the value equals an exact tower
     boundary `L_n(0)` for some `n ≥ 1` representable in budget — then
     prefer the boundary.
   - Apply the same rule to reciprocals.
   - Equality on canonical forms is structural; non-canonical forms must
     be normalized before comparison or arithmetic.

3. **Specify "stay at level" outward rounding.** Outward rounding from
   coordinate `r` at level `n` must produce a coordinate strictly less
   than `1` at the same level. Level promotion happens only when the
   mathematical interval forces it (i.e., the operation crosses a tower
   boundary), never as a side effect of bit-budget fitting.

4. **Make the budget configurable and pick a reasonable routine
   default.** Rename `CoordinateBitLimit` to a session parameter
   analogous to `$Precision`. Suggest a routine default of 256–512 bits
   and document 10 000 as a high-precision headroom example.

5. **Add a "Precision derivation" section.** Give a formula for
   `(center, precision, accuracy)` derived from `Interval[lower,
   upper]`, compatible with today's Tungie display rules. In particular,
   show how the negative-precision result
   `1`-86.364…*^^102` from `(1.*^^2)^(1.*^^2)` would be rendered, so
   that test expectations can be re-anchored deliberately rather than
   accidentally.

6. **Cross-walk to `Pow10Tower`.** Add a paragraph stating that `L_n(r)`
   with `r ∈ [0, 1)` rational corresponds to a generalization of
   today's `Pow10Tower[n − 1, ...]`: an `n`-deep base-10 tower with a
   rational top coordinate rather than only an integer top.

7. **Document the `AroundZero` removal.** State explicitly that the
   current support for `0` with finite accuracy (e.g., `.1`0`) becomes
   an `Interval[-r, r]`. Show what `Precision[.1`0]` reports in the new
   system.

### To `certified-exp10-log10-with-rational-intervals.md`

1. **Tighten the ln range reduction.** Use `u ∈ [1/√2, √2]` for
   `|z| ≤ (√2 − 1)/(√2 + 1) ≈ 0.172`, with the choice of `k` decided by
   comparing `x^2` to powers of two (still rational).

2. **Prove termination of the `precision *= 2` loops.** One paragraph
   per loop is enough. For atanh with `|z| ≤ 0.172`, reaching width `ε`
   needs `N = O(log(1/ε))` terms; doubling `N` succeeds in
   `O(log log(1/ε))` rounds.

3. **Specify a working budget separate from the user budget.**
   "Intermediates may use up to `K *  CoordinateBitLimit` bits, with a
   default `K = 4`." Define behavior when a series cannot finish within
   `K` (return a wider but valid enclosure; do not silently lose
   containment).

4. **Specify directed dyadic floor/ceil of rationals.**
   `floor(p/q * 2^k) / 2^k = ((p << k) // q) / 2^k`, and the
   sign-adjusted analog for `ceil`. Trivial, but worth pinning.

5. **Note the alternating-series advantage for `r < 0` in `exp`.**
   For negative `r`, even-index truncation gives a directed *upper* bound
   and odd-index truncation a directed *lower* bound; this halves the
   constant in the tail bound for that case.

6. **Give the trigger for the level-endpoint shortcut.** "If
   `|y| > BudgetThreshold * ln(10)` (or equivalently, the result
   magnitude would not fit as a level-zero rational), do not compute
   `exp(y)` in level-zero rational space; build the level-1+ endpoint
   from `y / ln(10)` as a coordinate." This is the paragraph that
   prevents accidental rational explosion.

7. **State the comparison-with-target proof obligation.** Comparisons
   between a transcendental enclosure and a rational target are
   decidable except when the rational equals the transcendental, which
   transcendence theorems rule out except for trivial structural cases.
   Recommend structural recognition before refinement, with a
   refinement cap as last resort.

8. **Add a "Mapping to Tungie's existing ln/log10 callers" section.**
   Show how `_decimal_ln10`, `_decimal_log10_abs`, `_interval_exp`, and
   `_interval_log` (`evaluator.py:3066`, `:3051`, `:2508`, `:2529`)
   become directed `lnLower` / `lnUpper` / `log10Lower` / `log10Upper`
   calls. This is the migration path that is currently missing and
   that determines whether the spec is actually adoptable.

9. **Concrete invariants for the testing strategy.** The doc lists
   properties (containment, monotonicity, directedness). Sharpen with
   concrete invariants suitable for property-based tests:

   - `lnLower(x) ≤ lnUpper(x)`, with strict inequality unless `x = 1`.
   - `lnLower(x) ≤ true ln(x) ≤ lnUpper(x)` checked against a
     high-precision oracle (mpmath) on a corpus of random rationals.
   - `exp10Lower(log10Upper(x)) ≤ x ≤ exp10Upper(log10Lower(x))` for
     positive `x`.
   - Doubling `terms` never widens an interval.
   - Doubling the bit budget never violates containment.

10. **Cost estimate paragraph.** Even a rough one
    ("`N` terms of the atanh series at `|z| ≤ 0.172` give roughly
    `1.5 * N` decimal digits of `ln`; each term has rational of size
    `O(N log N)` bits; so 100 digits cost ~70 terms with denominators
    in the few-hundred-bit range") tells readers what they are signing
    up for. Useful when picking a routine default for the working
    budget.

## Latent Wins For The Current Codebase

Whether or not the full level-interval kernel is built, two pieces of the
exp10/log10 doc are usable *today* against the existing
`DecimalInterval`-based code:

1. **Replace `_decimal_ln10` and `_decimal_log10_abs` with rational-
   interval versions.** Currently they invoke `Decimal.ln()` at a fixed
   working precision and trust the result. Substituting a rational
   atanh-based `lnInterval` with an explicit width — even while keeping
   `DecimalInterval` for centers and accuracies — removes the
   undocumented dependence on Python's Decimal rounding mode for the
   `log10`-radius calculation in `_log10_uncertainty_accuracy`
   (`evaluator.py:1296`). That tightens the certification of every
   scale-power result the recent `f405cf4f6` / `ad94fbbab` commits
   produced.

2. **Replace `_interval_exp` / `_interval_log` with directed enclosures.**
   The current implementations compute `(center ± radius).exp()` /
   `.ln()` and take a max-difference. Replacing with directed
   `expLower(center − radius)` / `expUpper(center + radius)` (and
   analogously for `ln`) is a localized change that preserves the
   interface while making the result certified.

These are independent of the larger representation change and would land
cleanly in the existing test suite.

## Strategic Recommendation

The proposals are technically solid. The level-interval representation
is recognizably a good design that hugs base-10 visualization, and the
certified exp10/log10 algorithms are textbook-correct with thoughtful
range reduction. The main weaknesses are about *scoping* and *committing
to a single canonical form*, not about the mathematics.

I would suggest, in order:

1. **Land a small code-backed prototype.** Create
   `src/Tungsten/Nummy/src/level/` (or similar), implementing
   `LevelPoint(sign, level, orientation, coordinate: Fraction)`,
   `LevelInterval(lower, upper)`, rational-only `lnInterval` /
   `expInterval` / `log10Interval` / `exp10Interval`, and the basic
   arithmetic ops `add`, `mul`, `pow_integer`. 30–50 round-trip and
   containment tests against an mpmath oracle. This will surface the
   under-specified corners of the spec faster than further document
   iteration.

2. **Amend both proposals with the items in the previous section,
   driven by what the prototype learns.** In particular, lock in a
   single canonical form (F2, amendment 2) and the
   stay-at-level-outward-rounding rule (F3, amendment 3) before the
   prototype commits to one accidentally.

3. **Land the two latent wins immediately.** The `lnInterval`
   rational-arithmetic helper and the directed `expLower` /
   `expUpper` / `lnLower` / `lnUpper` routines can replace
   `_decimal_ln10`, `_decimal_log10_abs`, `_interval_exp`,
   `_interval_log` in today's evaluator without touching the
   `DecimalInterval` interface. That delivers a concrete certification
   tightening on the current scale-power machinery and validates the
   exp10/log10 spec on the existing test surface.

4. **Add an "Implementation status" section to
   `tungie-interval-precision-spec.md`** pointing forward to the
   level-interval kernel as a future direction, with an explicit
   statement of what stays the same (precision metadata as `Decimal`,
   compact `SetPrecision[...]` form, exact-centered values) and what
   changes (interval endpoints become level points, exp/log become
   directed-enclosure callers).

The combination of these four steps gives the proposals the
near-term grounding they currently lack while preserving the
larger architectural target.

## Open Questions Worth Answering Before Building

These are the genuine open questions I do not have answers to:

- **Symbolic-center compatibility.** Does the level kernel ever need
  to represent `Sqrt[2]`-with-precision-`10^13` as a stored value, or
  is that always a Tungie-layer concern handled by deferring
  materialization?
- **Domain of "interval crosses zero".** Today, `Sign[ scale-value ]`
  returns an exact `1` or `-1` when the value is certified strictly
  signed (`evaluator.py` test
  `tests/test_tungie.py:195`). Under interval semantics, a
  zero-crossing interval has no certified sign. Is that always
  acceptable for Tungie, or do we want a "certified-strictly-signed"
  predicate that is materially stronger than "interval excludes zero"?
- **Relationship to `Around`.** Tungie deliberately followed
  `Interval`-style containment. If a future user-facing
  `CenteredInterval` syntax is wanted (per
  [`tungie-interval-precision-spec.md`](tungie-interval-precision-spec.md)),
  is the level kernel a place to store its endpoints, or only its
  half-radius?
- **Comparison engine for non-canonical inputs.** If the system ever
  reads a level point that is *not* in canonical form (say, from a
  serialized session), does it normalize on read, or compare via
  `comparePoint`? The performance and audit consequences differ.

The proposals are good enough to make these questions answerable; they
just need to be answered explicitly in the next iteration.
