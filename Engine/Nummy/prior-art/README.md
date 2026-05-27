# Nummy Prior Art Corpus

Created (UTC): 2026-04-28T00:26:00Z

Repository HEAD: dad97d346dba0cc2ef8655f3527cb5fc37f61b72

This directory collects prior-art and reference implementations relevant to
Nummy. Most entries are vendored upstream snapshots or small experiments.
They are here to support source study, behavior comparison, and design
extraction; they are not the production Nummy implementation.

## Inventory

| Directory | Language | Context | License Source |
| --- | --- | --- | --- |
| [`break_infinity.js`](break_infinity.js/) | TypeScript/JavaScript | Decimal-like library optimized for fast values above ordinary double range, up to roughly `1e9e15`. | `LICENSE` (MIT) |
| [`break_eternity.js`](break_eternity.js/) | TypeScript/JavaScript | Layer/magnitude library for tetration-scale values and hyper-4 operations. | `LICENSE` (MIT) |
| [`OmegaNum.js`](OmegaNum.js/) | JavaScript | Array-based huge-number library reaching beyond fixed tower-height representations. | `LICENSE` (MIT) |
| [`GSLI`](GSLI/) | C++ | Generalized SLI arithmetic implementation with Visual Studio project files. | `LICENSE` (GPL) |
| [`level-index-simulator`](level-index-simulator/) | MATLAB | Custom-precision SLI simulator with tests and experiment scripts. | `license.txt` (BSD 2-Clause) |
| [`hypercalc`](hypercalc/) | Perl/HTML/JavaScript | Hypercalc artifacts from Robert Munafo's power-tower calculator lineage. | File headers |
| [`expol.py`](expol.py/) | Python | Experimental break_infinity-like Python implementation with known correctness limits. | `LICENSE` (GPL) |
| [`python`](python/) | Python | Loose standalone Python experiments and ports gathered under one local landing page. | File headers / nearest applicable license |
| [`Oeis.A002845`](Oeis.A002845/) | C# / .NET | Computes terms of [OEIS A002845](https://oeis.org/A002845) using a recursive sparse-binary `SparseInteger` representation that stores huge integers as sorted bit-position arrays of `SparseInteger`. Includes a console app and xUnit tests. | `LICENSE` (MIT) |
| [`SparseNumerics`](SparseNumerics/) | C# / .NET | Standalone library extracted from `Oeis.A002845` exposing the `SparseInteger` type for nonnegative integers far larger than `BigInteger` can represent, provided the binary form has a moderate number of one-bits whose positions are themselves recursively representable. | `LICENSE` (MIT) |
| [`name-the-biggest-number`](name-the-biggest-number/) | Coq | codyroux's "name the biggest number" competition: each contender is a constructive `nat`-valued Coq definition with a formal proof that it dominates the previous contender. A different angle on the corpus - formal/constructive size bounds rather than overflow-resistant arithmetic - aligned with Scott Aaronson's "Who Can Name the Bigger Number?". | `LICENSE` (MIT) |
| [`LIO`](LIO/) | Wolfram Mathematica | Swastik Banerjee's level-index arithmetic implementation in the Wolfram Language. Defines `LIO[sign, level, index]` with `ToLIO`, `FromLIO`, `PowerForm`, and `LevelIndexArithmetic` operations following Clenshaw and Olver. Vendored as the article ([`LIO.md`](LIO/LIO.md)), notebook ([`LIO.nb`](LIO/LIO.nb)), and PDF ([`LIO.pdf`](LIO/LIO.pdf)); discussed further under [`../docs/reports/wolfram/`](../docs/reports/wolfram/). | Wolfram Community publication (no explicit license file) |

## Usage Guidance

- Treat vendored source as reference material unless a task explicitly asks to
  repair or modernize that snapshot.
- Prefer adding Nummy-owned experiments under `../src/` once they become part
  of the project rather than mutating upstream-style subtrees in place.
- Nummy-owned code and documentation inherit the containing repository license
  (MIT-0); Nummy does not have a separate license file.
- Keep license files with their original subtrees. Do not copy code from one
  subtree into another without checking the nearest license.
- For behavior comparisons, record observed differences in `../docs/` instead
  of encoding them only in ad hoc test scripts.
