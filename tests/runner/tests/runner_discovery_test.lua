-- Contract tests for the capability-aware runner's discovery, listing, and
-- selection. Discovery is recursive over approved roots and is the only source
-- of truth: no hand-maintained module registry may exist. Listing reports
-- layer/capability metadata without executing any test body.
--
-- Suffix rule under test: a file is a suite exactly when its name ends in
-- `_test.lua`; the plural `_tests.lua` spelling is not discovered.

local Assert = require("tests.support.Assert")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local Discovery = require("tests.runner.Discovery")
local Selection = require("tests.runner.Selection")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

function T.tree_discovery_derives_modules_and_layers_from_tests_directories()
  local corpus = FakeCorpus.new({
    ["tests/graphics/shader_test.lua"] = { tests = { ["draws"] = function() end } },
    ["app/tests/app_test.lua"] = { tests = { ["boots"] = function() end } },
    ["game/tests/application_test.lua"] = { tests = { ["boots"] = function() end } },
    ["game/hgss/tests/hgss_test.lua"] = { tests = { ["boots"] = function() end } },
    ["game/hgss/tests/audio/game_audio_test.lua"] = { tests = { ["plays"] = function() end } },
    ["libs/codec/tests/binary_test.lua"] = { tests = { ["reads"] = function() end } },
    ["libs/codec/tests/nested/helper_test.lua"] = { tests = { ["reads"] = function() end } },
    ["tmp/refs/legacy/tests/example_silly_oak_test.lua"] = { tests = { ["legacy"] = function() end } },
  })

  local suites = Discovery.suites(corpus.fs)
  local layers = {}
  for _, suite in ipairs(suites) do
    layers[suite.module] = suite.layer
  end

  Assert.equal(layers["tests.graphics.shader_test"], "graphics")
  Assert.equal(layers["game.tests.application_test"], "component")
  Assert.equal(layers["game.hgss.tests.hgss_test"], "component")
  Assert.equal(layers["game.hgss.tests.audio.game_audio_test"], "component")
  Assert.equal(layers["app.tests.app_test"], "component")
  Assert.equal(layers["libs.codec.tests.binary_test"], "unit")
  Assert.equal(layers["libs.codec.tests.nested.helper_test"], "unit")
  Assert.isNil(layers["tmp.refs.legacy.tests.example_silly_oak_test"], "reference trees are not test sources")
end

local function moduleNames(listing)
  local out = {}
  for _, suite in ipairs(listing) do
    out[#out + 1] = suite.module
  end
  return out
end

-- Raises when absent so a missing suite fails as a listing defect rather than
-- as a nil index further down the test.
---@return { module: string, layer: string, capabilities: string[], tags: string[], tests: string[] }
---@param listing table[]
---@param moduleName string
local function find(listing, moduleName)
  for _, suite in ipairs(listing) do
    if suite.module == moduleName then
      return suite
    end
  end
  error("listing has no suite " .. moduleName, 2)
end

-- nested suites are discovered; non-suite files are not.
function T.discovery_finds_nested_suites_and_ignores_other_files()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["a"] = function() end } },
    ["fake/unit/nested/deep/beta_test.lua"] = { tests = { ["b"] = function() end } },
    ["fake/unit/support/Helper.lua"] = {},
    ["fake/unit/nested/notes.md"] = {},
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.deepEqual(moduleNames(listing), { "fake.unit.alpha_test", "fake.unit.nested.deep.beta_test" })
end

-- The repository controls every suite filename, so the plural spelling is
-- dropped: a file named `_tests.lua` is not a suite.
function T.plural_suffix_is_no_longer_discovered()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["a"] = function() end } },
    ["fake/unit/alpha_tests.lua"] = { tests = { ["plural"] = function() end } },
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.deepEqual(moduleNames(listing), { "fake.unit.alpha_test" })
end

