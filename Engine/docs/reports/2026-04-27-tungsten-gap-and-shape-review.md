# Tungsten Gap and Argument-Shape Review

- Status: Research-and-plan (current-state inventory of remaining work in the kernel-free Tungsten interpreter)
- Audience: Vladimir, Tungsten maintainers planning the next implementation passes
- Scope: `src/Tungsten/src/tungsten/` Python package — only the kernel-free expression subsystem. The Wolfram kernel interop layer is out of scope here.
- Created (UTC): 2026-04-27T16:48:25Z
- Updated (UTC): 2026-04-27T20:38:45Z
- Repository HEAD: e2ff91fdff0e3300d0f2e927bdb3829d0178bc0f
- Predecessors (now archived): `2026-04-23-external-review.md`, `2026-04-24-parser-evaluator-kernel-parity.md`, `2026-04-24-parser-evaluator-kernel-parity-evil-qa.md`, `2026-04-26-expression-parity-deep-review.md`, `2026-04-26-function-surface-gap-report.md`. Each archived header carries a notice; this document is the active gap inventory.

## Purpose and method

This report inventories what is still missing in Tungsten's kernel-free Wolfram-language interpreter at HEAD, broken down by family. For each family it lists, where applicable:

1. **Missing family members** — sibling heads that the kernel ships and that Tungsten leaves inert.
2. **Missing argument shapes** — heads where Tungsten *does* dispatch, but only some of the documented Wolfram signatures resolve.
3. **Missing options** — option keys that Tungsten silently ignores or rejects.

Method: I walked every dispatch chain under `src/tungsten/expression*.py`, reconciled it with `docs/expression-function-support.md`, executed each candidate gap item in-process through `evaluate(parse_expression(...))`, and used a batched kernel parity probe purely to nail down kernel ground truth. Items confirmed working at HEAD are not listed; only remaining gaps appear below.

The README scope statement is honored throughout: this report does not push for closed-form `Solve` / `Reduce`, calculus heads (`D`, `Integrate`, `Series`, `Limit`), broad simplification, dense linear algebra, optimization, or special mathematical functions. Where they appear in tables they are flagged as **out-of-scope** so the long-tail picture stays visible without re-scoping.

## Buckets

### A. Atoms, arithmetic, transcendentals

**Missing family members.**

- **Symbolic constants residual rules.** The basic constants `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Degree` now have `N[]` and `Sign[]` rules and participate in `Sin`/`Log`/etc. through the SymPy bridge. The remaining gaps are: direct `Re[const]` / `Im[const]` / `Abs[const]` rules (today users have to wrap in `ComplexExpand`); and the `Khinchin` / `Glaisher` constants which still have no `N[]` or `Sign[]` rule.

- **Logarithm head aliases.** `Log[b, x]` is implemented; the dedicated `Log2[x]` and `Log10[x]` heads still stay inert. Trivial wrappers (rewrite to `Log[2, x]` and `Log[10, x]`).

- **Special functions over integers.** `Gamma[n]` for non-negative integers (= `(n-1)!`), `LogGamma[n]`, `Factorial[n]`, `Factorial2[n]`, `Pochhammer[a, n]`, `Beta[a, b]`, `Subfactorial[n]`, `StirlingS1[n, k]`, `StirlingS2[n, k]`, `BellB[n]`, `CatalanNumber[n]`. All inert today, including under `N[]`. Each is a small wrapper.

- **`AbsArg`.** `Arg[z]` and `ComplexExpand[expr]` now work; the paired `AbsArg[z]` head still stays inert.

- **Numeric helpers.** `Rationalize[x]`, `Rationalize[x, dx]`, `RealDigits[x]`, `MantissaExponent[x]`, `Hash[expr]`, `Hash[expr, "MD5"|"SHA"|...]`, `Hash[expr, type, "Format"]`. None implemented.

- **Random number generation.** `RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`, `SeedRandom`, `BlockRandom`. None implemented (`RandomSample` and `RandomPermutation` are). `RandomInteger[]`, `RandomReal[]`, `RandomChoice[{...}]` all stay inert. High-impact gap for any data-shaping or scripting workload.

### B. Number theory (residual)

