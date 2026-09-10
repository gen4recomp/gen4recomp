-- Persists a compiled map bundle to the derived cache through the shared
-- staged publication primitive: the map's own subtree (collision grid, terrain
-- surfaces, neighbor artifacts, scene, dependencies, marker) is written into a
-- disposable staging root, read back and validated there, and only then
-- published over the map's live dir with the marker last. A failure at any
-- point leaves any previous ready map untouched and re-raises, never touching
-- the raw ROM dump.
--
-- Shared content-addressed meshes and textures (and shared model descriptors)
-- are written directly into the live shared roots instead of being staged:
-- they are shared across maps, so a wholesale swap would clobber other maps'
-- artifacts, while content addressing makes a re-write idempotent (same hash,
-- same bytes) and any unreferenced partial garbage from a failed build is
-- inert. Model keys are content-addressed over the descriptor itself, so a
-- failed rebuild can never replace a descriptor an older ready map references
-- (a changed descriptor gets a new path). Cheap structural invariants
-- (collision grid shape, terrain schema, descriptor schema, mesh
-- encodeability) are validated before anything is written, so a bad bundle
-- leaves no new shared artifacts behind at all.

local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local AssetErrors = require("libs.assets.src.errors")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local MapCacheWriter = {}

-- Cheap structural invariants are validated up front, before anything is
-- written to any shared root: a bad collision grid, terrain, or descriptor
-- must not replace a model descriptor or leave new shared meshes behind on
-- the way to failing. Meshes arrive as finalized content-addressed Data
-- values and are persisted verbatim.
local function validateBundle(bundle)
  local mapId = bundle.mapId
  local ok, err = pcall(CollisionGridAsset.encode, bundle.collision)
  if not ok then
    Errors.raise("MAP_CACHE_BAD_COLLISION", "collision grid is invalid: " .. tostring(err), { mapId = mapId })
  end
  if type(bundle.terrain) ~= "table" or bundle.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    Errors.raise(
      AssetErrors.MAP_CACHE_BAD_TERRAIN,
      "terrain artifact is missing or has the wrong schema",
      { mapId = mapId }
    )
  end
  for landDataMemberId, chunk in pairs(bundle.neighborChunks or {}) do
    local okChunk, chunkErr = pcall(CollisionGridAsset.encode, chunk.collision)
    if not okChunk then
      Errors.raise(
        "MAP_CACHE_BAD_NEIGHBOR_COLLISION",
        "neighbor collision grid is invalid: " .. tostring(chunkErr),
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
    if type(chunk.terrain) ~= "table" or chunk.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        AssetErrors.MAP_CACHE_BAD_NEIGHBOR_TERRAIN,
        "neighbor terrain artifact is invalid",
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
  end
  for _, descriptor in pairs(bundle.models) do
    ModelAsset.validate(descriptor)
  end
  for sha1, data in pairs(bundle.meshes) do
    assert(data ~= nil, "compiled mesh is missing finalized G4M2 Data for " .. sha1)
  end
  return bundle.meshes
end

local function persist(prepared, bundle)
  local cacheFs = prepared:cacheFs()
  local mapId = bundle.mapId
  local dir = MapAssetCache.mapDir(mapId)
  local stage = prepared:stageFs()

  local finalizedMeshes = validateBundle(bundle)
  prepared:addOwnedRoot(dir)

  -- 1. Shared content-addressed geometry (the encoded bytes validated
  -- above). 2. Shared content-addressed textures. 3. Shared model
  -- descriptors. The model key is content-addressed over the descriptor, so
  -- a re-write is idempotent and a failure can never clobber a descriptor an
  -- older ready map references (a different descriptor gets a different
  -- path).
  for sha1, bytes in pairs(finalizedMeshes) do
    local path = MapAssetCache.geometryPath(sha1)
    stage:write(path, bytes)
    prepared:addSharedFile(path)
  end
  for sha1, tex in pairs(bundle.textures) do
    local path = MapAssetCache.texturePath(sha1)
    assert(tex.data, "compiled texture is missing finalized PNG Data")
    stage:write(path, tex.data)
    prepared:addSharedFile(path)
  end
  for modelKey, descriptor in pairs(bundle.models) do
    local path = MapAssetCache.modelPath(modelKey)
    stage:writeLua(path, descriptor)
    prepared:addSharedFile(path)
  end
  -- 4. Collision grid, encoded into the project-owned G4CL asset. The
  -- encoder rejects malformed grids (bad dimensions, missing/wrong cells,
  -- non-boolean blocked), so an invalid bundle never reaches the stage.
  local collisionBytes = CollisionGridAsset.encode(bundle.collision)
  stage:write(dir .. "/collision.g4collision", collisionBytes)
  -- 5. Terrain surfaces.
  if type(bundle.terrain) ~= "table" or bundle.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    Errors.raise(
      AssetErrors.MAP_CACHE_BAD_TERRAIN,
      "terrain artifact is missing or has the wrong schema",
      { mapId = mapId }
    )
  end
  stage:writeLua(MapAssetCache.terrainPath(mapId), bundle.terrain)
  -- 6. Neighbor collision and terrain artifacts.
  for landDataMemberId, chunk in pairs(bundle.neighborChunks or {}) do
    local neighborCollisionBytes = CollisionGridAsset.encode(chunk.collision)
    if type(chunk.terrain) ~= "table" or chunk.terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        AssetErrors.MAP_CACHE_BAD_NEIGHBOR_TERRAIN,
        "neighbor terrain artifact is invalid",
        { mapId = mapId, landDataMemberId = landDataMemberId }
      )
    end
    stage:write(MapAssetCache.neighborCollisionPath(mapId, landDataMemberId), neighborCollisionBytes)
    stage:writeLua(MapAssetCache.neighborTerrainPath(mapId, landDataMemberId), chunk.terrain)
  end
  -- 7. Scene descriptor. 8. Dependency record.
  stage:writeLua(dir .. "/scene.lua", bundle.scene)
  stage:writeLua(dir .. "/dependencies.lua", bundle.dependencies)

  -- 9. Read back the staged scene and confirm every referenced asset exists:
  -- map-owned paths in the stage, shared content-addressed paths in the live
  -- shared roots. isReady requires the marker too, so probe with the intended
  -- marker after the marker file is written; here validate references directly.
  local scene = stage:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    Errors.raise(AssetErrors.MAP_CACHE_READBACK_FAILED, "scene.lua did not read back as a table", { mapId = mapId })
  end
  for _, path in
    ipairs(MapAssetCache.referencedPaths(scene --[[@as MapAssetCache.Scene]], stage))
  do
    if not stage:exists(path) and not cacheFs:exists(path) then
      Errors.raise(
        AssetErrors.MAP_CACHE_MISSING_ASSET,
        "referenced asset missing after write: " .. path,
        { mapId = mapId }
      )
    end
  end

  -- 10. Completion marker, written last. Publication happens in write()
  -- outside the staging-validation error handler, so a publish failure never
  -- triggers stage cleanup that could delete the last remaining copy of the
  -- previous artifact.
  stage:write(dir .. "/complete", bundle.marker)
  return bundle.marker
end

function MapCacheWriter.stage(prepared, bundle)
  assert(prepared and prepared.stageFs, "stage requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid bundle")
  local ok, result = pcall(persist, prepared, bundle)
  if not ok then
    error(result, 0)
  end
  return result
end

-- Synchronous compatibility for existing producer callers. It uses the same
-- private-stage and controller publication lifecycle as worker jobs.
function MapCacheWriter.write(cacheFs, bundle)
  assert(type(bundle) == "table" and bundle.mapId and bundle.marker, "invalid bundle")
  local prepared = PreparedArtifact.new({
    cacheFs = cacheFs,
    kind = "map",
    jobKey = "map:" .. bundle.mapId,
    stageName = "map-" .. bundle.mapId,
  })
  local ok, result = pcall(MapCacheWriter.stage, prepared, bundle)
  if not ok then
    prepared:abort()
    error(result, 0)
  end
  prepared:finishSuccess({ mapId = bundle.mapId, marker = bundle.marker })
  prepared:publish()
  return result
end

return MapCacheWriter
