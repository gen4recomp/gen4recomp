-- Contract tests for the capability-aware runner's execution and result model.
-- Results are pass, fail, or skip: a skip is always explicit and is never
-- counted as a pass, a module-load error is a failed result carrying the module name rather than a
-- runner crash, and cleanup hooks run on every terminal path.

local Assert = require("tests.support.Assert")
local Execution = require("tests.runner.Execution")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local Suite = require("tests.runner.Suite")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

-- Raises when absent so a missing result fails as a reporting defect rather
-- than as a nil index further down the test.
---@return { module: string, test: string, status: string, message: string, layer: string, duration: number }
---@param run table
---@param moduleName string
---@param testName string|nil
local function resultFor(run, moduleName, testName)
  for _, entry in ipairs(run.results) do
    if entry.module == moduleName and (testName == nil or entry.test == testName) then
      return entry
    end
  end
  error("no result for " .. moduleName .. " :: " .. tostring(testName), 2)
end

-- A flat `name -> function` module is no legacy shape: normalization rejects
-- it, so the runner reports one failed result naming the module instead of
-- guessing what the module means.
function T.flat_module_is_rejected_as_a_failed_result()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { ["adds"] = function() end, ["subtracts"] = function() end },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 1)
  local failure = resultFor(run, "fake.unit.alpha_test")
  Assert.equal(failure.status, "fail")
  Assert.isTrue(
    tostring(failure.message):find("tests table", 1, true) ~= nil,
    "the rejection names the missing tests table: " .. tostring(failure.message)
  )
end

-- a module that fails to load is one failed result naming the
-- module; the rest of the corpus still runs.
function T.module_load_failure_is_a_failed_result()
  local corpus = FakeCorpus.new({
    ["fake/unit/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
    ["fake/unit/healthy_test.lua"] = { tests = { ["works"] = function() end } },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.failed, 1)
  Assert.equal(run.passed, 1)
  local failure = resultFor(run, "fake.unit.broken_test")
  Assert.equal(failure.status, "fail")
  Assert.isTrue(
    tostring(failure.message):find("fake load failure", 1, true) ~= nil,
    "load failure keeps the underlying error: " .. tostring(failure.message)
  )
end

-- an explicit skip is recorded as a skip with its reason, never as
-- a pass.
function T.explicit_skip_is_counted_as_skip()
  local corpus = FakeCorpus.new({
    ["fake/rom/dump_test.lua"] = {
      tests = {
        ["reads the dump"] = function(context)
          context:skip("no ready user-owned HGSS dump")
          error("skip must abort the test body", 0)
        end,
      },
    },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/rom", "rom") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.skipped, 1)
  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 0)
  local skip = resultFor(run, "fake.rom.dump_test", "reads the dump")
  Assert.equal(skip.status, "skip")
  Assert.isTrue(
    tostring(skip.message):find("no ready user-owned HGSS dump", 1, true) ~= nil,
    "skip records its reason: " .. tostring(skip.message)
  )
end

-- a suite whose declared capability is unavailable skips with the
-- capability named, and its bodies never run.
function T.missing_capability_skips_the_suite()
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/acc/lab_test.lua"] = {
      metadata = { capabilities = { "rom_dump" } },
      tests = {
        ["boots the lab"] = function()
          executed = true
        end,
      },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/acc", "acceptance") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = { graphics = true },
  })

  Assert.isFalse(executed, "a suite missing its capability must not execute")
  Assert.equal(run.skipped, 1)
  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 0)
  local skip = resultFor(run, "fake.acc.lab_test", "boots the lab")
  Assert.equal(skip.status, "skip")
  Assert.isTrue(
    tostring(skip.message):find("rom_dump", 1, true) ~= nil,
    "capability skip names the capability: " .. tostring(skip.message)
  )
end

