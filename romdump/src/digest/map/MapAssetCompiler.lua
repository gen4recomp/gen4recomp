-- Orchestrates the full derived-map compile for one semantic map: resolve the
-- target, decode its area/land/model/texture members, compile the map geometry
-- and every unique placed-building model into normalized batches and
-- content-addressed textures, and assemble a serializable bundle -- the scene
-- descriptor, the raw permission grid, the keyed mesh/texture blobs, the model
-- descriptors, and a dependency record hashed into a completion marker. It
-- writes nothing; MapCacheWriter persists the bundle. Runs under LÖVE (needs an
-- open RomFs) but the raw Nitro formats stop here.

local MapResolver = require("romdump.src.digest.map.MapResolver")
local StarterLab = require("romdump.src.reference.hgss.starter_lab")
local AreaData = require("romdump.src.digest.map.AreaData")
local LandData = require("romdump.src.digest.map.LandData")
local HgssBdhc = require("romdump.src.digest.map.HgssBdhc")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local HgssFieldLighting = require("romdump.src.digest.field.HgssFieldLighting")
local HgssFieldLightProfile = require("romdump.src.digest.field.HgssFieldLightProfile")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local Matrix4 = require("libs.math.src.Matrix4")
local Hashing = require("romdump.src.digest.Hashing")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local NeighborPlan = require("romdump.src.digest.map.NeighborPlan")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local NeighborChunkCompiler = require("romdump.src.digest.map.NeighborChunkCompiler")
local TerrainAnimationCompiler = require("romdump.src.digest.map.TerrainAnimationCompiler")
local Errors = require("libs.errors.src.Errors")
local BuildingModelCompiler = require("romdump.src.digest.map.BuildingModelCompiler")

local MapAssetCompiler = {}

local COORDINATE_CONVENTION = "nsbmd-sbc-matrix-16-tile-v3"

