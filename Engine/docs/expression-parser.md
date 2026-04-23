# Tungsten Expression Parser

Created (UTC): 2026-04-23T14:55:38Z
Updated (UTC): 2026-04-23T21:12:16Z
Repository HEAD: e5c1e2b48eea1534033dbf6bcd549b2059db91e7

## Summary

`expression.py` gives Tungsten a real kernel-free Wolfram expression subsystem. It provides:

- an AST for atoms and general expressions;
- parsers for FullForm, InputForm, and a pragmatic StandardForm subset;
- canonical `InputForm` and `FullForm` rendering;
- an inert evaluator for structural built-ins such as `Length`, `Depth`, `Head`, `Part`,
  `Extract`, `Level`, `Take`, `Drop`, `Flatten`, `ReplacePart`, association constructors, key
  accessors, and related exact-position transforms;
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
- association-aware exact selectors such as `Key[b]` and string-key shorthand `"name"` inside
  part and extract specifications;
- arithmetic syntax such as `+`, unary `-`, implicit `Times`, `/`, and `^`;
- rules `->` and `:>`;
- comparisons and boolean operators;
- prefix and postfix application such as `f @ x` and `x // f`;
- mapping and replacement operators such as `/@`, `/.`, and `//.`;
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
constructs, pure-function shorthand, assignments, and broader evaluation semantics.

## Parsing forms

### `input`

Use this for normal textual Wolfram input such as:

```text
1 + 2 x^3
f[a, b] /. x -> y
expr[[1 ;; 3]]
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
- sequence-style transforms such as `First`, `Last`, `Rest`, `Most`, `Take`, `Drop`, `Append`,
  `Prepend`, `Join`, `Reverse`, `RotateLeft`, `RotateRight`, `Flatten`, `Delete`, `ReplacePart`,
  `Apply`, `Map`, and `MapAt`;
- association-specific constructors and accessors such as `Association`, `AssociationQ`, `Keys`,
  `Values`, `Normal`, `Lookup`, `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`, `KeyMap`,
  `KeyValueMap`, `AssociationThread`, and `AssociationMap`.

Everything else is treated as an inert symbolic head.

Examples:

- `1 + 2` parses as `Plus[1, 2]` and stays that way;
- `Length[1 + 2]` evaluates to `2`;
- `Part[f[a, b, c], {1, 3}]` evaluates to `f[a, c]`;
- `Level[f[a, g[b]], -1]` evaluates to `List[a, b]`;
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

Those boundaries are intentional. If you need them, use the real kernel-backed Tungsten flows.
