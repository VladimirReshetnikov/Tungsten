# Tungsten Symbol and Context Registry

- Status: Normative for Tungsten's current kernel-free symbol registry
- Audience: Tungsten maintainers, expression-subsystem users, automation authors, and reviewers
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-25T17:48:49Z
- Updated (UTC): 2026-04-25T20:58:10Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Structural Expression Function Support](./expression-function-support.md)
  - [Usage Reference](./usage-reference.md)

## Purpose

Tungsten now has a process-local symbol and context registry for kernel-free expression work. The
registry gives the inert evaluator enough name awareness to support common Wolfram name-management
functions without launching a kernel. It also carries a read-only Wolfram 14.3
<code>System`</code> symbol catalog and per-symbol attribute metadata so discovery functions can
see installed built-ins even when Tungsten has no evaluator rule for them.

The registry is not a package loader and does not attempt to mirror a complete mutable live kernel
session. It is a structural service for parsing, rendering, name lookup, context lookup,
generated-symbol allocation, and read-only built-in attribute lookup inside one Tungsten Python
process.

## Registry Model

Every registered symbol has a `SymbolRecord` containing:

- `full_name`: the fully qualified Wolfram name, such as <code>System`Plus</code> or
  <code>Global`x</code>;
- `context`: the context prefix including the trailing backtick, such as <code>System`</code>;
- `short_name`: the final symbol name without context;
- `built_in`: whether Tungsten seeded the record as part of its <code>System`</code> built-in
  surface;
- `attributes`: a tuple of Wolfram attribute names, such as `Protected`, `HoldAll`, `Flat`, or
  `Listable`;
- `own_value`, `down_values`, `up_values`, and `sub_values`: reserved for future value and rule
  support.

The current registry is initialized with:

- <code>$Context = "Global`"</code>;
- <code>$ContextPath = {"System`", "Global`"}</code>;
- a generated Wolfram 14.3 snapshot at
  `src/tungsten/data/system_symbols_wolfram_14_3.json`, currently containing 7800 immediate
  <code>System`</code> symbols from <code>Names["System`*"]</code>;
- the exact read-only attribute list reported by the installed Wolfram 14.3 kernel for each of
  those immediate <code>System`</code> symbols;
- a small explicit fallback seed for the evaluator's built-in heads, used only if the generated
  snapshot is absent in an unusual source layout.

The snapshot intentionally excludes nested contexts below <code>System`</code>. It mirrors the
machine-local Wolfram 14.3 top-level system symbol catalog for discovery purposes, not the full set
of packages and contexts that a live session could load later.

## Name Resolution

Tungsten follows the same broad direction as the Wolfram kernel:

- an explicit name with a context mark, such as <code>MyContext`x</code>, resolves to that exact
  full name;
- an unqualified name first searches visible contexts from `$ContextPath`;
- if an unqualified name is not already visible, it resolves into the current context;
- valid symbol short names start with a letter or `$`, and then contain letters, digits, or `$`;
- valid contexts are one or more valid symbol-name components separated by backticks and ending in
  a backtick.

Rendered names use visible-context elision:

- records in <code>System`</code> or <code>Global`</code> render by short name, because both
  contexts are on the fixed `$ContextPath`;
- records in non-visible contexts render as fully qualified names;
- <code>Names["System`Plus"]</code> therefore returns `"Plus"`, while
  <code>Names["TungstenExample`*"]</code> returns fully qualified strings such as
  <code>"TungstenExample`alpha"</code>.

The registry is process-local. A single expression evaluation can create a symbol and query it
later in the same expression, but separate `python -m tungsten expr evaluate ...` invocations start
with a fresh registry.

## Supported Functions

The current kernel-free evaluator implements these symbol and context functions:

- `Symbol["name"]` validates and registers a symbol, then returns it using visible-context display
  rules.
- `SymbolName[sym]` returns the short name for a symbol. String inputs are accepted when they name
  an existing symbol or contain an explicit valid context.
- `Context[]` returns the fixed current context. `Context[sym]` returns the symbol context.
  Tungsten also accepts string names for registered symbols as a practical scripting convenience.
- `$Context` evaluates to <code>"Global`"</code>. Assignment to `$Context` is not implemented.
- `$ContextPath` evaluates to <code>{"System`", "Global`"}</code>. Assignment to `$ContextPath` is not
  implemented.
- `Contexts[]` returns contexts currently known to the registry. `Contexts["pattern"]` filters
  those contexts.
- `Names[]` returns currently known visible names. `Names["pattern"]` or a list of string patterns
  filters registered symbol names.
