# Tungie

Created (UTC): 2026-04-29T03:08:50Z

Repository HEAD: c1b225695b4b5186e75e5650f9013fbd7865ccba

Tungie is Nummy's dependency-light canonical calculator REPL. It is a small
Tungsten-inspired interpreter subset intended to replace the older makeshift
calculator REPLs while staying independent from Tungsten's broad interpreter
runtime and heavy dependencies.

This first implementation intentionally focuses on ordinary Tungsten-style
integers, rationals produced by exact arithmetic, and real literals. It does
not include Nummy large-number representations, base-form integer literals,
strings, rules, associations, trig functions, formatting heads, or Tungsten's
main-loop hook and input-history symbols.

## Supported Surface

- Decimal integer literals with arbitrary Python integer precision.
- Decimal real literals, including `*^` scientific notation, precision marks
  such as <code>1.23`20</code>, and accuracy marks such as
  <code>1.23``20</code>.
- Arithmetic operators `+`, `-`, `*`, `/`, `^`, implicit multiplication, list
  literals, function calls, unary `+`, unary `-`, and boolean `!`.
- Binary comparisons `==`, `!=`, `<`, `<=`, `>`, and `>=`.
- Top-level semicolon sequencing, without semicolon expressions inside
  parentheses or function arguments. An input ending in `;` evaluates to
  `Null`, stores that `Null` in `Out[n]`, and normally prints no result.
- Simple top-level assignment in the form `name = expr`; chained assignments
  are intentionally rejected. Assigning to predefined symbols emits an error
  message and returns `Null`.
- REPL history through `%`, `%%`, `%n`, and `Out[n]`; the prompt remains
  `In[n]:=`, but `In`, `InString`, and `$Line` are not built-ins.
- Calculator built-ins including `N`, `SetPrecision`, `SetAccuracy`,
  `Precision`, `Accuracy`, `Abs`, `Sign`, `Floor`, `Ceiling`, `Round`,
  `IntegerPart`, `FractionalPart`, `Sqrt`, `Exp`, `Log`, `Min`, `Max`, `If`,
  `Clear`, `Rational`, `Rationalize`, and numeric predicates. `Clear` reports
  each predefined symbol argument without clearing it, while still clearing
  user-defined symbol arguments.
- Division by zero, zero raised to a negative power, and negative numbers
  raised to non-integer powers emit an evaluation error message and return the
  special symbol `Undefined`.
- Arithmetic and relational operations involving `Undefined` return
  `Undefined`; `UndefinedQ[expr]` tests for that symbol. `If[Undefined, a, b]`
  returns `Undefined`, while `Undefined` in a selected branch behaves like any
  other value.

## Running

From this directory:

```powershell
python -m tungie repl
python -m tungie eval "N[Sqrt[2], 20]"
python -m unittest discover -s tests
```

The package has no runtime dependency outside the Python standard library.
