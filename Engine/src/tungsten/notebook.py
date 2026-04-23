from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from .wolfram_strings import display_text as display_wl_string
from .wolfram_strings import inline_box_segments
from .wolfram_strings import parse_wl_string_literal
from .wolfram_strings import skip_wl_comment
from .wolfram_strings import skip_wl_string
from .wolfram_strings import wl_string


def extract_string_literals(text: str) -> list[str]:
    literals: list[str] = []
    index = 0
    while index < len(text):
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue

        if text[index] == "\"":
            start = index
            index = skip_wl_string(text, index)
            literals.append(parse_wl_string_literal(text[start:index]))
            continue

        index += 1

    return literals


def collapse_text(text: str, limit: int = 160) -> str:
    collapsed = re.sub(r"\s+", " ", text).strip()
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1].rstrip() + "…"


def _skip_ws_comments(text: str, index: int) -> int:
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        break
    return index


def _find_matching(text: str, index: int, open_char: str, close_char: str) -> int:
    depth = 1
    index += 1
    while index < len(text):
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        if text[index] == "\"":
            index = skip_wl_string(text, index)
            continue
        if text[index] == open_char:
            depth += 1
        elif text[index] == close_char:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError(f"Unmatched {open_char!r} in Wolfram expression.")


def split_top_level(text: str) -> list[str]:
    parts: list[str] = []
    start = 0
    index = 0
    stack: list[str] = []
    while index < len(text):
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        if text[index] == "\"":
            index = skip_wl_string(text, index)
            continue

        char = text[index]
        if char in "[{(":
            stack.append(char)
        elif char in "]})":
            if stack:
                stack.pop()
        elif char == "," and not stack:
            parts.append(text[start:index].strip())
            start = index + 1
        index += 1

    tail = text[start:].strip()
    if tail:
        parts.append(tail)

    return parts


def parse_call(expr: str) -> tuple[str, list[str]]:
    expr = expr.strip()
    index = _skip_ws_comments(expr, 0)
    while index < len(expr):
        if expr[index] == "\"":
            index = skip_wl_string(expr, index)
            continue
        if expr.startswith("(*", index):
            index = skip_wl_comment(expr, index)
            continue
        if expr[index] == "[":
            head = expr[:index].strip()
            close_index = _find_matching(expr, index, "[", "]")
            tail_index = _skip_ws_comments(expr, close_index + 1)
            if tail_index != len(expr):
                return expr, []
            body = expr[index + 1 : close_index]
            return head, split_top_level(body)
        index += 1

    return expr, []


def parse_list(expr: str) -> list[str]:
    expr = expr.strip()
    if not expr.startswith("{") or not expr.endswith("}"):
        return []
    return split_top_level(expr[1:-1])


def extract_box_expressions(expr: str) -> list[str]:
    collected: list[str] = []
    _extract_box_expressions_into(expr, collected)

    deduped: list[str] = []
    seen: set[str] = set()
    for item in collected:
        normalized = item.strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        deduped.append(normalized)
    return deduped


def _extract_box_expressions_into(expr: str, collected: list[str]) -> None:
    text = expr.strip()
    if not text:
        return

    if text.startswith("\"") and text.endswith("\""):
        value = parse_wl_string_literal(text)
        for segment in inline_box_segments(value):
            collected.append(segment.box_expression)
        return

    head, args = parse_call(text)
    if head == "BoxData" and args:
        collected.append(args[0].strip())
        return

    if head and head.endswith("Box") and head != "BoxData":
        collected.append(text)
        return

    if head in {"TextData", "Row", "List"} and args:
        for arg in args:
            if arg.startswith("{") and arg.endswith("}"):
                for item in parse_list(arg):
                    _extract_box_expressions_into(item, collected)
            else:
                _extract_box_expressions_into(arg, collected)
        return

    if head == "Cell" and args:
        _extract_box_expressions_into(args[0], collected)
        return

    if text.startswith("{") and text.endswith("}"):
        for item in parse_list(text):
            _extract_box_expressions_into(item, collected)
        return


def rule_value(options: Iterable[str], name: str) -> str | None:
    prefix = f"{name}->"
    for option in options:
        compact = option.replace(" ", "")
        if compact.startswith(prefix):
            return option.split("->", 1)[1].strip()
    return None