**Missing family members.** `Divisible[n, m]`, `CoprimeQ[a, b, …]`, `NumberDigit[n, k]` / `NumberDigit[n, k, base]`, `Factorial[n]`, `Factorial2[n]`, `Pochhammer[a, n]`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`, `Subfactorial` (the last six also bucket A). All inert. These nine plug into the existing `expression_arithmetic.py` `_evaluate_integer_special_functions` chain and look like ~60–120 LOC.

### C. Polynomial algebra and rational simplification (residual)

The rational-function and polynomial-extension family is now closed (`Numerator`, `Denominator`, `Together`, `Apart`, `Cancel`, `PolynomialGCD`, `PolynomialLCM`, `PolynomialMod`, `PolynomialQuotient`, `PolynomialRemainder`, `PolynomialReduce`, `Resultant`, `Discriminant`, `Subresultants`, `GroebnerBasis`, `ToRadicals`). What remains is restricted-form coverage:

**Out of scope per current README direction:** `Simplify`, `FullSimplify`, `Roots`, `Solve`, `Reduce`, `NSolve`, `FindRoot`, `RootSum`, `D`, `Derivative`, `Integrate`, `Series`, `Limit`, closed-form `Sum`/`Product`. Listed only so the long-tail picture is visible.

**Missing argument shapes.**

- `Expand[expr, patt]` — pattern-restricted expansion. Inert.
- `Factor[poly, Modulus -> p]` — over `Z/pZ`. Inert.
- `Factor[poly, Extension -> {Sqrt[2], …}]` — non-`I` algebraic extensions. Inert.
- `MonomialList[poly, monomialOrder]` — only lex order today.
- `Collect[expr, var, f]` — coefficient-transforming third argument is unsupported.
- `Coefficient[expr, vars, {n1, n2, …}]` — multi-exponent form against several variables at once.

**Missing options.** `Modulus`, `Trig`, `Cubics`, `Quartics`, `GaussianIntegers` for `Factor` / `FactorList` (only `True`/`False` for Gaussian today). `Trig`, `Modulus` for `Expand` / `ExpandAll`. `PolynomialQ[expr, Modulus -> p]`.

### D. Lists, arrays, tensors, structural (residual)

**Missing family members.** All confirmed inert.

- `ArrayFilter[f, list, n]`, `ArrayReduce[f, list, dims]` — out-of-scope per current direction; `ArrayReduce` is small enough to wrap as a structural fold.
- `Groupings[list, k]`, `SequenceReplace`, `SequenceSplit` — out-of-scope per current direction.
- `Numerator` / `Denominator` listable threading once the heads exist (also bucket A).

**Missing argument shapes.**

- `Inner[f, l, r, g, n]` 5-argument tensor-rank form (the kernel uses ``n`` as the contracted-axis depth, not a wrapping head).
- `Outer[f, list1, list2, …, n]` levelspec form.

**Missing options.** `ReplaceAll` and `ReplaceRepeated` walk heads unconditionally and ignore an explicit `Heads` rule (the kernel has the same behavior). All other pattern-search and traversal heads now honor `Heads -> True/False`.

### E. Linear algebra (out-of-scope per README, residual notes)

Listed for completeness:

- `LinearSolve`, `RowReduce`, `MatrixRank`, `NullSpace`.
- `Eigenvalues`, `Eigenvectors`, `Eigensystem`, `CharacteristicPolynomial`.
- `SingularValueDecomposition`, `LUDecomposition`, `QRDecomposition`, `CholeskyDecomposition`, `SchurDecomposition`, `JordanDecomposition`.
- `LeastSquares`, `PseudoInverse`, `Orthogonalize`, `Projection`.
- `KroneckerProduct`, `TensorProduct`, `TensorContract`, `TensorTranspose`.
- `MatrixExp`, `MatrixLog`, `MatrixFunction`.
- `Norm[m, p]` for matrix `p` — only vector p-norms work.
- `Chop[expr, dx]`.
- `IdentityMatrix[{n, m}]` non-square form.
- `DiagonalMatrix[list, k, {n, m}]` non-square form.
- `MatrixPower[m, n, v]` vector-applied power.

### F. Statistics and random

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

### G. Iteration, loops, functional iteration

- `Until[test, body]` — inert.
- `FixedPoint`, `FixedPointList` `SameTest -> f` option — not honored.
- Closed-form `Sum`/`Product` over symbolic `n` — out-of-scope per current direction.

### H. Strings, text, regex

This is one of the densest remaining buckets. None of the heads below are implemented.

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

### I. Pattern matching and replacement

**Missing family members.**

- `ReplaceList[expr, rules]`, `ReplaceList[expr, rules, n]` — enumerate every distinct match. Inert; valuable for combinatorial pattern enumeration.
- `Default[h]`, `Default[h, n]` — registry for `Optional[patt]` / `_.` defaults. Without this, `f[x_, y_.] := …` cannot synthesize defaults for user-defined heads with omitted arguments.
- `OptionValue[opts, key]`, `OptionValue[f, opts, key]`, `OptionValue[f, opts, key, default]` — none implemented.
- `Options[f]`, `SetOptions[f, opts]`, `Options[f] = {opts}`, `FilterRules[opts, spec]`. None implemented.
- `Information[sym]`, `Definition[sym]`, `?sym`, `??sym` parser forms.
- `MessageName[sym, "tag"]` parses but does not look up message-template values.

**Missing argument shapes.**

- `MatchQ[patt][expr]` operator form.
- `Replace[rules][expr]`, `Cases[patt][expr]`, `DeleteCases[patt][expr]`, `Position[patt][expr]`, `Map[f][expr]` operator forms. (Tungsten supports operator forms for `Select`, `SelectFirst`, `Discard`, `Scan`, `MapApply`, `MapAll`, `MapIndexed`, `KeySelect`, `SortBy`, `ReverseSortBy`, `OrderingBy`, `MinimalBy`, `MaximalBy`, `Comap`, `ComapApply`. The asymmetry is worth either closing or documenting.)
- `Replace[expr, rules, levelspec, Heads -> True/False]` — `Heads` option not honored (also bucket D).

**Missing options.**

- `Heads -> True/False` on `DeleteCases`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `MapAll`, `Scan` (cross-cutting; see bucket D).
- `OptionsPattern[f]` validating against `Options[f]` (depends on the options system landing).

### J. Associations (residual)

**Missing family members.**

- `JoinAcross[a1, a2, key]` relational-style join.
- `AssociationFromMatrix`, `AssociationToMatrix`.
- `AssociationMap[f, <|...|>]` direct-association form.
- `KeyDropFrom[sym, key]`, `AssociateTo[sym, rule]` — companions to the missing `PrependTo`/`AddTo` family in bucket K.
- `KeyFreeQ[assoc, key]`, `KeySortBy[assoc, f]`.
- `CountsBy[list, f]` (also bucket D).

**Missing argument shapes.**

- `Lookup[assoc, key, default, missingFn]` 4-arg form.
- `KeyMap[f][assoc]` operator form.

### K. Definitions and scoping

**Missing family members.**

- `BeginPackage`, `Begin`, `End`, `EndPackage`, `Needs`, `Get` (`<<`), `Put` (`>>`), `Save` — parser-only inert today.
- `Information[sym]`, `Definition[sym]` (also bucket I) — inert.
- `MessageName[sym, "tag"]` (also bucket I).

**Missing argument shapes.**

- `OwnValues[sym] = rules`, `DownValues[sym] = rules`, `UpValues[sym] = rules`, `SubValues[sym] = rules`, `NValues[sym] = rules` — direct value-list assignment.
- `$Context = "..."`, `$ContextPath = {…}` direct assignment.
- `Block[$ContextPath, body]` — moot until contexts are mutable.

### L. Mutation operators

This is the bucket where Tungsten's "parser-only inert" debt is biggest.

**Missing family members (all parsed, none evaluated).**

- `AddTo` (`+=`), `SubtractFrom` (`-=`), `TimesBy` (`*=`), `DivideBy` (`/=`).
- `PrependTo[sym, item]` companion to `AppendTo`.
- `UpSet[lhs, rhs]`, `UpSetDelayed[lhs, rhs]`. Tagged up-values are reachable only via `TagSet` / `TagSetDelayed` today.
- `AssociateTo`, `KeyDropFrom` (also bucket J).
- `ApplyTo[sym, f]`.

Without these, `For[i = 0, i < n, i += 2, …]`, `s += t`, and similar accumulator patterns do not work.

**Missing argument shapes.**

- Compound LHS for `Set`, `SetDelayed`, `Increment`, `Decrement`, `PreIncrement`, `PreDecrement`, `Unset`, `AppendTo`, `AddTo`. Verified: `a = {1,2,3}; a[[2]] = 99; a` keeps `a` unchanged because `Set[Part[a, 2], 99]` is left inert. Wolfram's contract is to rewrite this as a re-assembly: `a = ReplacePart[a, 2 -> 99]`. Same for `m[[i, j]] = v`, `assoc[k] = v`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`. Significant feature; the implementation work is mostly in `expression_definitions.py` (or the `Set` / `Increment` handlers) and is naturally one cross-cutting change.

