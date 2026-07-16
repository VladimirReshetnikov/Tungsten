# Review: Overflow/Underflow Large-Number Fallback (Tungsten)

- Status: Maintainer review of the design proposal
- Reviewed proposal: `Engine/docs/overflow-underflow-large-number-fallback.md`
- Reviewed history window: `370c28b9562eccbda96d2c6a25d6d64da10250d8` (inclusive) .. `de64e8978becc8d82170622d071d646ba5ae9f44` (HEAD)
- Created (UTC): 2026-04-29T00:29:34Z
- Repository HEAD: de64e8978becc8d82170622d071d646ba5ae9f44

## Executive Verdict

The proposal is directionally correct and is the right boundary for Tungsten: keep existing exact and
finite machine/decimal arithmetic fast and compatible, then *retry the same operation* in a
Tungsten-owned large-number engine only when the machine result becomes non-finite or collapses
information (overflow to `Overflow[]`, underflow to an indistinguishable `0.`).

I recommend accepting the design with a few targeted clarifications:

- Be explicit about which operations get underflow fallback in v1 (multiplication/division/power are
  straightforward; addition needs a conservative policy to avoid mis-triggering on cancellation).
- Treat “certified precision” as a first-class payload concept from day 1, but separate it from “we
  computed at high working precision”. Nummy shows that these are not the same thing.
- Keep the “exact power guard” in scope (it is a correctness/safety requirement, not a performance
  nice-to-have).

## What Changed In This History Window

This range is largely a documentation-and-analysis tranche:

- Nummy: multiple alpha/beta/gamma comparison reports were generated, merged, then consolidated into
  `Engine/Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md` with antecedents archived under
  `Engine/Nummy/docs/reports/archived/`.
- Tungsten: numeric docs were updated and a new proposal was added:
  `Engine/docs/overflow-underflow-large-number-fallback.md`, plus a short
  `Engine/src/tungsten/review-notes-2026-04-28.md` capturing implementation seams.

## What I Verified

### Tungsten numeric choke points

I reviewed the concrete integration seams called out by the proposal in
`Engine/src/tungsten/expression.py`:

- `_machine_real` maps `inf` → `Overflow[]` and does not model underflow.
- `_inexact_real_result` is the machine-real fold point for `Plus`/`Times` real arithmetic when
  operand precision is machine (float path).
- `_div_real_expr` is the machine-real division path.
- `_real_power_expr` is the machine-real power path (both integer-power and float-power cases).

This confirms the proposal’s core premise: today, float underflow can silently become `0.0` and the
information loss happens *before* any Tungsten semantic layer can react.

### Nummy acceptance behavior (alpha/beta/gamma)

I ran the acceptance expression through all three prototypes and observed the same behavior
summarized in the unified comparison:

- `alpha` (from `Engine/Nummy/src/alpha`) accepts ordinary syntax and prints the landmark-plus-tail
  form with a precision mark; `Floor[...]` returns a sparse exact integer part.
- `beta` (from `Engine/Nummy/src/beta`) preserves the scale structurally for ordinary syntax, but
  recovers the finite tail only through its dedicated `LeadingDigits[...]` builtin.
- `gamma` (from `Engine/Nummy/src/gamma`) prints a compact `10^10^10 + ...` form from ordinary syntax,
  but does not expose precision marks or a `Floor[...]` path.

This matches the archived and unified reports and supports the proposal’s “harvest alpha discipline,
beta engine concepts, gamma vocabulary” synthesis.

## Strong Parts Of The Tungsten Proposal

### Provenance-based triggering (do not reinterpret explicit `Overflow[]` / `Underflow[]`)

The proposal’s “do not promote special atoms into large numbers” rule is important and, in my view,
correct:

- It preserves existing Wolfram-compatible semantics for explicit `Overflow[]` / `Underflow[]`.
- It avoids back-propagating intent from a lossy representation (a bare `Overflow[]` cannot encode
  whether it came from `Exp[1000.]` vs `1./0.` vs user input).
- It makes fallback auditable and testable (“this `LargeReal` exists because operation X overflowed
  on finite operands”).

### `LargeReal` as an atom with `Head[Real]`

Making `LargeReal` a real-valued numeric atom aligns with Tungsten’s current numeric tower design
(`Integer`, `RationalNumber`, `Real`, `ComplexNumber`, `SpecialReal`) and keeps predicates like
`AtomQ`, `NumberQ`, and `RealValuedNumberQ` structurally correct without inventing a new user-visible
head.

### Exact-power guard is non-negotiable

The proposal correctly notes that the “large-number story” is not only about float overflow. It is
also about preventing catastrophic exact allocation for expressions that are syntactically ordinary
in Wolfram land (e.g., `10^10^10`).

The guard belongs close to the exact-integer exponent path (and, practically, it will need to cover
both exact integer bases and exact rational bases that would allocate huge integers during `Fraction
** power`).

### Phased test plan is practical

The test plan has the right shape: lock down *semantics* first (predicates, precision/accuracy, JSON
shape), then add fallback triggers, then add the exact-power guard, then build the tower/landmark
engine and the MathOverflow path.

