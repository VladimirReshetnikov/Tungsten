//! Local Wolfram documentation extraction and SQLite FTS5 search.

use crate::discovery::{
    WolframInstallation, discover_installation, ensure_parent_directory, notebook_files,
};
use crate::notebook::{collapse_text, extract_string_literals};
use regex::Regex;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;

const REFERENCE_CATEGORIES: &[(&str, &str)] = &[
    ("Symbols", "ref"),
    ("Programs", "ref/program"),
    ("MenuItems", "ref/menuitem"),
    ("Characters", "ref/character"),
    ("Entities", "ref/entity"),
    ("Interpreters", "ref/interpreter"),
    ("FrontEndObjects", "ref/frontendobject"),
];
const SECTION_CATEGORIES: &[(&str, &str)] = &[
    ("Guides", "guide"),
    ("Tutorials", "tutorial"),
    ("HowTos", "howto"),
    ("Workflows", "workflow"),
    ("WorkflowGuides", "workflowguide"),
    ("ExamplePages", "example"),
];
const NOISE_LITERALS: &[&str] = &[
    "AnchorBar",
    "AnchorBarGrid",
    "Columns",
    "ExampleCount",
    "ExampleSection",
    "LinkHand",
    "ObjectNameTranslation",
    "PacletNameCell",
    "PrimaryExamplesSection",
    "Rows",
    "SeeAlsoRelated",
    "Spacer1",
];

#[derive(Debug, Error)]
pub enum DocumentationError {
    #[error("No documentation page found for {0:?}.")]
    NotFound(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DocumentationRecord {
    pub title: String,
    pub paclet: String,
    pub kind: String,
    pub category: String,
    pub path: String,
    pub preview: String,
    pub text: String,
}

impl DocumentationRecord {
    pub fn to_value(&self) -> Value {
        json!({
            "title": self.title,
            "paclet": self.paclet,
            "kind": self.kind,
            "category": self.category,
            "path": self.path,
            "preview": self.preview,
            "text": self.text,
        })
    }
}

#[derive(Clone, Debug)]
pub struct DocumentationIndex {
    pub installation: WolframInstallation,
}

impl Default for DocumentationIndex {
    fn default() -> Self {
        Self::new(discover_installation())
    }
}

impl DocumentationIndex {
    pub const fn new(installation: WolframInstallation) -> Self {
        Self { installation }
    }

    pub fn ensure_index(
        &self,
        index_path: Option<&Path>,
        rebuild: bool,
    ) -> Result<PathBuf, DocumentationError> {
        let target = index_path
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.installation.default_index_path.clone());
        if rebuild || !target.exists() {
            self.build_index(Some(&target))?;
        }
        Ok(target)
    }

    pub fn build_index(&self, index_path: Option<&Path>) -> Result<PathBuf, DocumentationError> {
        let target = index_path
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.installation.default_index_path.clone());
        ensure_parent_directory(&target)?;
        if target.exists() {
            fs::remove_file(&target)?;
        }
        let mut connection = Connection::open(&target)?;
        connection.execute_batch(
            "CREATE TABLE documents (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                paclet TEXT NOT NULL,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                path TEXT NOT NULL,
                preview TEXT NOT NULL,
                text TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE documents_fts USING fts5(
                title, paclet, kind, category, preview, text,
                content='documents', content_rowid='id'
            );
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        let roots = self
            .installation
            .docs_roots
            .iter()
            .map(|root| root.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        connection.execute(
            "INSERT INTO metadata(key, value) VALUES(?1, ?2)",
            params!["docs_roots", serde_json::to_string(&roots)?],
        )?;
        let transaction = connection.transaction()?;
        for notebook_path in notebook_files(&self.installation.docs_roots) {
            let record = self.record_from_path(&notebook_path)?;
            transaction.execute(
                "INSERT INTO documents(title, paclet, kind, category, path, preview, text)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    record.title,
                    record.paclet,
                    record.kind,
                    record.category,
                    record.path,
                    record.preview,
                    record.text
                ],
            )?;
            let rowid = transaction.last_insert_rowid();
            transaction.execute(
                "INSERT INTO documents_fts(rowid, title, paclet, kind, category, preview, text)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    rowid,
                    record.title,
                    record.paclet,
                    record.kind,
                    record.category,
                    record.preview,
                    record.text
                ],
            )?;
        }
        transaction.commit()?;
        Ok(target)
    }

