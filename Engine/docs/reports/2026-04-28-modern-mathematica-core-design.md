# A Compatibility-Free Mathematica Core

- Status: Design report and architecture outline
- Audience: Vladimir and Tungsten maintainers thinking about language/runtime direction
- Scope: a from-scratch Wolfram-Language-like core language and evaluator, informed by `Engine`
- Created (UTC): 2026-04-28T01:43:15Z
- Repository HEAD: 2689dffeee9f9c16d9e3cbe4bfd55ef011ecdf82
- Related code:
  - `Engine/src/tungsten/expression.py`
  - `Engine/src/tungsten/expression_parser.py`
  - `Engine/src/tungsten/expression_evaluator.py`
  - `Engine/src/tungsten/expression_patterns.py`
  - `Engine/src/tungsten/expression_scoping.py`
  - `Engine/src/tungsten/notebook.py`
- Related Tungsten docs:
  - [../architecture.md](../architecture.md)
  - [../expression-parser.md](../expression-parser.md)
  - [../expression-function-support.md](../expression-function-support.md)
  - [../symbol-context-registry.md](../symbol-context-registry.md)
  - [../sequence-nothing-evaluation.md](../sequence-nothing-evaluation.md)
  - [../numeric-tower.md](../numeric-tower.md)
  - [2026-04-27-tungsten-gap-and-shape-review.md](2026-04-27-tungsten-gap-and-shape-review.md)
  - [2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md](2026-04-27-tungsten-notebook-frontend-alternatives__47d1f0f5e114.md)

## Executive Summary

If I were designing Mathematica's core language and evaluator today, with no compatibility
obligations, I would not throw away the central idea. The load-bearing insight is still magnificent:
programs, data, formulas, patterns, graphics, notebooks, and metadata can share one symbolic
expression substrate, and computation can be understood as controlled transformation of those
expressions. That idea is still fresher than many newer language designs.

I would, however, make the implicit parts explicit. The current Mathematica model has accumulated a
lot of semantic power in places that are hard to see: attributes, contexts, value lists, upvalues,
sequence splicing, messages, box interpretation, notebook state, package loading, `$ContextPath`,
and FrontEnd behavior. If freed from compatibility, I would preserve the symbolic programming soul
but redesign the runtime as a set of typed, inspectable contracts:

- expression identity and source syntax would be separate layers;
- evaluation policy would be a first-class per-head contract instead of a loose attribute bundle;
- definitions would live in versioned rule tables compiled to pattern dispatch programs;
- lexical modules would replace context-path-based name lookup for ordinary code;
- dynamic state would be explicit, scoped, snapshot-able, and capability-controlled;
- options would be normalized by schemas instead of parsed ad hoc by every function;
- diagnostics would be structured `Failure`-like events, with messages as display views;
- notebooks and boxes would remain symbolic but would have their own document/display IRs rather
  than relying on accidental equivalence with kernel expressions everywhere;
- the evaluator would expose a traceable, persistent session protocol rather than being only a
  black-box REPL loop.

So the answer is: not completely different, but much more disciplined. It would feel recognizably
Mathematica to a symbolic programmer, while looking internally more like a small theorem prover,
a term-rewriting VM, a database query engine, and an IDE runtime agreed on the same object model.

## What Tungsten Teaches

Tungsten is currently an automation workspace around a real Wolfram installation, plus a growing
kernel-free structural interpreter. It is not trying to be a full kernel, and that boundary is
healthy. Still, its expression subsystem is an excellent microscope for the design pressure in a
Mathematica-like runtime.

The good pressure:

- `expression.py` keeps the basic expression model compact: atoms plus general calls.
- `expression_parser.py` shows that Wolfram syntax can lower into ordinary heads without needing
  bespoke internal nodes for every surface construct.
- The symbol registry gives names, attributes, and values a concrete process-local home.
- The evaluator's use of dynamic scopes and internal signals for `Throw`, `Abort`, `Confirm`,
  cleanup, time constraints, and loop control is the right shape for non-local evaluator behavior.
- The split between notebook parsing and expression parsing is correct; they are related languages,
  not the same parser problem.
- The docs are admirably explicit about supported forms and known divergences.

