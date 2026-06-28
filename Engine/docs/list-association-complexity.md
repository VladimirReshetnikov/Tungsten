# Wolfram List and Association Complexity Compared with Tungsten

- Status: Informational maintainer note
- Audience: Tungsten maintainers and contributors working on the kernel-free expression evaluator
- Scope: List and Association representation and asymptotic operation costs in Wolfram Language and Tungsten
- Created (UTC): 2026-06-28T22:46:59Z
- Repository HEAD: 732d7f348d53adf5badfb9e1ff30a89e572665be
- Related code:
  - [`expression.py`](../src/tungsten/expression.py)
- Related docs:
  - [`association-support-plan.md`](./association-support-plan.md)
  - [`expression-function-support.md`](./expression-function-support.md)
- External references:
  - [Wolfram Language: Some Notes on Internal Implementation](https://reference.wolfram.com/language/tutorial/SomeNotesOnInternalImplementation.html)
  - [Wolfram Language: Association](https://reference.wolfram.com/language/ref/Association.html)
  - [Wolfram Language: Associations guide](https://reference.wolfram.com/language/guide/Associations.html)
  - [Wolfram Language: `Developer`PackedArrayQ`](https://reference.wolfram.com/language/Developer/ref/PackedArrayQ.html)
  - [Wolfram Community: How to make use of Associations](https://community.wolfram.com/groups/-/m/t/1184209)
  - [Mathematica Stack Exchange: Difference between HashTable datastructure and Association datastructure](https://mathematica.stackexchange.com/questions/257531/difference-between-hashtable-datastructure-and-association-datastructure)

## Purpose

This document records the current working model for the low-level data structures behind Wolfram
Language `List` and `Association`, then compares the resulting asymptotic operation costs with
Tungsten's Python implementation.

The comparison is intentionally theoretical. It does not report timing measurements. The Wolfram
side is based on public documentation and public Wolfram Research / community implementation
statements; the Tungsten side is based on source inspection of the current Python evaluator.

## Notation and Evidence Boundaries

The tables below use:

- `n` for the number of list elements or association entries;
- `m` for the number of queried keys;
- `N` for the total number of entries or elements across all operands;
- `B` for the branching factor of a hash-array-mapped trie (HAMT);
- `h(key)` for the cost of hashing and comparing a structural key.

Asymptotic costs are output-sensitive. An operation that returns `k` elements has at least `O(k)`
work and allocation even if the lookup component is faster.

The Wolfram documentation page [Some Notes on Internal Implementation](https://reference.wolfram.com/language/tutorial/SomeNotesOnInternalImplementation.html)
describes ordinary expressions as essentially a head plus a contiguous array of pointers to
arguments. The same page notes that large homogeneous numeric arrays can use packed-array storage.
The public documentation does not give a complete low-level contract for `Association`. The strongest
public implementation statements found during this investigation are Leonid Shifrin's Wolfram
Community note that associations are implemented using a HAMT-like persistent structure and the
Mathematica Stack Exchange explanation contrasting immutable `Association` with mutable
`CreateDataStructure["HashTable"]`.

The local Wolfram 15 foreground probe was unavailable during this write-up because the kernel launch
reported a license/password failure. The tables therefore do not depend on local live-kernel
measurements.

## Representation Model

### Wolfram `List`

An ordinary Wolfram `List` is an expression with head `List` and a contiguous argument-pointer
array. This gives ordinary positional access the same theoretical shape as array indexing:

```text
List[a, b, c]
  head pointer: List
  argument pointers: a, b, c
```

For homogeneous numeric lists and arrays, Wolfram can use packed arrays. Packed arrays preserve
ordinary list semantics but store machine-sized numeric data in a compact contiguous representation.
Many numeric operations can therefore have the same big-O complexity as ordinary list traversal
while using much smaller constants, better cache locality, and lower memory overhead.

### Wolfram `Association`

Semantically, a Wolfram `Association` is an ordered key-value mapping with last-key-wins
construction rules, key lookup, and values-oriented behavior for many list-like functions. `Normal`
converts an association to a list of rules, but that is not the internal representation.

Based on the public HAMT statements, the best working model is:

```text
Association
  persistent hash trie for key -> value lookup and update
  plus enough order information to expose stable key/value order
```

A HAMT lookup or update is `O(log_B n)` in the size of the mapping, with a large branching factor.
In practice this is often close to constant depth for ordinary sizes, but it should not be described
as plain `O(1)` in a language-independent theoretical model. Hash collisions, large structural keys,
and order-preserving operations add costs outside the trie descent itself.

### Tungsten `List`

Tungsten represents a general expression call as a frozen Python dataclass:

```python
@dataclass(frozen=True)
class Call(Expr):
    head_expr: Expr
    arguments: tuple[Expr, ...]
```

The relevant source is [`Call` in `expression.py`](../src/tungsten/expression.py#L2071). A Tungsten
list is just `Call(Symbol("List"), tuple_of_arguments)`. Python tuple indexing and length are
constant time; operations that change arity allocate a new tuple.

Tungsten does not currently have a packed-array representation for ordinary numeric lists. Some
special atom types, such as sparse arrays and byte arrays, have their own paths, but ordinary
`List[...]` values remain expression calls.

### Tungsten `Association`

Tungsten keeps the same AST shape as the Wolfram full form:

```text
Association[Rule[key1, value1], Rule[key2, value2], ...]
```

The association helpers extract entries by scanning the raw arguments into `_AssociationEntry`
records, normalize duplicates, and rebuild an ordinary `Call` node. See:

- [`_AssociationEntry`](../src/tungsten/expression.py#L3061)
- [`_association_entries`](../src/tungsten/expression.py#L3108)
- [`_normalize_association_entries`](../src/tungsten/expression.py#L3125)
- [`_association_entry_map`](../src/tungsten/expression.py#L3146)

Some key-oriented operations build a temporary Python dictionary from the extracted entries, for
example [`lookup`](../src/tungsten/expression.py#L16485) and
[`key_take`](../src/tungsten/expression.py#L16511). That dictionary is not cached on the association
node. Repeated independent scalar lookups therefore rebuild the entry map each time.

## List Operation Complexity

The list comparison is straightforward because both systems use array-like storage for ordinary
expression arguments.

| Operation | Wolfram ordinary `List` | Tungsten `List` | Notes |
|---|---:|---:|---|
| `Length[list]` | `O(1)` | `O(1)` | Tungsten delegates to Python tuple length via [`length`](../src/tungsten/expression.py#L11429). |
| `list[[i]]` | `O(1)` | `O(1)` | For a simple integer selector. |
| `First[list]`, `Last[list]` | `O(1)` | `O(1)` | Tungsten indexes the tuple directly in [`first`](../src/tungsten/expression.py#L11906). |
| `Rest[list]`, `Most[list]` | `O(n)` | `O(n)` | Both must allocate the output expression. |
| `Take[list, spec]`, `Drop[list, spec]` | `O(k)` to `O(n)` | `O(k)` to `O(n)` | Output-size dependent; complex nested specs add recursive traversal. |
| `Append[list, x]`, `Prepend[list, x]` | Semantically `O(n)` | `O(n)` | Tungsten allocates a new tuple in [`append`](../src/tungsten/expression.py#L12035). Wolfram may optimize unique-reference cases, but the expression result is size `n + 1`. |
| `Join[list1, ...]` | `O(N)` | `O(N)` | Tungsten accumulates arguments then builds one tuple in [`join`](../src/tungsten/expression.py#L12062). |
| One top-level `ReplacePart` | `O(n)` | `O(n)` | Rebuilds the containing expression. |
| `Map[f, list]` | `O(n * work(f))` | `O(n * work(f))` | Tungsten loops in Python in [`map_expr`](../src/tungsten/expression.py#L16329). |
| `Select`, `Cases`, first-level scans | `O(n * predicate)` | `O(n * predicate)` | Same traversal shape; different constants. |
| `Sort[list]` | `O(n log n * cmp)` | `O(n log n * cmp)` | Tungsten uses Python sorting in [`sort_expr`](../src/tungsten/expression.py#L13934). |
| Numeric vector traversal | `O(n)` | `O(n)` | Wolfram packed arrays can have substantially better constants and memory locality. |

The main Tungsten gap for lists is not asymptotic for ordinary structural lists. It is the absence
of a packed numeric representation and of the native-code vectorized paths that packed arrays enable
in Wolfram.

## Association Operation Complexity

Associations are where the asymptotic models diverge.

| Operation | Wolfram `Association` working model | Tungsten `Association` | Notes |
|---|---:|---:|---|
| `Length[assoc]` | Likely `O(1)` | `O(1)` | Tungsten returns the raw arity; malformed associations are not validated by `Length`. |
| `AssociationQ[assoc]` | Likely `O(1)` | `O(n)` | Tungsten validates every argument as a rule through `_association_entries`. |
| `Keys[assoc]`, `Values[assoc]` | `O(n)` | `O(n)` | Output-size dominated. Tungsten uses [`keys_expr`](../src/tungsten/expression.py#L16458) and [`values_expr`](../src/tungsten/expression.py#L16463). |
| `Normal[assoc]` | `O(n)` | `O(n)` | Output-size dominated; see [`normal`](../src/tungsten/expression.py#L16468). |
| Scalar `Lookup[assoc, key]` | Expected `O(log_B n * h(key))` | `O(n * h(key))` | Tungsten scans entries and builds a temporary dict for every call. |
| `Lookup[assoc, {k1, ..., km}]` | Expected `O(m log_B n * h(key))` | `O(n * h(key) + m * h(key))` | Tungsten amortizes one temporary dict across the key list. |
| `KeyExistsQ[assoc, key]` | Expected `O(log_B n * h(key))` | `O(n * h(key))` | Tungsten validates then scans. |
| `assoc[[Key[key]]]` | Expected lookup-like cost | `O(n * h(key))` | Tungsten scans entries in [`_select_association_entry`](../src/tungsten/expression.py#L19555). |
| `assoc[[i]]` | Public implementation unclear; likely at least order-structure access | `O(n)` | Tungsten scans/validates the association before indexing into extracted entries. |
| `First[assoc]`, `Last[assoc]` | Likely `O(1)` if order endpoints are stored | `O(n)` | Tungsten extracts all entries before returning the first or last value. |
| `Rest[assoc]`, `Most[assoc]` | `O(n)` output | `O(n)` | Output-size dominated; Tungsten also normalizes the rebuilt association. |
| `KeyTake[assoc, keys]` | Expected `O(m log_B n)` plus output | `O(n + m)` | Tungsten builds a temporary dict, then emits requested entries. |
| `KeyDrop[assoc, keys]` | At least output-sensitive; commonly `O(n)` when preserving order | `O(n + m)` | Tungsten builds a key set, filters entries, and normalizes output. |
| `Append[assoc, key -> value]` | Expected persistent update plus order maintenance | `O(n)` | Tungsten filters old key occurrences and rebuilds. |
| `Join[assoc1, ...]` | Depends on implementation; at least output-sensitive | `O(N)` expected | Tungsten scans operands, extends a list, and normalizes through a Python dict. |
| Construct from `n` rules | At least `O(n)`; duplicate handling and hashing apply | `O(n * h(key))` expected | Tungsten normalizes through a Python dict. |
| `Map[f, assoc]` over values | `O(n * work(f))` | `O(n * work(f))` | Both preserve keys and transform values. |
| `KeyMap[f, assoc]` | `O(n * work(f))` plus duplicate-key normalization | `O(n * work(f))` plus normalization | Tungsten may collapse duplicate mapped keys during rebuild. |
| `KeySort`, value `Sort` | `O(n log n * cmp)` | `O(n log n * cmp)` | Tungsten sorts extracted ordering items or key indices. |

The scalar lookup rows are the important ones. Wolfram's HAMT model gives repeated independent key
queries a cost near `R * log_B n` for `R` queries. Tungsten's current scalar `Lookup` path gives
`R * n`, because the key index is rebuilt for each call. When a caller can batch the keys into one
`Lookup[assoc, keys]`, Tungsten improves to `O(n + m)`.

## Memory and Allocation Shape

For ordinary lists, both systems allocate new expression storage for structural updates. Wolfram can
benefit from internal reference-count and preallocation tricks, but a purely functional expression
result containing `n` elements still has output-size allocation.

For associations, Wolfram's persistent HAMT model implies structural sharing across updates. An
updated association can share most trie nodes with the original, so the incremental allocation for a
single key update is proportional to the trie depth plus any order-maintenance data it must update.

Tungsten currently rebuilds association values as ordinary expression calls. A single update usually
allocates:

- a tuple of extracted `_AssociationEntry` records;
- temporary Python lists or dictionaries used by the operation;
- a new `Association[...]` call and new `Rule[...]` calls for the surviving entries.

This is simple and transparent, but it means Tungsten association updates are list-like rather than
HAMT-like.

## Practical Consequences for Tungsten

The current implementation is asymptotically reasonable for one-shot structural traversals:

- `Keys`, `Values`, `Normal`, `Map`, `KeyMap`, `KeyValueMap`, `Sort`, `KeySort`;
- constructing or joining associations once;
- `Lookup[assoc, keyList]` when many keys are queried in one call.

The current implementation is asymptotically weak for repeated scalar key operations:

- repeated `Lookup[assoc, key]`;
- repeated `KeyExistsQ`;
- repeated `assoc[[Key[key]]]`;
- incremental association updates in a loop.

The immediate caller-side rule is: batch key queries when possible. Prefer one
`Lookup[assoc, {k1, ..., km}]` over `m` separate scalar `Lookup` calls.

## Possible Tungsten Improvements

Tungsten can improve association complexity without changing the public expression syntax. Useful
implementation directions include:

1. Add an `AssociationExpr` node that stores both ordered entries and a cached key index. Keep
   rendering and full-form export compatible with `Association[Rule[...], ...]`.
2. Keep the current `Call` shape but attach a lazy per-node key-index cache. This is harder with
   frozen dataclasses unless cache state is external or explicitly exempted from equality.
3. Introduce a small persistent map abstraction for associations, with an ordered-entry vector plus
   a persistent hash trie or immutable Python mapping library.
4. Add optimized paths for common scalar operations that stop after the first relevant key where
   normalization is not required. This helps constants but does not solve repeated lookup
   asymptotics.

The first option is the cleanest long-term shape if Tungsten's association-heavy workloads grow:
preserve the Wolfram syntax contract at the boundary while giving the evaluator a representation
closer to Wolfram's own association model.

## Summary

Tungsten's ordinary lists have the same asymptotic shape as ordinary Wolfram expression lists:
array-like indexing and length, linear rebuilding for structural updates, and `O(n log n)` sorting.
The missing Wolfram feature is packed-array acceleration for homogeneous numeric arrays.

Tungsten's associations are semantically association-aware but structurally list-of-rules-like.
Bulk association operations are mostly output-size optimal. Repeated scalar key lookup and update
operations are asymptotically weaker than Wolfram's HAMT-backed association model because Tungsten
does not retain a key index on the association object.
