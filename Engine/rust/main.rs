use clap::{Args, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};
use std::error::Error;
use std::fs;
use std::io::BufRead as _;
use std::path::PathBuf;
use tungsten::assistant::{
    AskCellOptions, AskOptions, AssistantCellSelector, NotebookAssistantController,
};
use tungsten::discovery::discover_installation;
use tungsten::docs_index::DocumentationIndex;
use tungsten::frontend::FrontEndController;
use tungsten::inline_boxes::{
    InlineBoxCellSelector, InlineBoxExtractionOptions, compose_inline_box_payload,
    extract_inline_boxes_from_notebook_cell,
};
use tungsten::kernel::WolframKernelRunner;
use tungsten::notebook::{NotebookDocument, NotebookError, apply_patch_spec, load_patch_spec};
use tungsten::parser_corpus::{
    CorpusDiscoveryOptions, DEFAULT_CORPUS_ROOT, DEFAULT_EXTENSIONS, ParserCorpusOptions,
    compare_parser_corpus, discover_corpus_files, summarize_discovery,
};
use tungsten::repl::run_repl;
use tungsten::wolfram_strings::wl_string;
use tungsten::{Evaluator, Expr, ParseForm, evaluate, parse_expression};

#[derive(Debug, Parser)]
#[command(name = "tungsten-rs", version, about = "Native Rust Tungsten Engine")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Start the stateful kernel-free Wolfram interpreter.
    Repl {
        #[arg(long)]
        no_banner: bool,
    },
    /// Parse a Wolfram expression without starting a kernel.
    Parse {
        #[arg(long, allow_hyphen_values = true)]
        code: String,
        #[arg(long, value_enum, default_value_t = FormArg::Input)]
        form: FormArg,
        #[arg(long)]
        full_form: bool,
        #[arg(long, conflicts_with = "full_form")]
        input_form: bool,
    },
    /// Parse and evaluate a Wolfram expression without starting a kernel.
    Eval {
        #[arg(long, allow_hyphen_values = true)]
        code: String,
        #[arg(long)]
        input_form: bool,
    },
    /// Migration-only JSON-lines evaluator used by differential checks.
    #[command(hide = true)]
    EvalBatch {
        #[arg(long)]
        stateful: bool,
    },
    /// Parse or structurally evaluate expressions with JSON output.
    Expr {
        #[command(subcommand)]
        command: ExprCommand,
    },
    /// Inspect, create, or source-patch notebook files.
    Notebook {
        #[command(subcommand)]
        command: NotebookCommand,
    },
    /// Compose or extract strings containing embedded box expressions.
    InlineBox {
        #[command(subcommand)]
        command: InlineBoxCommand,
    },
    /// Inspect the local Tungsten and Wolfram environment.
    Env {
        #[command(subcommand)]
        command: EnvCommand,
    },
    /// Evaluate code through the discovered local Wolfram kernel.
    Kernel {
        #[command(subcommand)]
        command: KernelCommand,
    },
    /// Discover and compare Wolfram parser-corpus files.
    ParserCorpus {
        #[command(subcommand)]
        command: ParserCorpusCommand,
    },
    /// Index, search, and read local Wolfram documentation.
    Docs {
        #[command(subcommand)]
        command: DocsCommand,
    },
    /// Programmatically drive Wolfram FrontEnd actions.
    Frontend {
        #[command(subcommand)]
        command: FrontendCommand,
    },
    /// Drive the built-in Wolfram Notebook Assistant.
    Assistant {
        #[command(subcommand)]
        command: AssistantCommand,
    },
}

