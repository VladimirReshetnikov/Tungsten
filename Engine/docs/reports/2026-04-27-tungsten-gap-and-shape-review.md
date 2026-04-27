# Tungsten Gap and Argument-Shape Review

- Status: Research-and-plan (current-state code review of `src/Tungsten`, kernel-side and kernel-free)
- Audience: Vladimir, Tungsten maintainers planning the next implementation passes
- Scope: `src/Tungsten/src/tungsten/` Python package (kernel-free expression subsystem) and the Wolfram kernel interop layer
- Created (UTC): 2026-04-27T16:48:25Z
- Repository HEAD: 175b26b178ab2da565608973d317a455292141e7
- Predecessors (now archived): `2026-04-23-external-review.md`, `2026-04-24-parser-evaluator-kernel-parity.md`, `2026-04-24-parser-evaluator-kernel-parity-evil-qa.md`, `2026-04-26-expression-parity-deep-review.md`, `2026-04-26-function-surface-gap-report.md`. Each archived header carries a notice; this document is the active gap inventory.

## Purpose and method

This report inventories what is still missing in Tungsten's Wolfram-language surface as of HEAD, broken down by family. For each family it lists:

1. **Missing family members** — siblings of already-implemented heads that the kernel ships and that Tungsten leaves inert.
2. **Missing argument shapes** — heads where Tungsten *does* dispatch, but only some of the documented Wolfram signatures resolve.
3. **Missing options** — option keys that Tungsten silently ignores or rejects.

Method: I (a) walked every dispatch chain in `expression_evaluator.py`, `expression_arithmetic.py`, `expression_iteration.py`, `expression_polynomial.py`, `expression_algebraic.py`, `expression_definitions.py`, `expression_scoping.py`, and `expression_patterns.py`; (b) reconciled that with `docs/expression-function-support.md`; (c) executed each previously-reported gap item in-process against `evaluate(parse_expression(...))`; and (d) ran a batched kernel parity probe over the same inputs to nail down disagreements.

Items already-implemented since the prior reports, plus a small set of doc-vs-implementation drift items, are listed under "Closed since the prior reports" and "Documentation drift" so we do not relitigate them.

The README scope statement is honored throughout: this report does not push for closed-form `Solve` / `Reduce`, calculus heads (`D`, `Integrate`, `Series`, `Limit`), broad simplification, dense linear algebra, optimization, or special mathematical functions. Where they appear in tables they are flagged as **out-of-scope** so the long-tail picture stays visible without re-scoping.

## Closed since the prior reports

Re-tested and confirmed working at HEAD; do not re-list:

- **Bucket B from the 2026-04-26 function-surface report (number theory)** — fully landed.
- **Bucket D (lists, arrays, tensors, structural)** — landed: `MinMax`, `RankedMin`, `RankedMax`, `Mode`, `Quantile` (with custom parameters), `Quartiles`, `BinCounts`, `BinLists`, `Permute`, `PermutationCycles`, `PermutationList`, `PermutationOrder`, `Cycles`, `RandomPermutation`, `SequenceCases` / `SequencePosition` / `SequenceCount` (fixed-arity patterns), `Subsequences`, `Subsets[list, {min, max, step}]`, `Permutations[list, {min, max, step}]`, `Tuples[items, {n1, n2, …}]`, `Riffle[list, x, {a, b, s}]`.
- **Bucket F (sorting, ordering, set ops)** — landed: `Sort[list, p, n]`, `SortBy[expr, f, p]`, `Union` / `Intersection` / `Complement` `SameTest`, `Counts[list, test]`, `Tally[list, test]`, `DeleteDuplicates[list, test]`, `DeleteDuplicatesBy[expr, f, test]`, `OrderingBy` n / p variants, the `MinimalBy` / `MaximalBy` family.
- `Take[m, spec1, spec2, …]`, `Drop[m, spec1, spec2, …]` matrix-style multi-spec slicing including `None`.
- `Partition` 4- and 5-argument padded forms.
- `Reverse[expr, levelspec]` (single level and `{m, n}` ranges).
- `Range[{n1, n2, …}]` iterator-list form, `Array[f, n, origin]`, `Array[f, n, {b1, b2, …}]`.
- `DiagonalMatrix[list, k]` and `DiagonalMatrix[list, k, n]` square cases.
- `Fold[f, expr]`, `FoldList[f, expr]` (no-init forms).
- `MapThread[f, lists, n]` at any depth (including `n = 0`).
- `NestWhile[..., m]` history size, the `m == All` case, and the soft `max` cap.
- `Merge`, `GroupBy` (default and arrow forms), `GatherBy`, `Gather`, `KeyComplement`, `KeyUnion`, `KeyIntersection`, `KeySort`, `KeySelect`.
- `Variance`, `StandardDeviation`, `Norm` (Euclidean, p-norm, `Infinity`).
- `PrimePowerQ`, `ChineseRemainder`.
- `OneIdentity` for `Plus[x]` and `Times[x]`.
- Registry-backed `Listable` threading (e.g. `Plus[{1,2},{3,4}]`, `Sin[{0, Pi}]`, `Abs[{-1, 2}]`).
- Numeric prefix folding for mixed `Plus` / `Times` / `Power`, including `Plus[a, 2, 3, b]` -> `Plus[5, a, b]`.
- Hold-family semantics (`Hold`, `HoldComplete`, `HoldForm`, `HoldPattern`, `Unevaluated`, `ReleaseHold`).
- `Sequence[...]` splicing (with the documented `HoldComplete`/`Unevaluated`/`Rule`/`RuleDelayed` exceptions).
- `Position` default level `{0, Infinity}` and the `Heads -> True/False` option.
- Span parsing for `a ;; b ;; c` (n-ary); n-ary chained comparisons (`a < b < c`, mixed via `Inequality`).
- `@` precedence fix (binds tighter than `+` / `*`).
- Algebraic-coefficient `Root` canonicalization, `MinimalPolynomial`, `RootReduce`.
- The 2026-04-23 external review's bug-grade items (F-1 through F-5) — addressed; the report is informational at this point.

