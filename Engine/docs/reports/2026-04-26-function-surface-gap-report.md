# Tungsten Function-Surface Gap Report

- Created (UTC): 2026-04-27T02:13:19Z
- Updated (UTC): 2026-04-27T02:55:00Z
- Repository HEAD: fef68fe7c4ff341cf5e62f4f20a8765192e63a38
- Status: Research-and-plan with Buckets B (number theory) and D (Lists, arrays, tensors, structural) implemented in follow-up commits. The bullets for landed buckets are kept here as historical context — the support matrix is the authoritative current-state record.
- Audience: Tungsten maintainers planning the next implementation passes
- Scope: Functions/heads in `src/Tungsten/src/tungsten/expression*.py`

## Purpose

This report inventories the gaps in Tungsten's Wolfram-Language structural surface as of HEAD. For each natural family of heads it lists three things:

1. **Missing family members** — sibling heads that fit the family but Tungsten does not yet dispatch.
2. **Missing argument shapes** — heads Tungsten *does* dispatch but with fewer documented Wolfram signatures than the kernel.
3. **Missing options** — heads that take Wolfram options whose effect Tungsten ignores or whose option keys are not yet honored.

The baseline is `docs/expression-function-support.md` plus a sweep of the dispatch tables in `expression_evaluator.py`. The reference for "what should exist" is the Wolfram 14.x documentation. The buckets below are organized by topic so a maintainer can pick one bucket and treat it as a self-contained workstream.

## Methodology

- The implemented surface was extracted from `expression-function-support.md` (438 documented rows, or 451 declared symbols after splitting combined rows such as `BitAnd` / `BitOr` / `BitXor`) and reconciled with `expression_evaluator.py` dispatch. Items the matrix already calls out as out-of-scope or partially supported are pulled forward into the bucket they belong to instead of being repeated in a separate "known limitations" section.
- "Missing argument shape" is interpreted strictly: a Wolfram-documented signature for the head that produces a different evaluation path than the implemented signatures (not just a different syntactic surface for the same evaluator).
- "Missing option" includes both options that are silently ignored and options that the matrix explicitly lists as out-of-scope.
- A second guide-family pass compared the support matrix against the Wolfram guide pages for list manipulation, list elements, rearranging/restructuring lists, applying functions to lists, functional programming, associations, tensors, string operations, integer functions, polynomial algebra, scoping, procedural programming, and messages.
- The local Wolfram 14.3 kernel was also queried for `Options[...]` on every documented Tungsten head. The cross-cutting option gaps below are grounded in that option inventory, not only in the prose support matrix.
- The report is current-state. When work lands, fold the relevant bullet into the support matrix and remove it here.

## Guide-family cross-check

The guide-family pass is useful because it shows which natural neighborhoods Tungsten has already
entered, even when the support matrix does not mention every sibling. The exact counts should not be
treated as a roadmap, because many guide entries are graphics, datasets, streams, solvers, or other
families outside Tungsten's kernel-free structural evaluator. They do identify small holes that are
easy to miss when reading only the dispatch table.

| Guide family | Implemented symbols from the sampled guide list | Notable missing structural candidates |
|--------------|--------------------------------------------------|---------------------------------------|
| List manipulation | 51 of 69 | `ContainsOnly`, `CountDistinct`, `PositionIndex`, `SequenceCount`, `Subdivide`, `Splice`, `UpTo` |
| Elements of lists | 47 of 63 | `FirstPosition`, `MatrixQ`, `VectorQ`, `PositionLargest`, `PositionSmallest`, `PrependTo`, `SequenceCases`, `SequencePosition` |
| Rearranging and restructuring | 45 of 52 | `ArrayFilter`, `ArrayReduce`, `Groupings`, `SequenceReplace`, `SequenceSplit`, `Splice` |
| Applying functions to lists | 15 of 21 | `ArrayFilter`, `ArrayReduce`, `Ratios`, `SubsetMap` |
| Functional programming | 41 of 48 | `CountsBy`, `KeySortBy`, `OperatorApplied`, `CurryApplied`, `ReverseApplied`, `SubsetMap` |
| Associations | 29 of 40 | `AssociateTo`, `CountsBy`, `KeyDropFrom`, `KeyFreeQ`, `KeySortBy`, `Missing`, `PositionIndex` |
| Tensors | 19 of 22 | `ArrayReduce`, `Band`, `MatrixForm` |
| String operations | 28 of 50 | `CharacterCounts`, `StringPart`, `StringTakeDrop`, `StringExtract`, `StringPartition`, `StringReplaceList`, `StringReplacePart`, `StringRotateLeft`, `StringRotateRight` |
| Integer functions | 34 of 52 | `Divisible`, `CoprimeQ`, `NumberDigit`, `Factorial` |
| Polynomial algebra | 10 of 44 | `CoefficientRules`, `PolynomialGCD`, `PolynomialMod`, `PolynomialQuotient`, `PolynomialReduce`, `Discriminant`, `Resultant`, `IrreduciblePolynomialQ` |
| Messages | 9 of 20 | `Failure`, `Missing`, `MessageName`, `Messages`, `CheckArguments`, `DeleteMissing`, `TerminatedEvaluation` |
| Scoping and procedural programming | 40 of 53 across both guides | `Until`, `ApplyTo`, `Begin`, `End`, `BlockRandom`, `Input`, `OpenRead` |

The most implementation-friendly missing symbols from this table are the ones that reuse existing
machinery: predicates (`VectorQ`, `MatrixQ`, `KeyFreeQ`), selector/search helpers
(`FirstPosition`, `PositionIndex`, `PositionLargest`, `PositionSmallest`), counters
(`CountDistinct`, `CountsBy`, `CharacterCounts`), mutators (`PrependTo`,
`AssociateTo`, `KeyDropFrom`, `ApplyTo`), small integer helpers (`Divisible`, `CoprimeQ`,
`NumberDigit`), and string slicing helpers (`StringPart`, `StringTakeDrop`, `StringPartition`,
`StringRotateLeft`, `StringRotateRight`).

## Buckets

### A. Atoms and arithmetic

**Missing family members**

