# SLI Arithmetic (Wikipedia)

This is a Markdown rendering of the local Wikipedia source snapshot for the
article on symmetric level-index arithmetic.

The **level-index** (**LI**) representation of numbers, and its
[algorithms](https://en.wikipedia.org/wiki/Algorithm) for
[arithmetic](https://en.wikipedia.org/wiki/Floating-point_arithmetic)
operations, were introduced by
[Charles Clenshaw](https://en.wikipedia.org/wiki/Charles_Clenshaw) and
[Frank Olver](https://en.wikipedia.org/wiki/Frank_William_John_Olver) in
1984.[^clenshaw-olver-1984]

The symmetric form of the LI system and its arithmetic operations were
presented by Clenshaw and Peter Turner in 1987.[^clenshaw-turner-1988]

Michael Anuta, Daniel Lozier, Nicolas Schabanel, and Turner developed the
algorithm for **symmetric level-index** (**SLI**) arithmetic, and a parallel
implementation of it. There has been extensive work on developing the SLI
arithmetic algorithms and extending them to
[complex](https://en.wikipedia.org/wiki/Complex_number) and
[vector](https://en.wikipedia.org/wiki/Vector_(mathematics_and_physics))
arithmetic operations.

## Definition

The idea of the level-index system is to represent a non-negative
[real number](https://en.wikipedia.org/wiki/Real_number) $X$ as

$$
X = e^{e^{e^{\cdots^{e^f}}}},
$$

where $0 \leq f < 1$, and the process of exponentiation is performed $\ell$
times, with $\ell \geq 0$. $\ell$ and $f$ are the **level** and **index** of
$X$, respectively. $x = \ell + f$ is the LI image of $X$. For example,

$$
X = 1234567 = e^{e^{e^{0.9711308}}},
$$

so its LI image is

$$
x = \ell + f = 3 + 0.9711308 = 3.9711308.
$$

The symmetric form is used to allow negative exponents if the magnitude of $X$
is less than 1. One takes $\operatorname{sgn}(\log X)$ or
$\operatorname{sgn}(|X| - |X|^{-1})$ and stores it as the reciprocal sign
$r_X$, after substituting $+1$ for $0$. Since for $X = 1 = e^0$ the LI image is
$x = 1.0$ and uniquely defines $X = 1$, the representation can avoid a third
reciprocal-sign state and use only one bit for the two states $-1$ and $+1$.
Mathematically, this is equivalent to taking the
[reciprocal](https://en.wikipedia.org/wiki/Multiplicative_inverse) of a
small-magnitude number, and then finding the SLI image for the reciprocal.
Using one bit for the reciprocal sign enables the representation of extremely
small numbers.

A [sign bit](https://en.wikipedia.org/wiki/Sign_bit) may also be used to allow
negative numbers. One takes $\operatorname{sgn}(X)$ and stores it as the sign
$s_X$, after substituting $+1$ for $0$. Since for $X = 0$ the LI image is
$x = 0.0$ and uniquely defines $X = 0$, the representation can avoid a third
sign state and use only one bit for the two states $-1$ and $+1$.
Mathematically, this is equivalent to taking the inverse (additive inverse) of
a negative number, and then finding the SLI image for the inverse. Using one
bit for the sign enables the representation of negative numbers.

The mapping function is called the **generalized logarithm function**. It is
defined as

$$
\psi(X) =
\begin{cases}
X & \text{if } 0 \leq X < 1, \\
1 + \psi(\ln X) & \text{if } X \geq 1,
\end{cases}
$$

and it maps $[0, \infty)$ onto itself monotonically, thus being invertible on
this interval. The inverse, the **generalized exponential function**, is
defined by

$$
\varphi(x) =
\begin{cases}
x & \text{if } 0 \leq x < 1, \\
e^{\varphi(x - 1)} & \text{if } x \geq 1.
\end{cases}
$$

The density of values $X$ represented by $x$ has no discontinuities as we go
from level $\ell$ to $\ell + 1$, since

$$
\left.\frac{d\varphi(x)}{dx}\right|_{x=1}
= \left.\frac{d\varphi(e^x)}{dx}\right|_{x=0}.
$$

The generalized logarithm function is closely related to the
[iterated logarithm](https://en.wikipedia.org/wiki/Iterated_logarithm) used in
computer-science analysis of algorithms.

Formally, we can define the SLI representation for an arbitrary real $X$ (not
0 or 1) as

$$
X = s_X\varphi(x)^{r_X},
$$

where $s_X$ is the sign of $X$, and $r_X$ is the reciprocal sign as in the
following equations:

$$
s_X = \operatorname{sgn}(X),\quad
r_X = \operatorname{sgn}\big(|X| - |X|^{-1}\big),\quad
x = \psi\big(\max\big(|X|, |X|^{-1}\big)\big)
  = \psi\big(|X|^{r_X}\big).
$$

For $X = 0$ or $X = 1$, we have

$$
s_0 = +1,\quad r_0 = +1,\quad x = 0.0,
$$

and

$$
s_1 = +1,\quad r_1 = +1,\quad x = 1.0.
$$

For example,

$$
X = -\frac{1}{1234567} = -e^{-e^{e^{0.9711308}}},
$$

and its SLI representation is

$$
x = -\varphi(3.9711308)^{-1}.
$$

## See Also

- [Tetration](https://en.wikipedia.org/wiki/Tetration)
- [Floating point](https://en.wikipedia.org/wiki/Floating_point) (FP)
- [Tapered floating point](https://en.wikipedia.org/wiki/Tapered_floating_point) (TFP)
- [Logarithmic number system](https://en.wikipedia.org/wiki/Logarithmic_number_system) (LNS)
- [Level (logarithmic quantity)](https://en.wikipedia.org/wiki/Level_(logarithmic_quantity))

## References

[^clenshaw-olver-1984]: Charles William Clenshaw and Frank William John Olver,
    "Beyond Floating Point", *Journal of the ACM*, 31(2), 319–328, 1984,
    doi:[10.1145/62.322429](https://doi.org/10.1145/62.322429).

[^clenshaw-turner-1988]: Charles William Clenshaw and Peter R. Turner, "The
    Symmetric Level-Index System", *IMA Journal of Numerical Analysis*, 8(4),
    517–526, 1988-10-01,
    doi:[10.1093/imanum/8.4.517](https://doi.org/10.1093/imanum/8.4.517);
    source snapshot also cited
    [ResearchGate](https://www.researchgate.net/publication/31393487).

## Further Reading

- Charles William Clenshaw, Frank William John Olver, and Peter R. Turner,
  "Level-index arithmetic: An introductory survey", *Numerical Analysis and
  Parallel Processing*, Lecture Notes in Mathematics 1397, 95–168, 1989,
  doi:[10.1007/BFb0085718](https://doi.org/10.1007/BFb0085718).
- Charles William Clenshaw and Peter R. Turner, "Root Squaring Using
  Level-Index Arithmetic", *Computing*, 43(2), 171–185, 1989-06-23,
  doi:[10.1007/BF02241860](https://doi.org/10.1007/BF02241860).
- Eberhard Zehendner, "Rechnerarithmetik: Logarithmische Zahlensysteme",
  lecture script, Friedrich-Schiller-Universität Jena, Summer 2008, 21–22,
  [handout PDF](https://users.fmi.uni-jena.de/~nez/rechnerarithmetik_5/folien/Rechnerarithmetik.2008.09.handout.pdf),
  [archived complete PDF](https://web.archive.org/web/20180806175620/https://users.fmi.uni-jena.de/~nez/rechnerarithmetik_5/folien/Rechnerarithmetik.2008.komplett.pdf).
- Brian Hayes, "The Higher Arithmetic", *American Scientist*, 97(5), 364–368,
  September–October 2009,
  doi:[10.1511/2009.80.364](https://doi.org/10.1511/2009.80.364),
  [article](https://www.americanscientist.org/article/the-higher-arithmetic),
  [PDF](https://www.americanscientist.org/sites/americanscientist.org/files/20097301410207456-2009-09Hayes.pdf).
  Also reprinted as Chapter 8, "Higher Arithmetic", in Brian Hayes,
  *Foolproof, and Other Mathematical Meditations*, MIT Press, 2017.

## External Links

- sli-c-library (hosted by Google Code),
  ["C++ Implementation of Symmetric Level-Index Arithmetic"](http://code.google.com/p/sli-c-library/).

Original Wikipedia category:
[Computer arithmetic](https://en.wikipedia.org/wiki/Category:Computer_arithmetic).
