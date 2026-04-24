# Tungsten Pattern Matching Plan

- Status: Implemented and validated (this document records the intended scope and the completed outcome)
- Audience: Tungsten maintainers, reviewers, and contributors extending `expression.py`
- Scope: kernel-free Wolfram pattern parsing and structural matching in `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-23T23:55:57Z
- Updated (UTC): 2026-04-24T02:24:13Z
- Repository HEAD: 5152667bb85be73fd9d7d6678e0bc4f9aa8d335a
- Related code:
  - `src/Tungsten/src/tungsten/expression.py`
  - `src/Tungsten/tests/test_expression.py`
  - `src/Tungsten/tests/test_cli.py`
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Expression Function Support](./expression-function-support.md)
  - [MatchQ](https://reference.wolfram.com/language/ref/MatchQ)
  - [FreeQ](https://reference.wolfram.com/language/ref/FreeQ)
  - [Cases](https://reference.wolfram.com/language/ref/Cases)
  - [DeleteCases](https://reference.wolfram.com/language/ref/DeleteCases)

## Purpose

This document is the implementation plan for adding a deliberately bounded but practically useful
subset of Wolfram pattern matching to Tungsten's kernel-free expression subsystem.

The requested first target is:

- pattern parsing in `InputForm` and the supported plain-text `StandardForm` subset;
- inert structural matching without a running kernel;
- `MatchQ`, `FreeQ`, `Cases`, and `DeleteCases`;
- no support for variable-length sequence patterns or options.

The important constraint is that Tungsten is still not becoming a general Wolfram evaluator. The
goal is a deterministic, structural, offline subset that is strong enough for scripting and
analysis tasks, while staying explicit about unsupported pattern forms.

## Implementation outcome

This plan has now been carried through in `expression.py` and `test_expression.py`.

Implemented highlights:

- parser support for `_`, `_Head`, `x_`, `x_Head`, and infix `|` alternatives;
- structural pattern matching over Tungsten's AST with support for `Blank`, `Pattern`,
  `HoldPattern`, `Verbatim`, `Except`, and `Alternatives`;
- new inert evaluator support for `MatchQ`, `FreeQ`, `Cases`, and `DeleteCases`;
- named-pattern binding substitution for `Cases[..., patt :> rhs]`;
- notebook-derived parser tests from installed `MatchQ.nb`, `Cases.nb`, and `FreeQ.nb`;
- live-kernel spot-check validation for the covered subset.

The main deliberate boundary kept for this pass is association traversal:

- whole associations can still match as structural expressions such as `_Association`;
- `FreeQ`, `Cases`, and `DeleteCases` currently treat associations as opaque leaves and do not
  descend into keys or values yet.

Validation completed:

- Python unit validation via
  `python -m unittest discover -s C:\Tools1\Tools\src\Tungsten\tests -t C:\Tools1\Tools\src\Tungsten`;
- targeted live-kernel comparisons for repeated named bindings, `Verbatim`, `Except`,
  `Cases[..., patt :> rhs]`, depth-first postorder search, and `DeleteCases` match limits.

## Why this needs design work

Pattern matching sounds local, but in practice it affects three different layers at once:

- the parser must understand common shorthand such as `_Integer` and `x_`;
- the evaluator must keep pattern and template arguments inert instead of eagerly evaluating them;
- traversal functions such as `Cases` and `DeleteCases` need their own search-order and
  level-spec behavior that differs from exact-position functions such as `Part`.

There are also a few semantic traps that are easy to get wrong unless they are decided up front:

- `FreeQ` searches heads by default, while `Cases` and `DeleteCases` do not;
- `DeleteCases` is depth-first with leaves visited before roots;
- named patterns such as `f[x_, x_]` must enforce repeated-binding equality;
- `Verbatim[_]` must treat `_` as a literal blank expression rather than as a wildcard;
- `Cases[expr, patt :> rhs]` must substitute bindings into `rhs` without evaluating `rhs`
  prematurely.

## Source material

### Official documentation consulted

Primary references:

- [MatchQ](https://reference.wolfram.com/language/ref/MatchQ)
- [FreeQ](https://reference.wolfram.com/language/ref/FreeQ)
- [Cases](https://reference.wolfram.com/language/ref/Cases)
- [DeleteCases](https://reference.wolfram.com/language/ref/DeleteCases)
- local notebooks:
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\MatchQ.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\FreeQ.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\Cases.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\DeleteCases.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\Blank.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\Except.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\HoldPattern.nb`
  - `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\Verbatim.nb`

Important documented rules that shape this design:

- `MatchQ[expr, form]` returns `True` exactly when `expr` matches the pattern `form`.
- `FreeQ[expr, form]` defaults to levels `{0, Infinity}` and, with default `Heads -> True`,
  searches heads and their parts.
- `Cases[expr, pattern]` defaults to levels `{1}` and only searches heads when `Heads -> True`
  is explicitly enabled.
- `DeleteCases[expr, pattern]` defaults to levels `{1}` and traverses the expression depth-first,
  with leaves visited before roots.

