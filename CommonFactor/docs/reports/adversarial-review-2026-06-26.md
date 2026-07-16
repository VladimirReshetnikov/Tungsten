# CommonFactor — Adversarial Code & Documentation Review

- Status: Review report
- Audience: Vladimir; future agents maintaining `CommonFactor`
- Scope: the `codex/common-factor` branch (package implemented by GPT-5.5 Codex)
- Created (UTC): 2026-06-26T19:31:02Z
- Repository HEAD: 1f7f46650687a40f673b402b51a27398b765c48e
- Reviewer: Claude Code (Opus 4.8), with a 6-dimension static fan-out + completeness critic and
  hands-on adversarial testing on the local paid Wolfram 15.0 kernel
- Subject commits: `81180fe00` → `1f7f46650` (5 commits adding `CommonFactor`)

---

## 1. Executive summary

`CommonFactor` is a genuinely useful, thoughtfully-built first cut at the open Mathematica
StackExchange question [#261053](https://mathematica.stackexchange.com/questions/261053). It does the
hard part **correctly**: every peeled factor exactly divides the observed terms, and the returned
`Factor` always reconstructs the input (`Factor(i) · QuotientSequence[i] === a_i`) — I verified this on
the full smoke corpus plus adversarial inputs and it held everywhere. All 22 author smoke tests pass.
The prime-valuation discovery layer is the standout idea and it works (`13^n`, `p^(n²)` are recovered
outside the default base range). Empirically the tool does **not** hallucinate factors on generic
sequences (a 5-term run of distinct primes yields `Factor → 1`, candidate report empty).

The problems are not in the arithmetic; they are in **form fidelity, robustness, performance, and a few
footguns** — and crucially, *several of them are masked by the smoke tests*, which only assert numeric
equivalence (`sameValuesQ`) and only inspect `QuotientSequence`.

Headline issues, all reproduced on the kernel:

| # | Severity | Issue | One-line evidence |
|---|----------|-------|-------------------|
| F1 | **High** | The flagship example returns an *opaque* factor, not the advertised one | `Factor = (5^n n² Gamma[2+2n])/n!`, not `10^n (2n+1)!! n²` |
| F2 | **High** | Unbounded `FactorInteger` on the default path → indefinite hang | 90-digit semiprime term: no return in 25 s; `TimeConstraint→6` returns fine |
| F3 | **High/Med** | Rational/zero/`PreferInteger` path is pathologically slow | 6–115 s for 6–8 term inputs |
| F4 | **Medium** | Same integer sequence gives a weaker result via `QuotientTarget` | bare call → quotient `primes`; `PreferInteger` → quotient `n·primes` |
| F5 | **Medium** | `data["Factor"]` silently corrupts when `n` has a global value | `n=42` ⇒ `data["Factor"]` reads `4398046511104` |
| F6 | **Medium** | Short-fragment valuation overfitting; no holdout / min-length guard | `{4,2,4}` → `Factor = 2^(n²-4n+5)` |
| F7 | **Medium** | `MaxSteps -> 64` (the documented default value) is silently downgraded to 2 | `result(MaxSteps→64) === result(default)` |
| F8 | **Low/Med** | Documentation overstates results & lists keys the integer path never returns | 5 README keys absent on integer input |

**Verdict:** solid and correct core, ship-able for interactive integer use, but it needs (a) a
factor-form normalization pass, (b) an always-on factorization time/size guard, (c) rational-path
performance work, and (d) the doc corrections below before it can be presented as "recovers
`10^n (2n+1)!! n²`". None of these are deep architectural flaws; they are finishing work the author
mostly already anticipated (the design doc's Open Questions name the form problem and the missing
holdout validation explicitly).

A useful meta-result: this review ran a 6-agent static read first, then verified every claim on the
kernel. **Verification mattered** — it refuted or substantially recalibrated five of the static
hypotheses (see §6). I report only the empirically grounded conclusions.

---

## 2. Methodology

1. **Baseline.** Ran the 22-check smoke suite on Wolfram 15.0 — all pass (exit 0).
2. **Static fan-out.** Six independent adversarial readings of the 1320-line package
   (integer path, rational/zero path, API/robustness, math soundness, docs, performance/DoS), each
   returning structured findings, followed by a completeness critic that audited the six and looked for
   cross-cutting gaps. ~704k tokens across 7 agents.
3. **Empirical adversarial testing.** Every concrete hypothesis was executed against the live kernel
   (persistent MCP evaluator, to respect the ~2-seat license limit). I report each finding as
   **CONFIRMED** (reproduced), **REFUTED** (tested, did not reproduce), or **STATIC** (code-evident,
   not run). Verbatim kernel output is quoted.

Environment note: during the review the machine had **four** live `wolfram.exe … StartMCPServer`
kernels (PIDs 24876, 14068, 4776, 22676), exhausting the license seats; `wolfram.exe -script` runs
failed with the misleading "No valid password" (CLAUDE.md's documented seat gotcha). All testing was
therefore routed through the single persistent MCP kernel. This is an environment artifact, not a
package issue, but it is worth a periodic orphan-kernel sweep.

---

## 3. What works well (keep these)

- **Reconstruction is exact and never silently wrong.** For every tested input,
  `Factor /. n->i === FactorValues[[i]]` and `Factor(i)·QuotientSequence[i] === a_i`. `FullSimplify` is
  given `Element[n, Integers] && n >= start`, so it is value-preserving on the sampled domain; the
  critic's worry that the simplified `Factor` might not reconstruct did **not** reproduce (§6).
- **Prime-valuation discovery is the best idea here and it works.** Affine and quadratic valuation
  fits recover `13^n` and `17^(n²)` even though those bases are outside `Bases` (Range[2,12]).
- **No hallucination on generic data.** `CommonFactorCandidateReport[Prime[Range[1000,1004]], n]`
  returns an empty list; `FindSymbolicCommonFactor` returns `1`. Distinct primes correctly yield no
  factor.
- **Graceful degenerate handling.** `{}` → `$Failed` with `::seq`; `{0,0,0}` → factor `1` with a
  diagnostic string; all-ones → factor `1`; inexact input rejected.
- **The zero-aware rational design is genuinely thoughtful** — the four-case removable-hole table,
  `KnownResidualPairs` for `FindSequenceFunction`, signed valuations over the support — and the design
  doc is honest about its own open questions.
- **Sign handling is correct.** `(-1)^k 5^k k!` → `(-5)^n n!`, reconstructs.

---

## 4. Findings (detailed)

Line references are to `CommonFactor/CommonFactor.wl` unless noted.

### F1 — [High] The flagship example returns an opaque Gamma-quotient, not the advertised recognizable factor — CONFIRMED

The entire point of the question is to recover a **recognizable** factor "constructed using simple
arithmetic operations and combinatorial sequences such as factorial, double factorial, or Catalan
numbers" — the worked target being `10^n (2n+1)!! n²`. The package instead returns a mathematically
equal but opaque form. Verbatim from the kernel (same code the `Demo.wl` runs):

```
DEMO Factor -> (5^n*n^2*Gamma[2 + 2*n])/n!
  Gamma[2 + 2*n]/Gamma[1 + n]   (GammaQuotient)
  5^n                           (ValuationPower)
  n^2                           (Linear)
```

`Gamma[2+2n]/Gamma[1+n] = (2n+1)!/n! = 2^n (2n+1)!!`, so the `GammaQuotient` candidate secretly absorbs
the `2^n` half of `10^n`, leaving only `5^n`; the double factorial and the `10^n` structure both vanish.
Root cause: the `GammaQuotient` has strictly higher growth than `Factorial2[2n+1]` (it carries the extra
`2^n`), so the greedy scorer prefers it (`candidateGrowth`, line 141; selection at lines 853-856), and
`factorExpression`'s `FullSimplify` (line 873) then fuses everything into `(5^n n² Gamma[2+2n])/n!`.

This is **not** a correctness bug — the quotient is still the clean prime sequence and the result
reconstructs — but it defeats the stated purpose, and the docs claim otherwise:

- `README.md:132-139` says the suite "recovers a factor **equivalent on the observed index range** to
  `10^n Factorial2[2 n + 1] n^2`" — true only as *value*-equivalence; the form is unrecognizable.
- `README.md:149` says "The demo script prints the motivating decomposition" — it prints the opaque one.
- The smoke test passes only because it uses `sameValuesQ` (numeric), never comparing forms.

The author already knows: `docs/rational-sequences-design.md:658-660` lists as an Open Question
"Formula complexity should penalize opaque Gamma quotients when a named combinatorial equivalent is
available. A post-pass should rewrite factors toward `CatalanNumber`, `Binomial`, `Pochhammer`, and
factorials when possible." That post-pass is the fix.

A milder instance: `seq7` (the Pochhammer×FallingFactorial smoke case) returns
`FactorialPower[4+n,2]·FactorialPower[5+n,4]` rather than the documented `Pochhammer[n+2,3]·FactorialPower[n+5,3]`
(equal, but re-expressed).

**Fix.** Add a factor-normalization post-pass: prefer named combinatorial heads over `Gamma` quotients
of equal value; bias scoring against `Gamma`/`BarnesG` when a `Factorial`/`Factorial2`/`Binomial`/
`CatalanNumber`/`Pochhammer` form with the same values exists. At minimum, soften the README/Demo claims
to "a factor *value-equivalent* to …" and show the actual output.

### F2 — [High] Unbounded `FactorInteger` on the default path hangs indefinitely — CONFIRMED

`valuationCandidateExpressions` (lines 561-564) and `signedValuationCandidateExpressions` (593-601) call
`FactorInteger` on every term; only when the deadline is **finite** is it wrapped in `TimeConstrained`:

```wolfram
fi = If[deadline === Infinity, FactorInteger[Abs[term]],
        TimeConstrained[FactorInteger[Abs[term]], Max[0.001, remainingTime[deadline]], $TimedOut]];
```

The default is `TimeConstraint -> Infinity` (line 91), so the default call factors every term with **no
bound**. The question's premise is *fast-growing* sequences whose terms are huge; a single hard
composite term then hangs the whole call. Reproduced with a 90-digit semiprime:

```
term digit count: 90
A default(Infinity), ext-guard 25s: 25.0007s -> HUNG (no return in 25s)
B TimeConstraint->6: 6.02559s -> returned: 1  timedOut=True
```

The "safe-looking" default (no time limit) is the **only** unsafe configuration. The design doc
(`rational-sequences-design.md:555`) explicitly promises "every expensive operation (`FactorInteger`,
…) checks the remaining budget" — the default path violates that contract.

**Fix.** Always wrap `FactorInteger` in a finite inner ceiling independent of the global budget (e.g. a
few seconds, or a digit-count threshold above which valuation discovery is skipped with a diagnostic).
Falling back to the default candidate families when factorization is abandoned degrades gracefully.

### F3 — [High/Medium] The rational / zero-aware / `PreferInteger` beam path is pathologically slow — CONFIRMED

Wall-clock for tiny inputs (Wolfram 15.0, warm kernel):

| Input | Terms | Options | Time |
|---|---|---|---|
| `((k+1)(k+2)/((k+3)(k+4)))·prime` | 7 | default | **6.2 s** |
| `2^k 3^k ((k+1)/(k+5))·prime` | 6 | default | **19.3 s** |
| `2^k 3^k ((k+1)/(k+5))·prime` | 6 | `MaxSteps->8` | **115.2 s** |
| `(k-3)^2·prime` (zero path) | 7 | default | **28.0 s** |
| `(k^2/2)·prime` | 7 | default | **50.0 s** |

Causes (lines): `generateRationalCandidates` builds hundreds of candidates including all reciprocals and
ratio families (440-479); each is evaluated under a `TimeConstrained[…, 0.05]` (271); the beam loop is
`Table[…, {state, beam}, {cand, candidates}]` with `BeamWidth` up to 32 (1104-1110), each cell running
`zeroAwareQuotient` + `rationalComplexityVector` (Log over all residuals); and `FullSimplify` runs at the
end. `RatioPairLimit` (default 64) bounds only the linear-ratio pairs (444-445) — the factorial,
Pochhammer (9×9×5=405), falling-factorial (405) and combinatorial ratio families are generated in full
regardless, contradicting the design doc's staged-generation plan (450-457).

**Fix.** Implement the design doc's staged generation (score atoms, keep top-K numerator/denominator
atoms, then form ratios only within budget); make `RatioPairLimit` bound *all* ratio families; cache
candidate `Values`; prune the accumulated candidate list across rounds.

