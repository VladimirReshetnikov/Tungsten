# Tungsten Inline Box Strings

Created (UTC): 2026-04-23T17:10:29Z
Updated (UTC): 2026-04-24T00:03:59Z
Repository HEAD: 045755896703fa8adf55c28e40b1ff9903a03f98

## Summary

Wolfram string literals can contain embedded inline boxes such as:

```text
\!\(\*GraphicsBox[...]\)
```

When such a string is rendered in the Mathematica FrontEnd, the embedded object can preserve its
appearance inside the string even though the underlying string value contains box escape text.

Tungsten now supports that workflow in two useful ways:

- it preserves inline-box escapes correctly when parsing Wolfram string literals;
- it can extract box-bearing objects from saved notebook cells and compose ready-to-use Wolfram
  string literals from them.

## What this is good for

Use this feature when you want to:

- embed an image or other notebook object into a Wolfram string literal;
- lift a `GraphicsBox`, `StyleBox`, `TemplateBox`, or similar box-bearing object from a saved
  notebook cell;
- script the same kind of rich string composition that a human can achieve by copy/pasting an
  object into a string literal in the FrontEnd.

## Core idea

There are three layers to the feature.

### 1. Shared string literal semantics

Tungsten now preserves unknown backslash escapes instead of dropping the backslash. That matters
because inline box syntax uses unknown-looking escapes such as:

- `\!`
- `\(`
- `\*`
- `\)`

Without that change, box-bearing strings could not round-trip safely through Tungsten.

### 2. Notebook-cell extraction

Given a saved notebook file plus a cell selector, Tungsten can inspect the selected cell and
extract:

- top-level `BoxData[...]` contents;
- inline box escapes already embedded inside string literals in that cell.

### 3. String composition

Tungsten can then compose:

- the decoded string value;
- the canonical Wolfram string literal text;
- structured box metadata for each embedded object.

## PowerShell usage

### Compose a string from an explicit box expression

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force

New-TungstenInlineBoxString `
    -Prefix "icon: " `
    -BoxExpression "GraphicsBox[{CircleBox[]}]"
```

Important output fields:

- `box_count`
- `boxes`
- `string_value`
- `string_literal`
- `string_segments`

### Extract an object from a notebook cell and compose the string in one step

```powershell
$boxNotebook = Join-Path $env:TEMP "tungsten-inline-box-demo.nb"
@'
Notebook[{
Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-inline-box"]
}]
'@ | Set-Content -Path $boxNotebook -Encoding UTF8

Get-TungstenNotebookCellInlineBoxes `
    -Path $boxNotebook `
    -ExpressionUuid "uuid-inline-box" `
    -Prefix "icon: "
```

That returns both:

- `selected_boxes[0].box_expression`, for example `GraphicsBox[{CircleBox[]}]`;
- `string_literal`, for example `"icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)"`.

### Select every embedded object from a source cell

```powershell
Get-TungstenNotebookCellInlineBoxes `
    -Path $boxNotebook `
    -CellIndex 0 `
    -AllObjects `
    -Prefix "objects: "
```

### Select a particular object by index

```powershell
Get-TungstenNotebookCellInlineBoxes `
    -Path $boxNotebook `
    -CellIndex 0 `
    -ObjectIndex 1
```

## Python CLI usage

### Compose from explicit box expressions

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)

python -m tungsten inline-box compose `
    --prefix "icon: " `
    --box-expr "GraphicsBox[{CircleBox[]}]"
```

### Extract from a notebook cell

```powershell
python -m tungsten inline-box from-cell `
    --file C:\path\to\analysis.nb `
    --expression-uuid uuid-inline-box `
    --prefix "icon: "
```

### Extract all objects from a selected cell

```powershell
python -m tungsten inline-box from-cell `
    --file C:\path\to\analysis.nb `
    --cell-index 0 `
    --all-objects `
    --prefix "objects: "
```

## Result payloads

The `inline-box from-cell` payload includes:

- `success`
- `source_cell`
- `available_box_count`
- `available_boxes`
- `selected_box_count`
- `selected_boxes`
- `string_value`
- `string_literal`
- `string_segments`

Each box record includes:

- `index`
- `head`
- `box_expression`
- `inline_box_escape`
- `string_literal`

## Selector rules

The source cell selector model matches Tungsten's notebook-assistant conventions:

- `CellIndex`
- `CellPath`
- `ExpressionUUID`
- `CellID`
- `CellTag`

Prefer `ExpressionUUID` when the notebook already has it. Use `CellIndex` for quick scripting and
synthetic notebooks.

## Current boundaries

- Extraction currently operates against saved notebook files.
- Tungsten does not yet extract arbitrary live selections from an unsaved visible FrontEnd window.
- Tungsten extracts box-bearing objects from the selected cell as stored in notebook expressions; it
  does not attempt to reproduce every possible GUI copy/paste nuance.
- The resulting `string_literal` is canonical Wolfram string text, so backslashes are doubled as
  expected in `InputForm`.

## Relationship to other Tungsten subsystems

- `wolfram_strings.py` owns the shared escape and inline-box parsing rules.
- `notebook.py` owns kernel-free extraction of `BoxData[...]` contents from notebook cell
  expressions.
- `inline_boxes.py` owns the user-facing composition and notebook-cell extraction workflow.
- `expression.py` now preserves inline-box escapes when it parses string literals.
