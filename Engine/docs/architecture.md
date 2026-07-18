# Tungsten Architecture

Created (UTC): 2026-04-23T02:16:55Z
Updated (UTC): 2026-07-18T04:31:20Z
Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7

## Summary

Tungsten is a small but deliberately layered automation stack around a local Wolfram installation.
Its architecture is shaped by two requirements that are easy to state but surprisingly important in
practice:

- agent and script callers want structured, deterministic outputs;
- the real machine-local Wolfram installation remains the source of truth for evaluation,
  documentation, and FrontEnd behavior.

That leads to a hybrid design:

- kernel-backed capabilities are delegated to the installed Wolfram runtime;
- notebook inspection/editing and expression parsing are implemented locally so they remain
  available even when the kernel is unavailable, undesirable, or too heavyweight for the task;
- PowerShell and .NET support are projected from the native C++ CLI rather than reimplemented.

This document describes the current architecture under `cpp/`. The implementation under
`src/tungsten/` remains the compatibility oracle and executable specification; it is not loaded by the
native runtime. See [cpp-port.md](./cpp-port.md) for verification status and known validation gaps.

## Architectural principles

The current Tungsten design follows a few consistent principles.

### 1. Use the real installation where fidelity matters

If the task depends on actual Wolfram evaluation semantics, actual FrontEnd behavior, or the exact
installed documentation set, Tungsten delegates to the local installation instead of simulating it.

Examples:

- `kernel.cpp` executes through `wolfram.exe`;
- `frontend.cpp` executes real `UsingFrontEnd[...]` code;
- `docs_index.cpp` indexes the actual local `*.nb` documentation corpus;
- `assistant.cpp` uses Mathematica's built-in Notebook Assistant stack rather than inventing a fake
  assistant layer.

### 2. Keep local fallbacks for structure-oriented workflows

Some tasks are structural rather than semantic. For those, Tungsten stays kernel-free on purpose.

Examples:

- `notebook.cpp` parses notebook files structurally and can create/edit them without a kernel;
- `parser.cpp`, `expression.cpp`, and `evaluator.cpp` parse textual Wolfram expressions and
  evaluate the supported offline subset.

### 3. Prefer explicit structured payloads over scraped terminal text

Where possible, Tungsten serializes results into JSON and then projects them outward. This is why
kernel execution goes through a wrapper script that writes a JSON payload to disk instead of asking
callers to infer success from mixed stdout/stderr text.

### 4. Centralize environment quirks

The machine-specific licensing workaround is not hidden in random call sites. Discovery and
licensing behavior are centralized so higher-level layers can rely on one execution policy.

### 5. Keep the PowerShell surface thin

PowerShell is important for automation ergonomics, but the source of truth is the native C++
implementation. The module wraps the CLI instead of growing a parallel implementation.

### 6. Treat .NET as a typed projection layer, not a second core

The .NET client exists so C# callers can use Tungsten naturally, but it is intentionally a thin
process-wrapper layer over the JSON CLI. It should add:

- typed request/response models;
- repo-local discovery helpers;
- option bags where the CLI surface would otherwise be awkward in C#;
- predictable exception handling for process and JSON failures.

It should not quietly fork Tungsten behavior into a second implementation stack.

## Module map

The native `tungsten_cpp` library and `tungsten-cpp` CLI are composed of the following modules.

| Module | Primary responsibility | Depends directly on |
|--------|------------------------|---------------------|
| `json.cpp` | Parse and serialize native JSON values and provide Python-compatible lossy UTF-8 decoding. | C++ standard library |
| `discovery.cpp` | Discover local installations, documentation roots, and default index locations. | OS filesystem and environment variables |
| `licensing.cpp` | Inspect `mathpass` and materialize a temporary deduplicated password file. | Filesystem |
| `kernel.cpp` | Execute Wolfram Language through `wolfram.exe` and return structured results. | discovery, licensing, process execution |
| `wolfram_processes.cpp` | Inspect Wolfram processes and serialize license-seat launches. | OS process APIs and filesystem locks |
| `wolfram_strings.cpp` | Own Wolfram string escaping, parsing, and inline-box segmentation. | Local text parsing only |
| `notebook.cpp` | Parse, inspect, render, and patch notebook files without a kernel. | Local text parsing only |
| `inline_boxes.cpp` | Extract box objects and compose inline-box string literals. | notebook and Wolfram strings |
| `expression.cpp` | Own expression values, GMP-backed exact numeric atoms, sparse arrays, and canonical constructors. | GMP/GMPXX and local formatting helpers |
| `parser.cpp` | Tokenize and parse InputForm/FullForm and lower supported StandardForm boxes. | expression model and bundled named characters |
| `evaluator.cpp` | Own session state, definitions, patterns, scoping, arithmetic, algebra, collections, strings, iteration, and control flow. | expression model/parser and native format codecs |
| `docs_index.cpp` | Build/search/read a local SQLite FTS documentation index through the platform SQLite library. | discovery and notebooks |
| `frontend.cpp` | Provide a narrow FrontEnd automation surface. | kernel and docs index |
| `assistant.cpp` | Automate Notebook Assistant and deterministic notebook insertion. | kernel and notebooks |
| `main.cpp` | Expose the native JSON-first CLI and REPL. | All feature modules |
| `repl.cpp` | Provide stateful console history, hooks, prompts, and display behavior. | expression parser/evaluator |
| `parser_corpus.cpp` | Discover corpus files and compare native acceptance with held Wolfram parsing. | parser, notebooks, kernel runner |
| `pwsh/Tungsten.psm1` | Project the CLI into PowerShell-friendly functions. | `tungsten-cpp` |
| `dotnet/Tungsten.DotNet` | Project the CLI into typed .NET request/response APIs. | `tungsten-cpp`, `System.Text.Json`, `System.Diagnostics.Process` |

