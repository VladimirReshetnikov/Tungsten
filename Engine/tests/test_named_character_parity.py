"""Regression tests for Wolfram named-character and string-escape parity.

These tests probe the parser's handling of `\\[Name]` named-character escapes
and the four numeric escape forms `\\:XXXX`, `\\.XX`, `\\OOO`, `\\|XXXXXX`,
both inside string literals and in identifier (outside-string) position.
The reference behavior is the Wolfram 14.3 kernel.

Tests are organized into:

1. ``StringLiteralEscapeForm*`` -- verifies that each documented escape form
   decodes to the correct codepoint inside a string literal.
2. ``NamedCharacterStringDecode*`` -- exercises the named-character table for
   string-context decoding. The full 1102-entry table parity is verified by
   spot checks here; the offline full sweep lives at
   ``C:/tmp/tungsten-probe/probe_all_named_chars.py`` for extension.
3. ``IdentifierEscape*`` -- verifies the corresponding identifier-position
   behavior, including the alias-canonicalization rule and the kernel's
   rejection of octal and PUA escapes outside string literals.
4. ``UnknownEscape*`` -- documents (with ``@expectedFailure`` where applicable)
   the known divergences between Tungsten and the kernel for malformed or
   unknown escapes.

Companion documents:

- ``docs/wolfram-string-literal-spec.md`` -- normative spec.
- ``docs/reports/2026-04-27-named-char-and-escape-parity.md`` -- gap report.
"""
from __future__ import annotations

import unittest

from tungsten.expression import (
    Symbol,
    String,
    WolframSyntaxError,
    parse_expression,
)
from tungsten.named_characters import named_character_codepoints


def _parse_string(text: str) -> String:
    expr = parse_expression(text, form="input")
    if not isinstance(expr, String):
        raise AssertionError(f"expected String, got {expr.to_full_form()!r}")
    return expr


def _parse_symbol(text: str) -> Symbol:
    expr = parse_expression(text, form="input")
    if not isinstance(expr, Symbol):
        raise AssertionError(f"expected Symbol, got {expr.to_full_form()!r}")
    return expr


def _codepoints(text: str) -> list[int]:
    return [ord(c) for c in text]


# ----------------------------------------------------------------------
# 1. String-literal escape forms
# ----------------------------------------------------------------------


class StringLiteralAsciiEscapeTests(unittest.TestCase):
    """Two-character mnemonic escapes inside a string literal."""

    def test_newline(self) -> None:
        self.assertEqual(_parse_string(r'"\n"').value, "\n")

    def test_carriage_return(self) -> None:
        self.assertEqual(_parse_string(r'"\r"').value, "\r")

    def test_tab(self) -> None:
        self.assertEqual(_parse_string(r'"\t"').value, "\t")

    def test_backspace(self) -> None:
        self.assertEqual(_parse_string(r'"\b"').value, "\b")

    def test_form_feed(self) -> None:
        self.assertEqual(_parse_string(r'"\f"').value, "\f")

    def test_double_quote(self) -> None:
        self.assertEqual(_parse_string(r'"\""').value, '"')

    def test_backslash(self) -> None:
        self.assertEqual(_parse_string(r'"\\"').value, "\\")


class StringLiteralOctalEscapeTests(unittest.TestCase):
    """Octal escapes ``\\OOO`` decode three octal digits to a Latin-1 codepoint."""

    def test_octal_letter_a(self) -> None:
        # \101 = 0o101 = 65 = 'A'
        self.assertEqual(_parse_string(r'"\101"').value, "A")

    def test_octal_exclamation(self) -> None:
        # \041 = 0o41 = 33 = '!'
        self.assertEqual(_parse_string(r'"\041"').value, "!")

    def test_octal_max(self) -> None:
        # \377 = 0o377 = 255 = U+00FF
        self.assertEqual(_parse_string(r'"\377"').value, "ÿ")

    def test_octal_min(self) -> None:
        # \000 = NUL
        self.assertEqual(_parse_string(r'"\000"').value, "\x00")

    def test_octal_followed_by_literal_digit(self) -> None:
        # \173 = '{', then literal '8'
        self.assertEqual(_parse_string(r'"\1738"').value, "{8")


class StringLiteralLatin1EscapeTests(unittest.TestCase):
    """Latin-1 escapes ``\\.XX`` decode two hex digits to a codepoint in 0..0xFF."""

    def test_latin1_letter_a(self) -> None:
        self.assertEqual(_parse_string(r'"\.41"').value, "A")

    def test_latin1_copyright(self) -> None:
        self.assertEqual(_parse_string(r'"\.A9"').value, "©")

    def test_latin1_max(self) -> None:
        self.assertEqual(_parse_string(r'"\.FF"').value, "ÿ")

    def test_latin1_lowercase_hex(self) -> None:
        self.assertEqual(_parse_string(r'"\.a9"').value, "©")

    def test_latin1_min(self) -> None:
        self.assertEqual(_parse_string(r'"\.00"').value, "\x00")


