from __future__ import annotations

from functools import lru_cache
import json
from importlib import resources


@lru_cache(maxsize=1)
def named_character_codepoints() -> dict[str, int]:
    data_path = resources.files(__package__).joinpath("data/wolfram_named_characters_14_3.json")
    with data_path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    characters = payload["characters"]
    return {str(name): int(codepoint) for name, codepoint in characters.items()}


@lru_cache(maxsize=1)
def named_character_reverse_map() -> dict[int, str]:
    reverse: dict[int, str] = {}
    for name, codepoint in named_character_codepoints().items():
        if codepoint < 128 and name.startswith("Raw"):
            continue
        reverse.setdefault(codepoint, name)
    return reverse


def named_character(name: str) -> str | None:
    codepoint = named_character_codepoints().get(name)
    if codepoint is None:
        return None
    return chr(codepoint)


def named_character_escape_for_char(char: str) -> str | None:
    if len(char) != 1:
        return None
    name = named_character_reverse_map().get(ord(char))
    if name is None:
        return None
    return f"\\[{name}]"


_PRINTABLE_ASCII_CONTROL_ESCAPES = {
    8: r"\b",
    9: r"\t",
    10: r"\n",
    12: r"\f",
    13: r"\r",
    27: r"\[RawEscape]",
}


def _escape_printable_ascii_character(char: str) -> str:
    codepoint = ord(char)
    if codepoint in _PRINTABLE_ASCII_CONTROL_ESCAPES:
        return _PRINTABLE_ASCII_CONTROL_ESCAPES[codepoint]
    if codepoint < 32 or codepoint == 127:
        return f"\\{codepoint:03o}"
    named = named_character_escape_for_char(char)
    if named is not None:
        return named
    if codepoint <= 0xFFFF:
        return f"\\:{codepoint:04x}"
    return f"\\|{codepoint:06x}"


def encode_printable_ascii(text: str) -> str:
    return "".join(
        char if 32 <= ord(char) < 127 else _escape_printable_ascii_character(char)
        for char in text
    )


def decode_named_character_escape(text: str, index: int) -> tuple[str, int] | None:
    if not text.startswith("\\[", index):
        return None
    end = text.find("]", index + 2)
    if end < 0:
        # The kernel's string-literal lexer preserves an unterminated ``\[`` as
        # literal source text rather than rejecting the entire string. Return
        # ``None`` so callers can fall through to the leading-backslash branch
        # (``parse_wl_string_literal`` re-emits the source verbatim). For
        # identifier-position parsing, use ``decode_named_character_escape_strict``
        # below instead.
        return None
    name = text[index + 2 : end]
    character = named_character(name)
    if character is None:
        # Unknown / empty named character escapes inside string literals are
        # preserved verbatim by the kernel rather than rejected. Let callers
        # decide whether to fall through (string-literal path) or hard-fail
        # (identifier path); see decode_named_character_escape_strict below.
        return None
    return character, end + 1


def decode_named_character_escape_strict(text: str, index: int) -> tuple[str, int] | None:
    """Strict variant of ``decode_named_character_escape``.

    Used in identifier-position parsing where the kernel rejects unknown
    named-character escapes outright. Raises ``ValueError`` for unrecognized
    or empty names; otherwise returns ``(character, new_index)``.
    """
    if not text.startswith("\\[", index):
        return None
    end = text.find("]", index + 2)
    if end < 0:
        raise ValueError(f"Unterminated Wolfram named character escape at offset {index}.")
    name = text[index + 2 : end]
    character = named_character(name)
    if character is None:
        raise ValueError(f"Unknown Wolfram named character escape \\[{name}].")
    return character, end + 1
