//! Interactive, stateful kernel-free Tungsten interpreter.

use crate::Evaluator;
use crate::expression::{
    Expr, ParseForm, WolframError, call, integer, list, parse_expression, string, symbol,
};
use crate::wolfram_strings::wl_string;
use num_traits::ToPrimitive;
use std::io::{BufRead, Write};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn banner() -> String {
    format!(
        "Tungsten {VERSION} Kernel-free Wolfram Language Interpreter for Microsoft Windows (64-bit)\nCopyright 2026 OpenAI Codex. Structural subset; not a Wolfram kernel.\n"
    )
}

#[derive(Debug)]
pub struct EvaluationSession {
    evaluator: Evaluator,
    line: usize,
    input_strings: Vec<String>,
    inputs: Vec<Expr>,
    outputs: Vec<(usize, Expr)>,
    message_history: Vec<(usize, Vec<Expr>)>,
}

impl Default for EvaluationSession {
    fn default() -> Self {
        let mut evaluator = Evaluator::default();
        evaluator.set_session_hooks_enabled(true);
        Self {
            evaluator,
            line: 0,
            input_strings: Vec::new(),
            inputs: Vec::new(),
            outputs: Vec::new(),
            message_history: Vec::new(),
        }
    }
}

impl EvaluationSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn line(&self) -> usize {
        self.line
    }

    pub fn evaluate_input(&mut self, source: &str) -> Result<SessionOutput, WolframError> {
        self.line += 1;
        let mut prints = Vec::new();
        let mut message_names = Vec::new();
        let mut messages = Vec::new();
        let prepared = self.apply_pre_read(source)?;
        self.collect_effects(&mut prints, &mut message_names, &mut messages);
        self.input_strings.push(prepared.clone());
        let parsed = parse_expression(&prepared, ParseForm::Input)?;
        self.inputs.push(parsed.clone());
        let expanded = replace_session_references(
            parsed,
            self.line,
            &self.input_strings,
            &self.inputs,
            &self.outputs,
            &self.message_history,
        );
        let prepared_expression = self.apply_hook("$Pre", expanded)?;
        self.collect_effects(&mut prints, &mut message_names, &mut messages);
        let result = self.evaluator.evaluate(prepared_expression)?;
        self.collect_effects(&mut prints, &mut message_names, &mut messages);
        if let Some(code) = exit_code(&result) {
            return Ok(SessionOutput::Exit(code));
        }
        let result = self.apply_hook("$Post", result)?;
        self.collect_effects(&mut prints, &mut message_names, &mut messages);
        self.outputs.push((self.line, result.clone()));
        self.message_history.push((self.line, message_names));
        Ok(SessionOutput::Value {
            line: self.line,
            result,
            prints,
            messages,
        })
    }

    pub fn preprint(&mut self, result: Expr) -> Result<Expr, WolframError> {
        self.apply_hook("$PrePrint", result)
    }

    pub fn output_size_limit(&mut self) -> Option<usize> {
        match self.evaluator.evaluate(symbol("$OutputSizeLimit")) {
            Ok(Expr::Integer(value)) => value.to_usize(),
            Ok(Expr::Symbol(name)) if name == "Infinity" => None,
            _ => Some(12_000),
        }
    }

    fn apply_pre_read(&mut self, source: &str) -> Result<String, WolframError> {
        let hook = self.evaluator.evaluate(symbol("$PreRead"))?;
        if hook == symbol("$PreRead") {
            return Ok(source.into());
        }
        match self.evaluator.evaluate(call(hook, [string(source)]))? {
            Expr::String(value) => Ok(value),
            _ => Ok(source.into()),
        }
    }

    fn apply_hook(&mut self, name: &str, expression: Expr) -> Result<Expr, WolframError> {
        let hook = self.evaluator.evaluate(symbol(name))?;
        if hook == symbol(name) {
            Ok(expression)
        } else {
            self.evaluator.evaluate(call(hook, [expression]))
        }
    }

    fn collect_effects(
        &self,
        prints: &mut Vec<String>,
        message_names: &mut Vec<Expr>,
        messages: &mut Vec<String>,
    ) {
        prints.extend(self.evaluator.prints().iter().cloned());
        message_names.extend(self.evaluator.messages().iter().cloned());
        messages.extend(self.evaluator.message_texts().iter().cloned());
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SessionOutput {
    Exit(i32),
    Value {
        line: usize,
        result: Expr,
        prints: Vec<String>,
        messages: Vec<String>,
    },
}

pub fn run_repl<R: BufRead, O: Write, E: Write>(
    input: &mut R,
    output: &mut O,
    error: &mut E,
    show_banner: bool,
) -> std::io::Result<i32> {
    let mut session = EvaluationSession::new();
    if show_banner {
        write!(output, "{}\n", banner())?;
    }
    loop {
        write!(output, "In[{}]:= ", session.line() + 1)?;
        output.flush()?;
        let mut source = String::new();
        if input.read_line(&mut source)? == 0 {
            writeln!(output)?;
            output.flush()?;
            return Ok(0);
        }
        let source = source.trim_end_matches(['\r', '\n']);
        if source.trim().is_empty() {
            writeln!(output)?;
            continue;
        }
        match session.evaluate_input(source) {
            Ok(SessionOutput::Exit(code)) => return Ok(code),
            Ok(SessionOutput::Value {
                line,
                result,
                prints,
                messages,
            }) => {
                for message in messages {
                    writeln!(error, "{message}")?;
                }
                error.flush()?;
                for print in prints {
                    writeln!(output, "{print}")?;
                }
                if result != symbol("Null") {
                    let print_result = session.preprint(result.clone()).unwrap_or(result.clone());
                    let (form, _) = display_parts(&result);
                    let (_, text) = display_parts(&print_result);
                    let text =
                        apply_output_size_limit(&print_result, &text, session.output_size_limit());
                    if let Some(form) = form {
                        write!(output, "\nOut[{line}]//{form}= {text}\n\n")?;
                    } else {
                        write!(output, "\nOut[{line}]= {text}\n\n")?;
                    }
                } else {
                    writeln!(output)?;
                }
                output.flush()?;
            }
            Err(WolframError::Syntax(message)) => {
                writeln!(error, "Syntax::sntxi: {message}\n")?;
                error.flush()?;
            }
            Err(WolframError::Evaluation(message)) => {
                writeln!(error, "Evaluate::error: {message}\n")?;
                error.flush()?;
            }
        }
    }
}

pub fn display_parts(expression: &Expr) -> (Option<&'static str>, String) {
    if let Expr::Call { head, args } = expression
        && let [payload, rest @ ..] = args.as_slice()
        && let Some(name) = head.symbol_name()
    {
        let rendered = match name {
            "InputForm" => Some(("InputForm", payload.to_input_form())),
            "FullForm" => Some(("FullForm", payload.to_full_form())),
            "TeXForm" => Some(("TeXForm", tex_form(payload))),
            "TraditionalForm" => Some((
                "TraditionalForm",
                format!(
                    r#"\!\(\*FormBox[{}, TraditionalForm]\)"#,
                    traditional_boxes(payload).to_input_form()
                ),
            )),
            "CForm" => Some(("CForm", c_form(payload))),
            "FortranForm" => Some(("FortranForm", fortran_form(payload))),
            "NumberForm" => Some(("NumberForm", number_form(payload, rest))),
            _ => None,
        };
        if let Some(rendered) = rendered {
            return (Some(rendered.0), rendered.1);
        }
    }
    if let Expr::String(value) = expression {
        (None, value.clone())
    } else {
        (None, expression.to_input_form())
    }
}

fn traditional_boxes(expression: &Expr) -> Expr {
    match expression {
        Expr::Symbol(_) | Expr::Integer(_) | Expr::Real(_) => string(expression.to_input_form()),
        Expr::String(value) => string(wl_string(value)),
        Expr::Rational(value) => call(
            "FractionBox",
            [
                string(value.numer().to_string()),
                string(value.denom().to_string()),
            ],
        ),
        Expr::Complex { real, imaginary } => traditional_boxes(&call(
            "Complex",
            [real.as_ref().clone(), imaginary.as_ref().clone()],
        )),
        Expr::Call { head, args } => match head.symbol_name() {
            Some("List") => traditional_bracket_boxes("{", args, "}"),
            Some("Association") => traditional_bracket_boxes("<|", args, "|>"),
            Some("Rule") if args.len() == 2 => traditional_infix_boxes(&args[0], "->", &args[1]),
            Some("RuleDelayed") if args.len() == 2 => {
                traditional_infix_boxes(&args[0], ":>", &args[1])
            }
            Some("Plus") if args.len() >= 2 => {
                let mut ordered = args.iter().collect::<Vec<_>>();
                ordered.sort_by_key(|argument| traditional_numeric(argument));
                traditional_separated_boxes(ordered, "+")
            }
            Some("Times") if args.len() >= 2 => traditional_separated_boxes(args, " "),
            Some("Power") if args.len() == 2 => call(
                "SuperscriptBox",
                [traditional_boxes(&args[0]), traditional_boxes(&args[1])],
            ),
            Some("Subscript") if args.len() == 2 => call(
                "SubscriptBox",
                [traditional_boxes(&args[0]), traditional_boxes(&args[1])],
            ),
            _ => row_box([
                traditional_boxes(head),
                string("["),
                traditional_separated_boxes(args, ","),
                string("]"),
            ]),
        },
        _ => string(expression.to_input_form()),
    }
}

fn traditional_numeric(expression: &Expr) -> bool {
    matches!(
        expression,
        Expr::Integer(_)
            | Expr::Real(_)
            | Expr::Rational(_)
            | Expr::Complex { .. }
            | Expr::SpecialReal(_)
    )
}

fn traditional_bracket_boxes(open: &str, arguments: &[Expr], close: &str) -> Expr {
    row_box([
        string(open),
        traditional_separated_boxes(arguments, ","),
        string(close),
    ])
}

fn traditional_infix_boxes(left: &Expr, operator: &str, right: &Expr) -> Expr {
    row_box([
        traditional_boxes(left),
        string(operator),
        traditional_boxes(right),
    ])
}

fn traditional_separated_boxes<'a>(
    expressions: impl IntoIterator<Item = &'a Expr>,
    separator: &str,
) -> Expr {
    let mut pieces = Vec::new();
    for (index, expression) in expressions.into_iter().enumerate() {
        if index > 0 {
            pieces.push(string(separator));
        }
        pieces.push(traditional_boxes(expression));
    }
    row_box(pieces)
}

