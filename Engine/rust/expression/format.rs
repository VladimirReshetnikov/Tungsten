use num_traits::{One, Signed, Zero};

use super::ast::{Expr, call, integer, system_dispatch_name};
use crate::wolfram_strings::wl_string;

pub(crate) const PREC_ATOM: u16 = 1000;
pub(crate) const PREC_CALL: u16 = 190;
pub(crate) const PREC_PART: u16 = 190;
pub(crate) const PREC_PATTERN: u16 = 185;
pub(crate) const PREC_PATTERN_TEST: u16 = 184;
pub(crate) const PREC_MESSAGE_NAME: u16 = 183;
pub(crate) const PREC_POSTFIX_UNARY: u16 = 175;
pub(crate) const PREC_POWER: u16 = 160;
pub(crate) const PREC_PREFIX: u16 = 150;
pub(crate) const PREC_NONCOMMUTATIVE_TIMES: u16 = 145;
pub(crate) const PREC_TIMES: u16 = 140;
pub(crate) const PREC_PLUS: u16 = 120;
pub(crate) const PREC_COMPARE: u16 = 100;
pub(crate) const PREC_AND: u16 = 80;
pub(crate) const PREC_OR: u16 = 70;
pub(crate) const PREC_ALTERNATIVES: u16 = 65;
pub(crate) const PREC_STRING_EXPRESSION: u16 = 64;
pub(crate) const PREC_NAMED_PATTERN: u16 = 63;
pub(crate) const PREC_CONDITION: u16 = 62;
pub(crate) const PREC_RULE: u16 = 60;
pub(crate) const PREC_TWO_WAY_RULE: u16 = 61;
pub(crate) const PREC_REPLACE: u16 = 50;
pub(crate) const PREC_MAP: u16 = 45;
pub(crate) const PREC_APPLY: u16 = 44;
pub(crate) const PREC_COMPOSITION: u16 = 43;
pub(crate) const PREC_ASSIGNMENT: u16 = 40;
pub(crate) const PREC_PUT: u16 = 35;
pub(crate) const PREC_POSTFIX: u16 = 30;
pub(crate) const PREC_FUNCTION: u16 = 10;

pub(crate) fn format_input(expr: &Expr, parent_precedence: u16) -> String {
    let (text, precedence) = match expr {
        Expr::Symbol(name) => (name.clone(), PREC_ATOM),
        Expr::Integer(value) => (value.to_string(), PREC_ATOM),
        Expr::Real(text) => (text.clone(), PREC_ATOM),
        Expr::Rational(value) => (format!("{}/{}", value.numer(), value.denom()), PREC_TIMES),
        Expr::Complex { real, imaginary } => (format_complex(real, imaginary), PREC_PLUS),
        Expr::String(value) => (wl_string(value), PREC_ATOM),
        Expr::SpecialReal(name) => (format!("{name}[]"), PREC_ATOM),
        Expr::ByteArray(_) | Expr::SparseArray { .. } | Expr::Root { .. } => {
            (expr.to_full_form(), PREC_CALL)
        }
        Expr::Call { head, args } => format_call(head, args),
    };
    if precedence < parent_precedence {
        format!("({text})")
    } else {
        text
    }
}

