# Tungie Language And REPL Proposal

- Status: Draft design proposal for a canonical Nummy calculator interpreter
- Audience: Nummy maintainers, Tungsten maintainers, REPL implementers, large-number arithmetic
  test authors
- Scope: `Engine/Nummy/src/`, replacing the alpha, beta, and gamma calculator REPL surfaces
  with one lightweight implementation contract
- Created (UTC): 2026-04-29T02:15:00Z
- Repository HEAD: c027a81817bb36b22d231d0558c6d73fe75b6eab
- Related code:
  - `Engine/Nummy/src/alpha/nummy/calculator.py`
  - `Engine/Nummy/src/alpha/nummy/repl.py`
  - `Engine/Nummy/src/beta/nummy/calc.py`
  - `Engine/Nummy/src/beta/nummy/repl.py`
  - `Engine/Nummy/src/gamma/gamma_repl.py`
  - `Engine/Nummy/src/gamma/nummy_tower/`
  - `Engine/src/tungsten/expression_parser.py`
  - `Engine/src/tungsten/repl.py`
- Related docs:
  - [Nummy Alpha/Beta/Gamma Unified Comparison](alpha-beta-gamma-unified-comparison.md)
  - [Tungsten Expression Parser](../../../docs/expression-parser.md)
  - [Tungsten REPL](../../../docs/repl.md)
  - [Tungsten Numeric Tower](../../../docs/numeric-tower.md)
  - [Overflow And Underflow Large-Number Fallback Design](../../../docs/overflow-underflow-large-number-fallback.md)

## Summary

Tungie is the proposed canonical calculator language and REPL for Nummy. It should replace the
three makeshift alpha, beta, and gamma REPLs with one small, well-tested interpreter that borrows
the durable parts of Tungsten's Wolfram-like expression model without depending on Tungsten's
runtime, symbol registry, parser corpus, notebook tooling, Wolfram installation discovery, SymPy
bridge, or other heavy machinery.

The target is a serious calculator, not a toy prompt loop. Tungie should support ordinary
calculator arithmetic, exact integer and rational work, precision-marked decimal work, session
history, assignments, compact structural large-number values, and enough diagnostic built-ins to
investigate why an astronomically large or small Nummy value has the digits, scale, precision, and
residual bounds it claims. The design must stay honest about precision: if a digit is not certified
by exact arithmetic, an interval, or a residual bound, Tungie must not print it as a trusted digit.

## Design Position

Tungie is a lightweight subset of Tungsten in three senses:

- It uses Tungsten/Wolfram textual conventions where they are directly useful: `Out[n]=`, `%`
  history, `Head[args]`, precision marks, `N`, `SetPrecision`, and right-associative `^`.
- It keeps the same fail-closed posture: unsupported branch-sensitive or insufficiently certified
  operations return an inert expression or a diagnostic `Failure[...]` value instead of pretending
  to know a result.
- It does not import Tungsten. The Nummy arithmetic core should be plain Python dataclasses and
  small services that can be tested without a Wolfram installation, without Tungsten's parser
  corpus, and without optional mathematical packages.

The implementation should live as a new canonical package, for example
`Engine/Nummy/src/tungie/`, with the old alpha, beta, and gamma tracks left as reference
experiments until the canonical test suite covers their retained behaviors.

## Goals

- Provide one canonical Nummy calculator REPL with deterministic parser, evaluator, formatter, and
  transcript behavior.
- Keep the runtime dependency baseline at Python standard library only.
- Preserve alpha's direct ordinary-expression path for the archived MathOverflow tower and
  alpha's sparse exact `Floor[...]` behavior.
- Preserve beta's asymptotic and residual-bound discipline, but expose it through ordinary
  expression evaluation instead of a mandatory one-off helper.
- Preserve gamma's compact `landmark + tail` vocabulary as a first-class value contract.
- Make very large and very small values inspectable: users should be able to see representation
  kind, sign, scale, tower layer, certified precision, residual bounds, dominance decisions, and
  sparse decimal shape.
