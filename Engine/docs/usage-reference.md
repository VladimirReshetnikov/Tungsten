# Tungsten Usage Reference

- Status: Informational and reference-oriented (command surface and payload reference)
- Audience: Tungsten users, automation authors, maintainers, reviewers, and anyone scripting the CLI or PowerShell wrappers
- Scope: Tungsten command-line and PowerShell surfaces
- Created (UTC): 2026-04-23T02:16:55Z
- Updated (UTC): 2026-04-25T21:57:56Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a
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

- The Python CLI is JSON-first. Every command returns structured JSON.
- The PowerShell module is a thin wrapper over `python -m tungsten ...`; it returns deserialized
  PowerShell objects based on those JSON payloads.
- The .NET client in [dotnet-api.md](./dotnet-api.md) is a typed wrapper over the same JSON
  command surface documented here.
- Kernel-backed commands depend on a real local Wolfram installation.
- Kernel-free commands such as notebook file inspection and expression parsing do not require a
  running kernel.

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

## Python CLI

Set the local source directory on `PYTHONPATH`:

```powershell
$env:PYTHONPATH = (Resolve-Path .\src\Tungsten\src)
```

### `repl`

Purpose:

- start the kernel-free Tungsten interpreter with `wolfram.exe`-style prompts;
- maintain session history through `$Line`, `In`, `InString`, `Out`, `DownValues`, and `%`
  shorthand;
- exit through `Exit`, `Exit[code]`, `Quit`, or `Quit[code]`.

Examples:

```powershell
python -m tungsten repl
python -m tungsten repl --no-banner
python -m tungsten
python -m pip install -e .\src\Tungsten
tungsten.exe
dotnet build .\src\Tungsten\dotnet\Tungsten.DotNet.slnx
.\src\Tungsten\dotnet\Tungsten.Console\bin\Debug\net10.0\tungsten.exe
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
python -m tungsten env show
python -m tungsten env show --probe
```

Important output fields:

- `install_dir`
- `kernel_cli`
- `kernel_executable`
- `frontend_executable`
- `wolframscript`
- `mathpass`
- `docs_roots`
- `bundled_python_client`
- `default_index_path`
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
python -m tungsten kernel eval --code "2+2"
python -m tungsten kernel eval --code "Print[Prime[10]]; Prime[20]"
python -m tungsten kernel eval --code "NotebookLocate[\"paclet:ref/NotebookGet\"]" --front-end
python -m tungsten kernel eval --file C:\path\to\script.wl
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
python -m tungsten notebook inspect --file C:\path\to\notebook.nb
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
python -m tungsten notebook create `
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
python -m tungsten notebook patch --file C:\Temp\new.nb --spec C:\Temp\patch.json
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
python -m tungsten inline-box compose `
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
python -m tungsten inline-box from-cell `
    --file C:\Temp\demo.nb `
    --expression-uuid uuid-inline-box `
    --prefix "icon: "

python -m tungsten inline-box from-cell `
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
python -m tungsten expr parse --code "1 + 2 x^3"
python -m tungsten expr parse --code "Rule[x, List[1, 2]]" --form fullform
python -m tungsten expr parse --code "f @ x // g" --form standard
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
python -m tungsten expr evaluate --code "Length[{a, b, c}]"
python -m tungsten expr evaluate --code "1 + 2 + 3"
python -m tungsten expr evaluate --code "True && False && x"
python -m tungsten expr evaluate --code '$ContextPath'
python -m tungsten expr evaluate --code 'Context[System`Plus]'
python -m tungsten expr evaluate --code '{Symbol["TungstenUsage`alpha"], Names["TungstenUsage`*"]}'
python -m tungsten expr evaluate --code 'Length[Names["System`*"]]'
python -m tungsten expr evaluate --code 'NameQ["System`AASTriangle"]'
python -m tungsten expr evaluate --code 'Attributes[Plus]'
python -m tungsten expr evaluate --code 'x = 1 + 2; {ValueQ[x], OwnValues[x], x}'
python -m tungsten expr evaluate --code 'x = 1; Clear[x]; ValueQ[x]'
python -m tungsten expr evaluate --code "Level[f[a, g[b]], -1]"
python -m tungsten expr evaluate --code "Part[f[a, b, c], {1, 3}]"
python -m tungsten expr evaluate --code "Extract[f[a, g[b]], {{1}, {2, 1}}]"
python -m tungsten expr evaluate --code "MatchQ[f[a, a], f[x_, x_]]"
python -m tungsten expr evaluate --code "MatchQ[f[2], f[x_ /; x > 0]]"
python -m tungsten expr evaluate --code "FreeQ[f[a], f]"
python -m tungsten expr evaluate --code "Cases[{f[a], f[b]}, f[x_] :> x]"
python -m tungsten expr evaluate --code "Cases[{1, -2, 3}, x_ :> x + 1 /; x > 0]"
python -m tungsten expr evaluate --code "DeleteCases[f[a, g[a]], a, Infinity]"
python -m tungsten expr evaluate --code "Replace[f[g[a]], x_ :> p[x], {0, Infinity}]"
python -m tungsten expr evaluate --code "Replace[1, {x_ :> x + 1 /; x < 0, x_ :> x + 2}]"
python -m tungsten expr evaluate --code "If[1 < 2, 1 + 2, 9]"
python -m tungsten expr evaluate --code "Which[False, a, True, 1 + 2]"
python -m tungsten expr evaluate --code "Switch[a, _Integer, 1, _Symbol, 2]"
python -m tungsten expr evaluate --code "Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"
python -m tungsten expr evaluate --code "Pick[f[a, b, c, d], {False, True, False, True}]"
python -m tungsten expr evaluate --code "Select[f[1, a, 2, 3], IntegerQ]"
python -m tungsten expr evaluate --code "Select[{1, a, 2, 3}, # > 1 & -> {\"Element\", \"Index\"}]"
python -m tungsten expr evaluate --code "Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"
python -m tungsten expr evaluate --code "SelectFirst[{1, a, 2, 3}, # > 1 &]"
python -m tungsten expr evaluate --code "TakeWhile[f[2, 4, 6, 7, 8], EvenQ]"
python -m tungsten expr evaluate --code "Mod[-14, 5]"
python -m tungsten expr evaluate --code "Clip[-7, {-5, 5}, {100, 200}]"
python -m tungsten expr evaluate --code "KroneckerDelta[3, 3, 3]"
python -m tungsten expr evaluate --code "f[g[a]] /. g[x_] :> x"
python -m tungsten expr evaluate --code "f[a] //. f[x_] :> x"
python -m tungsten expr evaluate --code "Map[# + 1 &, {a, b}]"
python -m tungsten expr evaluate --code "(f[##2] &)[a, b, c]"
python -m tungsten expr evaluate --code "Function[Null, HoldComplete[#], HoldAll][1 + 2]"
python -m tungsten expr evaluate --code "Function[Null, f[#], Listable][{a, b}]"
python -m tungsten expr evaluate --code "ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}]"
python -m tungsten expr evaluate --code "ReplacePart[f[a, b, c], 2 -> x]"
python -m tungsten expr evaluate --code "MapAt[g, f[a, h[b, c], d], {2, 1}]"
python -m tungsten expr evaluate --code "Composition[f, g][x]"
python -m tungsten expr evaluate --code "MapApply[f, {g[a, b], h[c]}]"
python -m tungsten expr evaluate --code "Thread[f[{a, b}, {c, d}]]"
python -m tungsten expr evaluate --code "Fold[f, x, {a, b, c}]"
python -m tungsten expr evaluate --code "BlockMap[f, {a, b, c, d, e}, 2]"
python -m tungsten expr evaluate --code "DeleteDuplicatesBy[{{a}, {b, c}, {d}}, Length]"
python -m tungsten expr evaluate --code "SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]"
python -m tungsten expr evaluate --code "OrderingBy[{{a, 2}, {b, 1}, {c, 3}}, Last, -2]"
python -m tungsten expr evaluate --code "MaximalBy[<|a -> 2, b -> 1, c -> 2|>, Identity]"
python -m tungsten expr evaluate --code "LexicographicSort[{\"ba\", \"aa\", \"ab\"}]"
python -m tungsten expr evaluate --code "StringTake[\"abcdef\", {2, 5, 2}]"
python -m tungsten expr evaluate --code "StringJoin[{\"a\", {\"b\", \"c\"}}]"
python -m tungsten expr evaluate --code "StringMatchQ[\"catalog\", \"c\" ~~ __ ~~ \"g\"]"
python -m tungsten expr evaluate --code "StringCases[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
python -m tungsten expr evaluate --code "StringCases[\"abc123def45\", LetterCharacter.. ~~ DigitCharacter..]"
python -m tungsten expr evaluate --code "StringPosition[\"ababa\", Shortest[\"a\" ~~ ___ ~~ \"a\"]]"
python -m tungsten expr evaluate --code "StringCases[\"on 2026-04-25 ok\", DatePattern[{\"Year\", \"Month\", \"Day\"}]]"
python -m tungsten expr evaluate --code "StringCases[\"abc123\", RegularExpression[\"[a-z]+\"]]"
python -m tungsten expr evaluate --code "StringReplace[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]"
python -m tungsten expr evaluate --code "StringPosition[\"ababa\", \"a\" ~~ __ ~~ \"a\"]"
python -m tungsten expr evaluate --code "ImportString[\"{\\\"a\\\":1,\\\"b\\\":[2,3]}\", \"RawJSON\"]"
python -m tungsten expr evaluate --code "ImportString[ExportString[{{1, 2}, {3, 4}}, \"CSV\"], \"CSV\"]"
python -m tungsten expr evaluate --code "ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {\"GZIP\", \"CSV\"}], {\"GZIP\", \"CSV\"}]"
python -m tungsten expr evaluate --code "ToExpression[ToString[HoldComplete[1 + 2], InputForm], InputForm]"
python -m tungsten expr evaluate --code "ToString[FullForm[{1, 2/3, a + b}]]"
python -m tungsten expr evaluate --code "ToBoxes[InputForm[1 + x]]"
python -m tungsten expr evaluate --code "Print[FullForm[{1, 2/3, a + b}]]"
python -m tungsten expr evaluate --code 'ToExpression["f @ x // g", StandardForm, HoldComplete]'
python -m tungsten expr evaluate --code 'ToExpression[RowBox[{"a", "\[CirclePlus]", "b"}], StandardForm, HoldComplete]'
python -m tungsten expr evaluate --code 'MakeExpression[SubscriptBox["x", "i"], StandardForm]'
python -m tungsten expr evaluate --code 'StripBoxes[RowBox[{"1", " ", StyleBox["+", Red], "2"}]]'
python -m tungsten expr evaluate --code 'SyntaxQ["a \[CirclePlus] b", StandardForm]'
python -m tungsten expr evaluate --code "Select[{\"ab\", \"cd\", \"ba\"}, StringContainsQ[\"a\"]]"
python -m tungsten expr evaluate --code "Normal[ByteArray[\"QUJD\"]]"
python -m tungsten expr evaluate --code "BaseEncode[StringToByteArray[\"abc\"], \"Base16\"]"
python -m tungsten expr evaluate --code "ToCharacterCode[ByteArrayToString[ByteArray[{97, 195, 169}], \"UTF-8\"]]"
```

The implemented inert evaluator currently covers:

- `Length`
- `Depth`
- `Head`
- symbol and context registry heads such as `Symbol`, `SymbolName`, `Unique`, `Names`, `NameQ`,
  `Contexts`, `Context`, `$Context`, `$ContextPath`, `Attributes`, `Set`, `Unset`, `Clear`,
  `OwnValues`, and `ValueQ`
- explicit-number arithmetic via `Rational`, `Complex`, `Plus`, `Times`, `Power`, `N`,
  `Precision`, `Accuracy`, `SetPrecision`, and `SetAccuracy` when all relevant arguments in the
  evaluated subexpression are explicit Tungsten numbers
- numeric relational heads such as `Equal`, `Unequal`, `Less`, `LessEqual`, `Greater`, and
  `GreaterEqual` over explicit numbers, with order comparisons limited to real-valued numbers
- simple predicate heads such as `AtomQ`, `IntegerQ`, `NumberQ`, `ExactNumberQ`,
  `InexactNumberQ`, `RealValuedNumberQ`, `MachineNumberQ`, `StringQ`, `EvenQ`, `OddQ`, and `TrueQ`
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
  `Through`, `MapThread`, `Thread`, `Distribute`, `Outer`, `Inner`, and `Dot`
- array, matrix, and sequence-construction heads such as `Tuples`, `Array`, `ConstantArray`,
  `Range`, `UnitVector`, `IdentityMatrix`, `DiagonalMatrix`, `Partition`, `BlockMap`,
  `TakeList`, and `TakeDrop`
- fold, search, and de-duplication heads such as `Fold`, `FoldList`, `FoldWhile`,
  `FoldWhileList`, `FoldPair`, `FoldPairList`, `SequenceFold`, `SequenceFoldList`,
  `LengthWhile`, `FirstCase`, `Position`, `MemberQ`, `DeleteDuplicates`,
  `DeleteDuplicatesBy`, and `DuplicateFreeQ`
- ordering and by-key selection heads such as `Order`, `OrderedQ`, `Ordering`, `OrderingBy`,
  `Sort`, `SortBy`, `ReverseSort`, `ReverseSortBy`, `MinimalBy`, `MaximalBy`,
  `LexicographicOrder`, and `LexicographicSort`
- byte and character heads such as `ByteArray`, `ByteArrayQ`, `BaseEncode`, `BaseDecode`,
  `Characters`, `StringLength`, `StringTake`, `StringDrop`, `StringJoin`, `StringInsert`,
  `StringReverse`, `StringMatchQ`, `StringFreeQ`, `StringStartsQ`, `StringEndsQ`,
  `StringPosition`, `StringContainsQ`, `StringCases`, `StringReplace`, `ToCharacterCode`,
  `FromCharacterCode`, `StringToByteArray`, `ByteArrayToString`, `ImportString`, `ExportString`,
  `ImportByteArray`, `ExportByteArray`, `ToString`, `ToExpression`, `ToBoxes`, `MakeBoxes`,
  `MakeExpression`, `StripBoxes`, `SyntaxQ`, and `SyntaxLength`
- `Pick`
- `First`
- `Last`
- `Rest`
- `Most`
- `Select`
- `Discard`
- `SelectFirst`
- `TakeWhile`
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
guard reduces to explicit `True` under Tungsten's shipped evaluator. The structural matcher still
does not implement `Flat`, `Orderless`, or `OneIdentity` attribute matching, user-defined
`Default[...]` values for omitted `Optional[patt]` arguments, or `OptionValue` lookup for
`OptionsPattern`.

The current string-pattern subset includes literal strings, `StringExpression` / `~~`, `_`, `__`,
`___`, `Repeated` / `..`, `RepeatedNull` / `...`, named string captures including `x : __`,
`Alternatives`, `Condition`, `PatternTest`, `Shortest`, `Longest`, `Except` over supported
one-character patterns, `CharacterRange`, `RegularExpression`, a practical `DatePattern` subset,
`NumberString`, `Whitespace`, common character classes such as `DigitCharacter`,
`HexadecimalCharacter`, `LetterCharacter`, `PunctuationCharacter`, `WhitespaceCharacter`, and
`WordCharacter`, and anchors such as `StartOfString`, `EndOfString`, `StartOfLine`, `EndOfLine`,
and `WordBoundary`. Tungsten uses Python's regex and Unicode facilities here, so exact PCRE-version
and Unicode-version parity with the Wolfram kernel is not promised.

Pure functions support positional slots plus named parameters: `#`, `#n`, `#0`, `##`, `##n`,
`Slot[]`, `Slot[n]`, `SlotSequence[]`, `SlotSequence[n]`, `Function[body]`, `body &`,
`Function[Null, body]`, `Function[Null, body, attrs]`, `Function[x, body]`,
`Function[{x, y}, body]`, `Function[params, body, attrs]`, `x |-> body`,
`x \[Function] body`, and Wolfram's `#name` first-argument association/key shorthand.
Tungsten keeps function bodies inert until application, which lets pure functions safely contain
patterns such as `MatchQ[#, _Integer] &`. Third-argument attributes currently honored by the
offline evaluator are `HoldFirst`, `HoldRest`, `HoldAll`, `HoldAllComplete`, `SequenceHold`, and
`Listable`.
Nested named pure functions use capture-avoiding renaming when an outer application modifies the
inner body. The exact rule is documented in
[named-pure-functions-spec.md](./named-pure-functions-spec.md).

