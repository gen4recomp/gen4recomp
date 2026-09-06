#!/usr/bin/env bash
# Reusable structural budget gate: manifest -> Lizard -> minimal report -> policy.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

BASE_REF=""
if [ "$#" -eq 0 ]; then
  :
elif [ "$#" -eq 2 ] && [ "$1" = "--base-ref" ] && [ -n "$2" ]; then
  BASE_REF="$2"
else
  echo "usage: scripts/ci/structure_check.sh [--base-ref REF]" >&2
  exit 1
fi

for tool in python3 lizard; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "structure check: required command not found: $tool" >&2
    exit 1
  fi
done

CHECK_ROOT="$REPO_ROOT/tmp/structure-check"
MANIFEST="$CHECK_ROOT/production-lua-files.txt"
LIZARD_CSV="$CHECK_ROOT/lizard-functions.csv"
REPORT_JSON="$CHECK_ROOT/quality-report.json"

rm -rf -- "$CHECK_ROOT"
mkdir -p -- "$CHECK_ROOT"

python3 scripts/ci/source_scope.py --scope production > "$MANIFEST"

if [ ! -s "$MANIFEST" ]; then
  echo "structure check: production Lua manifest is empty" >&2
  exit 1
fi

lizard -l lua -t 4 -i -1 -f "$MANIFEST" -V --csv > "$LIZARD_CSV"

python3 scripts/ci/codehealth_report.py \
  --lizard-csv "$LIZARD_CSV" \
  --structure-report "$REPORT_JSON" \
  --repository-root "$REPO_ROOT"

if [ -n "$BASE_REF" ]; then
  python3 scripts/ci/check_structure_budget.py \
    --report "$REPORT_JSON" \
    --baseline scripts/ci/structure-baseline.json \
    --base-ref "$BASE_REF"
else
  python3 scripts/ci/check_structure_budget.py \
    --report "$REPORT_JSON" \
    --baseline scripts/ci/structure-baseline.json
fi
