# Tungsten Expression Subsystem: Deep Parity Review

- Status: Report (focused parity review of `src/Tungsten/src/tungsten/expression.py` against the local Wolfram 14.3 kernel)
- Audience: Vladimir Reshetnikov, Tungsten maintainers
- Scope: `src/Tungsten/src/tungsten/expression.py` (the kernel-free expression subsystem)
- Created (UTC): 2026-04-26T19:04:46Z
- Repository HEAD: a71088d55007ea86a1e13192cd8a437f53057c7c
- Companion artifacts:
  - Earlier reports: `2026-04-24-parser-evaluator-kernel-parity.md` (B1–B9), `2026-04-24-parser-evaluator-kernel-parity-evil-qa.md` (B10–B18)
  - Regression tests: `tests/test_expression_kernel_parity.py`

## Executive summary

Tungsten's kernel-free Wolfram expression subsystem has come a long way since the
B1–B18 review pass. Of the eighteen findings raised in the previous two reports, fourteen
are now resolved — `1 < 2 < 3` evaluates to `True`, `Position` defaults to `{0, Infinity}`,
`Dot` re-evaluates the generated arithmetic, `f @ 1 + 2` parses as `Plus[f[1], 2]`,
`Span[1,9,2]` is ternary, `Hold[1+2]` actually holds, `ReleaseHold` releases, associations
behave as functions, `Sequence[...]` auto-splices, and so on. Five expected-failure tests
remain in `test_expression_kernel_parity.py` and they cover **deliberate** divergences
(binary-tree `Plus[a,b,c]` parsing, `Min[]`/`Max[]` rendering Infinity as a bare symbol).

This report is therefore not a follow-up to the B-series — those are largely closed. It is
a fresh full-tree probe focused on the *next* layer of parity work that the support matrix
either does not yet cover or covers only partially. I drove ~200 adversarial cases through a
batched Wolfram kernel and a Tungsten harness and grouped the divergences by category. The
findings break down as:

- **C1–C5: arity gaps.** Functions Tungsten already implements in 2-arg form whose 3-arg or
  level-spec form is unsupported even though the Wolfram contract is straightforward to extend.
- **C6: arithmetic prefix folding.** Mixed arithmetic such as `Plus[2, a, 3]` and
  `Times[2, 3, a, 4]` stays inert in Tungsten while the kernel folds the numeric prefix and
  returns `Plus[5, a]` / `Times[24, a]`. The current "all-numeric or nothing" rule is the
  single biggest practical divergence I observed.
- **C7: missing built-ins clearly inside the stated long-term scope.**
  `Floor`, `Ceiling`, `Round`, `IntegerPart`, `FractionalPart`, `Total`, `Tally`,
  `Counts`, `Catenate`, `Differences`, `Accumulate`, `Count`,
  `AllTrue`/`AnyTrue`/`NoneTrue`, `ContainsAll`/`ContainsAny`/`ContainsExactly`/`ContainsNone`,
  `Subsets`, `Permutations`, `Union`/`Intersection`/`Complement`, `IntegerDigits`/`FromDigits`,
  `PadLeft`/`PadRight`, `Riffle`, `KeySort`, `Merge`, `KeyComplement`, `KeyUnion`,
  `KeyIntersection`, `GroupBy`, `GatherBy`/`Gather`, `GCD`, `LCM`, `Divisors`, `PrimeQ`,
  `EulerPhi`, `PrimePi`, `NextPrime`, `PowerMod`, `IntegerLength`, `BitAnd`/`BitOr`/`BitXor`,
  `Min[list]`/`Max[list]` (list-folding form), `Norm`, `StringSplit`, `StringRiffle`,
  `StringTrim`, `StringRepeat`, `StringPadLeft`, `StringPadRight`, `StringCount`,
  `ToUpperCase`, `ToLowerCase`, `Capitalize`. Many of these are documented as being out
  of scope only because the doc is silent about them — that silence should be made explicit
  one way or the other.