def _string_list_value(expr: str | None) -> list[str]:
    if expr is None:
        return []

    expr = expr.strip()
    if not expr:
        return []

    if expr.startswith("\"") and expr.endswith("\""):
        return [parse_wl_string_literal(expr)]

    values = []
    for item in parse_list(expr):
        item = item.strip()
        if item.startswith("\"") and item.endswith("\""):
            values.append(parse_wl_string_literal(item))
    return values


@dataclass
class NotebookCell:
    content_expr: str
    style: str | None = None
    options: list[str] = field(default_factory=list)
    raw: str | None = None

    @property
    def kind(self) -> str:
        return "cell"

    def plain_text(self) -> str:
        display_fragments = [display_wl_string(value) for value in extract_string_literals(self.content_expr)]
        return collapse_text(" ".join(display_fragments))

    @property
    def cell_id(self) -> int | None:
        value = rule_value(self.options, "CellID")
        if value is None:
            return None
        try:
            return int(value.strip())
        except ValueError:
            return None

    @property
    def expression_uuid(self) -> str | None:
        value = rule_value(self.options, "ExpressionUUID")
        if value is None:
            return None
        return parse_wl_string_literal(value)

    @property
    def cell_tags(self) -> list[str]:
        return _string_list_value(rule_value(self.options, "CellTags"))

    def to_dict(self, path: list[int], depth: int, index: int | None = None) -> dict[str, object]:
        return {
            "index": index,
            "kind": self.kind,
            "path": path,
            "depth": depth,
            "style": self.style,
            "preview": self.plain_text(),
            "cell_id": self.cell_id,
            "expression_uuid": self.expression_uuid,
            "cell_tags": self.cell_tags,
            "options": self.options,
        }

    def render(self) -> str:
        if self.raw is not None:
            return self.raw

        parts = [self.content_expr]
        if self.style is not None:
            parts.append(wl_string(self.style))
        parts.extend(self.options)
        return f"Cell[{', '.join(parts)}]"


@dataclass
class NotebookGroup:
    children: list["NotebookItem"]
    group_tail: list[str] = field(default_factory=list)
    wrapper_options: list[str] = field(default_factory=list)
    raw: str | None = None

    @property
    def kind(self) -> str:
        return "group"

    def render(self) -> str:
        if self.raw is not None:
            return self.raw

        group_parts = [
            "{\n" + ",\n".join(child.render() for child in self.children) + "\n}"
        ]
        group_parts.extend(self.group_tail)
        cell_parts = [f"CellGroupData[{', '.join(group_parts)}]"]
        cell_parts.extend(self.wrapper_options)
        return f"Cell[{', '.join(cell_parts)}]"


@dataclass
class NotebookRawItem:
    expression: str

    @property
    def kind(self) -> str:
        return "raw"

    def render(self) -> str:
        return self.expression

    def to_dict(self, path: list[int], depth: int, index: int | None = None) -> dict[str, object]:
        return {
            "index": index,
            "kind": self.kind,
            "path": path,
            "depth": depth,
            "preview": collapse_text(self.expression),
        }


NotebookItem = NotebookCell | NotebookGroup | NotebookRawItem


def _parse_cell(expr: str) -> NotebookCell | NotebookGroup:
    head, args = parse_call(expr)
    if head != "Cell":
        return NotebookRawItem(expr)

    if args:
        group_head, group_args = parse_call(args[0])
        if group_head == "CellGroupData" and group_args:
            children = [_parse_item(item) for item in parse_list(group_args[0])]
            return NotebookGroup(
                children=children,
                group_tail=group_args[1:],
                wrapper_options=args[1:],
                raw=expr,
            )

    style: str | None = None
    options: list[str] = []
    content_expr = args[0] if args else wl_string("")
    remaining = args[1:] if len(args) > 1 else []
    if remaining and "->" not in remaining[0]:
        style = parse_wl_string_literal(remaining[0])
        options = remaining[1:]
    else:
        options = remaining

    return NotebookCell(
        content_expr=content_expr,
        style=style,
        options=options,
        raw=expr,
    )


def _parse_item(expr: str) -> NotebookItem:
    head, _ = parse_call(expr)
    if head == "Cell":
        return _parse_cell(expr)
    return NotebookRawItem(expr)


