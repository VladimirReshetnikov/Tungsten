# Tungsten Numeric Tower

- Status: Implementation notes for Tungsten's kernel-free numeric evaluator
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Updated (UTC): 2026-04-27T20:51:45Z
- Repository HEAD: 61e28d844b1e32dca30f4a8d6ca402c4ec8a67b7
- Related docs:
  - [Expression Function Support](./expression-function-support.md)
  - [Numeric Simplification](./numeric-simplification.md)
  - [Expression Parser](./expression-parser.md)
  - [Usage Reference](./usage-reference.md)
  - [Wolfram Numbers tutorial](https://reference.wolfram.com/language/tutorial/Numbers.html)
  - [Numerical Evaluation & Precision guide](https://reference.wolfram.com/language/guide/NumericalEvaluationAndPrecision.html)
  - [Precision & Accuracy Control guide](https://reference.wolfram.com/language/guide/PrecisionAndAccuracyControl.html)

## Design Goals

Tungsten's numeric implementation is designed for offline structural evaluation, not for replacing
the Wolfram kernel's numerical engine. The goal is to make common explicit numeric expressions
parse, inspect, compare, and simplify in the ways agent scripts expect, while failing closed on
symbolic or branch-sensitive cases.

This means Tungsten implements a coherent numeric tower for explicit atoms, but it does not attempt
general algebraic simplification, transcendental numerical evaluation, interval arithmetic, or full
guard-digit uncertainty propagation.

## Atomic Numeric Values

Tungsten treats the following as numeric atoms:

- `Integer`: arbitrary-size exact integers represented by the existing `Integer` AST atom.
- `Rational`: exact normalized fractions represented by an atomic `RationalNumber`, rendered as
  `Rational[n, d]` in `FullForm` and `n/d` in `InputForm`.
- `Real`: approximate real atoms represented by decimal text. Machine reals have no explicit
  precision or accuracy marker; arbitrary-precision reals preserve markers such as
  <code>`20</code> or <code>``20</code>.
- `Complex`: atomic complex values whose real and imaginary components are explicit real-valued
  numeric atoms.
- `Overflow[]` and `Underflow[]`: special atomic real values with head `Real`, matching the
  important Wolfram behavior that their printed form looks like a call while `AtomQ` is `True`.

Numeric atoms have no extractable parts. `Length[Rational[1, 2]]`, `Length[1 + 2 I]`, and
`Length[Overflow[]]` therefore all return `0`.

## Canonicalization Rules

`Rational[n, d]` reduces explicit integer numerator and denominator to lowest terms. A denominator
of `0` yields `ComplexInfinity` for nonzero numerators and `Indeterminate` for `0/0`.

`Complex[re, im]` accepts explicit real-valued numeric components. If `im` is exact zero, Tungsten
collapses the complex value to `re`. If either component is a machine real, exact components are
coerced to machine reals so predicates such as `MachineNumberQ[1. + 2 I]` behave in the common
Wolfram-compatible way. Approximate zero imaginary parts are not exact zero, so values such as
`Complex[1., 0.]` remain complex.

`I` evaluates to the atomic complex value `Complex[0, 1]`.

## Arithmetic

`Plus`, `Times`, and `Power` evaluate exact numeric combinations and perform a small set of
Wolfram-style structural arithmetic simplifications. Exact integer/rational arithmetic uses Python
`Fraction`. Machine arithmetic uses Python `float`. Arbitrary-precision decimal arithmetic uses
Python `Decimal` with the minimum visible precision of the participating explicit
arbitrary-precision real atoms.

These heads run through the same registry-backed attribute pipeline as user symbols. Built-in
snapshot attributes therefore flatten `Flat` expressions, canonicalize `Orderless` argument order,
and thread `Listable` calls before the numeric evaluator attempts an explicit-number calculation.
This is still bounded structural normalization rather than general algebraic simplification.
Tungsten folds numeric constants, combines identical additive terms (`x + x` -> `2*x`), combines
identical multiplicative bases (`x*x` -> `x^2`, `x^a*x^b` -> `x^(a+b)`), applies identity powers
such as `x^1 -> x` and `1^x -> 1`, and distributes explicit integer powers over products. It does
not factor unrelated terms such as `a*x + b*x`, solve assumptions, reorder according to every
undocumented kernel tie breaker, or infer numeric values for symbolic subexpressions.

Supported power cases are deliberately bounded:

- exact or inexact numeric bases raised to integer powers;
- negative integer powers through reciprocals;
- machine real powers that Python can compute directly;
- complex integer powers by repeated multiplication.
- symbolic identity powers such as `x^0`, `x^1`, and `1^x`;
- integer powers of symbolic powers/products where the transformation is structurally safe.

Unsupported branch-sensitive cases remain inert.

## Relations And Predicates

`Equal` and `Unequal` work for explicit real and complex numbers. Ordering relations (`Less`,
`LessEqual`, `Greater`, `GreaterEqual`) work for explicit real-valued numbers and supported
infinity markers; complex ordering remains inert.

Implemented numeric predicates include `AtomQ`, `IntegerQ`, `MachineIntegerQ`, `NumberQ`,
`NumericQ`, `ExactNumberQ`, `InexactNumberQ`, `RealValuedNumberQ`, and `MachineNumberQ`.
`Infinity` is not a number for `NumberQ` or `NumericQ`, but `Overflow[]` and `Underflow[]` are
explicit real numbers. `NumericQ` additionally recognizes variable-free supported elementary
numeric expressions and exact algebraic `Root` expressions.

`MachineIntegerQ` is a Tungsten convenience spelling for the signed 64-bit range check that Wolfram
exposes as <code>Developer`MachineIntegerQ</code>.

## Numeric Simplification

`Simplify` and `FullSimplify` are intentionally bounded. They run only for evaluated expressions
where `NumericQ` returns `True`; variable-bearing expressions are returned in their evaluated form.
The current transformation set is documented in [Numeric Simplification](./numeric-simplification.md)
and consists of ordinary evaluation, supported `RootReduce`, and one low-risk SymPy pass over a
variable-free numeric expression.

## Precision And Accuracy

`N[expr]` converts exact numeric atoms to machine precision by default. `N[expr, p]` converts them
to decimal arbitrary-precision reals with precision marker `p`. Tungsten also numericizes common
symbolic constants and elementary numeric calls through SymPy, such as `N[Pi, 20]`,
`N[Sin[Pi/6], 20]`, and `N[Log[E], 20]`. As a Tungsten extension, option-like trailing rules
`WorkingPrecision`, `AccuracyGoal`, and `PrecisionGoal` are accepted and treated as requested
decimal precision.

`Precision` returns:

- `Infinity` for exact numbers;
- `MachinePrecision` for machine real or machine complex numbers;
- the explicit precision for precision-marked arbitrary-precision real numbers;
- an inferred precision for accuracy-marked real numbers;
- `0.` for `Overflow[]` and `Underflow[]`;
- the minimum visible numeric precision across compound expressions.

`Accuracy` uses the standard precision/accuracy relationship documented by Wolfram: precision is a
relative digit count and accuracy is an absolute digit count. Tungsten computes this relationship
from the explicit decimal literal value and its visible marker. This is sufficient for inspectable
metadata such as `Accuracy[1000.]` and <code>Accuracy[1.23`20]</code>, but it does not model all guard-digit
or uncertainty effects from the live kernel.

`SetPrecision` and `SetAccuracy` rewrite explicit numeric atoms to carry the requested metadata.
`SetPrecision[expr, Infinity]` converts finite decimal real literals to exact rationals using
Tungsten's decimal interpretation of the literal, rather than reconstructing the exact binary
machine value the Wolfram kernel may use.

## Machine Constants

Tungsten exposes these machine constants using Python's platform `float` metadata:

- `$MachinePrecision`
- `$MaxMachineNumber`
- `$MinMachineNumber`
- `$MachineEpsilon`

The displayed decimal text is Wolfram-like and parseable by Tungsten, but not intended to be a
byte-for-byte reproduction of Wolfram kernel formatting.

## Known Divergences

- `DirectedInfinity` is not yet the canonical internal representation for `Infinity`,
  `-Infinity`, and `ComplexInfinity`.
- Arbitrary-precision arithmetic uses decimal precision metadata and does not implement the full
  Wolfram bigfloat engine or interval uncertainty model.
- `SetAccuracy` is metadata-oriented and intentionally simpler than Wolfram's guard-digit behavior.
- Symbolic mathematical constants such as `Pi` and `E` are inert until passed to a live kernel or a
  future Tungsten mathematical evaluator.
- Complex functions are currently limited to structural `Re`, `Im`, `Conjugate`, and `Abs` over
  explicit numeric complex atoms.
