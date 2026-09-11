-- Readiness for the derived map-asset cache. This cache has its own format
-- version, fully independent of the raw ROM dump: changing it may rebuild
-- derived maps but must never disturb the raw-dump completion marker,
-- romfs/, or the raw dump indexes. A map is ready only when its completion
-- marker matches exactly and every artifact it references is present and
-- loadable, so a partial or stale build never reads as complete. Paths are
-- cache-relative; all IO goes through a CacheFs (which confines every write
-- to the version subtree).

local MapAssetCache = {}

---@class MapAssetCache.Scene
---@field schema string
---@field kind string
---@field materials table[]
---@field mapBatches table[]
---@field buildingInstances table[]
---@field neighbors table[]
---@field terrainAnimations table<string, unknown>
---@field [string] table<string, unknown>|string|number|boolean|nil

---@class MapAssetCache.Neighbor
---@field offsetTilesX integer
---@field offsetTilesY number
---@field offsetTilesZ integer
---@field batches table[]
---@field materials table[]
---@field [string] table<string, unknown>|string|number|boolean|nil

local Errors = require("libs.errors.src.Errors")
local AssetErrors = require("libs.assets.src.errors")
local Validate = require("libs.assets.src.Validate")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local CompiledNsbtaClip = require("libs.assets.src.model.CompiledNsbtaClip")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

MapAssetCache.FORMAT = Contract.map.cacheFormat
MapAssetCache.SCENE_SCHEMA = Contract.map.sceneSchema
MapAssetCache.TERRAIN_SCHEMA = Contract.map.terrainSchema

local DERIVED_DATA = "data/generated"
local DERIVED_ASSETS = "assets/generated"

function MapAssetCache.mapDir(mapId)
  return string.format("%s/maps/%04d", DERIVED_DATA, mapId)
end

function MapAssetCache.terrainPath(mapId)
  return MapAssetCache.mapDir(mapId) .. "/terrain.lua"
end

function MapAssetCache.collisionPath(mapId)
  return MapAssetCache.mapDir(mapId) .. "/collision.g4collision"
end

function MapAssetCache.neighborCollisionPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/collision.g4collision", MapAssetCache.mapDir(mapId), landDataMemberId)
end

function MapAssetCache.neighborTerrainPath(mapId, landDataMemberId)
  return string.format("%s/neighbors/%d/terrain.lua", MapAssetCache.mapDir(mapId), landDataMemberId)
end

-- Cache-relative path to the whole-ROM world manifest (map index the game boots
-- and switches on). Lives next to the per-map dirs, under the derived root.
function MapAssetCache.worldPath()
  return DERIVED_DATA .. "/world.lua"
end

function MapAssetCache.geometryPath(sha1)
  return string.format("%s/maps/geometry/%s.g4mesh", DERIVED_ASSETS, sha1)
end

function MapAssetCache.texturePath(sha1)
  return string.format("%s/maps/textures/%s.png", DERIVED_ASSETS, sha1)
end

function MapAssetCache.modelPath(modelKey)
  -- Model keys embed ':' (archive:member:hash); keep them filesystem-safe.
  return string.format("%s/models/%s.lua", DERIVED_DATA, (modelKey:gsub(":", "_")))
end

function MapAssetCache.marker(romSha1, mapId, depHash)
  return string.format("%s:%s:%d:%s", MapAssetCache.FORMAT, romSha1, mapId, depHash)
end

-- ---- terrain-animation subset validation ----
--
-- The current scene schema carries the strict generated terrain-animation
-- subset: the required terrainAnimations block (an explicit false clip or
-- the data-only texture-SRT clip shape the producer's NsbtaClipCompiler
-- emits), and the terrain material fields (texWidth/texHeight/texMtxMode,
-- the optional fixed-point srt, and the optional textureSwap record). The
-- compiled clip contract is the shared validator's; the checks here cover
-- only the scene material fields. Every check raises through the caller's
-- `invalid(reason)` so a malformed current-schema scene reports
-- MAP_CACHE_SCENE_INVALID.

local TERRAIN_SRT_FIELDS = { "transS", "transT", "scaleS", "scaleT" }
local TERRAIN_SRT_ONES = { "scaleOne", "transOne", "rotOne" }