### M. Control flow and debugging

**Missing family members.**

- `Echo[expr]`, `Echo[expr, label]`, `Echo[expr, label, f]`. Lightweight; small wrapper that prints + returns.
- `EchoFunction[f][expr]`, `EchoFunction[label, f][expr]`.
- `EchoTiming[expr]`, `EchoTiming[expr, label]`, `EchoEvaluation[expr]`.
- `Trace[expr]`, `TracePrint[expr]`, `TraceShallow`, `TraceCounts`, `Stack[]`, `StackBegin`, `StackComplete`. The full `Trace` family is a large surface, but the `Echo` family alone gives the REPL meaningful debug ergonomics; that is the small high-leverage subset to land first.
- `RepeatedTiming[expr]`, `RepeatedTiming[expr, n]`.

**Missing argument shapes.**

- `Return[expr, head]` for `head ∈ {Function, CompoundExpression}` — currently only `Module`, `Block`, `InheritedBlock`, `Do`, `For`, `While` are wired. Adding `CompoundExpression` is the more useful target.

**Missing options.** `Print[args, options]` accepts `PageWidth`, `CharacterEncoding` in the kernel; ignored here.

### N. Sessions, messages, hooks, introspection

Largely overlaps with I and K.

- `Information[sym]`, `?sym`, `??sym`, `Definition[sym]` — REPL has no information surface today.
- `MessageName[sym, "tag"]` reading.
- `$AssertFunction`.

