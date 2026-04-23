# Tungsten Notebook Assistant

Created (UTC): 2026-04-23T04:36:53Z
Updated (UTC): 2026-04-23T21:12:16Z
Repository HEAD: e5c1e2b48eea1534033dbf6bcd549b2059db91e7

## Summary

Tungsten provides a direct high-level command for the workflow that is easy in the Mathematica
FrontEnd but awkward to automate manually:

1. choose a notebook;
2. choose a cell in that notebook;
3. ask the built-in Notebook Assistant a question about that cell;
4. if the reply contains Wolfram Language code, insert that code below the source cell;
5. optionally save the notebook.

You do not need to write a custom FrontEnd automation script for that flow anymore.

## What this guide covers

This guide focuses on:

- how to select the source cell;
- how the recommended assistant backend works;
- how to use the workflow from PowerShell and from the CLI;
- what Tungsten inserts and when;
- when to use the experimental visible inline backend instead.

## Cell selection model

Assistant workflows operate on exactly one notebook cell. Tungsten supports several selector forms:

- `ExpressionUUID`
- `CellID`
- `CellTag`
- cell path
- flat cell index

In practice:

- prefer `ExpressionUUID` when the notebook already has it;
- use `CellID` when you have a durable numeric identifier;
- use `CellTag` when your notebook intentionally assigns unique tags;
- use `CellIndex` for quick scripting and for freshly generated notebooks that do not yet have
  stable IDs.

You can inspect available selectors with:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
Get-TungstenNotebook -Path C:\path\to\analysis.nb
```

or:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
python -m tungsten notebook inspect --file C:\path\to\analysis.nb
```

The flattened notebook rows include `index`, `path`, `style`, `preview`, `expression_uuid`,
`cell_id`, and `cell_tags`.

## Recommended backend: `NotebookChatCell`

The recommended backend is `NotebookChatCell`, which is the default in PowerShell and corresponds
to `assistant ask-cell` in the CLI.

### Why this is the default

Humans naturally use the inline Notebook Assistant popup attached to a cell. Tungsten does expose
that path as `DesktopInline`, but it is not the default because it is much less reliable for
automation:

- inline assistant state lives inside FrontEnd dynamic attached-cell state;
- later helper-kernel invocations cannot recover that state as cleanly as a human can visually;
- desktop driving requires a visible foreground window and therefore depends on WinDesk and desktop
  focus.

The default `NotebookChatCell` backend instead:

1. reads the selected source cell from the real notebook;
2. creates a temporary hidden Chatbook notebook;
3. asks the built-in Notebook Assistant stack about that source cell;
4. extracts the final assistant text and code blocks from the returned `ChatObject`;
5. inserts Wolfram Language code cells below the original source cell in the real notebook.

That is still using Mathematica's built-in assistant machinery. It is simply routed through a
surface that is much easier to automate reliably.

## What Tungsten inserts

Tungsten currently looks for fenced code blocks in the assistant response. It classifies a block as
insertable Wolfram Language when the block language is one of:

- `wolfram`
- `wolfram language`
- `wolframlanguage`
- `mathematica`
- `wl`

Insertion behavior is explicit:

- `-InsertWolframCodeBelow` or `--insert-wolfram-code-below` inserts the first insertable block;
- `-InsertAllWolframCodeBelow` or `--insert-all-wolfram-code-below` inserts every insertable
  Wolfram block in the reply;
- without an insertion switch, Tungsten asks the assistant but does not modify the notebook.

If the assistant reply does not contain an insertable fenced Wolfram block, Tungsten reports the
assistant text and extracted blocks, but nothing is inserted.

## PowerShell workflow

Import the module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
```

Inspect the notebook to find the target cell:

```powershell
$notebook = Get-TungstenNotebook -Path C:\path\to\analysis.nb
$notebook.cells | Select-Object index, path, style, preview, expression_uuid, cell_id, cell_tags
```

Ask Notebook Assistant about a cell and insert the first Wolfram Language code block that appears
in the reply:

```powershell
Invoke-TungstenNotebookAssistant `
    -Path C:\path\to\analysis.nb `
    -ExpressionUuid "7d4a0f9a-17a8-4bc0-b61d-c7497fc16557" `
    -Question "Reply only with Wolfram Language code that plots the data from this cell." `
    -InsertWolframCodeBelow `
    -Save
```

