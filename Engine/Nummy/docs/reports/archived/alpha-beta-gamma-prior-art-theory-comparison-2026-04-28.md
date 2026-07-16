# Nummy Report: Alpha vs Beta vs Gamma, with Prior-Art and Theory Alignment

Created (UTC): 2026-04-28

## Scope and Method

This report compares the three repository-owned implementations under `Engine/Nummy/src/`:

- `alpha`
- `beta`
- `gamma`

and maps them against:

- prior-art implementations under `Engine/Nummy/prior-art/`
- theory corpus under `Engine/Nummy/docs/theory/`

Primary source inputs for this report were the implementation-level design/README docs, the existing implementation comparison, and the prior-art/theory landing pages.

---

## 1) High-level Positioning of the Three Implementations

### Alpha (`Engine/Nummy/src/alpha`)

Alpha is the most **calculator-product-facing** implementation today. It combines structural tower arithmetic, exact rational handling in layer-0 arithmetic, conservative precision labeling, and a perturbation path that can recover the MathOverflow tail directly from normal expression syntax.

Key characteristics:

- Standard-library-only dependency footprint.
- Strong REPL/CLI ergonomics, including `Floor[...]`, `N[...]`, `SetPrecision[...]`, and precision-mark output.
- Explicit “certified vs structural approximation” display semantics.
- Built to avoid overclaiming decimal correctness for non-certified tower regimes.

### Beta (`Engine/Nummy/src/beta`)

Beta is the strongest **asymptotic-analysis engine** of the three. It builds a more formalized perturbation pipeline using `mpmath`, with richer tests and `LeadingDigits[k, n]` as an explicit first-class operation.

Key characteristics:

- `mpmath`-based series propagation and high-precision arithmetic.
- Broadest test suite among alpha/beta/gamma.
- Most explicit implementation of “compute huge dominant term + finite correction” via dedicated built-ins.
- Less direct than alpha/gamma for the specific “type only the ordinary expression and get the tail” calculator behavior.

### Gamma (`Engine/Nummy/src/gamma`)

Gamma is the most **minimal and inspectable acceptance prototype**. It has a compact structural model (`Pow10Tower`) plus a near-landmark tail representation that directly demonstrates the MathOverflow behavior in a small codebase.

Key characteristics:

- Smallest code surface.
- Narrow, clean conceptual model for “landmark + finite tail.”
- Successfully recovers the motivating tail from ordinary expression syntax.
- Fewer user-facing capabilities (packaging, precision suffix semantics, richer built-ins).

---

## 2) Direct Alpha/Beta/Gamma Comparison

## 2.1 Acceptance target: MathOverflow expression

Target expression:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

Required behavior (project-specific): recover the finite correction near `10^(10^10)`, including the `2811012357389.4407...`-style tail description, without materializing impossible digit strings.

- **Alpha:** meets this through normal expression evaluation and supports `Floor[...]` on the same expression shape.
- **Beta:** computes this robustly through `LeadingDigits[...]` built-in; normal expression REPL path focuses on structural tower form and does not expose the correction tail directly.
- **Gamma:** meets this through normal expression path and exposes compact “tower + tail” output.

## 2.2 Precision semantics and trust model

- **Alpha:** most conservative trust model; distinguishes exact/certified from structural approximation at output level.
- **Beta:** strong numerical precision from `mpmath` and explicit precision handling, but oriented around asymptotic API and dedicated built-ins for the hardest case.
- **Gamma:** pragmatic `Decimal` usage and compact output, but fewer explicit user-visible contracts around digit certification in the REPL.

## 2.3 Representation strategy

- **Alpha:** broad calculator value model (`tower` + optional exact fraction + optional perturbation state + display metadata).
- **Beta:** asymptotic series abstraction around tower progression, with explicit MO-focused leading-digit extraction pathway.
- **Gamma:** two cooperating abstractions (`Pow10Tower` and landmark-tail form) with minimal ceremony.

## 2.4 Product-readiness profile

- **Alpha:** best current candidate for user-facing calculator baseline.
- **Beta:** best current candidate for mathematically extensible perturbation engine.
- **Gamma:** best current candidate for minimal pedagogical/reference kernel.

---

## 3) Comparison with Prior Art

## 3.1 break_infinity.js / break_eternity.js / OmegaNum.js

The JavaScript lineage prioritizes extreme dynamic range and speed using layer/magnitude (or array-hyperoperation) representations.

Relative to those libraries:

- **Alpha/Beta/Gamma all align** with the same “range-first structural magnitude” family, especially for tower-scale representation.
- **Nummy implementations diverge intentionally** by elevating the MathOverflow-style perturbation/tail recovery as a core requirement, not merely a formatting concern.
- **Beta is closest in spirit** to a mathematically explicit perturbation layer absent in typical incremental-game-number libraries.
- **Gamma is closest in compactness** to the simple conceptual core these libraries popularized.

