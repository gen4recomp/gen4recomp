-- Defines the strict generated physical-cell cache. Runtime consumers resolve
-- matrix coordinates from this index and never need ROM or logical-map scenes.

local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local Contract = require("libs.assets.src.DerivedAssetContract")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AssetErrors = require("libs.assets.src.errors")

---@class FieldCellCache.FileSystem
---@field exists fun(self: FieldCellCache.FileSystem, path: string, expectedType?: string): boolean
---@field read fun(self: FieldCellCache.FileSystem, path: string): string?
---@field loadLua fun(self: FieldCellCache.FileSystem, path: string): table<string, unknown>?

local FieldCellCache = {}
FieldCellCache.FORMAT = Contract.fieldCells.cacheFormat
FieldCellCache.INDEX_SCHEMA = Contract.fieldCells.indexSchema
FieldCellCache.CELL_SCHEMA = Contract.fieldCells.cellSchema

local ROOT = "data/generated/field/cells"

function FieldCellCache.dir()
  return ROOT
end
function FieldCellCache.indexPath()
  return ROOT .. "/index.lua"
end
function FieldCellCache.markerPath()
  return ROOT .. "/complete"
end
function FieldCellCache.indexMarkerPath()
  return ROOT .. "/index.complete"
end
function FieldCellCache.cellDir(matrixMemberId, index)
  return string.format("%s/%d/%d", ROOT, matrixMemberId, index)
end
function FieldCellCache.cellPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/cell.lua"
end
function FieldCellCache.collisionPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/collision.g4collision"
end
function FieldCellCache.terrainPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/terrain.lua"
end
function FieldCellCache.dependenciesPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/dependencies.lua"
end
function FieldCellCache.cellMarkerPath(matrixMemberId, index)
  return FieldCellCache.cellDir(matrixMemberId, index) .. "/complete"
end
function FieldCellCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", FieldCellCache.FORMAT, romSha1, dependencyHash)
end
function FieldCellCache.indexMarker(romSha1, dependencyHash)
  return string.format("%s:index:%s:%s", FieldCellCache.FORMAT, romSha1, dependencyHash)
end
function FieldCellCache.cellMarker(romSha1, matrixMemberId, index, dependencyHash)
  return string.format("%s:%s:%d:%d:%s", FieldCellCache.FORMAT, romSha1, matrixMemberId, index, dependencyHash)
end

local function validId(value)
  return Validate.isNonNegativeInteger(value)
end

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validCell(record, matrix)
  return type(record) == "table"
    and validId(record.matrixMemberId)
    and validId(record.index)
    and validId(record.x)
    and validId(record.z)
    and record.x < matrix.width
    and record.z < matrix.height
    and validId(record.mapHeaderId)
    and validId(record.altitude)
    and validId(record.landDataMemberId)
    and validId(record.areaDataMemberId)
    and record.file == FieldCellCache.cellPath(matrix.matrixMemberId, record.index)
end

local function validateIndex(index)
  if type(index) ~= "table" or index.schema ~= FieldCellCache.INDEX_SCHEMA or not Validate.isArray(index.matrices) then
    return false
  end
  local seenMatrices = {}
  for _, matrix in ipairs(index.matrices) do
    if
      type(matrix) ~= "table"
      or not validId(matrix.matrixMemberId)
      or not validId(matrix.width)
      or not validId(matrix.height)
      or matrix.width < 1
      or matrix.height < 1
      or not Validate.isArray(matrix.cells)
      or seenMatrices[matrix.matrixMemberId]
    then
      return false
    end
    seenMatrices[matrix.matrixMemberId] = true
    local seenCells = {}
    local seenCoordinates = {}
    for _, cell in ipairs(matrix.cells) do
      local coordinateKey = type(cell) == "table" and string.format("%s:%s", cell.x, cell.z) or "invalid"
      if
        not validCell(cell, matrix)
        or cell.matrixMemberId ~= matrix.matrixMemberId
        or seenCells[cell.index]
        or seenCoordinates[coordinateKey]
      then
        return false
      end
      seenCells[cell.index] = true
      seenCoordinates[coordinateKey] = true
    end
  end
  return true
end

local function validateExpectedCell(cell, expected)
  if expected ~= nil and type(expected) ~= "table" then
    return false
  end
  if
    expected ~= nil
    and (
      cell.matrixMemberId ~= expected.matrixMemberId
      or cell.index ~= expected.index
      or cell.x ~= expected.x
      or cell.z ~= expected.z
      or cell.mapHeaderId ~= expected.mapHeaderId
      or cell.altitude ~= expected.altitude
      or cell.landDataMemberId ~= expected.landDataMemberId
      or cell.areaDataMemberId ~= expected.areaDataMemberId
    )
  then
    return false
  end
  return true
end

local function validateCellIdentity(cell)
  for _, key in ipairs({
    "matrixMemberId",
    "index",
    "x",
    "z",
    "mapHeaderId",
    "altitude",
    "landDataMemberId",
    "areaDataMemberId",
  }) do
    if not validId(cell[key]) then
      return false
    end
  end
  return true
end

local function validateCellOrigin(cell)
  return type(cell.origin) == "table"
    and validId(cell.origin.x)
    and finiteNumber(cell.origin.y)
    and validId(cell.origin.z)
    and cell.origin.x == cell.x * 32
    and cell.origin.z == cell.z * 32
end

local function validateCellArtifacts(cell)
  return type(cell.collision) == "table"
    and type(cell.collision.file) == "string"
    and type(cell.terrain) == "table"
    and type(cell.terrain.file) == "string"
    and cell.collision.file == FieldCellCache.collisionPath(cell.matrixMemberId, cell.index)
    and cell.terrain.file == FieldCellCache.terrainPath(cell.matrixMemberId, cell.index)
    and cell.terrain.schema == MapAssetCache.TERRAIN_SCHEMA
    and Validate.isArray(cell.batches)
    and Validate.isArray(cell.materials)
    and Validate.isArray(cell.buildingInstances)
    and type(cell.terrainAnimations) == "table"