The same flow using a flat cell index:

```powershell
Invoke-TungstenNotebookAssistant `
    -Path C:\path\to\analysis.nb `
    -CellIndex 7 `
    -Question "Explain this cell briefly, then give Wolfram Language code that improves it." `
    -InsertWolframCodeBelow `
    -Save
```

Example automation pattern:

```powershell
$nb = "C:\path\to\analysis.nb"
$target = (Get-TungstenNotebook -Path $nb).cells |
    Where-Object { $_.style -eq "Input" -and $_.preview -like "*LinearModelFit*" } |
    Select-Object -First 1

$result = Invoke-TungstenNotebookAssistant `
    -Path $nb `
    -CellIndex $target.index `
    -Question "Reply only with Wolfram Language code that adds residual diagnostics for this analysis." `
    -InsertWolframCodeBelow `
    -Save

if (-not $result.assistant_success) {
    throw "$($result.assistant.error_type): $($result.assistant.error)"
}
```

## Python CLI workflow

Set `PYTHONPATH` to the repo-local source tree:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
```

Inspect the notebook:

```powershell
python -m tungsten notebook inspect --file C:\path\to\analysis.nb
```

Ask the assistant about a cell and insert the first Wolfram Language code block below it:

```powershell
python -m tungsten assistant ask-cell `
    --file C:\path\to\analysis.nb `
    --expression-uuid 7d4a0f9a-17a8-4bc0-b61d-c7497fc16557 `
    --question "Reply only with Wolfram Language code that computes 2+2." `
    --insert-wolfram-code-below `
    --save
```

If you want all Wolfram Language code blocks from the reply inserted:

```powershell
python -m tungsten assistant ask-cell `
    --file C:\path\to\analysis.nb `
    --cell-index 7 `
    --question "Give two alternative Wolfram Language implementations." `
    --insert-all-wolfram-code-below `
    --save
```

Optional controls on the CLI side include:

- `--extra-instructions` for extra prompt guidance;
- `--model-service` and `--model-name` for model overrides;
- `--close-assistant-notebook` to close the temporary hidden chat notebook after the request.

## Result payloads to expect

The returned object includes:

- `assistant_success`
- `assistant.response_text`
- `assistant.code_blocks`
- `assistant.wolfram_code_blocks`
- `assistant.inserted`
- `assistant.saved_notebook`

If something goes wrong, important fields often include:

- `assistant.error_type`
- `assistant.error`
- `evaluation.stderr`

This makes it practical to treat the assistant flow as an automation primitive rather than as a UI
macro.

## Experimental visible inline backend

If you specifically want visible inline assistant driving, Tungsten still exposes it:

```powershell
Invoke-TungstenNotebookAssistant `
    -Path C:\path\to\analysis.nb `
    -CellIndex 7 `
    -Question "Reply only with Wolfram Language code that computes 2+2." `
    -Backend DesktopInline `
    -InsertWolframCodeBelow `
    -Save
```

Use that backend only when all of the following are true:

- the notebook window is visible on the desktop;
- Tungsten is allowed to bring that window to the foreground;
- the WinDesk PowerShell module is available;
- you specifically want UI-level interaction rather than the more reliable hidden chat-notebook
  path.

The PowerShell surface also exposes `KernelWindow`, which routes through the non-inline
kernel-driven assistant path.

## When to prefer each path

Prefer `NotebookChatCell` when:

- you want the most reliable automation path;
- you do not need visible UI interaction;
- you want deterministic code extraction and insertion.

Prefer `DesktopInline` only when:

- you explicitly want to automate the visible inline assistant experience;
- you are willing to accept UI focus and desktop-state requirements;
- you have WinDesk available.

## Troubleshooting pointers

If the assistant does not behave as expected:

- inspect the notebook first and confirm the selector really matches the intended cell;
- ask for fenced Wolfram code explicitly if you want insertion to happen;
- inspect `assistant.response_text` and `assistant.code_blocks` before assuming insertion failed;
- use the default backend before debugging the inline visible one.

For broader failure modes, see `troubleshooting.md`.
