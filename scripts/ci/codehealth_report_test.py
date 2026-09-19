#!/usr/bin/env python3
"""Tests for the standard-library code-health report normalizer."""

from __future__ import annotations

import csv
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("codehealth_report.py")
MODULE_SPEC = importlib.util.spec_from_file_location("codehealth_report", MODULE_PATH)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
REPORT = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(REPORT)

SCOPE_PATH = Path(__file__).with_name("codehealth_scope.py")


def load_scope_owner():
    scope_spec = importlib.util.spec_from_file_location("codehealth_scope_owner", SCOPE_PATH)
    if scope_spec is None or scope_spec.loader is None:
        raise AssertionError("code-health scope owner module cannot be loaded")
    owner = importlib.util.module_from_spec(scope_spec)
    scope_spec.loader.exec_module(owner)
    return owner


def _write_minimal_site_fixture(root: Path) -> tuple[Path, list[str]]:
    site_root = root / "site"
    reports_root = site_root / "codehealth" / "reports"
    for report_directory in ("lizard", "jscpd", "graphify"):
        (reports_root / report_directory).mkdir(parents=True)
    (site_root / "game").mkdir(parents=True)
    (site_root / "game" / "a.lua").write_text(
        "local value = {}\nfunction value.compute()\nreturn 1\nend\nreturn value\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "--quiet"], cwd=site_root, check=True)
    subprocess.run(["git", "add", "."], cwd=site_root, check=True)
    with (reports_root / "lizard" / "functions.csv").open("w", newline="", encoding="utf-8") as report_file:
        writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
        writer.writeheader()
        writer.writerow({"NLOC": "10", "CCN": "3", "file": "game/a.lua", "function": "compute"})
    (reports_root / "jscpd" / "jscpd-report.json").write_text(
        json.dumps(
            {"statistics": {"total": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0}}}
        ),
        encoding="utf-8",
    )
    (reports_root / "graphify" / "graph.json").write_text(
        json.dumps(
            {
                "directed": True,
                "nodes": [{"id": "a", "source_file": "game/a.lua"}],
                "links": [
                    {
                        "source": "a",
                        "target": "a",
                        "relation": "imports",
                        "confidence": "EXTRACTED",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    return site_root, ["game/a.lua"]


def _read_lizard_files(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as report_file:
        return list(csv.DictReader(report_file))


def _write_production_fixture(repository: Path) -> dict[str, int]:
    sources = {
        "game/a.lua": "local value = {}\nfunction value.compute()\nreturn 1\nend\nreturn value\n",
        "game/b.lua": "local other = {}\nfunction other.compute()\nreturn 2\nend\nreturn other\n",
        "game/data-only.lua": "return {\n1,\n2,\n3,\n}\n",
    }
    for relative, content in sources.items():
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "init", "--quiet"], cwd=repository, check=True)
    subprocess.run(["git", "config", "user.email", "codehealth-test@example.com"], cwd=repository, check=True)
    subprocess.run(["git", "config", "user.name", "Code Health Test"], cwd=repository, check=True)
    subprocess.run(["git", "add", "."], cwd=repository, check=True)
    return {relative: len(content.splitlines()) for relative, content in sources.items()}


def _write_lizard_fixture(path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as report_file:
        writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
        writer.writeheader()
        writer.writerow({"NLOC": "30", "CCN": "7", "file": "game/a.lua", "function": "compute"})
        writer.writerow({"NLOC": "2", "CCN": "2", "file": "game/a.lua", "function": "helper"})
        writer.writerow({"NLOC": "15", "CCN": "4", "file": "game/b.lua", "function": "compute"})


def _sized_source(line_count: int) -> str:
    lines = [f"-- filler {index}" for index in range(line_count - 1)]
    lines.append("return {}")
    return "\n".join(lines) + "\n"


def _write_hotspot_site(
    root: Path,
    sources: dict[str, str],
    lizard_rows: list[dict[str, str]],
    nodes: list[dict[str, object]],
    links: list[dict[str, object]],
) -> tuple[Path, Path]:
    site_root = root / "site"
    reports_root = site_root / "codehealth" / "reports"
    for report_directory in ("lizard", "jscpd", "graphify"):
        (reports_root / report_directory).mkdir(parents=True)
    for relative, content in sources.items():
        path = site_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "init", "--quiet"], cwd=site_root, check=True)
    subprocess.run(["git", "add", "."], cwd=site_root, check=True)
    lizard_csv = reports_root / "lizard" / "functions.csv"
    with lizard_csv.open("w", newline="", encoding="utf-8") as report_file:
        writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
        writer.writeheader()
        for row in lizard_rows:
            writer.writerow(row)
    (reports_root / "jscpd" / "jscpd-report.json").write_text(
        json.dumps(
            {
                "statistics": {
                    "total": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0}
                }
            }
        ),
        encoding="utf-8",
    )
    (reports_root / "graphify" / "graph.json").write_text(
        json.dumps({"directed": True, "nodes": nodes, "links": links}),
        encoding="utf-8",
    )
    return site_root, lizard_csv


class CodeHealthReportTest(unittest.TestCase):
    """Protect report parsing, scope validation, and summary links."""

    def test_lizard_metrics_use_header_names_and_nearest_rank(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "functions.csv"
            with path.open("w", newline="", encoding="utf-8") as report_file:
                writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN"])
                writer.writeheader()
                for nloc, ccn in ((10, 1), (20, 3), (30, 5), (40, 7)):
                    writer.writerow({"NLOC": nloc, "CCN": ccn})
            metrics = REPORT._parse_lizard_report(path)
            self.assertEqual(metrics["functions"], 4)
            self.assertEqual(metrics["ccn"], {"median": 4.0, "p90": 7, "p95": 7, "p99": 7, "max": 7})
            self.assertEqual(metrics["nloc"], {"median": 25.0, "p95": 40, "max": 40})
            self.assertEqual(REPORT._nearest_rank([1, 2, 3, 4], 0.5), 2)

    def test_structural_visibility_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site_root = Path(directory)
            reports_root = site_root / "codehealth" / "reports"
            for report_directory in ("lizard", "jscpd", "graphify"):
                (reports_root / report_directory).mkdir(parents=True)

            for source_file, source in {
                "game/a.lua": "return {}\n",
                "game/b.lua": "return {}\nreturn {}\n",
                "game/c.lua": "return {}\n",
                "game/d.lua": "return {}\n",
                "game/hgss/src/field/FieldRuntime.lua": "return {}\n-- concrete product source\n",
                "libs/hgss/src/field/Map.lua": "return {}\n",
            }.items():
                path = site_root / source_file
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")
            subprocess.run(["git", "init", "--quiet"], cwd=site_root, check=True)
            subprocess.run(["git", "add", "."], cwd=site_root, check=True)

            (reports_root / "jscpd" / "jscpd-report.json").write_text(
                json.dumps(
                    {
                        "statistics": {
                            "total": {
                                "sources": 3,
                                "clones": 0,
                                "duplicatedLines": 0,
                                "percentage": 0,
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )

            lizard_path = reports_root / "lizard" / "functions.csv"
            with lizard_path.open("w", newline="", encoding="utf-8") as report_file:
                fieldnames = [
                    "NLOC",
                    "CCN",
                    "token_count",
                    "parameter_count",
                    "location",
                    "file",
                    "function",
                    "long_name",
                    "start_line",
                    "end_line",
                ]
                writer = csv.DictWriter(report_file, fieldnames=fieldnames)
                writer.writeheader()
                for file_name, function_count, max_nloc, max_ccn in (
                    ("game/a.lua", 8, 30, 3),
                    ("game/b.lua", 10, 15, 9),
                    ("game/c.lua", 9, 20, 9),
                ):
                    for function_index in range(function_count):
                        writer.writerow(
                            {
                                "NLOC": max_nloc if function_index == 0 else 1,
                                "CCN": max_ccn if function_index == 0 else 1,
                                "token_count": 1,
                                "parameter_count": 0,
                                "location": 1,
                                "file": file_name,
                                "function": f"function_{function_index}",
                                "long_name": f"function_{function_index}",
                                "start_line": 1,
                                "end_line": 1,
                            }
                        )

            nodes = [
                {"id": f"a{index}", "source_file": "game/a.lua", "_callable": True}
                for index in range(8)
            ]
            nodes.extend(
                {
                    "id": f"b{index}",
                    "source_file": "game/b.lua",
                    "_callable": index < 2,
                }
                for index in range(10)
            )
            nodes.extend(
                [
                    {"id": "c0", "source_file": "game/c.lua"},
                    {"id": "d0", "source_file": "game/d.lua", "_callable": True},
                    {"id": "external"},
                ]
            )
            links = [
                {"source": "a0", "target": "b0", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "a1", "target": "b1", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "a2", "target": "b0", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "a0", "target": "b0", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "a3", "target": "c0", "relation": "imports", "confidence": "INFERRED"},
                {"source": "b0", "target": "a0", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "b1", "target": "c0", "relation": "imports", "confidence": "AMBIGUOUS"},
                {"source": "c0", "target": "c0", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "external", "target": "a0", "relation": "calls", "confidence": "INFERRED"},
            ]
            (reports_root / "graphify" / "graph.json").write_text(
                json.dumps({"directed": True, "nodes": nodes, "links": links}),
                encoding="utf-8",
            )

            with mock.patch.object(REPORT, "_git_commit", return_value="a" * 40), mock.patch.object(
                REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
            ), mock.patch.object(REPORT, "_version", return_value="test"):
                manifest = [
                    "game/a.lua",
                    "game/b.lua",
                    "game/c.lua",
                    "game/d.lua",
                    "game/hgss/src/field/FieldRuntime.lua",
                    "libs/hgss/src/field/Map.lua",
                ]
                model = REPORT._build_model(site_root, site_root, manifest)

            self.assertEqual(model["schemaVersion"], 7)
            self.assertTrue(
                {
                    "schemaVersion",
                    "commit",
                    "generatedAt",
                    "tools",
                    "scope",
                    "source",
                    "directories",
                    "complexity",
                    "duplication",
                    "architecture",
                    "structure",
                }.issubset(model)
            )
            self.assertNotIn("policy", model)
            self.assertEqual(model["tools"], {"lizard": "test", "jscpd": "test", "graphify": "test"})
            self.assertEqual(model["scope"], load_scope_owner().scope_metadata())
            self.assertNotIn("excludedPrefixes", model["scope"])
            self.assertNotIn("luaLanguageServer", model["tools"])
            self.assertNotIn("files", model["complexity"])
            source_files = {row["path"]: row for row in model["source"]["files"]}
            self.assertEqual(source_files["game/hgss/src/field/FieldRuntime.lua"]["physicalLines"], 2)
            self.assertGreater(source_files["game/hgss/src/field/FieldRuntime.lua"]["bytes"], 0)
            directories = {row["path"]: row for row in model["directories"]["files"]}
            self.assertEqual(directories["libs/hgss/src/field"]["directProductionFiles"], 1)
            self.assertNotIn("policy", model)
            structure = model["structure"]
            self.assertEqual(
                structure["callableVisibility"]["lizardFunctions"],
                27,
            )
            self.assertEqual(
                structure["callableVisibility"]["graphifyCallables"],
                11,
            )
            self.assertAlmostEqual(structure["callableVisibility"]["ratio"], 11 / 27)
            self.assertEqual(
                structure["files"],
                [
                    {
                        "path": "game/a.lua",
                        "lizardFunctions": 8,
                        "graphifyCallables": 8,
                        "callableVisibility": 1.0,
                        "maxCcn": 3,
                        "maxNloc": 30,
                        "physicalLines": 1,
                        "hotspotIgnored": False,
                        "importFanIn": 1,
                        "importFanOut": 1,
                    },
                    {
                        "path": "game/b.lua",
                        "lizardFunctions": 10,
                        "graphifyCallables": 2,
                        "callableVisibility": 0.2,
                        "maxCcn": 9,
                        "maxNloc": 15,
                        "physicalLines": 2,
                        "hotspotIgnored": False,
                        "importFanIn": 1,
                        "importFanOut": 1,
                    },
                    {
                        "path": "game/c.lua",
                        "lizardFunctions": 9,
                        "graphifyCallables": 0,
                        "callableVisibility": 0.0,
                        "maxCcn": 9,
                        "maxNloc": 20,
                        "physicalLines": 1,
                        "hotspotIgnored": False,
                        "importFanIn": 0,
                        "importFanOut": 0,
                    },
                    {
                        "path": "game/d.lua",
                        "lizardFunctions": 0,
                        "graphifyCallables": 1,
                        "callableVisibility": None,
                        "maxCcn": None,
                        "maxNloc": None,
                        "physicalLines": 1,
                        "hotspotIgnored": False,
                        "importFanIn": 0,
                        "importFanOut": 0,
                    },
                    {
                        "path": "game/hgss/src/field/FieldRuntime.lua",
                        "lizardFunctions": 0,
                        "graphifyCallables": 0,
                        "callableVisibility": None,
                        "maxCcn": None,
                        "maxNloc": None,
                        "physicalLines": 2,
                        "hotspotIgnored": False,
                        "importFanIn": 0,
                        "importFanOut": 0,
                    },
                    {
                        "path": "libs/hgss/src/field/Map.lua",
                        "lizardFunctions": 0,
                        "graphifyCallables": 0,
                        "callableVisibility": None,
                        "maxCcn": None,
                        "maxNloc": None,
                        "physicalLines": 1,
                        "hotspotIgnored": False,
                        "importFanIn": 0,
                        "importFanOut": 0,
                    },
                ],
            )
            self.assertEqual(
                structure["hotspotPolicy"],
                {
                    "thresholds": {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200},
                    "ignoreMarker": "-- codehealth: ignore-hotspot",
                    "ignoreScanLines": 5,
                },
            )
            self.assertEqual(
                {metric: [row["path"] for row in rows] for metric, rows in structure["hotspots"].items()},
                {"maxCcn": [], "maxNloc": [], "physicalLines": []},
            )
            self.assertEqual(
                [row["path"] for row in structure["outliers"]["lowVisibility"]],
                ["game/c.lua", "game/b.lua", "game/a.lua"],
            )
            self.assertNotIn("complexity", structure["outliers"])
            self.assertEqual(
                [row["path"] for row in structure["outliers"]["fanOut"]],
                [
                    "game/a.lua",
                    "game/b.lua",
                    "game/c.lua",
                    "game/d.lua",
                    "game/hgss/src/field/FieldRuntime.lua",
                    "libs/hgss/src/field/Map.lua",
                ],
            )

            json.loads(json.dumps(model))
            summary = REPORT._render_summary(model).lower()
            self.assertIn("source census", summary)
            self.assertIn("directory density", summary)
            self.assertNotIn("policy findings", summary)
            self.assertIn("luals", summary)
            self.assertIn("binding ci", summary)
            self.assertIn("visibility is a proxy", summary)
            self.assertIn("inferred calls remain heuristic", summary)
            self.assertNotIn("reports/luals/check.json", summary)

    def test_jscpd_reads_only_pinned_statistics_total_shape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jscpd-report.json"
            path.write_text(
                json.dumps(
                    {
                        "duplicates": [],
                        "statistics": {
                            "total": {
                                "sources": 12,
                                "clones": 3,
                                "duplicatedLines": 45,
                                "percentage": 6.25,
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                REPORT._parse_jscpd_report(path),
                {"sources": 12, "clones": 3, "duplicatedLines": 45, "percentage": 6.25},
            )

            unsupported_shapes = (
                {"statistic": {"total": {"sources": 12}}},
                {},
                {"statistics": {}},
                {"statistics": {"total": {"sources": 12}}},
                {"statistics": {"total": []}},
            )
            for unsupported_shape in unsupported_shapes:
                path.write_text(json.dumps(unsupported_shape), encoding="utf-8")
                with self.subTest(report=unsupported_shape):
                    with self.assertRaisesRegex(ValueError, "statistics.total"):
                        REPORT._parse_jscpd_report(path)

    def test_graphify_requires_directed_nonempty_graph(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.json"
            graph = {
                "directed": False,
                "nodes": [{"id": "a", "source_file": "game/a.lua"}],
                "links": [],
            }
            path.write_text(json.dumps(graph), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "directed"):
                REPORT._parse_graphify_report(path)

    def test_graphify_adapter_builds_and_serializes_reciprocal_directed_links(self) -> None:
        calls: dict[str, object] = {}

        class DirectedGraph:
            def is_directed(self) -> bool:
                return True

            def number_of_nodes(self) -> int:
                return 2

            def number_of_edges(self) -> int:
                return 2

        graph = DirectedGraph()

        def extract(paths, cache_root, *, root, parallel, max_workers):
            calls["extract"] = (paths, cache_root, root, parallel, max_workers)
            return {"nodes": ["a", "b"], "edges": ["a->b", "b->a"]}

        def build_from_json(extraction, *, root, directed):
            calls["build"] = (extraction, root, directed)
            return graph

        def cluster(value):
            calls["cluster"] = value
            return {0: ["a", "b"]}

        def to_json(value, communities, output_path, *, force):
            calls["to_json"] = (value, communities, output_path, force)
            Path(output_path).write_text(
                json.dumps(
                    {
                        "directed": True,
                        "nodes": [
                            {"id": "a", "source_file": "a.lua"},
                            {"id": "b", "source_file": "nested/b.lua"},
                        ],
                        "links": [
                            {"source": "a", "target": "b", "relation": "imports", "confidence": "EXTRACTED"},
                            {"source": "b", "target": "a", "relation": "imports", "confidence": "EXTRACTED"},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            return True

        fake_graphify = types.ModuleType("graphify")
        fake_graphify.extract = extract
        fake_graphify.build_from_json = build_from_json
        fake_graphify.cluster = cluster
        fake_graphify.to_json = to_json

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            (root / "nested").mkdir(parents=True)
            (root / "a.lua").write_text("return {}", encoding="utf-8")
            (root / "nested" / "b.lua").write_text("return {}", encoding="utf-8")
            (root / "ignored.txt").write_text("not Lua", encoding="utf-8")
            (Path(directory) / "outside.lua").write_text("return {}", encoding="utf-8")
            output = Path(directory) / "reports" / "graph.json"
            cache_root = Path(directory) / "cache"

            adapter_spec = importlib.util.spec_from_file_location(
                "codehealth_graphify_test_adapter",
                MODULE_PATH.with_name("codehealth_graphify.py"),
            )
            self.assertIsNotNone(adapter_spec)
            assert adapter_spec is not None
            assert adapter_spec.loader is not None
            adapter = importlib.util.module_from_spec(adapter_spec)
            with mock.patch.dict(sys.modules, {"graphify": fake_graphify}):
                adapter_spec.loader.exec_module(adapter)
                self.assertEqual(adapter.main([
                    "--source-root", str(root),
                    "--output", str(output),
                    "--cache-root", str(cache_root),
                    "--max-workers", "4",
                ]), 0)

            extracted_paths, extracted_cache, extracted_root, parallel, workers = calls["extract"]
            self.assertEqual(extracted_paths, [root / "a.lua", root / "nested" / "b.lua"])
            self.assertEqual(extracted_cache, cache_root)
            self.assertEqual(extracted_root, root)
            self.assertTrue(parallel)
            self.assertEqual(workers, 4)
            self.assertEqual(calls["build"][2], True)
            self.assertIs(calls["cluster"], graph)
            self.assertEqual(calls["to_json"][1], {0: ["a", "b"]})
            self.assertTrue(calls["to_json"][3])
            serialized = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(serialized["directed"], True)
            self.assertEqual(
                {(link["source"], link["target"]) for link in serialized["links"]},
                {("a", "b"), ("b", "a")},
            )

    def test_graphify_rejects_nonportable_non_lua_and_excluded_sources(self) -> None:
        bad_paths = (
            "/game/a.lua",
            "../game/a.lua",
            "C:\\game\\a.lua",
            "game/a.py",
            "tests/a.lua",
            "libs/tests/a.lua",
            "vendor/a.lua",
            "types/a.lua",
            "tools/a.lua",
            "scripts/a.lua",
            "site/a.lua",
            ".github/a.lua",
            ".agents/a.lua",
            ".cache/a.lua",
            ".claude/a.lua",
            "import-output/a.lua",
            "tmp/a.lua",
            "log/a.lua",
            "data/generated/a.lua",
            "data/scripts/overrides/a.lua",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.json"
            for source_file in bad_paths:
                path.write_text(
                    json.dumps(
                        {
                            "directed": True,
                            "nodes": [{"id": "a", "source_file": source_file}],
                            "links": [{"source": "a", "target": "a", "relation": "imports", "confidence": "EXTRACTED"}],
                        }
                    ),
                    encoding="utf-8",
                )
                with self.subTest(source_file=source_file):
                    with self.assertRaisesRegex(ValueError, "graph.json"):
                        REPORT._parse_graphify_report(path)

    def test_graphify_counts_provenance_and_import_cycles(self) -> None:
        graph = {
            "directed": True,
            "nodes": [
                {"id": "a", "source_file": "game/a.lua", "community": 1},
                {"id": "b", "source_file": "game/b.lua", "community": 1},
                {"id": "c", "source_file": "game/c.lua", "community": 2},
                {"id": "external"},
            ],
            "links": [
                {"source": "a", "target": "b", "relation": "imports", "confidence": "EXTRACTED"},
                {"source": "b", "target": "a", "relation": "imports", "confidence": "INFERRED"},
                {"source": "b", "target": "c", "relation": "imports", "confidence": "AMBIGUOUS"},
                {"source": "a", "target": "b", "relation": "imports", "confidence": "EXTRACTED"},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.json"
            path.write_text(json.dumps(graph), encoding="utf-8")
            metrics = REPORT._parse_graphify_report(path)
        self.assertEqual(metrics["modules"], 3)
        self.assertEqual(metrics["nodes"], 4)
        self.assertEqual(metrics["edges"], 4)
        self.assertEqual(metrics["communities"], 2)
        self.assertEqual(metrics["importEdges"], 3)
        self.assertEqual(metrics["importCycleGroups"], 1)
        self.assertEqual(metrics["provenance"], {"extracted": 2, "inferred": 1, "ambiguous": 1})
        self.assertEqual(REPORT._import_cycle_groups({"a": {"b"}, "b": {"a"}, "c": set()}), 1)
        self.assertEqual(REPORT._import_cycle_groups({"a": {"b"}, "b": {"c"}, "c": set()}), 0)
        self.assertEqual(REPORT._import_cycle_groups({"a": {"a"}}), 1)

    def test_graphify_validates_link_source_scope(self) -> None:
        graph = {
            "directed": True,
            "nodes": [
                {"id": "a", "source_file": "game/a.lua"},
                {"id": "b", "source_file": "game/b.lua"},
            ],
            "links": [
                {
                    "source": "a",
                    "target": "b",
                    "relation": "imports",
                    "confidence": "EXTRACTED",
                    "source_file": "tests/a.lua",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.json"
            path.write_text(json.dumps(graph), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "excluded source_file"):
                REPORT._parse_graphify_report(path)

    def test_graphify_rejects_unhashable_node_ids(self) -> None:
        graph = {
            "directed": True,
            "nodes": [{"id": [], "source_file": "game/a.lua"}],
            "links": [{"source": [], "target": [], "relation": "imports", "confidence": "EXTRACTED"}],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "graph.json"
            path.write_text(json.dumps(graph), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "node id"):
                REPORT._parse_graphify_report(path)

    def test_rendered_summary_has_relative_human_and_download_links(self) -> None:
        model = {
            "schemaVersion": 5,
            "commit": "a" * 40,
            "generatedAt": "2026-01-01T00:00:00Z",
            "tools": {"lizard": "1.23.0", "jscpd": "5.0.16", "graphify": "0.9.50"},
            "scope": {"structural": "production-lua", "excludedPrefixes": []},
            "complexity": {"functions": 1, "ccn": {"median": 1, "p90": 1, "p95": 1, "p99": 1, "max": 1}, "nloc": {"median": 1, "p95": 1, "max": 1}},
            "duplication": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0},
            "architecture": {"modules": 1, "nodes": 1, "edges": 1, "communities": 1, "importEdges": 1, "importCycleGroups": 0, "provenance": {"extracted": 1, "inferred": 0, "ambiguous": 0}},
            "source": {"files": [{"path": "game/a.lua", "bytes": 10, "physicalLines": 1}]},
            "directories": {"files": [{"path": "game", "directProductionFiles": 1}]},
            "structure": {"callableVisibility": {"lizardFunctions": 1, "graphifyCallables": 1, "ratio": 1.0}, "files": [], "hotspotPolicy": {"thresholds": {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200}, "ignoreMarker": "-- codehealth: ignore-hotspot", "ignoreScanLines": 5}, "hotspots": {"maxCcn": [], "maxNloc": [], "physicalLines": []}, "outliers": {"lowVisibility": [], "fanOut": []}},
        }
        html = REPORT._render_summary(model)
        self.assertIn('href="reports/lizard/index.html"', html)
        self.assertIn('href="quality-report.json" download', html)
        self.assertIn('href="reports/graphify/graph.json" download', html)
        self.assertNotIn('href="reports/luals/check.json"', html)
        self.assertNotIn("policy", html.lower())
        self.assertIn("INFERRED", html)

    def test_site_scope_matches_scope_owner_and_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site_root, manifest = _write_minimal_site_fixture(Path(directory))
            owner = load_scope_owner()
            with mock.patch.object(REPORT, "_git_commit", return_value="a" * 40), mock.patch.object(
                REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
            ), mock.patch.object(REPORT, "_version", return_value="test"):
                model = REPORT._build_model(site_root, site_root, manifest)
            self.assertEqual(model["schemaVersion"], 7)
            self.assertEqual(model["scope"], owner.scope_metadata())
            self.assertNotIn("excludedPrefixes", model["scope"])

    def test_site_and_structure_versions_remain_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site_root, manifest = _write_minimal_site_fixture(Path(directory))
            with mock.patch.object(REPORT, "_git_commit", return_value="a" * 40), mock.patch.object(
                REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
            ), mock.patch.object(REPORT, "_version", return_value="test"):
                model = REPORT._build_model(site_root, site_root, manifest)
            self.assertEqual(model["measurementVersion"], 1)
            lizard_csv = site_root / "codehealth" / "reports" / "lizard" / "functions.csv"
            lightweight = REPORT._build_structure_report(lizard_csv, site_root, manifest)
            self.assertEqual(lightweight["schemaVersion"], 4)

    def run_structure_report_mode(
        self, repository: Path, lizard_csv: Path, output: Path
    ) -> subprocess.CompletedProcess[str]:
        structural = {row["file"] for row in _read_lizard_files(lizard_csv)}
        manifest = output.parent / "structural-manifest.txt"
        manifest.write_text("\n".join(sorted(structural)) + "\n", encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--lizard-csv",
                str(lizard_csv),
                "--structure-report",
                str(output),
                "--repository-root",
                str(repository),
                "--structural-manifest",
                str(manifest),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_structure_report_mode_writes_minimal_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repo"
            repository.mkdir()
            expected_lines = _write_production_fixture(repository)
            lizard_csv = root / "functions.csv"
            _write_lizard_fixture(lizard_csv)
            output = root / "quality-report.json"
            result = self.run_structure_report_mode(repository, lizard_csv, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(model["schemaVersion"], 4)
            source_rows = {row["path"]: row for row in model["source"]["files"]}
            self.assertEqual(set(source_rows), {"game/a.lua", "game/b.lua"})
            self.assertNotIn("game/data-only.lua", source_rows)
            self.assertEqual(
                source_rows["game/a.lua"]["physicalLines"],
                expected_lines["game/a.lua"],
            )
            self.assertEqual(
                source_rows["game/b.lua"]["physicalLines"],
                expected_lines["game/b.lua"],
            )
            for row in model["source"]["files"]:
                self.assertGreater(row["bytes"], 0)
            directories = {row["path"]: row["directProductionFiles"] for row in model["directories"]["files"]}
            self.assertEqual(directories.get("game"), 2)
            structure = {row["path"]: row for row in model["structure"]["files"]}
            self.assertEqual(structure["game/a.lua"]["maxCcn"], 7)
            self.assertEqual(structure["game/a.lua"]["maxNloc"], 30)
            self.assertEqual(structure["game/b.lua"]["maxCcn"], 4)
            self.assertEqual(structure["game/b.lua"]["maxNloc"], 15)
            self.assertNotIn("game/data-only.lua", structure)

    def test_structure_report_agrees_with_census_and_lizard_maxima(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repo"
            repository.mkdir()
            _write_production_fixture(repository)
            lizard_csv = root / "functions.csv"
            _write_lizard_fixture(lizard_csv)
            output = root / "quality-report.json"
            result = self.run_structure_report_mode(repository, lizard_csv, output)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            model = json.loads(output.read_text(encoding="utf-8"))
            manifest = ["game/a.lua", "game/b.lua"]
            expected_source, expected_directories = REPORT._source_census(repository, manifest)
            self.assertEqual(
                {row["path"]: row for row in model["source"]["files"]},
                {row["path"]: row for row in expected_source["files"]},
            )
            self.assertEqual(
                {row["path"]: row for row in model["directories"]["files"]},
                {row["path"]: row for row in expected_directories["files"]},
            )
            expected_lizard = REPORT._parse_lizard_report(lizard_csv)["files"]
            actual_structure = {row["path"]: row for row in model["structure"]["files"]}
            for path, metrics in expected_lizard.items():
                self.assertIn(path, actual_structure)
                self.assertEqual(actual_structure[path]["maxCcn"], metrics["maxCcn"])
                self.assertEqual(actual_structure[path]["maxNloc"], metrics["maxNloc"])
            data_row = actual_structure.get("game/data-only.lua")
            self.assertIsNone(data_row)

    def test_structure_report_rejects_mixed_or_missing_modes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            both = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--site-root",
                    str(root / "site"),
                    "--lizard-csv",
                    str(root / "functions.csv"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(both.returncode, 0)
            missing_output = subprocess.run(
                [sys.executable, str(MODULE_PATH), "--lizard-csv", str(root / "functions.csv")],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing_output.returncode, 0)

    def test_full_site_command_still_writes_quality_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repo"
            repository.mkdir()
            (repository / "game").mkdir(parents=True)
            (repository / "game" / "a.lua").write_text(
                "local value = {}\nfunction value.compute()\nreturn 1\nend\nreturn value\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "init", "--quiet"], cwd=repository, check=True)
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            site_root = Path(directory) / "site"
            reports_root = site_root / "codehealth" / "reports"
            (reports_root / "lizard").mkdir(parents=True)
            (reports_root / "jscpd").mkdir(parents=True)
            (reports_root / "graphify").mkdir(parents=True)
            with (reports_root / "lizard" / "functions.csv").open("w", newline="", encoding="utf-8") as report_file:
                writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
                writer.writeheader()
                writer.writerow({"NLOC": "10", "CCN": "3", "file": "game/a.lua", "function": "compute"})
            (reports_root / "jscpd" / "jscpd-report.json").write_text(
                json.dumps(
                    {"statistics": {"total": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0}}}
                ),
                encoding="utf-8",
            )
            (reports_root / "graphify" / "graph.json").write_text(
                json.dumps(
                    {
                        "directed": True,
                        "nodes": [{"id": "a", "source_file": "game/a.lua"}],
                        "links": [
                            {
                                "source": "a",
                                "target": "a",
                                "relation": "imports",
                                "confidence": "EXTRACTED",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.object(REPORT, "_git_commit", return_value="b" * 40), mock.patch.object(
                REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
            ), mock.patch.object(REPORT, "_version", return_value="test"):
                manifest = Path(directory) / "structural-manifest.txt"
                manifest.write_text("game/a.lua\n", encoding="utf-8")
                self.assertEqual(
                    REPORT.main(
                        [
                            "--site-root",
                            str(site_root),
                            "--repository-root",
                            str(repository),
                            "--structural-manifest",
                            str(manifest),
                        ]
                    ),
                    0,
                )
            model = json.loads((site_root / "codehealth" / "quality-report.json").read_text(encoding="utf-8"))
            self.assertEqual(model["schemaVersion"], 7)
            self.assertNotIn("policy", model)
            self.assertTrue((site_root / "codehealth" / "index.html").exists())

    def build_site_model(self, site_root: Path, manifest: list[str] | None = None) -> dict:
        with mock.patch.object(REPORT, "_git_commit", return_value="a" * 40), mock.patch.object(
            REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
        ), mock.patch.object(REPORT, "_version", return_value="test"):
            if manifest is None:
                manifest = sorted(
                    str(path.relative_to(site_root)).replace("\\", "/")
                    for path in site_root.rglob("*.lua")
                    if "codehealth" not in path.parts
                )
            return REPORT._build_model(site_root, site_root, manifest)

    def test_threshold_hotspot_lists_are_data_driven(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {
                "game/below_all.lua": _sized_source(3),
                "game/at_ccn_limit.lua": _sized_source(3),
                "game/above_ccn.lua": _sized_source(3),
                "game/tie_ccn_a.lua": _sized_source(3),
                "game/tie_ccn_b.lua": _sized_source(3),
                "game/at_nloc_limit.lua": _sized_source(3),
                "game/above_nloc.lua": _sized_source(3),
                "game/at_line_limit.lua": _sized_source(1200),
                "game/above_line_count.lua": _sized_source(1201),
                "game/no_function_long.lua": _sized_source(1250),
            }
            lizard_rows = [
                {"NLOC": "10", "CCN": "5", "file": "game/below_all.lua", "function": "run"},
                {"NLOC": "10", "CCN": "25", "file": "game/at_ccn_limit.lua", "function": "run"},
                {"NLOC": "10", "CCN": "26", "file": "game/above_ccn.lua", "function": "run"},
                {"NLOC": "150", "CCN": "30", "file": "game/tie_ccn_a.lua", "function": "run"},
                {"NLOC": "10", "CCN": "30", "file": "game/tie_ccn_b.lua", "function": "run"},
                {"NLOC": "100", "CCN": "5", "file": "game/at_nloc_limit.lua", "function": "run"},
                {"NLOC": "101", "CCN": "5", "file": "game/above_nloc.lua", "function": "run"},
                {"NLOC": "10", "CCN": "5", "file": "game/at_line_limit.lua", "function": "run"},
                {"NLOC": "10", "CCN": "5", "file": "game/above_line_count.lua", "function": "run"},
            ]
            ordered = sorted(sources)
            nodes: list[dict[str, object]] = [
                {"id": f"node-{index}", "source_file": path}
                for index, path in enumerate(ordered)
            ]
            links: list[dict[str, object]] = [
                {
                    "source": "node-0",
                    "target": "node-1",
                    "relation": "imports",
                    "confidence": "EXTRACTED",
                }
            ]
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, links)
            model = self.build_site_model(site_root)
            structure = model["structure"]
            self.assertEqual(
                structure["hotspotPolicy"],
                {
                    "thresholds": {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200},
                    "ignoreMarker": "-- codehealth: ignore-hotspot",
                    "ignoreScanLines": 5,
                },
            )
            files = {row["path"]: row for row in structure["files"]}
            self.assertEqual(set(files), set(sources))
            for path, row in files.items():
                self.assertEqual(row["physicalLines"], len(sources[path].splitlines()))
                self.assertFalse(row["hotspotIgnored"])
            self.assertIsNone(files["game/no_function_long.lua"]["maxCcn"])
            self.assertIsNone(files["game/no_function_long.lua"]["maxNloc"])
            hotspots = structure["hotspots"]
            self.assertEqual(
                [row["path"] for row in hotspots["maxCcn"]],
                ["game/tie_ccn_a.lua", "game/tie_ccn_b.lua", "game/above_ccn.lua"],
            )
            self.assertEqual(
                [row["path"] for row in hotspots["maxNloc"]],
                ["game/tie_ccn_a.lua", "game/above_nloc.lua"],
            )
            self.assertEqual(
                [row["path"] for row in hotspots["physicalLines"]],
                ["game/no_function_long.lua", "game/above_line_count.lua"],
            )

    def test_exact_top_of_file_marker_suppresses_target_lists_only(self) -> None:
        marker = "-- codehealth: ignore-hotspot"
        body = "local value = {}\nreturn value\n"
        sources = {
            "game/hot_ignored_exact.lua": (
                "-- module role comment\n"
                "---@class Suppressed\n"
                "local value = {}\n"
                "\n"
                f"{marker}\n"
                "return value\n"
            ),
            "game/hot_ignored_padded.lua": f"   {marker}  \n{body}",
            "game/hot_visible_sixth.lua": f"-- filler 0\n-- filler 1\n-- filler 2\n-- filler 3\n-- filler 4\n{marker}\n{body}",
            "game/hot_visible_extra.lua": f"{marker} until refactor\n{body}",
            "game/hot_visible_quoted.lua": f'local note = "{marker}"\n{body}',
        }
        lizard_rows = []
        for path in sources:
            for function_index in range(8):
                lizard_rows.append(
                    {
                        "NLOC": "150" if function_index == 0 else "1",
                        "CCN": "30" if function_index == 0 else "1",
                        "file": path,
                        "function": f"step_{function_index}",
                    }
                )
        nodes: list[dict[str, object]] = []
        links: list[dict[str, object]] = []
        for path in sorted(sources):
            stem = Path(path).stem.replace("hot_", "")
            first = {"id": f"{stem}-0", "source_file": path}
            second = {"id": f"{stem}-1", "source_file": path}
            if "ignored" not in path:
                first["_callable"] = True
                second["_callable"] = True
            nodes.extend([first, second])
        links.extend(
            [
                {
                    "source": "ignored_exact-0",
                    "target": "visible_sixth-0",
                    "relation": "imports",
                    "confidence": "EXTRACTED",
                },
                {
                    "source": "ignored_exact-1",
                    "target": "visible_extra-0",
                    "relation": "imports",
                    "confidence": "EXTRACTED",
                },
                {
                    "source": "visible_sixth-0",
                    "target": "visible_extra-0",
                    "relation": "imports",
                    "confidence": "EXTRACTED",
                },
            ]
        )
        with tempfile.TemporaryDirectory() as directory:
            site_root, lizard_csv = _write_hotspot_site(
                Path(directory), sources, lizard_rows, nodes, links
            )
            model = self.build_site_model(site_root)
            structure = model["structure"]
            files = {row["path"]: row for row in structure["files"]}
            self.assertEqual(set(files), set(sources))
            self.assertTrue(files["game/hot_ignored_exact.lua"]["hotspotIgnored"])
            self.assertTrue(files["game/hot_ignored_padded.lua"]["hotspotIgnored"])
            self.assertFalse(files["game/hot_visible_sixth.lua"]["hotspotIgnored"])
            self.assertFalse(files["game/hot_visible_extra.lua"]["hotspotIgnored"])
            self.assertFalse(files["game/hot_visible_quoted.lua"]["hotspotIgnored"])
            hotspots = structure["hotspots"]
            for metric in ("maxCcn", "maxNloc"):
                paths = [row["path"] for row in hotspots[metric]]
                self.assertNotIn("game/hot_ignored_exact.lua", paths)
                self.assertNotIn("game/hot_ignored_padded.lua", paths)
                self.assertIn("game/hot_visible_sixth.lua", paths)
                self.assertIn("game/hot_visible_extra.lua", paths)
                self.assertIn("game/hot_visible_quoted.lua", paths)
            self.assertEqual(
                [row["path"] for row in hotspots["physicalLines"]], []
            )
            low_visibility = [row["path"] for row in structure["outliers"]["lowVisibility"]]
            fan_out = [row["path"] for row in structure["outliers"]["fanOut"]]
            self.assertNotIn("complexity", structure["outliers"])
            self.assertEqual(set(structure["outliers"]), {"lowVisibility", "fanOut"})
            self.assertNotIn("game/hot_ignored_exact.lua", low_visibility)
            self.assertNotIn("game/hot_ignored_padded.lua", low_visibility)
            self.assertIn("game/hot_visible_sixth.lua", low_visibility)
            self.assertNotIn("game/hot_ignored_exact.lua", fan_out)
            self.assertNotIn("game/hot_ignored_padded.lua", fan_out)
            lightweight = REPORT._build_structure_report(lizard_csv, site_root, sorted(sources))
            self.assertEqual(lightweight["schemaVersion"], 4)
            self.assertEqual(
                lightweight["structure"]["hotspotPolicy"], structure["hotspotPolicy"]
            )
            light_files = {row["path"]: row for row in lightweight["structure"]["files"]}
            self.assertEqual(set(light_files), set(sources))
            for path in sources:
                self.assertEqual(
                    light_files[path]["hotspotIgnored"], files[path]["hotspotIgnored"]
                )
                self.assertEqual(
                    light_files[path]["physicalLines"], files[path]["physicalLines"]
                )
                self.assertEqual(light_files[path]["maxCcn"], files[path]["maxCcn"])
                self.assertEqual(light_files[path]["maxNloc"], files[path]["maxNloc"])

    def test_summary_presents_threshold_hotspots_and_suppression_state(self) -> None:
        visible = {
            "path": "game/hot_visible.lua",
            "lizardFunctions": 8,
            "graphifyCallables": 2,
            "callableVisibility": 0.25,
            "maxCcn": 30,
            "maxNloc": 150,
            "physicalLines": 40,
            "hotspotIgnored": False,
            "importFanIn": 0,
            "importFanOut": 1,
        }
        ignored = {
            "path": "game/hot_ignored.lua",
            "lizardFunctions": 8,
            "graphifyCallables": 0,
            "callableVisibility": 0.0,
            "maxCcn": 30,
            "maxNloc": 150,
            "physicalLines": 40,
            "hotspotIgnored": True,
            "importFanIn": 0,
            "importFanOut": 2,
        }
        policy = {
            "thresholds": {"maxCcn": 25, "maxNloc": 100, "physicalLines": 1200},
            "ignoreMarker": "-- codehealth: ignore-hotspot",
            "ignoreScanLines": 5,
        }
        model = {
            "schemaVersion": 5,
            "commit": "a" * 40,
            "generatedAt": "2026-01-01T00:00:00Z",
            "tools": {"lizard": "test", "jscpd": "test", "graphify": "test"},
            "scope": {"structural": "production-lua", "excludedPrefixes": []},
            "complexity": {
                "functions": 16,
                "ccn": {"median": 1, "p90": 30, "p95": 30, "p99": 30, "max": 30},
                "nloc": {"median": 1, "p95": 150, "max": 150},
            },
            "duplication": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0},
            "architecture": {
                "modules": 2,
                "nodes": 2,
                "edges": 1,
                "communities": 1,
                "importEdges": 1,
                "importCycleGroups": 0,
                "provenance": {"extracted": 1, "inferred": 0, "ambiguous": 0},
            },
            "source": {
                "files": [
                    {"path": "game/hot_visible.lua", "bytes": 100, "physicalLines": 40},
                    {"path": "game/hot_ignored.lua", "bytes": 120, "physicalLines": 40},
                ]
            },
            "directories": {"files": [{"path": "game", "directProductionFiles": 2}]},
            "structure": {
                "callableVisibility": {
                    "lizardFunctions": 16,
                    "graphifyCallables": 2,
                    "ratio": 2 / 16,
                },
                "files": [visible, ignored],
                "outliers": {
                    "lowVisibility": [visible],
                    "fanOut": [visible],
                },
                "hotspotPolicy": policy,
                "hotspots": {
                    "maxCcn": [visible],
                    "maxNloc": [visible],
                    "physicalLines": [],
                },
            },
        }
        rendered = REPORT._render_summary(model).lower()
        self.assertRegex(rendered, r"hotspot.{0,80}ccn|ccn.{0,80}hotspot")
        self.assertRegex(rendered, r"hotspot.{0,80}nloc|nloc.{0,80}hotspot")
        self.assertRegex(rendered, r"hotspot.{0,80}physical|physical.{0,80}hotspot")
        self.assertIn("ignor", rendered)
        self.assertIn("raw", rendered)
        self.assertIn("game/hot_visible.lua", rendered)
        self.assertIn("game/hot_ignored.lua", rendered)


def _commit_fixture_repo(site_root: Path) -> None:
    subprocess.run(["git", "config", "user.email", "codehealth-test@example.com"], cwd=site_root, check=True)
    subprocess.run(["git", "config", "user.name", "Code Health Test"], cwd=site_root, check=True)
    subprocess.run(["git", "add", "."], cwd=site_root, check=True)
    subprocess.run(["git", "commit", "--quiet", "--message", "fixture"], cwd=site_root, check=True)


def _trend_nodes(paths: list[str]) -> list[dict[str, object]]:
    return [{"id": f"node-{index}", "source_file": path} for index, path in enumerate(paths)]


def _trend_link(index_by_path: dict[str, int], source: str, target: str) -> dict[str, object]:
    return {
        "source": f"node-{index_by_path[source]}",
        "target": f"node-{index_by_path[target]}",
        "relation": "imports",
        "confidence": "EXTRACTED",
    }


def _trend_self_link() -> list[dict[str, object]]:
    return [{"source": "node-0", "target": "node-0", "relation": "imports", "confidence": "EXTRACTED"}]


class CodeHealthTrendsTest(unittest.TestCase):
    """Protect erosion, subsystem, headline, fan, and compact-history behavior."""

    def build_trend_model(self, site_root: Path, manifest: list[str] | None = None) -> dict:
        with mock.patch.object(REPORT, "_git_commit", return_value="c" * 40), mock.patch.object(
            REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"
        ), mock.patch.object(REPORT, "_version", return_value="test"):
            if manifest is None:
                manifest = sorted(
                    str(path.relative_to(site_root)).replace("\\", "/")
                    for path in site_root.rglob("*.lua")
                    if "codehealth" not in path.parts
                )
            return REPORT._build_model(site_root, site_root, manifest)

    def test_erosion_counts_only_high_complexity_mass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {
                "game/at_limit.lua": _sized_source(120),
                "game/above_limit.lua": _sized_source(120),
                "game/calm.lua": _sized_source(420),
            }
            lizard_rows = [
                {"NLOC": "100", "CCN": "10", "file": "game/at_limit.lua", "function": "run"},
                {"NLOC": "100", "CCN": "11", "file": "game/above_limit.lua", "function": "run"},
                {"NLOC": "400", "CCN": "5", "file": "game/calm.lua", "function": "run"},
            ]
            ordered = sorted(sources)
            nodes = _trend_nodes(ordered)
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            model = self.build_trend_model(site_root)
            erosion = model["complexity"]["erosion"]
            self.assertEqual(erosion["threshold"], 10)
            self.assertAlmostEqual(erosion["totalMass"], 310.0)
            self.assertAlmostEqual(erosion["highComplexityMass"], 110.0)
            self.assertEqual(erosion["highComplexityFunctions"], 1)
            self.assertEqual(erosion["functions"], 3)
            self.assertAlmostEqual(erosion["score"], 110.0 / 310.0)

    def test_subsystems_group_functions_without_file_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {
                "libs/assets/pack.lua": _sized_source(30),
                "libs/nds/cart.lua": _sized_source(30),
                "game/hgss/field.lua": _sized_source(30),
                "game/party.lua": _sized_source(30),
                "app/main.lua": _sized_source(30),
                "romdump/tool.lua": _sized_source(120),
                "gen4/convert.lua": _sized_source(30),
            }
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": path, "function": "run"}
                for path in sorted(sources)
                if path != "romdump/tool.lua"
            ]
            lizard_rows.append(
                {"NLOC": "100", "CCN": "11", "file": "romdump/tool.lua", "function": "run"}
            )
            ordered = sorted(sources)
            nodes = _trend_nodes(ordered)
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            model = self.build_trend_model(site_root)
            subsystems = {row["id"]: row for row in model["subsystems"]}
            self.assertEqual(
                sorted(subsystems),
                ["app", "game", "game/hgss", "gen4", "libs/assets", "libs/nds", "romdump"],
            )
            self.assertEqual(
                [row["id"] for row in model["subsystems"]], sorted(subsystems)
            )
            for identifier in ("app", "game", "game/hgss", "gen4", "libs/assets", "libs/nds"):
                self.assertEqual(subsystems[identifier]["functions"], 1)
                self.assertEqual(subsystems[identifier]["highComplexityFunctions"], 0)
                self.assertEqual(subsystems[identifier]["erosion"], 0.0)
            self.assertEqual(subsystems["romdump"]["functions"], 1)
            self.assertEqual(subsystems["romdump"]["highComplexityFunctions"], 1)
            self.assertAlmostEqual(subsystems["romdump"]["erosion"], 1.0)

    def test_headline_cards_and_fan_distributions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {
                "game/hub.lua": _sized_source(30),
                "game/left.lua": _sized_source(30),
                "game/middle.lua": _sized_source(30),
                "game/right.lua": _sized_source(30),
                "game/leaf.lua": _sized_source(30),
            }
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": path, "function": "run"}
                for path in sorted(sources)
            ]
            ordered = sorted(sources)
            index_by_path = {path: index for index, path in enumerate(ordered)}
            links = [
                _trend_link(index_by_path, "game/hub.lua", "game/left.lua"),
                _trend_link(index_by_path, "game/hub.lua", "game/middle.lua"),
                _trend_link(index_by_path, "game/hub.lua", "game/right.lua"),
                _trend_link(index_by_path, "game/hub.lua", "game/leaf.lua"),
                _trend_link(index_by_path, "game/left.lua", "game/middle.lua"),
                _trend_link(index_by_path, "game/middle.lua", "game/right.lua"),
            ]
            nodes = _trend_nodes(ordered)
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, links)
            model = self.build_trend_model(site_root)
            distributions = model["structure"]["distributions"]
            self.assertEqual(distributions["importFanOut"], {"p95": 4, "p99": 4, "max": 4})
            self.assertEqual(distributions["importFanIn"], {"p95": 2, "p99": 2, "max": 2})
            rendered = REPORT._render_summary(model)
            headline = rendered.split("Headline metrics", 1)[1].split("</section>", 1)[0]
            for title in ("Erosion", "Duplication percentage", "CCN p95", "Import-cycle groups"):
                self.assertIn(title, headline)
            self.assertNotIn("Callable visibility", headline)
            self.assertIn("Callable visibility", rendered)

    def test_nonpositive_nloc_fails_normalization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "functions.csv"
            with path.open("w", newline="", encoding="utf-8") as report_file:
                writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
                writer.writeheader()
                writer.writerow({"NLOC": "0", "CCN": "3", "file": "game/a.lua", "function": "run"})
            with self.assertRaises(ValueError):
                REPORT._parse_lizard_report(path)

    def run_site_main(
        self, site_root: Path, repository: Path, manifest: Path, previous: Path | None
    ) -> int:
        with mock.patch.object(REPORT, "_version", return_value="test"), mock.patch.object(
            REPORT, "_git_commit", return_value="d" * 40
        ), mock.patch.object(REPORT, "_git_committed_at", return_value="2026-03-01T00:00:00Z"):
            args = [
                "--site-root",
                str(site_root),
                "--repository-root",
                str(repository),
                "--structural-manifest",
                str(manifest),
            ]
            if previous is not None:
                args += ["--previous-history", str(previous)]
            return REPORT.main(args)

    def write_previous_history(self, path: Path, entries: list[dict]) -> None:
        path.write_text(
            json.dumps({"schemaVersion": 1, "measurementVersion": 1, "entries": entries}),
            encoding="utf-8",
        )

    def history_entry(
        self, commit: str, committed: str, analyzed: str, **overrides: object
    ) -> dict:
        entry: dict = {
            "commit": commit,
            "committedAt": committed,
            "analyzedAt": analyzed,
            "files": 5,
            "physicalLines": 100,
            "functions": 5,
            "erosion": 0.1,
            "duplicationPercentage": 2.0,
            "ccnP95": 4,
            "ccnP99": 8,
            "importCycleGroups": 0,
            "fanOutP95": 1,
            "fanOutP99": 2,
        }
        entry.update(overrides)
        return entry

    def test_compatible_history_appends_and_renders_signed_deltas(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {"game/a.lua": _sized_source(30), "game/b.lua": _sized_source(30)}
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": "game/a.lua", "function": "run"},
                {"NLOC": "10", "CCN": "5", "file": "game/b.lua", "function": "run"},
            ]
            ordered = sorted(sources)
            nodes = _trend_nodes(ordered)
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            _commit_fixture_repo(site_root)
            previous_path = root / "previous.json"
            self.write_previous_history(
                previous_path,
                [self.history_entry("a" * 40, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")],
            )
            manifest = root / "structural-manifest.txt"
            manifest.write_text("game/a.lua\ngame/b.lua\n", encoding="utf-8")
            self.assertEqual(self.run_site_main(site_root, site_root, manifest, previous_path), 0)
            history = json.loads(
                (site_root / "codehealth" / "history.json").read_text(encoding="utf-8")
            )
            self.assertEqual(history["schemaVersion"], 1)
            self.assertEqual(history["measurementVersion"], 1)
            self.assertEqual(len(history["entries"]), 2)
            self.assertEqual(history["entries"][0]["commit"], "a" * 40)
            rendered = (site_root / "codehealth" / "index.html").read_text(encoding="utf-8")
            self.assertIn("a" * 40, rendered)
            self.assertRegex(rendered, r"[+-]\d")

    def test_baseline_without_previous_history_has_neutral_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {"game/a.lua": _sized_source(30)}
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": "game/a.lua", "function": "run"},
            ]
            nodes = _trend_nodes(sorted(sources))
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            _commit_fixture_repo(site_root)
            manifest = root / "structural-manifest.txt"
            manifest.write_text("game/a.lua\n", encoding="utf-8")
            self.assertEqual(self.run_site_main(site_root, site_root, manifest, None), 0)
            history = json.loads(
                (site_root / "codehealth" / "history.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(history["entries"]), 1)
            rendered = (site_root / "codehealth" / "index.html").read_text(encoding="utf-8")
            self.assertIn("aseline", rendered)

    def test_rendered_history_caps_visible_entries_without_truncating_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {"game/a.lua": _sized_source(30)}
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": "game/a.lua", "function": "run"},
            ]
            nodes = _trend_nodes(sorted(sources))
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            _commit_fixture_repo(site_root)
            entries = [
                self.history_entry(
                    format(index, "040x"),
                    f"2026-01-{(index % 28) + 1:02d}T00:00:00Z",
                    "2026-02-01T00:00:00Z",
                )
                for index in range(1, 56)
            ]
            previous_path = root / "previous.json"
            self.write_previous_history(previous_path, entries)
            manifest = root / "structural-manifest.txt"
            manifest.write_text("game/a.lua\n", encoding="utf-8")
            self.assertEqual(self.run_site_main(site_root, site_root, manifest, previous_path), 0)
            history = json.loads(
                (site_root / "codehealth" / "history.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(history["entries"]), 56)
            rendered = (site_root / "codehealth" / "index.html").read_text(encoding="utf-8")
            newest = history["entries"][-1]["commit"]
            oldest = history["entries"][0]["commit"]
            self.assertIn(newest, rendered)
            self.assertNotIn(oldest, rendered)

    def test_published_state_holds_only_current_detailed_reports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {"game/a.lua": _sized_source(30), "game/b.lua": _sized_source(30)}
            lizard_rows = [
                {"NLOC": "10", "CCN": "4", "file": "game/a.lua", "function": "run"},
                {"NLOC": "10", "CCN": "5", "file": "game/b.lua", "function": "run"},
            ]
            ordered = sorted(sources)
            nodes = _trend_nodes(ordered)
            site_root, _ = _write_hotspot_site(root, sources, lizard_rows, nodes, _trend_self_link())
            _commit_fixture_repo(site_root)
            previous_path = root / "previous.json"
            self.write_previous_history(
                previous_path,
                [
                    self.history_entry("a" * 40, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"),
                    self.history_entry("b" * 40, "2026-01-15T00:00:00Z", "2026-02-01T00:00:00Z"),
                ],
            )
            manifest = root / "structural-manifest.txt"
            manifest.write_text("game/a.lua\ngame/b.lua\n", encoding="utf-8")
            self.assertEqual(self.run_site_main(site_root, site_root, manifest, previous_path), 0)
            reports_root = site_root / "codehealth" / "reports"
            nested = sorted(
                path.relative_to(reports_root).parts[0]
                for path in reports_root.rglob("*")
                if path.is_dir()
            )
            self.assertEqual(sorted(set(nested)), ["graphify", "jscpd", "lizard"])
            rendered = (site_root / "codehealth" / "index.html").read_text(encoding="utf-8")
            self.assertIn("history.json", rendered)

    def test_fan_distributions_cover_single_and_two_file_sets(self) -> None:
        self.assertEqual(REPORT._distribution([3]), {"p95": 3, "p99": 3, "max": 3})
        self.assertEqual(REPORT._distribution([0, 4]), {"p95": 4, "p99": 4, "max": 4})


if __name__ == "__main__":
    unittest.main()