### F4 — [Medium] The same integer sequence yields a weaker result depending only on `QuotientTarget` routing — CONFIRMED

`reduceDispatch` (1243) routes an exact nonzero integer sequence to the fast greedy path **unless**
`QuotientTarget` is `"Rational"` or `"PreferInteger"`, in which case it goes to the rational beam, which
silently caps default `MaxSteps` to 2 (1072). `PreferInteger` is exactly the option a user reaches for
to bias toward integer quotients. On the motivating sequence:

```
bare call             -> quotient = {233,239,241,251,257,263,269,271,277}   (clean primes)
PreferInteger default -> quotient = {233,478,723,1004,1285,...}             (= n·Prime[50+n], under-peeled)
PreferInteger MaxSteps->10 -> quotient = {233,239,241,...}                  (full peel, 3 steps)
PreferInteger SearchRounds->4 -> quotient = {233,478,723,...}              (still under-peeled)
```

So the documented flagship result is *not* reproducible through `PreferInteger` at default settings, with
no diagnostic that a shallower search ran. Note the empirically-correct nuance (which the static review
got partly wrong, §6): **explicit `MaxSteps->10` does fix it** (3 steps, clean primes); `SearchRounds`
does not help here; and `MaxSteps->64` specifically is broken by F7.

**Fix.** Either share one effective default `MaxSteps` across paths, or have `QuotientTarget` change only
the *scoring*, not the *search depth*; and surface the effective step budget in the result.

