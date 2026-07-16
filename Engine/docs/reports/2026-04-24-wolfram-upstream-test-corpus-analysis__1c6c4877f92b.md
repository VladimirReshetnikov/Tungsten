# Tungsten Wolfram Upstream Test Corpus Analysis

- Status: Report (analysis of the downloaded upstream Wolfram-language corpus for Tungsten parser/evaluator test adaptation)
- Audience: Vladimir Reshetnikov, Tungsten maintainers, future expression-subsystem contributors
- Scope: `Engine` expression parsing/evaluation work, plus the local corpus under `C:\TestData\wolfram\tungsten-wolfram-upstream-tests`
- Created (UTC): 2026-04-24T18:06:25Z
- Repository HEAD: cf5b9a9f8ec5b6e93a9c8c064e1e994e1adface0
- Inputs:
  - Corpus root: `C:\TestData\wolfram\tungsten-wolfram-upstream-tests`
  - Corpus manifest: `C:\TestData\wolfram\tungsten-wolfram-upstream-tests\manifest.json`
  - Analyzer script: `Engine/scripts/analyze_upstream_wolfram_tests.py`
  - Analyzer output: `C:\TestData\wolfram\tungsten-wolfram-upstream-tests\analysis.json`

## Executive summary

The corpus is worth keeping and mining. It is not one monolithic "test suite" so much as a
collection of complementary upstream assets:

- parser goldens and box-language cases;
- lexer/operator/named-character tables;
- small, portable subset evaluators with direct expected results;
- large mixed suites that contain both valuable structural tests and a lot of math that Tungsten
  explicitly does not intend to implement.

The best parser sources are `wolfram-codeparser`, `mathics3-scanner`, `mathics-core`'s parser
tests, Symja's parser tests and parser data tables, and `mmaclone`'s parser subset. The best
evaluator sources for Tungsten's intended direction are `mmaclone`, selected `woxi` suites,
selected `mathics-core` suites, selected `expreduce` suites, and carefully filtered parts of
Symja.

The single most important strategic constraint is licensing. MIT/BSD-licensed sources are the best
targets for direct vendoring or near-literal translation. GPL/AGPL sources are still excellent
reference corpora, but they should be treated as local mining inputs or as inspiration for new
Tungsten-authored tests, not copied blindly into the repository.

## Corpus overview

The current snapshot contains 8 upstream sources and 1,287 downloaded files. The corpus is broad
enough to cover almost every part of the long-term parser goal and a large fraction of the intended
evaluator surface, but only after filtering.

| Source | License | Best use for Tungsten | Notes |
| --- | --- | --- | --- |
| `WolframResearch/codeparser` | MIT | Highest-value parser goldens, especially box forms and concrete syntax | Best direct source for eventual "parse all syntax including built-in box forms". |
| `Mathics3/Mathics3-scanner` | GPLv3 | Tokenizer, operator precedence, named characters, escape handling | Better as a reference corpus or generator input than as copied tests. |
| `Mathics3/mathics-core` | GPLv3 | Parser subset, box parser subset, procedural control flow, associations, patterns, selected number theory | Large and useful, but mixed heavily with out-of-scope symbolic math. |
| `corywalker/expreduce` | MIT | Operator/precedence tests plus functional, control-flow, list, and basic number-theory cases | Good direct adaptation candidate after aggressive filtering. |
| `axkr/symja_android_library` | GPLv3 | Parser coverage, operator tables, named characters, associations, sparse arrays, pattern matching | Especially useful as a catalog of cases and tables. |
| `ad-si/Woxi` | AGPLv3 | Control flow, associations, syntax, CLI-style expected outputs, large number-theory corpus | Good reference corpus; number-theory coverage exceeds current intended scope. |
| `jyh1/mmaclone` | BSD 3-Clause-style | Smallest and cleanest parser/evaluator subset for direct adaptation | Probably the best first-wave evaluator source. |
| `davidsd/howl` | Modified BSD | Secondary parser/evaluator subset, round-trip/property inspiration | Lower priority than `mmaclone`, still useful for supplemental cases. |

## Method

I used two passes:

1. Manual inspection of representative high-value files in each repository.
2. A heuristic scan over the full local corpus using `Engine/scripts/analyze_upstream_wolfram_tests.py`.

The analyzer is intentionally approximate. It is good at ranking repositories and surfacing likely
candidate files, but it still overcounts some utility files and cannot replace human filtering.
The recommendations below are therefore based on the analyzer plus direct file inspection.

## Parser findings

### Best direct parser corpus

