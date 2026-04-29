# Nummy Design Proposal

Overflow-resistant arbitrary-precision floating-point arithmetic via symmetric level-index (SLI) “scale algebra”

**Status:** design proposal (implementation-agnostic, but biased toward a C/C++/Rust core with MPFR/GMP backends)
**Scope:** real numbers first; complex later; focus on correctness contracts, normalization invariants, and boundary behavior.

---

## 1. Problem statement

Conventional arbitrary-precision floating point in CAS systems (Mathematica, Maple, Sage/MPFR, etc.) typically remains “mantissa × base^exponent” with a larger mantissa. This solves “more digits,” but does not fundamentally solve “scale” when magnitudes become so extreme that:

* the exponent range (or intermediate exponent range in algorithms) is exceeded ? overflow/underflow or pseudo-infinities;
* representing intermediate values requires an astronomically large exponent, even if the final answer is reasonable;
* cancellation makes the result depend on low-order digits that were never computed ? catastrophic loss of precision;
* some functions (e.g., periodic functions of enormous arguments) become ill-defined at the requested precision because argument reduction is impossible without far more precision than the value carries.

The archive materials argue (correctly) that the missing abstraction is a **native scale coordinate system**: arithmetic directly on “how many logs until the value is ordinary,” not on the digits of the value itself.

Nummy’s thesis: build a numeric engine where “overflow/underflow” becomes a **level transition** rather than an exceptional state, and where loss of information is explicit and inspectable rather than silent.

---

## 2. High-level goals and non-goals

### 2.1 Goals

1. **Virtually abolish overflow and underflow** for finite computations, by representing scale in a multi-level logarithmic coordinate system (SLI family).
2. **Support arbitrary precision** in the *stored coordinate* (index), with controlled rounding and guard-digit policies.
3. **Make approximation semantics explicit**:

   * track uncertainty / effective significance;
   * expose dominance decisions (when an addend cannot affect a sum);
   * separate representational states: “mathematically infinite,” “division by zero,” “precision exhausted,” etc.
4. **Remain numerically useful when digit-centric bigfloats fail**, specifically in:

   * huge/tiny intermediates;
   * recurrence relations with explosive growth/decay;
   * log/exp chains and power towers;
   * large combinatorics/probability computations that would underflow/overflow in linear space.
5. **Provide predictable normalization invariants** so the type is auditable and can be reimplemented/debugged.

### 2.2 Non-goals (at least for v1)

* Not a full CAS and not a symbolic simplifier.
* Not exact arithmetic (integers/rationals) as the primary contract. (Interop can exist, but Nummy’s core is approximate.)
* Not “correctly rounded in the real numbers” across all operations (too broad). Instead: correctly rounded *in the chosen SLI coordinate model*, with explicit error bounds.
* Not immediately targeting extreme googology/hyperoperation stacks beyond a finite SLI ladder (OmegaNum-style) — though the design should leave a clean escape hatch.

---

## 3. Prior art inspiration from the archive

Nummy should explicitly borrow and/or learn from these lineages:

### 3.1 SLI/LI academic core

* **Clenshaw–Olver LI** and **Clenshaw–Turner SLI** define:

  * the coordinate map (`psi`) via repeated logarithms,
  * the reconstruction map (`phi`) via repeated exponentials,
  * algorithms for addition/subtraction that operate on bounded sequences (`a_j`, `b_j`, `c_j`, `a_j`, `ß_j`) and avoid overflow by never constructing enormous intermediate values.

Key takeaways to incorporate:

* **Symmetry for tiny values** is not optional: represent small magnitudes via reciprocals with explicit bookkeeping.
* **Addition/subtraction is the hard part** and must be first-class, not an edge case.
* Error control works by **fixed absolute precision** of bounded internal sequences, plus guard digits in key places.

### 3.2 Direct SLI implementations

* **GSLI** demonstrates a “fast path” where ordinary values are represented exactly in the base format, and only extreme values use SLI levels.
* **level-index-simulator** (MATLAB) makes format choices explicit (level bits, index bits, rounding) and is a great blueprint for making Nummy’s invariants and precision behavior inspectable.

Key takeaways:

* Keep a high-quality “ordinary regime” (either as a fast path or as “low levels with high index precision”).
* Make quantization/rounding rules concrete and testable.

### 3.3 Practical tower arithmetic