## 3.2 GSLI and level-index-simulator

These represent the LI/SLI research lineage rather than game-oriented huge-number APIs.

Relative to them:

- **All three Nummy implementations are proto-SLI-adjacent but not full SLI engines** with complete bounded-sequence arithmetic and full error-control framework.
- **Alpha** pulls in the strongest “precision contract discipline” at the user boundary.
- **Beta** pulls in the strongest “asymptotic derivation machinery” useful for bridging from structural towers toward deeper LI/SLI algorithmics.
- **Gamma** contributes a clean representational core that could host stronger SLI-style arithmetic later.

## 3.3 Hypercalc / expol.py / local Python prior art

- Hypercalc and related tools demonstrate long-standing utility of tower-structured notation but do not, by default, solve Nummy’s precise tail-recovery objective in a conservative precision-contract way.
- `expol.py` and simple mantissa/exponent systems illustrate why plain “bigger decimal float” is insufficient once tower-depth + perturbation sensitivity dominate.
- The Nummy trio improves on this by keeping structural representation and perturbation logic explicit rather than forcing all behavior through ordinary big-float arithmetic.

## 3.4 Sparse integer prior art (SparseNumerics / OEIS A002845)

Sparse integer work is not tower arithmetic, but its “represent huge values structurally without dense expansion” principle is highly aligned with Nummy goals.

- **Alpha’s sparse-decimal integer floor output** is the strongest direct realization of this design principle in current Nummy implementations.
- **Gamma’s landmark+tail concept** is the cleanest conceptual analog for sparse huge-value description.

---

## 4) Alignment with Theory Corpus

## 4.1 Beyond Floating Point (Clenshaw 1984) and LI framing

Core theoretical theme: trade conventional local spacing for dramatically expanded representable range via repeated log/exp coordinate systems.

Alignment:

- All three implementations adopt the practical equivalent of repeated-log/exponential stratification (tower/layer abstractions).
- Beta and alpha most explicitly use this structure for algorithmic computation rather than display alone.

## 4.2 The Symmetric Level-Index System (Clenshaw 1988)

Core theme: sign/reciprocal handling and arithmetic algorithms under SLI with error considerations.

Alignment:

- Alpha’s explicit reciprocal/sign-aware structural model is the closest practical step toward SLI-style semantics.
- Beta/gamma currently emphasize positive tower-growth and perturbative workflows more than full symmetric arithmetic closure.

## 4.3 LI Introductory Survey (Clenshaw 1989)

Core theme: implementation tradeoffs, closure, precision, and practical numerical behavior.

Alignment:

- Alpha’s conservative precision reporting maps best to survey concerns about representational meaning versus printed-digit trust.
- Beta’s asymptotic series machinery maps best to “problem-specific algorithmic overlays” that LI-style systems often require.

## 4.4 Root-squaring and applied LI workflows

Core theme: LI usefulness in concrete numerical methods beyond pure representation.

Alignment implication:

- Beta has the strongest architecture for extension into algorithm-specialized workflows (series propagation as reusable machinery).
- Alpha offers best user-surface for exposing such workflows safely.
- Gamma offers best compact substrate for proving minimal algorithm kernels.

---

## 5) Synthesis and Recommended Direction

A high-leverage merged architecture would be:

1. **Alpha as REPL/CLI contract and precision UX backbone**
   - Keep its conservative output-certification model.
   - Keep direct normal-expression handling, including `Floor[...]`.
2. **Beta as perturbation/asymptotic computation engine**
   - Promote series propagation into a shared core module.
   - Preserve dedicated analysis entry points like `LeadingDigits[k,n]` as optional power-tools.
3. **Gamma concepts as minimal core vocabulary**
   - Preserve `Pow10Tower`-style clarity and landmark+tail decomposition as simple, inspectable domain primitives.

This combination would better match both the theory corpus (LI/SLI range+error discipline) and the strongest practical lessons from prior art (structural scale representation + special-case algorithm overlays when local digits matter).

---

## 6) Bottom Line

- **Alpha** currently wins for end-user calculator behavior and trust semantics.
- **Beta** currently wins for mathematically scalable perturbation machinery.
- **Gamma** currently wins for conceptual compactness and inspectable minimality.

Against prior-art and theory, all three are directionally correct, but each captures a different third of the final target system:

- product contract (`alpha`),
- asymptotic engine (`beta`),
- minimal model clarity (`gamma`).

The path to a production-grade Nummy core is not choosing one and discarding the rest; it is a planned synthesis that preserves each implementation’s strongest invariant.
