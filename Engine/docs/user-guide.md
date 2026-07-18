# Tungsten User Guide

- Status: Informational and operational (current usage manual, tutorial, and scripting guide)
- Audience: Users running Tungsten locally, maintainers validating it, and script authors building automation on top of it
- Scope: Building, running, and troubleshooting Tungsten's native CLI and PowerShell surfaces
- Created (UTC): 2026-04-23T15:36:45Z
- Updated (UTC): 2026-07-18T04:31:20Z
- Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7
- Related code:
  - `Engine/cpp/`
  - `Engine/pwsh/Tungsten.psm1`
- Related docs:
  - [Project README](../README.md)
  - [Usage Reference](./usage-reference.md)
  - [Inline Box Strings](./inline-box-strings.md)
  - [Notebook Assistant](./notebook-assistant.md)
  - [Expression Parser](./expression-parser.md)
  - [Troubleshooting](./troubleshooting.md)

## Summary

This guide is the practical "how do I actually use Tungsten?" companion to the architecture
documents. It focuses on real workflows:

- verifying that Tungsten can see the local Wolfram installation;
- evaluating Wolfram Language code through the real kernel;
- working with notebooks without needing the kernel;
- constructing string literals that embed notebook objects through inline box escapes;
- searching and reading the local documentation corpus;
- driving selected FrontEnd actions;
- automating the built-in Notebook Assistant;
- parsing and structurally evaluating Wolfram expressions without a kernel;
- scripting everything from PowerShell.

## What Tungsten is good for

Tungsten is most useful when you want one of these behaviors:

- run small or medium Wolfram Language snippets from automation and get structured results back;
- inspect or patch `*.nb` files in bulk;
- build Wolfram string literals that embed images or other notebook objects through inline box
  escapes;
- build PowerShell workflows that need Wolfram Language without living entirely inside Mathematica;
- search the exact locally installed documentation set instead of relying on web search;
- mix kernel-backed and kernel-free workflows in the same toolchain;
- automate Notebook Assistant from a script instead of manually clicking around the FrontEnd.

It is less appropriate when you need:

- full Mathematica GUI authoring;
- arbitrary FrontEnd UI automation beyond the small subset Tungsten intentionally exposes;
- full Wolfram evaluation semantics without the real kernel;
- full StandardForm or box-language parsing.

## Prerequisites

### To use kernel-backed Tungsten features

- A local Wolfram installation discoverable by Tungsten. On this machine Tungsten defaults to
  paid Wolfram 15.0 and can opt into Wolfram Engine 14.3 with `TUNGSTEN_WOLFRAM_PRODUCT=engine`.
- A usable `wolfram.exe` CLI.
- A usable `mathpass` path. Tungsten handles the duplicate-entry machine quirk automatically, but it
  still needs a discoverable source file.

### To use PowerShell wrappers

- PowerShell 7.4+.
- CMake 3.20+, a C++17 compiler, and discoverable ABI-compatible GMP/GMPXX development libraries
  to build the native engine.
- A built `tungsten-cpp` executable in `Engine/build/cpp`, a `Release`/`Debug` multi-config
  subdirectory, or on `PATH`. `TUNGSTEN_EXECUTABLE` can select an exact path.

### To use experimental visible inline assistant automation

