# Tungsten Expression Parser/Evaluator vs Live Wolfram Kernel: Parity Review

- Status: **Archived — superseded.** Active gap inventory: `../2026-04-27-tungsten-gap-and-shape-review.md`. All B1–B9 findings have been resolved (n-ary infix flattening, `Position` default `{0, Infinity}`, postorder `Level` traversal with sign-aware spec, `Dot` re-evaluation, association duplicate-key first-occurrence position, `DirectedInfinity` rendering, `@` precedence, etc.) and the relevant `*_wolfram_target` test classes have flipped to passing. **Do not treat this document as current state.**

  Original status line: Report (differential review of `expression.py` against the local Wolfram 14.3 kernel).
- Audience: Vladimir Reshetnikov, Tungsten maintainers
- Scope: `src/Tungsten/src/tungsten/expression.py`, documented support matrix in `docs/expression-function-support.md` and `docs/expression-parser.md`
- Created (UTC): 2026-04-24T19:38:47Z
- Repository HEAD: 110bbc4bc5b6ce3af5afd0e8cabbfef42d15a55e
- Related artifacts:
  - [`tests/test_expression_kernel_parity.py`](../../tests/test_expression_kernel_parity.py) — new regression tests added as part of this review (14 expected-failure targets lock in each bug's Wolfram-correct behavior)
  - External harness (not committed): `C:\tmp\tungsten-diff\diff_harness.py` — 298-case differential runner used to generate these findings

## Contents

1. [Executive summary](#executive-summary)
2. [Methodology](#methodology)
3. [Findings](#findings) — 9 numbered findings (B1–B9) with file:line citations
4. [Documented behaviors that look like bugs but are not](#documented-behaviors-that-look-like-bugs-but-are-not)
5. [Recommended fix roadmap](#recommended-fix-roadmap)
6. [Harness reusability note](#harness-reusability-note)

## Executive summary

Since yesterday's review, `expression.py` has grown from ~1,800 lines to ~7,070 lines and the documented evaluator surface has expanded to roughly 160+ built-ins, full pattern matching (with sequence patterns), associations, pure functions (positional and named), string patterns, byte arrays, and base encoding. It's a lot of surface, and overall **the parity with the live kernel within the documented scope is excellent** — 234/251 cases in the first pass match exactly, and 252/298 in the expanded pass.

The mismatches that remain fall into two groups:

1. **Seven real bugs** (B1–B7) inside the documented scope — these are cases where the docs do not advertise a divergence, but Tungsten's output differs from the kernel's in ways that would surprise a user. The most impactful are **B1 (chained comparisons)** and **B2 (Position's default levelspec)**; both are one-file changes with high user-visible impact.
2. **Two cosmetic/semantic divergences** (B8–B9) that are worth flagging but are low-priority.

The rest of the differential run is dominated by documented, intentional gaps (integer-only arithmetic, no Orderless/Flat, named sequence patterns out of scope, etc.) — well-advertised in `docs/expression-parser.md` and `docs/expression-function-support.md`.

**Tl;dr priority order for fixes:**

| ID | Summary | Priority | Estimated reach |
|----|---------|----------|------------------|
| B1 | Chained comparisons parse as left-associative binary, so `1 < 2 < 3` stays inert | **P1** | ~20 LOC in `_parse_infix_operator` (or a small post-parse flattening pass) |
| B2 | `Position[...]` default levelspec is `{1}` instead of `{0, Infinity}` | **P1** | 1 LOC at `expression.py:4233` |
| B3 | `Level[expr, -n]` returns only depth-n atoms instead of `{1, -n}` range | **P2** | 1 LOC at `expression.py:7040` plus test re-baseline |
| B4 | `Level` traversal is preorder; kernel is postorder | **P2** | 3–5 LOC in `_collect_levels` at `expression.py:7016` |
| B5 | `Dot` returns unsimplified `Plus[Times[...], ...]` instead of re-evaluating | **P2** | 2 LOC in `dot()` at `expression.py:4359` and `:4383` |
| B6 | Association duplicate keys move the winning entry to the later position | **P2** | 2 LOC in `_normalize_association_entries` at `expression.py:415` |
| B7 | Parser produces left-associative binary trees for `+`, `*`, `<>`, etc.; structural root of B1 | **P3** | Either n-ary post-parse flatten or refactor the Pratt loop |
| B8 | `Min[]` / `Max[]` / `Infinity` render as the symbol `Infinity` instead of `DirectedInfinity[1]` | **P3** | Cosmetic — one function or a rendering rule |
| B9 | Real-number FullForm uses `2.0` instead of Wolfram's backtick notation `2.\`` | **P4** | Low-impact cosmetic divergence |

## Methodology

A single Python harness (see `C:\tmp\tungsten-diff\diff_harness.py`) generates a corpus of 298 input expressions that cover the documented feature surface:

- core arithmetic, relational, and Boolean heads
- predicate heads (`IntegerQ`, `StringQ`, `EvenQ`, etc.)
- structural queries (`Length`, `Depth`, `Head`, `First`, …)
- `Part` / `Extract` / `Level` and their spec variants
- `Take` / `Drop` / `Append` / `Prepend` / `Join` / `Reverse` / `Rotate*` / `Flatten` / `Delete` / `ReplacePart` / `MapAt` / `ReplaceAt`
- `Apply` / `Map` / `MapAll` / `MapIndexed` / `MapApply` / `Through` / `MapThread` / `Thread` / `Distribute` / `Outer` / `Inner` / `Dot`
- positional and named pure functions, `Composition` / `RightComposition`, `Nest*`, `Fold*`, `FixedPoint*`, `Operate`
- `Cases` / `DeleteCases` / `FirstCase` / `Position` / `MemberQ` / `MatchQ` / `FreeQ` / `DeleteDuplicates*` / `DuplicateFreeQ`
- `Replace` / `ReplaceAll` / `ReplaceRepeated` plus the lowered infix `/.` / `//.`
- control flow: `If`, `Which`, `Switch`, `Piecewise`, `Boole`
- `Select` / `Discard` / `SelectFirst` / `TakeWhile` / `Pick` / `LengthWhile`
- `Range` / `Array` / `ConstantArray` / `UnitVector` / `IdentityMatrix` / `DiagonalMatrix` / `Tuples` / `Partition` / `BlockMap` / `TakeList` / `TakeDrop`
- integer "special" heads: `UnitStep`, `Mod`, `Quotient`, `QuotientRemainder`, `Min`, `Max`, `Clip`, `KroneckerDelta`, `DiscreteDelta`, `Ramp`, `Sign`, `Abs`
- strings: `StringLength`, `StringTake`, `StringDrop`, `StringJoin`, `StringInsert`, `StringReverse`, `Characters`, `ToCharacterCode`, `FromCharacterCode`
- string patterns: `StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, `StringReplace`
- associations: `Association`, `AssociationQ`, `Keys`, `Values`, `Normal`, `Lookup`, `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`, `KeyMap`, `KeyValueMap`, `AssociationThread`, `AssociationMap`, plus duplicate-key, `Part[assoc, Key[k]]`, and `Map` over associations
- byte arrays: `ByteArray`, `BaseEncode`, `BaseDecode`, `StringToByteArray`, `ByteArrayToString`
- targeted edge cases (empty lists, empty associations, `0^0`, `Plus[]`, `Times[]`, negative exponents, etc.)

For each case, the harness:

1. Evaluates the input through Tungsten's in-process Python API (fast; no subprocess).
2. Evaluates the same input through the **local Wolfram 14.3 kernel** in a single batched invocation. The kernel script uses `ToExpression[..., InputForm, HoldComplete]` to isolate parse failures from evaluation failures and emits each result's `FullForm` via `ToString[FullForm[result]]` inside a per-case association that is marshalled to JSON with `ExportString[..., "RawJSON"]`.
3. Compares Tungsten's `full_form` against the kernel's FullForm string, after trivial whitespace normalization.

All 298 cases execute in a single kernel invocation (~25–40 s total, dominated by kernel startup), which plays nicely with the launch-gate and license-slot stabilization in `wolfram_processes.py`. No evidence of intermittent license contention during the run.

## Findings

Each finding has: what the differential run saw, the root cause in `expression.py`, a proposed fix sketch, and the regression-test identifier in `tests/test_expression_kernel_parity.py` that locks it in.

### B1. Chained comparisons stay inert because the parser is left-associative

- **Category**: parser bug, semantic impact
- **Priority**: P1
- **Source**: [`expression.py:6871-6878`](../../src/tungsten/expression.py#L6871-L6878) (Pratt operator table) plus `_parse_infix_operator` at line 6860
- **Tests**: `ChainedComparisonTests.*_wolfram_target` (expected-failure)

**Observed.** Tungsten parses `a < b < c` as `Less[Less[a, b], c]`. The inner `Less[a, b]` evaluates to `True`, and the outer `Less[True, c]` is inert because `True` is not an explicit integer. So:

```text
1 < 2 < 3     Tungsten: Less[True, 3]        Kernel: True
1 < 3 < 2     Tungsten: Less[True, 2]        Kernel: False
1 == 1 == 1   Tungsten: Equal[True, 1]       Kernel: True
5 >= 5 >= 3   Tungsten: GreaterEqual[True, 3] Kernel: True
1 != 2 != 3   Tungsten: Unequal[True, 3]     Kernel: True
1 < 2 == 2    Tungsten: Equal[True, 2]       Kernel: True (Inequality[1, Less, 2, Equal, 2])
```

**Root cause.** The operator table at `expression.py:6871-6878` gives each relational operator the same `_COMPARE_BP` (left and right) which, combined with the standard Pratt loop, produces left-associative binary trees. There is no post-parse pass that collapses runs of same-operator comparisons into an n-ary call.

**Proposed fix.** Two reasonable options:

1. **Post-parse n-ary collapsing pass** (simpler): after parsing, walk the tree once and merge `Less[Less[a, b], c]` into `Less[a, b, c]` when the outer and inner have the same head and the head is in `{Less, LessEqual, Greater, GreaterEqual, Equal, Unequal, SameQ, UnsameQ}`. This also fixes B7 as a side effect if extended to `Plus`, `Times`, `StringJoin`, `And`, `Or`, `StringExpression`.
2. **Pratt-loop flattening** (more invasive): in `_parse_infix_operator`, when the incoming operator matches the head of the current left-hand-side call and the head is one of the flattenable operators, append to the existing arg list rather than wrapping.

Wolfram also supports **mixed** chained comparisons like `1 < 2 == 2`, which the kernel parses as `Inequality[1, Less, 2, Equal, 2]`. Matching that fully is a separate feature; the table above labels it as a known gap.

### B2. `Position` defaults to level `{1}` instead of `{0, Infinity}`

- **Category**: evaluator bug
- **Priority**: P1
- **Source**: [`expression.py:4233`](../../src/tungsten/expression.py#L4233) in `def position(...)`
- **Tests**: `PositionDefaultLevelSpecTests.test_position_default_wolfram_target` (expected-failure)

**Observed.** Tungsten's default is level 1, so `Position[f[a, g[b, a]], a]` returns `{{1}}`. Kernel: `{{1}, {2, 2}}`. When called with explicit `{0, Infinity}`, Tungsten agrees with the kernel.

**Root cause.** `level_spec = integer(1) if spec is None else spec` at line 4233. Wolfram's default for `Position` is `{0, Infinity}` (search everywhere, including heads), not the common `{1}` that `Cases`/`DeleteCases` use.

**Proposed fix.** Change the default to a level-0-through-infinity specification:

```python
level_spec = list_expr(integer(0), symbol("Infinity")) if spec is None else spec
```

(or the equivalent tuple representation the normalizer already understands). While you're there, consider adding an explicit `Position` support-table entry in `docs/expression-function-support.md` that names the default levelspec — that's currently not stated anywhere and it's the kind of thing a user needs to know.

### B3. `Level[expr, -n]` returns only depth-n atoms instead of levels `{1, -n}`

- **Category**: evaluator bug
- **Priority**: P2
- **Source**: [`expression.py:7036-7040`](../../src/tungsten/expression.py#L7036-L7040) in `_normalize_level_spec`
- **Tests**: `LevelSemanticsTests.test_level_minus_one_wolfram_target` (expected-failure)

**Observed.** For `f[a, g[b, c], h[k[d]]]`:

```text
                       Tungsten              Kernel
Level[..., -1]         {a, b, c, d}          {a, b, c, g[b, c], d, k[d], h[k[d]]}
Level[..., -2]         {g[b,c], k[d]}        {g[b, c], k[d], h[k[d]]}
```

**Root cause.** The Wolfram rule is:

> For non-negative `n`, `Level[expr, n]` is shorthand for `Level[expr, {1, n}]`. For negative `n`, `Level[expr, -n]` is shorthand for `Level[expr, {1, -n}]`.

Tungsten implements the non-negative case correctly at line 7039 (`return (0 if spec == 0 else 1, spec)`), but the negative case at line 7040 returns `(spec, -1)`, which is "only the bottommost level" instead of "from level 1 down to level -n".

**Proposed fix.** Single-line change:

```python
if spec < 0:
    return (1, spec)   # was (spec, -1)
```

**Caveat.** The matching rule in `_level_matches` at line 7066 uses an `OR` between pos- and neg-level checks. With the proposed fix, `level_min=1, level_max=-1` produces `1 <= pos_level <= -1` (always false) OR `1 <= neg_level <= -1` (always false). The matcher needs to be made sign-aware so that the positive bound applies to `pos_level` and the negative bound applies to `neg_level` independently, AND-combined. A reasonable formulation:

```python
def _level_matches(record, level_min, level_max):
    lower_ok = (
        record.positive_level >= level_min if level_min >= 0
        else record.negative_level >= level_min
    )
    upper_ok = (
        record.positive_level <= level_max if level_max >= 0
        else record.negative_level <= level_max
    )
    return lower_ok and upper_ok
```

This also fixes the related `Level[expr, {1, -1}]` case (currently undefined behavior in Tungsten) and mixed-sign specs generally. I verified by running the same probe against the kernel with explicit `{1, -1}`, `{-2}`, `{2}`, etc. and confirming the Wolfram behavior is what this matcher would produce.

### B4. `Level` traversal is preorder; kernel uses postorder

- **Category**: evaluator bug
- **Priority**: P2
- **Source**: [`expression.py:7016-7025`](../../src/tungsten/expression.py#L7016-L7025) in `_collect_levels`
- **Tests**: `LevelSemanticsTests.test_level_*_wolfram_target` (expected-failure)

**Observed.** `Level[f[a, g[b, c]], Infinity]`:

```text
Tungsten: {a, g[b, c], b, c}     — preorder: container, then children
Kernel  : {a, b, c, g[b, c]}     — postorder: children, then container
```

This is true for any spec where multiple levels are visited, including `Level[..., 2]`, `Level[..., Infinity]`, `Level[..., -1]` after fix B3, etc.

**Root cause.** `_collect_levels` at line 7017 appends the record for the current expression **before** recursing into its arguments:

```python
def _collect_levels(expr, positive_level, target):
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, ...))
    # ... then recurse
```

**Proposed fix.** Swap the order so children are visited first:

```python
def _collect_levels(expr, positive_level, target):
    entries = _association_entries(expr)
    if entries is not None:
        for entry in entries:
            _collect_levels(entry.value, positive_level + 1, target)
    elif isinstance(expr, Call):
        for argument in expr.arguments:
            _collect_levels(argument, positive_level + 1, target)
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, ...))
```

The root itself is then at the very end of the list; the existing `_level_matches` filter will still exclude it for the common `{1, ...}` and `{0 + positive, ...}` ranges. Double-check the `{0, 0}` case (root only) still works after the change.

### B5. `Dot` constructs a `Plus[Times[...], ...]` sum-of-products but never re-evaluates

- **Category**: evaluator bug
- **Priority**: P2
- **Source**: [`expression.py:4348-4390`](../../src/tungsten/expression.py#L4348-L4390) in `dot(...)`, dispatched at line 5838 (`evaluated_head.name == "Dot"`)
- **Tests**: `DotEvaluationTests.test_dot_*_wolfram_target` (expected-failure)

**Observed.**

```text
{1, 2, 3} . {4, 5, 6}
   Tungsten: Plus[Times[1, 4], Times[2, 5], Times[3, 6]]
   Kernel  : 32

{{1, 2}, {3, 4}} . {5, 6}
   Tungsten: {Plus[Times[1, 5], Times[2, 6]], Plus[Times[3, 5], Times[4, 6]]}
   Kernel  : {17, 39}
```

Crucially, the same expression that `dot_two` produces does evaluate to `32` when handed to `evaluate(...)` directly:

```text
Plus[Times[1, 4], Times[2, 5], Times[3, 6]]  →  32      (Tungsten)
```

So the **arithmetic pipeline exists and fires**; the bug is that `dot_two` returns the constructed `Plus`/`Times` tree without routing it back through `evaluate()`.

**Root cause.** The three return statements in `dot_two` (lines 4359, 4365, 4375, 4383) all construct a `Call` and return it directly. The outer caller `dot()` likewise returns `current` without re-evaluating.

**Proposed fix.** Wrap the final return in `evaluate(...)`. Simplest:

```python
def dot(arguments: Sequence[Expr]) -> Expr:
    ...
    current = arguments[0]
    for argument in arguments[1:]:
        current = dot_two(current, argument)
    return evaluate(current)
```

I verified this is consistent with how sibling functions like `Outer`, `Inner`, `MapThread`, `Fold`, `Nest`, `Apply` behave (they all re-evaluate their result correctly — `Inner[Times, {1,2,3}, {4,5,6}, Plus]` → 32 in Tungsten today). `Dot` is the odd one out.

### B6. Association duplicate keys move the winning entry to the later position

- **Category**: evaluator bug
- **Priority**: P2
- **Source**: [`expression.py:415-426`](../../src/tungsten/expression.py#L415-L426) in `_normalize_association_entries`
- **Tests**: `AssociationDuplicateKeyTests.test_duplicate_key_wolfram_target` (expected-failure)

**Observed.**

```text
<|a -> 1, b -> 2, a -> 3|>
   Tungsten: <|b -> 2, a -> 3|>    — 'a' placed in the later position
   Kernel  : <|a -> 3, b -> 2|>    — 'a' keeps its first-occurrence position

<|a -> 1, b -> 2, c -> 3, b -> 4|>
   Tungsten: <|a -> 1, c -> 3, b -> 4|>
   Kernel  : <|a -> 1, b -> 4, c -> 3|>
```

**Root cause.** Current logic:

```python
for entry in entries:
    previous = last_positions.get(entry.key)
    if previous is not None:
        ordered[previous] = None        # null the earlier slot
    last_positions[entry.key] = len(ordered)
    ordered.append(entry)               # append at the end
```

This is "last-occurrence-at-later-position". Wolfram's documented behavior is last-occurrence-value but first-occurrence-position.

**Proposed fix.** On duplicate, **update** the existing slot instead of nulling it and appending:

```python
for entry in entries:
    previous = last_positions.get(entry.key)
    if previous is not None:
        ordered[previous] = entry       # overwrite in place
    else:
        last_positions[entry.key] = len(ordered)
        ordered.append(entry)
```

The `ordered` list then has no `None` holes, and the trailing filter can simplify to `return tuple(ordered)`. This matches Wolfram's behavior on every duplicate case I exercised.

The docs in `docs/expression-function-support.md` currently state *"last-occurrence-wins duplicate-key semantics"*. That's true of the value, but the position story is worth spelling out — recommended doc update is to add "with the first-occurrence position preserved" to that sentence.

### B7. Parser produces left-associative binary trees for `+`, `*`, `<>`, etc. instead of n-ary

- **Category**: parser divergence, low direct impact
- **Priority**: P3 (but **fixing this dissolves B1 as a side effect**)
- **Source**: `expression.py:6864-6891` (operator table); `_parse_infix_operator` Pratt loop
- **Tests**: `ParserNaryGroupingTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
a + b + c        Tungsten: Plus[Plus[a, b], c]       Kernel: Plus[a, b, c]
a * b * c        Tungsten: Times[Times[a, b], c]     Kernel: Times[a, b, c]
a + b - c        Tungsten: Plus[Plus[a, b], Times[-1, c]]
                 Kernel  : Plus[a, b, Times[-1, c]]
"a" <> "b" <> "c"  Tungsten: StringJoin[StringJoin["a", "b"], "c"]
                   Kernel  : StringJoin["a", "b", "c"]
```

**Why most cases still look right.** For all-integer/all-string inputs, the Tungsten evaluator works bottom-up and collapses the binary tree into the same final result the kernel would produce. For mixed inputs where Orderless sorting matters (e.g., `1 + a`), Tungsten correctly leaves it as `Plus[1, a]` and FullForm matches the kernel. So the binary-tree structure is mostly invisible.

The one place it isn't invisible is **chained comparisons** (B1): `Less[Less[a, b], c]` does not collapse because the inner result is `True`, and Tungsten's integer-only `Less` evaluator refuses to keep going.

**Proposed fix.** Add a post-parse pass (or modify the Pratt loop) to flatten same-head infix runs for the Wolfram-canonical operators. Since `Less`/`Equal`/etc. need this anyway (B1), handling `Plus`/`Times`/`StringJoin`/`And`/`Or`/`StringExpression` at the same time is a small add. My suggestion: a dedicated `_flatten_parser_nary` post-pass is easier to review than changes to the Pratt loop.

### B8. `Infinity` renders as the bare symbol instead of `DirectedInfinity[1]`

- **Category**: cosmetic FullForm divergence
- **Priority**: P3
- **Source**: `Min[]` / `Max[]` implementations (search `expression.py` for the `Min` / `Max` evaluator dispatch and the associated `Infinity` / `-Infinity` construction)
- **Tests**: `InfinityRenderingTests.*_wolfram_target` (expected-failure)

**Observed.**

```text
Min[]         Tungsten FullForm: Infinity         Kernel FullForm: DirectedInfinity[1]
Max[]         Tungsten FullForm: -Infinity        Kernel FullForm: DirectedInfinity[-1]
Infinity      Tungsten FullForm: Infinity         Kernel FullForm: DirectedInfinity[1]
```

In Wolfram, the user-facing `Infinity` symbol is syntactic sugar and immediately evaluates to `DirectedInfinity[1]` in FullForm. Tungsten treats it as a plain `Symbol`.

**Proposed fix.** Two options:

1. Emit `Call(Symbol("DirectedInfinity"), Integer(1))` wherever Tungsten currently emits the `Infinity` symbol, and similarly `DirectedInfinity[-1]` for `-Infinity`. This propagates into `Min[]` / `Max[]` automatically.
2. Keep the internal representation as the symbol but override FullForm rendering for `Infinity` / `-Infinity`. Lower-risk but makes later arithmetic comparisons with `DirectedInfinity[...]` harder.

Given that Tungsten already has integer-only arithmetic, option 1 is probably cleanest. This is cosmetic today, but if Tungsten later adds any semantic evaluation of `Infinity` + something, the canonical form will matter.

### B9. Real numbers use `2.0` instead of Wolfram's backtick notation `2.\``

- **Category**: cosmetic FullForm divergence (very low impact)
- **Priority**: P4
- **Source**: `Real.to_full_form` in `expression.py:91-104`
- **Tests**: none added (not a useful regression target right now)

**Observed.**

```text
Cases[{1, a, 2.0, "s"}, _Integer | _Real]
   Tungsten FullForm: List[1, 2.0]
   Kernel  FullForm: List[1, 2.`]
```

Wolfram renders machine-precision reals with a trailing backtick in FullForm; the `` 2.` `` form is how Wolfram indicates "this is a Real, not an Integer written with decimal point" when round-tripping through `ToExpression`. Tungsten currently doesn't do float arithmetic so this doesn't hurt anyone today.

**Proposed fix.** If/when Tungsten gains real arithmetic, update the `Real.to_full_form` rendering to match Wolfram's conventions. Defer.

## Documented behaviors that look like bugs but are not

The differential run flagged the following as "mismatches" but they are all explicitly covered in `docs/expression-parser.md` or `docs/expression-function-support.md`. They are included here so readers of this report don't mistake them for new bugs:

| Case | Tungsten | Kernel | Why it's intentional |
|------|----------|--------|-----------------------|
| `2^-1` | `Power[2, -1]` | `Rational[1, 2]` | "Negative exponents remain inert in this pass." (integer-only scope) |
| `6 / 2` | `Times[6, Power[2, -1]]` | `3` | Same — no Rational support, and the parser lowers `/` to `Times[..., Power[..., -1]]` |
| `Length[Plus[1, 2, a]]` | `3` | `2` | Docs: Plus does not flatten/reorder at evaluation |
| `True && False && x` | `And[False, x]` | `False` | Docs: "no short-circuit or flattening" |
| `MatchQ[f[a, b, c], f[x__]]` | parse error | `True` | Named sequence patterns explicitly out of scope |
| `StringMatchQ["abc123", LetterCharacter.. ~~ DigitCharacter..]` | eval error | `True` | Docs: "at most one unbounded string-pattern element" |
| `0^0` | inert Power | `Indeterminate` | Docs: "excluding 0^0" |
| `Plus[1, 2, a]` (direct call) | inert | `3 + a` | Docs: direct `Plus[...]` evaluates only when every arg is explicit integer |
| `Total[{1, 2, 3}]`, `Count[{1, 2, 3, 2, 1}, 2]`, `Max[{3, 1, 4}]`, `Sort[{3, 1, 4}]` | inert | kernel value | Simply not implemented yet. `Max`, `Min` accept `Max[i1, ...]` but not a list argument, because Tungsten doesn't flatten. Worth tracking as a follow-up if these are useful for user scripts. |

Status note added 2026-04-25: the named sequence-pattern and multiple-unbounded-string-pattern
rows above were accurate when this historical report was written, but both limitations have since
been removed. Current string-pattern coverage is documented in
`docs/expression-function-support.md`.

One doc-level observation: `Position`'s default levelspec is **not** stated in `docs/expression-function-support.md` (the row just says "Returns exact structural positions"). Once B2 is fixed, add a line like *"Default levelspec is `{0, Infinity}`, matching the kernel."* This prevents the same confusion from resurfacing.

## Recommended fix roadmap

### Tier 1 (high-impact, low-cost)

1. **B2** — change Position default to `{0, Infinity}`. One-line fix.
2. **B1 + B7** together — add a post-parse n-ary flattening pass for the documented Wolfram-flat operators (`Less`, `LessEqual`, `Greater`, `GreaterEqual`, `Equal`, `Unequal`, `SameQ`, `UnsameQ`, `Plus`, `Times`, `And`, `Or`, `StringJoin`, `StringExpression`). Fixes chained comparisons and brings parser output into Wolfram-canonical shape in one change.

### Tier 2 (medium-impact, localized)

3. **B3 + B4** together — fix `_normalize_level_spec` for negative ints AND change `_collect_levels` to postorder AND make `_level_matches` sign-aware. These three interact and are easier to land as a single commit with the existing regression tests as the acceptance target.
4. **B5** — wrap `dot()` return in `evaluate(...)`. Two-line fix.
5. **B6** — fix `_normalize_association_entries` to update in place instead of null-then-append. Two-line fix.

### Tier 3 (cosmetic)

6. **B8** — emit `DirectedInfinity[±1]` instead of the bare `Infinity` symbol. A small rendering rule is enough.
7. **B9** — update `Real.to_full_form` once real arithmetic lands. Not worth doing standalone.

### Documentation follow-ups

- State Position's default levelspec in `docs/expression-function-support.md`.
- In the Association row of `docs/expression-function-support.md`, add "with the first-occurrence position preserved" to the duplicate-key description.
- Consider adding an **"Appendix: known divergences from the live kernel"** section to `docs/expression-parser.md` that enumerates the fixed-list of documented differences (integer-only arithmetic, no flattening/orderless, no short-circuit, named sequence patterns out of scope, `Infinity` vs `DirectedInfinity`, etc.). This gives users a single place to check when something "looks odd" and saves repeated triage.

## Harness reusability note

The differential harness at `C:\tmp\tungsten-diff\diff_harness.py` is throwaway-style for this session, but the pattern is worth formalizing. Specifically:

- A single kernel batch through `WolframKernelRunner.evaluate_text(...)` for the entire corpus is dramatically cheaper than per-case invocations and plays well with the new launch-gate and license-slot stabilization.
- The `ToString[FullForm[result]]` pattern (instead of `ToString[result, FullForm, opts]`, which this kernel rejects with `ToString::fmtval`) is the reliable way to get FullForm text out of the kernel on this machine.
- The Wolfram-side parse/eval split using `ToExpression[..., HoldComplete]` then `ReleaseHold` cleanly separates the three failure classes (parse, eval, post-eval stringification) in a way that mirrors Tungsten's own wrapper script.

If Tungsten eventually wants a committed "differential smoke" that runs in CI or on demand, I'd suggest taking this harness, moving it under `src/Tungsten/scripts/`, naming it something like `Test-TungstenKernelParity.ps1` (PowerShell entry) + `diff_kernel_parity.py`, and limiting the corpus to cases that Tungsten currently passes plus a small "expected divergences" list that the script is allowed to skip. That gives you a trip-wire against future regressions without making the build take forever.

## Closing thoughts

The scope expansion since yesterday is substantial and, on balance, well-executed. The evaluator surface feels coherent — most related heads share traversal helpers, pattern matching is wired through the same `_match_pattern` path everywhere, and the integer-only arithmetic discipline gives the implementation a clear "fails closed" stance when it meets anything outside its scope.

The bugs above are real but each one is small and localized. In particular, B1 and B2 together probably account for the lion's share of moments where a user thinks "hmm, that looked like it should have just worked" — and both are one-change-per-bug fixes. If I had to recommend one commit to ship next, it would be `Fix Position default levelspec to {0, Infinity} and flatten n-ary relational/arithmetic infix operators`, which together would land B1, B2, B7, and the documentation clarification. The three `*_wolfram_target` test classes in `tests/test_expression_kernel_parity.py` are ready to flip from `expectedFailure` to `expectedSuccess` the moment those fixes are in.

Good work on the kernel-launch stabilization too, by the way — I didn't see any license-slot flakes or stuck processes during the 5+ kernel invocations this review needed, which is exactly the kind of non-surprise that makes differential work like this possible.
