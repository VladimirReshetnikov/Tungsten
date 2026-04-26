# Tungsten Expression Parser

Created (UTC): 2026-04-23T14:55:38Z
Updated (UTC): 2026-04-26T04:49:30Z
Repository HEAD: be1373c65e4260dd384f08b08e8b3677fc2a0bf3

## Summary

`expression.py` gives Tungsten a real kernel-free Wolfram expression subsystem. It provides:

- an AST for atoms and general expressions;
- parsers for FullForm, InputForm, and a pragmatic StandardForm subset;
- canonical `InputForm` and `FullForm` rendering;
- an inert evaluator for structural built-ins such as `Length`, `Depth`, `Head`, `Part`,
  `Extract`, `Level`, explicit-number arithmetic and relational heads such as `Rational`,
  `Complex`, `Plus`, `Times`, `Power`, `N`, `Precision`, `Accuracy`, `Equal`, and `Less`,
  simple predicates such as `AtomQ`, `IntegerQ`, `NumberQ`, `StringQ`, `DigitQ`, `LetterQ`, and
  `EvenQ`, hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`, bounded
  numeric heads such as `UnitStep`, `Mod`, `Clip`, and `KroneckerDelta`, Boolean heads such as `Not`,
  `And`, and `Or`, `MatchQ`, `FreeQ`, `Cases`, `DeleteCases`, `Replace`, `ReplaceAll`,
  `ReplaceRepeated`, non-local control and message heads such as `Abort`, `Throw`, `Catch`,
  `CheckAbort`, `AbortProtect`, `Check`, `Quiet`, `Message`, `Off`, `On`, and `Print`,
  collection and timing heads such as `Sow`, `Reap`, `Pause`, `AbsoluteTiming`,
  `TimeConstrained`, and `TimeRemaining`, failure and cleanup heads such as `FailureQ`,
  `MissingQ`, `Enclose`, `Confirm`, `ConfirmBy`, `ConfirmMatch`, `ConfirmAssert`, `Assert`,
  `Failsafe`, and `WithCleanup`, `Function`,
  functional combinators such as `Composition`, `Nest`,
  `FixedPoint`, `Fold`, `MapApply`, `MapAll`, `MapIndexed`, `Through`, `Thread`, `Outer`,
  `Inner`, `Dot`, array and matrix builders such as `Array`, `Range`, `UnitVector`,
  `IdentityMatrix`, and `DiagonalMatrix`, sequence transforms such as `Partition`, `BlockMap`,
  `TakeList`, `TakeDrop`, `FoldWhile`, `FoldPair`, `Position`, `DeleteDuplicates`, byte and
  character heads such as `ByteArray`, `BaseEncode`, `BaseDecode`, `Characters`,
  `StringLength`, `StringTake`, `StringDrop`, `StringJoin`, `StringInsert`, `StringReverse`,
  string-pattern heads such as `StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`,
  `StringPosition`, `StringContainsQ`, `StringCases`, and `StringReplace` with `RegularExpression`
  and practical `DatePattern` support, `ToCharacterCode`,
  `FromCharacterCode`, `StringToByteArray`, `ByteArrayToString`, `ImportString`,
  `ExportString`, `ImportByteArray`, `ExportByteArray`, `ToString`, `ToExpression`, `ToBoxes`,
  `MakeBoxes`, `MakeExpression`, `StripBoxes`, `SyntaxQ`, `SyntaxLength`, `Pick`,
  `Select`, `Discard`, `SelectFirst`, `TakeWhile`, `Take`, `Drop`, `Flatten`, `ReplaceAt`,
  `ReplacePart`, association constructors, key accessors, symbol and context registry functions
  such as `Symbol`, `SymbolName`, `Unique`, `Names`, `NameQ`, `Contexts`, `Context`, `$Context`,
  `$ContextPath`, `Attributes`, and `ValueQ`, `Sequence` splicing, `Nothing` removal in evaluated
  list contexts, REPL history heads such as `$Line`, `In`, `InString`, `Out`, and `DownValues`,
  Hold-family wrappers, and related exact-position transforms;
- preservation of Wolfram string literals that contain embedded inline box escapes such as
  `\!\(\*GraphicsBox[...]\)`.

The important constraint is deliberate: this is not a replacement for the Wolfram kernel. Unknown
symbols stay inert, and Tungsten only evaluates the specific built-ins it implements itself.

For the exact supported structural function list, supported forms, and official Wolfram reference
links, read [expression-function-support.md](./expression-function-support.md). For the supported
offline import / export format subset and its data-shape rules, read
[import-export-formats.md](./import-export-formats.md). For the evaluator ordering rules that make
`Sequence` and `Nothing` special without a live kernel, read
[sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md). For the process-local name
registry and fixed context state, read [symbol-context-registry.md](./symbol-context-registry.md).

## When to use this subsystem

Use the expression subsystem when you want:

- structural analysis without launching a kernel;
- symbol and context name queries without launching a kernel;
- read-only Wolfram 14.3 <code>System`</code> symbol and attribute discovery without launching a kernel;
- canonical formatting of textual Wolfram expressions;
- lightweight expression traversal from Python or PowerShell;
- deterministic scripting behavior that does not depend on evaluation rules, definitions, or
  notebook state.