- Everything above.
- A visible desktop session.
- WinDesk available and importable. WinDesk is not part of this repository — it lives in the sibling [`Tools`](https://github.com/VladimirReshetnikov/Tools) repository. Build `WinDesk.PowerShell` there, then either pre-import the module in your session or set `$env:TUNGSTEN_WINDESK_MODULE_PATH` to the built `WinDesk.PowerShell.dll`.
- Willingness to let Tungsten activate the notebook window.

## Environment setup

### Native CLI setup

From the repository root:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
Pop-Location
```

### PowerShell module setup

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
```

The module is intentionally thin. It resolves `tungsten-cpp`, calls it directly,
deserializes the JSON response, and returns PowerShell objects.

## Tutorial

### Tutorial 1: Verify the environment and the machine-local Wolfram installation

Native CLI:

```powershell
.\Engine\build\cpp\tungsten-cpp.exe env show --probe
```

For a Visual Studio multi-configuration build, use
`.\Engine\build\cpp\Release\tungsten-cpp.exe` instead.

PowerShell:

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
Get-TungstenEnvironment -Probe
```

What to look for:

- `install_dir`, `kernel_cli`, `frontend_executable`, and `mathpass` should resolve correctly.
- `docs_roots` should contain the local documentation roots Tungsten will index.
- The probe payload should show both a normal evaluation result and a FrontEnd probe result.

If this step fails, jump to [Troubleshooting](./troubleshooting.md) before going further.

### Tutorial 2: Evaluate Wolfram Language code through the real kernel

Native CLI:

```powershell
tungsten-cpp kernel eval --code "2+2"
tungsten-cpp kernel eval --code "Print[Prime[10]]; Prime[20]"
```

PowerShell:

```powershell
Invoke-TungstenKernel -Code "2+2"
Invoke-TungstenKernel -Code "Print[Prime[10]]; Prime[20]"
```

Important behavior:

- `result` and `result_head` are stringified `InputForm` representations.
- `messages`, `messages_text`, and captured `Print` output are returned explicitly.
- Tungsten does not try to coerce arbitrary Wolfram objects into C++ or PowerShell-native data
  structures.

### Tutorial 3: Create, inspect, and patch a notebook without the kernel

Create a notebook:

```powershell
tungsten-cpp notebook create `
    --file $env:TEMP\tungsten-demo.nb `
    --title "Demo Notebook" `
    --cell "Title:Demo Notebook" `
    --cell "Text:Hello from Tungsten" `
    --cell "Input:2+2"
```

Inspect it:

```powershell
tungsten-cpp notebook inspect --file $env:TEMP\tungsten-demo.nb
```

PowerShell equivalent:

```powershell
$nb = Join-Path $env:TEMP "tungsten-demo.nb"
New-TungstenNotebook -Path $nb -Title "Demo Notebook" -Cell @(
    "Title:Demo Notebook",
    "Text:Hello from Tungsten",
    "Input:2+2"
)

Get-TungstenNotebook -Path $nb
```

Why this matters:

- `notebook inspect` gives you a stable flattened cell list with `index`, `path`, `style`,
  `preview`, `expression_uuid`, `cell_id`, and `cell_tags`.
- Those selectors feed directly into Notebook Assistant automation later.

Apply a patch:

```powershell
$spec = Join-Path $env:TEMP "tungsten-patch.json"
@'
{
  "operations": [
    {
      "op": "append_cell",
      "style": "Text",
      "text": "Tail cell"
    },
    {
      "op": "set_option",
      "name": "WindowTitle",
      "value_expr": "\"Patched Notebook\""
    }
  ]
}
'@ | Set-Content -Path $spec -Encoding UTF8

tungsten-cpp notebook patch --file $env:TEMP\tungsten-demo.nb --spec $spec
```

### Tutorial 4: Build inline-box string literals from notebook cells

Create a small notebook containing a box-bearing output cell:

```powershell
$inlineBoxNotebook = Join-Path $env:TEMP "tungsten-inline-box-demo.nb"
@'
Notebook[{
Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-inline-box"]
}]
'@ | Set-Content -Path $inlineBoxNotebook -Encoding UTF8
```

Extract the object from the selected cell and compose a ready-to-use string literal:

```powershell
tungsten-cpp inline-box from-cell `
    --file $inlineBoxNotebook `
    --expression-uuid uuid-inline-box `
    --prefix "icon: "
```

PowerShell equivalent:

```powershell
Get-TungstenNotebookCellInlineBoxes `
    -Path $inlineBoxNotebook `
    -ExpressionUuid "uuid-inline-box" `
    -Prefix "icon: "
```

What to look for:

- `selected_boxes[0].box_expression` contains the extracted box form such as
  `GraphicsBox[{CircleBox[]}]`.
- `string_value` contains the decoded Wolfram string content with `\!\(\*...\)` embedded.
- `string_literal` contains the canonical Wolfram string literal text with doubled backslashes as it
  would appear in `InputForm`.

If you already have box expressions and only need composition, use:

```powershell
New-TungstenInlineBoxString `
    -Prefix "icon: " `
    -BoxExpression "GraphicsBox[{CircleBox[]}]"
```

For fuller details, see [Inline Box Strings](./inline-box-strings.md).

### Tutorial 5: Search and read the local documentation corpus

Search:

```powershell
tungsten-cpp docs search NotebookGet
tungsten-cpp docs search NotebookImport --limit 5
```

Read a page:

```powershell
tungsten-cpp docs read paclet:ref/NotebookGet
tungsten-cpp docs read NotebookGet
```

Open a page in the FrontEnd:

```powershell
tungsten-cpp docs open paclet:ref/NotebookGet
```

PowerShell equivalents:

```powershell
Find-TungstenDocumentation -Query "NotebookGet"
Get-TungstenDocumentationPage -Identifier "paclet:ref/NotebookGet"
Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet"
```

Key point:

- Tungsten indexes the locally installed documentation notebooks, not a remote web corpus. Search
  results stay aligned with the exact installed machine state.

### Tutorial 6: Drive selected FrontEnd actions

Probe FrontEnd availability:

```powershell
tungsten-cpp frontend probe
```

Open a notebook:

```powershell
tungsten-cpp frontend open-notebook --file $env:TEMP\tungsten-demo.nb
```

Run FE-targeted code:

```powershell
tungsten-cpp frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
```

Execute a token:

```powershell
tungsten-cpp frontend token OpenCloseGroup --file $env:TEMP\tungsten-demo.nb
```

PowerShell equivalents:

```powershell
Open-TungstenNotebook -Path $nb
Invoke-TungstenFrontEnd -Code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
```

### Tutorial 7: Ask Notebook Assistant about a specific cell and insert generated code below it

Inspect the notebook and pick a target cell:

```powershell
$notebook = Get-TungstenNotebook -Path $nb
$target = $notebook.cells | Where-Object { $_.style -eq "Input" } | Select-Object -First 1
```

Ask the built-in assistant about that cell:

```powershell
$result = Invoke-TungstenNotebookAssistant `
    -Path $nb `
    -CellIndex $target.index `
    -Question "Reply only with Wolfram Language code that computes 2+2." `
    -InsertWolframCodeBelow `
    -Save
```

What happens on the default backend:

1. Tungsten reads the selected source cell.
2. Tungsten creates a temporary hidden Chatbook notebook.
3. Tungsten asks the built-in Notebook Assistant stack about the source cell.
4. Tungsten extracts assistant text and code blocks from the returned `ChatObject`.
5. If requested, Tungsten inserts Wolfram Language code cells below the original source cell.

This is the recommended path. The visible inline UI backend exists, but it is not the default.

For full assistant details, see [Notebook Assistant](./notebook-assistant.md).

### Tutorial 8: Parse and structurally evaluate Wolfram expressions without the kernel

Parse:

```powershell
tungsten-cpp expr parse --code "1 + 2 x^3"
tungsten-cpp expr parse --code "Rule[x, List[1, 2]]" --form fullform
```

Evaluate built-ins inertly:

```powershell
tungsten-cpp expr evaluate --code "Length[{a, b, c}]"
tungsten-cpp expr evaluate --code "Level[f[a, g[b]], -1]"
tungsten-cpp expr evaluate --code "Part[f[a, b, c], {1, 3}]"
```

PowerShell:

```powershell
Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
```

Important boundary:

- This is not full kernel evaluation.
- Unknown heads remain inert.
- The subsystem is for structure, traversal, canonical formatting, and a small explicitly supported
  built-in set.

For the precise syntax/evaluation boundary, see [Expression Parser](./expression-parser.md).

## PowerShell scripting patterns

### Pattern 1: Treat Tungsten as a JSON-first tool with thin wrappers

This is the default design philosophy. The PowerShell functions are mostly just ergonomic names over
the native CLI.

Example:

```powershell
$result = Invoke-TungstenKernel -Code "Print[Prime[10]]; Prime[20]"
if (-not $result.evaluation_available) {
    throw "Kernel evaluation did not produce a structured payload."
}

$result.result
$result.output
```

### Pattern 2: Use notebook inspection to drive later notebook actions

```powershell
$cells = (Get-TungstenNotebook -Path $nb).cells
$target = $cells | Where-Object { $_.preview -like "*Plot*" } | Select-Object -First 1

Invoke-TungstenNotebookAssistant `
    -Path $nb `
    -CellIndex $target.index `
    -Question "Reply only with Wolfram Language code that improves this plot." `
    -InsertWolframCodeBelow `
    -Save
```

### Pattern 3: Mix kernel-free and kernel-backed workflows

Example:

1. Parse notebook files structurally without the kernel.
2. Use the expression parser to inspect extracted Wolfram fragments.
3. Use the real kernel only for the subset of operations that genuinely need it.

That split is one of Tungsten's main design advantages.

## Data locations and important paths

Tungsten discovers and/or uses these important path categories:

- Wolfram installation root, usually under `C:\Program Files\Wolfram Research\Wolfram\<version>`
- shared documentation root under `C:\Program Files\Common Files\Wolfram Research\Documentation.en-us\...`
- user-installed `SystemDocsUpdate*` paclets under `%APPDATA%\Wolfram\Paclets\Repository`
- machine `mathpass` under `%ProgramData%\Wolfram\Licensing\mathpass`
- default docs index under `%LOCALAPPDATA%\Tungsten\docs\wolfram-<version>.sqlite3`

You can inspect the discovered values with:

```powershell
tungsten-cpp env show
```

## Choosing the right Tungsten surface

Use `kernel eval` / `Invoke-TungstenKernel` when:

- you need real Wolfram semantics;
- you do not need notebook mutation specifically;
- you want timing, messages, and captured output.

Use `notebook inspect/create/patch` when:

- you want purely file-based notebook work;
- you do not need a running kernel;
- you are bulk-editing or analyzing notebooks.

Use `docs search/read/open` when:

- you want the locally installed documentation corpus;
- you want offline or version-aligned documentation lookup.

Use `frontend` commands when:

- you specifically need a small set of FE operations;
- you are comfortable depending on a running FrontEnd.

Use `assistant ask-cell` / `Invoke-TungstenNotebookAssistant` when:

- the workflow conceptually starts from "this notebook cell";
- you want the built-in assistant involved;
- any generated code should be inserted back into the notebook in a controlled way.

Use `expr parse` / `expr evaluate` when:

- you need structural Wolfram-expression tooling without a kernel;
- you need canonical forms, traversal, or part extraction;
- full kernel semantics are not required.

## Validation and smoke testing

Run the native Tungsten and .NET test suites:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
ctest --test-dir build/cpp -C Release --output-on-failure
dotnet test .\dotnet\Tungsten.DotNet.slnx
Pop-Location
```

Run the development-only Python reference-oracle suite and parity tools:

```powershell
Push-Location .\Engine
try {
    uv run python -m unittest discover -s tests -t .
    uv run python scripts/check_cpp_parser_parity.py
    uv run python scripts/check_cpp_evaluator_parity.py --tests tests
    uv run python scripts/check_cpp_stateful_evaluator_parity.py --require-perfect
    uv run python scripts/check_cpp_recorded_evaluator_parity.py --workers 8 --require-perfect
    uv run python scripts/check_cpp_cli_parity.py
}
finally {
    Pop-Location
}
```

The parser differential is exact over 1,414 literals, the stateful evaluator gate is 82/82, the
recorded evaluator gate is 2,499/2,499 calls across 585 tests, and the CLI differential is 119/119.
The static evaluator extractor loses setup state and is diagnostic; the recorded evaluator harness
with `--require-perfect` is the authoritative broad comparison. See
[C++ Runtime and Verification](./cpp-port.md).

Run a repository-local PowerShell smoke against the C++ executable:

```powershell
$env:TUNGSTEN_EXECUTABLE = (Resolve-Path .\Engine\build\cpp\tungsten-cpp.exe)
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
Invoke-TungstenExpression -Code "ReplacePart[f[a, b, c], 2 -> x]"
```

Use the `Release` subdirectory for a multi-configuration build. Live Wolfram, FrontEnd, assistant,
and WinDesk workflows require the corresponding Windows environment and are separate from the
kernel-free CTest/parity gates.

The current portability record does not include a live MSVC/Visual Studio or macOS build. The
documented paths are supported design targets, but validate them locally before distributing a
platform-specific binary.

## Where to go next

- Read [Usage Reference](./usage-reference.md) for the full command surface.
- Read [Troubleshooting](./troubleshooting.md) when the local environment behaves differently from the
  happy path.
- Read [Architecture](./architecture.md) if you want to change Tungsten itself.
