# Tungsten Notebook FrontEnd Alternatives

- Status: Recommendation report
- Audience: Tungsten maintainers and implementers
- Scope: `src/Tungsten` notebook GUI, StandardForm rendering subset, and simple `.nb` editing
- Created (UTC): 2026-04-27T17:06:48Z
- Repository HEAD: 72450c52ff291b2be07d3eee3ec5b61a1d9ffc64

## Summary

The best first Tungsten notebook FrontEnd is a Windows-first .NET desktop app that hosts a browser
surface through WebView2. It should keep `.nb` files as the canonical storage format, use Tungsten's
existing Python notebook parser and evaluator as the semantic engine, and render notebook cells in
HTML/CSS/TypeScript. This gives Tungsten a practical `WolframNB.exe`-like companion for
`tungsten.exe` without committing to reimplementing Mathematica's full FrontEnd.

The renderer should have two paths:

1. A direct StandardForm box-to-DOM renderer for the editable/canonical subset. This is the durable
   path because it preserves the Wolfram box tree and can support selection, source mapping,
   incremental editing, and `.nb` round-tripping.
2. A TeX/MathJax rendering path for fast, high-quality display of simple evaluated output. Tungsten
   already has generated-subset `TeXForm` and `MathMLForm` support, and MathJax is mature browser
   infrastructure for TeX and MathML rendering. This path is valuable, but it should not become the
   canonical notebook model because TeX is not isomorphic to Wolfram boxes.

The shortest useful product slice is:

- open and save simple `.nb` files;
- show a cell list with text, input, and output cells;
- edit plain text and input cells;
- evaluate the selected input through Tungsten's evaluator;
- insert or replace the corresponding output cell;
- render a StandardForm subset including rows, fractions, roots, scripts, strings, symbols, calls,
  lists, rules, and associations;
- fall back to InputForm text when the renderer cannot represent an expression.

VS Code notebooks, Jupyter, Electron, Tauri, Avalonia, and a localhost browser app are all viable in
particular niches. They are less suitable than WebView2 as the primary answer if the goal is a small,
native-feeling Windows executable that sits beside `tungsten.exe`.

## Decision Frame

Wolfram notebooks are not just rich text documents. The official low-level notebook documentation
describes notebooks as symbolic expressions, with structural heads such as `Notebook`, `Cell`, and
`CellGroupData` rather than a word-processor file format. Box expressions are the FrontEnd-facing
display layer produced by functions such as `MakeBoxes[expr, form]`. Tungsten already has partial
support for this world: it parses notebooks structurally, extracts box expressions, evaluates an
offline expression subset, and can generate StandardForm boxes, TeX strings, and MathML strings for
some expressions.

The FrontEnd decision is therefore two decisions:

- what application shell hosts the notebook editor;
- what rendering/editing model maps Wolfram box expressions to pixels and back.

The shell can be relatively conventional. The renderer is where most long-lived complexity lives.

## Current Tungsten Assets

The current codebase gives a future GUI several unusually useful foundations:

- `src/tungsten/notebook.py` parses, inspects, renders, patches, and saves `.nb` notebooks without a
  Wolfram kernel. It preserves unknown raw notebook items and supports structured cell operations.
- `NotebookDocument`, `NotebookCell`, `NotebookGroup`, and `NotebookRawItem` already provide a useful
  document model boundary.
- `extract_box_expressions()` can find top-level `BoxData[...]` and inline boxes.
- `src/tungsten/expression.py` includes a kernel-free parser/evaluator plus generated-subset
  StandardForm boxes.
- The expression docs list current box support for `RowBox`, `FractionBox`, `SqrtBox`,
  `RadicalBox`, `SuperscriptBox`, `SubscriptBox`, `SubsuperscriptBox`, over/under boxes, wrappers
  such as `BoxData`, `FormBox`, `StyleBox`, `TagBox`, `TooltipBox`, and `InterpretationBox`, and
  reconstruction of common `RowBox` shapes.
- `TeXForm` and `MathMLForm` output exist today for a generated subset.
- `src/Tungsten/dotnet/Tungsten.DotNet` already contains a typed .NET client over the JSON CLI.
- `src/Tungsten/dotnet/Tungsten.Console` already provides the `tungsten.exe` launcher.

