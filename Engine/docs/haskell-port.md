# Tungsten Engine Haskell port

- Status: Active incremental port and compatibility boundary
- Audience: Tungsten users, maintainers, integration authors, and contributors
- Scope: `Engine/haskell`, `Engine/tungsten-engine.cabal`, and `Engine/cabal.project`
- Created (UTC): 2026-07-18T14:01:03Z
- Updated (UTC): 2026-07-28T16:00:00Z
- Repository HEAD: 793c0b68abec8e08fc8b44929217678f82b8c6f0

## Purpose

The Haskell implementation is an active typed port of Tungsten Engine. It is being introduced in
coherent, independently testable slices while the Python implementation remains the compatibility
reference for the wider automation surface. The independently buildable C++17 port and all three
runtime trees currently coexist under the same `Engine` ownership boundary.

The port favors immutable values, exact arithmetic, explicit errors, and JSON process boundaries.
Unknown evaluator forms remain symbolic instead of silently receiving guessed semantics.

## Build and run

From `Engine`:

```bash
cabal build all
cabal test all --ghc-options=-Werror
cabal run tungsten-hs -- expr parse --code '1 + 2 x^3'
cabal run tungsten-hs -- expr evaluate --code 'Total[Range[10]]'
cabal run tungsten-hs -- notebook inspect --file example.nb
cabal run tungsten-hs -- notebook patch --file example.nb --spec patch.json --out patched.nb
cabal run tungsten-hs -- repl
cabal run tungsten-hs -- env show
cabal run tungsten-hs -- kernel eval --code '2+2'
cabal run tungsten-hs -- env show --probe
cabal run tungsten-hs -- frontend probe
cabal run tungsten-hs -- inline-box compose --prefix 'icon: ' --box-expr 'GraphicsBox[{CircleBox[]}]'
cabal run tungsten-hs -- inline-box from-cell --file example.nb --cell-index 0 --all-objects
cabal run tungsten-hs -- docs search NotebookGet
cabal run tungsten-hs -- parser-corpus discover --corpus-root ./corpus --sample 20
cabal run tungsten-hs -- parser-corpus compare --corpus-root ./corpus --skip-wolfram --no-write --include-results
cabal run tungsten-hs -- assistant ask --prompt 'Explain FullForm[1 + x]'
cabal run tungsten-hs -- assistant ask-cell --file example.nb --cell-index 0 --question 'Explain this cell'
cabal run tungsten-hs -- assistant prepare-inline --file example.nb --cell-index 0
cabal run tungsten-hs -- assistant capture-inline --file example.nb --cell-index 0 --insert-wolfram-code-below
```

Parse a file or select FullForm explicitly:

```bash
cabal run tungsten-hs -- expr parse --file example.wl --form input
cabal run tungsten-hs -- expr evaluate --code 'Plus[1, Times[2, 3]]' --form fullform
```

Run the newline-delimited JSON process protocol:

```bash
printf '%s\n' \
  '{"id":1,"command":"parse","source":"1 + 2 x"}' \
  '{"id":2,"command":"evaluate","source":"Total[Range[5]]"}' \
  | cabal run tungsten-hs -- protocol
```

The no-argument executable mode also starts the protocol server for compatibility with the first
Haskell process clients.

## Evaluation runtime boundary

`Tungsten.Evaluate.evaluate` remains a pure, kernel-free reducer. Runtime-dependent forms stay
symbolic at that API boundary. Stateful callers use `Tungsten.Session.evaluateInSession`, whose
result is in `IO`; the CLI, protocol server, and REPL all use this session entry point.

`evaluateInSessionWithRuntime` accepts a `SessionRuntime` containing monotonic-clock and sleep
handlers. Production code uses `defaultSessionRuntime`, while tests can inject deterministic
handlers. The immutable evaluator constructs explicit clock-read and sleep requests and only the
session entry point interprets them, so timing does not rely on `unsafePerformIO` or hidden mutable
process state.

## Implemented surface

