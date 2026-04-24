# Tungsten Usage Reference

- Status: Informational and reference-oriented (command surface and payload reference)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and anyone scripting the CLI or PowerShell wrappers
- Scope: Tungsten command-line and PowerShell surfaces
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-04-24T04:24:45Z
- Repository HEAD: 078e521a368bd61c48df4bd9bb25ebac45ee6215
- Related docs:
  - [Project README](../README.md)
  - [User Guide](./user-guide.md)
  - [C#/.NET API](./dotnet-api.md)
  - [Inline Box Strings](./inline-box-strings.md)
  - [Troubleshooting](./troubleshooting.md)
  - [Notebook Assistant](./notebook-assistant.md)
  - [Expression Parser](./expression-parser.md)
  - [Expression Function Support](./expression-function-support.md)

## Conventions

- The Python CLI is JSON-first. Every command returns structured JSON.
- The PowerShell module is a thin wrapper over `python -m tungsten ...`; it returns deserialized
  PowerShell objects based on those JSON payloads.
- The .NET client in [dotnet-api.md](./dotnet-api.md) is a typed wrapper over the same JSON
  command surface documented here.
- Kernel-backed commands depend on a real local Wolfram installation.
- Kernel-free commands such as notebook file inspection and expression parsing do not require a
  running kernel.

## Exit codes

- `0` means the command completed and produced its normal JSON payload. For commands that support
  `--require-success`, the payload may still describe a structured failure when that switch is not
  supplied.
- `1` means the command reported a structured failure that Tungsten treats as user-visible failure:
  `expr parse` and `expr evaluate` use it for syntax and structural evaluation errors, and
  `kernel`, `frontend`, `assistant`, and `inline-box from-cell` use it when `--require-success` is
  supplied and the returned payload reports failure.
- `2` is currently used only by `kernel eval`, and means Tungsten could not produce a structured
  evaluation payload at all. Typical causes include `KernelNotFound`, launch failures, or a kernel
  run that never reached Tungsten's JSON export step.

## Python CLI

Set the local source directory on `PYTHONPATH`:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
```

### `env`

#### `env show`

Purpose:

- show discovered installation paths and local documentation roots;
- optionally run live kernel and FrontEnd probes.

Examples:

```powershell
python -m tungsten env show
python -m tungsten env show --probe
```

Important output fields:

- `install_dir`
- `kernel_cli`
- `kernel_executable`
- `frontend_executable`
- `wolframscript`
- `mathpass`
- `docs_roots`
- `bundled_python_client`
- `default_index_path`
- `probe` when `--probe` is supplied

### `kernel`

#### `kernel eval`

Purpose:

- evaluate inline Wolfram Language code or a file through `wolfram.exe`;
- optionally evaluate inside `UsingFrontEnd[...]`.

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--working-directory <path>`: optional
- `--front-end`: wrap evaluation in `UsingFrontEnd[...]`
- `--require-success`: return exit code `1` when the evaluation reports `success: false`

Examples:

```powershell
python -m tungsten kernel eval --code "2+2"
python -m tungsten kernel eval --code "Print[Prime[10]]; Prime[20]"
python -m tungsten kernel eval --code "NotebookLocate[\"paclet:ref/NotebookGet\"]" --front-end
python -m tungsten kernel eval --file C:\path\to\script.wl
```

Important output fields:

- `success`
- `failure_type`
- `result`
- `result_head`
- `messages`
- `messages_text`
- `output`
- `timing`
- `absolute_timing`
- `evaluation_available`
- `mathpass`
- `used_mathpass_workaround`

### `notebook`

#### `notebook inspect`

Purpose:

- parse a notebook file structurally and return a flattened cell inventory.

Example:

```powershell
python -m tungsten notebook inspect --file C:\path\to\notebook.nb
```

Important output fields:

- `title`
- `cell_count`
- `group_count`
- `options`
- `cells`

Each cell row may include:

- `index`
- `path`
- `style`
- `preview`
- `expression_uuid`
- `cell_id`
- `cell_tags`

#### `notebook create`

Purpose:

- create a notebook file from a title plus repeated `STYLE:TEXT` cell specifications.

Options:

- `--file <path>`: required
- `--title <text>`: optional
- `--cell <STYLE:TEXT>`: repeatable

Example:

```powershell
python -m tungsten notebook create `
    --file C:\Temp\new.nb `
    --title "Generated Notebook" `
    --cell "Title:Generated Notebook" `
    --cell "Text:Hello" `
    --cell "Input:2+2"
```

#### `notebook patch`

Purpose:

- apply a JSON patch spec to a notebook.

Options:

- `--file <path>`: required
- `--spec <path>`: required
- `--out <path>`: optional; defaults to in-place update

Example:

```powershell
python -m tungsten notebook patch --file C:\Temp\new.nb --spec C:\Temp\patch.json
```

Patch operations currently supported by Tungsten include:

- `append_cell`
- `insert_cell`
- `replace_cell`
- `delete_item`
- `set_option`

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

### `inline-box`

Purpose:

- compose Wolfram string literals that contain embedded inline box escapes;
- extract box-bearing objects from saved notebook cells and immediately turn them into ready-to-use
  string literals.

#### Shared selector options

These selector forms are mutually exclusive and are reused across cell-targeted inline-box
commands:

- `--cell-index <n>`
- `--cell-path <json-or-comma-separated-int-list>`
- `--expression-uuid <uuid>`
- `--cell-id <int>`
- `--cell-tag <tag>`

#### `inline-box compose`

Options:

- `--prefix <text>`: optional
- `--box-expr <text>`: repeatable
- `--suffix <text>`: optional

Example:

```powershell
python -m tungsten inline-box compose `
    --prefix "icon: " `
    --box-expr "GraphicsBox[{CircleBox[]}]"
```

Important output fields:

- `boxes`
- `string_value`
- `string_literal`
- `string_segments`

#### `inline-box from-cell`

Options:

- `--file <path>`: required
- one selector option: required
- `--prefix <text>`: optional
- `--suffix <text>`: optional
- `--object-index <n>`: optional; defaults to `0`
- `--all-objects`: optional
- `--require-success`

Examples:

```powershell
python -m tungsten inline-box from-cell `
    --file C:\Temp\demo.nb `
    --expression-uuid uuid-inline-box `
    --prefix "icon: "

python -m tungsten inline-box from-cell `
    --file C:\Temp\demo.nb `
    --cell-index 0 `
    --all-objects `
    --prefix "objects: "
```

Important output fields:

- `source_cell`
- `available_box_count`
- `available_boxes`
- `selected_box_count`
- `selected_boxes`
- `string_value`
- `string_literal`
- `string_segments`

### `expr`

Purpose:

- parse Wolfram expressions without a kernel;
- structurally evaluate a small inert built-in set.

#### `expr parse`

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--form input|fullform|standard`: optional; defaults to `input`

Examples:

```powershell
python -m tungsten expr parse --code "1 + 2 x^3"
python -m tungsten expr parse --code "Rule[x, List[1, 2]]" --form fullform
python -m tungsten expr parse --code "f @ x // g" --form standard
```

Important output fields:

- `input_form`
- `full_form`
- `depth`
- `length`
- `tree`

On syntax failure, `expr parse` still writes structured JSON to stdout and returns exit code `1`
with:

- `success: false`
- `error_type: "WolframSyntaxError"`
- `error`

#### `expr evaluate`

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--form input|fullform|standard`: optional; defaults to `input`

Examples:

```powershell
python -m tungsten expr evaluate --code "Length[{a, b, c}]"
python -m tungsten expr evaluate --code "1 + 2 + 3"
python -m tungsten expr evaluate --code "True && False && x"
python -m tungsten expr evaluate --code "Level[f[a, g[b]], -1]"
python -m tungsten expr evaluate --code "Part[f[a, b, c], {1, 3}]"
python -m tungsten expr evaluate --code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
python -m tungsten expr evaluate --code "MatchQ[f[a, a], f[x_, x_]]"
python -m tungsten expr evaluate --code "MatchQ[f[2], f[x_ /; x > 0]]"
python -m tungsten expr evaluate --code "FreeQ[f[a], f]"
python -m tungsten expr evaluate --code "Cases[{f[a], f[b]}, f[x_] :> x]"
python -m tungsten expr evaluate --code "Cases[{1, -2, 3}, x_ :> x + 1 /; x > 0]"
python -m tungsten expr evaluate --code "DeleteCases[f[a, g[a]], a, Infinity]"
python -m tungsten expr evaluate --code "Replace[f[g[a]], x_ :> p[x], {0, Infinity}]"
python -m tungsten expr evaluate --code "Replace[1, {x_ :> x + 1 /; x < 0, x_ :> x + 2}]"
python -m tungsten expr evaluate --code "If[1 < 2, 1 + 2, 9]"
python -m tungsten expr evaluate --code "Which[False, a, True, 1 + 2]"
python -m tungsten expr evaluate --code "Switch[a, _Integer, 1, _Symbol, 2]"
python -m tungsten expr evaluate --code "Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"
python -m tungsten expr evaluate --code "Pick[f[a, b, c, d], {False, True, False, True}]"
python -m tungsten expr evaluate --code "Select[f[1, a, 2, 3], IntegerQ]"
python -m tungsten expr evaluate --code "Select[{1, a, 2, 3}, # > 1 & -> {\"Element\", \"Index\"}]"
python -m tungsten expr evaluate --code "Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"
python -m tungsten expr evaluate --code "SelectFirst[{1, a, 2, 3}, # > 1 &]"
python -m tungsten expr evaluate --code "TakeWhile[f[2, 4, 6, 7, 8], EvenQ]"
python -m tungsten expr evaluate --code "Mod[-14, 5]"
python -m tungsten expr evaluate --code "Clip[-7, {-5, 5}, {100, 200}]"
python -m tungsten expr evaluate --code "KroneckerDelta[3, 3, 3]"
python -m tungsten expr evaluate --code "f[g[a]] /. g[x_] :> x"
python -m tungsten expr evaluate --code "f[a] //. f[x_] :> x"
python -m tungsten expr evaluate --code "Map[# + 1 &, {a, b}]"
python -m tungsten expr evaluate --code "ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}]"
python -m tungsten expr evaluate --code "ReplacePart[f[a, b, c], 2 -> x]"
python -m tungsten expr evaluate --code "MapAt[g, f[a, h[b, c], d], {2, 1}]"
```

The implemented inert evaluator currently covers:

- `Length`
- `Depth`
- `Head`
- integer arithmetic via `Plus`, `Times`, and `Power` when all arguments in the evaluated
  subexpression are explicit integers
- integer relational heads such as `Equal`, `Unequal`, `Less`, `LessEqual`, `Greater`, and
  `GreaterEqual` under the same explicit-integer rule
- simple predicate heads such as `IntegerQ`, `StringQ`, `EvenQ`, `OddQ`, and `TrueQ`
- hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`
- integer-only numeric heads such as `UnitStep`, `Unitize`, `Sign`, `Abs`, `RealSign`,
  `RealAbs`, `Mod`, `Quotient`, `QuotientRemainder`, `Min`, `Max`, `Clip`, `KroneckerDelta`,
  `DiscreteDelta`, and `Ramp`
- Boolean heads `Not`, `And`, and `Or` when all arguments in the evaluated subexpression are
  explicit `True`/`False`
- `MatchQ`
- `FreeQ`
- `Cases`
- `DeleteCases`
- `Replace`
- `ReplaceAll`
- `ReplaceRepeated`
- positional pure-function applications via `Function[body]` or `body &`
- `Pick`
- `First`
- `Last`
- `Rest`
- `Most`
- `Select`
- `Discard`
- `SelectFirst`
- `TakeWhile`
- `Part`
- `Extract`
- `Level`
- `Take`
- `Drop`
- `Append`
- `Prepend`
- `Join`
- `Reverse`
- `RotateLeft`
- `RotateRight`
- `Flatten`
- `Delete`
- `ReplaceAt`
- `ReplacePart`
- `Apply`
- `Map`
- `MapAt`

For the exact supported forms and limits of each function, see
[expression-function-support.md](./expression-function-support.md).

Everything else remains inert.

The current pattern subset includes `_`, `_Head`, anonymous `__`, `___`, head-qualified anonymous
sequence forms such as `__Integer`, named `x_`, `x_Head`, guarded patterns via `/;`,
`Alternatives` via `|`, `Except`, `HoldPattern`, and `Verbatim`. The parser also lowers
`expr /. rules` and `expr //. rules` to `ReplaceAll[expr, rules]` and `ReplaceRepeated[expr, rules]`.
Anonymous `__` and `___` match a single candidate expression directly, and they also support
multi-element matching when there is at most one such pattern in a containing argument list.
Guards via `/;` are supported in patterns and delayed-rule right-hand sides when the substituted
guard reduces to explicit `True` under Tungsten's shipped evaluator. Named sequence patterns, `?`,
and options-related pattern forms remain intentionally out of scope.

Pure functions currently support positional slots only: `#`, `#n`, `#0`, `Slot[]`, `Slot[n]`,
`Function[body]`, `body &`, and the Tungsten-specific shorthand `#name` for `#1["name"]`.
`SlotSequence` and `##` are not implemented yet.
Tungsten also keeps `Function[body]` inert until application, which lets pure functions safely
contain patterns such as `MatchQ[#, _Integer] &`.

Arithmetic, relational, and Boolean heads are also intentionally narrow in this pass: Tungsten
does not flatten or reorder `Plus`, `Times`, `And`, `Or`, or the relational heads, and it does
not apply short-circuit behavior. Operator forms still parse to those named heads, so nested
operator syntax can partially simplify one binary layer at a time.

The new selection family follows the same explicit-`True` rule as Wolfram's own docs: `Select`,
`Discard`, `SelectFirst`, and `TakeWhile` treat their criterion as a callable predicate, not as a
pattern shorthand. Use a pure function such as `MatchQ[#, _Integer] &` when you want
pattern-based selection. `Select`, `Discard`, and `SelectFirst` currently support the
`"Element"` and `"Index"` property forms, plus lists composed from those two properties.

The newer conditional heads are also deliberately narrow and structural: `If`, `Which`, `Switch`,
and `Piecewise` honor the main branch-selection behavior from the Wolfram Language, but Tungsten
does not attempt to emulate every procedural side effect or message path. `Pick` currently
supports selector expressions with compatible structural shapes and is strongest on the ordinary
list/head-preserving and association-by-position cases.

On structural evaluation failure, `expr evaluate` still writes structured JSON to stdout and
returns exit code `1` with:

- `success: false`
- `error_type: "WolframEvaluationError"`
- `error`
- `parsed_input_form`
- `parsed_full_form`
- `parsed_tree`

### `docs`

Purpose:

- build, search, read, and open the local Wolfram documentation index.

#### `docs index`

Build or rebuild the local documentation index.

```powershell
python -m tungsten docs index
python -m tungsten docs index --path C:\Temp\tungsten-docs.sqlite3
```

#### `docs search`

Search the index.

Options:

- positional query
- `--limit <n>`: defaults to `10`
- `--index-path <path>`: optional
- `--rebuild`: force index rebuild before search

Examples:

```powershell
python -m tungsten docs search NotebookGet
python -m tungsten docs search NotebookImport --limit 5
```

#### `docs read`

Read a documentation page by title, paclet identifier, or path.

```powershell
python -m tungsten docs read NotebookGet
python -m tungsten docs read paclet:ref/NotebookGet
```

#### `docs open`

Open a documentation page in the FrontEnd.

```powershell
python -m tungsten docs open paclet:ref/NotebookGet
```

### `frontend`

Purpose:

- run a small set of FrontEnd-oriented actions through the kernel runner.

#### `frontend probe`

```powershell
python -m tungsten frontend probe
```

#### `frontend open-notebook`

```powershell
python -m tungsten frontend open-notebook --file C:\Temp\new.nb
```

#### `frontend open-doc`

```powershell
python -m tungsten frontend open-doc paclet:ref/NotebookGet
```

#### `frontend run`

```powershell
python -m tungsten frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
python -m tungsten frontend run --code "SomeCode[]" --no-wrap
```

#### `frontend token`

```powershell
python -m tungsten frontend token OpenCloseGroup --file C:\Temp\new.nb
```

Common FE options:

- `--require-success` on probe/open/run/token variants
- `--no-wrap` on `frontend run`

### `assistant`

Purpose:

- drive the built-in Notebook Assistant against a selected source cell.

#### Shared selector options

These selector forms are mutually exclusive and are reused across assistant commands:

- `--cell-index <n>`
- `--cell-path <json-or-comma-separated-int-list>`
- `--expression-uuid <uuid>`
- `--cell-id <int>`
- `--cell-tag <tag>`

#### `assistant ask-cell`

Recommended assistant workflow.

Options:

- `--file <path>`: required
- one selector option: required
- `--question <text>`: required
- `--insert-wolfram-code-below`
- `--insert-all-wolfram-code-below`
- `--save`
- `--close-assistant-notebook`
- `--extra-instructions <text>`
- `--model-service <name>`
- `--model-name <name>`
- `--require-success`

Examples:

```powershell
python -m tungsten assistant ask-cell `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --question "Explain this cell."

python -m tungsten assistant ask-cell `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --question "Reply only with Wolfram Language code that computes 2+2." `
    --insert-wolfram-code-below `
    --save
```

Important output fields:

- `assistant_success`
- `assistant.response_text`
- `assistant.code_blocks`
- `assistant.wolfram_code_blocks`
- `assistant.inserted`
- `assistant.saved_notebook`

#### `assistant prepare-inline`

Experimental visible inline-assistant setup helper.

```powershell
python -m tungsten assistant prepare-inline --file C:\Temp\new.nb --cell-index 1
```

#### `assistant capture-inline`

Experimental visible inline-assistant capture helper.

```powershell
python -m tungsten assistant capture-inline `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --insert-wolfram-code-below `
    --save
```

For real automation, prefer `assistant ask-cell`.

## PowerShell module

Import the module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
```

### Environment and kernel

```powershell
Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
Invoke-TungstenKernel -File C:\path\to\script.wl -FrontEnd
```

### Notebook operations

```powershell
Get-TungstenNotebook -Path C:\Temp\demo.nb
New-TungstenNotebook -Path C:\Temp\demo.nb -Title "Demo" -Cell "Text:Hello" -Cell "Input:2+2"
Set-TungstenNotebook -Path C:\Temp\demo.nb -Spec C:\Temp\patch.json
```

### Expression parsing and inert evaluation

```powershell
Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
```

### Inline-box strings

```powershell
New-TungstenInlineBoxString -Prefix "icon: " -BoxExpression "GraphicsBox[{CircleBox[]}]"
Get-TungstenNotebookCellInlineBoxes -Path C:\Temp\demo.nb -ExpressionUuid "uuid-inline-box" -Prefix "icon: "
```

### Documentation and FrontEnd

```powershell
Find-TungstenDocumentation -Query "NotebookImport"
Get-TungstenDocumentationPage -Identifier "paclet:ref/NotebookGet"
Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet"
Open-TungstenNotebook -Path C:\Temp\demo.nb
Invoke-TungstenFrontEnd -Code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
```

### Notebook Assistant

```powershell
Invoke-TungstenNotebookAssistant -Path C:\Temp\demo.nb -CellIndex 1 -Question "Explain this cell."
Invoke-TungstenNotebookAssistant `
    -Path C:\Temp\demo.nb `
    -CellIndex 1 `
    -Question "Reply only with Wolfram Language code that computes 2+2." `
    -InsertWolframCodeBelow `
    -Save
```

Important assistant parameters:

- selector parameters: `-CellIndex`, `-CellPath`, `-ExpressionUuid`, `-CellId`, `-CellTag`
- insertion controls: `-InsertWolframCodeBelow`, `-InsertAllWolframCodeBelow`
- persistence: `-Save`
- backend: `-Backend NotebookChatCell|DesktopInline|KernelWindow`

`NotebookChatCell` is the recommended default backend.

## Smoke test entrypoint

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
```

The smoke now covers:

- environment probing;
- kernel execution;
- inline-box string composition and notebook-cell extraction;
- expression parsing/evaluation;
- documentation search;
- notebook creation/inspection;
- optional assistant integration;
- optional FrontEnd integration;
- optional WinDesk-assisted capture.
