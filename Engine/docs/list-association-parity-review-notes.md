# Editorial Notes: Review of the List/Association Parity Proposal

- Status: Editorial record (companion to the parity proposal)
- Audience: Tungsten maintainers; whoever implements the parity work
- Scope: What was checked in [`list-association-parity-proposal.md`](./list-association-parity-proposal.md),
  which claims were corrected, and why
- Created (UTC): 2026-06-30T01:04:11Z
- Repository HEAD: d96f46e4f64def76d86de98efda9bf8ae9f4dba1
- Related docs:
  - [`list-association-parity-proposal.md`](./list-association-parity-proposal.md) (the reviewed proposal)
  - [`list-association-complexity.md`](./list-association-complexity.md) (the diagnostic the proposal builds on)
  - [`architecture.md`](./architecture.md)
- Related code:
  - [`expression.py`](../src/tungsten/expression.py)
  - [`expression_evaluator.py`](../src/tungsten/expression_evaluator.py)
  - [`expression_patterns.py`](../src/tungsten/expression_patterns.py)

## Why this document exists

The parity proposal was drafted by GPT-5.5. It was then reviewed against the *actual* Tungsten
implementation and against live package metadata, and edited in place. Several of the edits change
load-bearing conclusions (which Python the dependency analysis targets, whether Stage A needs a new
dependency at all, whether the recommended Stage B library actually delivers its advertised
performance on this machine). This note records what was verified, what changed, and the reasoning —
so a future implementer does not have to re-derive it, and so the *reversals* are not silently lost.

## How the review was done

Two passes, both grounded in source and in live probes rather than memory:

1. A lead pass that read the cited functions in `expression.py` / `expression_evaluator.py`, ran
   isolated `uv run --isolated --with <pkg>` probes plus PyPI metadata fetches for every named
   dependency, and tested the proposed dataclass shape empirically.
2. A four-dimension adversarial fan-out — *code-facts*, *design-soundness*, *deps-packaging*,
   *doc-conventions* — each agent re-checking one slice against the source. Every finding adopted
   below was re-verified by the lead before being written into the proposal; nothing was taken on an
   agent's word alone. The fan-out earned its keep by catching an error in the lead's own first-pass
   reading (see *The `_rebuild` non-issue*).

## Claims that were verified correct (do not re-litigate)

These were checked and are accurate as written; they are recorded here so the next reader does not
burn time re-confirming them.

- **Every complexity row** in both the proposal's "Operation Parity Targets" table and the companion
  diagnostic's "Association Operation Complexity" table matches the code. Notably non-obvious ones
  that are nonetheless correct: `First`/`Last`/`AssociationQ` are `O(n)` (they all route through
  `_association_entries`, which validates *every* argument — `expression.py:3108`), `assoc[[i]]` is
  `O(n)` because entry extraction dominates the `O(1)` index, and `assoc[key]` (association applied
  as a function) is `O(n)` *twice* (`expression_evaluator.py:569` validates, then `lookup` at
  `:576` rebuilds the entry map).
- **No phantom functions.** Every name in Steps 3 and 4 resolves to a real definition (`merge`
  dispatches to `merge_associations`; `gather`, `gather_by`, `key_complement`, `key_union`,
  `key_intersection`, `key_select`, `position_index`, `counts`, `counts_by`, `group_by`,
  `association_thread`, `association_map` all exist).
- **Duplicate-key semantics.** `append`/`prepend` (`expression.py:12035`/`:12049`) do remove an
  existing key from its slot and re-add it at the end/front; `join` and the constructor keep the
  first slot and update the value (`_normalize_association_entries`, `:3125`). The proposal's
  "Second-Pass Corrections" describe this correctly.
