-- Black-box process contract for the test command's private ROM-cache
-- management: one private root reused across repeated source runs, an
-- explicit cold rerun, partial-scope preparation, no product-root mutation,
-- validated private selection, serialized mutation, and ordered
-- cancellation. Pure Lua selection/capability rules cannot observe process
-- roots, locks, or cleanup ordering, so these drive the existing test
-- command with a generated fake `love` executable: plan answers come from
-- the real runner while ROM preparation and test execution are recorded
-- fakes, so no real dump, build, or graphics host is required.

local Assert = require("tests.support.Assert")

local T = {}

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function popen(command)
  return assert(io.popen(command))
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function mkdtemp()
  local handle = popen("mktemp -d")
  local path = trim(handle:read("*l") or "")
  handle:close()
  assert(path ~= "", "mktemp -d produced no path")
  return path
end

local function mkdir(path)
  os.execute("mkdir -p -- " .. shellQuote(path))
end

local function writeFile(path, content)
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function writeExecutable(path, content)
  writeFile(path, content)
  os.execute("chmod +x -- " .. shellQuote(path))
end

local function fileExists(path)
  local handle = io.open(path, "r")
  if handle then
    handle:close()
    return true
  end
  return false
end

local function readFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function dirExists(path)
  local handle = popen("[ -d " .. shellQuote(path) .. " ] && echo yes || echo no")
  local result = trim(handle:read("*l") or "")
  handle:close()
  return result == "yes"
end

local function listFiles(directory, prefix)
  local handle = popen("ls -- " .. shellQuote(directory) .. " 2>/dev/null")
  local names = {}
  for line in handle:lines() do
    if line:sub(1, #prefix) == prefix then
      names[#names + 1] = line
    end
  end
  handle:close()
  return names
end

local function waitUntil(maxAttempts, intervalSeconds, description, predicate)
  for _ = 1, maxAttempts do
    if predicate() then
      return
    end
    os.execute("sleep " .. tostring(intervalSeconds))
  end
  error("timed out waiting for " .. description, 2)
end

local function contains(text, needle, label)
  Assert.isTrue(
    tostring(text):find(needle, 1, true) ~= nil,
    (label or "text") .. " must mention " .. string.format("%q", needle) .. ", got: " .. tostring(text)
  )
end

local function writeProductSentinel(content)
  mkdir(".cache")
  writeFile(".cache/isolation_probe_sentinel", content)
end

local function removeProductSentinel()
  os.execute("rm -f -- " .. shellQuote(".cache/isolation_probe_sentinel"))
  os.execute("rmdir -- .cache 2>/dev/null")
end

local function readProductSentinel()
  return readFile(".cache/isolation_probe_sentinel")
end

-- The real `love` binary, resolved outside the fake on PATH so plan answers
-- keep the runner's real selection semantics while preparation and execution
-- stay recorded fakes.
local function realLove()
  local handle = popen("command -v love 2>/dev/null || echo /usr/bin/love")
  local path = trim(handle:read("*l") or "")
  handle:close()
  assert(path ~= "", "cannot locate the real love executable")
  return path
end

-- Every nested command runs inside this worktree with worker identity
-- sanitized, a fresh fake `love` first on PATH, and the product save
-- location left to the repository's own environment file so product-root
-- isolation is proved against the real default.
local SANITIZE_ENV =
  "unset PORTEMON_TEST_RUN_DIR PORTEMON_TEST_WORKERS PORTEMON_TEST_WORKER PORTEMON_TEST_AGGREGATE PORTEMON_TEST_ACCEPTANCE_NAMESPACE PORTEMON_TEST_PREPARATION PORTEMON_DERIVED_CACHE_READY PORTEMON_REQUIRE_ROM_TESTS;"

-- Generated fake `love`: plan mode is delegated to the real binary so the
-- runner's actual selection rules apply; ROM preparation records its data
-- home and arguments per invocation (and emulates a content-keyed probe
-- answer when asked); test execution records the data home it observed.
-- Slow knobs simulate long imports and workers without any real build.
local FAKE_LOVE = [[
#!/usr/bin/env bash
set -u
record_dir="${FAKE_ISOLATION_RECORD_DIR:?missing record dir}"
run_tag="${FAKE_RUN_TAG:-run}"
has_plan=false
for arg in "$@"; do
  if [ "$arg" = "--plan" ]; then has_plan=true; fi
done
if [ "$has_plan" = true ]; then
  exec "${FAKE_REAL_LOVE:?missing real love}" "$@"
fi
target="${1:-}"
if [ "$target" = "romdump/" ]; then
  invocation="$record_dir/preparation-${run_tag}-${BASHPID}.log"
  {
    printf 'tag=%s\n' "$run_tag"
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}"
    printf 'argv=%s\n' "$*"
    printf 'start=%s\n' "$(date +%s.%N)"
  } > "$invocation"
  if [ "${2:-}" = "--probe-rom" ]; then
    rom_path="${3:-}"
    sha="missing"
    if [ -f "$rom_path" ]; then sha="$(sha1sum -- "$rom_path" | cut -d ' ' -f 1)"; fi
    printf 'version=%s\n' "${FAKE_PROBE_VERSION:-heartgold}"
    printf 'rom_sha1=%s\n' "$sha"
  fi
  if [ "${2:-}" = "--build-cache" ]; then
    printf 'import complete: %s\n' "${FAKE_PROBE_VERSION:-heartgold}"
  fi
  # A successful scoped preparation issues its invocation receipt the way
  # the common builder does; a failed one leaves no successful receipt.
  # Only scoped preparation honors the failure switch: probing and raw
  # import always succeed, so a failing scope proves selection preservation
  # with a reusable raw import behind it.
  command_status=0
  if [ "${2:-}" = "--prepare-cache" ]; then command_status="${FAKE_PREPARATION_STATUS:-0}"; fi
  if [ "$command_status" = "0" ]; then
    previous=""
    for arg in "$@"; do
      if [ "$previous" = "--preparation-record" ]; then : > "$arg"; fi
      previous="$arg"
    done
  fi
  if [ "${FAKE_SLOW_PREPARATION:-0}" != "0" ]; then sleep "$FAKE_SLOW_PREPARATION"; fi
  printf 'end=%s\n' "$(date +%s.%N)" >> "$invocation"
  exit "$command_status"
fi
if [ "$target" = "app/" ]; then
  if [ -n "${PORTEMON_TEST_AGGREGATE:-}" ]; then
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}" > "$record_dir/aggregate.txt"
    exit 0
  fi
  if [ -n "${PORTEMON_TEST_WORKER:-}" ]; then
    worker="$PORTEMON_TEST_WORKER"
    echo "$$" > "$record_dir/worker-$worker.pid"
    : > "$record_dir/worker-$worker.live"
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}" > "$record_dir/worker-$worker.txt"
    term_handler() {
      if [ -n "${XDG_DATA_HOME:-}" ] && [ -d "$XDG_DATA_HOME" ]; then
        echo present > "$record_dir/worker-$worker.xdg-during-term"
      else
        echo absent > "$record_dir/worker-$worker.xdg-during-term"
      fi
      : > "$record_dir/worker-$worker.terminated"
      rm -f "$record_dir/worker-$worker.live"
      if [ -n "${child:-}" ]; then kill "$child" 2>/dev/null || true; fi
      exit 143
    }
    trap term_handler TERM
    if [ "${FAKE_SLOW_WORKER:-0}" != "0" ]; then
      sleep "$FAKE_SLOW_WORKER" &
      child=$!
      wait "$child"
    fi
    rm -f "$record_dir/worker-$worker.live"
    : > "$record_dir/worker-$worker.done"
    exit 0
  fi
  {
    printf 'tag=%s\n' "$run_tag"
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}"
    printf 'argv=%s\n' "$*"
  } > "$record_dir/serial.txt"
  exit 0
