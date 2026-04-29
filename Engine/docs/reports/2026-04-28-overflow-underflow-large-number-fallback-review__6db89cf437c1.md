# Review: Overflow And Underflow Large-Number Fallback Design

- Status: Independent design review of `src/Tungsten/docs/overflow-underflow-large-number-fallback.md`
- Audience: Vladimir, Tungsten maintainers, Nummy maintainers, future readers comparing the proposal with the implementations
- Scope: the proposal text plus the Nummy alpha/beta/gamma source under `src/Nummy/src/{alpha,beta,gamma}/`, the unified comparison at `src/Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md`, and the relevant Tungsten arithmetic seams in `src/Tungsten/src/tungsten/expression.py`
- Reviewed proposal: [overflow-underflow-large-number-fallback.md](../overflow-underflow-large-number-fallback.md)
- Reviewed unified comparison: [alpha-beta-gamma-unified-comparison.md](../../../Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md)
- Created (UTC): 2026-04-29T00:17:02Z
- Repository HEAD: de64e8978becc8d82170622d071d646ba5ae9f44

## Summary verdict

The proposal is well-shaped and the broad strokes of the Nummy analysis are sound. The four
cornerstone claims — that alpha is the cleanest user-facing baseline, beta is the cleanest
asymptotic engine, gamma is the cleanest result-vocabulary prototype, and that none of them is yet
proof-grade across all surfaces — all hold up under direct source inspection and replay of the
acceptance expression.

That said, the proposal slightly oversells two of the three Nummy implementations as reusable
building blocks. The gamma "landmark + tail" engine is narrower in *behavior* than the proposal
reads — the recognizer is one hard-coded magic shape — even though its *types* are clean and worth
borrowing. The beta engine has a deliberate `K = 5` ceiling and a `K`-input restriction that the
proposal does not call out. Alpha's perturbation propagator, similarly, is hardcoded base-10 with a
small switch table for tower levels 1, 2, 3.

These are all addressable as Phase 4 design constraints rather than blockers, and the proposal's
"reuse Nummy as source material, do not depend on it at runtime" stance already absorbs most of
the risk. But the recommendation section reads as if Tungsten could mostly *port* the three
prototypes' Phase-4 cores; in practice it will need to *re-derive* the perturbation engine and
recognizer, using Nummy mostly as worked-example test data and as a vocabulary cheat sheet.

## What I verified directly

I re-ran the acceptance expression in each Nummy implementation and inspected the relevant
Tungsten code paths.

| Implementation | Command | Result |
| --- | --- | --- |
| alpha | `echo … | python -m nummy repl --no-banner --precision 30` | `10^10000000000 + 2811012357389.44071162781827848` `30` plus correction-precision and omitted-tail report; `Floor[…]` returns the sparse exact integer with `precision: Infinity` and a stability flag |
| beta  | `echo … | python -m nummy` | `10^^2(10.0)` (a clean structural form, not the noisy `10^^2(9.99…)` that the archived reports recorded — see correction below) |
| gamma | `echo … | python gamma_repl.py --no-banner --prec=120` | `10^10^10 + 2811012357389.4407116278` (no precision mark, no zero-run report, no `Floor`) |

I also verified the gamma quantization regression noted in the unified report:
`compute_mo_1010101010_1010(precision=80, frac_digits=20)` raises `decimal.InvalidOperation` at
[pow10_tower.py:256](../../../Nummy/src/gamma/nummy_tower/pow10_tower.py:256) inside
`_format_decimal_fixed`. The tested `precision=120, frac_digits=10` path still succeeds. This is a
real bug in the gamma display layer, not just an API contract gap.

I confirmed that the Tungsten arithmetic seams the proposal names are accurately located:

- `SpecialReal` is the `Overflow[]` / `Underflow[]` atom
  ([expression.py:321](../../src/tungsten/expression.py:321))
- `_machine_real` collapses `math.inf` to `Overflow[]` but passes ordinary `0.0` through unchanged
  ([expression.py:3968](../../src/tungsten/expression.py:3968))
- `_inexact_real_result` catches `OverflowError` from `sum`/`math.prod` and returns
  `Overflow[]`; it has no underflow detection
  ([expression.py:4000](../../src/tungsten/expression.py:4000))