- **`rpds-py` facts.** Version `2026.5.1`, MIT, `requires-python>=3.11`, classifiers through 3.15,
  prebuilt `win_amd64` wheels for cp311/cp312/cp313, full `HashTrieMap` API
  (`get`/`insert`/`remove`/`update`/`keys`/`values`/`items`, plus `discard`/`fromkeys`), and
  `rpds.List` is linked-list-shaped (`first`/`rest`/`push_front`/`drop_first`, no random access) —
  all confirmed. Arbitrary Tungsten `Expr` objects work as keys, including genuine hash collisions
  resolved by `__eq__`.
- **`numpy` is already locked** transitively via `sparse 0.18.0` (`uv.lock`); there is no separate
  numpy line in `pyproject.toml`.
- **Velocity-independent-units rule** is respected — the proposal contains no time-unit work
  estimates.
- **The Call-subclass approach is correctness-safe** on the axes that usually break subclassing:
  there are no `type(x) is Call` exact-type checks and no `dataclasses.replace(call, ...)` calls in
  the evaluator, so a `Call` subclass will not be silently mis-dispatched or reconstructed into the
  wrong type by those mechanisms.

## Corrections applied, with rationale

### 1. The dependency analysis targeted the wrong Python (high)

The proposal stated it probed "the active CPython 3.14.4 interpreter." Tungsten's real runtime —
the one `uv run` selects and the one `requires-python = ">=3.11"` describes — is **CPython
3.13.13**. (Bare `python` on this machine happens to be 3.14.4, which is what the original probe
caught, but that is not what Tungsten executes under.) The interpreter reference was corrected, and
the two dependency-risk statements that depend on it were re-evaluated against 3.13 — with opposite
results in both cases (next two items).

### 2. The `immutables` risk was overstated (medium)

The proposal flagged `immutables` as risky because "package classifiers only name Python 3.8 through
3.12" and "it built from source." Trove classifiers are documentation, not wheel availability. On
the real 3.13 target, `immutables 0.21` ships a prebuilt `immutables-0.21-cp313-cp313-win_amd64.whl`
and installs in seconds with no build. The genuine ceiling is cp314+, which is outside Tungsten's
current runtime. The row was rewritten so `immutables` reads as a viable dev-only reference adapter
on 3.13, not a packaging hazard.

### 3. The `pyrsistent` Stage B recommendation has a real, verified caveat (high)

This is the inverse: the proposal *understated* the `pyrsistent` risk. `pyrsistent 0.20.0` publishes
`win_amd64` wheels only through cp312 (cp38–cp312); there is **no cp313 wheel**. On Tungsten's 3.13
runtime it therefore builds from sdist, and the `pvectorc` C accelerator is **absent**
(`import pvectorc` → `ModuleNotFoundError`, verified), so `PVector` runs as its pure-Python fallback.
`PVector`'s advertised `O(log32 n)` random access / amortized-`O(1)` append profile depends on
`pvectorc`; the pure-Python path does not deliver it. Since that performance profile is the *entire*
reason Stage B reaches for `PVector`, the Stage B section now carries this caveat explicitly and
lists the alternatives (pin a C-extension build, treat it as performance-unverified, or write the
small homegrown 32-way vector the proposal already mentions as the fallback).

### 4. Stage A does not need a new dependency at all (high)

This is the most consequential design change, and it tightens rather than contradicts the proposal.
The proposal makes `rpds-py`'s persistent `HashTrieMap` the *Stage A* dependency. But a persistent
HAMT's distinguishing benefit is **structural sharing across incremental updates** — and Stage A has
no incremental updates to share: every Stage-A association operation already rebuilds the ordered
entries as a brand-new tuple (`O(n)`). Rebuilding a plain `dict[Expr, int]` index alongside it is
the same `O(n)`, so the persistent map buys nothing in Stage A. A **retained plain Python
`dict[Expr, int]`**, built once when the association value is constructed and never mutated (the node
is frozen), already delivers the `O(1)`-repeated-lookup parity that is Stage A's whole goal — with
zero new dependencies. Expr-keyed dicts are already idiomatic in this code
(`_association_entry_map`, the `first_positions` dict in `_normalize_association_entries`).

