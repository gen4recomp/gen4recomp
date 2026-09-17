#!/usr/bin/env python3
"""Validate and merge the compact versioned code-health history."""

from __future__ import annotations

import json
import math
import re
import sys
from datetime import datetime, timezone
from typing import Any


SCHEMA_VERSION = 1
MEASUREMENT_VERSION = 1

_COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")

# Integer-valued compact metrics. Floats hold erosion/duplication ratios.
_INTEGER_FIELDS = (
    "files",
    "physicalLines",
    "functions",
    "ccnP95",
    "ccnP99",
    "importCycleGroups",
    "fanOutP95",
    "fanOutP99",
)
_FLOAT_FIELDS = ("erosion", "duplicationPercentage",)
_ENTRY_FIELDS = ("commit", "committedAt", "analyzedAt") + _INTEGER_FIELDS + _FLOAT_FIELDS


def _integer(value: Any, entry: Any) -> int:
    if isinstance(value, bool):
        raise ValueError(f"history entry {entry!r} has a boolean metric")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, float) and value.is_integer():
        parsed = int(value)
    else:
        raise ValueError(f"history entry {entry!r} has a non-integer metric")
    if parsed < 0:
        raise ValueError(f"history entry {entry!r} has a negative metric")
    return parsed


def _ratio(value: Any, entry: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"history entry {entry!r} has a non-numeric metric")
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError(f"history entry {entry!r} has a non-finite metric")
    if parsed < 0:
        raise ValueError(f"history entry {entry!r} has a negative metric")
    return parsed


def _timestamp(value: Any, entry: Any) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"history entry {entry!r} has an invalid timestamp")
    text = value.strip()
    try:
        datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"history entry {entry!r} has an invalid timestamp") from error
    return text


def _validate_entry(entry: Any) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise ValueError(f"history entry {entry!r} must be an object")
    unknown = set(entry) - set(_ENTRY_FIELDS)
    if unknown:
        raise ValueError(f"history entry {entry!r} has unknown fields {sorted(unknown)}")
    missing = [field for field in _ENTRY_FIELDS if field not in entry]
    if missing:
        raise ValueError(f"history entry {entry!r} is missing fields {missing}")
    commit = entry["commit"]
    if not isinstance(commit, str) or _COMMIT_RE.match(commit.strip()) is None:
        raise ValueError(f"history entry {entry!r} has an invalid commit SHA")
    validated: dict[str, Any] = {
        "commit": commit.strip(),
        "committedAt": _timestamp(entry["committedAt"], entry),
        "analyzedAt": _timestamp(entry["analyzedAt"], entry),
    }
    for field in _INTEGER_FIELDS:
        validated[field] = _integer(entry[field], entry)
    for field in _FLOAT_FIELDS:
        validated[field] = _ratio(entry[field], entry)
    return validated


def _validate_previous(previous: Any) -> list[dict[str, Any]]:
    if not isinstance(previous, dict):
        raise ValueError("previous history must be an object")
    unknown = set(previous) - {"schemaVersion", "measurementVersion", "entries"}
    if unknown:
        raise ValueError(f"previous history has unknown fields {sorted(unknown)}")
    if previous.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(
            f"previous history schemaVersion {previous.get('schemaVersion')!r} "
            f"is incompatible with {SCHEMA_VERSION}"
        )
    if previous.get("measurementVersion") != MEASUREMENT_VERSION:
        raise ValueError(
            f"previous history measurementVersion {previous.get('measurementVersion')!r} "
            f"is incompatible with {MEASUREMENT_VERSION}"
        )
    entries = previous.get("entries")
    if not isinstance(entries, list):
        raise ValueError("previous history entries must be a list")
    validated = [_validate_entry(entry) for entry in entries]
    commits = [entry["commit"] for entry in validated]
    if len(set(commits)) != len(commits):
        raise ValueError("previous history contains duplicate commits")
    return validated


