# Tungsten documentation

- Status: Informational (index, reading order, and current-status map for Tungsten docs)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and future contributors
- Scope: `src/Tungsten`
- Created (UTC): 2026-04-23T15:36:45Z
- Updated (UTC): 2026-04-25T01:46:40Z
- Repository HEAD: dac74d643ce319a384a81fd5a91d6cd1f961f9f2

## What this docs tree is for

This folder is the current-state documentation set for Tungsten, the repository's local Wolfram
automation workspace. The documents here are meant to answer different questions cleanly:

- "What is Tungsten and what does it already do?"
- "How do I use it from Python or PowerShell?"
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
- focused guides cover specific subsystems such as Notebook Assistant, inline-box strings, and the
  the expression parser.

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
4. [expression-parser.md](./expression-parser.md)
5. [sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md)
6. [import-export-formats.md](./import-export-formats.md)
7. [named-pure-functions-spec.md](./named-pure-functions-spec.md)
8. [expression-function-support.md](./expression-function-support.md)
9. [pattern-matching-plan.md](./pattern-matching-plan.md)
10. [inline-box-strings.md](./inline-box-strings.md)
11. [notebook-assistant.md](./notebook-assistant.md)
12. [troubleshooting.md](./troubleshooting.md)

## Documents in this folder

| Item | Purpose |
|------|---------|
| [../README.md](../README.md) | Current-state project landing page: goals, shipped surface, architecture summary, quick start, layout, and validation. |
| [user-guide.md](user-guide.md) | Practical usage guide with setup steps, tutorial flows, and common PowerShell/Python workflows. |
| [usage-reference.md](usage-reference.md) | Exhaustive command reference for the CLI and PowerShell wrapper surface. |
| [dotnet-api.md](dotnet-api.md) | Typed C#/.NET client guide with repository setup, API map, examples, and failure-model notes. |
| [architecture.md](architecture.md) | Current architecture reference: layer ownership, execution model, and subsystem boundaries. |
| [implementation-details.md](implementation-details.md) | Environment-specific findings and the reasoning behind important implementation choices. |
| [inline-box-strings.md](inline-box-strings.md) | Focused guide for Wolfram string literals that embed notebook objects through inline box escapes. |
| [notebook-assistant.md](notebook-assistant.md) | Focused guide for automating Mathematica's built-in Notebook Assistant against a selected source cell. |
| [expression-parser.md](expression-parser.md) | Focused guide for the kernel-free Wolfram expression parser and inert evaluator. |
| [sequence-nothing-evaluation.md](sequence-nothing-evaluation.md) | Normative specification for `Sequence` splicing and `Nothing` removal in Tungsten's kernel-free evaluator. |
| [import-export-formats.md](import-export-formats.md) | Focused guide for kernel-free `ImportString` / `ExportString` / `ImportByteArray` / `ExportByteArray` support and the implemented format subset. |
| [named-pure-functions-spec.md](named-pure-functions-spec.md) | Detailed specification for named-parameter pure functions and Tungsten's capture-avoiding renaming rules. |
| [expression-function-support.md](expression-function-support.md) | Support matrix for the structural Wolfram functions that Tungsten currently implements offline. |
| [pattern-matching-plan.md](pattern-matching-plan.md) | Design and rollout plan for Tungsten's first kernel-free Wolfram pattern-matching subset. |
| [troubleshooting.md](troubleshooting.md) | Diagnostics, failure modes, and troubleshooting guidance for installation, licensing, FrontEnd, and assistant workflows. |
| [reports/2026-04-24-license-seat-investigation.md](reports/2026-04-24-license-seat-investigation.md) | Investigation report for intermittent license-seat failures, ghost/orphaned Wolfram processes, and Tungsten's launch-gate mitigation. |

## Suggested learning path by task

### Kernel-backed automation

- Start with [user-guide.md](./user-guide.md) sections on environment setup and kernel execution.
- Use [usage-reference.md](./usage-reference.md) for exact commands.
- Use [troubleshooting.md](./troubleshooting.md) if evaluation is unavailable or licensing looks wrong.

### Notebook-centric workflows

- Read [user-guide.md](./user-guide.md) sections on notebook creation, inspection, and patching.
- Read [inline-box-strings.md](./inline-box-strings.md) when you need to lift objects out of
  notebook cells and embed them into string literals.
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

- Read [expression-parser.md](./expression-parser.md).
- Read [sequence-nothing-evaluation.md](./sequence-nothing-evaluation.md) if you need precise
  `Sequence` / `Nothing` evaluation-order behavior.
- Read [import-export-formats.md](./import-export-formats.md) if you need the exact string /
  byte-array format subset and the data-shape rules for JSON, tabular text, and compression wrappers.
- Read [named-pure-functions-spec.md](./named-pure-functions-spec.md) if you need the exact
  capture-avoiding renaming rule for named pure functions.
- Read [expression-function-support.md](./expression-function-support.md) for the exact built-in coverage and official Wolfram reference links.
- Read [pattern-matching-plan.md](./pattern-matching-plan.md) if you need the design boundaries and validation strategy for the new pattern subset.
- Use [usage-reference.md](./usage-reference.md) for `expr parse` and `expr evaluate`.
- Read [architecture.md](./architecture.md) if you need to extend the expression subsystem.

## Conventions

- Documents under this tree describe current state. Historical implementation narratives belong in
  explicit reports rather than in README, user-guide, or architecture text.
- Documents include `Created (UTC)` and `Repository HEAD` metadata. Revised documents also carry an
  `Updated (UTC)` field.
- Use `pwsh -File .\src\Tungsten\scripts\Update-TungstenDocsProvenance.ps1` after a documentation
  pass so the shared Tungsten docs metadata stays consistent.
- The documentation is Windows-first because Tungsten itself is currently built around local
  Windows Wolfram installations and PowerShell automation.
- PowerShell examples assume the repository root as the working directory unless the example
  explicitly says otherwise.

## Relationship to the rest of the repo

Tungsten is its own independent workspace under `src/Tungsten`. It is not a thin wrapper over
another project in this repository. When Tungsten uses another local project, such as WinDesk for
experimental desktop-assistant flows, it treats that project as an optional integration rather than
as a hidden implementation dependency.
