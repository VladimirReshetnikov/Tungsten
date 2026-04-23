# Tungsten Implementation Details

Created (UTC): 2026-04-23T02:16:55Z
Updated (UTC): 2026-04-23T17:10:29Z
Repository HEAD: 67ad70b3bea14aa14a093684a3b033a53ca14d9e

## Summary

This document records the machine findings, engineering choices, and reasoning that shaped
Tungsten's current implementation. It is intentionally more specific than the architecture guide.
Where the architecture document says "what the layers are," this document answers questions like:

- why Tungsten executes through `wolfram.exe` instead of a different local surface;
- why notebook editing is structural instead of semantic;
- why the default Notebook Assistant backend is the hidden chat-notebook flow;
- why the expression subsystem is separated from notebook parsing;
- why some outputs are returned as strings even when they represent rich Wolfram objects.

## Machine findings that materially shaped the design

### 1. This machine has a real, usable Wolfram installation

The target environment includes a real Wolfram 14.3 installation with the important executables and
assets Tungsten needs:

- `wolfram.exe`
- `WolframKernel.exe`
- `WolframNB.exe`
- `wolframscript.exe`
- the shared documentation notebook corpus
- the bundled `WolframClientForPython` source tree

That justified building a real automation framework around the installation rather than a
notebook-only utility or a mock layer.

### 2. The local `mathpass` is the key operational wrinkle

The most important machine-specific finding was that the installed `mathpass` contains duplicate
license entries. Using that raw file directly can cause command-line evaluation failures. A
deduplicated copy works.

This finding moved from "one weird local hack" to "core Tungsten behavior." As a result:

- Tungsten never mutates the machine-wide installed `mathpass`;
- Tungsten always inspects the discovered file;
- Tungsten always materializes a temporary deduplicated copy before kernel execution;
- kernel result payloads surface the inspection data so callers can see what happened.

### 3. The bundled Wolfram Python client exists but is not the best runtime substrate here

The installation contains `WolframClientForPython`, which is useful reference material and could be
tempting as a runtime dependency. In practice, its higher-level evaluation surface pulls in
dependencies that are not reliably present on this machine, such as `oauthlib`.

That made it a poor default dependency for a repository-local tool whose job is to be dependable on
this machine today. Tungsten therefore:

- treats the bundled client tree as contextual reference;
- does not depend on it for core execution;
- uses the documented command-line Wolfram entrypoints instead.

### 4. `UsingFrontEnd[...]` is good enough to support real FE automation

Once Tungsten supplies a deduplicated password file, kernel-side FE automation works on this
machine. That unlocked the design of:

- `frontend.py`;
- Notebook Assistant automation through a helper kernel script;
- documentation opening through `NotebookLocate`;
- token execution through `FrontEndTokenExecute`.

Without that capability, Tungsten would have had to lean much harder on visible desktop automation.

### 5. `es.exe` is a meaningful local performance win

The Everything CLI tool is present on this machine and is extremely effective for filename-oriented
documentation lookup. Tungsten uses it opportunistically in `docs_index.py` for fast path
resolution before falling back to recursive traversal or SQLite FTS.

This is exactly the kind of machine-local affordance Tungsten is designed to exploit.

## Why Tungsten executes through `wolfram.exe`

Several candidate execution surfaces were available:

- `wolfram.exe`
- `WolframKernel.exe`
- `wolframscript.exe`
- the bundled Python client

The current default is `wolfram.exe -noprompt -script`.

### Why this choice won

- It is present in the discovered installation.
- It is close to the real runtime rather than being a high-level wrapper with extra dependency
  assumptions.
- It works well with temporary script files and temporary result files.
- It gives Tungsten predictable control over the exact script it is running.
- It plays well with the deduplicated `-pwfile` workaround.

### Why Tungsten does not primarily use `wolframscript.exe`

`wolframscript.exe` is valuable and present, but on this machine it was not the most reliable
evaluation path under the raw licensing state. Tungsten needed a substrate it could control more
explicitly.

### Why Tungsten does not primarily use `WolframKernel.exe`

