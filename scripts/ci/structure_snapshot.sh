#!/usr/bin/env bash
# Build one structural hotspot snapshot for an explicit repository worktree.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOL_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)

if [ "$#" -eq 4 ] && [ "$1" = "--repository-root" ] && [ -n "$2" ] && [ "$3" = "--output" ] && [ -n "$4" ]; then
  TARGET_ROOT="$2"
  OUTPUT_FILE="$4"
else
  echo "usage: scripts/ci/structure_snapshot.sh --repository-root PATH --output FILE" >&2
  exit 1
fi

for tool in python3 lizard; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "structure snapshot: required command not found: $tool" >&2
    exit 1
  fi
done

if ! git -C "$TARGET_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "structure snapshot: repository root is not a git worktree: $TARGET_ROOT" >&2
  exit 1
fi

OUTPUT_PARENT=$(dirname -- "$OUTPUT_FILE")
if [ ! -d "$OUTPUT_PARENT" ]; then
  echo "structure snapshot: output parent is not a directory: $OUTPUT_PARENT" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
MANIFEST="$WORK_DIR/production-lua-files.txt"
LIZARD_CSV="$WORK_DIR/lizard-functions.csv"

python3 "$TOOL_ROOT/scripts/ci/source_scope.py" --scope production --repository-root "$TARGET_ROOT" > "$MANIFEST"

if [ ! -s "$MANIFEST" ]; then
  echo "structure snapshot: production Lua manifest is empty" >&2
  exit 1
fi

cd -- "$TARGET_ROOT"
lizard -l lua -t 4 -i -1 -f "$MANIFEST" -V --csv > "$LIZARD_CSV"

python3 "$TOOL_ROOT/scripts/ci/codehealth_report.py" \
  --lizard-csv "$LIZARD_CSV" \
  --structure-report "$OUTPUT_FILE" \
  --repository-root "$TARGET_ROOT"