## Documentation drift caught while testing

These should be folded into `docs/expression-function-support.md` rather than treated as work items:

1. `MapIndexed[f, expr, levelspec]` works for arbitrary levelspecs (integer `n`, `{n}`, negative integers, `Infinity`). The matrix says "only the default level `1` is implemented." Update the matrix.
2. `Tally[list, test]` is in the matrix. `Counts[list, test]` is also implemented; the matrix already lists it as a Tungsten extension, but the description does not call out the binary-test argument explicitly enough — the rule the implementation actually uses is "treat two elements as equal when `test[a, b]` evaluates to explicit `True` for any earlier representative". Worth a sentence.
3. `Cases[..., Heads -> True/False]` is honored (verified against kernel for `{0, Infinity}` and explicit `Heads`). The matrix bullet says "`Cases` and other pattern-search heads do not yet honor this option." That's stale — `Cases` *and* `Count` honor it; only `DeleteCases`, `MemberQ`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `Scan` do not.
4. `Through[expr]` and `Through[expr, head]` both work. Matrix says "single-argument direct form" only.
5. The matrix bullet about `Sum[expr, {n}]` rejecting the bare-integer iter spec is still correct; do not touch.

## Buckets

The bucket letters intentionally mirror the 2026-04-26 function-surface gap report's so a reader can correlate items across the two documents.

### A. Atoms, arithmetic, transcendentals