### F5 — [Medium] `data["Factor"]` re-evaluates against a global value of `n` — CONFIRMED

`HoldRest` + `Block[{n}]` (1304-1306) correctly let the *input* `n` be a symbol even if it has an
`OwnValue`. But the returned association stores `Factor` (and `SelectedFactors[…]["Expression"]`) as a
**live** expression in the symbol `n`, with no `HoldForm`/`Inactive` guard. Extraction re-evaluates in
the caller's context:

```
n = 42;  res = CommonFactorReduce[{2,4,8}, n, "Progress"->False];
FreeQ[res, 42]                                   -> True       (* stores Power[2,n], not 2^42 *)
res["Factor"]                                    -> 4398046511104   (* = 2^42 on extraction *)
Clear[n];  res["Factor"]                         -> 2^n
```

The smoke test "held index symbol works when n has an OwnValue" (smoke.wl:133-137) passes only because
it inspects `QuotientSequence` (a frozen integer list), never `Factor`. So the package *advertises*
support for a valued `n` but silently corrupts the headline output in that case.

**Fix.** Substitute a fresh formal symbol for `n` in the stored result (e.g. return the factor in terms
of an internal `\[FormalN]` or replace `n -> Unique[]` at the boundary), or document that `n` must be
undefined and assert it.