## High-level layer diagram

```text
                     local Wolfram installation
       ┌─────────────────────────────────────────────────────┐
       │ wolfram.exe / WolframNB.exe / docs notebooks /     │
       │ mathpass / Notebook Assistant / Chatbook stack     │
       └─────────────────────────────────────────────────────┘
                              ▲
                              │
                  discovery.cpp + licensing.cpp
                              │
         ┌────────────────────┼─────────────────────┐
         │                    │                     │
         ▼                    ▼                     ▼
     kernel.cpp           notebook.cpp          expression subsystem
         │                    │
         │                    ├───────┬──────┐
         ▼                    ▼       ▼      │
    frontend.cpp         docs_index.cpp inline_boxes.cpp
         │                    │              │
         └──────────────┬─────┘              │
                        ▼                    │
                   assistant.cpp              │
                        │                    │
                        └──────────┬─────────┘
                                   ▼
                                 main.cpp
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
             pwsh/Tungsten.psm1        dotnet/Tungsten.DotNet
                    ▼                             ▼
           C++ callers / PowerShell / .NET apps / agents
```

## Core runtime objects

Several data structures act as architectural seams between layers.

### `JsonValue`

Defined in `json.hpp` and `json.cpp`, this is the native structured-data seam used throughout the
library and CLI. It preserves valid parsed number spellings, emits deterministic object/array
payloads, formats constructed finite doubles with CPython-compatible JSON spellings, and uses
ASCII-safe Unicode escaping. The same component exposes lossy UTF-8 decoding with Python-compatible
replacement boundaries for external text streams; strict inputs such as notebook patch JSON add
UTF-8 validation before they enter the JSON parser.

### `WolframInstallation`

Defined in `discovery.cpp`, this is the canonical description of the discovered local environment.
It includes:

- product metadata (`product`, `product_family`, `version`) and the full list of available local
  Wolfram product installations;
- installation paths such as `kernel_cli`, `kernel_executable`, `frontend_executable`, and
  `wolframscript`;
- `mathpass`;
- discovered documentation roots;
- the bundled `WolframClientForPython` tree if present;
- Tungsten's default documentation index path.

Higher layers take this object instead of independently rediscovering the environment.

### `MathpassInspection`

Defined in `licensing.cpp`, this captures:

- whether the discovered file exists;
- whether a `%` header is present;
- original line count;
- unique entry count;
- duplicate entry count.

This is returned all the way out to callers as part of kernel result metadata, which makes
licensing behavior observable instead of implicit.

### `KernelEvaluationResult`

Defined in `kernel.cpp`, this is the main structured payload for kernel-backed execution. It
contains:

- command-line invocation;
- process exit code;
- Tungsten-level success/failure metadata;
- result and result head as strings;
- messages, message text, and captured printed output;
- timing fields;
- raw stdout/stderr;
- whether a JSON payload was successfully produced;
- mathpass inspection details.

This object is the core contract for `kernel.cpp`, `frontend.cpp`, and much of `assistant.cpp`.

### `NotebookDocument`

Defined in `notebook.cpp`, this is Tungsten's structural notebook model. It is intentionally simpler
than the full Wolfram language model and is built around:

- `NotebookCell`
- `NotebookGroup`
- `NotebookRawItem`

It supports:

- flattening cells for selector-based workflows;
- inspecting notebook-level options;
- appending/inserting/replacing cells;
- round-tripping notebook text back to disk.

