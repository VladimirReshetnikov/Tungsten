# Shortcomings of Floating-Point Arithmetic in Modern CAS

Created (UTC): 2026-04-28T00:51:50Z

Repository HEAD: 2689dffeee9f9c16d9e3cbe4bfd55ef011ecdf82

Document type: descriptive design report.

## Purpose

Modern computer algebra systems are excellent at exact symbolic computation,
arbitrary-precision evaluation, simplification, special functions, and mixed
symbolic-numeric workflows. This document is not an argument that Mathematica,
Maple, Sage, SymPy, Maxima, or similar systems are poorly engineered.

The narrower claim is this: their floating-point models are still mostly
conventional mantissa/exponent systems wrapped in a symbolic environment. They
can raise precision, track some uncertainty, call high-quality libraries, and
fall back to exact forms, but they do not usually make magnitude scale a
first-class alternative coordinate system. That matters for Nummy because Nummy
is interested in overflow-resistant arithmetic for extremely large and tiny
values, including level-index, symmetric level-index, and power-tower-style
representations.

In other words, a CAS is often very good at "compute this expression to more
digits." Nummy is exploring "represent and operate on values whose ordinary
digits may be the wrong object to store."

## The Common CAS Numeric Tower

Most CAS numeric towers have several layers:

- exact integers and rationals;
- symbolic expressions;
- machine floating-point numbers, usually backed by hardware double precision;
- software arbitrary-precision floating-point numbers;
- intervals, balls, or other validated numeric forms in some systems;
- special values such as infinities, undefined/NaN-like values, and signed
  zeros.

Wolfram Language documentation is unusually explicit about this split. It
distinguishes exact numbers, machine-precision approximate numbers, and
arbitrary-precision approximate numbers. It also documents that machine
precision is the default in many numerical contexts and that machine numbers
are fast but do not track precision loss. Wolfram's arbitrary-precision numbers
carry significance information, while machine numbers are fixed-precision
hardware values.

Maple has a similar split between software floating-point values and hardware
floating-point values. Maple software floats are represented as a decimal
mantissa/exponent pair, while hardware floats are a separate format used for
speed-oriented numeric computation. Maple's `Digits` setting controls the
mantissa length for software floating-point arithmetic, with a default of 10.

Sage exposes fixed-precision real/complex double fields and arbitrary-precision
real/complex fields backed by MPFR, GMP, MPC, and related libraries. SymPy's
`evalf` and `N` evaluate exact expressions to decimal approximations and
support arbitrary precision, with a default approximate output around the usual
15 decimal digits. Maxima similarly distinguishes ordinary floating point from
`bigfloat`, with `fpprec` controlling significant digits for bigfloat arithmetic
but not ordinary floating-point computations.

These designs are practical and mature. The limitation is that they keep the
ordinary floating-point mental model at the center.

## Shortcoming 1: Machine Precision Is A Fast Path, Not A Reliability Contract

CAS users often assume that because a system is symbolic, numerical results are
automatically protected from ordinary floating-point hazards. That is not true
when machine numbers enter the computation.

In Wolfram Language, machine-precision computations use native floating-point
hardware and low-level numerical libraries. The documentation states that this
path is fast and does not track precision loss from roundoff and related
effects. The same documentation warns that machine arithmetic may produce
numerically unvalidated results and that those results can differ substantially
from correct values.

That is a serious semantic split:

- exact symbolic expressions have algebraic meaning;
- arbitrary-precision expressions can carry precision metadata;
- machine expressions are fast approximate values with no internal proof that
  their displayed digits are justified.

The practical failure mode is familiar. A single machine literal can pull a
larger expression into a machine-precision evaluation path. Once that happens,
the symbolic environment does not magically recover the lost information.

For Nummy, this is a warning: a range-first number type should not be a quiet
fast path that pretends to have the same contract as exact or
arbitrary-precision arithmetic. Its approximation semantics should be visible.

## Shortcoming 2: "Arbitrary Precision" Usually Means A Bigger Mantissa

Arbitrary precision in a CAS is often the right tool when the user needs more
digits. But increasing the number of digits is not the same thing as changing
the coordinate system.

A conventional arbitrary-precision float still stores something like:

```text
sign * mantissa * base^exponent
```

with a mantissa that can grow to many digits. That is excellent for constants,
roots, special functions, and exact-expression numerical evaluation. It is not
excellent for values whose number of digits is itself astronomical.

For example, storing a googolplex as ordinary decimal digits is impossible in
any literal sense. Even if a CAS can represent `10^(10^100)` symbolically, its
floating-point approximation model is not designed to preserve arithmetic over
that value as a normalized scale object. It can avoid materializing the value
only by keeping it symbolic or by reducing it into a logarithmic expression
chosen by the user or algorithm.

SLI and power-tower systems make a different commitment. They store a level or
layer coordinate. They accept that ordinary relative precision decays at high
magnitude, and in exchange they make extreme scale representable as data.

## Shortcoming 3: Overflow And Underflow Are Still Operational States