The hard pressure:

- A single-step dispatch table with hundreds of `if raw_head_name == ...` branches is a sign that
  evaluator policy and builtin implementation need a data-driven registry.
- The coexistence of legacy own-value slots and canonical definition lists is exactly the kind of
  compatibility seam I would avoid in a clean design.
- `Sequence`, `Nothing`, `Evaluate`, `Unevaluated`, hold attributes, list threading, and orderless
  normalization all interact in ways that are powerful but too implicit.
- The fixed `$Context` / `$ContextPath` model is useful for compatibility but not the namespace
  system I would choose today.
- Options and defaults are visibly cross-cutting; every new builtin either grows local option code
  or ignores options.
- Notebook boxes, display forms, expression parsing, and FrontEnd state remain separate concerns
  even when the historical system often lets them blur.

In other words, Tungsten is already moving toward the design I would choose: explicit structural
layers, honest kernel-free subsets, structured outputs, and docs that identify exact semantic
contracts. A clean language/runtime should make those contracts foundational rather than
retrofit them around historical behavior.

## Design Principles

### 1. Keep the homoiconic expression core

Everything important should still have a symbolic representation. A function call, a theorem, a
graphics scene, a notebook cell, a package export list, and a query plan should all be expressible
as trees or DAGs whose heads and children can be inspected and transformed.

But "everything is an expression" should not mean "all expressions are operationally alike." The
runtime should distinguish at least these layers:

| Layer | Purpose |
|---|---|
| Source syntax | Text with trivia, comments, source spans, parse diagnostics. |
| Core expressions | Immutable symbolic DAG used by the evaluator and pattern matcher. |
| Values | Core expressions plus optimized atoms such as packed arrays, byte arrays, associations, units, quantities, compiled functions, images, and foreign handles. |
| Patterns | Compiled match programs with capture scopes, width bounds, and attribute-aware strategies. |
| Boxes | Display/edit trees for mathematical notation and notebook rendering. |
| Documents | Notebook-level cells, groups, styles, attachments, metadata, and evaluation products. |

All layers should be reversible where feasible, but not collapsed into one confused node type.

### 2. Make evaluation policy declarative

The classic attribute set is a brilliant compression, but it mixes several independent ideas:

- which arguments are evaluated;
- whether `Sequence` splices;
- whether `Unevaluated` strips;
- whether nested same-head calls flatten;
- whether list arguments thread;
- whether arguments reorder;
- whether pattern matching treats unary heads as identities;
- whether users may mutate definitions or attributes.

In a clean design, every head would have an `EvaluationContract`:

```text
EvaluationContract
  argumentPolicy: strict | holdAll | holdFirst | custom(argument -> demand)
  splicePolicy: none | constructorSplice | callSplice | custom
  normalization: flatten | orderless | listable | associativeKeyed | none
  definitionSlots: own | down | up | sub | numeric | none
  optionSchema: OptionSchema?
  purity: pure | readsSession | writesSession | externalEffect
  evaluator: builtin handler or compiled rule table
  tracePolicy: transparent | opaque | summary
```

Surface attributes can remain as syntax or metadata, but the evaluator would consume this contract,
not a loose bag of flags.

### 3. Prefer lexical modules over context search

Context paths are convenient in the REPL and painful in large systems. A fresh design should make
module imports explicit and lexical:

```text
module Demo exports f, g
import LinearAlgebra.{Dot, MatrixQ}
import Statistics as Stats
```

Symbols should have stable identity independent of their display name. Name lookup should produce a
symbol identity plus an import provenance, and shadowing should be a diagnostic unless deliberately
requested. REPL sessions can still have a convenience import list, but package code should not
depend on ambient `$ContextPath`.

This does not reject symbolic names. It gives them stronger identity.

### 4. Keep dynamic scope, but fence it

`Block`-style dynamic scope is genuinely useful in a symbolic system. It is the right model for
temporary evaluator settings, message filters, random seeds, precision policy, trace collection,
and `$Assumptions`-like state.

The redesign should keep dynamic scope as an explicit `DynamicScope` stack with typed keys:

```text
DynamicScope {
  settings: Map<SettingKey, Value>
  capabilities: CapabilitySet
  collectors: MessageCollector | TraceCollector | ReapCollector
  cancellation: CancellationToken
}
```

