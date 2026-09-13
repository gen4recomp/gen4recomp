#!/usr/bin/env python3
"""Contract tests for the repository's tracked-Lua source taxonomy."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


MODULE_PATH = Path(__file__).with_name("source_scope.py")


def load_scope_module():
    if not MODULE_PATH.is_file():
        raise AssertionError(
            "source scope must classify tracked Lua paths before these contract tests can pass"
        )
    module_spec = importlib.util.spec_from_file_location("source_scope", MODULE_PATH)
    if module_spec is None or module_spec.loader is None:
        raise AssertionError("source scope module cannot be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


SCOPE = load_scope_module()


class SourceScopeTest(unittest.TestCase):
    """Protect one deterministic taxonomy for code-health and policy tooling."""

    def test_product_paths_include_concrete_hgss_source(self) -> None:
        for path in (
            "app/src/main.lua",
            "game/src/Game.lua",
            "game/hgss/src/field/FieldRuntime.lua",
            "gen4/src/compat.lua",
            "libs/hgss/src/field/FieldSession.lua",
            "romdump/src/digest/MapCompiler.lua",
        ):
            with self.subTest(path=path):
                self.assertEqual(SCOPE.classify(path), "production")

    def test_non_product_paths_have_explicit_categories(self) -> None:
        expected = {
            "tests/unit.lua": "test",
            "libs/example/tests/unit.lua": "test",
            "scripts/ci/tool.lua": "tooling",
            "vendor/love2d-types/library/love.lua": "vendor",
            "vendor/library.lua": "vendor",
            "site/generated.lua": "generated",
            "data/generated/catalog.lua": "generated",
            "data/scripts/overrides/script.lua": "reference",
            ".agents/tmp/example.lua": "ignored",
        }
        for path, category in expected.items():
            with self.subTest(path=path):
                self.assertEqual(SCOPE.classify(path), category)

    def test_normalization_rejects_nonportable_paths(self) -> None:
        for path in ("/game/a.lua", "../game/a.lua", "game/../a.lua", "C:\\game\\a.lua", ""):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    SCOPE.classify(path)

    def test_cli_lists_only_requested_scope_in_deterministic_order(self) -> None:
        result = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--scope", "production"],
            cwd=MODULE_PATH.parents[2],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = result.stdout.splitlines()
        self.assertEqual(paths, sorted(paths))
        self.assertIn("game/hgss/src/field/FieldRuntime.lua", paths)
        self.assertTrue(all(SCOPE.classify(path) == "production" for path in paths))

    def test_cli_rejects_empty_and_unknown_scope(self) -> None:
        for scope in ("", "not-a-scope"):
            with self.subTest(scope=scope):
                result = subprocess.run(
                    [sys.executable, str(MODULE_PATH), "--scope", scope],
                    cwd=MODULE_PATH.parents[2],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr or result.stdout)


if __name__ == "__main__":
    unittest.main()
