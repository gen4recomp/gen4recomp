#!/usr/bin/env bash
# Build disposable static-analysis reports for the GitHub Pages artifact.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOL_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)

TARGET_ROOT="$TOOL_ROOT"
SITE_ROOT="$TOOL_ROOT/tmp/codehealth-site"
PREVIOUS_HISTORY=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository-root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "codehealth: --repository-root requires a path" >&2
        exit 1
      fi
      TARGET_ROOT="$2"
      shift 2
      ;;
    --site-root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "codehealth: --site-root requires a path" >&2
        exit 1
      fi
      SITE_ROOT="$2"
      shift 2
      ;;
    --previous-history)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "codehealth: --previous-history requires a path" >&2
        exit 1
      fi
      PREVIOUS_HISTORY="$2"
      shift 2
      ;;
    *)
      echo "usage: scripts/ci/codehealth.sh [--repository-root PATH] [--site-root PATH] [--previous-history PATH]" >&2
      exit 1
      ;;
  esac
done

TARGET_ROOT=$(cd -- "$TARGET_ROOT" && pwd)
mkdir -p -- "$(dirname -- "$SITE_ROOT")"
SITE_ROOT=$(cd -- "$(dirname -- "$SITE_ROOT")" && pwd)/$(basename -- "$SITE_ROOT")

WORK_ROOT="$TOOL_ROOT/tmp/codehealth-work"
STRUCT_ROOT="$WORK_ROOT/production-lua"
REPORT_ROOT="$SITE_ROOT/codehealth/reports"
CANDIDATE_MANIFEST="$WORK_ROOT/candidate-lua-files.txt"
FINAL_MANIFEST="$WORK_ROOT/structural-lua-files.txt"

cleanup_site_on_error() {
  status=$?
  rm -rf -- "$SITE_ROOT"
  exit "$status"
}
trap cleanup_site_on_error EXIT

for tool in python3 lizard jscpd graphify; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "codehealth: required command not found: $tool" >&2
    exit 1
  fi
done

if [ ! -s "$TOOL_ROOT/site/styles.css" ]; then
  echo "codehealth: required site source is missing or empty: $TOOL_ROOT/site/styles.css" >&2
  exit 1
fi

for tool_file in scripts/ci/codehealth_scope.py scripts/ci/codehealth_history.py scripts/ci/codehealth_report.py scripts/ci/codehealth_graphify.py; do
  if [ ! -s "$TOOL_ROOT/$tool_file" ]; then
    echo "codehealth: required tool is missing or empty: $TOOL_ROOT/$tool_file" >&2
    exit 1
  fi
done

if ! git -C "$TARGET_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "codehealth: repository root is not a git worktree: $TARGET_ROOT" >&2
  exit 1
fi

rm -rf -- "$WORK_ROOT" "$SITE_ROOT"
mkdir -p \
  "$STRUCT_ROOT" \
  "$SITE_ROOT"/codehealth \
  "$REPORT_ROOT/lizard" \
  "$REPORT_ROOT/jscpd" \
  "$REPORT_ROOT/graphify"

cp -- "$TOOL_ROOT/site/styles.css" "$SITE_ROOT/"

python3 "$TOOL_ROOT/scripts/ci/codehealth_scope.py" candidates --repository-root "$TARGET_ROOT" > "$CANDIDATE_MANIFEST"

if [ ! -s "$CANDIDATE_MANIFEST" ]; then
  echo "codehealth: candidate Lua manifest is empty" >&2
  exit 1
fi

LIZARD_CSV="$REPORT_ROOT/lizard/functions.csv"
LIZARD_HTML="$REPORT_ROOT/lizard/index.html"
(
  cd -- "$TARGET_ROOT"
  lizard -l lua -t 4 -i -1 -f "$CANDIDATE_MANIFEST" -H > "$LIZARD_HTML"
  lizard -l lua -t 4 -i -1 -f "$CANDIDATE_MANIFEST" -V --csv > "$LIZARD_CSV"
)

python3 "$TOOL_ROOT/scripts/ci/codehealth_scope.py" structural \
  --repository-root "$TARGET_ROOT" \
  --candidates "$CANDIDATE_MANIFEST" \
  --lizard-csv "$LIZARD_CSV" > "$FINAL_MANIFEST"

if [ ! -s "$FINAL_MANIFEST" ]; then
  echo "codehealth: structural Lua manifest is empty" >&2
  exit 1
fi

while IFS= read -r path; do
  mkdir -p "$STRUCT_ROOT/$(dirname "$path")"
  cp -- "$TARGET_ROOT/$path" "$STRUCT_ROOT/$path"
done < "$FINAL_MANIFEST"

(
  cd "$STRUCT_ROOT"
  jscpd . \
    --format lua \
    --mode mild \
    --min-lines 5 \
    --min-tokens 50 \
    --max-lines 10000 \
    --max-size 2mb \
    --workers 4 \
    --reporters html,json,markdown \
    --output "$REPORT_ROOT/jscpd"
)

GRAPHIFY_REPORT_ROOT="$REPORT_ROOT/graphify"
GRAPH_JSON="$GRAPHIFY_REPORT_ROOT/graph.json"
python3 "$TOOL_ROOT/scripts/ci/codehealth_graphify.py" \
  --source-root "$STRUCT_ROOT" \
  --output "$GRAPH_JSON" \
  --cache-root "$WORK_ROOT/graphify-cache" \
  --max-workers 4
graphify export html \
  --graph "$GRAPH_JSON" \
  --output "$GRAPHIFY_REPORT_ROOT/graph.html"
graphify export callflow-html \
  --graph "$GRAPH_JSON" \
  --output "$GRAPHIFY_REPORT_ROOT/callflow.html"

if [ -n "$PREVIOUS_HISTORY" ]; then
  if [ ! -r "$PREVIOUS_HISTORY" ]; then
    echo "codehealth: previous history is not readable: $PREVIOUS_HISTORY" >&2
    exit 1
  fi
  REPORT_HISTORY_ARGS=(--previous-history "$PREVIOUS_HISTORY")
else
  REPORT_HISTORY_ARGS=()
fi

python3 "$TOOL_ROOT/scripts/ci/codehealth_report.py" \
  --site-root "$SITE_ROOT" \
  --repository-root "$TARGET_ROOT" \
  --structural-manifest "$FINAL_MANIFEST" \
  "${REPORT_HISTORY_ARGS[@]+"${REPORT_HISTORY_ARGS[@]}"}"

for required_file in \
  styles.css \
  codehealth/index.html \
  codehealth/quality-report.json \
  codehealth/history.json \
  codehealth/reports/lizard/index.html \
  codehealth/reports/lizard/functions.csv \
  codehealth/reports/jscpd/jscpd-report.html \
  codehealth/reports/jscpd/jscpd-report.json \
  codehealth/reports/jscpd/jscpd-report.md \
  codehealth/reports/graphify/graph.html \
  codehealth/reports/graphify/callflow.html \
  codehealth/reports/graphify/graph.json; do
  if [ ! -s "$SITE_ROOT/$required_file" ]; then
    echo "codehealth: required published report is missing or empty: $SITE_ROOT/$required_file" >&2
    exit 1
  fi
done

trap - EXIT
echo "codehealth: published artifact at $SITE_ROOT"
