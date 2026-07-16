# CommonFactor

- Status: Wolfram Language package and smoke suite
- Audience: Vladimir and future agents investigating finite exact sequences
- Scope: `CommonFactor`
- Created (UTC): 2026-06-26T15:37:34Z
- Repository HEAD: 99d9ca081c8c148d90a9f6c438f34d4b0ee8489a
- Related source: [Mathematica StackExchange question 261053](https://mathematica.stackexchange.com/questions/261053/largest-symbolic-common-factor-of-an-integer-sequence-not-simply-gcd)
- Related design: [Rational sequence support](docs/rational-sequences-design.md)

`CommonFactor` is a heuristic Wolfram Language package for finding a large
symbolic common factor in a finite exact integer or rational sequence.  It is
aimed at the case where the raw sequence grows too quickly or irregularly for
`FindSequenceFunction`, but a substantial factor such as

```wolframlanguage
10^n (2 n + 1)!! n^2
```

can be peeled away, leaving a slower quotient sequence.

The implementation is intentionally best-effort.  It does not prove that the
reported factor is globally largest or unique.  Instead, it discovers candidates
in stages and chooses factors that simplify the observed residual.  Exact
nonzero integer input uses a fast divisibility-driven greedy path.  Rational
input and integer input containing zeros use a zero-aware beam search over exact
rational quotient states.  The returned association includes the selected factor
list and the residual sequence so the result can be inspected and refined.

## Public API

```wolframlanguage
Get["CommonFactor.wl"];

FindSymbolicCommonFactor[seq, n]
CommonFactorReduce[seq, n]
CommonFactorCandidateReport[seq, n]
```

`FindSymbolicCommonFactor` returns only the factor expression.  `CommonFactorReduce`
returns diagnostics:

```wolframlanguage
<|
  "Factor" -> ...,
  "FactorValues" -> ...,
  "QuotientSequence" -> ...,
  "ResidualSequence" -> ...,
  "ResidualGCD" -> ...,
  "ResidualComplexity" -> ...,
  "ZeroIndices" -> ...,
  "UnknownQuotientIndices" -> ...,
  "KnownResidualPairs" -> ...,
  "SelectedFactors" -> ...,
  "CandidateCount" -> ...,
  "IndexRange" -> ...,
  "TimedOut" -> ...
|>
```

For rational and zero-containing input, `QuotientSequence` can contain
`Missing["RemovableZero"]` at indices where both the observed term and the
selected factor vanish.  `KnownResidualPairs` gives the corresponding explicit
`{index, value}` observations, omitting those removable holes so it can be passed
directly to `FindSequenceFunction`.

By default `CommonFactorReduce` prints a progress line every time it discovers a
larger factor, then continues searching.  Set `"Progress" -> False` for quiet
batch use, or pass a pure function to receive a payload association for each
step.  `TimeConstraint -> t` makes the search time-bounded and returns the best
factor found so far when the budget elapses; with finite time and
`"SearchRounds" -> Automatic`, the candidate horizon keeps widening until the
time budget is exhausted.

The candidate sources include:

- prime-valuation discovery from `FactorInteger`, inferring factors such as
  `13^n`, `p^(a n+b)`, and exact quadratic valuation powers such as `p^(n^2)`;
- shifted exponentials `c^(n+s)` for bases `2..12`;
- quadratic exponentials such as `c^(n^2)`, `c^(n (n+1)/2)`, and shifted variants;
- linear factors `n+s` and `2 n+s`;
- `Factorial[n+s]`, `Factorial[2 n+s]`;
- `Factorial2[n+s]`, `Factorial2[2 n+s]`;
- `Pochhammer[n+s, k]` (rising factorials) and `FactorialPower[n+s, k]`
  (falling factorials);
- integer-valued `Gamma` quotients such as `Gamma[2 n+s+1]/Gamma[n+s+1]`;
- central and nearby binomial coefficients;
- multinomials such as `Multinomial[n, n, n]`;
- `CatalanNumber[n+s]`;
- `Fibonacci[n+s]` and `LucasL[n+s]`;
- `BarnesG[n+s+2]`, representing superfactorial-style products;
- periodic sign factors such as `(-1)^n`.

The widening knobs are:

- `"SearchRounds"` — number of candidate-expansion rounds, or `Automatic`
  (`1` with no time limit, unbounded with a finite `TimeConstraint`);
- `"BaseGrowthStep"` — how far to extend the exponential base range each round;
- `"ShiftGrowthStep"` — how far to extend the shift range each round;
- `"ExtendedOrderMax"` — maximum small order for Pochhammer/falling/Gamma-quotient
  candidates in the first round; later rounds increase it gradually.
- `"QuotientTarget"` — `Automatic`, `"Rational"`, `"Integer"`, or
  `"PreferInteger"` for rational/zero-aware residual scoring;
- `"BeamWidth"` and `"TemporaryDamageAllowance"` — rational-mode controls for
  retaining temporarily worse states, especially denominator moves and
  zero-covering factors;
- `"RatioPairLimit"` — maximum shift-pair count for the direct rational ratio
  templates.

Custom candidate expressions can be supplied with `"ExtraCandidates"`, either as
plain expressions in `n` or as labels:

```wolframlanguage
CommonFactorReduce[
  seq,
  n,
  "ExtraCandidates" -> {"quadratic" -> n^2 + n + 1}
]
```

## Example

```wolframlanguage
b = Table[Prime[50 + k], {k, 1, 9}];
seq = Table[10^k Factorial2[2 k + 1] k^2 b[[k]], {k, 1, Length[b]}];

data = CommonFactorReduce[seq, n];
data["Factor"]
data["QuotientSequence"]
```

The smoke suite checks that this recovers a factor equivalent on the observed
index range to:

```wolframlanguage
10^n Factorial2[2 n + 1] n^2
```

with quotient `b`.

## Validation

Run the smoke suite with the paid Wolfram 15 kernel:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script CommonFactor/tests/smoke.wl
```

The demo script prints the motivating decomposition:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script CommonFactor/Demo.wl
```
