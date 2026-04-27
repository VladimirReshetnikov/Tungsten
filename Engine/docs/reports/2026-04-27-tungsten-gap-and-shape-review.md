# Tungsten Gap and Argument-Shape Review

- Status: Research-and-plan (current-state inventory of remaining work in the kernel-free Tungsten interpreter)
- Audience: Vladimir, Tungsten maintainers planning the next implementation passes
- Scope: `src/Tungsten/src/tungsten/` Python package — only the kernel-free expression subsystem. The Wolfram kernel interop layer is out of scope here.
- Created (UTC): 2026-04-27T16:48:25Z
- Updated (UTC): 2026-04-27T17:19:00Z
- Repository HEAD: f4a230578d18a99e678d1c62a908b230ac46f7f4
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

- **Symbolic constants beyond inert.** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree` are accepted as inert symbols and `N[Pi, p]` / `N[E, p]` / `N[EulerGamma, p]` work via the SymPy bridge. They have no associated `Re` / `Im` / `Sign` / `Abs` rules and no participation in arithmetic identities (e.g. `2 Pi - Pi` does not simplify to `Pi`). All of `Re[Pi]`, `Im[I*Pi]`, and `Re[I*Pi]` stay inert. **Add per-constant rules for the deterministic-real cases**: `Re[const] -> const`, `Im[const] -> 0` for the real-valued constants; `Sign[Pi] -> 1`, `Abs[Pi] -> Pi`, etc. The same hooks unblock most of the items below once the value heads are in place.

- **Transcendental and elementary functions.** None of these have evaluator rules today. Adding even a small subset of exact rules over the explicit-numeric / `Pi` / `E` / `I` subset would dramatically expand what ordinary Wolfram code Tungsten can run.

  | Family | Heads |
  |--------|-------|
  | Logarithms | `Log[x]`, `Log[b, x]`, `Log2[x]`, `Log10[x]` |
  | Exponential | `Exp[x]` |
  | Trig | `Sin`, `Cos`, `Tan`, `Sec`, `Csc`, `Cot` |
  | Inverse trig | `ArcSin`, `ArcCos`, `ArcTan` (1-arg and 2-arg `ArcTan[x, y]`), `ArcSec`, `ArcCsc`, `ArcCot` |
  | Hyperbolic | `Sinh`, `Cosh`, `Tanh`, `Sech`, `Csch`, `Coth` |
  | Inverse hyperbolic | `ArcSinh`, `ArcCosh`, `ArcTanh`, `ArcSech`, `ArcCsch`, `ArcCoth` |

  The README explicitly excludes "real- or complex-valued elementary or special mathematical functions" and "expression simplification." If staying out-of-scope, keep the heads inert and document the Wolfram-vs-Tungsten divergence so users do not chase silent inertness. If moving in-scope even narrowly, the smallest defensible subset is exact rules for explicit-numeric and `Pi`/`E`/`I` arguments — `Sin[Pi/6] -> 1/2`, `Log[E] -> 1`, `Exp[0] -> 1`, `ArcTan[1] -> Pi/4`, `Tan[Pi/4] -> 1` — plus inert pass-through for everything else.

- **Special functions over integers.** `Gamma[n]` for non-negative integers (= `(n-1)!`), `LogGamma[n]`, `Factorial[n]`, `Factorial2[n]`, `Pochhammer[a, n]`, `Beta[a, b]`, `Subfactorial[n]`, `StirlingS1[n, k]`, `StirlingS2[n, k]`, `BellB[n]`, `CatalanNumber[n]`. All inert today. Each is a small wrapper.

- **Complex-number helpers.** `Arg[z]`, `AbsArg[z]`, `ComplexExpand[expr]`. All inert. Tungsten already has `Re`, `Im`, `Conjugate`, `Abs`, so a small `Arg` for explicit real and pure-imaginary `z` plus a structural `ComplexExpand` over the `(a + I b)^n` template is feasible without crossing into broad simplification.

- **Rational structure.** `Numerator[expr]`, `Denominator[expr]`. Glaring hole — Tungsten has full exact `Rational`, but `Numerator[3/4]` and `Denominator[3/4]` are inert. **Add.** Once the head dispatches, threading over rational expressions through SymPy is a five-line wrapper.

- **Numeric helpers.** `Rationalize[x]`, `Rationalize[x, dx]`, `RealDigits[x]`, `MantissaExponent[x]`, `Hash[expr]`, `Hash[expr, "MD5"|"SHA"|...]`, `Hash[expr, type, "Format"]`. None implemented.

- **Random number generation.** `RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`, `SeedRandom`, `BlockRandom`. None implemented (`RandomSample` and `RandomPermutation` are). `RandomInteger[]`, `RandomReal[]`, `RandomChoice[{...}]` all stay inert. High-impact gap for any data-shaping or scripting workload.

### B. Number theory (residual)

**Missing family members.** `Divisible[n, m]`, `CoprimeQ[a, b, …]`, `NumberDigit[n, k]` / `NumberDigit[n, k, base]`, `Factorial[n]`, `Factorial2[n]`, `Pochhammer[a, n]`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`, `Subfactorial` (the last six also bucket A). All inert. These nine plug into the existing `expression_arithmetic.py` `_evaluate_integer_special_functions` chain and look like ~60–120 LOC.

