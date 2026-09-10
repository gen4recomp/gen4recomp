-- Field-cell publication tests. A failed staged rebuild must leave the last
-- complete class available while shared immutable descriptors remain usable.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")

local T = {}

local function collision()
  local cells = {}
  for _ = 1, 32 * 32 do
    cells[#cells + 1] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return { width = 32, height = 32, cells = cells }
end

local function bundle(marker)
  local modelKey = "outdoor:1:writer-test"
  local descriptor = {
    schema = ModelAsset.SCHEMA,
    key = modelKey,
    memberId = 1,
    kind = "static",
    batches = {},
    materials = {},
  }
  local cellPath = FieldCellCache.cellPath(4, 1)
  return {
    marker = marker,
    index = {
      schema = FieldCellCache.INDEX_SCHEMA,
      matrices = {
        {
          matrixMemberId = 4,
          width = 1,
          height = 1,
          cells = {
            {
              matrixMemberId = 4,
              index = 1,
              x = 0,
              z = 0,
              mapHeaderId = 60,
              altitude = 0,
              landDataMemberId = 7,
              areaDataMemberId = 2,
              file = cellPath,
            },
          },
        },
      },
    },
    cells = {
      ["4:1"] = {
        schema = FieldCellCache.CELL_SCHEMA,
        matrixMemberId = 4,
        index = 1,
        x = 0,
        z = 0,
        mapHeaderId = 60,
        origin = { x = 0, y = 0, z = 0 },
        altitude = 0,
        landDataMemberId = 7,
        areaDataMemberId = 2,
        batches = {},
        materials = {},
        buildingInstances = {
          {
            placementIndex = 0,
            modelKey = modelKey,
            transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
          },
        },
        terrainAnimations = { textureSrt = false },
        collision = { width = 32, height = 32, file = FieldCellCache.collisionPath(4, 1) },
        terrain = { schema = MapAssetCache.TERRAIN_SCHEMA, file = FieldCellCache.terrainPath(4, 1) },
        calibration = { modelExtentTilesX = 32, modelExtentTilesZ = 32, posScale = 1 },
        cellMarker = FieldCellCache.cellMarker("rom", 4, 1, marker),
        dependencies = {
          marker = FieldCellCache.cellMarker("rom", 4, 1, marker),
          matrixMemberId = 4,
          index = 1,
          descriptor = {
            matrixMemberId = 4,
            index = 1,
            x = 0,
            z = 0,
            mapHeaderId = 60,
            altitude = 0,
            landDataMemberId = 7,
            areaDataMemberId = 2,
          },
        },
        collisionData = collision(),
        terrainData = { schema = MapAssetCache.TERRAIN_SCHEMA },
      },
    },
    meshes = {},
    textures = {},
    models = { [modelKey] = descriptor },
  }
end

function T.writes_a_complete_field_cell_class()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle("field-cell-cache-v2:one")
  Assert.equal(FieldCellCacheWriter.write(cache, b), b.marker)
  Assert.isTrue(FieldCellCacheWriter.isReady(cache, b.marker), "field-cell class is ready")
  Assert.isTrue(cache:exists(MapAssetCache.modelPath("outdoor:1:writer-test"), "file"))
end

function T.failed_rebuild_preserves_the_previous_class()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = bundle("field-cell-cache-v2:first")
  FieldCellCacheWriter.write(cache, first)

  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("terrain.lua", 1, true) then
      error("injected field-cell write failure")
    end
    return original(self, path, data)
  end
  local second = bundle("field-cell-cache-v2:second")
  Assert.throws(function()
    FieldCellCacheWriter.write(cache, second)
  end)
  backend.write = original

  Assert.isTrue(FieldCellCacheWriter.isReady(cache, first.marker), "previous class remains ready")
  Assert.equal(cache:read(FieldCellCache.markerPath()), first.marker)
end

return { tests = T }
