-- Plans and compiles one canonical physical matrix cell at a time.

local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local BuildingModelCompiler = require("romdump.src.digest.map.BuildingModelCompiler")
local NeighborChunkCompiler = require("romdump.src.digest.map.NeighborChunkCompiler")
local TerrainAnimationCompiler = require("romdump.src.digest.map.TerrainAnimationCompiler")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local Hashing = require("romdump.src.digest.Hashing")
local Errors = require("libs.errors.src.Errors")

local Compiler = {}

local function readMember(narc, memberId)
  assert(memberId >= 0 and memberId < narc:memberCount(), "matrix member out of range")
  return assert(narc:readMember(memberId))
end

local function descriptorKey(descriptor)
  return string.format("%d:%d", descriptor.matrixMemberId, descriptor.index)
end

local function descriptorIdentity(descriptor)
  return {
    matrixMemberId = descriptor.matrixMemberId,
    index = descriptor.index,
    x = descriptor.x,
    z = descriptor.z,
    mapHeaderId = descriptor.mapHeaderId,
    altitude = descriptor.altitude,
    landDataMemberId = descriptor.landDataMemberId,
    areaDataMemberId = descriptor.areaDataMemberId,
  }
end

local function expectedMarker(romSha1, descriptor, producerFingerprint)
  local dependency = Hashing.hashLua({
    producerFingerprint = producerFingerprint or "",
    cacheFormat = FieldCellCache.FORMAT,
    indexSchema = FieldCellCache.INDEX_SCHEMA,
    cellSchema = FieldCellCache.CELL_SCHEMA,
    descriptor = descriptorIdentity(descriptor),
  })
  return FieldCellCache.cellMarker(romSha1, descriptor.matrixMemberId, descriptor.index, dependency), dependency
end

local function descriptorFor(matrixMemberId, matrix, x, z, source)
  local index = matrix:index(x, z)
  local header = MapCatalog.areaForMapHeader(source.mapHeaderId)
  assert(header and source.landDataMemberId ~= 0xFFFF, "cell is not a valid physical field cell")
  return {
    matrixMemberId = matrixMemberId,
    index = index,
    x = x,
    z = z,
    mapHeaderId = source.mapHeaderId,
    altitude = source.altitude,
    landDataMemberId = source.landDataMemberId,
    areaDataMemberId = header.areaDataMemberId,
    file = FieldCellCache.cellPath(matrixMemberId, index),
  }
end

local function readDescriptorSource(romFs, descriptor)
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local bytes = readMember(matrixNarc, descriptor.matrixMemberId)
  local matrix = assert(MapMatrix.decode(bytes, descriptor.mapHeaderId))
  assert(descriptor.x < matrix.width and descriptor.z < matrix.height, "field cell coordinate is out of range")
  local source = matrix:cell(descriptor.x, descriptor.z)
  local expected = descriptorFor(descriptor.matrixMemberId, matrix, descriptor.x, descriptor.z, source)
  for key, value in pairs(descriptorIdentity(expected)) do
    assert(descriptor[key] == value, "field cell descriptor does not match the current matrix")
  end
  return matrix, source, MapCatalog.areaForMapHeader(source.mapHeaderId)
end

local function compileCell(romFs, descriptor, scratch, producerFingerprint)
  local _, source, header = readDescriptorSource(romFs, descriptor)
  local marker, dependencyHash = expectedMarker(romFs:metadata().sha1, descriptor, producerFingerprint)
  local animationCompilers = scratch and scratch.terrainAnimationCompilers
  if animationCompilers == nil and scratch then
    animationCompilers = {}
    scratch.terrainAnimationCompilers = animationCompilers
  end
  local animationKey = string.format("%d:%d", descriptor.areaDataMemberId, source.mapHeaderId)
  local terrainAnimationCompiler = animationCompilers and animationCompilers[animationKey]
  if terrainAnimationCompiler == nil then
    terrainAnimationCompiler = TerrainAnimationCompiler.new(romFs, {
      mapId = source.mapHeaderId,
      dynamicTextureType = assert(header).dynamicTextureType,
    })
    if animationCompilers then
      animationCompilers[animationKey] = terrainAnimationCompiler
    end
  end
  local chunk = NeighborChunkCompiler.compile(romFs, descriptor.landDataMemberId, descriptor.areaDataMemberId, {
    mapId = source.mapHeaderId,
    mapSymbol = assert(header).symbol,
    terrainAnimationCompiler = terrainAnimationCompiler,
    geometryArena = scratch and scratch.geometryArena,
    gxScratch = scratch and scratch.gxScratch,
  })
  local building = BuildingModelCompiler.compile(romFs, chunk.area, chunk.land, {
    mapId = source.mapHeaderId,
    mapSymbol = assert(header).symbol,
    areaDataMemberId = descriptor.areaDataMemberId,
    landDataMemberId = descriptor.landDataMemberId,
    meshes = chunk.meshes,
    textures = chunk.textures,
    finalizeMeshes = true,
    geometryArena = scratch and scratch.geometryArena,
    gxScratch = scratch and scratch.gxScratch,
  })
  local textureSrt = terrainAnimationCompiler:compileTextureSrt()
  local dependencies = {
    marker = marker,
    dependencyHash = dependencyHash,
    matrixMemberId = descriptor.matrixMemberId,
    index = descriptor.index,
    descriptor = descriptorIdentity(descriptor),
    mapHeaderId = descriptor.mapHeaderId,
    landDataMemberId = descriptor.landDataMemberId,
    areaDataMemberId = descriptor.areaDataMemberId,
    buildingModelShas = building.buildingModelShas,
    terrainAnimation = terrainAnimationCompiler:dependencies(),
  }
  return {
    cell = {
      schema = FieldCellCache.CELL_SCHEMA,
      matrixMemberId = descriptor.matrixMemberId,
      index = descriptor.index,
      x = descriptor.x,
      z = descriptor.z,
      mapHeaderId = descriptor.mapHeaderId,
      origin = { x = descriptor.x * 32, y = source.altitude / 16, z = descriptor.z * 32 },
      altitude = descriptor.altitude,
      landDataMemberId = descriptor.landDataMemberId,
      areaDataMemberId = descriptor.areaDataMemberId,
      batches = chunk.batches,
      materials = chunk.materials,
      buildingInstances = building.buildingInstances,
      modelKeyOf = building.modelKeyOf,
      terrainAnimations = { textureSrt = textureSrt },
      calibration = chunk.calibration,
      collision = {
        width = 32,
        height = 32,
        file = FieldCellCache.collisionPath(descriptor.matrixMemberId, descriptor.index),
      },
      terrain = {
        schema = chunk.terrain.schema,
        file = FieldCellCache.terrainPath(descriptor.matrixMemberId, descriptor.index),
      },
      collisionData = chunk.collision,
      terrainData = chunk.terrain,
      cellMarker = marker,
      dependencies = dependencies,
    },
    meshes = chunk.meshes,
    textures = chunk.textures,
    models = building.models,
    unresolvedMaterials = chunk.unresolved,
  }
