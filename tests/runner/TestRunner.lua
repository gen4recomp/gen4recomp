-- Public entry point of the capability-aware test runner: recursive discovery
-- over approved roots, layer/filter/tag/slow selection, and explicit pass/fail/skip
-- results. There is no module registry — a suite is discovered because it
-- exists, so removing a line can never hide a test.
--
-- Options:
--   roots        table[]|nil                 legacy explicit roots for focused tests
--   fs           love.filesystem-shaped       defaults to love.filesystem
--   load         fun(moduleName): table       defaults to require
--   capabilities table<string, boolean>       available capabilities, default {}
--   layer        string|nil                   run only this layer
--   filter       string|nil                   literal substring over
--                                             "module :: test"
--   tag          string|nil                   exact suite tag membership
--   slow         boolean|nil                  include slow suites, default false
--   onResult       fun(result: table)|nil      called after each result

local Discovery = require("tests.runner.Discovery")
local Execution = require("tests.runner.Execution")
local Selection = require("tests.runner.Selection")
local Suite = require("tests.runner.Suite")
local Parallel = require("tests.runner.Parallel")

local TestRunner = {}

local function resolve(options)
  assert(type(options) == "table", "TestRunner needs an options table")
  local fs = options.fs or (love ~= nil and love.filesystem or nil)
  assert(type(fs) == "table", "TestRunner needs a filesystem reader")
  return {
    roots = options.roots,
    fs = fs,
    load = options.load or require,
    capabilities = options.capabilities or {},
    layer = options.layer,
    filter = options.filter,
    tag = options.tag,
    slow = options.slow,
    onResult = options.onResult,
    shard = options.shard,
  }
end

local function loadFailure(entry, message)
  return {
    module = entry.module,
    test = "<load>",
    status = "fail",
    message = message,
    layer = entry.layer,
    duration = 0,
  }
end

-- Whether a discovered entry may be loaded under the selection. The discovery
-- root is the single source of a suite's layer, so the decision is exact: a
-- module loads exactly when its root layer is selected, with no
-- approximation branch, and an unselected root's module is never required.
local function mayLoad(entry, layer)
  return layer == nil or entry.layer == layer
end