## Concerns / Clarifications

### 1) Underflow fallback policy for addition

The proposal calls out a real problem: underflow-to-`0.0` is silent. For multiplication/division,
“finite nonzero operands produced zero” is already a strong signal.

For addition, the trigger conditions need a more explicit policy statement, because:

- `a + b` can legitimately round to `0.0` (exact cancellation).
- even when the exact mathematical result is nonzero, proving it is nonzero without a higher-precision
  model may require more work than is worth it for v1.

Recommendation:

- Implement underflow fallback for `Times`, `Divide`, and machine-real `Power` first.
- For `Plus`, either skip underflow fallback initially or restrict it to cases where cancellation is
  structurally impossible (for example: same-sign operands, and a magnitude bound shows the sum must
  be nonzero but below the smallest representable magnitude).

### 2) `Power` needs two complementary safeguards

There are two different “Power hazards” that should be handled explicitly:

1. **Machine power overflow/underflow**: the proposal covers this (hook in `_real_power_expr`).
2. **Exact integer blowups**: the proposal also covers this (digit estimate guard).

The implementation should ensure these safeguards apply across:

- exact integer base/exponent;
- exact rational base with integer exponent (can allocate large numerator/denominator);
- machine-real base with integer exponent (Python float underflow to `0.0` and overflow to `inf`);
- machine-real base with non-integer exponent (overflow/underflow/domain errors).

### 3) “Certified digits” must be data, not formatting

The proposal’s precision contract is the right target behavior, but the implementation detail matters:

- Nummy `alpha` is conservative because it keeps exact rationals for ordinary scalar arithmetic and
  explicitly marks uncertified structural tower displays.
- Nummy `beta` exposes residual information in its `LeadingDigits[...]` report; it still does not
  constitute a global proof of every printed digit.
- Nummy `gamma` demonstrates how easy it is to print plausible-looking tails without a visible
  certification story (and its formatting can fail when the Decimal context is too small for a
  requested fractional digit count).

Recommendation:

- Introduce a minimal explicit “certainty object” (interval/radius, residual bound, or “certified
  digit count”) as part of the payload contract, even if the only initial certified results are:
  - scientific-scale values with “certified digits = input precision (capped)”;
  - the MO landmark-tail path with a tight residual bound.

### 4) “LargeReal” scope creep risk: keep v1 minimal

The proposal’s payload taxonomy (decimal interval, reciprocal tiny value, structural tower,
landmark+tail, sparse exact integer) is good, but it is easy to overbuild.

Recommendation:

- Define a *small* payload set that supports the initial triggers + MO path, then extend later.
- Keep `large_numbers/*` independent from Tungsten AST early (as the proposal suggests), but accept
  that a thin adapter layer will still need to understand a subset of Tungsten numeric atoms.

### 5) Documentation provenance metadata consistency

Several docs in this window record `Repository HEAD: 7b191bfb...` (the parent of `de64e897...`).
That may be intentional (“HEAD at doc authoring time”), but it reads inconsistent when the docs are
first introduced by the `de64e897...` commit.

Recommendation:

- Decide on a single rule and enforce it with `Engine/scripts/Update-TungstenDocsProvenance.ps1`.
  If the rule is “HEAD at doc creation time before commit”, this is fine; otherwise consider bumping
  the metadata once the docs are committed.

## Are The Nummy Prototype Conclusions Sound?

Yes, with the caveat that the reports are correctly scoped to “engineering conclusions for next
steps”, not a full prior-art audit.

Specifically, the unified comparison’s bottom line (“alpha UX discipline, beta asymptotic engine,
gamma vocabulary; none are complete LI/SLI with proof-grade digits everywhere yet”) matches what the
code and tests demonstrate today:

- Alpha’s calculator UX and sparse-integer `Floor[...]` path are uniquely aligned with Tungsten’s
  needs.
- Beta’s architecture for perturbation/series propagation is the best foundation for generalizing
  beyond the single MO expression, even though it is not wired into ordinary `^` evaluation yet.
- Gamma’s `Pow10Tower` / landmark-tail types remain the cleanest minimal data contract model, even
  though the evaluator is intentionally narrow.

The Tungsten proposal draws the right conclusions from that analysis (reuse lessons, not code; add a
certainty object; keep runtime independence from `Engine/Nummy/src/*`).

## Concrete Suggestions For The Tungsten Implementation

- Implement v1 underflow fallback only for `Times`/`Divide`/`Power` on machine reals; keep addition
  conservative until a nonzero proof rule is nailed down.
- Ensure the machine-power path catches both `OverflowError` and underflow-to-zero for integer
  exponents.
- Put the exact-power guard on the exact code path before any `pow`/`Fraction ** power` allocation.
- Add a `LargeReal` payload field for “residual bound / interval radius” and make formatting consult
  it before claiming digits.
- Add one golden acceptance test mirroring Nummy alpha’s behavior for the MO expression, plus a
  small set of overflow/underflow triggers (`10.^400`, `10.^-400`, etc.).