end

local function compileIndex(romFs, producerFingerprint)
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrices, seen = {}, {}
  for record in MapCatalog.all() do
    if not seen[record.matrixMemberId] then
      seen[record.matrixMemberId] = true
      local matrix = assert(MapMatrix.decode(readMember(matrixNarc, record.matrixMemberId), record.id))
      local matrixRecord =
        { matrixMemberId = record.matrixMemberId, width = matrix.width, height = matrix.height, cells = {} }
      matrices[#matrices + 1] = matrixRecord
      for z = 0, matrix.height - 1 do
        for x = 0, matrix.width - 1 do
          local source = matrix:cell(x, z)
          if MapCatalog.areaForMapHeader(source.mapHeaderId) and source.landDataMemberId ~= 0xFFFF then
            matrixRecord.cells[#matrixRecord.cells + 1] = descriptorFor(record.matrixMemberId, matrix, x, z, source)
          end
        end
      end
    end
  end
  table.sort(matrices, function(a, b)
    return a.matrixMemberId < b.matrixMemberId
  end)
  for _, matrix in ipairs(matrices) do
    table.sort(matrix.cells, function(a, b)
      return a.index < b.index
    end)
  end
  local dependencies = {
    producerFingerprint = producerFingerprint or "",
    romSha1 = romFs:metadata().sha1,
    cacheFormat = FieldCellCache.FORMAT,
    indexSchema = FieldCellCache.INDEX_SCHEMA,
    matrices = matrices,
  }
  return {
    marker = FieldCellCache.marker(romFs:metadata().sha1, Hashing.hashLua(dependencies)),
    indexMarker = FieldCellCache.indexMarker(romFs:metadata().sha1, Hashing.hashLua(dependencies)),
    index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = matrices },
    dependencies = dependencies,
  }
end

function Compiler.compileIndex(romFs, producerFingerprint)
  assert(romFs and romFs.openNarc, "field cell index compilation requires RomFs")
  local ok, result = pcall(compileIndex, romFs, producerFingerprint)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function Compiler.planCell(romFs, descriptor, producerFingerprint)
  assert(type(descriptor) == "table", "field cell descriptor is required")
  readDescriptorSource(romFs, descriptor)
  local marker, dependencyHash = expectedMarker(romFs:metadata().sha1, descriptor, producerFingerprint)
  return {
    descriptor = descriptor,
    dependencies = { dependencyHash = dependencyHash, descriptor = descriptorIdentity(descriptor) },
    expectedMarker = marker,
    jobIdentity = "field-cell:" .. descriptorKey(descriptor),
  }
end

function Compiler.compileCell(romFs, descriptor, scratch, producerFingerprint, expectedPlan)
  local plan = expectedPlan or Compiler.planCell(romFs, descriptor, producerFingerprint)
  local result = compileCell(romFs, descriptor, scratch, producerFingerprint)
  assert(result.cell.cellMarker == plan.expectedMarker, "compiled field cell marker differs from its plan")
  return result
end

function Compiler.compile(romFs, producerFingerprint)
  local indexBundle = assert(Compiler.compileIndex(romFs, producerFingerprint))
  local bundle = {
    marker = indexBundle.marker,
    indexMarker = indexBundle.indexMarker,
    index = indexBundle.index,
    dependencies = indexBundle.dependencies,
    cells = {},
    meshes = {},
    textures = {},
    models = {},
  }
  for _, matrix in ipairs(indexBundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local result = assert(Compiler.compileCell(romFs, descriptor, {}, producerFingerprint))
      bundle.cells[descriptorKey(descriptor)] = result.cell
      for key, value in pairs(result.meshes) do
        bundle.meshes[key] = value
      end
      for key, value in pairs(result.textures) do
        bundle.textures[key] = value
      end
      for key, value in pairs(result.models) do
        bundle.models[key] = value
      end
    end
  end
  return bundle
end

return Compiler