The proposal's `tungsten.persistent_maps` adapter seam is kept, because it is genuinely useful: Stage
A backs it with a plain dict, and Stage B swaps in `rpds.HashTrieMap` *if and only if* a persistent
ordered-entry vector lands and structural sharing across updates starts to pay. This moves the
`rpds-py` dependency (and acceptance criterion 8's `uv.lock` change) out of the first commit and into
Stage B, which also collapses most of the packaging risk in items 1–3 for the initial landing.

### 5. The `_rebuild` "downgrade" is a non-issue — and is actually a strength (medium)

The lead's first pass worried that generic structural operations (`Map`, `MapAt`, `ReplacePart`,
`Sort`, `KeySort`) would route an `AssociationExpr` through `_rebuild` (`expression.py:18962`), which
constructs a *plain* `Call` and would silently strip the accelerator. The fan-out's code-facts pass
refuted this, and re-reading the source confirms the refutation: each of those operations has a
dedicated association branch that rebuilds through the single canonical constructor
`_association_expr` — `map_expr:16346`, `_try_map_at_path:19531/19535`,
`_try_replace_at_path:19486/19491`, `sort`/`KeySort` via `_rebuild_ordered_expr` → `_association_expr`.
`_rebuild` is only reached on the *non*-association branch.

Because `_association_expr` (`:3141`/`:3143`) is the **single funnel** for every valid *evaluated*
association value — the only other association constructions are two deliberate held/unevaluated
paths that *should* stay a plain `Call`: the malformed/held fallback in `association()` at `:16451`
(reached when the arguments are not all valid rules) and the parser's raw `<|…|>` node
(`expression_parser.py:1643`) — changing `_association_expr` to return an `AssociationExpr` upgrades
the entire evaluated structural surface for free, with no per-operation edits. The proposal now states this as the strength it is. The one genuine residual is documented:
the head-replacing rewrites in `expression_patterns.py` (around `:1571` and `:1640`) intentionally
emit a plain `Call` when the head itself is substituted, and must *not* be coerced back into an
`AssociationExpr`.

### 6. `AssociationExpr` is not an architectural peer of `SparseArrayExpr` (medium)

Step 7 told the future `architecture.md` edit to add `AssociationExpr` "beside `SparseArrayExpr` as a
specialized expression node." But `architecture.md:215` calls `SparseArrayExpr` a specialized
*atomic* node, and the code confirms it: `SparseArrayExpr(Expr)` and `ByteArrayExpr(Expr)` are
atomic `Expr` subclasses (`expression.py:397`/`:367`), whereas the proposed `AssociationExpr(Call)`
is a *non-atomic* `Call` subclass with a visible head and arguments. They sit at different points in
the hierarchy. The guidance was reworded so the architecture edit introduces `AssociationExpr` as the
first *Call-subclass* specialized node, distinct from the atomic pattern. The genuine commonality —
worth citing in `architecture.md` — is the *idiom*: a frozen specialized node carrying a derived
accelerator field that is excluded from equality/hash/repr (see next item).

### 7. The dataclass sketch should follow the in-repo `SparseArrayExpr` idiom (medium)

The proposal's snippet declares `entries` and `key_index` as constructor fields the caller must
supply, which makes them a second source of truth alongside `arguments` (each entry is just the
parsed form of a rule `Call`) and invites drift. The repository already has the right pattern:
`SparseArrayExpr` carries `_backend = field(default=None, init=False, compare=False, repr=False,
hash=False)` and derives it in `__post_init__` via `object.__setattr__` (the frozen-dataclass escape
hatch). `AssociationExpr` should do the same — keep `arguments` as the single source of truth and
derive `entries` + `key_index` in `__post_init__` — so the accelerators cannot disagree with the
visible shape and callers carry no construction obligation.