* **Hypercalc**, **break_infinity**, **break_eternity** show:

  * ergonomics and notation expectations (layers, slog, tetration helpers),
  * aggressive normalization and dominance heuristics for sums at far-separated scales,
  * the value of explicitly tracking approximation/uncertainty (Hypercalc’s uncertainty component).

Key takeaways:

* Users *want* usable display/parse for huge values.
* Dominance decisions are inevitable; they must be explicit and tied to precision.

### 3.4 CAS shortcomings report

Key pressures to bake into the spec:

* Avoid silent mixing of regimes that changes semantics.
* Don’t conflate “mathematical infinity” with “format overflow.”
* Separate “requested precision,” “working precision,” and “display precision.”
* Expect “precision exhaustion” in certain transcendental functions at huge scales; represent it honestly.

---

## 4. Core mathematical model

Nummy’s core numeric model will be **Symmetric Level-Index Arithmetic** (SLI), possibly generalized the way GSLI does to preserve a wide “ordinary” region.

### 4.1 Canonical SLI representation (conceptual)

For nonzero real (X):

[
X = s(X) \cdot \phi(x)^{r(X)}
]

* (s(X) \in {+1,-1}) is the sign.
* (r(X) \in {+1,-1}) is the reciprocal indicator:

  * (r(X)=+1) if (|X| \ge 1)
  * (r(X)=-1) if (|X| < 1) (store reciprocal magnitude).
* (x) is the level-index coordinate (nonnegative, typically (x \ge 1) in the symmetric system once level-0 is eliminated).

The classic Clenshaw definition:

* For (0 \le y \le 1): (\phi(y) = y)
* For (y > 1): (\phi(y) = \exp(\phi(y-1)))

The inverse (“generalized logarithm”) (\psi) repeatedly applies (\ln) until the value is in ([0,1)).

### 4.2 Why this helps

* Values like ( \exp(\exp(\exp(0.7)))) become **small data**: a modest level and an index.
* Underflow/overflow is replaced by **increasing/decreasing level**, not by exiting the number system.

### 4.3 Precision contract (the crucial honesty)

Nummy preserves precision primarily in the **generalized-log coordinate**, not necessarily in ordinary relative error at extreme magnitudes.

That’s a feature, not a bug — but the engine must expose it:

* “How many reliable digits” is context-dependent and can collapse under cancellation.
* At high levels, *tiny coordinate errors correspond to gigantic relative errors in real space*.

Hence: Nummy must ship with **error metadata** and **dominance flags**, not just values.

---

## 5. Data model and invariants

### 5.1 Core types

At minimum:

* `NContext` — precision & policy object (no global knobs).
* `NReal` — signed real value (finite or special).
* `NMag` (optional) — magnitude-only type to simplify internal algorithms.
* `NBall` / `NInterval` (optional but recommended) — value + error radius / bounds.

### 5.2 `NReal` internal representation

A practical v1 representation:

```text
enum NClass { Finite, Zero, Inf, NaN, Unknown }

struct NReal {
  NClass  cls;

  bool    sign;        // false = +, true = -
  bool    recip;       // false = magnitude, true = reciprocal-magnitude
                       // (exact meaning defined by normalization rules)

  BigInt  level;       // >= 1 for nonzero finite; potentially huge
  BigFloat index;      // bounded (e.g. in [0,1) or (MIN_1, MAX_1])

  PrecisionMeta pm;    // optional: significance / ulp / ball radius
  Flags flags;         // dominated, inexact, phase-lost, etc.
}
```

**BigFloat**: MPFR-like arbitrary precision float used only for bounded quantities (index and internal sequences). This is key: bounded BigFloat means MPFR exponent limits are not a bottleneck.

**BigInt**: GMP-like integer for level. But to avoid O(level) loops, algorithms must short-circuit based on precision thresholds (more on that below).

### 5.3 Normalization invariants

Pick one of two canonical schemes:

#### Scheme A: “No level 0” (Clenshaw/Turner style)

* For finite nonzero numbers:

  * `level >= 1`
  * `index ? [0, 1)` (or a small bounded interval)
* (|X| \ge 1) iff `recip == false`; else (|X| < 1) and magnitude is stored via reciprocal.

Pros: matches the SLI paper’s simplifications (fewer special cases).
Cons: even “ordinary” numbers live at small levels; may be slower than a dedicated linear fast path.

