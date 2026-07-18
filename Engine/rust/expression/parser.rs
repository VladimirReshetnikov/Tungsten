use std::collections::HashSet;

use num_bigint::BigInt;
use num_traits::Signed;

use super::ast::{Expr, call, integer, list, real, string, symbol};
use super::{Result, WolframError};
use crate::named_characters::named_character;
use crate::wolfram_strings::parse_wl_string_literal;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ParseForm {
    #[default]
    Input,
    Full,
    Standard,
}

pub fn parse_expression(text: &str, form: ParseForm) -> Result<Expr> {
    let expression = Parser::new(text)?.parse()?;
    if form == ParseForm::Standard {
        interpret_standard_form(expression)
    } else {
        Ok(expression)
    }
}

pub fn parse_input_form(text: &str) -> Result<Expr> {
    parse_expression(text, ParseForm::Input)
}

pub fn parse_full_form(text: &str) -> Result<Expr> {
    parse_expression(text, ParseForm::Full)
}

pub fn parse_standard_form(text: &str) -> Result<Expr> {
    parse_expression(text, ParseForm::Standard)
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TokenKind {
    Integer,
    Real,
    String,
    Symbol,
    Percent,
    Filename,
    Operator,
    Eof,
}

#[derive(Clone, Debug)]
struct Token {
    kind: TokenKind,
    text: String,
    start: usize,
    end: usize,
    value: Option<String>,
}

impl Token {
    fn operator(text: &str, start: usize, end: usize) -> Self {
        Self {
            kind: TokenKind::Operator,
            text: text.into(),
            start,
            end,
            value: Some(text.into()),
        }
    }
}

fn syntax(message: impl Into<String>) -> WolframError {
    WolframError::Syntax(message.into())
}

fn tokenize(text: &str) -> Result<Vec<Token>> {
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < text.len() {
        let character = text[index..]
            .chars()
            .next()
            .expect("valid character boundary");
        if character.is_whitespace() {
            index += character.len_utf8();
            continue;
        }
        if character == '\\' {
            if let Some(end) = line_continuation_end(text, index) {
                index = end;
                continue;
            }
        }
        if text[index..].starts_with("(*") {
            index = skip_comment(text, index)?;
            continue;
        }
        if character == '"' {
            let (token, end) = scan_string(text, index)?;
            tokens.push(token);
            index = end;
            continue;
        }
        if let Some((token, end)) = scan_named_character_token(text, index) {
            tokens.push(token);
            index = end;
            continue;
        }
        if let Some((token, end)) = scan_symbol(text, index)? {
            tokens.push(token);
            index = end;
            continue;
        }
        if let Some((token, end)) = scan_escaped_token(text, index)? {
            if !token.text.trim().is_empty() {
                tokens.push(token);
            }
            index = end;
            continue;
        }
        if character.is_ascii_digit()
            || (character == '.'
                && text[index + 1..]
                    .chars()
                    .next()
                    .is_some_and(|next| next.is_ascii_digit()))
        {
            let (token, end) = scan_number(text, index)?;
            tokens.push(token);
            index = end;
            continue;
        }
        if character == '%' {
            let (token, end) = scan_percent(text, index);
            tokens.push(token);
            index = end;
            continue;
        }
        if let Some(operator) = MULTI_TOKENS
            .iter()
            .find(|candidate| text[index..].starts_with(**candidate))
        {
            let end = index + operator.len();
            tokens.push(Token::operator(operator, index, end));
            index = end;
            if matches!(*operator, "<<" | ">>" | ">>>")
                && let Some((filename, end)) = scan_filename(text, index)
            {
                tokens.push(filename);
                index = end;
            }
            continue;
        }
        if "[]{}(),.;:+-*/^!@<>_|&#=?~'".contains(character) {
            let end = index + character.len_utf8();
            tokens.push(Token::operator(&character.to_string(), index, end));
            index = end;
            continue;
        }
        return Err(syntax(format!(
            "Unexpected Wolfram syntax character {character:?} at offset {index}."
        )));
    }
    tokens.push(Token {
        kind: TokenKind::Eof,
        text: String::new(),
        start: text.len(),
        end: text.len(),
        value: None,
    });
    Ok(tokens)
}

fn scan_string(text: &str, start: usize) -> Result<(Token, usize)> {
    let mut index = start + 1;
    while index < text.len() {
        let character = text[index..].chars().next().expect("character boundary");
        if character == '\\' {
            index += 1;
            if index < text.len() {
                let escaped = text[index..].chars().next().expect("character boundary");
                index += escaped.len_utf8();
            }
            continue;
        }
        index += character.len_utf8();
        if character == '"' {
            let raw = &text[start..index];
            let value = parse_wl_string_literal(raw).map_err(syntax)?;
            return Ok((
                Token {
                    kind: TokenKind::String,
                    text: raw.into(),
                    start,
                    end: index,
                    value: Some(value),
                },
                index,
            ));
        }
    }
    Err(syntax("Unterminated Wolfram string literal."))
}

fn scan_number(text: &str, start: usize) -> Result<(Token, usize)> {
    let bytes = text.as_bytes();
    let mut index = start;
    while bytes.get(index).is_some_and(u8::is_ascii_digit) {
        index += 1;
    }
    if index > start && text[index..].starts_with("^^") {
        return scan_based_number(text, start, index);
    }
    let (mut index, saw_dot, saw_digits) = scan_decimal_mantissa(text, start, true)?;
    let (next, saw_precision) = scan_precision_marker(text, index)?;
    index = next;
    let (next, saw_magnitude) = scan_magnitude(text, index)?;
    index = next;
    let raw = &text[start..index];
    if raw.is_empty() || raw == "." || !saw_digits {
        return Err(syntax(format!("Malformed Wolfram number near {raw:?}.")));
    }
    let kind = if saw_dot || saw_precision || saw_magnitude {
        TokenKind::Real
    } else {
        TokenKind::Integer
    };
    Ok((
        Token {
            kind,
            text: raw.into(),
            start,
            end: index,
            value: Some(raw.into()),
        },
        index,
    ))
}

fn scan_based_number(text: &str, start: usize, base_end: usize) -> Result<(Token, usize)> {
    let base: u32 = text[start..base_end]
        .parse()
        .map_err(|_| syntax("Malformed Wolfram base-number literal."))?;
    if !(2..=36).contains(&base) {
        return Err(syntax(
            "Wolfram base-number literals require a base between 2 and 36.",
        ));
    }
    let mantissa_start = base_end + 2;
    let (mut index, saw_dot, saw_digits) = scan_base_mantissa(text, mantissa_start, base)?;
    if !saw_digits || text[index..].starts_with("..") {
        return Err(syntax("Malformed Wolfram base-number literal."));
    }
    let (next, saw_precision) = scan_precision_marker(text, index)?;
    index = next;
    let (next, saw_magnitude) = scan_magnitude(text, index)?;
    index = next;
    let raw = &text[start..index];
    if !saw_dot && !saw_precision && !saw_magnitude {
        let digits = &text[mantissa_start..index];
        let value = BigInt::parse_bytes(digits.as_bytes(), base)
            .ok_or_else(|| syntax("Malformed Wolfram base-number literal."))?;
        return Ok((
            Token {
                kind: TokenKind::Integer,
                text: raw.into(),
                start,
                end: index,
                value: Some(value.to_string()),
            },
            index,
        ));
    }
    Ok((
        Token {
            kind: TokenKind::Real,
            text: raw.into(),
            start,
            end: index,
            value: Some(raw.into()),
        },
        index,
    ))
}

fn scan_decimal_mantissa(
    text: &str,
    start: usize,
    allow_leading_dot: bool,
) -> Result<(usize, bool, bool)> {
    let bytes = text.as_bytes();
    let mut index = start;
    let mut saw_digits = false;
    while bytes.get(index).is_some_and(u8::is_ascii_digit) {
        saw_digits = true;
        index += 1;
    }
    let mut saw_dot = false;
    if bytes.get(index) == Some(&b'.') && !text[index..].starts_with("..") {
        if bytes.get(index + 1).is_some_and(u8::is_ascii_digit) {
            saw_dot = true;
            index += 1;
            while bytes.get(index).is_some_and(u8::is_ascii_digit) {
                saw_digits = true;
                index += 1;
            }
        } else if saw_digits {
            saw_dot = true;
            index += 1;
        } else if allow_leading_dot {
            return Err(syntax("Malformed Wolfram number."));
        }
    }
    Ok((index, saw_dot, saw_digits))
}

fn scan_precision_marker(text: &str, mut index: usize) -> Result<(usize, bool)> {
    if text[index..].starts_with("``") {
        index += 2;
        let (end, _, saw_digits) = scan_decimal_mantissa(text, index, true)?;
        if !saw_digits {
            return Err(syntax("Malformed Wolfram accuracy mark."));
        }
        return Ok((end, true));
    }
    if text.as_bytes().get(index) == Some(&b'`') {
        index += 1;
        let (end, _, _) = scan_decimal_mantissa(text, index, true)?;
        return Ok((end, true));
    }
    Ok((index, false))
}

fn scan_magnitude(text: &str, mut index: usize) -> Result<(usize, bool)> {
    if !text[index..].starts_with("*^") {
        return Ok((index, false));
    }
    index += 2;
    if matches!(text.as_bytes().get(index), Some(b'+' | b'-')) {
        index += 1;
    }
    let exponent_start = index;
    while text.as_bytes().get(index).is_some_and(u8::is_ascii_digit) {
        index += 1;
    }
    if exponent_start == index
        || (text.as_bytes().get(index) == Some(&b'.') && !text[index..].starts_with(".."))
    {
        return Err(syntax("Malformed Wolfram numeric exponent."));
    }
    Ok((index, true))
}

fn scan_base_mantissa(text: &str, start: usize, base: u32) -> Result<(usize, bool, bool)> {
    let mut index = start;
    let mut saw_dot = false;
    let mut saw_digits = false;
    if text.as_bytes().get(index) == Some(&b'.') {
        let Some(value) = text
            .as_bytes()
            .get(index + 1)
            .and_then(|byte| base_digit(*byte))
        else {
            return Err(syntax("Malformed Wolfram base-number literal."));
        };
        if value >= base {
            return Err(syntax(format!("Malformed Wolfram base-{base} literal.")));
        }
        saw_dot = true;
        index += 1;
    }
    while let Some(byte) = text.as_bytes().get(index).copied() {
        if let Some(value) = base_digit(byte) {
            if value >= base {
                return Err(syntax(format!("Malformed Wolfram base-{base} literal.")));
            }
            saw_digits = true;
            index += 1;
        } else if byte == b'.' && !saw_dot && !text[index..].starts_with("..") {
            saw_dot = true;
            index += 1;
        } else {
            break;
        }
    }
    Ok((index, saw_dot, saw_digits))
}

fn base_digit(byte: u8) -> Option<u32> {
    match byte {
        b'0'..=b'9' => Some(u32::from(byte - b'0')),
        b'a'..=b'z' => Some(u32::from(byte - b'a') + 10),
        b'A'..=b'Z' => Some(u32::from(byte - b'A') + 10),
        _ => None,
    }
}

fn scan_percent(text: &str, start: usize) -> (Token, usize) {
    let mut index = start;
    while text.as_bytes().get(index) == Some(&b'%') {
        index += 1;
    }
    let count = index - start;
    let value = if count == 1 && text.as_bytes().get(index).is_some_and(u8::is_ascii_digit) {
        let digit_start = index;
        while text.as_bytes().get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        text[digit_start..index].to_owned()
    } else if count == 1 {
        String::new()
    } else {
        format!("-{}", count)
    };
    (
        Token {
            kind: TokenKind::Percent,
            text: text[start..index].into(),
            start,
            end: index,
            value: Some(value),
        },
        index,
    )
}

fn is_symbol_start(character: char) -> bool {
    character.is_alphabetic() || matches!(character, '$' | '`') || !character.is_ascii()
}

fn is_symbol_continue(character: char) -> bool {
    character.is_alphanumeric() || matches!(character, '$' | '`') || !character.is_ascii()
}

fn scan_symbol(text: &str, start: usize) -> Result<Option<(Token, usize)>> {
    let mut index = start;
    let mut name = String::new();
    let first = text[index..].chars().next().expect("character boundary");
    if first == '\\' {
        let Some((character, end)) = scan_symbol_escape(text, index)? else {
            return Ok(None);
        };
        if !is_symbol_start(character) {
            return Ok(None);
        }
        name.push(character);
        index = end;
    } else if is_symbol_start(first) {
        name.push(first);
        index += first.len_utf8();
    } else {
        return Ok(None);
    }
    while index < text.len() {
        let character = text[index..].chars().next().expect("character boundary");
        if character == '\\' {
            if let Some((decoded, end)) = scan_symbol_escape(text, index)?
                && is_symbol_continue(decoded)
            {
                name.push(decoded);
                index = end;
                continue;
            }
            break;
        }
        if !is_symbol_continue(character) || named_operator(character).is_some() {
            break;
        }
        name.push(character);
        index += character.len_utf8();
    }
    if name.chars().count() == 1 {
        name = match name.chars().next().expect("one character") {
            character if Some(character) == named_character("Pi") => "Pi".into(),
            character if Some(character) == named_character("Infinity") => "Infinity".into(),
            character if Some(character) == named_character("ExponentialE") => "E".into(),
            character if Some(character) == named_character("ImaginaryI") => "I".into(),
            character if Some(character) == named_character("ImaginaryJ") => "I".into(),
            character if Some(character) == named_character("Degree") => "Degree".into(),
            _ => name,
        };
    }
    Ok(Some((
        Token {
            kind: TokenKind::Symbol,
            text: text[start..index].into(),
            start,
            end: index,
            value: Some(name),
        },
        index,
    )))
}

fn scan_symbol_escape(text: &str, start: usize) -> Result<Option<(char, usize)>> {
    if text[start..].starts_with(r"\[") {
        let Some(relative_end) = text[start + 2..].find(']') else {
            return Err(syntax(format!(
                "Unterminated Wolfram named character escape at offset {start}."
            )));
        };
        let end = start + 2 + relative_end;
        let name = &text[start + 2..end];
        if escaped_operator(name).is_some() || escaped_token(name).is_some() {
            return Ok(None);
        }
        let character = named_character(name).ok_or_else(|| {
            syntax(format!(
                r"Unknown Wolfram named character escape \[{name}]."
            ))
        })?;
        return Ok(Some((character, end + 1)));
    }
    Ok(scan_simple_character_escape(text, start))
}

fn scan_simple_character_escape(text: &str, start: usize) -> Option<(char, usize)> {
    if text.as_bytes().get(start) != Some(&b'\\') {
        return None;
    }
    let marker = *text.as_bytes().get(start + 1)?;
    let (radix, digits, offset) = match marker {
        b':' => (16, 4, 2),
        b'.' => (16, 2, 2),
        b'|' => (16, 6, 2),
        b'0'..=b'7' => (8, 3, 1),
        _ => return None,
    };
    let value =
        u32::from_str_radix(text.get(start + offset..start + offset + digits)?, radix).ok()?;
    Some((char::from_u32(value)?, start + offset + digits))
}

fn scan_escaped_token(text: &str, start: usize) -> Result<Option<(Token, usize)>> {
    if !text[start..].starts_with(r"\[") {
        return Ok(None);
    }
    let Some(relative_end) = text[start + 2..].find(']') else {
        return Err(syntax(format!(
            "Unterminated Wolfram escaped token at offset {start}."
        )));
    };
    let end = start + 2 + relative_end;
    let name = &text[start + 2..end];
    let token_end = end + 1;
    if let Some(normalized) = escaped_token(name) {
        return Ok(Some((
            Token::operator(normalized, start, token_end),
            token_end,
        )));
    }
    if let Some(alias) = escaped_alias(name) {
        return Ok(Some((
            Token {
                kind: TokenKind::Symbol,
                text: text[start..token_end].into(),
                start,
                end: token_end,
                value: Some(alias.into()),
            },
            token_end,
        )));
    }
    if escaped_operator(name).is_some() {
        return Ok(Some((
            Token::operator(&text[start..token_end], start, token_end),
            token_end,
        )));
    }
    let character = named_character(name).ok_or_else(|| {
        syntax(format!(
            r"Unknown Wolfram named character escape \[{name}]."
        ))
    })?;
    let value = character.to_string();
    if character.is_whitespace() {
        return Ok(Some((Token::operator(" ", start, token_end), token_end)));
    }
    if "[]{}(),.;:+-*/^!@<>_|&#=?~'".contains(character) {
        return Ok(Some((Token::operator(&value, start, token_end), token_end)));
    }
    Ok(Some((
        Token {
            kind: TokenKind::Symbol,
            text: value.clone(),
            start,
            end: token_end,
            value: Some(value),
        },
        token_end,
    )))
}

fn scan_named_character_token(text: &str, start: usize) -> Option<(Token, usize)> {
    let character = text[start..].chars().next()?;
    let end = start + character.len_utf8();
    if let Some(normalized) = named_token(character) {
        return Some((Token::operator(normalized, start, end), end));
    }
    if let Some(alias) = named_alias(character) {
        return Some((
            Token {
                kind: TokenKind::Symbol,
                text: character.to_string(),
                start,
                end,
                value: Some(alias.into()),
            },
            end,
        ));
    }
    named_operator(character).map(|_| (Token::operator(&character.to_string(), start, end), end))
}

fn escaped_token(name: &str) -> Option<&'static str> {
    Some(match name {
        "And" => "&&",
        "Equal" => "==",
        "Function" => "|->",
        "GreaterEqual" => ">=",
        "InvisibleApplication" => "@",
        "InvisibleTimes" => "*",
        "Rule" => "->",
        "RuleDelayed" => ":>",
        "LessEqual" => "<=",
        "LeftAssociation" => "<|",
        "NotEqual" => "!=",
        "Or" => "||",
        "RightAssociation" => "|>",
        _ => return None,
    })
}

