-- Owns process-level test sharding policy and the disposable worker result protocol.

local LuaWriter = require("libs.codec.src.LuaWriter")

local Parallel = {}

Parallel.RUN_DIR_ENV = "G4RECOMP_TEST_RUN_DIR"
Parallel.WORKERS_ENV = "G4RECOMP_TEST_WORKERS"
Parallel.WORKER_ENV = "G4RECOMP_TEST_WORKER"
Parallel.AGGREGATE_ENV = "G4RECOMP_TEST_AGGREGATE"
Parallel.FRAGMENT_SCHEMA = "g4-test-worker-v1"

local function positiveInteger(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value > 0, what .. " must be a positive integer")
  return value
end

local function positiveIntegerString(value, what)
  assert(type(value) == "string" and value:match("^[1-9][0-9]*$") ~= nil, what .. " must be a positive integer")
  return tonumber(value)
end

local function nonNegativeInteger(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 0, what .. " must be a non-negative integer")
end

local function finiteNumber(value, what)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    what .. " must be finite"
  )
  assert(value >= 0, what .. " must be non-negative")
end

local function validateRun(run)
  assert(type(run) == "table", "fragment run must be a table")
  assert(type(run.results) == "table", "fragment run.results must be a table")
  finiteNumber(run.duration, "fragment run.duration")
  for _, field in ipairs({ "passed", "failed", "skipped", "excludedSlow" }) do
    nonNegativeInteger(run[field], "fragment run." .. field)
  end

  local byLayer = run.byLayer
  assert(type(byLayer) == "table", "fragment run.byLayer must be a table")
  local totals = { passed = 0, failed = 0, skipped = 0 }
  local resultLayers = {}
  for index, entry in ipairs(run.results) do
    assert(type(entry) == "table", "fragment result " .. index .. " must be a table")
    assert(type(entry.module) == "string", "fragment result module must be a string")
    assert(type(entry.test) == "string", "fragment result test must be a string")
    assert(
      entry.status == "pass" or entry.status == "fail" or entry.status == "skip",
      "fragment result status is invalid"
    )
    if entry.status == "pass" then
      assert(entry.message == nil or type(entry.message) == "string", "fragment result message is invalid")
    else
      assert(type(entry.message) == "string", "fragment result message is required")
    end
    assert(type(entry.layer) == "string", "fragment result layer must be a string")
    finiteNumber(entry.duration, "fragment result duration")
    local field = entry.status == "pass" and "passed" or (entry.status == "fail" and "failed" or "skipped")
    totals[field] = totals[field] + 1
    resultLayers[entry.layer] = resultLayers[entry.layer] or { passed = 0, failed = 0, skipped = 0 }
    resultLayers[entry.layer][field] = resultLayers[entry.layer][field] + 1
  end
  for _, field in ipairs({ "passed", "failed", "skipped" }) do
    assert(run[field] == totals[field], "fragment run counts do not match results")
  end
  for layer, counts in pairs(byLayer) do
    assert(type(layer) == "string" and type(counts) == "table", "fragment layer counts are invalid")
    for _, field in ipairs({ "passed", "failed", "skipped" }) do
      nonNegativeInteger(counts[field], "fragment layer count")
      assert(counts[field] == ((resultLayers[layer] or {})[field] or 0), "fragment layer counts do not match results")
    end
    finiteNumber(counts.duration, "fragment layer duration")
  end
  for layer, counts in pairs(resultLayers) do
    assert(byLayer[layer] ~= nil, "fragment result layer has no layer counts")
    for _, field in ipairs({ "passed", "failed", "skipped" }) do
      assert(byLayer[layer][field] == counts[field], "fragment layer counts do not match results")
    end
  end

  for _, field in ipairs({ "capabilities", "selectedCapabilities" }) do
    assert(type(run[field]) == "table", "fragment run." .. field .. " must be a table")
    for name, enabled in pairs(run[field]) do
      assert(type(name) == "string" and enabled == true, "fragment capability map is invalid")
    end
  end
  assert(type(run.suiteTimings) == "table", "fragment run.suiteTimings must be a table")
  for _, timing in ipairs(run.suiteTimings) do
    assert(type(timing) == "table" and type(timing.module) == "string", "fragment suite timing is invalid")
    finiteNumber(timing.total, "fragment suite timing total")
    for _, field in ipairs({ "beforeAll", "tests", "afterAll" }) do
      if timing[field] ~= nil then
        finiteNumber(timing[field], "fragment suite timing " .. field)
      end
    end
  end
  if run.versions ~= nil then
    assert(type(run.versions) == "table", "fragment run.versions must be a table")
    for _, version in ipairs(run.versions) do
      assert(type(version) == "string", "fragment version must be a string")
    end
  end
end

