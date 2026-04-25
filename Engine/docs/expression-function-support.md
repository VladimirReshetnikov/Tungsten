# Tungsten Structural Expression Function Support

- Status: Informational and reference-oriented (kernel-free structural expression support matrix)
- Audience: Tungsten users, automation authors, maintainers, and anyone relying on offline Wolfram expression manipulation
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-23T18:33:04Z
- Updated (UTC): 2026-04-25T21:57:56Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Symbol and Context Registry](./symbol-context-registry.md)
  - [Sequence and Nothing Evaluation](./sequence-nothing-evaluation.md)
  - [Sequence Pattern Matching](./sequence-pattern-matching.md)
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
  forms below or implements them explicitly, such as `expr /. rules` to `ReplaceAll[expr, rules]`,
  `expr //. rules` to `ReplaceRepeated[expr, rules]`, and callable compound forms such as
  `SameAs[q]`, `Composition[f, g]`, `RightComposition[f, g]`, `MapApply[f]`, `MapAll[f]`,
  `MapIndexed[f]`, `Scan[f]`, `Comap[fs]`, and `ComapApply[fs]`.
- Parser-lowered operator syntax includes `@`, `//`, `/@`, `@@`, `@@@`, `@*`, `/*`, `.`, `/.`,
  `//.`, `;;`, arithmetic operators, comparison operators, Boolean operators, and string
  concatenation / string-pattern operators. Callable operator forms such as `Map[f]`, `Cases[p]`,
  or `ReplaceAll[rules]` are not implemented unless explicitly listed in this document.
- `Take` and `Drop` currently support a single first-level specification only.
- `If`, `Which`, `Switch`, `Piecewise`, and `Pick` currently support only the direct forms listed
  below.
- `Select`, `Discard`, and `SelectFirst` currently support their direct forms plus the one-argument
  operator forms `Select[crit]`, `Discard[crit]`, and `SelectFirst[crit]`.
- `Select`, `Discard`, and `SelectFirst` currently support only the `"Element"` and `"Index"`
  property forms, plus lists composed from those two property names.
- `TakeWhile` currently supports only the direct two-argument form.
- `Pick` currently supports selector expressions whose immediate structural shape is compatible
  with the data expression. Nested compatible selectors are supported, but Tungsten does not aim to
  replicate every scalar-selector corner case from the full kernel.
- `Map` currently supports `Map[f, expr]` only.
- `Apply` currently supports `Apply[f, expr]` only.
- `Scan` currently supports `Scan[f, expr]`, `Scan[f, expr, levelspec]`, and the one-argument
  operator form `Scan[f]`.
- `MapApply` currently supports `MapApply[f, expr]` plus the one-argument operator form
  `MapApply[f]`.
- `MapAll` currently supports `MapAll[f, expr]` plus the one-argument operator form `MapAll[f]`.
- `MapIndexed` currently supports `MapIndexed[f, expr]`, `MapIndexed[f, expr, levelspec]`, and
  the one-argument operator form `MapIndexed[f]`. Only the default level `1` is implemented.
- `Flatten` currently supports `Flatten[expr]` and `Flatten[expr, n]` where `n` is a non-negative
  integer or `Infinity`.
- `Through` currently supports only the single-argument direct form.
- `MapThread` currently supports only level `1`, and currently expects a list of `List`
  expressions.
- `Distribute` currently supports only the common direct forms
  `Distribute[expr]`, `Distribute[expr, g]`, and `Distribute[expr, g, f]`.
- `Inner` currently supports first-level compounds of equal length only.
- `Dot` currently supports `List` vectors and rectangular `List` matrices only.
- `Array` and `ConstantArray` currently support only the two-argument direct forms without
  explicit origins or padding specifications.
- `UnitVector` currently supports only the two-argument integer form `UnitVector[n, k]`.
- `Partition` and `BlockMap` currently support only one-dimensional direct forms with an optional
  positive integer offset.
- `FoldWhile` and `FoldWhileList` currently support the explicit-initial-value forms with optional
  positive history length or `All`, plus an optional trailing-count integer.
- `FoldPair` and `FoldPairList` currently support the explicit-initial-value forms only. The fold
  function must return a two-element `List`, and `FoldPair` currently remains inert on empty
  input.
- `DeleteDuplicatesBy` evaluates its key function result under Tungsten's shipped evaluator, so
  built-ins such as `Length` work when they are themselves supported by Tungsten.
- Association-aware exact positions currently apply only to real `Association[...]` expressions, not
  to arbitrary lists of rules.
- `AssociationMap` currently supports the key-list form only: `AssociationMap[f, {k1, ...}]`.
- `Lookup`, `Keys`, `Values`, `Normal`, `KeyExistsQ`, `KeyMemberQ`, `KeyTake`, `KeyDrop`,
  `KeyMap`, and `KeyValueMap` currently expect an `Association`.
- Associations in function position support the common single-key lookup form `assoc[key]`,
  returning `Missing["KeyAbsent", key]` when no entry exists.
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
- `Sequence[...]` splices into evaluated call arguments, including lists and ordinary symbolic
  calls. It also splices structurally, without evaluating its payload, inside held-but-not-
  sequence-suppressing heads such as `Hold`, `HoldForm`, `HoldPattern`, and `Function`.
  Tungsten suppresses splicing for `HoldComplete`, `Unevaluated`, `Rule`, and `RuleDelayed`.
- `Nothing` is removed from evaluated `List[...]` result lists and from direct `Association[...]`
  constructor placeholders. It is retained as an ordinary argument to non-list heads, retained as an
  association value such as `Rule[key, Nothing]`, and retained inside held subexpressions.
- Hold-family wrappers `Hold`, `HoldComplete`, `HoldForm`, `HoldPattern`, and `Unevaluated` keep
  their arguments unevaluated in Tungsten's structural evaluator. `ReleaseHold` strips one outer
  Hold-family wrapper and evaluates the released payload.
- Simple predicate heads are intentionally narrow too: Tungsten currently implements only
  `IntegerQ`, `StringQ`, `DigitQ`, `LetterQ`, `ByteArrayQ`, `EvenQ`, `OddQ`, and `TrueQ`, and only
  over the explicit values described in the support table below.
- String/byte conversion heads are also intentionally bounded: Tungsten currently supports the
  common encodings `"Unicode"`, `"UTF-8"`, `"UTF-16LE"`, `"UTF-16BE"`, `"UTF-32LE"`,
  `"UTF-32BE"`, `"ASCII"`, `"ISO8859-1"`, and `"ISO8859-15"` where they make sense, rather than
  the full Wolfram `$CharacterEncodings` surface.
- String heads are still intentionally bounded in this pass: Tungsten currently supports
  `StringTake`, `StringDrop`, `StringJoin`, `StringInsert`, `StringReverse`, and a pragmatic
  symbolic string-pattern subset for `StringMatchQ`, `StringFreeQ`, `StringStartsQ`,
  `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, and `StringReplace`,
  operating on explicit strings and `List`-threaded lists of explicit strings without options.
- `ImportString`, `ExportString`, `ImportByteArray`, and `ExportByteArray` currently support only
  explicit two-argument forms with an explicit format specification.
- The currently supported import/export formats are `"Byte"`, `"String"`, `"Text"`, `"WL"`,
  `"JSON"`, `"RawJSON"`, `"CSV"`, `"TSV"`, and `"Table"`, plus compression-wrapper specs
  `{"GZIP", inner}` and `{"BZIP2", inner}`.
- Auto-detection and general element specifications are out of scope in this pass.
- `ToString`, `ToExpression`, `ToBoxes`, `MakeBoxes`, `MakeExpression`, `StripBoxes`, `SyntaxQ`,
  and `SyntaxLength` currently support only `InputForm` and Tungsten's textual / box-backed
  `StandardForm` subset. Unlike the Wolfram kernel, one-argument `ToString[expr]` renders
  canonical `InputForm` so the result is parseable by Tungsten's kernel-free `ToExpression`.
  `ToExpression[boxes]` uses StandardForm box interpretation, while `MakeExpression[boxes, form]`
  returns held syntax as `HoldComplete[...]`. FrontEnd-dependent formats such as `TraditionalForm`,
  `TeXForm`, and `MathMLForm` remain out of scope.
- Box conversion is semantic rather than pixel-perfect. Tungsten understands ordinary `RowBox`
  syntax, wrapper stripping, fractions, radicals, powers, subscripts, subsuperscripts, over/under
  scripts, and named-character infix operators such as `\[CirclePlus]`. It does not implement
  custom notation, stylesheet-dependent box rules, or the Notation package.
- Symbol and context functions use Tungsten's process-local registry. `$Context` and `$ContextPath`
  are fixed to <code>"Global`"</code> and <code>{"System`", "Global`"}</code> for now; user-defined
  symbols have no own values, down values, up values, or sub values yet. The registry is seeded
  from a Wolfram 14.3 snapshot of 7800 immediate <code>System`</code> symbols, including read-only
  per-symbol attributes used by `Attributes`, `Names`, and `NameQ`.
- That string-pattern subset supports literal strings, `StringExpression` / `~~`, anonymous `_`,
  `__`, `___`, `Repeated[p]` / `p..`, `RepeatedNull[p]` / `p...`, named captures including
  `x : __` and `x : ___`, `Alternatives`, `Condition`, `PatternTest`, `HoldPattern`,
  `Shortest`, `Longest`, `Except` over supported one-character disallowed and allowed patterns,
  `CharacterRange`, `RegularExpression`, a practical `DatePattern` subset, `Whitespace`, and the
  common character classes / anchors such as `DigitCharacter`, `HexadecimalCharacter`,
  `LetterCharacter`, `NumberString`, `PunctuationCharacter`, `WhitespaceCharacter`,
  `WordCharacter`, `StartOfString`, `EndOfString`, `StartOfLine`, `EndOfLine`, and
  `WordBoundary`.
- String patterns no longer have a single-unbounded-element limit. Ambiguous string sequences are
  greedy by default, `Shortest[...]` makes the wrapped subtree non-greedy, and `Longest[...]`
  requests greedy allocation explicitly.
- Tungsten delegates `RegularExpression` to Python's `re` implementation and uses Python /
  Unicode-library predicates for character classes. This is intentional: the compatibility goal is
  structural and practical rather than exact PCRE-version or Unicode-version parity with the
  Wolfram kernel.
- String-pattern `Optional`, `OptionsPattern`, string-function options such as `IgnoreCase` /
  `Overlaps`, qualified blank shorthand such as `_DigitCharacter`, and multi-character
  `Except[...]` disallowed atoms such as `Except["ab"]` remain out of scope.
- Base encodings are currently bounded to `"Base16"`, `"Base64"`, and `"Base85ASCII"`.
- The integer-only numeric family below is also intentionally narrow: Tungsten evaluates these
  heads only when the supported arguments are already explicit integers or integer lists in the
  listed direct forms.
- Pure functions currently support positional slot forms, `SlotSequence` / `##`, named-parameter
  forms such as `Function[x, body]`, `Function[{x, y}, body]`, `x |-> body`, and
  `x \[Function] body`, and the evaluation-impact subset of third-argument `Function` attributes.