fn row_box(items: impl IntoIterator<Item = Expr>) -> Expr {
    call("RowBox", [list(items)])
}

fn replace_session_references(
    expression: Expr,
    line: usize,
    input_strings: &[String],
    inputs: &[Expr],
    outputs: &[(usize, Expr)],
    message_history: &[(usize, Vec<Expr>)],
) -> Expr {
    match expression {
        Expr::Symbol(name) if name == "$Line" => integer(line),
        Expr::Call { head, args } if head.symbol_name() == Some("InString") && args.len() == 1 => {
            history_index(&args[0], line)
                .and_then(|index| input_strings.get(index.saturating_sub(1)))
                .map_or_else(|| call(*head, args), |source| string(source))
        }
        Expr::Call { head, args } if head.symbol_name() == Some("In") && args.len() == 1 => {
            history_index(&args[0], line)
                .and_then(|index| inputs.get(index.saturating_sub(1)))
                .cloned()
                .unwrap_or_else(|| call(*head, args))
        }
        Expr::Call { head, args } if head.symbol_name() == Some("Out") && args.len() == 1 => {
            history_index(&args[0], line)
                .and_then(|target| {
                    outputs
                        .iter()
                        .find(|(output_line, _)| *output_line == target)
                        .map(|(_, output)| output.clone())
                })
                .unwrap_or_else(|| call(*head, args))
        }
        Expr::Call { head, args }
            if head.symbol_name() == Some("MessageList") && args.len() == 1 =>
        {
            history_index(&args[0], line)
                .and_then(|target| {
                    message_history
                        .iter()
                        .find(|(message_line, _)| *message_line == target)
                        .map(|(_, messages)| {
                            list(
                                messages
                                    .iter()
                                    .cloned()
                                    .map(|message| call("HoldForm", [message])),
                            )
                        })
                })
                .unwrap_or_else(|| list(std::iter::empty::<Expr>()))
        }
        Expr::Call { head, args } => call(
            replace_session_references(
                *head,
                line,
                input_strings,
                inputs,
                outputs,
                message_history,
            ),
            args.into_iter().map(|argument| {
                replace_session_references(
                    argument,
                    line,
                    input_strings,
                    inputs,
                    outputs,
                    message_history,
                )
            }),
        ),
        other => other,
    }
}

