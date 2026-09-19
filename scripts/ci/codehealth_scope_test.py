#!/usr/bin/env python3
"""Contract tests for the code-health executable-Lua scope.

Code health measures maintainability of executable production Lua. Declarative
data subtrees and header-marked data modules are excluded before analysis, and
only candidate files with at least one analyzer function row reach structural
census, clone detection, and import-graph work. Both the full site build and
the lightweight structural snapshot resolve scope through the same helper, and
the full build can analyze a detached target worktree with current tooling.
"""

from __future__ import annotations

import csv
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("codehealth_scope.py")
SNAPSHOT_PATH = Path(__file__).with_name("structure_snapshot.sh")


def load_scope_module():
    if not MODULE_PATH.is_file():
        raise AssertionError(
            "executable code-health scope must derive candidate and final "
            "structural manifests before these contract tests can pass"
        )
    module_spec = importlib.util.spec_from_file_location("codehealth_scope", MODULE_PATH)
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("executable code-health scope module cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _init_repository(files: dict[str, str]) -> Path:
    directory = Path(tempfile.mkdtemp())
    for relative, content in files.items():
        path = directory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "init", "--quiet"], cwd=directory, check=True)
    subprocess.run(
        ["git", "config", "user.email", "codehealth-test@example.com"],
        cwd=directory,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Code Health Test"], cwd=directory, check=True
    )
    subprocess.run(["git", "add", "."], cwd=directory, check=True)
    return directory


def _write_lizard_csv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as report_file:
        writer = csv.DictWriter(report_file, fieldnames=["NLOC", "CCN", "file", "function"])
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _function_body() -> str:
    return "local value = {}\nfunction value.compute()\nreturn 1\nend\nreturn value\n"


