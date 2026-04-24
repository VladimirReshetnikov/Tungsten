from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from .discovery import WolframInstallation, discover_installation
from .licensing import MathpassInspection, deduped_mathpass
from .notebook import wl_string
from .wolfram_processes import cleanup_stale_tungsten_processes
from .wolfram_processes import read_cached_max_license_processes
from .wolfram_processes import snapshot_wolfram_processes
from .wolfram_processes import tungsten_wolfram_launch_gate
from .wolfram_processes import wait_for_wolfram_license_slot
from .wolfram_processes import write_cached_max_license_processes


def _to_wl_path(path: Path) -> str:
    return wl_string(path.resolve().as_posix())


@dataclass
class KernelEvaluationResult:
    command: list[str]
    exit_code: int
    success: bool | None
    failure_type: str | None
    result: str | None
    result_head: str | None
    messages: list[str]
    messages_text: list[str]
    output: list[str]
    timing: float | None
    absolute_timing: float | None
    stdout: str
    stderr: str
    json_path: str | None
    evaluation_available: bool
    mathpass: MathpassInspection
    used_mathpass_workaround: bool
    license_processes: int | None
    max_license_processes: int | None
    launch_gate_wait_seconds: float
    license_wait_seconds: float
    license_wait_satisfied: bool | None
    cached_max_license_processes: int | None
    cleaned_tungsten_processes: list[int]
    observed_wolfram_processes: list[dict[str, object]]

    def to_dict(self) -> dict[str, object]:
        return {
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
            "mathpass": self.mathpass.to_dict(),
            "used_mathpass_workaround": self.used_mathpass_workaround,
            "license_processes": self.license_processes,
            "max_license_processes": self.max_license_processes,
            "launch_gate_wait_seconds": self.launch_gate_wait_seconds,
            "license_wait_seconds": self.license_wait_seconds,
            "license_wait_satisfied": self.license_wait_satisfied,
            "cached_max_license_processes": self.cached_max_license_processes,
            "cleaned_tungsten_processes": self.cleaned_tungsten_processes,
            "observed_wolfram_processes": self.observed_wolfram_processes,
        }