`wolfram-codeparser` is the strongest single source for Tungsten's long-term parser goal.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\wolfram-codeparser\Tests\Parse.mt` is a pure parser
golden corpus over raw WL source strings and expected parse-equivalence behavior.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\wolfram-codeparser\Tests\Boxes.mt` is the most useful
box-language source in the whole corpus. It covers `RowBox`, `TagBox`, `InterpretationBox`,
integral forms, `DifferentialD`, `SubsuperscriptBox`, and contour-integral variants. This is
precisely the kind of corpus Tungsten will need when it moves from today's semantic-box subset to
"all built-in box forms".

Recommended use:

- adapt selected cases as parse-acceptance and canonical-AST tests;
- keep the current CodeParser-specific expected CST/AST nodes as reference data during translation;
- prioritize box cases that extend Tungsten beyond the already supported `FractionBox`,
  `SqrtBox`, `RadicalBox`, and `SuperscriptBox` subset.

### Best operator / tokenizer / named-character sources

`mathics3-scanner` and Symja's parser data files are the best sources for parser tables rather than
for literal test copying.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics3-scanner\test\test_tokeniser.py` contains
useful token-level cases for escaped named characters, row-box escapes, comments, and operator
tokenization.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics3-scanner\test\test_mathics_precedence.py`
documents precedence ordering mismatches between Wolfram's reported precedence values and actual
parsing behavior. That is especially relevant for Tungsten's Pratt parser as the operator surface
grows.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-parser\src\test\resources\data\operators.yml`
is a high-value data source for operator precedence, associativity, boxing operators, and FullForm
names.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-parser\src\test\resources\data\named-characters.yml`
is a large catalog of WL named characters and operator-name associations, including entries for
`Rule`, `RuleDelayed`, `ReplaceAll`, `ReplaceRepeated`, `Span`, `Function`,
`LeftAssociation` / `RightAssociation`, `RightComposition`, `SameQ`, `UnsameQ`, and
`StringJoin`.

Recommended use:

- generate Tungsten parser/operator/named-character fixtures from these tables;
- keep those generated fixtures separate from hand-authored semantic parser tests;
- use the tables to drive completeness checks rather than one-off unit tests.

### Best subset parser suites for direct translation

`mmaclone` and `mathics-core` provide the most directly portable textual parser cases for Tungsten.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mmaclone\mmaclone\test\Parser\NewParseSpec.hs`
covers exactly the kinds of forms Tungsten already cares about and plans to expand:

- part syntax;
- `@`, `//`, `/@`, `@@`;
- derivatives;
- `/.`;
- `&`, `#`, `##`, `%`;
- compound expressions;
- `/;`;
- pattern alternatives.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\core\parser\test_parser.py`
contains good precedence and associativity cases, message names, slots, patterns, comments, and
named characters.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\core\parser\test_box_parser.py`
contains useful escaped-box parsing cases and box operators such as `SuperscriptBox`,
`SubscriptBox`, and `FractionBox`.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-parser\src\test\java\org\matheclipse\parser\test\ParserTestCase.java`
and `...WMAParserTestCase.java` add more coverage for:

- `Part` and `Span`;
- out-history syntax like `%` / `%%%`;
- named characters;
- `Function` / `Slot`;
- compound expressions;
- derivative syntax;
- mixed precedence edge cases.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\woxi\tests\parser_tests.rs` is also useful, but in a
different way: it is mainly a parse-acceptance smoke suite rather than a detailed AST-golden
corpus. Likewise, `C:\TestData\wolfram\tungsten-wolfram-upstream-tests\woxi\all_mathics_tests.txt` looks
better suited to a later bulk parse-smoke or fuzz-style harness than to first-wave unit tests.

### Parser extraction recommendation

First parser wave:

- `wolfram-codeparser/Tests/Parse.mt`
- `wolfram-codeparser/Tests/Boxes.mt`
- `mathics3-scanner/test/test_tokeniser.py`
- `mathics3-scanner/test/test_mathics_precedence.py`
- `mathics-core/test/core/parser/test_parser.py`
- `mathics-core/test/core/parser/test_box_parser.py`
- `mmaclone/mmaclone/test/Parser/NewParseSpec.hs`
- Symja `ParserTestCase.java`, `WMAParserTestCase.java`, `operators.yml`, and `named-characters.yml`

These cover the largest amount of parser surface with the least ambiguity about why each case is
valuable.

## Evaluator findings

### Best first-wave evaluator source

