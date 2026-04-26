# Tungsten REPL

- Status: Informational and reference-oriented (console-mode kernel-free interpreter)
- Audience: Tungsten users, script authors, maintainers, and testers comparing Tungsten with `wolfram.exe`
- Scope: `src/Tungsten/src/tungsten/repl.py`, `src/Tungsten/src/tungsten/expression.py`, and the `tungsten` console entry point
- Created (UTC): 2026-04-25T21:57:56Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a
- Related docs:
  - [Usage Reference](./usage-reference.md)
  - [Expression Parser](./expression-parser.md)
  - [Symbol and Context Registry](./symbol-context-registry.md)
  - [Structural Expression Function Support](./expression-function-support.md)

## Purpose

The Tungsten REPL is a console-mode, kernel-free interpreter for Tungsten's structural Wolfram
Language subset. It is intentionally shaped like `wolfram.exe`: it prints `In[n]:=` prompts,
prints successful results as `Out[n]= ...`, and maintains line-local history values for the
session.

The REPL does not launch the Wolfram kernel. It uses Tungsten's offline parser and structural
evaluator, so it is useful for quick structural experiments, parser debugging, and agent scripts
that want Wolfram-like interaction without consuming a kernel license seat.

## Starting It

From a source checkout:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
python -m tungsten repl
```

Running `python -m tungsten` with no arguments starts the same REPL.

After installing Tungsten as an editable or packaged Python project, the `pyproject.toml`
`project.scripts` entry point creates a Windows console launcher named `tungsten.exe`:

```powershell
python -m pip install -e .\src\Tungsten
tungsten.exe
```

The repository also includes a small .NET console launcher at
`dotnet/Tungsten.Console`. It builds to `dotnet/Tungsten.Console/bin/<configuration>/net10.0/tungsten.exe`
and delegates to `python -m tungsten` with the source tree added to `PYTHONPATH` when it can find
the checkout:

```powershell
dotnet build .\src\Tungsten\dotnet\Tungsten.DotNet.slnx
.\src\Tungsten\dotnet\Tungsten.Console\bin\Debug\net10.0\tungsten.exe
```

The launcher keeps the existing JSON-first CLI surface intact. Supplying subcommands such as
`tungsten.exe expr evaluate --code "1+2"` still runs the ordinary CLI command; invoking
`tungsten.exe` without arguments starts the REPL.

## Session Values

The REPL maintains these Wolfram-style session values:

- `$Line` evaluates to the current input line number while that input is being evaluated.
- `In[n]` returns the delayed input expression for line `n` and then evaluates it.
- `In[]` is shorthand for the previous input expression.
- `In[-k]` addresses input relative to the current line.
- `InString[n]` returns the exact submitted text for line `n` as a string.
- `InString[]` and `InString[-k]` use the same previous / relative addressing convention.
- `Out[n]` returns the stored output expression for line `n`.
- `Out[]` and `Out[-k]` use the same previous / relative addressing convention.
- `%`, `%%`, and `%n` parse as `Out[-1]`, `Out[-2]`, and `Out[n]`, respectively.

The line is recorded before evaluation begins, matching the important `wolfram.exe` behavior that
`DownValues[In]` for the current line already includes that line's input.

## Main-Loop Hooks

The REPL supports Tungsten's session subset of Wolfram main-loop hooks:

```wolfram
$PreRead = Function[s, StringReplace[s, "sq" -> "Sqrt"]]
$Pre = Function[x, HoldForm[x], HoldAll]
$Post = FullForm
$PrePrint = InputForm
$MessagePrePrint = FullForm
```

Hook order follows the console model:

- `$PreRead` is applied to the complete input string before parsing and before `InString[n]` is
  stored. If it returns a non-string, Tungsten emits `$PreRead::prstr` and parses the original
  string.
- `In[n]` stores the parsed expression after `$PreRead`, but before `$Pre`.
- `$Pre` is applied before ordinary evaluation.
- `$Post` is applied after ordinary evaluation and before `Out[n]` is stored.
- `$PrePrint` is applied only to the displayed expression after `Out[n]` is stored, so it does not
  affect `%` or `Out[n]`.
- `$MessagePrePrint` is applied to message insertions before Tungsten renders message text.

Hook bodies are evaluated with main-loop hooks suppressed to avoid recursive `$Pre` / `$Post` /
`$PrePrint` application while the hook itself is running.

## DownValues

`DownValues` is implemented only in read-only session-history form:

```wolfram
DownValues[In]
DownValues[InString]
DownValues[Out]
```

The returned shape mirrors Wolfram's ordinary structure:

```wolfram
{HoldPattern[In[1]] :> 1 + 2, HoldPattern[In[2]] :> $Line}
```

Tungsten does not implement mutable definitions here. `DownValues[userSymbol]` returns `{}` and
there is no support yet for assigning to `DownValues`, defining functions with `:=`, or inspecting
general built-in definitions.

## Exiting

The REPL exits on any of these forms:

```wolfram
Exit
Exit[]
Exit[code]
Quit
Quit[]
Quit[code]
```

The optional integer code becomes the process exit code. Non-integer exit-code arguments report an
evaluation error and leave the session running.

## Deliberate Differences From `wolfram.exe`

Tungsten matches the console shape and history state that matter for offline structural work, but
it is not a drop-in Wolfram kernel:

- Evaluation is limited to Tungsten's implemented structural subset.
- Output rendering is Tungsten `InputForm`-like for most expressions, with top-level strings shown
  without quotes to resemble the ordinary Wolfram console. Outermost display wrappers use
  Wolfram-style labels and text: `InputForm[expr]` prints as `Out[n]//InputForm= ...`,
  `FullForm[expr]` prints as `Out[n]//FullForm= ...`, and the same display selection is used
  for `Print[InputForm[expr]]`, `Print[FullForm[expr]]`, `OutputForm[expr]`, and
  `StandardForm[expr]`.
- Syntax errors and evaluation errors are reported with Tungsten messages rather than exact Wolfram
  message names and formatting.
- The REPL currently reads one input line at a time; full Wolfram multi-line input recovery is out
  of scope for this pass.
