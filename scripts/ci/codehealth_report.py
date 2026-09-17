#!/usr/bin/env python3
"""Normalize analyzer reports and render the static code-health summary."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import html
import importlib.util
import json
import math
from collections.abc import Iterable
from pathlib import Path
import statistics
import subprocess
from typing import Any


def _load_history_module() -> Any:
    module_path = Path(__file__).with_name("codehealth_history.py")
    module_spec = importlib.util.spec_from_file_location("codehealth_history", module_path)
    if module_spec is None or module_spec.loader is None:
        raise ValueError(f"cannot load history helper from {module_path}")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


_HISTORY = _load_history_module()

REPORT_SCHEMA_VERSION = 6
EROSION_THRESHOLD = 10

EXCLUDED_PREFIXES = [
    "tests/",
    "**/tests/",
    "vendor/",
    "types/",
    "tools/",
    "scripts/",
    "site/",
    ".github/",
    "data/generated/",
    "data/scripts/overrides/",
]
STRUCTURAL_ROOT_EXCLUSIONS = {
    ".agents",
    ".cache",
    ".claude",
    ".github",
    "import-output",
    "log",
    "scripts",
    "site",
    "tmp",
    "tools",
    "types",
    "vendor",
}

HOTSPOT_THRESHOLDS = {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200}
HOTSPOT_IGNORE_MARKER = "-- codehealth: ignore-hotspot"
HOTSPOT_IGNORE_SCAN_LINES = 5


def _hotspot_policy() -> dict[str, Any]:
    return {
        "thresholds": dict(HOTSPOT_THRESHOLDS),
        "ignoreMarker": HOTSPOT_IGNORE_MARKER,
        "ignoreScanLines": HOTSPOT_IGNORE_SCAN_LINES,
    }


def _hotspot_rows(files: list[dict[str, Any]], metric: str) -> list[dict[str, Any]]:
    threshold = HOTSPOT_THRESHOLDS[metric]
    candidates = (
        row
        for row in files
        if not row["hotspotIgnored"] and row[metric] is not None and row[metric] > threshold
    )
    return sorted(candidates, key=lambda row: (-row[metric], row["path"]))


def _load_json_value(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as report_file:
            return json.load(report_file)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}: {error}") from error


def _load_json(path: Path) -> dict[str, Any]:
    value = _load_json_value(path)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def _number(value: Any, path: Path, field: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise ValueError(f"{path} has a non-numeric {field}")
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{path} has a non-numeric {field}") from error
    if not math.isfinite(parsed):
        raise ValueError(f"{path} has a non-finite {field}")
    if parsed.is_integer():
        return int(parsed)
    return parsed


def _nearest_rank(values: list[int | float], percentile: float) -> int | float:
    if not values:
        raise ValueError("nearest-rank requires at least one value")
    rank = max(1, min(len(values), math.ceil(percentile * len(values))))
    return sorted(values)[rank - 1]


def _subsystem_for_path(source_file: str) -> str:
    parts = source_file.split("/")
    if parts[0] == "libs" and len(parts) > 1:
        return f"libs/{parts[1]}"
    if parts[0] == "game" and len(parts) > 1 and parts[1] == "hgss":
        return "game/hgss"
    return parts[0]


def _erosion(records: list[tuple[str | None, float, float]]) -> dict[str, Any]:
    masses = [ccn * math.sqrt(nloc) for _, nloc, ccn in records]
    total_mass = sum(masses)
    high_masses = [mass for (_, _, ccn), mass in zip(records, masses) if ccn > EROSION_THRESHOLD]
    high_mass = sum(high_masses)
    score = high_mass / total_mass if total_mass else 0.0
    if not math.isfinite(score):
        raise ValueError("erosion score is non-finite")
    return {
        "threshold": EROSION_THRESHOLD,
        "totalMass": total_mass,
        "highComplexityMass": high_mass,
        "highComplexityFunctions": len(high_masses),
        "functions": len(records),
        "score": score,
    }


def _subsystems(records: list[tuple[str | None, float, float]]) -> list[dict[str, Any]]:
    groups: dict[str, list[tuple[str | None, float, float]]] = {}
    for source_file, nloc, ccn in records:
        if source_file is None:
            continue
        groups.setdefault(_subsystem_for_path(source_file), []).append((source_file, nloc, ccn))
    rows = []
    for identifier in sorted(groups):
        aggregate = _erosion(groups[identifier])
        rows.append(
            {
                "id": identifier,
                "functions": aggregate["functions"],
                "highComplexityFunctions": aggregate["highComplexityFunctions"],
                "erosion": aggregate["score"],
            }
        )
    return rows


def _parse_lizard_report(path: Path) -> dict[str, Any]:
    try:
        with path.open(newline="", encoding="utf-8") as report_file:
            reader = csv.DictReader(report_file)
            if reader.fieldnames is None or "NLOC" not in reader.fieldnames or "CCN" not in reader.fieldnames:
                raise ValueError(f"Lizard report {path} must have NLOC and CCN headers")
            nloc_values: list[int | float] = []
            ccn_values: list[int | float] = []
            file_metrics: dict[str, dict[str, int | float]] = {}
            function_records: list[tuple[str | None, float, float]] = []
            has_file_column = "file" in reader.fieldnames
            for row in reader:
                if not row or any(value is None or value.strip() == "" for value in row.values()):
                    raise ValueError(f"Lizard report {path} contains an empty row")
                nloc = _number(row["NLOC"], path, "NLOC")
                ccn = _number(row["CCN"], path, "CCN")
                if nloc <= 0:
                    raise ValueError(f"Lizard report {path} has a non-positive NLOC")
                nloc_values.append(nloc)
                ccn_values.append(ccn)
                source_file: str | None = None
                if has_file_column:
                    source_file = _normalize_source_file(row["file"], path)
                    metrics = file_metrics.setdefault(
                        source_file,
                        {"functions": 0, "maxCcn": ccn, "maxNloc": nloc},
                    )
                    metrics["functions"] += 1
                    metrics["maxCcn"] = max(metrics["maxCcn"], ccn)
                    metrics["maxNloc"] = max(metrics["maxNloc"], nloc)
                function_records.append((source_file, float(nloc), float(ccn)))
    except OSError as error:
        raise ValueError(f"cannot read Lizard report {path}: {error}") from error
    if not nloc_values:
        raise ValueError(f"Lizard report {path} contains no function rows")
    return {
        "erosion": _erosion(function_records),
        "subsystems": _subsystems(function_records),
        "functions": len(nloc_values),
        "files": file_metrics,
        "ccn": {
            "median": statistics.median(ccn_values),
            "p90": _nearest_rank(ccn_values, 0.90),
            "p95": _nearest_rank(ccn_values, 0.95),
            "p99": _nearest_rank(ccn_values, 0.99),
            "max": max(ccn_values),
        },
        "nloc": {
            "median": statistics.median(nloc_values),
            "p95": _nearest_rank(nloc_values, 0.95),
            "max": max(nloc_values),
        },
    }


def _parse_jscpd_report(path: Path) -> dict[str, Any]:
    report = _load_json(path)
    statistics = report.get("statistics")
    if not isinstance(statistics, dict) or not isinstance(statistics.get("total"), dict):
        raise ValueError(f"jscpd report {path} must contain statistics.total")
    total = statistics["total"]
    fields = ("sources", "clones", "duplicatedLines", "percentage")
    if any(field not in total for field in fields):
        raise ValueError(f"jscpd report {path} statistics.total is missing a required field")
    return {
        "sources": _number(total["sources"], path, "statistics.total.sources"),
        "clones": _number(total["clones"], path, "statistics.total.clones"),
        "duplicatedLines": _number(total["duplicatedLines"], path, "statistics.total.duplicatedLines"),
        "percentage": _number(total["percentage"], path, "statistics.total.percentage"),
    }


def _is_excluded_source(source_file: str) -> bool:
    parts = source_file.split("/")
    if "tests" in parts or parts[0] in STRUCTURAL_ROOT_EXCLUSIONS:
        return True
    return source_file.startswith("data/generated/") or source_file.startswith("data/scripts/overrides/")


def _normalize_source_file(source_file: Any, path: Path, label: str = "Graphify report") -> str:
    if not isinstance(source_file, str) or not source_file:
        raise ValueError(f"{label} {path} contains an invalid source_file")
    normalized = source_file.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized.startswith("/")
        or (len(normalized) >= 2 and normalized[1] == ":")
        or ".." in parts
        or any(not part for part in parts)
    ):
        raise ValueError(f"{label} {path} contains a non-portable source_file {source_file!r}")
    if not normalized.endswith(".lua"):
        raise ValueError(f"{label} {path} contains a non-Lua source_file {source_file!r}")
    if _is_excluded_source(normalized):
        raise ValueError(f"{label} {path} contains an excluded source_file {source_file!r}")
    return normalized


def _load_structural_manifest(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read structural manifest {path}: {error}") from error
    entries: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        normalized = _normalize_source_file(stripped, path, "structural manifest")
        if normalized in seen:
            raise ValueError(f"structural manifest {path} contains a duplicate entry {stripped!r}")
        seen.add(normalized)
        entries.append(normalized)
    if not entries:
        raise ValueError(f"structural manifest {path} is empty")
    return sorted(entries)


def _source_census(
    repository_root: Path, structural_paths: Iterable[str]
) -> tuple[dict[str, Any], dict[str, Any]]:
    paths = [_normalize_source_file(entry, repository_root, "structural manifest") for entry in structural_paths]
    if len(set(paths)) != len(paths):
        raise ValueError("structural manifest contains a duplicate entry")
    if not paths:
        raise ValueError("structural manifest is empty")
    source_files: list[dict[str, Any]] = []
    directory_counts: dict[str, int] = {}
    for source_file in paths:
        source_path = repository_root / source_file
        try:
            raw = source_path.read_bytes()
        except OSError as error:
            raise ValueError(f"cannot read production source {source_file}: {error}") from error
        text = raw.decode("utf-8")
        lines = text.splitlines()
        source_files.append(
            {
                "path": source_file,
                "bytes": len(raw),
                "physicalLines": len(lines),
                "hotspotIgnored": any(
                    line.strip() == HOTSPOT_IGNORE_MARKER
                    for line in lines[:HOTSPOT_IGNORE_SCAN_LINES]
                ),
            }
        )
        directory = str(Path(source_file).parent).replace("\\", "/")
        directory_counts[directory] = directory_counts.get(directory, 0) + 1
    directories = [
        {"path": path, "directProductionFiles": count}
        for path, count in sorted(directory_counts.items())
    ]
    return {"files": source_files}, {"files": directories}


def _import_cycle_groups(adjacency: dict[Any, set[Any]]) -> int:
    nodes = set(adjacency)
    for targets in adjacency.values():
        nodes.update(targets)
    forward = {node: set(adjacency.get(node, set())) for node in nodes}
    reverse = {node: set() for node in nodes}
    for source, targets in forward.items():
        for target in targets:
            reverse[target].add(source)

    visited: set[Any] = set()
    finish_order: list[Any] = []
    for start in nodes:
        if start in visited:
            continue
        stack = [(start, False)]
        while stack:
            node, expanded = stack.pop()
            if expanded:
                finish_order.append(node)
                continue
            if node in visited:
                continue
            visited.add(node)
            stack.append((node, True))
            for target in forward[node]:
                if target not in visited:
                    stack.append((target, False))

    visited.clear()
    cycles = 0
    for start in reversed(finish_order):
        if start in visited:
            continue
        component: set[Any] = set()
        stack = [start]
        visited.add(start)
        while stack:
            node = stack.pop()
            component.add(node)
            for source in reverse[node]:
                if source not in visited:
                    visited.add(source)
                    stack.append(source)
        if len(component) > 1 or any(node in forward[node] for node in component):
            cycles += 1
    return cycles


def _parse_graphify_report(path: Path) -> dict[str, Any]:
    report = _load_json(path)
    if report.get("directed") is not True:
        raise ValueError(f"Graphify report {path} must be directed")
    nodes = report.get("nodes")
    links = report.get("links")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError(f"Graphify report {path} must contain nonempty nodes")
    if not isinstance(links, list) or not links:
        raise ValueError(f"Graphify report {path} must contain nonempty links")

    node_sources: dict[Any, str] = {}
    node_ids: set[Any] = set()
    communities: set[Any] = set()
    modules: set[str] = set()
    file_callables: dict[str, int] = {}
    for node in nodes:
        if not isinstance(node, dict) or "id" not in node:
            raise ValueError(f"Graphify report {path} contains an invalid node")
        node_id = node["id"]
        try:
            hash(node_id)
        except TypeError as error:
            raise ValueError(f"Graphify report {path} contains an unhashable node id") from error
        if node_id in node_ids:
            raise ValueError(f"Graphify report {path} contains a duplicate node id {node_id!r}")
        node_ids.add(node_id)
        source_file = node.get("source_file")
        if "source_file" in node and source_file is not None:
            normalized = _normalize_source_file(source_file, path)
            node_sources[node_id] = normalized
            modules.add(normalized)
            file_callables.setdefault(normalized, 0)
            if node.get("_callable") is True:
                file_callables[normalized] += 1
            if node.get("community") is not None:
                try:
                    communities.add(node["community"])
                except TypeError as error:
                    raise ValueError(f"Graphify report {path} contains an unhashable community") from error

    provenance = {"extracted": 0, "inferred": 0, "ambiguous": 0}
    import_pairs: set[tuple[str, str]] = set()
    extracted_import_pairs: set[tuple[str, str]] = set()
    adjacency = {module: set() for module in modules}
    for link in links:
        if not isinstance(link, dict):
            raise ValueError(f"Graphify report {path} contains an invalid link")
        if any(field not in link for field in ("source", "target", "relation", "confidence")):
            raise ValueError(f"Graphify report {path} contains a link missing a required field")
        for endpoint in ("source", "target"):
            endpoint_id = link[endpoint]
            try:
                hash(endpoint_id)
            except TypeError as error:
                raise ValueError(f"Graphify report {path} contains an unhashable link {endpoint}") from error
            if endpoint_id not in node_ids:
                raise ValueError(f"Graphify report {path} contains a link to an unknown node {endpoint_id!r}")
        if "source_file" in link and link["source_file"] is not None:
            _normalize_source_file(link["source_file"], path)
        confidence = link.get("confidence")
        if not isinstance(confidence, str) or confidence.upper() not in {"EXTRACTED", "INFERRED", "AMBIGUOUS"}:
            raise ValueError(f"Graphify report {path} contains unsupported link confidence {confidence!r}")
        provenance[confidence.lower()] += 1
        if link.get("relation") == "imports":
            source = node_sources.get(link.get("source"))
            target = node_sources.get(link.get("target"))
            if source is not None and target is not None:
                import_pairs.add((source, target))
                adjacency[source].add(target)
                if confidence.upper() == "EXTRACTED" and source != target:
                    extracted_import_pairs.add((source, target))

    return {
        "modules": len(modules),
        "nodes": len(nodes),
        "edges": len(links),
        "communities": len(communities),
        "importEdges": len(import_pairs),
        "importCycleGroups": _import_cycle_groups(adjacency),
        "provenance": provenance,
        "files": file_callables,
        "extractedImportPairs": extracted_import_pairs,
    }


def _distribution(values: list[int | float]) -> dict[str, Any]:
    return {
        "p95": _nearest_rank(values, 0.95),
        "p99": _nearest_rank(values, 0.99),
        "max": max(values),
    }


def _lizard_maxima(lizard: dict[str, Any], path: str) -> tuple[Any, Any]:
    metrics = lizard["files"].get(path)
    if metrics is None:
        return None, None
    return metrics.get("maxCcn"), metrics.get("maxNloc")


def _build_structure_metrics(
    lizard: dict[str, Any], graphify: dict[str, Any], source: dict[str, Any]
) -> dict[str, Any]:
    lizard_files: dict[str, dict[str, int | float]] = lizard["files"]
    graphify_files: dict[str, int] = graphify["files"]
    source_by_path = {row["path"]: row for row in source["files"]}
    paths = sorted(set(lizard_files) | set(graphify_files) | set(source_by_path))
    fan_in = {path: 0 for path in paths}
    fan_out = {path: 0 for path in paths}
    for source_path, target in graphify["extractedImportPairs"]:
        if source_path in fan_out and target in fan_in:
            fan_out[source_path] += 1
            fan_in[target] += 1

    files: list[dict[str, Any]] = []
    for path in paths:
        lizard_metrics = lizard_files.get(path)
        lizard_functions = int(lizard_metrics["functions"]) if lizard_metrics is not None else 0
        graphify_callables = graphify_files.get(path, 0)
        max_ccn, max_nloc = _lizard_maxima(lizard, path)
        source_row = source_by_path.get(path)
        files.append(
            {
                "path": path,
                "lizardFunctions": lizard_functions,
                "graphifyCallables": graphify_callables,
                "callableVisibility": (
                    graphify_callables / lizard_functions if lizard_functions else None
                ),
                "maxCcn": max_ccn,
                "maxNloc": max_nloc,
                "physicalLines": source_row["physicalLines"] if source_row is not None else None,
                "hotspotIgnored": (
                    source_row["hotspotIgnored"] if source_row is not None else False
                ),
                "importFanIn": fan_in[path],
                "importFanOut": fan_out[path],
            }
        )

    eligible = [row for row in files if not row["hotspotIgnored"]]
    low_visibility = sorted(
        (row for row in eligible if row["lizardFunctions"] >= 8),
        key=lambda row: (
            row["callableVisibility"] is not None,
            row["callableVisibility"] or 0,
            -row["lizardFunctions"],
            row["path"],
        ),
    )[:20]
    fan_outliers = sorted(eligible, key=lambda row: (-row["importFanOut"], row["path"]))[:20]
    return {
        "callableVisibility": {
            "lizardFunctions": lizard["functions"],
            "graphifyCallables": sum(graphify_files.values()),
            "ratio": (
                sum(graphify_files.values()) / lizard["functions"] if lizard["functions"] else None
            ),
        },
        "distributions": {
            "importFanIn": _distribution([fan_in[path] for path in paths]),
            "importFanOut": _distribution([fan_out[path] for path in paths]),
        },
        "files": files,
        "hotspotPolicy": _hotspot_policy(),
        "hotspots": {
            "maxCcn": _hotspot_rows(files, "maxCcn"),
            "maxNloc": _hotspot_rows(files, "maxNloc"),
            "physicalLines": _hotspot_rows(files, "physicalLines"),
        },
        "outliers": {
            "lowVisibility": low_visibility,
            "fanOut": fan_outliers,
        },
    }


def _version(command: str) -> str:
    try:
        result = subprocess.run([command, "--version"], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot read {command} version: {error}") from error
    version = (result.stdout or result.stderr).strip()
    if not version:
        raise ValueError(f"{command} returned an empty version")
    return version


def _git_commit(repository_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot determine analyzed git commit: {error}") from error
    commit = result.stdout.strip()
    if len(commit) != 40:
        raise ValueError(f"git returned an invalid commit {commit!r}")
    return commit


def _git_committed_at(repository_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "log", "-1", "--format=%cI"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot determine analyzed commit time: {error}") from error
    committed_at = result.stdout.strip()
    if not committed_at:
        raise ValueError("git returned an empty commit time")
    return committed_at


def _render_summary(
    model: dict[str, Any],
    history: dict[str, Any] | None = None,
    previous: dict[str, Any] | None = None,
) -> str:
    def value(item: Any) -> str:
        return html.escape(str(item))

    def display(item: Any) -> str:
        return "—" if item is None else value(item)

    def render_hotspot_table(title: str, rows: list[dict[str, Any]], metric: str) -> str:
        row_markup = "\n".join(
            "            <tr>"
            f"<td>{value(row['path'])}</td>"
            f"<td>{display(row[metric])}</td>"
            f"<td>{display(row['maxCcn'])}</td>"
            f"<td>{display(row['maxNloc'])}</td>"
            f"<td>{display(row['physicalLines'])}</td>"
            "</tr>"
            for row in rows
        )
        heading_id = title.lower().replace(" ", "-") + "-title"
        return f"""        <section class="panel" aria-labelledby="{html.escape(heading_id)}">
          <h3 id="{html.escape(heading_id)}">{html.escape(title)}</h3>
          <div class="table-wrap"><table>
            <thead><tr><th scope="col">Path</th><th scope="col">Hotspot value</th><th scope="col">Max CCN</th><th scope="col">Max NLOC</th><th scope="col">Physical lines</th></tr></thead>
            <tbody>
{row_markup}
            </tbody>
          </table></div>
        </section>"""

    def render_outlier_table(title: str, rows: list[dict[str, Any]]) -> str:
        row_markup = "\n".join(
            "            <tr>"
            f"<td>{value(row['path'])}</td>"
            f"<td>{display(row['callableVisibility'])}</td>"
            f"<td>{display(row['maxCcn'])}</td>"
            f"<td>{display(row['maxNloc'])}</td>"
            f"<td>{value(row['importFanOut'])}</td>"
            "</tr>"
            for row in rows
        )
        heading_id = title.lower().replace(" ", "-") + "-title"
        return f"""        <section class="panel" aria-labelledby="{html.escape(heading_id)}">
          <h3 id="{html.escape(heading_id)}">{html.escape(title)}</h3>
          <div class="table-wrap"><table>
            <thead><tr><th scope="col">Path</th><th scope="col">Visibility</th><th scope="col">Max CCN</th><th scope="col">Max NLOC</th><th scope="col">Fan-out</th></tr></thead>
            <tbody>
{row_markup}
            </tbody>
          </table></div>
        </section>"""

    tools = model["tools"]
    complexity = model["complexity"]
    duplication = model["duplication"]
    architecture = model["architecture"]
    structure = model["structure"]
    source = model["source"]
    directories = model["directories"]
    visibility = structure["callableVisibility"]
    erosion = complexity.get("erosion") or {}
    erosion_score = erosion.get("score")
    duplication_percentage = duplication.get("percentage")
    ccn_p95 = (complexity.get("ccn") or {}).get("p95")
    cycle_groups = architecture.get("importCycleGroups")
    previous_metrics: dict[str, Any] = previous if isinstance(previous, dict) else {}

    def signed(current: Any, old: Any) -> str | None:
        if current is None or old is None:
            return None
        delta = current - old
        if isinstance(delta, float):
            return f"{delta:+.4f}"
        return f"{delta:+d}"

    def headline_card(title: str, formatted: str, delta: str | None) -> str:
        detail = f"<p>{html.escape(delta)} since previous</p>" if delta is not None else ""
        return (
            f'        <article class="card"><h3>{html.escape(title)}</h3>'
            f"<p>{formatted}</p>{detail}</article>"
        )

    def formatted_erosion(score: Any) -> str:
        return "—" if score is None else f"{score:.4f}"

    def formatted_percentage(percentage: Any) -> str:
        return "—" if percentage is None else f"{value(percentage)}%"

    card_markup = "\n".join(
        [
            headline_card(
                "Erosion",
                formatted_erosion(erosion_score),
                signed(erosion_score, previous_metrics.get("erosion")),
            ),
            headline_card(
                "Duplication percentage",
                formatted_percentage(duplication_percentage),
                signed(duplication_percentage, previous_metrics.get("duplicationPercentage")),
            ),
            headline_card(
                "CCN p95",
                display(ccn_p95),
                signed(ccn_p95, previous_metrics.get("ccnP95")),
            ),
            headline_card(
                "Import-cycle groups",
                display(cycle_groups),
                signed(cycle_groups, previous_metrics.get("importCycleGroups")),
            ),
        ]
    )
    subsystems = model.get("subsystems") or []
    subsystem_rows_markup = "\n".join(
        "            <tr>"
        f"<td>{value(row['id'])}</td>"
        f"<td>{value(row['functions'])}</td>"
        f"<td>{value(row['highComplexityFunctions'])}</td>"
        f"<td>{formatted_erosion(row['erosion'])}</td>"
        "</tr>"
        for row in subsystems
    )
    history_entries: list[dict[str, Any]] = []
    if isinstance(history, dict) and isinstance(history.get("entries"), list):
        history_entries = history["entries"]
    visible_history = history_entries[-50:]
    if previous_metrics.get("commit") is not None:
        history_status = (
            "<p>Change since "
            f"<code>{value(previous_metrics['commit'])}</code>. "
            "Deltas on headline cards are signed differences against that commit.</p>"
        )
    else:
        history_status = (
            "<p>Baseline — this is the first compatible measurement; "
            "there is no previous commit to compare.</p>"
        )
    history_rows_markup = "\n".join(
        "            <tr>"
        f"<td><code>{value(row['commit'])}</code></td>"
        f"<td>{value(row['committedAt'])}</td>"
        f"<td>{value(row['analyzedAt'])}</td>"
        f"<td>{value(row['files'])}</td>"
        f"<td>{value(row['functions'])}</td>"
        f"<td>{formatted_erosion(row['erosion'])}</td>"
        f"<td>{formatted_percentage(row['duplicationPercentage'])}</td>"
        f"<td>{value(row['ccnP95'])}</td>"
        f"<td>{value(row['importCycleGroups'])}</td>"
        "</tr>"
        for row in visible_history
    )
    human_reports = (
        ("Lizard HTML", "reports/lizard/index.html"),
        ("jscpd HTML", "reports/jscpd/jscpd-report.html"),
        ("Graphify graph", "reports/graphify/graph.html"),
        ("Graphify call flow", "reports/graphify/callflow.html"),
        ("jscpd Markdown", "reports/jscpd/jscpd-report.md"),
    )
    machine_reports = (
        ("Normalized quality report", "quality-report.json"),
        ("Compact history", "history.json"),
        ("Lizard functions", "reports/lizard/functions.csv"),
        ("jscpd report", "reports/jscpd/jscpd-report.json"),
        ("Graphify graph", "reports/graphify/graph.json"),
    )
    human_markup = "\n".join(
        f'          <li><a href="{html.escape(link, quote=True)}">{html.escape(title)}</a></li>'
        for title, link in human_reports
    )
    machine_markup = "\n".join(
        f'          <li><a href="{html.escape(link, quote=True)}" download>{html.escape(title)}</a></li>'
        for title, link in machine_reports
    )
    def ignored_state(row: dict[str, Any]) -> str:
        return "ignored" if row["hotspotIgnored"] else "—"

    hotspots = structure["hotspots"]
    hotspot_note = (
        "<p>Structural hotspots list files above the advisory thresholds "
        f"(max CCN &gt; {HOTSPOT_THRESHOLDS['maxCcn']}, max NLOC &gt; "
        f"{HOTSPOT_THRESHOLDS['maxNloc']}, physical lines &gt; "
        f"{HOTSPOT_THRESHOLDS['physicalLines']}). A file carrying "
        f"<code>{value(HOTSPOT_IGNORE_MARKER)}</code> within the first "
        f"{HOTSPOT_IGNORE_SCAN_LINES} lines is ignored in hotspot and outlier "
        "lists; raw measurements for ignored files remain available in the "
        "per-file table and downloadable reports.</p>"
    )
    file_rows_markup = "\n".join(
        "            <tr>"
        f"<td>{value(row['path'])}</td>"
        f"<td>{value(row['lizardFunctions'])}</td>"
        f"<td>{value(row['graphifyCallables'])}</td>"
        f"<td>{display(row['callableVisibility'])}</td>"
        f"<td>{display(row['maxCcn'])}</td>"
        f"<td>{display(row['maxNloc'])}</td>"
        f"<td>{display(row['physicalLines'])}</td>"
        f"<td>{value(row['importFanIn'])}</td>"
        f"<td>{value(row['importFanOut'])}</td>"
        f"<td>{ignored_state(row)}</td>"
        "</tr>"
        for row in structure["files"]
    )
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Code health — g4recomp</title>
    <link rel="stylesheet" href="../styles.css">
  </head>
  <body>
    <main class="page-shell">
      <section class="hero" aria-labelledby="report-title">
        <p class="eyebrow">Static analysis report</p>
        <h1 id="report-title">Code health</h1>
        <p class="lede">Generated for commit <code>{value(model["commit"])}</code> at {value(model["generatedAt"])}.</p>
        <p>LuaLS remains enforced by binding CI through the repository lint gate; this Pages report covers production-Lua complexity, duplication, and architecture observations.</p>
      </section>
      <section aria-labelledby="headline-title">
        <h2 id="headline-title">Headline metrics</h2>
        <div class="grid">
{card_markup}
        </div>
      </section>
      <section class="panel" aria-labelledby="source-census-title">
        <h2 id="source-census-title">Source census</h2>
        <p>{value(len(source["files"]))} analyzed structural files, {value(complexity.get("functions", "—"))} functions, {value(sum(row["physicalLines"] for row in source["files"]))} physical lines, with bytes and physical-line measurements.</p>
      </section>
      <section class="panel" aria-labelledby="erosion-title">
        <h2 id="erosion-title">Structural erosion</h2>
        <p>Erosion is the share of complexity mass held by functions with CCN above {value(erosion.get("threshold", EROSION_THRESHOLD))}, where mass is CCN times the square root of NLOC. Lizard NLOC is the SLOC proxy for this metric. It is a structural signal, not a health verdict.</p>
        <div class="table-wrap"><table>
          <thead><tr><th scope="col">Subsystem</th><th scope="col">Functions</th><th scope="col">High-complexity functions</th><th scope="col">Erosion</th></tr></thead>
          <tbody>
{subsystem_rows_markup}
          </tbody>
        </table></div>
      </section>
      <section class="panel" aria-labelledby="history-title">
        <h2 id="history-title">Measurement history</h2>
{history_status}
        <p>Showing the latest {value(len(visible_history))} of {value(len(history_entries))} compact measurements. Full history remains available through the machine download below.</p>
        <div class="table-wrap"><table>
          <thead><tr><th scope="col">Commit</th><th scope="col">Committed</th><th scope="col">Analyzed</th><th scope="col">Files</th><th scope="col">Functions</th><th scope="col">Erosion</th><th scope="col">Duplication</th><th scope="col">CCN p95</th><th scope="col">Cycles</th></tr></thead>
          <tbody>
{history_rows_markup}
          </tbody>
        </table></div>
      </section>
      <section class="panel" aria-labelledby="directory-density-title">
        <h2 id="directory-density-title">Directory density</h2>
        <p>{value(len(directories["files"]))} directories with direct production Lua files.</p>
      </section>
      <section class="panel" aria-labelledby="tools-title">
        <h2 id="tools-title">Analyzer versions</h2>
        <div class="table-wrap"><table>
          <tbody>
            <tr><th scope="row">Lizard</th><td>{value(tools["lizard"])}</td></tr>
            <tr><th scope="row">jscpd</th><td>{value(tools["jscpd"])}</td></tr>
            <tr><th scope="row">Graphify</th><td>{value(tools["graphify"])}</td></tr>
          </tbody>
        </table></div>
      </section>
      <section class="panel" aria-labelledby="human-reports-title">
        <h2 id="human-reports-title">Human reports</h2>
        <ul>
{human_markup}
        </ul>
      </section>
      <section class="panel" aria-labelledby="machine-downloads-title">
        <h2 id="machine-downloads-title">Machine downloads</h2>
        <ul>
{machine_markup}
        </ul>
      </section>
      <section class="panel" aria-labelledby="visibility-title">
        <h2 id="visibility-title">Callable visibility</h2>
        <p>Visibility is a proxy for how many Lizard function rows Graphify exposes as callable nodes; it is not a semantic correctness score.</p>
        <div class="table-wrap"><table>
          <tbody>
            <tr><th scope="row">Lizard functions</th><td>{value(visibility["lizardFunctions"])}</td></tr>
            <tr><th scope="row">Graphify callables</th><td>{value(visibility["graphifyCallables"])}</td></tr>
            <tr><th scope="row">Ratio</th><td>{display(visibility["ratio"])}</td></tr>
          </tbody>
        </table></div>
        <h3>Per-file structural observations</h3>
        <div class="table-wrap"><table>
          <thead><tr><th scope="col">Path</th><th scope="col">Lizard functions</th><th scope="col">Graphify callables</th><th scope="col">Visibility</th><th scope="col">Max CCN</th><th scope="col">Max NLOC</th><th scope="col">Physical lines</th><th scope="col">Fan-in</th><th scope="col">Fan-out</th><th scope="col">Hotspot state</th></tr></thead>
          <tbody>
{file_rows_markup}
          </tbody>
        </table></div>
      </section>
      <section class="panel" aria-labelledby="hotspots-title">
        <h2 id="hotspots-title">Structural hotspots</h2>
{hotspot_note}
      </section>
{render_hotspot_table("CCN hotspots", hotspots["maxCcn"], "maxCcn")}
{render_hotspot_table("NLOC hotspots", hotspots["maxNloc"], "maxNloc")}
{render_hotspot_table("Physical-line hotspots", hotspots["physicalLines"], "physicalLines")}
{render_outlier_table("Low visibility outliers", structure["outliers"]["lowVisibility"])}
{render_outlier_table("Fan-out outliers", structure["outliers"]["fanOut"])}
      <section class="panel" aria-labelledby="architecture-note-title">
        <h2 id="architecture-note-title">Architecture interpretation</h2>
        <p>Inferred calls remain heuristic; Graphify <strong>INFERRED</strong> cross-file call relationships must not be treated like <strong>EXTRACTED</strong> import edges.</p>
        <p>Provenance: extracted {value(architecture["provenance"]["extracted"])}, inferred {value(architecture["provenance"]["inferred"])}, ambiguous {value(architecture["provenance"]["ambiguous"])}.</p>
      </section>
    </main>
  </body>
</html>
"""


