# Symmetric Level-Index Arithmetic: An Accessible Introduction

Created (UTC): 2026-04-28T00:36:39Z

Repository HEAD: 0ada81b39d863886de4e7bac414d8c91b8b292bf

Document type: descriptive guide.

## The Core Idea

Symmetric level-index arithmetic is a way to store real numbers by asking a
different question than ordinary floating point asks.

Floating point asks:

> What mantissa and exponent approximate this value?

Symmetric level-index arithmetic asks:

> How many logarithms does it take before this value becomes ordinary-sized,
> and what is left after those logarithms?

That sounds like a small change, but it changes the shape of the whole number
system. A double-precision float can represent numbers up to roughly `1e308`.
An SLI-style representation can climb through values like `exp(exp(exp(x)))`
without storing the digits of the value itself. Instead of trying to hold the
number, it holds a compact description of the number's position in an
iterated-exponential scale.

The payoff is enormous range. The cost is that familiar precision intuitions no
longer apply.

## Why Ordinary Floating Point Runs Out

Ordinary floating point is already a clever compromise. A value is stored as a
sign, a significand, and an exponent. That lets the same fixed-size word cover
tiny values, ordinary values, and large values.

But the exponent field is finite. When a computation grows beyond the largest
available exponent, the value overflows. When it becomes too close to zero, it
underflows. In many practical computations this is fine, but some domains
stress the boundary:

- recurrence relations that grow or shrink explosively;
- probability and combinatorics calculations with extreme intermediate values;
- tetration, power towers, and googology;
- incremental-game arithmetic where resources quickly exceed `1e308`;
- experiments where the magnitude is meaningful even when exact lower digits
  are not.

Arbitrary-precision integers and decimals solve a different problem. They keep
more digits. If the number has a trillion digits, they need storage
proportional to those digits. SLI does not try to keep all digits. It keeps the
number's large-scale structure.

## Level-Index Arithmetic First

The non-symmetric version, level-index arithmetic, starts with a generalized
exponential function. In the local source corpus this function is usually
called `phi`.

For `0 <= y < 1`:

```text
phi(y) = y
```

For `y >= 1`:

```text
phi(y) = exp(phi(y - 1))
```

So `phi` behaves like this:

```text
phi(0.5) = 0.5
phi(1.5) = exp(0.5)
phi(2.5) = exp(exp(0.5))
phi(3.5) = exp(exp(exp(0.5)))
```

The integer part of `y` is the level. The fractional part is the index. A
larger level means "one more layer of exponentiation."

The inverse function is the generalized logarithm, usually called `psi`.
Instead of applying exponentials, it repeatedly applies logarithms:

```text
psi(X) = X                 when 0 <= X < 1
psi(X) = 1 + psi(ln(X))    when X >= 1
```

In ordinary language: keep taking natural logs until the value is between `0`
and `1`; the number of logs is the level, and the final remainder is the index.

For example, the local Wikipedia snapshot gives:

```text
1234567 = exp(exp(exp(0.9711308)))
```

So its level-index image is approximately:

```text
3.9711308
```

That compact coordinate says: "level 3, index 0.9711308."

## What Symmetry Adds

Plain level-index arithmetic is naturally good at large positive values. It is
not, by itself, equally good at tiny positive values. All numbers between `0`
and `1` live in the base interval, which means an extremely tiny value is not
given the same kind of logarithmic attention as an extremely large one.

The symmetric level-index system fixes this by storing tiny values through
their reciprocals.

For a nonzero real value `X`, SLI stores:

- a sign bit, telling whether `X` is positive or negative;
- a reciprocal bit, telling whether the stored magnitude represents `|X|` or
  `1 / |X|`;
- a level-index coordinate for the larger of `|X|` and `1 / |X|`.

In formula form:

```text
X = sign * phi(x)^reciprocal
```

where:

```text
sign       is +1 or -1
reciprocal is +1 for ordinary magnitude, -1 for reciprocal magnitude
x          is the level-index coordinate
```

This gives large and small numbers matching treatment:

```text
 1234567       sign +, reciprocal +, coordinate 3.9711308
 1 / 1234567   sign +, reciprocal -, coordinate 3.9711308
-1 / 1234567   sign -, reciprocal -, coordinate 3.9711308
```

Zero and one need special handling because the sign/reciprocal description has
natural redundancies there. That is not unusual; ordinary floating point also
has special encodings for zero, infinities, and NaN.

## The Mental Model

Think of the SLI coordinate as a place on a very stretched ruler.

Near ordinary values, the ruler behaves somewhat like ordinary arithmetic.
Further out, each extra unit of level represents another exponential layer.
Moving from level 2 to level 3 is not like adding another decimal digit. It is
like saying, "the logarithm was still too large, so take another logarithm."

That is why SLI is so resistant to overflow. A value that would be impossible
to write down explicitly may only need a small level and an index.

But the ruler is stretched unevenly in ordinary-number space. A small change in
the SLI coordinate at high level corresponds to an enormous change in the
represented real value. SLI preserves information in the generalized-log
coordinate, not in ordinary decimal digits.

## What Arithmetic Feels Like

Some operations become conceptually natural.

Comparisons are usually straightforward: compare signs, reciprocal states,
levels, and indexes in the right order.

