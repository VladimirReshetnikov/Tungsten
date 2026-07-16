# Nummy Comparative Report: alpha vs beta vs gamma, with Prior-Art and Theory Alignment

Created (UTC): 2026-04-28T22:39:34Z

Repository HEAD: 370c28b9562eccbda96d2c6a25d6d64da10250d8

## Scope

This report compares the three repository-owned Nummy implementations under `Engine/Nummy/src/` (`alpha`, `beta`, `gamma`), then maps them against the reference implementations under `Engine/Nummy/prior-art/` and the source-paper corpus under `Engine/Nummy/docs/theory/`.

The comparison axis is not only feature count. It is the deeper fit between:

- representation model;
- precision/error discipline;
- user-facing calculator ergonomics;
- extensibility toward true LI/SLI arithmetic;
- practical ability to solve the motivating expression:

```text
10^(10^(10^(10^(10^(-10^10)))))
```

## Executive Findings

1. **alpha is the strongest UX and correctness-contract baseline** for a user-facing calculator: normal expression path, sparse-floor support, explicit precision signalling, exact `Fraction` arithmetic for ordinary operations.
2. **beta is the strongest asymptotic mathematics baseline**: cleaner modular architecture, richer perturbation machinery, and the broadest test surface.
3. **gamma is the strongest minimal didactic baseline**: smallest conceptual core for landmark-plus-tail reasoning (`Pow10Tower` + finite correction), but intentionally narrow scope.
4. **No implementation is yet a full LI/SLI engine** in the Clenshaw/Turner sense (representation + stable arithmetic closure + principled error propagation across broad operation families).
5. The best forward path is a **composite architecture**: alpha surface + beta asymptotic core + gamma-style result vocabulary, validated against GSLI and level-index-simulator behaviors where comparable.

## Implementation-to-Implementation Comparison

### 1) Representation Model

- **alpha** uses a layered hybrid model: tower coordinates, sparse integer shape (`10^N + k` style), and a calculator value wrapper that carries certification/precision metadata.
- **beta** splits concerns more explicitly: `PowerTower` for magnitude shape, plus asymptotic series objects for perturbative propagation.
- **gamma** uses a compact structural tower type and landmark-tail output objects with deliberately restricted evaluator behavior.

Interpretation: alpha and gamma optimize for solving/printing the motivating expression through ordinary syntax, while beta optimizes for reusable asymptotic machinery.

### 2) Precision and Error Semantics

- **alpha** has the clearest conservative display policy: exact rational substrate for ordinary expressions and explicit low-confidence signalling for structural outputs.
- **beta** offers precision tags + guard-digit working precision and residual discussion for asymptotic terms; pragmatic but not yet a global proof discipline.
- **gamma** relies on `Decimal` context precision and concise output, but with weaker explicit confidence signalling.

Interpretation: alpha best communicates reliability to the user; beta best positions the internals for future formalized bounds.

### 3) REPL and Syntax Surface

- **alpha** and **gamma** both satisfy the high-value behavior of directly entering the archived power-tower expression in ordinary syntax and getting a landmark-tail style result.
- **beta** currently exposes its strongest MO path through dedicated function flow (`LeadingDigits[...]`), not yet fully fused into ordinary expression evaluation.

Interpretation: beta has a "core/surface impedance mismatch" that is architectural, not mathematical.

### 4) Test Posture

- **beta** has the broadest and most modular test footprint.
- **alpha** has focused tests that align tightly with Nummy’s acceptance narrative and calculator contract.
- **gamma** has compact targeted tests around the critical tower path and REPL basics.

Interpretation: beta is best for regression scaling; alpha is best for acceptance behavior fidelity.

## Comparison with Prior-Art Implementations

## A) break_infinity.js / break_eternity.js / OmegaNum.js family

The JS lineage in prior-art emphasizes **range + speed + game ergonomics** over strict decimal-proof guarantees. `break_eternity.js` in particular shares structural DNA with Nummy towers (sign/layer/magnitude-like components and hyper-operation support).

- Alignment with Nummy:
  - beta’s `PowerTower` abstraction and structural formatting are closest in spirit.
  - gamma’s small core mirrors the same design instinct: keep giant-number shape compact.
- Misalignment with Nummy’s stricter reporting goal:
  - these libraries generally optimize practical magnitude arithmetic, not theorem-like claims about every displayed correction digit in perturbative tails.

Implication: this family is excellent for API and normalization heuristics, but insufficient alone for Nummy’s precision-certification ambitions.

## B) GSLI (C++)

GSLI is the strongest prior-art bridge to classical SLI goals: very wide dynamic range, arithmetic operators and elementary transcendental support, and emphasis on overflow/underflow avoidance.

- Alignment:
  - Nummy’s theoretical direction (especially proposals around SLI) is philosophically close.
  - alpha’s conservative output semantics and beta’s structured asymptotics move toward the same robustness ethos.
- Gap:
  - current alpha/beta/gamma implementations are still domain-focused prototypes, not yet a generalized SLI runtime covering broad arithmetic with consistent performance/error contracts.