Use `kernel eval` instead when you need:

- real Wolfram evaluation semantics;
- definitions from packages or notebook state;
- full StandardForm or box-language behavior;
- symbolic semantics beyond the inert built-ins listed here.

## Supported syntax

The parser currently handles:

- symbols, strings, integers, and reals, including Wolfram numeric literal spellings such as
  leading-dot and trailing-dot decimals (`.5`, `1.`), base literals (`16^^ff`, `16^^f.f`),
  scientific notation (`1.2*^3`), precision marks such as <code>1.2`20</code> and
  <code>1.2`</code>, and accuracy marks such as <code>1.2``20</code>;
- function application `head[arg1, arg2]`;
- lists `{a, b, c}`;
- associations `<|a -> b|>`;
- common pattern shorthand such as `_`, `_Head`, `x_`, `x_Head`, `x : patt`, `patt?test`,
  `patt:def`, `_.`, `patt /; test`, and `a | b`;
- association-aware exact selectors such as `Key[b]` and string-key shorthand `"name"` inside
  part and extract specifications;
- arithmetic syntax such as `+`, unary `-`, implicit `Times`, `/`, and `^`;
- structural operator forms such as `===`, `=!=`, `@@@`, `@*`, `/*`, `.`, `**`, `<->`,
  string concatenation `<>`, string-pattern concatenation `~~`, and repetition suffixes `..` /
  `...`;
- postfix derivative primes such as `f'`, `f''`, and `f'[x]`, lowered to
  `Derivative[1][f]`, `Derivative[2][f]`, and `Derivative[1][f][x]`;
- rules `->` and `:>`, including guarded delayed-rule right-hand sides such as
  `x_ :> rhs /; test`;
- assignment and update surface syntax, lowered inertly to the corresponding heads:
  `=`, `:=`, `=.`, `^=`, `^:=`, `+=`, `-=`, `*=`, `/=`, `/: ... =`, `/: ... :=`, and
  `/: ... =.` become `Set`, `SetDelayed`, `Unset`, `UpSet`, `UpSetDelayed`, `AddTo`,
  `SubtractFrom`, `TimesBy`, `DivideBy`, `TagSet`, `TagSetDelayed`, and `TagUnset`.
  Spaced Wolfram unset syntax such as `lhs = .` and `tag /: lhs = .` is also recognized;
- other high-precedence syntactic operators, including `x++`, `++x`, `x--`, `--x`, `x!`,
  `x!!`, `a::tag`, `a ~ f ~ b`, `<< file`, `expr >> file`, `expr >>> file`, `?name`, and
  `??name`, lowered to `Increment`, `PreIncrement`, `Decrement`, `PreDecrement`, `Factorial`,
  `Factorial2`, `MessageName`, ordinary function application, `Get`, `Put`, `PutAppend`, and
  `Information`;
- comparisons and boolean operators, with same-head chained comparisons parsed as n-ary relation
  calls such as `Less[a, b, c]`;
- prefix and postfix application such as `f @ x` and `x // f`, with `@` binding tighter than
  arithmetic but looser than direct function application;
- mapping and replacement operators such as `/@`, `/.`, and `//.`;
- output-history shorthand `%`, `%%`, and `%n`, which lower to `Out[-1]`, `Out[-2]`, and
  `Out[n]`;
- positional pure-function syntax such as `body &`, `#`, `#n`, `#0`, `##`, `##n`, `Slot[]`,
  `Slot[n]`, `SlotSequence[]`, `SlotSequence[n]`, and Wolfram's `#name` shorthand for
  `#["name"]` / `#1["name"]`;
- named pure-function syntax such as `Function[x, body]`, `Function[{x, y}, body]`, `x |-> body`,
  `{x, y} |-> body`, and `x \[Function] body`, plus explicit-attribute forms such as
  `Function[Null, body, attrs]` and `Function[params, body, attrs]`;
- part syntax `expr[[...]]`;
- span syntax `a ;; b ;; c`;
- compound expressions with binary and trailing semicolons, including `expr;` lowering to
  `CompoundExpression[expr, Null]`;
- nested Wolfram comments `(* ... *)`. Quote characters inside comments are treated as comment
  text rather than as string delimiters, matching the practical behavior needed for exported
  package comments such as `\"tag\"`;
- backslash-newline line continuations;
- empty or comment-only input, which parses as `Null` to match the useful whole-file parser-corpus
  behavior of `ToExpression[..., InputForm, HoldComplete]`;
- common semantic notebook boxes when they appear as textual box expressions:
  `FractionBox`, `SqrtBox`, `RadicalBox`, `SuperscriptBox`, `SubscriptBox`,
  `SubsuperscriptBox`, `OverscriptBox`, `UnderscriptBox`, and `UnderoverscriptBox`;
