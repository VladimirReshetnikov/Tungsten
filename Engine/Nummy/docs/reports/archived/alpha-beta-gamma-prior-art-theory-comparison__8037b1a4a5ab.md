# Nummy Alpha/Beta/Gamma Comparative Report vs Prior Art and Theory

Created (UTC): 2026-04-28T22:39:46Z

Repository HEAD: 370c28b9562eccbda96d2c6a25d6d64da10250d8

## Scope

This report compares the three in-repo implementations under `Engine/Nummy/src` (`alpha`, `beta`, `gamma`), then cross-compares their representation/algorithm choices with the implementations in `Engine/Nummy/prior-art` and the theory corpus in `Engine/Nummy/docs/theory`.

Primary acceptance target: evaluate and explain the archived MathOverflow expression
`10^(10^(10^(10^(10^(-10^10)))))`, including recovery of the finite tail (`... + 2811012357389.440711...`) without materializing impossible-size decimal strings.

## Method

- Reviewed implementation docs and key source modules for alpha/beta/gamma.
- Reviewed representative prior-art families: break_infinity.js, break_eternity.js, OmegaNum.js, Hypercalc lineage, GSLI, and local Python sketches.
- Reviewed Nummy theory index and canonical LI/SLI papers listed there.
- Consolidated findings into architecture, correctness, UX, extensibility, and theory-alignment dimensions.

## Implementation Profiles

### Alpha (`Engine/Nummy/src/alpha`)

**Core character**
- Standard-library-only implementation with an integrated calculator UX.
- Strong display-certification posture: ordinary arithmetic preserved exactly (`Fraction`) when possible; uncertified gigantic forms are clearly marked.
- Directly supports normal-expression evaluation of the MO target plus a `Floor[...]` path yielding a sparse exact integer shape.

**Representation stack**
- Structural tower representation (`TowerReal`) for extreme magnitudes.
- Sparse exact decimal-integer shape (`SparseDecimalInteger`) for expressions like `10^N + k`.
- Calculator value wrapper carrying precision/certification metadata and optional perturbation state.

**Strengths**
- Best end-user REPL semantics today (precision marks, history, direct expression behavior).
- Conservative numerical claims (clear distinction between exact/certified vs structural).
- Most complete “normal syntax” handling of the MO acceptance expression.

**Tradeoffs**
- Perturbation machinery is targeted and pragmatic rather than a broadly generalized asymptotic algebra.
- More bespoke logic in evaluator/display pipeline.

### Beta (`Engine/Nummy/src/beta`)

**Core character**
- Most mathematically extensible prototype; depends on `mpmath`.
- Rich asymptotic-series machinery for propagating tiny perturbations through repeated `10^(...)` structure.
- REPL and package structure are mature, with broad test surface.

**Representation stack**
- `PowerTower(sign, layer, mag)` for structural giant/small magnitudes.
- `PerturbationSeries` for truncated coefficient propagation.
- `AsymptoticTowerValue` as `scale * series(x)` with deferred giant scales.

**Strengths**
- Strongest foundation for generalizing beyond one hand-crafted acceptance case.
- Good separation between structural magnitude and asymptotic correction channels.
- Largest automated test corpus among the three tracks.

**Tradeoffs**
- Normal `^` REPL expression path does not fully surface MO-tail recovery; best results currently behind specialized helper semantics.
- Exact-rational semantics are weaker than alpha for ordinary layer-0 arithmetic.

### Gamma (`Engine/Nummy/src/gamma`)

**Core character**
- Minimal, focused research prototype emphasizing clarity and acceptance-driven behavior.
- Compact tower + landmark/tail model with a small REPL.
- Lightweight and easy to reason about.

**Representation stack**
- Structural `Pow10Tower`.
- Landmark + tail decomposition for finite recoverable parts.
- First-order perturbative helper for small-bottom tower scenarios.

**Strengths**
- Simplicity and readability.
- Demonstrates that direct-expression MO-tail-style recovery can be done with compact machinery.
- Useful as a “clean-room conceptual scaffold.”

**Tradeoffs**
- Narrower arithmetic coverage and weaker precision UX than alpha/beta.
- Less developed packaging and fewer mature extension hooks.

## Cross-Implementation Comparison

## 1) Acceptance behavior for the MO target

- **Alpha:** strongest direct UX fit (normal expression + floorable sparse integer shape + explicit certification signaling).
- **Beta:** strongest engine for asymptotic derivation, but currently less integrated into plain expression semantics.
- **Gamma:** direct behavior is good for prototype goals, but precision/reporting depth is lower.

## 2) Numerical trust model

- **Alpha:** “do not overclaim digits” posture is explicit and user-visible.
- **Beta:** precise when asymptotic path is used correctly; less strict in ordinary mixed pathways due to floating-style core.
- **Gamma:** practical but lightweight trust signaling.

