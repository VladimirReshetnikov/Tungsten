# CommonFactor

- Status: Initial Wolfram Language package and smoke suite
- Audience: Vladimir and future agents investigating finite integer sequences
- Scope: `src/CommonFactor`
- Created (UTC): 2026-06-26T15:37:34Z
- Repository HEAD: 99d9ca081c8c148d90a9f6c438f34d4b0ee8489a
- Related source: [Mathematica StackExchange question 261053](https://mathematica.stackexchange.com/questions/261053/largest-symbolic-common-factor-of-an-integer-sequence-not-simply-gcd)

`CommonFactor` is a heuristic Wolfram Language package for finding a large
symbolic common factor in a finite exact integer sequence.  It is aimed at the
case where the raw sequence grows too quickly or irregularly for
`FindSequenceFunction`, but a substantial factor such as

```wolframlanguage
10^n (2 n + 1)!! n^2
```

can be peeled away, leaving a slower quotient sequence.

The implementation is intentionally best-effort.  It does not prove that the
reported factor is globally largest or unique.  Instead, it generates a broad
library of simple candidate sequence factors, tests exact divisibility on the
observed index range, scores candidates by observed growth with a small
formula-complexity penalty, and greedily removes the strongest currently
available factor.  The returned association includes the selected factor list
and the residual sequence so the result can be inspected and refined.

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
  "SelectedFactors" -> ...,
  "CandidateCount" -> ...,
  "IndexRange" -> ...
|>
```

The default candidate grammar includes:

- shifted exponentials `c^(n+s)` for bases `2..12`;
- linear factors `n+s` and `2 n+s`;
- `Factorial[n+s]`, `Factorial[2 n+s]`;
- `Factorial2[n+s]`, `Factorial2[2 n+s]`;
- central and nearby binomial coefficients;
- `CatalanNumber[n+s]`;
- `Fibonacci[n+s]` and `LucasL[n+s]`.

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
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/CommonFactor/tests/smoke.wl
```

The demo script prints the motivating decomposition:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script src/CommonFactor/Demo.wl
```
