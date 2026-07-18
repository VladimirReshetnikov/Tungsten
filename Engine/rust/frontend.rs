//! FrontEnd operations expressed through structured Wolfram kernel evaluation.

use crate::docs_index::{DocumentationError, DocumentationIndex};
use crate::kernel::{KernelError, KernelEvaluationResult, WolframKernelRunner};
use crate::wolfram_strings::wl_string;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FrontEndError {
    #[error(transparent)]
    Kernel(#[from] KernelError),
    #[error(transparent)]
    Documentation(#[from] DocumentationError),
}

#[derive(Clone, Debug)]
pub struct FrontEndController {
    pub runner: WolframKernelRunner,
    pub docs_index: DocumentationIndex,
}

impl FrontEndController {
    pub fn new(runner: WolframKernelRunner, docs_index: Option<DocumentationIndex>) -> Self {
        let docs_index =
            docs_index.unwrap_or_else(|| DocumentationIndex::new(runner.installation.clone()));
        Self { runner, docs_index }
    }

    pub fn probe(&self) -> Result<KernelEvaluationResult, FrontEndError> {
        Ok(self.runner.evaluate_text(
            r#"nb = UsingFrontEnd[CreateDocument[Notebook[{Cell["Tungsten probe", "Text"]}, Visible -> False]]]; head = Head[nb]; UsingFrontEnd[NotebookClose[nb]]; head"#,
            None,
            false,
        )?)
    }

    pub fn run(
        &self,
        code: &str,
        wrap_using_front_end: bool,
    ) -> Result<KernelEvaluationResult, FrontEndError> {
        Ok(self
            .runner
            .evaluate_text(code, None, wrap_using_front_end)?)
    }

    pub fn open_notebook(&self, path: &Path) -> Result<KernelEvaluationResult, FrontEndError> {
        Ok(self
            .runner
            .evaluate_text(&open_notebook_code(path), None, true)?)
    }

    pub fn open_documentation(
        &self,
        identifier: &str,
        index_path: Option<&Path>,
    ) -> Result<KernelEvaluationResult, FrontEndError> {
        let paclet = self.docs_index.resolve_identifier(identifier, index_path)?;
        Ok(self.runner.evaluate_text(
            &format!("NotebookLocate[{}]", wl_string(&paclet)),
            None,
            true,
        )?)
    }

    pub fn execute_token(
        &self,
        token: &str,
        notebook_path: Option<&Path>,
    ) -> Result<KernelEvaluationResult, FrontEndError> {
        Ok(self
            .runner
            .evaluate_text(&execute_token_code(token, notebook_path), None, true)?)
    }
}

pub fn open_notebook_code(path: &Path) -> String {
    format!("NotebookOpen[{}]", wl_string(&resolved_posix(path)))
}

pub fn execute_token_code(token: &str, notebook_path: Option<&Path>) -> String {
    notebook_path.map_or_else(
        || format!("FrontEndTokenExecute[{}]", wl_string(token)),
        |path| {
            format!(
                "nb = NotebookOpen[{}]; FrontEndTokenExecute[nb, {}]; nb",
                wl_string(&resolved_posix(path)),
                wl_string(token)
            )
        },
    )
}

fn resolved_posix(path: &Path) -> String {
    let mut resolved = path
        .canonicalize()
        .unwrap_or_else(|_| absolute_path(path))
        .to_string_lossy()
        .into_owned();
    if let Some(stripped) = resolved.strip_prefix(r"\\?\") {
        resolved = stripped.into();
    }
    resolved.replace('\\', "/")
}

fn absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn front_end_code_escapes_paths_and_tokens() {
        let path = Path::new("notebooks/example.nb");
        assert!(open_notebook_code(path).starts_with("NotebookOpen[\""));
        assert_eq!(
            execute_token_code("EvaluateCells", None),
            r#"FrontEndTokenExecute["EvaluateCells"]"#
        );
        let code = execute_token_code("Select\"All", Some(path));
        assert!(code.contains(r#"FrontEndTokenExecute[nb, "Select\"All"]"#));
        assert!(code.ends_with("; nb"));
    }
}
