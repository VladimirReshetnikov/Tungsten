# Tungsten Architecture

Created (UTC): 2026-04-23T02:16:55Z  
Repository HEAD: e809b942e10d2495fa5a680a33e6009412da447a

## Overview

Tungsten is organized as a thin set of cooperating layers:

1. `discovery.py` locates the installation, documentation roots, and licensing artifacts.
2. `licensing.py` converts the machine-local `mathpass` into a safe, deduplicated temporary password file for execution.
3. `kernel.py` runs `wolfram.exe` in a controlled, script-driven mode and returns structured JSON results.
4. `frontend.py` builds on the kernel layer to execute `UsingFrontEnd[...]`, `NotebookOpen`, `NotebookLocate`, and `FrontEndTokenExecute`.
5. `notebook.py` parses and rewrites notebook expressions directly from file text.
6. `docs_index.py` indexes the local documentation notebook corpus into a SQLite FTS database.
7. `pwsh/Tungsten.psm1` projects the JSON CLI into PowerShell-friendly commands.

## Execution model

### Kernel execution

The kernel runner does not pass user code directly on the command line. Instead, it:

1. creates a temporary deduplicated `mathpass`;
2. writes the requested Wolfram Language code to a temporary input file;
3. writes a wrapper script that:
   - imports the code,
   - parses it with `ToExpression[..., HoldComplete]`,
   - optionally wraps it in `UsingFrontEnd[...]`,
   - evaluates it through `EvaluationData[...]`,
   - stringifies the result and message metadata into JSON-compatible values,
   - exports a JSON payload to a temporary result file;
4. runs `wolfram.exe -noprompt -pwfile <deduped> -script <wrapper>`;
5. reads the JSON payload back into Python.

This approach is more robust than trying to parse mixed stdout/stderr streams, and it gives Tungsten stable result objects for both kernel-only and FrontEnd-targeted flows.

### FrontEnd execution

The FrontEnd controller is intentionally small. It does not duplicate the entire FrontEnd API; instead, it provides a dependable path for the operations that matter most in agent and automation workflows:

- open a notebook file;
- open a documentation page by paclet identifier;
- execute an arbitrary `UsingFrontEnd[...]` expression;
- execute a named FrontEnd token.

These are all expressed as Wolfram Language code and then delegated to the same kernel runner, which keeps licensing and process setup policy centralized.

## Notebook model

`notebook.py` implements a structural parser rather than a full Wolfram Language parser. The parser understands:

- strings, including escaped characters;
- nested Wolfram comments `(* ... *)`;
- bracket nesting for `[]`, `{}`, and `()`;
- top-level expression splitting on commas;
- the notebook patterns that matter for practical file manipulation:
  - `Notebook[...]`
  - `Cell[...]`
  - `Cell[CellGroupData[...]]`

That is deliberate. The goal is not to interpret arbitrary Wolfram code; the goal is to make notebook files inspectable and editable in a way that is resilient, local, and independent from a running kernel.

The model preserves raw expressions for unchanged nodes. When an operation modifies a cell or group, Tungsten regenerates only the affected structural expressions.

## Documentation indexing

Wolfram documentation pages are themselves notebooks. Tungsten indexes those notebook files directly:

- it discovers local documentation roots from the shared installation tree and from user-installed `SystemDocsUpdate*` paclets;
- it extracts a title from `WindowTitle->...`;
- it derives an approximate paclet identifier from the file’s location in `ReferencePages`, `Guides`, `Tutorials`, and similar sections;
- it extracts string literals from the notebook text to build a full-text search payload;
- it stores metadata plus an FTS index in SQLite.

The index is intentionally approximate rather than semantically perfect. The tradeoff is worthwhile because it stays offline, installation-local, and easy to rebuild.

## PowerShell projection

The PowerShell module is intentionally thin. It does not reimplement Tungsten logic; it just:

- sets `PYTHONPATH` to the project `src/` directory;
- calls `python -m tungsten ...`;
- deserializes the resulting JSON;
- exposes ergonomic PowerShell function names for common tasks.

This keeps the authoritative implementation in one place while still making `pwsh` automation pleasant.