fi
echo "fake love: unrecognized invocation: $*" >&2
exit 1
]]

local function withTempDirectory(fn)
  local root = mkdtemp()
  local ok, err = pcall(fn, root)
  os.execute("rm -rf -- " .. shellQuote(root))
  if not ok then
    error(err, 0)
  end
end

local function installFakeLove(root)
  local fakeLoveDir = root .. "/bin"
  mkdir(fakeLoveDir)
  writeExecutable(fakeLoveDir .. "/love", FAKE_LOVE)
  return fakeLoveDir
end

-- One nested test-command invocation. `extra` supplies scenario exports
-- (record dir, run tag, slow knobs); the command always runs with an
-- isolated private test-cache parent and reports its exit status to a file.
local function runTestCommand(root, fakeLoveDir, args, extra)
  local recordDir = (extra or {}).recordDir or (root .. "/records")
  mkdir(recordDir)
  local logFile = recordDir .. "/" .. ((extra or {}).logName or "command.log")
  local statusFile = recordDir .. "/" .. ((extra or {}).statusName or "status")
  local exports = {
    "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
    "export FAKE_REAL_LOVE=" .. shellQuote(realLove()) .. ";",
    "export FAKE_ISOLATION_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
    "export FAKE_RUN_TAG=" .. shellQuote((extra or {}).runTag or "run") .. ";",
    "export XDG_CACHE_HOME=" .. shellQuote(root .. "/cache") .. ";",
  }
  for _, name in ipairs({
    "FAKE_SLOW_PREPARATION",
    "FAKE_SLOW_WORKER",
    "FAKE_PREPARATION_STATUS",
    "FAKE_PROBE_VERSION",
  }) do
    if extra ~= nil and extra[name] ~= nil then
      exports[#exports + 1] = "export " .. name .. "=" .. shellQuote(extra[name]) .. ";"
    end
  end
  local command = table.concat({
    SANITIZE_ENV,
    table.concat(exports, " "),
    "scripts/test.sh " .. args .. " >" .. shellQuote(logFile) .. " 2>&1;",
    "echo $? > " .. shellQuote(statusFile) .. ";",
  }, " ")
  local handle = popen(command)
  local _ = handle:read("*a")
  handle:close()
  return recordDir, logFile, statusFile
end

local function exitStatus(statusFile)
  return trim(readFile(statusFile) or "")
end

local function fieldOf(path, field)
  local content = readFile(path)
  if content == nil then
    return nil
  end
  return content:match(field .. "=([^\n]*)")
end

-- All recorded preparation invocations across every run sharing a record
-- directory: one parsed record per per-invocation log file.
local function preparationInvocations(recordDir)
  local invocations = {}
  for _, name in ipairs(listFiles(recordDir, "preparation-")) do
    local path = recordDir .. "/" .. name
    invocations[#invocations + 1] = {
      tag = fieldOf(path, "tag"),
      xdg = fieldOf(path, "xdg"),
      argv = fieldOf(path, "argv"),
      start = tonumber(fieldOf(path, "start") or ""),
      finish = tonumber(fieldOf(path, "finish") or fieldOf(path, "end") or ""),
    }
  end
  return invocations
end

local function countImports(invocations, needle)
  local count = 0
  for _, invocation in ipairs(invocations) do
    if (invocation.argv or ""):find(needle, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function invocationsWith(invocations, needle)
  local selected = {}
  for _, invocation in ipairs(invocations) do
    if (invocation.argv or ""):find(needle, 1, true) ~= nil then
      selected[#selected + 1] = invocation
    end
  end
  return selected
end

local function shaOf(path)
  local handle = popen("sha1sum -- " .. shellQuote(path))
  local digest = trim((handle:read("*l") or ""):match("^%S+") or "")
  handle:close()
  assert(#digest == 40, "the fixture source has a content identity")
  return digest
end

local function requiresOf(argv)
  local requirements = {}
  for requirement in (argv or ""):gmatch("%-%-require ([^%s]+)") do
    requirements[#requirements + 1] = requirement
  end
  table.sort(requirements)
  return requirements
end

local function assertRequireUnion(argv, expected, label)
  local wanted = {}
  for _, requirement in ipairs(expected) do
    wanted[#wanted + 1] = requirement
  end
  table.sort(wanted)
  Assert.deepEqual(requiresOf(argv), wanted, label .. ", got: " .. tostring(argv))
end

-- A repeated run against the same source must reuse one surviving private
-- root and skip the second import: identity is validated, nothing is
-- recompiled, and both runs execute inside the same data home.
function T.a_repeated_source_run_reuses_one_private_root_and_skips_the_second_import()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for the repeat run")

    local record1 = root .. "/run1"
    local _, _, status1 = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test",
      { recordDir = record1, runTag = "first" }
    )
    Assert.equal(
      exitStatus(status1),
      "0",
      "the first run must succeed: " .. tostring(readFile(record1 .. "/command.log"))
    )

    local record2 = root .. "/run2"
    local _, _, status2 = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test",
      { recordDir = record2, runTag = "second" }
    )
    Assert.equal(
      exitStatus(status2),
      "0",
      "the second run must succeed: " .. tostring(readFile(record2 .. "/command.log"))
    )

    local firstXdg = fieldOf(record1 .. "/serial.txt", "xdg")
    local secondXdg = fieldOf(record2 .. "/serial.txt", "xdg")
    Assert.isTrue(firstXdg ~= nil and firstXdg ~= "", "the first run must record its data home")
    Assert.equal(secondXdg, firstXdg, "the second run must reuse the first run's private root")
    Assert.isTrue(dirExists(firstXdg), "the reused private root must survive between runs")

    local invocations = {}
    for _, invocation in ipairs(preparationInvocations(record1)) do
      invocations[#invocations + 1] = invocation
    end
    for _, invocation in ipairs(preparationInvocations(record2)) do
      invocations[#invocations + 1] = invocation
    end
    Assert.equal(
      countImports(invocations, "--import-rom") + countImports(invocations, "--build-cache"),
      1,
      "a ready private root must be imported exactly once across both runs"
    )
  end)
end

-- The same NDS bytes selected through a different path or container spelling
-- share one private namespace: identity comes from content, never from the
-- filename, the container, or the modification time.
function T.same_bytes_under_a_different_path_or_container_share_one_private_root()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local raw = root .. "/fixture.nds"
    local zipped = root .. "/copy.zip"
    writeFile(raw, "fixture rom bytes shared across spellings")
    writeFile(zipped, "fixture rom bytes shared across spellings")

    local record1 = root .. "/run1"
    local _, _, status1 = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(raw) .. " --filter field_dialogue_test",
      { recordDir = record1, runTag = "raw" }
    )
    Assert.equal(exitStatus(status1), "0", "the raw run must succeed")

    local record2 = root .. "/run2"
    local _, _, status2 = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(zipped) .. " --filter field_dialogue_test",
      { recordDir = record2, runTag = "zipped" }
    )
    Assert.equal(exitStatus(status2), "0", "the container-spelled run must succeed")

    local rawXdg = fieldOf(record1 .. "/serial.txt", "xdg")
    local zippedXdg = fieldOf(record2 .. "/serial.txt", "xdg")
    Assert.isTrue(rawXdg ~= nil and rawXdg ~= "", "the raw run must record its data home")
    Assert.equal(zippedXdg, rawXdg, "identical bytes must share one private root whatever the spelling")

    local invocations = {}
    for _, invocation in ipairs(preparationInvocations(record1)) do
      invocations[#invocations + 1] = invocation
    end
    for _, invocation in ipairs(preparationInvocations(record2)) do
      invocations[#invocations + 1] = invocation
    end
    Assert.equal(
      countImports(invocations, "--build-cache") + countImports(invocations, "--import-rom"),
      1,
      "identical bytes must be imported exactly once across spellings"
    )
  end)
end

-- An explicit cold rerun without a source is a usage error: the failure must
-- state the source rule instead of failing as an unknown option deep in the
-- plan or, worse, running against an unintended root.
function T.fresh_without_a_source_is_a_usage_error()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local recordDir, logFile, statusFile = runTestCommand(root, fakeLoveDir, "--fresh", { runTag = "freshless" })

    Assert.equal(exitStatus(statusFile), "2", "a sourceless cold rerun must exit with the usage status")
    local log = readFile(logFile) or ""
    contains(log, "--fresh", "the usage error names the cold-rerun option")
    Assert.isNil(
      log:find("unknown option", 1, true),
      "the failure must state the source rule, not an unknown option, got: " .. log
    )
    Assert.equal(#preparationInvocations(recordDir), 0, "a rejected cold rerun must prepare nothing")
  end)
end

-- An explicit cold rerun against a ready persistent cache still performs a
-- real import into a new empty temporary root, leaves the persistent cache
-- and every product sentinel untouched, and removes only that temporary
-- root once its children have exited.
function T.a_fresh_run_is_cold_temporary_and_leaves_the_persistent_cache_alone()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for the cold rerun")

    local warm = root .. "/run-warm"
    local _, _, warmStatus = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test",
      { recordDir = warm, runTag = "warm" }
    )
    Assert.equal(exitStatus(warmStatus), "0", "the seeding run must succeed")

    local persistentXdg = fieldOf(warm .. "/serial.txt", "xdg")
    Assert.isTrue(persistentXdg ~= nil and persistentXdg ~= "", "the seeding run must record its data home")
    Assert.isTrue(dirExists(persistentXdg), "the seeding run's private root must survive between runs")
    writeFile(persistentXdg .. "/persistent-sentinel", "do not delete")

    local fresh = root .. "/run-fresh"
    local _, _, freshStatus = runTestCommand(
      root,
      fakeLoveDir,
      "--rom-source " .. shellQuote(source) .. " --fresh --filter field_dialogue_test",
      { recordDir = fresh, runTag = "fresh" }
    )
    Assert.equal(
      exitStatus(freshStatus),
      "0",
      "the cold rerun must succeed: " .. tostring(readFile(fresh .. "/command.log"))
    )

    local freshXdg = fieldOf(fresh .. "/serial.txt", "xdg")
    Assert.isTrue(freshXdg ~= nil and freshXdg ~= "", "the cold rerun must record its data home")
    Assert.isTrue(freshXdg ~= persistentXdg, "the cold rerun must use a new temporary root, not the persistent cache")
    Assert.equal(
      readFile(persistentXdg .. "/persistent-sentinel"),
      "do not delete",
      "the cold rerun must leave persistent artifacts unchanged"
    )
    Assert.isFalse(dirExists(freshXdg), "only the owned temporary root is removed after the run")
    Assert.isTrue(dirExists(persistentXdg), "the persistent cache survives the cold rerun")

    local invocations = preparationInvocations(fresh)
    Assert.isTrue(
      countImports(invocations, source) >= 1,
      "a cold rerun performs a real import even when the persistent cache is ready"
    )
  end)
end

-- One direct plan child with worker identity sanitized. The real child exit
-- status travels through a status file; plan fields are parsed only after
-- exit zero, never inferred from a plan line the wrapper happened to print.
local function runPlanChild(root, name, args)
  local logFile = root .. "/" .. name .. ".log"
  local statusFile = root .. "/" .. name .. ".status"
  local command = table.concat({
    SANITIZE_ENV,
    shellQuote(realLove()) .. " app/ --test " .. args .. " >" .. shellQuote(logFile) .. " 2>&1;",
    "echo $? > " .. shellQuote(statusFile) .. ";",
  }, " ")
  local handle = popen(command)
  local _ = handle:read("*a")
  handle:close()
  return exitStatus(statusFile), readFile(logFile) or ""
end

local function parsePlanFields(output)
  local prepare, jobs, requires = nil, nil, {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "prepare" then
      prepare = value
    elseif key == "jobs" then
      jobs = value
    elseif key == "require" then
      requires[#requires + 1] = value
    end
  end
  return prepare, jobs, requires
end

-- The machine-readable plan scopes preparation to the actual selection: a
-- cache-backed focus using the historical cache capability prepares the
-- complete scope it is granted from, while a narrow requirement-free focus
-- reports no scope and no requirements. Both children run sanitized, so the
-- scenario holds under parallel workers as well as serially.
function T.a_legacy_cache_backed_focus_prepares_the_complete_scope_it_claims()
  withTempDirectory(function(root)
    local parentWorker = os.getenv("PORTEMON_TEST_WORKER")

    local cacheStatus, cacheOutput = runPlanChild(root, "cache-plan", "--plan --filter field_dialogue_test")
    Assert.equal(cacheStatus, "0", "the cache-backed plan child must exit zero, got: " .. cacheOutput)
    local prepare, jobs, requires = parsePlanFields(cacheOutput)
    -- A nested plan call that dies under parallel load prints no prepare line;
    -- surface its captured output so the failure names the nested cause.
    local planEvidence = "nested plan output: [" .. cacheOutput:gsub("\n", " | ") .. "]"
    Assert.equal(prepare, "complete", "a historical-cache focus prepares the complete scope; " .. planEvidence)
    Assert.isTrue(#requires >= 1, "a cache-backed focus must name its requirements")
    local hasComplete = false
    for _, requirement in ipairs(requires) do
      Assert.isTrue(requirement ~= nil and requirement ~= "", "every requirement names a closed request")
      if requirement == "complete" then
        hasComplete = true
      end
    end
    Assert.isTrue(hasComplete, "a historical-cache focus explicitly requires the complete corpus")
    Assert.isTrue(
      tostring(jobs):match("^[1-9][0-9]*$") ~= nil,
      "the plan still answers a positive worker count, got: " .. tostring(jobs)
    )

    local narrowStatus, narrowOutput =
      runPlanChild(root, "narrow-plan", "--plan --filter the_plan_mode_is_part_of_the_command_surface")
    Assert.equal(narrowStatus, "0", "the requirement-free plan child must exit zero, got: " .. narrowOutput)
    local narrowPrepare, _, narrowRequires = parsePlanFields(narrowOutput)
    Assert.equal(narrowPrepare, "none", "a requirement-free focus prepares nothing")
    Assert.equal(#narrowRequires, 0, "a requirement-free focus names no requirements")

    Assert.equal(
      os.getenv("PORTEMON_TEST_WORKER"),
      parentWorker,
      "the parent worker identity is unchanged by its sanitized children"
    )
  end)
end

-- A plain run with no private selection never prepares the product cache:
-- with preparation requested but no usable source, no ROM preparation is
-- invoked at all and the inherited product root is left untouched.
function T.a_plain_run_without_a_selection_never_prepares_the_product_root()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    writeProductSentinel("product sentinel")

    local ok, err = pcall(function()
      local recordDir, logFile, statusFile =
        runTestCommand(root, fakeLoveDir, "--filter field_dialogue_test", { runTag = "plain" })
      Assert.equal(
        exitStatus(statusFile),
        "0",
        "optional ROM evidence skips without failing: " .. tostring(readFile(logFile))
      )
      Assert.equal(#preparationInvocations(recordDir), 0, "no private selection means no ROM preparation of any root")
      Assert.equal(readProductSentinel(), "product sentinel", "the product root must stay untouched")
    end)

    removeProductSentinel()
    if not ok then
      error(err, 0)
    end
  end)
end

-- A malformed or unsupported private selection is rejected before anything
-- runs: its values are never used as paths, and nothing falls back to
-- preparing the product cache.
function T.a_malformed_private_selection_is_rejected_without_product_fallback()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local selectionDir = root .. "/cache/portemon/rom-tests"
    mkdir(selectionDir)
    writeFile(selectionDir .. "/selected-rom", "version=bogus-version\nrom_sha1=not-a-hash\n")
    writeProductSentinel("product sentinel")

    local ok, err = pcall(function()
      local recordDir, _, statusFile =
        runTestCommand(root, fakeLoveDir, "--filter field_dialogue_test", { runTag = "stale" })
      Assert.equal(exitStatus(statusFile), "0", "a stale selection degrades to skips, not to failure")
      Assert.equal(#preparationInvocations(recordDir), 0, "a rejected selection must trigger no ROM preparation")
      for _, name in ipairs(listFiles(recordDir, "")) do
        local content = readFile(recordDir .. "/" .. name) or ""
        Assert.isNil(
          content:find("bogus-version", 1, true),
          "rejected selection values must never reach an invocation: " .. name
        )
      end
      Assert.equal(readProductSentinel(), "product sentinel", "the product root must stay untouched")
    end)

    removeProductSentinel()
    if not ok then
      error(err, 0)
    end
  end)
end

-- Two invocations selecting the same source serialize their mutation: their
-- preparation windows never overlap, while different sources proceed
-- independently and both succeed.
function T.concurrent_runs_for_one_source_serialize_their_mutation()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for the lock run")
    local recordDir = root .. "/records"
    mkdir(recordDir)

    local testArgs = "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test"
    local command = table.concat({
      SANITIZE_ENV,
      "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
      "export FAKE_REAL_LOVE=" .. shellQuote(realLove()) .. ";",
      "export FAKE_ISOLATION_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
      "export XDG_CACHE_HOME=" .. shellQuote(root .. "/cache") .. ";",
      "export FAKE_SLOW_PREPARATION=4;",
      "( export FAKE_RUN_TAG=first; scripts/test.sh "
        .. testArgs
        .. " >"
        .. shellQuote(recordDir .. "/a.log")
        .. " 2>&1; echo $? > "
        .. shellQuote(recordDir .. "/a.status")
        .. " ) &",
      "( export FAKE_RUN_TAG=second; scripts/test.sh "
        .. testArgs
        .. " >"
        .. shellQuote(recordDir .. "/b.log")
        .. " 2>&1; echo $? > "
        .. shellQuote(recordDir .. "/b.status")
        .. " ) &",
      "wait;",
    }, " ")
    local handle = popen(command)
    local _ = handle:read("*a")
    handle:close()

    waitUntil(600, 0.1, "both concurrent runs to finish", function()
      return fileExists(recordDir .. "/a.status") and fileExists(recordDir .. "/b.status")
    end)
    Assert.equal(exitStatus(recordDir .. "/a.status"), "0", "the first run must succeed")
    Assert.equal(exitStatus(recordDir .. "/b.status"), "0", "the second run must succeed")

    -- Only mutating invocations hold the per-ROM lock; source probes are
    -- lock-exempt validation that creates no cache state, so concurrent
    -- probes may overlap while mutation stays serialized.
    local windows = {}
    for _, invocation in ipairs(preparationInvocations(recordDir)) do
      local argv = invocation.argv or ""
      local mutates = argv:find("--prepare-cache", 1, true) ~= nil
        or argv:find("--import-rom", 1, true) ~= nil
        or argv:find("--build-cache", 1, true) ~= nil
      if mutates and invocation.start ~= nil and invocation.finish ~= nil then
        windows[#windows + 1] = invocation
      end
    end
    Assert.isTrue(#windows >= 1, "the concurrent runs must prepare at least once")
    for first = 1, #windows do
      for second = first + 1, #windows do
        local a, b = windows[first], windows[second]
        Assert.isFalse(a.start < b.finish and b.start < a.finish, "same-source preparation windows must not overlap")
      end
    end
  end)
end

-- Cancelling a running invocation reaps every owned child before its roots
-- are released: workers observe termination, no worker stays alive, the
-- persistent private root survives the cancellation, and source and product
-- files remain untouched while a follow-up run proceeds normally.
function T.cancellation_reaps_children_before_releasing_roots_and_keeps_sources_intact(context)
  local serialFallback = false
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for the cancellation run")
    local before = trim((function()
      local handle = popen("sha1sum -- " .. shellQuote(source))
      local out = handle:read("*l") or ""
      handle:close()
      return out
    end)())
    writeProductSentinel("product sentinel")

    local ok, err = pcall(function()
      local recordDir = root .. "/records"
      mkdir(recordDir)
      local launchCommand = table.concat({
        SANITIZE_ENV,
        "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
        "export FAKE_REAL_LOVE=" .. shellQuote(realLove()) .. ";",
        "export FAKE_ISOLATION_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
        "export FAKE_RUN_TAG=cancelled;",
        "export XDG_CACHE_HOME=" .. shellQuote(root .. "/cache") .. ";",
        "export FAKE_SLOW_WORKER=60;",
        "scripts/test.sh --rom-source "
          .. shellQuote(source)
          .. " >"
          .. shellQuote(recordDir .. "/command.log")
          .. " 2>&1 &",
        "parent_pid=$!;",
        "echo $parent_pid;",
        "wait $parent_pid;",
        "echo $? > " .. shellQuote(recordDir .. "/status") .. ";",
      }, " ")
      local handle = popen(launchCommand)
      local parentPid = tonumber(trim(handle:read("*l") or ""))

      -- Releases the launched parent tree without asserting: used when the
      -- selection ran serially and worker cancellation is unobservable.
      local function abandon()
        if parentPid ~= nil then
          os.execute("kill -9 " .. tostring(parentPid) .. " 2>/dev/null")
          for worker = 1, 8 do
            local pid = trim(readFile(recordDir .. "/worker-" .. worker .. ".pid") or "")
            if pid ~= "" then
              os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
          end
        end
        local _ = handle:read("*a")
        handle:close()
      end

      if parentPid == nil then
        local _ = handle:read("*a")
        handle:close()
        error("expected the launched parent command's pid", 0)
      end

      waitUntil(600, 0.1, "a worker to start", function()
        for worker = 1, 8 do
          if fileExists(recordDir .. "/worker-" .. worker .. ".live") then
            return true
          end
        end
        if fileExists(recordDir .. "/serial.txt") then
          return true
        end
        return false
      end)

      if fileExists(recordDir .. "/serial.txt") then
        abandon()
        serialFallback = true
        return
      end

      local dataHome = fieldOf(recordDir .. "/worker-1.txt", "xdg")
      Assert.isTrue(dataHome ~= nil and dataHome ~= "", "the worker must record its data home")
      Assert.isTrue(dirExists(dataHome), "the data home must exist while workers are live")

      os.execute("kill -TERM " .. tostring(parentPid))
      waitUntil(600, 0.1, "the parent command to exit after cancellation", function()
        return fileExists(recordDir .. "/status")
      end)

      Assert.equal(
        exitStatus(recordDir .. "/status"),
        "143",
        "termination must exit 143: " .. tostring(readFile(recordDir .. "/command.log"))
      )
      for worker = 1, 8 do
        if fileExists(recordDir .. "/worker-" .. worker .. ".pid") then
          Assert.isTrue(
            fileExists(recordDir .. "/worker-" .. worker .. ".terminated"),
            "worker " .. worker .. " must observe termination"
          )
          Assert.isFalse(
            fileExists(recordDir .. "/worker-" .. worker .. ".live"),
            "worker " .. worker .. " must no longer be live after cancellation"
          )
          Assert.equal(
            trim(readFile(recordDir .. "/worker-" .. worker .. ".xdg-during-term") or ""),
            "present",
            "worker " .. worker .. " must observe its data home while terminating"
          )
          local pid = trim(readFile(recordDir .. "/worker-" .. worker .. ".pid") or "")
          local liveness = popen("kill -0 " .. pid .. " 2>/dev/null && echo alive || echo dead")
          local state = trim(liveness:read("*l") or "")
          liveness:close()
          Assert.equal(state, "dead", "worker " .. worker .. " must be reaped after cancellation")
        end
      end
      Assert.isTrue(dirExists(dataHome), "the persistent private root survives cancellation")

      local afterHandle = popen("sha1sum -- " .. shellQuote(source))
      local after = trim(afterHandle:read("*l") or "")
      afterHandle:close()
      Assert.equal(after, before, "the source file must remain untouched")
      Assert.equal(readProductSentinel(), "product sentinel", "the product root must stay untouched")

      local followDir = root .. "/followup"
      local _, _, followStatus = runTestCommand(
        root,
        fakeLoveDir,
        "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test",
        { recordDir = followDir, runTag = "followup" }
      )
      Assert.equal(exitStatus(followStatus), "0", "a follow-up run must proceed once cancellation released the root")

      local _ = handle:read("*a")
      handle:close()
    end)

    removeProductSentinel()
    if serialFallback then
      return
    end
    if not ok then
      error(err, 0)
    end
  end)
  if serialFallback then
    context:skip("the unfocused selection ran serially, so worker cancellation is unobservable here")
  end
end

-- Readiness always comes from the common builder under the working-tree
-- development identity: a repeat run against a ready private root must still
-- invoke scoped preparation (reused scope text alone never authorizes the
-- run), and every such invocation tests the development identity so an
-- uncommitted producer edit invalidates the previous preparation.
function T.repeat_runs_reprepare_through_the_common_builder_under_the_development_identity()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for builder-issued preparation")
    local args = "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test"

    local seed = root .. "/seed"
    local _, _, seedStatus = runTestCommand(root, fakeLoveDir, args, { recordDir = seed, runTag = "seed" })
    Assert.equal(exitStatus(seedStatus), "0", "the seeding run must succeed")

    local repeatDir = root .. "/repeat"
    local _, repeatLog, repeatStatus =
      runTestCommand(root, fakeLoveDir, args, { recordDir = repeatDir, runTag = "repeat" })
    Assert.equal(exitStatus(repeatStatus), "0", "the repeat run must succeed: " .. tostring(readFile(repeatLog)))

    local prepared = {}
    for _, invocation in ipairs(preparationInvocations(repeatDir)) do
      if (invocation.argv or ""):find("--prepare-cache", 1, true) ~= nil then
        prepared[#prepared + 1] = invocation
      end
    end
    Assert.isTrue(
      #prepared >= 1,
      "a repeat run must re-establish readiness through the common builder, not reused scope text"
    )
    for _, invocation in ipairs(prepared) do
      Assert.isTrue(
        (invocation.argv or ""):find("--dev", 1, true) ~= nil,
        "builder preparation tests the working-tree development identity, got: " .. tostring(invocation.argv)
      )
      Assert.isTrue(
        (invocation.argv or ""):find("--preparation-record", 1, true) ~= nil,
        "builder preparation issues the invocation receipt, got: " .. tostring(invocation.argv)
      )
    end
  end)
end

-- The generation half of the same contract, pinned without any shell: with
-- the release counter held fixed, changing one producer byte through a
-- controlled checkout backend moves the development generation while the
-- release generation stays put.
function T.a_working_tree_producer_edit_moves_only_the_development_generation()
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local romSha1 = string.rep("c", 40)

  local function backendFor(bytes)
    return {
      list = function(_)
        return { "producer.lua" }
      end,
      read = function(_, _)
        return bytes
      end,
      getInfo = function(_)
        return { type = "file" }
      end,
    }
  end

  local before = ProducerFingerprint.compute(backendFor("producer bytes v1"), "producer")
  local after = ProducerFingerprint.compute(backendFor("producer bytes v2"), "producer")
  Assert.isTrue(before ~= after, "an uncommitted producer edit must change the development fingerprint")

  local function developmentGeneration(producerId)
    local identity = DerivedCacheState.currentForSelection({
      versionId = "heartgold",
      romSha1 = romSha1,
      producerId = producerId,
      developmentRepositoryRoot = "/checkout",
    })
    return assert(identity.generationId, "the selection identity carries its generation")
  end
  Assert.isTrue(
    developmentGeneration(before) ~= developmentGeneration(after),
    "an uncommitted producer edit must invalidate test preparation"
  )

  local function releaseGeneration()
    local identity = DerivedCacheState.currentForSelection({
      versionId = "heartgold",
      romSha1 = romSha1,
      producerId = "r7",
    })
    return assert(identity.generationId, "the release identity carries its generation")
  end
  Assert.equal(releaseGeneration(), releaseGeneration(), "the release counter stays fixed across working-tree edits")
end

-- Only the common builder can produce ready evidence: once the persistent
-- scope text survives a seeding run, a builder failure on the next run must
-- still fail the invocation, start no test child, and leave no successful
-- receipt behind.
function T.a_failed_builder_preparation_stops_the_run_without_fabricating_a_receipt()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local source = root .. "/fixture.nds"
    writeFile(source, "fixture rom bytes for builder failure")
    local args = "--rom-source " .. shellQuote(source) .. " --filter field_dialogue_test"

    local seed = root .. "/seed"
    local _, _, seedStatus = runTestCommand(root, fakeLoveDir, args, { recordDir = seed, runTag = "seed" })
    Assert.equal(exitStatus(seedStatus), "0", "the seeding run must succeed")

    local failed = root .. "/failed"
    local _, failedLog, failedStatus =
      runTestCommand(root, fakeLoveDir, args, { recordDir = failed, runTag = "failed", FAKE_PREPARATION_STATUS = "1" })
    Assert.isTrue(
      exitStatus(failedStatus) ~= "0",
      "a failed builder preparation must fail the run even when scope text survives: " .. tostring(readFile(failedLog))
    )
    Assert.isFalse(fileExists(failed .. "/serial.txt"), "no test child starts after a failed preparation")

    local shaHandle = popen("sha1sum -- " .. shellQuote(source))
    local sha = trim((shaHandle:read("*l") or ""):match("^%S+") or "")
    shaHandle:close()
    Assert.equal(#sha, 40, "the fixture source has a content identity")
    Assert.isFalse(
      fileExists(root .. "/cache/portemon/rom-tests/" .. sha .. "/data-home/preparation.lua"),
      "a failed preparation leaves no successful receipt behind"
    )
  end)
end

-- A failed scoped preparation for another valid raw input authorizes
-- nothing: the run exits nonzero with no test child, the previous
-- successful selection stays published, the valid raw import remains
-- reusable, and a retry reuses it while minting a fresh proof.
function T.a_failed_scoped_preparation_keeps_the_previous_selection()
  withTempDirectory(function(root)
    local fakeLoveDir = installFakeLove(root)
    local first = root .. "/first.nds"
    local second = root .. "/second.nds"
    writeFile(first, "first valid raw input bytes")
    writeFile(second, "second valid raw input bytes")
    local testRoot = root .. "/cache/portemon/rom-tests"
    local selectionFile = testRoot .. "/selected-rom"
    local firstArgs = "--rom-source " .. shellQuote(first) .. " --filter field_dialogue_test"
    local secondArgs = "--rom-source " .. shellQuote(second) .. " --filter field_dialogue_test"

    local seed = root .. "/seed"
    local _, _, seedStatus = runTestCommand(root, fakeLoveDir, firstArgs, { recordDir = seed, runTag = "seed" })
    Assert.equal(exitStatus(seedStatus), "0", "the seeding run must succeed")
    local firstSha = shaOf(first)
    local published = "version=heartgold\nrom_sha1=" .. firstSha .. "\n"
    Assert.equal(readFile(selectionFile), published, "the seed publishes the first selection")

    local failed = root .. "/failed"
    local _, failedLog, failedStatus = runTestCommand(
      root,
      fakeLoveDir,
      secondArgs,
      { recordDir = failed, runTag = "failed", FAKE_PREPARATION_STATUS = "1" }
    )
    Assert.isTrue(
      exitStatus(failedStatus) ~= "0",
      "a failed scoped preparation must fail the run: " .. tostring(readFile(failedLog))
    )
    Assert.isFalse(fileExists(failed .. "/serial.txt"), "no test child starts after a failed preparation")
    Assert.equal(
      readFile(selectionFile),
      published,
      "a failed scope must not replace the previous successful selection"
    )

    local secondSha = shaOf(second)
    Assert.isTrue(
      fileExists(testRoot .. "/" .. secondSha .. "/rom-ready"),
      "the successfully imported new raw data remains reusable"
    )

    local retry = root .. "/retry"
    local _, retryLog, retryStatus =
      runTestCommand(root, fakeLoveDir, secondArgs, { recordDir = retry, runTag = "retry" })
    Assert.equal(exitStatus(retryStatus), "0", "the retry must succeed: " .. tostring(readFile(retryLog)))
    Assert.isTrue(fileExists(retry .. "/serial.txt"), "the retry runs its test child")
    Assert.equal(
      readFile(selectionFile),
      "version=heartgold\nrom_sha1=" .. secondSha .. "\n",
      "the retry publishes the second selection once its scope succeeds"
    )

    local scoped = {}
    for _, invocation in ipairs(preparationInvocations(failed)) do
      scoped[#scoped + 1] = invocation
    end
    for _, invocation in ipairs(preparationInvocations(retry)) do
      scoped[#scoped + 1] = invocation
    end
    local imports = 0
    for _, invocation in ipairs(scoped) do
      local argv = invocation.argv or ""
      if argv:find("--import-rom", 1, true) ~= nil or argv:find("--build-cache", 1, true) ~= nil then
        imports = imports + 1
      end
    end
    Assert.equal(imports, 1, "the retry reuses the raw import and mints only a fresh proof")
  end)
end

-- An ordinary first seed into an empty private root imports raw data only
-- and prepares exactly the selected closure: one import-only invocation,
-- never an exhaustive build; a requirement-free selection prepares nothing,
-- while derived selections prepare only their exact requirement union
-- through an invocation-owned receipt under the private root.
function T.first_seed_imports_once_and_prepares_only_the_selected_scope()
  local cases = {
    {
      label = "requirement-free",
      args = "--filter the_plan_mode_is_part_of_the_command_surface",
      requires = {},
    },
    {
      label = "narrow-derived",
      args = "--filter field_dialogue_test",
      requires = { "complete", "field-core" },
    },
    {
      label = "complete",
      args = "--slow --filter derived_cache_corpus_test",
      requires = { "complete" },
    },
  }
  for _, case in ipairs(cases) do
    withTempDirectory(function(root)
      local fakeLoveDir = installFakeLove(root)
      local source = root .. "/fixture.nds"
      writeFile(source, "fixture rom bytes for the " .. case.label .. " first seed")
      local recordDir = root .. "/records"

      local _, logFile, statusFile = runTestCommand(
        root,
        fakeLoveDir,
        "--rom-source " .. shellQuote(source) .. " " .. case.args,
        { recordDir = recordDir, runTag = "first" }
      )
      Assert.equal(
        exitStatus(statusFile),
        "0",
        "the " .. case.label .. " first seed must succeed: " .. tostring(readFile(logFile))
      )

      local invocations = preparationInvocations(recordDir)
      Assert.equal(
        countImports(invocations, "--import-rom"),
        1,
        "the " .. case.label .. " first seed must import raw data exactly once"
      )
      Assert.equal(
        countImports(invocations, "--build-cache"),
        0,
        "the " .. case.label .. " first seed must never hide an exhaustive build"
      )

      local testRoot = root .. "/cache/portemon/rom-tests"
      local dataHome = testRoot .. "/" .. shaOf(source) .. "/data-home"
      local prepared = invocationsWith(invocations, "--prepare-cache")
      if #case.requires == 0 then
        Assert.equal(#prepared, 0, "a requirement-free first seed prepares nothing")
        for _, invocation in ipairs(invocations) do
          Assert.isNil(
            (invocation.argv or ""):find("--preparation-record", 1, true),
            "a requirement-free first seed exports no preparation proof"
          )
        end
      else
        Assert.equal(#prepared, 1, "the " .. case.label .. " first seed must prepare its exact scope once")
        local argv = prepared[1].argv or ""
        assertRequireUnion(argv, case.requires, "the " .. case.label .. " preparation requests only its exact union")
        contains(argv, "--dev", "scoped preparation tests the working-tree development identity")
        contains(argv, "--preparation-record " .. testRoot, "the invocation receipt stays under the private root")
      end
      for _, invocation in ipairs(invocationsWith(invocations, "--import-rom")) do
        Assert.equal(invocation.xdg, dataHome, "the raw import runs inside the canonical private root")
      end
      for _, invocation in ipairs(prepared) do
        Assert.equal(invocation.xdg, dataHome, "scoped preparation runs inside the canonical private root")
      end
      Assert.isTrue(
        fileExists(recordDir .. "/serial.txt"),
        "the " .. case.label .. " first seed still executes its test child"
      )
    end)
  end
end

-- Direct entrypoint children (bypassing the shell wrapper) for pre-setup
-- authorization: the child shares this process's save directory, so a crafted
-- record either authorizes on its own source merits or fails before setup.
local function writePreparationRecord(path, dataHome, versionId, romSha1)
  writeFile(
    path,
    table.concat({
      "return {",
      '  schema = "g4-test-preparation-v1",',
      "  data_home = " .. string.format("%q", dataHome) .. ",",
      "  source = { version_id = "
        .. string.format("%q", versionId)
        .. ", rom_sha1 = "
        .. string.format("%q", romSha1)
        .. " },",
      "  preparation = { version_id = " .. string.format("%q", versionId) .. ", rom_sha1 = " .. string.format(
        "%q",
        romSha1
      ) .. ', requested = { "map:7", }, requested_ready = true, complete = false },',
      "}",
      "",
    }, "\n")
  )
end

local function runEntryChild(root, name, args, exports)
  local logFile = root .. "/" .. name .. ".log"
  local statusFile = root .. "/" .. name .. ".status"
  local parts = { SANITIZE_ENV }
  for _, export in ipairs(exports or {}) do
    parts[#parts + 1] = export .. " "
  end
  parts[#parts + 1] = shellQuote(realLove()) .. " app/ --test " .. args .. " >" .. shellQuote(logFile) .. " 2>&1;"
  parts[#parts + 1] = "echo $? > " .. shellQuote(statusFile) .. ";"
  local handle = popen(table.concat(parts, " "))
  local _ = handle:read("*a")
  handle:close()
  return exitStatus(statusFile), readFile(logFile) or ""
end

local UNIT_FOCUS = "--filter the_plan_mode_is_part_of_the_command_surface"

-- Strict revision helpers for the builder-issued receipt: the exact field
-- shape the entrypoint authorizes, with per-test overrides.
local function writeStrictPreparationRecord(path, overrides)
  local fields = {
    schema = "g4-test-preparation-v2",
    saveDirectory = love.filesystem.getSaveDirectory(),
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = "g4:heartgold:" .. string.rep("a", 40) .. ":d" .. string.rep("1", 64) .. ":a1:s1",
    requested = { "bootstrap" },
    requestedReady = true,
    complete = false,
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  local parts = { "return {" }
  parts[#parts + 1] = '  schema = "' .. fields.schema .. '",'
  parts[#parts + 1] = '  saveDirectory = "' .. fields.saveDirectory .. '",'
  parts[#parts + 1] = '  versionId = "' .. fields.versionId .. '",'
  parts[#parts + 1] = '  romSha1 = "' .. fields.romSha1 .. '",'
  parts[#parts + 1] = '  generationId = "' .. fields.generationId .. '",'
  local requested = {}
  for _, requirement in ipairs(fields.requested) do
    requested[#requested + 1] = string.format("%q", requirement)
  end
  parts[#parts + 1] = "  requested = { " .. table.concat(requested, ", ") .. " },"
  parts[#parts + 1] = "  requestedReady = " .. tostring(fields.requestedReady) .. ","
  parts[#parts + 1] = "  complete = " .. tostring(fields.complete) .. ","
  parts[#parts + 1] = "}"
  writeFile(path, table.concat(parts, "\n") .. "\n")
end

-- A receipt for a narrower closure never authorizes a wider selection: the
-- dialogue focus requires its field core, so a bootstrap-only receipt fails
-- before any setup without needing a dump to prove the mismatch.
function T.a_preparation_record_for_a_narrower_closure_fails_before_any_setup()
  withTempDirectory(function(root)
    local receipt = root .. "/narrow-preparation.lua"
    writeStrictPreparationRecord(receipt, { requested = { "bootstrap" } })

    local status, output = runEntryChild(root, "serial-narrow", "--filter field_dialogue_test", {
      "export PORTEMON_TEST_PREPARATION=" .. shellQuote(receipt) .. ";",
    })
    Assert.isTrue(status ~= "0", "a narrower receipt must fail before setup, got: " .. output)
    Assert.isNil(
      output:find("1 passed", 1, true),
      "no test may execute against a narrower preparation, got: " .. output
    )
    contains(output, "field-core", "the failure names the uncovered requirement")
  end)
end

-- A strict receipt without a generation proves nothing: the empty token is
-- rejected during record validation, before any setup.
function T.a_strict_preparation_record_without_a_generation_fails_before_any_setup()
  withTempDirectory(function(root)
    local receipt = root .. "/generationless-preparation.lua"
    writeStrictPreparationRecord(receipt, { generationId = "" })

    local status, output = runEntryChild(root, "serial-generationless", UNIT_FOCUS, {
      "export PORTEMON_TEST_PREPARATION=" .. shellQuote(receipt) .. ";",
    })
    Assert.isTrue(status ~= "0", "a generationless receipt must fail before setup, got: " .. output)
    Assert.isNil(
      output:find("1 passed", 1, true),
      "no test may execute against a generationless preparation, got: " .. output
    )
  end)
end

-- A well-formed record for another source must fail before mutable setup,
-- never downgrade into skips against product data.
function T.a_preparation_record_for_another_source_fails_before_any_setup()
  withTempDirectory(function(root)
    local saveDirectory = love.filesystem.getSaveDirectory()
    Assert.isTrue(saveDirectory ~= nil and saveDirectory ~= "", "the child shares this process's save directory")
    local receipt = root .. "/foreign-preparation.lua"
    writePreparationRecord(receipt, saveDirectory, "heartgold", string.rep("f", 40))

    local status, output = runEntryChild(root, "serial-foreign", UNIT_FOCUS, {
      "export PORTEMON_TEST_PREPARATION=" .. shellQuote(receipt) .. ";",
    })
    Assert.isTrue(status ~= "0", "a record for another source must fail before setup, got: " .. output)
    Assert.isNil(output:find("1 passed", 1, true), "no test may execute against a foreign preparation, got: " .. output)
  end)
end

-- The parallel worker entry path applies the same authorization: a foreign
-- record fails the worker before it runs or reports anything.
function T.a_parallel_worker_rejects_a_preparation_record_for_another_source()
  withTempDirectory(function(root)
    local saveDirectory = love.filesystem.getSaveDirectory()
    Assert.isTrue(saveDirectory ~= nil and saveDirectory ~= "", "the child shares this process's save directory")
    local receipt = root .. "/foreign-preparation.lua"
    writePreparationRecord(receipt, saveDirectory, "heartgold", string.rep("f", 40))
    local runDir = root .. "/run-dir"
    mkdir(runDir)

    local status, output = runEntryChild(root, "worker-foreign", UNIT_FOCUS, {
      "export PORTEMON_TEST_PREPARATION=" .. shellQuote(receipt) .. ";",
      "export PORTEMON_TEST_RUN_DIR=" .. shellQuote(runDir) .. ";",
      "export PORTEMON_TEST_WORKERS=1;",
      "export PORTEMON_TEST_WORKER=1;",
    })
    Assert.isTrue(status ~= "0", "a worker must reject a record for another source, got: " .. output)
  end)
end

-- A record for another data home already fails before setup today; this pins
-- the behavior while source authorization is repaired beside it.
function T.a_preparation_record_for_another_data_home_fails_before_any_setup()
  withTempDirectory(function(root)
    local receipt = root .. "/elsewhere-preparation.lua"
    writePreparationRecord(receipt, root .. "/elsewhere", "heartgold", string.rep("e", 40))

    local status, output = runEntryChild(root, "serial-elsewhere", UNIT_FOCUS, {
      "export PORTEMON_TEST_PREPARATION=" .. shellQuote(receipt) .. ";",
    })
    Assert.isTrue(status ~= "0", "a record for another data home must fail before setup, got: " .. output)
  end)
end

-- A unit-only focus without any preparation record keeps running: absent ROM
-- evidence is only fatal when a selected scope was promised one.
function T.a_unit_focus_without_any_preparation_record_stays_green()
  withTempDirectory(function(root)
    local status, output = runEntryChild(root, "serial-plain", UNIT_FOCUS, {})
    Assert.equal(status, "0", "a unit focus without preparation must stay green, got: " .. output)
  end)
end

-- The exhaustive corpus check consumes a proven complete preparation instead
-- of publishing one: it declares the complete capability with the complete
-- closure and never prepares anything itself.
function T.the_exhaustive_corpus_suite_consumes_only_a_proven_complete_preparation()
  local suite = require("tests.rom.derived_cache_corpus_test")
  local metadata = assert(suite.metadata, "the corpus suite declares its contract")
  local found = false
  for _, name in ipairs(metadata.capabilities or {}) do
    if name == "complete_derived_cache" then
      found = true
    end
  end
  Assert.isTrue(found, "the read-only corpus check requires the proven complete corpus")
  Assert.deepEqual(
    metadata.derivedAssets,
    { "complete" },
    "the corpus check authorizes from the complete closure instead of preparing it"
  )
end

-- Producer census suites keep their raw-dump contract: they claim no prepared
-- closure, so selection never prepares the shared cache on their behalf.
function T.producer_census_suites_keep_a_raw_dump_contract_without_claiming_a_prepared_closure()
  local suite = require("tests.rom.cache_milestone_test")
  local metadata = assert(suite.metadata, "the census suite declares its contract")
  for _, name in ipairs(metadata.capabilities or {}) do
    Assert.isTrue(
      name ~= "derived_cache" and name ~= "derived_assets" and name ~= "complete_derived_cache",
      "a self-driven census must not claim a prepared closure, got: " .. name
    )
  end
  local derivedAssets = metadata.derivedAssets or {}
  Assert.deepEqual(derivedAssets, {}, "a self-driven census prepares no shared closure")
end

-- The isolation mechanism the writer fixtures rely on: two cache handles for
-- one version over separate backends never observe each other's writes, so a
-- private writer backend cannot rewrite the shared fixture.
function T.private_writer_backends_never_leak_into_the_shared_fixture()
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local shared = FakeCache.new()
  local private = FakeCache.new()
  local sharedFs = CacheFs.forVersion("heartgold", shared)
  local privateFs = CacheFs.forVersion("heartgold", private)

  sharedFs:write("data/generated/probe.lua", "shared")
  privateFs:write("data/generated/probe.lua", "writer")

  Assert.equal(
    sharedFs:read("data/generated/probe.lua"),
    "shared",
    "shared readers never observe private writer output"
  )
  Assert.equal(privateFs:read("data/generated/probe.lua"), "writer", "private writers keep their own output")
end

return { tests = T }
