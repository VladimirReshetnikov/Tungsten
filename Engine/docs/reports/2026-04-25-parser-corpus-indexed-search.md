# Tungsten Parser Corpus Indexed Search Investigation

- Created (UTC): 2026-04-25T19:36:30Z
- Repository HEAD: 8d573b569cd63e77dea836599ba58819022d3074
- Corpus root: `C:\TestData\wolfram\tungsten-wolfram-parser-corpus`
- Indexed candidate: `src/Indexed`
- Scope: Fast indexed content search for Wolfram parser-corpus notebooks, packages, scripts, and tests

## Summary

`src/Indexed` is the best local fit for fast repeated search over the Tungsten Wolfram parser corpus.
It already provides a Windows .NET daemon, SQLite FTS5 trigram content index, literal search, regex
search, JSON output, recursive directory targets, path globs, and background freshness tracking. For
agent and tool workflows that issue multiple searches against the same corpus, this is materially
better than building another one-off Tungsten index.

There are three caveats before we should treat it as the complete corpus-search answer:

- Indexed currently skips files larger than 50 MiB, which excludes 23 large `.nb` files totaling
  2,319,252,147 bytes.
- Indexed has exclude-at-index-time support but no include-at-index-time support, so a root-level
  parser-corpus target indexes all non-binary text under the corpus rather than only Wolfram file
  extensions.
- Cold startup is awkward for large targets because the daemon becomes discoverable only after the
  first full scan, and a Rubi pilot exposed a first-query timeout even though the scan completed.

Recommendation: use Indexed as the primary repeated-search engine, keep `rg` as the one-off and
validation fallback, and extend Indexed in a few focused ways before relying on it for the entire
corpus. A Tungsten-side wrapper should enrich Indexed results with corpus metadata rather than
duplicating the search engine.

## Corpus Shape

The parser-relevant corpus consists of 7,033 files and 7,952,105,676 bytes across `.nb`, `.m`,
`.wl`, `.wls`, `.wlt`, and `.mt` files.

| Extension | Files | Bytes | Files over 50 MiB | Bytes over 50 MiB |
|---|---:|---:|---:|---:|
| `.nb` | 3,781 | 7,905,897,993 | 23 | 2,319,252,147 |
| `.m` | 2,000 | 16,465,620 | 0 | 0 |
| `.wl` | 876 | 27,373,074 | 0 | 0 |
| `.wls` | 169 | 284,640 | 0 | 0 |
| `.wlt` | 133 | 1,609,187 | 0 | 0 |
| `.mt` | 74 | 475,162 | 0 | 0 |
| Total | 7,033 | 7,952,105,676 | 23 | 2,319,252,147 |

Indexed's current 50 MiB file cap covers 7,010 of 7,033 files, or 99.7% by file count. The skipped
files are only 0.3% of the file count, but they are 29.2% of the bytes. They are all notebooks from
the Notebook Archive side of the corpus.

Sampled notebooks and packages are line-oriented enough for Indexed's result model. Several
multi-megabyte `.nb` files had maximum line lengths around 80 to 115 characters, and a large 89 MiB
notebook sample had a maximum line length of 111 characters. The line-oriented match output is
therefore acceptable for raw notebook syntax search.

## Indexed Fit

Indexed already matches most of the shape we need:

| Need | Indexed status |
|---|---|
| Recursive directory corpus target | Supported through `--root C:\TestData\wolfram\tungsten-wolfram-parser-corpus`. |
| Repeated fast literal search | Supported by the contentless FTS5 trigram code index. |
| Regex search | Supported by Indexed's regex path after candidate narrowing. |
| Extension/path filtering | Supported at query time with repeatable `--glob` and `--exclude`. |
| Machine-readable output | Supported through `--json`. |
| Long-lived service | Supported by per-target daemons under `%LOCALAPPDATA%\Indexed`. |
| Incremental refresh | Supported by target snapshots and rescan/status commands. |
| Raw `.nb` / `.wl` / `.m` search | Supported as code-mode text for non-binary files under the size cap. |
| Visible notebook prose search | Not currently supported for `.nb`; prose extractors do not handle Wolfram notebooks. |
| Complete huge-notebook coverage | Not currently supported because files over 50 MiB are classified as unindexable. |
| Index-time inclusion by extension | Not currently supported; only index-time exclusion globs exist. |

The existing Tungsten documentation index in `src/Tungsten/src/tungsten/docs_index.py` is not a good
replacement. It is purpose-built for local Wolfram documentation notebooks, visible-text snippets,
titles, paclet metadata, and documentation navigation. It does not provide a raw source-code trigram
index, regex search, directory-target daemon management, or general parser-corpus indexing. Reusing
Indexed avoids rebuilding those pieces in Python.

## Pilot Measurements

The pilot used a Release build of `src/Indexed` on two parser-corpus subtrees. The important pattern
is that Indexed's service-side query cost is very low after indexing, while the CLI process and
daemon-discovery overhead dominate short command-line invocations.

| Target | Parser-relevant size | Query | Indexed CLI wall | Indexed response | `rg` wall | Notes |
|---|---:|---|---:|---:|---:|---|
| `github\feyncalc-feyncalc` | about 6.7 MB | `Integrate` in `.m` files, first 50 matches | 0.265 s | 0.007 s | 0.071 s | Small tree; `rg` wins for one-off CLI use. |
| `github\rulebasedintegration-rubi` | about 308 MB | `CellGroupData` in `.nb` files, first 20 matches | 0.246 s | 0.022 s | 0.026 s | Common token plus early truncation favors `rg`. |
| `github\rulebasedintegration-rubi` | about 308 MB | no-hit literal in `.nb` files | 0.310 s | 0.002 s | 0.081 s | Indexed service is faster, CLI overhead hides it. |