- `_div_real_expr`, `_real_power_expr`, `_add_real_expr`, `_mul_real_expr` are the right
  hook points for the proposed fallback
  ([expression.py:4096](../../src/tungsten/expression.py:4096),
   [expression.py:4132](../../src/tungsten/expression.py:4132),
   [expression.py:4057](../../src/tungsten/expression.py:4057),
   [expression.py:4078](../../src/tungsten/expression.py:4078))

The exact integer power path the proposal flags as a hazard is at
[expression.py:4148](../../src/tungsten/expression.py:4148): `_fraction_expr(base_fraction ** power)`
with no digit-budget guard. A normal Wolfram expression `10^10^10` would route the inner `10^10`
through this path with `power = 10000000000`, allocating a Python integer of ten-billion decimal
digits before any large-number engine has a chance to intervene. The proposal correctly identifies
this.

## What the proposal gets right

### Provenance-based triggering

The decision to tie the fallback to *provenance* (a finite operation overflowed/underflowed) rather
than to operand identity (a `SpecialReal` operand was seen) is the correct design move. It keeps
explicit `Overflow[]` and `Underflow[]` semantics intact for users who depend on them while still
unlocking the certified-fallback path for ordinary expressions. The `LargeFallbackTrigger` enum
formalizes this cleanly.

This also matches what the Nummy work *did not* do. None of alpha, beta, or gamma faces this
question because none of them has a `SpecialReal`-equivalent atom. Tungsten does, and the
proposal's framing protects that surface area.

### Atom split, not atom merge

Adding a new `LargeReal` atom alongside `SpecialReal` rather than retrofitting `SpecialReal` is
the right call. `SpecialReal` is a nullary placeholder; `LargeReal` carries arbitrary payload data
plus certification metadata. Conflating them would either bloat the placeholder semantics or
leak structural data into JSON and parser corpora that currently expect a fixed `{"special":
"Overflow"}` shape. The proposal preserves backward compatibility at every projection layer.

### Layer separation

The dependency direction in the proposed package shape —
`expression_arithmetic.py → expression.py helpers → expression_large_numbers.py → large_numbers/*` —
is the correct shape for keeping `expression.py` from absorbing yet more code. The 19,947-line
`expression.py` is already large; bolting payload classes, perturbation series, and asymptotic
machinery onto it would push it past comfortable maintenance. The "no dependency on Tungsten AST
classes" rule for `large_numbers/*` is the right guard for that.

### Exact-power guard as a separate phase

Phase 3's structural exact-integer threshold belongs to a different code path than the
floating-overflow fallback (Phase 2), and the proposal correctly carves it out. A 10-billion-digit
Python integer is not technically an "overflow"; it is a memory-allocation hazard that the
proposal calls out separately and protects with a configurable threshold.

### Precision contract

The four-quantity model — input / working / certified / display — is the right vocabulary, and the
"display reduces precision rather than printing uncertified digits" default is consistent with
Wolfram's posture and with alpha's existing behavior. The repeated-9 / repeated-0 caveat is a
genuine boundary case worth naming, and the proposal handles it correctly by making the caveat
opt-in for diagnostic contexts.

## Where the Nummy analysis is sound

### Alpha as the calculator-discipline baseline

Confirmed. Alpha's `CalculatorValue` carries an exact `Fraction` for `+`, `-`, `*`, `/`, and integer
powers along with `certified` and `perturbation` state, exactly as the proposal characterizes. The
ordinary-expression path through `parse_power → power → from_fraction or from_tower` does what
the proposal describes. The "uncertified structural output → precision `0`" rule is real
([calculator.py:421-422](../../../Nummy/src/alpha/nummy/calculator.py:421)).

The sparse exact integer `Floor[…]` result for the MathOverflow expression is the strongest single
piece of behavior in any of the three implementations and is a good template for Tungsten's
sparse-decimal-integer payload.

### Beta as the asymptotic-engine baseline

Confirmed. `PerturbationSeries` plus `exp_of_series` plus `pow10_of_series` is the cleanest
truncated-series machinery in the three trees, and `AsymptoticTowerValue.apply_pow10` is the
clearest worked-out propagator for `f_{k+1}(x) = 10^f_k(x)` near `x = 0`. The
`Decomposition.residual_log10` field is the right place to read the omitted-tail bound from, and
it is the closest thing to a proof-grade error budget in any of the three Nummy implementations.

