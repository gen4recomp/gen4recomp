#!/usr/bin/env bash
# Build disposable static-analysis reports for the GitHub Pages artifact.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

WORK_ROOT="$REPO_ROOT/tmp/codehealth-work"
SITE_ROOT="$REPO_ROOT/tmp/codehealth-site"
STRUCT_ROOT="$WORK_ROOT/production-lua"
REPORT_ROOT="$SITE_ROOT/codehealth/reports"

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

for source_file in site/index.html site/styles.css; do
  if [ ! -s "$source_file" ]; then
    echo "codehealth: required site source is missing or empty: $source_file" >&2
    exit 1
  fi
done

rm -rf -- "$WORK_ROOT" "$SITE_ROOT"
mkdir -p \
  "$STRUCT_ROOT" \
  "$SITE_ROOT"/codehealth \
  "$REPORT_ROOT/lizard" \
  "$REPORT_ROOT/jscpd" \
  "$REPORT_ROOT/graphify"

cp -- site/index.html site/styles.css "$SITE_ROOT/"

python3 scripts/ci/source_scope.py --scope production > "$WORK_ROOT/production-lua-files.txt"

if [ ! -s "$WORK_ROOT/production-lua-files.txt" ]; then
  echo "codehealth: production Lua manifest is empty" >&2
  exit 1
fi

while IFS= read -r path; do
  mkdir -p "$STRUCT_ROOT/$(dirname "$path")"
  cp -- "$path" "$STRUCT_ROOT/$path"
done < "$WORK_ROOT/production-lua-files.txt"

FILE_LIST="$WORK_ROOT/production-lua-files.txt"
lizard -l lua -t 4 -i -1 -f "$FILE_LIST" -H > "$REPORT_ROOT/lizard/index.html"
lizard -l lua -t 4 -i -1 -f "$FILE_LIST" -V --csv > "$REPORT_ROOT/lizard/functions.csv"

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
python3 scripts/ci/codehealth_graphify.py \
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

python3 scripts/ci/codehealth_report.py --site-root tmp/codehealth-site

for required_file in \
  index.html \
  styles.css \
  codehealth/index.html \
  codehealth/quality-report.json \
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