fn history_index(expression: &Expr, line: usize) -> Option<usize> {
    let Expr::Integer(value) = expression else {
        return None;
    };
    let index = value.to_i64()?;
    if index < 0 {
        usize::try_from(line as i64 + index).ok()
    } else {
        usize::try_from(index).ok()
    }
}

fn exit_code(expression: &Expr) -> Option<i32> {
    match expression {
        Expr::Symbol(name) if matches!(name.as_str(), "Quit" | "Exit") => Some(0),
        Expr::Call { head, args } if matches!(head.symbol_name(), Some("Quit" | "Exit")) => {
            match args.as_slice() {
                [] => Some(0),
                [Expr::Integer(code)] => code.to_i32(),
                _ => Some(0),
            }
        }
        _ => None,
    }
}

fn apply_output_size_limit(expression: &Expr, text: &str, limit: Option<usize>) -> String {
    let Some(limit) = limit else {
        return text.into();
    };
    if text.chars().count() <= limit {
        return text.into();
    }
    let payload = if let Expr::Call { head, args } = expression
        && head.symbol_name().is_some_and(|name| {
            matches!(
                name,
                "InputForm" | "FullForm" | "TeXForm" | "TraditionalForm" | "CForm" | "FortranForm"
            )
        })
        && let Some(payload) = args.first()
    {
        payload
    } else {
        expression
    };
    if let Expr::Call { head, args } = payload
        && head.symbol_name() == Some("List")
        && args.len() > 15
    {
        let front = args[..10]
            .iter()
            .map(Expr::to_input_form)
            .collect::<Vec<_>>();
        let back = args[args.len() - 5..]
            .iter()
            .map(Expr::to_input_form)
            .collect::<Vec<_>>();
        let shortened = format!(
            "{{{}, <<{}>>, {}}}",
            front.join(", "),
            args.len() - 15,
            back.join(", ")
        );
        if shortened.len() <= limit {
            return shortened;
        }
    }
    center_truncate(text, limit)
}

