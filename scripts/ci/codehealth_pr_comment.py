#!/usr/bin/env python3
"""Validate an untrusted hotspot comparison artifact and render publication data."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


_METRICS = ("maxCcn", "maxNloc", "physicalLines")
_KINDS = ("new-hotspot", "worsened")
_SCHEMA_VERSION = 1

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_UNSAFE_PATH_CHARS = ("\n", "\r", "`", "|", "<", ">", "&")

_MARKER = "<!-- gen4recomp-codehealth-hotspot-advisory -->"
_HEADER = "### Structural hotspot advisory"
_INTRO = (
    "Advisory only, not a merge requirement. "
    "These file metrics rose above the hotspot threshold "
    "compared with the pull request base."
)
_TABLE_HEADER = "| File | Metric | Base | PR | Status | Threshold |"
_TABLE_SEPARATOR = "| --- | --- | --- | --- | --- | --- |"


def _fail(message: str) -> int:
    print(f"codehealth comment: {message}", file=sys.stderr)
    return 1


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    return isinstance(value, (int, float))


def _is_finite_number(value: Any) -> bool:
    if not _is_number(value):
        return False
    if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
        return False
    return True


def _validate_sha(value: Any) -> str:
    if not isinstance(value, str) or not _SHA_RE.match(value):
        raise ValueError("invalid SHA")
    return value


def _validate_path(raw: Any) -> str:
    if not isinstance(raw, str) or not raw:
        raise ValueError(f"invalid path {raw!r}")
    for fragment in _UNSAFE_PATH_CHARS:
        if fragment in raw:
            raise ValueError(f"unsafe path {raw!r}")
    if "\\" in raw or raw.startswith("/") or not raw.endswith(".lua"):
        raise ValueError(f"unsafe or non-Lua path {raw!r}")
    parts = raw.split("/")
    if any(not part or part in (".", "..") for part in parts):
        raise ValueError(f"unsafe or non-Lua path {raw!r}")
    return raw


def _validate_row(row: Any) -> dict[str, Any]:
    if not isinstance(row, dict):
        raise ValueError("invalid regression row")
    path = _validate_path(row.get("path"))
    metric = row.get("metric")
    if metric not in _METRICS:
        raise ValueError(f"invalid metric {metric!r}")
    threshold = row.get("threshold")
    head = row.get("head")
    if not _is_finite_number(threshold):
        raise ValueError("invalid threshold")
    if not _is_finite_number(head):
        raise ValueError("invalid head value")
    if not head > threshold:  # type: ignore[operator]
        raise ValueError("head must exceed threshold")
    kind = row.get("kind")
    if kind not in _KINDS:
        raise ValueError(f"invalid kind {kind!r}")
    base = row.get("base")
    if kind == "new-hotspot":
        if base is not None:
            raise ValueError("new-hotspot base must be null")
    else:
        if not _is_finite_number(base):
            raise ValueError("worsened base must be numeric")
        if not head > base:  # type: ignore[operator]
            raise ValueError("worsened head must exceed base")
    return {
        "path": path,
        "metric": metric,
        "threshold": threshold,
        "base": base,
        "head": head,
        "kind": kind,
    }


def _load_artifact(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            model = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}: {error}") from error
    if not isinstance(model, dict):
        raise ValueError("artifact must contain a JSON object")
    return model


def _associated_numbers(raw: str) -> set[int]:
    try:
        model = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid associated pull requests: {error}") from error
    if not isinstance(model, list) or not model:
        raise ValueError("associated pull requests must be a non-empty list")
    numbers: set[int] = set()
    for entry in model:
        if not isinstance(entry, dict):
            continue
        number = entry.get("number")
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            continue
        numbers.add(number)
    if not numbers:
        raise ValueError("associated pull requests must be a non-empty list")
    return numbers


def _render_body(rows: list[dict[str, Any]]) -> str:
    lines = [
        f"| `{row['path']}` | {row['metric']} | "
        f"{'—' if row['base'] is None else row['base']} | "
        f"{row['head']} | {row['kind']} | {row['threshold']} |"
        for row in rows
    ]
    return "\n".join(
        [_MARKER, _HEADER, "", _INTRO, "", _TABLE_HEADER, _TABLE_SEPARATOR, *lines]
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--run-head-sha", required=True)
    parser.add_argument("--associated-pull-requests", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        run_head_sha = _validate_sha(args.run_head_sha)
        associated = _associated_numbers(args.associated_pull_requests)
        model = _load_artifact(args.artifact)
        if model.get("schemaVersion") != _SCHEMA_VERSION:
            raise ValueError("unsupported schema version")
        pull_request = model.get("pullRequest")
        if isinstance(pull_request, bool) or not isinstance(pull_request, int) or pull_request <= 0:
            raise ValueError("invalid pull request number")
        base_sha = _validate_sha(model.get("baseSha"))
        head_sha = _validate_sha(model.get("headSha"))
        if head_sha != run_head_sha:
            raise ValueError("artifact head does not match triggering run")
        if pull_request not in associated:
            raise ValueError("artifact is not associated with the triggering run")
        regressions = model.get("regressions")
        if not isinstance(regressions, list):
            raise ValueError("invalid regressions")
        normalized = [_validate_row(row) for row in regressions]
        normalized.sort(key=lambda row: (row["path"], row["metric"]))
        body = _render_body(normalized) if normalized else None
        output = {
            "pullRequest": pull_request,
            "baseSha": base_sha,
            "headSha": head_sha,
            "regressions": normalized,
            "body": body,
        }
        args.output.write_text(
            json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except (OSError, ValueError) as error:
        try:
            args.output.unlink(missing_ok=True)
        except OSError:
            pass
        return _fail(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