Arithmetic, relational, and Boolean heads are also intentionally narrow in this pass: Tungsten
does not flatten or reorder `Plus`, `Times`, `And`, `Or`, or the relational heads, and it does
not apply short-circuit behavior. Operator forms still parse to those named heads, so nested
operator syntax can partially simplify one binary layer at a time.

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

On structural evaluation failure, `expr evaluate` still writes structured JSON to stdout and
returns exit code `1` with:

- `success: false`
- `error_type: "WolframEvaluationError"`
- `error`
- `parsed_input_form`
- `parsed_full_form`
- `parsed_tree`

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
python -m tungsten parser-corpus discover --sample 30
python -m tungsten parser-corpus discover --include-glob "github/woxi/**" --extension wls
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
python -m tungsten parser-corpus compare --max-files 100 --max-file-mb 2
python -m tungsten parser-corpus compare --skip-wolfram --no-write --include-results
python -m tungsten parser-corpus compare --include-glob "github/wolframresearch-codeparser/**" --extension wl
```

Important options:

- `--out-dir <path>`: output directory for summary, JSONL results, and Markdown report
- `--max-file-mb <n>` / `--max-bytes <n>` / `--no-max-bytes`: large-file behavior
- `--form input|fullform|standard`: Tungsten expression form for non-notebook source files
- `--skip-wolfram`: run only the Tungsten side
- `--kernel-batch-size <n>`: number of files per Wolfram kernel batch; defaults to `100`
- `--tungsten-workers <n>`: local worker processes for Tungsten-side parsing
- `--preview-chars <n>`: maximum preview text stored per attempt
- `--no-write`: stdout-only summary
- `--include-results`: include per-file results in stdout JSON
- `--fail-on-tungsten-gap`: return exit code `1` if Wolfram accepts a file Tungsten rejects
- `--fail-on-mismatch`: return exit code `1` for either `tungsten_gap` or
  `tungsten_only_success`

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
python -m tungsten docs index
python -m tungsten docs index --path C:\Temp\tungsten-docs.sqlite3
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
python -m tungsten docs search NotebookGet
python -m tungsten docs search NotebookImport --limit 5
```