### C. Polynomial algebra and rational simplification

The SymPy bridge already underpins `Expand`, `Factor`, `Collect`, `Coefficient`, `MonomialList`, `CoefficientList`, `Decompose`, `PolynomialQ`, `Variables`, and `Exponent`. The natural follow-on layer is missing entirely.

**Missing family members.**

- `Numerator`, `Denominator` (also bucket A; these unblock everything below).
- `Together[expr]`, `Apart[expr]`, `Apart[expr, x]`, `Cancel[expr]`. All thin SymPy wrappers; confirmed inert.
- `PolynomialGCD`, `PolynomialLCM`, `PolynomialMod[poly, m]`, `PolynomialQuotient[a, b, x]`, `PolynomialRemainder[a, b, x]`, `PolynomialReduce[poly, polys, vars]`. All thin SymPy wrappers.
- `Resultant[p, q, x]`, `Discriminant[p, x]`, `Subresultants`. SymPy bridge for the first two; `Subresultants` is more involved.
- `GroebnerBasis[polys, vars]`. SymPy has it; the bridge is mostly type-marshalling.

**Out of scope per current README direction:** `Simplify`, `FullSimplify`, `Roots`, `Solve`, `Reduce`, `NSolve`, `FindRoot`, `RootSum`, `ToRadicals`, `D`, `Derivative`, `Integrate`, `Series`, `Limit`, closed-form `Sum`/`Product`. Listed only so the long-tail picture is visible.

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

- `VectorQ[expr]`, `VectorQ[expr, test]`.
- `MatrixQ[expr]`, `MatrixQ[expr, test]`.
- `FirstPosition[expr, patt]`, `FirstPosition[expr, patt, default]`, `FirstPosition[expr, patt, default, levelspec]`.
- `PositionLargest[list]`, `PositionSmallest[list]`.
- `PositionIndex[list]`.
- `CountDistinct[list]`.
- `CountsBy[list, f]`.
- `ContainsOnly[a, b]`, `ContainsOnly[a, b, SameTest -> f]`.
- `Subdivide[n]`, `Subdivide[n, k]`, `Subdivide[xmin, xmax, k]`.
- `Splice[{a, b, c}]`, `f[Splice[{a, b}], c]` — variadic argument splicer.
- `Ratios[list]` — adjacent-pair ratios.
- `SubsetMap[f, list, positions]`.
- `ArrayFilter[f, list, n]`, `ArrayReduce[f, list, dims]` — out-of-scope per current direction; `ArrayReduce` is small enough to wrap as a structural fold.
- `Groupings[list, k]`, `SequenceReplace`, `SequenceSplit` — out-of-scope per current direction.
- `Numerator` / `Denominator` listable threading once the heads exist (also bucket A).

**Missing argument shapes.**

