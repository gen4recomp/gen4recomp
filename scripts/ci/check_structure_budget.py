#!/usr/bin/env python3
"""Compare the current code-health structure with checked-in ceilings."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
from pathlib import Path
import sys
from typing import Any


BASELINE_RELATIVE_PATH = "scripts/ci/structure-baseline.json"


CLASSIFICATIONS = {"refactor", "retained-schema-catalog", "retained-algorithm", "retained-state-owner"}
THRESHOLD_FIELDS = ("maxCcn", "maxNloc", "maxPhysicalLines", "maxDirectProductionFiles")


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def _integer(value: Any, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{context} must be a non-negative integer")
    return value


def _entries(value: Any, name: str) -> dict[str, dict[str, Any]]:
    if isinstance(value, dict):
        raw_entries = [{"path": path, **entry} for path, entry in value.items() if isinstance(entry, dict)]
        if len(raw_entries) != len(value):
            raise ValueError(f"{name} entries must be objects")
    elif isinstance(value, list):
        raw_entries = value
    else:
        raise ValueError(f"{name} must be an object or array")
    result: dict[str, dict[str, Any]] = {}
    for entry in raw_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str) or not entry["path"]:
            raise ValueError(f"{name} contains an invalid path entry")
        path = entry["path"].replace("\\", "/")
        parts = path.split("/")
        if path.startswith("/") or ".." in parts or any(not part for part in parts):
            raise ValueError(f"{name} contains a non-portable path {path!r}")
        if path in result:
            raise ValueError(f"duplicate {name} path {path}")
        result[path] = entry
    return result


def _validate_baseline(baseline: dict[str, Any]) -> tuple[dict[str, int], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    if baseline.get("schemaVersion") != 1:
        raise ValueError("baseline schemaVersion must be 1")
    thresholds = baseline.get("thresholds")
    if not isinstance(thresholds, dict):
        raise ValueError("baseline thresholds must be an object")
    normalized_thresholds: dict[str, int] = {}
    for field in THRESHOLD_FIELDS:
        if field not in thresholds:
            raise ValueError(f"baseline thresholds missing {field}")
        normalized_thresholds[field] = _integer(thresholds[field], f"baseline threshold {field}")
    files = _entries(baseline.get("files"), "baseline files")
    directories = _entries(baseline.get("directories"), "baseline directories")
    for collection_name, collection in (("file", files), ("directory", directories)):
        for path, entry in collection.items():
            if entry.get("deleted") is True:
                continue
            if entry.get("classification") not in CLASSIFICATIONS:
                raise ValueError(f"{collection_name} baseline entry {path} has invalid classification")
            if not isinstance(entry.get("rationale"), str) or not entry["rationale"].strip():
                raise ValueError(f"{collection_name} baseline entry {path} needs a rationale")
            required = ("maxCcn", "maxNloc", "physicalLines") if collection_name == "file" else ("directProductionFiles",)
            for field in required:
                if field not in entry:
                    raise ValueError(f"{collection_name} baseline entry {path} missing {field}")
                _integer(entry[field], f"baseline {collection_name} {path} {field}")
    return normalized_thresholds, files, directories


def _validate_report(report: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    if report.get("schemaVersion") != 4:
        raise ValueError("quality report schemaVersion must be 4")
    source = report.get("source")
    directories = report.get("directories")
    structure = report.get("structure")
    if not isinstance(source, dict) or not isinstance(directories, dict) or not isinstance(structure, dict):
        raise ValueError("quality report must contain source, directories, and structure objects")
    source_files = _entries(source.get("files"), "report source files")
    structure_files = _entries(structure.get("files"), "report structure files")
    directory_entries = _entries(directories.get("files"), "report directories")
    for path, entry in source_files.items():
        _integer(entry.get("bytes"), f"report source {path} bytes")
        _integer(entry.get("physicalLines"), f"report source {path} physicalLines")
    for path, entry in structure_files.items():
        for field in ("maxCcn", "maxNloc"):
            if entry.get(field) is not None:
                value = entry[field]
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise ValueError(f"report structure {path} {field} must be non-negative numeric")
    for path, entry in directory_entries.items():
        _integer(entry.get("directProductionFiles"), f"report directory {path} directProductionFiles")
    all_files: dict[str, dict[str, Any]] = {}
    for path, entry in source_files.items():
        all_files[path] = dict(entry)
    for path, entry in structure_files.items():
        all_files.setdefault(path, {}).update(entry)
    return all_files, directory_entries


def _metric_or_zero(entry: dict[str, Any], field: str) -> int | float:
    value = entry.get(field)
    if value is None:
        return 0
    assert isinstance(value, (int, float))
    return value


def _load_base_baseline(ref: str) -> dict[str, Any] | None:
    resolved = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
        check=False,
        capture_output=True,
        text=True,
    )
    commit = (resolved.stdout or "").strip()
    if resolved.returncode != 0 or not commit:
        raise ValueError(f"invalid base ref {ref!r}: no such commit")
    shown = subprocess.run(
        ["git", "show", f"{commit}:{BASELINE_RELATIVE_PATH}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if shown.returncode != 0:
        return None
    try:
        value = json.loads(shown.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"base baseline at {ref} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"base baseline at {ref} must contain a JSON object")
    return value


def check(
    report: dict[str, Any],
    baseline: dict[str, Any],
    base_baseline: dict[str, Any] | None = None,
) -> list[str]:
    thresholds, baseline_files, baseline_directories = _validate_baseline(baseline)
    current_files, current_directories = _validate_report(report)
    findings: list[str] = []

    for path, entry in sorted(baseline_files.items()):
        if entry.get("deleted") is not True and path not in current_files:
            findings.append(f"missing baseline file without explicit deletion: {path}")
    for path, entry in sorted(baseline_directories.items()):
        if entry.get("deleted") is not True and path not in current_directories:
            findings.append(f"missing baseline directory without explicit deletion: {path}")

    for path, entry in sorted(current_files.items()):
        physical_lines = entry.get("physicalLines")
        current_baseline = baseline_files.get(path)
        if current_baseline is None:
            if physical_lines is not None and physical_lines > thresholds["maxPhysicalLines"]:
                findings.append(f"unclassified file hotspot: {path} physicalLines={physical_lines}")
            for field, label in (("maxCcn", "CCN"), ("maxNloc", "NLOC")):
                value = entry.get(field)
                if value is not None and value > thresholds[field]:
                    findings.append(f"unclassified file hotspot: {path} {label}={value}")
            continue
        if current_baseline.get("deleted") is True:
            findings.append(f"current file is marked deleted in baseline: {path}")
            continue
        current_ccn = _metric_or_zero(entry, "maxCcn")
        current_nloc = _metric_or_zero(entry, "maxNloc")
        for field, label, current_value in (
            ("maxCcn", "CCN", current_ccn),
            ("maxNloc", "NLOC", current_nloc),
        ):
            if current_value != current_baseline[field]:
                findings.append(
                    f"file baseline is not exact: {path} {label} current={current_value} ceiling={current_baseline[field]}"
                )
        if physical_lines is not None and physical_lines != current_baseline["physicalLines"]:
            if physical_lines > current_baseline["physicalLines"]:
                findings.append(
                    f"file ceiling exceeded: {path} physicalLines={physical_lines} ceiling={current_baseline['physicalLines']}"
                )
            else:
                findings.append(
                    f"file baseline is not exact: {path} physicalLines current={physical_lines} ceiling={current_baseline['physicalLines']}"
                )
        if (
            current_ccn <= thresholds["maxCcn"]
            and current_nloc <= thresholds["maxNloc"]
            and (physical_lines is None or physical_lines <= thresholds["maxPhysicalLines"])
        ):
            findings.append(
                f"stale file baseline entry is fully within global thresholds: {path} "
                f"CCN={current_ccn} NLOC={current_nloc} physicalLines={physical_lines}"
            )

    for path, entry in sorted(current_directories.items()):
        current_baseline = baseline_directories.get(path)
        value = entry["directProductionFiles"]
        if current_baseline is None:
            if value > thresholds["maxDirectProductionFiles"]:
                findings.append(f"unclassified directory hotspot: {path} directProductionFiles={value}")
        elif current_baseline.get("deleted") is True:
            findings.append(f"current directory is marked deleted in baseline: {path}")
        else:
            if value != current_baseline["directProductionFiles"]:
                if value > current_baseline["directProductionFiles"]:
                    findings.append(
                        f"directory ceiling exceeded: {path} directProductionFiles={value} ceiling={current_baseline['directProductionFiles']}"
                    )
                else:
                    findings.append(
                        f"directory baseline is not exact: {path} directProductionFiles current={value} ceiling={current_baseline['directProductionFiles']}"
                    )
            if value <= thresholds["maxDirectProductionFiles"]:
                findings.append(
                    f"stale directory baseline entry is fully within global thresholds: {path} directProductionFiles={value}"
                )

    if base_baseline is not None:
        base_thresholds, base_files, base_directories = _validate_baseline(base_baseline)
        for field in THRESHOLD_FIELDS:
            if thresholds[field] > base_thresholds[field]:
                findings.append(
                    f"global threshold increased: {field} candidate={thresholds[field]} base={base_thresholds[field]}"
                )
        for path, entry in sorted(baseline_files.items()):
            if entry.get("deleted") is True:
                continue
            base_entry = base_files.get(path)
            if base_entry is None or base_entry.get("deleted") is True:
                findings.append(f"new grandfathered file path absent from base baseline: {path}")
                continue
            for field, label in (("maxCcn", "CCN"), ("maxNloc", "NLOC"), ("physicalLines", "physicalLines")):
                if entry[field] > base_entry[field]:
                    findings.append(
                        f"file ceiling increased over base baseline: {path} {label} candidate={entry[field]} base={base_entry[field]}"
                    )
        for path, entry in sorted(baseline_directories.items()):
            if entry.get("deleted") is True:
                continue
            base_entry = base_directories.get(path)
            if base_entry is None or base_entry.get("deleted") is True:
                findings.append(f"new grandfathered directory path absent from base baseline: {path}")
                continue
            if entry["directProductionFiles"] > base_entry["directProductionFiles"]:
                findings.append(
                    f"directory ceiling increased over base baseline: {path} directProductionFiles "
                    f"candidate={entry['directProductionFiles']} base={base_entry['directProductionFiles']}"
                )
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--base-ref", default=None)
    args = parser.parse_args(argv)
    try:
        base_object = _load_base_baseline(args.base_ref) if args.base_ref is not None else None
        findings = check(_load_object(args.report), _load_object(args.baseline), base_object)
    except ValueError as error:
        print(f"structure budget: {error}", file=sys.stderr)
        return 1
    if findings:
        for finding in findings:
            print(f"structure budget: {finding}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
