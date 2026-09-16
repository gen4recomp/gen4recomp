#!/usr/bin/env bash
# The single test command. Runs every available layer:
#   scripts/test.sh
#   scripts/test.sh --list
#   scripts/test.sh --layer unit|component|graphics|rom|acceptance
#   scripts/test.sh --filter <substring>
#   scripts/test.sh --serial
#   scripts/test.sh --rom-source <path-to.nds-or-zip>
#   scripts/test.sh --rom-source <path-to.nds-or-zip> --fresh
#
# Arguments are parsed by tests/runner/Cli.lua; this script only decides where
# the save root lives and whether to prepare the derived cache first. That
# decision comes from the runner's own plan mode (`--plan`): the plan call
# itself exits 2 on a usage error and answers, machine-readably, the
# preparation scope, the cold-rerun flag, the source to import, and the exact
# closed requirements of the selection — the shell never re-implements option
# scanning. An explicit source seeds a persistent private cache rooted at
# ${XDG_CACHE_HOME:-$HOME/.cache}/portemon/rom-tests/<rom-sha1>/ and guarded
# by an exclusive lock; a later plain run reuses the last successfully
# selected private cache, and --fresh performs a real cold import into an
# owned temporary root that is removed after its children exit. The product
# cache and personal saves are never touched by test preparation.
# Readiness always comes from the common scoped builder (`love romdump/
# --prepare-cache --dev`), which alone issues the invocation receipt the test
# children validate; reused scope text from an earlier invocation never
# authorizes the current run.
# PORTEMON_REQUIRE_ROM_TESTS=1 makes a missing dump fatal.
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

# No inherited worker token, stale preparation record, or stale readiness
# claim may leak into planning, cache preparation, or serial execution; only
# a worker subshell below exports one, and the invocation receipt below is
# exported only for preparation this invocation established.
unset PORTEMON_TEST_ACCEPTANCE_NAMESPACE
unset PORTEMON_TEST_PREPARATION
unset PORTEMON_DERIVED_CACHE_READY

# Terminate every still-tracked child before waiting any of them, so one
# long-running child cannot delay signal delivery to the others; then wait
# every tracked PID so cancellation always reaps before returning. Failed
# kill/wait during cancellation are expected races with a naturally exiting
# child, not a replacement for the cancellation status.
terminate_children() {
  for tracked in "${!pids[@]}"; do
    kill -TERM "${pids[$tracked]}" 2>/dev/null || true
  done
  for tracked in "${!pids[@]}"; do
    wait "${pids[$tracked]}" 2>/dev/null || true
  done
  pids=()
}

# Disable INT/TERM traps first so cancellation cannot reenter itself, then
# terminate/reap owned children, then exit with the conventional signal
# status. The EXIT trap runs after this exits, so run_dir cleanup happens
# only once every tracked child has been reaped. Locks held on shell file
# descriptors release when this process exits, which is after the reap.
cancel_parallel() {
  trap - INT TERM
  terminate_children
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
export PORTEMON_REQUIRE_GRAPHICS_TESTS="${PORTEMON_REQUIRE_GRAPHICS_TESTS:-1}"

# A selection file value is only ever a version name or a content hash: it
# must never become a path. Reject everything else before any filesystem use.
is_version_name() {
  [[ "$1" =~ ^[a-z][a-z0-9]*$ ]]
}

is_content_hash() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# A closed preparation requirement is a scope word or one kind:key pair with
# no whitespace; the cache builder owns the authoritative grammar and rejects
# the rest as a usage error.
is_requirement() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || [[ "$1" =~ ^[^:[:space:]]+:[^:[:space:]]+$ ]]
}

# Read the private last-selected source without trusting it: the file must
# hold exactly the two strict lines, otherwise there is no selection.
read_selection() {
  select_version=""
  select_sha=""
  [ -f "$selection_file" ] || return 0
  if [ "$(wc -l <"$selection_file" | tr -d ' ')" != 2 ]; then
    return 0
  fi
  local version_line="" sha_line=""
  version_line="$(sed -n 's/^version=//p' -- "$selection_file" | head -n 1)"
  sha_line="$(sed -n 's/^rom_sha1=//p' -- "$selection_file" | head -n 1)"
  if is_version_name "$version_line" && is_content_hash "$sha_line"; then
    select_version="$version_line"
    select_sha="$sha_line"
  fi
  return 0
}

# Atomically record the last successfully selected private source. Only
# validated version/hash pairs reach this writer; callers validate first.
write_selection() {
  mkdir -p -- "$test_root"
  local temporary="$test_root/selected-rom.tmp.$$"
  printf 'version=%s\nrom_sha1=%s\n' "$1" "$2" >"$temporary"
  mv -- "$temporary" "$selection_file"
}

