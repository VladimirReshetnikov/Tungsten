# Tungsten Parser Speed Experiments

- Created (UTC): 2026-04-25T18:54:39Z
- Updated (UTC): 2026-04-25T19:18:25Z
- Repository HEAD: 83607cff26e26661814ef7dcfb906fef4799b5b3
- Span-internals implementation baseline HEAD: e59d8c00d977185644fc59a814d9bea96bb78cac
- Corpus root: `C:\TestData\wolfram\tungsten-wolfram-parser-corpus`
- Scope: Tungsten notebook parsing and parser-corpus throughput

## Summary

The parser-corpus runner was still dominated by Tungsten notebook parsing after the earlier worker
parallelism work. Profiling found that saved notebook parsing spent most of its time in repeated
string scanner loops, especially `split_top_level`, `_find_matching`, and duplicate `parse_call`
passes over the same `Cell[...]` expressions.

This pass landed four low-risk improvements:

- Cached string lengths and replaced hot per-character `str.startswith("(*", index)` probes with
  direct two-character checks in notebook and Wolfram-string scanners.
- Replaced `parse_call`'s separate "find matching bracket, then split arguments" scans with one
  `_split_call_arguments` pass.
- Avoided reparsing each `Cell[...]` expression after `_parse_item` had already parsed it, and
  avoided parsing normal cell content just to check whether it is `CellGroupData[...]`.
- Added `NotebookDocument.summary()` and used it in parser-corpus notebook attempts instead of
  building the full preview-heavy `to_dict()` payload.
- Started larger eligible files first when using multiple Tungsten worker processes, reducing
  parallel-run stragglers without changing result ordering.

## Hot-Path Profile

Profile target:

```text
C:\TestData\wolfram\tungsten-wolfram-parser-corpus\github\rulebasedintegration-rubi\Rubi\IntegrationRules\1 Algebraic functions\1.1 Binomial products\1.1.1 Linear\1.1.1.4 (a+b x)^m (c+d x)^n (e+f x)^p (g+h x)^q.nb
```

The profile used `NotebookDocument.from_text(...)` on the same 1.3 MB notebook. `cProfile` times
are not normal wall-clock timings, but they are useful for relative hot-path shape.

| Metric | Before | After | Change |
|---|---:|---:|---:|
| Function calls | 79,895,470 | 874,564 | 91.4x fewer |
| Profile elapsed seconds | 17.103 | 2.274 | 7.5x faster |
| `parse_call` calls | 1,279 | 491 | 2.6x fewer |
| `split_top_level` calls | 1,200 | 65 | 18.5x fewer |
| `str.startswith` calls | 37,236,427 | 65 | effectively removed from the hot loop |
| `len(...)` calls | 40,109,634 | 433,636 | 92.5x fewer |

Remaining profiler hot spots after the change:

| Function | Calls | Cumulative profile seconds |
|---|---:|---:|
| `_split_call_arguments` | 491 | 1.515 |
| `split_top_level` | 65 | 0.747 |
| `skip_wl_string` | 425,436 | 0.167 |

The remaining cost is now mostly unavoidable text scanning plus substring materialization, not
accidental repeated `startswith`/`len` overhead.

## Notebook A/B Measurements

Method:

- Loaded the unmodified `HEAD` notebook parser under a temporary module name.
- Timed it against the working-tree parser in the same Python process.
- Warmed both implementations once, then alternated baseline/current order for 6 iterations.
- Verified that cell count, group count, and top-level option count matched.

| File | Size | Baseline median seconds | Current median seconds | Speedup |
|---|---:|---:|---:|---:|
| Rubi binomial products notebook | 1,304,508 bytes | 4.650 | 2.147 | 2.17x |
| Rubi three-factor notebook | 2,020,965 bytes | 5.729 | 2.635 | 2.17x |
| CSSTools tutorial notebook | 2,054,115 bytes | 6.827 | 2.968 | 2.30x |
| Notebook Archive historical notebook | 2,095,817 bytes | 4.358 | 1.431 | 3.04x |

All four A/B samples produced the same structural shape as the baseline.

## Parser-Corpus Throughput

All corpus runs used:

```powershell
python -m tungsten parser-corpus compare `
    --corpus-root C:\TestData\wolfram\tungsten-wolfram-parser-corpus `
    --max-file-mb 2 `
    --shuffle `
    --seed 20260425
```

Parser-only runs additionally used `--skip-wolfram --no-write`.

| Scenario | Previous measurement | Current measurement | Change |
|---|---:|---:|---:|
| 100 files, 1 Tungsten worker | 57.9 wall seconds | 37.4 wall seconds | 1.55x faster |
| 100 files, 8 Tungsten workers | 24.3 wall seconds | 9.9 wall seconds | 2.45x faster |
| 250 files, 8 Tungsten workers, Tungsten-only wall | 46.8 wall seconds | 16.0 wall seconds | 2.93x faster |