def _build_model(
    site_root: Path, repository_root: Path, structural_paths: Iterable[str]
) -> dict[str, Any]:
    reports_root = site_root / "codehealth" / "reports"
    report_paths = {
        "lizard": reports_root / "lizard" / "functions.csv",
        "jscpd": reports_root / "jscpd" / "jscpd-report.json",
        "graphify": reports_root / "graphify" / "graph.json",
    }
    lizard = _parse_lizard_report(report_paths["lizard"])
    graphify = _parse_graphify_report(report_paths["graphify"])
    subsystems = lizard.pop("subsystems")
    complexity = {key: value for key, value in lizard.items() if key != "files"}
    architecture = {
        key: value for key, value in graphify.items() if key not in {"files", "extractedImportPairs"}
    }
    source, directories = _source_census(repository_root, structural_paths)
    generated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    committed_at = _git_committed_at(repository_root)
    model = {
        "schemaVersion": REPORT_SCHEMA_VERSION,
        "measurementVersion": _HISTORY.MEASUREMENT_VERSION,
        "commit": _git_commit(repository_root),
        "committedAt": committed_at,
        "generatedAt": generated_at,
        "tools": {
            "lizard": _version("lizard"),
            "jscpd": _version("jscpd"),
            "graphify": _version("graphify"),
        },
        "scope": {
            "structural": "production-lua",
            "excludedPrefixes": EXCLUDED_PREFIXES,
        },
        "complexity": complexity,
        "duplication": _parse_jscpd_report(report_paths["jscpd"]),
        "architecture": architecture,
        "subsystems": subsystems,
        "source": source,
        "directories": directories,
        "structure": _build_structure_metrics(lizard, graphify, source),
    }
    return model


