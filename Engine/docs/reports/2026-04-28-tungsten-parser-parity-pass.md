# Tungsten parser parity pass — 2026-04-28

- Status: Report (parser-only parity sweep against the live Wolfram 14.3 kernel,
  with five follow-up parser fixes plus documentation gaps and non-parser issues
  flagged for the maintainer)
- Audience: Vladimir Reshetnikov, Tungsten parser maintainers
- Scope: `Engine/src/tungsten/expression_parser.py`,
  `Engine/src/tungsten/named_characters.py`,
  `Engine/src/tungsten/wolfram_strings.py` plus regression tests and
  `expression-parser.md` documentation updates
- Created (UTC): 2026-04-28T03:04:09Z
- Repository HEAD: d7b15d267848a0ad22ccd1798e790bb27f621835
- Related code:
  - [Engine/src/tungsten/expression_parser.py](../../src/tungsten/expression_parser.py)
  - [Engine/src/tungsten/named_characters.py](../../src/tungsten/named_characters.py)
  - [Engine/src/tungsten/wolfram_strings.py](../../src/tungsten/wolfram_strings.py)
  - [tests/test_expression_kernel_parity.py](../../tests/test_expression_kernel_parity.py)
- Related docs:
  - [Expression Parser](../expression-parser.md)
  - [Parser Corpus](../parser-corpus.md)
  - [2026-04-27 parity fixes](2026-04-27-parser-parity-fixes.md)

## Executive summary

A parser-only parity sweep against the live Wolfram 14.3 kernel found five
real parse-tree divergences that this pass closes, plus a sizeable backlog of
documentation gaps. Headline numbers from a 500-file corpus run with the
kernel-side oracle (`ToExpression[text, InputForm, HoldComplete]`):

| Outcome | Count |
| ------- | ----: |
| `both_success` | 431 |
| `tungsten_only_success` | 7 |
| `both_fail` | 1 |
| `tungsten_gap` | 1 |
| `skipped` (size cap) | 60 |

The single remaining `tungsten_gap` is the previously documented
`f[ [b] ]` -> `Part[f, b]` quirk (`wljs-notebook/Kernel/Utils.wl`). The seven
`tungsten_only_success` files are kernel-side parse failures on real
package-info template files where the kernel is the stricter side.

A wider Tungsten-only sweep over 5000 files reports 4593 successes, 394
size-cap skips, and 13 remaining failures — and **all 13 also fail in the
kernel** (verified by re-parsing each through `ToExpression`). The remaining
13 are git-merge-conflict files, IntelliJ-plugin placeholder fixtures with
`<ref>` markers, Lisp source incorrectly classified as Wolfram, Git-LFS
pointer stubs, and a FeynCalc package with a typo (extra `}` at EOF).

## Methodology

Differential harness, identical in spirit to the 2026-04-27 sweep:

1. Build a list of textual inputs covering numeric literals, string literals
   and escapes, symbols and contexts, arithmetic, comparison, boolean, list /
   part / span, patterns (including `_..`, `x_..`, blank shorthand), pure
   functions (`&`, `|->`), replacement (`/.`, `//.`, `/@`, `@@`, `@@@`),
   compound expressions, get / put with diverse filename character classes,
   string concatenation, structural operators (`@*`, `/*`, `**`, `.`),
   and operator-precedence interactions across all of the above.
2. For each input, send to the live kernel via `WolframKernelRunner.evaluate_text`
   and capture the FullForm of `ToExpression["...", InputForm, HoldComplete]`.
   Strip the leading `HoldComplete[...]` (collapsing multi-arg HoldComplete to
   `CompoundExpression[...]` for the comparison).
3. Compare to `parse_expression(text, form="input").to_full_form()`.
4. Iterate over the corpus at `C:/TestData/wolfram/tungsten-wolfram-parser-corpus`
   for breadth (500-file kernel-batched run, 5000-file Tungsten-only run).

Five focused fixes landed across this pass; the other observed divergences are
either documented in [expression-parser.md](../expression-parser.md), in
[2026-04-27-parser-parity-fixes.md](2026-04-27-parser-parity-fixes.md), or
flagged below as new doc-gap call-outs.

## Findings and fixes