- Define enough syntax and built-ins that later Tungsten integration can call Tungie as a small
  numeric substrate instead of scraping REPL text.

## Non-Goals

- Tungie is not a full Wolfram Language implementation.
- Tungie is not Tungsten's parser or evaluator with modules removed.
- Tungie does not parse notebooks, boxes, pattern definitions, replacement expressions, pure functions,
  packages, contexts, attributes, or arbitrary Wolfram source files.
- Tungie does not perform general symbolic simplification, equation solving, integration,
  differentiation, or special-function numerics.
- Tungie does not require `mpmath`, SymPy, NumPy, Wolfram, or Tungsten at runtime. Optional backends
  may be added later behind explicit interfaces, but the canonical tests for the required surface
  must pass without them.
- Tungie does not materialize exact integers or dense decimal renderings beyond configured safety
  limits.

## Value Model

The evaluator should use one small value hierarchy. The names below are descriptive; exact class
names can change, but the concepts should be stable.

| Value kind | Meaning | Required behavior |
| --- | --- | --- |
| `ExactInteger` | Arbitrary-size Python integer below materialization limits, or a sparse exact integer when dense form is unsafe. | Exact arithmetic, `Precision` is `Infinity`, exact comparisons. |
| `ExactRational` | Normalized fraction of exact integers. | Exact `+`, `-`, `*`, `/`, integer powers, exact `Floor`. |
| `FiniteDecimal` | Decimal interval or exact decimal text with explicit precision/accuracy metadata. | Decimal arithmetic with certified precision no higher than the inputs and working proof. |
| `ScientificScale` | Sign, certified mantissa interval, and base-10 exponent that may itself be large. | `10.^400`, `10.^-400`, ordinary overflow/underflow investigation. |
| `Pow10Tower` | Structural base-10 repeated exponent/log coordinate. | Compact representation of `10^(10^(...))`, structural `Pow10` and `Log10`. |
| `LandmarkTail` | A recognized landmark plus a finite tail and residual bound. | MathOverflow-style `10^10000000000 + 2811012357389.4407...` values. |
| `SparseDecimalInteger` | Exact decimal shape such as `10^N + k` without storing `N` zero characters. | Stable `Floor` results, digit counts, prefix/suffix extraction. |
| `Failure` | Structured diagnostic result for parseable but invalid evaluation. | Stored in history, inspectable, never silently coerced to `0`. |
| `InertExpression` | Parsed expression whose head or operation is outside Tungie's supported evaluator subset. | Round-trips through parseable constructor text; numeric consumers reject it. |

Every numeric value must carry a `Certainty` record:

- input precision;
- working precision or exact provenance;
- certified precision;
- optional absolute accuracy;
- residual or interval bound;
- whether display digits were rounded, truncated, or suppressed;
- a reason when certified precision is `0`.

This certainty record is part of the semantic value, not only formatter state. Built-ins such as
`Precision`, `Accuracy`, `CertifiedDigits`, `ResidualBound`, and `Representation` read it directly.

## Syntax Subset

Tungie should parse one REPL input at a time. The parser should be Pratt or recursive-descent, but
the grammar must be specified and tested as a contract.

### Lexical Forms

Required tokens:

- identifiers: `x`, `foo2`, `$Precision`, `$MaxExactIntegerDigits`;
- exact integers: `0`, `123`, `10000000000`;
- decimals: `1.`, `.5`, `1.25`, `1e6`, `1.25e-6`, `1.25*^6`;
- precision and accuracy marks:

  ```text
  1.25`30
  1.25`
  1.25``20
  ```
- history references: `%`, `%%`, `%%%`, `%1`, `%25`;
- punctuation: `()`, `[]`, `{}`, `,`, `;`;
- operators: `+`, `-`, `*`, `/`, `^`, `=`, `<`, `<=`, `>`, `>=`, `==`, `!=`, `&&`,
  `||`, `!`;
- nested Wolfram comments: `(* ... *)`.

