# `src/InverseAsymptotic` vs `src/InverseAsymptotic-2` — head-to-head comparison

- Created (UTC): 2026-06-26T05:36:34Z
- Updated (UTC): 2026-06-28T18:49:23Z (IA-2 removed; postscript added)
- Repository HEAD: a84f89feb34f7ca500d7657762afa3a17ba8dbad

Two independent Wolfram Language packages solve the same problem — the asymptotic
expansion of the **real-valued branch** of an inverse function, the task posed in
[Mathematica StackExchange #236367](https://mathematica.stackexchange.com/questions/236367):

- [`src/InverseAsymptotic`](../InverseAsymptotic.wl) — written by Claude (Opus 4.8). Below: **IA-1**.
- `src/InverseAsymptotic-2` (since removed — see the postscript) — written by GPT-5.5. Below: **IA-2**.

> **Update — this comparison has been acted on.** Following the recommendation below,
> `src/InverseAsymptotic` (IA-1) has since been **merged to the "best of both"**: it now
> carries IA-2's idiomatic interface (`{x, x0}` / `{y, y0}` specs, `SeriesTermGoal`,
> pure-`Function` / `ConditionalExpression` inputs) on top of IA-1's correctness discipline,
> plus a **gated** `InverseFunction` fallback (returned only if numerically certified real,
> solving `f(x(y))=y`, and passing through `x0`). The merged package passes all of IA-2's
> own test cases *and* the real-branch cases IA-2 fails (see
> [`tests/merged-api.wl`](../tests/merged-api.wl)). The analysis below describes the two
> packages **as originally written** (IA-1 at commit `aa9cbd524`); `src/InverseAsymptotic-2`
> was subsequently **removed** (2026-06-28) after an empirical re-verification confirmed this
> package fully subsumes it — see the postscript at the end of this report.

This report compares their approaches, cross-ports and cross-runs their test
suites, and records which implementation passes the other's tests. Every claim
below was checked against the running Wolfram 15.0 kernel. Because both packages
use the **same context** `` InverseAsymptotic` ``, the cross-run was performed by
loading IA-2 into a renamed context (`` IA2` ``) so both could be called
side-by-side; the committed cross-test files instead load one package per fresh
kernel.

## Executive summary

Both implementations **agree exactly** on the entire shared core — the two
flagship cases and every analytic / Puiseux / power-log / irrational-exponent
case that both can express (`x + x^2(1+Log x)`, `x + x^Sqrt[2]`, `x + x^2`,
`2x + x^2`, `x^2 + x^3`, `x - x^2`, `Log[x]` at `x→1`, and even `x + Log x` and
`x + Sqrt[x]` at `x→∞`). Their *core* designs are strikingly convergent: the
identical monomial representation `c·s^p·Log[s]^k`, the same asymptotic ordering,
the same "keep the first *n* distinct powers" truncation, and the same
binomial/log series machinery.

They diverge on three axes that matter for a *real-branch* tool:

| axis | IA-1 (Claude) | IA-2 (GPT-5.5) |
|---|---|---|
| **branch fidelity** | always the real branch through the requested `x0` | a `SystemInverseFallback` inherits `InverseFunction`'s branch and can return the **wrong** or even a **complex** branch |
| **out-of-scale inputs** | clean refusal (`$Failed` + message) | silently falls back to a possibly-unrelated branch |
| **API & input forms** | positional `f, x, y, n` + `"At"`; bare expression only | idiomatic `{x,x0},{y,y0}` + `SeriesTermGoal`; also accepts pure functions and `ConditionalExpression` |

