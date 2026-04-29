# Archived Nummy Design Proposals

Created (UTC): 2026-04-29T00:49:16Z

Repository HEAD: b3d0d7929b6a5927bfde9adb364f07616565d3e3

This directory preserves standalone Nummy design proposals that predate
Nummy's relocation under Tungsten. They are historical design alternatives,
not the active implementation plan.

The active production-facing proposal is Tungsten's
[`overflow-underflow-large-number-fallback.md`](../../../../docs/overflow-underflow-large-number-fallback.md).

## Inventory

| Proposal | Historical role |
| --- | --- |
| [`design-proposal-1.md`](design-proposal-1.md) | SLI/scale-algebra core; biased toward a C/C++/Rust implementation with MPFR/GMP backends. |
| [`design-proposal-2.md`](design-proposal-2.md) | Hybrid engine combining a conventional limb-array significand, a hierarchical exponent layer, and an escalation layer to LNS/SLI. |
| [`design-proposal-2.docx`](design-proposal-2.docx) | Word mirror of `design-proposal-2.md` for sharing outside Markdown-aware tooling. |
| [`design-proposal-3.md`](design-proposal-3.md) | Range-first SLI core with explicit reciprocal state, level/index coordinate uncertainty, and adapter boundaries. |
