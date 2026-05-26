# Parallel dispatch on Wolfram subkernels

- Created (UTC): 2026-05-26T16:30:00Z
- Repository HEAD: 6e80073d3a4d56f9aa6d4dc18b3119d72cdb7b87
- Audience: Vladimir; future Tungsten / Hypergeometric maintainers
- Status: Design notes + empirical findings. Read alongside
  `wolfram-license-parallelism.md`.

## What the license actually allows

The `:2,2,4,4:` field in `C:\ProgramData\Wolfram\Licensing\mathpass`
permits **two simultaneous main kernels** plus **a machine-wide
pool of four worker subkernels** — *not* four workers per master.
Empirically confirmed:

| Probe | Result |
|---|---|
| 5x `wolfram.exe -script` concurrent | 2 succeed; 3 fail with `Duplicate entry for license ID` |
| 1x `wolfram.exe -script`, then `LaunchKernels[6]` | Master + 4 `WolframKernel.exe` workers |
| **2x `wolfram.exe -script` concurrent, each calling `LaunchKernels[6]`** | M1 gets **4 workers**; M2 gets **0 workers**. Observer at +5s / +10s / +18s sees exactly 4 `WolframKernel.exe` and 2 `wolfram.exe`. |

So the realistic ceiling on this machine, current single-license
setup, is **1 active master + 4 workers = 5 parallel evaluation
contexts** — even though the license technically permits two
concurrent main kernels, the second master cannot acquire any
workers when the first has already claimed the pool. Running two
masters in parallel is therefore only useful when each is doing
purely serial work; for `ParallelMap`-style workloads, one master
with four workers is strictly better than two masters fighting
over zero workers each.

If the second license group (`L3458-6977`, see
`wolfram-license-parallelism.md`) were also activated, each
license group would presumably get its own independent worker pool,
yielding **2 master + 4+4 = 10 parallel contexts**. That's
unverified speculation until we activate; the empirical evidence
here is only single-license.

## Three implementation strategies

### Strategy A — intra-script `ParallelMap` / `ParallelSubmit`

The simplest path. The Wolfram script Tungsten launches calls
`LaunchKernels[]` itself, distributes definitions to the workers,
and uses `ParallelMap` / `ParallelTable` / `ParallelSubmit` for
its inner loops. Tungsten's process model stays exactly the same:
spawn-per-request, `wolfram.exe -script`, scrape the result JSON.

**Best for**: Wolfram scripts that internally iterate over many
independent items (corpus runner, identity generator, batch fuzz).

**Worst for**: many small, independent requests from different
callers — each one pays the master-kernel boot cost.

Pattern (sketch for the identity generator):

```wolframlanguage
Module[{kernels, results},
  kernels = LaunchKernels[];   (* spawns up to 4 workers *)
  Quiet @ ParallelEvaluate[
    Get["C:/Tools1/src/Hypergeometric/HypergeometricDerivatives.wl"]
  ];
  results = ParallelMap[reduceOne @@ # &, enumeration];
  CloseKernels[]
]
```

### Strategy B — Python-side pool via `wolframclient`

A persistent master `WolframLanguageSession` lives in a Python
daemon. Each Tungsten request goes through a queue + dispatcher
that submits via `session.evaluate(wlexpr("ParallelSubmit[...]"))`,
keeps the EvaluationObject, and resolves the Python Future when
`WaitNext` returns.

**Best for**: many small independent requests across the lifetime
of the Tungsten session (chat-driven workloads, REPL).

**Worst for**: simplicity. Requires an external Python dependency
(`pip install wolframclient`), a persistent daemon process, health
monitoring, and recovery when the master crashes. Roughly an order
of magnitude more code than Strategy A.

### Strategy C — bespoke WSTP IPC

Same idea as Strategy B but using a raw subprocess pipe protocol
instead of `wolframclient`. Avoids the dependency but the protocol
hand-rolling is brittle (Wolfram's text-format output is ambiguous
in pathological cases, and the binary WSTP protocol is undocumented).

Not recommended unless `wolframclient` is unavailable for licensing
or platform reasons.

## Recommendation