class StringLiteralUnicode4EscapeTests(unittest.TestCase):
    """4-digit Unicode escapes ``\\:XXXX`` decode to a BMP codepoint."""

    def test_unicode4_letter_a(self) -> None:
        self.assertEqual(_parse_string(r'"\:0041"').value, "A")

    def test_unicode4_pi(self) -> None:
        self.assertEqual(_parse_string(r'"\:03C0"').value, "π")

    def test_unicode4_squared(self) -> None:
        self.assertEqual(_parse_string(r'"\:00B2"').value, "²")

    def test_unicode4_function_pua(self) -> None:
        # PUA codepoint is decoded literally inside string
        self.assertEqual(_parse_string(r'"\:F4A1"').value, "")

    def test_unicode4_lowercase_hex(self) -> None:
        self.assertEqual(_parse_string(r'"\:03c0"').value, "π")


class StringLiteralUnicode6EscapeTests(unittest.TestCase):
    """6-digit Unicode escapes ``\\|XXXXXX`` cover the supplementary planes."""

    def test_unicode6_letter_a(self) -> None:
        self.assertEqual(_parse_string(r'"\|000041"').value, "A")

    def test_unicode6_emoji(self) -> None:
        self.assertEqual(_parse_string(r'"\|01F600"').value, "\U0001F600")

    def test_unicode6_max(self) -> None:
        self.assertEqual(_parse_string(r'"\|10FFFF"').value, "\U0010ffff")


@unittest.expectedFailure
class StringLiteralLineContinuationFails(unittest.TestCase):
    """A backslash followed by a newline is deleted from the decoded string in
    the kernel. Tungsten currently preserves the literal backslash and the
    newline. Both of these tests are expected-failure pending implementation.

    Outside string literals, Tungsten already implements line continuation.
    The gap is specifically inside string literals.
    """

    def test_backslash_lf_deleted_in_string(self) -> None:
        self.assertEqual(_parse_string('"a\\\nb"').value, "ab")

    def test_backslash_crlf_deleted_in_string(self) -> None:
        self.assertEqual(_parse_string('"a\\\r\nb"').value, "ab")


# ----------------------------------------------------------------------
# 2. Named-character decoding inside strings
# ----------------------------------------------------------------------


class NamedCharacterStringSpotChecks(unittest.TestCase):
    """A representative sampling of named characters decoded inside strings.

    The expected codepoints are the kernel's authoritative mapping from
    ``UnicodeCharacters.tr``. Note that several Wolfram constants
    (``EulerGamma``, ``Catalan``, ``GoldenRatio``, ``Glaisher``, ``Khinchin``)
    do **not** have a ``\\[Name]`` form -- they are typed in ASCII directly.
    """

    SAMPLES = [
        ("Alpha", 0x03B1),
        ("Beta", 0x03B2),
        ("Gamma", 0x03B3),
        ("Pi", 0x03C0),
        ("Sigma", 0x03C3),
        ("Omega", 0x03C9),
        ("CapitalAlpha", 0x0391),
        ("CapitalDigamma", 0x03DC),
        ("Aleph", 0x2135),
        ("CenterDot", 0x00B7),
        ("CirclePlus", 0x2295),
        ("CircleTimes", 0x2297),
        ("Element", 0x2208),
        ("Infinity", 0x221E),
        ("Function", 0xF4A1),
        ("ImaginaryI", 0xF74E),
        ("ExponentialE", 0xF74D),
        ("PartialD", 0x2202),
        ("DifferentialD", 0xF74C),
        ("Integral", 0x222B),
        ("Sum", 0x2211),
        ("Product", 0x220F),
        ("GreaterEqual", 0x2265),
        # Note: Wolfram's `\[DoubleStruckCapitalZ]` uses the PUA glyph 0xF7BD
        # rather than Unicode 0x2124 (DOUBLE-STRUCK CAPITAL Z); the latter is
        # exposed in the kernel as a synonym only at the FontEnd level.
        ("DoubleStruckCapitalZ", 0xF7BD),
        ("Star", 0x22C6),
        ("FilledSmallSquare", 0x25FC),
        ("ODoubleDot", 0x00F6),
        ("Theta", 0x03B8),
        ("Ellipsis", 0x2026),
        ("Psi", 0x03C8),
        ("Xi", 0x03BE),
        # Wolfram's NumberSign is a PUA glyph (U+F724), distinct from
        # RawNumberSign (U+0023). Both are documented named characters.
        ("NumberSign", 0xF724),
        ("RawNumberSign", 0x0023),
        ("Copyright", 0x00A9),
        ("Degree", 0x00B0),
    ]

    def test_each_sample_decodes_to_expected_codepoint(self) -> None:
        for name, expected_cp in self.SAMPLES:
            with self.subTest(name=name):
                src = f'"\\[{name}]"'
                value = _parse_string(src).value
                self.assertEqual(
                    len(value), 1,
                    f"\\[{name}] should decode to a single character"
                )
                self.assertEqual(
                    ord(value), expected_cp,
                    f"\\[{name}] expected U+{expected_cp:04X}, got U+{ord(value):04X}",
                )


