use crate::named_characters::named_character;
use serde::Serialize;

const LINEAR_SYNTAX_BANG: char = '\u{f7c1}';
const LINEAR_SYNTAX_OPEN: char = '\u{f7c9}';
const LINEAR_SYNTAX_CLOSE: char = '\u{f7c0}';
const LINEAR_SYNTAX_STAR: char = '\u{f7c8}';

pub const INLINE_BOX_PREFIX: &str = r"\!\(\*";
pub const INLINE_BOX_OPEN: &str = r"\(";
pub const INLINE_BOX_CLOSE: &str = r"\)";

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WolframStringSegment {
    Text {
        text: String,
    },
    InlineBox {
        box_expression: String,
        #[serde(rename = "inline_box_escape")]
        source: String,
    },
}

pub fn wl_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str(r"\\"),
            '"' => escaped.push_str(r#"\""#),
            '\r' => escaped.push_str(r"\r"),
            '\n' => escaped.push_str(r"\n"),
            '\t' => escaped.push_str(r"\t"),
            _ => escaped.push(character),
        }
    }
    escaped.push('"');
    escaped
}

pub fn parse_wl_string_literal(value: &str) -> Result<String, String> {
    let text = if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
        &value[1..value.len() - 1]
    } else {
        value
    };
    let mut result = String::new();
    let mut index = 0;
    while index < text.len() {
        let Some(character) = text[index..].chars().next() else {
            break;
        };
        if character != '\\' {
            result.push(character);
            index += character.len_utf8();
            continue;
        }
        let marker_index = index + 1;
        let Some(marker) = text
            .get(marker_index..)
            .and_then(|tail| tail.chars().next())
        else {
            result.push('\\');
            break;
        };
        if marker == '\n' {
            index = marker_index + 1;
            continue;
        }
        if marker == '\r' {
            index = marker_index + 1;
            if text[index..].starts_with('\n') {
                index += 1;
            }
            continue;
        }
        if let Some((decoded, end)) = decode_character_escape(text, index)? {
            result.push_str(&decoded);
            index = end;
            continue;
        }
        match marker {
            'b' => result.push('\u{0008}'),
            'f' => result.push('\u{000c}'),
            'r' => result.push('\r'),
            'n' => result.push('\n'),
            't' => result.push('\t'),
            '\\' => result.push('\\'),
            '"' => result.push('"'),
            '!' => result.push(LINEAR_SYNTAX_BANG),
            '(' => result.push(LINEAR_SYNTAX_OPEN),
            ')' => result.push(LINEAR_SYNTAX_CLOSE),
            '*' => result.push(LINEAR_SYNTAX_STAR),
            '<' | '>' => {}
            _ => {
                result.push('\\');
                result.push(marker);
            }
        }
        index = marker_index + marker.len_utf8();
    }
    Ok(result)
}

pub fn inline_box_escape(box_expression: &str) -> String {
    format!("{INLINE_BOX_PREFIX}{box_expression}{INLINE_BOX_CLOSE}")
}

pub fn compose_inline_box_string<'a>(
    prefix: &str,
    box_expressions: impl IntoIterator<Item = &'a str>,
    suffix: &str,
) -> String {
    let mut output = prefix.to_owned();
    for expression in box_expressions {
        output.push_str(&inline_box_escape(expression));
    }
    output.push_str(suffix);
    output
}

pub fn compose_inline_box_string_literal<'a>(
    prefix: &str,
    box_expressions: impl IntoIterator<Item = &'a str>,
    suffix: &str,
) -> String {
    wl_string(&compose_inline_box_string(prefix, box_expressions, suffix))
}

pub fn split_inline_boxes(value: &str) -> Vec<WolframStringSegment> {
    let decoded_prefix = format!("{LINEAR_SYNTAX_BANG}{LINEAR_SYNTAX_OPEN}{LINEAR_SYNTAX_STAR}");
    let decoded_open = format!("{LINEAR_SYNTAX_BANG}{LINEAR_SYNTAX_OPEN}");
    let decoded_close = LINEAR_SYNTAX_CLOSE.to_string();
    let mut output = Vec::new();
    let mut text_start = 0;
    let mut index = 0;
    while index < value.len() {
        let parsed = if value[index..].starts_with(INLINE_BOX_PREFIX) {
            parse_inline_box_segment(
                value,
                index,
                INLINE_BOX_PREFIX,
                INLINE_BOX_OPEN,
                INLINE_BOX_CLOSE,
            )
        } else if value[index..].starts_with(&decoded_prefix) {
            parse_inline_box_segment(value, index, &decoded_prefix, &decoded_open, &decoded_close)
        } else {
            None
        };
        if let Some((segment, end)) = parsed {
            if text_start < index {
                output.push(WolframStringSegment::Text {
                    text: value[text_start..index].to_owned(),
                });
            }
            output.push(segment);
            index = end;
            text_start = end;
            continue;
        }
        let Some(character) = value[index..].chars().next() else {
            break;
        };
        index += character.len_utf8();
    }
    if text_start < value.len() {
        output.push(WolframStringSegment::Text {
            text: value[text_start..].to_owned(),
        });
    }
    output
}

