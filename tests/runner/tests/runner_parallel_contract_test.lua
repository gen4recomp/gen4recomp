-- Contract tests for process-isolated test execution. The public command keeps
-- one selection/outcome policy while workers own complete suites and the
-- aggregate process restores one deterministic RunnerRun.

local Assert = require("tests.support.Assert")
local Cli = require("tests.runner.Cli")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

local function parallel()
  local ok, module = pcall(require, "tests.runner.Parallel")
  Assert.isTrue(ok, "process-sharding behavior needs its runner owner")
  Assert.equal(type(module), "table", "process-sharding owner must return a module")
  return assert(module)
end

local function contains(lines, needle, label)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) ~= nil then
      return
    end
  end
  error((label or "lines") .. " must contain " .. string.format("%q", needle), 2)
end

local function parse(argv)
  local plan, message = Cli.parse(argv)
  Assert.isTrue(plan ~= nil, "expected a valid plan, got " .. tostring(message))
  return assert(plan)
end

local function result(module, test, status, layer, duration)
  return {
    module = module,
    test = test,
    status = status,
    message = status == "pass" and "" or status .. " reason",
    layer = layer,
    duration = duration,
  }
end

---@param results table[]
---@param overrides { duration: number|nil, byLayer: table<string, table>|nil, selectedCapabilities: table<string, boolean>|nil, excludedSlow: integer|nil, suiteTimings: table[]|nil }|nil
---@return RunnerRun
local function runData(results, overrides)
  ---@type RunnerRun
  local run = {
    results = results,
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
  for _, entry in ipairs(results) do
    local field = entry.status == "pass" and "passed" or (entry.status == "fail" and "failed" or "skipped")
    run[field] = run[field] + 1
    local counts = run.byLayer[entry.layer]
    if counts == nil then
      counts = { passed = 0, failed = 0, skipped = 0, duration = 0 }
      run.byLayer[entry.layer] = counts
    end
    counts[field] = counts[field] + 1
    counts.duration = counts.duration + entry.duration
  end
  if overrides ~= nil then
    if overrides.duration ~= nil then
      run.duration = overrides.duration
    end
    if overrides.byLayer ~= nil then
      run.byLayer = overrides.byLayer
    end
    if overrides.selectedCapabilities ~= nil then
      run.selectedCapabilities = overrides.selectedCapabilities
    end
    if overrides.excludedSlow ~= nil then
      run.excludedSlow = overrides.excludedSlow
    end
    if overrides.suiteTimings ~= nil then
      run.suiteTimings = overrides.suiteTimings
    end
  end
  return run
end

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function withTempDirectory(fn)
  local path = os.tmpname()
  os.remove(path)
  os.execute("mkdir -p " .. shellQuote(path))
  local ok, message = pcall(fn, path)
  os.execute("rm -rf -- " .. shellQuote(path))
  if not ok then
    error(message, 0)
  end
end

local function mixedCorpus(withBrokenRom)
  local function case()
    return function() end
  end
  local files = {
    ["fake/acceptance/story_test.lua"] = { tests = { ["runs"] = case() } },
    ["fake/component/engine_test.lua"] = { tests = { ["runs"] = case() } },
    ["fake/graphics/shader_test.lua"] = { tests = { ["runs"] = case() } },
    ["fake/rom/dump_test.lua"] = { tests = { ["runs"] = case() } },
    ["fake/unit/alpha_test.lua"] = { tests = { ["runs"] = case() } },
    ["fake/unit/beta_test.lua"] = { tests = { ["runs"] = case() } },
  }
  if withBrokenRom then
    files["fake/rom/broken_test.lua"] = FakeCorpus.LOAD_ERROR
  end
  return FakeCorpus.new(files)
end

local function roots(corpus)
  return {
    corpus:root("fake/acceptance", "acceptance"),
    corpus:root("fake/component", "component"),
    corpus:root("fake/graphics", "graphics"),
    corpus:root("fake/rom", "rom"),
    corpus:root("fake/unit", "unit"),
  }
end

local function runWorker(corpus, index, count, loads)
  return TestRunner.run({
    roots = roots(corpus),
    fs = corpus.fs,
    capabilities = {},
    shard = { index = index, count = count },
    load = function(moduleName)
      loads[moduleName] = (loads[moduleName] or 0) + 1
      return corpus.load(moduleName)
    end,
  })
end

local function selectedModules(run)
  local modules = {}
  for _, entry in ipairs(run.results) do
    modules[entry.module] = true
  end
  return modules
end

function T.public_jobs_control_is_strict_and_reaches_the_plan_protocol()
  for _, jobs in ipairs({ "1", "4", "16" }) do
    local plan = parse({ "--jobs", jobs })
    Assert.equal(plan.jobs, tonumber(jobs), "positive jobs value is retained")
  end

  local plan = parse({ "--plan", "--jobs", "4" })
  local lines = Cli.renderPlan(plan, {}, 4)
  contains(lines, "prepare=0", "plan")
  contains(lines, "jobs=4", "plan")
end

function T.invalid_jobs_values_are_usage_errors()
  for _, value in ipairs({ nil, "0", "-1", "1.5", "abc", "01" }) do
    local argv = { "--jobs" }
    if value ~= nil then
      argv[2] = value
    end
    local plan, message = Cli.parse(argv)
    Assert.isNil(plan, "invalid jobs value must not produce a plan")
    Assert.isTrue(type(message) == "string" and #message > 0, "invalid jobs needs an actionable message")
  end
end

function T.job_policy_bounds_full_runs_and_preserves_focused_serial_defaults()
  local Parallel = parallel()
  ---@param fields { list: boolean|nil, layer: string|nil, filter: string|nil, tag: string|nil, jobs: integer|nil }|nil
  ---@return TestPlan
  local function plan(fields)
    fields = fields or {}
    return {
      planMode = false,
      list = fields.list == true,
      slow = false,
      layer = fields.layer,
      filter = fields.filter,
      tag = fields.tag,
      jobs = fields.jobs,
      strict = false,
      graphicsStrict = false,
      requiredCapabilities = {},
    }
  end

  Assert.equal(Parallel.effectiveJobs(plan(), 20, 16), 4)
  Assert.equal(Parallel.effectiveJobs(plan(), 20, 2), 2)
  Assert.equal(Parallel.effectiveJobs(plan(), 20, 1), 1)
  Assert.equal(Parallel.effectiveJobs(plan(), 0, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ filter = "runner" }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ tag = "door" }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ layer = "unit" }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ layer = "unit", jobs = 6 }), 20, 16), 6)
  Assert.equal(Parallel.effectiveJobs(plan({ jobs = 16 }), 3, 16), 3)
  Assert.equal(Parallel.effectiveJobs(plan({ layer = "graphics", jobs = 16 }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ layer = "acceptance", jobs = 16 }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ layer = "rom", jobs = 16 }), 20, 16), 1)
  Assert.equal(Parallel.effectiveJobs(plan({ list = true, jobs = 16 }), 20, 16), 1)
