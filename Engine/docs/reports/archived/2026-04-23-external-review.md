# Tungsten External Consultant Review

- Status: **Archived — no longer current.** This was a broad external-consultant pass at HEAD `d21a3a9c…`. Findings F-1 (kernel `result_head` HoldAll bug) through F-15 (observability hooks) have been addressed or explicitly accepted in the time since; the `expr` CLI now returns structured JSON on parse/eval errors, docs-root sprawl is filtered, the Wolfram helper prelude has been deduplicated, etc. For the *current* function-surface gap inventory see `../2026-04-27-tungsten-gap-and-shape-review.md`. **Do not treat this document as current state.**

  Original status line: Report (external-consultant review of `src/Tungsten` as of the date below).
- Audience: Vladimir Reshetnikov (project owner), Tungsten maintainers, future reviewers
- Scope: `src/Tungsten` — Python package, PowerShell module, typed .NET client, tests, docs, and scripts
- Created (UTC): 2026-04-23T19:56:30Z
- Repository HEAD: d21a3a9c626457e9fe8eb91e7a3cfec73cd7b432
- Reviewer context: Simulated external consultant-contractor. Hands-on validation was performed against the actual local Wolfram 14.3 installation on this machine.
- Validation performed:
  - Ran the full Python test suite (`python -m unittest discover`) — 52 tests passed, 1 skipped.
  - Ran the .NET test suite (`dotnet test dotnet/Tungsten.DotNet.slnx`) — 9 tests passed.
  - Ran `env show`, `kernel eval`, `expr parse`, `expr evaluate`, `notebook create`, `inline-box from-cell`, `docs search` against the real installation.
  - Exercised failure paths (parse errors, evaluator errors, division by zero, unterminated brackets).
  - Did **not** exercise `assistant ask-cell` end-to-end against the live Chatbook stack, the `DesktopInline` backend, or `frontend open-*` commands; static code review only for those.

## Contents

