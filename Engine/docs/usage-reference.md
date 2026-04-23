# Tungsten Usage Reference

Created (UTC): 2026-04-23T02:16:55Z  
Repository HEAD: e809b942e10d2495fa5a680a33e6009412da447a

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
```

## Smoke test entrypoint

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
```

The WinDesk-assisted path is optional and activates only when the WinDesk PowerShell module has already been built.