- `MapApply[f, expr, levelspec]` — only 2-arg form. Mechanical extension on top of the `Map` levelspec walker.
- `Operate[g, expr, 0]` — kernel returns `g[expr]`; Tungsten leaves it inert. **Real bug**, isolated. The same dispatch already handles default and `n=1`. One-line fix.
- `Distribute[expr, g, f, gp, fp]` 5-arg form.
- `Inner[f, l, r, g, h]` 5-arg generalization.
- `Flatten[expr, n, h]` 3-arg form selecting which head to flatten.
- `Take[assoc, {Key[k], …}]` — only numeric / span specs work on associations today. Verified: `Take[<|a->1, b->2, c->3|>, {Key[a], Key[b]}]` returns the input unchanged instead of `<|a->1, b->2|>`. Treat the unsupported selector list as a Tungsten diagnostic rather than silent inertness.
- `Differences[list, {n1, n2}]` multivariate.
- `Outer[f, list1, list2, …, n]` levelspec form.
- `Position[expr, patt, levelspec, n, "Index"]` — second-property form.

**Missing options.** `Heads -> True/False` is honored on `Position`, `Cases`, `Count`, `MemberQ`. It is **not** honored on `DeleteCases`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `MapAll`, `Scan`. The cross-cutting fix is one shared option-parsing path.

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

### N. Pure functions and composition (residual)

- `Operate[g, expr, 0]` bug — see bucket D.
- `MapApply[f, expr, levelspec]` — only 2-arg form (also bucket D).

### O. Sessions, messages, hooks, introspection

Largely overlaps with I and K.

- `Information[sym]`, `?sym`, `??sym`, `Definition[sym]` — REPL has no information surface today.
- `MessageName[sym, "tag"]` reading.
- `$AssertFunction`.

### P. Boxes, forms, and display wrappers

Almost all FrontEnd-tied wrappers are out of scope: `Row`, `Column`, `Grid`, `Style`, `Framed`, `Panel`, `Pane`, `Item`, `Magnify`, `Tooltip`, `Mouseover`, `Button`, `Manipulate`. `BoxData`, `Cell`, `CellGroup`, `Notebook`, `NotebookGet`, `NotebookPut` overlap with the notebook subsystem.

Worth noting in the kernel-free interpreter:

- `Defer[expr]` — defer evaluation in Print-style display.
- `MatrixForm[m]` is inert; could be a thin display wrapper using existing `TableForm` machinery.
- `NumberForm[x, n]`, `NumberForm[x, {n, f}]`, with options `DigitBlock`, `ExponentFunction`, `NumberSeparator`, `NumberPoint`, `NumberSigns`, `SignPadding`, `NumberPadding` — most options are silently ignored.
- `BaseForm[x, base, opts]` — options ignored.
- `TableForm[list, opts]`, `MatrixForm[m, opts]` — `TableHeadings`, `TableSpacing`, `TableAlignments` ignored.

### Q. Sparse arrays and typed atoms

Already mature. Remaining:

- `SparseArray[Band[{i, j}], dims]` — `Band` constructor.
- General pattern rules in `SparseArray` constructor.
- Wolfram-internal compressed FullForm — round-trip of arbitrary kernel-emitted sparse arrays will not work.

### R. Encoding, I/O, hashing

- `Hash` family — see buckets A and H.
- File I/O: `OpenWrite`, `OpenAppend`, `Read`, `Close`, `WriteString`, `Write`, `BinaryWrite`, `BinaryRead`. Out of scope for kernel-free.
- More import/export formats: `XML`, `HTML`, `URL`, `MIME`, `Markdown`, `SExpression`, `BSON`, `MessagePack`. Matrix supports `"Byte"`, `"String"`, `"Text"`, `"WL"`, `"JSON"`, `"RawJSON"`, `"CSV"`, `"TSV"`, `"Table"` plus `"GZIP"` / `"BZIP2"` wrappers; expanding the list is mostly mechanical.

**Missing argument shapes.**

- `ImportString[s]`, `ExportString[expr]` auto-detection.
- `BaseEncode[ba, "encoding", n]` line-length argument.

**Missing options.** Every Wolfram option on `ImportString` / `ExportString` (`"Compact"`, `"FieldSeparators"`, `"TextDelimiters"`, `"IncludeHeadings"`, etc.) — currently silently ignored.

## Cross-cutting holes

These items hit multiple buckets and are worth flagging once at the top of any planning doc:

1. **Options system as a service.** `Options[f]`, `OptionValue[opts, key]`, `SetOptions[f, opts]`, `FilterRules[opts, spec]`, plus `OptionsPattern[f]` validation. Until this lands, every option-bearing head silently drops options it doesn't natively understand. (Buckets H, I, P, R.)
2. **`Default[h, n]` registry.** `Optional[patt]` / `_.` shorthand cannot synthesize defaults for user-defined heads. (Bucket I.)
3. **`Heads -> True/False` on the rest of the pattern-search and traversal family.** Honored by `Position`, `Cases`, `Count`, `MemberQ`. Should be honored by `DeleteCases`, `FreeQ`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `Map`, `MapAll`, `Scan`. (Buckets D, I.)
4. **Compound LHS for mutations.** `Set[m[[i, j]], v]`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`, `Unset[parts[i]]`. (Bucket L.)
5. **Direct value-list assignment.** `OwnValues[sym] = …`, `DownValues[sym] = …`, `UpValues[sym] = …`, `SubValues[sym] = …`, `NValues[sym] = …`. (Bucket K.)
6. **Symbolic constants beyond inert.** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree`. Need at least `Re` / `Im` / `Sign` / `Abs` rules. (Bucket A.)
7. **Transcendentals.** `Log`, `Exp`, `Sin`/`Cos`/`Tan`/inverse, `Sinh`/`Cosh`/`Tanh`/inverse, `Gamma`, `Beta`. README still lists these as out-of-scope; if that holds, document the divergence explicitly so users do not chase silent inertness. (Bucket A.)
8. **Random number generation.** Entire `Random*` family. (Bucket F.)
9. **Numerator / Denominator and rational simplification.** `Numerator`, `Denominator`, `Together`, `Apart`, `Cancel`. SymPy bridge already exists. (Buckets A, C.)
10. **Polynomial algebra extensions.** `PolynomialGCD`, `PolynomialQuotient`, `PolynomialMod`, `PolynomialReduce`, `Resultant`, `Discriminant`. SymPy bridge wrappers. (Bucket C.)
11. **`Echo` family.** Tiny, high-leverage ergonomics for the REPL. (Bucket M.)
12. **String-pattern arguments.** `StringSplit[s, patt]`, `StringTrim[s, patt]`, `StringCount[s, patt]` — restricted to literal-string forms today. The string-pattern engine already exists; this is plumbing. (Bucket H.)
13. **String-search options.** `IgnoreCase`, `Overlaps`, `MetaCharacters` across the string-pattern family. (Bucket H.)
14. **`AddTo` / `SubtractFrom` / `TimesBy` / `DivideBy` / `PrependTo`.** Companion mutators to `AppendTo` / `Increment`. (Bucket L.)
15. **Statistics and integer helpers.** `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance`, `Divisible`, `CoprimeQ`, `NumberDigit`, `Factorial`, `Factorial2`, `Pochhammer`, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`. Small wrappers, high data-science value. (Buckets A, B, F.)
16. **Operator forms.** `Map[f][expr]`, `Cases[patt][expr]`, `Replace[rules][expr]`, `MatchQ[patt][expr]`, `Position[patt][expr]`, `DeleteCases[patt][expr]`. The asymmetry with the dozen-plus heads that *do* support operator forms is confusing.

## Real bugs (small, isolated)

These are not feature gaps — they are documented behavior that disagrees with the kernel:

- **`Operate[g, expr, 0]` returns the input unchanged.** Kernel: `g[expr]`. Bucket D / N.
- **`Take[<|a->1, b->2, c->3|>, {Key[a], Key[b]}]` returns the input unchanged.** Kernel: `<|a->1, b->2|>`. The matrix bullet about "association supports numeric or span-style only" likely covers this, but the inert-rather-than-error behavior is surprising; consider raising a Tungsten diagnostic for unsupported association selector lists. (Bucket D.)

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
| 2 | `Heads -> True/False` on `DeleteCases`, `FreeQ`, `Replace`, `ReplaceAll`, `Map`, `Scan` | Closes a documented gap in pattern traversal. |
| 2 | String-pattern arguments to `StringSplit`, `StringTrim`, `StringCount` | The pattern compiler exists; route the existing call sites through it. |
| 2 | Polynomial extensions `PolynomialGCD`, `PolynomialQuotient`, `PolynomialMod`, `PolynomialReduce`, `Resultant`, `Discriminant` | SymPy wrappers; close out bucket C. |
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
| 5 | Solvers (`Solve`, `Reduce`, `NSolve`, `FindRoot`, `Roots`, `RootSum`, `ToRadicals`) | Out-of-scope. |
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