fn escaped_alias(name: &str) -> Option<&'static str> {
    Some(match name {
        "Degree" => "Degree",
        "ExponentialE" => "E",
        "ImaginaryI" | "ImaginaryJ" => "I",
        "Infinity" => "Infinity",
        "Pi" => "Pi",
        _ => return None,
    })
}

fn escaped_operator(name: &str) -> Option<&str> {
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
        "LeftArrow",
        "LeftRightArrow",
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
        "UnionPlus",
        "UpArrow",
        "Vee",
        "VerticalBar",
        "VerticalSeparator",
        "Wedge",
    ];
    NAMES.contains(&name).then_some(name)
}

fn named_token(character: char) -> Option<&'static str> {
    [
        ("And", "&&"),
        ("Equal", "=="),
        ("Function", "|->"),
        ("GreaterEqual", ">="),
        ("InvisibleApplication", "@"),
        ("InvisibleTimes", "*"),
        ("Rule", "->"),
        ("RuleDelayed", ":>"),
        ("LessEqual", "<="),
        ("LeftAssociation", "<|"),
        ("NotEqual", "!="),
        ("Or", "||"),
        ("RightAssociation", "|>"),
    ]
    .into_iter()
    .find_map(|(name, value)| (named_character(name) == Some(character)).then_some(value))
}