-- A module under a root the selection excludes must not even load: a broken
-- or environment-dependent suite under a foreign layer must not break a
-- unit-only run, and must not execute its module body in it. The root is the
-- only classifier, so a component-root module is excluded exactly like a
-- graphics-root one.
function T.excluded_layer_modules_are_not_loaded()
  local loads = {}
  local corpus = FakeCorpus.new({
    ["fake/gfx/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
    ["fake/comp/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
    ["fake/unit/ok_test.lua"] = { tests = { ["passes"] = function() end } },
  })
  local options = {
    roots = {
      corpus:root("fake/gfx", "graphics"),
      corpus:root("fake/comp", "component"),
      corpus:root("fake/unit", "unit"),
    },
    fs = corpus.fs,
    layer = "unit",
    capabilities = {},
    load = function(moduleName)
      loads[#loads + 1] = moduleName
      return corpus.load(moduleName)
    end,
  }

  local run = TestRunner.run(options)

  Assert.deepEqual(loads, { "fake.unit.ok_test" }, "only matching-root modules load")
  Assert.equal(run.passed, 1)
  Assert.equal(run.failed, 0)
  Assert.equal(run.skipped, 0)
end

-- order is deterministic and independent of filesystem order.
function T.discovery_order_is_sorted_not_filesystem_order()
  local corpus = FakeCorpus.new({
    ["fake/unit/zulu_test.lua"] = { tests = { ["z second"] = function() end, ["a first"] = function() end } },
    ["fake/unit/alpha_test.lua"] = { tests = { ["only"] = function() end } },
    ["fake/unit/mike_test.lua"] = { tests = { ["only"] = function() end } },
  })
  local options = { roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load }

  local listing = TestRunner.list(options)

  Assert.deepEqual(moduleNames(listing), { "fake.unit.alpha_test", "fake.unit.mike_test", "fake.unit.zulu_test" })
  Assert.deepEqual(find(listing, "fake.unit.zulu_test").tests, { "a first", "z second" })
  Assert.deepEqual(moduleNames(TestRunner.list(options)), moduleNames(listing))
end

-- a module name reachable from two roots is a hard error, not a
-- silently doubled or dropped suite.
function T.duplicate_module_name_is_rejected()
  local corpus = FakeCorpus.new({ ["fake/unit/alpha_test.lua"] = { tests = { ["a"] = function() end } } })
  local root = corpus:root("fake/unit", "unit")

  local err = Assert.throws(function()
    TestRunner.list({ roots = { root, root }, fs = corpus.fs, load = corpus.load })
  end)

  Assert.isTrue(
    tostring(err):find("fake.unit.alpha_test", 1, true) ~= nil,
    "error names the duplicate module: " .. tostring(err)
  )
end

-- listing the corpus never runs a test body.
function T.listing_does_not_execute_test_bodies()
  local executed = false
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = {
      tests = {
        ["explodes when executed"] = function()
          executed = true
          error("test body must not run during --list", 0)
        end,
      },
    },
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/unit", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(#listing, 1)
  Assert.deepEqual(listing[1].tests, { "explodes when executed" })
  Assert.isFalse(executed, "listing executed a test body")
end

-- explicit metadata is surfaced; a module's layer comes from the root it
-- was discovered under, and a module with no metadata declares no
-- capabilities.
function T.listing_reports_layer_capabilities_and_tags()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["a"] = function() end } },
    ["fake/acc/lab_test.lua"] = {
      metadata = { capabilities = { "rom_dump", "derived_cache" }, tags = { "field" } },
      beforeAll = function() end,
      afterAll = function() end,
      tests = { ["lab exit round trip"] = function() end },
    },
  })

  local listing = TestRunner.list({
    roots = { corpus:root("fake/acc", "acceptance"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
  })

  local unit = find(listing, "fake.unit.alpha_test")
  Assert.equal(unit.layer, "unit")
  Assert.deepEqual(unit.capabilities, {})
  local acceptance = find(listing, "fake.acc.lab_test")
  Assert.equal(acceptance.layer, "acceptance")
  Assert.deepEqual(acceptance.capabilities, { "rom_dump", "derived_cache" })
  Assert.deepEqual(acceptance.tags, { "field" })
  -- metadata/beforeAll/afterAll keys are not tests
  Assert.deepEqual(acceptance.tests, { "lab exit round trip" })
end

-- layer selection runs only the selected layer.
function T.layer_selection_runs_only_that_layer()
  local ran = {}
  local function record(label)
    return function()
      ran[#ran + 1] = label
    end
  end
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["unit case"] = record("unit") } },
    ["fake/gfx/shader_test.lua"] = { tests = { ["graphics case"] = record("graphics") } },
  })
  local options = {
    roots = { corpus:root("fake/gfx", "graphics"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
  }

  options.layer = "unit"
  local result = TestRunner.run(options)

  Assert.deepEqual(ran, { "unit" })
  Assert.equal(result.passed, 1)
  Assert.equal(result.failed, 0)
  Assert.equal(result.skipped, 0)
end

-- filter matches against the fully qualified module :: test name.
function T.filter_matches_qualified_module_and_test_name()
  local corpus = FakeCorpus.new({
    ["fake/unit/warp_test.lua"] = {
      tests = { ["resolves door"] = function() end, ["resolves stairs"] = function() end },
    },
    ["fake/unit/camera_test.lua"] = { tests = { ["resolves door"] = function() end, ["pans"] = function() end } },
  })
  local roots = { corpus:root("fake/unit", "unit") }

  local byModule = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "warp_test" })
  Assert.equal(byModule.passed, 2)

  local byTest = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "pans" })
  Assert.equal(byTest.passed, 1)

  local byBoth = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "resolves door" })
  Assert.equal(byBoth.passed, 2)