The current implementation already achieves the needed behavior through `wolfram.exe`, and there
was no compelling reason to add a second kernel-launch strategy. One consistent execution path is
preferable unless a future requirement forces broader launcher support.

## Why kernel execution is wrapper-script based

The wrapper script is a central implementation decision.

### The problem it solves

Naively running arbitrary Wolfram code and reading stdout is not good enough for Tungsten's goals.
Callers need to know:

- did the process launch?
- did the Wolfram evaluation parse?
- did it semantically succeed?
- what was the result?
- what were the messages?
- what was printed?
- what timing metadata exists?

Mixed terminal output is too ambiguous for that.

### The wrapper design

`kernel.py` writes a script that:

- imports the user code from disk;
- parses it with `ToExpression[..., HoldComplete]`;
- optionally wraps it in `UsingFrontEnd[...]`;
- evaluates it via `EvaluationData[...]`;
- captures `Print` output by temporarily rebinding `Print`;
- stringifies result and metadata into JSON-safe fields;
- exports a `RawJSON` payload to a result file.

### Why `HoldComplete` is used during parsing

Tungsten wants a clear separation between "the input text parsed" and "the evaluation ran." Parsing
under `HoldComplete` allows Tungsten to report parse failure deterministically before evaluation.

### Why results are stringified instead of deeply serialized

Arbitrary Wolfram expressions, FE objects, graphics, and symbolic constructs do not map cleanly
onto JSON. Attempting to coerce them into a fake Python object model would create a lot of fragile
special cases.

Tungsten instead returns:

- `result` as an `InputForm` string;
- `result_head` as an `InputForm` string;
- lists of stringified messages and printed output;
- numeric timing fields when they are naturally numeric.

This is less magical and more robust.

## Why notebook editing is structural rather than semantic

Notebook files are ordinary Wolfram expressions, but using the full Wolfram parser as a requirement
for notebook editing would erase one of Tungsten's most useful properties: it can work on notebook
files even when the kernel is unavailable.

### Scope of the structural parser

`notebook.py` is intentionally focused on:

- strings;
- nested comments;
- bracket balancing;
- splitting top-level expressions;
- identifying `Notebook[...]`;
- identifying `Cell[...]`;
- identifying `Cell[CellGroupData[...]]`.

That is enough to support:

- notebook inventory and flattening;
- extracting selectors such as `ExpressionUUID`, `CellID`, and `CellTags`;
- title and option inspection;
- deterministic cell insertion, append, and replacement.

### Raw preservation strategy

Notebook nodes preserve their original raw text when possible. If Tungsten edits a structure, it
regenerates the affected region and clears raw caches only where needed.

This is important because it keeps unrelated notebook text stable and avoids unnecessary churn.

### Why notebook and expression parsing are separate

The notebook parser is optimized for resilience on notebook files. The expression parser is
optimized for operator precedence, implicit multiplication, `Part` syntax, spans, and canonical
rendering. Combining them would make both more complicated and less trustworthy.

## Why inline-box string handling lives in shared string utilities

The inline-box feature exposed a foundational issue: Tungsten's older string literal parsers would
drop the leading backslash on unknown escape sequences. That was survivable for many ordinary
strings, but it is wrong for Wolfram strings that intentionally contain inline box escapes such as:

- `\!`
- `\(`
- `\*`
- `\)`

Those escapes are exactly how Mathematica stores embedded notebook objects inside strings.

### Why this was fixed centrally

Both `notebook.py` and `expression.py` parse Wolfram string literals. Fixing only one of them would
have left Tungsten inconsistent and fragile. The new shared `wolfram_strings.py` module therefore
owns:

- Wolfram string literal escaping;
- Wolfram string literal parsing;
- inline-box escape segmentation;
- display-oriented placeholder rendering for notebook previews.

That keeps every Tungsten subsystem aligned on the same string semantics.

### Why notebook-cell extraction is kernel-free

For saved notebooks, the relevant object is already present in the notebook expression text. That
means Tungsten can often extract the needed `GraphicsBox[...]`, `StyleBox[...]`, `TemplateBox[...]`,
or similar object directly from the saved cell expression without launching a kernel or FrontEnd.