- common wrapper boxes around those semantic forms, including `BoxData`, `FormBox`, `StyleBox`,
  `TagBox`, `TooltipBox`, and `InterpretationBox`;
- `RowBox` reconstruction for the box-driven subset above, so notebook snippets such as
  `SuperscriptBox["x", RowBox[{"1", "/", "3"}]]` or
  `FractionBox[SuperscriptBox["x", "3"], RowBox[{"1", "+", "a", " ", "b"}]]` lower to ordinary
  Tungsten expressions;
- named-character symbols and common named-character infix operators. Letter-like forms such as
  `\[Alpha]` remain symbols, while operator forms such as `a \[CirclePlus] b` lower to inert
  head calls such as `CirclePlus[a, b]` unless Tungsten has an explicit evaluator rule for that
  head;
- `RowBox`-based association examples from the installed `Association.nb` reference page,
  including `\[Rule]`, `\[RuleDelayed]`, `\[LeftAssociation]`, and `\[RightAssociation]`
  tokens plus nested part syntax such as `<|a -> x|>[[Key[b]]]`.
- common symbolic string-pattern forms such as `StringExpression`, `StartOfString`,
  `EndOfString`, `StartOfLine`, `EndOfLine`, `WordBoundary`, `DigitCharacter`,
  `HexadecimalCharacter`, `LetterCharacter`, `NumberString`, `PunctuationCharacter`,
  `WhitespaceCharacter`, `WordCharacter`, `CharacterRange["a", "z"]`, `RegularExpression[...]`,
  practical `DatePattern[...]` forms, and `Whitespace`.
- string literals that contain inline-box escape sequences.

The parser does not attempt to cover full box language or every textual corner of Mathematica. In
particular, it is intentionally conservative around attribute-driven pattern semantics,
arbitrary box constructs, custom notation definitions, stylesheet-dependent interpretation, and
broader evaluation semantics. Assignment-like syntax is parsed to inert heads, but Tungsten does
not yet attach own values, down values, up values, or other definition side effects to those heads.

The currently supported pattern subset is intentionally bounded:

- supported: `Blank`, `BlankSequence`, and `BlankNullSequence` forms via `_`, `__`, `___`,
  optional head-qualified forms such as `__Integer`, named patterns such as `x_`, `x__`, and
  `x___Integer`, `PatternTest` via `?`, explicit-default `Optional` forms via `patt:def`,
  global-default placeholders via `_.`, guarded patterns via `Condition` / `/;`, `Alternatives`,
  `Except`, `HoldPattern`, `Verbatim`, `Repeated`, `RepeatedNull`, `PatternSequence`,
  `OrderlessPatternSequence`, `Longest`, `Shortest`, `OptionsPattern`, and `KeyValuePattern`;
- typed blank shorthand is adjacency-sensitive: `x_Foo` is `Pattern[x, Blank[Foo]]`, while
  `x_ Foo_` is implicit multiplication between two patterns. Optional blank shorthand also
  supports common package-source idioms such as `a_.*x_` and whitespace-implied multiplication
  such as `c_. pf_Foo`;
- sequence patterns support named bindings and multiple occurrences in the same argument list for
  ordinary non-`Flat`, non-`Orderless` heads. Tungsten follows Wolfram's left-to-right
  shortest-first allocation rule with backtracking, while `Longest` switches the wrapped ambiguous
  sequence to greedy allocation; see
  [sequence-pattern-matching.md](./sequence-pattern-matching.md);
- limitations: Tungsten still does not implement attributes such as `Flat`, `Orderless`, or
  `OneIdentity`, user-defined `Default[...]` values for `Optional[patt]` / `_.`, or `OptionValue`
  lookup for `OptionsPattern`.

The current string-pattern subset is also intentionally bounded:

- supported: literal strings, `StringExpression` / `~~`, anonymous `_`, `__`, and `___`,
  `Repeated[p]` / `p..`, `RepeatedNull[p]` / `p...`, named captures including named string
  sequence captures via `x : __` and `x : ___`, `Alternatives`, `Condition` / `/;`,
  `PatternTest` / `?`, `HoldPattern`, `Shortest`, `Longest`, `Except` over supported
  one-character disallowed and allowed patterns, `CharacterRange`, `RegularExpression`, a
  practical `DatePattern` subset, `Whitespace`, and the common symbolic character classes and
  zero-width anchors listed above;
- string-pattern matches are leftmost-first, `StringCases` remains non-overlapping, and
  `StringPosition` keeps Wolfram's default overlapping behavior;
- ambiguous string sequence patterns use greedy allocation by default; wrapping a string-pattern
  subtree in `Shortest[...]` switches that subtree to non-greedy allocation, while `Longest[...]`
  explicitly requests greedy allocation;
- `RegularExpression` is delegated to Python's `re` engine and character-class tests use Python /
  Unicode-library predicates rather than trying to match Wolfram's exact PCRE and Unicode-version
  behavior byte for byte;
- `DatePattern` supports the documented date-element strings and simple supported separator
  string patterns, with range checks for the common numeric fields; it is a practical recognizer,
  not a full calendar validator;