Ordinary lexical variables should not be smuggled through dynamic values. Dynamic state should be
snapshot-able, inspectable, and thread/task local by construction.

### 5. Treat diagnostics as data

Messages should be a rendering of diagnostics, not the diagnostic model itself. The primary runtime
event should be structured:

```text
Diagnostic {
  id: "Part::partd"
  severity: warning | error | info
  subject: Expr
  inserts: Expr[]
  sourceRange: SourceRange?
  provenance: EvaluationFrame[]
  recoverable: bool
}
```

`Check`, `Quiet`, `Enclose`, `Confirm`, and notebook message cells can all be implemented as views
or filters over this stream. This would make batch tooling, notebooks, tests, and IDE integrations
much saner.

### 6. Make performance an implementation tier, not a semantic fork

The symbolic evaluator should be the semantic reference. Under it, the runtime can select faster
tiers:

- hash-consed immutable expression DAGs for structural sharing;
- compiled pattern dispatch tables for definitions;
- indexed upvalue/downvalue lookup;
- packed arrays and sparse arrays as specialized atoms;
- JIT or AOT compiled pure numeric/list kernels;
- incremental notebook evaluation with dependency tracking;
- parallel map/reduce where the evaluation contract says the function is pure enough.

The user should not need separate languages for "symbolic" and "fast." They should see one
language with visible compilation boundaries and explicit fallback.

## Proposed Core Architecture

```text
source text / boxes / notebook cells / API calls
                 |
                 v
        parsers and source mappers
                 |
                 v
        immutable core expression DAG
                 |
        +--------+---------+
        |                  |
        v                  v
 compiled patterns   evaluator contracts
        |                  |
        +--------+---------+
                 v
         evaluation engine
                 |
        +--------+---------+-------------+
        |                  |             |
        v                  v             v
   value store       diagnostic stream   trace stream
        |
        v
 renderers: InputForm, StandardForm boxes, TeX, notebook cells, JSON
```

The engine's unit of work is not "evaluate a string." It is:

```text
Evaluate(expr, EvaluationContext) -> EvaluationResult
```

where `EvaluationResult` contains:

- the result expression/value;
- diagnostics;
- printed/output events;
- trace summary or full trace if requested;
- mutations committed to the session definition store;
- dependencies observed;
- resource usage and cancellation state.

## Core Expression Model

### Immutable DAG, not mutable tree

Core expressions should be immutable and structurally shareable. Every compound expression is:

```text
Apply(head: ExprId, args: ArgVector)
```

Atoms include:

- symbol identities;
- exact integers;
- rationals;
- arbitrary precision reals with explicit precision model;
- complex numbers;
- strings;
- byte arrays;
- packed numeric arrays;
- associations;
- sparse arrays;
- dates/times/quantities if the language chooses to make them primitive values;
- foreign handles with capability restrictions.

The evaluator can still present everything in `FullForm`, but the runtime is allowed to store high
traffic values in optimized representations as long as their expression view is deterministic.

### Expressions carry optional metadata out-of-band

Source ranges, comments, notebook cell IDs, formatting, and provenance should not be ordinary
arguments unless the program explicitly asks for them. Metadata belongs in side tables keyed by
expression IDs or document nodes. This keeps symbolic equality from accidentally depending on
source layout.

### Associations become first-class structural values

Associations should not merely be calls with rule arguments internally. They deserve a first-class
value representation with an expression view:

```text
Assoc[(key1, value1), (key2, value2), ...]
```

That gives lookup, update, duplicate-key normalization, key ordering, structural hashing, and
pattern matching a clean home while still rendering as `<|key -> value|>`.

## Evaluation Semantics

### Standard evaluation sequence

A clean evaluator would use this loop:

1. If the expression is an atom, resolve atom behavior: symbol own values, constants, or atom
   identity.
2. Evaluate the head according to the enclosing policy.
3. Load the head's `EvaluationContract`.
4. Demand or hold arguments according to the contract.
5. Apply constructor-level splice/omit rules.
6. Normalize shape according to the contract: flatten, order, thread, association normalization.
7. Apply user definitions through compiled rule tables.
8. Apply builtin handlers.
9. Repeat until the expression reaches a fixed point or a resource limit.

