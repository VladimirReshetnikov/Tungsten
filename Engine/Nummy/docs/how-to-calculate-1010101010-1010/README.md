# How to Calculate 10^10^10^10^10^-10^10

Created (UTC): 2026-04-28T17:57:38Z

Repository HEAD: e62abd26bee0839a55d4252db7a7a581b251e35b

This directory archives a MathOverflow question and answer about computing the
integer part of `10^(10^(10^(10^(10^(-10^10)))))`, a value that sits just above
`10^(10^10)` and whose leading-digit structure is determined by a tiny
perturbation propagated through five stacked exponentials.

The original question was posted by Vladimir Reshetnikov on 2011-10-27 at
[mathoverflow.net/questions/79217](https://mathoverflow.net/questions/79217/how-to-calculate-1010101010-1010).
The accepted answer by "GH from MO" derives the value as
`10^(10^10) + 10^11 * ln^4(10)` plus a tiny positive correction by expanding
each level of the tower around `1 + cx + O(x^2)` with `c = ln(10)` and
`x = 10^(-10^10)`.

## Files

- [PDF](how-to-calculate-1010101010-1010.pdf) - rendered snapshot of the
  MathOverflow page.
- [TeX sidecar](how-to-calculate-1010101010-1010.tex) - searchable LaTeX
  source matching the PDF, useful for quoting individual formulas.
- [Plain-text excerpt](how-to-calculate-1010101010-1010.txt) - condensed
  question/answer text without page chrome.

## Why It Matters

The worked computation is a compact, fully concrete instance of the regime
Nummy is designed to make routine: a value in which ordinary arithmetic
collapses (`10^(10^10)` already overflows IEEE 754 double exponents many times
over) but whose leading digits are still recoverable through symbolic
expansion at the right scale. It is a useful test case and motivating example
for the SLI-level dominance, cancellation, and structural-expansion concerns
discussed in the proposals under [`../proposals/`](../proposals/) and the
theory corpus under [`../theory/`](../theory/).
