# Tungsten Troubleshooting

- Status: Informational and operational (diagnostics, failure modes, and recovery guidance)
- Audience: Tungsten users and maintainers diagnosing local-environment, kernel, FrontEnd, assistant, or parser failures
- Scope: `Engine` runtime behavior on a local Windows machine
- Created (UTC): 2026-04-23T15:36:45Z
- Updated (UTC): 2026-07-18T04:31:20Z
- Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7
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
- PowerShell cannot find `tungsten-cpp` or cannot import the Tungsten module correctly.

This document gives a practical recovery path for each of those cases.

The kernel-free native executable and its failure paths can also be exercised on Linux, but the
installation, licensing, process-seat, FrontEnd, documentation, and assistant guidance below is
Windows/Wolfram-specific. Those live paths were not validated by the Linux native-runtime pass.

## Build or locate the native executable first

From the repository root:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release --target tungsten-cpp
Pop-Location
```

Direct callers can run `Engine\build\cpp\Release\tungsten-cpp.exe` for a typical Windows
multi-configuration build or `Engine\build\cpp\tungsten-cpp` for a typical single-configuration
build. The PowerShell module and the repository-aware .NET option factories honor
`TUNGSTEN_EXECUTABLE`; otherwise they check the repository build locations and then `PATH`. A
plain `TungstenClientOptions` instance uses `tungsten-cpp` from `PATH` unless its executable path is
set explicitly.

The native library requires GMP and GMPXX headers/libraries that are ABI-compatible with the build
toolchain and with each other. If configuration succeeds but linking or a downstream consumer
fails, first check architecture, runtime-library, and GMP installation consistency. The current
verification record does not include a live MSVC/Visual Studio or macOS build, so validate those
platforms locally before treating a packaged binary as supported.

## First diagnostic commands to run

These are the fastest high-signal checks:

```powershell
tungsten-cpp env show --probe
tungsten-cpp kernel eval --code "2+2"
tungsten-cpp frontend probe
tungsten-cpp docs search NotebookGet
tungsten-cpp expr evaluate --code "Level[f[a, g[b]], -1]"
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

- Run `tungsten-cpp env show`.
- Verify that the local installation really exists at the expected path, for example:
  `C:\Program Files\Wolfram Research\Wolfram\15.0`.

### Recovery

- Set `TUNGSTEN_WOLFRAM_HOME` to the installation root if the installation lives in a
  non-default location.
- Set `TUNGSTEN_WOLFRAM_PRODUCT=engine` only when you intentionally want the installed
  Wolfram Engine for Developers 14.3 runtime instead of paid Wolfram 15.0.
- Re-run `tungsten-cpp env show` to verify discovery.

## Problem: Kernel evaluation does not produce a structured payload

### Symptoms

- `evaluation_available` is `false`.
- `json_path` is `null`.
- `stderr` contains an evaluation or launch failure.
- the process exit code is `2`.

### Checks

- Run `tungsten-cpp kernel eval --code "2+2"`.
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

The Windows launcher currently enables broad handle inheritance for the child process. This is
appropriate for Tungsten's trusted local automation model, but an embedding host with sensitive
inheritable handles should de-inherit or close them before launching Wolfram.

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
tungsten-cpp frontend probe
```

If the kernel probe works but the FrontEnd probe does not, the problem is specifically in the FE
path rather than in the base Tungsten installation discovery.

### Recovery

- Verify that the local Wolfram FrontEnd executable is present and discoverable.
- Close any obviously wedged FrontEnd instances and retry.
- Retry a minimal FE operation before a complex one:

  ```powershell
  tungsten-cpp frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> False]]"
  ```

## Problem: Documentation search returns poor results or no results

### Symptoms

- `docs search` returns no hits for obvious documentation pages.
- The result set appears stale after local documentation paclet updates.

### Checks

- Inspect `env show` and confirm `docs_roots` is populated.
- Rebuild the index explicitly:

  ```powershell
  tungsten-cpp docs index
  tungsten-cpp docs search NotebookGet --rebuild
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
tungsten-cpp notebook inspect --file C:\path\to\file.nb
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

