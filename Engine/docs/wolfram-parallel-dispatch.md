# Parallel dispatch on Wolfram subkernels

- Created (UTC): 2026-05-26T16:30:00Z
- Repository HEAD: 6e80073d3a4d56f9aa6d4dc18b3119d72cdb7b87
- Audience: Vladimir; future Tungsten / Hypergeometric maintainers
- Status: Design notes + empirical findings. Read alongside
  `wolfram-license-parallelism.md`.

## What the license actually allows

The `:2,2,4,4:` field in `C:\ProgramData\Wolfram\Licensing\mathpass`
permits **two simultaneous main kernels** PLUS **four worker
subkernels per main kernel**. Empirically confirmed:

| Probe | Result |
|---|---|
| 5x `wolfram.exe -script` concurrent | 2 succeed; 3 fail with `Duplicate entry for license ID` |
| 1x `wolfram.exe -script`, then `LaunchKernels[6]` | Master + 4 `WolframKernel.exe` workers (one fewer than requested) |

So the realistic ceiling on this machine, current single-license
setup, is **1 master + 4 workers = 5 parallel evaluation contexts**
in one script invocation. If we also activated the second license
group (`L3458-6977`, see `wolfram-license-parallelism.md`), we'd
get **2 master + up to 8 worker = 10 parallel contexts** — two
copies of the same {master, 4-worker} group running independently.

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

4. **License-slot contention.** The `:2,2,4,4:` allows 4 workers
   PER MASTER. If we ever run two masters (Strategy A inside two
   Tungsten requests at once, or Strategy B with two persistent
   sessions), each master gets its own 4-worker pool. They don't
   share workers.

5. **`Quiet` doesn't propagate across workers.** Messages from
   subkernel evaluations come back through the `KernelStatus`
   stream. Wrap the per-task body in `Quiet[...]` at the worker
   side, not just at the master side, if you want to suppress
   reducer noise.

## Reference

- `src/Tungsten/docs/wolfram-license-parallelism.md` —
  empirical license-slot investigation.
- `C:\Users\vresh\AppData\Local\Temp\subkernel-probe.wl` —
  exploratory script that confirmed 4 workers spawn on this
  license; left in temp so it can be re-run.