Index storage from the same pilot:

| Target | Indexed files | Indexed bytes | `index.db` size | Ratio |
|---|---:|---:|---:|---:|
| Rubi | 623 | 308,111,396 | 460,906,496 | 1.50x |
| FeynCalc | about 1,400 | about 6.7 MB | 14,663,680 | about 2.2x |

For the full eligible corpus under the 50 MiB cap, the index should be expected to occupy multiple
gigabytes. A rough storage extrapolation from the Rubi target puts it near 8 GB for the 5.63 GB of
eligible parser-relevant bytes, before counting any extra non-Wolfram text indexed under the same
root.

The Rubi cold-start run also exposed an operational issue. A first query against the 308 MB Rubi
target timed out at the calling shell, while `idx status` afterward showed a completed scan with no
pending files. This makes the current cold-start path risky for full-corpus use unless callers
separate "start/index/wait" from "query" or Indexed changes daemon readiness behavior.

## Required Indexed Extensions

These are the extensions I would make before promoting Indexed as the official parser-corpus search
backend.

| Change | Why it matters | Likely shape |
|---|---|---|
| Add index-time include globs | Parser-corpus search should not index manifests, reports, generated logs, and other incidental text when the user's intent is Wolfram syntax search. | Add repeatable `--include-index <glob>` to daemon launch and target config, evaluated before exclude globs. |
| Improve cold-index lifecycle | Full-corpus initial scans are large enough that a first `find` should not be responsible for both daemon startup and a complete scan. | Write daemon metadata before the first full scan, expose `initialScanComplete`, and make `idx status --wait` or `idx rescan --wait` the explicit blocking operation. |
| Surface skipped files and reasons | The 50 MiB cap silently matters for this corpus because it skips nearly a third of parser-relevant bytes. | Persist skip records such as `too_large`, `binary`, `excluded`, and expose counts plus sample paths in `status` or a new `stats` command. |
| Support huge notebooks deliberately | Complete syntax search requires the 23 large `.nb` files; simply raising the cap may stress memory because current indexing reads whole files. | Add configurable size caps first, then a streaming/chunked path for very large text files if complete Notebook Archive search is required. |

## Useful Optional Extensions

These are lower priority for raw parser syntax search but valuable for interactive corpus work.

| Change | Why it helps |
|---|---|
| Add a Wolfram notebook prose extractor | Allows prose-mode search over visible notebook text, section headings, text cells, and comments separately from raw notebook syntax. |
| Add a Tungsten result-enrichment wrapper | Maps Indexed logical paths to corpus source, kind, extension, size, and parser status metadata using Tungsten's existing corpus discovery logic. |
| Add extension presets | A preset such as `--preset wolfram` could expand to `*.nb`, `*.wl`, `*.m`, `*.wls`, `*.mt`, `*.wlt`, and `*.nbp` globs. |
| Add direct HTTP helper documentation | For repeated agent queries, direct HTTP calls avoid most CLI overhead and expose the service-side millisecond response times seen in the pilot. |

## Alternatives

`rg` remains excellent for one-off searches. It has no index build cost, sees files over 50 MiB, and
was faster than the Indexed CLI in the small and medium pilots when match limits caused early exit.
It should remain the fallback oracle and the right answer for occasional searches.

Everything via `es.exe` is useful for filename and path discovery, but it does not solve content
search inside notebooks and packages.

Extending Tungsten's `docs_index.py` would be the wrong abstraction for raw parser-corpus search. It
would need a new raw-content model, query language, daemon story, regex path, freshness tracking, and
extension handling. At that point it would be recreating Indexed.

External engines such as Lucene, Zoekt, or Tantivy could work, but they add a larger dependency and
integration surface. Indexed is already in this repo, already Windows-local, already SQLite-backed,
and already close to the desired workflow.

## Proposed Path

Use Indexed now for repeated searches over bounded subtrees and for full-corpus searches where
skipping the 23 huge notebooks is acceptable. The practical command shape is:

```powershell
$idx = "C:\Tools3\Tools\src\Indexed\src\Indexed.Cli\bin\Release\net10.0-windows\idx.exe"
$root = "C:\TestData\wolfram\tungsten-wolfram-parser-corpus"

& $idx find "CellGroupData" `
    --root $root `
    --mode code `
    --glob "**/*.nb" `
    --max-matches 100 `
    --max-matches-per-file 5 `
    --json
```

For immediate full-corpus use, pre-warm the target with `idx status --root <corpus-root>` or a small
query before relying on interactive search. Use `rg` for searches that must include the 23 notebooks
over 50 MiB.

For a robust Tungsten-facing feature, implement the Indexed extensions above, then add a small
Tungsten command or script that:

- starts or discovers the Indexed target for `C:\TestData\wolfram\tungsten-wolfram-parser-corpus`;
- passes Wolfram extension globs by default;
- optionally queries Indexed over HTTP instead of spawning the CLI for each search;
- enriches results with Tungsten corpus metadata;
- warns when huge notebooks are excluded by the current Indexed cap.

This gives us fast repeated search without copying Indexed into Tungsten, and it keeps a clean path
to complete corpus coverage when huge-notebook indexing is made explicit rather than accidental.