fn center_truncate(text: &str, limit: usize) -> String {
    if limit == 0 {
        return format!("<<{}>> chars", text.len());
    }
    let characters = text.chars().collect::<Vec<_>>();
    if characters.len() <= limit {
        return text.into();
    }
    let marker = format!(" <<{} chars>> ", characters.len() - limit);
    if marker.len() >= limit {
        return marker.chars().take(limit).collect();
    }
    let prefix = (limit - marker.len() + 1) / 2;
    let suffix = limit - marker.len() - prefix;
    characters[..prefix]
        .iter()
        .chain(marker.chars().collect::<Vec<_>>().iter())
        .chain(characters[characters.len() - suffix..].iter())
        .collect()
}

fn tex_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression {
        match head.symbol_name() {
            Some("Plus") => {
                let mut terms = args.iter().map(tex_form).collect::<Vec<_>>();
                terms.sort_by_key(|term| term.chars().next().is_some_and(|c| c.is_ascii_digit()));
                return terms.join("+");
            }
            Some("Times") => return args.iter().map(tex_form).collect::<Vec<_>>().join(" "),
            Some("Power") if args.len() == 2 => {
                return format!("{}^{{{}}}", tex_form(&args[0]), tex_form(&args[1]));
            }
            _ => {}
        }
    }
    expression.to_input_form().replace(' ', "")
}

fn c_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression {
        return format!(
            "{}({})",
            head.to_input_form(),
            args.iter().map(c_form).collect::<Vec<_>>().join(",")
        );
    }
    expression.to_input_form()
}

fn fortran_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression
        && head.symbol_name() == Some("Power")
        && args.len() == 2
    {
        return format!("{}**{}", fortran_form(&args[0]), fortran_form(&args[1]));
    }
    expression.to_input_form().replace(' ', "")
}