fn named_alias(character: char) -> Option<&'static str> {
    [
        ("Degree", "Degree"),
        ("ExponentialE", "E"),
        ("ImaginaryI", "I"),
        ("ImaginaryJ", "I"),
        ("Infinity", "Infinity"),
        ("Pi", "Pi"),
    ]
    .into_iter()
    .find_map(|(name, value)| (named_character(name) == Some(character)).then_some(value))
}

fn named_operator(character: char) -> Option<&'static str> {
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
    NAMES
        .iter()
        .find(|name| named_character(name) == Some(character))
        .copied()
}

const MULTI_TOKENS: &[&str] = &[
    "===", "=!=", "___", "^:=", "//=", "__", "##", "...", "//.", "//@", "@@@", ">>>", "<->", "..",
    "[[", "~~", "<>", "<|", "|>", "|->", "@*", "/*", ":=", "::", ":>", "->", "=.", "^=", "+=",
    "-=", "*=", "/=", "/:", "/;", "//", "/@", "/.", "@@", "++", "--", "**", "<<", ">>", "??", "<=",
    ">=", "==", "!=", "&&", "||", ";;",
];

fn scan_filename(text: &str, start: usize) -> Option<(Token, usize)> {
    let mut index = start;
    while matches!(text.as_bytes().get(index), Some(b' ' | b'\t')) {
        index += 1;
    }
    if text.as_bytes().get(index) == Some(&b'"') {
        return None;
    }
    let name_start = index;
    while let Some(character) = text[index..].chars().next() {
        if character.is_alphanumeric() || "_-*:/\\.`$!?~".contains(character) {
            index += character.len_utf8();
        } else {
            break;
        }
        if index >= text.len() {
            break;
        }
    }
    (index > name_start).then(|| {
        let value = text[name_start..index].to_owned();
        (
            Token {
                kind: TokenKind::Filename,
                text: value.clone(),
                start: name_start,
                end: index,
                value: Some(value),
            },
            index,
        )
    })
}

fn line_continuation_end(text: &str, start: usize) -> Option<usize> {
    let mut index = start + 1;
    while matches!(text.as_bytes().get(index), Some(b' ' | b'\t')) {
        index += 1;
    }
    match text.as_bytes().get(index) {
        Some(b'\r') => {
            Some(index + 1 + usize::from(text.as_bytes().get(index + 1) == Some(&b'\n')))
        }
        Some(b'\n') => Some(index + 1),
        _ => None,
    }
}

fn skip_comment(text: &str, start: usize) -> Result<usize> {
    let mut index = start + 2;
    let mut depth = 1;
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
            index += text[index..]
                .chars()
                .next()
                .expect("character boundary")
                .len_utf8();
        }
    }
    Err(syntax(format!(
        "Unterminated Wolfram comment at offset {start}."
    )))
}

#[derive(Clone, Debug)]
struct Parsed {
    expr: Expr,
    grouped: bool,
    operator_head: Option<&'static str>,
    completed_span: bool,
}

impl Parsed {
    fn new(expr: Expr) -> Self {
        Self {
            expr,
            grouped: false,
            operator_head: None,
            completed_span: false,
        }
    }

    fn operator(expr: Expr, head: &'static str) -> Self {
        Self {
            expr,
            grouped: false,
            operator_head: Some(head),
            completed_span: false,
        }
    }
}

struct Parser {
    tokens: Vec<Token>,
    index: usize,
}

impl Parser {
    const PART_BP: u16 = 190;
    const CALL_BP: u16 = 190;
    const PATTERN_BP: u16 = 185;
    const PATTERN_TEST_BP: u16 = 184;
    const MESSAGE_NAME_BP: u16 = 183;
    const POSTFIX_UNARY_BP: u16 = 175;
    const INFIX_FUNCTION_BP: u16 = 165;
    const POWER_BP: u16 = 160;
    const DOT_BP: u16 = 145;
    const NONCOMMUTATIVE_TIMES_BP: u16 = 146;
    const TIMES_BP: u16 = 140;
    const PLUS_BP: u16 = 120;
    const COMPARE_BP: u16 = 100;
    const AND_BP: u16 = 80;
    const OR_BP: u16 = 70;
    const ALTERNATIVES_BP: u16 = 65;
    const STRING_EXPRESSION_BP: u16 = 64;
    const NAMED_PATTERN_BP: u16 = 63;
    const NAMED_PATTERN_LEFT_BP: u16 = 180;
    const CONDITION_BP: u16 = 62;
    const RULE_BP: u16 = 60;
    const TWO_WAY_RULE_BP: u16 = 61;
    const REPLACE_BP: u16 = 50;
    const MAP_BP: u16 = 45;
    const APPLY_BP: u16 = 44;
    const COMPOSITION_BP: u16 = 43;
    const POSTFIX_FUNCTION_BP: u16 = 42;
    const ASSIGNMENT_BP: u16 = 40;
    const PUT_BP: u16 = 35;
    const AT_BP: u16 = 180;
    const POSTFIX_BP: u16 = 30;
    const SEMICOLON_BP: u16 = 20;
    const FUNCTION_BP: u16 = 10;
    const SPAN_BP: u16 = 110;
    const PREFIX_NOT_BP: u16 = 90;
    const PREFIX_PLUS_MINUS_BP: u16 = 142;

