# Rational Sequence Support Design

- Status: Design and experiment report
- Audience: Vladimir and future agents extending `CommonFactor`
- Scope: `src/CommonFactor`
- Created (UTC): 2026-06-26T16:24:53Z
- Repository HEAD: 2b46b217d65478e0fff0f7f4f6265e11189f5e01
- Last updated (UTC): 2026-06-26T17:40:08Z
- Update basis HEAD: d6802de177e266474afbe9613bb86ac46021fb3e

## Problem Statement

`CommonFactor` currently assumes an exact integer sequence and searches for a
symbolic factor `F(n)` whose evaluated values divide every observed term.  That
model is too narrow for rational input, and it is also too narrow for perfectly
natural sequences with isolated zeros, such as a polynomial factor divided by a
factorial.

For exact rational sequences, literal divisibility is no longer a useful
definition: any rational factor whose observed values are finite and nonzero on
the observed support divides every rational term in the field `Q`.  The real
task is instead to find a symbolic rational factor that makes the quotient
arithmetically simpler while treating zero terms as part of the data, not as
terms to discard or as accidents that break the search.

The tempting fallback,

```wolframlanguage
integerSeq = (LCM @@ Denominator /@ seq) seq
```

is usually the wrong object.  It smears denominator structure into a global
constant, changes local prime-valuation profiles, and often makes the sequence
larger and less recognizable.

The rational extension should therefore work directly with reduced exact
rationals, using signed prime valuations on the finite support, an explicit zero
mask, and an exact residual-complexity objective.

## Key Observation

For a reduced rational term `q`, the available arithmetic information is its
signed p-adic valuation vector

```text
v_p(q) = v_p(Numerator[q]) - v_p(Denominator[q]).
```

This is the right analogue of integer prime exponents.  It captures both
numerator and denominator structure and avoids the false separation introduced
by treating `Numerator[q]` and `Denominator[q]` as independent sequences.

For `q == 0`, however, this finite vector does not exist.  Algebraically one can
say `v_p(0) = +Infinity`, but infinities are not observations to fit with affine,
quadratic, factorial, or Gamma-derived valuation templates.  The implementation
should split the observed index set into:

```text
S = {i | a_i != 0}    finite support, used for signed valuations and heights
Z = {i | a_i == 0}    zero mask, used for zero preservation and root discovery
```

The zero mask is real information, but it is a different kind of information
from finite prime exponents.

However, signed valuations also expose a hard identifiability limit.  If a
symbolic factor and the residual sequence cancel before the observed rational
terms are reduced, the pre-cancellation story is not recoverable from the data
alone.  The package can only recover a mathematically equivalent factor supported
by the reduced rational values.

## Zero Terms and Removable Factors

Zeros should be handled by a zero-aware quotient operation, not by filtering them
out before the search.  For each observed index `i`, candidate evaluation falls
into one of four cases:

| Term | Candidate value | Quotient state | Candidate status |
| --- | --- | --- | --- |
| `a_i != 0` | finite, `F(i) != 0` | known value `a_i/F(i)` | valid at `i` |
| `a_i != 0` | `F(i) == 0` | impossible | reject candidate |
| `a_i == 0` | finite, `F(i) != 0` | known value `0` | valid at `i` |
| `a_i == 0` | `F(i) == 0` | `Missing["RemovableZero"]` unless filled later | valid as a removable-zero hypothesis |

Candidate values that evaluate to `ComplexInfinity`, `Indeterminate`,
`Undefined`, or a non-rational exact expression should be rejected by default.
If the expression has a removable singularity in Wolfram Language syntax, the
normal candidate-canonicalization path should simplify it before this table is
applied; the zero-aware quotient should not try to prove arbitrary analytic
limits as part of its cheap evaluation loop.

The last row is the subtle case.  If both `a_i` and `F(i)` are zero, the observed
sequence alone does not determine the quotient value at that index.  For example,

```wolframlanguage
a_n = ((n - 2) (n - 5) Prime[100+n]) / n!
```

