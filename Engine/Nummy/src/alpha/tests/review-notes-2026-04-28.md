# Code Review Notes: `src/Tungsten/Nummy/src/alpha/tests`

Created (UTC): 2026-04-28T20:31:20Z

Repository HEAD: 67641dfe69bcd930d9844bcafdb8c8621ebfa559

## Observations

The alpha tests were already centered on the MathOverflow calculation and the
structural tower primitives. That was the right coverage for the first
implementation, but it left the interactive calculator surface unpinned.

The REPL is easiest to test without a real console because its input, output,
and error streams can all be modeled with `StringIO`. That also makes prompt
numbering and failed-input behavior explicit.

## Conclusions

Calculator tests should cover both the pure session evaluator and the console
loop. The session tests anchor grammar and state behavior: assignment,
default-zero variables, right-associative power, and `%` history references.
They should also pin the boundary where exponentiation stops being ordinary
decimal arithmetic and remains structural for large power towers.

After adding precision marks, the tests also need to treat formatting as part
of the arithmetic contract. The important cases are exact rational output at a
configured precision, Wolfram-style `N[expr, p]` and numeric backtick input, and
refusal to claim precision for non-integer powers that the alpha evaluator
cannot yet certify. The REPL tests anchor the Tungsten-style transcript shape
and verify that syntax errors do not advance the output counter.

The archived MathOverflow expression is covered through ordinary syntax. The
tests check that the raw expression displays the sparse anchor plus first-order
correction, that regular `Floor[...]` returns the exact sparse integer suffix
with explicit `Infinity` precision, and that report-valued history entries
cannot accidentally participate in numeric arithmetic.
