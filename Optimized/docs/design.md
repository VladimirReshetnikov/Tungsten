# OptimizedExpressions Design

- Created (UTC): 2026-06-26T19:47:55Z
- Repository HEAD: fbc379002652d67648e299fe6e6de86c27653dfb

This document describes the API and implementation of `src/Optimized/OptimizedExpressions.wl`.
The package implements DAG-preserving computation over Wolfram's
`Experimental`OptimizedExpression` representation: addition, multiplication, division, and
exact-symbol substitution can be performed on already-optimized operands without first calling
`Normal` and rebuilding the whole expression tree.

## Problem Shape

`Experimental`OptimizeExpression` rewrites repeated subexpressions into a `Block` of temporary
assignments:

```wolfram
Experimental`OptimizeExpression[(x + y)^2 + (x + y)^3, "OptimizationSymbol" -> t]

(* Experimental`OptimizedExpression[
     Block[{t3},
       t3 = x + y;
       t3^2 + t3^3
     ]] *)
```

This is compact because it is really a directed acyclic graph, not a tree. The problem from the
StackExchange question is that normal Wolfram arithmetic sees only the wrapper. A brute-force route

```wolfram
Experimental`OptimizeExpression[Normal[o1] + Normal[o2]]
```

works only while the expanded tree is small enough to materialize. For the target workload
(rational functions in roughly 30 variables, stored as many-level nested sums of fractions), the
expanded tree may be orders of magnitude larger than the optimized DAG.

The package therefore imports optimized operands as DAGs, performs operations on DAG roots, and
emits one new optimized expression.

## Public API Shape

The public surface separates four responsibilities.

### Optimization

```wolfram
OptimizeExpressionDAG[expr, opts]
```

Builds a canonical DAG from an ordinary or already-optimized expression and emits an
`Experimental`OptimizedExpression`. It is an improved, controllable optimizer rather than a wrapper
around `Experimental`OptimizeExpression`.

Important options:

- `"AtomicLeafCount"` controls decomposition depth: small composite expressions are opaque leaves.
- `"ExcludedPatterns"` and `"ExcludedHeads"` protect caller-selected regions.
- `"MinCommonLeafCount"` suppresses extraction of tiny repeated nodes.
- `"MaxInlineLeafCount"` forces extraction of large one-off nodes.
- `"OptimizationSymbol"` chooses the generated temporary base.

### Operations

```wolfram
OptimizedPlus[e1, e2, ...]
OptimizedTimes[e1, e2, ...]
OptimizedDivide[num, den]
OptimizedApply[headOrFunction, {e1, e2, ...}]
```

These import each operand as a DAG, merge all nodes through one hash-consing builder, create the
new root expression, and emit one optimized result. `OptimizedPlus` and `OptimizedTimes` apply
elementwise to equal-length list roots, because the original use case often represents a list of
expressions as one optimized object.

`OptimizedApply[Function[...], operands]` uses placeholders instead of `Normal`. It evaluates the
pure function on fresh placeholder symbols, then builds that template with an environment mapping
each placeholder to the corresponding operand root. This supports custom combinations without
destroying operand sharing.

### Substitution

```wolfram
OptimizedSubstitute[expr, x -> replacement]
OptimizedSubstitute[expr, {x -> replacementX, y -> replacementY}]
```

The implemented substitution is exact symbol substitution. The left sides must be symbols. The
right sides may be ordinary or optimized expressions. During a DAG walk, an atom equal to a
left-hand symbol is replaced by the already-imported replacement root.

General pattern replacement is intentionally not included in this package version. Pattern matching
over a DAG has choices that are absent from tree rewriting:

- Should a pattern match a temporary root, a use site, or the fully inlined expression?
- If one shared node matches, should all uses change, or only one use?
- How should sequence patterns and conditions see hidden sharing?

Those choices deserve a separate DAG-pattern matcher. Exact symbol substitution is the operation
needed for substituting one optimized expression for a variable in another, and it has unambiguous
sharing semantics.

### Inspection

```wolfram
OptimizedExpressionNormal[expr]
OptimizedExpressionData[expr]
```

`OptimizedExpressionNormal` expands a DAG back to an ordinary expression and is meant for tests and
small diagnostics. `OptimizedExpressionData` returns node counts, temporary counts, roots,
occurrence counts, leaf counts, nodes, and the emitted optimized expression.

## Internal DAG Model

The internal DAG is an association:

```wolfram
<|
  "Nodes" -> <|
    id -> <|"Kind" -> "Atom", "Expression" -> expr, "LeafCount" -> n,
            "Extractable" -> True|>,
    id -> <|"Kind" -> "Call", "Head" -> h, "Children" -> {id1, id2, ...},
            "LeafCount" -> n, "Extractable" -> True|>
  |>,
  "Outputs" -> {rootId}
|>
```

Atoms are ordinary Wolfram atoms or opaque composite leaves. Calls hold a head plus child node IDs.
Nodes are hash-consed by semantic structure:

- atom key: `HoldComplete["Atom", expr]`;
- call key: `HoldComplete["Call", head, children]`.

Because node IDs are assigned after hash-consing, input temporary names are irrelevant. Two imported
operands that both define `x + y`, even with different names, map to the same node in the merged
builder.

## Importing Existing Optimized Expressions

The importer recognizes the system shape:

```wolfram
Experimental`OptimizedExpression[Block[{t1, t2, ...}, body]]
```

It scans the held `Block` body for assignments to declared temporary symbols. Each right-hand side
is built with an environment mapping previously imported temporaries to their node IDs. The final
body expression is then built with that environment. This imports the graph without calling
`Normal`.

The importer assumes the system optimizer emits temporaries in dependency order, which matches the
observed `Experimental`OptimizeExpression` output. Forward references are not currently supported.

## Temporary Selection and Emission

After an operation produces a merged DAG, the renderer computes occurrence counts. A node is emitted
as a temporary when it is extractable and either:

- it occurs more than once and `LeafCount >= "MinCommonLeafCount"`; or
- it has `LeafCount > "MaxInlineLeafCount"`.

Non-extractable opaque leaves from `"ExcludedPatterns"` or `"ExcludedHeads"` are never assigned to
temporaries. Small opaque leaves from `"AtomicLeafCount"` may be assigned if repeated; that option
controls decomposition, not extraction.

Temporary definitions are emitted in dependency order:

```wolfram
Experimental`OptimizedExpression[
  Block[{opt$1, opt$2, ...},
    opt$1 = ...;
    opt$2 = f[opt$1, ...];
    rootExpression
  ]
]
```

The default temporary base is `"opt"`, producing private-context symbols. Passing
`"OptimizationSymbol" -> t` produces symbols in `Context[t]`, analogous to the system optimizer.

## Equality and Canonicalization

The DAG is structural. It deduplicates expressions that the Wolfram evaluator already puts into the
same structural form, but it does not perform algebraic canonicalization beyond normal evaluation.
For example, it does not prove that two different rational-function trees are mathematically equal.
That is a deliberate boundary: the target problem is common-subexpression preservation across
optimized representations, not symbolic simplification.

The practical consequence is:

- exact repeated subexpressions are shared;
- `Plus` and `Times` benefit from Wolfram's ordinary argument ordering/flattening;
- algebraically equivalent but structurally different terms are not merged.

## Failure Modes and Limitations

- The package imports the common `Block` representation produced by
  `Experimental`OptimizeExpression`. Exotic hand-written optimized expressions with forward
  temporary references or non-`Set` side effects are outside the contract.
- General pattern substitution is not implemented; only exact symbol rules are supported.
- The package does not expand rational functions, factor polynomials, or normalize fractions.
- Memory use is proportional to the number of distinct DAG nodes in the optimized operands and the
  newly constructed operation roots. It avoids the expanded tree, but it does not use an out-of-core
  graph store.
- Very large roots can still be emitted as one temporary if `"MaxInlineLeafCount"` is low. This is
  useful for staging but may be cosmetically different from `Experimental`OptimizeExpression`.

## Verification Strategy

The smoke suite checks value preservation by expanding only small examples with
`OptimizedExpressionNormal`. For production-size expressions, the package's main correctness
invariant is local and structural:

1. Each imported temporary definition is converted once into a node.
2. Every use of a temporary is replaced by the corresponding node ID.
3. Merged operands use one builder, so semantically identical nodes share one ID.
4. Rendering emits dependency-ordered assignments.
5. Re-importing the emitted expression yields the same normal expression on small tests and the
   expected temporary counts.

This is intentionally close to compiler common-subexpression elimination and SSA lowering: the
optimized expression is a compact program, and the package rewrites that program rather than
evaluating it into a large tree.
