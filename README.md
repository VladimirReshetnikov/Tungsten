# Tungsten

- Status: Active multi-project Wolfram automation and symbolic-computation repository
- Audience: Users, maintainers, researchers, and coding agents
- Created (UTC): 2026-07-16T23:45:44Z
- Extraction source: [`VladimirReshetnikov/Smithereens`](https://github.com/VladimirReshetnikov/Smithereens) at `94fc0c18b538a191192a0da658e66528940438c6`

Tungsten collects a Python-first Wolfram automation engine and three focused Wolfram Language
packages. The projects share a repository and runtime context, but each top-level directory is an
independent workspace.

## Projects

| Directory | Purpose |
|---|---|
| [`Engine/`](Engine/) | Python-first automation over a local Wolfram installation, kernel-free Wolfram expression and notebook tooling, PowerShell and .NET projections, and the Nummy large-number research workspace. This directory was formerly `src/Tungsten/`. |
| [`CommonFactor/`](CommonFactor/) | Heuristic discovery of large symbolic common factors in finite exact integer or rational sequences. |
| [`InverseAsymptotic/`](InverseAsymptotic/) | Real-branch inverse-function asymptotics in generalized power-logarithm scales. |
| [`Optimized/`](Optimized/) | DAG-preserving arithmetic and substitution for ``Experimental`OptimizedExpression`` values. |

The detailed history-rewrite method and verification record are in
[`docs/history-extraction.md`](docs/history-extraction.md).

## Running the projects

There is no repository-wide build. Use the entry point for the project being changed.

```powershell
# Engine: Python tests and CLI
cd Engine
uv run python -m unittest discover -s tests -t .
uv run python -m tungsten kernel eval --code '2+2'

# Wolfram Language packages, from the repository root
wolfram -script CommonFactor/tests/smoke.wl
wolfram -script InverseAsymptotic/tests/smoke.wl
wolfram -script InverseAsymptotic/tests/merged-api.wl
wolfram -script Optimized/tests/smoke.wl
```

The Engine documentation is indexed by [`Engine/docs/README.md`](Engine/docs/README.md). Each
Wolfram package has its own README and runnable demo.

## Repository guidance

- Treat each top-level project as an independent ownership boundary; avoid introducing shared
  dependencies unless a task explicitly calls for them.
- Documentation should describe the current state. New technical documents should include their
  UTC creation time and the full repository `HEAD` used as provenance.
- Prefer symbolic identity checks before numerical checks. When a numerical Wolfram equality test
  is necessary, test the difference with a raised precision budget:

  ```wolframlanguage
  Block[{$MaxExtraPrecision = 100}, PossibleZeroQ[lhs - rhs]]
  ```

- For PSLQ or integer-relation searches, include an unrelated canary such as
  `ChampernowneNumber[]`, vary basis permutations/scalings/precision, and reject relations with a
  nonzero canary coefficient.
- Use the Engine JSON-first CLI for structured Wolfram automation; use the product-local Wolfram
  executable directly for one-off scripts.
- Preserve third-party licenses under `Engine/Nummy/prior-art/`. The repository-level `LICENSE`
  applies only where a subtree does not provide a more specific license.

## History

This repository was extracted from Smithereens on 2026-07-16 with `git-filter-repo`. The selected
histories were rewritten from `src/Tungsten`, `src/CommonFactor`, `src/InverseAsymptotic`, and
`src/Optimized` to the top-level paths shown above. Rewriting paths necessarily changed commit IDs,
while preserving authorship, timestamps, messages, relevant ancestry, and file contents.
