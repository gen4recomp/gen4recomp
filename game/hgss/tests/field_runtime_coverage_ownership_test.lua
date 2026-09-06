-- FieldRuntime owns the committed physical coverage. A transition may stage a
-- replacement, but only a successful commit transfers ownership; teardown is
-- repeat-safe for every committed owner.

local Assert = require("tests.support.Assert")
local FieldNavigationBoundary = require("libs.hgss.src.world.FieldNavigationBoundary")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

local T = {}

local function releaseSpy(name, matrixMemberId, anchorX, anchorZ)
  local spy = {
    name = name,
    matrixMemberId = matrixMemberId,
    anchorX = anchorX,
    anchorZ = anchorZ,
    releases = 0,
    released = false,
    probes = 0,
  }
  function spy:release()
    Assert.isFalse(self.released, self.name .. " must not be released twice")
    self.released = true
    self.releases = self.releases + 1
  end
  function spy:mapHeaderAt()
    Assert.isFalse(self.released, self.name .. " must remain usable")
    self.probes = self.probes + 1
    return 60
  end
  function spy:probe()
    Assert.isFalse(self.released, self.name .. " must remain usable")
    self.probes = self.probes + 1
    return self.name
  end
  return spy
end

local function newSourceMap()
  return { mapId = 61 }
end

local function outdoorMap(coverage)
  return {
    mapId = 60,
    scene = { type = "outdoor" },
    coverage = coverage,
  }
end

local function runtimeForSwap(sourceCoverage)
  local sourceRuntimeMap = { mapId = 61 }
  local runtime = setmetatable({
    physicalCoverage = sourceCoverage,
    runtimeMap = sourceRuntimeMap,
    transition = FieldTransition.new({ loader = {}, prepare = function() end, commit = function() end }),
    session = { beginMapEntry = function() end },
    zoneController = { currentMap = sourceRuntimeMap },
    fieldTerrainEffectController = { clear = function() end },
    actors = { leaveMap = function() end, dispose = function() end },
    mapLoader = { protectMap = function() end, release = function() end },
    residency = {
      commitTransition = function() end,
      discardTransition = function() end,
      dispose = function() end,
    },
    scripts = { onMapSwap = function() end },
  }, FieldRuntime)
  runtime.worldSwapCoordinator = FieldWorldSwapCoordinator.new(runtime)
  return runtime, sourceRuntimeMap
end