    pub fn search(
        &self,
        query: &str,
        index_path: Option<&Path>,
        limit: usize,
        rebuild: bool,
    ) -> Result<Vec<Value>, DocumentationError> {
        let fast = self.search_by_filename(query, limit)?;
        if !fast.is_empty() {
            return Ok(fast);
        }
        let target = self.ensure_index(index_path, rebuild)?;
        let connection = Connection::open(target)?;
        let mut statement = connection.prepare(
            "SELECT documents.title, documents.paclet, documents.kind, documents.category,
                    documents.path, documents.preview,
                    snippet(documents_fts, 5, '[', ']', ' … ', 18) AS snippet,
                    bm25(documents_fts) AS score
             FROM documents_fts
             JOIN documents ON documents.id = documents_fts.rowid
             WHERE documents_fts MATCH ?1
             ORDER BY score LIMIT ?2",
        )?;
        let rows = statement.query_map(
            params![
                build_match_query(query),
                i64::try_from(limit).unwrap_or(i64::MAX)
            ],
            |row| {
                Ok(json!({
                    "title": row.get::<_, String>(0)?,
                    "paclet": row.get::<_, String>(1)?,
                    "kind": row.get::<_, String>(2)?,
                    "category": row.get::<_, String>(3)?,
                    "path": row.get::<_, String>(4)?,
                    "preview": row.get::<_, String>(5)?,
                    "snippet": row.get::<_, String>(6)?,
                    "score": row.get::<_, f64>(7)?,
                }))
            },
        )?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn read(
        &self,
        identifier: &str,
        index_path: Option<&Path>,
        rebuild: bool,
    ) -> Result<Value, DocumentationError> {
        let stem = stem_from_identifier(identifier);
        if !stem.is_empty()
            && let Some(path) = self.find_notebook_paths(&stem, 1)?.into_iter().next()
        {
            return Ok(self.record_from_path(&path)?.to_value());
        }
        let target = self.ensure_index(index_path, rebuild)?;
        let connection = Connection::open(&target)?;
        let row = if Path::new(identifier).exists() {
            query_document(
                &connection,
                "SELECT * FROM documents WHERE path = ?1",
                &absolute_string(Path::new(identifier)),
            )?
        } else if identifier.starts_with("paclet:") {
            query_document(
                &connection,
                "SELECT * FROM documents WHERE paclet = ?1 COLLATE NOCASE",
                identifier,
            )?
        } else {
            query_document_pair(
                &connection,
                "SELECT * FROM documents WHERE title = ?1 COLLATE NOCASE OR paclet = ?2 COLLATE NOCASE LIMIT 1",
                identifier,
            )?
        };
        if let Some(row) = row {
            return Ok(row);
        }
        let hit = self.search(identifier, Some(&target), 1, false)?;
        let Some(paclet) = hit
            .first()
            .and_then(|hit| hit.get("paclet"))
            .and_then(Value::as_str)
        else {
            return Err(DocumentationError::NotFound(identifier.into()));
        };
        query_document(
            &connection,
            "SELECT * FROM documents WHERE paclet = ?1",
            paclet,
        )?
        .ok_or_else(|| DocumentationError::NotFound(identifier.into()))
    }

    pub fn resolve_identifier(
        &self,
        identifier: &str,
        index_path: Option<&Path>,
    ) -> Result<String, DocumentationError> {
        if identifier.starts_with("paclet:") {
            return Ok(identifier.into());
        }
        self.read(identifier, index_path, false)?["paclet"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| DocumentationError::NotFound(identifier.into()))
    }

    pub fn record_from_path(
        &self,
        notebook_path: &Path,
    ) -> Result<DocumentationRecord, DocumentationError> {
        let raw = String::from_utf8_lossy(&fs::read(notebook_path)?).into_owned();
        let title = extract_title(&raw, notebook_path);
        let (kind, category, paclet) = infer_kind_and_paclet(notebook_path);
        let strings = filter_useful_strings(extract_string_literals(&raw));
        let text = collapse_text(&strings.join(" "), 20_000);
        let preview = collapse_text(
            &strings
                .iter()
                .filter(|fragment| !fragment.is_empty() && **fragment != title)
                .cloned()
                .collect::<Vec<_>>()
                .join(" "),
            300,
        );
        Ok(DocumentationRecord {
            title,
            paclet,
            kind,
            category,
            path: absolute_string(notebook_path),
            preview,
            text,
        })
    }

    fn search_by_filename(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<Value>, DocumentationError> {
        let stem = stem_from_identifier(query);
        if stem.is_empty() {
            return Ok(Vec::new());
        }
        self.find_notebook_paths(&stem, limit.saturating_mul(4))?
            .into_iter()
            .take(limit)
            .map(|path| {
                let record = self.record_from_path(&path)?;
                Ok(json!({
                    "title": record.title,
                    "paclet": record.paclet,
                    "kind": record.kind,
                    "category": record.category,
                    "path": record.path,
                    "preview": record.preview,
                    "snippet": record.preview,
                    "score": 0.0,
                }))
            })
            .collect()
    }

    fn find_notebook_paths(
        &self,
        stem: &str,
        limit: usize,
    ) -> Result<Vec<PathBuf>, DocumentationError> {
        let roots = self
            .installation
            .docs_roots
            .iter()
            .map(|root| root.canonicalize().unwrap_or_else(|_| root.clone()))
            .collect::<Vec<_>>();
        let mut candidates = Vec::new();
        for root in &roots {
            collect_named_notebooks(root, stem, &mut candidates);
        }
        let mut seen = HashSet::new();
        let mut filtered = candidates
            .into_iter()
            .filter_map(|path| path.canonicalize().ok())
            .filter(|path| seen.insert(path.clone()))
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("nb"))
                    && path
                        .file_stem()
                        .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case(stem))
                    && roots.iter().any(|root| {
                        absolute_string(path)
                            .to_lowercase()
                            .starts_with(&absolute_string(root).to_lowercase())
                    })
            })
            .collect::<Vec<_>>();
        filtered.sort_by_key(|path| self.root_priority(path));
        filtered.truncate(limit);
        Ok(filtered)
    }

    fn root_priority(&self, path: &Path) -> (usize, String) {
        let normalized = absolute_string(path).to_lowercase();
        for (index, root) in self.installation.docs_roots.iter().enumerate() {
            if normalized.starts_with(&absolute_string(root).to_lowercase()) {
                return (index, normalized);
            }
        }
        (self.installation.docs_roots.len(), normalized)
    }
}

