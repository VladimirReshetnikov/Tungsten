# Wolfram Language String-Literal and Identifier Escape Specification

- Status: Reference (specification of Wolfram-Language string-literal lexis and the
  parallel character-escape rules that apply outside string literals)
- Audience: Tungsten parser, evaluator, and renderer maintainers; reviewers comparing
  Tungsten behavior against the local Wolfram 14.3 kernel
- Scope: textual surface syntax of Wolfram Language string literals (`"..."`), the
  identical numeric and named-character escape forms that appear outside string
  literals as identifier and operator characters, and the canonical FullForm rendering
  rules that turn parsed strings back into source text
- Created (UTC): 2026-04-27T19:01:27Z
- Repository HEAD: 9f34a00792e3b1c988cebccb17987d8421240085
- Authoritative references:
  - [tutorial/StringsAndCharacters](https://reference.wolfram.com/language/tutorial/StringsAndCharacters.html)
  - [tutorial/MathematicalAndOtherNotation](https://reference.wolfram.com/language/tutorial/MathematicalAndOtherNotation.html)
  - [guide/ListingOfNamedCharacters](https://reference.wolfram.com/language/guide/ListingOfNamedCharacters.html)
  - [ref/ToString](https://reference.wolfram.com/language/ref/ToString.html)
  - Local font data file:
    `C:/Program Files/Wolfram Research/Wolfram/14.3/SystemFiles/FrontEnd/TextResources/UnicodeCharacters.tr`
    (1102 named characters with their canonical Unicode codepoints, used as the parity
    oracle in this specification)

## Motivation

Tungsten currently recognizes ~220 named Wolfram characters out of 1102 in Wolfram 14.3,
and its string-literal escape parser is more permissive than the kernel — it preserves
malformed and unknown escapes as literal backslash text rather than rejecting them.
This document captures the kernel's behavior precisely so the parser, the
`parse_wl_string_literal` helper, and the FullForm renderer can be brought into parity.

This is **specification-only**. Implementation work is not in scope here; see the
companion report at [reports/2026-04-27-named-char-and-escape-parity.md](./reports/2026-04-27-named-char-and-escape-parity.md)
for the parity-gap inventory.

## Vocabulary

- A **codepoint** is a Unicode scalar value in `0..0x10FFFF` excluding the surrogate
  range `0xD800..0xDFFF`.
- A **character** is the source-text occurrence of a single codepoint, possibly written
  as a multi-character escape sequence.
- A **string literal** is a token starting with `"`, ending with the matching `"`, and
  containing zero or more characters in between.
- A **named character** is a character that has an `\[Name]` long-form alias in the
  Wolfram Language. The kernel's font data file lists 1102 such names in 14.3.
- The **PUA** (Private Use Area) is the codepoint range `0xE000..0xF8FF`, reserved by
  Unicode for application-specific use. Wolfram assigns 450 of the 1102 named
  characters to PUA codepoints in `0xF000..0xFFFE`. These are visible only when the
  Wolfram font is loaded; they are otherwise unrendered glyphs.

## String-literal lexis

A string literal is the regular expression
`" ( <regular> | <escape> )* "`, where:

- `<regular>` is any source character other than `"` and `\`.
- `<escape>` is one of the recognized escape forms below.

The string literal begins at the opening `"` and ends at the next *unescaped* `"`. The
result of parsing is a Wolfram `String` atom whose value is the decoded character
sequence. Parsing fails (`ToExpression[..., InputForm]` returns `$Failed`, and
`ToExpression[..., InputForm, HoldComplete]` likewise returns `$Failed`) if any
`<escape>` is malformed.

### `<regular>`: literal characters

Any source character whose codepoint is not `0x22` (`"`) or `0x5C` (`\`) appears
literally in the result. Source files are typically UTF-8 in Wolfram 14.x, so a literal
`"π"` contains the single codepoint U+03C0.

The Wolfram parser does **not** require source files to be ASCII; multi-byte UTF-8
sequences are decoded into the corresponding codepoints before string lexing.

Newlines (LF, CR, CRLF) inside a string literal are accepted and produce the actual
newline codepoint(s) in the result, except when immediately preceded by a backslash
(see "Line-continuation escape" below).

### `<escape>`: escape forms

The kernel recognizes exactly the following escape forms inside string literals. Each
form starts with a backslash. Anything that begins with `\` and is not one of these
forms is a syntax error.

#### 1. Two-character mnemonic escapes

| Source | Result codepoint | Mnemonic |
|--------|------------------|----------|
| `\n` | `U+000A` | newline |
| `\r` | `U+000D` | carriage return |
| `\t` | `U+0009` | tab |
| `\b` | `U+0008` | backspace |
| `\f` | `U+000C` | form feed |
| `\\` | `U+005C` | literal backslash |
| `\"` | `U+0022` | literal double quote |

> Note: the kernel does **not** support C-style `\a`, `\v`, `\e`, `\0`, or `\x..`
> outside the specific forms listed below. `"\g"`, `"\v"`, `"\a"` are syntax errors.

#### 2. Inline-box and linear-syntax markers

These escapes carry box-language and linear-syntax meaning. Inside a string literal
their decoded codepoints are PUA characters that the FrontEnd interprets specially:

| Source | Result codepoint | Wolfram name | Notes |
|--------|------------------|--------------|-------|
| `\!` | `U+F7C1` | `\[RawEscape]`-like inline-box prefix opener | Begins a `\!\(...\)` inline-box escape when followed by `\(`. Inside a string, it decodes to U+F7C1. |
| `\(` | `U+F7C9` | `\[LinearSyntaxOpenParenthesis]` | Linear-syntax box open. |
| `\)` | `U+F7C0` | `\[LinearSyntaxCloseParenthesis]` | Linear-syntax box close. |
| `\*` | `U+F7C8` | `\[LinearSyntaxStar]` | Linear-syntax marker. |
| `\<` | empty | (none) | Linear-syntax delimiter; **deleted** from the decoded string. |
| `\>` | empty | (none) | Linear-syntax delimiter; **deleted** from the decoded string. |
| `\^` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\_` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\&` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\@` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\/` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\%` | (TBD)   | (none) | Linear-syntax marker; behavior TBD. |
| `\!` | as above | (none) | Inline-box prefix. |

The TBD entries are documented in the kernel but not yet probed in this specification
pass; they should be added once tested.

#### 3. Octal escape `\OOO`

A backslash followed by exactly three octal digits (`0..7`). The result is the codepoint
formed by interpreting the three octal digits as a base-8 number, in the range
`0..0o777` = `0..511`. Examples:

- `\041` → `U+0021` (`!`)
- `\173` → `U+007B` (`{`)
- `\377` → `U+00FF` (`ÿ`)
- `\000` → `U+0000` (NUL)

**Strictness**: exactly three digits. `\0`, `\01`, `\17` are syntax errors. `\1738` is
the valid 3-digit octal `\173` (= `{`) followed by the literal character `8`.

A digit greater than 7 anywhere in the three digits is a syntax error
(e.g. `\800`, `\999`).

#### 4. Latin-1 hex escape `\.XX`

A backslash, a period, and exactly two hex digits (`0-9`, `a-f`, `A-F`,
case-insensitive). The result is the codepoint formed by interpreting the two hex
digits as a base-16 number, in the range `0..0xFF` = `0..255`.

- `\.41` → `U+0041` (`A`)
- `\.A9` → `U+00A9` (`©`)
- `\.FF` → `U+00FF` (`ÿ`)

**Strictness**: exactly two hex digits. `\.`, `\.0`, `\.A` are syntax errors. Non-hex
characters (e.g. `\.GG`) are syntax errors.

#### 5. 4-digit Unicode hex escape `\:XXXX`

A backslash, a colon, and exactly four hex digits. The result is the codepoint formed
by interpreting the four hex digits as a base-16 number, in the range `0..0xFFFF`.

- `\:0041` → `U+0041` (`A`)
- `\:03C0` → `U+03C0` (`π`)
- `\:F4A1` → `U+F4A1` (PUA `\[Function]` glyph)

**Strictness**: exactly four hex digits. `\:`, `\:0`, `\:00`, `\:000` are syntax
errors. Surrogate values (`\:D800` through `\:DFFF`) are accepted by some kernel
versions but produce malformed UTF-16; this implementation should also accept them
verbatim for parity but warn on render.

#### 6. 6-digit Unicode hex escape `\|XXXXXX`

A backslash, a vertical bar, and exactly six hex digits. The result is the codepoint
formed by interpreting the six hex digits as a base-16 number, in the range
`0..0x10FFFF`.

- `\|000041` → `U+0041` (`A`)
- `\|01F600` → `U+1F600` (😀)
- `\|10FFFF` → `U+10FFFF` (last valid Unicode codepoint)

**Strictness**: exactly six hex digits. Codepoints in the surrogate range (`0xD800..0xDFFF`)
or above `0x10FFFF` are syntax errors.

#### 7. Named-character escape `\[Name]`

A backslash, an open square bracket, a non-empty alphanumeric sequence, and a closing
square bracket. If `Name` is in the kernel's table of recognized named characters, the
escape decodes to the canonical Unicode codepoint for that name. If `Name` is **not**
recognized, the kernel preserves the literal sequence `\[Name]` verbatim in the
decoded string (the backslash, brackets, and name are kept as 3+name-length
characters). An empty name `\[]` likewise decodes to the literal three characters
`\[]`.

Examples:

| Source | Result codepoint(s) |
|--------|---------------------|
| `"\[Alpha]"` | `[0x03B1]` (α) |
| `"\[Pi]"` | `[0x03C0]` (π) |
| `"\[Function]"` | `[0xF4A1]` (PUA) |
| `"\[ImaginaryI]"` | `[0xF74E]` (PUA) |
| `"\[Aleph]"` | `[0x2135]` (ℵ) |
| `"\[CenterDot]"` | `[0x00B7]` (·) |
| `"\[GreaterEqual]"` | `[0x2265]` (≥) |
| `"\[CapitalAlpha]"` | `[0x0391]` (Α) |
| `"\[NotARealName]"` | `[0x5C, 0x5B, …]` — backslash + brackets + name (literal) |
| `"\[]"` | `[0x5C, 0x5B, 0x5D]` — three literal characters |

The full mapping of names to codepoints is the contents of the kernel's
`UnicodeCharacters.tr` resource file; Tungsten should treat that file as the canonical
source rather than maintain a hand-curated list.

#### 8. Line-continuation escape

A backslash immediately followed by a newline (LF, CR, or CRLF) is a line-continuation
inside a string literal. The backslash and the newline together are **deleted** from
the decoded string. This lets long string literals span multiple source lines without
introducing newline characters.

```text
"hello\
 world"
```

decodes to `"hello world"` (with the leading-space-on-the-next-line preserved as part
of the string content).

> Note: the kernel also accepts a backslash followed by an arbitrary amount of
> trailing horizontal whitespace and then a newline. Tungsten matches this in
> `_line_continuation_end`.

### Failure model

Wolfram's kernel parser is strict about string-literal escapes. Any source position
that begins with a backslash and is not one of the eight forms above is a parse
error. `ToExpression[..., InputForm]` returns `$Failed` and emits a
`General::sntx`-shaped message. `ToExpression[..., InputForm, HoldComplete]` returns
`$Failed` rather than `HoldComplete[$Failed]`.

The one significant softening of this rule is that **unrecognized named characters
are preserved verbatim** rather than being errors. `"\[Alpa]"` (with one missing `h`)
decodes to the literal 6-character string `\[Alpa]` rather than failing. The same
holds for `"\[]"`. This is the only escape form that has fall-through-to-literal
semantics; every other malformed escape is a hard syntax error.

## Identifier-context escapes (outside string literals)

The same numeric and named escape sequences appear in identifier and operator
position outside string literals. They follow the same lexical rules but with two
significant differences from the string-literal context:

1. **Octal escapes are not allowed.** `\041` is a string-literal-only form; outside
   strings it is a syntax error. The kernel only allows `\:XXXX`, `\.XX`,
   `\|XXXXXX`, and `\[Name]` outside strings.

2. **PUA codepoints are not valid identifier characters.** A `\:F4A1` outside a
   string is a syntax error even though the same escape inside a string is valid.
   Only codepoints that fall in the standard letter/digit categories may compose an
   identifier.

3. **Aliases collapse symbol names to their canonical English form.** When the named
   character has a built-in alias (the small set `Pi`, `E`, `I`, `Infinity`,
   `Degree`, `EulerGamma`, etc.), the parser produces a `Symbol` whose canonical
   `SymbolName` is the English alias rather than the bare Unicode character. So
   `\[Pi]` and `\:03C0` and the literal Unicode `π` all parse to the same symbol
   whose `SymbolName` is `"Pi"`.

4. **Non-aliased named characters become single-character symbol names.**
   `\[Alpha]` and `\:03B1` and the literal `α` all parse to the same symbol whose
   `SymbolName` is the single-character string `"α"` (one codepoint).

The full alias table is small. The known built-in aliases as of 14.3 are:

| Named character | Codepoint | Canonical SymbolName |
|-----------------|-----------|----------------------|
| `\[Pi]` | `0x03C0` | `Pi` |
| `\[ExponentialE]` | `0xF74D` | `E` |
| `\[ImaginaryI]` | `0xF74E` | `I` |
| `\[ImaginaryJ]` | `0xF74F` | `I` |
| `\[Infinity]` | `0x221E` | `Infinity` |
| `\[Degree]` | `0x00B0` | `Degree` |
| `\[EulerGamma]` | `0xF74A` | `EulerGamma` |
| `\[Catalan]` | `0xF74C` | `Catalan` |
| `\[GoldenRatio]` | `0xF7B7` | `GoldenRatio` |
| `\[Khinchin]` | `0xF7B6` | `Khinchin` |
| `\[Glaisher]` | `0xF7B5` | `Glaisher` |
| `\[CapitalDigamma]` | `0xF74B` | (TBD) |

This table is best derived from the kernel at runtime (`SymbolName[\[Name]]`) rather
than maintained by hand.

## FullForm rendering

The kernel's `ToString[expr, InputForm]` and `FullForm[expr]` rendering of strings is
governed by the following decision rules, applied per character:

1. **ASCII printable (`U+0020..U+007E` excluding `"` and `\`)**: emit verbatim.
2. **`U+0022` (`"`)**: emit `\"`.
3. **`U+005C` (`\`)**: emit `\\`.
4. **`U+0008..U+000D`** (one of the C-mnemonic codepoints): emit the corresponding
   `\b`, `\t`, `\n`, `\f`, `\r` mnemonic.
5. **Other `U+0000..U+007F` (ASCII control)**: emit as octal `\OOO`.
6. **Latin-1 supplement `U+0080..U+00FF`**: emit as octal `\OOO` (so U+00B2 → `\262`,
   U+00FF → `\377`) **unless** the codepoint is one of the small set of Latin-1
   codepoints that has a Wolfram named character (e.g. `U+00A9` → `\[Copyright]`).
   For the named-character set the named form wins.
7. **`U+0100..U+FFFF` (BMP outside Latin-1)**: emit as `\[Name]` if the codepoint
   has a Wolfram name; otherwise emit as `\:XXXX`.
8. **`U+10000..U+10FFFF` (supplementary planes)**: emit as `\|XXXXXX`. Wolfram
   currently has no supplementary-plane named characters.

This is the rule observed in 14.3 by sampling
`ToString[FullForm[<one-character-string>]]` for representative codepoints. Some
codepoints in the Latin-1 range (e.g. U+00A9 ©, U+00B0 °) prefer the named form, while
others (e.g. U+00B2 ²) prefer octal — the choice is per-codepoint and stored in the
font's resource file alongside the name itself. The resource file annotates each
codepoint with a "Class" column (`Letter`, `Alias`, `Postfix`, etc.) and additional
flags that influence whether the renderer prefers `\[Name]` or `\OOO` / `\:XXXX`.

The `InputForm` rendering of a string is a relaxed superset of `FullForm`: it
typically emits the underlying codepoint verbatim if the source encoding can carry
it (so `ToString["\[Alpha]", InputForm]` produces `"α"` literally), while
`FullForm["\[Alpha]"]` produces `"\[Alpha]"`. Tungsten uses `FullForm` as its
canonical-form renderer for tooling and diff output, so matching the FullForm rules
above is the priority.

## Round-trip identity

For every codepoint c in `0..0x10FFFF` (excluding surrogates), the following round-trip
must hold:

```
c == ToCharacterCode[ToExpression[ToString[FromCharacterCode[c], FullForm], InputForm]][[1]]
```

That is: take a single-character string, render it as a FullForm source-text literal,
re-parse it through `ToExpression[..., InputForm]`, take the single codepoint of the
result. The result codepoint must equal the original.

This is the parity acceptance test for renderer + parser symmetry. Tungsten currently
fails round-trip for codepoints whose FullForm rendering uses a `\[Name]` form that
Tungsten does not recognize.

## Identifier round-trip

A parallel round-trip identity holds for symbol names:

```
SymbolName[ToExpression[\[Name], InputForm]] == "alias"
```

where `alias` is either the bare English alias (for the small alias set above) or the
single-character SymbolName for non-aliased named characters. Tungsten currently
diverges by:

- Producing the literal text `\[Name]` (8+ characters) as the `SymbolName` when it
  does not recognize `Name`.
- Producing the raw single Unicode character (e.g. `π`) as the `SymbolName` when it
  decodes `\:03C0` directly without applying the alias rule that maps it back to
  `"Pi"`.

The implementation will need both a comprehensive named-character table and an
alias-canonicalization step in the lexer.

## Related Tungsten code paths

- [src/tungsten/wolfram_strings.py](../src/tungsten/wolfram_strings.py) —
  `parse_wl_string_literal` decodes string-literal escapes; `_decode_character_escape`
  handles the four numeric forms; the named-character form `\[Name]` is currently not
  decoded inside strings.
- [src/tungsten/expression_parser.py](../src/tungsten/expression_parser.py) —
  `_scan_escaped_token` handles `\[Name]` outside strings;
  `_scan_simple_character_escape` handles `\:`, `\.`, `\|`, octal outside strings.
- [src/tungsten/expression.py](../src/tungsten/expression.py) — `_ESCAPED_TOKEN_MAP`
  (~13 entries), `_ESCAPED_SYMBOL_ALIASES` (~5 entries), and
  `_ESCAPED_INFIX_OPERATOR_HEADS` (~63 entries) constitute Tungsten's hand-curated
  named-character table. Tungsten knows about 220 of the 1102 14.3 names.

The implementation gap analysis is in
[reports/2026-04-27-named-char-and-escape-parity.md](./reports/2026-04-27-named-char-and-escape-parity.md).