has zeros at `n == 2` and `n == 5`.  The factor `(n - 2) (n - 5)/n!` is perfectly
meaningful, but a finite list of reduced values only tells us the quotient away
from the roots.  The quotient at the roots is a removable value that may be
recoverable from a discovered formula for the residual, not from direct
division of the observed samples.

The result object should therefore be allowed to carry a punctured residual
sequence:

```wolframlanguage
{knownQ1, Missing["RemovableZero"], knownQ3, ...}
```

It should also carry an indexed known-observation view:

```wolframlanguage
{{i1, knownQ1}, {i3, knownQ3}, ...}
```

This is the form to pass to sequence-function discovery tools.  In particular,
`FindSequenceFunction` can work with holes when the observed indices are supplied
explicitly, so unknown removable positions should be omitted from that indexed
dataset rather than represented by `Missing` or `Indeterminate`.  Known zero
quotients from the third row of the table are not holes; they should remain in
the indexed dataset as ordinary `{index, 0}` observations.

The intended call shape is:

```wolframlanguage
residualFormula = FindSequenceFunction[knownResidualPairs, n]
```

where the first element of each pair is the actual sequence index.  For example,
`FindSequenceFunction[Table[{2 k, 2^k}, {k, 8}], n]` recovers `2^(n/2)`, showing
that omitted odd indices are genuine holes rather than implicit missing values.

This is better than silently producing `Indeterminate`, replacing the value with
`0`, or rejecting every zero-covering factor.  A later reconstruction pass may
fill removable values when it can justify them, for example by:

- evaluating a symbolic residual formula found from explicit indexed support
  observations;
- taking an exact limit when an explicit symbolic expression for the original
  sequence is supplied by the user;
- using a user-supplied candidate factor whose quotient expression is known;
- interpolating only as a diagnostic, not as a proof of the value.

Multiplicity is even less identifiable.  A single observed zero does not reveal
whether the hidden factor contains `(n-r)`, `(n-r)^2`, or a higher power.  The
default zero-mask candidate should use multiplicity one.  Higher multiplicities
should enter only through widening rounds, user-supplied candidates, nearby
finite-difference evidence, or because they produce a much simpler residual on
the finite support.

### Zero-Mask Candidate Discovery

The zero mask should seed its own small candidate family:

```wolframlanguage
n - r
Times @@ (n - r_j)
Pochhammer[n - rHigh, m]              (* roots rHigh-m+1, ..., rHigh *)
FallingFactorial[n - rLow, m]         (* roots rLow, ..., rLow+m-1 *)
```

These candidates are zero-covering candidates: they are accepted only if they do
not vanish on the finite support and if the resulting punctured residual improves
the score enough to pay for the formula cost and any unknown removable values.
They should get, at most, a modest explanatory bonus for compactly matching the
observed zero mask.  Otherwise a finite sample with one zero would invite
arbitrary overfitted factors.

If all observed terms are zero, there is no finite valuation or residual-height
signal at all.  The package should return factor `1` with a diagnostic such as
`"All observed terms are zero; common factors are not identifiable from the
data."` unless the user supplied explicit candidate factors or an original
symbolic expression to analyze.

## Experiments

The experiments below used four small synthetic rational sequences and a simple
exact height score

```wolframlanguage
qHeight[q_] := Log[Max[Abs[Numerator[q]], Abs[Denominator[q]]]]
totalHeight[seq_] := Total[qHeight /@ seq]
```

The candidate score was `totalHeight[seq] - totalHeight[seq/candidate]`.

### Rational Factor With Factorial Denominator

Sequence:

```wolframlanguage
a_k = 10^k (2 k + 1)!! k^2 Prime[50+k] / (k+3)!
```

Observed values:

```wolframlanguage
{1165/4, 11950, 632625/2, 7530000, 662578125/4,
 3525843750, 147256484375/2, 1497275000000}
```

Candidate scores:

| Candidate | Height before | Height after | Gain | Observation |
| --- | ---: | ---: | ---: | --- |
| `10^n n^2 (2 n + 1)!!/(n+3)!` | 141.686 | 44.256 | 97.430 | Correct full rational factor, quotient is primes. |
| `10^n` | 141.686 | 75.429 | 66.258 | Good partial factor. |
| `1/(n+3)!` | 141.686 | 216.610 | -74.924 | Denominator part alone is actively harmful under max-height. |
| `(n+3)!` | 141.686 | 112.543 | 29.143 | Wrong direction still improves height on this sample. |

This is the main reason a purely greedy reciprocal-atom extension is not enough:
one component of the right rational factor can have negative standalone score.

### Catalan-Like Cancellation

Sequence:

```wolframlanguage
a_k = Binomial[2 k, k] Prime[80+k] / (k+1)!
```

The equivalent compact form is `CatalanNumber[k] Prime[80+k] / k!`.

Candidate scores:

| Candidate | Height before | Height after | Gain | Observation |
| --- | ---: | ---: | ---: | --- |
| `Binomial[2 n,n]/(n+1)!` | 66.452 | 48.627 | 17.825 | Correct quotient is primes. |
| `CatalanNumber[n]/n!` | 66.452 | 48.627 | 17.825 | Same reduced factor in a nicer vocabulary. |
| `Binomial[2 n,n]` | 66.452 | 62.728 | 3.724 | Looks useful but worsens some terms. |
| `1/(n+1)!` | 66.452 | 88.318 | -21.866 | Again, denominator part alone is bad. |

The ratio must be considered as a coupled candidate, not discovered by selecting
the numerator and denominator independently.

### Small Linear Rational Factor

Sequence:

```wolframlanguage
a_k = ((k+2)/(k+3)) Prime[110+k]
```

Candidate scores:

| Candidate | Height before | Height after | Gain | Observation |
| --- | ---: | ---: | ---: | --- |
| `(n+2)/(n+3)` | 65.940 | 51.529 | 14.411 | Correct quotient is primes. |
| `n+2` | 65.940 | 51.529 | 14.411 | Same max-height gain but leaves denominators. |
| `1/(n+3)` | 65.940 | 65.940 | 0 | Removes denominators only after `n+2` is selected. |
| `n+3` | 65.940 | 65.940 | 0 | No max-height signal. |

This shows that max-height alone does not distinguish “prime quotient” from
“prime divided by a structured denominator.”  A denominator-complexity term or
integer-quotient preference is needed.

### Why LCM Integerization Is Misleading

For the three sequences above, multiplying by the LCM of denominators increased
the total height:

| Case | LCM | Rational height | Integerized height |
| --- | ---: | ---: | ---: |
| Factorial denominator | `4` | 141.686 | 148.618 |
| Catalan-over-factorial | `20160` | 66.452 | 118.648 |
| Linear rational factor | `27720` | 65.940 | 132.069 |

The signed valuation columns also become more regular only in the rational
representation.  For the linear case,

```wolframlanguage
v_2(a_k) = {-2, 2, -1, 1, -3, 3, -1, 1}
v_5(a_k) = {0, -1, 1, 0, 0, 0, -1, 1}
```

These are not numerator-only or denominator-only signals.  They are net signed
signals of a rational factor.

## Proposed Semantics

For an exact rational sequence `a_i`, a symbolic rational factor `F(n)` is
acceptable when:

1. `F(i)` is a finite exact rational at every observed index.
2. `F(i) != 0` for every support index `i` where `a_i != 0`.
3. The quotient state at every index follows the zero-aware table above.
4. The known quotient values, together with the missing-removable mask, are
   simpler under a documented residual-complexity objective.

The residual should be exposed in two equivalent views:

- a position-preserving vector that may contain `Missing["RemovableZero"]`;
- explicit indexed known observations suitable for `FindSequenceFunction` and
  other tools that understand holes.

There should be no default requirement that the quotient be integer.  Instead,
integer quotients should receive a strong preference because they are often the
ideal outcome.

Recommended public option:

```wolframlanguage
"QuotientTarget" -> Automatic
```

with values:

- `Automatic`: rational mode for rational input, integer mode for integer input.
- `"Rational"`: optimize rational residual complexity.
- `"Integer"`: require all quotient terms to be integers.
- `"PreferInteger"`: rational mode, but add a strong integer-quotient bonus.

For `"Integer"`, `Missing["RemovableZero"]` should not be counted as an integer
value.  The result can still be returned as the best punctured state, but the
diagnostics should say that the integer quotient is verified only on the finite
known support unless removable values were filled.

The existing integer behavior should remain the fast path for integer sequences,
but it should share the same zero-aware quotient logic.  Integer sequences can
have natural zeros too.

## Residual Complexity

The rational-mode score should be based on a vector of exact residual statistics,
not on one scalar alone.

For a rational residual sequence `r`, define the known value list by deleting
`Missing["RemovableZero"]`.  Known zeros contribute height `0`; they are excluded
from finite valuation sums.

```wolframlanguage
knownValues[r] = DeleteMissing[r]
knownPairs[r, indices] = Cases[Transpose[{indices, r}], {i_, q_} /; ! MissingQ[q] :> {i, q}]
finiteSupport[r] = Select[knownValues[r], # != 0 &]

sizeHeight[r] = Total[Log[Max[Abs[Numerator[#]], Abs[Denominator[#]]]] & /@ knownValues[r]]
numHeight[r]  = Total[Log[Max[1, Abs[Numerator[#]]]] & /@ knownValues[r]]
denHeight[r]  = Total[Log[Denominator[#]] & /@ knownValues[r]]
valL1[r]      = Total over observed primes p and q in finiteSupport[r] of Abs[v_p(q)]
unknownCount[r] = Count[r, Missing["RemovableZero"]]
```

Recommended ranking key:

```text
{
  sizeHeight,
  denWeight denHeight,
  valWeight valL1,
  unknownWeight unknownCount,
  formulaPenalty,
  tieBreakers...
}
```

In implementation this can be a weighted scalar for fast sorting, but the
diagnostics should report each component separately.

Important detail: `denHeight` must participate even when `sizeHeight` is
unchanged.  In the linear experiment, `1/(n+3)` has zero max-height gain after
`n+2`, but it removes the entire structured denominator and should be eligible.

Candidate acceptance should require one of:

- positive total weighted improvement and not too much per-term damage;
- integer quotient improvement;
- beam-search retention as a promising partial state, even if immediate score is
  mildly negative.

The last case is necessary because a denominator component can be temporarily
bad while the paired rational factor is excellent.

Zero-covering factors need one additional guard: they should not win merely
because they turn several observed zeros into missing values.  A state with fewer
unknown removable values should dominate an otherwise identical state, and a
state with unknowns should beat a fully known state only when its finite-support
residual is materially simpler or its zero mask is explained by a compact,
low-complexity factor.

## Candidate Generation

Rational support should add candidates in four layers.

### 1. Signed Valuation Discovery

For every prime appearing in any reduced numerator or denominator, compute:

```wolframlanguage
vals[p] = Table[v_p(a_i), {i}]
```

Fit simple integer-valued profiles to `vals[p]`:

- exact affine `a n + b`;
- exact quadratic `a n^2 + b n + c`;
- lower affine envelopes for numerator-like common factors;
- upper affine envelopes for denominator-like common factors.

This generalizes the current integer valuation discovery:

- positive profile `e(n)` suggests `p^e(n)`;
- negative profile `-e(n)` suggests `p^-e(n)`;
- proportional profiles across several primes should be clustered into rational
  bases such as `(2/3)^n` or `(12/5)^(n^2)`.

The output of this layer should include rational-valued candidates directly:

```wolframlanguage
p^poly
p^-poly
Times @@ (p_j^(c_j poly))
```

### 2. Grammar Atoms and Reciprocals

Every existing positive-integer atom should become a rational atom source by
including its reciprocal:

```wolframlanguage
A(n)
1/A(n)
```