fn parse_inline_box_segment(
    value: &str,
    start: usize,
    prefix: &str,
    open: &str,
    close: &str,
) -> Option<(WolframStringSegment, usize)> {
    let mut index = start + prefix.len();
    let mut depth = 1_usize;
    while index < value.len() {
        if value[index..].starts_with(open) {
            depth += 1;
            index += open.len();
            continue;
        }
        if value[index..].starts_with(close) {
            depth -= 1;
            index += close.len();
            if depth == 0 {
                let source = value[start..index].to_owned();
                let expression_end = index - close.len();
                let box_expression = value[start + prefix.len()..expression_end].to_owned();
                return Some((
                    WolframStringSegment::InlineBox {
                        box_expression,
                        source,
                    },
                    index,
                ));
            }
            continue;
        }
        if value[index..].starts_with('"') {
            index = skip_string_value(value, index);
            continue;
        }
        if value[index..].starts_with("(*") {
            index = skip_comment_value(value, index);
            continue;
        }
        let character = value[index..].chars().next()?;
        index += character.len_utf8();
    }
    None
}

fn skip_comment_value(value: &str, start: usize) -> usize {
    let mut index = start + 2;
    let mut depth = 1_usize;
    while index < value.len() {
        if value[index..].starts_with("(*") {
            depth += 1;
            index += 2;
        } else if value[index..].starts_with("*)") {
            depth -= 1;
            index += 2;
            if depth == 0 {
                break;
            }
        } else {
            index += value[index..].chars().next().map_or(1, char::len_utf8);
        }
    }
    index
}

fn skip_string_value(value: &str, start: usize) -> usize {
    let mut index = start + 1;
    while index < value.len() {
        let Some(character) = value[index..].chars().next() else {
            return value.len();
        };
        if character == '\\' {
            index += character.len_utf8();
            if let Some(escaped) = value[index..].chars().next() {
                index += escaped.len_utf8();
            }
            continue;
        }
        index += character.len_utf8();
        if character == '"' {
            break;
        }
    }
    index
}

pub fn inline_box_segments(value: &str) -> Vec<(String, String)> {
    split_inline_boxes(value)
        .into_iter()
        .filter_map(|segment| match segment {
            WolframStringSegment::InlineBox {
                box_expression,
                source,
            } => Some((box_expression, source)),
            WolframStringSegment::Text { .. } => None,
        })
        .collect()
}

pub fn display_text(value: &str, placeholder: &str) -> String {
    split_inline_boxes(value)
        .into_iter()
        .map(|segment| match segment {
            WolframStringSegment::Text { text } => text,
            WolframStringSegment::InlineBox { .. } => placeholder.to_owned(),
        })
        .collect()
}

fn decode_character_escape(text: &str, index: usize) -> Result<Option<(String, usize)>, String> {
    if text[index..].starts_with(r"\[") {
        let Some(relative_end) = text[index + 2..].find(']') else {
            return Ok(None);
        };
        let end = index + 2 + relative_end;
        let name = &text[index + 2..end];
        return Ok(Some((
            named_character(name).map_or_else(|| text[index..=end].to_owned(), String::from),
            end + 1,
        )));
    }
    let tail = &text[index + 1..];
    let Some(marker) = tail.chars().next() else {
        return Ok(None);
    };
    let (radix, digits, offset) = match marker {
        ':' => (16, 4, 2),
        '.' => (16, 2, 2),
        '|' => (16, 6, 2),
        '0'..='7' => (8, 3, 1),
        _ => return Ok(None),
    };
    let start = index + offset;
    let Some(raw) = text.get(start..start + digits) else {
        return Ok(None);
    };
    if !raw.chars().all(|character| character.is_digit(radix)) {
        return Ok(None);
    }
    let codepoint = u32::from_str_radix(raw, radix).map_err(|error| error.to_string())?;
    let Some(character) = char::from_u32(codepoint) else {
        return Ok(None);
    };
    Ok(Some((character.to_string(), start + digits)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_box_escape_decodes_to_linear_syntax_markers() {
        let decoded =
            parse_wl_string_literal(r#""hello \!\(\*GraphicsBox[{CircleBox[]}]\)""#).unwrap();
        assert_eq!(
            decoded,
            "hello \u{f7c1}\u{f7c9}\u{f7c8}GraphicsBox[{CircleBox[]}]"
        );
        assert_eq!(
            inline_box_segments(&decoded),
            vec![(
                "GraphicsBox[{CircleBox[]}]".to_owned(),
                "\u{f7c1}\u{f7c9}\u{f7c8}GraphicsBox[{CircleBox[]}]".to_owned(),
            )]
        );
    }

    #[test]
    fn inline_box_composition_matches_wolfram_string_source() {
        let expressions = ["GraphicsBox[{CircleBox[]}]", r#"StyleBox["x", Bold]"#];
        let value = compose_inline_box_string("icon: ", expressions, ".");
        assert_eq!(
            value,
            r#"icon: \!\(\*GraphicsBox[{CircleBox[]}]\)\!\(\*StyleBox["x", Bold]\)."#
        );
        assert_eq!(
            compose_inline_box_string_literal("icon: ", expressions, "."),
            r#""icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)\\!\\(\\*StyleBox[\"x\", Bold]\\).""#
        );
    }

    #[test]
    fn inline_box_scanner_handles_nesting_and_quoted_delimiters() {
        let value =
            r#"before \!\(\*RowBox[{"literal \\)", FormBox[\(x\), TraditionalForm]}]\) after"#;
        let segments = split_inline_boxes(value);
        assert_eq!(segments.len(), 3);
        assert_eq!(
            segments[1],
            WolframStringSegment::InlineBox {
                box_expression: r#"RowBox[{"literal \\)", FormBox[\(x\), TraditionalForm]}]"#
                    .to_owned(),
                source: r#"\!\(\*RowBox[{"literal \\)", FormBox[\(x\), TraditionalForm]}]\)"#
                    .to_owned(),
            }
        );
        assert_eq!(
            display_text(value, "[InlineBox]"),
            "before [InlineBox] after"
        );
    }
}