@dataclass
class NotebookDocument:
    items: list[NotebookItem]
    options: list[str] = field(default_factory=list)
    preamble: str = ""
    path: Path | None = None

    @classmethod
    def from_text(cls, text: str, path: Path | None = None) -> "NotebookDocument":
        notebook_start = text.find("Notebook[")
        if notebook_start < 0:
            raise ValueError("Notebook expression not found.")

        preamble = text[:notebook_start]
        expr = text[notebook_start:].strip()
        head, args = parse_call(expr)
        if head != "Notebook":
            raise ValueError("Top-level expression is not a Notebook.")

        items = [_parse_item(item) for item in parse_list(args[0] if args else "{}")]
        options = args[1:] if len(args) > 1 else []
        return cls(items=items, options=options, preamble=preamble, path=path)

    @classmethod
    def load(cls, path: Path) -> "NotebookDocument":
        return cls.from_text(path.read_text(encoding="utf-8", errors="replace"), path=path)

    @property
    def title(self) -> str | None:
        value = rule_value(self.options, "WindowTitle")
        if value is None:
            return self.path.stem if self.path else None
        return parse_wl_string_literal(value)

    def to_dict(self) -> dict[str, object]:
        flattened = self.flattened_cells()
        group_count = sum(1 for item in self.walk_items() if isinstance(item[1], NotebookGroup))
        return {
            "path": str(self.path) if self.path else None,
            "title": self.title,
            "cell_count": len(flattened),
            "group_count": group_count,
            "options": self.options,
            "cells": flattened,
        }

    def walk_items(
        self,
        items: list[NotebookItem] | None = None,
        prefix: list[int] | None = None,
        depth: int = 0,
    ) -> Iterable[tuple[list[int], NotebookItem, int]]:
        current_items = self.items if items is None else items
        current_prefix = [] if prefix is None else prefix
        for index, item in enumerate(current_items):
            path = [*current_prefix, index]
            yield path, item, depth
            if isinstance(item, NotebookGroup):
                yield from self.walk_items(
                    items=item.children,
                    prefix=path,
                    depth=depth + 1,
                )

    def flattened_cells(self) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for path, item, depth in self.walk_items():
            index = len(rows)
            if isinstance(item, NotebookCell):
                rows.append(item.to_dict(path=path, depth=depth, index=index))
            elif isinstance(item, NotebookRawItem):
                rows.append(item.to_dict(path=path, depth=depth, index=index))
        return rows

    def cell_at_flat_index(self, index: int) -> dict[str, object]:
        rows = self.flattened_cells()
        if index < 0 or index >= len(rows):
            raise IndexError(f"Cell index {index} is out of range for notebook with {len(rows)} cells.")
        return rows[index]

    def cell_at_path(self, path: list[int]) -> dict[str, object]:
        target = [int(value) for value in path]
        for row in self.flattened_cells():
            if row["path"] == target:
                return row
        raise KeyError(f"Notebook cell path {target!r} was not found.")

    def item_at_path(self, path: list[int]) -> NotebookItem:
        if not path:
            raise KeyError("Notebook item lookup requires a non-empty path.")

        item: NotebookItem | None = None
        container = self.items
        for depth, index in enumerate(path):
            if index < 0 or index >= len(container):
                raise KeyError(f"Notebook item path {path!r} was not found.")
            item = container[index]
            if depth < len(path) - 1:
                if not isinstance(item, NotebookGroup):
                    raise KeyError(f"Notebook item path {path!r} does not resolve through a group.")
                container = item.children

        assert item is not None
        return item

    def item_at_flat_index(self, index: int) -> NotebookItem:
        row = self.cell_at_flat_index(index)
        return self.item_at_path([int(value) for value in row["path"]])

    def render(self) -> str:
        rendered_items = ",\n".join(item.render() for item in self.items)
        args = [f"{{\n{rendered_items}\n}}"]
        args.extend(self.options)
        return f"{self.preamble}Notebook[{', '.join(args)}]\n"

    def save(self, path: Path | None = None) -> Path:
        target = path or self.path
        if target is None:
            raise ValueError("A destination path is required to save the notebook.")
        target.write_text(self.render(), encoding="utf-8")
        self.path = target
        return target

    def _resolve_container(self, path: list[int] | None) -> list[NotebookItem]:
        if not path:
            return self.items

        container = self.items
        current: NotebookItem | None = None
        for index in path:
            current = container[index]
            if not isinstance(current, NotebookGroup):
                raise ValueError(f"Path {path!r} does not identify a notebook group.")
            container = current.children
        return container

    def _replace_raw_ancestors(self, path: list[int]) -> None:
        container = self.items
        current: NotebookItem | None = None
        for index in path:
            current = container[index]
            if isinstance(current, NotebookGroup):
                current.raw = None
                container = current.children

    def append_cell(
        self,
        text: str | None = None,
        style: str | None = "Text",
        content_expr: str | None = None,
        container_path: list[int] | None = None,
    ) -> NotebookCell:
        container = self._resolve_container(container_path)
        content = content_expr if content_expr is not None else wl_string(text or "")
        cell = NotebookCell(content_expr=content, style=style, raw=None)
        container.append(cell)
        if container_path:
            self._replace_raw_ancestors(container_path)
        return cell

    def insert_cell(
        self,
        index: int,
        text: str | None = None,
        style: str | None = "Text",
        content_expr: str | None = None,
        container_path: list[int] | None = None,
    ) -> NotebookCell:
        container = self._resolve_container(container_path)
        content = content_expr if content_expr is not None else wl_string(text or "")
        cell = NotebookCell(content_expr=content, style=style, raw=None)
        container.insert(index, cell)
        if container_path:
            self._replace_raw_ancestors(container_path)
        return cell

    def replace_cell(
        self,
        path: list[int],
        text: str | None = None,
        style: str | None = None,
        content_expr: str | None = None,
    ) -> NotebookCell:
        if not path:
            raise ValueError("Cell replacement requires a non-empty path.")
        container = self._resolve_container(path[:-1])
        existing = container[path[-1]]
        if not isinstance(existing, (NotebookCell, NotebookRawItem)):
            raise ValueError("replace_cell expects a cell or raw item target.")

        new_style = style
        if new_style is None and isinstance(existing, NotebookCell):
            new_style = existing.style
        content = content_expr if content_expr is not None else wl_string(text or "")
        replacement = NotebookCell(content_expr=content, style=new_style, raw=None)
        container[path[-1]] = replacement
        self._replace_raw_ancestors(path[:-1])
        return replacement

    def delete_item(self, path: list[int]) -> None:
        if not path:
            raise ValueError("Deletion requires a non-empty path.")
        container = self._resolve_container(path[:-1])
        del container[path[-1]]
        self._replace_raw_ancestors(path[:-1])

    def set_option(self, name: str, value_expr: str) -> None:
        replacement = f"{name}->{value_expr}"
        for index, option in enumerate(self.options):
            compact = option.replace(" ", "")
            if compact.startswith(f"{name}->"):
                self.options[index] = replacement
                return
        self.options.append(replacement)


