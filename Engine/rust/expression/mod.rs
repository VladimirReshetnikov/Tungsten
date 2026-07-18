mod ast;
mod evaluator;
mod format;
mod parser;

pub use ast::{Expr, call, complex, integer, list, rational, real, string, symbol};
pub use evaluator::{Evaluator, evaluate};
pub use parser::{
    ParseForm, parse_expression, parse_full_form, parse_input_form, parse_standard_form,
};

/// Errors raised while parsing or structurally evaluating Wolfram expressions.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum WolframError {
    #[error("{0}")]
    Syntax(String),
    #[error("{0}")]
    Evaluation(String),
}

pub(crate) type Result<T> = std::result::Result<T, WolframError>;
