# Tungsten Troubleshooting

- Status: Informational and operational (diagnostics, failure modes, and recovery guidance)
- Audience: Tungsten users and maintainers diagnosing local-environment, kernel, FrontEnd, assistant, or parser failures
- Scope: `Engine` runtime behavior on a local Windows machine
- Created (UTC): 2026-04-23T15:36:45Z
- Updated (UTC): 2026-04-24T20:06:49Z
- Repository HEAD: 110bbc4bc5b6ce3af5afd0e8cabbfef42d15a55e
- Related docs:
  - [Project README](../README.md)
  - [User Guide](./user-guide.md)
  - [Usage Reference](./usage-reference.md)
  - [Implementation Details](./implementation-details.md)

## Summary

Tungsten is intentionally honest about environment facts and failure modes. Most user-visible
problems fall into one of a handful of categories:

- Tungsten cannot discover the local Wolfram installation.
- The kernel exists, but evaluation does not produce the expected structured JSON payload.
- The FrontEnd is unavailable or cannot complete the requested operation.
- Documentation indexing/search is stale or incomplete.
- Notebook Assistant automation cannot find or resolve the requested cell.
- The kernel-free expression parser rejects syntax outside its intended subset.
- PowerShell cannot find `python` or cannot import the Tungsten module correctly.

This document gives a practical recovery path for each of those cases.

## First diagnostic commands to run

These are the fastest high-signal checks:

```powershell
$env:PYTHONPATH = (Resolve-Path .\Engine\src)
python -m tungsten env show --probe
python -m tungsten kernel eval --code "2+2"
python -m tungsten frontend probe
python -m tungsten docs search NotebookGet
python -m tungsten expr evaluate --code "Level[f[a, g[b]], -1]"
```

