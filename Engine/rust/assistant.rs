//! Wolfram Notebook Assistant automation and response post-processing.

use crate::kernel::{KernelError, KernelEvaluationResult, WolframKernelRunner};
use crate::notebook::{NotebookDocument, NotebookError, NotebookRow};
use crate::wolfram_strings::{parse_wl_string_literal, wl_string};
use regex::Regex;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use thiserror::Error;

const DEFAULT_TOOLS: [&str; 3] = [
    "WolframLanguageEvaluator",
    "DocumentationSearcher",
    "WolframAlpha",
];

#[derive(Debug, Error)]
pub enum AssistantError {
    #[error(transparent)]
    Kernel(#[from] KernelError),
    #[error(transparent)]
    Notebook(#[from] NotebookError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("{0}")]
    InvalidSelector(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AssistantCellSelector {
    FlatIndex(usize),
    Path(Vec<usize>),
    ExpressionUuid(String),
    CellId(i64),
    CellTag(String),
}

#[derive(Clone, Debug)]
pub struct AskOptions {
    pub prompt: String,
    pub system_prompt: Option<String>,
    pub extra_instructions: Option<String>,
    pub model_service: Option<String>,
    pub model_name: Option<String>,
    pub tools: Option<Vec<String>>,
}

#[derive(Clone, Debug)]
pub struct AskCellOptions {
    pub notebook_path: PathBuf,
    pub selector: AssistantCellSelector,
    pub question: String,
    pub insert_wolfram_code: bool,
    pub insert_all_wolfram_code: bool,
    pub save_notebook: bool,
    pub close_assistant_notebook: bool,
    pub extra_instructions: Option<String>,
    pub model_service: Option<String>,
    pub model_name: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NotebookAssistantResult {
    pub evaluation: KernelEvaluationResult,
    pub payload: Value,
}

impl NotebookAssistantResult {
    pub fn assistant_success(&self) -> bool {
        self.payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    pub fn to_value(&self) -> Value {
        json!({
            "assistant_success": self.assistant_success(),
            "assistant": self.payload,
            "evaluation": self.evaluation.to_value(),
        })
    }
}

#[derive(Clone, Debug)]
pub struct NotebookAssistantController {
    pub runner: WolframKernelRunner,
}

impl Default for NotebookAssistantController {
    fn default() -> Self {
        Self::new(WolframKernelRunner::default())
    }
}

impl NotebookAssistantController {
    pub const fn new(runner: WolframKernelRunner) -> Self {
        Self { runner }
    }

    pub fn ask(&self, options: &AskOptions) -> Result<NotebookAssistantResult, AssistantError> {
        let evaluation = self
            .runner
            .evaluate_text(&self.build_ask_script(options)?, None, true)?;
        let payload = self.finalize_ask_payload(self.parse_payload(&evaluation));
        Ok(NotebookAssistantResult {
            evaluation,
            payload,
        })
    }

    pub fn ask_cell(
        &self,
        options: &AskCellOptions,
    ) -> Result<NotebookAssistantResult, AssistantError> {
        let document = NotebookDocument::load(&options.notebook_path)?;
        let source_row = resolve_row(&document, &options.selector)?;
        let selector = selector_for_kernel(&source_row, &options.selector);
        let insert_mode = insert_mode(options.insert_wolfram_code, options.insert_all_wolfram_code);
        let evaluation = self.runner.evaluate_text(
            &self.build_ask_cell_script(options, &selector)?,
            None,
            true,
        )?;
        let payload = self.finalize_ask_cell_payload(
            self.parse_payload(&evaluation),
            &options.notebook_path,
            &source_row,
            insert_mode,
            options.save_notebook,
        )?;
        Ok(NotebookAssistantResult {
            evaluation,
            payload,
        })
    }

    pub fn prepare_inline(
        &self,
        notebook_path: &Path,
        selector: &AssistantCellSelector,
    ) -> Result<NotebookAssistantResult, AssistantError> {
        let document = NotebookDocument::load(notebook_path)?;
        let row = resolve_row(&document, selector)?;
        let kernel_selector = selector_for_kernel(&row, selector);
        let script = build_prepare_inline_script(notebook_path, &kernel_selector)?;
        let evaluation = self.runner.evaluate_text(&script, None, true)?;
        let payload = self.parse_payload(&evaluation);
        Ok(NotebookAssistantResult {
            evaluation,
            payload,
        })
    }

    pub fn capture_inline(
        &self,
        notebook_path: &Path,
        selector: &AssistantCellSelector,
        insert_wolfram_code: bool,
        insert_all_wolfram_code: bool,
        save_notebook: bool,
    ) -> Result<NotebookAssistantResult, AssistantError> {
        let document = NotebookDocument::load(notebook_path)?;
        let row = resolve_row(&document, selector)?;
        let kernel_selector = selector_for_kernel(&row, selector);
        let script = build_capture_inline_script(
            notebook_path,
            &kernel_selector,
            insert_mode(insert_wolfram_code, insert_all_wolfram_code),
            save_notebook,
        )?;
        let evaluation = self.runner.evaluate_text(&script, None, true)?;
        let payload = self.parse_payload(&evaluation);
        Ok(NotebookAssistantResult {
            evaluation,
            payload,
        })
    }

    fn parse_payload(&self, evaluation: &KernelEvaluationResult) -> Value {
        if !evaluation.evaluation_available {
            return failure(
                "EvaluationUnavailable",
                if evaluation.stderr.is_empty() {
                    "The Wolfram evaluation did not produce a structured payload."
                } else {
                    &evaluation.stderr
                },
            );
        }
        if evaluation.success == Some(false) {
            let error = if !evaluation.stderr.is_empty() {
                evaluation.stderr.as_str()
            } else {
                evaluation
                    .result
                    .as_deref()
                    .unwrap_or("The Wolfram evaluation failed.")
            };
            return failure(
                evaluation
                    .failure_type
                    .as_deref()
                    .unwrap_or("KernelEvaluationFailure"),
                error,
            );
        }
        let Some(result) = evaluation
            .result
            .as_deref()
            .filter(|value| !value.is_empty())
        else {
            return failure(
                "MissingAssistantPayload",
                "The Wolfram evaluation completed but did not return an assistant payload.",
            );
        };
        let payload = parse_wl_string_literal(result)
            .map_err(|error| error.to_string())
            .and_then(|text| {
                serde_json::from_str::<Value>(&text).map_err(|error| error.to_string())
            });
        match payload {
            Ok(value @ Value::Object(_)) => value,
            Ok(value) => json!({
                "success": false,
                "error_type": "InvalidAssistantPayload",
                "error": "The assistant payload was not a JSON object.",
                "raw_payload": value,
            }),
            Err(error) => json!({
                "success": false,
                "error_type": "InvalidAssistantPayload",
                "error": format!("Unable to parse assistant payload JSON: {error}"),
                "raw_result": result,
            }),
        }
    }

    pub fn finalize_ask_payload(&self, payload: Value) -> Value {
        if !payload_success(&payload) {
            return payload;
        }
        let Some(chat) = payload
            .get("assistant_chat_object_string")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            return failure(
                "AssistantResponseUnavailable",
                "Notebook Assistant did not return a chat object string that Tungsten could inspect.",
            );
        };
        let response = extract_assistant_text(chat);
        if response.is_empty() {
            return json!({
                "success": false,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant completed, but Tungsten could not extract an assistant text response.",
                "assistant_chat_object_string": chat,
            });
        }
        enrich_response(payload, &response)
    }

    pub fn finalize_ask_cell_payload(
        &self,
        payload: Value,
        notebook_path: &Path,
        source_row: &NotebookRow,
        insert_mode: &str,
        save_notebook: bool,
    ) -> Result<Value, AssistantError> {
        if !payload_success(&payload) {
            return Ok(payload);
        }
        let source_cell = payload.get("source_cell").cloned().unwrap_or(Value::Null);
        let Some(chat) = payload
            .get("assistant_chat_object_string")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            return Ok(json!({
                "success": false,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant did not return a chat object string that Tungsten could inspect.",
                "source_cell": source_cell,
            }));
        };
        let response = extract_assistant_text(chat);
        if response.is_empty() {
            return Ok(json!({
                "success": false,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant completed, but Tungsten could not extract an assistant text response.",
                "source_cell": source_cell,
                "assistant_chat_object_string": chat,
            }));
        }
        let blocks = extract_code_blocks(&response);
        let wolfram = insertable_blocks(&blocks);
        let insertion = self.insert_code_blocks(
            notebook_path,
            source_row,
            &wolfram,
            insert_mode,
            save_notebook,
        )?;
        if !payload_success(&insertion) {
            return Ok(json!({
                "success": false,
                "error_type": insertion.get("error_type").cloned().unwrap_or(json!("InsertionFailure")),
                "error": insertion.get("error").cloned().unwrap_or(json!("Tungsten could not insert the generated Wolfram code.")),
                "source_cell": source_cell,
                "response_text": response,
                "code_blocks": blocks,
                "wolfram_code_blocks": wolfram,
            }));
        }
        let mut enriched = payload.as_object().cloned().unwrap_or_default();
        enriched.remove("assistant_chat_object_string");
        enriched.insert("response_text".into(), json!(response));
        enriched.insert("code_blocks".into(), Value::Array(blocks));
        enriched.insert("wolfram_code_blocks".into(), Value::Array(wolfram));
        enriched.insert("insert_mode".into(), json!(insert_mode));
        enriched.insert(
            "inserted".into(),
            insertion
                .get("inserted")
                .cloned()
                .unwrap_or_else(|| json!([])),
        );
        enriched.insert(
            "saved_notebook".into(),
            json!(
                insertion
                    .get("saved_notebook")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            ),
        );
        Ok(Value::Object(enriched))
    }

    fn insert_code_blocks(
        &self,
        notebook_path: &Path,
        source_row: &NotebookRow,
        blocks: &[Value],
        mode: &str,
        save_notebook: bool,
    ) -> Result<Value, AssistantError> {
        if mode == "none" || blocks.is_empty() {
            return Ok(json!({"success": true, "inserted": [], "saved_notebook": false}));
        }
        let take = if mode == "all" { blocks.len() } else { 1 };
        let codes = blocks
            .iter()
            .take(take)
            .filter_map(|block| block.get("code").and_then(Value::as_str))
            .filter(|code| !code.is_empty())
            .collect::<Vec<_>>();
        if codes.is_empty() {
            return Ok(json!({"success": true, "inserted": [], "saved_notebook": false}));
        }
        let selector = selector_from_row(source_row);
        let script = build_insert_script(notebook_path, &selector, &codes, save_notebook)?;
        let evaluation = self.runner.evaluate_text(&script, None, true)?;
        Ok(self.parse_payload(&evaluation))
    }

    pub fn build_ask_script(&self, options: &AskOptions) -> Result<String, AssistantError> {
        let mut settings = Map::new();
        settings.insert("AutoSaveConversations".into(), json!(false));
        settings.insert(
            "Tools".into(),
            json!(
                options
                    .tools
                    .as_deref()
                    .unwrap_or(&DEFAULT_TOOLS.map(str::to_owned))
            ),
        );
        if options.model_service.is_some() || options.model_name.is_some() {
            settings.insert(
                "Model".into(),
                json!({
                    "Service": options.model_service.as_deref().unwrap_or("Automatic"),
                    "Name": options.model_name.as_deref().unwrap_or("Automatic"),
                }),
            );
        }
        let settings = serde_json::to_string(&settings)?;
        Ok(ASK_SCRIPT
            .replace("__SETTINGS__", &wl_string(&settings))
            .replace("__PROMPT__", &wl_string(&options.prompt))
            .replace(
                "__SYSTEM_PROMPT__",
                &wl_string(options.system_prompt.as_deref().unwrap_or("").trim()),
            )
            .replace(
                "__EXTRA_INSTRUCTIONS__",
                &wl_string(options.extra_instructions.as_deref().unwrap_or("").trim()),
            ))
    }

    fn build_ask_cell_script(
        &self,
        options: &AskCellOptions,
        selector: &Value,
    ) -> Result<String, AssistantError> {
        let settings = assistant_settings(
            options.model_service.as_deref(),
            options.model_name.as_deref(),
        )?;
        let default_instructions = "Do not modify the notebook directly or use notebook-editing tools. Answer in chat only. If you provide Wolfram Language code, place it in a Wolfram Language code block.";
        let instructions = options.extra_instructions.as_deref().map_or_else(
            || default_instructions.to_owned(),
            |extra| format!("{default_instructions}\n\n{extra}"),
        );
        Ok(ASK_CELL_SCRIPT
            .replace("__HELPERS__", ASSISTANT_HELPERS)
            .replace(
                "__SELECTOR__",
                &wl_string(&serde_json::to_string(selector)?),
            )
            .replace("__SETTINGS__", &wl_string(&settings))
            .replace("__QUESTION__", &wl_string(&options.question))
            .replace(
                "__NOTEBOOK_PATH__",
                &wl_string(&absolute_slash_path(&options.notebook_path)),
            )
            .replace("__INSTRUCTIONS__", &wl_string(&instructions)))
    }
}

fn assistant_settings(
    service: Option<&str>,
    name: Option<&str>,
) -> Result<String, serde_json::Error> {
    let mut settings = json!({
        "AutoSaveConversations": false,
        "Tools": DEFAULT_TOOLS,
    });
    if service.is_some() || name.is_some() {
        settings["Model"] = json!({
            "Service": service.unwrap_or("Automatic"),
            "Name": name.unwrap_or("Automatic"),
        });
    }
    serde_json::to_string(&settings)
}

fn resolve_row(
    document: &NotebookDocument,
    selector: &AssistantCellSelector,
) -> Result<NotebookRow, AssistantError> {
    match selector {
        AssistantCellSelector::FlatIndex(index) => Ok(document.cell_at_flat_index(*index)?),
        AssistantCellSelector::Path(path) => Ok(document.cell_at_path(path)?),
        AssistantCellSelector::ExpressionUuid(value) => unique_row(document, |row| {
            row.expression_uuid.as_deref() == Some(value)
        }),
        AssistantCellSelector::CellId(value) => {
            unique_row(document, |row| row.cell_id == Some(*value))
        }
        AssistantCellSelector::CellTag(value) => {
            unique_row(document, |row| row.cell_tags.contains(value))
        }
    }
}

fn unique_row(
    document: &NotebookDocument,
    predicate: impl Fn(&NotebookRow) -> bool,
) -> Result<NotebookRow, AssistantError> {
    let matches = document
        .flattened_cells()
        .into_iter()
        .filter(predicate)
        .collect::<Vec<_>>();
    match matches.as_slice() {
        [row] => Ok(row.clone()),
        [] => Err(AssistantError::InvalidSelector(
            "The requested notebook cell selector did not match any cell in the notebook file."
                .into(),
        )),
        _ => Err(AssistantError::InvalidSelector(
            "The requested notebook cell selector matched more than one cell in the notebook file."
                .into(),
        )),
    }
}

fn selector_for_kernel(row: &NotebookRow, requested: &AssistantCellSelector) -> Value {
    match requested {
        AssistantCellSelector::ExpressionUuid(value) => json!({"expression_uuid": value}),
        AssistantCellSelector::CellId(value) => json!({"cell_id": value}),
        AssistantCellSelector::CellTag(value) => json!({"cell_tag": value}),
        AssistantCellSelector::FlatIndex(_) | AssistantCellSelector::Path(_) => {
            selector_from_row(row)
        }
    }
}

fn selector_from_row(row: &NotebookRow) -> Value {
    if let Some(value) = row
        .expression_uuid
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        json!({"expression_uuid": value})
    } else if let Some(value) = row.cell_id {
        json!({"cell_id": value})
    } else if let Some(value) = row.cell_tags.first().filter(|value| !value.is_empty()) {
        json!({"cell_tag": value})
    } else {
        json!({"cell_index": row.index})
    }
}

fn payload_success(payload: &Value) -> bool {
    payload
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn failure(error_type: &str, error: &str) -> Value {
    json!({"success": false, "error_type": error_type, "error": error})
}

fn insert_mode(first: bool, all: bool) -> &'static str {
    if all {
        "all"
    } else if first {
        "first"
    } else {
        "none"
    }
}

fn enrich_response(payload: Value, response: &str) -> Value {
    let blocks = extract_code_blocks(response);
    let wolfram = insertable_blocks(&blocks);
    let mut enriched = payload.as_object().cloned().unwrap_or_default();
    enriched.remove("assistant_chat_object_string");
    enriched.insert("response_text".into(), json!(response));
    enriched.insert("code_blocks".into(), Value::Array(blocks));
    enriched.insert("wolfram_code_blocks".into(), Value::Array(wolfram));
    Value::Object(enriched)
}

pub fn extract_assistant_text(chat_object_string: &str) -> String {
    let section_regex = Regex::new(
        r#"(?s)<\|"Role"\s*->\s*"Assistant".*?"Content"\s*->\s*\{(.*?)\}\s*,\s*"Metadata"\s*->"#,
    )
    .expect("valid assistant section regex");
    let Some(section) = section_regex
        .captures_iter(chat_object_string)
        .last()
        .and_then(|captures| captures.get(1))
    else {
        return String::new();
    };
    let data_regex = Regex::new(r#"(?s)"Type"\s*->\s*"Text"\s*,\s*"Data"\s*->\s*"(.*?)""#)
        .expect("valid assistant data regex");
    data_regex
        .captures_iter(section.as_str())
        .filter_map(|captures| captures.get(1))
        .map(|value| decode_chat_string(value.as_str()))
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn decode_chat_string(value: &str) -> String {
    let quoted = format!("\"{value}\"");
    let decoded = serde_json::from_str::<String>(&quoted).unwrap_or_else(|_| value.to_owned());
    if decoded.contains("\\n")
        || decoded.contains("\\t")
        || decoded.contains("\\\"")
        || decoded.contains("\\\\")
    {
        decode_backslash_escapes(&decoded)
    } else {
        decoded
    }
}

fn decode_backslash_escapes(value: &str) -> String {
    let mut output = String::new();
    let mut characters = value.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            output.push(character);
            continue;
        }
        match characters.next() {
            Some('n') => output.push('\n'),
            Some('r') => output.push('\r'),
            Some('t') => output.push('\t'),
            Some('"') => output.push('"'),
            Some('\\') => output.push('\\'),
            Some(other) => {
                output.push('\\');
                output.push(other);
            }
            None => output.push('\\'),
        }
    }
    output
}

pub fn extract_code_blocks(response_text: &str) -> Vec<Value> {
    let regex = Regex::new(r"(?s)```([^\n`]*)\n(.*?)```").expect("valid code block regex");
    regex
        .captures_iter(response_text)
        .enumerate()
        .map(|(index, captures)| {
            let language = captures[1].trim();
            let normalized = language
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .to_lowercase();
            let insertable = matches!(
                normalized.as_str(),
                "wolfram" | "wolfram language" | "wolframlanguage" | "mathematica" | "wl"
            );
            json!({
                "index": index,
                "language": if language.is_empty() { "Unknown" } else { language },
                "code": captures[2].trim(),
                "insertable": insertable,
            })
        })
        .collect()
}

fn insertable_blocks(blocks: &[Value]) -> Vec<Value> {
    blocks
        .iter()
        .filter(|block| {
            block
                .get("insertable")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .cloned()
        .collect()
}

fn absolute_slash_path(path: &Path) -> String {
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    absolute.to_string_lossy().replace('\\', "/")
}

fn build_insert_script(
    notebook_path: &Path,
    selector: &Value,
    codes: &[&str],
    save: bool,
) -> Result<String, AssistantError> {
    Ok(INSERT_SCRIPT
        .replace("__HELPERS__", ASSISTANT_HELPERS)
        .replace(
            "__SELECTOR__",
            &wl_string(&serde_json::to_string(selector)?),
        )
        .replace("__CODES__", &wl_string(&serde_json::to_string(codes)?))
        .replace(
            "__NOTEBOOK_PATH__",
            &wl_string(&absolute_slash_path(notebook_path)),
        )
        .replace("__SAVE__", if save { "True" } else { "False" }))
}

fn build_prepare_inline_script(
    notebook_path: &Path,
    selector: &Value,
) -> Result<String, AssistantError> {
    Ok(PREPARE_INLINE_SCRIPT
        .replace("__HELPERS__", ASSISTANT_HELPERS)
        .replace(
            "__SELECTOR__",
            &wl_string(&serde_json::to_string(selector)?),
        )
        .replace(
            "__NOTEBOOK_PATH__",
            &wl_string(&absolute_slash_path(notebook_path)),
        ))
}

fn build_capture_inline_script(
    notebook_path: &Path,
    selector: &Value,
    mode: &str,
    save: bool,
) -> Result<String, AssistantError> {
    Ok(CAPTURE_INLINE_SCRIPT
        .replace("__HELPERS__", ASSISTANT_HELPERS)
        .replace(
            "__SELECTOR__",
            &wl_string(&serde_json::to_string(selector)?),
        )
        .replace(
            "__NOTEBOOK_PATH__",
            &wl_string(&absolute_slash_path(notebook_path)),
        )
        .replace("__MODE__", &wl_string(mode))
        .replace("__SAVE__", if save { "True" } else { "False" }))
}

const ASSISTANT_HELPERS: &str = r#"
ClearAll[tungstenError, tungstenStringValue, tungstenStringList, tungstenCellMetadata,
    tungstenFindNotebook, tungstenResolveNotebook, tungstenResolveCell];
tungstenError[type_String, message_String, extra_: <||>] :=
    Join[<|"success" -> False, "error_type" -> type, "error" -> message|>, extra];
tungstenStringValue[value_] := Replace[value, {None | Null | Inherited | Missing[__] -> Null,
    s_String :> s, other_ :> ToString[Unevaluated[other], InputForm, PageWidth -> Infinity]}];
tungstenStringList[value_] := Replace[value, {s_String :> {s},
    list_List :> Cases[list, tag_String :> tag, Infinity], _ :> {}}];
tungstenCellMetadata[cell_CellObject] := <|
    "expression_uuid" -> tungstenStringValue @ CurrentValue[cell, ExpressionUUID],
    "cell_id" -> Replace[CurrentValue[cell, CellID], {value_Integer :> value, _ :> Null}],
    "cell_tags" -> tungstenStringList @ CurrentValue[cell, CellTags],
    "style" -> tungstenStringValue @ CurrentValue[cell, CellStyle],
    "preview" -> StringTake[ToString[NotebookRead[cell], InputForm, PageWidth -> Infinity], UpTo[240]]|>;
tungstenFindNotebook[path_String] := SelectFirst[Notebooks[],
    Quiet @ Check[NotebookFileName[#] === path, False] &, Missing["NotFound"]];
tungstenResolveNotebook[path_String] := Module[{existing, opened},
    existing = tungstenFindNotebook[path]; If[MatchQ[existing, _NotebookObject], Return[existing]];
    opened = Quiet @ Check[NotebookOpen[path], $Failed];
    If[MatchQ[opened, _NotebookObject], opened,
        tungstenError["NotebookOpenFailed", "Unable to open the requested notebook.", <|"notebook_path" -> path|>]]];
tungstenResolveCell[nbo_NotebookObject, selector_Association] := Module[{matches = {}, index, cells},
    Which[StringQ @ Lookup[selector, "expression_uuid", Missing[]],
            matches = Cells[nbo, ExpressionUUID -> selector["expression_uuid"]],
        IntegerQ @ Lookup[selector, "cell_id", Missing[]], matches = Cells[nbo, CellID -> selector["cell_id"]],
        StringQ @ Lookup[selector, "cell_tag", Missing[]], matches = Cells[nbo, CellTags -> selector["cell_tag"]],
        IntegerQ @ Lookup[selector, "cell_index", Missing[]], cells = Cells[nbo]; index = selector["cell_index"] + 1;
            matches = If[1 <= index <= Length[cells], {cells[[index]]}, {}]];
    Which[Length[matches] == 1, First[matches], Length[matches] == 0,
        tungstenError["CellNotFound", "No notebook cell matched the requested selector.", <|"selector" -> selector|>],
        True, tungstenError["AmbiguousCellSelector", "More than one notebook cell matched the requested selector.",
            <|"selector" -> selector, "match_count" -> Length[matches]|>]]];
"#;

const ASK_SCRIPT: &str = r#"Needs["Wolfram`Chatbook`" -> None];
tungstenSettings = ImportString[__SETTINGS__, "RawJSON"];
tungstenPrompt = __PROMPT__;
tungstenSystemPrompt = __SYSTEM_PROMPT__;
tungstenExtraInstructions = __EXTRA_INSTRUCTIONS__;
tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];
tungstenResult = Module[{assistantNotebook, chatCell, chatObject, chatRaw, combinedPrompt},
 combinedPrompt = Which[tungstenSystemPrompt =!= "" && tungstenExtraInstructions =!= "",
   tungstenSystemPrompt <> "\n\n" <> tungstenPrompt <> "\n\n" <> tungstenExtraInstructions,
   tungstenSystemPrompt =!= "", tungstenSystemPrompt <> "\n\n" <> tungstenPrompt,
   tungstenExtraInstructions =!= "", tungstenPrompt <> "\n\n" <> tungstenExtraInstructions, True, tungstenPrompt];
 assistantNotebook = Quiet @ Check[CreateDocument[Notebook[{Cell["Tungsten Assistant Ask Session", "Section"]}], Visible -> False], $Failed];
 If[!MatchQ[assistantNotebook, _NotebookObject],
  <|"success" -> False, "error_type" -> "AssistantNotebookCreateFailed",
    "error" -> "Tungsten could not create the temporary Notebook Assistant notebook."|>,
  CurrentValue[assistantNotebook, {TaggingRules, "ChatNotebookSettings"}] = tungstenSettings;
  SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
  NotebookWrite[assistantNotebook, Cell[combinedPrompt, "ChatInput"]];
  chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];
  chatObject = Quiet @ Check[If[MatchQ[chatCell, _CellObject],
    tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed], $Failed];
  chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];
  Quiet @ Check[NotebookClose[assistantNotebook], Null];
  <|"success" -> True, "prompt" -> tungstenPrompt, "assistant_chat_object_string" -> chatRaw|>]];
ExportString[tungstenResult, "RawJSON"]"#;

const ASK_CELL_SCRIPT: &str = r#"Needs["Wolfram`Chatbook`" -> None];
tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenSettings = ImportString[__SETTINGS__, "RawJSON"];
tungstenQuestion = __QUESTION__; tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenExtraInstructions = __INSTRUCTIONS__;
tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];
__HELPERS__
tungstenResult = Module[{sourceNotebook, sourceCell, assistantNotebook, chatCell, chatObject, chatRaw, sourceText},
 sourceNotebook = tungstenResolveNotebook[tungstenNotebookPath]; If[AssociationQ[sourceNotebook], sourceNotebook,
 sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector]; If[AssociationQ[sourceCell], sourceCell,
 sourceText = ToString[NotebookRead[sourceCell], InputForm, PageWidth -> Infinity];
 assistantNotebook = Quiet @ Check[CreateDocument[Notebook[{Cell["Tungsten Notebook Assistant Session", "Section"]}], Visible -> False], $Failed];
 If[!MatchQ[assistantNotebook, _NotebookObject], tungstenError["AssistantNotebookCreateFailed", "Tungsten could not create the temporary Notebook Assistant notebook."],
 CurrentValue[assistantNotebook, {TaggingRules, "ChatNotebookSettings"}] = tungstenSettings;
 NotebookWrite[assistantNotebook, Cell[StringJoin[tungstenQuestion, "\n\nSource notebook cell contents:\n", sourceText,
   "\n\n", tungstenExtraInstructions], "ChatInput"]]; chatCell = Last[Cells[assistantNotebook]];
 chatObject = Quiet @ Check[tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed];
 chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity]; Quiet @ Check[NotebookClose[assistantNotebook], Null];
 <|"success" -> True, "notebook_path" -> tungstenNotebookPath, "question" -> tungstenQuestion,
 "selector" -> tungstenSelector, "source_cell" -> tungstenCellMetadata[sourceCell],
 "assistant_notebook_mode" -> "TemporaryHiddenChatNotebook", "assistant_notebook_closed" -> True,
 "assistant_chat_object_string" -> chatRaw|>]]]];
ExportString[tungstenResult, "RawJSON"]"#;

const INSERT_SCRIPT: &str = r#"tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenCodes = ImportString[__CODES__, "RawJSON"]; tungstenNotebookPath = __NOTEBOOK_PATH__; tungstenSaveNotebook = __SAVE__;
__HELPERS__
tungstenResult = Module[{nbo, source, point, inserted = {}, code, uuid, cell},
 nbo = tungstenResolveNotebook[tungstenNotebookPath]; If[AssociationQ[nbo], nbo,
 source = tungstenResolveCell[nbo, tungstenSelector]; If[AssociationQ[source], source, point = source;
 Do[uuid = CreateUUID[]; SelectionMove[point, After, Cell, AutoScroll -> False];
 NotebookWrite[nbo, Cell[code, "Input", ExpressionUUID -> uuid], All, AutoScroll -> False];
 cell = Quiet @ Check[First[Cells[nbo, ExpressionUUID -> uuid]], None]; If[MatchQ[cell, _CellObject], point = cell];
 AppendTo[inserted, <|"expression_uuid" -> uuid, "cell_id" -> Replace[If[MatchQ[cell, _CellObject], CurrentValue[cell, CellID], Null], {i_Integer :> i, _ :> Null}], "code" -> code|>], {code, tungstenCodes}];
 If[TrueQ[tungstenSaveNotebook], NotebookSave[nbo]];
 <|"success" -> True, "source_cell" -> tungstenCellMetadata[source], "inserted" -> inserted,
 "saved_notebook" -> TrueQ[tungstenSaveNotebook]|>]]]; ExportString[tungstenResult, "RawJSON"]"#;

const PREPARE_INLINE_SCRIPT: &str = r#"Needs["Wolfram`Chatbook`" -> None];
tungstenSelector = ImportString[__SELECTOR__, "RawJSON"]; tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenShowNotebookAssistance = Symbol["Wolfram`Chatbook`ShowNotebookAssistance"];
__HELPERS__
tungstenResult = Module[{nbo, source, attached}, nbo = tungstenResolveNotebook[tungstenNotebookPath];
 If[AssociationQ[nbo], nbo, SetSelectedNotebook[nbo]; source = tungstenResolveCell[nbo, tungstenSelector];
 If[AssociationQ[source], source, SelectionMove[source, All, Cell, AutoScroll -> True];
 attached = Quiet @ Check[tungstenShowNotebookAssistance[source, "Inline", EvaluateInput -> False], $Failed];
 If[!MatchQ[attached, _CellObject], tungstenError["InlineAssistantOpenFailed", "Notebook Assistant inline input was not created."],
 SelectionMove[attached, Before, Cell, AutoScroll -> True]; FrontEnd`MoveCursorToInputField[nbo, "AttachedChatInputField"];
 <|"success" -> True, "notebook_path" -> tungstenNotebookPath, "source_cell" -> tungstenCellMetadata[source],
 "inline_cell_style" -> tungstenStringValue @ CurrentValue[attached, CellStyle]|>]]]];
ExportString[tungstenResult, "RawJSON"]"#;

const CAPTURE_INLINE_SCRIPT: &str = r#"Needs["Wolfram`Chatbook`" -> None];
tungstenSelector = ImportString[__SELECTOR__, "RawJSON"]; tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenInsertMode = __MODE__; tungstenSaveNotebook = __SAVE__;
__HELPERS__
tungstenResult = Module[{nbo, source, attached, expr, input, outputs, response, progress, completed},
 nbo = tungstenResolveNotebook[tungstenNotebookPath]; If[AssociationQ[nbo], nbo,
 source = tungstenResolveCell[nbo, tungstenSelector]; If[AssociationQ[source], source,
 attached = SelectFirst[Cells[nbo, AttachedCell -> True, CellStyle -> "AttachedChatInput"], True &, None];
 If[!MatchQ[attached, _CellObject], tungstenError["InlineAssistantNotFound", "No inline Notebook Assistant input is currently attached to the requested source cell."],
 expr = Quiet @ Check[NotebookRead[attached], $Failed]; input = Quiet @ Check[CurrentValue[attached, {TaggingRules, "ChatInputString"}], ""];
 outputs = Cases[expr, cell : Cell[_, "ChatOutput", ___] :> cell, Infinity];
 response = StringRiffle[ToString[#, InputForm, PageWidth -> Infinity] & /@ outputs, "\n\n"];
 progress = !FreeQ[expr, _ProgressIndicator | _ProgressIndicatorBox, Infinity];
 completed = StringQ[input] && input == "" && Length[outputs] > 0 && !progress;
 <|"success" -> True, "completed" -> completed, "has_progress_indicator" -> progress,
 "inline_attached" -> True, "notebook_path" -> tungstenNotebookPath, "source_cell" -> tungstenCellMetadata[source],
 "input_string" -> tungstenStringValue[input], "response_text" -> response,
 "assistant_output_count" -> Length[outputs], "code_blocks" -> {}, "wolfram_code_blocks" -> {},
 "insert_mode" -> tungstenInsertMode, "inserted" -> {}, "saved_notebook" -> False|>]]]];
ExportString[tungstenResult, "RawJSON"]"#;

#[cfg(test)]
mod tests {
    use super::*;

    fn controller() -> NotebookAssistantController {
        NotebookAssistantController::default()
    }

    fn chat(data: &str) -> String {
        format!(
            "ChatObject[<|\"Messages\" -> {{<|\"Role\" -> \"Assistant\", \"Content\" -> {{<|\"Type\" -> \"Text\", \"Data\" -> \"{data}\"|>}}, \"Metadata\" -> <||>|>}}|>]"
        )
    }

    #[test]
    fn extracts_assistant_text_and_wolfram_code_blocks() {
        let response = extract_assistant_text(&chat("```wolfram\\\\n2 + 2\\\\n```"));
        assert_eq!(response, "```wolfram\n2 + 2\n```");
        let blocks = extract_code_blocks(&response);
        assert_eq!(blocks[0]["language"], "wolfram");
        assert_eq!(blocks[0]["code"], "2 + 2");
        assert_eq!(blocks[0]["insertable"], true);
    }

    #[test]
    fn finalizes_bare_payload_and_removes_raw_chat_object() {
        let payload = json!({
            "success": true,
            "prompt": "question",
            "assistant_chat_object_string": chat("Use Integrate.\\\\n```wolfram\\\\nIntegrate[x,x]\\\\n```")
        });
        let finalized = controller().finalize_ask_payload(payload);
        assert_eq!(finalized["success"], true);
        assert_eq!(
            finalized["wolfram_code_blocks"][0]["code"],
            "Integrate[x,x]"
        );
        assert!(finalized.get("assistant_chat_object_string").is_none());
    }

    #[test]
    fn missing_chat_string_is_a_structured_failure() {
        let finalized = controller().finalize_ask_payload(json!({"success": true}));
        assert_eq!(finalized["success"], false);
        assert_eq!(finalized["error_type"], "AssistantResponseUnavailable");
    }

    #[test]
    fn ask_script_contains_chatbook_settings_and_no_cell_resolution() {
        let script = controller()
            .build_ask_script(&AskOptions {
                prompt: "What is Hypergeometric2F1[1, 1, 2, z]?".into(),
                system_prompt: Some("You answer Wolfram-Language questions.".into()),
                extra_instructions: Some("Use a fenced Wolfram code block.".into()),
                model_service: None,
                model_name: None,
                tools: None,
            })
            .unwrap();
        assert!(script.contains("Needs[\"Wolfram`Chatbook`\" -> None]"));
        assert!(script.contains("WolframLanguageEvaluator"));
        assert!(script.contains("DocumentationSearcher"));
        assert!(script.contains("Hypergeometric2F1"));
        assert!(script.contains("\"ChatInput\""));
        assert!(script.contains("tungstenChatCellEvaluate[chatCell, assistantNotebook]"));
        assert!(!script.contains("tungstenResolveNotebook"));
        assert!(!script.contains("tungstenResolveCell"));
    }
}
