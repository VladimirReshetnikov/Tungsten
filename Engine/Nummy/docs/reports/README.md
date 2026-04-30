# Nummy Reports

Created (UTC): 2026-04-28T00:26:00Z

Repository HEAD: dad97d346dba0cc2ef8655f3527cb5fc37f61b72

This directory holds long-form reports and surveys that synthesize Nummy's
theory corpus and prototype/reference libraries.

## Current Reports

| Report | Context |
| --- | --- |
| [Prototype Corpus Overview](<Prototype Corpus Overview.md>) | Overview and comparison of the prior-art reference projects under `src/Tungsten/Nummy/prior-art`, including their relation to symmetric level-index arithmetic. |
| [Shortcomings of Floating-Point Arithmetic in Modern CAS](cas-floating-point-shortcomings__288318099677.md) | Survey of why modern CAS floating-point models, including Wolfram Language/Mathematica-style precision tracking, still inherit mantissa/exponent limits and do not make magnitude scale a first-class arithmetic coordinate. |
| [Power-Tower Arithmetic and SLI in Python](<Power-Tower Arithmetic and SLI in Python.md>) | Survey of SLI, power-tower representations, Hypercalc-style arithmetic, Python library options, uncertainty propagation, and the trade-off between magnitude reach and conventional precision. |
| [Nummy Alpha/Beta/Gamma Unified Comparison](alpha-beta-gamma-unified-comparison.md) | Current deduplicated comparison of the three implementation experiments, including claim triage, prior-art/theory alignment, and synthesis recommendation. |
| [Tungie Language And REPL Proposal](tungie-language-and-repl-proposal__e9b88699e6fe.md) | Current proposal for replacing the three prototype calculator REPLs with one lightweight, Tungsten-inspired, dependency-light Nummy interpreter. |
| [Tungie Interval Precision Specification](tungie-interval-precision-spec.md) | Implementation-level contract for Tungie's current center-plus-radius interval precision model, including fractional and negative precision behavior. |
| [Base-10 Level-Interval Arithmetic Proposal](base10-level-interval-arithmetic-proposal.md) | Proposal for a standalone interval arithmetic system with exact base-10 level endpoints, rational coordinate budgets, and outward-rounded arithmetic/power semantics. |

## Topical Subdirectories

| Subdirectory | Context |
| --- | --- |
| [`archived/`](archived/) | Antecedent alpha/beta/gamma comparison reports superseded by the unified comparison. |
| [`wolfram/`](wolfram/) | Surveys of how Wolfram Language users get past the kernel's `$MaxNumber` ceiling: `ComputerArithmetic\``, `mpmath`/`python-flint` via `ExternalEvaluate`, Arb/FLINT via LibraryLink, log-domain tools, and the `LIO[sign, level, index]` level-index project (vendored under [`../../prior-art/LIO/`](../../prior-art/LIO/)). |

The Power-Tower / Prototype Corpus / CAS reports include inline data-URI
images for formulas. That makes them self-contained, but also large and noisy
for diffs. Prefer adding new analysis as separate Markdown documents rather
than mechanically rewriting the existing reports unless the rewrite is
intentional.
