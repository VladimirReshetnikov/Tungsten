# Nummy Alpha/Beta/Gamma Unified Comparison

Created (UTC): 2026-04-28

## Scope

This is the final unified comparison of the three Nummy implementation
experiments under `Engine/Nummy/src/`:

- `alpha/`
- `beta/`
- `gamma/`

It replaces five antecedent comparison reports, now archived under
`archived/`. Those reports overlapped heavily. This document deduplicates their
well-supported claims, softens overbroad claims, and excludes claims that were
not supported by the current code, tests, or project documentation.

The core acceptance target is the archived MathOverflow expression:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

The project-specific question is whether a calculator can recover the finite
tail:

```text
10^10000000000 + 2811012357389.4407116278...
```

without materializing the impossible decimal expansion.

## Source Reports

Antecedent reports:

- `archived/IMPLEMENTATION_COMPARISON.md`
- `archived/alpha-beta-gamma-prior-art-theory-comparison-2026-04-28.md`
- `archived/alpha-beta-gamma-prior-art-theory-comparison.md`
- `archived/alpha-beta-gamma-prior-art-theory-comparison__8037b1a4a5ab.md`
- `archived/alpha-beta-gamma-vs-prior-art-and-theory__7ec46f6f8706.md`

Additional local checks used for this final report:

- README and implementation approach documents under `alpha/`, `beta/`, and
  `gamma/`.
- Representative source modules for each implementation.
- Representative REPL transcripts for the MathOverflow expression.
- Unit test counts from the merged tree.
- Nummy prior-art and theory corpus index documents.

## Claim Triage

The five reports converged on the same broad conclusion: alpha has the best
current calculator surface, beta has the best asymptotic engine, and gamma is
the cleanest compact landmark-plus-tail prototype. That conclusion is retained.

Several claims were softened or excluded:

- Some reports stated or implied that alpha's generic structural tower output
  has a complete precision-certification story. The code supports exact
  rational scalar display and a certified MathOverflow floor report, but
  generic structural tower displays can still carry ordinary precision marks
  such as ``e10000000000`30``. The final report therefore does not claim that
  every alpha structural display is proof-grade.
- Some reports described beta's precision model as strongly trustworthy.
  Beta uses `mpmath`, precision tags, and guard digits, and the asymptotic path
  reports residual information. That is useful but not a global proof of every
  displayed digit.
- Some reports described gamma's precision strategy too generously. Gamma has
  a configurable `Decimal` context, but the REPL does not print precision
  marks or certification metadata. A low-working-precision/high-frac-digit
  API call also showed a `decimal.InvalidOperation` quantization failure during
  review, so this report treats gamma's precision API as prototype-grade.
- Prior-art/theory comparisons were retained only at the level supported by
  the repository's prior-art and theory indexes. The final report does not
  claim a fresh full source audit of every vendored prior-art implementation.
- Size estimates and future-work calendar implications were omitted. Where
  needed, the report uses artifact counts, test counts, and qualitative scope
  descriptions.

## Executive Conclusion

The three implementations are complementary, not redundant:

- `alpha` is the best current user-facing calculator baseline.
- `beta` is the best current perturbative/asymptotic computation baseline.
- `gamma` is the best current minimal conceptual model for landmark-plus-tail
  arithmetic.

The most plausible next Nummy direction is an intentional synthesis:

- keep alpha's ordinary-expression REPL and conservative output posture;
- route tower-near-landmark expressions into beta-style asymptotic machinery;
- expose results through a gamma-style landmark-plus-tail data contract;
- add a shared certainty/error object before claiming proof-grade arbitrary
  decimal precision for all tower-derived displays.

## Inventory

| Track | Files | Python files | Markdown files | Python LOC | Dependencies |
| --- | ---: | ---: | ---: | ---: | --- |
| `alpha` | 17 | 11 | 5 | 1799 | Python standard library |
| `beta` | 23 | 21 | 1 | 2681 | `mpmath>=1.3.0` |
| `gamma` | 12 | 8 | 4 | 889 | Python standard library |

Validation from the merged tree:

| Track | Command | Result |
| --- | --- | --- |
| `alpha` | `python -m unittest discover -s tests` | 22 tests passed |
| `beta` | `python -m unittest discover -s tests` | 144 tests passed |
| `gamma` REPL tests | `python -m unittest discover -s tests` | 8 tests passed |
| `gamma` tower tests | `python -m unittest discover -s nummy_tower\tests` | 6 tests passed |

## Capability Matrix

| Capability | `alpha` | `beta` | `gamma` |
| --- | --- | --- | --- |
| Direct normal-expression MO tail | Yes | No, structural form only | Yes |
| Dedicated MO helper/API | Yes | Yes | Yes |
| Regular `Floor[...]` on MO expression | Yes | No | No |
| Tungsten-style `In[n]` / `Out[n]` prompts | Yes | Yes | Yes |
| Variables with default zero | Yes | Yes | Yes |
| `%`, `%%`, `%n` history | Yes | Yes | Yes |
| Mathematica precision suffix on literals | Yes | Yes | No |
| Configurable precision | CLI, `N[...]`, `SetPrecision[...]` | `Precision = n`, literal suffixes | `--prec=n` |
| Output precision marks | Yes | Yes for non-machine scalar values | No |
| Exact ordinary rational substrate | Yes, via `Fraction` | No, `mpmath` scalar values | No, `Decimal` context |
| Structural tower representation | `TowerReal` | `PowerTower` | `Pow10Tower` |
| Landmark/tail result vocabulary | Sparse display and report text | `LeadingDigits` report object | `TowerLandmarkDecimal` |
| Installable package metadata | Yes | Yes | No |

## Acceptance Target Behavior

### Alpha

Alpha accepts the ordinary expression directly:

```text
10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))
```

At precision 30, the observed REPL output includes:

```text
10^10000000000 + 2811012357389.44071162781827848`30
correction precision: 30
omitted tail < 10^-9999999970
```