`mmaclone` is the best starting point for Tungsten evaluator adaptation, despite its small size.
The reason is not raw coverage; it is fit.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mmaclone\mmaclone\test\Eval\EvalSpec.hs`
contains compact, direct expected-result cases for:

- `Map` and `Apply`;
- `If`;
- `Replace`, `ReplaceAll`, and `ReplaceRepeated`;
- `Nest` and `NestList`;
- pure functions and slots;
- list/part/length style structural behavior.

This suite is close to Tungsten's intended evaluator direction and contains much less irrelevant
math than the larger systems.

### Best control-flow and scoping source

`woxi` is the strongest source for explicit control-flow constructs.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\woxi\tests\interpreter_tests\control_flow.rs`
contains direct result cases for:

- `For`;
- `While`;
- `Break[]`;
- `Continue[]`;
- `Return[]`;
- `Block`;
- `Module`;
- compound assignment and loop-local state.

These are especially valuable because Tungsten intends to support real scoping and control-flow
constructs, and this file already expresses the expected observable behavior in a concise form.

### Best association / structural collection sources

There are three particularly strong sources here.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\builtin\list\test_association.py`
has many structural association cases, including malformed inputs, `Keys`, `Values`, `Map` over
associations, nested associations, and key lookup behavior.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\woxi\tests\interpreter_tests\association.rs`
is smaller and cleaner, with very direct cases for `Keys`, `Values`, `KeyExistsQ`, `KeyDropFrom`,
association part extraction, updates, nested lookup, and `AssociationThread`.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-core\src\test\java\org\matheclipse\core\system\AssociationTest.java`
is broad and valuable for later waves:

- association normalization and duplicate-key overwrite behavior;
- association indexing by string and `Key[...]`;
- `Map`, `Normal`, `Depth`, `Level`, and `AssociationMap`;
- `For` loops writing into associations;
- mixed structural edge cases.

### Best pattern / replacement sources

`mathics-core` and Symja are both useful here.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\builtin\test_patterns.py`
and `...test\builtin\test_rules.py` are good sources for filtered structural matching and rewrite
behavior.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-core\src\test\java\org\matheclipse\core\system\PatternMatchingTestCase.java`
contains cases that combine pattern conditions with `Block`, `Module`, and `With`, which makes it
especially relevant to Tungsten's intended interaction between matching and control/scoping.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\expreduce\expreduce\interp_test.go` is also very
good for parser-lowered replacement/operator precedence cases such as:

- `/.` and `//.`;
- `/;`;
- `a::b`;
- `<>`;
- postfix / prefix combinations;
- pure-function syntax and pattern tests.

### Best functional / iterative sources

`expreduce` and `mathics-core` are strongest here.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\expreduce\expreduce\resources\functional.m`
contains compact expected-result examples for:

- `Function` and `Slot`;
- `Apply`;
- `Map`;
- `MapIndexed`;
- `Fold` and `FoldList`;
- `Nest`, `NestList`, `NestWhile`, `NestWhileList`;
- `FixedPoint` and `FixedPointList`;
- `Array`.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\builtin\test_procedural.py`
adds useful control-flow and compound-expression behavior, including `Do`, `For`, `While`,
`Switch`, `CompoundExpression`, and history-sensitive semicolon behavior.

### Best array / sparse-array sources

Symja is the best array/sparse-array source in the current corpus.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\symja_android_library\symja_android_library\matheclipse-core\src\test\java\org\matheclipse\core\system\SparseArrayTest.java`
contains strong direct cases for:

- `SparseArray`;
- `ArrayRules`;
- `DiagonalMatrix`;
- sparse `Dot`;
- `Flatten`;
- `FullForm`;
- `IdentityMatrix`;
- `Normal`.

This file is broader than Tungsten's currently implemented evaluator surface, but it is very well
aligned with the long-term goal of supporting array/matrix/tensor manipulation including sparse
forms.

### Best basic integer arithmetic sources

`woxi`, `mathics-core`, and `expreduce` all contribute useful cases, but with different tradeoffs.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\woxi\tests\interpreter_tests\math\number_theory.rs`
is the richest single file for exact integer and rational arithmetic edge cases, including:

- `GCD`;
- `Divisors`;
- `Divisible`;
- `IntegerExponent`;
- large-integer behavior;
- some rational GCD/LCM behavior.

