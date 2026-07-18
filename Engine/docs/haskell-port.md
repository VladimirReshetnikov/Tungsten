# Tungsten Engine Haskell port

- Status: Active incremental port and compatibility boundary
- Audience: Tungsten users, maintainers, integration authors, and contributors
- Scope: `Engine/haskell`, `Engine/tungsten-engine.cabal`, and `Engine/cabal.project`
- Created (UTC): 2026-07-18T14:01:03Z
- Updated (UTC): 2026-07-18T15:14:31Z
- Repository HEAD: b68944ed1ed42a9342dd2b00d6ee2f889a7cb599

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
| Rendering | Canonical structural FullForm, including compact roots, sparse arrays, byte arrays, and Wolfram-aware escaped strings/symbols |
| Wolfram strings | Character, control, numeric and line-continuation escapes; raw and PUA-decoded inline boxes; nested delimiter scanning through strings/comments; composition and display projection |
| FullForm parser | Calls and chained heads, exact and real atoms, shared Wolfram string decoding, nested comments, rationals, and complex atoms |
| InputForm parser | Core calls, lists, associations, parts, patterns, slots and pure functions, arithmetic, comparisons, Boolean operators, rules, replacements, conditions, assignments, application, and compound expressions |
| Evaluator | Exact arithmetic and powers, comparisons, Boolean control flow, structural predicates, parts, ranges and core list transforms, mapping/application, pure functions, exact replacement, held forms, and symbolic fallback |
| Sessions | Immutable immediate/delayed symbol own-values, assignment and updates, unset/clear, sequential state, and session-aware held control flow |
| JSON | Deterministic codec, tagged expression round trips, arbitrary integer lexemes, protocol requests/responses, parse/evaluate source commands, and structured errors |
| CLI | Expression, notebook, environment, kernel, FrontEnd, REPL, protocol, and inline-box command families with deterministic JSON and explicit exit behavior |
| REPL | Persistent definitions, `In`/`InString`/`Out`, `%` output shorthand, `$Line`, Wolfram-style prompts, and `Exit`/`Quit` codes |
| Discovery | Explicit `TUNGSTEN_WOLFRAM_HOME`, product-family selection, installed-version ranking, PATH fallback, executable/docs/license candidates, cache paths, and `env show` JSON |
| Kernel runner | Temporary source/wrapper/result isolation, stable temporary mathpass deduplication, held parsing, `EvaluationData` metadata, evaluated `Print` capture, optional `UsingFrontEnd`, process output, JSON decoding, and `kernel eval` exit behavior |
| FrontEnd | Hidden probing, wrapped/unwrapped code, notebook open, direct documentation locate, token execution, safely escaped code builders, and the `frontend` CLI family |
| Notebooks | Structural `Notebook`/`Cell`/`CellGroupData` parsing, nested group traversal, cell metadata and previews, deterministic creation/rendering, typed immutable patches, and `notebook inspect`/`notebook create`/`notebook patch` CLI commands |
| Inline boxes | Typed composition records, `BoxData` and box-bearing string extraction, stable deduplication, flat-index/path/UUID/ID/tag selectors, object selection, and `inline-box compose`/`inline-box from-cell` JSON commands |

## Compatibility boundary

The following Engine areas still use the Python implementation and are not represented as Haskell
features yet:

- the complete Wolfram tokenizer, named-character catalog, box-language and StandardForm parser;
- downvalues/subvalues/upvalues, symbol attributes, general pattern matching, scoping, iteration,
  polynomial/SymPy bridges, broad number theory, and inexact numeric semantics;
- source-span-preserving notebook edits and byte-for-byte preservation of original box-expression formatting;
- cross-process license launch gates, stale-process cleanup, license-seat waiting, documentation-index-backed identifier resolution, and Notebook Assistant automation;
- local documentation indexing, parser-corpus orchestration, and Notebook Assistant;
- the PowerShell and .NET projections, which continue to call the Python JSON CLI.

Do not redirect an existing Python, PowerShell, or .NET production caller to `tungsten-hs` unless
its required commands and payload fields appear in the implemented table above and its own
compatibility tests pass.

## Migration order

The next useful port slices are:

1. grow parser and evaluator parity from the Python corpus and the local Wolfram held-parser oracle;
2. port the complete named-character catalog and source-preserving notebook spans;
3. port definitions, attributes, pattern matching, scoping, and iteration on the immutable session;
4. port documentation indexing, parser-corpus orchestration, and Notebook Assistant workflows;
5. complete kernel licensing/concurrency behavior and broad Python CLI payload parity;
6. move the PowerShell and .NET projections only after their JSON contract tests pass against the
   Haskell executable.

Each slice should keep the Python behavior as an oracle where possible and should be committed only
with focused Haskell tests plus an end-to-end JSON smoke check.