The important gaps are:

- no persistent JSON evaluator/server protocol for GUI sessions;
- no notebook DTO that carries enough editable cell content, box trees, source ranges, and dirty
  state for a rich GUI;
- no renderer for StandardForm boxes;
- no policy for output-cell replacement, cell labels, grouped input/output pairs, cancellation, or
  long-running evaluation;
- no file-watch and external-change reconciliation story.

These gaps are tractable. They argue for adding a thin protocol layer before investing in elaborate
UI behavior.

## Product Envelope

### In Scope

The first FrontEnd should support:

- opening `.nb` files that Tungsten can parse today;
- showing cell groups and common styles such as `Title`, `Section`, `Text`, `Input`, `Output`, and
  `Message`;
- editing simple text cells and input cells;
- adding, deleting, moving, and changing the style of cells;
- evaluating one input cell or all input cells in order;
- showing generated output cells;
- saving back to `.nb` while preserving untouched raw cells as much as possible;
- rendering a reasonable StandardForm subset;
- keyboard-driven cell navigation, evaluation, and insertion;
- diagnostics when a cell, box, or expression is outside the supported subset.

### Out of Scope

The first FrontEnd should not attempt:

- full Mathematica stylesheet semantics;
- arbitrary FrontEnd tokens;
- `DynamicModule`, `Manipulate`, full notebook interactivity, or live controls;
- full `GraphicsBox` rendering;
- custom notation packages;
- full two-dimensional math editing parity with WolframNB;
- cloud collaboration or multi-user editing;
- automatic execution of notebook initialization code on open.

These are not permanently excluded; they are simply beyond the right first boundary.

## Renderer Strategies

### R1. Direct StandardForm Box-to-DOM Renderer

This renderer takes Tungsten's box expressions as the canonical display tree and maps them to HTML
elements. `RowBox` becomes horizontal inline layout. `FractionBox` becomes a two-row fraction layout.
`SqrtBox`, `RadicalBox`, script boxes, strings, symbols, lists, rules, and associations get explicit
DOM templates and CSS.

This is the recommended durable renderer.

Strengths:

- preserves the Wolfram box tree instead of passing through a lossy format;
- can attach DOM nodes to source box nodes for selection and diagnostics;
- can support round-trip editing for the supported subset;
- keeps unsupported boxes visible as structured fallback nodes rather than silently dropping meaning;
- aligns with Wolfram's own `MakeBoxes`/box-language boundary.

Costs:

- requires a small math layout engine, even for the supported subset;
- needs careful CSS baselines for fractions, radicals, and nested scripts;
- needs golden rendering tests to prevent visual regressions;
- will not match WolframNB exactly for all spacing and typography.

Recommended scope:

- implement display first;
- then support structural edits for a narrow box subset;
- keep raw input editing available for every expression so users are never trapped by renderer limits.

### R2. Generated TeX Plus MathJax

This path converts an evaluated expression to TeX, sends the TeX string to the web surface, and lets
MathJax render it. MathJax supports TeX and MathML input and browser outputs such as CommonHTML and
SVG. Tungsten already has generated-subset `TeXForm`; the Wolfram Language also treats `TeXForm` as
the conventional export/display form for TeX.

This option is important enough to include in the first implementation.

Strengths:

- very good visual quality for common mathematical output;
- fast to integrate in a browser UI;
- lets Tungsten benefit from MathJax's layout, fonts, accessibility work, and browser compatibility;
- gives pleasant output for fractions, powers, roots, sums, integrals, Greek letters, and many
  conventional math forms;
- also works in a localhost browser prototype before the desktop shell exists.

Costs:

- TeX is not a faithful notebook model. Many different Wolfram expressions can produce the same TeX.
- MathJax rendering is display-oriented; editing rendered MathJax does not naturally produce
  Wolfram boxes or `.nb` syntax.
- Wolfram boxes carry wrappers, interpretation, tagging, style, tooltips, and FrontEnd metadata that
  are not generally represented by TeX.
- Generated TeX needs escaping, trust-boundary rules, and fallback behavior.
- TeX layout and Wolfram StandardForm layout will differ in visible details.

Recommended use:

- use MathJax for evaluated output display in the first product slice;
- use it as a fallback renderer when direct box rendering is not available yet;
- store canonical output as Wolfram boxes or InputForm-like expressions in `.nb`, not as TeX-only
  cells unless the cell is explicitly a text/TeX artifact;
- add a renderer payload that can carry all useful forms at once:

```json
{
  "inputForm": "Plus[1, x]",
  "standardBoxes": {"head": "RowBox", "items": ["x", "+", "1"]},
  "tex": "x+1",
  "mathml": "<math>...</math>",
  "messages": []
}
```

This keeps MathJax in the system as a rendering accelerator rather than a semantic bottleneck.

### R3. MathML Rendering

MathML is more structured than TeX and MathJax can consume it. Tungsten already has generated-subset
`MathMLForm`, and modern browser/math stacks understand MathML better than they did historically.

Strengths:

- more tree-shaped than TeX;
- a closer fit for generated semantic payloads;
- useful for accessibility and interchange experiments.

Costs:

- still not equivalent to Wolfram boxes;
- less pleasant for hand editing than TeX;
- browser-native MathML support and MathJax behavior may differ enough to need testing;
- does not by itself solve notebook selection and source mapping.

Recommended use:

- include MathML in renderer diagnostics and experimentation;
- do not choose MathML as the primary editable notebook model.

### R4. Canvas or SVG Custom Renderer

A custom renderer can draw boxes to Canvas or SVG and control every pixel.

Strengths:

- precise layout control;
- future path for graphics-heavy or high-performance rendering;
- possible to reuse generated SVG snapshots in exports.

Costs:

- much harder text selection, caret movement, accessibility, copy/paste, and incremental editing;
- more implementation burden than DOM/CSS for notebook cells;
- higher test burden for multiple DPI scales and fonts.

Recommended use:

- reserve for specific future needs such as `GraphicsBox` or snapshot export;
- do not use as the main notebook renderer.

## Application Shell Alternatives

### A. .NET Desktop Host With WebView2

This is the recommended primary path. The app would be a new Tungsten desktop project, for example
`Tungsten.Notebook`, using WPF or WinUI as the native shell and WebView2 as the notebook surface.
WebView2 is Microsoft's supported way to embed web technologies in native Windows apps, backed by
the Microsoft Edge rendering engine. It also has documented bridges between native and web code,
including message passing and host objects.

Why this fits Tungsten:

- Windows-first matches Tungsten's current Wolfram automation assumptions.
- The repo already has a .NET wrapper boundary around the Python CLI.
- Web technologies are the right substrate for CodeMirror, MathJax, HTML/CSS box rendering, and
  Playwright screenshot tests.
- The app can still feel native: open/save dialogs, recent files, menus, process lifetime,
  single-instance behavior, file associations, and packaged `tungsten.exe` discovery all belong in
  the native host.
- WebView2 packaging can use either the Evergreen Runtime or a fixed WebView2 runtime, depending on
  distribution goals.

Recommended shape:

- native host: WPF or WinUI, C#/.NET;
- bridge: `chrome.webview.postMessage` style messages or host objects;
- web UI: TypeScript, Vite or equivalent bundler;
- cell source editor: CodeMirror 6;
- math display: direct box-to-DOM renderer plus MathJax fallback;
- optional rich text: defer ProseMirror until text cells need more than plain text plus inline boxes.

Main risks:

- lifecycle coordination between native app, WebView2, and the Python evaluator;
- renderer test coverage;
- keeping the host/web bridge small enough that notebook semantics stay in Tungsten, not in ad hoc UI
  callbacks.

### B. Localhost Browser App

This path starts a local HTTP server and opens the user's browser. The backend can be Python, .NET,
or Node. It is the quickest way to validate UI ideas and renderer behavior.

Strengths:

- minimal desktop packaging;
- easiest path for a prototype;
- excellent compatibility with CodeMirror, MathJax, Playwright, and browser dev tools;
- backend can call the existing Python modules directly.

Costs:

- less like a `WolframNB.exe` companion;
- file-open/save ergonomics are weaker;
- browser profile state and localhost port management leak into the user experience;
- process lifetime and multiple-window behavior are awkward;
- local web security boundaries still need care because notebooks are untrusted input.

Recommended use:

- build an early prototype this way only if it substantially accelerates renderer iteration;
- keep the protocol and frontend code portable to WebView2 so the prototype does not become a
  separate product.

### C. Electron

Electron packages Chromium and Node with the application. It is a proven route for sophisticated
cross-platform editors, and Monaco/CodeMirror/MathJax integration is straightforward.

Strengths:

- consistent Chromium runtime on every platform;
- mature packaging and auto-update ecosystem;
- strong web development tooling;
- many examples of editor-heavy apps.

Costs:

- larger binary payload than WebView2;
- duplicates a browser runtime on Windows where Edge/WebView2 already exists;
- introduces Node/Electron security and packaging concerns;
- does not add much value for Tungsten's current Windows-first scope.

Recommended use:

- reconsider if Tungsten explicitly becomes cross-platform desktop software;
- otherwise prefer WebView2.

### D. Tauri

Tauri uses a web frontend with a Rust backend and the system webview. It is lighter than Electron and
can produce compact native apps.

Strengths:

- smaller application payload than Electron;
- good for web-fronted desktop apps;
- strong security posture when configured carefully.

Costs:

- adds Rust as a required implementation language and build toolchain;
- less aligned with the existing Tungsten .NET wrapper;
- Windows WebView2 still sits underneath on Windows, so a direct .NET/WebView2 app is simpler here.

Recommended use:

- not the first choice unless Tungsten wants a Rust desktop layer for other reasons.

### E. Native WPF or Avalonia Renderer

A purely native .NET UI can be built in WPF, WinUI, or Avalonia. Avalonia is attractive for
cross-platform .NET UI, and WPF is very mature on Windows.

Strengths:

- native .NET development;
- direct integration with existing C# projects;
- good platform menus, dialogs, commands, and accessibility primitives;
- no embedded browser surface.

Costs:

- math layout, source editing, rich text editing, HTML-like flow layout, and screenshot testing all
  become harder;
- CodeMirror, MathJax, and browser CSS cannot be used directly;
- building a good two-dimensional box editor in native controls is a substantial renderer project.

Recommended use:

- use native WPF/WinUI for the shell if WebView2 is selected;
- do not build the notebook surface as pure native controls in the first implementation.

### F. VS Code Notebook Extension

VS Code has Notebook APIs for serializers, renderers, and controllers. A Tungsten extension could
open Wolfram notebooks, execute cells, and render custom outputs inside VS Code.

Strengths:

- excellent editor infrastructure;
- users get source control, search, command palette, tabs, and settings for free;
- notebook controller/renderer concepts fit evaluation and display;
- good extension distribution story for developer users.

Costs:

- not a standalone `WolframNB.exe` analogue;
- VS Code notebook documents are not `.nb` documents, so a custom serializer must preserve Wolfram
  notebook structure carefully;
- rich Wolfram box editing remains custom work;
- less approachable for users who want a simple dedicated Tungsten app.

Recommended use:

- good secondary integration after the core protocol and renderer exist;
- not the primary FrontEnd for this request.

### G. Jupyter Frontend or Kernel

Jupyter notebooks use a JSON `.ipynb` format with cells, metadata, and outputs, plus a mature
client/kernel messaging protocol. A Tungsten Jupyter kernel would be useful for Python-centric
workflows.

Strengths:

- mature notebook UI ecosystem;
- established execution protocol;
- many renderers and exporters;
- easy sharing with data-science tooling.

Costs:

- `.ipynb` is not `.nb`;
- preserving Wolfram notebook structure requires a translation layer;
- StandardForm boxes still require a custom renderer or TeX/MathJax fallback;
- Jupyter cell/output semantics differ from Wolfram notebook grouping and styles.

Recommended use:

- consider a separate `tungsten-jupyter` integration;
- do not use Jupyter as the main `.nb` editor.

### H. Existing Wolfram-Like Projects

Several existing projects are useful reference points:

- WLJS Notebook is a JavaScript-oriented notebook frontend for Wolfram workflows.
- Mathics and Mathics Web are open-source Wolfram-like evaluator and web UI projects.
- WolframLanguageForJupyter shows how Wolfram Language evaluation can fit into Jupyter.