end

-- A filter is literal text, not a Lua pattern: metacharacters select nothing
-- unless the qualified name really contains them.
function T.filter_treats_pattern_metacharacters_literally()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["a"] = function() end } },
  })
  local roots = { corpus:root("fake/unit", "unit") }

  local byClass = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "%a" })
  Assert.equal(byClass.passed, 0, "`%a` must not act as a character class")

  local byAnchor = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "^fake%.unit" })
  Assert.equal(byAnchor.passed, 0, "`^` must not anchor and `%.` must not escape")

  local byText = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "alpha_test" })
  Assert.equal(byText.passed, 1, "a plain substring still selects")
end

-- Layer, tag, filter, and slow eligibility compose conjunctively with literal
-- matching: only tests satisfying every selector run, and filter
-- metacharacters select literally instead of acting as patterns.
function T.tag_filter_layer_and_slow_select_conjunctively_with_literal_matching()
  local corpus = FakeCorpus.new({
    ["fake/rom/door_test.lua"] = {
      metadata = { tags = { "door" } },
      tests = {
        ["resolves (door)"] = function() end,
        ["pans camera"] = function() end,
      },
    },
    ["fake/rom/camera_test.lua"] = {
      metadata = { tags = { "camera" } },
      tests = { ["resolves (door)"] = function() end },
    },
    ["fake/unit/door_test.lua"] = {
      metadata = { tags = { "door" } },
      tests = { ["resolves (door)"] = function() end },
    },
    ["fake/rom/slow_door_test.lua"] = {
      metadata = { tags = { "door" }, slow = true },
      tests = {
        ["resolves (door) slowly"] = function() end,
        ["unrelated census"] = function() end,
      },
    },
  })

  local run = TestRunner.run({
    roots = { corpus:root("fake/rom", "rom"), corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    layer = "rom",
    tag = "door",
    slow = true,
    filter = "resolves (door)",
  })

  Assert.equal(run.failed, 0, "selecting tagged slow suites is not a failure")
  local selected = {}
  for _, entry in ipairs(run.results) do
    if entry.status == "pass" then
      selected[#selected + 1] = Selection.qualify(entry.module, entry.test)
    end
  end
  table.sort(selected)
  Assert.deepEqual(selected, {
    "fake.rom.door_test :: resolves (door)",
    "fake.rom.slow_door_test :: resolves (door) slowly",
  })
end

return { tests = T }