local function appendUnresolved(target, source)
  for _, entry in ipairs(source.unresolved) do
    target[#target + 1] = entry
  end
end

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  return assert(narc:readMember(memberId))
end

---@param romFs RomFs
---@param resolved table<string, unknown>
---@param mapId integer
---@param terrainAnimationCompiler table<string, unknown>
---@param meshes table<string, table<string, unknown>>
---@param textures table<string, table<string, unknown>>
---@param unresolvedMaterials table[]
---@return table<string, unknown> neighbors
---@return table<string, unknown> textureSrt
---@return table<string, unknown> neighborChunkByMember
local function compileNeighborAssets(
  romFs,
  resolved,
  mapId,
  terrainAnimationCompiler,
  meshes,
  textures,
  unresolvedMaterials
)
  -- Plan the eight surrounding matrix cells and compile each unique land chunk
  -- once. Geometry/textures feed the draw ring; permission and BDHC artifacts
  -- make the same cells traversable in the field runtime.
  local plan = NeighborPlan.plan(resolved.matrix, resolved.matrixX, resolved.matrixZ, function(h)
    local rec = MapCatalog.areaForMapHeader(h)
    return rec and rec.areaDataMemberId or nil
  end)

  local neighborChunkByMember = {}
  for _, member in ipairs(plan.uniqueLandMembers) do
    local neighborCells, memberAreaId = {}, nil
    for _, cell in ipairs(plan.cells) do
      if cell.landDataMemberId == member then
        neighborCells[#neighborCells + 1] = { x = cell.x, z = cell.z }
        memberAreaId = memberAreaId or cell.areaDataMemberId
      end
    end
    local chunk = NeighborChunkCompiler.compile(romFs, member, memberAreaId, {
      mapId = mapId,
      mapSymbol = resolved.map.symbol,
      neighborCells = neighborCells,
      terrainAnimationCompiler = terrainAnimationCompiler,
    })
    for sha1, b in pairs(chunk.meshes) do
      meshes[sha1] = b
    end
    for sha1, t in pairs(chunk.textures) do
      textures[sha1] = t
    end
    appendUnresolved(unresolvedMaterials, chunk)
    neighborChunkByMember[member] = chunk
  end

  local neighbors = {}
  for _, cell in ipairs(plan.cells) do
    local chunk = neighborChunkByMember[cell.landDataMemberId]
    neighbors[#neighbors + 1] = {
      mapHeaderId = cell.mapHeaderId,
      landDataMemberId = cell.landDataMemberId,
      offsetTilesX = cell.offsetTilesX,
      offsetTilesY = cell.offsetTilesY,
      offsetTilesZ = cell.offsetTilesZ,
      batches = chunk.batches,
      materials = chunk.materials,
      collision = {
        width = 32,
        height = 32,
        file = MapAssetCache.neighborCollisionPath(mapId, cell.landDataMemberId),
      },
      terrain = {
        schema = chunk.terrain.schema,
        file = MapAssetCache.neighborTerrainPath(mapId, cell.landDataMemberId),
      },
    }
  end

  return neighbors, terrainAnimationCompiler:compileTextureSrt(), neighborChunkByMember
end

-- Retail map-prop base translations address their map cell's local tile grid
-- in model units: MapPropManager_LoadOne copies the handed VecFx32 with unit
-- scale and no second model posScale. Ordinary compiled geometry (map mesh,
-- placed buildings) renders in the centred scene frame, where the local grid
-- corner sits half a 32-tile matrix cell below the resolved world origin, so
-- each ball is tile-normalized once and shifted by that resolved corner to
-- join the room and its machine. The cell width is inlined (as in
-- NeighborPlan) so the producer stays free of the field-runtime dependency.
local CELL_TILES = 32

---@param sceneOrigin { x: number, y: number, z: number }
---@param position { x: number, y: number, z: number }
---@return number[]
local function mapPropBaseToScene(sceneOrigin, position)
  local x, y, z = MapUnits.toTiles(position.x, position.y, position.z)
  local origin = Matrix4.translateInto(Matrix4.newBuffer(), sceneOrigin.x, sceneOrigin.y, sceneOrigin.z)
  local positionMatrix = Matrix4.translateInto(Matrix4.newBuffer(), x, y, z)
  local composed = Matrix4.multiplyInto(Matrix4.newBuffer(), origin, positionMatrix)
  return Matrix4.toArrayBuffer(composed)
end

local function _compile(romFs, idOrSymbol, opts)
  opts = opts or {}
  local resolved = assert(MapResolver.resolve(romFs, idOrSymbol))
  local mapId = resolved.map.id
  local romSha1 = romFs:metadata().sha1

  -- Source members.
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrixBytes = readMember(matrixNarc, "map_matrices", resolved.matrixMemberId)

  local areaNarc = assert(romFs:openNarc("area_data"))
  local areaBytes = readMember(areaNarc, "area_data", resolved.areaDataMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = resolved.areaDataMemberId }))

  -- Terrain-animation compilation is map-scoped: one compiler parses the
  -- fldtanime table and serves every central and neighbor terrain compile,
  -- so all matched replacement members land in one dependency record, and
  -- the one area NSBTA clip is compiled from the central area's selection.
  local terrainAnimationCompiler = TerrainAnimationCompiler.new(romFs, {
    mapId = mapId,
    dynamicTextureType = area.dynamicTextureType,
  })

  local landNarc = assert(romFs:openNarc("land_data"))
  local landBytes = readMember(landNarc, "land_data", resolved.landDataMemberId)
  local land =
    assert(LandData.decode(landBytes, { mapId = mapId, alias = "land_data", memberId = resolved.landDataMemberId }))
  local decodedTerrain = assert(HgssBdhc.decode(land.bdhcBytes, {
    mapId = mapId,
    alias = "land_data",
    memberId = resolved.landDataMemberId,
    offset = land.offsets.bdhc,
    size = land.sizes.bdhc,
  }))
  local bdhcSha1 = Hashing.sha1hex(land.bdhcBytes)
  local terrain = {
    schema = "g4-terrain-surfaces-v1",
    sourceFormat = decodedTerrain.schema,
    source = {
      landDataMemberId = resolved.landDataMemberId,
      bdhcOffset = land.offsets.bdhc,
      bdhcSize = land.sizes.bdhc,
      bdhcSha1 = bdhcSha1,
    },
    counts = decodedTerrain.counts,
    points = decodedTerrain.points,
    slopes = decodedTerrain.slopes,
    heights = decodedTerrain.heights,
    plates = decodedTerrain.plates,
    strips = decodedTerrain.strips,
    accessEntries = decodedTerrain.accessEntries,
  }

  -- Map model + calibration.
  local mapNsbmd = assert(
    Nsbmd.decode(
      land.mapModelBytes,
      { alias = "land_data", memberId = resolved.landDataMemberId, section = "map-model" }
    )
  )
  local mapModel = mapNsbmd.models[1]
  local exTiles, ezTiles = MapUnits.assertMapCalibration(mapModel.bounds, mapModel.info.posScale, { map = mapId })

  -- Map texture pack.
  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local mapTexBytes = readMember(mapTexNarc, "map_textures", area.mapTexturePackId)
  local mapTexPack = assert(Nsbtx.decode(mapTexBytes, { alias = "map_textures", memberId = area.mapTexturePackId }))

  -- Field-light profile selected by the area's raw light type.
  local selectedLight = HgssFieldLighting.resolve(area.lightTypeRaw, false)
  local lightBytes =
    assert(romFs:readSourcePath(selectedLight.sourcePath), "missing field-light profile: " .. selectedLight.sourcePath)
  local lightProfile = assert(HgssFieldLightProfile.parse(lightBytes, { sourcePath = selectedLight.sourcePath }))
  local lightSha1 = Hashing.sha1hex(lightBytes)

  local meshes, textures = {}, {}
  local mapCompiled = ModelAssetCompiler.compileModel(mapModel, mapTexPack, meshes, textures, {
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    role = "map",
    areaDataMemberId = resolved.areaDataMemberId,
    landDataMemberId = resolved.landDataMemberId,
    textureArchive = "map_textures",
    textureMemberId = area.mapTexturePackId,
    modelArchive = "land_data",
    modelMemberId = resolved.landDataMemberId,
    modelName = mapModel.name,
    terrainAnimationCompiler = terrainAnimationCompiler,
    finalizeMeshes = true,
  })

  -- Materials whose names the pack they bind to does not define. They draw
  -- untextured, exactly as on the DS, so they are reported rather than fatal.
  local unresolvedMaterials = {}
  appendUnresolved(unresolvedMaterials, mapCompiled)

  local buildingCompiled = BuildingModelCompiler.compile(romFs, area, land, {
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    areaDataMemberId = resolved.areaDataMemberId,
    landDataMemberId = resolved.landDataMemberId,
    resourceCache = opts.resourceCache,
    meshes = meshes,
    textures = textures,
    finalizeMeshes = true,
    requiredModelMembers = resolved.map.symbol == StarterLab.mapSymbol and { StarterLab.modelMemberId } or nil,
  })
  appendUnresolved(unresolvedMaterials, { unresolved = buildingCompiled.unresolvedMaterials })
  local archiveAlias = buildingCompiled.archiveAlias
  local buildingInstances = buildingCompiled.buildingInstances
  local models = buildingCompiled.models

  local runtimeProps
  local starterSceneOrigin
  local starterModelKey = buildingCompiled.modelKeyOf[StarterLab.modelMemberId]
  if resolved.map.symbol == StarterLab.mapSymbol then
    assert(starterModelKey, "Elm's Lab starter-ball model was not compiled")
    local worldOriginX = assert(resolved.worldOriginX, "the lab scene origin resolves from the map compile")
    local worldOriginZ = assert(resolved.worldOriginZ, "the lab scene origin resolves from the map compile")
    local halfCell = CELL_TILES / 2
    starterSceneOrigin = { x = worldOriginX - halfCell, y = 0, z = worldOriginZ - halfCell }
    local placements = {}
    for _, position in ipairs(StarterLab.positions) do
      placements[#placements + 1] = { transform = mapPropBaseToScene(starterSceneOrigin, position) }
    end
    runtimeProps = {
      starter_balls = {
        model = starterModelKey,
        placements = placements,
      },
    }
  end

  local neighbors, textureSrt, neighborChunkByMember =
    compileNeighborAssets(romFs, resolved, mapId, terrainAnimationCompiler, meshes, textures, unresolvedMaterials)

  -- Dependency record -> hash -> marker.
  local dependencies = {
    cacheFormat = MapAssetCache.FORMAT,
    sceneSchemaVersion = MapAssetCache.SCENE_SCHEMA,
    coordinateConventionVersion = COORDINATE_CONVENTION,
    vertexFormatVersion = VertexFormat.VERSION,
    fieldLightSourcePath = selectedLight.sourcePath,
    fieldLightSourceSha1 = lightSha1,
    versionRomSha1 = romSha1,
    mapCatalogRecord = resolved.map,
    matrixMemberSha1 = Hashing.sha1hex(matrixBytes),
    areaDataMemberSha1 = Hashing.sha1hex(areaBytes),
    landDataMemberSha1 = Hashing.sha1hex(landBytes),
    terrainSchemaVersion = terrain.schema,
    bdhcSha1 = bdhcSha1,
    mapTextureMemberSha1 = Hashing.sha1hex(mapTexBytes),
    buildingArchive = archiveAlias,
    buildingTextureMemberId = buildingCompiled.buildingTextureMemberId,
    buildingTextureMemberSha1 = buildingCompiled.buildingTextureMemberSha1,
    uniqueBuildingModelMemberSha1s = buildingCompiled.buildingModelShas,
    -- Source-only facts about the compiled cell: matrix and area member
    -- identity, the matrix cell index/altitude, and the raw area record
    -- fields. None of these have a runtime consumer; they live on the
    -- producer dependency record, never in the runtime scene.
    matrix = {
      memberId = resolved.matrixMemberId,
      name = resolved.matrix.name,
      index = resolved.matrixIndex,
      altitude = resolved.matrixAltitude,
    },
    area = {
      memberId = resolved.areaDataMemberId,
      type = area.areaType,
      mapTexturePackId = area.mapTexturePackId,
      buildingTexturePackId = area.buildingTexturePackId,
      dynamicTextureType = area.dynamicTextureType,
      lightType = area.lightTypeRaw,
    },
    animationListMemberSha1s = buildingCompiled.animationListMemberSha1s,
  }
  if runtimeProps then
    dependencies.runtimeProps = {
      starter_balls = {
        modelMemberId = StarterLab.modelMemberId,
        positions = StarterLab.positions,
        sceneOrigin = assert(starterSceneOrigin, "the starter scene origin is stamped with its placements"),
      },
    }
  end
  -- The animation sources are producer provenance like every other
  -- dependency: the fldtanime table hash unconditionally, only the used
  -- replacement members, and the selected area NSBTA member -- merged before
  -- the marker hash so any animation source change invalidates the map.
  local terrainAnimDeps = terrainAnimationCompiler:dependencies()
  dependencies.fieldTextureAnimations = terrainAnimDeps.fieldTextureAnimations
  dependencies.terrainTextureSrt = terrainAnimDeps.terrainTextureSrt
  local marker = MapAssetCache.marker(romSha1, mapId, Hashing.hashLua(dependencies))

  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = romFs:version(),
    mapId = mapId,
    mapSymbol = resolved.map.symbol,
    type = area.areaType,
    matrix = {
      width = resolved.matrix.width,
      height = resolved.matrix.height,
      x = resolved.matrixX,
      z = resolved.matrixZ,
      worldOriginX = resolved.worldOriginX,
      worldOriginZ = resolved.worldOriginZ,
    },
    cameraType = resolved.map.cameraType,
    collision = {
      width = 32,
      height = 32,
      file = MapAssetCache.collisionPath(mapId),
    },
    terrain = {
      schema = terrain.schema,
      file = MapAssetCache.terrainPath(mapId),
    },
    mapBatches = mapCompiled.batches,
    materials = mapCompiled.materials,
    buildingInstances = buildingInstances,
    neighbors = neighbors,
    -- The central scene owns the one area texture-coordinate clip; the
    -- neighbor runtime receives it from the loader, never per-descriptor.
    terrainAnimations = { textureSrt = textureSrt },
    calibration = { modelExtentTilesX = exTiles, modelExtentTilesZ = ezTiles, posScale = mapModel.info.posScale },
    -- The runtime consumes only the normalized records for time-of-day
    -- selection; the source light type, profile id, source path, and source
    -- hash are producer provenance and live in the dependency record.
    lighting = {
      records = lightProfile.records,
    },
    -- The real HGSS edge-color table selected by the same per-area
    -- light-pattern byte HgssFieldLighting.resolve reads above (AreaData's
    -- lightTypeRaw at area-data offset 0x07 IS the byte AreaDataManager_Load
    -- reads at +0x8B7 to select between the two overlay tables). Field edge
    -- marking is unconditionally enabled, so every compiled scene carries
    -- this table.
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(area.lightTypeRaw),
    -- The map's base weather ID (MapCatalog record), carried alongside its
    -- resolved fog preset so a future runtime override policy (RTC/save/
    -- Defog/Flash) can start from the original ID rather than only the
    -- already-resolved preset.
    weatherId = resolved.map.weather,
    -- The resolved global HGSS weather fog preset for this map's real weather
    -- field, never a placeholder: every compiled scene carries it
    -- unconditionally, matching HGSS's own unconditional Fog_New()/
    -- WeatherManager_SetWeather call on field init. Derived from weatherId
    -- in this one place so the two fields cannot diverge.
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(resolved.map.weather)),
    runtimeProps = runtimeProps,
  }

  return {
    mapId = mapId,
    marker = marker,
    scene = scene,
    dependencies = dependencies,
    collision = land.collision,
    terrain = terrain,
    neighborChunks = neighborChunkByMember,
    meshes = meshes,
    textures = textures,
    models = models,
    unresolvedMaterials = unresolvedMaterials,
  }
end

function MapAssetCompiler.compile(romFs, idOrSymbol, opts)
  assert(romFs and romFs.openNarc, "compile requires a RomFs-shaped object")
  local ok, result = pcall(_compile, romFs, idOrSymbol, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return MapAssetCompiler