1. [Executive summary](#executive-summary)
2. [Architecture assessment](#architecture-assessment)
3. [Code quality assessment](#code-quality-assessment)
4. [Documentation assessment](#documentation-assessment)
5. [Usability and developer experience](#usability-and-developer-experience)
6. [Findings](#findings) — prioritized, with recommendations
7. [Recommended roadmap](#recommended-roadmap)
8. [Closing thoughts](#closing-thoughts)

## Executive summary

Tungsten is a small, cleanly layered, unusually thoughtful WIP. It has a clear value
proposition (structured, script-friendly automation over a local Wolfram installation without
trying to replace the runtime), and the shape of the codebase matches the stated goals. The
Python package is the source of truth; the PowerShell module and the typed .NET client are thin
JSON-projection layers; the embedded Wolfram wrapper script is a nice pattern for surfacing
evaluation success/failure/messages/timing as structured data.

The project is **in good shape for its age**. Tests pass, builds are clean, documentation is
comprehensive and consistent in tone. The design principles in `architecture.md` are actually
followed in code.

That said, there are a handful of real defects and inconsistencies a reviewer should care
about. In priority order:

1. **A correctness bug in the kernel-evaluation wrapper**: `result_head` is always returned as
   `"Symbol"` regardless of the actual result head. Confirmed by experiment. Root cause is a
   `HoldAll` + `Unevaluated` interaction in the embedded Wolfram script.
2. **A contract violation in the CLI**: the docs promise "every command returns structured
   JSON," but `expr parse` and `expr evaluate` let Python tracebacks escape to stderr on any
   `WolframSyntaxError` / `WolframEvaluationError`. The kernel path correctly handles its
   own parse/eval failures as JSON; the offline path does not.
3. Several **documentation metadata inconsistencies** (stale `Repository HEAD`, and hardcoded
   absolute example paths where repo-root-relative paths would be more portable).
4. **Ergonomic and stylistic issues** in the PowerShell module (e.g., assigning to the
   automatic `$args` variable) and a very long `Invoke-TungstenNotebookAssistant` function.
5. **Docs-root sprawl** from finding every `SystemDocsUpdate*` paclet across versions; likely
   causes duplicate index entries and slower indexing.

None of the above block the project from being useful today. They are the kinds of things a
paid consultant should surface so that they get fixed before the project takes on a wider
user base.

## Architecture assessment

### What the architecture gets right

- **Layering is real, not decorative.** `discovery.py` and `licensing.py` are leaf utilities;
  `kernel.py` depends on them; everything kernel-backed then builds on `kernel.py`; `cli.py`
  is the only module that knows about subcommand shapes. The dependency graph in
  `docs/architecture.md` matches the import graph in the code.
- **"Use the real thing where fidelity matters; fall back locally where it doesn't" is honored.**
  Evaluation, FrontEnd, docs corpus, and Chatbook all go through the installed runtime. Notebook
  parsing, inline-box extraction, and expression parsing stay kernel-free on purpose. This
  split is load-bearing — it is the main reason Tungsten can be a useful
  dev-loop helper rather than a giant dependency.
- **The mathpass deduplication is a first-class concern, not a hidden hack.** The
  `MathpassInspection` payload is surfaced all the way out to callers; `used_mathpass_workaround`
  is visible in every kernel result. This is exactly how a machine quirk should be exposed.
- **The wrapper-script pattern (`EvaluationData[...]` + `RawJSON` export) is the right shape.**
  It cleanly separates process success, parse success, evaluation success, messages, timing,
  and printed output. This is hard to get right on a Wolfram substrate, and Tungsten's version
  is close to the cleanest you can achieve with a stdout-based CLI.
- **Selector policy is sensible.** Preferring `ExpressionUUID` > `CellID` > `CellTag` > flat
  index gives users ergonomic shortcuts while keeping stable identities available when the
  notebook has them.
- **PowerShell and .NET are explicit projection layers, not second implementations.** The
  .NET client literally forwards JSON-first CLI invocations to typed response records. This
  keeps the behavior-surface single-source-of-truth in Python.

### What is architecturally underdone or worth revisiting

- **Embedded Wolfram scripts are Python f-strings with doubled braces.** `kernel.py`,
  `assistant.py`, and the FE controller use f-strings to interpolate Python values into Wolfram
  source. Escaping rules are subtle (`{{` → `{`, `\` handling inside `wl_string`, JSON
  serialization for selectors and code lists). The pattern works today, but it is fragile to
  review and modify — every change has to simultaneously reason about Python string
  interpolation AND Wolfram evaluation AND Chatbook internals. Consider extracting the larger
  assistant scripts into `*.wlt` template files loaded with a small parameter-substitution
  helper, so each escape pass is explicit.
- **Multiple independent Wolfram-string parsers.** `wolfram_strings.parse_wl_string_literal`,
  `notebook._skip_string`, and `expression._skip_string` all walk string literals slightly
  differently. This is the seam the inline-box work already cleaned up once — the same
  refactor could usefully go further, e.g., by making `notebook` and `expression` consume a
  single shared tokenizer for strings/comments/brackets. Right now it's 4 close-but-not-identical
  implementations.
- **Docs-root discovery is too permissive on this machine.** `env show` surfaces 8 roots,
  including older SystemDocsUpdate paclets (`14.1.0.1`, `14.2.0.2`, etc.) that likely contain
  stale copies of the same notebooks. Indexing all of them means duplicate entries at search
  time and extra index build cost. See finding F-5.
- **Failure-model layering is slightly leaky.** `docs/architecture.md` carefully describes
  four classes of failure (discovery, process, evaluation, post-processing). In the code, the
  `expr` subsystem has a fifth class (syntax/structural parse errors) that isn't handled
  consistently at the CLI boundary. See finding F-2.
- **No clear headless seam for the embedded Wolfram scripts.** The wrapper scripts live
  inside `kernel.py` and `assistant.py` as private method returns. A consultant coming from
  Near's TUI architecture playbook would expect these to be testable without a kernel —
  perhaps via snapshot tests on the generated script text.

## Code quality assessment

### Python — overall: **good**

- Clean dataclasses, `from __future__ import annotations` everywhere, PEP 604 union syntax,
  consistent type hints. Readable without being over-typed.
- `expression.py` is a proper Pratt-style parser with a published operator-precedence table.
  Implicit multiplication is handled through a `_starts_primary` check in the main expression
  loop — standard technique, correctly applied.
- Context managers are used consistently (`TemporaryDirectory`, `deduped_mathpass`). No
  obvious lifecycle leaks.
- Error types are specific (`WolframSyntaxError`, `WolframEvaluationError`) rather than
  generic. Good.
- `wolfram_strings.py` centralization after the inline-box work is a real improvement; the
  "preserve unknown backslash escapes" decision is correctly motivated.

#### Specific Python concerns

- **`wl_string` escape coverage is narrow.** It handles `\\`, `"`, `\r`, `\n`, `\t` but
  nothing else. Form feed, vertical tab, NUL, and (more importantly) Wolfram named-character
  escapes like `\[Pi]` are passed through unchanged. For the stated scope (notebook paths,
  short prompts, JSON blobs) this is fine; for arbitrary user data it is a latent source of
  subtle corruption.
- **`Stringify` fallback "$Failed"** returns the literal *string* `"$Failed"`, so callers
  cannot distinguish a Wolfram `$Failed` symbol from a stringify failure. Minor.
- **Some branches in `cli.main` lack a trailing `return`.** The `if args.command == "notebook":`
  block, for example, relies on falling off the end and hitting `raise RuntimeError(...)` only
  if nothing matched inside. This works today, but a dispatch-table or explicit
  `return`-per-branch would be safer as the command surface grows.
- **`main()` does not catch `WolframSyntaxError` / `WolframEvaluationError`** around the
  `expr` command (line 343–379 of `cli.py`). This is the root of F-2.
- **`rule_value(options, name)` compacts by stripping *all* spaces.** It works for standard
  `CellID->1001` etc., but will false-positive if an option's *value* contains a substring
  matching `"<name>->"` with whitespace variation. Very unlikely on well-formed notebooks,
  still worth a quick defensive guard.
- **`extract_string_literals` walks character-by-character.** Acceptable at current scale but
  would be worth benchmarking if documentation indexing over large notebook corpora becomes a
  hot path.

### Wolfram (embedded scripts) — overall: **works, but brittle**

- The pattern `EvaluationData[...]` + `RawJSON` export is solid and gives the Python side a
  clean contract.
- **Correctness bug**: `HeadStringify` always returns `"Symbol"`. See finding F-1.
- **Minor quirk**: `Stringify[$Failed]` returns the string `"$Failed"` by design, but the
  `Check`-fallback also returns `"$Failed"`. Collapsing both into the same string makes
  debugging harder.
- The assistant scripts re-declare a nearly-identical set of helper functions
  (`tungstenError`, `tungstenStringValue`, `tungstenCellMetadata`, `tungstenResolveNotebook`,
  `tungstenResolveCell`) across `_build_script`, `_build_insert_script`,
  `_build_prepare_inline_script`, and `_build_capture_inline_script`. A shared prelude
  loaded via `Needs` or a single concatenated helper block would remove ~400 lines of
  drift risk.

### PowerShell — overall: **good, with a few stylistic snags**

- `Set-StrictMode -Version Latest` is the right default.
- Parameter-set modeling for selectors is idiomatic.
- JSON-round-trip through `ConvertFrom-Json -Depth 100` is the correct way to cross the
  CLI boundary.

#### Specific PowerShell concerns

- **Local `$args` shadowing**: `Invoke-TungstenCliJson`, `Get-TungstenEnvironment`, etc.
  assign to a local `$args` variable. `$args` is an automatic variable in PowerShell; while
  assigning to it is legal, it's generally considered bad form and can surprise readers
  familiar with the automatic semantics. Rename to `$cliArgs` or `$argList`.
- **`Invoke-TungstenCliJson` merges stderr into stdout with `2>&1`** and then
  `ConvertFrom-Json` the whole thing. If Python ever writes a warning to stderr (e.g., a
  Python `DeprecationWarning`), the PowerShell wrapper will fail to parse. Prefer capturing
  stderr separately and only parsing stdout.
- **`Invoke-TungstenNotebookAssistant` is very long.** The DesktopInline branch alone runs
  ~270 lines with nested try/catch, window-state checks, text injection, and polling. Breaking
  this into smaller private functions (`Wait-TungstenInlineWindow`, `Submit-TungstenQuestion`,
  `Wait-TungstenInlineCompletion`, `Complete-TungstenInlineInsertion`) would be much easier to
  maintain.

### .NET — overall: **clean, idiomatic, minimal**

- `TungstenClient` + options + response records is exactly the right shape: a thin,
  async-first process wrapper that does not leak its mechanism.
- `CreateForRepositoryRoot` and `CreateForDiscoveredRepository` are nice ergonomic helpers.
- Separating `TungstenCommandException` (exit-code failure) from `TungstenProtocolException`
  (bad JSON) is the right distinction.
- Timeout handling via `CancellationTokenSource` + `process.Kill(entireProcessTree: true)` is
  correct.

#### Specific .NET concerns

- **No XML docs on public types** for `TungstenInputSource`, `TungstenExpressionForm`,
  `TungstenNotebookCellSpec` beyond summary-level. `GenerateDocumentationFile=true` plus
  `NoWarn=CS1591` hides the absence. Not a bug; something to track if you publish a NuGet.
- **`TungstenClientTests` uses a PowerShell fake script.** The intent is clever — it lets the
  test bypass Python entirely — but makes the tests Windows-locked even for the argument-shape
  parts that could be cross-platform.
- **`pythopath` typo** in the fake test script (`Tungsten.DotNet.Tests/TungstenClientTests.cs:327`
  and line 471, and read back by line 34 and 471). It's self-consistent (test writes typo,
  test reads typo), so it passes — but the typo itself reduces the test's documentary value.
- **`OpenDocumentationInFrontEndAsync` routes through `frontend open-doc`** rather than
  `docs open`. Per the Python CLI, both paths exist and behave similarly, but the .NET API
  method name suggests FrontEnd semantics and the implementation agrees — so this is fine.
  Just something to keep consistent if the CLI surface diverges later.
- **`RealRepositoryExpressionEvaluation_WorksAsync` is a single live test.** Good that it
  exists; consider adding a kernel-free notebook round-trip live test (create → inspect →
  patch → inspect) to cover more of the typed wrapper surface end-to-end.

### Tests — overall: **good coverage for this stage**

- 52 Python tests + 9 .NET tests, all passing. 1 skip is the `RadicalBox.nb` path in
  `test_expression.py` being optional on docs availability — harmless.
- `test_expression.py` goes further than I expected, using **actual vendored documentation
  notebooks** (`FractionBox.nb`, `SqrtBox.nb`, `RadicalBox.nb`, `SuperscriptBox.nb`) as
  test fixtures for the StandardForm lowering rules. That is an excellent practice —
  catches drift between Tungsten's assumptions and real Wolfram artifacts.
- `test_kernel_integration.py` runs against the real kernel, with `setUpClass` gracefully
  skipping if the kernel isn't discoverable.
- `test_assistant.py` only covers the parse-and-finalize helpers, not the full `ask_cell`
  kernel round trip. Reasonable — an end-to-end assistant test would be slow and fragile —
  but document that gap.

## Documentation assessment

### What the docs do well

- **Reading-order paths by role** in `docs/README.md` are genuinely useful. Most docs
  trees don't do this; users have to guess.
- **Non-goals are stated up front.** README's "Non-goals" section and the repeated "this is
  intentionally narrow" framing protect reviewers from misunderstanding scope.
- **Implementation-details.md is the kind of doc every project should have.** It captures
  *why* decisions were made (the mathpass workaround, the `wolfram.exe` choice, the hidden
  chat-notebook assistant path) instead of just *what* was built. That's the information that
  normally lives only in maintainers' heads.
- **The expression-function-support matrix** is the right idea — a support table with
  supported forms and authoritative Wolfram doc links. Easy to extend as more heads are
  implemented.

### Docs issues

- **`Repository HEAD` is stale and inconsistent across files.** At the time of this review
  (`d21a3a9c...`):
  - README.md, docs/README.md, architecture.md, usage-reference.md, dotnet-api.md:
    `1d773e54...`
  - implementation-details.md, user-guide.md: `67ad70b3...`
  - expression-parser.md: `d802d432...`
  - expression-function-support.md: `d802d432...`
  - inline-box-strings.md, notebook-assistant.md, troubleshooting.md: `67ad70b3...`

  Three different HEADs across the docs tree. The CLAUDE.md provenance rule is good, but
  it only helps if it is kept honest on every edit. Consider a pre-commit hook or a simple
  `scripts/Update-TungstenDocsHead.ps1` that rewrites `Repository HEAD:` and `Updated (UTC):`
  lines in all docs before commit.
- **Hardcoded absolute example paths (`C:\Tools1\Tools\...`) in `dotnet-api.md` and
  `expression-parser.md`.** These happen to match the real checkout location on this
  machine, so they aren't *wrong* — but per repo policy, doc examples should use
  repo-root-relative paths (e.g., `.\src\Tungsten\src`), which README and user-guide
  already follow. Absolute paths to the Wolfram installation itself are fine since the
  installation is external to the repo; the policy only applies to *in-repo* references.
- **`docs/README.md` lists `implementation-details.md` in "Documents in this folder" but
  implementation-details.md itself lacks the full header metadata block** (no Status,
  Audience, Scope entries — just `Created (UTC)`, `Updated (UTC)`, `Repository HEAD`). Most
  other docs in the tree follow the fuller metadata convention. Minor consistency nit.
- **The `result_head` field is documented in usage-reference.md as an "InputForm string" of
  the head** (`docs/usage-reference.md:99-106`). The actual returned value is always
  `"Symbol"` (see F-1). Users reading the docs will be confused.
- **Security/threat-model** is not discussed anywhere. Tungsten interpolates user-provided
  strings (questions, paths, code snippets) into Wolfram source via `wl_string`. The escape
  function is narrow and intentional. A one-paragraph "Threat model" in
  `implementation-details.md` stating "Tungsten assumes trusted input; it is not hardened
  against hostile callers" would set expectations correctly.
- **No mention in docs of the CLI exit codes.** Users scripting around `kernel eval` will
  encounter exit code `2` when `evaluation_available == false`. Neither `usage-reference.md`
  nor `troubleshooting.md` document this. Add a small "Exit codes" subsection.

## Usability and developer experience

### Happy path is smooth

- `env show` works out of the box.
- `kernel eval --code "2+2"` returns a clean JSON payload in under a second.
- `notebook create` + `notebook inspect` + `notebook patch` is actually a pleasant workflow;
  the flattened-cell view is a real ergonomic win over hand-parsing `.nb` files.
- `expr evaluate` is surprisingly pleasant for quick structural work
  (e.g. `ReplacePart[f[a, b, c], 2 -> x] → f[a, x, c]` without paying the kernel startup
  cost).
- `docs search NotebookGet` returns the correct page and a usable preview; the `es.exe`
  fast-path is noticeable.
- PowerShell ergonomics are good: `Invoke-TungstenKernel -Code "2+2"` feels native.

### Rough edges I hit during testing

- **Parse errors crash the CLI.** `tungsten expr parse --code "x := 5"` and
  `tungsten expr evaluate --code "Length[]"` print a Python traceback and exit nonzero.
  A user scripting around these commands has to either parse stderr or wrap in their own
  try/except equivalent. This is the issue documented in F-2.
- **`result_head: "Symbol"`** is surprising when it appears for `4` (expected `"Integer"`),
  `{1,2,3}` (expected `"List"`), and so on. Documented in F-1.
- **Multi-version docs roots mean duplicated hits.** A `docs search` for a term that
  appears in multiple version paclets will likely return the same page multiple times (I
  saw only one hit for `NotebookGet`, but the root list strongly suggests this will bite
  on other queries).
- **Help text collisions on subcommands.** Typing `python -m tungsten` without a subcommand
  shows argparse's default "required" error, which is OK but terser than the high-quality
  docs suggest. A top-level `--help` summary that lists the 7 command groups would be nice.
- **`New-TungstenInlineBoxString -BoxExpression @()`** (no boxes) currently produces just
  `prefix + suffix` with no error — fine — but the returned `string_literal` is still a
  quoted string. The current behavior is correct; worth noting as a small "no-op input"
  example in the Inline Box Strings doc.

## Findings

Findings are prioritized. For each: observed behavior, root cause, impact, and a concrete
recommendation.

### F-1 (P1, correctness bug): `result_head` always returns `"Symbol"` from kernel eval

**Observed.** Every kernel evaluation returns `result_head: "Symbol"`, regardless of the
actual head of the result value.

```
2+2             → result "4", result_head "Symbol"     (expected "Integer")
{1, 2, 3}       → result "{1, 2, 3}", result_head "Symbol"  (expected "List")
Plot[x^2, ...]  → result "Graphics[...]", result_head "Symbol"  (expected "Graphics")
2^100           → result "1267...376", result_head "Symbol"    (expected "Integer")
```

**Root cause.** In `src/tungsten/kernel.py:264-276`, the wrapper declares:

```
SetAttributes[Tungsten`Private`HeadStringify, HoldAll];
Tungsten`Private`HeadStringify[value_] := Quiet @ Check[
    ToString[Head @ Unevaluated[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
```

With `HoldAll`, the pattern variable `value` binds to the *symbol* `result` (unevaluated).
`Unevaluated[value]` then passes that symbol through to `Head` without triggering its
own-value evaluation — so `Head` sees the pattern-bound symbol `result` and returns
`Symbol`. The result's actual head is never examined.

I verified this experimentally with an isolated reproducer:

```wolfram
x = 42;
ClearAll[sf];
SetAttributes[sf, HoldAll];
sf[value_] := {ToString[Unevaluated[value], InputForm], ToString[Head[Unevaluated[value]], InputForm]};
sf[x]
(* → {"x", "Symbol"}    -- confirms the same behavior *)
```

**Impact.** `result_head` is effectively a useless field for all callers today. This also
undermines the `TungstenKernelEvaluationResponse.ResultHead` typed property in the .NET
client. Tests never caught this because no Python test asserts on `result_head`, and the
`RealRepositoryExpressionEvaluation` .NET test hits the offline expression evaluator, not the
real kernel.

**Recommendation.** Drop `HoldAll` on `HeadStringify` and remove the `Unevaluated` wrapper:

```
Tungsten`Private`HeadStringify[value_] := Quiet @ Check[
    ToString[Head[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
```

The point of `HoldAll` + `Unevaluated` was presumably to avoid re-triggering any
side-effectful evaluation of `result`. That concern doesn't apply here: by the time the
wrapper reaches the payload-construction step, `result` is already the
stored-and-fully-evaluated value. Re-evaluating it inside `HeadStringify` is a no-op lookup.

Also add a test to `test_kernel_integration.py` that asserts `result_head` for a few known
heads (`2+2` → `"Integer"`, `{1,2}` → `"List"`, `"abc"` → `"String"`).

### F-2 (P1, contract violation): `expr` commands leak Python tracebacks on bad input

**Observed.** `tungsten expr parse --code "x := 5"` and `tungsten expr evaluate --code "Length[]"`
exit nonzero with a Python traceback on stderr. No JSON is produced on stdout.

```
$ python -m tungsten expr parse --code "x := 5"
Traceback (most recent call last):
  ...
tungsten.expression.WolframSyntaxError: Unexpected Wolfram syntax character ':' at offset 2.
```

**Root cause.** `src/tungsten/cli.py:342-379` calls `parse_expression(...)` and
`evaluate_expression(...)` without catching `WolframSyntaxError` or `WolframEvaluationError`.
These propagate out of `main()` and the Python runtime prints the traceback.

**Impact.** The docs (`docs/usage-reference.md` "Conventions") state: "The Python CLI is
JSON-first. Every command returns structured JSON." Right now that is true only for the
kernel path, which catches parse failures inside the embedded script and reports
`"failure_type": "ParseFailure"` in the JSON payload. The offline expression path has no
such safety net. Scripts calling `python -m tungsten expr ...` must inspect stderr to
detect user-input errors.

**Recommendation.** Catch `WolframSyntaxError` / `WolframEvaluationError` at the CLI
boundary and emit a structured error payload, then return a distinct exit code:

```python
if args.command == "expr":
    try:
        parsed = parse_expression(source_text, form=args.form)
        ...
    except WolframSyntaxError as exc:
        _json_dump({
            "command": args.expr_command,
            "form": args.form,
            "source": source_text,
            "success": False,
            "error_type": "WolframSyntaxError",
            "error": str(exc),
        })
        return 1
    except WolframEvaluationError as exc:
        _json_dump({...})
        return 1
```

Bonus: surface the same payload shape from the Python API. Right now `parse_expression` raises;
for library callers that's fine, but the CLI is free to catch and reformat.

### F-3 (P2, docs consistency): `Repository HEAD` and example paths are stale

**Observed.** `Repository HEAD:` differs across docs (three different SHA prefixes seen at the
time of this review). Separately, `dotnet-api.md` and `expression-parser.md` use hardcoded
absolute example paths (`C:\Tools1\Tools\...`). Those paths happen to be correct for the
current machine, but the README and user-guide use repo-root-relative paths (`.\src\Tungsten\src`),
and the repo convention is to keep in-repo references relative so examples work for anyone
with a different checkout location. (Absolute paths to the *Wolfram installation* are
external to the repo and are not subject to this policy.)

**Impact.** Two separate issues, both small: stale provenance metadata erodes reviewer
trust, and absolute in-repo paths in examples are mildly unportable — a reader who cloned
the repo to a different location has to mentally translate every path.

**Recommendation.**
1. Add a small script (e.g., `scripts/Update-DocsProvenance.ps1`) that rewrites
   `Repository HEAD:` and `Updated (UTC):` across all docs before commit. Run it as part of
   a pre-commit hook or, more pragmatically, from CI/`Test-TungstenSmoke.ps1`.
2. Convert the hardcoded `C:\Tools1\Tools\...` prefixes in in-repo examples to relative
   paths like `.\src\Tungsten\src` (or `<repository-root>\src\Tungsten\...` placeholders).
   README and user-guide already follow this convention; `dotnet-api.md` and
   `expression-parser.md` are the main stragglers. Leave absolute Wolfram-installation
   paths (`C:\Program Files\Wolfram Research\...`) as-is since they live outside the repo.

### F-4 (P2, CLI robustness): Exit codes are undocumented

**Observed.** `cli.py` uses three distinct exit codes for kernel:
- `0` — success or `evaluation_available == true` and `--require-success` not specified
- `1` — `--require-success` and `success == False`
- `2` — evaluation never completed (e.g. `KernelNotFound`, kernel launch failure)

Similar implicit policies exist for `assistant`, `inline-box`, and `frontend`. None of this is
stated in `usage-reference.md` or `troubleshooting.md`.

**Impact.** Users wiring Tungsten into larger scripts will write fragile `if ($LASTEXITCODE
-ne 0)` checks and miss the nuance.

**Recommendation.** Add an "Exit codes" subsection to `usage-reference.md`, and make the
meaning of each code explicit across the command family (not just kernel).

### F-5 (P2, docs-root sprawl): Indexing multiple SystemDocsUpdate paclets duplicates entries

**Observed.** `env show` returns 8 docs roots on this machine, including paclets tagged
`14.1.0.1`, `14.2.0.2`, `14.3.0.1`, `14.3.0.2`, `14.3.0.3`. These likely contain stale
copies of notebooks that also exist under the current shared `Common Files/.../14.3/...`
root.

**Impact.** The SQLite FTS index probably contains duplicate or near-duplicate entries for
popular reference pages. `docs search NotebookGet` returned a single hit, suggesting
`_search_by_filename` deduplicates by resolved path — so the pain is masked for filename
matches but would likely show on body-text queries.

**Recommendation.** Either:
1. In `_discover_docs_roots`, only include `SystemDocsUpdate*` paclets whose version prefix
   matches `install_dir.name` (the current install version).
2. Or, in `build_index`, dedupe records by `(title, paclet)` so older-paclet duplicates
   don't survive the build.

The first option is lighter-weight and matches the "stay aligned with the installed version"
principle in `architecture.md` and `implementation-details.md`.

### F-6 (P2, DX/maintainability): Duplicated Wolfram helper functions in `assistant.py`

**Observed.** `assistant.py` `_build_script`, `_build_insert_script`,
`_build_prepare_inline_script`, and `_build_capture_inline_script` each redeclare
essentially the same block of Wolfram helpers (`tungstenError`, `tungstenStringValue`,
`tungstenStringList`, `tungstenCompactText`, `tungstenCellMetadata`, `tungstenFindNotebook`,
`tungstenResolveNotebook`, `tungstenResolveCell`). Roughly 80 lines × 4 = ~320 lines of
near-duplicate script text.

**Impact.** A bug fix or feature addition has to be replicated in up to four places and
cannot be mechanically verified to be consistent.

**Recommendation.** Extract a shared `TUNGSTEN_ASSISTANT_HELPERS` constant (Wolfram source
text) and inject it into each builder method. Even easier: ship the helper prelude as a
`.wl` file under `src/tungsten/wolfram/assistant_helpers.wl` and `Get` it from each
generated script.

### F-7 (P2, PowerShell style): Assigning to the automatic `$args` variable

**Observed.** In `pwsh/Tungsten.psm1`, multiple functions do `$args = @("kernel", "eval",
...)` etc. `$args` is a PowerShell automatic variable that holds unbound positional
arguments to a function.

**Impact.** Works today, but shadowing automatic variables is considered bad style and can
produce confusing scope behavior under `Set-StrictMode`. Also makes the code harder to
grep for — `$args` is common noise.

**Recommendation.** Rename the local arg-list variables to `$cliArgs` or `$argList`
throughout the module.

### F-8 (P3, code quality): `Invoke-TungstenNotebookAssistant` is ~350 lines

**Observed.** The function handles three backends in-line: `NotebookChatCell`, `KernelWindow`,
and `DesktopInline`. The DesktopInline branch alone does window resolution, foreground
validation, minimize-restore handling, text injection, submit, poll, finalize.

**Impact.** Hard to read, hard to test incrementally, and the failure-path logic (multiple
`New-TungstenNotebookAssistantFailure` with different `-ErrorType` values) is repetitive.

**Recommendation.** Split into:
- `Invoke-TungstenAssistantAskCell` (NotebookChatCell / KernelWindow path)
- `Invoke-TungstenDesktopInlineAssistant` (orchestrator that calls…)
- `Get-TungstenInlineAssistantWindow`
- `Submit-TungstenInlineAssistantQuestion`
- `Wait-TungstenInlineAssistantCompletion`
- `Complete-TungstenInlineAssistantInsertion`

Keep `Invoke-TungstenNotebookAssistant` as a thin dispatcher.

### F-9 (P3, merged streams): `Invoke-TungstenCliJson` loses stderr integrity

**Observed.** `Invoke-TungstenCliJson` uses `& $python.Source -m tungsten @Arguments 2>&1`
and then deserializes the whole captured stream as JSON. If Python ever writes to stderr
(deprecation warning, ResourceWarning under `PYTHONWARNINGS=error`, etc.), the whole thing
becomes un-parseable.

**Impact.** Silent dependency on Python staying quiet. Brittle.

**Recommendation.** Capture stderr separately. For example:

```powershell
$stdoutFile = [IO.Path]::GetTempFileName()
$stderrFile = [IO.Path]::GetTempFileName()
try {
    & $python.Source -m tungsten @Arguments > $stdoutFile 2> $stderrFile
    ...
    (Get-Content $stdoutFile -Raw) | ConvertFrom-Json -Depth 100
}
finally {
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
}
```

Or use `Start-Process -Wait -RedirectStandardOutput -RedirectStandardError`.

### F-10 (P3, .NET DX): `pythopath` typo in test fake script

**Observed.** `dotnet/Tungsten.DotNet.Tests/TungstenClientTests.cs` writes and reads a
`pythopath` field (missing the `n`). The test is self-consistent, so it passes, but the
typo reduces the readability and documentary value of the fake script.

**Recommendation.** Rename to `pythonpath` in both the fake script writer and the test's
assertions.

### F-11 (P3, pyproject.toml and .psd1 authorship): "OpenAI Codex" author attribution

**Observed.** Both `pyproject.toml` (`authors = [{ name = "OpenAI Codex" }]`) and
`pwsh/Tungsten.psd1` (`Author = "OpenAI Codex"`, `CompanyName = "OpenAI"`) attribute
authorship to OpenAI Codex.

**Impact.** Presumably accurate as a statement of how the initial scaffolding was produced.
If Tungsten ever ends up on a package index (PyPI, PowerShell Gallery), this authorship
string is the public face. Vladimir may want to decide whether to keep it, co-credit, or
replace. This is not a bug — just a policy question to settle before first publish.

### F-12 (P3, Python style): `_skip_string` and friends exist in 3 modules

**Observed.** `wolfram_strings.py`, `notebook.py`, and `expression.py` all have their own
`_skip_string` / `_skip_comment` helpers with slightly different semantics (e.g.,
`notebook._skip_comment` supports nested comments, `expression._skip_comment` also does
but via a different code path).

**Impact.** Bug-fix drift risk; each helper needs to stay correct independently.

**Recommendation.** Move them into `wolfram_strings.py` and have `notebook.py` and
`expression.py` import from there. The inline-box work already consolidated string-literal
*parsing*; this is the same refactor extended to string/comment *skipping*.

### F-13 (P3, docs layering): Some docs reference `implementation-details.md` headers it doesn't have

**Observed.** `implementation-details.md` omits the full header block (Status/Audience/Scope)
present on most other docs. Minor consistency nit.

**Recommendation.** Either add the block or note in `docs/README.md` that some docs are
reference-style and keep a shorter header.

### F-14 (low, latent): `wl_string` doesn't cover all Wolfram escapes

**Observed.** `wl_string` only escapes `\\` and `"`. Control characters like `\b`, `\f`,
`\v`, `\0` pass through as literal bytes into the Wolfram string.

**Impact.** Very unlikely to bite in Tungsten's current use cases (paths, short prompts,
code snippets). Worth a comment documenting the intentional narrowness and linking to the
`parse_wl_string_literal` decision.

**Recommendation.** No code change needed; add a docstring to `wl_string` explaining the
intentional scope. Note that Wolfram named-character escapes (`\[Pi]`, etc.) are not escape
sequences in the C sense — they survive `wl_string` unchanged, which is usually what
callers want.

### F-15 (low, observability): No structured logging

**Observed.** Tungsten writes only CLI JSON payloads. When something goes wrong inside a
long-running operation (e.g., the assistant wrapper spends time setting up a hidden
chat notebook), there's no way to attach a diagnostic trace short of running the wrapper
script directly with `wolframscript`.

**Recommendation.** A `TUNGSTEN_LOG` environment variable that, when set, writes a
diagnostic file (or lines to stderr) at key checkpoints — temp dir creation, wrapper
script path, subprocess.run command, result JSON size — would pay for itself the first
time an assistant run mysteriously stalls.

## Recommended roadmap

A suggested order of operations, biased toward maximum reviewer/contributor impact per
unit of effort:

### Priority 1 — correctness and contract

- **Fix F-1**: `HeadStringify` HoldAll bug. Small change, high impact on payload
  correctness. Add a regression test.
- **Fix F-2**: `expr` CLI contract. Catch `WolframSyntaxError` / `WolframEvaluationError`
  and return structured JSON. Add a test that asserts both the JSON shape and the exit
  code on bad input.

### Priority 2 — trust and consistency

- **Fix F-3 / F-4**: Docs provenance automation + documented exit codes.
- **Fix F-5**: Docs-root discovery filter. One-line change in `discovery.py`, large impact
  on index quality and build time.
- **Fix F-11**: Decide authorship policy and apply it once.

### Priority 3 — maintainability

- **F-6**: Extract shared Wolfram helper prelude.
- **F-12**: Consolidate `_skip_string`/`_skip_comment` into `wolfram_strings.py`.
- **F-8**: Split `Invoke-TungstenNotebookAssistant` into smaller functions.
- **F-9**: Separate stderr capture in PowerShell.

### Priority 4 — polish

- **F-7**: Rename local `$args` → `$cliArgs`.
- **F-10**: Fix `pythopath` → `pythonpath`.
- **F-13, F-14, F-15**: Docs-only polish and optional observability hook.

### New capabilities worth considering once the above lands

These are **not** defects — they are natural next steps implied by the architecture:

- **Namespace the CLI exit codes explicitly** and surface a `--exit-policy` flag so scripts
  can opt into stricter or more permissive behavior.
- **Add `notebook delete-cell` and `notebook insert-cell` to the documented patch operations**
  (both are implemented in the Python `apply_patch_spec` but only `append_cell`,
  `replace_cell`, and `set_option` are advertised in `usage-reference.md`).
- **Add `kernel eval --json-result`** or similar, which would export `ExportString[res,
  "ExpressionJSON"]` or `RawJSON` for result values that happen to be JSON-representable,
  side-stepping the "everything is a stringified InputForm" limitation for common cases
  like `{"a" -> 1, "b" -> "x"}`.
- **Add a lightweight smoke-benchmark mode** to `scripts/Test-TungstenSmoke.ps1` that runs
  `kernel eval "2+2"` N times and reports p50/p99 latency. Useful as a regression guard
  once the Wolfram startup cost lands on the critical path.
- **Provide a `Trace-TungstenCall` or `tungsten --trace`** that captures the generated
  wrapper script + JSON payload + subprocess command into a debug bundle.

## Closing thoughts

A few broader observations that don't fit in the findings list:

- **The project benefits from resisting scope creep.** The explicit non-goals in the README,
  the deliberately narrow expression evaluator, the choice to not wrap the entire FrontEnd
  API — these are the right calls for a project that wants to stay useful over time rather
  than become a full Wolfram reimplementation. Keep saying "no" to features that would
  force Tungsten to grow a second parser, a second kernel substrate, or a second automation
  framework.
- **The Wolfram wrapper script is actually the most valuable technical artifact in the
  project.** It is the thing other people can't easily reinvent. Treat it with the care
  it deserves — test it, document it, and resist the urge to let it sprawl inline across
  multiple builder methods.
- **The notebook-structural parser is more capable than it looks.** Once fixed points like
  the shared Wolfram-string helpers land, the same structural core could reasonably support
  extra patch operations, a Wolfram-free `notebook diff` command, and perhaps a structural
  `notebook move-cell` that is surprisingly hard to do well via FE automation.
- **The `.NET` + `PowerShell` + `CLI` triple is the right distribution model** for this
  kind of repo-local tool. The JSON contract is the backbone. Protect it as the project
  grows; it is the single interface that makes the other two layers cheap.
- **The documentation is unusually good.** It is the kind of doc set that makes a reviewer
  want to contribute. The notes above about inconsistencies and minor gaps should be read
  against a strong baseline — most WIPs don't have a docs tree this coherent.

Overall: this is a solid foundation. The biggest actionable item is F-1 (the
`result_head` bug), because it silently ships incorrect data on every kernel evaluation
and is invisible to existing tests. Everything else is incremental polish — worth doing,
not urgent.

Nice work, Vladimir. This was genuinely pleasant to review.
