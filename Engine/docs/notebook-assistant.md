# Tungsten Notebook Assistant

Created (UTC): 2026-04-23T04:36:53Z  
Updated (UTC): 2026-04-23T04:36:53Z  
Repository HEAD: 514cecf641d6ba728984110fa239a3f7da3c516b

## What Tungsten gives you

Tungsten now provides a direct high-level command for the workflow that is easy in the Mathematica FrontEnd:

1. choose a notebook;
2. choose a cell in that notebook;
3. ask the built-in Notebook Assistant a question about that cell;
4. if the reply contains Wolfram Language code, insert that code below the source cell;
5. optionally save the notebook.

You do not need to write a custom FrontEnd automation script for that flow anymore.

## Recommended PowerShell workflow

Import the module:

```powershell
Import-Module C:\Tools1\Tools\src\Tungsten\pwsh\Tungsten.psd1 -Force
```

Inspect the notebook to find the target cell:

```powershell
$notebook = Get-TungstenNotebook -Path C:\path\to\analysis.nb
$notebook.cells | Select-Object index, path, style, preview, expression_uuid, cell_id, cell_tags
```

If the notebook already has `ExpressionUUID` values, prefer them. If not, `CellIndex` is the simplest fallback.

Ask Notebook Assistant about a cell and insert the first Wolfram Language code block that appears in the reply:

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

The returned object includes:

- `assistant_success`
- `assistant.response_text`
- `assistant.code_blocks`
- `assistant.wolfram_code_blocks`
- `assistant.inserted`
- `assistant.saved_notebook`

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

## Recommended Python CLI workflow

Set `PYTHONPATH` to the repo-local source tree:

```powershell
$env:PYTHONPATH = (Resolve-Path C:\Tools1\Tools\src\Tungsten\src)
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

Optional controls:

- `--extra-instructions` appends extra prompt guidance.
- `--model-service` and `--model-name` pass assistant model overrides.
- `--close-assistant-notebook` closes the temporary hidden chat notebook after the request finishes.

## Why the default backend is not the visible inline popup

Humans naturally use the inline Notebook Assistant UI attached to a cell. Tungsten does expose that path as the `DesktopInline` backend, but it is not the default because it is much less reliable for automation:

- inline assistant state lives inside FrontEnd dynamic attached-cell state;
- later helper-kernel invocations cannot recover that state as cleanly as a human can visually;
- desktop driving requires a visible foreground window and therefore depends on WinDesk and desktop focus.

The default `NotebookChatCell` backend instead:

1. reads the selected source cell from the real notebook;
2. creates a temporary hidden Chatbook notebook;
3. asks the built-in Notebook Assistant stack about that source cell;
4. extracts the final assistant text and code blocks from the returned `ChatObject`;
5. inserts Wolfram Language code cells below the original source cell in the real notebook.

That is still using the built-in Mathematica assistant machinery. It is just routed through a text-automation-friendly surface.

## Experimental inline-desktop path

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
- you specifically want UI-level interaction rather than the more reliable hidden chat-notebook path.