These projects are worth studying for UI conventions, protocols, and rendering ideas. They should
not be adopted wholesale as Tungsten's main FrontEnd because Tungsten has a different evaluator,
storage target, and repository-local integration story.

## Recommended Architecture

The recommended architecture is:

```text
Tungsten.Notebook.exe
  Native shell: WPF or WinUI
  Web surface: WebView2
  Bridge: JSON messages
  Backend client: Tungsten.DotNet
        |
        v
  tungsten session process
        |
        v
  Python modules: notebook.py, expression.py, evaluator state
```

The web surface owns presentation and interaction:

- notebook outline and cell list;
- CodeMirror editors for source-like text;
- DOM/CSS StandardForm renderer;
- MathJax rendering for TeX/MathML payloads;
- diagnostics and unsupported-box placeholders;
- keyboard command routing.

The native host owns OS integration:

- menus, commands, window state, recent files;
- open/save dialogs and file watching;
- WebView2 lifecycle;
- evaluator process lifecycle;
- trusted bridge methods;
- packaging and app identity.

The Python/Tungsten layer owns notebook semantics:

- parse and render `.nb`;
- preserve raw unknown structures;
- evaluate expressions;
- generate output forms;
- validate patch operations;
- maintain session state.

## Protocol Additions

The current CLI is good for automation, but a GUI should avoid rebuilding state on every command.
Add a persistent JSON-over-stdio session process with a small protocol. This can live under the
existing `python -m tungsten` entry point without changing the current commands.

Recommended commands:

```json
{"id": 1, "method": "notebook.open", "params": {"path": "C:/work/example.nb"}}
{"id": 2, "method": "notebook.patch", "params": {"documentId": "doc-1", "patch": []}}
{"id": 3, "method": "notebook.save", "params": {"documentId": "doc-1"}}
{"id": 4, "method": "evaluate.cell", "params": {"documentId": "doc-1", "cellId": "cell-7"}}
{"id": 5, "method": "expr.render", "params": {"expr": "Plus[1, x]", "forms": ["boxes", "tex", "mathml"]}}
{"id": 6, "method": "session.cancel", "params": {"evaluationId": "eval-2"}}
```

The notebook-open response should contain a UI-oriented DTO rather than only an inspection table:

```json
{
  "documentId": "doc-1",
  "path": "C:/work/example.nb",
  "cells": [
    {
      "cellId": "cell-1",
      "path": [0, 2],
      "expressionUuid": "...",
      "cellIdOption": 123,
      "style": "Input",
      "contentKind": "boxData",
      "sourceText": "BoxData[RowBox[{\"1\", \"+\", \"x\"}]]",
      "plainText": "1 + x",
      "boxTree": {"head": "RowBox", "items": ["1", "+", "x"]},
      "options": {"CellLabel": "In[1]:="},
      "raw": false,
      "diagnostics": []
    }
  ]
}
```

This DTO should be deliberately redundant. A GUI needs raw source, plain text, parsed boxes, stable
identity, and diagnostics at the same time.

## Notebook Persistence Policy

The `.nb` file should remain canonical. The GUI should avoid rewriting the whole file when only a
few cells changed. Tungsten already preserves raw structures; the GUI should build on that.

Recommended rules:

- preserve untouched cell raw text when possible;
- patch changed cells structurally;
- generate new `ExpressionUUID` values for inserted cells unless the caller supplies one;
- keep unsupported cells visible and movable, but not structurally rewritten;
- never execute notebook code on open;
- show unsupported parse/render states as diagnostics, not silent data loss;
- save through Tungsten's notebook renderer, not through browser-side string concatenation.

## Evaluation Flow

A basic input-cell evaluation should work like this:

1. The user edits an `Input` cell.
2. The UI sends the source expression to the session process.
3. The evaluator updates the session state, including `$Line`, `In`, `Out`, `%`, and definitions.
4. The evaluator returns a payload with InputForm, StandardForm boxes, TeX, MathML, messages, and
   diagnostic metadata where available.
5. The notebook model inserts or replaces the following `Output` cell.
6. The UI renders the output through direct boxes when supported, MathJax when useful, and text
   fallback otherwise.

Persistent session state matters. A GUI that shells out to a fresh process per cell would be easier
to build but would not feel like a notebook because definitions and output history would disappear.

