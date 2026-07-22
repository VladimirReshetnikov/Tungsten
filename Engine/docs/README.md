# Tungsten documentation

- Status: Informational (index, reading order, and current-status map for Tungsten docs)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and future contributors
- Scope: `Engine`
- Created (UTC): 2026-04-23T15:36:45Z
- Updated (UTC): 2026-07-22T19:25:35Z
- Repository HEAD: b6e36d4fcd683cb312b5bf4000be5da0205356cf

## What this docs tree is for

This folder is the current-state documentation set for Tungsten, the repository's local Wolfram
automation workspace. The documents here are meant to answer different questions cleanly:

- "What is Tungsten and what does it already do?"
- "How do I use the native CLI or PowerShell projection?"
- "How do I use it from C#/.NET?"
- "What are the exact commands and payload shapes?"
- "How is it built internally?"
- "What are the machine-specific quirks and troubleshooting steps?"

The docs are split so readers can choose the right depth:

- the project README is the landing page;
- the user guide is workflow-oriented;
- the usage reference is command-oriented;
- the .NET API guide is integration-oriented for C# callers;
- the architecture and implementation documents are maintainer-oriented;
- focused guides cover specific subsystems such as Notebook Assistant, inline-box strings, parser
  corpus validation, the expression parser, and notebook FrontEnd planning.
- the sibling Nummy workspace under `../Nummy/` holds the large-number arithmetic research corpus,
  archived standalone proposals, prior-art snapshots, and alpha/beta/gamma prototypes that feed
  Tungsten's numeric fallback work.

## Recommended reading order

### If you are completely new to Tungsten

1. [../README.md](../README.md)
2. [user-guide.md](./user-guide.md)
3. [usage-reference.md](./usage-reference.md)

### If you mainly want to script Tungsten from PowerShell

1. [user-guide.md](./user-guide.md)
2. [usage-reference.md](./usage-reference.md)
3. [troubleshooting.md](./troubleshooting.md)
4. [inline-box-strings.md](./inline-box-strings.md) if your workflow touches string literals with
   embedded notebook objects
5. [notebook-assistant.md](./notebook-assistant.md) if your workflow touches the built-in assistant

### If you want to call Tungsten from C#/.NET

1. [dotnet-api.md](./dotnet-api.md)
2. [../README.md](../README.md)
3. [architecture.md](./architecture.md) if you need to understand the wrapper boundary
4. [usage-reference.md](./usage-reference.md) when you need to correlate a .NET call with the
   underlying CLI shape

### If you want to extend or maintain Tungsten itself

1. [../README.md](../README.md)
2. [architecture.md](./architecture.md)
3. [implementation-details.md](./implementation-details.md)
4. [cpp-port.md](./cpp-port.md)
5. [haskell-port.md](./haskell-port.md)
6. [expression-parser.md](./expression-parser.md)
7. [symbol-context-registry.md](./symbol-context-registry.md)
8. [sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md)
9. [sequence-pattern-matching.md](./sequence-pattern-matching.md)
10. [import-export-formats.md](./import-export-formats.md)
11. [named-pure-functions-spec.md](./named-pure-functions-spec.md)
12. [expression-function-support.md](./expression-function-support.md)
13. [list-association-complexity.md](./list-association-complexity.md)
14. [list-association-parity-proposal.md](./list-association-parity-proposal.md)
15. [reports/2026-07-03-list-association-persistent-backends.md](./reports/2026-07-03-list-association-persistent-backends.md)
    if you are choosing the Stage B substrate or need the kernel-verified `Association` semantics
16. [numeric-simplification.md](./numeric-simplification.md)
17. [overflow-underflow-large-number-fallback.md](./overflow-underflow-large-number-fallback.md)
18. [pattern-matching-plan.md](./pattern-matching-plan.md)
19. [parser-corpus.md](./parser-corpus.md)
20. [inline-box-strings.md](./inline-box-strings.md)
21. [notebook-assistant.md](./notebook-assistant.md)
22. [reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md](./reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md)
    if you are planning a GUI notebook FrontEnd or StandardForm renderer
23. [troubleshooting.md](./troubleshooting.md)