- Named pure functions use Tungsten's capture-avoiding renaming rule for nested named functions.
  The exact rule is documented in [named-pure-functions-spec.md](./named-pure-functions-spec.md).
- `Function[params, body, attrs]` currently honors `HoldFirst`, `HoldRest`, `HoldAll`,
  `HoldAllComplete`, `SequenceHold`, and `Listable`. Other attribute names are accepted
  structurally but do not yet change evaluation.
- REPL-only session history heads `In`, `InString`, `Out`, `$Line`, and `DownValues` require an
  active `EvaluationSession`, normally created by `python -m tungsten repl` or `tungsten.exe`.
  Outside that context they remain inert or return empty read-only metadata.
- The current structural pattern subset includes variable-length sequence patterns and the common
  advanced argument-pattern forms: anonymous and named `__`, `___`, `BlankSequence[...]`,
  `BlankNullSequence[...]`, `Repeated`, `RepeatedNull`, `PatternSequence`,
  `OrderlessPatternSequence`, `Optional`, `PatternTest`, `Longest`, `Shortest`, and
  `OptionsPattern`. Allocation is left-to-right shortest-first with backtracking unless a wrapped
  pattern explicitly requests greedy `Longest` behavior, as documented in
  [sequence-pattern-matching.md](./sequence-pattern-matching.md).
- `Condition` / `/;` is supported in patterns and in delayed-rule right-hand sides, but only when
  the substituted guard expression reduces to explicit `True` under Tungsten's shipped evaluator.
- `Optional[patt, default]` can match an omitted argument and bind named variables to `default`;
  Tungsten intentionally does not yet have a `Default[...]` registry, so `Optional[patt]` / `_.`
  without an explicit default does not synthesize omitted values for arbitrary user-defined heads.
- `OptionsPattern` structurally matches zero or more option rules, `RuleDelayed` option rules, and
  nested lists of option rules with symbol or string keys. It does not validate options against
  `Options[f]` or implement `OptionValue`.
- Association-aware pattern search follows Wolfram's values-only association model. `FreeQ`,
  `Cases`, `DeleteCases`, `FirstCase`, `Position`, and `MemberQ` traverse association values and
  whole associations, but not keys or raw `Rule` wrappers. Use `KeyValuePattern` when a pattern
  needs to match keys or complete association entries.
- Replacement functions use the same values-only association model unless they are explicitly
  operating on the whole association or its head: `Replace` traverses values, `ReplaceAll` and
  `ReplaceRepeated` traverse the whole association first and then its head and values, and
  `ReplaceAt` supports key-aware exact paths into association values.

## Supported functions

