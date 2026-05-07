# Nummy Design Proposals

Created (UTC): 2026-04-28T17:57:38Z
Updated (UTC): 2026-04-29T00:49:16Z

Repository HEAD: b3d0d7929b6a5927bfde9adb364f07616565d3e3

This directory is now a historical proposal landing page. Nummy is developed
inside Tungsten, and the active production direction for large-number fallback
work is documented in
[`../../../docs/overflow-underflow-large-number-fallback.md`](../../../docs/overflow-underflow-large-number-fallback.md).

The earlier standalone Nummy proposals are archived under
[`archived/`](archived/). They remain useful for source-study context because
they captured alternative numeric-engine shapes before Nummy became a Tungsten
subworkspace.

## Archived Proposals

Use [`archived/README.md`](archived/README.md) for the historical proposal
inventory. The archived drafts cover:

- SLI/scale-algebra as the central arithmetic model;
- a hybrid significand plus hierarchical exponent engine;
- a range-first SLI core with explicit reciprocal and uncertainty state.

## Current Reading Path

For active Tungsten large-number work:

1. Read the Tungsten fallback proposal:
   [`../../../docs/overflow-underflow-large-number-fallback.md`](../../../docs/overflow-underflow-large-number-fallback.md).
2. Read the current Nummy prototype synthesis:
   [`../reports/alpha-beta-gamma-unified-comparison.md`](../reports/alpha-beta-gamma-unified-comparison.md).
3. Use the archived proposal set only when historical design alternatives,
   prior-art notes, or engine-level tradeoffs matter.
