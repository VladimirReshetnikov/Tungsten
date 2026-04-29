# Review: Overflow/Underflow Large-Number Fallback Design

- Status: Design review notes for Tungsten maintainers
- Reviewed proposal: `../overflow-underflow-large-number-fallback.md`
- Reviewed history: `370c28b9562eccbda96d2c6a25d6d64da10250d8..de64e8978becc8d82170622d071d646ba5ae9f44`
- Created (UTC): 2026-04-29T00:28:06Z
- Repository HEAD: de64e8978becc8d82170622d071d646ba5ae9f44
- Related sources:
  - Nummy comparison: `../../../Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md`
  - Tungsten numeric helpers: `../../src/tungsten/expression.py`
  - Tungsten arithmetic dispatch: `../../src/tungsten/expression_arithmetic.py`

## Executive Verdict

The proposal is directionally correct and has the right architectural shape:

- keep today’s exact + machine-float + decimal paths fast and unchanged;
- add a Tungsten-owned `LargeReal` atom as a *provenance-driven retry* after representability loss;
- preserve explicit `Overflow[]` / `Underflow[]` as special atoms with existing semantics;
- make precision/accuracy/display strictly consume a carried “certified digits + residual” contract.

Two things need to be tightened before implementation starts:

1. **Overflow/underflow triggering must be specified at the “Python actually does” level.** In this
   tree’s current Python runtime, `10.0 ** 400` raises `OverflowError` (it does not reliably return
   `inf`). That means `_real_power_expr` needs an exception-safe fallback hook, not only an `isinf`
   post-check.
2. **“Exact large integer” semantics must be defined explicitly.** The proposal calls for a sparse
   exact integer floor (e.g. `10^10000000000 + 2811012357389`). Today’s Tungsten `Integer` atom is a
   Python `int`, so “exact but sparse” needs a concrete representation choice (new atom vs inert
   expression vs large-number payload surfaced through `Floor`).

Everything else can iterate while building tests.

## What Changed in the Reviewed History

This commit range does two things:

1. Nummy: generates several overlapping alpha/beta/gamma comparison reports, then consolidates them
   into a single deduplicated “unified comparison” document while archiving the antecedents.
2. Tungsten: uses the consolidated Nummy conclusions plus a quick `expression.py` seam review to
   propose a kernel-free “large-number fallback” design (`LargeReal` + payloads + precision rules +
   staged implementation plan + test plan).

That “Nummy → synthesis → Tungsten design” narrative is coherent and useful.

## Proposal Review

### Strong Points

- **Correct provenance model.** Treating explicit `Overflow[]` / `Underflow[]` as distinct atoms and
  triggering fallback only when *finite operands* produce overflow/underflow avoids a large class of
  semantic regressions.
- **Good dependency direction.** A Tungsten-facing adapter module (`expression_large_numbers.py`)
  plus a pure dataclass “engine” layer keeps `expression.py` from turning into a numeric monolith.
- **Right “precision contract” stance.** The proposal repeatedly insists that display digits must be
  certified and that `Precision[...]` must reflect the certification data, not string length. That
  matches the strongest part of Nummy alpha’s posture and avoids the common “pretty but wrong” trap
  in huge-number libraries.
- **Correctly identifies the arithmetic choke points.** The proposal points at
  `_inexact_real_result`, `_div_real_expr`, and `_real_power_expr` as the key hooks. That matches the
  actual structure in `expression.py`.
- **Phase ordering is sane.** “Atom + predicates + formatting” before “fallback hooks” before
  “tower/landmark-tail” is a pragmatic way to keep changes testable.

### Issues / Clarifications Needed

#### 1) Machine overflow/underflow behavior must cover `OverflowError` paths explicitly

Current code catches `OverflowError` in `_inexact_real_result` (sum/product), but `_real_power_expr`
does not wrap the `base_float ** power` path in a `try/except`. On this runtime, common inputs like
`10.^400` can therefore raise rather than returning a `SpecialReal`.

Recommendation:

