from __future__ import annotations

import datetime as dt
import fnmatch
import json
import random
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping, Sequence

from .expression import depth as expression_depth
from .expression import length as expression_length
from .expression import parse_expression
from .kernel import WolframKernelRunner
from .notebook import NotebookDocument
from .notebook import wl_string
from .wolfram_strings import parse_wl_string_literal


DEFAULT_CORPUS_ROOT = Path(r"C:\TestData\tungsten-wolfram-parser-corpus")
DEFAULT_OUTPUT_DIRECTORY_NAME = "validation"
DEFAULT_EXTENSIONS = (".wl", ".m", ".wls", ".mt", ".wlt", ".nb", ".nbp")
NOTEBOOK_EXTENSIONS = (".nb", ".nbp")
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
DEFAULT_KERNEL_BATCH_SIZE = 25
DEFAULT_PREVIEW_CHARS = 2_000


@dataclass(frozen=True)
class CorpusFile:
    path: Path
    relative_path: str
    extension: str
    kind: str
    source: str
    size_bytes: int

    def to_dict(self) -> dict[str, object]:
        return {
            "path": str(self.path),
            "relative_path": self.relative_path,
            "extension": self.extension,
            "kind": self.kind,
            "source": self.source,
            "size_bytes": self.size_bytes,
        }


@dataclass(frozen=True)
class ParserAttempt:
    parser: str
    status: str
    elapsed_ms: float | None = None
    error_type: str | None = None
    error: str | None = None
    summary: dict[str, object] = field(default_factory=dict)

    def to_dict(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "parser": self.parser,
            "status": self.status,
            "elapsed_ms": self.elapsed_ms,
            "error_type": self.error_type,
            "error": self.error,
            "summary": self.summary,
        }
        return {key: value for key, value in payload.items() if value is not None}


@dataclass(frozen=True)
class ParserCorpusResult:
    file: CorpusFile
    tungsten: ParserAttempt
    wolfram: ParserAttempt
    outcome: str

    def to_dict(self) -> dict[str, object]:
        return {
            "file": self.file.to_dict(),
            "tungsten": self.tungsten.to_dict(),
            "wolfram": self.wolfram.to_dict(),
            "outcome": self.outcome,
        }


@dataclass(frozen=True)
class ParserCorpusRun:
    summary: dict[str, object]
    results: list[ParserCorpusResult]
    output_files: dict[str, str] = field(default_factory=dict)

    def to_dict(self, *, include_results: bool = False) -> dict[str, object]:
        payload: dict[str, object] = {
            "summary": self.summary,
            "output_files": self.output_files,
        }
        if include_results:
            payload["results"] = [result.to_dict() for result in self.results]
        return payload


WolframBatchParser = Callable[[Sequence[CorpusFile]], Mapping[str, ParserAttempt]]


