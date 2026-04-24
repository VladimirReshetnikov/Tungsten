# Tungsten Expression Parser

Created (UTC): 2026-04-23T14:55:38Z
Updated (UTC): 2026-04-24T04:24:45Z
Repository HEAD: 078e521a368bd61c48df4bd9bb25ebac45ee6215

## Summary

`expression.py` gives Tungsten a real kernel-free Wolfram expression subsystem. It provides:

- an AST for atoms and general expressions;
- parsers for FullForm, InputForm, and a pragmatic StandardForm subset;
- canonical `InputForm` and `FullForm` rendering;
- an inert evaluator for structural built-ins such as `Length`, `Depth`, `Head`, `Part`,
  `Extract`, `Level`, integer-only arithmetic and relational heads such as `Plus`, `Times`,
  `Power`, `Equal`, and `Less`, simple predicates such as `IntegerQ`, `StringQ`, and `EvenQ`,
  hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`, integer-only numeric
  heads such as `UnitStep`, `Mod`, `Clip`, and `KroneckerDelta`, Boolean heads such as `Not`,
  `And`, and `Or`, `MatchQ`, `FreeQ`, `Cases`, `DeleteCases`, `Replace`, `ReplaceAll`,
  `ReplaceRepeated`, `Function`, `Pick`, `Select`, `Discard`, `SelectFirst`, `TakeWhile`, `Take`,
  `Drop`, `Flatten`, `ReplaceAt`, `ReplacePart`, association constructors, key accessors, and
  related exact-position transforms;
- preservation of Wolfram string literals that contain embedded inline box escapes such as
  `\!\(\*GraphicsBox[...]\)`.

The important constraint is deliberate: this is not a replacement for the Wolfram kernel. Unknown
symbols stay inert, and Tungsten only evaluates the specific built-ins it implements itself.

For the exact supported structural function list, supported forms, and official Wolfram reference
links, read [expression-function-support.md](./expression-function-support.md).

## When to use this subsystem

Use the expression subsystem when you want:

- structural analysis without launching a kernel;
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

- symbols, strings, integers, and reals;
- function application `head[arg1, arg2]`;
- lists `{a, b, c}`;
- associations `<|a -> b|>`;
- common pattern shorthand such as `_`, `_Head`, `x_`, `x_Head`, `patt /; test`, and `a | b`;
- association-aware exact selectors such as `Key[b]` and string-key shorthand `"name"` inside
  part and extract specifications;
- arithmetic syntax such as `+`, unary `-`, implicit `Times`, `/`, and `^`;
- rules `->` and `:>`, including guarded delayed-rule right-hand sides such as
  `x_ :> rhs /; test`;
- comparisons and boolean operators;
- prefix and postfix application such as `f @ x` and `x // f`;
- mapping and replacement operators such as `/@`, `/.`, and `//.`;
- positional pure-function syntax such as `body &`, `#`, `#n`, `#0`, `Slot[]`, `Slot[n]`, and
  the Tungsten-specific shorthand `#name` for `#1["name"]`;
- part syntax `expr[[...]]`;
- span syntax `a ;; b ;; c`;
- nested Wolfram comments `(* ... *)`;
- common semantic notebook boxes when they appear as textual box expressions:
  `FractionBox`, `SqrtBox`, `RadicalBox`, `SuperscriptBox`;
- common wrapper boxes around those semantic forms, including `BoxData`, `FormBox`, `StyleBox`,
  `TagBox`, `TooltipBox`, and `InterpretationBox`;
- `RowBox` reconstruction for the box-driven subset above, so notebook snippets such as
  `SuperscriptBox["x", RowBox[{"1", "/", "3"}]]` or
  `FractionBox[SuperscriptBox["x", "3"], RowBox[{"1", "+", "a", " ", "b"}]]` lower to ordinary
  Tungsten expressions;
- `RowBox`-based association examples from the installed `Association.nb` reference page,
  including `\[Rule]`, `\[RuleDelayed]`, `\[LeftAssociation]`, and `\[RightAssociation]`
  tokens plus nested part syntax such as `<|a -> x|>[[Key[b]]]`.
- string literals that contain inline-box escape sequences.

The parser does not attempt to cover full box language or every textual corner of Mathematica. In
particular, it is intentionally conservative around advanced pattern syntax, arbitrary box
constructs, named-parameter function forms, assignments, and broader evaluation semantics.

The currently supported pattern subset is intentionally bounded:

- supported: `Blank`, anonymous `BlankSequence` / `BlankNullSequence` via `__`, `___`, optional
  head-qualified forms such as `__Integer`, named patterns over `Blank`, guarded patterns via
  `Condition` / `/;`, `Alternatives`, `Except`, `HoldPattern`, and `Verbatim`;
- not yet supported: named sequence patterns such as `x__` or `Pattern[x, BlankSequence[]]`,
  multiple `__` / `___` patterns in the same argument list, `PatternTest`, `Optional`,
  options-related pattern forms, and other advanced matching constructs.

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
```

These lower to ordinary Tungsten expressions such as:

```text
Power[x, Rational[1, 2]]
Power[x, Rational[1, 3]]
Times[Power[x, 3], Power[Plus[1, Times[a, b]], -1]]
```

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
# List[a, b]

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
```