#### Scheme B: “Generalized SLI with wide level-0 region” (GSLI style)

* `level == 0` stores a conventional arbitrary-precision float exactly (or almost exactly).
* `level >= 1` uses bounded index ranges.
* Transitions between level 0 and level 1 are continuous via generalized phi/psi scaling constants.

Pros: excellent ordinary-number behavior.
Cons: more complicated mapping and edge conditions.

**Proposal:** Implement Scheme B for the public type (best UX), but keep Scheme A machinery in an internal `SLICore` module because:

* many algorithms and proofs are cleaner without level 0,
* but users strongly benefit from a wide ordinary regime.

Concretely: public `NReal` can be a tagged union:

* `FiniteLinear(BigFloat value)` for ordinary regime
* `FiniteSLI(sign, recip, level>=1, index)` for extreme regime

…and normalization decides when to promote/demote between them.

### 5.4 Special values and operational states

Nummy should distinguish at least:

* `Zero` (with sign? probably store signed zero optionally)
* `Inf` (mathematical +8/-8)
* `NaN` (invalid/indeterminate)
* `Unknown` (precision exhausted / phase lost / deliberately “not enough information”)

This is one place where Nummy should *not* copy IEEE 754 mechanically; instead, it should expose *why* a non-finite state exists.

Recommended flag taxonomy:

* `Flag::Dominated` (addend dropped)
* `Flag::Inexact` (rounded)
* `Flag::Underresolved` (result exists but accuracy not guaranteed)
* `Flag::PhaseLost` (periodic function argument reduction impossible)
* `Flag::InvalidOp` (e.g. sqrt(negative) in reals)
* `Flag::DivisionByZero`
* `Flag::OverflowRequestedPrecision` (not representational overflow; “you asked for digits we can’t justify”)

### 5.5 Precision and uncertainty metadata

Borrow the spirit of:

* Wolfram’s significance arithmetic (but don’t hide it)
* Hypercalc’s explicit uncertainty component

Minimum viable precision meta:

```text
struct PrecisionMeta {
  uint32_t p_bits;          // precision of index/linear float
  BigFloat abs_err;         // optional absolute error in SLI-coordinate or linear
  BigFloat rel_err;         // optional relative error estimate
}
```

Better (and more composable): **ball arithmetic** in the coordinate system Nummy actually preserves.

For SLI values, define the stored coordinate as (x = level + index) (conceptually), and store a ball in x-space:

* center: (x_c)
* radius: (r_x)

Then the represented real value lies in:
[
{ \pm \phi(x)^{\pm 1} : x \in [x_c - r_x, x_c + r_x] }
]

This keeps error propagation aligned with the representation.

---

## 6. Core operations and algorithms

### 6.1 Conversion: real ? SLI coordinate

#### From linear BigFloat to SLI

Input: finite nonzero `v`.

1. `sign = (v < 0)`, `m = abs(v)`
2. If `m < 1`: set `recip = true`, `m = 1/m`; else `recip = false`
3. Compute `(level, index)` such that repeated logs bring `m` into base interval.

For Scheme A ([0,1) index):

```text
level = 0
x = m
while x >= 1:
  x = ln(x)
  level += 1
index = x
// then enforce level >= 1 for nonzero by design choice
```

For Scheme B (wide level-0):

* If `m` is within “ordinary regime,” keep as linear.
* Else:

  * reduce with ln repeatedly until x is within [minIndex, maxIndex] and store as SLI.

**Key implementation detail:** This loop must never call `ln` on astronomically huge numbers in linear form. So “ordinary regime” must be bounded by what the linear backend can handle safely. That’s fine because we only need linear operations on values that fit in linear.

#### From SLI to linear BigFloat

Only permitted when level is small enough to reconstruct without overflow in linear backend, or when the user explicitly asks for an approximation with controlled clipping.

Provide:

* `to_linear_exact()` — only succeeds if representable.
* `to_linear_approx(max_exp)` — returns best effort (possibly inf/0), with flags.

### 6.2 Ordering and comparisons

Comparison is one of the big wins:

1. Handle special classes (NaN unordered, etc.)
2. Compare signs.
3. Compare magnitudes using `(recip, level, index)`:

   * For positive numbers, `recip=false` means =1, `recip=true` means <1; so it flips ordering relative to magnitude stored.
   * For SLI magnitudes, compare `level` first then `index`.

