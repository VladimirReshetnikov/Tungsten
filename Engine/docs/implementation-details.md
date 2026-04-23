# Tungsten Implementation Details

Created (UTC): 2026-04-23T02:16:55Z  
Repository HEAD: e809b942e10d2495fa5a680a33e6009412da447a

## Local machine findings that materially shaped Tungsten

### 1. The installation is complete enough for real automation

The machine has a real Wolfram 14.3 installation with:

- `wolfram.exe`
- `WolframKernel.exe`
- `WolframNB.exe`
- `wolframscript.exe`
- the local documentation corpus under `Common Files\Wolfram Research\Documentation.en-us\14.3`
- the bundled `WolframClientForPython` source tree

That was enough to justify a real framework rather than a file-only notebook utility.

### 2. The `mathpass` file is the critical operational wrinkle

The installed `mathpass` contains duplicate license entries. With the original file:

- `wolframscript -code ...` fails with a license/password error;
- the full raw `mathpass` causes command-line evaluation failures;
- a deduplicated copy works;
- even a file containing a single license entry works.

Tungsten therefore always executes the kernel against a temporary deduplicated `mathpass` and never mutates the installed system file.

### 3. The bundled Wolfram Python client is present but not runtime-clean

The local `WolframClientForPython` tree is importable, but importing its higher-level evaluation surface pulls in missing dependencies such as `oauthlib`. That made it a poor default runtime dependency for this machine.

The framework therefore uses the documented `wolfram.exe` CLI as the execution substrate and treats the bundled Python client as contextual reference material rather than as the primary runtime.

### 4. `UsingFrontEnd[...]` works on this machine

Once Tungsten supplies a deduplicated password file, kernel-side FrontEnd actions work, including hidden document creation and close. That is why the framework exposes real FrontEnd automation commands rather than only file-based notebook operations.

## Why the evaluator returns strings for results

Arbitrary Wolfram expressions do not map cleanly onto JSON. Rather than pretending otherwise, Tungsten returns:

- `result` as an `InputForm` string;
- `result_head` as an `InputForm` string;
- `messages` and `messages_text` as string lists;
- `timing` fields as numeric values when available.

That keeps the result payload stable across symbolic, graphical, and FrontEnd object results, and it means PowerShell callers always receive something representable.

## Why notebook editing is structural rather than semantic

Notebook files are ordinary Wolfram expressions, but full Wolfram parsing is not a reasonable dependency for a small repository-local automation framework. Tungsten therefore parses exactly the parts that matter for notebook manipulation:

- top-level notebook options;
- cells;
- cell groups.

When precise semantic interpretation is needed, callers can still use the kernel and FrontEnd APIs. Tungsten’s local parser is deliberately the fallback and bulk-edit tool, not a replacement for the full language.

## Why documentation search is file-backed instead of browser-backed

The local documentation notebooks are already the authoritative installation-aligned corpus. Indexing them directly has several advantages:

- it works offline;
- it respects the exact installed version and any local documentation paclet updates;
- it avoids browser automation;
- it makes `docs read` and `docs search` available even when the FrontEnd is not open.

The cost is that the extracted text is approximate rather than a polished final rendering. That tradeoff is acceptable for agent workflows.

## WinDesk relationship

Tungsten does not require WinDesk at runtime. However, WinDesk is explicitly useful for:

- optional visible-window capture during FrontEnd smoke tests;
- future richer verification of notebook/documentation windows;
- future UIA-based assertions if the project grows beyond token/document open flows.

The smoke script therefore includes an optional `-UseWinDesk` path that attempts capture only when the WinDesk PowerShell module has already been built.