- **Symbolic mathematical constants:** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree`. Only `I` is special-cased; no other constant has an own value or a `Re`/`Im`/`N` rule.
- **Transcendental functions:** `Log` (1-arg natural and 2-arg base), `Exp`, `Log2`, `Log10`. None implemented.
- **Trigonometric / hyperbolic:** `Sin`, `Cos`, `Tan`, `Sec`, `Csc`, `Cot`, `ArcSin`, `ArcCos`, `ArcTan` (1-arg and 2-arg `ArcTan[x, y]`), `ArcSec`, `ArcCsc`, `ArcCot`, `Sinh`, `Cosh`, `Tanh`, `Sech`, `Csch`, `Coth`, plus the `ArcSinh`/`ArcCosh`/`ArcTanh` family. None implemented.
- **Special functions** (where exact / rational evaluation is meaningful): `Gamma[n]` for non-negative integers, `LogGamma`, `Factorial[n]`/`Factorial2[n]`, `Pochhammer`, `Subfactorial`, `Beta[a, b]` for explicit positive integers, `StirlingS1`, `StirlingS2`, `BellB`, `CatalanNumber`. `BernoulliB`, `EulerE`, `HarmonicNumber`, `Fibonacci`, and `LucasL` moved to the implemented number-theory bucket.
- **Complex helpers:** `Arg[z]`, `AbsArg[z]`, `ComplexExpand[expr]`. Only `Re`, `Im`, `Conjugate` exist.
- **Rational structure:** `Numerator[expr]`, `Denominator[expr]`. **Glaring hole** — Tungsten has full exact `Rational` support and a polynomial algebra subsystem, but no numerator/denominator extraction. Many polynomial workflows (Together / Apart / partial fractions / rational simplification) build on these.
- **Numeric helpers:** `Rationalize[x]`, `Rationalize[x, dx]` (rational approximation), `RealDigits[x]`, `MantissaExponent`, `MachineNumberQ` (already in), `Hash[expr]`, `Hash[expr, type]`.
- **`MinMax[list]`** — pair-in-one-pass; missing.
- **Random number generation:** entire `RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`, `SeedRandom`, `BlockRandom` family. Not implemented.

**Missing argument shapes**

- `Floor[x, a]`, `Ceiling[x, a]`, `Round[x, a]` — round/floor/ceiling to a multiple of `a`. Only the 1-arg forms are implemented.
- `Mod[m, n]` for non-integer `m` (real or rational). The matrix explicitly limits to integers.
- `Sign[z]` for complex `z` — should return the unit complex number `z / Abs[z]`.
- `Abs[z]` for purely symbolic `z` — only numeric and a narrow Gaussian-radical case are supported.
- `IntegerPart[z]` / `FractionalPart[z]` for complex `z` (component-wise).
- `Min[expr]` / `Max[expr]` — listable threading and option-style forms (only positional and one-list-unwrap are implemented).
- `Plus`/`Times`: factor across unrelated coefficients (e.g., `a x + b x` → `(a + b) x`). The matrix explicitly notes this is out-of-scope today.
- `Power[base, exponent]` for fractional exponents on exact non-perfect-powers (only perfect squares and integer exponents normalize today).
- `N[expr, p]` for inputs that contain transcendental functions or constants (currently relies on supported numeric atoms only).

**Missing options**

- `N[expr, p, options]` — `WorkingPrecision`, `AccuracyGoal`, `PrecisionGoal`. Not honored.
- `Equal[a, b, ..., SameTest -> f]`-style overrides — Tungsten compares numerically only.
- `Mod[m, n, d]` — supported per matrix, but no other options.

### B. Number theory and integer operations

Implemented in the 2026-04-27 exact-integer pass:

- `Binomial`, `Multinomial`.
- `JacobiSymbol[n, m]`, `KroneckerSymbol[n, m]`.
- `Fibonacci[n]`, `LucasL[n]`, `BernoulliB[n]`, `EulerE[n]`, `HarmonicNumber[n]`, `HarmonicNumber[n, r]`.
- `ContinuedFraction[x]`, `ContinuedFraction[x, n]`, `FromContinuedFraction[{...}]`.
- `MultiplicativeOrder[a, n]`, `PrimitiveRoot[n]`, `CarmichaelLambda[n]`, `LiouvilleLambda[n]`,
  `JordanTotient[k, n]`, `RamanujanTau[n]`, `DivisorSigma[k, n]`, `ModularInverse[a, m]`.
- `IntegerPartitions[n]`, `IntegerPartitions[n, k]`, `IntegerPartitions[n, {k}]`,
  `IntegerPartitions[n, {kmin, kmax}]`, `PartitionsP[n]`, `PartitionsQ[n]`.
- `IntegerReverse[n]`, `IntegerReverse[n, base]`.
- `DigitCount[n]`, `DigitCount[n, base]`, `DigitCount[n, base, d]`.
- `BitNot`, `BitClear`, `BitSet`, `BitGet`, `BitLength`.
- `FactorInteger[n, GaussianIntegers -> True|False]` and `FactorInteger[n, limit]`.

**Remaining notes**

- `Prime[n]` for very large `n` still uses incremental search; this remains a performance note, not a functional gap.
- `PowerMod[a, -1, m]` remains inert when no inverse exists, which matches the observed Wolfram 14.3 result after emitting `PowerMod::ninv`.

### C. Polynomial algebra and symbolic structure

**Missing family members**

- `Numerator`, `Denominator` (also bucket A).
- `Together[expr]`, `Apart[expr]`, `Apart[expr, x]`, `Cancel[expr]` — basic rational simplification. Without these, Tungsten cannot canonicalize sums of rationals or extract partial fractions, even though the SymPy bridge exists.
- `Simplify[expr]`, `Simplify[expr, assumptions]`, `FullSimplify[expr]` — general-purpose simplification.
- `PolynomialReduce[poly, polys, vars]`, `PolynomialGCD`, `PolynomialLCM`, `PolynomialMod`, `PolynomialQuotient`, `PolynomialRemainder`. The SymPy bridge already supports most of this; thin wrappers are easy.
- `Resultant[p, q, x]`, `Discriminant[p, x]`, `Subresultants`, `GroebnerBasis[polys, vars]`. Foundational for polynomial elimination.
- `Roots[poly == 0, x]`, `Solve[eqs, vars]`, `Reduce[eqs, vars]`, `NSolve`, `FindRoot`, `RootReduce`, `ToRadicals`, `Root[f, n]`, `RootSum`. The closed-form solvers; substantial effort, but the `Solve` for polynomials in one variable is small once polynomial-roots is in.
- Calculus heads `D`, `Derivative`, `Integrate`, `Sum` (closed-form), `Product` (closed-form), `Series`, `Limit`. **All explicitly out of scope today;** call them out as long-tail items rather than near-term plans.

**Missing argument shapes**

- `Expand[expr, patt]` — pattern-restricted expansion. Matrix already calls this out.
- `Factor[poly, Modulus -> p]` — factor over `Z/pZ`. Not supported (only Gaussian rationals).
- `Factor[poly, Extension -> {Sqrt[2], …}]` — non-`I` algebraic extensions.
- `MonomialList[poly, monomialOrder]` — only lex order supported per matrix.
- `Collect[expr, var, f]` — coefficient-transforming third argument is unsupported.
- `Coefficient[expr, vars, {n1, n2, ...}]` — multi-exponent form against several variables at once.

**Missing options**

- `Factor` / `FactorList` — `Modulus`, `Trig`, `Cubics`, `Quartics`, `GaussianIntegers` (only `True`/`False` for Gaussian, no `Modulus`).
- `Expand` / `ExpandAll` — `Trig`, `Modulus`.
- `PolynomialQ[expr, Modulus -> p]`.

### D. Lists, arrays, tensors, structural

**Missing family members**

- `MinMax[list]`. Trivial but absent.
- `RankedMin[list, k]`, `RankedMax[list, k]`.
- `Quantile[list, q]`, `Quantile[list, {q1, …}]`, `Quantile[list, q, {a, b, c, d}]`. `Quartiles[list]`. `Mode[list]`.
- `BinCounts[list, spec]`, `BinLists[list, spec]`, `Histogram` (display-side; out of scope).
- `SequenceCases[list, patt]`, `SequencePosition`, `SequenceCount`, `SequenceReplace`, `SequenceSplit`, `SequenceFold` already exists. Matrix lists `SequenceReplace` / `SequenceSplit` / `Groupings` as out-of-scope.
- `Permute[list, perm]`, `PermutationCycles`, `Cycles`, `PermutationList`, `PermutationOrder`. Not implemented.
- `RotateLeft[list, {n1, n2, ...}]` per-axis rotation. Only flat 1-arg `n` form per matrix.
- `Range[]` (zero-arg, lazy infinite stream — out of scope) and `Range[Infinity, ...]` lazy forms.
- `ListConvolve`, `ListCorrelate`, `ArrayResample`, `ArrayFilter` — explicitly out of scope per matrix; numeric algorithms.
- `Numerator`/`Denominator` thread over arrays once implemented.

**Missing argument shapes**

- `Total[expr, n]`, `Total[expr, {n}]` — levelspec form **not implemented per matrix.**
- `Length[expr, levelspec]`, `Depth[expr, levelspec]` 2-arg forms. (Not all of these exist in Wolfram, but `Length` does for some heads — verify.)
- `Flatten[expr, n, h]` — 3-arg form selecting which head to flatten. Only 1- and 2-arg forms are implemented.
- `Reverse[expr, levelspec]` — supported per matrix; verify the multi-axis forms.
- `Position[expr, patt, levelspec, n, "Index"]` — only the no-property form is implemented.
- `Position[..., Heads -> True/False]` — supported on `Position` per matrix; **NOT on `Cases`, `DeleteCases`, `Count`, `MemberQ`** (matrix explicitly notes this).
- `DeleteCases[expr, patt, {0}]` — whole-expression deletion at level 0 not implemented per matrix.
- `Take[assoc, spec]` / `Drop[assoc, spec]` — only numeric / span specs work on associations; key-path specs unsupported.
- `Range[start, stop, step]` for non-integer step — supported numerically; double-check rational/real step.
- `Tuples[items, {n1, n2, …}]` — only `n` and `{ ... }` form documented; per-position widths.
- `Subsets[list, {min, max, step}]` — matrix lists `n`, `{n}`, `{min, max}`, but not the step variant.
- `Permutations[list, {min, max, step}]` similarly.
- `Tally[list, test]` — supported; `Counts[list, test]` is missing the test argument.
- `Count[expr, patt, levelspec, n]` — early-termination count argument not implemented.
- `Differences[list, n]` (n-th differences) and `Differences[list, {n1, n2}]` (multivariate differences). Only the 1-arg form is implemented per matrix.
- `Accumulate[list, f]` — function variant (using `Fold` semantics) not implemented.
- `Partition[expr, n, d, k, pad]` — supported per matrix; verify the unimplemented edge cases for negative `d` and overlap.
- `Riffle[list, x, {a, b, s}]` — span-style insertion positions; only flat scalar separator and list-of-separators are implemented.
- `Map[f, expr, levelspec, Heads -> True]` and similar option forms.
- `MapIndexed[f, expr, levelspec]` — only level 1 per matrix.
- `Apply[f, expr, levelspec]` — already supported per matrix at all levels.
- `Outer[f, list1, list2, …, n]` — levelspec form for n-deep outer products not implemented.
- `Inner[f, l, r, g, h]` — generalized 5-arg with extra reduction head; only 4-arg supported per matrix.
- `Operate[p, expr, n]` — n-deep head operation not implemented per matrix.
- `Through[expr, h]` — 2-arg form **not implemented per matrix** (only the 1-arg form).
- `Distribute[expr, g, f, gp, fp]` — 5-arg form not implemented per matrix.
- `Tr[m, f, n]` — 3-arg trace not implemented per matrix.
- `Transpose[m, perm]` — supported, but verify higher-rank arrays.

**Missing options**

- `Cases`, `DeleteCases`, `Count`, `MemberQ` — `Heads -> True/False` not honored (matrix).
- `SortBy[..., ordering]` — third-argument ordering function not honored?
- `Sort[list, p]` and `Ordering[list, n, p]` — supported per matrix.
- `DeleteDuplicates[..., test]` — supported per matrix.
- `DeleteDuplicatesBy[expr, f, test]` — custom-equality variant of the result-key compare not supported.
- `Position[..., 1]` etc. count — supported.

### E. Linear algebra

**Missing family members (largely out of scope per matrix)**

- `LinearSolve[m, b]` (with options `Method`, `Modulus`, `ZeroTest`).
- `RowReduce[m]`, `MatrixRank[m]`, `NullSpace[m]`, `RowReduce[m, Modulus -> p]`.
- `Eigenvalues[m]`, `Eigenvectors[m]`, `Eigensystem[m]`, `CharacteristicPolynomial[m, x]`.
- `SingularValueDecomposition`, `LUDecomposition`, `QRDecomposition`, `CholeskyDecomposition`, `SchurDecomposition`, `JordanDecomposition`.
- `LeastSquares[m, b]`, `PseudoInverse[m]`, `Orthogonalize[vs]`, `Projection[u, v]`.
- `KroneckerProduct[m1, m2, …]`, `TensorProduct`, `TensorContract`, `TensorTranspose`.
- `MatrixExp[m]`, `MatrixLog[m]`, `MatrixFunction[f, m]`.
- `Norm[m, p]` for matrix `p` (only vector p-norms work today).
- `Chop[expr, dx]` — drop tiny numeric residues.

**Missing argument shapes**

- `IdentityMatrix[{n, m}]` — non-square form not implemented per matrix.
- `DiagonalMatrix[list]` (1-arg) is implemented; `DiagonalMatrix[list, k, {n, m}]` non-square form similarly limited.
- `MatrixPower[m, n, v]` — apply matrix power to a vector form.

**Missing options**

- `LinearSolve` and friends — `Method`, `Modulus`, `ZeroTest`.
- `Det`, `Inverse` — `Modulus`, `Method`. Currently exact arithmetic only.

### F. Sorting, ordering, set ops

**Missing family members**

- `BinarySearch` is not in the kernel; ignore.
- `Permute[list, perm]` — apply a permutation.
- `RandomPermutation[n]` — needs the `Random*` family first.

**Missing argument shapes**

- `Sort[list, p, n]` — n-best form.
- `SortBy[expr, f, p]` — third-argument ordering function (matrix says `SortBy[expr, f, p]` is supported; double-check).
- `Union`, `Intersection`, `Complement` — `SameTest -> f` option.
- `DeleteDuplicates[list, test]` — supported per matrix.
- `OrderingBy[list, f, n, p]` — supported per matrix.

**Missing options**

- `Sort`, `Ordering`, `SortBy`, `Union`, `Intersection`, `Complement` — `SameTest -> f` option not honored.
- `Tally[list, test]` — supported per matrix; `Counts[list, test]` lacks the test arg.

### G. Statistics and random

**Missing family members (random)**

- All of `RandomInteger`, `RandomReal`, `RandomComplex`, `RandomChoice`, `RandomVariate`, `RandomPrime`, `SeedRandom`, `BlockRandom`. **High-impact gap** for any data-shaping or scripting workload.
- `Permutations`, `RandomPermutation`, `RandomSample` — `RandomSample` is implemented; the other two need the `Random*` family.

**Missing family members (statistics)**

- `Quantile`, `Quartiles`, `Mode`, `MinMax`, `RankedMin`, `RankedMax`.
- `Skewness`, `Kurtosis`, `RootMeanSquare`, `Correlation`, `Covariance`, `CovarianceMatrix`.
- `StandardDeviation` and `Variance` are implemented but only over numeric/symbolic lists.
- `Histogram`, `BinCounts`, `BinLists`, `Quartiles`.
- `WeightedData[list, weights]`. Deferred / out of scope.
- Distribution-parametric versions of `Mean`/`Median`/etc. (e.g., `Mean[NormalDistribution[…]]`) — entirely out of scope for kernel-free.

**Missing argument shapes**

- `Mean[list, w]` (weighted), `Median[list, w]`. Not implemented.
- `Total[list, levelspec]` (also bucket D).

**Missing options**

- Statistical heads: `Method`, `WorkingPrecision`, etc. — none honored.

### H. Iteration / loops / functional iteration

**Missing family members**

- `LeftComposition` — does not exist in standard Wolfram; ignore.
- `Curry[f, n]`, `RightCompose[f]`, `LeftCompose[f]`. Not standard library; ignore.
- `Function`-attribute forms with `Listable`, `HoldFirst`, etc. — implemented per matrix.

**Missing argument shapes**

- `For[init, test, incr, body]` — supported per matrix; consider documenting non-`True` test handling (currently exits on anything not literal `True`, matching kernel).
- `While[test]` 1-arg form — supported per matrix.
- `Do[expr, {n}]` etc. — supported per matrix.
- `NestWhileList[f, expr, test, m, max]` — only 3-arg form per matrix; the 4-arg history form and 5-arg max form are missing.
- `FixedPoint`, `FixedPointList` `SameTest -> f` option — not honored.
- `Sum[f, {i, 1, n}]` symbolic closed-form (e.g., `Sum[i, {i, 1, n}]` → `n(n+1)/2`) — explicitly out-of-scope per matrix.
- `Product` symbolic closed-form similarly.

**Missing options**

- `NestWhile`, `NestWhileList`, `FixedPoint`, `FixedPointList` — `SameTest`, `WorkingPrecision`, etc.

### I. Strings, text, regex

**Missing family members**

- `StringExpression` — verify whether the `~~` operator is matched at the head level. Parser supports `~~` per support docs; check the head dispatch.
- `StringDelete[s, patt]`, `StringDelete[s, {patt1, …}]` — common companion to `StringCases` / `StringReplace`. Not implemented.
- `StringExtract[s, n]`, `StringPart[s, spec]`, `StringPartition[s, spec]`. Not implemented.
- `StringTemplate[template]` and `TemplateApply[template, args]`, `StringForm[template, args…]` (display-only). Not implemented.
- `EditDistance[s, t]`, `DamerauLevenshteinDistance`, `HammingDistance`, `LongestCommonSubsequence`, `LongestCommonSubsequenceList`, `LongestCommonSubstring`, `LongestOrderedSequence`. Not implemented.
- `WordCount`, `TextWords`, `TextSentences`, `TextLines`, `LetterCounts`. Not implemented.
- `ToTitleCase[s]` (alongside `ToUpperCase`/`ToLowerCase`/`Capitalize`).
- `Hash[expr]`, `Hash[expr, "MD5"]`, `Hash[expr, "SHA"]`, `Hash[expr, type, "Format"]`.
- `Anagrams`, `LetterNumber`, `FromLetterNumber`.

**Missing argument shapes**

- `StringSplit[s, patt]` with **pattern** separators — matrix limits to literal-string separators.
- `StringTrim[s, patt]` — matrix limits to literal `"literal"` form.
- `StringReplace[s, rules, n]`, `StringCases[s, patt, n]` — supported per matrix.
- `StringPosition[s, patt, n]` — supported per matrix.
- `StringJoin[lists]` — supported per matrix; flat and nested.
- `StringInsert[s, ins, pos]` for negative or list `pos` — implemented per matrix.

**Missing options**

- `IgnoreCase`, `Overlaps`, `MetaCharacters` on every string head that accepts patterns (`StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, `StringReplace`, `StringCount`). Matrix explicitly lists these as out-of-scope.
- `StringSplit[s, patt, opts]` — same options.