This is typically O(size(level)+size(index)), no giant computations.

### 6.3 Elementary “scale moves”: log / exp

For the classic phi definition (Scheme A), the key identities:

* If (|X| \ge 1) and (X = \phi(level+index)), then:

  * (\ln(X) = \phi((level-1)+index)) for `level > 1`
  * (\exp(\phi(level+index)) = \phi((level+1)+index))

So log/exp are **level shifts**, not huge exponentials.

For Scheme B, log/exp:

* stay in linear mode when safe,
* otherwise promote to SLI and apply level shift logic.

Edge behavior:

* `log(0)` ? `-Inf` (or `NaN` if you want strict real domain errors)
* `exp(Inf)` ? `Inf`, `exp(-Inf)` ? `0`
* `log(NaN)` ? `NaN`, etc.

### 6.4 Addition and subtraction (the main event)

This is where Nummy needs to be deliberate.

#### 6.4.1 Front-end sign handling

Given `a ± b`:

* If either is NaN ? NaN.
* If infinities ? IEEE-like rules but with explicit flags (Inf - Inf invalid, etc).
* If `a` or `b` is zero ? fast return with correct sign.
* Reduce to operations on nonnegative magnitudes:

  * if signs differ, use subtraction on magnitudes and apply sign of larger magnitude.

Then:

* order operands so that (|A| \ge |B|).

Now you’re in the Clenshaw–Turner setup.

#### 6.4.2 Classify cases by reciprocal flags

Using paper terminology (and mirrored in the MATLAB simulator):

* **Large case:** both operands in standard form ((|A|,|B| \ge 1))
* **Small case:** both operands in reciprocal form ((|A|,|B| < 1)) — computation naturally happens in reciprocal space
* **Mixed case:** one =1 and one <1

These cases differ because the most stable “base operand” changes.

#### 6.4.3 Clenshaw–Turner bounded-sequence algorithm (recommended core)

Implement the SLI addition/subtraction algorithm using bounded sequences:

* Compute `a_j = 1/phi(x-j)` via recurrence:

  * (a_{l-1} = e^{-f})
  * (a_{j-1} = \exp(-1/a_j))

* Compute the “ratio sequence” depending on case:

  * Large: `b_j`
  * Mixed: `a_j`
  * Small: `ß_j`

* Compute `c_0` (a bounded combination like `1 ± b_0`, etc.)

* Detect “flip-over” (result crosses 1, switching reciprocal form)

* Climb back up levels via `c_j = 1 + a_j ln(c_{j-1})` (or its subtraction variant)

* Normalize: repeatedly log until the final index lands in base interval.

**Why this matters for Nummy:** all of these intermediate quantities are bounded (typically in [0,1] or [0,2]), so the BigFloat backend never overflows, even if the represented real numbers are unimaginably large.

#### 6.4.4 Dominance and early termination

A practical engine must not run O(level) loops when level is enormous (possibly a huge BigInt).

Fortunately, the recurrences drive `a_j` quickly toward 0 as you descend levels. Once `a_j` is smaller than the working absolute precision `?`, further contributions are irrelevant at that precision.

So: implement sequence construction as:

```text
for j = l-1 down to 1:
  a[j-1] = exp(-1/a[j])
  if a[j-1] < gamma: 
     mark a[k]=0 for all k<j-1 and break
```

Similarly for the other sequences.

This is directly aligned with the papers’ notes (“if computed a0 is zero then z=x”), and it is the difference between “theoretical model” and “usable engine.”

#### 6.4.5 Guard digits and precision policy

Let `p` be the user precision for stored index (and/or linear values).
During addition/subtraction, allocate:

* `p_work = p + guard(p, level, operation)` bits

Guard heuristic examples:

* Base guard: +16…+64 bits for MPFR-style safety.
* Extra guard when subtraction near cancellation is detected (c_0 close to 1 in subtraction mode).

The Clenshaw error analysis effectively says: store `a_j` to tighter absolute precision than other sequences. Translate that into:

* compute `a_j` at `p_work_a = p_work + extra_guard_a`
* compute other sequences at `p_work`

Then round result back to `p`.

#### 6.4.6 Returning explicit loss information

If early dominance triggers (smaller term can’t affect sum at precision `p`):

* return the larger operand,
* set `Flag::Dominated`,
* and (if ball/interval mode enabled) widen error bound by = |smaller| in the most meaningful coordinate.