### Live-kernel experiments already run

The following behaviors were confirmed against the real local Wolfram kernel through Tungsten's
kernel runner on this machine.

#### Basic matching and repeated bindings

- `MatchQ[2, _]` yields `True`.
- `MatchQ[f[1], f[_Integer]]` yields `True`.
- `MatchQ[f[1, 1], f[x_, x_]]` yields `True`.
- `MatchQ[f[1, 2], f[x_, x_]]` yields `False`.
- `MatchQ[f[1], _[1]]` yields `True`.
- `MatchQ[1, Blank[Integer]]` yields `True`.
- `MatchQ[x, Blank[Integer]]` yields `False`.

#### Literal and exclusion-oriented patterns

- `MatchQ[_, Verbatim[_]]` yields `True`.
- `MatchQ[_, HoldPattern[_]]` yields `True`.
- `MatchQ[2, Except[_Integer]]` yields `False`.
- `MatchQ[a, Except[_Integer]]` yields `True`.
- `MatchQ[f[a], Except[f[_]]]` yields `False`.
- `MatchQ[g[a], Except[f[_]]]` yields `True`.

#### Search behavior and defaults

- `FreeQ[f[a], a]` yields `False`.
- `FreeQ[f[a], f]` yields `False`.
- `FreeQ[f[a], f, {1}]` yields `False`.
- `Cases[f[a, g[a]], a]` yields `{a}`.
- `Cases[f[a, g[a]], a, Infinity]` yields `{a, a}`.
- `Cases[f[a], f, Infinity]` yields `{}`.
- `Cases[f[a, g[a]], a, Infinity, 1]` yields `{a}`.

#### `Cases` transformations and `DeleteCases` ordering

- `Cases[{f[a], f[b]}, f[x_] :> x]` yields `{a, b}`.
- `Cases[{f[a], f[b]}, f[x_] :> {x, x}]` yields `{{a, a}, {b, b}}`.
- `DeleteCases[{1, a, 2, a}, a]` yields `{1, 2}`.
- `DeleteCases[{1, a, 2, a}, a, Infinity, 1]` yields `{1, 2, a}`.
- `DeleteCases[f[a, g[a]], a]` yields `f[g[a]]`.
- `DeleteCases[f[a, g[a]], a, Infinity]` yields `f[g[]]`.

These experiments are enough to define the first implementation slice without having to implement
the whole Wolfram pattern language.

## Current Tungsten gaps

The current expression subsystem has no first-class pattern matcher.

Concrete gaps:

- `_`, `_Integer`, `x_`, and `x_Integer` do not parse at all;
- pattern constructs currently survive only as explicit function-call syntax such as
  `Blank[Integer]` or `Except[...]`;
- `MatchQ`, `FreeQ`, `Cases`, and `DeleteCases` are not implemented in the evaluator;
- `Cases[..., patt :> rhs]` has no binding-substitution path;
- the evaluator currently evaluates all arguments eagerly, which is wrong for pattern and template
  arguments.

## Proposed implementation scope

### Pattern forms to support in this pass

Supported:

- literal structural expressions;
- `Blank[]` and `_`;
- `Blank[h]` and `_h`;
- `Pattern[x, patt]`, `x_`, and `x_h`;
- `HoldPattern[patt]`;
- `Verbatim[patt]`;
- `Except[patt]` and `Except[patt, q]`;
- `Alternatives[p1, p2, ...]`;
- infix `p1 | p2` as syntax sugar for `Alternatives[p1, p2]`.

Originally out of scope in this pass:

- `BlankSequence`, `BlankNullSequence`, `__`, `___`;
- `Repeated`, `RepeatedNull`;
- `Optional` and options-related pattern forms;
- `PatternTest` (`?`) and `Condition` (`/;`);
- `Longest`, `Shortest`, and similar match-shaping forms;
- full rule-based replacement semantics outside the narrow `Cases[..., patt :> rhs]` path;
- association-aware pattern traversal.

### Function forms to support in this pass

Implement:

- `MatchQ[expr, form]`;
- `FreeQ[expr, form]`;
- `FreeQ[expr, form, levelspec]`;
- `Cases[expr, patt]`;
- `Cases[expr, patt, levelspec]`;
- `Cases[expr, patt, levelspec, n]`;
- `Cases[expr, patt :> rhs]` and `Cases[expr, patt :> rhs, levelspec]`;
- `DeleteCases[expr, patt]`;
- `DeleteCases[expr, patt, levelspec]`;
- `DeleteCases[expr, patt, levelspec, n]`.

Deliberate non-goals for this pass:

- operator forms such as `MatchQ[patt]` and `Cases[patt]`;
- `Heads -> True` options on `Cases` and `DeleteCases`;
- association-specific value-only traversal and key-aware matching.

### Association boundary for this pass

The user explicitly allowed postponing association pattern matching, so this implementation will
take the conservative route:

- association expressions may still participate as whole structural expressions;
- the matcher may succeed on whole-association literals such as `_Association`;
- `FreeQ`, `Cases`, and `DeleteCases` will treat associations as opaque leaves instead of
  descending into rules, keys, or values.

