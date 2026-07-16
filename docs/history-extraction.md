# History extraction from Smithereens

- Created (UTC): 2026-07-16T23:45:44Z
- Source repository: [`VladimirReshetnikov/Smithereens`](https://github.com/VladimirReshetnikov/Smithereens)
- Source snapshot: `94fc0c18b538a191192a0da658e66528940438c6`
- Rewrite tool: `git-filter-repo` 2.47.0 (`a40bce548d2c`)

This repository retains the history of four project trees formerly hosted by Smithereens. Path
rewriting gives retained commits new identifiers, but preserves their authorship, author and
committer timestamps, messages, relevant parentage, and contents.

## Path map

| Smithereens path | Tungsten path | Source/current tree object at extraction |
|---|---|---|
| `src/Tungsten/` | `Engine/` | `dfb25042eb999980611ca3365c55a470c11f5516` |
| `src/CommonFactor/` | `CommonFactor/` | `7eb3312fd4ced5d1a91f853228e62ea5f1d823a8` |
| `src/InverseAsymptotic/` | `InverseAsymptotic/` | `92cacfa88b07f690c124db3bd09fa5ff97d61585` |
| `src/Optimized/` | `Optimized/` | `8d06e377d9e3860559cdb9a6905ffb7157341000` |

Matching tree object IDs provide a byte-for-byte Git object check that the extraction itself did
not alter any selected file. Layout-adaptation and repository-metadata changes were made only after
that check.

## Rewrite

The extraction was performed from a fresh single-branch clone:

```text
git filter-repo --force \
  --path src/Tungsten/ \
  --path src/CommonFactor/ \
  --path src/InverseAsymptotic/ \
  --path src/Optimized/ \
  --path-rename src/Tungsten/:Engine/ \
  --path-rename src/CommonFactor/:CommonFactor/ \
  --path-rename src/InverseAsymptotic/:InverseAsymptotic/ \
  --path-rename src/Optimized/:Optimized/
```

The source had no tags. An audit of all source refs found 195 commits touching the selected paths,
all reachable from `main`; no selected-path commits existed only on another remote branch. The
filtered result contains 201 commits because relevant merge ancestry is retained. The last relevant
source merge, `3ce81c6e983584d70d4e452464c5319da9e8f01d`, became
`2f6d25782be78c82a34d6af3975b87398a660e10`.

The companion Smithereens commit,
`da7026ec1369ade49bb6d964019a4c124fdd5091`, removes the four original directories and records
their move to this repository, following the parallel-deletion convention already used for earlier
repository splits.