Structurally evaluate implemented built-ins:

```powershell
python -m tungsten expr evaluate --code "Length[{a, b, c}]"
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
- integer-only arithmetic and relational evaluation for heads such as `Plus`, `Times`, `Power`,
  `Equal`, `Less`, and their operator forms, without flattening or orderless normalization;
- simple predicate evaluation for heads such as `IntegerQ`, `StringQ`, `EvenQ`, `OddQ`, and `TrueQ`;
- hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`, where only the
  selected or retained branches are evaluated;
- integer-only numeric evaluation for heads such as `UnitStep`, `Unitize`, `Sign`, `Abs`,
  `RealSign`, `RealAbs`, `Mod`, `Quotient`, `QuotientRemainder`, `Min`, `Max`, `Clip`,
  `KroneckerDelta`, `DiscreteDelta`, and `Ramp`;
- explicit-Boolean evaluation for `Not`, `And`, and `Or`, again without flattening or
  short-circuit behavior in this pass;
- positional pure-function applications such as `Function[body][arg]`, `body &[arg]`, and pure
  functions used as the function argument of `Map`, `MapAt`, and `Apply`;
- sequence-style transforms such as `First`, `Last`, `Rest`, `Most`, `Take`, `Drop`, `Append`,
  `Prepend`, `Join`, `Reverse`, `RotateLeft`, `RotateRight`, `Flatten`, `Delete`, `ReplaceAt`,
  `ReplacePart`, `Apply`, `Map`, and `MapAt`;
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
- `Level[f[a, g[b]], -1]` evaluates to `List[a, b]`;
- `MatchQ[f[a, a], f[x_, x_]]` evaluates to `True`;
- `Cases[f[g[a]], _, {0, Infinity}]` evaluates to `List[a, g[a], f[g[a]]]`;
- `If[1 < 2, 1 + 2, 9]` evaluates to `3`, while `If[x, 1 + 2, 9]` stays structurally inert;
- `Which[False, a, True, 1 + 2]` evaluates to `3`;
- `Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]` evaluates to `Piecewise[{{2, x}}, 4]`;
- `Pick[f[a, b, c, d], {False, True, False, True}]` evaluates to `f[b, d]`;
- `f[g[a]] /. g[x_] :> x` evaluates to `f[a]`;
- `f[a] //. f[x_] :> x` evaluates to `a`;
- `Map[# + 1 &, {a, b}]` evaluates to `List[Plus[a, 1], Plus[b, 1]]`;
- `Select[f[1, a, 2, 3], IntegerQ]` evaluates to `f[1, 2, 3]`;
- `Select[{1, a, 2, 3}, # > 1 & -> {"Element", "Index"}]` evaluates to
  `<|"Element" -> {2, 3}, "Index" -> {3, 4}|>`;
- `Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]` evaluates to `<|b -> x, c -> 2|>`;
- `TakeWhile[f[2, 4, 6, 7, 8], EvenQ]` evaluates to `f[2, 4, 6]`;
- `Mod[-14, 5]` evaluates to `1`;
- `Clip[-7, {-5, 5}, {100, 200}]` evaluates to `100`;
- `KroneckerDelta[3, 3, 3]` evaluates to `1`;
- `Part[<|a -> x, b -> y|>, Key[b]]` evaluates to `y`;
- `Map[g, <|a -> 1, b -> 2|>]` evaluates to `<|a -> g[1], b -> g[2]|>`;
- `Delete[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]` evaluates to `{<|a -> 1, b -> {2}|>, 9}`.

That design keeps the subsystem honest: it is useful for structural analysis and manipulation
without pretending to reproduce arbitrary kernel semantics.

## Current limits

The current subsystem does not aim to support:

- full box language;
- arbitrary StandardForm notebook surface syntax;
- general evaluation;
- definitions, attributes, or user-created transformation rules;
- package loading or notebook-scoped semantics.

One additional current boundary matters for pattern workflows: association-aware pattern traversal is
not implemented yet. In this pass, search functions such as `FreeQ`, `Cases`, and `DeleteCases`
treat associations as opaque leaves rather than descending into keys or values.

Replacement functions are less conservative than those search functions. `Replace` traverses
association values, `ReplaceAll` and `ReplaceRepeated` traverse association heads and values, and
`ReplaceAt` supports key-aware exact paths into association values.

Pure functions are also deliberately bounded in this pass: only positional slot forms are
implemented, not named-parameter `Function[{x, ...}, body]`, `SlotSequence`, or `##`. Tungsten
does, however, keep `Function[body]` inert until application, so pure functions can safely contain
patterns such as `MatchQ[#, _Integer] &`.

`Pick` is also intentionally narrower than the full kernel: Tungsten supports compatible selector
shapes well, including the common list/head-preserving and association-by-position cases, but it
does not aim to reproduce every scalar-selector corner case from the Wolfram Language.

Those boundaries are intentional. If you need them, use the real kernel-backed Tungsten flows.
