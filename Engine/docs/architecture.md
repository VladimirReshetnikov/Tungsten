# Tungsten Architecture

Created (UTC): 2026-04-23T02:16:55Z
Updated (UTC): 2026-04-27T00:34:28Z
Repository HEAD: 9b7cb3dc1051f354b5da892397b825a822ede8e3

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
- PowerShell and .NET support are projected from the Python CLI rather than reimplemented.

This document describes the current architecture as implemented in `src/tungsten/`.

## Architectural principles

The current Tungsten design follows a few consistent principles.

### 1. Use the real installation where fidelity matters

If the task depends on actual Wolfram evaluation semantics, actual FrontEnd behavior, or the exact
installed documentation set, Tungsten delegates to the local installation instead of simulating it.

Examples:

- `kernel.py` executes through `wolfram.exe`;
- `frontend.py` executes real `UsingFrontEnd[...]` code;
- `docs_index.py` indexes the actual local `*.nb` documentation corpus;
- `assistant.py` uses Mathematica's built-in Notebook Assistant stack rather than inventing a fake
  assistant layer.

### 2. Keep local fallbacks for structure-oriented workflows

Some tasks are structural rather than semantic. For those, Tungsten stays kernel-free on purpose.

Examples:

- `notebook.py` parses notebook files structurally and can create/edit them without a kernel;
- `expression.py` parses textual Wolfram expressions and evaluates a small inert structural subset.

### 3. Prefer explicit structured payloads over scraped terminal text

Where possible, Tungsten serializes results into JSON and then projects them outward. This is why
kernel execution goes through a wrapper script that writes a JSON payload to disk instead of asking
callers to infer success from mixed stdout/stderr text.

### 4. Centralize environment quirks

The machine-specific licensing workaround is not hidden in random call sites. Discovery and
licensing behavior are centralized so higher-level layers can rely on one execution policy.

### 5. Keep the PowerShell surface thin

PowerShell is important for automation ergonomics, but the source of truth remains the Python
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

The current Tungsten package is composed of the following modules.