Three things were verified empirically and folded into the text: (a) the manual `__eq__` is
**mandatory**, not stylistic — relying on the inherited dataclass `__eq__` produces objects that are
*hash-equal but not equal* to the corresponding plain `Call` (a real `dict`/`set` corruption: the set
`{assoc, plain_call_same_shape}` fails to collapse), whereas the manual override gives correct
bidirectional equality and a single set/dict slot; (b) the manual `__hash__` is **also mandatory, and
for a separate reason** — writing a `__eq__` in the class body makes Python null the inherited
`__hash__` (the standard "a class that overrides `__eq__` is unhashable unless it also defines
`__hash__`" rule), and `eq=False` does *not* prevent this (it only suppresses the *dataclass-generated*
`__eq__`, not Python's reaction to a hand-written one). Verified: with the manual `__eq__` but no
manual `__hash__`, the subclass is `unhashable type`. So the snippet is right to define both; the
prose should say *why* both are needed. (c) Subclassing a frozen `Call` with a frozen `eq=False`
subclass and `compare=False` private fields constructs and behaves correctly.

### 8. `HashTrieMap` iteration order is non-deterministic, not merely non-insertion-order (medium)

The proposal warns against relying on `HashTrieMap` iteration order for Wolfram-visible order. The
reality is stronger: iteration order is **non-deterministic across identical builds** — inserting the
same keys in the same order twice yields different `keys()` orderings. That makes the "order lives
only in `entries`, never in `key_index`" invariant load-bearing for reproducibility, so the test that
asserts it is mandatory, not optional. The risk row and Step 5 were strengthened accordingly. (This
only matters once `rpds` is actually in use, i.e. Stage B — but the invariant should be stated up
front.)

### 9. Smaller consistency fixes (low)

- **Provenance refresh.** `Updated (UTC)` and `Repository HEAD` were refreshed to the current HEAD
  on edit, per the repo rule.
- **Internal consistency.** The `Lookup[assoc, keys]` "Current Tungsten" cell read `O(n + m)` in the
  proposal but `O(n·h(key) + m·h(key))` in the diagnostic; the `h(key)` factor is now carried
  consistently, matching the diagnostic's own notation section.
- **Acceptance criterion 1** dropped the "or an equivalent specialized node" hedge that made it
  non-testable, and now names the concrete deliverable.
- **Step 4** now names `_association_from_arguments` as the constructor the builder replaces, and
  notes that `KeySort` already routes through `_rebuild_ordered_expr` → `_association_expr`.

## Open questions deferred to implementation

- **Stage B ordered-entry storage** has no library answer, and this is now settled: `rpds-py` exposes
  no random-access `Vector` (only `HashTrieMap`/`HashTrieSet`/`List`/`Queue`/`Stack`), and
  `pyrsistent.PVector` is pure-Python on this runtime, so a small homegrown 32-way bitmapped vector
  trie is the only viable ordered store. It makes only the new-key-`Append` / value-replace /
  random-index cases sub-linear; the order-rearranging cases (existing-key `Append`, `Prepend`,
  `KeyDrop`) stay `O(n)` short of a finger tree that no one should write speculatively. The whole
  thing is measurement-gated (Step 6) and may simply never be built, since bulk construction is
  already `O(N)` via the builder.
- **Append under a persistent vector** splits cleanly, and the proposal's two Append rows are already
  honest about it: appending a *new* key (the `Append[assoc, newKey -> v]` row) is a pure
  push-at-end, legitimately `O(log n)` on a persistent vector once the absence check goes through the
  retained index; appending an *existing* key (the `Append[assoc, oldKey -> v]` row) is *not* claimed
  to be `O(log n)` — that row says "order maintenance is not lookup-only" precisely because Wolfram
  moves the duplicate to the end, which requires deleting from an arbitrary interior position, and a
  persistent vector has no efficient interior delete. The one thing both rows gloss is that Stage B
  must *also* remove the unconditional `_normalize_association_entries` re-scan that currently sits
  behind `_association_expr` (`expression.py:3125`/`:3143`); swapping the storage alone does not remove
  it.
- **Small-association threshold.** Whether to keep a tuple-only (no retained index) representation
  below some entry count, to avoid the dict/map overhead on tiny associations, is left to
  measurement.
