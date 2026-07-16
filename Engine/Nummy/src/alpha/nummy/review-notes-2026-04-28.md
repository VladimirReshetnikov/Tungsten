# Code Review Notes: `Engine/Nummy/src/alpha/nummy`

Created (UTC): 2026-04-28T20:31:20Z

Repository HEAD: 67641dfe69bcd930d9844bcafdb8c8621ebfa559

## Observations

The alpha package already had a small structural arithmetic core, but ordinary
layer-0 reciprocal values leaked into user-facing arithmetic. In particular,
division and powers could fall through the tower log path and produce
calculator-hostile results for ordinary expressions such as `5 / 2` or `2^3`.
The opposite edge also matters: power expressions such as `10^10^10` must
promote into structural coordinates before `Decimal` tries to materialize the
enormous ordinary value.

The package also had only a module entry point for the MathOverflow calculation,
not an interactive surface. Once the REPL started exposing ordinary decimal
arithmetic, the next important boundary was precision: output needs to say how
many digits it claims, and the evaluator needs to avoid claiming digits that
come only from rounded `Decimal` intermediates.

## Conclusions

The REPL should be layered over a dedicated calculator session and parser rather
than hand-coded inside the console loop. That keeps Tungsten-like console
behavior testable through `StringIO` and keeps the arithmetic grammar small:
numbers, variables, assignment, history references, and arithmetic operators.

Layer-0 arithmetic should materialize through `Decimal` before using structural
tower fallbacks when the result is ordinary-sized. That matches calculator
expectations while preserving the tower representation for genuinely huge
values.

For the REPL-facing arithmetic subset, exact `Fraction` values are a better
certification layer than bare `Decimal`. They let the calculator emit
Wolfram-style precision marks and guarantee displayed decimal digits for
ordinary arithmetic, while structural tower approximations can honestly report
precision `0` until the higher-level interval algorithms exist.

The MathOverflow answer does not fit plain tower-coordinate evaluation,
because the small perturbation around the anchor is exactly the important
quantity. The calculator should therefore carry a perturbation state through
ordinary `10 ^ ...` syntax and let regular `Floor[...]` consume it, rather than
exposing a named shortcut for the motivating example.