Atoms include the current grammar: exponentials, linear terms, factorials,
double factorials, Pochhammer/falling factorials, Gamma quotients, binomials,
multinomials, Catalan, Fibonacci/Lucas, BarnesG, and signs.

A reciprocal atom should be allowed even when it does not improve max-height by
itself, because it may remove denominators in combination with a numerator atom.

### 3. Coupled Ratio Templates

Do not rely only on selecting `A(n)` and then `1/B(n)` independently.  Generate
direct ratio candidates for common families:

```wolframlanguage
(n+s)/(n+t)
Factorial[n+s]/Factorial[n+t]
Factorial[2 n+s]/Factorial[n+t]
Pochhammer[n+s, k]/Pochhammer[n+t, k]
FactorialPower[n+s, k]/FactorialPower[n+t, k]
Binomial[2 n+s, n]/Factorial[n+t]
CatalanNumber[n+s]/Factorial[n+t]
Gamma[alpha n + beta]/Gamma[gamma n + delta]
BarnesG[n+s]/BarnesG[n+t]
```

Candidate explosion is real.  Use staged generation:

1. Score atoms and reciprocals cheaply.
2. Keep the top `K` numerator-like atoms and top `K` denominator-like atoms by
   correlation with signed residual valuations.
3. Generate ratios only within compatible families and within a formula-cost
   budget.
4. Widen `K`, shifts, and orders under `TimeConstraint`.

This keeps the search effectively unbounded without making ordinary calls
unbounded.

### 4. Zero-Mask Templates

From the observed zero indices, generate compact root factors after the ordinary
finite-support valuation candidates:

```wolframlanguage
n - r
Product[n - r, {r, roots}]
Pochhammer[n - rHigh, m]
FallingFactorial[n - rLow, m]
```

These are evaluated with the zero-aware quotient table.  They should not
contribute signed valuation rows, because their valuation at their roots is not
finite.  Away from their roots, however, they may combine productively with
rational denominator factors such as `1/n!`.

## Search Strategy

The integer reducer can stay greedy because integer divisibility imposes a
strong monotone constraint.  Rational support should use a beam search.

State:

```wolframlanguage
<|
  "Factor" -> product expression,
  "FactorValues" -> vector,
  "ResidualSequence" -> zero-aware quotient vector,
  "SupportIndices" -> indices where the original term is not zero,
  "ZeroIndices" -> indices where the original term is zero,
  "UnknownQuotientIndices" -> indices with Missing["RemovableZero"],
  "KnownResidualPairs" -> explicit {index, value} observations for residual tools,
  "ZeroFactors" -> selected factors that vanish on zero indices,
  "SelectedFactors" -> list,
  "ScoreVector" -> residual complexity components
|>
```

Expansion:

1. Generate candidate factors for the current round.
2. For each beam state and candidate, evaluate the quotient with the zero-aware
   table.
3. Compute the residual-complexity vector.
4. Keep the best states under dominance pruning.

Dominance:

- If two states have identical residual sequences, keep the one with lower formula
  complexity.
- If one state has no worse `sizeHeight`, no worse `denHeight`, no worse `valL1`,
  no worse `unknownCount`, and lower formula complexity, discard the dominated
  state.
- Keep a small number of mildly worse states so denominator-only moves can survive
  until they pair with numerator moves.
- For punctured states, identical residual sequences require both identical known
  values and identical missing-removable masks.

Progress output:

```text
CommonFactor: round r, best factor = ..., residual height = ..., denominator height = ..., removable zeros = ...
```

Unlike the integer reducer's current progress line, rational progress should
print only when the best state improves under the rational score vector.

The result association should add:

```wolframlanguage
"InputDomain" -> "Rational"
"ResidualComplexity" -> <|...|>
"ZeroIndices" -> {...}
"UnknownQuotientIndices" -> {...}
"KnownResidualPairs" -> {{i1, q1}, ...}
"BestStateCount" -> ...
"SearchMode" -> "Beam"
"QuotientTarget" -> ...
```

