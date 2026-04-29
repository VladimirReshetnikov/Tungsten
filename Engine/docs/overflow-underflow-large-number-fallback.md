# Overflow And Underflow Large-Number Fallback Design

- Status: Design proposal for Tungsten's kernel-free numeric evaluator
- Audience: Tungsten maintainers, Nummy maintainers, REPL implementers, and test authors
- Scope: `src/Tungsten/src/tungsten/`, with source material from `src/Tungsten/Nummy/src/{alpha,beta,gamma}/`
- Created (UTC): 2026-04-28T23:55:11Z
- Updated (UTC): 2026-04-29T00:49:16Z
- Repository HEAD: b3d0d7929b6a5927bfde9adb364f07616565d3e3
- Related docs:
  - [Numeric Tower](./numeric-tower.md)
  - [Numeric Simplification](./numeric-simplification.md)
  - [REPL](./repl.md)
  - [Nummy Alpha/Beta/Gamma Unified Comparison](../Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md)

## Summary

Tungsten should keep its current fast exact, machine, and decimal arithmetic paths, but add a
kernel-free very-large-number fallback that activates when ordinary floating-point arithmetic would
otherwise collapse to `Overflow[]`, `Underflow[]`, or an indistinguishable machine zero caused by
underflow.

The fallback should not reinterpret every explicit `Overflow[]` or `Underflow[]` atom as a hidden
large number. Those atoms already have Wolfram-compatible behavior in Tungsten: they are atomic real
values, `NumberQ[Overflow[]]` is `True`, `Head[Overflow[]]` is `Real`, and
`Precision[Overflow[]]` is `0.`. The new behavior should be tied to provenance: a finite ordinary
floating-point operation attempted by Tungsten overflowed or underflowed, so Tungsten retries that
same operation in the large-number engine using the original operands.

The target user experience is seamless in the REPL and expression evaluator:

```wolfram
In[1]:= 10.^400
Out[1]= 1.*10^400`15.95

In[2]:= 10.^-400
Out[2]= 1.*10^-400`15.95

In[3]:= 10^(10^(10^(10^(10^(-10^10)))))
Out[3]= 10^10^10 + 2811012357389.4407116278...`30
```

The exact final formatting should be locked down by tests, but the semantic contract is the
important part: the output must show the precision it can justify, and every printed decimal digit
inside that claimed precision must be certified correct, except for the known boundary case where a
tighter residual bound can flip a tail between repeated `9` and repeated `0`.

## Current Tungsten Numeric Shape

The existing implementation is favorable for this integration because the numeric evaluator is
already concentrated in a few places:

- `src/tungsten/expression.py` defines the numeric atoms, including `Integer`, `RationalNumber`,
  `Real`, `ComplexNumber`, `RootNumber`, and `SpecialReal`.
- `SpecialReal` is the internal atom for `Overflow[]` and `Underflow[]`; it has head `Real` and
  serializes as `{"type": "real", "special": "Overflow"}` or
  `{"type": "real", "special": "Underflow"}`.
- `_machine_real` maps `math.inf` to `Overflow[]`.
- `_inexact_real_result`, `_add_real_expr`, `_mul_real_expr`, `_div_real_expr`,
  `_real_power_expr`, `_add_numeric_expr`, `_mul_numeric_expr`, `_div_numeric_expr`, and
  `_numeric_power_expr` are the real arithmetic choke points.
- `src/tungsten/expression_arithmetic.py` owns evaluator dispatch for `Plus`, `Times`, and
  `Power`, then calls those helpers.
- `Precision` and `Accuracy` are implemented through `_precision_value` and `_accuracy_value`.

One important gap is that ordinary Python float underflow can silently produce `0.0`; the current
`_machine_real(0.0)` returns `0.` rather than `Underflow[]`. The large-number fallback must detect
operation-specific underflow before that collapse loses information.

There is also an adjacent exact-arithmetic hazard. Exact integer powers currently use Python's
`pow` for non-negative integer exponents. That is correct for moderate values, but a normal Wolfram
expression such as `10^10^10` can ask for an integer with ten billion decimal digits. A complete
large-number integration should therefore include a structural exact-power guard, even though the
first trigger requested here is floating-point overflow and underflow.

## Design Goals

- Preserve the current exact and ordinary floating-point behavior whenever the result is finite and
  representable.
- Retry finite floating-point operations in a large-number engine only after a real overflow or
  underflow trigger is detected.
- Preserve explicit `Overflow[]` and `Underflow[]` semantics when those atoms appear as user input
  or as operands produced by older rules.
- Return numeric atoms that behave like real numbers for `NumberQ`, `NumericQ`,
  `RealValuedNumberQ`, `Precision`, `Accuracy`, ordering where justified, and JSON serialization.
- Never claim decimal precision that is not backed by a proof, interval, exact residual, or
  mathematically valid bound.
- Make the MathOverflow expression work through ordinary `Power` syntax, not through a special
  helper.
- Keep the implementation inside Tungsten, while reusing the lessons from the Nummy alpha, beta,
  and gamma prototypes.

## Non-Goals

- This is not a full Wolfram arbitrary-precision engine.
- This is not general symbolic simplification, equation solving, integration, or special-function
  numerics.
- This is not a promise that every structural large number can be expanded into decimal digits.
  Some results will have only a certified scale or a structural display.
- This is not a replacement for the existing `Overflow[]` and `Underflow[]` atoms.
- Complex branch-cut-sensitive arithmetic is out of scope for the first implementation. Complex
  integer powers can continue using the existing path until the real fallback is stable.

## Proposed Architecture

Add a small, explicit large-number subsystem rather than spreading tower logic through the existing
`expression.py` helpers.

```text
expression_arithmetic.py
        |
        v
