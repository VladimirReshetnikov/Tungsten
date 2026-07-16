# Running multiple Wolfram kernels in parallel

- Created (UTC): 2026-05-26T15:45:00Z
- Updated (UTC): 2026-06-17T02:17:48Z
- Repository HEAD: 07930f5d6e6c04bf3c3f12f7b0a95debd2ab7b56
- Audience: Vladimir; future Tungsten maintainers
- Status: Current-state reference for paid Wolfram 15.0 as Tungsten's default runtime, with the
  earlier 14.3-era paid-product seat investigation preserved below. Wolfram Engine for Developers
  14.3 is installed separately and does not change the paid-product seat count.

## TL;DR

The active paid Wolfram 15.0 command-line kernel currently reports
`$MaxLicenseProcesses = 2` under default launch, system `-pwfile`, and user `-pwfile` modes. Tungsten
therefore treats **2 paid Wolfram controlling kernels** as the live operating point and caches the
observed value from successful evaluations.

The 2026-06-01 investigation below is retained because it explains how the license entries relate
to each other. At that time, the then-current paid product exposed 4 concurrent controlling kernels.
That four-kernel observation should be treated as historical until a fresh paid Wolfram 15.0
concurrency probe proves otherwise.

Vladimir's Wolfram account holds 4 activation keys
(`3458-6977-EUAT9H`, `3458-6977-QLUG23`, `9828-7240-KAY472`,
`9828-7240-8794RH`), which are **2 distinct licenses**, not 4:
- License `L9828-7240`: keys `KAY472`, `8794RH`
- License `L3458-6977`: keys `EUAT9H`, `QLUG23`

**As of 2026-06-17 Tungsten selects paid Wolfram 15.0 by default**:
`C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe`. The live paid 15.0 probe reports
2 controlling kernels. The earlier paid-product probe found **4 concurrent `wolfram.exe` kernels**
under the then-current paid installation; keep that result as background evidence, not as the
current cache target.

In the historical four-kernel configuration, going **beyond 4** would have
required an *additional* Wolfram license (a different `L`-prefix). The two unused
keys (`8794RH` in `L9828-7240`, `QLUG23` in `L3458-6977`) are siblings of the
two licenses already active and add nothing — they deduplicate against the same
license IDs.

## Historical paid-product setup — how the 4-kernel result worked (verified 2026-06-01)

The two licenses are recorded in **two different mathpass files**, and
the then-current `wolfram.exe` honoured both:

| license | key | mathpass file | seat field |
|---------|-----|---------------|-----------|
| `L9828-7240` | `9828-7240-KAY472` | `C:\ProgramData\Wolfram\Licensing\mathpass` (system) | `:2,2,4,4:` |
| `L3458-6977` | `3458-6977-EUAT9H` | `C:\Users\vresh\AppData\Roaming\Wolfram\Licensing\mathpass` (user) | `:2,2,8,8:` |

`EUAT9H` was activated interactively in the then-current paid Wolfram installation (it reports back via
`$ActivationKey` and the *About Wolfram* dialog). The activation wrote **only
the user mathpass** — the system mathpass was left unchanged, and **no manual
mathpass edit was needed**.

**Key empirical finding:** `-pwfile` does **not** *replace* the mathpass search —
the per-user mathpass is read **in addition** to any `-pwfile`. So Tungsten's
existing launch path (`-pwfile <copy of the system mathpass>`, which contains
only `KAY472`) already sees `EUAT9H` from the user mathpass and gets all 4
seats. **No Tungsten code change is required** — only the cached cap value.

A 6-way concurrency probe (`Temp/license-probe2.py`, 2-license version) confirms
4 under every launch mode:

```
A. DEFAULT launch (no -pwfile; merges user+system) : activated 4/6   {L3458-6977: 2, L9828-7240: 2}
B. SYSTEM mathpass only via -pwfile (current Tungsten): activated 4/6   {L9828-7240: 2, L3458-6977: 2}
C. MERGED user+system via -pwfile                    : activated 4/6   {L9828-7240: 2, L3458-6977: 2}
```

The 5th and 6th launches fail (rc 40 "No valid password found" under `-pwfile`,
rc 85 under default) — the expected ceiling once both licenses' 2-kernel seats
are taken.

Tungsten's cap cache (`%LOCALAPPDATA%\Tungsten\wolfram-license-cache.json`) has
been bumped from `2` to `4` to match.

> Note: a *third* activation key, `9919-6315-Q6KVQR`, may also appear in
> `$ActivationKey`; it belongs to the separately-installed **free Wolfram Engine
> for Developers 14.3**, not to paid Wolfram, and is irrelevant to the paid-product seat count.

## Evidence (the pre-activation investigation)

The analysis below is the single-license investigation (2026-05-26) that led to
activating `EUAT9H`. The mathpass snapshot in §1 **predates** that activation —
it shows only `KAY472` in the system mathpass, before `EUAT9H` was added to the
user mathpass. The mechanism it documents (MathID matching, the `:2,2,4,4:` seat
field, dedupe of same-key entries) still holds.

