#!/usr/bin/env python3
"""Enforce shaped LuaCATS contracts and diagnostic-directive policy."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys
from typing import Any


_ANNOTATION = re.compile(r"^\s*---@([A-Za-z][\w-]*)(?:\s+(.*))?$")
_DIRECTIVE = re.compile(r"^\s*---@diagnostic\b(.*)$")
_BARE_TABLE = re.compile(r"(?<![A-Za-z0-9_])table(?![A-Za-z0-9_<\[])")
_POLICY_DEBT_CATEGORIES = {"explicit-any"}
_VALID_DIRECTIVE_STATES = {"disable", "disable-next-line", "enable", "enable-next-line"}
_HARD_BANNED_CATEGORIES = {
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
}
_KNOWN_CATEGORIES = _HARD_BANNED_CATEGORIES | {
    "await-in-sync",
    "duplicate-set-field",
    "redundant-parameter",
}
_ALLOWED_CATEGORIES = {
    "production": {"await-in-sync", "duplicate-set-field"},
    "test": {"param-type-mismatch", "duplicate-set-field"},
}
_EXCEPTIONS_RELATIVE_PATH = "scripts/ci/lua-policy-exceptions.json"


def _load_scope_module():
    module_path = Path(__file__).with_name("source_scope.py")
    module_spec = importlib.util.spec_from_file_location("source_scope", module_path)
    if module_spec is None or module_spec.loader is None:
        raise RuntimeError("cannot load source scope")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def _consume_suffixes(text: str, index: int) -> int:
    total = len(text)
    while index < total:
        if text[index] == "?":
            index += 1
        elif text[index] == "[" and index + 1 < total and text[index + 1] == "]":
            index += 2
        else:
            break
    return index


def _consume_balanced(text: str, start: int, opener: str, closer: str) -> int | None:
    if start >= len(text) or text[start] != opener:
        return None
    depth = 0
    index = start
    total = len(text)
    while index < total:
        char = text[index]
        if char in "\"'`":
            quote = char
            index += 1
            while index < total:
                if quote in "\"'" and text[index] == "\\" and index + 1 < total:
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        if char == opener:
            depth += 1
            index += 1
            continue
        if char == closer:
            depth -= 1
            index += 1
            if depth == 0:
                return index
            continue
        index += 1
    return None


def _consume_type(text: str, index: int) -> int | None:
    total = len(text)
    while index < total and text[index].isspace():
        index += 1
    if index >= total:
        return None
    if text[index] in "\"'`":
        delimiter = text[index]
        index += 1
        while index < total:
            if delimiter in "\"'" and text[index] == "\\" and index + 1 < total:
                index += 2
                continue
            if text[index] == delimiter:
                return _consume_suffixes(text, index + 1)
            index += 1
        return None
    if text.startswith("fun", index) and (
        index + 3 >= total or (not text[index + 3].isalnum() and text[index + 3] != "_")
    ):
        index += 3
        while index < total and text[index].isspace():
            index += 1
        if index >= total or text[index] != "(":
            return None
        end = _consume_balanced(text, index, "(", ")")
        if end is None:
            return None
        index = end
        cursor = index
        while cursor < total and text[cursor].isspace():
            cursor += 1
        if cursor < total and text[cursor] == ":":
            nested = _consume_type_list(text, cursor + 1, allow_comma=True)
            if nested is None:
                return None
            return nested
        return _consume_suffixes(text, index)
    if text[index] in "{(":
        opener = text[index]
        closer = "}" if opener == "{" else ")"
        end = _consume_balanced(text, index, opener, closer)
        if end is None:
            return None
        return _consume_suffixes(text, end)
    if text.startswith("...", index):
        return _consume_suffixes(text, index + 3)
    if text[index].isalpha() or text[index] == "_":
        while index < total and (text[index].isalnum() or text[index] in "_."):
            index += 1
        cursor = index
        while cursor < total and text[cursor].isspace():
            cursor += 1
        if cursor < total and text[cursor] == "<":
            end = _consume_balanced(text, cursor, "<", ">")
            if end is None:
                return None
            index = end
        return _consume_suffixes(text, index)
    return None


def _consume_type_list(text: str, index: int, *, allow_comma: bool) -> int | None:
    end = _consume_type(text, index)
    if end is None:
        return None
    total = len(text)
    while True:
        cursor = end
        while cursor < total and text[cursor].isspace():
            cursor += 1
        if cursor < total and text[cursor] in "|&":
            candidate = _consume_type(text, cursor + 1)
            if candidate is None:
                break
            end = candidate
            continue
        if allow_comma and cursor < total and text[cursor] == ",":
            candidate = _consume_type(text, cursor + 1)
            if candidate is None:
                break
            end = candidate
            continue
        break
    return end


def _leading_type_prefix(text: str, *, allow_comma: bool) -> str:
    end = _consume_type_list(text, 0, allow_comma=allow_comma)
    if end is None:
        return ""
    return text[:end]


def _scan_depth(text: str, index: int, depth: dict[str, int]) -> bool:
    for opener, closer in (("<", ">"), ("{", "}"), ("(", ")"), ("[", "]")):
        if text[index] == opener:
            depth[opener] += 1
            return True
        if text[index] == closer:
            depth[opener] -= 1
            return True
    return False


def _find_top_level_char(text: str, target: str) -> int | None:
    depth: dict[str, int] = {"<": 0, "{": 0, "(": 0, "[": 0}
    index = 0
    total = len(text)
    while index < total:
        char = text[index]
        if char in "\"'`":
            quote = char
            index += 1
            while index < total:
                if quote in "\"'" and text[index] == "\\" and index + 1 < total:
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        if _scan_depth(text, index, depth):
            index += 1
            continue
        if char == target and all(value == 0 for value in depth.values()):
            return index
        index += 1
    return None


def _split_top_level(text: str, separator: str) -> list[str]:
    parts: list[str] = []
    depth: dict[str, int] = {"<": 0, "{": 0, "(": 0, "[": 0}
    current: list[str] = []
    index = 0
    total = len(text)
    while index < total:
        char = text[index]
        if char in "\"'`":
            quote = char
            current.append(char)
            index += 1
            while index < total:
                current.append(text[index])
                if quote in "\"'" and text[index] == "\\" and index + 1 < total:
                    current.append(text[index + 1])
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        if _scan_depth(text, index, depth):
            current.append(char)
            index += 1
            continue
        if char == separator and all(value == 0 for value in depth.values()):
            parts.append("".join(current))
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    parts.append("".join(current))
    return parts


def _find_matching_bracket(text: str, start: int, opener: str, closer: str) -> int | None:
    end = _consume_balanced(text, start, opener, closer)
    if end is None:
        return None
    return end - 1


def _count_any_in_region(region: str) -> int:
    count = 0
    index = 0
    total = len(region)
    while index < total:
        char = region[index]
        if char in "\"'`":
            quote = char
            index += 1
            while index < total:
                if quote in "\"'" and region[index] == "\\" and index + 1 < total:
                    index += 2
                    continue
                if region[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        if region.startswith("any", index):
            previous = region[index - 1] if index > 0 else ""
            following = region[index + 3] if index + 3 < total else ""
            if (previous == "" or (not previous.isalnum() and previous != "_")) and (
                following == "" or (not following.isalnum() and following != "_")
            ):
                count += 1
                index += 3
                continue
        index += 1
    return count


def _explicit_any_regions(tag: str, payload: str) -> list[str]:
    text = (payload or "").strip()
    if tag == "param":
        fields = text.split(None, 1)
        if len(fields) < 2:
            return []
        prefix = _leading_type_prefix(fields[1], allow_comma=False)
        return [prefix] if prefix else []
    if tag == "field":
        rest = text
        scoped = re.match(r"^(?:public|private|protected)\s+(.*)$", rest, re.DOTALL)
        if scoped is not None:
            rest = scoped.group(1).strip()
        if not rest:
            return []
        if rest.startswith("["):
            closing = _find_matching_bracket(rest, 0, "[", "]")
            if closing is None:
                return []
            regions: list[str] = []
            key = rest[1:closing].strip()
            if key:
                regions.append(key)
            after = rest[closing + 1 :].strip()
            if after:
                prefix = _leading_type_prefix(after, allow_comma=False)
                if prefix:
                    regions.append(prefix)
            return regions
        fields = rest.split(None, 1)
        if len(fields) < 2:
            return []
        prefix = _leading_type_prefix(fields[1], allow_comma=False)
        return [prefix] if prefix else []
    if tag in {"return", "type", "vararg"}:
        if not text:
            return []
        prefix = _leading_type_prefix(text, allow_comma=True)
        return [prefix] if prefix else []
    if tag == "alias":
        fields = text.split(None, 1)
        if len(fields) < 2:
            return []
        return [fields[1]]
    if tag == "cast":
        fields = text.split(None, 1)
        if len(fields) < 2:
            return []
        return [fields[1]]
    if tag == "class":
        colon = _find_top_level_char(text, ":")
        if colon is None:
            return []
        parents = text[colon + 1 :].strip()
        return [parents] if parents else []
    if tag == "generic":
        if not text:
            return []
        regions = []
        for part in _split_top_level(text, ","):
            candidate = part.strip()
            if not candidate:
                continue
            colon = _find_top_level_char(candidate, ":")
            if colon is None:
                continue
            bound = candidate[colon + 1 :].strip()
            if bound:
                regions.append(bound)
        return regions
    if tag in {"operator", "overload"}:
        return [text] if text else []
    return []


def _inline_as_types(line: str) -> list[str]:
    asserted: list[str] = []
    index = 0
    total = len(line)
    while True:
        start = line.find("--[", index)
        if start == -1:
            break
        cursor = start + 3
        level = 0
        while cursor < total and line[cursor] == "=":
            level += 1
            cursor += 1
        if cursor >= total or line[cursor] != "[":
            index = start + 1
            continue
        content_start = cursor + 1
        closer = "]" + "=" * level + "]"
        end = line.find(closer, content_start)
        if end == -1:
            index = start + 1
            continue
        content = line[content_start:end]
        stripped = content.lstrip()
        if stripped.startswith("@as") and (len(stripped) == 3 or stripped[3].isspace()):
            asserted_type = stripped[3:].strip()
            if asserted_type:
                asserted.append(asserted_type)
        index = end + len(closer)
    return asserted


def _type_text(tag: str, payload: str) -> str:
    fields = payload.split(None, 1)
    if tag in {"param", "field"}:
        return fields[1] if len(fields) == 2 else ""
    if tag == "cast":
        return fields[1] if len(fields) == 2 else ""
    if tag in {"return", "type", "alias", "operator"}:
        return payload
    return ""


def _finding(path: Path, line: int, kind: str, **fields: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"path": path.as_posix(), "line": line, "kind": kind}
    result.update(fields)
    return result


def _directive_finding(path: Path, line: int, payload: str) -> dict[str, Any]:
    match = re.match(r"^\s*([^:\s]+)\s*:(.*)$", payload)
    if match is None:
        return _finding(path, line, "malformed-directive")
    state, category_text = match.groups()
    category_text, separator, reason = category_text.partition("--")
    categories = [category.strip() for category in category_text.split(",") if category.strip()]
    if state not in _VALID_DIRECTIVE_STATES or not categories:
        return _finding(path, line, "malformed-directive")
    return _finding(
        path,
        line,
        "diagnostic-directive",
        state=state,
        categories=categories,
        reason=reason.strip() if separator else "",
    )


def scan_file(path: Path) -> list[dict[str, Any]]:
    """Scan one Lua file and return findings in source order."""
    findings: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ValueError(f"cannot read Lua source {path}: {error}") from error
    for line_number, line in enumerate(lines, start=1):
        directive = _DIRECTIVE.match(line)
        if directive is not None:
            findings.append(_directive_finding(path, line_number, directive.group(1)))
            continue
        annotation = _ANNOTATION.match(line)
        if annotation is None:
            for asserted in _inline_as_types(line):
                for _ in range(_count_any_in_region(asserted)):
                    findings.append(_finding(path, line_number, "explicit-any", annotation="as", type="any"))
            continue
        tag, payload = annotation.groups()
        type_text = _type_text(tag, payload or "")
        if _BARE_TABLE.search(type_text) is not None:
            findings.append(_finding(path, line_number, "bare-table", annotation=tag, type="table"))
        for region in _explicit_any_regions(tag, payload or ""):
            for _ in range(_count_any_in_region(region)):
                findings.append(_finding(path, line_number, "explicit-any", annotation=tag, type="any"))
        for asserted in _inline_as_types(line):
            for _ in range(_count_any_in_region(asserted)):
                findings.append(_finding(path, line_number, "explicit-any", annotation="as", type="any"))
    return findings


def scan_paths(paths: list[Path]) -> list[dict[str, Any]]:
    findings = [finding for path in sorted(paths, key=lambda item: item.as_posix()) for finding in scan_file(path)]
    return sorted(findings, key=lambda finding: (finding["path"], finding["line"], finding["kind"]))


def _repository_paths(repository_root: Path, scope: str) -> list[Path]:
    scope_module = _load_scope_module()
    return [repository_root / path for path in scope_module.paths_for_scope(repository_root, scope)]


def _source_scope(repository_root: Path, path: str) -> str:
    scope_module = _load_scope_module()
    return scope_module.classify(path)


def _relative_findings(findings: list[dict[str, Any]], repository_root: Path) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for finding in findings:
        relative = dict(finding)
        relative["path"] = Path(finding["path"]).resolve().relative_to(repository_root).as_posix()
        normalized.append(relative)
    return normalized


def _load_exceptions(repository_root: Path) -> list[dict[str, Any]]:
    path = repository_root / _EXCEPTIONS_RELATIVE_PATH
    if not path.exists():
        return []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read exception inventory {path}: {error}") from error
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: expected schemaVersion 1")
    entries = document.get("exceptions")
    if not isinstance(entries, list):
        raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: exceptions must be an array")
    hard_banned_entries = [
        (entry.get("path"), entry.get("category"))
        for entry in entries
        if isinstance(entry, dict)
        and entry.get("scope") == "production"
        and entry.get("category") in _HARD_BANNED_CATEGORIES
    ]
    if hard_banned_entries:
        details = ", ".join(f"{path}: {category}" for path, category in hard_banned_entries)
        raise ValueError(
            f"{_EXCEPTIONS_RELATIVE_PATH}: hard-banned diagnostic exceptions are forbidden ({details})"
        )

    validated: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} must be an object")
        required = {"scope", "path", "category", "maxOccurrences", "rationale"}
        if set(entry) != required:
            raise ValueError(
                f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} must contain exactly "
                f"{', '.join(sorted(required))}"
            )
        scope = entry["scope"]
        relative_path = entry["path"]
        category = entry["category"]
        maximum = entry["maxOccurrences"]
        rationale = entry["rationale"]
        if scope not in _ALLOWED_CATEGORIES:
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} has invalid scope {scope!r}")
        if not isinstance(relative_path, str) or "*" in relative_path or "?" in relative_path:
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} has wildcard path {relative_path!r}")
        try:
            normalized_path = Path(relative_path).as_posix()
            scope_module = _load_scope_module()
            if scope_module._normalize(normalized_path) != normalized_path:  # noqa: SLF001
                raise ValueError(f"non-portable Lua path: {relative_path!r}")
        except (AttributeError, ValueError) as error:
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index}: {error}") from error
        if not isinstance(category, str) or (
            category not in _KNOWN_CATEGORIES and category not in _POLICY_DEBT_CATEGORIES
        ):
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} has unknown category {category!r}")
        if category in _POLICY_DEBT_CATEGORIES:
            if scope != "production":
                raise ValueError(
                    f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} cannot allow {category!r} in {scope} scope"
                )
        elif category not in _ALLOWED_CATEGORIES[scope]:
            raise ValueError(
                f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} cannot allow {category!r} in {scope} scope"
            )
        if isinstance(maximum, bool) or not isinstance(maximum, int) or maximum <= 0:
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} maxOccurrences must be positive")
        if not isinstance(rationale, str) or not rationale.strip():
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: entry {index} rationale must be non-empty")
        key = (scope, normalized_path, category)
        if key in seen:
            raise ValueError(f"{_EXCEPTIONS_RELATIVE_PATH}: duplicate entry {key!r}")
        seen.add(key)
        validated.append(
            {
                "scope": scope,
                "path": normalized_path,
                "category": category,
                "maxOccurrences": maximum,
                "rationale": rationale.strip(),
            }
        )
    return validated


def _luarc_violations(repository_root: Path) -> list[str]:
    path = repository_root / ".luarc.json"
    if not path.exists():
        return []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    if not isinstance(document, dict):
        raise ValueError(f"{path}: expected an object")
    diagnostics = document.get("diagnostics", {})
    if not isinstance(diagnostics, dict):
        raise ValueError(f"{path}: diagnostics must be an object")
    violations: list[str] = []
    disabled = diagnostics.get("disable", [])
    disabled_categories = set(disabled) if isinstance(disabled, list) else {disabled}
    if "all" in disabled_categories:
        violations.extend(sorted(_HARD_BANNED_CATEGORIES))
    else:
        violations.extend(sorted(_HARD_BANNED_CATEGORIES & disabled_categories))
    severity = diagnostics.get("severity", {})
    if isinstance(severity, dict):
        violations.extend(
            sorted(
                category
                for category, level in severity.items()
                if category in _HARD_BANNED_CATEGORIES
                and isinstance(level, str)
                and level.lower() == "ignore"
            )
        )
    return sorted(set(violations))


def _policy_violations(
    findings: list[dict[str, Any]],
    repository_root: Path,
    scope: str,
) -> list[str]:
    exceptions = [
        entry
        for entry in _load_exceptions(repository_root)
        if scope in {"all", "first-party"} or entry["scope"] == scope
    ]
    exception_counts: dict[tuple[str, str, str], int] = {}
    violations: list[str] = []
    for category in _luarc_violations(repository_root):
        violations.append(f".luarc.json: diagnostic {category} is disabled or ignored")

    for finding in findings:
        path = finding["path"]
        line = finding["line"]
        kind = finding["kind"]
        if kind == "bare-table":
            if _source_scope(repository_root, path) == "production":
                violations.append(f"{path}:{line}: bare-table; use a shaped or named contract")
            continue
        if kind == "explicit-any":
            if _source_scope(repository_root, path) == "production":
                key = ("production", path, "explicit-any")
                matching = [
                    entry for entry in exceptions if (entry["scope"], entry["path"], entry["category"]) == key
                ]
                if not matching:
                    violations.append(f"{path}:{line}: explicit-any; use a named or shaped contract")
                    continue
                exception_counts[key] = exception_counts.get(key, 0) + 1
                if exception_counts[key] > matching[0]["maxOccurrences"]:
                    violations.append(f"{path}:{line}: exception category explicit-any exceeds occurrence limit")
            continue
        if kind == "malformed-directive":
            violations.append(f"{path}:{line}: malformed diagnostic directive")
            continue
        if kind != "diagnostic-directive":
            continue
        state = finding["state"]
        categories = finding["categories"]
        reason = finding["reason"]
        if state != "disable-next-line":
            violations.append(f"{path}:{line}: {state} diagnostic region is forbidden")
        if not reason:
            violations.append(f"{path}:{line}: diagnostic exception requires a source reason")
        finding_scope = _source_scope(repository_root, path)
        for category in categories:
            if category not in _KNOWN_CATEGORIES:
                violations.append(f"{path}:{line}: unknown diagnostic category {category}")
                continue
            if finding_scope == "production" and category in _HARD_BANNED_CATEGORIES:
                violations.append(f"{path}:{line}: hard-banned diagnostic category {category}")
                continue
            key = (finding_scope, path, category)
            matching = [entry for entry in exceptions if (entry["scope"], entry["path"], entry["category"]) == key]
            if not matching:
                violations.append(f"{path}:{line}: diagnostic category {category} lacks an exact exception")
                continue
            exception_counts[key] = exception_counts.get(key, 0) + 1
            if exception_counts[key] > matching[0]["maxOccurrences"]:
                violations.append(f"{path}:{line}: exception category {category} exceeds occurrence limit")

    for entry in exceptions:
        key = (entry["scope"], entry["path"], entry["category"])
        if exception_counts.get(key, 0) == 0:
            violations.append(
                f"{entry['path']}: stale exception for {entry['category']} has no matching occurrence"
            )
    if scope == "production":
        violations = [
            violation
            for violation in violations
            if not violation.startswith("tests/")
        ]
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--scope", default="first-party")
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--check", action="store_true", help="fail when findings are present")
    args = parser.parse_args(argv)
    try:
        repository_root = args.repository_root.resolve()
        findings = _relative_findings(scan_paths(_repository_paths(repository_root, args.scope)), repository_root)
        if args.report is not None:
            report = {"schemaVersion": 1, "scope": args.scope, "findings": findings}
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        violations = _policy_violations(findings, repository_root, args.scope) if args.check else []
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Lua policy: {error}", file=sys.stderr)
        return 1
    if args.check and violations:
        for violation in violations:
            print(f"Lua policy: {violation}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
