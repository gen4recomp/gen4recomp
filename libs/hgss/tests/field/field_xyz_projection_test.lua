-- Physical-origin projection tests keep player, camera, terrain, and transient
-- effect coordinates in one XYZ frame across an altitude recenter.

local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function cellIndex()
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
            altitude = 0,
            origin = { x = 0, y = 0, z = 0 },
          },
          {
            matrixMemberId = 1,
            index = 1,
            x = 1,
            z = 0,
            altitude = 1,
            origin = { x = 32, y = 0.5, z = 0 },
          },
        },
      },
    },
  }
end

local function loadCell(descriptor)
  local key = string.format("%d:%d", descriptor.x, descriptor.z)
  return {
    key = key,
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

local function newCoverage()
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = cellIndex(),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
end

local function integerOrigin(value)
  assert(value % 1 == 0, "fixture origin must be an integer")
  ---@cast value integer
  return value
end

local function mapFor(coverage)
  local originX = integerOrigin(coverage.origin.x)
  local originZ = integerOrigin(coverage.origin.z)
  local map = {
    mapId = 60,
    mapSymbol = "projection-test",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = originX, z = originZ },
    physicalOrigin = coverage.origin,
    collision = coverage.region.collision,
    terrain = coverage.region.terrain,
    fieldRegion = coverage.region,
    coverage = coverage,
    scene = {},
    fieldData = {},
    cameraType = 4,
    projectPhysicalPoint = function(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
      return coverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
    end,
    updateAnimated = function() end,
    release = function() end,
  } --[[@as RuntimeFieldMap]]
  function map:syncPhysicalFields()
    local syncedOriginX = integerOrigin(coverage.origin.x)
    local syncedOriginZ = integerOrigin(coverage.origin.z)
    self.fieldRegion = coverage.region
    self.collision = coverage.region.collision
    self.terrain = coverage.region.terrain
    self.coordinateOrigin = { x = syncedOriginX, z = syncedOriginZ }
    self.physicalOrigin = coverage.origin
  end
  return map
end

local function cameraProfile()
  return {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
end

local function copyPoint(point)
  return { x = point.x, y = point.y, z = point.z }
end

local function assertTranslated(actual, before, delta, label)
  Assert.near(actual.x, before.x + delta.x, 1e-9, label .. " x")
  Assert.near(actual.y, before.y + delta.y, 1e-9, label .. " y")
  Assert.near(actual.z, before.z + delta.z, 1e-9, label .. " z")
end

function T.altitude_recenter_translates_player_camera_terrain_and_effect_in_one_xyz_frame()
  local coverage = newCoverage()
  local oldOrigin = coverage:status().physicalOrigin
  local runtimeMap = mapFor(coverage)
  local sourceSurfaceId = assert(coverage:sourceSurface("1:0", 1))
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = 33,
    fieldZ = 1,
    surfaceId = sourceSurfaceId,
  })
  local camera = FieldCamera.new(cameraProfile(), { initialTarget = player:renderPosition() })
  camera:updateFixed({ x = player.worldX + 0.25, y = player.worldY + 0.5, z = player.worldZ + 0.75 })
  local beforePlayer = { x = player.worldX, y = player.worldY, z = player.worldZ }
  player.previousWorldX = player.worldX - 0.25
  player.previousWorldY = player.worldY - 0.125
  player.previousWorldZ = player.worldZ + 0.5
  local beforePreviousPlayer = {
    x = player.previousWorldX,
    y = player.previousWorldY,
    z = player.previousWorldZ,
  }
  local beforeCamera = {
    sourceTarget = copyPoint(camera.sourceTarget),
    target = copyPoint(camera.target),
    previousTarget = copyPoint(camera.previousTarget),
    eye = copyPoint(camera.eye),
    previousEye = copyPoint(camera.previousEye),
  }
  local beforeSourceY = camera.cameraSourceY
  local beforeAppliedY = camera.cameraAppliedY
  local beforeEffect = runtimeMap:projectPhysicalPoint(33, 1, "1:0", 1)
  local beforeTerrainY = coverage.region.terrain:sampleHeight(sourceSurfaceId, 33.5, 1.5)

  coverage:recenter(1, 0)
  local newOrigin = coverage:status().physicalOrigin
  local delta = {
    x = oldOrigin.x - newOrigin.x,
    y = oldOrigin.y - newOrigin.y,
    z = oldOrigin.z - newOrigin.z,
  }
  runtimeMap:syncPhysicalFields()
  player:rebindCoverage(runtimeMap, delta.x, delta.y, delta.z, "1:0", 1)
  camera:rebase(delta.x, delta.y, delta.z)

  local afterEffect = runtimeMap:projectPhysicalPoint(33, 1, "1:0", 1)
  local reboundSurfaceId = assert(coverage:sourceSurface("1:0", 1))
  local afterTerrainY = coverage.region.terrain:sampleHeight(reboundSurfaceId, 1.5, 1.5)

  assertTranslated(player:renderPosition(), beforePlayer, delta, "player")
  assertTranslated(
    { x = player.previousWorldX, y = player.previousWorldY, z = player.previousWorldZ },
    beforePreviousPlayer,
    delta,
    "previous player"
  )
  Assert.equal(player.surfaceId, reboundSurfaceId, "player surface identity must survive composite-id remapping")
  for name, before in pairs(beforeCamera) do
    assertTranslated(camera[name], before, delta, "camera " .. name)
  end
  Assert.near(camera.cameraSourceY, beforeSourceY + delta.y, 1e-9, "camera source Y")
  Assert.near(camera.cameraAppliedY, beforeAppliedY + delta.y, 1e-9, "camera applied Y")
  Assert.near(afterTerrainY, beforeTerrainY + delta.y, 1e-9, "terrain Y")
  Assert.near(afterEffect.localX, beforeEffect.localX + delta.x, 1e-9, "effect X")
  Assert.near(afterEffect.localZ, beforeEffect.localZ + delta.z, 1e-9, "effect Z")
  Assert.near(afterEffect.worldY, beforeEffect.worldY + delta.y, 1e-9, "effect Y")
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
