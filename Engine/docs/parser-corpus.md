# Tungsten Parser Corpus

- Status: Operational test-infrastructure reference
- Audience: Tungsten maintainers and parser/evaluator contributors
- Scope: Local parser-corpus discovery, Tungsten parser runs, and Wolfram held-parser comparison
- Created (UTC): 2026-04-25T00:50:09Z
- Updated (UTC): 2026-07-18T04:22:20Z
- Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7
- Related docs:
  - [Project README](../README.md)
  - [Usage Reference](./usage-reference.md)
  - [Expression Parser](./expression-parser.md)
  - [Troubleshooting](./troubleshooting.md)

## Purpose

The local parser corpus at `C:\TestData\wolfram\tungsten-wolfram-parser-corpus` is a stress corpus for
Tungsten's Wolfram Language parsers. It intentionally contains notebooks, packages, scripts, tests,
and some noisy false positives such as non-Wolfram `.m` files discovered from public repositories.

The corpus is local-only test data. Do not bundle it into Tungsten, publish it as a Tungsten
artifact, or treat parser-corpus results as license clearance for redistribution.

## Wolfram Comparison Model

The Wolfram side is parser-only. Tungsten generates a Wolfram script that imports each selected file
as text and calls:

```wolfram
ToExpression[text, InputForm, HoldComplete]
```

The held expression is never released, so packages and notebooks are parsed but not evaluated. This
lets the local Wolfram kernel serve as an acceptance oracle for syntax while avoiding side effects
from arbitrary corpus code.

The comparison classifies each file as:

- `both_success`: Tungsten and Wolfram both accepted the file.
- `tungsten_gap`: Wolfram accepted the file but Tungsten rejected it.
- `tungsten_only_success`: Tungsten accepted the file but Wolfram rejected it.
- `both_fail`: both parsers rejected the file.
- `skipped`: at least one side skipped the file, usually because of `--max-file-mb` or
  `--skip-wolfram`.

## CLI

Build `tungsten-cpp` with CMake and invoke it by path or place it on `PATH`. The parser-corpus
command has no Python runtime dependency:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release --target tungsten-cpp
Pop-Location
```

On a multi-configuration Windows generator the executable is normally
`Engine\build\cpp\Release\tungsten-cpp.exe`; on a single-configuration generator it is normally
`Engine\build\cpp\tungsten-cpp`. The examples below assume that executable is available as
`tungsten-cpp` on `PATH`.

Discover the current corpus selection:

```powershell
tungsten-cpp parser-corpus discover `
    --corpus-root C:\TestData\wolfram\tungsten-wolfram-parser-corpus `
    --sample 30
```

Run a bounded comparison and write artifacts under
`C:\TestData\wolfram\tungsten-wolfram-parser-corpus\validation`:

```powershell
tungsten-cpp parser-corpus compare `
    --corpus-root C:\TestData\wolfram\tungsten-wolfram-parser-corpus `
    --max-files 100 `
    --max-file-mb 2 `
    --kernel-batch-size 100 `
    --tungsten-workers 8
```

Run Tungsten only, without launching Wolfram:

```powershell
tungsten-cpp parser-corpus compare `
    --corpus-root C:\TestData\wolfram\tungsten-wolfram-parser-corpus `
    --skip-wolfram `
    --no-write `
    --include-results
```

Focus on a specific subtree or extension:

```powershell
tungsten-cpp parser-corpus compare `
    --include-glob "github/wolframresearch-codeparser/**" `
    --extension wl `
    --extension m `
    --max-files 200
```

Useful failure switches:

- `--fail-on-tungsten-gap`: returns exit code `1` if Wolfram accepts any file that Tungsten rejects.
- `--fail-on-mismatch`: returns exit code `1` for either `tungsten_gap` or
  `tungsten_only_success`.

These switches are intended for focused subsets or milestone gates. The full corpus is expected to
contain many known gaps while Tungsten is still growing toward full Wolfram Language syntax.

Performance-oriented options:

- `--kernel-batch-size <n>` controls how many files each Wolfram kernel launch parses. The default
  is `100`; larger batches reduce kernel startup overhead but delay partial results if one batch is
  interrupted.
- `--tungsten-workers <n>` controls local worker threads for Tungsten-side parsing. Results retain
  corpus order even when work is concurrent.

## Discovery, Filtering, and Sampling Compatibility

The selected file order is a compatibility surface because it is recorded in comparison artifacts.
The native implementation therefore reproduces the Python oracle rather than delegating these
details to platform-default C++ behavior:

- relative paths use `/` separators and are stably sorted by the Unicode 15.1 case-fold keys used
  by CPython 3.12;
- extension filters are trimmed with Python-compatible Unicode whitespace rules, receive a leading
  dot when needed, and use Python-compatible Unicode lowercase mapping for both the filter and the
  file suffix;
- include/exclude patterns use case-sensitive `fnmatchcase`-style matching over Unicode code
  points. `?` consumes one code point, `*` may cross `/`, and `**` is just repeated `*` rather than
  a separate recursive-glob operator. Backslashes in patterns are normalized to `/`;
- `--shuffle --seed <n>` applies the same integer seeding, bounded-integer draws, and shuffle order
  as `random.Random(n).shuffle(...)`, after the stable sort and before `--max-files` truncation.
  It does not use the superficially similar but incompatible `std::mt19937` contract;
- `--sample` controls how many already-selected records `discover` displays. It does not change the
  selection; use `--max-files` for that.

Case folding affects ordering, not glob matching. For example, a case-insensitive extension filter
does not make an include glob case-insensitive.

Source, notebook, and documentation-like corpus files are read as UTF-8 with malformed sequences
replaced at the same boundaries as Python's `bytes.decode("utf-8", errors="replace")`. This keeps a
damaged file in the corpus and makes its failure reproducible instead of turning corpus discovery
into a host decoding exception.

## PowerShell

Import the Tungsten module:

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
```

Discover:

```powershell
Get-TungstenParserCorpus -Sample 30
```

Compare:

```powershell
Compare-TungstenParserCorpus -MaxFiles 100 -MaxFileMB 2 -KernelBatchSize 100 -TungstenWorkers 8
```

## Output Artifacts

By default `parser-corpus compare` writes:

- `parser-corpus-summary.json`: run options, file counts, outcome counts, and failure-type counts.
- `parser-corpus-results.jsonl`: one JSON object per selected file, including Tungsten and Wolfram
  attempts.
- `parser-corpus-report.md`: compact human-readable report with first Tungsten gaps and suspicious
  Tungsten-only successes.

The default output directory is:

```text
C:\TestData\wolfram\tungsten-wolfram-parser-corpus\validation
```

Use `--out-dir` to write elsewhere, or `--no-write` for stdout-only summaries.

## Native Tests and Live Comparison

The native component test covers discovery, filtering, deterministic sampling, native source and
notebook parsing, batching, injected Wolfram results, missing-kernel behavior, summaries, and output
files without requiring an installed Wolfram runtime:

```powershell
Push-Location .\Engine
ctest --test-dir build/cpp -C Release --output-on-failure -R tungsten_parser_corpus_tests
Pop-Location
```

For a live held-parser comparison, run a bounded `tungsten-cpp parser-corpus compare` command
without `--skip-wolfram` on a machine with a usable Wolfram installation. That live path was not
validated as part of the Linux native-runtime pass. The Python integration test under
`tests.test_parser_corpus_integration` remains a reference-oracle check, not the native runtime
entrypoint.
