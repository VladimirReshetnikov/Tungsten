# Tungsten List and Association Complexity Parity Proposal

- Status: Proposal
- Audience: Tungsten maintainers working on the kernel-free expression evaluator
- Scope: `List` and `Association` representation, asymptotic parity, dependency choice, validation, and rollout
- Created (UTC): 2026-06-28T23:00:26Z
- Updated (UTC): 2026-06-28T23:31:40Z
- Repository HEAD: eae2b72892eab0002b62a9cbf87371f0a30268bf
- Related code:
  - [`expression.py`](../src/tungsten/expression.py)
  - [`expression_evaluator.py`](../src/tungsten/expression_evaluator.py)
  - [`expression_patterns.py`](../src/tungsten/expression_patterns.py)
  - [`pyproject.toml`](../pyproject.toml)
  - [`uv.lock`](../uv.lock)
- Related docs:
  - [`list-association-complexity.md`](./list-association-complexity.md)
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

## Target Outcome

Tungsten should keep the external expression contract:

```text
Association[Rule[key1, value1], Rule[key2, value2], ...]
```

Internally, evaluated associations should be specialized values with:

- ordered entries for Wolfram's stable key/value order;
- a persistent key index for lookup, membership, and key-path operations;
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

The important consequence is not just a slower constant. Scalar lookup-like operations are
structurally linear because the key index is not retained on the association value.

## Second-Pass Corrections

The second review changed several parts of the first draft.

- Stage A should be described as **lookup parity**, not full update parity. With ordered entries
  stored in a Python tuple, `Append`, `Prepend`, and key-based `ReplacePart` still allocate a new
  entry tuple. They can reuse a persistent key index path, but their returned ordered storage is
  still `O(n)` until Stage B adds a persistent random-access entry vector.
- The first implementation should **subclass `Call`** or otherwise preserve the `Call` fields
  exactly. The current evaluator is heavily `Call`-centric; a standalone `AssociationExpr(Expr)`
  would require a broad audit before it could be safe.
- `rpds-py` remains the best Stage A dependency, but `immutables` should be treated as an optional
  spike/reference implementation rather than a production fallback. On the active CPython 3.14
  probe it built from source, while `rpds-py` installed directly and advertises Python 3.11 through
  3.15 classifiers.
- `rpds.List` is not a Stage B ordered-entry candidate: its API is linked-list-shaped, with
  `first`, `rest`, `push_front`, and `drop_first`, not random access.
- Duplicate-key behavior is not one generic rule. Constructor-like operations (`Association`,
  `Join`, `KeyMap`) preserve the first key slot while updating to the last value; `Append` and
  `Prepend` deliberately move a replaced key to the end or start, respectively.

## Library Recommendation

Tungsten should prefer a free, existing persistent-map implementation instead of implementing a HAMT
from scratch. The dependency should sit behind a tiny adapter so we keep one Tungsten-owned key-index
contract even if the backing library changes.

The dependency check performed for this proposal used isolated `uv run --isolated --with ...`
probes on the active CPython 3.14.4 interpreter, plus package metadata from the installed
distributions, on 2026-06-28:

| Package | Current PyPI version seen | Fit | Recommendation |
|---|---:|---|---|
| `rpds-py` | `2026.5.1` | Rust-backed persistent `HashTrieMap`, MIT, Python `>=3.11`, classifiers include Python 3.11 through 3.15. The isolated probe confirmed `get`, `insert`, `remove`, `update`, `keys`, `values`, and `items`. | Best Stage A dependency for Tungsten's retained key index. The adapter must not rely on `HashTrieMap` iteration order. |
| `immutables` | `0.21` | Direct HAMT-backed immutable `Map`, Apache 2.0, explicit `O(log N)` get/set documentation. The isolated active-Python probe worked, but it built from source and package classifiers only name Python 3.8 through 3.12. | Keep as a semantic reference or dev-only adapter. Do not make it a required dependency unless wheel/source-build reliability is validated for Tungsten's active Python range. |
| `pyrsistent` | `0.20.0` | MIT, includes `PVector` and `PMap`; docs state amortized `O(1)` append and `log32(n)` random access/update for vectors. The isolated active-Python probe imported and exercised `PVector`, but package classifiers only name Python 3.8 through 3.12. | Useful for a Stage B ordered-entry vector spike. Do not make required for Stage A. Benchmark and packaging-check before adoption. |
| `sortedcontainers` | `2.4.0` | Apache 2.0, production-stable sorted collections. | Do not use for `Association`; sorted-key order is the wrong semantic model. It may be useful elsewhere, but not for this parity fix. |
| `numpy` | already locked transitively through `sparse` | Contiguous numeric arrays. | Useful for a later packed numeric list optimization, not for general symbolic `Association`. |

