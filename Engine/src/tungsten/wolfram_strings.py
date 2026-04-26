from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


INLINE_BOX_PREFIX = r"\!\(\*"
INLINE_BOX_OPEN = r"\("
INLINE_BOX_CLOSE = r"\)"


@dataclass(frozen=True)
class StringTextSegment:
    text: str

    @property
    def kind(self) -> str:
        return "text"

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "text": self.text,
        }


@dataclass(frozen=True)
class StringInlineBoxSegment:
    box_expression: str
    source: str

    @property
    def kind(self) -> str:
        return "inline_box"

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "box_expression": self.box_expression,
            "inline_box_escape": self.source,
        }


WolframStringSegment = StringTextSegment | StringInlineBoxSegment


def wl_string(value: str) -> str:
    """Encode a Python string as a Wolfram string literal.

    The escaping here is intentionally narrow. Tungsten mostly uses this helper for paths,
    prompts, JSON blobs, and other trusted short text where preserving Wolfram-specific
    escapes such as ``\\[Pi]`` and inline box syntax ``\\!\\(\\*...\\)`` is more important
    than aggressively normalizing every control character.
    """
    escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
    escaped = escaped.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    return f"\"{escaped}\""


def parse_wl_string_literal(value: str) -> str:
    text = value
    if len(text) >= 2 and text[0] == "\"" and text[-1] == "\"":
        text = text[1:-1]

    result: list[str] = []
    index = 0
    while index < len(text):
        if text[index] != "\\" or index + 1 >= len(text):
            result.append(text[index])
            index += 1
            continue

        escape = text[index + 1]
        if escape == "r":
            result.append("\r")
        elif escape == "n":
            result.append("\n")
        elif escape == "t":
            result.append("\t")
        elif escape == "\\":
            result.append("\\")
        elif escape == "\"":
            result.append("\"")
        else:
            # Preserve unknown escapes exactly so Tungsten can round-trip things like
            # embedded box syntax \!\(\*GraphicsBox[...]\).
            result.append("\\" + escape)
        index += 2

    return "".join(result)


def inline_box_escape(box_expression: str) -> str:
    return f"{INLINE_BOX_PREFIX}{box_expression}{INLINE_BOX_CLOSE}"


def compose_inline_box_string(
    *,
    prefix: str = "",
    box_expressions: Iterable[str] = (),
    suffix: str = "",
) -> str:
    parts = [prefix]
    parts.extend(inline_box_escape(box_expression) for box_expression in box_expressions)
    parts.append(suffix)
    return "".join(parts)


def compose_inline_box_string_literal(
    *,
    prefix: str = "",
    box_expressions: Iterable[str] = (),
    suffix: str = "",
) -> str:
    return wl_string(
        compose_inline_box_string(
            prefix=prefix,
            box_expressions=box_expressions,
            suffix=suffix,
        )
    )


def split_inline_boxes(value: str) -> tuple[WolframStringSegment, ...]:
    segments: list[WolframStringSegment] = []
    text_parts: list[str] = []
    index = 0

    while index < len(value):
        if value.startswith(INLINE_BOX_PREFIX, index):
            parsed = _parse_inline_box_segment(value, index)
            if parsed is not None:
                segment, index = parsed
                if text_parts:
                    segments.append(StringTextSegment("".join(text_parts)))
                    text_parts = []
                segments.append(segment)
                continue

        text_parts.append(value[index])
        index += 1

    if text_parts:
        segments.append(StringTextSegment("".join(text_parts)))

    return tuple(segments)


def inline_box_segments(value: str) -> tuple[StringInlineBoxSegment, ...]:
    return tuple(
        segment
        for segment in split_inline_boxes(value)
        if isinstance(segment, StringInlineBoxSegment)
    )


def has_inline_boxes(value: str) -> bool:
    return any(isinstance(segment, StringInlineBoxSegment) for segment in split_inline_boxes(value))


def display_text(value: str, *, placeholder: str = "[InlineBox]") -> str:
    parts: list[str] = []
    for segment in split_inline_boxes(value):
        if isinstance(segment, StringTextSegment):
            parts.append(segment.text)
        else:
            parts.append(placeholder)
    return "".join(parts)


def _parse_inline_box_segment(value: str, start: int) -> tuple[StringInlineBoxSegment, int] | None:
    if not value.startswith(INLINE_BOX_PREFIX, start):
        return None

    index = start + len(INLINE_BOX_PREFIX)
    depth = 1
    while index < len(value):
        if value.startswith(INLINE_BOX_OPEN, index):
            depth += 1
            index += len(INLINE_BOX_OPEN)
            continue

        if value.startswith(INLINE_BOX_CLOSE, index):
            depth -= 1
            index += len(INLINE_BOX_CLOSE)
            if depth == 0:
                raw = value[start:index]
                box_expression = raw[len(INLINE_BOX_PREFIX) : -len(INLINE_BOX_CLOSE)]
                return StringInlineBoxSegment(box_expression=box_expression, source=raw), index
            continue

        if value[index] == "\"":
            index = skip_wl_string(value, index)
            continue

        if value.startswith("(*", index):
            index = skip_wl_comment(value, index)
            continue

        index += 1

    return None


def skip_wl_string(text: str, index: int) -> int:
    index += 1
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == "\"":
            return index + 1
        index += 1
    return index


def skip_wl_comment(text: str, index: int) -> int:
    depth = 1
    index += 2
    length = len(text)
    while index < length and depth > 0:
        char = text[index]
        if char == "(" and index + 1 < length and text[index + 1] == "*":
            depth += 1
            index += 2
            continue
        if char == "*" and index + 1 < length and text[index + 1] == ")":
            depth -= 1
            index += 2
            continue
        index += 1
    return index