    fn new(text: &str) -> Result<Self> {
        Ok(Self {
            tokens: tokenize(text)?,
            index: 0,
        })
    }

    fn parse(mut self) -> Result<Expr> {
        if self.peek().kind == TokenKind::Eof {
            return Ok(symbol("Null"));
        }
        let expression = self.parse_bp(0, &HashSet::from(["eof"]))?;
        self.expect("eof")?;
        Ok(expression.expr)
    }

    fn peek(&self) -> &Token {
        &self.tokens[self.index]
    }

    fn token_terminates(&self, token: &Token, terminators: &HashSet<&str>) -> bool {
        token.kind == TokenKind::Eof
            || (token.kind == TokenKind::Operator && terminators.contains(token.text.as_str()))
            || (token.kind == TokenKind::Eof && terminators.contains("eof"))
    }

    fn consume(&mut self) -> Token {
        let token = self.tokens[self.index].clone();
        self.index += 1;
        token
    }

    fn matches(&mut self, values: &[&str]) -> Option<Token> {
        let token = self.peek();
        let matches_kind = values.contains(&match token.kind {
            TokenKind::Eof => "eof",
            TokenKind::Integer => "integer",
            TokenKind::Real => "real",
            TokenKind::String => "string",
            TokenKind::Symbol => "symbol",
            TokenKind::Percent => "percent",
            TokenKind::Filename => "filename",
            TokenKind::Operator => "operator",
        });
        if values.contains(&token.text.as_str()) || matches_kind {
            Some(self.consume())
        } else {
            None
        }
    }

    fn expect(&mut self, value: &str) -> Result<Token> {
        self.matches(&[value]).ok_or_else(|| {
            let token = self.peek();
            syntax(format!(
                "Expected {value:?}, found {:?} at offset {}.",
                token.text, token.start
            ))
        })
    }

    fn parse_bp(&mut self, min_bp: u16, terminators: &HashSet<&str>) -> Result<Parsed> {
        if self.token_terminates(self.peek(), terminators) {
            let token = self.peek();
            return Err(syntax(format!(
                "Unexpected {:?} at offset {}.",
                token.text, token.start
            )));
        }
        let mut left = self.parse_prefix(terminators)?;
        loop {
            let token = self.peek().clone();
            if self.token_terminates(&token, terminators) {
                break;
            }
            if matches!(token.text.as_str(), "_" | "__" | "___") {
                if Self::PATTERN_BP < min_bp {
                    break;
                }
                if self.can_attach_named_blank(&left, &token) {
                    left = self.parse_postfix_pattern(left)?;
                } else {
                    if Self::TIMES_BP < min_bp {
                        break;
                    }
                    let blank = self.parse_prefix_blank_at_position()?;
                    left = self.flat_call("Times", left, blank);
                }
                continue;
            }
            if matches!(token.text.as_str(), ".." | "...") {
                if Self::PATTERN_BP < min_bp {
                    break;
                }
                self.consume();
                if token.text == "..." && is_optional_dot_candidate(&left.expr) {
                    left = Parsed::new(call("Repeated", [call("Optional", [left.expr])]));
                } else {
                    let head = if token.text == "..." {
                        "RepeatedNull"
                    } else {
                        "Repeated"
                    };
                    left = Parsed::new(call(head, [left.expr]));
                }
                continue;
            }
            if token.text == "?" {
                if Self::PATTERN_TEST_BP < min_bp {
                    break;
                }
                self.consume();
                let test = self.parse_bp(Self::PATTERN_TEST_BP + 1, terminators)?.expr;
                left = Parsed::new(call("PatternTest", [left.expr, test]));
                continue;
            }
            if token.text == "."
                && is_optional_dot_candidate(&left.expr)
                && self.optional_dot_context(terminators)
            {
                if Self::PATTERN_BP < min_bp {
                    break;
                }
                self.consume();
                left = Parsed::new(call("Optional", [left.expr]));
                continue;
            }
            if token.text == "!" {
                if Self::POSTFIX_UNARY_BP < min_bp {
                    break;
                }
                self.consume();
                let head = if self.matches(&["!"]).is_some() {
                    "Factorial2"
                } else {
                    "Factorial"
                };
                left = Parsed::new(call(head, [left.expr]));
                continue;
            }
            if token.text == "'" {
                if Self::POSTFIX_UNARY_BP < min_bp {
                    break;
                }
                let mut count = 0;
                while self.matches(&["'"]).is_some() {
                    count += 1;
                }
                left = Parsed::new(call(call("Derivative", [integer(count)]), [left.expr]));
                continue;
            }
            if matches!(token.text.as_str(), "++" | "--") {
                if Self::POSTFIX_UNARY_BP < min_bp {
                    break;
                }
                self.consume();
                left = Parsed::new(call(
                    if token.text == "++" {
                        "Increment"
                    } else {
                        "Decrement"
                    },
                    [left.expr],
                ));
                continue;
            }
            if token.text == "=." {
                if Self::POSTFIX_UNARY_BP < min_bp {
                    break;
                }
                self.consume();
                left = unset(left);
                continue;
            }
            if token.text == "[" {
                if Self::CALL_BP < min_bp {
                    break;
                }
                self.consume();
                let args = self.parse_sequence("]")?;
                self.expect("]")?;
                left = Parsed::new(call(left.expr, args));
                continue;
            }
            if token.text == "[[" {
                if Self::PART_BP < min_bp {
                    break;
                }
                self.consume();
                let specs = self.parse_sequence("]")?;
                self.expect("]")?;
                self.expect("]")?;
                let mut args = vec![left.expr];
                args.extend(specs);
                left = Parsed::new(call("Part", args));
                continue;
            }
            if token.text == ";;" {
                if Self::SPAN_BP < min_bp {
                    break;
                }
                self.consume();
                if left.completed_span && !left.grouped {
                    let next = self.finish_span(integer(1), terminators)?;
                    left = self.flat_call("Times", left, next);
                } else {
                    left = self.finish_span(left.expr, terminators)?;
                }
                continue;
            }
            if token.text == "&" {
                if Self::POSTFIX_FUNCTION_BP < min_bp {
                    break;
                }
                self.consume();
                left = Parsed::new(call("Function", [left.expr]));
                continue;
            }
            if token.text == "~" {
                if Self::INFIX_FUNCTION_BP < min_bp {
                    break;
                }
                self.consume();
                let mut operator_terminators = terminators.clone();
                operator_terminators.insert("~");
                let operator = self.parse_bp(0, &operator_terminators)?.expr;
                self.expect("~")?;
                let right = self
                    .parse_bp(Self::INFIX_FUNCTION_BP + 1, terminators)?
                    .expr;
                left = Parsed::new(call(operator, [left.expr, right]));
                continue;
            }
            if starts_primary(&token) {
                if Self::TIMES_BP < min_bp {
                    break;
                }
                let right = self.parse_bp(Self::TIMES_BP + 1, terminators)?;
                left = self.flat_call("Times", left, right);
                continue;
            }
            let Some(next) = self.parse_infix(left.clone(), min_bp, terminators)? else {
                break;
            };
            left = next;
        }
        if is_tag_prefix(&left.expr) {
            return Err(syntax("Expected '=', ':=', or '=.' after '/:'."));
        }
        Ok(left)
    }

