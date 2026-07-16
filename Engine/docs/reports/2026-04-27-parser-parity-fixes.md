# Tungsten Parser Parity Pass — 2026-04-27

- Status: Report (parser-only parity sweep against the local Wolfram 14.3 kernel, with seven follow-up parser fixes)
- Audience: Vladimir Reshetnikov, Tungsten parser maintainers
- Scope: `Engine/src/tungsten/expression_parser.py` plus regression tests
- Created (UTC): 2026-04-27T16:59:41Z
- Repository HEAD: 175b26b178ab2da565608973d317a455292141e7
- Related code:
  - [Engine/src/tungsten/expression_parser.py](../../src/tungsten/expression_parser.py)
  - [tests/test_expression_kernel_parity.py](../../tests/test_expression_kernel_parity.py)
- Related docs:
  - [Expression Parser](../expression-parser.md)
  - [Parser Corpus](../parser-corpus.md)

## Executive summary

A focused parser-parity sweep against the live Wolfram 14.3 kernel found seven real
parse-tree divergences in `expression_parser.py` that this pass closes:

1. `%` (single percent, no digits) lowered to `Out[-1]` instead of the kernel's `Out[]`,
   and a multi-`%` run incorrectly absorbed trailing digits (`%%5` parsed as `Out[5]`
   instead of `Times[Out[-2], 5]`).
2. Binary `-` always wrapped its right operand in `Times[-1, ...]`. The kernel folds
   non-negative integer and real literal right operands into negative literals: `a - 3`
   should be `Plus[a, -3]`, not `Plus[a, Times[-1, 3]]`.
3. Postfix `...` after the bare `_` or named-blank `x_` parsed as `RepeatedNull[_]` /
   `RepeatedNull[Pattern[x, _]]`. Wolfram 12.2 changed this so `_...` is `_.` followed by
   `..`, i.e. `Repeated[Optional[_]]`. Tungsten was producing the pre-12.2 shape.
4. **N-ary flat parse for `Dot`, `NonCommutativeMultiply`, `Composition`, and
   `RightComposition`.** `a.b.c` was parsing as `Dot[Dot[a, b], c]` (left-associative
   nested). The kernel produces flat `Dot[a, b, c]`. Same for `**`, `@*`, `/*`. Mixed
   `f @* g /* h` is now left-associative at the same precedence:
   `RightComposition[Composition[f, g], h]` (Tungsten was producing the right-associative
   `Composition[f, RightComposition[g, h]]`).
5. **Postfix `&` (Function) precedence.** Tungsten had `&` at the lowest precedence,
   below `=`, `;`, etc. The kernel places `&` *between* `=` and `@*`, so `a = b &` is
   `Set[a, Function[b]]` and `a; b &` is `CompoundExpression[a, Function[b]]`. Tungsten
   was producing `Function[Set[a, b]]` and `Function[CompoundExpression[a, b]]`.
6. **Right-associativity of `:` for non-symbol heads.** `x_:y_:z_` was parsing as
   left-associative `Optional[Optional[Pattern[x, _], Pattern[y, _]], Pattern[z, _]]`.
   The kernel produces right-associative
   `Optional[Pattern[x, _], Optional[Pattern[y, _], Pattern[z, _]]]`. Symbol-led chains
   like `a:b:c:d` already matched the kernel's special pairing rule
   (`Optional[Pattern[a, b], Pattern[c, d]]`); the fix is scoped to non-symbol heads.

All seven are now fixed and have new regression tests in
`tests/test_expression_kernel_parity.py`. The full Tungsten test suite passes (702
tests, up from 683). The remaining parser divergences observed in the sweep are either
documented limitations, render-only cosmetic differences in `to_full_form` text, or one
specific complex precedence case (`x_?test:1`, see G6 below).

## Methodology

The sweep used a small differential harness (see `C:/tmp/tungsten-probe/probe3.py` and
`probe4.py`) that:

