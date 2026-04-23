from __future__ import annotations

import json
import re
import sqlite3
import subprocess
from shutil import which
from dataclasses import dataclass
from pathlib import Path

from .discovery import (
    WolframInstallation,
    discover_installation,
    ensure_parent_directory,
    iter_notebook_files,
)
from .notebook import collapse_text, extract_string_literals


REFERENCE_CATEGORY_MAP = {
    "Symbols": "ref",
    "Programs": "ref/program",
    "MenuItems": "ref/menuitem",
    "Characters": "ref/character",
    "Entities": "ref/entity",
    "Interpreters": "ref/interpreter",
    "FrontEndObjects": "ref/frontendobject",
}

SECTION_CATEGORY_MAP = {
    "Guides": "guide",
    "Tutorials": "tutorial",
    "HowTos": "howto",
    "Workflows": "workflow",
    "WorkflowGuides": "workflowguide",
    "ExamplePages": "example",
}

NOISE_LITERALS = {
    "AnchorBar",
    "AnchorBarGrid",
    "Columns",
    "ExampleCount",
    "ExampleSection",
    "LinkHand",
    "ObjectNameTranslation",
    "PacletNameCell",
    "PrimaryExamplesSection",
    "Rows",
    "SeeAlsoRelated",
    "Spacer1",
}


@dataclass(frozen=True)
class DocumentationRecord:
    title: str
    paclet: str
    kind: str
    category: str
    path: str
    preview: str
    text: str

    def to_dict(self) -> dict[str, object]:
        return {
            "title": self.title,
            "paclet": self.paclet,
            "kind": self.kind,
            "category": self.category,
            "path": self.path,
            "preview": self.preview,
            "text": self.text,
        }


