# Tungsten Sequence Pattern Matching

- Status: Normative specification for Tungsten's kernel-free pattern matcher
- Audience: Tungsten maintainers and users who rely on `__` / `___` matching without a live kernel
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-25T02:03:31Z
- Repository HEAD: 79721cbfd92090c751acae5413701d61342eb98b
- Related Wolfram docs:
  - [BlankSequence](https://reference.wolfram.com/language/ref/BlankSequence.html)
  - [BlankNullSequence](https://reference.wolfram.com/language/ref/BlankNullSequence.html)
  - [Pattern](https://reference.wolfram.com/language/ref/Pattern.html)
  - [Patterns tutorial](https://reference.wolfram.com/language/tutorial/Patterns.html)

## Purpose

Tungsten supports structural Wolfram pattern matching without a running kernel. This document
specifies the variable-length argument-list subset implemented for `BlankSequence` (`__`) and
`BlankNullSequence` (`___`), including named forms such as `x__`, `x___`, `x:__`, and repeated
occurrences of sequence patterns inside the same argument list.

The goal is Wolfram-compatible behavior for ordinary non-`Flat`, non-`Orderless` expression heads.
Tungsten still does not implement general attributes, `Flat` matching, `Orderless` matching,
`Longest`, `Shortest`, `Optional`, or options-pattern machinery.

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

The table uses list notation for readability. In replacement templates, a sequence binding with
zero or more than one member behaves as a `Sequence[...]` object and is spliced when inserted into
another evaluated expression.

## Surface Syntax

Tungsten accepts these pattern forms:

- anonymous forms: `__`, `___`, `__Head`, `___Head`;
- named postfix forms: `x__`, `x___`, `x__Head`, `x___Head`;
- explicit named forms: `Pattern[x, BlankSequence[]]`, `Pattern[x, BlankNullSequence[Head]]`;
- colon forms that lower to `Pattern`, such as `x : __` and `x : ___Head`;
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
- `Pattern`, `Condition`, and `HoldPattern` wrappers inherit the width of the wrapped sequence
  pattern.

Tungsten computes the minimum remaining width of the suffix patterns before choosing a length for a
sequence pattern. This avoids trying impossible allocations.

When a sequence pattern is encountered, Tungsten tries candidate segment lengths in ascending order:

1. start at the sequence pattern minimum length (`1` for `__`, `0` for `___`);
2. stop at the largest length that leaves enough arguments for the remaining patterns;
3. for each length, test the candidate segment against the sequence pattern;
4. recurse into the remaining argument and pattern suffix;
5. return the first complete match.

This is the key multi-occurrence rule: earlier sequence patterns get the shortest segment that can
lead to a full match. Later failures can force an earlier sequence pattern to grow.

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

## Non-Goals

Tungsten still does not implement:

- matching under `Flat`, `Orderless`, or `OneIdentity` attributes;
- `Longest` and `Shortest`;
- `Optional`, default arguments, or `OptionsPattern`;
- `PatternSequence`;
- named sequence matching inside associations, because association pattern traversal is still a
  separate documented limitation;
- string-pattern sequence matching beyond the already documented string-pattern subset.

These limits keep the offline evaluator deterministic and structural while covering ordinary
variable-length function-argument patterns.
