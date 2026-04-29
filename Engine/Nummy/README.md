# Nummy

Nummy is Tungsten's workspace for overflow-resistant arithmetic over very large
and very small numbers. The project is currently research-first and now lives
inside `src/Tungsten` because its next production target is Tungsten's
kernel-free large-number fallback. The implementation surface under `src/`
contains three independent Python alpha/beta/gamma experiments for the same
power-tower arithmetic task, while the broader research corpus and prior-art
reference implementations remain collected under `docs/` and `prior-art/`.

The main design family represented here is level-index and symmetric
level-index arithmetic, plus the related power-tower and "incremental game"
number libraries that trade ordinary floating-point precision guarantees for a
much wider dynamic range.

## Directory Layout

| Path | Context |
| --- | --- |
| `docs/` | Project-local documentation, research reports, theory references, and archived standalone design proposals. |
| `docs/proposals/` | Historical proposal index; standalone Nummy design drafts are archived there because the active production direction now lives in Tungsten docs. |
| `docs/proposals/archived/` | Historical standalone Nummy design proposals, kept for source-study context. |
| `docs/reports/` | Long-form reports and library surveys relevant to Nummy design. |
| `docs/theory/` | Source papers, article snapshots, OCR/LaTeX sidecars, and generated Markdown text for level-index arithmetic. |
| `docs/how-to-calculate-1010101010-1010/` | Archived MathOverflow Q&A computing the leading digits of a five-level power tower; concrete worked example for SLI/dominance arithmetic. |
| `prior-art/` | Vendored or local reference implementations used as source-study material, not production Nummy code. |
| `prior-art/python/` | Standalone Python experiments and ports that are not packaged as independent projects. |
| `src/` | Repository-owned implementation staging area containing independent alpha, beta, and gamma experiments. |
| `src/alpha/` | First Python reference implementation with structural tower arithmetic, certified precision-aware REPL behavior, and a perturbative path for the MathOverflow expression. |
| `src/beta/` | Independent asymptotic power-tower implementation with its own package, REPL, examples, and focused tests. |
| `src/gamma/` | Independent compact tower/REPL implementation with project-local design notes and tests. |

## Implementation Experiments

The `src/alpha/`, `src/beta/`, and `src/gamma/` directories are intentionally
parallel, self-contained implementations of the same Nummy exploration. They
are not merged into a shared runtime package, and similarly named files inside
those directories should be read as implementation-local artifacts rather than
as competing versions of one file.

When comparing the implementations, run their tests and examples from inside
their respective directories so package names, import paths, and REPL entry
points remain scoped to that implementation.

## Research Context

Nummy is about representations that keep computations finite when ordinary
IEEE 754 floating-point values would overflow or underflow. The corpus covers
several closely related strategies:

- Level-index (LI) arithmetic maps huge positive reals through generalized
  logarithm/exponential functions.
- Symmetric level-index (SLI) extends LI with sign and reciprocal handling so
  the representation covers negative and very small values.
- Power-tower representations store a finite level/layer and a magnitude,
  usually in base 10, which is the practical shape used by Hypercalc,
  break_eternity.js, and several incremental-game libraries.
- Array-based googology libraries such as OmegaNum.js go beyond fixed tower
  height by encoding higher hyperoperation layers.

These systems do not make arbitrary-precision arithmetic obsolete. They answer
a different question: "What is the magnitude and stable computable behavior of
an astronomically large value when exact digits are no longer meaningful or
physically representable?"

## Prior Art Corpus