**Symbolic constants.** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree` are accepted as inert symbols and `N[Pi, p]` / `N[E, p]` / `N[EulerGamma, p]` work via the SymPy bridge. They have no associated `Re` / `Im` / `Sign` / `Abs` rules and no participation in arithmetic identities (e.g. `2 Pi - Pi` does not simplify to `Pi`). All of `Re[Pi]`, `Im[I*Pi]`, and `Re[I*Pi]` stay inert. **Add per-constant rules for the deterministic-real cases**: `Re[const] -> const`, `Im[const] -> 0` for the real-valued constants; `Sign[Pi] -> 1`, `Abs[Pi] -> Pi`, etc. The same hooks unblock most of the items below once their value heads are in place.

**Transcendental and elementary functions.** None of these have evaluator rules today; the values come back inert. Adding even a small subset of exact rules over the explicit-numeric / `Pi` / `E` / `I` subset would dramatically expand what "ordinary" Wolfram code Tungsten can run.

| Family | Heads |
|--------|-------|
| Logarithms | `Log[x]`, `Log[b, x]`, `Log2[x]`, `Log10[x]` |
| Exponential | `Exp[x]` |
| Trig | `Sin`, `Cos`, `Tan`, `Sec`, `Csc`, `Cot` |
| Inverse trig | `ArcSin`, `ArcCos`, `ArcTan` (1-arg and 2-arg `ArcTan[x, y]`), `ArcSec`, `ArcCsc`, `ArcCot` |
| Hyperbolic | `Sinh`, `Cosh`, `Tanh`, `Sech`, `Csch`, `Coth` |
| Inverse hyperbolic | `ArcSinh`, `ArcCosh`, `ArcTanh`, `ArcSech`, `ArcCsch`, `ArcCoth` |

The README explicitly excludes "real- or complex-valued elementary or special mathematical functions" and "expression simplification." That should be re-confirmed against the latest direction. If staying out-of-scope, keep the heads inert and add explicit `N` bridges for them (numeric pass through SymPy already exists, e.g. `N[Sin[Pi/6]] -> 0.5`). If moving in-scope even narrowly, the smallest defensible subset is exact rules for explicit-numeric and `Pi`/`E`/`I` arguments — `Sin[Pi/6] -> 1/2`, `Log[E] -> 1`, `Exp[0] -> 1`, `ArcTan[1] -> Pi/4`, `Tan[Pi/4] -> 1`, etc. — plus pass-through inert for everything else.

**Special functions over integers.** Below each is the one-line rule the kernel uses, which is small enough to thin-wrap once arithmetic is in place.

- `Gamma[n]` for non-negative integers (= `(n-1)!`), `LogGamma[n]`.
- `Factorial[n]`, `Factorial2[n]` — `Factorial[5]` and `Factorial2[7]` are still inert. **Add.** This is in Bucket 6 of the prior report's "merged structural work buckets."
- `Pochhammer[a, n]` for explicit integers / rationals.
- `Beta[a, b]`, `Subfactorial[n]`, `StirlingS1[n, k]`, `StirlingS2[n, k]`, `BellB[n]`, `CatalanNumber[n]`.

**Complex-number helpers.** `Arg[z]`, `AbsArg[z]`, `ComplexExpand[expr]`. All inert today. Tungsten already has `Re`, `Im`, `Conjugate`, `Abs`, so a small `Arg` for explicit real and pure-imaginary `z` plus a structural `ComplexExpand` over the `(a + I b)^n` template is feasible without crossing into broad simplification.

**Rational structure.** `Numerator[expr]`, `Denominator[expr]`. Glaring hole — Tungsten has full exact `Rational`, but `Numerator[3/4]` and `Denominator[3/4]` are inert. Confirmed against the kernel: `Numerator[3/4] -> 3`, `Denominator[3/4] -> 4`. **Add.** Once the head dispatches, threading over rational expressions through SymPy is a five-line wrapper.

**Numeric helpers.** `Rationalize[x]`, `Rationalize[x, dx]`, `RealDigits[x]`, `MantissaExponent[x]`, `Hash[expr]`, `Hash[expr, "MD5"|"SHA"|...]`, `Hash[expr, type, "Format"]`. None implemented.

**Random number generation.** `RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`, `SeedRandom`, `BlockRandom`. None implemented (`RandomSample` is). `RandomInteger[]`, `RandomReal[]`, `RandomChoice[{...}]` all stay inert. High-impact gap for any data-shaping or scripting workload — **prioritize**.

**Argument shapes already supported, but worth verifying once.**

- `Min[expr]` / `Max[expr]` listable threading — single-list-arg fold is in; cross-list listable is in via the registry; cover with one regression test.
- `Mod[m, n]` for non-integer `m` — supported per matrix; a regression test against rationals/reals would be useful.
- `Power[base, p/q]` for exact non-perfect-powers — partial via the existing perfect-factor extraction.

### B. Number theory (residual)

Most of this bucket is closed. Remaining:

- `Divisible[n, m]`. **Trivial.** Confirmed inert; kernel = `Mod[n, m] == 0`.
- `CoprimeQ[a, b, …]`. Trivial; kernel = `GCD[args] == 1`.
- `NumberDigit[n, k]`, `NumberDigit[n, k, base]`. Trivial — current `IntegerDigits` already does the underlying work.
- `Factorial[n]`, `Factorial2[n]`. Trivial wrappers (`math.factorial`).
- `Pochhammer[a, n]` (also bucket A).
- `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`, `Subfactorial` (also bucket A).

These nine plug into the existing `expression_arithmetic.py` `_evaluate_integer_special_functions` chain and look like ~60–120 LOC.

### C. Polynomial algebra and rational simplification

The SymPy bridge already underpins `Expand`, `Factor`, `Collect`, `Coefficient`, `MonomialList`, `CoefficientList`, `Decompose`, `PolynomialQ`, `Variables`, and `Exponent`. The natural follow-on layer is missing entirely:

- `Numerator`, `Denominator` (also bucket A; these unblock everything below).
- `Together[expr]`, `Apart[expr]`, `Apart[expr, x]`, `Cancel[expr]`. All thin SymPy wrappers; confirmed inert against kernel (`Cancel[(x^2-1)/(x-1)] -> 1 + x`).
- `PolynomialGCD`, `PolynomialLCM`, `PolynomialMod[poly, m]`, `PolynomialQuotient[a, b, x]`, `PolynomialRemainder[a, b, x]`, `PolynomialReduce[poly, polys, vars]`. All thin SymPy wrappers.
- `Resultant[p, q, x]`, `Discriminant[p, x]`, `Subresultants`. SymPy bridge for the first two; `Subresultants` is more involved.
- `GroebnerBasis[polys, vars]`. SymPy has it; the bridge is mostly type-marshalling.

**Out of scope per current README direction:** `Simplify`, `FullSimplify`, `Roots`, `Solve`, `Reduce`, `NSolve`, `FindRoot`, `RootSum`, `ToRadicals`, `D`, `Derivative`, `Integrate`, `Series`, `Limit`, closed-form `Sum`/`Product`. Listed only so the long-tail picture is visible.

**Missing argument shapes.**

- `Expand[expr, patt]` — pattern-restricted expansion. Inert.
- `Factor[poly, Modulus -> p]` — over `Z/pZ`. Inert; matrix says explicitly unsupported.
- `Factor[poly, Extension -> {Sqrt[2], …}]` — non-`I` algebraic extensions. Inert.
- `MonomialList[poly, monomialOrder]` — only lex order today.
- `Collect[expr, var, f]` — coefficient-transforming third argument is unsupported.
- `Coefficient[expr, vars, {n1, n2, …}]` — multi-exponent form against several variables at once.

**Missing options.** `Modulus`, `Trig`, `Cubics`, `Quartics`, `GaussianIntegers` for `Factor` / `FactorList` (only `True`/`False` for Gaussian today). `Trig`, `Modulus` for `Expand` / `ExpandAll`. `PolynomialQ[expr, Modulus -> p]`.

### D. Lists, arrays, tensors, structural (residual)

This bucket is mostly closed. Remaining items, all confirmed inert against the kernel:

**Missing family members.**

- `VectorQ[expr]`, `VectorQ[expr, test]` — kernel = `True`.
- `MatrixQ[expr]`, `MatrixQ[expr, test]` — kernel = `True`.
- `FirstPosition[expr, patt]`, `FirstPosition[expr, patt, default]`, `FirstPosition[expr, patt, default, levelspec]` — kernel = `{2}` for `FirstPosition[{1,2,3}, 2]`.
- `PositionLargest[list]`, `PositionSmallest[list]` — useful adjuncts to `Ordering`.
- `PositionIndex[list]` — kernel returns an association of value -> index list.
- `CountDistinct[list]` — kernel = `Length[Union[list]]`.
- `CountsBy[list, f]` — kernel = `Counts[Map[f, list]]`.
- `ContainsOnly[a, b]`, `ContainsOnly[a, b, SameTest -> f]`.
- `Subdivide[n]`, `Subdivide[n, k]`, `Subdivide[xmin, xmax, k]`.
- `Splice[{a, b, c}]`, `f[Splice[{a, b}], c]` — variadic argument splicer (similar in spirit to `Sequence`, but it splices structurally and sticks around in held forms).
- `UpTo[n]` — already partly supported as a `Take` / `Drop` selector via the `UpTo[n]` parser form (matrix lists this); ensure it also threads through `StringTake` / `StringDrop` and search-with-count selectors uniformly.
- `Ratios[list]` — adjacent-pair ratios.
- `SubsetMap[f, list, positions]` — apply `f` to a listed-positions subset.
- `ArrayFilter[f, list, n]`, `ArrayReduce[f, list, dims]` — out-of-scope per matrix; `ArrayReduce` is small enough to wrap as a structural fold even without the dense-array assumption.
- `Groupings[list, k]`, `SequenceReplace`, `SequenceSplit` — out-of-scope per matrix.
- `Numerator` / `Denominator` listable threading once the heads exist (also bucket A).

**Missing argument shapes.**

- `MapApply[f, expr, levelspec]` — only 2-arg form. Mechanical extension on top of the `Map` levelspec walker that already exists.
- `Operate[g, expr, 0]` — kernel returns `g[expr]`; Tungsten leaves it inert. **Real bug**, isolated. The same dispatch already handles default and `n=1`. One-line fix.
- `Through[expr, head]` returning the unchanged input when `head` doesn't match — current behavior matches kernel, but documentation calls it "supported" without spelling out the no-match case.
- `Distribute[expr, g, f, gp, fp]` 5-arg form — inert today (matrix confirms).
- `Tr[m, f, n]` 3-arg trace — supported per matrix; verify against the kernel for n>1.
- `Inner[f, l, r, g, h]` 5-arg generalization — inert.
- `Flatten[expr, n, h]` 3-arg form — inert.
- `Total[expr, levelspec]` — supported per matrix; tests confirm.
- `Length[expr, levelspec]` / `Depth[expr, levelspec]` — n/a in kernel; ignore.
- `Take[assoc, {Key[k], …}]` — only numeric / span specs work on associations today. Verified: `Take[<|a->1, b->2, c->3|>, {Key[a], Key[b]}]` returns the input unchanged instead of `<|a->1, b->2|>`.
- `Range[start, stop, step]` for non-integer step — works numerically; one regression test.
- `Tuples[items, {n1, n2, …}]` per-position widths — supported per matrix.
- `Permutations[list, {min, max, step}]` — supported per matrix.
- `Differences[list, {n1, n2}]` multivariate — inert (matrix confirms partial support).
- `Outer[f, list1, list2, …, n]` levelspec form — inert.
- `Operate[p, expr, 0]` — see above.
- `Position[expr, patt, levelspec, n, "Index"]` — second-property form not implemented.

**Missing options.** `Heads -> True/False` is honored on `Position`, `Cases`, `Count` (confirmed); it is **not** honored on `DeleteCases`, `MemberQ`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `Scan`. The matrix is stale on this. Also: `SortBy[..., ordering]` third-argument ordering function — verify whether the implementation actually respects it (matrix says yes; one regression test will confirm).

### E. Linear algebra (out-of-scope per README, residual notes)

The README excludes broad linear algebra. Listed for completeness:

- `LinearSolve`, `RowReduce`, `MatrixRank`, `NullSpace`.
- `Eigenvalues`, `Eigenvectors`, `Eigensystem`, `CharacteristicPolynomial`.
- `SingularValueDecomposition`, `LUDecomposition`, `QRDecomposition`, `CholeskyDecomposition`, `SchurDecomposition`, `JordanDecomposition`.
- `LeastSquares`, `PseudoInverse`, `Orthogonalize`, `Projection`.
- `KroneckerProduct`, `TensorProduct`, `TensorContract`, `TensorTranspose`.
- `MatrixExp`, `MatrixLog`, `MatrixFunction`.
- `Norm[m, p]` for matrix `p` — only vector p-norms work.
- `Chop[expr, dx]`.
- `IdentityMatrix[{n, m}]` non-square form — inert (verified).
- `DiagonalMatrix[list, k, {n, m}]` non-square form — inert (verified).
- `MatrixPower[m, n, v]` — vector-applied power; inert.

### F. Sorting, ordering, set ops (residual)

Mostly closed. Remaining shape items:

- `Sort[list, p, n]` — supported per matrix as a Tungsten extension. Verify.
- `OrderingBy[list, f, n, p]` — supported.
- `Union[list1, …, SameTest -> test]`, `Intersection`, `Complement` — verified working (`Union[{1,2,3,4}, {1,2}, SameTest -> Equal]`).
- `Tally[list, test]`, `Counts[list, test]`, `DeleteDuplicates[list, test]`, `DeleteDuplicatesBy[expr, f, test]` — verified working.
- `BinarySearch` — not in kernel; ignore.

### G. Statistics and random (residual)

The random family is the biggest blocker for scripting workloads.

**Random.** None implemented except `RandomSample` and `RandomPermutation`:

- `RandomInteger[]`, `RandomInteger[max]`, `RandomInteger[{min, max}]`, `RandomInteger[range, dims]`.
- `RandomReal[]`, `RandomReal[max]`, `RandomReal[{min, max}]`, `RandomReal[range, dims, p]`.
- `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`.
- `SeedRandom[seed]`, `SeedRandom[]`.
- `BlockRandom[expr]` — scoped seed.

**Statistics.**

- `Skewness[list]`, `Kurtosis[list]`, `RootMeanSquare[list]`.
- `Correlation[a, b]`, `Covariance[a, b]`, `CovarianceMatrix[m]`.
- `Mean[list, w]` / `Median[list, w]` weighted variants.
- `WeightedData[list, weights]` — out of scope likely.
- Distribution-parametric forms (`Mean[NormalDistribution[…]]`) — out of scope.

### H. Iteration, loops, functional iteration

- `Until[test, body]` — inert today.
- `NestWhileList[..., m, max]` — current matrix says "direct three-argument form only"; verify whether the four- and five-argument forms now thread through (the `NestWhile` cousin already supports both).
- `FixedPoint`, `FixedPointList` `SameTest -> f` option — not honored. Verified inert.
- Closed-form `Sum`/`Product` over symbolic `n` — out-of-scope per current direction; explicit-bound `Sum` and `Product` work.

### I. Strings, text, regex

This is one of the densest remaining buckets. None of the heads below are implemented:

**Missing family members.**

- `StringDelete[s, patt]`, `StringDelete[s, {patt1, …}]`, `StringDelete[s, patt, n]`.
- `StringExtract[s, n]`, `StringExtract[s, {n1, …}]`, `StringExtract[s, n, sep]`.
- `StringPart[s, n]`, `StringPart[s, {n1, …}]`.
- `StringPartition[s, n]`, `StringPartition[s, n, d]`.
- `StringRotateLeft[s, n]`, `StringRotateRight[s, n]`.
- `StringReplaceList[s, rules]`, `StringReplaceList[s, rules, n]`.
- `StringReplacePart[s, ins, span]`, `StringReplacePart[s, {ins1, …}, {span1, …}]`.
- `StringTakeDrop[s, n]` — kernel returns `{StringTake[...], StringDrop[...]}`.
- `StringTemplate[template]`, `TemplateApply[template, args]`, `StringForm[template, args]` (last is display-only).
- `EditDistance[s, t]`, `DamerauLevenshteinDistance`, `HammingDistance`, `LongestCommonSubsequence` / `LongestCommonSubsequenceList`, `LongestCommonSubstring`, `LongestOrderedSequence`.
- `WordCount[s]`, `TextWords[s]`, `TextSentences[s]`, `TextLines[s]`, `LetterCounts[s]`, `CharacterCounts[s]`.
- `ToTitleCase[s]`.
- `Anagrams[s]`, `LetterNumber["a"]`, `FromLetterNumber[n]`.
- `Hash[expr]`, `Hash[expr, type]`, `Hash[expr, type, "Format"]` (also bucket A).

**Missing argument shapes on already-implemented heads.**

- `StringSplit[s, patt]` and `StringSplit[s, {patt1, …}]` — pattern separators (`DigitCharacter`, `_?DigitQ`, `RegularExpression["..."]`) leave the call inert; only literal-string separators evaluate.
- `StringTrim[s, patt]` — only literal-string trim works (`StringTrim["a1b2", DigitCharacter]` is inert).
- `StringCount[s, patt]` — only literal-string patterns supported.
- `StringSplit[s, patt, n]` — bounded-count form.
- `Capitalize[s, "AllWords"]` — kernel's word-list / dictionary modes.

**Missing options.** Across every string head that already accepts patterns (`StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, `StringReplace`, `StringSplit`, `StringCount`):