---@param plan TestPlan
---@param selectedSuiteCount integer
---@param processorCount integer
---@return integer
function Parallel.effectiveJobs(plan, selectedSuiteCount, processorCount)
  assert(type(plan) == "table", "job policy needs a plan")
  nonNegativeInteger(selectedSuiteCount, "selected suite count")
  positiveInteger(processorCount, "processor count")
  local count = math.max(1, selectedSuiteCount)
  if plan.list or plan.layer == "graphics" or plan.layer == "acceptance" or plan.layer == "rom" then
    return 1
  end
  if plan.jobs ~= nil then
    return math.min(positiveInteger(plan.jobs, "jobs"), count)
  end
  if plan.layer ~= nil or plan.filter ~= nil or plan.tag ~= nil then
    return 1
  end
  return math.min(4, processorCount, count)
end

---@param env table<string, string>
---@return table
function Parallel.context(env)
  assert(type(env) == "table", "parallel environment must be a table")
  local runDir = env[Parallel.RUN_DIR_ENV]
  local workers = env[Parallel.WORKERS_ENV]
  local worker = env[Parallel.WORKER_ENV]
  local aggregate = env[Parallel.AGGREGATE_ENV]
  if runDir == nil and workers == nil and worker == nil and aggregate == nil then
    return { kind = "normal" }
  end
  assert(type(runDir) == "string" and runDir ~= "" and runDir:sub(1, 1) == "/", "parallel run directory is invalid")
  local count = positiveIntegerString(workers, "parallel worker count")
  if aggregate ~= nil then
    assert(aggregate == "1" and worker == nil, "parallel aggregate environment is contradictory")
    return { kind = "aggregate", runDir = runDir, count = count }
  end
  local index = positiveIntegerString(worker, "parallel worker index")
  assert(index <= count, "parallel worker index is out of range")
  return { kind = "worker", runDir = runDir, index = index, count = count }
end

---@param entry { module: string, layer: string, path: string }
---@param ordinal integer
---@param shard { index: integer, count: integer }
---@param selectedLayer string|nil
---@return integer
function Parallel.workerFor(entry, ordinal, shard, selectedLayer)
  assert(type(entry) == "table" and type(entry.layer) == "string", "worker ownership needs a discovery entry")
  positiveInteger(ordinal, "discovery ordinal")
  assert(type(shard) == "table", "worker ownership needs a shard")
  local count = positiveInteger(shard.count, "worker count")
  assert(shard.index >= 1 and shard.index <= count, "worker index is out of range")
  if count == 1 then
    return 1
  end
  if selectedLayer == "unit" or selectedLayer == "component" then
    return (ordinal - 1) % count + 1
  end
  if selectedLayer == "graphics" or selectedLayer == "acceptance" or selectedLayer == "rom" then
    return 1
  end
  if entry.layer == "graphics" then
    return 1
  elseif entry.layer == "acceptance" then
    return math.min(2, count)
  elseif entry.layer == "rom" then
    return math.min(3, count)
  elseif entry.layer == "unit" or entry.layer == "component" then
    if count >= 4 then
      return 4 + (ordinal - 1) % (count - 3)
    end
    return count
  end
  error("unknown test layer " .. entry.layer, 0)
end

function Parallel.owns(entry, ordinal, shard, selectedLayer)
  return Parallel.workerFor(entry, ordinal, shard, selectedLayer) == shard.index
end

function Parallel.fragmentPath(runDir, index)
  assert(type(runDir) == "string" and runDir ~= "", "fragment run directory is required")
  positiveInteger(index, "fragment worker index")
  return runDir .. "/worker-" .. index .. ".lua"
end

local function validateWrapper(wrapper, expectedIndex, expectedCount)
  assert(type(wrapper) == "table" and wrapper.schema == Parallel.FRAGMENT_SCHEMA, "invalid worker fragment schema")
  assert(type(wrapper.worker) == "table", "worker fragment identity is missing")
  local index = positiveInteger(wrapper.worker.index, "fragment worker index")
  local count = positiveInteger(wrapper.worker.count, "fragment worker count")
  assert(index == expectedIndex and count == expectedCount, "worker fragment identity does not match")
  validateRun(wrapper.run)
  return wrapper
end

function Parallel.writeFragment(runDir, index, count, run)
  positiveInteger(index, "fragment worker index")
  positiveInteger(count, "fragment worker count")
  assert(index <= count, "fragment worker index is out of range")
  validateRun(run)
  local path = Parallel.fragmentPath(runDir, index)
  local temporary = path .. ".tmp"
  local encoded = LuaWriter.encode({
    schema = Parallel.FRAGMENT_SCHEMA,
    worker = { index = index, count = count },
    run = run,
  })
  local handle, openError = io.open(temporary, "w")
  assert(handle ~= nil, "cannot open worker fragment: " .. tostring(openError))
  local ok, message = pcall(function()
    assert(handle:write(encoded))
    local closed, closeError = handle:close()
    handle = nil
    assert(closed, tostring(closeError))
  end)
  if not ok then
    if handle ~= nil then
      handle:close()
    end
    os.remove(temporary)
    error(message, 0)
  end
  local renamed, renameError = os.rename(temporary, path)
  if not renamed then
    os.remove(temporary)
    error("cannot publish worker fragment: " .. tostring(renameError), 0)
  end
