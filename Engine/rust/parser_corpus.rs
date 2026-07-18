//! Discovery and differential validation of Wolfram parser corpora.

use crate::expression::{ParseForm, parse_expression};
use crate::kernel::{KernelError, WolframKernelRunner};
use crate::notebook::NotebookDocument;
use crate::wolfram_processes::utc_now_string;
use crate::wolfram_strings::{parse_wl_string_literal, wl_string};
use regex::Regex;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;
use thiserror::Error;

pub const DEFAULT_CORPUS_ROOT: &str = r"C:\TestData\wolfram\tungsten-wolfram-parser-corpus";
pub const DEFAULT_OUTPUT_DIRECTORY_NAME: &str = "validation";
pub const DEFAULT_EXTENSIONS: &[&str] = &[".wl", ".m", ".wls", ".mt", ".wlt", ".nb", ".nbp"];
pub const NOTEBOOK_EXTENSIONS: &[&str] = &[".nb", ".nbp"];
pub const DEFAULT_MAX_BYTES: usize = 2 * 1024 * 1024;
pub const DEFAULT_KERNEL_BATCH_SIZE: usize = 100;
pub const DEFAULT_PREVIEW_CHARS: usize = 2_000;

#[derive(Debug, Error)]
pub enum CorpusError {
    #[error("Parser corpus root does not exist: {0}")]
    RootMissing(String),
    #[error("Parser corpus root is not a directory: {0}")]
    RootNotDirectory(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Kernel(#[from] KernelError),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CorpusFile {
    pub path: PathBuf,
    pub relative_path: String,
    pub extension: String,
    pub kind: String,
    pub source: String,
    pub size_bytes: u64,
}

impl CorpusFile {
    pub fn to_value(&self) -> Value {
        json!({
            "path": self.path.to_string_lossy(),
            "relative_path": self.relative_path,
            "extension": self.extension,
            "kind": self.kind,
            "source": self.source,
            "size_bytes": self.size_bytes,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParserAttempt {
    pub parser: String,
    pub status: String,
    pub elapsed_ms: Option<f64>,
    pub error_type: Option<String>,
    pub error: Option<String>,
    pub summary: Value,
}

impl ParserAttempt {
    pub fn success(parser: &str, elapsed_ms: f64, summary: Value) -> Self {
        Self {
            parser: parser.into(),
            status: "success".into(),
            elapsed_ms: Some(elapsed_ms),
            error_type: None,
            error: None,
            summary,
        }
    }

    pub fn to_value(&self) -> Value {
        let mut object = Map::new();
        object.insert("parser".into(), json!(self.parser));
        object.insert("status".into(), json!(self.status));
        if let Some(value) = self.elapsed_ms {
            object.insert("elapsed_ms".into(), json!(value));
        }
        if let Some(value) = &self.error_type {
            object.insert("error_type".into(), json!(value));
        }
        if let Some(value) = &self.error {
            object.insert("error".into(), json!(value));
        }
        object.insert("summary".into(), self.summary.clone());
        Value::Object(object)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParserCorpusResult {
    pub file: CorpusFile,
    pub tungsten: ParserAttempt,
    pub wolfram: ParserAttempt,
    pub outcome: String,
}

impl ParserCorpusResult {
    pub fn to_value(&self) -> Value {
        json!({
            "file": self.file.to_value(),
            "tungsten": self.tungsten.to_value(),
            "wolfram": self.wolfram.to_value(),
            "outcome": self.outcome,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParserCorpusRun {
    pub summary: Value,
    pub results: Vec<ParserCorpusResult>,
    pub output_files: BTreeMap<String, String>,
}

impl ParserCorpusRun {
    pub fn to_value(&self, include_results: bool) -> Value {
        let mut payload = json!({
            "summary": self.summary,
            "output_files": self.output_files,
        });
        if include_results {
            payload["results"] = Value::Array(
                self.results
                    .iter()
                    .map(ParserCorpusResult::to_value)
                    .collect(),
            );
        }
        payload
    }
}

#[derive(Clone, Debug)]
pub struct CorpusDiscoveryOptions {
    pub extensions: Vec<String>,
    pub include_globs: Vec<String>,
    pub exclude_globs: Vec<String>,
    pub max_files: Option<usize>,
    pub shuffle: bool,
    pub seed: u64,
}

impl Default for CorpusDiscoveryOptions {
    fn default() -> Self {
        Self {
            extensions: DEFAULT_EXTENSIONS.iter().map(ToString::to_string).collect(),
            include_globs: Vec::new(),
            exclude_globs: Vec::new(),
            max_files: None,
            shuffle: false,
            seed: 0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ParserCorpusOptions {
    pub discovery: CorpusDiscoveryOptions,
    pub out_dir: Option<PathBuf>,
    pub max_bytes: Option<usize>,
    pub source_form: ParseForm,
    pub compare_wolfram: bool,
    pub kernel_batch_size: usize,
    pub tungsten_workers: usize,
    pub preview_chars: usize,
    pub write_outputs: bool,
}

impl Default for ParserCorpusOptions {
    fn default() -> Self {
        Self {
            discovery: CorpusDiscoveryOptions::default(),
            out_dir: None,
            max_bytes: Some(DEFAULT_MAX_BYTES),
            source_form: ParseForm::Input,
            compare_wolfram: true,
            kernel_batch_size: DEFAULT_KERNEL_BATCH_SIZE,
            tungsten_workers: 1,
            preview_chars: DEFAULT_PREVIEW_CHARS,
            write_outputs: true,
        }
    }
}

pub fn discover_corpus_files(
    corpus_root: &Path,
    options: &CorpusDiscoveryOptions,
) -> Result<Vec<CorpusFile>, CorpusError> {
    let root = absolute_path(corpus_root);
    if !root.exists() {
        return Err(CorpusError::RootMissing(
            root.to_string_lossy().into_owned(),
        ));
    }
    if !root.is_dir() {
        return Err(CorpusError::RootNotDirectory(
            root.to_string_lossy().into_owned(),
        ));
    }
    let extensions = normalize_extensions(&options.extensions);
    let include = normalize_globs(&options.include_globs);
    let exclude = normalize_globs(&options.exclude_globs);
    let mut paths = Vec::new();
    collect_files(&root, &mut paths);
    let mut files = Vec::new();
    for path in paths {
        let extension = path
            .extension()
            .map(|extension| format!(".{}", extension.to_string_lossy().to_lowercase()))
            .unwrap_or_default();
        if !extensions.contains(&extension) {
            continue;
        }
        let Ok(relative) = path.strip_prefix(&root) else {
            continue;
        };
        let relative_path = relative.to_string_lossy().replace('\\', "/");
        if !include.is_empty() && !matches_any(&relative_path, &include) {
            continue;
        }
        if !exclude.is_empty() && matches_any(&relative_path, &exclude) {
            continue;
        }
        let Ok(metadata) = path.metadata() else {
            continue;
        };
        files.push(CorpusFile {
            path,
            relative_path: relative_path.clone(),
            extension: extension.clone(),
            kind: if NOTEBOOK_EXTENSIONS.contains(&extension.as_str()) {
                "notebook".into()
            } else {
                "source".into()
            },
            source: source_from_relative_path(&relative_path),
            size_bytes: metadata.len(),
        });
    }
    files.sort_by_key(|file| file.relative_path.to_lowercase());
    if options.shuffle {
        deterministic_shuffle(&mut files, options.seed);
    }
    if let Some(max_files) = options.max_files {
        files.truncate(max_files);
    }
    Ok(files)
}

pub fn summarize_discovery(files: &[CorpusFile], corpus_root: &Path) -> Value {
    json!({
        "corpus_root": absolute_path(corpus_root).to_string_lossy(),
        "file_count": files.len(),
        "total_bytes": files.iter().map(|file| file.size_bytes).sum::<u64>(),
        "by_extension": counts(files.iter().map(|file| file.extension.as_str())),
        "by_kind": counts(files.iter().map(|file| file.kind.as_str())),
        "by_source": counts(files.iter().map(|file| file.source.as_str())),
    })
}

pub fn parse_file_with_tungsten(
    file: &CorpusFile,
    source_form: ParseForm,
    max_bytes: Option<usize>,
    preview_chars: usize,
) -> ParserAttempt {
    if max_bytes.is_some_and(|limit| file.size_bytes > limit as u64) {
        return skipped_attempt(
            "tungsten",
            "FileTooLarge",
            &format!(
                "File is {} bytes; max_bytes is {}.",
                file.size_bytes,
                max_bytes.unwrap()
            ),
        );
    }
    let start = Instant::now();
    let text = match fs::read(&file.path) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        Err(error) => return failed_attempt("tungsten", start, "OSError", &error.to_string()),
    };
    if file.kind == "notebook" {
        return match NotebookDocument::from_text(&text, Some(file.path.clone())) {
            Ok(document) => ParserAttempt::success(
                "tungsten",
                elapsed_ms(start),
                serde_json::to_value(document.summary()).unwrap(),
            ),
            Err(error) => failed_attempt("tungsten", start, "ValueError", &error.to_string()),
        };
    }
    match parse_expression(&text, source_form) {
        Ok(expression) => ParserAttempt::success(
            "tungsten",
            elapsed_ms(start),
            json!({
                "form": form_label(source_form),
                "input_form_preview": truncate(&expression.to_input_form(), preview_chars),
                "full_form_preview": truncate(&expression.to_full_form(), preview_chars),
                "depth": expression.depth(),
                "length": expression.length(),
            }),
        ),
        Err(error) => failed_attempt("tungsten", start, "WolframSyntaxError", &error.to_string()),
    }
}

pub fn parse_files_with_wolfram_kernel(
    files: &[CorpusFile],
    runner: &WolframKernelRunner,
    preview_chars: usize,
) -> Result<HashMap<String, ParserAttempt>, CorpusError> {
    if files.is_empty() {
        return Ok(HashMap::new());
    }
    let result = runner.evaluate_text(
        &build_wolfram_parse_batch_script(files, preview_chars),
        None,
        false,
    )?;
    if !result.evaluation_available {
        return Ok(files
            .iter()
            .map(|file| {
                (
                    file.relative_path.clone(),
                    skipped_attempt(
                        "wolfram",
                        result
                            .failure_type
                            .as_deref()
                            .unwrap_or("KernelUnavailable"),
                        if result.stderr.is_empty() {
                            "Wolfram kernel did not produce a structured result."
                        } else {
                            &result.stderr
                        },
                    ),
                )
            })
            .collect());
    }
    let Some(raw_result) = result.result.as_deref() else {
        return Ok(files
            .iter()
            .map(|file| {
                (
                    file.relative_path.clone(),
                    failure(
                        "wolfram",
                        "MissingKernelResult",
                        "Wolfram kernel evaluation completed without a result string.",
                    ),
                )
            })
            .collect());
    };
    let payload = match decode_kernel_json_string(raw_result) {
        Ok(Value::Array(payload)) => payload,
        Ok(_) => {
            return Ok(files
                .iter()
                .map(|file| {
                    (
                        file.relative_path.clone(),
                        failure(
                            "wolfram",
                            "InvalidKernelPayload",
                            "Wolfram parser batch payload was not a JSON array.",
                        ),
                    )
                })
                .collect());
        }
        Err(error) => {
            return Ok(files
                .iter()
                .map(|file| {
                    (
                        file.relative_path.clone(),
                        ParserAttempt {
                            parser: "wolfram".into(),
                            status: "failure".into(),
                            elapsed_ms: None,
                            error_type: Some("JSONDecodeError".into()),
                            error: Some(truncate(
                                &format!("Could not decode Wolfram parser batch payload: {error}"),
                                preview_chars,
                            )),
                            summary: json!({
                                "kernel_success": result.success,
                                "kernel_failure_type": result.failure_type,
                                "kernel_messages": result.messages,
                                "kernel_result_preview": truncate(raw_result, preview_chars),
                            }),
                        },
                    )
                })
                .collect());
        }
    };
    let by_path = files
        .iter()
        .map(|file| (slash_absolute(&file.path), file))
        .collect::<HashMap<_, _>>();
    let mut attempts = HashMap::new();
    for item in payload {
        let Some(item) = item.as_object() else {
            continue;
        };
        let Some(file) = item
            .get("path")
            .and_then(Value::as_str)
            .and_then(|path| by_path.get(path))
        else {
            continue;
        };
        if let Some(attempt) = item.get("attempt").and_then(Value::as_object) {
            attempts.insert(
                file.relative_path.clone(),
                attempt_from_wolfram_payload(attempt, preview_chars),
            );
        }
    }
    for file in files {
        attempts
            .entry(file.relative_path.clone())
            .or_insert_with(|| {
                failure(
                    "wolfram",
                    "MissingFileResult",
                    "Wolfram parser batch did not include this file in its JSON payload.",
                )
            });
    }
    Ok(attempts)
}

pub fn compare_parser_corpus(
    corpus_root: &Path,
    options: &ParserCorpusOptions,
    runner: Option<&WolframKernelRunner>,
    mut batch_parser: Option<&mut dyn FnMut(&[CorpusFile]) -> HashMap<String, ParserAttempt>>,
) -> Result<ParserCorpusRun, CorpusError> {
    let total_start = Instant::now();
    let discovery_start = Instant::now();
    let files = discover_corpus_files(corpus_root, &options.discovery)?;
    let discovery_elapsed = elapsed_ms(discovery_start);
    let tungsten_start = Instant::now();
    let tungsten = files
        .iter()
        .map(|file| {
            (
                file.relative_path.clone(),
                parse_file_with_tungsten(
                    file,
                    options.source_form,
                    options.max_bytes,
                    options.preview_chars,
                ),
            )
        })
        .collect::<HashMap<_, _>>();
    let tungsten_elapsed = elapsed_ms(tungsten_start);
    let mut wolfram = HashMap::new();
    let mut wolfram_elapsed = 0.0;
    if options.compare_wolfram {
        let start = Instant::now();
        let eligible = files
            .iter()
            .filter(|file| {
                options
                    .max_bytes
                    .is_none_or(|limit| file.size_bytes <= limit as u64)
            })
            .cloned()
            .collect::<Vec<_>>();
        for batch in eligible.chunks(options.kernel_batch_size.max(1)) {
            let attempts = if let Some(parser) = batch_parser.as_deref_mut() {
                parser(batch)
            } else if let Some(runner) = runner {
                parse_files_with_wolfram_kernel(batch, runner, options.preview_chars)?
            } else {
                parse_files_with_wolfram_kernel(
                    batch,
                    &WolframKernelRunner::default(),
                    options.preview_chars,
                )?
            };
            wolfram.extend(attempts);
        }
        wolfram_elapsed = elapsed_ms(start);
    }
    for file in &files {
        wolfram
            .entry(file.relative_path.clone())
            .or_insert_with(|| {
                if options.compare_wolfram {
                    skipped_attempt(
                        "wolfram",
                        "FileTooLarge",
                        &format!(
                            "File is {} bytes; max_bytes is {}.",
                            file.size_bytes,
                            options
                                .max_bytes
                                .map_or_else(|| "None".into(), |value| value.to_string())
                        ),
                    )
                } else {
                    skipped_attempt(
                        "wolfram",
                        "WolframComparisonDisabled",
                        "Wolfram kernel comparison was disabled for this run.",
                    )
                }
            });
    }
    let results = files
        .iter()
        .map(|file| {
            let tungsten = tungsten[&file.relative_path].clone();
            let wolfram = wolfram[&file.relative_path].clone();
            ParserCorpusResult {
                file: file.clone(),
                outcome: classify_outcome(&tungsten, &wolfram),
                tungsten,
                wolfram,
            }
        })
        .collect::<Vec<_>>();
    let mut summary = build_run_summary(
        corpus_root,
        &files,
        &results,
        options,
        discovery_elapsed,
        tungsten_elapsed,
        wolfram_elapsed,
    );
    let output_directory = options.out_dir.clone().or_else(|| {
        options
            .write_outputs
            .then(|| corpus_root.join(DEFAULT_OUTPUT_DIRECTORY_NAME))
    });
    let output_start = Instant::now();
    let mut output_files =
        if let Some(directory) = output_directory.filter(|_| options.write_outputs) {
            write_parser_corpus_outputs(&directory, &summary, &results)?
        } else {
            BTreeMap::new()
        };
    if !output_files.is_empty() {
        summary["output_files"] = json!(output_files);
    }
    summary["timings"]["output_write_elapsed_ms"] = json!(elapsed_ms(output_start));
    summary["timings"]["total_elapsed_ms"] = json!(elapsed_ms(total_start));
    if let Some(path) = output_files.get("summary") {
        fs::write(path, serde_json::to_string_pretty(&summary)? + "\n")?;
    }
    if let Some(path) = output_files.get("report") {
        fs::write(path, render_markdown_report(&summary, &results))?;
    }
    Ok(ParserCorpusRun {
        summary,
        results,
        output_files: std::mem::take(&mut output_files),
    })
}

pub fn write_parser_corpus_outputs(
    output_directory: &Path,
    summary: &Value,
    results: &[ParserCorpusResult],
) -> Result<BTreeMap<String, String>, CorpusError> {
    fs::create_dir_all(output_directory)?;
    let summary_path = output_directory.join("parser-corpus-summary.json");
    let results_path = output_directory.join("parser-corpus-results.jsonl");
    let report_path = output_directory.join("parser-corpus-report.md");
    fs::write(&summary_path, serde_json::to_string_pretty(summary)? + "\n")?;
    let mut result_lines = String::new();
    for result in results {
        result_lines.push_str(&serde_json::to_string(&result.to_value())?);
        result_lines.push('\n');
    }
    fs::write(&results_path, result_lines)?;
    fs::write(&report_path, render_markdown_report(summary, results))?;
    Ok(BTreeMap::from([
        (
            "summary".into(),
            summary_path.to_string_lossy().into_owned(),
        ),
        (
            "results_jsonl".into(),
            results_path.to_string_lossy().into_owned(),
        ),
        ("report".into(), report_path.to_string_lossy().into_owned()),
    ]))
}

pub fn build_wolfram_parse_batch_script(files: &[CorpusFile], preview_chars: usize) -> String {
    let paths = files
        .iter()
        .map(|file| slash_absolute(&file.path))
        .collect::<Vec<_>>();
    let paths_literal = wl_string(&serde_json::to_string(&paths).unwrap());
    format!(
        r#"tungstenParserCorpusFiles = ImportString[{paths_literal}, "RawJSON"];
tungstenParserCorpusPreviewChars = {preview_chars};

ClearAll[tungstenParserCorpusShortString, tungstenParserCorpusParseOne];
tungstenParserCorpusShortString[text_] := If[
    StringQ[text] && StringLength[text] > tungstenParserCorpusPreviewChars,
    StringTake[text, tungstenParserCorpusPreviewChars] <> "...",
    text
];

tungstenParserCorpusParseOne[path_String] := Module[
    {{started, text, held, normalized, rendered, fullRendered}},
    started = AbsoluteTime[];
    text = Quiet @ Check[Import[path, "Text", CharacterEncoding -> "UTF-8"], $Failed];
    If[text === $Failed, Return @ <|"parser" -> "wolfram", "status" -> "failure", "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)], "error_type" -> "ImportFailure", "error" -> "Import[path, Text] returned $Failed."|>];
    held = Quiet @ Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return @ <|"parser" -> "wolfram", "status" -> "failure", "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)], "error_type" -> "ParseFailure", "error" -> "ToExpression[text, InputForm, HoldComplete] returned $Failed."|>];
    normalized = Replace[held, HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]];
    rendered = Quiet @ Check[ToString[normalized, InputForm, PageWidth -> Infinity], "$Failed"];
    fullRendered = Quiet @ Check[ToString[FullForm[normalized], OutputForm, PageWidth -> Infinity], "$Failed"];
    <|"parser" -> "wolfram", "status" -> "success", "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)], "summary" -> <|"held_head" -> Quiet @ Check[ToString[Head[normalized], InputForm], "$Failed"], "leaf_count" -> Quiet @ Check[LeafCount[normalized], Null], "byte_count" -> Quiet @ Check[ByteCount[normalized], Null], "input_form_preview" -> tungstenParserCorpusShortString[rendered], "full_form_preview" -> tungstenParserCorpusShortString[fullRendered]|>|>
];

ExportString[Map[<|"path" -> #, "attempt" -> tungstenParserCorpusParseOne[#]|> &, tungstenParserCorpusFiles], "RawJSON"]"#
    )
}

fn build_run_summary(
    corpus_root: &Path,
    files: &[CorpusFile],
    results: &[ParserCorpusResult],
    options: &ParserCorpusOptions,
    discovery_elapsed: f64,
    tungsten_elapsed: f64,
    wolfram_elapsed: f64,
) -> Value {
    let tungsten_attempt_elapsed = results
        .iter()
        .filter(|result| result.tungsten.status != "skipped")
        .filter_map(|result| result.tungsten.elapsed_ms)
        .sum::<f64>();
    let wolfram_attempt_elapsed = results
        .iter()
        .filter(|result| result.wolfram.status != "skipped")
        .filter_map(|result| result.wolfram.elapsed_ms)
        .sum::<f64>();
    let tungsten_failures = counts(results.iter().filter_map(|result| {
        (result.tungsten.status == "failure")
            .then(|| result.tungsten.error_type.as_deref().unwrap_or("Unknown"))
    }));
    let wolfram_failures = counts(results.iter().filter_map(|result| {
        (result.wolfram.status == "failure")
            .then(|| result.wolfram.error_type.as_deref().unwrap_or("Unknown"))
    }));
    json!({
        "generated_utc": utc_now_string(),
        "corpus_root": absolute_path(corpus_root).to_string_lossy(),
        "options": {
            "extensions": normalize_extensions(&options.discovery.extensions),
            "include_globs": options.discovery.include_globs,
            "exclude_globs": options.discovery.exclude_globs,
            "max_files": options.discovery.max_files,
            "max_bytes": options.max_bytes,
            "source_form": form_label(options.source_form),
            "compare_wolfram": options.compare_wolfram,
            "kernel_batch_size": options.kernel_batch_size,
            "tungsten_workers": options.tungsten_workers,
            "preview_chars": options.preview_chars,
            "shuffle": options.discovery.shuffle,
            "seed": options.discovery.seed,
        },
        "timings": {
            "discovery_elapsed_ms": discovery_elapsed,
            "tungsten_wall_elapsed_ms": tungsten_elapsed,
            "wolfram_wall_elapsed_ms": wolfram_elapsed,
            "tungsten_attempt_elapsed_ms": round3(tungsten_attempt_elapsed),
            "wolfram_attempt_elapsed_ms": round3(wolfram_attempt_elapsed),
            "tungsten_files_per_second_wall": rate(results.len(), tungsten_elapsed),
            "wolfram_files_per_second_wall": rate(results.iter().filter(|result| result.wolfram.status != "skipped").count(), wolfram_elapsed),
        },
        "file_count": files.len(),
        "total_bytes": files.iter().map(|file| file.size_bytes).sum::<u64>(),
        "by_extension": counts(files.iter().map(|file| file.extension.as_str())),
        "by_kind": counts(files.iter().map(|file| file.kind.as_str())),
        "by_source": counts(files.iter().map(|file| file.source.as_str())),
        "outcomes": counts(results.iter().map(|result| result.outcome.as_str())),
        "tungsten_statuses": counts(results.iter().map(|result| result.tungsten.status.as_str())),
        "wolfram_statuses": counts(results.iter().map(|result| result.wolfram.status.as_str())),
        "tungsten_failure_types": tungsten_failures,
        "wolfram_failure_types": wolfram_failures,
    })
}

fn render_markdown_report(summary: &Value, results: &[ParserCorpusResult]) -> String {
    let mut lines = vec![
        "# Tungsten Parser Corpus Comparison".to_owned(),
        String::new(),
        format!(
            "- Generated UTC: `{}`",
            display_json(&summary["generated_utc"])
        ),
        format!("- Corpus root: `{}`", display_json(&summary["corpus_root"])),
        format!(
            "- Files considered: `{}`",
            display_json(&summary["file_count"])
        ),
        format!(
            "- Total bytes considered: `{}`",
            display_json(&summary["total_bytes"])
        ),
        String::new(),
        "## Outcomes".into(),
        String::new(),
    ];
    append_map_lines(&mut lines, &summary["outcomes"], false);
    lines.extend([
        String::new(),
        "## Tungsten Failure Types".into(),
        String::new(),
    ]);
    append_map_lines(&mut lines, &summary["tungsten_failure_types"], true);
    lines.extend([String::new(), "## Timings".into(), String::new()]);
    append_map_lines(&mut lines, &summary["timings"], true);
    for (heading, outcome, none_text, use_tungsten) in [
        (
            "First Wolfram-Accepted Tungsten Gaps",
            "tungsten_gap",
            "None in this run.",
            true,
        ),
        (
            "First Tungsten-Accepted Wolfram Rejections",
            "tungsten_only_success",
            "None in this run.",
            false,
        ),
    ] {
        lines.extend([String::new(), format!("## {heading}"), String::new()]);
        let selected = results
            .iter()
            .filter(|result| result.outcome == outcome)
            .take(50)
            .collect::<Vec<_>>();
        if selected.is_empty() {
            lines.push(format!("- {none_text}"));
        } else {
            for result in selected {
                let attempt = if use_tungsten {
                    &result.tungsten
                } else {
                    &result.wolfram
                };
                lines.push(format!(
                    "- `{}` ({}, {} bytes): {}",
                    result.file.relative_path,
                    result.file.extension,
                    result.file.size_bytes,
                    attempt.error_type.as_deref().unwrap_or(&attempt.status)
                ));
                if let Some(error) = &attempt.error {
                    lines.push(format!(
                        "  {}: `{}`",
                        if use_tungsten { "Tungsten" } else { "Wolfram" },
                        truncate(&error.split_whitespace().collect::<Vec<_>>().join(" "), 180)
                    ));
                }
            }
        }
    }
    lines.push(String::new());
    lines.join("\n")
}

fn attempt_from_wolfram_payload(
    payload: &Map<String, Value>,
    preview_chars: usize,
) -> ParserAttempt {
    ParserAttempt {
        parser: "wolfram".into(),
        status: payload
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("failure")
            .into(),
        elapsed_ms: payload.get("elapsed_ms").and_then(Value::as_f64),
        error_type: optional_value_string(payload.get("error_type")),
        error: optional_value_string(payload.get("error"))
            .map(|error| truncate(&error, preview_chars))
            .filter(|error| !error.is_empty()),
        summary: payload.get("summary").cloned().unwrap_or_else(|| json!({})),
    }
}

fn decode_kernel_json_string(value: &str) -> Result<Value, serde_json::Error> {
    let mut text = value.trim().to_owned();
    if text.starts_with('"') && text.ends_with('"') {
        text = parse_wl_string_literal(&text).unwrap_or(text);
    }
    serde_json::from_str(&text)
}

fn skipped_attempt(parser: &str, reason: &str, message: &str) -> ParserAttempt {
    ParserAttempt {
        parser: parser.into(),
        status: "skipped".into(),
        elapsed_ms: None,
        error_type: Some(reason.into()),
        error: Some(message.into()),
        summary: json!({}),
    }
}

fn failure(parser: &str, error_type: &str, error: &str) -> ParserAttempt {
    ParserAttempt {
        parser: parser.into(),
        status: "failure".into(),
        elapsed_ms: None,
        error_type: Some(error_type.into()),
        error: Some(error.into()),
        summary: json!({}),
    }
}

fn failed_attempt(parser: &str, start: Instant, error_type: &str, error: &str) -> ParserAttempt {
    let mut attempt = failure(parser, error_type, error);
    attempt.elapsed_ms = Some(elapsed_ms(start));
    attempt
}

fn classify_outcome(tungsten: &ParserAttempt, wolfram: &ParserAttempt) -> String {
    match (tungsten.status.as_str(), wolfram.status.as_str()) {
        ("skipped", _) | (_, "skipped") => "skipped".into(),
        ("success", "success") => "both_success".into(),
        ("failure", "success") => "tungsten_gap".into(),
        ("success", "failure") => "tungsten_only_success".into(),
        ("failure", "failure") => "both_fail".into(),
        (left, right) => format!("{left}_vs_{right}"),
    }
}

fn normalize_extensions(extensions: &[String]) -> Vec<String> {
    let mut normalized = Vec::new();
    for extension in extensions {
        let mut extension = extension.trim().to_lowercase();
        if extension.is_empty() {
            continue;
        }
        if !extension.starts_with('.') {
            extension.insert(0, '.');
        }
        if !normalized.contains(&extension) {
            normalized.push(extension);
        }
    }
    normalized
}

fn normalize_globs(patterns: &[String]) -> Vec<Regex> {
    patterns
        .iter()
        .filter(|pattern| !pattern.trim().is_empty())
        .filter_map(|pattern| glob_regex(&pattern.replace('\\', "/")).ok())
        .collect()
}

fn glob_regex(pattern: &str) -> Result<Regex, regex::Error> {
    let mut regex = String::from("^");
    for character in pattern.chars() {
        match character {
            '*' => regex.push_str(".*"),
            '?' => regex.push('.'),
            character if ".+()|[]{}^$\\".contains(character) => {
                regex.push('\\');
                regex.push(character);
            }
            character => regex.push(character),
        }
    }
    regex.push('$');
    Regex::new(&regex)
}

fn matches_any(relative_path: &str, patterns: &[Regex]) -> bool {
    patterns
        .iter()
        .any(|pattern| pattern.is_match(relative_path))
}

fn source_from_relative_path(relative_path: &str) -> String {
    let parts = relative_path.split('/').collect::<Vec<_>>();
    if parts.len() >= 2 && matches!(parts[0], "github" | "notebookarchive") {
        format!("{}/{}", parts[0], parts[1])
    } else {
        parts.first().copied().unwrap_or_default().into()
    }
}

fn collect_files(path: &Path, output: &mut Vec<PathBuf>) {
    if path.is_file() {
        output.push(path.to_path_buf());
        return;
    }
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            collect_files(&entry.path(), output);
        }
    }
}

fn counts<'a>(values: impl Iterator<Item = &'a str>) -> BTreeMap<String, usize> {
    let mut output = BTreeMap::new();
    for value in values {
        *output.entry(value.to_owned()).or_insert(0) += 1;
    }
    output
}

fn deterministic_shuffle<T>(values: &mut [T], mut state: u64) {
    for index in (1..values.len()).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let target = usize::try_from(state % (index as u64 + 1)).unwrap_or(0);
        values.swap(index, target);
    }
}

fn truncate(value: &str, limit: usize) -> String {
    if limit == 0 || value.chars().count() <= limit {
        return value.to_owned();
    }
    let mut output = value
        .chars()
        .take(limit.saturating_sub(3))
        .collect::<String>();
    while output.ends_with(char::is_whitespace) {
        output.pop();
    }
    output.push_str("...");
    output
}

fn elapsed_ms(start: Instant) -> f64 {
    round3(start.elapsed().as_secs_f64() * 1000.0)
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

fn rate(count: usize, elapsed_ms: f64) -> Option<f64> {
    (elapsed_ms > 0.0).then(|| round3(count as f64 / (elapsed_ms / 1000.0)))
}

fn form_label(form: ParseForm) -> &'static str {
    match form {
        ParseForm::Input => "input",
        ParseForm::Full => "fullform",
        ParseForm::Standard => "standard",
    }
}

fn optional_value_string(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::Null => None,
        Value::String(value) => Some(value.clone()),
        value => Some(value.to_string()),
    }
}

fn absolute_path(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        }
    })
}

fn slash_absolute(path: &Path) -> String {
    absolute_path(path).to_string_lossy().replace('\\', "/")
}

fn display_json(value: &Value) -> String {
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}

fn append_map_lines(lines: &mut Vec<String>, value: &Value, none_if_empty: bool) {
    let Some(object) = value.as_object() else {
        if none_if_empty {
            lines.push("- None".into());
        }
        return;
    };
    if object.is_empty() && none_if_empty {
        lines.push("- None".into());
    } else {
        for (key, value) in object {
            lines.push(format!("- `{key}`: `{}`", display_json(value)));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::licensing::unique_temp_directory;

    #[test]
    fn discovers_stable_wolfram_paths_and_sources() {
        let root = unique_temp_directory("tungsten-corpus-test").unwrap();
        fs::create_dir_all(root.join("github/sample")).unwrap();
        fs::create_dir_all(root.join("notebookarchive")).unwrap();
        fs::write(root.join("github/sample/expr.wl"), "1 + 2").unwrap();
        fs::write(root.join("github/sample/notes.txt"), "skip").unwrap();
        fs::write(
            root.join("notebookarchive/sample.nb"),
            r#"Notebook[{Cell["Hello", "Text"]}]"#,
        )
        .unwrap();
        let files = discover_corpus_files(&root, &CorpusDiscoveryOptions::default()).unwrap();
        assert_eq!(
            files
                .iter()
                .map(|file| file.relative_path.as_str())
                .collect::<Vec<_>>(),
            ["github/sample/expr.wl", "notebookarchive/sample.nb"]
        );
        assert_eq!(files[0].source, "github/sample");
        assert_eq!(files[1].kind, "notebook");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parses_source_notebook_and_failure_attempts() {
        let root = unique_temp_directory("tungsten-corpus-parse").unwrap();
        fs::write(root.join("expr.wl"), "1 + 2 x").unwrap();
        fs::write(
            root.join("sample.nb"),
            r#"Notebook[{Cell["Hello", "Text"]}]"#,
        )
        .unwrap();
        fs::write(root.join("bad.wl"), "x @= 1").unwrap();
        let files = discover_corpus_files(&root, &CorpusDiscoveryOptions::default())
            .unwrap()
            .into_iter()
            .map(|file| (file.relative_path.clone(), file))
            .collect::<HashMap<_, _>>();
        let source = parse_file_with_tungsten(&files["expr.wl"], ParseForm::Input, None, 2000);
        let notebook = parse_file_with_tungsten(&files["sample.nb"], ParseForm::Input, None, 2000);
        let bad = parse_file_with_tungsten(&files["bad.wl"], ParseForm::Input, None, 2000);
        assert_eq!(source.summary["full_form_preview"], "Plus[1, Times[2, x]]");
        assert_eq!(notebook.summary["cell_count"], 1);
        assert_eq!(bad.status, "failure");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn comparison_injection_classifies_and_writes_outputs() {
        let root = unique_temp_directory("tungsten-corpus-compare").unwrap();
        let output = root.join("out");
        fs::write(root.join("good.wl"), "1 + 2").unwrap();
        fs::write(root.join("bad.wl"), "x @= 1").unwrap();
        let mut parser = |batch: &[CorpusFile]| {
            batch
                .iter()
                .map(|file| {
                    (
                        file.relative_path.clone(),
                        ParserAttempt::success("wolfram", 0.0, json!({"fake": true})),
                    )
                })
                .collect()
        };
        let options = ParserCorpusOptions {
            out_dir: Some(output),
            ..ParserCorpusOptions::default()
        };
        let run = compare_parser_corpus(&root, &options, None, Some(&mut parser)).unwrap();
        assert_eq!(run.summary["outcomes"]["both_success"], 1);
        assert_eq!(run.summary["outcomes"]["tungsten_gap"], 1);
        assert!(Path::new(&run.output_files["summary"]).exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn oversized_files_are_skipped_before_batch_parser() {
        let root = unique_temp_directory("tungsten-corpus-size").unwrap();
        fs::write(root.join("large.wl"), "1".repeat(100)).unwrap();
        let mut called = false;
        let mut parser = |_batch: &[CorpusFile]| {
            called = true;
            HashMap::new()
        };
        let options = ParserCorpusOptions {
            max_bytes: Some(10),
            write_outputs: false,
            ..ParserCorpusOptions::default()
        };
        let run = compare_parser_corpus(&root, &options, None, Some(&mut parser)).unwrap();
        assert!(!called);
        assert_eq!(run.results[0].outcome, "skipped");
        assert_eq!(
            run.results[0].tungsten.error_type.as_deref(),
            Some("FileTooLarge")
        );
        fs::remove_dir_all(root).unwrap();
    }
}