This is close in spirit to the historical evaluator, but every step is explicit and traceable.

### Definitions and rule tables

Definitions should be stored as versioned rule tables:

```text
DefinitionTable
  ownRules: RuleProgram[]
  downRules: RuleProgram[]
  upRules: RuleProgram[]
  subRules: RuleProgram[]
  numericRules: RuleProgram[]
  defaults: DefaultTable
  options: OptionSchema
```

Every rule has:

- a held pattern;
- a body expression or builtin function;
- a capture environment;
- an evaluation policy for the right-hand side;
- source/module provenance;
- priority and specificity metadata;
- invalidation dependencies for incremental compilation.

`Set`, `SetDelayed`, and package loading become transactions against this store. A notebook cell can
evaluate against a session snapshot, and re-evaluation can invalidate only the affected compiled
dispatch entries.

### Upvalues stay, but become extension methods

Upvalues are one of Mathematica's deepest ideas: they let data types participate in operations
owned by other heads. I would keep them, but make the registration more disciplined:

- the target symbol's module owns the upvalue;
- upvalues declare which foreign heads they extend;
- conflicting extensions produce diagnostics;
- packages can export extension sets separately from ordinary values;
- tracing shows when an upvalue wins.

This keeps the extensibility while reducing spooky action at a distance.

### Sequence and Nothing become constructor effects

I would not keep arbitrary `Sequence` / `Nothing` as ordinary magical symbols with evaluator-wide
effects. The capability is valuable, but the clean core should represent it as constructor effects:

```text
Splice[List[a, b]]
Omit
```

These would be meaningful only in declared construction contexts: list construction, call argument
construction, association construction, and selected transformation APIs. They can still have
friendly surface syntax, but the core evaluator should not have to ask every arbitrary head whether
an ordinary symbol named `Sequence` might explode its argument list.

Compatibility-free Mathematica can afford this simplification. Tungsten cannot, because it is
mirroring Wolfram behavior.

### Evaluation forcing is a demand operation

Instead of `Evaluate` being another special case threaded through holding constructs, the evaluator
should expose a demand primitive:

```text
Force[expr, mode]
```

Modes might include:

- ordinary value;
- normal form under current context;
- held normal form;
- numeric value at precision;
- box/rendered form.

Surface `Evaluate` can remain as the common spelling, but internally it should be a typed demand
request honored only where the contract permits it.

## Patterns and Rules

The pattern language is the other pillar I would preserve almost unchanged at the user level. It is
one of Mathematica's most successful pieces of language design.

Internally, though, patterns should compile.

### Pattern IR

Patterns should lower into a separate pattern IR:

```text
PatternProgram
  widthBounds
  literalTests
  headTests
  captures
  guards
  sequenceAutomaton
  associativeMatcher?
  orderlessMatcher?
  costModel
```

This lets the engine:

- precompute width bounds for sequence patterns;
- index definitions by head and first discriminating literals;
- isolate pattern variable scopes from ordinary lexical scopes;
- choose specialized matchers for flat/orderless heads;
- give diagnostics for ambiguous or expensive rules;
- make `ReplaceList` and trace output meaningful.

### Matching is not evaluation

Pattern matching should not accidentally evaluate pattern fragments. Guards and predicates evaluate
only at declared points, with their own diagnostic and trace events. This is already the direction
Tungsten takes, and it is the direction I would bake into the language.

### OptionsPattern and defaults become real services

`OptionsPattern[]`, `OptionValue`, and `Default` should not be bolted onto the matcher. They need
first-class stores:

```text
OptionSchema[f]
DefaultTable[f]
```

The pattern compiler can then lower optional arguments and option patterns against the schema,
rather than rediscovering option rules by hand in every builtin.

## Functions, Scoping, and Binding

### Pure functions are lexical closures

Pure functions should be ordinary closures over a lexical environment:

```text
Function(params, body, contract?, closureEnv)
```

Positional slots are convenient shorthand, but the core representation should unify positional and
named parameters. The capture-avoiding renaming rules documented in Tungsten's named pure function
spec are the right semantic instinct; I would expose them as lexical binding rules rather than as
post-hoc substitution tricks.