### O. Boxes, forms, and display wrappers

Almost all FrontEnd-tied wrappers are out of scope: `Row`, `Column`, `Grid`, `Style`, `Framed`, `Panel`, `Pane`, `Item`, `Magnify`, `Tooltip`, `Mouseover`, `Button`, `Manipulate`. `BoxData`, `Cell`, `CellGroup`, `Notebook`, `NotebookGet`, `NotebookPut` overlap with the notebook subsystem.

Worth noting in the kernel-free interpreter:

- `Defer[expr]` — defer evaluation in Print-style display.
- `MatrixForm[m]` is inert; could be a thin display wrapper using existing `TableForm` machinery.
- `NumberForm[x, n]`, `NumberForm[x, {n, f}]`, with options `DigitBlock`, `ExponentFunction`, `NumberSeparator`, `NumberPoint`, `NumberSigns`, `SignPadding`, `NumberPadding` — most options are silently ignored.
- `BaseForm[x, base, opts]` — options ignored.
- `TableForm[list, opts]`, `MatrixForm[m, opts]` — `TableHeadings`, `TableSpacing`, `TableAlignments` ignored.

### P. Sparse arrays and typed atoms

Already mature. Remaining:

- `SparseArray[Band[{i, j}], dims]` — `Band` constructor.
- General pattern rules in `SparseArray` constructor.
- Wolfram-internal compressed FullForm — round-trip of arbitrary kernel-emitted sparse arrays will not work.

### Q. Encoding, I/O, hashing

- `Hash` family — see buckets A and H.
- File I/O: `OpenWrite`, `OpenAppend`, `Read`, `Close`, `WriteString`, `Write`, `BinaryWrite`, `BinaryRead`. Out of scope for kernel-free.
- More import/export formats: `XML`, `HTML`, `URL`, `MIME`, `Markdown`, `SExpression`, `BSON`, `MessagePack`. Matrix supports `"Byte"`, `"String"`, `"Text"`, `"WL"`, `"JSON"`, `"RawJSON"`, `"CSV"`, `"TSV"`, `"Table"` plus `"GZIP"` / `"BZIP2"` wrappers; expanding the list is mostly mechanical.