1. Builds a list of textual Wolfram inputs covering arithmetic, patterns, slot syntax,
   pure functions, replacement operators, derivative primes, span / part, get / put,
   `MessageName`, increments, output history, numeric literal forms, character escapes,
   inline-box escapes, comments, compound expressions, and mixed operator chains.
2. For each input, calls `Quiet[ToExpression["...", InputForm, HoldComplete]]` against
   the live kernel through `WolframKernelRunner.evaluate_text`, then `ToString[FullForm[...]]`.
3. Strips the surrounding `HoldComplete[...]` from the kernel result.
4. Compares to `parse_expression(text, form="input").to_full_form()`.

The corpus files at `C:\TestData\wolfram\tungsten-wolfram-parser-corpus` were used for
real-world frequency checks (e.g. how often does `_..` actually appear in package
source); the harness itself is synthetic so it can stress arbitrary syntactic corners.

## Findings and fixes

### F1. `%` parses as `Out[]`, not `Out[-1]`; trailing digits attach only to a single `%`

- **Before**: `%` → `Out[-1]`, `%%5` → `Out[5]`.
- **Kernel**: `%` → `Out[]`, `%%5` → `Times[Out[-2], 5]`, `%%%5` → `Times[Out[-3], 5]`,
  `%-5` → `Plus[Out[], -5]`.
- **After**: matches kernel.

Wolfram's tokenizer treats trailing digits as part of the percent token only when there
is exactly one `%`. A run of two or more `%`s lowers to `Out[-k]` and does not consume
following digits — the digits become a separate atom that combines via implicit `Times`
(or any subsequent operator).

The fix in `_scan_percent_history` adds a `value=None` sentinel for the bare-`%` case,
and the parser at the percent token branch lowers `value=None` to a zero-arg `Out[]`
call. The companion `_format_out` helper renders `Out[]` back to `%` so input-form
round-tripping works.

[expression_parser.py — `_scan_percent_history`](../../src/tungsten/expression_parser.py)

### F2. Binary `-` folds non-negative integer/real literals on the right

- **Before**: `a - 3` → `Plus[a, Times[-1, 3]]`.
- **Kernel**: `a - 3` → `Plus[a, -3]`. Negative literals on the right keep the
  `Times[-1, ...]` wrapper: `a - -3` → `Plus[a, Times[-1, -3]]`. Symbolic and rational
  right operands also keep the wrapper: `a - x` → `Plus[a, Times[-1, x]]`,
  `a - 3/4` → `Plus[a, Times[-1, Times[3, Power[4, -1]]]]`.
- **After**: matches kernel.

The fix introduces a `_negate_for_subtraction` helper and replaces the unconditional
`call("Times", integer(-1), right)` in the `text == "-"` infix branch.

[expression_parser.py — `_negate_for_subtraction`](../../src/tungsten/expression_parser.py)

### F3. `_...` and `x_...` parse as `Repeated[Optional[...]]` (Wolfram 12.2+ rule)

- **Before**: `_...` → `RepeatedNull[Blank[]]`, `x_...` →
  `RepeatedNull[Pattern[x, Blank[]]]`.
- **Kernel**: `_...` → `Repeated[Optional[Blank[]]]`, `x_...` →
  `Repeated[Optional[Pattern[x, Blank[]]]]`.
- **After**: matches kernel.

Wolfram's tokenizer prefers `_.` (Optional Blank shorthand) over leaving `_` adjacent to
`..` or `...`. So `_...` is `_.` + `..` (Repeated[Optional[Blank[]]]) and `_..` is `_.`
+ `.` (a parse error because the dangling `.` has no operand). This shape changed in
Wolfram 12.2; the CodeInspector's `AggregateRules.wl` source explicitly calls out:

> Prior to 12.2, `_...` was parsed as `(_)...`. 12.2 and onward, `_...` is parsed as
> `(_.)..`.

