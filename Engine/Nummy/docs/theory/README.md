# Nummy Theory Corpus

Created (UTC): 2026-04-28T00:26:00Z

Repository HEAD: dad97d346dba0cc2ef8655f3527cb5fc37f61b72

This directory is the source-study corpus for Nummy's number-representation
work. It collects primary papers, article snapshots, and searchable sidecars
for level-index arithmetic, symmetric level-index arithmetic, logarithmic
number systems, tapered floating point, and related huge-number representation
ideas.

## Reading Order

1. [Symmetric Level-Index Arithmetic: An Accessible Introduction](symmetric-level-index-arithmetic-introduction__316e449481ec.md)
   gives a gentle conceptual entry point before the source papers.
2. [The Higher Arithmetic (Hayes)](<The Higher Arithmetic - Hayes/README.md>)
   gives an approachable overview of bignums, tapered representations, and
   level-index ideas.
3. [Beyond Floating Point (Clenshaw 1984)](<Beyond Floating Point - Clenshaw 1984/README.md>)
   introduces the level-index framing and generalized logarithm/exponential
   model.
4. [The Symmetric Level-Index System (Clenshaw 1988)](<The Symmetric Level-Index System - Clenshaw 1988/README.md>)
   adds the symmetric representation and focuses on arithmetic algorithms and
   error control.
5. [Level-Index Arithmetic - An Introductory Survey (Clenshaw 1989)](<Level-Index Arithmetic - An Introductory Survey - Clenshaw 1989/README.md>)
   is the broad technical survey: alternatives, precision, closure,
   implementation schemes, and applications.
6. [Root Squaring Using Level-Index Arithmetic (Clenshaw 1989)](<Root Squaring Using Level-Index Arithmetic - Clenshaw 1989/README.md>)
   is the concrete application study for root-squaring.
7. [Rechnerarithmetik 2008.09 Handout](<Rechnerarithmetik.2008.09.handout/README.md>)
   adds lecture-note context for logarithmic number systems, tapered floating
   point, and SLI.

## Corpus Inventory

| Item | Context |
| --- | --- |
| [Symmetric Level-Index Arithmetic: An Accessible Introduction](symmetric-level-index-arithmetic-introduction__316e449481ec.md) | Gentle conceptual guide to SLI, its range/precision trade-off, arithmetic intuition, and Nummy design implications. |
| [Beyond Floating Point (Clenshaw 1984)](<Beyond Floating Point - Clenshaw 1984/README.md>) | Foundational LI paper; generalized exponentials/logarithms and motivations beyond ordinary floating point. |
| [The Symmetric Level-Index System (Clenshaw 1988)](<The Symmetric Level-Index System - Clenshaw 1988/README.md>) | SLI representation and arithmetic algorithms, including error-control discussion. |
| [Level-Index Arithmetic - An Introductory Survey (Clenshaw 1989)](<Level-Index Arithmetic - An Introductory Survey - Clenshaw 1989/README.md>) | Broad survey of alternatives, LI/SLI arithmetic, precision, closure, implementation approaches, and applications. |
| [Root Squaring Using Level-Index Arithmetic (Clenshaw 1989)](<Root Squaring Using Level-Index Arithmetic - Clenshaw 1989/README.md>) | Application-focused paper using LI arithmetic for root-squaring. |
| [The Higher Arithmetic (Hayes)](<The Higher Arithmetic - Hayes/README.md>) | Popular exposition linking bignums, tapered arithmetic, logarithmic systems, and level-index arithmetic. |
| [Rechnerarithmetik 2008.09 Handout](<Rechnerarithmetik.2008.09.handout/README.md>) | German lecture handout covering logarithmic number systems, tapered floating point, and LI/SLI. |
| [SLI Arithmetic (Wikipedia).md](<SLI Arithmetic (Wikipedia).md>) | Markdown rendering of the local Wikipedia snapshot for the SLI article and its references. |

## Artifact Conventions

Each paper directory keeps the matching `.tex` OCR/LaTeX sidecar and generated
`.md` rendering together, with the PDF retained where the corpus still carries
one. When present, the PDF remains the citation and layout authority; generated
Markdown is primarily for search, structural reading, and quoting short
excerpts. Extracted `images/` directories are kept next to the `.tex` files
that reference them.
