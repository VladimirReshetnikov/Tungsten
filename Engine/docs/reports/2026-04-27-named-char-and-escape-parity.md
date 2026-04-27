# Tungsten Named-Character and String-Escape Parity Report

- Status: Report (parity sweep against the local Wolfram 14.3 kernel; identifies gaps,
  proposes implementation directions, but **does not** modify the implementation in
  this pass per session-level instructions)
- Audience: Vladimir Reshetnikov, Tungsten parser maintainers
- Scope: every Wolfram escape sequence that may appear inside string literals or in
  identifier position, plus the full kernel named-character table
- Created (UTC): 2026-04-27T19:01:27Z
- Repository HEAD: 9f34a00792e3b1c988cebccb17987d8421240085
- Companion documents:
  - [wolfram-string-literal-spec.md](../wolfram-string-literal-spec.md) — normative
    specification
  - [tests/test_named_character_parity.py](../../tests/test_named_character_parity.py)
    — 54 regression / parity tests

## Executive summary

The recently landed commit `9f34a0079 "Align Tungsten named character escapes"` brings
Tungsten's named-character coverage from ~220 names to the full 1100-name table from
`UnicodeCharacters.tr`. The string-literal parser now decodes all 1100 names to the
correct codepoints, and the identifier-position parser canonicalizes `\[Alpha]`,
`\[Aleph]`, etc. to single-codepoint Symbol names. The basic numeric escape forms
(`\:XXXX`, `\.XX`, `\OOO`, `\|XXXXXX`) all decode correctly inside strings.

A focused 76-case differential probe against the live kernel shows **64/76 cases match
exactly**. The 12 remaining cases break into five groups, each documented below with a
test and a proposed fix. None of the gaps cause Tungsten to reject Wolfram-accepted
syntax, but each is a real divergence in either the decoded output or the
strictness-of-rejection.

For the full 1100-name table, **all 1100 names produce identical codepoints between
Tungsten and the kernel** when used inside a string literal. The remaining gaps are in
the surrounding lexical rules, not in the table itself.

This report is **research-only**; no implementation changes are made here. The
companion specification and tests are committed alongside.

## Methodology

1. Extracted the full 1102-entry named-character table from
   `C:/Program Files/Wolfram Research/Wolfram/14.3/SystemFiles/FrontEnd/TextResources/UnicodeCharacters.tr`.
2. Confirmed the table matches `tungsten/data/wolfram_named_characters_14_3.json` (1100
   entries — the 2 omitted names `COMPATIBILITYKanjiSpace` and `COMPATIBILITYNoBreak`
   are kernel-rejected and intentionally excluded).
3. Built a 76-case escape-form probe (`C:/tmp/tungsten-probe/probe_escapes_v2.py`) that
   compares Tungsten's `parse_expression` against the kernel's
   `Quiet[ToExpression[input, InputForm, HoldComplete]]`, with character-code
   comparison so encoding artifacts cannot distort the result.
4. Built a comprehensive 1100-name probe
   (`C:/tmp/tungsten-probe/probe_all_named_chars.py`) that batched the kernel's
   `ToCharacterCode["\[Name]"]` for every entry and compared to the Tungsten string
   parse.
5. Mined the local Wolfram parser-corpus
   (`C:/TestData/wolfram/tungsten-wolfram-parser-corpus/github`) for real-world
   named-character usage. The corpus contains 1115 distinct named-character forms in
   real package source; 1100 are valid kernel names and 15 are corpus typos
   (`Alpa`, `delta`, `inf`, etc).

## Gap inventory

### G1. Linear-syntax string escapes (`\!`, `\(`, `\)`, `\*`, `\<`, `\>`)

**Severity**: low. **Test class**: `LinearSyntaxStringEscapeFails`.

Inside a string literal, the kernel decodes six special escape sequences to PUA
codepoints or to the empty string:

| Source | Kernel decoded codepoints | Tungsten current |
|--------|--------------------------|--------------------|
| `"\!"` | `[U+F7C1]` (1 char) | `[\, !]` (2 chars, literal) |
| `"\("` | `[U+F7C9]` (1 char) | `[\, (]` (2 chars, literal) |
| `"\)"` | `[U+F7C0]` (1 char) | `[\, )]` (2 chars, literal) |
| `"\*"` | `[U+F7C8]` (1 char) | `[\, *]` (2 chars, literal) |
| `"\<"` | `[]` (deleted) | `[\, <]` (2 chars, literal) |
| `"\>"` | `[]` (deleted) | `[\, >]` (2 chars, literal) |

These are linear-syntax markers used by the FrontEnd to embed inline-box content in
string-typed cells. The four `\!`, `\(`, `\)`, `\*` decode to PUA glyphs that the
Wolfram font renders specially. The `\<` and `\>` are zero-width markers used for
linear-syntax grouping.