## Documents in this folder

| Item | Purpose |
|------|---------|
| [../README.md](../README.md) | Current-state project landing page: goals, shipped surface, architecture summary, quick start, layout, and validation. |
| [user-guide.md](user-guide.md) | Practical usage guide with CMake setup steps, native CLI tutorials, and common PowerShell workflows. |
| [usage-reference.md](usage-reference.md) | Exhaustive command reference for the CLI and PowerShell wrapper surface. |
| [dotnet-api.md](dotnet-api.md) | Typed C#/.NET client guide with repository setup, API map, examples, and failure-model notes. |
| [architecture.md](architecture.md) | Current architecture reference: layer ownership, execution model, and subsystem boundaries. |
| [implementation-details.md](implementation-details.md) | Environment-specific findings and the reasoning behind important implementation choices. |
| [cpp-port.md](cpp-port.md) | Current native C++ runtime layout, verification record, parity gates, and known validation limits. |
| [rust-port.md](rust-port.md) | Historical record of the superseded Rust migration phase; not current build or runtime guidance. |
| [haskell-port.md](haskell-port.md) | Haskell build/run guide, implemented compatibility surface, current Python boundary, and migration order. |
| [inline-box-strings.md](inline-box-strings.md) | Focused guide for Wolfram string literals that embed notebook objects through inline box escapes. |
| [notebook-assistant.md](notebook-assistant.md) | Focused guide for automating Mathematica's built-in Notebook Assistant against a selected source cell. |
| [expression-parser.md](expression-parser.md) | Focused guide for the kernel-free Wolfram expression parser and bounded native evaluator. |
| [numeric-tower.md](numeric-tower.md) | Implementation notes for explicit numeric atoms, arithmetic, precision, numeric predicates, and bounded numeric evaluation. |
| [numeric-simplification.md](numeric-simplification.md) | Focused note describing `NumericQ`, variable-free `Simplify` / `FullSimplify`, and the exact transformations the offline simplifier applies. |
| [overflow-underflow-large-number-fallback.md](overflow-underflow-large-number-fallback.md) | Design proposal for adding a certified very-large-number fallback when machine arithmetic would otherwise overflow, underflow, or collapse to lossy zero. |
| [../Nummy/README.md](../Nummy/README.md) | Nummy workspace guide for the Tungsten-owned large-number arithmetic corpus and prototypes. |
| [../Nummy/docs/proposals/README.md](../Nummy/docs/proposals/README.md) | Historical index for archived standalone Nummy design proposals. |
| [../Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md](../Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md) | Current synthesis of the alpha, beta, and gamma prototype engines used as source material for Tungsten large-number work. |
| [wolfram-string-literal-spec.md](wolfram-string-literal-spec.md) | Normative specification for Wolfram-Language string literals, escape sequences, and named-character handling, with parity rules against the Wolfram 15.0 kernel. |
| [symbol-context-registry.md](symbol-context-registry.md) | Normative design note for Tungsten's process-local symbol registry, fixed context state, name queries, `Unique`, and `ValueQ` boundaries. |
| [sequence-nothing-evaluation.md](sequence-nothing-evaluation.md) | Normative specification for `Sequence` splicing and `Nothing` removal in Tungsten's kernel-free evaluator. |
| [sequence-pattern-matching.md](sequence-pattern-matching.md) | Normative specification for structural sequence-pattern allocation, named sequence bindings, repetition, optional arguments, options patterns, and match-priority wrappers. |
| [import-export-formats.md](import-export-formats.md) | Focused guide for kernel-free `ImportString` / `ExportString` / `ImportByteArray` / `ExportByteArray` support and the implemented format subset. |
| [named-pure-functions-spec.md](named-pure-functions-spec.md) | Detailed specification for named-parameter pure functions and Tungsten's capture-avoiding renaming rules. |
| [expression-function-support.md](expression-function-support.md) | Support matrix for the structural Wolfram functions that Tungsten currently implements offline. |
| [list-association-complexity.md](list-association-complexity.md) | Maintainer note comparing the theoretical complexity of common Wolfram `List` and `Association` operations with Tungsten's Python expression representation. |
| [list-association-parity-proposal.md](list-association-parity-proposal.md) | Proposal for closing the `Association` asymptotic gap with a retained persistent key index, bulk builders, dependency choices, and validation guardrails. |
| [reports/2026-07-03-list-association-persistent-backends.md](reports/2026-07-03-list-association-persistent-backends.md) | Substrate-level design study for persistent `List` and `Association` backends (chunked ropes, HAMT + stamp-ordered deque), with Wolfram 14.3 kernel-verified semantics, adversarial-review corrections, migration order, and substrate requirements. |
| [pattern-matching-plan.md](pattern-matching-plan.md) | Design and rollout plan for Tungsten's first kernel-free Wolfram pattern-matching subset. |
| [parser-corpus.md](parser-corpus.md) | Parser corpus discovery, Wolfram held-parser comparison, outputs, and test-entrypoint reference. |
| [troubleshooting.md](troubleshooting.md) | Diagnostics, failure modes, and troubleshooting guidance for installation, licensing, FrontEnd, and assistant workflows. |
| [reports/2026-04-25-parser-speed-experiments.md](reports/2026-04-25-parser-speed-experiments.md) | Notebook parser profiling, landed parser-speed improvements, parser-corpus throughput measurements, and next optimization proposals. |
| [reports/2026-04-25-parser-corpus-speed.md](reports/2026-04-25-parser-corpus-speed.md) | Parser corpus throughput measurements, bottleneck analysis, implemented optimizations, and full-corpus runtime estimates. |
| [reports/2026-04-24-license-seat-investigation.md](reports/2026-04-24-license-seat-investigation.md) | Investigation report for intermittent license-seat failures, ghost/orphaned Wolfram processes, and Tungsten's launch-gate mitigation. |
| [reports/2026-04-27-tungsten-gap-and-shape-review.md](reports/2026-04-27-tungsten-gap-and-shape-review.md) | Planning inventory of remaining Tungsten expression-function family holes, incomplete Wolfram argument shapes, unsupported options, and implementation buckets. Supersedes the earlier `2026-04-26-function-surface-gap-report.md`, the `2026-04-26-expression-parity-deep-review.md`, the `2026-04-24-parser-evaluator-kernel-parity*.md` pair, and the `2026-04-23-external-review.md` (all archived). |
| [reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md](reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md) | Recommendation report for a simple Tungsten notebook FrontEnd, including WebView2, browser-hosted, VS Code, Jupyter, native UI, direct StandardForm boxes, and TeX/MathJax alternatives. |
| [reports/2026-04-28-modern-mathematica-core-design.md](reports/2026-04-28-modern-mathematica-core-design.md) | Compatibility-free design report for a modern Mathematica-like core language and evaluator, informed by Tungsten's parser, evaluator, pattern, symbol-registry, and notebook boundaries. |

