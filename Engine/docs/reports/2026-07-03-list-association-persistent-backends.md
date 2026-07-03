# Persistent Backends for List and Association: Design Study

- Status: Design study (substrate-level; complements [`list-association-parity-proposal.md`](../list-association-parity-proposal.md))
- Audience: Tungsten maintainers working on the kernel-free expression evaluator
- Scope: Verified designs for `List` and `Association` backends on persistent chunked ropes and
  HAMT + order-tree composites; kernel-verified Wolfram semantics; corrections from adversarial
  review; migration order and substrate requirements
- Created (UTC): 2026-07-03T17:10:00Z
- Repository HEAD: e16db62ae188dbe7df0a3e0cd417e027122b0ebf
- Related code:
  - [`expression.py`](../../src/tungsten/expression.py)
  - [`expression_evaluator.py`](../../src/tungsten/expression_evaluator.py)
  - [`expression_patterns.py`](../../src/tungsten/expression_patterns.py)
- Related docs:
  - [`list-association-complexity.md`](../list-association-complexity.md)
  - [`list-association-parity-proposal.md`](../list-association-parity-proposal.md)
  - [`list-association-parity-review-notes.md`](../list-association-parity-review-notes.md)
  - [`association-support-plan.md`](../association-support-plan.md)
- Reference substrates: the sibling `C:\DataStructures` repository (persistent HAMT and
  finger-tree families; see its `docs/reference/derived-structure-catalog.md` for the
  library-side view of this study)

## Purpose And Method

This report answers: what should `List` and `Association` look like as *data structures* if
Tungsten replaces the current tuple-backed and scan-based representations with persistent
structures? It is substrate-level and language-abstract: the designs are specified against the
contracts of the DataStructures repository's C# implementations (chunked `Rope<T>`,
`FingerTreeDeque<T>`, `PersistentHashMap<K,V>`), which serve as reference substrates. Whether a
Python implementation binds to them, ports them, or approximates them with `rpds-py`-class
libraries is the parity proposal's Stage A/B dependency question, out of scope here.

Method: a multi-agent design study (2026-07-03). Recon agents mapped Tungsten's current
representation, pinned Wolfram semantics against documentation *and a live Wolfram Engine 14.3
kernel*, and extracted the exact substrate APIs; two designs were then produced and each
adversarially verified twice (feasibility against substrate sources at file/line granularity;
fidelity against the kernel-verified semantics). Corrections from those reviews are folded in and
marked.

Baseline (from [`list-association-complexity.md`](../list-association-complexity.md), re-confirmed
by recon): a `List` is `Call(Symbol("List"), tuple)` and every structural update rebuilds the
tuple in `O(n)`; an `Association` is scanned per operation, and scalar lookup builds a throwaway
dict per call (`expression.py:16485`). `SameQ` performs a full recursive structural comparison per
call, and the set/dict paths (`UnsameQ`, expressions used as dict or set keys) recompute recursive
dataclass hashes per call; there is no interning and no cached hash.

## Kernel-Verified Wolfram Semantics

These behaviors were executed on Wolfram Engine 14.3 (`wolfram.exe -pwfile` against the local
mathpass; the 15.0 install is unactivated). They are the requirements spec for any backend and
extend what the parity proposal records.