#[derive(Debug, Subcommand)]
enum AssistantCommand {
    Ask {
        #[arg(long)]
        prompt: String,
        #[arg(long)]
        system_prompt: Option<String>,
        #[arg(long)]
        extra_instructions: Option<String>,
        #[arg(long = "tool")]
        tools: Vec<String>,
        #[arg(long)]
        model_service: Option<String>,
        #[arg(long)]
        model_name: Option<String>,
        #[arg(long)]
        require_success: bool,
    },
    AskCell {
        #[arg(long)]
        file: PathBuf,
        #[command(flatten)]
        selector: CellSelectorArgs,
        #[arg(long)]
        question: String,
        #[arg(long)]
        insert_wolfram_code_below: bool,
        #[arg(long)]
        insert_all_wolfram_code_below: bool,
        #[arg(long)]
        save: bool,
        #[arg(long)]
        close_assistant_notebook: bool,
        #[arg(long)]
        extra_instructions: Option<String>,
        #[arg(long)]
        model_service: Option<String>,
        #[arg(long)]
        model_name: Option<String>,
        #[arg(long)]
        require_success: bool,
    },
    PrepareInline {
        #[arg(long)]
        file: PathBuf,
        #[command(flatten)]
        selector: CellSelectorArgs,
        #[arg(long)]
        require_success: bool,
    },
    CaptureInline {
        #[arg(long)]
        file: PathBuf,
        #[command(flatten)]
        selector: CellSelectorArgs,
        #[arg(long)]
        insert_wolfram_code_below: bool,
        #[arg(long)]
        insert_all_wolfram_code_below: bool,
        #[arg(long)]
        save: bool,
        #[arg(long)]
        require_success: bool,
    },
}

#[derive(Debug, Subcommand)]
enum FrontendCommand {
    Probe {
        #[arg(long)]
        require_success: bool,
    },
    OpenNotebook {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        require_success: bool,
    },
    OpenDoc {
        identifier: String,
        #[arg(long)]
        index_path: Option<PathBuf>,
        #[arg(long)]
        require_success: bool,
    },
    Run {
        #[arg(long, allow_hyphen_values = true)]
        code: String,
        #[arg(long)]
        no_wrap: bool,
        #[arg(long)]
        require_success: bool,
    },
    Token {
        token: String,
        #[arg(long)]
        file: Option<PathBuf>,
        #[arg(long)]
        require_success: bool,
    },
}