## Problem: PowerShell wrappers cannot find the native executable

### Symptoms

- Tungsten PowerShell commands report that `tungsten-cpp` could not be found or started.

### Recovery

- Build the native executable with CMake and confirm either
  `Engine/build/cpp/tungsten-cpp.exe` or a multi-configuration output such as
  `Engine/build/cpp/Release/tungsten-cpp.exe` exists.
- Set `TUNGSTEN_EXECUTABLE` to the exact executable path when using a nonstandard build layout.
- Otherwise place `tungsten-cpp` on `PATH` and confirm `Get-Command tungsten-cpp` succeeds.
- Re-import `Engine/pwsh/Tungsten.psd1` after changing the environment.

## Problem: The expression parser rejects valid Wolfram syntax you expected it to support

### Important boundary

The Tungsten expression subsystem is intentionally narrower than the Wolfram parser in the real
kernel. It currently supports:

- FullForm;
- InputForm;
- a pragmatic StandardForm subset, including common semantic box forms such as `FractionBox`,
  `SqrtBox`, `RadicalBox`, `SuperscriptBox`, `SubscriptBox`, related script boxes, and common
  named-character operators;
- a broad but bounded native evaluator whose unsupported heads remain symbolic.

It does not attempt full box language, arbitrary StandardForm surface syntax, or general kernel
semantics.

### Recovery

- Fall back to `kernel eval` if you genuinely need the real Wolfram parser/evaluator.
- Reduce the expression to the supported textual subset if your goal is structural analysis rather
  than full evaluation.
- Inspect the structured `success`, `error_type`, and `error` fields from `expr parse` or
  `expr evaluate`; Tungsten now reports syntax and inert-evaluation failures as JSON rather than as
  unstructured host-language exceptions.

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

## Problem: Text contains U+FFFD or a notebook patch reports invalid UTF-8

### Meaning

Tungsten uses two deliberate text-input policies:

- saved notebooks, documentation notebooks, parser-corpus files, `mathpass`, and captured kernel
  stdout/stderr decode malformed UTF-8 with the same replacement boundaries as Python's
  `errors="replace"`; malformed byte subsequences therefore appear as U+FFFD (`�`);
- notebook patch JSON must be valid UTF-8 and valid JSON, so an invalid patch file is rejected
  rather than decoded lossily.

An empty patch object `{}` is a supported no-op. Non-empty patch operations require correctly typed
fields, non-negative bounded paths, and in-range insertion indices; native patching does not coerce
invalid values or clamp an out-of-range insertion as Python's `list.insert` would.

Native JSON output escapes non-ASCII characters by default. Seeing `\u03b1` or a surrogate pair in
raw output is normal JSON serialization, not evidence that the original Unicode text was damaged.

### Recovery

- Re-encode the source or patch as UTF-8 without a legacy code page or malformed byte sequence.
- For a damaged notebook that still parses structurally, inspect the affected cell before saving;
  saving a modified document will preserve the decoded U+FFFD character, not the original invalid
  bytes.
- For a patch file, fix the encoding rather than substituting replacement characters into the
  operation payload.

## Problem: Smoke or tests fail intermittently while other Wolfram work is running

### Meaning

Tungsten's kernel and FrontEnd tests are integration-heavy compared to pure unit tests. Running
multiple FE-heavy or kernel-heavy validation paths in parallel can create misleading transient
failures.

The smoke runner now starts with parser, 82-step stateful evaluator (`--require-perfect`), full
recorded-evaluator (`--require-perfect`), and 119-case CLI parity gates. A deterministic failure in
one of those gates is a native compatibility regression, not Wolfram license or desktop contention.

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

The most relevant source files are under `cpp/src/`: `discovery.cpp`, `licensing.cpp`,
`kernel.cpp`, `notebook.cpp`, `docs_index.cpp`, `frontend.cpp`, `assistant.cpp`, `parser.cpp`, and
`evaluator.cpp`. Their public interfaces are under `cpp/include/tungsten/`.
