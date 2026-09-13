#!/usr/bin/env bash
# Rebuild the complete game-facing cache. Reuses an existing raw dump; when no
# dump is ready, accepts a ROM path, imports it, then builds the derived cache.
# Pass --forcedump with a ROM to replace an existing raw dump before rebuilding.
# Exits nonzero when any resolved map failed asset compilation; pass
# --allow-compile-exclusions for an exploratory run that accepts them.
# The wrapper builds the development cache identity (producer working-tree
# bytes) by default; pass --release once to build the release cache identity
# (the explicit per-game counter, no source reads) instead. Passing both mode
# flags, or repeating either one, is a usage error.
# Usage: scripts/buildcache.sh [path-to.nds-or.zip] [--allow-compile-exclusions] [--dev | --release]
#        scripts/buildcache.sh --forcedump <path-to.nds-or.zip> [--allow-compile-exclusions] [--dev | --release]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/dev.sh

usage() {
  echo "usage: scripts/buildcache.sh [path-to.nds-or.zip] [--allow-compile-exclusions] [--dev | --release]" >&2
  echo "       scripts/buildcache.sh --forcedump <path-to.nds-or.zip> [--allow-compile-exclusions] [--dev | --release]" >&2
}

flags=()
args=()
mode=""
for a in "$@"; do
  if [ "$a" = "--allow-compile-exclusions" ]; then
    flags+=("$a")
  elif [ "$a" = "--dev" ] || [ "$a" = "--release" ]; then
    if [ -n "$mode" ]; then
      usage
      exit 2
    fi
    mode="$a"
  else
    args+=("$a")
  fi
done

devFlag=(--dev)
if [ "$mode" = "--release" ]; then
  devFlag=()
fi

if [ "${args[0]:-}" = "--forcedump" ]; then
  if [ "${#args[@]}" -ne 2 ]; then
    usage
    exit 2
  fi
  exec love romdump/ --build-cache --forcedump "${args[1]}" ${flags[@]+"${flags[@]}"} ${devFlag[@]+"${devFlag[@]}"}
fi

if [ "${#args[@]}" -gt 1 ]; then
  usage
  exit 2
fi

exec love romdump/ --build-cache ${args[@]+"${args[@]}"} ${flags[@]+"${flags[@]}"} ${devFlag[@]+"${devFlag[@]}"}