#[derive(Debug, Subcommand)]
enum DocsCommand {
    Index {
        #[arg(long)]
        path: Option<PathBuf>,
    },
    Search {
        query: String,
        #[arg(long, default_value_t = 10)]
        limit: usize,
        #[arg(long)]
        index_path: Option<PathBuf>,
        #[arg(long)]
        rebuild: bool,
    },
    Read {
        identifier: String,
        #[arg(long)]
        index_path: Option<PathBuf>,
        #[arg(long)]
        rebuild: bool,
    },
    Open {
        identifier: String,
        #[arg(long)]
        index_path: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum ParserCorpusCommand {
    Discover {
        #[command(flatten)]
        discovery: ParserCorpusDiscoveryArgs,
        #[arg(long, default_value_t = 20)]
        sample: usize,
    },
    Compare {
        #[command(flatten)]
        discovery: ParserCorpusDiscoveryArgs,
        #[arg(long)]
        out_dir: Option<PathBuf>,
        #[arg(long, default_value_t = 2.0)]
        max_file_mb: f64,
        #[arg(long)]
        max_bytes: Option<usize>,
        #[arg(long)]
        no_max_bytes: bool,
        #[arg(long, value_enum, default_value_t = FormArg::Input)]
        form: FormArg,
        #[arg(long)]
        skip_wolfram: bool,
        #[arg(long, default_value_t = 100)]
        kernel_batch_size: usize,
        #[arg(long, default_value_t = 1)]
        tungsten_workers: usize,
        #[arg(long, default_value_t = 2_000)]
        preview_chars: usize,
        #[arg(long)]
        no_write: bool,
        #[arg(long)]
        include_results: bool,
        #[arg(long)]
        fail_on_tungsten_gap: bool,
        #[arg(long)]
        fail_on_mismatch: bool,
    },
}

#[derive(Debug, Args)]
struct ParserCorpusDiscoveryArgs {
    #[arg(long, default_value = DEFAULT_CORPUS_ROOT)]
    corpus_root: PathBuf,
    #[arg(long = "extension")]
    extensions: Vec<String>,
    #[arg(long = "include-glob")]
    include_globs: Vec<String>,
    #[arg(long = "exclude-glob")]
    exclude_globs: Vec<String>,
    #[arg(long)]
    max_files: Option<usize>,
    #[arg(long)]
    shuffle: bool,
    #[arg(long, default_value_t = 0)]
    seed: u64,
}

impl ParserCorpusDiscoveryArgs {
    fn options(&self) -> CorpusDiscoveryOptions {
        CorpusDiscoveryOptions {
            extensions: if self.extensions.is_empty() {
                DEFAULT_EXTENSIONS.iter().map(ToString::to_string).collect()
            } else {
                self.extensions.clone()
            },
            include_globs: self.include_globs.clone(),
            exclude_globs: self.exclude_globs.clone(),
            max_files: self.max_files,
            shuffle: self.shuffle,
            seed: self.seed,
        }
    }
}

#[derive(Debug, Subcommand)]
enum EnvCommand {
    Show {
        #[arg(long)]
        probe: bool,
    },
}

#[derive(Debug, Subcommand)]
enum KernelCommand {
    Eval {
        #[command(flatten)]
        source: ExpressionSource,
        #[arg(long)]
        working_directory: Option<PathBuf>,
        #[arg(long = "front-end")]
        front_end: bool,
        #[arg(long)]
        require_success: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ExprCommand {
    Parse {
        #[command(flatten)]
        source: ExpressionSource,
        #[arg(long, value_enum, default_value_t = FormArg::Input)]
        form: FormArg,
    },
    Evaluate {
        #[command(flatten)]
        source: ExpressionSource,
        #[arg(long, value_enum, default_value_t = FormArg::Input)]
        form: FormArg,
    },
}

#[derive(Debug, Args)]
struct ExpressionSource {
    #[arg(long, allow_hyphen_values = true, required_unless_present = "file")]
    code: Option<String>,
    #[arg(long, conflicts_with = "code")]
    file: Option<PathBuf>,
}

#[derive(Debug, Subcommand)]
enum NotebookCommand {
    Inspect {
        #[arg(long)]
        file: PathBuf,
    },
    Create {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        title: Option<String>,
        #[arg(long = "cell")]
        cells: Vec<String>,
    },
    Patch {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        spec: PathBuf,
        #[arg(long)]
        out: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum InlineBoxCommand {
    Compose {
        #[arg(long, default_value = "")]
        prefix: String,
        #[arg(long = "box-expr")]
        box_expressions: Vec<String>,
        #[arg(long, default_value = "")]
        suffix: String,
    },
    FromCell {
        #[arg(long)]
        file: PathBuf,
        #[command(flatten)]
        selector: CellSelectorArgs,
        #[arg(long, default_value = "")]
        prefix: String,
        #[arg(long, default_value = "")]
        suffix: String,
        #[arg(long, default_value_t = 0)]
        object_index: usize,
        #[arg(long)]
        all_objects: bool,
        #[arg(long)]
        require_success: bool,
    },
}

#[derive(Debug, Args)]
#[group(required = true, multiple = false)]
struct CellSelectorArgs {
    #[arg(long, group = "selector")]
    cell_index: Option<usize>,
    #[arg(long, group = "selector", value_parser = parse_cell_path)]
    cell_path: Option<Vec<usize>>,
    #[arg(long, group = "selector")]
    expression_uuid: Option<String>,
    #[arg(long, group = "selector")]
    cell_id: Option<i64>,
    #[arg(long, group = "selector")]
    cell_tag: Option<String>,
}

impl CellSelectorArgs {
    fn into_selector(self) -> InlineBoxCellSelector {
        if let Some(value) = self.cell_index {
            InlineBoxCellSelector::FlatIndex(value)
        } else if let Some(value) = self.cell_path {
            InlineBoxCellSelector::Path(value)
        } else if let Some(value) = self.expression_uuid {
            InlineBoxCellSelector::ExpressionUuid(value)
        } else if let Some(value) = self.cell_id {
            InlineBoxCellSelector::CellId(value)
        } else {
            InlineBoxCellSelector::CellTag(
                self.cell_tag
                    .expect("clap requires exactly one cell selector"),
            )
        }
    }

    fn into_assistant_selector(self) -> AssistantCellSelector {
        if let Some(value) = self.cell_index {
            AssistantCellSelector::FlatIndex(value)
        } else if let Some(value) = self.cell_path {
            AssistantCellSelector::Path(value)
        } else if let Some(value) = self.expression_uuid {
            AssistantCellSelector::ExpressionUuid(value)
        } else if let Some(value) = self.cell_id {
            AssistantCellSelector::CellId(value)
        } else {
            AssistantCellSelector::CellTag(
                self.cell_tag
                    .expect("clap requires exactly one cell selector"),
            )
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum FormArg {
    Input,
    #[value(alias = "fullform")]
    Full,
    Standard,
}

impl FormArg {
    const fn label(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Full => "fullform",
            Self::Standard => "standard",
        }
    }
}

impl From<FormArg> for ParseForm {
    fn from(value: FormArg) -> Self {
        match value {
            FormArg::Input => Self::Input,
            FormArg::Full => Self::Full,
            FormArg::Standard => Self::Standard,
        }
    }
}

fn main() {
    let result = if std::env::args_os().len() == 1 {
        execute_repl(false)
    } else {
        execute(Cli::parse())
    };
    match result {
        Ok(0) => {}
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2);
        }
    }
}

fn execute(cli: Cli) -> Result<i32, Box<dyn Error>> {
    let Some(command) = cli.command else {
        return execute_repl(false);
    };
    match command {
        Command::Repl { no_banner } => execute_repl(no_banner),
        Command::Parse {
            code,
            form,
            full_form,
            input_form,
        } => {
            let expression = parse_expression(&code, form.into())?;
            if full_form {
                println!("{}", expression.to_full_form());
            } else if input_form {
                println!("{}", expression.to_input_form());
            } else {
                println!("{}", serde_json::to_string(&expression)?);
            }
            Ok(0)
        }
        Command::Eval { code, input_form } => {
            let expression = evaluate(parse_expression(&code, ParseForm::Input)?)?;
            if input_form {
                println!("{}", expression.to_input_form());
            } else {
                println!("{}", expression.to_full_form());
            }
            Ok(0)
        }
        Command::EvalBatch { stateful } => execute_eval_batch(stateful),
        Command::Expr { command } => execute_expr(command),
        Command::Notebook { command } => execute_notebook(command),
        Command::InlineBox { command } => execute_inline_box(command),
        Command::Env { command } => execute_env(command),
        Command::Kernel { command } => execute_kernel(command),
        Command::ParserCorpus { command } => execute_parser_corpus(command),
        Command::Docs { command } => execute_docs(command),
        Command::Frontend { command } => execute_frontend(command),
        Command::Assistant { command } => execute_assistant(command),
    }
}

fn execute_eval_batch(stateful: bool) -> Result<i32, Box<dyn Error>> {
    let stdin = std::io::stdin();
    let mut evaluator = Evaluator::default();
    for line in stdin.lock().lines() {
        let line = line?;
        let source: String = serde_json::from_str(&line)?;
        if !stateful {
            evaluator = Evaluator::default();
        }
        let payload = match parse_expression(&source, ParseForm::Input)
            .and_then(|expression| evaluator.evaluate(expression))
        {
            Ok(expression) => json!({
                "success": true,
                "full_form": expression.to_full_form(),
                "messages": evaluator.messages().iter().map(Expr::to_full_form).collect::<Vec<_>>(),
                "message_texts": evaluator.message_texts(),
                "prints": evaluator.prints(),
            }),
            Err(error) => json!({
                "success": false,
                "error": error.to_string(),
                "messages": evaluator.messages().iter().map(Expr::to_full_form).collect::<Vec<_>>(),
                "message_texts": evaluator.message_texts(),
                "prints": evaluator.prints(),
            }),
        };
        println!("{}", serde_json::to_string(&payload)?);
    }
    Ok(0)
}

fn execute_assistant(command: AssistantCommand) -> Result<i32, Box<dyn Error>> {
    let controller = NotebookAssistantController::new(WolframKernelRunner::default());
    let (result, require_success) = match command {
        AssistantCommand::Ask {
            prompt,
            system_prompt,
            extra_instructions,
            tools,
            model_service,
            model_name,
            require_success,
        } => (
            controller.ask(&AskOptions {
                prompt,
                system_prompt,
                extra_instructions,
                model_service,
                model_name,
                tools: (!tools.is_empty()).then_some(tools),
            })?,
            require_success,
        ),
        AssistantCommand::AskCell {
            file,
            selector,
            question,
            insert_wolfram_code_below,
            insert_all_wolfram_code_below,
            save,
            close_assistant_notebook,
            extra_instructions,
            model_service,
            model_name,
            require_success,
        } => (
            controller.ask_cell(&AskCellOptions {
                notebook_path: file,
                selector: selector.into_assistant_selector(),
                question,
                insert_wolfram_code: insert_wolfram_code_below,
                insert_all_wolfram_code: insert_all_wolfram_code_below,
                save_notebook: save,
                close_assistant_notebook,
                extra_instructions,
                model_service,
                model_name,
            })?,
            require_success,
        ),
        AssistantCommand::PrepareInline {
            file,
            selector,
            require_success,
        } => (
            controller.prepare_inline(&file, &selector.into_assistant_selector())?,
            require_success,
        ),
        AssistantCommand::CaptureInline {
            file,
            selector,
            insert_wolfram_code_below,
            insert_all_wolfram_code_below,
            save,
            require_success,
        } => (
            controller.capture_inline(
                &file,
                &selector.into_assistant_selector(),
                insert_wolfram_code_below,
                insert_all_wolfram_code_below,
                save,
            )?,
            require_success,
        ),
    };
    let failed = !result.assistant_success();
    print_json(&result.to_value())?;
    Ok(i32::from(require_success && failed))
}

fn execute_repl(no_banner: bool) -> Result<i32, Box<dyn Error>> {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    Ok(run_repl(
        &mut stdin.lock(),
        &mut stdout.lock(),
        &mut stderr.lock(),
        !no_banner,
    )?)
}

fn execute_docs(command: DocsCommand) -> Result<i32, Box<dyn Error>> {
    let index = DocumentationIndex::default();
    match command {
        DocsCommand::Index { path } => {
            let path = index.build_index(path.as_deref())?;
            print_json(&json!({"index_path": path.to_string_lossy()}))?;
        }
        DocsCommand::Search {
            query,
            limit,
            index_path,
            rebuild,
        } => {
            print_json(&json!({"hits": index.search(
                &query,
                index_path.as_deref(),
                limit,
                rebuild,
            )?}))?;
        }
        DocsCommand::Read {
            identifier,
            index_path,
            rebuild,
        } => {
            print_json(&index.read(&identifier, index_path.as_deref(), rebuild)?)?;
        }
        DocsCommand::Open {
            identifier,
            index_path,
        } => {
            let controller = FrontEndController::new(
                WolframKernelRunner::new(index.installation.clone()),
                Some(index),
            );
            print_json(
                &controller
                    .open_documentation(&identifier, index_path.as_deref())?
                    .to_value(),
            )?;
        }
    }
    Ok(0)
}

fn execute_frontend(command: FrontendCommand) -> Result<i32, Box<dyn Error>> {
    let installation = discover_installation();
    let controller = FrontEndController::new(
        WolframKernelRunner::new(installation.clone()),
        Some(DocumentationIndex::new(installation)),
    );
    let (result, require_success) = match command {
        FrontendCommand::Probe { require_success } => (controller.probe()?, require_success),
        FrontendCommand::OpenNotebook {
            file,
            require_success,
        } => (controller.open_notebook(&file)?, require_success),
        FrontendCommand::OpenDoc {
            identifier,
            index_path,
            require_success,
        } => (
            controller.open_documentation(&identifier, index_path.as_deref())?,
            require_success,
        ),
        FrontendCommand::Run {
            code,
            no_wrap,
            require_success,
        } => (controller.run(&code, !no_wrap)?, require_success),
        FrontendCommand::Token {
            token,
            file,
            require_success,
        } => (
            controller.execute_token(&token, file.as_deref())?,
            require_success,
        ),
    };
    let failed = result.success == Some(false);
    print_json(&result.to_value())?;
    Ok(i32::from(require_success && failed))
}

fn execute_parser_corpus(command: ParserCorpusCommand) -> Result<i32, Box<dyn Error>> {
    match command {
        ParserCorpusCommand::Discover { discovery, sample } => {
            let files = discover_corpus_files(&discovery.corpus_root, &discovery.options())?;
            let mut payload = summarize_discovery(&files, &discovery.corpus_root);
            payload["sample_files"] = Value::Array(
                files
                    .iter()
                    .take(sample)
                    .map(|file| file.to_value())
                    .collect(),
            );
            print_json(&payload)?;
            Ok(0)
        }
        ParserCorpusCommand::Compare {
            discovery,
            out_dir,
            max_file_mb,
            max_bytes,
            no_max_bytes,
            form,
            skip_wolfram,
            kernel_batch_size,
            tungsten_workers,
            preview_chars,
            no_write,
            include_results,
            fail_on_tungsten_gap,
            fail_on_mismatch,
        } => {
            let max_bytes = if no_max_bytes {
                None
            } else {
                Some(max_bytes.unwrap_or((max_file_mb * 1024.0 * 1024.0) as usize))
            };
            let options = ParserCorpusOptions {
                discovery: discovery.options(),
                out_dir,
                max_bytes,
                source_form: form.into(),
                compare_wolfram: !skip_wolfram,
                kernel_batch_size,
                tungsten_workers: tungsten_workers.max(1),
                preview_chars,
                write_outputs: !no_write,
            };
            let runner = (!skip_wolfram).then(WolframKernelRunner::default);
            let run =
                compare_parser_corpus(&discovery.corpus_root, &options, runner.as_ref(), None)?;
            let tungsten_gaps = run.summary["outcomes"]["tungsten_gap"]
                .as_u64()
                .unwrap_or(0);
            let tungsten_only = run.summary["outcomes"]["tungsten_only_success"]
                .as_u64()
                .unwrap_or(0);
            print_json(&run.to_value(include_results))?;
            if (fail_on_mismatch && (tungsten_gaps > 0 || tungsten_only > 0))
                || (fail_on_tungsten_gap && tungsten_gaps > 0)
            {
                Ok(1)
            } else {
                Ok(0)
            }
        }
    }
}

fn execute_env(command: EnvCommand) -> Result<i32, Box<dyn Error>> {
    match command {
        EnvCommand::Show { probe } => {
            let installation = discover_installation();
            let mut payload = installation.to_value();
            if probe {
                payload["probe"] = WolframKernelRunner::new(installation).probe()?;
            }
            print_json(&payload)?;
        }
    }
    Ok(0)
}

fn execute_kernel(command: KernelCommand) -> Result<i32, Box<dyn Error>> {
    match command {
        KernelCommand::Eval {
            source,
            working_directory,
            front_end,
            require_success,
        } => {
            let runner = WolframKernelRunner::default();
            let result = match (source.code, source.file) {
                (Some(code), None) => {
                    runner.evaluate_text(&code, working_directory.as_deref(), front_end)?
                }
                (None, Some(path)) => {
                    runner.evaluate_file(&path, working_directory.as_deref(), front_end)?
                }
                _ => unreachable!("clap enforces exactly one expression source"),
            };
            let failed = result.success == Some(false);
            let available = result.evaluation_available;
            print_json(&result.to_value())?;
            if require_success && failed {
                return Ok(1);
            }
            return Ok(if available { 0 } else { 2 });
        }
    }
}

fn execute_expr(command: ExprCommand) -> Result<i32, Box<dyn Error>> {
    let (name, source, form) = match command {
        ExprCommand::Parse { source, form } => ("parse", source.read()?, form),
        ExprCommand::Evaluate { source, form } => ("evaluate", source.read()?, form),
    };
    let parsed = match parse_expression(&source, form.into()) {
        Ok(expression) => expression,
        Err(error) => {
            print_json(&json!({
                "command": name,
                "form": form.label(),
                "source": source,
                "success": false,
                "error_type": "WolframSyntaxError",
                "error": error.to_string(),
            }))?;
            return Ok(1);
        }
    };
    if name == "parse" {
        print_json(&json!({
            "command": "parse",
            "form": form.label(),
            "source": source,
            "input_form": parsed.to_input_form(),
            "full_form": parsed.to_full_form(),
            "depth": parsed.depth(),
            "length": parsed.length(),
            "tree": parsed,
        }))?;
        return Ok(0);
    }
    let mut evaluator = Evaluator::default();
    let result = match evaluator.evaluate(parsed.clone()) {
        Ok(result) => result,
        Err(error) => {
            print_json(&json!({
                "command": "evaluate",
                "form": form.label(),
                "source": source,
                "success": false,
                "error_type": "WolframEvaluationError",
                "error": error.to_string(),
                "parsed_input_form": parsed.to_input_form(),
                "parsed_full_form": parsed.to_full_form(),
                "parsed_tree": parsed,
            }))?;
            return Ok(1);
        }
    };
    let messages = evaluator
        .messages()
        .iter()
        .zip(evaluator.message_texts())
        .map(|(message, text)| message_payload(message, text))
        .collect::<Vec<_>>();
    print_json(&json!({
        "command": "evaluate",
        "form": form.label(),
        "source": source,
        "parsed_input_form": parsed.to_input_form(),
        "parsed_full_form": parsed.to_full_form(),
        "result": expression_payload(&result),
        "messages": messages,
        "prints": evaluator.prints(),
    }))?;
    Ok(0)
}

fn execute_notebook(command: NotebookCommand) -> Result<i32, Box<dyn Error>> {
    match command {
        NotebookCommand::Inspect { file } => {
            print_json(&NotebookDocument::load(file)?.to_value())?;
        }
        NotebookCommand::Create { file, title, cells } => {
            let mut document = NotebookDocument::new(Vec::new());
            if let Some(title) = title {
                document.set_option("WindowTitle", &wl_string(&title));
            }
            for specification in cells {
                let (style, text) = specification.split_once(':').ok_or_else(|| {
                    NotebookError::InvalidOperation(format!(
                        "Invalid cell specification: {specification:?}"
                    ))
                })?;
                document.append_cell(Some(text), Some(style), None, None)?;
            }
            document.save(Some(&file))?;
            print_json(&document.to_value())?;
        }
        NotebookCommand::Patch { file, spec, out } => {
            let mut document = NotebookDocument::load(&file)?;
            apply_patch_spec(&mut document, &load_patch_spec(spec)?)?;
            document.save(Some(out.as_deref().unwrap_or(&file)))?;
            print_json(&document.to_value())?;
        }
    }
    Ok(0)
}

fn execute_inline_box(command: InlineBoxCommand) -> Result<i32, Box<dyn Error>> {
    match command {
        InlineBoxCommand::Compose {
            prefix,
            box_expressions,
            suffix,
        } => {
            print_json(&compose_inline_box_payload(
                &box_expressions,
                &prefix,
                &suffix,
            ))?;
            Ok(0)
        }
        InlineBoxCommand::FromCell {
            file,
            selector,
            prefix,
            suffix,
            object_index,
            all_objects,
            require_success,
        } => {
            let payload = extract_inline_boxes_from_notebook_cell(
                file,
                &selector.into_selector(),
                &InlineBoxExtractionOptions {
                    prefix,
                    suffix,
                    object_index,
                    all_objects,
                },
            )?;
            let failed = payload["success"] == false;
            print_json(&payload)?;
            Ok(i32::from(require_success && failed))
        }
    }
}

impl ExpressionSource {
    fn read(self) -> Result<String, std::io::Error> {
        match (self.code, self.file) {
            (Some(code), None) => Ok(code),
            (None, Some(path)) => fs::read_to_string(path),
            _ => unreachable!("clap enforces exactly one expression source"),
        }
    }
}

fn expression_payload(expression: &Expr) -> Value {
    json!({
        "input_form": expression.to_input_form(),
        "full_form": expression.to_full_form(),
        "depth": expression.depth(),
        "length": expression.length(),
        "tree": expression,
    })
}

fn message_payload(message: &Expr, text: &str) -> Value {
    let input = message.to_input_form();
    let name = if let Expr::Call { head, args } = message
        && head.symbol_name() == Some("MessageName")
        && let [Expr::Symbol(symbol), Expr::String(tag)] = args.as_slice()
    {
        format!("{symbol}::{tag}")
    } else {
        input
    };
    json!({"name": name, "full_name": message.to_full_form(), "text": text})
}

fn parse_cell_path(value: &str) -> Result<Vec<usize>, String> {
    let text = value.trim();
    if text.starts_with('[') && text.ends_with(']') {
        return serde_json::from_str(text)
            .map_err(|error| format!("Invalid JSON cell path {value:?}: {error}"));
    }
    let values = text
        .split(',')
        .filter(|part| !part.trim().is_empty())
        .map(|part| {
            part.trim()
                .parse::<usize>()
                .map_err(|_| format!("Invalid cell path: {value:?}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if values.is_empty() {
        Err("Cell paths must contain at least one integer.".into())
    } else {
        Ok(values)
    }
}

fn print_json(value: &Value) -> Result<(), serde_json::Error> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}
