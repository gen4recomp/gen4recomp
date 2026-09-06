#!/usr/bin/env python3
"""Contract tests for targeted LuaCATS annotation and directive scanning."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from typing import Iterator


MODULE_PATH = Path(__file__).with_name("lua_policy.py")


def load_policy_module():
    if not MODULE_PATH.is_file():
        raise AssertionError(
            "Lua policy scanning must report annotation debt before these contract tests can pass"
        )
    module_spec = importlib.util.spec_from_file_location("lua_policy", MODULE_PATH)
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("Lua policy module cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


POLICY = load_policy_module()
REPOSITORY_ROOT = MODULE_PATH.parents[2]


@contextmanager
def fixture_repository(
    files: dict[str, str],
    *,
    exceptions: list[dict[str, object]] | None = None,
    luarc: dict[str, object] | None = None,
) -> Iterator[Path]:
    """Create a tracked, source-scoped repository for policy CLI tests."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for relative_path, contents in files.items():
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        if exceptions is not None:
            exceptions_path = root / "scripts/ci/lua-policy-exceptions.json"
            exceptions_path.parent.mkdir(parents=True, exist_ok=True)
            exceptions_path.write_text(
                json.dumps({"schemaVersion": 1, "exceptions": exceptions}) + "\n",
                encoding="utf-8",
            )
        if luarc is not None:
            (root / ".luarc.json").write_text(json.dumps(luarc) + "\n", encoding="utf-8")
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "add", "--all"], cwd=root, check=True)
        yield root


def run_policy_check(
    repository_root: Path,
    scope: str = "first-party",
    *,
    with_report: bool = True,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        report = Path(directory) / "lua-policy.json"
        command = [
            "python3",
            str(MODULE_PATH),
            "--scope",
            scope,
            "--repository-root",
            str(repository_root),
        ]
        if with_report:
            command.extend(["--report", str(report)])
        command.append("--check")
        return subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )


class LuaPolicyTest(unittest.TestCase):
    """Protect semantic type-expression and diagnostic-directive findings."""

    def test_scan_reports_bare_types_and_directives_but_not_shaped_types(self) -> None:
        source = """\
---@param bare table
---@return table?
---@param union table|nil
---@param mapping table<string, string>
---@param array string[]
---@param record {name: string}
---@param optional NamedType?
---@type { [string]: NamedType }?
---@param callback fun(value: string): NamedType
-- A prose comment and a runtime type check are not annotations.
local function read(value)
  if type(value) == "table" then
    return value
  end
  return nil
end
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        bare = [finding for finding in findings if finding["kind"] == "bare-table"]
        directives = [finding for finding in findings if finding["kind"] == "diagnostic-directive"]
        self.assertEqual(
            [(finding["line"], finding["kind"]) for finding in bare],
            [(1, "bare-table"), (2, "bare-table"), (3, "bare-table")],
        )
        self.assertEqual(directives, [])
        self.assertNotIn("mapping", " ".join(str(finding) for finding in findings))
        self.assertNotIn("array", " ".join(str(finding) for finding in findings))
        self.assertNotIn("record", " ".join(str(finding) for finding in findings))

    def test_scan_preserves_multiple_directive_categories_and_reason(self) -> None:
        source = "---@diagnostic disable-next-line: param-type-mismatch, duplicate-set-field -- deliberate test fixture\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["kind"], "diagnostic-directive")
        self.assertEqual(findings[0]["categories"], ["param-type-mismatch", "duplicate-set-field"])
        self.assertEqual(findings[0]["reason"], "deliberate test fixture")

    def test_findings_are_stable_and_include_normalized_source_fields(self) -> None:
        source = "---@return table\n---@diagnostic disable: undefined-global -- reason\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            first = POLICY.scan_file(path)
            second = POLICY.scan_file(path)

        self.assertEqual(first, second)
        self.assertEqual([finding["line"] for finding in first], [1, 2])
        for finding in first:
            self.assertEqual(finding["path"], str(path).replace("\\", "/"))
            self.assertIn("kind", finding)
            self.assertIn("line", finding)

    def test_malformed_directive_is_reported_instead_of_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text("---@diagnostic disable-next-line\n", encoding="utf-8")
            findings = POLICY.scan_file(path)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["kind"], "malformed-directive")

    def test_hard_banned_production_directive_cannot_be_allowed_by_exception(self) -> None:
        categories = (
            "undefined-field",
            "invisible",
            "missing-return-value",
            "return-type-mismatch",
            "assign-type-mismatch",
            "param-type-mismatch",
            "need-check-nil",
            "inject-field",
            "cast-type-mismatch",
            "cast-local-type",
            "missing-fields",
            "missing-parameter",
            "missing-return",
        )
        source = (
            "---@diagnostic disable-next-line: "
            + ", ".join(categories)
            + " -- compatibility rationale\nreturn {}\n"
        )
        exceptions = [
            {
                "scope": "production",
                "path": "app/src/fixture.lua",
                "category": category,
                "maxOccurrences": 1,
                "rationale": "This entry must be rejected because the category is correctness debt.",
            }
            for category in categories
        ]
        with fixture_repository({"app/src/fixture.lua": source}, exceptions=exceptions) as root:
            result = run_policy_check(root, scope="production")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app/src/fixture.lua", result.stderr)
        for category in categories:
            self.assertIn(category, result.stderr)
        self.assertIn("hard", result.stderr.lower())

    def test_check_mode_reports_findings_without_a_report_argument(self) -> None:
        source = "---@return table\nreturn {}\n"
        with fixture_repository({"app/src/fixture.lua": source}) as root:
            result = run_policy_check(root, scope="production", with_report=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app/src/fixture.lua", result.stderr)
        self.assertIn("bare-table", result.stderr)

    def test_reasoned_test_exceptions_are_exact_and_accepted(self) -> None:
        source = """\
