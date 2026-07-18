//! Inspection and temporary de-duplication of Wolfram `mathpass` files.

use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MathpassInspection {
    pub path: Option<String>,
    pub header_present: bool,
    pub original_line_count: usize,
    pub unique_entry_count: usize,
    pub duplicate_entry_count: usize,
}

impl MathpassInspection {
    fn missing() -> Self {
        Self {
            path: None,
            header_present: false,
            original_line_count: 0,
            unique_entry_count: 0,
            duplicate_entry_count: 0,
        }
    }
}

pub fn inspect_mathpass(path: Option<&Path>) -> MathpassInspection {
    let Some(path) = path.filter(|path| path.exists()) else {
        return MathpassInspection::missing();
    };
    let lines = read_lossy_lines(path).unwrap_or_default();
    inspection_for_lines(path, &lines)
}

pub fn write_deduped_mathpass(
    source: &Path,
    destination: &Path,
) -> std::io::Result<MathpassInspection> {
    let lines = read_lossy_lines(source)?;
    let header_present = lines.first().is_some_and(|line| line.starts_with('%'));
    let (header, entries) = if header_present {
        (&lines[..1], &lines[1..])
    } else {
        (&lines[..0], &lines[..])
    };
    let unique = deduplicate(entries);
    let mut output = header
        .iter()
        .map(String::as_str)
        .chain(unique.iter().map(String::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    output.push('\n');
    fs::write(destination, output)?;
    Ok(MathpassInspection {
        path: Some(source.to_string_lossy().into_owned()),
        header_present,
        original_line_count: lines.len(),
        unique_entry_count: unique.len(),
        duplicate_entry_count: entries.len().saturating_sub(unique.len()),
    })
}

#[derive(Debug)]
pub struct DedupedMathpass {
    pub path: Option<PathBuf>,
    pub inspection: MathpassInspection,
    temporary_directory: Option<PathBuf>,
}

impl DedupedMathpass {
    pub fn create(source: Option<&Path>) -> std::io::Result<Self> {
        let inspection = inspect_mathpass(source);
        let Some(source) = source.filter(|path| path.exists()) else {
            return Ok(Self {
                path: None,
                inspection,
                temporary_directory: None,
            });
        };
        let directory = unique_temp_directory("tungsten-mathpass")?;
        let destination = directory.join("mathpass.txt");
        let inspection = write_deduped_mathpass(source, &destination)?;
        Ok(Self {
            path: Some(destination),
            inspection,
            temporary_directory: Some(directory),
        })
    }
}

impl Drop for DedupedMathpass {
    fn drop(&mut self) {
        if let Some(directory) = &self.temporary_directory {
            let _ = fs::remove_dir_all(directory);
        }
    }
}

fn inspection_for_lines(path: &Path, lines: &[String]) -> MathpassInspection {
    let header_present = lines.first().is_some_and(|line| line.starts_with('%'));
    let entries = if header_present { &lines[1..] } else { lines };
    let unique = deduplicate(entries);
    MathpassInspection {
        path: Some(path.to_string_lossy().into_owned()),
        header_present,
        original_line_count: lines.len(),
        unique_entry_count: unique.len(),
        duplicate_entry_count: entries.len().saturating_sub(unique.len()),
    }
}

fn deduplicate(lines: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    lines
        .iter()
        .filter(|line| seen.insert((*line).clone()))
        .cloned()
        .collect()
}

fn read_lossy_lines(path: &Path) -> std::io::Result<Vec<String>> {
    Ok(String::from_utf8_lossy(&fs::read(path)?)
        .lines()
        .map(str::to_owned)
        .collect())
}

pub(crate) fn unique_temp_directory(prefix: &str) -> std::io::Result<PathBuf> {
    let root = std::env::temp_dir();
    for nonce in 0..1000_u32 {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = root.join(format!(
            "{prefix}-{}-{timestamp}-{nonce}",
            std::process::id()
        ));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "could not allocate a unique Tungsten temporary directory",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inspection_and_temporary_deduplication_preserve_header_and_order() {
        let directory = unique_temp_directory("tungsten-license-test").unwrap();
        let source = directory.join("mathpass");
        fs::write(&source, "% header\nalpha\nbeta\nalpha\n\n").unwrap();
        assert_eq!(
            inspect_mathpass(Some(&source)),
            MathpassInspection {
                path: Some(source.to_string_lossy().into_owned()),
                header_present: true,
                original_line_count: 5,
                unique_entry_count: 3,
                duplicate_entry_count: 1,
            }
        );
        let temporary_path;
        {
            let deduped = DedupedMathpass::create(Some(&source)).unwrap();
            temporary_path = deduped.path.clone().unwrap();
            assert_eq!(
                fs::read_to_string(&temporary_path).unwrap(),
                "% header\nalpha\nbeta\n\n"
            );
        }
        assert!(!temporary_path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn absent_mathpass_is_a_valid_noop() {
        assert_eq!(inspect_mathpass(None), MathpassInspection::missing());
        let deduped = DedupedMathpass::create(None).unwrap();
        assert!(deduped.path.is_none());
    }
}
