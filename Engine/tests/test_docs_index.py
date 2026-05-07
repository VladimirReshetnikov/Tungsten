from __future__ import annotations

import unittest
from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory

from tungsten.discovery import discover_installation
from tungsten.docs_index import DocumentationIndex


class DocumentationIndexTests(unittest.TestCase):
    def test_build_search_and_read(self) -> None:
        with TemporaryDirectory(prefix="tungsten-docs-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            docs_root = temp_dir / "ReferencePages" / "Symbols"
            docs_root.mkdir(parents=True)

            (docs_root / "Foo.nb").write_text(
                'Notebook[{Cell["Foo", "ObjectName"], Cell["Foo computes a symbolic bar.", "Usage"]}, WindowTitle->Foo]\n',
                encoding="utf-8",
            )
            (docs_root / "Bar.nb").write_text(
                'Notebook[{Cell["Bar", "ObjectName"], Cell["Bar transforms a notebook.", "Usage"]}, WindowTitle->Bar]\n',
                encoding="utf-8",
            )

            installation = replace(
                discover_installation(),
                docs_roots=(temp_dir,),
                default_index_path=temp_dir / "docs.sqlite3",
            )
            index = DocumentationIndex(installation)
            index_path = index.build_index()

            hits = index.search("Foo", index_path=index_path, limit=5)
            self.assertGreaterEqual(len(hits), 1)
            self.assertEqual(hits[0]["paclet"], "paclet:ref/Foo")

            record = index.read("paclet:ref/Bar", index_path=index_path)
            self.assertEqual(record["title"], "Bar")
            self.assertIn("notebook", record["text"].lower())


if __name__ == "__main__":
    unittest.main()