| Module | Primary responsibility | Depends directly on |
|--------|------------------------|---------------------|
| `discovery.py` | Discover the local installation, documentation roots, bundled client tree, and default index location. | OS filesystem and environment variables |
| `licensing.py` | Inspect `mathpass` and materialize a temporary deduplicated password file. | Filesystem |
| `kernel.py` | Execute Wolfram Language through `wolfram.exe` and return structured results. | `discovery.py`, `licensing.py`, subprocess |
| `wolfram_strings.py` | Own shared Wolfram string literal escaping, parsing, and inline-box segmentation. | Local text parsing only |
| `notebook.py` | Parse, inspect, render, and patch notebook files without a kernel. | Local text parsing only |
| `inline_boxes.py` | Extract box-bearing objects from saved notebook cells and compose inline-box string literals. | `notebook.py`, `wolfram_strings.py` |
| `expression.py` | Own the expression AST facade, sparse-array value representation, evaluation session state, public compatibility imports, and structural helpers not yet split out. | `expression_parser.py`, `expression_evaluator.py` through lazy wrappers |
| `expression_parser.py` | Tokenize/parse Wolfram InputForm/FullForm text and lower the supported StandardForm box subset. | `expression.py`, `wolfram_strings.py` |
| `expression_evaluator.py` | Dispatch one evaluated expression to the appropriate built-in family. | `expression.py` |
| `expression_arithmetic.py` | Evaluate arithmetic, numeric constructors, relations, Boolean logic, predicates, integer-number-theory functions, real-rounding heads, and the explicit-number subset of special functions. | `expression.py` |
| `expression_patterns.py` | Match ordinary expression patterns and implement replacement/search helpers. | `expression.py` |
| `expression_definitions.py` | Own the canonical symbol-definition storage shape (`Definition`, `assign_definition`, `remove_definitions`, `rules_for_kind`) and the routing seam for compound-LHS Set / SetDelayed plus tagged TagSet / TagSetDelayed support. | `expression.py` |
| `expression_scoping.py` | Home for the lexical/dynamic scoping constructs. Owns ``With[bindings, body]`` (capture-avoiding substitution backed by `expression._substitute_named_symbols_in_expr`), ``Module[{locals}, body]`` (fresh-symbol allocation through `SymbolRegistry.allocate_module_local_symbols` plus capture-avoiding rename of `body` through `expression._rename_bound_symbols_in_expr`), and ``Block[locals, body]`` / ``Internal``InheritedBlock[locals, body]`` (snapshot-and-restore of the symbols' complete value state in a Python ``try`` / ``finally`` so the restore survives non-local control flow). Exports the snapshot/restore primitives that the iteration module reuses. | `expression.py` |
| `expression_iteration.py` | Home for the iteration and looping constructs. Owns the iter-spec heads ``Table`` (builds nested ``List`` results), ``Do`` (runs the body for side effects, returns ``Null``), ``Sum`` and ``Product`` (collect per-iteration body values into a flat list and fold through ``Plus`` / ``Times``), as well as the predicate-driven loops ``For[init, test, incr, body]`` and ``While[test, body]`` / ``While[test]``. Iter-spec iteration variables are Block-scoped through the snapshot/restore primitives borrowed from ``expression_scoping``; later iter specs are resolved in the scope where earlier iterators are already bound, so dependent iter forms (``{j, i}`` after ``{i, ...}``) work as in the kernel. ``Do`` / ``For`` / ``While`` catch the non-local control signals raised by ``Break[]`` / ``Continue[]`` / ``Return[expr, head]`` so the loop exits cleanly or skips to its next iteration. | `expression.py`, `expression_scoping.py` |
| `docs_index.py` | Build/search/read a local SQLite FTS documentation index from notebook files. | `discovery.py`, `notebook.py`, SQLite, optional `es.exe` |
| `frontend.py` | Provide a narrow FrontEnd automation surface through kernel-backed calls. | `kernel.py`, `docs_index.py` |
| `assistant.py` | Automate Notebook Assistant for a selected source cell and optionally insert code below it. | `kernel.py`, `notebook.py` |
| `cli.py` | Expose the package as a JSON-first command-line interface. | All feature modules |
| `pwsh/Tungsten.psm1` | Project the CLI into PowerShell-friendly functions. | `python -m tungsten ...` |
| `dotnet/Tungsten.DotNet` | Project the CLI into typed .NET request/response APIs. | `python -m tungsten ...`, `System.Text.Json`, `System.Diagnostics.Process` |

## High-level layer diagram

```text
                     local Wolfram installation
       ┌─────────────────────────────────────────────────────┐
       │ wolfram.exe / WolframNB.exe / docs notebooks /     │
       │ mathpass / Notebook Assistant / Chatbook stack     │
       └─────────────────────────────────────────────────────┘
                              ▲
                              │
                  discovery.py + licensing.py
                              │
         ┌────────────────────┼─────────────────────┐
         │                    │                     │
         ▼                    ▼                     ▼
     kernel.py           notebook.py          expression subsystem
         │                    │
         │                    ├───────┬──────┐
         ▼                    ▼       ▼      │
    frontend.py         docs_index.py inline_boxes.py
         │                    │              │
         └──────────────┬─────┘              │
                        ▼                    │
                   assistant.py              │
                        │                    │
                        └──────────┬─────────┘
                                   ▼
                                 cli.py
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
             pwsh/Tungsten.psm1        dotnet/Tungsten.DotNet
                    ▼                             ▼
          Python callers / PowerShell / .NET apps / agents
```

## Core runtime objects

Several data structures act as architectural seams between layers.

### `WolframInstallation`

Defined in `discovery.py`, this is the canonical description of the discovered local environment.
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

Defined in `licensing.py`, this captures:

- whether the discovered file exists;
- whether a `%` header is present;
- original line count;
- unique entry count;
- duplicate entry count.

This is returned all the way out to callers as part of kernel result metadata, which makes
licensing behavior observable instead of implicit.

### `KernelEvaluationResult`

Defined in `kernel.py`, this is the main structured payload for kernel-backed execution. It
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

This object is the core contract for `kernel.py`, `frontend.py`, and much of `assistant.py`.

### `NotebookDocument`

Defined in `notebook.py`, this is Tungsten's structural notebook model. It is intentionally simpler
than the full Wolfram language model and is built around:

- `NotebookCell`
- `NotebookGroup`
- `NotebookRawItem`

It supports:

- flattening cells for selector-based workflows;
- inspecting notebook-level options;
- appending/inserting/replacing cells;
- round-tripping notebook text back to disk.

### Expression AST Nodes

Defined in `expression.py`, these carry the general Wolfram expression model used by the inert
parser/evaluator. The exact node types are owned by that module, but architecturally the important
point is that they are separate from `NotebookDocument` and deliberately not reused for notebook
structure.

`SparseArrayExpr` is one specialized atomic node in that model. It stores dimensions, an implicit
value, and explicit coordinate/value entries in Tungsten-owned structural form, and lazily attaches
a PyData Sparse `sparse.COO` backend when the package is importable and can represent the payload.
Evaluator behavior remains defined by the Tungsten structure so fallback behavior and symbolic
values do not depend on the external package's arithmetic semantics.

The expression implementation is now split across a small facade plus family modules:

- `expression_parser.py` owns tokenization, Pratt parsing, and supported StandardForm box
  interpretation.
- `expression_evaluator.py` owns the large single-step built-in dispatch table.
- `expression_arithmetic.py` owns explicit-number, relation, Boolean, predicate, integer
  number-theory, and real-rounding evaluator rules.
- `expression_patterns.py` owns ordinary expression pattern matching, replacements, and structural
  search helpers.
- `expression_definitions.py` owns the canonical symbol-definition storage shape — the
  `Definition` dataclass and the ``OwnValues`` / ``DownValues`` / ``UpValues`` / ``SubValues`` /
  ``NValues`` ordered-list contract — plus the LHS classifier
  (``classify_assignment_lhs``) that routes Set / SetDelayed / UpSet / TagSet
  assignments to the right value list. Bare-symbol Set / SetDelayed, ordinary compound-LHS
  Set / SetDelayed, and TagSet / TagSetDelayed write through this surface today; UpSet remains
  the next direct up-value assignment family to wire into the same seam.
- `expression_scoping.py` owns the lexical/dynamic scoping constructs.
  ``With[bindings, body]`` parses each binding (``Set`` evaluates the RHS once in the
  outer scope; ``SetDelayed`` holds it), builds a substitution map, and applies the
  shared ``expression._substitute_named_symbols_in_expr`` capture-avoiding substitution
  into ``body``. ``Module[{locals}, body]`` allocates a fresh per-invocation symbol
  ``name$N`` for every local through ``SymbolRegistry.allocate_module_local_symbols``
  (which increments the per-process module counter once and gives every local from one
  Module call the same suffix); each binding's RHS is evaluated in the outer scope and
  installed as the fresh symbol's own value, then ``body`` is rewritten through
  ``expression._rename_bound_symbols_in_expr`` so every reference to a local resolves
  to its fresh symbol. The shared rewrite helpers now recognize ``Function``, ``With``,
  ``Module``, and ``Block`` as scoping calls so inner-bound names that would shadow the
  rewrite are filtered out, and inner-bound names that would *capture* a free variable
  in a substituted value are alpha-renamed to a fresh ``name$`` symbol.
  ``Block[locals, body]`` and ``Internal``InheritedBlock[locals, body]`` are
  functionally identical in modern Wolfram and are implemented through a shared
  ``_block_implementation`` helper: each binding's symbol is snapshotted (legacy
  ``own_value`` plus all canonical value-list slots), the optional initializer sets
  the OwnValue, the body evaluates, and the snapshot is restored in a Python
  ``try`` / ``finally`` so non-local control flow (``Throw``, ``Abort``, time
  constraints, confirmation failures) still reverts outer state.