### F6 — [Medium] Short-fragment valuation overfitting; no holdout / min-length guard — CONFIRMED

`exactValuationPolynomial` (505-514) interpolates a degree-`d` polynomial through the **first `d+1`**
sample points and then "verifies" it on **all** indices via `integerPolynomialValuesQ` (501). When
`Length == d+1`, the verification set *is* the interpolation set, so the check is vacuous and any
3-term valuation profile is fit by a quadratic exponent:

```
{4,2,4} -> Factor = 2^(5 + (-4 + n)*n)   ( = 2^((n-2)^2 + 1) ),  quotient {1,1,1}
{9,3,9,3} (length 4) -> Factor = 1        (quadratic fails the 4th point, correctly rejected)
```

So the defect bites precisely at `length == degree+1` (length 3 for the quadratic, length 2 for the
affine fit) — i.e. the short-fragment regime the tool targets — and is correctly self-limiting for
longer inputs. There is also no minimum-length guard anywhere: single points overfit freely and silently
(`{8}->8^n`, `{16}->2^(3+n)`, `{12}->12^n`), and no result field distinguishes a structurally-supported
factor from pure interpolation. The design doc lists "holdout validation for candidate products when
enough terms exist" as a Phase-4 deliverable (615-626) that is not implemented.

**Fix.** Reject vacuous self-verification (require ≥1 out-of-sample node, i.e. degree `d` only when
`Length ≥ d+2`); add a low-confidence diagnostic when `length` is small or when a candidate's free
parameters approach the sample length; consider an "insufficient data" note below some minimum length.

### F7 — [Medium] `MaxSteps -> 64` (the documented default value) is silently downgraded to 2 — CONFIRMED

`rationalReduceCore` distinguishes "user left `MaxSteps` at default" by value comparison
(`maxSteps === ("MaxSteps" /. Options[CommonFactorReduce])`, 1072), and the default is `64` (line 80).
Option resolution can't tell an explicit `MaxSteps->64` from the inherited default, so a user typing the
natural "search deeply" value 64 is silently capped to 2:

```
CommonFactorReduce[threeAtom, n, "MaxSteps"->64]["Factor"] === CommonFactorReduce[threeAtom, n]["Factor"]
   -> True      (* both ran the 2-step capped search *)
```