# Validate one ROM path through the canonical source owner and report its
# version identity without importing, creating cache state, or starting
# compiler workers. Exits nonzero when the source is unusable.
probe_source() {
  local probe_out=""
  local probe_status=0
  probe_out="$(love romdump/ --probe-rom "$1")" || probe_status=$?
  if [ "$probe_status" -ne 0 ]; then
    printf '%s\n' "$probe_out"
    echo "test: source validation failed for $1 (exit $probe_status)" >&2
    exit "$probe_status"
  fi
  probe_version="$(printf '%s\n' "$probe_out" | sed -n 's/^version=//p' | head -n 1)"
  probe_sha="$(printf '%s\n' "$probe_out" | sed -n 's/^rom_sha1=//p' | head -n 1)"
  if ! is_version_name "$probe_version" || ! is_content_hash "$probe_sha"; then
    echo "test: source validation answered an unusable identity for $1" >&2
    exit 1
  fi
}

# Run the cache builder's scoped preparation for the exact requirement union
# under the working-tree development identity and require the builder-issued
# invocation receipt. Any failure exits without touching the last valid
# selection, and no test child starts without the newly written receipt.
run_scoped_prepare() {
  local version="$1" receipt="$2"
  local prepare_args=()
  local requirement=""
  for requirement in "${requires[@]}"; do
    prepare_args+=(--require "$requirement")
  done
  local prepare_out=""
  local prepare_status=0
  prepare_out="$(love romdump/ --prepare-cache --dev --version "$version" "${prepare_args[@]}" --preparation-record "$receipt")" || prepare_status=$?
  printf '%s\n' "$prepare_out"
  if [ "$prepare_status" -ne 0 ]; then
    echo "test: scoped cache preparation failed (exit $prepare_status)" >&2
    exit "$prepare_status"
  fi
  case "$prepare_out" in
    *ready=false*)
      echo "test: scoped cache preparation left requirements unready" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$receipt" ]; then
    echo "test: scoped cache preparation issued no receipt" >&2
    exit 1
  fi
}

# An invocation-owned receipt directory for the builder-issued proof beneath
# the private test root. The receipt file inside is created only by a
# successful preparation below; the directory is removed with the other owned
# evidence after every child has been reaped. Sets $receipt_dir in the
# caller (a command substitution would lose the cleanup registration).
new_receipt_dir() {
  receipt_dir="$(mktemp -d -- "$test_root/preparation.XXXXXXXX")"
  temp_dirs+=("$receipt_dir")
}

# The runner's plan answer: the preparation scope the actual selection
# implies, the cold-rerun flag, the source to import, and the exact closed
# requirements. A misread plan (protocol drift) must fail loudly rather
# than silently run against a stale cache.
plan_status=0
plan="$(love app/ --test --plan "$@")" || plan_status=$?
if [ "$plan_status" -ne 0 ]; then
  exit "$plan_status"
fi
prepare=""
fresh="0"
rom_source=""
jobs=""
requires=()
while IFS= read -r line; do
  case "$line" in
    prepare=*) prepare="${line#prepare=}" ;;
    fresh=*) fresh="${line#fresh=}" ;;
    rom_source=*) rom_source="${line#rom_source=}" ;;
    jobs=*) jobs="${line#jobs=}" ;;
    require=*)
      requirement="${line#require=}"
      if ! is_requirement "$requirement"; then
        echo "test: the runner plan named an invalid requirement '$requirement'" >&2
        exit 1
      fi
      requires+=("$requirement")
      ;;
  esac
done <<<"$plan"
if [ "$prepare" != "none" ] && [ "$prepare" != "assets" ] && [ "$prepare" != "complete" ]; then
  echo "test: the runner plan did not answer prepare=none|assets|complete (got '$prepare')" >&2
  exit 1
fi
if [ "$fresh" != "0" ] && [ "$fresh" != "1" ]; then
  echo "test: the runner plan did not answer fresh=0|1 (got '$fresh')" >&2
  exit 1
fi
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "test: the runner plan did not answer a positive jobs count (got '$jobs')" >&2
  exit 1
fi
if [ -z "$rom_source" ] && [ "$fresh" = 1 ]; then
  echo "test: --fresh requires --rom-source <path-to-nds-or-zip>" >&2
  exit 2
fi

# Private developer test roots live under the cache home, never under the
# product save root; isolation is applied after the shared dev setup above
# so no inherited override can restore the product root for a child.
test_root="${XDG_CACHE_HOME:-$HOME/.cache}/portemon/rom-tests"
selection_file="$test_root/selected-rom"

# Exclusive per-ROM mutation lock. Only Linux developer tooling provides it;
# selections that never mutate need no lock and stay portable.
take_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "test: the private test cache requires flock (Linux developer tooling)" >&2
    exit 1
  fi
  exec {lock_fd}>"$1/lock"
  flock "$lock_fd"
}

if [ "$fresh" = 1 ]; then
  # An explicit cold rerun: a new empty temporary data home, a real import,
  # and the declared closure only. Persistent artifacts and the private
  # default selection are neither read nor written; only the owned temporary
  # directory is removed after all children exit.
  fresh_root="$(mktemp -d)"
  temp_dirs+=("$fresh_root")
  export XDG_DATA_HOME="$fresh_root"
  unset PORTEMON_SAVE_DIR
  echo "== cold import $rom_source into $fresh_root =="
  love romdump/ --import-rom "$rom_source"
  if [ "$prepare" != "none" ]; then
    probe_source "$rom_source"
    run_scoped_prepare "$probe_version" "$fresh_root/preparation.lua"
    export PORTEMON_TEST_PREPARATION="$fresh_root/preparation.lua"
  else
    rm -f -- "$fresh_root/preparation.lua"
  fi