def _build_structure_report(
    lizard_csv: Path, repository_root: Path, structural_paths: Iterable[str]
) -> dict[str, Any]:
    lizard = _parse_lizard_report(lizard_csv)
    source, directories = _source_census(repository_root, structural_paths)
    files = []
    for row in source["files"]:
        path = row["path"]
        max_ccn, max_nloc = _lizard_maxima(lizard, path)
        files.append(
            {
                "path": path,
                "maxCcn": max_ccn,
                "maxNloc": max_nloc,
                "physicalLines": row["physicalLines"],
                "hotspotIgnored": row["hotspotIgnored"],
            }
        )
    files.sort(key=lambda row: row["path"])
    return {
        "schemaVersion": 4,
        "source": source,
        "directories": directories,
        "structure": {"files": files, "hotspotPolicy": _hotspot_policy()},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-root", type=Path, default=None)
    parser.add_argument("--lizard-csv", type=Path, default=None)
    parser.add_argument("--structure-report", type=Path, default=None)
    parser.add_argument("--repository-root", type=Path, default=None)
    parser.add_argument("--structural-manifest", type=Path, default=None)
    parser.add_argument("--previous-history", type=Path, default=None)
    args = parser.parse_args(argv)
    site_mode = args.site_root is not None
    structure_mode = args.lizard_csv is not None or args.structure_report is not None
    if site_mode == structure_mode:
        parser.error("exactly one of --site-root or --lizard-csv/--structure-report is required")
    if structure_mode and (args.lizard_csv is None or args.structure_report is None):
        parser.error("--lizard-csv and --structure-report are both required for structure-report mode")
    if site_mode:
        site_root = args.site_root.resolve()
        if args.structural_manifest is None:
            parser.error("--structural-manifest is required with --site-root")
        repository_root = (
            args.repository_root.resolve()
            if args.repository_root is not None
            else Path(__file__).resolve().parents[2]
        )
        try:
            structural_paths = _load_structural_manifest(args.structural_manifest)
            model = _build_model(site_root, repository_root, structural_paths)
            previous = None
            if args.previous_history is not None:
                previous = _load_json(args.previous_history)
            history = _HISTORY.merge(previous, _HISTORY.entry_from_report(model))
            previous_entry = _HISTORY.previous_entry(history, model["commit"])
            quality_report = site_root / "codehealth" / "quality-report.json"
            history_report = site_root / "codehealth" / "history.json"
            summary_page = site_root / "codehealth" / "index.html"
            quality_report.write_text(json.dumps(model, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            history_report.write_text(json.dumps(history, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            summary_page.write_text(_render_summary(model, history, previous_entry), encoding="utf-8")
            _load_json(quality_report)
            _load_json(history_report)
        except (OSError, ValueError) as error:
            print(f"codehealth report: {error}", flush=True)
            return 1
        return 0
    repository_root = (
        args.repository_root.resolve()
        if args.repository_root is not None
        else Path(__file__).resolve().parents[2]
    )
    try:
        if args.structural_manifest is None:
            parser.error("--structural-manifest is required with --lizard-csv/--structure-report")
        structural_paths = _load_structural_manifest(args.structural_manifest)
        model = _build_structure_report(args.lizard_csv, repository_root, structural_paths)
        args.structure_report.write_text(
            json.dumps(model, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        _load_json(args.structure_report)
    except (OSError, ValueError) as error:
        print(f"codehealth report: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
