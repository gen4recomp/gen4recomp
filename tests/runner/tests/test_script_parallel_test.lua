-- Black-box shell-orchestration contract for `scripts/test.sh`'s parallel
-- branch. This proves worker environment ownership and cancellation
-- lifecycle that pure Lua sharding/fragment tests cannot observe, using a
-- generated fake `love` executable so no real LÖVE process, ROM dump, or
-- graphics host is required.

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

local function writeExecutable(path, content)
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
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

local function waitUntil(maxAttempts, intervalSeconds, description, predicate)
  for _ = 1, maxAttempts do
    if predicate() then
      return
    end
    os.execute("sleep " .. tostring(intervalSeconds))
  end
  error("timed out waiting for " .. description, 2)
end

-- Every command below runs a nested `scripts/test.sh`, and this suite may
-- itself be executing inside an outer parallel worker; inherited run/worker
-- identity must not leak into the nested command.
local SANITIZE_ENV =
  "unset G4RECOMP_TEST_RUN_DIR G4RECOMP_TEST_WORKERS G4RECOMP_TEST_WORKER G4RECOMP_TEST_AGGREGATE G4RECOMP_TEST_ACCEPTANCE_NAMESPACE;"

-- Shared preamble for every generated fake `love`: answers `--plan` with the
-- exact `prepare=0`/`jobs=N` records the real plan protocol requires, echoing
-- back whatever `--jobs` value scripts/test.sh forwarded, and otherwise falls
-- through to the scenario-specific worker/aggregate body appended below.
local FAKE_LOVE_PREAMBLE = [[
#!/usr/bin/env bash
set -u
is_plan=false
jobs=""
previous=""
for arg in "$@"; do
  if [ "$arg" = "--plan" ]; then
    is_plan=true
  fi
  if [ "$previous" = "--jobs" ]; then
    jobs="$arg"
  fi
  previous="$arg"
done
if [ "$is_plan" = true ]; then
  echo "prepare=0"
  echo "jobs=${jobs:-1}"
  exit 0
fi
record_dir="$FAKE_LOVE_RECORD_DIR"
]]

local NAMESPACE_FAKE_LOVE_BODY = [[
if [ -n "${G4RECOMP_TEST_AGGREGATE:-}" ]; then
  printf 'token=%s\n' "${G4RECOMP_TEST_ACCEPTANCE_NAMESPACE:-}" > "$record_dir/aggregate.txt"
  exit 0
fi
if [ -n "${G4RECOMP_TEST_WORKER:-}" ]; then
  worker="$G4RECOMP_TEST_WORKER"
  {
    printf 'token=%s\n' "${G4RECOMP_TEST_ACCEPTANCE_NAMESPACE:-}"
    printf 'xdg=%s\n' "${XDG_DATA_HOME:-}"
  } > "$record_dir/worker-$worker.txt"
  exit 0
fi
echo "fake love: unrecognized invocation" >&2
exit 1
]]

local CANCEL_FAKE_LOVE_BODY = [[
if [ -n "${G4RECOMP_TEST_AGGREGATE:-}" ]; then
  : > "$record_dir/aggregate-ran"
  exit 0
fi
if [ -n "${G4RECOMP_TEST_WORKER:-}" ]; then
  worker="$G4RECOMP_TEST_WORKER"
  run_dir="${G4RECOMP_TEST_RUN_DIR:-}"
  echo "$run_dir" > "$record_dir/worker-$worker.rundir"
  echo "$$" > "$record_dir/worker-$worker.pid"
  : > "$record_dir/worker-$worker.live"
  child=""
  term_handler() {
    if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
      echo present > "$record_dir/worker-$worker.rundir-during-term"
    else
      echo absent > "$record_dir/worker-$worker.rundir-during-term"
    fi
    : > "$record_dir/worker-$worker.terminated"
    rm -f "$record_dir/worker-$worker.live"
    if [ -n "$child" ]; then
      kill "$child" 2>/dev/null || true
    fi
    exit 143
  }
  trap term_handler TERM
  sleep 100000 &
  child=$!
  wait "$child"
  exit 0
fi
echo "fake love: unrecognized invocation" >&2
exit 1
]]