def entry_from_report(model: Any) -> dict[str, Any]:
    """Extract the compact history entry from a normalized current model."""
    if not isinstance(model, dict):
        raise ValueError("report model must be an object")
    if model.get("measurementVersion") != MEASUREMENT_VERSION:
        raise ValueError(
            f"report measurementVersion {model.get('measurementVersion')!r} "
            f"is incompatible with {MEASUREMENT_VERSION}"
        )
    try:
        complexity = model["complexity"]
        duplication = model["duplication"]
        architecture = model["architecture"]
        source = model["source"]
        distributions = model["structure"]["distributions"]
        fan_out = distributions["importFanOut"]
        entry = {
            "commit": model["commit"],
            "committedAt": model["committedAt"],
            "analyzedAt": model["generatedAt"],
            "files": len(source["files"]),
            "physicalLines": sum(row["physicalLines"] for row in source["files"]),
            "functions": complexity["functions"],
            "erosion": complexity["erosion"]["score"],
            "duplicationPercentage": duplication["percentage"],
            "ccnP95": complexity["ccn"]["p95"],
            "ccnP99": complexity["ccn"]["p99"],
            "importCycleGroups": architecture["importCycleGroups"],
            "fanOutP95": fan_out["p95"],
            "fanOutP99": fan_out["p99"],
        }
    except (KeyError, TypeError) as error:
        raise ValueError(f"report model is missing history fields: {error}") from error
    return _validate_entry(entry)


def _commit_instant(entry: dict[str, Any]) -> Any:
    """Return the commit instant for chronological history ordering."""
    parsed = datetime.fromisoformat(entry["committedAt"].replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def merge(previous: Any, current_entry: dict[str, Any]) -> dict[str, Any]:
    """Upsert the current entry into compatible history, ordered by commit time."""
    current = _validate_entry(current_entry)
    entries = [] if previous is None else _validate_previous(previous)
    entries = [entry for entry in entries if entry["commit"] != current["commit"]]
    entries.append(current)
    entries.sort(key=lambda entry: (_commit_instant(entry), entry["commit"]))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "measurementVersion": MEASUREMENT_VERSION,
        "entries": entries,
    }


def published_bootstrap_source(report: Any) -> str | None:
    """Decide the Pages history continuation from downloaded published state.

    The workflow fetches the live history and quality report over HTTP and
    passes the parsed bodies here; no networking happens in this helper.
    A missing report is passed as None. Returning a SHA means the caller
    must reanalyze that source commit with current tooling and reuse the
    resulting history. Returning None means the current build starts its
    own one-entry history. Raising ValueError fails the run closed.
    """
    if report is None:
        return None
    if not isinstance(report, dict):
        raise ValueError(f"published report {report!r} is not an object")
    version = report.get("measurementVersion")
    if version is None:
        commit = report.get("commit")
        if not isinstance(commit, str) or not _COMMIT_RE.match(commit):
            raise ValueError(f"published report has an invalid commit {commit!r}")
        return commit
    if isinstance(version, bool) or version != MEASUREMENT_VERSION:
        raise ValueError(
            f"published report measurement version {version!r} is incompatible"
        )
    raise ValueError("published report already uses current measurements without history")


def main(argv: list[str]) -> int:
    """Inspect a downloaded published quality report for bootstrap history."""
    if len(argv) != 2 or argv[0] != "published-bootstrap-source":
        print(
            "usage: codehealth_history.py published-bootstrap-source REPORT",
            file=sys.stderr,
        )
        return 2
    try:
        with open(argv[1], encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"codehealth: cannot parse published report: {error}", file=sys.stderr)
        return 1
    try:
        result = published_bootstrap_source(report)
    except ValueError as error:
        print(f"codehealth: {error}", file=sys.stderr)
        return 1
    sys.stdout.write((result or "") + "\n")
    return 0


def previous_entry(history: Any, current_commit: str) -> dict[str, Any] | None:
    """Return the entry preceding the current commit, or None at the baseline."""
    if not isinstance(history, dict) or not isinstance(history.get("entries"), list):
        raise ValueError("history must be an object with an entries list")
    entries = history["entries"]
    for index, entry in enumerate(entries):
        if isinstance(entry, dict) and entry.get("commit") == current_commit:
            return entries[index - 1] if index > 0 else None
    return None


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