This avoids shipping incorrect semantics for associations while still allowing the rest of the
pattern subsystem to become useful.

## Parser plan

### 1. Add shorthand-token support

Extend the tokenizer and parser for:

- `_` as a pattern token;
- `|` as the `Alternatives` infix operator.

The parser should lower shorthand patterns directly into ordinary Tungsten AST nodes:

- `_` -> `Blank[]`
- `_Integer` -> `Blank[Integer]`
- `x_` -> `Pattern[x, Blank[]]`
- `x_Integer` -> `Pattern[x, Blank[Integer]]`
- `a | b` -> `Alternatives[a, b]`

This keeps the matcher engine independent of textual surface syntax.

### 2. Follow-up extension note

This design note predates the later anonymous-sequence-pattern extension. Tungsten now supports a
deliberately narrow slice of `BlankSequence` / `BlankNullSequence`:

- anonymous `__`, `___`, `__Head`, and `___Head`;
- only when there is at most one such pattern in the containing argument list;
- still not for named forms such as `x__` or `x___`.

Other advanced shorthand such as `?` and `/;` remains unsupported.

## Matcher plan

### 1. Add a dedicated structural matcher

Implement a matcher that consumes:

- a candidate expression;
- a pattern expression;
- a current binding environment.

The result should be:

- success with a binding map, or
- failure.

### 2. Binding rules

Named patterns should bind by symbol name, with repeat occurrences requiring structural equality.

Example:

- `f[x_, x_]` matches `f[a, a]`;
- `f[x_, x_]` does not match `f[a, b]`.

### 3. Special forms

Matcher handling should be explicit for:

- `Blank`
- `Pattern`
- `HoldPattern`
- `Verbatim`
- `Except`
- `Alternatives`

Everything else should fall back to ordinary structural recursion over heads and arguments.

### 4. Unsupported pattern heads

If the matcher encounters an explicit advanced pattern form that Tungsten does not implement, it
should raise a `WolframEvaluationError` instead of silently treating it as a literal expression.

## Traversal plan

### 1. Add a general pattern-search walker

Implement a separate traversal helper for the pattern functions instead of trying to reuse exact
position code.

The walker needs:

- level bookkeeping;
- optional head traversal;
- association opacity for this pass;
- depth-first order for delete operations;
- support for a match limit `n`.

### 2. Defaults

Use Wolfram-compatible defaults for the subset:

- `FreeQ`: levels `{0, Infinity}`, heads searched by default;
- `Cases`: levels `{1}`, heads not searched by default;
- `DeleteCases`: levels `{1}`, heads not searched by default.

### 3. `DeleteCases` semantics

Implement `DeleteCases` as a recursive transform that:

- visits children before parents;
- counts matches in traversal order;
- deletes matched subexpressions by removing them from their parent's argument list.

Whole-expression deletion at level `0` is not a priority target for this pass. If it appears, the
implementation may conservatively reject it rather than guessing at a top-level `Sequence[]`-like
result contract.

## Template-substitution plan for `Cases`

For `Cases[..., patt :> rhs]`:

- match using the left-hand side pattern;
- substitute bound names into `rhs`;
- evaluate the substituted result structurally with Tungsten's existing evaluator.

For `Cases[..., patt -> rhs]`, Tungsten can support the same surface with a simplified structural
interpretation:

- structurally evaluate `rhs` once up front;
- substitute bindings into that evaluated template.

This is not full Wolfram replacement semantics, but it is deterministic and close enough for the
requested structural subset.

## Validation plan

### Parser tests

Add parser tests for:

- `_`, `_Integer`, `x_`, `x_Integer`;
- `a | b`;
- `Verbatim[_]`;
- notebook-derived examples from installed docs such as:
  - `MatchQ[12345, _Integer]` from `MatchQ.nb`;
  - `Cases[..., Except[_Integer]]` from `Cases.nb`;
  - `FreeQ[..., _Integer]` from `FreeQ.nb`.

### Evaluator tests

Add structural evaluator tests for:

- `MatchQ`
- `FreeQ`
- `Cases`
- `DeleteCases`
- repeated named bindings;
- `Verbatim`;
- `Except`;
- `Alternatives`;
- `Cases[..., patt :> rhs]`;
- level specs and match limits;
- head-search differences between `FreeQ` and `Cases`.

### Live-kernel spot checks

Re-run a curated kernel comparison list after implementation, especially for:

- `f[x_, x_]` repeated bindings;
- `Verbatim[_]`;
- `Except[_Integer]`;
- `Cases[..., Infinity, 1]`;
- `DeleteCases[..., Infinity, 1]`;
- root/head search defaults.

## Planned documentation updates

After implementation:

- update [Expression Parser](./expression-parser.md) with supported pattern syntax;
- update [Expression Function Support](./expression-function-support.md) so it no longer says
  pattern-driven functions are out of scope;
- update [usage-reference.md](./usage-reference.md) with representative `expr evaluate` examples;
- add this plan doc to [docs/README.md](./README.md).