Parsed notebook text is retained through shared immutable `SourceSpan` buffers. Span start/end
values are UTF-8 byte offsets, matching C++ string indexing and allowing cells/options to share one
large source allocation; they are not Python Unicode code-point indices. Edited values materialize
owned `SourceText` only where needed.

### Expression AST Nodes

Defined in `expression.hpp` and `expression.cpp`, `Expr` carries Tungsten's general Wolfram
expression model independently of `NotebookDocument`. Immutable shared nodes represent symbols,
strings, calls, exact GMP integers and rationals, reals, complex values, algebraic roots, byte
arrays, and sparse arrays. Canonical constructors and `to_input_form`, `to_full_form`, and JSON
projections are owned by this layer.

`parser.cpp` owns tokenization, Pratt parsing, FullForm parsing, and the supported StandardForm box
lowering. `evaluator.cpp` owns the process-local definition tables, attribute handling, patterns,
scoping, arithmetic, collections, strings, iteration, and control flow. `repl.cpp` adds the
stateful session boundary: line history, main-loop hooks, prompts, and output formatting.

The Python modules under `src/tungsten/` describe the compatibility target and remain useful for
differential testing, but they are not architectural runtime dependencies. Some Python behavior is
still more complete at edge cases; native C++ tests and the parity harnesses identify those gaps
rather than treating the port as automatically complete.

## Workflow architecture

The easiest way to understand Tungsten is by following the main workflows end to end.

### Workflow 1: Environment discovery

Used by almost every CLI command.

1. `main.cpp` calls `discover_installation()`.
2. `discovery.cpp` looks for an explicit `TUNGSTEN_WOLFRAM_HOME` override first.
3. If no override is present, it searches the default Windows installation root under
   `Program Files\Wolfram Research\Wolfram` and picks the highest parseable version directory.
4. It discovers documentation roots from both:
   - the shared installation tree under `Common Files`;
   - user-installed documentation paclet update roots under `%APPDATA%\Wolfram\Paclets\Repository`.