`MaxSteps->10` or `MaxSteps->65` would behave differently (deeper) — only `64` collides. The design doc
(650-651) even claims "Explicit MaxSteps values still request deeper rational searches", which is false
for the value `64`.

**Fix.** Use a sentinel (`Automatic`) for the rational depth default instead of overloading the integer
default `64`; resolve "user supplied vs. default" via `OptionValue`/a distinct marker, not value
equality.

### F8 — [Low/Medium] Documentation inaccuracies — CONFIRMED (static + kernel)

- **Integer path omits 5 README-documented keys.** `README.md:43-59` shows a single flat result schema
  including `ResidualComplexity`, `ZeroIndices`, `UnknownQuotientIndices`, `KnownResidualPairs`. On
  integer input `finalAssociation` (977-1000) returns none of these (nor `InputDomain`):
  ```
  CommonFactorReduce[{2,4,8}, n] -> all of {ResidualComplexity, ZeroIndices,
     UnknownQuotientIndices, KnownResidualPairs, InputDomain} KeyExistsQ -> False
  ```
  (The `::usage` string at 38-51 gets this right — "Rational and zero-containing input returns
  *additional* diagnostics …"; only the README is wrong.) Split the schema by input type.
- **`BeamWidth` default mismatch.** Design doc says `16` (`rational-sequences-design.md:608`); code uses
  `32` (line 87).
- **`BestStateCount` documented but never emitted** (design doc 538 vs `finalRationalAssociation`
  1005-1035).
- **Widening-until-time-budget claim.** `README.md:71-73, 96-97` say the candidate horizon "keeps
  widening until the time budget is exhausted"; in the rational path the search effectively stops after
  ~2 improving steps under default `SearchRounds`, and (F4) `SearchRounds` did not deepen the
  `PreferInteger` example. Reconcile docs with actual depth behavior.
- **Progress-line description.** `README.md:67-69` ("prints a progress line every time it discovers a
  larger factor") matches the rational path but not the integer path, which prints on *every* accepted
  peel step (emitProgress is unconditional, 1203-1210).
- **Provenance header** (`README.md:7`) records `99d9ca081…`, the parent of the first CommonFactor
  commit; valid SHA, but the prose describes features added later. Cosmetic.

### F9 — [Low] Minor API footguns — CONFIRMED / STATIC

- **Non-symbol index returns unevaluated, no message** (STATIC + confirmed): `CommonFactorReduce[{2,4,8}, 5]`
  → returns the literal unevaluated call (only `n_Symbol` defs exist, 1304-1317). A `::sym` message + `$Failed`
  would be friendlier, consistent with the existing `::seq`/`::start`/`::opt` messages.
- **`Progress -> True` default prints from `FindSymbolicCommonFactor`** (CONFIRMED behavior): a pure-value
  function emits `Print` side effects by default (90, 878-889). Consider quiet-by-default for the
  value-only function.
- **`safeValues` message watch-list may be imprecise** (line 238-242): tags like `Infinity::indet` /
  `Factorial::fact` may not be the ones actually emitted at poles. Impact is low because
  `validCandidateValuesQ` (`VectorQ[_, IntegerQ]`) rejects any `ComplexInfinity`/`Indeterminate` values
  anyway; the only symptom would be a leaked message during candidate generation.

---

## 5. Recommendations (prioritized)

1. **Always bound `FactorInteger`** (F2) — highest user-impact robustness fix; a fixed inner ceiling or
   digit threshold. One-liner change with large payoff.
2. **Factor-form normalization post-pass** (F1) — make the headline example actually print
   `10^n (2n+1)!! n²` (or value-equivalent recognizable form); rewrite `Gamma` quotients toward named
   combinatorial heads. This is what makes the tool *answer the question as asked*.
3. **Fix the rational depth controls** (F4, F7) — sentinel-based default instead of the `64` collision;
   make `QuotientTarget` affect scoring not depth; surface the effective step budget.
4. **Rational-path performance** (F3) — staged candidate generation; bound *all* ratio families by
   `RatioPairLimit`; cache values. Today 50–115 s for ≤8 terms is too slow for interactive use.
5. **Overfitting guards** (F6) — reject vacuous self-verification (`Length ≥ degree+2`); add a
   confidence/holdout signal; consider a minimum-length note.
6. **`n`-value hardening** (F5) — return the factor over a fresh symbol, or assert `n` undefined.
7. **Documentation corrections** (F8) — split result schema by input type, fix `BeamWidth`/`BestStateCount`,
   reconcile the widening/MaxSteps claims, soften "recovers `10^n (2n+1)!! n²`" to value-equivalence (or
   deliver it via #2).
8. **Strengthen the smoke suite** to lock these down: assert `Factor(i) === FactorValues[i]` (catches any
   future FullSimplify regression); assert `Factor` *form* on the motivating example once #2 lands; add a
   hard-composite term with a finite `TimeConstraint`; add a length-3 input that must **not** overfit;
   add an `n=42` case that checks `Factor`, not just `QuotientSequence`.

---

## 6. Calibration of the static review (verification mattered)

Running the static fan-out first and then verifying on the kernel changed the conclusions materially.
The following static hypotheses were **refuted or recalibrated** by testing:

- **"Factor may not reconstruct the input (FullSimplify-fragile)"** (critic, High) — **REFUTED.**
  `Factor(i) === FactorValues[i]` and `Factor(i)·quotient === a_i` held on every tested input including
  the sign and Gamma-rewrite cases. `FullSimplify` under the integer-domain assumption is value-preserving.
- **"Rational mode caps exponent at 1, so `n²` is unreachable"** (rational reviewer, High) —
  **REFUTED.** Repeated selection across steps recovers powers: `(k-3)²` → `(-3+n)²`, `k²/2` → `n²`. The
  real limit is the 2-*step* default, not the exponent cap.
- **"Explicit `MaxSteps` has no effect / `step>1 Break` caps depth regardless of `MaxSteps`"**
  (rational reviewer + critic) — **REFUTED.** `MaxSteps->10` deepened `PreferInteger` to 3 steps and
  fully peeled. The genuine issues are the silent default-of-2 (F4) and the `64` collision (F7).
- **"Growth metric ranks `10^n` above `n!`, so it picks the wrong factor"** (math reviewer, High) —
  **RECALIBRATED to cosmetic.** The metric values are real (`9.21` vs `3.65`), but when both are genuine
  factors both are peeled (`10^k k!` → `Factor = 10^n n!`); the ranking only affects peel *order*, not
  the final product.
- **"Legitimate slow-growth divisors are silently dropped"** (integer reviewer, Low) — **REFUTED at
  default settings** (critic was right to flag it as a false positive). `(k+1)·prime` → `Factor = 1+n`;
  the drop only manifests at a deliberately raised `ComplexityPenalty`.
- **"Overfitting/hallucination is broad"** (math reviewer, Medium) — **NARROWED.** Generic sequences do
  not hallucinate (distinct primes → empty report, `Factor → 1`). The real, sharp case is the
  `length == degree+1` valuation overfit (F6).

Findings that **survived** verification are F1–F9 above.

---

## 7. Reproduction appendix

All run on Wolfram 15.0 with `Get["CommonFactor/CommonFactor.wl"]` and `Clear[n]` unless noted.

```wolfram
(* F1 *) b = Table[Prime[50+k],{k,9}]; seq = Table[10^k Factorial2[2k+1] k^2 b[[k]],{k,9}];
         CommonFactorReduce[seq, n, "Progress"->False]["Factor"]
         (* (5^n*n^2*Gamma[2+2*n])/n! *)

(* F2 *) p = NextPrime[10^44]; q = NextPrime[3*10^45]; s = {2 p q, 4 p q, 6 p q};
         TimeConstrained[CommonFactorReduce[s, n], 25]          (* hangs *)
         CommonFactorReduce[s, n, TimeConstraint->6]            (* returns 1, TimedOut->True *)

(* F4 *) CommonFactorReduce[seq, n, "QuotientTarget"->"PreferInteger"]["QuotientSequence"]
         (* {233,478,723,1004,...} = n*Prime[50+n], vs clean primes from the bare call *)

(* F5 *) n=42; r=CommonFactorReduce[{2,4,8}, n]; {FreeQ[r,42], r["Factor"]}   (* {True, 4398046511104} *)
         Clear[n]; r["Factor"]                                                (* 2^n *)

(* F6 *) CommonFactorReduce[{4,2,4}, n, "Progress"->False]["Factor"]          (* 2^(5+(-4+n)*n) *)

(* F7 *) ta = Table[2^k 3^k ((k+1)/(k+5)) Prime[40+k], {k,6}];
         CommonFactorReduce[ta,n,"MaxSteps"->64]["Factor"] === CommonFactorReduce[ta,n]["Factor"]  (* True *)

(* refuted: reconstruction *) (* Factor(i)===FactorValues and Factor(i)*quotient===a_i on every smoke seq *)
```