| Function | Tungsten-supported forms | Brief description | Official Wolfram docs |
|------|------|------|------|
| `Length` | `Length[expr]` | Returns the number of immediate arguments in an expression. | [Length](https://reference.wolfram.com/language/ref/Length) |
| `Depth` | `Depth[expr]` | Returns the structural depth of an expression tree. For associations, Tungsten measures depth through values rather than keys or raw `Rule` wrappers. | [Depth](https://reference.wolfram.com/language/ref/Depth) |
| `Head` | `Head[expr]` | Returns the head of an expression. | [Head](https://reference.wolfram.com/language/ref/Head) |
| `$Context` | `$Context` and <code>System`$Context</code> | Returns Tungsten's fixed current context string <code>"Global`"</code>. Assignment is not implemented. | [$Context](https://reference.wolfram.com/language/ref/%24Context.html) |
| `$ContextPath` | `$ContextPath` and <code>System`$ContextPath</code> | Returns Tungsten's fixed visible context list <code>{"System`", "Global`"}</code>. Assignment is not implemented. | [$ContextPath](https://reference.wolfram.com/language/ref/%24ContextPath.html) |
| `Symbol` | `Symbol["name"]` | Validates and registers a symbol name, then returns the symbol using visible-context rendering. Names in <code>System`</code> or <code>Global`</code> display by short name; names in other contexts display fully qualified. | [Symbol](https://reference.wolfram.com/language/ref/Symbol.html) |
| `SymbolName` | `SymbolName[sym]` and practical string-name forms | Returns a symbol's short name. Tungsten also accepts strings that name existing symbols, plus explicit valid context-qualified strings. | [SymbolName](https://reference.wolfram.com/language/ref/SymbolName.html) |
| `Context` | `Context[]`, `Context[sym]`, and practical string-name forms for existing symbols | Returns the current context or the registered context of a symbol. | [Context](https://reference.wolfram.com/language/ref/Context.html) |
| `Contexts` | `Contexts[]`, `Contexts["pattern"]` | Lists contexts known to the process-local registry, optionally filtered with Wolfram-style name wildcards. | [Contexts](https://reference.wolfram.com/language/ref/Contexts.html) |
| `Names` | `Names[]`, `Names["pattern"]`, `Names[{"p1", ...}]` | Lists registered symbol names visible to the registry. Visible contexts render by short name; non-visible contexts render fully qualified. | [Names](https://reference.wolfram.com/language/ref/Names.html) |
| `NameQ` | `NameQ["pattern"]` | Returns `True` when `Names["pattern"]` would produce at least one registered symbol. | [NameQ](https://reference.wolfram.com/language/ref/NameQ.html) |
| `Attributes` | `Attributes[sym]`, `Attributes["name"]`, `Attributes[{s1, ...}]` | Returns read-only attribute metadata from the registry. The shipped snapshot mirrors immediate <code>System`</code> symbols from the installed Wolfram 14.3 kernel; user-defined symbols currently have empty attribute lists. Attribute metadata is discoverable even when Tungsten has no evaluator rule for that symbol. | [Attributes](https://reference.wolfram.com/language/ref/Attributes.html) |
| `$Line` | `$Line` in a REPL session | Returns the current REPL input line number during evaluation. Outside an active session it remains inert. | [$Line](https://reference.wolfram.com/language/ref/%24Line.html) |
| `In` | `In[n]`, `In[]`, `In[-k]` in a REPL session | Returns and evaluates stored input expressions from the current REPL session. | [In](https://reference.wolfram.com/language/ref/In.html) |
| `InString` | `InString[n]`, `InString[]`, `InString[-k]` in a REPL session | Returns stored raw input text from the current REPL session. | [InString](https://reference.wolfram.com/language/ref/InString.html) |
| `Out` | `Out[n]`, `Out[]`, `Out[-k]`, plus parser shorthand `%`, `%%`, `%n` | Returns stored output expressions from the current REPL session. | [Out](https://reference.wolfram.com/language/ref/Out.html) |
| `DownValues` | `DownValues[In]`, `DownValues[InString]`, `DownValues[Out]` in a REPL session | Returns read-only history downvalues for the active REPL session. Other symbols currently return `{}` in Tungsten's offline evaluator. | [DownValues](https://reference.wolfram.com/language/ref/DownValues.html) |
| `Exit`, `Quit` | `Exit`, `Exit[]`, `Exit[code]`, `Quit`, `Quit[]`, `Quit[code]` in the REPL | Terminates the Tungsten REPL. Optional integer arguments become the process exit code. | [Exit](https://reference.wolfram.com/language/ref/Exit.html), [Quit](https://reference.wolfram.com/language/ref/Quit.html) |
| `Unique` | `Unique[]`, `Unique[sym]`, `Unique["prefix"]`, `Unique[{spec1, ...}]` | Generates fresh registered symbols using Tungsten's module counter or per-prefix string counters. | [Unique](https://reference.wolfram.com/language/ref/Unique.html) |
| `ValueQ` | `ValueQ[expr]` | Returns `True` for explicit numeric, string, and byte-array literals, `$Context`, `$ContextPath`, and expressions Tungsten can reduce structurally. This is conservative for unreduced built-in calls until Tungsten has value/rule storage; user-defined symbols currently return `False`. | [ValueQ](https://reference.wolfram.com/language/ref/ValueQ.html) |
| `Plus` | `Plus[i1, ...]` and infix `+` when nested evaluation reaches an all-integer subexpression | Adds explicit integer arguments. `Plus[]` yields `0`. Mixed expressions remain inert. | [Plus](https://reference.wolfram.com/language/ref/Plus) |
| `Times` | `Times[i1, ...]` and infix `*` when nested evaluation reaches an all-integer subexpression | Multiplies explicit integer arguments. `Times[]` yields `1`. Mixed expressions remain inert. | [Times](https://reference.wolfram.com/language/ref/Times) |
| `Power` | `Power[base, exponent]` and infix `^` when both arguments are integers and the exponent is non-negative, excluding `0^0` | Raises an integer base to a non-negative integer exponent when the result stays in the integer subset. Negative exponents remain inert in this pass. | [Power](https://reference.wolfram.com/language/ref/Power) |
| `Equal` | `Equal[i1, ...]` and infix `==` when every argument is an explicit integer | Returns `True` when all explicit integer arguments are equal. Zero- and one-argument forms return `True`. | [Equal](https://reference.wolfram.com/language/ref/Equal) |
| `Unequal` | `Unequal[i1, ...]` and infix `!=` when every argument is an explicit integer | Returns `True` when all explicit integer arguments are pairwise distinct. | [Unequal](https://reference.wolfram.com/language/ref/Unequal) |
| `Less` | `Less[i1, ...]` and infix `<` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are strictly increasing. | [Less](https://reference.wolfram.com/language/ref/Less) |
| `LessEqual` | `LessEqual[i1, ...]` and infix `<=` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are nondecreasing. | [LessEqual](https://reference.wolfram.com/language/ref/LessEqual) |
| `Greater` | `Greater[i1, ...]` and infix `>` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are strictly decreasing. | [Greater](https://reference.wolfram.com/language/ref/Greater) |
| `GreaterEqual` | `GreaterEqual[i1, ...]` and infix `>=` when every argument is an explicit integer | Returns `True` when adjacent explicit integer arguments are nonincreasing. | [GreaterEqual](https://reference.wolfram.com/language/ref/GreaterEqual) |
| `IntegerQ` | `IntegerQ[expr]` | Returns `True` when the argument is an explicit integer in Tungsten's AST; otherwise returns `False`. | [IntegerQ](https://reference.wolfram.com/language/ref/IntegerQ) |
| `StringQ` | `StringQ[expr]` | Returns `True` when the argument is an explicit string in Tungsten's AST; otherwise returns `False`. | [StringQ](https://reference.wolfram.com/language/ref/StringQ) |
| `DigitQ` | `DigitQ["string"]` | Returns `True` when the argument is a non-empty explicit string whose characters all satisfy Tungsten's Unicode digit predicate. | [DigitQ](https://reference.wolfram.com/language/ref/DigitQ) |
| `LetterQ` | `LetterQ["string"]` | Returns `True` when the argument is a non-empty explicit string whose characters all satisfy Tungsten's Unicode letter predicate. | [LetterQ](https://reference.wolfram.com/language/ref/LetterQ) |
| `ByteArray` | `ByteArray[{b1, ...}]`, `ByteArray["base64"]`, `ByteArray[ba]` | Constructs Tungsten byte-array values from explicit byte lists, Base64 strings, or existing byte arrays. Tungsten renders these values in Wolfram-style `ByteArray["..."]` InputForm using Base64. | [ByteArray](https://reference.wolfram.com/language/ref/ByteArray) |
| `ByteArrayQ` | `ByteArrayQ[expr]` | Returns `True` when the argument is a Tungsten byte-array value. | [ByteArrayQ](https://reference.wolfram.com/language/ref/ByteArrayQ) |
| `EvenQ` | `EvenQ[expr]` | Returns `True` when the argument is an explicit even integer in Tungsten's AST; otherwise returns `False`. | [EvenQ](https://reference.wolfram.com/language/ref/EvenQ) |
| `OddQ` | `OddQ[expr]` | Returns `True` when the argument is an explicit odd integer in Tungsten's AST; otherwise returns `False`. | [OddQ](https://reference.wolfram.com/language/ref/OddQ) |
| `TrueQ` | `TrueQ[expr]` | Returns `True` only when the argument is explicit `True`; otherwise returns `False`. | [TrueQ](https://reference.wolfram.com/language/ref/TrueQ) |
| `Not` | `Not[bool]` and prefix `!bool` when the argument is explicit `True` or `False` | Negates an explicit Boolean value. | [Not](https://reference.wolfram.com/language/ref/Not) |
| `And` | `And[b1, ...]` and infix `&&` when every argument of the evaluated subexpression is explicit `True` or `False` | Computes Boolean conjunction for explicit Boolean arguments only. Tungsten does not apply short-circuit or flattening semantics in this pass. | [And](https://reference.wolfram.com/language/ref/And) |
| `Or` | `Or[b1, ...]` and infix `||` when every argument of the evaluated subexpression is explicit `True` or `False` | Computes Boolean disjunction for explicit Boolean arguments only. Tungsten does not apply short-circuit or flattening semantics in this pass. | [Or](https://reference.wolfram.com/language/ref/Or) |
| `If` | `If[cond, t]`, `If[cond, t, f]`, `If[cond, t, f, u]` | Evaluates the condition first, then evaluates only the selected branch. `If[cond, t]` yields `Null` when the condition is explicit `False`. The four-argument form uses `u` when the condition is neither explicit `True` nor explicit `False`. | [If](https://reference.wolfram.com/language/ref/If) |
| `Which` | `Which[test1, value1, ...]` with condition-value pairs | Evaluates tests in order. False-leading pairs are dropped; the first explicit `True` selects its value; the first non-Boolean test stops evaluation and leaves a simplified `Which` starting at that test; all-false input yields `Null`. | [Which](https://reference.wolfram.com/language/ref/Which) |
| `Switch` | `Switch[expr, form1, value1, ...]` | Evaluates the subject once, then tries forms in order using Tungsten's supported pattern matcher. Only the first matching value is evaluated. If no form matches, Tungsten returns an inert `Switch` with the evaluated subject. | [Switch](https://reference.wolfram.com/language/ref/Switch) |
| `Piecewise` | `Piecewise[{{value1, cond1}, ...}]`, `Piecewise[{{value1, cond1}, ...}, default]` | Evaluates conditions in order, dropping explicit `False` cases and selecting the first explicit `True` case. Unknown conditions are retained in a simplified `Piecewise`, and only values that remain in the returned form are evaluated. | [Piecewise](https://reference.wolfram.com/language/ref/Piecewise) |
| `Boole` | `Boole[cond]` | Returns `1` for explicit `True`, `0` for explicit `False`, and otherwise remains inert. | [Boole](https://reference.wolfram.com/language/ref/Boole) |
| `Characters` | `Characters["string"]`, `Characters[{"s1", ...}]` | Splits strings into lists of one-character strings. Lists of strings are handled elementwise. | [Characters](https://reference.wolfram.com/language/ref/Characters) |
| `StringLength` | `StringLength["string"]`, `StringLength[{"s1", ...}]` | Returns Unicode-character lengths for explicit strings. Lists of strings are handled elementwise. | [StringLength](https://reference.wolfram.com/language/ref/StringLength) |
| `StringTake` | `StringTake["string", spec]`, `StringTake[{"s1", ...}, spec]` | Takes characters using the list-like specification subset `n`, `All`, `Span`, `{n}`, `{m, n}`, `{m, n, s}`, and direct `UpTo[n]`. Lists of strings are handled elementwise. | [StringTake](https://reference.wolfram.com/language/ref/StringTake) |
| `StringDrop` | `StringDrop["string", spec]`, `StringDrop[{"s1", ...}, spec]` | Drops characters using the same supported specification subset as `StringTake`, including direct `UpTo[n]`. Lists of strings are handled elementwise. | [StringDrop](https://reference.wolfram.com/language/ref/StringDrop) |
| `StringJoin` | `StringJoin[]`, `StringJoin["a", ...]`, `StringJoin[{...}]`, and infix `<>` | Concatenates explicit strings. Tungsten recursively flattens nested lists of strings in the practical Wolfram style before joining. | [StringJoin](https://reference.wolfram.com/language/ref/StringJoin) |
| `StringInsert` | `StringInsert["string", "ins", pos]`, `StringInsert[{"s1", ...}, "ins", pos]` | Inserts an explicit string at one or more explicit integer positions. As in Wolfram, insertion positions refer to the original string when several insertions are requested. Lists of strings are handled elementwise. | [StringInsert](https://reference.wolfram.com/language/ref/StringInsert) |
| `StringReverse` | `StringReverse["string"]`, `StringReverse[{"s1", ...}]` | Reverses characters in explicit strings. Lists of strings are handled elementwise. | [StringReverse](https://reference.wolfram.com/language/ref/StringReverse) |
| `StringMatchQ` | `StringMatchQ["string", patt]`, `StringMatchQ[{"s1", ...}, patt]`, and operator form `StringMatchQ[patt]` | Returns `True` when the whole string matches Tungsten's shipped string-pattern subset. Threads over `List` inputs. | [StringMatchQ](https://reference.wolfram.com/language/ref/StringMatchQ) |
| `StringFreeQ` | `StringFreeQ["string", patt]`, `StringFreeQ[{"s1", ...}, patt]`, and operator form `StringFreeQ[patt]` | Returns `True` when no match for the shipped string-pattern subset exists anywhere in the string. Threads over `List` inputs. | [StringFreeQ](https://reference.wolfram.com/language/ref/StringFreeQ) |
| `StringStartsQ` | `StringStartsQ["string", patt]`, `StringStartsQ[{"s1", ...}, patt]`, and operator form `StringStartsQ[patt]` | Returns `True` when a match for the shipped string-pattern subset begins at the first character. Threads over `List` inputs. | [StringStartsQ](https://reference.wolfram.com/language/ref/StringStartsQ) |
| `StringEndsQ` | `StringEndsQ["string", patt]`, `StringEndsQ[{"s1", ...}, patt]`, and operator form `StringEndsQ[patt]` | Returns `True` when a match for the shipped string-pattern subset ends at the last character. Threads over `List` inputs. | [StringEndsQ](https://reference.wolfram.com/language/ref/StringEndsQ) |
| `StringPosition` | `StringPosition["string", patt]`, `StringPosition["string", {patt1, ...}]`, `StringPosition["string", patt, n]`, `StringPosition[{"s1", ...}, patt]`, and operator form `StringPosition[patt]` | Returns one-based inclusive `{start, end}` spans for matches of the shipped string-pattern subset. Tungsten keeps Wolfram's default overlapping behavior and threads over `List` inputs. | [StringPosition](https://reference.wolfram.com/language/ref/StringPosition) |
| `StringContainsQ` | `StringContainsQ["string", patt]`, `StringContainsQ["string", {patt1, ...}]`, `StringContainsQ[{"s1", ...}, patt]`, and operator form `StringContainsQ[patt]` | Returns `True` when a match for the shipped string-pattern subset exists. Threads over `List` inputs. | [StringContainsQ](https://reference.wolfram.com/language/ref/StringContainsQ) |
| `StringCases` | `StringCases["string", patt]`, `StringCases["string", patt, n]`, `StringCases["string", patt :> rhs]`, `StringCases["string", patt -> rhs]`, `StringCases[{"s1", ...}, spec]`, and list-of-pattern / list-of-rule specs | Collects non-overlapping matches for the shipped string-pattern subset. Delayed rules bind named string captures before evaluating the replacement template. Non-string replacement results are preserved as `StringExpression[...]` pieces when needed. | [StringCases](https://reference.wolfram.com/language/ref/StringCases) |
| `StringReplace` | `StringReplace["string", rules]`, `StringReplace["string", rules, n]`, `StringReplace[{"s1", ...}, rules]`, and flat list-of-rule forms using `->` or `:>` | Rewrites non-overlapping matches for the shipped string-pattern subset from left to right. Delayed rules bind named string captures before evaluating the replacement template, and non-string replacement results are preserved through `StringExpression[...]` when needed. | [StringReplace](https://reference.wolfram.com/language/ref/StringReplace) |
| `RegularExpression` | `RegularExpression["regex"]` inside supported string patterns | Matches a prefix using Python's regular-expression engine. Inline flags such as `(?i)` are honored by Python when accepted by `re`. | [RegularExpression](https://reference.wolfram.com/language/ref/RegularExpression.html) |
| `DatePattern` | `DatePattern[{"Year", ...}]`, `DatePattern[{"Year", ...}, sep]` inside supported string patterns | Recognizes common date/time substrings from documented date element names using Tungsten's practical regex-backed subset. Default separators are `/`, `-`, `:`, and `.`; supported explicit separators can be literal strings or simple string-pattern expressions convertible to regex. | [DatePattern](https://reference.wolfram.com/language/ref/DatePattern.html) |
| `ToCharacterCode` | `ToCharacterCode["string"]`, `ToCharacterCode["string", "encoding"]`, and list-of-strings forms | Converts strings to character codes. Tungsten uses Unicode code points for the default / `"Unicode"` case, byte values for the supported encoded cases, and `None` placeholders for unrepresentable characters in supported single-byte legacy encodings such as ASCII. | [ToCharacterCode](https://reference.wolfram.com/language/ref/ToCharacterCode) |
| `FromCharacterCode` | `FromCharacterCode[n]`, `FromCharacterCode[{n1, ...}]`, and encoded forms `FromCharacterCode[..., "encoding"]` | Converts Unicode code points or encoded byte values back to strings. For encoded forms, Tungsten currently expects integers between `0` and `255`. | [FromCharacterCode](https://reference.wolfram.com/language/ref/FromCharacterCode) |
| `StringToByteArray` | `StringToByteArray["string"]`, `StringToByteArray["string", "encoding"]` | Encodes strings to byte arrays, defaulting to UTF-8. Unsupported characters in a requested legacy encoding currently raise a Tungsten evaluation error instead of returning an inert expression with messages. | [StringToByteArray](https://reference.wolfram.com/language/ref/StringToByteArray) |
| `ByteArrayToString` | `ByteArrayToString[ba]`, `ByteArrayToString[ba, "encoding"]`, plus the empty-list synonym `ByteArrayToString[{}]` | Decodes byte arrays to strings, defaulting to UTF-8. For UTF-style encodings, Tungsten follows Wolfram's practical behavior of preserving invalid raw bytes as literal code points in the resulting string. | [ByteArrayToString](https://reference.wolfram.com/language/ref/ByteArrayToString) |
| `ImportString` | `ImportString["data", "Byte"|"String"|"Text"|"WL"|"JSON"|"RawJSON"|"CSV"|"TSV"|"Table"]` and compressed wrapper forms such as `ImportString["data", {"GZIP", "String"}]` | Imports data from a string for Tungsten's practical direct-format subset. `"JSON"` imports objects as rule lists; `"RawJSON"` imports objects as associations; `"CSV"` / `"TSV"` / `"Table"` import row lists with simple numeric recognition; compression wrappers treat the source string as raw bytes. | [ImportString](https://reference.wolfram.com/language/ref/ImportString.html) |
| `ExportString` | `ExportString[expr, "Byte"|"String"|"Text"|"WL"|"JSON"|"RawJSON"|"CSV"|"TSV"|"Table"]` and compressed wrapper forms such as `ExportString[expr, {"GZIP", "CSV"}]` | Exports expressions through the same practical subset. `"JSON"` accepts rule-list or association objects; `"RawJSON"` expects associations; flat lists export as single-column tabular data; compression wrappers return raw byte strings. | [ExportString](https://reference.wolfram.com/language/ref/ExportString.html) |
| `ImportByteArray` | `ImportByteArray[ba, "Byte"|"String"|"Text"|"WL"|"JSON"|"RawJSON"|"CSV"|"TSV"|"Table"]` and compressed wrapper forms such as `ImportByteArray[ba, {"BZIP2", "RawJSON"}]` | Imports from byte arrays using the same practical format subset. `"String"` maps bytes directly to character codes `0..255`; `"Text"` / `"WL"` / JSON / tabular formats decode UTF-8 first; compression wrappers decompress and then import the inner format. | [ImportByteArray](https://reference.wolfram.com/language/ref/ImportByteArray.html) |
| `ExportByteArray` | `ExportByteArray[expr, "Byte"|"String"|"Text"|"WL"|"JSON"|"RawJSON"|"CSV"|"TSV"|"Table"]` and compressed wrapper forms such as `ExportByteArray[expr, {"GZIP", "CSV"}]` | Exports to byte arrays using the same practical subset. `"Byte"` expects a byte list or `ByteArray`; `"String"` exports raw characters with code points `0..255`; textual formats are UTF-8 encoded; compression wrappers compress the inner byte payload. | [ExportByteArray](https://reference.wolfram.com/language/ref/ExportByteArray.html) |
| `ToString` | `ToString[expr]`, `ToString[expr, InputForm]`, `ToString[expr, StandardForm]` | Converts an evaluated expression to parseable text. `InputForm` and `StandardForm` both use Tungsten's canonical textual renderer rather than byte-for-byte kernel or FrontEnd formatting. The one-argument form is a Tungsten-specific parseable `InputForm` default. | [ToString](https://reference.wolfram.com/language/ref/ToString.html) |
| `ToExpression` | `ToExpression["text"]`, `ToExpression["text", InputForm|StandardForm]`, `ToExpression["text", InputForm|StandardForm, h]`, lists of supported inputs, and supported StandardForm box expressions such as `RowBox[...]`, `BoxData[...]`, and script boxes | Parses text or supported box expressions, then evaluates the result. The three-argument form wraps the parsed expression in `h` before evaluation, so `HoldComplete` can preserve parsed syntax. Lists are handled elementwise. Syntax failures raise a Tungsten evaluation error instead of returning `$Failed`. | [ToExpression](https://reference.wolfram.com/language/ref/ToExpression.html) |
| `ToBoxes` | `ToBoxes[expr]`, `ToBoxes[expr, StandardForm]`, `ToBoxes[expr, InputForm]` | Converts the evaluated expression to Tungsten's supported box subset. `StandardForm` returns structural box expressions such as `RowBox`, `FractionBox`, and `SuperscriptBox`; `InputForm` returns a parseable string box. | [ToBoxes](https://reference.wolfram.com/language/ref/ToBoxes.html) |
| `MakeBoxes` | `MakeBoxes[expr]`, `MakeBoxes[expr, StandardForm]`, `MakeBoxes[expr, InputForm]` | Held low-level box conversion. Unlike `ToBoxes`, Tungsten does not evaluate the first argument before boxing it. | [MakeBoxes](https://reference.wolfram.com/language/ref/MakeBoxes.html) |
| `MakeExpression` | `MakeExpression[boxes]`, `MakeExpression[boxes, StandardForm]`, `MakeExpression["text", InputForm|StandardForm]` | Converts supported text or boxes to held syntax as `HoldComplete[expr]`, mirroring Wolfram's low-level box-to-expression boundary without evaluating the parsed expression. | [MakeExpression](https://reference.wolfram.com/language/ref/MakeExpression.html) |
| `StripBoxes` | `StripBoxes[boxes]` | Removes nonsemantic row-box whitespace and common style/wrapper boxes, returning a `BoxData[...]` expression. Tungsten's stripping is deterministic and stylesheet-independent, so it is a practical subset of the FrontEnd's richer stripping process. | [StripBoxes](https://reference.wolfram.com/language/ref/StripBoxes.html) |
| `SyntaxQ` | `SyntaxQ["text"]`, `SyntaxQ["text", InputForm|StandardForm]`, plus Tungsten-supported box expressions | Returns `True` when the input parses as one complete expression in the selected supported form. Tungsten also accepts supported boxes directly as a convenience extension. | [SyntaxQ](https://reference.wolfram.com/language/ref/SyntaxQ.html) |
| `SyntaxLength` | `SyntaxLength["text"]`, `SyntaxLength["text", InputForm|StandardForm]`, plus Tungsten-supported box expressions | Returns the number of characters in a syntactically complete leading expression, or an approximate parser error/continuation position for incomplete input. Tungsten uses its own parser diagnostics rather than Wolfram's exact byte-for-byte values. | [SyntaxLength](https://reference.wolfram.com/language/ref/SyntaxLength.html) |
| `BaseEncode` | `BaseEncode[ba]`, `BaseEncode[ba, "encoding"]` | Encodes byte arrays as `"Base64"` by default, with additional support for `"Base16"` and `"Base85ASCII"`. | [BaseEncode](https://reference.wolfram.com/language/ref/BaseEncode) |
| `BaseDecode` | `BaseDecode["text"]`, `BaseDecode["text", "encoding"]` | Decodes supported base-encoded strings to byte arrays. Tungsten currently supports `"Base64"` by default, plus `"Base16"` and `"Base85ASCII"`, and it drops nonalphabet characters before decoding in the practical Wolfram style. | [BaseDecode](https://reference.wolfram.com/language/ref/BaseDecode) |
| `PatternTest` | `PatternTest[patt, test]` and shorthand `patt?test` | Pattern object that first matches `patt`, then applies `test` as a callable predicate to the matched expression. For sequence patterns such as `__?IntegerQ`, Tungsten requires every consumed element to satisfy the predicate. | [PatternTest](https://reference.wolfram.com/language/ref/PatternTest.html) |
| `Optional` | `Optional[patt, default]`, shorthand `patt:default`, `Optional[patt]`, and shorthand `_.` / `x_.` | Pattern object for optional arguments. Explicit defaults can fill omitted arguments and named variables bind to the default even when the default would not itself match the present-argument pattern. Without an explicit default, Tungsten treats the pattern as present-only because user-defined and built-in `Default[...]` values are not represented yet. | [Optional](https://reference.wolfram.com/language/ref/Optional.html) |
| `Repeated` | `Repeated[patt]`, `Repeated[patt, max]`, `Repeated[patt, {min, max}]`, `Repeated[patt, {n}]`, and suffix `patt..` | Matches one or more adjacent arguments, or the bounded count requested by the repetition specification. The repeated item may itself be a fixed-width pattern or a sequence pattern such as `PatternSequence[a, b]`. | [Repeated](https://reference.wolfram.com/language/ref/Repeated.html) |
| `RepeatedNull` | `RepeatedNull[patt]`, bounded forms parallel to `Repeated`, and suffix `patt...` | Matches zero or more adjacent arguments, or the bounded count requested by the repetition specification. | [RepeatedNull](https://reference.wolfram.com/language/ref/RepeatedNull.html) |
| `PatternSequence` | `PatternSequence[p1, p2, ...]` | Matches a fixed-order sequence of adjacent arguments. Named wrappers bind the consumed sequence using Tungsten's `Sequence[...]` splicing representation. | [PatternSequence](https://reference.wolfram.com/language/ref/PatternSequence.html) |
| `OrderlessPatternSequence` | `OrderlessPatternSequence[p1, p2, ...]` | Matches a local adjacent argument segment against the supplied sequence patterns in any order while preserving the candidate argument order in named bindings and replacements. This does not make the enclosing head globally `Orderless`. | [OrderlessPatternSequence](https://reference.wolfram.com/language/ref/OrderlessPatternSequence.html) |
| `Longest` | `Longest[patt]` | Requests greedy allocation for the wrapped ambiguous sequence pattern within Tungsten's ordinary argument-list matcher. It is a match-priority wrapper only; Tungsten still does not implement attribute-driven `Flat` or `Orderless` matching. | [Longest](https://reference.wolfram.com/language/ref/Longest.html) |
| `Shortest` | `Shortest[patt]` | Requests non-greedy allocation for the wrapped ambiguous sequence pattern. This is also Tungsten's default for ordinary ambiguous sequence patterns. | [Shortest](https://reference.wolfram.com/language/ref/Shortest.html) |
| `OptionsPattern` | `OptionsPattern[]`, `OptionsPattern[spec]` as a structural pattern object | Matches zero or more option rules, delayed option rules, and nested lists of such rules whose keys are symbols or strings. The optional spec is accepted syntactically but Tungsten does not yet validate against `Options[f]` or support `OptionValue`. | [OptionsPattern](https://reference.wolfram.com/language/ref/OptionsPattern.html) |
| `Condition` | `Condition[patt, test]`, `patt /; test`, and top-level delayed-template guards such as `lhs :> rhs /; test` | Guards a pattern or delayed-rule template. Tungsten treats the guard as satisfied only when the substituted test reduces to explicit `True` under the shipped evaluator. | [Condition](https://reference.wolfram.com/language/ref/Condition) |
| `RuleDelayed` | `lhs :> rhs`, including guarded forms such as `lhs :> rhs /; test` | Delays right-hand-side instantiation until after pattern bindings are known. A top-level delayed-template `Condition` guard can suppress the rule and fall through to later rules when present. | [RuleDelayed](https://reference.wolfram.com/language/ref/RuleDelayed) |
| `Sequence` | `Sequence[e1, ...]` as a direct argument of a call | Splices its arguments into the enclosing call after argument evaluation for ordinary calls, and structurally without payload evaluation for `Hold`, `HoldForm`, `HoldPattern`, and `Function`. Splicing is suppressed for `HoldComplete`, `Unevaluated`, `Rule`, and `RuleDelayed`. | [Sequence](https://reference.wolfram.com/language/ref/Sequence) |
| `Nothing` | `Nothing`, `Nothing[...]` | `Nothing[...]` evaluates to `Nothing`; direct `Nothing` is removed from evaluated `List[...]` outputs and direct association-constructor placeholders, while remaining inert in ordinary calls, held expressions, and association values. | [Nothing](https://reference.wolfram.com/language/ref/Nothing) |
| `MatchQ` | `MatchQ[expr, patt]` | Structurally tests whether `expr` matches Tungsten's supported pattern subset, including `Blank`, anonymous and named `__` / `___` sequence patterns, `Repeated`, `PatternSequence`, `Optional`, `PatternTest`, guarded patterns via `/;`, `Alternatives`, `Except`, `HoldPattern`, `Verbatim`, `OptionsPattern`, and `KeyValuePattern`. Multiple sequence patterns in one ordinary argument list are matched with Tungsten's documented backtracking rule. | [MatchQ](https://reference.wolfram.com/language/ref/MatchQ) |
| `FreeQ` | `FreeQ[expr, patt]`, `FreeQ[expr, patt, levelspec]` | Returns `True` when no searched subexpression matches the supported pattern subset. Tungsten follows Wolfram's default `Heads -> True` behavior for `FreeQ`; associations contribute their head, values, and whole expression, but not keys or raw rules. Advanced structural pattern forms use the same documented sequence allocation and guard rules as `MatchQ`. | [FreeQ](https://reference.wolfram.com/language/ref/FreeQ) |
| `Cases` | `Cases[expr, patt]`, `Cases[expr, patt, levelspec]`, `Cases[expr, patt, levelspec, n]`, `Cases[expr, patt :> rhs]`, `Cases[expr, patt :> rhs, levelspec]` | Collects matching subexpressions in depth-first postorder, with optional template substitution through named-pattern bindings. On associations, Tungsten picks out matching values and nested value subexpressions; `KeyValuePattern` matches whole associations or lists of rules when keys must participate. Named sequence bindings substitute through `Sequence[...]`-style splicing, and delayed templates may use `/;` as a post-substitution guard. | [Cases](https://reference.wolfram.com/language/ref/Cases) |
| `DeleteCases` | `DeleteCases[expr, patt]`, `DeleteCases[expr, patt, levelspec]`, `DeleteCases[expr, patt, levelspec, n]` | Removes matching subexpressions in depth-first postorder, deleting leaves before roots. On associations, matching values are removed from their owning entries and deeper matches are removed inside nested values. Whole-expression deletion at level `0` is not implemented yet. Anonymous and named `__` / `___` patterns and guarded patterns are supported under Tungsten's documented limits. | [DeleteCases](https://reference.wolfram.com/language/ref/DeleteCases) |
| `KeyValuePattern` | `KeyValuePattern[patt]`, `KeyValuePattern[{patt1, ...}]` | Pattern object for matching associations or lists of rules by their entries. Entry patterns are matched in the supplied order, may appear in any association order, and each entry can satisfy at most one pattern. Tungsten distinguishes `Rule` from `RuleDelayed` and supports named captures inside key and value patterns. | [KeyValuePattern](https://reference.wolfram.com/language/ref/KeyValuePattern) |
| `Replace` | `Replace[expr, rules]`, `Replace[expr, rules, levelspec]`, nested rule-list forms such as `Replace[expr, {{rules1...}, {rules2...}}, levelspec]` | Applies the first matching rule per visited part, with Wolfram-style levelspec semantics and bottom-up traversal over the covered subset. Guarded left-hand-side patterns are supported, and delayed right-hand-side guards such as `lhs :> rhs /; test` fire only when the substituted guard reduces to explicit `True`. On associations, Tungsten traverses values rather than keys or raw `Rule` wrappers. | [Replace](https://reference.wolfram.com/language/ref/Replace) |
| `ReplaceAll` | `ReplaceAll[expr, rule]`, `ReplaceAll[expr, {rule1, ...}]`, nested rule-list forms such as `ReplaceAll[expr, {{rules1...}, {rules2...}}]` | Performs a single top-down rewrite pass over the covered subset. Tungsten also supports the parser-lowered operator form `expr /. rules`. Guarded left-hand-side patterns are supported, and delayed right-hand-side guards such as `lhs :> rhs /; test` can suppress a rule and fall through to later rules. On associations, Tungsten rewrites the whole association first, then the head and values, but not keys or raw `Rule` wrappers. | [ReplaceAll](https://reference.wolfram.com/language/ref/ReplaceAll) |
| `ReplaceRepeated` | `ReplaceRepeated[expr, rule]`, `ReplaceRepeated[expr, {rule1, ...}]`, nested rule-list forms such as `ReplaceRepeated[expr, {{rules1...}, {rules2...}}]` | Repeats the covered `ReplaceAll` semantics until a structural fixed point is reached. Tungsten also supports the parser-lowered operator form `expr //. rules`. Non-terminating rewrite loops stop at a Tungsten safety cap and raise an evaluation error. Guarded delayed rules are reapplied until the guard stops succeeding or a structural fixed point is reached. | [ReplaceRepeated](https://reference.wolfram.com/language/ref/ReplaceRepeated) |
| `Function` | `Function[body]`, `body &`, `Function[Null, body]`, `Function[Null, body, attrs]`, positional slot applications such as `Function[body][arg1, ...]`, named forms such as `Function[x, body]`, `Function[{x, y}, body]`, `Function[params, body, attrs]`, `x |-> body`, and `x \[Function] body` | Supports positional pure functions over `Slot` and `SlotSequence` forms plus named-parameter pure functions with lexical scoping and capture-avoiding renaming. Tungsten recognizes `#`, `#n`, `#0`, `##`, `##n`, `Slot[]`, `Slot[n]`, `SlotSequence[]`, `SlotSequence[n]`, Wolfram's `#name` shorthand for first-argument association lookup, third-argument hold / sequence / listable attributes, and nested named-function alpha-renaming when an inner body is modified by outer pure-function application. | [Function](https://reference.wolfram.com/language/ref/Function) |
| `Slot` | `#`, `#n`, `#0`, `Slot[]`, `Slot[n]`, `#name` | Represents a positional pure-function argument. `Slot[]` is treated like `Slot[1]` on application; `#0` refers to the pure function itself; `#name` is Wolfram's first-argument association/key shorthand and parses as `#1["name"]` in Tungsten's AST. | [Slot](https://reference.wolfram.com/language/ref/Slot.html) |
| `SlotSequence` | `##`, `##n`, `SlotSequence[]`, `SlotSequence[n]` | Represents all remaining arguments in a positional pure function, starting at argument `n` (`1` by default), and splices them into the function body before the substituted body is evaluated. | [SlotSequence](https://reference.wolfram.com/language/ref/SlotSequence.html) |
| `Hold` / `HoldComplete` / `HoldForm` / `Unevaluated` | `Hold[expr]`, `HoldComplete[expr]`, `HoldForm[expr]`, `Unevaluated[expr]` | Preserve arguments unevaluated under Tungsten's structural evaluator. `HoldPattern` has the same holding behavior for pattern expressions. | [Hold](https://reference.wolfram.com/language/ref/Hold) |
| `ReleaseHold` | `ReleaseHold[expr]` | Strips one outer `Hold`, `HoldComplete`, `HoldForm`, or `Unevaluated` wrapper and evaluates the released payload. Non-held arguments are returned after ordinary argument evaluation. | [ReleaseHold](https://reference.wolfram.com/language/ref/ReleaseHold) |
| `Identity` | `Identity[expr]` | Returns its argument unchanged. Tungsten also benefits from this when `Identity` is used as a callable argument to higher-order structural functions. | [Identity](https://reference.wolfram.com/language/ref/Identity) |
| `SameQ` | `SameQ[e1, ...]` and infix `===` | Returns `True` when all arguments are structurally identical in Tungsten's AST. | [SameQ](https://reference.wolfram.com/language/ref/SameQ) |
| `UnsameQ` | `UnsameQ[e1, ...]` and infix `=!=` | Returns `True` when all arguments are pairwise structurally distinct in Tungsten's AST. | [UnsameQ](https://reference.wolfram.com/language/ref/UnsameQ) |
| `SameAs` | `SameAs[q]` and callable forms such as `SameAs[q][expr]` | Supports the common operator form that tests structural identity against a fixed expression. | [SameAs](https://reference.wolfram.com/language/ref/SameAs) |
| `Construct` | `Construct[h, a1, ...]` | Constructs and evaluates `h[a1, ...]` under Tungsten's shipped evaluator, so structural built-ins and pure functions can participate. | [Construct](https://reference.wolfram.com/language/ref/Construct) |
| `Composition` | `Composition[f1, ...]`, infix `@*`, and callable forms such as `Composition[f, g][x]` | Builds a callable composition that applies the rightmost function first and then works leftward. | [Composition](https://reference.wolfram.com/language/ref/Composition) |
| `RightComposition` | `RightComposition[f1, ...]`, infix `/*`, and callable forms such as `RightComposition[f, g][x]` | Builds a callable composition that applies the leftmost function first and then works rightward. | [RightComposition](https://reference.wolfram.com/language/ref/RightComposition) |
| `ComposeList` | `ComposeList[{f1, ...}, expr]` | Returns the successive values produced by composing functions left to right over an initial expression. | [ComposeList](https://reference.wolfram.com/language/ref/ComposeList) |
| `Nest` | `Nest[f, expr, n]` | Applies a function repeatedly a fixed number of times. | [Nest](https://reference.wolfram.com/language/ref/Nest) |
| `NestList` | `NestList[f, expr, n]` | Returns the successive values produced by repeated function application. | [NestList](https://reference.wolfram.com/language/ref/NestList) |
| `NestWhile` | `NestWhile[f, expr, test]` | Repeats function application while the current value satisfies the predicate. Tungsten currently supports the direct three-argument form only. | [NestWhile](https://reference.wolfram.com/language/ref/NestWhile) |
| `NestWhileList` | `NestWhileList[f, expr, test]` | Returns the successive values produced while the current value satisfies the predicate, including the first value that fails the test. Tungsten currently supports the direct three-argument form only. | [NestWhileList](https://reference.wolfram.com/language/ref/NestWhileList) |
| `FixedPoint` | `FixedPoint[f, expr]`, `FixedPoint[f, expr, n]` | Repeats function application until a structural fixed point is reached. With an explicit `n`, Tungsten follows Wolfram's soft-limit behavior and returns the value after at most `n` iterations. | [FixedPoint](https://reference.wolfram.com/language/ref/FixedPoint) |
| `FixedPointList` | `FixedPointList[f, expr]`, `FixedPointList[f, expr, n]` | Returns the successive values through the first structural fixed point or through the explicit soft iteration limit. | [FixedPointList](https://reference.wolfram.com/language/ref/FixedPointList) |
| `Operate` | `Operate[p, expr]`, `Operate[p, expr, n]` | Applies a function to the head at the requested nesting depth, leaving arguments unchanged. | [Operate](https://reference.wolfram.com/language/ref/Operate) |
| `Comap` | `Comap[functions, expr]` and callable operator form `Comap[functions]` | Applies one expression to every function in a function collection while preserving the collection's outer structure. | [Comap](https://reference.wolfram.com/language/ref/Comap) |
| `ComapApply` | `ComapApply[functions, expr]` and callable operator form `ComapApply[functions]` | Applies the arguments of a nonatomic expression to every function in a function collection while preserving the collection's outer structure. | [ComapApply](https://reference.wolfram.com/language/ref/ComapApply) |
| `Association` | `Association[rule1, ...]`, `Association[{rule1, ...}]`, `Association[assoc]`, and single-key function-position lookup `assoc[key]` | Normalizes associations structurally, including last-occurrence-wins duplicate-key semantics while preserving the first occurrence position of a duplicate key. Invalid constructor forms remain inert. | [Association](https://reference.wolfram.com/language/ref/Association) |
| `AssociationQ` | `AssociationQ[expr]` | Returns `True` when Tungsten recognizes a structural association value. | [AssociationQ](https://reference.wolfram.com/language/ref/AssociationQ) |
| `Part` | `Part[expr, spec1, ...]` | Extracts parts by exact structural position, including spans, `All`, and selector lists. On associations, Tungsten supports numeric positions, `Key[key]`, and string-key shorthand for string keys. | [Part](https://reference.wolfram.com/language/ref/Part) |
| `Extract` | `Extract[expr, pos]` | Extracts one or more parts using explicit position lists. Association positions support numeric components, `Key[key]`, and string-key shorthand. | [Extract](https://reference.wolfram.com/language/ref/Extract) |
| `Level` | `Level[expr, spec]`, `Level[expr, spec, False]` | Returns subexpressions at requested positive or negative levels in postorder. Negative integer shorthand such as `-1` follows Wolfram's `{1, -1}` meaning. Associations are traversed through values rather than keys. | [Level](https://reference.wolfram.com/language/ref/Level) |
| `First` | `First[expr]`, `First[expr, default]` | Returns the first argument of an expression, with optional default for empty expressions. For associations, this is the first value. | [First](https://reference.wolfram.com/language/ref/First) |
| `Last` | `Last[expr]`, `Last[expr, default]` | Returns the last argument of an expression, with optional default for empty expressions. For associations, this is the last value. | [Last](https://reference.wolfram.com/language/ref/Last) |
| `Rest` | `Rest[expr]` | Returns an expression with its first argument removed. For associations, Tungsten removes the first key-value entry. | [Rest](https://reference.wolfram.com/language/ref/Rest) |
| `Most` | `Most[expr]` | Returns an expression with its last argument removed. For associations, Tungsten removes the last key-value entry. | [Most](https://reference.wolfram.com/language/ref/Most) |
| `Pick` | `Pick[data, selector]`, `Pick[data, selector, patt]` | Picks parts whose corresponding selector parts are explicit `True` or match `patt`. Tungsten preserves the original head for supported compatible selector shapes and preserves association keys when association entries are kept. | [Pick](https://reference.wolfram.com/language/ref/Pick) |
| `Select` | `Select[expr, crit]`, `Select[expr, crit, n]`, `Select[expr, crit -> "Element"]`, `Select[expr, crit -> "Index"]`, list-property forms built from those two properties, and operator form `Select[crit]` | Keeps immediate elements for which the criterion evaluates to explicit `True`. Tungsten preserves the original head for the default `"Element"` property, works on association values while preserving keys, and uses 1-based immediate positions for the `"Index"` property. | [Select](https://reference.wolfram.com/language/ref/Select) |
| `Discard` | `Discard[expr, crit]`, `Discard[expr, crit, n]`, `Discard[expr, crit -> "Element"]`, `Discard[expr, crit -> "Index"]`, list-property forms built from those two properties, and operator form `Discard[crit]` | Removes immediate elements for which the criterion evaluates to explicit `True`. Tungsten preserves the original head for the default `"Element"` property, works on association values while preserving keys, and uses 1-based immediate positions for the `"Index"` property. | [Discard](https://reference.wolfram.com/language/ref/Discard) |
| `SelectFirst` | `SelectFirst[expr, crit]`, `SelectFirst[expr, crit, default]`, `SelectFirst[expr, crit -> "Element"]`, `SelectFirst[expr, crit -> "Index"]`, list-property forms built from those two properties, and operator form `SelectFirst[crit]` | Returns the first immediate element whose criterion evaluates to explicit `True`. For the default `"Element"` property, Tungsten returns `Missing["NotFound"]` when no match exists unless an explicit default is supplied. For the `"Index"` property, Tungsten returns the first 1-based immediate position or `Missing["NotFound"]`. | [SelectFirst](https://reference.wolfram.com/language/ref/SelectFirst) |
| `TakeWhile` | `TakeWhile[expr, crit]` | Keeps the longest immediate prefix for which the criterion evaluates to explicit `True`. Tungsten preserves the original head and works on association values while preserving keys. | [TakeWhile](https://reference.wolfram.com/language/ref/TakeWhile) |
| `UnitStep` | `UnitStep[]`, `UnitStep[i1, ...]` | Returns `1` when no explicit integer argument is negative, otherwise `0`. In this pass, Tungsten supports only explicit integer arguments. | [UnitStep](https://reference.wolfram.com/language/ref/UnitStep) |
| `Unitize` | `Unitize[i]` | Returns `0` for integer `0` and `1` for any other explicit integer. | [Unitize](https://reference.wolfram.com/language/ref/Unitize) |
| `Sign` | `Sign[i]` | Returns `-1`, `0`, or `1` for an explicit integer. | [Sign](https://reference.wolfram.com/language/ref/Sign) |
| `Abs` | `Abs[i]` | Returns the absolute value of an explicit integer. | [Abs](https://reference.wolfram.com/language/ref/Abs) |
| `RealSign` | `RealSign[i]` | Returns `-1`, `0`, or `1` for an explicit integer, using Tungsten's integer-only real subset. | [RealSign](https://reference.wolfram.com/language/ref/RealSign) |
| `RealAbs` | `RealAbs[i]` | Returns the absolute value of an explicit integer, using Tungsten's integer-only real subset. | [RealAbs](https://reference.wolfram.com/language/ref/RealAbs) |
| `Mod` | `Mod[m, n]`, `Mod[m, n, d]` with explicit integers | Returns the Wolfram-style remainder for explicit integer arguments, including the offset form `d`. `Mod[m, 0]` currently yields `Indeterminate`. | [Mod](https://reference.wolfram.com/language/ref/Mod) |
| `Quotient` | `Quotient[m, n]`, `Quotient[m, n, d]` with explicit integers | Returns the Wolfram-style integer quotient corresponding to `Mod`, including the offset form `d`. `Quotient[0, 0]` currently yields `Indeterminate`, while nonzero divided by zero yields `ComplexInfinity`. | [Quotient](https://reference.wolfram.com/language/ref/Quotient) |
| `QuotientRemainder` | `QuotientRemainder[m, n]` with explicit integers and nonzero `n` | Returns `{Quotient[m, n], Mod[m, n]}` for the supported integer subset. Division by zero currently remains inert in Tungsten. | [QuotientRemainder](https://reference.wolfram.com/language/ref/QuotientRemainder) |
| `Min` | `Min[]`, `Min[i1, ...]` | Returns the minimum of explicit integer arguments. `Min[]` yields `Infinity`. | [Min](https://reference.wolfram.com/language/ref/Min) |
| `Max` | `Max[]`, `Max[i1, ...]` | Returns the maximum of explicit integer arguments. `Max[]` yields `-Infinity`. | [Max](https://reference.wolfram.com/language/ref/Max) |
| `Clip` | `Clip[i]`, `Clip[i, {min, max}]`, `Clip[i, {min, max}, {vmin, vmax}]` with explicit integers | Clips an explicit integer into the specified range. Tungsten currently requires explicit integer bounds, and for the three-argument form it returns `vmin` or `vmax` when clipping occurs. | [Clip](https://reference.wolfram.com/language/ref/Clip) |
| `KroneckerDelta` | `KroneckerDelta[]`, `KroneckerDelta[i]`, `KroneckerDelta[i1, ...]` | Returns `1` when all supported explicit integer arguments are equal, otherwise `0`. The one-argument form tests whether the integer is `0`. | [KroneckerDelta](https://reference.wolfram.com/language/ref/KroneckerDelta) |
| `DiscreteDelta` | `DiscreteDelta[]`, `DiscreteDelta[i1, ...]` | Returns `1` when every supported explicit integer argument is `0`, otherwise `0`. | [DiscreteDelta](https://reference.wolfram.com/language/ref/DiscreteDelta) |
| `Ramp` | `Ramp[i]` | Returns `0` for negative explicit integers and the argument itself for nonnegative explicit integers. | [Ramp](https://reference.wolfram.com/language/ref/Ramp) |
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
| `Scan` | `Scan[f, expr]`, `Scan[f, expr, levelspec]`, operator form `Scan[f]` | Applies a function for structural side effects and returns `Null`. Tungsten does not model side effects, but it still applies supported callables structurally over the visited levels. | [Scan](https://reference.wolfram.com/language/ref/Scan) |
| `Apply` | `Apply[f, expr]` | Replaces the head of a nonatomic expression with another expression. For associations, Tungsten applies over values, producing `f[value1, ...]`. | [Apply](https://reference.wolfram.com/language/ref/Apply) |
| `MapApply` | `MapApply[f, expr]`, infix `@@@`, and operator form `MapApply[f]` | Replaces the heads of immediate nonatomic elements with `f` while preserving the outer head. | [MapApply](https://reference.wolfram.com/language/ref/MapApply) |
| `Map` | `Map[f, expr]` | Applies a function structurally to each immediate argument. For associations, Tungsten maps over values and keeps keys unchanged. | [Map](https://reference.wolfram.com/language/ref/Map) |
| `MapAll` | `MapAll[f, expr]`, operator form `MapAll[f]` | Applies a function at every visited node, including leaves and rebuilt compound expressions. Associations are traversed through values. | [MapAll](https://reference.wolfram.com/language/ref/MapAll) |
| `MapIndexed` | `MapIndexed[f, expr]`, `MapIndexed[f, expr, 1]`, operator form `MapIndexed[f]` | Maps at the first level and supplies each immediate position as a one-based index list. Associations supply key-aware positions such as `{Key[k]}` while preserving the original keys. | [MapIndexed](https://reference.wolfram.com/language/ref/MapIndexed) |
| `MapAt` | `MapAt[f, expr, pos]` | Applies a function structurally at one or more exact positions. Association positions target values using the same key-aware position syntax as `Part`. | [MapAt](https://reference.wolfram.com/language/ref/MapAt) |
| `Through` | `Through[expr]` | Threads the arguments of a call through a nonatomic head expression. Associations are supported as function collections in the head position. | [Through](https://reference.wolfram.com/language/ref/Through) |
| `MapThread` | `MapThread[f, {{...}, ...}]`, `MapThread[f, {{...}, ...}, 1]` | Threads parallel `List` expressions by position and applies a function to each tuple. | [MapThread](https://reference.wolfram.com/language/ref/MapThread) |
| `Thread` | `Thread[expr]`, `Thread[expr, head]` | Threads immediate arguments that share a common head into a new outer expression with that head. | [Thread](https://reference.wolfram.com/language/ref/Thread) |
| `Distribute` | `Distribute[expr]`, `Distribute[expr, g]`, `Distribute[expr, g, f]` | Distributes a nonatomic outer expression over immediate arguments with the chosen distributed head. Tungsten currently implements the common one-dimensional direct forms only. | [Distribute](https://reference.wolfram.com/language/ref/Distribute) |
| `Outer` | `Outer[f, seq1, ...]` | Forms the outer combination of several nonatomic expressions while preserving each sequence's head nesting. | [Outer](https://reference.wolfram.com/language/ref/Outer) |
| `Inner` | `Inner[f, left, right, g]` | Combines corresponding first-level elements with `f` and then combines the results with `g`. Tungsten currently supports only equal-length first-level compounds. | [Inner](https://reference.wolfram.com/language/ref/Inner) |
| `Dot` | `Dot[a, b, ...]` and infix `.` | Supports `List` vector-vector, matrix-vector, vector-matrix, and matrix-matrix products, then re-evaluates the generated arithmetic so all-integer products simplify. | [Dot](https://reference.wolfram.com/language/ref/Dot) |
| `Tuples` | `Tuples[{{...}, ...}]`, `Tuples[items, n]` | Returns Cartesian products either from an explicit list of sequences or by repeating one base sequence. | [Tuples](https://reference.wolfram.com/language/ref/Tuples) |
| `Array` | `Array[f, dims]` | Builds nested `List` arrays by calling `f` on one-based integer index tuples. | [Array](https://reference.wolfram.com/language/ref/Array) |
| `ConstantArray` | `ConstantArray[value, dims]` | Builds nested `List` arrays filled with a constant value. | [ConstantArray](https://reference.wolfram.com/language/ref/ConstantArray) |
| `Range` | `Range[n]`, `Range[min, max]`, `Range[min, max, step]` with explicit integers | Builds explicit integer ranges using Wolfram's inclusive end behavior. | [Range](https://reference.wolfram.com/language/ref/Range) |
| `UnitVector` | `UnitVector[n, k]` with explicit integers | Builds a one-dimensional integer unit vector with a single `1` at the requested one-based position. | [UnitVector](https://reference.wolfram.com/language/ref/UnitVector) |
| `IdentityMatrix` | `IdentityMatrix[n]` with explicit integer `n` | Builds a square integer identity matrix as nested `List` expressions. | [IdentityMatrix](https://reference.wolfram.com/language/ref/IdentityMatrix) |
| `DiagonalMatrix` | `DiagonalMatrix[list]` | Builds a square matrix with the supplied diagonal values and explicit integer zeros elsewhere. | [DiagonalMatrix](https://reference.wolfram.com/language/ref/DiagonalMatrix) |
| `Partition` | `Partition[expr, n]`, `Partition[expr, n, d]` | Splits a first-level sequence into overlapping or non-overlapping blocks while preserving the original head inside each block. | [Partition](https://reference.wolfram.com/language/ref/Partition) |
| `BlockMap` | `BlockMap[f, expr, n]`, `BlockMap[f, expr, n, d]` | Applies a function to first-level blocks of a sequence and returns the resulting blocks in a `List`. | [BlockMap](https://reference.wolfram.com/language/ref/BlockMap) |
| `TakeList` | `TakeList[expr, specs]` | Repeatedly takes prefixes from a sequence according to a list of specifications and returns the collected pieces. | [TakeList](https://reference.wolfram.com/language/ref/TakeList) |
| `TakeDrop` | `TakeDrop[expr, spec]` | Returns `{Take[expr, spec], Drop[expr, spec]}`. | [TakeDrop](https://reference.wolfram.com/language/ref/TakeDrop) |
| `Fold` | `Fold[f, init, expr]` | Left-folds a function over the immediate elements of a sequence. | [Fold](https://reference.wolfram.com/language/ref/Fold) |
| `FoldList` | `FoldList[f, init, expr]` | Returns the successive states produced by a left fold. | [FoldList](https://reference.wolfram.com/language/ref/FoldList) |
| `FoldWhile` | `FoldWhile[f, init, expr, test]`, plus optional history and trailing-count arguments | Left-folds until the predicate fails on the requested result history, returning the last retained result. | [FoldWhile](https://reference.wolfram.com/language/ref/FoldWhile) |
| `FoldWhileList` | `FoldWhileList[f, init, expr, test]`, plus optional history and trailing-count arguments | Returns the retained result history for `FoldWhile`, including the first failing result when the default trailing count is used. | [FoldWhileList](https://reference.wolfram.com/language/ref/FoldWhileList) |
| `FoldPair` | `FoldPair[f, init, expr]`, `FoldPair[f, init, expr, proj]` | Expects each fold step to return a two-element list `{x, y}` and returns the last projected value. Tungsten's default projection is the first element. | [FoldPair](https://reference.wolfram.com/language/ref/FoldPair) |
| `FoldPairList` | `FoldPairList[f, init, expr]`, `FoldPairList[f, init, expr, proj]` | Expects each fold step to return a two-element list `{x, y}` and returns the successive projected values. Tungsten's default projection is the first element. | [FoldPairList](https://reference.wolfram.com/language/ref/FoldPairList) |
| `SequenceFold` | `SequenceFold[f, initValues, expr]`, `SequenceFold[f, initValues, expr, arity]` | Generalizes left folding to a rolling state of several recent values. | [SequenceFold](https://reference.wolfram.com/language/ref/SequenceFold) |
| `SequenceFoldList` | `SequenceFoldList[f, initValues, expr]`, `SequenceFoldList[f, initValues, expr, arity]` | Returns the successive states for `SequenceFold`, beginning with the initial values themselves. | [SequenceFoldList](https://reference.wolfram.com/language/ref/SequenceFoldList) |
| `LengthWhile` | `LengthWhile[expr, crit]` | Counts the longest immediate prefix whose elements satisfy the predicate. | [LengthWhile](https://reference.wolfram.com/language/ref/LengthWhile) |
| `FirstCase` | `FirstCase[expr, patt]`, `FirstCase[expr, patt, default]`, `FirstCase[expr, patt, default, levelspec]` | Returns the first matching case under Tungsten's `Cases` traversal rules, or `Missing["NotFound"]` / the supplied default when there is no match. | [FirstCase](https://reference.wolfram.com/language/ref/FirstCase) |
| `Position` | `Position[expr, patt]`, `Position[expr, patt, levelspec]`, `Position[expr, patt, levelspec, n]` | Returns exact structural positions of matching subexpressions. The default levelspec is `{0, Infinity}` with heads included, matching Wolfram. Associations search values only, include the association head at `{0}`, and report value paths with components such as `Key[k]`. | [Position](https://reference.wolfram.com/language/ref/Position) |
| `MemberQ` | `MemberQ[expr, patt]`, `MemberQ[expr, patt, levelspec]` | Returns `True` when `Position` would find at least one matching structural position. | [MemberQ](https://reference.wolfram.com/language/ref/MemberQ) |
| `DeleteDuplicates` | `DeleteDuplicates[expr]`, `DeleteDuplicates[expr, test]` | Removes later duplicates while preserving the first occurrence of each retained element. Associations deduplicate by values while preserving the first surviving key for each retained value. | [DeleteDuplicates](https://reference.wolfram.com/language/ref/DeleteDuplicates) |
| `DeleteDuplicatesBy` | `DeleteDuplicatesBy[expr, f]` | Removes later elements whose computed keys are structurally identical after Tungsten evaluates the supported key function. | [DeleteDuplicatesBy](https://reference.wolfram.com/language/ref/DeleteDuplicatesBy) |
| `DuplicateFreeQ` | `DuplicateFreeQ[expr]`, `DuplicateFreeQ[expr, test]` | Returns `True` when no two retained first-level elements are duplicates under structural equality or the supplied binary test. | [DuplicateFreeQ](https://reference.wolfram.com/language/ref/DuplicateFreeQ) |
| `Keys` | `Keys[assoc]` | Returns the keys of an association as a list. | [Keys](https://reference.wolfram.com/language/ref/Keys) |
| `Values` | `Values[assoc]` | Returns the values of an association as a list. | [Values](https://reference.wolfram.com/language/ref/Values) |
| `Normal` | `Normal[assoc]` | Converts an association to a plain list of rules. | [Normal](https://reference.wolfram.com/language/ref/Normal) |
| `Lookup` | `Lookup[assoc, key]`, `Lookup[assoc, key, default]`, `Lookup[assoc, {key1, ...}]`, `Lookup[assoc, {key1, ...}, default]` | Looks up one or more keys, returning `Missing["KeyAbsent", key]` when no default is provided. | [Lookup](https://reference.wolfram.com/language/ref/Lookup) |
| `KeyExistsQ` | `KeyExistsQ[assoc, key]` | Tests whether an association contains a key. | [KeyExistsQ](https://reference.wolfram.com/language/ref/KeyExistsQ) |
| `KeyMemberQ` | `KeyMemberQ[assoc, key]` | Synonym-style key-membership test supported for associations. | [KeyMemberQ](https://reference.wolfram.com/language/ref/KeyMemberQ) |
| `KeyTake` | `KeyTake[assoc, key]`, `KeyTake[assoc, {key1, ...}]` | Selects key-value pairs by explicit key list, preserving requested-key order. | [KeyTake](https://reference.wolfram.com/language/ref/KeyTake) |
| `KeyDrop` | `KeyDrop[assoc, key]`, `KeyDrop[assoc, {key1, ...}]` | Removes key-value pairs by explicit key list while preserving the order of the remaining entries. | [KeyDrop](https://reference.wolfram.com/language/ref/KeyDrop) |
| `KeySelect` | `KeySelect[assoc, crit]`, operator form `KeySelect[crit]` | Selects entries whose keys make the supplied predicate evaluate to explicit `True`, preserving association order. Tungsten currently supports real `Association[...]` inputs, not arbitrary rule lists. | [KeySelect](https://reference.wolfram.com/language/ref/KeySelect) |
| `KeyMap` | `KeyMap[f, assoc]` | Applies a function to association keys while keeping values unchanged and re-normalizing duplicate mapped keys. | [KeyMap](https://reference.wolfram.com/language/ref/KeyMap) |
| `KeyValueMap` | `KeyValueMap[f, assoc]` | Returns a list of `f[key, value]` results in association order. | [KeyValueMap](https://reference.wolfram.com/language/ref/KeyValueMap) |
| `AssociationThread` | `AssociationThread[{k1, ...}, {v1, ...}]` | Builds an association from parallel key and value lists of equal length. | [AssociationThread](https://reference.wolfram.com/language/ref/AssociationThread) |
| `AssociationMap` | `AssociationMap[f, {k1, ...}]` | Builds an association that maps each listed key to `f[key]`. | [AssociationMap](https://reference.wolfram.com/language/ref/AssociationMap) |

## Notes on position semantics

- `Part`, `Extract`, `Delete`, `ReplacePart`, `MapAt`, and related exact-position functions are
  exact and structural. `Position` and `MemberQ` use the documented Tungsten pattern subset.
- `Position` defaults to `{0, Infinity}` with heads included; `Cases` and `DeleteCases` default to
  `{1}` without heads.
- The same position syntax family is shared across `Part`, `Extract`, `Delete`, `ReplacePart`, and
  `MapAt`, but not every Wolfram-language variant is implemented.
- `Part` and `Extract` support selector-style components such as `All`, spans, selector lists,
  `Key[key]`, and string-key shorthand inside associations. `Position` returns association value
  paths in the `Key[key]` form so they can be reused by `Extract`, `ReplacePart`, and `MapAt`.
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
- Association traversal in pattern search is values-only. Keys and raw `Rule` wrappers are inert
  unless a pattern explicitly matches the whole association or uses `KeyValuePattern`.
- `KeyValuePattern` matches associations and lists whose elements are rules. Its entry patterns can
  be ordinary rule patterns such as `k_ -> v_`, delayed-rule patterns, blanks, alternatives, or
  guarded patterns; each association entry is matched at most once.
- `BlankSequence` / `BlankNullSequence` patterns match a single candidate expression directly,
  and they also support multi-element matching in direct argument lists, including named forms such
  as `x__` and multiple occurrences in the same list. For the exact allocation rule, read
  [sequence-pattern-matching.md](./sequence-pattern-matching.md).
- Advanced structural forms such as `PatternTest`, `Optional`, `Repeated`, `RepeatedNull`,
  `PatternSequence`, `OrderlessPatternSequence`, `Longest`, `Shortest`, and `OptionsPattern` use
  the same matcher core. Remaining non-string limits are now about missing global evaluator state
  or attributes, not unsupported pattern heads: no `Flat`, `Orderless`, or `OneIdentity`
  matching; no user-defined `Default[...]` registry; and no `OptionValue`.

## Notes on pure functions

- `#` is parsed as `Slot[1]`.
- `Slot[]` remains distinct in the AST, but Tungsten treats it the same as `Slot[1]` when a pure
  function is actually applied.
- `#0` and `Slot[0]` refer to the pure function itself.
- `#name` is Wolfram syntax for first-argument association/key lookup. Tungsten lowers it to
  `#1["name"]`; it is not named-argument support.
- `##` and `##n` parse to `SlotSequence[1]` and `SlotSequence[n]`. On application, the selected
  argument sequence is spliced structurally into the body before evaluating the substituted result.
- `Function[body]`, `Function[Null, body]`, `Function[params, body]`, and their third-argument
  attribute forms keep `body` inert until application so pure functions can safely contain patterns
  and other expressions that would otherwise evaluate too early.
- Named pure functions accept a single-symbol parameter specification or a list of symbols.
- Tungsten alpha-renames named parameters in nested pure functions when an outer pure-function
  application modifies the inner body. For the exact rule and examples, read
  [named-pure-functions-spec.md](./named-pure-functions-spec.md).
- The implemented `Function` attribute subset affects pure-function applications only:
  `HoldFirst`, `HoldRest`, `HoldAll`, and `HoldAllComplete` control which actual arguments are
  evaluated before substitution; `SequenceHold` and `HoldAllComplete` suppress direct
  `Sequence[...]` argument splicing; `Listable` threads the pure function over same-length list
  arguments, reusing scalar arguments.

## Notes on Hold, Sequence, and Nothing

- `Hold`, `HoldComplete`, `HoldForm`, `HoldPattern`, and `Unevaluated` keep their arguments
  unevaluated. This is a hardcoded structural subset of Wolfram's attribute behavior, not a general
  attribute system.
- `ReleaseHold` strips one outer Hold-family wrapper and evaluates the released payload.
- `Sequence[...]` is spliced after its own arguments evaluate and before ordinary head dispatch for
  ordinary calls. `Hold`, `HoldForm`, `HoldPattern`, and `Function` still splice direct
  `Sequence[...]` arguments, but do so structurally without evaluating the payload. `HoldComplete`,
  `Unevaluated`, `Rule`, and `RuleDelayed` suppress splicing.
- `Nothing` is removed only when Tungsten is constructing or rebuilding an evaluated list, or when
  `Association[...]` receives direct `Nothing` placeholders. Held lists keep direct `Nothing`;
  ordinary calls such as `f[Nothing, x]` keep it as a normal argument; association values such as
  `<|a -> Nothing|>` remain present.
- The precise ordering and examples are specified in
  [sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md).

## Notes on arithmetic and Boolean semantics

- Tungsten parses infix arithmetic, relational, and Boolean operators into ordinary head-based AST
  calls such as `Plus[...]`, `Less[...]`, `And[...]`, and `Not[...]`.
- Tungsten parses same-head chained comparisons such as `1 < 2 < 3` as n-ary relation calls so the
  integer relation evaluator can match Wolfram's ordinary chain behavior.
- In this pass, Tungsten does not flatten or reorder `Plus`, `Times`, `And`, or `Or` during
  parsing or evaluation, and it does not implement `Orderless` canonicalization for any head.
- That means nested operator forms can partially simplify one binary layer at a time. For example,
  `1 + 2 + a` becomes `Plus[3, a]`, while `Plus[1, 2, a]` stays inert.
- Boolean operator forms behave the same way: `True && False && x` becomes `And[False, x]`, while
  `And[True, False, x]` stays inert in this pass.
- Simple predicate heads follow the same explicit-value rule: `IntegerQ[2]`, `EvenQ[4]`,
  `DigitQ["123"]`, and `LetterQ["abc"]` evaluate, while broader numeric or symbolic semantics
  remain out of scope.

## Listable Heads Not Implemented

Wolfram marks many common numeric and logical functions as `Listable`; Tungsten intentionally does
not. These heads therefore stay inert on list arguments unless the support table says otherwise:
`Plus`, `Times`, `Power`, `Equal`, `Unequal`, `Less`, `LessEqual`, `Greater`, `GreaterEqual`,
`UnitStep`, `Unitize`, `Sign`, `Abs`, `RealSign`, `RealAbs`, `Mod`, `Quotient`, `Min`, `Max`,
`Clip`, `KroneckerDelta`, `DiscreteDelta`, and `Ramp`.

This does not apply to `Function[..., Listable]`: Tungsten honors `Listable` when it is explicitly
supplied as a third-argument pure-function attribute.

## Notes on atoms and empty expressions

- `Apply[f, atom]` and `Map[f, atom]` leave atoms unchanged.
- `First` and `Last` honor the optional default argument on empty expressions.
- Many sequence-oriented transforms such as `Append`, `Prepend`, `Join`, `Reverse`,
  `RotateLeft`, `RotateRight`, and `Flatten` expect a nonatomic expression.
- Empty nonatomic expressions such as `f[]` are handled structurally where that behavior is
  straightforward and deterministic.
- Empty associations such as `<||>` are also handled structurally where the result is
  deterministic, for example `Depth[<||>] -> 2` and `Part[<||>, All] -> <||>`.
