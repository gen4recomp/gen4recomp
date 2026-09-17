#!/usr/bin/env python3
"""Tests for the compact versioned code-health history helper."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("codehealth_history.py")
MODULE_SPEC = importlib.util.spec_from_file_location("codehealth_history", MODULE_PATH)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
HISTORY = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(HISTORY)


def _entry(commit: str, committed: str, analyzed: str, **overrides: object) -> dict:
    base: dict = {
        "commit": commit,
        "committedAt": committed,
        "analyzedAt": analyzed,
        "files": 10,
        "physicalLines": 200,
        "functions": 30,
        "erosion": 0.25,
        "duplicationPercentage": 4.5,
        "ccnP95": 6,
        "ccnP99": 12,
        "importCycleGroups": 1,
        "fanOutP95": 3,
        "fanOutP99": 5,
    }
    base.update(overrides)
    return base


FIRST = "a" * 40
SECOND = "b" * 40
THIRD = "c" * 40


class CodeHealthHistoryTest(unittest.TestCase):
    """Protect compact history validation, upsert, ordering, and lookup."""

    def test_empty_previous_history_starts_single_entry(self) -> None:
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z")
        merged = HISTORY.merge(None, current)
        self.assertEqual(merged["schemaVersion"], 1)
        self.assertEqual(merged["measurementVersion"], 1)
        self.assertEqual(merged["entries"], [current])

    def test_compatible_history_appends_and_orders_by_commit_time(self) -> None:
        previous = {
            "schemaVersion": 1,
            "measurementVersion": 1,
            "entries": [
                _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"),
            ],
        }
        current = _entry(FIRST, "2026-01-01T00:00:00Z", "2026-03-02T00:00:00Z")
        merged = HISTORY.merge(previous, current)
        self.assertEqual([row["commit"] for row in merged["entries"]], [FIRST, SECOND])

    def test_same_commit_rerun_replaces_entry_without_growing_history(self) -> None:
        previous = {
            "schemaVersion": 1,
            "measurementVersion": 1,
            "entries": [
                _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z", erosion=0.1),
            ],
        }
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-05T00:00:00Z", erosion=0.2)
        merged = HISTORY.merge(previous, current)
        self.assertEqual(len(merged["entries"]), 1)
        self.assertEqual(merged["entries"][0]["erosion"], 0.2)
        self.assertEqual(merged["entries"][0]["analyzedAt"], "2026-03-05T00:00:00Z")

    def test_same_commit_time_sorts_deterministically_by_sha(self) -> None:
        previous = {
            "schemaVersion": 1,
            "measurementVersion": 1,
            "entries": [
                _entry(THIRD, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"),
            ],
        }
        current = _entry(FIRST, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z")
        merged = HISTORY.merge(previous, current)
        self.assertEqual([row["commit"] for row in merged["entries"]], [FIRST, THIRD])

    def test_mixed_utc_offsets_order_by_instant_not_lexical_string(self) -> None:
        previous = {
            "schemaVersion": 1,
            "measurementVersion": 1,
            "entries": [
                _entry(SECOND, "2026-02-01T17:00:00-03:00", "2026-03-01T00:00:00Z"),
            ],
        }
        current = _entry(FIRST, "2026-02-01T20:00:00+02:00", "2026-03-02T00:00:00Z")
        merged = HISTORY.merge(previous, current)
        self.assertEqual([row["commit"] for row in merged["entries"]], [FIRST, SECOND])

    def test_previous_entry_selects_immediately_preceding_commit(self) -> None:
        history = {
            "schemaVersion": 1,
            "measurementVersion": 1,
            "entries": [
                _entry(FIRST, "2026-01-01T00:00:00Z", "2026-03-01T00:00:00Z"),
                _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z"),
                _entry(THIRD, "2026-03-01T00:00:00Z", "2026-03-03T00:00:00Z"),
            ],
        }
        self.assertEqual(HISTORY.previous_entry(history, THIRD)["commit"], SECOND)
        self.assertIsNone(HISTORY.previous_entry(history, FIRST))

    def test_incompatible_schema_version_is_rejected(self) -> None:
        previous = {
            "schemaVersion": 2,
            "measurementVersion": 1,
            "entries": [_entry(FIRST, "2026-01-01T00:00:00Z", "2026-03-01T00:00:00Z")],
        }
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z")
        with self.assertRaises(ValueError):
            HISTORY.merge(previous, current)

    def test_incompatible_measurement_version_is_rejected(self) -> None:
        previous = {
            "schemaVersion": 1,
            "measurementVersion": 2,
            "entries": [_entry(FIRST, "2026-01-01T00:00:00Z", "2026-03-01T00:00:00Z")],
        }
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z")
        with self.assertRaises(ValueError):
            HISTORY.merge(previous, current)

    def test_malformed_commit_sha_is_rejected(self) -> None:
        current = _entry("not-a-sha", "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z")
        with self.assertRaises(ValueError):
            HISTORY.merge(None, current)

    def test_malformed_timestamp_is_rejected(self) -> None:
        current = _entry(SECOND, "sometime", "2026-03-02T00:00:00Z")
        with self.assertRaises(ValueError):
            HISTORY.merge(None, current)

    def test_nonfinite_metric_is_rejected(self) -> None:
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z", erosion=float("inf"))
        with self.assertRaises(ValueError):
            HISTORY.merge(None, current)

    def test_boolean_metric_is_rejected(self) -> None:
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z", functions=True)
        with self.assertRaises(ValueError):
            HISTORY.merge(None, current)

    def test_missing_required_field_is_rejected(self) -> None:
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-02T00:00:00Z")
        del current["fanOutP99"]
        with self.assertRaises(ValueError):
            HISTORY.merge(None, current)

    def test_history_file_round_trip_preserves_entries(self) -> None:
        current = _entry(SECOND, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z")
        merged = HISTORY.merge(None, current)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            path.write_text(json.dumps(merged), encoding="utf-8")
            reloaded = HISTORY.merge(
                json.loads(path.read_text(encoding="utf-8")),
                _entry(FIRST, "2026-01-01T00:00:00Z", "2026-03-02T00:00:00Z"),
            )
        self.assertEqual([row["commit"] for row in reloaded["entries"]], [FIRST, SECOND])


class PublishedBootstrapSourceTest(unittest.TestCase):
    """Decide the Pages history continuation from downloaded published state.

    The workflow fetches the live history and quality report over HTTP and
    passes the parsed bodies here; no networking happens in this helper.
    A missing report is passed as None. Returning a SHA means the caller
    must reanalyze that source commit with current tooling and reuse the
    resulting history. Returning None means the current build starts its
    own one-entry history. Raising ValueError fails the run closed.
    """

    def test_absent_report_starts_current_only_history(self) -> None:
        self.assertIsNone(HISTORY.published_bootstrap_source(None))

    def test_report_without_measurement_version_yields_bootstrap_commit(self) -> None:
        report = {"commit": FIRST, "generatedAt": "2026-01-01T00:00:00Z"}
        self.assertEqual(HISTORY.published_bootstrap_source(report), FIRST)

    def test_report_with_current_measurement_version_fails_closed(self) -> None:
        report = {
            "commit": FIRST,
            "measurementVersion": 1,
            "generatedAt": "2026-01-01T00:00:00Z",
        }
        with self.assertRaises(ValueError):
            HISTORY.published_bootstrap_source(report)

    def test_report_with_malformed_commit_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            HISTORY.published_bootstrap_source({"commit": "not-a-sha"})
        with self.assertRaises(ValueError):
            HISTORY.published_bootstrap_source({})
        with self.assertRaises(ValueError):
            HISTORY.published_bootstrap_source([])

    def test_report_with_mismatched_measurement_version_is_rejected(self) -> None:
        report = {"commit": FIRST, "measurementVersion": 2}
        with self.assertRaises(ValueError):
            HISTORY.published_bootstrap_source(report)


class PublishedBootstrapSourceCommandTest(unittest.TestCase):
    """Exercise the report-inspection entrypoint used by Pages orchestration."""

    def run_command(self, body: str, *arguments: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            report.write_text(body, encoding="utf-8")
            containing = Path(directory)
            resolved = [
                str(containing / argument) if argument == "report.json" else argument
                for argument in arguments
            ]
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = HISTORY.main(resolved)
            return status, output.getvalue()

    def test_old_report_prints_bootstrap_commit(self) -> None:
        status, output = self.run_command(
            json.dumps({"commit": FIRST}), "published-bootstrap-source", "report.json"
        )
        self.assertEqual(status, 0)
        self.assertEqual(output.strip(), FIRST)

    def test_current_report_fails_closed(self) -> None:
        status, _ = self.run_command(
            json.dumps({"commit": FIRST, "measurementVersion": 1}),
            "published-bootstrap-source",
            "report.json",
        )
        self.assertEqual(status, 1)

    def test_malformed_report_fails_closed(self) -> None:
        status, _ = self.run_command(
            "not json", "published-bootstrap-source", "report.json"
        )
        self.assertEqual(status, 1)

    def test_missing_report_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = str(Path(directory) / "absent.json")
            self.assertEqual(HISTORY.main(["published-bootstrap-source", missing]), 1)

    def test_unknown_command_is_rejected(self) -> None:
        self.assertEqual(HISTORY.main([]), 2)
        self.assertEqual(HISTORY.main(["unknown"]), 2)


if __name__ == "__main__":
    unittest.main()
