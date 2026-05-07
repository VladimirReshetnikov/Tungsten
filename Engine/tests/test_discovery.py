from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from tungsten.discovery import _discover_docs_roots


class DiscoveryTests(unittest.TestCase):
    def test_docs_root_discovery_prefers_current_install_version(self) -> None:
        with TemporaryDirectory(prefix="tungsten-discovery-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            install_dir = temp_dir / "Wolfram" / "14.3"
            install_dir.mkdir(parents=True)

            appdata = temp_dir / "AppData" / "Roaming"
            program_files = temp_dir / "Program Files"

            current_update = (
                appdata
                / "Wolfram"
                / "Paclets"
                / "Repository"
                / "SystemDocsUpdate3-14.3.0.3"
                / "Documentation"
                / "English"
            )
            current_update.mkdir(parents=True)

            stale_update = (
                appdata
                / "Wolfram"
                / "Paclets"
                / "Repository"
                / "SystemDocsUpdate2-14.2.0.2"
                / "Documentation"
                / "English"
            )
            stale_update.mkdir(parents=True)

            common_root = (
                program_files
                / "Common Files"
                / "Wolfram Research"
                / "Documentation.en-us"
                / "14.3"
                / "Documentation"
                / "English"
                / "System"
            )
            common_root.mkdir(parents=True)

            with patch.dict(
                os.environ,
                {
                    "APPDATA": str(appdata),
                    "ProgramFiles": str(program_files),
                },
                clear=False,
            ):
                roots = _discover_docs_roots(install_dir)

        self.assertEqual(
            roots,
            (
                current_update.resolve(),
                common_root.resolve(),
            ),
        )


if __name__ == "__main__":
    unittest.main()
