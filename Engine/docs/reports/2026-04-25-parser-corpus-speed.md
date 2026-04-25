# Tungsten Parser Corpus Speed Report

- Created (UTC): 2026-04-25T02:11:38Z
- Repository HEAD: d5c80ad79cc968d21ae0e40731f2f0427674d6a0
- Corpus root: `C:\TestData\tungsten-wolfram-parser-corpus`
- Runner: `python -m tungsten parser-corpus compare`

## Summary

The current corpus contains 7,033 parser-relevant files totaling about 7.95 GB. With Tungsten's
default 2 MiB file cap, 6,480 files are eligible and 553 very large files are skipped. The skipped
files account for about 6.70 GB, so the cap is not cosmetic; it is the difference between a
practical parser regression pass and a giant-notebook stress pass.

Two bottlenecks dominate:

- Wolfram kernel startup cost when `--kernel-batch-size` is small.
- Tungsten's structural notebook parser on medium-to-large `.nb` files.

The low-risk optimizations implemented in this pass are:

- Raised the Wolfram kernel batch default from `25` to `100`.
- Added `--tungsten-workers <n>` / `-TungstenWorkers <n>` for process-parallel Tungsten parsing.
- Added timing fields to `parser-corpus-summary.json` and the generated Markdown report.

Recommended broad-run command on this machine:

```powershell
python -m tungsten parser-corpus compare `
    --corpus-root C:\TestData\tungsten-wolfram-parser-corpus `
    --max-file-mb 2 `
    --kernel-batch-size 100 `
    --tungsten-workers 8 `
    --shuffle `
    --seed 20260425
```

Estimated broad-run wall time for the default 2 MiB-capped corpus comparison with that command is
about 38 minutes, based on the 250-file representative run below.

## Corpus Shape

Discovery in-process took about 0.52 seconds. The CLI `discover` command took about 1.92 seconds,
including Python startup and JSON printing.

| File cap | Eligible files | Skipped files | Eligible bytes | Skipped bytes |
|---:|---:|---:|---:|---:|
| none | 7,033 | 0 | 7,952,105,676 | 0 |
| 64 KiB | 4,075 | 2,958 | 47,110,183 | 7,904,995,493 |
| 256 KiB | 5,145 | 1,888 | 205,381,174 | 7,746,724,502 |
| 1 MiB | 6,122 | 911 | 729,625,075 | 7,222,480,601 |
| 2 MiB | 6,480 | 553 | 1,256,759,297 | 6,695,346,379 |
| 8 MiB | 6,861 | 172 | 2,745,290,722 | 5,206,814,954 |

Full corpus by extension:

| Extension | Files |
|---|---:|
| `.nb` | 3,781 |
| `.m` | 2,000 |
| `.wl` | 876 |
| `.wls` | 169 |
| `.wlt` | 133 |
| `.mt` | 74 |

## Measurements

All benchmark samples used `--shuffle --seed 20260425` unless noted.

### Tungsten-Only

Before adding worker parallelism, a full Tungsten-only run with the 2 MiB cap did not complete
inside a 600-second guard. The representative 100-file sample explains why:

| Scenario | Wall seconds | Files/sec | Tungsten statuses |
|---|---:|---:|---|
| 100 files, 2 MiB cap, 1 worker | 57.9 | 1.77 | 55 success, 40 failure, 5 skipped |
| 100 files, 2 MiB cap, 4 workers | 31.0 | 3.37 | 55 success, 40 failure, 5 skipped |
| 100 files, 2 MiB cap, 8 workers | 24.3 | 4.35 | 55 success, 40 failure, 5 skipped |
| 100 files, 256 KiB cap, 1 worker | 10.3 | 9.75 | 33 success, 40 failure, 27 skipped |
| 100 files, 64 KiB cap, 1 worker | 3.5 | 28.6 | 21 success, 39 failure, 40 skipped |

The slowest Tungsten-side files in the 100-file / 2 MiB sample were all notebooks. The largest
single observed local parse was:

```text
8.1 s  github/rulebasedintegration-rubi/Rubi/IntegrationRules/1 Algebraic functions/1.1 Binomial products/1.1.1 Linear/1.1.1.4 (a+b x)^m (c+d x)^n (e+f x)^p (g+h x)^q.nb
```

For that file, `NotebookDocument.from_text(...)` took about 4.22 seconds on a warm isolated probe,
while `to_dict()` took only about 0.07 seconds. The parser itself is the bottleneck, not report
rendering or preview extraction.

### Wolfram Kernel Batch Size