| Area | Current Haskell support |
|---|---|
| Expression values | Symbols, arbitrary integers, rationals, source-preserving reals, complex values, strings, byte arrays, general calls, algebraic roots, and sparse arrays |
| Rendering | Canonical structural FullForm plus precedence-aware Python-compatible InputForm for collections, arithmetic, patterns, functions, parts, spans, rules, assignments, mapping/application/composition, updates, messages, roots, sparse arrays, byte arrays, and Wolfram strings/symbols |
| Wolfram strings | Character, control, numeric and line-continuation escapes; raw and PUA-decoded inline boxes; nested delimiter scanning through strings/comments; composition and display projection |
| Named characters | Build-time embedding of all 1,100 Wolfram 15.0 kernel-accepted names, canonical symbol rendering, strict identifier escapes, single-character aliases, and core escaped operator spellings |
| System symbol catalog | Build-time parsing and validation of the pinned 7,935-name Wolfram 15.0 snapshot plus six Python-only compatibility names, exposed as 7,941 sorted names with typed, bitmask-backed attribute lookup for bare and explicitly system-qualified spellings; the session registry treats every catalog entry as known and its attributes can be inspected or overridden at runtime |
| FullForm parser | Calls and chained heads, exact and real atoms, shared Wolfram string decoding, nested comments, rationals, and complex atoms |
| InputForm parser | Core calls and chained heads, lists, associations, parts, `Span`/`;;` specifications, blanks/named patterns/chained PatternTest, valid dotted and explicit-default optional patterns, named colon patterns, `..`/`...` repetition postfixes with precision-literal boundary handling, adjacent numeric multiplication, slots, postfix and named `|->` pure functions including immediately applied postfix functions, whitespace-independent subtraction, arithmetic, comparisons, Boolean operators, rules, replacements, conditions, ordinary and right-associative tagged assignments including contiguous or spaced tagged unset, application, compound expressions, comment-only input, and escaped physical-line continuations |
| Evaluator | Exact arithmetic with coefficient-aware symbolic term/factor collection, integer powers, exact rational-power radical extraction, explicit-number `Sqrt`, scalar and explicit-complex exact/source-real `Floor`/`Ceiling`/half-even `Round`/`IntegerPart`/`FractionalPart` with signed exact multiples, recursive-list `Min`/`Max` folding over explicit reals and symbolic residues, canonical ordering/sort-by/set operations, bare/qualified `System` reducer dispatch with structural spelling restoration, comparisons, held `If`/`Which`/`Switch`/`Piecewise` control flow, structural and quantified collection predicates, predicate select/discard/first/while/pick operations over heads and associations, structural MatchQ blanks/typed and named bindings/PatternTest/alternatives/exceptions/conditions/backtracking sequence blanks, explicit optional defaults, bounded Repeated/RepeatedNull, named and orderless PatternSequence, Longest/Shortest allocation priorities, structural OptionsPattern capture, order-independent KeyValuePattern entry matching, catalog- and session-attribute-aware `Flat` grouping, `OneIdentity` unwrapping, Python-ordered `Orderless` permutation search with effect-preserving backtracking, variable-width Optional/Alternatives sequence matching, and fixed-width IgnoringInactive structural views with original-value bindings plus level-aware traversal and binding/sequence-aware Cases/Replace/ReplaceAll/ReplaceRepeated/Position/FirstPosition transformations, postorder `Level` extraction over positive, negative, ranged, and infinite specifications with optional `False` heads flag and non-re-evaluated held results, Python-compatible zero-argument/root/sparse-array depth, canonical PositionLargest/PositionSmallest and grouped PositionIndex, exact-path pattern-aware ReplaceAt, recursive numeric/key/`All`/`Span` parts with head-preserving selector lists and per-selection remaining specifications, extraction, ranges, strict multi-axis take/drop, append/prepend/join, rotation, bounded/named-head flattening, nested delete/insert/replace/map-at operations across list and association paths, mapping/application, association normalization/access/key transforms/value-aware structural operations/ordered grouping and key-set alignment, rank-N dense `Array`/`ConstantArray` construction with scalar and per-axis origins, canonical `SparseArray` construction from rules/vectorized rules/dense arrays/`Automatic`/existing sparse values, sparse properties/`Normal`/`ArrayRules`, coordinate-native sparse `Part`/`Extract`, compact arbitrary-precision reshape/padding/transposition/flatten/block flattening, elementwise sparse arithmetic, direct sparse vector/matrix `Dot`, `ArrayQ`/`VectorQ`/`MatrixQ`, dense reshape/padding/block flattening/arbitrary-rank transposition, vector and matrix constructors, dense and compact-sparse `LeviCivitaTensor`, checked output materialization, tuples/partition/take-list/take-drop, fixed-pattern sequence search and rolling `SequenceFold`/`SequenceFoldList`, exact symbolic `Dot`/`Cross`/`Det`/`Inverse`/`MatrixPower`, rank-aware dense and sparse `Tr` with callback combiners, matrix totals, ordered tally/counts, catenation, differences, accumulation, riffle, containment, subsets/permutations, padding and exact mean/median, string character/list conversion, slicing, insertion, joining, case conversion, reversal, repetition, padding, splitting, riffle, trimming and counting plus stateful `StringCases`/`StringReplace` and pattern-driven positions/contains/match/free/starts/ends over literals, string expressions, alternatives, blanks, captures, tests, conditions, repeated forms, character classes, boundaries, regular expressions, number strings, and date patterns, compact byte-array construction/predicates/length/normalization plus Unicode, PrintableASCII, ASCII, Latin-1/15, Windows-1252, and UTF-8/16/32 character-code and byte-string conversions with invalid-byte preservation, positional and capture-aware named pure functions including recursive `SlotSequence`, exact replacement, held forms including `HoldComplete`, one-layer `ReleaseHold`, held `Inactive`, recursive selective `Activate`, bottom-up `Sequence`/`Splice`/`Nothing` argument normalization, and symbolic fallback |
| Sessions | Uniform catalog-backed symbol records with immediate/delayed own values, ordered conditional downvalues, upvalues, and one-level curried subvalues, plus a reserved n-value slot, held value inspection and session-aware `ValueQ` structural probing with live effects and non-local control propagation, whole-expression symbol registration, fixed `$Context`/`$ContextPath` values, validated `Symbol` construction, `SymbolName`/`Context` inspection, wildcard `Names`/`NameQ`/`Contexts` registry queries, shared-counter and collision-aware `Unique` allocation, direct and qualified `Evaluate` transparency, callable `Nothing` with preserved argument effects, structural `SameAs`, directional `Composition`/`RightComposition` including empty identities and constructor-only `Unevaluated` transparency, association callability with one-step immediate or delayed value projection, visible `System`/`Global` identity resolution, active-own-value cycle guards, intrinsic `I`/`MachinePrecision`, seeded system settings, mutable `Attributes`/`SetAttributes`/`ClearAttributes`, protection/locking, wildcard `Clear`/`ClearAll`, and attribute-driven hold, sequence, listable, flat, orderless, and pure-function evaluation; compound `Set`/`SetDelayed`/`Unset`, `TagSet`/`TagSetDelayed`/`TagUnset` natural-value and immediate-argument/head-chain routing, evaluated curried-head owner retargeting, shared down/up/subvalue matching and return boundaries, left-to-right identity-deduplicated UpValue candidates before DownValues or SubValues with `HoldAllComplete` suppression, user-head alias retargeting, exact-before-generic dispatch with explicit-System structural preservation, recursive and memoizing rule bodies, session-native stateful pure functions, assignment and arithmetic updates, raw-symbol `Increment`/`Decrement`/`PreIncrement`/`PreDecrement` with old/new return timing and recovered-diagnostic assignment, strict held `AppendTo` rebuilding for general calls and associations through ordinary own/down/subvalue `Set`, sequential state, state-preserving internal evaluation exits, pattern-tagged non-local `Catch`/`Throw` with handlers, `Break`/`Continue` propagation with `Do`/`For`/`While` boundaries, evaluated bare and headed `Return` propagation with Python-compatible definition-RHS boundaries and exact `Module`/`Block`/`InheritedBlock`/`Do`/`For`/`While` target catches, held `For` and one- or two-argument `While` with phase-specific `Continue`, whole-loop `Break`, state preservation, and the Python iteration safety boundary, held `With` simultaneous substitution with independent eager or duplicated delayed values, deterministic capture avoidance through named functions and nested `With`/`Module`/`Block` scopes, held `Module` lexical scoping with monotone shared-suffix fresh symbols, independent eager/delayed initializers, capture-avoiding body renaming, persistent fresh definitions and closure rule tables, and exit-safe initializer state, held `Block` plus both `InheritedBlock` spellings with validated left-to-right immediate/delayed initializers, dynamic own/down/up/sub-value inheritance, and scoped restoration across normal or non-local exits while retaining unrelated effects, session-aware held `Which`/`Switch`/`Piecewise` control, one-layer `ReleaseHold`, held `Inactive`, stateful recursive selective `Activate`, held pattern and rewrite dispatch for `MatchQ`, `Cases`, `DeleteCases`, `FirstCase`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `ReplaceAt`, `Position`, `FirstPosition`, `Count`, `FreeQ`, and `MemberQ`, state-preserving `Condition`/`PatternTest` callbacks across failed alternatives and traversal, once-only eager rule preparation versus per-match delayed rules, exact held-context replacement rebuilding, semantic association value-only traversal with qualified-head preservation, effectful down/up/subvalue matching without duplicated callbacks, dynamically scoped held `Table`/`Do`/`Sum`/`Product` iteration over counts/exact ranges/value lists/nested dependent specifications with complete value-slot iterator snapshots and nested-list, side-effect-only, or flat arithmetic-fold results as appropriate, ordered generated/visible nonfatal diagnostics with raw-syntax recovery, held-name `Message` insertion evaluation with `InputForm`/`FullForm`/`StandardForm` rendering, persistent exact and `General::tag` `Off`/`On` filtering, dynamically nested `Quiet` generated-versus-visible filtering with inner `on` precedence, depth-aware `Check` collection and lazy fallback, exit-safe scope restoration, duplicate-preserving current `$MessageList` snapshots, left-to-right `Clear` diagnostics, and preserved argument effects, qualified structural constructors at consumer boundaries, targeted session re-entry for totals, level-aware generated `Map`/`Apply`, expanded exact `MapAt` selectors (`All`, `Span`, numeric/key selector lists, duplicates, and nested paths), and `AssociationMap`/`KeyMap`/`KeyValueMap` calls, session-threaded `Select`/`Discard`/`SelectFirst`/`TakeWhile`/`LengthWhile`/`KeySelect` predicates and `SortBy`/`ReverseSortBy` key extraction, ordering callbacks, trailing `SameTest` options, eager/delayed option timing, exact CPython 3.13 stable-sort callback scheduling, raw-head `Print` capture, and fresh-session stateless command evaluation |
| JSON | Deterministic codec, tagged expression round trips, arbitrary integer lexemes, compact sparse-array trees with canonical entries plus explicit-length and Python backend metadata, protocol requests/responses with FullForm and InputForm expression projections, session-backed parse/evaluate source commands, ordered message and print payloads, and structured fatal errors |
| CLI | Expression, notebook, environment, kernel, FrontEnd, REPL, protocol, and inline-box command families with Python-compatible FullForm/InputForm JSON projections, fresh evaluation sessions, nonfatal evaluation payloads, and explicit exit behavior; the InputForm/FullForm expression commands reproduce the Python success and error field sets, error types, source inclusion, diagnostics, standard-error output, and exit codes, including first-axis `SparseArray` result length and sparse tree metadata |
| REPL | Persistent definitions, `In`/`InString`/`Out`, `%` output shorthand, `$Line`, per-input message/print resets, diagnostics on standard error, captured prints on standard output, Wolfram-style prompts, and `Exit`/`Quit` codes |
| Discovery | Explicit `TUNGSTEN_WOLFRAM_HOME`, product-family selection, installed-version ranking, PATH fallback, executable/docs/license candidates, cache paths, and `env show` JSON |
| Kernel runner | Temporary source/wrapper/result isolation, stable temporary mathpass deduplication, held parsing, `EvaluationData` metadata, evaluated `Print` capture, optional `UsingFrontEnd`, cross-process launch gating, stale batch cleanup, cached license-seat waiting, process snapshots, process output, JSON decoding, and `kernel eval` exit behavior |
| Wolfram processes | Windows process discovery/classification, helper-process exclusion, portable cached license limits, stale Tungsten batch cleanup, bounded license-seat polling, cross-process launch gating, and structured snapshots |
| FrontEnd | Hidden probing, wrapped/unwrapped code, notebook open, direct documentation locate, token execution, safely escaped code builders, and the `frontend` CLI family |
| Notebooks | Structural `Notebook`/`Cell`/`CellGroupData` parsing, nested group traversal, cell metadata and previews, deterministic creation/rendering, typed immutable patches, and `notebook inspect`/`notebook create`/`notebook patch` CLI commands |
| Inline boxes | Typed composition records, `BoxData` and box-bearing string extraction, stable deduplication, flat-index/path/UUID/ID/tag selectors, object selection, and `inline-box compose`/`inline-box from-cell` JSON commands |
| Documentation | Kernel-free notebook text/title extraction, Python-compatible SQLite/FTS5 schema, filename and full-text search, page reads, paclet resolution, and the `docs` CLI family |
| Parser corpora | Deterministic recursive discovery, extension/include/exclude filtering, byte-budget skips, bounded local workers, held Wolfram kernel batches, outcome classification, summary/JSONL/Markdown reports, failure-policy exits, and the `parser-corpus` CLI family |
| Notebook Assistant | Free-form and selected-cell hidden Chatbook requests, model/tool settings, stable notebook selectors, structured kernel failures, assistant text extraction, fenced-code classification, optional generated-input insertion/save, inline input creation/focus, completion/progress capture, inline output/code extraction, and the full `assistant` CLI family |