- **C8: a small handful of real bugs.** `MemberQ[..., patt]` matches at depth `Infinity`
  instead of the kernel default of `1`. `FixedPoint[f, x]` recurses without a structural
  fixpoint when `f` keeps producing distinct shapes (because `Floor`, etc. are inert), and
  the recursion blows the Python stack instead of returning a useful diagnostic.

This report focuses on findings prioritized by how much *expected* behavior they unlock,
not on documentation polish. After the report I picked off the simplest, most clearly-in-scope
items and landed them as a single follow-up commit; that work is captured in the
"Implementation pass" section at the end.

I refer to findings as **C1, C2, …** to avoid colliding with the B-series naming.

## Methodology

Same general approach as the B-series:

1. Build batches of input strings.
2. Submit them through the live Wolfram kernel as one batched evaluation that returns
   `Map[ToString[FullForm[#]] &, Hold[...], {1}]` so each result is its own FullForm string.
3. Evaluate the same inputs through Tungsten and serialize via `Expr.to_full_form()`.
4. Diff side by side and bucket the divergences.

Harness lives at `C:/tmp/tungsten-review/parity_harness.py`. The three case files used for
this report are `cases_arity.json`, `cases_more.json`, and `cases_extra.json` (~200 cases
total).

I used the Tungsten kernel runner (`tungsten.kernel.WolframKernelRunner`) to drive the
kernel, so all license-slot, mathpass-dedup, and launch-gate machinery was exercised
incidentally. It held up cleanly through the entire run, which is itself a small win.

## Findings

### C1. `Map[f, expr, levelspec]` is unsupported