The kernel-side bottleneck is launch overhead. With a 64 KiB cap, Tungsten work is small enough to
make the kernel batching effect obvious:

| Scenario | Wall seconds | Files/sec | Wolfram statuses |
|---|---:|---:|---|
| 100 files, 64 KiB cap, batch 5 | 86.8 | 1.15 | 58 success, 2 failure, 40 skipped |
| 100 files, 64 KiB cap, batch 25 | 19.1 | 5.23 | 58 success, 2 failure, 40 skipped |
| 100 files, 64 KiB cap, batch 100 | 8.3 | 12.1 | 58 success, 2 failure, 40 skipped |

At the 2 MiB cap, larger Wolfram batches still help but notebook parsing becomes the larger local
cost:

| Scenario | Wall seconds | Outcomes |
|---|---:|---|
| 100 files, 2 MiB cap, batch 25, 1 worker | 103.2 | 55 both-success, 38 Tungsten gaps, 2 both-fail, 5 skipped |
| 100 files, 2 MiB cap, batch 100, 1 worker | 83.5 | same outcomes |
| 100 files, 2 MiB cap, batch 100, 8 workers | 44.5 | same outcomes |

### Representative Optimized Run

The best estimate point was a 250-file run:

```powershell
python -m tungsten parser-corpus compare `
    --corpus-root C:\TestData\tungsten-wolfram-parser-corpus `
    --max-files 250 `
    --max-file-mb 2 `
    --shuffle `
    --seed 20260425 `
    --kernel-batch-size 100 `
    --tungsten-workers 8 `
    --no-write
```

Observed summary:

| Metric | Value |
|---|---:|
| Total wall time | 80.7 s |
| Files | 250 |
| Overall rate | 3.10 files/s |
| Tungsten wall time | 46.8 s |
| Wolfram wall time | 33.4 s |
| Tungsten wall rate | 5.35 files/s |
| Wolfram wall rate | 6.92 eligible files/s |
| Outcomes | 129 both-success, 98 Tungsten gaps, 4 both-fail, 19 skipped |

The sample extension mix was close enough to be useful: 127 notebooks, 82 `.m` files, 28 `.wl`
files, 7 `.wls` files, 4 `.wlt` files, and 2 `.mt` files.

## Full-Corpus Estimate

For the 2 MiB-capped broad run, extrapolating the 250-file optimized sample to all 7,033 selected
files gives:

```text
7,033 files / 3.10 files per second = about 2,270 seconds = about 38 minutes
```

Component estimate:

- Tungsten local parsing: about 22 minutes.
- Wolfram held parsing: about 16 minutes.
- Discovery and artifact writing: under 1 minute for normal JSONL/report output sizes.

The estimate is only rough because notebook sizes are heavy-tailed. A randomly unlucky shard with
many Rubi or Notebook Archive files near the 2 MiB cap will run slower; a package-heavy shard will
run faster.

For smaller caps:

- 256 KiB cap: rough full-corpus estimate is about 14 minutes from the 100-file batch-100 sample.
- 64 KiB cap: rough full-corpus estimate is about 10 minutes from the 100-file batch-100 sample.

For `--no-max-bytes`, I do not recommend extrapolating from these samples. The skipped files above
2 MiB contain about 6.70 GB of notebook/package text, and the largest notebook parse costs are not
linear enough to trust a simple files/sec projection. Treat unlimited runs as a separate stress mode
with a much higher memory and runtime risk.

## Bottlenecks And Next Optimizations

The implemented optimizations are enough to make broad 2 MiB-capped runs practical, but the next
real wins are parser-level:

- Add a lightweight notebook acceptance mode that validates top-level `Notebook[...]`, balanced
  cell/group structure, and selected cell expressions without eagerly building every nested cell
  object. This would preserve parser-corpus signal while avoiding the slowest full structural
  notebook parse paths.
- Add per-file timeout / quarantine support so pathological notebooks are recorded as
  `TungstenTimeout` instead of dominating a broad run.
- Add sharded output support such as `--shard-index` / `--shard-count` for easy parallel corpus
  sweeps across multiple shells or machines.
- Consider a persistent Wolfram parser worker for full runs. The current batch-100 model already
  removes most launch overhead, so this is lower priority than notebook-parser work.

## Current Validation Artifact

The default validation artifact was refreshed with timing data:

```text
C:\TestData\tungsten-wolfram-parser-corpus\validation\parser-corpus-summary.json
C:\TestData\tungsten-wolfram-parser-corpus\validation\parser-corpus-results.jsonl
C:\TestData\tungsten-wolfram-parser-corpus\validation\parser-corpus-report.md
```
