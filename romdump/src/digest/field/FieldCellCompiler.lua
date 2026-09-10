-- Normalizes every valid matrix cell into an independently addressable
-- runtime payload. Source interpretation stays here; the engine sees only the
-- generated index and cell contracts.

local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local BuildingModelCompiler = require("romdump.src.digest.map.BuildingModelCompiler")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local AreaData = require("romdump.src.digest.map.AreaData")
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

local function compile(romFs)
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrices, cells = {}, {}
  local meshes, textures, models = {}, {}, {}
  local matrixMembers = {}
  local buildingCache, terrainAnimationCompilers, terrainAnimationClips = {}, {}, {}
  for record in MapCatalog.all() do
    if not matrixMembers[record.matrixMemberId] then
      matrixMembers[record.matrixMemberId] = true
      local bytes = readMember(matrixNarc, record.matrixMemberId)
      local matrix = assert(MapMatrix.decode(bytes, record.id))
      local matrixRecord = {
        matrixMemberId = record.matrixMemberId,
        width = matrix.width,
        height = matrix.height,
        cells = {},
      }
      matrices[#matrices + 1] = matrixRecord
      for z = 0, matrix.height - 1 do
        for x = 0, matrix.width - 1 do
          local source = matrix:cell(x, z)
          local header = MapCatalog.areaForMapHeader(source.mapHeaderId)
          if header and source.landDataMemberId ~= 0xFFFF then
            local key = string.format("%d:%d", record.matrixMemberId, matrix:index(x, z))
            if not cells[key] then
              local animationKey = tostring(header.areaDataMemberId)
              local terrainAnimationCompiler = terrainAnimationCompilers[animationKey]
              if terrainAnimationCompiler == nil then
                local area = assert(
                  AreaData.decode(
                    readMember(assert(romFs:openNarc("area_data")), header.areaDataMemberId),
                    { alias = "area_data", memberId = header.areaDataMemberId }
                  )
                )
                terrainAnimationCompiler = TerrainAnimationCompiler.new(romFs, {
                  mapId = source.mapHeaderId,
                  dynamicTextureType = area.dynamicTextureType,
                })
                terrainAnimationCompilers[animationKey] = terrainAnimationCompiler
              end
              local chunk = NeighborChunkCompiler.compile(romFs, source.landDataMemberId, header.areaDataMemberId, {
                mapId = source.mapHeaderId,
                mapSymbol = header.symbol,
                terrainAnimationCompiler = terrainAnimationCompiler,
              })
              for sha1, mesh in pairs(chunk.meshes) do
                meshes[sha1] = mesh
              end
              for sha1, texture in pairs(chunk.textures) do
                textures[sha1] = texture
              end

              local buildingKey = string.format("%d:%d", source.landDataMemberId, header.areaDataMemberId)
              local building = buildingCache[buildingKey]
              if building == nil then
                building = BuildingModelCompiler.compile(romFs, chunk.area, chunk.land, {
                  mapId = source.mapHeaderId,
                  mapSymbol = header.symbol,
                  areaDataMemberId = header.areaDataMemberId,
                  landDataMemberId = source.landDataMemberId,
                  meshes = meshes,
                  textures = textures,
                  finalizeMeshes = true,
                })
                buildingCache[buildingKey] = building
              end
              for modelKey, model in pairs(building.models) do
                models[modelKey] = model
              end
              local textureSrt
              if terrainAnimationClips[animationKey] == nil then
                textureSrt = terrainAnimationCompiler:compileTextureSrt()
                terrainAnimationClips[animationKey] = textureSrt
              else
                textureSrt = terrainAnimationClips[animationKey]
              end

              local index = matrix:index(x, z)
              local descriptor = {
                matrixMemberId = record.matrixMemberId,
                index = index,
                x = x,
                z = z,
                mapHeaderId = source.mapHeaderId,
                altitude = source.altitude,
                landDataMemberId = source.landDataMemberId,
                areaDataMemberId = header.areaDataMemberId,
                file = FieldCellCache.cellPath(record.matrixMemberId, index),
              }
              matrixRecord.cells[#matrixRecord.cells + 1] = descriptor
              cells[key] = {
                schema = FieldCellCache.CELL_SCHEMA,
                matrixMemberId = record.matrixMemberId,
                index = index,
                x = x,
                z = z,
                mapHeaderId = source.mapHeaderId,
                origin = {
                  x = x * 32,
                  y = MapUnits.altitudeDeltaToTiles(source.altitude),
                  z = z * 32,
                },
                altitude = source.altitude,
                landDataMemberId = source.landDataMemberId,
                areaDataMemberId = header.areaDataMemberId,
                batches = chunk.batches,
                materials = chunk.materials,
                buildingInstances = building.buildingInstances,
                terrainAnimations = { textureSrt = textureSrt },
                collision = {
                  width = 32,
                  height = 32,
                  file = FieldCellCache.collisionPath(record.matrixMemberId, index),
                },
                terrain = {
                  schema = chunk.terrain.schema,
                  file = FieldCellCache.terrainPath(record.matrixMemberId, index),
                },
                collisionData = chunk.collision,
                terrainData = chunk.terrain,
              }
            end
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
  local dependency = Hashing.hashLua({
    matrices = matrices,
    cells = cells,
    terrainAnimations = terrainAnimationClips,
  })
  return {
    marker = FieldCellCache.marker(romFs:metadata().sha1, dependency),
    index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = matrices },
    cells = cells,
    meshes = meshes,
    textures = textures,
    models = models,
  }
end

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "field cell compilation requires RomFs")
  local ok, result = pcall(compile, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Compiler
