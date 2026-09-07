#!/usr/bin/env python3
"""Compare two structural hotspot snapshots and emit advisory regressions."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


POLICY_METRICS = ("maxCcn", "maxNloc", "physicalLines")
_SCHEMA_VERSION = 1
_EXPECTED_SNAPSHOT_VERSION = 4

_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


def _fail(message: str) -> int:
    print(f"codehealth compare: {message}", file=sys.stderr)
    return 1


def _load_report(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            model = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}: {error}") from error
    if not isinstance(model, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return model


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    return isinstance(value, (int, float))


def _check_metric_value(value: Any, path: Path, row_path: str, metric: str) -> None:
    if value is None:
        return
    if not _is_number(value):
        raise ValueError(f"{path} row {row_path!r} has a non-numeric {metric}")
    if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
        raise ValueError(f"{path} row {row_path!r} has a non-finite {metric}")


def _validate_path(raw: Any, path: Path) -> str:
    if not isinstance(raw, str) or not raw:
        raise ValueError(f"{path} contains an invalid path {raw!r}")
    normalized = raw.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized != raw
        or normalized.startswith("/")
        or ".." in parts
        or any(not part for part in parts)
        or not normalized.endswith(".lua")
    ):
        raise ValueError(f"{path} contains an unsafe or non-Lua path {raw!r}")
    return normalized


def _load_snapshot(path: Path) -> tuple[dict[str, float | int], dict[str, str | int], dict[str, dict[str, Any]]]:
    model = _load_report(path)
    if model.get("schemaVersion") != _EXPECTED_SNAPSHOT_VERSION:
        raise ValueError(f"{path} has an unsupported schemaVersion")
    structure = model.get("structure")
    if not isinstance(structure, dict):
        raise ValueError(f"{path} is missing structure")
    policy = structure.get("hotspotPolicy")
    if not isinstance(policy, dict):
        raise ValueError(f"{path} is missing structure.hotspotPolicy")
    thresholds = policy.get("thresholds")
    if not isinstance(thresholds, dict) or set(thresholds) != set(POLICY_METRICS):
        raise ValueError(f"{path} has an unsupported hotspot threshold map")
    numeric_thresholds: dict[str, float | int] = {}
    for metric in POLICY_METRICS:
        value = thresholds[metric]
        if not _is_number(value):
            raise ValueError(f"{path} has a non-numeric threshold for {metric}")
        if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
            raise ValueError(f"{path} has a non-finite threshold for {metric}")
        numeric_thresholds[metric] = value
    marker = policy.get("ignoreMarker")
    scan_lines = policy.get("ignoreScanLines")
    if not isinstance(marker, str) or not marker:
        raise ValueError(f"{path} has an invalid hotspot ignore marker")
    if isinstance(scan_lines, bool) or not isinstance(scan_lines, int):
        raise ValueError(f"{path} has an invalid hotspot ignore scan window")
    rows = structure.get("files")
    if not isinstance(rows, list):
        raise ValueError(f"{path} is missing structure.files")
    files: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(f"{path} contains an invalid structure row")
        row_path = _validate_path(row.get("path"), path)
        if row_path in files:
            raise ValueError(f"{path} contains a duplicate path {row_path!r}")
        for metric in POLICY_METRICS:
            if metric not in row:
                raise ValueError(f"{path} row {row_path!r} is missing {metric}")
            _check_metric_value(row[metric], path, row_path, metric)
        ignored = row.get("hotspotIgnored")
        if not isinstance(ignored, bool):
            raise ValueError(f"{path} row {row_path!r} has an invalid hotspotIgnored")
        files[row_path] = {
            "path": row_path,
            "maxCcn": row["maxCcn"],
            "maxNloc": row["maxNloc"],
            "physicalLines": row["physicalLines"],
            "hotspotIgnored": ignored,
        }
    return numeric_thresholds, {"ignoreMarker": marker, "ignoreScanLines": scan_lines}, files


def _resolve_ref(repository_root: Path, ref: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", ref],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot resolve git ref {ref!r}: {error}") from error
    sha = result.stdout.strip()
    if not _SHA_RE.match(sha):
        raise ValueError(f"git resolved ref {ref!r} to an invalid SHA {sha!r}")
    return sha.lower()


def _rename_map(repository_root: Path, base_sha: str, head_sha: str) -> dict[str, str]:
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(repository_root),
                "diff",
                "--find-renames=50%",
                "--name-status",
                "-z",
                base_sha,
                head_sha,
                "--",
                "*.lua",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot determine rename identity: {error}") from error
    raw = result.stdout
    if not raw:
        return {}
    tokens = raw.split("\0")
    if tokens and tokens[-1] == "":
        tokens.pop()
    mapping: dict[str, str] = {}
    index = 0
    while index < len(tokens):
        status = tokens[index]
        index += 1
        if not status:
            raise ValueError("malformed rename detection output")
        kind = status[0]
        if kind in ("R", "C"):
            if index + 1 >= len(tokens):
                raise ValueError("malformed rename detection output")
            old_path = tokens[index]
            new_path = tokens[index + 1]
            index += 2
            if not old_path or not new_path:
                raise ValueError("malformed rename detection output")
            mapping[new_path] = old_path
        else:
            if index >= len(tokens):
                raise ValueError("malformed rename detection output")
            index += 1
    return mapping


def _compare(
    thresholds: dict[str, float | int],
    base_files: dict[str, dict[str, Any]],
    head_files: dict[str, dict[str, Any]],
    renames: dict[str, str],
) -> list[dict[str, Any]]:
    regressions: list[dict[str, Any]] = []
    for head_path in sorted(head_files):
        head_row = head_files[head_path]
        if head_row["hotspotIgnored"]:
            continue
        base_path = renames.get(head_path, head_path)
        base_row = base_files.get(base_path)
        for metric in POLICY_METRICS:
            head_value = head_row[metric]
            if head_value is None:
                continue
            threshold = thresholds[metric]
            if not head_value > threshold:
                continue
            if base_row is None:
                regressions.append(
                    {
                        "path": head_path,
                        "metric": metric,
                        "threshold": threshold,
                        "base": None,
                        "head": head_value,
                        "kind": "new-hotspot",
                    }
                )
                continue
            base_value = base_row[metric]
            if base_value is None:
                regressions.append(
                    {
                        "path": head_path,
                        "metric": metric,
                        "threshold": threshold,
                        "base": None,
                        "head": head_value,
                        "kind": "new-hotspot",
                    }
                )
            elif head_value > base_value:
                regressions.append(
                    {
                        "path": head_path,
                        "metric": metric,
                        "threshold": threshold,
                        "base": base_value,
                        "head": head_value,
                        "kind": "worsened",
                    }
                )
    regressions.sort(key=lambda row: (row["path"], row["metric"]))
    return regressions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-report", type=Path, required=True)
    parser.add_argument("--head-report", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--head-ref", required=True)
    parser.add_argument("--pull-request", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        pull_request = int(args.pull_request)
    except (TypeError, ValueError):
        return _fail(f"invalid pull request number {args.pull_request!r}")
    if pull_request <= 0:
        return _fail(f"invalid pull request number {args.pull_request!r}")
    repository_root = args.repository_root.resolve()
    if not repository_root.is_dir():
        return _fail(f"repository root {args.repository_root} is not a directory")
    try:
        base_thresholds, base_marker, base_files = _load_snapshot(args.base_report)
        head_thresholds, head_marker, head_files = _load_snapshot(args.head_report)
        if base_thresholds != head_thresholds:
            raise ValueError("hotspot threshold maps differ between base and head reports")
        if base_marker != head_marker:
            raise ValueError("hotspot marker metadata differs between base and head reports")
        base_sha = _resolve_ref(repository_root, args.base_ref)
        head_sha = _resolve_ref(repository_root, args.head_ref)
        renames = _rename_map(repository_root, base_sha, head_sha)
        regressions = _compare(head_thresholds, base_files, head_files, renames)
        model = {
            "schemaVersion": _SCHEMA_VERSION,
            "pullRequest": pull_request,
            "baseSha": base_sha,
            "headSha": head_sha,
            "regressions": regressions,
        }
        args.output.write_text(
            json.dumps(model, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except (OSError, ValueError) as error:
        return _fail(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