This prevents the “silent drop” problem common in huge-number libraries.

### 6.5 Multiplication and division

Multiplication and division are far more natural in SLI because log turns them into sum/difference.

Recommended approach (aligned with the papers):

1. Reduce to magnitude and sign.
2. Convert multiplication/division to operations on logs:

   * (\ln(|A \cdot B|) = \ln|A| + \ln|B|)
   * (\ln(|A / B|) = \ln|A| - \ln|B|)
3. Compute the sum/difference using the LI/SLI add/sub machinery at one lower level.
4. Apply exp to return to magnitude space (a level shift).

Careful: if you implement `ln_abs` as a level shift on the stored coordinate, this stays bounded.

Division by zero:

* return `Inf` or `NaN` depending on numerator and policy; set `Flag::DivisionByZero`.

### 6.6 Power, roots, and exponentiation

For real `pow(a,b)` you need domain rules:

* If `a > 0`: `a^b = exp(b * ln(a))`
* If `a < 0`:

  * if `b` is an integer (detectable if b is exact integer or if user requests rational recognition): allow result with sign.
  * else: invalid in reals ? `NaN` (or move to complex module).

Implementation:

* `ln(a)` for huge a is level shift (safe).
* multiplication `b * ln(a)` uses `*` which uses log-domain again — can be expensive but still safe.
* `exp` returns via level shift.

Special cases:

* `0^0` invalid or 1 by convention (policy choice).
* `0^b` for b>0 ? 0; b<0 ? Inf.
* `a^Inf` etc.

### 6.7 Transcendental functions and “precision exhaustion” semantics

This is the CAS pain point Nummy should embrace explicitly.

#### 6.7.1 Functions naturally compatible with SLI

These are great candidates for early support:

* `exp`, `log`, `log1p`, `expm1`
* `sinh`, `cosh`, `tanh` (in terms of exp; but watch cancellation)
* `gamma`, `loggamma`, `factorial` (via loggamma; output can be astronomically large but representable in SLI)
* `binomial`, `beta`, `erf` for large arguments often via logs/asymptotics

#### 6.7.2 Periodic functions on huge arguments

For `sin(x)`, `cos(x)`, `tan(x)`:

* Correct evaluation requires argument reduction `x mod 2p`.
* If `x` is enormous, you need *many* correct digits of `x` to know its remainder mod 2p.
* In SLI, you may have great knowledge of scale but not of low digits.

So Nummy should define:

* If `x` is so large that available precision cannot determine the reduced argument within a small enough interval, return an **interval/ball result**:

  * `sin(x) ? [-1,1]` with `Flag::PhaseLost`
  * or tighter bounds if partial reduction is possible
* If ball mode is disabled, return `Unknown` with `PhaseLost` flag rather than a random-looking float.

This is exactly the kind of catastrophic “precision looks fine but is nonsense” that CAS users encounter.

### 6.8 Aggregate operations: sum/product/logsumexp

Nummy should provide numerically stable building blocks as first-class API:

* `logaddexp(a,b) = log(exp(a)+exp(b))` — canonical overflow-resistant tool
* `logsumexp([x_i])` — stable sum of exponentials
* `sum([x_i])` that:

  * sorts by magnitude,
  * uses reuse of `a_j` sequences when many terms share the same “base level,”
  * tracks dominance drops explicitly.

These are core to “remain useful when bigfloat fails,” because many real workloads are exactly “add up tiny contributions near huge terms.”

---

## 7. Public API contract

### 7.1 Context-first design (avoid global knobs)

Model it like MPFR / Arb: operations happen in a context.

```text
NContext ctx;
ctx.prec_bits = 256;
ctx.mode = ErrorMode::Ball;        // or None / Significance
ctx.rounding = Rounding::Nearest;
ctx.max_work_guard = 128;
ctx.display = DisplayPolicy{...};
```

Then:

```text
NReal x = NReal::from_decimal(ctx, "1e1000000");
NReal y = NReal::exp(ctx, x);
NReal z = x + y;           // uses ctx rules
```

Crucially:

* no silent “one float literal turned everything into machine precision” regime switch;
* conversions require explicit calls (or explicit constructors).

### 7.2 Explicit conversions between regimes

Provide named constructors / converters:

* `from_int_exact`, `from_rational_exact` (if exact interop exists)
* `from_mpfr`, `to_mpfr_approx`
* `from_double` (explicitly low precision, flagged)
* `to_double` (best effort, flagged)
* `to_string(DisplayPolicy)`
* `parse(string, ParsePolicy)`

### 7.3 Error reporting

Every operation returns:

* a value
* flags (and optionally a structured status)

Example:

```text
NReal r = a + b;
if (r.flags.contains(Dominated)) {
   // you dropped something; your sum is effectively a
}
if (r.flags.contains(PhaseLost)) {
   // periodic result is an interval / unknown
}
```

This is the “CAS numeric tower” lesson applied: never hide the semantic shift.

### 7.4 Formatting and notation

Nummy must support multiple notations because “decimal digits” are not always meaningful.

Recommended formatting layers:

1. Ordinary: decimal scientific notation for linear regime.
2. SLI structural: `{recip?, level, index}` or `SLI(l=3, i=0.971...)`.
3. Tower-ish for users: `10^^...` or `exp(exp(...))` style, configurable base (10 or e).
4. For extremely huge: show “scale” not digits, e.g.:

   * `exp^[3](0.9711308)` (3 nested exps)
   * or `L=3, idx=0.9711308, recip=0`

Also allow “pretty but honest” forms:

* show a mantissa-like prefix only when it’s meaningful at the current level (avoid misleading `1.23e...` for huge-level values where that prefix is largely decorative).

---

## 8. Implementation architecture

### 8.1 Module structure

A clean split (mirroring the archive’s lesson: representation ? notation):

1. `nummy_core/`

   * `sli_rep`: internal representation and normalization
   * `sli_ops`: +, -, *, /, compare, log/exp, pow
   * `precision`: guard digit policies, ball propagation
   * `special`: NaN/Inf/Unknown semantics
2. `nummy_format/`

   * parsing: decimal + tower + SLI literal forms
   * formatting policies
3. `nummy_funcs/`

   * special functions (gamma/loggamma, factorial, binomial, etc.)
   * stable primitives (logsumexp, logaddexp, etc.)
4. `bindings/`

   * Python (Sage-friendly)
   * C ABI
   * optional: Mathematica LibraryLink adapter, Maple external interface

### 8.2 Numeric backends

Recommended:

* **MPFR** for BigFloat (bounded values)
* **GMP** for BigInt (levels, and possibly exact interop)
* Optional: a small fixed-precision fast path for common low precisions (e.g., 128-bit via `long double` or `boost::multiprecision::cpp_bin_float`) — but only if it doesn’t compromise semantics.

Key constraint: the SLI algorithm should keep internal values bounded, so MPFR exponent range is never stressed.

### 8.3 Performance strategy

1. **Fast paths:**

   * both operands in linear regime ? MPFR addition/mul directly
   * mixed linear/SLI ? promote/demote minimally
2. **Early dominance:**

   * use level/index comparisons and precision thresholds before doing heavy work
3. **Bounded sequence short-circuit:**

   * stop sequence recursion when terms drop below gamma
4. **Scratch allocation:**

   * per-thread scratch MPFR temporaries to reduce heap churn
   * avoid repeated init/clear inside tight loops

### 8.4 Determinism and reproducibility

Because Nummy is intended as a debugging-grade numeric engine:

* insist on deterministic rounding across platforms (to the extent MPFR provides it),
* make context explicit and printable,
* provide a “replayable” mode where operations log their chosen paths (fast path vs SLI path, dominance decisions).

### 8.5 Thread safety

* `NContext` should be immutable once built (or treated as such).
* Scratch pools should be thread-local.
* Avoid MPFR global exponent settings; keep exponent range fixed and stay bounded anyway.

---

## 9. Testing and validation plan

### 9.1 Invariant tests (normalization)

* Every finite nonzero number must satisfy representation invariants:

  * level bounds, index bounds
  * reciprocal/sign rules
  * canonical zero encoding
* `normalize(normalize(x)) == normalize(x)` (idempotence)

### 9.2 Differential tests vs MPFR (where representable)

For cases where SLI value can be reconstructed into MPFR without overflow:

* compare `NReal op` with MPFR op at high precision
* ensure the true value is within the ball/interval result (if ball mode enabled)

### 9.3 Cross-tests vs prototypes (behavioral)

* Compare qualitative behavior with:

  * GSLI for similar regimes (especially log/exp and comparisons)
  * break_eternity / Hypercalc for tower-scale operations and formatting expectations
