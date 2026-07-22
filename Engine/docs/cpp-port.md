# Tungsten Engine C++ Runtime and Verification

- Status: Active incomplete native-port and verification record
- Audience: Tungsten maintainers, reviewers, projection authors, and contributors
- Scope: `Engine/CMakeLists.txt`, `Engine/cpp/`, native projections, and Python-oracle parity tooling
- Created (UTC): 2026-07-18T01:44:22Z
- Updated (UTC): 2026-07-22T19:30:17Z
- Repository HEAD: `b6e36d4fcd683cb312b5bf4000be5da0205356cf`

## C++ port boundary

The C++ port is an independently buildable C++17 library and CLI built by CMake:

- `tungsten_cpp` is the native library;
- `tungsten-cpp` is the JSON-first CLI and kernel-free REPL;
- `cpp/include/tungsten/` contains the installed public headers;
- `cpp/src/` contains the expression, parser, evaluator, notebook, Wolfram automation, REPL, and
  CLI implementation;
- `cpp/tests/` contains native unit, component, and CLI smoke coverage.

The Python package under `src/tungsten/` remains the executable compatibility specification and is
used by development-only differential tools. It is not loaded by `tungsten-cpp` and is not a
production fallback. The Haskell port under `haskell/` remains an independent typed implementation
with its own Cabal build and compatibility boundary. The former Rust port is superseded;
[rust-port.md](./rust-port.md) and the Rust source tree are retained only as historical migration
records.

## Build, test, and install

From `Engine/`:

```powershell
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
ctest --test-dir build/cpp -C Release --output-on-failure
```

The build requires CMake 3.20+, a C++17 compiler, threads, and discoverable, ABI-compatible
GMP/GMPXX headers and libraries. Single-configuration generators normally place the CLI at
`build/cpp/tungsten-cpp(.exe)`. Visual Studio and other multi-configuration generators normally
place it at `build/cpp/Release/tungsten-cpp.exe`.

Install the library, headers, exported `Tungsten::Engine` CMake target, and CLI under a staging
prefix with:

```powershell
cmake --install build/cpp --config Release --prefix build/install
```

## Runtime and projection entry points

Run the native CLI or REPL directly:

```powershell
build/cpp/tungsten-cpp expr evaluate --code "ReplacePart[f[a, b, c], 2 -> x]"
build/cpp/tungsten-cpp repl
```

Use `.exe` on Windows and the `Release` subdirectory when required by the generator. PowerShell,
the .NET console launcher, and `TungstenClientOptions.CreateForRepositoryRoot` resolve the runtime
in this order:

1. `TUNGSTEN_EXECUTABLE` when set;
2. the direct `Engine/build/cpp` output;
3. common `Release`, `Debug`, `RelWithDebInfo`, and `MinSizeRel` subdirectories;
4. `tungsten-cpp` on `PATH`.

Explicit .NET executable paths and `LauncherArguments` remain supported for custom launchers.

## Ported subsystem surface

The C++ tree contains native implementations for:

- immutable Wolfram expression values, canonical InputForm/FullForm rendering, JSON, exact GMP
  integers/rationals, roots, byte arrays, and sparse arrays;
- InputForm, FullForm, and the supported StandardForm parser subset;
- the broad bounded evaluator subset, process-local definitions/attributes, patterns, scoping,
  collections, arithmetic, strings, formatting, messages, and control flow;
- source-preserving notebook parsing/editing and JSON patching;
- Wolfram string literals and inline-box composition/extraction;
- installation/license discovery, process inspection, kernel execution, FrontEnd control, and
  Notebook Assistant workflows;
- SQLite documentation indexing/search;
- parser-corpus discovery and optional held-Wolfram comparison;
- the stateful kernel-free REPL and compatible JSON-first CLI command tree.

This list describes the native component map, not perfect semantic parity. Unsupported expressions
remain symbolic where possible, and the differential results below identify known gaps.

## Verification record

The following results were observed on 2026-07-18 in the Linux verification environment using the
working tree based on the repository HEAD above:

| Gate | Observed result |
|---|---|
| Native CTest suite | 16/16 passed, covering the expression model/evaluator, JSON, bundled data, runtime foundation, strings, notebooks, inline boxes, processes/kernel, REPL, docs index, FrontEnd, parser corpus, assistant, and CLI smoke |
| Parser differential | 1,414 unique Python-test literals compared; one shared rejection; zero mismatches |
| Stateful evaluator differential | 82/82 steps matched across 10 fresh-process scenarios |
| Native/Python CLI differential | 119/119 command cases matched across the Python command families and native CLI |
| .NET projection suite | 14/14 tests passed; the added native integration case round-trips a Unicode notebook patch and guards BOM-less UTF-8 patch-spec output |
| Python compatibility-oracle suite | 846 tests passed, with 4 skipped and 2 expected failures |
| Recorded evaluator differential | 2,499/2,499 top-level calls matched across 585 Python tests; zero mismatches |

### 2026-07-22 integration build

The C++ branch at `b6e36d4fcd683cb312b5bf4000be5da0205356cf` was integrated with `main` at
`d15988af27446b547fe5e465bb2a765c305bce7f` and validated on Linux before publication:

| Gate | Result |
|---|---|
| GCC 12.3 strict Release | 52/52 Ninja steps completed with `-Werror -Wall -Wextra -Wpedantic`; zero warnings and zero errors |
| GCC CTest | 16/16 passed |
| Clang 21.1.8 Release | 52/52 Ninja steps completed; all project warnings remained fatal, with only libstdc++ 12's internal deprecated `std::get_temporary_buffer` diagnostic exempted from `-Werror` |
| Clang CTest | 16/16 passed |
| Native CLI smoke | `tungsten-cpp expr evaluate --code '2+2'` returned the exact integer `4` |
| Install/export consumer | Staged install completed; an external CMake project found `TungstenEngine`, linked `Tungsten::Engine`, built, and ran successfully |
| .NET projection suite | 14/14 Release tests passed |
| Coexisting Haskell suite | Warning-as-error Cabal test passed after integration |

The Clang exception is a host-toolchain interaction inside libstdc++'s implementation of
`std::stable_sort`, not a warning in Tungsten source. A normal Clang build completes without any
special option; the exemption is needed only when globally promoting every deprecation from the
host standard library to an error.

Run the compatibility gates from `Engine/` with:

```powershell
uv run python scripts/check_cpp_parser_parity.py --no-build
uv run python scripts/check_cpp_evaluator_parity.py --no-build --tests tests
uv run python scripts/check_cpp_stateful_evaluator_parity.py --no-build --require-perfect
uv run python scripts/check_cpp_recorded_evaluator_parity.py --no-build --workers 8 --require-perfect
uv run python scripts/check_cpp_cli_parity.py
```

The parser gate already fails on a mismatch; the stateful and recorded evaluator gates use
`--require-perfect`. The standalone
evaluator extractor intentionally loses setup state for some assertions; it remains a useful
diagnostic, but its raw count is not a semantic acceptance gate. The recorded harness executes each
Python test with its setup and replays canonical FullForm inputs against a fresh native evaluator,
so it is the authoritative broad evaluator comparison.

## Compatibility scope after parity closure

The native evaluator now includes broad exact arithmetic and number theory, bounded elementary and
transcendental evaluation, variable-free `Simplify`/`FullSimplify`, mutable protection and
definition state, messages/control flow, and algebraic-number support. It remains intentionally
bounded rather than a complete Wolfram kernel. Unsupported argument shapes and algorithms stay
symbolic where possible. The recorded evaluator differential is exact over its current 2,499-call,
585-test corpus; that result measures Python-oracle compatibility for the exercised forms, not full
Wolfram-kernel coverage.

The standalone extractor will continue to report setup-dependent differences even after every
recorded test is exact. Those are extraction artifacts, not native evaluator failures: literal
assertions that rely on preceding assignments, registry mutations, or session state cannot be
reconstructed from the assertion text alone.

## Intentional public-API compatibility boundaries

The following native choices differ from Python implementation details but do not affect ordinary,
valid CLI workflows:

- notebook patch `{}` is accepted as a no-op; non-empty operations still require typed fields,
  non-negative bounded paths, and an in-range insertion index rather than Python coercion or
  `list.insert` clamping;
- `SourceSpan::start()` and `SourceSpan::end()` are offsets into the immutable UTF-8 byte buffer,
  not Python Unicode code-point offsets;
- arbitrary-size CLI integer options accept signed ASCII decimal digits (and valid ASCII
  underscore separators), not Python's wider set of Unicode decimal digits;
- negative worker, batch, preview, maximum-file, and sample inputs may be normalized to their
  operational values in summary JSON instead of echoing the raw spelling;
- exact `Root` index and method fields use native `std::size_t` and `long` widths; callers must not
  assume Python's unbounded integer range for those metadata fields;
- sparse-expression JSON omits Python's optional `backend` field because that field names a
  Python-specific acceleration implementation, not part of the portable expression contract.

## Validation limits

- The Linux verification environment did not provide a live Wolfram executable, so kernel, FrontEnd,
  Notebook Assistant, and held-parser script generation were tested structurally and through
  unavailable-runtime paths, not by a successful live Wolfram round trip.
- Windows execution and MSVC/Visual Studio multi-configuration output were not run in this Linux
  pass. Their `.exe` resolution paths are implemented and documented but still require live
  Windows validation. No native macOS build was available for this record either.
- A downstream consumer must use GMP/GMPXX headers and libraries that are ABI-compatible with the
  ones used to build `Tungsten::Engine`; the exported CMake package discovers GMP but cannot prove
  binary compatibility for a manually mixed installation.
- The current Windows process launcher uses broad inheritable-handle mode rather than a restricted
  explicit handle allow-list. This is suitable for Tungsten's trusted local automation model, but
  an embedding process with sensitive inheritable handles should close or de-inherit them before
  launch.
- Parser-corpus seeded sampling reproduces CPython integer seeding, bounded draws, and shuffle
  order. Unicode 15.1 lowercase/case-fold ordering and code-point `fnmatchcase` behavior are also
  compatibility-tested; these are not platform-locale operations.
- Threaded C++ parser-corpus workers replace Python worker processes, so isolation and scheduling
  characteristics differ even though result ordering is stable.

## Ongoing acceptance rule

For each implemented behavior, use native C++ tests as the runtime regression gate and the Python suite
as the compatibility oracle. Prefer exact JSON/InputForm/FullForm comparisons and stateful
scenarios over broad claims of parity. Live Wolfram validation remains a separate opt-in gate on a
machine with the required installation, licensing, and desktop state.