Recommended dependency shape:

1. Add a private adapter module, for example `tungsten.persistent_maps`, with a minimal protocol:
   `empty()`, `from_items()`, `get()`, `contains()`, `insert()`, `remove()`, and `update_many()`.
2. Back it with `rpds.HashTrieMap` first.
3. Optionally keep a dev-only alternate implementation over `immutables.Map` during the initial
   spike, because `immutables` documents the exact HAMT performance model Tungsten wants. Do not
   lock it as production dependency unless the packaging concern above is resolved.
4. Keep the old temporary Python `dict` logic only as a builder/transient implementation, not as the
   retained association representation.

This gives Tungsten a maintained free-library path without entangling association semantics with one
package's public API.

## Proposed Representation

Introduce a specialized association node. For the first implementation, it should remain a
`Call`-compatible object:

```python
@dataclass(frozen=True, eq=False)
class AssociationExpr(Call):
    entries: tuple[_AssociationEntry, ...] = field(compare=False, hash=False, repr=False)
    key_index: PersistentMap[Expr, int] = field(compare=False, hash=False, repr=False)

    def __eq__(self, other): ...
    def __hash__(self): ...
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

- Keep the inherited `head_expr` and `arguments` fields as the visible Wolfram expression shape.
- Keep `entries` and `key_index` as private accelerators excluded from equality and hashing.
- Implement equality against `Call`-compatible values by comparing only `head_expr` and `arguments`.
  The dataclass-generated equality method is not sufficient because it is class-sensitive.
- Implement hashing as the same visible-shape hash used for an ordinary `Call` with head
  `Association` and the same rule arguments.
- Store `key_index` as `key -> entry_index`.
- Store `arguments` eagerly in Stage A, because too much code currently reads `.arguments` directly
  after an `isinstance(expr, Call)` check.
- Make `_association_expr(...)` the only public constructor for valid association values.
- Make `_association_entries(expr)` return `expr.entries` in `O(1)` for `AssociationExpr`.
- Keep the existing raw `Call(Symbol("Association"), ...)` path valid for held or malformed syntax
  that has not yet gone through evaluator normalization.

The key index stores indexes rather than entries so value replacement can update a single ordered
slot while leaving the key map unchanged.

## Builder Contract

Bulk association producers should not create a persistent map one key at a time if they already have
all entries in hand. Add a mutable internal builder:

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

This preserves `O(N)` construction for `N` total input entries and builds the persistent key index
once at freeze time.

## Operation Parity Targets

The table below uses `B` for the persistent hash-trie branching factor and `h(key)` for structural
hash/compare cost.

| Operation | Current Tungsten | Proposed Tungsten | Notes |
|---|---:|---:|---|
| `AssociationQ[assoc]` | `O(n)` | `O(1)` | `AssociationExpr` is already validated. |
| `Length[assoc]` | `O(1)` | `O(1)` | Entry count is stored. |
| `First[assoc]`, `Last[assoc]` | `O(n)` | `O(1)` | Read ordered endpoint directly. |
| `Keys`, `Values`, `Normal` | `O(n)` | `O(n)` | Output-size dominated. |
| `Lookup[assoc, key]` | `O(n * h(key))` | `O(log_B n * h(key))` | Persistent key index lookup. |
| `Lookup[assoc, keys]` | `O(n + m)` | `O(m log_B n + m)` | Proposed shape wins when `m << n`; both are output-sensitive. |
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

## Persistent Ordered Entries Decision

The ordered-entry structure has two viable stages.

### Stage A: tuple entries plus persistent key index

This is the recommended first implementation:

- lowest disruption;
- keeps numeric positional access `O(1)`;
- fixes repeated scalar key operations;
- keeps formatter and traversal behavior simple;
- avoids introducing an additional vector dependency before there is measured need.

It does not make single-slot update results structurally shared; replacing one entry still creates a
new tuple of entries.

### Stage B: persistent vector for ordered entries

If update-heavy association workloads are important, add a persistent ordered-entry vector behind
the same `AssociationExpr` API. Candidate source:

- `pyrsistent.PVector`, if compatibility with Tungsten's active Python versions is verified.

The `rpds-py` package is not currently a candidate for this slot despite being the recommended map
dependency: its exposed `List` API is linked-list-shaped rather than random-access-vector-shaped.

If no maintained free library fits the active Python range and measured workload, a small internal
32-way persistent vector is the only justifiable homegrown piece. It should be introduced only after
Stage A, with focused tests showing which operations still miss the parity target.

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

### Step 1. Add dependency adapter and probe tests

Add `tungsten.persistent_maps` with the required map protocol and a first implementation over
`rpds.HashTrieMap`.

Probe requirements:

- accepts Tungsten `Expr` objects as keys;
- preserves structural equality behavior for existing atom and `Call` keys;
- supports lookup, insert, remove, and bulk construction without converting the whole map to a
  mutable dictionary for every operation;
- has wheels for the active Windows Python versions Tungsten actually uses.
- does not expose or depend on persistent-map iteration order for Wolfram-visible association order.

Keep a local alternate adapter over `immutables.Map` only as a spike if the first candidate behaves
poorly. Treat it as dev-only unless packaging is validated.

Expected files touched: one new adapter module, `pyproject.toml`, `uv.lock`, and one focused test
module.

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

Expected tests: scalar lookup, missing lookup, string key lookup, key path lookup, function-position
lookup, and repeated lookup guardrails.

### Step 4. Route bulk association operations through builders

Update every association producer to freeze through `AssociationBuilder`:

- `Association`;
- `Append`, `Prepend`, `Join`;
- `KeyTake`, `KeyDrop`, `KeyMap`, `KeySelect`;
- `AssociationThread`, `AssociationMap`;
- `Merge`, `GroupBy`, `GatherBy`, `Gather`;
- `KeyComplement`, `KeyUnion`, `KeyIntersection`;
- `Counts`, `CountsBy`, `PositionIndex`;
- JSON import paths and failure-detail constructors.

This step should remove duplicate ad hoc normalization logic and keep constructor-style operations
linear in total input size.

### Step 5. Add complexity guardrails

Unit tests should include instrumentation that catches accidental full scans in scalar paths. Good
guardrails:

- monkeypatch or wrap `_association_entries` in a test-only counter and assert repeated
  `Lookup[assoc, key]` does not re-validate every rule once the value is an `AssociationExpr`;
- use a custom `Expr` key type with counted `__hash__` and `__eq__` calls to detect `R * n`
  comparison growth on `R` repeated independent lookups;
- monkeypatch `_rule_entry` in scalar-path tests, because the old implementation revalidates every
  visible rule during lookup;
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

If these remain materially worse in the operation-count guardrails, prototype persistent ordered
entries. The first prototype should try `pyrsistent.PVector`; if Python-version compatibility is
bad, keep the tuple representation and record why Stage B is deferred.

### Step 7. Document the final current state

After implementation, update:

- [`list-association-complexity.md`](./list-association-complexity.md), changing proposed rows to
  current-state rows;
- [`expression-function-support.md`](./expression-function-support.md), if any supported forms or
  complexity notes need clearer boundaries;
- [`architecture.md`](./architecture.md), adding `AssociationExpr` beside `SparseArrayExpr` as a
  specialized expression node;
- [`implementation-details.md`](./implementation-details.md), recording the dependency decision and
  why a persistent index is retained on the association value.

## Compatibility Rules

The implementation must preserve these observable behaviors:

- `Normal[assoc]` returns a list of rules in association order.
- `Keys` and `Values` preserve association order.
- Duplicate-key normalization continues to match the existing Wolfram-calibrated tests.
- `Map`, `Select`, `Cases`, `Position`, and pattern operations traverse association values, not the
  private key index.
- `KeyValuePattern` continues to reason over visible key/value entries.
- Held raw `Association[...]` syntax can still exist as a plain `Call` until evaluated.
- `to_dict()` and CLI JSON output do not expose private implementation details.
- arbitrary structural expressions remain usable as association keys as long as they are hashable
  under Tungsten's existing expression model.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Stage A is mistaken for full update parity | State explicitly that Stage A fixes retained-key-index lookup paths only. Keep update-heavy cases in a Stage B decision gate. |
| Structural equality changes for association keys | Implement `AssociationExpr` as a `Call`-compatible value whose equality and hash compare only visible `head_expr` / `arguments`, including equality against raw `Call[Association, ...]` when shapes match. Add tests where associations, calls, strings, symbols, and nested expressions are keys. |
| Existing code checks `isinstance(expr, Call)` before `has_head("Association")` | Subclass `Call` in Stage A. Separately audit `_association_entries`, `_is_association`, direct `.arguments`, and direct `.head_expr` call sites before considering a non-`Call` node. |
| Private index accidentally appears as a child during traversal or pattern matching | Store it outside `args()` and exclude it from `to_dict()`, `to_full_form()`, `Position`, and pattern traversal. |
| Persistent map iteration order leaks into Wolfram-visible order | Store order only in `entries`; never render, traverse, or export by iterating `key_index`. Add a test with keys whose map iteration order differs from insertion order if the library exposes that behavior. |
| Dependency compatibility drifts across Python versions | Hide dependency API behind `persistent_maps`; add an import/API smoke test for `rpds-py`; keep `immutables` dev-only unless its build and wheel story is acceptable. |
| Memory increases because entries and index are both retained | This is the cost of asymptotic parity. For small associations, a threshold can keep a compact tuple-only representation if measurements justify it. |
| `RuleDelayed` entries have evaluation subtleties | Preserve the current structural handling. The representation stores rule head plus key and value; it does not invent delayed evaluation. |
| Bulk construction becomes slower due persistent map churn | Use `AssociationBuilder` with mutable `dict` positions and freeze the persistent map once. |
| Duplicate-key order semantics regress | Encode separate builder methods for constructor mode, append mode, and prepend mode. Preserve the existing live-kernel-calibrated tests for `Association`, `Join`, `Append`, and `Prepend`. |
| Association-as-function lookup is missed | Include the `expression_evaluator.py` association-head path in the scalar-key rewiring step and add tests for `assoc[key]`. |
| Raw held `Association[...]` syntax becomes invalid | Keep `_association_entries` able to parse plain `Call[Association, Rule[...], ...]` values, and normalize only at evaluator construction boundaries. |
| Hash cost dominates for large structural keys | Treat `h(key)` as part of the documented complexity. Add counted-hash/equality tests to detect entry scans separately from unavoidable key hashing. |
| Informational microbenchmarks become brittle gates | Keep wall-clock scripts outside the required unit suite. Gate only on operation-count or revalidation-count tests. |

## Acceptance Criteria

The proposal is implemented when all of these are true:

1. Valid evaluated associations are represented by a `Call`-compatible `AssociationExpr` or an
   equivalent specialized node with retained ordered entries and retained key index.
2. `Lookup[assoc, key]`, `KeyExistsQ`, `KeyMemberQ`, and `Part[assoc, Key[key]]` do not scan all
   entries for an already-normalized association.
3. `AssociationQ`, `First`, and `Last` on a valid association are constant-time with respect to the
   number of entries.
4. Stage A documents and preserves `O(n)` ordered-entry copying for `Append`, `Prepend`, and
   key-based replacement until a persistent ordered-entry vector is deliberately added.
5. Bulk association construction and joining remain linear in total input size.
6. Existing association behavior tests continue to pass.
7. New complexity guardrails would fail against the current list-of-rules implementation.
8. The dependency decision is recorded in docs and locked in `uv.lock`.
9. The implementation remains kernel-free and preserves public `FullForm`, `InputForm`, `Normal`,
   and CLI JSON behavior.

## Recommended First Commit Shape

The first implementation checkpoint should be intentionally substantial:

- one persistent-map adapter;
- one specialized association node;
- one association builder;
- rewired scalar key operations;
- rewired constructor and `Join` paths;
- focused tests for duplicate-key semantics and scalar lookup guardrails;
- `pyproject.toml` / `uv.lock` dependency update;
- documentation updates to this proposal's related current-state docs.

That is large enough to remove the real asymptotic bug instead of merely caching one call site, while
still keeping packed numeric lists and persistent ordered-entry vectors as separate follow-up
decisions.