- `IgnoreCase -> True/False`.
- `Overlaps -> True/False/All`.
- `MetaCharacters -> ...`.
- `SpellingCorrection -> True/False` for the introspection family (`Names[..., SpellingCorrection -> True]`, `Names[..., IgnoreCase -> True]`).

### J. Pattern matching and replacement

**Missing family members.**

- `ReplaceList[expr, rules]`, `ReplaceList[expr, rules, n]` — enumerate every distinct match. Inert; valuable for combinatorial pattern enumeration.
- `Default[h]`, `Default[h, n]` — registry for `Optional[patt]` / `_.` defaults. Without this, `f[x_, y_.] := …` cannot synthesize defaults for user-defined heads with omitted arguments.
- `OptionValue[opts, key]`, `OptionValue[f, opts, key]`, `OptionValue[f, opts, key, default]` — none implemented (verified inert). The matrix says `OptionsPattern` is structural-only and explicitly notes the gap.
- `Options[f]`, `SetOptions[f, opts]`, `Options[f] = {opts}`, `FilterRules[opts, spec]`. None implemented.
- `Information[sym]`, `Definition[sym]`, `?sym`, `??sym` parser forms — inert.
- `MessageName[sym, "tag"]` parses but does not look up message-template values.

**Missing argument shapes.**