### Three explicit local forms

The language should keep three local mechanisms, but name and define them cleanly:

| Concept | Mathematica ancestor | Clean role |
|---|---|---|
| Lexical constants | `With` | Substitute once into a lexical body. |
| Lexical locals | `Module` | Allocate fresh symbols/slots for a body. |
| Dynamic values | `Block` | Temporarily override dynamic/session values. |

I would make all three explicit in the core IR, with binding lists that the parser and evaluator can
recognize structurally. This avoids every feature needing to rediscover which subexpressions bind
names.

### Assignment is a transaction

Assignment should commit to an environment:

```text
Set[target, value]        -> transaction with evaluated value
SetDelayed[target, body]  -> transaction with held body and closure
Unset[target]             -> transaction deleting matching definitions
```

Compound LHS assignment such as `a[[2]] = x` should not be a special evaluator hack. It should lower
to a lens/update operation:

```text
Update[a, PartLens[2], x]
```

That lens model naturally covers parts, association keys, dataset paths, sparse-array entries, and
future document updates.

## Numeric and Data Model

### Exactness and precision are value-level invariants

The numeric tower should be explicit about:

- exact integers and rationals;
- algebraic numbers;
- arbitrary-precision real intervals or ball arithmetic;
- machine reals as an explicitly lossy tier;
- complex values over each real tier;
- infinities and indeterminates with a coherent internal representation.

I would strongly consider ball arithmetic or interval-backed arbitrary precision as the default
internal model for approximate reals. The historical precision/accuracy model is powerful, but a
clean runtime should make uncertainty propagation mechanically inspectable.

### Arrays are not lists with dreams

Lists should remain symbolic expressions. Dense numeric arrays, sparse arrays, tensors, images, and
tables should be optimized value atoms with expression views. This avoids the trap where every
linear algebra operation must first prove that a nested list is rectangular and packed.

The language can still let users write `{{1, 2}, {3, 4}}`, but the evaluator should be able to
promote it to a typed packed matrix when a numeric kernel demands one.

### Dataframes and datasets need schema objects

`Dataset`-like functionality should be built on associations plus explicit schemas:

```text
TableValue[rows, Schema[...]]
```

Queries then compile to plans, not arbitrary recursive rewrites over nested associations. The
expression view remains available for symbolic manipulation, but common analytics get a real query
engine.

## Effects, I/O, and Security

Mathematica historically grew in an environment where local code execution was the norm. A modern
core should assume notebooks and packages can be untrusted.

The evaluator context should carry capabilities:

```text
Capabilities
  fileRead(paths)
  fileWrite(paths)
  network(domains)
  processLaunch
  frontEndMutation
  persistentStorage
```

I/O functions check capabilities. Notebook open does not evaluate code. Package imports can request
capabilities and declare initialization effects. Sandboxed evaluation becomes a runtime mode, not a
separate product.

This also improves agent workflows: a tool can say "evaluate this expression with no file writes
and no network" and get a guarantee from the engine.

## Notebook and FrontEnd Model

I would keep notebooks symbolic, but not pretend the kernel expression model and document model are
identical.

### Document IR

Notebook files should parse into:

```text
NotebookDocument
  cells: CellTree
  styles: StyleSheetRef | EmbeddedStyleSheet
  attachments
  evaluationState
  metadata
```

Cells contain source expressions, boxes, plain text, output bundles, diagnostics, and provenance.
Every cell has stable identity independent of position.

### Boxes as display/edit trees

Boxes should be a proper display IR:

```text
BoxTree
  RowBox
  FractionBox
  ScriptBox
  GridBox
  TemplateBox
  GraphicsBox
  InterpretationBox
```

`MakeBoxes` and `MakeExpression` are then compiler passes between core expressions and box trees,
with source maps. TeX, MathML, SVG, and accessibility output are renderers from boxes or expressions,
not canonical storage formats.

This matches the direction of Tungsten's notebook frontend report: direct StandardForm box rendering
should be the durable path, with TeX/MathJax as a useful display accelerator rather than the semantic
model.

### Evaluation products are structured bundles

