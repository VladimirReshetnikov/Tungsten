# Tungsten Implementation Details

- Status: Informational and maintainership-oriented (design rationale, machine findings, and implementation-specific constraints)
- Audience: Tungsten maintainers, reviewers, contributors, and advanced users who need the reasoning behind the current implementation
- Scope: `src/Tungsten` implementation choices and machine-shaped design constraints
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-04-26T04:06:50Z
- Repository HEAD: 61037266f3664b750ab84c6186eced4cd9b12632

## Summary

This document records the machine findings, engineering choices, and reasoning that shaped
Tungsten's current implementation. It is intentionally more specific than the architecture guide.
Where the architecture document says "what the layers are," this document answers questions like:

- why Tungsten executes through `wolfram.exe` instead of a different local surface;
- why notebook editing is structural instead of semantic;
- why the default Notebook Assistant backend is the hidden chat-notebook flow;
- why the expression subsystem is separated from notebook parsing;
- why some outputs are returned as strings even when they represent rich Wolfram objects.

## Threat model

Tungsten assumes trusted local callers. It interpolates notebook paths, prompts, selectors, JSON
blobs, and Wolfram code snippets into generated Wolfram source through narrow string-literal
escaping helpers because its primary job is dependable local automation, not hostile-input
sandboxing.

That means Tungsten is designed for:

- repo-local scripts;
- trusted PowerShell automation;
- local .NET callers;
- agents operating on the owner's machine.

It is not currently hardened as a multi-tenant service boundary or untrusted-code execution broker.

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

### 2a. License-seat contention, not just duplicate entries, is part of the real machine story

Later live investigation showed that the local license ceiling is also materially relevant:

- successful runs report `$MaxLicenseProcesses = 2`;
- a single orphaned headless `wolfram.exe` can consume one controlling-process seat;
- parallel Tungsten launches can then exhaust the remaining seat and surface as `No valid password found.`

Tungsten therefore now pairs the `mathpass` workaround with lightweight runtime seat management:

- a machine-wide launch gate serializes Tungsten's own kernel launches;
- successful runs cache the observed `max_license_processes`;
- prelaunch process scans record likely controlling-process consumers;
- clearly orphaned Tungsten-owned headless kernels from prior crashed runs are cleaned up before
  new launches.

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
  common notebook boxes such as `FractionBox`, `SqrtBox`, `RadicalBox`, `SuperscriptBox`,
  `SubscriptBox`, and related script boxes, plus named-character operators such as
  `\[CirclePlus]`;
- structural inspection;
- canonical rendering;
- a small set of structural built-ins for inert evaluation.

### Why the evaluator is structural first

Tungsten's evaluator implements a broadening set of kernel-free, non-I/O structural operations:
part extraction, traversal, mapping, replacement, patterns, associations, strings, selected
control-flow forms, explicit numeric atoms, and first-level ordering operations. It still does not
pretend to be a general Wolfram kernel. Built-ins are added when their behavior can be expressed
over Tungsten's explicit expression tree and tested without hidden global state.

The ordering family uses one shared deterministic canonical order for explicit numbers, strings,
symbols, byte arrays, and compound expressions. `Sort`, `Ordering`, `SortBy`, `OrderingBy`,
`MinimalBy`, `MaximalBy`, `ReverseSort`, `ReverseSortBy`, `LexicographicOrder`, and
`LexicographicSort` all delegate to that core, with association support implemented by ordering
values and rebuilding the original key-value entries. This keeps comparator behavior consistent
and makes deviations from undocumented Wolfram kernel tie breakers local rather than scattered
through the evaluator.

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

### Why docs-root discovery now filters update paclets by install version

This machine has multiple `SystemDocsUpdate*` paclets for older Wolfram versions side by side with
the current 14.3 installation. Indexing every update paclet would duplicate reference notebooks and
inflate the local SQLite index.

Tungsten therefore filters `SystemDocsUpdate*` roots to the current install-version prefix before
building the documentation corpus. That keeps the offline index aligned with the active
installation rather than with every historical docs update still cached under `%APPDATA%`.

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

### Why the assistant Wolfram helpers are shared

The assistant module generates several Wolfram scripts: ask-cell, insertion, inline preparation,
and inline capture. They all need the same notebook/cell resolution and metadata helpers.

Tungsten now generates those shared helpers from one Python-side prelude template instead of
copying near-identical Wolfram definitions into every builder method. That keeps selector behavior
and metadata shaping aligned across assistant workflows.

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

## Why Abort, Throw, and Catch are evaluator signals

`Abort`, `Throw`, and `Catch` cannot be implemented as ordinary symbolic rewrites because they
must stop evaluating sibling arguments and unwind through arbitrary intermediate heads. Tungsten
therefore models them with internal non-local evaluator signals.

The outer public `evaluate(...)` boundary catches only signals that escaped the whole evaluation.
That matters because Tungsten's evaluator recursively calls `evaluate(...)` while evaluating
ordinary arguments; catching at every recursive call would incorrectly turn `1 + Throw[x]` into a
partially evaluated `Plus[...]` expression instead of unwinding the whole evaluation. `Catch`
intercepts signals only in its own body evaluation and preserves Wolfram's split between untagged
`Throw[value]`, caught by `Catch[expr]`, and tagged `Throw[value, tag]`, caught by
`Catch[expr, form]` when the tag matches the pattern form.

## Why Sow/Reap, AbortProtect, and time constraints are evaluator scopes

