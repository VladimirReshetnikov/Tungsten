# Tungsten Symbol and Context Registry

- Status: Normative for Tungsten's current kernel-free symbol registry
- Audience: Tungsten maintainers, expression-subsystem users, automation authors, and reviewers
- Scope: `Engine/cpp/src/evaluator.cpp`, `Engine/cpp/src/expression.cpp`, and the bundled symbol snapshot
- Created (UTC): 2026-04-25T17:48:49Z
- Updated (UTC): 2026-07-18T01:40:01Z
- Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Structural Expression Function Support](./expression-function-support.md)
  - [Usage Reference](./usage-reference.md)

## Purpose

Tungsten now has a process-local symbol and context registry for kernel-free expression work. The
registry gives the inert evaluator enough name awareness to support common Wolfram name-management
functions without launching a kernel. It also carries a Wolfram 15.0 <code>System`</code> symbol
catalog and mutable per-symbol attribute metadata so discovery functions can see installed
built-ins and the evaluator can honor common attributes even when Tungsten has no specialized
evaluator rule for a symbol.

The registry is not a package loader and does not attempt to mirror a complete mutable live kernel
session. It is a structural service for parsing, rendering, name lookup, context lookup,
generated-symbol allocation, own-value storage, and attribute-aware evaluation inside one native
Tungsten process.

## Registry Model

The native registry is intentionally compact and distributed across the expression runtime rather
than exposed as a Python-style `SymbolRecord` object:

- CMake embeds the generated <code>System`</code> symbol and attribute snapshots into the native
  library;
- name/context helpers resolve visible short names against <code>System`</code> and
  <code>Global`</code> and retain explicitly qualified names;
- `Evaluator` owns immediate values plus ordered down-, up-, and sub-value definition tables for
  the lifetime of that evaluator instance;
- mutable attributes are stored separately from the immutable bundled startup attributes;
- `EvaluationSession` retains one evaluator across REPL inputs, while separate `expr evaluate`
  processes start with fresh mutable state.

The current registry is initialized with:

- <code>$Context = "Global`"</code>;
- <code>$ContextPath = {"System`", "Global`"}</code>;
- a generated Wolfram 15.0 snapshot at
  `src/tungsten/data/system_symbols_wolfram_15_0.json`, currently containing 7935 immediate
  <code>System`</code> symbols from <code>Names["System`*"]</code>;
- the exact startup attribute list reported by the installed Wolfram 15.0 kernel for each of those
  immediate <code>System`</code> symbols;
- a small explicit fallback seed for the evaluator's built-in heads, used only if the generated
  snapshot is absent in an unusual source layout.

The snapshot intentionally excludes nested contexts below <code>System`</code>. It mirrors the
machine-local Wolfram 15.0 top-level system symbol catalog for discovery purposes, not the full set
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
later in the same expression, but separate `tungsten-cpp expr evaluate ...` invocations start
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
- `Attributes[sym]`, `Attributes["name"]`, and `Attributes[{s1, s2, ...}]` return attribute
  metadata from the registry. `Attributes[sym] = attrs` replaces mutable attributes for a symbol
  target.
- `SetAttributes[sym, attrs]` and `ClearAttributes[sym, attrs]` add and remove known attributes
  for symbols or symbol lists. `Protected` does not block attribute mutation, but `Locked` does.
- `Protect` and `Unprotect` add or remove `Protected` and return the changed symbol names as
  strings. String-pattern forms operate through `Names[pattern]`.
- `Unique[]`, `Unique[sym]`, `Unique["prefix"]`, and list forms generate fresh registered symbols.
- `Set[sym, rhs]` / `sym = rhs` stores an immediate own value for a bare, unprotected symbol.
  The right-hand side is evaluated before storage, matching Wolfram's immediate-assignment model.
- `Set[f[args], rhs]` / `f[args] = rhs` stores an immediate down value for the symbol `f`.
  Ordinary LHS arguments are evaluated after the RHS is evaluated, and the defined head's
  attributes control whether those arguments are held. Head own values are used when choosing
  the assignment tag, matching cases such as `f = List; f[1] = rhs`.
- `SetDelayed[f[args], rhs]` / `f[args] := rhs` stores a delayed down value for `f`. The RHS is
  stored unevaluated and evaluated afresh each time the definition is used.
- Curried forms such as `f[x_][y_] := rhs` are stored as `SubValues[f]`; if the inner head
  expression evaluates during assignment, the subvalue can be attached to the evaluated target.
- `Unset[sym]` / `sym =.` removes a bare symbol's own value.
- `Unset[f[args]]` / `f[args] =.` removes a matching down-value or sub-value definition.
- `Clear[sym1, ...]` and `Clear[{sym1, ...}]` clear process-local value slots for bare symbols.
  String-pattern forms clear registered names that match `Names[pattern]`.
- `ClearAll[sym1, ...]` clears process-local value slots and mutable attributes for unprotected,
  unlocked symbols.
- `OwnValues[sym]` and `OwnValues["name"]` return read-only own-value rules of the form
  `HoldPattern[sym] :> value`.
- `DownValues[sym]`, `SubValues[sym]`, `UpValues[sym]`, and `NValues[sym]` read the corresponding
  canonical value lists. `DownValues` and `SubValues` are populated by supported compound-LHS
  assignments; `UpValues` is populated by `TagSet` / `TagSetDelayed`; `NValues` remains a
  read-only storage surface for now.
- `TagSet`, `TagSetDelayed`, and `TagUnset` support tagged own/down/sub definitions plus
  practical up-value definitions where the tag appears as an immediate argument or in the head
  chain of an immediate argument of the left-hand side.