end

function Parallel.readFragment(runDir, index, count)
  local path = Parallel.fragmentPath(runDir, index)
  local handle, openError = io.open(path, "r")
  assert(handle ~= nil, "cannot read worker fragment: " .. tostring(openError))
  local source = handle:read("*a")
  handle:close()
  local chunk, loadError
  if loadstring ~= nil then
    chunk, loadError = loadstring(source, "@" .. path)
    assert(chunk ~= nil, "cannot compile worker fragment: " .. tostring(loadError))
    setfenv(chunk, {})
  else
    chunk, loadError = load(source, "@" .. path, "t", {})
    assert(chunk ~= nil, "cannot compile worker fragment: " .. tostring(loadError))
  end
  local ok, wrapper = pcall(chunk)
  assert(ok, "cannot evaluate worker fragment: " .. tostring(wrapper))
  return validateWrapper(wrapper, index, count)
end

function Parallel.readFragments(runDir, count)
  positiveInteger(count, "worker count")
  local fragments = {}
  for index = 1, count do
    fragments[index] = Parallel.readFragment(runDir, index, count)
  end
  return fragments
end

local function resultRank(test)
  if test == "<load>" then
    return 1
  elseif test == "<beforeAll>" then
    return 2
  elseif test == "<afterAll>" then
    return 4
  end
  return 3
end

local function union(into, values)
  for name, enabled in pairs(values) do
    if enabled then
      into[name] = true
    end
  end
end

function Parallel.merge(fragments)
  assert(type(fragments) == "table" and #fragments > 0, "worker fragments are required")
  local count = nil
  local seen = {}
  local entries = {}
  local merged = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0,
    byLayer = {},
    capabilities = {},
    selectedCapabilities = {},
    excludedSlow = 0,
    suiteTimings = {},
  }
  local orderedFragments = {}
  for _, wrapper in ipairs(fragments) do
    assert(type(wrapper) == "table" and type(wrapper.worker) == "table", "worker fragment identity is missing")
    orderedFragments[#orderedFragments + 1] = wrapper
  end
  table.sort(orderedFragments, function(a, b)
    return a.worker.index < b.worker.index
  end)
  for _, wrapper in ipairs(orderedFragments) do
    if count == nil then
      count = positiveInteger(wrapper.worker and wrapper.worker.count, "worker count")
    end
    local checked = validateWrapper(wrapper, wrapper.worker.index, count)
    local index = checked.worker.index
    assert(not seen[index], "duplicate worker fragment")
    seen[index] = true
    local run = checked.run
    merged.passed = merged.passed + run.passed
    merged.failed = merged.failed + run.failed
    merged.skipped = merged.skipped + run.skipped
    merged.excludedSlow = merged.excludedSlow + run.excludedSlow
    merged.duration = math.max(merged.duration, run.duration)
    union(merged.capabilities, run.capabilities)
    union(merged.selectedCapabilities, run.selectedCapabilities)
    for _, entry in ipairs(run.results) do
      entries[#entries + 1] = { entry = entry, worker = index }
    end
    for layer, counts in pairs(run.byLayer) do
      local target = merged.byLayer[layer]
      if target == nil then
        target = { passed = 0, failed = 0, skipped = 0, duration = 0 }
        merged.byLayer[layer] = target
      end
      target.passed = target.passed + counts.passed
      target.failed = target.failed + counts.failed
      target.skipped = target.skipped + counts.skipped
      target.duration = target.duration + counts.duration
    end
    for _, timing in ipairs(run.suiteTimings) do
      merged.suiteTimings[#merged.suiteTimings + 1] = timing
    end
    if run.versions ~= nil then
      merged.versions = merged.versions or {}
      for _, version in ipairs(run.versions) do
        merged.versions[#merged.versions + 1] = version
      end
    end
  end
  assert(#fragments == count, "worker fragments are incomplete")
  for index = 1, count do
    assert(seen[index], "worker fragments are incomplete")
  end
  table.sort(entries, function(a, b)
    if a.entry.module ~= b.entry.module then
      return a.entry.module < b.entry.module
    end
    local aRank, bRank = resultRank(a.entry.test), resultRank(b.entry.test)
    if aRank ~= bRank then
      return aRank < bRank
    end
    if a.entry.test ~= b.entry.test then
      return a.entry.test < b.entry.test
    end
    return a.worker < b.worker
  end)
  for _, item in ipairs(entries) do
    merged.results[#merged.results + 1] = item.entry
  end
  if merged.versions ~= nil then
    table.sort(merged.versions)
  end
  return merged
end

return Parallel