- `MatchQ[patt][expr]` operator form — inert.
- `Replace[rules][expr]`, `Cases[patt][expr]`, `DeleteCases[patt][expr]`, `Position[patt][expr]`, `Map[f][expr]` operator forms — inert. (Tungsten supports `Select[crit][expr]`, `SelectFirst[crit][expr]`, `Discard[crit][expr]`, `Scan[f][expr]`, `MapApply[f][expr]`, `MapAll[f][expr]`, `MapIndexed[f][expr]`, `KeySelect[crit][expr]`, `SortBy[f][expr]`, `ReverseSortBy[f][expr]`, `OrderingBy[f][expr]`, `MinimalBy[f][expr]`, `MaximalBy[f][expr]`, `Comap[fs][expr]`, `ComapApply[fs][expr]`. The asymmetry is worth either closing or documenting.)
- `Replace[expr, rules, levelspec, Heads -> True/False]` — `Heads` option not honored (also bucket D).
- `_DigitCharacter` and other qualified-blank shorthands — not in matrix; out of scope.

**Missing options.**

- `Heads -> True/False` on `DeleteCases`, `MemberQ`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `Scan` (already noted in bucket D; the cross-cutting fix is one shared option-parsing path).
- `OptionsPattern[f]` validating against `Options[f]` (depends on bucket J's options system landing).

### K. Associations (residual)

**Missing family members.**

- `JoinAcross[a1, a2, key]` relational-style join.
- `AssociationFromMatrix`, `AssociationToMatrix` — inert.
- `AssociationMap[f, <|...|>]` direct-association form — inert; matrix explicitly limits to the key-list form.
- `KeyDropFrom[sym, key]`, `AssociateTo[sym, rule]` — both inert; companions to the missing `PrependTo`/`AddTo` family in bucket M.
- `KeyFreeQ[assoc, key]`, `KeySortBy[assoc, f]` — inert.
- `CountsBy[list, f]` (also bucket D).

**Missing argument shapes.**

- `Lookup[assoc, key, default, missingFn]` 4-arg form — inert (verified; kernel returns `default` when key absent and applies `missingFn` to a `Missing[...]` only on a missing failure path).
- `KeyMap[f][assoc]` operator form — inert.
- `Counts[list, test]` — supported but the test-arg semantics deserve a regression test that distinguishes structural equality from `test`-induced equivalence (today the canonical test cases `Counts[{1,1,2,2,3}, Equal]` happen to coincide).

### L. Definitions and scoping

**Missing family members.**

- `BeginPackage`, `Begin`, `End`, `EndPackage`, `Needs`, `Get` (`<<`), `Put` (`>>`), `Save` — parser-only inert today.
- `Information[sym]`, `Definition[sym]` (also bucket J / P) — inert.
- `MessageName[sym, "tag"]` (also bucket J).

**Missing argument shapes.**

- `OwnValues[sym] = rules` direct assignment — inert (matrix confirms only via `Set` / `SetDelayed`).
- `DownValues[sym] = rules`, `UpValues[sym] = rules`, `SubValues[sym] = rules`, `NValues[sym] = rules` — inert direct assignment.
- `$Context = "..."`, `$ContextPath = {…}` — inert direct assignment (matrix explicit).
- `Block[$ContextPath, body]` — moot until contexts are mutable.

### M. Mutation operators

This is the bucket where Tungsten's "parser-only inert" debt is biggest.

**Missing family members (all parsed, none evaluated).**

- `AddTo` (`+=`), `SubtractFrom` (`-=`), `TimesBy` (`*=`), `DivideBy` (`/=`).
- `PrependTo[sym, item]` companion to `AppendTo`.
- `UpSet[lhs, rhs]`, `UpSetDelayed[lhs, rhs]`. Tagged up-values are reachable only via `TagSet` / `TagSetDelayed` today.
- `AssociateTo`, `KeyDropFrom` (also bucket K).
- `ApplyTo[sym, f]` — inert.

Without these, `For[i = 0, i < n, i += 2, …]`, `s += t`, and similar accumulator patterns do not work.

**Missing argument shapes.**

- Compound LHS for `Set`, `SetDelayed`, `Increment`, `Decrement`, `PreIncrement`, `PreDecrement`, `Unset`, `AppendTo`, `AddTo`. Verified: `a = {1,2,3}; a[[2]] = 99; a` keeps `a` unchanged because `Set[Part[a, 2], 99]` is left inert. Wolfram's contract is to rewrite this as a re-assembly: `a = ReplacePart[a, 2 -> 99]`. Same for `m[[i, j]] = v`, `assoc[k] = v`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`. Significant feature. The implementation work is mostly in `expression_definitions.py` (or the `Set` / `Increment` handlers) and is naturally one cross-cutting change.

### N. Control flow, debugging, exceptions

**Missing family members.**

- `Echo[expr]`, `Echo[expr, label]`, `Echo[expr, label, f]`. Inert (verified). Lightweight; small wrapper that prints + returns.
- `EchoFunction[f][expr]`, `EchoFunction[label, f][expr]`. Inert.
- `EchoTiming[expr]`, `EchoTiming[expr, label]`, `EchoEvaluation[expr]`. Inert.
- `Trace[expr]`, `TracePrint[expr]`, `TraceShallow`, `TraceCounts`, `Stack[]`, `StackBegin`, `StackComplete`. Inert. The full `Trace` family is a large surface, but the `Echo` family alone gives the REPL meaningful debug ergonomics; that is the small high-leverage subset to land.
- `RepeatedTiming[expr]`, `RepeatedTiming[expr, n]`. Inert.

**Missing argument shapes.**

- `Return[expr, head]` for `head ∈ {Function, CompoundExpression}` — currently only `Module`, `Block`, `InheritedBlock`, `Do`, `For`, `While` are wired. Adding `CompoundExpression` is the more useful target; `Function` matches a kernel quirk that the kernel itself handles oddly.
- `Throw[value, tag, h]`, `Catch[expr, form, f]` — supported per matrix.
- `AbortProtect[expr]`, `TimeConstrained[expr, t, fail]` — supported.

**Missing options.** `Print[args, options]` accepts `PageWidth`, `CharacterEncoding` in the kernel; ignored here. `Check`, `Quiet`, `WithCleanup` — none documented in kernel for these.

### O. Pure functions and composition

Mostly closed. Remaining items are the small completeness items already touched in other buckets:

- `Through[expr, head]` — works (matrix is stale; see "Documentation drift").
- `Operate[g, expr, 0]` — bug; see bucket D.
- `MapApply[f, expr, levelspec]` — only 2-arg form.

### P. Sessions, messages, hooks, introspection

Largely overlap with N and L. New items:

- `Information[sym]`, `?sym`, `??sym`, `Definition[sym]` — REPL has no information surface today.
- `MessageName[sym, "tag"]` reading.
- `$AssertFunction` — referenced by matrix as not implemented.

`Print[args]` supports the Tungsten output-form wrapper subset already and writes to `EvaluationSession.print_history`. The `PageWidth` / `CharacterEncoding` options are unhonored.

### Q. Boxes, forms, and display wrappers

Almost all FrontEnd-tied wrappers are out of scope: `Row`, `Column`, `Grid`, `Style`, `Framed`, `Panel`, `Pane`, `Item`, `Magnify`, `Tooltip`, `Mouseover`, `Button`, `Manipulate`. `BoxData`, `Cell`, `CellGroup`, `Notebook`, `NotebookGet`, `NotebookPut` overlap with the notebook subsystem.

Worth noting:

- `Defer[expr]` — defer evaluation in Print-style display; inert.
- `MatrixForm[m]` — inert (verified). Could be a thin display wrapper using existing `TableForm` machinery.
- `NumberForm[x, n]`, `NumberForm[x, {n, f}]`, with options `DigitBlock`, `ExponentFunction`, `NumberSeparator`, `NumberPoint`, `NumberSigns`, `SignPadding`, `NumberPadding` — most options are silently ignored.
- `BaseForm[x, base, opts]` — options ignored.
- `TableForm[list, opts]`, `MatrixForm[m, opts]` — `TableHeadings`, `TableSpacing`, `TableAlignments` ignored.

### R. Symbol, context, and package system

Already covered under L. The only addition is:

- `Names[..., SpellingCorrection]`, `Names[..., IgnoreCase]` — kernel-only options Tungsten could imitate (also bucket I option family).

### S. Sparse arrays and typed atoms

Already mature. Remaining:

- `SparseArray[Band[{i, j}], dims]` — `Band` constructor not implemented. Matrix explicit.
- General pattern rules in `SparseArray` constructor — matrix explicit.
- Wolfram-internal compressed FullForm — not implemented; round-trip of arbitrary kernel-emitted sparse arrays will not work.

### T. Encoding, I/O, hashing

- `Hash` family — see buckets A and I.
- File I/O: `OpenWrite`, `OpenAppend`, `Read`, `Close`, `WriteString`, `Write`, `BinaryWrite`, `BinaryRead`. Out of scope for kernel-free.
- More import/export formats: `XML`, `HTML`, `URL`, `MIME`, `Markdown`, `SExpression`, `BSON`, `MessagePack`. Matrix supports `"Byte"`, `"String"`, `"Text"`, `"WL"`, `"JSON"`, `"RawJSON"`, `"CSV"`, `"TSV"`, `"Table"` plus `"GZIP"` / `"BZIP2"` wrappers; expanding the list is a low-priority but mostly-mechanical pass.

**Missing argument shapes.**

- `ImportString[s]`, `ExportString[expr]` auto-detection — inert.
- `BaseEncode[ba, "encoding", n]` line-length argument — inert.

**Missing options.** Every Wolfram option on `ImportString` / `ExportString` (`"Compact"`, `"FieldSeparators"`, `"TextDelimiters"`, `"IncludeHeadings"`, etc.) — currently silently ignored.

## Cross-cutting holes

1. **Options system as a service.** `Options[f]`, `OptionValue[opts, key]`, `SetOptions[f, opts]`, `FilterRules[opts, spec]`, plus `OptionsPattern[f]` validation. Until this lands, every option-bearing head silently drops options it doesn't natively understand. (Buckets I, J, T, Q.)
2. **`Default[h, n]` registry.** `Optional[patt]` / `_.` shorthand cannot synthesize defaults for user-defined heads. (Bucket J.)
3. **`Heads -> True/False` on the rest of the pattern-search and traversal family.** Honored by `Position`, `Cases`, `Count`. Should be honored by `DeleteCases`, `MemberQ`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `MapAll`, `Scan`. (Buckets D, J.)
4. **Compound LHS for mutations.** `Set[m[[i, j]], v]`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`, `Unset[parts[i]]`. (Bucket M.)
5. **Direct value-list assignment.** `OwnValues[sym] = …`, `DownValues[sym] = …`, `UpValues[sym] = …`, `SubValues[sym] = …`, `NValues[sym] = …`. (Bucket L.)
6. **Symbolic constants beyond inert.** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree`. Need at least `Re` / `Im` / `Sign` / `Abs` rules. (Bucket A.)
7. **Transcendentals.** `Log`, `Exp`, `Sin`/`Cos`/`Tan`/inverse, `Sinh`/`Cosh`/`Tanh`/inverse, `Gamma`, `Beta`, etc. README still lists these as out-of-scope; if that holds, document the kernel-vs-Tungsten divergence explicitly so users do not chase silent inertness. (Bucket A.)
8. **Random number generation.** Entire `Random*` family. (Bucket G.)
9. **Numerator / Denominator and rational simplification.** `Numerator`, `Denominator`, `Together`, `Apart`, `Cancel`. SymPy bridge already exists. (Buckets A, C.)
10. **Polynomial algebra extensions.** `PolynomialGCD`, `PolynomialQuotient`, `PolynomialMod`, `PolynomialReduce`, `Resultant`, `Discriminant`. SymPy bridge wrappers. (Bucket C.)
11. **`Echo` family.** Tiny, high-leverage ergonomics for the REPL. (Bucket N.)
12. **String-pattern arguments.** `StringSplit[s, patt]`, `StringTrim[s, patt]`, `StringCount[s, patt]` — restricted to literal-string forms today. The string-pattern engine already exists; this is plumbing. (Bucket I.)
13. **String-search options.** `IgnoreCase`, `Overlaps`, `MetaCharacters` across the string-pattern family. (Bucket I.)
14. **`AddTo` / `SubtractFrom` / `TimesBy` / `DivideBy` / `PrependTo`.** Companion mutators to `AppendTo` / `Increment`. (Bucket M.)
15. **Statistics and integer helpers.** `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance`, `Divisible`, `CoprimeQ`, `NumberDigit`, `Factorial`, `Factorial2`, `Pochhammer`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`. Small wrappers, high data-science value. (Buckets A, B, G.)
16. **Operator forms.** `Map[f][expr]`, `Cases[patt][expr]`, `Replace[rules][expr]`, `MatchQ[patt][expr]`, `Position[patt][expr]`, `DeleteCases[patt][expr]`. The asymmetry with the dozen-plus heads that *do* support operator forms is confusing.

## Real bugs (small, isolated)

These are not feature gaps — they are documented behavior that disagrees with the kernel:

- **`Operate[g, expr, 0]` returns the input unchanged.** Kernel: `g[expr]`. Bucket D / O.
- **`Take[<|a->1, b->2, c->3|>, {Key[a], Key[b]}]` returns the input unchanged.** Kernel: `<|a->1, b->2|>`. The matrix bullet about "association supports numeric or span-style only" likely covers this, but the inert-rather-than-error behavior is surprising; consider raising a Tungsten diagnostic for unsupported association selector lists.

## Suggested next-pass priorities

These are opinion, not a roadmap, ordered by leverage per implementation complexity:

| Tier | Work | Why |
|------|------|-----|
| 1 | `Numerator`, `Denominator`, `Together`, `Apart`, `Cancel` | Wraps SymPy bridge; unblocks rational simplification. |
| 1 | `AddTo`, `SubtractFrom`, `TimesBy`, `DivideBy`, `PrependTo`, `AssociateTo`, `KeyDropFrom` | Companion mutators; make `For[i = 0, i < n, i += 2, …]` work. |
| 1 | Compound LHS for `Set` / `Increment` (`m[[i, j]] = v`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`) | One cross-cutting change that removes a long-standing limitation. |
| 1 | `Operate[g, expr, 0]` bug fix | One-line fix; small. |
| 1 | `Divisible`, `CoprimeQ`, `NumberDigit`, `Factorial`, `Factorial2` | Trivial wrappers; close out bucket B residuals. |
| 1 | `VectorQ`, `MatrixQ`, `FirstPosition`, `PositionLargest`, `PositionSmallest`, `PositionIndex`, `CountDistinct`, `CountsBy`, `KeyFreeQ`, `KeySortBy`, `ContainsOnly`, `Subdivide`, `Ratios` | One-line predicate / search helpers; close out bucket D residuals. |
| 1 | String helpers backed by existing Python: `StringDelete`, `StringExtract`, `StringPart`, `StringPartition`, `StringRotateLeft`, `StringRotateRight`, `StringTakeDrop`, `ToTitleCase`, `StringReplaceList`, `StringReplacePart` | Pure plumbing on existing string-pattern compiler. |
| 2 | Random number generation (`RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `SeedRandom`, `BlockRandom`) | High-impact for scripting / sampling workloads. |
| 2 | `Echo`, `EchoFunction`, `EchoTiming` | Lightweight debugging surface for the REPL. |
| 2 | Symbolic constants `Re`/`Im`/`Sign`/`Abs` rules for `Pi`, `E`, `EulerGamma`, `Degree` | Required scaffold for any later transcendental work; small. |
| 2 | Options system: `Options[f]`, `OptionValue`, `SetOptions`, `FilterRules`, `OptionsPattern` validation | Cross-cutting unblocker; many heads silently drop options. |
| 2 | `Default[h, n]` registry | Unlocks `_.` shorthand for user heads. |
| 2 | `Heads -> True/False` on `DeleteCases`, `MemberQ`, `FreeQ`, `Replace`, `ReplaceAll`, `Map`, `Scan` | Closes a documented gap in pattern traversal. |
| 2 | String-pattern arguments to `StringSplit`, `StringTrim`, `StringCount` | The pattern compiler exists; route the existing call sites through it. |
| 2 | Polynomial extensions `PolynomialGCD`, `PolynomialQuotient`, `PolynomialMod`, `PolynomialReduce`, `Resultant`, `Discriminant` | SymPy wrappers; close out bucket C. |
| 2 | Statistics: `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance` | Small numeric helpers; pair with random. |
| 3 | Operator forms for `Map`, `Cases`, `DeleteCases`, `Replace`, `Position`, `MatchQ` | Closes the asymmetry. |
| 3 | `Information[sym]`, `Definition[sym]`, `?sym`, `??sym` | REPL introspection. |
| 3 | `ReplaceList`, `Verbatim` (already partly working) | Combinatorial pattern enumeration. |
| 3 | `Trace`, `TracePrint`, `Stack[]` | Heavier debugging surface. |
| 3 | String options `IgnoreCase`, `Overlaps`, `MetaCharacters` (depends on options system) | Common string-search idioms. |
| 4 | Direct `OwnValues`/`DownValues`/`UpValues`/`SubValues`/`NValues` assignment | Round out the value-storage symmetry. |
| 4 | `BeginPackage`, `Begin`, `End`, `EndPackage`, `Needs`, `Get`, `Put` | Real context system; large. |
| 5 | Linear algebra (`LinearSolve`, `RowReduce`, `MatrixRank`, `NullSpace`, `Eigenvalues` …) | Out-of-scope per current README direction; revisit. |
| 5 | Calculus (`D`, `Integrate`, `Series`, `Limit`, closed-form `Sum`/`Product`) | Out-of-scope per README. |
| 5 | Solvers (`Solve`, `Reduce`, `NSolve`, `FindRoot`, `Roots`, `RootSum`, `ToRadicals`) | Out-of-scope. |
| 5 | Simplification (`Simplify`, `FullSimplify`, `TrigExpand`, `TrigReduce`, `PowerExpand`) | Out-of-scope. |

## Validation plan for implementation passes

Each implementation bucket should add tests in three layers:

- **Direct Wolfram-compatible examples** for each new function or new argument shape, drawn from the head's reference page.
- **Cross-head consistency tests**, especially for `Heads`, `SameTest`, sparse-array behavior, association value-vs-key traversal, and the soon-to-exist options system.
- **Kernel parity spot checks** when the local Wolfram installation is available (the existing `tungsten.kernel.WolframKernelRunner` plus the JSON-batched probe template used for this report is a good reusable base).

Sparse-aware functions should always include dense/sparse result equivalence, implicit-value behavior, shape preservation across slicing/padding/transposition/dot/normalization, and tests that avoid forcing dense materialization.

For options work, tests should cover accepted-and-honored options, unsupported options rejected with a Tungsten diagnostic, and option ordering / duplicate-option behavior (kernel uses last-option-wins).

## Notes

- "Out of scope today" items are listed deliberately so the long-tail picture is visible without a cross-reference. Their listing here is *not* a re-scoping signal; treat the README as authoritative for direction.
- Items flagged "verify" in the prior reports are spot-checked here. If a flag is not echoed in this document it has been confirmed working.
- The implementation-friendly items in the "Suggested next-pass priorities" Tier 1 row are deliberately small enough to land without changing evaluator semantics elsewhere; tiers 2 and 3 are where the cross-cutting refactors live.