---@diagnostic disable-next-line: param-type-mismatch -- deliberate invalid-input coverage
local function accepts(value) return value end
---@diagnostic disable-next-line: duplicate-set-field -- deliberate replacement coverage
local function replace(value) return value end
"""
        exceptions = [
            {
                "scope": "test",
                "path": "tests/fixture.lua",
                "category": "param-type-mismatch",
                "maxOccurrences": 1,
                "rationale": "The fixture intentionally calls a function with an invalid value.",
            },
            {
                "scope": "test",
                "path": "tests/fixture.lua",
                "category": "duplicate-set-field",
                "maxOccurrences": 1,
                "rationale": "The fixture intentionally replaces an externally owned callback.",
            },
        ]
        with fixture_repository({"tests/fixture.lua": source}, exceptions=exceptions) as root:
            result = run_policy_check(root)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_line_local_exception_requires_a_nonempty_source_reason(self) -> None:
        source = "---@diagnostic disable-next-line: param-type-mismatch\nreturn {}\n"
        exceptions = [
            {
                "scope": "test",
                "path": "tests/fixture.lua",
                "category": "param-type-mismatch",
                "maxOccurrences": 1,
                "rationale": "The inventory entry alone does not explain the source exception.",
            }
        ]
        with fixture_repository({"tests/fixture.lua": source}, exceptions=exceptions) as root:
            result = run_policy_check(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tests/fixture.lua", result.stderr)
        self.assertIn("reason", result.stderr.lower())

    def test_file_wide_and_multiline_diagnostic_regions_are_rejected(self) -> None:
        source = """\
---@diagnostic disable: undefined-field -- broad disable
---@diagnostic disable-next-line -- categoryless disable
---@diagnostic enable: undefined-field -- broad enable
return {}
"""
        with fixture_repository({"tests/fixture.lua": source}) as root:
            result = run_policy_check(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tests/fixture.lua", result.stderr)
        self.assertIn("disable", result.stderr.lower())
        self.assertIn("enable", result.stderr.lower())

    def test_exception_inventory_rejects_wildcard_and_stale_entries(self) -> None:
        cases = (
            (
                "tests/*.lua",
                "tests/fixture.lua",
                "wildcard",
            ),
            (
                "tests/missing.lua",
                "tests/fixture.lua",
                "stale",
            ),
        )
        for exception_path, source_path, expected_word in cases:
            with self.subTest(exception_path=exception_path):
                exceptions = [
                    {
                        "scope": "test",
                        "path": exception_path,
                        "category": "param-type-mismatch",
                        "maxOccurrences": 1,
                        "rationale": "Inventory validation fixture.",
                    }
                ]
                with fixture_repository({source_path: "return {}\n"}, exceptions=exceptions) as root:
                    result = run_policy_check(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(exception_path, result.stderr)
                self.assertIn(expected_word, result.stderr.lower())

    def test_exception_inventory_rejects_unknown_diagnostic_categories(self) -> None:
        exceptions = [
            {
                "scope": "test",
                "path": "tests/fixture.lua",
                "category": "invented-diagnostic",
                "maxOccurrences": 1,
                "rationale": "Unknown categories must fail closed.",
            }
        ]
        with fixture_repository({"tests/fixture.lua": "return {}\n"}, exceptions=exceptions) as root:
            result = run_policy_check(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invented-diagnostic", result.stderr)

    def test_exception_occurrence_limit_is_enforced(self) -> None:
        source = """\