### 1. Pre-activation mathpass (system only)

`C:\ProgramData\Wolfram\Licensing\mathpass`:

```
%(*userregistered*)
evo  6206-12529-59587  9828-7240-KAY472  2751-636-401:2,2,4,4:800801   Vladimir Reshetnikov
evo  6206-12529-59587  9828-7240-KAY472  5358-894-407:2,2,4,4:800801   Vladimir Reshetnikov
evo  6206-12529-59587  9828-7240-KAY472  7899-456-756:2,2,4,4:800801   Vladimir Reshetnikov
evo  6206-12529-59587  9828-7240-KAY472  5615-248-039:2,2,4,4:800803:20241227 Vladimir Reshetnikov
```

Four lines but all using the **same activation key** with four
different MathIDs (machine fingerprints). Wolfram deduplicates these
to **one effective entry** at startup:

```
C:\ProgramData\Wolfram\Licensing\mathpass:3:  Duplicate entry for license ID ignored.
C:\ProgramData\Wolfram\Licensing\mathpass:4:  Duplicate entry for license ID ignored.
C:\ProgramData\Wolfram\Licensing\mathpass:5:  Duplicate entry for license ID ignored.
```

The `:2,2,4,4:` field is the per-key process limit. Empirically it
yields **2** concurrent `wolfram.exe`.

### 2. License variables inside a running kernel

```
$ActivationKey      9828-7240-KAY472
$ActivationGroupID  L9828-7240
$LicenseID          L9828-7240
$LicenseProcesses   1
$LicenseServer      evo
```

The `$LicenseID` matches the first two segments of the activation
key (`9828-7240`). The same `$LicenseID` covers **all keys with
the same prefix** — so `KAY472` and `8794RH` share license
`L9828-7240`, and `EUAT9H` / `QLUG23` share license `L3458-6977`.

`$LicenseProcesses = 1` looks contradictory to the empirical
2-kernel cap. The `2,2,4,4` field in `mathpass` is `{NumKernels,
NumKernels, NumProcesses, NumProcesses}`: 2 main kernels concurrent,
4 process slots overall counting subkernels. `$LicenseProcesses`
inside a running kernel reports the **per-kernel sub-process budget**
(1 sub-process per main kernel), not the concurrent main-kernel cap.

### 3. Empirical concurrency probe

`Temp/license-probe.py` launches 5 `wolfram.exe` processes with the
existing `-pwfile`:

```
#0 rc=0   activated=True
#1 rc=0   activated=True
#2 rc=40  activated=False  ... Duplicate entry for license ID ignored.
#3 rc=40  activated=False  ... Duplicate entry for license ID ignored.
#4 rc=40  activated=False  ... Duplicate entry for license ID ignored.

Total activated: 2
```

This matches `cached_max_license_processes = 2` cached at
`%LOCALAPPDATA%\Tungsten\wolfram-license-cache.json`.

### 4. Different Windows user does NOT bypass the cap

`Temp/runas-probe.ps1` launches 2 vresh kernels + 1 vovac kernel
via `Start-Process -Credential`:

```
vresh #0:  ToExpression::sntxi (script issue, but process started fine)
vresh #1:  ToExpression::sntxi (same)
vovac:     "Duplicate entry for license ID ignored." x6
           "No valid password found."
```

vovac can **read** the system `mathpass` but Wolfram's licensing
layer refuses to honour any entry inside it for the vovac process.

The mechanism is not the `%(*userregistered*)` header — that line is
a comment marker, not a per-user binding flag. The actual gate is
the **MathID**: each entry in `mathpass` records the MathID
(machine fingerprint) the key was activated against, and Wolfram
recomputes the MathID at every kernel startup and only honours
entries whose stored MathID matches what it recomputes.

The MathID derivation includes the Windows-user identity (or
per-user profile state) as one of its inputs, so vresh produces
MathID `2751-636-401` (and friends, from old activations) while
vovac running the same `wolfram.exe -pwfile <mathpass>` produces a
different MathID that none of the entries match. Result: vovac
sees its own MathID computed inside the kernel, compares it
against the mathpass entries, finds no match, and reports
`No valid password found`.

The observable consequence is the same: running `wolfram.exe` as a
different Windows user does not borrow vresh's activation. But the
fix is *also* MathID-based, not user-rename-based: a second
Windows user could hold an **independent** activation under their
own profile (vovac would generate vovac's MathID and then a fresh
activation against that MathID would be added to mathpass and
honoured for vovac). That still costs one key activation, so the
total concurrent-kernel ceiling on this machine is bounded by the
number of distinct licenses you own, not by the number of Windows
users you have.

## How the second license was activated (reference — executed 2026-06-01)

Activate one key from the `L3458-6977` license group on this
machine, for the current user (vresh). This is the procedure that was
run to activate `EUAT9H`; keep it for reference (e.g. re-activating after
a hardware change, or activating `QLUG23` instead).

