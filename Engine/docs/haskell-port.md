# Tungsten Engine Haskell port

- Status: Active incremental port and compatibility boundary
- Audience: Tungsten users, maintainers, integration authors, and contributors
- Scope: `Engine/haskell`, `Engine/tungsten-engine.cabal`, and `Engine/cabal.project`
- Created (UTC): 2026-07-18T14:01:03Z
- Updated (UTC): 2026-07-22T07:07:36Z
- Repository HEAD: 565b25a27b51e5876269eb8f857a1bac8453fb36

## Purpose

The Haskell implementation is the new typed core of Tungsten Engine. It is being introduced in
coherent, independently testable slices while the Python implementation remains the compatibility
reference for the wider automation surface. The two implementations currently coexist under the
same `Engine` ownership boundary.

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
| Evaluator | Exact arithmetic with coefficient-aware symbolic term/factor collection, integer powers, exact rational-power radical extraction, explicit-number `Sqrt`, scalar and explicit-complex exact/source-real `Floor`/`Ceiling`/half-even `Round`/`IntegerPart`/`FractionalPart` with signed exact multiples, recursive-list `Min`/`Max` folding over explicit reals and symbolic residues, canonical ordering/sort-by/set operations, comparisons, Boolean control flow, structural and quantified collection predicates, predicate select/discard/first/while/pick operations over heads and associations, structural MatchQ blanks/typed and named bindings/PatternTest/alternatives/exceptions/conditions/backtracking sequence blanks, explicit optional defaults, bounded Repeated/RepeatedNull, named and orderless PatternSequence, Longest/Shortest allocation priorities, structural OptionsPattern capture, order-independent KeyValuePattern entry matching, catalog- and session-attribute-aware `Flat` grouping, `OneIdentity` unwrapping, Python-ordered `Orderless` permutation search with effect-preserving backtracking, variable-width Optional/Alternatives sequence matching, and fixed-width IgnoringInactive structural views with original-value bindings plus level-aware traversal and binding/sequence-aware Cases/Replace/ReplaceAll/ReplaceRepeated/Position/FirstPosition transformations, postorder `Level` extraction over positive, negative, ranged, and infinite specifications with optional `False` heads flag and non-re-evaluated held results, Python-compatible zero-argument/root/sparse-array depth, canonical PositionLargest/PositionSmallest and grouped PositionIndex, exact-path pattern-aware ReplaceAt, recursive numeric/key/`All`/`Span` parts with head-preserving selector lists and per-selection remaining specifications, extraction, ranges, strict multi-axis take/drop, append/prepend/join, rotation, bounded/named-head flattening, nested delete/insert/replace/map-at operations across list and association paths, mapping/application, association normalization/access/key transforms/value-aware structural operations/ordered grouping and key-set alignment, dense rectangular array construction/reshape/padding/block flattening/arbitrary-rank transposition, vector and matrix constructors, tuples/partition/take-list/take-drop, exact symbolic `Dot`/`Cross`/`Det`/`Inverse`/`MatrixPower`, matrix totals, ordered tally/counts, catenation, differences, accumulation, riffle, containment, subsets/permutations, padding and exact mean/median, literal string character/list conversion, slicing, insertion, joining, case conversion, reversal, repetition, padding, splitting, riffle, trimming, counting, positions, and contains/match/free/starts/ends predicates, compact byte-array construction/predicates/length/normalization plus Unicode, PrintableASCII, ASCII, Latin-1/15, Windows-1252, and UTF-8/16/32 character-code and byte-string conversions with invalid-byte preservation, positional and capture-aware named pure functions including recursive `SlotSequence`, exact replacement, held forms including `HoldComplete`, bottom-up `Sequence`/`Splice`/`Nothing` argument normalization, and symbolic fallback |
| Sessions | Uniform catalog-backed symbol records with immediate/delayed own values, ordered conditional downvalues, upvalues, and one-level curried subvalues, plus a reserved n-value slot, held value inspection and session-aware `ValueQ` structural probing with live effects and non-local control propagation, whole-expression symbol registration, fixed `$Context`/`$ContextPath` values, validated `Symbol` construction, `SymbolName`/`Context` inspection, wildcard `Names`/`NameQ`/`Contexts` registry queries, visible `System`/`Global` identity resolution, active-own-value cycle guards, intrinsic `I`/`MachinePrecision`, seeded system settings, mutable `Attributes`/`SetAttributes`/`ClearAttributes`, protection/locking, wildcard `Clear`/`ClearAll`, and attribute-driven hold, sequence, listable, flat, orderless, and pure-function evaluation; compound `Set`/`SetDelayed`/`Unset`, `TagSet`/`TagSetDelayed`/`TagUnset` natural-value and immediate-argument/head-chain routing, evaluated curried-head owner retargeting, shared down/up/subvalue matching and return boundaries, left-to-right identity-deduplicated UpValue candidates before DownValues or SubValues with `HoldAllComplete` suppression, user-head alias retargeting, exact-before-generic dispatch with explicit-System structural preservation, recursive and memoizing rule bodies, session-native stateful pure functions, assignment and updates, sequential state, state-preserving internal evaluation exits, pattern-tagged non-local `Catch`/`Throw` with handlers, `Break`/`Continue` propagation with `Do`/`For`/`While` boundaries, evaluated bare and headed `Return` propagation with Python-compatible definition-RHS boundaries and exact `Module`/`Block`/`InheritedBlock`/`Do`/`For`/`While` target catches, held `For` and one- or two-argument `While` with phase-specific `Continue`, whole-loop `Break`, state preservation, and the Python iteration safety boundary, held `With` simultaneous substitution with independent eager or duplicated delayed values, deterministic capture avoidance through named functions and nested `With`/`Module`/`Block` scopes, held `Module` lexical scoping with monotone shared-suffix fresh symbols, independent eager/delayed initializers, capture-avoiding body renaming, persistent fresh definitions and closure rule tables, and exit-safe initializer state, held `Block` plus both `InheritedBlock` spellings with validated left-to-right immediate/delayed initializers, dynamic own/down/up/sub-value inheritance, and scoped restoration across normal or non-local exits while retaining unrelated effects, session-aware held control flow, held pattern and rewrite dispatch for `MatchQ`, `Cases`, `DeleteCases`, `FirstCase`, `Replace`, `ReplaceAll`, `ReplaceRepeated`, `ReplaceAt`, `Position`, `FirstPosition`, `Count`, `FreeQ`, and `MemberQ`, state-preserving `Condition`/`PatternTest` callbacks across failed alternatives and traversal, once-only eager rule preparation versus per-match delayed rules, exact held-context replacement rebuilding, semantic association value-only traversal with qualified-head preservation, effectful down/up/subvalue matching without duplicated callbacks, dynamically scoped held `Table`/`Do`/`Sum`/`Product` iteration over counts/exact ranges/value lists/nested dependent specifications with complete value-slot iterator snapshots and nested-list, side-effect-only, or flat arithmetic-fold results as appropriate, ordered generated/visible nonfatal diagnostics with raw-syntax recovery, left-to-right `Clear` diagnostics, and preserved argument effects, qualified structural constructors at consumer boundaries, targeted session re-entry for totals, level-aware generated `Map`/`Apply`, expanded exact `MapAt` selectors (`All`, `Span`, numeric/key selector lists, duplicates, and nested paths), and `AssociationMap`/`KeyMap`/`KeyValueMap` calls, session-threaded `Select`/`Discard`/`SelectFirst`/`TakeWhile`/`LengthWhile`/`KeySelect` predicates and `SortBy`/`ReverseSortBy` key extraction, ordering callbacks, trailing `SameTest` options, eager/delayed option timing, exact CPython 3.13 stable-sort callback scheduling, raw-head `Print` capture, and fresh-session stateless command evaluation |
| JSON | Deterministic codec, tagged expression round trips, arbitrary integer lexemes, protocol requests/responses with FullForm and InputForm expression projections, session-backed parse/evaluate source commands, ordered message and print payloads, and structured fatal errors |
| CLI | Expression, notebook, environment, kernel, FrontEnd, REPL, protocol, and inline-box command families with Python-compatible FullForm/InputForm JSON projections, fresh evaluation sessions, nonfatal evaluation payloads, and explicit exit behavior; the InputForm/FullForm expression commands reproduce the Python success and error field sets, error types, source inclusion, diagnostics, standard-error output, and exit codes |
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