-- setup failure is reported and still runs the cleanup hook.
function T.setup_failure_reports_and_still_runs_cleanup()
  local cleanups = 0
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      beforeAll = function(context)
        context.store = {}
        error("alpha setup failed", 0)
      end,
      afterAll = function()
        cleanups = cleanups + 1
      end,
      tests = {
        ["never runs"] = function()
          executed = true
        end,
      },
    },
    ["fake/unit/beta_test.lua"] = { tests = { ["still runs"] = function() end } },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(cleanups, 1)
  Assert.isFalse(executed, "tests must not run after setup failed")
  Assert.equal(run.passed, 1)
  Assert.isTrue(run.failed >= 1, "setup failure is reported as a failure")
  local failure = resultFor(run, "fake.unit.alpha_test")
  Assert.equal(failure.status, "fail")
  Assert.isTrue(
    tostring(failure.message):find("alpha setup failed", 1, true) ~= nil,
    "setup failure keeps its message: " .. tostring(failure.message)
  )
end

-- one failing test stops neither its siblings nor later modules, and
-- cleanup still runs.
function T.test_failure_does_not_stop_the_run()
  local cleanups = 0
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      afterAll = function()
        cleanups = cleanups + 1
      end,
      tests = {
        ["a passes"] = function() end,
        ["b fails"] = function()
          error("deliberate alpha failure", 0)
        end,
        ["c passes"] = function() end,
      },
    },
    ["fake/unit/beta_test.lua"] = { tests = { ["runs after a failure"] = function() end } },
  })

  local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(run.passed, 3)
  Assert.equal(run.failed, 1)
  Assert.equal(cleanups, 1)
  Assert.equal(resultFor(run, "fake.unit.alpha_test", "c passes").status, "pass")
  Assert.equal(resultFor(run, "fake.unit.beta_test", "runs after a failure").status, "pass")
  local failure = resultFor(run, "fake.unit.alpha_test", "b fails")
  Assert.isTrue(
    tostring(failure.message):find("deliberate alpha failure", 1, true) ~= nil,
    "failure keeps its message: " .. tostring(failure.message)
  )
end

-- the context threads suite state and capability queries from setup
-- into every test of that suite.
function T.context_is_shared_between_hooks_and_tests()
  local seen = {}
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      metadata = { capabilities = { "graphics" } },
      beforeAll = function(context)
        context.fixture = "prepared"
      end,
      tests = {
        ["sees setup state"] = function(context)
          seen.fixture = context.fixture
          seen.graphics = context:hasCapability("graphics")
          seen.romDump = context:hasCapability("rom_dump")
        end,
      },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = { graphics = true },
  })

  Assert.equal(run.passed, 1)
  Assert.equal(seen.fixture, "prepared")
  Assert.isTrue(seen.graphics, "declared available capability reads as available")
  Assert.isFalse(seen.romDump, "undeclared capability reads as unavailable")
end

-- the report carries durations and per-layer pass/fail/skip counts.
function T.report_summarises_counts_and_durations_by_layer()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      tests = {
        ["passes"] = function() end,
        ["fails"] = function()
          error("deliberate failure", 0)
        end,
      },
    },
    ["fake/rom/dump_test.lua"] = {
      metadata = { capabilities = { "rom_dump" } },
      tests = { ["reads the dump"] = function() end },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/rom", "rom"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    capabilities = {},
  })

  Assert.equal(run.byLayer.unit.passed, 1)
  Assert.equal(run.byLayer.unit.failed, 1)
  Assert.equal(run.byLayer.unit.skipped, 0)
  Assert.equal(run.byLayer.rom.passed, 0)
  Assert.equal(run.byLayer.rom.skipped, 1)
  Assert.equal(type(run.duration), "number")
  Assert.equal(type(resultFor(run, "fake.unit.alpha_test", "passes").duration), "number")
end

local function withFakeClock(fn)
  local t = 0
  local function tick()
    t = t + 0.05
    return t
  end
  local savedClock = os.clock
  local savedLove = nil
  local hasLove = love ~= nil and love.timer ~= nil and love.timer.getTime ~= nil
  if hasLove then
    savedLove = love.timer.getTime
    love.timer.getTime = tick
  end
  os.clock = tick
  local ok, err = pcall(fn)
  os.clock = savedClock
  if hasLove then
    love.timer.getTime = savedLove
  end
  if not ok then
    error(err, 0)
  end
end

