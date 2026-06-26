# Rational Sequence Support Design

- Status: Design and experiment report
- Audience: Vladimir and future agents extending `CommonFactor`
- Scope: `src/CommonFactor`
- Created (UTC): 2026-06-26T16:24:53Z
- Repository HEAD: 2b46b217d65478e0fff0f7f4f6265e11189f5e01

## Problem Statement

`CommonFactor` currently assumes an exact nonzero integer sequence and searches
for a symbolic factor `F(n)` whose evaluated values divide every observed term.
For exact rational sequences this literal divisibility test is no longer a
useful definition: every nonzero rational sequence factor divides every rational
term in the field `Q`.  The real task is instead to find a symbolic rational
factor that makes the quotient arithmetically simpler.

The tempting fallback,

```wolframlanguage
integerSeq = (LCM @@ Denominator /@ seq) seq
```

is usually the wrong object.  It smears denominator structure into a global
constant, changes local prime-valuation profiles, and often makes the sequence
larger and less recognizable.

The rational extension should therefore work directly with reduced exact
rationals, using signed prime valuations and an exact residual-complexity
objective.

## Key Observation

For a reduced rational term `q`, the available arithmetic information is its
signed p-adic valuation vector

```text
v_p(q) = v_p(Numerator[q]) - v_p(Denominator[q]).
```

This is the right analogue of integer prime exponents.  It captures both
numerator and denominator structure and avoids the false separation introduced
by treating `Numerator[q]` and `Denominator[q]` as independent sequences.

However, signed valuations also expose a hard identifiability limit.  If a
symbolic factor and the residual sequence cancel before the observed rational
terms are reduced, the pre-cancellation story is not recoverable from the data
alone.  The package can only recover a mathematically equivalent factor supported
by the reduced rational values.

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

1. `F(i)` is a nonzero exact rational for every observed index.
2. The quotient `q_i = a_i / F(i)` is exact rational.
3. The quotient sequence is simpler under a documented residual-complexity
   objective.

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

The existing integer behavior should remain the fast path for integer sequences.

## Residual Complexity

The rational-mode score should be based on a vector of exact residual statistics,
not on one scalar alone.

For a rational sequence `r`, define:

```wolframlanguage
sizeHeight[r] = Total[Log[Max[Abs[Numerator[#]], Abs[Denominator[#]]]] & /@ r]
numHeight[r]  = Total[Log[Max[1, Abs[Numerator[#]]]] & /@ r]
denHeight[r]  = Total[Log[Denominator[#]] & /@ r]
valL1[r]      = Total over observed primes p and indices i of Abs[v_p(r_i)]
```

Recommended ranking key:

```text
{
  sizeHeight,
  denWeight denHeight,
  valWeight valL1,
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

## Candidate Generation

Rational support should add candidates in three layers.

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

## Search Strategy

The integer reducer can stay greedy because integer divisibility imposes a
strong monotone constraint.  Rational support should use a beam search.

State:

```wolframlanguage
<|
  "Factor" -> product expression,
  "FactorValues" -> vector,
  "ResidualSequence" -> seq / factorValues,
  "SelectedFactors" -> list,
  "ScoreVector" -> residual complexity components
|>
```

Expansion:

1. Generate candidate factors for the current round.
2. For each beam state and candidate, evaluate the quotient exactly.
3. Compute the residual-complexity vector.
4. Keep the best states under dominance pruning.

Dominance:

- If two states have identical residual sequences, keep the one with lower formula
  complexity.
- If one state has no worse `sizeHeight`, no worse `denHeight`, no worse `valL1`,
  and lower formula complexity, discard the dominated state.
- Keep a small number of mildly worse states so denominator-only moves can survive
  until they pair with numerator moves.

Progress output:

```text
CommonFactor: round r, best factor = ..., residual height = ..., denominator height = ...
```

Unlike the integer reducer's current progress line, rational progress should
print only when the best state improves under the rational score vector.

The result association should add:

```wolframlanguage
"InputDomain" -> "Rational"
"ResidualComplexity" -> <|...|>
"BestStateCount" -> ...
"SearchMode" -> "Beam"
"QuotientTarget" -> ...
```

## Time-Bounded Behavior

`TimeConstraint` should remain a hard outer budget.  Under finite time:

- candidate rounds widen shifts, bases, ratio-pair count, and Gamma/Pochhammer
  order;
- every expensive operation (`FactorInteger`, candidate evaluation, ratio-pair
  generation, beam expansion) checks the remaining budget;
- when time elapses, return the best beam state found so far;
- if no factor has been found, return factor `1` and the original sequence.

This matches the integer reducer's current best-so-far semantics while making
rational search naturally extensible.

## Implementation Plan

### Phase 1: Rational Scoring Kernel

Add internal helpers:

```wolframlanguage
rationalSequenceQ
rationalCandidateValuesQ
rationalComplexityVector
rationalCandidateScore
signedValuationRows
```

Do not change integer behavior yet.  Add a private experimental entry point or
option-gated path and tests for the four synthetic examples above.

### Phase 2: Rational Candidate Generation

Add:

- reciprocal atoms;
- signed valuation discovery;
- rational base clustering;
- direct small-family ratio templates.

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
- tests for assigned index symbols, finite timeouts, ratio candidates, reciprocal
  candidates, and accidental denominator cancellations.

## Open Questions

- The scalar weights for `sizeHeight`, `denHeight`, and `valL1` need calibration.
  The experiments show that `denHeight` cannot be zero, but the right default
  weight is empirical.
- Formula complexity should penalize opaque Gamma quotients when a named
  combinatorial equivalent is available.  A post-pass should rewrite factors
  toward `CatalanNumber`, `Binomial`, `Pochhammer`, and factorials when possible.
- Some rational factors are only visible after several individually neutral
  moves.  Beam width and temporary-damage policy determine whether those survive.
- Reduced rational data cannot identify hidden pre-cancellation structure.  The
  documentation should say this plainly so the package is not expected to recover
  a story the data no longer contains.

## Recommendation

The best design is not to integerize rational sequences and not to split
numerators from denominators.  Work directly over reduced rationals, represent
terms and candidates by signed valuation vectors, and choose factors by exact
residual-complexity reduction.  Generate rational candidates directly, especially
family ratios, and search with a small beam rather than a single greedy path.

That gives the package a principled rational mode while preserving the current
integer fast path.