- still not supported as string patterns: `Optional`, `OptionsPattern`, string-function options
  such as `IgnoreCase` / `Overlaps`, qualified blank shorthand such as `_DigitCharacter` or
  `__DigitCharacter`, and multi-character `Except[...]` disallowed subpatterns such as
  `Except["ab"]`, which the live Wolfram kernel also rejects as a string-pattern atom.

## Parsing forms

### `input`

Use this for normal textual Wolfram input such as:

```text
1 + 2 x^3
f[a, b] /. x -> y
expr[[1 ;; 3]]
Cases[{f[a], f[b]}, f[x_] :> x]
```

### `fullform`

Use this when you already have canonical head-based syntax:

```text
Rule[x, List[1, 2]]
Plus[1, Times[2, Power[x, 3]]]
```

### `standard`

Use this for the StandardForm subset that Tungsten understands. This is useful for plain-text
surface syntax like:

```text
f @ x // g
1 + 2 x^3
expr[[1]]
```

It also recognizes a pragmatic notebook-box subset when those boxes are represented textually:

```text
TagBox[SqrtBox["x"], DisplayForm]
FormBox[RadicalBox["x", "3"], TraditionalForm]
FractionBox[SuperscriptBox["x", "3"], RowBox[{"1", "+", "a", " ", "b"}]]
SubscriptBox["x", "i"]
RowBox[{"a", "\[CirclePlus]", "b"}]
```

These lower to ordinary Tungsten expressions such as:

```text
Power[x, Rational[1, 2]]
Power[x, Rational[1, 3]]
Times[Power[x, 3], Power[Plus[1, Times[a, b]], -1]]
Subscript[x, i]
CirclePlus[a, b]
```

The evaluator also exposes the corresponding conversion boundary through `ToBoxes`, `MakeBoxes`,
`MakeExpression`, `StripBoxes`, `SyntaxQ`, and `SyntaxLength`. These are kernel-free structural
approximations of the Wolfram functions: `MakeBoxes` is held, `ToBoxes` boxes evaluated input,
`MakeExpression` returns `HoldComplete[...]`, and `ToExpression[boxes]` uses the same supported
StandardForm box interpretation.

For pattern shorthand, Tungsten currently normalizes to explicit heads in canonical output. For
example:

```text
f[x_Integer, y_]
```

parses structurally as:

```text
f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]
```

## Output model

Both the CLI and the Python API expose a few useful normal forms.

### Canonical `input_form`

This is the subsystem's normalized textual rendering. It may differ from the exact original source
spelling if the parser inserts explicit grouping or canonical head-oriented formatting.

Example:

```text
1 + 2 x^3
```

may normalize to something like:

```text
1 + (2 * (x^3))
```

### Canonical `full_form`

This is the explicit head-based structural representation.

Example:

```text
Plus[1, Times[2, Power[x, 3]]]
```

For StandardForm box inputs, `full_form` is often the easiest way to confirm what Tungsten
understood semantically.

### `tree`

The CLI returns a structured AST dictionary for inspection and downstream automation.

## Python usage

```python
from tungsten.expression import evaluate
from tungsten.expression import parse_expression

expr = parse_expression("1 + 2 x^3", form="input")
expr.to_full_form()
# Plus[1, Times[2, Power[x, 3]]]

result = evaluate(parse_expression("Level[f[a, g[b]], -1]"))
result.to_full_form()
# List[a, b, g[b]]

match_result = evaluate(parse_expression("MatchQ[f[a, a], f[x_, x_]]"))
match_result.to_full_form()
# True

rewrite_result = evaluate(parse_expression("f[g[a]] /. g[x_] :> x"))
rewrite_result.to_full_form()
# f[a]

map_result = evaluate(parse_expression("Map[# + 1 &, {a, b}]"))
map_result.to_full_form()
# List[Plus[a, 1], Plus[b, 1]]

integer_sum = evaluate(parse_expression("1 + 2 + 3"))
integer_sum.to_full_form()
# 6
```

Convenience entrypoints include:

- `parse_input_form(...)`
- `parse_full_form(...)`
- `parse_standard_form(...)`
- `length(expr)`
- `depth(expr)`
- `first(expr)`
- `last(expr)`
- `rest(expr)`
- `most(expr)`
- `part(expr, ...)`
- `extract(expr, ...)`
- `level(expr, ...)`
- `match_q(expr, pattern)`
- `free_q(expr, pattern, spec=None)`
- `cases(expr, pattern_spec, spec=None, limit=None)`
- `delete_cases(expr, pattern, spec=None, limit=None)`
- `replace(expr, rules, spec=None)`
- `replace_all(expr, rules)`
- `replace_repeated(expr, rules)`
- `take(expr, spec)`
- `drop(expr, spec)`
- `append(expr, item)`
- `prepend(expr, item)`
- `join(expr1, expr2, ...)`
- `string_length(expr)`
- `string_take(expr, spec)`
- `string_drop(expr, spec)`
- `string_join(expr1, expr2, ...)`
- `string_insert(expr, item, positions)`
- `string_reverse(expr)`
- `string_position(expr, pattern, limit=None)`
- `string_contains_q(expr, pattern)`
- `reverse(expr)`
- `rotate_left(expr, n=1)`
- `rotate_right(expr, n=1)`
- `flatten(expr, n=None)`
- `delete(expr, positions)`
- `replace_at(expr, rules, positions)`
- `replace_part(expr, replacements)`
- `apply_head(head, expr)`
- `map_expr(f, expr)`
- `map_at(f, expr, positions)`
- `association(...)`
- `association_q(expr)`
- `keys_expr(assoc)`
- `values_expr(assoc)`
- `normal(assoc)`
- `lookup(assoc, key_spec, default=None)`
- `key_exists_q(assoc, key)`
- `key_member_q(assoc, key)`
- `key_take(assoc, key_spec)`
- `key_drop(assoc, key_spec)`
- `key_map(f, assoc)`
- `key_value_map(f, assoc)`
- `association_thread(keys, values)`
- `association_map(f, keys)`
- `evaluate(expr)`