local function assertTimingInvariants(timing)
  Assert.notNil(timing, "suite timing must be returned")
  Assert.equal(type(timing.beforeAll), "number")
  Assert.equal(type(timing.tests), "number")
  Assert.equal(type(timing.afterAll), "number")
  Assert.equal(type(timing.total), "number")
  Assert.isTrue(timing.beforeAll >= 0, "beforeAll is not negative")
  Assert.isTrue(timing.tests >= 0, "tests is not negative")
  Assert.isTrue(timing.afterAll >= 0, "afterAll is not negative")
  Assert.isTrue(timing.total >= 0, "total is not negative")
  local sum = timing.beforeAll + timing.tests + timing.afterAll
  Assert.isTrue(math.abs(sum - timing.total) < 1e-9, "total equals sum of segments")
end

function T.execution_returns_hook_inclusive_timing_with_controlled_clock()
  withFakeClock(function()
    local suite = Suite.normalize({
      beforeAll = function() end,
      afterAll = function() end,
      tests = { ["a"] = function() end, ["b"] = function() end },
    }, "fake.unit.timed_test", "unit")
    local results, timing = Execution.runSuite(suite, { capabilities = {} })
    Assert.equal(#results, 2)
    assertTimingInvariants(timing)
    Assert.isTrue(timing.beforeAll > 0, "successful beforeAll must contribute")
    Assert.isTrue(timing.afterAll > 0, "successful afterAll must contribute")
    Assert.isTrue(timing.tests > 0, "tests must contribute")
  end)
end

function T.layer_duration_is_suite_total_not_sum_of_result_durations()
  withFakeClock(function()
    local corpus = FakeCorpus.new({
      ["fake/unit/hooked_test.lua"] = {
        beforeAll = function() end,
        afterAll = function() end,
        tests = { ["a"] = function() end, ["b"] = function() end },
      },
    })
    local run = TestRunner.run({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })
    Assert.equal(run.passed, 2)
    Assert.notNil(run.suiteTimings, "run should expose suite timings")
    Assert.equal(#run.suiteTimings, 1)
    local timing = run.suiteTimings[1]
    assertTimingInvariants(timing)
    local resultSum = 0
    for _, entry in ipairs(run.results) do
      resultSum = resultSum + entry.duration
    end
    Assert.isTrue(timing.total > resultSum, "hook-inclusive total must exceed sum of result durations")
    Assert.isTrue(math.abs(run.byLayer.unit.duration - timing.total) < 1e-9, "layer duration equals suite total")
    Assert.isTrue(run.duration >= timing.total, "outer wall clock is at least suite total")
  end)
end

function T.filtered_suite_produces_no_timing_entry()
  withFakeClock(function()
    local corpus = FakeCorpus.new({
      ["fake/unit/alpha_test.lua"] = {
        beforeAll = function()
          error("hook must not run for filtered suite", 0)
        end,
        tests = { ["a"] = function() end },
      },
    })
    local run = TestRunner.run({
      roots = { corpus:root("fake/unit", "unit") },
      fs = corpus.fs,
      load = corpus.load,
      filter = "no such test",
    })
    Assert.equal(#run.results, 0)
    if run.suiteTimings ~= nil then
      Assert.equal(#run.suiteTimings, 0, "filtered suite must not produce timing")
    end
    Assert.isTrue(run.byLayer.unit == nil or run.byLayer.unit.duration == 0, "no layer duration for filtered suite")
  end)
end

function T.missing_capability_suite_has_zero_hook_timing()
  withFakeClock(function()
    local corpus = FakeCorpus.new({
      ["fake/rom/needs_dump_test.lua"] = {
        metadata = { capabilities = { "rom_dump" } },
        beforeAll = function()
          error("hook must not run without capability", 0)
        end,
        tests = { ["a"] = function() end },
      },
    })
    local run = TestRunner.run({
      roots = { corpus:root("fake/rom", "rom") },
      fs = corpus.fs,
      load = corpus.load,
      capabilities = {},
    })
    Assert.equal(run.skipped, 1)
    if run.suiteTimings ~= nil and #run.suiteTimings > 0 then
      local timing = run.suiteTimings[1]
      Assert.equal(timing.beforeAll, 0)
      Assert.equal(timing.afterAll, 0)
      Assert.equal(timing.tests, 0)
      Assert.equal(timing.total, 0)
    end
  end)
end

-- The default run is the fast tier: a suite marked slow is discovered but
-- excluded without running its hooks, hidden tests are counted so a focused
-- selection can explain itself, and listing shows only the fast suite.
function T.default_run_excludes_slow_suites_without_running_their_hooks()
  local slowHookRan = false
  local corpus = FakeCorpus.new({
    ["fake/unit/fast_test.lua"] = { tests = { ["fast case"] = function() end } },
    ["fake/unit/slow_test.lua"] = {
      metadata = { slow = true },
      beforeAll = function()
        slowHookRan = true
      end,
      tests = { ["slow case"] = function() end },
    },
  })
  local options = { roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load }

  local run = TestRunner.run(options)

  Assert.equal(run.passed, 1, "only the fast test executes by default")
  Assert.equal(run.failed, 0, "excluding a slow suite is not a failure")
  Assert.isFalse(slowHookRan, "an excluded slow suite must not run its hooks")
  Assert.equal(run.excludedSlow, 1, "the hidden slow test is counted")

  local listing = TestRunner.list(options)

  Assert.equal(#listing, 1, "default listing shows only the fast suite")
  Assert.equal(listing[1].module, "fake.unit.fast_test")
end

-- A suite rejected by its tags never reaches the slow gate, so a tag miss
-- counts nothing as hidden.
function T.tag_mismatch_does_not_count_as_hidden_slow()
  local corpus = FakeCorpus.new({
    ["fake/unit/slow_test.lua"] = {
      metadata = { slow = true, tags = { "door" } },
      tests = { ["slow case"] = function() end },
    },
  })
  local options = { roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load, tag = "camera" }

  local run = TestRunner.run(options)

  Assert.equal(run.passed, 0)
  Assert.equal(run.failed, 0)
  Assert.equal(run.excludedSlow, 0, "a suite rejected by tag is not hidden by the slow gate")
  Assert.equal(#TestRunner.list(options), 0, "a tag miss lists nothing")
end

-- The selected capability union follows the selection: unselected suites
-- contribute nothing, and one selected suite contributes every declared
-- capability exactly once no matter how many of its tests matched.
function T.selected_capabilities_follow_the_selection_without_duplicates()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      metadata = { capabilities = { "rom_dump", "derived_cache" } },
      tests = { ["a"] = function() end, ["b"] = function() end },
    },
    ["fake/unit/beta_test.lua"] = {
      metadata = { capabilities = { "rom_dump" } },
      tests = { ["c"] = function() end },
    },
  })
  local roots = { corpus:root("fake/unit", "unit") }
  local available = { rom_dump = true, derived_cache = true }

  local full = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, capabilities = available })
  Assert.deepEqual(full.selectedCapabilities, { rom_dump = true, derived_cache = true })

  local narrowed = TestRunner.run({
    roots = roots,
    fs = corpus.fs,
    load = corpus.load,
    capabilities = available,
    filter = "alpha_test :: a",
  })
  Assert.equal(narrowed.passed, 1)
  Assert.deepEqual(
    narrowed.selectedCapabilities,
    { rom_dump = true, derived_cache = true },
    "one selected suite contributes every declared capability once"
  )

  local beta = TestRunner.run({
    roots = roots,
    fs = corpus.fs,
    load = corpus.load,
    capabilities = available,
    filter = "beta_test",
  })
  Assert.deepEqual(beta.selectedCapabilities, { rom_dump = true }, "an unselected suite contributes nothing")

  local none = TestRunner.run({
    roots = roots,
    fs = corpus.fs,
    load = corpus.load,
    capabilities = available,
    filter = "no such test",
  })
  Assert.deepEqual(none.selectedCapabilities, {}, "an empty selection selects no capabilities")
end

-- A module that cannot load stays one visible failure and is never mistaken
-- for a suite hidden by the slow gate.
function T.load_failures_stay_visible_and_are_not_hidden_slow()
  local corpus = FakeCorpus.new({
    ["fake/unit/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
  })
  local options = { roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load }

  local run = TestRunner.run(options)

  Assert.equal(run.failed, 1)
  Assert.equal(run.excludedSlow, 0, "a load failure is not a hidden slow test")

  local listing = TestRunner.list(options)

  Assert.equal(#listing, 1, "a broken module is still listed")
  Assert.notNil(listing[1].error, "the broken suite carries its load error")
end

return { tests = T }