### J. Pattern matching and replacement

**Missing family members**

- `ReplaceList[expr, rules]`, `ReplaceList[expr, rules, n]` — enumerate every distinct match. Not implemented; valuable for combinatorial pattern enumeration.
- `Default[h, n]`, `Default[h]` — registry for `_.` / `Optional[patt]` defaults. **Matrix calls this out** as not implemented; impacts user-defined heads with optional arguments.
- `OptionValue[opts, key]`, `OptionValue[opts, key, default]`, `OptionValue[f, opts, key]`. **Matrix calls this out.**
- `Options[f]`, `SetOptions[f, opts]`, `Options[f] = {opts}`, `FilterRules[opts, spec]`, `Lookup[opts, key]` already partly available via `Lookup`.
- `Verbatim[expr]` — explicit verbatim wrapper. Not present as a top-level head in the matrix; verify whether `MatchQ` honors it.
- `Information[sym]`, `Definition[sym]`, `?sym`, `??sym`. Symbol-introspection commands.

**Missing argument shapes**

- `Cases[expr, patt :> rhs, levelspec, n]` — supported per matrix.
- `MatchQ[patt][expr]` — operator form. Not in matrix; verify.
- `Replace[expr, rules, levelspec, Heads -> True/False]` — `Heads` option not honored.
- `ReplaceAll`/`ReplaceRepeated` operator forms `expr /. rules` and `expr //. rules` — supported.
- `Except["ab"]` — multi-character `Except` disallowed atom. Matrix says only single-character `Except` works.
- `_DigitCharacter` and other qualified-blank shorthands. Not in matrix.