fn number_form(payload: &Expr, specs: &[Expr]) -> String {
    let digits = specs
        .first()
        .and_then(|value| match value {
            Expr::Integer(value) => value.to_usize(),
            _ => None,
        })
        .unwrap_or(6);
    let value = match payload {
        Expr::Real(value) => value.parse::<f64>().ok(),
        Expr::Integer(value) => value.to_f64(),
        _ => None,
    };
    value.map_or_else(
        || payload.to_input_form(),
        |value| format!("{value:.precision$}", precision = digits.saturating_sub(1)),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn repl_tracks_line_input_and_output_history_and_exits() {
        let mut input = Cursor::new("1+2\n$Line\nInString[1]\n%1 + 10\nQuit\n");
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run_repl(&mut input, &mut output, &mut error, false).unwrap();
        let transcript = String::from_utf8(output).unwrap();
        assert_eq!(code, 0);
        assert!(transcript.contains("Out[1]= 3"));
        assert!(transcript.contains("Out[2]= 2"));
        assert!(transcript.contains("Out[3]= 1+2"));
        assert!(transcript.contains("Out[4]= 13"));
        assert!(error.is_empty());
    }

    #[test]
    fn repl_display_forms_prints_hooks_and_limits() {
        let mut input = Cursor::new(
            "InputForm[1 + x]\nFullForm[1 + x]\nTeXForm[1 + x]\nCForm[x^2]\nNumberForm[1.2345, 3]\nPrint[FortranForm[x^2]]\n$OutputSizeLimit = 80\nRange[100]\n$PrePrint = FullForm\n1+x\nExit[7]\n",
        );
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run_repl(&mut input, &mut output, &mut error, false).unwrap();
        let transcript = String::from_utf8(output).unwrap();
        assert_eq!(code, 7);
        assert!(transcript.contains("Out[1]//InputForm= 1 + x"));
        assert!(transcript.contains("Out[2]//FullForm= Plus[1, x]"));
        assert!(transcript.contains("Out[3]//TeXForm= x+1"));
        assert!(transcript.contains("Out[4]//CForm= Power(x,2)"));
        assert!(transcript.contains("Out[5]//NumberForm= 1.23"));
        assert!(transcript.contains("In[6]:= x**2"));
        assert!(transcript.contains("<<85>>"));
        assert!(transcript.contains("//FullForm= Plus[1, x]"));
    }

    #[test]
    fn repl_pre_read_hook_transforms_and_records_source() {
        let mut input = Cursor::new(
            "$PreRead = Function[s, StringReplace[s, \"aa\" -> \"1+2\"]]\naa\nInString[2]\nQuit\n",
        );
        let mut output = Vec::new();
        let mut error = Vec::new();
        run_repl(&mut input, &mut output, &mut error, false).unwrap();
        let transcript = String::from_utf8(output).unwrap();
        assert!(transcript.contains("Out[2]= 3"));
        assert!(transcript.contains("Out[3]= 1+2"));
    }

    #[test]
    fn session_tracks_input_message_history_and_pre_post_hooks() {
        fn submit(session: &mut EvaluationSession, source: &str) -> Expr {
            match session.evaluate_input(source).unwrap() {
                SessionOutput::Value { result, .. } => result,
                SessionOutput::Exit(code) => panic!("unexpected exit {code}"),
            }
        }

        let mut session = EvaluationSession::new();
        assert_eq!(submit(&mut session, "1 + 2").to_full_form(), "3");
        assert_eq!(submit(&mut session, "In[1]").to_full_form(), "3");
        assert_eq!(
            submit(&mut session, "Part[f[a], 2]").to_full_form(),
            "Part[f[a], 2]"
        );
        assert_eq!(
            submit(&mut session, "MessageList[3]").to_full_form(),
            "List[HoldForm[MessageName[Part, \"error\"]]]"
        );

        submit(&mut session, "$Pre = Function[x, x + 1]");
        assert_eq!(submit(&mut session, "3").to_full_form(), "4");
        submit(&mut session, "$Pre =.");
        submit(&mut session, "$Post = Function[x, x * 2]");
        assert_eq!(submit(&mut session, "3").to_full_form(), "6");

        submit(&mut session, "$Post =.");
        submit(&mut session, "$MessagePrePrint = FullForm");
        let message_output = session.evaluate_input("Message[f::tag, {1 + 2}]").unwrap();
        let SessionOutput::Value { messages, .. } = message_output else {
            panic!("expected a value result");
        };
        assert_eq!(messages, ["f::tag: List[3]"]);
    }
}
