#!/usr/bin/env bash
# Configure the repository's local Git hook path.
set -euo pipefail
cd "$(dirname "$0")/../.."

hooks_path=""
if hooks_path="$(git config --local --get core.hooksPath 2>/dev/null)"; then
  if [ "$hooks_path" = "scripts/hooks" ]; then
    exit 0
  fi
else
  config_status="$?"
  if [ "$config_status" -ne 1 ]; then
    exit "$config_status"
  fi
fi

git config --local core.hooksPath scripts/hooks
echo "core.hooksPath -> scripts/hooks (pre-commit checks staged repository invariants and runs full lint)"
