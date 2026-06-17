from __future__ import annotations

import os
import re
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
class WolframInstallationSummary:
    product: str
    product_family: str
    version: str | None
    install_dir: Path
    kernel_cli: Path | None
    wolframscript: Path | None

    def to_dict(self) -> dict[str, object]:
        return {
            "product": self.product,
            "product_family": self.product_family,
            "version": self.version,
            "install_dir": str(self.install_dir),
            "kernel_cli": str(self.kernel_cli) if self.kernel_cli else None,
            "wolframscript": str(self.wolframscript) if self.wolframscript else None,
        }


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
    product: str = "unknown"
    product_family: str = "unknown"
    version: str | None = None
    user_base: Path | None = None
    system_base: Path | None = None
    mathpass_candidates: tuple[Path, ...] = ()
    available_installations: tuple[WolframInstallationSummary, ...] = ()
    selection_reason: str | None = None

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
            "product": self.product,
            "product_family": self.product_family,
            "version": self.version,
            "user_base": str(self.user_base) if self.user_base else None,
            "system_base": str(self.system_base) if self.system_base else None,
            "mathpass_candidates": [str(path) for path in self.mathpass_candidates],
            "available_installations": [
                installation.to_dict() for installation in self.available_installations
            ],
            "selection_reason": self.selection_reason,
        }


@dataclass(frozen=True)
class _ProductLayout:
    product: str
    product_family: str
    program_files_name: str
    user_base_name: str
    index_prefix: str
    default_priority: int


_PRODUCT_LAYOUTS = (
    _ProductLayout(
        product="Wolfram",
        product_family="wolfram",
        program_files_name="Wolfram",
        user_base_name="Wolfram",
        index_prefix="wolfram",
        default_priority=0,
    ),
    _ProductLayout(
        product="Wolfram Engine",
        product_family="engine",
        program_files_name="Wolfram Engine",
        user_base_name="WolframEngine",
        index_prefix="wolfram-engine",
        default_priority=1,
    ),
)

_LAYOUTS_BY_FAMILY = {layout.product_family: layout for layout in _PRODUCT_LAYOUTS}
_EXPLICIT_PRODUCT_ALIASES = {
    "wolfram": "wolfram",
    "desktop": "wolfram",
    "paid": "wolfram",
    "mathematica": "wolfram",
    "engine": "engine",
    "wolframengine": "engine",
    "wolfram-engine": "engine",
    "wefd": "engine",
}


def _program_files_wolfram_research_root() -> Path:
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    return Path(program_files) / "Wolfram Research"


def _appdata_root() -> Path | None:
    appdata = os.environ.get("APPDATA")
    return Path(appdata) if appdata else None


def _program_data_root() -> Path:
    return Path(os.environ.get("ProgramData", r"C:\ProgramData"))


def _infer_layout(path: Path) -> _ProductLayout:
    normalized = str(path).lower()
    if "wolfram engine" in normalized or "wolframengine" in normalized:
        return _LAYOUTS_BY_FAMILY["engine"]
    return _LAYOUTS_BY_FAMILY["wolfram"]


def _normalize_install_dir(candidate: Path) -> Path:
    if candidate.is_file():
        parent = candidate.parent
        parts_lower = [part.lower() for part in parent.parts]
        if "systemfiles" in parts_lower:
            index = parts_lower.index("systemfiles")
            return Path(*parent.parts[:index])
        return parent

    if candidate.exists() and _parse_version(candidate.name):
        return candidate

    if candidate.exists() and candidate.is_dir():
        version_dirs = [
            child
            for child in candidate.iterdir()
            if child.is_dir() and _parse_version(child.name)
        ]
        if version_dirs:
            version_dirs.sort(key=lambda path: _parse_version(path.name), reverse=True)
            return version_dirs[0]

    return candidate


