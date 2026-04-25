# Tungsten Parser Corpus

- Status: Operational test-infrastructure reference
- Audience: Tungsten maintainers and parser/evaluator contributors
- Scope: Local parser-corpus discovery, Tungsten parser runs, and Wolfram held-parser comparison
- Created (UTC): 2026-04-25T00:50:09Z
- Updated (UTC): 2026-04-25T02:12:28Z
- Repository HEAD: d5c80ad79cc968d21ae0e40731f2f0427674d6a0
- Related docs:
  - [Project README](../README.md)
  - [Usage Reference](./usage-reference.md)
  - [Expression Parser](./expression-parser.md)
  - [Troubleshooting](./troubleshooting.md)

## Purpose

The local parser corpus at `C:\TestData\tungsten-wolfram-parser-corpus` is a stress corpus for
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

Set the local source directory on `PYTHONPATH`:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
```

Discover the current corpus selection:

```powershell
python -m tungsten parser-corpus discover `
    --corpus-root C:\TestData\tungsten-wolfram-parser-corpus `
    --sample 30
```

Run a bounded comparison and write artifacts under
`C:\TestData\tungsten-wolfram-parser-corpus\validation`:

```powershell
python -m tungsten parser-corpus compare `
    --corpus-root C:\TestData\tungsten-wolfram-parser-corpus `
    --max-files 100 `
    --max-file-mb 2 `
    --kernel-batch-size 100 `
    --tungsten-workers 8
```

Run Tungsten only, without launching Wolfram:

```powershell
python -m tungsten parser-corpus compare `
    --corpus-root C:\TestData\tungsten-wolfram-parser-corpus `
    --skip-wolfram `
    --no-write `
    --include-results
```

Focus on a specific subtree or extension:

```powershell
python -m tungsten parser-corpus compare `
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
- `--tungsten-workers <n>` controls local worker processes for Tungsten-side parsing. Use `8` on
  this machine for broad notebook-heavy runs.

## PowerShell

Import the Tungsten module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
```

Discover:

```powershell
Get-TungstenParserCorpus -Sample 30
```

Compare:

```powershell
Compare-TungstenParserCorpus -MaxFiles 100 -MaxFileMB 2 -KernelBatchSize 100 -TungstenWorkers 8
```

The repository also includes a script wrapper:

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenParserCorpus.ps1 -MaxFiles 100
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
C:\TestData\tungsten-wolfram-parser-corpus\validation
```

Use `--out-dir` to write elsewhere, or `--no-write` for stdout-only summaries.

## Live Integration Test

The regular unit test suite does not launch Wolfram for parser corpus checks. To run the opt-in live
smoke against a known small corpus file:

```powershell
Push-Location .\src\Tungsten
try {
    $env:PYTHONPATH = (Resolve-Path .\src)
    $env:TUNGSTEN_PARSER_CORPUS_LIVE = "1"
    python -m unittest tests.test_parser_corpus_integration -v
}
finally {
    Remove-Item Env:\TUNGSTEN_PARSER_CORPUS_LIVE -ErrorAction SilentlyContinue
    Pop-Location
}
```
