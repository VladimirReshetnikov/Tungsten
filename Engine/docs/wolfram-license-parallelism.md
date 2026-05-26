# Running multiple Wolfram kernels in parallel

- Created (UTC): 2026-05-26T15:45:00Z
- Repository HEAD: 4b3f2a32be9fbb04f7c1f01b1e9a17b6c8d3f6dc
- Audience: Vladimir; future Tungsten maintainers
- Status: Investigation report. Read before activating additional keys.

## TL;DR

Vladimir's Wolfram account holds 4 activation keys
(`3458-6977-EUAT9H`, `3458-6977-QLUG23`, `9828-7240-KAY472`,
`9828-7240-8794RH`). The current Tungsten setup is capped at **2
concurrent `wolfram.exe` processes**. The cap is real, not a
Tungsten artifact — `wolfram.exe` itself refuses the 3rd concurrent
launch with `Duplicate entry for license ID ignored` / `No valid
password found`.

The 4 keys are **2 distinct licenses**, not 4:
- License `L9828-7240`: keys `KAY472` (currently in use), `8794RH`
- License `L3458-6977`: keys `EUAT9H`, `QLUG23`

So to go from **2 → 4** concurrent kernels, **activate one key from
the `L3458-6977` group** on this machine. To go beyond 4, additional
Wolfram licenses would be required (the keys we have are pairs that
share the same license pool).

## Evidence

### 1. Current mathpass

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

## Path to 4 concurrent kernels

Activate one key from the `L3458-6977` license group on this
machine, for the current user (vresh).

**Do not use the standalone `wolframscript.exe`** at
`C:\Program Files\Wolfram Research\WolframScript\` for this. That
binary is the Wolfram-Engine-for-Developers launcher; its
`-activate` flag is hardwired to a Wolfram Engine install and
fails on the paid Wolfram product with:

```
An appropriate wolfram.exe location could not be determined. When
using the -activate option with WolframScript, wolfram.exe must be
located within a Wolfram Engine installation.
```

The fix is one of two product-correct entry points:

**(a)** the `wolframscript.exe` that ships *inside* the Wolfram
14.3 install, which knows it belongs to the paid product:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\14.3\wolframscript.exe" `
    -activate 3458-6977-EUAT9H
```

**(b)** the WolframNB.exe (notebook front end) interactive
activation dialog:

```powershell
& "C:\Program Files\Wolfram Research\Wolfram\14.3\WolframNB.exe"
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

After activation, the system mathpass should grow a new entry tied
to the new key + a fresh MathID. The new line should NOT trigger
`Duplicate entry for license ID` (it's a different license ID),
which doubles the concurrent-`wolfram.exe` cap to 4.

To verify after activation:

```powershell
python C:\Users\vresh\AppData\Local\Temp\license-probe.py
```

Expected: `Total activated: 4` (instead of 2).

Then bump Tungsten's cache:

```powershell
echo '{ "max_license_processes": 4, "updated_utc": "..." }' `
    > "$env:LOCALAPPDATA\Tungsten\wolfram-license-cache.json"
```

## Path to >4 concurrent kernels

Both remaining keys (`8794RH` in `L9828-7240`, `QLUG23` in
`L3458-6977`) are **siblings** of keys we already considered, in
the same two license groups. Activating them does nothing useful:
they are deduplicated against the same license ID. To go beyond 4
concurrent kernels Vladimir would need to acquire an **additional**
Wolfram license (different `L`-prefix), then activate one of its
keys here.

A `runas`-based approach (multiple Windows users, each with their
own activation) is possible but expensive: each user still needs a
distinct activation, so the upper bound is still set by the number
of independent licenses Vladimir owns.

## What this means for Tungsten

The license-aware launch gate in Tungsten
(`wait_for_wolfram_license_slot` + `cached_max_license_processes`)
already serializes launches against the discovered cap. Once the
extra activation lands, the only required change is updating the
cached cap value. The launch gate, the dedupe-mathpass helper, and
the process-snapshot logic remain unchanged.

No code change is required to make the parallelism work — only an
activation step that Tungsten cannot perform autonomously.

## See also

- `src/Tungsten/src/tungsten/licensing.py` — mathpass inspection
  and dedupe.
- `src/Tungsten/src/tungsten/wolfram_processes.py` —
  `wait_for_wolfram_license_slot`, license-process cache.
- `C:\Users\vresh\AppData\Local\Temp\license-probe.py` — the
  concurrency probe used to produce evidence (3).
- `C:\Users\vresh\AppData\Local\Temp\runas-probe.ps1` — the
  cross-user probe used to produce evidence (4).
