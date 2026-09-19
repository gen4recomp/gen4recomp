#!/usr/bin/env python3
"""Derive the executable-Lua scope used by code-health analysis."""

from __future__ import annotations

import argparse
import csv
import importlib.util
import subprocess
import sys
from pathlib import Path
from typing import Iterable


DECLARATIVE_PREFIXES = ("romdump/src/config/", "romdump/src/reference/")
DECLARATIVE_MARKER = "-- codehealth: declarative"
MARKER_SCAN_LINES = 5


def scope_metadata() -> dict[str, object]:
    return {
        "structural": "executable-production-lua",
        "sourceScope": "production",
        "declarativePrefixes": list(DECLARATIVE_PREFIXES),
        "declarativeMarker": DECLARATIVE_MARKER,
        "markerScanLines": MARKER_SCAN_LINES,
        "requiresLizardFunctionRow": True,
    }


def _resolve_repository_root(value: Path | str) -> Path:
    root = Path(value).resolve()
    if not root.is_dir():
        raise ValueError(f"repository root is not a directory: {value}")
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"repository root is not a git worktree: {value}: {error}") from error
    toplevel = Path(result.stdout.strip()).resolve()
    if toplevel != root:
        raise ValueError(f"repository root is not a worktree top level: {value}")
    return root


def _load_source_scope() -> object:
    module_path = Path(__file__).with_name("source_scope.py")
    module_spec = importlib.util.spec_from_file_location("source_scope", module_path)
    if module_spec is None or module_spec.loader is None:
        raise ValueError(f"cannot load source scope from {module_path}")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _normalize_manifest_path(raw: object) -> str:
    if not isinstance(raw, str) or not raw:
        raise ValueError(f"invalid manifest path {raw!r}")
    normalized = raw.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized.startswith("/")
        or (len(normalized) >= 2 and normalized[1] == ":")
        or ".." in parts
        or any(not part for part in parts)
    ):
        raise ValueError(f"invalid manifest path {raw!r}")
    if not normalized.endswith(".lua"):
        raise ValueError(f"invalid manifest path {raw!r}")
    return normalized


def _has_declarative_marker(repository_root: Path, relative: str) -> bool:
    try:
        text = (repository_root / relative).read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read candidate source {relative}: {error}") from error
    lines = text.splitlines()
    return any(
        line.strip() == DECLARATIVE_MARKER for line in lines[:MARKER_SCAN_LINES]
    )


def candidate_paths(repository_root: Path | str) -> list[str]:
    root = _resolve_repository_root(Path(repository_root))
    source_scope = _load_source_scope()
    paths_for_scope = getattr(source_scope, "paths_for_scope")
    production = paths_for_scope(root, "production")
    candidates: list[str] = []
    seen: set[str] = set()
    for raw in production:
        normalized = _normalize_manifest_path(raw)
        if normalized in seen:
            raise ValueError(f"duplicate candidate path {raw!r}")
        seen.add(normalized)
        if normalized.startswith(DECLARATIVE_PREFIXES):
            continue
        if _has_declarative_marker(root, normalized):
            continue
        candidates.append(normalized)
    candidates.sort()
    if not candidates:
        raise ValueError("code-health candidate scope is empty")
    return candidates


def _read_manifest_file(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read candidate manifest {path}: {error}") from error
    entries: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        normalized = _normalize_manifest_path(stripped)
        if normalized in seen:
            raise ValueError(f"duplicate candidate manifest entry {stripped!r}")
        seen.add(normalized)
        entries.append(normalized)
    if not entries:
        raise ValueError(f"candidate manifest {path} is empty")
    return sorted(entries)


def final_paths(
    repository_root: Path | str,
    candidates: Iterable[str],
    lizard_csv: Path | str,
) -> list[str]:
    _resolve_repository_root(Path(repository_root))
    candidate_list = [_normalize_manifest_path(entry) for entry in candidates]
    if len(set(candidate_list)) != len(candidate_list):
        raise ValueError("duplicate candidate manifest entry")
    if not candidate_list:
        raise ValueError("code-health candidate scope is empty")
    candidate_set = set(candidate_list)
    csv_path = Path(lizard_csv)
    try:
        handle = csv_path.open(newline="", encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read Lizard report {csv_path}: {error}") from error
    with handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or "file" not in reader.fieldnames:
            raise ValueError(f"Lizard report {csv_path} must have a file column")
        found: set[str] = set()
        has_rows = False
        for row in reader:
            has_rows = True
            raw = row.get("file")
            if raw is None:
                raise ValueError(f"Lizard report {csv_path} contains a row without a file")
            normalized = _normalize_manifest_path(raw.strip())
            if normalized not in candidate_set:
                raise ValueError(
                    f"Lizard report {csv_path} contains a path outside the candidate scope: {raw!r}"
                )
            found.add(normalized)
    if not has_rows or not found:
        raise ValueError(f"Lizard report {csv_path} contains no structural files")
    return sorted(found)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    candidate_parser = subparsers.add_parser("candidates")
    candidate_parser.add_argument("--repository-root", type=Path, required=True)
    structural_parser = subparsers.add_parser("structural")
    structural_parser.add_argument("--repository-root", type=Path, required=True)
    structural_parser.add_argument("--candidates", type=Path, required=True)
    structural_parser.add_argument("--lizard-csv", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "candidates":
            paths = candidate_paths(args.repository_root)
        else:
            candidates = _read_manifest_file(args.candidates)
            paths = final_paths(args.repository_root, candidates, args.lizard_csv)
    except ValueError as error:
        print(f"codehealth scope: {error}", file=sys.stderr)
        return 1
    sys.stdout.write("\n".join(paths) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