Take Strategy A first. The two highest-value Tungsten consumers of
Wolfram parallelism right now are:

- `src/Hypergeometric/tests/corpus-runner.wl` (197 reducer calls)
- `src/Hypergeometric/GenerateIdentities.wl` (up to thousands of
  reducer calls)

Both are batch jobs that already iterate inside a single Wolfram
script. Parallelising the inner loop should give roughly **4x
speedup** on a 4-worker grid (with diminishing returns past 4
since the master itself isn't free).

Strategy B is worth doing once we have a Tungsten consumer that
makes many small Wolfram requests per session — likely the Chatbook
`ask` surface as it matures into something users iterate against
interactively. Until that load profile shows up, the cost/benefit
isn't there yet.

## Caveats and gotchas

1. **`WaitNext` return shape changes at queue length 1.** With 2+
   queued evaluations, `WaitNext[{...}]` returns `{result, rest}`.
   With exactly one, it returns just the `EvaluationObject`. A
   safe drain loop:

   ```wolframlanguage
   While[Length[pending] > 0,
     Module[{r},
       r = WaitNext[pending];
       If[Length[r] === 2,
         {result, pending} = r,
         {result, pending} = {r, {}}
       ];
       AppendTo[results, result]
     ]
   ]
   ```

2. **Workers need their own definitions.** `DistributeDefinitions[]`
   pushes specific symbols; `ParallelEvaluate[Get[...]]` reloads a
   package on every worker (heavier but works for packages whose
   definitions can't be enumerated upfront).

3. **`Block`-scoped state survives across `ParallelSubmit` calls
   only inside a worker, not across workers.** The Hypergeometric
   reducer's `$contiguousShiftDepth` counter is `Block`-scoped, so
   each worker has its own independent counter — no cross-worker
   interference, but also no shared budget.

4. **License-slot contention.** The `:2,2,4,4:` license slot does
   NOT give 4 workers per master — the four-worker pool is shared
   machine-wide across all running masters. Verified experimentally
   (see the "two-masters" probe results in the table above): when
   two `wolfram.exe -script` processes both call `LaunchKernels[6]`
   concurrently, the first claims all four workers and the second
   gets zero. Two-Tungsten-requests-at-once therefore makes things
   *worse* for ParallelMap-style work than one request alone, since
   the second master is idle-with-no-workers while the first runs
   at full parallel.

5. **`Quiet` doesn't propagate across workers.** Messages from
   subkernel evaluations come back through the `KernelStatus`
   stream. Wrap the per-task body in `Quiet[...]` at the worker
   side, not just at the master side, if you want to suppress
   reducer noise.

## A fourth strategy: MCP-driven persistent kernels

The Wolfram MCP servers shipped by the AgentTools paclet
(`Wolfram/AgentTools` from the paclet repository) implement what
Strategy B would have built: a persistent master kernel (paid Wolfram
or Wolfram Engine for Developers) addressable from any MCP client over
stdio. Once registered in `.claude.json` /
`claude_desktop_config.json`, Claude Code / Claude Desktop sees them as
deferred tools (`mcp__Wolfram__WolframLanguageEvaluator`,
`mcp__WolframEngine__WolframLanguageEvaluator`, plus several
companions). The persistent kernel stays warm across calls — the
single biggest cost for spawn-per-request Tungsten — and the MCP wire
protocol takes care of cancellation, timeouts, and result formatting.

For ad-hoc and interactive workloads this is the right tier; for batch
jobs Tungsten's spawn-per-request stays cleaner (isolated state per
run, JSON artifacts on disk, doesn't tie up the chat session). See
`src/Hypergeometric/docs/test-execution-paths.md` for the Hypergeometric-
specific decision matrix.

## Reference

- `src/Tungsten/docs/wolfram-license-parallelism.md` —
  empirical license-slot investigation.
- `src/Hypergeometric/docs/test-execution-paths.md` —
  worked example of choosing between Tungsten and MCP per workload.
- `C:\Users\vresh\AppData\Local\Temp\subkernel-probe.wl` —
  exploratory script that confirmed 4 workers spawn on this
  license; left in temp so it can be re-run.
