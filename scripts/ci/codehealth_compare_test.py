#!/usr/bin/env python3
"""Tests for the pull-request structural hotspot comparator."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("codehealth_compare.py")

DEFAULT_THRESHOLDS = {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200}
METRICS = ("maxCcn", "maxNloc", "physicalLines")


def _row(path, max_ccn=None, max_nloc=None, physical_lines=None, ignored=False):
    return {
        "path": path,
        "maxCcn": max_ccn,
        "maxNloc": max_nloc,
        "physicalLines": physical_lines,
        "hotspotIgnored": ignored,
    }


def _write_snapshot(path, rows, thresholds=None):
    policy_thresholds = dict(thresholds) if thresholds is not None else dict(DEFAULT_THRESHOLDS)
    model = {
        "schemaVersion": 4,
        "structure": {
            "files": list(rows),
            "hotspotPolicy": {
                "thresholds": policy_thresholds,
                "ignoreMarker": "-- codehealth: ignore-hotspot",
                "ignoreScanLines": 5,
            },
        },
    }
    Path(path).write_text(json.dumps(model) + "\n", encoding="utf-8")


def _init_repo(directory, files):
    root = Path(directory) / "repo"
    root.mkdir()
    for relative, content in files.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "compare-test@example.com"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "Compare Test"], cwd=root, check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "--quiet", "-m", "base"], cwd=root, check=True)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()
    return root, sha


def _run_compare(root, base_report, head_report, base_ref, head_ref, output, pull_request=42):
    return subprocess.run(
        [
            sys.executable,
            str(MODULE_PATH),
            "--base-report",
            str(base_report),
            "--head-report",
            str(head_report),
            "--repository-root",
            str(root),
            "--base-ref",
            base_ref,
            "--head-ref",
            head_ref,
            "--pull-request",
            str(pull_request),
            "--output",
            str(output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _read_result(output):
    return json.loads(Path(output).read_text(encoding="utf-8"))


class HotspotCompareTest(unittest.TestCase):
    def test_only_worsening_above_threshold_metrics_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(
                base_report,
                [
                    _row("game/improved.lua", 30, 10, 10),
                    _row("game/unchanged.lua", 30, 10, 10),
                    _row("game/below.lua", 10, 10, 10),
                    _row("game/crossing.lua", 20, 10, 10),
                    _row("game/worsened.lua", 30, 10, 10),
                ],
            )
            _write_snapshot(
                head_report,
                [
                    _row("game/improved.lua", 26, 10, 10),
                    _row("game/unchanged.lua", 30, 10, 10),
                    _row("game/below.lua", 20, 10, 10),
                    _row("game/crossing.lua", 26, 10, 10),
                    _row("game/worsened.lua", 35, 10, 10),
                ],
            )
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(model["schemaVersion"], 1)
            self.assertEqual(model["pullRequest"], 42)
            self.assertEqual(
                [(row["path"], row["metric"]) for row in model["regressions"]],
                [("game/crossing.lua", "maxCcn"), ("game/worsened.lua", "maxCcn")],
            )
            by_path = {row["path"]: row for row in model["regressions"]}
            self.assertEqual(by_path["game/crossing.lua"]["kind"], "worsened")
            self.assertEqual(by_path["game/crossing.lua"]["base"], 20)
            self.assertEqual(by_path["game/crossing.lua"]["head"], 26)
            self.assertEqual(by_path["game/crossing.lua"]["threshold"], 25)
            self.assertEqual(by_path["game/worsened.lua"]["base"], 30)
            self.assertEqual(by_path["game/worsened.lua"]["head"], 35)

    def test_candidate_only_file_reports_new_hotspot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/a.lua", 5, 10, 10)])
            _write_snapshot(
                head_report,
                [_row("game/a.lua", 5, 10, 10), _row("game/added.lua", None, None, 1300)],
            )
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(len(model["regressions"]), 1)
            row = model["regressions"][0]
            self.assertEqual(row["path"], "game/added.lua")
            self.assertEqual(row["metric"], "physicalLines")
            self.assertEqual(row["threshold"], 1200)
            self.assertIsNone(row["base"])
            self.assertEqual(row["head"], 1300)
            self.assertEqual(row["kind"], "new-hotspot")

    def test_recognized_rename_keeps_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            body = "".join(f"-- filler {index}\n" for index in range(60)) + "return {}\n"
            (root / "game").mkdir(parents=True)
            (root / "game" / "before.lua").write_text(body, encoding="utf-8")
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "compare-test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Compare Test"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "base"], cwd=root, check=True)
            base_sha = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True
            ).stdout.strip()
            subprocess.run(["git", "mv", "game/before.lua", "game/after.lua"], cwd=root, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "rename"], cwd=root, check=True)
            head_sha = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True
            ).stdout.strip()
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            output = Path(directory) / "result.json"
            _write_snapshot(base_report, [_row("game/before.lua", 30, 10, 10)])
            _write_snapshot(head_report, [_row("game/after.lua", 30, 10, 10)])
            result = _run_compare(root, base_report, head_report, base_sha, head_sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(_read_result(output)["regressions"], [])
            _write_snapshot(head_report, [_row("game/after.lua", 34, 10, 10)])
            result = _run_compare(root, base_report, head_report, base_sha, head_sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(len(model["regressions"]), 1)
            row = model["regressions"][0]
            self.assertEqual(row["path"], "game/after.lua")
            self.assertEqual(row["metric"], "maxCcn")
            self.assertEqual(row["base"], 30)
            self.assertEqual(row["head"], 34)
            self.assertEqual(row["kind"], "worsened")

    def test_candidate_ignore_marker_suppresses_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/hot.lua", 20, 10, 10)])
            _write_snapshot(head_report, [_row("game/hot.lua", 40, 10, 10, ignored=True)])
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(_read_result(output)["regressions"], [])

    def test_mismatched_threshold_maps_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/a.lua", 5, 10, 10)])
            _write_snapshot(
                head_report,
                [_row("game/a.lua", 5, 10, 10)],
                thresholds={"maxCcn": 26, "maxNloc": 100, "physicalLines": 1200},
            )
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertNotEqual(result.returncode, 0)

    def test_unsafe_duplicate_and_non_lua_paths_fail(self) -> None:
        bad_cases = (
            [_row("/game/a.lua", 30, 10, 10)],
            [_row("../game/a.lua", 30, 10, 10)],
            [_row("game/a.lua", 30, 10, 10), _row("game/a.lua", 31, 10, 10)],
            [_row("game/a.txt", 30, 10, 10)],
        )
        for rows in bad_cases:
            with self.subTest(rows=[row["path"] for row in rows]):
                with tempfile.TemporaryDirectory() as directory:
                    root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
                    base_report = Path(directory) / "base.json"
                    head_report = Path(directory) / "head.json"
                    _write_snapshot(base_report, [_row("game/a.lua", 5, 10, 10)])
                    _write_snapshot(head_report, rows)
                    output = Path(directory) / "result.json"
                    result = _run_compare(root, base_report, head_report, sha, sha, output)
                    self.assertNotEqual(result.returncode, 0)

    def test_results_are_deterministically_ordered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(
                base_report,
                [_row("game/zeta.lua", 20, 10, 10), _row("game/alpha.lua", 20, 90, 1000)],
            )
            _write_snapshot(
                head_report,
                [_row("game/alpha.lua", 40, 150, 1300), _row("game/zeta.lua", 40, 10, 10)],
            )
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            result = _run_compare(root, base_report, head_report, sha, sha, first)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            result = _run_compare(root, base_report, head_report, sha, sha, second)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                first.read_text(encoding="utf-8"),
                second.read_text(encoding="utf-8"),
            )
            keys = [
                (row["path"], row["metric"]) for row in _read_result(first)["regressions"]
            ]
            self.assertEqual(keys, sorted(keys))
            self.assertEqual(
                keys,
                [
                    ("game/alpha.lua", "maxCcn"),
                    ("game/alpha.lua", "maxNloc"),
                    ("game/alpha.lua", "physicalLines"),
                    ("game/zeta.lua", "maxCcn"),
                ],
            )

    def test_head_equal_to_threshold_is_not_regression(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/a.lua", 20, 10, 10)])
            _write_snapshot(head_report, [_row("game/a.lua", 25, 10, 10)])
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(_read_result(output)["regressions"], [])

    def test_multiple_metrics_per_file_yield_independent_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/hot.lua", 26, 90, 1000)])
            _write_snapshot(head_report, [_row("game/hot.lua", 30, 150, 1300)])
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(
                [(row["metric"], row["threshold"]) for row in model["regressions"]],
                [("maxCcn", 25), ("maxNloc", 100), ("physicalLines", 1200)],
            )
            for row in model["regressions"]:
                self.assertEqual(row["path"], "game/hot.lua")
                self.assertEqual(row["kind"], "worsened")
                self.assertGreater(row["head"], row["base"])
                self.assertGreater(row["head"], row["threshold"])

    def test_only_candidate_ignore_state_controls_suppression(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/hot.lua", 20, 10, 10, ignored=True)])
            _write_snapshot(head_report, [_row("game/hot.lua", 40, 10, 10, ignored=False)])
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(len(model["regressions"]), 1)
            self.assertEqual(model["regressions"][0]["path"], "game/hot.lua")

    def test_invalid_git_refs_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            _write_snapshot(base_report, [_row("game/a.lua", 5, 10, 10)])
            _write_snapshot(head_report, [_row("game/a.lua", 5, 10, 10)])
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, "not-a-ref", sha, output)
            self.assertNotEqual(result.returncode, 0)
            result = _run_compare(root, base_report, head_report, sha, "missing-ref", output)
            self.assertNotEqual(result.returncode, 0)

    def test_report_thresholds_drive_classification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, sha = _init_repo(directory, {"game/a.lua": "return {}\n"})
            base_report = Path(directory) / "base.json"
            head_report = Path(directory) / "head.json"
            custom = {"maxCcn": 10, "maxNloc": 20, "physicalLines": 30}
            _write_snapshot(base_report, [_row("game/a.lua", 9, 10, 10)], thresholds=custom)
            _write_snapshot(head_report, [_row("game/a.lua", 11, 10, 10)], thresholds=custom)
            output = Path(directory) / "result.json"
            result = _run_compare(root, base_report, head_report, sha, sha, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_result(output)
            self.assertEqual(len(model["regressions"]), 1)
            self.assertEqual(model["regressions"][0]["threshold"], 10)
            self.assertEqual(model["regressions"][0]["metric"], "maxCcn")


if __name__ == "__main__":
    unittest.main()
