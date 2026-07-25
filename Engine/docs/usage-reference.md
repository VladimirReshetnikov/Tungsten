# Tungsten Usage Reference

- Status: Informational and reference-oriented (command surface and payload reference)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and anyone scripting the CLI or PowerShell wrappers
- Scope: Tungsten command-line and PowerShell surfaces
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-07-18T04:31:20Z
- Repository HEAD: 64a65f4894ba14a84b73917bc595b7e1779703f7
- Related docs:
  - [Project README](../README.md)
  - [User Guide](./user-guide.md)
  - [C#/.NET API](./dotnet-api.md)
  - [Inline Box Strings](./inline-box-strings.md)
  - [Troubleshooting](./troubleshooting.md)
  - [Notebook Assistant](./notebook-assistant.md)
  - [Expression Parser](./expression-parser.md)
  - [Symbol and Context Registry](./symbol-context-registry.md)
  - [Expression Function Support](./expression-function-support.md)
  - [Sequence Pattern Matching](./sequence-pattern-matching.md)
  - [Parser Corpus](./parser-corpus.md)

## Conventions

- The native CLI is JSON-first for command surfaces; `repl` is interactive text.
- The PowerShell module is a thin wrapper over `tungsten-cpp ...`; it returns deserialized
  PowerShell objects based on those JSON payloads.
- The .NET client in [dotnet-api.md](./dotnet-api.md) is a typed wrapper over the same JSON
  command surface documented here.
- Kernel-backed commands depend on a real local Wolfram installation.
- Kernel-free commands such as notebook file inspection and expression parsing do not require a
  running kernel.
- Arbitrary-size integer option parsing uses signed ASCII decimal digits with valid ASCII
  underscore separators. It intentionally does not accept Python's additional Unicode decimal
  digit classes; normal documented command lines are unchanged.

## Exit codes

- `0` means the command completed and produced its normal JSON payload. For commands that support
  `--require-success`, the payload may still describe a structured failure when that switch is not
  supplied.
- `1` means the command reported a structured failure that Tungsten treats as user-visible failure:
  `expr parse` and `expr evaluate` use it for syntax and structural evaluation errors, and
  `kernel`, `frontend`, `assistant`, and `inline-box from-cell` use it when `--require-success` is
  supplied and the returned payload reports failure.
- `2` is currently used only by `kernel eval`, and means Tungsten could not produce a structured
  evaluation payload at all. Typical causes include `KernelNotFound`, launch failures, or a kernel
  run that never reached Tungsten's JSON export step.
- `repl` returns the integer supplied to `Exit[code]` or `Quit[code]`. Plain `Exit`, `Exit[]`,
  `Quit`, and `Quit[]` return `0`.

## Native CLI

Build the native executable from the repository checkout:

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
Pop-Location
```

The executable is normally `Engine/build/cpp/tungsten-cpp(.exe)` for a single-configuration
generator or `Engine/build/cpp/Release/tungsten-cpp.exe` for a multi-configuration generator.
Add that directory to `PATH`, invoke the executable by path, or set `TUNGSTEN_EXECUTABLE` for the
PowerShell and .NET projections.

### `repl`

Purpose:

- start the kernel-free Tungsten interpreter with `wolfram.exe`-style prompts;
- maintain session history through `$Line`, `In`, `InString`, `Out`, `DownValues`, and `%`
  shorthand;
- bound retained history with `$HistoryLength` and shorten very large console outputs with
  Tungsten's heuristic `$OutputSizeLimit`;
- exit through `Exit`, `Exit[code]`, `Quit`, or `Quit[code]`.

Examples:

```powershell
tungsten-cpp repl
tungsten-cpp repl --no-banner
tungsten-cpp
```

The optional .NET console projection launches the same native CLI:

```powershell
dotnet build .\Engine\dotnet\Tungsten.DotNet.slnx
.\Engine\dotnet\Tungsten.Console\bin\Debug\net10.0\tungsten.exe
```

Inside the REPL:

```wolfram
1 + 2
$Line
In[1]
InString[1]
Out[1]
% + 10
DownValues[In]
$HistoryLength = 2
$OutputSizeLimit = 80
Range[100]
Short[Range[100]]
Shallow[Range[100], {Infinity, 5}]
$PreRead = Function[s, StringReplace[s, "aa" -> "1+2"]]
aa
$PrePrint = FullForm
1 + x
$PrePrint =.
Quit
```

Read [repl.md](./repl.md) for the exact supported history behavior.

### `env`

#### `env show`

Purpose:

- show discovered installation paths and local documentation roots;
- optionally run live kernel and FrontEnd probes.

Examples:

```powershell
tungsten-cpp env show
tungsten-cpp env show --probe
```

Important output fields:

- `product`
- `product_family`
- `version`
- `install_dir`
- `kernel_cli`
- `kernel_executable`
- `frontend_executable`
- `wolframscript`
- `mathpass`
- `mathpass_candidates`
- `docs_roots`
- `bundled_python_client`
- `default_index_path`
- `available_installations`
- `selection_reason`
- `probe` when `--probe` is supplied

### `kernel`

#### `kernel eval`

Purpose:

- evaluate inline Wolfram Language code or a file through `wolfram.exe`;
- optionally evaluate inside `UsingFrontEnd[...]`.

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--working-directory <path>`: optional
- `--front-end`: wrap evaluation in `UsingFrontEnd[...]`
- `--require-success`: return exit code `1` when the evaluation reports `success: false`

Examples:

```powershell
tungsten-cpp kernel eval --code "2+2"
tungsten-cpp kernel eval --code "Print[Prime[10]]; Prime[20]"
tungsten-cpp kernel eval --code "NotebookLocate[\"paclet:ref/NotebookGet\"]" --front-end
tungsten-cpp kernel eval --file C:\path\to\script.wl
```

Important output fields:

- `success`
- `failure_type`
- `result`
- `result_head`
- `messages`
- `messages_text`
- `output`
- `timing`
- `absolute_timing`
- `evaluation_available`
- `mathpass`
- `used_mathpass_workaround`

### `notebook`

#### `notebook inspect`

Purpose:

- parse a notebook file structurally and return a flattened cell inventory.

Example:

```powershell
tungsten-cpp notebook inspect --file C:\path\to\notebook.nb
```

Important output fields:

- `title`
- `cell_count`
- `group_count`
- `options`
- `cells`

Each cell row may include:

- `index`
- `path`
- `style`
- `preview`
- `expression_uuid`
- `cell_id`
- `cell_tags`

#### `notebook create`

Purpose:

- create a notebook file from a title plus repeated `STYLE:TEXT` cell specifications.

Options:

- `--file <path>`: required
- `--title <text>`: optional
- `--cell <STYLE:TEXT>`: repeatable

Example:

```powershell
tungsten-cpp notebook create `
    --file C:\Temp\new.nb `
    --title "Generated Notebook" `
    --cell "Title:Generated Notebook" `
    --cell "Text:Hello" `
    --cell "Input:2+2"
```

#### `notebook patch`

Purpose:

- apply a JSON patch spec to a notebook.

Options:

- `--file <path>`: required
- `--spec <path>`: required
- `--out <path>`: optional; defaults to in-place update

Example:

```powershell
tungsten-cpp notebook patch --file C:\Temp\new.nb --spec C:\Temp\patch.json
```

Patch operations currently supported by Tungsten include:

- `append_cell`
- `insert_cell`
- `replace_cell`
- `delete_item`
- `set_option`

Example patch specification:

```json
{
  "operations": [
    {
      "op": "append_cell",
      "style": "Text",
      "text": "Tail cell"
    },
    {
      "op": "replace_cell",
      "path": [0],
      "style": "Title",
      "text": "Retitled notebook"
    },
    {
      "op": "set_option",
      "name": "WindowTitle",
      "value_expr": "\"Retitled notebook\""
    }
  ]
}
```

### `inline-box`

Purpose:

- compose Wolfram string literals that contain embedded inline box escapes;
- extract box-bearing objects from saved notebook cells and immediately turn them into ready-to-use
  string literals.

#### Shared selector options

These selector forms are mutually exclusive and are reused across cell-targeted inline-box
commands:

- `--cell-index <n>`
- `--cell-path <json-or-comma-separated-int-list>`
- `--expression-uuid <uuid>`
- `--cell-id <int>`
- `--cell-tag <tag>`

#### `inline-box compose`

Options:

- `--prefix <text>`: optional
- `--box-expr <text>`: repeatable
- `--suffix <text>`: optional

Example:

```powershell
tungsten-cpp inline-box compose `
    --prefix "icon: " `
    --box-expr "GraphicsBox[{CircleBox[]}]"
```

Important output fields:

- `boxes`
- `string_value`
- `string_literal`
- `string_segments`

#### `inline-box from-cell`

Options:

- `--file <path>`: required
- one selector option: required
- `--prefix <text>`: optional
- `--suffix <text>`: optional
- `--object-index <n>`: optional; defaults to `0`
- `--all-objects`: optional
- `--require-success`

Examples:

```powershell
tungsten-cpp inline-box from-cell `
    --file C:\Temp\demo.nb `
    --expression-uuid uuid-inline-box `
    --prefix "icon: "

tungsten-cpp inline-box from-cell `
    --file C:\Temp\demo.nb `
    --cell-index 0 `
    --all-objects `
    --prefix "objects: "
```

Important output fields:

- `source_cell`
- `available_box_count`
- `available_boxes`
- `selected_box_count`
- `selected_boxes`
- `string_value`
- `string_literal`
- `string_segments`

### `expr`

Purpose:

- parse Wolfram expressions without a kernel;
- structurally evaluate a small inert built-in set.

#### `expr parse`

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--form input|fullform|standard`: optional; defaults to `input`

Examples:

```powershell
tungsten-cpp expr parse --code "1 + 2 x^3"
tungsten-cpp expr parse --code "Rule[x, List[1, 2]]" --form fullform
tungsten-cpp expr parse --code "f @ x // g" --form standard
```

Important output fields:

- `input_form`
- `full_form`
- `depth`
- `length`
- `tree`

On syntax failure, `expr parse` still writes structured JSON to stdout and returns exit code `1`
with:

- `success: false`
- `error_type: "WolframSyntaxError"`
- `error`

#### `expr evaluate`

Options:

- `--code <text>` or `--file <path>`: required, mutually exclusive
- `--form input|fullform|standard`: optional; defaults to `input`

Examples:

```powershell
tungsten-cpp expr evaluate --code "Length[{a, b, c}]"
tungsten-cpp expr evaluate --code "1 + 2 + 3"
tungsten-cpp expr evaluate --code "True && False && x"
tungsten-cpp expr evaluate --code '$ContextPath'
tungsten-cpp expr evaluate --code 'Context[System`Plus]'
tungsten-cpp expr evaluate --code '{Symbol["TungstenUsage`alpha"], Names["TungstenUsage`*"]}'
tungsten-cpp expr evaluate --code 'Length[Names["System`*"]]'
tungsten-cpp expr evaluate --code 'NameQ["System`AASTriangle"]'
tungsten-cpp expr evaluate --code 'Attributes[Plus]'
tungsten-cpp expr evaluate --code 'x = 1 + 2; {ValueQ[x], OwnValues[x], x}'
tungsten-cpp expr evaluate --code 'x = 1; Clear[x]; ValueQ[x]'
tungsten-cpp expr evaluate --code 'f[x_] := x + 1; {f[3], DownValues[f]}'
tungsten-cpp expr evaluate --code 'f[x_][y_] := {x, y}; {f[1][2], SubValues[f]}'
tungsten-cpp expr evaluate --code 'f /: h[f[x_]] := x + 10; {h[f[2]], UpValues[f]}'
tungsten-cpp expr evaluate --code 'f /: h[f[x_]] =.; UpValues[f]'
tungsten-cpp expr evaluate --code "Level[f[a, g[b]], -1]"
tungsten-cpp expr evaluate --code "Part[f[a, b, c], {1, 3}]"
tungsten-cpp expr evaluate --code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
tungsten-cpp expr evaluate --code "MatchQ[f[a, a], f[x_, x_]]"
tungsten-cpp expr evaluate --code "MatchQ[f[2], f[x_ /; x > 0]]"
tungsten-cpp expr evaluate --code "FreeQ[f[a], f]"
tungsten-cpp expr evaluate --code "Cases[{f[a], f[b]}, f[x_] :> x]"
tungsten-cpp expr evaluate --code "Cases[{1, -2, 3}, x_ :> x + 1 /; x > 0]"
tungsten-cpp expr evaluate --code "DeleteCases[f[a, g[a]], a, Infinity]"
tungsten-cpp expr evaluate --code "Replace[f[g[a]], x_ :> p[x], {0, Infinity}]"
tungsten-cpp expr evaluate --code "Replace[1, {x_ :> x + 1 /; x < 0, x_ :> x + 2}]"
tungsten-cpp expr evaluate --code "If[1 < 2, 1 + 2, 9]"
tungsten-cpp expr evaluate --code "Which[False, a, True, 1 + 2]"
tungsten-cpp expr evaluate --code "Switch[a, _Integer, 1, _Symbol, 2]"
tungsten-cpp expr evaluate --code "Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"
tungsten-cpp expr evaluate --code "Pick[f[a, b, c, d], {False, True, False, True}]"
tungsten-cpp expr evaluate --code "Select[f[1, a, 2, 3], IntegerQ]"
tungsten-cpp expr evaluate --code "Select[{1, a, 2, 3}, # > 1 & -> {\"Element\", \"Index\"}]"
tungsten-cpp expr evaluate --code "Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"
tungsten-cpp expr evaluate --code "SelectFirst[{1, a, 2, 3}, # > 1 &]"
tungsten-cpp expr evaluate --code "TakeWhile[f[2, 4, 6, 7, 8], EvenQ]"
tungsten-cpp expr evaluate --code "Mod[-14, 5]"
tungsten-cpp expr evaluate --code "Clip[-7, {-5, 5}, {100, 200}]"
tungsten-cpp expr evaluate --code "KroneckerDelta[3, 3, 3]"
tungsten-cpp expr evaluate --code "f[g[a]] /. g[x_] :> x"
tungsten-cpp expr evaluate --code "f[a] //. f[x_] :> x"
tungsten-cpp expr evaluate --code "Map[# + 1 &, {a, b}]"
tungsten-cpp expr evaluate --code "(f[##2] &)[a, b, c]"
tungsten-cpp expr evaluate --code "Function[Null, HoldComplete[#], HoldAll][1 + 2]"
tungsten-cpp expr evaluate --code "Function[Null, f[#], Listable][{a, b}]"
tungsten-cpp expr evaluate --code "ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}]"
tungsten-cpp expr evaluate --code "ReplacePart[f[a, b, c], 2 -> x]"
tungsten-cpp expr evaluate --code "MapAt[g, f[a, h[b, c], d], {2, 1}]"
tungsten-cpp expr evaluate --code "Composition[f, g][x]"
tungsten-cpp expr evaluate --code "MapApply[f, {g[a, b], h[c]}]"
tungsten-cpp expr evaluate --code "Thread[f[{a, b}, {c, d}]]"
tungsten-cpp expr evaluate --code "Fold[f, x, {a, b, c}]"
tungsten-cpp expr evaluate --code "BlockMap[f, {a, b, c, d, e}, 2]"
tungsten-cpp expr evaluate --code "DeleteDuplicatesBy[{{a}, {b, c}, {d}}, Length]"
tungsten-cpp expr evaluate --code "SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]"
tungsten-cpp expr evaluate --code "OrderingBy[{{a, 2}, {b, 1}, {c, 3}}, Last, -2]"
tungsten-cpp expr evaluate --code "MaximalBy[<|a -> 2, b -> 1, c -> 2|>, Identity]"
tungsten-cpp expr evaluate --code "LexicographicSort[{\"ba\", \"aa\", \"ab\"}]"
tungsten-cpp expr evaluate --code "StringTake[\"abcdef\", {2, 5, 2}]"
tungsten-cpp expr evaluate --code "StringJoin[{\"a\", {\"b\", \"c\"}}]"
tungsten-cpp expr evaluate --code "StringMatchQ[\"catalog\", \"c\" ~~ __ ~~ \"g\"]"
tungsten-cpp expr evaluate --code "StringCases[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
tungsten-cpp expr evaluate --code "StringCases[\"abc123def45\", LetterCharacter.. ~~ DigitCharacter..]"
tungsten-cpp expr evaluate --code "StringPosition[\"ababa\", Shortest[\"a\" ~~ ___ ~~ \"a\"]]"
tungsten-cpp expr evaluate --code "StringCases[\"on 2026-04-25 ok\", DatePattern[{\"Year\", \"Month\", \"Day\"}]]"
tungsten-cpp expr evaluate --code "StringCases[\"abc123\", RegularExpression[\"[a-z]+\"]]"
tungsten-cpp expr evaluate --code "StringReplace[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
tungsten-cpp expr evaluate --code "StringPosition[\"ababa\", \"a\" ~~ __ ~~ \"a\"]"
tungsten-cpp expr evaluate --code "ImportString[\"{\\\"a\\\":1,\\\"b\\\":[2,3]}\", \"RawJSON\"]"
tungsten-cpp expr evaluate --code "ImportString[ExportString[{{1, 2}, {3, 4}}, \"CSV\"], \"CSV\"]"
tungsten-cpp expr evaluate --code "ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {\"GZIP\", \"CSV\"}], {\"GZIP\", \"CSV\"}]"
tungsten-cpp expr evaluate --code "ToExpression[ToString[HoldComplete[1 + 2], InputForm], InputForm]"
tungsten-cpp expr evaluate --code "ToString[FullForm[{1, 2/3, a + b}]]"
tungsten-cpp expr evaluate --code "ToBoxes[InputForm[1 + x]]"
tungsten-cpp expr evaluate --code "ToString[1 + x, TeXForm]"
tungsten-cpp expr evaluate --code "ToString[1 + x, MathMLForm]"
tungsten-cpp expr evaluate --code "ToString[1 + x, TraditionalForm]"
tungsten-cpp expr evaluate --code "ToString[x^2, CForm]"
tungsten-cpp expr evaluate --code "ToString[x^2, FortranForm]"
tungsten-cpp expr evaluate --code "NumberForm[1.2345, 3]"
tungsten-cpp expr evaluate --code "PercentForm[0.1234, 3]"
tungsten-cpp expr evaluate --code "TableForm[{{1, 22}, {333, 4}}]"
tungsten-cpp expr evaluate --code 'StringForm["a `` `1`", b]'
tungsten-cpp expr evaluate --code "ToExpression[ToString[1 + x, TeXForm], TeXForm, HoldComplete]"
tungsten-cpp expr evaluate --code "ToBoxes[TraditionalForm[1 + x]]"
tungsten-cpp expr evaluate --code "ToBoxes[CForm[x^2]]"
tungsten-cpp expr evaluate --code "Print[FullForm[{1, 2/3, a + b}]]"
tungsten-cpp expr evaluate --code 'ToExpression["f @ x // g", StandardForm, HoldComplete]'
tungsten-cpp expr evaluate --code 'ToExpression[RowBox[{"a", "\[CirclePlus]", "b"}], StandardForm, HoldComplete]'
tungsten-cpp expr evaluate --code 'MakeExpression[SubscriptBox["x", "i"], StandardForm]'
tungsten-cpp expr evaluate --code 'StripBoxes[RowBox[{"1", " ", StyleBox["+", Red], "2"}]]'
tungsten-cpp expr evaluate --code 'SyntaxQ["a \[CirclePlus] b", StandardForm]'
tungsten-cpp expr evaluate --code "Select[{\"ab\", \"cd\", \"ba\"}, StringContainsQ[\"a\"]]"
tungsten-cpp expr evaluate --code "Normal[ByteArray[\"QUJD\"]]"
tungsten-cpp expr evaluate --code "BaseEncode[StringToByteArray[\"abc\"], \"Base16\"]"
tungsten-cpp expr evaluate --code "ToCharacterCode[ByteArrayToString[ByteArray[{97, 195, 169}], \"UTF-8\"]]"
tungsten-cpp expr evaluate --code "Normal[SparseArray[{{1, 2} -> a, {2, 3} -> b}, {2, 3}]]"
tungsten-cpp expr evaluate --code "ArrayRules[SparseArray[{{1, 2} -> a}, {2, 3}]]"
```

The bounded native evaluator covers a broad subset of the following compatibility inventory.
Unsupported heads and unsupported forms remain symbolic; the differential status in
[cpp-port.md](./cpp-port.md) and the detailed caveats in
[expression-function-support.md](./expression-function-support.md) are authoritative for C++ edge
coverage:

- `Length`
- `Depth`
- `Head`
- `Dimensions`
- `ArrayRules`
- symbol and context registry heads such as `Symbol`, `SymbolName`, `Unique`, `Names`, `NameQ`,
  `Contexts`, `Context`, `$Context`, `$ContextPath`, `Attributes`, `SetAttributes`,
  `ClearAttributes`, `Protect`, `Unprotect`, `Set`, `SetDelayed`, `TagSet`, `TagSetDelayed`,
  `Unset`, `TagUnset`, `Clear`, `ClearAll`, `OwnValues`, `DownValues`, `UpValues`, `SubValues`,
  and `ValueQ`
- explicit-number arithmetic via `Rational`, `Complex`, `Plus`, `Times`, `Power`, `N`,
  `Precision`, `Accuracy`, `SetPrecision`, and `SetAccuracy` when all relevant arguments in the
  evaluated subexpression are explicit Tungsten numbers
- numeric relational heads such as `Equal`, `Unequal`, `Less`, `LessEqual`, `Greater`, and
  `GreaterEqual` over explicit numbers, with order comparisons limited to real-valued numbers
- simple predicate heads such as `AtomQ`, `IntegerQ`, `NumberQ`, `ExactNumberQ`,
  `InexactNumberQ`, `RealValuedNumberQ`, `MachineNumberQ`, `StringQ`, `SparseArrayQ`, `EvenQ`,
  `OddQ`, and `TrueQ`
- hold-like conditionals such as `If`, `Which`, `Switch`, and `Piecewise`
- bounded numeric heads such as `UnitStep`, `Unitize`, `Sign`, `Abs`, `Re`, `Im`, `Conjugate`,
  `RealSign`, `RealAbs`, `Mod`, `Quotient`, `QuotientRemainder`, `Min`, `Max`, `Clip`,
  `KroneckerDelta`, `DiscreteDelta`, and `Ramp`
- Boolean heads `Not`, `And`, and `Or` when all arguments in the evaluated subexpression are
  explicit `True`/`False`
- `MatchQ`
- `FreeQ`
- `Cases`
- `DeleteCases`
- `Replace`
- `ReplaceAll`
- `ReplaceRepeated`
- positional pure-function applications via `Function[body]` or `body &`
- named pure-function applications via `Function[x, body]`, `Function[{x, y}, body]`,
  `x |-> body`, and `x \[Function] body`
- structural function combinators such as `Identity`, `SameQ`, `UnsameQ`, `SameAs`,
  `Construct`, `Composition`, `RightComposition`, `ComposeList`, `Nest`, `NestList`,
  `NestWhile`, `NestWhileList`, `FixedPoint`, `FixedPointList`, `Operate`, `Comap`, and
  `ComapApply`
- higher-order structural traversal heads such as `Scan`, `MapApply`, `MapAll`, `MapIndexed`,
  `Through`, `MapThread`, `Thread`, `Distribute`, `Outer`, `Inner`, `Dot`, `Cross`, `Tr`,
  `Transpose`, `Det`, `Inverse`, and integer `MatrixPower`, including sparse-preserving paths
  where a zero-fill sparse representation still matches the result
- array, matrix, and sequence-construction heads such as `Tuples`, `Array`, `ConstantArray`,
  `ArrayDepth`, `ArrayQ`, `ArrayFlatten`, `ArrayPad`, `ArrayReshape`, `Range`, `UnitVector`,
  `IdentityMatrix`, `DiagonalMatrix`, `LeviCivitaTensor`, `SparseArray`, `Partition`, `BlockMap`,
  `TakeList`, and `TakeDrop`
- fold, search, and de-duplication heads such as `Fold`, `FoldList`, `FoldWhile`,
  `FoldWhileList`, `FoldPair`, `FoldPairList`, `SequenceFold`, `SequenceFoldList`,
  `LengthWhile`, `FirstCase`, `Position`, `MemberQ`, `DeleteDuplicates`,
  `DeleteDuplicatesBy`, `DeleteAdjacentDuplicates`, `Split`, `SplitBy`, `Subsequences`, and
  `DuplicateFreeQ`
- ordering and by-key selection heads such as `Order`, `OrderedQ`, `Ordering`, `OrderingBy`,
  `Sort`, `SortBy`, `ReverseSort`, `ReverseSortBy`, `MinimalBy`, `MaximalBy`,
  `LexicographicOrder`, `LexicographicSort`, `AlphabeticSort`, `NumericalSort`, and
  `RandomSample`
- byte and character heads such as `ByteArray`, `ByteArrayQ`, `BaseEncode`, `BaseDecode`,
  `Characters`, `StringLength`, `StringTake`, `StringDrop`, `StringJoin`, `StringInsert`,
  `StringReverse`, `StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`,
  `StringPosition`, `StringContainsQ`, `StringCases`, `StringReplace`, `ToCharacterCode`,
  `FromCharacterCode`, `StringToByteArray`, `ByteArrayToString`, `ImportString`, `ExportString`,
  `ImportByteArray`, `ExportByteArray`, `ToString`, `ToExpression`, `ToBoxes`, `MakeBoxes`,
  `MakeExpression`, `StripBoxes`, `SyntaxQ`, `SyntaxLength`, `TraditionalForm`, `TeXForm`,
  `MathMLForm`, `OutputForm`, `TextForm`, `CForm`, `FortranForm`, `NumberForm`, `ScientificForm`,
  `EngineeringForm`, `AccountingForm`, `PaddedForm`, `PercentForm`, `BaseForm`, `TableForm`, `MatrixForm`,
  `TreeForm`, `DisplayForm`, `StringForm`, and `SequenceForm`
- `Pick`
- `First`
- `Last`
- `Rest`
- `Most`
- `Select`
- `Discard`
- `SelectFirst`
- `TakeWhile`
- `Normal`
- `Part`
- `Extract`
- `Level`
- `Take`
- `Drop`
- `Append`
- `Prepend`
- `Join`
- `Reverse`
- `RotateLeft`
- `RotateRight`
- `Flatten`
- `Delete`
- `ReplaceAt`
- `ReplacePart`
- `Apply`
- `Map`
- `MapAt`

For the exact supported forms and limits of each function, see
[expression-function-support.md](./expression-function-support.md).

Everything else remains inert.

The current pattern subset includes `_`, `_Head`, anonymous and named `__`, `___`, head-qualified
sequence forms such as `__Integer` and `x___Symbol`, named `x_`, `x_Head`, pattern tests via `?`,
optional arguments via `patt:def` and `_.`, guarded patterns via `/;`, `Alternatives` via `|`,
`Except`, `HoldPattern`, `Verbatim`, `Repeated`, `RepeatedNull`, `PatternSequence`,
`OrderlessPatternSequence`, `Longest`, `Shortest`, `OptionsPattern`, and `KeyValuePattern`. The
parser also lowers `expr /. rules` and `expr //. rules` to `ReplaceAll[expr, rules]` and
`ReplaceRepeated[expr, rules]`.
`__` and `___` match a single candidate expression directly, and they also support multi-element
matching with multiple occurrences in a containing argument list. The allocation rule is documented
in [sequence-pattern-matching.md](./sequence-pattern-matching.md).
Guards via `/;` are supported in patterns and delayed-rule right-hand sides when the substituted
guard reduces to explicit `True` under Tungsten's shipped evaluator. The structural matcher
consults registry attributes for ordinary `Flat`, `Orderless`, and `OneIdentity` expression
matching. It still does not implement user-defined `Default[...]` values for omitted
`Optional[patt]` arguments or `OptionValue` lookup for `OptionsPattern`.

The current string-pattern subset includes literal strings, `StringExpression` / `~~`, `_`, `__`,
`___`, `Repeated` / `..`, `RepeatedNull` / `...`, named string captures including `x : __`,
`Alternatives`, `Condition`, `PatternTest`, `Shortest`, `Longest`, `Except` over supported
one-character patterns, `CharacterRange`, `RegularExpression`, a practical `DatePattern` subset,
`NumberString`, `Whitespace`, common character classes such as `DigitCharacter`,
`HexadecimalCharacter`, `LetterCharacter`, `PunctuationCharacter`, `WhitespaceCharacter`, and
`WordCharacter`, and anchors such as `StartOfString`, `EndOfString`, `StartOfLine`, `EndOfLine`,
and `WordBoundary`. Tungsten uses the C++ standard regular-expression library and a bounded native
character-class implementation here, so exact PCRE-version and Unicode-version parity with the
Wolfram kernel is not promised.

Pure functions support positional slots plus named parameters: `#`, `#n`, `#0`, `##`, `##n`,
`Slot[]`, `Slot[n]`, `SlotSequence[]`, `SlotSequence[n]`, `Function[body]`, `body &`,
`Function[Null, body]`, `Function[Null, body, attrs]`, `Function[x, body]`,
`Function[{x, y}, body]`, `Function[params, body, attrs]`, `x |-> body`,
`x \[Function] body`, and Wolfram's `#name` first-argument association/key shorthand.
Tungsten keeps function bodies inert until application, which lets pure functions safely contain
patterns such as `MatchQ[#, _Integer] &`. Third-argument attributes currently honored by
pure-function application are `HoldFirst`, `HoldRest`, `HoldAll`, `HoldAllComplete`,
`SequenceHold`, and `Listable`; symbol-level attributes such as `Flat`, `Orderless`, and
`OneIdentity` are honored when they are attached to the head that is actually being evaluated or
matched.
Nested named pure functions use capture-avoiding renaming when an outer application modifies the
inner body. The exact rule is documented in
[named-pure-functions-spec.md](./named-pure-functions-spec.md).

Arithmetic, relational, and Boolean heads are still bounded to Tungsten's supported explicit-value
rules, but syntax and evaluation are now separated the same way Wolfram exposes them. The parser
normalizes unparenthesized `+` / `*` chains, right-associative powers, and chained comparisons even
inside `Hold`; for example `Hold[a + b + c]` parses as `Hold[Plus[a, b, c]]`, `Hold[a^b^c]` parses
as `Hold[Power[a, Power[b, c]]]`, and `Hold[a < b <= c]` parses as
`Hold[Inequality[a, Less, b, LessEqual, c]]`. Later evaluation runs through the registry-backed
attribute pipeline, so `Flat`, `Orderless`, `Listable`, and held Boolean argument behavior affect
supported calls before the direct built-in evaluator runs.

The new selection family follows the same explicit-`True` rule as Wolfram's own docs: `Select`,
`Discard`, `SelectFirst`, and `TakeWhile` treat their criterion as a callable predicate, not as a
pattern shorthand. Use a pure function such as `MatchQ[#, _Integer] &` when you want
pattern-based selection. `Select`, `Discard`, and `SelectFirst` currently support the
`"Element"` and `"Index"` property forms, plus lists composed from those two properties.

The newer conditional heads are also deliberately narrow and structural: `If`, `Which`, `Switch`,
and `Piecewise` honor the main branch-selection behavior from the Wolfram Language, but Tungsten
does not attempt to emulate every procedural side effect or message path. `Pick` currently
supports selector expressions with compatible structural shapes and is strongest on the ordinary
list/head-preserving and association-by-position cases.

On syntax failure, `expr evaluate` writes structured JSON to stdout and returns exit code `1` with
`success: false`, `error_type: "WolframSyntaxError"`, and `error`. Unsupported evaluator heads are
normally successful inert results rather than process failures. Native diagnostics and `Print`
effects are reported in the `messages` and `prints` arrays.

### `parser-corpus`

Purpose:

- discover parser-corpus files under `C:\TestData\wolfram\tungsten-wolfram-parser-corpus`;
- parse selected files with Tungsten;
- compare parse acceptance with the local Wolfram kernel without evaluating corpus code.

The Wolfram side imports each file as text and calls
`ToExpression[text, InputForm, HoldComplete]`. The held expression is not released.

#### `parser-corpus discover`

Examples:

```powershell
tungsten-cpp parser-corpus discover --sample 30
tungsten-cpp parser-corpus discover --include-glob "github/woxi/**" --extension wls
```

Important options:

- `--corpus-root <path>`: defaults to `C:\TestData\wolfram\tungsten-wolfram-parser-corpus`
- `--extension <ext>`: repeatable extension filter
- `--include-glob <glob>` / `--exclude-glob <glob>`: repeatable relative path filters
- `--max-files <n>`: cap selected files
- `--shuffle --seed <n>`: deterministic shuffled selection before applying `--max-files`
- `--sample <n>`: include this many selected file records in stdout JSON

#### `parser-corpus compare`

Examples:

```powershell
tungsten-cpp parser-corpus compare --max-files 100 --max-file-mb 2
tungsten-cpp parser-corpus compare --skip-wolfram --no-write --include-results
tungsten-cpp parser-corpus compare --include-glob "github/wolframresearch-codeparser/**" --extension wl
```

Important options:

- `--out-dir <path>`: output directory for summary, JSONL results, and Markdown report
- `--max-file-mb <n>` / `--max-bytes <n>` / `--no-max-bytes`: large-file behavior
- `--form input|fullform|standard`: Tungsten expression form for non-notebook source files
- `--skip-wolfram`: run only the Tungsten side
- `--kernel-batch-size <n>`: number of files per Wolfram kernel batch; defaults to `100`
- `--tungsten-workers <n>`: local worker threads for Tungsten-side parsing
- `--preview-chars <n>`: maximum preview text stored per attempt
- `--no-write`: stdout-only summary
- `--include-results`: include per-file results in stdout JSON
- `--fail-on-tungsten-gap`: return exit code `1` if Wolfram accepts a file Tungsten rejects
- `--fail-on-mismatch`: return exit code `1` for either `tungsten_gap` or
  `tungsten_only_success`

Negative worker, batch, preview, maximum-file, and sample values may be normalized to the value the
native command actually uses when written back to summary JSON, rather than preserving the raw
negative spelling. Valid non-negative invocations match the Python command contract.

Default output files are written under the corpus `validation` directory:

- `parser-corpus-summary.json`
- `parser-corpus-results.jsonl`
- `parser-corpus-report.md`

For details, see [parser-corpus.md](./parser-corpus.md).

### `docs`

Purpose:

- build, search, read, and open the local Wolfram documentation index.

#### `docs index`

Build or rebuild the local documentation index.

```powershell
tungsten-cpp docs index
tungsten-cpp docs index --path C:\Temp\tungsten-docs.sqlite3
```

#### `docs search`

Search the index.

Options:

- positional query
- `--limit <n>`: defaults to `10`
- `--index-path <path>`: optional
- `--rebuild`: force index rebuild before search

Examples:

```powershell
tungsten-cpp docs search NotebookGet
tungsten-cpp docs search NotebookImport --limit 5
```

#### `docs read`

Read a documentation page by title, paclet identifier, or path.

```powershell
tungsten-cpp docs read NotebookGet
tungsten-cpp docs read paclet:ref/NotebookGet
```

#### `docs open`

Open a documentation page in the FrontEnd.

```powershell
tungsten-cpp docs open paclet:ref/NotebookGet
```

### `frontend`

Purpose:

- run a small set of FrontEnd-oriented actions through the kernel runner.

#### `frontend probe`

```powershell
tungsten-cpp frontend probe
```

#### `frontend open-notebook`

```powershell
tungsten-cpp frontend open-notebook --file C:\Temp\new.nb
```

#### `frontend open-doc`

```powershell
tungsten-cpp frontend open-doc paclet:ref/NotebookGet
```

#### `frontend run`

```powershell
tungsten-cpp frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
tungsten-cpp frontend run --code "SomeCode[]" --no-wrap
```

#### `frontend token`

```powershell
tungsten-cpp frontend token OpenCloseGroup --file C:\Temp\new.nb
```

Common FE options:

- `--require-success` on probe/open/run/token variants
- `--no-wrap` on `frontend run`

### `assistant`

Purpose:

- drive the built-in Notebook Assistant against a selected source cell.

#### Shared selector options

These selector forms are mutually exclusive and are reused across assistant commands:

- `--cell-index <n>`
- `--cell-path <json-or-comma-separated-int-list>`
- `--expression-uuid <uuid>`
- `--cell-id <int>`
- `--cell-tag <tag>`

#### `assistant ask-cell`

Recommended assistant workflow.

Options:

- `--file <path>`: required
- one selector option: required
- `--question <text>`: required
- `--insert-wolfram-code-below`
- `--insert-all-wolfram-code-below`
- `--save`
- `--close-assistant-notebook`: close the generated hidden chat notebook; when omitted, it
  remains open and `assistant.assistant_notebook_closed` is `false`
- `--extra-instructions <text>`
- `--model-service <name>`
- `--model-name <name>`
- `--require-success`

Examples:

```powershell
tungsten-cpp assistant ask-cell `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --question "Explain this cell."

tungsten-cpp assistant ask-cell `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --question "Reply only with Wolfram Language code that computes 2+2." `
    --insert-wolfram-code-below `
    --save
```

Important output fields:

- `assistant_success`
- `assistant.response_text`
- `assistant.code_blocks`
- `assistant.wolfram_code_blocks`
- `assistant.inserted`
- `assistant.saved_notebook`

#### `assistant prepare-inline`

Experimental visible inline-assistant setup helper.

```powershell
tungsten-cpp assistant prepare-inline --file C:\Temp\new.nb --cell-index 1
```

#### `assistant capture-inline`

Experimental visible inline-assistant capture helper.

```powershell
tungsten-cpp assistant capture-inline `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --insert-wolfram-code-below `
    --save
```

For real automation, prefer `assistant ask-cell`.

## PowerShell module

Import the module:

```powershell
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
```

### Environment and kernel

```powershell
Get-TungstenEnvironment -Probe
Invoke-TungstenKernel -Code "2+2"
Invoke-TungstenKernel -File C:\path\to\script.wl -FrontEnd
```

### Notebook operations

```powershell
Get-TungstenNotebook -Path C:\Temp\demo.nb
New-TungstenNotebook -Path C:\Temp\demo.nb -Title "Demo" -Cell "Text:Hello" -Cell "Input:2+2"
Set-TungstenNotebook -Path C:\Temp\demo.nb -Spec C:\Temp\patch.json
```

### Expression parsing and inert evaluation

```powershell
Convert-TungstenExpression -Code "1 + 2 x^3"
Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
```

### Parser corpus

```powershell
Get-TungstenParserCorpus -Sample 30
Compare-TungstenParserCorpus -MaxFiles 100 -MaxFileMB 2 -KernelBatchSize 100 -TungstenWorkers 8
Compare-TungstenParserCorpus -SkipWolfram -NoWrite -IncludeResults
```

### Inline-box strings

```powershell
New-TungstenInlineBoxString -Prefix "icon: " -BoxExpression "GraphicsBox[{CircleBox[]}]"
Get-TungstenNotebookCellInlineBoxes -Path C:\Temp\demo.nb -ExpressionUuid "uuid-inline-box" -Prefix "icon: "
```

### Documentation and FrontEnd

```powershell
Find-TungstenDocumentation -Query "NotebookImport"
Get-TungstenDocumentationPage -Identifier "paclet:ref/NotebookGet"
Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet"
Open-TungstenNotebook -Path C:\Temp\demo.nb
Invoke-TungstenFrontEnd -Code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
```

### Notebook Assistant

```powershell
Invoke-TungstenNotebookAssistant -Path C:\Temp\demo.nb -CellIndex 1 -Question "Explain this cell."
Invoke-TungstenNotebookAssistant `
    -Path C:\Temp\demo.nb `
    -CellIndex 1 `
    -Question "Reply only with Wolfram Language code that computes 2+2." `
    -InsertWolframCodeBelow `
    -Save
```

Important assistant parameters:

- selector parameters: `-CellIndex`, `-CellPath`, `-ExpressionUuid`, `-CellId`, `-CellTag`
- insertion controls: `-InsertWolframCodeBelow`, `-InsertAllWolframCodeBelow`
- persistence: `-Save`
- backend: `-Backend NotebookChatCell|DesktopInline|KernelWindow`

`NotebookChatCell` is the recommended default backend.

## Build and validation entrypoints

```powershell
Push-Location .\Engine
cmake -S . -B build/cpp -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release
ctest --test-dir build/cpp -C Release --output-on-failure
uv run python scripts/check_cpp_parser_parity.py
uv run python scripts/check_cpp_evaluator_parity.py --tests tests
uv run python scripts/check_cpp_stateful_evaluator_parity.py --require-perfect
uv run python scripts/check_cpp_recorded_evaluator_parity.py --workers 8 --require-perfect
uv run python scripts/check_cpp_cli_parity.py
dotnet test .\dotnet\Tungsten.DotNet.slnx
Pop-Location
```

The parser differential is exact over 1,414 extracted literals, the stateful evaluator gate is
82/82, the recorded evaluator gate is 2,499/2,499 calls across 585 tests, and the CLI differential
is 119/119. The standalone evaluator extractor remains a setup-losing diagnostic; the recorded
evaluator harness with `--require-perfect` is the authoritative broad comparison. See
[C++ Runtime and Verification](./cpp-port.md) for the current record.

For a PowerShell projection smoke, point the module at the built executable before importing it:

```powershell
$env:TUNGSTEN_EXECUTABLE = (Resolve-Path .\Engine\build\cpp\tungsten-cpp.exe)
Import-Module .\Engine\pwsh\Tungsten.psd1 -Force
Invoke-TungstenExpression -Code "ReplacePart[f[a, b, c], 2 -> x]"
```

Use the `Release` subdirectory in the override for a Visual Studio multi-configuration build.
Live kernel, FrontEnd, assistant, and WinDesk validation additionally requires the corresponding
Windows Wolfram/desktop environment and should be run serially. The kernel-free CTest and parity
commands do not establish live Wolfram or Windows validation.

The native test set covers the kernel-free and missing-runtime paths for:

- environment probing;
- kernel execution;
- inline-box string composition and notebook-cell extraction;
- expression parsing/evaluation;
- documentation search;
- notebook creation/inspection;
- assistant request construction and failure handling;
- FrontEnd request construction and failure handling;
- WinDesk request construction and failure handling.

Successful live assistant, FrontEnd, kernel, or WinDesk operation still requires a separate test in
the corresponding Windows Wolfram/desktop environment.