fn format_call(head: &Expr, args: &[Expr]) -> (String, u16) {
    if let Some(derivative) = format_derivative(head, args) {
        return (derivative, PREC_POSTFIX_UNARY);
    }
    if let Expr::Symbol(name) = head {
        let name = system_dispatch_name(name);
        match name {
            "List" => {
                return (
                    format!(
                        "{{{}}}",
                        args.iter()
                            .map(|argument| format_input(argument, 0))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                    PREC_ATOM,
                );
            }
            "Association" => {
                return (
                    format!(
                        "<|{}|>",
                        args.iter()
                            .map(|argument| format_input(argument, 0))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                    PREC_ATOM,
                );
            }
            "Blank" | "BlankSequence" | "BlankNullSequence" => {
                if let Some(value) = format_blank(name, args) {
                    return (value, PREC_ATOM);
                }
            }
            "Slot" => {
                if let Some(value) = format_slot(args) {
                    return (value, PREC_ATOM);
                }
            }
            "SlotSequence" => {
                if let Some(value) = format_slot_sequence(args) {
                    return (value, PREC_ATOM);
                }
            }
            "Out" => {
                if args.is_empty() {
                    return ("%".into(), PREC_ATOM);
                }
                if let [Expr::Integer(value)] = args {
                    if value.is_negative() {
                        if let Some(count) = (-value).to_usize() {
                            return ("%".repeat(count), PREC_ATOM);
                        }
                    }
                }
            }
            "Pattern" if args.len() == 2 => {
                if let Expr::Symbol(symbol) = &args[0] {
                    return (format_pattern(symbol, &args[1]), PREC_PATTERN);
                }
            }
            "PatternTest" if args.len() == 2 => {
                return (
                    format!(
                        "{}?{}",
                        format_input(&args[0], PREC_PATTERN_TEST),
                        format_input(&args[1], PREC_PATTERN_TEST + 1)
                    ),
                    PREC_PATTERN_TEST,
                );
            }
            "Optional" if args.len() == 1 => {
                return (
                    format!("{}.", format_input(&args[0], PREC_PATTERN)),
                    PREC_PATTERN,
                );
            }
            "Optional" if args.len() == 2 => {
                return (
                    format!(
                        "{}:{}",
                        format_input(&args[0], PREC_NAMED_PATTERN),
                        format_input(&args[1], PREC_NAMED_PATTERN)
                    ),
                    PREC_NAMED_PATTERN,
                );
            }
            "Repeated" if args.len() == 1 => {
                return (
                    format!("{}..", format_input(&args[0], PREC_POSTFIX)),
                    PREC_POSTFIX,
                );
            }
            "RepeatedNull" if args.len() == 1 => {
                return (
                    format!("{}...", format_input(&args[0], PREC_POSTFIX)),
                    PREC_POSTFIX,
                );
            }
            "Condition" if args.len() == 2 => {
                return (
                    format!(
                        "{} /; {}",
                        format_input(&args[0], PREC_CONDITION),
                        format_input(&args[1], PREC_CONDITION + 1)
                    ),
                    PREC_CONDITION,
                );
            }
            "Function" => {
                if args.len() == 1 {
                    return (
                        format!("{} &", format_input(&args[0], PREC_FUNCTION + 1)),
                        PREC_FUNCTION,
                    );
                }
                if args.len() == 2 {
                    return (
                        format!(
                            "{} |-> {}",
                            format_input(&args[0], PREC_FUNCTION + 1),
                            format_input(&args[1], PREC_FUNCTION)
                        ),
                        PREC_FUNCTION,
                    );
                }
            }
            "Information" if args.len() == 2 => {
                if let Expr::String(name) = &args[0]
                    && let Expr::Call { head, args: option } = &args[1]
                    && head
                        .symbol_name()
                        .is_some_and(|name| system_dispatch_name(name) == "Rule")
                    && let [Expr::Symbol(option_name), Expr::Symbol(value)] = option.as_slice()
                    && system_dispatch_name(option_name) == "LongForm"
                {
                    let prefix = if system_dispatch_name(value) == "True" {
                        "??"
                    } else {
                        "?"
                    };
                    return (format!("{prefix}{name}"), PREC_PREFIX);
                }
            }
            "Get" if args.len() == 1 => {
                if let Expr::String(path) = &args[0] {
                    return (format!("<< {path}"), PREC_PREFIX);
                }
            }
            "MessageName" if args.len() >= 2 => {
                let mut output = format_input(&args[0], PREC_MESSAGE_NAME);
                for tag in &args[1..] {
                    match tag {
                        Expr::String(value) | Expr::Symbol(value) => {
                            output.push_str("::");
                            output.push_str(value);
                        }
                        _ => return generic_call(head, args),
                    }
                }
                return (output, PREC_MESSAGE_NAME);
            }
            "Put" | "PutAppend" if args.len() == 2 => {
                if let Expr::String(path) = &args[1] {
                    let operator = if name == "Put" { ">>" } else { ">>>" };
                    return (
                        format!("{} {operator} {path}", format_input(&args[0], PREC_PUT)),
                        PREC_PUT,
                    );
                }
            }
            "TagSet" | "TagSetDelayed" if args.len() == 3 => {
                let operator = if name == "TagSet" { "=" } else { ":=" };
                return (
                    format!(
                        "{} /: {} {operator} {}",
                        format_input(&args[0], PREC_ASSIGNMENT + 1),
                        format_input(&args[1], PREC_ASSIGNMENT + 1),
                        format_input(&args[2], PREC_ASSIGNMENT)
                    ),
                    PREC_ASSIGNMENT,
                );
            }
            "TagUnset" if args.len() == 2 => {
                return (
                    format!(
                        "{} /: {} =.",
                        format_input(&args[0], PREC_ASSIGNMENT + 1),
                        format_input(&args[1], PREC_ASSIGNMENT + 1)
                    ),
                    PREC_ASSIGNMENT,
                );
            }
            "Increment" | "Decrement" | "Factorial" | "Factorial2" | "Unset" if args.len() == 1 => {
                let operator = match name {
                    "Increment" => "++",
                    "Decrement" => "--",
                    "Factorial" => "!",
                    "Factorial2" => "!!",
                    _ => " =.",
                };
                return (
                    format!("{}{operator}", format_input(&args[0], PREC_POSTFIX_UNARY)),
                    PREC_POSTFIX_UNARY,
                );
            }
            "PreIncrement" | "PreDecrement" if args.len() == 1 => {
                let operator = if name == "PreIncrement" { "++" } else { "--" };
                return (
                    format!("{operator}{}", format_input(&args[0], PREC_POSTFIX_UNARY)),
                    PREC_POSTFIX_UNARY,
                );
            }
            "Plus" if !args.is_empty() => return (format_plus(args), PREC_PLUS),
            "Times" if !args.is_empty() => return (format_times(args), PREC_TIMES),
            "Power" if args.len() == 2 => {
                return (
                    format!(
                        "{}^{}",
                        format_input(&args[0], PREC_POWER + 1),
                        if matches!(&args[1], Expr::Integer(value) if value.is_negative()) {
                            format!("({})", format_input(&args[1], 0))
                        } else {
                            format_input(&args[1], PREC_POWER)
                        }
                    ),
                    PREC_POWER,
                );
            }
            "Not" if args.len() == 1 => {
                return (
                    format!("!{}", format_input(&args[0], PREC_PREFIX)),
                    PREC_PREFIX,
                );
            }
            "Span" => return (format_span(args), PREC_FUNCTION),
            "Part" if !args.is_empty() => {
                return (
                    format!(
                        "{}[[{}]]",
                        format_input(&args[0], PREC_PART),
                        args[1..]
                            .iter()
                            .map(|argument| format_input(argument, 0))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                    PREC_PART,
                );
            }
            _ => {}
        }
        if let Some((operator, precedence, right_associative, spaced)) = infix_spec(name)
            && args.len() >= 2
        {
            return (
                format_infix(args, operator, precedence, right_associative, spaced),
                precedence,
            );
        }
        if let Some((operator, precedence)) = escaped_infix_spec(name)
            && args.len() >= 2
        {
            let pieces = args
                .iter()
                .map(|argument| {
                    let text = format_input(argument, 0);
                    let argument_precedence = input_precedence(argument);
                    if argument_precedence < precedence
                        || (argument_precedence == precedence
                            && matches!(argument, Expr::Call { .. }))
                    {
                        format!("({text})")
                    } else {
                        text
                    }
                })
                .collect::<Vec<_>>();
            return (pieces.join(&format!(" {operator} ")), precedence);
        }
    }
    generic_call(head, args)
}

fn generic_call(head: &Expr, args: &[Expr]) -> (String, u16) {
    let formatted_head = if let Expr::Call {
        head: derivative_head,
        args: derivative_args,
    } = head
        && format_derivative(derivative_head, derivative_args).is_some()
    {
        format_input(head, 0)
    } else {
        format_input(head, PREC_CALL)
    };
    (
        format!(
            "{}[{}]",
            formatted_head,
            args.iter()
                .map(|argument| format_input(argument, 0))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        PREC_CALL,
    )
}

fn infix_spec(name: &str) -> Option<(&'static str, u16, bool, bool)> {
    Some(match name {
        "Equal" => ("==", PREC_COMPARE, true, true),
        "Unequal" => ("!=", PREC_COMPARE, true, true),
        "SameQ" => ("===", PREC_COMPARE, true, true),
        "UnsameQ" => ("=!=", PREC_COMPARE, true, true),
        "Less" => ("<", PREC_COMPARE, true, true),
        "LessEqual" => ("<=", PREC_COMPARE, true, true),
        "Greater" => (">", PREC_COMPARE, true, true),
        "GreaterEqual" => (">=", PREC_COMPARE, true, true),
        "And" => ("&&", PREC_AND, false, true),
        "Or" => ("||", PREC_OR, false, true),
        "Alternatives" => ("|", PREC_ALTERNATIVES, false, true),
        "StringExpression" => ("~~", PREC_STRING_EXPRESSION, false, false),
        "TwoWayRule" => ("<->", PREC_TWO_WAY_RULE, true, true),
        "Rule" => ("->", PREC_RULE, true, true),
        "RuleDelayed" => (":>", PREC_RULE, true, true),
        "ReplaceAll" => ("/.", PREC_REPLACE, false, true),
        "ReplaceRepeated" => ("//.", PREC_REPLACE, false, true),
        "Map" => ("/@", PREC_MAP, false, true),
        "MapAll" => ("//@", PREC_MAP, false, true),
        "Apply" => ("@@", PREC_APPLY, false, true),
        "MapApply" => ("@@@", PREC_APPLY, false, true),
        "Composition" => ("@*", PREC_COMPOSITION, true, true),
        "RightComposition" => ("/*", PREC_COMPOSITION, true, true),
        "Set" => ("=", PREC_ASSIGNMENT, true, true),
        "SetDelayed" => (":=", PREC_ASSIGNMENT, true, true),
        "UpSet" => ("^=", PREC_ASSIGNMENT, true, true),
        "UpSetDelayed" => ("^:=", PREC_ASSIGNMENT, true, true),
        "AddTo" => ("+=", PREC_ASSIGNMENT, true, true),
        "SubtractFrom" => ("-=", PREC_ASSIGNMENT, true, true),
        "TimesBy" => ("*=", PREC_ASSIGNMENT, true, true),
        "DivideBy" => ("/=", PREC_ASSIGNMENT, true, true),
        "NonCommutativeMultiply" => ("**", PREC_NONCOMMUTATIVE_TIMES, false, true),
        "Dot" => (".", PREC_TIMES, false, true),
        "StringJoin" => ("<>", PREC_PLUS, false, true),
        _ => return None,
    })
}

fn escaped_infix_spec(name: &str) -> Option<(String, u16)> {
    const NAMES: &[&str] = &[
        "CenterDot",
        "CircleDot",
        "CircleMinus",
        "CirclePlus",
        "CircleTimes",
        "Congruent",
        "Cross",
        "Diamond",
        "DirectedEdge",
        "DiscreteRatio",
        "DiscreteShift",
        "DoubleLeftArrow",
        "DoubleLeftRightArrow",
        "DoubleRightArrow",
        "DoubleVerticalBar",
        "DownArrow",
        "Element",
        "Equivalent",
        "Implies",
        "Intersection",
        "LessEqualGreater",
        "LongLeftArrow",
        "LongLeftRightArrow",
        "LongRightArrow",
        "MinusPlus",
        "NotElement",
        "NotSubset",
        "NotSubsetEqual",
        "NotSuperset",
        "NotSupersetEqual",
        "PlusMinus",
        "Precedes",
        "PrecedesEqual",
        "Proportion",
        "RightArrow",
        "SmallCircle",
        "SquareIntersection",
        "SquareSubset",
        "SquareSubsetEqual",
        "SquareSuperset",
        "SquareSupersetEqual",
        "SquareUnion",
        "Star",
        "Subset",
        "SubsetEqual",
        "Succeeds",
        "SucceedsEqual",
        "Superset",
        "SupersetEqual",
        "TensorProduct",
        "Tilde",
        "TildeEqual",
        "TildeFullEqual",
        "TildeTilde",
        "UndirectedEdge",
        "Union",
        "UpArrow",
        "Vee",
        "VerticalBar",
        "VerticalSeparator",
        "Wedge",
    ];
    if !NAMES.contains(&name) {
        return None;
    }
    let precedence = match name {
        "CirclePlus" => 125,
        "CircleTimes" => 142,
        "Diamond" => 144,
        _ => PREC_COMPARE,
    };
    Some((format!(r"\[{name}]"), precedence))
}

fn input_precedence(expr: &Expr) -> u16 {
    match expr {
        Expr::Call { head, args } => format_call(head, args).1,
        Expr::Rational(_) => PREC_TIMES,
        Expr::Complex { .. } => PREC_PLUS,
        _ => PREC_ATOM,
    }
}

fn format_infix(
    args: &[Expr],
    operator: &str,
    precedence: u16,
    right_associative: bool,
    spaced: bool,
) -> String {
    let separator = if spaced {
        format!(" {operator} ")
    } else {
        operator.to_owned()
    };
    let last = args.len() - 1;
    args.iter()
        .enumerate()
        .map(|(index, argument)| {
            let mut operand_precedence = if right_associative {
                if index == 0 {
                    precedence + 1
                } else {
                    precedence
                }
            } else if index == 0 {
                precedence
            } else {
                precedence + 1
            };
            if index > 0 && index < last {
                operand_precedence = precedence + 1;
            }
            format_input(argument, operand_precedence)
        })
        .collect::<Vec<_>>()
        .join(&separator)
}

fn format_blank(name: &str, args: &[Expr]) -> Option<String> {
    let prefix = match name {
        "Blank" => "_",
        "BlankSequence" => "__",
        "BlankNullSequence" => "___",
        _ => return None,
    };
    match args {
        [] => Some(prefix.into()),
        [Expr::Symbol(name)] => Some(format!("{prefix}{name}")),
        _ => None,
    }
}

fn format_pattern(name: &str, pattern: &Expr) -> String {
    if let Expr::Call { head, args } = pattern
        && let Expr::Symbol(head_name) = head.as_ref()
        && let Some(blank) = format_blank(system_dispatch_name(head_name), args)
    {
        return format!("{name}{blank}");
    }
    format!("{name} : {}", format_input(pattern, PREC_NAMED_PATTERN))
}

fn format_slot(args: &[Expr]) -> Option<String> {
    match args {
        [] => Some("#".into()),
        [Expr::Integer(value)] if value.is_one() => Some("#".into()),
        [Expr::Integer(value)] => Some(format!("#{value}")),
        [Expr::String(value)] => Some(format!("#{value}")),
        _ => None,
    }
}

fn format_slot_sequence(args: &[Expr]) -> Option<String> {
    match args {
        [] => Some("##".into()),
        [Expr::Integer(value)] if value.is_one() => Some("##".into()),
        [Expr::Integer(value)] => Some(format!("##{value}")),
        _ => None,
    }
}

fn format_derivative(head: &Expr, args: &[Expr]) -> Option<String> {
    if args.len() != 1 {
        return None;
    }
    let Expr::Call {
        head: derivative,
        args: orders,
    } = head
    else {
        return None;
    };
    if !derivative.has_head("Derivative") && derivative.symbol_name() != Some("Derivative") {
        return None;
    }
    let [Expr::Integer(order)] = orders.as_slice() else {
        return None;
    };
    let count = order.to_usize()?;
    if count == 0 {
        return None;
    }
    Some(format!(
        "{}{}",
        format_input(&args[0], PREC_POSTFIX_UNARY),
        "'".repeat(count)
    ))
}

fn format_plus(args: &[Expr]) -> String {
    let mut pieces = Vec::new();
    for (index, argument) in args.iter().enumerate() {
        if let Some(stripped) = strip_negative_term(argument) {
            let formatted = format_input(
                &stripped,
                if index == 0 {
                    PREC_PREFIX
                } else {
                    PREC_PLUS + 1
                },
            );
            pieces.push(if index == 0 {
                format!("-{formatted}")
            } else {
                format!("- {formatted}")
            });
        } else if index == 0 {
            pieces.push(format_input(argument, PREC_PLUS));
        } else {
            pieces.push(format!("+ {}", format_input(argument, PREC_PLUS + 1)));
        }
    }
    pieces.join(" ")
}

fn strip_negative_term(expr: &Expr) -> Option<Expr> {
    let Expr::Call { head, args } = expr else {
        return None;
    };
    if head.symbol_name().map(system_dispatch_name) != Some("Times")
        || !matches!(args.first(), Some(Expr::Integer(value)) if value == &(-1).into())
    {
        return None;
    }
    match &args[1..] {
        [single] => Some(single.clone()),
        rest => Some(call("Times", rest.iter().cloned())),
    }
}

fn format_times(args: &[Expr]) -> String {
    if let [numerator, denominator] = args
        && let Some(denominator) = inverse_denominator(denominator)
    {
        return format!(
            "{} / {}",
            format_input(numerator, PREC_TIMES),
            format_input(denominator, PREC_TIMES + 1)
        );
    }
    if matches!(args.first(), Some(Expr::Integer(value)) if value == &(-1).into()) {
        let stripped = match &args[1..] {
            [single] => single.clone(),
            rest => call("Times", rest.iter().cloned()),
        };
        return format!("-{}", format_input(&stripped, PREC_PREFIX));
    }
    args.iter()
        .enumerate()
        .map(|(index, argument)| format_input(argument, PREC_TIMES + u16::from(index > 0)))
        .collect::<Vec<_>>()
        .join(" * ")
}

fn inverse_denominator(expr: &Expr) -> Option<&Expr> {
    let Expr::Call { head, args } = expr else {
        return None;
    };
    if head.symbol_name().map(system_dispatch_name) == Some("Power")
        && matches!(args.as_slice(), [_, Expr::Integer(value)] if value == &(-1).into())
    {
        return args.first();
    }
    None
}

fn format_span(args: &[Expr]) -> String {
    match args {
        [Expr::Integer(start), Expr::Symbol(end)] if start.is_one() && end == "All" => ";;".into(),
        [Expr::Integer(start), end] if start.is_one() => format!(";; {}", format_input(end, 0)),
        [start, Expr::Symbol(end)] if end == "All" => format!("{} ;;", format_input(start, 0)),
        [start, end] => format!("{} ;; {}", format_input(start, 0), format_input(end, 0)),
        [start, end, step] => format!(
            "{} ;; {} ;; {}",
            format_input(start, 0),
            format_input(end, 0),
            format_input(step, 0)
        ),
        _ => format!(
            "Span[{}]",
            args.iter()
                .map(|arg| format_input(arg, 0))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn format_complex(real: &Expr, imaginary: &Expr) -> String {
    if is_exact_zero(real) {
        return format_imaginary(imaginary);
    }
    if is_negative_number(imaginary) {
        return format!(
            "{} - {}",
            format_input(real, PREC_PLUS),
            format_imaginary(&negate_number(imaginary))
        );
    }
    format!(
        "{} + {}",
        format_input(real, PREC_PLUS),
        format_imaginary(imaginary)
    )
}

fn format_imaginary(value: &Expr) -> String {
    match value {
        Expr::Integer(number) if number.is_one() => "I".into(),
        Expr::Integer(number) if number == &(-1).into() => "-I".into(),
        _ => format!("{} I", format_input(value, PREC_TIMES)),
    }
}

fn is_exact_zero(expr: &Expr) -> bool {
    matches!(expr, Expr::Integer(value) if value.is_zero())
        || matches!(expr, Expr::Rational(value) if value.is_zero())
}

fn is_negative_number(expr: &Expr) -> bool {
    matches!(expr, Expr::Integer(value) if value.is_negative())
        || matches!(expr, Expr::Rational(value) if value.is_negative())
        || matches!(expr, Expr::Real(text) if text.starts_with('-'))
}

fn negate_number(expr: &Expr) -> Expr {
    match expr {
        Expr::Integer(value) => Expr::Integer(-value),
        Expr::Rational(value) => Expr::Rational(-value),
        Expr::Real(text) if text.starts_with('-') => Expr::Real(text[1..].into()),
        Expr::Real(text) => Expr::Real(format!("-{text}")),
        _ => call("Times", [integer(-1), expr.clone()]),
    }
}

trait ToUsize {
    fn to_usize(&self) -> Option<usize>;
}

impl ToUsize for num_bigint::BigInt {
    fn to_usize(&self) -> Option<usize> {
        num_traits::ToPrimitive::to_usize(self)
    }
}
