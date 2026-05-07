---
title: "Nummy Design Proposal"
subtitle: "An overflow-resistant engine for range-first arbitrary-precision floating-point arithmetic"
author: "Prepared for the Nummy project"
date: "April 28, 2026"
---

# Contents {.unnumbered}

- [Summary](#summary)
- [Design goals](#design-goals)
- [Lessons from the attached archive](#lessons-from-the-attached-archive)
- [External numeric context](#external-numeric-context)
- [Proposed architecture](#proposed-architecture)
- [Numeric model](#numeric-model)
- [Context and policy](#context-and-policy)
- [Data structures](#data-structures)
- [Normalization](#normalization)
- [Arithmetic algorithms](#arithmetic-algorithms)
- [Uncertainty and precision model](#uncertainty-and-precision-model)
- [Structural provenance and scale algebra](#structural-provenance-and-scale-algebra)
- [Formatting and parsing](#formatting-and-parsing)
- [Public API sketch](#public-api-sketch)
- [Implementation plan](#implementation-plan)
- [Testing strategy](#testing-strategy)
- [Performance considerations](#performance-considerations)
- [Documentation requirements](#documentation-requirements)
- [Licensing and source-use policy](#licensing-and-source-use-policy)
- [Risks and mitigations](#risks-and-mitigations)
- [Example user stories](#example-user-stories)
- [Recommended minimum viable product](#recommended-minimum-viable-product)
- [Open design questions](#open-design-questions)
- [Source material reviewed from the archive](#source-material-reviewed-from-the-archive)
- [Public references consulted](#public-references-consulted)

# Summary

Nummy should be a range-first real-number engine, not a conventional arbitrary-precision decimal with a larger exponent. Its purpose is to keep computations meaningful when ordinary machine floats, MPFR-style arbitrary-precision floats, or CAS numeric towers can no longer represent the scale, can no longer distinguish the operands, or have lost the precision needed to justify a decimal-looking answer.

The proposed core is a symmetric level-index (SLI) representation with explicit sign, reciprocal state, level, index, and coordinate uncertainty. Around that core, Nummy should provide a practical power-tower notation layer, an ordinary-number fast path, a structural expression/provenance layer, and CAS/Python adapters. The important architectural choice is to keep these concerns separate:

- The arithmetic core stores values on an iterated-logarithm scale.
- The precision model tracks uncertainty in that scale, not merely decimal digits.
- The notation layer renders values honestly without pretending to know digits that are no longer represented.
- The adapter layer lets Mathematica, Maple, Sage, Python, and future clients enter and leave Nummy without silent coercions.

This proposal recommends using SLI as the numeric model and borrowing ergonomics, parsing, and display ideas from the power-tower lineage represented in Hypercalc, break_eternity.js, and OmegaNum.js. The archive's GSLI and MATLAB level-index simulator should be treated as the strongest implementation references for the numerical core. The game/googology libraries should be treated as references for normalization, parsing, formatting, and high-level operator convenience, not as the mathematical contract.

# Design goals

## Primary goals

Nummy should satisfy the following design goals.

1. **Avoid overflow and underflow by construction.** A value should not become `inf`, `0`, `Overflow[]`, or `Underflow[]` merely because its magnitude exceeds a hardware or MPFR exponent range. Nummy may still expose mathematical infinities, invalid operations, exhausted precision, or representational limits, but those states must be explicit and distinguishable.

2. **Represent huge and tiny magnitudes symmetrically.** A value like `exp(exp(1000))` and its reciprocal should be equally natural. This requires a first-class reciprocal bit or equivalent canonical representation, not merely a sign on an exponent.

3. **Separate range from precision.** Increasing Nummy's index precision should refine a value's coordinate on the level-index scale. It should not be advertised as preserving ordinary relative precision at arbitrary levels.

4. **Make dominance and cancellation observable.** When `x + y` returns `x` because `y` is below the current resolvable scale, the result should be marked as a certified dominance result. When `x - y` suffers cancellation that cannot be resolved from the stored information, Nummy should return an uncertain result, a symbolic/deferred result, or an explicit failure according to context policy. It must not silently invent ordinary digits.

5. **Keep ordinary numerical work excellent.** For normal-sized inputs, Nummy should behave like a high-quality arbitrary-precision floating type, with predictable rounding, good performance, and exact/special-case preservation where feasible.

6. **Provide useful scale algebra.** Operations such as `log(exp(x))`, `exp(log(x))`, `pow(exp(a), b)`, products of exponentials, and power-tower manipulations should exploit structure rather than immediately losing information in a numeric approximation.

7. **Integrate cleanly with CAS and Python ecosystems.** The engine should be useful from Python first, then from Sage directly, and later through Mathematica/Maple bridges. It should interoperate with exact integers, rationals, MPFR/mpmath values, decimal strings, and symbolic expression handles.

## Non-goals

Nummy should not promise the following.

- It should not be a replacement for exact integer, rational, modular, or algebraic computation.
- It should not claim to know the leading decimal digits of values whose high-level representation no longer supports that claim.
- It should not make modulo, primality, exact divisibility, or exact comparisons of unrelated symbolic expressions magically possible at googological scale.
- It should not silently coerce exact values into an approximate scale representation without a context policy or user-visible indication.
- It should not copy GPL code from GSLI into a differently licensed Nummy implementation. GSLI is a reference for behavior and algorithms unless Nummy's licensing deliberately becomes GPL-compatible.

# Lessons from the attached archive

The archive splits naturally into three bodies of material: CAS failure analysis, SLI theory, and prototype implementations. The proposal below uses all three.

## CAS failure modes

The CAS report in `docs/reports/cas-floating-point-shortcomings__288318099677.md` makes the right negative case for Nummy. Mathematica, Maple, and Sage have rich numeric systems, but their arbitrary-precision facilities are still mostly mantissa-first floating-point systems. They can track digits, use guard precision, expose intervals, or switch between exact and approximate forms, yet they do not provide a native scale algebra for values whose magnitude is itself beyond practical exponent handling.

The design implication is not "replace CAS arithmetic." It is "add a separate numeric regime." Nummy should keep exact, conventional floating-point, arbitrary-precision floating-point, interval/ball, symbolic, and SLI-like values semantically distinct. A user should be able to audit how and why a result entered Nummy's range-first regime.

## SLI theory

The theory material, especially `docs/theory/symmetric-level-index-arithmetic-introduction__316e449481ec.md`, is the conceptual center. The core idea is to represent a magnitude by repeatedly applying logarithms until it lies in a manageable base interval. The inverse operation reconstructs the value by iterated exponentiation. The symmetric extension stores small magnitudes through their reciprocals so that tiny and huge values are handled by the same magnitude coordinate.

The key warning from the same material is that SLI is not "bigger floating point." It preserves information in the generalized-log coordinate. Ordinary relative precision necessarily degrades at high levels. This must be part of Nummy's contract, API, documentation, and formatting.

## Prototype lineage

The archive's prototype overview identifies two related but distinct lineages.

| Prototype family | Main contribution to Nummy | How Nummy should use it |
|---|---|---|
| GSLI | Direct generalized SLI representation and optimized operations. | Treat as the strongest SLI implementation reference, especially for normalization, special values, comparisons, `nextabove`, `float_distance`, and operation case splits. |
| MATLAB level-index simulator | Explicit sign, reciprocal, level, index, custom precision, and Clenshaw/Turner-style addition/subtraction algorithms. | Use as a readable research harness and test inspiration. Its exposed bit allocation is valuable for format experiments. |
| Hypercalc and `hypernums.py` | Practical power-tower representation and notation, with promotion/demotion intuition. | Borrow parser/formatter ideas and some scale-display conventions. Keep separate from the SLI core. |
| break_infinity.js | Fast decimal scientific notation beyond ordinary double range. | Use as inspiration for the ordinary extended-decimal fast path and API ergonomics. |
| break_eternity.js | Polished `sign/layer/mag` tower representation, normalization, tetration/slog helpers, and reciprocal behavior through negative magnitude. | Borrow notation, parsing, and high-level API shapes. Do not adopt its layer/magnitude heuristic as Nummy's numerical contract. |
| OmegaNum.js | Hyperoperation-array representation beyond fixed tower heights. | Treat as an upper-bound exploration and possible future extension, not the first Nummy core. |

The practical synthesis is: **Nummy should be SLI in the kernel and power-tower-friendly at the boundary.**

# External numeric context

Public documentation for current systems supports the same design pressure. Wolfram Language arbitrary-precision numbers track precision through calculations and can return fewer digits when less can be justified; Wolfram also exposes system-level maximum and minimum magnitudes for arbitrary-precision numbers and a distinct `Overflow[]` object for numbers too large to represent explicitly. Maple's software floats are controlled by the `Digits` environment variable, and `evalf[n]` changes significant-digit precision but still operates as floating-point evaluation. Sage's `RealField` is an MPFR-backed arbitrary-precision field with specified precision and rounding mode; MPFR itself has precise semantics, configurable precision, rounding modes, and finite exponent limits. These systems are strong, but their core abstraction remains floating-point approximation, not iterated-log scale algebra.

Nummy should therefore present itself as a complement to these systems. Its success criterion is not "more correct decimal digits than MPFR." It is "a meaningful, auditable result when a mantissa/exponent representation is no longer the right representation."

# Proposed architecture

Nummy should be organized as a layered engine.

```text
+--------------------------------------------------------------+
| Public APIs: Python, Sage, CLI, future Mathematica/Maple      |
+--------------------------------------------------------------+
| Formatting/parsing: decimal, scientific, tower, SLI, JSON     |
+--------------------------------------------------------------+
| Context and policy: precision, rounding, dominance, errors    |
+--------------------------------------------------------------+
| Operation dispatcher and structural simplifier                |
+--------------------------------------------------------------+
| Numeric regimes: ordinary MPFR, extended decimal, SLI core    |
+--------------------------------------------------------------+
| Data model: value state, sign, reciprocal, level, index, ball |
+--------------------------------------------------------------+
```

The implementation should start Python-first for clarity and Sage compatibility, with a native Rust or C++ core later if profiling justifies it. The public API should be designed so that the core can be swapped without changing semantics.

## Core design decision

The core type should be an SLI real, not a tower-number type.

A tower-number core is tempting because `sign/layer/mag` APIs are approachable and parse strings like `ee100` nicely. But tower libraries optimize for calculator/game behavior and often use dominance heuristics without a formal precision contract. Nummy's stated purpose is numerical resilience in the presence of overflow, underflow, and precision loss. That requires an explicit numeric model, explicit reciprocal symmetry, and an explicit uncertainty contract.

Tower notation should be a view over the SLI core. It should not be the core.

# Numeric model

## Mathematical reference model

For explanation and documentation, Nummy can use the classical level-index functions.

```text
phi(y) = y                       for 0 <= y < 1
phi(y) = exp(phi(y - 1))          for y >= 1

psi(x) = x                       for 0 <= x < 1
psi(x) = 1 + psi(log(x))          for x >= 1
```

Here `psi` maps a nonnegative magnitude to a generalized-log coordinate, and `phi` maps the coordinate back to a magnitude. The integer part of the coordinate is the level; the fractional part is the index.

For production arithmetic, Nummy should use a generalized SLI form rather than this toy interval directly. GSLI shows why: it is valuable to preserve a high-quality ordinary-number level and choose index ranges so that operation case splits are numerically stable. The documentation can teach the simple `phi/psi` model, while the implementation uses configurable thresholds and normalization windows.

## Finite real value representation

A finite nonzero real should be represented as:

```text
x = sign * mag
mag = Phi(level, index)        if reciprocal == false
mag = 1 / Phi(level, index)    if reciprocal == true
```

where:

- `sign` is `+1` or `-1`.
- `reciprocal` says whether the actual magnitude is represented directly or as the reciprocal of the stored magnitude.
- `level` is a nonnegative integer. It should be a Python `int` or arbitrary-sized native integer in the reference implementation.
- `index` is an arbitrary-precision binary floating value, preferably MPFR-backed, with a context-selected precision.
- `Phi` is the implementation's generalized level-index exponential map.

Zero is a special state, not `reciprocal=true` with infinite level. Nummy may preserve signed zero for compatibility, but signed zero must never be confused with underflow.

## Value states

Nummy should distinguish at least these states.

| State | Meaning | Notes |
|---|---|---|
| `Finite` | A represented real value with sign, reciprocal state, level, index, and uncertainty. | The normal case. |
| `Zero(+/-)` | Exact zero, optionally signed. | Not an underflow artifact. |
| `PosInfinity` / `NegInfinity` | Mathematical or declared infinity. | Distinct from overflow. |
| `NaN` | Invalid or undefined result with payload. | Payload records operation and operands when possible. |
| `OverflowedExternal` | A value imported from an external system that reported overflow. | May have provenance but no magnitude coordinate. |
| `UnderflowedExternal` | A value imported from an external system that reported underflow. | Distinct from zero. |
| `Indeterminate` | A mathematically indeterminate form such as `inf - inf`. | Distinct from NaN caused by invalid input. |
| `Unresolved` | A result cannot be certified under the current context. | Used for exact modulo, unknown cancellation, etc. |

This distinction is important. For example, a CAS `Overflow[]` is not mathematical infinity; it is an operational state. Nummy should preserve that distinction when importing results and when reporting its own failures.

## Regimes inside `Finite`

The public `NummyReal` object can be a tagged union whose finite branch has several internal regimes. The user should mostly see one type.

| Regime | Intended range | Representation | Purpose |
|---|---|---|---|
| `SmallExact` | Small integers/rationals and exact constants under budget. | Exact Python/Sage object or expression node. | Preserve exactness and avoid avoidable cancellation. |
| `OrdinaryFloat` | Values inside a configured MPFR-safe window. | MPFR/Decimal with precision and rounding mode. | Good ordinary arithmetic. |
| `ExtendedDecimal` | Scientific notation with unbounded integer exponent. | Sign, mantissa, arbitrary integer exponent. | Fast one-log gateway and human decimal I/O. |
| `SLI` | Huge/tiny values beyond ordinary exponent handling. | Sign, reciprocal, level, index, uncertainty. | The core overflow-resistant regime. |
| `StructuredScale` | Values produced by recognizable exp/log/pow/tower forms. | Expression DAG plus approximate SLI coordinate. | Prevent avoidable loss and support simplification. |
| `OpaqueHighLevel` | Values at levels too high for exact operation algorithms. | Coarse coordinate plus certified dominance rules. | Keep the engine functional for extreme tower/hyperoperation values. |

A key implementation point: `ExtendedDecimal` is an optimization and parsing convenience, not a separate semantics. It should normalize into `OrdinaryFloat` or `SLI` as needed.

# Context and policy

Every operation should run under a `Context`. A context is not just a precision integer; it is the semantic contract for uncertain arithmetic.

Suggested fields:

```python
Context(
    index_bits=256,
    guard_bits=64,
    max_algorithmic_level=64,
    rounding="nearest_even",
    dominance="certify",          # certify | fast | never
    cancellation="defer",         # defer | interval | raise | fast
    exact_provenance=True,
    max_provenance_nodes=4096,
    display_base=10,
    display_digits=12,
    special_values="preserve",     # preserve | ieee | strict
    coercion="explicit",           # explicit | permissive | strict
)
```

The defaults should favor correctness and auditability over raw speed. A separate `FastContext` can be provided for game-like workloads where dominance shortcuts are expected.

## Precision fields

`index_bits` controls the precision of the SLI coordinate. `guard_bits` controls internal temporary precision. Ordinary-number operations should use at least `index_bits + guard_bits` where feasible before rounding back to the target context.

## Dominance policy

When adding `x + y` with `|x| >= |y|`, Nummy may return `x` only if it can certify that `y` is below half a representable unit in the chosen result coordinate or below a context-selected tolerance. The result should carry a flag such as:

```text
flags = {DominatedAddend, ExactWithinCoordinate, LostOrdinaryDigits}
```

The flag is not a failure. It is useful information.

## Cancellation policy

When subtracting nearly equal values, Nummy should try, in order:

1. Exact identity or shared-provenance simplification.
2. Re-evaluation at higher guard precision, if operands have enough provenance.
3. Interval/ball enclosure in SLI coordinate.
4. Explicit `UnresolvedCancellation` if no reliable result can be produced under the policy.
5. A fast-context approximate result only when the user opted into it.

The worst possible behavior is a nice-looking decimal or SLI coordinate with no indication that the value is essentially unknown.

# Data structures

A reference Python implementation can use dataclasses and MPFR via `gmpy2` or a compatible backend.

```python
@dataclass(frozen=True)
class NummyReal:
    tag: ValueTag
    finite: FinitePayload | None
    payload: SpecialPayload | None

@dataclass(frozen=True)
class FinitePayload:
    sign: int                    # +1 or -1
    magnitude: Magnitude
    uncertainty: Uncertainty
    provenance: Provenance | None
    flags: frozenset[ResultFlag]

@dataclass(frozen=True)
class Magnitude:
    reciprocal: bool
    coord: LevelIndex

@dataclass(frozen=True)
class LevelIndex:
    level: int
    index: MpfrLike
    format_id: str               # canonical, generalized-v1, etc.

@dataclass(frozen=True)
class Uncertainty:
    radius_li: MpfrLike          # radius in level-index coordinate
    radius_log: MpfrLike | None  # optional absolute log radius
    kind: str                    # exact, rounded, interval, unknown
```

The native core can pack common cases more tightly later. The reference representation should be explicit, inspectable, and easy to test.

## Invariants

All constructors and operations must maintain these invariants.

1. `Finite` values are normalized.
2. Zero is never represented as a reciprocal/level/index pseudo-value.
3. `level >= 0` for stored magnitudes.
4. `index` is finite and lies inside the canonical interval for its `format_id`.
5. If `reciprocal == true`, the represented magnitude is less than or equal to one except for canonical tie cases around one.
6. The uncertainty radius is nonnegative and rounded outward.
7. A result with unknown precision must carry an uncertainty state or be `Unresolved`; it must not masquerade as a precise finite value.
8. Display routines may not print more ordinary decimal significance than justified by the representation and context.

# Normalization

Normalization is the heart of Nummy. It keeps equivalent values from proliferating and makes comparisons cheap.

## Ordinary-to-SLI normalization

For a positive ordinary magnitude `m`, normalization should do this conceptually:

```text
if m == 0:
    return Zero
if m < 1:
    return reciprocal(normalize_positive(1/m))
return normalize_positive(m)
```

`normalize_positive(m)` repeatedly applies the generalized logarithm until the value fits the index interval for its level. For the simple explanatory model:

```python
def psi_simple(m):
    level = 0
    u = m
    while u >= 1:
        u = log(u)
        level += 1
    return LevelIndex(level, u)
```

A production generalized SLI implementation should not literally use `[0, 1)` for every level. It should use an ordinary level-0 window large enough to preserve normal MPFR arithmetic and upper-level windows chosen to make addition/multiplication case splits stable.

## SLI-to-ordinary demotion

Nummy should demote a value to ordinary MPFR when it can be represented inside the context's ordinary window without loss beyond normal rounding. Demotion should happen for results near 1, for cancellation results that fall back to ordinary scale, and for APIs requesting ordinary output.

Demotion must be policy-controlled. Calling `to_float()` on a huge value should not quietly return `inf`; it should raise, return a special, or require an explicit `overflow="inf"` argument.

## Reciprocal flip-over

Addition/subtraction and multiplication/division can produce results that cross the boundary between ordinary and reciprocal forms. Nummy should treat this as a normal normalization event.

Example:

```text
(1 / A) + (1 / A) = 2 / A
```

If `A` is enormous, the result remains reciprocal. But:

```text
(1 / A) + (A - A + 1)
```

may cross back to ordinary scale depending on provenance and cancellation. The reciprocal bit must be updated by normalization, not patched ad hoc by individual operations.

# Arithmetic algorithms

## Comparison

Comparison is mostly structural.

1. Handle special states.
2. Compare signs.
3. Compare zero against finite values.
4. For same sign, compare reciprocal flags.
5. Compare levels and indexes, reversing the order for reciprocal magnitudes.
6. If uncertainties overlap, return a three-valued or policy-controlled comparison result.

The public API should expose both ordinary boolean comparisons and audited comparisons.

```python
x < y                    # bool under default policy, may raise if uncertain
x.compare(y)             # returns Comparison(lt/eq/gt/unknown, certificate)
x.total_order_key()      # deterministic ordering for containers, includes specials
```

## Negation, absolute value, reciprocal

These operations are trivial and should not change coordinate precision.

- `neg(x)` flips sign.
- `abs(x)` clears sign.
- `recip(x)` flips reciprocal for nonzero finite values, with zero/infinity handled by special-value policy.

## Logarithm

For positive finite values:

```text
log(x) = log(Phi(level, index))      if reciprocal == false
log(x) = -log(Phi(level, index))     if reciprocal == true
```

At high levels, `log` usually decrements the level. Near boundaries, it may demote to ordinary MPFR. For structured values, `log(exp(a))` should return `a` exactly or with inherited uncertainty before falling back to coordinate arithmetic.

`log_abs(x)` should be a primitive because it is needed for multiplication, division, powers, comparisons of magnitudes, and formatting.

## Exponential

`exp(x)` is the inverse of `log` for finite real `x`.

- If `x` is ordinary and small enough, compute with MPFR.
- If `x` is positive and large, increment level structurally.
- If `x` is negative and large in magnitude, produce a reciprocal value.
- If `x` has a structured inverse such as `log(y)`, simplify.

This operation is where Nummy should most visibly outperform conventional arbitrary-precision floats: `exp(exp(10**100))` should be a compact finite value, not an overflow.

## Multiplication and division

There are two complementary implementations.

The conceptual implementation is:

```text
x * y = sign(x)*sign(y) * exp(log_abs(x) + log_abs(y))
x / y = sign(x)*sign(y) * exp(log_abs(x) - log_abs(y))
```

This is simple and good for the reference implementation, especially if `log_abs` and `exp` are robust.

The optimized implementation should use direct SLI multiplication/division algorithms inspired by GSLI and the MATLAB simulator. The reason is performance and boundary accuracy: direct algorithms can avoid unnecessary conversions and can handle reciprocal flips more locally.

Special cases must be exact where possible:

- `x * 0 = 0` for finite `x`.
- `x * 1 = x`.
- `x / x = 1` if identity/provenance proves equality.
- `x * recip(x) = 1` if identity/provenance proves equality.
- Infinity and NaN handling follows context special-value policy.

## Addition and subtraction

Addition/subtraction are the hard operations. Nummy should make their difficulty explicit and design around it.

For same-sign addition with `|x| >= |y|`, the basic log-domain identity is:

```text
log(|x| + |y|) = log(|x|) + log(1 + exp(log(|y|) - log(|x|)))
```

For same-sign subtraction or opposite-sign addition:

```text
log(|x| - |y|) = log(|x|) + log(1 - exp(log(|y|) - log(|x|)))
```

These formulas are stable when the log difference is not too close to zero. They also expose the two principal cases:

- If `log(|y|) - log(|x|)` is very negative, `y` is dominated and the result is `x` with a dominance certificate.
- If it is close to zero and signs oppose, the result is cancellation-sensitive and may need provenance, more precision, or an uncertain result.

A reference algorithm should be:

```python
def add(x, y, ctx):
    x, y = coerce_pair(x, y, ctx)
    if is_special_or_zero(x, y):
        return add_special(x, y, ctx)

    if abs_compare(x, y) < 0:
        x, y = y, x

    if signs_equal(x, y):
        return add_same_sign_dominant(x, y, ctx)
    else:
        return sub_magnitudes_dominant(x, y, ctx)
```

For `add_same_sign_dominant`:

```python
def add_same_sign_dominant(x, y, ctx):
    delta = log_abs(y) - log_abs(x)
    cert = dominance_certificate(delta, x, ctx)
    if cert.is_dominated:
        return with_flag(x, DominatedAddend, cert)
    correction = log1p(exp(delta))
    return with_sign(sign(x), exp(log_abs(x) + correction))
```

For `sub_magnitudes_dominant`:

```python
def sub_magnitudes_dominant(x, y, ctx):
    if same_identity_or_exact_value(x, y):
        return Zero(sign=+1)
    delta = log_abs(y) - log_abs(x)
    if is_too_close_for_context(delta, ctx):
        return resolve_cancellation(x, y, delta, ctx)
    correction = log1p(-exp(delta))
    return with_sign(sign(x), exp(log_abs(x) + correction))
```

The optimized implementation should incorporate Clenshaw/Turner case splitting: big/big, small/small, and mixed reciprocal cases. The MATLAB simulator's explicit `main_sli_algorithm` is a useful guide for the reference version because it makes reciprocal cases visible.

## Powers and roots

For real powers:

```text
x^y = exp(y * log(x))      for x > 0
```

For negative bases, Nummy should special-case integer and rational exponents when exact exponent information is available. Otherwise it should either produce a complex result if complex mode is enabled or raise/return an invalid-domain state.

Integer powers should use exponentiation by squaring for ordinary values and structural shortcuts for high-level values. Repeated multiplication should not be used for large exponents when `exp(n * log_abs(x))` is more stable.

Roots are powers with reciprocal exponents, with exact odd/even root handling for negative bases where possible.

## Factorial and gamma

Factorial and gamma are useful at exactly the scales where Nummy is intended to operate. The archive's Hypercalc report points to Stirling-style strategies. Nummy should implement:

- exact factorial for small nonnegative integers;
- MPFR/ordinary gamma for safe ordinary ranges;
- log-gamma asymptotics in the SLI/log domain for huge inputs;
- explicit error estimates from the asymptotic truncation;
- no claim of exact integer factorial digits once the result enters SLI scale.

A useful primitive is `loggamma_abs(x)`, which can feed `gamma(x) = exp(loggamma_abs(x))` for positive real `x`.

## Tetration, iterated exp/log, slog

These should not be in the minimum viable arithmetic kernel, but Nummy should reserve API and notation space for them because the archive's power-tower lineage makes them central to user expectations.

Recommended phase-one support:

- `iterated_exp(base=e or 10, height=n, payload=...)` for integer height;
- `iterated_log(base=e or 10, count=n)`;
- parsing/display of `eeX`, `(e^N)X`, and `N PT X` as notation adapters;
- no promise of analytically continuous tetration/slog until a separate numerical method is specified.

The break_eternity.js continuous tetration/slog approximations are useful references for later, but they should not define Nummy's core semantics.

## Modulo and integer-like functions

Modulo should be deliberately conservative.

At high levels, knowing the scale of a number usually tells us almost nothing about its residue modulo a small integer. For example, an SLI coordinate may locate a number's magnitude while discarding the lower bits that determine parity. Therefore:

- exact modulo is allowed only for exact/provenance-preserved integer values;
- modulo of ordinary MPFR values follows ordinary numeric policy;
- modulo of high-level approximate SLI values should return `Unresolved` or an interval/set only when a proof is available;
- a fast heuristic mode may exist, but it must be opt-in and visibly heuristic.

The same applies to floor, ceiling, parity, primality, gcd, divisibility, and exact combinatorial identities.

# Uncertainty and precision model

## Coordinate balls

Each finite approximate Nummy value should carry an uncertainty ball in coordinate space:

```text
coord in [c - r, c + r]
```

where `c` is the normalized level-index coordinate and `r` is outward-rounded. For ordinary values, Nummy may also track ordinary absolute/relative error. But the durable contract at high levels is the coordinate ball.

Coordinate balls are honest about SLI precision. At high levels, a tiny coordinate radius can correspond to an enormous ordinary relative uncertainty. That is not a bug; it is the reason Nummy can represent the value at all.

## Result flags

In addition to numerical uncertainty, results should carry flags. Suggested flags:

| Flag | Meaning |
|---|---|
| `RoundedCoordinate` | Coordinate was rounded to context precision. |
| `DominatedAddend` | One operand was swallowed by a certified dominance rule. |
| `CancellationResolved` | Cancellation occurred but was resolved by exact/provenance or guard precision. |
| `CancellationUnresolved` | Result is uncertain due to unresolved cancellation. |
| `DemotedToOrdinary` | Result left SLI and became ordinary scale. |
| `PromotedToSLI` | Result left ordinary scale and became SLI. |
| `StructuralSimplification` | Expression provenance simplified the operation. |
| `AsymptoticApproximation` | Function used asymptotic expansion with tracked remainder. |
| `Heuristic` | Fast-mode heuristic used. Not suitable for audited computation. |
| `ExternalSpecialImported` | Imported an external overflow/underflow/special state. |

Flags make Nummy useful in notebooks and debugging sessions. They also let downstream systems refuse results with certain provenance.

## Precision queries

The API should expose multiple precision notions.

```python
x.coord_precision_bits()
x.coord_radius()
x.ordinary_relative_precision_estimate()
x.has_known_decimal_prefix()
x.result_flags()
x.audit()
```

`ordinary_relative_precision_estimate()` may be `None` or `Unknown` for high-level values. That is preferable to a misleading number.

# Structural provenance and scale algebra

Nummy can mitigate catastrophic loss by preserving selected expression structure. This should be lightweight, not a full symbolic algebra system.

## Provenance DAG

A `StructuredScale` value carries:

- operation kind (`exp`, `log`, `pow`, `mul`, `div`, `add`, etc.);
- references to child nodes or content hashes;
- exact parameters when small;
- approximate SLI coordinate for ordering and display;
- simplification metadata.

The DAG is bounded by context. When it exceeds budget, Nummy keeps the approximate coordinate and drops or compresses provenance.

## Simplification rules

Minimum structural rules:

```text
log(exp(x)) -> x                         when domains allow
exp(log(x)) -> x                         for positive x
log(x*y) -> log(x) + log(y)              when x,y positive and policy allows
exp(a)*exp(b) -> exp(a+b)
exp(a)/exp(b) -> exp(a-b)
pow(exp(a), b) -> exp(a*b)
recip(exp(a)) -> exp(-a)
x/x -> 1                                when same identity or exact proof
x - x -> 0                              when same identity or exact proof
```

These rules are essential. Without them, Nummy would reproduce a common CAS problem: evaluating an expression too early and then being unable to recover lost information.

## Limits

The structural layer is not a theorem prover. It should not try to prove arbitrary identities. It should perform local, sound rewrites with clear domain checks.

# Formatting and parsing

Formatting is not cosmetic in Nummy. It is part of the semantics because users need to understand what kind of information the value carries.

## Display modes

Nummy should support these display modes.

| Mode | Example | Use |
|---|---|---|
| Ordinary decimal | `123.456` | Values demoted to ordinary scale. |
| Scientific | `1.23456e789` | One-log extended decimal values. |
| Tower `e` notation | `ee123.4`, `eee5` | Compact base-10 tower display borrowed from break_eternity-style notation. |
| Power-tower notation | `2 PT 123.4` | Hypercalc-compatible display. |
| SLI diagnostic | `SLI(sign=+, recip=false, level=3, index=0.971...)` | Debugging and reproducibility. |
| Log magnitude | `log10(|x|) = ee12.3` | Honest display for values whose decimal form is not meaningful. |
| Uncertainty display | `SLI(... +/- 2^-180)` | Audited computation. |

The default `repr` should be unambiguous and reconstructable. The default `str` can be friendlier but must avoid overclaiming digits.

## Parser

The parser should accept:

```text
123
-1.234e567
1e1e6
ee6
eee1.25
3 PT 7.5
SLI(+ direct level=3 index=0.9711308)
10^^5
exp(exp(1000))
```

Parsing should return structured provenance when possible. For example, `exp(exp(1000))` should not immediately become a bare SLI coordinate if the expression tree is cheap to preserve.

## Output honesty rules

1. Do not print a decimal mantissa if the representation does not justify it.
2. If a displayed decimal prefix is approximate, make that clear through precision markers or audit info.
3. If a dominance or cancellation flag is present, make it visible in diagnostic mode.
4. Provide machine-readable JSON with tag, level, index, precision, flags, and provenance hash.

# Public API sketch

## Python API

```python
from nummy import Real, Context, getcontext

ctx = Context(index_bits=256, guard_bits=64)
x = Real.exp(Real.exp(1000), context=ctx)
y = 1 / x

x.log().log()              # approximately 1000, structurally exact if provenance kept
x + y                      # x with DominatedAddend flag
x.audit()                  # precision, flags, representation, provenance
x.to_string("tower")       # e.g. "ee434.294..." depending on base/display policy
x.to_string("sli")         # diagnostic representation
```

Constructors:

```python
Real(123)
Real("1.23e456")
Real.parse("ee100")
Real.from_sli(sign=1, reciprocal=False, level=3, index="0.9711308")
Real.from_mpfr(value, precision=512)
Real.from_decimal(mantissa="1.23", exponent=456)
```

Operations:

```python
x + y
x - y
x * y
x / y
x ** y
x.exp()
x.log()
x.log_abs()
x.sqrt()
x.root(n)
x.gamma()
x.loggamma()
x.iterated_exp(height=5, base=10)
x.iterated_log(count=3, base=10)
```

Audited operations:

```python
x.add(y, audit=True)
x.compare(y, audit=True)
x.with_context(ctx)
x.refine(extra_bits=128)
x.drop_provenance()
```

## Sage integration

Sage is the easiest CAS integration because it is Python-based and already uses MPFR-backed `RealField`. Nummy should provide:

- coercion from Sage integers, rationals, real algebraic values, `RealNumber`, intervals, and symbolic expressions;
- a Sage parent/element wrapper if deeper integration is desired;
- conversion back to Sage `RealField` only when magnitude and precision allow;
- expression-level wrappers for values that cannot be converted.

## Mathematica and Maple bridges

The first bridge should be textual and explicit rather than trying to replace either system's numeric evaluator.

Recommended interchange object:

```json
{
  "type": "NummyReal",
  "version": 1,
  "tag": "Finite",
  "sign": 1,
  "reciprocal": false,
  "level": 3,
  "index": "0.971130800000...",
  "index_bits": 256,
  "radius_li": "0x1p-240",
  "flags": ["RoundedCoordinate"]
}
```

Mathematica can wrap this as `NummyReal[Association[...]]`; Maple can wrap it as a module/object. Evaluation stays explicit: users call Nummy functions instead of relying on hidden coercions.

# Implementation plan

## Phase 0: Specification and executable reference

Deliverables:

- A written arithmetic semantics specification.
- Pure Python reference implementation of `NummyReal`, `Context`, `LevelIndex`, and basic normalization.
- Parser/formatter for decimal, tower, and diagnostic SLI forms.
- A small golden test corpus from the archive's examples and prototypes.

Exit criteria:

- `exp(exp(n))`, reciprocals, logs, products, and dominance additions work without overflow for large ordinary `n`.
- Ordinary values round-trip through MPFR-compatible paths.
- All special states are distinguishable.

## Phase 1: Core SLI arithmetic

Deliverables:

- Addition/subtraction with dominance certificates and cancellation policy.
- Multiplication/division via `log_abs` + `exp` reference path.
- Direct SLI comparison, reciprocal, and normalization.
- Coordinate uncertainty propagation.
- `nextabove`, `nextbelow`, and `float_distance` analogues for the chosen format.

Exit criteria:

- Differential tests against MPFR for safe ordinary ranges.
- Differential behavior checks against GSLI/MATLAB simulator for representative SLI cases.
- Property tests for monotonicity, reciprocal symmetry, and log/exp round-trips.

## Phase 2: Structural provenance

Deliverables:

- Bounded provenance DAG.
- Sound simplification rules for exp/log/pow/product/quotient identities.
- Cancellation recovery using identity/provenance and guard precision.
- Audit output explaining simplifications.

Exit criteria:

- `log(exp(x))`, `exp(log(x))`, `exp(a)*exp(b)`, `exp(a)/exp(b)`, `x-x`, and `x/x` behave structurally when domains are known.
- Provenance limits are enforced and visible.

## Phase 3: Transcendentals and asymptotics

Deliverables:

- `pow`, roots, `loggamma`, `gamma`, and factorial strategy.
- Asymptotic error tracking.
- Opt-in tetration/iterated-log functions for integer heights.

Exit criteria:

- Huge factorial/gamma values return meaningful scale results.
- Error flags distinguish asymptotic approximations from exact/symbolic simplifications.

## Phase 4: Performance engineering

Deliverables:

- Native core prototype in Rust or C++ if needed.
- Python bindings with stable API.
- C ABI for external tools.
- Cache and vectorization strategy.

Exit criteria:

- Ordinary operations are competitive with MPFR/mpmath for reasonable precisions.
- High-level structural operations are O(1) or O(log level) where mathematically possible.
- Expensive O(level) algorithms have fallbacks when `level > max_algorithmic_level`.

## Phase 5: CAS adapters

Deliverables:

- Sage package integration.
- Mathematica textual/JSON bridge, then WSTP bridge if justified.
- Maple textual/JSON bridge.
- Notebook examples showing Nummy as an escape hatch after external overflow/underflow.

Exit criteria:

- External systems can round-trip Nummy values without converting them to ordinary floats.
- External overflow/underflow states can be imported as explicit Nummy states or recomputed from symbolic inputs.

# Testing strategy

## Unit tests

Test each primitive on ordinary, boundary, high-level, reciprocal, and special values. Boundary tests are crucial: values near 1, near reciprocal flip-over, near ordinary/SLI promotion, and near cancellation.

## Differential tests

- Compare ordinary-range arithmetic against MPFR/Sage `RealField` at multiple precisions.
- Compare direct SLI behavior against GSLI where licensing permits execution as an external oracle.
- Compare readable algorithm paths against the MATLAB simulator's published logic and tests.
- Compare tower parsing/formatting examples against Hypercalc and break_eternity-style notation where semantics overlap.

## Property-based tests

Useful properties:

```text
x == exp(log(x))                 for positive x when context can certify
log(exp(x)) == x                 under domain/provenance rules
x * recip(x) == 1                for nonzero x with identity/provenance
abs(x) >= 0
x + 0 == x
x * 1 == x
compare(x, y) == -compare(y, x)
recip(recip(x)) == x
log_abs(x*y) ~= log_abs(x)+log_abs(y)
```

Approximate properties should be checked in coordinate space, not ordinary relative error, once values enter high levels.

## Metamorphic tests

Generate expressions that are mathematically equivalent but operationally different:

```text
exp(a) * exp(b)          vs exp(a+b)
exp(a) / exp(b)          vs exp(a-b)
log(exp(exp(a)))         vs exp(a)
(x + y) - x              vs y       # should expose dominance/cancellation limits
x + y                    vs y + x
(x*y)/y                  vs x       # when y nonzero and provenance available
```

Nummy should not always return the same low-level representation, but it should return compatible audited results.

## Golden failure tests

Nummy should include tests where conventional systems are expected to overflow, underflow, or lose precision. Examples:

```python
x = exp(exp(1000000))
1 / x
log(log(x))
x + 1
x - x
exp(10**100) / exp(10**100 - 1)
gamma(exp(1000))
```

The expected output is not always a precise ordinary real. Sometimes the correct result is a dominance-certified value, an exact structural simplification, or an unresolved cancellation state.

# Performance considerations

## Complexity by operation

| Operation | Desired common complexity | Notes |
|---|---:|---|
| sign/abs/reciprocal | O(1) | Bit/field changes. |
| comparison | O(1) common | Uncertainty overlap may require more work. |
| log/exp | O(1) common | Boundary normalization may require MPFR operations. |
| multiplication/division | O(1) to O(level) | Reference path uses log/add/exp; optimized path can reduce work. |
| addition/subtraction | O(1) dominance, O(level) close cases | Cancellation may require provenance or higher precision. |
| formatting | O(1) for SLI/tower; potentially expensive for ordinary decimal expansion | Avoid decimal expansion of high-level values. |
| exact modulo/floor | Only for exact/ordinary values | High-level approximate values are usually unresolved. |

## Avoiding O(level) explosions

SLI algorithms that allocate arrays by level are fine for small levels but unsuitable if users create huge tower heights. Nummy should have a context field such as `max_algorithmic_level`. Above that level:

- structural log/exp can still increment/decrement levels;
- addition usually becomes certified dominance unless coordinates are identical or nearly identical;
- multiplication/division can often be handled through log-space structural rules;
- close cancellation should become `Unresolved` unless provenance proves the result.

This keeps Nummy functional instead of hanging on mathematically unhelpful work.

## Caching

Nummy should cache:

- normalized log coordinates;
- display strings for immutable values;
- provenance simplification hashes;
- threshold constants for each context;
- common constants (`0`, `1`, `-1`, `e`, `pi`, `ln(10)`, `log10(e)`).

Caches must be context-aware because precision and rounding affect results.

# Documentation requirements

Nummy's documentation should be unusually explicit about its numeric contract. Required topics:

1. What Nummy is good for.
2. What Nummy is bad for.
3. Difference between ordinary precision and coordinate precision.
4. Meaning of dominance flags.
5. Meaning of cancellation/unresolved results.
6. Why `x + 1 == x` can be correct in Nummy for extreme `x`.
7. Why `x - x == 0` can be exact only with identity/provenance, not merely because displays match.
8. How to convert to and from MPFR, Decimal, float, Sage, Mathematica, and Maple.
9. How to choose contexts.
10. How to read SLI and tower notation.

The docs should include side-by-side examples showing conventional overflow/underflow and Nummy's output.

# Licensing and source-use policy

The archive contains prototypes with different licenses. Nummy should establish a source-use rule before implementation begins.

- MIT-licensed prototypes can be used more freely, but design should still avoid unnecessary code copying.
- GSLI is GPL. Unless Nummy chooses a GPL-compatible license, do not copy GSLI code. Use it as an external behavior reference and cite it as inspiration.
- The MATLAB level-index simulator is BSD 2-Clause per its README and may be more permissive, but code translation should still be deliberate and documented.
- Hypercalc artifacts carry file-header terms. Treat them as algorithm-study material unless licensing is reviewed.

A clean-room-ish approach is best: write Nummy's spec from the mathematical papers and archive summaries, use prototypes for tests and behavioral comparison, and keep any copied code isolated with license records.

# Risks and mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Users mistake Nummy for exact arbitrary precision. | They may trust digits that are not represented. | Aggressive documentation, display honesty, result flags, explicit conversion policies. |
| Addition/subtraction become a source of silent errors. | These are the hardest SLI operations. | Dominance certificates, cancellation policy, structural provenance, tests around boundaries. |
| Formatting overwhelms arithmetic design. | Tower notation can obscure the numerical core. | Keep formatting/parser layer separate from SLI representation. |
| Native implementation copies incompatible code. | Licensing risk. | Treat prototypes as references; use clean implementation and clear license review. |
| O(level) algorithms hang on giant levels. | Users will create extreme tower values. | `max_algorithmic_level`, structural shortcuts, `OpaqueHighLevel`, dominance fallbacks. |
| CAS adapters silently coerce values back to floats. | This defeats the point. | Use explicit wrapper objects and JSON/diagnostic representations. |
| Transcendental functions overpromise. | Gamma/tetration/slog have complex domains and approximations. | Phase them in with audited asymptotic/error semantics. |

# Example user stories

## Escape from overflow

```python
x = Real.exp(Real.exp(1000))
print(x)
# ee434.294481...   or diagnostic SLI form, depending on display mode

print(x.log().log())
# 1000, exact or high-confidence if provenance was preserved
```

A conventional floating-point system cannot materialize `x`. Nummy can, because the value is represented by scale structure.

## Escape from underflow

```python
y = 1 / Real.exp(Real.exp(1000))
print(y)
# reciprocal tower / SLI reciprocal form

print(y.log_abs().neg().log())
# approximately 1000, with provenance if available
```

The reciprocal side is not a denormal or zero. It is a first-class finite value.

## Certified dominance

```python
x = Real.parse("eee10")
z = x + 1
z.audit()
# operation: add
# result: x
# flags: DominatedAddend, ExactWithinCoordinate
```

This is not an error. It says the current representation cannot distinguish `x + 1` from `x`, and that this was certified.

## Unresolved cancellation

```python
a = Real.parse("eee10")
b = Real.parse("eee10")
(a - b).audit()
# exact zero if a and b are the same object or same parsed exact value

c = external_nummy_value_with_same_display_but_unknown_bits()
(a - c).audit()
# UnresolvedCancellation unless provenance or intervals prove the result
```

This distinction is essential. Matching displays do not imply equal values.

# Recommended minimum viable product

The smallest useful Nummy should include:

1. `NummyReal` with explicit states and SLI finite representation.
2. Context with index precision, guard bits, dominance policy, and cancellation policy.
3. Normalization for ordinary, reciprocal, and SLI values.
4. Comparison, negation, abs, reciprocal.
5. `exp`, `log`, `log_abs`.
6. Multiplication/division through log-space reference algorithms.
7. Addition/subtraction with certified dominance and unresolved cancellation states.
8. Parser/formatter for ordinary decimal, scientific notation, `ee...`, `N PT X`, and diagnostic SLI.
9. Basic provenance for exp/log/product/quotient simplification.
10. Test corpus covering ordinary values, huge values, tiny values, dominance, cancellation, and external special states.

This MVP is already enough to show why Nummy exists.

# Open design questions

1. **Base interval and generalized SLI parameters.** Should the first release use a simple canonical LI interval for clarity, or a GSLI-style generalized interval for better ordinary-range behavior? Recommendation: implement the simple model in the reference spec, but use generalized parameters in the production core once tests are ready.

2. **Backend precision engine.** Should Python use `gmpy2.mpfr`, `mpmath`, `decimal`, or a custom wrapper? Recommendation: prefer MPFR semantics through `gmpy2` or a small native binding; keep mpmath as a portability fallback only.

3. **Default provenance budget.** How much structure should be retained? Recommendation: keep enough for common exp/log/pow simplifications, with a node budget and hash-consing.

4. **Intervals versus single coordinate balls.** Should every approximate value be a ball, or should balls be opt-in? Recommendation: store at least a radius/quality field in every approximate value; full interval endpoints can be enabled in audited contexts.

5. **Complex numbers.** Should complex support be part of v1? Recommendation: no. Define real semantics first, then add complex values with explicit branch-cut policies.

6. **Hyperoperation arrays.** Should OmegaNum-style arrays be supported? Recommendation: not initially. Reserve extension points but do not complicate the SLI core.

# Source material reviewed from the archive

- `README.md` and `TOC.md`: project goals, corpus layout, and reading order.
- `docs/reports/cas-floating-point-shortcomings__288318099677.md`: CAS numeric-tower failure modes and implications for Nummy.
- `docs/reports/Prototype Corpus Overview.md`: comparison of prototype lineages and design takeaways.
- `docs/reports/Power-Tower Arithmetic and SLI in Python.md`: power-tower arithmetic, uncertainty, and Python-facing library survey.
- `docs/theory/symmetric-level-index-arithmetic-introduction__316e449481ec.md`: SLI conceptual model, reciprocal symmetry, precision trade-offs.
- `prior-art/GSLI`: direct generalized SLI implementation and representation details.
- `prior-art/level-index-simulator`: MATLAB SLI simulator with custom precision and explicit reciprocal handling.
- `prior-art/break_infinity.js`: extended scientific notation and fast decimal-like API.
- `prior-art/break_eternity.js`: layer/magnitude tower representation, normalization, and tetration/slog-facing API.
- `prior-art/OmegaNum.js`: array-based hyperoperation representation.
- `prior-art/hypercalc` and `prior-art/python/hypernums.py`: Hypercalc-style power-tower notation and arithmetic sketches.
- `prior-art/expol.py` and `prior-art/python/break_eternity.py`: simple Python experiments and cautionary references.

# Public references consulted

- Wolfram Language Documentation, "Numbers": https://reference.wolfram.com/language/tutorial/Numbers.html?view=all
- Wolfram Language Documentation, "Overflow": https://reference.wolfram.com/language/ref/Overflow.html
- Maple Help, "evalf/details": https://www.maplesoft.com/support/help/Maple/view.aspx?path=evalf/details
- Maple Help, "Digits": https://www.maplesoft.com/support/help/Maple/view.aspx?path=Digits
- Maple Help, "Float": https://www.maplesoft.com/support/help/Maple/view.aspx?path=float
- SageMath Reference Manual, "Arbitrary precision floating point real numbers using GNU MPFR": https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html
- SageMath Reference Manual, "Fixed and Arbitrary Precision Numerical Fields": https://doc.sagemath.org/html/en/reference/rings_numerical/index.html
- GNU MPFR Manual: https://www.mpfr.org/mpfr-current/mpfr.html
