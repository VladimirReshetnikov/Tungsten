# Tungie Interval Precision Specification

Created (UTC): 2026-04-29T00:00:00Z

This document specifies the interval precision model currently implemented by
Tungie. It is intentionally a narrow implementation contract, not the full
future Nummy numeric design.

## Numeric Model

Every finite inexact number denotes a decimal interval with:

- nominal center `c`;
- absolute uncertainty radius `r`;
- accuracy `a = -log10(r)`;
- precision `p = a + log10(abs(c))` when `c != 0`.

For an inexact value whose center is zero, `Accuracy` remains meaningful and
`Precision` reports `0`. Exact integers and rationals do not carry intervals and
report `Precision` and `Accuracy` as `Infinity`.

Tungie stores precision and accuracy metadata as `Decimal` values. Certified
precision and accuracy may therefore be fractional, zero, or negative. Working
precision remains a positive integer control used by `$Precision`, `N[expr, p]`,
and Decimal evaluation contexts.

## Literal Parsing

Unmarked real literals are assigned precision equal to the larger of current
`$Precision` and the number of significant decimal digits written in the
literal. Thus ``.5`` is interpreted as ``.5`16`` by default, while a longer
literal such as ``.500000000000000000000000000000000000`` receives precision
`36`.

A single-backtick mark specifies precision:

- ``1.23`15.5`` has center `1.23`, precision `15.5`, and derived accuracy.
- ``1`-2.25`` has negative certified precision.

A double-backtick mark specifies accuracy:

- <code>1.23``20.5</code> has center `1.23`, accuracy `20.5`, and derived
  precision.

The internal radius convention is `r = 10^-a`. Tungie does not currently expose
public `Interval[...]` syntax.

## Formatting

Precision marks on output are ordinary value-space precision marks. They are
not Decimal context precision and they are not scale-coordinate precision.

Formatting rules:

- integer-valued markers omit meaningless `.0`, so output uses ``1`16`` rather
  than ``1`16.0``;
- fractional and negative markers are printed when certified by the interval
  model, for example ``3.`16.176091257969945`` and
  ``1`-86.3640977218404131*^^102``;
- marker display snaps near-integer metadata noise to the integer value and
  otherwise prints up to 18 significant decimal digits;
- for negative or zero precision, Tungie still prints a nominal center with at
  least one significant digit plus the honest precision marker.

For scale values, the marker on the displayed mantissa is the precision of the
whole represented value. The exponent and hyper-exponent coordinates are nominal
scale coordinates and do not carry printed precision marks while a mantissa is
present.

## Arithmetic

Finite inexact `+`, `-`, `*`, `/`, `^`, unary `Exp`, and unary `Log` use interval
propagation.

Addition and subtraction:

- centers are added or subtracted;
- radii are added.

Multiplication:

- the center is the product of centers;
- for two operands, the radius bound is
  `abs(x) ry + abs(y) rx + rx ry`;
- products of more than two operands apply the same rule pairwise.

Division:

- the denominator interval must exclude zero;
- if it contains zero, Tungie emits the existing division-by-zero diagnostic and
  returns `Undefined`;
- otherwise Tungie uses a conservative reciprocal interval and multiplies by the
  numerator interval.

Powers:

- exact integer powers keep exact behavior where possible;
- `base^0` returns exact `1`, exact `1^exponent` returns exact `1`, and
  `0^positive` returns exact `0`;
- inexact integer powers propagate interval endpoints conservatively;
- positive non-integer powers require a positive base interval and propagate via
  logarithmic sensitivity;
- zero raised to a negative power and a negative base raised to a non-integer
  power keep the existing diagnostics and return `Undefined`.

`SetPrecision[x, p]` and `SetAccuracy[x, a]` may lower certainty by widening an
already inexact interval. They do not increase certainty of an inexact input.
For example, `Precision[SetPrecision[1.`2, 20]]` remains `2.`. Exact input to
`N`, `SetPrecision`, or `SetAccuracy` may create a new inexact interval at the
requested positive working precision or accuracy.

## Scale Values

Tungie represents very large finite values as:

```text
ScientificScale[mantissa, exponent]
```

with compact input and output forms such as ``1`16*^^6``. The scale expression
means `mantissa * 10^exponent`; `Pow10Tower[1, 6]` in the exponent is printed as
`*^^6`.

Direct scale evaluation shifts accuracy by the base-10 exponent. For finite
direct scientific notation, multiplying by `10^e` changes absolute accuracy by
`-e` while preserving the represented value-space precision when appropriate.

Scale multiplication and division combine mantissas with the finite interval
rules and add or subtract scale exponents. Scale addition aligns terms when the
exponents are close enough to certify the sum, otherwise it returns a dominant
term when the separation exceeds certified precision.

Positive scale powers with inexact exponents are evaluated in log10 space:

- let `L = exponent * log10(base)`;
- compute a nominal center and radius for `L`;
- output `10^L` as a scale value;
- derive the printed value-space precision from the log-coordinate uncertainty
  using the current logarithmic approximation `-log10(ln(10) * radius_L)`.

The current target example is:

```text
(1.*^^2)^(1.*^^2) -> 1`-86.3640977218404131*^^102
```

This says the nominal scale coordinate is `10^102`, while the represented
ordinary value has no certified significant decimal digits.

## Error And Undefined Behavior

The following operations emit evaluation errors and return `Undefined`:

- exact or interval division by zero;
- zero raised to a negative power;
- a negative number raised to a non-integer power.

Arithmetic and relational operations involving `Undefined` return `Undefined`.
`UndefinedQ[Undefined]` returns `True`; `UndefinedQ` returns `False` for all
other arguments.

## Deliberate Limits

This implementation does not yet provide:

- public interval endpoint syntax;
- separate scale-coordinate precision;
- exact outward-rounded transcendental enclosures;
- the full MathOverflow leading-digits algorithm;
- arbitrary precision for every built-in with complete interval propagation.

Two-argument `Log` and several non-core built-ins still use the older Decimal
center-evaluation fallback. Those are outside the first interval-precision
surface and should be upgraded before being treated as part of Nummy's final
certified arithmetic kernel.

## Reference Model

The terminology follows the Wolfram Language distinction between precision as a
relative uncertainty measure and accuracy as an absolute uncertainty measure.
The implementation is Tungie-specific and currently uses conservative decimal
intervals rather than Wolfram's full arbitrary-precision machinery.

- https://reference.wolfram.com/language/tutorial/Numbers.html
- https://reference.wolfram.com/language/tutorial/NumericalOperationsOnFunctions.html