-- A finite integer (rejects fractional, NaN, and infinite values).
---@param value unknown
---@return boolean
local function isFiniteInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Optional owner-keyed runtime static-prop groups. Owner keys are opaque to
-- this source-independent cache layer: every group names the model descriptor
-- its placements instance, and validation is structural only (non-empty owner
-- and model keys, an array of placements, one 16-component finite transform
-- each). Owner identity rides every diagnostic.
---@param scene MapAssetCache.Scene
---@param invalid fun(reason: string)
local function checkRuntimeProps(scene, invalid)
  local runtimeProps = scene.runtimeProps
  if runtimeProps == nil then
    return
  end
  if type(runtimeProps) ~= "table" then
    invalid("runtimeProps must be a table keyed by owner")
  end
  local groups = runtimeProps --[[@as table]]
  for ownerKey, group in pairs(groups) do
    local where = "runtimeProps[" .. tostring(ownerKey) .. "]"
    if type(ownerKey) ~= "string" or #ownerKey == 0 then
      invalid("a runtime prop owner key must be a non-empty string")
    end
    if type(group) ~= "table" then
      invalid(where .. " must be a record")
    end
    if type(group.model) ~= "string" or #group.model == 0 then
      invalid(where .. ".model must be a non-empty model key")
    end
    if not Validate.isArray(group.placements) then
      invalid(where .. ".placements must be an array")
    end
    for index, placement in ipairs(group.placements) do
      if type(placement) ~= "table" or not Validate.isArray(placement.transform) or #placement.transform ~= 16 then
        invalid(where .. " placement " .. index .. " must carry a sixteen-component transform")
      end
      for component = 1, 16 do
        if not isFiniteNumber(placement.transform[component]) then
          invalid(where .. " placement " .. index .. " has a non-finite transform component")
        end
      end
    end
  end
end

-- The optional fixed-point srt table (the MaterialEvaluator shape): the four
-- translation/scale fixed-point values, an optional { sin, cos } rotation
-- (omitted for identity rotation), and the three "one" flags.
---@param srt table<string, unknown>
---@param invalid fun(reason: string)
local function checkTerrainSrt(srt, invalid)
  for _, field in ipairs(TERRAIN_SRT_FIELDS) do
    local value = srt[field] ---@type number?
    if not isFiniteInteger(value) then
      invalid("a material srt." .. field .. " must be a fixed-point integer")
    end
  end
  local rot = srt.rot ---@type { sin: number?, cos: number? }?
  if rot ~= nil and (type(rot) ~= "table" or not isFiniteInteger(rot.sin) or not isFiniteInteger(rot.cos)) then
    invalid("a material srt.rot must be { sin, cos } fixed-point integers")
  end
  for _, field in ipairs(TERRAIN_SRT_ONES) do
    local value = srt[field] ---@type boolean?
    if type(value) ~= "boolean" then
      invalid("a material srt." .. field .. " must be a boolean")
    end
  end
end

-- The textureSwap record of one terrain material: the playback-group name
-- and the direct playback steps, each naming the replacement image for its
-- schedule entry and the entry's duration in ticks (zero durations are
-- valid: the source state machine can process them). The material's base
-- texture stays outside the schedule in material.texture, so no step is
-- compared against it.
---@param m table<string, unknown>
---@param invalid fun(reason: string)
local function checkTextureSwap(m, invalid)
  local swap = m.textureSwap ---@type table
  if type(swap) ~= "table" or type(swap.name) ~= "string" or #swap.name == 0 then
    invalid("a material textureSwap requires a non-empty name")
  end
  local steps = swap.steps ---@type table[]
  if not Validate.isArray(steps) or #steps == 0 then
    invalid("a material textureSwap requires a non-empty steps array")
  end
  for i, step in ipairs(steps) do
    local where = "a material textureSwap step " .. i .. " "
    if type(step) ~= "table" or type(step.texture) ~= "string" or #step.texture == 0 then
      invalid(where .. "must carry a non-empty texture path")
    end
    if not (isFiniteInteger(step.durationTicks) and step.durationTicks >= 0) then
      invalid(where .. "durationTicks must be a non-negative integer")
    end
  end
end

-- The terrain material fields: every material record carries the
-- texture-matrix inputs because the terrain animator is constructed
-- unconditionally -- textured materials have positive authored dimensions,
-- untextured materials zero or more (the producer emits zero), and only
-- texture-matrix mode 0 has a compiled convention. A textureSwap requires
-- the bound base texture the map starts from.
---@param m table<string, unknown>
---@param invalid fun(reason: string)
local function checkTerrainMaterial(m, invalid)
  local textured = type(m.texture) == "string"
  for _, field in ipairs({ "texWidth", "texHeight" }) do
    local value = m[field] ---@type number?
    if not isFiniteInteger(value) or (textured and value < 1) or (not textured and value < 0) then
      invalid("a material " .. field .. " must be a " .. (textured and "positive" or "non-negative") .. " integer")
    end
  end
  if m.texMtxMode ~= 0 then
    invalid("a material texMtxMode must be 0 (only the Maya texture-matrix convention is supported)")
  end
  local srt = m.srt ---@type table?
  if srt ~= nil then
    if type(srt) ~= "table" then
      invalid("a material srt must be a table")
    end
    checkTerrainSrt(srt, invalid)
  end
  local textureSwap = m.textureSwap ---@type table?
  if textureSwap ~= nil then
    if not textured then
      invalid("a textureSwap requires a base material texture")
    end
    checkTextureSwap(m, invalid)
  end