The proposal's recommendation to fold this engine into `large_numbers/perturbation.py` is correct.

### Gamma as the result-vocabulary baseline

Half-confirmed. `Pow10Tower`, `ExponentSum`, `Pow10Factor`, `TowerLandmarkDecimal`, and
`TowerDecimalDescription` are an unusually crisp set of types for "landmark plus tail plus zero
run". They are worth borrowing as the public vocabulary for Tungsten's payloads.

But — see the caveats below — the **runtime** that consumes those types in gamma is much narrower
than the proposal's "use gamma's landmark-tail vocabulary for payload design" might suggest.

### Settings shape

Tying `$TungstenLargeNumberFallback`, `$TungstenLargeNumberDisplayPrecision`, etc., to the existing
session-runtime machinery (the same place `$Line` and history live) is consistent with how
Tungsten currently handles mutable evaluator state.

## Concerns and corrections

### Gamma's perturbation engine is one hard-coded shape, not a parameterized recognizer

The unified comparison says gamma "directly demonstrates the MathOverflow behavior in a small
codebase" and that gamma's REPL "recognizes the exact MO tower shape while building structural
base-10 towers." Both true. What is *understated* is how literal that recognizer is.
[gamma_repl.py:230](../../../Nummy/src/gamma/gamma_repl.py:230) reads:

```python
if next_t.height == 5 and _is_effectively_integer(next_t.top) and int(next_t.top) == -(10**10):
    mo = compute_pow10_tower_small_bottom_linear(
        height=5,
        bottom_exponent=-(10**10),
        precision=prec,
        max_tower_int_digits=64,
    )
    return GammaValue.from_landmark(mo)
```

That is not a structural pattern matcher. It is a **literal magic-number shape match**: only
height exactly 5, only top exactly `-10^10`. Any nearby variant — height 6, height 4, top
`-10^11`, top `-10^9`, top `-(2*10^10)` — falls out of the path even though the underlying
`compute_pow10_tower_small_bottom_linear` would happily handle it.

Tungsten's "Recognize the base-10 tower form during `Power` evaluation" step (Phase 4 step 3 of
the proposal) cannot be modeled on this. The recognizer in the Tungsten engine has to be a real
recognizer for the tower-near-landmark family, parameterized over `(height, base, bottom
magnitude)`. The proposal already says "the recognizer should be mathematical rather than
text-based"; I would suggest strengthening this to "the recognizer must not be a single shape
match; it must accept a parameterized family covering at least the same height and bottom
magnitude variations the perturbation engine itself can solve."

### Alpha's perturbation propagator is also base-10-only and hardcoded for tower heights 0-3

Alpha's `TowerPerturbationState.anchor_tower`
([calculator.py:77-90](../../../Nummy/src/alpha/nummy/calculator.py:77)) returns the anchor for
each tower level via a switch table:

```python
if self.levels == 1:
    return TowerReal.from_int(1).with_flags(INEXACT)
if self.levels == 2:
    return TowerReal.from_int(10).with_flags(INEXACT)
if self.levels == 3:
    return TowerReal.from_int(10_000_000_000).with_flags(INEXACT)
return TowerReal.from_layer(self.levels - 3, 10_000_000_000).with_flags(INEXACT)
```

These are `f_k(0)` for `f_{k+1}(x) = 10^f_k(x)` starting from `f_0 = 0`, but they are inlined as
literals rather than computed from a recurrence. `power` advancement
([calculator.py:244-251](../../../Nummy/src/alpha/nummy/calculator.py:244)) is also
base-10-gated: it advances perturbation state only when `self.exact_fraction == Fraction(10, 1)`.

This is fine as a calculator surface and good source material for Tungsten, but the proposal's
"port the Nummy-derived structural tower and landmark-tail payloads" should be read with the
understanding that there is essentially no general structural-tower routing in alpha to lift —
only a base-10 specialization.

### Beta's `apply_pow10` deliberately stops at the deferred-scale boundary

Beta's [`apply_pow10`](../../../Nummy/src/beta/nummy/asymptotic.py:127) raises
`NotImplementedError` whenever `value.scale_layer != 0`, with a comment explaining that the MO
problem terminates at level 5 without needing the deferred-scale propagator. Beta's
`compute_mo_expression` enforces `num_levels <= 5`
([mo.py:69-74](../../../Nummy/src/beta/nummy/mo.py:69)).