local function stagingRuntime(sourceCoverage, replacementCoverage)
  local runtime = runtimeForSwap(sourceCoverage)
  local calls = {}
  runtime.mapLoader.createPhysicalCoverage = function(_, logicalMap, position)
    calls[#calls + 1] = { logicalMap = logicalMap, position = position }
    return replacementCoverage
  end
  return runtime, calls
end

local function stage(runtime, logicalMap, position, matrixMemberId)
  return runtime:_stagePhysicalCoverage(logicalMap --[[@as RuntimeFieldMap]], position, matrixMemberId)
end

local function destinationTerrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function destinationCollision()
  return {
    containsLocal = function(_, localX, localZ)
      return localX >= 0 and localX < 32 and localZ >= 0 and localZ < 32
    end,
  }
end

function T.same_matrix_non_anchor_warp_stages_a_destination_centered_owner()
  local sourceCoverage = releaseSpy("source", 7, 0, 0)
  local replacementCoverage = releaseSpy("replacement", 7, 1, 0)
  local runtime, calls = stagingRuntime(sourceCoverage, replacementCoverage)
  local destination = outdoorMap(replacementCoverage)
  local position = { fieldX = 32 + 5, fieldZ = 11 }

  local staged = stage(runtime, destination, position, 7)

  Assert.equal(staged.coverage, replacementCoverage)
  Assert.isTrue(staged.replacement)
  Assert.equal(staged.previous, sourceCoverage)
  Assert.equal(staged.state, "prepared")
  Assert.equal(#calls, 1)
  Assert.equal(calls[1].logicalMap, destination)
  Assert.deepEqual(calls[1].position, position)
  Assert.equal(runtime.physicalCoverage, sourceCoverage)
  Assert.equal(sourceCoverage.releases, 0)

  local reused = stage(runtime, destination, { fieldX = 5, fieldZ = 11 }, 7)

  Assert.equal(reused.coverage, sourceCoverage)
  Assert.isFalse(reused.replacement)
  Assert.isNil(reused.previous)
  Assert.equal(reused.state, "prepared")
  Assert.equal(#calls, 1)
end

function T.far_same_matrix_warp_supplies_destination_terrain_before_resolution()
  local sourceCoverage = releaseSpy("source", 7, 0, 0)
  local replacementCoverage = releaseSpy("replacement", 7, 4, 0)
  replacementCoverage.terrain = destinationTerrain()
  local runtime, calls = stagingRuntime(sourceCoverage, replacementCoverage)
  local destination = outdoorMap(replacementCoverage)
  destination.coordinateOrigin = { x = 4 * 32, z = 0 }
  destination.fieldData = {
    events = {
      warps = {
        { index = 0, x = 4 * 32 + 8, z = 16, y = 0, destinationMapId = 61, destinationWarpId = 0 },
      },
    },
  }
  local source = {
    mapId = 61,
    fieldData = { events = { warps = {} } },
  }
  local position = { fieldX = 4 * 32 + 8, fieldZ = 16 }

  local staged = stage(runtime, destination, position, 7)
  Assert.equal(staged.coverage, replacementCoverage)
  Assert.equal(replacementCoverage.anchorX, 4)
  Assert.equal(replacementCoverage.anchorZ, 0)
  Assert.equal(#calls, 1)
  Assert.equal(runtime.physicalCoverage, sourceCoverage)
  Assert.equal(sourceCoverage.releases, 0)

  -- This minimal candidate is the same physical-map view consumed by the
  -- resolver: the staged terrain, not the source-centered region, owns the
  -- destination's local coordinates.
  local candidate = {
    mapId = destination.mapId,
    coordinateOrigin = destination.coordinateOrigin,
    fieldData = destination.fieldData,
    collision = destinationCollision(),
    terrain = replacementCoverage.terrain,
    coverage = staged.coverage,
  }
  local resolved = WarpSystem.resolveDestination(
    {
      load = function()
        return candidate
      end,
    },
    source,
    {
      index = 0,
      x = 1,
      z = 1,
      destinationMapId = 60,
      destinationWarpId = 0,
    }
  )

  Assert.equal(resolved.fieldX, position.fieldX)
  Assert.equal(resolved.fieldZ, position.fieldZ)
  Assert.equal(resolved.surfaceId, 0)
  Assert.equal(resolved.worldY, 0)
  Assert.equal(sourceCoverage.releases, 0)
end

function T.same_matrix_replacement_uses_abort_and_commit_ownership_transaction()
  local sourceCoverage = releaseSpy("source", 7, 0, 0)
  local replacementCoverage = releaseSpy("replacement", 7, 1, 0)
  local runtime = stagingRuntime(sourceCoverage, replacementCoverage)
  local destination = outdoorMap(replacementCoverage)
  local staged = stage(runtime, destination, { fieldX = 32 + 5, fieldZ = 11 }, 7)

  runtime:_disposePreparedSwap(nil, { physical = staged })
  runtime:_disposePreparedSwap(nil, { physical = staged })

  Assert.equal(replacementCoverage.releases, 1)
  Assert.equal(sourceCoverage.releases, 0)
  Assert.equal(runtime.physicalCoverage, sourceCoverage)
  Assert.equal(staged.state, "released")
  Assert.equal(sourceCoverage:probe(), "source")

  local committedSource = releaseSpy("committed-source", 7, 0, 0)
  local committedReplacement = releaseSpy("committed-replacement", 7, 1, 0)
  local committedRuntime = stagingRuntime(committedSource, committedReplacement)
  local committedDestination = outdoorMap(committedReplacement)
  local committed = stage(committedRuntime, committedDestination, { fieldX = 32 + 5, fieldZ = 11 }, 7)

  committedRuntime:_commitSwap(
    { destinationMap = committedDestination },
    "south",
    { player = {}, camera = {}, playerVisual = {}, physical = committed, residency = {} }
  )

  Assert.equal(committedRuntime.physicalCoverage, committedReplacement)
  Assert.equal(committed.state, "committed")
  Assert.equal(committedSource.releases, 1)
  Assert.equal(committedReplacement.releases, 0)

  committedRuntime:_releaseAll()
  committedRuntime:_releaseAll()
  Assert.equal(committedSource.releases, 1)
  Assert.equal(committedReplacement.releases, 1)
end

function T.destination_preparation_failure_discards_only_the_staged_owner()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local source = newSourceMap()
  local destination = { mapId = 60 }
  local runtime = {
    physicalCoverage = sourceCoverage,
    currentMap = source,
  }
  local cleanupCalls = 0
  local transition = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return {
        destinationMap = destination,
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
        physical = {
          coverage = destinationCoverage,
          replacement = true,
          previous = sourceCoverage,
        },
      }
    end,
    prepare = function(result)
      Assert.equal(runtime.physicalCoverage, sourceCoverage)
      Assert.equal(result.physical.coverage, destinationCoverage)
      error("destination actor preparation failed", 0)
    end,
    disposePrepared = function(result)
      cleanupCalls = cleanupCalls + 1
      if result.physical and result.physical.replacement then
        result.physical.coverage:release()
      end
    end,
    commit = function()
      error("a failed preparation must not commit", 0)
    end,
  })

  transition:start(source, { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 } }, "south")
  local ticks = 0
  while transition.phase ~= "idle" and ticks < 32 do
    transition:updateFixed()
    transition:updateSourceFrame()
    ticks = ticks + 1
  end

  Assert.equal(transition.phase, "idle")
  Assert.equal(tostring(transition.error), "destination actor preparation failed")
  Assert.equal(runtime.physicalCoverage, sourceCoverage)
  Assert.equal(runtime.currentMap, source)
  Assert.equal(sourceCoverage.releases, 0)
  Assert.equal(destinationCoverage.releases, 1)
  Assert.equal(cleanupCalls, 1)
  Assert.equal(sourceCoverage:probe(), "source")
end

local function destinationMap(coverage)
  return {
    mapId = 60,
    coverage = coverage,
    scene = { type = "outdoor" },
  }
end

---@param runtimeMap table
---@param physicalCoverage table?
---@param actors table
---@param zoneController table
---@param player table?
---@param eventState table?
---@param residency table?
---@return table
local function occupancyRuntime(runtimeMap, physicalCoverage, actors, zoneController, player, eventState, residency)
  return setmetatable({
    physicalCoverage = physicalCoverage,
    runtimeMap = runtimeMap,
    actors = actors,
    zoneController = zoneController,
    residency = residency,
    player = player or {},
    eventState = eventState or {},
  }, FieldRuntime)
end

local function preparedSwap(coverage, previous)
  return {
    player = {},
    camera = {},
    playerVisual = {},
    residency = {},
    physical = {
      coverage = coverage,
      replacement = true,
      previous = previous,
      state = "prepared",
    },
  }
end

function T.successful_swap_publishes_the_new_owner_before_destination_queries()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local runtime, sourceRuntimeMap = runtimeForSwap(sourceCoverage)
  local destination = destinationMap(destinationCoverage)

  runtime:_commitSwap({ destinationMap = destination }, "south", preparedSwap(destinationCoverage, sourceCoverage))

  Assert.equal(runtime.physicalCoverage, destinationCoverage)
  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 0)
  Assert.equal(runtime.runtimeMap, destination)

  local boundary = FieldNavigationBoundary.new({
    zoneController = { currentMap = destination },
    coverageProvider = function()
      return runtime.physicalCoverage
    end,
  })
  Assert.isFalse(boundary:crossesLogicalZone({ scene = { type = "outdoor" } }, { fieldX = 0, fieldZ = 0 }, "south"))
  Assert.equal(sourceCoverage.probes, 0)
  Assert.equal(destinationCoverage.probes, 1)
  Assert.equal(sourceRuntimeMap.mapId, 61)

  runtime:_releaseAll()
  runtime:_releaseAll()
  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 1)
