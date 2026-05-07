# Nummy Alpha/Beta/Gamma Implementation Comparison

Created (UTC): 2026-04-28

This report reviews the three parallel Python implementations preserved under
`src/Tungsten/Nummy/src/` after merging `nummy/alpha`, `nummy/beta`, and `nummy/gamma`
into `main`.

The review scope is:

- `alpha/`: standard-library structural tower arithmetic plus a precision-aware
  calculator.
- `beta/`: asymptotic series tower arithmetic plus a calculator backed by
  `mpmath`.
- `gamma/`: compact structural tower and landmark-tail prototype plus a small
  standalone calculator.

The core acceptance target is the archived MathOverflow expression:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

The important behavioral question is not merely whether an implementation can
represent the dominant magnitude. It is whether it can recover the finite tail:

```text
10^10000000000 + 2811012357389.4407116278...
```

without materializing the impossible digit string.

## Executive Summary

`alpha` is currently the best candidate for the user-facing calculator track.
It accepts the normal expression form directly, carries a perturbative state
through ordinary `^` syntax, displays Wolfram-style precision marks, and
supports regular `Floor[...]` for the motivating expression. Its precision
contract is also the most conservative: ordinary layer-0 arithmetic is backed
by exact `Fraction` values, and uncertified tower decimals are marked with
precision `0` rather than silently printed as trustworthy digits.

`beta` has the strongest mathematical engine for generalizing the
MathOverflow derivation. Its asymptotic-series representation is richer than
alpha's first-order state, it has the broadest tests, and it exposes
`LeadingDigits[k, n]` for variants of `10^^k(-10^n)`. However, the REPL does
not recover the MathOverflow tail from the normal expression form. It only
gets the published tail through a special `LeadingDigits[...]` builtin, which
does not satisfy the project's strongest calculator requirement.

`gamma` is the smallest and clearest acceptance-test prototype. It does recover
the MathOverflow tail from the normal expression form, and the structural
`Pow10Tower` plus `TowerLandmarkDecimal` model is easy to inspect. It is also
the narrowest implementation: no package metadata, no precision marks in
output, no `Floor[...]`, no Mathematica precision syntax, and mostly scalar
arithmetic outside the recognized tower path.

The best next synthesis would use:

- alpha's REPL surface, exact display discipline, and normal-expression
  perturbation hook;
- beta's asymptotic series machinery and test breadth;
- gamma's compact `Pow10Tower` / landmark-tail vocabulary where a minimal API
  is helpful.

## Inventory

| Implementation | Files | Python files | Markdown files | Test files | Python LOC | Markdown lines | Dependencies |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `alpha` | 17 | 11 | 5 | 1 | 1799 | 337 | Python standard library |
| `beta` | 23 | 21 | 1 | 11 | 2681 | 211 | `mpmath>=1.3.0` |
| `gamma` | 12 | 8 | 4 | 5 | 889 | 165 | Python standard library |

Validation results from the merged tree:

| Implementation | Command | Result |
| --- | --- | --- |
| `alpha` | `python -m unittest discover -s tests` | 22 tests passed |
| `beta` | `python -m unittest discover -s tests` | 144 tests passed |
| `gamma` REPL tests | `python -m unittest discover -s tests` | 8 tests passed |
| `gamma` tower tests | `python -m unittest discover -s nummy_tower\tests` | 6 tests passed |

## Capability Matrix

