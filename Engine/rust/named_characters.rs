use std::collections::HashMap;

use once_cell::sync::Lazy;

static NAMED_CHARACTERS: Lazy<HashMap<String, u32>> = Lazy::new(|| {
    let payload: serde_json::Value = serde_json::from_str(include_str!(
        "../src/tungsten/data/wolfram_named_characters_15_0.json"
    ))
    .expect("bundled Wolfram named-character snapshot must be valid JSON");
    payload["characters"]
        .as_object()
        .expect("named-character snapshot must contain an object")
        .iter()
        .filter_map(|(name, value)| {
            let codepoint = u32::try_from(value.as_u64()?).ok()?;
            Some((name.clone(), codepoint))
        })
        .collect()
});

static REVERSE_CHARACTERS: Lazy<HashMap<char, String>> = Lazy::new(|| {
    let mut entries: Vec<_> = NAMED_CHARACTERS.iter().collect();
    entries.sort_by(|(left, _), (right, _)| left.cmp(right));
    let mut result = HashMap::new();
    for (name, codepoint) in entries {
        if *codepoint < 128 && name.starts_with("Raw") {
            continue;
        }
        if let Some(character) = char::from_u32(*codepoint) {
            result.entry(character).or_insert_with(|| name.clone());
        }
    }
    result
});

pub fn named_character(name: &str) -> Option<char> {
    NAMED_CHARACTERS.get(name).copied().and_then(char::from_u32)
}

pub fn named_character_name(character: char) -> Option<&'static str> {
    REVERSE_CHARACTERS.get(&character).map(String::as_str)
}

pub fn encode_printable_ascii(text: &str) -> String {
    let mut output = String::new();
    for character in text.chars() {
        let codepoint = u32::from(character);
        if (32..127).contains(&codepoint) {
            output.push(character);
        } else if let Some(escape) = match codepoint {
            8 => Some(r"\b"),
            9 => Some(r"\t"),
            10 => Some(r"\n"),
            12 => Some(r"\f"),
            13 => Some(r"\r"),
            27 => Some(r"\[RawEscape]"),
            _ => None,
        } {
            output.push_str(escape);
        } else if codepoint < 32 || codepoint == 127 {
            output.push_str(&format!(r"\{codepoint:03o}"));
        } else if let Some(name) = named_character_name(character) {
            output.push_str(&format!(r"\[{name}]"));
        } else if codepoint <= 0xffff {
            output.push_str(&format!(r"\:{codepoint:04x}"));
        } else {
            output.push_str(&format!(r"\|{codepoint:06x}"));
        }
    }
    output
}