When the package attempts residual recognition, the indexed known pairs should be
the default input.  If a candidate residual formula is found from those pairs,
the package may evaluate it at `UnknownQuotientIndices` and fill the punctured
residual only after checking consistency with all known observations and, when
available, holdout indices.

## Time-Bounded Behavior

`TimeConstraint` should remain a hard outer budget.  Under finite time:

- candidate rounds widen shifts, bases, ratio-pair count, and Gamma/Pochhammer
  order;
- every expensive operation (`FactorInteger`, candidate evaluation, ratio-pair
  generation, beam expansion) checks the remaining budget;
- when time elapses, return the best beam state found so far;
- if no factor has been found, return factor `1` and the original sequence.
- if only punctured states were found, return the best one with explicit
  `UnknownQuotientIndices` diagnostics rather than pretending the residual is a
  complete ordinary sequence.

This matches the integer reducer's current best-so-far semantics while making
rational search naturally extensible.

## Implementation Plan

### Phase 1: Rational Scoring Kernel

Add internal helpers:

```wolframlanguage
rationalSequenceQ
rationalCandidateValuesQ
sequenceSupport
zeroIndices
zeroAwareQuotient
knownResidualPairs
rationalComplexityVector
rationalCandidateScore
signedValuationRows
puncturedValuationRows
```

Do not change integer behavior yet.  Add a private experimental entry point or
option-gated path and tests for the four synthetic examples above, plus a
zero-containing example.

### Phase 2: Rational Candidate Generation

Add:

- reciprocal atoms;
- signed valuation discovery;
- rational base clustering;
- direct small-family ratio templates;
- zero-mask root templates.

`CommonFactorCandidateReport` should show rational candidates and their full
complexity breakdown.

### Phase 3: Beam Search

Introduce rational-mode beam search with options:

```wolframlanguage
"BeamWidth" -> 16
"RatioPairLimit" -> 64
"TemporaryDamageAllowance" -> Automatic
"QuotientTarget" -> Automatic
```

Keep the existing greedy integer path for exact integer input.

### Phase 4: Polish and Diagnostics

Add:

- progress output for rational score components;
- explanatory warnings when LCM integerization would be much larger;
- holdout validation for candidate products when enough terms exist;
- residual-recognition calls that pass explicit index-value pairs so holes remain
  holes;
- tests for assigned index symbols, finite timeouts, ratio candidates, reciprocal
  candidates, accidental denominator cancellations, isolated zeros, zero-covering
  factors, and all-zero input diagnostics.

## Open Questions

- The scalar weights for `sizeHeight`, `denHeight`, and `valL1` need calibration.
  The experiments show that `denHeight` cannot be zero, but the right default
  weight is empirical.
- Formula complexity should penalize opaque Gamma quotients when a named
  combinatorial equivalent is available.  A post-pass should rewrite factors
  toward `CatalanNumber`, `Binomial`, `Pochhammer`, and factorials when possible.
- Some rational factors are only visible after several individually neutral
  moves.  Beam width and temporary-damage policy determine whether those survive.
- How aggressive should zero-mask discovery be?  Multiplicity and sparse-root
  interpolation are easy to overfit from finite data, so the default should be
  conservative.
- Should public residual sequences expose `Missing["RemovableZero"]` directly, or
  wrap punctured output in a richer association with known values and holes?
- Reduced rational data cannot identify hidden pre-cancellation structure.  The
  documentation should say this plainly so the package is not expected to recover
  a story the data no longer contains.

## Recommendation

The best design is not to integerize rational sequences and not to split
numerators from denominators.  Work directly over reduced rationals, represent
finite support terms and candidates by signed valuation vectors, keep zeros in a
separate mask, and choose factors by exact residual-complexity reduction.
Generate rational candidates directly, especially family ratios and conservative
zero-mask root factors, and search with a small beam rather than a single greedy
path.

That gives the package a principled rational mode while preserving the current
integer fast path, and it makes both modes resilient to natural zero terms.
