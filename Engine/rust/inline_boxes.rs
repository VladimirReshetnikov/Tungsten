//! Composition and notebook extraction for Wolfram inline-box strings.

use crate::notebook::{
    NotebookDocument, NotebookError, NotebookItem, NotebookRow, extract_box_expressions, parse_call,
};
use crate::wolfram_strings::{
    compose_inline_box_string, compose_inline_box_string_literal, inline_box_escape,
    split_inline_boxes, wl_string,
};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InlineBoxCellSelector {
    FlatIndex(usize),
    Path(Vec<usize>),
    ExpressionUuid(String),
    CellId(i64),
    CellTag(String),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InlineBoxExtractionOptions {
    pub prefix: String,
    pub suffix: String,
    pub object_index: usize,
    pub all_objects: bool,
}

pub fn compose_inline_box_payload(box_expressions: &[String], prefix: &str, suffix: &str) -> Value {
    let boxes = box_expressions
        .iter()
        .enumerate()
        .map(|(index, expression)| box_record(index, expression))
        .collect::<Vec<_>>();
    let string_value =
        compose_inline_box_string(prefix, box_expressions.iter().map(String::as_str), suffix);
    let string_literal = compose_inline_box_string_literal(
        prefix,
        box_expressions.iter().map(String::as_str),
        suffix,
    );
    json!({
        "success": true,
        "prefix": prefix,
        "suffix": suffix,
        "box_count": boxes.len(),
        "boxes": boxes,
        "string_value": string_value,
        "string_literal": string_literal,
        "string_segments": split_inline_boxes(&string_value),
    })
}

pub fn extract_inline_boxes_from_notebook_cell(
    notebook_path: impl AsRef<Path>,
    selector: &InlineBoxCellSelector,
    options: &InlineBoxExtractionOptions,
) -> Result<Value, NotebookError> {
    let notebook_path = notebook_path.as_ref();
    let document = NotebookDocument::load(notebook_path)?;
    let row = resolve_row(&document, selector)?;
    let source_expr = match document.item_at_path(&row.path)? {
        NotebookItem::Cell(cell) => &cell.content_expr,
        NotebookItem::Raw(raw) => &raw.expression,
        NotebookItem::Group(_) => {
            return Ok(json!({
                "success": false,
                "error_type": "UnsupportedNotebookItem",
                "error": "The requested notebook selector did not resolve to a notebook cell item.",
                "source_cell": row.to_value(),
            }));
        }
    };
    let box_expressions = extract_box_expressions(source_expr);
    if box_expressions.is_empty() {
        return Ok(json!({
            "success": false,
            "error_type": "NoInlineBoxObjectsFound",
            "error": "The selected notebook cell did not contain any inline box objects or box-bearing string escapes.",
            "source_cell": row.to_value(),
        }));
    }
    let available_boxes = box_expressions
        .iter()
        .enumerate()
        .map(|(index, expression)| box_record(index, expression))
        .collect::<Vec<_>>();
    let (selected_expressions, selected_boxes, selection_mode, object_index) = if options
        .all_objects
    {
        (
            box_expressions.clone(),
            available_boxes.clone(),
            "all",
            Value::Null,
        )
    } else {
        let Some(expression) = box_expressions.get(options.object_index) else {
            return Ok(json!({
                "success": false,
                "error_type": "InlineBoxObjectIndexOutOfRange",
                "error": format!(
                    "Requested object index {}, but the selected cell only contains {} inline box object(s).",
                    options.object_index,
                    box_expressions.len()
                ),
                "source_cell": row.to_value(),
                "available_box_count": box_expressions.len(),
            }));
        };
        (
            vec![expression.clone()],
            vec![available_boxes[options.object_index].clone()],
            "index",
            json!(options.object_index),
        )
    };
    let composed =
        compose_inline_box_payload(&selected_expressions, &options.prefix, &options.suffix);
    let notebook_path = notebook_path
        .canonicalize()
        .unwrap_or_else(|_| notebook_path.to_path_buf());
    Ok(json!({
        "success": true,
        "notebook_path": notebook_path.to_string_lossy(),
        "source_cell": row.to_value(),
        "selection_mode": selection_mode,
        "object_index": object_index,
        "available_box_count": box_expressions.len(),
        "available_boxes": available_boxes,
        "selected_box_count": selected_expressions.len(),
        "selected_boxes": selected_boxes,
        "prefix": options.prefix,
        "suffix": options.suffix,
        "string_value": composed["string_value"],
        "string_literal": composed["string_literal"],
        "string_segments": composed["string_segments"],
    }))
}

fn resolve_row(
    document: &NotebookDocument,
    selector: &InlineBoxCellSelector,
) -> Result<NotebookRow, NotebookError> {
    match selector {
        InlineBoxCellSelector::FlatIndex(index) => document.cell_at_flat_index(*index),
        InlineBoxCellSelector::Path(path) => document.cell_at_path(path),
        InlineBoxCellSelector::ExpressionUuid(value) => resolve_unique(document, |row| {
            row.expression_uuid.as_deref() == Some(value)
        }),
        InlineBoxCellSelector::CellId(value) => {
            resolve_unique(document, |row| row.cell_id == Some(*value))
        }
        InlineBoxCellSelector::CellTag(value) => {
            resolve_unique(document, |row| row.cell_tags.contains(value))
        }
    }
}

fn resolve_unique(
    document: &NotebookDocument,
    predicate: impl Fn(&NotebookRow) -> bool,
) -> Result<NotebookRow, NotebookError> {
    let mut matches = document.flattened_cells().into_iter().filter(predicate);
    let first = matches.next().ok_or_else(|| {
        NotebookError::InvalidOperation(
            "The requested notebook cell selector did not match any cell in the notebook file."
                .into(),
        )
    })?;
    if matches.next().is_some() {
        return Err(NotebookError::InvalidOperation(
            "The requested notebook cell selector matched more than one cell in the notebook file."
                .into(),
        ));
    }
    Ok(first)
}

fn box_record(index: usize, box_expression: &str) -> Value {
    let head = parse_call(box_expression)
        .ok()
        .map(|(head, _)| head)
        .filter(|head| !head.is_empty());
    let escaped = inline_box_escape(box_expression);
    json!({
        "index": index,
        "head": head,
        "box_expression": box_expression,
        "inline_box_escape": escaped,
        "string_literal": wl_string(&escaped),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    const SAMPLE: &str = r#"Notebook[{
Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-graphic"],
Cell["prefix \!\(\*StyleBox[\"Hello\", FontWeight->Bold]\) suffix", "Text", CellID->2001]
}]"#;

    #[test]
    fn composition_payload_matches_python_shape() {
        let payload =
            compose_inline_box_payload(&["GraphicsBox[{CircleBox[]}]".to_owned()], "icon: ", ".");
        assert_eq!(payload["success"], true);
        assert_eq!(payload["box_count"], 1);
        assert_eq!(payload["boxes"][0]["head"], "GraphicsBox");
        assert_eq!(
            payload["string_value"],
            r"icon: \!\(\*GraphicsBox[{CircleBox[]}]\)."
        );
        assert_eq!(
            payload["string_literal"],
            r#""icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\).""#
        );
    }

    #[test]
    fn extracts_by_uuid_and_cell_id() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("tungsten-inline-{unique}.nb"));
        fs::write(&path, SAMPLE).unwrap();
        let by_uuid = extract_inline_boxes_from_notebook_cell(
            &path,
            &InlineBoxCellSelector::ExpressionUuid("uuid-graphic".into()),
            &InlineBoxExtractionOptions {
                prefix: "icon: ".into(),
                ..InlineBoxExtractionOptions::default()
            },
        )
        .unwrap();
        assert_eq!(by_uuid["available_box_count"], 1);
        assert_eq!(by_uuid["selected_boxes"][0]["head"], "GraphicsBox");
        assert_eq!(
            by_uuid["string_value"],
            r"icon: \!\(\*GraphicsBox[{CircleBox[]}]\)"
        );
        let by_id = extract_inline_boxes_from_notebook_cell(
            &path,
            &InlineBoxCellSelector::CellId(2001),
            &InlineBoxExtractionOptions {
                prefix: "rendered: ".into(),
                all_objects: true,
                ..InlineBoxExtractionOptions::default()
            },
        )
        .unwrap();
        assert_eq!(by_id["selected_box_count"], 1);
        assert_eq!(by_id["selected_boxes"][0]["head"], "StyleBox");
        assert!(by_id["string_value"].as_str().unwrap().contains("StyleBox"));
        fs::remove_file(path).unwrap();
    }
}