elif [ -n "$rom_source" ]; then
  # An explicit source: resolve its canonical identity through the source
  # owner before selecting a root, then reuse the private root for that
  # content hash, importing raw data only when absent and preparing exactly
  # the selected scope.
  probe_source "$rom_source"
  version="$probe_version"
  sha="$probe_sha"
  rom_dir="$test_root/$sha"
  data_home="$rom_dir/data-home"
  mkdir -p -- "$data_home"
  take_lock "$rom_dir"
  export XDG_DATA_HOME="$data_home"
  unset PORTEMON_SAVE_DIR
  if [ ! -f "$rom_dir/rom-ready" ]; then
    echo "== import $rom_source into $data_home =="
    import_status=0
    love romdump/ --import-rom "$rom_source" || import_status=$?
    if [ "$import_status" -ne 0 ]; then
      echo "test: private cache import failed (exit $import_status)" >&2
      exit "$import_status"
    fi
    printf 'version=%s\nrom_sha1=%s\n' "$version" "$sha" >"$rom_dir/rom-ready"
  fi
  # Stale scope text and predecessor receipts inside the owned root never
  # authorize reuse; only the builder-issued receipt below does.
  rm -f -- "$rom_dir/prepared" "$data_home/preparation.lua"
  if [ "$prepare" != "none" ]; then
    echo "== prepare ${requires[*]} for $version in $data_home =="
    new_receipt_dir
    run_scoped_prepare "$version" "$receipt_dir/preparation.lua"
    export PORTEMON_TEST_PREPARATION="$receipt_dir/preparation.lua"
  fi
  # Publish the successful selection only after this invocation's required
  # import and scoped preparation succeeded; a failed scope leaves the
  # previous selection in place while its valid raw import stays reusable.
  write_selection "$version" "$sha"
  echo "== private ROM test cache: $version $sha in $data_home =="
elif [ "$prepare" != "none" ]; then
  # A plain run: reuse the last successfully selected private cache when it
  # names a supported hash whose raw dump validates, otherwise run the
  # ROM-independent suites with explicit unavailable-ROM skips. The product
  # cache is never prepared here.
  read_selection
  if [ -n "$select_sha" ] && [ -f "$test_root/$select_sha/rom-ready" ]; then
    rom_dir="$test_root/$select_sha"
    data_home="$rom_dir/data-home"
    mkdir -p -- "$data_home"
    take_lock "$rom_dir"
    export XDG_DATA_HOME="$data_home"
    unset PORTEMON_SAVE_DIR
    version="$select_version"
    rm -f -- "$rom_dir/prepared" "$data_home/preparation.lua"
    echo "== private ROM test cache: $version $select_sha in $data_home =="
    echo "== prepare ${requires[*]} for $version in $data_home =="
    new_receipt_dir
    run_scoped_prepare "$version" "$receipt_dir/preparation.lua"
    export PORTEMON_TEST_PREPARATION="$receipt_dir/preparation.lua"
  fi
fi

# Not `exec`: the isolated save roots above are removed by the EXIT trap,
# which a replaced process would never run. Locks held above release when
# this process exits, which is after every child below has been reaped.
status=0
echo "Running tests..."
if [ "$jobs" -eq 1 ]; then
  love app/ --test "$@" || status=$?
else
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/portemon-tests.XXXXXXXX")"
  temp_dirs+=("$run_dir")
  run_token="${run_dir##*/}"
  echo "Running tests with $jobs workers..."
  pids=()
  trap 'cancel_parallel 130' INT
  trap 'cancel_parallel 143' TERM
  for ((worker = 1; worker <= jobs; worker++)); do
    (
      unset PORTEMON_TEST_AGGREGATE PORTEMON_TEST_WORKER
      export PORTEMON_TEST_RUN_DIR="$run_dir"
      export PORTEMON_TEST_WORKERS="$jobs"
      export PORTEMON_TEST_WORKER="$worker"
      export PORTEMON_TEST_ACCEPTANCE_NAMESPACE="${run_token}-w${worker}"
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
  if [ "$worker_status" -ne 0 ]; then
    status="$worker_status"
  else
    (
      unset PORTEMON_TEST_WORKER PORTEMON_TEST_ACCEPTANCE_NAMESPACE
      export PORTEMON_TEST_RUN_DIR="$run_dir"
      export PORTEMON_TEST_WORKERS="$jobs"
      export PORTEMON_TEST_AGGREGATE=1
      exec love app/ --test "$@"
    ) &
    pids[1]=$!
    if wait "${pids[1]}"; then
      :
    else
      status=$?
    fi
    unset "pids[1]"
  fi
  trap - INT TERM
fi
if [ -n "${lock_fd:-}" ]; then
  exec {lock_fd}>&-
fi
exit "$status"
