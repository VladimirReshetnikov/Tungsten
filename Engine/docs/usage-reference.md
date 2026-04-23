# Tungsten Usage Reference

Created (UTC): 2026-04-23T02:16:55Z  
Updated (UTC): 2026-04-23T04:36:53Z  
Repository HEAD: 514cecf641d6ba728984110fa239a3f7da3c516b

## Python CLI

Set the local source directory on `PYTHONPATH`:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
```

### Environment and probes

```powershell
python -m tungsten env show
python -m tungsten env show --probe
```

### Kernel execution

```powershell
python -m tungsten kernel eval --code "2+2"
python -m tungsten kernel eval --code "NotebookLocate[\"paclet:ref/NotebookGet\"]" --front-end
python -m tungsten kernel eval --file C:\path\to\script.wl
```

### Notebook inspection and editing

```powershell
python -m tungsten notebook inspect --file C:\path\to\notebook.nb
python -m tungsten notebook create --file C:\Temp\new.nb --title "Generated Notebook" --cell "Title:Generated Notebook" --cell "Text:Hello"
python -m tungsten notebook patch --file C:\Temp\new.nb --spec C:\Temp\patch.json
```

`notebook inspect` returns flat cell metadata including `index`, `path`, `style`, `preview`, `expression_uuid`, `cell_id`, and `cell_tags`. Those values are the selectors used by Notebook Assistant automation.

Example patch specification:

```json
{
  "operations": [
    {
      "op": "append_cell",
      "style": "Text",
      "text": "Tail cell"
    },
    {
      "op": "replace_cell",
      "path": [0],
      "style": "Title",
      "text": "Retitled notebook"
    },
    {
      "op": "set_option",
      "name": "WindowTitle",
      "value_expr": "\"Retitled notebook\""
    }
  ]
}
```

### Documentation indexing and search

```powershell
python -m tungsten docs index
python -m tungsten docs search NotebookGet
python -m tungsten docs read paclet:ref/NotebookImport
python -m tungsten docs open paclet:ref/NotebookGet
```

### FrontEnd control

```powershell
python -m tungsten frontend probe
python -m tungsten frontend open-notebook --file C:\Temp\new.nb
python -m tungsten frontend open-doc paclet:ref/NotebookGet
python -m tungsten frontend token OpenCloseGroup --file C:\Temp\new.nb
python -m tungsten frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
```

### Notebook Assistant

Recommended path:

```powershell
python -m tungsten assistant ask-cell --file C:\Temp\new.nb --cell-index 1 --question "Explain this cell."
python -m tungsten assistant ask-cell --file C:\Temp\new.nb --cell-index 1 --question "Reply only with Wolfram Language code that computes 2+2." --insert-wolfram-code-below --save
python -m tungsten assistant ask-cell --file C:\Temp\new.nb --expression-uuid 11111111-1111-1111-1111-111111111111 --question "Give two Wolfram Language alternatives." --insert-all-wolfram-code-below --save
```

Useful options:

- `--cell-index`, `--cell-path`, `--expression-uuid`, `--cell-id`, and `--cell-tag` select the source cell.
- `--insert-wolfram-code-below` inserts the first Wolfram Language code block from the assistant reply.
- `--insert-all-wolfram-code-below` inserts every Wolfram Language code block from the assistant reply.
- `--save` saves the notebook after insertion.
- `--extra-instructions`, `--model-service`, and `--model-name` refine the assistant request.
- `--close-assistant-notebook` closes the temporary assistant notebook when the request completes.

Experimental inline-desktop commands:

```powershell
python -m tungsten assistant prepare-inline --file C:\Temp\new.nb --cell-index 1
python -m tungsten assistant capture-inline --file C:\Temp\new.nb --cell-index 1 --insert-wolfram-code-below --save
```

Those inline commands are mainly intended for WinDesk-assisted desktop testing. For real automation, prefer `assistant ask-cell`.

## PowerShell module

Import the module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
```

### Core commands

```powershell
Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
Get-TungstenNotebook -Path C:\Temp\new.nb
New-TungstenNotebook -Path C:\Temp\demo.nb -Title "Demo" -Cell "Text:Hello" -Cell "Input:2+2"
Set-TungstenNotebook -Path C:\Temp\demo.nb -Spec C:\Temp\patch.json
Find-TungstenDocumentation -Query "NotebookImport"
Get-TungstenDocumentationPage -Identifier "paclet:ref/NotebookGet"
Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet"
Open-TungstenNotebook -Path C:\Temp\demo.nb
Invoke-TungstenFrontEnd -Code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
Invoke-TungstenNotebookAssistant -Path C:\Temp\demo.nb -CellIndex 1 -Question "Explain this cell."
Invoke-TungstenNotebookAssistant -Path C:\Temp\demo.nb -CellIndex 1 -Question "Reply only with Wolfram Language code that computes 2+2." -InsertWolframCodeBelow -Save
```

### Notebook Assistant from PowerShell

```powershell
$notebook = Get-TungstenNotebook -Path C:\Temp\demo.nb
$target = $notebook.cells | Where-Object { $_.style -eq "Input" } | Select-Object -First 1

$result = Invoke-TungstenNotebookAssistant `
    -Path C:\Temp\demo.nb `
    -CellIndex $target.index `
    -Question "Reply only with Wolfram Language code that factors x^4-1." `
    -InsertWolframCodeBelow `
    -Save
```

By default the PowerShell cmdlet uses backend `NotebookChatCell`, which is the stable hidden-chat-notebook implementation. `-Backend DesktopInline` remains available for visible desktop automation and WinDesk-based testing.

## Smoke test entrypoint

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
```

The WinDesk-assisted path is optional and activates only when the WinDesk PowerShell module has already been built. The dedicated Notebook Assistant smoke is enabled by `-IncludeAssistant`.