However, the same file also covers `FactorInteger`, `Fibonacci`, `EulerPhi`, `ExtendedGCD`, and
other algorithms that are either explicitly out of scope or at least beyond the currently stated
"basic integer arithmetic functions" boundary.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\mathics-core\test\builtin\numbers\test_numbertheory.py`
contains a small number of very relevant `Divisors` cases, but the same file also mixes in
`FractionalPart`, `MantissaExponent`, `RandomPrime`, and real/complex-related behavior that should
not be part of Tungsten's first evaluator waves.

`C:\TestData\wolfram\tungsten-wolfram-upstream-tests\expreduce\expreduce\resources\numbertheory.m`
has good `GCD`, `LCM`, `Mod`, `EvenQ`, `OddQ`, and `FactorInteger` coverage, but it too extends
well past the currently stated boundary.

My recommendation is to split this area into two internal buckets:

- `basic-integer-now`: `GCD`, `LCM`, `Divisors`, `Mod`, `Quotient*`, parity, exact integer
  predicates, and big-integer edge cases;
- `scope-adjacent-later`: `FactorInteger`, `EulerPhi`, `Fibonacci`, `Prime*`, `ExtendedGCD`,
  `Binomial`, and similar algorithmic number theory.

## What should not be adapted

These parts of the corpus are useful only as "do not import this into Tungsten's evaluator plan"
markers.

`mathics-core`:

- `test/builtin/numbers/test_hyperbolic.py`
- `test/builtin/numbers/test_diffeqns.py`
- calculus, special-function, and symbolic simplification suites in the builtin tree

`expreduce`:

- `expreduce/resources/rubi.m`
- `expreduce/resources/solve.m`
- `expreduce/builtin_trig.go`
- the large mixed `resources/tests.m` file unless it is split first

`woxi`:

- `tests/cli/math/elementary.md`
- `tests/cli/math/special.md`
- `tests/cli/math/algebraic.md`
- `tests/interpreter_tests/calculus.rs`
- much of `all_mathics_tests.txt` for early waves

`symja_android_library`:

- `SolveTest.java`
- `PolynomialFunctionsTest.java`
- `ComplexExpandTest.java`
- optimization, calculus, special-function, and solver-heavy areas across `matheclipse-core`

The common failure mode in those files is not "they are bad tests". It is that they encode exactly
the symbolic math and specialized algorithms Tungsten has said it does not want to implement.

## Recommended extraction strategy

### Parser lanes

I recommend organizing adapted parser tests into separate lanes instead of one giant imported blob.

- `parser/smoke`: parse-success / parse-failure cases with no deep expected tree.
- `parser/canonical`: source to canonical InputForm / FullForm / Tungsten AST.
- `parser/operators`: precedence and associativity edge cases.
- `parser/named-characters`: escaped names, Unicode forms, and special tokens.
- `parser/boxes-semantic`: semantic box lowering into ordinary Tungsten expressions.
- `parser/boxes-concrete`: preserve exact box-tree structure for forms Tungsten eventually wants
  to round-trip or inspect structurally.

### Evaluator lanes

- `eval/structural`
- `eval/patterns-and-rules`
- `eval/functional`
- `eval/control-flow-and-scoping`
- `eval/associations`
- `eval/arrays-and-sparse`
- `eval/basic-integer`
- `eval/scope-adjacent-number-theory`

The last lane should remain explicitly non-default until the intended evaluator boundary changes.

### Source priority

Best direct-copy / near-literal adaptation candidates:

- `wolfram-codeparser` (MIT)
- `expreduce` (MIT)
- `mmaclone` (BSD 3-Clause-style)
- `howl` (Modified BSD)

Best reference-only or derive-new-tests sources:

- `mathics-core` (GPLv3)
- `mathics3-scanner` (GPLv3)
- `symja_android_library` (GPLv3)
- `woxi` (AGPLv3)

### Practical next extraction waves

Wave 1:

- parser goldens from `wolfram-codeparser`
- operator/named-character completeness data from `mathics3-scanner` and Symja parser tables
- subset parser/evaluator cases from `mmaclone`

Wave 2:

- control-flow and association cases from `woxi`
- procedural, association, and pattern/rule cases from `mathics-core`
- functional/list/control-flow cases from `expreduce`

Wave 3:

- sparse-array and matrix/tensor structural cases from Symja
- additional parser surface from Symja's `ParserTestCase` and `WMAParserTestCase`
- selected scope-adjacent basic/algorithmic number-theory cases if the evaluator boundary expands

## Bottom line

The corpus is already sufficient to drive a serious Tungsten parser and evaluator test expansion.
The highest-leverage path is not "import everything". It is:

1. use `wolfram-codeparser` plus parser-table sources to build a much more complete parser corpus,
   especially for boxes and named characters;
2. use `mmaclone`, selected `woxi`, selected `mathics-core`, and selected `expreduce` as the
   evaluator backbone for structural, functional, control-flow, association, array, and basic
   integer behavior;
3. keep solver/calculus/simplification/special-function material out of scope unless the Tungsten
   README scope changes later;
4. treat GPL/AGPL repositories as local mining corpora and case catalogs unless we are prepared to
   accept the licensing consequences of copying their tests.
