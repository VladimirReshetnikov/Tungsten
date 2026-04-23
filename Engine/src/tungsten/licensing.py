from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Iterator


@dataclass(frozen=True)
class MathpassInspection:
    path: str | None
    header_present: bool
    original_line_count: int
    unique_entry_count: int
    duplicate_entry_count: int

    def to_dict(self) -> dict[str, object]:
        return {
            "path": self.path,
            "header_present": self.header_present,
            "original_line_count": self.original_line_count,
            "unique_entry_count": self.unique_entry_count,
            "duplicate_entry_count": self.duplicate_entry_count,
        }


def inspect_mathpass(path: Path | None) -> MathpassInspection:
    if path is None or not path.exists():
        return MathpassInspection(
            path=None,
            header_present=False,
            original_line_count=0,
            unique_entry_count=0,
            duplicate_entry_count=0,
        )

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    header_present = bool(lines) and lines[0].startswith("%")
    entries = lines[1:] if header_present else lines
    unique_entries = list(dict.fromkeys(entries))

    return MathpassInspection(
        path=str(path),
        header_present=header_present,
        original_line_count=len(lines),
        unique_entry_count=len(unique_entries),
        duplicate_entry_count=max(0, len(entries) - len(unique_entries)),
    )


def write_deduped_mathpass(source: Path, destination: Path) -> MathpassInspection:
    lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
    header_present = bool(lines) and lines[0].startswith("%")
    header = [lines[0]] if header_present else []
    entries = lines[1:] if header_present else lines
    unique_entries = list(dict.fromkeys(entries))

    destination.write_text("\n".join([*header, *unique_entries, ""]), encoding="utf-8")

    return MathpassInspection(
        path=str(source),
        header_present=header_present,
        original_line_count=len(lines),
        unique_entry_count=len(unique_entries),
        duplicate_entry_count=max(0, len(entries) - len(unique_entries)),
    )


@contextmanager
def deduped_mathpass(source: Path | None) -> Iterator[tuple[Path | None, MathpassInspection]]:
    inspection = inspect_mathpass(source)
    if source is None or not source.exists():
        yield None, inspection
        return

    with TemporaryDirectory(prefix="tungsten-mathpass-") as temp_dir:
        destination = Path(temp_dir) / "mathpass.txt"
        inspection = write_deduped_mathpass(source, destination)
        yield destination, inspection
