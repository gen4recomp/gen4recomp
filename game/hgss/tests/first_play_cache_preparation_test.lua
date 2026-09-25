-- Fresh-import first-play demand tests. After raw ROM extraction, the menu
-- must wait until the existing global milestones plus the exact initial
-- bedroom closure are current under one provisioner epoch. These tests drive
-- the HGSS preparation coordinator through the app-facing factory with a
-- recording derived host and spies on the location seams; the coordinator
-- owns which closures constitute first play but no production mechanism.

local Assert = require("tests.support.Assert")
local HgssGame = require("game.hgss.src.HgssGame")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")

local T = {}

local PLAYER_ROOM = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = "south" }
local GLOBAL_BEDROOM = { x = 101, z = 202 }

-- A derived host stand-in with scripted per-milestone answers. Calls follow
-- the production host convention: plain function fields invoked without a
-- receiver, recording every name/urgency pair for exact-set assertions.
local function fakeHost(script)
  local calls = {}
  local host = {}
  function host.requestMilestone(name, urgency)
    calls[#calls + 1] = { name = name, urgency = urgency }
    if script.failures[name] ~= nil then
      return nil, script.failures[name]
    end
    if script.ready[name] then
      return true, nil
    end
    return nil, nil
  end
  function host.status()
    return { bootstrap = "pending" }
  end
  return host, calls
end

local function readySet(names)
  local ready = {}
  for _, name in ipairs(names) do
    ready[name] = true
  end
  return ready
end

-- Replaces the loader constructor with a recording stand-in so tests observe
-- the coordinator's demand wiring: one construction, one local-to-global
-- conversion, then required-urgency location demand. Restored by withSpies.
local function spyLoader(script)
  local originalNew = FieldMapLoader.new
  local state = { constructions = {}, conversions = {}, demands = {}, releases = 0 }
  FieldMapLoader.new = function(cacheFs, world, options)
    state.constructions[#state.constructions + 1] = { cacheFs = cacheFs, world = world, options = options }
    local loader = {}
    function loader:globalPosition(symbol, localX, localZ)
      state.conversions[#state.conversions + 1] = { symbol = symbol, x = localX, z = localZ }
      return { x = GLOBAL_BEDROOM.x, z = GLOBAL_BEDROOM.z }
    end
    function loader:requestLocation(symbol, fieldX, fieldZ, urgency)
      state.demands[#state.demands + 1] = { symbol = symbol, x = fieldX, z = fieldZ, urgency = urgency }
      if script.locationFailure ~= nil then
        return nil, script.locationFailure
      end
      if script.locationReady then
        return true, nil
      end
      return nil, nil
    end
    function loader:release()
      state.releases = state.releases + 1
    end
    return loader
  end
  return state, originalNew
end

-- Each scenario is named for the user-visible wait it locks: the menu stays
-- down while the bounded first-play closure is pending, then hands over the
-- same epoch once the exact bedroom demand resolves.

-- Records generated-location reads through the game-owned accessor seam.
local function spyLocation()
  local original = NewGameInitialization.initialLocation
  local state = { reads = 0, versionId = nil }
  NewGameInitialization.initialLocation = function(versionId)
    state.reads = state.reads + 1
    state.versionId = versionId
    return {
      mapSymbol = PLAYER_ROOM.mapSymbol,
      fieldX = PLAYER_ROOM.fieldX,
      fieldZ = PLAYER_ROOM.fieldZ,
      facing = PLAYER_ROOM.facing,
    }
  end
  return state, original
end

local function withSpies(script, fn)
  local loaderState, originalNew = spyLoader(script)
  local locationState, originalLocation = spyLocation()
  -- The structural world manifest is a filesystem fixture the component
  -- sandbox does not provide: stub the version-cache read so the
  -- coordinator's CacheFs/worldPath load reaches the spied loader
  -- constructor exactly as the production recipe prescribes. The stub
  -- carries no milestone/location/loader semantics; every assertion below
  -- observes the coordinator's own demand wiring.
  local originalForVersion = CacheFs.forVersion
  rawset(CacheFs, "forVersion", function(_)
    local cacheFs = {}
    function cacheFs.loadLua(_, path)
      Assert.equal(path, MapAssetCache.worldPath())
      return { schema = "fixture-world" }
    end
    return cacheFs
  end)
  local ok, err = xpcall(function()
    fn(loaderState, locationState)
  end, function(failure)
    return failure
  end)
  FieldMapLoader.new = originalNew
  NewGameInitialization.initialLocation = originalLocation
  rawset(CacheFs, "forVersion", originalForVersion)
  if not ok then
    error(err, 0)
  end
end

local function newPreparation(host, versionId, completion)
  local factory = HgssGame.newFirstPlayCachePreparation
  Assert.notNil(factory, "HgssGame must expose the first-play preparation factory used after a fresh import")
  return factory({ versionId = versionId or "heartgold", derivedAssets = host, completion = completion })
end

-- A completion gateway stand-in: the generation the controller has derived
-- so far (nil while the selection answer is still in flight) plus the
-- durable attestation answers owned by the import orchestration boundary.
local function completionGateway(script)
  return {
    hasStored = function()
      return script.stored == true
    end,
    isCurrent = function(_)
      return script.current == true
    end,
    currentGeneration = function()
      return script.generation
    end,
  }
end

local function milestoneNames(calls)
  local names = {}
  for _, call in ipairs(calls) do
    names[#names + 1] = call.name
  end
  table.sort(names)
  return names
end

function T.pending_milestones_request_the_exact_first_play_set_without_readiness()
  local script = { ready = {}, failures = {} }
  withSpies(script, function(loaderState, locationState)
    local host, calls = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "pending milestones carry no failure")
    Assert.isFalse(ready == true, "first-play preparation is not ready while its milestones are pending")
    Assert.deepEqual(
      milestoneNames(calls),
      { "bootstrap", "field-planning", "field-runtime", "new-game-intro" },
      "preparation requests exactly the existing global set, never a copied job list"
    )
    for _, call in ipairs(calls) do
      Assert.equal(call.urgency, "required", "first-play milestone demand is always required urgency")
    end
    Assert.equal(locationState.reads, 0, "the generated location is unread while its milestone is pending")
    Assert.equal(#loaderState.constructions, 0, "no planning loader exists before planning metadata is ready")
  end)
end

function T.ready_bootstrap_still_requests_every_milestone_in_the_first_poll()
  local script = { ready = readySet({ "bootstrap" }), failures = {} }
  withSpies(script, function(_, _)
    local host, calls = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "a ready bootstrap carries no failure")
    Assert.isFalse(ready == true, "one ready milestone never completes first-play preparation")
    Assert.deepEqual(
      milestoneNames(calls),
      { "bootstrap", "field-planning", "field-runtime", "new-game-intro" },
      "milestone demands overlap in the same poll instead of serializing behind bootstrap"
    )
  end)
end

function T.generated_location_stays_unread_until_its_milestone_is_ready()
  local script = { ready = readySet({ "bootstrap", "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState, locationState)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "pending intro carries no failure")
    Assert.isFalse(ready == true, "preparation waits for the intro milestone")
    Assert.equal(locationState.reads, 0, "generated start data is unread before intro readiness makes it current")
    Assert.equal(#loaderState.constructions, 0, "no loader is built while planning waits on intro")
  end)
end

function T.planning_loader_waits_for_planning_metadata()
  local script = { ready = readySet({ "bootstrap", "new-game-intro" }), failures = {} }
  withSpies(script, function(loaderState, _)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local _, failure = preparation:poll()
    Assert.isNil(failure, "pending planning carries no failure")
    Assert.equal(#loaderState.constructions, 0, "the structural loader is built only after planning is ready")
  end)
end

function T.bedroom_demand_uses_the_exact_runtime_location_closure()
  local script = {
    ready = readySet({ "bootstrap", "new-game-intro", "field-planning" }),
    failures = {},
    locationReady = false,
  }
  withSpies(script, function(loaderState, locationState)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "pending bedroom demand carries no failure")
    Assert.isFalse(ready == true, "preparation waits for the bedroom closure")
    Assert.equal(locationState.versionId, "heartgold", "the generated location is read for the selected version")
    Assert.equal(#loaderState.constructions, 1, "one metadata-only planning loader serves the import")
    Assert.deepEqual(
      loaderState.conversions,
      { { symbol = PLAYER_ROOM.mapSymbol, x = PLAYER_ROOM.fieldX, z = PLAYER_ROOM.fieldZ } },
      "map-local start coordinates convert through the loader, never assumed global"
    )
    Assert.deepEqual(loaderState.demands, {
      {
        symbol = PLAYER_ROOM.mapSymbol,
        x = GLOBAL_BEDROOM.x,
        z = GLOBAL_BEDROOM.z,
        urgency = "required",
      },
    }, "bedroom readiness follows the runtime location demand at required urgency")
    script.locationReady = true
    local laterReady, laterFailure = preparation:poll()
    Assert.isNil(laterFailure, "resolved bedroom demand carries no failure")
    Assert.isFalse(laterReady == true, "a resolved bedroom closure still waits for the pending field-runtime milestone")
    script.ready["field-runtime"] = true
    local finalReady, finalFailure = preparation:poll()
    Assert.isNil(finalFailure, "the joined closure carries no failure")
    Assert.isTrue(finalReady == true, "all four milestones plus the bedroom closure report ready together")
  end)
end

function T.planning_loader_and_target_are_built_once_across_polls()
  local script = {
    ready = readySet({ "bootstrap", "new-game-intro", "field-planning" }),
    failures = {},
    locationReady = false,
  }
  withSpies(script, function(loaderState, _)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    for _ = 1, 3 do
      local ready, failure = preparation:poll()
      Assert.isNil(failure, "repeated pending polls carry no failure")
      Assert.isFalse(ready == true, "repeated polls stay pending with the bedroom closure")
    end
    Assert.equal(#loaderState.constructions, 1, "the planning loader is constructed once, not per poll")
    Assert.equal(#loaderState.conversions, 1, "the local start is globalized once, not per poll")
  end)
end

function T.milestone_failure_blocks_readiness()
  local script = {
    ready = readySet({ "bootstrap", "new-game-intro", "field-planning" }),
    failures = { ["field-runtime"] = "field runtime failed in the fixture" },
  }
  withSpies(script, function(_, _)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isFalse(ready == true, "a failed milestone never reports readiness")
    Assert.notNil(failure, "the milestone failure becomes the preparation failure")
    local laterReady, laterFailure = preparation:poll()
    Assert.isFalse(laterReady == true, "a latched failure never recovers into readiness")
    Assert.notNil(laterFailure, "the latched failure persists")
  end)
end

function T.bedroom_failure_propagates_for_diagnosis()
  local script = {
    ready = readySet({ "bootstrap", "new-game-intro", "field-planning", "field-runtime" }),
    failures = {},
    locationFailure = "bedroom plot is missing in the fixture",
  }
  withSpies(script, function(_, _)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, failure = preparation:poll()
    Assert.isFalse(ready == true, "a failed bedroom closure never reports readiness")
    Assert.equal(failure, "bedroom plot is missing in the fixture", "the location failure propagates unchanged")
  end)
end

function T.disposal_releases_the_loader_once_and_blocks_transfer()
  local script = {
    ready = readySet({ "bootstrap", "new-game-intro", "field-planning", "field-runtime" }),
    failures = {},
    locationReady = true,
  }
  withSpies(script, function(loaderState, _)
    local host, _ = fakeHost(script)
    local preparation = newPreparation(host)
    local ready, _ = preparation:poll()
    Assert.isTrue(ready == true, "the scripted closure reports ready before disposal")
    preparation:dispose()
    Assert.equal(loaderState.releases, 1, "disposal releases the constructed planning loader")
    preparation:dispose()
    Assert.equal(loaderState.releases, 1, "repeated disposal releases the loader exactly once")
    local pollOk, afterReady = pcall(function()
      return preparation:poll()
    end)
    Assert.isTrue(pollOk, "polling after disposal stays safe")
    Assert.isFalse(afterReady == true, "a disposed preparation can never transfer readiness")
  end)
end

function T.construction_validates_its_selection_inputs()
  local factory = HgssGame.newFirstPlayCachePreparation
  Assert.notNil(factory, "HgssGame must expose the first-play preparation factory used after a fresh import")
  local host, _ = fakeHost({ ready = {}, failures = {} })
  Assert.throws(function()
    factory({ versionId = "heartgold" })
  end, "preparation requires its borrowed derived host")
  Assert.throws(function()
    factory({ derivedAssets = host })
  end, "preparation requires its selected version")
end

function T.current_completion_reports_ready_without_any_closure_demand()
  local script = { ready = {}, failures = {}, generation = "current-generation", current = true, stored = true }
  withSpies(script, function(loaderState, locationState)
    local host, calls = fakeHost(script)
    local preparation = newPreparation(host, "heartgold", completionGateway(script))
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "a current completion carries no failure")
    Assert.isTrue(ready == true, "a current completion transfers without compiling the closure")
    Assert.equal(#calls, 0, "a current completion demands no milestone while transferring")
    Assert.equal(locationState.reads, 0, "a current completion never reads the generated location")
    Assert.equal(#loaderState.constructions, 0, "a current completion builds no planning loader")
  end)
end

function T.unknown_generation_with_a_stored_completion_waits_without_demands()
  local script = { ready = {}, failures = {}, generation = nil, current = false, stored = true }
  withSpies(script, function(_, locationState)
    local host, calls = fakeHost(script)
    local preparation = newPreparation(host, "heartgold", completionGateway(script))
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "waiting for the generation carries no failure")
    Assert.isFalse(ready == true, "an unvalidated completion never transfers")
    Assert.equal(#calls, 0, "no milestone is demanded while currency is still unknown")
    Assert.equal(locationState.reads, 0, "no location is read while currency is still unknown")
    script.generation = "current-generation"
    script.current = true
    local laterReady, laterFailure = preparation:poll()
    Assert.isNil(laterFailure, "the validated completion carries no failure")
    Assert.isTrue(laterReady == true, "the validated completion transfers without closure demands")
    Assert.equal(#calls, 0, "the transfer demands no milestone")
  end)
end

function T.stale_completion_demands_the_full_closure()
  local script = { ready = {}, failures = {}, generation = "next-generation", current = false, stored = true }
  withSpies(script, function(_, _)
    local host, calls = fakeHost(script)
    local preparation = newPreparation(host, "heartgold", completionGateway(script))
    local ready, failure = preparation:poll()
    Assert.isNil(failure, "a stale completion carries no failure")
    Assert.isFalse(ready == true, "a stale completion never transfers directly")
    Assert.deepEqual(
      milestoneNames(calls),
      { "bootstrap", "field-planning", "field-runtime", "new-game-intro" },
      "a stale completion recompiles the exact first-play set"
    )
  end)
end

return { tests = T }