Alpha also supports regular `Floor[...]` over the same expression and returns
the sparse exact integer report:

```text
10^10000000000 + 2811012357389
precision: Infinity (exact sparse integer part)
stable floor: True
decimal shape: 1 followed by 9999999987 zeros, then 2811012357389
digits: 10000000001
```

This is the strongest current match for the calculator behavior requested in
the Nummy task thread.

### Beta

Beta's ordinary expression path does not recover the finite tail. It returns a
structural tower form, for example:

```text
10^^2(10.0)
```

or a nearby structural payload depending on session precision and evaluation
path. The important point is that the normal `^` expression path preserves
large-scale structure but does not expose the `2811012357389.4407...` tail.

Beta does recover the tail through the dedicated asymptotic builtin:

```text
LeadingDigits[5, 10]
```

At precision 30, the observed output reports the digit structure and returns:

```text
2811012357389.44071162781827848`30
```

This is the best mathematical engine behavior, but the strongest path is not
yet wired into ordinary expression evaluation.

### Gamma

Gamma also accepts the ordinary expression directly:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

At precision 120, the observed REPL output is:

```text
10^10^10 + 2811012357389.4407116278
```

Gamma's direct behavior is therefore good for the acceptance target. Its output
is less explicit than alpha's: the REPL does not print a precision mark, a
zero-run report, a digit-count report, or a `Floor[...]` result.

## Implementation Profiles

### Alpha

Alpha combines:

- `TowerReal`, a signed base-10 tower coordinate with a reciprocal bit and
  flags;
- `SparseDecimalInteger`, an exact representation for values such as
  `10^N + k`;
- `CalculatorValue`, a calculator wrapper carrying a tower value, display
  precision, optional exact `Fraction`, certification state, display override,
  and optional perturbation state;
- a parser/evaluator with `N[...]`, `SetPrecision[...]`, `Floor[...]`, history,
  assignment, default-zero variables, and precision syntax.

Strengths:

- Best current normal-syntax calculator behavior.
- Best current `Floor[...]` result for the MathOverflow expression.
- Exact rational arithmetic for ordinary scalar `+`, `-`, `*`, `/`, and
  integer-power cases that stay within the exact path.
- Standard-library-only dependency footprint.

Limits:

- The perturbation machinery is specialized around the MathOverflow-style
  base-10 tower path.
- The calculator module is dense: lexer, parser, evaluator, precision display,
  and perturbation hooks live together.
- Generic structural tower output is not a complete proof-grade decimal
  precision story yet.

### Beta

Beta separates:

- `PowerTower` for structural magnitude;
- `PerturbationSeries` for truncated small-parameter expansions;
- `AsymptoticTowerValue` for values of the form `scale * series(x)`;
- `LeadingDigits` and `compute_mo_expression` for structured MO-style reports;
- a tested parser/evaluator/REPL with precision state and function calls.

Strengths:

- Best current architecture for generalizing the perturbation derivation.
- Broadest and most modular test suite.
- Clean separation between structural scale and asymptotic correction.
- Explicit residual reporting in the `LeadingDigits[...]` path.

Limits:

- Ordinary expression evaluation does not currently route the MO expression to
  the asymptotic engine.
- Scalar precision is `mpmath` plus guard digits, not exact rational arithmetic
  or interval-certified arithmetic.
- `apply_pow10` on deferred-scale input is intentionally not implemented, so
  the asymptotic engine is not yet closed under arbitrarily longer tower chains.

### Gamma

Gamma centers on:

- `Pow10Tower(height, top)` for structural base-10 towers;
- `ExponentSum` and `Pow10Factor` for exponent bookkeeping;
- `TowerLandmarkDecimal` and `TowerDecimalDescription` for landmark-plus-tail
  output;
- a standalone script REPL that recognizes the MO tower during base-10 tower
  construction.

Strengths:

- Smallest and easiest to inspect.
- Clearest minimal "landmark plus finite tail" vocabulary.
- Direct ordinary-expression behavior for the MO target.
- Standard-library-only dependency footprint.

Limits:

- Narrow arithmetic: most non-scalar operations outside base-10 tower building
  are rejected.
- No precision suffix syntax, no precision marks in output, no `Floor[...]`,
  and no package metadata.
- Precision behavior is prototype-grade and not visibly certified at the REPL
  boundary.

## Prior-Art Alignment

The prior-art corpus has two major families relevant here:

- Practical huge-number libraries and calculators: `break_infinity.js`,
  `break_eternity.js`, `OmegaNum.js`, Hypercalc, and Python sketches.
- Direct or near-direct LI/SLI research implementations: `GSLI`,
  `level-index-simulator`, and `LIO`.

The Nummy experiments borrow the practical idea of structural scale
coordinates from the first family, but their distinguishing requirement is
finite-tail recovery near a tower landmark. A range-first layer/magnitude
library can represent the dominant magnitude, but that alone does not recover
the `2811012357389.4407...` correction.

The LI/SLI family is more relevant to the long-term arithmetic goal because it
treats extreme range as a numerical coordinate system rather than only a
display notation. However, none of alpha, beta, or gamma is yet a complete
LI/SLI engine with broad operation closure and systematic error propagation.

The useful lessons are:

- use structural log/exp coordinates for scale;
- treat huge and tiny magnitudes symmetrically where possible;
- do not claim ordinary decimal digits merely because a magnitude is
  representable;
- add special transformed-coordinate algorithms when local digits near a
  landmark matter.

## Theory Alignment

The theory corpus emphasizes repeated log/exp coordinates, symmetric handling
of tiny and huge values, arithmetic closure, and explicit precision/error
control. Against that lens:

| Theory theme | `alpha` | `beta` | `gamma` |
| --- | --- | --- | --- |
| Structural log/exp coordinates | Strong | Strong | Strong |
| Symmetric tiny/huge representation | Moderate, explicit reciprocal bit | Moderate | Limited |
| User-visible confidence semantics | Strongest, but incomplete for all structural cases | Moderate | Limited |
| Generalized perturbation machinery | Limited | Strongest | Limited |
| Broad LI/SLI arithmetic closure | Not yet | Not yet | Not yet |

The theory-aligned destination is not a pure incremental-game number type and
not an ad hoc one-expression calculator. It is a hybrid system with structural
scale, perturbation/asymptotic correction algebra, and a visible certainty
contract.

## Unified Recommendation

Use alpha as the user-facing baseline:

- preserve ordinary expression entry;
- preserve `Floor[...]` on sparse exact results;
- preserve explicit precision display where the implementation can justify it;
- keep exact rational scalar arithmetic for ordinary calculator paths.

Use beta as the computation-core baseline:

- promote the asymptotic series engine into the shared tower-near-landmark
  evaluator;
- make residual/error bounds explicit result data, not only text;
- route detected ordinary `^` tower expressions into this engine instead of
  requiring `LeadingDigits[...]`.

Use gamma as the result-vocabulary baseline:

- standardize a small `landmark + tail + zero-run + residual` result type;
- keep `Pow10Tower`-style clarity for compact structural representation;
- use the minimal model as a check against overcomplicated abstractions.

Add the missing common layer:

- a certainty/error object attached to every value;
- interval or symbolic residual bounds for tower-derived decimal output;
- conformance tests that require the ordinary expression path, not only a
  special helper, to reach the MO result;
- a small suite of additional high-dynamic-range workloads from the Nummy
  theory corpus.

## Final Ranking by Use Case

| Use case | Best current track | Reason |
| --- | --- | --- |
| Interactive calculator for the MO acceptance expression | `alpha` | Direct syntax, precision-marked correction, sparse exact `Floor[...]`. |
| Generalizing the perturbation derivation | `beta` | Explicit truncated-series architecture and broad tests. |
| Minimal API/model explanation | `gamma` | Compact `Pow10Tower` and landmark-tail representation. |
| Long-term Nummy foundation | Composite | Alpha surface, beta engine, gamma vocabulary, plus a new certainty layer. |

## Bottom Line

The five antecedent reports were right about the main shape: alpha, beta, and
gamma each capture a different necessary part of Nummy. The corrected and
deduplicated conclusion is:

- alpha should drive the calculator UX and exact sparse-output behavior;
- beta should drive the asymptotic/perturbation engine;
- gamma should influence the public landmark-tail vocabulary;
- none of the three should be described as a complete proof-grade LI/SLI
  arithmetic system yet.

The next Nummy milestone should be a deliberate synthesis rather than a winner
selection.