Base-number literals such as `16^^ff` should be accepted for exact integers and finite decimals
because Tungsten already accepts them, but Tungie should not use `10^^5(x)` as canonical input
syntax for power towers. That spelling is too easy to confuse with base notation. Use
`Pow10Tower[5, x]` or `PowerTower[10, 5, x]` for parseable input, and reserve compact
`10^^5(x)` for non-parseable display text if desired.

### Expressions

Required expression forms:

```text
input          := statement | statement ';' | statement (';' statement)+
statement      := assignment | expression
assignment     := symbol '=' expression
expression     := logical-or
logical-or     := logical-and ('||' logical-and)*
logical-and    := comparison ('&&' comparison)*
comparison     := additive (('<' | '<=' | '>' | '>=' | '==' | '!=') additive)*
additive       := multiplicative (('+' | '-') multiplicative)*
multiplicative := unary (('*' | '/') unary | implicit-times unary)*
unary          := ('+' | '-' | '!') unary | power
power          := primary ('^' unary)?
primary        := literal | symbol | history | call | list | '(' expression ')'
call           := head '[' argument-list? ']'
list           := '{' argument-list? '}'
argument-list  := expression (',' expression)*
```

Precedence should follow Tungsten/Wolfram for the calculator subset:

- `^` is right-associative: `2^3^2` is `2^(3^2)`.
- unary minus binds outside power in base position: `-10^2` is `-(10^2)`.
- unary minus binds inside the exponent after `^`: `10^-2` is `10^(-2)`.
- implicit multiplication is supported for `2 x`, `2(x + 1)`, and `(x + 1)(x - 1)`.
- chained comparisons evaluate as conjunctions only when all individual comparisons are certified.

### Statements And Session State

Supported statements:

- `expr`: evaluate and print the result;
- `name = expr`: immediate assignment of the evaluated result;
- `Clear[name]`: remove a user assignment;
- `expr;`: evaluate and store the result but suppress printing;
- `expr1; expr2`: evaluate left to right and return the last non-suppressed result.

Unbound symbols should evaluate to symbolic `InertExpression` values, not `0`. The three prototype
REPLs default unassigned variables to zero, but Tungie should choose the Tungsten-like behavior
because it catches misspellings and makes symbolic inspection possible. A compatibility setting can
exist later, but it should not be the default.

## Built-In Symbols

The required built-in set should stay small enough to test exhaustively.

### Session And Output

| Symbol | Contract |
| --- | --- |
| `Out[n]`, `Out[]`, `Out[-k]` | Stored output values, including `Failure` values. |
| `%`, `%%`, `%n` | Parser shorthand for `Out[-1]`, `Out[-2]`, and `Out[n]`. |
| `Exit` | End the REPL; optional integer argument becomes process exit code. |

### Core Forms

| Symbol | Contract |
| --- | --- |
| `Set` / `=` | Immediate assignment; holds the left-hand symbol and evaluates the right side. |
| `Clear` | Removes user bindings for one or more symbols. |
| `If` | Evaluates only the selected branch when the condition is exactly `True` or `False`. |

### Numeric Constants And Markers

| Symbol | Contract |
| --- | --- |
| `Pi`, `E`, `Degree` | Numericizable constants for finite precision requests. They may stay symbolic until passed to `N`. |
| `Infinity`, `-Infinity`, `Indeterminate` | Non-finite markers for diagnostic and boundary behavior. |
| `Overflow[]`, `Underflow[]` | Explicit diagnostic atoms, distinct from finite large/tiny values produced by Nummy fallback. |
| `$MachinePrecision`, `$MaxMachineNumber`, `$MinMachineNumber`, `$MachineEpsilon` | Host-machine reference constants for ordinary float comparison. |
| `$Precision` | Mutable session precision, initially `16`, for numeric operations that need an approximation when precision is not otherwise specified. `N[expr, p]` temporarily evaluates `expr` with `$Precision` set to `p`. |

### Arithmetic And Elementary Numerics

