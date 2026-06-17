from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from tungsten.discovery import _discover_docs_roots, discover_installation


class DiscoveryTests(unittest.TestCase):
    @staticmethod
    def _touch(path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("", encoding="utf-8")

    def test_default_discovery_prefers_paid_wolfram_over_engine(self) -> None:
        with TemporaryDirectory(prefix="tungsten-discovery-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            program_files = temp_dir / "Program Files"
            appdata = temp_dir / "AppData" / "Roaming"
            program_data = temp_dir / "ProgramData"
            local_app_data = temp_dir / "AppData" / "Local"

            paid_root = program_files / "Wolfram Research" / "Wolfram" / "15.0"
            engine_root = program_files / "Wolfram Research" / "Wolfram Engine" / "14.3"
            self._touch(paid_root / "wolfram.exe")
            self._touch(paid_root / "wolframscript.exe")
            self._touch(engine_root / "wolfram.exe")
            self._touch(engine_root / "wolframscript.exe")
            self._touch(program_data / "Wolfram" / "Licensing" / "mathpass")

            with patch.dict(
                os.environ,
                {
                    "ProgramFiles": str(program_files),
                    "APPDATA": str(appdata),
                    "ProgramData": str(program_data),
                    "LOCALAPPDATA": str(local_app_data),
                },
                clear=True,
            ):
                installation = discover_installation()

        self.assertEqual(installation.product, "Wolfram")
        self.assertEqual(installation.product_family, "wolfram")
        self.assertEqual(installation.version, "15.0")
        self.assertEqual(installation.install_dir, paid_root.resolve())
        self.assertEqual(installation.kernel_cli, paid_root.resolve() / "wolfram.exe")
        self.assertEqual(
            installation.default_index_path,
            local_app_data / "Tungsten" / "docs" / "wolfram-15.0.sqlite3",
        )
        self.assertEqual(
            [(item.product_family, item.version) for item in installation.available_installations],
            [("wolfram", "15.0"), ("engine", "14.3")],
        )

    def test_product_override_can_select_wolfram_engine(self) -> None:
        with TemporaryDirectory(prefix="tungsten-discovery-") as temp_dir_name:
            temp_dir = Path(temp_dir_name)
            program_files = temp_dir / "Program Files"
            appdata = temp_dir / "AppData" / "Roaming"
            program_data = temp_dir / "ProgramData"
            local_app_data = temp_dir / "AppData" / "Local"

            paid_root = program_files / "Wolfram Research" / "Wolfram" / "15.0"
            engine_root = program_files / "Wolfram Research" / "Wolfram Engine" / "14.3"
            self._touch(paid_root / "wolfram.exe")
            self._touch(engine_root / "wolfram.exe")
            engine_mathpass = appdata / "WolframEngine" / "Licensing" / "mathpass"
            self._touch(engine_mathpass)

            with patch.dict(
                os.environ,
                {
                    "ProgramFiles": str(program_files),
                    "APPDATA": str(appdata),
                    "ProgramData": str(program_data),
                    "LOCALAPPDATA": str(local_app_data),
                    "TUNGSTEN_WOLFRAM_PRODUCT": "engine",
                },
                clear=True,
            ):
                installation = discover_installation()

        self.assertEqual(installation.product, "Wolfram Engine")
        self.assertEqual(installation.product_family, "engine")
        self.assertEqual(installation.version, "14.3")
        self.assertEqual(installation.install_dir, engine_root.resolve())
        self.assertEqual(installation.mathpass, engine_mathpass)
        self.assertEqual(
            installation.default_index_path,
            local_app_data / "Tungsten" / "docs" / "wolfram-engine-14.3.sqlite3",
        )

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