-- Discovers and normalizes every suite of the selected layer, in module order.
-- Modules under a root the selection excludes are never loaded; the rest are
-- loaded (test names come from the module itself) but never executed. Each
-- returned item carries either a normalized `suite` or the `failure` result of
-- a module that could not be loaded or normalized.
---@return { suite: RunnerSuite|nil, failure: table|nil }[]
---@param config { fs: table, roots: string[]|nil, load: function, capabilities: table<string, boolean>, layer: string|nil, filter: string|nil, tag: string|nil, slow: boolean|nil, onResult: function|nil, shard: table|nil }
local function collect(config)
  local items = {}
  for ordinal, entry in ipairs(Discovery.suites(config.fs, config.roots)) do
    if
      mayLoad(entry, config.layer)
      and (config.shard == nil or Parallel.owns(entry, ordinal, config.shard, config.layer))
    then
      local ok, loaded = pcall(config.load, entry.module)
      if not ok then
        items[#items + 1] = { failure = loadFailure(entry, "module load failed: " .. tostring(loaded)) }
      else
        local normalized
        ok, normalized = pcall(Suite.normalize, loaded, entry.module, entry.layer)
        if not ok then
          items[#items + 1] = { failure = loadFailure(entry, tostring(normalized)) }
        else
          items[#items + 1] = { suite = normalized }
        end
      end
    end
  end
  return items
end

-- Discovery without execution: one entry per suite, sorted by module name. A
-- module that cannot be loaded is listed with its `error` and no tests, the same
-- way a run reports it as one failed result — one broken suite must not replace
-- the whole listing with a traceback.
---@param options table
---@return { module: string, layer: string, capabilities: string[], tags: string[], slow: boolean, tests: string[], error: string|nil }[]
function TestRunner.list(options)
  local config = resolve(options)
  local listing = {}
  for _, item in ipairs(collect(config)) do
    if item.failure ~= nil then
      listing[#listing + 1] = {
        module = item.failure.module,
        layer = item.failure.layer,
        capabilities = {},
        tags = {},
        slow = false,
        tests = {},
        error = item.failure.message,
      }
    else
      local suite = assert(item.suite, "collected item carries neither a suite nor a failure")
      local tests = Selection.tests(suite, config)
      if #tests > 0 then
        listing[#listing + 1] = {
          module = suite.module,
          layer = suite.layer,
          capabilities = suite.capabilities,
          tags = suite.tags,
          slow = suite.slow,
          tests = tests,
        }
      end
    end
  end
  return listing
end

---@param run RunnerRun
---@param entry { module: string, test: string, status: string, layer: string, duration: number }
local function tally(run, entry)
  run.results[#run.results + 1] = entry
  local layer = run.byLayer[entry.layer]
  if layer == nil then
    layer = { passed = 0, failed = 0, skipped = 0, duration = 0 }
    run.byLayer[entry.layer] = layer
  end
  layer = assert(layer)
  if entry.status == "pass" then
    run.passed = run.passed + 1
    layer.passed = layer.passed + 1
  elseif entry.status == "skip" then
    run.skipped = run.skipped + 1
    layer.skipped = layer.skipped + 1
  else
    run.failed = run.failed + 1
    layer.failed = layer.failed + 1
  end
end

---@class RunnerRun
---@field results table[]
---@field passed integer
---@field failed integer
---@field skipped integer
---@field duration number seconds
---@field byLayer table<string, { passed: integer, failed: integer, skipped: integer, duration: number }>
---@field capabilities table<string, boolean>
---@field selectedCapabilities table<string, boolean> union of declared capabilities of suites with selected tests
---@field excludedSlow integer tests hidden solely by slow eligibility after the other selectors matched
---@field versions string[]|nil ready game versions the run exercised, when known
---@field suiteTimings table[]|nil per-suite hook-inclusive timing rows
---@field workerCriticalPath number|nil the longest worker's duration in a merged parallel result; nil for a serial run

---@return RunnerRun
---@param options table
function TestRunner.run(options)
  local config = resolve(options)
  local started = love ~= nil and love.timer ~= nil and love.timer.getTime() or os.clock()
  local items = collect(config)

  local run = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0,
    byLayer = {},
    capabilities = config.capabilities,
    selectedCapabilities = {},
    excludedSlow = 0,
    suiteTimings = {},
  }
  local function record(entry)
    entry = assert(entry)
    tally(run, entry)
    if config.onResult ~= nil then
      config.onResult(entry)
    end
  end
  for _, item in ipairs(items) do
    if item.failure ~= nil then
      record(item.failure)
    else
      local suite = assert(item.suite, "collected item carries neither a suite nor a failure")
      local selected, hidden = Selection.tests(suite, config)
      run.excludedSlow = run.excludedSlow + hidden
      if #selected > 0 then
        for _, name in ipairs(suite.capabilities) do
          run.selectedCapabilities[name] = true
        end
        local results, timing = Execution.runSuite(suite, config, selected)
        for _, entry in ipairs(results) do
          record(assert(entry))
        end
        if timing ~= nil and #results > 0 then
          local layer = run.byLayer[suite.layer]
          if layer == nil then
            layer = { passed = 0, failed = 0, skipped = 0, duration = 0 }
            run.byLayer[suite.layer] = layer
          end
          layer.duration = layer.duration + timing.total
          run.suiteTimings[#run.suiteTimings + 1] = {
            module = suite.module,
            layer = suite.layer,
            beforeAll = timing.beforeAll,
            tests = timing.tests,
            afterAll = timing.afterAll,
            total = timing.total,
          }
        end
      end
    end
  end

  local finished = love ~= nil and love.timer ~= nil and love.timer.getTime() or os.clock()
  run.duration = finished - started
  return run
end

return TestRunner
