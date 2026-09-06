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
from pathlib import Path
import statistics
import subprocess
from typing import Any


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


def _parse_lizard_report(path: Path) -> dict[str, Any]:
    try:
        with path.open(newline="", encoding="utf-8") as report_file:
            reader = csv.DictReader(report_file)
            if reader.fieldnames is None or "NLOC" not in reader.fieldnames or "CCN" not in reader.fieldnames:
                raise ValueError(f"Lizard report {path} must have NLOC and CCN headers")
            nloc_values: list[int | float] = []
            ccn_values: list[int | float] = []
            file_metrics: dict[str, dict[str, int | float]] = {}
            has_file_column = "file" in reader.fieldnames
            for row in reader:
                if not row or any(value is None or value.strip() == "" for value in row.values()):
                    raise ValueError(f"Lizard report {path} contains an empty row")
                nloc = _number(row["NLOC"], path, "NLOC")
                ccn = _number(row["CCN"], path, "CCN")
                nloc_values.append(nloc)
                ccn_values.append(ccn)
                if has_file_column:
                    source_file = _normalize_source_file(row["file"], path)
                    metrics = file_metrics.setdefault(
                        source_file,
                        {"functions": 0, "maxCcn": ccn, "maxNloc": nloc},
                    )
                    metrics["functions"] += 1
                    metrics["maxCcn"] = max(metrics["maxCcn"], ccn)
                    metrics["maxNloc"] = max(metrics["maxNloc"], nloc)
    except OSError as error:
        raise ValueError(f"cannot read Lizard report {path}: {error}") from error
    if not nloc_values:
        raise ValueError(f"Lizard report {path} contains no function rows")
    return {
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


def _normalize_source_file(source_file: Any, path: Path) -> str:
    if not isinstance(source_file, str) or not source_file:
        raise ValueError(f"Graphify report {path} contains an invalid source_file")
    normalized = source_file.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized.startswith("/")
        or (len(normalized) >= 2 and normalized[1] == ":")
        or ".." in parts
        or any(not part for part in parts)
    ):
        raise ValueError(f"Graphify report {path} contains a non-portable source_file {source_file!r}")
    if not normalized.endswith(".lua"):
        raise ValueError(f"Graphify report {path} contains a non-Lua source_file {source_file!r}")
    if _is_excluded_source(normalized):
        raise ValueError(f"Graphify report {path} contains an excluded source_file {source_file!r}")
    return normalized


