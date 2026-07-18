#!/usr/bin/env python3
"""Differentially audit the Python and native Tungsten command-line surfaces.

The audit deliberately avoids commands that require a live Wolfram installation.  It
uses an isolated fake documentation tree for documentation commands and removes only
parser-corpus timestamps/timings before comparing otherwise exact JSON values.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any, Callable, Sequence


ENGINE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE_BINARY = ENGINE_ROOT / "build" / "cpp" / "tungsten-cpp"


class Audit:
    def __init__(self, native_binary: Path, *, verbose: bool = False) -> None:
        self.native_binary = native_binary.resolve()
        self.verbose = verbose
        self.passed: list[str] = []
        self.failed: list[dict[str, Any]] = []
        self.intentional: list[dict[str, str]] = []

        python_path = str(ENGINE_ROOT / "src")
        inherited = os.environ.get("PYTHONPATH")
        self.base_environment = os.environ.copy()
        self.base_environment["PYTHONPATH"] = (
            python_path if not inherited else python_path + os.pathsep + inherited
        )
        # Make the no-installation cases deterministic even on a configured host.
        self.base_environment.pop("TUNGSTEN_WOLFRAM_HOME", None)
        self.base_environment.pop("TUNGSTEN_WOLFRAM_PRODUCT", None)

    def run(
        self,
        implementation: str,
        arguments: Sequence[str],
        *,
        environment: dict[str, str] | None = None,
        stdin: str | None = None,
        timeout: float = 30.0,
    ) -> subprocess.CompletedProcess[str]:
        if implementation == "python":
            command = [sys.executable, "-m", "tungsten", *arguments]
        else:
            command = [str(self.native_binary), *arguments]
        result = subprocess.run(
            command,
            cwd=ENGINE_ROOT,
            env=environment or self.base_environment,
            input=stdin,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        if self.verbose:
            rendered = " ".join(arguments) if arguments else "<default>"
            print(
                f"[{implementation:6}] {result.returncode:2} {rendered}",
                file=sys.stderr,
            )
        return result

    def _failure(
        self,
        name: str,
        reason: str,
        python: subprocess.CompletedProcess[str],
        native: subprocess.CompletedProcess[str],
        *,
        python_value: Any = None,
        native_value: Any = None,
    ) -> None:
        self.failed.append(
            {
                "name": name,
                "reason": reason,
                "python": {
                    "exit_code": python.returncode,
                    "stdout": python.stdout,
                    "stderr": python.stderr,
                    "value": python_value,
                },
                "native": {
                    "exit_code": native.returncode,
                    "stdout": native.stdout,
                    "stderr": native.stderr,
                    "value": native_value,
                },
            }
        )

    def json_case(
        self,
        name: str,
        arguments: Sequence[str],
        *,
        environment: dict[str, str] | None = None,
        stdin: str | None = None,
        normalize: Callable[[Any], Any] | None = None,
        expected_exit: int | None = None,
        timeout: float = 30.0,
    ) -> tuple[subprocess.CompletedProcess[str], subprocess.CompletedProcess[str]]:
        python = self.run(
            "python", arguments, environment=environment, stdin=stdin, timeout=timeout
        )
        native = self.run(
            "native", arguments, environment=environment, stdin=stdin, timeout=timeout
        )
        if python.returncode != native.returncode:
            self._failure(name, "exit codes differ", python, native)
            return python, native
        if expected_exit is not None and python.returncode != expected_exit:
            self._failure(
                name,
                f"unexpected shared exit code {python.returncode}; expected {expected_exit}",
                python,
                native,
            )
            return python, native
        try:
            python_value = json.loads(python.stdout)
        except (json.JSONDecodeError, TypeError) as error:
            self._failure(name, f"Python stdout is not JSON: {error}", python, native)
            return python, native
        try:
            native_value = json.loads(native.stdout)
        except (json.JSONDecodeError, TypeError) as error:
            self._failure(
                name,
                f"native stdout is not JSON: {error}",
                python,
                native,
                python_value=python_value,
            )
            return python, native
        if normalize is not None:
            python_value = normalize(python_value)
            native_value = normalize(native_value)
        if python_value != native_value:
            self._failure(
                name,
                "JSON values differ",
                python,
                native,
                python_value=python_value,
                native_value=native_value,
            )
            return python, native
        self.passed.append(name)
        return python, native

    def exact_stdout_case(
        self,
        name: str,
        arguments: Sequence[str],
        *,
        stdin: str | None = None,
        expected_exit: int | None = None,
    ) -> None:
        python = self.run("python", arguments, stdin=stdin)
        native = self.run("native", arguments, stdin=stdin)
        if python.returncode != native.returncode:
            self._failure(name, "exit codes differ", python, native)
        elif expected_exit is not None and python.returncode != expected_exit:
            self._failure(name, "unexpected shared exit code", python, native)
        elif python.stdout != native.stdout or python.stderr != native.stderr:
            self._failure(name, "stdout or stderr differs", python, native)
        else:
            self.passed.append(name)

    def exit_case(
        self,
        name: str,
        arguments: Sequence[str],
        *,
        expected_exit: int,
        environment: dict[str, str] | None = None,
        note_output_difference: str | None = None,
    ) -> None:
        python = self.run("python", arguments, environment=environment)
        native = self.run("native", arguments, environment=environment)
        if python.returncode != native.returncode:
            self._failure(name, "exit codes differ", python, native)
            return
        if python.returncode != expected_exit:
            self._failure(name, "unexpected shared exit code", python, native)
            return
        self.passed.append(name)
        if note_output_difference and (
            python.stdout != native.stdout or python.stderr != native.stderr
        ):
            self.intentional.append({"name": name, "reason": note_output_difference})

    def expected_exit_difference(
        self,
        name: str,
        arguments: Sequence[str],
        *,
        python_exit: int,
        native_exit: int,
        reason: str,
        environment: dict[str, str] | None = None,
    ) -> None:
        python = self.run("python", arguments, environment=environment)
        native = self.run("native", arguments, environment=environment)
        if python.returncode != python_exit or native.returncode != native_exit:
            self._failure(
                name,
                "expected intentional exit-code difference changed",
                python,
                native,
            )
            return
        self.passed.append(name)
        self.intentional.append({"name": name, "reason": reason})


def normalize_parser_corpus(payload: Any) -> Any:
    result = copy.deepcopy(payload)

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            for key in list(value):
                if (
                    key == "generated_utc"
                    or "elapsed" in key
                    or "files_per_second" in key
                ):
                    del value[key]
                else:
                    visit(value[key])
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(result)
    return result


def normalize_parser_corpus_report(source: str) -> str:
    lines: list[str] = []
    in_timings = False
    for line in source.splitlines():
        if line.startswith("- Generated UTC:"):
            continue
        if line == "## Timings":
            in_timings = True
            lines.append(line)
            continue
        if in_timings and line.startswith("## "):
            in_timings = False
        if in_timings and line.startswith("- `"):
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def make_isolated_environment(root: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(ENGINE_ROOT / "src")
    environment.pop("TUNGSTEN_WOLFRAM_HOME", None)
    environment.pop("TUNGSTEN_WOLFRAM_PRODUCT", None)
    environment["APPDATA"] = str(root / "appdata")
    environment["LOCALAPPDATA"] = str(root / "localappdata")
    environment["ProgramData"] = str(root / "programdata")
    environment["ProgramFiles"] = str(root / "programfiles")
    environment["HOME"] = str(root / "home")
    return environment


def write_fixtures(root: Path) -> dict[str, Path]:
    root.mkdir(parents=True, exist_ok=True)
    expression_file = root / "expression.wl"
    expression_file.write_text("1 + 2 x^3\n", encoding="utf-8")
    kernel_file = root / "kernel.wl"
    kernel_file.write_text("2 + 2\n", encoding="utf-8")
    notebook = root / "fixture.nb"
    notebook.write_text(
        'Notebook[{Cell["Hello","Text",CellID->42,CellTags->{"tagged"},'
        'ExpressionUUID->"uuid-text"],'
        'Cell[BoxData[GraphicsBox[{CircleBox[]}]],"Output",'
        'ExpressionUUID->"uuid-graphic"]},WindowTitle->"Fixture"]\n',
        encoding="utf-8",
    )
    patch = root / "patch.json"
    patch.write_text(
        json.dumps(
            {
                "operations": [
                    {"op": "append_cell", "style": "Input", "text": "2+2"},
                    {
                        "op": "set_option",
                        "name": "WindowTitle",
                        "value_expr": '"Patched"',
                    },
                ]
            }
        ),
        encoding="utf-8",
    )

    corpus = root / "corpus"
    (corpus / "nested").mkdir(parents=True)
    (corpus / "alpha.wl").write_text("1 + 2\n", encoding="utf-8")
    (corpus / "nested" / "beta.m").write_text("f[x_] := x^2\n", encoding="utf-8")
    (corpus / "gamma.wl").write_text("Sin[x]^2 + Cos[x]^2\n", encoding="utf-8")
    (corpus / "nested" / "delta.m").write_text("{a,b,c}\n", encoding="utf-8")
    (corpus / "nested" / "ignored.txt").write_text("not Wolfram\n", encoding="utf-8")

    docs = (
        root
        / "appdata"
        / "Wolfram"
        / "Paclets"
        / "Repository"
        / "SystemDocsUpdate-fixture"
        / "Documentation"
        / "English"
    )
    symbols = docs / "ReferencePages" / "Symbols"
    guides = docs / "Guides"
    symbols.mkdir(parents=True)
    guides.mkdir(parents=True)
    (symbols / "Foo.nb").write_text(
        'Notebook[{Cell["Foo","ObjectName"],'
        'Cell["Foo computes a symbolic bar.","Usage"]},WindowTitle->Foo]\n',
        encoding="utf-8",
    )
    (guides / "Topic.nb").write_text(
        'Notebook[{Cell["UnusualNeedle phrase","Text"]},WindowTitle->Topic]\n',
        encoding="utf-8",
    )

    return {
        "expression": expression_file,
        "kernel": kernel_file,
        "notebook": notebook,
        "patch": patch,
        "corpus": corpus,
        "docs": docs,
    }


def audit_json_commands(audit: Audit, root: Path, fixtures: dict[str, Path]) -> None:
    isolated = make_isolated_environment(root)
    index = root / "docs.sqlite3"

    audit.json_case("env show", ["env", "show"], expected_exit=0)
    audit.json_case("env show --probe", ["env", "show", "--probe"], expected_exit=0)

    audit.json_case(
        "kernel unavailable code", ["kernel", "eval", "--code", "2+2"], expected_exit=2
    )
    audit.json_case(
        "kernel unavailable file/options",
        [
            "kernel",
            "eval",
            "--file",
            str(fixtures["kernel"]),
            "--working-directory",
            str(root),
            "--front-end",
            "--require-success",
        ],
        expected_exit=2,
    )

    audit.json_case(
        "expr parse input",
        ["expr", "parse", "--code", "1 + 2 x^3", "--form", "input"],
        expected_exit=0,
    )
    audit.json_case(
        "expr parse fullform file",
        ["expr", "parse", "--file", str(fixtures["expression"]), "--form", "fullform"],
        expected_exit=0,
    )
    audit.json_case(
        "expr parse standard form",
        [
            "expr",
            "parse",
            "--code",
            'RowBox[{"1","+","2"}]',
            "--form",
            "standard",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "expr parse syntax error",
        ["expr", "parse", "--code", "f[", "--form", "input"],
        expected_exit=1,
    )
    audit.json_case(
        "expr evaluate",
        ["expr", "evaluate", "--code", "Length[{a,b,c}]"],
        expected_exit=0,
    )

    audit.json_case(
        "notebook inspect",
        ["notebook", "inspect", "--file", str(fixtures["notebook"])],
        expected_exit=0,
    )
    created = root / "created.nb"
    create_arguments = [
        "notebook",
        "create",
        "--file",
        str(created),
        "--title",
        "Created Fixture",
        "--cell",
        "Text:Hello",
        "--cell",
        "Input:2+2",
    ]
    python_create = audit.run("python", create_arguments, environment=isolated)
    python_bytes = created.read_bytes() if created.exists() else b""
    native_create = audit.run("native", create_arguments, environment=isolated)
    native_bytes = created.read_bytes() if created.exists() else b""
    try:
        create_equal = json.loads(python_create.stdout) == json.loads(native_create.stdout)
    except json.JSONDecodeError:
        create_equal = False
    if (
        python_create.returncode == native_create.returncode == 0
        and create_equal
        and python_bytes == native_bytes
    ):
        audit.passed.append("notebook create JSON and bytes")
    else:
        audit._failure(
            "notebook create JSON and bytes",
            "exit code, JSON, or serialized notebook differs",
            python_create,
            native_create,
        )

    empty_title = root / "empty-title.nb"
    empty_title_arguments = [
        "notebook",
        "create",
        "--file",
        str(empty_title),
        "--title",
        "",
    ]
    python_empty_title = audit.run(
        "python", empty_title_arguments, environment=isolated
    )
    python_bytes = empty_title.read_bytes() if empty_title.exists() else b""
    native_empty_title = audit.run(
        "native", empty_title_arguments, environment=isolated
    )
    native_bytes = empty_title.read_bytes() if empty_title.exists() else b""
    try:
        empty_title_equal = (
            json.loads(python_empty_title.stdout)
            == json.loads(native_empty_title.stdout)
        )
    except json.JSONDecodeError:
        empty_title_equal = False
    if (
        python_empty_title.returncode == native_empty_title.returncode == 0
        and empty_title_equal
        and python_bytes == native_bytes
    ):
        audit.passed.append("notebook create empty title JSON and bytes")
    else:
        audit._failure(
            "notebook create empty title JSON and bytes",
            "exit code, JSON, or serialized notebook differs",
            python_empty_title,
            native_empty_title,
        )

    patched = root / "patched.nb"
    patch_arguments = [
        "notebook",
        "patch",
        "--file",
        str(fixtures["notebook"]),
        "--spec",
        str(fixtures["patch"]),
        "--out",
        str(patched),
    ]
    python_patch = audit.run("python", patch_arguments, environment=isolated)
    python_bytes = patched.read_bytes() if patched.exists() else b""
    native_patch = audit.run("native", patch_arguments, environment=isolated)
    native_bytes = patched.read_bytes() if patched.exists() else b""
    try:
        patch_equal = json.loads(python_patch.stdout) == json.loads(native_patch.stdout)
    except json.JSONDecodeError:
        patch_equal = False
    if (
        python_patch.returncode == native_patch.returncode == 0
        and patch_equal
        and python_bytes == native_bytes
    ):
        audit.passed.append("notebook patch JSON and bytes")
    else:
        audit._failure(
            "notebook patch JSON and bytes",
            "exit code, JSON, or serialized notebook differs",
            python_patch,
            native_patch,
        )

    in_place = root / "in-place.nb"
    original_notebook = fixtures["notebook"].read_bytes()
    in_place.write_bytes(original_notebook)
    in_place_arguments = [
        "notebook",
        "patch",
        "--file",
        str(in_place),
        "--spec",
        str(fixtures["patch"]),
    ]
    python_in_place = audit.run("python", in_place_arguments, environment=isolated)
    python_in_place_bytes = in_place.read_bytes() if in_place.exists() else b""
    in_place.write_bytes(original_notebook)
    native_in_place = audit.run("native", in_place_arguments, environment=isolated)
    native_in_place_bytes = in_place.read_bytes() if in_place.exists() else b""
    try:
        in_place_json_equal = (
            json.loads(python_in_place.stdout) == json.loads(native_in_place.stdout)
        )
    except json.JSONDecodeError:
        in_place_json_equal = False
    if (
        python_in_place.returncode == native_in_place.returncode == 0
        and in_place_json_equal
        and python_in_place_bytes == native_in_place_bytes
    ):
        audit.passed.append("notebook patch in-place JSON and bytes")
    else:
        audit._failure(
            "notebook patch in-place JSON and bytes",
            "exit code, JSON, or in-place serialization differs",
            python_in_place,
            native_in_place,
        )

    audit.json_case(
        "parser-corpus discover",
        [
            "parser-corpus",
            "discover",
            "--corpus-root",
            str(fixtures["corpus"]),
            "--extension",
            ".wl",
            "--extension",
            "m",
            "--include-glob",
            "**",
            "--exclude-glob",
            "**/ignored*",
            "--max-files",
            "10",
            "--sample",
            "10",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "parser-corpus compare skip Wolfram",
        [
            "parser-corpus",
            "compare",
            "--corpus-root",
            str(fixtures["corpus"]),
            "--skip-wolfram",
            "--no-write",
            "--include-results",
            "--max-bytes",
            "4096",
            "--form",
            "input",
            "--kernel-batch-size",
            "2",
            "--tungsten-workers",
            "1",
            "--preview-chars",
            "80",
            "--fail-on-tungsten-gap",
            "--fail-on-mismatch",
        ],
        normalize=normalize_parser_corpus,
        expected_exit=0,
        timeout=60.0,
    )
    shuffle_arguments = [
        "parser-corpus",
        "discover",
        "--corpus-root",
        str(fixtures["corpus"]),
        "--shuffle",
        "--seed",
        "7",
        "--sample",
        "10",
    ]
    python_shuffle = audit.run("python", shuffle_arguments, environment=isolated)
    native_shuffle = audit.run("native", shuffle_arguments, environment=isolated)
    try:
        python_shuffle_value = json.loads(python_shuffle.stdout)
        native_shuffle_value = json.loads(native_shuffle.stdout)
    except json.JSONDecodeError:
        python_shuffle_value = None
        native_shuffle_value = None
    if (
        python_shuffle.returncode == native_shuffle.returncode == 0
        and python_shuffle_value == native_shuffle_value
    ):
        audit.passed.append("parser-corpus exact CPython seeded shuffle")
    else:
        audit._failure(
            "parser-corpus exact CPython seeded shuffle",
            "seeded discovery JSON or ordering differs",
            python_shuffle,
            native_shuffle,
            python_value=python_shuffle_value,
            native_value=native_shuffle_value,
        )

    corpus_output = root / "corpus-output"
    write_arguments = [
        "parser-corpus",
        "compare",
        "--corpus-root",
        str(fixtures["corpus"]),
        "--skip-wolfram",
        "--out-dir",
        str(corpus_output),
        "--include-results",
        "--no-max-bytes",
        "--tungsten-workers",
        "1",
    ]
    python_write = audit.run(
        "python", write_arguments, environment=isolated, timeout=60.0
    )
    python_artifacts: dict[str, Any] = {}
    try:
        python_artifacts = {
            "summary": normalize_parser_corpus(
                json.loads((corpus_output / "parser-corpus-summary.json").read_text())
            ),
            "results": [
                normalize_parser_corpus(json.loads(line))
                for line in (
                    corpus_output / "parser-corpus-results.jsonl"
                ).read_text().splitlines()
                if line.strip()
            ],
            "report": normalize_parser_corpus_report(
                (corpus_output / "parser-corpus-report.md").read_text()
            ),
        }
    except (OSError, json.JSONDecodeError):
        pass
    native_write = audit.run(
        "native", write_arguments, environment=isolated, timeout=60.0
    )
    native_artifacts: dict[str, Any] = {}
    try:
        native_artifacts = {
            "summary": normalize_parser_corpus(
                json.loads((corpus_output / "parser-corpus-summary.json").read_text())
            ),
            "results": [
                normalize_parser_corpus(json.loads(line))
                for line in (
                    corpus_output / "parser-corpus-results.jsonl"
                ).read_text().splitlines()
                if line.strip()
            ],
            "report": normalize_parser_corpus_report(
                (corpus_output / "parser-corpus-report.md").read_text()
            ),
        }
    except (OSError, json.JSONDecodeError):
        pass
    try:
        python_write_json = normalize_parser_corpus(json.loads(python_write.stdout))
        native_write_json = normalize_parser_corpus(json.loads(native_write.stdout))
    except json.JSONDecodeError:
        python_write_json = None
        native_write_json = None
    if (
        python_write.returncode == native_write.returncode == 0
        and python_write_json == native_write_json
        and python_artifacts
        and python_artifacts == native_artifacts
    ):
        audit.passed.append("parser-corpus report output files")
    else:
        audit._failure(
            "parser-corpus report output files",
            "normalized stdout or generated report artifacts differ",
            python_write,
            native_write,
            python_value={"stdout": python_write_json, "files": python_artifacts},
            native_value={"stdout": native_write_json, "files": native_artifacts},
        )

    audit.json_case(
        "docs index fixture",
        ["docs", "index", "--path", str(index)],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs search filename",
        ["docs", "search", "Foo", "--index-path", str(index), "--limit", "3"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs search full text",
        [
            "docs",
            "search",
            "UnusualNeedle",
            "--index-path",
            str(index),
            "--limit",
            "3",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs read filename",
        ["docs", "read", "Foo", "--index-path", str(index)],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs read full-text fallback",
        ["docs", "read", "UnusualNeedle", "--index-path", str(index)],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs search zero limit",
        ["docs", "search", "Foo", "--index-path", str(index), "--limit", "0"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs search rebuild",
        [
            "docs",
            "search",
            "UnusualNeedle",
            "--index-path",
            str(index),
            "--rebuild",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "docs open unavailable",
        ["docs", "open", "Foo", "--index-path", str(index)],
        environment=isolated,
        expected_exit=0,
    )
    empty_environment = make_isolated_environment(root / "empty-environment")
    empty_index = root / "empty-docs.sqlite3"
    audit.json_case(
        "docs index absent corpus",
        ["docs", "index", "--path", str(empty_index)],
        environment=empty_environment,
        expected_exit=0,
    )
    audit.json_case(
        "docs search absent corpus",
        ["docs", "search", "Missing", "--index-path", str(empty_index)],
        environment=empty_environment,
        expected_exit=0,
    )

    audit.json_case(
        "frontend probe unavailable",
        ["frontend", "probe"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend probe unavailable required",
        ["frontend", "probe", "--require-success"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend open notebook unavailable",
        ["frontend", "open-notebook", "--file", str(fixtures["notebook"])],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend open notebook unavailable required",
        [
            "frontend",
            "open-notebook",
            "--file",
            str(fixtures["notebook"]),
            "--require-success",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend open documentation unavailable",
        ["frontend", "open-doc", "Foo", "--index-path", str(index)],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend run unavailable",
        ["frontend", "run", "--code", "NotebookCreate[]", "--no-wrap"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend run wrapped unavailable",
        ["frontend", "run", "--code", "NotebookCreate[]", "--require-success"],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend token unavailable",
        [
            "frontend",
            "token",
            "EvaluateCells",
            "--file",
            str(fixtures["notebook"]),
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "frontend token without notebook unavailable",
        ["frontend", "token", "EvaluateCells", "--require-success"],
        environment=isolated,
        expected_exit=0,
    )

    audit.json_case(
        "assistant ask unavailable",
        [
            "assistant",
            "ask",
            "--prompt",
            "Explain this expression",
            "--system-prompt",
            "Be concise",
            "--extra-instructions",
            "Return Wolfram Language",
            "--tool",
            "WolframLanguageEvaluator",
            "--model-service",
            "OpenAI",
            "--model-name",
            "fixture-model",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "assistant ask unavailable required",
        ["assistant", "ask", "--prompt", "Hello", "--require-success"],
        environment=isolated,
        expected_exit=1,
    )
    audit.json_case(
        "assistant ask-cell unavailable",
        [
            "assistant",
            "ask-cell",
            "--file",
            str(fixtures["notebook"]),
            "--expression-uuid",
            "uuid-text",
            "--question",
            "What is this?",
            "--insert-wolfram-code-below",
            "--save",
            "--close-assistant-notebook",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "assistant prepare inline unavailable",
        [
            "assistant",
            "prepare-inline",
            "--file",
            str(fixtures["notebook"]),
            "--cell-path",
            "[0]",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "assistant prepare inline unavailable required",
        [
            "assistant",
            "prepare-inline",
            "--file",
            str(fixtures["notebook"]),
            "--cell-tag",
            "tagged",
            "--require-success",
        ],
        environment=isolated,
        expected_exit=1,
    )
    audit.json_case(
        "assistant capture inline unavailable",
        [
            "assistant",
            "capture-inline",
            "--file",
            str(fixtures["notebook"]),
            "--cell-id",
            "42",
            "--insert-all-wolfram-code-below",
        ],
        environment=isolated,
        expected_exit=0,
    )
    audit.json_case(
        "assistant capture inline unavailable required",
        [
            "assistant",
            "capture-inline",
            "--file",
            str(fixtures["notebook"]),
            "--cell-index",
            "0",
            "--require-success",
        ],
        environment=isolated,
        expected_exit=1,
    )

    audit.json_case(
        "inline-box compose empty",
        ["inline-box", "compose"],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box compose multiple",
        [
            "inline-box",
            "compose",
            "--prefix",
            "before ",
            "--box-expr",
            "GraphicsBox[{CircleBox[]}]",
            "--box-expr",
            "ButtonBox[\"go\"]",
            "--suffix",
            " after",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box from cell one object",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--expression-uuid",
            "uuid-graphic",
            "--prefix",
            "icon: ",
            "--object-index",
            "0",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box from cell all objects",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-path",
            "1",
            "--all-objects",
            "--suffix",
            "!",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box JSON boolean cell path",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-path",
            "[true]",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box no objects",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-id",
            "42",
        ],
        expected_exit=0,
    )
    audit.json_case(
        "inline-box no objects required",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-id",
            "42",
            "--require-success",
        ],
        expected_exit=1,
    )
    audit.exit_case(
        "inline-box missing cell required",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-tag",
            "missing",
            "--require-success",
        ],
        environment=isolated,
        expected_exit=1,
        note_output_difference="Python emits a traceback; native emits one concise diagnostic",
    )
    audit.exit_case(
        "inline-box negative cell index",
        [
            "inline-box",
            "from-cell",
            "--file",
            str(fixtures["notebook"]),
            "--cell-index",
            "-1",
        ],
        environment=isolated,
        expected_exit=1,
        note_output_difference=(
            "both reject the selector at runtime with implementation-specific diagnostics"
        ),
    )
    audit.exit_case(
        "assistant negative cell path",
        [
            "assistant",
            "prepare-inline",
            "--file",
            str(fixtures["notebook"]),
            "--cell-path",
            "-1",
        ],
        environment=isolated,
        expected_exit=1,
        note_output_difference=(
            "both reject the selector at runtime with implementation-specific diagnostics"
        ),
    )
    missing_expression = root / "missing-expression.wl"
    audit.exit_case(
        "expr missing input file",
        ["expr", "parse", "--file", str(missing_expression)],
        environment=isolated,
        expected_exit=1,
        note_output_difference="Python emits a traceback; native emits one concise diagnostic",
    )
    audit.expected_exit_difference(
        "docs negative limit validation",
        ["docs", "search", "Foo", "--index-path", str(index), "--limit", "-1"],
        environment=isolated,
        python_exit=0,
        native_exit=2,
        reason=(
            "Python accidentally exposes negative list/SQLite LIMIT semantics; the native CLI "
            "intentionally rejects negative limits"
        ),
    )


def audit_repl_and_argument_surface(audit: Audit, root: Path) -> None:
    transcript = "1 + 1\nLength[{a,b,c}]\nQuit[]\n"
    audit.exact_stdout_case(
        "REPL no-banner transcript",
        ["repl", "--no-banner"],
        stdin=transcript,
        expected_exit=0,
    )
    audit.exact_stdout_case(
        "default REPL transcript",
        [],
        stdin="Quit[]\n",
        expected_exit=0,
    )

    audit.exit_case(
        "top-level help",
        ["--help"],
        expected_exit=0,
        note_output_difference="native help is concise and uses the native executable name",
    )
    for command in (
        "repl",
        "env",
        "kernel",
        "notebook",
        "expr",
        "parser-corpus",
        "docs",
        "frontend",
        "assistant",
        "inline-box",
    ):
        audit.exit_case(
            f"{command} help",
            [command, "--help"],
            expected_exit=0,
            note_output_difference="native help is concise and uses the native executable name",
        )

    subcommand_help = (
        ("env", "show"),
        ("kernel", "eval"),
        ("notebook", "inspect"),
        ("notebook", "create"),
        ("notebook", "patch"),
        ("expr", "parse"),
        ("expr", "evaluate"),
        ("parser-corpus", "discover"),
        ("parser-corpus", "compare"),
        ("docs", "index"),
        ("docs", "search"),
        ("docs", "read"),
        ("docs", "open"),
        ("frontend", "probe"),
        ("frontend", "open-notebook"),
        ("frontend", "open-doc"),
        ("frontend", "run"),
        ("frontend", "token"),
        ("assistant", "ask"),
        ("assistant", "ask-cell"),
        ("assistant", "prepare-inline"),
        ("assistant", "capture-inline"),
        ("inline-box", "compose"),
        ("inline-box", "from-cell"),
    )
    for command in subcommand_help:
        audit.exit_case(
            " ".join((*command, "help")),
            [*command, "--help"],
            expected_exit=0,
        )

    for command in (
        "env",
        "kernel",
        "notebook",
        "expr",
        "parser-corpus",
        "docs",
        "frontend",
        "assistant",
        "inline-box",
    ):
        audit.exit_case(f"{command} missing subcommand", [command], expected_exit=2)

    audit.exit_case("unknown command", ["definitely-unknown"], expected_exit=2)
    audit.exit_case("unknown top-level option", ["--definitely-unknown"], expected_exit=2)
    audit.exit_case("env unknown option", ["env", "show", "--unknown"], expected_exit=2)
    audit.exit_case("kernel missing source", ["kernel", "eval"], expected_exit=2)
    audit.exit_case(
        "kernel conflicting sources",
        ["kernel", "eval", "--code", "1", "--file", "anything.wl"],
        expected_exit=2,
    )
    audit.exit_case("expr missing source", ["expr", "parse"], expected_exit=2)
    audit.exit_case(
        "expr rejects legacy full form alias",
        ["expr", "parse", "--code", "1", "--form", "full"],
        expected_exit=2,
    )
    audit.exit_case(
        "parser-corpus rejects legacy full form alias",
        ["parser-corpus", "compare", "--form", "full"],
        expected_exit=2,
    )
    audit.exit_case(
        "notebook invalid create cell",
        [
            "notebook",
            "create",
            "--file",
            str(root / "invalid-cell.nb"),
            "--cell",
            "invalid",
        ],
        expected_exit=1,
        note_output_difference="Python emits a traceback; native emits one concise diagnostic",
    )
    audit.exit_case("docs search missing query", ["docs", "search"], expected_exit=2)
    audit.exit_case("frontend run missing code", ["frontend", "run"], expected_exit=2)
    audit.exit_case("assistant ask missing prompt", ["assistant", "ask"], expected_exit=2)
    audit.exit_case(
        "inline-box missing selector",
        ["inline-box", "from-cell", "--file", "fixture.nb"],
        expected_exit=2,
    )

    native_version = audit.run("native", ["--version"])
    python_version = audit.run("python", ["--version"])
    if native_version.returncode == 0 and native_version.stdout.startswith("tungsten-cpp "):
        audit.passed.append("native --version")
        audit.intentional.append(
            {
                "name": "native --version",
                "reason": (
                    "the native executable exposes its port version; the legacy Python CLI has "
                    "no --version action and exits 2"
                ),
            }
        )
    else:
        audit._failure(
            "native --version",
            "native version action is unavailable or malformed",
            python_version,
            native_version,
        )

    for native_command, arguments in (
        ("legacy parse", ["parse", "--code", "1+1"]),
        ("legacy eval", ["eval", "--code", "1+1"]),
        ("evaluator batch protocol", ["eval-batch"]),
    ):
        audit.expected_exit_difference(
            native_command,
            arguments,
            python_exit=2,
            native_exit=0,
            reason=(
                "this native-only compatibility command supports existing projections and "
                "differential harnesses; it is not part of the Python argparse surface"
            ),
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        type=Path,
        default=DEFAULT_NATIVE_BINARY,
        help="Path to the native Tungsten executable.",
    )
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--json-report",
        type=Path,
        help="Optional path for the complete machine-readable audit report.",
    )
    args = parser.parse_args(argv)

    if not args.native_binary.is_file():
        parser.error(f"native binary does not exist: {args.native_binary}")

    audit = Audit(args.native_binary, verbose=args.verbose)
    with tempfile.TemporaryDirectory(prefix="tungsten-cpp-cli-parity-") as temporary:
        root = Path(temporary)
        fixtures = write_fixtures(root)
        audit_json_commands(audit, root, fixtures)
        audit_repl_and_argument_surface(audit, root)

    report = {
        "success": not audit.failed,
        "native_binary": str(audit.native_binary),
        "passed_count": len(audit.passed),
        "failed_count": len(audit.failed),
        "passed": audit.passed,
        "failures": audit.failed,
        "intentional_differences": audit.intentional,
    }
    if args.json_report:
        args.json_report.parent.mkdir(parents=True, exist_ok=True)
        args.json_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(report, indent=2))
    return 0 if report["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
