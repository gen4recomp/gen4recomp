-- Publishes the generated physical-cell class with stage, readback, and marker
-- ordering. The class owns only its cell data; shared meshes, textures, and
-- model descriptors remain content-addressed cache assets shared with maps.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}

local function validateBundle(bundle)
  assert(
    type(bundle.index) == "table"
      and type(bundle.cells) == "table"
      and type(bundle.meshes) == "table"
      and type(bundle.textures) == "table"
      and type(bundle.models) == "table"
      and bundle.marker,
    "incomplete field cell bundle"
  )
  assert(FieldCellCache.validateIndex(bundle.index), "field cell index is malformed")
  local encodedTextures = {}
  for sha1, data in pairs(bundle.meshes or {}) do
    assert(data ~= nil, "compiled mesh is missing finalized G4M2 Data for " .. sha1)
  end
  for sha1, texture in pairs(bundle.textures or {}) do
    encodedTextures[sha1] = assert(texture.data, "compiled texture is missing finalized PNG Data")
  end
  for _, model in pairs(bundle.models or {}) do
    ModelAsset.validate(model)
  end
  for _, matrix in ipairs(bundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(bundle.cells[descriptor.matrixMemberId .. ":" .. descriptor.index])
      assert(cell.schema == FieldCellCache.CELL_SCHEMA, "field cell schema mismatch")
      CollisionGridAsset.encode(cell.collisionData)
      assert(
        type(cell.terrainData) == "table" and cell.terrainData.schema == MapAssetCache.TERRAIN_SCHEMA,
        "field cell terrain schema mismatch"
      )
    end
  end
  return { meshes = bundle.meshes, textures = encodedTextures }
end

---@param stage CacheFs
---@param cacheFs CacheFs
---@return FieldCellCache.FileSystem
local function validationCache(stage, cacheFs)
  local function exists(_, path, expectedType)
    return stage:exists(path, expectedType) or cacheFs:exists(path, expectedType)
  end
  local function read(_, path)
    if stage:exists(path, "file") then
      return stage:read(path)
    end
    return cacheFs:read(path)
  end
  local function loadLua(_, path)
    if stage:exists(path, "file") then
      return stage:loadLua(path)
    end
    return cacheFs:loadLua(path)
  end
  return {
    exists = exists,
    read = read,
    loadLua = loadLua,
  }
end

local function writeSharedAssets(cacheFs, encoded, models)
  for sha1, bytes in pairs(encoded.meshes) do
    cacheFs:write(MapAssetCache.geometryPath(sha1), bytes)
  end
  for sha1, bytes in pairs(encoded.textures) do
    cacheFs:write(MapAssetCache.texturePath(sha1), bytes)
  end
  for modelKey, model in pairs(models) do
    cacheFs:writeLua(MapAssetCache.modelPath(modelKey), model)
  end
end

local function persist(cacheFs, tx, bundle)
  local encoded = validateBundle(bundle)
  local stage = tx.stage
  writeSharedAssets(stage, encoded, bundle.models)
  for _, matrix in ipairs(bundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(bundle.cells[descriptor.matrixMemberId .. ":" .. descriptor.index])
      assert(cell.schema == FieldCellCache.CELL_SCHEMA, "field cell schema mismatch")
      local descriptorCell = {}
      for key, value in pairs(cell) do
        if key ~= "collisionData" and key ~= "terrainData" then
          descriptorCell[key] = value
        end
      end
      stage:writeLua(descriptor.file, descriptorCell)
      stage:write(
        FieldCellCache.collisionPath(descriptor.matrixMemberId, descriptor.index),
        CollisionGridAsset.encode(cell.collisionData)
      )
      stage:writeLua(FieldCellCache.terrainPath(descriptor.matrixMemberId, descriptor.index), cell.terrainData)
    end
  end
  stage:writeLua(FieldCellCache.indexPath(), bundle.index)
  local index = FieldCellCache.loadIndex(stage)
  for _, matrix in ipairs(index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(stage:loadLua(descriptor.file))
      assert(
        FieldCellCache.validateCell(validationCache(stage, cacheFs), cell, descriptor),
        "field cell did not validate after staging"
      )
    end
  end
  stage:write(FieldCellCache.markerPath(), bundle.marker)
  writeSharedAssets(cacheFs, encoded, bundle.models)
  return bundle.marker
end

function Writer.isReady(cacheFs, marker)
  return FieldCellCache.isReady(cacheFs, marker)
end

function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-cells", { FieldCellCache.dir() })
  local ok, result = pcall(persist, cacheFs, tx, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return Writer
