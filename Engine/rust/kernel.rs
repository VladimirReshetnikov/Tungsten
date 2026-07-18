//! Structured execution through a discovered local Wolfram kernel.

use crate::discovery::{WolframInstallation, discover_installation};
use crate::licensing::{
    DedupedMathpass, MathpassInspection, inspect_mathpass, unique_temp_directory,
};
use crate::wolfram_processes::{
    ProcessError, WolframLaunchGate, cleanup_stale_tungsten_processes,
    read_cached_max_license_processes, snapshot_wolfram_processes, wait_for_wolfram_license_slot,
    write_cached_max_license_processes,
};
use crate::wolfram_strings::wl_string;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum KernelError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Process(#[from] ProcessError),
}

#[derive(Clone, Debug, PartialEq)]
pub struct KernelEvaluationResult {
    pub command: Vec<String>,
    pub exit_code: i32,
    pub success: Option<bool>,
    pub failure_type: Option<String>,
    pub result: Option<String>,
    pub result_head: Option<String>,
    pub messages: Vec<String>,
    pub messages_text: Vec<String>,
    pub output: Vec<String>,
    pub timing: Option<f64>,
    pub absolute_timing: Option<f64>,
    pub stdout: String,
    pub stderr: String,
    pub json_path: Option<String>,
    pub evaluation_available: bool,
    pub mathpass: MathpassInspection,
    pub used_mathpass_workaround: bool,
    pub license_processes: Option<i64>,
    pub max_license_processes: Option<i64>,
    pub launch_gate_wait_seconds: f64,
    pub license_wait_seconds: f64,
    pub license_wait_satisfied: Option<bool>,
    pub cached_max_license_processes: Option<u32>,
    pub cleaned_tungsten_processes: Vec<u32>,
    pub observed_wolfram_processes: Vec<Value>,
}

impl KernelEvaluationResult {
    pub fn to_value(&self) -> Value {
        json!({
            "command": self.command,
            "exit_code": self.exit_code,
            "success": self.success,
            "failure_type": self.failure_type,
            "result": self.result,
            "result_head": self.result_head,
            "messages": self.messages,
            "messages_text": self.messages_text,
            "output": self.output,
            "timing": self.timing,
            "absolute_timing": self.absolute_timing,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "json_path": self.json_path,
            "evaluation_available": self.evaluation_available,
            "mathpass": self.mathpass,
            "used_mathpass_workaround": self.used_mathpass_workaround,
            "license_processes": self.license_processes,
            "max_license_processes": self.max_license_processes,
            "launch_gate_wait_seconds": self.launch_gate_wait_seconds,
            "license_wait_seconds": self.license_wait_seconds,
            "license_wait_satisfied": self.license_wait_satisfied,
            "cached_max_license_processes": self.cached_max_license_processes,
            "cleaned_tungsten_processes": self.cleaned_tungsten_processes,
            "observed_wolfram_processes": self.observed_wolfram_processes,
        })
    }
}

#[derive(Clone, Debug)]
pub struct WolframKernelRunner {
    pub installation: WolframInstallation,
}

impl Default for WolframKernelRunner {
    fn default() -> Self {
        Self::new(discover_installation())
    }
}

impl WolframKernelRunner {
    pub const fn new(installation: WolframInstallation) -> Self {
        Self { installation }
    }

    pub fn probe(&self) -> Result<Value, KernelError> {
        let evaluation = self.evaluate_text("2+2", None, false)?;
        let front_end = self.evaluate_text(
            "nb = UsingFrontEnd[CreateDocument[Notebook[{Cell[\"Tungsten probe\", \"Text\"]}, Visible -> False]]]; head = Head[nb]; UsingFrontEnd[NotebookClose[nb]]; head",
            None,
            false,
        )?;
        Ok(json!({
            "evaluation": evaluation.to_value(),
            "front_end": front_end.to_value(),
        }))
    }

    pub fn evaluate_text(
        &self,
        code: &str,
        working_directory: Option<&Path>,
        require_front_end: bool,
    ) -> Result<KernelEvaluationResult, KernelError> {
        let directory = TemporaryDirectory::new("tungsten-eval")?;
        let code_path = directory.path().join("input.wl");
        let result_path = directory.path().join("result.json");
        fs::write(&code_path, code)?;
        self.evaluate_file_internal(
            &code_path,
            &result_path,
            working_directory,
            require_front_end,
        )
    }

    pub fn evaluate_file(
        &self,
        path: &Path,
        working_directory: Option<&Path>,
        require_front_end: bool,
    ) -> Result<KernelEvaluationResult, KernelError> {
        let directory = TemporaryDirectory::new("tungsten-eval")?;
        let result_path = directory.path().join("result.json");
        self.evaluate_file_internal(path, &result_path, working_directory, require_front_end)
    }