Session control also includes raw `Label` markers and evaluated-target `Goto` signals. The nearest
`CompoundExpression` with a structurally matching immediate label resumes after that marker; an
unmatched signal crosses definition, iterator, and dynamic-scope boundaries with state restoration
and becomes an inert `Goto[...]` only at the top-level evaluator boundary.

Session-native safety and resource control includes `Abort`, `CheckAbort`, `AbortProtect`,
`WithCleanup`, `Reap`, and `Sow`. Abort ownership follows the active protection depth, cleanup runs
once across every supported non-local control exit with cleanup-signal precedence, and ordered
sow buckets route to the nearest matching reap scope before optional combiners run outside that
scope. These controls are available through the session, CLI, protocol, and REPL evaluators; the
exported pure `Tungsten.Evaluate.evaluate` API remains the deterministic expression reducer.

Session timing includes `Pause`, `AbsoluteTiming`, `TimeConstrained`, and `TimeRemaining`, with
bare and explicit `System`` dispatch. Nested constraints use the earliest active monotonic
deadline; the scope owner supplies its fallback only after its own scope is removed. Deadlines are
restored across normal completion, diagnostics, throws, confirmations, aborts, loop control,
returns, gotos, and cleanup. `Pause` sleeps cooperatively in bounded increments, and
`WithCleanup` suppresses expired deadlines while its abort-protected initializer and cleanup run,
matching the Python reference's cleanup guarantee.

Session mapping includes bottom-up `MapIndexed` traversal with positive and negative level
specifications, integer and association `Key[...]` paths, callback-created child rebuilding,
state and control propagation, generated-list normalization, and the Python-compatible distinction
between direct and operator forms of explicit `System`` and `Global`` spellings. `MapThread`
supports depth-zero application and recursive parallel-list threading, row-major callback order,
incremental validation with retained prior effects, bare generated-list normalization, and exact
shape diagnostics. `BlockMap` adds complete-window scheduling with default, overlapping, and
gapped offsets over arbitrary compound expressions and associations, preserving block heads,
association rule kinds, callback effects and control, and generated outer-list normalization.
`SubsetMap` validates flat integer positions before its single callback, supports negative and
duplicate selections with later-replacement precedence, preserves exact List head spelling, and
retains callback effects and diagnostics through successful or recovered transformations. `Scan`
adds postorder level traversal with optional ordinary-call head visits, association value-only
semantics, ignored callback results, recoverable continuation, and exact direct/operator context
boundaries.

Ordered keyed selection now includes `OrderingBy`, `MinimalBy`, and `MaximalBy`, with Python-stable
callback scheduling, scalar-versus-list tie behavior, custom ordering and `SameTest`, count forms,
association-preserving extrema, post-decoration validation, and exact direct/operator context
boundaries. `FlattenAt` applies deduplicated nested and batched selectors deepest/rightmost first,
including sparse densification, association raw-rule behavior, qualified selector constructors,
effect retention, and normalized rebuilt arguments.

Persistent sessions now own raw `In`, `InString`, `Out`, and historical `MessageList[n]` dispatch.
Line specifications evaluate exactly once with effects and non-local control intact; message lookup
projects the retained visible stream, while current `$MessageList` remains the generated stream.
`$HistoryLength` pruning keeps input, output, source, print, and visible-message histories aligned.

Failure control now includes `FailureQ`, `MissingQ`, callable `Failure[...]` property projection,
and the one-, two-, and three-argument `Failsafe` operator forms. Session evaluation also provides
dynamic `Enclose` scopes plus `Confirm`, `ConfirmBy`, `ConfirmMatch`, and `ConfirmAssert`.
Confirmations preserve
lazy information and tag evaluation, session-aware tag and match predicates, string or callable
handlers, `Confirm::confirmnotag` message filtering, and cleanup before a matching outer handler.
The scope stack is restored across aborts, throws, returns, loop control, gotos, reaping, handler
failures, and ordinary completion. Stateful `Assert` enablement is persistent across REPL inputs;
disabled assertions remain held, while enabled failures emit `Assert::asrtfl` through the ordinary
message scopes and `$MessagePrePrint` hook. Explicit `System`` spellings dispatch with the same
boundary as the Python reference. `ConfirmQuiet` and `FailWhen` deliberately remain symbolic
because the current Python compatibility reference has no evaluator implementation for either head.