## CLI usage

Parse without evaluating:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
python -m tungsten expr parse --code "1 + 2 x^3"
python -m tungsten expr parse --code "Rule[x, List[1, 2]]" --form fullform
python -m tungsten expr parse --code "f @ x // g" --form standard
python -m tungsten expr parse --code "\"a\" <> \"b\" <> \"c\""
```

Structurally evaluate implemented built-ins:

```powershell
python -m tungsten expr evaluate --code "Length[{a, b, c}]"
python -m tungsten expr evaluate --code '$ContextPath'
python -m tungsten expr evaluate --code 'Context[System`Plus]'
python -m tungsten expr evaluate --code '{Symbol["TungstenParser`alpha"], Names["TungstenParser`*"]}'
python -m tungsten expr evaluate --code "Level[f[a, g[b]], -1]"
python -m tungsten expr evaluate --code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
python -m tungsten expr evaluate --code "MatchQ[f[a, a], f[x_, x_]]"
python -m tungsten expr evaluate --code "Cases[{f[a], f[b]}, f[x_] :> x]"
python -m tungsten expr evaluate --code "DeleteCases[f[a, g[a]], a, Infinity]"
python -m tungsten expr evaluate --code "Replace[f[g[a]], x_ :> p[x], {0, Infinity}]"
python -m tungsten expr evaluate --code "If[1 < 2, 1 + 2, 9]"
python -m tungsten expr evaluate --code "Which[False, a, True, 1 + 2]"
python -m tungsten expr evaluate --code "Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"
python -m tungsten expr evaluate --code "Pick[f[a, b, c, d], {False, True, False, True}]"
python -m tungsten expr evaluate --code "Select[f[1, a, 2, 3], IntegerQ]"
python -m tungsten expr evaluate --code "SelectFirst[{1, a, 2, 3}, # > 1 &]"
python -m tungsten expr evaluate --code "Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"
python -m tungsten expr evaluate --code "TakeWhile[f[2, 4, 6, 7, 8], EvenQ]"
python -m tungsten expr evaluate --code "Mod[-14, 5]"
python -m tungsten expr evaluate --code "Clip[-7, {-5, 5}, {100, 200}]"
python -m tungsten expr evaluate --code "KroneckerDelta[3, 3, 3]"
python -m tungsten expr evaluate --code "f[g[a]] /. g[x_] :> x"
python -m tungsten expr evaluate --code "f[a] //. f[x_] :> x"
python -m tungsten expr evaluate --code "ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}]"
python -m tungsten expr evaluate --code "ReplacePart[f[a, b, c], 2 -> x]"
python -m tungsten expr evaluate --code "MapAt[g, f[a, h[b, c], d], {2, 1}]"
python -m tungsten expr evaluate --code "StringTake[\"abcdef\", {2, 5, 2}]"
python -m tungsten expr evaluate --code "StringJoin[{\"a\", {\"b\", \"c\"}}]"
python -m tungsten expr evaluate --code "StringMatchQ[\"catalog\", \"c\" ~~ __ ~~ \"g\"]"
python -m tungsten expr evaluate --code "StringCases[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
python -m tungsten expr evaluate --code "StringReplace[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
python -m tungsten expr evaluate --code "StringPosition[\"ababa\", \"a\" ~~ __ ~~ \"a\"]"
python -m tungsten expr evaluate --code "ImportString[\"{\\\"a\\\":1}\", \"JSON\"]"
python -m tungsten expr evaluate --code "ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {\"GZIP\", \"CSV\"}], {\"GZIP\", \"CSV\"}]"
python -m tungsten expr evaluate --code "ToExpression[ToString[HoldComplete[1 + 2], InputForm], InputForm]"
python -m tungsten expr evaluate --code 'ToExpression["f @ x // g", StandardForm, HoldComplete]'
python -m tungsten expr evaluate --code "Select[{\"ab\", \"cd\", \"ba\"}, StringContainsQ[\"a\"]]"
```

The parse payload includes:

- canonical `input_form`;
- canonical `full_form`;
- `depth`;
- `length`;
- the full `tree`.

The evaluate payload also includes:

- the original parsed forms;
- the final evaluated result in the same structured shape.

## PowerShell usage

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force

Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
```