class NamedCharacterTableConsistencyTests(unittest.TestCase):
    """The shipped named-characters table contains the expected family members."""

    def test_table_has_expected_size(self) -> None:
        # The Wolfram 14.3 font ships 1102 entries; the JSON file excludes 2
        # kernel-rejected entries (COMPATIBILITYKanjiSpace, COMPATIBILITYNoBreak),
        # leaving 1100 usable names.
        self.assertEqual(len(named_character_codepoints()), 1100)

    def test_includes_all_greek_lowercase(self) -> None:
        table = named_character_codepoints()
        for letter in [
            "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta",
            "Theta", "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron",
            "Pi", "Rho", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
        ]:
            self.assertIn(letter, table, f"missing Greek letter \\[{letter}]")

    def test_includes_common_pua_glyphs(self) -> None:
        table = named_character_codepoints()
        # PUA characters (0xE000..0xF8FF) for Wolfram-specific glyphs.
        # NOTE: ``EulerGamma``, ``Catalan``, ``GoldenRatio``, ``Khinchin``,
        # and ``Glaisher`` are NOT named characters in Wolfram (they are typed
        # as ASCII identifiers and have no ``\[Name]`` form).
        for name in [
            "Function", "ImaginaryI", "ImaginaryJ", "ExponentialE",
            "DifferentialD",
        ]:
            self.assertIn(name, table, f"missing PUA \\[{name}]")
            cp = table[name]
            self.assertTrue(
                0xE000 <= cp <= 0xF8FF,
                f"\\[{name}] U+{cp:04X} should be in PUA",
            )


# ----------------------------------------------------------------------
# 3. Identifier-position escape semantics
# ----------------------------------------------------------------------


class IdentifierNamedCharBareTests(unittest.TestCase):
    """``\\[Name]`` outside a string parses as an identifier with the codepoint."""

    def test_alpha_outside_string(self) -> None:
        # Wolfram: SymbolName is "α" (one codepoint U+03B1)
        sym = _parse_symbol(r"\[Alpha]")
        # Tungsten currently produces a Symbol with the literal text "\[Alpha]"
        # (8 ASCII chars). Document the divergence.
        self.assertIn(sym.name, ("α", r"\[Alpha]"))

    def test_pi_alias(self) -> None:
        # Wolfram canonicalizes \[Pi] to Symbol "Pi" via the alias rule
        sym = _parse_symbol(r"\[Pi]")
        self.assertEqual(sym.name, "Pi")

    def test_imaginary_i_alias(self) -> None:
        sym = _parse_symbol(r"\[ImaginaryI]")
        self.assertEqual(sym.name, "I")

    def test_exponential_e_alias(self) -> None:
        sym = _parse_symbol(r"\[ExponentialE]")
        self.assertEqual(sym.name, "E")

    def test_infinity_alias(self) -> None:
        sym = _parse_symbol(r"\[Infinity]")
        self.assertEqual(sym.name, "Infinity")


class IdentifierNamedCharCanonicalizationTests(unittest.TestCase):
    """Tungsten correctly canonicalizes ``\\[Alpha]`` to a Symbol whose name
    is the single Unicode codepoint U+03B1 (matching the kernel as of the
    2026-04-27 ``Align Tungsten named character escapes`` commit). Locked-in
    here so future regressions are caught immediately.
    """

    def test_alpha_symbol_name_is_unicode_char(self) -> None:
        sym = _parse_symbol(r"\[Alpha]")
        self.assertEqual(sym.name, "α")

    def test_aleph_symbol_name_is_unicode_char(self) -> None:
        sym = _parse_symbol(r"\[Aleph]")
        self.assertEqual(sym.name, "ℵ")

    def test_capital_alpha_symbol_name(self) -> None:
        sym = _parse_symbol(r"\[CapitalAlpha]")
        self.assertEqual(sym.name, "Α")  # U+0391, distinct from ASCII 'A'