Multiplication and division fit the representation better than addition because
logs turn multiplication into addition. At sufficiently high levels, multiplying
two values may look like adding lower-level coordinates.

Exponentials and logarithms are also natural because SLI is built out of
iterated exponentials and logarithms. Taking a log often means moving down a
level. Taking an exponential often means moving up a level.

Addition and subtraction are the awkward operations.

The reason is familiar from scientific notation, but much stronger. In ordinary
floating point:

```text
1e100 + 1
```

rounds to `1e100` if the format cannot see the small addend. In SLI, the gaps
between representable values at high levels can be vastly larger. Adding a
small-enough number to a huge number may be mathematically real but
representationally invisible.

The Clenshaw-Turner SLI paper divides addition/subtraction into large, mixed,
and small cases depending on whether the operands are ordinary-magnitude or
reciprocal-magnitude values. A good implementation cannot just convert
everything back to ordinary floats. It has to do the arithmetic in the
level-index representation and handle "flip-over" cases where a result crosses
between ordinary and reciprocal form.

## Precision: The Trade-Off You Must Not Forget

SLI is not "bigger floating point with no downside." It is a different
precision contract.

Ordinary floating point approximately preserves a fixed relative precision over
much of its normal range. SLI preserves a fixed-ish precision in the
generalized-log coordinate. As the represented magnitude grows, ordinary
relative precision degrades.

That is exactly why SLI can represent values with absurd magnitudes in a fixed
amount of storage. It does not carry all the trailing digits. It carries enough
information to locate the value on an iterated-log scale.

This is a good trade when:

- overflow or underflow would otherwise destroy the computation;
- the order of magnitude is more important than exact low-order digits;
- logarithms, exponentials, products, quotients, powers, or recurrence growth
  dominate the workload;
- exact integer identity is not required.

It is a bad trade when:

- exact digits matter;
- modular arithmetic or exact divisibility matters;
- cancellation between nearly equal values is common and important;
- users expect ordinary floating-point relative-error behavior everywhere.

## Relation To Nearby Number Systems

SLI sits near several neighboring ideas.

Floating point uses one exponent level. It is fast, hardware-supported, and
excellent for most numerical work, but it has a finite exponent range.

Arbitrary precision uses more storage to keep more digits. It is the right tool
when exactness or many correct digits matter, but it cannot explicitly store
numbers whose digit count is itself astronomically large.

Logarithmic number systems store something like `log(X)`. They make
multiplication and division easy, but addition and subtraction harder. LI and
SLI can be seen as iterated-logarithm systems that keep going past one log.

Power-tower libraries such as Hypercalc and break_eternity.js use a practical
base-10 cousin of the same idea: a layer or tower height plus a magnitude. They
are often engineered for speed, formatting, and game simulation rather than for
the exact academic SLI model.

Array-based googology libraries such as OmegaNum.js go even further by encoding
higher hyperoperation layers. They are useful references when fixed tower
height stops being enough.

## What This Means For Nummy

For Nummy, SLI is most useful as a design lens:

- It gives a principled model for overflow-resistant real arithmetic.
- It explains why reciprocal symmetry matters for tiny values, not only huge
  values.
- It warns that addition, subtraction, cancellation, and exactness are the hard
  parts.
- It separates "range" from "precision" in a way an implementation must expose
  honestly.
- It suggests that formatting and parsing are not cosmetic; notation is part
  of making values understandable at extreme scale.

A Nummy implementation influenced by SLI should make its contract explicit. It
should not pretend to be arbitrary precision. It should say which operations
are approximate, which are exact special cases, how zero and one are encoded,
how NaN/infinity-like states are represented if they exist, and what users
should expect when adding values at very different levels.

## A Small Glossary

Level
: The integer part of the level-index coordinate. It counts how many nested
  exponentials are involved.

Index
: The fractional remainder after enough logarithms have been taken to bring the
  value into the base interval.

`phi`
: The generalized exponential function. It maps a level-index coordinate back
  to a real magnitude.

`psi`
: The generalized logarithm function. It maps a nonnegative real magnitude to a
  level-index coordinate.

Reciprocal bit
: The SLI marker that says the stored coordinate represents the reciprocal of
  the actual magnitude. This is what gives tiny values symmetric treatment.

Flip-over
: A transition where an arithmetic result crosses between ordinary magnitude
  and reciprocal magnitude, requiring the reciprocal bit to change.

## Local Reading Path

- [The Higher Arithmetic (Hayes)](<The Higher Arithmetic - Hayes/README.md>) is
  the friendliest motivation.
- [Beyond Floating Point (Clenshaw 1984)](<Beyond Floating Point - Clenshaw 1984/README.md>)
  introduces the level-index system and generalized logarithms.
- [The Symmetric Level-Index System (Clenshaw 1988)](<The Symmetric Level-Index System - Clenshaw 1988/README.md>)
  is the primary SLI source in this corpus.
- [Level-Index Arithmetic - An Introductory Survey (Clenshaw 1989)](<Level-Index Arithmetic - An Introductory Survey - Clenshaw 1989/README.md>)
  gives the broadest technical context.
- [Power-Tower Arithmetic and SLI in Python](<../reports/Power-Tower Arithmetic and SLI in Python.md>)
  connects SLI ideas to Hypercalc-style and Python-facing huge-number
  libraries.
