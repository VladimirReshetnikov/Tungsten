# Tungsten Import/Export String and ByteArray Support

- Status: Informational and reference-oriented (kernel-free import/export string and byte-array format support)
- Audience: Tungsten users, automation authors, maintainers, and anyone relying on offline data interchange
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-24T20:05:00Z
- Updated (UTC): 2026-04-24T20:06:49Z
- Repository HEAD: 110bbc4bc5b6ce3af5afd0e8cabbfef42d15a55e
- Related docs:
  - [Expression Parser](./expression-parser.md)
  - [Expression Function Support](./expression-function-support.md)
  - [Usage Reference](./usage-reference.md)

## Purpose

Tungsten now implements a practical kernel-free subset of Wolfram's string and byte-array import /
export surface:

- `ImportString`
- `ExportString`
- `ImportByteArray`
- `ExportByteArray`

The goal is not to reproduce every Wolfram format. The goal is to make the common, genuinely
useful formats work offline in a way that is predictable, scriptable, and easy to compose with
Tungsten's existing expression evaluator.

The subset below was chosen from the live `$ImportFormats` / `$ExportFormats` surface and the
official Wolfram docs, with a bias toward formats that are:

- broadly used rather than niche;
- straightforward to implement faithfully enough in Python; and
- useful inside Tungsten's symbolic AST model.

## Supported format specifications

### Direct formats