These are thin wrappers over the CLI and return deserialized JSON objects, which makes them
convenient inside `pwsh` automation scripts.

## Evaluation model

Tungsten currently implements a broader structural subset that includes:

- core structural queries such as `Length`, `Depth`, `Head`, `Part`, `Extract`, and `Level`;
- pattern-search functions such as `MatchQ`, `FreeQ`, `Cases`, and `DeleteCases` over Tungsten's
  supported pattern subset;
- replacement functions such as `Replace`, `ReplaceAll`, and `ReplaceRepeated`, including the
  textual operator forms `/.` and `//.` that Tungsten lowers to named function calls during
  parsing;
- selection functions such as `Select`, `Discard`, `SelectFirst`, and `TakeWhile`, with
  association-aware value semantics and immediate-position `"Index"` properties for the supported
  property forms;
- explicit-number arithmetic and relational evaluation for heads such as `Rational`, `Complex`,
  `Plus`, `Times`, `Power`, `N`, `Precision`, `Accuracy`, `Equal`, `Less`, and their operator
  forms, without flattening or orderless normalization;
- simple predicate evaluation for heads such as `AtomQ`, `IntegerQ`, `NumberQ`, `StringQ`,
  `EvenQ`, `OddQ`, and `TrueQ`;
- hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`, where only the
  selected or retained branches are evaluated;
- evaluator-level non-local control for `Abort`, `Throw`, and `Catch`, including the Wolfram
  distinction between untagged throws caught by `Catch[expr]` and tagged throws caught by
  pattern-filtered `Catch[expr, form]` forms;
- scoped abort control for `CheckAbort` and `AbortProtect`, including deferred aborts that let
  protected statement sequences run cleanup before an outer `CheckAbort` observes the abort;
- scoped collection with `Sow` and `Reap`, including tag patterns, pattern-list grouping, nearest
  matching `Reap` behavior, and optional per-tag handler applications;
- practical timing control with `Pause`, `AbsoluteTiming`, `TimeConstrained`, and `TimeRemaining`;
  deadlines are checked at Tungsten evaluator boundaries and during `Pause`, rather than by
  asynchronously interrupting arbitrary host-language code;
- failure and confirmation control with `FailureQ`, `MissingQ`, `Enclose`, `Confirm`,
  `ConfirmBy`, `ConfirmMatch`, `ConfirmAssert`, `Failsafe`, and `Assert`; generated failures are
  ordinary `Failure[...]` expressions with property lookup support, while matching confirmations
  use evaluator signals so cleanup and enclosing handlers can observe them;
- cleanup-preserving evaluation with `WithCleanup`, including cleanup execution after Tungsten
  abort, throw, confirmation, exit, and time-constraint signals;
- message-oriented evaluation for `Check`, `Quiet`, `Message`, `$MessageList`, `MessageList`,
  `Off`, `On`, and `Print`; precondition failures emit non-fatal `Head::error` diagnostics and
  leave the failing expression in structural form;
- bounded numeric evaluation for explicit integers, rationals, reals, and complex numbers,
  including heads such as `UnitStep`, `Unitize`, `Sign`, `Abs`, `Re`, `Im`, `Conjugate`,
  `RealSign`, `RealAbs`, `Min`, `Max`, `Clip`, `KroneckerDelta`, `DiscreteDelta`, and `Ramp`;
- explicit-Boolean evaluation for `Not`, `And`, and `Or`, again without flattening or
  short-circuit behavior in this pass;
- positional pure-function applications such as `Function[body][arg]`, `body &[arg]`, and pure
  functions used as the function argument of `Map`, `MapAt`, and `Apply`;
- named pure-function applications such as `Function[x, body][arg]`, `x |-> body`, and
  `{x, y} |-> body`, including Tungsten's kernel-backed capture-avoiding renaming rule for nested
  named functions whose bodies are modified by outer pure-function application;
- sequence-style transforms such as `First`, `Last`, `Rest`, `Most`, `Take`, `Drop`, `Append`,
  `Prepend`, `Join`, `Reverse`, `RotateLeft`, `RotateRight`, `Flatten`, `Delete`, `ReplaceAt`,
  `ReplacePart`, `Apply`, `Map`, and `MapAt`;
- string structural sequence heads such as `StringLength`, `StringTake`, `StringDrop`,
  `StringJoin`, `StringInsert`, and `StringReverse`, plus symbolic string-pattern heads such as
  `StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`, `StringPosition`,
  `StringContainsQ`, `StringCases`, and `StringReplace`;
- practical kernel-free import / export heads such as `ImportString`, `ExportString`,
  `ImportByteArray`, and `ExportByteArray` over a documented subset of text, JSON, tabular, raw
  byte, and compression-wrapper formats;
- textual expression conversion through `ToString` and `ToExpression` for `InputForm` and the
  supported textual `StandardForm` subset;
- process-local symbol/context registry behavior for `Symbol`, `SymbolName`, `Unique`, `Names`,
  `NameQ`, `Contexts`, `Context`, `$Context`, `$ContextPath`, `Set`, `Unset`, `Clear`,
  `OwnValues`, and `ValueQ`;
- association-specific constructors and accessors such as `Association`, `AssociationQ`, `Keys`,
  `Values`, `Normal`, `Lookup`, `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`, `KeyMap`,
  `KeyValueMap`, `AssociationThread`, and `AssociationMap`.

Everything else is treated as an inert symbolic head.

Examples:

- `1 + 2` evaluates to `3`;
- `1 + 2 + a` evaluates to `Plus[3, a]`, while `Plus[1, 2, a]` stays inert;
- `True && False && x` evaluates to `And[False, x]`, while `And[True, False, x]` stays inert;
- `Length[1 + 2]` evaluates to `0`;
- `Part[f[a, b, c], {1, 3}]` evaluates to `f[a, c]`;
- `Level[f[a, g[b]], -1]` evaluates to `List[a, b, g[b]]`;
- `Position[f[a, g[b, a]], a]` evaluates to `List[List[1], List[2, 2]]`;
- `1 < 2 < 3` evaluates to `True`, while `1 < 3 < 2` evaluates to `False`;
- `f @ 1 + 2` evaluates to `Plus[f[1], 2]`;
- `{a, b, c, d, e}[[1 ;; 5 ;; 2]]` evaluates to `List[a, c, e]`;
- `{Sequence[1, 2], 3}` evaluates to `List[1, 2, 3]`;
- `Hold[Sequence[1 + 1, 2 + 2]]` evaluates to `Hold[Plus[1, 1], Plus[2, 2]]`, while
  `HoldComplete[Sequence[1 + 1, 2 + 2]]` keeps the `Sequence[...]` wrapper;
- `{Nothing, 1}` and `Cases[{1, 2, 3}, 2 :> Nothing]` evaluate to `List[1]` and `List[]`;
- `f[Nothing, 1]` keeps `Nothing` as an ordinary argument;
- `Hold[1 + 2]` evaluates to `Hold[Plus[1, 2]]`, and `ReleaseHold[Hold[1 + 2]]` evaluates to `3`;
- `MatchQ[f[a, a], f[x_, x_]]` evaluates to `True`;
- `Cases[f[g[a]], _, {0, Infinity}]` evaluates to `List[a, g[a], f[g[a]]]`;
- `If[1 < 2, 1 + 2, 9]` evaluates to `3`, while `If[x, 1 + 2, 9]` stays structurally inert;
- `Which[False, a, True, 1 + 2]` evaluates to `3`;
- `Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]` evaluates to `Piecewise[{{2, x}}, 4]`;
- `Pick[f[a, b, c, d], {False, True, False, True}]` evaluates to `f[b, d]`;
- `f[g[a]] /. g[x_] :> x` evaluates to `f[a]`;
- `f[a] //. f[x_] :> x` evaluates to `a`;
- `Map[# + 1 &, {a, b}]` evaluates to `List[Plus[a, 1], Plus[b, 1]]`;
- `(x |-> y |-> x[y])[y]` evaluates to `Function[y$, y[y$]]`;
- `Select[f[1, a, 2, 3], IntegerQ]` evaluates to `f[1, 2, 3]`;
- `Select[{1, a, 2, 3}, # > 1 & -> {"Element", "Index"}]` evaluates to
  `<|"Element" -> {2, 3}, "Index" -> {3, 4}|>`;