def discover_corpus_files(
    corpus_root: Path = DEFAULT_CORPUS_ROOT,
    *,
    extensions: Sequence[str] | None = None,
    include_globs: Sequence[str] = (),
    exclude_globs: Sequence[str] = (),
    max_files: int | None = None,
    shuffle: bool = False,
    seed: int = 0,
) -> list[CorpusFile]:
    root = Path(corpus_root).resolve()
    if not root.exists():
        raise FileNotFoundError(f"Parser corpus root does not exist: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"Parser corpus root is not a directory: {root}")

    normalized_extensions = _normalize_extensions(extensions or DEFAULT_EXTENSIONS)
    include_patterns = _normalize_globs(include_globs)
    exclude_patterns = _normalize_globs(exclude_globs)

    files: list[CorpusFile] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue

        extension = path.suffix.lower()
        if extension not in normalized_extensions:
            continue

        relative_path = path.relative_to(root).as_posix()
        if include_patterns and not _matches_any(relative_path, include_patterns):
            continue
        if exclude_patterns and _matches_any(relative_path, exclude_patterns):
            continue

        try:
            size_bytes = path.stat().st_size
        except OSError:
            continue

        files.append(
            CorpusFile(
                path=path,
                relative_path=relative_path,
                extension=extension,
                kind="notebook" if extension in NOTEBOOK_EXTENSIONS else "source",
                source=_source_from_relative_path(relative_path),
                size_bytes=size_bytes,
            )
        )

    files.sort(key=lambda item: item.relative_path.casefold())
    if shuffle:
        random.Random(seed).shuffle(files)
    if max_files is not None:
        files = files[: max(0, max_files)]
    return files


def summarize_discovery(files: Sequence[CorpusFile], *, corpus_root: Path = DEFAULT_CORPUS_ROOT) -> dict[str, object]:
    return {
        "corpus_root": str(Path(corpus_root).resolve()),
        "file_count": len(files),
        "total_bytes": sum(file.size_bytes for file in files),
        "by_extension": dict(sorted(Counter(file.extension for file in files).items())),
        "by_kind": dict(sorted(Counter(file.kind for file in files).items())),
        "by_source": dict(sorted(Counter(file.source for file in files).items())),
    }


def parse_file_with_tungsten(
    file: CorpusFile,
    *,
    source_form: str = "input",
    max_bytes: int | None = DEFAULT_MAX_BYTES,
    preview_chars: int = DEFAULT_PREVIEW_CHARS,
) -> ParserAttempt:
    if max_bytes is not None and file.size_bytes > max_bytes:
        return _skipped_attempt(
            "tungsten",
            "FileTooLarge",
            f"File is {file.size_bytes} bytes; max_bytes is {max_bytes}.",
        )

    start = time.perf_counter()
    try:
        text = file.path.read_text(encoding="utf-8", errors="replace")
        if file.kind == "notebook":
            document = NotebookDocument.from_text(text, path=file.path)
            payload = document.to_dict()
            summary = {
                "title": payload.get("title"),
                "cell_count": payload.get("cell_count"),
                "group_count": payload.get("group_count"),
                "option_count": len(payload.get("options", [])),
            }
        else:
            expression = parse_expression(text, form=source_form)
            summary = {
                "form": source_form,
                "input_form_preview": _truncate(expression.to_input_form(), preview_chars),
                "full_form_preview": _truncate(expression.to_full_form(), preview_chars),
                "depth": expression_depth(expression),
                "length": expression_length(expression),
            }
        return ParserAttempt(
            parser="tungsten",
            status="success",
            elapsed_ms=_elapsed_ms(start),
            summary=summary,
        )
    except Exception as exc:
        return ParserAttempt(
            parser="tungsten",
            status="failure",
            elapsed_ms=_elapsed_ms(start),
            error_type=type(exc).__name__,
            error=_truncate(str(exc), preview_chars),
        )


def parse_files_with_wolfram_kernel(
    files: Sequence[CorpusFile],
    *,
    runner: WolframKernelRunner | None = None,
    preview_chars: int = DEFAULT_PREVIEW_CHARS,
) -> dict[str, ParserAttempt]:
    if not files:
        return {}

    active_runner = runner or WolframKernelRunner()
    script = _build_wolfram_parse_batch_script(files, preview_chars=preview_chars)
    result = active_runner.evaluate_text(script)
    if not result.evaluation_available:
        return {
            file.relative_path: _skipped_attempt(
                "wolfram",
                result.failure_type or "KernelUnavailable",
                result.stderr or "Wolfram kernel did not produce a structured result.",
            )
            for file in files
        }

    if result.result is None:
        return {
            file.relative_path: ParserAttempt(
                parser="wolfram",
                status="failure",
                error_type="MissingKernelResult",
                error="Wolfram kernel evaluation completed without a result string.",
            )
            for file in files
        }

    try:
        batch_payload = _decode_kernel_json_string(result.result)
    except Exception as exc:
        return {
            file.relative_path: ParserAttempt(
                parser="wolfram",
                status="failure",
                error_type=type(exc).__name__,
                error=_truncate(f"Could not decode Wolfram parser batch payload: {exc}", preview_chars),
                summary={
                    "kernel_success": result.success,
                    "kernel_failure_type": result.failure_type,
                    "kernel_messages": result.messages,
                    "kernel_result_preview": _truncate(result.result, preview_chars),
                },
            )
            for file in files
        }

    attempts: dict[str, ParserAttempt] = {}
    if not isinstance(batch_payload, list):
        return {
            file.relative_path: ParserAttempt(
                parser="wolfram",
                status="failure",
                error_type="InvalidKernelPayload",
                error="Wolfram parser batch payload was not a JSON array.",
            )
            for file in files
        }

    path_to_file = {file.path.resolve().as_posix(): file for file in files}
    for item in batch_payload:
        if not isinstance(item, dict):
            continue
        raw_path = str(item.get("path", ""))
        file = path_to_file.get(raw_path)
        if file is None:
            continue
        raw_attempt = item.get("attempt")
        if isinstance(raw_attempt, dict):
            attempts[file.relative_path] = _attempt_from_wolfram_payload(raw_attempt, preview_chars=preview_chars)

    for file in files:
        attempts.setdefault(
            file.relative_path,
            ParserAttempt(
                parser="wolfram",
                status="failure",
                error_type="MissingFileResult",
                error="Wolfram parser batch did not include this file in its JSON payload.",
            ),
        )
    return attempts


def compare_parser_corpus(
    *,
    corpus_root: Path = DEFAULT_CORPUS_ROOT,
    out_dir: Path | None = None,
    extensions: Sequence[str] | None = None,
    include_globs: Sequence[str] = (),
    exclude_globs: Sequence[str] = (),
    max_files: int | None = None,
    max_bytes: int | None = DEFAULT_MAX_BYTES,
    source_form: str = "input",
    compare_wolfram: bool = True,
    kernel_batch_size: int = DEFAULT_KERNEL_BATCH_SIZE,
    preview_chars: int = DEFAULT_PREVIEW_CHARS,
    shuffle: bool = False,
    seed: int = 0,
    runner: WolframKernelRunner | None = None,
    wolfram_batch_parser: WolframBatchParser | None = None,
    write_outputs: bool = True,
) -> ParserCorpusRun:
    files = discover_corpus_files(
        corpus_root,
        extensions=extensions,
        include_globs=include_globs,
        exclude_globs=exclude_globs,
        max_files=max_files,
        shuffle=shuffle,
        seed=seed,
    )

    tungsten_attempts = {
        file.relative_path: parse_file_with_tungsten(
            file,
            source_form=source_form,
            max_bytes=max_bytes,
            preview_chars=preview_chars,
        )
        for file in files
    }

    wolfram_attempts: dict[str, ParserAttempt] = {}
    if compare_wolfram:
        eligible_files = [
            file
            for file in files
            if max_bytes is None or file.size_bytes <= max_bytes
        ]
        for batch in _batches(eligible_files, max(1, kernel_batch_size)):
            if wolfram_batch_parser is not None:
                batch_attempts = dict(wolfram_batch_parser(batch))
            else:
                batch_attempts = parse_files_with_wolfram_kernel(
                    batch,
                    runner=runner,
                    preview_chars=preview_chars,
                )
            wolfram_attempts.update(batch_attempts)

    for file in files:
        if file.relative_path in wolfram_attempts:
            continue
        if compare_wolfram:
            wolfram_attempts[file.relative_path] = _skipped_attempt(
                "wolfram",
                "FileTooLarge",
                f"File is {file.size_bytes} bytes; max_bytes is {max_bytes}.",
            )
        else:
            wolfram_attempts[file.relative_path] = _skipped_attempt(
                "wolfram",
                "WolframComparisonDisabled",
                "Wolfram kernel comparison was disabled for this run.",
            )

    results = [
        ParserCorpusResult(
            file=file,
            tungsten=tungsten_attempts[file.relative_path],
            wolfram=wolfram_attempts[file.relative_path],
            outcome=_classify_outcome(
                tungsten_attempts[file.relative_path],
                wolfram_attempts[file.relative_path],
            ),
        )
        for file in files
    ]

    output_directory = out_dir
    if output_directory is None and write_outputs:
        output_directory = Path(corpus_root) / DEFAULT_OUTPUT_DIRECTORY_NAME

    output_files: dict[str, str] = {}
    summary = _build_run_summary(
        corpus_root=corpus_root,
        files=files,
        results=results,
        options={
            "extensions": list(_normalize_extensions(extensions or DEFAULT_EXTENSIONS)),
            "include_globs": list(include_globs),
            "exclude_globs": list(exclude_globs),
            "max_files": max_files,
            "max_bytes": max_bytes,
            "source_form": source_form,
            "compare_wolfram": compare_wolfram,
            "kernel_batch_size": kernel_batch_size,
            "preview_chars": preview_chars,
            "shuffle": shuffle,
            "seed": seed,
        },
    )

    if write_outputs and output_directory is not None:
        output_files = write_parser_corpus_outputs(
            output_directory,
            summary=summary,
            results=results,
        )
        summary["output_files"] = output_files

    return ParserCorpusRun(summary=summary, results=results, output_files=output_files)


def write_parser_corpus_outputs(
    out_dir: Path,
    *,
    summary: Mapping[str, object],
    results: Sequence[ParserCorpusResult],
) -> dict[str, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    summary_path = out_dir / "parser-corpus-summary.json"
    results_path = out_dir / "parser-corpus-results.jsonl"
    report_path = out_dir / "parser-corpus-report.md"

    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    with results_path.open("w", encoding="utf-8", newline="\n") as writer:
        for result in results:
            writer.write(json.dumps(result.to_dict(), separators=(",", ":")) + "\n")
    report_path.write_text(_render_markdown_report(summary, results), encoding="utf-8")

    return {
        "summary": str(summary_path),
        "results_jsonl": str(results_path),
        "report": str(report_path),
    }


def _build_run_summary(
    *,
    corpus_root: Path,
    files: Sequence[CorpusFile],
    results: Sequence[ParserCorpusResult],
    options: Mapping[str, object],
) -> dict[str, object]:
    tungsten_failure_types = Counter(
        result.tungsten.error_type or "Unknown"
        for result in results
        if result.tungsten.status == "failure"
    )
    wolfram_failure_types = Counter(
        result.wolfram.error_type or "Unknown"
        for result in results
        if result.wolfram.status == "failure"
    )
    return {
        "generated_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "corpus_root": str(Path(corpus_root).resolve()),
        "options": dict(options),
        "file_count": len(files),
        "total_bytes": sum(file.size_bytes for file in files),
        "by_extension": dict(sorted(Counter(file.extension for file in files).items())),
        "by_kind": dict(sorted(Counter(file.kind for file in files).items())),
        "by_source": dict(sorted(Counter(file.source for file in files).items())),
        "outcomes": dict(sorted(Counter(result.outcome for result in results).items())),
        "tungsten_statuses": dict(sorted(Counter(result.tungsten.status for result in results).items())),
        "wolfram_statuses": dict(sorted(Counter(result.wolfram.status for result in results).items())),
        "tungsten_failure_types": dict(sorted(tungsten_failure_types.items())),
        "wolfram_failure_types": dict(sorted(wolfram_failure_types.items())),
    }


def _render_markdown_report(summary: Mapping[str, object], results: Sequence[ParserCorpusResult]) -> str:
    lines = [
        "# Tungsten Parser Corpus Comparison",
        "",
        f"- Generated UTC: `{summary.get('generated_utc')}`",
        f"- Corpus root: `{summary.get('corpus_root')}`",
        f"- Files considered: `{summary.get('file_count')}`",
        f"- Total bytes considered: `{summary.get('total_bytes')}`",
        "",
        "## Outcomes",
        "",
    ]
    outcomes = summary.get("outcomes")
    if isinstance(outcomes, dict):
        for key, value in outcomes.items():
            lines.append(f"- `{key}`: `{value}`")
    lines.extend(["", "## Tungsten Failure Types", ""])
    failure_types = summary.get("tungsten_failure_types")
    if isinstance(failure_types, dict) and failure_types:
        for key, value in failure_types.items():
            lines.append(f"- `{key}`: `{value}`")
    else:
        lines.append("- None")

    lines.extend(["", "## First Wolfram-Accepted Tungsten Gaps", ""])
    gaps = [result for result in results if result.outcome == "tungsten_gap"][:50]
    if gaps:
        for result in gaps:
            lines.append(
                "- "
                f"`{result.file.relative_path}` "
                f"({result.file.extension}, {result.file.size_bytes} bytes): "
                f"{result.tungsten.error_type or result.tungsten.status}"
            )
            if result.tungsten.error:
                lines.append(f"  Tungsten: `{_one_line(result.tungsten.error, 180)}`")
    else:
        lines.append("- None in this run.")

    lines.extend(["", "## First Tungsten-Accepted Wolfram Rejections", ""])
    suspicious = [result for result in results if result.outcome == "tungsten_only_success"][:50]
    if suspicious:
        for result in suspicious:
            lines.append(
                "- "
                f"`{result.file.relative_path}` "
                f"({result.file.extension}, {result.file.size_bytes} bytes): "
                f"{result.wolfram.error_type or result.wolfram.status}"
            )
            if result.wolfram.error:
                lines.append(f"  Wolfram: `{_one_line(result.wolfram.error, 180)}`")
    else:
        lines.append("- None in this run.")

    lines.append("")
    return "\n".join(lines)


def _classify_outcome(tungsten: ParserAttempt, wolfram: ParserAttempt) -> str:
    if tungsten.status == "skipped" or wolfram.status == "skipped":
        return "skipped"
    if tungsten.status == "success" and wolfram.status == "success":
        return "both_success"
    if tungsten.status == "failure" and wolfram.status == "success":
        return "tungsten_gap"
    if tungsten.status == "success" and wolfram.status == "failure":
        return "tungsten_only_success"
    if tungsten.status == "failure" and wolfram.status == "failure":
        return "both_fail"
    return f"{tungsten.status}_vs_{wolfram.status}"


def _build_wolfram_parse_batch_script(files: Sequence[CorpusFile], *, preview_chars: int) -> str:
    paths_json = json.dumps([file.path.resolve().as_posix() for file in files])
    paths_literal = wl_string(paths_json)
    return f"""
tungstenParserCorpusFiles = ImportString[{paths_literal}, "RawJSON"];
tungstenParserCorpusPreviewChars = {int(preview_chars)};

ClearAll[tungstenParserCorpusShortString, tungstenParserCorpusParseOne];
tungstenParserCorpusShortString[text_] := If[
    StringQ[text] && StringLength[text] > tungstenParserCorpusPreviewChars,
    StringTake[text, tungstenParserCorpusPreviewChars] <> "...",
    text
];

tungstenParserCorpusParseOne[path_String] := Module[
    {{started, text, held, normalized, rendered, fullRendered}},
    started = AbsoluteTime[];
    text = Quiet @ Check[Import[path, "Text", CharacterEncoding -> "UTF-8"], $Failed];
    If[
        text === $Failed,
        Return @ <|
            "parser" -> "wolfram",
            "status" -> "failure",
            "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
            "error_type" -> "ImportFailure",
            "error" -> "Import[path, Text] returned $Failed."
        |>
    ];

    held = Quiet @ Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[
        held === $Failed,
        Return @ <|
            "parser" -> "wolfram",
            "status" -> "failure",
            "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
            "error_type" -> "ParseFailure",
            "error" -> "ToExpression[text, InputForm, HoldComplete] returned $Failed."
        |>
    ];

    normalized = Replace[held, HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]];
    rendered = Quiet @ Check[ToString[normalized, InputForm, PageWidth -> Infinity], "$Failed"];
    fullRendered = Quiet @ Check[ToString[FullForm[normalized], OutputForm, PageWidth -> Infinity], "$Failed"];
    <|
        "parser" -> "wolfram",
        "status" -> "success",
        "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
        "summary" -> <|
            "held_head" -> Quiet @ Check[ToString[Head[normalized], InputForm], "$Failed"],
            "leaf_count" -> Quiet @ Check[LeafCount[normalized], Null],
            "byte_count" -> Quiet @ Check[ByteCount[normalized], Null],
            "input_form_preview" -> tungstenParserCorpusShortString[rendered],
            "full_form_preview" -> tungstenParserCorpusShortString[fullRendered]
        |>
    |>
];

ExportString[
    Map[<|"path" -> #, "attempt" -> tungstenParserCorpusParseOne[#]|> &, tungstenParserCorpusFiles],
    "RawJSON"
]
""".strip()


def _attempt_from_wolfram_payload(payload: Mapping[str, object], *, preview_chars: int) -> ParserAttempt:
    raw_summary = payload.get("summary")
    summary = dict(raw_summary) if isinstance(raw_summary, dict) else {}
    return ParserAttempt(
        parser="wolfram",
        status=str(payload.get("status", "failure")),
        elapsed_ms=_optional_float(payload.get("elapsed_ms")),
        error_type=_optional_string(payload.get("error_type")),
        error=_truncate(_optional_string(payload.get("error")) or "", preview_chars) or None,
        summary=summary,
    )


def _decode_kernel_json_string(value: str) -> object:
    text = value.strip()
    if text.startswith('"') and text.endswith('"'):
        text = parse_wl_string_literal(text)
    return json.loads(text)


def _normalize_extensions(extensions: Sequence[str]) -> tuple[str, ...]:
    normalized = []
    for extension in extensions:
        text = extension.strip().lower()
        if not text:
            continue
        if not text.startswith("."):
            text = f".{text}"
        normalized.append(text)
    return tuple(dict.fromkeys(normalized))


def _normalize_globs(patterns: Sequence[str]) -> tuple[str, ...]:
    return tuple(pattern.replace("\\", "/") for pattern in patterns if pattern.strip())


def _matches_any(relative_path: str, patterns: Sequence[str]) -> bool:
    return any(fnmatch.fnmatch(relative_path, pattern) for pattern in patterns)


def _source_from_relative_path(relative_path: str) -> str:
    parts = relative_path.split("/")
    if len(parts) >= 2 and parts[0] in {"github", "notebookarchive"}:
        return "/".join(parts[:2])
    return parts[0] if parts else ""


def _batches(items: Sequence[CorpusFile], batch_size: int) -> list[list[CorpusFile]]:
    return [list(items[index : index + batch_size]) for index in range(0, len(items), batch_size)]


def _skipped_attempt(parser: str, reason: str, message: str) -> ParserAttempt:
    return ParserAttempt(
        parser=parser,
        status="skipped",
        error_type=reason,
        error=message,
    )


def _elapsed_ms(start: float) -> float:
    return round((time.perf_counter() - start) * 1000, 3)


def _optional_float(value: object) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _optional_string(value: object) -> str | None:
    if value is None:
        return None
    return str(value)


def _truncate(value: str, limit: int) -> str:
    if limit <= 0 or len(value) <= limit:
        return value
    return value[: max(0, limit - 3)].rstrip() + "..."


def _one_line(value: str, limit: int) -> str:
    return _truncate(" ".join(value.split()), limit)
