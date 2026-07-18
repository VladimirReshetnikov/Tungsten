//! Kernel-free parsing and source-preserving editing of Wolfram notebook files.

use crate::wolfram_strings::{
    display_text, inline_box_segments, parse_wl_string_literal, wl_string,
};
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum NotebookError {
    #[error("Notebook expression not found.")]
    NotebookExpressionNotFound,
    #[error("Top-level expression is not a Notebook.")]
    NotNotebook,
    #[error("{0}")]
    Syntax(String),
    #[error("{0}")]
    InvalidOperation(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookCell {
    pub content_expr: String,
    pub style: Option<String>,
    pub options: Vec<String>,
    raw: Option<String>,
}

impl NotebookCell {
    pub fn new(content_expr: impl Into<String>, style: Option<String>) -> Self {
        Self {
            content_expr: content_expr.into(),
            style,
            options: Vec::new(),
            raw: None,
        }
    }

    pub fn raw(&self) -> Option<&str> {
        self.raw.as_deref()
    }

    pub fn plain_text(&self) -> String {
        let fragments = extract_string_literals(&self.content_expr)
            .into_iter()
            .map(|value| display_text(&value, "[InlineBox]"))
            .collect::<Vec<_>>()
            .join(" ");
        collapse_text(&fragments, 160)
    }

    pub fn cell_id(&self) -> Option<i64> {
        rule_value(&self.options, "CellID")?.trim().parse().ok()
    }

    pub fn expression_uuid(&self) -> Option<String> {
        parse_wl_string_literal(rule_value(&self.options, "ExpressionUUID")?).ok()
    }

    pub fn cell_tags(&self) -> Vec<String> {
        string_list_value(rule_value(&self.options, "CellTags"))
    }

    pub fn render(&self) -> String {
        if let Some(raw) = &self.raw {
            return raw.clone();
        }
        let mut parts = vec![self.content_expr.clone()];
        if let Some(style) = &self.style {
            parts.push(wl_string(style));
        }
        parts.extend(self.options.clone());
        format!("Cell[{}]", parts.join(", "))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookGroup {
    pub children: Vec<NotebookItem>,
    pub group_tail: Vec<String>,
    pub wrapper_options: Vec<String>,
    raw: Option<String>,
}

impl NotebookGroup {
    pub fn raw(&self) -> Option<&str> {
        self.raw.as_deref()
    }

    pub fn render(&self) -> String {
        if let Some(raw) = &self.raw {
            return raw.clone();
        }
        let children = self
            .children
            .iter()
            .map(NotebookItem::render)
            .collect::<Vec<_>>()
            .join(",\n");
        let mut group_parts = vec![format!("{{\n{children}\n}}")];
        group_parts.extend(self.group_tail.clone());
        let mut cell_parts = vec![format!("CellGroupData[{}]", group_parts.join(", "))];
        cell_parts.extend(self.wrapper_options.clone());
        format!("Cell[{}]", cell_parts.join(", "))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookRawItem {
    pub expression: String,
}

impl NotebookRawItem {
    pub fn render(&self) -> String {
        self.expression.clone()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NotebookItem {
    Cell(NotebookCell),
    Group(NotebookGroup),
    Raw(NotebookRawItem),
}

impl NotebookItem {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Cell(_) => "cell",
            Self::Group(_) => "group",
            Self::Raw(_) => "raw",
        }
    }

    pub fn render(&self) -> String {
        match self {
            Self::Cell(cell) => cell.render(),
            Self::Group(group) => group.render(),
            Self::Raw(raw) => raw.render(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NotebookSummary {
    pub title: Option<String>,
    pub cell_count: usize,
    pub group_count: usize,
    pub option_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookRow {
    pub index: usize,
    pub kind: &'static str,
    pub path: Vec<usize>,
    pub depth: usize,
    pub style: Option<String>,
    pub preview: String,
    pub cell_id: Option<i64>,
    pub expression_uuid: Option<String>,
    pub cell_tags: Vec<String>,
    pub options: Vec<String>,
}

impl NotebookRow {
    pub fn to_value(&self) -> Value {
        let mut value = Map::new();
        value.insert("index".into(), json!(self.index));
        value.insert("kind".into(), json!(self.kind));
        value.insert("path".into(), json!(self.path));
        value.insert("depth".into(), json!(self.depth));
        value.insert("preview".into(), json!(self.preview));
        if self.kind == "cell" {
            value.insert("style".into(), json!(self.style));
            value.insert("cell_id".into(), json!(self.cell_id));
            value.insert("expression_uuid".into(), json!(self.expression_uuid));
            value.insert("cell_tags".into(), json!(self.cell_tags));
            value.insert("options".into(), json!(self.options));
        }
        Value::Object(value)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookDocument {
    pub items: Vec<NotebookItem>,
    pub options: Vec<String>,
    pub preamble: String,
    pub path: Option<PathBuf>,
}

impl NotebookDocument {
    pub fn new(items: Vec<NotebookItem>) -> Self {
        Self {
            items,
            options: Vec::new(),
            preamble: String::new(),
            path: None,
        }
    }

    pub fn from_text(text: &str, path: Option<PathBuf>) -> Result<Self, NotebookError> {
        let notebook_start = text
            .find("Notebook[")
            .ok_or(NotebookError::NotebookExpressionNotFound)?;
        let preamble = text[..notebook_start].to_owned();
        let expression = text[notebook_start..].trim();
        let (head, args) = parse_call(expression)?;
        if head != "Notebook" {
            return Err(NotebookError::NotNotebook);
        }
        let items = if let Some(first) = args.first() {
            parse_list(first)?
                .into_iter()
                .map(|item| parse_item(&item))
                .collect::<Result<_, _>>()?
        } else {
            Vec::new()
        };
        Ok(Self {
            items,
            options: args.into_iter().skip(1).collect(),
            preamble,
            path,
        })
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self, NotebookError> {
        let path = path.as_ref();
        let text = fs::read_to_string(path)?;
        Self::from_text(&text, Some(path.to_path_buf()))
    }

    pub fn title(&self) -> Option<String> {
        if let Some(value) = rule_value(&self.options, "WindowTitle") {
            return parse_wl_string_literal(value).ok();
        }
        self.path
            .as_deref()
            .and_then(Path::file_stem)
            .map(|stem| stem.to_string_lossy().into_owned())
    }

    pub fn summary(&self) -> NotebookSummary {
        let mut cell_count = 0;
        let mut group_count = 0;
        count_items(&self.items, &mut cell_count, &mut group_count);
        NotebookSummary {
            title: self.title(),
            cell_count,
            group_count,
            option_count: self.options.len(),
        }
    }

    pub fn flattened_cells(&self) -> Vec<NotebookRow> {
        let mut rows = Vec::new();
        flatten_items(&self.items, &[], 0, &mut rows);
        rows
    }

    pub fn to_value(&self) -> Value {
        let flattened = self.flattened_cells();
        let group_count = self.summary().group_count;
        json!({
            "path": self.path.as_ref().map(|path| path.to_string_lossy().into_owned()),
            "title": self.title(),
            "cell_count": flattened.len(),
            "group_count": group_count,
            "options": self.options,
            "cells": flattened.iter().map(NotebookRow::to_value).collect::<Vec<_>>(),
        })
    }

    pub fn cell_at_flat_index(&self, index: usize) -> Result<NotebookRow, NotebookError> {
        let rows = self.flattened_cells();
        rows.get(index).cloned().ok_or_else(|| {
            NotebookError::InvalidOperation(format!(
                "Cell index {index} is out of range for notebook with {} cells.",
                rows.len()
            ))
        })
    }

    pub fn cell_at_path(&self, path: &[usize]) -> Result<NotebookRow, NotebookError> {
        self.flattened_cells()
            .into_iter()
            .find(|row| row.path == path)
            .ok_or_else(|| {
                NotebookError::InvalidOperation(format!(
                    "Notebook cell path {path:?} was not found."
                ))
            })
    }

    pub fn item_at_flat_index(&self, index: usize) -> Result<&NotebookItem, NotebookError> {
        let row = self.cell_at_flat_index(index)?;
        self.item_at_path(&row.path)
    }

    pub fn item_at_path(&self, path: &[usize]) -> Result<&NotebookItem, NotebookError> {
        item_at_path(&self.items, path)
    }

    pub fn render(&self) -> String {
        let rendered_items = self
            .items
            .iter()
            .map(NotebookItem::render)
            .collect::<Vec<_>>()
            .join(",\n");
        let mut args = vec![format!("{{\n{rendered_items}\n}}")];
        args.extend(self.options.clone());
        format!("{}Notebook[{}]\n", self.preamble, args.join(", "))
    }

    pub fn save(&mut self, path: Option<&Path>) -> Result<PathBuf, NotebookError> {
        let target = path
            .map(Path::to_path_buf)
            .or_else(|| self.path.clone())
            .ok_or_else(|| {
                NotebookError::InvalidOperation(
                    "A destination path is required to save the notebook.".into(),
                )
            })?;
        fs::write(&target, self.render())?;
        self.path = Some(target.clone());
        Ok(target)
    }

    pub fn append_cell(
        &mut self,
        text: Option<&str>,
        style: Option<&str>,
        content_expr: Option<&str>,
        container_path: Option<&[usize]>,
    ) -> Result<(), NotebookError> {
        let cell = created_cell(text, style, content_expr);
        container_mut(&mut self.items, container_path.unwrap_or_default())?.push(cell);
        clear_raw_ancestors(&mut self.items, container_path.unwrap_or_default())?;
        Ok(())
    }

    pub fn insert_cell(
        &mut self,
        index: usize,
        text: Option<&str>,
        style: Option<&str>,
        content_expr: Option<&str>,
        container_path: Option<&[usize]>,
    ) -> Result<(), NotebookError> {
        let path = container_path.unwrap_or_default();
        let container = container_mut(&mut self.items, path)?;
        if index > container.len() {
            return Err(NotebookError::InvalidOperation(format!(
                "Cell insertion index {index} is out of range."
            )));
        }
        container.insert(index, created_cell(text, style, content_expr));
        clear_raw_ancestors(&mut self.items, path)?;
        Ok(())
    }

    pub fn replace_cell(
        &mut self,
        path: &[usize],
        text: Option<&str>,
        style: Option<&str>,
        content_expr: Option<&str>,
    ) -> Result<(), NotebookError> {
        let (&index, parent_path) = path.split_last().ok_or_else(|| {
            NotebookError::InvalidOperation("Cell replacement requires a non-empty path.".into())
        })?;
        let container = container_mut(&mut self.items, parent_path)?;
        let existing = container.get(index).ok_or_else(|| {
            NotebookError::InvalidOperation(format!("Notebook item path {path:?} was not found."))
        })?;
        let inherited_style = match existing {
            NotebookItem::Cell(cell) => cell.style.as_deref(),
            NotebookItem::Raw(_) => None,
            NotebookItem::Group(_) => {
                return Err(NotebookError::InvalidOperation(
                    "replace_cell expects a cell or raw item target.".into(),
                ));
            }
        };
        let replacement_style = style.or(inherited_style);
        container[index] = created_cell(text, replacement_style, content_expr);
        clear_raw_ancestors(&mut self.items, parent_path)?;
        Ok(())
    }

    pub fn delete_item(&mut self, path: &[usize]) -> Result<(), NotebookError> {
        let (&index, parent_path) = path.split_last().ok_or_else(|| {
            NotebookError::InvalidOperation("Deletion requires a non-empty path.".into())
        })?;
        let container = container_mut(&mut self.items, parent_path)?;
        if index >= container.len() {
            return Err(NotebookError::InvalidOperation(format!(
                "Notebook item path {path:?} was not found."
            )));
        }
        container.remove(index);
        clear_raw_ancestors(&mut self.items, parent_path)?;
        Ok(())
    }

    pub fn set_option(&mut self, name: &str, value_expr: &str) {
        let replacement = format!("{name}->{value_expr}");
        if let Some(option) = self
            .options
            .iter_mut()
            .find(|option| option.replace(' ', "").starts_with(&format!("{name}->")))
        {
            *option = replacement;
        } else {
            self.options.push(replacement);
        }
    }
}

pub fn split_top_level(text: &str) -> Result<Vec<String>, NotebookError> {
    split_top_level_range(text, 0, text.len())
}

pub fn parse_call(expression: &str) -> Result<(String, Vec<String>), NotebookError> {
    let expression = expression.trim();
    let mut index = skip_ws_comments(expression, 0, expression.len());
    while index < expression.len() {
        if starts_comment(expression, index) {
            index = skip_comment(expression, index)?;
            continue;
        }
        match byte(expression, index) {
            Some(b'"') => index = skip_string(expression, index)?,
            Some(b'[') => {
                let head = expression[..index].trim().to_owned();
                let (close, args) = split_call_arguments(expression, index)?;
                let tail = skip_ws_comments(expression, close + 1, expression.len());
                if tail != expression.len() {
                    return Ok((expression.to_owned(), Vec::new()));
                }
                return Ok((head, args));
            }
            Some(_) => index += next_char_len(expression, index),
            None => break,
        }
    }
    Ok((expression.to_owned(), Vec::new()))
}

pub fn parse_list(expression: &str) -> Result<Vec<String>, NotebookError> {
    let expression = expression.trim();
    if !expression.starts_with('{') || !expression.ends_with('}') {
        return Ok(Vec::new());
    }
    split_top_level_range(expression, 1, expression.len() - 1)
}

pub fn extract_string_literals(text: &str) -> Vec<String> {
    let mut literals = Vec::new();
    let mut index = 0;
    while index < text.len() {
        if starts_comment(text, index) {
            index = skip_comment(text, index).unwrap_or(text.len());
            continue;
        }
        if byte(text, index) == Some(b'"') {
            let start = index;
            index = skip_string(text, index).unwrap_or(text.len());
            if let Ok(value) = parse_wl_string_literal(&text[start..index]) {
                literals.push(value);
            }
            continue;
        }
        index += next_char_len(text, index);
    }
    literals
}

pub fn extract_box_expressions(expression: &str) -> Vec<String> {
    let mut collected = Vec::new();
    extract_box_expressions_into(expression, &mut collected);
    let mut deduped = Vec::new();
    for item in collected {
        let normalized = item.trim();
        if !normalized.is_empty() && !deduped.iter().any(|seen| seen == normalized) {
            deduped.push(normalized.to_owned());
        }
    }
    deduped
}

pub fn load_patch_spec(path: impl AsRef<Path>) -> Result<Value, NotebookError> {
    Ok(serde_json::from_str(&fs::read_to_string(path)?)?)
}

pub fn apply_patch_spec(
    document: &mut NotebookDocument,
    spec: &Value,
) -> Result<(), NotebookError> {
    let operations = spec
        .get("operations")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            NotebookError::InvalidOperation(
                "Patch specification must contain an operations list.".into(),
            )
        })?;
    for operation in operations {
        let operation = operation.as_object().ok_or_else(|| {
            NotebookError::InvalidOperation("Patch operations must be JSON objects.".into())
        })?;
        let op = operation
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let path = optional_path(operation.get("path"), "path")?;
        let container_path = optional_path(operation.get("container_path"), "container_path")?;
        let text = operation.get("text").and_then(Value::as_str);
        let content_expr = operation.get("content_expr").and_then(Value::as_str);
        match op {
            "append_cell" => document.append_cell(
                text,
                operation
                    .get("style")
                    .and_then(Value::as_str)
                    .or(Some("Text")),
                content_expr,
                container_path.as_deref(),
            )?,
            "insert_cell" => {
                let index = usize_value(operation.get("index"), "insert_cell requires an index.")?;
                document.insert_cell(
                    index,
                    text,
                    operation
                        .get("style")
                        .and_then(Value::as_str)
                        .or(Some("Text")),
                    content_expr,
                    container_path.as_deref(),
                )?;
            }
            "replace_cell" => document.replace_cell(
                path.as_deref().ok_or_else(|| {
                    NotebookError::InvalidOperation("replace_cell requires a path.".into())
                })?,
                text,
                operation.get("style").and_then(Value::as_str),
                content_expr,
            )?,
            "delete_item" => document.delete_item(path.as_deref().ok_or_else(|| {
                NotebookError::InvalidOperation("delete_item requires a path.".into())
            })?)?,
            "set_option" => {
                let name = operation
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        NotebookError::InvalidOperation("set_option requires a name.".into())
                    })?;
                let value_expr = operation
                    .get("value_expr")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        NotebookError::InvalidOperation("set_option requires a value_expr.".into())
                    })?;
                document.set_option(name, value_expr);
            }
            _ => {
                return Err(NotebookError::InvalidOperation(format!(
                    "Unsupported patch operation: {op:?}"
                )));
            }
        }
    }
    Ok(())
}

fn parse_item(expression: &str) -> Result<NotebookItem, NotebookError> {
    let (head, args) = parse_call(expression)?;
    if head != "Cell" {
        return Ok(NotebookItem::Raw(NotebookRawItem {
            expression: expression.to_owned(),
        }));
    }
    if let Some(first) = args.first()
        && has_call_head(first, "CellGroupData")
    {
        let (group_head, group_args) = parse_call(first)?;
        if group_head == "CellGroupData" && !group_args.is_empty() {
            let children = parse_list(&group_args[0])?
                .into_iter()
                .map(|child| parse_item(&child))
                .collect::<Result<_, _>>()?;
            return Ok(NotebookItem::Group(NotebookGroup {
                children,
                group_tail: group_args.into_iter().skip(1).collect(),
                wrapper_options: args.into_iter().skip(1).collect(),
                raw: Some(expression.to_owned()),
            }));
        }
    }
    let content_expr = args.first().cloned().unwrap_or_else(|| wl_string(""));
    let remaining = args.into_iter().skip(1).collect::<Vec<_>>();
    let (style, options) = if remaining.first().is_some_and(|value| !value.contains("->")) {
        (
            parse_wl_string_literal(&remaining[0]).ok(),
            remaining.into_iter().skip(1).collect(),
        )
    } else {
        (None, remaining)
    };
    Ok(NotebookItem::Cell(NotebookCell {
        content_expr,
        style,
        options,
        raw: Some(expression.to_owned()),
    }))
}

fn has_call_head(expression: &str, expected: &str) -> bool {
    let index = skip_ws_comments(expression, 0, expression.len());
    if !expression[index..].starts_with(expected) {
        return false;
    }
    let bracket = skip_ws_comments(expression, index + expected.len(), expression.len());
    byte(expression, bracket) == Some(b'[')
}

fn extract_box_expressions_into(expression: &str, collected: &mut Vec<String>) {
    let expression = expression.trim();
    if expression.is_empty() {
        return;
    }
    if expression.starts_with('"') && expression.ends_with('"') {
        if let Ok(value) = parse_wl_string_literal(expression) {
            collected.extend(
                inline_box_segments(&value)
                    .into_iter()
                    .map(|(box_expression, _)| box_expression),
            );
        }
        return;
    }
    let Ok((head, args)) = parse_call(expression) else {
        return;
    };
    if head == "BoxData" && !args.is_empty() {
        collected.push(args[0].trim().to_owned());
        return;
    }
    if head.ends_with("Box") && head != "BoxData" {
        collected.push(expression.to_owned());
        return;
    }
    if matches!(head.as_str(), "TextData" | "Row" | "List") && !args.is_empty() {
        for argument in args {
            if argument.starts_with('{') && argument.ends_with('}') {
                if let Ok(items) = parse_list(&argument) {
                    for item in items {
                        extract_box_expressions_into(&item, collected);
                    }
                }
            } else {
                extract_box_expressions_into(&argument, collected);
            }
        }
        return;
    }
    if head == "Cell" && !args.is_empty() {
        extract_box_expressions_into(&args[0], collected);
        return;
    }
    if expression.starts_with('{')
        && expression.ends_with('}')
        && let Ok(items) = parse_list(expression)
    {
        for item in items {
            extract_box_expressions_into(&item, collected);
        }
    }
}

fn flatten_items(
    items: &[NotebookItem],
    prefix: &[usize],
    depth: usize,
    rows: &mut Vec<NotebookRow>,
) {
    for (item_index, item) in items.iter().enumerate() {
        let mut path = prefix.to_vec();
        path.push(item_index);
        match item {
            NotebookItem::Cell(cell) => rows.push(NotebookRow {
                index: rows.len(),
                kind: "cell",
                path,
                depth,
                style: cell.style.clone(),
                preview: cell.plain_text(),
                cell_id: cell.cell_id(),
                expression_uuid: cell.expression_uuid(),
                cell_tags: cell.cell_tags(),
                options: cell.options.clone(),
            }),
            NotebookItem::Group(group) => {
                flatten_items(&group.children, &path, depth + 1, rows);
            }
            NotebookItem::Raw(raw) => rows.push(NotebookRow {
                index: rows.len(),
                kind: "raw",
                path,
                depth,
                style: None,
                preview: collapse_text(&raw.expression, 160),
                cell_id: None,
                expression_uuid: None,
                cell_tags: Vec::new(),
                options: Vec::new(),
            }),
        }
    }
}

fn count_items(items: &[NotebookItem], cell_count: &mut usize, group_count: &mut usize) {
    for item in items {
        match item {
            NotebookItem::Group(group) => {
                *group_count += 1;
                count_items(&group.children, cell_count, group_count);
            }
            NotebookItem::Cell(_) | NotebookItem::Raw(_) => *cell_count += 1,
        }
    }
}

fn created_cell(
    text: Option<&str>,
    style: Option<&str>,
    content_expr: Option<&str>,
) -> NotebookItem {
    NotebookItem::Cell(NotebookCell::new(
        content_expr.map_or_else(|| wl_string(text.unwrap_or_default()), str::to_owned),
        style.map(str::to_owned),
    ))
}

fn item_at_path<'a>(
    items: &'a [NotebookItem],
    path: &[usize],
) -> Result<&'a NotebookItem, NotebookError> {
    let (&index, rest) = path.split_first().ok_or_else(|| {
        NotebookError::InvalidOperation("Notebook item lookup requires a non-empty path.".into())
    })?;
    let item = items.get(index).ok_or_else(|| {
        NotebookError::InvalidOperation(format!("Notebook item path {path:?} was not found."))
    })?;
    if rest.is_empty() {
        return Ok(item);
    }
    match item {
        NotebookItem::Group(group) => item_at_path(&group.children, rest),
        _ => Err(NotebookError::InvalidOperation(format!(
            "Notebook item path {path:?} does not resolve through a group."
        ))),
    }
}

fn container_mut<'a>(
    items: &'a mut Vec<NotebookItem>,
    path: &[usize],
) -> Result<&'a mut Vec<NotebookItem>, NotebookError> {
    let Some((&index, rest)) = path.split_first() else {
        return Ok(items);
    };
    let item = items.get_mut(index).ok_or_else(|| {
        NotebookError::InvalidOperation(format!("Notebook group path {path:?} was not found."))
    })?;
    match item {
        NotebookItem::Group(group) => container_mut(&mut group.children, rest),
        _ => Err(NotebookError::InvalidOperation(format!(
            "Path {path:?} does not identify a notebook group."
        ))),
    }
}

fn clear_raw_ancestors(items: &mut [NotebookItem], path: &[usize]) -> Result<(), NotebookError> {
    let Some((&index, rest)) = path.split_first() else {
        return Ok(());
    };
    let item = items.get_mut(index).ok_or_else(|| {
        NotebookError::InvalidOperation(format!("Notebook group path {path:?} was not found."))
    })?;
    match item {
        NotebookItem::Group(group) => {
            group.raw = None;
            clear_raw_ancestors(&mut group.children, rest)
        }
        _ => Err(NotebookError::InvalidOperation(format!(
            "Path {path:?} does not identify a notebook group."
        ))),
    }
}

fn split_top_level_range(
    text: &str,
    start: usize,
    end: usize,
) -> Result<Vec<String>, NotebookError> {
    let mut parts = Vec::new();
    let mut part_start = start;
    let mut depth = 0_usize;
    let mut index = start;
    while index < end {
        if starts_comment(text, index) {
            index = skip_comment(text, index)?;
            continue;
        }
        match byte(text, index) {
            Some(b'"') => index = skip_string(text, index)?,
            Some(b'[' | b'{' | b'(') => {
                depth += 1;
                index += 1;
            }
            Some(b']' | b'}' | b')') => {
                depth = depth.saturating_sub(1);
                index += 1;
            }
            Some(b',') if depth == 0 => {
                parts.push(text[part_start..index].trim().to_owned());
                part_start = index + 1;
                index += 1;
            }
            Some(_) => index += next_char_len(text, index),
            None => break,
        }
    }
    let tail = text[part_start..end].trim();
    if !tail.is_empty() {
        parts.push(tail.to_owned());
    }
    Ok(parts)
}

fn split_call_arguments(text: &str, open: usize) -> Result<(usize, Vec<String>), NotebookError> {
    let mut parts = Vec::new();
    let mut start = open + 1;
    let mut index = start;
    let mut square_depth = 1_usize;
    let mut nested_depth = 0_usize;
    while index < text.len() {
        if starts_comment(text, index) {
            index = skip_comment(text, index)?;
            continue;
        }
        match byte(text, index) {
            Some(b'"') => index = skip_string(text, index)?,
            Some(b'[') => {
                square_depth += 1;
                nested_depth += 1;
                index += 1;
            }
            Some(b']') => {
                square_depth -= 1;
                if square_depth == 0 {
                    let tail = text[start..index].trim();
                    if !tail.is_empty() {
                        parts.push(tail.to_owned());
                    }
                    return Ok((index, parts));
                }
                nested_depth = nested_depth.saturating_sub(1);
                index += 1;
            }
            Some(b'{' | b'(') => {
                nested_depth += 1;
                index += 1;
            }
            Some(b'}' | b')') => {
                nested_depth = nested_depth.saturating_sub(1);
                index += 1;
            }
            Some(b',') if nested_depth == 0 => {
                parts.push(text[start..index].trim().to_owned());
                start = index + 1;
                index += 1;
            }
            Some(_) => index += next_char_len(text, index),
            None => break,
        }
    }
    Err(NotebookError::Syntax(
        "Unmatched '[' in Wolfram expression.".into(),
    ))
}

fn rule_value<'a>(options: &'a [String], name: &str) -> Option<&'a str> {
    let prefix = format!("{name}->");
    for option in options {
        if option.replace(' ', "").starts_with(&prefix) {
            return option.split_once("->").map(|(_, value)| value.trim());
        }
    }
    None
}

fn string_list_value(expression: Option<&str>) -> Vec<String> {
    let Some(expression) = expression.map(str::trim) else {
        return Vec::new();
    };
    if expression.starts_with('"') && expression.ends_with('"') {
        return parse_wl_string_literal(expression).into_iter().collect();
    }
    parse_list(expression)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| {
            let item = item.trim();
            (item.starts_with('"') && item.ends_with('"'))
                .then(|| parse_wl_string_literal(item).ok())
                .flatten()
        })
        .collect()
}

pub fn collapse_text(text: &str, limit: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= limit {
        return collapsed;
    }
    let mut shortened = collapsed.chars().take(limit - 1).collect::<String>();
    while shortened.ends_with(char::is_whitespace) {
        shortened.pop();
    }
    shortened.push('…');
    shortened
}

fn optional_path(value: Option<&Value>, name: &str) -> Result<Option<Vec<usize>>, NotebookError> {
    let Some(value) = value else {
        return Ok(None);
    };
    let array = value.as_array().ok_or_else(|| {
        NotebookError::InvalidOperation(format!(
            "Patch operation {name} values must be arrays of integers."
        ))
    })?;
    array
        .iter()
        .map(|value| {
            usize_value(
                Some(value),
                "Patch paths must contain non-negative integers.",
            )
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Some)
}

fn usize_value(value: Option<&Value>, error: &str) -> Result<usize, NotebookError> {
    value
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or_else(|| NotebookError::InvalidOperation(error.into()))
}

fn starts_comment(text: &str, index: usize) -> bool {
    text.get(index..).is_some_and(|tail| tail.starts_with("(*"))
}

fn skip_comment(text: &str, start: usize) -> Result<usize, NotebookError> {
    let mut depth = 1_usize;
    let mut index = start + 2;
    while index < text.len() {
        if text[index..].starts_with("(*") {
            depth += 1;
            index += 2;
        } else if text[index..].starts_with("*)") {
            depth -= 1;
            index += 2;
            if depth == 0 {
                return Ok(index);
            }
        } else {
            index += next_char_len(text, index);
        }
    }
    Err(NotebookError::Syntax(
        "Unterminated Wolfram comment.".into(),
    ))
}

fn skip_string(text: &str, start: usize) -> Result<usize, NotebookError> {
    let mut index = start + 1;
    while index < text.len() {
        match byte(text, index) {
            Some(b'\\') => {
                index += 1;
                if index < text.len() {
                    index += next_char_len(text, index);
                }
            }
            Some(b'"') => return Ok(index + 1),
            Some(_) => index += next_char_len(text, index),
            None => break,
        }
    }
    Err(NotebookError::Syntax("Unterminated Wolfram string.".into()))
}

fn skip_ws_comments(text: &str, mut index: usize, end: usize) -> usize {
    while index < end {
        if text[index..].starts_with("(*") {
            index = skip_comment(text, index).unwrap_or(end);
        } else if text[index..]
            .chars()
            .next()
            .is_some_and(char::is_whitespace)
        {
            index += next_char_len(text, index);
        } else {
            break;
        }
    }
    index
}

fn byte(text: &str, index: usize) -> Option<u8> {
    text.as_bytes().get(index).copied()
}

fn next_char_len(text: &str, index: usize) -> usize {
    text[index..].chars().next().map_or(1, char::len_utf8)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_NOTEBOOK: &str = "(* sample header *)\nNotebook[{\nCell[\"Welcome\", \"Title\", CellID->1001, ExpressionUUID->\"uuid-title\", CellTags->{\"intro\", \"top\"}],\nCell[CellGroupData[{\nCell[\"Section A\", \"Section\"],\nCell[\"Body text\", \"Text\"]\n}, Open]],\nCell[\"2+2\", \"Input\"]\n}, WindowTitle->\"Sample Notebook\"]\n";

    #[test]
    fn call_scanner_preserves_edge_cases() {
        assert_eq!(
            parse_call(r#"f[a, g[1, 2], {x, y}, "literal, comma", (* comment, *) h]"#).unwrap(),
            (
                "f".to_owned(),
                vec![
                    "a",
                    "g[1, 2]",
                    "{x, y}",
                    r#""literal, comma""#,
                    "(* comment, *) h",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect()
            )
        );
        assert_eq!(parse_call("f[]").unwrap(), ("f".into(), Vec::new()));
        assert_eq!(parse_call("f[a,]").unwrap().1, vec!["a"]);
        assert_eq!(parse_call("f[,a]").unwrap().1, vec!["", "a"]);
        assert_eq!(
            parse_call("f[a] trailing").unwrap(),
            ("f[a] trailing".into(), Vec::new())
        );
    }

    #[test]
    fn parses_flattens_and_summarizes_notebook() {
        let document = NotebookDocument::from_text(SAMPLE_NOTEBOOK, None).unwrap();
        assert_eq!(document.title().as_deref(), Some("Sample Notebook"));
        assert_eq!(document.summary().group_count, 1);
        let rows = document.flattened_cells();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].style.as_deref(), Some("Title"));
        assert_eq!(rows[0].cell_id, Some(1001));
        assert_eq!(rows[0].expression_uuid.as_deref(), Some("uuid-title"));
        assert_eq!(rows[0].cell_tags, ["intro", "top"]);
        assert_eq!(rows[1].path, [1, 0]);
        assert_eq!(document.cell_at_path(&[1, 1]).unwrap().preview, "Body text");
        assert!(document.item_at_flat_index(0).is_ok());
        assert!(serde_json::to_string(&document.to_value()).is_ok());
    }

    #[test]
    fn patching_invalidates_group_source_and_preserves_unmodified_cells() {
        let mut document = NotebookDocument::from_text(SAMPLE_NOTEBOOK, None).unwrap();
        let original_title_cell = document.items[0].render();
        apply_patch_spec(
            &mut document,
            &json!({"operations": [
                {"op": "append_cell", "style": "Text", "text": "Tail cell"},
                {"op": "replace_cell", "path": [2], "style": "Input", "text": "Expand[2 (a+b)]"},
                {"op": "set_option", "name": "WindowTitle", "value_expr": "\"Patched Notebook\""},
                {"op": "append_cell", "container_path": [1], "style": "Text", "text": "Nested tail"}
            ]}),
        )
        .unwrap();
        assert_eq!(document.title().as_deref(), Some("Patched Notebook"));
        assert_eq!(document.summary().cell_count, 6);
        assert_eq!(document.items[0].render(), original_title_cell);
        let rendered = document.render();
        assert!(rendered.contains("Tail cell"));
        assert!(rendered.contains("Expand[2 (a+b)]"));
        assert!(rendered.contains("Nested tail"));
    }

    #[test]
    fn inline_box_preview_and_extraction_match_python_contract() {
        let document = NotebookDocument::from_text(
            r#"Notebook[{Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output"], Cell["hello \!\(\*StyleBox[\"Hello\", FontWeight->Bold]\)", "Text"]}]"#,
            None,
        )
        .unwrap();
        assert_eq!(document.flattened_cells()[1].preview, "hello [InlineBox]");
        let graphic = match document.item_at_flat_index(0).unwrap() {
            NotebookItem::Cell(cell) => &cell.content_expr,
            _ => panic!("expected cell"),
        };
        let styled = match document.item_at_flat_index(1).unwrap() {
            NotebookItem::Cell(cell) => &cell.content_expr,
            _ => panic!("expected cell"),
        };
        assert_eq!(
            extract_box_expressions(graphic),
            ["GraphicsBox[{CircleBox[]}]".to_owned()]
        );
        assert_eq!(
            extract_box_expressions(styled),
            [r#"StyleBox["Hello", FontWeight->Bold]"#.to_owned()]
        );
    }

    #[test]
    fn render_round_trip_preserves_preamble_and_raw_cells() {
        let document = NotebookDocument::from_text(SAMPLE_NOTEBOOK, None).unwrap();
        let rendered = document.render();
        assert!(rendered.starts_with("(* sample header *)\nNotebook["));
        let reparsed = NotebookDocument::from_text(&rendered, None).unwrap();
        assert_eq!(reparsed.to_value(), document.to_value());
    }
}
