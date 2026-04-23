# Tungsten Expression Parser

Created (UTC): 2026-04-23T14:55:38Z  
Updated (UTC): 2026-04-23T14:55:38Z  
Repository HEAD: 57ab7a5664bc31c13cc3fad044e00d2246b0f07e

## What this subsystem is for

`expression.py` gives Tungsten a real kernel-free Wolfram expression model:

- an AST for atoms and general expressions;
- parsers for FullForm, InputForm, and a box-free StandardForm subset;
- canonical `FullForm` and `InputForm` rendering;
- a small inert evaluator for structural built-ins such as `Length`, `Depth`, `Head`, `Part`, `Extract`, and `Level`.

The important constraint is deliberate: this is not a replacement for the Wolfram kernel. Unknown symbols stay inert, and Tungsten only evaluates the specific built-ins it implements itself.

## Supported syntax

The parser currently handles:

- symbols, strings, integers, and reals;
- function application `head[arg1, arg2]`;
- lists `{a, b, c}`;
- associations `<|a -> b|>`;
- arithmetic syntax such as `+`, `-`, implicit `Times`, `/`, and `^`;
- rules `->` and `:>`;
- comparisons and boolean operators;
- prefix and postfix application such as `f @ x` and `x // f`;
- mapping and replacement operators such as `/@`, `/.`, and `//.`;
- part syntax `expr[[...]]`;
- span syntax `a ;; b ;; c`;
- nested Wolfram comments `(* ... *)`.

The parser does not attempt to cover full box language or every textual corner of Mathematica. In particular, it is intentionally conservative around advanced pattern syntax, pure-function shorthand, assignments, and broader evaluation semantics.

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

Convenience entrypoints:

- `parse_input_form(...)`
- `parse_full_form(...)`
- `parse_standard_form(...)`
- `length(expr)`
- `depth(expr)`
- `part(expr, ...)`
- `extract(expr, ...)`
- `level(expr, ...)`
- `evaluate(expr)`

## CLI usage

Parse without evaluating:

```powershell
$env:PYTHONPATH = (Resolve-Path C:\Tools1\Tools\src\Tungsten\src)
python -m tungsten expr parse --code "1 + 2 x^3"
```

Structurally evaluate implemented built-ins:

```powershell
python -m tungsten expr evaluate --code "Level[f[a, g[b]], -1]"
python -m tungsten expr evaluate --code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
```

The parse payload includes canonical `input_form`, canonical `full_form`, `depth`, `length`, and the full AST tree. The evaluate payload also includes the original parsed forms plus the final evaluated result.

## PowerShell usage

```powershell
Import-Module C:\Tools1\Tools\src\Tungsten\pwsh\Tungsten.psd1 -Force

Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
```

These are thin wrappers over the CLI and return deserialized JSON objects, which makes them convenient inside `pwsh` automation scripts.

## Evaluation model

Tungsten currently implements structural rules for:

- `Length`
- `Depth`
- `Head`
- `Part`
- `Extract`
- `Level`

Everything else is treated as an inert symbolic head. For example:

- `1 + 2` parses as `Plus[1, 2]` and stays that way;
- `Length[1 + 2]` evaluates to `2`;
- `Part[f[a, b, c], {1, 3}]` evaluates to `f[a, c]`;
- `Level[f[a, g[b]], -1]` evaluates to `List[a, b]`.

That design keeps the subsystem honest: it is useful for structural analysis and manipulation, without pretending to reproduce arbitrary kernel semantics.
