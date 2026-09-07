#!/usr/bin/env python3
"""Black-box contract tests for the shell source-policy gate.

Invokes the repository invariant script in explicit-path mode against
minimal temporary fixtures. Production scope is any explicit ``.lua``
path; test scope is an explicit path containing a ``/tests/`` segment.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "check-invariants.sh"


def run_gate(path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), str(path)],
        check=False,
        capture_output=True,
        text=True,
    )


def write_production(directory: Path, name: str, body: str) -> Path:
    target = directory / "prod" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    return target


def write_test(directory: Path, name: str, body: str) -> Path:
    target = directory / "tests" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    return target


class ShellPolicyTest(unittest.TestCase):
    """Production annotation and diagnostic-directive policy."""

    def test_production_param_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "param_any.lua",
                "--- Module stub.\n"
                "---@param value any\n"
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("any", result.stderr.lower())

    def test_production_generic_function_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "generic_any.lua",
                "--- Module stub.\n"
                "---@type fun<T>(value: any): T\n"
                "local handler = {}\n"
                "return handler\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_inline_assertion_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "assertion_any.lua",
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "local outcome = compute(1) --[[@as any]]\n"
                "return outcome\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_annotation_prose_any_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "prose_any.lua",
                "--- Module stub.\n"
                "---@param mode string -- select any mode\n"
                "local function compute(mode)\n"
                "  return mode\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_runtime_identifier_any_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "runtime_any.lua",
                "local function compute()\n"
                "  return 1\n"
                "end\n"
                "local any = compute()\n"
                "return any\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_shaped_table_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "shaped_table.lua",
                "--- Module stub.\n"
                "---@type table<string, unknown>\n"
                "local mapping = {}\n"
                "return mapping\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_bare_table_param_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "bare_table.lua",
                "--- Module stub.\n"
                "---@param value table\n"
                "local function compute(value)\n"
                "  return value\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("table", result.stderr.lower())

    def test_production_bare_table_return_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "bare_return.lua",
                "--- Module stub.\n"
                "---@return table\n"
                "local function compute()\n"
                "  return {}\n"
                "end\n"
                "return compute\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_production_next_line_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_production(
                Path(directory),
                "directive.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_narrow_test_directive_stays_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "narrow_test.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_test_file_wide_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "wide_test.lua",
                "local value = {}\n"
                "---@diagnostic disable: param-type-mismatch\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)

    def test_test_other_category_directive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = write_test(
                Path(directory),
                "other_category_test.lua",
                "local value = {}\n"
                "---@diagnostic disable-next-line: unused-local\n"
                "value.compute(nil)\n"
                "return value\n",
            )
            result = run_gate(path)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