**Missing options**

- `Cases`, `DeleteCases`, `Count`, `MemberQ`, `FreeQ` (some) — `Heads -> True/False` (matrix says only `Position` honors this).
- `Replace`, `ReplaceAll`, `ReplaceRepeated` — `Heads`, `Modulus` (rare).
- `OptionsPattern[f]` validating against `Options[f]` (matrix).

### K. Associations

**Missing family members**

- `JoinAcross[a1, a2, key]` — relational-style join.
- `AssociationFromMatrix`, `AssociationToMatrix`.
- `AssociationMap[f, assoc]` — mapping over an association directly. **Matrix limits to the key-list form** `AssociationMap[f, {k1, …}]`.
- `KeyValueMap[f, assoc]` — supported.
- `Counts[list, test]` — test argument missing.

**Missing argument shapes**

- `Lookup[assoc, key, default, missingFn]` — extra `missingFn` argument.
- `Merge[{a1, …}, f]` — `f` is currently restricted; check for missing forms (e.g., `f` returning failure).
- `KeyMap[f, assoc]` operator form `KeyMap[f][assoc]` — likely supported via `Operate`, but not documented as standalone.

**Missing options**

- `KeyTake`, `KeyDrop`, `KeySelect` — none documented in Wolfram, but the `Default -> ` option for `Lookup` matters for `KeyTake`-style fallbacks.
- `Lookup[assoc, key, default]` — supported; verify the list-of-keys form.

