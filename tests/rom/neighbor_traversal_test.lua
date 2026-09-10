-- ROM-conformance connected-cell traversal proves New Bark's compiled west/east
-- neighbors provide collision and BDHC data for real cross-boundary steps.

local Assert = require("tests.support.Assert")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldRegion = require("libs.hgss.src.world.FieldRegion")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function collision(grid)
  return CollisionGrid.new(grid)
end

local function runtimeMap(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local neighbors = {}
  for _, descriptor in ipairs(bundle.scene.neighbors) do
    local chunk = assert(bundle.neighborChunks[descriptor.landDataMemberId])
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = collision(chunk.collision),
      terrain = TerrainSurface.new(chunk.terrain),
    }
  end
  local region = FieldRegion.new(collision(bundle.collision), TerrainSurface.new(bundle.terrain), neighbors)
  return {
    mapId = bundle.mapId,
    coordinateOrigin = {
      x = bundle.scene.matrix.worldOriginX,
      z = bundle.scene.matrix.worldOriginZ,
    },
    collision = region.collision,
    terrain = region.terrain,
  },
    bundle.scene.neighbors
end

local function crossesBoundary(map, sourceX, destinationX, direction)
  for z = 0, 31 do
    if not map.collision:isBlockedLocal(sourceX, z) and not map.collision:isBlockedLocal(destinationX, z) then
      for _, plate in ipairs(map.terrain:candidatesAt(sourceX + 0.5, z + 0.5)) do
        local currentMap = map --[[@as RuntimeFieldMap]]
        local fieldX = map.coordinateOrigin.x + sourceX --[[@as integer]]
        local fieldZ = map.coordinateOrigin.z + z --[[@as integer]]
        local player = FieldPlayer.new({
          currentMap = currentMap,
          fieldX = fieldX,
          fieldZ = fieldZ,
          surfaceId = plate.id,
          facing = direction,
        })
        if player:tryStep(direction) then
          for _ = 1, FieldPlayer.WALK_STEP_TICKS do
            player:updateFixed({})
          end
          Assert.equal(player.fieldX, map.coordinateOrigin.x + destinationX)
          return z
        end
      end
    end
  end
  return nil
end

function T.new_bark_crosses_into_route_29_and_rejects_route_27_water(romFs, versionId)
  -- Compiled-bundle region: the same crossings must hold from fresh ROM
  -- compilation, which also pins the neighbor header mapping.
  local map, descriptors = runtimeMap(romFs)
  local westHeader, eastHeader
  for _, descriptor in ipairs(descriptors) do
    if descriptor.offsetTilesX == -32 and descriptor.offsetTilesZ == 0 then
      westHeader = descriptor.mapHeaderId
    elseif descriptor.offsetTilesX == 32 and descriptor.offsetTilesZ == 0 then
      eastHeader = descriptor.mapHeaderId
    end
  end
  Assert.equal(westHeader, 33)
  Assert.equal(eastHeader, 31)
  Assert.notNil(crossesBoundary(map, 0, -1, "west"), "no Route 29 boundary crossing")
  Assert.isNil(crossesBoundary(map, 31, 32, "east"), "Route 27 water is walkable")

  -- Generated-cache region: the logical loader entry deliberately owns no
  -- representative collision or terrain. The session-owned physical
  -- coverage is the public path for the traversable cached region.
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()))
  local loader = FieldMapLoader.new(cacheFs, world)
  local logical = loader:load(60)
  Assert.isNil(logical.collision)
  Assert.isNil(logical.terrain)
  local coverage = loader:createPhysicalCoverage(logical, { fieldX = 672, fieldZ = 384 })
  local cached = {
    mapId = logical.mapId,
    coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z },
    collision = coverage.region.collision,
    terrain = coverage.region.terrain,
  }
  Assert.equal(coverage:mapHeaderAt(672, 384), 60)
  Assert.notNil(crossesBoundary(cached, 0, -1, "west"))
  Assert.isNil(crossesBoundary(cached, 31, 32, "east"))
  coverage:release()
  loader:release()
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