| Symbol | Contract |
| --- | --- |
| `Plus`, `Subtract`, `Times`, `Divide`, `Power` | Operator-backed arithmetic over exact, decimal, structural, and landmark-tail values. |
| `Abs`, `Sign` | Sign and magnitude helpers when sign is certified. |
| `Floor`, `Ceiling`, `Round`, `IntegerPart`, `FractionalPart` | Exact or certified interval-based rounding. Unsafe cases return `Failure` or stay inert. |
| `Sqrt`, `Exp`, `Log`, `Log10`, `Pow10` | Required elementary subset. `Pow10` and `Log10` must use structural tower shifts where possible. |
| `Min`, `Max` | Certified comparisons only; uncertain comparisons stay inert or return `Failure`. |

### Precision And Conversion

| Symbol | Contract |
| --- | --- |
| `N[expr]`, `N[expr, p]` | Numeric approximation. Requests certified precision; does not inflate uncertified payloads. |
| `SetPrecision[expr, p]` | Lowers or requests recomputation of precision. It cannot certify new digits by metadata alone. |
| `SetAccuracy[expr, a]` | Accuracy analogue of `SetPrecision`. |
| `Precision[expr]` | `Infinity` for exact values, finite certified precision for certified inexact values, `0` for scale-only values, inert for nonnumeric expressions. |
| `Accuracy[expr]` | Absolute digit count when derivable from precision and scale. |
| `Rationalize[expr]` | Exact rational recovery only when the value's interval or decimal provenance justifies it. |
| `Normal[expr]` | Materializes to ordinary dense integer/decimal only under configured digit limits. |

### Nummy Large-Number Constructors

| Symbol | Contract |
| --- | --- |
| `Pow10Tower[h, top]` | Structural value for `10` exponentiated `h` times over `top`. |
| `PowerTower[base, h, top]` | General constructor reserved for future non-base-10 towers; base `10` required initially. |
| `ScientificScale[sign, mantissa, exponent]` | Explicit scale-coordinate value for overflow/underflow debugging. |
| `LandmarkTail[landmark, tail, residual]` | Parseable constructor for landmark-tail diagnostic values. |
| `SparseDecimalInteger[terms...]` | Parseable exact sparse decimal integer constructor, primarily emitted by `Floor`. |

These constructors are the parseable representation for tests and external tooling. The default
REPL display can be prettier, but it must never be the only representation of a value.

### Large-Number Diagnostics

| Symbol | Contract |
| --- | --- |
| `Representation[expr]` | Returns `ExactInteger`, `ExactRational`, `FiniteDecimal`, `ScientificScale`, `Pow10Tower`, `LandmarkTail`, etc. |
| `CertifiedDigits[expr]` | Returns the certified relative digit count or `0`. |
| `ResidualBound[expr]` | Returns the residual/error bound when present. |
| `Scale10[expr]` | Returns a base-10 scale coordinate when certified. |
| `Layer[expr]` | Returns tower layer/height for structural tower values. |
| `MantissaExponent[expr]` | Returns a certified scientific mantissa/exponent pair when available. |
| `Landmark[expr]`, `Tail[expr]` | Accessors for `LandmarkTail`. |
| `DigitCount[expr]` | Exact digit count for exact or sparse integers; inert otherwise. |
| `LeadingDigits[expr, n]`, `TrailingDigits[expr, n]` | Certified digit extraction only. |
| `DecimalShape[expr]` | Compact sparse shape such as one leading `1`, a zero-run count, and a suffix. |
| `StableFloorQ[expr]` | `True` only when `Floor[expr]` is certified stable under the residual bound. |
| `DominanceReport[expr]` | Explains discarded addends or multiplicative scale decisions. |
| `TraceEvaluation[expr]` | Returns a bounded evaluation trace focused on numeric representation transitions. |

`TraceEvaluation` is important for debugging Nummy. It should show, for example, that
`10^(10^(10^(10^(10^(-10^10)))))` starts as ordinary nested `Power`, converts the tiny bottom to a
reciprocal tower coordinate, advances through base-10 tower layers, recognizes the landmark-tail
regime, attaches a residual bound, and only then formats the finite correction digits.