### L. Definitions and scoping

**Missing family members**

- `OptionValue`, `Options[f]`, `SetOptions` — also bucket J.
- `BeginPackage[ctx]`, `Begin[ctx]`, `End[]`, `EndPackage[]`, `Needs[ctx]`, `Get[file]`, `Put`, `Save`. Matrix lists context system as fixed; package management is parser-only inert.
- `Information[sym]`, `Definition[sym]`, `Definition[sym, ...]`. Useful for REPL introspection.
- `MessageName[sym, "tag"]` — exists at the parser level; check whether reading message templates is supported.

**Missing argument shapes**

- `OwnValues[sym] = rules` — direct assignment **not implemented per matrix.**
- `DownValues[sym] = rules` — direct assignment **not implemented** (only via `SetDelayed` / compound LHS).
- `UpValues[sym] = rules` — direct assignment **not implemented** (only via `TagSet` / `TagSetDelayed`).
- `SubValues[sym] = rules`, `NValues[sym] = rules` — same.
- `Block[$ContextPath, body]`, `Block[$Context, body]` — with `$Context` / `$ContextPath` fixed today, this is moot until the context system grows.

**Missing options**

- None standard.

### M. Mutation operators

**Missing family members**

- `AddTo` (`+=`), `SubtractFrom` (`-=`), `TimesBy` (`*=`), `DivideBy` (`/=`). **Matrix says parser-only inert.** These pair naturally with `Increment` / `Decrement` and the new `For` loop; without them, `For[i = 0, i < n, i = i + 2, ...]` and `s += t` style accumulators don't work.
- `PrependTo[sym, item]` (alongside `AppendTo`).
- `UpSet[lhs, rhs]`, `UpSetDelayed[lhs, rhs]`. **Matrix says parser-only inert.** Tagged up-values are reachable via `TagSet`/`TagSetDelayed` only; the symmetric `UpSet` operator does not store anything.

**Missing argument shapes**