end

function T.mixed_suite_ownership_is_complete_and_count_three_uses_worker_three()
  local corpus = mixedCorpus(false)
  local expected = {
    ["fake.acceptance.story_test"] = { [1] = false, [2] = true, [3] = false },
    ["fake.component.engine_test"] = { [1] = false, [2] = false, [3] = true },
    ["fake.graphics.shader_test"] = { [1] = true, [2] = false, [3] = false },
    ["fake.rom.dump_test"] = { [1] = false, [2] = false, [3] = true },
    ["fake.unit.alpha_test"] = { [1] = false, [2] = false, [3] = true },
    ["fake.unit.beta_test"] = { [1] = false, [2] = false, [3] = true },
  }
  local loaded = {}
  local executed = {}

  for worker = 1, 3 do
    local loads = {}
    local run = runWorker(corpus, worker, 3, loads)
    for moduleName, count in pairs(loads) do
      loaded[moduleName] = (loaded[moduleName] or 0) + count
    end
    for moduleName in pairs(selectedModules(run)) do
      executed[moduleName] = (executed[moduleName] or 0) + 1
      Assert.isTrue(expected[moduleName][worker], moduleName .. " has the wrong count-three worker")
    end
  end

  for moduleName, owners in pairs(expected) do
    Assert.equal(loaded[moduleName], 1, moduleName .. " must load in exactly one worker")
    Assert.equal(executed[moduleName], 1, moduleName .. " must execute in exactly one worker")
    local ownerCount = 0
    for _, owns in pairs(owners) do
      if owns then
        ownerCount = ownerCount + 1
      end
    end
    Assert.equal(ownerCount, 1, moduleName .. " must have one owner")
  end