That approach has several advantages:

- it is faster;
- it is more testable;
- it works in the same kernel-free workflows as notebook inspection and patching;
- it avoids mixing a fundamentally file-structural feature into the FE automation layer.

The current implementation therefore extracts box-bearing objects from:

- top-level `BoxData[...]` contents;
- inline box escapes already embedded inside strings in the selected cell.

## Why the expression subsystem exists and why it is intentionally narrow

The request for a kernel-free expression parser was justified, but trying to fully reproduce
Wolfram semantics locally would have been a trap.

### What the subsystem is for

`expression.py` exists to support:

- parsing FullForm, InputForm, and a pragmatic StandardForm subset with semantic lowering for
  common notebook boxes such as `FractionBox`, `SqrtBox`, `RadicalBox`, and `SuperscriptBox`;
- structural inspection;
- canonical rendering;
- a small set of structural built-ins for inert evaluation.

### Why the evaluator is deliberately small

Only a small built-in subset is implemented:

- `Length`
- `Depth`
- `Head`
- `Part`
- `Extract`
- `Level`

Everything else remains inert. This is a feature, not a limitation accidentally left undocumented.
It keeps behavior predictable and keeps Tungsten honest about what is and is not kernel evaluation.

### Why StandardForm support is only a subset

Box language and full StandardForm surface syntax are large topics. The practical requirement here
was a deterministic subset that is useful for scripts, docs, notebook inspection, and code
examples. Tungsten now lowers a few high-value semantic boxes plus their common wrappers, but it
still deliberately stops far short of full notebook box reconstruction.

## Why documentation indexing is notebook-backed and SQLite-backed

The obvious alternative to local indexing would have been:

- online documentation lookup;
- browser automation;
- or remote search.

Tungsten deliberately avoids those as the primary path.

### What the current index buys us

- offline operation;
- exact alignment with the installed documentation version and any local update paclets;
- local search without FE startup;
- deterministic records that can be consumed from Python and PowerShell.

### Why SQLite FTS5

SQLite is already available, reliable, and a good fit for a local single-user index. FTS5 provides:

- ranking;
- snippets;
- incremental query support;
- no extra service dependency.

### Why there is also a filename fast path

Many documentation lookups are effectively "find `NotebookGet.nb`" rather than "search the body
text semantically." Using `es.exe` for that common case makes the experience dramatically faster.

### Why the extracted text is approximate

Documentation notebooks contain a lot of UI scaffolding and non-content strings. Tungsten filters
obvious noise, but the resulting text is still an approximation of the notebook's semantic content.
That tradeoff is acceptable because the index is meant for discovery and retrieval, not polished
rendering.

## Why FrontEnd automation is intentionally selective

It would be easy to let FrontEnd automation sprawl into a grab-bag of arbitrary UI-driving code.
Tungsten deliberately does not do that.

### What is currently considered in-scope

- FE availability probing;
- notebook open;
- documentation open;
- arbitrary FE-targeted Wolfram code;
- token execution.

### Why the surface is narrow

- These operations have clear Wolfram-language representations.
- They fit cleanly on top of the kernel runner.
- They are useful for automation without requiring a full general-purpose desktop automation
  framework.

For anything more UI-fragile, Tungsten prefers to be explicit about optionality and experimental
status.

## Why Notebook Assistant defaults to the hidden chat-notebook path

This was one of the most important product-level design choices.

### The obvious human workflow

A human user naturally:

1. clicks a cell;
2. opens the inline assistant;
3. types a question;
4. sees the answer in the attached assistant UI;
5. copies or inserts code manually.

That is easy in the GUI and not inherently easy for automation.

### Why the visible inline assistant was not a good default

The inline popup is transient FE state. It is excellent for a person but awkward for a script:

- the assistant lives in visible UI state rather than in a stable file artifact;
- state discovery is harder;
- response harvesting is fragile;
- desktop focus and input assumptions become part of the workflow.

### Why the hidden chat-notebook backend works better