| Capability | `alpha` | `beta` | `gamma` |
| --- | --- | --- | --- |
| Normal expression computes MO tail | Yes | No | Yes |
| Special helper for MO calculation | Yes, CLI/API also available | Yes, central path | Yes, API helper |
| `Floor[...]` for MO integer part | Yes | No | No |
| Tungsten-style `In[n]` / `Out[n]` REPL | Yes | Yes | Yes |
| Variables with default zero | Yes | Yes | Yes |
| `%`, `%%`, `%n` history | Yes | Yes | Yes |
| Mathematica precision suffix on literals | Yes | Yes | No |
| Configurable precision | CLI, `N[...]`, `SetPrecision[...]` | `Precision = n`, literal suffixes | `--prec=n` only |
| Output precision mark | Yes | Yes when not machine precision | No |
| Exact ordinary rational arithmetic | Yes, via `Fraction` | No, via `mpmath` values | No, via `Decimal` context |
| Structural tower representation | `TowerReal` | `PowerTower` | `Pow10Tower` |
| Perturbation model | First-order MO-oriented state | Truncated asymptotic series | First-order landmark-tail |
| Few-hundred-level structural towers | Yes | Yes | Yes structurally |
| Installable package metadata | Yes | Yes | No |
| Independent package-name conflict risk | `nummy` | `nummy` | Low, uses `nummy_tower` plus script |

## Acceptance Target Behavior

### Alpha

From `src/Tungsten/Nummy/src/alpha`:

```powershell
@'
10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))
Floor[10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))]
'@ | python -m nummy repl --no-banner --precision 30
```

Observed output includes:

```text
Out[1]= 10^10000000000 + 2811012357389.44071162781827848`30
correction precision: 30
omitted tail < 10^-9999999970

Out[2]= 10^10000000000 + 2811012357389
precision: Infinity (exact sparse integer part)
stable floor: True
decimal shape: 1 followed by 9999999987 zeros, then 2811012357389
digits: 10000000001
```

This is the strongest match for the project goal. The expression is typed in
the normal calculator syntax. No `MathOverflow[...]`, `MO[...]`, or
`LeadingDigits[...]` wrapper is needed. `Floor[...]` consumes the same regular
expression and returns the exact sparse integer part.

### Beta

From `src/Tungsten/Nummy/src/beta`, the normal expression:

```powershell
@'
10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))
'@ | python -m nummy
```

produces a structural approximation:

```text
Out[1]= 10^^2(9.9999999999999999999999999999999999999997386424354)
```

That value preserves magnitude information, but it does not recover the
`2811012357389.4407...` tail. Beta recovers the tail through its special
asymptotic builtin:

```text
LeadingDigits[5, 10]
```

which prints a structured report and returns:

```text
Out[n]= 2811012357389.44071162781827848`30
```

This is mathematically useful, but it is not the normal-expression calculator
behavior Vladimir explicitly asked for.

### Gamma

From `src/Tungsten/Nummy/src/gamma`:

```powershell
@'
10^(10^(10^(10^(10^(-10^10)))))
'@ | python gamma_repl.py --no-banner --prec=120
```

observed:

```text
Out[1]= 10^10^10 + 2811012357389.4407116278
```

Gamma therefore satisfies the direct normal-expression shape at the REPL
surface, but its output is less explicit than alpha's: it does not display a
precision mark, does not print the zero-run/digit-count report in the REPL,
and does not expose a regular `Floor[...]` path.

The gamma API can produce the structured decimal shape:

```text
Decimal expansion shape: starts with '1', then 9999999987 zeros, then
'2811012357389.4407116278'.
```

## Representation Choices

### Alpha: `TowerReal`, `SparseDecimalInteger`, and `CalculatorValue`

Alpha has the broadest integrated numeric domain:

- `TowerReal` is a signed, base-10 tower-coordinate value:
  - `sign`
  - `layer`
  - `mag`
  - `reciprocal`
  - `flags`
- `SparseDecimalInteger` represents exact values such as `10^N + k`.
- `CalculatorValue` wraps a tower value with:
  - a display precision,
  - an optional exact `Fraction`,
  - a `certified` bit,
  - an optional display override,
  - an optional `TowerPerturbationState`.

The important design choice is that the calculator layer is more conservative
than the tower layer. When ordinary arithmetic remains exact, alpha keeps a
`Fraction` and only rounds for display. When a tower operation is structural or
dominance-based rather than digit-certified, alpha avoids overclaiming.

