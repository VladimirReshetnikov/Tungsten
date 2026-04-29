from __future__ import annotations

from dataclasses import dataclass

from .errors import TungieSyntaxError


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int


_TWO_CHAR_OPERATORS = {
    "&&",
    "||",
    "<=",
    ">=",
    "==",
    "!=",
}

_SINGLE_CHAR_OPERATORS = set("+-*/^=<>!()[]{};,")


def lex(source: str) -> list[Token]:
    tokens: list[Token] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char.isspace():
            index += 1
            continue
        if source.startswith("(*", index):
            index = _skip_comment(source, index)
            continue
        if char == '"':
            raise TungieSyntaxError("Strings are not supported in Tungie.")
        if source.startswith("->", index) or source.startswith(":>", index):
            raise TungieSyntaxError("Rules are not supported in Tungie.")
        if char.isdigit() or (char == "." and index + 1 < len(source) and source[index + 1].isdigit()):
            token, index = _scan_number(source, index)
            tokens.append(token)
            continue
        if _is_symbol_start(char):
            token, index = _scan_symbol(source, index)
            tokens.append(token)
            continue
        if char == "%":
            token, index = _scan_history(source, index)
            tokens.append(token)
            continue
        two = source[index : index + 2]
        if two in _TWO_CHAR_OPERATORS:
            tokens.append(Token("operator", two, index, index + 2))
            index += 2
            continue
        if char in {"*", "/"} and index + 1 < len(source) and source[index + 1] == "^":
            token, index = _scan_scale_operator(source, index)
            tokens.append(token)
            continue
        if char in _SINGLE_CHAR_OPERATORS:
            tokens.append(Token("operator", char, index, index + 1))
            index += 1
            continue
        raise TungieSyntaxError(f"Unexpected character {char!r} at offset {index}.")

    tokens.append(Token("eof", "", len(source), len(source)))
    return tokens


def _skip_comment(source: str, start: int) -> int:
    depth = 1
    index = start + 2
    while index < len(source):
        if source.startswith("(*", index):
            depth += 1
            index += 2
            continue
        if source.startswith("*)", index):
            depth -= 1
            index += 2
            if depth == 0:
                return index
            continue
        index += 1
    raise TungieSyntaxError("Unterminated comment.")


def _scan_number(source: str, start: int) -> tuple[Token, int]:
    if source.startswith("^^", start):
        raise TungieSyntaxError("Base-form integer literals are not supported.")

    index = start
    saw_dot = False
    saw_digits = False

    while index < len(source) and source[index].isdigit():
        saw_digits = True
        index += 1

    if source.startswith("^^", index):
        raise TungieSyntaxError("Base-form integer literals are not supported.")

    if index < len(source) and source[index] == ".":
        saw_dot = True
        index += 1
        while index < len(source) and source[index].isdigit():
            saw_digits = True
            index += 1

    if not saw_digits:
        raise TungieSyntaxError(f"Malformed number near {source[start:start + 8]!r}.")

    saw_precision = False
    if index < len(source) and source[index] == "`":
        saw_precision = True
        index += 1
        if index < len(source) and source[index] == "`":
            index += 1
        index = _scan_optional_decimal_digits(source, index)

    saw_magnitude = False
    normalized_text: str | None = None
    if source.startswith("*^", index) and not source.startswith("*^^", index):
        saw_magnitude = True
        index += 2
        if index < len(source) and source[index] in "+-":
            index += 1
        magnitude_start = index
        while index < len(source) and source[index].isdigit():
            index += 1
        if index == magnitude_start:
            raise TungieSyntaxError("Scientific notation requires an integer exponent after *^.")
    elif source.startswith("/^", index) and not source.startswith("/^^", index):
        saw_magnitude = True
        operator_start = index
        index += 2
        if index < len(source) and source[index] == "-":
            raise TungieSyntaxError("Negative exponents after /^ are not supported; use *^ instead.")
        if index < len(source) and source[index] == "+":
            index += 1
        magnitude_start = index
        while index < len(source) and source[index].isdigit():
            index += 1
        if index == magnitude_start:
            raise TungieSyntaxError("Reciprocal scientific notation requires an integer exponent after /^.")
        normalized_text = f"{source[start:operator_start]}*^-{source[magnitude_start:index]}"

    text = normalized_text or source[start:index]
    kind = "real" if saw_dot or saw_precision or saw_magnitude else "integer"
    return Token(kind, text, start, index), index


def _scan_scale_operator(source: str, start: int) -> tuple[Token, int]:
    index = start + 1
    while index < len(source) and source[index] == "^":
        index += 1
    return Token("operator", source[start:index], start, index), index


def _scan_optional_decimal_digits(source: str, index: int) -> int:
    if index < len(source) and source[index] in "+-":
        index += 1
    saw_dot = False
    while index < len(source):
        char = source[index]
        if char.isdigit():
            index += 1
            continue
        if char == "." and not saw_dot:
            saw_dot = True
            index += 1
            continue
        break
    return index


def _scan_symbol(source: str, start: int) -> tuple[Token, int]:
    index = start + 1
    while index < len(source) and _is_symbol_continue(source[index]):
        index += 1
    return Token("symbol", source[start:index], start, index), index


def _scan_history(source: str, start: int) -> tuple[Token, int]:
    index = start + 1
    if index < len(source) and source[index] == "%":
        return Token("history", "%%", start, index + 1), index + 1
    while index < len(source) and source[index].isdigit():
        index += 1
    return Token("history", source[start:index], start, index), index


def _is_symbol_start(char: str) -> bool:
    return char.isalpha() or char == "$"


def _is_symbol_continue(char: str) -> bool:
    return char.isalnum() or char in "$_"