The exact numeric reducer also covers the Python reference's integer combinatorics and sequences,
ordinary and Gaussian factorization, divisor and prime arithmetic, modular arithmetic and residue
symbols, continued fractions, integer partitions, digit/base conversion, Chinese remaindering,
special integer sequences, and arbitrary-precision bit operations.

Exact polynomial support now includes `MonomialList` with implicit, explicit, and partial variable
sets, all six Python-compatible lexicographic order directions, Gaussian coefficients, and the
reference's zero conventions. `PolynomialMod` maps integer and invertible rational coefficients into
positive residue representatives over arbitrary-size moduli while preserving unsupported domains
symbolically. Exact `Resultant` and `Discriminant` evaluation works over Gaussian-rational
multivariate polynomial rings, using a pivoted fraction-free Sylvester determinant and exact
polynomial division without a fixed degree cutoff; constants, zero polynomials, list threading,
qualified heads, and unsupported-domain fallback follow the Python reference. Shared `Plus`
normalization also factors the best common symbolic subset with real or complex numeric
coefficients, matching the reference's deterministic rebuilt forms.

## Compatibility boundary

The following Engine areas still use the Python implementation and are not represented as Haskell
features yet:

- the complete Wolfram tokenizer, box-language and StandardForm parser, including the broad named infix-operator precedence table;
- operational enforcement
  of the mutable iteration, precision, root-degree, and output-size settings, plus main-loop
  `$PreRead`/`$Pre`/`$Post`/`$PrePrint` hook application; `$MessagePrePrint` is implemented for
  explicit `Message` insertions and assertion diagnostics;