**Missing argument shapes.**

- `ImportString[s]`, `ExportString[expr]` auto-detection.
- `BaseEncode[ba, "encoding", n]` line-length argument.

**Missing options.** Every Wolfram option on `ImportString` / `ExportString` (`"Compact"`, `"FieldSeparators"`, `"TextDelimiters"`, `"IncludeHeadings"`, etc.) — currently silently ignored.

## Cross-cutting holes

These items hit multiple buckets and are worth flagging once at the top of any planning doc:

1. **Options system as a service.** `Options[f]`, `OptionValue[opts, key]`, `SetOptions[f, opts]`, `FilterRules[opts, spec]`, plus `OptionsPattern[f]` validation. Until this lands, every option-bearing head silently drops options it doesn't natively understand. (Buckets H, I, O, Q.)
2. **`Default[h, n]` registry.** `Optional[patt]` / `_.` shorthand cannot synthesize defaults for user-defined heads. (Bucket I.)
3. **Compound LHS for mutations.** `Set[m[[i, j]], v]`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`, `Unset[parts[i]]`. (Bucket L.)
4. **Direct value-list assignment.** `OwnValues[sym] = …`, `DownValues[sym] = …`, `UpValues[sym] = …`, `SubValues[sym] = …`, `NValues[sym] = …`. (Bucket K.)
5. **Direct `Re`/`Im`/`Abs` rules for symbolic constants.** Today users have to wrap in `ComplexExpand[...]` to get `Re[Pi] -> Pi`, `Im[Pi] -> 0`, `Abs[Pi] -> Pi`, etc. The constants `Khinchin` and `Glaisher` also still lack `N[]` rules. (Bucket A.)
6. **Special functions over integers.** `Gamma`, `LogGamma`, `Factorial`, `Factorial2`, `Pochhammer`, `Beta`, `Subfactorial`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`. Inert under both direct evaluation and `N[]`. (Bucket A.)
7. **Random number generation.** Entire `Random*` family. (Bucket F.)
8. **`Echo` family.** Tiny, high-leverage ergonomics for the REPL. (Bucket M.)
9. **String-pattern arguments.** `StringSplit[s, patt]`, `StringTrim[s, patt]`, `StringCount[s, patt]` — restricted to literal-string forms today. The string-pattern engine already exists; this is plumbing. (Bucket H.)
10. **String-search options.** `IgnoreCase`, `Overlaps`, `MetaCharacters` across the string-pattern family. (Bucket H.)
11. **`AddTo` / `SubtractFrom` / `TimesBy` / `DivideBy` / `PrependTo`.** Companion mutators to `AppendTo` / `Increment`. (Bucket L.)
12. **Statistics and integer helpers.** `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance`, `Divisible`, `CoprimeQ`, `NumberDigit`. Small wrappers, high data-science value. (Buckets B, F.)
13. **Operator forms.** `Map[f][expr]`, `Cases[patt][expr]`, `Replace[rules][expr]`, `MatchQ[patt][expr]`, `Position[patt][expr]`, `DeleteCases[patt][expr]`. The asymmetry with the dozen-plus heads that *do* support operator forms is confusing.

## Suggested next-pass priorities

These are opinion, not a roadmap, ordered by leverage per implementation complexity:

| Tier | Work | Why |
|------|------|-----|
| 1 | `AddTo`, `SubtractFrom`, `TimesBy`, `DivideBy`, `PrependTo`, `AssociateTo`, `KeyDropFrom` | Companion mutators; make `For[i = 0, i < n, i += 2, …]` work. |
| 1 | Compound LHS for `Set` / `Increment` (`m[[i, j]] = v`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`) | One cross-cutting change that removes a long-standing limitation. |
| 1 | `Divisible`, `CoprimeQ`, `NumberDigit`, `Factorial`, `Factorial2` | Trivial wrappers; close out bucket B residuals. |
| 1 | `KeyFreeQ`, `KeySortBy` | Small association helpers; close out bucket J residuals. |
| 1 | `Log2`, `Log10` aliases for `Log[2, x]` / `Log[10, x]` | One-line rewrites. |
| 1 | `AbsArg[z]` paired with the existing `Abs` and `Arg` | One-line wrapper. |
| 1 | String helpers backed by existing Python: `StringDelete`, `StringExtract`, `StringPart`, `StringPartition`, `StringRotateLeft`, `StringRotateRight`, `StringTakeDrop`, `ToTitleCase`, `StringReplaceList`, `StringReplacePart` | Pure plumbing on existing string-pattern compiler. |
| 2 | Random number generation (`RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `SeedRandom`, `BlockRandom`) | High-impact for scripting / sampling workloads. |
| 2 | `Echo`, `EchoFunction`, `EchoTiming` | Lightweight debugging surface for the REPL. |
| 2 | Direct `Re`/`Im`/`Abs` rules for `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Degree`; `N[]` and `Sign[]` for `Khinchin` / `Glaisher` | Removes the `ComplexExpand[...]` workaround for trivial real-constant cases. |
| 2 | Special functions over integers: `Gamma`, `LogGamma`, `Factorial`, `Factorial2`, `Pochhammer`, `Beta`, `Subfactorial`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber` | SymPy bridge wrappers. |
| 2 | Options system: `Options[f]`, `OptionValue`, `SetOptions`, `FilterRules`, `OptionsPattern` validation | Cross-cutting unblocker; many heads silently drop options. |
| 2 | `Default[h, n]` registry | Unlocks `_.` shorthand for user heads. |
| 2 | String-pattern arguments to `StringSplit`, `StringTrim`, `StringCount` | The pattern compiler exists; route the existing call sites through it. |
| 2 | Statistics: `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance` | Small numeric helpers; pair with random. |
| 3 | Operator forms for `Map`, `Cases`, `DeleteCases`, `Replace`, `Position`, `MatchQ` | Closes the asymmetry. |
| 3 | `Information[sym]`, `Definition[sym]`, `?sym`, `??sym` | REPL introspection. |
| 3 | `ReplaceList` | Combinatorial pattern enumeration. |
| 3 | `Trace`, `TracePrint`, `Stack[]` | Heavier debugging surface. |
| 3 | String options `IgnoreCase`, `Overlaps`, `MetaCharacters` (depends on options system) | Common string-search idioms. |
| 4 | Direct `OwnValues`/`DownValues`/`UpValues`/`SubValues`/`NValues` assignment | Round out the value-storage symmetry. |
| 4 | `BeginPackage`, `Begin`, `End`, `EndPackage`, `Needs`, `Get`, `Put` | Real context system; large. |
| 5 | Linear algebra (`LinearSolve`, `RowReduce`, `MatrixRank`, `NullSpace`, `Eigenvalues` …) | Out-of-scope per current README direction; revisit. |
| 5 | Calculus (`D`, `Integrate`, `Series`, `Limit`, closed-form `Sum`/`Product`) | Out-of-scope per README. |
| 5 | Solvers (`Solve`, `Reduce`, `NSolve`, `FindRoot`, `Roots`, `RootSum`) | Out-of-scope. |
| 5 | Simplification (`Simplify`, `FullSimplify`, `TrigExpand`, `TrigReduce`, `PowerExpand`) | Out-of-scope. |

## Validation plan for implementation passes

Each implementation bucket should add tests in three layers:

- **Direct Wolfram-compatible examples** for each new function or new argument shape, drawn from the head's reference page.
- **Cross-head consistency tests**, especially for `Heads`, `SameTest`, sparse-array behavior, association value-vs-key traversal, and the soon-to-exist options system.
- **Kernel parity spot checks** when the local Wolfram installation is available, used purely to confirm Tungsten's kernel-free output matches the kernel's behavior on the same inputs.

Sparse-aware functions should always include dense/sparse result equivalence, implicit-value behavior, shape preservation across slicing/padding/transposition/dot/normalization, and tests that avoid forcing dense materialization.

For options work, tests should cover accepted-and-honored options, unsupported options rejected with a Tungsten diagnostic, and option ordering / duplicate-option behavior (kernel uses last-option-wins).

## Notes

- "Out of scope today" items are listed deliberately so the long-tail picture is visible without a cross-reference. Their listing here is *not* a re-scoping signal; treat the README as authoritative for direction.
- The implementation-friendly items in the "Suggested next-pass priorities" Tier 1 row are deliberately small enough to land without changing evaluator semantics elsewhere; tiers 2 and 3 are where the cross-cutting refactors live.