## Editing Model

The first implementation should provide three editing modes:

- source editing for input cells through CodeMirror;
- plain text editing for text-like cells;
- display-only rendering for output boxes, with copy and inspect commands.

Two-dimensional box editing can be added incrementally:

- click a box-rendered expression and reveal its source expression;
- support structural edits for simple leaf boxes;
- support wrapper-preserving edits for `FractionBox`, script boxes, and `SqrtBox`;
- keep a source editor escape hatch for every rendered expression.

This keeps the first GUI convenient without forcing Tungsten to solve the entire Wolfram box editor
problem before users can benefit from it.

## Frontend Library Choices

Recommended first choices:

- CodeMirror 6 for source/input cells. It is designed as an embeddable browser editor component with
  an extension system, and it is lighter to place in many notebook cells than Monaco.
- MathJax for TeX and MathML display. It supports the input formats Tungsten can already generate
  and runs directly in the WebView2/browser surface.
- Plain TypeScript components for cells and box rendering. Avoid a large framework until the desired
  interaction model is clearer.
- Playwright screenshot tests for renderer and layout regression checks.

Libraries to defer:

- Monaco, unless Tungsten wants VS Code-like language-service behavior inside each cell.
- ProseMirror, unless text cells need serious rich-text editing rather than plain text with inline
  boxes.
- MathLive, unless interactive math entry becomes a priority. It is promising for TeX-oriented math
  input, but it does not solve Wolfram box round-tripping by itself.

## Security and Trust Boundary

Opening notebooks should be treated like opening code, not like opening inert documents.

Rules:

- no automatic evaluation on open;
- WebView2 bridge exposes only a small allowlisted API;
- notebook content is rendered as data, never injected as trusted HTML;
- TeX/MathJax input is escaped and configured conservatively;
- external links and file paths require explicit user action;
- persistent evaluator processes are tied to a document/window and are terminated predictably;
- save operations go through native dialogs or trusted host methods, not arbitrary browser file
  writes.

This is especially important because notebook cells can contain strings, boxes, and expressions that
look like UI markup but are actually untrusted document content.

## Validation Strategy

Validation should cover both document semantics and pixels:

- unit tests for notebook DTO generation from representative `.nb` fixtures;
- round-trip tests that unchanged cells preserve raw source;
- patch tests for insert, replace, delete, style changes, and output replacement;
- expression tests for StandardForm boxes, TeX, and MathML payloads;
- renderer golden tests for each supported box head;
- Playwright screenshots at desktop and narrow viewport sizes;
- copy/paste tests for source text and rendered output;
- save/reopen tests with WolframNB where available;
- malformed notebook fixtures that must show diagnostics instead of crashing or losing content.

The renderer fixture set should start with small expressions:

- `1 + x`;
- `x^2 + 1`;
- `(a + b)/(c + d)`;
- `Sqrt[x^2 + y^2]`;
- `Subscript[x, i]`;
- `x -> y`;
- `{1, x, x^2}`;
- `<|"a" -> 1, "b" -> x|>`;
- `f[x, y + z]`;
- nested fractions and scripts.

## Implementation Slices

The work can be staged by artifact count rather than calendar estimates.

### Slice 1: Usable Notebook Viewer and Evaluator

Artifacts:

- one desktop or localhost shell;
- one notebook-open DTO;
- one cell-list UI;
- CodeMirror-backed input editing;
- MathJax output rendering from TeX;
- save support for edited simple text/input cells;
- direct text fallback for unsupported cells.

This slice validates the user experience quickly while relying on MathJax for pleasant output.

### Slice 2: Persistent Session Protocol

Artifacts:

- one JSON-over-stdio session mode;
- request/response IDs and error payloads;
- document-open/save/patch commands;
- evaluate-cell command;
- cancellation command;
- .NET client methods for the new protocol.

This slice makes the GUI behave like a notebook instead of a sequence of isolated command runs.

### Slice 3: Direct StandardForm Renderer

Artifacts:

- TypeScript box AST types;
- renderer implementations for the supported box heads;
- CSS baseline and nesting rules;
- unsupported-box placeholders;
- golden renderer fixtures;
- Playwright screenshot checks.