CAS arbitrary precision can greatly reduce overflow and underflow in many
ordinary calculations, but conventional floating-point formats still have
finite representable ranges. Machine paths certainly do, and software
floating-point systems still define infinities or overflow behavior.

Maple's `Float(infinity)` documentation makes the point cleanly: a
floating-point infinity can indicate a value too large for the format, not
mathematical infinity. Maple's numeric environment also exposes underflow,
overflow, undefined, signed zero, and event-handling machinery.

Wolfram's machine-precision documentation likewise says that machine numbers
have independently stored exponents and significands, but their scale remains
constrained by the possible exponent range. Wolfram's arbitrary-precision
settings also expose system-dependent maximum usable precision and extra
precision controls.

The result is that most CAS systems have good tools for managing overflow, but
overflow remains something to manage. Level-index and SLI arithmetic attack a
different problem: move the representation boundary so that crossing an
ordinary exponent limit becomes a level transition rather than an exceptional
event.

## Shortcoming 4: Precision Tracking Is Often Local To The Representation

Wolfram's significance arithmetic is one of the stronger mainstream precision
tracking systems. Its documentation describes arbitrary-precision numbers as
having known digits followed by unknown digits, and it propagates that
uncertainty so returned digits are justified by input precision. It also
documents precision loss under cancellation and notes that the precision of a
function's output can depend on the input in complicated ways.

That is valuable, but it is still not a universal validation layer:

- machine precision does not carry the same tracking;
- internal algorithms may need extra guard digits;
- global controls such as `$MaxExtraPrecision` can limit whether enough
  internal precision is available;
- hidden zeros and ill-conditioned forms can defeat purely numeric effort;
- fixed-precision modes can be faster but can report wrong trailing digits.

This is not a criticism of Wolfram specifically. It is the natural shape of a
system that tries to serve exact symbolic work, fast machine numerics,
arbitrary precision, plotting, compiled code, and numerical analysis in one
language.

For Nummy, the lesson is that "precision" should not be a single scalar bolted
onto every value. SLI-style values have at least two distinct stories:
magnitude-coordinate precision and ordinary-value precision. They should not be
confused.

## Shortcoming 5: Mixed Exact/Inexact Evaluation Is Semantically Fragile

CAS systems must decide what happens when exact and approximate values mix.
The usual answer is useful but sharp-edged: approximate inputs tend to make
approximate outputs.

In Wolfram Language, `N[expr]` gives machine precision by default, while
`N[expr, n]` requests an `n`-digit result. If a computation already contains
machine-precision numbers, the computation is typically done at machine
precision. Wolfram also documents a subtle distinction between requesting the
symbol `MachinePrecision` and requesting the numeric value of `$MachinePrecision`.

In Maple, the presence of a floating-point number generally implies
floating-point evaluation, and `evalf` forces computation in the floating-point
domain. In Maxima, ordinary floats and bigfloats have separate precision
controls. In SymPy, exact expressions can be evaluated to arbitrary precision,
but expressions already containing low-precision floats can carry that history.

The user experience is a recurring trap:

```text
exact expression -> high precision works
same expression with one approximate literal -> high precision may be gone
```

Nummy should avoid making literal syntax or a single mixed operand silently
change the semantic class of an entire computation without an explicit rule.

## Shortcoming 6: Cancellation Is Recognized But Not Eliminated

Cancellation is not a bug in CAS arithmetic. It is a mathematical fact. If two
nearly equal approximate quantities are subtracted, leading digits cancel and
the result depends on lower digits that may not be known.

Wolfram documentation explicitly discusses this precision degradation and uses
subtraction of close numbers as a typical case. Machine arithmetic is worse
because it keeps returning machine-precision-looking numbers even when the
input does not justify all displayed digits.

CAS systems can sometimes avoid cancellation symbolically:

```text
(x^2 - y^2) / (x - y)  ->  x + y
```

But that only works when the expression remains symbolic and the simplifier
finds an applicable transformation. Once an expression has entered a numeric
black box, cancellation becomes a numeric-algorithm responsibility.

In SLI and power-tower arithmetic, addition and subtraction are exactly the
hard operations. This should shape Nummy's design from the start. A huge-range
type that makes multiplication pleasant but hides cancellation risk would
repeat a familiar CAS mistake in a new coordinate system.

## Shortcoming 7: Special Values Mix Mathematical And Operational Meaning

CAS systems often have both symbolic infinities and floating-point infinities.
They also have undefined or NaN-like values, signed zeros, complex infinities,
and branch-cut conventions. These are necessary, but they blur two meanings:

- a mathematical object such as infinity in an extended domain;
- an operational artifact such as overflow, invalid operation, or an
  unrepresentable intermediate result.

Maple explicitly says its floating-point infinity can represent a value too
large for the format and does not necessarily represent mathematical infinity.
Wolfram distinguishes exact, approximate, indeterminate, infinite, and
machine-level behavior across several contexts.

This is a hard problem for any CAS because symbolic and numeric semantics are
interleaved. For Nummy, the useful design pressure is to keep operational
states explicit:

- out-of-range for this representation;
- mathematically infinite;
- unknown because precision was exhausted;
- invalid operation;
- signed zero or reciprocal-side zero convention.