The 250-file Tungsten-only sample processed 250 files at 15.6 files/second wall rate. The sample
contained 127 notebooks and 123 source/test files, with 19 files skipped by the 2 MiB cap.

End-to-end comparison with the Wolfram held parser is now more clearly kernel-bound:

| Scenario | Previous run | Current run |
|---|---:|---:|
| 250 files, 8 Tungsten workers, batch-100 Wolfram comparison | 80.7 wall seconds | 68.4 wall seconds |
| Tungsten wall component | 46.8 wall seconds | 21.1 wall seconds |
| Wolfram wall component | 33.4 wall seconds | 45.7 wall seconds |
| Overall wall rate | 3.10 files/second | 3.66 files/second |

The current end-to-end run still improved despite a slower Wolfram component. This is a useful
warning: for full comparisons, Wolfram kernel launch/import variance can hide local parser wins.

At the measured 250-file end-to-end rate, the 7,033-file selected corpus projects to about 1,920
wall seconds for the default 2 MiB-capped comparison. At the parser-only 250-file rate, the local
Tungsten side projects to about 451 wall seconds. These are throughput extrapolations, not
guarantees, because the notebook size distribution is heavy-tailed.

## Landed Changes

The landed changes are intentionally conservative:

- `Engine/src/tungsten/notebook.py`
  - Faster scanner loops for strings/comments and top-level splitting.
  - Single-pass function-call argument splitting.
  - Fewer duplicate `Cell[...]` and content-expression parses.
  - Lightweight notebook summary for parser-corpus use.
- `Engine/src/tungsten/wolfram_strings.py`
  - Faster string/comment skipping loops shared by notebook and inline-box parsing.
- `Engine/src/tungsten/parser_corpus.py`
  - Notebook attempts use `NotebookDocument.summary()`.
  - Multi-process Tungsten parsing starts larger eligible files first.
- `Engine/tests/test_notebook.py`
  - Regression coverage for `parse_call` argument edge cases after the single-pass splitter.

Validation:

```powershell
$env:PYTHONPATH = (Resolve-Path Engine\src).Path
python -m unittest src.Tungsten.tests.test_notebook src.Tungsten.tests.test_parser_corpus
```

Result: 9 tests passed, 1 skipped.

## Measurement-Backed Proposals

1. Introduce span-based notebook internals. Implemented after the initial report.

   The optimized parser still spent much of its allocation budget materializing stripped substrings
   for arguments, cell raw text, cell content, group tails, and notebook options. The implemented
   representation now keeps `SourceSpan(source, start, end)` values through notebook construction
   and materializes strings only at public API boundaries such as `content_expr`, `options`,
   `to_dict()`, rendering, option decoding, and preview extraction.

   A/B wall-clock measurements against the previous optimized parser were intentionally treated as
   neutral: median parse time ranged from 0.93x to 1.01x of the previous implementation on the
   four measured 1-2 MiB notebooks. The actual win was memory behavior. `tracemalloc` peak
   allocations dropped from 11.6-22.0 MB to 0.32-0.54 MB on the same samples, a 24x-70x reduction,
   while cell/group/option counts stayed identical.

   Parser-corpus throughput is therefore expected to be roughly neutral for ordinary 2 MiB-capped
   runs, but the parser now has much more headroom for large-notebook stress runs and parallel
   workers.

2. Add a dedicated parser-corpus notebook acceptance mode.

   The parser-corpus comparison primarily needs "can Tungsten structurally accept this file?" plus
   counts and failure metadata. A one-pass `Notebook[...]`/`Cell[...]`/`CellGroupData[...]` scanner
   could validate the saved notebook envelope and selected cell boundaries without building editor
   objects. That should be optional, because the existing full notebook parser is still needed for
   patching and inspection workflows.

3. Record slowest Tungsten files in parser-corpus summaries.

   The speed work went much faster once the slow notebook names were visible. The runner should
   persist the slowest successful and failing Tungsten attempts in `parser-corpus-summary.json`, so
   every broad run automatically produces the next optimization target list.

4. Keep source-parser speed below source-parser coverage for now.

   Large `.wl` and `.m` files usually fail quickly today because unsupported syntax is encountered
   early. The corpus bottleneck is accepted notebooks, not rejected source files. For source files,
   grammar coverage will buy more useful signal than micro-optimizing failure paths.

5. Treat full Wolfram comparisons as a separate kernel-throughput problem.

   After the parser-side changes, the 250-file comparison spent more wall time in Wolfram than in
   Tungsten. Further end-to-end gains should investigate persistent kernel workers, larger or
   adaptive batch sizes, and better kernel-side result streaming separately from local parser work.
