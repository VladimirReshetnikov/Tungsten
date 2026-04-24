# Tungsten Structural Expression Function Support

- Status: Informational and reference-oriented (kernel-free structural expression support matrix)
- Audience: Tungsten users, automation authors, maintainers, and anyone relying on offline Wolfram expression manipulation
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-23T18:33:04Z
- Updated (UTC): 2026-04-24T02:48:08Z
- Repository HEAD: b434ae1b0cac0653c6954d72f4f6df6148ecb345
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Usage Reference](./usage-reference.md)
  - [Project README](../README.md)

## Purpose

This document lists the Wolfram Language structural-manipulation functions that Tungsten currently
implements without a running kernel. These functions operate on Tungsten's own inert AST. Unknown
symbols remain inert, and Tungsten does not implement general Wolfram evaluation semantics.

## Important boundaries

- The functions below are implemented only for the direct forms listed in the "Tungsten-supported
  forms" column.
- Operator forms are generally out of scope unless Tungsten explicitly lowers them to the direct
  forms below, such as `expr /. rules` to `ReplaceAll[expr, rules]` and `expr //. rules` to
  `ReplaceRepeated[expr, rules]`.
- `Take` and `Drop` currently support a single first-level specification only.
- `Map` currently supports `Map[f, expr]` only.
- `Apply` currently supports `Apply[f, expr]` only.
- `Flatten` currently supports `Flatten[expr]` and `Flatten[expr, n]` where `n` is a non-negative
  integer or `Infinity`.
- Association-aware exact positions currently apply only to real `Association[...]` expressions, not
  to arbitrary lists of rules.
- `AssociationMap` currently supports the key-list form only: `AssociationMap[f, {k1, ...}]`.
- `Lookup`, `Keys`, `Values`, `Normal`, `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`,
  `KeyMap`, and `KeyValueMap` currently expect an `Association`.
- `ReplacePart` supports exact position rules and ignores positions that do not exist, matching the
  practical behavior of Wolfram's direct rule form.
- `Delete` and `MapAt` support exact positions and lists of exact positions; invalid positions
  currently surface as Tungsten evaluation errors.
- `ReplaceAt` supports exact positions and lists of exact positions, but it currently expects a
  single rule or a flat list of rules rather than a nested list of rule lists.
- `ReplaceRepeated` uses a Tungsten-side iteration safety cap to avoid non-terminating rewrite
  loops.
- Arithmetic and Boolean evaluation are intentionally narrow: Tungsten does not honor `Flat`,
  `Orderless`, or short-circuit attributes here, and only evaluates the covered heads when every
  participating argument is already an explicit integer or Boolean value in the shipped subset.
- Pure functions currently support positional slot forms only:
  `Function[body]`, `body &`, `Slot[n]`, `Slot[]`, `Slot[0]`, `#`, `#n`, `#0`, and the
  Tungsten-specific shorthand `#name` for `#1["name"]`.
- `SlotSequence` and `##` are not implemented yet.
- The current pattern subset includes a deliberately narrow slice of variable-length sequence
  patterns: anonymous `__`, `___`, `BlankSequence[...]`, and `BlankNullSequence[...]` match a
  single candidate expression directly, and they also support multi-element matching when there is
  at most one such pattern in a containing argument list.
- `Condition` / `/;` is supported in patterns and in delayed-rule right-hand sides, but only when
  the substituted guard expression reduces to explicit `True` under Tungsten's shipped evaluator.
- Named sequence patterns such as `x__`, `x___`, and `Pattern[x, BlankSequence[]]` remain out of
  scope, as do options, pattern tests, and other advanced matching forms.
- Pattern search on associations is deliberately conservative in this pass: associations can match
  as whole expressions such as `_Association`, but `FreeQ`, `Cases`, and `DeleteCases` currently
  treat associations as opaque leaves instead of descending into keys or values.
- Replacement functions are less conservative than the search functions above: `Replace` traverses
  association values, `ReplaceAll` and `ReplaceRepeated` traverse association heads and values, and
  `ReplaceAt` supports key-aware exact paths into association values.

## Supported functions