| # | Behavior | Verified result |
| --- | --- | --- |
| 1 | Duplicate keys at construction | `<\|a->1, b->2, a->3\|> === <\|a->3, b->2\|>` - key keeps its **first**-occurrence position with the **last** value. Holds for `Association[...]`, `AssociationThread`, and `Join`. The docs' phrase "all but the last are dropped" is misleading about position. |
| 2 | `Append`/`Prepend` on an existing key | **Removes the old entry and re-adds at the end/front.** |
| 3 | `AssociateTo`, `a[k] = v`, `a[[Key[k]]] = v` | **Update in place, keeping the key's position.** New keys append at the end. `AssociateTo` is therefore not positionally equivalent to `Append`. |
| 4 | Positional operations | `a[[n]]`/`a[[-n]]` return the nth **value**; spans and index lists return sub-associations preserving keys (index lists in requested order); `Take`/`Drop`/`First`/`Last`/`Rest`/`Most`/`Insert`/`Delete`/`Reverse` are positional. |
| 5 | Sorting | `Sort` sorts by **values**, `KeySort`/`KeySortBy` by keys, `SortBy` by `f` of values. (Sorted results are ordinary associations that do not stay sorted under later appends - documented behavior, not separately kernel-run.) |
| 6 | Missing behavior | `a[k]` on an absent key silently returns `Missing["KeyAbsent", k]`; `a[[Key[k]]]` issues `Part::keyw` (14.3 returned the `Key`-wrapped form - see caveats). `Lookup` evaluates its default only on absence. |
| 7 | Key equality | Structural SameQ identity after key evaluation: `<\|1+1->x\|>` has key `2`; `1`, `1.`, `1/2`, `"a"`, and the symbol `a` are five distinct keys; `2.0` does not match key `2`. |
| 8 | Bulk operations | `Merge` applies the combiner to the **list** of same-key values (singletons included), result keys in first-encounter order; `KeyTake` follows the **requested** key order, skipping absents; `KeyDrop`/`KeySelect`/`Select`/`DeleteCases` preserve association order; `GroupBy`/`Counts`/`PositionIndex` are first-occurrence ordered; `KeyUnion` pads `Missing["KeyAbsent", k]`. |
| 9 | Structure | `AtomQ` on associations is `True`; `===`/`==` are order-sensitive; `Keys`/`Values`/`Normal` orders are mutually consistent; value semantics are persistent (aliased copy mutation does not affect the original). |

Caveats to re-verify on a healthy kernel: the `Missing["KeyAbsent", Key[k]]` wrapper form (observed
on a damaged 14.3 install; older documentation shows the unwrapped form); `RuleDelayed` per-access
re-evaluation; `Sort` tie stability; `AssociationMap`/`Query` (returned unevaluated because
top-level init failed - spec'd from documentation). Community reporting (Shifrin, attributed to
WRI) says the kernel's own `Association` is a HAMT, so this design uses the same substrate class
the kernel does - with an explicit order structure the kernel may lack (its positional-access
complexity is unpublished).

## TungstenList