fn query_document(
    connection: &Connection,
    sql: &str,
    value: &str,
) -> rusqlite::Result<Option<Value>> {
    connection.query_row(sql, [value], document_row).optional()
}

fn query_document_pair(
    connection: &Connection,
    sql: &str,
    value: &str,
) -> rusqlite::Result<Option<Value>> {
    connection
        .query_row(sql, params![value, value], document_row)
        .optional()
}

fn document_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": row.get::<_, i64>(0)?,
        "title": row.get::<_, String>(1)?,
        "paclet": row.get::<_, String>(2)?,
        "kind": row.get::<_, String>(3)?,
        "category": row.get::<_, String>(4)?,
        "path": row.get::<_, String>(5)?,
        "preview": row.get::<_, String>(6)?,
        "text": row.get::<_, String>(7)?,
    }))
}

fn extract_title(raw: &str, notebook_path: &Path) -> String {
    let pattern =
        Regex::new(r#"WindowTitle->(?P<title>"(?:\\.|[^"])*"|[A-Za-z0-9`.$_-]+)"#).unwrap();
    if let Some(title) = pattern
        .captures(raw)
        .and_then(|capture| capture.name("title"))
        .map(|title| title.as_str().trim())
    {
        if title.starts_with('"') && title.ends_with('"') {
            return title[1..title.len() - 1].replace(r#"\""#, "\"");
        }
        return title.into();
    }
    notebook_path
        .file_stem()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
}

fn infer_kind_and_paclet(notebook_path: &Path) -> (String, String, String) {
    let parts = notebook_path
        .iter()
        .map(|part| part.to_string_lossy())
        .collect::<Vec<_>>();
    let stem = notebook_path
        .file_stem()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    if let Some(index) = parts.iter().position(|part| part == "ReferencePages")
        && let Some(category) = parts.get(index + 1)
    {
        let paclet_category = REFERENCE_CATEGORIES
            .iter()
            .find(|(name, _)| name == category)
            .map_or_else(
                || format!("ref/{}", category.to_lowercase()),
                |(_, value)| (*value).into(),
            );
        return (
            "reference".into(),
            category.to_string(),
            format!("paclet:{paclet_category}/{stem}"),
        );
    }
    for (section, category) in SECTION_CATEGORIES {
        if parts.iter().any(|part| part == section) {
            return (
                (*category).into(),
                (*section).into(),
                format!("paclet:{category}/{stem}"),
            );
        }
    }
    (
        "document".into(),
        "Other".into(),
        format!("paclet:document/{stem}"),
    )
}

fn build_match_query(query: &str) -> String {
    let pattern = Regex::new(r"[A-Za-z0-9_.:/-]+").unwrap();
    let terms = pattern
        .find_iter(query)
        .map(|term| format!("\"{}\"*", term.as_str()))
        .collect::<Vec<_>>();
    if terms.is_empty() {
        format!("\"{query}\"")
    } else {
        terms.join(" AND ")
    }
}

fn filter_useful_strings(strings: Vec<String>) -> Vec<String> {
    let uuid = Regex::new(
        r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )
    .unwrap();
    let compressed = Regex::new(r"^[A-Za-z0-9+/=:._-]{200,}$").unwrap();
    strings
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| {
            !value.is_empty()
                && !NOISE_LITERALS.contains(&value.as_str())
                && !uuid.is_match(value)
                && !compressed.is_match(value)
        })
        .collect()
}

fn stem_from_identifier(identifier: &str) -> String {
    let candidate = if identifier.starts_with("paclet:") {
        identifier.rsplit('/').next().unwrap_or_default()
    } else {
        identifier
    };
    let stem = Path::new(candidate)
        .file_stem()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let valid = Regex::new(r"^[A-Za-z0-9_.-]+$").unwrap();
    if valid.is_match(&stem) {
        stem
    } else {
        String::new()
    }
}

fn collect_named_notebooks(path: &Path, stem: &str, output: &mut Vec<PathBuf>) {
    if path.is_file() {
        if path.file_name().is_some_and(|name| {
            name.to_string_lossy()
                .eq_ignore_ascii_case(&format!("{stem}.nb"))
        }) {
            output.push(path.to_path_buf());
        }
        return;
    }
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            collect_named_notebooks(&entry.path(), stem, output);
        }
    }
}

