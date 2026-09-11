#!/usr/bin/env bash
# Fast developer-loop static checks: formatting (stylua), repository-owned
# static/policy/invariant checks, and a reduced-workspace LuaLS check (tests
# excluded) that runs in the background while the other checks execute, so
# lint.sh's wall time is roughly the slower of the two rather than their sum.
# The reduced check is generated from the committed .luarc.json plus
# additional ignoreDir entries; it is deliberately incomplete (tests are
# unchecked, and only Hint-or-higher findings on the reduced workspace are
# caught). scripts/typecheck.sh remains the canonical whole-repository LuaLS
# gate and is what CI binds on.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$#:${1:-}" in
  0:) STYLUA_ARGS=() ;;
  1:--check) STYLUA_ARGS=(--check) ;;
  *) echo "usage: scripts/lint.sh [--check]" >&2; exit 2 ;;
esac

for tool in stylua lua-language-server; do
  command -v "$tool" >/dev/null || {
    echo "lint: $tool not found in PATH (see README 'Requirements')" >&2
    exit 1
  }
done

LUALS_LOG_DIR="$(mktemp -d)"
LINT_LUARC="$(mktemp)"
LUALS_OUTPUT="$(mktemp)"
luals_pid=""
cleanup() {
  local status=$?
  if [ -n "$luals_pid" ]; then
    kill "$luals_pid" 2>/dev/null || true
    wait "$luals_pid" 2>/dev/null || true
  fi
  rm -rf -- "$LUALS_LOG_DIR" "$LINT_LUARC" "$LUALS_OUTPUT"
  exit "$status"
}
trap cleanup EXIT

python3 - "$LINT_LUARC" <<'PYEOF'
import json
import sys

with open(".luarc.json", encoding="utf-8") as f:
    config = json.load(f)
config.setdefault("workspace", {}).setdefault("ignoreDir", []).extend(["tests", "**/tests"])
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(config, f)
PYEOF

echo "==> lua-language-server --check (tests excluded, running in background)"
lua-language-server --check . --configpath="$LINT_LUARC" --num_threads="2" --checklevel=Hint --logpath="$LUALS_LOG_DIR" \
  >"$LUALS_OUTPUT" 2>&1 &
luals_pid=$!

if [ "${#STYLUA_ARGS[@]}" -eq 0 ]; then
  echo "==> stylua"
else
  echo "==> stylua --check"
fi
stylua "${STYLUA_ARGS[@]}" .

scripts/lib/check-repository.sh
scripts/lib/check-invariants.sh

# Reject references to the planning spec ("tmp/spec", "spec section N",
# "Workstream N", "milestone N", "slice N", "WS N"), planning language
# ("under development", "provisional", "may change in a future API"), and
# temporary phase/deliverable identifiers ("D12", "DEV-06", "pre-D4") in
# source, tests, data, and permanent docs. The patterns are narrow on
# purpose: bare "section"/"slice" and project concepts like the playable
# "New Bark slice" stay legal. lint.sh is excluded because it contains the
# patterns itself.
permanent_prose_roots=(README.md docs data libs game romdump tests scripts gen4 .agents/docs)
if grep -RInE --include='*.lua' --include='*.md' --include='*.sh' --include='*.toml' \
  -e 'tmp/spec' -e 'spec section' -e 'Workstream' -e 'milestone' -e 'slice [0-9]' \
  -e 'WS[0-9]' -e 'under development' -e 'provisional' -e 'may change in a future API' \
  -e '\bD[0-9]+\b' -e '\bDEV-[0-9]+\b' -e 'pre-D[0-9]+' \
  --exclude='lint.sh' \
  "${permanent_prose_roots[@]}"; then
  echo "lint: temporary-spec references found; replace them with durable reasoning" >&2
  exit 1
fi

echo "==> waiting for reduced-workspace lua-language-server --check"
luals_status=0
wait "$luals_pid" || luals_status=$?
luals_pid=""
if [ "$luals_status" -ne 0 ]; then
  cat "$LUALS_OUTPUT" >&2
  echo "lint: reduced-workspace LuaLS check failed (tests excluded; run scripts/typecheck.sh for the complete check)" >&2
  exit 1
fi