### F1. `<<file.m`, `>>file.m`, `>>>file.m` filename tokenization

- **Before**: `<<file.m` parsed as `Dot[Get["file"], m]`. The
  `_parse_file_name_literal` helper consumed only a single `symbol` or `string`
  token, so anything beyond the first symbol-fragment of the filename
  re-entered as ordinary infix operators.
- **Kernel**: `<<file.m` parses as `Get["file.m"]`. Wolfram's tokenizer
  recognizes a context-sensitive "filename" character class after `<<`, `>>`,
  and `>>>` that includes `.`, `/`, `\`, `:`, `-`, `*`, `!`, `?`, `~`,
  `` ` ``, `$`, and `_`, plus letters and digits. The class terminates at
  whitespace, `;`, `,`, brackets (`]`, `}`, `)`, `[`, `{`, `(`), and the
  prefix-only operators `+`, `&`, `%`, `^`, `@`, `#`, `=`, `<`, `>`, `|`,
  `'`, and `"` (a leading `"` falls through to the regular string scanner).
  Verified empirically against the live kernel.
- **After**: matches the kernel for the common cases — `<<file.m`,
  `<<a.b.c`, `<<a/b/c.m`, `<<a`b``, `<<C:/path/file.m`, `<< file.m` (with
  whitespace), and quoted-string `<<"file.m"`. `>>` and `>>>` use the same
  scanner.

The fix lives in `_tokenize`, which now calls a new
`_scan_get_put_filename(text, index)` helper immediately after emitting an
`<<`, `>>`, or `>>>` operator token. The helper skips inline whitespace and a
single backslash-newline continuation, falls through if the next character is
`"` (regular string scanner takes over), and otherwise scans a maximal run of
filename-class characters and emits a new `kind="filename"` token.
`_parse_file_name_literal` accepts the new token kind.

This is a high-impact change: every `.wl` / `.m` / `.wls` file with a `<<file.m`
form was previously rejected by Tungsten. The 12 `tungsten_gap` failures from
the 2026-04-25 corpus run all involved this exact form (or were corpus
artifacts).

### F2. `/@`, `//@`, `@@`, `@@@` are right-associative

- **Before**: `a /@ b /@ c` parsed as `Map[Map[a, b], c]` (left-associative).
  Same for `//@`, `@@`, `@@@`.
- **Kernel**: `a /@ b /@ c` parses as `Map[a, Map[b, c]]` (right-associative).
- **After**: matches the kernel. The fix is one line per operator in the infix
  table — change `(BP, BP+1, head)` to `(BP, BP, head)` so the right operand
  re-enters at the same precedence and absorbs the next instance of the same
  operator.

The kernel's `Map` and `Apply` precedences are both 620, but Wolfram parses
them right-to-left so `a /@ b @@ c` becomes `Map[a, Apply[b, c]]` — same shape
as `a /@ (b @@ c)`. Tungsten's compressed BP space gives them BPs 45 and 44
respectively (and now both right-associative), which produces the same parse
tree for that case.

### F3. `@*` and `/*` mixed-associativity

- **Before**: `f /* g @* h` parsed as `Composition[RightComposition[f, g], h]`
  (`/*` -> `@*` left-associative at same BP). The 2026-04-27 pass made
  `f @* g /* h` parse to `RightComposition[Composition[f, g], h]` correctly,
  but the reverse ordering still diverged.
- **Kernel**: kernel `Composition` (650) sits one tick above `RightComposition`
  (648), so `f /* g @* h` parses as `RightComposition[f, Composition[g, h]]`
  (the `@*` binds the right operand of `/*`).
- **After**: matches the kernel for both orderings. Fix is asymmetric
  right-bp: `@*` keeps `(COMPOSITION_BP, COMPOSITION_BP+1, "Composition")`
  (left-associative chain), while `/*` becomes
  `(COMPOSITION_BP, COMPOSITION_BP, "RightComposition")` (right-associative
  re-entry). Same-operator chains remain flat through
  `_PARSER_FLAT_OPERATOR_HEADS`.

### F4. `Dot` precedence above `Times`

