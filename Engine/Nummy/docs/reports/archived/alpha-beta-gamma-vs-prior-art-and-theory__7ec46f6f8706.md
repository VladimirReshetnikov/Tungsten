# Nummy Comparative Report: alpha/beta/gamma vs Prior Art and Theory

Created (UTC): 2026-04-28T22:39:21Z
Repository HEAD: 370c28b9562eccbda96d2c6a25d6d64da10250d8

## Scope and Method

This report compares the three repository-owned implementations in `src/Tungsten/Nummy/src` (`alpha`, `beta`, `gamma`) and cross-checks them against:

1. Prior-art implementations under `src/Tungsten/Nummy/prior-art/`.
2. The theory corpus under `src/Tungsten/Nummy/docs/theory/`.

The focus is not only representable range, but also **computational behavior near tower landmarks**, especially for the archived motivating expression:

`10^(10^(10^(10^(10^(-10^10)))))`

## High-Level Verdict

- **alpha** is currently the strongest *interactive calculator* implementation because it supports direct expression entry, explicit precision signaling, and an exact sparse-integer `Floor[...]` path.
- **beta** has the strongest *asymptotic mathematics engine* and best test breadth, but the highest-value asymptotic path is exposed through a special function instead of being fully fused into ordinary `^` evaluation.
- **gamma** is the cleanest *minimal model* of “tower landmark + finite correction” behavior for the motivating expression, but has a narrower surface and fewer numerical/UX guardrails.

## Side-by-Side Comparison: alpha, beta, gamma

| Axis | alpha | beta | gamma |
| --- | --- | --- | --- |
| Primary numeric model | Structural tower + sparse integer + perturbation state | Structural tower + asymptotic series | Structural tower + landmark-tail model |
| Core dependencies | Python stdlib only | `mpmath` | Python stdlib only |
| REPL maturity | High (Wolfram-like history, precision controls, `Floor`, `N`, `SetPrecision`) | High (parser/evaluator with precision state, special builtins) | Moderate (compact REPL, focused commands) |
| Motivating expression (direct syntax) | Strong | Partial (structural form without full tail) | Strong |
| Explicit precision semantics in outputs | Strong | Strong for scalar values | Limited |
| Test breadth in-tree | Moderate | Highest | Small but focused |
| Architecture extensibility for higher-order perturbation | Moderate | Strongest | Moderate |

## Implementation Profiles

### alpha

**Strengths**
- Integrates structural tower arithmetic, sparse decimal integer shape, and a calculator-layer precision contract in one coherent user surface.
- Supports direct entry of the motivating expression and returns a landmark + correction output.
- Exposes an exact sparse integer path for `Floor[...]`, which is a major practical win for “landmark plus finite tail” tasks.
- Uses conservative certification behavior (marks uncertified approximations with low/zero confidence precision rather than silently overclaiming digits).

**Weaknesses / Risks**
- Perturbation path appears more expression-pattern-driven and less general than a full symbolic asymptotic engine.
- Broader high-order asymptotic propagation is less explicit than in beta.

### beta

**Strengths**
- Best mathematical core for generalization: explicit asymptotic series machinery and separate representational layers for tower scale and perturbation.
- Most complete test corpus among the three implementations.
- Clean conceptual decomposition (`tower`, `series`, `asymptotic`, `leading_digits`, `calc`).

**Weaknesses / Risks**
- Ordinary REPL exponentiation path does not always surface the full correction digits for the motivating expression without the specialized helper.
- UX split between “ordinary calculator expression” and “special asymptotic builtin” may confuse users.

### gamma

**Strengths**
- Small, readable implementation that still demonstrates direct motivating-expression success.
- Clear architectural idea: represent impossible-scale landmark structurally and finite correction as normal decimal data.
- Good as a pedagogical and prototyping base.

**Weaknesses / Risks**
- Narrower features (precision reporting, precision controls, `Floor` semantics, packaging maturity).
- Smaller safety net of tests and edge-case handling.

## Comparison Against Prior Art

## 1) break_infinity.js and break_eternity.js

These libraries provide highly practical large-number arithmetic with layer/magnitude style representations and excellent runtime ergonomics for game-scale huge numbers. Relative to Nummy’s three implementations:

- They excel at range-first operations and compact notation for huge scales.
- They are weaker for Nummy’s motivating requirement: preserving tiny perturbations through several exponentials to recover a finite tail near a landmark.

**Nummy delta:** alpha/beta/gamma each introduce project-specific “landmark plus correction” behavior that is more directly aligned with the MathOverflow-style target than generic incremental-game number engines.

## 2) OmegaNum.js

OmegaNum extends to much larger hierarchy levels (array/hyperoperation style), but that power is orthogonal to decimal-tail extraction near a fixed landmark.

**Nummy delta:** Nummy prototypes are currently stronger on the specific perturbative-decimal-tail problem; OmegaNum-style systems are stronger on naming and manipulating enormously high hyperoperation ordinals.

## 3) GSLI and level-index-simulator

These are closest to the theory corpus, aiming at LI/SLI arithmetic as arithmetic systems. They provide direct relevance for robust range extension and SLI arithmetic design, including error/control ideas.

**Nummy delta:** alpha/beta/gamma are currently application-targeted prototypes rather than full LI/SLI engines with the same breadth. They are pragmatically closer to a calculator-facing acceptance target, while GSLI/simulator are closer to full-system arithmetic research artifacts.

## 4) hypercalc, expol.py, and loose python experiments

These emphasize exploratory approaches and wide-range formatting. They clarify historical trade-offs and failure modes when using floating-like schemas for tower-scale tasks.

**Nummy delta:** all three Nummy implementations encode a clearer distinction between representable landmark structure and finite correction, which is the key architectural move required for the motivating expression.

## 5) SparseNumerics / Oeis.A002845

These are not tower-focused but provide valuable representation insight: massive values can remain tractable when encoded sparsely around structure.

**Nummy delta:** alpha and gamma in particular mirror this philosophy in decimal-landmark form (e.g., “1 then many zeros then finite tail”), even though the underlying sparse basis differs.

## Comparison Against Theory Corpus

The Nummy theory corpus emphasizes LI/SLI concepts, generalized log/exp coordinates, and error-control framing. Relative to that body:

- **alpha** aligns with the theory in spirit via structural magnitude coordinates and conservative display semantics, but is not a full LI/SLI implementation.
- **beta** is closest to the trajectory suggested by theory for mathematically robust extensions because its asymptotic machinery can be expanded toward higher-order and more formal error tracking.
- **gamma** aligns conceptually with the dominance/landmark intuition found in LI/SLI discussions, but currently remains a compact practical prototype.

### Theory Alignment Matrix

| Theory theme | alpha | beta | gamma |
| --- | --- | --- | --- |
| Iterated log/exp as coordinate idea | Medium | High | Medium |
| Symmetric handling of tiny/huge scales | Medium | Medium-High | Medium |
| Explicit error/precision discipline | High (user-facing) | Medium-High (engine-facing) | Medium-Low |
| General-purpose LI/SLI arithmetic breadth | Low-Medium | Medium | Low-Medium |

## Synthesis Recommendation

A unified “next Nummy core” should combine:

1. **alpha’s user-facing contract** (direct expression support, precision signaling, exact sparse `Floor` semantics).
2. **beta’s asymptotic engine** (generalizable perturbation series and stronger internal math decomposition).
3. **gamma’s compact landmark-tail vocabulary** (simple, explicit data model for impossible-scale decimal descriptions).

Concretely, the highest-leverage near-term direction is to route ordinary REPL exponentiation through beta-grade asymptotic propagation *when landmark-near conditions are detected*, then format via alpha-style certified output rules.

## Practical Ranking by Use Case

- **Best today for end-user calculator behavior:** `alpha`
- **Best today for mathematical extensibility and research progression:** `beta`
- **Best today for compact conceptual prototype / teaching model:** `gamma`

## Closing Assessment

Nummy’s three in-repo implementations are not redundant; they collectively cover complementary strengths that prior-art projects and theory corpus both suggest are necessary:

- range representation,
- perturbation propagation,
- and trustworthy user-visible precision/shape reporting.

Compared with prior art, Nummy is already stronger on the specific “tower landmark + finite correction” acceptance target. Compared with the theory corpus, Nummy still needs a fuller LI/SLI-grade arithmetic core, but beta’s architecture plus alpha’s UX contract provides a credible path to that destination.
