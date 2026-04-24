from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

try:
    import msvcrt
except ImportError:  # pragma: no cover - non-Windows fallback
    msvcrt = None  # type: ignore[assignment]


_WOLFRAM_PROCESS_NAMES = {
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
}


@dataclass(frozen=True)
class WolframProcessInfo:
    pid: int
    parent_pid: int
    name: str
    executable_path: str | None
    command_line: str | None
    started_utc: str | None
    tungsten_owned: bool
    headless_batch: bool
    parent_missing: bool
    controlling_process_candidate: bool

    @property
    def age_seconds(self) -> float | None:
        if self.started_utc is None:
            return None
        try:
            started = datetime.fromisoformat(self.started_utc.replace("Z", "+00:00"))
        except ValueError:
            return None
        return max(0.0, (datetime.now(timezone.utc) - started).total_seconds())

    def to_dict(self) -> dict[str, object]:
        return {
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
            "age_seconds": self.age_seconds,
        }


@dataclass(frozen=True)
class WolframProcessSnapshot:
    processes: tuple[WolframProcessInfo, ...]
    cached_max_license_processes: int | None

    @property
    def active_count(self) -> int:
        return sum(1 for process in self.processes if process.controlling_process_candidate)

    def to_dict(self) -> dict[str, object]:
        return {
            "cached_max_license_processes": self.cached_max_license_processes,
            "active_count": self.active_count,
            "processes": [process.to_dict() for process in self.processes],
        }


def _cache_root() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "Tungsten"
    return Path(tempfile.gettempdir()) / "Tungsten"


def _cache_path() -> Path:
    return _cache_root() / "wolfram-license-cache.json"


def read_cached_max_license_processes() -> int | None:
    path = _cache_path()
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    value = payload.get("max_license_processes")
    if isinstance(value, int) and value > 0:
        return value
    return None


def write_cached_max_license_processes(value: int) -> None:
    if value <= 0:
        return
    path = _cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "max_license_processes": value,
        "updated_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _powershell_executable() -> str:
    for candidate in ("pwsh", "powershell"):
        try:
            completed = subprocess.run(
                [candidate, "-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if completed.returncode == 0:
            return candidate
    raise RuntimeError("Could not find PowerShell for Wolfram process inspection.")


def _normalize_process_payload(payload: object) -> list[dict[str, object]]:
    if payload is None:
        return []
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        return [payload]
    return []


def _is_wolfram_process(name: str | None, executable_path: str | None) -> bool:
    if name and name.lower() in _WOLFRAM_PROCESS_NAMES:
        return True
    if executable_path and "wolfram" in executable_path.lower():
        return True
    return False


def _is_controlling_process_candidate(name: str, lower_command: str) -> bool:
    normalized = name.lower()
    if normalized in {"mathematica", "mathematica.exe", "wolframdesktop", "wolframdesktop.exe"}:
        return True
    if normalized in {"wolfram", "wolfram.exe"}:
        return not any(marker in lower_command for marker in (" -mathlink ", " -subkernel ", "playerpass"))
    if normalized in {"wolframkernel", "wolframkernel.exe", "mathkernel", "mathkernel.exe"}:
        return not any(marker in lower_command for marker in (" -mathlink ", " -subkernel ", "playerpass"))
    return False


def list_wolfram_processes() -> list[WolframProcessInfo]:
    script = r"""
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
"""
    completed = subprocess.run(
        [_powershell_executable(), "-NoLogo", "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=15,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"PowerShell process inspection failed: {completed.stderr or completed.stdout}")

    raw = completed.stdout.strip()
    payload = json.loads(raw) if raw else []
    rows = _normalize_process_payload(payload)
    live_pids = {
        int(row["ProcessId"])
        for row in rows
        if isinstance(row.get("ProcessId"), int)
    }

    processes: list[WolframProcessInfo] = []
    for row in rows:
        name = row.get("Name")
        executable_path = row.get("ExecutablePath")
        if not _is_wolfram_process(str(name) if name is not None else None, str(executable_path) if executable_path is not None else None):
            continue

        command_line = str(row["CommandLine"]) if row.get("CommandLine") is not None else None
        lower_command = (command_line or "").lower()
        tungsten_owned = any(marker in lower_command for marker in ("tungsten-wrapper-", "tungsten-mathpass-"))
        headless_batch = any(marker in lower_command for marker in (" -script ", " -run ", " -runfile "))
        parent_pid = int(row["ParentProcessId"]) if isinstance(row.get("ParentProcessId"), int) else 0
        parent_missing = parent_pid > 0 and parent_pid not in live_pids
        controlling_process_candidate = _is_controlling_process_candidate(str(name), lower_command)

        processes.append(
            WolframProcessInfo(
                pid=int(row["ProcessId"]),
                parent_pid=parent_pid,
                name=str(name),
                executable_path=str(executable_path) if executable_path is not None else None,
                command_line=command_line,
                started_utc=str(row["StartedUtc"]) if row.get("StartedUtc") is not None else None,
                tungsten_owned=tungsten_owned,
                headless_batch=headless_batch,
                parent_missing=parent_missing,
                controlling_process_candidate=controlling_process_candidate,
            )
        )

    return sorted(processes, key=lambda process: process.pid)


def snapshot_wolfram_processes() -> WolframProcessSnapshot:
    return WolframProcessSnapshot(
        processes=tuple(list_wolfram_processes()),
        cached_max_license_processes=read_cached_max_license_processes(),
    )


def cleanup_stale_tungsten_processes(min_age_seconds: float = 30.0) -> list[int]:
    cleaned: list[int] = []
    for process in list_wolfram_processes():
        age = process.age_seconds
        if not process.tungsten_owned:
            continue
        if not process.headless_batch:
            continue
        if not process.parent_missing:
            continue
        if age is not None and age < min_age_seconds:
            continue

        completed = subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
        if completed.returncode == 0:
            cleaned.append(process.pid)
    return cleaned


@contextmanager
def tungsten_wolfram_launch_gate(timeout_seconds: float = 900.0, poll_seconds: float = 0.2) -> Iterator[float]:
    if msvcrt is None:  # pragma: no cover - non-Windows fallback
        yield 0.0
        return

    lock_path = _cache_root() / "wolfram-launch.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    waited = 0.0
    start = time.monotonic()

    with lock_path.open("a+b") as handle:
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        while True:
            try:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                waited = time.monotonic() - start
                if waited >= timeout_seconds:
                    raise TimeoutError("Timed out waiting for the Tungsten Wolfram launch gate.")
                time.sleep(poll_seconds)

        try:
            waited = time.monotonic() - start
            yield waited
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def wait_for_wolfram_license_slot(
    cached_max_license_processes: int | None,
    *,
    timeout_seconds: float = 30.0,
    poll_seconds: float = 0.5,
) -> tuple[WolframProcessSnapshot, float, bool]:
    start = time.monotonic()
    snapshot = snapshot_wolfram_processes()
    if cached_max_license_processes is None or snapshot.active_count < cached_max_license_processes:
        return snapshot, 0.0, True

    while True:
        elapsed = time.monotonic() - start
        if elapsed >= timeout_seconds:
            return snapshot, elapsed, False
        time.sleep(poll_seconds)
        snapshot = snapshot_wolfram_processes()
        if snapshot.active_count < cached_max_license_processes:
            return snapshot, time.monotonic() - start, True
