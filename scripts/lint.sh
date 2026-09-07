#!/usr/bin/env bash
# Static checks for the whole repo: formatting (stylua) and diagnostics
# (lua-language-server). Both analyze the full workspace — luals resolves
# `require` paths against the repo root, so a per-file mode would be unsound.
# Both exit non-zero on findings; `set -e` turns that into a failed check.
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

if [ "${#STYLUA_ARGS[@]}" -eq 0 ]; then
  echo "==> stylua"
else
  echo "==> stylua --check"
fi
stylua "${STYLUA_ARGS[@]}" .

scripts/lib/check-repository.sh
scripts/lib/check-invariants.sh

echo "==> temporary-spec reference guard"
# Reject references to the planning spec ("tmp/spec", "spec section N",
# "Workstream N", "milestone N", "slice N", "WS N"), planning language
# ("under development", "provisional", "may change in a future API"), and
# temporary phase/deliverable identifiers ("D12", "DEV-06", "pre-D4") in
# source, tests, data, and permanent docs. The patterns are narrow on
# purpose: bare "section"/"slice" and project concepts like the playable
# "New Bark slice" stay legal. lint.sh is excluded because it contains the
# patterns itself.
permanent_prose_roots=(README.md docs data libs game romdump tests scripts gen4)
if [ -d .agents/docs ]; then
  permanent_prose_roots+=(.agents/docs)
fi
if grep -RInE --include='*.lua' --include='*.md' --include='*.sh' --include='*.toml' \
  -e 'tmp/spec' -e 'spec section' -e 'Workstream' -e 'milestone' -e 'slice [0-9]' \
  -e 'WS[0-9]' -e 'under development' -e 'provisional' -e 'may change in a future API' \
  -e '\bD[0-9]+\b' -e '\bDEV-[0-9]+\b' -e 'pre-D[0-9]+' \
  --exclude='lint.sh' \
  "${permanent_prose_roots[@]}"; then
  echo "lint: temporary-spec references found; replace them with durable reasoning" >&2
  exit 1
fi

echo "==> lua-language-server --check"
LUALS_LOG_DIR="$(mktemp -d)"
trap 'rm -rf -- "$LUALS_LOG_DIR"' EXIT
lua-language-server --check . --num_threads="4" --checklevel=Hint --logpath="$LUALS_LOG_DIR"
