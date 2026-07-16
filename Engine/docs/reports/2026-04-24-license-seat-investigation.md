# Tungsten Wolfram License Seat Investigation

- Status: Report (live-machine investigation plus mitigation implementation)
- Audience: Vladimir Reshetnikov, Tungsten maintainers, future debugging sessions
- Scope: `Engine` kernel-launch reliability on the local Wolfram 14.3 Windows installation
- Created (UTC): 2026-04-24T18:16:08Z
- Repository HEAD: dcad077d1f5fabcc31bef9998e628c916bcadfc2
- Validation context: Performed against the real local installation at `C:\Program Files\Wolfram Research\Wolfram\14.3`

## Executive summary

The intermittent Tungsten failures that surfaced as:

- `exit_code = 40`
- `evaluation_available = false`
- stderr/stdout containing `No valid password found.`

were not primarily caused by the deduplicated `mathpass` workaround itself. The dominant issue was
license-seat contention.

On this machine, a successful kernel evaluation reports:

- `$MaxLicenseProcesses = 2`
- `$LicenseProcesses = 2`
- `$MaxLicenseSubprocesses = 4`

That means there are only two controlling-process seats. A single orphaned or long-lived headless
`wolfram.exe` can consume one seat. Parallel Tungsten launches can easily consume the second seat
and make every additional launch fail with the same licensing symptom.

The mitigation implemented in Tungsten is therefore:

1. machine-wide serialization of Tungsten kernel launches;
2. prelaunch Wolfram-process scanning;
3. cached knowledge of the observed controlling-process ceiling;
4. bounded waiting for a free seat before launch;
5. cleanup of clearly orphaned Tungsten-owned headless kernels from previous crashed runs;
6. richer kernel result payloads that expose the observed Wolfram-process state.

## Local findings

### 1. The machine really is license-limited to two controlling processes

A successful live evaluation returned:

- `$MaxLicenseProcesses -> 2`
- `$LicenseProcesses -> 2`

This matches Wolfram's documented "2 controlling processes" model for common single-user licenses.

### 2. There was a real lingering headless `wolfram.exe`

During investigation, one long-lived process was present:

- executable: `C:\Program Files\Wolfram Research\Wolfram\14.3\wolfram.exe`
- mode: headless `-pwfile ... -noprompt -run ...`
- parent process: missing
- age: long enough to clearly be abandoned rather than a fresh launch

That is exactly the kind of ghost/orphaned process that can hold a seat indefinitely.

### 3. The failure is easy to reproduce with concurrent launches

Before the mitigation, a 12-way parallel repro produced:

- 1 success
- 11 failures with `No valid password found.`

That is exactly what we expect when:

- one orphaned headless process is already holding one controlling seat; and
- the remaining seat is contested by multiple concurrent Tungsten launches.

### 4. The failure is not deterministic under serial use

Back-to-back serial `evaluate_text("2+2")` calls can succeed repeatedly. That explains why the
bug felt intermittent: it only surfaces when seat pressure rises because of:

- lingering headless processes;
- concurrently active Tungsten launches;
- other visible or hidden Wolfram sessions on the machine.

## External references and what they imply

### Wolfram Support: controlling vs computing processes

Wolfram states that:

- a controlling process is a kernel or front end that handles input/output/scheduling;
- `$MaxLicenseProcesses` reports the maximum number of controlling processes;
- two simultaneous standalone sessions consume both controlling processes of a standard license.

Source:

- [What are controlling and computing processes?](https://support.wolfram.com/36293)

This directly validates Tungsten's need to respect a controlling-process ceiling rather than only
thinking about raw subkernel parallelism.

### Wolfram Support: ghost processes are a real expected failure mode

Wolfram explicitly says that unexpected license-limit failures can be caused by ghost Wolfram
processes running in the background, and recommends inspecting Task Manager / Activity Monitor and
ending those processes.

Source:

- [How do I handle “License Limit Reached” errors?](https://support.wolfram.com/36360?src=mathematica)

This strongly supports Tungsten adding process inspection and cleanup logic instead of treating the
license error as opaque.

### Wolfram Community: not every visible kernel-like process counts the same way

In a Wolfram Community thread, a Wolfram employee explains that the GUI may start two kernels on
startup, one being the default evaluator and one being a helper kernel that does not count against
the process limit in the same way.

Source:

- [Trying to understand WolframKernel processes licensing](https://community.wolfram.com/groups/-/m/t/3326555)

This matters for Tungsten because a naive "count every Wolfram-related process" strategy would be
too conservative. The implementation therefore distinguishes likely controlling-process candidates
from obvious helper/subkernel-style processes.

### Mathematica Stack Exchange: users do run into seat contention across tool surfaces

Mathematica Stack Exchange discussions around Workbench and concurrent tool usage show the same
practical symptom: starting an additional Wolfram-facing tool surface can trigger activation /
license-limit behavior once the controlling-process ceiling is reached.

Source:

- [Is Starting wolfram-workbench when Mathematica already running not allowed?](https://mathematica.stackexchange.com/questions/274227/is-starting-wolfram-workbench-when-mathematica-already-running-not-allowed)

This reinforces that Tungsten should expect seat contention from unrelated Wolfram tooling, not
just from other Tungsten invocations.

## Implemented changes

### New runtime-management layer

Added `src/tungsten/wolfram_processes.py` with:

- `list_wolfram_processes()`
- `snapshot_wolfram_processes()`
- `cleanup_stale_tungsten_processes()`
- `tungsten_wolfram_launch_gate()`
- `wait_for_wolfram_license_slot()`
- cached `$MaxLicenseProcesses` persistence

### Launcher behavior changes

`kernel.py` now:

- serializes Tungsten launches through a machine-wide file lock;
- scans for existing Wolfram-related processes before launch;
- cleans up clearly orphaned Tungsten-owned headless kernels from prior crashed runs;
- waits for an available controlling-process seat when the cached limit is known;
- caches `max_license_processes` after successful live evaluations;
- returns richer JSON diagnostics, including the observed process snapshot.

### Result-payload changes

Kernel result payloads now expose:

- `license_processes`
- `max_license_processes`
- `launch_gate_wait_seconds`
- `license_wait_seconds`
- `license_wait_satisfied`
- `cached_max_license_processes`
- `cleaned_tungsten_processes`
- `observed_wolfram_processes`

That turns future license incidents from "mysterious `exit_code 40`" into something diagnosable.

## Design boundaries

- Tungsten now automatically cleans up only **Tungsten-owned** orphaned headless kernels by
  default. It does **not** automatically kill arbitrary foreign Wolfram processes.
- The process-count heuristic is intentionally conservative but not completely naive: it tries to
  approximate controlling-process consumers rather than counting every helper/subkernel process.
- The machine-wide launch gate now has a long wait budget because this repository explicitly
  tolerates waiting for higher-confidence results more than it tolerates flaky failures.

## Validation

After implementing the mitigation:

- targeted runtime-management unit tests passed;
- the kernel integration tests passed;
- the full Tungsten Python suite passed (`120` tests, `1` skipped);
- `Test-TungstenSmoke.ps1` passed end to end;
- a 12-way concurrent repro that previously collapsed into license failures now completed
  successfully because launches were serialized.

## Recommended next steps

- Keep the richer process snapshot in the kernel result payload; it is high-value debugging data.
- If license contention becomes a recurring operational issue, consider exposing the process scan
  and cleanup helpers as first-class CLI / PowerShell commands.
- If we later observe false positives from the controlling-process heuristic, capture concrete
  command lines from those sessions and refine the classifier rather than dropping the whole seat
  management approach.