* Not for exact equality, but for monotonicity and scale consistency.

### 9.4 Property-based testing

* monotonicity: if `a>b` then `f(a)>f(b)` for monotone `f` (log, exp in domain)
* algebraic identities where stable:

  * `log(exp(x)) ˜ x` (with appropriate domain caveats)
  * `exp(log(x)) ˜ x` for x>0
  * `a*(b/c) ˜ (a*b)/c` within error bounds
* “no crash” tests for random huge levels/index values

### 9.5 Known-stress suites

* cancellation:

  * `(1 + e) - 1` for e spanning huge/small scales
  * `exp(x) - exp(x)` (should go to 0 with correct flags)
* dominance:

  * `A + B` with level gaps
* extreme scale:

  * iterated exp/log chains
* periodic exhaustion:

  * `sin(10^(10^k))` for increasing k; verify it becomes `PhaseLost` not garbage.

---

## 10. Roadmap (pragmatic milestones)

### Milestone 0: Spec lock

* Choose Scheme A vs Scheme B publicly (or commit to B public + A internal).
* Freeze invariants, special-value rules, and flag taxonomy.

### Milestone 1: Core representation + conversion

* `NContext`, `NReal`
* linear mode (MPFR) + SLI mode
* `normalize`, `compare`, `abs`, `neg`, `recip`
* `log`, `exp`

### Milestone 2: Arithmetic kernel

* `+`, `-` via Clenshaw–Turner bounded sequences + early termination
* `*`, `/` via log-domain reduction
* `pow` for positive bases

### Milestone 3: Error model

* ball/interval propagation for core ops
* dominance widening rules
* introspection API (effective precision reports)

### Milestone 4: Formatting/parsing

* SLI structural format
* base-10 tower-ish display
* robust parser

### Milestone 5: First special functions

* `loggamma`, `gamma`, `factorial`, `binomial` via log forms/asymptotics

### Milestone 6: Bindings

* Python module usable in Sage workflows
* C ABI
* optional adapters for Mathematica/Maple if needed

---

## 11. Risk register and open design questions

1. **Level 0 scheme choice**
   GSLI-style generalized mapping is more complex but dramatically improves everyday behavior.

2. **Error semantics in SLI coordinate**
   “Correct digits” is ambiguous at high levels. Ball-in-x-space is conceptually clean but must be made user-comprehensible.

3. **Cancellation expectations**
   Users may expect `(A + 1) - A == 1` even for astronomically huge A. In an approximate system, that may be impossible without tracking A’s low-order structure symbolically. Nummy must flag and/or intervalize, not lie.

4. **Periodics**
   Returning `Unknown`/interval for sin/cos at huge arguments is honest but may surprise users who expect “some answer.” Documentation and flags are non-negotiable.

5. **Performance traps**
   Naively iterating sequences up to `level` is impossible when `level` is huge. The early-termination rule must be part of the formal spec, not an optimization.

6. **Interoperability with CAS**
   The biggest hazard is silent coercion and regime mixing. If Nummy is embedded, integration must preserve explicit conversion boundaries.

---

## Appendix A: Minimal pseudocode sketches

### A.1 Normalization sketch (Scheme A core)

```text
function to_sli(magnitude >= 1):
  level = 0
  x = magnitude
  while x >= 1:
    x = ln(x)
    level += 1
  index = x    // in [0,1)
  return (level, index)
```

### A.2 Addition front-end sketch

```text
function add(a, b):
  if a or b special -> handle
  if a == 0 return b
  if b == 0 return a

  // reduce to signed magnitude problem
  if sign(a) == sign(b):
     (A,B) = sort_by_abs(a,b)   // |A|>=|B|
     mag = sli_add_magnitudes(|A|, |B|)  // large/mixed/small cases
     return sign(a) * mag
  else:
     // subtraction
     (A,B) = sort_by_abs(a,b)   // |A|>=|B|
     mag = sli_sub_magnitudes(|A|, |B|)
     return sign(A) * mag
```

### A.3 Multiplication sketch via logs

```text
function mul(a, b):
  if a==0 or b==0 return 0 (with sign policy)
  sign = sign(a) xor sign(b)
  la = ln_abs(a)   // signed
  lb = ln_abs(b)
  s = la + lb
  mag = exp(s)
  return sign * mag
```