end

function T.safety_lanes_remain_single_owner_at_every_supported_worker_count()
  local corpus = mixedCorpus(false)
  local safety = {
    ["fake.graphics.shader_test"] = true,
    ["fake.acceptance.story_test"] = true,
    ["fake.rom.dump_test"] = true,
  }
  for _, count in ipairs({ 1, 2, 3, 4, 6 }) do
    local owners = {}
    for worker = 1, count do
      local run = runWorker(corpus, worker, count, {})
      for moduleName in pairs(selectedModules(run)) do
        owners[moduleName] = (owners[moduleName] or 0) + 1
      end
    end
    for moduleName in pairs(safety) do
      Assert.equal(owners[moduleName], 1, moduleName .. " must stay in one safety lane")
    end
  end
end

function T.broken_owned_suite_is_loaded_once_and_remains_one_load_failure()
  local corpus = mixedCorpus(true)
  local loads = {}
  local failures = 0
  for worker = 1, 3 do
    local run = runWorker(corpus, worker, 3, loads)
    for _, entry in ipairs(run.results) do
      if entry.module == "fake.rom.broken_test" and entry.status == "fail" then
        failures = failures + 1
      end
    end
  end
  Assert.equal(loads["fake.rom.broken_test"], 1, "a broken suite is loaded only by its owner")
  Assert.equal(failures, 1, "a broken owned suite contributes one load failure")
end

function T.private_process_context_rejects_partial_or_contradictory_environment()
  local Parallel = parallel()
  Assert.equal(Parallel.context({}).kind, "normal")
  local worker = Parallel.context({
    G4RECOMP_TEST_RUN_DIR = "/tmp/run",
    G4RECOMP_TEST_WORKERS = "3",
    G4RECOMP_TEST_WORKER = "2",
  })
  Assert.equal(worker.kind, "worker")
  Assert.equal(worker.index, 2)
  Assert.equal(worker.count, 3)
  Assert.equal(
    Parallel.context({
      G4RECOMP_TEST_RUN_DIR = "/tmp/run",
      G4RECOMP_TEST_WORKERS = "3",
      G4RECOMP_TEST_AGGREGATE = "1",
    }).kind,
    "aggregate"
  )

  for _, env in ipairs({
    { G4RECOMP_TEST_RUN_DIR = "/tmp/run" },
    { G4RECOMP_TEST_WORKERS = "3", G4RECOMP_TEST_WORKER = "1" },
    { G4RECOMP_TEST_RUN_DIR = "/tmp/run", G4RECOMP_TEST_WORKERS = "3", G4RECOMP_TEST_WORKER = "0" },
    {
      G4RECOMP_TEST_RUN_DIR = "/tmp/run",
      G4RECOMP_TEST_WORKERS = "3",
      G4RECOMP_TEST_WORKER = "1",
      G4RECOMP_TEST_AGGREGATE = "1",
    },
  }) do
    Assert.throws(function()
      Parallel.context(env)
    end, "malformed process context must fail closed")
  end
end

function T.worker_fragments_round_trip_atomically_and_reject_corruption()
  local Parallel = parallel()
  withTempDirectory(function(runDir)
    local run = runData({ result("fake.unit.alpha_test", "pass", "pass", "unit", 0.1) }, {
      duration = 1.25,
      selectedCapabilities = { rom_dump = true },
      excludedSlow = 2,
      suiteTimings = {},
    })
    Parallel.writeFragment(runDir, 2, 4, run)
    local wrapper = Parallel.readFragment(runDir, 2, 4)
    Assert.equal(wrapper.schema, "g4-test-worker-v1")
    Assert.equal(wrapper.worker.index, 2)
    Assert.equal(wrapper.worker.count, 4)
    Assert.equal(wrapper.run.duration, 1.25)
    Assert.isNil(io.open(Parallel.fragmentPath(runDir, 2) .. ".tmp", "r"), "temporary file is not published")

    local handle = assert(io.open(Parallel.fragmentPath(runDir, 1), "w"))
    handle:write("return { schema = 'wrong', worker = { index = 1, count = 4 }, run = {} }\n")
    handle:close()
    Assert.throws(function()
      Parallel.readFragment(runDir, 1, 4)
    end, "wrong schema must not be accepted")

    handle = assert(io.open(Parallel.fragmentPath(runDir, 3), "w"))
    handle:write("not lua")
    handle:close()
    Assert.throws(function()
      Parallel.readFragment(runDir, 3, 4)
    end, "malformed Lua must not be accepted")
  end)
