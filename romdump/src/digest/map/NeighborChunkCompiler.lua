-- Compiles a single neighboring land chunk's geometry, permissions, and BDHC
-- terrain. Unlike MapAssetCompiler it does not resolve a semantic map, emit a
-- scene descriptor, or touch the derived cache: it takes an explicit land-data
-- member plus the area-data member of that cell's own map header, decodes the
-- area/land/map-model/map-texture pack, and reuses ModelAssetCompiler.compileModel
-- to produce the same content-addressed batches/meshes/textures.
--
-- Using the cell's own area is a deliberate divergence. The engine binds every
-- streamed cell against the single map TEX0 of the AreaDataManager built from the
-- entry map header (pret/pokeheartgold `InitGraphicsAndManagers`,
-- `ov01_021F4BE8`), and crossing a cell boundary does not rebuild it
-- (`FieldMap_ChangeZone`); binding is by name and non-fatal, and no HGSS material
-- stores a texture format or address of its own, so a name the entry TEX0 lacks
-- leaves that material untextured. Emulating that exactly would leave whole
-- chunks of e.g. MAP_ROUTE_1 untextured, since a cell's names routinely exist in
-- only its own area's pack. The cell's own pack is the resource its model was
-- authored against, so it is what gets bound here.
--
-- Placed buildings are intentionally skipped. Runs under LÖVE (needs an open
-- RomFs); raw Nitro formats stop here just as in the main compiler.

local AreaData = require("romdump.src.digest.map.AreaData")
local LandData = require("romdump.src.digest.map.LandData")
local HgssBdhc = require("romdump.src.digest.map.HgssBdhc")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local Hashing = require("romdump.src.digest.Hashing")
local Errors = require("libs.errors.src.Errors")

local NeighborChunkCompiler = {}

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  return assert(narc:readMember(memberId))
end

-- Compile land member `landMemberId`, textured through the map-texture pack of
-- `areaMemberId` (the cell's own area-data member), into
-- { batches, materials, meshes, textures, collision, terrain }. The optional
-- `context.terrainAnimationCompiler` map-scoped terrain-animation compiler
-- rides the compileModel call so the cell's materials annotate against the
-- same fldtanime records and dependency set as the central terrain.
function NeighborChunkCompiler.compile(romFs, landMemberId, areaMemberId, context)
  local areaBytes = readMember(assert(romFs:openNarc("area_data")), "area_data", areaMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = areaMemberId }))

  local landBytes = readMember(assert(romFs:openNarc("land_data")), "land_data", landMemberId)
  local land = assert(LandData.decode(landBytes, { alias = "land_data", memberId = landMemberId }))
  local decodedTerrain = assert(
    HgssBdhc.decode(
      land.bdhcBytes,
      { alias = "land_data", memberId = landMemberId, offset = land.offsets.bdhc, size = land.sizes.bdhc }
    )
  )

  local mapNsbmd =
    assert(Nsbmd.decode(land.mapModelBytes, { alias = "land_data", memberId = landMemberId, section = "map-model" }))
  local mapModel = mapNsbmd.models[1]
  local modelExtentTilesX, modelExtentTilesZ = MapUnits.assertMapCalibration(mapModel.bounds, mapModel.info.posScale, {
    landDataMemberId = landMemberId,
    areaDataMemberId = areaMemberId,
  })

  local texBytes = readMember(assert(romFs:openNarc("map_textures")), "map_textures", area.mapTexturePackId)
  local texPack = assert(Nsbtx.decode(texBytes, { alias = "map_textures", memberId = area.mapTexturePackId }))

  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(mapModel, texPack, meshes, textures, {
    mapId = context and context.mapId or nil,
    mapSymbol = context and context.mapSymbol or nil,
    role = "neighbor",
    neighborCells = context and context.neighborCells or nil,
    terrainAnimationCompiler = context and context.terrainAnimationCompiler or nil,
    areaDataMemberId = areaMemberId,
    landDataMemberId = landMemberId,
    textureArchive = "map_textures",
    textureMemberId = area.mapTexturePackId,
    modelArchive = "land_data",
    modelMemberId = landMemberId,
    modelName = mapModel.name,
    finalizeMeshes = true,
    geometryArena = context and context.geometryArena or nil,
    gxScratch = context and context.gxScratch or nil,
    terrainScratch = context and context.terrainScratch or nil,
  })

  -- NeighborRing bakes a fixed world offset into each draw, so it has nowhere to
  -- put a camera-resolved billboard. No terrain model in the target world has a
  -- BB command; one that did would otherwise draw silently static.
  for _, batch in ipairs(compiled.batches) do
    if batch.transformMode then
      Errors.raise(
        "NEIGHBOR_CHUNK_BILLBOARD_UNSUPPORTED",
        "neighbor terrain batch requires transform mode " .. batch.transformMode,
        { landDataMemberId = landMemberId, modelName = mapModel.name, transformMode = batch.transformMode }
      )
    end
  end

  return {
    area = area,
    land = land,
    batches = compiled.batches,
    materials = compiled.materials,
    unresolved = compiled.unresolved,
    meshes = meshes,
    textures = textures,
    collision = land.collision,
    terrain = {
      schema = MapAssetCache.TERRAIN_SCHEMA,
      sourceFormat = decodedTerrain.schema,
      source = {
        landDataMemberId = landMemberId,
        bdhcOffset = land.offsets.bdhc,
        bdhcSize = land.sizes.bdhc,
        bdhcSha1 = Hashing.sha1hex(land.bdhcBytes),
      },
      counts = decodedTerrain.counts,
      points = decodedTerrain.points,
      slopes = decodedTerrain.slopes,
      heights = decodedTerrain.heights,
      plates = decodedTerrain.plates,
      strips = decodedTerrain.strips,
      accessEntries = decodedTerrain.accessEntries,
    },
    calibration = {
      modelExtentTilesX = modelExtentTilesX,
      modelExtentTilesZ = modelExtentTilesZ,
      posScale = mapModel.info.posScale,
    },
  }
end

return NeighborChunkCompiler