- `Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]` evaluates to `<|b -> x, c -> 2|>`;
- `TakeWhile[f[2, 4, 6, 7, 8], EvenQ]` evaluates to `f[2, 4, 6]`;
- `StringJoin[{"a", {"b", "c"}}]` evaluates to `"abc"`, and `"a" <> "b" <> "c"` parses to
  nested `StringJoin[...]` calls before evaluating to `"abc"`;
- `StringMatchQ["catalog", "c" ~~ __ ~~ "g"]` evaluates to `True`;
- `StringCases["abc123def", x : DigitCharacter.. :> "[" <> x <> "]"]` evaluates to `{"[123]"}`;
- `StringReplace["abc123def", x : DigitCharacter.. :> "[" <> x <> "]"]` evaluates to
  `"abc[123]def"`;
- `StringPosition["ababa", "a" ~~ __ ~~ "a"]` evaluates to `{{1, 5}, {3, 5}}`;
- `ImportString["{\"a\":1}", "JSON"]` evaluates to `{"a" -> 1}`;
- `ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {"GZIP", "CSV"}], {"GZIP", "CSV"}]`
  evaluates to `{{1, 2}, {3, 4}}`;
- `ToExpression[ToString[HoldComplete[1 + 2], InputForm], InputForm]` evaluates to
  `HoldComplete[1 + 2]`;