Those should not collapse into one vaguely infinite-looking state.

## Shortcoming 8: Performance Incentives Pull Toward Hardware Doubles

Machine floating point remains attractive because it is fast. Wolfram uses
machine precision by default in many numerical and graphical functions. Maple
uses hardware floats in contexts such as rtables and can route linear algebra
to numeric libraries for efficiency. Sage exposes optimized double fields in
addition to arbitrary-precision MPFR-backed fields.

This is rational engineering. It is also why CAS numerical behavior often has
two personalities:

- fast, hardware-backed, weakly tracked machine arithmetic;
- slower, software-backed, better tracked arbitrary precision.

Users can usually request more precision, but that is not the same as a uniform
numeric abstraction. Some algorithms, compiled paths, library calls, plotting
paths, and data containers are optimized around machine numbers.

Nummy should expect the same pressure. If it offers both fast approximate and
range-first semantics, the boundary must be explicit enough that users know
which contract they are exercising.

## Shortcoming 9: CAS Precision Knobs Are Global Or Algorithmic

Many CAS precision controls are global settings, dynamic settings, or options
to evaluation functions:

- Wolfram has `WorkingPrecision`, `PrecisionGoal`, `$MaxExtraPrecision`,
  `$MaxPrecision`, and related settings.
- Maple uses `Digits`, `Rounding`, `UseHardwareFloats`, and event handlers.
- Maxima uses `fpprec` for bigfloat arithmetic.
- SymPy uses requested digits in `evalf` or `N`.
- Sage uses field objects such as `RealField(prec)`.

These controls are useful. Their weakness is that the precision policy often
lives outside the value. Two values that print similarly may have arrived
through different numeric regimes. Two calls to the same expression can differ
because a global or dynamic option changed.

For Nummy, it may be better to treat representation, working precision,
display precision, uncertainty policy, and overflow policy as distinct axes.
They can have defaults, but they should not be mistaken for one another.

## Shortcoming 10: There Is No Native "Scale Algebra"

The main missing abstraction is scale algebra.

CAS systems can represent expressions such as:

```text
Exp[Exp[Exp[x]]]
10^(10^100)
PowerTower[10, n]    // if provided by a package or user code
```

But these are usually symbolic expressions or ordinary numeric expressions, not
members of a numeric type whose operations are defined directly on scale
coordinates.

SLI, LI, and power-tower systems make scale algebra concrete:

- logarithm moves down a level;
- exponential moves up a level;
- reciprocal flips a symmetry bit;
- multiplication and division become lower-level operations;
- addition and subtraction are explicit hard cases;
- formatting follows the level/layer structure.

That is exactly the territory Nummy is investigating. The point is not to
replace CAS systems. The point is to provide a numeric substrate with a
different center of gravity.

## Implications For Nummy

A Nummy design should learn from CAS systems without copying their numeric
layer wholesale.

Recommended design principles:

- Keep exact, conventional floating-point, arbitrary-precision, interval, and
  SLI-like values semantically distinct.
- Make conversions explicit, especially conversions from exact or high
  precision into a range-first representation.
- Separate magnitude-coordinate precision from ordinary relative precision.
- Treat overflow, mathematical infinity, invalid operation, and exhausted
  precision as different states.
- Document addition, subtraction, and cancellation as primary design risks, not
  edge cases.
- Avoid global precision settings as the only control surface. Prefer
  operation-local or context-local policies that can be inspected.
- Make display notation honest about what is known. A pretty decimal prefix can
  be actively misleading for high-level values.
- Preserve links to symbolic forms when possible, but do not require every
  value to remain a symbolic expression.

The key positive lesson from CAS systems is that users need multiple numeric
regimes. The key negative lesson is that once those regimes mix silently, the
meaning of a result can become difficult to audit.

## References

- Wolfram Language, [Numbers](https://reference.wolfram.com/language/tutorial/Numbers.html?view=all).
- Wolfram Language, [MachinePrecision](https://reference.wolfram.com/language/ref/MachinePrecision.html).
- Wolfram Language, [$MaxExtraPrecision](https://reference.wolfram.com/language/ref/%24MaxExtraPrecision.html).
- Wolfram Language, [$MaxPrecision](https://reference.wolfram.com/language/ref/%24MaxPrecision.html).
- Maple Help, [Software Floating-point Numbers and Their Constructors](https://www.maplesoft.com/support/help/maple/view.aspx?path=float).
- Maple Help, [Maple Numerics Overview](https://www.maplesoft.com/support/help/maple/view.aspx?path=numerics).
- SymPy documentation, [Numerical Evaluation](https://docs.sympy.org/latest/modules/evalf.html).
- SageMath documentation, [Fixed and Arbitrary Precision Numerical Fields](https://doc.sagemath.org/html/en/reference/rings_numerical/index.html).
- Maxima Manual, [Floating Point](https://maxima.sourceforge.io/docs/manual/maxima_singlepage.html).
- Nummy, [Symmetric Level-Index Arithmetic: An Accessible Introduction](../theory/symmetric-level-index-arithmetic-introduction__316e449481ec.md).