For paid-product activation, prefer a product-local wrapper or the product FrontEnd rather than
the standalone `C:\Program Files\Wolfram Research\WolframScript\wolframscript.exe`. The standalone
wrapper currently launches paid Wolfram 15.0 for ordinary evaluation on this machine, but the
historical `-activate` path was product-sensitive and failed with:

```
An appropriate wolfram.exe location could not be determined. When
using the -activate option with WolframScript, wolfram.exe must be
located within a Wolfram Engine installation.
```

The fix is one of two product-correct entry points:

**(a)** the `wolframscript.exe` that ships *inside* the paid Wolfram
15.0 install, which knows it belongs to the paid product:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\wolframscript.exe" `
    -activate 3458-6977-EUAT9H
```

**(b)** the WolframNB.exe (notebook front end) interactive
activation dialog:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\15.0\WolframNB.exe"
```

The first time the front end is run with a key that has free
slots remaining, it pops the Wolfram Product Activation dialog
(Preferences -> Product Settings -> Activate Additional Product
in newer 14.x builds). Paste the key, complete the cloud sign-in,
and on success the new entry lands in
`C:\ProgramData\Wolfram\Licensing\mathpass`.

Either path is **one-way**: it burns one of the key's allowed
machine activations. The cloud sign-in step is interactive — this
cannot be fully scripted without prior `wolframscript -authenticate`.

On this machine the activation wrote a new entry to the **user** mathpass
(`C:\Users\vresh\AppData\Roaming\Wolfram\Licensing\mathpass`), tied to the new
key + a fresh MathID; the **system** mathpass was left unchanged. Because the
entry is a different license ID it does **not** trigger `Duplicate entry for
license ID`, and because the user mathpass is honoured alongside any `-pwfile`,
the concurrent-`wolfram.exe` cap rose to 4 with **no further mathpass edit**.

Verified with the 2-license probe:

```powershell
python C:\Users\vresh\AppData\Local\Temp\license-probe2.py
```

Result: `activated 4/6` under default, system-`-pwfile`, and merged-`-pwfile`
launches alike (2 seats per license). The Tungsten cap cache was then bumped to
match:

```powershell
'{ "max_license_processes": 4, "updated_utc": "2026-06-01T02:51:00Z" }' `
    | Set-Content "$env:LOCALAPPDATA\Tungsten\wolfram-license-cache.json"
```

## Historical path to >4 concurrent kernels

Both remaining keys (`8794RH` in `L9828-7240`, `QLUG23` in
`L3458-6977`) are **siblings** of keys we already considered, in
the same two license groups. Activating them does nothing useful:
they are deduplicated against the same license ID. In the historical 4-kernel
setup, going beyond that ceiling would have required an **additional** Wolfram
license (different `L`-prefix), then activating one of its keys here.

A `runas`-based approach (multiple Windows users, each with their
own activation) is possible but expensive: each user still needs a
distinct activation, so the upper bound is still set by the number
of independent licenses Vladimir owns.

## Historical Tungsten impact

The license-aware launch gate in Tungsten
(`wait_for_wolfram_license_slot` + `cached_max_license_processes`)
serializes launches against the discovered cap. In the 2026-06-01 paid-product
state, the only required change was **updating the cached cap value from `2` to
`4`** (`%LOCALAPPDATA%\Tungsten\wolfram-license-cache.json`). The launch gate,
the dedupe-mathpass helper, and the process-snapshot logic were unchanged.

The 2026-06-17 paid Wolfram 15.0 retest supersedes that cache target for normal
operation: successful Wolfram 15.0 evaluations report `$MaxLicenseProcesses = 2`,
and Tungsten refreshes its cache from that live kernel value. If a future
concurrency probe shows a higher Wolfram 15.0 ceiling, the cache can follow the
observed kernel value again.

A subtlety worth preserving from the 4-kernel investigation: Tungsten launched
with `-pwfile <copy of the system mathpass>`, which contained only `KAY472`, yet
the probe still acquired all 4 seats because the then-current `wolfram.exe` read
the per-user mathpass (holding `EUAT9H`) **in addition** to `-pwfile`. If a future
context ever launches where the user mathpass is *not* read, the merged-pwfile
approach — `Temp/license-probe2.py` condition C — is the drop-in fix.

## See also

- `Engine/src/tungsten/licensing.py` — mathpass inspection
  and dedupe.
- `Engine/src/tungsten/wolfram_processes.py` —
  `wait_for_wolfram_license_slot`, license-process cache.
- `C:\Users\vresh\AppData\Local\Temp\license-probe.py` — the
  single-license concurrency probe (pre-activation evidence §3).
- `C:\Users\vresh\AppData\Local\Temp\license-probe2.py` — the 2-license
  concurrency probe (default / system-`-pwfile` / merged-`-pwfile`) used to
  confirm the 4-kernel cap after activating `EUAT9H`.
- `C:\Users\vresh\AppData\Local\Temp\runas-probe.ps1` — the
  cross-user probe used to produce evidence (4).
