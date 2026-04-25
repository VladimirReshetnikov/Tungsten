# Tungsten

- Status: Informational (current-state project guide and maintainer-facing landing page)
- Audience: Tungsten users, script authors, maintainers, reviewers, and contributors onboarding into `src/Tungsten`
- Scope: `src/Tungsten`
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-04-25T17:48:49Z
- Repository HEAD: 7312c7acbea3192296e6e3f8ff6f4ff36f1529f1
- Related code:
  - `src/Tungsten/src/tungsten/`
  - `src/Tungsten/pwsh/`
  - `src/Tungsten/dotnet/`
  - `src/Tungsten/tests/`
  - `src/Tungsten/scripts/`
- Related docs:
  - [Documentation Index](./docs/README.md)
  - [User Guide](./docs/user-guide.md)
  - [Usage Reference](./docs/usage-reference.md)
  - [C#/.NET API](./docs/dotnet-api.md)
  - [Architecture](./docs/architecture.md)
  - [Symbol and Context Registry](./docs/symbol-context-registry.md)
  - [Parser Corpus](./docs/parser-corpus.md)
  - [Inline Box Strings](./docs/inline-box-strings.md)
  - [Troubleshooting](./docs/troubleshooting.md)

## Summary

Tungsten is a Python-first automation workspace for a local Wolfram installation, with thin
PowerShell and .NET projection layers for script and application callers. It exists for the
workflows that are awkward in the traditional Mathematica GUI but natural for agents, scripts, and
typed host applications:

- evaluate Wolfram Language code and get structured JSON back instead of scraping stdout;
- inspect, create, and patch notebook files without needing a running kernel;
- search and read the locally installed documentation corpus offline;
- drive selected FrontEnd actions programmatically;
- ask the built-in Notebook Assistant about a specific source cell and optionally insert generated
  Wolfram Language code back into the notebook;
- parse and structurally analyze Wolfram expressions without access to a kernel.

Tungsten is deliberately not trying to be a full alternative Wolfram runtime. It is an automation
layer over the real local installation, plus a small amount of kernel-free structural tooling where
that meaningfully improves agent workflows.

## Project goals

Tungsten exists to satisfy a small set of load-bearing goals:

- Make local Wolfram automation practical from `pwsh`, Python, and JSON-first tooling.
- Make the same workflows pleasant to call from C#/.NET without forcing callers to hand-roll
  process execution or JSON deserialization.
- Preserve machine readability. The primary outputs should be structured data, not terminal-only
  text.
- Keep as much functionality local and offline as possible so results stay aligned with the actual
  machine-local Wolfram installation and documentation version.
- Treat environment quirks, especially licensing quirks, as first-class engineering constraints
  instead of hidden one-off hacks.
- Offer a useful fallback layer when the kernel or FrontEnd is unavailable, especially for notebook
  and expression inspection/manipulation.
- Be pleasant to compose from PowerShell scripts without forcing callers to write large amounts of
  boilerplate.

## Non-goals

Tungsten is intentionally not trying to do several things:

- It is not a full Wolfram kernel reimplementation.
- Today it does not attempt full box-language parsing or full StandardForm rendering.
- It does not try to expose the entire FrontEnd API surface.
- It does not depend on browser automation or online-only documentation scraping.
- It does not replace interactive GUI workflows when those are genuinely the most natural way to do
  the work.

## Longer-term expression direction

The shipped expression subsystem is intentionally narrower than the long-term target. Over time, the
kernel-free Tungsten expression stack is intended to:

- successfully parse all Wolfram Language syntax, including all built-in box forms;
- evaluate structural expression manipulation;
- evaluate pure functions;
- evaluate functional and iterative programming helpers;
- evaluate scoping and control-flow constructs;
- perform exact integer arithmetic;
- perform floating-point arithmetic;
- handle array, matrix, and tensor manipulation, including sparse forms;
- support some basic integer arithmetic functions such as `GCD` and `Divisors`.

Even in that broader future direction, Tungsten is not intended to implement:

- real- or complex-valued elementary or special mathematical functions;
- expression simplification algorithms;
- equation solving;
- polynomial algebra;
- derivatives or integrals;
- optimization problems;
- anything that requires specialized mathematical algorithms.

## Current feature map

The current workspace is built around seven complementary capabilities:

1. A kernel runner that executes Wolfram Language code through `wolfram.exe` and returns structured
   JSON instead of terminal-only output.
2. A notebook parser/editor that can inspect and patch `*.nb` files without requiring a live
   kernel or FrontEnd.
3. A kernel-free inline-box string subsystem that can preserve embedded `\!\(\*...\)` escapes,
   extract box-bearing objects from saved notebook cells, and compose ready-to-use Wolfram string
   literals for images and other notebook objects.
4. A kernel-free Wolfram expression subsystem that parses FullForm, InputForm, and a pragmatic
   StandardForm subset, including common semantic box forms such as `FractionBox`, `SqrtBox`,
   `RadicalBox`, `SuperscriptBox`, `SubscriptBox`, and related script boxes, understands
   named-character operators such as `\[CirclePlus]` as inert structural heads, understands
   association literals and common association
   row-box forms from the installed documentation notebooks, understands a bounded but useful
   pattern subset such as `_Integer`, anonymous `__` / `___`, guarded patterns via `/;`, `x_`,
   `Except[...]`, and `a | b`, parses replacement operators such as `/.` and `//.` into named AST
   calls, supports positional pure functions such as `Function[body]`, `body &`, `#`, `#n`, and
   `#0`, supports named pure functions such as `Function[x, body]`, `x |-> body`, and
   `x \[Function] body` with capture-avoiding parameter renaming, then evaluates a broader inert
   structural built-in set such as hold-like conditionals (`If`, `Which`, `Switch`, `Piecewise`),
   integer arithmetic and relational heads, simple predicates such as `IntegerQ`, `StringQ`, and
   `EvenQ`, integer-only numeric heads such as `UnitStep`, `Mod`, `Min`, `Clip`, and
   `KroneckerDelta`, Boolean heads, `Length`, `Depth`, `MatchQ`, `Cases`, `DeleteCases`,
   `Replace`, `ReplaceAll`, `ReplaceRepeated`, functional combinators such as `Composition`,
   `Nest`, `FixedPoint`, `Fold`, and `SameAs`, traversal and threading heads such as `MapApply`,
   `MapAll`, `MapIndexed`, `Thread`, `Outer`, `Inner`, and `Dot`, array and sequence builders
   such as `Array`, `Range`, `Partition`, and `BlockMap`, search and de-duplication heads such as
   `FirstCase`, `Position`, and `DeleteDuplicates`, byte and character heads such as `ByteArray`,
   `BaseEncode`, `BaseDecode`, `StringLength`, `StringTake`, `StringDrop`, `StringJoin`,
   `StringInsert`, `StringReverse`, string-pattern heads such as `StringMatchQ`, `StringFreeQ`,
   `StringStartsQ`, `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, and
   `StringReplace`, `ToCharacterCode`, `StringToByteArray`, `ImportString`, `ExportString`,
   `ImportByteArray`, `ExportByteArray`, `ToString`, `ToExpression`, `ToBoxes`, `MakeBoxes`,
   `MakeExpression`, `StripBoxes`, `SyntaxQ`, and `SyntaxLength`, plus `Pick`, `Select`, `Discard`, `SelectFirst`,
   `TakeWhile`, `Take`, `Drop`, `Flatten`, `ReplaceAt`, `ReplacePart`, `MapAt`, `Association`,
   `Lookup`, `KeyTake`, and symbol/context registry heads such as `Symbol`, `SymbolName`,
   `Unique`, `Names`, `NameQ`, `Contexts`, `Context`, `$Context`, `$ContextPath`, and `ValueQ`.
5. An offline documentation index over the locally installed documentation notebooks.
6. A FrontEnd controller that can open notebooks, open documentation pages, and execute selected
   FrontEnd operations through kernel-side `UsingFrontEnd[...]` calls.
7. A Notebook Assistant controller that can ask the built-in assistant about a selected source cell
   and optionally insert Wolfram Language code below that cell.

## Current status

### Shipped now

- Environment discovery for the local Wolfram installation, documentation roots, bundled Python
  client tree, and default index path.
- Automatic `mathpass` deduplication plus launch-gate / process-scan handling before kernel execution.
- Structured kernel evaluation with timing, messages, printed output capture, and explicit success
  metadata.
- Structural notebook inspection, notebook creation, and JSON patch application.
- Kernel-free inline-box string composition plus extraction of box-bearing objects from saved
  notebook cells.
- Offline documentation indexing and search over the installed `*.nb` documentation corpus.
- FrontEnd probing, notebook open, documentation open, token execution, and arbitrary FE-targeted
  code execution.
- Built-in Notebook Assistant automation through the stable hidden chat-notebook backend, with the
  visible inline-desktop path retained as an experimental option.
- Kernel-free Wolfram expression parsing and inert structural evaluation.
- PowerShell wrappers for all major Tungsten surfaces.
- A typed .NET client wrapper over the JSON CLI for C# callers.

### Deliberately narrow or experimental

- The visible inline Notebook Assistant desktop-driving backend remains experimental. It depends on
  a visible foreground notebook window and, in practice, on WinDesk-backed automation.
- The expression subsystem intentionally covers only a pragmatic StandardForm subset, a limited
  semantic box subset, and a small built-in evaluation surface.
- FrontEnd automation is intentionally selective rather than exhaustive.

## Tech stack and operating assumptions

| Area | Current choice |
|------|----------------|
| Runtime | Python 3.11+ |
| Package layout | `setuptools` package under `src/tungsten/` |
| Primary execution substrate | `wolfram.exe -script` |
| PowerShell integration | Thin JSON-first wrapper module in `pwsh/Tungsten.psm1` |
| .NET integration | Thin typed wrapper library in `dotnet/Tungsten.DotNet/` |
| Documentation index | SQLite FTS5 |
| Notebook representation | Tungsten-owned structural parser for notebook expressions |
| Expression representation | Tungsten-owned AST and Pratt-style parser |
| Platform expectation | Windows-first local machine with a real Wolfram installation |
| Optional desktop automation helper | WinDesk for visible-window testing and the experimental inline assistant path |

## Architecture at a glance

```text
                  local Wolfram installation
        ┌───────────────────────────────────────────────┐
        │ wolfram.exe / WolframKernel.exe / WolframNB  │
        │ mathpass / local docs notebooks / Chatbook   │
        └───────────────────────────────────────────────┘
                              ▲
                              │
                    discovery.py + licensing.py
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
   kernel.py            notebook.py          expression.py
   docs_index.py        frontend.py          assistant.py
                         inline_boxes.py     wolfram_strings.py
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                           cli.py
                     ┌────────┴────────┐
                     │                 │
                     ▼                 ▼
               Tungsten.psm1   Tungsten.DotNet
                     │                 │
       Python callers / pwsh scripts / .NET apps / agents
```

For the deeper component model and execution flow, see [Architecture](./docs/architecture.md).

## The most important environment fact on this machine

This machine has a real Wolfram 14.3 installation, but the installed `mathpass` contains duplicate
license entries. That matters because the obvious command-line paths can fail if they use the raw
installed file directly.

Tungsten handles that by:

- inspecting the discovered `mathpass`;
- writing a temporary deduplicated copy;
- invoking `wolfram.exe` with `-pwfile <temporary-deduped-copy>`;
- never mutating the installed machine-wide licensing file.

This is not a side detail. It is part of Tungsten's core execution model.

## Quick start

### Python CLI

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)

python -m tungsten env show --probe
python -m tungsten kernel eval --code "2+2"
python -m tungsten notebook create --file $env:TEMP\tungsten-demo.nb --title "Demo" --cell "Text:Hello" --cell "Input:2+2"
python -m tungsten notebook inspect --file $env:TEMP\tungsten-demo.nb
python -m tungsten inline-box compose --prefix "icon: " --box-expr "GraphicsBox[{CircleBox[]}]"
python -m tungsten docs search NotebookGet
python -m tungsten expr evaluate --code "1 + 2 + 3"
python -m tungsten expr evaluate --code '$ContextPath'
python -m tungsten expr evaluate --code '{Symbol["TungstenReadme`alpha"], Names["TungstenReadme`*"]}'
python -m tungsten parser-corpus compare --max-files 25 --max-file-mb 2 --tungsten-workers 8
```

### PowerShell

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force

Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
New-TungstenInlineBoxString -Prefix "icon: " -BoxExpression "GraphicsBox[{CircleBox[]}]"
Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "True && False && x"
Invoke-TungstenExpression -Code '$ContextPath'
Find-TungstenDocumentation -Query "NotebookGet"
Compare-TungstenParserCorpus -MaxFiles 25 -MaxFileMB 2 -TungstenWorkers 8
```

### C#/.NET

```csharp
using Tungsten.DotNet;

var client = TungstenClient.CreateForRepositoryRoot(@"<repository-root>");

var environment = await client.GetEnvironmentAsync(probe: true);
var expression = await client.EvaluateExpressionAsync(
    TungstenInputSource.FromCode("1 + 2 + 3"));

Console.WriteLine(environment.InstallDir);
Console.WriteLine(expression.Result?.FullForm);
```

See [C#/.NET API](./docs/dotnet-api.md) for the full typed surface, assistant/front-end examples,
and failure-model guidance.

### Notebook Assistant end-to-end

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force

$nb = Join-Path $env:TEMP "tungsten-assistant-demo.nb"
New-TungstenNotebook -Path $nb -Title "Assistant Demo" -Cell @(
    "Text:Demo notebook",
    "Input:2+2"
) | Out-Null

$result = Invoke-TungstenNotebookAssistant `
    -Path $nb `
    -CellIndex 1 `
    -Question "Reply only with Wolfram Language code that computes 2+2." `
    -InsertWolframCodeBelow `
    -Save
```

See [User Guide](./docs/user-guide.md) for a fuller tutorial sequence.

### Inline box strings from notebook cells

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

That returns both the extracted `GraphicsBox[...]` expression and a ready-to-use Wolfram string
literal such as `"icon: \\!\\(\\*GraphicsBox[...]\\)"`.

## What Tungsten is good for

Tungsten is especially useful when you want one of these behaviors:

- run Wolfram Language from scripts and receive explicit machine-readable result metadata;
- inspect or bulk-edit notebook files without launching Mathematica;
- construct Wolfram string literals that embed images or other notebook objects through inline box
  escapes;
- automate documentation lookup locally and offline;
- use the real FrontEnd when needed, but drive only a narrow, dependable subset of actions;
- script Notebook Assistant workflows from PowerShell;
- structurally inspect Wolfram expressions even when the kernel is unavailable.

## Known limitations

The current documentation should state these boundaries plainly:

- Tungsten is Windows-first and expects a local Wolfram installation.
- Kernel-backed features still require the real local installation and a working license path.
- The expression parser handles common semantic box forms, but it still does not cover full box
  language or arbitrary StandardForm constructs.
- The expression evaluator implements a pragmatic structural subset, including associations, but it
  still leaves all other heads inert and does not attempt general kernel semantics.
- FrontEnd automation works only for the actions Tungsten explicitly exposes.
- Notebook Assistant inline UI driving is intentionally not the default path because it is less
  reliable for automation than the hidden chat-notebook backend.
- Notebook-cell inline-box extraction currently operates against saved notebook files rather than
  unsaved live FrontEnd state.

## Repository layout

| Path | Purpose |
|------|---------|
| `src/Tungsten/pyproject.toml` | Python package metadata |
| `src/Tungsten/src/tungsten/discovery.py` | Installation, docs-root, and path discovery |
| `src/Tungsten/src/tungsten/licensing.py` | `mathpass` inspection and deduplication helpers |
| `src/Tungsten/src/tungsten/kernel.py` | Structured kernel execution wrapper |
| `src/Tungsten/src/tungsten/notebook.py` | Structural notebook parser, renderer, and patch support |
| `src/Tungsten/src/tungsten/inline_boxes.py` | Inline-box string composition and notebook-cell object extraction |
| `src/Tungsten/src/tungsten/expression.py` | Kernel-free Wolfram expression parser and inert evaluator |
| `src/Tungsten/src/tungsten/parser_corpus.py` | Local parser corpus discovery and Wolfram held-parser comparison |
| `src/Tungsten/src/tungsten/wolfram_strings.py` | Shared Wolfram string literal and inline-box escape handling |
| `src/Tungsten/src/tungsten/docs_index.py` | Offline documentation indexing/search |
| `src/Tungsten/src/tungsten/frontend.py` | Programmatic FrontEnd actions |
| `src/Tungsten/src/tungsten/assistant.py` | Notebook Assistant automation |
| `src/Tungsten/src/tungsten/cli.py` | JSON-first CLI entrypoint |
| `src/Tungsten/pwsh/` | PowerShell wrappers |
| `src/Tungsten/tests/` | Python unit and integration coverage |
| `src/Tungsten/scripts/Test-TungstenSmoke.ps1` | End-to-end smoke runner |
| `src/Tungsten/scripts/Test-TungstenParserCorpus.ps1` | Parser corpus comparison runner |
| `src/Tungsten/docs/` | Documentation set |

## Build and validation

Run the Python tests from the Tungsten workspace:

```powershell
Push-Location .\src\Tungsten
try {
    $env:PYTHONPATH = (Resolve-Path .\src)
    python -m unittest discover -s tests -t .
}
finally {
    Pop-Location
}
```

Run the repository-local smoke:

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
pwsh -File .\src\Tungsten\scripts\Test-TungstenParserCorpus.ps1 -MaxFiles 100 -TungstenWorkers 8
pwsh -File .\src\Tungsten\scripts\Update-TungstenDocsProvenance.ps1
```

## Documentation map

If you are new to Tungsten, this reading order works well:

1. This README for the project map, goals, and current shipped surface.
2. [Documentation Index](./docs/README.md) for the full docs inventory and reading orders by role.
3. [User Guide](./docs/user-guide.md) for practical workflows, tutorials, and scripting examples.
4. [Usage Reference](./docs/usage-reference.md) for the full command surface.
5. [Architecture](./docs/architecture.md) for the detailed component model and execution flow.
6. Focused guides as needed:
   - [Notebook Assistant](./docs/notebook-assistant.md)
   - [Inline Box Strings](./docs/inline-box-strings.md)
   - [Expression Parser](./docs/expression-parser.md)
   - [Troubleshooting](./docs/troubleshooting.md)
   - [Implementation Details](./docs/implementation-details.md)

## Design notes

- Tungsten intentionally uses the documented `wolfram.exe` CLI instead of trying to depend on the
  bundled Wolfram Python client at runtime. The bundled client is present on this machine, but its
  higher-level dependency surface is not the most dependable local runtime substrate here.
- Notebook parsing/editing is kept independent from the kernel so agents can still inspect and
  patch notebooks even when evaluation is unavailable or undesirable.
- The expression subsystem is also kernel-free, but it is explicitly structural and inert rather
  than a general-purpose evaluator.
- Inline-box string handling is also kernel-free for saved notebooks: Tungsten can extract
  box-bearing objects from notebook cell expressions and compose canonical Wolfram string literals
  without launching the kernel or FrontEnd.
- Documentation search is based on the installed documentation notebooks themselves, not on browser
  automation or online-only search.
- The recommended Notebook Assistant path is `assistant ask-cell` /
  `Invoke-TungstenNotebookAssistant` with the default `NotebookChatCell` backend. Tungsten asks the
  built-in assistant through a temporary hidden chat notebook, extracts assistant text from the
  returned `ChatObject`, and only then performs deterministic insertion below the requested source
  cell.
