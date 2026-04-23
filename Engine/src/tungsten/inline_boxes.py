from __future__ import annotations

from pathlib import Path

from .notebook import NotebookCell
from .notebook import NotebookDocument
from .notebook import NotebookRawItem
from .notebook import extract_box_expressions
from .notebook import parse_call
from .wolfram_strings import compose_inline_box_string
from .wolfram_strings import compose_inline_box_string_literal
from .wolfram_strings import inline_box_escape
from .wolfram_strings import split_inline_boxes
from .wolfram_strings import wl_string


def compose_inline_box_payload(
    *,
    box_expressions: list[str],
    prefix: str = "",
    suffix: str = "",
) -> dict[str, object]:
    boxes = [_box_record(index, box_expression) for index, box_expression in enumerate(box_expressions)]
    string_value = compose_inline_box_string(
        prefix=prefix,
        box_expressions=box_expressions,
        suffix=suffix,
    )
    string_literal = compose_inline_box_string_literal(
        prefix=prefix,
        box_expressions=box_expressions,
        suffix=suffix,
    )

    return {
        "success": True,
        "prefix": prefix,
        "suffix": suffix,
        "box_count": len(boxes),
        "boxes": boxes,
        "string_value": string_value,
        "string_literal": string_literal,
        "string_segments": [segment.to_dict() for segment in split_inline_boxes(string_value)],
    }


def extract_inline_boxes_from_notebook_cell(
    *,
    notebook_path: Path,
    cell_index: int | None = None,
    cell_path: list[int] | None = None,
    expression_uuid: str | None = None,
    cell_id: int | None = None,
    cell_tag: str | None = None,
    prefix: str = "",
    suffix: str = "",
    object_index: int = 0,
    all_objects: bool = False,
) -> dict[str, object]:
    document = NotebookDocument.load(notebook_path)
    row = _resolve_row(
        document=document,
        cell_index=cell_index,
        cell_path=cell_path,
        expression_uuid=expression_uuid,
        cell_id=cell_id,
        cell_tag=cell_tag,
    )
    item = document.item_at_path([int(value) for value in row["path"]])

    if isinstance(item, NotebookCell):
        source_expr = item.content_expr
    elif isinstance(item, NotebookRawItem):
        source_expr = item.expression
    else:  # pragma: no cover - flattened cells should never resolve to groups
        return {
            "success": False,
            "error_type": "UnsupportedNotebookItem",
            "error": "The requested notebook selector did not resolve to a notebook cell item.",
            "source_cell": row,
        }

    box_expressions = extract_box_expressions(source_expr)
    if not box_expressions:
        return {
            "success": False,
            "error_type": "NoInlineBoxObjectsFound",
            "error": "The selected notebook cell did not contain any inline box objects or box-bearing string escapes.",
            "source_cell": row,
        }

    available_boxes = [
        _box_record(index, box_expression)
        for index, box_expression in enumerate(box_expressions)
    ]

    if all_objects:
        selected_expressions = box_expressions
        selected_boxes = available_boxes
        selection_mode = "all"
    else:
        if object_index < 0 or object_index >= len(box_expressions):
            return {
                "success": False,
                "error_type": "InlineBoxObjectIndexOutOfRange",
                "error": f"Requested object index {object_index}, but the selected cell only contains {len(box_expressions)} inline box object(s).",
                "source_cell": row,
                "available_box_count": len(box_expressions),
            }
        selected_expressions = [box_expressions[object_index]]
        selected_boxes = [available_boxes[object_index]]
        selection_mode = "index"

    composed = compose_inline_box_payload(
        box_expressions=selected_expressions,
        prefix=prefix,
        suffix=suffix,
    )

    return {
        "success": True,
        "notebook_path": str(notebook_path.resolve()),
        "source_cell": row,
        "selection_mode": selection_mode,
        "object_index": None if all_objects else object_index,
        "available_box_count": len(box_expressions),
        "available_boxes": available_boxes,
        "selected_box_count": len(selected_expressions),
        "selected_boxes": selected_boxes,
        "prefix": prefix,
        "suffix": suffix,
        "string_value": composed["string_value"],
        "string_literal": composed["string_literal"],
        "string_segments": composed["string_segments"],
    }


def _resolve_row(
    *,
    document: NotebookDocument,
    cell_index: int | None,
    cell_path: list[int] | None,
    expression_uuid: str | None,
    cell_id: int | None,
    cell_tag: str | None,
) -> dict[str, object]:
    selector_count = sum(
        value is not None
        for value in (cell_index, cell_path, expression_uuid, cell_id, cell_tag)
    )
    if selector_count != 1:
        raise ValueError(
            "Exactly one cell selector must be provided: cell index, cell path, expression UUID, cell ID, or cell tag."
        )

    if cell_index is not None:
        return document.cell_at_flat_index(cell_index)

    if cell_path is not None:
        return document.cell_at_path(cell_path)

    rows = document.flattened_cells()
    if expression_uuid is not None:
        matches = [row for row in rows if row.get("expression_uuid") == expression_uuid]
    elif cell_id is not None:
        matches = [row for row in rows if row.get("cell_id") == int(cell_id)]
    else:
        assert cell_tag is not None
        matches = [
            row
            for row in rows
            if isinstance(row.get("cell_tags"), list) and cell_tag in row["cell_tags"]
        ]

    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise ValueError("The requested notebook cell selector did not match any cell in the notebook file.")
    raise ValueError("The requested notebook cell selector matched more than one cell in the notebook file.")


def _box_record(index: int, box_expression: str) -> dict[str, object]:
    head, _ = parse_call(box_expression)
    return {
        "index": index,
        "head": head or None,
        "box_expression": box_expression,
        "inline_box_escape": inline_box_escape(box_expression),
        "string_literal": wl_string(inline_box_escape(box_expression)),
    }