---@diagnostic disable-next-line: param-type-mismatch -- first deliberate invalid-input case
local first = true
---@diagnostic disable-next-line: param-type-mismatch -- second deliberate invalid-input case
local second = true
"""
        exceptions = [
            {
                "scope": "test",
                "path": "tests/fixture.lua",
                "category": "param-type-mismatch",
                "maxOccurrences": 1,
                "rationale": "Only one deliberate invalid-input exception is permitted.",
            }
        ]
        with fixture_repository({"tests/fixture.lua": source}, exceptions=exceptions) as root:
            result = run_policy_check(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tests/fixture.lua", result.stderr)
        self.assertIn("occurrence", result.stderr.lower())

    def test_luarc_cannot_disable_or_ignore_hard_banned_diagnostics(self) -> None:
        luarc = {
            "diagnostics": {
                "disable": ["undefined-field"],
                "severity": {"invisible": "Ignore"},
                "neededFileStatus": {"await-in-sync": "Any"},
            }
        }
        with fixture_repository({"app/src/fixture.lua": "return {}\n"}, luarc=luarc) as root:
            result = run_policy_check(root, scope="production")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("undefined-field", result.stderr)
        self.assertIn("invisible", result.stderr)

    def test_scan_detects_standalone_any_across_type_positions(self) -> None:
        source = """\
---@param direct any
---@param optional any?
---@return string|any
---@field values table<string, any>
---@type fun(value: any): unknown
---@param union string | any | nil
local value = 1
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        explicit = [finding for finding in findings if finding["kind"] == "explicit-any"]
        self.assertEqual([finding["line"] for finding in explicit], [1, 2, 3, 4, 5, 6])

    def test_scan_ignores_unknown_and_identifiers_containing_any(self) -> None:
        source = """\
---@param value unknown
---@param values ManyValues
---@param companion string
-- Any prose comment mentioning any value is not an annotation type.
local anything = 1
if type(anything) == "table" then
  return anything
end
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        explicit = [finding for finding in findings if finding["kind"] == "explicit-any"]
        self.assertEqual(explicit, [])

    def test_scan_detects_any_at_renderer_and_runtime_view_seams(self) -> None:
        source = """\
---@class FixturePresentationResources
---@field renderer any
---@field fieldTerrainEffectRenderer any
---@param runtime table<string, unknown>
local fixtures = {}
return fixtures
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text(source, encoding="utf-8")
            findings = POLICY.scan_file(path)

        explicit = [finding for finding in findings if finding["kind"] == "explicit-any"]
        self.assertEqual([finding["line"] for finding in explicit], [2, 3])

    def test_production_any_without_an_exact_exception_fails_the_check(self) -> None:
        source = "---@param value any\nlocal function accepts(value) return value end\nreturn {}\n"
        with fixture_repository({"app/src/fixture.lua": source}) as root:
            result = run_policy_check(root, scope="production")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app/src/fixture.lua", result.stderr)
        self.assertIn("explicit-any", result.stderr)

    def test_exact_production_any_exception_passes_at_or_below_its_limit(self) -> None:
        source = "---@param value any\nlocal function accepts(value) return value end\nreturn {}\n"
        exceptions = [
            {
                "scope": "production",
                "path": "app/src/fixture.lua",
                "category": "explicit-any",
                "maxOccurrences": 1,
                "rationale": "Legacy production type debt carried from before this change.",
            }
        ]
        with fixture_repository({"app/src/fixture.lua": source}, exceptions=exceptions) as root:
            result = run_policy_check(root, scope="production")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_any_exception_limit_and_staleness_are_enforced(self) -> None:
        overused = (
            "---@param first any\nlocal first = true\n"
            "---@param second any\nlocal second = true\n"
        )
        limited = [
            {
                "scope": "production",
                "path": "app/src/fixture.lua",
                "category": "explicit-any",
                "maxOccurrences": 1,
                "rationale": "Only one legacy production occurrence is permitted.",
            }
        ]
        with fixture_repository({"app/src/fixture.lua": overused}, exceptions=limited) as root:
            exceeded = run_policy_check(root, scope="production")

        self.assertNotEqual(exceeded.returncode, 0)
        self.assertIn("app/src/fixture.lua", exceeded.stderr)
        self.assertIn("occurrence", exceeded.stderr.lower())

        stale = [
            {
                "scope": "production",
                "path": "app/src/fixture.lua",
                "category": "explicit-any",
                "maxOccurrences": 1,
                "rationale": "The annotation was improved so this entry must ratchet away.",
            }
        ]
        with fixture_repository({"app/src/fixture.lua": "return {}\n"}, exceptions=stale) as root:
            unused = run_policy_check(root, scope="production")

        self.assertNotEqual(unused.returncode, 0)
        self.assertIn("app/src/fixture.lua", unused.stderr)
        self.assertIn("stale", unused.stderr.lower())

    def test_current_first_party_tree_is_clean_under_the_strict_policy(self) -> None:
        result = run_policy_check(REPOSITORY_ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lint_wires_the_blocking_policy_check_before_luals(self) -> None:
        lint_source = (REPOSITORY_ROOT / "scripts/lint.sh").read_text(encoding="utf-8")
        self.assertIn("lua_policy.py", lint_source)
        self.assertIn("lua-language-server --check", lint_source)
        policy_position = lint_source.index("lua_policy.py")
        luals_position = lint_source.index("lua-language-server --check")
        self.assertLess(policy_position, luals_position)
        self.assertIn("--check", lint_source[policy_position:luals_position])


if __name__ == "__main__":
    unittest.main()