## Suggested learning path by task

### Kernel-backed automation

- Start with [user-guide.md](./user-guide.md) sections on environment setup and kernel execution.
- Use [usage-reference.md](./usage-reference.md) for exact commands.
- Use [troubleshooting.md](./troubleshooting.md) if evaluation is unavailable or licensing looks wrong.

### Notebook-centric workflows

- Read [user-guide.md](./user-guide.md) sections on notebook creation, inspection, and patching.
- Read [inline-box-strings.md](./inline-box-strings.md) when you need to lift objects out of
  notebook cells and embed them into string literals.
- Read [reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md](./reports/2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md)
  when planning a graphical `.nb` editor, StandardForm renderer, or TeX/MathJax output path.
- Use [notebook-assistant.md](./notebook-assistant.md) for assistant-specific flows.
- Use [usage-reference.md](./usage-reference.md) for selector syntax and command options.

### FrontEnd and documentation workflows

- Read [user-guide.md](./user-guide.md) sections on documentation and FrontEnd control.
- Use [usage-reference.md](./usage-reference.md) for exact `frontend` and `docs` commands.
- Use [troubleshooting.md](./troubleshooting.md) when FE actions fail or documentation search results look stale.

### .NET application integration

- Read [dotnet-api.md](./dotnet-api.md) for the typed wrapper surface and examples.
- Read [architecture.md](./architecture.md) when deciding whether to add a new typed method versus
  using the generic JSON escape hatch.