end

local function validateCalibration(calibration)
  return type(calibration) == "table"
    and finiteNumber(calibration.modelExtentTilesX)
    and finiteNumber(calibration.modelExtentTilesZ)
    and calibration.modelExtentTilesX > 0
    and calibration.modelExtentTilesZ > 0
    and finiteNumber(calibration.posScale)
    and calibration.posScale > 0
end

local function validateBuildingInstances(cell)
  for _, instance in ipairs(cell.buildingInstances) do
    if
      type(instance) ~= "table"
      or not validId(instance.placementIndex)
      or type(instance.modelKey) ~= "string"
      or not Validate.isArray(instance.transform)
      or #instance.transform ~= 16
    then
      return false
    end
    for _, value in ipairs(instance.transform) do
      if not finiteNumber(value) then
        return false
      end
    end
  end
  return true
end

local function validateCellContent(cacheFs, cell)
  if
    cell.collision.width ~= 32
    or cell.collision.height ~= 32
    or not cacheFs:exists(cell.collision.file, "file")
    or not cacheFs:exists(cell.terrain.file, "file")
  then
    return false
  end
  local terrain = cacheFs:loadLua(cell.terrain.file)
  if type(terrain) ~= "table" or terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
    return false
  end
  local bytes = cacheFs:read(cell.collision.file)
  local collision = bytes and CollisionGridAsset.decode(bytes)
  return collision ~= nil and collision.width == 32 and collision.height == 32
end

local function validateReferencedPaths(cacheFs, cell)
  local ok, paths = pcall(MapAssetCache.referencedPaths, {
    schema = MapAssetCache.SCENE_SCHEMA,
    kind = "field-cell",
    terrainAnimations = cell.terrainAnimations,
    mapBatches = cell.batches,
    materials = cell.materials,
    buildingInstances = cell.buildingInstances,
    neighbors = {},
  }, cacheFs)
  if not ok then
    local errorValue = paths ---@cast errorValue Errors.Error
    if Errors.is(errorValue) and errorValue.code == AssetErrors.MAP_CACHE_SCENE_INVALID then
      return false
    end
    error(errorValue)
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

---@param index table<string, unknown>
---@return boolean
function FieldCellCache.validateIndex(index)
  return validateIndex(index)
end

---@param cacheFs CacheFs|FieldCellCache.FileSystem
---@param cell table<string, unknown>
---@param expected? unknown
---@return boolean
function FieldCellCache.validateCell(cacheFs, cell, expected)
  if type(cell) ~= "table" or cell.schema ~= FieldCellCache.CELL_SCHEMA then
    return false
  end
  if not validateExpectedCell(cell, expected) then
    return false
  end
  if not validateCellIdentity(cell) then
    return false
  end
  if not validateCellOrigin(cell) then
    return false
  end
  if not validateCellArtifacts(cell) then
    return false
  end
  if not validateCalibration(cell.calibration) then
    return false
  end
  if not validateBuildingInstances(cell) then
    return false
  end
  if not validateCellContent(cacheFs, cell) then
    return false
  end
  return validateReferencedPaths(cacheFs, cell)
end

function FieldCellCache.isCellReady(cacheFs, descriptor, expectedMarker)
  if type(descriptor) ~= "table" or type(expectedMarker) ~= "string" then
    return false
  end
  if cacheFs:read(FieldCellCache.cellMarkerPath(descriptor.matrixMemberId, descriptor.index)) ~= expectedMarker then
    return false
  end
  local cell = cacheFs:loadLua(descriptor.file)
  if not FieldCellCache.validateCell(cacheFs, cell, descriptor) then
    return false
  end
  local dependencies = cacheFs:loadLua(FieldCellCache.dependenciesPath(descriptor.matrixMemberId, descriptor.index))
  local identity = type(dependencies) == "table" and dependencies.descriptor
  return type(dependencies) == "table"
    and type(identity) == "table"
    and dependencies.marker == expectedMarker
    and dependencies.matrixMemberId == descriptor.matrixMemberId
    and dependencies.index == descriptor.index
    and identity.matrixMemberId == descriptor.matrixMemberId
    and identity.index == descriptor.index
    and identity.x == descriptor.x
    and identity.z == descriptor.z
    and identity.mapHeaderId == descriptor.mapHeaderId
    and identity.altitude == descriptor.altitude
    and identity.landDataMemberId == descriptor.landDataMemberId
    and identity.areaDataMemberId == descriptor.areaDataMemberId
end

function FieldCellCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldCellCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldCellCache.indexPath())
  if not validateIndex(index) then
    return false
  end
  for _, matrix in ipairs(index.matrices) do
    for _, entry in ipairs(matrix.cells) do
      local cellMarker = cacheFs:read(FieldCellCache.cellMarkerPath(entry.matrixMemberId, entry.index))
      if not FieldCellCache.isCellReady(cacheFs, entry, cellMarker) then
        return false
      end
    end
  end
  return true
end

function FieldCellCache.loadIndex(cacheFs)
  local index = cacheFs:loadLua(FieldCellCache.indexPath())
  assert(validateIndex(index), "field cell index is malformed")
  return index
end

function FieldCellCache.find(index, matrixMemberId, x, z)
  for _, matrix in ipairs(index.matrices) do
    if matrix.matrixMemberId == matrixMemberId then
      for _, cell in ipairs(matrix.cells) do
        if cell.x == x and cell.z == z then
          return cell
        end
      end
      return nil
    end
  end
  return nil
end

return FieldCellCache
