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
  "unset G4RECOMP_TEST_RUN_DIR G4RECOMP_TEST_WORKERS G4RECOMP_TEST_WORKER G4RECOMP_TEST_AGGREGATE G4RECOMP_TEST_ACCEPTANCE_NAMESPACE G4RECOMP_DERIVED_CACHE_READY G4RECOMP_REQUIRE_ROM_TESTS;"

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
  if [ "${FAKE_SLOW_PREPARATION:-0}" != "0" ]; then sleep "$FAKE_SLOW_PREPARATION"; fi
  printf 'end=%s\n' "$(date +%s.%N)" >> "$invocation"
  exit "${FAKE_PREPARATION_STATUS:-0}"
fi
if [ "$target" = "app/" ]; then
  if [ -n "${G4RECOMP_TEST_AGGREGATE:-}" ]; then
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}" > "$record_dir/aggregate.txt"
    exit 0
  fi
  if [ -n "${G4RECOMP_TEST_WORKER:-}" ]; then
    worker="$G4RECOMP_TEST_WORKER"
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
      countImports(invocations, source),
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
    Assert.equal(#invocations, 1, "identical bytes must be prepared exactly once across spellings")
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

-- The machine-readable plan scopes preparation to the actual selection: a
-- cache-backed focus reports a partial scope with its requirements, while a
-- narrow requirement-free focus reports no scope and no requirements.
function T.a_narrow_selection_prepares_a_partial_scope_not_a_complete_build()
  local loveBin = shellQuote(realLove())

  local cacheBacked = popen(loveBin .. " app/ --test --plan --filter field_dialogue_test 2>&1")
  local cacheLines = {}
  for line in cacheBacked:lines() do
    cacheLines[#cacheLines + 1] = line
  end
  cacheBacked:close()

  local prepare, jobs, requires = nil, nil, {}
  for _, line in ipairs(cacheLines) do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "prepare" then
      prepare = value
    elseif key == "jobs" then
      jobs = value
    elseif key == "require" then
      requires[#requires + 1] = value
    end
  end
  -- A nested plan call that dies under parallel load prints no prepare line;
  -- surface its captured output so the failure names the nested cause.
  local planEvidence = "nested plan output: [" .. table.concat(cacheLines, " | ") .. "]"
  Assert.isTrue(
    prepare == "none" or prepare == "assets" or prepare == "complete",
    "the plan must scope preparation, got: " .. tostring(prepare) .. "; " .. planEvidence
  )
  Assert.isTrue(
    prepare == "assets" or prepare == "complete",
    "a cache-backed focus must request preparation, got: " .. tostring(prepare)
  )
  Assert.isTrue(#requires >= 1, "a cache-backed focus must name its requirements")
  for _, requirement in ipairs(requires) do
    Assert.isTrue(requirement ~= nil and requirement ~= "", "every requirement names a closed request")
    Assert.isTrue(requirement ~= "complete", "a partial focus must not request the complete corpus")
  end
  Assert.isTrue(
    tostring(jobs):match("^[1-9][0-9]*$") ~= nil,
    "the plan still answers a positive worker count, got: " .. tostring(jobs)
  )

  local narrow = popen(loveBin .. " app/ --test --plan --filter the_plan_mode_is_part_of_the_command_surface 2>&1")
  local narrowPrepare, narrowRequires = nil, {}
  for line in narrow:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "prepare" then
      narrowPrepare = value
    elseif key == "require" then
      narrowRequires[#narrowRequires + 1] = value
    end
  end
  narrow:close()
  Assert.equal(narrowPrepare, "none", "a requirement-free focus prepares nothing")
  Assert.equal(#narrowRequires, 0, "a requirement-free focus names no requirements")
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
    local selectionDir = root .. "/cache/g4recomp/rom-tests"
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

    local windows = {}
    for _, invocation in ipairs(preparationInvocations(recordDir)) do
      if invocation.start ~= nil and invocation.finish ~= nil then
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

return { tests = T }