## 3) Architecture for long-term extensibility

- **Alpha:** strongest UX baseline; medium extensibility in asymptotic depth.
- **Beta:** strongest asymptotic extensibility; medium UX integration.
- **Gamma:** strongest conceptual minimalism; lower breadth/extensibility.

## 4) Testing posture

- **Beta** currently has the broadest and densest test matrix.
- **Alpha** tests key behavior with strong acceptance relevance.
- **Gamma** has focused tests aligned to prototype claims.

## Comparison with `prior-art`

Prior-art naturally clusters into five families:

1. **Layer/magnitude decimal game libraries** (`break_infinity.js`, `break_eternity.js`, local Python BE sketches):
   - Excellent for huge dynamic range and performant game-oriented operations.
   - Usually optimized for monotone growth economics, not certified finite-tail recovery for expressions like the MO target.
   - Nummy **beta** aligns most with this family structurally (`sign/layer/mag`) but extends toward asymptotic analysis.

2. **Higher-googology array systems** (`OmegaNum.js`):
   - Extreme representational reach via array/hyperoperation encodings.
   - Sacrifice conventional decimal interpretability and fine-grained correction extraction.
   - Nummy intentionally stays below this abstraction in current tracks, prioritizing meaningful finite output interpretation.

3. **Classical LI/SLI numeric engines** (`GSLI`, `level-index-simulator`, `LIO`):
   - Closer to the theory corpus; emphasize arithmetic closure and algorithmic discipline in LI/SLI coordinates.
   - Better theoretical lineage for future rigorous range/precision handling than incremental-game libraries.
   - Nummy currently borrows concepts but has not yet converged on a full LI/SLI coordinate implementation with comparable formalism.

4. **Hypercalc lineage / power-tower calculators** (`hypercalc`, `hypernums.py`):
   - Strong UX precedent for human interaction with gigantic values.
   - Great landmark for notation and interactive affordances.
   - **Alpha** and **gamma** are most directly aligned in spirit, while adding more explicit acceptance-target behavior.

5. **Conventional exact-big-number backends** (`gmp` and sparse integer experiments):
   - Critical for exact arithmetic at finite scales.
   - Insufficient alone for tower-scale representational needs.
   - Nummy alpha’s sparse/integer exactness posture complements this family.

### Practical deltas versus prior-art

- Nummy’s **distinguishing trait** is not just “bigger numbers”; it is combining giant-structure representation with **recoverable finite tails** and explicit precision semantics for specific structurally dominated regimes.
- Among prior art, LI/SLI engines are closest in spirit to this goal; incremental-game libraries are closest in ecosystem familiarity and practical APIs.

## Comparison with theory corpus (`docs/theory`)

Theory corpus themes (LI, SLI, generalized exp/log, error control, tapered/logarithmic tradeoffs) imply three design obligations:

1. **Range-precision decoupling with explicit semantics.**
2. **Algorithmic closure in transformed coordinates (LI/SLI-like).**
3. **Transparent error/certification behavior at every operation.**

### Alignment map

- **Alpha** aligns strongly with (1) and (3), moderately with (2).
- **Beta** aligns strongly with (2), moderately/strongly with (1), moderately with (3) depending on surface path.
- **Gamma** aligns moderately with (1), lightly/moderately with (2), lightly with (3).

### Key insight

The theory corpus suggests the end-state should not be a pure layer/magnitude game-number clone, and not merely an ad-hoc perturbation calculator. It should become a **hybrid certified system** where:

- structural tower representation handles scale;
- asymptotic/LI-like transformed arithmetic handles corrections;
- UX layer exposes explicit, conservative confidence/precision contracts.

In current experiments, **alpha + beta together already span most of this target envelope**; gamma remains a valuable minimal reference model.

## Recommended synthesis direction

1. Keep **alpha REPL semantics** as the user-facing baseline (normal-expression behavior, floor path, precision communication).
2. Fold in **beta asymptotic engine** as the canonical correction algebra behind the same syntax paths.
3. Retain **gamma minimal landmark/tail abstractions** where they simplify API and internal invariants.
4. Add a first-class **certainty contract** object (exact/certified/lower-bound/structural-only) attached to every value.
5. Introduce LI/SLI-coordinate experiment modules explicitly mapped to theory-paper nomenclature, so results can be compared paper-by-paper.

## Bottom line

- If the immediate goal is best interactive behavior for the specific acceptance target, **alpha leads**.
- If the goal is mathematically scalable asymptotic machinery for broader tower families, **beta leads**.
- If the goal is minimal conceptual clarity and rapid experimentation, **gamma leads**.
- Against prior art and theory, the strongest path is **intentional alpha+beta fusion with LI/SLI-informed certification semantics**, using gamma as a simplification check.
