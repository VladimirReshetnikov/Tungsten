# Tungsten List and Association Complexity Parity Proposal

- Status: Proposal
- Audience: Tungsten maintainers working on the kernel-free expression evaluator
- Scope: `List` and `Association` representation, asymptotic parity, dependency choice, validation, and rollout
- Created (UTC): 2026-06-28T23:00:26Z
- Updated (UTC): 2026-06-30T01:04:11Z
- Repository HEAD: d96f46e4f64def76d86de98efda9bf8ae9f4dba1
- Related code:
  - [`expression.py`](../src/tungsten/expression.py)
  - [`expression_evaluator.py`](../src/tungsten/expression_evaluator.py)
  - [`expression_patterns.py`](../src/tungsten/expression_patterns.py)
  - [`pyproject.toml`](../pyproject.toml)
  - [`uv.lock`](../uv.lock)
- Related docs:
  - [`list-association-complexity.md`](./list-association-complexity.md)
  - [`list-association-parity-review-notes.md`](./list-association-parity-review-notes.md)
  - [`association-support-plan.md`](./association-support-plan.md)
  - [`expression-function-support.md`](./expression-function-support.md)
  - [`architecture.md`](./architecture.md)
- External references:
  - [Wolfram Language: Some Notes on Internal Implementation](https://reference.wolfram.com/language/tutorial/SomeNotesOnInternalImplementation.html)
  - [Wolfram Language: Association](https://reference.wolfram.com/language/ref/Association.html)
  - [Wolfram Language: Associations guide](https://reference.wolfram.com/language/guide/Associations.html)
  - [Wolfram Language: `Developer`PackedArrayQ`](https://reference.wolfram.com/language/Developer/ref/PackedArrayQ.html)
  - [rpds.py documentation](https://rpds.readthedocs.io/en/latest/)
  - [rpds-py on PyPI](https://pypi.org/project/rpds-py/)
  - [immutables on PyPI](https://pypi.org/project/immutables/)
  - [Pyrsistent on PyPI](https://pypi.org/project/pyrsistent/)
  - [Sorted Containers on PyPI](https://pypi.org/project/sortedcontainers/)

## Purpose

[`list-association-complexity.md`](./list-association-complexity.md) records the current asymptotic
gap: Tungsten's ordinary `List` representation is broadly array-like, but Tungsten's `Association`
representation is still list-of-rules-like. Repeated scalar key operations rebuild or rescan the
entry list, so workloads that should be lookup-like become linear in the number of association
entries.

This proposal turns that diagnosis into an implementation plan. The target is asymptotic parity
with Wolfram's public working model for association operations, while preserving Tungsten's current
public syntax and structural evaluator boundaries.

## Review status

This document was reviewed against the actual Tungsten implementation and against live package
metadata. The complexity claims, function lists, and duplicate-key semantics all held up; several
dependency and design statements were corrected. The substantive changes — most importantly that
**Stage A needs no new dependency**, that the recommended Stage B library (`pyrsistent`) ships no
wheel for Tungsten's runtime, and that the single canonical constructor `_association_expr` makes the
whole structural surface upgrade for free — and the reasoning behind each are recorded in
[`list-association-parity-review-notes.md`](./list-association-parity-review-notes.md). Read that
companion note for the *why*; this document now reflects the corrected *what*.

## Target Outcome

Tungsten should keep the external expression contract:

```text
Association[Rule[key1, value1], Rule[key2, value2], ...]
```

Internally, evaluated associations should be specialized values with:

- ordered entries for Wolfram's stable key/value order;
- a retained key index for lookup, membership, and key-path operations (a plain `dict` in Stage A, a
  persistent map in Stage B);
- builder paths for bulk construction so `Association`, `Join`, `Merge`, `GroupBy`, `Counts`,
  `PositionIndex`, and similar producers remain linear in their total input size;
- formatting, `FullForm`, `InputForm`, `Normal`, JSON export, pattern traversal, and public helper
  behavior identical to the current association surface.

The parity target is asymptotic and output-sensitive. Operations that return `k` results still
perform at least `O(k)` work and allocation. Operations that must preserve or filter all entries
still have an `O(n)` lower bound. The gap to close is the avoidable `O(n)` scan on independent key
queries and on helper calls that only need one entry.

## Non-Goals

This proposal does not make Tungsten a full Wolfram kernel. It does not add `Dataset`, `Query`,
stateful `AssociateTo`, general mutation semantics, or complete packed-array arithmetic.

It also does not require changing the parser's public AST rendering. The goal is a better runtime
representation behind the same Wolfram-facing shape.

## Current Local Findings

The current implementation has these relevant properties:

- `Call(head_expr, arguments)` stores arguments in a Python tuple.
- A Tungsten list is `Call(Symbol("List"), tuple_of_arguments)`.
- A Tungsten association is currently `Call(Symbol("Association"), tuple_of_rule_calls)`.
- `_association_entries(expr)` validates every rule argument and returns a tuple of
  `_AssociationEntry` records.
- `_association_entry_map(entries)` builds a temporary Python `dict`.
- `Lookup`, `KeyTake`, `Part[assoc, Key[key]]`, `First`, `Last`, and many association-aware
  functions begin by re-extracting the full entry tuple.
- `_association_expr(...)` (`expression.py:3141`) is the **single canonical constructor** for every
  *evaluated* association value. The structural operations that transform an association — `Map`
  (`map_expr:16346`), `MapAt` (`_try_map_at_path:19531`), `ReplacePart` (`_try_replace_at_path:19486`),
  `Sort`/`KeySort` (via `_rebuild_ordered_expr`) — already rebuild through `_association_expr`, *not*
  through the generic `_rebuild`; `_rebuild` is reached only on their non-association branches. The
  only constructions that bypass `_association_expr` are the deliberately held/unevaluated paths that
  should remain plain `Call` values: the malformed/held fallback in `association()` (`:16451`) and the
  parser's raw `<|…|>` node (`expression_parser.py:1643`).

The important consequence is not just a slower constant. Scalar lookup-like operations are
structurally linear because the key index is not retained on the association value. Conversely, the
single-constructor funnel is the lever this proposal pulls: replacing what `_association_expr` returns
upgrades the entire evaluated association surface at once.

## Second-Pass Corrections

The second review changed several parts of the first draft.

- Stage A should be described as **lookup parity**, not full update parity. With ordered entries
  stored in a Python tuple, `Append`, `Prepend`, and key-based `ReplacePart` still allocate a new
  entry tuple. They can reuse a retained key index path, but their returned ordered storage is
  still `O(n)` until Stage B adds a persistent random-access entry vector.
- The first implementation should **subclass `Call`** or otherwise preserve the `Call` fields
  exactly. The current evaluator is heavily `Call`-centric; a standalone `AssociationExpr(Expr)`
  would require a broad audit before it could be safe.
- The retained key index needs **no new dependency in Stage A**: a plain `dict[Expr, int]` built once
  on the frozen association value gives `O(1)` repeated lookup, because every Stage-A update already
  rebuilds the entry tuple in `O(n)`. `rpds.HashTrieMap` is the right backing for **Stage B**, where
  structural sharing across persistent-vector updates matters; `immutables` is a dev-only alternate.
  Both install from prebuilt `cp313` Windows wheels on Tungsten's actual 3.13 runtime (the earlier
  draft's "CPython 3.14 / built from source" note probed the wrong interpreter).
- `rpds.List` is not a Stage B ordered-entry candidate: its API is linked-list-shaped, with
  `first`, `rest`, `push_front`, and `drop_first`, not random access.
- Duplicate-key behavior is not one generic rule. Constructor-like operations (`Association`,
  `Join`, `KeyMap`) preserve the first key slot while updating to the last value; `Append` and
  `Prepend` deliberately move a replaced key to the end or start, respectively.

## Library Recommendation

The key index can be retained **without any new dependency in Stage A**, and with a maintained
persistent-map library in Stage B. The two stages have genuinely different needs:

- **Stage A** stores ordered entries in a plain tuple and rebuilds the whole node on every update. A
  persistent hash trie's one distinguishing benefit — structural sharing across incremental updates —
  therefore buys nothing here: each Stage-A update already rebuilds the entry tuple in `O(n)`, so
  rebuilding a key index in `O(n)` alongside it is the same order. A **retained plain
  `dict[Expr, int]`**, built once when the (frozen) association value is constructed and never
  mutated, already delivers the `O(1)`-repeated-lookup parity that is Stage A's goal — with zero new
  dependencies. Expr-keyed dicts are already idiomatic in this code (`_association_entry_map`, the
  `first_positions` dict in `_normalize_association_entries`).
- **Stage B** adds a persistent ordered-entry vector so incremental updates can structurally share
  storage. Only then does a persistent key index that shares structure across updates start to pay,
  and only then is a persistent-map library worth its weight.

To keep call sites stable across both stages, put the index behind a tiny adapter
(`tungsten.persistent_maps`) so the backing implementation can change without touching association
semantics. Stage A backs the adapter with a plain `dict`; Stage B can swap in a persistent map.

The dependency survey below was run against Tungsten's actual runtime — **CPython 3.13.13**
(`uv run python`), with `requires-python = ">=3.11"` — using isolated `uv run --isolated --with ...`
probes plus PyPI metadata, on 2026-06-29. (An earlier draft probed bare `python`, which on this
machine is 3.14.4; that is not the interpreter Tungsten executes under, and two of the risk
conclusions below flip when the target is corrected to 3.13.)

| Package | Version | Fit on the 3.13 Windows target | Recommendation |
|---|---:|---|---|
| `rpds-py` | `2026.5.1` | Rust-backed persistent `HashTrieMap`, MIT, `requires-python>=3.11`, classifiers 3.11–3.15. Prebuilt `win_amd64` wheels for cp311/cp312/cp313, so it installs with no Rust build. API confirmed: `get`, `insert`, `remove`, `update`, `keys`, `values`, `items` (plus `discard`, `fromkeys`). Arbitrary `Expr` objects work as keys, including hash collisions resolved by `__eq__`. Adds **zero** transitive dependencies. | Best **Stage B** persistent-map dependency; **not needed in Stage A**. The adapter must not rely on `HashTrieMap` iteration order — it is non-deterministic even across identical builds (see Step 5). |
| `immutables` | `0.21` | Direct HAMT-backed immutable `Map`, Apache 2.0, explicit `O(log N)` get/set. On the 3.13 target it installs from a **prebuilt `cp313` `win_amd64` wheel** with no source build; the stale `3.8–3.12` classifiers are documentation, not wheel availability. The only real gap is cp314+, outside Tungsten's current runtime. | Viable dev-only reference backing for Stage B (it documents the exact HAMT model). `rpds-py` is preferred for the wider classifier range. |
| `pyrsistent` | `0.20.0` | MIT; `PVector`/`PMap`; docs cite amortized `O(1)` append and `log32(n)` random access — **but those numbers require the `pvectorc` C extension.** `pyrsistent 0.20.0` publishes `win_amd64` wheels only through `cp312` (no `cp313`), so on Tungsten's 3.13 runtime it builds from sdist and `pvectorc` is **absent** (`import pvectorc` → `ModuleNotFoundError`, verified); `PVector` then runs as its pure-Python fallback, which does **not** deliver the advertised profile. | Do **not** assume `pyrsistent.PVector` for Stage B without resolving this: pin a verified C-extension build, treat it as performance-unverified, or prefer the homegrown 32-way vector. |
| `sortedcontainers` | `2.4.0` | Apache 2.0, pure-Python (so its very old classifiers are not a runtime concern). | Do not use for `Association`; sorted-key order is the wrong semantic model. |
| `numpy` | `2.4.4` (locked transitively via `sparse 0.18.0`) | Contiguous numeric arrays. | Useful for a later packed numeric list optimization, not for general symbolic `Association`. |

Recommended dependency shape:

1. Add a private adapter module, `tungsten.persistent_maps`, with a minimal protocol:
   `empty()`, `from_items()`, `get()`, `contains()`, `insert()`, `remove()`, and `update_many()`.
2. **Stage A: back it with a plain `dict[Expr, int]`.** No new dependency, no `uv.lock` change.
3. **Stage B: swap in `rpds.HashTrieMap`** behind the same protocol, if and when a persistent
   ordered-entry vector lands and structural sharing across updates is worth measuring. `immutables`
   is an acceptable alternate backing during that spike.
4. Keep the old temporary Python `dict` logic only as a builder/transient implementation, not as the
   retained association representation.

This gives Tungsten the `O(1)`-lookup parity immediately, with no dependency footprint until Stage B
makes one worthwhile, and without entangling association semantics with one package's public API.

## Proposed Representation

Introduce a specialized association node. For the first implementation, it should remain a
`Call`-compatible object:

```python
@dataclass(frozen=True, eq=False)
class AssociationExpr(Call):
    # Derived accelerators, not independent state: the inherited `arguments`
    # tuple stays the single source of truth (mirrors SparseArrayExpr._backend).
    entries: tuple[_AssociationEntry, ...] = field(
        default=(), init=False, compare=False, hash=False, repr=False
    )
    key_index: "PersistentMap[Expr, int]" = field(  # a plain dict in Stage A
        default=None, init=False, compare=False, hash=False, repr=False
    )

    def __post_init__(self) -> None:
        entries = _entries_from_arguments(self.arguments)
        object.__setattr__(self, "entries", entries)
        object.__setattr__(self, "key_index", _key_index_from_entries(entries))

    def __eq__(self, other: object) -> bool:
        # Structural equality against any Call-compatible value, including a plain
        # Call[Association, ...] of the same shape. The dataclass-generated __eq__
        # is class-sensitive and would treat that Call as unequal.
        return (
            isinstance(other, Call)
            and self.head_expr == other.head_expr
            and self.arguments == other.arguments
        )

    def __hash__(self) -> int:
        # Same hash as the equivalent plain Call. Mandatory, not optional: defining
        # __eq__ above nulls the inherited __hash__ (Python's standard rule), and
        # eq=False does NOT prevent that — it only suppresses the generated __eq__.
        return hash((self.head_expr, self.arguments))
```

The required behavioral contract is:

- `head()` returns `Symbol("Association")`.
- `args()` returns the rule expressions in association order.
- `has_head("Association")` returns `True`.
- `to_full_form()` renders exactly as `Association[Rule[...], ...]`.
- `to_input_form()` renders exactly as `<|...|>` through the existing formatter.
- `to_dict()` remains call-shaped, so CLI JSON output does not gain a new public node kind.
- equality and hashing remain structural with respect to the Wolfram full form, not with respect to
  the private index object.

Implementation preference:

- Keep the inherited `head_expr` and `arguments` fields as the visible Wolfram expression shape, and
  treat `arguments` as the **single source of truth**. Derive `entries` and `key_index` from it in
  `__post_init__` via `object.__setattr__`, exactly as `SparseArrayExpr` derives its `_backend`
  accelerator (`expression.py:401`–`404`). This makes it impossible for the accelerators to disagree
  with the visible shape and removes any construction obligation from callers.
- Mark `entries` and `key_index` as `init=False`, `compare=False`, `hash=False`, `repr=False`, so they
  are private accelerators excluded from equality, hashing, and rendering.
- Implement equality against `Call`-compatible values by comparing only `head_expr` and `arguments`.
  The dataclass-generated equality method is not sufficient because it is class-sensitive — it would
  make an `AssociationExpr` unequal to an otherwise-identical plain `Call[Association, ...]`.
- Implement `__hash__` explicitly as the same visible-shape hash used for an ordinary `Call`. This is
  **mandatory, not optional**: defining `__eq__` in the class body nulls the inherited `__hash__`
  (Python's standard "overriding `__eq__` makes a class unhashable unless it also defines `__hash__`"
  rule), and `eq=False` does not prevent it — `eq=False` only suppresses the *dataclass-generated*
  `__eq__`. Without the explicit `__hash__`, the node is `unhashable type` (verified).
- Store `key_index` as `key -> entry_index` (an index, not an entry) so value replacement can update a
  single ordered slot while leaving the key map unchanged.
- `arguments` is stored eagerly (it is an ordinary `Call` field), which matters because much code
  reads `.arguments` directly after an `isinstance(expr, Call)` check.
- Make `_association_expr(...)` the only constructor that returns `AssociationExpr` for valid
  association values, and `_association_entries(expr)` return `expr.entries` in `O(1)` for an
  `AssociationExpr`.
- Keep the raw `Call(Symbol("Association"), ...)` path valid for held or malformed syntax that has not
  yet gone through evaluator normalization — the `association()` held fallback (`expression.py:16451`)
  and the parser's raw `<|…|>` node (`expression_parser.py:1643`) must stay plain `Call` values.

## Builder Contract

Bulk association producers should not build the key index one key at a time if they already have all
entries in hand. Add a mutable internal builder:

```python
class AssociationBuilder:
    ordered: list[_AssociationEntry]
    positions: dict[Expr, int]

    def append_constructor_entry(entry): ...
    def append_to_end(entry): ...
    def prepend_to_start(entry): ...
    def set_existing_value(index, value): ...
    def freeze() -> AssociationExpr: ...
```

The builder needs explicit normalization modes:

- constructor/merge mode: first key slot survives, later duplicate value replaces it;
- append mode: any old key slot is removed, then the new entry is appended;
- prepend mode: any old key slot is removed, then the new entry is inserted at the front.

The builder is private and short-lived. It is used for:

- `Association[...]` construction and nested association/list-of-rule normalization;
- `Join` over associations;
- `AssociationThread` and `AssociationMap`;
- `Merge`, `GroupBy`, `GatherBy`, `Counts`, `CountsBy`, `PositionIndex`, and other association
  producers;
- `KeyMap`, when duplicate mapped keys must be normalized;
- JSON object import into `Association`.

This preserves `O(N)` construction for `N` total input entries and builds the key index once at freeze
time (a plain `dict` in Stage A).

## Operation Parity Targets

The table below uses `B` for the persistent hash-trie branching factor and `h(key)` for structural
hash/compare cost. The `log_B n` factors describe the Stage B / Wolfram-HAMT model; **Stage A's
plain-`dict` index realizes the scalar-lookup rows as `O(h(key))` — amortized `O(1)` in `n`, at least
as good as the `log_B n` bound shown.**

| Operation | Current Tungsten | Proposed Tungsten | Notes |
|---|---:|---:|---|
| `AssociationQ[assoc]` | `O(n)` | `O(1)` | `AssociationExpr` is already validated. |
| `Length[assoc]` | `O(1)` | `O(1)` | Entry count is stored. |
| `First[assoc]`, `Last[assoc]` | `O(n)` | `O(1)` | Read ordered endpoint directly. |
| `Keys`, `Values`, `Normal` | `O(n)` | `O(n)` | Output-size dominated. |
| `Lookup[assoc, key]` | `O(n * h(key))` | `O(log_B n * h(key))` | Retained key-index lookup (`O(h(key))` with the Stage A dict). |
| `Lookup[assoc, keys]` | `O((n + m) · h(key))` | `O(m log_B n · h(key) + m)` | Proposed shape wins when `m << n`; both are output-sensitive. `h(key)` carried as in the companion doc. |
| `KeyExistsQ`, `KeyMemberQ` | `O(n * h(key))` | `O(log_B n * h(key))` | Same key-index path as `Lookup`. |
| `assoc[[Key[key]]]` | `O(n * h(key))` | `O(log_B n * h(key))` | Route `_select_association_entry` through the index. |
| `assoc[[i]]` | `O(n)` | `O(1)` with tuple entries | If entries later move to a persistent vector, this becomes `O(log n)`. |
| `KeyTake[assoc, keys]` | `O(n + m)` | `O(m log_B n + m)` | Output order follows the key spec. |
| `KeyDrop[assoc, keys]` | `O(n + m)` | `O(n + m log_B n)` or `O(n + m)` | Filtering all entries is output-sensitive; build a transient key set for large `m`. |
| `Append[assoc, newKey -> v]` | `O(n)` | Stage A: `O(n)`; Stage B: `O(log n)`-like if ordered entries become persistent-vector-backed | Stage A still copies the ordered-entry tuple. |
| `Append[assoc, oldKey -> v]` | `O(n)` | Stage A: `O(n)`; Stage B still needs order-maintenance work | Wolfram moves the surviving key position for append-like replacement, so order maintenance is not lookup-only. |
| `ReplacePart[assoc, Key[k] -> v]` | `O(n)` | Stage A: `O(n)`; Stage B: `O(log_B n + log n)`-like | Stage A lookup is fast, but the tuple slot replacement copies `O(n)` pointers. |
| Construct from `N` rules | `O(N)` | `O(N)` | Builder path preserves current asymptotics and improves constants by avoiding duplicate scans. |

The first implementation should close every scalar key-operation row. Persistent ordered-entry
storage is a second representation decision, not a blocker for removing the current lookup scans.
The plan should therefore be read as two-tiered: Stage A fixes repeated scalar lookup; Stage B is the
only stage that can plausibly fix update-heavy association loops.

Because the structural operations already rebuild associations through the single constructor
`_association_expr` (see *Current Local Findings*), Stage A needs no per-operation edits for them:
changing what `_association_expr` returns makes `Map`, `MapAt`, `ReplacePart`, `Sort`, and `KeySort`
emit `AssociationExpr` values automatically. The one boundary to respect is the head-replacing rewrite
in `expression_patterns.py` (around `:1571` and `:1640`): when a rule rewrites the head away from
`Association`, the result is intentionally a plain `Call` and must not be coerced back into an
`AssociationExpr`. The upgrade logic must therefore key on *"head is `Association` and the entries are
valid"* (the existing guard), never on *"the input was an `AssociationExpr`, so preserve the
subclass"*.

## Persistent Ordered Entries Decision

The ordered-entry structure has two viable stages.

### Stage A: tuple entries plus a retained key index

This is the recommended first implementation:

- lowest disruption;
- keeps numeric positional access `O(1)`;
- fixes repeated scalar key operations;
- keeps formatter and traversal behavior simple;
- needs **no new dependency** — the key index is a plain `dict[Expr, int]` built once on the frozen
  node (see *Library Recommendation*).

It does not make single-slot update results structurally shared; replacing one entry still creates a
new tuple of entries (and a new index).

### Stage B: persistent vector for ordered entries

Stage B is **measurement-gated** (Step 6), and the honest default is that it may never be needed. If
it is, the plan is *not* "pick a library", because no maintained package with `cp313` wheels provides
the structure Stage B wants. The findings, verified on the 3.13 Windows runtime:

- `rpds-py` — the already-chosen map dependency — exposes only `HashTrieMap`, `HashTrieSet`, `List`,
  `Queue`, and `Stack`. There is **no random-access persistent `Vector`** (the Rust `rpds` crate has
  one; the Python binding does not surface it). `rpds.List` is a linked list
  (`first`/`rest`/`push_front`/`drop_first`), not random access.
- `pyrsistent.PVector` would fit, but ships no `cp313` wheel, so it falls back to pure Python on this
  runtime (`pvectorc` absent) and loses its advertised profile. Its silent C-extension degradation
  also runs against the repo preference for explicit, non-opaque dependency behavior, so it should not
  be a runtime dependency — at most a benchmark oracle on machines where its C extension is present.

A persistent ordered-entry vector therefore means a **small homegrown 32-way bitmapped vector trie**
(the structure `pyrsistent.PVector` itself implements — ~150–250 LOC, pure-Python, no dependency),
with the key index moved from the Stage A plain `dict` to `rpds.HashTrieMap` via the `persistent_maps`
adapter so it too shares structure across updates. Correctness is testable against `pyrsistent` where
its C extension is available.

Even this only fixes *half* the update surface, and the split is fundamental, not a library
limitation:

- **Sub-linear with a bitmapped vector trie:** `Append` of a *new* key (push-at-tail), value
  replacement / `ReplacePart` (set-at-index), and random `assoc[[i]]` — all `O(log32 n)`.
- **Stays `O(n)`:** the *order-rearranging* operations — `Append` of an *existing* key (Wolfram moves
  it to the end), `Prepend`, and `KeyDrop` — because they delete from an interior position, which a
  bitmapped vector trie cannot do sub-linearly. Making those `O(log n)` needs an RRB-tree or finger
  tree with `O(log n)` split/concat, for which there is no maintained Python library and whose
  pure-Python constants would likely eat the asymptotic win. Do not build one without a specific
  workload that demands it.

Whichever path is taken, introduce it only after Stage A, with focused tests showing which operations
still miss the parity target.

## List Strategy

Generic Tungsten `List` is not the urgent asymptotic gap. A Python tuple already gives:

- `Length` in `O(1)`;
- integer `Part` in `O(1)`;
- output-size behavior for `Rest`, `Most`, `Take`, `Drop`, `Join`, `Map`, and traversal.

Do not replace general symbolic lists with a persistent vector by default, because that would risk
turning the most important positional operation from `O(1)` into `O(log n)`.

The list-side proposal is limited to two follow-ups:

1. Add builder helpers for functions that currently build intermediate tuples repeatedly instead of
   using one mutable Python list and freezing once.
2. Add a separate packed numeric list representation later, probably backed by NumPy arrays already
   present through the `sparse` dependency, for homogeneous machine integer, real, and complex
   arrays. This is a memory/locality parity effort, not the same asymptotic fix as associations.

## Implementation Plan

### Step 1. Add the key-index adapter

Add `tungsten.persistent_maps` with the required map protocol and a **Stage A implementation over a
plain `dict[Expr, int]`** — no new third-party dependency. The adapter exists so that Stage B can swap
in `rpds.HashTrieMap` behind the same protocol without touching call sites.

Adapter requirements:

- accepts Tungsten `Expr` objects as keys, preserving structural equality for existing atom and `Call`
  keys (the existing `_association_entry_map` already relies on Expr-keyed dicts, so this is free);
- supports lookup, membership, insert, remove, and bulk construction;
- never exposes or depends on map iteration order for Wolfram-visible association order — when the
  Stage B `rpds.HashTrieMap` backing arrives its iteration order is non-deterministic even across
  identical builds, so order must always come from `entries` (see Step 5).

Expected files touched in Stage A: one new adapter module and one focused test module. No
`pyproject.toml` / `uv.lock` change is needed until Stage B introduces a real persistent map.

### Step 2. Introduce `AssociationExpr`

Implement the specialized node as a `Call` subclass and change `_association_expr(...)` to return it.

Required helper changes:

- `_association_entries(expr)` returns entries in `O(1)` for `AssociationExpr`.
- `_association_entry_map(...)` is replaced by `_association_key_index(expr)` and
  `_association_get_entry(expr, key)`.
- `_association_values(expr)` reads entries directly.
- `_association_from_arguments(...)` uses `AssociationBuilder`.
- `to_full_form`, `to_input_form`, `to_dict`, and `args` remain public-shape compatible.
- `AssociationExpr` equality and hash are implemented explicitly so they match the visible
  `Call[Association, ...]` shape, not the cache fields or Python subclass identity.

Expected files touched: `expression.py`, possibly one extracted association helper module, plus
tests.

### Step 3. Route scalar key operations through the retained index

Update these APIs first:

- `lookup`;
- `key_exists_q`;
- `key_member_q`;
- `_select_association_entry`;
- association string-key shorthand in `Part`;
- association function position lookup in `expression_evaluator.py`.

The old full-entry scan should remain only for malformed raw `Call[Association, ...]` values that
come from held or manually constructed syntax and have not been normalized.

The association-as-function path (`expression_evaluator.py:569`–`576`) is `O(n)` *twice* today — once
validating the head via `_association_entries`, then again inside `lookup`. Route it through an
`isinstance(evaluated_head, AssociationExpr)` fast path (mirroring the `SparseArrayExpr`-as-function
dispatch already at `:588`) that passes the already-validated value into a lookup overload that does
not re-validate.

Expected tests: scalar lookup, missing lookup, string key lookup, key path lookup, function-position
lookup (`assoc[key]`), and repeated lookup guardrails.

### Step 4. Route bulk association operations through builders

Update every association producer to freeze through `AssociationBuilder`:

- `Association` (the constructor is `_association_from_arguments`, `expression.py:3157`);
- `Append`, `Prepend`, `Join`;
- `KeyTake`, `KeyDrop`, `KeyMap`, `KeySelect`;
- `AssociationThread`, `AssociationMap`;
- `Merge` (dispatched to `merge_associations`), `GroupBy`, `GatherBy`, `Gather`;
- `KeyComplement`, `KeyUnion`, `KeyIntersection`;
- `Counts`, `CountsBy`, `PositionIndex`;
- JSON import paths and failure-detail constructors.

This step should remove duplicate ad hoc normalization logic and keep constructor-style operations
linear in total input size.

`KeySort` and value-`Map` are intentionally *not* in this list: they already funnel through
`_association_expr` (`KeySort` via `_rebuild_ordered_expr`), so they emit `AssociationExpr` values
automatically once Step 2 lands. The builder is needed only where a producer would otherwise construct
an intermediate `dict` or re-normalize from scratch.

### Step 5. Add complexity guardrails

Unit tests should include instrumentation that catches accidental full scans in scalar paths. Good
guardrails:

- monkeypatch or wrap `_association_entries` in a test-only counter and assert repeated
  `Lookup[assoc, key]` does not re-validate every rule once the value is an `AssociationExpr`;
- use a custom `Expr` key type with counted `__hash__` and `__eq__` calls to detect `R * n`
  comparison growth on `R` repeated independent lookups;
- monkeypatch `_rule_entry` in scalar-path tests, because the old implementation revalidates every
  visible rule during lookup;
- assert that Wolfram-visible order (`Keys`, `Values`, `Normal`) comes only from `entries`, never from
  the key index. This is **mandatory once the Stage B `rpds.HashTrieMap` backing is in use**, because
  `HashTrieMap` iteration order is non-deterministic *even across identical insertion sequences*, so
  any reliance on it would be a latent reproducibility bug — add a test with keys whose map iteration
  order differs from insertion order;
- add a microbenchmark script under `src/Tungsten/scripts/` that reports slopes for association
  sizes such as 10, 100, 1000, and 10000 entries without becoming a correctness gate.

The unit guardrails should be correctness-oriented. The microbenchmark is informational because
wall-clock timing is machine-sensitive.

### Step 6. Decide whether Stage B ordered storage is needed

After Stage A lands, evaluate these update-heavy cases:

- repeated `Append` of new keys;
- repeated `ReplacePart` on an existing association key;
- `Fold[Append, <||>, rules]` if the evaluator supports the relevant fold shape;
- association-producing loops in existing Tungsten tests or scripts.

If these remain materially worse in the operation-count guardrails, prototype the homegrown persistent
vector described in *Stage B*. The likely outcome, though, is that Stage B is **not** needed: bulk
construction already goes through `AssociationBuilder` in `O(N)`, and tight functional mutation loops
(`Fold[Append, <||>, …]`) are both uncommon and against the grain of how associations are used —
Wolfram's own hot-mutation idiom is `AssociateTo`, an explicit non-goal here. "Stage B is unnecessary"
is a legitimate, documented result; record the measurements either way. If a homegrown vector is
built, remember it makes only the *new-key append / value-replace / random-index* cases sub-linear;
the order-rearranging cases (`Append` of an existing key, `Prepend`, `KeyDrop`) stay `O(n)`.

### Step 7. Document the final current state

After implementation, update:

- [`list-association-complexity.md`](./list-association-complexity.md), changing proposed rows to
  current-state rows;
- [`expression-function-support.md`](./expression-function-support.md), if any supported forms or
  complexity notes need clearer boundaries;
- [`architecture.md`](./architecture.md), introducing `AssociationExpr` as the first specialized
  **`Call`-subclass** node — distinct from the atomic `SparseArrayExpr`/`ByteArrayExpr`
  (`Expr`-subclass) pattern that `architecture.md:215` describes — while noting the shared idiom of a
  derived accelerator field populated in `__post_init__` and excluded from equality/hash;
- [`implementation-details.md`](./implementation-details.md), recording that Stage A retains a plain
  `dict[Expr, int]` key index (no new dependency), why the index is retained on the association value,
  and the deferred Stage B persistent-map/vector decision with its `pyrsistent` `cp313` caveat.

## Compatibility Rules

The implementation must preserve these observable behaviors:

- `Normal[assoc]` returns a list of rules in association order.
- `Keys` and `Values` preserve association order.
- Duplicate-key normalization continues to match the existing Wolfram-calibrated tests.
- `Map`, `Select`, `Cases`, `Position`, and pattern operations traverse association values, not the
  private key index.
- `KeyValuePattern` continues to reason over visible key/value entries.
- Held raw `Association[...]` syntax can still exist as a plain `Call` until evaluated.
- Rewriting an association's head away from `Association` yields a plain `Call`, not an
  `AssociationExpr` — e.g. `ReplaceAll[<|a -> 1|>, Association -> Other]` must produce
  `Other[a -> 1]`. Add this as a regression test.
- `to_dict()` and CLI JSON output do not expose private implementation details.
- arbitrary structural expressions remain usable as association keys as long as they are hashable
  under Tungsten's existing expression model.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Stage A is mistaken for full update parity | State explicitly that Stage A fixes retained-key-index lookup paths only. Keep update-heavy cases in a Stage B decision gate. |
| Structural equality changes for association keys | Implement `AssociationExpr` as a `Call`-compatible value whose equality and hash compare only visible `head_expr` / `arguments`, including equality against raw `Call[Association, ...]` when shapes match. Add tests where associations, calls, strings, symbols, and nested expressions are keys. |
| Existing code checks `isinstance(expr, Call)` before `has_head("Association")` | Subclass `Call` in Stage A; a subclass passes both checks. Verified safe on the usual subclassing hazards: there are no `type(x) is Call` exact-type checks and no `dataclasses.replace(call, ...)` calls in the evaluator. Still audit `_association_entries`, `_is_association`, and direct `.arguments`/`.head_expr` reads before considering a non-`Call` node. |
| Private index accidentally appears as a child during traversal or pattern matching | Store it outside `args()` and exclude it from `to_dict()`, `to_full_form()`, `Position`, and pattern traversal. |
| Persistent map iteration order leaks into Wolfram-visible order | Store order only in `entries`; never render, traverse, or export by iterating `key_index`. `rpds.HashTrieMap` iteration is non-deterministic *even across identical builds*, so this invariant is load-bearing for reproducibility — make the `entries`-only order test mandatory (relevant once the Stage B map backing is in use). |
| Dependency compatibility drifts across Python versions | Stage A needs no dependency. For Stage B, hide the map API behind `persistent_maps` and add an import/API smoke test for `rpds-py` (prebuilt `cp311`–`cp313` Windows wheels); `immutables` is an acceptable dev-only alternate (prebuilt `cp313` wheel on the 3.13 runtime). Do not adopt `pyrsistent.PVector` for the Stage B vector without resolving its missing `cp313` wheel / pure-Python fallback. |
| Memory increases because entries and index are both retained | This is the cost of asymptotic parity. For small associations, a threshold can keep a compact tuple-only representation if measurements justify it. |
| `RuleDelayed` entries have evaluation subtleties | Preserve the current structural handling. The representation stores rule head plus key and value; it does not invent delayed evaluation. |
| Bulk construction becomes slower due to per-key index churn | Use `AssociationBuilder` with mutable `dict` positions and build the key index once at freeze time (a plain `dict` in Stage A). |
| Duplicate-key order semantics regress | Encode separate builder methods for constructor mode, append mode, and prepend mode. Preserve the existing live-kernel-calibrated tests for `Association`, `Join`, `Append`, and `Prepend`. |
| Association-as-function lookup is missed | Include the `expression_evaluator.py` association-head path in the scalar-key rewiring step and add tests for `assoc[key]`. |
| Raw held `Association[...]` syntax becomes invalid | Keep `_association_entries` able to parse plain `Call[Association, Rule[...], ...]` values, and normalize only at evaluator construction boundaries. |
| Hash cost dominates for large structural keys | Treat `h(key)` as part of the documented complexity. Add counted-hash/equality tests to detect entry scans separately from unavoidable key hashing. |
| Informational microbenchmarks become brittle gates | Keep wall-clock scripts outside the required unit suite. Gate only on operation-count or revalidation-count tests. |

## Acceptance Criteria

The proposal is implemented when all of these are true:

1. Valid evaluated associations are represented by a `Call`-subclass `AssociationExpr` carrying
   retained ordered entries and a retained key index, constructed only via `_association_expr`.
2. `Lookup[assoc, key]`, `KeyExistsQ`, `KeyMemberQ`, and `Part[assoc, Key[key]]` do not scan all
   entries for an already-normalized association.
3. `AssociationQ`, `First`, and `Last` on a valid association are constant-time with respect to the
   number of entries.
4. Stage A documents and preserves `O(n)` ordered-entry copying for `Append`, `Prepend`, and
   key-based replacement until a persistent ordered-entry vector is deliberately added.
5. Bulk association construction and joining remain linear in total input size.
6. Existing association behavior tests continue to pass.
7. New complexity guardrails would fail against the current list-of-rules implementation.
8. The Stage A representation adds no new runtime dependency (the key index is a plain `dict`); any
   Stage B persistent-map/vector dependency is recorded in docs and locked in `uv.lock` when taken.
9. The implementation remains kernel-free and preserves public `FullForm`, `InputForm`, `Normal`,
   and CLI JSON behavior.

## Recommended First Commit Shape

The first implementation checkpoint should be intentionally substantial:

- one key-index adapter (dict-backed in Stage A, behind the `persistent_maps` protocol);
- one specialized association node (`AssociationExpr`, a `Call` subclass);
- one association builder;
- rewired scalar key operations (including the `assoc[key]` evaluator path);
- rewired constructor and `Join` paths;
- focused tests for duplicate-key semantics and scalar lookup guardrails;
- documentation updates to this proposal's related current-state docs.

That is large enough to remove the real asymptotic bug instead of merely caching one call site, while
still keeping packed numeric lists, persistent ordered-entry vectors, and any new third-party
dependency as separate follow-up decisions. Note that Stage A as scoped here touches no
`pyproject.toml` / `uv.lock` entry — the key index is a plain `dict`.