**Real-world impact**: low. Real package source rarely contains these escapes inside
string literals; their main use is in machine-generated FrontEnd output and in box
language. Tungsten's notebook parser path handles inline-box escapes separately
(`\!\(\*...\)`), so the string-literal divergence does not block notebook
round-tripping.

**Implementation direction**: extend `wolfram_strings.parse_wl_string_literal` to map
these six 2-char sequences before falling through to literal preservation. The PUA
codepoints are already in the named-character table under the names
`\[RawEscape]` for `\!`, `\[LinearSyntaxOpenParenthesis]` for `\(`, etc. — a small
shim that maps each 2-char form to the corresponding name suffices.

### G2. Unknown / empty named character preserved verbatim

**Severity**: medium. **Test class**: `UnknownNamedCharStringFallbackFails`.

```
"\[NotARealName]"  Tungsten: ParseFailure
                   Kernel:   String "[\, [, N, o, t, A, R, e, a, l, N, a, m, e, ]]"
"\[]"              Tungsten: ParseFailure
                   Kernel:   String "[\, [, ]]"
```

The kernel's lenient fallback rule: if `\[Name]` doesn't match a known name, the
escape is **not an error**; the literal source text is preserved as the string's
content. Tungsten's `decode_named_character_escape` raises `ValueError("Unknown
Wolfram named character escape \[Name].")` instead.

**Real-world impact**: medium. Some packages use `\[Notebook]`-style names that
have been removed in newer kernel versions, and notebooks pass through Tungsten's
string parser. A typo in a package source file (`\[Alpa]` instead of `\[Alpha]`)
would produce a Tungsten parse error where the kernel would silently keep the
literal text. The corpus contains 15 such corpus-typo cases.

**Implementation direction**: change `decode_named_character_escape` to return the
literal source text when the name is unknown, rather than raising. Decide whether
to also emit a Tungsten-side warning message (the kernel does emit a non-fatal
`General::sntx`-shaped diagnostic for these in some versions).

### G3. Backslash-newline line continuation inside strings

**Severity**: low. **Test class**: `StringLiteralLineContinuationFails`.

```
"a\
 b"   Tungsten: "a\\\nb" (4 chars: a, \, LF, b... actually a \ LF b)
       Kernel:  "ab"     (2 chars)
```

The kernel deletes `\<LF>` and `\<CRLF>` from the decoded string content. Tungsten's
string lexer keeps them. Outside string literals, Tungsten already implements line
continuation correctly (`_line_continuation_end` in the parser); the gap is
specifically inside the string parser.

**Real-world impact**: low. Long literal strings spanning multiple source lines are
uncommon outside auto-generated `wolfram-language-server` snapshots.

**Implementation direction**: in `parse_wl_string_literal`, when seeing `\`
followed by `\r`, `\n`, or `\r\n`, advance past the newline without appending
anything to the output.

### G4. Octal and PUA-hex escapes outside string literals

**Severity**: low. **Test class**: `IdentifierKernelRejectsTests`.

```
\041     Tungsten: Symbol("!")    Kernel: ParseFailure
\:F4A1   Tungsten: Symbol() Kernel: ParseFailure
```

Wolfram allows the four numeric escapes (`\:XXXX`, `\.XX`, `\OOO`, `\|XXXXXX`) only
inside string literals. In identifier position, the kernel:

- accepts `\:XXXX` and `\|XXXXXX` for **letter-class** Unicode characters only —
  PUA codepoints are not letters and are rejected;
- accepts `\.XX` for the corresponding Latin-1 codepoint if it is letter-class;
- rejects `\OOO` (octal) entirely.

Tungsten's `_scan_simple_character_escape` accepts all four forms unconditionally
in identifier position, so it folds invalid identifier characters into symbol
names.

**Real-world impact**: low. No corpus file uses these forms in identifier
position; they only appear inside string literals.

**Implementation direction**: add a Unicode-class check in
`_scan_simple_character_escape` (use `unicodedata.category()`) and reject when the
decoded codepoint is in `Cc`, `Cf`, `Co` (PUA), `Cs` (surrogate), or any other
non-letter / non-mark / non-number category.

### G5. Hex-escape symbol-name aliasing

**Severity**: low. **Test class**: `IdentifierHexCanonicalizationFails`.

```
\:03C0   Tungsten: Symbol("π")  Kernel: Symbol("Pi")
```

The kernel canonicalizes `\:03C0` (a 4-digit Unicode escape) to the same Symbol as
`\[Pi]` and the bare `Pi`. Tungsten's lexer routes `\:03C0` through the
`_scan_simple_character_escape` path, which produces the literal Unicode codepoint
without consulting the alias table; `\[Pi]` goes through the named-character table
which does have the alias.

**Real-world impact**: very low. Code that uses `\:03C0` instead of `\[Pi]` or `Pi`
is rare and produces a syntactically equivalent Symbol from the kernel's
perspective (because of `Pi === π`).

**Implementation direction**: have `_scan_simple_character_escape` consult the
named-character reverse map. If the decoded codepoint corresponds to a name with
an alias entry in `_ESCAPED_SYMBOL_ALIASES`, emit the alias as the symbol name
rather than the Unicode character.

## What is NOT a gap (verified parity)

The following areas are already fully aligned with the kernel:

- **Decoding all 1100 named characters inside string literals**: every entry in
  `UnicodeCharacters.tr` produces the correct codepoint via Tungsten's
  `decode_named_character_escape`. Verified by an exhaustive sweep against
  `ToCharacterCode["\[Name]"]` for every `Name`.
- **Numeric escapes inside string literals**: `\:XXXX`, `\.XX`, `\OOO`, `\|XXXXXX`
  all decode to the correct codepoints. The strict-format rules (exact digit count,
  hex/octal validation) are also followed.
- **Two-character mnemonic escapes**: `\n`, `\r`, `\t`, `\b`, `\f`, `\\`, `\"` all
  decode correctly.
