# Tungsten documentation

- Status: Informational (index, reading order, and current-status map for Tungsten docs)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and future contributors
- Scope: `src/Tungsten`
- Created (UTC): 2026-04-23T15:36:45Z
- Repository HEAD: 67ad70b3bea14aa14a093684a3b033a53ca14d9e

## What this docs tree is for

This folder is the current-state documentation set for Tungsten, the repository's local Wolfram
automation workspace. The documents here are meant to answer different questions cleanly:

- "What is Tungsten and what does it already do?"
- "How do I use it from Python or PowerShell?"
- "What are the exact commands and payload shapes?"
- "How is it built internally?"
- "What are the machine-specific quirks and troubleshooting steps?"

The docs are split so readers can choose the right depth:

- the project README is the landing page;
- the user guide is workflow-oriented;
- the usage reference is command-oriented;
- the architecture and implementation documents are maintainer-oriented;
- focused guides cover specific subsystems such as Notebook Assistant and the expression parser.

## Recommended reading order

### If you are completely new to Tungsten

1. [../README.md](../README.md)
2. [user-guide.md](./user-guide.md)
3. [usage-reference.md](./usage-reference.md)

### If you mainly want to script Tungsten from PowerShell

1. [user-guide.md](./user-guide.md)
2. [usage-reference.md](./usage-reference.md)
3. [troubleshooting.md](./troubleshooting.md)
4. [notebook-assistant.md](./notebook-assistant.md) if your workflow touches the built-in assistant

### If you want to extend or maintain Tungsten itself

1. [../README.md](../README.md)
2. [architecture.md](./architecture.md)
3. [implementation-details.md](./implementation-details.md)
4. [expression-parser.md](./expression-parser.md)
5. [notebook-assistant.md](./notebook-assistant.md)
6. [troubleshooting.md](./troubleshooting.md)

## Documents in this folder

| Item | Purpose |
|------|---------|
| [../README.md](../README.md) | Current-state project landing page: goals, shipped surface, architecture summary, quick start, layout, and validation. |
| [user-guide.md](user-guide.md) | Practical usage guide with setup steps, tutorial flows, and common PowerShell/Python workflows. |
| [usage-reference.md](usage-reference.md) | Exhaustive command reference for the CLI and PowerShell wrapper surface. |
| [architecture.md](architecture.md) | Current architecture reference: layer ownership, execution model, and subsystem boundaries. |
| [implementation-details.md](implementation-details.md) | Environment-specific findings and the reasoning behind important implementation choices. |
| [notebook-assistant.md](notebook-assistant.md) | Focused guide for automating Mathematica's built-in Notebook Assistant against a selected source cell. |
| [expression-parser.md](expression-parser.md) | Focused guide for the kernel-free Wolfram expression parser and inert evaluator. |
| [troubleshooting.md](troubleshooting.md) | Diagnostics, failure modes, and troubleshooting guidance for installation, licensing, FrontEnd, and assistant workflows. |

## Suggested learning path by task

### Kernel-backed automation

- Start with [user-guide.md](./user-guide.md) sections on environment setup and kernel execution.
- Use [usage-reference.md](./usage-reference.md) for exact commands.
- Use [troubleshooting.md](./troubleshooting.md) if evaluation is unavailable or licensing looks wrong.

### Notebook-centric workflows

- Read [user-guide.md](./user-guide.md) sections on notebook creation, inspection, and patching.
- Use [notebook-assistant.md](./notebook-assistant.md) for assistant-specific flows.
- Use [usage-reference.md](./usage-reference.md) for selector syntax and command options.

### FrontEnd and documentation workflows

- Read [user-guide.md](./user-guide.md) sections on documentation and FrontEnd control.
- Use [usage-reference.md](./usage-reference.md) for exact `frontend` and `docs` commands.
- Use [troubleshooting.md](./troubleshooting.md) when FE actions fail or documentation search results look stale.

### Kernel-free structural analysis

- Read [expression-parser.md](./expression-parser.md).
- Use [usage-reference.md](./usage-reference.md) for `expr parse` and `expr evaluate`.
- Read [architecture.md](./architecture.md) if you need to extend the expression subsystem.

## Conventions

- Documents under this tree describe current state. Historical implementation narratives belong in
  explicit reports rather than in README, user-guide, or architecture text.
- Documents include `Created (UTC)` and `Repository HEAD` metadata. Revised documents also carry an
  `Updated (UTC)` field.
- The documentation is Windows-first because Tungsten itself is currently built around local
  Windows Wolfram installations and PowerShell automation.
- PowerShell examples assume the repository root as the working directory unless the example
  explicitly says otherwise.

## Relationship to the rest of the repo

Tungsten is its own independent workspace under `src/Tungsten`. It is not a thin wrapper over
another project in this repository. When Tungsten uses another local project, such as WinDesk for
experimental desktop-assistant flows, it treats that project as an optional integration rather than
as a hidden implementation dependency.