def _load_source_scope():
    module_path = Path(__file__).with_name("source_scope.py")
    module_spec = importlib.util.spec_from_file_location("source_scope", module_path)
    if module_spec is None or module_spec.loader is None:
        raise ValueError(f"cannot load source scope from {module_path}")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _source_census(repository_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    source_scope = _load_source_scope()
    production_paths = source_scope.paths_for_scope(repository_root, "production")
    if not production_paths:
        raise ValueError("source classification produced an empty production manifest")
    source_files: list[dict[str, Any]] = []
    directory_counts: dict[str, int] = {}
    for source_file in production_paths:
        source_path = repository_root / source_file
        try:
            raw = source_path.read_bytes()
        except OSError as error:
            raise ValueError(f"cannot read production source {source_file}: {error}") from error
        source_files.append(
            {
                "path": source_file,
                "bytes": len(raw),
                "physicalLines": len(raw.decode("utf-8").splitlines()),
            }
        )
        directory = str(Path(source_file).parent).replace("\\", "/")
        directory_counts[directory] = directory_counts.get(directory, 0) + 1
    directories = [
        {"path": path, "directProductionFiles": count}
        for path, count in sorted(directory_counts.items())
    ]
    return {"files": source_files}, {"files": directories}


def _policy_report(site_root: Path, repository_root: Path) -> dict[str, Any]:
    policy_path = site_root / "codehealth" / "reports" / "lua-policy.json"
    if not policy_path.exists():
        return {"findings": 0, "byKind": {}}
    report = _load_json(policy_path)
    findings = report.get("findings")
    if not isinstance(findings, list):
        raise ValueError(f"Lua policy report {policy_path} must contain findings")
    source_scope = _load_source_scope()
    tracked = set(source_scope.tracked_paths(repository_root))
    normalized_findings: list[dict[str, Any]] = []
    for finding in findings:
        if not isinstance(finding, dict) or not isinstance(finding.get("path"), str):
            raise ValueError(f"Lua policy report {policy_path} contains an invalid finding")
        path = finding["path"].replace("\\", "/")
        if path.startswith("/") or ".." in path.split("/") or path not in tracked:
            raise ValueError(f"Lua policy report {policy_path} contains an out-of-scope path {path!r}")
        normalized_findings.append(finding)
    if normalized_findings != sorted(
        normalized_findings, key=lambda finding: (finding["path"], finding.get("line", 0), finding.get("kind", ""))
    ):
        raise ValueError(f"Lua policy report {policy_path} findings are not deterministic")
    by_kind: dict[str, int] = {}
    for finding in normalized_findings:
        kind = finding.get("kind")
        if not isinstance(kind, str) or not kind:
            raise ValueError(f"Lua policy report {policy_path} contains a finding without kind")
        by_kind[kind] = by_kind.get(kind, 0) + 1
    return {"findings": len(normalized_findings), "byKind": dict(sorted(by_kind.items()))}


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


def _lizard_maxima(lizard: dict[str, Any], path: str) -> tuple[Any, Any]:
    metrics = lizard["files"].get(path)
    if metrics is None:
        return None, None
    return metrics.get("maxCcn"), metrics.get("maxNloc")


def _build_structure_metrics(lizard: dict[str, Any], graphify: dict[str, Any]) -> dict[str, Any]:
    lizard_files: dict[str, dict[str, int | float]] = lizard["files"]
    graphify_files: dict[str, int] = graphify["files"]
    paths = sorted(set(lizard_files) | set(graphify_files))
    fan_in = {path: 0 for path in paths}
    fan_out = {path: 0 for path in paths}
    for source, target in graphify["extractedImportPairs"]:
        if source in fan_out and target in fan_in:
            fan_out[source] += 1
            fan_in[target] += 1

    files: list[dict[str, Any]] = []
    for path in paths:
        lizard_metrics = lizard_files.get(path)
        lizard_functions = int(lizard_metrics["functions"]) if lizard_metrics is not None else 0
        graphify_callables = graphify_files.get(path, 0)
        max_ccn, max_nloc = _lizard_maxima(lizard, path)
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
                "importFanIn": fan_in[path],
                "importFanOut": fan_out[path],
            }
        )

    low_visibility = sorted(
        (row for row in files if row["lizardFunctions"] >= 8),
        key=lambda row: (
            row["callableVisibility"] is not None,
            row["callableVisibility"] or 0,
            -row["lizardFunctions"],
            row["path"],
        ),
    )[:20]
    complexity = sorted(
        (row for row in files if row["lizardFunctions"] > 0),
        key=lambda row: (-row["maxCcn"], -row["maxNloc"], row["path"]),
    )[:20]
    fan_outliers = sorted(files, key=lambda row: (-row["importFanOut"], row["path"]))[:20]
    return {
        "callableVisibility": {
            "lizardFunctions": lizard["functions"],
            "graphifyCallables": sum(graphify_files.values()),
            "ratio": (
                sum(graphify_files.values()) / lizard["functions"] if lizard["functions"] else None
            ),
        },
        "files": files,
        "outliers": {
            "lowVisibility": low_visibility,
            "complexity": complexity,
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


def _render_summary(model: dict[str, Any]) -> str:
    def value(item: Any) -> str:
        return html.escape(str(item))

    def display(item: Any) -> str:
        return "—" if item is None else value(item)

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
    policy = model["policy"]
    visibility = structure["callableVisibility"]
    cards = (
        ("Functions", complexity["functions"]),
        ("Duplicated lines", duplication["duplicatedLines"]),
        ("Architecture modules", architecture["modules"]),
        ("Callable visibility proxy", visibility["ratio"]),
    )
    card_markup = "\n".join(
        f'        <article class="card"><h3>{html.escape(title)}</h3><p>{value(metric)}</p></article>'
        for title, metric in cards
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
    file_rows_markup = "\n".join(
        "            <tr>"
        f"<td>{value(row['path'])}</td>"
        f"<td>{value(row['lizardFunctions'])}</td>"
        f"<td>{value(row['graphifyCallables'])}</td>"
        f"<td>{display(row['callableVisibility'])}</td>"
        f"<td>{display(row['maxCcn'])}</td>"
        f"<td>{display(row['maxNloc'])}</td>"
        f"<td>{value(row['importFanIn'])}</td>"
        f"<td>{value(row['importFanOut'])}</td>"
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
        <p>{value(len(source["files"]))} production Lua files, with bytes and physical-line measurements.</p>
      </section>
      <section class="panel" aria-labelledby="directory-density-title">
        <h2 id="directory-density-title">Directory density</h2>
        <p>{value(len(directories["files"]))} directories with direct production Lua files.</p>
      </section>
      <section class="panel" aria-labelledby="policy-findings-title">
        <h2 id="policy-findings-title">Policy findings</h2>
        <p>{value(policy["findings"])} report-mode Lua annotation and diagnostic findings.</p>
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
          <thead><tr><th scope="col">Path</th><th scope="col">Lizard functions</th><th scope="col">Graphify callables</th><th scope="col">Visibility</th><th scope="col">Max CCN</th><th scope="col">Max NLOC</th><th scope="col">Fan-in</th><th scope="col">Fan-out</th></tr></thead>
          <tbody>
{file_rows_markup}
          </tbody>
        </table></div>
      </section>
{render_outlier_table("Low visibility outliers", structure["outliers"]["lowVisibility"])}
{render_outlier_table("Complexity outliers", structure["outliers"]["complexity"])}
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


def _build_model(site_root: Path, repository_root: Path) -> dict[str, Any]:
    reports_root = site_root / "codehealth" / "reports"
    report_paths = {
        "lizard": reports_root / "lizard" / "functions.csv",
        "jscpd": reports_root / "jscpd" / "jscpd-report.json",
        "graphify": reports_root / "graphify" / "graph.json",
    }
    lizard = _parse_lizard_report(report_paths["lizard"])
    graphify = _parse_graphify_report(report_paths["graphify"])
    complexity = {key: value for key, value in lizard.items() if key != "files"}
    architecture = {
        key: value for key, value in graphify.items() if key not in {"files", "extractedImportPairs"}
    }
    source, directories = _source_census(repository_root)
    model = {
        "schemaVersion": 4,
        "commit": _git_commit(repository_root),
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
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
        "source": source,
        "directories": directories,
        "policy": _policy_report(site_root, repository_root),
        "structure": _build_structure_metrics(lizard, graphify),
    }
    return model


def _build_structure_report(lizard_csv: Path, repository_root: Path) -> dict[str, Any]:
    lizard = _parse_lizard_report(lizard_csv)
    source, directories = _source_census(repository_root)
    files = []
    for row in source["files"]:
        path = row["path"]
        max_ccn, max_nloc = _lizard_maxima(lizard, path)
        files.append({"path": path, "maxCcn": max_ccn, "maxNloc": max_nloc})
    files.sort(key=lambda row: row["path"])
    return {
        "schemaVersion": 4,
        "source": source,
        "directories": directories,
        "structure": {"files": files},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-root", type=Path, default=None)
    parser.add_argument("--lizard-csv", type=Path, default=None)
    parser.add_argument("--structure-report", type=Path, default=None)
    parser.add_argument("--repository-root", type=Path, default=None)
    args = parser.parse_args(argv)
    site_mode = args.site_root is not None
    structure_mode = args.lizard_csv is not None or args.structure_report is not None
    if site_mode == structure_mode:
        parser.error("exactly one of --site-root or --lizard-csv/--structure-report is required")
    if structure_mode and (args.lizard_csv is None or args.structure_report is None):
        parser.error("--lizard-csv and --structure-report are both required for structure-report mode")
    if site_mode:
        site_root = args.site_root.resolve()
        repository_root = Path(__file__).resolve().parents[2]
        try:
            model = _build_model(site_root, repository_root)
            quality_report = site_root / "codehealth" / "quality-report.json"
            summary_page = site_root / "codehealth" / "index.html"
            quality_report.write_text(json.dumps(model, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            summary_page.write_text(_render_summary(model), encoding="utf-8")
            _load_json(quality_report)
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
        model = _build_structure_report(args.lizard_csv, repository_root)
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