| Item | Context |
| --- | --- |
| [`break_infinity.js`](prior-art/break_infinity.js/) | Decimal-like JavaScript library for values beyond `1e308`, optimized for incremental games and speed. |
| [`break_eternity.js`](prior-art/break_eternity.js/) | Layer/magnitude JavaScript library for tetration-scale values; a sequel to break_infinity.js. |
| [`OmegaNum.js`](prior-art/OmegaNum.js/) | Array-based JavaScript library for much larger googological scales. |
| [`GSLI`](prior-art/GSLI/) | C++ implementation of generalized SLI arithmetic, with Visual Studio project files and GPL licensing. |
| [`level-index-simulator`](prior-art/level-index-simulator/) | MATLAB SLI simulator associated with a 2024 ARITH paper and custom-precision experiments. |
| [`hypercalc`](prior-art/hypercalc/) | Robert Munafo's Hypercalc artifacts: Perl calculator source and JavaScript/HTML calculator page. |
| [`expol.py`](prior-art/expol.py/) | Experimental Python break_infinity-like implementation, kept as a cautionary/simple reference. |
| [`python`](prior-art/python/) | Standalone Python files: a small break_eternity-style experiment and `hypernums.py`. |
| [`Oeis.A002845`](prior-art/Oeis.A002845/) | C# project computing terms of OEIS A002845 via a recursive sparse-binary `SparseInteger` representation. |
| [`SparseNumerics`](prior-art/SparseNumerics/) | C# library extracted from `Oeis.A002845`, exposing the recursive `SparseInteger` type as a standalone NuGet-shaped package. |
| [`name-the-biggest-number`](prior-art/name-the-biggest-number/) | codyroux's Coq-formalized "biggest number" competition in the spirit of Scott Aaronson; a constructive/proof-theoretic angle on the googology corpus. |
| [`LIO`](prior-art/LIO/) | Swastik Banerjee's `LIO[sign, level, index]` Wolfram Mathematica implementation of Clenshaw-Olver level-index arithmetic; surveyed alongside other Wolfram-side big-number routes under [`docs/reports/wolfram/`](docs/reports/wolfram/). |

Vendored code in this corpus should be treated as reference/source-study
material. Prefer adding Nummy-owned experiments under `src/` or a clearly
named new prior-art directory instead of editing upstream snapshots in place.
GNU MP 6.3.0 is still an important repo-level reference and candidate backend,
but its upstream source snapshot now lives outside Nummy at
[`../../../lib/gmp-6.3.0/`](../../../lib/gmp-6.3.0/).

## Theory Corpus

Start with [`docs/theory/README.md`](docs/theory/README.md) for the annotated
paper list. The shortest path through the material is:

1. [Symmetric Level-Index Arithmetic: An Accessible Introduction](<docs/theory/symmetric-level-index-arithmetic-introduction__316e449481ec.md>)
   for a gentle conceptual guide to SLI.
2. Brian Hayes, "The Higher Arithmetic" for the approachable motivation.
3. Clenshaw and Olver, "Beyond Floating Point" for the original level-index
   framing.
4. Clenshaw and Turner, "The Symmetric Level-Index System" for SLI algorithms
   and error control.
5. Olver/Clenshaw, "Level-Index Arithmetic - An Introductory Survey" for the
   broadest technical survey and implementation discussion.
6. Clenshaw and Turner, "Root Squaring Using Level-Index Arithmetic" for a
   concrete numerical application.

When present, PDFs are the authoritative layout copies in the theory corpus.
Matching `.tex` files are OCR/LaTeX sidecars; matching `.md` files are
generated Markdown renderings for search, quoting small excerpts, and agent
analysis. Some OCR sidecars reference extracted `images/` subdirectories.

## Design Direction

The active production direction is Tungsten's large-number fallback design in
[`../docs/overflow-underflow-large-number-fallback.md`](../docs/overflow-underflow-large-number-fallback.md).
Nummy remains the research corpus and implementation staging area feeding that
work.

Earlier standalone Nummy design proposals are now historical. Their landing
surface is [`docs/proposals/archived/`](docs/proposals/archived/). They remain
useful source-study material, but they no longer describe the active ownership
or integration boundary.

A worked motivating example for the SLI/dominance regime - the MathOverflow
Q&A on computing the leading digits of `10^(10^(10^(10^(10^(-10^10)))))` -
is archived under
[`docs/how-to-calculate-1010101010-1010/`](docs/how-to-calculate-1010101010-1010/).

## Licensing Notes

Nummy does not carry a separate license file. Nummy-owned code and
documentation inherit the repository license, MIT-0; see
[`../../../LICENSE`](../../../LICENSE). Several prior-art subtrees have their
own `LICENSE` or `license.txt` files; those files govern their respective
vendored/reference contents. Check the nearest license before copying
prior-art code into any future Nummy-owned implementation.