That is a deliberate scope cut, not a bug. But Tungsten's Phase 4 says "Make ordinary `Power`
syntax route to this path without user-visible helpers," which implies a *general* tower
fallback, not a `K = 5` one. If Tungsten ports the beta engine as-is, then expressions of the
form `10^^6(small)` or `10^^7(small)` will crash through `_propagate_deferred` instead of
producing a `LargeReal`. The proposal should probably either:

1. Note explicitly that the first Tungsten implementation will inherit beta's `K = 5` ceiling and
   fall back to `Overflow[]` (or a structural-only `LargeReal`) for taller towers; or
2. Plan to design and implement the deferred-scale propagation that beta intentionally skipped.

The Open Decisions section is the natural place to add this.

### Beta's REPL `^` already refuses what the Tungsten fallback wants to handle

[`beta/nummy/calc.py:590-595`](../../../Nummy/src/beta/nummy/calc.py:590) raises
`CalcEvaluationError` for `^` whenever `|exponent| > 10^15`. Beta's REPL does not even attempt
`10^(10^16)`; it tells the user to call `nummy.compute_mo_expression`. The fact that beta's
`LeadingDigits[k, n]` is "the only way" to reach the asymptotic core is therefore an *intentional*
design choice in the calc layer, not just a coincidence of evolution.

The proposal already acknowledges that "ordinary expression evaluation does not currently route
the MO expression to the asymptotic engine" in beta. I would phrase this more strongly: beta's
calc layer was *designed* to refuse the high-magnitude expressions Tungsten wants to handle, so
"adapt beta's perturbation/residual machinery into `large_numbers/perturbation.py`" is correct,
but Tungsten should consciously *not* port beta's calc layer's exponent gate. Making the engine
reusable will require splitting it from those calc-layer guard rails — the engine itself
(`asymptotic.py`, `series.py`, `leading_digits.py`) does not depend on the gate.

### Single-workload validation for all three Nummy implementations

All three implementations validate against exactly one acceptance target: `10^^5(-10^10)`. Beta's
own MO test (`compute_mo_expression`) and gamma's `test_mo_tail_prefix_and_zeros` both check the
same hardcoded expression with the same hardcoded tail prefix. Alpha's calculator tests cover
parser/REPL behavior more broadly but the perturbation path is exercised on the same single
expression.

The unified report acknowledges this once ("Nummy currently has one dominant showcase workload").
The proposal inherits that risk silently. None of the Nummy implementations gives evidence about
whether the architecture scales across patterns — different bases, different inner functions,
different landmark structures, near-landmark *negative* perturbations rather than positive,
asymmetric tower heights, mixed `^` and `*` chains.

I would suggest the proposal explicitly call out "single-workload provenance" in **Risks And
Mitigations**, with mitigations along the lines of:

- Add a small Tungsten-owned synthetic workload set covering at least different bases and
  different `K`s before claiming Phase 4 is "done";
- Treat any extension beyond `K = 5` and base 10 as a real research item rather than a port.

### Gamma's `decimal.InvalidOperation` bug

The unified report notes this; the proposal does not. Since Tungsten plans to "use gamma's
landmark-tail vocabulary for payload design" (Nummy Reuse Strategy), it is worth being explicit
that this means **vocabulary, not implementation**. If Tungsten copies the
`TowerDecimalDescription._format_decimal_fixed` quantize logic verbatim, it inherits the bug. The
fix is straightforward — clamp `frac_digits` to the active `Decimal` context's precision before
calling `quantize` — but it is not currently in any of the prototypes.

### Empirical correction to the unified comparison

The unified comparison records beta's normal-expression output as
`10^^2(9.9999999999999999999999999999999999999997386424354)`. With the current beta tree at
HEAD `de64e8978`, the same expression at session precision 16 evaluates to
`mpf("1.0e10000000000")` and `format_value` displays it as `10^^2(10.0)`. The cleaner output is
not a regression — beta still does not recover the tail through ordinary `^` evaluation — but the
displayed mantissa is now the clean `10.0` rather than the noisy `9.999…` previously recorded. If
the proposal quotes the unified comparison's `10^^2(9.99…)` shape as a stable fact, that quote
will need a small refresh.