- `ValueQ[expr]` holds `expr` while checking value availability. It returns `True` for symbols
  with own values, `$Context`, `$ContextPath`, and expressions Tungsten can reduce structurally
  through own, down, sub, or up values. Ordinary atoms such as integers and strings return
  `False`, matching Wolfram's value-oriented interpretation more closely now that Tungsten has
  process-local own-value storage.
- Symbols whose registry attributes include `Protected` reject `Set`, `Unset`, `Clear`, and
  `ClearAll` value mutations with `wrsym` messages. Symbols whose attributes include `Locked`
  reject attribute mutation and protect/unprotect attempts with `locked` messages.

Name-pattern matching supports the practical string-pattern subset used by Wolfram name functions:

- `*` matches any sequence of characters;
- `@` matches one or more characters that are not uppercase ASCII letters;
- backslash escapes the next character literally.

## Current Boundaries

The registry intentionally does not yet implement:

- mutable `$Context` or `$ContextPath`;
- `Begin`, `BeginPackage`, `End`, `Needs`, package loading, shadowing diagnostics, or context
  aliases;
- `UpSet` and `UpSetDelayed`;
- direct assignment to value lists such as `DownValues[f] = {...}`;
- remaining kernel corner cases for user-definable up values;
- persistent registry state across separate Tungsten CLI processes.

These boundaries are structural, not accidental. Attributes are process-local metadata that the
offline evaluator now consults for common argument handling (`HoldFirst`, `HoldRest`, `HoldAll`,
`HoldAllComplete`, `SequenceHold`, `Listable`, `Flat`, `Orderless`, and Flat/OneIdentity pattern
segments). Tungsten still does not implement package loading, direct value-list assignment, or
every specialized built-in evaluator rule associated with the full Wolfram kernel.

## Examples

```powershell
tungsten-cpp expr evaluate --code '$Context'
tungsten-cpp expr evaluate --code '$ContextPath'
tungsten-cpp expr evaluate --code 'Context[System`Plus]'
tungsten-cpp expr evaluate --code '{Symbol["TungstenExample`alpha"], Names["TungstenExample`*"]}'
tungsten-cpp expr evaluate --code 'NameQ["Plus"]'
tungsten-cpp expr evaluate --code 'NameQ["System`AASTriangle"]'
tungsten-cpp expr evaluate --code 'Length[Names["System`*"]]'
tungsten-cpp expr evaluate --code 'Attributes[Plus]'
tungsten-cpp expr evaluate --code 'Attributes[{Attributes, Plus, AASTriangle}]'
tungsten-cpp expr evaluate --code 'SetAttributes[f, {Flat, Orderless}]; f[b, f[a]]'
tungsten-cpp expr evaluate --code 'Attributes[g] = HoldAll; g[1 + 2, Evaluate[3 + 4]]'
tungsten-cpp expr evaluate --code 'Protect[x]; x = 1; Unprotect[x]; x = 1'
tungsten-cpp expr evaluate --code 'x = 1 + 2; {ValueQ[x], OwnValues[x], x}'
tungsten-cpp expr evaluate --code 'x = 1; x = .; ValueQ[x]'
tungsten-cpp expr evaluate --code 'Unique[temporarySymbol]'
```

## Regenerating the System Snapshot

The snapshot is generated from the installed paid Wolfram 15.0 kernel rather than hand-authored:

```powershell
pwsh -File .\Engine\scripts\Update-TungstenSystemSymbolSnapshot.ps1
```

The generator records <code>Names["System`*"]</code> entries that do not themselves contain a
backtick and uses <code>Attributes[Evaluate["System`" <> name]]</code> to account for the fact that `Attributes` has
`HoldAll`. CMake embeds the JSON file into the native library, and the Python oracle reads the same
source snapshot for differential compatibility checks.

## Reference Material

Implementation choices were checked against the corresponding Wolfram documentation pages:

- [Symbol](https://reference.wolfram.com/language/ref/Symbol.html)
- [SymbolName](https://reference.wolfram.com/language/ref/SymbolName.html)
- [Unique](https://reference.wolfram.com/language/ref/Unique.html)
- [Set](https://reference.wolfram.com/language/ref/Set.html)
- [Unset](https://reference.wolfram.com/language/ref/Unset.html)
- [Clear](https://reference.wolfram.com/language/ref/Clear.html)
- [ClearAll](https://reference.wolfram.com/language/ref/ClearAll.html)
- [OwnValues](https://reference.wolfram.com/language/ref/OwnValues.html)
- [Names](https://reference.wolfram.com/language/ref/Names.html)
- [NameQ](https://reference.wolfram.com/language/ref/NameQ.html)
- [Attributes](https://reference.wolfram.com/language/ref/Attributes.html)
- [SetAttributes](https://reference.wolfram.com/language/ref/SetAttributes.html)
- [ClearAttributes](https://reference.wolfram.com/language/ref/ClearAttributes.html)
- [Protect](https://reference.wolfram.com/language/ref/Protect.html)
- [Unprotect](https://reference.wolfram.com/language/ref/Unprotect.html)
- [Contexts](https://reference.wolfram.com/language/ref/Contexts.html)
- [Context](https://reference.wolfram.com/language/ref/Context.html)
- [$Context](https://reference.wolfram.com/language/ref/%24Context.html)
- [$ContextPath](https://reference.wolfram.com/language/ref/%24ContextPath.html)
- [ValueQ](https://reference.wolfram.com/language/ref/ValueQ.html)
