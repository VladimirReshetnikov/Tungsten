from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from tungsten.parser_corpus import ParserAttempt
from tungsten.parser_corpus import compare_parser_corpus
from tungsten.parser_corpus import discover_corpus_files
from tungsten.parser_corpus import parse_file_with_tungsten


class ParserCorpusTests(unittest.TestCase):
    def test_discovers_wolfram_corpus_files_with_stable_relative_paths(self) -> None:
        with TemporaryDirectory(prefix="tungsten-parser-corpus-") as temp_dir_name:
            root = Path(temp_dir_name)
            (root / "github" / "sample").mkdir(parents=True)
            (root / "github" / "sample" / "expr.wl").write_text("1 + 2", encoding="utf-8")
            (root / "github" / "sample" / "notes.txt").write_text("skip", encoding="utf-8")
            (root / "notebookarchive").mkdir()
            (root / "notebookarchive" / "sample.nb").write_text(
                'Notebook[{Cell["Hello", "Text"]}]',
                encoding="utf-8",
            )

            files = discover_corpus_files(root)

        self.assertEqual([file.relative_path for file in files], [
            "github/sample/expr.wl",
            "notebookarchive/sample.nb",
        ])
        self.assertEqual(files[0].kind, "source")
        self.assertEqual(files[1].kind, "notebook")

    def test_tungsten_attempts_parse_source_and_notebook_files(self) -> None:
        with TemporaryDirectory(prefix="tungsten-parser-corpus-") as temp_dir_name:
            root = Path(temp_dir_name)
            root.mkdir(exist_ok=True)
            source_path = root / "expr.wl"
            notebook_path = root / "sample.nb"
            bad_path = root / "bad.wl"
            source_path.write_text("1 + 2 x", encoding="utf-8")
            notebook_path.write_text('Notebook[{Cell["Hello", "Text"]}]', encoding="utf-8")
            bad_path.write_text("x := 1", encoding="utf-8")
            files = {file.relative_path: file for file in discover_corpus_files(root)}

            source_attempt = parse_file_with_tungsten(files["expr.wl"])
            notebook_attempt = parse_file_with_tungsten(files["sample.nb"])
            bad_attempt = parse_file_with_tungsten(files["bad.wl"])

        self.assertEqual(source_attempt.status, "success")
        self.assertEqual(source_attempt.summary["full_form_preview"], "Plus[1, Times[2, x]]")
        self.assertEqual(notebook_attempt.status, "success")
        self.assertEqual(notebook_attempt.summary["cell_count"], 1)
        self.assertEqual(bad_attempt.status, "failure")

    def test_compare_uses_injected_wolfram_batch_parser_and_writes_outputs(self) -> None:
        with TemporaryDirectory(prefix="tungsten-parser-corpus-") as temp_dir_name:
            root = Path(temp_dir_name) / "corpus"
            out_dir = Path(temp_dir_name) / "out"
            root.mkdir()
            (root / "good.wl").write_text("1 + 2", encoding="utf-8")
            (root / "bad.wl").write_text("x := 1", encoding="utf-8")

            def fake_wolfram(batch):
                return {
                    file.relative_path: ParserAttempt(
                        parser="wolfram",
                        status="success",
                        summary={"fake": True},
                    )
                    for file in batch
                }

            run = compare_parser_corpus(
                corpus_root=root,
                out_dir=out_dir,
                wolfram_batch_parser=fake_wolfram,
                write_outputs=True,
            )

            summary_path = Path(run.output_files["summary"])
            results_path = Path(run.output_files["results_jsonl"])
            report_path = Path(run.output_files["report"])

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            result_lines = results_path.read_text(encoding="utf-8").splitlines()
            report_exists = report_path.exists()

        self.assertEqual(run.summary["outcomes"], {"both_success": 1, "tungsten_gap": 1})
        self.assertEqual(summary["file_count"], 2)
        self.assertEqual(len(result_lines), 2)
        self.assertTrue(report_exists)

    def test_compare_marks_oversized_files_skipped_before_kernel_batch(self) -> None:
        with TemporaryDirectory(prefix="tungsten-parser-corpus-") as temp_dir_name:
            root = Path(temp_dir_name)
            root.mkdir(exist_ok=True)
            (root / "large.wl").write_text("1" * 100, encoding="utf-8")

            called = False

            def fake_wolfram(batch):
                nonlocal called
                called = True
                return {}

            run = compare_parser_corpus(
                corpus_root=root,
                max_bytes=10,
                wolfram_batch_parser=fake_wolfram,
                write_outputs=False,
            )

        self.assertFalse(called)
        self.assertEqual(run.results[0].outcome, "skipped")
        self.assertEqual(run.results[0].tungsten.error_type, "FileTooLarge")


if __name__ == "__main__":
    unittest.main()