expression.py numeric helpers
        |
        v
expression_large_numbers.py        # Expr-facing fallback adapter
        |
        v
large_numbers/
  core.py                          # payloads, intervals, certainty
  tower.py                         # repeated exp/log coordinates
  perturbation.py                  # asymptotic series near landmarks
  formatting.py                    # certified text rendering
```

The exact package shape can be flattened initially, but the dependency direction should stay clean:

- `expression.py` owns AST classes and Wolfram-facing behavior.
- `expression_large_numbers.py` converts Tungsten numeric `Expr` objects to and from large-number
  payloads.
- `large_numbers/*` has no dependency on Tungsten AST classes. It works on plain dataclasses.

That separation matters because the Nummy prototypes are calculator-oriented. Tungsten needs a
library-grade substrate that can sit below a Wolfram-like evaluator, the REPL, JSON output, and
eventually the .NET projection layer.

## New Numeric Atom

Introduce a new atomic expression class, tentatively named `LargeReal`.

```python
@dataclass(frozen=True)
class LargeReal(Expr):
    payload: LargeRealPayload

    def head(self) -> Expr:
        return Symbol("Real")
```

`LargeReal` should be an atom with head `Real`, not an ordinary call. That keeps the user-facing
behavior aligned with the existing numeric tower:

- `AtomQ[large]` should be `True`.
- `NumberQ[large]` should be `True`.
- `NumericQ[large]` should be `True`.
- `RealValuedNumberQ[large]` should be `True`.
- `MachineNumberQ[large]` should be `False`.
- `InexactNumberQ[large]` should be `True` unless the payload is explicitly exact.

The JSON payload should extend, not replace, the existing real-number shape:

```json
{
  "type": "real",
  "large": {
    "kind": "landmark_tail",
    "landmark": {"kind": "pow10", "exponent": {"kind": "integer", "value": "10000000000"}},
    "tail": {"kind": "decimal_interval", "midpoint": "2811012357389.4407116278", "radius_exp10": -31}
  },
  "precision": {"certified_digits": 30, "kind": "relative"},
  "accuracy": null
}
```

The exact schema can be tightened during implementation, but it needs these concepts:

- payload kind;
- sign;
- scale or landmark;
- optional tail;
- certified precision;
- optional absolute accuracy;
- residual bound;
- whether a displayed decimal tail has a repeated-`9` / repeated-`0` boundary caveat.

## Large-Number Payloads

The initial payload set should be small and composable.

### 1. Decimal Interval

For ordinary overflow cases like `10.^400`, the result can be a decimal interval around an exact
scale-coordinate evaluation:

```text
sign * mantissa * 10^exponent, with a certified relative digit count
```

If the operands are machine reals, the certified precision should not exceed the effective input
precision. For machine literals this is approximately `$MachinePrecision`, unless a later parser
change records more source-literal information.

### 2. Reciprocal Tiny Value

Underflow is not zero. Represent tiny values symmetrically:

```text
sign * mantissa * 10^(-huge_exponent)
```

This should use the same scale coordinate as huge values, not a separate special case.

### 3. Structural Tower

Use a compact repeated-power or repeated-log coordinate for values whose magnitude cannot be held as
an ordinary exponent:

```text
Tower(base=10, levels=[...])
```

This payload answers scale questions and preserves expression identity without allocating enormous
integers or strings.

### 4. Landmark Plus Tail

For values close to a landmark such as `10^10^10 + c`, represent the value as:

```text
landmark + certified_tail + residual_bound
```

This is the form needed for the MathOverflow expression. It should support both display and exact
integer-floor operations when the residual bound is strong enough.

### 5. Sparse Exact Integer

When `Floor` or exact integer extraction is justified, do not materialize the full integer. Use a
sparse decimal integer payload such as:

```text
10^10000000000 + 2811012357389
```

with metadata saying that the decimal shape is one leading `1`, a certified zero run, and a final
suffix.

## Fallback Triggering

The fallback must run inside the arithmetic helpers before information is lost.

### Machine Addition And Multiplication

`_inexact_real_result` currently folds machine reals using Python `sum` or `math.prod`, then passes
the result to `_machine_real`.

Add a hook after the Python operation but before `_machine_real`:

```python
result = machine_operation(values)
fallback = _try_large_real_fallback(operation, arguments, result)
if fallback is not None:
    return fallback
return _machine_real(result)
```

The hook should activate when:

- `math.isinf(result)` after finite operands;
- `result == 0.0` and an operation-specific analysis proves the mathematical result is nonzero and
  below the minimum representable machine magnitude;
- Python raises `OverflowError`.

For addition, underflow detection should be conservative because cancellation can legitimately
produce exact zero in the floating model. Multiplication and division are much easier to prove from
nonzero operands and log-magnitude bounds.

### Division

`_div_real_expr` performs machine division directly. Add the same hook there:

- overflow: `abs(left / right) == inf` or `OverflowError`;
- underflow: nonzero numerator and finite nonzero denominator produce `0.0`;
- existing division-by-zero behavior remains `Indeterminate` or `ComplexInfinity`.

### Power

`_real_power_expr` is the most important hook.

- Integer powers over machine reals should route through large-number evaluation when
  `base_float ** power` overflows or underflows.
- Non-integer machine powers should route through large-number evaluation when the real branch is
  unambiguous and Python either overflows, underflows, or cannot represent the result.
- Negative bases with non-integer exponents remain inert or follow the existing behavior until
  complex large numbers are designed.

### Exact Power Guard

Add a separate guard before `pow(base.value, exponent.value)` for exact integer powers:

```text
estimated_decimal_digits = floor(exponent * log10(abs(base))) + 1
```

If that estimate exceeds a configurable structural threshold, return a structural exact large
integer instead of constructing Python's full integer. This guard is not strictly part of the
floating-overflow fallback, but it is required for normal-syntax tower expressions to remain safe.

## Provenance Rules

Do not convert existing special atoms into large numbers merely because they participate in
arithmetic.

Examples:

```wolfram
Overflow[] + 1
1 / Overflow[]
Underflow[] * 10
```

These should keep the current `SpecialReal` semantics unless Tungsten later adds an explicit opt-in
compatibility mode. The fallback path should know whether it was triggered by a failed operation on
finite operands, not by receiving a `SpecialReal` operand.

The adapter can model this with an internal trigger enum:

```python
class LargeFallbackTrigger(Enum):
    MACHINE_OVERFLOW = "machine_overflow"
    MACHINE_UNDERFLOW = "machine_underflow"
    EXACT_INTEGER_TOO_LARGE = "exact_integer_too_large"
```

Each trigger should carry the original operation and operands. The large-number engine must never
be asked to reconstruct intent from a bare `Overflow[]`.

## Precision Contract

Tungsten should distinguish four quantities:

- input precision: the precision of the operands;
- working precision: internal guard precision used to evaluate or bound the result;
- certified precision: the number of decimal digits proven correct in the printed result;
- display precision: the number of digits the formatter is allowed to show.

Only certified precision should appear in user-visible precision marks or `Precision[large]`.

For simple scale results, the certified precision is limited by the input precision and by any
interval widening in the operation. For tower-near-landmark results, the certified precision comes
from residual bounds in the asymptotic expansion.

If the renderer prints a digit string with a residual interval that crosses a decimal rounding
boundary, it must either:

- reduce the printed precision until the digits are stable; or
- show the repeated-`9` / repeated-`0` caveat explicitly in the large payload display.

The default should be to reduce precision. The caveat is useful for diagnostic reports, but ordinary
REPL output should be conservative.

`Precision[large]` should return:

- `Infinity` for exact structural large integers and exact rational large values;
- a finite machine real for certified finite precision;
- `0.` when the value is only a scale placeholder with no certified local decimal digits;
- `MachinePrecision` only if the payload truly has ordinary machine-precision semantics.

`Accuracy[large]` should be derived from certified precision and scale when possible. For enormous
values with relative precision but no useful absolute digit count, returning the Wolfram-style
relationship is acceptable as long as it does not imply unavailable local digits.

## Display Contract

The display layer should remain Wolfram-like, but it can introduce Tungsten-owned forms when a value
cannot be displayed as an ordinary decimal.

Recommended display rules:

- ordinary scientific-scale values: `1.2345*10^400` or `1.2345*^-400` with a precision mark;
- structural towers: `10^^3(2.5)` only if documented, otherwise an explicit
  `TungstenLargeReal[...]` input form;
- landmark-tail values: `10^10^10 + 2811012357389.4407116278...` with a precision mark on the tail;
- exact sparse integer floors: `10^10000000000 + 2811012357389` plus optional `Short`-style shape
  metadata in diagnostic contexts.

For `FullForm`, prefer an explicit Tungsten-owned constructor so round-tripping is not ambiguous:

```wolfram
TungstenLargeReal[<|"Kind" -> "LandmarkTail", ...|>]
```

For `InputForm`, prefer readable mathematical notation when it is unambiguous and compact. Tests
should verify that `ToString[large, InputForm]` does not print uncertified digits.

## Nummy Reuse Strategy

The Nummy work should be used as source material, not copied wholesale.

The unified comparison of Nummy alpha, beta, and gamma points to a synthesis:

- alpha has the best current calculator surface, ordinary-expression behavior, precision-marked
  output, exact rational scalar arithmetic, and sparse `Floor` result for the MathOverflow case;
- beta has the best perturbative/asymptotic engine and the broadest modular tests;
- gamma has the cleanest compact landmark-plus-tail vocabulary.

For Tungsten:

- use alpha's user-facing conservatism and exact sparse integer idea;
- adapt beta's perturbation/residual machinery into `large_numbers/perturbation.py`;
- use gamma's landmark-tail vocabulary for payload design;
- add a common certainty object before exposing proof-grade precision claims.

The resulting code should not depend on `src/Tungsten/Nummy/src/alpha`, `beta`, or `gamma` at runtime. Those
directories are independent experiments with overlapping package names and REPL concerns. Tungsten
needs a focused internal engine with stable AST and JSON integration.

## MathOverflow Expression Path

The expression:

```wolfram
10^(10^(10^(10^(10^(-10^10)))))
```

must work through ordinary syntax. The evaluator should not require a function such as
`LeadingDigits[...]`, `MO[...]`, or any other special case visible to the user.

The implementation path should be:

1. Parse the expression normally as nested `Power`.
2. Avoid exact construction of impossible intermediate integers by using the exact-power guard.
3. Recognize the base-10 tower form during `Power` evaluation.
4. Preserve the small negative perturbation introduced by `10^(-10^10)`.
5. Route the tower-near-landmark value through the perturbation engine.
6. Produce a `LargeReal` landmark-tail payload:

```text
10^10000000000 + 2811012357389.44071162781827848...
```

7. Let ordinary formatting decide how many certified digits to print.
8. Let `Floor[...]` use the same payload and residual bound to return the sparse exact integer when
   stable.

The recognizer should be mathematical rather than text-based. It should operate over evaluated
`Power` expressions and `LargeReal` structural payloads, so whitespace, parentheses, and REPL
history substitutions do not matter.

## Settings

Add Tungsten-owned session settings only where they are needed. Candidate names:

- `$TungstenLargeNumberFallback`: `Automatic`, `True`, or `False`; default `Automatic`.
- `$TungstenLargeNumberDisplayPrecision`: default finite integer used by the REPL when no explicit
  `N[..., p]` precision is requested.
- `$TungstenLargeNumberMaxGuardDigits`: cap for internal guard digits in the large-number engine.
- `$TungstenMaxExactIntegerDigits`: threshold beyond which exact integer powers become structural.

`Automatic` should mean:

- enabled for kernel-free Tungsten expression evaluation;
- disabled only when doing a strict Wolfram-kernel parity test that expects literal
  `Overflow[]` / `Underflow[]` from machine arithmetic.

These settings should be part of the same session-runtime machinery that currently owns `$Line`,
history, attributes, and other mutable evaluator state.

## JSON And Projection Layers

The Python CLI already returns structured expression payloads. Adding `LargeReal` requires the
following projection work:

- extend `Expr.to_dict()` for the new atom;
- ensure existing consumers that only care about `full_form` and `input_form` remain unaffected;
- update .NET DTOs to tolerate or model `real.large`;
- update PowerShell wrappers only if they parse numeric payload details directly;
- add examples to the usage reference after the implementation exists.

The JSON should carry enough information for external callers to decide whether digits are
certified. A caller should not need to parse a printed string to find precision or residual data.

## Comparison And Ordering

Ordering can be added incrementally.

Safe initial comparisons:

- two exact sparse large integers with comparable landmarks;
- a large positive value against finite ordinary numbers;
- a positive tiny reciprocal against zero and finite positive numbers when the sign is certified;
- a landmark-tail value against its landmark when the tail sign and residual are certified.

Unsafe comparisons should remain inert rather than manufacturing a boolean. This keeps Tungsten's
current fail-closed numeric posture.

## Interaction With `N`, `SetPrecision`, And `SetAccuracy`

`N[large, p]` should request `p` certified digits. If the engine can produce them, return a
`LargeReal` with certified precision `p`. If it cannot, return the best certified payload and do
not inflate the precision marker.

`SetPrecision[large, p]` should not magically certify new digits. It can:

- lower visible precision by widening or truncating the certainty object;
- request recomputation when the payload retains exact or structural information that can produce
  more digits;
- refuse to raise precision beyond certification when recomputation is impossible.

`SetAccuracy` should follow the same principle with absolute error bounds.

## Implementation Phases

### Phase 1: Atom And Adapter

- Add `LargeReal` and payload dataclasses.
- Update numeric predicates, `Precision`, `Accuracy`, serialization, and display.
- Add tests for explicit construction through an internal helper.

### Phase 2: Machine Overflow And Underflow Fallback

- Add fallback hooks to `_inexact_real_result`, `_div_real_expr`, and `_real_power_expr`.
- Support finite large scientific-scale outputs for `Times`, `Divide`, and `Power`.
- Preserve explicit `Overflow[]` / `Underflow[]` operand behavior.

### Phase 3: Exact Power Guard

- Add configurable exact-integer digit thresholding.
- Return exact structural large integers for powers above the threshold.
- Add `Floor`, comparison, and display tests for sparse exact integer payloads.

### Phase 4: Tower And Landmark-Tail Engine

- Port the Nummy-derived structural tower and landmark-tail payloads.
- Add perturbation/residual support for the MathOverflow expression.
- Make ordinary `Power` syntax route to this path without user-visible helpers.

### Phase 5: REPL And External Surface

- Tune REPL display.
- Add `N[..., p]` tests for large values.
- Update CLI JSON examples and .NET DTOs.
- Add documentation examples after behavior is implemented.

## Test Plan

Add tests in `src/Tungsten/tests/test_expression.py` or a new numeric-focused test module.

Core regression tests:

- `Overflow[]` and `Underflow[]` explicit atoms keep current behavior.
- `Head`, `AtomQ`, `NumberQ`, `NumericQ`, `RealValuedNumberQ`, and `MachineNumberQ` classify
  `LargeReal` correctly.
- Existing exact integer/rational arithmetic is unchanged below the structural threshold.
- Existing machine arithmetic is unchanged for finite representable results.

Fallback tests:

- `10.^400` returns a large finite real, not `Overflow[]`.
- `10.^-400` returns a large tiny real, not `0.` and not `Underflow[]`, when fallback is enabled.
- Multiplication and division produce large values when their machine result overflows or
  underflows.
- Disabling `$TungstenLargeNumberFallback` restores current special-real behavior for strict parity
  checks.

Precision tests:

- printed digits never exceed certified precision;
- `Precision[large]` matches the certified precision payload;
- `N[large, p]` does not claim `p` unless the engine certifies `p`;
- repeated-`9` / repeated-`0` boundary cases reduce visible precision or report the caveat.

MathOverflow tests:

- the ordinary nested `Power` expression returns a landmark-tail `LargeReal`;
- the displayed tail begins with `2811012357389.4407116278` at a requested precision that supports
  those digits;
- `Floor[...]` over the same expression returns the sparse exact integer payload
  `10^10000000000 + 2811012357389`;
- no test uses a special visible helper to reach that path.

JSON and REPL tests:

- `to_dict()` includes `real.large` and certification metadata;
- `to_input_form()` and REPL output are compact and certified;
- `%`, `Out[n]`, `Short`, and output-size limiting work with large payloads.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| Wolfram parity changes for machine overflow | Make the behavior a Tungsten extension controlled by `$TungstenLargeNumberFallback`; keep explicit special atoms unchanged. |
| Precision overclaiming | Carry certified precision and residual bounds as data; make formatting consume those bounds. |
| Exact integer allocation blowups | Add a digit-estimate guard before `pow` for large exact integer powers. |
| Circular imports in the expression subsystem | Keep pure payload logic out of `expression.py`; add a narrow Expr-facing adapter. |
| Unclear JSON compatibility | Extend the existing `{"type": "real"}` shape with a new `large` property rather than replacing existing fields. |
| Complex branch behavior | Keep complex large-number arithmetic out of the first implementation except for cases reduced to real arithmetic safely. |
| Hidden special cases for the MathOverflow expression | Implement a structural tower recognizer and perturbation engine, then test ordinary `Power` syntax directly. |

## Open Decisions

- The exact user-facing constructor name for `FullForm`: `TungstenLargeReal[...]`,
  `LargeReal[...]`, or an internal-system-context symbol.
- Whether `InputForm` should use `10^^n(x)` notation for structural towers or always use an
  explicit constructor when no certified decimal tail exists.
- The default display precision for large fallback values in the REPL.
- The exact digit threshold for structural exact integers.
- Whether `$TungstenLargeNumberFallback -> Automatic` should be enabled for CLI `expr evaluate`
  immediately or only for the REPL at first.

## Recommendation

Implement this as a Tungsten-owned large-number layer with a new `LargeReal` atom, not as a rewrite
of `SpecialReal`. Keep ordinary arithmetic fast and unchanged until it crosses a representability
boundary, then retry with the original operands in a certified large-number engine. Use Nummy alpha
for the calculator-facing discipline, beta for perturbation and residual machinery, gamma for the
landmark-tail vocabulary, and add Tungsten's missing AST, JSON, and precision contracts around that
core.