    fn parse_prefix(&mut self, terminators: &HashSet<&str>) -> Result<Parsed> {
        let token = self.consume();
        match token.kind {
            TokenKind::Integer => {
                let value =
                    BigInt::parse_bytes(token.value.as_deref().unwrap_or_default().as_bytes(), 10)
                        .ok_or_else(|| syntax("Malformed integer literal."))?;
                return Ok(Parsed::new(integer(value)));
            }
            TokenKind::Real => return Ok(Parsed::new(real(token.value.unwrap_or_default()))),
            TokenKind::String => return Ok(Parsed::new(string(token.value.unwrap_or_default()))),
            TokenKind::Symbol => return Ok(Parsed::new(symbol(token.value.unwrap_or_default()))),
            TokenKind::Percent => {
                let value = token.value.unwrap_or_default();
                return Ok(Parsed::new(if value.is_empty() {
                    call("Out", [])
                } else {
                    call(
                        "Out",
                        [integer(
                            value
                                .parse::<i64>()
                                .map_err(|_| syntax("Invalid output history index."))?,
                        )],
                    )
                }));
            }
            _ => {}
        }
        match token.text.as_str() {
            "(" => {
                let expression = self.parse_bp(0, &HashSet::from([")"]))?;
                self.expect(")")?;
                return Ok(Parsed {
                    grouped: true,
                    ..expression
                });
            }
            "{" => {
                let items = self.parse_sequence("}")?;
                self.expect("}")?;
                return Ok(Parsed::new(list(items)));
            }
            "<|" => {
                let items = self.parse_sequence("|>")?;
                self.expect("|>")?;
                return Ok(Parsed::new(call("Association", items)));
            }
            "_" => return Ok(Parsed::new(self.prefix_blank("Blank"))),
            "__" => return Ok(Parsed::new(self.prefix_blank("BlankSequence"))),
            "___" => return Ok(Parsed::new(self.prefix_blank("BlankNullSequence"))),
            "#" => return Ok(Parsed::new(self.prefix_slot(false)?)),
            "##" => return Ok(Parsed::new(self.prefix_slot(true)?)),
            "?" | "??" => {
                let name = self.file_name("information")?;
                let option = call(
                    "Rule",
                    [
                        symbol("LongForm"),
                        symbol(if token.text == "??" { "True" } else { "False" }),
                    ],
                );
                return Ok(Parsed::new(call("Information", [name, option])));
            }
            "<<" => return Ok(Parsed::new(call("Get", [self.file_name("Get")?]))),
            "++" | "--" => {
                let operand = self.parse_bp(Self::POSTFIX_UNARY_BP, terminators)?.expr;
                return Ok(Parsed::new(call(
                    if token.text == "++" {
                        "PreIncrement"
                    } else {
                        "PreDecrement"
                    },
                    [operand],
                )));
            }
            "+" => {
                let operand = self.parse_bp(Self::PREFIX_PLUS_MINUS_BP, terminators)?.expr;
                return Ok(Parsed::operator(call("Plus", [operand]), "Plus"));
            }
            "-" => {
                let operand = self.parse_bp(Self::PREFIX_PLUS_MINUS_BP, terminators)?.expr;
                return Ok(Parsed::new(match operand {
                    Expr::Integer(value) => integer(-value),
                    Expr::Real(text) if text.starts_with('-') => real(text[1..].to_owned()),
                    Expr::Real(text) => real(format!("-{text}")),
                    _ => call("Times", [integer(-1), operand]),
                }));
            }
            "!" => {
                let operand = self.parse_bp(Self::PREFIX_NOT_BP, terminators)?.expr;
                return Ok(Parsed::new(call("Not", [operand])));
            }
            ";;" => return self.finish_span(integer(1), terminators),
            _ => {}
        }
        Err(syntax(format!(
            "Unexpected token {:?} at offset {}.",
            token.text, token.start
        )))
    }

    fn parse_sequence(&mut self, end: &str) -> Result<Vec<Expr>> {
        let mut items = Vec::new();
        if self.peek().text == end {
            return Ok(items);
        }
        loop {
            if matches!(self.peek().text.as_str(), ",") || self.peek().text == end {
                items.push(symbol("Null"));
            } else {
                items.push(self.parse_bp(0, &HashSet::from([",", end]))?.expr);
            }
            if self.matches(&[","]).is_none() {
                break;
            }
        }
        Ok(items)
    }

    fn prefix_blank(&mut self, head: &str) -> Expr {
        let blank = &self.tokens[self.index - 1];
        let next = self.peek();
        if next.kind == TokenKind::Symbol && blank.end == next.start {
            let name = self.consume().value.unwrap_or_default();
            call(head.to_owned(), [symbol(name)])
        } else {
            call(head.to_owned(), [])
        }
    }

    fn prefix_slot(&mut self, sequence: bool) -> Result<Expr> {
        let head = if sequence { "SlotSequence" } else { "Slot" };
        if self.peek().kind == TokenKind::Integer {
            let value = self.consume().value.unwrap_or_default();
            let number = BigInt::parse_bytes(value.as_bytes(), 10)
                .ok_or_else(|| syntax("Invalid slot index."))?;
            return Ok(call(head, [integer(number)]));
        }
        if self.peek().kind == TokenKind::Real
            && let Some(digits) = self.peek().text.strip_suffix('.')
            && !digits.is_empty()
            && digits.bytes().all(|byte| byte.is_ascii_digit())
        {
            let number = BigInt::parse_bytes(digits.as_bytes(), 10)
                .ok_or_else(|| syntax("Invalid slot index."))?;
            let token = &mut self.tokens[self.index];
            token.kind = TokenKind::Operator;
            token.text = ".".into();
            token.start = token.end - 1;
            token.value = Some(".".into());
            return Ok(call(head, [integer(number)]));
        }
        if !sequence {
            let slot = &self.tokens[self.index - 1];
            if matches!(self.peek().kind, TokenKind::Symbol | TokenKind::String)
                && slot.end == self.peek().start
            {
                let value = self.consume().value.unwrap_or_default();
                return Ok(call(head, [string(value)]));
            }
        }
        Ok(call(head, [integer(1)]))
    }

    fn can_attach_named_blank(&self, left: &Parsed, blank: &Token) -> bool {
        matches!(left.expr, Expr::Symbol(_))
            && self.index > 0
            && self.tokens[self.index - 1].end == blank.start
    }

    fn parse_prefix_blank_at_position(&mut self) -> Result<Parsed> {
        let token = self.consume();
        let head = match token.text.as_str() {
            "_" => "Blank",
            "__" => "BlankSequence",
            "___" => "BlankNullSequence",
            _ => return Err(syntax("Expected a blank pattern.")),
        };
        Ok(Parsed::new(self.prefix_blank(head)))
    }

    fn parse_postfix_pattern(&mut self, left: Parsed) -> Result<Parsed> {
        let token = self.consume();
        let Expr::Symbol(name) = left.expr else {
            return Err(syntax("Named pattern shorthand requires a symbol."));
        };
        let head = match token.text.as_str() {
            "_" => "Blank",
            "__" => "BlankSequence",
            "___" => "BlankNullSequence",
            _ => return Err(syntax("Expected a blank pattern.")),
        };
        let blank = self.prefix_blank(head);
        Ok(Parsed::new(call("Pattern", [symbol(name), blank])))
    }

    fn optional_dot_context(&self, terminators: &HashSet<&str>) -> bool {
        let next = &self.tokens[self.index + 1];
        self.token_terminates(next, terminators)
            || [
                ",", "]", "}", "|>", ")", ";", "+", "-", "*", "/", "**", "^", "&&", "||", "|",
                "~~", "/;", "->", ":>", "<->", "/.", "//.", "/@", "//@", "@@", "@@@", "==", "!=",
                "===", "=!=", "<", "<=", ">", ">=", "=", ":=",
            ]
            .contains(&next.text.as_str())
            || (self.peek().end < next.start && starts_primary(next))
    }

    fn finish_span(&mut self, start: Expr, terminators: &HashSet<&str>) -> Result<Parsed> {
        let end = self.span_argument(symbol("All"), terminators)?;
        let mut args = vec![start, end];
        if self.peek().text == ";;"
            && self
                .tokens
                .get(self.index + 1)
                .is_some_and(can_start_expression)
        {
            self.consume();
            args.push(self.span_argument(integer(1), terminators)?);
        }
        Ok(Parsed {
            expr: call("Span", args),
            grouped: false,
            operator_head: None,
            completed_span: true,
        })
    }