Implication: GSLI is a calibration target for operation coverage and API breadth, while Nummy can exceed it on explainability and modern calculator UX.

## C) level-index-simulator (MATLAB, ARITH 2024 context)

The simulator foregrounds **custom precision experiments** and systematic arithmetic experimentation in SLI space.

- Alignment:
  - beta’s modular series engine is conceptually best suited for experimental arithmetic pathways.
  - alpha’s explicit precision posture resembles the simulator’s concern with controlled numerical behavior.
- Gap:
  - Nummy’s current implementations focus heavily on the power-tower/leading-tail scenario rather than broad benchmark-style SLI operation studies.

Implication: adopting experiment-style benchmark suites similar to the simulator would materially strengthen Nummy’s research-to-engineering bridge.

## D) Hypercalc / expol.py / python sketches

These references are especially useful for **interface intuition** and **heuristic handling** of huge numbers in scripting-friendly contexts.

- gamma reflects the same spirit of compactness and inspectability.
- alpha improves on this lineage by adding explicit precision/certification framing.
- beta improves on it by adding asymptotic machinery suitable for principled derivations.

Implication: Nummy should keep taking UX cues from these systems while avoiding their common weakness: under-specified confidence semantics.

## Alignment with Theory Corpus

The theory corpus emphasizes several recurrent requirements: representation closure across extreme scale, arithmetic algorithms that remain stable across scale transitions, and explicit thought about errors/precision.

### 1) Beyond Floating Point (Clenshaw 1984)

Core message: ordinary exponent/mantissa floating point is structurally insufficient for extreme ranges; alternative coordinate systems are justified.

- alpha/beta/gamma all align with this motivation through non-IEEE-centric tower representations.
- beta most directly aligns with the "change representation to preserve computability" thesis in algorithmic form.

### 2) The Symmetric Level-Index System (Clenshaw 1988)

Core message: SLI requires carefully designed arithmetic mappings and controlled error behavior over sign/reciprocal domains.

- alpha makes the strongest move on explicit user-facing confidence semantics.
- none of alpha/beta/gamma yet implements the full SLI arithmetic closure expected by this paper lineage.

### 3) Level-Index Arithmetic Survey (Clenshaw 1989)

Core message: LI/SLI are systems, not isolated tricks; operation set, implementation constraints, and precision policy are interdependent.

- beta’s modular structure is best poised to evolve into a broader system.
- alpha is best poised to serve as the user-facing shell of such a system.

### 4) Root-Squaring and application papers

Core message: these representations matter when they unlock concrete numerically difficult applications.

- Nummy currently has one dominant showcase workload (the archived MO expression).
- next maturity step is diversifying difficult workloads (iterative maps, root-squaring-like transforms, mixed-operation chains) under common semantics.

## Strengths and Weaknesses Matrix

| Axis | alpha | beta | gamma |
| --- | --- | --- | --- |
| User-facing calculator readiness | **High** | Medium | Medium |
| Asymptotic extensibility | Medium | **High** | Low-Medium |
| Precision communication clarity | **High** | Medium-High | Low-Medium |
| Architectural modularity | Medium | **High** | Medium |
| Minimal conceptual footprint | Medium | Medium | **High** |
| Direct MO-expression UX | **High** | Medium | **High** |

## Synthesis Recommendation

Adopt a three-layer target architecture:

1. **Surface Layer (from alpha)**
   - Keep ordinary expression grammar as primary entry path.
   - Preserve explicit precision/certification output semantics.
2. **Core Perturbation Layer (from beta)**
   - Replace specialized one-off correction logic with generalized truncated-series propagation + residual bounds.
   - Keep operations modular by domain (tower algebra vs asymptotic correction algebra).
3. **Result Vocabulary Layer (from gamma)**
   - Standardize a compact landmark-tail data contract for outputs (dominant landmark, zero-run metadata, trailing block, fractional tail).

Validation track:

- Cross-check representative arithmetic behaviors against `prior-art/GSLI` and `prior-art/level-index-simulator` where operation overlap exists.
- Keep the archived MO expression as an acceptance anchor, but add at least a small corpus of additional high-dynamic-range workloads from the theory papers.

## Practical Next Steps (Size-Only Estimates)

- Refactor and integrate shared calculator AST/evaluator interfaces across alpha+beta: ~700-1200 LOC across ~8-12 files.
- Introduce unified landmark-tail result type + adapters in all three prototypes: ~250-400 LOC across ~5-7 files.
- Add cross-implementation conformance tests for 12-20 canonical expressions/workloads: ~20-35 tests across ~4-6 files.
- Add paper-inspired benchmark script set (LI/SLI motivated operations): ~300-600 LOC across ~4-8 files.

## Closing

The strongest conclusion is that the three Nummy implementations are complementary rather than mutually exclusive competitors:

- alpha has the best user contract;
- beta has the best mathematical engine trajectory;
- gamma has the best minimal explanatory core.

Compared with prior-art and theory, Nummy is already on a promising trajectory: it has surpassed many practical huge-number toolkits in explicit acceptance-driven behavior for the motivating expression, while still leaving a clear path toward fuller LI/SLI arithmetic maturity.
