#!/usr/bin/env bash
# The single test command. Runs every available layer:
#   scripts/test.sh
#   scripts/test.sh --list
#   scripts/test.sh --layer unit|component|graphics|rom|acceptance
#   scripts/test.sh --filter <substring>
#   scripts/test.sh --jobs <positive-integer>
#   scripts/test.sh --rom-source <path-to.nds-or-zip>
#
# Arguments are parsed by tests/runner/Cli.lua; this script only decides where
# the save root lives and whether to prepare the derived cache first. That
# decision comes from the runner's own plan mode (`--plan`): the plan call
# itself exits 2 on a usage error and answers, machine-readably, whether
# preparation (and a supplied source import) is needed — the shell never
# re-implements option scanning. With a ready dump the published derived cache
# is checked before the ROM-gated layers. The incremental builder runs only
# when that audit finds no usable cache; with no dump those layers skip loudly.
# G4RECOMP_REQUIRE_ROM_TESTS=1 makes a missing dump fatal.
# Exit status: 0 green, 1 failures or a missing required capability, 2 usage.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/dev.sh

temp_dirs=()
cleanup() {
  for directory in "${temp_dirs[@]}"; do
    rm -rf -- "$directory"
  done
}
trap cleanup EXIT

# No inherited worker token may leak into planning, cache preparation, or
# serial execution; only a worker subshell below exports one.
unset G4RECOMP_TEST_ACCEPTANCE_NAMESPACE

# Terminate every still-tracked worker before waiting any of them, so one
# long-running worker cannot delay signal delivery to the others; then wait
# every tracked PID so cancellation always reaps before returning. Failed
# kill/wait during cancellation are expected races with a naturally exiting
# worker, not a replacement for the cancellation status.
terminate_workers() {
  for worker in "${!pids[@]}"; do
    kill -TERM "${pids[$worker]}" 2>/dev/null || true
  done
  for worker in "${!pids[@]}"; do
    wait "${pids[$worker]}" 2>/dev/null || true
  done
  pids=()
}

# Disable INT/TERM traps first so cancellation cannot reenter itself, then
# terminate/reap owned workers, then exit with the conventional signal
# status. The EXIT trap runs after this exits, so run_dir cleanup happens
# only once every tracked worker has been reaped.
cancel_parallel() {
  trap - INT TERM
  terminate_workers
  exit "$1"
}

# Match the development container's supported graphics host. Callers may still
# override either variable for driver diagnosis, but the default test command
# must create the same offscreen software context on a machine without a
# desktop session.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

# The graphics layer is part of the required surface, so a whole-run selection
# that executes no graphics test fails instead of passing silently. Callers
# may still override it for diagnosis, like the SDL variables above.
export G4RECOMP_REQUIRE_GRAPHICS_TESTS="${G4RECOMP_REQUIRE_GRAPHICS_TESTS:-1}"

# `love romdump/ --build-cache` exits 2 with "no ready dump" when there is
# nothing to prepare; any other nonzero status is a real preparation failure.
NO_DUMP_STATUS=2

# The runner's plan answer: preparation is needed for everything except a
# listing and the three ROM-independent layers, and a supplied source is
# always imported. A misread plan (protocol drift) must fail loudly rather
# than silently run against a stale cache.
plan="$(love app/ --test --plan "$@")"
prepare=""
rom_source=""
jobs=""
while IFS= read -r line; do
  case "$line" in
    prepare=*) prepare="${line#prepare=}" ;;
    rom_source=*) rom_source="${line#rom_source=}" ;;
    jobs=*) jobs="${line#jobs=}" ;;
  esac
done <<<"$plan"
if [ "$prepare" != 0 ] && [ "$prepare" != 1 ]; then
  echo "test: the runner plan did not answer prepare=0|1 (got '$prepare')" >&2
  exit 1
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "test: the runner plan did not answer a positive jobs count (got '$jobs')" >&2
  exit 1
fi

status=0
if [ "$prepare" = 1 ]; then
  if [ -n "$rom_source" ]; then
    # An isolated save root: importing and building a supplied source must never
    # touch the user's ordinary cache or saves.
    isolated="$(mktemp -d)"
    temp_dirs+=("$isolated")
    export XDG_DATA_HOME="$isolated"
    echo "== import and build $rom_source into $isolated =="
    love romdump/ --build-cache "$rom_source"
  else
    BUILD_LOG_DIR="$(mktemp -d)"
    temp_dirs+=("$BUILD_LOG_DIR")
    BUILD_LOG="$BUILD_LOG_DIR/buildcache.log"
    # The producer fingerprint + build-state check makes --build-cache cheap
    # when nothing relevant changed: an identity match with a fully available
    # cache means no ROM open and no compilation. A producer/contract/dump
    # change rebuilds once; a damaged cache takes the repair path. This
    # prevents tests from accepting a merely complete but stale cache.
    love romdump/ --build-cache >"$BUILD_LOG" 2>&1 || status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne "$NO_DUMP_STATUS" ]; then
      tail -n 20 "$BUILD_LOG" >&2
      echo "test: derived-cache preparation failed (exit $status); see $BUILD_LOG" >&2
      exit "$status"
    fi
    { grep -v ' current$' "$BUILD_LOG" | tail -n 5; } || true
  fi

  if [ "$status" -eq 0 ]; then
    export G4RECOMP_DERIVED_CACHE_READY=1
  fi
fi

# Not `exec`: the isolated save root of --rom-source is removed by the EXIT trap,
# which a replaced process would never run.
status=0
echo "Running tests..."
if [ "$jobs" -eq 1 ]; then
  love app/ --test "$@" || status=$?
else
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/g4recomp-tests.XXXXXXXX")"
  temp_dirs+=("$run_dir")
  run_token="${run_dir##*/}"
  echo "Running tests with $jobs workers..."
  pids=()
  trap 'cancel_parallel 130' INT
  trap 'cancel_parallel 143' TERM
  for ((worker = 1; worker <= jobs; worker++)); do
    (
      unset G4RECOMP_TEST_AGGREGATE G4RECOMP_TEST_WORKER
      export G4RECOMP_TEST_RUN_DIR="$run_dir"
      export G4RECOMP_TEST_WORKERS="$jobs"
      export G4RECOMP_TEST_WORKER="$worker"
      export G4RECOMP_TEST_ACCEPTANCE_NAMESPACE="${run_token}-w${worker}"
      exec love app/ --test "$@"
    ) >"$run_dir/worker-$worker.log" 2>&1 &
    pids[$worker]=$!
  done
  worker_status=0
  for ((worker = 1; worker <= jobs; worker++)); do
    if wait "${pids[$worker]}"; then
      :
    else
      child_status=$?
      echo "test: worker $worker failed with status $child_status" >&2
      tail -n 40 "$run_dir/worker-$worker.log" >&2 || true
      worker_status=1
    fi
    unset "pids[$worker]"
  done
  trap - INT TERM
  if [ "$worker_status" -ne 0 ]; then
    status="$worker_status"
  else
    (
      unset G4RECOMP_TEST_WORKER G4RECOMP_TEST_ACCEPTANCE_NAMESPACE
      export G4RECOMP_TEST_RUN_DIR="$run_dir"
      export G4RECOMP_TEST_WORKERS="$jobs"
      export G4RECOMP_TEST_AGGREGATE=1
      love app/ --test "$@"
    ) || status=$?
  fi
fi
exit "$status"