Or from PowerShell:

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force

Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
Find-TungstenDocumentation -Query "NotebookGet"
Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
```

If those five checks behave as expected, the core Tungsten stack is usually healthy.

## Problem: Tungsten cannot discover the local Wolfram installation

### Symptoms

- `env show` reports `install_dir: null`.
- `kernel eval` returns `failure_type: KernelNotFound`.
- FrontEnd and assistant workflows fail immediately because the discovered executables are missing.

### Checks

- Run `python -m tungsten env show`.
- Verify that the local installation really exists at the expected path, for example:
  `C:\Program Files\Wolfram Research\Wolfram\15.0`.

### Recovery

- Set `TUNGSTEN_WOLFRAM_HOME` to the installation root if the installation lives in a
  non-default location.
- Set `TUNGSTEN_WOLFRAM_PRODUCT=engine` only when you intentionally want the installed
  Wolfram Engine for Developers 14.3 runtime instead of paid Wolfram 15.0.
- Re-run `python -m tungsten env show` to verify discovery.

## Problem: Kernel evaluation does not produce a structured payload

### Symptoms

- `evaluation_available` is `false`.
- `json_path` is `null`.
- `stderr` contains an evaluation or launch failure.
- the process exit code is `2`.

### Checks

- Run `python -m tungsten kernel eval --code "2+2"`.
- Inspect `exit_code`, `stderr`, `evaluation_available`, and the `mathpass` payload.

### Common causes

- `wolfram.exe` exists but cannot run successfully under the current environment.
- Licensing is failing before Tungsten's wrapper script can export the result payload.
- The wrapper script itself hit a parse/evaluation failure before payload export.

### Recovery

- Confirm `env show` reports the expected `kernel_cli` path.
- Confirm `mathpass` is discoverable.
- Inspect `stderr` first. Tungsten intentionally preserves it.
- Re-run with a tiny expression such as `2+2` before diagnosing a larger workload.

## Problem: Licensing or `mathpass` behavior is confusing

### Important context

On this machine, the selected product's installed `mathpass` has historically contained duplicate
license entries. Tungsten works around that by writing a temporary deduplicated copy and invoking:

```text
wolfram.exe -noprompt -pwfile <temporary-copy> -script <wrapper>
```

Tungsten also now:

- serializes its own kernel launches through a machine-wide launch gate;
- records the observed controlling-process ceiling from successful runs;
- scans existing Wolfram-related processes before launch;
- cleans up orphaned Tungsten-owned headless kernels from obviously stale prior runs.

### What to inspect

The kernel result payload includes:

- `mathpass.path`
- `mathpass.header_present`
- `mathpass.original_line_count`
- `mathpass.unique_entry_count`
- `mathpass.duplicate_entry_count`
- `used_mathpass_workaround`
- `license_processes`
- `max_license_processes`
- `cached_max_license_processes`
- `launch_gate_wait_seconds`
- `license_wait_seconds`
- `license_wait_satisfied`
- `cleaned_tungsten_processes`
- `observed_wolfram_processes`

### What to expect

- `used_mathpass_workaround` will typically be `true` on this machine.
- The deduplicated temporary file is intentional and not an error condition.
- If `observed_wolfram_processes` contains old headless `wolfram.exe` / `WolframKernel.exe`
  entries, they may be consuming scarce controlling-process seats.
- On this machine, with **two** licenses now activated (see
  [`wolfram-license-parallelism.md`](wolfram-license-parallelism.md)), successful live runs report
  `max_license_processes = 4`, so up to four concurrent main kernels are available; once that many
  are live (e.g. orphaned batch kernels plus fresh launches), the next launch is refused for lack
  of a seat.

## Problem: FrontEnd operations fail

### Symptoms

- `frontend probe` reports failure.
- `frontend open-notebook`, `docs open`, or assistant workflows fail even though kernel-only
  evaluation succeeds.

### Checks

```powershell
python -m tungsten frontend probe
```

If the kernel probe works but the FrontEnd probe does not, the problem is specifically in the FE
path rather than in the base Tungsten installation discovery.

### Recovery

- Verify that the local Wolfram FrontEnd executable is present and discoverable.
- Close any obviously wedged FrontEnd instances and retry.
- Retry a minimal FE operation before a complex one:

  ```powershell
  python -m tungsten frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> False]]"
  ```

## Problem: Documentation search returns poor results or no results

### Symptoms

- `docs search` returns no hits for obvious documentation pages.
- The result set appears stale after local documentation paclet updates.

### Checks

- Inspect `env show` and confirm `docs_roots` is populated.
- Rebuild the index explicitly:

  ```powershell
  python -m tungsten docs index
  python -m tungsten docs search NotebookGet --rebuild
  ```

### Important behavior

- Tungsten indexes the local `*.nb` documentation files themselves.
- Search quality is intentionally approximate rather than semantically perfect.
- `docs read` and `docs search` are installation-aligned, which is the point of the local index.

## Problem: Notebook Assistant cannot find the requested cell

### Symptoms

- Assistant payloads report `CellNotFound` or selector ambiguity.
- The selected cell works in the GUI but not through Tungsten.

### Checks

Inspect the notebook first:

```powershell
python -m tungsten notebook inspect --file C:\path\to\file.nb
```

Then verify which of these selectors you are using:

- `--expression-uuid`
- `--cell-id`
- `--cell-tag`
- `--cell-path`
- `--cell-index`

### Practical guidance

- Prefer `ExpressionUUID` when available.
- Use `CellIndex` when working with freshly generated or synthetic notebooks that do not yet have
  stable UUIDs.
- Use `CellTag` only when you know it is unique enough for the notebook in question.

## Problem: Notebook Assistant succeeds but no code is inserted

### Symptoms

- `assistant_success` is `true`, but `inserted` is empty.

### Meaning

This often means the assistant replied, but Tungsten did not find any Wolfram Language code blocks
that it considers insertable.

### Checks

Inspect:

- `assistant.response_text`
- `assistant.code_blocks`
- `assistant.wolfram_code_blocks`

### Recovery

- Ask a more constrained question such as:
  `Reply only with Wolfram Language code that ...`
- Use `--insert-all-wolfram-code-below` if you expect multiple WL code blocks.

## Problem: Inline-box extraction reports no objects

### Symptoms

- `inline-box from-cell` returns `NoInlineBoxObjectsFound`.
- `Get-TungstenNotebookCellInlineBoxes` reports success `false`.

### Meaning

The selected saved cell did not contain:

- a top-level `BoxData[...]` object;
- or a string literal that already contains inline box escapes such as `\!\(\*...\)`.

### Recovery

- Inspect the notebook cell with `notebook inspect` and make sure you selected the intended cell.
- Confirm the notebook has been saved if you are expecting recently generated output to be present.
- Try an output cell or a cell that visibly contains an inline object rather than a plain text or
  plain input cell.
- If you need live unsaved FrontEnd selection capture, that is outside the current saved-notebook
  scope of the feature.

## Problem: The visible inline assistant path is flaky

### Context

This is exactly why the default backend is not the visible inline popup.

### Symptoms

- Window activation or input injection fails.
- The inline assistant opens, but Tungsten cannot harvest the result reliably.

### Recovery

- Prefer the default `NotebookChatCell` backend.
- Use `DesktopInline` only when you specifically want visible UI-level automation.
- Ensure the notebook window is visible, not minimized, and can become foreground.
- Ensure WinDesk is available if you are depending on the desktop path. WinDesk is not part of this repository — it lives in the sibling [`Tools`](https://github.com/VladimirReshetnikov/Tools) repository. Build `WinDesk.PowerShell` there, then either pre-import the module or set `$env:TUNGSTEN_WINDESK_MODULE_PATH` to the built `WinDesk.PowerShell.dll`.

## Problem: PowerShell cannot find the Tungsten wrapper functions

### Symptoms

- `Get-TungstenEnvironment` or `Invoke-TungstenNotebookAssistant` is not recognized.

### Recovery

- Import the module explicitly:

  ```powershell
  Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
  ```

- Verify it loaded:

  ```powershell
  Get-Command -Module Tungsten
  ```

## Problem: PowerShell wrappers fail because `python` is missing

### Symptoms

- Tungsten PowerShell commands throw `python was not found on PATH.`

### Recovery

- Verify `python` is installed and on `PATH`.
- If necessary, use the repository's Python installation workflow described in the repo guidance.
- Re-run the PowerShell command after confirming `Get-Command python` succeeds.

## Problem: The expression parser rejects valid Wolfram syntax you expected it to support

### Important boundary

The Tungsten expression subsystem is intentionally narrower than the Wolfram parser in the real
kernel. It currently supports:

- FullForm;
- InputForm;
- a pragmatic StandardForm subset, including common semantic box forms such as `FractionBox`,
  `SqrtBox`, `RadicalBox`, `SuperscriptBox`, `SubscriptBox`, related script boxes, and common
  named-character operators;
- a small inert evaluator for structural built-ins.

It does not attempt full box language, arbitrary StandardForm surface syntax, or general kernel
semantics.

### Recovery

- Fall back to `kernel eval` if you genuinely need the real Wolfram parser/evaluator.
- Reduce the expression to the supported textual subset if your goal is structural analysis rather
  than full evaluation.
- Inspect the structured `success`, `error_type`, and `error` fields from `expr parse` or
  `expr evaluate`; Tungsten now reports syntax and inert-evaluation failures as JSON rather than as
  raw Python tracebacks.

## Problem: Canonical `input_form` output is different from the original source text

### Example

Parsing:

```text
1 + 2 x^3
```

may produce canonical `input_form` like:

```text
1 + (2 * (x^3))
```

### Meaning

This is expected. Tungsten's expression subsystem renders a canonicalized textual form of its AST;
it is not trying to preserve the user's exact original formatting token-for-token.

## Problem: Smoke or tests fail intermittently while other Wolfram work is running

### Meaning

Tungsten's kernel and FrontEnd tests are integration-heavy compared to pure unit tests. Running
multiple FE-heavy or kernel-heavy validation paths in parallel can create misleading transient
failures.

### Recovery

- Re-run the smoke serially:

  ```powershell
  pwsh -File .\Engine\scripts\Test-TungstenSmoke.ps1
  ```

- If necessary, close stray FrontEnd sessions and retry.

## When to escalate from docs to code inspection

Use the docs first, but inspect code directly when:

- a payload field looks surprising;
- you are extending Tungsten rather than merely using it;
- the failure path appears to come from the wrapper surface rather than from the Wolfram runtime.

The most relevant source files are:

- `src/tungsten/discovery.py`
- `src/tungsten/licensing.py`
- `src/tungsten/kernel.py`
- `src/tungsten/notebook.py`
- `src/tungsten/docs_index.py`
- `src/tungsten/frontend.py`
- `src/tungsten/assistant.py`
- `src/tungsten/expression.py`