class DocumentationIndex:
    def __init__(self, installation: WolframInstallation | None = None) -> None:
        self.installation = installation or discover_installation()

    def ensure_index(self, index_path: Path | None = None, rebuild: bool = False) -> Path:
        target = index_path or self.installation.default_index_path
        if rebuild or not target.exists():
            self.build_index(target)
        return target

    def build_index(self, index_path: Path | None = None) -> Path:
        target = index_path or self.installation.default_index_path
        ensure_parent_directory(target)
        if target.exists():
            target.unlink()

        connection = sqlite3.connect(target)
        try:
            connection.execute(
                """
                CREATE TABLE documents (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    paclet TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    category TEXT NOT NULL,
                    path TEXT NOT NULL,
                    preview TEXT NOT NULL,
                    text TEXT NOT NULL
                )
                """
            )
            connection.execute(
                """
                CREATE VIRTUAL TABLE documents_fts USING fts5(
                    title,
                    paclet,
                    kind,
                    category,
                    preview,
                    text,
                    content='documents',
                    content_rowid='id'
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )

            roots = [str(root) for root in self.installation.docs_roots]
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES(?, ?)",
                ("docs_roots", json.dumps(roots)),
            )

            for notebook_path in iter_notebook_files(self.installation.docs_roots):
                record = self._record_from_path(notebook_path)
                cursor = connection.execute(
                    """
                    INSERT INTO documents(title, paclet, kind, category, path, preview, text)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        record.title,
                        record.paclet,
                        record.kind,
                        record.category,
                        record.path,
                        record.preview,
                        record.text,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO documents_fts(rowid, title, paclet, kind, category, preview, text)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        cursor.lastrowid,
                        record.title,
                        record.paclet,
                        record.kind,
                        record.category,
                        record.preview,
                        record.text,
                    ),
                )

            connection.commit()
        finally:
            connection.close()

        return target

    def search(
        self,
        query: str,
        *,
        index_path: Path | None = None,
        limit: int = 10,
        rebuild: bool = False,
    ) -> list[dict[str, object]]:
        fast_hits = self._search_by_filename(query, limit=limit)
        if fast_hits:
            return fast_hits

        target = self.ensure_index(index_path=index_path, rebuild=rebuild)
        connection = sqlite3.connect(target)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                """
                SELECT
                    documents.title,
                    documents.paclet,
                    documents.kind,
                    documents.category,
                    documents.path,
                    documents.preview,
                    snippet(documents_fts, 5, '[', ']', ' … ', 18) AS snippet,
                    bm25(documents_fts) AS score
                FROM documents_fts
                JOIN documents ON documents.id = documents_fts.rowid
                WHERE documents_fts MATCH ?
                ORDER BY score
                LIMIT ?
                """,
                (self._build_match_query(query), limit),
            ).fetchall()
        finally:
            connection.close()

        return [dict(row) for row in rows]

    def read(
        self,
        identifier: str,
        *,
        index_path: Path | None = None,
        rebuild: bool = False,
    ) -> dict[str, object]:
        fast_hits = self._search_by_filename(identifier, limit=1)
        if fast_hits:
            return fast_hits[0]

        target = self.ensure_index(index_path=index_path, rebuild=rebuild)
        connection = sqlite3.connect(target)
        connection.row_factory = sqlite3.Row
        try:
            if Path(identifier).exists():
                row = connection.execute(
                    "SELECT * FROM documents WHERE path = ?",
                    (str(Path(identifier).resolve()),),
                ).fetchone()
            elif identifier.startswith("paclet:"):
                row = connection.execute(
                    "SELECT * FROM documents WHERE paclet = ? COLLATE NOCASE",
                    (identifier,),
                ).fetchone()
            else:
                row = connection.execute(
                    """
                    SELECT * FROM documents
                    WHERE title = ? COLLATE NOCASE OR paclet = ? COLLATE NOCASE
                    LIMIT 1
                    """,
                    (identifier, identifier),
                ).fetchone()

                if row is None:
                    hits = self.search(identifier, index_path=target, limit=1)
                    if not hits:
                        raise ValueError(f"No documentation page found for {identifier!r}.")
                    row = connection.execute(
                        "SELECT * FROM documents WHERE paclet = ?",
                        (hits[0]["paclet"],),
                    ).fetchone()
        finally:
            connection.close()

        if row is None:
            raise ValueError(f"No documentation page found for {identifier!r}.")

        return dict(row)

    def resolve_identifier(
        self,
        identifier: str,
        *,
        index_path: Path | None = None,
    ) -> str:
        if identifier.startswith("paclet:"):
            return identifier
        return str(self.read(identifier, index_path=index_path)["paclet"])

    def _search_by_filename(self, query: str, *, limit: int) -> list[dict[str, object]]:
        stem = self._stem_from_identifier(query)
        if not stem:
            return []

        paths = self._find_notebook_paths(stem, limit=limit * 4)
        if not paths:
            return []

        records: list[dict[str, object]] = []
        for path in paths[:limit]:
            record = self._record_from_path(path)
            records.append(
                {
                    "title": record.title,
                    "paclet": record.paclet,
                    "kind": record.kind,
                    "category": record.category,
                    "path": record.path,
                    "preview": record.preview,
                    "snippet": record.preview,
                    "score": 0.0,
                }
            )
        return records

    def _record_from_path(self, notebook_path: Path) -> DocumentationRecord:
        raw = notebook_path.read_text(encoding="utf-8", errors="replace")
        title = self._extract_title(raw, notebook_path)
        kind, category, paclet = self._infer_kind_and_paclet(notebook_path)
        strings = self._filter_useful_strings(extract_string_literals(raw))
        text = collapse_text(" ".join(strings), limit=20_000)
        preview_source = " ".join(
            fragment for fragment in strings if fragment and fragment != title
        )
        preview = collapse_text(preview_source, limit=300)

        return DocumentationRecord(
            title=title,
            paclet=paclet,
            kind=kind,
            category=category,
            path=str(notebook_path.resolve()),
            preview=preview,
            text=text,
        )

    @staticmethod
    def _extract_title(raw: str, notebook_path: Path) -> str:
        match = re.search(r"WindowTitle->(?P<title>\"(?:\\\\.|[^\"])*\"|[A-Za-z0-9`.$_-]+)", raw)
        if match:
            title = match.group("title").strip()
            if title.startswith("\"") and title.endswith("\""):
                return title[1:-1].replace("\\\"", "\"")
            return title
        return notebook_path.stem

    @staticmethod
    def _infer_kind_and_paclet(notebook_path: Path) -> tuple[str, str, str]:
        parts = notebook_path.parts
        if "ReferencePages" in parts:
            category = parts[parts.index("ReferencePages") + 1]
            paclet_category = REFERENCE_CATEGORY_MAP.get(category, f"ref/{category.lower()}")
            return "reference", category, f"paclet:{paclet_category}/{notebook_path.stem}"

        for section, paclet_category in SECTION_CATEGORY_MAP.items():
            if section in parts:
                return paclet_category, section, f"paclet:{paclet_category}/{notebook_path.stem}"

        return "document", "Other", f"paclet:document/{notebook_path.stem}"

    @staticmethod
    def _build_match_query(query: str) -> str:
        terms = re.findall(r"[A-Za-z0-9_.:/-]+", query)
        if not terms:
            return f"\"{query}\""
        return " AND ".join(f"\"{term}\"*" for term in terms)

    @staticmethod
    def _filter_useful_strings(strings: list[str]) -> list[str]:
        uuid_pattern = re.compile(
            r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        )
        compressed_blob = re.compile(r"^[A-Za-z0-9+/=:._-]{200,}$")

        filtered: list[str] = []
        for value in strings:
            trimmed = value.strip()
            if not trimmed:
                continue
            if trimmed in NOISE_LITERALS:
                continue
            if uuid_pattern.fullmatch(trimmed):
                continue
            if compressed_blob.fullmatch(trimmed):
                continue
            filtered.append(trimmed)
        return filtered

    @staticmethod
    def _stem_from_identifier(identifier: str) -> str:
        candidate = identifier
        if identifier.startswith("paclet:"):
            candidate = identifier.rsplit("/", 1)[-1]
        candidate = Path(candidate).stem
        if not candidate:
            return ""
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", candidate):
            return ""
        return candidate

    def _find_notebook_paths(self, stem: str, *, limit: int) -> list[Path]:
        es_exe = which("es.exe")
        candidates: list[Path] = []
        roots = [root.resolve() for root in self.installation.docs_roots]

        if es_exe:
            completed = subprocess.run(
                [es_exe, f"{stem}.nb"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            for line in completed.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                candidates.append(Path(line))
        else:
            for root in roots:
                candidates.extend(root.rglob(f"{stem}.nb"))

        filtered: list[Path] = []
        seen: set[Path] = set()
        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue

            if resolved in seen:
                continue
            if resolved.suffix.lower() != ".nb":
                continue
            if resolved.stem.lower() != stem.lower():
                continue
            if not any(str(resolved).lower().startswith(str(root).lower()) for root in roots):
                continue

            seen.add(resolved)
            filtered.append(resolved)

        filtered.sort(key=self._root_priority)
        return filtered[:limit]

    def _root_priority(self, path: Path) -> tuple[int, str]:
        normalized = str(path.resolve()).lower()
        for index, root in enumerate(self.installation.docs_roots):
            prefix = str(root.resolve()).lower()
            if normalized.startswith(prefix):
                return index, normalized
        return len(self.installation.docs_roots), normalized