## Compatibility boundary

The following Engine areas still use the Python implementation and are not represented as Haskell
features yet:

- the complete Wolfram tokenizer, box-language and StandardForm parser, including the broad named infix-operator precedence table;
- `Unique` symbol allocation and operational enforcement
  of the mutable iteration, recursion, precision, root-degree, history, and output-size settings;
- symbol-name validation, symbol and three-argument `Function` attributes, nested positional-slot
  scope diagnostics, session-aware callback evaluation for aggregation reducers
  beyond the selection, map, sort, and pattern/rewrite families, the full string-pattern, base
  encoding, import/export, and textual-form character-encoding surface, broader loop and jump control, real-valued iteration,
  polynomial/SymPy bridges, broad
  number theory, and inexact numeric semantics;
- global message-stream recovery in the exported pure `Tungsten.Evaluate.evaluate` API, which
  remains fatal while session, CLI, protocol, and REPL evaluation recover nonfatal diagnostics;
- general `Array`, `ArrayQ`, `Tr`, `LeviCivitaTensor`, and full `SparseArray` construction,
  properties, transformations, slicing, arithmetic, and dot products;
- source-span-preserving notebook edits and byte-for-byte preservation of original box-expression formatting;
- the PowerShell and .NET projections, which continue to call the Python JSON CLI.

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
