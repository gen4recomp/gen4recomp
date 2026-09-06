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
                REPORT, "_version", return_value="test"
            ):
                model = REPORT._build_model(site_root, site_root)

            self.assertEqual(model["schemaVersion"], 4)
            self.assertTrue(
                {
                    "schemaVersion",
                    "commit",
                    "generatedAt",
                    "tools",
                    "scope",
                    "source",
                    "directories",
                    "policy",
                    "complexity",
                    "duplication",
                    "architecture",
                    "structure",
                }.issubset(model)
            )
            self.assertEqual(model["tools"], {"lizard": "test", "jscpd": "test", "graphify": "test"})
            self.assertEqual(model["scope"]["structural"], "production-lua")
            self.assertEqual(model["scope"]["excludedPrefixes"], REPORT.EXCLUDED_PREFIXES)
            self.assertNotIn("luaLanguageServer", model["tools"])
            self.assertNotIn("files", model["complexity"])
            source_files = {row["path"]: row for row in model["source"]["files"]}
            self.assertEqual(source_files["game/hgss/src/field/FieldRuntime.lua"]["physicalLines"], 2)
            self.assertGreater(source_files["game/hgss/src/field/FieldRuntime.lua"]["bytes"], 0)
            directories = {row["path"]: row for row in model["directories"]["files"]}
            self.assertEqual(directories["libs/hgss/src/field"]["directProductionFiles"], 1)
            self.assertEqual(model["policy"]["findings"], 0)
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
                        "importFanIn": 0,
                        "importFanOut": 0,
                    },
                ],
            )
            self.assertEqual(
                [row["path"] for row in structure["outliers"]["lowVisibility"]],
                ["game/c.lua", "game/b.lua", "game/a.lua"],
            )
            self.assertEqual(
                [row["path"] for row in structure["outliers"]["complexity"]],
                ["game/c.lua", "game/b.lua", "game/a.lua"],
            )
            self.assertEqual(
                [row["path"] for row in structure["outliers"]["fanOut"]],
                ["game/a.lua", "game/b.lua", "game/c.lua", "game/d.lua"],
            )

            json.loads(json.dumps(model))
            summary = REPORT._render_summary(model).lower()
            self.assertIn("source census", summary)
            self.assertIn("directory density", summary)
            self.assertIn("policy findings", summary)
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
            "schemaVersion": 4,
            "commit": "a" * 40,
            "generatedAt": "2026-01-01T00:00:00Z",
            "tools": {"lizard": "1.23.0", "jscpd": "5.0.16", "graphify": "0.9.50"},
            "scope": {"structural": "production-lua", "excludedPrefixes": []},
            "complexity": {"functions": 1, "ccn": {"median": 1, "p90": 1, "p95": 1, "p99": 1, "max": 1}, "nloc": {"median": 1, "p95": 1, "max": 1}},
            "duplication": {"sources": 1, "clones": 0, "duplicatedLines": 0, "percentage": 0},
            "architecture": {"modules": 1, "nodes": 1, "edges": 1, "communities": 1, "importEdges": 1, "importCycleGroups": 0, "provenance": {"extracted": 1, "inferred": 0, "ambiguous": 0}},
            "source": {"files": [{"path": "game/a.lua", "bytes": 10, "physicalLines": 1}]},
            "directories": {"files": [{"path": "game", "directProductionFiles": 1}]},
            "policy": {"findings": 0},
            "structure": {"callableVisibility": {"lizardFunctions": 1, "graphifyCallables": 1, "ratio": 1.0}, "files": [], "outliers": {"lowVisibility": [], "complexity": [], "fanOut": []}},
        }
        html = REPORT._render_summary(model)
        self.assertIn('href="reports/lizard/index.html"', html)
        self.assertIn('href="quality-report.json" download', html)
        self.assertIn('href="reports/graphify/graph.json" download', html)
        self.assertNotIn('href="reports/luals/check.json"', html)
        self.assertIn("INFERRED", html)

    def run_structure_report_mode(
        self, repository: Path, lizard_csv: Path, output: Path
    ) -> subprocess.CompletedProcess[str]:
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
            self.assertEqual(
                {path: source_rows[path]["physicalLines"] for path in expected_lines},
                expected_lines,
            )
            for row in model["source"]["files"]:
                self.assertGreater(row["bytes"], 0)
            directories = {row["path"]: row["directProductionFiles"] for row in model["directories"]["files"]}
            self.assertEqual(directories.get("game"), 3)
            structure = {row["path"]: row for row in model["structure"]["files"]}
            self.assertEqual(structure["game/a.lua"]["maxCcn"], 7)
            self.assertEqual(structure["game/a.lua"]["maxNloc"], 30)
            self.assertEqual(structure["game/b.lua"]["maxCcn"], 4)
            self.assertEqual(structure["game/b.lua"]["maxNloc"], 15)
            self.assertIn("game/data-only.lua", source_rows)

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
            expected_source, expected_directories = REPORT._source_census(repository)
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
            self.assertTrue(
                data_row is None
                or (data_row.get("maxCcn") in (None, 0) and data_row.get("maxNloc") in (None, 0))
            )

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
                REPORT, "_version", return_value="test"
            ):
                self.assertEqual(REPORT.main(["--site-root", str(site_root)]), 0)
            model = json.loads((site_root / "codehealth" / "quality-report.json").read_text(encoding="utf-8"))
            self.assertEqual(model["schemaVersion"], 4)
            self.assertTrue((site_root / "codehealth" / "index.html").exists())


if __name__ == "__main__":
    unittest.main()