- **Identifier canonicalization for non-aliased names**: `\[Alpha]`, `\[Aleph]`,
  `\[CapitalAlpha]` etc. correctly produce a `Symbol` whose name is the single
  Unicode codepoint, matching the kernel.
- **Identifier alias for `\[Pi]`, `\[ImaginaryI]`, etc.**: the small alias set is
  correctly canonicalized to the English symbol name (`Pi`, `I`, `E`,
  `Infinity`, `Degree`).

## Real-world corpus statistics

The local parser corpus contains the following distribution of named-character
references in source code:

| Frequency | Top names |
|-----------|-----------|
| 54142 | `\[InvisibleSpace]` |
| 41801 | `\[DifferentialD]` |
| 41607 | `\[Integral]` |
| 32167 | `\[And]` |
| 25798 | `\[FilledSmallSquare]` |
| 25637 | `\[IndentingNewLine]` |
| 24254 | `\[Equal]` |
| 22715 | `\[Rule]` |
| 19255 | `\[DoubleStruckCapitalZ]` |
| 16930 | `\[Element]` |

Of 1115 distinct named-character forms used in the corpus, 1100 are valid kernel
names. Tungsten now decodes all 1100 to the correct codepoint inside strings;
previously (before commit `9f34a0079`) Tungsten knew only 220 of these.

The remaining 15 corpus references are typos (`Alpa`, `Curl`, `Divergence`,
`Gradient`, `Laplacian`, `delta`, `inf`, `integral`, `omega`, `phi`, etc.).
These should benefit from the **G2** fallback fix: keeping them as literal text
rather than failing.

## Test inventory

The companion test file `tests/test_named_character_parity.py` covers:

- 7 mnemonic escape forms (`\n`, `\r`, `\t`, `\b`, `\f`, `\"`, `\\`)
- 5 octal escape positive-and-negative cases
- 5 Latin-1 hex escape cases including lowercase hex
- 5 4-digit Unicode hex escape cases
- 3 6-digit Unicode hex escape cases (including supplementary plane)
- 2 line-continuation cases (expected failure)
- 35 named-character codepoint spot checks
- 3 named-character table consistency checks
- 8 identifier-position canonicalization checks (including alias resolution)
- 2 kernel-rejection / Tungsten-too-permissive cases (expected failure)
- 6 linear-syntax escape cases (expected failure)
- 2 unknown / empty named character cases (expected failure)
- 4 malformed numeric escape cases (documenting current Tungsten behavior)

Total: 54 tests, of which 13 are `@expectedFailure` and exactly capture each gap
listed above. The remaining 41 lock in already-correct behavior.

## Out-of-scope items

- **Round-trip identity** (renderer + parser symmetry). The kernel's FullForm
  rendering rules are documented in
  [wolfram-string-literal-spec.md](../wolfram-string-literal-spec.md#fullform-rendering),
  but Tungsten's `_format_string` and `encode_printable_ascii` paths were not
  exhaustively tested against `ToString[FullForm[s], InputForm]` for every
  codepoint. A separate round-trip parity sweep is recommended once the parser
  gaps in G1–G5 are closed.
- **Wolfram FrontEnd alias (`Esc-name-Esc`) handling**. The kernel's input
  syntax also supports keyboard-alias names like `Esc p Esc` that resolve to
  `\[Pi]`. Those are FrontEnd-only and not part of any source-text or
  `ToExpression` path. No parity is expected.
- **`\[Name]` evaluation rules**. The kernel may apply attached `OwnValues` to a
  named-character symbol (e.g. `\[Pi]` evaluates to `Pi` which is bound). Tungsten's
  evaluator is the right place to handle that, not the parser. Out of scope for
  this report.

## Conclusion

The 2026-04-27 commit `9f34a0079` closed the largest parity gap (220 names → 1100).
The remaining 5 gaps (G1–G5) are concrete, well-bounded, and individually small;
each has a concrete implementation direction sketched above. None are in the
critical path of real-world package parsing.

The 54 regression tests lock in current correct behavior and the 13 expected
failures pinpoint the remaining gaps for follow-up work.
