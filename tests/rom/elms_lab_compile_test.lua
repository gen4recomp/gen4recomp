-- ROM-conformance test: deterministic derived compilation of Professor Elm's Lab
-- 1F (map 61) against a real HGSS dump. Compiling twice from the unchanged raw
-- dump must produce byte-identical scene, mesh, and texture output; the result
-- must be complete (every placed indoor model, a 2048-byte permission grid) and
-- report ready; and an injected write failure must leave no completion marker
-- and spare the raw-dump marker. Runs only in the ROM-gated layer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")

local T = {}
local SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
local MAP_ID = 61

local function compileInto(romFs, version)
  local c = CacheFs.forVersion(version, FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
  local marker = MapCacheWriter.write(c, bundle)
  return c, bundle, marker
end

local function sortedKeys(t)
  local k = {}
  for x in pairs(t) do
    k[#k + 1] = x
  end
  table.sort(k)
  return k
end

function T.deterministic_bytes(romFs, version)
  local c1, b1 = compileInto(romFs, version)
  local c2, b2 = compileInto(romFs, version)
  local dir = MapAssetCache.mapDir(MAP_ID)

  Assert.equal(b1.marker, b2.marker)
  Assert.equal(c1:read(dir .. "/scene.lua"), c2:read(dir .. "/scene.lua"))
  Assert.equal(c1:read(dir .. "/dependencies.lua"), c2:read(dir .. "/dependencies.lua"))
  Assert.equal(c1:read(MapAssetCache.terrainPath(MAP_ID)), c2:read(MapAssetCache.terrainPath(MAP_ID)))
  Assert.deepEqual(sortedKeys(b1.meshes), sortedKeys(b2.meshes))
  Assert.deepEqual(sortedKeys(b1.textures), sortedKeys(b2.textures))

  for sha in pairs(b1.meshes) do
    Assert.equal(c1:read(MapAssetCache.geometryPath(sha)), c2:read(MapAssetCache.geometryPath(sha)))
  end
  for sha in pairs(b1.textures) do
    Assert.equal(c1:read(MapAssetCache.texturePath(sha)), c2:read(MapAssetCache.texturePath(sha)))
  end
end

function T.completeness_and_ready(romFs, version)
  local c, bundle, marker = compileInto(romFs, version)
  Assert.isTrue(MapAssetCache.isReady(c, MAP_ID, marker), "cache reports ready")
  local collision = assert(CollisionGridAsset.decode(assert(c:read(MapAssetCache.collisionPath(MAP_ID)))))
  Assert.equal(collision.width, 32)
  Assert.equal(#collision.cells, 1024)
  Assert.equal(bundle.scene.schema, MapAssetCache.SCENE_SCHEMA)
  Assert.equal(bundle.terrain.schema, "g4-terrain-surfaces-v1")
  Assert.isTrue(c:exists(MapAssetCache.terrainPath(MAP_ID)), "terrain artifact on disk")

  Assert.equal(#sortedKeys(bundle.models), 10) -- unique indoor building models plus starter balls
  Assert.equal(#bundle.scene.buildingInstances, 15) -- placed instances

  -- Polygon state lives on batch records, not material records.
  for _, m in ipairs(bundle.scene.materials) do
    Assert.isNil(m.alphaMode)
    Assert.isNil(m.alphaCutoff)
    Assert.isNil(m.cullMode)
  end
  for _, b in ipairs(bundle.scene.mapBatches) do
    Assert.notNil(b.alphaClass)
    Assert.notNil(b.cullMode)
    Assert.notNil(b.polygonAlpha)
  end
  Assert.notNil(bundle.scene.lighting)
  Assert.notNil(bundle.scene.lighting.records)

  -- Every building instance references a compiled model descriptor written to disk.
  for _, inst in ipairs(bundle.scene.buildingInstances) do
    Assert.notNil(bundle.models[inst.modelKey], "instance references a compiled model: " .. inst.modelKey)
    Assert.isTrue(c:exists(MapAssetCache.modelPath(inst.modelKey)), "model descriptor on disk")
  end
  -- Every map batch references a mesh present on disk.
  for _, b in ipairs(bundle.scene.mapBatches) do
    Assert.isTrue(c:exists(b.geometry), "map mesh on disk: " .. b.geometry)
  end

  -- Representative compiled-animation payload: every animated model
  -- descriptor the bundle emits must carry a table `compiled` payload on
  -- each clip, and the representative indoor bundle must reach at least one.
  local animatedDescriptors = 0
  local clipCount = 0
  for modelKey, desc in pairs(bundle.models) do
    if type(desc.animations) == "table" then
      animatedDescriptors = animatedDescriptors + 1
      for _, clip in ipairs(desc.animations) do
        Assert.equal(
          type(clip.compiled),
          "table",
          "clip " .. tostring(clip.id) .. " of " .. modelKey .. " carries a compiled payload"
        )
        clipCount = clipCount + 1
      end
    end
  end
  Assert.isTrue(animatedDescriptors > 0, "Elm's Lab emits animated model descriptors")
  Assert.isTrue(clipCount > 0, "Elm's Lab counted emitted clips")
end

-- The selected field-light profile is source-hashed and its records
-- serialize deterministically; compiling twice yields identical lighting data.
-- The runtime scene carries only the normalized records; source identity stays
-- in the dependency record.
function T.lighting_profile_is_deterministic(romFs, version)
  local _, b1 = compileInto(romFs, version)
  local _, b2 = compileInto(romFs, version)
  local l1, l2 = b1.scene.lighting, b2.scene.lighting
  Assert.isNil(l1.lightTypeRaw)
  Assert.isNil(l1.sourcePath)
  Assert.isNil(l1.sourceSha1)
  Assert.equal(#l1.records, #l2.records)
  for i = 1, #l1.records do
    Assert.deepEqual(l1.records[i], l2.records[i])
  end
  -- Profile source is hashed into cache dependencies.
  Assert.equal(b1.dependencies.fieldLightSourceSha1, b2.dependencies.fieldLightSourceSha1)
  Assert.equal(b1.dependencies.fieldLightSourcePath, b2.dependencies.fieldLightSourcePath)
end

-- Regression: DS texcoords are in texel units and must be normalized to
-- [0,1] by the bound texture size. Before the fix the healing machine (64px
-- texture) carried UVs up to 63 and clamped to a black edge texel. Elm's models
-- are all clamp/single-texture, so no legitimate UV should approach the raw
-- texel magnitudes; bound them well under any texel range.
function T.uvs_are_normalized(romFs, version)
  local _, bundle = compileInto(romFs, version)
  local maxUV = 0
  for _, batch in pairs(bundle.meshes) do
    for _, vtx in ipairs(batch.vertices) do
      maxUV = math.max(maxUV, math.abs(vtx.u), math.abs(vtx.v))
    end
  end
  Assert.isTrue(maxUV <= 8, "normalized UVs stay small, got max " .. maxUV)
end

-- Cache-only restart. After a successful compile the map loads and
-- traverses from the derived cache alone -- no ROM, and geometry comes from
-- baked G4M2 batches rather than a re-parsed NSBMD. Modelled by building into an
-- in-memory backend, then reopening a fresh CacheFs over the same backend and
-- using nothing but cache reads below the "restart" line.
function T.cache_only_restart(romFs, version)
  local backend = FakeCache.new()
  local marker
  do
    local c = CacheFs.forVersion(version, backend)
    local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
    marker = MapCacheWriter.write(c, bundle)
  end

  -- ---- restart: everything below reads only the cache ----
  local cache = CacheFs.forVersion(version, backend)
  Assert.isTrue(MapAssetCache.isReady(cache, MAP_ID, marker), "cache is ready without the ROM")

  local dir = MapAssetCache.mapDir(MAP_ID)
  local scene = assert(cache:loadLua(dir .. "/scene.lua"))
  local terrain = assert(cache:loadLua(MapAssetCache.terrainPath(MAP_ID)))
  Assert.equal(terrain.schema, "g4-terrain-surfaces-v1")

  -- Geometry loads as baked G4M2 batches from the derived-asset subtree; the map
  -- never re-parses NSBMD/NSBTX at load, and no reference escapes the cache.
  for _, b in ipairs(scene.mapBatches) do
    Assert.isTrue(b.geometry:find("^assets/generated/") ~= nil, "geometry is a derived asset: " .. b.geometry)
    local decoded = SceneMesh.decode(assert(cache:read(b.geometry), "mesh present: " .. b.geometry))
    Assert.isTrue(decoded.vertexCount > 0, "baked mesh has vertices")
  end
  for _, inst in ipairs(scene.buildingInstances) do
    Assert.isTrue(cache:exists(MapAssetCache.modelPath(inst.modelKey)), "model descriptor cached")
  end

  -- Load and traverse from the cached collision asset alone.
  local bytes = assert(cache:read(MapAssetCache.collisionPath(MAP_ID)))
  local grid = assert(CollisionGridAsset.decode(bytes))
  local collision = CollisionGrid.new(grid, {
    worldOriginX = scene.matrix.worldOriginX,
    worldOriginZ = scene.matrix.worldOriginZ,
  })
  Assert.isTrue(collision:containsLocal(4, 13), "spawn tile is in the cell")
  Assert.isFalse(collision:isBlockedLocal(4, 14), "exit warp tile is passable from cache-only data")
end

function T.injected_failure_leaves_no_marker(romFs, version)
  local backend = FakeCache.new()
  local orig = backend.write
  backend.write = function(self, path, data)
    if path:find("scene.lua", 1, true) then
      error("injected write failure")
    end
    return orig(self, path, data)
  end
  local c = CacheFs.forVersion(version, backend)
  c:write("rom-dump.complete", "raw-owned-by-earlier-run")

  local bundle = assert(MapAssetCompiler.compile(romFs, SYMBOL))
  Assert.isTrue(not pcall(MapCacheWriter.write, c, bundle), "write raises")
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(MAP_ID) .. "/complete"), "no false marker")
  Assert.isTrue(c:exists("rom-dump.complete"), "raw-dump marker preserved")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
