-- Focused ownership for deferred field-entry planning: the preparation
-- state polls its planning and runtime prerequisites with no loader,
-- builds its planning loader exactly once after readiness, overlaps
-- target demand with a pending runtime, never retries a failed build,
-- and never releases the borrowed loader on disposal.

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
      requestLogicalField = function()
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

-- Two-gate host for the overlapped entry contract: planning and runtime
-- readiness are independent interests, and every milestone demand is
-- logged so tests can prove demand ordering and urgency.
local function gatedHost(gates, log)
  return {
    requestMilestone = function(name, urgency)
      log[#log + 1] = { name = name, urgency = urgency }
      if name == "field-planning" then
        return gates.planning, gates.planningFailure
      end
      if name == "field-runtime" then
        return gates.runtime, gates.runtimeFailure
      end
      if name == "new-game-intro" then
        return true
      end
      return false
    end,
    requestLogicalField = function(mapId, urgency)
      gates.logicalCalls = gates.logicalCalls or {}
      gates.logicalCalls[#gates.logicalCalls + 1] = { mapId = mapId, urgency = urgency }
      if gates.logicalFailure ~= nil then
        return false, gates.logicalFailure
      end
      if gates.logical == nil then
        return true
      end
      return gates.logical
    end,
  }
end

local function gatedLoader(calls, behavior)
  local loader = {}
  function loader:globalPosition(_, fieldX, fieldZ)
    return { x = fieldX, z = fieldZ }
  end
  function loader:requestLocation(_, _, _, _)
    calls.requests = (calls.requests or 0) + 1
    return behavior.ready, behavior.failure
  end
  return loader
end

local function newGameOptions(gates, log, calls, behavior, overrides)
  local options = {
    kind = "newgame",
    candidate = {
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    },
    versionId = "heartgold",
    derivedAssets = gatedHost(gates, log),
    createLoader = function()
      return gatedLoader(calls, behavior)
    end,
    enterField = function()
      calls.transfers = (calls.transfers or 0) + 1
    end,
    onCancel = function() end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

function T.construction_builds_no_loader_while_readiness_is_pending()
  local builds = 0
  local pending = true
  local state = FieldPreparationState.new(continueOptions({
    derivedAssets = {
      requestMilestone = function()
        return not pending
      end,
      requestLogicalField = function()
        return true
      end,
    },
    createLoader = function()
      builds = builds + 1
      return readyGeometryLoader({})
    end,
  }))
  Assert.equal(state.phase, "planning")
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
  Assert.equal(state.phase, "location")
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
      requestLogicalField = function()
        return true
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

function T.new_game_demands_its_target_while_runtime_is_still_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false }))
  settle(state)
  Assert.isTrue((calls.requests or 0) >= 1, "planning readiness starts target location demand")
  Assert.equal(calls.transfers or 0, 0, "a pending runtime never transfers early")
  Assert.equal(state.phase, "location", "the state waits on the target while runtime is pending")
  state:dispose()
end

function T.transfer_waits_for_target_and_runtime_together()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local behavior = { ready = true }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, behavior))
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "a ready target alone never transfers")
  gates.runtime = true
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "the transfer runs once both closures are ready")
  Assert.equal(state.phase, "done")
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "settling never transfers twice")
  state:dispose()
end

function T.runtime_failure_is_visible_while_the_target_is_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false, runtimeFailure = "injected runtime failure" }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false }))
  settle(state)
  Assert.equal(state.phase, "failed", "a runtime failure fails preparation visibly")
  Assert.isTrue(
    string.find(tostring(state.error), "injected runtime failure", 1, true) ~= nil,
    "the runtime cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed runtime never transfers")
  settle(state)
  Assert.equal(state.phase, "failed")
  Assert.equal(calls.transfers or 0, 0, "the failure surfaces exactly once")
  state:dispose()
end

function T.target_failure_is_visible_while_runtime_is_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local state =
    FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false, failure = "injected target failure" }))
  settle(state)
  Assert.equal(state.phase, "failed", "a target failure fails preparation visibly")
  Assert.isTrue(
    string.find(tostring(state.error), "injected target failure", 1, true) ~= nil,
    "the target cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed target never transfers")
  state:dispose()
end

function T.cancelled_preparation_never_transfers_on_late_readiness()
  local log = {}
  local calls = {}
  local gates = { planning = false, runtime = false }
  local behavior = { ready = false }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, behavior))
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "nothing transfers while both closures are pending")
  state:keypressed("escape")
  gates.planning = true
  gates.runtime = true
  behavior.ready = true
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "late readiness never transfers a cancelled preparation")
  state:dispose()
end

function T.continue_rejects_a_save_without_a_field_location()
  local transfers = 0
  local state = FieldPreparationState.new(continueOptions({
    saveStore = {
      load = function(_, _)
        return { mapId = nil, fieldX = nil, fieldZ = nil }
      end,
    },
    enterField = function()
      transfers = transfers + 1
    end,
  }))
  settle(state)
  Assert.equal(state.phase, "failed", "an unvalidated save fails preparation visibly")
  Assert.equal(transfers, 0, "an unvalidated save never transfers")
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

function T.new_game_warms_the_destination_logical_closure_alongside_geometry()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true, logical = false }
  local loader = gatedLoader(calls, { ready = false })
  loader.world = { bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 }, maps = {} }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false }, {
    createLoader = function()
      return loader
    end,
  }))
  settle(state)
  local logicalCalls = gates.logicalCalls or {}
  Assert.isTrue(#logicalCalls >= 1, "the destination logical closure is demanded while geometry is pending")
  for _, demand in ipairs(logicalCalls) do
    Assert.equal(demand.mapId, 64, "warming names the resolved destination map")
    Assert.equal(demand.urgency, "required", "warming holds required urgency")
  end
  Assert.equal(calls.transfers or 0, 0, "a pending logical channel never transfers")
  Assert.equal(state.phase, "location")
  state:dispose()
end
function T.transfer_waits_for_the_warmed_destination_logical_closure()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true, logical = false }
  local loader = gatedLoader(calls, { ready = true })
  loader.world = { bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 }, maps = {} }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = true }, {
    createLoader = function()
      return loader
    end,
  }))
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "a pending logical channel holds the transfer")
  gates.logical = true
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "the transfer runs once the logical channel is terminal")
  Assert.equal(state.phase, "done")
  state:dispose()
end
function T.destination_logical_failure_is_visible_before_transfer()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true, logicalFailure = "injected logical failure" }
  local loader = gatedLoader(calls, { ready = true })
  loader.world = { bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 }, maps = {} }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = true }, {
    createLoader = function()
      return loader
    end,
  }))
  settle(state)
  Assert.equal(state.phase, "failed", "a logical failure fails preparation visibly")
  Assert.isTrue(
    string.find(tostring(state.error), "injected logical failure", 1, true) ~= nil,
    "the logical cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed logical channel never transfers")
  state:dispose()
end

return { tests = T }
