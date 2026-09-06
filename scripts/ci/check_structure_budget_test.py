#!/usr/bin/env python3
"""Contract tests for structural hotspot ceilings and baseline validation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER_PATH = Path(__file__).with_name("check_structure_budget.py")


def baseline() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "thresholds": {
            "maxCcn": 25,
            "maxNloc": 100,
            "maxPhysicalLines": 1200,
            "maxDirectProductionFiles": 40,
        },
        "files": {
            "libs/legacy/Schema.lua": {
                "classification": "retained-schema-catalog",
                "rationale": "cohesive schema owner",
                "maxCcn": 28,
                "maxNloc": 132,
                "physicalLines": 1500,
            }
        },
        "directories": {
            "libs/legacy": {
                "classification": "refactor",
                "rationale": "mixed-responsibility directory awaiting ownership split",
                "directProductionFiles": 41,
            }
        },
    }


def report(
    *,
    ccn: int = 28,
    nloc: int = 132,
    physical_lines: int = 1500,
    direct_files: int = 41,
    file_path: str = "libs/legacy/Schema.lua",
    directory_path: str = "libs/legacy",
) -> dict[str, object]:
    return {
        "schemaVersion": 4,
        "source": {
            "files": [
                {
                    "path": file_path,
                    "bytes": 9000,
                    "physicalLines": physical_lines,
                }
            ]
        },
        "directories": {
            "files": [
                {"path": directory_path, "directProductionFiles": direct_files}
            ]
        },
        "structure": {
            "files": [
                {
                    "path": file_path,
                    "maxCcn": ccn,
                    "maxNloc": nloc,
                }
            ]
        },
    }


class StructureBudgetTest(unittest.TestCase):
    """Protect fail-closed comparison of generated structure and checked-in ceilings."""

    def run_checker(self, current: dict[str, object], pinned: dict[str, object]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "quality-report.json"
            baseline_path = root / "structure-baseline.json"
            report_path.write_text(json.dumps(current), encoding="utf-8")
            baseline_path.write_text(json.dumps(pinned), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER_PATH),
                    "--report",
                    str(report_path),
                    "--baseline",
                    str(baseline_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_unchanged_grandfathered_ceiling_passes(self) -> None:
        result = self.run_checker(report(), baseline())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_growth_of_one_metric_fails_with_path_and_metric(self) -> None:
        result = self.run_checker(report(ccn=29), baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libs/legacy/Schema.lua", result.stderr + result.stdout)
        self.assertIn("CCN", (result.stderr + result.stdout).upper())

    def test_new_unclassified_file_or_directory_fails(self) -> None:
        current = report()
        current["source"] = {
            "files": [
                {
                    "path": "game/new/Hotspot.lua",
                    "bytes": 1000,
                    "physicalLines": 1201,
                }
            ]
        }
        current["directories"] = {
            "files": [{"path": "game/new", "directProductionFiles": 41}]
        }
        result = self.run_checker(current, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("game/new", result.stderr + result.stdout)

    def test_missing_baseline_file_requires_explicit_deletion(self) -> None:
        pinned = baseline()
        current = report()
        current["source"] = {"files": []}
        current["structure"] = {"files": []}
        result = self.run_checker(current, pinned)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Schema.lua", result.stderr + result.stdout)

        pinned["files"]["libs/legacy/Schema.lua"]["deleted"] = True  # type: ignore[index]
        result = self.run_checker(current, pinned)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_moved_baseline_entry_keeps_its_numeric_ceiling(self) -> None:
        pinned = baseline()
        file_entry = pinned["files"].pop("libs/legacy/Schema.lua")  # type: ignore[union-attr]
        directory_entry = pinned["directories"].pop("libs/legacy")  # type: ignore[union-attr]
        pinned["files"]["libs/moved/Schema.lua"] = file_entry  # type: ignore[index]
        pinned["directories"]["libs/moved"] = directory_entry  # type: ignore[index]
        result = self.run_checker(
            report(file_path="libs/moved/Schema.lua", directory_path="libs/moved"),
            pinned,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_schema_and_duplicate_baseline_entries_fail_closed(self) -> None:
        malformed = baseline()
        malformed["schemaVersion"] = 4
        result = self.run_checker(report(), malformed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("schema", (result.stderr + result.stdout).lower())

        duplicate = baseline()
        duplicate["files"] = [
            {"path": "libs/legacy/Schema.lua", "classification": "refactor"},
            {"path": "libs/legacy/Schema.lua", "classification": "refactor"},
        ]
        result = self.run_checker(report(), duplicate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", (result.stderr + result.stdout).lower())

    def _init_case_repo(self, root: Path, base_baseline: dict[str, object] | None) -> str:
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "structure-test@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Structure Test"], cwd=root, check=True)
        if base_baseline is None:
            (root / "README.md").write_text("base without a checked-in baseline\n", encoding="utf-8")
        else:
            baseline_path = root / "scripts" / "ci" / "structure-baseline.json"
            baseline_path.parent.mkdir(parents=True, exist_ok=True)
            baseline_path.write_text(json.dumps(base_baseline), encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "--quiet", "-m", "base"], cwd=root, check=True)
        resolved = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        return resolved.stdout.strip()

    def run_checker_with_base(
        self,
        current: dict[str, object],
        pinned: dict[str, object],
        base_baseline: dict[str, object] | None,
        base_ref: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resolved = self._init_case_repo(root, base_baseline)
            case_root = root / "case"
            case_root.mkdir()
            report_path = case_root / "quality-report.json"
            baseline_path = case_root / "structure-baseline.json"
            report_path.write_text(json.dumps(current), encoding="utf-8")
            baseline_path.write_text(json.dumps(pinned), encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER_PATH),
                    "--report",
                    str(report_path),
                    "--baseline",
                    str(baseline_path),
                    "--base-ref",
                    base_ref if base_ref is not None else resolved,
                ],
                check=False,
                capture_output=True,
                text=True,
                cwd=root,
            )

    def test_candidate_file_ceiling_above_current_metric_fails(self) -> None:
        result = self.run_checker(report(ccn=26), baseline())
        self.assertNotEqual(result.returncode, 0)
        output = result.stderr + result.stdout
        self.assertIn("libs/legacy/Schema.lua", output)
        self.assertIn("CCN", output.upper())

    def test_candidate_directory_ceiling_above_current_count_fails(self) -> None:
        result = self.run_checker(report(direct_files=40), baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libs/legacy", result.stderr + result.stdout)

    def test_fully_compliant_baseline_entry_fails_until_removed(self) -> None:
        current = report(ccn=5, nloc=10, physical_lines=100, direct_files=1)
        result = self.run_checker(current, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Schema.lua", result.stderr + result.stdout)

    def test_data_only_file_baseline_headroom_over_zero_fails(self) -> None:
        pinned = baseline()
        pinned_files = pinned["files"]
        assert isinstance(pinned_files, dict)
        pinned_files["libs/legacy/Data.lua"] = {
            "classification": "retained-schema-catalog",
            "rationale": "data-only catalog",
            "maxCcn": 5,
            "maxNloc": 10,
            "physicalLines": 500,
        }
        current: dict[str, object] = {
            "schemaVersion": 4,
            "source": {
                "files": [
                    {"path": "libs/legacy/Schema.lua", "bytes": 9000, "physicalLines": 1500},
                    {"path": "libs/legacy/Data.lua", "bytes": 4000, "physicalLines": 500},
                ]
            },
            "directories": {"files": [{"path": "libs/legacy", "directProductionFiles": 41}]},
            "structure": {"files": [{"path": "libs/legacy/Schema.lua", "maxCcn": 28, "maxNloc": 132}]},
        }
        result = self.run_checker(current, pinned)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Data.lua", result.stderr + result.stdout)

    def test_candidate_threshold_increase_over_base_fails(self) -> None:
        pinned = baseline()
        pinned_thresholds = pinned["thresholds"]
        assert isinstance(pinned_thresholds, dict)
        pinned_thresholds["maxCcn"] = 26
        result = self.run_checker_with_base(report(), pinned, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("threshold", (result.stderr + result.stdout).lower())

    def test_candidate_ceiling_increase_over_base_fails_when_candidate_exact(self) -> None:
        pinned = baseline()
        pinned_files = pinned["files"]
        assert isinstance(pinned_files, dict)
        pinned_entry = pinned_files["libs/legacy/Schema.lua"]
        assert isinstance(pinned_entry, dict)
        pinned_entry["maxCcn"] = 30
        result = self.run_checker_with_base(report(ccn=30), pinned, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libs/legacy/Schema.lua", result.stderr + result.stdout)

    def test_equal_or_improved_candidate_ceiling_passes_against_base(self) -> None:
        pinned = baseline()
        pinned_files = pinned["files"]
        assert isinstance(pinned_files, dict)
        pinned_entry = pinned_files["libs/legacy/Schema.lua"]
        assert isinstance(pinned_entry, dict)
        pinned_entry["maxCcn"] = 27
        pinned_entry["maxNloc"] = 130
        pinned_entry["physicalLines"] = 1400
        current = report(ccn=27, nloc=130, physical_lines=1400)
        result = self.run_checker_with_base(current, pinned, baseline())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_valid_base_without_baseline_file_skips_history_but_keeps_exactness(self) -> None:
        exact = self.run_checker_with_base(report(), baseline(), None)
        self.assertEqual(exact.returncode, 0, exact.stderr)
        headroom = self.run_checker_with_base(report(ccn=26), baseline(), None)
        self.assertNotEqual(headroom.returncode, 0)
        self.assertIn("libs/legacy/Schema.lua", headroom.stderr + headroom.stdout)

    def test_invalid_base_ref_fails_closed(self) -> None:
        result = self.run_checker_with_base(report(), baseline(), baseline(), base_ref="not-a-valid-ref")
        self.assertNotEqual(result.returncode, 0)
        output = (result.stderr + result.stdout).lower()
        self.assertIn("invalid", output)
        self.assertIn("base", output)

    def test_new_grandfathered_path_absent_from_base_fails(self) -> None:
        pinned = baseline()
        pinned_files = pinned["files"]
        assert isinstance(pinned_files, dict)
        pinned_files["game/new/Hotspot.lua"] = {
            "classification": "refactor",
            "rationale": "new hotspot",
            "maxCcn": 30,
            "maxNloc": 120,
            "physicalLines": 1300,
        }
        pinned_directories = pinned["directories"]
        assert isinstance(pinned_directories, dict)
        pinned_directories["game/new"] = {
            "classification": "refactor",
            "rationale": "new hotspot",
            "directProductionFiles": 41,
        }
        current: dict[str, object] = {
            "schemaVersion": 4,
            "source": {
                "files": [
                    {"path": "libs/legacy/Schema.lua", "bytes": 9000, "physicalLines": 1500},
                    {"path": "game/new/Hotspot.lua", "bytes": 8000, "physicalLines": 1300},
                ]
            },
            "directories": {
                "files": [
                    {"path": "libs/legacy", "directProductionFiles": 41},
                    {"path": "game/new", "directProductionFiles": 41},
                ]
            },
            "structure": {
                "files": [
                    {"path": "libs/legacy/Schema.lua", "maxCcn": 28, "maxNloc": 132},
                    {"path": "game/new/Hotspot.lua", "maxCcn": 30, "maxNloc": 120},
                ]
            },
        }
        result = self.run_checker_with_base(current, pinned, baseline())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("game/new", result.stderr + result.stdout)

    def test_removed_base_entry_after_improvement_passes(self) -> None:
        pinned = baseline()
        pinned_files = pinned["files"]
        assert isinstance(pinned_files, dict)
        del pinned_files["libs/legacy/Schema.lua"]
        pinned_directories = pinned["directories"]
        assert isinstance(pinned_directories, dict)
        del pinned_directories["libs/legacy"]
        current = report(ccn=5, nloc=10, physical_lines=100, direct_files=1)
        result = self.run_checker_with_base(current, pinned, baseline())
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