Notebook output should not be "the printed cell." It should be:

```text
EvaluationBundle
  resultExpr
  boxes
  textForms
  diagnostics
  prints
  graphics
  traceSummary
  dependencies
```

The notebook UI chooses views over this bundle. Batch tools and agents consume the same bundle as
JSON or another structured protocol.

## Runtime and Tooling

### Persistent sessions

A modern engine should expose a persistent JSON or binary protocol:

```text
session.open
session.evaluate
session.cancel
session.snapshot
session.restore
definitions.list
definitions.patch
expr.parse
expr.render
notebook.open
notebook.patch
notebook.evaluateCell
trace.subscribe
```

This is not just for IDEs. It is the clean boundary for notebooks, CLI tools, agents, tests, remote
kernels, and language servers.

### Tracing as a stream

`Trace` should be implemented by the evaluator, not by reifying another evaluation after the fact.
Every evaluation step can optionally emit:

- frame enter/leave;
- argument demand;
- rule considered;
- rule matched;
- builtin called;
- diagnostic emitted;
- dynamic scope entered/exited;
- mutation committed;
- packed-kernel selected.

The full stream can be large, so users request trace policies. But the architecture should make it
possible.

### Deterministic replay

Given a session snapshot, expression, capabilities, random seed, and resource limits, pure portions
of evaluation should be replayable. Non-deterministic functions should be marked and traced. This
would be a major improvement for notebooks, tests, and agent debugging.

## Surface Language Sketch

I would keep most familiar notation:

```text
f[x_, y_Integer] := x + y
expr /. rule
{a, b, c}[[2]]
<|"name" -> "Ada"|>["name"]
Map[# + 1 &, data]
```

But I would introduce clearer module and option declarations:

```text
module Demo exports fib, sample

options sample = <|
  "Count" -> 10,
  "Seed" -> Automatic
|>

fib[0] = 0
fib[1] = 1
fib[n_Integer?Positive] := fib[n - 1] + fib[n - 2]

sample[data_List, OptionsPattern[]] :=
  DynamicScope[RandomSeed -> OptionValue["Seed"],
    RandomChoice[data, OptionValue["Count"]]
  ]
```

And I would make evaluation contracts declarable for advanced users:

```text
contract HoldMap = EvaluationContract[
  ArgumentPolicy -> HoldRest,
  Purity -> Pure,
  TracePolicy -> Transparent
]

define HoldMap[f_, expr_] with HoldMap := ...
```

This is not meant as final syntax. The design point is that the contract is named, inspectable, and
part of the function definition rather than hidden in global mutable attributes.

## What I Would Keep From Mathematica

- Symbolic expressions as the universal substrate.
- FullForm/InputForm distinction and ordinary head-based representation.
- Pattern matching as the primary user-level dispatch and transformation language.
- Rules, delayed rules, replacement, and structural traversal.
- Exact arithmetic and arbitrary precision as first-class defaults.
- The idea of attributes/evaluation policy, though not the exact representation.
- Upvalues or an equivalent extension-method mechanism.
- Lexical and dynamic scoping forms.
- Rich notebooks as executable symbolic documents.
- The ability for users to build new languages inside the language.

These are the soul of the system.

## What I Would Change Hard

- Replace context-path package loading with lexical modules and explicit imports.
- Replace mutable attributes-as-flags with `EvaluationContract`.
- Replace ad hoc options with schemas, normalized option records, and `OptionValue` as a service.
- Replace text messages as the primary error model with structured diagnostics.
- Replace string/box/notebook ambiguity with separate source, expression, box, and document IRs.
- Replace magical arbitrary `Sequence` / `Nothing` behavior with constructor-scoped splice/omit.
- Replace global session mutation with transactional definition stores and dynamic scopes.
- Replace black-box evaluation with traceable, persistent, cancellable sessions.
- Replace nested-list numeric kernels with typed packed array/tensor values plus expression views.
- Replace source-less definitions with definitions carrying provenance, source maps, and invalidation
  dependencies.

These are not aesthetic changes. They directly improve tooling, security, testability,
performance, and explainability.

## What I Would Avoid