#### `docs read`

Read a documentation page by title, paclet identifier, or path.

```powershell
python -m tungsten docs read NotebookGet
python -m tungsten docs read paclet:ref/NotebookGet
```

#### `docs open`

Open a documentation page in the FrontEnd.

```powershell
python -m tungsten docs open paclet:ref/NotebookGet
```

### `frontend`

Purpose:

- run a small set of FrontEnd-oriented actions through the kernel runner.

#### `frontend probe`

```powershell
python -m tungsten frontend probe
```

#### `frontend open-notebook`

```powershell
python -m tungsten frontend open-notebook --file C:\Temp\new.nb
```

#### `frontend open-doc`

```powershell
python -m tungsten frontend open-doc paclet:ref/NotebookGet
```

#### `frontend run`

```powershell
python -m tungsten frontend run --code "CreateDocument[Notebook[{Cell[\"Hello\", \"Text\"]}, Visible -> True]]"
python -m tungsten frontend run --code "SomeCode[]" --no-wrap
```

#### `frontend token`

```powershell
python -m tungsten frontend token OpenCloseGroup --file C:\Temp\new.nb
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
- `--close-assistant-notebook`
- `--extra-instructions <text>`
- `--model-service <name>`
- `--model-name <name>`
- `--require-success`

Examples:

```powershell
python -m tungsten assistant ask-cell `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --question "Explain this cell."

python -m tungsten assistant ask-cell `
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
python -m tungsten assistant prepare-inline --file C:\Temp\new.nb --cell-index 1
```

#### `assistant capture-inline`

Experimental visible inline-assistant capture helper.

```powershell
python -m tungsten assistant capture-inline `
    --file C:\Temp\new.nb `
    --cell-index 1 `
    --insert-wolfram-code-below `
    --save
```

For real automation, prefer `assistant ask-cell`.

## PowerShell module

Import the module:

```powershell
Import-Module .\src\Tungsten\pwsh\Tungsten.psd1 -Force
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

## Smoke test entrypoint

```powershell
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -IncludeAssistant
pwsh -File .\src\Tungsten\scripts\Test-TungstenSmoke.ps1 -IncludeFrontEnd -UseWinDesk
pwsh -File .\src\Tungsten\scripts\Test-TungstenParserCorpus.ps1 -MaxFiles 100
```

The smoke now covers:

- environment probing;
- kernel execution;
- inline-box string composition and notebook-cell extraction;
- expression parsing/evaluation;
- documentation search;
- notebook creation/inspection;
- optional assistant integration;
- optional FrontEnd integration;
- optional WinDesk-assisted capture.
