//! Wolfram process inspection, cleanup, and license-slot coordination.

use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
#[cfg(windows)]
use std::fs::OpenOptions;
#[cfg(windows)]
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use thiserror::Error;

const WOLFRAM_PROCESS_NAMES: &[&str] = &[
    "mathkernel",
    "mathkernel.exe",
    "mathematica",
    "mathematica.exe",
    "wolfram",
    "wolfram.exe",
    "wolframdesktop",
    "wolframdesktop.exe",
    "wolframkernel",
    "wolframkernel.exe",
];

#[derive(Debug, Error)]
pub enum ProcessError {
    #[error("Could not find PowerShell for Wolfram process inspection.")]
    PowerShellNotFound,
    #[error("PowerShell process inspection failed: {0}")]
    PowerShell(String),
    #[error("Timed out waiting for the Tungsten Wolfram launch gate.")]
    LaunchGateTimeout,
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, PartialEq)]
pub struct WolframProcessInfo {
    pub pid: u32,
    pub parent_pid: u32,
    pub name: String,
    pub executable_path: Option<String>,
    pub command_line: Option<String>,
    pub started_utc: Option<String>,
    pub tungsten_owned: bool,
    pub headless_batch: bool,
    pub parent_missing: bool,
    pub controlling_process_candidate: bool,
}

impl WolframProcessInfo {
    pub fn age_seconds(&self) -> Option<f64> {
        let started = parse_rfc3339_seconds(self.started_utc.as_deref()?)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs_f64();
        Some((now - started).max(0.0))
    }