end

function T.fragment_merge_preserves_counts_capabilities_order_and_critical_path()
  local Parallel = parallel()
  local first = runData({
    result("fake.unit.alpha_test", "<afterAll>", "fail", "unit", 0.3),
    result("fake.unit.alpha_test", "ordinary", "pass", "unit", 0.2),
  }, {
    duration = 2.5,
    selectedCapabilities = { graphics = true },
    excludedSlow = 3,
    byLayer = { unit = { passed = 1, failed = 1, skipped = 0, duration = 0.5 } },
    suiteTimings = { { module = "fake.unit.alpha_test", total = 0.5 } },
  })
  local second = runData({
    result("fake.unit.alpha_test", "<beforeAll>", "pass", "unit", 0.1),
    result("fake.rom.dump_test", "reads", "skip", "rom", 0),
  }, {
    duration = 4.75,
    selectedCapabilities = { rom_dump = true },
    excludedSlow = 5,
    byLayer = {
      unit = { passed = 1, failed = 0, skipped = 0, duration = 0.1 },
      rom = { passed = 0, failed = 0, skipped = 1, duration = 0 },
    },
    suiteTimings = { { module = "fake.rom.dump_test", total = 0 } },
  })

  local merged = Parallel.merge({
    { schema = "g4-test-worker-v1", worker = { index = 2, count = 2 }, run = second },
    { schema = "g4-test-worker-v1", worker = { index = 1, count = 2 }, run = first },
  })
  Assert.equal(merged.passed, 2)
  Assert.equal(merged.failed, 1)
  Assert.equal(merged.skipped, 1)
  Assert.equal(merged.excludedSlow, 8)
  Assert.equal(merged.duration, 4.75)
  Assert.isTrue(merged.selectedCapabilities.graphics)
  Assert.isTrue(merged.selectedCapabilities.rom_dump)
  Assert.equal(merged.byLayer.unit.passed, 2)
  Assert.equal(merged.byLayer.unit.failed, 1)
  Assert.equal(merged.byLayer.unit.duration, 0.6)
  Assert.equal(merged.byLayer.rom.skipped, 1)
  Assert.equal(#merged.suiteTimings, 2)
  Assert.equal(merged.results[1].module, "fake.rom.dump_test", "modules sort by identity")
  Assert.equal(merged.results[2].test, "<beforeAll>", "setup result stays first")
  Assert.equal(merged.results[3].test, "ordinary")
  Assert.equal(merged.results[4].test, "<afterAll>", "cleanup result stays last")
end

function T.fragment_merge_sorts_modules_by_identity_across_workers()
  local Parallel = parallel()
  local merged = Parallel.merge({
    {
      schema = "g4-test-worker-v1",
      worker = { index = 1, count = 2 },
      run = runData({ result("fake.unit.zulu_test", "runs", "pass", "unit", 0) }),
    },
    {
      schema = "g4-test-worker-v1",
      worker = { index = 2, count = 2 },
      run = runData({ result("fake.unit.alpha_test", "runs", "pass", "unit", 0) }),
    },
  })
  Assert.equal(merged.results[1].module, "fake.unit.alpha_test")
  Assert.equal(merged.results[2].module, "fake.unit.zulu_test")
end

function T.missing_fragments_cannot_be_merged_as_an_empty_worker()
  local Parallel = parallel()
  Assert.throws(function()
    Parallel.readFragments("/tmp/no-such-worker-run", 2)
  end, "a missing worker fragment must be infrastructure failure")
end

return { tests = T }
