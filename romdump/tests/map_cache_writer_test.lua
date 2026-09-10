-- MapCacheWriter: a successful write leaves a ready map with the marker last; an
-- injected write failure leaves no completion marker and rolls back the map
-- subtree without disturbing the raw-dump marker.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local Bundle = require("tests.support.BundleFixture")
local ffi = require("ffi")

local T = {}

-- Wrap a FakeCache backend so writes to a path substring raise.
local function failOn(backend, substr)
  local orig = backend.write
  rawset(backend, "write", function(self, path, data)
    if path:find(substr, 1, true) then
      error("injected write failure")
    end
    return orig(self, path, data)
  end)
  return backend
end

function T.writes_marker_last_and_is_ready()
  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = Bundle.minimal()
  local marker = MapCacheWriter.write(c, bundle)
  Assert.equal(marker, bundle.marker)
  Assert.isTrue(MapAssetCache.isReady(c, bundle.mapId, marker), "ready after write")
  local terrain = assert(c:loadLua(MapAssetCache.terrainPath(bundle.mapId)))
  Assert.equal(terrain.schema, "g4-terrain-surfaces-v1")
end

-- A producer-finalized mesh is already content-addressed G4M2 Data. The map
-- writer owns staging/publication only and must persist that same object
-- without asking MeshWriter to rebuild it.
function T.stages_finalized_mesh_data_verbatim()
  local bundle = Bundle.minimal()
  local meshSha = assert(next(bundle.meshes))
  local payload = MeshWriter.encode(bundle.meshes[meshSha])
  local data = love.data.newByteData(#payload)
  ffi.copy(data:getFFIPointer(), payload, #payload)
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  bundle.meshes[meshSha] = data

  Assert.equal(MapCacheWriter.write(c, bundle), bundle.marker)
  local stored = backend.files["heartgold/" .. MapAssetCache.geometryPath(meshSha)]
  Assert.isTrue(stored == data, "the finalized Data object is staged without conversion")
  Assert.equal(ffi.string(stored:getFFIPointer(), stored:getSize()), payload, "staged bytes are unchanged")
end

function T.writes_neighbor_collision_and_terrain_artifacts()
  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = Bundle.minimal(60)
  local collisionPath = MapAssetCache.neighborCollisionPath(60, 3)
  local terrainPath = MapAssetCache.neighborTerrainPath(60, 3)
  bundle.neighborChunks = {
    [3] = { collision = bundle.collision, terrain = bundle.terrain },
  }
  bundle.scene.neighbors = {
    {
      offsetTilesX = 0,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      collision = { file = collisionPath },
      terrain = { file = terrainPath },
      batches = {},
      materials = {},
    },
  }
  MapCacheWriter.write(c, bundle)
  Assert.isTrue(c:exists(collisionPath, "file"), "neighbor collision asset exists")
  Assert.equal(assert(c:loadLua(terrainPath)).schema, "g4-terrain-surfaces-v1")
  Assert.isTrue(MapAssetCache.isReady(c, bundle.mapId, bundle.marker))
  c:write(collisionPath, "short")
  Assert.isFalse(MapAssetCache.isReady(c, bundle.mapId, bundle.marker))
end

function T.missing_terrain_artifact_is_not_ready()
  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = Bundle.minimal()
  MapCacheWriter.write(c, bundle)
  c:removeTree(MapAssetCache.terrainPath(bundle.mapId))
  Assert.isFalse(MapAssetCache.isReady(c, bundle.mapId, bundle.marker))
end

function T.injected_failure_leaves_no_marker()
  local backend = failOn(FakeCache.new(), "scene.lua")
  local c = CacheFs.forVersion("heartgold", backend)
  local bundle = Bundle.minimal()
  Assert.isTrue(not pcall(MapCacheWriter.write, c, bundle), "write raises")
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(bundle.mapId) .. "/complete"), "no false marker")
  -- Rolled back: the map's collision asset is gone too.
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(bundle.mapId) .. "/collision.g4collision"), "map subtree rolled back")
end

function T.failure_preserves_raw_dump_marker()
  local backend = failOn(FakeCache.new(), "scene.lua")
  local c = CacheFs.forVersion("heartgold", backend)
  c:write("rom-dump.complete", "raw")
  pcall(MapCacheWriter.write, c, Bundle.minimal())
  Assert.isTrue(c:exists("rom-dump.complete"), "raw marker untouched")
end