    fn evaluate_file_internal(
        &self,
        code_path: &Path,
        result_path: &Path,
        working_directory: Option<&Path>,
        require_front_end: bool,
    ) -> Result<KernelEvaluationResult, KernelError> {
        let mathpass = self.installation.mathpass.as_deref();
        let Some(kernel_cli) = self
            .installation
            .kernel_cli
            .as_deref()
            .filter(|path| path.exists())
        else {
            return Ok(self.kernel_not_found_result(mathpass));
        };
        let execution_directory =
            absolute_path(working_directory.unwrap_or_else(|| Path::new(".")));
        let cached_max_license_processes = read_cached_max_license_processes();
        let mut command = Vec::new();
        let gate = match WolframLaunchGate::acquire(
            Duration::from_secs(900),
            Duration::from_millis(200),
        ) {
            Ok(gate) => gate,
            Err(ProcessError::LaunchGateTimeout) => {
                return Ok(self.launch_timeout_result(
                    "Timed out waiting for the Tungsten Wolfram launch gate.",
                    cached_max_license_processes,
                ));
            }
            Err(error) => return Err(error.into()),
        };
        let launch_gate_wait_seconds = gate.waited_seconds();
        let cleaned_tungsten_processes = cleanup_stale_tungsten_processes(30.0)?;
        if !cleaned_tungsten_processes.is_empty() {
            thread::sleep(Duration::from_millis(500));
        }
        let (_, license_wait_seconds, license_wait_satisfied) = wait_for_wolfram_license_slot(
            cached_max_license_processes,
            Duration::from_secs(15),
            Duration::from_millis(500),
        )?;
        let deduped = DedupedMathpass::create(mathpass)?;
        let wrapper_directory = TemporaryDirectory::new("tungsten-wrapper")?;
        let wrapper_path = wrapper_directory.path().join("wrapper.wl");
        fs::write(
            &wrapper_path,
            build_wrapper_script(
                &absolute_path(code_path),
                &absolute_path(result_path),
                &execution_directory,
                require_front_end,
            ),
        )?;
        command.push(kernel_cli.to_string_lossy().into_owned());
        command.push("-noprompt".into());
        if let Some(path) = &deduped.path {
            command.push("-pwfile".into());
            command.push(path.to_string_lossy().into_owned());
        }
        command.push("-script".into());
        command.push(wrapper_path.to_string_lossy().into_owned());
        let completed = Command::new(kernel_cli)
            .args(command.iter().skip(1))
            .output()?;
        drop(gate);

        let parsed = if result_path.exists() {
            Some(serde_json::from_str::<Value>(&fs::read_to_string(
                result_path,
            )?)?)
        } else {
            None
        };
        let max_license_processes = optional_int(parsed.as_ref(), "max_license_processes");
        if let Some(value) = max_license_processes.and_then(|value| u32::try_from(value).ok())
            && value > 0
        {
            write_cached_max_license_processes(value)?;
        }
        let observed_wolfram_processes = snapshot_wolfram_processes()?
            .processes
            .iter()
            .map(crate::wolfram_processes::WolframProcessInfo::to_value)
            .collect();
        Ok(KernelEvaluationResult {
            command,
            exit_code: completed.status.code().unwrap_or(-1),
            success: optional_bool(parsed.as_ref(), "success"),
            failure_type: optional_string(parsed.as_ref(), "failure_type"),
            result: optional_string(parsed.as_ref(), "result"),
            result_head: optional_string(parsed.as_ref(), "result_head"),
            messages: string_list(parsed.as_ref(), "messages"),
            messages_text: string_list(parsed.as_ref(), "messages_text"),
            output: string_list(parsed.as_ref(), "output"),
            timing: optional_float(parsed.as_ref(), "timing"),
            absolute_timing: optional_float(parsed.as_ref(), "absolute_timing"),
            stdout: String::from_utf8_lossy(&completed.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&completed.stderr).into_owned(),
            json_path: result_path
                .exists()
                .then(|| result_path.to_string_lossy().into_owned()),
            evaluation_available: result_path.exists(),
            mathpass: deduped.inspection.clone(),
            used_mathpass_workaround: deduped.path.is_some(),
            license_processes: optional_int(parsed.as_ref(), "license_processes"),
            max_license_processes,
            launch_gate_wait_seconds,
            license_wait_seconds,
            license_wait_satisfied: Some(license_wait_satisfied),
            cached_max_license_processes,
            cleaned_tungsten_processes,
            observed_wolfram_processes,
        })
    }