The MO expression is recognized by value flow rather than by a named shortcut.
When the parser/evaluator sees the ordinary subexpression `10 ^ (-10 ^ 10)`,
it records a tiny perturbation state. Each enclosing `10 ^ ...` advances the
state. At the target height, formatting invokes the perturbation evaluator to
print:

```text
10^10000000000 + correction
```

and `Floor[...]` invokes the sparse integer path.

### Beta: `PowerTower`, `PerturbationSeries`, and `AsymptoticTowerValue`

Beta separates general magnitude representation from asymptotic propagation:

- `PowerTower(sign, layer, mag)` is a compact structural magnitude format.
- `PerturbationSeries` tracks truncated coefficients in a small parameter.
- `AsymptoticTowerValue` represents:

```text
scale * series(x)
```

where the scale can itself be deferred as a power tower. This is the most
mathematically extensible representation of the three, because it already has
the shape needed for higher-order Taylor propagation.

For the MO case, beta starts with `x = 10^-n` and applies `pow10` repeatedly
while carrying series coefficients. The final value decomposes into a dominant
`10^E` plus a finite correction. This is exactly the family of machinery Nummy
will need if it grows beyond the one archived expression.

The main weakness is surface integration. The REPL evaluator's ordinary `^`
path uses `PowerTower` formatting for huge magnitudes, while the asymptotic
engine is reached through `LeadingDigits[k, n]`. In other words, the strongest
engine and the ordinary expression parser are not yet unified.

### Gamma: `Pow10Tower`, `ExponentSum`, `Pow10Factor`, and `TowerLandmarkDecimal`

Gamma is the cleanest minimal model:

- `Pow10Tower(height, top)` structurally represents `10^^height(top)`.
- `ExponentSum` records integer plus tower exponent terms and cancels identical
  terms.
- `Pow10Factor` represents `coeff * 10^exp`.
- `TowerLandmarkDecimal` represents `landmark + tail`.
- `TowerDecimalDescription` renders the decimal-shape report.

This model is small and easy to reason about. It is useful as a prototype of
the "landmark plus finite tail" abstraction. The REPL recognizes the exact MO
tower shape while building structural base-10 towers and routes it to
`compute_pow10_tower_small_bottom_linear`.

The tradeoff is narrowness. Arithmetic outside finite `Decimal` scalars and
base-10 tower construction is intentionally absent. It is not a general
calculator yet.

## Precision and Correctness

### Alpha

Alpha has the best precision discipline.

For ordinary calculator arithmetic over literals, `+`, `-`, `*`, `/`, and
integer powers, the evaluator keeps exact `Fraction` values. The requested
precision affects display, not computation. That is the strongest basis among
the three for the requirement that displayed decimal digits within a claimed
precision are correct.

For tower values, alpha distinguishes certified ordinary decimals from
structural approximations. It marks uncertified structural output with
precision `0` rather than pretending to have decimal digits. The MO perturbation
path includes a stability report for the floor, including the omitted-tail
bound.

Remaining gap: the perturbation proof is specialized. Alpha does not yet have a
general interval or higher-order error algebra for arbitrary tower expressions.

### Beta

Beta has precision annotations and uses guard digits:

- exact integer literals are treated as exact;
- floating literals use session precision unless they carry a backtick suffix;
- result precision is usually the minimum operand precision;
- `GUARD_DIGITS = 10` is added to the working precision.

This is familiar and practical, but it is not a proof-grade precision contract.
`mpmath` arithmetic with guard digits can make displayed digits reliable for
well-conditioned calculations, but cancellation and boundary cases can defeat
it. The code comments acknowledge that heavy cancellation can still defeat the
guard-digit approach.

For the MO path, beta does report a residual bound for dropped higher-order
terms. That part is valuable, but it is attached to `LeadingDigits[...]`, not
to ordinary expression evaluation.

