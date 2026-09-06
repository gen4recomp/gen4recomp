-- Runtime static-prop replacement resolves the requested owner's model record:
-- two generic owners with different descriptors replace independently, and an
-- unknown owner fails instead of falling back to another group's model.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")

local T = {}

local function quad()
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
  return { vertices = { v(0, 0), v(1, 0), v(1, 1), v(0, 1) }, indices = { 0, 1, 2, 0, 2, 3 } }
end

local function staticDescriptor(key, batchCount, geometryPrefix)
  local batches = {}
  for index = 1, batchCount do
    batches[index] = {
      geometry = "assets/generated/maps/geometry/" .. geometryPrefix .. index .. ".g4mesh",
      polygonAlpha = 31,
      alphaClass = "opaque",
    }
  end
  return {
    schema = ModelAsset.SCHEMA,
    key = key,
    memberId = 1,
    kind = "static",
    batches = batches,
    materials = {},
  }
end

local function placement(x, z)
  return { transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 0, z, 1 } }
end

local function fakeMeshBuilder(_)
  return { release = function() end }
end

local function loadRuntime(descriptors, runtimeProps)
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(61)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 0, worldOriginZ = 0 },
    collision = { width = 32, height = 32, file = MapAssetCache.collisionPath(61) },
    lighting = {},
    edgeColors = {},
    fog = (function()
      local table32 = {}
      for i = 1, 32 do
        table32[i] = 0
      end
      return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
    end)(),
    runtimeProps = runtimeProps,
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  backend:write(MapAssetCache.collisionPath(61), CollisionGridAsset.encode({ width = 32, height = 32, cells = cells }))
  for _, desc in ipairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
    for _, batch in ipairs(desc.batches) do
      backend:write(batch.geometry, MeshWriter.encode(quad()))
    end
  end
  local cache = {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      local data = assert(backend:read(path), "missing cache file " .. path)
      local chunk = assert(loadstring(data, path))
      setfenv(chunk, {})
      local ok, result = pcall(chunk)
      assert(ok, result)
      return result
    end,
  }
  ---@cast cache CacheFs
  return MapSceneLoader.load(cache, scene, { meshBuilder = fakeMeshBuilder })
end

function T.replacement_resolves_each_owner_model_and_leaves_other_owners_untouched()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local descB = staticDescriptor("indoor:2:propB", 2, "propB-")
  local runtime = loadRuntime({ descA, descB }, {
    fountain_coin = { model = descA.key, placements = {} },
    harbor_lantern = { model = descB.key, placements = {} },
  })

  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 1, "one batch per placement of the first model")

  runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(7, 8) })
  local lanternDraws = runtime.runtimePropDrawsByOwner.harbor_lantern
  Assert.equal(#lanternDraws, 2, "two batches per placement of the second model")
  for _, draw in ipairs(lanternDraws) do
    Assert.equal(draw.transform[13], 7)
    Assert.equal(draw.transform[15], 8)
  end

  local coinDraws = runtime.runtimePropDrawsByOwner.fountain_coin
  Assert.equal(#coinDraws, 1, "replacing one owner leaves the other owner's draws untouched")
  Assert.equal(coinDraws[1].transform[13], 1)
  Assert.equal(#runtime.runtimePropDraws, 3)
  runtime:release()
end

function T.empty_selection_clears_only_the_named_owner()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local descB = staticDescriptor("indoor:2:propB", 1, "propB-")
  local runtime = loadRuntime({ descA, descB }, {
    fountain_coin = { model = descA.key, placements = {} },
    harbor_lantern = { model = descB.key, placements = {} },
  })

  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(2, 2) })
  Assert.equal(#runtime.runtimePropDraws, 2)
  runtime:replaceRuntimeStaticProps("fountain_coin", {})
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 0)
  Assert.equal(#runtime.runtimePropDrawsByOwner.harbor_lantern, 1)
  Assert.equal(#runtime.runtimePropDraws, 1)
  runtime:release()
end

function T.unknown_owner_fails_without_touching_existing_draws()
  local descA = staticDescriptor("indoor:1:propA", 1, "propA-")
  local runtime = loadRuntime({ descA }, {
    fountain_coin = { model = descA.key, placements = {} },
  })
  runtime:replaceRuntimeStaticProps("fountain_coin", { placement(1, 1) })
  local err = Assert.throws(function()
    runtime:replaceRuntimeStaticProps("harbor_lantern", { placement(2, 2) })
  end)
  Assert.isTrue(tostring(err):find("harbor_lantern", 1, true) ~= nil, "the failure names the unknown owner")
  Assert.equal(#runtime.runtimePropDrawsByOwner.fountain_coin, 1, "the failed replacement keeps prior draws")
  runtime:release()
end

return { tests = T }