## Evaluation Rules

### Evaluation Order

Evaluation is deterministic and session-local:

1. Parse one input into a Tungie AST.
2. Evaluate held heads according to their fixed built-in rules.
3. Evaluate ordinary function arguments before dispatch unless the head is a held built-in.
4. Apply arithmetic, precision, listable, and diagnostic rules.
5. Store the resulting value, inert expression, or `Failure` in `Out[n]`.
6. Render the result without changing the stored `Out[n]` value.

Syntax errors do not advance the prompt counter because there is no parsed expression to store.
Evaluation failures should produce structured `Failure[...]` outputs whenever the input parsed
successfully, so users can inspect the failure and history remains reproducible.

### Unknown Symbols And Heads

Unbound symbols evaluate to themselves. Unknown function heads evaluate their arguments normally
and then remain inert unless the head has a built-in rule. Numeric consumers such as `N`, `Floor`,
and `Scale10` reject inert expressions with a `Failure` explaining which head made the expression
nonnumeric.

This is intentionally closer to Tungsten than to the current Nummy prototypes. Default-zero
variables make short demos convenient, but they hide misspellings and make expression-level
debugging harder.

### Exact Arithmetic

Exact integer and rational arithmetic is closed under:

- `+`, `-`, `*`, `/`;
- integer powers and rational powers whose result is an exact rational;
- exact comparisons;
- `Floor`, `Ceiling`, `Round`, `IntegerPart`, and `FractionalPart`.

Exact `Power` has calculator-oriented identities before approximate fallback:
`base^0` evaluates to exact `1`, including `0^0`; `1^exponent` evaluates to
exact `1`; and `0^exponent` evaluates to exact `0` for positive numeric
exponents. Exact numeric powers outside those identities and outside the exact
rational-result cases are approximated using the current `$Precision`.

Exact integer powers must estimate dense digit count before allocating. If a result would exceed
`$MaxExactIntegerDigits`, Tungie returns a sparse exact value or a structural power expression
instead of constructing the dense Python integer.

### Inexact Decimal Arithmetic

Finite decimal arithmetic uses exact decimal input provenance plus a working interval or guard
precision. The result precision is bounded by the minimum input precision after exact operands are
ignored for precision loss. Heavy cancellation can reduce certified precision; if the evaluator
cannot prove the displayed digits, it must reduce the precision mark or return a scale-only value
with certified precision `0`.

Unmarked decimal literals should have machine-precision semantics by default. They may be stored as
decimal text rather than binary `float`, but their certified precision must not exceed
`$MachinePrecision`.

### Large And Tiny Scale Arithmetic

Tungie must treat overflow and underflow as finite scale information whenever the operation has
finite operands and the mathematical result is nonzero:

- `10.^400` should produce a finite `ScientificScale`, not `Overflow[]`.
- `10.^-400` should produce a finite tiny `ScientificScale`, not `0`.
- explicit `Overflow[]` and `Underflow[]` input atoms keep diagnostic marker semantics and are not
  automatically reinterpreted as hidden finite numbers.

Multiplication and division combine log-scale coordinates. Addition and subtraction use exact or
interval arithmetic when operands share a scale, and dominance rules when certified scale separation
makes one addend irrelevant to the requested precision. If neither path is certified, return an
inert `Plus[...]` or `Failure[...]` with a dominance diagnostic.

### Power And Towers

`Power` is the load-bearing operation:

- exact small integer powers stay exact;
- exact huge integer powers become sparse or structural before allocation;
- `10^x` routes to `Pow10[x]` so tower shifts and tiny reciprocal values remain structural;
- nested base-10 powers are recognized from evaluated structure, not from source text;
- positive finite non-integer powers may use `Exp[exponent * Log[base]]` only when the branch and
  precision contract are clear;
- negative bases with non-integer exponents are out of the required real subset.

The MathOverflow acceptance expression must work through ordinary syntax:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