def _summarize_install_dir(install_dir: Path) -> WolframInstallationSummary:
    layout = _infer_layout(install_dir)
    kernel_cli = install_dir / "wolfram.exe"
    wolframscript = install_dir / "wolframscript.exe"
    return WolframInstallationSummary(
        product=layout.product,
        product_family=layout.product_family,
        version=install_dir.name if _parse_version(install_dir.name) else None,
        install_dir=install_dir,
        kernel_cli=kernel_cli if kernel_cli.exists() else None,
        wolframscript=wolframscript if wolframscript.exists() else None,
    )


def _installation_candidates() -> list[Path]:
    explicit = os.environ.get("TUNGSTEN_WOLFRAM_HOME")
    candidates: list[Path] = []
    if explicit:
        candidates.append(_normalize_install_dir(Path(explicit)))
        return candidates

    research_root = _program_files_wolfram_research_root()
    for layout in _PRODUCT_LAYOUTS:
        product_root = research_root / layout.program_files_name
        if not product_root.exists():
            continue
        for child in product_root.iterdir():
            if child.is_dir() and _parse_version(child.name):
                candidates.append(child)

    return candidates


def _discover_available_installations() -> tuple[WolframInstallationSummary, ...]:
    discovered: list[WolframInstallationSummary] = []
    seen: set[Path] = set()
    for candidate in _installation_candidates():
        install_dir = _normalize_install_dir(candidate)
        if not install_dir.exists() or not install_dir.is_dir():
            continue
        resolved = install_dir.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        summary = _summarize_install_dir(resolved)
        if summary.kernel_cli or summary.wolframscript:
            discovered.append(summary)

    discovered.sort(key=_installation_sort_key)
    return tuple(discovered)


def _requested_product_family() -> str | None:
    value = os.environ.get("TUNGSTEN_WOLFRAM_PRODUCT", "").strip().lower()
    if not value:
        return None
    return _EXPLICIT_PRODUCT_ALIASES.get(value, value)


def _installation_sort_key(summary: WolframInstallationSummary) -> tuple[int, tuple[int, ...], str]:
    layout = _LAYOUTS_BY_FAMILY.get(summary.product_family, _LAYOUTS_BY_FAMILY["engine"])
    version = _parse_version(summary.version or "")
    return (layout.default_priority, tuple(-part for part in version), str(summary.install_dir).lower())


def _discover_installation_root() -> Path | None:
    explicit_home = os.environ.get("TUNGSTEN_WOLFRAM_HOME")
    available = _discover_available_installations()
    if not available:
        return _normalize_install_dir(Path(explicit_home)) if explicit_home else None

    if explicit_home:
        return available[0].install_dir

    requested_family = _requested_product_family()
    if requested_family:
        matching = [
            installation
            for installation in available
            if installation.product_family == requested_family
        ]
        if matching:
            return matching[0].install_dir

    return available[0].install_dir