def _run_production_lizard_csv(work: Path, repository: Path, candidates: list[str]) -> Path:
    """Run the production Lizard CSV invocation and return the generated report."""
    if shutil.which("lizard") is None:
        raise AssertionError(
            "the real lizard analyzer must be installed for this composition test; refusing to skip"
        )
    manifest = work / "candidates.txt"
    manifest.write_text("\n".join(candidates) + "\n", encoding="utf-8")
    result = subprocess.run(
        ["lizard", "-l", "lua", "-t", "4", "-i", "-1", "-f", str(manifest), "-V", "--csv"],
        cwd=repository,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(
            "production lizard invocation failed: "
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )
    csv_path = work / "functions.csv"
    csv_path.write_text(result.stdout, encoding="utf-8")
    return csv_path


class CandidateScopeTest(unittest.TestCase):
    """Declarative production data stays out of the pre-analyzer candidate set."""

    def test_config_and_reference_subtrees_are_absent_from_candidates(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "romdump/src/engine.lua": _function_body(),
                "romdump/src/config/Table.lua": _function_body(),
                "romdump/src/reference/Map.lua": _function_body(),
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        candidates = scope.candidate_paths(repository)
        self.assertIn("romdump/src/engine.lua", candidates)
        self.assertNotIn("romdump/src/config/Table.lua", candidates)
        self.assertNotIn("romdump/src/reference/Map.lua", candidates)

    def test_header_marker_excludes_data_module_with_helpers(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "romdump/src/tables.lua": (
                    "-- codehealth: declarative\n" + _function_body()
                ),
                "romdump/src/engine.lua": _function_body(),
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        candidates = scope.candidate_paths(repository)
        self.assertIn("romdump/src/engine.lua", candidates)
        self.assertNotIn("romdump/src/tables.lua", candidates)

    def test_marker_beyond_header_window_does_not_exclude(self) -> None:
        scope = load_scope_module()
        content = (
            "-- line one\n-- line two\n-- line three\n-- line four\n"
            "-- line five\n-- codehealth: declarative\n" + _function_body()
        )
        repository = _init_repository({"romdump/src/tables.lua": content})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        candidates = scope.candidate_paths(repository)
        self.assertIn("romdump/src/tables.lua", candidates)

    def test_candidates_are_sorted_and_unique(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "romdump/src/zeta.lua": _function_body(),
                "game/src/alpha.lua": _function_body(),
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        candidates = scope.candidate_paths(repository)
        self.assertEqual(candidates, sorted(candidates))
        self.assertEqual(len(candidates), len(set(candidates)))

    def test_repository_subdirectory_is_rejected_as_analysis_root(self) -> None:
        scope = load_scope_module()
        repository = _init_repository({"game/src/alpha.lua": _function_body()})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with self.assertRaisesRegex(ValueError, "top level"):
            scope.candidate_paths(repository / "game")


class FinalStructuralScopeTest(unittest.TestCase):
    """Only candidates with analyzer function rows reach structural analysis."""

    def test_files_without_function_rows_are_absent(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "game/src/alpha.lua": _function_body(),
                "game/src/data.lua": "return {\n1,\n2,\n}\n",
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "functions.csv"
            _write_lizard_csv(
                csv_path,
                [
                    {
                        "NLOC": "10",
                        "CCN": "2",
                        "file": "game/src/alpha.lua",
                        "function": "compute",
                    }
                ],
            )
            candidates = scope.candidate_paths(repository)
            self.assertIn("game/src/data.lua", candidates)
            final = scope.final_paths(repository, candidates, csv_path)
            self.assertEqual(final, ["game/src/alpha.lua"])

    def test_final_manifest_is_sorted_regardless_of_analyzer_row_order(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "game/src/beta.lua": _function_body(),
                "game/src/alpha.lua": _function_body(),
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "functions.csv"
            _write_lizard_csv(
                csv_path,
                [
                    {
                        "NLOC": "10",
                        "CCN": "2",
                        "file": "game/src/beta.lua",
                        "function": "compute",
                    },
                    {
                        "NLOC": "10",
                        "CCN": "2",
                        "file": "game/src/alpha.lua",
                        "function": "compute",
                    },
                ],
            )
            candidates = scope.candidate_paths(repository)
            final = scope.final_paths(repository, candidates, csv_path)
            self.assertEqual(final, ["game/src/alpha.lua", "game/src/beta.lua"])

    def test_analyzer_paths_outside_candidates_are_rejected(self) -> None:
        scope = load_scope_module()
        repository = _init_repository({"game/src/alpha.lua": _function_body()})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "functions.csv"
            _write_lizard_csv(
                csv_path,
                [
                    {
                        "NLOC": "10",
                        "CCN": "2",
                        "file": "game/src/elsewhere.lua",
                        "function": "compute",
                    }
                ],
            )
            candidates = scope.candidate_paths(repository)
            with self.assertRaises(ValueError):
                scope.final_paths(repository, candidates, csv_path)

    def test_unsafe_analyzer_paths_are_rejected(self) -> None:
        scope = load_scope_module()
        repository = _init_repository({"game/src/alpha.lua": _function_body()})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            for foreign in ("../game/src/alpha.lua", "/game/src/alpha.lua", "game/src/alpha.txt"):
                csv_path = Path(directory) / "functions.csv"
                _write_lizard_csv(
                    csv_path,
                    [
                        {
                            "NLOC": "10",
                            "CCN": "2",
                            "file": foreign,
                            "function": "compute",
                        }
                    ],
                )
                candidates = scope.candidate_paths(repository)
                with self.subTest(foreign=foreign):
                    with self.assertRaises(ValueError):
                        scope.final_paths(repository, candidates, csv_path)

    def test_empty_candidate_or_final_scope_fails(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {"romdump/src/config/Table.lua": _function_body()}
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with self.assertRaises(ValueError):
            scope.candidate_paths(repository)
        repository_two = _init_repository({"game/src/alpha.lua": _function_body()})
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository_two)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "functions.csv"
            _write_lizard_csv(csv_path, [])
            candidates = scope.candidate_paths(repository_two)
            with self.assertRaises(ValueError):
                scope.final_paths(repository_two, candidates, csv_path)


class ScopeMetadataContractTest(unittest.TestCase):
    """The scope owner publishes the machine-readable population description."""

    def test_metadata_describes_effective_population_rules(self) -> None:
        scope = load_scope_module()
        self.assertEqual(
            scope.scope_metadata(),
            {
                "structural": "executable-production-lua",
                "sourceScope": "production",
                "declarativePrefixes": list(scope.DECLARATIVE_PREFIXES),
                "declarativeMarker": scope.DECLARATIVE_MARKER,
                "markerScanLines": scope.MARKER_SCAN_LINES,
                "requiresLizardFunctionRow": True,
            },
        )

    def test_metadata_calls_return_independent_containers(self) -> None:
        scope = load_scope_module()
        first = scope.scope_metadata()
        first["declarativePrefixes"].append("injected/prefix/")
        first["injected"] = True
        second = scope.scope_metadata()
        self.assertNotIn("injected", second)
        self.assertNotIn("injected/prefix/", second["declarativePrefixes"])
        self.assertEqual(second["declarativePrefixes"], list(scope.DECLARATIVE_PREFIXES))


class ScopeCommandContractTest(unittest.TestCase):
    """Both analysis entry points resolve scope through one shared helper."""

    def test_candidate_command_emits_sorted_manifest(self) -> None:
        if not MODULE_PATH.is_file():
            self.fail(
                "executable code-health scope must derive candidate and final "
                "structural manifests before these contract tests can pass"
            )
        repository = _init_repository(
            {
                "romdump/src/engine.lua": _function_body(),
                "romdump/src/config/Table.lua": _function_body(),
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "candidates",
                "--repository-root",
                str(repository),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = result.stdout.splitlines()
        self.assertEqual(paths, sorted(paths))
        self.assertIn("romdump/src/engine.lua", paths)
        self.assertNotIn("romdump/src/config/Table.lua", paths)

    def test_structural_command_derives_function_bearing_manifest(self) -> None:
        if not MODULE_PATH.is_file():
            self.fail(
                "executable code-health scope must derive candidate and final "
                "structural manifests before these contract tests can pass"
            )
        scope = load_scope_module()
        repository = _init_repository(
            {
                "game/src/alpha.lua": _function_body(),
                "game/src/data.lua": "return {\n1,\n2,\n}\n",
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            candidates_file = work / "candidates.txt"
            csv_path = work / "functions.csv"
            candidates = scope.candidate_paths(repository)
            candidates_file.write_text("\n".join(candidates) + "\n", encoding="utf-8")
            _write_lizard_csv(
                csv_path,
                [
                    {
                        "NLOC": "10",
                        "CCN": "2",
                        "file": "game/src/alpha.lua",
                        "function": "compute",
                    }
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "structural",
                    "--repository-root",
                    str(repository),
                    "--candidates",
                    str(candidates_file),
                    "--lizard-csv",
                    str(csv_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["game/src/alpha.lua"])

    def test_real_analyzer_rows_define_final_structural_scope(self) -> None:
        scope = load_scope_module()
        repository = _init_repository(
            {
                "game/src/logic.lua": _function_body(),
                "game/src/data.lua": "return {\n1,\n2,\n}\n",
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(repository)], check=False)
        )
        candidates = scope.candidate_paths(repository)
        self.assertIn("game/src/logic.lua", candidates)
        self.assertIn("game/src/data.lua", candidates)
        with tempfile.TemporaryDirectory() as directory:
            csv_path = _run_production_lizard_csv(
                Path(directory), repository, candidates
            )
            final = scope.final_paths(repository, candidates, csv_path)
            self.assertEqual(final, ["game/src/logic.lua"])

    def test_snapshot_wrapper_reports_explicit_target_root(self) -> None:
        target = _init_repository(
            {
                "game/src/logic.lua": _function_body(),
                "game/src/data.lua": "return {\n1,\n2,\n}\n",
            }
        )
        self.addCleanup(
            lambda: subprocess.run(["rm", "-rf", str(target)], check=False)
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "snapshot" / "structure.json"
            output.parent.mkdir(parents=True)
            result = subprocess.run(
                [
                    str(SNAPSHOT_PATH),
                    "--repository-root",
                    str(target),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            report = json.loads(output.read_text(encoding="utf-8"))
            paths = [row["path"] for row in report["source"]["files"]]
            self.assertEqual(paths, ["game/src/logic.lua"])


if __name__ == "__main__":
    unittest.main()
