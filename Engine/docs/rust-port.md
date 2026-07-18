# Historical: Tungsten Engine Rust Port

Created (UTC): 2026-07-17T00:38:00Z
Updated (UTC): 2026-07-17T07:43:05Z
Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7

> **Historical record.** This document describes the superseded Python-to-Rust migration phase.
> Rust is no longer the active Engine runtime or projection target. Use
> [cpp-port.md](./cpp-port.md) for current C++ build, runtime, and verification guidance. Commands
> and coverage numbers below are preserved as historical evidence and should not be used as current
> setup instructions.

## Objective

The objective of this completed historical phase was to port Tungsten Engine from Python to native
Rust with behavioral parity. The existing Python
implementation and its tests remain the executable specification until the Rust test suite and
differential corpus cover the same surface.

## Layout

The Rust package is rooted at `Engine/Cargo.toml`. Rust sources live under `Engine/rust/` so they
can coexist with the Python reference package at `Engine/src/tungsten/` during the migration.
The Rust implementation must not invoke Python at runtime. Python may be used only by development
and differential-test tooling as a parity oracle.

## Port order

1. Expression value model, serialization, FullForm/InputForm formatting, and Wolfram strings.
2. InputForm/FullForm tokenizer and Pratt parser, then supported StandardForm boxes.
3. Evaluator loop, attributes, symbol registry, definitions, patterns, and scoping.
4. Arithmetic, algebraic, polynomial, collection, string, sparse-array, and control-flow heads.
5. Notebook, discovery, process, kernel, FrontEnd, assistant, docs-index, REPL, and CLI surfaces.
6. PowerShell and .NET projections switched from the Python CLI to the native binary. Completed:
   both projections now resolve and invoke `tungsten-rs` without Python at runtime.

Every slice is accepted by native Rust tests and differential comparisons against the Python AST,
canonical FullForm, canonical InputForm, evaluation result, messages, and side effects as relevant.

Run parser parity checks from `Engine/` with:

```powershell
uv run python scripts/check_rust_parser_parity.py
```

Sample standalone evaluator expectations while the evaluator port is in progress with:

```powershell
uv run python scripts/check_rust_evaluator_parity.py --max-mismatches 50
```

Run fresh-process stateful scenarios for definitions, scoping, iteration, registry mutations, and
system settings with:

```powershell
uv run python scripts/check_rust_stateful_evaluator_parity.py --require-perfect
```

The evaluator sampler is intentionally non-strict by default because each extracted assertion is
evaluated in isolation. Stateful setup, messages, and side-effect assertions require native tests
or a stateful differential scenario instead of interpreting its raw mismatch count as a gate.

## Current native coverage

- Expression values, JSON serialization, FullForm/InputForm formatting, named characters, and
  Wolfram strings, including decoded and source-form inline boxes.
- InputForm, FullForm, and the supported StandardForm parser surface. The literal parser corpus is
  currently exact for all 1,414 unique extracted cases (plus one shared rejection).
- A stateful structural evaluator covering arithmetic, algebraic roots, polynomial operations,
  collections and associations, ordinary and string patterns, definitions, scoping, iteration,
  formatting and boxes, import/export, sparse arrays, messages, printing, cleanup, and control
  flow. It has 96 native unit tests.
- The expression-only standalone differential sample matches 1,212 of 1,222 extracted assertions.
  All ten reported differences require earlier state in their Python test and have native stateful
  coverage. Across the complete Python test tree, 1,583 of 1,649 isolated assertions match; the
  remaining cases are likewise state-dependent, except two intentionally distinct
  `Infinity`/`DirectedInfinity` reference baselines.
- Ten fresh-process stateful scenarios match all 82 Python-oracle steps exactly, including
  definitions, scoping, iteration, symbol-registry changes, system settings, messages,
  `Check`/`Quiet` nesting, `Assert`, cleanup, and printed side effects.
- Source-preserving notebook parsing/editing and JSON patches, inline-box composition/extraction,
  installation and license discovery, Wolfram process/kernel control, documentation indexing,
  FrontEnd and Notebook Assistant control, parser-corpus comparison, the REPL, and compatible
  JSON-first CLI command trees.
- PowerShell and typed .NET projections invoke `tungsten-rs` directly. The native PowerShell smoke
  passes, as do all nine .NET client tests.

Notebook inspect/patch and inline-box compose/extract payloads are checked structurally against the
Python implementation in addition to their native Rust unit tests.

## Remaining validation work

- Expand stateful differential scenarios and native tests for dynamic assertions that the literal
  extraction tool cannot see, especially randomized and history-sensitive behavior.
- Measure parser and evaluator performance on the full corpus and close remaining unsupported
  Wolfram syntax, box-language, precision, and built-in edge cases.
- Keep the Python implementation as the executable oracle until these gates cover its full test
  surface; it is not used by the native runtime.
