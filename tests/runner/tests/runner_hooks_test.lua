-- Hook behaviour beyond the suite-execution contract: a setup that skips owns
-- the whole suite's precondition, and a cleanup that fails is a reported
-- failure rather than a swallowed error.

local Assert = require("tests.support.Assert")
local Execution = require("tests.runner.Execution")
local Suite = require("tests.runner.Suite")

local T = {}

local function runSuite(mod, options, selected)
  local suite = Suite.normalize(mod, "fake.rom.alpha_test", "rom")
  return Execution.runSuite(suite, options or { capabilities = {} }, selected)
end

local function statuses(results)
  local out = {}
  for _, entry in ipairs(results) do
    out[#out + 1] = entry.test .. "=" .. entry.status
  end
  table.sort(out)
  return out
end

function T.setup_skip_skips_every_test_of_the_suite()
  local executed = false
  local results = runSuite({
    beforeAll = function(context)
      context:skip("no ready user-owned HGSS dump")
    end,
    tests = {
      ["a"] = function()
        executed = true
      end,
      ["b"] = function()
        executed = true
      end,
    },
  })

  Assert.isFalse(executed, "a skipped setup must not run test bodies")
  Assert.deepEqual(statuses(results), { "a=skip", "b=skip" })
  Assert.equal(results[1].message, "no ready user-owned HGSS dump")
end

function T.cleanup_failure_is_reported_without_hiding_test_results()
  local results = runSuite({
    afterAll = function()
      error("release failed", 0)
    end,
    tests = { ["a"] = function() end },
  })

  Assert.deepEqual(statuses(results), { "<afterAll>=fail", "a=pass" })
  local cleanup = results[2]
  Assert.isTrue(
    tostring(cleanup.message):find("release failed", 1, true) ~= nil,
    "cleanup failure keeps its message: " .. tostring(cleanup.message)
  )
end

-- A suite with no selected tests runs no hooks either: setup may acquire
-- expensive resources nothing is going to use.
function T.filtered_out_suite_runs_no_hooks()
  local hooks = 0
  local results = runSuite({
    beforeAll = function()
      hooks = hooks + 1
    end,
    afterAll = function()
      hooks = hooks + 1
    end,
    tests = { ["a"] = function() end },
  }, { capabilities = {} }, {})

  Assert.equal(#results, 0)
  Assert.equal(hooks, 0)
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

function T.successful_setup_cost_is_in_timing_and_not_only_results()
  withFakeClock(function()
    local results, timing = runSuite({
      beforeAll = function() end,
      tests = { ["a"] = function() end },
    })
    Assert.notNil(timing, "timing expected")
    Assert.isTrue(timing.beforeAll > 0, "beforeAll pass must be timed")
    Assert.isTrue(timing.tests > 0, "tests must be timed")
    Assert.isTrue(math.abs(timing.total - (timing.beforeAll + timing.tests + timing.afterAll)) < 1e-9)
    local resultDuration = 0
    for _, e in ipairs(results) do
      if e.test == "a" then
        resultDuration = e.duration
      end
    end
    Assert.isTrue(timing.beforeAll > 0)
    Assert.isTrue(math.abs(timing.tests - resultDuration) < 1e-9)
  end)
end

function T.failed_setup_timing_is_charged_once_and_tests_do_not_run()
  withFakeClock(function()
    local results, timing = runSuite({
      beforeAll = function()
        error("boom", 0)
      end,
      afterAll = function() end,
      tests = { ["a"] = function() end },
    })
    Assert.notNil(timing)
    Assert.isTrue(timing.beforeAll > 0, "failed beforeAll must be timed")
    Assert.equal(timing.tests, 0)
    Assert.isTrue(timing.afterAll >= 0)
    Assert.isTrue(math.abs(timing.total - (timing.beforeAll + timing.tests + timing.afterAll)) < 1e-9)
    local hasBeforeAllFailure = false
    for _, e in ipairs(results) do
      if e.test == "<beforeAll>" then
        hasBeforeAllFailure = true
        Assert.isTrue(e.duration > 0)
        Assert.isTrue(math.abs(e.duration - timing.beforeAll) < 1e-9, "failure result duration matches timing")
      end
    end
    Assert.isTrue(hasBeforeAllFailure, "beforeAll failure must be present")
  end)
end

function T.skipped_setup_timing_is_charged_and_all_tests_skip()
  withFakeClock(function()
    local results, timing = runSuite({
      beforeAll = function(context)
        context:skip("nope")
      end,
      afterAll = function() end,
      tests = { ["a"] = function() end, ["b"] = function() end },
    })
    Assert.notNil(timing)
    Assert.isTrue(timing.beforeAll > 0, "skipped beforeAll must be timed")
    Assert.equal(timing.tests, 0)
    for _, e in ipairs(results) do
      Assert.equal(e.status, "skip")
    end
  end)
end

function T.failed_cleanup_timing_is_charged_without_hiding_test_results()
  withFakeClock(function()
    local results, timing = runSuite({
      afterAll = function()
        error("release failed", 0)
      end,
      tests = { ["a"] = function() end },
    })
    Assert.notNil(timing)
    Assert.isTrue(timing.afterAll > 0, "failed afterAll must be timed")
    Assert.isTrue(timing.tests > 0)
    Assert.isTrue(math.abs(timing.total - (timing.beforeAll + timing.tests + timing.afterAll)) < 1e-9)
    local found = false
    for _, e in ipairs(results) do
      if e.test == "<afterAll>" then
        found = true
        Assert.isTrue(math.abs(e.duration - timing.afterAll) < 1e-9)
      end
    end
    Assert.isTrue(found, "afterAll failure must be present")
  end)
end

function T.missing_capability_does_not_invent_hook_time()
  withFakeClock(function()
    local results, timing = runSuite({
      metadata = { capabilities = { "rom_dump" } },
      beforeAll = function()
        error("must not run", 0)
      end,
      tests = { ["a"] = function() end },
    }, { capabilities = {} })
    Assert.notNil(timing)
    Assert.equal(timing.beforeAll, 0)
    Assert.equal(timing.afterAll, 0)
    Assert.equal(timing.tests, 0)
    Assert.equal(timing.total, 0)
    Assert.equal(#results, 1)
    Assert.equal(results[1].status, "skip")
  end)
end

return { tests = T }