### Gamma

Gamma has configurable `Decimal` context precision through `--prec=n`, but it
does not display precision marks. Scalar decimal arithmetic is rounded by the
active `Decimal` context, not preserved as exact rationals.

The MO path computes a finite tail with `Decimal` and prints a fixed number of
fractional digits. It does not currently state the claimed precision in output.
One concrete edge observed during review: calling
`compute_mo_1010101010_1010(precision=80, frac_digits=20)` raises
`decimal.InvalidOperation` during quantization, while the tested
`precision=120, frac_digits=10` path succeeds. That is a precision budgeting
bug or at least an API contract gap.

## Parser and REPL Surfaces

### Alpha

Alpha implements the most complete requested calculator surface:

- integer and floating-point literals;
- Mathematica-style precision suffixes;
- `*^` exponent notation;
- `+`, `-`, `*`, `/`, `^`;
- assignment;
- default-zero variables;
- `%`, `%%`, and `%n`;
- `N[...]`;
- `SetPrecision[...]`;
- `Floor[...]`;
- CLI default precision.

Its REPL has Tungsten-like prompts and supports `Quit`, `Quit()`, `Exit`, and
`Exit()`. It does not currently accept `Quit[]`, which appears as an unsupported
function because square-bracket calls are reserved for calculator functions.

### Beta

Beta has a clean lexer/parser split and more AST structure than alpha:

- tokenization and parsing are separately tested;
- function calls are part of the grammar;
- precision is a session variable, `Precision`;
- `MachinePrecision` is read-only;
- the `LeadingDigits[k, n]` builtin is wired through the same function-call
  mechanism.

The surface is internally tidy and well tested, but two details matter:

- ordinary expression evaluation does not enter the asymptotic engine;
- `--no-banner` was not effective in the observed `python -m nummy --no-banner`
  run, while the underlying `run_repl` helper does accept `show_banner=False`.

### Gamma

Gamma is compact and script-shaped:

- decimal/integer literals;
- `+`, `-`, `*`, `/`, `^`;
- assignment;
- default-zero variables;
- `%`, `%%`, `%n`, and repeated percent history;
- `--prec=n`;
- `--no-banner`;
- `quit`, `quit()`, `exit`, and `exit()`.

It deliberately omits:

- precision suffixes;
- scientific notation;
- functions;
- `Floor`;
- package install metadata;
- precision marks in output.

## Test Coverage

`alpha` has one consolidated test file with 22 tests. It covers:

- structural `pow10`/`log10`;
- dominance reporting;
- sparse decimal integers;
- the MO integer-part result;
- exact rational calculator operations;
- precision syntax;
- `Floor[...]`;
- direct normal-expression MO display;
- REPL prompts and history.

`beta` has the broadest test suite with 144 tests across 11 files. It covers:

- tower formatting and edge cases;
- perturbation series identities;
- asymptotic propagation;
- MO leading-digit result;
- lexer, parser, evaluator, function calls, precision propagation;
- REPL summary printing;
- variations of the asymptotic driver.

`gamma` has 14 tests split between REPL and tower package tests. It covers:

- scalar arithmetic and precedence;
- right-associative power;
- unary binding;
- default variables and history;
- direct recognition of the MO expression;
- structural tower helpers;
- exponent-sum cancellation;
- the MO tail prefix and zero count.

Beta has the most comprehensive test net. Alpha has the best tests for the
exact user-facing requirement. Gamma's tests are intentionally compact but do
hit its acceptance path.

## Maintainability

### Alpha

Alpha is cohesive but dense. The calculator module is large and carries lexer,
parser, evaluator, formatting, precision, and perturbation hooks in one file.
That made it fast to integrate the surface, but future growth would benefit
from splitting:

- tokens and parser;
- exact arithmetic value model;
- structural tower arithmetic adapter;
- formatting and precision contract;
- perturbation recognizers/evaluators.