The argument sequence of *every* normal expression, not just `List`. Three representations behind
one abstract surface; representation is never observable (the parity proposal's discipline).

1. **SmallList** (`n <= ~32`): plain immutable array. Most expressions live here forever; nothing
   beats a flat array at this size. Mandatory tier, not an optimization.
2. **LargeList**: chunked persistent rope (256-2048-element chunks over plain arrays). Point
   access `O(log n)`; single-element replacement copies one chunk and shares the rest;
   split/slice/concatenate are `O(log)` and structurally shared.
3. **PackedList**: `Rope<int64>` / `Rope<float64>` behind a lazily boxing view - the chunks *are*
   contiguous homogeneous arrays, so the packed-array analog falls out of the rope, except
   functional update copies one chunk instead of the whole array.

Consequential operation mappings (reference WL cost is the contiguous-array model; Tungsten-today
is the tuple model):

| Operation | Tungsten today | Reference WL | This design |
| --- | --- | --- | --- |
| `Part` | `O(1)` | `O(1)` | `O(1)` small / `O(log n)` large - the one regression |
| `ReplacePart` (one position) | `O(n)` | `O(n)` | `O(log n + chunk)` |
| `Append` in a loop (n appends) | `O(n^2)` | `O(n^2)` (documented trap) | `O(n)` total |
| `Join` | `O(n + m)` | `O(n + m)` | `O(log min(n, m))` with boundary-chunk coalescing |
| `Take`/`Drop`/span `Part` | `O(k)` | `O(k)` | `O(log n)`, structurally shared |
| `Reverse` | `O(n)` | `O(n)` | `O(1)` (wrapper reversal bit) |
| Flat-attribute flattening | full rebuild | full rebuild | `O(log)` splices per nested child |
| Pattern backtracking cursors | `O(n)` tuple slice per candidate | - | `O(log n)` persistent splits |

Cross-cutting additions: a lazily memoized structural hash on every expression node (the
`SparseArrayExpr._backend` precedent for equality-excluded derived fields), making `SameQ` a
hash-fast-reject plus pointer-fast-accept; an `isCanonicallySorted` bit so the evaluator's
fixed-point Orderless re-normalization of already-sorted arguments costs `O(1)` instead of
`O(n log n)` per pass.

### Corrections from adversarial review (List)

- **Hash direction vs `O(1)` Reverse.** A polynomial rolling hash is orientation-dependent; a
  reversal bit over a forward rope would report the wrong hash and make hash-based fast-reject
  unsound. If the hash lives in the tree measure it must carry
  `(length, forward hash, backward hash, multiplier)` - both directions are associative, and
  carrying `x^len` keeps `Combine` at `O(1)`.
- **Measure placement is a real decision.** A measure is refolded over a boundary chunk (up to
  2048 elements) on every split/slice - pattern-matching backtracking and `Take`/`Drop` chains pay
  hash maintenance on transients that never read the hash. The alternative - memoize the hash on
  the expression wrapper over a plain rope, Merkle-style - keeps structural ops at true `O(log n)`
  and hashes only values actually hashed. Benchmark before committing; for a matcher-heavy engine
  the wrapper placement is likely better.
- **Append amortization is linear-history only.** Rope append is already amortized `O(1)`
  (the trailing chunk grows to 2048), but repeatedly appending to the *same retained version*
  re-pays the trailing-chunk copy. Honest contract: `O(1)` amortized along linear histories,
  `O(log n + chunk)` worst case per call - still removes the quadratic loop trap.
- **Sorting needs its own algorithm.** BCL/array sorts are unstable and throw on inconsistent
  comparators; WL `Sort` accepts arbitrary ordering functions and (community-reported) is stable.
  A predicate-tolerant stable merge sort is required.
- **`ReplacePart` vs `Part` assignment are two paths.** `ReplacePart` silently ignores
  out-of-range rules; `Part` assignment errors. Multi-rule `ReplacePart` takes the *first*
  matching rule per position; right-to-left application is the discipline for `Insert`/`Delete`
  (original-coordinate semantics), not for `ReplacePart`.
- **Packing must be unobservable.** Tungsten's `Integer` is arbitrary-precision and `Real` stores
  text; packed chunks must unpack on `int64` overflow (including overflow produced by Listable
  arithmetic) and must never pack a `Real` whose text does not round-trip through `float64` -
  otherwise packing becomes observable via `SameQ`/`FullForm`, violating the WL guarantee.
- Unmapped-but-required forms flagged by review: negative-step spans (the natural consumer of the
  reversal bit), span/`All` `Part` assignment with broadcast, `Join[..., n]` at level `n`,
  `Flatten` level-transposition form, multi-level `Reverse`/`RotateLeft`, `Riffle` cycling rules.

## TungstenAssociation

The backend accelerator of the parity proposal's `AssociationExpr` (Stage B), composed of:

- **Index**: persistent HAMT `key -> (stamp, value, delayed)` under a structural-hash + SameQ
  comparer (pointer-fast after interning). Scalar lookup is an allocation-free `O(w)` probe,
  `w <= 7` trie levels.
- **Order**: a catenable deque of `(stamp, key, value)` kept **sorted by stamp** (stamps are
  gapped order-maintenance labels: append takes `max + G`, prepend `min - G`, positional insert
  the midpoint). Stamp-sorted means the deque's sorted-search adapter locates any entry by stamp
  in `O(log n)`, positional access is `O(log min(i, n-i))`, and `First`/`Last` are `O(1)`
  worst-case.
- **Reversal flag**: `Reverse` is `O(1)`; the stamp-ascending invariant is physical and survives
  reversal.
- **Values live in both structures** (one extra reference per entry): `a[k]` stays a pure HAMT
  probe while `Keys`/`Values`/`Normal`/`Map` stream off the deque with zero hashing.
- **Small tier** (`n <= ~16`): plain immutable entry array with linear SameQ scan (the parity
  proposal's Stage A dict-index shape remains valid here).

Every kernel-verified rule from the table above maps directly: duplicate-key construction is one
builder pass; `Append` = remove + re-add at max stamp (rule 2); `AssociateTo` = same stamp, both
structures updated in place (rule 3); `assoc[[n]]` is `O(log n)` off the deque (rule 4 - likely
*better* than the kernel); `Rest`/`Most` are `O(w)` shared, so `Rest`-driven recursion goes
quadratic to linearithmic; `Join` of small-into-large is `O(m (w + log n))`, never touching the
big side; sorted results rebuild with fresh stamps (rule 5). The substrate's no-op identity
(equal-value write returns the same instance) gives `evaluate_once` a reference-equality
"nothing changed" signal for the fixed-point loop.

### Corrections from adversarial review (Association)

- **`Real` keys must be normalized by numeric value**, not stored text: WL treats `2.0`, `2.00`,
  and `2.` as the SameQ-identical machine real, so `<\|2.0 -> x\|>[2.00]` must hit. Text-based
  key equality inherits an infidelity.
- **The `delayed` flag must live in the deque entries too**, or `Normal` cannot reconstruct
  `->` vs `:>` without a per-entry HAMT probe, breaking hash-free `O(n)` enumeration.
- **String `Part` subscripts are key access**: `a[["s"]]` routes to the HAMT, not the positional
  path; mixed subscript lists (strings, `Key[...]`, integers) need per-element dispatch.
- **The arguments tuple must be lazily materialized** from the backend. If the full-form tuple is
  eagerly maintained, every operation pays `O(n)` and all wins evaporate; and the cached ordered
  hash must reproduce exactly the structural hash of the materialized
  `Association[Rule[k, v], ...]` form so `AssociationExpr` stays hash-consistent with a plain
  `Call` (the parity proposal's compatibility invariant).
- **Relabeling is not persistence-safe and touches both structures.** Stamps are stored in the
  HAMT and the deque, so a gap-exhaustion relabel of a region rewrites both (`O(region (w +
  log n))`), and the amortized order-maintenance argument assumes linear histories - branching
  from a pre-relabel version can re-pay it. Positional `Insert` is the only operation that needs
  midpoint stamps; contract it honestly.
- **Sequence/Nothing handling inside `Association`** must be owned by `Association`'s own
  construction semantics, not the generic argument-preparation path (WL's `Association` is
  `HoldAllComplete`-adjacent); the recon never tested `Sequence` inside `<\|...\|>` - pin it on a
  kernel before hard-coding.
- Unresolved policy points: `Insert[assoc, k -> v, n]` when `k` already exists (untested in WL);
  `AssociationMap`/`KeyMap` repeated-key position policy (documented "later replaces earlier" is
  ambiguous about position); `Union`/`TakeLargest` mappings.

## Migration Order

Each step is independently shippable and keeps the parity proposal's compatibility rules
(structural equality against plain `Call`, backend never observable):

1. Cached structural hashes on expression nodes + `SameQ` fast paths (independent, immediate win).
2. `TungstenList` behind `Call` with the SmallList tier only (pure refactor, tuple-compatible).
3. LargeList rope tier with complexity-guardrail tests (extend the parity proposal's guardrail
   pattern: assert `Append`-in-a-loop is `O(n)` total, `ReplacePart` touches `O(log n + chunk)`).
4. Hash-placement decision (measure vs wrapper) after benchmarking both under matcher workloads.
5. Association backend per the parity proposal Stage B, with the kernel-verified semantics table
   as the fidelity test spec.
6. Intern table (canonical-instance recovery; epoch sweeping against live roots - a persistent
   pool strong-references everything).
7. Packed tier, with pack/unpack promotion rules and the unobservability guarantee test-locked.

## Substrate Requirements

Whatever library ultimately backs Stage B must provide (gaps found even in the reference
substrates, now recorded in the DataStructures repository's derived-structure catalog):

- a transient/builder bulk-construction path for the hash map (the largest constant-factor loss
  vs the kernel is `O(n * per-insert)` association construction);
- a fused `update(key, fn)` / `get_or_add` (every read-modify-write is otherwise two probe walks -
  hits `Merge`, `Counts`, `GroupBy` hardest);
- either a reversal bit / reverse enumerator on the sequence type or acceptance of the
  wrapper-flag workaround with a pop-loop reverse walk;
- struct/cheap enumeration for the chunked sequence (evaluator iteration is the hottest loop in
  the engine);
- a value-comparer hook on the map's equal-value no-op check, so structural value equality (not
  just reference identity) can trigger the "nothing changed" short-circuit before interning
  lands.

For `rpds-py`/`immutables`-class Python candidates these same questions apply and mostly answer
"no" today; that assessment belongs to the parity proposal's dependency section, not this report.