    fn kernel_not_found_result(&self, mathpass: Option<&Path>) -> KernelEvaluationResult {
        KernelEvaluationResult {
            command: Vec::new(),
            exit_code: 127,
            success: None,
            failure_type: Some("KernelNotFound".into()),
            result: None,
            result_head: None,
            messages: Vec::new(),
            messages_text: Vec::new(),
            output: Vec::new(),
            timing: None,
            absolute_timing: None,
            stdout: String::new(),
            stderr: "No local wolfram.exe installation was discovered.".into(),
            json_path: None,
            evaluation_available: false,
            mathpass: inspect_mathpass(mathpass),
            used_mathpass_workaround: false,
            license_processes: None,
            max_license_processes: None,
            launch_gate_wait_seconds: 0.0,
            license_wait_seconds: 0.0,
            license_wait_satisfied: None,
            cached_max_license_processes: read_cached_max_license_processes(),
            cleaned_tungsten_processes: Vec::new(),
            observed_wolfram_processes: Vec::new(),
        }
    }

    fn launch_timeout_result(
        &self,
        error: &str,
        cached_max_license_processes: Option<u32>,
    ) -> KernelEvaluationResult {
        let observed_wolfram_processes = snapshot_wolfram_processes()
            .map(|snapshot| {
                snapshot
                    .processes
                    .iter()
                    .map(crate::wolfram_processes::WolframProcessInfo::to_value)
                    .collect()
            })
            .unwrap_or_default();
        KernelEvaluationResult {
            command: Vec::new(),
            exit_code: 124,
            success: None,
            failure_type: Some("LaunchGateTimeout".into()),
            result: None,
            result_head: None,
            messages: Vec::new(),
            messages_text: Vec::new(),
            output: Vec::new(),
            timing: None,
            absolute_timing: None,
            stdout: String::new(),
            stderr: error.into(),
            json_path: None,
            evaluation_available: false,
            mathpass: inspect_mathpass(self.installation.mathpass.as_deref()),
            used_mathpass_workaround: false,
            license_processes: None,
            max_license_processes: None,
            launch_gate_wait_seconds: 0.0,
            license_wait_seconds: 0.0,
            license_wait_satisfied: None,
            cached_max_license_processes,
            cleaned_tungsten_processes: Vec::new(),
            observed_wolfram_processes,
        }
    }
}

pub fn build_wrapper_script(
    code_path: &Path,
    result_path: &Path,
    working_directory: &Path,
    require_front_end: bool,
) -> String {
    let require_front_end = if require_front_end { "True" } else { "False" };
    format!(
        r#"$HistoryLength = 0;
SetDirectory[{}];

userCode = Import[{}, "Text"];
output = {{}};

ClearAll[
    Tungsten`Private`CapturedPrint,
    Tungsten`Private`Stringify,
    Tungsten`Private`HeadStringify,
    Tungsten`Private`StringList
];
(* Stock Print is NOT HoldAll - its args evaluate before display. The capture
   shim must match that contract: callers writing Print[Prime[10]] expect "29"
   in the output buffer, not the string "Prime[10]". *)
Tungsten`Private`CapturedPrint[args___] := AppendTo[
    output,
    ToString[SequenceForm[args], OutputForm, PageWidth -> Infinity]
];
Tungsten`Private`Stringify[value_] := Quiet @ Check[
    ToString[Unevaluated[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
Tungsten`Private`HeadStringify[value_] := Quiet @ Check[
    ToString[Head[value], InputForm, PageWidth -> Infinity],
    "$Failed"
];
Tungsten`Private`StringList[value_] := If[
    ListQ[value],
    Map[Tungsten`Private`Stringify, value],
    {{}}
];

heldExpr = Quiet @ Check[ToExpression[userCode, InputForm, HoldComplete], $Failed];
If[
    heldExpr === $Failed,
    Export[
        {},
        <|
            "success" -> False,
            "failure_type" -> "ParseFailure",
            "result" -> "$Failed",
            "result_head" -> "$Failed",
            "messages" -> {{}},
            "messages_text" -> {{}},
            "output" -> output,
            "timing" -> Null,
            "absolute_timing" -> Null
        |>,
        "RawJSON"
    ];
    Exit[2];
];
heldExpr = Replace[
    heldExpr,
    HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]
];

evalExpr = If[
    {require_front_end},
    HoldComplete[UsingFrontEnd[ReleaseHold[heldExpr]]],
    heldExpr
];

ed = Block[
    {{Print = Tungsten`Private`CapturedPrint}},
    EvaluationData[ReleaseHold[evalExpr]]
];

result = Lookup[ed, "Result", $Failed];
payload = <|
    "success" -> TrueQ[Lookup[ed, "Success", False]],
    "failure_type" -> Replace[
        Lookup[ed, "FailureType", None],
        {{
            None -> Null,
            value_ :> Tungsten`Private`Stringify[value]
        }}
    ],
    "result" -> Tungsten`Private`Stringify[result],
    "result_head" -> Tungsten`Private`HeadStringify[result],
    "license_processes" -> Quiet @ Check[$LicenseProcesses, Null],
    "max_license_processes" -> Quiet @ Check[$MaxLicenseProcesses, Null],
    "messages" -> Tungsten`Private`StringList[Lookup[ed, "Messages", {{}}]],
    "messages_text" -> Tungsten`Private`StringList[Lookup[ed, "MessagesText", {{}}]],
    "output" -> output,
    "timing" -> Replace[Lookup[ed, "Timing", Missing["NotAvailable"]], Missing[__] -> Null],
    "absolute_timing" -> Replace[
        Lookup[ed, "AbsoluteTiming", Missing["NotAvailable"]],
        Missing[__] -> Null
    ]
|>;

Export[{}, payload, "RawJSON"];
Exit[0];"#,
        to_wl_path(working_directory),
        to_wl_path(code_path),
        to_wl_path(result_path),
        to_wl_path(result_path),
    )
}

fn optional_bool(payload: Option<&Value>, key: &str) -> Option<bool> {
    payload?.get(key)?.as_bool()
}

fn optional_string(payload: Option<&Value>, key: &str) -> Option<String> {
    let value = payload?.get(key)?;
    match value {
        Value::Null => None,
        Value::String(value) => Some(value.clone()),
        other => Some(match other {
            Value::Bool(value) => value.to_string(),
            Value::Number(value) => value.to_string(),
            _ => other.to_string(),
        }),
    }
}

fn optional_float(payload: Option<&Value>, key: &str) -> Option<f64> {
    payload?.get(key)?.as_f64()
}

fn optional_int(payload: Option<&Value>, key: &str) -> Option<i64> {
    let value = payload?.get(key)?;
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|value| value.fract() == 0.0)
            .map(|value| value as i64)
    })
}