This slice moves the canonical output path away from TeX and toward notebook-faithful boxes.

### Slice 4: Editing and Notebook Ergonomics

Artifacts:

- cell insertion/deletion/move commands;
- style picker for common cell styles;
- input/output grouping behavior;
- dirty-state and external-change handling;
- find-in-notebook;
- basic inspector for raw cell expression and options;
- initial structural edits for simple rendered boxes.

This slice makes the tool comfortable for day-to-day simple notebook work.

## Recommendation

Build `Tungsten.Notebook.exe` as a .NET/WebView2 app with a TypeScript notebook surface. Use
CodeMirror for source editing, MathJax for the first high-quality rendered output path, and a direct
StandardForm box-to-DOM renderer as the canonical long-term rendering/editing path.

Do not make TeX/MathJax the only model. It is excellent as display infrastructure and as a low-cost
first renderer, but it cannot preserve all of the information carried by Wolfram boxes. The internal
contract should be "Tungsten owns expressions and boxes; MathJax helps paint some of them."

Do not start with a pure native renderer, Jupyter, or VS Code as the primary app. Those paths are
useful future integrations or experiments, but they do not best match the requested
`WolframNB.exe`-to-`wolfram.exe` relationship.

## References

- Wolfram Research, [Low-Level Notebook Structure](https://reference.wolfram.com/language/guide/LowLevelNotebookStructure.html).
- Wolfram Research, [MakeBoxes](https://reference.wolfram.com/language/ref/MakeBoxes.html).
- Wolfram Research, [TeXForm](https://reference.wolfram.com/language/ref/TeXForm.html).
- Wolfram Research, [MathMLForm](https://reference.wolfram.com/language/ref/MathMLForm.html).
- Microsoft, [Introduction to Microsoft Edge WebView2](https://learn.microsoft.com/en-us/microsoft-edge/webview2/).
- Microsoft, [Distribute your app and the WebView2 Runtime](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution).
- Microsoft, [Call native-side code from web-side code](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/hostobject).
- Microsoft, [Communication between host and web content](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/communicate-btwn-web-native).
- CodeMirror, [CodeMirror](https://codemirror.net/).
- Microsoft, [Monaco Editor](https://microsoft.github.io/monaco-editor/).
- ProseMirror, [ProseMirror](https://prosemirror.net/).
- MathJax, [MathJax Documentation](https://docs.mathjax.org/en/latest/).
- MathJax, [TeX and LaTeX Input](https://docs.mathjax.org/en/latest/input/tex/index.html).
- MathJax, [Output Formats](https://docs.mathjax.org/en/latest/output/index.html).
- MathLive, [MathLive Mathfield](https://mathlive.io/mathfield/).
- KaTeX, [Supported Functions](https://katex.org/docs/supported).
- Electron, [Electron Documentation](https://www.electronjs.org/docs/latest/).
- Tauri, [Tauri v2 Documentation](https://v2.tauri.app/start/).
- Avalonia, [Avalonia Documentation](https://docs.avaloniaui.net/).
- Microsoft, [Blazor Hybrid](https://learn.microsoft.com/en-us/aspnet/core/blazor/hybrid/).
- Visual Studio Code, [Notebook API](https://code.visualstudio.com/api/extension-guides/notebook).
- Visual Studio Code, [Notebook Kernel](https://code.visualstudio.com/api/extension-guides/notebook-kernel).
- Visual Studio Code, [Notebook Renderer](https://code.visualstudio.com/api/extension-guides/notebook-renderer).
- Jupyter, [The Jupyter Notebook Format](https://nbformat.readthedocs.io/en/latest/format_description.html).
- Jupyter Client, [Messaging in Jupyter](https://jupyter-client.readthedocs.io/en/latest/messaging.html).
- JupyterLab, [Extension Developer Guide](https://jupyterlab.readthedocs.io/en/stable/extension/extension_dev.html).
- WLJS Notebook, [Documentation](https://jerryi.github.io/wljs-docs/).
- Mathics, [Mathics](https://mathics.org/).
- Mathics Web, [Mathics Web](https://mathics3.github.io/mathics-web/).
- Wolfram Research, [WolframLanguageForJupyter](https://github.com/WolframResearch/WolframLanguageForJupyter).