def _discover_docs_roots(
    install_dir: Path | None,
    *,
    user_base_name: str | None = None,
) -> tuple[Path, ...]:
    roots: list[Path] = []
    layout = _infer_layout(install_dir) if install_dir is not None else _LAYOUTS_BY_FAMILY["wolfram"]
    appdata = _appdata_root()
    install_version_prefix = _parse_version(install_dir.name) if install_dir is not None else ()
    base_names = [user_base_name or layout.user_base_name]
    if layout.user_base_name != "Wolfram":
        base_names.append("Wolfram")

    if appdata:
        for base_name in base_names:
            paclet_repo = appdata / base_name / "Paclets" / "Repository"
            if not paclet_repo.exists():
                continue
            update_dirs = sorted(
                paclet_repo.glob("SystemDocsUpdate*"),
                reverse=True,
            )
            for update_dir in update_dirs:
                if install_version_prefix:
                    match = re.search(r"-(\d+(?:\.\d+)*)$", update_dir.name)
                    update_version = _parse_version(match.group(1)) if match else ()
                    if update_version[: len(install_version_prefix)] != install_version_prefix:
                        continue
                candidate = update_dir / "Documentation" / "English"
                if candidate.exists():
                    roots.append(candidate)

    common_root = (
        _program_files_wolfram_research_root().parent
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


def _discover_mathpass_candidates(product_family: str) -> tuple[Path, ...]:
    program_data = _program_data_root()
    appdata = _appdata_root()
    candidates: list[Path] = []

    if product_family == "engine":
        if appdata:
            candidates.append(appdata / "WolframEngine" / "Licensing" / "mathpass")
        candidates.append(program_data / "WolframEngine" / "Licensing" / "mathpass")
    else:
        candidates.append(program_data / "Wolfram" / "Licensing" / "mathpass")
        if appdata:
            candidates.append(appdata / "Wolfram" / "Licensing" / "mathpass")

    return tuple(candidates)


def _discover_mathpass(product_family: str) -> tuple[Path | None, tuple[Path, ...]]:
    candidates = _discover_mathpass_candidates(product_family)
    for candidate in candidates:
        if candidate.exists():
            return candidate, candidates

    return None, candidates


def discover_installation() -> WolframInstallation:
    available_installations = _discover_available_installations()
    explicit_home = os.environ.get("TUNGSTEN_WOLFRAM_HOME")
    requested_family = _requested_product_family()
    selected_summary: WolframInstallationSummary | None = None
    selection_reason: str | None = None

    if explicit_home and available_installations:
        selected_summary = available_installations[0]
        selection_reason = "TUNGSTEN_WOLFRAM_HOME"
    elif requested_family:
        for installation in available_installations:
            if installation.product_family == requested_family:
                selected_summary = installation
                selection_reason = f"TUNGSTEN_WOLFRAM_PRODUCT={requested_family}"
                break
    if selected_summary is None and available_installations:
        selected_summary = available_installations[0]
        selection_reason = "default-product-preference"

    install_dir = selected_summary.install_dir if selected_summary else _discover_installation_root()
    layout = _infer_layout(install_dir) if install_dir else _LAYOUTS_BY_FAMILY["wolfram"]
    product = selected_summary.product if selected_summary else layout.product
    product_family = selected_summary.product_family if selected_summary else layout.product_family
    version = (
        selected_summary.version
        if selected_summary
        else install_dir.name if install_dir and _parse_version(install_dir.name) else None
    )

    kernel_cli = install_dir / "wolfram.exe" if install_dir else None
    kernel_executable = install_dir / "WolframKernel.exe" if install_dir else None
    frontend_executable = install_dir / "WolframNB.exe" if install_dir else None
    wolframscript = install_dir / "wolframscript.exe" if install_dir else None
    bundled_python_client = (
        install_dir / "SystemFiles" / "Components" / "WolframClientForPython"
        if install_dir
        else None
    )
    appdata = _appdata_root()
    user_base = appdata / layout.user_base_name if appdata else None
    system_base = _program_data_root() / layout.user_base_name
    docs_roots = _discover_docs_roots(install_dir, user_base_name=layout.user_base_name)
    mathpass, mathpass_candidates = _discover_mathpass(product_family)

    local_app_data_value = os.environ.get("LOCALAPPDATA")
    local_app_data = (
        Path(local_app_data_value)
        if local_app_data_value
        else Path.home() / "AppData" / "Local"
    )
    index_version = version or (install_dir.name if install_dir else "unknown")
    default_index_path = (
        local_app_data / "Tungsten" / "docs" / f"{layout.index_prefix}-{index_version}.sqlite3"
    )

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
        product=product,
        product_family=product_family,
        version=version,
        user_base=user_base,
        system_base=system_base,
        mathpass_candidates=mathpass_candidates,
        available_installations=available_installations,
        selection_reason=selection_reason,
    )


def ensure_parent_directory(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def iter_notebook_files(roots: Iterable[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists():
            continue
        yield from root.rglob("*.nb")