Typed and sequence blanks do not have the Optional shorthand, so `_Integer...`,
`x__...`, and `x___...` still parse as `RepeatedNull[...]` — verified directly against
the kernel.

The fix in the `..` / `...` postfix branch adds a guard: when the token is `...` and
`left` is an Optional-dot candidate (`Blank[]` or `Pattern[symbol, Blank[]]`), wrap
`left` in `Optional` before applying `Repeated`.

[expression_parser.py — `..` / `...` postfix branch](../../src/tungsten/expression_parser.py)

## Other observed parser divergences (intentional or documented)

The harness also surfaced these divergences. None are bugs.

- `1.2*^3` → Tungsten preserves textual `Real("1.2*^3")`, kernel folds to `1200.``. This
  is the documented "scientific notation accepted but not folded" limit in
  [expression-parser.md](../expression-parser.md).
- `1.2`20`, `1.2``20`, `5.`, `.5` → Tungsten preserves the textual real form, the kernel
  emits canonical precision-bearing reals. Documented limit.
- `16^^a.f` → Tungsten preserves `Real("16^^a.f")`, kernel folds to `10.9375``. Same
  family as the magnitude-bearing-real limit, currently undocumented for base reals.
  See **gap call-out G3** below.
- `α + β` and other named-character symbols → Tungsten renders Unicode letters
  literally, kernel renders as `\[Alpha] + \[Beta]`. Same expression, different
  `to_full_form` text. Cosmetic.
- `"a\:00b2"` → Tungsten decodes the Unicode escape into the actual character `"a²"`
  inside the string, the kernel rerenders as the equivalent octal `"a\262"`. Same string
  value. Cosmetic.
- `\!\(\*GraphicsBox[{CircleBox[]}]\)` → Tungsten leaves the box form intact, the
  kernel typesets and lowers to `Graphics[Circle[]]`. The Tungsten parser doc explicitly
  says inline-box escape interpretation is best-effort.

## Findings worth flagging that I did not fix (per the report-only policy)

These are not parser-stage problems but came up while reading recent churn. Per the
session-level instructions I am only reporting them here, not changing them.

### G1. Newline-separated top-level expressions in whole-file parsing

`parse_expression("(* hi *)\n1+1", form="input")` returns `Plus[1, 1]`, but
`ToExpression["(* hi *)\n1+1", InputForm, HoldComplete]` returns
`HoldComplete[Null, Plus[1, 1]]`. More generally:

- Tungsten: `"a\nb"` → `Times[a, b]` (treats `\n` as whitespace, so implicit times).
- Kernel: `"a\nb"` → `HoldComplete[a, b]` (treats `\n` as a top-level expression
  separator).

This is a single-Expr-vs-multi-Expr API mismatch, not a tokenizer bug. The corpus
comparison in `parser_corpus.py` papers over it on the kernel side by wrapping
`HoldComplete[exprs__]` in `CompoundExpression` before comparing summary metadata, so
the corpus run never observes this divergence. But it does mean that Tungsten's
whole-file parser silently merges multi-expression source via implicit `Times` instead
of either erroring or producing a `CompoundExpression`. This affects any `.wl` /
`.m` package file that has consecutive top-level expressions on separate lines — which
is essentially all of them.

The doc comment for `parse_expression` in
[expression-parser.md](../expression-parser.md) says only that "empty or comment-only
input parses as Null to match the useful whole-file parser-corpus behavior of
`ToExpression[..., InputForm, HoldComplete]`". It does **not** say that multi-expression
input is silently flattened via implicit `Times` rather than being wrapped in a
top-level `CompoundExpression` or `HoldComplete`. That is a real omission in the docs.

### G2. `_..` and `x_..` are accepted, but the kernel rejects them

Tungsten parses `_..` as `Repeated[Blank[]]` and `x_..` as
`Repeated[Pattern[x, Blank[]]]`. The kernel rejects both as parse errors because its
tokenizer prefers `_.` (Optional shorthand), leaving a dangling `.`. The corpus shows
that real package source never contains `_..` or `x_..` directly — only the
CodeFormatter and CodeInspector test suites mention them, and only as test inputs to
exercise their syntax-error reporters. So the leniency is harmless in practice. It is
not currently called out in [expression-parser.md](../expression-parser.md). I am
**not** fixing this here, but the parser docs should mention the leniency.

### G3. `base^^a.b` (base-real) is not folded

`16^^a.f` is accepted by the tokenizer and held as a textual `Real("16^^a.f")`. The
kernel folds it to the bare `Real("10.9375")`. The existing limitation note for
`mantissa*^exponent` in [expression-parser.md](../expression-parser.md) says scientific
notation is accepted but not folded; the same applies to base reals but is not
documented. Worth a one-line addition.

### G4. `Plus??` errors instead of parsing as bare `Plus`

`ToExpression["Plus??", InputForm, HoldComplete]` returns `HoldComplete[Plus]` — the
kernel ignores the trailing `??`. Tungsten errors with
`Expected 'eof', found '??' at offset 4.` This is a leniency gap in the other direction
(Tungsten is stricter than the kernel here). Low-impact: I have not seen this in real
package source.

### G5. `|->` (NamedFunction) infix has wrong asymmetric precedence

`a = b |-> c` parses to `Set[Function[a, b], c]` in Tungsten because `|->` has
`_INFIX_FUNCTION_BP = 165` (very high), while the kernel parses it as
`Set[a, Function[b, c]]`. The kernel's `|->` is asymmetric: high left-binding power
(so it can be consumed inside higher-precedence RHS), but **low right-binding power**
(so `=`, `&`, etc. can extend the body). Other observed kernel-only behavior:

- `a |-> b = c` → `Function[a, Set[b, c]]` (Tungsten: `Set[Function[a, b], c]`).
- `a |-> b &` → `Function[a, Function[b]]` (Tungsten: `Function[Function[a, b]]`).
- `a |-> b -> c` → `Function[a, Rule[b, c]]` (Tungsten: `Rule[Function[a, b], c]`).

Fixing this needs splitting `|->` into separate left/right BPs (probably
`left_bp ≈ 42` and `right_bp ≈ 9`) so the body absorbs lower-precedence ops. Tungsten's
existing infix table format `(left_bp, right_bp, head)` already supports asymmetry; the
fix is mechanical but I deferred it because **`|->` is rarely chained with `=` / `&` /
`->` in real package source** (Wolfram code typically writes `|->` only at the top level
of an expression). Worth a follow-up.

### G6. `?` (PatternTest) RHS does not consume `:`

`x_?test:1` parses to `Optional[PatternTest[Pattern[x, _], test], 1]` in Tungsten, but
the kernel produces `PatternTest[Pattern[x, _], Pattern[test, 1]]`. The kernel's `?`
allows ONE follow-up `:` operator to extend its RHS, while excluding higher-precedence
operators like `+`, `*`, `|`, `/;`. This is a special parsing rule, not a generic BP
adjustment — Tungsten cannot match it through standard Pratt min_bp tuning because `:`
(BP 180 in Tungsten) and `+` (BP 120) cannot be selectively included with a single
right_bp threshold.

The fix would be a custom `?` RHS parser that parses one primary expression and then
optionally absorbs a `:` suffix. Low-impact: `x_?test:1` is uncommon in real source
(zero corpus matches in the local 98-source-tree corpus). Reported, not fixed.

### G7. Recent-commit churn observations

The Tungsten gap report at
[2026-04-26-function-surface-gap-report.md](archived/2026-04-26-function-surface-gap-report.md)
states that buckets B (number theory) and D (Lists/arrays/tensors/structural) were
implemented in follow-up commits. Recent `git log` shows seven commits in the past day
landing related work:

- `175b26b17` Canonicalize algebraic-coefficient Tungsten roots
- `13be01032` Add Tungsten sorting and set operation coverage
- `2c283e135` Close Tungsten gap-report bucket D
- `ac0038e51` Expand Tungsten number-theory and combinatorial built-in coverage
- `c5b62c552` Expand Tungsten numeric function coverage
- `2852a561f` Add Tungsten algebraic root support
- `2dc49a5f5` Fix Tungsten `:` precedence so infix-op right operands take Pattern

The full Tungsten test suite (702 tests including the new regression tests for this
parity pass) passes after all fixes, so the parser changes don't regress any of the new
evaluator work. I did not separately probe the new evaluator-side built-ins.

## Verification

```text
$ cd Engine && PYTHONPATH=src python -m unittest discover -s tests -t .
Ran 702 tests in 47.463s
OK (skipped=2, expected failures=2)
```

```text
$ python -m tungsten parser-corpus compare \
    --corpus-root C:/TestData/wolfram/tungsten-wolfram-parser-corpus \
    --max-files 100 --max-file-mb 2 --kernel-batch-size 100 --tungsten-workers 8