end

function T.runtime_disposal_discards_an_uncommitted_replacement()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local runtime = runtimeForSwap(sourceCoverage)
  runtime.transition = FieldTransition.new({ loader = {}, prepare = function() end, commit = function() end })
  runtime.transition.resolution = {
    physical = {
      coverage = destinationCoverage,
      replacement = true,
      previous = sourceCoverage,
      state = "prepared",
    },
  }

  runtime:_releaseAll()

  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 1)
end

function T.indoor_occupancy_uses_the_current_map_actor_index()
  local calls = { getCollisionAt = 0, preflight = 0 }
  local retainedCoverage = {
    mapHeaderCalls = 0,
  }
  function retainedCoverage:mapHeaderAt()
    self.mapHeaderCalls = self.mapHeaderCalls + 1
    error("retained coverage must not participate in indoor occupancy", 0)
  end

  local actors = { currentMapId = "indoor" }
  function actors:getCollisionAt(mapId, candidate)
    calls.getCollisionAt = calls.getCollisionAt + 1
    Assert.equal(mapId, "indoor")
    Assert.equal(candidate.fieldX, 12)
    Assert.equal(candidate.fieldZ, 8)
    Assert.equal(candidate.surfaceId, 3)
    return { actorId = "indoor-blocker" }
  end
  function actors:probeAt()
    error("indoor occupancy must not preflight a destination map", 0)
  end

  local zoneController = {}
  function zoneController:mapForPreflight()
    calls.preflight = calls.preflight + 1
    error("indoor occupancy must not load a destination map", 0)
  end

  local runtime = occupancyRuntime({ mapId = "indoor", coverage = nil }, retainedCoverage, actors, zoneController)

  local occupant = runtime:_playerOccupantAt({ fieldX = 12, fieldZ = 8, surfaceId = 3 })

  Assert.equal(occupant, "indoor-blocker")
  Assert.equal(calls.getCollisionAt, 1)
  Assert.equal(calls.preflight, 0)
  Assert.equal(retainedCoverage.mapHeaderCalls, 0)
