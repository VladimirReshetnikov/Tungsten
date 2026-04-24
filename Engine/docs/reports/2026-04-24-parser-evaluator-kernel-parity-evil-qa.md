# Tungsten Expression Evaluator: Evil-QA Follow-Up Findings

- Status: Report (adversarial parity addendum to `2026-04-24-parser-evaluator-kernel-parity.md`)
- Audience: Vladimir Reshetnikov, Tungsten maintainers
- Scope: `src/Tungsten/src/tungsten/expression.py`, documented support matrix
- Created (UTC): 2026-04-24T20:37:12Z
- Repository HEAD: f72ac6c1d78d422b9f05559ee263786a244bb686
- Companion artifacts:
  - Prior report (findings B1–B9): [`2026-04-24-parser-evaluator-kernel-parity.md`](./2026-04-24-parser-evaluator-kernel-parity.md)
  - Regression tests for all findings B1–B18:
    [`tests/test_expression_kernel_parity.py`](../../tests/test_expression_kernel_parity.py)
  - Evil harness (not committed): `C:\tmp\tungsten-diff\evil_harness.py` — 178 adversarial cases

## Executive summary

After the first-pass review identified 9 findings (B1–B9), I put on the "evil QA" hat and
built a 178-case adversarial corpus targeting operator precedence, hold-family semantics,
association-as-function, pure-function shadowing, Sequence splicing, FixedPoint limits, and
a handful of other edge cases where a thoughtful user would reasonably expect Wolfram parity.

Against the live kernel, Tungsten **matched 150/178** evil cases. The 28 non-matches shake
out as follows:

- **9 new real bugs** (B10–B18), all within documented scope or within what a reasonable
  reader of the docs would expect to work.
- **3 documented limits** (Listable threading, named sequence patterns, `StringExpression`
  with multiple unbounded elements) — already flagged in `docs/expression-parser.md`.
- **3 operator-form consistency gaps** (Map/Cases operator-form rejected while Select's is
  accepted) — mostly documented, but the inconsistency deserves a one-line doc update.
- Remaining 13 are cosmetic or overlap with already-known B1/B7/B8/B9 findings (binary-tree
  parser, Real-number backtick FullForm, `Infinity` rendering, etc.).

The top four additions from this pass (ranked by user-visible impact):

| ID | Finding | Priority |
|----|---------|----------|
| **B17** | `Hold`, `HoldComplete`, `HoldForm`, `Unevaluated` **don't actually hold their arguments** | **P1** |
| **B10** | `@` prefix operator precedence is backwards (binds weaker than `+`/`*`) | **P1** |
| **B13** | Association-as-function `assoc[key]` isn't implemented, which breaks the documented `#name` shorthand | **P2** |
| **B14** | `FixedPoint[f, x, n]` treats `n` as a hard error cap instead of a soft stop-after-n | **P2** |

Three of these (B10, B11, B17) all stem from the same structural shortcut: the Pratt parser
produces left-associative binary trees and the evaluator has no mechanism for HoldAll-attribute
heads. If the maintainers do one big cleanup pass, it's probably worth doing both together.

## Methodology

Same harness pattern as the first parity report — one batched kernel invocation over all
178 cases, `ToString[FullForm[result]]` on both sides, JSON round-trip via
`ExportString[..., "RawJSON"]` with a hand-rolled `tgAsciiEscape` helper to avoid
`Export::jsonstrictencoding` on Unicode content. The categories exercised:

- parser precedence and associativity corners (`@`, `;;`, chained infix, prefix stacks)
- string escapes and Unicode round-tripping
- pattern matching with named captures, shadowing, repeated bindings, `Except`, `HoldPattern`, `Verbatim`
- `Replace` / `ReplaceAll` / `ReplaceRepeated` with self-reference, guarded delayed RHS, fall-through, negative/infinity levelspecs
- associations with duplicate keys, nested associations, string keys, mixed selectors, `assoc[key]` access
- pure functions with shadowing, extra arguments, `#0`, `#name` shorthand, composition
- integer/Boolean control flow (`If`, `Which`, `Switch`, `Piecewise`) boundary cases
- `Take` / `Drop` / `Part` edges (negative out-of-range, reverse spans, empty lists)
- `Cases` / `Position` / `FreeQ` with level variations and multiple patterns
- `Fold` / `Nest` / `FixedPoint` on empty / non-converging inputs
- string patterns with empty strings, anchors, overlap, `StringJoin[]`, `StringCases[""]`