This empirical drift also illustrates a more general point: the precise displayed form of any
mpmath-backed result is sensitive to small changes in working precision, evaluator order, and
mpmath's own internal rounding. Tungsten's `LargeReal` formatter must consume *certified* digit
counts as data, not be inferred from the underlying engine's `nstr`-style representation. The
proposal's Display Contract section already says this; it is worth keeping in mind during
implementation.

### Settings naming inconsistency (minor)

The proposal lists four candidate session settings:

- `$TungstenLargeNumberFallback`
- `$TungstenLargeNumberDisplayPrecision`
- `$TungstenLargeNumberMaxGuardDigits`
- `$TungstenMaxExactIntegerDigits`

The fourth lacks the `LargeNumber` infix that the first three carry. Either it is intentionally
broader (it gates the exact-integer power guard which is conceptually adjacent but not part of
the large-number fallback proper), or it should be renamed
`$TungstenLargeNumberMaxExactIntegerDigits` for consistency. The Open Decisions section is the
natural place to resolve this.

### JSON schema example

The example payload's landmark exponent `10000000000` is consistent with the MO expression
(`10^(10^10)`) and the alpha REPL output. The schema field naming
(`landmark.kind = "pow10"`, `landmark.exponent.kind = "integer"`, `tail.midpoint`,
`tail.radius_exp10`) is internally consistent. One small wording note: `radius_exp10: -31` for
a `midpoint` with 14 mantissa digits implicitly claims the midpoint is correct to about
`10^-31` of relative magnitude. That is a stronger claim than the alpha REPL prints
(`correction precision: 30`, omitted-tail bound `10^-9999999970`), and the example should
probably say so explicitly so future readers do not over-interpret the schema as encoding raw
correctness.

## Specific suggestions for the proposal

1. In **Fallback Triggering / Power**, explicitly note that the Phase 4 perturbation engine will
   initially inherit beta's `K = 5` ceiling, with a documented Open Decision about extending into
   the deferred-scale regime.

2. In **Nummy Reuse Strategy**, replace the unqualified "use gamma's landmark-tail vocabulary for
   payload design" with "use gamma's landmark-tail *types* for payload design, but do not port
   gamma's MO recognizer (which is a single literal shape match) or `_format_decimal_fixed`
   (which has a precision-budgeting bug at small `precision` / large `frac_digits`)."

3. In **Risks And Mitigations**, add a row for "Single-workload Nummy validation" with the
   mitigation that Tungsten add a parameterized acceptance corpus covering different `K`,
   different bases, and different perturbation signs before declaring the engine general.

4. In **Open Decisions**, add the `K`-ceiling decision and the
   `$TungstenMaxExactIntegerDigits` naming question.

5. In **Test Plan / MathOverflow tests**, add a test that varies `(K, base, bottom magnitude)` so
   the engine cannot be implemented as another single literal shape match — even by accident
   during rapid iteration.

6. Consider adding a one-line note to the **Display Contract** that the certified-precision data
   should drive the formatter, with a worked counter-example showing what would go wrong if the
   formatter inferred precision from the rendered mpf string.

## Bottom line

Yes, the Nummy alpha/beta/gamma prototypes were adequately analyzed for the purpose this proposal
puts them to: choosing what to learn from each. The proposal correctly identifies the calculator
discipline of alpha, the asymptotic core of beta, and the result vocabulary of gamma, and it
correctly chooses to keep the Tungsten engine independent of all three at runtime.

The conclusions drawn from that analysis are mostly correct, with three real refinements:

- The proposal slightly understates how *narrow* gamma's runtime is (single literal pattern), how
  *base-10-specific* alpha's perturbation propagator is (hardcoded anchors), and how *bounded*
  beta's engine is (`K ≤ 5`, deferred-scale unimplemented).
- The proposal inherits the single-workload risk that all three Nummy implementations share, and
  should name it explicitly in the risks table.
- The proposal can borrow gamma's *vocabulary* but must rewrite gamma's *implementation*; one
  small but real bug (`decimal.InvalidOperation` in `_format_decimal_fixed`) should not survive
  the port.

None of these is a blocker for going ahead with the design. Phases 1–3 are well-targeted and can
proceed against the existing Tungsten arithmetic seams. Phase 4 will be more research-heavy than
the "port from Nummy" framing implies, but the architectural decisions (separate `LargeReal` atom,
provenance-based triggering, certified-precision data on the payload, layered package shape) are
all sound.