- **Before**: `a*b.c` parsed as `Dot[Times[a, b], c]` because Tungsten gave
  `.` the same `_TIMES_BP = 140` as `*`, with the `+1` right-bp making the
  table left-associative. So `a*b.c` was `(a*b).c`.
- **Kernel**: kernel `Dot` (490) sits between `Diamond` (450) and
  `NonCommutativeMultiply` (510), strictly above `Times` (400). So `a*b.c`
  parses as `Times[a, Dot[b, c]]`.
- **After**: matches the kernel. New `_DOT_BP = 145` (between
  `_DIAMOND_BP = 144` and the bumped `_NONCOMMUTATIVE_TIMES_BP = 146`).
  Operator-table entry for `.` switches from `_TIMES_BP` to `_DOT_BP`. The
  bump to `**`'s BP keeps `a.b**c` -> `Dot[a, NonCommutativeMultiply[b, c]]`
  (`**` still binds tighter than `.`).

This fix also propagates to unary `-` consuming `Dot`: `-a.b` now parses
as `Times[-1, Dot[a, b]]` instead of `Dot[Times[-1, a], b]`.

### F5. Prefix `!` precedence

- **Before**: prefix `!` shared the higher `_PREFIX_BP = 150` with unary `+`
  and `-`. So `!a == b` parsed as `Equal[Not[a], b]`, `!a + b` as
  `Plus[Not[a], b]`, etc. — `!` only consumed its immediate atom.
- **Kernel**: kernel `Not` (230) sits between `&&`/`||` (And/Or = 215) and
  `==`/`<` (Equal/Less = 290). So `!` consumes `==`, `<`, `+`, `*`, `^`,
  `Span`, `Map`, etc. but does *not* consume `&&`, `||`, `/.`, `->`, `;`.
  Verified: `!a == b` -> `Not[Equal[a, b]]`, `!a && b` -> `And[Not[a], b]`,
  `!a /. b` -> `ReplaceAll[Not[a], b]`.