- I would not bolt on a conventional Hindley-Milner or nominal static type system as the center of
  the language. Symbolic programming wants open terms, partial knowledge, and transformation over
  unevaluated structure.
- I would not make everything lazy. Strict-by-default evaluation with explicit hold/demand contracts
  is still the right fit.
- I would not make notebooks the only program representation. Notebooks are wonderful documents;
  packages and modules still need source-first ergonomics.
- I would not hide optimized data structures behind lossy display forms. Packed arrays, sparse
  arrays, datasets, images, and graphs need real runtime identities.
- I would not make the FrontEnd the semantic oracle. Display/edit behavior and kernel evaluation
  should meet through boxes and bundles, not through ambient UI state.

## Implications for Tungsten

Tungsten should not try to become this whole clean-room runtime. Its current hybrid mission is more
practical: automate the real installation, parse/edit notebooks, and provide useful kernel-free
structural evaluation.

But this thought experiment suggests a few Tungsten-friendly directions:

1. **Keep splitting semantic families out of `expression.py`.** The current facade is useful, but
   evaluator policy wants a registry shape over time.
2. **Introduce an internal builtin registry.** Even before a full `EvaluationContract`, a table of
   head names, hold policy, option policy, and handler function would make new functions less
   dispatch-table-shaped.
3. **Treat options as a shared subsystem.** The gap review already shows options are the
   cross-cutting blocker.
4. **Keep definitions canonical.** Retire legacy own-value storage when feasible and make all value
   lists use one rule representation.
5. **Invest in a persistent session protocol before a serious notebook GUI.** Fresh-process
   expression evaluation is fine for CLI automation, but a notebook wants real session state.
6. **Keep notebook and expression parsers separate.** That boundary is not a compromise; it is the
   right architecture.
7. **Make diagnostics more structured.** Tungsten messages already have records; growing that into
   richer result metadata would pay off in CLI, .NET, and notebook paths.
8. **Preserve exact support matrices.** The docs are one of Tungsten's strongest assets. A
   Mathematica-like runtime needs semantic honesty more than broad claims.

## Open Design Questions

- Should a clean language keep `Set` / `SetDelayed` syntax, or rename definition forms to make
  rule-table mutation more explicit?
- How far should upvalues be restricted before they stop feeling like Mathematica?
- Should arbitrary-precision approximate numbers use ball arithmetic internally, or retain a
  precision/accuracy model closer to Wolfram's visible semantics?
- Should associations preserve insertion order as a semantic guarantee, or expose separate ordered
  and unordered map types?
- How much of notebook styling should be symbolic and evaluatable versus treated as document
  metadata?
- Should package imports be pure declarations, or can imports execute initialization code under
  declared capabilities?
- What is the right user-facing syntax for evaluation contracts without making everyday function
  definitions feel bureaucratic?

These are language-design choices, not implementation chores. They deserve experiments.

## Conclusion

A fresh Mathematica should still be a symbolic expression language with pattern-directed
evaluation. That is the part I would defend with teeth. The thing I would change is not the heart
but the skeleton: explicit evaluation contracts, lexical modules, structured diagnostics,
compiled pattern dispatch, transactional state, separate document/display layers, and a persistent
traceable runtime protocol.

Mathematica's historical design feels like a language that discovered a deep unifying principle and
then had to grow an empire around it in real time. A clean redesign would keep the principle and
make the empire legible.

## References

- Wolfram Research, [Expressions](https://reference.wolfram.com/language/guide/Expressions.html).
- Wolfram Research, [Evaluation](https://reference.wolfram.com/language/tutorial/Evaluation.html).
- Wolfram Research, [Attributes](https://reference.wolfram.com/language/guide/Attributes.html).
- Wolfram Research, [Rules & Patterns](https://reference.wolfram.com/language/guide/RulesAndPatterns).
- Wolfram Research, [Patterns](https://reference.wolfram.com/language/tutorial/Patterns.html).
- Wolfram Research, [Associations](https://reference.wolfram.com/language/guide/Associations.html).
- Wolfram Research, [Modularity and the Naming of Things](https://reference.wolfram.com/language/tutorial/ModularityAndTheNamingOfThings.html).
- Wolfram Research, [Enclose](https://reference.wolfram.com/language/ref/Enclose.html).
