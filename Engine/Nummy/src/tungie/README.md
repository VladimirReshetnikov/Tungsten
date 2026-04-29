# Tungie

Created (UTC): 2026-04-29T03:08:50Z

Repository HEAD: c1b225695b4b5186e75e5650f9013fbd7865ccba

Tungie is Nummy's dependency-light canonical calculator REPL. It is a small
Tungsten-inspired interpreter subset intended to replace the older makeshift
calculator REPLs while staying independent from Tungsten's broad interpreter
runtime and heavy dependencies.

This first implementation intentionally focuses on ordinary Tungsten-style
integers, rationals produced by exact arithmetic, real literals, and the first
structural base-10 scale forms needed for Nummy's large-number arithmetic. It
does not include full Nummy large-number arithmetic, base-form integer
literals, strings, rules, associations, trig functions, formatting heads, or
Tungsten's main-loop hook and input-history symbols.

## Supported Surface

- Decimal integer literals with arbitrary Python integer precision.
- Decimal real literals, including `*^` scientific notation, precision marks
  such as <code>1.23`20</code>, and accuracy marks such as
  <code>1.23``20</code>. Unmarked real literals are tracked decimal values:
  their precision is the larger of the current `$Precision` and the number of
  significant digits written in the literal. Reciprocal scientific notation
  `m/^e` is accepted as input and is preferred in output over `m*^-e`;
  `m*^-e` remains accepted input.
- Compact base-10 scale notation: `m*^^e` means `m * 10^(10^e)`,
  `m*^^^e` means `m * 10^(10^(10^e))`, and additional carets insert another
  `10` between adjacent exponentiation operators. The reciprocal forms `/^^`,
  `/^^^`, and so on negate the outer scale exponent, so `m/^^e` means
  `m * 10^(-10^e)`. Direct negative top arguments after `/^`, `/^^`, etc. and
  after any two-or-more-caret `*^^` form are intentionally rejected for now.
- Arithmetic operators `+`, `-`, `*`, `/`, `^`, implicit multiplication, list
  literals, function calls, unary `+`, unary `-`, and boolean `!`.
- Exact rational arithmetic for `+`, `-`, `*`, `/`, and for `^` when the
  exact rational result is representable. Other exact numeric powers are
  approximated with the current `$Precision`.
- Inexact operations use tracked decimal interval arithmetic rather than
  machine-real arithmetic. Approximate numbers carry a nominal center plus an
  absolute uncertainty radius; `Precision` and `Accuracy` are derived from that
  interval and may be fractional, zero, or negative. Very large or small decimal
  results use compact `*^` or `/^` scientific notation. When a result's
  base-10 exponent is larger than `$MaxDirectDecimalExponent`, Tungie keeps it
  as a structural `ScientificScale[mantissa, exponent]` value instead of
  returning an inert expression after Decimal overflow; exact or effectively
  integral powers of ten in the scale exponent are printed compactly as
  `*^^n`, `/^^n`, and longer tower forms.
- Scale values participate in calculator arithmetic. Multiplication and
  division combine mantissas and add or subtract base-10 scale exponents;
  powers of positive numeric values convert to scale form when ordinary Decimal
  arithmetic would overflow; powers of positive scale values multiply the scale
  exponent; addition and subtraction keep a dominant term when the scale
  separation is larger than the certified precision and combine equal-scale
  terms exactly enough to expose cancellation such as
  `10^1000000. - 10^1000000.`.
- Binary comparisons `==`, `!=`, `<`, `<=`, `>`, and `>=`.
- Top-level semicolon sequencing, without semicolon expressions inside
  parentheses or function arguments. An input ending in `;` evaluates to
  `Null`, stores that `Null` in `Out[n]`, and normally prints no result.
- Simple top-level assignment in the form `name = expr`; chained assignments
  are intentionally rejected. Assigning to predefined symbols emits an error
  message and returns `Null`.
- REPL history through `%`, `%%`, `%n`, and `Out[n]`; the prompt remains
  `In[n]:=`, but `In`, `InString`, and `$Line` are not built-ins.
- Mutable session precision through `$Precision`, initially `16`, used when a
  numeric operation needs an approximation and no precision is specified
  explicitly. `N[expr, p]` temporarily evaluates `expr` with `$Precision` set
  to `p`.
- Mutable scale-evaluation threshold through `$MaxDirectDecimalExponent`,
  initially `999999`. Exponents at or below the threshold are evaluated as
  ordinary tracked Decimals when possible; larger exponents stay prefactored.
  `Clear[$Precision]` and `Clear[$MaxDirectDecimalExponent]` emit warnings and
  reset those symbols to their defaults.
- Calculator built-ins including `N`, `SetPrecision`, `SetAccuracy`,
  `Precision`, `Accuracy`, `Abs`, `Sign`, `Floor`, `Ceiling`, `Round`,
  `IntegerPart`, `FractionalPart`, `Sqrt`, `Exp`, `Log`, `Min`, `Max`, `If`,
  `Clear`, `Rational`, `Rationalize`, and numeric predicates. `Clear` reports
  each predefined symbol argument without clearing it, resets the mutable
  system variables above, and still clears user-defined symbol arguments.
- The active interval-precision contract is specified in
  [`../../docs/reports/tungie-interval-precision-spec.md`](../../docs/reports/tungie-interval-precision-spec.md).
- Division by zero, zero raised to a negative power, and negative numbers
  raised to non-integer powers emit an evaluation error message and return the
  special symbol `Undefined`.
- Arithmetic and relational operations involving `Undefined` return
  `Undefined`; `UndefinedQ[expr]` tests for that symbol. `If[Undefined, a, b]`
  returns `Undefined`, while `Undefined` in a selected branch behaves like any
  other value.
- Power special cases are calculator-oriented: `base^0` evaluates to exact
  `1`, including `0^0`; exact `1^exponent` evaluates to exact `1`; and
  `0^exponent` evaluates to exact `0` for positive numeric exponents.

## Running

From this directory:

```powershell
python -m tungie repl
python -m tungie eval "N[Sqrt[2], 20]"
python -m unittest discover -s tests
```

The package has no runtime dependency outside the Python standard library.