- nested positional-slot scope diagnostics, session-aware callback evaluation for aggregation and array reducers
  beyond the selection, map, sort, string-pattern, and pattern/rewrite families, the base
  encoding, import/export, and textual-form character-encoding surface, broader loop control, real-valued iteration,
  polynomial/SymPy bridges, broad
  number theory, and inexact numeric semantics;
- global message-stream recovery in the exported pure `Tungsten.Evaluate.evaluate` API, which
  remains fatal while session, CLI, protocol, and REPL evaluation recover nonfatal diagnostics;
- Python-specific `RegularExpression` constructs outside the POSIX TDFA intersection, including
  look-around, named groups, and inline flags other than a leading `(?i)`; ordinary expressions and
  the compatibility suite's case-insensitive prefix are supported;
- `OutputForm`, `TraditionalForm`, `TeXForm`, and the remaining display-form renderers at session
  output boundaries;
- tolerant parsing of representative saved notebooks, source-span-preserving edits, and byte-for-byte
  preservation of untouched notebook and box-expression formatting;
- the PowerShell and .NET projections, which currently target `tungsten-cpp` and do not yet call
  the Haskell executable.

Do not redirect an existing Python, PowerShell, or .NET production caller to `tungsten-hs` unless
its required commands and payload fields appear in the implemented table above and its own
compatibility tests pass.

## Migration order

The next useful port slices are:

1. grow parser and evaluator parity from the Python corpus and the local Wolfram held-parser oracle;
2. port source-preserving notebook spans and broader box-language interpretation;
3. finish context APIs, operational settings,
   remaining scoping/control flow, and real iteration on the immutable session;
4. complete broad Python CLI payload parity;
5. move the PowerShell and .NET projections only after their JSON contract tests pass against the
   Haskell executable.

Each slice should keep the Python behavior as an oracle where possible and should be committed only
with focused Haskell tests plus an end-to-end JSON smoke check.

Documentation index builds and full-text queries currently invoke the local `sqlite3` executable;
filename-fast-path search and record extraction remain available through the library without it.
