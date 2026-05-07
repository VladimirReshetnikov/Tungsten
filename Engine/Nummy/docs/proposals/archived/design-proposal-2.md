# Nummy Design for Overflow-Resistant Arbitrary-Precision Floating-Point Arithmetic

## Executive summary

Nummy should **not** be a single exotic number format. It should be a **hybrid engine** with a conventional high-precision binary core, a much stronger exponent subsystem, and an optional rigorous error/enclosure layer. The core recommendation is:

- a **normalized arbitrary-precision significand** stored in limb arrays;
- a **hierarchical exponent object** that can scale from machine-word exponents to big integers to sparse recursive exponents inspired by the inspected repository;
- an **escalation layer** that can switch selected operations into logarithmic or symmetric level-index style scale representations when ordinary exponent arithmetic becomes the bottleneck;
- an optional **ball/interval sidecar** for rigorous error tracking and directed rounding.

That hybrid gives Nummy the best chance of remaining useful exactly where the host CAS fails: catastrophic cancellation, hidden-zero situations, exponent-range exhaustion in backend libraries, underflow/overflow sentinels, and "result technically representable but numerically meaningless" scenarios. It also keeps the common case fast and interoperable, instead of forcing every operation through a pure LNS, pure SLI, or pure rational regime. [\[1\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/README.md) [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[3\]](https://epubs.siam.org/doi/10.1137/0724034)

The inspected repository on the repository host, GitHub[\[4\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseNumerics.csproj), is highly relevant even though it is **not yet a floating-point engine**. Its SparseInteger type stores huge nonnegative integers either directly in ulong or recursively as a sorted array of bit positions; addition works by recursive carry propagation through bit-position insertion/removal, multiplication is dominated by exact power-of-two shifts, and exponentiation support is specialized around Exp2, Log2, and "power of an exact power of two." That is exactly the right intellectual seed for **Nummy's exponent layer**, not for its significand layer. The significance of the repo is therefore architectural: it shows how to represent exponents that are too large or too structured for dense big integers to be the right abstraction. [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[5\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/ArrayHelpers.cs) [\[6\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs)

For interoperability, Nummy should expose a **stable C ABI** and thin bindings for the ecosystems behind Mathematica, Maple, and Sage: **LibraryLink** and **WSTP** for Wolfram Research[\[7\]](https://flintlib.org/doc/arb.html), define_external / shared-library bindings or OpenMaple for Maplesoft[\[8\]](https://epubs.siam.org/doi/10.1137/0724034), and Python/Cython bindings for the SageMath[\[9\]](https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors) stack. Those are all officially supported extension routes. [\[10\]](https://reference.wolfram.com/language/guide/LibraryLink.html)

The most important design choice is to make **overflow resistance an explicit architectural invariant**: no internal dependence on a machine-word exponent, no requirement to materialize astronomically large decimal or binary strings, no eager conversion of scale information back into dense exponents, and no silent collapse of "too small" values into zero unless the caller explicitly asks for finite-format emulation. That lesson is reinforced by the documented behavior of MPFR, GMP floats, Wolfram precision tracking, Maple software floats, and Arb/FLINT ball arithmetic. [\[11\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html)

## Findings from SparseNumerics

The repository is small, targeted, and unusually clean in what it optimizes. The README states that SparseInteger is intended for nonnegative integers far larger than what BigInteger can represent within feasible memory, provided the binary representation has a moderate number of one-bits and the positions of those one-bits are themselves recursively representable as SparseInteger. The package is netstandard2.0, and the solution includes an xUnit test project. [\[1\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/README.md) [\[12\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseNumerics.csproj) [\[13\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.sln) [\[14\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseNumerics.Tests.csproj)

The implementation confirms the README's description. SparseInteger is an immutable value type. A small value is stored directly in a ulong; otherwise the number is stored as a sorted array of positions of set bits, and each position is itself another SparseInteger. Comparison is lexicographic from the highest set bit downward. Addition merges sparse bit-position sets and recursively carries through PlusOne; multiplication expands into shifts by exact powers of two through MultiplyByExp2; Exp2 and Log2 are first-class operations; and Power works by reducing to exponent multiplication when the base is an exact power of two. The repository therefore privileges **shift algebra** and **exponent algebra** over dense mantissa arithmetic. [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[5\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/ArrayHelpers.cs)

That design matches the recursive sparse-binary technique Vladimir Reshetnikov described publicly for the OEIS A002845 problem: represent an integer as a recursively nested list of bit positions, where operations exploit the closure of the target problem under powers of two and sparse addition. The OEIS entry now includes related PARI code using the same "positions of ones" idea for huge tower-like values. This matters because it shows the repo's model is not accidental; it is a deliberate choice for **astronomical scale values with sparse structure**. [\[15\]](https://oeis.org/A002845)

The main implication for Nummy is that this representation is **excellent for exponents** and **poor as a universal significand**. General floating-point significands need dense limb arithmetic, rounding, cancellation handling, divide/sqrt/transcendental kernels, and eventually vectorized/multithreaded multiplication. By contrast, exponents frequently need only ordering, addition/subtraction, parity, halving, exact dyadic scaling, and sparse structural compression. Nummy should therefore adopt the repository's idea as a reusable HugeExpInt layer while keeping the significand in a more conventional limb-array representation. That is the single strongest concrete design lesson from the repo. [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs)

## Goals and threat model

Nummy's goal is not merely "more precision." Existing systems already provide substantial arbitrary-precision support. The problem is that their behavior is still governed by **finite working precision**, **finite guard-digit budgets**, **backend exponent models**, and **representation choices that are not optimized for astronomical scale separation**. The threat model should therefore include five distinct failure classes: ordinary overflow, ordinary underflow, exponent-range exhaustion in a backend or host interface, catastrophic cancellation, and semantic mismatches around special values and subnormals. [\[16\]](https://reference.wolfram.com/language/ref/Overflow.html?view=all)

In the Wolfram stack, arbitrary-precision evaluation is accompanied by systemwide precision tracking, but it also relies on finite extra precision. \$MaxExtraPrecision defaults to 50 digits, and the documentation explicitly notes that some computations do not reach the requested precision with the default allowance, that hidden zeros are not fixed by merely raising \$MaxExtraPrecision, and that unlimited extra precision can exhaust memory. The documentation for SetPrecision also warns that raising precision on approximate inputs first exposes hidden binary digits and only then pads with zeros. Overflow\[\] and Underflow\[\] are explicit sentinel values in the language. For Nummy, that means the real threat in this environment is at least as much **precision semantics and cancellation pathology** as raw exponent range. [\[17\]](https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html)

In Maple, software floats are documented as pairs of integers and representing ; Digits controls working precision, and the maximum value is bounded by kernelopts(maxdigits). Maple also documents Float(infinity) as the floating-point-domain infinity representation and notes that it may arise from overflow. This suggests a different threat profile: arbitrary decimal exponent storage is native, but working precision is still finite and the system still propagates floating-point infinities and finite-precision rounding effects. So for Maple users, Nummy primarily addresses **ultra-large scale management**, **reliable guard-digit control**, and **cancellation-safe evaluation**, not just exponent storage. [\[18\]](https://www.maplesoft.com/support/help/maple/view.aspx?path=float)

In Sage, RealField is implemented atop MPFR, Sage explicitly notes that the exponent range is set to the maximal possible value, and it notes that the default exponent range is much wider than binary64 while subnormal numbers are not implemented by default. Sage also exposes interval and ball arithmetic through MPFI and Arb/FLINT. This is the clearest documented example of a CAS whose arbitrary-precision core is still tethered to a **finite exponent type** and a specific underflow/subnormal model. Nummy therefore must be designed so that its internal exponent representation is not limited by mpfr_exp_t or any machine-word analogue. [\[19\]](https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html)

GMP makes the backend risk even clearer in generic terms: mpf_t uses an arbitrary-precision mantissa with a **limited-precision exponent**, typically one machine word, and MPFR similarly restricts exponents to a subset of mpfr_exp_t, with globally changeable exponent bounds and explicit overflow/underflow flags. Nummy should treat those designs as a warning label: if exponent storage is fundamentally a machine-word concept, then "arbitrary precision" is only half arbitrary. [\[20\]](https://gmplib.org/manual/Floating_002dpoint-Functions.html)

The practical threat model for Nummy is summarized below.

| Threat                                 | Typical host symptom                                                                   | Nummy requirement                                                                   |
| -------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Enormous positive scale                | Overflow\[\], Float(infinity), backend range error, impractical decimal expansion      | Store scale structurally; never require dense exponent materialization              |
| Enormous negative scale                | Underflow\[\], collapse to zero, loss of significance in reciprocal form               | Represent tiny numbers symmetrically, not as "almost zero"                          |
| Catastrophic cancellation              | Requested precision not achieved; hidden-zero precision collapse; unstable subtraction | Detect exponent gaps, use compensated formulas, optionally switch to enclosure mode |
| Subnormal / gradual underflow mismatch | Backend-specific semantics, emulation quirks                                           | No internal subnormal category; emulate only at compatibility boundaries            |
| Special-value propagation              | Infinities/NaNs that are semantically convenient but mathematically misleading         | Dual semantics: IEEE-compatible API mode and strict mathematical mode               |

This table is a synthesis of the documented host behaviors and the proposed Nummy design constraints. [\[21\]](https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html)

## Candidate representations and recommended numeric format

The primary literature around overflow-resistant arithmetic comes from work by Charles Clenshaw[\[22\]](https://epubs.siam.org/doi/10.1137/0724034), Frank Olver[\[23\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs), and later collaborators on level-index and symmetric level-index arithmetic; from logarithmic number-system work beginning with the sign/logarithm formulation; from exact rational arithmetic libraries; from midpoint-radius interval and ball arithmetic, especially the work of Fredrik Johansson[\[24\]](https://epubs.siam.org/doi/10.1137/0724034); and from fixed-word proposals such as posits associated with John Gustafson[\[25\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs). For arbitrary-precision engineering, the modern baseline remains the multiple-precision floating-point literature summarized by Richard Brent[\[26\]](https://www.mpfr.org/algo.html) and Paul Zimmermann[\[27\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs), together with MPFR and Arb/FLINT documentation. [\[28\]](https://epubs.siam.org/doi/10.1137/0724034)

The key conclusion from that literature is that **no single representation dominates across all dimensions**. Block floating point is excellent for blocks of data sharing an exponent, but it is not an unbounded scalar representation. Pure LNS makes multiplication and division elegant, but addition and subtraction require expensive Gaussian-log style evaluation. Pure rationals are exact, but denominator growth and normalization are expensive. Ball arithmetic gives rigorous enclosures, but it is best viewed as an error-control layer rather than a sole storage format for all workloads. Posits improve fixed-word behavior, but they are not a drop-in answer to arbitrary-precision, astronomically large exponents. SLI is the closest match to Nummy's aspiration to abolish overflow/underflow, but by itself it is awkward as the only representation for ordinary high-precision scientific workloads. [\[29\]](https://www.intel.com/content/www/us/en/docs/programmable/683374/17-1/block-floating-point-scaling.html)

| Design family                          | Overflow resilience                                  | Precision model                                           | Add/Sub behavior                          | Mul/Div behavior                  | Complexity of implementation | Ease of CAS integration                      |
| -------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------- | --------------------------------- | ---------------------------- | -------------------------------------------- |
| Dense arbitrary-precision binary float | Good until exponent backend saturates                | Familiar ulp model                                        | Good, but cancellation still hard         | Excellent                         | Moderate                     | Excellent                                    |
| Block floating point                   | Weak for scalar extremes; good per block             | Shared exponent                                           | Good only for coherent blocks             | Good for vector kernels           | Low to moderate              | Poor as a scalar CAS type                    |
| Logarithmic number system              | Excellent dynamic range                              | Relative-error oriented                                   | Expensive / nontrivial                    | Excellent                         | High                         | Moderate                                     |
| Exact rational                         | No overflow for exact ratios                         | Exact                                                     | Exact but size growth can explode         | Exact but size growth can explode | Moderate                     | Good for symbolic systems, poor for numerics |
| Interval / ball arithmetic             | Excellent as enclosure layer                         | Rigorous bound + approximation                            | Width can grow, but correctness preserved | Same                              | High                         | Good as an auxiliary mode                    |
| Posits                                 | High for fixed word sizes                            | Tapered precision                                         | Hardware-friendly, but fixed-size         | Very good                         | Moderate                     | Poor for arbitrary precision                 |
| LI / SLI                               | Designed specifically to suppress overflow/underflow | Scale-centric, not classical ulp-centric                  | Harder than dense FP                      | Often elegant                     | High                         | Moderate                                     |
| **Recommended hybrid**                 | **Very high**                                        | **Classical ulp + optional enclosure + scale escalation** | **Best overall**                          | **Best overall**                  | **High but manageable**      | **Best overall**                             |

This table is analytical synthesis, but each row is grounded in the cited source categories above. [\[29\]](https://www.intel.com/content/www/us/en/docs/programmable/683374/17-1/block-floating-point-scaling.html)

The recommended concrete format is:

Nummy =  
class: Zero | Finite | Infinity | NaN | Interval  
sign: -1 | +1  
repr: DenseBinary | SparseBinary | LNS | SLI  
prec: requested precision in bits  
exp: HugeExp  
sig: normalized limb array, binary, with top bit set for nonzero finite values  
err: optional enclosure / ulp / radius sidecar  
meta: flags, diagnostics, provenance, payload

with

HugeExp =  
SmallI64  
| BigInt  
| SparseBits // SparseInteger-like recursive bit positions  
| TowerScale // level/index or equivalent logarithmic tower descriptor

The decisive trade-off is that **representation choice is a runtime concern**. Ordinary scientific arguments should live in DenseBinary; sparse power-tower-like scales should migrate to SparseBits; operations like log and exp should be allowed to promote or demote values into TowerScale when that preserves meaning while avoiding explosion. This is far more practical than committing the whole engine to a pure SLI or pure LNS worldview. [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[30\]](https://epubs.siam.org/doi/10.1137/0724034)

For **NaN/Inf semantics**, Nummy should support two modes. In **compatibility mode**, it should expose signed zero, signed infinities, and quiet NaNs with payloads so that wrappers can map naturally to host CAS and to MPFR/IEEE-style workflows. In **strict mode**, exceptional states should be explicit algebraic tags such as Indeterminate, Pole, DomainError, or "interval became unbounded," and silent promotion to infinity should be disabled except where mathematically unavoidable. This dual mode is worth the complexity because host ecosystems already differ in their special-value semantics. [\[31\]](https://reference.wolfram.com/language/ref/Overflow.html?view=all)

For **subnormals**, the best design choice is simplicity: Nummy should have **no internal subnormal category** at all. Every nonzero finite value is normalized because exponent range is not bounded in the ordinary floating-point sense. Subnormals should exist only in explicit emulation layers for binary32, binary64, MPFR compatibility experiments, or hardware export. That aligns Nummy with the documented reality that MPFR's default model does not implement subnormals directly and instead treats them as something to emulate when necessary. [\[32\]](https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html)

The following diagram shows the recommended architecture.

flowchart TD  
A\[Host API\] --> B\[Dispatcher\]  
B --> C\[DenseBinary core\]  
B --> D\[Sparse exponent core\]  
B --> E\[Scale-elevated core LNS/SLI\]  
C &lt;--&gt; D  
C &lt;--&gt; F\[Ball/interval sidecar\]  
E &lt;--&gt; F  
C --> G\[Elementary kernels\]  
E --> G  
G --> H\[Special-function layer\]  
H --> I\[Formatting and export\]  
D --> I

## Algorithms, rounding, normalization, and special functions

For addition and subtraction, Nummy should follow classical arbitrary-precision floating-point structure until it becomes obviously wasteful. First compare exponents using HugeExp. If the exponent gap exceeds the target precision plus guard bits, return the larger operand with the correct sticky-bit status instead of actually shifting a giant mantissa. If the gap is relevant, shift only the smaller significand, perform signed addition/subtraction, then renormalize by counting leading zeros and adjusting the exponent. This is ordinary floating-point engineering, but the HugeExp comparison lets Nummy make that early-out decision without assuming a machine-word exponent. The repository's shift-first style strongly reinforces this approach. [\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs)

For multiplication and division, the significand should use standard limb algorithms with Karatsuba, Toom-Cook, and FFT/NTT crossover points as appropriate, while the exponent is updated symbolically. Multiplication becomes "multiply mantissas, add exponents"; division becomes "divide mantissas, subtract exponents"; square root becomes "sqrt significand, halve exponent, adjust for odd exponent." In the common case, this gives the same asymptotic behavior expected of multiple-precision libraries; in the sparse/tower regime, exponent work can remain structural instead of degenerating into huge dense integers. The standard multiple-precision literature and MPFR algorithms are the right baseline here. [\[33\]](https://www.mpfr.org/algo.html)

For exp, log, and pow, Nummy should be **representation-aware**. On ordinary inputs it should use classical range reduction, series/Newton/AGM-style methods, and correctly rounded output targets. On astronomical inputs, it should be allowed to **change representation instead of expanding the number**. In particular, log should often demote a scale-elevated value to a more ordinary form, and exp should often promote an ordinary huge argument into a tower-scale value. That is exactly where LI/SLI ideas become valuable: not as a universal storage format, but as an **escape hatch for scale**. The original LI/SLI papers were explicitly motivated by abolishing overflow and underflow, and later work improved performance via Taylor approximations. [\[34\]](https://epubs.siam.org/doi/10.1137/0724034)

For special functions, Nummy should be built in layers. The **first release** should prioritize numerically load-bearing kernels: exp, log, pow, sqrt, hypot, fused multiply-add, and cancellation-safe companions such as expm1 and log1p. The **second layer** should add interval-aware evaluation of transcendentals and a small set of scaled special functions such as loggamma, scaled Bessel functions, and Airy functions. Arb/FLINT shows the right overall architecture for this: midpoint-radius enclosures, arbitrary-precision midpoints, small fixed-precision bounds for radii, and function implementations that increase precision until a correct enclosure is achieved. [\[35\]](https://arblib.org/index.html)

The most important rounding modes are the six that MPFR documents today: nearest-even, toward negative infinity, toward positive infinity, toward zero, away from zero, and faithful rounding. Nummy should support all six in the C ABI, because directed rounding is indispensable for interval endpoints, rigorous enclosure checks, monotonicity testing, and host-CAS integration. It should also expose sticky bits, inexact flags, cancellation warnings, and "representation escalated" flags. [\[36\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html)

Error analysis should be **first-class**, not an afterthought. Nummy's finite type should be able to carry either no error metadata, an ulp-style local error estimate, or a rigorous ball/interval sidecar. The Arb/FLINT model is especially instructive: an arb_t is a midpoint-radius interval, and the lower-level arf_t is an arbitrary-precision binary float while mag_t is an unsigned bound format. Nummy does not need to copy that layout exactly, but it should copy the architectural principle: **approximation plus automatically propagated proof of containment** when requested. [\[37\]](https://flintlib.org/doc/arb.html)

The recommended normalization policy is deliberately asymmetric. For ordinary finite values, maintain a canonical normalized significand in with a separate sign. For scale-elevated values, maintain a canonical level/index or logarithmic form without bouncing back to dense binary unless a caller explicitly requests it. Renormalization must therefore be able to move in both directions: dense results may elevate when exponent growth becomes absurd, and scale-elevated results may de-elevate when log, reciprocal, or cancellation makes dense representation practical again. This avoids the classic trap of inventing an escape representation and then forcing every result back through the bottleneck that made the escape necessary. [\[38\]](https://epubs.siam.org/doi/10.1137/0724034)

A useful engineering view of the core complexity targets is the following, where is significand precision in bits, is the chosen multiplication cost, and is the cost of exponent-object comparison/update in the current representation:

| Operation | Target algorithm                                            | Time target                                       | Space target | Notes                                             |
| --------- | ----------------------------------------------------------- | ------------------------------------------------- | ------------ | ------------------------------------------------- |
| add / sub | align, signed combine, renormalize                          | worst case; early-out when exponent gap dominates |              | Often much less than if gap is huge               |
| mul       | limb multiplication + exponent add                          |                                                   | to           | Sparse/tower exp update is cheap                  |
| div       | Newton / Burnikel-Ziegler style division + exponent sub     | target                                            | to           | Conservative first implementation may behave like |
| sqrt      | Newton or Karatsuba-style sqrt + exponent halve             | target                                            |              | Exact power-of-two scaling is cheap               |
| exp       | range reduction + series / Newton / AGM, or scale promotion | ordinary mode target                              |              | Scale-elevated mode may avoid dense blowup        |
| log       | argument reduction + Newton / AGM, or scale demotion        | ordinary mode target                              |              | Tower inputs may become much easier               |

These are design targets, not measured benchmarks in this report; they are the right asymptotic goals for a serious arbitrary-precision engine. [\[39\]](https://www.mpfr.org/algo.html)

The exponent-management policy is shown below.

flowchart TD  
A\[Input value\] --> B{Exponent fits i64?}  
B -- yes --> C\[SmallI64\]  
B -- no --> D{Dense big-int still compact?}  
D -- yes --> E\[BigInt exponent\]  
D -- no --> F{Bit pattern sparse/tower-like?}  
F -- sparse --> G\[SparseBits exponent\]  
F -- tower/log scale --> H\[TowerScale\]  
C --> I\[Core operation\]  
E --> I  
G --> I  
H --> I  
I --> J{Result easy to de-elevate?}  
J -- yes --> K\[DenseBinary result\]  
J -- no --> L\[Stay elevated\]

## Performance, API sketches, and interoperability

The performance strategy should be aggressively tiered. Small inputs should never pay for exotic machinery. Nummy therefore needs a **small-object fast path** for one- and two-limb significands, a direct i64/u64 exponent fast path, and branchless exact dyadic scaling. The next tier should use tuned schoolbook/Karatsuba/Toom arithmetic with cache-friendly limb arrays. The largest tier should add FFT-based multiplication, optional multithreading for large products and long series, and arena allocation for exponent trees so that sparse exponent manipulations do not fragment memory. These are standard engineering choices for high-performance multiprecision systems. [\[40\]](https://www.mpfr.org/algo.html)

SIMD should be confined to **limb kernels and bulk conversions**, not forced into every abstraction boundary. The literature on SIMD multiprecision arithmetic shows why this matters: generalized high-precision arithmetic can benefit from vectorization, but only if buffers, carry propagation, and crossover points are carefully controlled. For Nummy, the safe conclusion is that SIMD belongs in the limb engine, in decimal/binary conversion, and in batched evaluation of elementary kernels, not in the exponent tree itself. [\[41\]](https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors)

The public API should be small, explicit, and status-rich. A sketch for the core C ABI is:

typedef enum {  
NMY_OK = 0,  
NMY_INEXACT = 1 << 0,  
NMY_ROUNDED = 1 << 1,  
NMY_CANCELLED = 1 << 2,  
NMY_ESCALATED_REPR = 1 << 3,  
NMY_INTERVAL_WIDENED= 1 << 4,  
NMY_DOMAIN_ERROR = 1 << 5,  
NMY_POLE = 1 << 6,  
NMY_RESOURCE_LIMIT = 1 << 7  
} nmy_status;  
<br/>typedef enum {  
NMY_RNDN,  
NMY_RNDD,  
NMY_RNDU,  
NMY_RNDZ,  
NMY_RNDA,  
NMY_RNDF  
} nmy_round;  
<br/>typedef struct nmy_ctx nmy_ctx;  
typedef struct nmy_num nmy_num;  
typedef struct nmy_interval nmy_interval;  
<br/>nmy_status nmy_add (nmy_num\* z, const nmy_num\* x, const nmy_num\* y,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_sub (nmy_num\* z, const nmy_num\* x, const nmy_num\* y,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_mul (nmy_num\* z, const nmy_num\* x, const nmy_num\* y,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_div (nmy_num\* z, const nmy_num\* x, const nmy_num\* y,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_sqrt(nmy_num\* z, const nmy_num\* x,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_exp (nmy_num\* z, const nmy_num\* x,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
nmy_status nmy_log (nmy_num\* z, const nmy_num\* x,  
uint64_t prec_bits, nmy_round rnd, nmy_ctx\* ctx);  
<br/>nmy_status nmy_add_interval(nmy_interval\* z, const nmy_interval\* x, const nmy_interval\* y,  
uint64_t prec_bits, nmy_ctx\* ctx);  
int nmy_cmp(const nmy_num\* x, const nmy_num\* y, nmy_ctx\* ctx);  
char\* nmy_format(const nmy_num\* x, int base, size_t max_chars, nmy_ctx\* ctx);

The corresponding higher-level bindings should raise host-language exceptions only for genuine programmer errors or hard resource failures. Numerical conditions such as inexactness, cancellation, or representation escalation should stay in the status word so callers can write deterministic numerical code. This is one of the biggest lessons from MPFR's flag model and Arb's careful distinction between approximate values and rigorous enclosures. [\[42\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html)

For Mathematica integration, the preferred path is a **LibraryLink** binding for in-process speed plus a **WSTP** fallback for out-of-process isolation and rich symbolic exchange. LibraryLink explicitly supports direct dynamic-library loading, arbitrary Wolfram expressions, and memory-managed library expressions; WSTP is the native symbolic transfer protocol for communication between external programs and the Wolfram engine. That combination is enough to expose a NummyObject wrapper and a handful of performance-critical entry points such as NummyExp, NummyLog, NummyAdd, and NummyInterval. [\[43\]](https://reference.wolfram.com/language/guide/LibraryLink.html)

For Maple integration, there are two viable routes with official support. define_external and wrapper libraries are appropriate for fast calls into a compiled Nummy shared library from Maple code. OpenMaple is appropriate when Nummy must also manipulate Maple-native data structures or run as a richer external session. Maple's documentation is unusually explicit here: define_external links external functions from shared libraries, and OpenMaple provides a C, Java, Python, and VB API for starting a Maple session, evaluating commands, and manipulating Maple data structures. [\[44\]](https://www.maplesoft.com/support/help/Maple/view.aspx?path=OpenMaple)

For Sage integration, the practical answer is a Python binding backed by Cython or a comparable Python extension mechanism. Sage already rides on Python, MPFR, MPFI, and Arb/FLINT, and its own external-package documentation emphasizes Cython as the natural tool for wrapping external C libraries efficiently. A Sage binding should therefore expose NummyReal, NummyBall, and conversion methods to/from RealField, RealIntervalField, and RealBallField. [\[45\]](https://doc.sagemath.org/html/en/reference/rings_numerical/index.html)

## Testing, security, roadmap, and migration

The testing strategy should be tri-modal. First, Nummy should use **differential testing** against MPFR and Arb/FLINT whenever a case stays inside ordinary exponent and precision ranges. Second, it should use **property-based and metamorphic tests** for invariants that do not require a reference oracle: commutativity where applicable, monotonicity under directed rounding, interval containment, exactness of dyadic scaling, and representation round-trips. Third, it should use **proof-oriented testing** for the exponent subsystem: sparse exponent ordering, canonicalization, recursive carry behavior, parity, and serialization. The inspected repository already demonstrates the value of small, focused unit tests around the exponent layer; Nummy needs much more of that, plus randomized adversarial generation. [\[6\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs) [\[42\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html)

A serious benchmark plan should cover at least four regimes: ordinary high precision, huge dense exponents, sparse/tower exponents, and rigorous-enclosure mode. A representative matrix is:

| Case family                      | Host weakness targeted                     | Example benchmark idea                                               | Expected Nummy behavior                                 |
| -------------------------------- | ------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------- |
| Hidden-zero / cancellation       | Precision collapse despite extra precision | near-cancelling subtraction, rationalized vs unrationalized formulas | detect cancellation; optionally widen to enclosure mode |
| Extreme positive scale           | overflow / impractical exponent handling   | iterated exponentials and power towers                               | stay finite in elevated representation                  |
| Extreme negative scale           | underflow / accidental zeroing             | inverse power towers, repeated logarithmic descent                   | represent tiny magnitudes symmetrically                 |
| Directed rounding                | interval correctness                       | compare lower/upper endpoint arithmetic                              | guaranteed enclosure                                    |
| Special functions at large scale | unstable asymptotics                       | scaled gamma/Bessel/loggamma tests                                   | use asymptotic or enclosure kernels                     |

The Wolfram documentation on hidden zeros and finite extra precision, the MPFR/Sage documentation on exponent bounds and subnormal handling, and the Arb/FLINT ball model are the best documented motivations for this matrix. [\[46\]](https://mathworld.wolfram.com/HiddenZero.html)

On security and robustness, the biggest risks are **denial of service by scale**, **runaway formatting**, **unbounded series or interval refinement**, and **deep recursive exponent shapes**. Nummy therefore needs explicit resource limits in the context object: maximum significand limbs, maximum exponent-tree nodes, maximum print length, maximum allowed precision escalation, maximum series terms, and maximum interval-refinement iterations. All entry points should be deterministic under budget exhaustion and return structured error statuses instead of partial garbage or process aborts. This is especially important for CAS integration, where users can accidentally create adversarial workloads through symbolic expansion. No citation is needed here because this is a direct engineering prescription.

A realistic implementation roadmap, assuming no language constraint and a small expert team, is:

| Milestone            | Scope                                                                           | Estimated effort  |
| -------------------- | ------------------------------------------------------------------------------- | ----------------- |
| Foundation           | HugeExpInt, dense binary core, normalization, add/sub/mul, formatting, statuses | 2-3 person-months |
| Core numerics        | div, sqrt, compare, conversions, directed rounding, interval sidecar skeleton   | 2-3 person-months |
| Scale elevation      | sparse exponent mode, tower/SLI mode, promotion/demotion rules                  | 3-4 person-months |
| Elementary functions | exp, log, pow, expm1/log1p-style stable kernels, enclosure versions             | 3-5 person-months |
| CAS bindings         | C ABI stabilization, Mathematica/Maple/Sage wrappers, packaging, serialization  | 2-3 person-months |
| Hardening            | fuzzing, differential tests, large-scale benchmarks, docs, policy controls      | 2-4 person-months |

So a credible first useful release is roughly **6-9 person-months**, while a robust "research-grade but usable" release is more like **12-18 person-months**. The span is wide because the hard part is not big-number arithmetic itself; it is the correctness and ergonomics of the representation transitions.

For migration, CAS users should be encouraged to start with **adapter functions rather than global replacement**. In the Wolfram environment, the safest inputs are exact integers, rationals, or explicit-precision strings, not machine-precision decimals, because SetPrecision on machine numbers exposes hidden binary digits before padding. In Maple, prefer mantissa/exponent or exact-rational interchange over decimal text when possible. In Sage, expose Python objects that convert cleanly to RealField and RealBallField when the result re-enters ordinary precision territory. The first migration targets should be operations that are both high-value and numerically fragile: Exp, Log, Power, near-cancelling subtraction, scaled special functions, and any workload involving exponent towers or repeated logs/exponentials. [\[47\]](https://reference.wolfram.com/language/ref/SetPrecision.html)

## Open questions and limitations

The main unresolved architectural question is whether Nummy should treat SLI as a **first-class user-visible format** or only as an **internal escape representation**. The evidence strongly supports using LI/SLI ideas, but it does not force a public SLI-facing API. My recommendation is to keep SLI internal at first and expose it publicly only if the transition rules become predictable enough for users to reason about. [\[34\]](https://epubs.siam.org/doi/10.1137/0724034)

A second open question is how far Nummy should go toward **exact real** semantics versus **pragmatic enclosure semantics**. Sage already offers both approximate MPFR reals and interval/ball variants, and Arb/FLINT demonstrates that rigorous enclosures can be made fast enough to be practical. Nummy should almost certainly support enclosures, but it does not need to promise a full constructive-real framework in its first generations. [\[48\]](https://doc.sagemath.org/html/en/reference/rings_numerical/index.html)

A final limitation of this report is empirical: the benchmark cases and integration plan are proposed from source analysis and official documentation, but the report did **not** execute live Mathematica, Maple, or Sage sessions. The architectural recommendations are still high-confidence because they rest on inspected repository code and on primary or official documentation for the host systems and major numeric libraries, but raw performance numbers remain to be measured.

[\[1\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/README.md) README.md

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/README.md>

[\[2\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[23\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) [\[27\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs) SparseInteger.cs

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseInteger.cs>

[\[3\]](https://epubs.siam.org/doi/10.1137/0724034) [\[8\]](https://epubs.siam.org/doi/10.1137/0724034) [\[22\]](https://epubs.siam.org/doi/10.1137/0724034) [\[24\]](https://epubs.siam.org/doi/10.1137/0724034) [\[28\]](https://epubs.siam.org/doi/10.1137/0724034) [\[30\]](https://epubs.siam.org/doi/10.1137/0724034) [\[34\]](https://epubs.siam.org/doi/10.1137/0724034) [\[38\]](https://epubs.siam.org/doi/10.1137/0724034) <https://epubs.siam.org/doi/10.1137/0724034>

<https://epubs.siam.org/doi/10.1137/0724034>

[\[12\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseNumerics.csproj) SparseNumerics.csproj

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/SparseNumerics.csproj>

[\[5\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/ArrayHelpers.cs) ArrayHelpers.cs

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics/ArrayHelpers.cs>

[\[6\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs) [\[25\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs) SparseIntegerTests.cs

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseIntegerTests.cs>

[\[7\]](https://flintlib.org/doc/arb.html) [\[37\]](https://flintlib.org/doc/arb.html) <https://flintlib.org/doc/arb.html>

<https://flintlib.org/doc/arb.html>

[\[9\]](https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors) [\[41\]](https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors) <https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors>

<https://www.researchgate.net/publication/319411961_Multiple_Precision_Floating-Point_Arithmetic_on_SIMD_Processors>

[\[10\]](https://reference.wolfram.com/language/guide/LibraryLink.html) [\[43\]](https://reference.wolfram.com/language/guide/LibraryLink.html) <https://reference.wolfram.com/language/guide/LibraryLink.html>

<https://reference.wolfram.com/language/guide/LibraryLink.html>

[\[11\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html) [\[36\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html) [\[42\]](https://www.mpfr.org/mpfr-4.2.1/mpfr.html) <https://www.mpfr.org/mpfr-4.2.1/mpfr.html>

<https://www.mpfr.org/mpfr-4.2.1/mpfr.html>

[\[13\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.sln) SparseNumerics.sln

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.sln>

[\[14\]](https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseNumerics.Tests.csproj) SparseNumerics.Tests.csproj

<https://github.com/VladimirReshetnikov/SparseNumerics/blob/master/SparseNumerics.Tests/SparseNumerics.Tests.csproj>

[\[15\]](https://oeis.org/A002845) <https://oeis.org/A002845>

<https://oeis.org/A002845>

[\[16\]](https://reference.wolfram.com/language/ref/Overflow.html?view=all) [\[31\]](https://reference.wolfram.com/language/ref/Overflow.html?view=all) <https://reference.wolfram.com/language/ref/Overflow.html?view=all>

<https://reference.wolfram.com/language/ref/Overflow.html?view=all>

[\[17\]](https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html) [\[21\]](https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html) <https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html>

<https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html>

[\[18\]](https://www.maplesoft.com/support/help/maple/view.aspx?path=float) <https://www.maplesoft.com/support/help/maple/view.aspx?path=float>

<https://www.maplesoft.com/support/help/maple/view.aspx?path=float>

[\[19\]](https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html) [\[32\]](https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html) <https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html>

<https://doc.sagemath.org/html/en/reference/rings_numerical/sage/rings/real_mpfr.html>

[\[20\]](https://gmplib.org/manual/Floating_002dpoint-Functions.html) <https://gmplib.org/manual/Floating_002dpoint-Functions.html>

<https://gmplib.org/manual/Floating_002dpoint-Functions.html>

[\[26\]](https://www.mpfr.org/algo.html) [\[33\]](https://www.mpfr.org/algo.html) [\[39\]](https://www.mpfr.org/algo.html) [\[40\]](https://www.mpfr.org/algo.html) <https://www.mpfr.org/algo.html>

<https://www.mpfr.org/algo.html>

[\[29\]](https://www.intel.com/content/www/us/en/docs/programmable/683374/17-1/block-floating-point-scaling.html) <https://www.intel.com/content/www/us/en/docs/programmable/683374/17-1/block-floating-point-scaling.html>

<https://www.intel.com/content/www/us/en/docs/programmable/683374/17-1/block-floating-point-scaling.html>

[\[35\]](https://arblib.org/index.html) <https://arblib.org/index.html>

<https://arblib.org/index.html>

[\[44\]](https://www.maplesoft.com/support/help/Maple/view.aspx?path=OpenMaple) <https://www.maplesoft.com/support/help/Maple/view.aspx?path=OpenMaple>

<https://www.maplesoft.com/support/help/Maple/view.aspx?path=OpenMaple>

[\[45\]](https://doc.sagemath.org/html/en/reference/rings_numerical/index.html) [\[48\]](https://doc.sagemath.org/html/en/reference/rings_numerical/index.html) <https://doc.sagemath.org/html/en/reference/rings_numerical/index.html>

<https://doc.sagemath.org/html/en/reference/rings_numerical/index.html>

[\[46\]](https://mathworld.wolfram.com/HiddenZero.html) <https://mathworld.wolfram.com/HiddenZero.html>

<https://mathworld.wolfram.com/HiddenZero.html>

[\[47\]](https://reference.wolfram.com/language/ref/SetPrecision.html) <https://reference.wolfram.com/language/ref/SetPrecision.html>

<https://reference.wolfram.com/language/ref/SetPrecision.html>