The current default instead:

1. resolves the source cell structurally from the notebook file;
2. creates a temporary hidden Chatbook notebook;
3. asks the built-in assistant through Wolfram code;
4. returns a serialized `ChatObject` string;
5. extracts the assistant text in Python;
6. extracts fenced Wolfram code blocks;
7. reinserts them below the source cell in a deterministic second step.

This preserves the "use the built-in assistant" requirement while giving Tungsten a much more
script-friendly control surface.

### Why code insertion is a separate post-processing step

Separating assistant generation from notebook mutation makes several things better:

- reply extraction is easier to debug;
- insertion can be disabled cleanly;
- insertion policy is visible in Python and PowerShell rather than hidden in FE-side logic;
- future insertion heuristics can evolve independently from assistant prompting.

## Selector resolution policy for notebook-targeted workflows

Tungsten needs stable ways to refer to notebook cells across different workflows. The current
selector policy is intentionally layered.

### Preferred selector order

When Tungsten resolves a cell for assistant insertion or later FE targeting, it prefers:

1. `ExpressionUUID`
2. `CellID`
3. first `CellTag`
4. flat cell index

### Why that order exists

- `ExpressionUUID` is the most stable notebook-native identity when available.
- `CellID` is often stable and numeric.
- `CellTag` can be useful when intentionally assigned, though it may be ambiguous.
- flat index is convenient and available even for synthetic or freshly generated notebooks, but it
  is more sensitive to structural edits.

This policy lets users write short scripts without giving up the more stable identity forms when
the notebook already contains them.

## Why the PowerShell module is thin

There is a strong temptation to keep adding PowerShell-native logic once a module exists. Tungsten
intentionally resists that.

### Current PowerShell responsibilities

The module mainly:

- constructs CLI arguments;
- ensures `PYTHONPATH` points at the repo-local `src/`;
- invokes `python -m tungsten`;
- deserializes JSON;
- exposes user-friendly function names.

### Why this is the right tradeoff

- implementation logic stays in one language and one code path;
- behavior stays consistent between Python and PowerShell callers;
- test burden stays smaller;
- docs can treat the PowerShell layer as a projection instead of as a second architecture.

## Why validation is structured the way it is

Tungsten spans pure parsing logic and live integration with an installed Wolfram environment, so no
single test strategy is enough.

### Unit and component coverage

Kernel-free subsystems and CLI shaping are covered by Python unit tests.

### Live machine smoke coverage

The smoke script covers the actual machine integration points:

- discovery;
- kernel execution;
- notebook workflows;
- documentation lookup;
- FrontEnd flows;
- Notebook Assistant;
- expression parsing/evaluation.

### Important operational lesson

FrontEnd-heavy validations should not be run in parallel with other Wolfram-heavy integration runs
on the same machine session. The desktop and FE state are shared enough that serial execution is
more dependable.

## Current limitations that are implementation choices, not oversights

Some current boundaries are deliberate and should be treated as such unless a later design changes
them intentionally.

- Tungsten is Windows-first.
- Tungsten assumes a local Wolfram installation rather than a remote kernel.
- The expression subsystem does not attempt full kernel semantics.
- Notebook parsing is structural rather than fully semantic.
- FrontEnd coverage is intentionally narrow.
- The visible inline Notebook Assistant path remains experimental.

## Likely future extension directions

The current implementation naturally suggests a few extensions if the project continues to grow.

- More notebook patch operations in `notebook.py`.
- Live FrontEnd selection-based inline-box capture for unsaved notebook state, if a future workflow
  really needs it.
- More inert structural built-ins in `expression.py`, provided they remain explicit and testable.
- Richer assistant post-processing, such as multiple insertion policies or code-block ranking.
- Additional FE operations that still fit the "small, deterministic, Wolfram-code-addressable"
  model.
- Better doc-index metadata extraction if future workflows need more precise classification.

The important constraint is that future growth should preserve Tungsten's two strongest traits:

- it is pleasant to automate from scripts;
- it is honest about which parts are real Wolfram execution and which parts are local structural
  tooling.
