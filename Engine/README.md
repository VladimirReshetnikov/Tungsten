# Tungsten

- Status: Informational (current-state project guide and maintainer-facing landing page)
- Audience: Tungsten users, script authors, maintainers, reviewers, and contributors onboarding into `Engine`
- Scope: `Engine`
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-07-22T19:25:35Z
- Repository HEAD: b6e36d4fcd683cb312b5bf4000be5da0205356cf
- Related code:
  - `Engine/cpp/`
  - `Engine/src/tungsten/`
  - `Engine/haskell/`
  - `Engine/Nummy/`
  - `Engine/pwsh/`
  - `Engine/dotnet/`
  - `Engine/tests/`
  - `Engine/scripts/`
- Related docs:
  - [Documentation Index](./docs/README.md)
  - [User Guide](./docs/user-guide.md)
  - [Usage Reference](./docs/usage-reference.md)
  - [C#/.NET API](./docs/dotnet-api.md)
  - [Architecture](./docs/architecture.md)
  - [C++ Runtime and Verification](./docs/cpp-port.md)
  - [Haskell Port](./docs/haskell-port.md)
  - [REPL](./docs/repl.md)
  - [Large-Number Fallback Design](./docs/overflow-underflow-large-number-fallback.md)
  - [Symbol and Context Registry](./docs/symbol-context-registry.md)
  - [Parser Corpus](./docs/parser-corpus.md)
  - [Inline Box Strings](./docs/inline-box-strings.md)
  - [Troubleshooting](./docs/troubleshooting.md)

## Summary

Tungsten is a multi-runtime automation and symbolic-computation workspace for a local Wolfram
installation. The Python implementation remains the executable compatibility reference. The C++17
runtime owns that reference's complete dispatch surface, provides an installable native library and
CLI, and is the target of the PowerShell and .NET projections, while the active Haskell port
provides an independent typed expression, parser, evaluator, structural-notebook, CLI, and
JSON-protocol foundation. Tungsten exists for the
workflows that are awkward in the traditional Mathematica GUI but natural for agents, scripts, and
typed host applications:

- evaluate Wolfram Language code and get structured JSON back instead of scraping stdout;
- inspect, create, and patch notebook files without needing a running kernel;
- search and read the locally installed documentation corpus offline;
- drive selected FrontEnd actions programmatically;
- ask the built-in Notebook Assistant about a specific source cell and optionally insert generated
  Wolfram Language code back into the notebook;
- parse and structurally analyze Wolfram expressions without access to a kernel.
- develop the overflow-resistant large-number arithmetic research and prototypes that feed the
  kernel-free numeric fallback.

Tungsten is deliberately not trying to be a full alternative Wolfram runtime. It is an automation
layer over the real local installation, plus a substantial but bounded kernel-free expression and
notebook runtime where that meaningfully improves agent workflows.

## Project goals

Tungsten exists to satisfy a small set of load-bearing goals:

- Make local Wolfram automation practical from C++, `pwsh`, .NET, and JSON-first tooling.
- Provide a console-mode `tungsten-cpp` REPL that feels familiar to `wolfram.exe` users while
  staying kernel-free.
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

- It is not yet a full Wolfram kernel reimplementation; unsupported heads remain symbolic.
- Today it does not attempt full box-language parsing or full StandardForm rendering.
- It does not try to expose the entire FrontEnd API surface.
- It does not depend on browser automation or online-only documentation scraping.
- It does not replace interactive GUI workflows when those are genuinely the most natural way to do
  the work.

## Longer-term expression direction

The shipped expression subsystem already covers structural manipulation, pure functions,
definitions and scoping, control flow, exact and approximate arithmetic, integer number theory,
arrays (including sparse forms), and a bounded elementary/transcendental numeric layer. Continued
work focuses on closing measured compatibility edges without turning Tungsten into an unbounded
general-purpose computer algebra system.

The main long-term boundaries remain:

- full Wolfram Language and box-language syntax is a target, but unsupported syntax is rejected
  explicitly rather than guessed;
- `Simplify`/`FullSimplify`, elementary functions, polynomial algebra, algebraic numbers, and
  equation solving stay within documented native subsets;
- general symbolic differential/integral calculus, optimization, and arbitrary specialized
  mathematical algorithms remain outside the local evaluator's scope;
- workflows requiring complete Wolfram semantics should use the real kernel-backed command path.

## Current feature map

The current workspace is built around eight complementary capabilities:

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
   calls, supports positional pure functions such as `Function[body]`, `body &`, `#`, `#n`, `#0`,
   `##`, `##n`, and `Function[Null, body, attrs]`, supports named pure functions such as
   `Function[x, body]`, `Function[params, body, attrs]`, `x |-> body`, and
   `x \[Function] body` with capture-avoiding parameter renaming and the pure-function attribute
   subset for hold, sequence, and listable behavior. The native evaluator covers the complete
   Python-oracle dispatch inventory with the same bounded algorithmic scope, including hold-like
   conditionals (`If`, `Which`, `Switch`, `Piecewise`),
   integer arithmetic and relational heads, simple predicates such as `IntegerQ`, `NumericQ`, `StringQ`,
   `DigitQ`, `LetterQ`, `EvenQ`, and `SparseArrayQ`, integer-only numeric heads such as `UnitStep`, `Mod`,
   `Min`/`Max` (with single-list-argument fold), `Clip`, and `KroneckerDelta`, real-rounding heads
   `Floor`, `Ceiling`, `Round`, `IntegerPart`, `FractionalPart`, and `Sqrt` over the explicit-number
   subset, native combinatorial and number-theory heads including `Binomial`, `Multinomial`,
   `GCD`, `LCM`, `Divisors`, `FactorInteger`, `IntegerExponent`, `JacobiSymbol`,
   `KroneckerSymbol`, integer sequences and partitions, prime predicates/enumeration, totients and
   multiplicative functions, modular arithmetic, continued fractions, integer digits, and
   Chinese remaindering, plus the `Bit*` integer family and exact polynomial heads
   `Expand`, `PolynomialQ`, `Variables`, `MonomialList`, `Collect`, `Coefficient`, `Exponent`,
   `CoefficientList`, `Factor`, `FactorList`, and `Decompose`, plus native exact algebraic-number
   operations over bounded indexed polynomial roots, guarded by the mutable `$MaxRootDegree`
   safety setting, and a numeric layer that recognizes `Pi`, `E`, `Degree`, direct and inverse
   trigonometric/hyperbolic families, degree forms, Haversine and Gudermannian families, exact
   special cases, machine values, and GMP-backed requested-precision projections. Variable-free
   `Simplify` and `FullSimplify` apply the documented bounded identities and ordinary evaluation;
   unsupported symbolic cases remain unchanged. The evaluator also covers Boolean heads,
   `Length`, `Depth`, `MatchQ`, `Cases`, `DeleteCases`,
   `Replace`, `ReplaceAll`, `ReplaceRepeated`, functional combinators such as `Composition`,
   `Nest`, `FixedPoint`, `Fold`, and `SameAs`, traversal and threading heads such as `MapApply`,
   `MapAll`, `MapIndexed`, `Thread`, `Outer`, `Inner`, and `Dot` including sparse vector/matrix
   products, sparse-array heads such as `SparseArray`, `Dimensions`, `ArrayRules`, and `Normal`,
   array and sequence builders such as `Array`, `Range`, `Partition`, and `BlockMap`, search and de-duplication heads such as
   `FirstCase`, `Position`, and `DeleteDuplicates`, statistical helpers `Mean`, `Median`,
   `Variance`, `StandardDeviation`, `Norm`, `Tally`, `Counts`, `Catenate`, `Differences`,
   `Accumulate`, `Riffle`, `Total`, `Count`, `AllTrue`/`AnyTrue`/`NoneTrue`,
   `ContainsAll`/`ContainsAny`/`ContainsExactly`/`ContainsNone`,
   combinatorial helpers `Subsets`, `Permutations`, `Union`, `Intersection`, `Complement`, and
   one-dimensional `PadLeft` and `PadRight`, association-merge helpers `Merge`, `GroupBy`,
   `GatherBy`, `Gather`, `KeyComplement`, `KeyUnion`, and `KeyIntersection`, byte and character heads such as `ByteArray`,
   `BaseEncode`, `BaseDecode`, `StringLength`, `StringTake`, `StringDrop`, `StringJoin`,
   `StringInsert`, `StringReverse`, `StringSplit`, `StringRiffle`, `StringTrim`,
   `StringPadLeft`/`StringPadRight`, `StringRepeat`, `StringCount`, `ToUpperCase`/`ToLowerCase`,
   `Capitalize`, structural pattern forms such as `PatternTest`, `Optional`,
   `Repeated`, `PatternSequence`, `OrderlessPatternSequence`, `OptionsPattern`, `Longest`, and
   `Shortest`, string-pattern heads such as `StringMatchQ`, `StringFreeQ`,
   `StringStartsQ`, `StringEndsQ`, `StringPosition`, `StringContainsQ`, `StringCases`, and
   `StringReplace` with support for `RegularExpression`, practical `DatePattern`, named string
   sequence captures, greedy/non-greedy `Longest` / `Shortest`, line/word anchors, and common
   Unicode-backed character classes, `ToCharacterCode`, `StringToByteArray`, `ImportString`,
   `ExportString`,
   `ImportByteArray`, `ExportByteArray`, `ToString`, `ToExpression`, `ToBoxes`, `MakeBoxes`,
   `MakeExpression`, `StripBoxes`, `SyntaxQ`, and `SyntaxLength`, plus `Pick`, `Select`, `Discard`, `SelectFirst`,
   `TakeWhile`, `Take`, `Drop`, `Flatten`, `ReplaceAt`, `ReplacePart`, `MapAt`, `Association`,
   `Lookup`, `KeyTake`, `KeySort`, and symbol/context registry heads such as `Symbol`, `SymbolName`,
   `Unique`, `Names`, `NameQ`, `Contexts`, `Context`, `$Context`, `$ContextPath`,
   mutable `Attributes`, `SetAttributes`, `ClearAttributes`, `Protect`, `Unprotect`,
   `ClearAll`, and `ValueQ`. The registry is pre-seeded with the immediate
   <code>System`</code> symbol catalog and attributes from the installed Wolfram 15.0 kernel so
   built-ins are discoverable even when Tungsten does not implement their evaluation rules; the
   evaluator consults those attributes plus process-local user mutations for common hold,
   sequence, listable, flat, orderless, and one-identity matching behavior.
   This is the complete native port of the reviewed Python-reference surface, not a claim of
   complete Wolfram-kernel parity; forms beyond that shared boundary remain symbolic or are
   documented as intentional limits.
5. A console-mode `tungsten-cpp repl` interpreter (also exposed by the .NET `tungsten.exe`
   projection) with `wolfram.exe`-style
   `In[n]:=` / `Out[n]=` prompts, `$Line`, `In`, `InString`, `Out`, read-only history
   `DownValues`, `%` output-history shorthand, and `Exit` / `Quit`.
6. An offline documentation index over the locally installed documentation notebooks.
7. A FrontEnd controller that can open notebooks, open documentation pages, and execute selected
   FrontEnd operations through kernel-side `UsingFrontEnd[...]` calls.
8. A Notebook Assistant controller that can ask the built-in assistant about a selected source cell
   and optionally insert Wolfram Language code below that cell.

## Current status

### Shipped now

- Environment discovery for paid Wolfram 15.0 by default, explicit Wolfram Engine 14.3 selection,
  documentation roots, bundled Python client tree, and product-scoped default index paths.
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
- Kernel-free Wolfram expression parsing and bounded native evaluation.
- Kernel-free `wolfram.exe`-style REPL through `tungsten-cpp repl` and the .NET `tungsten.exe`
  console projection.
- PowerShell wrappers for all major Tungsten surfaces, invoking the native binary directly.
- A typed .NET client wrapper over the native JSON CLI for C# callers.

### Deliberately narrow or experimental

- The visible inline Notebook Assistant desktop-driving backend remains experimental. It depends on
  a visible foreground notebook window and, in practice, on WinDesk-backed automation. WinDesk is
  not part of this repository — it lives in the sibling
  [`Tools`](https://github.com/VladimirReshetnikov/Tools) repository. To use the WinDesk path, build
  `WinDesk.PowerShell` from that repository and either pre-import the module or set
  `$env:TUNGSTEN_WINDESK_MODULE_PATH` to the built `WinDesk.PowerShell.dll`.
- The expression subsystem covers the same pragmatic StandardForm, box, and bounded built-in
  evaluation surface as the Python reference. Forms beyond that reference surface remain symbolic.
- FrontEnd automation is intentionally selective rather than exhaustive.

## Tech stack and operating assumptions

| Area | Current choice |
|------|----------------|
| Runtime | C++17 with CMake 3.20+ and GMP/GMPXX; Python 3.11+ only for the reference oracle and differential tooling |
| Package layout | Native library, CLI, headers, and tests under `cpp/`; Python oracle under `src/tungsten/` |
| Primary execution substrate | Paid Wolfram 15.0 `wolfram.exe -script` by default; `TUNGSTEN_WOLFRAM_PRODUCT=engine` selects Wolfram Engine 14.3 |
| PowerShell integration | Thin JSON-first wrapper module in `pwsh/Tungsten.psm1` |
| .NET integration | Thin typed wrapper library in `dotnet/Tungsten.DotNet/` |
| Documentation index | SQLite FTS5 |
| Notebook representation | Tungsten-owned structural parser for notebook expressions |
| Expression representation | Tungsten-owned AST and Pratt-style parser |
| Sparse array backend | Tungsten-owned native structural sparse arrays |
| Exact polynomial backend | Tungsten-owned native exact integer/rational polynomial core |
| Platform expectation | Windows-first local machine with a real Wolfram installation |
| Optional desktop automation helper | WinDesk (external, from the sibling [`Tools`](https://github.com/VladimirReshetnikov/Tools) repo) for visible-window testing and the experimental inline assistant path |

## Architecture at a glance

```text
                  local Wolfram installations
        ┌───────────────────────────────────────────────┐
        │ Wolfram 15.0 / Wolfram Engine 14.3 wrappers  │
        │ mathpass / local docs notebooks / Chatbook   │
        └───────────────────────────────────────────────┘
                              ▲
                              │
                    discovery.cpp + licensing.cpp
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
   kernel.cpp           notebook.cpp         expression subsystem
   docs_index.cpp       frontend.cpp         assistant.cpp
                         inline_boxes.cpp    wolfram_strings.cpp
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
                        cpp/src/main.cpp
                     ┌────────┴────────┐
                     │                 │
                     ▼                 ▼
               Tungsten.psm1   Tungsten.DotNet
                     │                 │
          C++ CLI / pwsh scripts / .NET apps / agents
```

For the deeper component model and execution flow, see [Architecture](./docs/architecture.md).

## The most important environment fact on this machine

This machine intentionally has two Wolfram product families installed:

- paid Wolfram 15.0 at `C:\Program Files\Wolfram Research\Wolfram\15.0`;
- Wolfram Engine for Developers 14.3 at `C:\Program Files\Wolfram Research\Wolfram Engine\14.3`.

Tungsten prefers the paid Wolfram 15.0 product by default. Set
`TUNGSTEN_WOLFRAM_PRODUCT=engine` only when an Engine-specific run is intended. The selected
product's installed `mathpass` can contain duplicate license entries; that matters because the
obvious command-line paths can fail if they use the raw installed file directly.

Tungsten handles that by:

- inspecting the discovered `mathpass`;
- writing a temporary deduplicated copy;
- invoking `wolfram.exe` with `-pwfile <temporary-deduped-copy>`;
- never mutating the installed machine-wide licensing file.

This is not a side detail. It is part of Tungsten's core execution model.

## Quick start

### C++ CLI

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
$tungsten = if (Test-Path .\build\cpp\tungsten-cpp.exe) {
    Resolve-Path .\build\cpp\tungsten-cpp.exe
} else {
    Resolve-Path .\build\cpp\Release\tungsten-cpp.exe
}

& $tungsten env show --probe
& $tungsten kernel eval --code "2+2"
& $tungsten notebook create --file $env:TEMP\tungsten-demo.nb --title "Demo" --cell "Text:Hello" --cell "Input:2+2"
& $tungsten notebook inspect --file $env:TEMP\tungsten-demo.nb
& $tungsten inline-box compose --prefix "icon: " --box-expr "GraphicsBox[{CircleBox[]}]"
& $tungsten docs search NotebookGet
& $tungsten expr evaluate --code "1 + 2 + 3"
& $tungsten repl
Pop-Location
```

Single-configuration generators normally write `build/cpp/tungsten-cpp` (or `.exe` on Windows).
Visual Studio and other multi-configuration generators normally write
`build/cpp/Release/tungsten-cpp.exe`. The PowerShell and .NET projections check both layouts.

### Haskell CLI

```bash
cd Engine
cabal test all --ghc-options=-Werror
cabal run tungsten-hs -- expr parse --code '1 + 2 x^3'
cabal run tungsten-hs -- expr evaluate --code 'Total[Range[10]]'
cabal run tungsten-hs -- notebook inspect --file example.nb
cabal run tungsten-hs -- repl
cabal run tungsten-hs -- env show
cabal run tungsten-hs -- kernel eval --code '2+2'
cabal run tungsten-hs -- frontend probe
cabal run tungsten-hs -- inline-box compose --prefix 'icon: ' --box-expr 'GraphicsBox[{CircleBox[]}]'
cabal run tungsten-hs -- inline-box from-cell --file example.nb --cell-index 0 --all-objects
cabal run tungsten-hs -- docs search NotebookGet
```

The Haskell port currently covers the kernel-free expression, stateful session and explicit timing
runtime, structural notebook, Wolfram-string, inline-box, and documentation-index foundations,
plus typed discovery, kernel, and FrontEnd operations. See
[Haskell Port](./docs/haskell-port.md) for its exact compatibility boundary and migration order.

### PowerShell

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force

Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
New-TungstenInlineBoxString -Prefix "icon: " -BoxExpression "GraphicsBox[{CircleBox[]}]"
Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "True && False && x"
Invoke-TungstenExpression -Code '$ContextPath'
Invoke-TungstenExpression -Code 'Attributes[Plus]'
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
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force

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
- The expression evaluator implements a broad, pragmatic subset, including associations, exact
  number theory, elementary numeric functions, and stateful definitions. Unsupported heads remain
  symbolic; it does not attempt general kernel semantics.
- FrontEnd automation works only for the actions Tungsten explicitly exposes.
- Notebook Assistant inline UI driving is intentionally not the default path because it is less
  reliable for automation than the hidden chat-notebook backend.
- Notebook-cell inline-box extraction currently operates against saved notebook files rather than
  unsaved live FrontEnd state.

## Repository layout

| Path | Purpose |
|------|---------|
| `Engine/CMakeLists.txt` | Native C++ library/CLI build, tests, install rules, and package export |
| `Engine/cpp/include/tungsten/` | Installed C++ public headers |
| `Engine/cpp/src/` | C++ Engine implementation: CLI, evaluator, parser, notebooks, and Wolfram automation |
| `Engine/cpp/tests/` | Native unit, component, and CLI smoke coverage |
| `Engine/tungsten-engine.cabal` | Haskell package, executable, and test-suite metadata |
| `Engine/haskell/` | Haskell expression model, parsers, evaluator, JSON protocol, CLI, and tests |
| `Engine/pyproject.toml` | Python compatibility-reference metadata and differential tooling |
| `Engine/src/tungsten/` | Python reference implementation and executable compatibility specification |
| `Engine/src/tungsten/discovery.py` | Installation, docs-root, and path discovery |
| `Engine/src/tungsten/licensing.py` | `mathpass` inspection and deduplication helpers |
| `Engine/src/tungsten/kernel.py` | Structured kernel execution wrapper |
| `Engine/src/tungsten/notebook.py` | Structural notebook parser, renderer, and patch support |
| `Engine/src/tungsten/inline_boxes.py` | Inline-box string composition and notebook-cell object extraction |
| `Engine/src/tungsten/expression.py` | Kernel-free expression model, session runtime, structural helpers, and built-in families |
| `Engine/src/tungsten/expression_parser.py` | Wolfram text tokenizer/parser and StandardForm box-to-expression interpretation |
| `Engine/src/tungsten/expression_evaluator.py` | Single-step evaluator dispatch table |
| `Engine/src/tungsten/expression_arithmetic.py` | Arithmetic, numeric, relational, Boolean, predicate, and number-theory rules |
| `Engine/src/tungsten/expression_patterns.py` | Pattern matching, replacement rules, and pattern-backed control helpers |
| `Engine/src/tungsten/parser_corpus.py` | Local parser corpus discovery and Wolfram held-parser comparison |
| `Engine/src/tungsten/wolfram_strings.py` | Shared Wolfram string literal and inline-box escape handling |
| `Engine/src/tungsten/docs_index.py` | Offline documentation indexing/search |
| `Engine/src/tungsten/frontend.py` | Programmatic FrontEnd actions |
| `Engine/src/tungsten/assistant.py` | Notebook Assistant automation |
| `Engine/src/tungsten/cli.py` | Python reference JSON-first CLI entrypoint |
| `Engine/Nummy/` | Tungsten-owned large-number arithmetic research corpus, prior-art snapshots, and alpha/beta/gamma prototype implementations |
| `Engine/Nummy/docs/` | Nummy theory corpus, reports, and archived standalone design proposals |
| `Engine/Nummy/prior-art/` | Source-study reference implementations for very-large-number arithmetic |
| `Engine/Nummy/src/` | Independent alpha, beta, and gamma Python experiments used as large-number fallback source material |
| `Engine/pwsh/` | PowerShell wrappers |
| `Engine/tests/` | Python executable specification and integration coverage |
| `Engine/scripts/Test-TungstenSmoke.ps1` | Native parity gates plus end-to-end smoke runner |
| `Engine/scripts/Test-TungstenParserCorpus.ps1` | Parser corpus comparison runner |
| `Engine/docs/` | Documentation set |

## Build and validation

Build and test the native engine from the Tungsten workspace:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
ctest --test-dir build/cpp -C Release --output-on-failure
dotnet test .\dotnet\Tungsten.DotNet.slnx
Pop-Location
```

Run the development-only Python oracle tests and differential checks:

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

The parser differential is exact over 1,414 extracted literals, the stateful evaluator gate is
82/82, the recorded evaluator gate is 2,499/2,499 calls across 585 tests, and the CLI differential
is 119/119. The standalone evaluator extractor loses setup state; use the recorded evaluator
harness with `--require-perfect` for the authoritative broad comparison. See
[C++ Runtime and Verification](./docs/cpp-port.md) for the measured record.

Run the Haskell build and tests from the same workspace:

```bash
cd Engine
cabal build all
cabal test all --ghc-options=-Werror
cabal check
```

Install the native C++ library, headers, CMake package, and CLI under a staging prefix when needed:

```powershell
cmake --install .\Engine\build\cpp --config Release --prefix .\Engine\build\install
```

The installed CLI is under `Engine/build/install/bin`. For repository-local PowerShell or .NET
smokes, leave the CLI in `Engine/build/cpp`, or set `TUNGSTEN_EXECUTABLE` to its exact path.

## Documentation map

If you are new to Tungsten, this reading order works well:

1. This README for the project map, goals, and current shipped surface.
2. [Documentation Index](./docs/README.md) for the full docs inventory and reading orders by role.
3. [User Guide](./docs/user-guide.md) for practical workflows, tutorials, and scripting examples.
4. [Usage Reference](./docs/usage-reference.md) for the full command surface.
5. [Architecture](./docs/architecture.md) for the detailed component model and execution flow.
6. [C++ Runtime and Verification](./docs/cpp-port.md) for parity status and validation limits.
7. [Haskell Port](./docs/haskell-port.md) for the independent typed port and its compatibility boundary.
8. Focused guides as needed:
   - [Notebook Assistant](./docs/notebook-assistant.md)
   - [Inline Box Strings](./docs/inline-box-strings.md)
   - [Expression Parser](./docs/expression-parser.md)
   - [Large-Number Fallback Design](./docs/overflow-underflow-large-number-fallback.md)
   - [Troubleshooting](./docs/troubleshooting.md)
   - [Implementation Details](./docs/implementation-details.md)

## Design notes

- Tungsten intentionally uses the documented `wolfram.exe` CLI instead of trying to depend on the
  bundled Wolfram Python client at runtime. The bundled client is present on this machine, but its
  higher-level dependency surface is not the most dependable local runtime substrate here.
- Notebook parsing/editing is kept independent from the kernel so agents can still inspect and
  patch notebooks even when evaluation is unavailable or undesirable.
- The expression subsystem is also kernel-free, with explicit bounded rules rather than a claim of
  general-purpose Wolfram evaluation.
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
