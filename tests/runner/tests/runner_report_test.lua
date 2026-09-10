-- Contract tests for run reporting: the report must say what actually ran.
-- Skips are visible with their reason (a skipped suite must never read as a
-- silent success), counts are broken down per layer, and slow tests are named.

local Assert = require("tests.support.Assert")
local Report = require("tests.runner.Report")

local T = {}

local function contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function run(results, overrides)
  local out = {
    results = results,
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 1.5,
    byLayer = {},
    capabilities = {},
    selectedCapabilities = {},
    excludedSlow = 0,
  }
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

function T.skips_are_reported_with_reason_and_counts()
  local lines = Report.lines(run({
    {
      module = "tests.rom.dump_test",
      test = "reads the dump",
      status = "skip",
      message = "missing capability: rom_dump",
      layer = "rom",
      duration = 0,
    },
  }, {
    skipped = 1,
    byLayer = { rom = { passed = 0, failed = 0, skipped = 1, duration = 0 } },
  }))

  Assert.isTrue(contains(lines, "SKIP tests.rom.dump_test :: reads the dump"), "names the skipped test")
  Assert.isFalse(contains(lines, "\27[33mS\27[0m"), "report leaves skip markers to progress")
  Assert.isTrue(contains(lines, "missing capability: rom_dump"), "keeps the skip reason")
  Assert.isTrue(contains(lines, "0 passed, 0 failed, 1 skipped"), "counts the skip")
  Assert.isTrue(contains(lines, "rom"), "breaks counts down by layer")
end

function T.failures_are_detailed_with_the_slowest_one_named()
  local lines = Report.lines(run({
    {
      module = "libs.codec.tests.a_test",
      test = "quick",
      status = "fail",
      message = "boom quick",
      layer = "unit",
      duration = 0.01,
    },
    {
      module = "libs.codec.tests.b_test",
      test = "slow",
      status = "fail",
      message = "boom slow",
      layer = "unit",
      duration = 0.5,
    },
  }, {
    failed = 2,
    byLayer = { unit = { passed = 0, failed = 2, skipped = 0, duration = 0.51 } },
  }))

  Assert.isTrue(contains(lines, "FAIL libs.codec.tests.a_test :: quick"), "names each failure")
  Assert.isFalse(contains(lines, "\27[31mF\27[0m"), "report leaves failure markers to progress")
  Assert.isTrue(contains(lines, "boom slow"), "keeps failure messages")
  Assert.isTrue(contains(lines, "slowest failing: libs.codec.tests.b_test :: slow"), "names the slowest failure")
  Assert.isFalse(contains(lines, "slowest 1:"), "no slowest-five list while red")
end

function T.green_run_lists_the_slowest_passing_tests_and_capabilities()
  local results = {}
  for index = 1, 6 do
    results[index] = {
      module = "libs.codec.tests.a_test",
      test = "case " .. index,
      status = "pass",
      layer = "unit",
      duration = index / 100,
    }
  end

  local lines = Report.lines(run(results, {
    passed = 6,
    byLayer = { unit = { passed = 6, failed = 0, skipped = 0, duration = 0.21 } },
    capabilities = { graphics = true, rom_dump = true },
  }))

  Assert.isTrue(contains(lines, "slowest 1: libs.codec.tests.a_test :: case 6"), "slowest first")
  Assert.isTrue(contains(lines, "slowest 5: libs.codec.tests.a_test :: case 2"), "five entries")
  Assert.isFalse(contains(lines, "slowest 6:"), "at most five entries")
  Assert.isTrue(contains(lines, "capabilities: graphics, rom_dump"), "names detected capabilities")
end

-- `--list` shows what would run without executing it, including the metadata a
-- reader needs to select a layer, and does not hide a module that failed to load.
function T.listing_shows_layer_capabilities_tags_and_broken_modules()
  local lines = Report.listingLines({
    {
      module = "tests.rom.new_bark_test",
      layer = "rom",
      capabilities = { "rom_dump" },
      tags = { "field" },
      tests = { "warps home", "reads terrain" },
    },
    { module = "tests.rom.broken_test", layer = "rom", capabilities = {}, tags = {}, tests = {}, error = "boom" },
  })

  Assert.isTrue(contains(lines, "tests.rom.new_bark_test"), "names the module")
  Assert.isTrue(contains(lines, "rom"), "names the layer")
  Assert.isTrue(contains(lines, "rom_dump"), "names the capabilities")
  Assert.isTrue(contains(lines, "field"), "names the tags")
  Assert.isTrue(contains(lines, "2 tests"), "counts the tests")
  Assert.isTrue(contains(lines, "boom"), "a broken module is listed with its load error")
  Assert.isTrue(contains(lines, "2 suites"), "totals the listing")
end

function T.slowest_suites_are_ranked_by_total_and_slowest_tests_remain()
  local results = {}
  for index = 1, 3 do
    results[index] = {
      module = "libs.unit.a_test",
      test = "case " .. index,
      status = "pass",
      layer = "unit",
      duration = index / 100,
    }
  end
  local runData = run(results, {
    passed = 3,
    byLayer = { unit = { passed = 3, failed = 0, skipped = 0, duration = 0.06 } },
    suiteTimings = {
      { module = "libs.unit.heavy_test", layer = "unit", beforeAll = 0.2, tests = 0.05, afterAll = 0.01, total = 0.26 },
      { module = "libs.unit.light_test", layer = "unit", beforeAll = 0, tests = 0.02, afterAll = 0, total = 0.02 },
      { module = "libs.unit.medium_test", layer = "unit", beforeAll = 0.01, tests = 0.03, afterAll = 0, total = 0.04 },
    },
  })
  local lines = Report.lines(runData)
  Assert.isTrue(contains(lines, "slowest suite 1: libs.unit.heavy_test"), "heaviest suite first")
  local heavyIdx, mediumIdx, lightIdx
  for i, line in ipairs(lines) do
    if line:find("slowest suite 1: libs.unit.heavy_test", 1, true) then
      heavyIdx = i
    end
    if line:find("slowest suite 2: libs.unit.medium_test", 1, true) then
      mediumIdx = i
    end
    if line:find("slowest suite 3: libs.unit.light_test", 1, true) then
      lightIdx = i
    end
  end
  Assert.notNil(heavyIdx)
  Assert.notNil(mediumIdx)
  Assert.notNil(lightIdx)
  Assert.isTrue(heavyIdx < mediumIdx and mediumIdx < lightIdx, "suite ranking is descending by total")
  Assert.isTrue(contains(lines, "slowest 1:"), "existing slowest test output remains")
end

function T.report_tolerates_missing_suite_timings()
  local results = {
    { module = "libs.unit.a_test", test = "a", status = "pass", layer = "unit", duration = 0.01 },
  }
  local runData = run(results, {
    passed = 1,
    byLayer = { unit = { passed = 1, failed = 0, skipped = 0, duration = 0.01 } },
  })
  local lines = Report.lines(runData)
  Assert.isFalse(contains(lines, "slowest suite"), "no suite lines when timings absent")
  Assert.isTrue(contains(lines, "slowest 1:"), "still shows slowest tests")
end

return { tests = T }