@unittest.expectedFailure
class IdentifierHexCanonicalizationFails(unittest.TestCase):
    """``\\:03C0`` outside a string canonicalizes to Symbol ``Pi`` in the kernel
    (because U+03C0 has the alias ``Pi``); Tungsten currently produces a
    one-character Symbol named ``"π"`` instead.
    """

    def test_pi_via_hex_aliases_to_Pi(self) -> None:
        sym = _parse_symbol(r"\:03C0")
        self.assertEqual(sym.name, "Pi")


class IdentifierKernelRejectsTests(unittest.TestCase):
    """Several escape forms are valid inside strings but rejected by the kernel
    in identifier position. Tungsten currently accepts them.
    """

    @unittest.expectedFailure
    def test_octal_outside_string_should_reject(self) -> None:
        # Kernel rejects \041 outside strings.
        with self.assertRaises(WolframSyntaxError):
            parse_expression(r"\041", form="input")

    @unittest.expectedFailure
    def test_pua_hex_outside_string_should_reject(self) -> None:
        # Kernel rejects \:F4A1 (PUA) outside strings -- not a valid identifier
        # character.
        with self.assertRaises(WolframSyntaxError):
            parse_expression(r"\:F4A1", form="input")


# ----------------------------------------------------------------------
# 4. Unknown / malformed escape divergences
# ----------------------------------------------------------------------


@unittest.expectedFailure
class UnknownNamedCharStringFallbackFails(unittest.TestCase):
    """When a string contains ``"\\[Unknown]"`` for a name that is not in the
    table, Wolfram preserves the literal source text as the string's content.
    Tungsten currently raises a parse error.
    """

    def test_unknown_name_preserves_literal(self) -> None:
        s = _parse_string(r'"\[NotARealName]"')
        # Kernel result: the literal 16-char source `\[NotARealName]`
        self.assertEqual(s.value, r"\[NotARealName]")

    def test_empty_named_char_preserves_literal(self) -> None:
        s = _parse_string(r'"\[]"')
        self.assertEqual(s.value, r"\[]")


@unittest.expectedFailure
class LinearSyntaxStringEscapeFails(unittest.TestCase):
    """Wolfram has special semantics for ``\\!``, ``\\(``, ``\\)``, ``\\*``,
    ``\\<``, and ``\\>`` inside string literals (linear-syntax markers). They
    decode to PUA codepoints or are deleted. Tungsten currently preserves the
    literal backslash + character.

    Codepoints from probing Wolfram 14.3:
    - ``\\!`` -> U+F7C1
    - ``\\(`` -> U+F7C9
    - ``\\)`` -> U+F7C0
    - ``\\*`` -> U+F7C8
    - ``\\<`` -> deleted (decoded as zero characters)
    - ``\\>`` -> deleted (decoded as zero characters)
    """

    def test_bang_decodes_to_pua(self) -> None:
        self.assertEqual(_parse_string(r'"\!"').value, "")

    def test_paren_open_decodes_to_pua(self) -> None:
        self.assertEqual(_parse_string(r'"\("').value, "")

    def test_paren_close_decodes_to_pua(self) -> None:
        self.assertEqual(_parse_string(r'"\)"').value, "")

    def test_star_decodes_to_pua(self) -> None:
        self.assertEqual(_parse_string(r'"\*"').value, "")

    def test_lt_is_deleted(self) -> None:
        self.assertEqual(_parse_string(r'"\<"').value, "")

    def test_gt_is_deleted(self) -> None:
        self.assertEqual(_parse_string(r'"\>"').value, "")


class MalformedNumericEscapeTests(unittest.TestCase):
    """Wolfram strictly rejects malformed numeric escapes; Tungsten currently
    falls back to literal preservation.

    These tests document the *current* Tungsten behavior and are NOT marked
    expected-failure; the parity gap is documented in the report.
    """

    def test_short_hex_unicode_preserved_as_literal(self) -> None:
        # Wolfram rejects \:003 (3 digits). Tungsten preserves as literal.
        s = _parse_string(r'"\:003"')
        # Currently 4 chars: '\\', ':', '0', '0', '3' = 5 chars actually
        self.assertEqual(s.value, "\\:003")

    def test_short_latin1_preserved_as_literal(self) -> None:
        s = _parse_string(r'"\.A"')
        self.assertEqual(s.value, "\\.A")

    def test_short_unicode6_preserved_as_literal(self) -> None:
        s = _parse_string(r'"\|0000"')
        self.assertEqual(s.value, "\\|0000")

    def test_unknown_one_char_escape_preserved(self) -> None:
        # Wolfram rejects \g (and most other non-listed mnemonics). Tungsten
        # currently keeps the literal backslash + char.
        s = _parse_string(r'"\g"')
        self.assertEqual(s.value, "\\g")


if __name__ == "__main__":
    unittest.main()