    pub fn to_value(&self) -> Value {
        json!({
            "pid": self.pid,
            "parent_pid": self.parent_pid,
            "name": self.name,
            "executable_path": self.executable_path,
            "command_line": self.command_line,
            "started_utc": self.started_utc,
            "tungsten_owned": self.tungsten_owned,
            "headless_batch": self.headless_batch,
            "parent_missing": self.parent_missing,
            "controlling_process_candidate": self.controlling_process_candidate,
            "age_seconds": self.age_seconds(),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WolframProcessSnapshot {
    pub processes: Vec<WolframProcessInfo>,
    pub cached_max_license_processes: Option<u32>,
}

impl WolframProcessSnapshot {
    pub fn active_count(&self) -> usize {
        self.processes
            .iter()
            .filter(|process| process.controlling_process_candidate)
            .count()
    }

    pub fn to_value(&self) -> Value {
        json!({
            "cached_max_license_processes": self.cached_max_license_processes,
            "active_count": self.active_count(),
            "processes": self.processes.iter().map(WolframProcessInfo::to_value).collect::<Vec<_>>(),
        })
    }
}

pub fn cache_root() -> PathBuf {
    std::env::var_os("LOCALAPPDATA").map_or_else(
        || std::env::temp_dir().join("Tungsten"),
        |root| PathBuf::from(root).join("Tungsten"),
    )
}

pub fn read_cached_max_license_processes() -> Option<u32> {
    read_cached_max_license_processes_at(&cache_root())
}

pub fn read_cached_max_license_processes_at(root: &Path) -> Option<u32> {
    let payload: Value =
        serde_json::from_str(&fs::read_to_string(root.join("wolfram-license-cache.json")).ok()?)
            .ok()?;
    payload
        .get("max_license_processes")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .filter(|value| *value > 0)
}

pub fn write_cached_max_license_processes(value: u32) -> std::io::Result<()> {
    write_cached_max_license_processes_at(&cache_root(), value)
}

pub fn write_cached_max_license_processes_at(root: &Path, value: u32) -> std::io::Result<()> {
    if value == 0 {
        return Ok(());
    }
    fs::create_dir_all(root)?;
    let timestamp = format_system_time(SystemTime::now());
    fs::write(
        root.join("wolfram-license-cache.json"),
        serde_json::to_string_pretty(&json!({
            "max_license_processes": value,
            "updated_utc": timestamp,
        }))? + "\n",
    )
}

pub fn utc_now_string() -> String {
    format_system_time(SystemTime::now())
}

pub fn list_wolfram_processes() -> Result<Vec<WolframProcessInfo>, ProcessError> {
    const SCRIPT: &str = r#"
$all = Get-CimInstance Win32_Process | Select-Object `
    Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine,
    @{ Name = "StartedUtc"; Expression = {
        if ($_.CreationDate) {
            [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate).ToUniversalTime().ToString("o")
        }
        else {
            $null
        }
    }}
$all | ConvertTo-Json -Compress -Depth 3
"#;
    let powershell = powershell_executable()?;
    let output = Command::new(powershell)
        .args(["-NoLogo", "-NoProfile", "-Command", SCRIPT])
        .output()?;
    if !output.status.success() {
        let error = if output.stderr.is_empty() {
            String::from_utf8_lossy(&output.stdout)
        } else {
            String::from_utf8_lossy(&output.stderr)
        };
        return Err(ProcessError::PowerShell(error.into_owned()));
    }
    let raw = String::from_utf8_lossy(&output.stdout);
    let payload = if raw.trim().is_empty() {
        Value::Array(Vec::new())
    } else {
        serde_json::from_str(raw.trim())?
    };
    Ok(normalize_process_payload(&payload))
}

pub fn normalize_process_payload(payload: &Value) -> Vec<WolframProcessInfo> {
    let rows = match payload {
        Value::Array(rows) => rows.iter().filter_map(Value::as_object).collect::<Vec<_>>(),
        Value::Object(row) => vec![row],
        _ => Vec::new(),
    };
    let live_pids = rows
        .iter()
        .filter_map(|row| row.get("ProcessId").and_then(Value::as_u64))
        .filter_map(|value| u32::try_from(value).ok())
        .collect::<HashSet<_>>();
    let mut processes = Vec::new();
    for row in rows {
        let name = string_value(row.get("Name"));
        let executable_path = optional_string(row.get("ExecutablePath"));
        if !is_wolfram_process(name.as_deref(), executable_path.as_deref()) {
            continue;
        }
        let name = name.unwrap_or_else(|| "None".to_owned());
        let command_line = optional_string(row.get("CommandLine"));
        let lower_command = command_line.as_deref().unwrap_or_default().to_lowercase();
        let tungsten_owned = ["tungsten-wrapper-", "tungsten-mathpass-"]
            .iter()
            .any(|marker| lower_command.contains(marker));
        let headless_batch = [" -script ", " -run ", " -runfile "]
            .iter()
            .any(|marker| lower_command.contains(marker));
        let pid = integer_value(row.get("ProcessId"));
        let parent_pid = integer_value(row.get("ParentProcessId"));
        processes.push(WolframProcessInfo {
            pid,
            parent_pid,
            controlling_process_candidate: is_controlling_process_candidate(&name, &lower_command),
            name,
            executable_path,
            command_line,
            started_utc: optional_string(row.get("StartedUtc")),
            tungsten_owned,
            headless_batch,
            parent_missing: parent_pid > 0 && !live_pids.contains(&parent_pid),
        });
    }
    processes.sort_by_key(|process| process.pid);
    processes
}

pub fn snapshot_wolfram_processes() -> Result<WolframProcessSnapshot, ProcessError> {
    Ok(WolframProcessSnapshot {
        processes: list_wolfram_processes()?,
        cached_max_license_processes: read_cached_max_license_processes(),
    })
}

pub fn cleanup_stale_tungsten_processes(min_age_seconds: f64) -> Result<Vec<u32>, ProcessError> {
    let processes = list_wolfram_processes()?;
    Ok(cleanup_stale_processes_with(
        &processes,
        min_age_seconds,
        |pid| {
            Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .output()
                .is_ok_and(|output| output.status.success())
        },
    ))
}

pub fn cleanup_stale_processes_with(
    processes: &[WolframProcessInfo],
    min_age_seconds: f64,
    mut kill: impl FnMut(u32) -> bool,
) -> Vec<u32> {
    let mut cleaned = Vec::new();
    for process in processes {
        if !process.tungsten_owned || !process.headless_batch || !process.parent_missing {
            continue;
        }
        if process
            .age_seconds()
            .is_some_and(|age| age < min_age_seconds)
        {
            continue;
        }
        if kill(process.pid) {
            cleaned.push(process.pid);
        }
    }
    cleaned
}

#[derive(Debug)]
pub struct WolframLaunchGate {
    waited: Duration,
    lock_path: Option<PathBuf>,
}

impl WolframLaunchGate {
    pub fn acquire(timeout: Duration, poll: Duration) -> Result<Self, ProcessError> {
        #[cfg(not(windows))]
        {
            let _ = (timeout, poll);
            return Ok(Self {
                waited: Duration::ZERO,
                lock_path: None,
            });
        }
        #[cfg(windows)]
        {
            let lock_path = cache_root().join("wolfram-launch.lock");
            if let Some(parent) = lock_path.parent() {
                fs::create_dir_all(parent)?;
            }
            let start = Instant::now();
            loop {
                match OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&lock_path)
                {
                    Ok(mut file) => {
                        writeln!(file, "{}", std::process::id())?;
                        return Ok(Self {
                            waited: start.elapsed(),
                            lock_path: Some(lock_path),
                        });
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                        if start.elapsed() >= timeout {
                            return Err(ProcessError::LaunchGateTimeout);
                        }
                        thread::sleep(poll);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }
    }

    pub fn waited_seconds(&self) -> f64 {
        self.waited.as_secs_f64()
    }
}

impl Drop for WolframLaunchGate {
    fn drop(&mut self) {
        if let Some(path) = &self.lock_path {
            let _ = fs::remove_file(path);
        }
    }
}

pub fn wait_for_wolfram_license_slot(
    cached_max_license_processes: Option<u32>,
    timeout: Duration,
    poll: Duration,
) -> Result<(WolframProcessSnapshot, f64, bool), ProcessError> {
    wait_for_license_slot_with(cached_max_license_processes, timeout, poll, || {
        snapshot_wolfram_processes()
    })
}

pub fn wait_for_license_slot_with(
    cached_max_license_processes: Option<u32>,
    timeout: Duration,
    poll: Duration,
    mut snapshot: impl FnMut() -> Result<WolframProcessSnapshot, ProcessError>,
) -> Result<(WolframProcessSnapshot, f64, bool), ProcessError> {
    let start = Instant::now();
    let mut current = snapshot()?;
    let Some(limit) = cached_max_license_processes else {
        return Ok((current, 0.0, true));
    };
    if current.active_count() < limit as usize {
        return Ok((current, 0.0, true));
    }
    loop {
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            return Ok((current, elapsed.as_secs_f64(), false));
        }
        thread::sleep(poll);
        current = snapshot()?;
        if current.active_count() < limit as usize {
            return Ok((current, start.elapsed().as_secs_f64(), true));
        }
    }
}

fn powershell_executable() -> Result<&'static str, ProcessError> {
    for candidate in ["pwsh", "powershell"] {
        if Command::new(candidate)
            .args([
                "-NoLogo",
                "-NoProfile",
                "-Command",
                "$PSVersionTable.PSVersion.ToString()",
            ])
            .output()
            .is_ok_and(|output| output.status.success())
        {
            return Ok(candidate);
        }
    }
    Err(ProcessError::PowerShellNotFound)
}

fn is_wolfram_process(name: Option<&str>, executable_path: Option<&str>) -> bool {
    name.is_some_and(|name| {
        WOLFRAM_PROCESS_NAMES
            .iter()
            .any(|candidate| name.eq_ignore_ascii_case(candidate))
    }) || executable_path.is_some_and(|path| path.to_lowercase().contains("wolfram"))
}

fn is_controlling_process_candidate(name: &str, lower_command: &str) -> bool {
    let name = name.to_lowercase();
    if matches!(
        name.as_str(),
        "mathematica" | "mathematica.exe" | "wolframdesktop" | "wolframdesktop.exe"
    ) {
        return true;
    }
    if matches!(
        name.as_str(),
        "wolfram"
            | "wolfram.exe"
            | "wolframkernel"
            | "wolframkernel.exe"
            | "mathkernel"
            | "mathkernel.exe"
    ) {
        return ![" -mathlink ", " -subkernel ", "playerpass"]
            .iter()
            .any(|marker| lower_command.contains(marker));
    }
    false
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value.and_then(|value| match value {
        Value::Null => None,
        Value::String(value) => Some(value.clone()),
        other => Some(match other {
            Value::Bool(value) => value.to_string(),
            Value::Number(value) => value.to_string(),
            _ => other.to_string(),
        }),
    })
}

fn string_value(value: Option<&Value>) -> Option<String> {
    optional_string(value)
}

fn integer_value(value: Option<&Value>) -> u32 {
    value
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .unwrap_or(0)
}

fn parse_rfc3339_seconds(value: &str) -> Option<f64> {
    if value.len() < 20 || value.as_bytes().get(10) != Some(&b'T') {
        return None;
    }
    let year = value.get(0..4)?.parse::<i64>().ok()?;
    let month = value.get(5..7)?.parse::<i64>().ok()?;
    let day = value.get(8..10)?.parse::<i64>().ok()?;
    let hour = value.get(11..13)?.parse::<i64>().ok()?;
    let minute = value.get(14..16)?.parse::<i64>().ok()?;
    let second = value.get(17..19)?.parse::<i64>().ok()?;
    let mut cursor = 19;
    let mut fraction = 0.0;
    if value.as_bytes().get(cursor) == Some(&b'.') {
        cursor += 1;
        let start = cursor;
        while value.as_bytes().get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        let digits = value.get(start..cursor)?;
        if !digits.is_empty() {
            fraction = format!("0.{digits}").parse().ok()?;
        }
    }
    let offset = match value.as_bytes().get(cursor).copied()? {
        b'Z' => 0,
        sign @ (b'+' | b'-') => {
            let offset_hours = value.get(cursor + 1..cursor + 3)?.parse::<i64>().ok()?;
            let offset_minutes = value.get(cursor + 4..cursor + 6)?.parse::<i64>().ok()?;
            let seconds = offset_hours * 3600 + offset_minutes * 60;
            if sign == b'+' { seconds } else { -seconds }
        }
        _ => return None,
    };
    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3600 + minute * 60 + second - offset) as f64 + fraction)
}

fn format_system_time(value: SystemTime) -> String {
    let seconds = value
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let daytime = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = daytime / 3600;
    let minute = (daytime % 3600) / 60;
    let second = daytime % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

fn days_from_civil(mut year: i64, month: i64, day: i64) -> i64 {
    year -= i64::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::licensing::unique_temp_directory;

    fn process(pid: u32, controlling: bool) -> WolframProcessInfo {
        WolframProcessInfo {
            pid,
            parent_pid: 0,
            name: "wolfram.exe".into(),
            executable_path: None,
            command_line: None,
            started_utc: None,
            tungsten_owned: false,
            headless_batch: true,
            parent_missing: false,
            controlling_process_candidate: controlling,
        }
    }

    #[test]
    fn license_cache_round_trips_and_rejects_nonpositive_values() {
        let root = unique_temp_directory("tungsten-process-cache").unwrap();
        assert_eq!(read_cached_max_license_processes_at(&root), None);
        write_cached_max_license_processes_at(&root, 2).unwrap();
        assert_eq!(read_cached_max_license_processes_at(&root), Some(2));
        write_cached_max_license_processes_at(&root, 0).unwrap();
        assert_eq!(read_cached_max_license_processes_at(&root), Some(2));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn process_payload_classifies_controllers_helpers_and_orphans() {
        let payload = json!([
            {"Name":"Mathematica.exe","ProcessId":1,"ParentProcessId":0,"ExecutablePath":null,"CommandLine":null,"StartedUtc":null},
            {"Name":"WolframKernel.exe","ProcessId":2,"ParentProcessId":1,"ExecutablePath":null,"CommandLine":"WolframKernel.exe -mathlink helper","StartedUtc":null},
            {"Name":"wolfram.exe","ProcessId":3,"ParentProcessId":99,"ExecutablePath":null,"CommandLine":"wolfram.exe -script C:\\Temp\\tungsten-wrapper-abc\\wrapper.wl","StartedUtc":"2026-04-24T18:00:00Z"},
            {"Name":"other.exe","ProcessId":4,"ParentProcessId":0,"ExecutablePath":null,"CommandLine":null,"StartedUtc":null}
        ]);
        let processes = normalize_process_payload(&payload);
        assert_eq!(processes.len(), 3);
        assert!(processes[0].controlling_process_candidate);
        assert!(!processes[1].controlling_process_candidate);
        assert!(processes[2].tungsten_owned);
        assert!(processes[2].headless_batch);
        assert!(processes[2].parent_missing);
        assert!(processes[2].age_seconds().is_some());
    }

    #[test]
    fn cleanup_only_kills_stale_owned_headless_orphans() {
        let mut stale = process(111, true);
        stale.tungsten_owned = true;
        stale.parent_missing = true;
        stale.started_utc = Some("2026-04-24T18:00:00Z".into());
        let mut foreign = stale.clone();
        foreign.pid = 222;
        foreign.tungsten_owned = false;
        let mut attached = stale.clone();
        attached.pid = 333;
        attached.parent_missing = false;
        let mut attempted = Vec::new();
        let cleaned = cleanup_stale_processes_with(&[stale, foreign, attached], 0.0, |pid| {
            attempted.push(pid);
            true
        });
        assert_eq!(cleaned, [111]);
        assert_eq!(attempted, [111]);
    }

    #[test]
    fn license_wait_polls_until_controller_count_drops() {
        let blocked = WolframProcessSnapshot {
            processes: vec![process(1, true), process(2, true)],
            cached_max_license_processes: Some(2),
        };
        let free = WolframProcessSnapshot {
            processes: vec![process(1, true), process(2, false)],
            cached_max_license_processes: Some(2),
        };
        let mut snapshots = [blocked, free].into_iter();
        let (snapshot, waited, satisfied) =
            wait_for_license_slot_with(Some(2), Duration::from_secs(5), Duration::ZERO, || {
                Ok(snapshots.next().unwrap())
            })
            .unwrap();
        assert!(satisfied);
        assert_eq!(snapshot.active_count(), 1);
        assert!(waited >= 0.0);
    }

    #[test]
    fn rfc3339_conversion_handles_epoch_and_offset() {
        assert_eq!(parse_rfc3339_seconds("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(
            parse_rfc3339_seconds("1970-01-01T01:00:00+01:00"),
            Some(0.0)
        );
        assert_eq!(format_system_time(UNIX_EPOCH), "1970-01-01T00:00:00Z");
    }
}