def load_patch_spec(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def apply_patch_spec(document: NotebookDocument, spec: dict[str, object]) -> NotebookDocument:
    operations = spec.get("operations", [])
    if not isinstance(operations, list):
        raise ValueError("Patch specification must contain an operations list.")

    for operation in operations:
        if not isinstance(operation, dict):
            raise ValueError("Patch operations must be JSON objects.")

        op = str(operation.get("op", "")).strip()
        path = operation.get("path")
        if path is not None and not isinstance(path, list):
            raise ValueError("Patch operation paths must be arrays of integers.")

        container_path = operation.get("container_path")
        if container_path is not None and not isinstance(container_path, list):
            raise ValueError("Patch operation container_path values must be arrays of integers.")

        text = operation.get("text")
        style = operation.get("style")
        content_expr = operation.get("content_expr")

        if op == "append_cell":
            document.append_cell(
                text=text if isinstance(text, str) else None,
                style=style if isinstance(style, str) else "Text",
                content_expr=content_expr if isinstance(content_expr, str) else None,
                container_path=container_path if isinstance(container_path, list) else None,
            )
            continue

        if op == "insert_cell":
            index = int(operation["index"])
            document.insert_cell(
                index=index,
                text=text if isinstance(text, str) else None,
                style=style if isinstance(style, str) else "Text",
                content_expr=content_expr if isinstance(content_expr, str) else None,
                container_path=container_path if isinstance(container_path, list) else None,
            )
            continue

        if op == "replace_cell":
            if not isinstance(path, list):
                raise ValueError("replace_cell requires a path.")
            document.replace_cell(
                path=[int(value) for value in path],
                text=text if isinstance(text, str) else None,
                style=style if isinstance(style, str) else None,
                content_expr=content_expr if isinstance(content_expr, str) else None,
            )
            continue

        if op == "delete_item":
            if not isinstance(path, list):
                raise ValueError("delete_item requires a path.")
            document.delete_item([int(value) for value in path])
            continue

        if op == "set_option":
            name = str(operation["name"])
            value_expr = str(operation["value_expr"])
            document.set_option(name, value_expr)
            continue

        raise ValueError(f"Unsupported patch operation: {op!r}")

    return document