| Function | Tungsten-supported forms | Brief description | Official Wolfram docs |
|------|------|------|------|
| `Length` | `Length[expr]` | Returns the number of immediate arguments in an expression. | [Length](https://reference.wolfram.com/language/ref/Length) |
| `Depth` | `Depth[expr]` | Returns the structural depth of an expression tree. For associations, Tungsten measures depth through values rather than keys or raw `Rule` wrappers. | [Depth](https://reference.wolfram.com/language/ref/Depth) |
| `Head` | `Head[expr]` | Returns the head of an expression. | [Head](https://reference.wolfram.com/language/ref/Head) |
| `Plus` | `Plus[i1, ...]` and infix `+` when nested evaluation reaches an all-integer subexpression | Adds explicit integer arguments. `Plus[]` yields `0`. Mixed expressions remain inert. | [Plus](https://reference.wolfram.com/language/ref/Plus) |
| `Times` | `Times[i1, ...]` and infix `*` when nested evaluation reaches an all-integer subexpression | Multiplies explicit integer arguments. `Times[]` yields `1`. Mixed expressions remain inert. | [Times](https://reference.wolfram.com/language/ref/Times) |
| `Power` | `Power[base, exponent]` and infix `^` when both arguments are integers and the exponent is non-negative, excluding `0^0` | Raises an integer base to a non-negative integer exponent when the result stays in the integer subset. Negative exponents remain inert in this pass. | [Power](https://reference.wolfram.com/language/ref/Power) |
| `Equal` | `Equal[i1, ...]` and infix `==` when every argument is an explicit integer | Returns `True` when all explicit integer arguments are equal. Zero- and one-argument forms return `True`. | [Equal](https://reference.wolfram.com/language/ref/Equal) |
| `Unequal` | `Unequal[i1, ...]` and infix `!=` when every argument is an explicit integer | Returns `True` when all explicit integer arguments are pairwise distinct. | [Unequal](https://reference.wolfram.com/language/ref/Unequal) |
| `Less` | `Less[i1, ...]` and infix `<` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are strictly increasing. | [Less](https://reference.wolfram.com/language/ref/Less) |
| `LessEqual` | `LessEqual[i1, ...]` and infix `<=` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are nondecreasing. | [LessEqual](https://reference.wolfram.com/language/ref/LessEqual) |
| `Greater` | `Greater[i1, ...]` and infix `>` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are strictly decreasing. | [Greater](https://reference.wolfram.com/language/ref/Greater) |
| `GreaterEqual` | `GreaterEqual[i1, ...]` and infix `>=` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are nonincreasing. | [GreaterEqual](https://reference.wolfram.com/language/ref/GreaterEqual) |
| `Not` | `Not[bool]` and prefix `!bool` when the argument is explicit `True` or `False` | Negates an explicit Boolean value. | [Not](https://reference.wolfram.com/language/ref/Not) |
| `And` | `And[b1, ...]` and infix `&&` when every argument of the evaluated subexpression is explicit `True` or `False` | Computes Boolean conjunction for explicit Boolean arguments only. Tungsten does not apply short-circuit or flattening semantics in this pass. | [And](https://reference.wolfram.com/language/ref/And) |
| `Or` | `Or[b1, ...]` and infix `||` when every argument of the evaluated subexpression is explicit `True` or `False` | Computes Boolean disjunction for explicit Boolean arguments only. Tungsten does not apply short-circuit or flattening semantics in this pass. | [Or](https://reference.wolfram.com/language/ref/Or) |
| `Condition` | `Condition[patt, test]`, `patt /; test`, and top-level delayed-template guards such as `lhs :> rhs /; test` | Guards a pattern or delayed-rule template. Tungsten treats the guard as satisfied only when the substituted test reduces to explicit `True` under the shipped evaluator. | [Condition](https://reference.wolfram.com/language/ref/Condition) |
| `RuleDelayed` | `lhs :> rhs`, including guarded forms such as `lhs :> rhs /; test` | Delays right-hand-side instantiation until after pattern bindings are known. A top-level delayed-template `Condition` guard can suppress the rule and fall through to later rules when present. | [RuleDelayed](https://reference.wolfram.com/language/ref/RuleDelayed) |
| `MatchQ` | `MatchQ[expr, patt]` | Structurally tests whether `expr` matches Tungsten's supported pattern subset, including `Blank`, anonymous `__` / `___` sequence patterns, named patterns over `Blank`, guarded patterns via `/;`, `Alternatives`, `Except`, `HoldPattern`, and `Verbatim`. Multi-element `__` / `___` matching is limited to one such pattern per containing argument list. | [MatchQ](https://reference.wolfram.com/language/ref/MatchQ) |
| `FreeQ` | `FreeQ[expr, patt]`, `FreeQ[expr, patt, levelspec]` | Returns `True` when no searched subexpression matches the supported pattern subset. Tungsten follows Wolfram's default `Heads -> True` behavior for `FreeQ`. Multi-element `__` / `___` matching is limited to one such pattern per containing argument list, and guarded patterns succeed only when the guard reduces to explicit `True`. | [FreeQ](https://reference.wolfram.com/language/ref/FreeQ) |
| `Cases` | `Cases[expr, patt]`, `Cases[expr, patt, levelspec]`, `Cases[expr, patt, levelspec, n]`, `Cases[expr, patt :> rhs]`, `Cases[expr, patt :> rhs, levelspec]` | Collects matching subexpressions in depth-first postorder, with optional template substitution through named-pattern bindings. Anonymous `__` / `___` patterns are supported under Tungsten's one-per-argument-list limit, and delayed templates may use `/;` as a post-substitution guard. | [Cases](https://reference.wolfram.com/language/ref/Cases) |
| `DeleteCases` | `DeleteCases[expr, patt]`, `DeleteCases[expr, patt, levelspec]`, `DeleteCases[expr, patt, levelspec, n]` | Removes matching subexpressions in depth-first postorder, deleting leaves before roots. Whole-expression deletion at level `0` is not implemented yet. Anonymous `__` / `___` patterns and guarded patterns are supported under Tungsten's documented limits. | [DeleteCases](https://reference.wolfram.com/language/ref/DeleteCases) |
| `Replace` | `Replace[expr, rules]`, `Replace[expr, rules, levelspec]`, nested rule-list forms such as `Replace[expr, {{rules1...}, {rules2...}}, levelspec]` | Applies the first matching rule per visited part, with Wolfram-style levelspec semantics and bottom-up traversal over the covered subset. Guarded left-hand-side patterns are supported, and delayed right-hand-side guards such as `lhs :> rhs /; test` fire only when the substituted guard reduces to explicit `True`. On associations, Tungsten traverses values rather than keys or raw `Rule` wrappers. | [Replace](https://reference.wolfram.com/language/ref/Replace) |
| `ReplaceAll` | `ReplaceAll[expr, rule]`, `ReplaceAll[expr, {rule1, ...}]`, nested rule-list forms such as `ReplaceAll[expr, {{rules1...}, {rules2...}}]` | Performs a single top-down rewrite pass over the covered subset. Tungsten also supports the parser-lowered operator form `expr /. rules`. Guarded left-hand-side patterns are supported, and delayed right-hand-side guards such as `lhs :> rhs /; test` can suppress a rule and fall through to later rules. On associations, Tungsten rewrites the whole association first, then the head and values, but not keys or raw `Rule` wrappers. | [ReplaceAll](https://reference.wolfram.com/language/ref/ReplaceAll) |
| `ReplaceRepeated` | `ReplaceRepeated[expr, rule]`, `ReplaceRepeated[expr, {rule1, ...}]`, nested rule-list forms such as `ReplaceRepeated[expr, {{rules1...}, {rules2...}}]` | Repeats the covered `ReplaceAll` semantics until a structural fixed point is reached. Tungsten also supports the parser-lowered operator form `expr //. rules`. Non-terminating rewrite loops stop at a Tungsten safety cap and raise an evaluation error. Guarded delayed rules are reapplied until the guard stops succeeding or a structural fixed point is reached. | [ReplaceRepeated](https://reference.wolfram.com/language/ref/ReplaceRepeated) |
| `Function` | `Function[body]`, `body &`, plus positional slot applications such as `Function[body][arg1, ...]` | Supports positional pure functions over `Slot` forms. Tungsten recognizes `#`, `#n`, `#0`, `Slot[]`, `Slot[n]`, and the Tungsten-specific `#name` shorthand for `#1["name"]`. Nested pure functions keep their own local slots. | [Function](https://reference.wolfram.com/language/ref/Function) |
| `Association` | `Association[rule1, ...]`, `Association[{rule1, ...}]`, `Association[assoc]` | Normalizes associations structurally, including last-occurrence-wins duplicate-key semantics. Invalid constructor forms remain inert. | [Association](https://reference.wolfram.com/language/ref/Association) |
| `AssociationQ` | `AssociationQ[expr]` | Returns `True` when Tungsten recognizes a structural association value. | [AssociationQ](https://reference.wolfram.com/language/ref/AssociationQ) |
| `Part` | `Part[expr, spec1, ...]` | Extracts parts by exact structural position, including spans, `All`, and selector lists. On associations, Tungsten supports numeric positions, `Key[key]`, and string-key shorthand for string keys. | [Part](https://reference.wolfram.com/language/ref/Part) |
| `Extract` | `Extract[expr, pos]` | Extracts one or more parts using explicit position lists. Association positions support numeric components, `Key[key]`, and string-key shorthand. | [Extract](https://reference.wolfram.com/language/ref/Extract) |
| `Level` | `Level[expr, spec]`, `Level[expr, spec, False]` | Returns subexpressions at requested positive or negative levels. Associations are traversed through values rather than keys. | [Level](https://reference.wolfram.com/language/ref/Level) |
| `First` | `First[expr]`, `First[expr, default]` | Returns the first argument of an expression, with optional default for empty expressions. For associations, this is the first value. | [First](https://reference.wolfram.com/language/ref/First) |
| `Last` | `Last[expr]`, `Last[expr, default]` | Returns the last argument of an expression, with optional default for empty expressions. For associations, this is the last value. | [Last](https://reference.wolfram.com/language/ref/Last) |
| `Rest` | `Rest[expr]` | Returns an expression with its first argument removed. For associations, Tungsten removes the first key-value entry. | [Rest](https://reference.wolfram.com/language/ref/Rest) |
| `Most` | `Most[expr]` | Returns an expression with its last argument removed. For associations, Tungsten removes the last key-value entry. | [Most](https://reference.wolfram.com/language/ref/Most) |
| `Take` | `Take[expr, n]`, `Take[expr, All]`, `Take[expr, span]`, `Take[expr, {n}]`, `Take[expr, {m, n}]`, `Take[expr, {m, n, s}]` | Selects a first-level slice while preserving the original head. For associations, supported specifications are still numeric or span-style only. | [Take](https://reference.wolfram.com/language/ref/Take) |
| `Drop` | `Drop[expr, n]`, `Drop[expr, All]`, `Drop[expr, span]`, `Drop[expr, {n}]`, `Drop[expr, {m, n}]`, `Drop[expr, {m, n, s}]` | Removes a first-level slice while preserving the original head. For associations, supported specifications are still numeric or span-style only. | [Drop](https://reference.wolfram.com/language/ref/Drop) |
| `Append` | `Append[expr, item]` | Adds an argument at the end of a nonatomic expression. For associations, Tungsten expects a rule and updates or appends the corresponding key. | [Append](https://reference.wolfram.com/language/ref/Append) |
| `Prepend` | `Prepend[expr, item]` | Adds an argument at the beginning of a nonatomic expression. For associations, Tungsten expects a rule and updates or prepends the corresponding key. | [Prepend](https://reference.wolfram.com/language/ref/Prepend) |
| `Join` | `Join[expr1, expr2, ...]` | Concatenates expressions that share the same head. For associations, Tungsten concatenates entries and reapplies last-occurrence-wins normalization. | [Join](https://reference.wolfram.com/language/ref/Join) |
| `Reverse` | `Reverse[expr]` | Reverses the order of the immediate arguments of an expression. Associations reverse entry order. | [Reverse](https://reference.wolfram.com/language/ref/Reverse) |
| `RotateLeft` | `RotateLeft[expr]`, `RotateLeft[expr, n]` | Rotates immediate arguments to the left. Associations rotate entry order. | [RotateLeft](https://reference.wolfram.com/language/ref/RotateLeft) |
| `RotateRight` | `RotateRight[expr]`, `RotateRight[expr, n]` | Rotates immediate arguments to the right. Associations rotate entry order. | [RotateRight](https://reference.wolfram.com/language/ref/RotateRight) |
| `Flatten` | `Flatten[expr]`, `Flatten[expr, n]`, `Flatten[expr, Infinity]` | Flattens nested subexpressions that have the same head as the outer expression. | [Flatten](https://reference.wolfram.com/language/ref/Flatten) |
| `Delete` | `Delete[expr, pos]` | Removes one or more exact-position parts from an expression. For associations, a final top-level key or numeric selector removes an entry, while deeper suffixes operate inside the selected value. | [Delete](https://reference.wolfram.com/language/ref/Delete) |
| `ReplaceAt` | `ReplaceAt[expr, rule, pos]`, `ReplaceAt[expr, {rule1, ...}, pos]` | Applies replacement rules only at explicitly targeted exact positions. If the target position exists but none of the supplied rules matches there, the result is left unchanged. Association positions reuse the same key-aware exact-path syntax as `Part`. | [ReplaceAt](https://reference.wolfram.com/language/ref/ReplaceAt) |
| `ReplacePart` | `ReplacePart[expr, rule]`, `ReplacePart[expr, {rule1, ...}]` | Replaces exact-position parts using explicit rules. For associations, top-level selectors replace entry values, not entire rules. | [ReplacePart](https://reference.wolfram.com/language/ref/ReplacePart) |
| `Apply` | `Apply[f, expr]` | Replaces the head of a nonatomic expression with another expression. For associations, Tungsten applies over values, producing `f[value1, ...]`. | [Apply](https://reference.wolfram.com/language/ref/Apply) |
| `Map` | `Map[f, expr]` | Applies a function structurally to each immediate argument. For associations, Tungsten maps over values and keeps keys unchanged. | [Map](https://reference.wolfram.com/language/ref/Map) |
| `MapAt` | `MapAt[f, expr, pos]` | Applies a function structurally at one or more exact positions. Association positions target values using the same key-aware position syntax as `Part`. | [MapAt](https://reference.wolfram.com/language/ref/MapAt) |
| `Keys` | `Keys[assoc]` | Returns the keys of an association as a list. | [Keys](https://reference.wolfram.com/language/ref/Keys) |
| `Values` | `Values[assoc]` | Returns the values of an association as a list. | [Values](https://reference.wolfram.com/language/ref/Values) |
| `Normal` | `Normal[assoc]` | Converts an association to a plain list of rules. | [Normal](https://reference.wolfram.com/language/ref/Normal) |
| `Lookup` | `Lookup[assoc, key]`, `Lookup[assoc, key, default]`, `Lookup[assoc, {key1, ...}]`, `Lookup[assoc, {key1, ...}, default]` | Looks up one or more keys, returning `Missing["KeyAbsent", key]` when no default is provided. | [Lookup](https://reference.wolfram.com/language/ref/Lookup) |
| `KeyExistsQ` | `KeyExistsQ[assoc, key]` | Tests whether an association contains a key. | [KeyExistsQ](https://reference.wolfram.com/language/ref/KeyExistsQ) |
| `KeyMemberQ` | `KeyMemberQ[assoc, key]` | Synonym-style key-membership test supported for associations. | [KeyMemberQ](https://reference.wolfram.com/language/ref/KeyMemberQ) |
| `KeyTake` | `KeyTake[assoc, key]`, `KeyTake[assoc, {key1, ...}]` | Selects key-value pairs by explicit key list, preserving requested-key order. | [KeyTake](https://reference.wolfram.com/language/ref/KeyTake) |
| `KeyDrop` | `KeyDrop[assoc, key]`, `KeyDrop[assoc, {key1, ...}]` | Removes key-value pairs by explicit key list while preserving the order of the remaining entries. | [KeyDrop](https://reference.wolfram.com/language/ref/KeyDrop) |
| `KeyMap` | `KeyMap[f, assoc]` | Applies a function to association keys while keeping values unchanged and re-normalizing duplicate mapped keys. | [KeyMap](https://reference.wolfram.com/language/ref/KeyMap) |
| `KeyValueMap` | `KeyValueMap[f, assoc]` | Returns a list of `f[key, value]` results in association order. | [KeyValueMap](https://reference.wolfram.com/language/ref/KeyValueMap) |
| `AssociationThread` | `AssociationThread[{k1, ...}, {v1, ...}]` | Builds an association from parallel key and value lists of equal length. | [AssociationThread](https://reference.wolfram.com/language/ref/AssociationThread) |
| `AssociationMap` | `AssociationMap[f, {k1, ...}]` | Builds an association that maps each listed key to `f[key]`. | [AssociationMap](https://reference.wolfram.com/language/ref/AssociationMap) |

## Notes on position semantics

- Tungsten position handling is exact and structural. It does not implement pattern matching.
- The same position syntax family is shared across `Part`, `Extract`, `Delete`, `ReplacePart`, and
  `MapAt`, but not every Wolfram-language variant is implemented.
- `Part` and `Extract` support selector-style components such as `All`, spans, selector lists,
  `Key[key]`, and string-key shorthand inside associations.
- On associations, selector lists may be all numeric-like (`2`, `All`, spans) or all key-like
  (`Key[a]`, `"name"`), but Tungsten rejects mixed numeric-and-key selector lists.
- `ReplacePart` and `MapAt` support exact position lists and lists of exact position lists, now
  including association-aware key components.
- Tungsten canonicalizes negative positions to concrete positive positions internally before
  applying updates, which keeps multi-update behavior deterministic.

## Notes on pattern semantics

- The supported shorthand syntax includes `_`, `_Head`, anonymous `__`, `___`, optional
  head-qualified forms such as `__Integer`, named `x_`, `x_Head`, guarded patterns via `/;`, and
  infix alternatives such as `a | b`.
- Tungsten lowers pattern shorthand to ordinary AST nodes such as `Blank[...]`, `Pattern[...]`, and
  `Alternatives[...]`, so canonical `input_form` output is explicit rather than shorthand-preserving.
- `Cases` and `DeleteCases` use Wolfram-compatible defaults for the implemented subset:
  `levelspec` defaults to `{1}` and heads are not searched in this pass.
- `FreeQ` uses Wolfram-compatible defaults for the implemented subset:
  `levelspec` defaults to `{0, Infinity}` and heads are searched.
- `Cases` and `DeleteCases` currently traverse expressions in the same depth-first postorder that
  the live kernel exhibits for the covered examples, which means leaves appear before parents in
  both the collected result order and the delete order.
- `Cases[..., patt :> rhs]` supports named-pattern substitution and then structurally evaluates the
  substituted result with Tungsten's inert evaluator.
- Guarded patterns via `Condition` / `/;` are supported when the substituted guard expression
  evaluates to explicit `True`.
- Delayed rule right-hand sides such as `x_ :> rhs /; test` are supported as guarded delayed
  templates. If the substituted guard is not explicit `True`, Tungsten treats that rule as not
  having fired and continues to later rules when present.
- Anonymous `BlankSequence` / `BlankNullSequence` patterns match a single candidate expression
  directly, and they also support multi-element matching in direct argument lists when there is at
  most one such pattern in the containing list.
- Named sequence patterns and other advanced forms such as `PatternTest` and `Optional` currently
  raise Tungsten evaluation errors instead of being silently treated as literals.

## Notes on pure functions

- `#` is parsed as `Slot[1]`.
- `Slot[]` remains distinct in the AST, but Tungsten treats it the same as `Slot[1]` when a pure
  function is actually applied.
- `#0` and `Slot[0]` refer to the pure function itself.
- `#name` is a Tungsten-specific shorthand for `#1["name"]`; it is not named-argument support.
- Tungsten does not yet implement `SlotSequence` or `##`.

## Notes on arithmetic and Boolean semantics

- Tungsten parses infix arithmetic, relational, and Boolean operators into ordinary head-based AST
  calls such as `Plus[...]`, `Less[...]`, `And[...]`, and `Not[...]`.
- In this pass, Tungsten does not flatten or reorder `Plus`, `Times`, `And`, `Or`, or the
  relational heads during parsing or evaluation.
- That means nested operator forms can partially simplify one binary layer at a time. For example,
  `1 + 2 + a` becomes `Plus[3, a]`, while `Plus[1, 2, a]` stays inert.
- Boolean operator forms behave the same way: `True && False && x` becomes `And[False, x]`, while
  `And[True, False, x]` stays inert in this pass.

## Notes on atoms and empty expressions

- `Apply[f, atom]` and `Map[f, atom]` leave atoms unchanged.
- `First` and `Last` honor the optional default argument on empty expressions.
- Many sequence-oriented transforms such as `Append`, `Prepend`, `Join`, `Reverse`,
  `RotateLeft`, `RotateRight`, and `Flatten` expect a nonatomic expression.
- Empty nonatomic expressions such as `f[]` are handled structurally where that behavior is
  straightforward and deterministic.
- Empty associations such as `<||>` are also handled structurally where the result is
  deterministic, for example `Depth[<||>] -> 2` and `Part[<||>, All] -> <||>`.