- Make the fallback hook in `_real_power_expr` handle both:
  - “returned `inf`/`0.0`” cases *and*
  - raised `OverflowError` cases
  before returning `special_real("Overflow")` or the new large-number payload.
- Add a regression test that asserts Tungsten does not throw on `10.^400` and `10.^-400` (regardless
  of whether the final behavior is `LargeReal` or gated behind
  `$TungstenLargeNumberFallback -> True`).

#### 2) Underflow detection rules need a crisp “don’t guess wrong” spec

The proposal correctly notes that “underflow is not zero”, and also correctly warns that addition
can legitimately cancel to exact zero.

The missing bit is the concrete rule set per operation. Without that, “underflow fallback” risks
becoming a source of false positives (turning real cancellation into tiny non-zero noise) or false
negatives (quietly returning `0.`).

Recommendation:

- For `Times`, `Divide`, and `Power` over machine reals: treat `0.0` results as underflow only when
  operands are finite and non-zero and a cheap log-magnitude bound proves the exact real result is
  non-zero.
- For `Plus`: either
  - skip machine underflow fallback entirely, or
  - enable it only in extremely constrained cases (e.g., adding two strictly positive operands where
    the smaller operand is non-zero and the float sum is exactly the larger operand).

#### 3) Define the exact representation strategy for sparse exact integers

The proposal wants:

- a `LargeReal` landmark-tail result for the MO tower;
- a `Floor[...]` that returns an exact sparse integer payload without allocating a dense Python
  integer.

This needs a concrete representation choice, because Tungsten’s “exact integer” identity currently
leans on the `Integer` atom being an actual integer value.

Options worth choosing between (in the proposal, up-front):

- **A new `LargeInteger` atom** (integer head + sparse payload + `IntegerQ -> True`).
- **Return a structural integer expression** like `10^10000000000 + 2811012357389` but guarded so
  evaluation never tries to materialize `10^10000000000` into a Python `int`.
- **Reuse `LargeReal` with an “exact integer” payload kind**, then make `IntegerQ` understand it.

I lean toward either “new `LargeInteger`” or “structural expression + guard”, but the document
should commit to one because it affects predicates, JSON schema, and test design.

#### 4) Tighten the “certification” story: alpha/beta lessons are correct, but need an explicit contract type

The proposal’s repeated “digits must be certified” is correct, but implementation will stall unless
there is an explicit internal contract type (“certainty object”) with:

- a relative digit count and/or absolute error bound;
- a residual interval radius bound expressed in a scale-aware way;
- a rule for when formatting is allowed to append digits, truncate, or elide as `...`.

This is compatible with the proposal’s current direction (and aligns with its stated Nummy synthesis
plan); it just needs to be treated as a first-class design artifact, not only a slogan.

## Did the Nummy Prototypes Get Adequately Analyzed?

Yes, for the *level of precision required to justify this Tungsten proposal*.

The unified Nummy comparison correctly draws these conclusions (and, importantly, softens
overclaims from earlier drafts):

- **Alpha** has the best *calculator UX contract* (ordinary expression entry, explicit precision
  markings, and conservative “don’t pretend” output posture).
- **Beta** has the best *perturbation/asymptotic engine shape* and the broadest tests, but its MO
  path is not wired into the normal expression evaluator (it relies on a dedicated helper).
- **Gamma** provides the cleanest minimal landmark+tail vocabulary, but its output/precision story is
  prototype-grade.

I also spot-validated the most load-bearing behavioral claims directly in-tree:

- All three test suites pass as documented (`alpha`: 22 tests, `beta`: 144 tests, `gamma`: 14 tests).
- Alpha and beta compute the same MO suffix and fractional tail prefix.
- Gamma reproduces the MO tail at its default fractional-digit request, and it also exhibits the
  reported `decimal.InvalidOperation` quantization failure when asked for larger fractional-digit
  output at high internal precision — which supports the unified report’s caution around gamma’s
  precision surface.

So: the analysis is “adequate and honest” for making the Tungsten design choice. The main missing
thing is not analysis quality; it’s that Tungsten now needs to *turn those conclusions into a typed
contract* (payload + certainty) so future work cannot regress into accidental overclaiming.