class WolframKernelRunner:
    def __init__(self, installation: WolframInstallation | None = None) -> None:
        self.installation = installation or discover_installation()

    def probe(self) -> dict[str, object]:
        evaluation = self.evaluate_text("2+2")
        front_end = self.evaluate_text(
            'nb = UsingFrontEnd[CreateDocument[Notebook[{Cell["Tungsten probe", "Text"]}, Visible -> False]]];'
            " head = Head[nb];"
            " UsingFrontEnd[NotebookClose[nb]];"
            " head"
        )
        return {
            "evaluation": evaluation.to_dict(),
            "front_end": front_end.to_dict(),
        }

    def evaluate_text(
        self,
        code: str,
        *,
        working_directory: Path | None = None,
        require_front_end: bool = False,
    ) -> KernelEvaluationResult:
        with TemporaryDirectory(prefix="tungsten-eval-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            code_path = temp_dir / "input.wl"
            result_path = temp_dir / "result.json"
            code_path.write_text(code, encoding="utf-8")
            return self._evaluate_file_internal(
                code_path=code_path,
                result_path=result_path,
                working_directory=working_directory,
                require_front_end=require_front_end,
            )

    def evaluate_file(
        self,
        path: Path,
        *,
        working_directory: Path | None = None,
        require_front_end: bool = False,
    ) -> KernelEvaluationResult:
        with TemporaryDirectory(prefix="tungsten-eval-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            result_path = temp_dir / "result.json"
            return self._evaluate_file_internal(
                code_path=path,
                result_path=result_path,
                working_directory=working_directory,
                require_front_end=require_front_end,
            )

    def _evaluate_file_internal(
        self,
        *,
        code_path: Path,
        result_path: Path,
        working_directory: Path | None,
        require_front_end: bool,
    ) -> KernelEvaluationResult:
        kernel_cli = self.installation.kernel_cli
        mathpass = self.installation.mathpass
        if kernel_cli is None or not kernel_cli.exists():
            return KernelEvaluationResult(
                command=[],
                exit_code=127,
                success=None,
                failure_type="KernelNotFound",
                result=None,
                result_head=None,
                messages=[],
                messages_text=[],
                output=[],
                timing=None,
                absolute_timing=None,
                stdout="",
                stderr="No local wolfram.exe installation was discovered.",
                json_path=None,
                evaluation_available=False,
                mathpass=MathpassInspection(
                    path=str(mathpass) if mathpass else None,
                    header_present=False,
                    original_line_count=0,
                    unique_entry_count=0,
                    duplicate_entry_count=0,
                ),
                used_mathpass_workaround=False,
                license_processes=None,
                max_license_processes=None,
                launch_gate_wait_seconds=0.0,
                license_wait_seconds=0.0,
                license_wait_satisfied=None,
                cached_max_license_processes=read_cached_max_license_processes(),
                cleaned_tungsten_processes=[],
                observed_wolfram_processes=[],
            )

        execution_directory = (working_directory or Path.cwd()).resolve()
        cached_max_license_processes = read_cached_max_license_processes()
        command: list[str] = []
        try:
            with tungsten_wolfram_launch_gate() as launch_gate_wait_seconds:
                cleaned_tungsten_processes = cleanup_stale_tungsten_processes()
                if cleaned_tungsten_processes:
                    time.sleep(0.5)

                _, license_wait_seconds, license_wait_satisfied = wait_for_wolfram_license_slot(
                    cached_max_license_processes,
                    timeout_seconds=15.0,
                )

                with deduped_mathpass(mathpass) as (deduped_path, inspection), TemporaryDirectory(
                    prefix="tungsten-wrapper-"
                ) as wrapper_dir_name:
                    wrapper_dir = Path(wrapper_dir_name)
                    wrapper_path = wrapper_dir / "wrapper.wl"
                    wrapper_path.write_text(
                        self._build_wrapper_script(
                            code_path=code_path.resolve(),
                            result_path=result_path.resolve(),
                            working_directory=execution_directory,
                            require_front_end=require_front_end,
                        ),
                        encoding="utf-8",
                    )

                    command = [str(kernel_cli), "-noprompt"]
                    if deduped_path is not None:
                        command.extend(["-pwfile", str(deduped_path)])
                    command.extend(["-script", str(wrapper_path)])

                    completed = subprocess.run(
                        command,
                        capture_output=True,
                        text=True,
                        encoding="utf-8",
                        errors="replace",
                    )
        except TimeoutError as exc:
            return KernelEvaluationResult(
                command=command,
                exit_code=124,
                success=None,
                failure_type="LaunchGateTimeout",
                result=None,
                result_head=None,
                messages=[],
                messages_text=[],
                output=[],
                timing=None,
                absolute_timing=None,
                stdout="",
                stderr=str(exc),
                json_path=None,
                evaluation_available=False,
                mathpass=MathpassInspection(
                    path=str(mathpass) if mathpass else None,
                    header_present=False,
                    original_line_count=0,
                    unique_entry_count=0,
                    duplicate_entry_count=0,
                ),
                used_mathpass_workaround=False,
                license_processes=None,
                max_license_processes=None,
                launch_gate_wait_seconds=0.0,
                license_wait_seconds=0.0,
                license_wait_satisfied=None,
                cached_max_license_processes=cached_max_license_processes,
                cleaned_tungsten_processes=[],
                observed_wolfram_processes=[process.to_dict() for process in snapshot_wolfram_processes().processes],
            )

        parsed: dict[str, object] | None = None
        if result_path.exists():
            parsed = json.loads(result_path.read_text(encoding="utf-8"))
            max_license_processes = self._as_optional_int(parsed, "max_license_processes")
            if max_license_processes is not None and max_license_processes > 0:
                write_cached_max_license_processes(max_license_processes)
        else:
            max_license_processes = None
        observed_wolfram_processes = [process.to_dict() for process in snapshot_wolfram_processes().processes]

        return KernelEvaluationResult(
            command=command,
            exit_code=completed.returncode,
            success=self._as_bool(parsed, "success"),
            failure_type=self._as_optional_string(parsed, "failure_type"),
            result=self._as_optional_string(parsed, "result"),
            result_head=self._as_optional_string(parsed, "result_head"),
            messages=self._as_string_list(parsed, "messages"),
            messages_text=self._as_string_list(parsed, "messages_text"),
            output=self._as_string_list(parsed, "output"),
            timing=self._as_optional_float(parsed, "timing"),
            absolute_timing=self._as_optional_float(parsed, "absolute_timing"),
            stdout=completed.stdout,
            stderr=completed.stderr,
            json_path=str(result_path) if result_path.exists() else None,
            evaluation_available=result_path.exists(),
            mathpass=inspection,
            used_mathpass_workaround=deduped_path is not None,
            license_processes=self._as_optional_int(parsed, "license_processes"),
            max_license_processes=max_license_processes,
            launch_gate_wait_seconds=launch_gate_wait_seconds,
            license_wait_seconds=license_wait_seconds,
            license_wait_satisfied=license_wait_satisfied,
            cached_max_license_processes=cached_max_license_processes,
            cleaned_tungsten_processes=cleaned_tungsten_processes,
            observed_wolfram_processes=observed_wolfram_processes,
        )

    @staticmethod
    def _as_bool(payload: dict[str, object] | None, key: str) -> bool | None:
        if payload is None or key not in payload:
            return None
        value = payload.get(key)
        if isinstance(value, bool):
            return value
        return None

    @staticmethod
    def _as_optional_string(payload: dict[str, object] | None, key: str) -> str | None:
        if payload is None or key not in payload:
            return None
        value = payload.get(key)
        if value is None:
            return None
        return str(value)

    @staticmethod
    def _as_optional_float(payload: dict[str, object] | None, key: str) -> float | None:
        if payload is None or key not in payload:
            return None
        value = payload.get(key)
        if value is None:
            return None
        if isinstance(value, (int, float)):
            return float(value)
        return None

    @staticmethod
    def _as_optional_int(payload: dict[str, object] | None, key: str) -> int | None:
        if payload is None or key not in payload:
            return None
        value = payload.get(key)
        if isinstance(value, int):
            return value
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return None

    @staticmethod
    def _as_string_list(payload: dict[str, object] | None, key: str) -> list[str]:
        if payload is None or key not in payload:
            return []
        value = payload.get(key)
        if not isinstance(value, list):
            return []
        return [str(item) for item in value]

    @staticmethod
    def _build_wrapper_script(
        *,
        code_path: Path,
        result_path: Path,
        working_directory: Path,
        require_front_end: bool,
    ) -> str:
        require_front_end_literal = "True" if require_front_end else "False"
        return f"""
$HistoryLength = 0;
SetDirectory[{_to_wl_path(working_directory)}];

userCode = Import[{_to_wl_path(code_path)}, "Text"];
output = {{}};

ClearAll[
    Tungsten`Private`CapturedPrint,
    Tungsten`Private`Stringify,
    Tungsten`Private`HeadStringify,
    Tungsten`Private`StringList
];
SetAttributes[Tungsten`Private`CapturedPrint, HoldAll];
Tungsten`Private`CapturedPrint[args___] := AppendTo[
    output,
    ToString[Unevaluated[SequenceForm[args]], OutputForm, PageWidth -> Infinity]
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
        {_to_wl_path(result_path)},
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
    {require_front_end_literal},
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

Export[{_to_wl_path(result_path)}, payload, "RawJSON"];
Exit[0];
""".strip()