end

-- Every material record of one list needs a valid id and a unique one: the
-- runtime indexes materials by record.id, so a missing, negative, fractional,
-- or duplicate id is malformed generated data. Ids are local to each list
-- (central or per-neighbor).
---@param materials table[]
---@param invalid fun(reason: string)
local function checkMaterialIds(materials, invalid)
  local seen = {} ---@type table<number, boolean>
  for _, material in ipairs(materials) do
    if type(material) ~= "table" then
      invalid("a material is not a record")
    end
    if not Validate.isNonNegativeInteger(material.id) then
      invalid("a material id must be a non-negative integer")
    end
    if seen[material.id] then
      invalid("two material records share the id " .. tostring(material.id) .. " in one list")
    end
    seen[material.id] = true
  end
end

-- Collect every cache-relative path the scene references, recursing into model
-- descriptors (validated through ModelAsset) so a stale or missing model
-- geometry/texture is caught. The scene shape is validated strictly: the
-- current compiler always writes these fields, so malformed structure raises
-- MAP_CACHE_SCENE_INVALID instead of being defaulted to empty collections.
---@param scene MapAssetCache.Scene
---@param cacheFs CacheFs?
---@return string[]
function MapAssetCache.referencedPaths(scene, cacheFs)
  local paths = {} ---@type string[]

  local function invalid(reason)
    Errors.raise(AssetErrors.MAP_CACHE_SCENE_INVALID, "scene descriptor is malformed: " .. reason, { reason = reason })
  end

  if type(scene.terrainAnimations) ~= "table" then
    invalid("terrainAnimations is missing or not a table")
  end
  local terrainAnimations = scene.terrainAnimations ---@type table
  local textureSrt = terrainAnimations.textureSrt ---@type table|false
  if textureSrt ~= false then
    if type(textureSrt) ~= "table" then
      invalid("terrainAnimations.textureSrt must be false or a table")
    end
    local textureSrtTable = textureSrt
    ---@cast textureSrtTable table<string, unknown>
    CompiledNsbtaClip.validate(textureSrtTable, function(reason)
      invalid("terrainAnimations.textureSrt " .. reason)
    end)
  end

  if not Validate.isArray(scene.mapBatches) then
    invalid("mapBatches is not an array")
  end
  if not Validate.isArray(scene.materials) then
    invalid("materials is not an array")
  end
  if not Validate.isArray(scene.buildingInstances) then
    invalid("buildingInstances is not an array")
  end
  if not Validate.isArray(scene.neighbors) then
    invalid("neighbors is not an array")
  end

  local mapBatches = scene.mapBatches ---@type table[]
  local materials = scene.materials ---@type table[]
  local neighbors = scene.neighbors ---@type MapAssetCache.Neighbor[]
  local buildingInstances = scene.buildingInstances ---@type table[]
  ---@cast mapBatches table[]
  ---@cast materials table[]
  ---@cast neighbors table[]
  ---@cast buildingInstances table[]
  checkRuntimeProps(scene, invalid)

  local terrain = scene.terrain
  if terrain and type(terrain) == "table" and terrain.file then
    paths[#paths + 1] = terrain.file
  end

  -- The runtime groups texture swaps by name, so every occurrence of one
  -- name must share its step count and per-step durations across the central
  -- scene and every neighbor cell; the texture paths may differ because
  -- neighboring cells compile the same animation against their own packs.
  local swapSchedules = {} ---@type table<string, { count: integer, durations: number[] }>
  ---@param m table<string, unknown>
  local function checkSwapSchedule(m)
    local swap = m.textureSwap ---@type table
    if swap == nil then
      return
    end
    local expected = swapSchedules[swap.name]
    if expected == nil then
      local durations = {} ---@type number[]
      local steps = swap.steps ---@type table[]
      for _, step in ipairs(steps) do
        local durationTicks = step.durationTicks ---@type number
        durations[#durations + 1] = durationTicks
      end
      swapSchedules[swap.name] = { count = #steps, durations = durations }
      return
    end
    local steps = swap.steps ---@type table[]
    if #steps ~= expected.count then
      invalid("textureSwap " .. swap.name .. " carries a different step count than another material of the same name")
    end
    for i, step in ipairs(steps) do
      local durationTicks = step.durationTicks ---@type number
      if durationTicks ~= expected.durations[i] then
        invalid(
          "textureSwap " .. swap.name .. " carries different step durations than another material of the same name"
        )
      end
    end
  end

  local function addBatch(b)
    if type(b) ~= "table" or type(b.geometry) ~= "string" then
      invalid("a batch does not reference a geometry path")
    end
    local geometry = b.geometry ---@type string
    paths[#paths + 1] = geometry
  end
  local function addMaterial(m)
    if type(m) ~= "table" or (m.texture ~= nil and type(m.texture) ~= "string") then
      invalid("a material is not a record with an optional texture path")
    end
    checkTerrainMaterial(m, invalid)
    checkSwapSchedule(m)
    local texture = m.texture ---@type string?
    if texture then
      paths[#paths + 1] = texture
    end
    local textureSwap = m.textureSwap ---@type table?
    if textureSwap then
      local steps = textureSwap.steps ---@type table[]
      for _, step in ipairs(steps) do
        local texturePath = step.texture ---@type string
        paths[#paths + 1] = texturePath
      end
    end
  end

  for _, b in ipairs(mapBatches) do
    addBatch(b)
  end
  checkMaterialIds(materials, invalid)
  for _, m in ipairs(materials) do
    addMaterial(m)
  end
  for _, cell in ipairs(neighbors) do
    if type(cell) ~= "table" then
      invalid("a neighbor cell is not a record")
    end
    if not isFiniteInteger(cell.offsetTilesX) then
      invalid("a neighbor offsetTilesX must be a finite integer")
    end
    if not isFiniteNumber(cell.offsetTilesY) then
      invalid("a neighbor offsetTilesY must be a finite number")
    end
    if not isFiniteInteger(cell.offsetTilesZ) then
      invalid("a neighbor offsetTilesZ must be a finite integer")
    end
    if not Validate.isArray(cell.batches) or not Validate.isArray(cell.materials) then
      invalid("a neighbor cell does not carry batches and materials arrays")
    end
    local cellBatches = cell.batches ---@type table[]
    local cellMaterials = cell.materials ---@type table[]
    for _, b in ipairs(cellBatches) do
      addBatch(b)
    end
    checkMaterialIds(cellMaterials, invalid)
    for _, m in ipairs(cellMaterials) do
      addMaterial(m)
    end
    local collision = cell.collision ---@type table?
    if type(collision) == "table" and collision.file then
      paths[#paths + 1] = collision.file
    end
    local neighborTerrain = cell.terrain ---@type table?
    if type(neighborTerrain) == "table" and neighborTerrain.file then
      paths[#paths + 1] = neighborTerrain.file
    end
  end
  for _, inst in ipairs(buildingInstances) do
    if type(inst) ~= "table" or type(inst.modelKey) ~= "string" then
      invalid("a building instance does not carry a modelKey")
    end
    local modelPath = MapAssetCache.modelPath(inst.modelKey)
    paths[#paths + 1] = modelPath
    local desc = cacheFs and cacheFs:loadLua(modelPath)
    if type(desc) ~= "table" then
      invalid("model descriptor does not load: " .. inst.modelKey)
    end
    local ok, referenced = pcall(ModelAsset.referencedPaths, desc)
    if not ok then
      local errorValue = referenced ---@cast errorValue Errors.Error
      if Errors.is(errorValue) and errorValue.code == ModelAsset.ERROR_INVALID then
        invalid("model descriptor is malformed: " .. inst.modelKey)
      end
      error(errorValue)
    end
    local referencedPaths = referenced ---@type string[]
    for _, path in ipairs(referencedPaths) do
      paths[#paths + 1] = path
    end
  end
  local runtimeProps = scene.runtimeProps
  if type(runtimeProps) == "table" then
    local ownerKeys = {}
    for ownerKey in pairs(runtimeProps) do
      ownerKeys[#ownerKeys + 1] = ownerKey
    end
    table.sort(ownerKeys)
    for _, ownerKey in ipairs(ownerKeys) do
      local group = runtimeProps[ownerKey] --[[@as table]]
      local context = "runtime prop owner " .. tostring(ownerKey)
      local modelPath = MapAssetCache.modelPath(group.model)
      paths[#paths + 1] = modelPath
      -- Without a filesystem the descriptor's files cannot be traversed; the
      -- recorded descriptor path is the full closure available.
      if cacheFs ~= nil then
        local desc = cacheFs:loadLua(modelPath)
        if type(desc) ~= "table" then
          invalid(context .. " model descriptor does not load: " .. group.model)
        end
        local ok, referenced = pcall(ModelAsset.referencedPaths, desc)
        if not ok then
          local errorValue = referenced ---@cast errorValue Errors.Error
          if Errors.is(errorValue) and errorValue.code == ModelAsset.ERROR_INVALID then
            invalid(context .. " model descriptor is malformed: " .. group.model)
          end
          error(errorValue)
        end
        local referencedPaths = referenced ---@type string[]
        for _, path in ipairs(referencedPaths) do
          paths[#paths + 1] = path
        end
      end
    end
  end
  return paths
end

-- A collision asset is ready only when it exists and fully decodes as the
-- current project format: malformed magic/version/dimensions/blocked bytes
-- must never read as a valid grid.
---@param cacheFs CacheFs?
---@param path string
---@return boolean
local function validCollision(cacheFs, path)
  cacheFs = assert(cacheFs)
  local bytes = cacheFs:read(path)
  if type(bytes) ~= "string" then
    return false
  end
  local grid = CollisionGridAsset.decode(bytes, { path = path })
  return grid ~= nil
end

-- True only if the marker is exact, the scene carries the current identity
-- (schema and mapId), scene/dependencies/terrain load, the collision asset
-- decodes (magic/version/dimensions/blocked bytes are all validated), every
-- model descriptor opens, and every referenced asset exists. A malformed
-- scene shape reports not ready rather than raising.
---@param cacheFs CacheFs?
---@param mapId integer
---@param expectedMarker string
---@return boolean
function MapAssetCache.isReady(cacheFs, mapId, expectedMarker)
  cacheFs = assert(cacheFs)
  local dir = MapAssetCache.mapDir(mapId)
  local marker = cacheFs:read(dir .. "/complete")
  if marker ~= expectedMarker then
    return false
  end

  local scene = cacheFs:loadLua(dir .. "/scene.lua")
  if type(scene) ~= "table" then
    return false
  end
  if scene.schema ~= MapAssetCache.SCENE_SCHEMA or scene.mapId ~= mapId then
    return false
  end
  ---@cast scene MapAssetCache.Scene
  if not cacheFs:loadLua(dir .. "/dependencies.lua") then
    return false
  end
  if scene.type == "outdoor" then
    if
      type(scene.collision) ~= "table"
      or type(scene.collision.file) ~= "string"
      or type(scene.terrain) ~= "table"
      or type(scene.terrain.file) ~= "string"
    then
      return false
    end
    if not validCollision(cacheFs, scene.collision.file) then
      return false
    end
    local terrain = cacheFs:loadLua(scene.terrain.file)
    if type(terrain) ~= "table" or terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      return false
    end
  else
    local terrain = cacheFs:loadLua(MapAssetCache.terrainPath(mapId))
    if type(terrain) ~= "table" or terrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      return false
    end
    if not validCollision(cacheFs, MapAssetCache.collisionPath(mapId)) then
      return false
    end
  end

  local ok, paths = pcall(MapAssetCache.referencedPaths, scene, cacheFs)
  if not ok then
    local errorValue = paths ---@cast errorValue Errors.Error
    if Errors.is(errorValue) and errorValue.code == AssetErrors.MAP_CACHE_SCENE_INVALID then
      return false
    end
    error(errorValue)
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  for _, cell in ipairs(scene.neighbors) do
    if type(cell.collision) == "table" and cell.collision.file then
      if not validCollision(cacheFs, cell.collision.file) then
        return false
      end
    end
    if type(cell.terrain) == "table" and cell.terrain.file then
      local neighborTerrain = cacheFs:loadLua(cell.terrain.file)
      if type(neighborTerrain) ~= "table" or neighborTerrain.schema ~= MapAssetCache.TERRAIN_SCHEMA then
        return false
      end
    end
  end
  return true
end

---@param cacheFs CacheFs?
---@param mapId integer
---@return table<string, unknown>
function MapAssetCache.dependencies(cacheFs, mapId)
  cacheFs = assert(cacheFs)
  local dependencies = cacheFs:loadLua(MapAssetCache.mapDir(mapId) .. "/dependencies.lua")
  assert(type(dependencies) == "table", "map dependencies must be a table")
  return dependencies
end

return MapAssetCache