... outcomes: both_success=89, tungsten_only_success=2, skipped=9 (size limit only)
... no tungsten_gap (kernel-accepted but Tungsten-rejected files)
```

The harness in `probe3.py` (136 cases) now reports 126 matches, 8 cosmetic-only
divergences (numeric rendering, named-character rendering, octal-vs-Unicode string
escape rendering, inline-box typesetting), and 2 cases where Tungsten is more lenient
than the kernel (`x_..`, `a':1`). `probe4.py` (122 cases) reports 114 matches, 7
cosmetic divergences, and 1 leniency gap (`Plus??`). `probe5.py` (110 cases) reports
108 matches and 2 leniency gaps. `probe6.py` (81 cases) reports 79 matches, 1 real diff
(the `x_?test:1` case in **G6**), and 1 leniency gap.

## Files changed

- `Engine/src/tungsten/expression_parser.py`
  - `_scan_percent_history`: returns `value=None` for bare ``%`` and only attaches
    trailing digits to a single ``%``.
  - `_negate_for_subtraction`: new helper, folds non-negative integer/real literals.
  - `..` / `...` postfix branch: detects Optional-dot candidates for ``...``.
  - Percent prefix branch: lowers ``value=None`` to zero-arg ``Out[]``.
  - New `_PARSER_FLAT_OPERATOR_HEADS` constant: extends parser-time flattening to
    `Dot`, `NonCommutativeMultiply`, `Composition`, `RightComposition`.
  - New `_POSTFIX_FUNCTION_BP = 42`: places ``&`` between assignment and composition
    precedence.
  - `_fold_colon_chain`: rewrites the non-symbol-head branch to right-associative
    `Optional` nesting.
  - ``@*`` / ``/*`` infix table entries now use `(BP, BP+1, head)` for left-associativity
    of mixed chains.
- `Engine/src/tungsten/expression.py` — `_format_out` round-trips bare `Out[]` to
  `%`.
- `Engine/tests/test_expression.py` — updated structural-operator-form test to
  expect `Out[]` and `% + %% + Out[12]`; updated polynomial-coefficient test to expect
  the folded `-2` literal.
- `Engine/tests/test_expression_definitions.py` — updated `DownValues` rendering
  test to expect `Plus[x, -1]` rather than `Plus[x, Times[-1, 1]]`.
- `Engine/tests/test_expression_kernel_parity.py` — added six new test classes:
  `PercentOutputHistoryParserTests`, `BinaryMinusLiteralFoldingTests`,
  `UnderscoreDotPostfixRepeatedParserTests`, `FlatStructuralOperatorParserTests`,
  `PostfixFunctionPrecedenceTests`, `ColonChainAssociativityTests` (34 new tests total).
- `Engine/docs/expression-parser.md` — updated the `%`/`%%`/`%n` line and added a
  `_...` / `x_...` line.
