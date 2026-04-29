# Wolfram / Mathematica Big-Number Reports

Created (UTC): 2026-04-28T19:13:36Z

Repository HEAD: 83d5cc4c911c6227d582e0bd7945632bd91d271c

This subdirectory collects surveys of how Wolfram Language users get past
the kernel's `$MaxNumber` ceiling: native Mathematica facilities,
Function Repository tools, external-package routes, and dedicated
level-index implementations such as the LIO project vendored under
[`../../../prior-art/LIO/`](../../../prior-art/LIO/).

## Reports

| Report | Context |
| --- | --- |
| [`big-number-packages-report-1.md`](big-number-packages-report-1.md) | Detailed survey: `ComputerArithmetic\``, `mpmath` via `ExternalEvaluate`, `python-flint`/Arb, direct Arb/FLINT through LibraryLink/WSTP, log-domain tools (`LogSumExp`), MPFR/`bigfloat`, and `HexStringToReal`. Verdict-style comparison table with practical recommendations. |
| [`big-number-packages-report-2.md`](big-number-packages-report-2.md) | Shorter writeup focused on the two natively Wolfram-aimed routes: the `ComputerArithmetic\`` modeling package and the `LIO[sign, level, index]` Wolfram Cloud notebook by Swastik Banerjee, with the LibraryLink-paclet route as the engineering fallback. |

## Why It Matters

Mathematica's arbitrary-precision `Real` type has an arbitrary mantissa but a
fixed-width exponent (Wolfram documentation lists `$MaxNumber` around
`10^1355718576299609`), so any genuine power-tower or tetration-scale value
overflows. These reports map the practical escape routes available today and
inform the Wolfram-side adapter discussion in
[`../../proposals/`](../../proposals/).