`Sow`, `Reap`, `CheckAbort`, `AbortProtect`, `TimeConstrained`, and `TimeRemaining` all depend on
dynamic evaluation context. Modeling them as ordinary expression rewrites would lose the important
"nearest enclosing scope" behavior:

- `Sow[e, tag]` must find the nearest active `Reap` whose pattern matches `tag`, not every
  syntactically surrounding or later-visited `Reap`.
- `AbortProtect[expr]` must allow the protected body to keep evaluating after `Abort[]`, but must
  re-raise the deferred abort once the protected body finishes.
- `CheckAbort[expr, fail]` must distinguish aborts raised in its own dynamic abort-protection
  depth from aborts deferred by an inner `AbortProtect`.
- `TimeRemaining[]` must report the earliest active `TimeConstrained` deadline, which is a
  dynamic property rather than a property of the expression tree.

Tungsten therefore keeps these as `contextvars`-backed evaluator scopes. That keeps nested
evaluation deterministic and makes the behavior safe for scripts that run multiple sessions in the
same Python process. `TimeConstrained` is intentionally practical rather than preemptive: it checks
deadlines at Tungsten evaluator boundaries and during `Pause`, then evaluates the fallback outside
the expired constraint scope. This mirrors the user-visible Wolfram shape for supported Tungsten
workloads while avoiding unsafe host-language asynchronous interruption.

## Why confirmations and cleanup are signals, not rewrites

The `Confirm*` family looks superficially like predicates returning either a value or a failure,
but its useful behavior is non-local: a failing confirmation must stop the current evaluation and
transfer to the nearest matching `Enclose`, while `WithCleanup` must still run cleanup before that
transfer leaves the protected region. Tungsten models this with `_TungstenConfirmSignal`, parallel
to the existing throw/abort/time signals.

Generated confirmation failures are ordinary `Failure[ConfirmationFailed, Association[...]]`
expressions. Tungsten currently records the properties needed by the implemented APIs, such as
`"Expression"`, `"Information"`, `"Function"`, `"Pattern"`, and `"Test"`, and supports
`failure["prop"]` lookup plus `Enclose[expr, "prop"]`. This is deliberately structural rather than
a clone of the FrontEnd's pretty failure summary boxes.

One important divergence is lexical scoping. The Wolfram kernel rewrites untagged `Confirm*`
occurrences lexically inside `Enclose`. Tungsten does not have source-level definition rewriting,
so untagged confirmations are handled dynamically by the active evaluator scope. Explicitly tagged
confirmations still require a matching `Enclose[..., handler, form]` scope.

`WithCleanup` catches Tungsten's evaluator control signals, runs cleanup, and then re-raises the
original signal. Init and cleanup are evaluated under abort protection and with time-constraint
checks suppressed, matching the practical guarantee that cleanup should complete even when the
body is aborted or externally time-constrained.

## Why messages are non-fatal evaluator events

The Wolfram kernel usually reports many failed preconditions as messages while returning the
original expression unevaluated. Tungsten now follows that shape for expressions evaluated through
the public evaluator: a `WolframEvaluationError` raised by a built-in implementation is converted
at the nearest recursive `evaluate(...)` boundary into a generated `Head::error` message and the
original expression is returned. This lets enclosing expressions continue, and it gives `Check`
and `$MessageList` meaningful data without turning ordinary user mistakes into Python exceptions.

The distinction is intentional:

- direct helper APIs can still raise `WolframEvaluationError` when called as Python functions;
- parser errors remain fatal syntax errors;
- evaluator control-flow signals such as `Throw`, `Abort`, `Exit`, and `Quit` remain non-message
  control flow;
- message records are Tungsten diagnostics, not attempts to reproduce Wolfram's localized message
  template database.

`Quiet` is modeled as a scoped visibility filter. Quieted messages are still generated and can be
seen by `$MessageList` during the same evaluation, but they are not saved into per-line
`MessageList[n]` history and are not visible to an enclosing `Check`. A `Check` placed inside an
outer `Quiet` still sees messages generated in its own body, matching the practical Wolfram rule
that `Check` is not disabled merely because its output is quieted.
- The expression subsystem can report read-only Wolfram 14.3 <code>System`</code> attributes through the
  symbol registry, but it intentionally does not implement evaluator-wide semantics for general
  attributes such as `Flat`, `Orderless`, `Listable`, or short-circuit evaluation. A small
  hardcoded Hold-family subset is implemented because it is required for predictable structural
  manipulation.
- FullForm cosmetics such as `DirectedInfinity[1]` for `Infinity` and exact precision-bearing real
  rendering are documented divergences for now.
- Numeric literal parsing follows Wolfram's lexical grammar for decimal, base, precision,
  accuracy, and `*^` magnitude forms closely enough to preserve accepted spellings as inert
  numeric atoms even when Tungsten cannot calculate with those exact literal forms. The shipped
  numeric tower now evaluates explicit integers, rationals, reals, complex values, machine
  constants, and special `Overflow[]` / `Underflow[]` real atoms for common structural arithmetic,
  predicates, and precision/accuracy metadata; see `docs/numeric-tower.md`.
- Assignment, update, prefix increment/decrement, message, file, information, factorial, and
  infix-function operator forms are parsed to their Wolfram heads, but side-effectful heads remain
  inert unless a future evaluator milestone explicitly gives them definition or I/O semantics.
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
