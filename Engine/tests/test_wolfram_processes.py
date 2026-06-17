from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tungsten.wolfram_processes import WolframProcessInfo
from tungsten.wolfram_processes import WolframProcessSnapshot
from tungsten.wolfram_processes import cleanup_stale_tungsten_processes
from tungsten.wolfram_processes import read_cached_max_license_processes
from tungsten.wolfram_processes import wait_for_wolfram_license_slot
from tungsten.wolfram_processes import write_cached_max_license_processes


class WolframProcessesTests(unittest.TestCase):
    def test_license_process_cache_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_root = Path(temp_dir)
            with patch("tungsten.wolfram_processes._cache_root", return_value=cache_root):
                self.assertIsNone(read_cached_max_license_processes())
                write_cached_max_license_processes(2)
                self.assertEqual(read_cached_max_license_processes(), 2)

    def test_cleanup_stale_tungsten_processes_terminates_only_orphaned_headless_tungsten_kernels(self) -> None:
        stale = WolframProcessInfo(
            pid=111,
            parent_pid=9,
            name="wolfram.exe",
            executable_path="C:\\Program Files\\Wolfram Research\\Wolfram\\15.0\\wolfram.exe",
            command_line='wolfram.exe -script C:\\Users\\vresh\\AppData\\Local\\Temp\\tungsten-wrapper-abc\\wrapper.wl',
            started_utc="2026-04-24T18:00:00Z",
            tungsten_owned=True,
            headless_batch=True,
            parent_missing=True,
            controlling_process_candidate=True,
        )
        foreign = WolframProcessInfo(
            pid=222,
            parent_pid=0,
            name="wolfram.exe",
            executable_path="C:\\Program Files\\Wolfram Research\\Wolfram\\15.0\\wolfram.exe",
            command_line='wolfram.exe -run "LongComputation[]"',
            started_utc="2026-04-24T18:00:00Z",
            tungsten_owned=False,
            headless_batch=True,
            parent_missing=True,
            controlling_process_candidate=True,
        )
        child_attached = WolframProcessInfo(
            pid=333,
            parent_pid=1234,
            name="wolfram.exe",
            executable_path="C:\\Program Files\\Wolfram Research\\Wolfram\\15.0\\wolfram.exe",
            command_line='wolfram.exe -script C:\\Users\\vresh\\AppData\\Local\\Temp\\tungsten-wrapper-def\\wrapper.wl',
            started_utc="2026-04-24T18:00:00Z",
            tungsten_owned=True,
            headless_batch=True,
            parent_missing=False,
            controlling_process_candidate=True,
        )

        with (
            patch("tungsten.wolfram_processes.list_wolfram_processes", return_value=[stale, foreign, child_attached]),
            patch("tungsten.wolfram_processes.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0
            cleaned = cleanup_stale_tungsten_processes(min_age_seconds=0.0)

        self.assertEqual(cleaned, [111])
        run_mock.assert_called_once()
        self.assertIn("/PID", run_mock.call_args.args[0])
        self.assertIn("111", run_mock.call_args.args[0])

    def test_wait_for_wolfram_license_slot_polls_until_process_count_drops(self) -> None:
        blocked = WolframProcessSnapshot(
            processes=(
                WolframProcessInfo(1, 0, "wolfram.exe", None, None, None, False, True, False, True),
                WolframProcessInfo(2, 0, "Mathematica.exe", None, None, None, False, False, False, True),
            ),
            cached_max_license_processes=2,
        )
        free = WolframProcessSnapshot(
            processes=(WolframProcessInfo(1, 0, "wolfram.exe", None, None, None, False, True, False, True),),
            cached_max_license_processes=2,
        )

        with (
            patch("tungsten.wolfram_processes.snapshot_wolfram_processes", side_effect=[blocked, free]),
            patch("tungsten.wolfram_processes.time.sleep"),
        ):
            snapshot, waited, satisfied = wait_for_wolfram_license_slot(2, timeout_seconds=5.0, poll_seconds=0.01)

        self.assertTrue(satisfied)
        self.assertEqual(snapshot.active_count, 1)
        self.assertGreaterEqual(waited, 0.0)

    def test_helper_kernel_can_exist_without_counting_toward_controlling_limit(self) -> None:
        snapshot = WolframProcessSnapshot(
            processes=(
                WolframProcessInfo(1, 0, "Mathematica.exe", None, None, None, False, False, False, True),
                WolframProcessInfo(2, 1, "WolframKernel.exe", None, None, None, False, False, False, False),
            ),
            cached_max_license_processes=2,
        )

        self.assertEqual(snapshot.active_count, 1)


if __name__ == "__main__":
    unittest.main()
