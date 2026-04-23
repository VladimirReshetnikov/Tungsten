from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


def _parse_version(value: str) -> tuple[int, ...]:
    parts: list[int] = []
    for fragment in value.split("."):
        fragment = fragment.strip()
        if not fragment:
            continue
        try:
            parts.append(int(fragment))
        except ValueError:
            break

    return tuple(parts)


@dataclass(frozen=True)
class WolframInstallation:
    install_dir: Path | None
    kernel_cli: Path | None
    kernel_executable: Path | None
    frontend_executable: Path | None
    wolframscript: Path | None
    mathpass: Path | None
    docs_roots: tuple[Path, ...]
    bundled_python_client: Path | None
    default_index_path: Path

    def to_dict(self) -> dict[str, object]:
        return {
            "install_dir": str(self.install_dir) if self.install_dir else None,
            "kernel_cli": str(self.kernel_cli) if self.kernel_cli else None,
            "kernel_executable": str(self.kernel_executable) if self.kernel_executable else None,
            "frontend_executable": str(self.frontend_executable) if self.frontend_executable else None,
            "wolframscript": str(self.wolframscript) if self.wolframscript else None,
            "mathpass": str(self.mathpass) if self.mathpass else None,
            "docs_roots": [str(root) for root in self.docs_roots],
            "bundled_python_client": (
                str(self.bundled_python_client) if self.bundled_python_client else None
            ),
            "default_index_path": str(self.default_index_path),
        }


def _installation_candidates() -> list[Path]:
    explicit = os.environ.get("TUNGSTEN_WOLFRAM_HOME")
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))

    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    candidates.append(Path(program_files) / "Wolfram Research" / "Wolfram")

    return candidates


def _discover_installation_root() -> Path | None:
    for candidate in _installation_candidates():
        if candidate.is_file():
            return candidate

        if not candidate.exists():
            continue

        version_dirs = [
            child
            for child in candidate.iterdir()
            if child.is_dir() and _parse_version(child.name)
        ]
        if version_dirs:
            version_dirs.sort(key=lambda path: _parse_version(path.name), reverse=True)
            return version_dirs[0]

    return None


def _discover_docs_roots(install_dir: Path | None) -> tuple[Path, ...]:
    roots: list[Path] = []
    appdata = os.environ.get("APPDATA")
    if appdata:
        paclet_repo = Path(appdata) / "Wolfram" / "Paclets" / "Repository"
        if paclet_repo.exists():
            update_dirs = sorted(
                paclet_repo.glob("SystemDocsUpdate*"),
                reverse=True,
            )
            for update_dir in update_dirs:
                candidate = update_dir / "Documentation" / "English"
                if candidate.exists():
                    roots.append(candidate)

    program_files = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
    common_root = (
        program_files
        / "Common Files"
        / "Wolfram Research"
        / "Documentation.en-us"
    )

    if install_dir is not None:
        version = install_dir.name
        candidate = common_root / version / "Documentation" / "English" / "System"
        if candidate.exists():
            roots.append(candidate)

    deduped: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        resolved = root.resolve()
        if resolved not in seen:
            seen.add(resolved)
            deduped.append(resolved)

    return tuple(deduped)


def _discover_mathpass() -> Path | None:
    program_data = Path(os.environ.get("ProgramData", r"C:\ProgramData"))
    candidates = [
        program_data / "Wolfram" / "Licensing" / "mathpass",
    ]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    return None


def discover_installation() -> WolframInstallation:
    install_dir = _discover_installation_root()
    kernel_cli = install_dir / "wolfram.exe" if install_dir else None
    kernel_executable = install_dir / "WolframKernel.exe" if install_dir else None
    frontend_executable = install_dir / "WolframNB.exe" if install_dir else None
    wolframscript = install_dir / "wolframscript.exe" if install_dir else None
    bundled_python_client = (
        install_dir / "SystemFiles" / "Components" / "WolframClientForPython"
        if install_dir
        else None
    )
    docs_roots = _discover_docs_roots(install_dir)
    mathpass = _discover_mathpass()

    local_app_data = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
    index_version = install_dir.name if install_dir else "unknown"
    default_index_path = local_app_data / "Tungsten" / "docs" / f"wolfram-{index_version}.sqlite3"

    return WolframInstallation(
        install_dir=install_dir if install_dir and install_dir.exists() else None,
        kernel_cli=kernel_cli if kernel_cli and kernel_cli.exists() else None,
        kernel_executable=(
            kernel_executable if kernel_executable and kernel_executable.exists() else None
        ),
        frontend_executable=(
            frontend_executable if frontend_executable and frontend_executable.exists() else None
        ),
        wolframscript=wolframscript if wolframscript and wolframscript.exists() else None,
        mathpass=mathpass,
        docs_roots=docs_roots,
        bundled_python_client=(
            bundled_python_client
            if bundled_python_client and bundled_python_client.exists()
            else None
        ),
        default_index_path=default_index_path,
    )


def ensure_parent_directory(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def iter_notebook_files(roots: Iterable[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists():
            continue
        yield from root.rglob("*.nb")
