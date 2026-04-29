# Nummy Documentation

Created (UTC): 2026-04-28T00:26:00Z
Updated (UTC): 2026-04-29T00:49:16Z

Repository HEAD: b3d0d7929b6a5927bfde9adb364f07616565d3e3

This directory contains project-local documentation for Nummy, the
large-number arithmetic research workspace now developed as part of Tungsten.
It is split between current analysis/reports, source-backed theory material,
and archived standalone design proposals.

## Layout

| Path | Context |
| --- | --- |
| [`proposals/`](proposals/) | Historical proposal index; earlier standalone Nummy design drafts are archived here now that the active production proposal lives in Tungsten docs. |
| [`reports/`](reports/) | Long-form reports and surveys about power-tower arithmetic, SLI, CAS floating-point limitations, and relevant Python/library ecosystems. |
| [`theory/`](theory/) | Primary and secondary source material for level-index arithmetic, SLI, tapered/logarithmic number systems, and related references. |
| [`how-to-calculate-1010101010-1010/`](how-to-calculate-1010101010-1010/) | Archived MathOverflow Q&A that computes the leading digits of a five-level power tower; a concrete worked example for the SLI/dominance regime. |

## Conventions

- When present, PDFs in `theory/` are the authoritative layout copies of
  papers and articles.
- Matching `.tex` files are OCR/LaTeX sidecars with the same base name as their
  generated Markdown rendering.
- Matching `.md` files are generated from the `.tex` sidecars for easier
  Markdown-native reading and search.
- `images/` directories under individual paper directories contain extracted
  figures referenced by OCR sidecars.
- Markdown source snapshots are used for reference and citation tracing.
- Reports may summarize external projects, but prior-art source snapshots live
  under `../prior-art/`.
