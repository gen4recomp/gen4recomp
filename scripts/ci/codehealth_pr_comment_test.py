#!/usr/bin/env python3
"""Tests for the trusted hotspot advisory publication helper."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("codehealth_pr_comment.py")

HEAD_A = "a" * 40
HEAD_B = "b" * 40
BASE_C = "c" * 40

MARKER = "<!-- gen4recomp-codehealth-hotspot-advisory -->"


def _regression(path="game/hot.lua", metric="maxCcn", threshold=25, base=20, head=30, kind="worsened"):
    return {
        "path": path,
        "metric": metric,
        "threshold": threshold,
        "base": base,
        "head": head,
        "kind": kind,
    }


def _write_artifact(path, pull_request=42, base_sha=BASE_C, head_sha=HEAD_A, regressions=None):
    if regressions is None:
        regressions = [_regression()]
    model = {
        "schemaVersion": 1,
        "pullRequest": pull_request,
        "baseSha": base_sha,
        "headSha": head_sha,
        "regressions": regressions,
    }
    Path(path).write_text(json.dumps(model) + "\n", encoding="utf-8")


def _run_helper(artifact, run_head_sha, associated, output):
    return subprocess.run(
        [
            sys.executable,
            str(MODULE_PATH),
            "--artifact",
            str(artifact),
            "--run-head-sha",
            run_head_sha,
            "--associated-pull-requests",
            json.dumps(associated),
            "--output",
            str(output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _read_output(output):
    return json.loads(Path(output).read_text(encoding="utf-8"))


class AdvisoryPublicationTest(unittest.TestCase):
    def test_valid_artifact_renders_existing_advisory_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact)
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_output(output)
            self.assertEqual(model["pullRequest"], 42)
            self.assertEqual(model["baseSha"], BASE_C)
            self.assertEqual(model["headSha"], HEAD_A)
            self.assertEqual(len(model["regressions"]), 1)
            body = model["body"]
            self.assertIn(MARKER, body)
            self.assertIn("### Structural hotspot advisory", body)
            self.assertIn("| File | Metric | Base | PR | Status | Threshold |", body)
            self.assertIn("`game/hot.lua`", body)

    def test_artifact_for_unassociated_pull_request_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact, pull_request=42, head_sha=HEAD_A)
            result = _run_helper(artifact, HEAD_A, [{"number": 41}], output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_associated_list_may_contain_other_numbers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact, pull_request=42, head_sha=HEAD_A)
            result = _run_helper(artifact, HEAD_A, [{"number": 41}, {"number": 42}], output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(_read_output(output)["pullRequest"], 42)

    def test_head_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact, pull_request=42, head_sha=HEAD_B)
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_empty_association_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact, pull_request=42, head_sha=HEAD_A)
            result = _run_helper(artifact, HEAD_A, [], output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_markdown_control_characters_in_path_are_rejected(self) -> None:
        bad_fragments = ("\n", "\r", "`", "|", "<", ">", "&")
        for fragment in bad_fragments:
            with self.subTest(fragment=repr(fragment)):
                with tempfile.TemporaryDirectory() as directory:
                    artifact = Path(directory) / "result.json"
                    output = Path(directory) / "publication.json"
                    _write_artifact(
                        artifact,
                        regressions=[_regression(path=f"game/ho{fragment}t.lua")],
                    )
                    result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())

    def test_rows_are_sorted_by_path_then_metric(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            rows = [
                _regression(path="game/zeta.lua", metric="maxCcn", base=20, head=30),
                _regression(path="game/alpha.lua", metric="physicalLines", threshold=1200, base=1000, head=1300),
                _regression(path="game/alpha.lua", metric="maxCcn", base=20, head=30),
            ]
            _write_artifact(artifact, regressions=rows)
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], first)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            _write_artifact(artifact, regressions=list(reversed(rows)))
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], second)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            first_body = _read_output(first)["body"]
            second_body = _read_output(second)["body"]
            self.assertEqual(first_body, second_body)
            keys = [(row["path"], row["metric"]) for row in _read_output(first)["regressions"]]
            self.assertEqual(keys, sorted(keys))

    def test_zero_regressions_yields_null_body_with_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(artifact, regressions=[])
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_output(output)
            self.assertIsNone(model["body"])
            self.assertEqual(model["pullRequest"], 42)
            self.assertEqual(model["baseSha"], BASE_C)
            self.assertEqual(model["headSha"], HEAD_A)
            self.assertEqual(model["regressions"], [])

    def test_non_numeric_and_bad_relationship_rows_are_rejected(self) -> None:
        bad_rows = [
            _regression(threshold=True),
            _regression(head=True),
            _regression(base=True, kind="worsened"),
            _regression(kind="new-hotspot", base=20),
            _regression(kind="worsened", base=30, head=30),
            _regression(metric="maxCcn", threshold=25, base=20, head=25),
            _regression(metric="notAMetric"),
            _regression(kind="improved"),
        ]
        for row in bad_rows:
            with self.subTest(row=row):
                with tempfile.TemporaryDirectory() as directory:
                    artifact = Path(directory) / "result.json"
                    output = Path(directory) / "publication.json"
                    _write_artifact(artifact, regressions=[row])
                    result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())

    def test_new_hotspot_with_null_base_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            _write_artifact(
                artifact,
                regressions=[_regression(kind="new-hotspot", base=None, head=1300,
                                        metric="physicalLines", threshold=1200)],
            )
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = _read_output(output)
            self.assertEqual(model["regressions"][0]["kind"], "new-hotspot")
            self.assertIsNone(model["regressions"][0]["base"])
            self.assertIn("—", model["body"])

    def test_unsupported_schema_version_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "result.json"
            output = Path(directory) / "publication.json"
            model = {
                "schemaVersion": 2,
                "pullRequest": 42,
                "baseSha": BASE_C,
                "headSha": HEAD_A,
                "regressions": [],
            }
            artifact.write_text(json.dumps(model) + "\n", encoding="utf-8")
            result = _run_helper(artifact, HEAD_A, [{"number": 42}], output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
