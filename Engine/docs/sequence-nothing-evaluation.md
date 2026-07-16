# Tungsten Sequence and Nothing Evaluation

- Status: Normative specification for Tungsten's kernel-free evaluator
- Audience: Tungsten maintainers and users who need precise offline evaluation behavior
- Scope: `Engine/src/tungsten/expression.py`
- Created (UTC): 2026-04-25T01:00:00Z
- Updated (UTC): 2026-04-25T23:42:00Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a
- Related Wolfram docs:
  - [Sequence](https://reference.wolfram.com/language/ref/Sequence.html)
  - [Nothing](https://reference.wolfram.com/language/ref/Nothing.html)
  - [HoldAll](https://reference.wolfram.com/language/ref/HoldAll.html)
  - [HoldAllComplete](https://reference.wolfram.com/language/ref/HoldAllComplete.html)
  - [SequenceHold](https://reference.wolfram.com/language/ref/SequenceHold.html)
  - [Evaluate](https://reference.wolfram.com/language/ref/Evaluate.html)
  - [Unevaluated](https://reference.wolfram.com/language/ref/Unevaluated.html)
  - [Inactive](https://reference.wolfram.com/language/ref/Inactive.html)
  - [Activate](https://reference.wolfram.com/language/ref/Activate.html)

## Purpose

`Sequence` and `Nothing` are not ordinary inert heads in the Wolfram evaluator. They participate in
the standard evaluation pipeline by changing the containing argument list. Tungsten implements a
bounded, explicit version of those rules so common structural transformations such as replacing a
list element with `Nothing` or constructing a call with `Sequence` work without launching a kernel.

This document defines that behavior. It also states where Tungsten deliberately stops because it
does not implement evaluator-wide attribute semantics, definitions, or upvalues. The separate symbol registry can report read-only Wolfram 15.0 <code>System`</code> attributes,
but most of those attributes do not drive evaluation here.

## Source Observations

The official Wolfram documentation states that `Sequence[expr1, expr2, ...]` represents arguments
to splice into any function, except functions with `SequenceHold` or `HoldAllComplete`.

The official documentation also states that `Nothing` represents a list element that is removed
automatically, that `Nothing[...]` gives `Nothing`, and that `Nothing` is not removed from held or
inactive expressions.

Live-kernel probes confirmed these representative cases:

| Expression | Kernel result |
|---|---|
| `{Sequence[1, 2], 3}` | `{1, 2, 3}` |
| `f[Sequence[1, 2], 3]` | `f[1, 2, 3]` |
| `Hold[Sequence[1 + 1, 2 + 2]]` | `Hold[1 + 1, 2 + 2]` |
| `HoldComplete[Sequence[1 + 1, 2 + 2]]` | `HoldComplete[Sequence[1 + 1, 2 + 2]]` |
| `{Nothing, 1}` | `{1}` |
| `f[Nothing, 1]` | `f[Nothing, 1]` |
| `Nothing[1, 2]` | `Nothing` |
| `Hold[Nothing]` | `Hold[Nothing]` |
| `ReleaseHold[Hold[{Nothing, 1}]]` | `{1}` |
| `<|Nothing, a -> 1|>` | `<|a -> 1|>` |
| `<|a -> Nothing, b -> 1|>` | `<|a -> Nothing, b -> 1|>` |
| `{a, b} /. a -> Nothing` | `{b}` |
| `Hold[{a, b}] /. a -> Nothing` | `Hold[{Nothing, b}]` |
| `Hold[Evaluate[1 + 2]]` | `Hold[3]` |
| `HoldComplete[Evaluate[1 + 2]]` | `HoldComplete[Evaluate[1 + 2]]` |
| `Evaluate[Unevaluated[1 + 2]]` | `3` |
| `Inactive[Plus][1 + 2, 3 + 4]` | `Inactive[Plus][3, 7]` |
| `Activate[Inactive[Plus][Inactive[Times][2, 3], 4], Times]` | `Inactive[Plus][6, 4]` |

## Evaluation Phases

Tungsten evaluates a call expression in these phases:

1. Evaluate or preserve the head according to Tungsten's existing special forms.
2. Decide whether the head suppresses argument evaluation, `Sequence` splicing, or both.
3. Evaluate arguments when the head is not in a holding form.
4. Splice direct `Sequence[...]` arguments when the head allows splicing.
5. Apply direct `Nothing` removal only in contexts where Wolfram removes it.
6. Dispatch the normalized call to Tungsten's supported built-ins.
7. Leave unsupported heads inert after the same normalization phases.

This ordering is important. `Sequence` is an argument-list operation, while `Nothing` is a
list-element operation. In a list, `Sequence` splicing happens before `Nothing` removal, so
`{Sequence[Nothing, 1], 2}` becomes `{1, 2}`.

## Sequence Rules

Tungsten treats `Sequence` as follows:

- `Sequence[...]` is parsed as an ordinary call. It has no special parse-time behavior.
- A top-level `Sequence[...]` remains representable as `Sequence[...]` in Tungsten's AST.
- When an evaluated argument of a non-suppressing call is `Sequence[a, b, ...]`, Tungsten replaces
  that one argument with `a, b, ...`.
- `Sequence[]` contributes zero arguments to the containing call.
- `Sequence[x]` contributes one argument and is therefore equivalent to `x` only in a containing
  call.
- For ordinary evaluated calls, the payload of a `Sequence[...]` has already been evaluated before
  splicing.
- For held-but-not-sequence-suppressing heads such as `Hold`, `HoldForm`, `HoldPattern`, and
  `Function`, Tungsten splices direct `Sequence[...]` arguments structurally without evaluating the
  sequence payload.
- Tungsten suppresses `Sequence` splicing for `HoldComplete`, `Unevaluated`, `Rule`, and
  `RuleDelayed`.
- Direct `Evaluate[...]` inside `Hold`, `HoldForm`, `HoldPattern`, `Function`, or `Inactive`
  overrides holding for that one argument before sequence splicing. `HoldComplete` and
  `Unevaluated` have `HoldAllComplete` behavior in Tungsten and therefore keep `Evaluate[...]`
  inert.
- Direct `Unevaluated[expr]` subjects are treated transparently by supported structural functions
  such as `Length`, `Head`, `Part`, `Map`, pattern functions, and replacement functions. Tungsten
  deliberately does not strip `Unevaluated` from inert unknown heads or from list construction.

Tungsten now implements registry-backed evaluator attributes. User-defined symbols can acquire
`SequenceHold` or `HoldAllComplete` behavior with `SetAttributes`, and Wolfram 15.0 System symbols
use the attributes loaded from the startup snapshot. The explicit built-in list above remains the
important reference for Tungsten's Hold-family heads, while ordinary calls also consult mutable
symbol metadata.

## Nothing Rules

Tungsten treats `Nothing` as follows:

- The symbol `Nothing` is otherwise inert and can appear as an atom.
- `Nothing[args...]` evaluates its arguments according to ordinary Tungsten evaluation, then
  returns the symbol `Nothing`.
- If an evaluated head becomes `Nothing`, the whole call evaluates to `Nothing`.
- Direct `Nothing` elements are removed from evaluated `List[...]` argument lists.
- Direct `Nothing` placeholders are removed from `Association[...]` constructor argument lists.
- `Rule[key, Nothing]` and `RuleDelayed[key, Nothing]` are retained; the value is `Nothing`.
- Direct `Nothing` arguments to non-list, non-association heads are retained.
- Held expressions do not remove `Nothing` from unevaluated subexpressions. For example,
  `Hold[{Nothing, 1}]` stays held, while `ReleaseHold[Hold[{Nothing, 1}]]` evaluates the released
  list and removes `Nothing`.

## Interaction With Replacement and Mapping

Replacement and mapping functions can produce `Nothing`. Tungsten follows the same contextual rule:

- If a transformation rebuilds an evaluated list, direct `Nothing` elements are removed.
- If a transformation rebuilds a held list inside `Hold`, `HoldComplete`, `HoldForm`,
  `HoldPattern`, `Unevaluated`, or `Function`, direct `Nothing` elements are retained because the
  rebuilt list is still in a held context.
- If a transformation rebuilds any non-list head, direct `Nothing` arguments are retained.

This gives the expected practical behavior:

- `{a, b} /. a -> Nothing` becomes `{b}`;
- `Hold[{a, b}] /. a -> Nothing` becomes `Hold[{Nothing, b}]`;
- `f[a, b] /. a -> Nothing` becomes `f[Nothing, b]`;
- `Cases[{1, 2, 3}, 2 :> Nothing]` becomes `{}`.

## Non-Goals

Tungsten does not implement:

- side-effect fidelity for discarded arguments, beyond structurally evaluating arguments before
  `Nothing[...]` collapses to `Nothing`.

These limits are deliberate. The offline evaluator stays useful for structural automation without
pretending to be a complete Wolfram kernel.
