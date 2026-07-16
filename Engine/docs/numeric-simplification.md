# Tungsten Numeric Simplification

- Status: Current-state implementation note for `NumericQ`, `Simplify`, and `FullSimplify`
- Audience: Tungsten maintainers, expression-evaluator contributors, and users relying on offline evaluation
- Scope: `Engine/src/tungsten/expression.py`, `expression_arithmetic.py`, and `expression_evaluator.py`
- Created (UTC): 2026-04-27T20:51:45Z
- Repository HEAD: 61e28d844b1e32dca30f4a8d6ca402c4ec8a67b7
- Related docs:
  - [Numeric Tower](./numeric-tower.md)
  - [Expression Function Support](./expression-function-support.md)
  - [Expression Parser](./expression-parser.md)

## Intent

Tungsten's kernel-free simplifier is deliberately small. It exists to close common variable-free
numeric cases without turning the offline evaluator into a general computer-algebra system.

The implementation uses `NumericQ` as the gate. `Simplify[expr]` and `FullSimplify[expr]` simplify
only the evaluated one-argument form when `NumericQ[expr]` returns `True`. If the evaluated
expression contains variables, unsupported heads, `Infinity`, `ComplexInfinity`, or
`Indeterminate`, simplification returns the evaluated expression unchanged.

`FullSimplify` is currently a synonym for `Simplify`; it does not run a broader search.

## NumericQ Gate

`NumericQ[expr]` returns `True` for:

- explicit numeric atoms: integers, rationals, reals, complexes, `Overflow[]`, and `Underflow[]`;
- exact algebraic `Root` values and supported arithmetic combinations of them;
- variable-free supported constants and elementary numeric expressions that Tungsten can convert
  through its SymPy-backed numeric bridge, such as `Pi`, `I Pi`, `Sin[1]`, and `Sqrt[2]`.

It returns `False` for:

- bare variables and expressions containing variables, such as `x + 1` or `Sin[x]`;
- `Infinity`, `-Infinity`, `ComplexInfinity`, and `Indeterminate`;
- opaque applications such as `f[1]` unless a future evaluator rule makes them numeric.

## Applied Transformations

`Simplify` builds a short list of candidates and returns the candidate with the smallest
`FullForm` text. This keeps the implementation deterministic and avoids expression-tree search.

The current candidates are:

1. The already evaluated input expression.
2. A `RootReduce` result when the expression is in Tungsten's supported algebraic-number subset.
3. A single SymPy-backed low-risk pass over the variable-free numeric expression:
   - `powsimp(..., combine="all", force=False)`;
   - `trigsimp(..., method="matching")`;
   - `cancel`;
   - `factor_terms`.

Exact results are converted back to Tungsten expressions without numeric approximation when
possible. Inexact inputs use the existing numeric conversion path and preserve the visible
combined precision policy already used by `N`.

## Examples

These expressions simplify:

```wolfram
Simplify[Sin[1]^2 + Cos[1]^2]       (* 1 *)
FullSimplify[Sin[1]^2 + Cos[1]^2]   (* 1 *)
Simplify[Sqrt[2]^2]                 (* 2 *)
Simplify[E^Log[2]]                  (* 2 *)
Simplify[Root[#^2 - 2 &, 2]^2]      (* 2 *)
```

These expressions stay within the evaluated input shape because they are not variable-free
numeric expressions under Tungsten's current `NumericQ`:

```wolfram
Simplify[x + 1]                     (* 1 + x *)
Simplify[Sin[x]^2 + Cos[x]^2]       (* Cos[x]^2 + Sin[x]^2 *)
Simplify[f[1]]                      (* f[1] *)
```

## Non-Goals

The simplifier does not implement:

- assumptions;
- variable-bearing symbolic simplification;
- general trigonometric reduction beyond the single matching pass;
- branch-sensitive transformations that require proof obligations;
- cost-guided search trees;
- logical, polynomial, equation-solving, or quantifier simplification.

Those remain live-kernel tasks or future explicitly scoped Tungsten features.