- `"Byte"`
  Official format: [Byte](https://reference.wolfram.com/language/ref/format/Byte.html)
- `"String"`
  Official format: [String](https://reference.wolfram.com/language/ref/format/String.html)
- `"Text"`
  Official format: [Text](https://reference.wolfram.com/language/ref/format/Text.html)
- `"WL"`
  Wolfram Language textual form
- `"JSON"`
  Official format: [JSON](https://reference.wolfram.com/language/ref/format/JSON.html)
- `"RawJSON"`
  Official format: [RawJSON](https://reference.wolfram.com/language/ref/format/RawJSON.html)
- `"CSV"`
  Official format: [CSV](https://reference.wolfram.com/language/ref/format/CSV.html)
- `"TSV"`
  Official format: [TSV](https://reference.wolfram.com/language/ref/format/TSV.html)
- `"Table"`
  Official format: [Table](https://reference.wolfram.com/language/ref/format/Table.html)

### Compression-wrapper formats

- `{"GZIP", innerFormat}`
  Official format: [GZIP](https://reference.wolfram.com/language/ref/format/GZIP.html)
- `{"BZIP2", innerFormat}`
  Official format: [BZIP2](https://reference.wolfram.com/language/ref/format/BZIP2.html)

These wrappers are supported around any Tungsten-supported direct format above.

Examples:

```wl
ExportByteArray[{{1, 2}, {3, 4}}, {"GZIP", "CSV"}]
ImportByteArray[ba, {"BZIP2", "RawJSON"}]
ExportString["hello", {"GZIP", "String"}]
```

## Data-shape rules

### `"Byte"`

- `ImportString[..., "Byte"]` returns a `List` of integers in the range `0..255`, interpreting
  each raw character code as one byte.
- `ExportString[..., "Byte"]` expects a byte list or `ByteArray` and returns a raw string whose
  character codes are the exported bytes.
- `ImportByteArray[..., "Byte"]` returns a `List` of integers.
- `ExportByteArray[..., "Byte"]` expects a byte list or `ByteArray`.

### `"String"`

- `"String"` is the raw-byte-string view.
- `ImportByteArray[..., "String"]` maps each byte directly to `FromCharacterCode[byte]`.
- `ExportByteArray[..., "String"]` maps each character code `0..255` directly to one byte.
- For `ExportString[..., "String"]`, explicit Tungsten strings are emitted as-is; other
  expressions are rendered textually first.

### `"Text"`

- `ImportString[..., "Text"]` returns the input string unchanged.
- `ImportByteArray[..., "Text"]` decodes bytes as UTF-8 using Tungsten's existing practical
  fallback behavior for invalid UTF-8.
- `ExportString[..., "Text"]` returns explicit strings unchanged; other expressions are rendered in
  canonical `InputForm`.
- `ExportByteArray[..., "Text"]` UTF-8-encodes the corresponding exported text string.

### `"WL"`

- `ExportString[..., "WL"]` returns Tungsten's canonical `InputForm`.
- `ImportString[..., "WL"]` parses Tungsten's supported `InputForm` subset.
- The byte-array forms use UTF-8 around the same textual representation.

### `"JSON"` versus `"RawJSON"`

- `"JSON"` imports JSON objects as lists of rules.
- `"RawJSON"` imports JSON objects as associations.
- `"JSON"` export accepts both rule-list objects and associations, matching practical Wolfram
  behavior.
- `"RawJSON"` export expects associations for JSON objects and deliberately rejects rule-list
  objects.

Imported scalars map as follows:

- JSON strings -> Tungsten strings
- JSON integers -> Tungsten integers
- JSON non-integer numbers -> Tungsten reals
- JSON booleans -> `True` / `False`
- JSON null -> `Null`
- JSON arrays -> `List[...]`

### `"CSV"`, `"TSV"`, and `"Table"`

- Import returns a `List` of row lists.
- Integer-looking fields import as integers.
- Common real-number forms import as reals, including exponent notation.
- Other fields import as strings.
- Export accepts either:
  - a flat list, treated as a single column; or
  - a list of row lists.

The current default separators follow practical Wolfram behavior:

- `"CSV"`: comma-separated rows with a trailing newline
- `"TSV"`: tab-separated rows with a trailing newline
- `"Table"`: tab-separated columns, newline-separated rows, no trailing newline

## Current limits

- Tungsten currently supports only the explicit two-argument forms of `ImportString`,
  `ExportString`, `ImportByteArray`, and `ExportByteArray`.
- Auto-detection forms such as `ImportString[data]` and `ImportByteArray[ba]` are not implemented
  in this pass.
- General element specifications are not implemented in this pass; the only list-based format specs
  currently supported are compression wrappers such as `{"GZIP", "CSV"}`.
- `"GZIP"` and `"BZIP2"` are currently supported only as explicit wrappers around an inner format.
- The tabular import/export surface is the practical direct-data subset, not the full Wolfram
  option space for delimiters, quoting policies, currency tokens, or custom number formats.
- `"String"` raw-byte export currently expects character codes in the range `0..255`.
- The current subset intentionally stops short of broader or more specialized formats such as ZIP
  archives, ZSTD, XML-family symbolic import, Parquet, XLSX, WXF, and the many domain-specific
  scientific or media formats in `$ImportFormats` / `$ExportFormats`.

## Examples

```wl
ImportString["{\"a\":1,\"b\":[2,3]}", "JSON"]
ImportString["{\"a\":1,\"b\":[2,3]}", "RawJSON"]
ImportString["1,2\n3,4\n", "CSV"]
ImportString["1 2\n3 4\n", "Table"]
ImportString["f[a, 1]", "WL"]

ExportString[{97, 98, 99}, "Byte"]
ExportString[<|"a" -> 1|>, "RawJSON"]
ExportString[{{1, 2}, {3, 4}}, "CSV"]
ExportString[{1, 2, 3}, "TSV"]
ExportString[f[a, 1], "WL"]

ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {"GZIP", "CSV"}], {"GZIP", "CSV"}]
ImportByteArray[ExportByteArray[<|"a" -> 1|>, {"BZIP2", "RawJSON"}], {"BZIP2", "RawJSON"}]
```

## References

- [ImportString](https://reference.wolfram.com/language/ref/ImportString.html)
- [ExportString](https://reference.wolfram.com/language/ref/ExportString.html)
- [ImportByteArray](https://reference.wolfram.com/language/ref/ImportByteArray.html)
- [ExportByteArray](https://reference.wolfram.com/language/ref/ExportByteArray.html)
- [Importing and Exporting](https://reference.wolfram.com/language/guide/ImportingAndExporting.html)
- [$ImportFormats](https://reference.wolfram.com/language/ref/$ImportFormats.html)
- [$ExportFormats](https://reference.wolfram.com/language/ref/$ExportFormats.html)