One operational note: with the license-slot/launch-gate stabilization that landed since
yesterday, the batched 178-case run held up cleanly even while I accidentally stacked up
4 concurrent Python harness invocations early in the session. The gate correctly serialized
them and all four eventually retired without any license failures. That's a real win; the
review simply isn't possible without it.

## Findings

### B10. The `@` prefix operator precedence is backwards

- **Category**: parser bug
- **Priority**: P1
- **Source**: [`expression.py:6623`](../../src/tungsten/expression.py#L6623) (`_AT_BP = 40`)
- **Tests**: `AtPrefixPrecedenceTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
f @ 1 + 2       Tungsten: f[3]                   Kernel: Plus[f[1], 2]
f @ x * 2       Tungsten: f[Times[x, 2]]         Kernel: Times[2, f[x]]
f @ 1 + g @ 2   Tungsten: f[Plus[1, g][2]]       Kernel: Plus[f[1], g[2]]
```

**Root cause.** Tungsten assigns `@` a binding power of 40 — *below* Plus (120), Times (140),
Power (160). In Wolfram, `@` (Prefix form) binds *above* Plus/Times/Power, closer to direct
function application. So Tungsten parses `f @ 1 + 2` as `f @ (1 + 2)` while the kernel parses
it as `(f @ 1) + 2`.

This also explains EVIL-11 (`#1 + 1` ordering): once prefix precedence is wrong, slot-based
pure functions that interact with arithmetic end up with the wrong shape.

**Proposed fix.** Raise `_AT_BP` to somewhere between `_POWER_BP` (160) and `_CALL_BP` (190).
A safe value is around 180 — tighter than `^`, looser than direct `f[...]` application.
Verify with the kernel that `f @ x^2` still parses to `f[x^2]` (it should, since `^` at 590 is
tighter than `@` at 640 in Wolfram's scale). The test `test_at_right_assoc_still_works` in
`test_expression_kernel_parity.py` confirms the right-associative chain behavior, which this
change must preserve.

### B11. `;;` parses left-associative binary, breaking stepped spans

- **Category**: parser bug (structural)
- **Priority**: P1
- **Source**: parser's span handling — the relevant region is reached from the Pratt loop
  at [`expression.py:6860`](../../src/tungsten/expression.py#L6860). Internally `a ;; b ;; c`
  is produced as `Span[a, Span[b, c]]` rather than `Span[a, b, c]`.
- **Tests**: `SpanParserTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
Parsed shape of  1 ;; 5 ;; 2       Tungsten: Span[1, Span[5, 2]]    Kernel: Span[1, 5, 2]
Parsed shape of  5 ;; 1 ;; -1      Tungsten: Span[5, Span[1, -1]]   Kernel: Span[5, 1, -1]

{a, b, c, d, e}[[5 ;; 1 ;; -1]]    Tungsten: List[e]                Kernel: List[e, d, c, b, a]
{a, b, c, d, e}[[1 ;; 5 ;; 2]]     Tungsten: List[a, b, c, d, e]    Kernel: List[a, c, e]
```

The step is effectively ignored because Part unwraps the nested `Span` by peeling off the
outer `Span[5, ...]`, interprets the inner nested span as "indices 1 through -1", and the
outer selector takes the first element of that. Using `Span[1, 5, 2]` (or `Take[..., {1, 5, 2}]`)
directly — without the parser — returns the correct answer.

**Root cause.** Same as B1/B7: the Pratt parser produces left-associative binary trees for
operators that Wolfram parses n-ary. For `;;`, the nesting means Part's span handler sees a
shape it wasn't built for.

**Proposed fix.** If the B1/B7 n-ary post-parse flattening pass also catches `Span`, this
dissolves automatically. Otherwise handle `;;` specifically in the parser by collecting up to
two `;;` tokens at a time into `Span[a, b]` or `Span[a, b, c]`.

### B12. `KeyMap` doesn't re-evaluate the applied function on keys

- **Category**: evaluator bug (same shape as B5 / Dot)
- **Priority**: P2
- **Source**: [`expression.py:4501-4510`](../../src/tungsten/expression.py#L4501-L4510)
- **Tests**: `KeyMapEvaluationTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
KeyMap[# &, <|a -> 1, b -> 2|>]
   Tungsten: <|Function[Slot[1]][a] -> 1, Function[Slot[1]][b] -> 2|>
   Kernel  : <|a -> 1, b -> 2|>

KeyMap[Identity, <|a -> 1|>]
   Tungsten: <|Identity[a] -> 1|>
   Kernel  : <|a -> 1|>
```

**Root cause.** Line 4506 constructs `Call(head_expr=function, arguments=(entry.key,))` and
hands it directly into `_association_expr` without routing through `evaluate()` or the shared
`_apply_callable` helper. For plain symbol heads like `f`, this is invisible (`f[a]` is
structurally stable). For callable heads like `Function[Slot[1]]` or `Identity`, the
application never fires.

**Proposed fix.** Swap the direct `Call(...)` for `_apply_callable(function, (entry.key,))`,
which already handles both positional pure functions and plain heads. Exactly the pattern the
rest of the codebase uses for higher-order applications.

### B13. Associations don't act as functions (`assoc[key]` doesn't extract)

- **Category**: missing evaluator feature
- **Priority**: P2
- **Source**: no single line — there's no evaluator case for `Call(head=<association>, args=[key])`.
- **Tests**: `AssociationAsFunctionTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
<|"name" -> x|>["name"]                    Tungsten: assoc["name"]   Kernel: x
#name & [<|"name" -> x|>]                  Tungsten: assoc["name"]   Kernel: x
```

**Background.** In Wolfram, an association has an implicit "call as function" semantics:
`assoc[key]` returns the stored value, equivalent to `Lookup[assoc, key]` when the key exists.
This is heavily used in practice.

Tungsten's parser-side `#name` → `#1["name"]` shorthand is documented in
`expression-parser.md` and is implemented correctly at the syntactic level — the problem is
that the resulting `assoc["name"]` call has no evaluator case. So the shorthand "works" but
its output is a useless inert expression.

**Proposed fix.** In the evaluator dispatch, before the fallback "unknown head" path, test
whether the evaluated head is an association. If so, interpret the call as `Lookup` /
`Part[..., Key[arg]]` depending on arity and key shape. Single-arg → `Part[assoc, Key[arg]]`
(or string shorthand). Multi-arg is a Wolfram extension for bulk lookup; probably safe to
leave out for now.

This also unlocks correct `#name` shorthand behavior end-to-end without any parser change.

### B14. `FixedPoint[f, x, n]` errors on non-convergence instead of returning current value

- **Category**: evaluator bug
- **Priority**: P2
- **Source**: [`expression.py:3671-3681`](../../src/tungsten/expression.py#L3671-L3681)
- **Tests**: `FixedPointMaxIterationsTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
FixedPoint[# - 1 &, 5, 2]    Tungsten: raises "exceeded iteration count"    Kernel: 3
FixedPoint[# - 1 &, 5, 0]    Tungsten: raises same                         Kernel: 5
```

Even `n=0` errors, which is clearly wrong — Wolfram returns the starting value with no
iterations.

**Root cause.** Line 3681 raises `WolframEvaluationError` when the loop exhausts without
reaching a fixed point. That's correct behavior for the default safety cap (when `max_iterations`
is `None`), but wrong when the caller *explicitly* passed an `n`. In Wolfram, explicit `n`
means "apply up to n times and return", not "error if not converged within n".

**Proposed fix.** Distinguish the two cases in `fixed_point` and `fixed_point_list`:

```python
def fixed_point(function, expr, max_iterations=None):
    has_explicit_cap = max_iterations is not None
    limit = _ITERATION_SAFETY_LIMIT if max_iterations is None \
            else _normalize_integer_argument(max_iterations, "FixedPoint")
    if limit < 0:
        raise WolframEvaluationError("FixedPoint expects a non-negative maximum iteration count.")
    current = expr
    for _ in range(limit + 1):
        updated = _apply_callable(function, (current,))
        if updated == current:
            return current
        current = updated
    if has_explicit_cap:
        return current             # Wolfram soft-limit behavior
    raise WolframEvaluationError("FixedPoint exceeded the allowed iteration count ...")
```

Apply the same shape to `fixed_point_list`.

### B15. `Sequence[...]` doesn't auto-splice

- **Category**: missing evaluator feature
- **Priority**: P2
- **Source**: no explicit handling; Tungsten treats `Sequence` as an unknown inert head.
- **Tests**: `SequenceSplicingTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
f[Sequence[1, 2], 3]    Tungsten: f[Sequence[1, 2], 3]    Kernel: f[1, 2, 3]
{Sequence[1, 2], 3}     Tungsten: {Sequence[1, 2], 3}     Kernel: {1, 2, 3}
```

**Background.** Wolfram's `Sequence[a, b, ...]` is spliced into the enclosing call at
evaluation time — it's the fundamental mechanism behind variadic operations and is relied on
heavily in Wolfram code that uses patterns, Apply, Fold, etc.

**Proposed fix.** In the argument-preparation step of the evaluator (after arguments are
individually evaluated, before dispatch), walk the argument list and splice any
`Sequence[...]` inline. Optionally honor Wolfram's exception list (`Hold`, `HoldComplete`,
`Unevaluated`, `HoldPattern`, `Function`) that do not splice — but those will already be
handled correctly if B17 lands first, because `Hold` arguments simply aren't evaluated.

### B16. Parser accepts `--5` where Wolfram rejects it

- **Category**: parser permissiveness
- **Priority**: P4 (cosmetic)
- **Source**: prefix-minus handling in the Pratt parser
- **Tests**: `DoubleUnaryMinusTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
--5    Tungsten: 5              Kernel: $Failed (syntax error)
```

Wolfram reserves `--` as `Decrement`, a side-effectful operator, so `--5` is a syntax error
in the kernel (no lvalue). Tungsten's parser treats `-` as a prefix operator and happily
chains two of them.

**Proposed fix.** Low-priority. Could tokenize `--` and `++` as reserved Decrement/Increment
operators, or simply reject two consecutive unary minuses. Not worth a dedicated pass.

### B17. `Hold`, `HoldComplete`, `HoldForm`, `Unevaluated` evaluate their arguments

- **Category**: missing evaluator feature (foundational)
- **Priority**: **P1**
- **Source**: no explicit handling; these are treated as plain unknown heads.
- **Tests**: `HoldFamilySemanticsTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
Hold[1 + 2]            Tungsten: Hold[3]               Kernel: Hold[Plus[1, 2]]
HoldComplete[1 + 2]    Tungsten: HoldComplete[3]       Kernel: HoldComplete[Plus[1, 2]]
HoldForm[1 + 2]        Tungsten: HoldForm[3]           Kernel: HoldForm[Plus[1, 2]]
Unevaluated[1 + 2]     Tungsten: Unevaluated[3]        Kernel: Unevaluated[Plus[1, 2]]
```

**Background.** Wolfram gives these heads the `HoldAll` (or `HoldAllComplete`) attribute,
which suppresses evaluation of their arguments. Tungsten has no attribute mechanism, so it
evaluates the argument first and then wraps it in the inert head — the exact opposite of
what Hold is supposed to do.

This is arguably the highest-impact semantic gap in this report. `Hold` is foundational in
Wolfram code for:

- deferred evaluation
- pattern-based meta-programming (`Hold[expr] /. pattern :> ...`)
- displaying unevaluated forms in pedagogical material
- implementing higher-order functions that need to inspect structure before evaluation

Many user-written snippets will silently compute the wrong thing because the hold fails.

**Proposed fix.** Hardcode a small `_HOLD_ALL_HEADS` set in the evaluator and have the
argument-evaluation step skip evaluation for children of calls whose head is in that set.
Something like:

```python
_HOLD_ALL_HEADS = frozenset({
    "Hold", "HoldComplete", "HoldForm", "Unevaluated", "HoldPattern",
    # "Function" already has a special case elsewhere
})

def evaluate(expr: Expr) -> Expr:
    ...
    if isinstance(expr, Call):
        if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _HOLD_ALL_HEADS:
            return Call(head_expr=expr.head_expr, arguments=expr.arguments)  # don't recurse
        ...
```

Combined with B18 (`ReleaseHold`), that restores the Hold-family semantics for ~99% of real
use cases without requiring a general attribute model.

Note: Tungsten's `Function[body]` / `Function[params, body]` already has analogous "don't
evaluate body" behavior (documented in `expression-parser.md`), so the pattern isn't new —
just needs to be extended to the Hold family.

### B18. `ReleaseHold` doesn't release the wrapper

- **Category**: missing evaluator feature (companion to B17)
- **Priority**: P1 (bundled with B17)
- **Source**: no explicit handling
- **Tests**: `HoldFamilySemanticsTests.test_release_hold_wolfram_target` (expected-failure)

**Observed.**

```text
ReleaseHold[Hold[1 + 2]]    Tungsten: ReleaseHold[Hold[3]]    Kernel: 3
```

Tungsten evaluates inside `Hold` (per B17), so `ReleaseHold` sees `Hold[3]` as input. But
Tungsten has no evaluator case for `ReleaseHold`, so the whole expression stays inert.

**Proposed fix.** Add a one-case evaluator for `ReleaseHold`:

```python
if evaluated_head.name == "ReleaseHold":
    if len(evaluated_arguments) != 1:
        raise WolframEvaluationError("ReleaseHold expects exactly one argument.")
    argument = evaluated_arguments[0]
    if isinstance(argument, Call) and isinstance(argument.head_expr, Symbol) \
            and argument.head_expr.name in {"Hold", "HoldComplete", "HoldForm"}:
        return evaluate(
            Call(head_expr=Symbol("CompoundExpression"), arguments=argument.arguments)
            if len(argument.arguments) > 1
            else argument.arguments[0]
        )
    return argument
```

(Tighten as needed for Tungsten's exact internals; the shape is what matters.)

## Other observations

These didn't warrant a numbered finding but are worth a paragraph each.

### Operator-form consistency

Tungsten supports `Select[crit][coll]` and `SelectFirst[crit][coll]` operator forms but
rejects `Map[f][coll]` and `Cases[patt][coll]`. The docs say Map and Cases support "direct
forms only" but a reasonable reader might not notice the asymmetry. Low-priority doc nit:
`docs/expression-function-support.md` should state explicitly which functions support
one-argument operator forms.

### Listable threading (documented but easy to trip on)

`Plus[{1,2}, {3,4}]`, `Sign[{-3, 0, 5}]`, `Abs[{-3, 4}]`, `Mod[{10,20}, 3]` all stay inert
in Tungsten. In Wolfram these thread over lists because of the `Listable` attribute.
Documented in Tungsten's "no Listable" disclaimer, but this is the single most common
"huh, I expected that to work" source because Wolfram users heavily rely on Listable.

Consider adding a short "Listable heads" appendix to `expression-parser.md` listing the
heads that are Listable in Wolfram but stay inert in Tungsten, so users can grep for their
scenario.

### Control-flow heads reject empty args where Wolfram would accept

`If[]`, `Which[]`, `Switch[]`, `Piecewise[{}]` — mixed behavior:

- `Piecewise[{}]` → Tungsten correctly returns `0` (matches kernel).
- `If[]`, `Which[]`, `Switch[]` → Tungsten raises. Wolfram: either returns the inert head
  or gives a specific result. For `Which[]`, Wolfram returns `Null`. For `If[]`, Wolfram
  would error.

Not strictly bugs, but worth a pass for consistency with the `Plus[]` / `Times[]` / `And[]`
/ `Or[]` zero-argument conventions.

### StringExpression multiple-unbounded-element rejection

`StringMatchQ["abc123", LetterCharacter.. ~~ DigitCharacter..]` → Tungsten raises with
"at most one unbounded element". Documented. But the error kills the whole caller; there's
no way to degrade gracefully (e.g., fall back to regex). Not a bug — just a rough edge for
users exploring string patterns.

## Recommended roadmap (updated from first report)

With B10–B18 in hand, the priority stack is:

### Tier 1 — highest-impact bugs

1. **B17 + B18** (Hold family + ReleaseHold) — restores Hold semantics for almost all user
   code with ~20 LOC in the evaluator dispatch. Biggest single DX improvement.
2. **B10** (`@` precedence) — one-line change, fixes the most common "wait, what?" when
   mixing `@` with arithmetic.
3. **B1 + B7 + B11** (n-ary infix flattening) — one post-parse pass flattens chained `<`,
   `>`, `==`, `!=`, `+`, `*`, `;;`, `<>`, `&&`, `||`. Fixes B1, B7, B11, and the pure-function
   composition case in a single change.
4. **B2** (Position default levelspec) — one-line change.

### Tier 2 — localized evaluator fixes

5. **B13** (association-as-function) — one evaluator case, unlocks the documented `#name`
   shorthand end-to-end.
6. **B14** (FixedPoint soft limit) — five-line change across `fixed_point` and
   `fixed_point_list`.
7. **B12** (KeyMap re-evaluation) — one-line fix (use `_apply_callable`).
8. **B5** (Dot re-evaluation) — one-line fix (wrap return in `evaluate`).
9. **B6** (Association duplicate-key position) — two-line fix in `_normalize_association_entries`.
10. **B3 + B4** (Level semantics + traversal order) — together.

### Tier 3 — feature additions

11. **B15** (Sequence splicing) — new evaluator feature, moderate impact.
12. **B16** (`--5` permissiveness) — trivial, cosmetic.
13. **B8** (`Infinity` as `DirectedInfinity[1]`) — rendering rule.
14. **B9** (Real backtick FullForm) — defer until real arithmetic lands.

### Documentation follow-ups

- Document which functions accept operator forms (Select yes, Map/Cases no).
- Add a "Listable heads" appendix listing heads that are Listable in Wolfram but stay inert
  in Tungsten.
- Document that `Hold` / `HoldComplete` / `HoldForm` / `Unevaluated` / `ReleaseHold` are
  currently unsupported (until B17/B18 land), so users don't assume they work based on
  Wolfram mental models.
- State Position's default levelspec explicitly (and note it differs from `Cases`).
- Clarify Association duplicate-key behavior with "first-occurrence position preserved"
  once B6 is fixed.

## Closing thoughts

The evil-QA pass found three clusters of bugs:

1. **Parser shortcuts** — binary-tree operators (B1, B7, B10, B11, B16). A single n-ary
   post-parse flattening pass plus a precedence fix for `@` dissolves most of this cluster.
2. **Missing "don't evaluate" attribute** — Hold-family (B17, B18) and Sequence splicing (B15).
   These share a design concern: Tungsten has no general Wolfram-attribute model, so any
   Wolfram-specific evaluation-order rule needs ad-hoc head-set handling. The `Function`
   body-held case already demonstrates the pattern works; extending it to a handful of other
   heads is mechanical.
3. **Missing re-evaluation passes** — KeyMap (B12), Dot (B5), FixedPoint (B14),
   association-as-function (B13). These are all local fixes where the evaluator builds a
   correctly-structured result but then hands it back to the caller without the expected
   simplification pass.

None of these blocks Tungsten's stated purpose — most real users working inside the
documented scope will land on the 150/178 (84%) parity region. But every one of the 9 new
findings is a case where a thoughtful user would expect parity and not get it. The
regression-test file is structured so that as each fix lands, the corresponding
`*_wolfram_target` test silently flips from expected-failure to expected-success. Clean
signal on progress, zero CI noise in the meantime.

One last operational compliment: the launch-gate and license-slot stabilization held up
nicely under stress. During this review I accidentally stacked four concurrent Python
invocations of the same harness early on (each spawning its own Wolfram batch), and the
gate serialized them cleanly. Once I noticed and killed the zombies, the single clean run
went through 178 cases in about 60 seconds. That's exactly the kind of infrastructure you
want underneath a differential harness — "don't think about it, just works."

Overall: the evaluator is a lot of surface area and it's holding up remarkably well. The
findings above are what you'd want to find after a hostile review pass, not what you'd fear.