It must not require a visible `MO[...]` or `LeadingDigits[5, 10]` helper. The recognizer should
notice the evaluated base-10 tower shape and produce a `LandmarkTail` value:

```text
10^10000000000 + 2811012357389.44071162781827848... with a residual bound
```

`LeadingDigits` can still exist as a diagnostic accessor, but the ordinary expression path is the
canonical behavior.

### Floor And Sparse Integers

`Floor[x]` returns an exact integer only when the floor is certified:

- exact rationals are always certified;
- finite decimal intervals are certified when the interval does not cross an integer boundary;
- `LandmarkTail` values are certified when the residual bound cannot change the integer part;
- scale-only tower values without local digits are not certified.

For the MathOverflow expression, `Floor` should return a sparse exact decimal integer whose default
display is compact:

```text
10^10000000000 + 2811012357389
```

`DecimalShape[%]` should expose the exact shape:

```text
DecimalShape[LeadingDigit[1], ZeroRun[9999999987], SuffixDigits[2811012357389], DigitCount[10000000001]]
```

If dictionary-style records are deferred, the same information can be returned as a parseable
`DecimalShape[...]` expression. The semantic requirement is that tests can assert the fields
without parsing a prose report.

### Lists And Listable Operations

Lists are required because they make calculator experiments and regression fixtures much smaller:

```text
N[{1/3, 1/7, 10.^400}, 40]
Precision[values]
```

Tungie does not need full `Map` or pure functions in the first canonical surface. Instead, built-ins
marked as listable should thread over lists of the same shape. `Plus`, `Times`, `Power`, `N`,
`Precision`, `Accuracy`, `Scale10`, and the diagnostic accessors should be listable. Shape
mismatches produce `Failure`, not silent truncation.

## REPL Contract

The REPL should have one transcript format:

```text
Tungie 0.x - Nummy calculator
In[1]:= 1 / 3

Out[1]= 0.3333333333333333`16

In[2]:= N[%, 50]

Out[2]= 0.33333333333333333333333333333333333333333333333333`50
```

Required behavior:

- prompt format is `In[n]:= `;
- result prefix is `Out[n]= `;
- blank input does not advance line number;
- syntax errors report to stderr and repeat the prompt;
- parseable evaluation failures return `Failure[...]` in `Out[n]`;
- `Exit` and `Exit[]` exit with code `0`;
- `Exit[n]` exits with integer code `n`;
- history references use stored values, not rendered text;
- report and sparse values are storable in history and rejected explicitly when a later arithmetic
  operation cannot consume them.

## Dependency Boundary

The required implementation must use only the Python standard library:

- `dataclasses` for value payloads;
- `decimal` for finite decimal arithmetic and guard contexts;
- `fractions` for exact rational arithmetic;
- `math` only for bounded machine-reference constants and low-precision finite helpers;
- `unittest` for baseline tests.

Optional packages can be explored behind feature flags:

- `mpmath` for wider elementary finite functions;
- `gmpy2` or MPFR for faster high-precision finite coefficients;
- SymPy for separate comparison tooling.

The canonical Tungie runtime and required test suite must not require those packages. If optional
backends are present, conformance tests should prove that they do not change certified results for
the required cases.

## Test Strategy

Tungie should be test-first around behavior, not just implementation details. The canonical suite
should include these groups:

| Test group | Required coverage |
| --- | --- |
| Lexer/parser | Numeric literal forms, comments, precedence, right-associative power, unary-minus precedence, implicit multiplication, function calls, lists, assignments, history tokens. |
| Session/REPL | Prompt text, line numbering, blank lines, syntax errors, evaluation failures, `%`/`%%`/`%n`, `Out`, `Exit`. |
| Exact arithmetic | Integer/rational operations, exact `Floor`, dense-allocation guards, sparse integer output. |
| Precision | Literal precision/accuracy marks, `N`, `SetPrecision`, cancellation lowering, no precision inflation, listable precision accessors. |
| Scale arithmetic | `10.^400`, `10.^-400`, multiplication/division overflow and underflow, explicit `Overflow[]` marker preservation. |
| Tower arithmetic | `Pow10Tower`, structural `Pow10`/`Log10`, tower height preservation, dominance decisions. |
| Landmark-tail | Ordinary MathOverflow expression path, tail prefix, residual bound, `Floor`, `StableFloorQ`, `DecimalShape`. |
| Diagnostics | `Representation`, `CertifiedDigits`, `ResidualBound`, `Scale10`, `Layer`, `DominanceReport`, `TraceEvaluation`. |
| Formatting | Default display text plus parseable constructor text for every value kind. |
| Prototype parity | Retained alpha/beta/gamma behaviors captured as fixtures, with intentional divergences such as no default-zero variables named explicitly. |

The MathOverflow regression should assert structured fields, not only rendered text fragments:

- landmark is `10^10000000000`;
- correction integer prefix is `2811012357389`;
- requested certified tail begins with `44071162781827848` when enough precision is requested;
- residual bound is below the threshold needed for stable floor;
- floor is the sparse integer `10^10000000000 + 2811012357389`;
- dense decimal materialization is refused.

## Relationship To The Existing Prototypes

The prototypes should be mined, not merged mechanically.

| Prototype | Keep | Replace |
| --- | --- | --- |
| Alpha | Direct ordinary-expression MathOverflow path, exact rational scalar arithmetic, precision-marked output, sparse exact `Floor`. | Dense combined calculator module, report-only diagnostic values, default-zero variables. |
| Beta | Parser/test modularity, precision setting discipline, perturbation/residual machinery, `LeadingDigits` report content. | Mandatory `LeadingDigits[5, 10]` path for the core scenario, `mpmath` as required runtime dependency. |
| Gamma | Compact `Pow10Tower` and `LandmarkTail` vocabulary, small inspectable evaluator. | Narrow scalar-only arithmetic, missing precision marks, hard-coded MathOverflow recognition shape. |

The resulting Tungie should have fewer concepts than all three prototypes combined, but stronger
contracts around the concepts it keeps.

## Implementation Shape

Recommended package layout:

```text
Engine/Nummy/src/tungie/
  __init__.py
  __main__.py
  cli.py
  repl.py
  lexer.py
  parser.py
  ast.py
  evaluator.py
  session.py
  values.py
  certainty.py
  arithmetic.py
  towers.py
  landmark_tail.py
  sparse_decimal.py
  formatting.py
  diagnostics.py
  tests/
```

Important boundaries:

- `values.py`, `certainty.py`, `towers.py`, `landmark_tail.py`, and `sparse_decimal.py` must not
  import parser or REPL code.
- `arithmetic.py` owns numeric operations over values and returns values plus diagnostics.
- `evaluator.py` owns Tungie AST evaluation and session symbol lookup.
- `formatting.py` consumes values and certainty records but does not make new mathematical claims.
- `repl.py` is only a UI loop over `session.py`; it should be easy to drive from in-memory text
  streams.

## Open Decisions

- Whether unmarked decimal literals should always mean `$MachinePrecision`, or whether a calculator
  mode should allow `$DefaultPrecision` to control them. The default should remain Wolfram-like.
- Whether uncertain numeric comparisons should return inert relations or `Failure[...]`. The
  important requirement is that they must not return an invented boolean.
- Exact names for the diagnostic built-ins. The concepts are more important than the spelling, but
  the spelling should be stable before implementation begins.

## Recommendation

Build Tungie as a new Nummy-owned package with a small Tungsten-inspired language contract, not as a
cleanup pass over any one prototype. Keep the parser/evaluator standard-library-only, route ordinary
base-10 tower expressions into a real landmark-tail value model, and make certainty data as central
as the numeric payload itself. The first successful Tungie implementation is done when the
MathOverflow expression, machine-overflow-scale expressions, exact rational calculator behavior,
REPL history, and diagnostic introspection all pass through the same canonical evaluator and tests.