- `ToExpression["f @ x // g", StandardForm, HoldComplete]` evaluates to `HoldComplete[g[f[x]]]`;
- <code>{Symbol["TungstenParser`alpha"], Names["TungstenParser`*"]}</code> evaluates to
  <code>{TungstenParser`alpha, {"TungstenParser`alpha"}}</code>;
- `x = 1 + 2; {ValueQ[x], OwnValues[x], x}` evaluates to
  `{True, {HoldPattern[x] :> 3}, 3}`;
- `x = 1; x = .; ValueQ[x]` evaluates to `False`;
- `Select[{"ab", "cd", "ba"}, StringContainsQ["a"]]` evaluates to `{"ab", "ba"}`;
- `Mod[-14, 5]` evaluates to `1`;
- `Clip[-7, {-5, 5}, {100, 200}]` evaluates to `100`;
- `KroneckerDelta[3, 3, 3]` evaluates to `1`;
- `Part[<|a -> x, b -> y|>, Key[b]]` evaluates to `y`;
- `<|"name" -> x|>["name"]` evaluates to `x`;
- `KeyMap[Identity, <|a -> 1|>]` evaluates to `<|a -> 1|>`;
- `Map[g, <|a -> 1, b -> 2|>]` evaluates to `<|a -> g[1], b -> g[2]|>`;
- `Delete[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]` evaluates to `{<|a -> 1, b -> {2}|>, 9}`.

That design keeps the subsystem honest: it is useful for structural analysis and manipulation
without pretending to reproduce arbitrary kernel semantics.

## Current limits

The current subsystem does not aim to support:

- full box language;
- arbitrary StandardForm notebook surface syntax;
- general evaluation;
- definitions, mutable attributes, or user-created transformation rules;
- package loading or notebook-scoped semantics.

## Known kernel divergences

These are intentional current boundaries, not hidden TODOs:

- `Plus`, `Times`, `And`, and `Or` are not given `Flat`, `Orderless`, `OneIdentity`,
  short-circuit, or `Listable` attributes. Direct mixed calls such as `Plus[1, 2, a]` stay inert,
  while nested infix forms can still simplify one parsed layer at a time.
- The parser now gives same-head comparison chains Wolfram-style n-ary shapes, but it still keeps
  arithmetic and Boolean operator chains as ordinary nested calls. This preserves Tungsten's
  explicit no-`Flat` evaluator contract.
- Empty `Min[]` and `Max[]` currently render as `Infinity` and `-Infinity` rather than Wolfram's
  `DirectedInfinity[1]` and `DirectedInfinity[-1]` FullForm spelling.
- Real-number precision marks using backticks are parsed as part of the accepted real literal text,
  but Tungsten does not reproduce every kernel `FullForm` nuance for precision-bearing reals.
- Prefix `++` and `--` now parse as `PreIncrement` and `PreDecrement`, including literal operands
  such as `--5`; Tungsten still leaves those side-effectful heads inert during evaluation.
- Pattern search through associations follows Wolfram's values-only convention: `FreeQ`, `Cases`,
  `DeleteCases`, `Position`, `MemberQ`, and `FirstCase` descend into values and can match whole
  associations, but they do not search keys or raw `Rule` wrappers. Use `KeyValuePattern` for
  entry-level matching that intentionally sees keys.

Common Wolfram `Listable` heads that stay inert on list arguments include `Plus`, `Times`, `Power`,
`Equal`, `Less`, `LessEqual`, `Greater`, `GreaterEqual`, `UnitStep`, `Unitize`, `Sign`, `Abs`,
`RealSign`, `RealAbs`, `Mod`, `Quotient`, `Min`, `Max`, `Clip`, `KroneckerDelta`,
`DiscreteDelta`, and `Ramp`. Use `Map`, `MapThread`, or explicit structural code when you want
that behavior offline.

Association pattern traversal deliberately does not expose keys to ordinary search. This matches the
kernel's values-only association model and keeps `FreeQ[<|a -> 1|>, a]` true while still allowing
`KeyValuePattern[a -> _]` to match the entry explicitly. `Position` emits association value paths
with `Key[key]` components so the paths can be reused by `Extract`, `ReplacePart`, and `MapAt`.

Pure functions are still deliberately bounded in this pass, but the common argument machinery is now
covered. Tungsten supports positional slots, `SlotSequence` / `##`, named-parameter forms, and the
evaluation-impact subset of `Function[params, body, attrs]`. `Function[Null, body]` and
`Function[Null, body, attrs]` are positional-slot functions with an explicit parameter placeholder.
Supported attributes are `HoldFirst`, `HoldRest`, `HoldAll`, `HoldAllComplete`, `SequenceHold`,
and `Listable`; other attribute names are preserved in the syntax but have no evaluator effect yet.
Tungsten keeps function bodies inert until application, so pure functions can safely contain
patterns such as `MatchQ[#, _Integer] &`.

`Pick` is also intentionally narrower than the full kernel: Tungsten supports compatible selector
shapes well, including the common list/head-preserving and association-by-position cases, but it
does not aim to reproduce every scalar-selector corner case from the Wolfram Language.

Those boundaries are intentional. If you need them, use the real kernel-backed Tungsten flows.
