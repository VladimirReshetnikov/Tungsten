# Tungsten Structural Expression Function Support

- Status: Informational and reference-oriented (kernel-free structural expression support matrix)
- Audience: Tungsten users, automation authors, maintainers, and anyone relying on offline Wolfram expression manipulation
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-23T18:33:04Z
- Repository HEAD: d802d432d96644fe1275d8577806edf3bbb7ec97
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
- Pattern-driven functions are intentionally out of scope for this subsystem.
- Operator forms are generally out of scope unless they happen to reduce to the direct forms below.
- `Take` and `Drop` currently support a single first-level specification only.
- `Map` currently supports `Map[f, expr]` only.
- `Apply` currently supports `Apply[f, expr]` only.
- `Flatten` currently supports `Flatten[expr]` and `Flatten[expr, n]` where `n` is a non-negative
  integer or `Infinity`.
- `ReplacePart` supports exact position rules and ignores positions that do not exist, matching the
  practical behavior of Wolfram's direct rule form.
- `Delete` and `MapAt` support exact positions and lists of exact positions; invalid positions
  currently surface as Tungsten evaluation errors.

## Supported functions

| Function | Tungsten-supported forms | Brief description | Official Wolfram docs |
|------|------|------|------|
| `Length` | `Length[expr]` | Returns the number of immediate arguments in an expression. | [Length](https://reference.wolfram.com/language/ref/Length) |
| `Depth` | `Depth[expr]` | Returns the structural depth of an expression tree. | [Depth](https://reference.wolfram.com/language/ref/Depth) |
| `Head` | `Head[expr]` | Returns the head of an expression. | [Head](https://reference.wolfram.com/language/ref/Head) |
| `Part` | `Part[expr, spec1, ...]` | Extracts parts by exact structural position, including spans, `All`, and selector lists. | [Part](https://reference.wolfram.com/language/ref/Part) |
| `Extract` | `Extract[expr, pos]` | Extracts one or more parts using explicit position lists. | [Extract](https://reference.wolfram.com/language/ref/Extract) |
| `Level` | `Level[expr, spec]`, `Level[expr, spec, False]` | Returns subexpressions at requested positive or negative levels. | [Level](https://reference.wolfram.com/language/ref/Level) |
| `First` | `First[expr]`, `First[expr, default]` | Returns the first argument of an expression, with optional default for empty expressions. | [First](https://reference.wolfram.com/language/ref/First) |
| `Last` | `Last[expr]`, `Last[expr, default]` | Returns the last argument of an expression, with optional default for empty expressions. | [Last](https://reference.wolfram.com/language/ref/Last) |
| `Rest` | `Rest[expr]` | Returns an expression with its first argument removed. | [Rest](https://reference.wolfram.com/language/ref/Rest) |
| `Most` | `Most[expr]` | Returns an expression with its last argument removed. | [Most](https://reference.wolfram.com/language/ref/Most) |
| `Take` | `Take[expr, n]`, `Take[expr, All]`, `Take[expr, span]`, `Take[expr, {n}]`, `Take[expr, {m, n}]`, `Take[expr, {m, n, s}]` | Selects a first-level slice while preserving the original head. | [Take](https://reference.wolfram.com/language/ref/Take) |
| `Drop` | `Drop[expr, n]`, `Drop[expr, All]`, `Drop[expr, span]`, `Drop[expr, {n}]`, `Drop[expr, {m, n}]`, `Drop[expr, {m, n, s}]` | Removes a first-level slice while preserving the original head. | [Drop](https://reference.wolfram.com/language/ref/Drop) |
| `Append` | `Append[expr, item]` | Adds an argument at the end of a nonatomic expression. | [Append](https://reference.wolfram.com/language/ref/Append) |
| `Prepend` | `Prepend[expr, item]` | Adds an argument at the beginning of a nonatomic expression. | [Prepend](https://reference.wolfram.com/language/ref/Prepend) |
| `Join` | `Join[expr1, expr2, ...]` | Concatenates expressions that share the same head. | [Join](https://reference.wolfram.com/language/ref/Join) |
| `Reverse` | `Reverse[expr]` | Reverses the order of the immediate arguments of an expression. | [Reverse](https://reference.wolfram.com/language/ref/Reverse) |
| `RotateLeft` | `RotateLeft[expr]`, `RotateLeft[expr, n]` | Rotates immediate arguments to the left. | [RotateLeft](https://reference.wolfram.com/language/ref/RotateLeft) |
| `RotateRight` | `RotateRight[expr]`, `RotateRight[expr, n]` | Rotates immediate arguments to the right. | [RotateRight](https://reference.wolfram.com/language/ref/RotateRight) |
| `Flatten` | `Flatten[expr]`, `Flatten[expr, n]`, `Flatten[expr, Infinity]` | Flattens nested subexpressions that have the same head as the outer expression. | [Flatten](https://reference.wolfram.com/language/ref/Flatten) |
| `Delete` | `Delete[expr, pos]` | Removes one or more exact-position parts from an expression. | [Delete](https://reference.wolfram.com/language/ref/Delete) |
| `ReplacePart` | `ReplacePart[expr, rule]`, `ReplacePart[expr, {rule1, ...}]` | Replaces exact-position parts using explicit rules. | [ReplacePart](https://reference.wolfram.com/language/ref/ReplacePart) |
| `Apply` | `Apply[f, expr]` | Replaces the head of a nonatomic expression with another expression. | [Apply](https://reference.wolfram.com/language/ref/Apply) |
| `Map` | `Map[f, expr]` | Applies a function structurally to each immediate argument. | [Map](https://reference.wolfram.com/language/ref/Map) |
| `MapAt` | `MapAt[f, expr, pos]` | Applies a function structurally at one or more exact positions. | [MapAt](https://reference.wolfram.com/language/ref/MapAt) |

## Notes on position semantics

- Tungsten position handling is exact and structural. It does not implement pattern matching.
- The same position syntax family is shared across `Part`, `Extract`, `Delete`, `ReplacePart`, and
  `MapAt`, but not every Wolfram-language variant is implemented.
- `Part` and `Extract` support selector-style components such as `All`, spans, and selector lists.
- `ReplacePart` and `MapAt` support exact position lists and lists of exact position lists.
- Tungsten canonicalizes negative positions to concrete positive positions internally before
  applying updates, which keeps multi-update behavior deterministic.

## Notes on atoms and empty expressions

- `Apply[f, atom]` and `Map[f, atom]` leave atoms unchanged.
- `First` and `Last` honor the optional default argument on empty expressions.
- Many sequence-oriented transforms such as `Append`, `Prepend`, `Join`, `Reverse`,
  `RotateLeft`, `RotateRight`, and `Flatten` expect a nonatomic expression.
- Empty nonatomic expressions such as `f[]` are handled structurally where that behavior is
  straightforward and deterministic.