- `NameQ["pattern"]` returns `True` when `Names["pattern"]` would produce at least one result.
- `Attributes[sym]`, `Attributes["name"]`, and `Attributes[{s1, s2, ...}]` return read-only
  attribute metadata from the registry. Unknown user symbols return an empty list until Tungsten
  grows mutable attributes.
- `Unique[]`, `Unique[sym]`, `Unique["prefix"]`, and list forms generate fresh registered symbols.
- `ValueQ[expr]` returns `True` for explicit numeric, string, and byte-array literals, for
  `$Context` and `$ContextPath`, and
  for expressions that Tungsten's evaluator can reduce to a different expression. This is a
  conservative kernel-free subset: unreduced calls whose Wolfram kernel value depends on attributes
  or other built-in definitions may still return `False` until Tungsten has real value/rule
  storage. User-defined symbols currently have no values, so `ValueQ[userSymbol]` returns `False`.

Name-pattern matching supports the practical string-pattern subset used by Wolfram name functions:

- `*` matches any sequence of characters;
- `@` matches one or more characters that are not uppercase ASCII letters;
- backslash escapes the next character literally.

## Current Boundaries

The registry intentionally does not yet implement:

- mutable `$Context` or `$ContextPath`;
- `Begin`, `BeginPackage`, `End`, `Needs`, package loading, shadowing diagnostics, or context
  aliases;
- `SetAttributes`, `ClearAttributes`, or mutation through assignment to `Attributes[s]`;
- evaluator-wide semantics for arbitrary registered attributes such as `Flat`, `Orderless`,
  `OneIdentity`, `NHoldAll`, or `Protected`;
- own values, down values, up values, sub values, delayed definitions, or assignment forms;
- persistent registry state across separate Tungsten CLI processes.

These boundaries are structural, not accidental. `Attributes` is currently a metadata lookup API:
it tells callers what attributes Wolfram 14.3 reports for a symbol, while Tungsten's evaluator
only gives operational meaning to the small number of attributes that earlier structural features
already handle explicitly, such as selected third-argument `Function` attributes.

## Examples

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)

python -m tungsten expr evaluate --code '$Context'
python -m tungsten expr evaluate --code '$ContextPath'
python -m tungsten expr evaluate --code 'Context[System`Plus]'
python -m tungsten expr evaluate --code '{Symbol["TungstenExample`alpha"], Names["TungstenExample`*"]}'
python -m tungsten expr evaluate --code 'NameQ["Plus"]'
python -m tungsten expr evaluate --code 'NameQ["System`AASTriangle"]'
python -m tungsten expr evaluate --code 'Length[Names["System`*"]]'
python -m tungsten expr evaluate --code 'Attributes[Plus]'
python -m tungsten expr evaluate --code 'Attributes[{Attributes, Plus, AASTriangle}]'
python -m tungsten expr evaluate --code 'ValueQ[userDefinedSymbol]'
python -m tungsten expr evaluate --code 'Unique[temporarySymbol]'
```

## Regenerating the System Snapshot

The snapshot is generated from the installed Wolfram 14.3 kernel rather than hand-authored:

```powershell
pwsh -File .\src\Tungsten\scripts\Update-TungstenSystemSymbolSnapshot.ps1
```

The generator records <code>Names["System`*"]</code> entries that do not themselves contain a
backtick and uses <code>Attributes[Evaluate["System`" <> name]]</code> to account for the fact that `Attributes` has
`HoldAll`. The JSON file is package data, so editable source runs and installed wheels use the
same registry seed.

## Reference Material

Implementation choices were checked against the corresponding Wolfram documentation pages:

- [Symbol](https://reference.wolfram.com/language/ref/Symbol.html)
- [SymbolName](https://reference.wolfram.com/language/ref/SymbolName.html)
- [Unique](https://reference.wolfram.com/language/ref/Unique.html)
- [Names](https://reference.wolfram.com/language/ref/Names.html)
- [NameQ](https://reference.wolfram.com/language/ref/NameQ.html)
- [Attributes](https://reference.wolfram.com/language/ref/Attributes.html)
- [Contexts](https://reference.wolfram.com/language/ref/Contexts.html)
- [Context](https://reference.wolfram.com/language/ref/Context.html)
- [$Context](https://reference.wolfram.com/language/ref/%24Context.html)
- [$ContextPath](https://reference.wolfram.com/language/ref/%24ContextPath.html)
- [ValueQ](https://reference.wolfram.com/language/ref/ValueQ.html)