-- A rename failure after publish begins must not trigger writer-level stage
-- cleanup: the aside root in the stage is the only remaining copy of the
-- last-known-good artifact, so write() re-raises and leaves it in place.
function T.publish_failure_keeps_the_stage_with_recovery_material()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = Bundle.minimal()
  MapCacheWriter.write(c, first)
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath:find("staging/heartgold/map-", 1, true) then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = Bundle.minimal()
  second.marker = MapAssetCache.marker("romsha1", second.mapId, "new-dephash")
  local err = Assert.throws(function()
    MapCacheWriter.write(c, second)
  end)
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  local stageRoot = "staging/heartgold/map-" .. first.mapId
  Assert.notNil(backend:getInfo(stageRoot), "the stage is not removed once publish has begun")
  Assert.equal(
    backend.files[stageRoot .. "/" .. MapAssetCache.mapDir(first.mapId) .. ".old/complete"],
    first.marker,
    "the last-known-good map stays in the stage as recovery material"
  )
end

function T.failed_rebuild_preserves_the_previous_map()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = Bundle.minimal()
  MapCacheWriter.write(c, first)
  local orig = backend.write
  backend.write = function(self, path, data)
    if path:find("scene.lua", 1, true) then
      error("injected write failure")
    end
    return orig(self, path, data)
  end
  local second = Bundle.minimal()
  second.marker = MapAssetCache.marker("romsha1", second.mapId, "new-dephash")
  Assert.throws(function()
    MapCacheWriter.write(c, second)
  end)
  Assert.isTrue(MapAssetCache.isReady(c, first.mapId, first.marker), "the previous map remains ready")
  Assert.equal(c:read(MapAssetCache.mapDir(first.mapId) .. "/complete"), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/map-" .. first.mapId), "the stage is cleaned on failure")
  backend.write = orig
  MapCacheWriter.write(c, second)
  Assert.isTrue(MapAssetCache.isReady(c, first.mapId, second.marker), "a successful retry publishes the new map")
  Assert.isNil(backend:getInfo("staging/heartgold/map-" .. first.mapId), "the stage is cleaned on success")
end

-- A rebuilt bundle whose scene fails the strict v5 validation (missing
-- terrainAnimations) must raise MAP_CACHE_SCENE_INVALID and leave the prior
-- ready artifact exactly as it was: same marker, no stage, no new artifacts.
function T.failed_scene_validation_preserves_the_previous_map()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = Bundle.minimal()
  MapCacheWriter.write(c, first)
  local second = Bundle.minimal()
  second.marker = MapAssetCache.marker("romsha1", second.mapId, "new-dephash")
  second.scene.terrainAnimations = nil
  local err = Assert.throws(function()
    MapCacheWriter.write(c, second)
  end)
  Assert.equal(err.code, "MAP_CACHE_SCENE_INVALID")
  Assert.isTrue(MapAssetCache.isReady(c, first.mapId, first.marker), "the previous map remains ready")
  Assert.equal(c:read(MapAssetCache.mapDir(first.mapId) .. "/complete"), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/map-" .. first.mapId), "the stage is cleaned on validation failure")
end

-- A failed rebuild never replaces a model descriptor an older ready map
-- references: the model key is content-addressed over the descriptor, so a
-- changed descriptor gets a new path and the old path keeps its bytes even
-- when the shared model write succeeds and a later staged write fails.
function T.failed_rebuild_preserves_the_previous_model_descriptor()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = Bundle.minimal()
  MapCacheWriter.write(c, first)
  local firstModelKey = first.scene.buildingInstances[1].modelKey
  local firstModelPath = MapAssetCache.modelPath(firstModelKey)
  local firstModelBytes = c:read(firstModelPath)

  -- A rebuilt bundle whose model descriptor changed content (the compiler
  -- would key it differently): the changed descriptor lands at its own new
  -- path in the shared root, then the map write fails.
  local second = Bundle.minimal()
  second.marker = MapAssetCache.marker("romsha1", second.mapId, "new-dephash")
  local secondModelKey = "indoor:1:deadbeefdead"
  second.scene.buildingInstances = { { placementIndex = 0, modelKey = secondModelKey } }
  second.models = {
    [secondModelKey] = {
      schema = "g4-model-v5",
      key = secondModelKey,
      memberId = 1,
      kind = "static",
      materials = {},
      batches = {
        {
          geometry = MapAssetCache.geometryPath("mesh0000000000000000000000000000000000aa"),
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
          fogEnabled = false,
        },
      },
    },
  }
  local orig = backend.write
  backend.write = function(self, path, data)
    if path:find("scene.lua", 1, true) then
      error("injected write failure")
    end
    return orig(self, path, data)
  end
  Assert.throws(function()
    MapCacheWriter.write(c, second)
  end)
  backend.write = orig

  Assert.isTrue(MapAssetCache.isReady(c, first.mapId, first.marker), "the previous map remains ready")
  Assert.equal(c:read(firstModelPath), firstModelBytes, "the old descriptor keeps its bytes")
  Assert.isFalse(c:exists(MapAssetCache.modelPath(secondModelKey)), "the failed private stage leaves no new descriptor")
end

return { tests = T }
