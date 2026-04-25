# Tungsten Sequence Pattern Matching

- Status: Normative specification for Tungsten's kernel-free pattern matcher
- Audience: Tungsten maintainers and users who rely on `__` / `___` matching without a live kernel
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-25T02:03:31Z
- Repository HEAD: 79721cbfd92090c751acae5413701d61342eb98b
- Related Wolfram docs:
  - [BlankSequence](https://reference.wolfram.com/language/ref/BlankSequence.html)
  - [BlankNullSequence](https://reference.wolfram.com/language/ref/BlankNullSequence.html)
  - [Repeated](https://reference.wolfram.com/language/ref/Repeated.html)
  - [RepeatedNull](https://reference.wolfram.com/language/ref/RepeatedNull.html)
  - [Pattern](https://reference.wolfram.com/language/ref/Pattern.html)
  - [PatternTest](https://reference.wolfram.com/language/ref/PatternTest.html)
  - [Optional](https://reference.wolfram.com/language/ref/Optional.html)
  - [PatternSequence](https://reference.wolfram.com/language/ref/PatternSequence.html)
  - [OrderlessPatternSequence](https://reference.wolfram.com/language/ref/OrderlessPatternSequence.html)
  - [OptionsPattern](https://reference.wolfram.com/language/ref/OptionsPattern.html)
  - [Longest](https://reference.wolfram.com/language/ref/Longest.html)
  - [Shortest](https://reference.wolfram.com/language/ref/Shortest.html)
  - [Patterns tutorial](https://reference.wolfram.com/language/tutorial/Patterns.html)

## Purpose

Tungsten supports structural Wolfram pattern matching without a running kernel. This document
specifies the variable-length argument-list subset implemented for `BlankSequence` (`__`),
`BlankNullSequence` (`___`), `Repeated`, `RepeatedNull`, `PatternSequence`,
`OrderlessPatternSequence`, `Optional`, `OptionsPattern`, and match-priority wrappers such as
`Longest` and `Shortest`. It covers named forms such as `x__`, `x___`, `x:__`, named
`PatternSequence` captures, and repeated occurrences of sequence patterns inside the same argument
list.

The goal is Wolfram-compatible behavior for ordinary non-`Flat`, non-`Orderless` expression heads.
Tungsten still does not implement general attributes, global `Flat` matching, global `Orderless`
matching, `OneIdentity`, user-defined `Default[...]` values, or `OptionValue`.

## Source Semantics

The Wolfram documentation defines:

- `__` / `BlankSequence[]` as one or more expressions;
- `___` / `BlankNullSequence[]` as zero or more expressions;
- head-qualified forms such as `__Integer` and `___Symbol` as sequences whose members all have the
  requested head;
- named forms such as `x__` as ordinary `Pattern[x, BlankSequence[]]` shorthand;
- named sequence replacements as spliced argument-list replacements, commonly represented
  internally through `Sequence[...]`;
- shortest-first matching for the first multiple blank when several matches are possible.
- `Repeated[p]` / `p..` as one or more adjacent expressions matching `p`, with bounded variants;
- `RepeatedNull[p]` / `p...` as zero or more adjacent expressions matching `p`, with bounded
  variants;
- `PatternSequence[p1, p2, ...]` as an adjacent sequence matching `p1`, `p2`, and so on;
- `OrderlessPatternSequence[p1, p2, ...]` as an adjacent sequence matching the supplied patterns
  in any order;
- `OptionsPattern[]` as a pattern for a sequence or nested list of option rules;
- `Longest[p]` and `Shortest[p]` as match-priority wrappers for ambiguous sequence choices.

Live Wolfram 14.3 probes confirmed the covered non-`Flat` behavior:

| Pattern | Candidate | First match |
|---|---|---|
| `f[x__, y__]` | `f[a, b, c]` | `x -> {a}`, `y -> {b, c}` |
| `f[x__, y__, z__]` | `f[a, b, c, d]` | `x -> {a}`, `y -> {b}`, `z -> {c, d}` |
| `f[x___, y__]` | `f[a, b, c]` | `x -> {}`, `y -> {a, b, c}` |
| `f[x__, y___]` | `f[a, b, c]` | `x -> {a}`, `y -> {b, c}` |
| `f[x__, x__]` | `f[a, b, a, b]` | `x -> {a, b}` |
| `f[x__, x__]` | `f[a, b, c]` | no match |
| `f[x___, x___]` | `f[]` | `x -> {}` |
| `f[x___, x___]` | `f[a]` | no match |
| `f[x___, x___]` | `f[a, a]` | `x -> {a}` |
| `f[Repeated[_Integer, {2, 3}]]` | `f[1, 2, 3]` | full match |
| `f[PatternSequence[_Integer, _Integer]]` | `f[1, 2]` | full match |
| `f[OrderlessPatternSequence[1, 2]]` | `f[2, 1]` | full match |
| `f[Longest[x__], y__]` | `f[a, b, c, d]` | `x -> {a, b, c}`, `y -> {d}` |
| `f[x_:7, y_]` | `f[a]` | `x -> 7`, `y -> a` |
| `f[OptionsPattern[]]` | `f[a -> 1]` | full match |

The table uses list notation for readability. In replacement templates, a sequence binding with
zero or more than one member behaves as a `Sequence[...]` object and is spliced when inserted into
another evaluated expression.

## Surface Syntax

Tungsten accepts these pattern forms:

- anonymous forms: `__`, `___`, `__Head`, `___Head`;
- named postfix forms: `x__`, `x___`, `x__Head`, `x___Head`;
- explicit named forms: `Pattern[x, BlankSequence[]]`, `Pattern[x, BlankNullSequence[Head]]`;
- colon forms that lower to `Pattern`, such as `x : __` and `x : ___Head`;
- pattern tests such as `_?IntegerQ`, `x_?IntegerQ`, and `x__?IntegerQ`;
- optional argument forms such as `x_:7`, `_Integer:7`, and the global-default placeholder
  spelling `x_.`;
- repetition forms such as `patt..`, `patt...`, `Repeated[patt, {2, 3}]`, and
  `RepeatedNull[patt, 2]`;
- `PatternSequence[p1, p2, ...]` and `OrderlessPatternSequence[p1, p2, ...]`;
- `Longest[patt]` and `Shortest[patt]`;
- `OptionsPattern[]` and `OptionsPattern[spec]`;
- `Condition` around a sequence pattern, such as `x__ /; Length[{x}] > 1`;
- `HoldPattern` around a sequence pattern.

The parser lowers all shorthand to ordinary Tungsten AST nodes. For example:

- `x__Integer` becomes `Pattern[x, BlankSequence[Integer]]`;
- `x___` becomes `Pattern[x, BlankNullSequence[]]`;
- `x : __` becomes `Pattern[x, BlankSequence[]]`.

## Argument-List Matching

For a call expression `h[e1, ..., en]` matched against `h[p1, ..., pm]`, Tungsten first matches the
head structurally, then matches the argument list with backtracking.

Each pattern argument has a width:

- fixed-width patterns consume exactly one argument;
- `BlankSequence[...]` consumes at least one argument;
- `BlankNullSequence[...]` consumes zero or more arguments;
- `Repeated[patt]` and `RepeatedNull[patt]` consume a bounded or unbounded repeated multiple of
  the wrapped pattern's width;
- `PatternSequence[p1, ...]` and `OrderlessPatternSequence[p1, ...]` consume the sum of their
  element widths;
- `OptionsPattern[...]` consumes zero or more option-rule arguments;
- `Optional[patt, default]` consumes zero arguments or the width of `patt`;
- `Pattern`, `Condition`, `PatternTest`, `HoldPattern`, `Longest`, and `Shortest` wrappers inherit
  the width of the wrapped sequence pattern.

Tungsten computes the minimum remaining width of the suffix patterns before choosing a length for a
sequence pattern. This avoids trying impossible allocations.

When an ambiguous sequence pattern is encountered, Tungsten tries candidate segment lengths in
ascending order unless the pattern is wrapped in `Longest` or is an explicit-default `Optional`,
which try longer present-argument matches before falling back to shorter or omitted matches:

1. start at the sequence pattern minimum length (`1` for `__`, `0` for `___`);
2. stop at the largest length that leaves enough arguments for the remaining patterns;
3. for each length, test the candidate segment against the sequence pattern;
4. recurse into the remaining argument and pattern suffix;
5. return the first complete match.

This is the key multi-occurrence rule: earlier ordinary sequence patterns get the shortest segment
that can lead to a full match. Later failures can force an earlier sequence pattern to grow.
`Longest` reverses the candidate-length order for the wrapped ambiguous sequence but still respects
suffix constraints, so it is greedy rather than globally omniscient.

Example:

```wl
f[a, b, c, d] /. f[x__, y__, z__] :> HoldComplete[{x}, {y}, {z}]
```

The first accepted allocation is:

```wl
HoldComplete[{a}, {b}, {c, d}]
```

## Segment Validation

A direct sequence pattern validates a candidate segment as follows:

- `BlankSequence[]` accepts any non-empty segment;
- `BlankNullSequence[]` accepts any segment, including empty;
- `BlankSequence[h]` accepts a non-empty segment whose every element has head `h`;
- `BlankNullSequence[h]` accepts an empty segment or a segment whose every element has head `h`.
- `Repeated[patt, spec]` and `RepeatedNull[patt, spec]` split the segment into repetitions of
  `patt` according to the requested count bounds. The repeated item may itself be a sequence
  pattern, for example `Repeated[PatternSequence[a, b]]`.
- `PatternSequence[p1, ...]` delegates back to the ordinary argument-list matcher on the consumed
  segment.
- `OrderlessPatternSequence[p1, ...]` tries permutations of its element patterns against the
  consumed segment. Named bindings still preserve the candidate expression order, not the
  successful pattern permutation.
- `OptionsPattern[...]` accepts an empty segment, option rules (`Rule` or `RuleDelayed`) whose keys
  are symbols or strings, and nested lists of such rules. Tungsten accepts the optional spec
  argument but does not validate option names or implement `OptionValue`.

Head checks reuse Tungsten's existing `Blank[h]` matcher for each member.

## Named Sequence Bindings

`Pattern[name, seqPattern]` first matches the candidate segment against `seqPattern`, then binds
`name` to the segment's replacement value:

- empty segment: `Sequence[]`;
- one element: that element;
- two or more elements: `Sequence[e1, e2, ...]`.

This mirrors Wolfram's practical replacement behavior:

```wl
Cases[{f[a, b]}, f[x__] :> x]
```

returns `{a, b}` because the replacement value for `x` is spliced into the surrounding result
list.

Repeated occurrences of the same pattern name must bind to structurally identical replacement
values. This is the same rule Tungsten already uses for ordinary named blanks, generalized to
sequence values.

Examples:

- `f[a, b, a, b]` matches `f[x__, x__]` with `x -> Sequence[a, b]`;
- `f[a, a]` matches `f[x__, x__]` with `x -> a`;
- `f[a, b, c]` does not match `f[x__, x__]`;
- `f[a]` does not match `f[x___, x___]`, because no split gives equal sequence values.

## Conditions

Sequence patterns wrapped in `Condition` match the segment first, then evaluate the condition after
substituting any new bindings. This lets conditions inspect the full sequence by putting the name in
an evaluated list:

```wl
f[a, b] /. f[x__ /; Length[{x}] == 2] :> HoldComplete[x]
```

The condition sees `{x}` as `{a, b}` because `x` substitutes to `Sequence[a, b]` and `List`
splices direct `Sequence[...]` arguments.

## Pattern Tests

`PatternTest[patt, test]` first matches `patt`, then applies `test` as a Tungsten callable
predicate. The match is retained only when the predicate evaluates to explicit `True`.

For fixed-width patterns, the predicate receives the matched expression:

```wl
MatchQ[1, _?IntegerQ]
```

For sequence patterns, Tungsten follows the practical Wolfram behavior of requiring every consumed
element to satisfy the predicate:

```wl
Cases[{f[1, 2], f[1, a]}, f[__?IntegerQ]]
```

returns only `f[1, 2]`.

## Optional Arguments

`Optional[patt, default]` can match either a present argument matching `patt` or an omitted
argument. If the argument is omitted, named variables inside `patt` bind to `default`. This mirrors
the Wolfram rule that the default value does not itself need to satisfy the pattern constraints:

```wl
Cases[{f[]}, f[x_Integer:foo] :> x]
```

returns `{foo}`.

`Optional[patt]` and the shorthand `_.` rely on `Default[...]` values in the full Wolfram kernel.
Tungsten does not yet have a default-value registry, so these forms match present arguments but do
not synthesize omitted arguments for arbitrary heads. This keeps the offline matcher deterministic
until the symbol/value registry grows real default-value storage.

## Options Patterns

`OptionsPattern[]` structurally matches zero or more option expressions:

- `Rule` or `RuleDelayed` with a symbol or string key;
- lists whose elements are themselves option expressions;
- nested empty lists.

The optional `OptionsPattern[spec]` argument is accepted as syntax, but Tungsten does not currently
consult `Options[f]`, filter invalid option names, or evaluate `OptionValue`.

## Non-Goals

Tungsten still does not implement:

- matching under `Flat`, `Orderless`, or `OneIdentity` attributes;
- user-defined `Default[...]` values for omitted `Optional[patt]` / `_.` arguments;
- `OptionValue` and validation of option names against `Options[f]`;
- global `Orderless` matching for the enclosing head. `OrderlessPatternSequence` is only a local
  sequence-pattern form;
- string-pattern sequence matching beyond the already documented string-pattern subset.

These limits keep the offline evaluator deterministic and structural while covering ordinary
variable-length function-argument patterns.
