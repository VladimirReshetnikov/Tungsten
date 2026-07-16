# OptimizedExpressions

- Created (UTC): 2026-06-26T19:47:55Z
- Repository HEAD: fbc379002652d67648e299fe6e6de86c27653dfb

`Optimized/` is a Wolfram Language package for doing arithmetic and exact-symbol
substitution on `Experimental`OptimizedExpression` objects without expanding them first.
It is the repository answer to Vladimir's unanswered Mathematica StackExchange question
[Computations with OptimizedExpressions without completely expanding them](https://mathematica.stackexchange.com/questions/221938/computations-with-optimizedexpressions-without-completely-expanding-them).

The package treats optimized expressions as expression DAGs. Existing temporary-variable
definitions are imported structurally, deduplicated semantically, and then re-emitted as one
new `Experimental`OptimizedExpression[Block[...]]`. Temporary names from input operands do
not matter: if one operand calls `x + y` `a15` and another calls it `b3`, the merged result
uses one temporary for `x + y`.

## Quick Start

```wolfram
Get["Optimized/OptimizedExpressions.wl"];

o1 = Experimental`OptimizeExpression[
  (x + y)^2 + z (x + y),
  "OptimizationSymbol" -> a
];

o2 = Experimental`OptimizeExpression[
  (x + y)^3 + w (x + y),
  "OptimizationSymbol" -> b
];

sum = OptimizedExpressions`OptimizedPlus[o1, o2]
(* Experimental`OptimizedExpression[
     Block[{OptimizedExpressions`Private`opt$1},
       opt$1 = x + y;
       opt$1^2 + opt$1^3 + opt$1 w + opt$1 z
     ]] *)

OptimizedExpressions`OptimizedExpressionNormal[sum] === Normal[o1] + Normal[o2]
```

## API

```wolfram
OptimizeExpressionDAG[expr]
OptimizedApply[headOrFunction, {expr1, expr2, ...}]
OptimizedPlus[expr1, expr2, ...]
OptimizedTimes[expr1, expr2, ...]
OptimizedDivide[num, den]
OptimizedSubstitute[expr, x -> replacement]
OptimizedExpressionNormal[expr]
OptimizedExpressionData[expr]
```

All entry points accept ordinary Wolfram expressions and existing
`Experimental`OptimizedExpression` objects. The production path is to keep operands optimized,
use the arithmetic/substitution helpers, and inspect small results with
`OptimizedExpressionNormal` only in tests or diagnostics.

### Options

The optimizer deliberately exposes controls that are awkward or unavailable in
`Experimental`OptimizeExpression`:

| option | default | meaning |
|---|---:|---|
| `"AtomicLeafCount"` | `1` | Composite expressions with `LeafCount <= n` are kept as opaque leaves during decomposition, but may still be extracted if repeated. |
| `"ExcludedPatterns"` | `{}` | Expressions matching any listed pattern are kept opaque and are not extracted. |
| `"ExcludedHeads"` | `{}` | Expressions with any listed head are kept opaque and are not extracted. |
| `"MinCommonLeafCount"` | `2` | A repeated node is extracted only if its leaf count is at least this value. |
| `"MaxInlineLeafCount"` | `50` | A node larger than this is extracted even if it occurs once. |
| `"OptimizationSymbol"` | `"opt"` | Base name or symbol for generated temporary variables, analogous to the system optimizer's option. |

## Current Semantics

- `OptimizedPlus` and `OptimizedTimes` are elementwise for equal-length list operands. This
  supports the StackExchange use case where a list of results shares many internal subexpressions.
- `OptimizedApply[head, operands]` constructs `head[operands...]` in DAG form. For `Plus` and
  `Times` it uses the list-wise rule above.
- `OptimizedApply[Function[...], operands]` does not expand operands. It evaluates the pure
  function on fresh placeholder symbols, then substitutes the operand DAG roots for those
  placeholders.
- `OptimizedSubstitute` supports exact symbol rules (`x -> optimizedReplacement`) and lists of
  such rules. Arbitrary pattern rewriting is intentionally out of scope for this first package:
  pattern matching over DAGs needs a separate matcher with explicit sharing semantics.
- The package preserves Wolfram's own evaluated structural form. It does not try to add algebraic
  normalization beyond what the kernel already does for heads such as `Plus` and `Times`.

## Tests

```powershell
cd Engine
uv run python -m tungsten kernel eval `
  --file ..\Optimized\tests\smoke.wl `
  --working-directory ..\.. `
  --require-success
```

The smoke suite checks:

- round-trip correctness for ordinary expressions;
- import of system-produced `Experimental`OptimizedExpression` operands;
- cross-operand common-subexpression extraction;
- plus, times, divide, exact-symbol substitution, list-wise plus, and pure-function apply;
- `"MinCommonLeafCount"` and `"ExcludedHeads"` behavior;
- `OptimizedExpressionData` diagnostics.

The direct Wolfram form also works when a kernel seat and the local `mathpass` setup are available:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe" -script Optimized/tests/smoke.wl
```

## Files

- [`OptimizedExpressions.wl`](OptimizedExpressions.wl) - package implementation.
- [`tests/smoke.wl`](tests/smoke.wl) - Wolfram smoke tests.
- [`docs/design.md`](docs/design.md) - API and implementation design notes.
