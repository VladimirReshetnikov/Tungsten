# Tungsten Association Support Plan

- Status: Implemented and validated (this document now records both the plan and the completed scope)
- Audience: Tungsten maintainers, reviewers, and contributors extending `expression.py`
- Scope: Association parsing and structural evaluation in `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-23T19:01:41Z
- Updated (UTC): 2026-04-24T16:50:02Z
- Repository HEAD: 6c97e4ba7ff2c691ed7494ad9ba968faf4c6cdec
- Related code:
  - `src/Tungsten/src/tungsten/expression.py`
  - `src/Tungsten/tests/test_expression.py`
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Expression Function Support](./expression-function-support.md)
  - [Association](https://reference.wolfram.com/language/ref/Association)
  - [Associations Guide](https://reference.wolfram.com/language/guide/Associations)

## Purpose

This document is the implementation plan for bringing Tungsten's kernel-free expression subsystem up
to a useful, association-aware level. The user request is broader than "parse `<|...|>`":

- parse association literals in `InputForm` and the supported plain-text / box-text `StandardForm`
  subset;
- implement a substantial set of standard association functions that can run without a kernel;
- make exact-position functions such as `Part`, `Extract`, `Delete`, `ReplacePart`, and `MapAt`
  work correctly for associations, including mixed nesting of lists and associations;
- verify behavior against the real local Wolfram kernel and against installed local documentation
  notebooks.

This plan records the intended scope, semantic decisions, and validation strategy before the code
changes are made.

## Implementation outcome

This plan has now been carried through in `expression.py` and `test_expression.py`.

Implemented highlights:

- association constructor normalization with last-occurrence-wins key semantics;
- association-aware parsing in both `InputForm` and the supported textual/row-box `StandardForm`
  subset;
- association-aware exact-position handling for `Part`, `Extract`, `Delete`, `ReplacePart`, and
  `MapAt`, including mixed nesting with lists;
- association-specific structural functions such as `Keys`, `Values`, `Normal`, `Lookup`,
  `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`, `KeyMap`, `KeyValueMap`,
  `AssociationThread`, and `AssociationMap`;
- association-aware behavior for already supported structural functions such as `First`, `Last`,
  `Rest`, `Most`, `Take`, `Drop`, `Append`, `Prepend`, `Join`, `Apply`, `Map`, and `Depth`.

Validation completed:

- direct live-kernel probes during implementation to calibrate edge semantics such as duplicate-key
  ordering, key-based `Part`, nested mixed paths, and `Prepend` behavior;
- notebook-derived parser tests sourced from the installed `Association.nb` reference page;
- Python unit validation via `python -m unittest discover -s .\src\Tungsten\tests -t .\src\Tungsten`.

## Why this needs design work

Associations are not just `Call("Association", Rule[key, value], ...)` with generic structural
semantics layered on top.

The real Wolfram behavior has a few association-specific rules that materially change the evaluator
design:

- duplicate keys are normalized by keeping the last occurrence;
- many sequence-oriented functions operate on association values rather than on raw `Rule`
  expressions;
- key-based position specifications exist for some functions but not all functions;
- top-level association positions have different meanings depending on the consuming function:
  `Part` and `ReplacePart` target values, while `Delete` can target whole entries;
- selector lists of keys are valid, but mixed integer-and-key selector lists are not.

The current Tungsten evaluator does not model those rules. It treats associations as an ordinary
head with `Rule` arguments, which is not sufficient.

## Source material

### Official/local documentation consulted

Primary references:

- `Association` reference page:
  - local notebook:
    `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\ReferencePages\Symbols\Association.nb`
  - web:
    [Association](https://reference.wolfram.com/language/ref/Association)
- `Associations` guide:
  - local notebook:
    `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\14.3\Documentation\English\System\Guides\Associations.nb`
  - web:
    [Associations Guide](https://reference.wolfram.com/language/guide/Associations)

Important local-doc findings:

- the `Association` page explicitly documents:
  - key-based extraction via `Key[...]`;
  - numeric part specifications on associations;
  - mixed list/association traversal through part specs;
  - string-key shorthand in part specs when keys are strings;
  - last-occurrence-wins semantics for duplicate keys;
  - the statement that typical list operations such as `Map`, `Select`, and `Sort` apply to
    association values while keeping the keys unchanged.
- the `Associations` guide usefully groups the ecosystem into:
  - element-access functions:
    `Keys`, `Values`, `Normal`, `Lookup`, `KeyExistsQ`;
  - key transforms:
    `KeyTake`, `KeyDrop`, `KeyMap`, `KeyValueMap`;
  - constructors:
    `Association`, `AssociationMap`, `AssociationThread`;
  - mutation-oriented / kernel-semantic / predicate-driven functions that are less suitable for the
    current inert evaluator.

### Live-kernel experiments already run

The following behaviors were confirmed against the real local Wolfram kernel through Tungsten's
kernel runner on this machine.

#### Constructor and duplicate-key semantics

- `Association[{a -> 1, a -> 2, b -> 3}]` yields `<|a -> 2, b -> 3|>`.
- `Append[<|a -> 1, b -> 2|>, a -> 9]` yields `<|b -> 2, a -> 9|>`.
- `Join[<|a -> 1, b -> 2|>, <|a -> 9, c -> 3|>]` yields `<|a -> 9, b -> 2, c -> 3|>`.

The important detail is that "last wins" is not just value replacement: the last surviving
occurrence determines the final key order.

#### Key-based `Part` and mixed nesting

- `<|a -> x, b -> y, c -> z|>[[Key[b]]]` yields `y`.
- `<|a -> x, b -> y, c -> z|>[[2]]` yields `y`.
- `{<|a -> x, b -> {y, z}|>}[[1, Key[b], 2]]` yields `z`.
- `{<|"a" -> x, "b" -> {y, z}|>}[[1, "b", 2]]` yields `z`.
- `<|a -> 1, b -> 2, c -> 3, d -> 4|>[[{Key[a], Key[c]}]]` yields `<|a -> 1, c -> 3|>`.
- `<|"a" -> 1, "b" -> 2, "c" -> 3|>[[{"c", "a"}]]` yields `<|"c" -> 3, "a" -> 1|>`.
- `<|a -> 1, b -> 2, c -> 3, d -> 4|>[[{2, Key[d]}]]` produces `Part::pmix`.

The key semantic rule is that integer selectors and key selectors may both exist in part paths, but
they may not be mixed inside a single selector-list component.

#### `Extract`, `Delete`, `ReplacePart`, and `MapAt`

- `Extract[<|a -> x, b -> y|>, {Key[b]}]` yields `y`.
- `Extract[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]` yields `{1, 3}`.
- `Delete[<|a -> 1, b -> 2, c -> 3|>, Key[b]]` yields `<|a -> 1, c -> 3|>`.
- `Delete[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]` yields `<|b -> 2|>`.
- `ReplacePart[<|a -> 1, b -> 2, c -> 3|>, Key[b] -> x]` yields `<|a -> 1, b -> x, c -> 3|>`.
- `MapAt[f, <|a -> 1, b -> 2, c -> 3|>, Key[b]]` yields `<|a -> 1, b -> f[2], c -> 3|>`.
- `Delete[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]` yields `{<|a -> 1, b -> {2}|>, 9}`.
- `ReplacePart[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2} -> x]` yields
  `{<|a -> 1, b -> {2, x}|>, 9}`.
- `MapAt[f, {<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]` yields
  `{<|a -> 1, b -> {2, f[3]}|>, 9}`.

This confirms a crucial distinction:

- for `Part`, `Extract`, `ReplacePart`, and `MapAt`, a top-level association position targets the
  value of the entry;
- for `Delete`, a top-level association position removes the entire entry, but deeper path suffixes
  operate inside the value.

#### Existing sequence-oriented functions on associations

- `First[<|a -> 1, b -> 2, c -> 3|>]` yields `1`.
- `Last[<|a -> 1, b -> 2, c -> 3|>]` yields `3`.
- `Rest[<|a -> 1, b -> 2, c -> 3|>]` yields `<|b -> 2, c -> 3|>`.
- `Most[<|a -> 1, b -> 2, c -> 3|>]` yields `<|a -> 1, b -> 2|>`.
- `Map[f, <|a -> 1, b -> 2|>]` yields `<|a -> f[1], b -> f[2]|>`.
- `Apply[g, <|a -> 1, b -> 2|>]` yields `g[1, 2]`.
- `Reverse[<|a -> 1, b -> 2, c -> 3|>]` yields `<|c -> 3, b -> 2, a -> 1|>`.
- `Take[<|a -> 1, b -> 2, c -> 3|>, 2]` yields `<|a -> 1, b -> 2|>`.
- `Drop[<|a -> 1, b -> 2, c -> 3|>, 2]` yields `<|c -> 3|>`.

This means several existing Tungsten functions must become association-aware instead of simply
operating on raw `Rule` arguments.

#### Element/key-oriented association functions

- `Keys[<|a -> x, b -> y, c -> z|>]` yields `{a, b, c}`.
- `Values[<|a -> x, b -> y, c -> z|>]` yields `{x, y, z}`.
- `Normal[<|a -> x, b -> y, c -> z|>]` yields `{a -> x, b -> y, c -> z}`.
- `Lookup[<|a -> x, b -> y|>, b]` yields `y`.
- `Lookup[<|a -> x, b -> y|>, d]` yields `Missing["KeyAbsent", d]`.
- `Lookup[<|a -> x, b -> y|>, d, q]` yields `q`.
- `Lookup[<|a -> 1, b -> 2, c -> 3|>, {c, a}]` yields `{3, 1}`.
- `KeyExistsQ[<|a -> x, b -> y|>, b]` yields `True`.
- `KeyMemberQ[<|a -> x, b -> y|>, d]` yields `False`.
- `KeyTake[<|a -> 1, b -> 2, c -> 3|>, {c, a}]` yields `<|c -> 3, a -> 1|>`.
- `KeyDrop[<|a -> 1, b -> 2, c -> 3|>, {c, a}]` yields `<|b -> 2|>`.
- `KeyMap[f, <|a -> 1, b -> 2|>]` yields `<|f[a] -> 1, f[b] -> 2|>`.
- `KeyMap[(1 &), <|a -> 1, b -> 2|>]` yields `<|1 -> 2|>`.
- `KeyValueMap[f, <|a -> 1, b -> 2|>]` yields `{f[a, 1], f[b, 2]}`.
- `AssociationThread[{a, b, c}, {1, 2, 3}]` yields `<|a -> 1, b -> 2, c -> 3|>`.
- `AssociationMap[f, {a, b, c}]` yields `<|a -> f[a], b -> f[b], c -> f[c]|>`.
- `AssociationMap[f, <|a -> 1, b -> 2|>]` raises `AssociationMap::invrlf`.

These findings define the first implementation scope below.

## Current Tungsten gaps

The current evaluator already parses `<|...|>` textually, but several important areas are missing
or incorrect.

### 1. No association-aware constructor semantics

`evaluate()` currently leaves `Association[...]` inert, so duplicate-key normalization and
constructor variants such as `Association[{rules}]` are not modeled.

### 2. Existing generic structural functions treat rules as values

For associations, current Tungsten behavior is currently wrong or incomplete for:

- `Depth`
- `First`
- `Last`
- `Rest`
- `Most`
- `Apply`
- `Map`
- likely other sequence-oriented transforms that should rebuild an association rather than expose
  `Rule` objects.

### 3. Position handling has no `Key[...]` or string-key support

Current position helpers understand integers, `All`, spans, and selector lists, but not:

- `Key[key]`
- string-key shorthand in part specs
- association-specific selector-list rules
- delete-versus-value-targeting distinctions for association positions.

### 4. StandardForm row-box parsing needs association token normalization

Local doc examples use row-box tokens such as:

- `"\[Rule]"`
- `"\[RuleDelayed]"`
- association delimiters carried as row-box strings

Tungsten's row-box token normalization currently handles whitespace tokens but not association and
rule tokens, so association row-box examples from `Association.nb` are not reliably understood.

### 5. Existing `Part` implementation is too iterative for multi-selector descent

Current `part()` effectively applies specifications left-to-right on the progressively transformed
expression. That is too weak for correct multi-level behavior when selector components such as
`All`, spans, or selector lists appear before additional path suffixes, and associations make this
more visible.

## Proposed implementation scope

### Parser scope

Implement and verify:

- `InputForm` association literals:
  - `<|a -> 1, b -> 2|>`
  - `<|"a" -> 1, "b" -> 2|>`
  - `<|a :> rhs|>`
- `StandardForm` / textual box examples from installed notebooks:
  - plain row-box association literals from `Association.nb`
  - key-based part examples from `Association.nb`
  - string-key shorthand examples from `Association.nb`
- row-box token normalization for:
  - `\[Rule]` -> `->`
  - `\[RuleDelayed]` -> `:>`
  - `\[LeftAssociation]` -> `<|`
  - `\[RightAssociation]` -> `|>`

### Evaluation scope

Implement the following kernel-free association surface.

#### Constructor / recognition

- `Association`
- `AssociationQ`

#### Element access and conversion

- `Keys`
- `Values`
- `Normal`
- `Lookup`
- `KeyExistsQ`
- `KeyMemberQ`

#### Exact-key transforms and constructors

- `KeyTake`
- `KeyDrop`
- `KeyMap`
- `KeyValueMap`
- `AssociationThread`
- `AssociationMap` for the key-list form

#### Association-aware behavior for already supported structural functions

- `Depth`
- `First`
- `Last`
- `Rest`
- `Most`
- `Append`
- `Prepend`
- `Join`
- `Take`
- `Drop`
- `Delete`
- `ReplacePart`
- `Apply`
- `Map`
- `MapAt`
- `Part`
- `Extract`

`Length`, `Head`, `Reverse`, `RotateLeft`, and `RotateRight` should also be reviewed and
canonicalized through the new association helpers so they cannot leak duplicate keys or malformed
rule sets.

## Deliberate non-goals for this milestone

The user asked for a large task, but not for a full association runtime. The first milestone should
still stay on the structural side.

Explicit non-goals for this pass:

- mutation forms that require stateful in-place semantics such as `AssociateTo` and `KeyDropFrom`;
- predicate-driven key selection such as `KeySelect` unless we later decide to support a very small
  inert subset;
- ordering/comparison-driven functions such as `KeySort`, `KeySortBy`, `Counts`, `CountsBy`, and
  `GroupBy`;
- full `RuleDelayed` evaluation semantics;
- dataset-specific operators or query language;
- pattern forms such as `KeyValuePattern`.

If some of these become cheap follow-on wins after the core association model is in place, they can
be added later, but they should not dilute the main implementation in this pass.

## Design approach

### 1. Keep the existing AST shape

Associations should continue to be represented as:

```text
Association[Rule[key1, value1], Rule[key2, value2], ...]
```

or with `RuleDelayed` entries where applicable.

That keeps the parser simple and avoids a large AST refactor.

### 2. Add association helpers instead of sprinkling ad hoc checks

Add centralized helpers in `expression.py` for:

- detecting associations;
- validating / normalizing association entries;
- deduplicating keys with last-occurrence order;
- iterating association entries as `(rule_head, key, value)` triples;
- rebuilding associations from normalized entries;
- converting associations to `List[Rule[...], ...]` for `Normal`.

Higher-level built-ins should use those helpers rather than inspecting raw `Rule` nodes directly.

### 3. Make position handling association-aware by operation mode

The key design distinction:

- `Part`, `Extract`, `ReplacePart`, `MapAt`
  - top-level association positions target values;
- `Delete`
  - top-level association positions delete entries;
  - deeper suffixes operate inside the selected value.

Plan:

- replace or substantially extend the current position-expansion helpers so they understand
  association components:
  - `Key[...]`
  - string-key shorthand
  - integer selectors
  - `All`
  - spans
  - selector lists that are internally consistent
- forbid selector lists that mix integer-style and key-style selectors;
- preserve current exact-position behavior and deterministic update ordering.

### 4. Rework `Part` recursion around semantic selection, not naive iteration

`Part` needs to become a recursive selector engine instead of repeatedly applying single-step
transformations to the current result.

For single selectors:

- descend into one selected value / item.

For multi selectors (`All`, spans, selector lists):

- select multiple items;
- if there are remaining components, apply the suffix recursively to each selected item;
- rebuild a result with the same head:
  - lists stay lists;
  - general heads stay the same head;
  - associations rebuild from the same keys plus transformed values.

This is important not only for associations, but also for mixed list/association paths such as:

```text
{<|a -> x, b -> {y, z}|>}[[1, Key[b], 2]]
```

### 5. Canonicalize every association-producing result

Any built-in that can produce an association must return a normalized association:

- valid entries only;
- last occurrence wins;
- final key order follows the last surviving occurrence.

Without this, generic transforms such as `Join`, `Append`, or `ReplacePart` would leak malformed
intermediate association states.

## Implementation steps

### Step 1. Add low-level association helpers

Create helpers for:

- `is_association(expr)`
- `association_entries(expr)`
- `association_expr(entries)`
- `association_from_expr(expr)` for constructor normalization
- key lookup / entry resolution by exact structural equality
- association-aware rendering helpers if needed

### Step 2. Implement constructor and recognition functions

Add evaluator cases for:

- `Association`
- `AssociationQ`

Constructor support should accept:

- direct rules;
- a single list of rules;
- a single association.

### Step 3. Implement element-access functions

Add evaluator cases and helpers for:

- `Keys`
- `Values`
- `Normal`
- `Lookup`
- `KeyExistsQ`
- `KeyMemberQ`

`Lookup` should support:

- single key;
- single key with default;
- list of keys;
- list of keys with default.

### Step 4. Implement association constructors / key transforms

Add evaluator cases and helpers for:

- `KeyTake`
- `KeyDrop`
- `KeyMap`
- `KeyValueMap`
- `AssociationThread`
- `AssociationMap` on key lists

Document that `AssociationMap[f, assoc]` remains unsupported in Tungsten for now, matching the fact
that the direct live-kernel probe produced `AssociationMap::invrlf`.

### Step 5. Make existing structural functions association-aware

Update helpers and evaluator cases so these functions respect association value semantics:

- `Depth`
- `First`
- `Last`
- `Rest`
- `Most`
- `Append`
- `Prepend`
- `Join`
- `Take`
- `Drop`
- `Apply`
- `Map`

### Step 6. Rework exact-position machinery

Implement association-aware semantics for:

- `Part`
- `Extract`
- `Delete`
- `ReplacePart`
- `MapAt`

The important acceptance criteria are:

- top-level key and string-key lookup works;
- nested list/association paths work;
- selector-list key subsets rebuild associations;
- mixed integer/key selector lists are rejected;
- delete semantics remove entries when the final component addresses an association slot.

### Step 7. Extend StandardForm row-box normalization

Add row-box token normalization for association and rule tokens, then add tests using real snippets
from `Association.nb`.

## Test plan

### Parser tests

Add kernel-free tests that parse:

- `InputForm` association literals with symbol keys;
- `InputForm` association literals with string keys;
- `InputForm` key-based part specs;
- `StandardForm` row-box association examples extracted from `Association.nb`;
- `StandardForm` nested list/association part examples extracted from `Association.nb`.

### Evaluator tests

Add unit tests for:

- constructor normalization and duplicate-key ordering;
- `Keys`, `Values`, `Normal`, `Lookup`, `KeyExistsQ`, `KeyMemberQ`;
- `KeyTake`, `KeyDrop`, `KeyMap`, `KeyValueMap`, `AssociationThread`, `AssociationMap`;
- association-aware `First`, `Last`, `Rest`, `Most`, `Map`, `Apply`;
- `Part`, `Extract`, `Delete`, `ReplacePart`, `MapAt` with:
  - integer positions;
  - `Key[...]` positions;
  - string-key shorthand;
  - nested mixed paths;
  - multi-key selector lists;
  - invalid mixed selector-list cases.

### Doc-derived tests

Extend the existing notebook-example test fixture pattern so `test_expression.py` extracts real
snippets from `Association.nb`, not just hard-coded strings.

High-value doc snippets to anchor:

- plain association literal row boxes;
- `[[Key[b]]]` example;
- numeric `[[2]]` example;
- mixed `{1, Key[b], 2}` example;
- string-key shorthand example.

### Live-kernel comparison tests

The test suite should remain kernel-free by default, but this task should also add or document a
maintainer smoke path that compares Tungsten results to live kernel expectations for a curated
association case set.

## Documentation updates planned after implementation

After the code lands, update:

- `docs/expression-parser.md`
  - supported association syntax and semantics;
- `docs/expression-function-support.md`
  - add association-oriented functions and note their supported forms;
- `README.md`
  - expand the expression subsystem description to mention association support if the resulting
    surface is substantial enough.

## Acceptance criteria

This task is complete when all of the following are true:

1. Association literals parse correctly in `InputForm` and in the supported `StandardForm` subset,
   including real row-box examples from installed notebooks.
2. Exact-position association traversal works for `Part`, `Extract`, `Delete`, `ReplacePart`, and
   `MapAt`, including mixed list/association nesting.
3. Tungsten implements a substantial, documented association function surface without a kernel.
4. The supported surface is documented in current-state Tungsten docs, with explicit boundaries.
5. Validation passes for the updated Python tests, and the implementation has been calibrated
   against live-kernel experiments recorded in this plan.