local AGGREGATE_CANCEL_FAKE_LOVE_BODY = [[
if [ -n "${G4RECOMP_TEST_AGGREGATE:-}" ]; then
  run_dir="${G4RECOMP_TEST_RUN_DIR:-}"
  echo "$run_dir" > "$record_dir/aggregate.rundir"
  echo "$$" > "$record_dir/aggregate.pid"
  echo x >> "$record_dir/aggregate.invocations"
  : > "$record_dir/aggregate.live"
  child=""
  term_handler() {
    if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
      echo present > "$record_dir/aggregate.rundir-during-term"
    else
      echo absent > "$record_dir/aggregate.rundir-during-term"
    fi
    : > "$record_dir/aggregate.terminated"
    rm -f "$record_dir/aggregate.live"
    if [ -n "$child" ]; then
      kill "$child" 2>/dev/null || true
    fi
    exit 143
  }
  trap term_handler TERM
  sleep 100000 &
  child=$!
  wait "$child"
  exit 0
fi
if [ -n "${G4RECOMP_TEST_WORKER:-}" ]; then
  worker="$G4RECOMP_TEST_WORKER"
  : > "$record_dir/worker-$worker.done"
  exit 0
fi
echo "fake love: unrecognized invocation" >&2
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

-- Worker-specific mutable save identity is unique per worker and per
-- command while every worker still reads the one shared cache/save root.
function T.parallel_worker_acceptance_tokens_are_disjoint_across_workers_and_commands()
  withTempDirectory(function(root)
    local fakeLoveDir = root .. "/bin"
    mkdir(fakeLoveDir)
    writeExecutable(fakeLoveDir .. "/love", FAKE_LOVE_PREAMBLE .. NAMESPACE_FAKE_LOVE_BODY)
    local saveDir = root .. "/save"
    mkdir(saveDir)

    local function runCommand(recordDir)
      mkdir(recordDir)
      local command = table.concat({
        SANITIZE_ENV,
        "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
        "export G4RECOMP_SAVE_DIR=" .. shellQuote(saveDir) .. ";",
        "export FAKE_LOVE_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
        "scripts/test.sh --jobs 4 >" .. shellQuote(recordDir .. "/command.log") .. " 2>&1;",
        "echo $? > " .. shellQuote(recordDir .. "/status"),
      }, " ")
      local handle = popen(command)
      local _ = handle:read("*a")
      handle:close()
    end

    local record1, record2 = root .. "/run1", root .. "/run2"
    runCommand(record1)
    runCommand(record2)

    for _, recordDir in ipairs({ record1, record2 }) do
      local status = trim(readFile(recordDir .. "/status") or "")
      Assert.equal(
        status,
        "0",
        "the command must exit successfully: " .. tostring(readFile(recordDir .. "/command.log"))
      )
    end

    local function tokensAndXdg(recordDir)
      local tokens, xdgValues = {}, {}
      for worker = 1, 4 do
        local content = assert(
          readFile(recordDir .. "/worker-" .. worker .. ".txt"),
          "worker " .. worker .. " must record its environment"
        )
        local token = content:match("token=([^\n]*)")
        local xdg = content:match("xdg=([^\n]*)")
        Assert.isTrue(token ~= nil and token ~= "", "worker " .. worker .. " must receive a private acceptance token")
        tokens[worker] = token
        xdgValues[worker] = xdg
      end
      return tokens, xdgValues
    end

    local tokens1, xdg1 = tokensAndXdg(record1)
    local tokens2, xdg2 = tokensAndXdg(record2)

    local seen = {}
    for worker, token in pairs(tokens1) do
      Assert.isNil(seen[token], "worker " .. worker .. " reused a token within the first command")
      seen[token] = worker
    end
    local seen2 = {}
    for worker, token in pairs(tokens2) do
      Assert.isNil(seen2[token], "worker " .. worker .. " reused a token within the second command")
      Assert.isNil(seen[token], "the second command reused a token from the first command")
      seen2[token] = worker
    end

    for worker = 2, 4 do
      Assert.equal(xdg1[worker], xdg1[1], "every worker of one command must share the same cache/save root")
      Assert.equal(xdg2[worker], xdg2[1], "every worker of one command must share the same cache/save root")
    end

    for _, recordDir in ipairs({ record1, record2 }) do
      local aggregate = assert(readFile(recordDir .. "/aggregate.txt"), "the aggregate process must run")
      Assert.equal(aggregate:match("token=([^\n]*)"), "", "the aggregate process must see no acceptance token")
    end
  end)
end

-- The parent test command owns cancellation of its background workers and
-- the ordering of temporary-directory cleanup relative to it.
function T.parent_term_cancellation_terminates_and_reaps_workers_before_run_dir_cleanup()
  withTempDirectory(function(root)
    local fakeLoveDir = root .. "/bin"
    mkdir(fakeLoveDir)
    writeExecutable(fakeLoveDir .. "/love", FAKE_LOVE_PREAMBLE .. CANCEL_FAKE_LOVE_BODY)
    local saveDir = root .. "/save"
    mkdir(saveDir)
    local recordDir = root .. "/records"
    mkdir(recordDir)
    local statusFile = root .. "/status"
    local logFile = root .. "/command.log"

    local launchCommand = table.concat({
      SANITIZE_ENV,
      "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
      "export G4RECOMP_SAVE_DIR=" .. shellQuote(saveDir) .. ";",
      "export FAKE_LOVE_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
      "scripts/test.sh --jobs 2 >" .. shellQuote(logFile) .. " 2>&1 &",
      "parent_pid=$!;",
      "echo $parent_pid;",
      "wait $parent_pid;",
      "echo $? > " .. shellQuote(statusFile) .. ";",
    }, " ")

    local handle = popen(launchCommand)
    local parentPid = tonumber(trim(handle:read("*l") or ""))
    Assert.notNil(parentPid, "expected the launched parent command's pid")

    local ok, err = pcall(function()
      waitUntil(200, 0.05, "both workers to start", function()
        return fileExists(recordDir .. "/worker-1.live") and fileExists(recordDir .. "/worker-2.live")
      end)

      local runDir = trim(readFile(recordDir .. "/worker-1.rundir") or "")
      Assert.isTrue(runDir ~= "", "worker must record the run directory it observed")
      Assert.isTrue(dirExists(runDir), "the run directory must exist while workers are live")

      os.execute("kill -TERM " .. tostring(parentPid))

      waitUntil(300, 0.05, "the parent command to exit after cancellation", function()
        return fileExists(statusFile)
      end)

      local status = trim(readFile(statusFile) or "")
      Assert.equal(status, "143", "SIGTERM cancellation must exit 143: " .. tostring(readFile(logFile)))

      for worker = 1, 2 do
        Assert.isTrue(
          fileExists(recordDir .. "/worker-" .. worker .. ".terminated"),
          "worker " .. worker .. " must observe termination"
        )
        Assert.isFalse(
          fileExists(recordDir .. "/worker-" .. worker .. ".live"),
          "worker " .. worker .. " must no longer be live after cancellation"
        )
        local duringTerm = trim(readFile(recordDir .. "/worker-" .. worker .. ".rundir-during-term") or "")
        Assert.equal(duringTerm, "present", "worker " .. worker .. " must observe the run directory while terminating")
        local pid = trim(readFile(recordDir .. "/worker-" .. worker .. ".pid") or "")
        Assert.isTrue(pid ~= "", "worker " .. worker .. " must have recorded its pid")
        local liveness = popen("kill -0 " .. pid .. " 2>/dev/null && echo alive || echo dead")
        local state = trim(liveness:read("*l") or "")
        liveness:close()
        Assert.equal(state, "dead", "worker " .. worker .. " process must be reaped after cancellation")
      end

      Assert.isFalse(dirExists(runDir), "the run directory must be removed only after cancellation reaps workers")
      Assert.isFalse(fileExists(recordDir .. "/aggregate-ran"), "cancellation must never reach the aggregate process")
    end)

    local _ = handle:read("*a")
    handle:close()

    -- Emergency cleanup: a pre-implementation run never signals the fake
    -- workers, so they (and their blocked `sleep` child) may still be alive;
    -- do not leak them regardless of pass/fail above.
    for worker = 1, 2 do
      local pid = readFile(recordDir .. "/worker-" .. worker .. ".pid")
      if pid then
        pid = trim(pid)
        os.execute("pkill -9 -P " .. pid .. " 2>/dev/null")
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
      end
    end

    if not ok then
      error(err, 0)
    end
  end)
end

-- The parent command owns cancellation through the final aggregate
-- process and orders temporary-directory cleanup after it.
function T.parent_term_cancellation_terminates_and_reaps_aggregate_before_run_dir_cleanup()
  withTempDirectory(function(root)
    local fakeLoveDir = root .. "/bin"
    mkdir(fakeLoveDir)
    writeExecutable(fakeLoveDir .. "/love", FAKE_LOVE_PREAMBLE .. AGGREGATE_CANCEL_FAKE_LOVE_BODY)
    local saveDir = root .. "/save"
    mkdir(saveDir)
    local recordDir = root .. "/records"
    mkdir(recordDir)
    local statusFile = root .. "/status"
    local logFile = root .. "/command.log"

    local launchCommand = table.concat({
      SANITIZE_ENV,
      "export PATH=" .. shellQuote(fakeLoveDir) .. ":$PATH;",
      "export G4RECOMP_SAVE_DIR=" .. shellQuote(saveDir) .. ";",
      "export FAKE_LOVE_RECORD_DIR=" .. shellQuote(recordDir) .. ";",
      "scripts/test.sh --jobs 2 >" .. shellQuote(logFile) .. " 2>&1 &",
      "parent_pid=$!;",
      "echo $parent_pid;",
      "wait $parent_pid;",
      "echo $? > " .. shellQuote(statusFile) .. ";",
    }, " ")

    local handle = popen(launchCommand)
    local parentPid = tonumber(trim(handle:read("*l") or ""))
    Assert.notNil(parentPid, "expected the launched parent command's pid")

    local ok, err = pcall(function()
      waitUntil(200, 0.05, "the aggregate process to start", function()
        return fileExists(recordDir .. "/aggregate.live")
      end)

      for worker = 1, 2 do
        Assert.isTrue(
          fileExists(recordDir .. "/worker-" .. worker .. ".done"),
          "worker " .. worker .. " must succeed before aggregation"
        )
      end

      local runDir = trim(readFile(recordDir .. "/aggregate.rundir") or "")
      Assert.isTrue(runDir ~= "", "the aggregate process must record the run directory it observed")
      Assert.isTrue(dirExists(runDir), "the run directory must exist while the aggregate process is live")

      os.execute("kill -TERM " .. tostring(parentPid))

      waitUntil(300, 0.05, "the parent command to exit after cancellation", function()
        return fileExists(statusFile)
      end)

      local status = trim(readFile(statusFile) or "")
      Assert.equal(status, "143", "SIGTERM cancellation must exit 143: " .. tostring(readFile(logFile)))

      Assert.isTrue(fileExists(recordDir .. "/aggregate.terminated"), "the aggregate process must observe termination")
      Assert.isFalse(
        fileExists(recordDir .. "/aggregate.live"),
        "the aggregate process must no longer be live after cancellation"
      )
      local duringTerm = trim(readFile(recordDir .. "/aggregate.rundir-during-term") or "")
      Assert.equal(duringTerm, "present", "the aggregate process must observe the run directory while terminating")
      local pid = trim(readFile(recordDir .. "/aggregate.pid") or "")
      Assert.isTrue(pid ~= "", "the aggregate process must have recorded its pid")
      local liveness = popen("kill -0 " .. pid .. " 2>/dev/null && echo alive || echo dead")
      local state = trim(liveness:read("*l") or "")
      liveness:close()
      Assert.equal(state, "dead", "the aggregate process must be reaped after cancellation")

      Assert.isFalse(
        dirExists(runDir),
        "the run directory must be removed only after cancellation reaps the aggregate process"
      )
      local invocations = readFile(recordDir .. "/aggregate.invocations") or ""
      local count = 0
      for _ in invocations:gmatch("[^\n]+") do
        count = count + 1
      end
      Assert.equal(count, 1, "cancellation must not launch an additional aggregate process")
    end)

    local _ = handle:read("*a")
    handle:close()

    -- Emergency cleanup: when the parent does not forward termination to
    -- the aggregate process, it (and its blocked `sleep` child) may still
    -- be alive; do not leak them regardless of pass/fail above.
    local aggregatePid = readFile(recordDir .. "/aggregate.pid")
    if aggregatePid then
      aggregatePid = trim(aggregatePid)
      os.execute("pkill -9 -P " .. aggregatePid .. " 2>/dev/null")
      os.execute("kill -9 " .. aggregatePid .. " 2>/dev/null")
    end
    if not fileExists(statusFile) then
      os.execute("kill -9 " .. tostring(parentPid) .. " 2>/dev/null")
    end

    if not ok then
      error(err, 0)
    end
  end)
end

return { tests = T }