    fn span_argument(&mut self, default: Expr, terminators: &HashSet<&str>) -> Result<Expr> {
        let token = self.peek();
        if self.token_terminates(token, terminators)
            || [",", "]", "}", "|>", ";;", ";"].contains(&token.text.as_str())
        {
            return Ok(default);
        }
        self.parse_bp(Self::SPAN_BP + 1, terminators)
            .map(|parsed| parsed.expr)
    }

    fn file_name(&mut self, context: &str) -> Result<Expr> {
        let token = self.peek();
        if matches!(
            token.kind,
            TokenKind::Filename | TokenKind::Symbol | TokenKind::String
        ) {
            let value = self.consume().value.unwrap_or_default();
            Ok(string(value))
        } else {
            Err(syntax(format!(
                "Expected {context} name at offset {}.",
                token.start
            )))
        }
    }

    fn parse_infix(
        &mut self,
        left: Parsed,
        min_bp: u16,
        terminators: &HashSet<&str>,
    ) -> Result<Option<Parsed>> {
        let token = self.peek().clone();
        let text = token.text.as_str();
        if text == "::" {
            if Self::MESSAGE_NAME_BP < min_bp {
                return Ok(None);
            }
            self.consume();
            let tag = self.peek();
            if !matches!(tag.kind, TokenKind::Symbol | TokenKind::String) {
                return Err(syntax(format!(
                    "Expected message tag at offset {}.",
                    tag.start
                )));
            }
            let tag = string(self.consume().value.unwrap_or_default());
            let expression = if let Expr::Call { head, mut args } = left.expr {
                if head.symbol_name() == Some("MessageName") {
                    args.push(tag);
                    call(*head, args)
                } else {
                    call("MessageName", [Expr::Call { head, args }, tag])
                }
            } else {
                call("MessageName", [left.expr, tag])
            };
            return Ok(Some(Parsed::new(expression)));
        }
        if matches!(text, ">>" | ">>>") {
            if Self::PUT_BP < min_bp {
                return Ok(None);
            }
            self.consume();
            let file = self.file_name("Put")?;
            return Ok(Some(Parsed::new(call(
                if text == ">>" { "Put" } else { "PutAppend" },
                [left.expr, file],
            ))));
        }
        if text == "/:" {
            if Self::ASSIGNMENT_BP < min_bp {
                return Ok(None);
            }
            self.consume();
            let mut tagged_terminators = terminators.clone();
            tagged_terminators.insert("=.");
            let tagged = self
                .parse_bp(Self::ASSIGNMENT_BP + 1, &tagged_terminators)?
                .expr;
            return Ok(Some(Parsed::new(call("TagSetPrefix", [left.expr, tagged]))));
        }
        if text == ";" {
            if Self::SEMICOLON_BP < min_bp {
                return Ok(None);
            }
            self.consume();
            let right = if self.token_terminates(self.peek(), terminators)
                || !can_start_expression(self.peek())
            {
                Parsed::new(symbol("Null"))
            } else {
                self.parse_bp(Self::SEMICOLON_BP + 1, terminators)?
            };
            return Ok(Some(self.compound(left, right)));
        }
        if text == "="
            && self
                .tokens
                .get(self.index + 1)
                .is_some_and(|token| token.text == ".")
        {
            if Self::ASSIGNMENT_BP < min_bp {
                return Ok(None);
            }
            self.consume();
            self.consume();
            return Ok(Some(unset(left)));
        }
        let Some((left_bp, right_bp, head)) = binary_spec(text).or_else(|| {
            let head = escaped_operator_from_token(text)?;
            let bp = match head {
                "CirclePlus" => 125,
                "CircleTimes" => 142,
                "Diamond" => 144,
                _ => Self::COMPARE_BP,
            };
            Some((bp, bp + 1, Some(head)))
        }) else {
            return Ok(None);
        };
        if left_bp < min_bp {
            return Ok(None);
        }
        self.consume();
        let right = self.parse_bp(right_bp, terminators)?;
        let result = match text {
            "/" => self.division(left, right),
            "-" => self.flat_call(
                "Plus",
                left,
                Parsed::new(negate_for_subtraction(right.expr)),
            ),
            ":" => combine_colon(left, right),
            "@" => Parsed::new(call(left.expr, [right.expr])),
            "//" => Parsed::new(call(right.expr, [left.expr])),
            _ => {
                let head =
                    head.ok_or_else(|| syntax(format!("Unhandled Wolfram operator {text:?}.")))?;
                if matches!(head, "Set" | "SetDelayed") && is_tag_prefix(&left.expr) {
                    let Expr::Call { args, .. } = left.expr else {
                        unreachable!()
                    };
                    Parsed::new(call(
                        if head == "Set" {
                            "TagSet"
                        } else {
                            "TagSetDelayed"
                        },
                        [args[0].clone(), args[1].clone(), right.expr],
                    ))
                } else if CHAINABLE_COMPARISONS.contains(&head) {
                    self.comparison(head, left, right)
                } else if PARSER_FLAT_HEADS.contains(&head)
                    || escaped_operator_from_token(text).is_some()
                {
                    self.flat_call(head, left, right)
                } else {
                    Parsed::operator(call(head, [left.expr, right.expr]), head)
                }
            }
        };
        Ok(Some(result))
    }

    fn flat_call(&self, head: &'static str, left: Parsed, right: Parsed) -> Parsed {
        let mut args = Vec::new();
        append_flat(&mut args, left, head);
        append_flat(&mut args, right, head);
        Parsed::operator(call(head, args), head)
    }

    fn division(&self, left: Parsed, right: Parsed) -> Parsed {
        let reciprocal = call("Power", [right.expr, integer(-1)]);
        if left.operator_head == Some("Times")
            && !left.grouped
            && let Expr::Call { args, .. } = &left.expr
            && !args.is_empty()
        {
            let mut divided = args[..args.len() - 1].to_vec();
            divided.push(call("Times", [args[args.len() - 1].clone(), reciprocal]));
            return Parsed::operator(call("Times", divided), "Times");
        }
        Parsed::new(call("Times", [left.expr, reciprocal]))
    }

    fn comparison(&self, head: &'static str, left: Parsed, right: Parsed) -> Parsed {
        if right.operator_head == Some(head)
            && !right.grouped
            && let Expr::Call { args, .. } = right.expr
        {
            let mut all = vec![left.expr];
            all.extend(args);
            return Parsed::operator(call(head, all), head);
        }
        if right
            .operator_head
            .is_some_and(|name| CHAINABLE_COMPARISONS.contains(&name))
            && !right.grouped
            && let Expr::Call { args, .. } = right.expr
        {
            let right_head = right.operator_head.expect("checked");
            let mut all = vec![left.expr, symbol(head), args[0].clone()];
            for argument in &args[1..] {
                all.push(symbol(right_head));
                all.push(argument.clone());
            }
            return Parsed::operator(call("Inequality", all), "Inequality");
        }
        if right.operator_head == Some("Inequality")
            && !right.grouped
            && let Expr::Call { args, .. } = right.expr
        {
            let mut all = vec![left.expr, symbol(head)];
            all.extend(args);
            return Parsed::operator(call("Inequality", all), "Inequality");
        }
        Parsed::operator(call(head, [left.expr, right.expr]), head)
    }

    fn compound(&self, left: Parsed, right: Parsed) -> Parsed {
        let mut args = Vec::new();
        append_flat(&mut args, left, "CompoundExpression");
        append_flat(&mut args, right, "CompoundExpression");
        Parsed::operator(call("CompoundExpression", args), "CompoundExpression")
    }
}

fn starts_primary(token: &Token) -> bool {
    matches!(
        token.kind,
        TokenKind::Integer
            | TokenKind::Real
            | TokenKind::String
            | TokenKind::Symbol
            | TokenKind::Percent
    ) || ["(", "{", "<|", "#", "##", "_", "__", "___", "<<"].contains(&token.text.as_str())
}