5. It discovers `mathpass` under `%ProgramData%\Wolfram\Licensing\mathpass`.
6. It constructs a default SQLite index path under `%LOCALAPPDATA%\Tungsten\docs\`.

Important property:

- discovery is read-only;
- discovery does not validate every downstream behavior by itself;
- optional probing is a separate step exposed through `env show --probe`.

### Workflow 2: Kernel evaluation

This is Tungsten's most important kernel-backed workflow.

1. The caller provides inline code or a file path.
2. `kernel.cpp` creates a temporary working area.
3. The user code is written to `input.wl` if necessary.
4. `licensing.cpp` materializes a temporary deduplicated password file.
5. `kernel.cpp` writes a wrapper script that:
   - imports the user code;
   - parses it with `ToExpression[..., HoldComplete]`;
   - optionally wraps it in `UsingFrontEnd[...]`;
   - evaluates it with `EvaluationData[...]`;
   - captures result strings, messages, timing, and `Print` output;
   - exports a JSON payload to disk.
6. `wolfram.exe -noprompt -pwfile ... -script wrapper.wl` is executed.
7. Tungsten reads the JSON payload if it was written.
8. The final `KernelEvaluationResult` is returned to the caller.

Architectural consequence:

- process success and semantic success are distinct;
- callers do not have to parse Wolfram textual output conventions on their own.

### Workflow 3: Notebook file inspection and editing

This is the main kernel-free notebook path.

1. `NotebookDocument.load()` reads the notebook text.
2. `NotebookDocument.from_text()` isolates the outer `Notebook[...]` expression.
3. Structural parsing is delegated to helper functions such as:
   - `parse_call`
   - `parse_list`
   - `split_top_level`
   - comment/string skipping helpers
4. Cells and groups are converted into Tungsten structural nodes.
5. For inspection, the document is flattened into rows containing:
   - `index`
   - `path`
   - `style`
   - `preview`
   - `expression_uuid`
   - `cell_id`
   - `cell_tags`
6. For edits, Tungsten mutates the structure and renders it back to notebook text.

The flattening step is especially important architecturally because it creates the stable selection
surface used by assistant automation and by many scripts.

That same structural layer now also supports kernel-free inline-box extraction. Given a saved
notebook file and a selected cell, `inline_boxes.cpp` can inspect the stored cell expression and
extract:

- top-level `BoxData[...]` contents;
- inline box escapes that are already embedded inside string literals.

### Workflow 4: Documentation indexing and search

This flow is local, offline, and installation-aligned.

1. `docs_index.cpp` enumerates notebook files beneath the discovered documentation roots.
2. For each notebook, it extracts:
   - a title, usually from `WindowTitle`;
   - a paclet identifier inferred from the file path;
   - a preview and searchable body assembled from string literals in the notebook text.
3. The extracted records are stored in:
   - a normal SQLite table for full records;
   - an FTS5 virtual table for search.
4. Searches prefer a native filename/stem lookup over indexed records and configured
   documentation roots.
5. If filename resolution does not win, Tungsten queries SQLite FTS5.

This hybrid design matters:

- the filename path makes obvious page lookups deterministic without an optional external tool;
- SQLite FTS provides a general offline fallback;
- the indexed data remains tied to the exact local documentation installation.

### Workflow 5: FrontEnd actions

`frontend.cpp` is intentionally a narrow adapter rather than a broad framework.

For every supported FrontEnd action:

1. the controller builds a small Wolfram expression;
2. the expression is sent through `kernel.cpp` with
   `KernelEvaluationOptions::require_front_end = true`;
3. the result comes back as a normal `KernelEvaluationResult`.

Supported action styles include:

- probing FE availability;
- opening a notebook;
- resolving and opening a documentation page;
- executing arbitrary FE-targeted code;
- executing named FE tokens.

Architecturally, FrontEnd control is a specialization of the kernel runner, not a separate process
management stack.

### Workflow 6: Notebook Assistant automation

The assistant subsystem combines notebook inspection, FrontEnd-backed execution, and post-processing.

Recommended `ask-cell` flow:

1. `assistant.cpp` resolves the requested source cell.
2. Resolution prefers stable selectors in this order:
   - `ExpressionUUID`
   - `CellID`
   - first `CellTag`
   - flat cell index as a fallback
3. Tungsten generates a Wolfram script that:
   - opens the source notebook;
   - locates the selected cell;
   - creates a temporary hidden assistant notebook;
   - invokes the built-in assistant stack on behalf of that source cell;
   - returns a JSON payload containing a `ChatObject` string and source-cell metadata.
4. `assistant.cpp` post-processes the returned assistant payload:
   - extracts assistant text from the `ChatObject` string;
   - extracts fenced code blocks from the reply;
   - classifies Wolfram insertable blocks;
   - optionally reinserts them below the source cell through a second FE-backed operation.

Experimental inline flow:

- `prepare-inline` opens/focuses the visible inline assistant UI;
- `capture-inline` reads the current inline assistant state and optionally inserts extracted code.

Architecturally, the important choice is that the default path is not the visible inline UI. Tungsten
prefers a hidden chat-notebook flow because it is much more deterministic for scripts and agents.

### Workflow 7: Kernel-free inline-box strings

The inline-box subsystem sits between notebook parsing and general expression parsing.

1. `wolfram_strings.cpp` preserves unknown backslash escapes so inline box syntax such as
   `\!\(\*GraphicsBox[...]\)` survives round-tripping.
2. `notebook.cpp` can structurally inspect a saved notebook cell and extract box-bearing objects from
   `BoxData[...]` or from strings that already contain inline box escapes.
3. `inline_boxes.cpp` turns those extracted box expressions into:
   - decoded string values;
   - canonical Wolfram string literals;
   - structured metadata for each embedded object.

This flow is intentionally kernel-free as long as the source notebook state is already saved to
disk.

### Workflow 8: Kernel-free expression parsing

The expression subsystem is separate from notebooks because the problem shape is different.

1. The caller provides source text plus an explicit form: `input`, `fullform`, or `standard`.
2. `parser.cpp` tokenizes the input.
3. The parser applies operator precedence and Wolfram-specific surface rules to build an AST.
4. The AST is rendered back to canonical `InputForm` and `FullForm`.
5. If requested, `Evaluator` in `evaluator.cpp` applies the supported native structural rules while
   retaining unsupported calls symbolically.

This subsystem does not participate in the kernel-backed architecture and is intentionally
kernel-free. Parser acceptance and evaluator behavior are checked against the Python oracle, but
the native implementation remains explicit about unsupported syntax and evaluator edge cases.

## Failure model

Tungsten distinguishes several different classes of failure.

### Discovery failure

Discovery may return missing paths without throwing. Higher layers decide whether the missing path
is fatal for the requested operation.

### Process failure

The external `wolfram.exe` process may fail to launch or may exit without producing Tungsten's JSON
payload. In that case:

- `exit_code` and `stderr` are still returned;
- `evaluation_available` is `false`;
- higher-level layers can surface a precise failure category.

On Windows, the current child-process launch path uses broad inheritable-handle mode rather than an
explicit handle allow-list. Tungsten's supported deployment is a trusted local automation process;
an embedding host that owns sensitive inheritable handles should de-inherit or close them before
launching a Wolfram child.

### Evaluation failure

The wrapper script may run and produce a payload whose `success` field is `false`. That is different
from total process failure and is preserved explicitly.

### Semantic post-processing failure

Some higher-level flows succeed at kernel evaluation but fail later.

Examples:

- assistant evaluation succeeds, but Tungsten cannot parse the assistant payload;
- assistant reply exists, but no insertable code block is found;
- notebook selector resolution is ambiguous.

These are represented as Tungsten-level errors instead of being hidden as generic subprocess failures.

## Boundary decisions

Several current subsystem boundaries are intentional and worth preserving unless a later change has
clear value.

### Notebook parsing and expression parsing are separate

Even though both deal with Wolfram syntax, they solve different problems and have different
correctness criteria. Merging them would likely make both more fragile.

### FrontEnd operations do not bypass the kernel layer

This keeps licensing behavior, process invocation, and result capture consistent across kernel-only
and FE-backed flows.

### PowerShell is not a second implementation

The module is an ergonomic projection layer. New substantive behavior should land in the C++
engine first and then be surfaced in PowerShell. Oracle fixtures or Python reference behavior
should change only when the intended compatibility contract changes too.

### Documentation search is file-backed, not browser-backed

This preserves offline behavior and installation alignment while keeping implementation complexity
low.

## Extension points

The current architecture is intentionally open to a few natural kinds of extension.

### Extending the CLI

The usual path is:

1. add or extend the relevant C++ library component under `cpp/src/` and public header under
   `cpp/include/tungsten/` when needed;
2. expose it through `cpp/src/main.cpp`;
3. add PowerShell wrappers in `pwsh/Tungsten.psm1` if the scenario benefits from them;
4. add tests;
5. add or update documentation in this docs tree.

### Extending notebook editing

If a new notebook mutation is structural and deterministic, it belongs in `notebook.cpp` and the
patch-spec surface rather than in opaque FE automation.

### Extending FrontEnd automation

If the action is a clean FE token or a small FE-targeted Wolfram expression, it usually belongs in
`frontend.cpp`. If the action requires brittle visible-window automation, Tungsten should treat it as
optional or experimental.

### Extending native expression evaluation

New built-ins should remain explicitly enumerated and structurally defined. The architecture works
because the evaluator is honest about being bounded.

## Validation architecture

Tungsten currently validates itself at three useful levels.

### Unit and component tests

CTest exercises the native C++ expression, JSON, runtime, string, notebook, inline-box, process,
kernel, REPL, documentation-index, FrontEnd, parser-corpus, assistant, and CLI surfaces. The Python
test suite remains the executable compatibility specification, and the `check_cpp_*_parity.py`
harnesses compare parser and evaluator projections where their contracts overlap.

### Integration-style tests

Component tests use injected installations, fake process results, and explicit missing-runtime
cases where possible. Live smoke flows separately exercise the real local installation and
documentation state.

### End-to-end projection smoke

Repository-local PowerShell and .NET smoke runs invoke `build/cpp/tungsten-cpp` directly (or via
`TUNGSTEN_EXECUTABLE`) and cover:

- environment discovery;
- kernel execution;
- notebook create/inspect/patch;
- documentation lookup;
- FrontEnd interaction;
- assistant workflows;
- expression parsing/evaluation.

One practical note belongs in the architecture record because it affects reliable validation:

- FrontEnd-heavy smoke runs should be executed serially rather than in parallel with other
  Wolfram-heavy test passes. Parallel FE integration runs can interfere with each other on the same
  desktop session.

The current verification record covers Linux GCC/Clang-style native builds, not a live MSVC or
macOS build. Installed/downstream consumers also need GMP/GMPXX binaries compatible with the
headers and libraries used to build `Tungsten::Engine`; CMake discovery alone cannot validate a
manually mixed GMP ABI.

The Linux native-runtime pass validates the native kernel-free layers and unavailable-runtime
behavior, but cannot validate the Windows-specific installation layout, `mathpass`/process-seat
integration, real `wolfram.exe` launches, FrontEnd, installed documentation, or Notebook Assistant.
A serial smoke run on the target Windows machine with Wolfram installed remains the validation
boundary for those workflows.

## What is deliberately not in the architecture

Tungsten currently does not attempt to own:

- general GUI automation beyond a small optional WinDesk-assisted surface;
- a full Wolfram runtime;
- complete box-language understanding;
- complete FrontEnd API coverage;
- semantic notebook interpretation beyond the structural editing model.

Those are not missing by accident. They are outside the current architectural scope.
