# Nummy Implementation Staging

Created (UTC): 2026-04-28T00:26:00Z

Repository HEAD: dad97d346dba0cc2ef8655f3527cb5fc37f61b72

This directory contains repository-owned Nummy implementation work. It contains
the canonical dependency-light Tungie calculator REPL plus the earlier
independent alpha/beta/gamma power-tower experiments:

| Path | Role |
| --- | --- |
| `alpha/` | Structural tower arithmetic reference with a certified precision-aware REPL and perturbative support for the archived MathOverflow expression. |
| `beta/` | Asymptotic power-tower implementation with its own `nummy` package, calculator parser/evaluator, REPL, example script, and tests. |
| `gamma/` | Compact tower arithmetic implementation with a standalone REPL, `nummy_tower` package, design notes, and tests. |
| `tungie/` | Canonical lightweight Tungsten-inspired calculator subset with a dependency-free parser, evaluator, REPL, and focused tests. |

The current deduplicated comparison of these experiments lives under
[`../docs/reports/alpha-beta-gamma-unified-comparison.md`](../docs/reports/alpha-beta-gamma-unified-comparison.md).

The alpha, beta, and gamma implementations are deliberately not merged into a
shared source tree. Their code, tests, project files, and implementation-local
Markdown documents belong to their respective subdirectories. Tungie is the
canonical calculator surface for new Nummy REPL work; shared docs in the parent
Nummy tree should describe that current ownership boundary without deduplicating
implementation-local design notes.

Keep vendored/reference code under `../prior-art/`. Put future
repository-owned experiments in clearly named sibling directories so the
distinction between "what Nummy is" and "what Nummy is learning from" remains
visible in the tree.
