# Tungsten Implementation Details

Created (UTC): 2026-04-23T02:16:55Z  
Updated (UTC): 2026-04-23T14:55:38Z  
Repository HEAD: 57ab7a5664bc31c13cc3fad044e00d2246b0f07e

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

### 5. Notebook Assistant automation is reliable through a hidden chat notebook

The first obvious design for Notebook Assistant automation was to drive the visible inline assistant attached to the target cell, because that is what a human user naturally does in the FrontEnd. Tungsten still exposes that path as an experimental backend, but it turned out to be the wrong default for robust automation.

The reason is that inline assistant state is FrontEnd-local dynamic state. It is easy for a human to see and continue interacting with it, but much harder for a later helper-kernel call to rediscover and interpret reliably. In practice that produced a fragile split workflow:

- one pass to open the inline assistant;
- a desktop automation layer to type into it;
- another pass to rediscover the transient attached-cell state and harvest the output.

Tungsten now defaults to a different design:

- read the selected source cell from the real notebook;
- create a temporary hidden Chatbook notebook;
- evaluate a `ChatInput` cell against the built-in assistant stack with `ChatCellEvaluate`;
- parse the returned `ChatObject` text in Python;
- extract Wolfram Language code blocks from the assistant reply;
- insert those code blocks below the original source cell in the real notebook.

This is still using Mathematica's built-in assistant machinery. The change is that Tungsten routes the interaction through a text-automation-friendly surface rather than through transient visible inline UI state.

### 6. Generic expression parsing needed its own subsystem

The existing notebook parser was intentionally structural and notebook-specific. It was good at splitting `Notebook[...]`, `Cell[...]`, and option lists, but it was not the right foundation for a general Wolfram expression AST with operator precedence, implicit `Times`, `Part` syntax, spans, and structural operations such as `Level`.

Tungsten therefore now has a separate `expression.py` subsystem with:

- an explicit AST for symbols, strings, numbers, and general expressions;
- a tokenizer that skips nested Wolfram comments and understands ambiguous tokens such as `[[` and plain `]`;
- a Pratt-style parser for textual Wolfram syntax;
- canonical FullForm rendering;
- a deliberately small inert evaluator for structural built-ins.

Keeping that subsystem separate from `notebook.py` preserves a clean boundary:

- `notebook.py` remains a resilient structural notebook tool;
- `expression.py` is the general-purpose Wolfram expression model.

### 7. The expression evaluator is intentionally narrow

The new evaluator does not try to reproduce kernel semantics wholesale. It only knows about a small set of structural built-ins:

- `Length`
- `Depth`
- `Head`
- `Part`
- `Extract`
- `Level`

Everything else remains inert, including heads like `Plus`, `Times`, and `Power`. That keeps the implementation predictable and honest. For example, `1 + 2` parses to `Plus[1, 2]`, but `Length[1 + 2]` still works because `Length` is explicitly implemented.

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
- the experimental `DesktopInline` Notebook Assistant backend, which drives the visible inline assistant UI;
- future richer verification of notebook/documentation windows;
- future UIA-based assertions if the project grows beyond token/document open flows.

The smoke script therefore includes optional `-UseWinDesk` and `-IncludeAssistant` paths. The recommended assistant backend does not require WinDesk, but the visible inline-desktop backend does.
