-- Focused ownership for deferred field-entry planning: the preparation
-- state polls field core with no loader, builds its planning loader exactly
-- once after readiness, never retries a failed build, and never releases
-- the borrowed loader on disposal.

local Assert = require("tests.support.Assert")
local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")

local T = {}

local function readyGeometryLoader(calls)
  local loader = {}
  function loader:globalPosition(_, fieldX, fieldZ)
    return { x = fieldX, z = fieldZ }
  end
  function loader:requestLocation(_, _, _, _)
    calls.requests = (calls.requests or 0) + 1
    return true
  end
  return loader
end

local function continueOptions(overrides)
  local options = {
    kind = "continue",
    saveId = "save-00000002",
    versionId = "heartgold",
    derivedAssets = {
      requestMilestone = function()
        return true
      end,
    },
    saveStore = {
      load = function(_, _)
        return { mapId = 60, fieldX = 684, fieldZ = 393 }
      end,
    },
    createLoader = function()
      return readyGeometryLoader({})
    end,
    enterField = function() end,
    onCancel = function() end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

local function settle(state)
  for _ = 1, 10 do
    state:update(1 / 60)
  end
end

function T.construction_builds_no_loader_while_core_is_pending()
  local builds = 0
  local pending = true
  local state = FieldPreparationState.new(continueOptions({
    derivedAssets = {
      requestMilestone = function()
        return not pending
      end,
    },
    createLoader = function()
      builds = builds + 1
      return readyGeometryLoader({})
    end,
  }))
  Assert.equal(state.phase, "core")
  settle(state)
  Assert.equal(builds, 0, "pending core never builds the planning loader")
  pending = false
  settle(state)
  Assert.equal(builds, 1, "readiness builds the planning loader exactly once")
  Assert.equal(state.phase, "done")
  state:dispose()
end

function T.geometry_polling_reuses_the_single_built_loader()
  local builds = 0
  local geometryPolls = 0
  local geometryReady = false
  local backing = {}
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      builds = builds + 1
      local loader = readyGeometryLoader(backing)
      function loader:requestLocation(_, _, _, _)
        geometryPolls = geometryPolls + 1
        return geometryReady
      end
      return loader
    end,
  }))
  settle(state)
  Assert.equal(builds, 1, "readiness builds the planning loader exactly once")
  Assert.equal(state.phase, "geometry")
  for _ = 1, 5 do
    state:update(1 / 60)
  end
  Assert.equal(builds, 1, "geometry polling never rebuilds the loader")
  Assert.isTrue(geometryPolls >= 5, "geometry polling reuses the retained loader")
  geometryReady = true
  settle(state)
  Assert.equal(builds, 1, "transfer still owns exactly one loader")
  Assert.equal(state.phase, "done")
  state:dispose()
end

function T.escape_before_readiness_never_builds_a_loader()
  local builds = 0
  local cancelled = 0
  local state = FieldPreparationState.new(continueOptions({
    derivedAssets = {
      requestMilestone = function()
        return false
      end,
    },
    createLoader = function()
      builds = builds + 1
      return readyGeometryLoader({})
    end,
    onCancel = function()
      cancelled = cancelled + 1
    end,
  }))
  settle(state)
  state:keypressed("escape")
  Assert.equal(builds, 0, "escape before readiness never builds a loader")
  Assert.equal(cancelled, 1)
  settle(state)
  Assert.equal(builds, 0, "a cancelled preparation never builds late")
  state:dispose()
end

function T.failed_loader_build_is_visible_and_never_retried()
  local builds = 0
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      builds = builds + 1
      error("injected world metadata failure", 0)
    end,
  }))
  settle(state)
  Assert.equal(state.phase, "failed", "a failed build fails preparation visibly")
  Assert.isTrue(state.error ~= nil, "the failure carries its diagnostic")
  Assert.equal(
    string.find(tostring(state.error), "injected world metadata failure", 1, true) ~= nil,
    true,
    "the original build error is preserved"
  )
  Assert.equal(builds, 1, "the failed build ran exactly once")
  for _ = 1, 5 do
    state:update(1 / 60)
  end
  Assert.equal(builds, 1, "a failed build is never retried")
  Assert.equal(state.phase, "failed")
  state:dispose()
end

function T.disposal_drops_references_without_releasing_the_borrowed_loader()
  local releases = 0
  local loader = readyGeometryLoader({})
  function loader:release()
    releases = releases + 1
  end
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      return loader
    end,
  }))
  settle(state)
  Assert.equal(state.phase, "done")
  state:dispose()
  Assert.equal(releases, 0, "the borrowed loader is never released by state disposal")
end

return { tests = T }