fn can_start_expression(token: &Token) -> bool {
    starts_primary(token)
        || ["?", "??", "++", "--", "+", "-", "!", ";;"].contains(&token.text.as_str())
}

fn is_optional_dot_candidate(expr: &Expr) -> bool {
    if expr.has_head("Blank") && expr.args().is_empty() {
        return true;
    }
    if !expr.has_head("Pattern")
        || expr.args().len() != 2
        || !matches!(expr.args()[0], Expr::Symbol(_))
    {
        return false;
    }
    expr.args()[1].has_head("Blank") && expr.args()[1].args().is_empty()
}

fn append_flat(args: &mut Vec<Expr>, parsed: Parsed, head: &str) {
    if parsed.operator_head == Some(head)
        && !parsed.grouped
        && let Expr::Call { args: nested, .. } = parsed.expr
    {
        args.extend(nested);
    } else {
        args.push(parsed.expr);
    }
}

fn negate_for_subtraction(expr: Expr) -> Expr {
    match expr {
        Expr::Integer(value) if !value.is_negative() => integer(-value),
        Expr::Real(text) if !text.starts_with('-') => real(format!("-{text}")),
        _ => call("Times", [integer(-1), expr]),
    }
}

fn combine_colon(left: Parsed, right: Parsed) -> Parsed {
    if matches!(left.expr, Expr::Symbol(_)) {
        Parsed::operator(call("Pattern", [left.expr, right.expr]), "Colon")
    } else {
        Parsed::operator(call("Optional", [left.expr, right.expr]), "Colon")
    }
}

fn unset(left: Parsed) -> Parsed {
    if is_tag_prefix(&left.expr) {
        let Expr::Call { args, .. } = left.expr else {
            unreachable!()
        };
        Parsed::new(call("TagUnset", [args[0].clone(), args[1].clone()]))
    } else {
        Parsed::new(call("Unset", [left.expr]))
    }
}

fn is_tag_prefix(expr: &Expr) -> bool {
    expr.has_head("TagSetPrefix") && expr.args().len() == 2
}

const CHAINABLE_COMPARISONS: &[&str] = &[
    "Equal",
    "Greater",
    "GreaterEqual",
    "Less",
    "LessEqual",
    "SameQ",
    "Unequal",
    "UnsameQ",
];

const PARSER_FLAT_HEADS: &[&str] = &[
    "Plus",
    "Times",
    "Dot",
    "NonCommutativeMultiply",
    "Composition",
    "RightComposition",
];

fn binary_spec(text: &str) -> Option<(u16, u16, Option<&'static str>)> {
    Some(match text {
        "^" => (Parser::POWER_BP, Parser::POWER_BP, Some("Power")),
        "**" => (
            Parser::NONCOMMUTATIVE_TIMES_BP,
            Parser::NONCOMMUTATIVE_TIMES_BP + 1,
            Some("NonCommutativeMultiply"),
        ),
        "*" => (Parser::TIMES_BP, Parser::TIMES_BP + 1, Some("Times")),
        "/" => (Parser::TIMES_BP, Parser::TIMES_BP + 1, None),
        "+" => (Parser::PLUS_BP, Parser::PLUS_BP + 1, Some("Plus")),
        "-" => (Parser::PLUS_BP, Parser::PLUS_BP + 1, None),
        "<>" => (Parser::PLUS_BP, Parser::PLUS_BP + 1, Some("StringJoin")),
        "==" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("Equal")),
        "===" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("SameQ")),
        "!=" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("Unequal")),
        "=!=" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("UnsameQ")),
        "<" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("Less")),
        "<=" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("LessEqual")),
        ">" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("Greater")),
        ">=" => (Parser::COMPARE_BP, Parser::COMPARE_BP, Some("GreaterEqual")),
        "&&" => (Parser::AND_BP, Parser::AND_BP + 1, Some("And")),
        "||" => (Parser::OR_BP, Parser::OR_BP + 1, Some("Or")),
        "|" => (
            Parser::ALTERNATIVES_BP,
            Parser::ALTERNATIVES_BP + 1,
            Some("Alternatives"),
        ),
        "~~" => (
            Parser::STRING_EXPRESSION_BP,
            Parser::STRING_EXPRESSION_BP + 1,
            Some("StringExpression"),
        ),
        ":" => (
            Parser::NAMED_PATTERN_LEFT_BP,
            Parser::NAMED_PATTERN_BP,
            Some("Pattern"),
        ),
        "/;" => (
            Parser::CONDITION_BP,
            Parser::CONDITION_BP + 1,
            Some("Condition"),
        ),
        "<->" => (
            Parser::TWO_WAY_RULE_BP,
            Parser::TWO_WAY_RULE_BP,
            Some("TwoWayRule"),
        ),
        "->" => (Parser::RULE_BP, Parser::RULE_BP, Some("Rule")),
        ":>" => (Parser::RULE_BP, Parser::RULE_BP, Some("RuleDelayed")),
        "/." => (
            Parser::REPLACE_BP,
            Parser::REPLACE_BP + 1,
            Some("ReplaceAll"),
        ),
        "//." => (
            Parser::REPLACE_BP,
            Parser::REPLACE_BP + 1,
            Some("ReplaceRepeated"),
        ),
        "/@" => (Parser::MAP_BP, Parser::MAP_BP, Some("Map")),
        "//@" => (Parser::MAP_BP, Parser::MAP_BP, Some("MapAll")),
        "@@" => (Parser::APPLY_BP, Parser::APPLY_BP, Some("Apply")),
        "@@@" => (Parser::APPLY_BP, Parser::APPLY_BP, Some("MapApply")),
        "@*" => (
            Parser::COMPOSITION_BP,
            Parser::COMPOSITION_BP + 1,
            Some("Composition"),
        ),
        "/*" => (
            Parser::COMPOSITION_BP,
            Parser::COMPOSITION_BP,
            Some("RightComposition"),
        ),
        "@" => (Parser::AT_BP, Parser::AT_BP, None),
        "//" => (Parser::POSTFIX_BP, Parser::POSTFIX_BP + 1, None),
        "." => (Parser::DOT_BP, Parser::DOT_BP + 1, Some("Dot")),
        "=" => (Parser::ASSIGNMENT_BP, Parser::ASSIGNMENT_BP, Some("Set")),
        ":=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("SetDelayed"),
        ),
        "^=" => (Parser::ASSIGNMENT_BP, Parser::ASSIGNMENT_BP, Some("UpSet")),
        "^:=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("UpSetDelayed"),
        ),
        "+=" => (Parser::ASSIGNMENT_BP, Parser::ASSIGNMENT_BP, Some("AddTo")),
        "-=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("SubtractFrom"),
        ),
        "*=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("TimesBy"),
        ),
        "/=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("DivideBy"),
        ),
        "//=" => (
            Parser::ASSIGNMENT_BP,
            Parser::ASSIGNMENT_BP,
            Some("ApplyTo"),
        ),
        "|->" => (Parser::FUNCTION_BP, Parser::FUNCTION_BP, Some("Function")),
        _ => return None,
    })
}

fn escaped_operator_from_token(token: &str) -> Option<&'static str> {
    if token.starts_with(r"\[") && token.ends_with(']') {
        let name = &token[2..token.len() - 1];
        return escaped_operator(name).map(|value| {
            // Names come from a static table, so extending the lifetime is unnecessary;
            // recover the corresponding table element directly.
            escaped_operator_static(value).expect("operator name is in static table")
        });
    }
    let character = token.chars().next()?;
    (token.chars().count() == 1)
        .then(|| named_operator(character))
        .flatten()
}

fn escaped_operator_static(name: &str) -> Option<&'static str> {
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
        "LeftArrow",
        "LeftRightArrow",
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
        "UnionPlus",
        "UpArrow",
        "Vee",
        "VerticalBar",
        "VerticalSeparator",
        "Wedge",
    ];
    NAMES.iter().find(|candidate| **candidate == name).copied()
}

