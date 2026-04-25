from __future__ import annotations

import os
import unittest
from pathlib import Path

from tungsten.discovery import discover_installation
from tungsten.kernel import WolframKernelRunner
from tungsten.parser_corpus import DEFAULT_CORPUS_ROOT
from tungsten.parser_corpus import compare_parser_corpus
from tungsten.parser_corpus import discover_corpus_files


class ParserCorpusIntegrationTests(unittest.TestCase):
    def test_live_wolfram_comparison_on_known_small_corpus_file(self) -> None:
        if os.environ.get("TUNGSTEN_PARSER_CORPUS_LIVE") != "1":
            self.skipTest("Set TUNGSTEN_PARSER_CORPUS_LIVE=1 to run live parser corpus comparison.")
        if not DEFAULT_CORPUS_ROOT.exists():
            self.skipTest(f"Parser corpus root not present: {DEFAULT_CORPUS_ROOT}")

        include_globs = ["github/woxi/tests/woxi/hello_world.wls"]
        files = discover_corpus_files(DEFAULT_CORPUS_ROOT, include_globs=include_globs)
        if not files:
            self.skipTest("Known small Woxi corpus file is not present.")

        installation = discover_installation()
        if installation.kernel_cli is None or installation.mathpass is None:
            self.skipTest("Local Wolfram kernel or mathpass was not discovered.")

        run = compare_parser_corpus(
            corpus_root=Path(DEFAULT_CORPUS_ROOT),
            include_globs=include_globs,
            max_files=1,
            max_bytes=64 * 1024,
            kernel_batch_size=1,
            runner=WolframKernelRunner(installation),
            write_outputs=False,
        )

        self.assertEqual(run.summary["file_count"], 1)
        self.assertIn(run.results[0].wolfram.status, {"success", "failure"})


if __name__ == "__main__":
    unittest.main()
