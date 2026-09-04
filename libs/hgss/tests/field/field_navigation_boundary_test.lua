-- Field navigation must use the session physical world only for outdoor
-- composed views; indoor/discontinuous maps keep their own transition path.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local FieldNavigationBoundary = require("libs.hgss.src.world.FieldNavigationBoundary")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = { tests = {} }

local function physicalIndex()
  return {
    schema = "g4-field-cell-index-v2",
    matrices = {
      {
        matrixMemberId = 1,
        width = 2,
        height = 1,
        cells = {
          { matrixMemberId = 1, index = 0, x = 0, z = 0, origin = { x = 0, y = 0, z = 0 } },
          { matrixMemberId = 1, index = 1, x = 1, z = 0, origin = { x = 32, y = 0, z = 0 } },
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
    mapId = 60,
    mapSymbol = "physical-boundary-test",
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

function T.tests.does_not_reuse_outdoor_world_for_indoor_maps()
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return {
        mapHeaderAt = function()
          error("indoor movement must not query outdoor coverage")
        end,
      }
    end,
  })
  local runtimeMap = { scene = { type = "indoor" } }
  local player = { fieldX = 0, fieldZ = 0 }

  Assert.isFalse(boundary:crossesLogicalZone(runtimeMap, player, "north"))
  Assert.isNil(boundary:afterCommittedMove(runtimeMap, player, {}))
end

function T.tests.uses_the_current_coverage_after_ownership_replacement()
  local sourceCalls = 0
  local destinationCalls = 0
  local sourceCoverage = {
    mapHeaderAt = function()
      sourceCalls = sourceCalls + 1
      return 60
    end,
  }
  local destinationCoverage = {
    mapHeaderAt = function()
      destinationCalls = destinationCalls + 1
      return 61
    end,
  }
  local currentCoverage = sourceCoverage
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return currentCoverage
    end,
    zoneController = { currentMap = { mapId = 60 } },
  })
  local runtimeMap = { scene = { type = "outdoor" } }
  local player = { fieldX = 0, fieldZ = 0 }

  Assert.isFalse(boundary:crossesLogicalZone(runtimeMap, player, "south"))
  currentCoverage = destinationCoverage
  Assert.isTrue(boundary:crossesLogicalZone(runtimeMap, player, "south"))
  Assert.equal(sourceCalls, 1)
  Assert.equal(destinationCalls, 1)
end

function T.tests.rebases_runtime_frame_on_the_commit_tick()
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = physicalIndex(),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
  local runtimeMap = newOutdoorMap(coverage)
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = 31,
    fieldZ = 0,
    surfaceId = assert(coverage:sourceSurface("0:0", 1)),
    facing = "east",
  })
  local camera = { x = 10, z = 20 }
  function camera:rebase(deltaX, deltaY, deltaZ)
    self.x = self.x + deltaX
    self.y = (self.y or 0) + deltaY
    self.z = self.z + deltaZ
  end

  Assert.isTrue(player:tryStep("east"))
  for _ = 1, FieldPlayer.WALK_STEP_TICKS do
    player:updateFixed({})
  end
  local previousWorldX = player.previousWorldX
  local previousWorldZ = player.previousWorldZ
  local oldOrigin = { x = coverage.origin.x, y = coverage.origin.y, z = coverage.origin.z }

  local reconcileCalls = 0
  local reconcileState
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return coverage
    end,
    reconcilePhysicalWorld = function()
      reconcileCalls = reconcileCalls + 1
      reconcileState = {
        anchorX = coverage.anchorX,
        anchorZ = coverage.anchorZ,
        physicalOriginX = runtimeMap.physicalOrigin.x,
        playerLocalX = player.localX,
        playerLocalZ = player.localZ,
        playerWorldX = player.worldX,
        playerWorldZ = player.worldZ,
        cameraX = camera.x,
        cameraZ = camera.z,
      }
    end,
  })
  boundary:afterCommittedMove(runtimeMap, player, camera)

  Assert.equal(player.currentMap, runtimeMap)
  Assert.equal(player.fieldX, 32)
  Assert.equal(player.fieldZ, 0)
  Assert.equal(player.localX, 0)
  Assert.equal(player.localZ, 0)
  Assert.equal(coverage:status().anchorX, 1)
  Assert.equal(coverage:status().anchorZ, 0)
  Assert.equal(runtimeMap.physicalOrigin.x, 32)
  Assert.equal(player.worldX, -15.5)
  Assert.equal(player.worldZ, -15.5)
  Assert.equal(player.previousWorldX, previousWorldX - 32)
  Assert.equal(player.previousWorldZ, previousWorldZ)
  Assert.equal(camera.x, oldOrigin.x - runtimeMap.physicalOrigin.x + 10)
  Assert.equal(camera.z, 20)
  Assert.equal(reconcileCalls, 1)
  Assert.deepEqual(reconcileState, {
    anchorX = 1,
    anchorZ = 0,
    physicalOriginX = 32,
    playerLocalX = 0,
    playerLocalZ = 0,
    playerWorldX = -15.5,
    playerWorldZ = -15.5,
    cameraX = -22,
    cameraZ = 20,
  })
  coverage:release()
end

function T.tests.refreshes_same_anchor_surface_without_rebasing()
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = physicalIndex(),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
  local runtimeMap = newOutdoorMap(coverage)
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = 1,
    fieldZ = 1,
    surfaceId = assert(coverage:sourceSurface("0:0", 1)),
  })
  local before = {
    worldX = player.worldX,
    worldY = player.worldY,
    worldZ = player.worldZ,
    previousWorldX = player.previousWorldX,
    previousWorldY = player.previousWorldY,
    previousWorldZ = player.previousWorldZ,
  }
  local rebaseCalls = 0
  local camera = {
    rebase = function()
      rebaseCalls = rebaseCalls + 1
    end,
  }

  local reconcileCalls = 0
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return coverage
    end,
    reconcilePhysicalWorld = function()
      reconcileCalls = reconcileCalls + 1
    end,
  })
  local result = assert(boundary:afterCommittedMove(runtimeMap, player, camera))

  Assert.equal(player.localX, 1)
  Assert.equal(player.localZ, 1)
  Assert.equal(player.worldX, before.worldX)
  Assert.equal(player.worldY, before.worldY)
  Assert.equal(player.worldZ, before.worldZ)
  Assert.equal(player.previousWorldX, before.previousWorldX)
  Assert.equal(player.previousWorldY, before.previousWorldY)
  Assert.equal(player.previousWorldZ, before.previousWorldZ)
  Assert.equal(rebaseCalls, 0)
  Assert.equal(reconcileCalls, 0)
  Assert.equal(result.anchorX, coverage.anchorX)
  Assert.equal(result.anchorZ, coverage.anchorZ)
  Assert.equal(player.committedSourceCellKey, "0:0")
  Assert.equal(player.committedSourceSurfaceId, 1)
  coverage:release()
end

return T