end

function T.outdoor_seam_occupancy_preflights_destination_actors()
  local calls = { mapHeaderAt = 0, getAt = 0, mapForId = 0, mapForPreflight = 0, probeAt = 0 }
  local player = {}
  local eventState = {}
  local destination = { mapId = "destination" }
  local activeCoverage = {}
  function activeCoverage:mapHeaderAt(fieldX, fieldZ)
    calls.mapHeaderAt = calls.mapHeaderAt + 1
    Assert.equal(fieldX, 19)
    Assert.equal(fieldZ, 7)
    return "destination"
  end

  local actors = {}
  function actors:getAt()
    calls.getAt = calls.getAt + 1
    error("an outdoor seam must probe the destination map", 0)
  end
  function actors:probeAt(map, state, candidate)
    calls.probeAt = calls.probeAt + 1
    Assert.equal(map, destination)
    Assert.equal(state, eventState)
    Assert.equal(candidate.fieldX, 19)
    Assert.equal(candidate.fieldZ, 7)
    Assert.equal(candidate.surfaceId, 2)
    return { actorId = "destination-blocker" }
  end

  local residency = {}
  function residency:mapForId(mapId)
    calls.mapForId = calls.mapForId + 1
    Assert.equal(mapId, "destination")
    return nil
  end
  function residency:mapForPreflight(mapId)
    calls.mapForPreflight = calls.mapForPreflight + 1
    Assert.equal(mapId, "destination")
    return destination
  end

  local zoneController = {}
  function zoneController:mapForPreflight(_, _)
    error("occupancy fallback belongs to logical residency", 0)
  end

  local runtime = occupancyRuntime(
    { mapId = "source", coverage = activeCoverage },
    nil,
    actors,
    zoneController,
    player,
    eventState,
    residency
  )

  local occupant = runtime:_playerOccupantAt({ fieldX = 19, fieldZ = 7, surfaceId = 2 })

  Assert.equal(occupant, "destination-blocker")
  Assert.equal(calls.mapHeaderAt, 1)
  Assert.equal(calls.mapForId, 1)
  Assert.equal(calls.mapForPreflight, 1)
  Assert.equal(calls.probeAt, 1)
  Assert.equal(calls.getAt, 0)
end

-- A logically resident destination only changes where the source events come
-- from: it is still read-only probed, because the one live actor entry
-- belongs to the active map.
function T.outdoor_seam_occupancy_probes_a_resident_destination_without_preflighting()
  local calls = { mapHeaderAt = 0, getAt = 0, mapForId = 0, mapForPreflight = 0, probeAt = 0 }
  local player = {}
  local eventState = {}
  local destination = { mapId = "destination" }
  local activeCoverage = {}
  function activeCoverage:mapHeaderAt(fieldX, fieldZ)
    calls.mapHeaderAt = calls.mapHeaderAt + 1
    Assert.equal(fieldX, 19)
    Assert.equal(fieldZ, 7)
    return "destination"
  end

  local actors = { currentMapId = "source" }
  function actors:getAt()
    calls.getAt = calls.getAt + 1
    error("an inactive destination must not be read from the live occupancy index", 0)
  end
  function actors:probeAt(map, state, candidate)
    calls.probeAt = calls.probeAt + 1
    Assert.equal(map, destination)
    Assert.equal(state, eventState)
    Assert.equal(candidate.fieldX, 19)
    Assert.equal(candidate.fieldZ, 7)
    Assert.equal(candidate.surfaceId, 2)
    return { actorId = "destination-blocker" }
  end

  local residency = {}
  function residency:mapForId(mapId)
    calls.mapForId = calls.mapForId + 1
    Assert.equal(mapId, "destination")
    return destination
  end
  function residency:mapForPreflight()
    calls.mapForPreflight = calls.mapForPreflight + 1
    error("a resident destination must not preflight a map", 0)
  end

  local zoneController = {}
  function zoneController:mapForPreflight()
    error("resident occupancy must not use the zone controller fallback", 0)
  end

  local runtime = occupancyRuntime(
    { mapId = "source", coverage = activeCoverage },
    nil,
    actors,
    zoneController,
    player,
    eventState,
    residency
  )
  local occupant = runtime:_playerOccupantAt({ fieldX = 19, fieldZ = 7, surfaceId = 2 })

  Assert.equal(occupant, "destination-blocker")
  Assert.equal(calls.mapHeaderAt, 1)
  Assert.equal(calls.mapForId, 1)
  Assert.equal(calls.probeAt, 1)
  Assert.equal(calls.mapForPreflight, 0)
  Assert.equal(calls.getAt, 0)
end

return { tests = T }