Its biggest maintainability advantage is that user-visible behavior is already
where it belongs: ordinary syntax, ordinary `Floor`, and ordinary precision
marks.

### Beta

Beta is the cleanest architecturally. Its files have crisp roles:

- `tower.py`
- `series.py`
- `asymptotic.py`
- `leading_digits.py`
- `mo.py`
- `calc.py`
- `repl.py`

The main maintainability risk is conceptual split-brain: the calculator and
the asymptotic engine coexist, but the normal expression evaluator does not
route the motivating expression to the asymptotic machinery. Fixing that would
likely make beta a much stronger contender.

### Gamma

Gamma is readable and teachable. The downside is that its narrowness is encoded
directly into the evaluator. The special MO recognition is in `_value_pow`,
which is fine for a prototype but would become awkward as soon as there are
multiple perturbation patterns, multiple bases, or more than one output mode.

Gamma's `nummy_tower` package is a useful extraction candidate even if the
standalone REPL remains a prototype.

## Risks and Gaps

### Shared Repository Risk

Both alpha and beta publish a top-level package named `nummy`. They coexist in
the repository because they live in separate directories, but they cannot both
be installed into the same Python environment as `nummy` without one shadowing
the other. This is acceptable for preserved experiments, but a unified Nummy
track should choose one package root or rename experimental packages.

### Mathematical Generality

None of the three is a complete LI/SLI implementation. All three represent
large towers structurally, but generic arithmetic between arbitrary same-scale
tower values remains limited.

Alpha handles dominance and exact low-level arithmetic well, but its
perturbation machinery is specialized.

Beta has the best path toward generalized perturbation algebra, but it does not
yet propagate through deferred-scale inputs beyond the motivating level-5 case.

Gamma is intentionally first-order and acceptance-test-driven.

### Proof-Grade Precision

The user-facing requirement is stronger than "high precision arithmetic":
displayed decimal digits within the claimed precision should be provably
correct, modulo the repeated-9/repeated-0 carry cascade caveat.

Alpha is closest because exact rational arithmetic underlies its ordinary
decimal displays. However, the generic tower side still needs interval or
symbolic error tracking before every printed tower-derived decimal can be
certified.

Beta and gamma should not yet claim proof-grade precision for all displayed
digits. Beta's guard digits are pragmatic, and gamma does not display claimed
precision at all.

## Conclusions

For a user-facing Nummy calculator, `alpha` is the best branch to continue from.
It already satisfies the critical "normal expression form" requirement:

```text
10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))
```

prints the expected landmark-plus-tail form, and regular:

```text
Floor[...]
```

returns the exact sparse integer part.

For the mathematical core, `beta` contains the best machinery to harvest. Its
asymptotic series code, residual reporting, and broader tests are the strongest
foundation for moving from one special derivation to a family of perturbative
tower computations.

For explanatory prototypes and API vocabulary, `gamma` is useful. Its
`Pow10Tower`, `Pow10Factor`, and `TowerLandmarkDecimal` types express the core
idea in the fewest moving parts.

The recommended synthesis is:

1. Keep alpha's REPL syntax and precision-display contract as the user-facing
   baseline.
2. Replace alpha's narrow perturbation evaluator with a beta-style truncated
   series engine, preferably with explicit interval or residual bounds.
3. Preserve gamma's landmark-tail vocabulary as a small public result type, or
   at least use it as the conceptual model for structured output.
4. Add tests that force the ordinary expression evaluator, not a special
   function, to reach the asymptotic path.
5. Add a shared precision-certification layer before claiming arbitrary
   proof-grade decimal precision for tower-derived values.

In short: alpha has the right UX skeleton, beta has the most promising engine,
and gamma has the clearest minimal model. The eventual Nummy implementation
should not choose one by wholesale adoption; it should fuse those three
specific strengths.
