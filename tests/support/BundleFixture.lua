-- Minimal self-consistent compiled-map bundle for exercising MapCacheWriter and
-- MapAssetCache without the real ROM pipeline: one mesh batch, one 1x1 texture,
-- one model descriptor (the explicit static schema/kind), and a scene that
-- references all three by their cache paths, plus a normalized collision grid
-- and a marker.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PngWriter = require("libs.assets.src.PngWriter")

local BundleFixture = {}

local function collisionGrid(width, height)
  local cells = {}
  for index = 1, width * height do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return { width = width, height = height, cells = cells }
end

function BundleFixture.minimal(mapId)
  mapId = mapId or 61
  local meshSha = "mesh0000000000000000000000000000000000aa"
  local texSha = "tex00000000000000000000000000000000000bb"
  local modelKey = "indoor:1:abc123abc123"

  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end

  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapBatches = { { geometry = MapAssetCache.geometryPath(meshSha), material = 0, node = 0 } },
    materials = {
      {
        id = 0,
        name = "m0",
        texture = MapAssetCache.texturePath(texSha),
        texWidth = 1,
        texHeight = 1,
        texMtxMode = 0,
      },
    },
    buildingInstances = { { placementIndex = 0, modelKey = modelKey } },
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }

  return {
    mapId = mapId,
    marker = MapAssetCache.marker("romsha1", mapId, "dephash"),
    scene = scene,
    dependencies = { cacheFormat = MapAssetCache.FORMAT },
    collision = collisionGrid(32, 32),
    terrain = {
      schema = "g4-terrain-surfaces-v1",
      source = { landDataMemberId = 0, bdhcOffset = 0, bdhcSize = 16, bdhcSha1 = "bdhcsha1" },
      points = {},
      slopes = {},
      heights = {},
      plates = {},
      strips = {},
      accessEntries = {},
    },
    meshes = { [meshSha] = { vertices = { v(0, 0), v(1, 0), v(0, 1) }, indices = { 0, 1, 2 } } },
    textures = {
      [texSha] = { data = PngWriter.encode(1, 1, string.char(10, 20, 30, 255)), width = 1, height = 1 },
    },
    models = {
      [modelKey] = {
        schema = "g4-model-v5",
        key = modelKey,
        memberId = 1,
        kind = "static",
        materials = {},
        batches = {},
      },
    },
  }
end

return BundleFixture