- **After**: matches the kernel. Split into `_PREFIX_NOT_BP = 90` for `!`
  (between `_AND_BP = 80` and `_COMPARE_BP = 100`) and
  `_PREFIX_PLUS_MINUS_BP = 142` for `+` and `-` (between Times 140 and Dot
  145, matching the kernel's unary Minus / Plus precedence). Unary `+` /
  `-` consume Power, NCT, Dot, Diamond, CircleTimes; do not consume Times,
  Plus, Compare, Span, Replace, Rule, etc.

### F6. Unterminated `\[` in string literals

- **Before**: `parse_wl_string_literal('"\\["')` raised
  `WolframSyntaxError("Unterminated Wolfram named character escape at offset 0.")`.
  `decode_named_character_escape` raised on missing `]` even from the
  string-literal path. Same for `"\[Alpha"` (named-character name with no
  closing bracket anywhere in the string).
- **Kernel**: kernel preserves the unterminated `\[` as literal text. The
  string-literal lexer is more lenient than the identifier path here.
- **After**: matches the kernel. `decode_named_character_escape` now returns
  `None` instead of raising when there is no closing `]`, letting the
  string-literal caller fall through to its leading-backslash branch (which
  already preserves `"\X"` -> `"\X"` for unrecognized escapes).
  `decode_named_character_escape_strict` (used in identifier-position
  parsing) keeps raising — that is where the kernel itself rejects.

## Files changed

- `Engine/src/tungsten/expression_parser.py`
  - New `_GET_PUT_FILENAME_PUNCT`, `_is_get_put_filename_char`,
    `_scan_get_put_filename` for filename tokenization.
  - `_tokenize` calls `_scan_get_put_filename` after `<<`, `>>`, or `>>>`.
  - `_parse_file_name_literal` accepts a new `kind="filename"` token.
  - New `_DOT_BP = 145`; bumped `_NONCOMMUTATIVE_TIMES_BP = 146`.
  - New `_PREFIX_NOT_BP = 90` and `_PREFIX_PLUS_MINUS_BP = 142`; the `+`,
    `-`, `!` prefix branches use the new BPs.
  - Operator table: `.` uses `_DOT_BP`; `/@`, `//@`, `@@`, `@@@` use
    same-bp `(MAP_BP, MAP_BP, ...)` / `(APPLY_BP, APPLY_BP, ...)` for
    right-associativity; `/*` uses
    `(_COMPOSITION_BP, _COMPOSITION_BP, "RightComposition")` for asymmetric
    right-associativity.
- `Engine/src/tungsten/named_characters.py`
  - `decode_named_character_escape` returns `None` instead of raising for
    unterminated `\[`. `decode_named_character_escape_strict` (identifier
    path) keeps the strict raise.
- `Engine/tests/test_expression_kernel_parity.py`
  - New regression suites: `GetPutFilenameTokenizationTests` (11 cases),
    `MapApplyAssociativityTests` (5 cases),
    `CompositionMixedAssociativityTests` (4 cases),
    `DotPrecedenceTests` (6 cases),
    `PrefixNotPrecedenceTests` (7 cases),
    `StringEscapeUnterminatedNamedCharTests` (3 cases).
- `Engine/docs/expression-parser.md`
  - Get / Put filename character class documented in the supported-syntax
    section.
  - New parse-stage normalization bullets for `/@` / `@@` right-assoc, mixed
    `@*` / `/*` precedence, Dot precedence, prefix `!` precedence.
  - New "Known kernel divergences" bullets for whole-file newline merging,
    `_..` / `x_..` leniency, `Plus??` strictness, `|->` precedence,
    `?:` interaction, base-real folding, and the still-unresolved
    `/@` / `/.` / `@*` vs arithmetic precedence relationship.

## Remaining parser divergences (intentional or deferred)

These are the divergences I observed but did **not** fix. All are now
documented in [expression-parser.md](../expression-parser.md):

### G-A. Whole-file newline-as-separator (was G1 in the 2026-04-27 report)

Tungsten's `parse_expression("a\nb")` returns `Times[a, b]` — newlines are
treated as ordinary whitespace, so adjacent expressions concatenate via
implicit Times. The kernel returns `HoldComplete[a, b]` (a multi-argument
`HoldComplete`). The `parser-corpus` comparison normalizes the kernel side
by rewriting `HoldComplete[exprs__]` to
`HoldComplete[CompoundExpression[exprs]]`, which is what makes the corpus run
look healthy in spite of the silent flattening.

This affects essentially every `.wl` / `.m` package file. Mentioned in the
2026-04-27 report (G1) but not previously documented in
`expression-parser.md`; now added. Fixing it requires either:

- treating top-level `\n` as an expression separator in the parser (likely
  requires a separate `parse_program` entry point so the existing single-Expr
  callers do not break), or
- returning a `CompoundExpression[...]` wrapper from `parse_expression` for
  multi-expression input. Either approach is a substantial refactor; the
  evaluator and rendering pipelines all assume a single top-level Expr today.

### G-B. `_..` and `x_..` are accepted by Tungsten but rejected by the kernel

Tungsten parses `_..` as `Repeated[Blank[]]` and `x_..` as
`Repeated[Pattern[x, Blank[]]]`. The kernel rejects both because its tokenizer
prefers `_.` (Optional shorthand), leaving the trailing single `.` with no
operand. Real package source never contains `_..` directly — only the
CodeFormatter / CodeInspector test suites reference it as syntax-error fixture
text — so the leniency is harmless in practice. Now documented.

### G-C. `Plus??` is rejected by Tungsten but accepted by the kernel

`ToExpression["Plus??", InputForm, HoldComplete]` returns `HoldComplete[Plus]`
in the kernel — the trailing `??` with no operand is silently dropped.
Tungsten errors with `Expected 'eof', found '??' at offset 4.`. Low-impact;
zero corpus matches outside `Information::syntx`-style fixtures. Now
documented.

### G-D. `|->` precedence asymmetry

`a = x |-> y` parses as `Function[Set[a, x], y]` in Tungsten, kernel gives
`Set[a, Function[x, y]]`. Other observed kernel-only behaviors include
`a |-> b = c` -> `Function[a, Set[b, c]]`, `a |-> b &` ->
`Function[a, Function[b]]`, and `a |-> b -> c` -> `Function[a, Rule[b, c]]`.
The kernel's `|->` is asymmetric: high left-binding power, low right-binding
power. Fixing requires splitting the operator-table entry into separate
left/right BPs (mechanical change, deferred because real package source rarely
chains `|->` with `=`, `&`, or `->`). Now documented.

### G-E. `?` PatternTest does not absorb a trailing `:`

`x_?test:1` parses as `Optional[PatternTest[Pattern[x, _], test], 1]` in
Tungsten, kernel gives `PatternTest[Pattern[x, _], Pattern[test, 1]]`. The
kernel allows exactly one follow-up `:` operator on the RHS while excluding
higher-precedence operators like `+`, `*`, `|`, `/;`. Cannot match through
plain Pratt min_bp tuning because `:` (BP 180 in Tungsten) and `+` (BP 120)
cannot be selectively included with a single right_bp threshold. Custom
`?`-RHS parser would be needed. Zero corpus matches; now documented.

### G-F. Map / Apply / Composition vs arithmetic-and-comparison precedence

In the kernel, `Map`/`Apply` (precedence 620) and `Composition` (650) sit
*above* arithmetic and comparison operators (Plus 310, Times 400, Power 590).
So:

- `f /@ a + b` -> kernel `Plus[Map[f, a], b]`; Tungsten `Map[f, Plus[a, b]]`
- `f /@ a^b` -> kernel `Power[Map[f, a], b]`; Tungsten `Map[f, Power[a, b]]`
- `f /. g @* h` -> kernel `ReplaceAll[f, Composition[g, h]]`; Tungsten
  `Composition[ReplaceAll[f, g], h]`
- `f /. g /@ h` -> kernel `ReplaceAll[f, Map[g, h]]`; Tungsten
  `Map[ReplaceAll[f, g], h]`

Tungsten currently keeps these structural operators at low BPs (43-50, in the
gap between `_ASSIGNMENT_BP = 40` and `_RULE_BP = 60`), so the same inputs
parse with the structural operator on the outside. Fixing this requires
moving `/@`, `//@`, `@@`, `@@@`, `@*`, `/*`, and `<>` (StringJoin) up into
the (160, 175) BP slot between `_POWER_BP` and `_POSTFIX_UNARY_BP`. The
refactor is mechanical but touches a handful of existing parity tests
(`PostfixFunctionPrecedenceTests` documents the assumed `&` / `@*` / `/.`
interaction, and several other tests encode the current ordering implicitly);
deferred from this pass because the change crosses many implicit invariants.

Real-world impact: package source typically parenthesizes the structural
operand (`(f /@ list) + offset`, `f /. (g @* h)`), so the corpus-success rate
is barely affected; held parse trees diverge only for the un-parenthesized
mixed forms. Now documented in `expression-parser.md`. **Worth a follow-up.**

### G-G. `<>` (StringJoin) and `~~` (StringExpression) are nested at parse time

`"a" <> "b" <> "c"` parses as `StringJoin[StringJoin["a", "b"], "c"]` rather
than the kernel's flat `StringJoin["a", "b", "c"]`. Same for `~~`. The
existing parser doc already calls this out: "intentionally remain nested at
parse time and rely on the evaluator's flattening attributes to produce the
flat call later." Documented.

The accompanying StringJoin precedence is also currently shared with `Plus`
(both at `_PLUS_BP = 120`), but the kernel places StringJoin (600) above
Power (590). So `a + b <> c` parses to `StringJoin[Plus[a, b], c]` in
Tungsten and to `Plus[a, StringJoin[b, c]]` in the kernel. This is part of
the same G-F relative-ordering issue (StringJoin should be in the
structural-operator high-BP slot too). **Worth a follow-up.**

### G-H. `And` / `Or` chains stay nested at parse time

`a && b && c` -> Tungsten `And[And[a, b], c]`; kernel `And[a, b, c]`. Already
documented in `expression-parser.md` ("intentionally remain nested at parse
time"). Same for `||`.

## Findings worth flagging that are not parser issues

These are the things I noticed during the sweep but did **not** touch (per the
session-level instructions to report-rather-than-fix non-parser issues):

### N1. `parser-corpus compare` only checks parse success/failure, not parse-tree equality

`parse_files_with_wolfram_kernel` produces a per-file FullForm preview but
the comparison logic in `compare_parser_corpus` only classifies outcomes by
status (`success` vs `failure`). Two files where Tungsten and the kernel both
parse but produce *different* parse trees show up as `both_success`. This
hides exactly the kind of divergence this report has been chasing — `f /@ a + b`,
`a && b && c`, etc. The held parse-tree previews are stored in
`parser-corpus-results.jsonl` but never compared.

A useful enhancement would be a `tungsten_diff` outcome that reports parse
trees both succeed but the FullForms differ. Out of scope for this pass;
worth flagging.

### N2. `_decode_character_escape`'s `\b` and `\f` decoding diverges in display only

Tungsten interprets `\b` as `\x08` (backspace) and `\f` as `\x0c` (form feed)
in string literals — same numeric codepoints as the kernel produces. The
diff only shows up in `to_full_form()` rendering: the kernel re-encodes
the backspace as `\b` for display, while Tungsten emits `\x08`. Round-trip
through `parse_expression(expr.to_input_form())` preserves the codepoint, so
no semantic divergence. Cosmetic; not a parser bug.

### N3. Cosmetic real-precision rendering

The kernel adds a trailing `` ` `` to every machine-precision real (`1.5` ->
`1.5\``, `0.001` -> `0.001\``) and renders precision/accuracy marks in a
canonical form (`1.2`20` -> `1.2`20.`, `1.2``20` -> `1.2`20.07918...`).
Tungsten preserves the original textual form. This is the documented
"scientific notation accepted but not folded" boundary, and the same applies
to base-real folding (`16^^f.f` is not folded to `15.9375`). Now also
documented.

### N4. Context-name leniency

Tungsten accepts a few context-name patterns that the kernel rejects:

- ``Foo`Bar``` (three trailing context delimiters): Tungsten parses as the
  symbol; kernel rejects.
- ````` (two adjacent backticks with no name): Tungsten parses as a symbol;
  kernel rejects.
- `` `Plus`` (leading single backtick): Tungsten preserves as the symbol
  `` `Plus``; kernel resolves to the current context (`Global`Plus`).

The kernel-resolved-current-context behavior is hard to replicate without a
live current-context state and is a held-vs-evaluated rendering difference,
not a parsing difference. The two leniency cases (trailing backticks,
double-backtick-no-name) are real divergences but extremely rare in real
source. Worth flagging; not blocking.

### N5. Notebook-only failures

`wolframresearch-codeparser/Tests/files/large/ReliefPlot.nb` failed with
"Notebook expression not found" — Tungsten's notebook parser path, not the
text parser path. Out of scope for this report (and the `.nb` is malformed —
134 bytes, almost certainly a stub).

## Verification

```text
$ cd Engine && PYTHONPATH=src python -m unittest discover -s tests -t .
Ran 866 tests in 62.449s
OK (skipped=2, expected failures=2)
```

(Up from 830 tests before this pass; the 36 new tests are the regression
suites listed under "Files changed".)

```text
$ python -m tungsten parser-corpus compare \
    --corpus-root C:/TestData/wolfram/tungsten-wolfram-parser-corpus \
    --no-write --max-files 500 --max-file-mb 1 --kernel-batch-size 200 \
    --tungsten-workers 8 --shuffle --seed 42
... outcomes: both_success=431, tungsten_only_success=7, both_fail=1,
... tungsten_gap=1, skipped=60
```

```text
$ python -m tungsten parser-corpus compare \
    --corpus-root C:/TestData/wolfram/tungsten-wolfram-parser-corpus \
    --skip-wolfram --no-write --max-files 5000 --max-file-mb 2 \
    --tungsten-workers 8 --shuffle --seed 42
... tungsten_statuses: success=4593, skipped=394, failure=13
... All 13 also fail under live-kernel ToExpression (verified separately).
```

The differential harness used during the sweep (~270 hand-picked cases
covering numerics, strings, symbols, arithmetic, comparison, boolean, lists,
patterns, slot syntax, get/put, structural operators, prefix/postfix
operators, and operator-precedence interactions) reports 207 / 230 matches
on the post-fix parser, with the 23 remaining diffs all in the documented
buckets (cosmetic precision rendering, context-name resolution, And/Or/StringJoin/StringExpression
parse-time nesting, base-real folding, `_..` leniency, mantissa-exponent
folding).