**Net:** IA-1 passes **all** of IA-2's tests (mathematically); IA-2 passes IA-1's
*power-log/Puiseux/infinity* cases but **fails IA-1's real-branch-correctness and
refusal cases** — it returns the `x=π` branch for `Sin`, a **complex** branch for
`Sinh`, the wrong sign for the `x^2` lower branch, and answers (rather than
declines) the deliberately out-of-scale `x·Log x` and `Sin[1/x]`. IA-2 has the
better *ergonomics*; IA-1 has the better *correctness discipline*. The ideal
package is a merge (see [Recommendations](#recommendations)).

## Approaches

### Shared core (independently arrived at)

Both represent a generalized power-log series as a list of monomials
`{power, logPower, coefficient}` standing for `c·s^p·Log[s]^k` in the output
displacement `s = y − y0`, ordered as `s → 0+` (smaller power dominates; at equal
power, larger `Log` power dominates). Both implement add / multiply / divide-by-
leading-monomial / non-integer `Power` (generalized binomial in the relative
tail) / `Log` (log of `lead·(1+small)`), and both truncate by **keeping the first
*n* distinct powers** (never splitting an equal-power log group). This is the
machinery that lets either package carry `z^Sqrt[2]` and `Log[z]` terms that
`Series`/`Asymptotic` cannot.

### Where they differ architecturally

| | IA-1 (Claude) | IA-2 (GPT-5.5) |
|---|---|---|
| iteration | **linear fixed point** `X ← ((y − f(X) + c X^p)/c)^(1/p)` | **Newton** `X ← X − (f(X)−y)/f'(X)` (quadratic; fewer iterations) |
| expansion of `f∘X` | fully self-contained custom engine; native `Exp`/`Sin`/`Cos`/`Tan`/… via Taylor (`tsAnalytic`) | **hybrid**: delegates to Wolfram `Asymptotic` first, then finishes with its own arithmetic what the kernel leaves unevaluated |
| analytic heads (`Sin`, `Exp`, …) | expanded **natively**, seeded at `x0` → correct branch | core `expandExpression` handles only `Plus/Times/Power/Log`; analytic heads fall through to the **system-inverse fallback** |
| out-of-scale input | refuse: `::leadlog` (leading `Log`), `::nolead` (no monomial), `::singular` (analytic at a singularity), `::badside` | `FallbackToSystemInverse → True`: returns `Asymptotic[InverseFunction[f][y], …]` |
| point / direction | explicit normalization for finite `a`, `±∞`, both `Direction`s; even leading order ⇒ `"RealBranches"→2` + `::branches`, and the sign branch is selected by `Direction` | `{x,x0}` (incl. `∞` via the fallback); `Direction` enters only as an *assumption*, **not** as branch selection — the even-power seed is always `+` |
| verification | **rate-based numeric** back-substitution (residual must decay at the remainder order across shrinking samples) | **symbolic** `InverseAsymptoticVerify`: leading residual term must be of higher order than the last retained term |
| post-processing | `Collect` into power-grouped form; inert `BigO` remainder | `FullSimplify` (default) on the final expression |
| API | `InverseAsymptotic[f, x, y, n]`, `[f, x→a, y, n]`; options `"At"`, `Direction`, `"ImagePoint"`, `"Remainder"`, `"Verify"` | `InverseAsymptotic[f, {x,x0}, {y,y0}]`; options `SeriesTermGoal`, `Direction`, `Assumptions`, `"FallbackToSystemInverse"`, `"PostSimplify"`; plus `InverseAsymptoticTerms`/`InverseAsymptoticVerify` |
| input forms | bare expression `f(x)` | bare expression, **pure `Function`**, and **`ConditionalExpression`** (matches the MSE question verbatim) |
| tests | `tests/smoke.wl` (custom harness, 27 checks, exit code) | `tests/inverse-asymptotic.wlt` (`VerificationTest`, 7 cases) + `tests/smoke.wl` (`TestReport`) |

## Cross-test results

### Test-suite × implementation matrix

| suite ↓ \ run on → | IA-1 (Claude) | IA-2 (GPT-5.5) |
|---|---|---|
| **IA-1 suite** (the 14 distinct math cases below) | **14/14 pass** (own baseline) | **8/14**: power-log/Puiseux/`∞`/some-analytic pass; wrong/complex branch on `Sin`, `Sinh`, `Cos`-sign, `x^2`-lower; no refusal on `x Log x`, `Sin[1/x]` |
| **IA-2 suite** (7 `VerificationTest`s) | **7/7 pass** mathematically (one input-form caveat, below) | **7/7 pass** (own baseline) |

### IA-2's tests run against IA-1 — all pass

Translating each of IA-2's 7 `VerificationTest`s to IA-1's API
(`InverseAsymptotic[f, x, y, n, "Remainder"→False]`):

| IA-2 test | IA-1 result |
|---|---|
| `x+x^2(1+Log x)`, goal 2 | ✅ `y − y^2(1+Log y)` |
| `x+x^2(1+Log x)`, goal 4 (full log-polynomial) | ✅ exact |
| `ConditionalExpression[#+#^Sqrt2,#≥0]&`, goal 4 | ✅ math exact **with the bare expression `x+x^Sqrt[2]`** — but IA-1 does **not** accept the `ConditionalExpression`/pure-function input form (returns `$Failed`); this is an API-surface gap, not a math gap |
| `x+x^2`, goal 4 | ✅ `y − y^2 + 2y^3 − 5y^4` |
| `2x+x^2`, goal 4 | ✅ `y/2 − y^2/8 + y^3/16 − 5y^4/128` |
| `x^2+x^3`, goal 4 | ✅ `Sqrt[y] − y/2 + 5y^(3/2)/8 − y^2` |
| `InverseAsymptoticVerify` residual check | ✅ IA-1's own `"Verified"` is `True` on the same case |

### IA-1's tests run against IA-2 — branch and refusal failures

Translating IA-1's cases to IA-2's API (`InverseAsymptotic[f, {x,x0}, {y,y0}, SeriesTermGoal→n]`):

| IA-1 case | IA-2 result | verdict |
|---|---|---|
| `x+x^2(1+Log x)`, `x+x^Sqrt[2]` (flagships) | identical to IA-1 (Newton core) | ✅ |
| `x+x^2`, `2x+x^2`, `x^2+x^3`, `x−x^2` | identical to IA-1 | ✅ |
| `Log[x]` at `x→1` → `Exp[y]` | correct (Newton core) | ✅ |
| `x+Log x`, `x+Sqrt[x]` at `x→∞` | identical to IA-1 | ✅ |
| `Exp[x]−1` → `Log(1+y)` | correct, via `SystemInverseFallback` | ✅ |
| `Tan[x]` → `ArcTan` | correct, via fallback | ✅ |
| `x·Exp[x]` → `ProductLog` | correct, via fallback | ✅ |
| **`Sin[x]`** → expects `ArcSin` | **`Pi − y − y^3/6`** — the branch through `x=π` (value `π` at `y=0`), **not** the requested `x0=0` | ❌ wrong branch |
| **`Sinh[x]`** → expects `ArcSinh` | **`I·Pi − y + y^3/6`** — a **complex** branch | ❌ complex branch |
| **`Cos[x]`** at `x→0+` → expects `+ArcCos` | `−Sqrt[2]Sqrt[1−y] + …` — the opposite (`x<0`) sign branch | ❌ branch sign |
| **`x^2`**, `Direction→FromBelow` → expects `−Sqrt[y]` | **`+Sqrt[y]`** — `Direction` is not used for branch selection | ❌ wrong sign |
| **`x·Log x`** (leading log) → IA-1 refuses | **`1 + y − y^2/2 + 2y^3/3`** — the analytic branch through `x=1`, via fallback (no refusal) | ❌ answers a different branch |
| **`Sin[1/x]`** (oscillatory) → IA-1 refuses | a finite-`x` local branch via fallback (no refusal) | ❌ answers a different question |

Root cause of every ❌: IA-2's native `expandExpression` covers only
`Plus/Times/Power/Log`, so any analytic head (`Sin`, `Cos`, `Sinh`, `Exp`, …) and
any genuinely out-of-scale input drops to `systemInverseFallback`, which returns
`Asymptotic[InverseFunction[f][y], …]` — and `InverseFunction` chooses the branch,
**unpredictably**: it happens to pick the `x=0` branch for `Tan` and `Exp[x]−1`
but the `x=π` branch for `Sin`, a complex branch for `Sinh`, and the `x=1` branch
for `x·Log x`. This is precisely the failure mode the task exists to avoid (it is
the same mechanism behind the `ProductLog[-1,-E]` complex branch that
`InverseFunction` returns for the flagship case). IA-1 avoids it by expanding
analytic heads **natively** and seeding the iteration at the requested `x0`, so
the branch is fixed by construction.

## Observations

1. **Convergent core, divergent edges.** Two models, working independently,
   built the same generalized power-log series engine — strong evidence that this
   representation is the natural one for the problem. The differences are all at
   the edges: branch selection, analytic heads, refusal, and API.

2. **IA-2's hybrid is a double-edged sword.** Delegating to Wolfram `Asymptotic`
   and to `InverseFunction` buys breadth cheaply (IA-2 returns *something* for
   more inputs and is shorter on analytic-head handling), but it imports
   `InverseFunction`'s branch ambiguity into a tool whose entire purpose is to
   pin the real branch. The fallback should never silently override the user's
   `x0`.

3. **IA-1's refusal is a feature.** Returning `$Failed` with a precise message for
   `x·Log x` (Lambert-W / iterated-log scale) and `Sin[1/x]` (no leading
   monomial) is more honest than IA-2's fall-through to an unrelated branch. A
   user who asked for the `x→0` asymptotic of `x·Log x` is better served by "out
   of scale, here's why" than by the `x=1` Taylor series.

4. **IA-2's API is more idiomatic.** `{x,x0}`, `{y,y0}`, `SeriesTermGoal`,
   `Assumptions`, and acceptance of pure functions / `ConditionalExpression`
   mirror `Series`, `Asymptotic`, and `AsymptoticSolve`, and match the MSE
   question's own `Asymptotic[InverseFunction[ConditionalExpression[…]&][z], …]`
   phrasing verbatim. IA-1's positional `f, x, y, n` with `"At"` is serviceable
   but bespoke, and it rejects the pure-function/`ConditionalExpression` forms.

5. **Verification philosophies differ.** IA-1 verifies **numerically** (residual
   decays at the claimed order across shrinking samples — robust to symbolic
   form, and it would *catch* a wrong branch because `f(X(y)) − y` would not
   vanish). IA-2 verifies **symbolically** (leading residual term is higher-order
   than the last retained term — exact when it succeeds, but it trusts the
   branch). Notably, IA-2 never runs its own verifier on the fallback output, so
   the `Sin`/`Sinh` wrong branches ship unflagged.

6. **Newton vs fixed point.** IA-2's Newton step is asymptotically faster (it
   roughly doubles correct terms per iteration); IA-1's linear iteration is
   simpler and, on the tested corpus, already fast. Not a differentiator in
   practice at these term counts.

## Recommendations

A "best of both" package is straightforward because the cores agree:

1. **Adopt IA-2's API surface** for IA-1: accept `{x,x0}` / `{y,y0}` specs,
   `SeriesTermGoal`, `Assumptions`, and pure-`Function`/`ConditionalExpression`
   inputs (the last closes IA-1's only gap against IA-2's tests). Keep IA-1's
   `x→a` rule sugar.
2. **Do not ship `InverseFunction`'s branch.** If a system-inverse fallback is
   kept at all, **gate it**: numerically check that the returned branch satisfies
   `f(x(y)) = y` *and* passes through the requested `x0` (e.g. `x(y0) = x0`)
   before returning; otherwise refuse. This single guard would convert IA-2's
   `Sin`/`Sinh`/`x·Log x` failures into either correct answers or clean refusals.
3. **Expand analytic heads natively** (port IA-1's `tsAnalytic`, or route IA-2's
   initial normalized-function expansion through its own `hybridAsymptotic…`
   instead of raw `expandExpression`). This lets the Newton core handle
   `Sin`/`Cos`/`Exp` seeded at `x0`, eliminating the bad fallback entirely for
   the common analytic cases.
4. **Use `Direction` for branch selection on even leading order** (IA-1's
   behavior): the lower branch of `x^2` must be `−Sqrt[y]`, not `+Sqrt[y]`.
5. **Keep IA-1's rate-based numeric verification** as the final gate on *any*
   output (native or fallback) — it is the cheapest reliable detector of a
   wrong branch.
6. **Keep IA-2's Newton iteration and `FullSimplify` post-processing** for speed
   and tidy output, and **keep IA-1's explicit `±∞` normalization and `RealBranches`/
   refusal diagnostics**.

In short: **IA-2's interface + IA-1's correctness discipline.** Until merged,
IA-1 is the safer default for real-branch fidelity, and IA-2 is the more
convenient front end for inputs already known to be in the analytic/power-log
class.

## Postscript — `src/InverseAsymptotic-2` removed (2026-06-28)

After this comparison, the merge was re-verified empirically against the running
Wolfram 15.0 kernel — the merged `src/InverseAsymptotic` run head-to-head against a
renamed in-kernel copy of IA-2. The merged package passes **all** of IA-2's own test
cases and **strictly dominates** IA-2 on every case where the two differ: `Sin -> ArcSin`
(IA-2 returns the `Pi` branch), `Sinh -> ArcSinh` (IA-2 returns a complex branch),
`x + Erf[x] -> $Failed` honest refusal (IA-2's ungated fallback ships
unevaluated-`Derivative` garbage), and pure `Erf[x] -> InverseErf` in both.

IA-2's one architecturally distinct idea — the hybrid delegation to the kernel's
`Asymptotic` for forward expansion — was found to add **no** real head breadth: it runs
only *after* IA-2's native `Plus/Times/Power/Log` expander already succeeds, and
substituting a power series into such an expression keeps it in that fragment, so the
hybrid never reaches a head the native engine could not. With nothing left to absorb, the
GPT-5.5 reference directory `src/InverseAsymptotic-2` was deleted; this report is kept as
the rationale record.

The surviving cross-test — IA-2's cases (preserved) run against this package — is:

```powershell
$wl = "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe"
& $wl -script src/InverseAsymptotic/tests/cross-from-inverse-2.wl   # all pass
```

(The reverse direction, IA-1's cases against IA-2, is no longer reproducible because IA-2
was removed; that result is recorded in the matrix above.)
