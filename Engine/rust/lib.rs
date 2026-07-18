//! Native Rust port of the Tungsten Engine.
//!
//! The Python package remains in the repository as the behavioral reference
//! while this crate is brought to full compatibility. New code must not call
//! into Python at runtime: parity is checked by differential tests instead.

pub mod assistant;
pub mod discovery;
pub mod docs_index;
pub mod expression;
pub mod frontend;
pub mod inline_boxes;
pub mod kernel;
pub mod licensing;
pub mod named_characters;
pub mod notebook;
pub mod parser_corpus;
pub mod repl;
pub mod wolfram_processes;
pub mod wolfram_strings;

pub use expression::{
    Evaluator, Expr, ParseForm, WolframError, call, complex, evaluate, integer, list,
    parse_expression, parse_full_form, parse_input_form, parse_standard_form, rational, real,
    string, symbol,
};
