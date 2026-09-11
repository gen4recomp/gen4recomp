#!/usr/bin/env bash
# Canonical whole-workspace Lua semantic check (lua-language-server). Analyzes
# the full repo — luals resolves `require` paths against the repo root, so a
# per-file mode would be unsound. Exits non-zero on Hint-or-higher findings.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/typecheck.sh" >&2
  exit 2
fi

command -v lua-language-server >/dev/null || {
  echo "typecheck: lua-language-server not found in PATH (see README 'Requirements')" >&2
  exit 1
}

echo "==> lua-language-server --check"
LUALS_LOG_DIR="$(mktemp -d)"
trap 'rm -rf -- "$LUALS_LOG_DIR"' EXIT
lua-language-server --check . --num_threads="2" --checklevel=Hint --logpath="$LUALS_LOG_DIR"
