-- Maps one logical scene to its canonical physical-cell prerequisites.

local Errors = require("libs.errors.src.Errors")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local NeighborPlan = require("romdump.src.digest.map.NeighborPlan")

local MapCompilePlan = {}

local function indexValue(index)
  return index and index.index or index
end

local function lookup(index, matrixMemberId, x, z)
  local descriptor = FieldCellCache.find(indexValue(index), matrixMemberId, x, z)
  if descriptor == nil then
    Errors.raise(
      "MAP_CELL_PREREQUISITE_MISSING",
      string.format("canonical field cell %d/%d/%d is absent", matrixMemberId, x, z),
      { matrixMemberId = matrixMemberId, x = x, z = z }
    )
  end
  return assert(descriptor)
end

local function plan(romFs, fieldCellIndex, mapId, producerFingerprint)
  local resolved = assert(MapResolver.resolve(romFs, mapId))
  local central = lookup(fieldCellIndex, resolved.matrixMemberId, resolved.matrixX, resolved.matrixZ)
  local neighbors = NeighborPlan.plan(resolved.matrix, resolved.matrixX, resolved.matrixZ, function(mapHeaderId)
    local record = MapCatalog.areaForMapHeader(mapHeaderId)
    return record and record.areaDataMemberId or nil
  end)
  local placements = {
    {
      cell = central,
      offsetTilesX = 0,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      mapHeaderId = central.mapHeaderId,
      landDataMemberId = central.landDataMemberId,
    },
  }
  for _, neighbor in ipairs(neighbors.cells) do
    placements[#placements + 1] = {
      cell = lookup(fieldCellIndex, resolved.matrixMemberId, neighbor.x, neighbor.z),
      offsetTilesX = neighbor.offsetTilesX,
      offsetTilesY = neighbor.offsetTilesY,
      offsetTilesZ = neighbor.offsetTilesZ,
      mapHeaderId = neighbor.mapHeaderId,
      landDataMemberId = neighbor.landDataMemberId,
      areaDataMemberId = neighbor.areaDataMemberId,
    }
  end

  local unique = {}
  for _, placement in ipairs(placements) do
    local descriptor = placement.cell
    unique[descriptor.matrixMemberId .. ":" .. descriptor.index] = descriptor
  end
  local descriptors = {}
  for _, descriptor in pairs(unique) do
    descriptors[#descriptors + 1] = descriptor
  end
  table.sort(descriptors, function(a, b)
    return a.matrixMemberId < b.matrixMemberId or (a.matrixMemberId == b.matrixMemberId and a.index < b.index)
  end)
  local cellPlans = {}
  for _, descriptor in ipairs(descriptors) do
    cellPlans[#cellPlans + 1] = FieldCellCompiler.planCell(romFs, descriptor, producerFingerprint)
  end
  local cellDependencies = {}
  for _, cellPlan in ipairs(cellPlans) do
    cellDependencies[#cellDependencies + 1] = {
      matrixMemberId = cellPlan.descriptor.matrixMemberId,
      index = cellPlan.descriptor.index,
      marker = cellPlan.expectedMarker,
    }
  end
  local dependencies = {
    cacheFormat = MapAssetCache.FORMAT,
    romSha1 = romFs:metadata().sha1,
    producerFingerprint = producerFingerprint or "",
    mapId = resolved.map.id,
    mapCatalogRecord = resolved.map,
    matrixMemberId = resolved.matrixMemberId,
    matrixIndex = resolved.matrixIndex,
    cells = cellDependencies,
  }
  return {
    central = central,
    neighbors = placements,
    resolved = {
      map = resolved.map,
      matrix = resolved.matrix,
      matrixMemberId = resolved.matrixMemberId,
      matrixX = resolved.matrixX,
      matrixZ = resolved.matrixZ,
      matrixIndex = resolved.matrixIndex,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
      areaDataMemberId = resolved.areaDataMemberId,
    },
    cellPlans = cellPlans,
    dependencies = dependencies,
    expectedMarker = MapAssetCache.marker(romFs:metadata().sha1, resolved.map.id, Hashing.hashLua(dependencies)),
    jobIdentity = "map:" .. resolved.map.id,
  }
end

function MapCompilePlan.plan(romFs, fieldCellIndex, mapId, producerFingerprint)
  assert(romFs and romFs.openNarc, "map compile planning requires RomFs")
  local ok, result = pcall(plan, romFs, fieldCellIndex, mapId, producerFingerprint)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return MapCompilePlan