- `Increment[parts[i]]`, `Decrement[parts[i]]`, `PreIncrement[parts[i]]`, `PreDecrement[parts[i]]` — compound targets. Matrix says only bare-symbol targets supported.
- `Set[m[[i, j]], v]`, `Set[assoc[k], v]` — part / association assignment. Verify whether Tungsten supports any of these (Wolfram's `m[[i]] = x` rewrites to `Part[m, i] = x` and updates the symbol holding `m`). Worth a probe and a separate row in the matrix.
- `Unset[parts[i]]` similarly.

**Missing options**

- None standard.

### N. Control flow and exceptions

**Missing family members**

- `Echo[expr]`, `EchoFunction[f, expr]`, `EchoTiming[expr]`, `EchoTiming[expr, label]`. Common debugging primitives. Not implemented.
- `Trace[expr]`, `TracePrint[expr]`, `TraceShallow[expr]`, `TraceCounts[expr]`, `Stack[]`, `StackBegin`, `StackComplete`. **Significant missing surface** for kernel-style debugging; can be partially implemented over Tungsten's evaluator hooks.
- `Pause[t]` — supported.
- `RepeatedTiming[expr]`, `RepeatedTiming[expr, n]`. Not implemented.
- `Internal\`AbortCurrentEvaluation`, `Internal\`InheritedBlock` (the latter implemented).

**Missing argument shapes**

- `Throw[value, tag, h]` — supported per matrix.
- `Catch[expr, form, f]` — supported per matrix.
- `Return[expr, head]` for `head` ∈ {`Function`, `CompoundExpression`, `Catch`, etc.}. **Currently only `Module`, `Block`, `InheritedBlock`, `Do`, `For`, `While` are wired.** Adding `Function` is plausible (kernel hangs on `Return[..., Function]` per probe — questionable contract); `CompoundExpression` is the more useful target.
- `AbortProtect[expr]` — supported.
- `TimeConstrained[expr, t, fail]` — supported.

**Missing options**

- `Pause` — none.
- `TimeConstrained` — none.

### O. Pure functions and composition

**Missing family members**

- Standard `Function`-family is fully covered per matrix. No new heads needed.
- `Curry[f, n]` — does not exist in standard Wolfram; ignore.

**Missing argument shapes**

- `Function[params, body, attrs]` — supported per matrix. Verify all attributes route correctly.
- `Apply[f, expr, levelspec]` — supported per matrix.
- `Through[expr, head]` — 2-arg form **not implemented per matrix** (only 1-arg).
- `MapApply[f, expr, levelspec]` — only 2-arg form per matrix.
- `MapIndexed[f, expr, levelspec]` — only level 1 per matrix.
- `Composition[f1, f2, …]` — supported per matrix.

**Missing options**

- None standard.

### P. Sessions, messages, hooks, introspection

**Missing family members**

- `Echo`, `EchoFunction`, `EchoEvaluation`, `EchoTiming` — bucket N also.
- `Trace` family — bucket N also.
- `Information[sym]`, `?sym`, `??sym`, `Definition[sym]`. Symbol introspection. Without these, the REPL has no equivalent of the kernel's information surface.
- `MessageName[sym, "tag"]` — accessing the message-template database. Tungsten's matrix says message texts are diagnostic strings, not Wolfram-localized templates; that's the design, but `MessageName` should still parse/render symmetrically.
- `$AssertFunction` — referenced by matrix as not implemented.
- `Beep`, `Speak`, `Pause`, `MessageDialog` — likely out of scope (FrontEnd-tied).

**Missing argument shapes**

- `Quiet[expr]`, `Quiet[expr, spec]`, `Quiet[expr, off, on]` — supported per matrix.
- `Off[sym::tag]`, `On[sym::tag]`, list and multi-argument forms — supported per matrix.
- `Print[args, options]` — Wolfram has formatting options not honored.

**Missing options**

- `Print` — `PageWidth`, `CharacterEncoding`. Ignored.
- `Check`, `Quiet` — none documented for ignore.
- `WithCleanup` — none.

### Q. Boxes, forms, and display wrappers

**Missing family members**

- FrontEnd-tied wrappers: `Row`, `Column`, `Grid`, `Style`, `Framed`, `Panel`, `Pane`, `Item`, `Magnify`, `Tooltip`, `Mouseover`, `Button`, `Manipulate`. Almost certainly out of scope.
- `BoxData`, `Cell`, `CellGroup`, `Notebook`, `NotebookGet`, `NotebookPut` — overlap with the notebook subsystem.
- `Defer[expr]` — defer evaluation in Print-style display.

**Missing argument shapes**

- `NumberForm[x, n]`, `NumberForm[x, {n, f}]` and many option forms. Matrix says "deterministic, kernel-free textual approximations for common cases; unsupported options are ignored."
- `BaseForm[x, base]` — supported; `BaseForm[x, base, opts]` ignores options.
- `TableForm[list, opts]` — `TableHeadings`, `TableSpacing`, `TableAlignments`, etc. Ignored.
- `MatrixForm[m, opts]` — same.

**Missing options**

- All output-format wrappers — `DigitBlock`, `ExponentFunction`, `NumberSeparator`, `NumberPoint`, `NumberSigns`, `SignPadding`, `NumberPadding`, etc. Currently ignored across the board.

### R. Symbol, context, and package system

**Missing family members**

- `BeginPackage`, `Begin`, `End`, `EndPackage`, `Needs`, `Get`, `Put`, `Save`, `<<`, `>>`, `>>>` — parser-only inert today.
- Dynamic context creation, user-defined contexts beyond `"Global`"` and `"System`"`.
- `Information[sym]` (also bucket P).
- `?sym`, `??sym` parser forms.

**Missing argument shapes**

- `Names[]`, `Names["pattern"]`, `Names[{"p1", …}]` — supported per matrix.
- `Context[]`, `Context[sym]` — supported per matrix.
- `$Context = "..."`, `$ContextPath = {"..."}` — direct assignment **not implemented per matrix.**

**Missing options**

- `Names[..., SpellingCorrection]`, `Names[..., IgnoreCase]` — kernel-only options that Tungsten could imitate.

### S. Sparse arrays and typed atoms

**Missing family members**

- `SparseArray[Band[{i, j}], dims]` — `Band` constructor not implemented.
- General pattern rules in `SparseArray` constructor (matrix lists this as out-of-scope).
- `SparseArray` Wolfram-internal compressed FullForm — not implemented per matrix.
- `ByteArray` and `SparseArray` are typed atoms; both are reasonably well covered.

**Missing argument shapes**

- `SparseArray[rules, dims, fill]` — supported per matrix.
- `Part[sparse, key]` association-style — n/a; sparse uses integer positions.

**Missing options**

- None.

### T. Encoding, I/O, hashing

**Missing family members**

- `Hash[expr]`, `Hash[expr, type]`. Not implemented despite being a common scripting primitive.
- File I/O: `OpenWrite`, `OpenAppend`, `Read`, `Close`, `WriteString`, `Write`, `BinaryWrite`, `BinaryRead`. Out of scope for kernel-free likely; document explicitly.
- More import/export formats: `XML`, `HTML`, `URL`, `MIME`, `Markdown`, `SExpression`, `BSON`, `MessagePack`. Matrix supports a practical subset.

**Missing argument shapes**

- `ImportString`, `ExportString`, `ImportByteArray`, `ExportByteArray` — only explicit two-argument forms with explicit format spec per matrix; no auto-detection, no element specifications.
- `BaseEncode[ba, "encoding", n]` — line-length argument.

**Missing options**

- `ImportString[..., opts]`, `ExportString[..., opts]` — every Wolfram option (e.g., JSON `"Compact"`, CSV `"FieldSeparators"`, `"TextDelimiters"`, `"IncludeHeadings"`). Currently ignored.

### U. Cross-cutting holes

These hit multiple buckets and are worth flagging once at the top of any planning doc:

1. **Options system.** `Options[f]`, `OptionValue[opts, key]`, `SetOptions[f, opts]`, `FilterRules[opts, spec]`, plus `OptionsPattern` validation against `Options[f]`. Until this lands, every option-bearing head silently drops options it doesn't natively understand. (Buckets I, J, T, Q.)
2. **`Default[h, n]` registry.** `Optional[patt]` / `_.` shorthand cannot synthesize defaults for user-defined heads; only explicit `Optional[patt, default]` works. (Bucket J.)
3. **`Heads -> True/False` option.** Honored by `Position` only. Should be honored by `Cases`, `DeleteCases`, `Count`, `MemberQ`, `Replace`, `ReplaceAll`, `Map`, `MapAll`, `Scan`. (Buckets D, J.)
4. **Compound LHS for mutations.** `Set[m[[i, j]], v]`, `Increment[parts[i]]`, `AppendTo[parts[i], x]`, `Unset[parts[i]]`. (Bucket M.)
5. **Direct value-list assignment.** `OwnValues[sym] = ...`, `DownValues[sym] = ...`, `UpValues[sym] = ...`, `SubValues[sym] = ...`, `NValues[sym] = ...`. (Bucket L.)
6. **Symbolic constants.** `Pi`, `E`, `EulerGamma`, `GoldenRatio`, `Catalan`, `Khinchin`, `Glaisher`, `Degree`. None implemented; needed before any transcendental function evaluation makes sense. (Bucket A.)
7. **Transcendental functions.** `Log`, `Exp`, `Sin`/`Cos`/`Tan`/inverse, `Sinh`/`Cosh`/`Tanh`/inverse, `Gamma`, `Beta`, etc. Big surface, but dramatically expands what Tungsten can evaluate. (Bucket A.)
8. **Random number generation.** Entire `Random*` family. High-impact for any data-shaping use case. (Bucket G.)
9. **Numerator / Denominator and rational simplification.** `Numerator`, `Denominator`, `Together`, `Apart`, `Cancel` — unblock partial fractions and rational canonicalization, both small wrappers over the SymPy bridge. (Bucket C.)
10. **Symbolic closed-form `Sum`/`Product`.** Even the simplest case `Sum[i, {i, 1, n}]` → `n(n+1)/2` is not implemented; SymPy can do this via `summation(...)`. (Bucket H.)
11. **`Echo` / `Trace` debugging primitives.** Lightweight `Echo` is small; `Trace` is bigger but has decent payoff. (Bucket N.)
12. **String-pattern arguments.** `StringSplit[s, patt]`, `StringTrim[s, patt]` — restricted to literal-string forms today. The string-pattern engine already exists; this is mostly plumbing. (Bucket I.)
13. **`IgnoreCase`/`Overlaps`/`MetaCharacters` options.** Block widely-used string-search idioms. (Bucket I.)
14. **`AddTo` / `SubtractFrom` / `TimesBy` / `DivideBy` / `PrependTo`.** Companion mutators to `AppendTo` / `Increment`. Small, high-value. (Bucket M.)
15. **`MinMax`, `Quantile`, `Quartiles`, `Mode`.** Trivial-to-medium statistics primitives. (Bucket G.)

## Merged structural work buckets

The second guide-family pass groups the remaining work slightly differently from the topic buckets
above. These work buckets are not a competing roadmap; they are a practical way to slice follow-up
implementation so each pass exercises one shared mechanism at a time.

### 1. Small structural parity holes

Patch helpers that fit existing infrastructure and do not require new symbolic math:

- `VectorQ`, `MatrixQ`, `FirstPosition`, `PositionSmallest`, `PositionLargest`
- `ContainsOnly`, `CountDistinct`, `CountsBy`, `PositionIndex`
- `PrependTo`, `DeleteElements`, `KeyFreeQ`, `KeySortBy`
- `StringPart`, `StringTakeDrop`, `StringPartition`, `StringRotateLeft`, `StringRotateRight`
- `Divisible`, `CoprimeQ`, `NumberDigit`
- `Until`

### 2. Shared option plumbing

Build a reusable option parser before widening individual heads:

- `Heads` across traversal and pattern-search functions
- `SameTest` across set, list, association, and membership families
- string options `IgnoreCase`, `MetaCharacters`, `Overlaps`, and `SpellingCorrection`
- definition ordering option `Sort`
- structural matrix options `TargetStructure`, `AllowedHeads`, `Modulus`, and `ZeroTest`

This bucket should also make unsupported options fail predictably instead of being silently ignored.

### 3. Sparse and tensor completion

Concentrate on structural tensor work before heavier matrix algorithms:

- `Band` in `SparseArray`
- richer `SparseArray` constructors and compressed-form parsing
- multidimensional `ArrayPad`, `PadLeft`, and `PadRight`
- `ArrayReduce`
- richer `Transpose`, `Tr`, `Inner`, `Outer`, and `Dot` shape handling
- `Det[mat, Modulus -> p]`, `Inverse[..., Modulus -> p]`, and integer `MatrixPower` option
  parsing where the algorithms stay exact and bounded

### 4. Sequence and subset operations

The existing pattern matcher is strong enough to justify a dedicated pass over:

- `SequenceCases`, `SequenceCount`, `SequencePosition`
- `SequenceReplace`, `SequenceSplit`
- `SubsetCases`, `SubsetCount`, `SubsetPosition`
- `SubsetMap`
- `Splice` and `UpTo` interaction with constructors and selectors

### 5. String pattern parity

Use the existing string-pattern compiler as the center:

- route `StringCount`, `StringSplit`, and `StringTrim` through the pattern compiler;
- add `StringReplaceList`, `StringReplacePart`, and `StringExtract`;
- implement common string options;
- decide whether `CharacterCounts`, `AlphabeticOrder`, and `PalindromeQ` belong in the same pass.

### 6. Exact integer and polynomial expansion

Keep this explicitly bounded:

- integer helper still remaining here: `Factorial`;
- digit helper still remaining here: `NumberDigit`;
- exact-polynomial helpers backed by SymPy: `CoefficientRules`, `PolynomialGCD`,
  `PolynomialQuotient`, `PolynomialMod`, `PolynomialReduce`, `Discriminant`, `Resultant`.

Do not let this bucket drift into solvers, broad simplification, or broad symbolic algebra.

### 7. Options and defaults registry

This is cross-cutting and should happen after the smaller structural work has stabilized:

- `Options`
- `OptionValue`
- validated `OptionsPattern`
- `Default`
- message-template values through `MessageName`

This unlocks many shapes, but it also changes evaluator semantics in more places than any single
list/tensor helper.

## Suggested prioritization

This is opinion, not a roadmap. The first pass picks small, high-leverage items that unblock common scripting patterns:

| Tier | Work | Why |
|------|------|-----|
| 1 | `Numerator`, `Denominator`, `Together`, `Apart`, `Cancel` | Wraps SymPy bridge; unblocks rational simplification. |
| 1 | `AddTo`, `SubtractFrom`, `TimesBy`, `DivideBy`, `PrependTo` | Companions to existing `Increment`/`AppendTo`; tiny. |
| 1 | `MinMax`, `Quantile`, `Quartiles`, `Mode` | One-line statistics that data-wrangling code expects. |
| 1 | Compound LHS for `Set` / `Increment` (`m[[i, j]] = v`, `Increment[parts[i]]`) | Removes an awkward limitation in the recently-landed mutation surface. |
| 2 | Random number generation (`RandomInteger`, `RandomReal`, `RandomChoice`, `RandomSample` already in, `SeedRandom`) | Scripting / sampling workloads. |
| 2 | Symbolic constants (`Pi`, `E`, `EulerGamma`, `Degree`) + `N[...]` rules | Required scaffold for transcendentals; small surface. |
| 2 | `Log`, `Exp`, `Sin`/`Cos`/`Tan`, `Sinh`/`Cosh`/`Tanh`, plus `ArcSin`/`ArcTan` family | Restricted to numeric and known-exact symbolic cases (SymPy bridge for the latter). |
| 2 | Options system: `Options[f]`, `OptionValue`, `SetOptions`, `FilterRules` + `OptionsPattern` validation | Cross-cutting unblocker; many heads silently drop options today. |
| 2 | `Default[h, n]` registry | Unlocks `_.` shorthand for user heads. |
| 2 | `Heads -> True/False` on `Cases`, `DeleteCases`, `Count`, `MemberQ`, `Map`, `Scan`, `Replace*` | Closes a documented gap in pattern traversal. |
| 3 | `Echo`, `EchoFunction`, `EchoTiming` | Lightweight debugging surface. |
| 3 | `Information[sym]`, `Definition[sym]`, `?sym`, `??sym` | REPL introspection. |
| 3 | Symbolic closed-form `Sum`/`Product` for the common patterns | SymPy bridge already in. |
| 3 | `MapIndexed` levelspec, `Through` 2-arg, `Distribute` 5-arg, `Operate` n-arg | Round out partial implementations. |
| 3 | `Total[expr, levelspec]`, `Reverse[expr, levelspec]` (already in matrix), `Flatten[expr, n, h]` | Round out structural ops. |
| 4 | `ReplaceList[expr, rules]`, `ReplaceList[expr, rules, n]` | Combinatorial pattern enumeration. |
| 4 | `Trace`, `TracePrint`, `Stack` | Heavier debugging primitives. |
| 5 | Linear algebra: `LinearSolve`, `RowReduce`, `MatrixRank`, `NullSpace` | Out-of-scope per matrix; revisit when polynomial-algebra coverage is solid. |
| 5 | `Solve`, `Reduce`, `D`, `Integrate`, `Limit`, `Series`, `Simplify` | Out-of-scope today; would need a full computer-algebra layer. |

## Validation plan for implementation passes

Each implementation bucket should add tests in three layers:

- direct Wolfram-compatible examples for each new function or new argument shape;
- cross-head consistency tests, especially for `Heads`, `SameTest`, sparse array behavior, and
  association value-vs-key traversal;
- kernel parity spot checks for ambiguous behavior when the local Wolfram installation is
  available.

Sparse-aware functions should always include:

- dense/sparse result equivalence for small explicit arrays;
- implicit value behavior;
- shape preservation after slicing, padding, transposition, dot products, and normalization;
- tests that avoid forcing dense materialization unless the function is explicitly dense, such as
  `Normal`.

For option work, tests should cover:

- accepted and honored options;
- unsupported options rejected with a Tungsten diagnostic;
- option order and duplicate-option behavior if Tungsten decides to match Wolfram's last-option
  convention.

## Notes

- "Out of scope today" items are deliberately listed even when the matrix excludes them, so a reader scanning this report once sees the full long-tail picture without having to cross-reference. That's the *only* purpose; please do not treat their listing here as a re-scoping signal.
- Several entries are flagged "verify" — the matrix and the dispatch table sometimes disagree at the edges (e.g., operator forms, `Heads` option). Each "verify" item is small enough to confirm with a one-line `evaluate(parse_expression(...))` smoke check before opening a PR.