fn string_list(payload: Option<&Value>, key: &str) -> Vec<String> {
    payload
        .and_then(|payload| payload.get(key))
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .map(|value| match value {
                    Value::String(value) => value.clone(),
                    Value::Null => "None".into(),
                    other => other.to_string(),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn to_wl_path(path: &Path) -> String {
    let mut path = absolute_path(path).to_string_lossy().into_owned();
    if let Some(stripped) = path.strip_prefix(r"\\?\") {
        path = stripped.to_owned();
    }
    wl_string(&path.replace('\\', "/"))
}

fn absolute_path(path: &Path) -> PathBuf {
    if let Ok(canonical) = path.canonicalize() {
        return canonical;
    }
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(prefix: &str) -> std::io::Result<Self> {
        unique_temp_directory(prefix).map(Self)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn missing_installation(root: &Path) -> WolframInstallation {
        WolframInstallation {
            install_dir: None,
            kernel_cli: None,
            kernel_executable: None,
            frontend_executable: None,
            wolframscript: None,
            mathpass: None,
            docs_roots: Vec::new(),
            bundled_python_client: None,
            default_index_path: root.join("docs.sqlite"),
            product: "unknown".into(),
            product_family: "unknown".into(),
            version: None,
            user_base: None,
            system_base: None,
            mathpass_candidates: Vec::new(),
            available_installations: Vec::new(),
            selection_reason: None,
        }
    }

    #[test]
    fn missing_kernel_returns_complete_structured_result() {
        let root = unique_temp_directory("tungsten-kernel-test").unwrap();
        let result = WolframKernelRunner::new(missing_installation(&root))
            .evaluate_text("2+2", None, false)
            .unwrap();
        assert_eq!(result.exit_code, 127);
        assert_eq!(result.failure_type.as_deref(), Some("KernelNotFound"));
        assert!(!result.evaluation_available);
        assert_eq!(result.to_value()["mathpass"]["original_line_count"], 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn wrapper_matches_structured_evaluation_contract() {
        let root = Path::new("/tmp/tungsten test");
        let wrapper = build_wrapper_script(
            &root.join("input.wl"),
            &root.join("result.json"),
            root,
            true,
        );
        assert!(wrapper.contains("SetDirectory[\"/tmp/tungsten test\"]"));
        assert!(wrapper.contains("HoldComplete[UsingFrontEnd[ReleaseHold[heldExpr]]]"));
        assert!(wrapper.contains("EvaluationData[ReleaseHold[evalExpr]]"));
        assert!(wrapper.contains("\"max_license_processes\""));
        assert!(wrapper.contains("Export[\"/tmp/tungsten test/result.json\""));
    }
}