- Use [usage-reference.md](./usage-reference.md) to understand the CLI command that sits underneath
  a given .NET call.

### Kernel-free structural analysis

- Read [repl.md](./repl.md) if you want the console-mode `tungsten-cpp(.exe)` interpreter and its
  `wolfram.exe`-style history behavior.
- Read [expression-parser.md](./expression-parser.md).
- Read [numeric-tower.md](./numeric-tower.md) and [numeric-simplification.md](./numeric-simplification.md)
  if your work touches numeric predicates, `N`, `Simplify`, or exact/inexact conversion.
- Read [overflow-underflow-large-number-fallback.md](./overflow-underflow-large-number-fallback.md)
  if your work touches machine overflow, underflow, structural large numbers, or Nummy-derived
  tower arithmetic.
- Read [symbol-context-registry.md](./symbol-context-registry.md) if you need precise
  `$Context`, `$ContextPath`, `Names`, `NameQ`, `Attributes`, `Symbol`, `Unique`, or `ValueQ`
  behavior, including the Wolfram 15.0 <code>System`</code> symbol snapshot.
- Read [sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md) if you need precise
  `Sequence` / `Nothing` evaluation-order behavior.
- Read [sequence-pattern-matching.md](./sequence-pattern-matching.md) if you need the exact
  allocation and binding rules for `__`, `___`, `Repeated`, `PatternSequence`, `Optional`,
  `OptionsPattern`, named sequence patterns, and repeated sequence variables.
- Read [import-export-formats.md](./import-export-formats.md) if you need the exact string /
  byte-array format subset and the data-shape rules for JSON, tabular text, and compression wrappers.
- Read [named-pure-functions-spec.md](./named-pure-functions-spec.md) if you need the exact
  capture-avoiding renaming rule for named pure functions.
- Read [expression-function-support.md](./expression-function-support.md) for the exact built-in coverage and official Wolfram reference links.
- Read [list-association-complexity.md](./list-association-complexity.md) when you need the
  historical asymptotic cost model for Wolfram-style lists and associations versus the Python
  compatibility oracle's representation.
- Read [list-association-parity-proposal.md](./list-association-parity-proposal.md) when planning
  changes that close the retained-key-index and association-builder gaps identified by the
  complexity note.
- Read [reports/2026-07-03-list-association-persistent-backends.md](./reports/2026-07-03-list-association-persistent-backends.md)
  when choosing the Stage B persistent substrate, or when you need the kernel-verified
  `Association` ordering/duplicate-key/positional semantics and the `List` backend design.
- Read [pattern-matching-plan.md](./pattern-matching-plan.md) if you need the design boundaries and validation strategy for the new pattern subset.
- Use [usage-reference.md](./usage-reference.md) for `expr parse` and `expr evaluate`.
- Use [parser-corpus.md](./parser-corpus.md) when measuring parser acceptance against the local
  notebook/package corpus and Wolfram held-parser oracle.
- Read [architecture.md](./architecture.md) if you need to extend the expression subsystem.

## Conventions

- Documents under this tree describe current state. Historical implementation narratives belong in
  explicit reports rather than in README, user-guide, or architecture text.
- Documents include `Created (UTC)` and `Repository HEAD` metadata. Revised documents also carry an
  `Updated (UTC)` field.
- Use `pwsh -File .\Engine\scripts\Update-TungstenDocsProvenance.ps1` after a documentation
  pass so the shared Tungsten docs metadata stays consistent.
- The documentation is Windows-first because Tungsten itself is currently built around local
  Windows Wolfram installations and PowerShell automation.
- PowerShell examples assume the repository root as the working directory unless the example
  explicitly says otherwise.

## Relationship to the rest of the repo

Tungsten is its own independent workspace under `Engine`. `Engine/Nummy/` is now a
Tungsten subworkspace for large-number arithmetic research and prototypes. When Tungsten uses any
other local project, such as WinDesk for experimental desktop-assistant flows, it treats that project
as an optional integration rather than as a hidden implementation dependency.
