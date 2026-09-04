-- Committed traversal over physical-only filler: stepping onto a passable
-- header-0 cell must complete the physical commit and player rebinding while
-- the logical zone stays on the source map with no map-0 load and no
-- zone-change side effects. A real neighboring logical map still transitions
-- exactly once with one rebind of scripts/weather/audio.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local FieldNavigationBoundary = require("libs.hgss.src.world.FieldNavigationBoundary")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldZoneController = require("libs.hgss.src.world.FieldZoneController")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local SOURCE_MAP_ID = 60

local function physicalIndex(destinationHeaderId)
  return {
    schema = "g4-field-cell-index-v2",
    matrices = {
      {
        matrixMemberId = 1,
        width = 2,
        height = 1,
        cells = {
          {
            matrixMemberId = 1,
            index = 0,
            x = 0,
            z = 0,
            origin = { x = 0, y = 0, z = 0 },
            mapHeaderId = SOURCE_MAP_ID,
          },
          {
            matrixMemberId = 1,
            index = 1,
            x = 1,
            z = 0,
            origin = { x = 32, y = 0, z = 0 },
            mapHeaderId = destinationHeaderId,
          },
        },
      },
    },
  }
end

local function loadCell(descriptor)
  return {
    key = string.format("%d:%d", descriptor.x, descriptor.z),
    x = descriptor.x,
    z = descriptor.z,
    origin = descriptor.origin,
    descriptor = descriptor,
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      getLocal = function()
        return { blocked = false }
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      source = { bdhcSha1 = string.format("cell-%d-%d", descriptor.x, descriptor.z) },
      plates = {
        {
          id = 1,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    release = function() end,
  }
end

local function newOutdoorMap(coverage)
  local map = {
    mapId = SOURCE_MAP_ID,
    mapSymbol = "filler-traversal-test",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z },
    physicalOrigin = coverage.origin,
    collision = coverage.region.collision,
    terrain = coverage.region.terrain,
    fieldRegion = coverage.region,
    coverage = coverage,
    scene = { type = "outdoor" },
    fieldData = {},
    cameraType = 0,
    updateAnimated = function() end,
    release = function() end,
  }
  function map:syncPhysicalFields()
    self.fieldRegion = coverage.region
    self.collision = coverage.region.collision
    self.terrain = coverage.region.terrain
    self.coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z }
    self.physicalOrigin = coverage.origin
  end
  return map
end

local function steppedEastPlayer(runtimeMap, coverage)
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = 31,
    fieldZ = 0,
    surfaceId = assert(coverage:sourceSurface("0:0", 1)),
    facing = "east",
  })
  Assert.isTrue(player:tryStep("east"))
  for _ = 1, FieldPlayer.WALK_STEP_TICKS do
    player:updateFixed({})
  end
  Assert.equal(player.fieldX, 32)
  Assert.equal(player.fieldZ, 0)
  return player
end

local function newCamera()
  local camera = { rebases = 0 }
  function camera:rebase()
    self.rebases = self.rebases + 1
  end
  return camera
end

function T.step_onto_filler_keeps_logical_zone_with_no_map_zero_load()
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = physicalIndex(0),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
  local runtimeMap = newOutdoorMap(coverage)
  local player = steppedEastPlayer(runtimeMap, coverage)
  local camera = newCamera()
  local calls = { lookups = {} }
  local zoneController = FieldZoneController.new({
    currentMap = { mapId = SOURCE_MAP_ID, mapSection = "OLD", fieldData = {} },
    mapForId = function(mapId)
      calls.lookups[#calls.lookups + 1] = mapId
      error("logical lookup for map " .. tostring(mapId) .. " is not part of a filler step", 0)
    end,
    rebindScripts = function(map)
      calls[#calls + 1] = "scripts:" .. map.mapId
    end,
    applyWeather = function(map)
      calls[#calls + 1] = "weather:" .. map.mapId
    end,
    enterAudio = function(map)
      calls[#calls + 1] = "audio:" .. map.mapId
    end,
    onChange = function(change)
      calls[#calls + 1] = "change:" .. change.newMapId
    end,
  })
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return coverage
    end,
    zoneController = zoneController,
  })

  local ok, result = pcall(function()
    return boundary:afterCommittedMove(runtimeMap, player, camera)
  end)
  if not ok then
    coverage:release()
  end
  Assert.isTrue(ok, "a passable filler step must not raise a logical-map lookup: " .. tostring(result))
  Assert.isNil(result, "a filler step publishes no zone change")

  Assert.equal(coverage:status().anchorX, 1, "physical coverage still commits the filler cell")
  Assert.equal(coverage:status().anchorZ, 0)
  Assert.equal(coverage:status().residentCount, 2)
  Assert.equal(player.fieldX, 32, "the player rebinds onto the committed filler cell")
  Assert.equal(player.fieldZ, 0)
  Assert.equal(player.localX, 0)
  Assert.equal(camera.rebases, 1, "the physical frame still rebases after the commit")
  Assert.equal(zoneController.currentMap.mapId, SOURCE_MAP_ID, "the logical zone stays on the source map")
  Assert.deepEqual(calls.lookups, {}, "no logical load or protection for map 0 occurs")
  Assert.deepEqual(calls, { lookups = {} }, "no zone-change callback, audio, weather, or script rebind fires")
  coverage:release()
end

function T.step_onto_a_real_neighbor_transitions_exactly_once()
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = physicalIndex(61),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
  local runtimeMap = newOutdoorMap(coverage)
  local player = steppedEastPlayer(runtimeMap, coverage)
  local camera = newCamera()
  local calls = { lookups = {} }
  local destination = { mapId = 61, mapSection = "NEW", fieldData = {} }
  local zoneController = FieldZoneController.new({
    currentMap = { mapId = SOURCE_MAP_ID, mapSection = "OLD", fieldData = {} },
    mapForId = function(mapId)
      calls.lookups[#calls.lookups + 1] = mapId
      return mapId == destination.mapId and destination or nil
    end,
    rebindScripts = function(map)
      calls[#calls + 1] = "scripts:" .. map.mapId
    end,
    applyWeather = function(map)
      calls[#calls + 1] = "weather:" .. map.mapId
    end,
    enterAudio = function(map)
      calls[#calls + 1] = "audio:" .. map.mapId
    end,
    onChange = function(change)
      calls[#calls + 1] = "change:" .. change.newMapId
    end,
  })
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return coverage
    end,
    zoneController = zoneController,
  })

  local change = assert(boundary:afterCommittedMove(runtimeMap, player, camera))
  Assert.equal(change.oldMapId, SOURCE_MAP_ID)
  Assert.equal(change.newMapId, 61)
  Assert.equal(zoneController.currentMap, destination)
  Assert.deepEqual(calls.lookups, { 61 }, "the destination logical map resolves once")
  Assert.equal(table.concat(calls, ","), "scripts:61,weather:61,audio:61,change:61")
  Assert.equal(player.fieldX, 32)
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
