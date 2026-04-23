# Tungsten

Created (UTC): 2026-04-23T02:16:55Z  
Updated (UTC): 2026-04-23T04:36:53Z  
Repository HEAD: 514cecf641d6ba728984110fa239a3f7da3c516b

`Tungsten` is a Python-first, PowerShell-friendly framework for automating a local Wolfram installation from text-oriented agent workflows.

The current workspace is built around five complementary capabilities:

1. a kernel runner that executes Wolfram Language code through `wolfram.exe` and returns structured JSON instead of terminal-only output;
2. a notebook parser/editor that can inspect and patch `*.nb` files without requiring a live kernel or FrontEnd;
3. an offline documentation index over the locally installed Wolfram documentation notebooks;
4. a FrontEnd controller that can open notebooks, open documentation pages, and execute FrontEnd tokens programmatically through kernel-side `UsingFrontEnd[...]` calls;
5. a Notebook Assistant controller that can ask the built-in Mathematica assistant about a selected cell and optionally insert Wolfram Language code from the reply directly below that cell.

## Why this exists

Humans usually drive Mathematica through the GUI FrontEnd. Agents and scripts generally need something different:

- machine-readable evaluation results;
- automation that works from `pwsh`;
- useful notebook and documentation workflows even when the kernel is unavailable;
- explicit diagnostics for installation and licensing problems.

This machine has an especially relevant quirk: the installed `mathpass` contains duplicate license entries. Running the local kernel directly with that file causes `wolframscript -code ...` and similar paths to fail, but a deduplicated copy of the same file works. Tungsten treats that as a first-class environment fact and automatically runs the kernel against a temporary deduplicated password file instead of mutating the system installation.

## Layout

- `pyproject.toml` — Python package metadata.
- `src/tungsten/` — Tungsten implementation.
  - `discovery.py` — installation, docs-root, and path discovery.
  - `licensing.py` — `mathpass` inspection and deduplication helpers.
  - `kernel.py` — structured kernel execution wrapper over `wolfram.exe`.
  - `notebook.py` — structural notebook parser, renderer, and JSON patch support.
  - `docs_index.py` — SQLite FTS index for offline Wolfram documentation search.
  - `frontend.py` — programmatic FrontEnd actions built on `UsingFrontEnd`.
  - `assistant.py` — built-in Notebook Assistant automation for selected notebook cells.
  - `cli.py` — JSON CLI entrypoint used directly and from PowerShell.
- `pwsh/`
  - `Tungsten.psm1` / `Tungsten.psd1` — PowerShell wrapper layer.
- `tests/` — Python unit and integration coverage.
- `scripts/Test-TungstenSmoke.ps1` — end-to-end smoke runner with optional FrontEnd, optional Notebook Assistant, and optional WinDesk-assisted capture.
- `docs/` — architecture, implementation, usage reference, and Notebook Assistant walkthroughs.

## Current command surface

Python CLI:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
python -m tungsten env show --probe
python -m tungsten kernel eval --code "2+2"
python -m tungsten notebook inspect --file C:\path\to\file.nb
python -m tungsten docs search NotebookGet
python -m tungsten frontend open-doc paclet:ref/NotebookGet
python -m tungsten assistant ask-cell --file C:\path\to\file.nb --cell-index 7 --question "Explain what this cell does."
python -m tungsten assistant ask-cell --file C:\path\to\file.nb --expression-uuid 11111111-1111-1111-1111-111111111111 --question "Reply only with Wolfram Language code that plots Sin[x]." --insert-wolfram-code-below --save
```

PowerShell module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "FactorInteger[2^127-1]"
Find-TungstenDocumentation -Query "NotebookImport"
Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet"
Invoke-TungstenNotebookAssistant -Path C:\path\to\file.nb -CellIndex 7 -Question "Explain what this cell does."
Invoke-TungstenNotebookAssistant -Path C:\path\to\file.nb -ExpressionUuid 11111111-1111-1111-1111-111111111111 -Question "Reply only with Wolfram Language code that computes 2+2." -InsertWolframCodeBelow -Save
```

The shortest end-to-end guide for Notebook Assistant lives in [docs/notebook-assistant.md](C:/Tools1/Tools/src/Tungsten/docs/notebook-assistant.md).

## Validation

Run the Python tests:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
python -m unittest discover -s .\src\Tungsten\tests -t .\src\Tungsten
```

Run the repo-local smoke:

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
```

## Design notes

- Tungsten intentionally uses the documented `wolfram.exe` CLI instead of trying to depend on the bundled Wolfram Python client at runtime. The bundled client is present on this machine, but its cloud-oriented dependency set is incomplete in the local Python environment, while the CLI path is stable once the `mathpass` duplication is handled.
- Notebook parsing/editing is kept independent from the kernel so that agents can still inspect and patch notebooks when evaluation is unavailable, when the FrontEnd is not running, or when scripts are operating on notebooks in bulk.
- Documentation search is based on the installed documentation notebooks themselves, not on browser automation or online-only search. That keeps results local, offline, and version-aligned with the installation on the machine.
- The recommended Notebook Assistant path is `assistant ask-cell` / `Invoke-TungstenNotebookAssistant` with the default `NotebookChatCell` backend. Tungsten asks the built-in assistant through a temporary hidden chat notebook, extracts assistant text from the returned `ChatObject`, and only then performs deterministic insertion below the requested source cell. The older visible inline-desktop path remains available as the experimental `DesktopInline` backend for cases where direct UI driving is specifically desired.