fn absolute_string(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::licensing::unique_temp_directory;

    #[test]
    fn builds_searches_and_reads_documentation_index() {
        let root = unique_temp_directory("tungsten-docs-test").unwrap();
        let docs = root.join("ReferencePages/Symbols");
        fs::create_dir_all(&docs).unwrap();
        fs::write(docs.join("Foo.nb"), r#"Notebook[{Cell["Foo", "ObjectName"], Cell["Foo computes a symbolic bar.", "Usage"]}, WindowTitle->Foo]"#).unwrap();
        fs::write(docs.join("Bar.nb"), r#"Notebook[{Cell["Bar", "ObjectName"], Cell["Bar transforms a notebook.", "Usage"]}, WindowTitle->Bar]"#).unwrap();
        let mut installation = discover_installation();
        installation.docs_roots = vec![root.clone()];
        installation.default_index_path = root.join("docs.sqlite3");
        let index = DocumentationIndex::new(installation);
        let path = index.build_index(None).unwrap();
        let hits = index.search("Foo", Some(&path), 5, false).unwrap();
        assert_eq!(hits[0]["paclet"], "paclet:ref/Foo");
        let record = index.read("paclet:ref/Bar", Some(&path), false).unwrap();
        assert_eq!(record["title"], "Bar");
        assert!(
            record["text"]
                .as_str()
                .unwrap()
                .to_lowercase()
                .contains("notebook")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn fts_fallback_finds_content_when_filename_does_not_match() {
        let root = unique_temp_directory("tungsten-docs-fts").unwrap();
        let docs = root.join("Guides");
        fs::create_dir_all(&docs).unwrap();
        fs::write(
            docs.join("Topic.nb"),
            r#"Notebook[{Cell["UnusualNeedle phrase", "Text"]}, WindowTitle->Topic]"#,
        )
        .unwrap();
        let mut installation = discover_installation();
        installation.docs_roots = vec![root.clone()];
        installation.default_index_path = root.join("docs.sqlite3");
        let index = DocumentationIndex::new(installation);
        let hits = index.search("UnusualNeedle", None, 5, false).unwrap();
        assert_eq!(hits[0]["paclet"], "paclet:guide/Topic");
        fs::remove_dir_all(root).unwrap();
    }
}
