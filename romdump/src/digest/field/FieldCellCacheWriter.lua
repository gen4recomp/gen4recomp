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

local function stageCell(stage, descriptor, cell, fallbackMarker)
  assert(cell.schema == FieldCellCache.CELL_SCHEMA, "field cell schema mismatch")
  local descriptorCell = {}
  for key, value in pairs(cell) do
    if key ~= "collisionData" and key ~= "terrainData" and key ~= "cellMarker" then
      descriptorCell[key] = value
    end
  end
  local marker = assert(cell.cellMarker or fallbackMarker, "field cell marker is required")
  assert(type(marker) == "string" and marker ~= "", "field cell marker is invalid")
  assert(type(cell.dependencies) == "table", "field cell dependencies are required")
  assert(cell.dependencies.marker == marker, "field cell dependency marker mismatch")
  assert(
    cell.dependencies.matrixMemberId == descriptor.matrixMemberId and cell.dependencies.index == descriptor.index,
    "field cell dependency identity mismatch"
  )
  descriptorCell.cellMarker = marker
  stage:writeLua(descriptor.file, descriptorCell)
  stage:write(
    FieldCellCache.collisionPath(descriptor.matrixMemberId, descriptor.index),
    CollisionGridAsset.encode(cell.collisionData)
  )
  stage:writeLua(FieldCellCache.terrainPath(descriptor.matrixMemberId, descriptor.index), cell.terrainData)
  stage:writeLua(FieldCellCache.dependenciesPath(descriptor.matrixMemberId, descriptor.index), cell.dependencies or {
    marker = marker,
    matrixMemberId = descriptor.matrixMemberId,
    index = descriptor.index,
  })
  stage:write(FieldCellCache.cellMarkerPath(descriptor.matrixMemberId, descriptor.index), marker)
end

function Writer.stageIndex(stage, index)
  assert(FieldCellCache.validateIndex(index), "field cell index is malformed")
  stage:writeLua(FieldCellCache.indexPath(), index)
end

function Writer.stageCell(stage, descriptor, cell, fallbackMarker)
  stageCell(stage, descriptor, cell, fallbackMarker)
end

function Writer.stageComplete(stage, marker)
  assert(type(marker) == "string" and marker ~= "", "field cell corpus marker is required")
  stage:write(FieldCellCache.markerPath(), marker)
end

function Writer.stagePrepared(prepared, descriptor, result)
  assert(prepared and prepared.stageFs and prepared.addOwnedRoot, "prepared field cell artifact is required")
  assert(
    type(result) == "table" and result.cell and result.meshes and result.textures and result.models,
    "invalid cell result"
  )
  local stage = prepared:stageFs()
  local cell = result.cell
  local encoded = validateBundle({
    index = {
      schema = FieldCellCache.INDEX_SCHEMA,
      matrices = {
        {
          matrixMemberId = descriptor.matrixMemberId,
          width = descriptor.x + 1,
          height = descriptor.z + 1,
          cells = { descriptor },
        },
      },
    },
    cells = { [descriptor.matrixMemberId .. ":" .. descriptor.index] = cell },
    meshes = result.meshes,
    textures = result.textures,
    models = result.models,
    marker = cell.cellMarker,
  })
  writeSharedAssets(stage, encoded, result.models)
  for sha1 in pairs(encoded.meshes) do
    prepared:addSharedFile(MapAssetCache.geometryPath(sha1))
  end
  for sha1 in pairs(encoded.textures) do
    prepared:addSharedFile(MapAssetCache.texturePath(sha1))
  end
  for modelKey in pairs(result.models) do
    prepared:addSharedFile(MapAssetCache.modelPath(modelKey))
  end
  stageCell(stage, descriptor, cell, assert(cell.cellMarker))
  prepared:addOwnedRoot(FieldCellCache.cellDir(descriptor.matrixMemberId, descriptor.index))
  assert(
    FieldCellCache.validateCell(validationCache(stage, prepared:cacheFs()), stage:loadLua(descriptor.file), descriptor),
    "field cell did not validate after staging"
  )
end

function Writer.writeIndex(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(
    cacheFs,
    "field-cell-index",
    { FieldCellCache.indexPath(), FieldCellCache.indexMarkerPath() }
  )
  tx.stage:writeLua(FieldCellCache.indexPath(), bundle.index)
  tx.stage:write(FieldCellCache.indexMarkerPath(), assert(bundle.indexMarker))
  tx:publish()
end

function Writer.writeComplete(cacheFs, marker)
  local tx = ArtifactPublisher.begin(cacheFs, "field-cell-complete", { FieldCellCache.markerPath() })
  tx.stage:write(FieldCellCache.markerPath(), marker)
  tx:publish()
end

local function persist(cacheFs, tx, bundle)
  local encoded = validateBundle(bundle)
  local stage = tx.stage
  writeSharedAssets(stage, encoded, bundle.models)
  for _, matrix in ipairs(bundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(bundle.cells[descriptor.matrixMemberId .. ":" .. descriptor.index])
      stageCell(stage, descriptor, cell, bundle.marker)
    end
  end
  Writer.stageIndex(stage, bundle.index)
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
  Writer.stageComplete(stage, bundle.marker)
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