pub(crate) fn interpret_standard_form(expr: Expr) -> Result<Expr> {
    let Expr::Call { head, args } = expr else {
        return Ok(expr);
    };
    if head.symbol_name() == Some("InterpretationBox") && args.len() >= 2 {
        return interpret_standard_form(args[1].clone());
    }
    if head.symbol_name().is_some_and(|name| {
        matches!(
            name,
            "AdjustmentBox"
                | "BoxData"
                | "FormBox"
                | "FrameBox"
                | "PaneBox"
                | "StyleBox"
                | "TagBox"
                | "TooltipBox"
        )
    }) && !args.is_empty()
    {
        return interpret_standard_form(args[0].clone());
    }
    match head.symbol_name() {
        Some("RowBox") => interpret_row_box(head.as_ref().clone(), args),
        Some("FractionBox") if args.len() >= 2 => {
            let numerator = coerce_box_operand(interpret_standard_form(args[0].clone())?)?;
            let denominator = coerce_box_operand(interpret_standard_form(args[1].clone())?)?;
            Ok(make_division(numerator, denominator))
        }
        Some("SqrtBox") if !args.is_empty() => {
            let radicand = coerce_box_operand(interpret_standard_form(args[0].clone())?)?;
            Ok(call(
                "Power",
                [radicand, call("Rational", [integer(1), integer(2)])],
            ))
        }
        Some("RadicalBox") if args.len() >= 2 => {
            let radicand = coerce_box_operand(interpret_standard_form(args[0].clone())?)?;
            let index = coerce_box_operand(interpret_standard_form(args[1].clone())?)?;
            Ok(call("Power", [radicand, make_division(integer(1), index)]))
        }
        Some("SuperscriptBox") if args.len() >= 2 => Ok(call(
            "Power",
            [
                coerce_box_operand(interpret_standard_form(args[0].clone())?)?,
                coerce_box_operand(interpret_standard_form(args[1].clone())?)?,
            ],
        )),
        Some(name @ ("SubscriptBox" | "OverscriptBox" | "UnderscriptBox")) if args.len() >= 2 => {
            let target = name.trim_end_matches("Box");
            Ok(call(
                target.to_owned(),
                args[..2]
                    .iter()
                    .cloned()
                    .map(interpret_standard_form)
                    .collect::<Result<Vec<_>>>()?
                    .into_iter()
                    .map(coerce_box_operand)
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        Some(name @ ("SubsuperscriptBox" | "UnderoverscriptBox")) if args.len() >= 3 => {
            let target = name.trim_end_matches("Box");
            Ok(call(
                target.to_owned(),
                args[..3]
                    .iter()
                    .cloned()
                    .map(interpret_standard_form)
                    .collect::<Result<Vec<_>>>()?
                    .into_iter()
                    .map(coerce_box_operand)
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        _ => Ok(call(
            interpret_standard_form(head.as_ref().clone())?,
            args.into_iter()
                .map(interpret_standard_form)
                .collect::<Result<Vec<_>>>()?,
        )),
    }
}

fn interpret_row_box(head: Expr, args: Vec<Expr>) -> Result<Expr> {
    if args.len() != 1 || !args[0].has_head("List") {
        return Ok(call(head, args));
    }
    let mut text = String::new();
    let mut previous = String::new();
    for item in args[0].args() {
        let piece = box_item_text(item.clone())?;
        if piece.is_empty() {
            continue;
        }
        if !text.is_empty() && needs_box_separator(&previous, &piece) {
            text.push(' ');
        }
        text.push_str(&piece);
        previous = piece;
    }
    if text.trim().is_empty() {
        Ok(string(""))
    } else {
        parse_standard_form(text.trim())
    }
}

fn box_item_text(expr: Expr) -> Result<String> {
    match expr {
        Expr::String(value) => Ok(normalize_box_token(&value)),
        Expr::Call { ref head, ref args } if head.symbol_name() == Some("RowBox") => {
            row_box_text(args)
        }
        Expr::Call { ref head, ref args }
            if head.symbol_name() == Some("FractionBox") && args.len() >= 2 =>
        {
            Ok(format!(
                "(({})/({}))",
                box_item_text(args[0].clone())?,
                box_item_text(args[1].clone())?
            ))
        }
        other => interpret_standard_form(other).map(|expr| expr.to_input_form()),
    }
}

fn row_box_text(args: &[Expr]) -> Result<String> {
    if args.len() != 1 || !args[0].has_head("List") {
        return Ok(call("RowBox", args.iter().cloned()).to_input_form());
    }
    let mut output = String::new();
    let mut previous = String::new();
    for item in args[0].args() {
        let piece = box_item_text(item.clone())?;
        if piece.is_empty() {
            continue;
        }
        if !output.is_empty() && needs_box_separator(&previous, &piece) {
            output.push(' ');
        }
        output.push_str(&piece);
        previous = piece;
    }
    Ok(output)
}

fn normalize_box_token(value: &str) -> String {
    match value {
        " " | "\t" | "\n" | r"\[InvisibleSpace]" | r"\[InvisibleTimes]" | r"\[ThinSpace]" => {
            " ".into()
        }
        raw if raw.starts_with(r"\[") && raw.ends_with(']') => {
            escaped_token(&raw[2..raw.len() - 1]).unwrap_or(raw).into()
        }
        _ => value.into(),
    }
}

fn needs_box_separator(left: &str, right: &str) -> bool {
    if left.trim().is_empty() || right.trim().is_empty() {
        return false;
    }
    let left_last = left.chars().next_back().unwrap_or_default();
    let right_first = right.chars().next().unwrap_or_default();
    !"[({<,.;+-*/^!@&|=_:".contains(left_last) && !"])}>,.;+-*/^!@&|=_:".contains(right_first)
}

fn coerce_box_operand(expr: Expr) -> Result<Expr> {
    if let Expr::String(value) = &expr {
        return parse_input_form(value.trim()).or(Ok(expr));
    }
    Ok(expr)
}

fn make_division(numerator: Expr, denominator: Expr) -> Expr {
    if matches!(numerator, Expr::Integer(_)) && matches!(denominator, Expr::Integer(_)) {
        call("Rational", [numerator, denominator])
    } else if matches!(&numerator, Expr::Integer(value) if value == &1.into()) {
        call("Power", [denominator, integer(-1)])
    } else {
        call(
            "Times",
            [numerator, call("Power", [denominator, integer(-1)])],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn full(source: &str) -> String {
        parse_input_form(source).unwrap().to_full_form()
    }

    #[test]
    fn parses_full_form_and_arithmetic() {
        assert_eq!(full("Plus[1, Times[2, x]]"), "Plus[1, Times[2, x]]");
        assert_eq!(full("1 + 2 x^3"), "Plus[1, Times[2, Power[x, 3]]]");
        assert_eq!(full("1 + 2 + 3"), "Plus[1, 2, 3]");
        assert_eq!(full("Hold[1 + (2 + 3)]"), "Hold[Plus[1, Plus[2, 3]]]");
    }

    #[test]
    fn parses_numeric_surface() {
        assert_eq!(full("Hold[16^^ff]"), "Hold[255]");
        assert_eq!(full("Hold[1.2``20*^-3]"), "Hold[1.2``20*^-3]");
        assert!(parse_input_form("Hold[37^^10]").is_err());
    }

    #[test]
    fn parses_patterns_and_rules() {
        assert_eq!(
            full("f[x_Integer, y_]"),
            "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]"
        );
        assert_eq!(
            full("x_ /; x > 0"),
            "Condition[Pattern[x, Blank[]], Greater[x, 0]]"
        );
        assert_eq!(full("f[a] /. a -> b"), "ReplaceAll[f[a], Rule[a, b]]");
    }

    #[test]
    fn parses_parts_functions_and_comparisons() {
        assert_eq!(full("expr[[1, 2 ;; -1]]"), "Part[expr, 1, Span[2, -1]]");
        assert_eq!(full("f @ # &"), "Function[f[Slot[1]]]");
        assert_eq!(
            full("Hold[a < b <= c]"),
            "Hold[Inequality[a, Less, b, LessEqual, c]]"
        );
    }
}