- `expression_iteration.py` owns the iteration constructs ``Table``, ``Do``,
  ``Sum``, and ``Product``. All four share the standard iter-spec vocabulary
  (``n`` / ``{n}`` for variable-less iteration, ``{i, n}``, ``{i, imin, imax}``,
  ``{i, imin, imax, di}``, ``{i, list}``); each iteration variable is Block-scoped
  through the snapshot/restore primitives borrowed from ``expression_scoping``, so
  the iteration variable's outer state is restored on exit and non-local control
  flow still reverts the binding. Multiple iter specs nest with the leftmost
  outermost; later iter specs are resolved in the scope where earlier iterators
  are already bound, so dependent iter forms work as in the kernel. ``Table``
  collects results into a nested ``List``; ``Do`` evaluates the body for side
  effects only and returns ``Null``. ``Sum`` and ``Product`` walk the iteration
  in flat fashion and fold the collected per-iteration body values through
  ``Plus`` (Sum, identity ``0``) or ``Times`` (Product, identity ``1``); both
  reject the bare-integer ``n`` form to match the kernel, which keeps
  ``Sum[a, 3]`` inert while accepting ``Sum[a, {3}]``.
- `expression.py` remains the compatibility import surface and still hosts shared expression data
  types, session state, formatting, strings, associations, functional/list operations, and other
  built-in families awaiting future extraction.

## Workflow architecture

The easiest way to understand Tungsten is by following the main workflows end to end.

### Workflow 1: Environment discovery

Used by almost every CLI command.

1. `cli.py` calls `discover_installation()`.
2. `discovery.py` looks for an explicit `TUNGSTEN_WOLFRAM_HOME` override first.
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
2. `kernel.py` creates a temporary working area.
3. The user code is written to `input.wl` if necessary.
4. `licensing.py` materializes a temporary deduplicated password file.
5. `kernel.py` writes a wrapper script that:
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
notebook file and a selected cell, `inline_boxes.py` can inspect the stored cell expression and
extract:

- top-level `BoxData[...]` contents;
- inline box escapes that are already embedded inside string literals.

### Workflow 4: Documentation indexing and search

This flow is local, offline, and installation-aligned.

1. `docs_index.py` enumerates notebook files beneath the discovered documentation roots.
2. For each notebook, it extracts:
   - a title, usually from `WindowTitle`;
   - a paclet identifier inferred from the file path;
   - a preview and searchable body assembled from string literals in the notebook text.
3. The extracted records are stored in:
   - a normal SQLite table for full records;
   - an FTS5 virtual table for search.
4. Searches prefer a fast filename lookup path first:
   - if `es.exe` is available, Tungsten uses it;
   - otherwise it falls back to recursive filesystem enumeration.
5. If filename resolution does not win, Tungsten queries SQLite FTS.

This hybrid design matters:

- `es.exe` makes obvious page lookups very fast;
- SQLite FTS provides a general offline fallback;
- the indexed data remains tied to the exact local documentation installation.

### Workflow 5: FrontEnd actions

`frontend.py` is intentionally a narrow adapter rather than a broad framework.

For every supported FrontEnd action:

1. the controller builds a small Wolfram expression;
2. the expression is sent through `kernel.py` with `require_front_end=True`;
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

1. `assistant.py` resolves the requested source cell.
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
4. Python post-processes the returned assistant payload:
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

1. `wolfram_strings.py` preserves unknown backslash escapes so inline box syntax such as
   `\!\(\*GraphicsBox[...]\)` survives round-tripping.
2. `notebook.py` can structurally inspect a saved notebook cell and extract box-bearing objects from
   `BoxData[...]` or from strings that already contain inline box escapes.
3. `inline_boxes.py` turns those extracted box expressions into:
   - decoded string values;
   - canonical Wolfram string literals;
   - structured metadata for each embedded object.

This flow is intentionally kernel-free as long as the source notebook state is already saved to
disk.

### Workflow 8: Kernel-free expression parsing

The expression subsystem is separate from notebooks because the problem shape is different.

1. The caller provides source text plus an explicit form: `input`, `fullform`, or `standard`.
2. `expression_parser.py` tokenizes the input.
3. The parser applies operator precedence and Wolfram-specific surface rules to build an AST.
4. The AST is rendered back to canonical `InputForm` and `FullForm`.
5. If requested, `expression.py` runs the outer evaluation loop and delegates single-step built-in
   dispatch to `expression_evaluator.py`, which calls family modules such as
   `expression_arithmetic.py` and `expression_patterns.py`.

This subsystem does not participate in the kernel-backed architecture and is intentionally
kernel-free. Some extracted modules still depend on `expression.py` as a shared runtime facade;
that is a deliberate transitional shape that keeps imports stable while allowing parser,
dispatch, arithmetic, and pattern-matching work to proceed in separate files.

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

The module is an ergonomic projection layer. New substantive behavior should usually land in Python
first and then be surfaced in PowerShell.

### Documentation search is file-backed, not browser-backed

This preserves offline behavior and installation alignment while keeping implementation complexity
low.

## Extension points

The current architecture is intentionally open to a few natural kinds of extension.

### Extending the CLI

The usual path is:

1. add or extend a Python module under `src/tungsten/`;
2. expose it through `cli.py`;
3. add PowerShell wrappers in `pwsh/Tungsten.psm1` if the scenario benefits from them;
4. add tests;
5. add or update documentation in this docs tree.

### Extending notebook editing

If a new notebook mutation is structural and deterministic, it belongs in `notebook.py` and the
patch-spec surface rather than in opaque FE automation.

### Extending FrontEnd automation

If the action is a clean FE token or a small FE-targeted Wolfram expression, it usually belongs in
`frontend.py`. If the action requires brittle visible-window automation, Tungsten should treat it as
optional or experimental.

### Extending inert expression evaluation

New built-ins should remain explicitly enumerated and structurally defined. The architecture works
because the evaluator is honest about being narrow.

## Validation architecture

Tungsten currently validates itself at three useful levels.

### Unit and component tests

The Python test suite covers kernel-free logic and CLI shaping, including expression parsing and
evaluation behavior.

### Integration-style tests

Some tests and smoke flows exercise the real local installation and documentation state.

### End-to-end smoke script

`scripts/Test-TungstenSmoke.ps1` is the practical end-to-end validator for:

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

## What is deliberately not in the architecture

Tungsten currently does not attempt to own:

- general GUI automation beyond a small optional WinDesk-assisted surface;
- a full Wolfram runtime;
- complete box-language understanding;
- complete FrontEnd API coverage;
- semantic notebook interpretation beyond the structural editing model.

Those are not missing by accident. They are outside the current architectural scope.