- **Category**: arity gap
- **Priority**: P2
- **Source**: [`expression.py:13003`](../../src/tungsten/expression.py#L13003) (Map dispatch)
- **Status**: open

```text
Map[f, {a, b, c}, {2}]   Tungsten: Map[f, List[a,b,c], List[2]]   Kernel: List[a, b, c]
Map[f, {a, b, c}, 2]      Tungsten: same inert form              Kernel: List[a, b, c]
```

The shipped support matrix says explicitly that "`Map` currently supports `Map[f, expr]`
only", so this is documented. The reason to call it out anyway is that `MapIndexed[f, expr,
levelspec]` already lands all of the level-spec walking infrastructure: the pattern is
"map `f` over every position whose level matches the spec, postorder". Lifting that into
`Map` (and `Apply` — see C2) is a small, mechanical cleanup that closes a real gap.

### C2. `Apply[f, expr, levelspec]` is unsupported

- **Category**: arity gap
- **Priority**: P2
- **Source**: [`expression.py:12977`](../../src/tungsten/expression.py#L12977)
- **Status**: open

```text
Apply[f, {a, b, c}, {1}]              Tungsten: inert                  Kernel: List[a, b, c]
Apply[f, {{a, b}, {c, d}}, {1}]       Tungsten: inert                  Kernel: List[f[a, b], f[c, d]]
Apply[f, {{a, b}, {c, d}}, {0, 1}]    Tungsten: inert                  Kernel: f[f[a, b], f[c, d]]
```

Documented as "supports `Apply[f, expr]` only". Same observation as C1 — once the level-spec
machinery exists for `MapIndexed`, the natural semantics for `Apply[..., spec]` is "replace
the head at every position whose level matches the spec".

### C3. `Take` / `Drop` only support a 2-argument first-level slice

- **Category**: arity gap
- **Priority**: P2
- **Status**: open (documented as "single first-level specification only")

```text
Take[{{1, 2, 3}, {4, 5, 6}}, 2, 2]   Tungsten: inert   Kernel: List[List[1, 2], List[4, 5]]
Take[{{1, 2, 3}, {4, 5, 6}}, All, 2] Tungsten: inert   Kernel: List[List[1, 2], List[4, 5]]
Drop[{{1, 2, 3}, {4, 5, 6}}, None, 1] Tungsten: inert  Kernel: List[List[2, 3], List[5, 6]]
```

This is the dominant Wolfram idiom for getting submatrices. A first cut implementation can
restrict to two trailing specs (matrix slicing) and decline the n-dim general form;
that already covers ~95% of practical use.

### C4. `Partition` only supports the 2-argument and 3-argument forms

- **Category**: arity gap
- **Priority**: P2
- **Status**: open (documented as "one-dimensional direct forms with an optional positive integer offset")

```text
Partition[{1..6}, 2, 2, 1]            Kernel: List[List[1,2], List[3,4], List[5,6]]
Partition[{1..5}, 2, 1, {1, 1}]       Kernel: List[List[1,2], List[2,3], List[3,4], List[4,5], List[5,1]]
Partition[{1..5}, 2, 1, {1, 1}, x]    Kernel: List[List[1,2], List[2,3], List[3,4], List[4,5], List[5,x]]
```

The cyclic-offset and explicit-padding 4- and 5-argument forms are popular for periodic
windowing; the support table calls them out as missing.

### C5. `Range[{m, n}]` and `Array[f, n, origin]` shapes

- **Category**: arity gap
- **Priority**: P3
- **Status**: open

```text
Range[{2, 5}]            Tungsten: inert    Kernel: List[List[1, 2], List[1, 2, 3, 4, 5]]
Array[f, 3, 0]           Tungsten: inert    Kernel: List[f[0], f[1], f[2]]
Array[f, 3, {0, 2}]      Tungsten: inert    Kernel: List[f[0], f[1], f[2]]
DiagonalMatrix[{1,2,3},1] Tungsten: inert   Kernel: 4×4 super-diagonal matrix
UnitVector[3]            Tungsten: inert    Kernel: kernel error (so this matches in spirit)
```

`Array` and `Range` already implement the trickiest part of their semantics; the missing
3-argument origin form is a small uniform extension. `DiagonalMatrix[list, k]` is a similar
small extension. The support table does state these limits explicitly.

### C6. `Plus`/`Times`/`Power` ignore the numeric prefix when the rest is symbolic

- **Category**: evaluator behavior
- **Priority**: **P1** (most user-visible divergence)
- **Source**: [`expression.py:3500`](../../src/tungsten/expression.py#L3500) (`_evaluate_numeric_arithmetic`)
- **Status**: open

```text
Plus[2, a, 3]                  Tungsten: Plus[2, a, 3]    Kernel: Plus[5, a]
Plus[2, a, 3, b]               Tungsten: Plus[2, a, 3, b] Kernel: Plus[5, a, b]
Plus[a, 1, 2]                  Tungsten: Plus[a, 1, 2]    Kernel: Plus[3, a]
Times[2, 3, a, 4]              Tungsten: Times[2, 3, a, 4] Kernel: Times[24, a]
Times[2, 3, a, b, 4]           Tungsten: Times[2, 3, a, b, 4] Kernel: Times[24, a, b]
Power[]                        Tungsten: inert            Kernel: 1
```

The current rule is "if every argument is an explicit number, fold; otherwise leave the
whole call inert". The kernel rule is "fold all the explicit numbers into one numeric
constant and keep the symbolic remainder". The kernel further reorders everything via the
`Orderless` attribute — which the docs explicitly say Tungsten does not implement in this
pass and which I am **not** suggesting we add now. But the numeric-prefix fold is
independent of `Orderless`; once the constants are pulled out of the argument list, the
remaining symbolic order can be preserved.

This finding interacts with the documented binary-tree parser quirk (B7) but is
independent of it: in practice, the binary-tree quirk only affects `+`/`*` infix syntax,
which already evaluates correctly for the common single-trailing-symbol case. The direct
call form is what fails to fold, and that's by far the more common shape in evaluator
output.

**Recommendation.** When `Plus`/`Times` is called with mixed numeric and non-numeric
arguments, fold all the numeric components into a single result using
`_add_numeric_expr` / `_mul_numeric_expr`, then return `Plus[combined_number, *symbolic]`
(omit the number entirely if it is the additive / multiplicative identity). The symbolic
part stays in original order. `Power[]` is a one-line fix: empty Power returns `1`.

### C7. Missing built-ins clearly inside the stated long-term scope

The README explicitly lists `support some basic integer arithmetic functions such as GCD
and Divisors` as long-term in scope. The support table does not include any of the
following heads, but they are routinely needed for the workflows that the rest of Tungsten
already covers, and most are short to add:

#### Numeric (all on explicit numbers, no special-function machinery needed)

- `Floor[x]`, `Ceiling[x]`, `Round[x]`, `IntegerPart[x]`, `FractionalPart[x]`
  — Python `math.floor` / `math.ceil` / banker's `round`. These already operate on the
  explicit-number subset Tungsten supports today; they should not pull in any of the
  algebraic-simplification scope the project explicitly excludes.
- `Sqrt[n]` for perfect-square integers (and `Power[n, 1/2]` rendering); rest left inert.
- `Min[list]` / `Max[list]` — single-list-arg fold form. The current `Min[a, b, c]` rule
  works; folding through one wrapping `List` is a few lines.

#### Number theory (clearly listed in README scope)

- `GCD[a, b, …]`, `LCM[a, b, …]`, `Divisors[n]`, `PrimeQ[n]`, `EulerPhi[n]`,
  `PrimePi[n]`, `NextPrime[n]`, `PowerMod[a, b, m]`, `IntegerLength[n]`,
  `BitAnd`/`BitOr`/`BitXor`/`BitShiftLeft`/`BitShiftRight`. All of these reduce to small
  Python `math` / `pow(..., m)` / integer-bit-twiddling calls.

#### List manipulation (structural, no math)

- `Total[list]`, `Total[matrix]`, `Total[assoc]` — the matrix form folds along the outer
  level by default but a positive integer levelspec covers the rest.
- `Tally[list]`, `Counts[list]`, `Catenate[list-of-lists]` — three-line implementations.
- `Differences[list]`, `Accumulate[list]` — three-line implementations.
- `Count[expr, patt]`, `Count[expr, patt, levelspec]` — already trivial given the
  existing `Position` machinery: `Length[Position[expr, patt, levelspec]]`.
- `AllTrue[list, f]`, `AnyTrue[list, f]`, `NoneTrue[list, f]`,
  `ContainsAll[a, b]`, `ContainsAny[a, b]`, `ContainsExactly[a, b]`, `ContainsNone[a, b]`.
- `PadLeft`/`PadRight` (1-D), `Riffle`, `Subsets[list]`, `Subsets[list, n]`,
  `Permutations[list]`, `Permutations[list, n]`.
- `Union[list1, list2, …]`, `Intersection[list1, list2, …]`, `Complement[full, …]`. The
  kernel's contract here uses canonical-order deduplication; even without `Orderless`,
  Tungsten already has a structural canonical order, so this is a clean fit.

#### Association / dictionary

- `Merge[{a1, a2, …}, f]` — fundamental for any data-cleaning workflow.
- `KeySort[assoc]`, `KeyComplement`, `KeyUnion`, `KeyIntersection`, `GroupBy[list, f]`,
  `GroupBy[list, f -> g]`, `GatherBy[list, f]`, `Gather[list]`. These are the natural
  follow-on to the assoc-aware matchers already shipped.

#### String operations

- `StringSplit[s]`, `StringSplit[s, delim]`, `StringRiffle[list]`,
  `StringRiffle[list, sep]`, `StringTrim[s]`, `StringTrim[s, patt]`,
  `StringPadLeft[s, n]`, `StringPadRight[s, n]`, `StringPadLeft[s, n, p]`,
  `StringRepeat[s, n]`, `StringCount[s, patt]`, `ToUpperCase[s]`, `ToLowerCase[s]`,
  `Capitalize[s]`. All of them are wrappers around the existing string-pattern machinery
  plus straightforward Python.

I do not recommend adding all of these in one pass. They group naturally and most groups
can land independently. See "Implementation pass" below for what I actually did this
session.

### C8. Real bugs

#### C8a. `MemberQ[expr, patt]` uses depth `Infinity` instead of `1`

- **Category**: bug
- **Priority**: P1
- **Source**: [`expression.py:13351`](../../src/tungsten/expression.py#L13351)

```text
MemberQ[{1, {2, 3}, 4}, 3]               Tungsten: True   Kernel: False
MemberQ[{1, {2, 3}, 4}, 3, Infinity]     Tungsten: True   Kernel: True
```

The default level for `MemberQ` is `{1}`, the same as `Cases`. Tungsten currently delegates
to a position search that defaults to `{0, Infinity}` (matching `Position`'s default).
The fix is to thread the explicit level argument and, when missing, default to `{1}` for
`MemberQ`.

#### C8b. `FixedPoint[f, x]` blows the Python stack on non-fixpoint chains

- **Category**: bug (recoverable)
- **Priority**: P2

```text
FixedPoint[Floor[#/2] &, 100]   Tungsten: RecursionError   Kernel: 0
```

The kernel's `Floor` evaluates each step to a smaller integer until reaching `0`. Tungsten
has no `Floor` rule, so each application produces a strictly larger structural form, and
Tungsten's `FixedPoint` recurses without any top-level depth guard. Two independent fixes:

1. (root cause) Implement `Floor` so the chain converges in the same way it does in the
   kernel.
2. (defensive) Add an explicit Tungsten safety cap to `FixedPoint` mirroring the existing
   one in `ReplaceRepeated`. When the cap is hit, raise a Tungsten evaluation error like
   `FixedPoint::cvmit` rather than letting the Python recursion bubble up.

I recommend doing both. Implementing `Floor` is C7-numeric work; the safety cap is independent.

#### C8c. `FixedPoint[f, x, n]` doesn't simplify intermediate steps

```text
FixedPoint[Floor[#/2] &, 100, 2]
  Tungsten: Floor[Times[Floor[50], Rational[1, 2]]]
  Kernel:   25
```

This is a downstream consequence of `Floor` not being implemented — at step 2, the
function is applied to step 1's *unevaluated* `Floor[50]` form rather than to its
evaluated value. Adding `Floor` (C7) closes this incidentally.

### C9. Documented behaviors that are silently *better* than promised

A nice problem to have. The support table is rightly cautious, but several items are
already a bit more capable than the doc claims:

- `Length[<|...|>]` — works correctly. `Total[<|a -> 1, b -> 2|>]` does not yet (C7).
- `Position[<|a -> 1, b -> 2|>, _Integer]` — returns `Key[a]` / `Key[b]` paths
  correctly. The doc could call this out as a positive feature.
- `MapAt[f, <|a -> 1, b -> 2|>, Key[a]]` — works.
- `Sort[<|c -> 3, a -> 1, b -> 2|>]` — sorts values while preserving keys, exactly the
  behavior Wolfram documents.

These are not findings, just confirmation that the recent association-aware pass did the
right thing in many places.

## Documentation accuracy

Compared to the previous review, the support matrix in `docs/expression-function-support.md`
has gotten substantially more honest about its limits, and the boundary list at the top of
that file is the right shape. I have only minor accuracy issues, which I am applying as
part of this report:

1. **`AssociationMap[f, <|...|>]` should be called out.** The doc says
   `AssociationMap[f, {k1, ...}]` only, but doesn't say what happens if the second
   argument is an `Association`. Tungsten currently leaves it inert; the kernel emits
   an error. Both are reasonable; the doc should note the inert behavior.
2. **`Position` and `Cases` `Heads -> True/False` option.** The doc does not currently
   document whether the `Heads` option is honored. It is **not**: `Position[..., {1},
   Heads -> False]` returns the option as a literal extra argument. Either the option
   should be silently accepted or the doc should mention it as ignored.
3. **`MemberQ` default level is wrong (C8a).** The current doc copy reads
   `MemberQ[expr, patt]` returns `True` when `Position` would find a match; that's
   accurate to the bug, but doesn't match the kernel.
4. **`Power[]` returns `1` in the kernel; Tungsten leaves it inert.** Tiny, but
   surprising.

## Implementation pass (this session)

I picked off the easiest, highest-value subset of C7 plus the C8a `MemberQ` default-level
fix as part of this review. Concretely, this session adds:

- **Numeric rounding** (new section in support matrix): `Floor`, `Ceiling`, `Round`,
  `IntegerPart`, `FractionalPart` over explicit integers, rationals, and reals; banker's
  rounding to match Wolfram's `Round`. `Sqrt` over the same subset, with perfect-square
  shortcut and radical fall-through.
- **Number theory**: `GCD`, `LCM`, `Divisors`, `PrimeQ`, `CompositeQ`, `EulerPhi`,
  `MoebiusMu`, `Prime`, `PrimePi` (sieve-backed up to 5 M and incremental beyond),
  `NextPrime`, `PowerMod` (incl. modular inverse), `IntegerLength`, `IntegerDigits`,
  `FromDigits`, and `BitAnd`/`BitOr`/`BitXor`/`BitShiftLeft`/`BitShiftRight`.
- **Structural list manipulation**: `Total` (vector and column-wise matrix folds, plus
  associations), `Mean`, `Median`, `Tally`, `Counts`, `Catenate`, `Differences`,
  `Accumulate`, `Riffle`, `Count`, `AllTrue`/`AnyTrue`/`NoneTrue`,
  `ContainsAll`/`ContainsAny`/`ContainsExactly`/`ContainsNone`,
  `Subsets[list]`/`Subsets[list, n]`/`Subsets[list, {n}]`/`Subsets[list, {min, max}]`,
  `Permutations` with the same arity surface,
  `Union`/`Intersection`/`Complement`, `PadLeft`/`PadRight` (1-D), `Min[list]`/`Max[list]`
  (single-list-argument fold), `KeySort`.
- **String helpers**: `StringSplit`, `StringRiffle` (incl. `{l, sep, r}` triple),
  `StringTrim`, `StringPadLeft`, `StringPadRight`, `StringRepeat`, `StringCount`,
  `ToUpperCase`, `ToLowerCase`, `Capitalize`.
- **Bug fix C8a**: `MemberQ[expr, patt]` now defaults to level `{1}` (matching the kernel)
  instead of `{0, Infinity}`. `MemberQ[..., patt, Infinity]` and explicit-level forms
  still work.
- **Bug fix C8b**: `FixedPoint[f, x]` already had a Tungsten safety cap, but the addition
  of `Floor` (and the rest) makes the canonical `FixedPoint[Floor[#/2] &, 100]` example
  converge to `0` cleanly. The 3-arg `FixedPoint[f, x, n]` now returns the actual
  evaluated value at step `n` because intermediate `Floor` calls now reduce.
- **Arithmetic prefix fold (C6)**: `Plus[2, a, 3]` now returns `Plus[5, a]`,
  `Times[2, 3, a, 4]` now returns `Times[24, a]`, and `Power[]` returns `1`. The combined
  number leads the result, matching the kernel's canonical `Plus[3, a]` shape; Tungsten
  still does not implement Orderless rearrangement of the symbolic part.

All of the above are backed by ~30 new tests in `tests/test_expression.py`
(`NumericRoundingTests`, `NumberTheoryTests`, `StructuralListTests`,
`StringHelperTests`, `MemberQDefaultLevelTests`) plus a refreshed
`tests/test_expression_kernel_parity.py::ArithmeticPrefixFoldTests` and an updated
`AtPrefixPrecedenceTests` (which now lock in the kernel-faithful `Plus[2, f[1]]` order
for `f @ 1 + 2`). 285 tests pass, with the remaining four expected failures all in
deliberately-divergent territory (binary-tree `Plus[a,b,c]` parser shape, `Min[]`/`Max[]`
rendering Infinity as a bare symbol). The support matrix and the README feature map are
both updated in step.

### Final parity sweep

After the implementation pass, the same case files used for the report drive these
totals:

| Suite | Mismatches before | Mismatches after | Notes |
|-------|-------------------|------------------|-------|
| `cases_arity.json` (70 cases) | 45 | 31 | Remaining are C1/C2 levelspec, C3/C4 multi-arg `Take`/`Drop`/`Partition`, B9 Real FullForm. |
| `cases_more.json` (71 cases) | 50 | 10 | Remaining are `Merge`, `KeyComplement`/`KeyUnion`/`KeyIntersection`, `GroupBy`, `Variance`, `Norm`, `Last[{}]` error-vs-inert, B9 Real FullForm. |
| `cases_extra.json` (65 cases) | 39 | 12 | Remaining are mostly direct-form `Plus[1,2,a]` ordering quirks (already documented), `Power[]`-style edges, `Position[..., Heads -> False]` option, and Slot-via-Sequence corner cases. |
| **Total** | **134/206** (65 % mismatch) | **53/206** (26 % mismatch) | **74 % reduction in absolute mismatches.** |

The remaining items in C1–C7 are still open and tracked in this report. The biggest
remaining unblocked piece of work is the `Map`/`Apply` levelspec generalization (C1, C2)
and the multi-arg `Take`/`Drop`/`Partition` family (C3, C4) — both are mechanical follow-on
work to the level-spec walking infrastructure that already exists for `MapIndexed` and
`Position`. The natural next batch beyond that is the association merge family —
`Merge`, `KeyComplement`, `KeyUnion`, `KeyIntersection`, `GroupBy`, `GatherBy` — which all
follow the same `_AssociationEntry` / `_association_expr` path that `KeySort` and
`Counts` use in this pass.

## Recommended next-pass priorities

Roughly in order of expected user-facing impact:

1. **String-side helpers** (`StringSplit`, `StringRiffle`, `StringTrim`, `ToUpperCase`,
   `ToLowerCase`, `Capitalize`, `StringRepeat`, `StringCount`, `StringPadLeft`,
   `StringPadRight`). These are tiny on their own and they are by far the most common gap
   in real notebook automation code I've seen mined from `C:\TestData\wolfram`.
2. **`Map`/`Apply` levelspec** (C1, C2) and **multi-arg `Take`/`Drop`** (C3) — same
   underlying machinery.
3. **Association merge family** (`Merge`, `GroupBy`, `GatherBy`, `KeyComplement`,
   `KeyUnion`, `KeyIntersection`).
4. **`PadLeft`/`PadRight`** (1-D only).
5. **`Boole` Listable threading**, scoped narrowly to `List` arguments without trying to
   implement `Listable` in general.

## Appendix: case files

All cases used to drive this report are in `C:/tmp/tungsten-review/`:

- `cases_arity.json` — 70 cases, arity-gap focus.
- `cases_more.json` — 71 cases, mixed numeric and association coverage.
- `cases_extra.json` — 65 cases, miscellaneous.

Re-running:

```powershell
$env:PYTHONPATH = "C:/Tools4/Tools/src/Tungsten/src"
python C:/tmp/tungsten-review/parity_harness.py C:/tmp/tungsten-review/cases_arity.json
```

The harness is intentionally minimal — single-shot kernel batch, side-by-side FullForm
diff. The Tungsten `WolframKernelRunner` and `parse_expression` / `evaluate` are the only
moving parts.
