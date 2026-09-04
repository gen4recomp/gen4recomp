-- Owns logical field-map entries and evicts them by least-recent use. Serialized
-- visual and event caches remain independent; outdoor physical cells are owned
-- by the field session, while indoor maps retain their aggregate runtime view.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldRegion = require("libs.hgss.src.world.FieldRegion")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local MapProps = require("libs.hgss.src.world.MapProps")
local ModelDoorMetadata = require("libs.hgss.src.world.ModelDoorMetadata")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")

---@class FieldMapLoader
---@field cacheFs CacheFs
---@field world table<string, unknown>
---@field capacity integer
---@field sceneLoader table<string, unknown>|nil presentation-only visual scene loader
---@field neighborLoader table<string, unknown>|nil presentation-only finite neighbor-ring loader
---@field sceneOptions table<string, unknown>|nil options passed to physical-cell presentation loading
---@field fieldCellIndex table<string, unknown>?
---@field entries table<integer, table<string, unknown>>
---@field protectedMaps table<integer, boolean>
---@field clock integer
---@field released boolean
local FieldMapLoader = {}
FieldMapLoader.__index = FieldMapLoader

---@class RuntimeFieldMap
---@field mapId integer
---@field mapSymbol string
---@field mapSection string
---@field mapSectionNativeId integer exact numeric MAPSEC_* identity; never the header id
---@field followMode string source map-header follow policy: ALLOW, HEIGHT_RESTRICT, or PREVENT
---@field sceneRuntime table<string, unknown>|nil presentation-only visual scene runtime
---@field mapProps MapProps? semantic door/prop resolver; present for logical (non-outdoor) maps, which load an eager central collision regardless of presentation
---@field scene table<string, unknown>
---@field fieldData table<string, unknown>
---@field collision table<string, unknown>?
---@field terrain TerrainSurface?
---@field terrainDependencyHash string?
---@field fieldRegion table<string, unknown>?
---@field cameraType integer
---@field coordinateOrigin { x: integer, z: integer }
---@field physicalOrigin { x: number, y: number, z: number }?
---@field neighborRuntime table<string, unknown>?
---@field coverage FieldCoverage? only on a session-owned composed field view
---@field probePhysicalCell fun(self: RuntimeFieldMap, fieldX: integer, fieldZ: integer, context: PhysicalProbeContext?): table<string, unknown>?|nil
---@field release fun(self: RuntimeFieldMap)
---@field updateAnimated fun(self: RuntimeFieldMap)
---@field syncPhysicalFields fun(self: RuntimeFieldMap)|nil

---@param world table<string, unknown>
---@param idOrSymbol string|integer
---@return table<string, unknown>?
local function findRecord(world, idOrSymbol)
  local mapId
  if type(idOrSymbol) == "string" then
    mapId = world.bySymbol[idOrSymbol]
    if mapId == nil then
      for _, candidate in ipairs(world.maps) do
        if candidate.mapCode == idOrSymbol then
          mapId = candidate.id
          break
        end
      end
    end
  else
    mapId = idOrSymbol
  end
  local index = mapId ~= nil and world.byId[mapId] or nil
  return index and world.maps[index] or nil
end

---@param world table<string, unknown>
---@param idOrSymbol string|integer
---@return table<string, unknown>
local function worldRecord(world, idOrSymbol)
  local record = findRecord(world, idOrSymbol)
  if not record then
    Errors.raise(FieldErrors.FIELD_MAP_UNKNOWN, "no runtime map for " .. tostring(idOrSymbol), { key = idOrSymbol })
  end
  return assert(record)
end

---@param cacheFs CacheFs
---@param path string
---@param code string
---@return table<string, unknown>
local function loadRequired(cacheFs, path, code)
  local value, err = cacheFs:loadLua(path)
  if value == nil then
    Errors.raise(code, "required field cache file is unavailable", {
      path = path,
      cause = err and Errors.format(err),
    })
  end
  return value --[[@as table]]
end

---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadFieldCellIndex(cacheFs)
  local path = FieldCellCache.indexPath()
  local index, err = cacheFs:loadLua(path)
  if index == nil then
    Errors.raise(FieldErrors.FIELD_CELL_CACHE_MISSING, "field cell index is unavailable; rebuild the derived cache", {
      path = path,
      cause = err and Errors.format(err),
    })
  end
  local loadedIndex = index --[[@as table]]
  if not FieldCellCache.validateIndex(loadedIndex) then
    Errors.raise(FieldErrors.FIELD_CELL_CACHE_INVALID, "field cell index is malformed; rebuild the derived cache", {
      path = path,
    })
  end
  return loadedIndex
end

local function releaseAggregate(runtimeMap)
  if runtimeMap.released then
    return
  end
  runtimeMap.released = true
  if runtimeMap.neighborRuntime then
    runtimeMap.neighborRuntime:release()
  end
  if runtimeMap.sceneRuntime then
    runtimeMap.sceneRuntime:release()
  end
end

-- The terrain artifact's source record is part of the map dependency identity
-- (see terrainDependencyHash); a missing source or bdhcSha1 is malformed
-- generated data and must fail the load rather than degrade the identity.
local function requireTerrainSource(artifact, context)
  if type(artifact.source) ~= "table" or type(artifact.source.bdhcSha1) ~= "string" then
    Errors.raise(FieldErrors.FIELD_MAP_TERRAIN_CACHE_INVALID, "terrain artifact source or bdhcSha1 is missing", context)
  end
end

-- Decode a collision asset into a runtime grid at a cell origin. Malformed
-- or missing generated collision data fails the load loudly -- a map with a
-- half-decoded grid must never move the player. `missingCode` names the
-- structured failure for the caller's artifact class.
local function loadCollision(cacheFs, descriptor, missingCode, context)
  local bytes = cacheFs:read(descriptor.file)
  if type(bytes) ~= "string" then
    Errors.raise(missingCode, "collision asset is unavailable", { path = descriptor.file, mapId = context.mapId })
  end
  ---@cast bytes string
  local grid, decodeErr = CollisionGridAsset.decode(bytes, { mapId = context.mapId, path = descriptor.file })
  if not grid then
    error(decodeErr)
  end
  return CollisionGrid.new(grid, {
    worldOriginX = context.worldOriginX or 0,
    worldOriginZ = context.worldOriginZ or 0,
  })
end

local function loadNeighborRegion(cacheFs, scene, centralCollision, centralTerrain)
  local neighbors = {}
  for _, descriptor in ipairs(scene.neighbors) do
    if not descriptor.collision or not descriptor.terrain then
      Errors.raise(
        FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING,
        "neighbor collision or terrain is missing; rebuild the derived cache",
        { mapId = scene.mapId, offsetTilesX = descriptor.offsetTilesX, offsetTilesZ = descriptor.offsetTilesZ }
      )
    end
    local terrainArtifact = loadRequired(cacheFs, descriptor.terrain.file, FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING)
    requireTerrainSource(terrainArtifact, {
      mapId = scene.mapId,
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
    })
    neighbors[#neighbors + 1] = {
      offsetTilesX = descriptor.offsetTilesX,
      offsetTilesY = descriptor.offsetTilesY,
      offsetTilesZ = descriptor.offsetTilesZ,
      collision = loadCollision(cacheFs, descriptor.collision, FieldErrors.FIELD_MAP_NEIGHBOR_CACHE_MISSING, {
        mapId = scene.mapId,
      }),
      terrain = TerrainSurface.new(terrainArtifact),
    }
  end
  return FieldRegion.new(centralCollision, centralTerrain, neighbors)
end

-- The DOOR-kind (behavior 105) tiles that actually own a warp: HGSS door
-- graphics sometimes span a tile with no warp of its own (an adjacent frame
-- tile purely visual, the functional warp sitting one tile over), and such a
-- tile has no gameplay reason to resolve a single owning placement -- doorAt
-- would never be reached there anyway, since it requires a warp before
-- consulting the index. Censusing only warp-bearing door tiles keeps the
-- ownership index meaningful (and avoids forcing a nearest-pivot decision
-- with no gameplay consumer) without weakening ambiguity/coverage
-- diagnostics for tiles that do matter.
---@param doorTiles { x: integer, z: integer }[]
---@param warps table[]
---@param originX integer
---@param originZ integer
---@return { x: integer, z: integer }[]
local function warpBearingDoorTiles(doorTiles, warps, originX, originZ)
  local warped = {}
  for _, warp in ipairs(warps) do
    warped[(warp.x - originX) .. ":" .. (warp.z - originZ)] = true
  end
  local out = {}
  for _, tile in ipairs(doorTiles) do
    if warped[tile.x .. ":" .. tile.z] then
      out[#out + 1] = tile
    end
  end
  return out
end

-- The scene's semantic door/prop resolver, built from generated data only:
-- placement transforms, and each placement's raw model descriptor (a pure
-- cache read -- no GPU) for its door sound type and role durations. Every
-- runtime map gets this, presentation or not; presentation later attaches
-- live ModelInstances into the SAME resolver instead of building a second
-- one (MapSceneLoader:attachInstances).
---@param cacheFs CacheFs
---@param scene table<string, unknown>
---@param fieldData table<string, unknown>
---@param centralCollision table<string, unknown>
---@return MapProps
local function buildMapProps(cacheFs, scene, fieldData, centralCollision)
  local doorTiles = warpBearingDoorTiles(
    DoorTiles.fromGrid(centralCollision),
    fieldData.events.warps,
    scene.matrix.worldOriginX,
    scene.matrix.worldOriginZ
  )
  local doorMetaByModelKey = {}
  local placements = {}
  for _, inst in ipairs(scene.buildingInstances) do
    local meta = doorMetaByModelKey[inst.modelKey]
    if meta == nil then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(inst.modelKey)), "missing model " .. inst.modelKey)
      meta = ModelDoorMetadata.forDescriptor(desc) or false
      doorMetaByModelKey[inst.modelKey] = meta
    end
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      doorSoundType = meta and meta.doorSoundType or nil,
      doorRoles = meta and meta.roles or nil,
    }
  end
  return MapProps.new({ placements = placements, instances = {}, doorTiles = doorTiles })
end

local function terrainDependencyHash(region)
  local identities = { "g4-composite-terrain-v1" }
  for _, cell in ipairs(region.cells) do
    identities[#identities + 1] = string.format(
      "%d:%.17g:%d:%s",
      cell.offsetTilesX,
      cell.offsetTilesY,
      cell.offsetTilesZ,
      cell.terrain.artifact.source.bdhcSha1
    )
  end
  return table.concat(identities, "|")
end

function FieldMapLoader.new(cacheFs, world, options)
  assert(cacheFs and cacheFs.loadLua, "FieldMapLoader requires a CacheFs-shaped object")
  assert(world and world.maps and world.byId and world.bySymbol, "world manifest required")
  options = options or {}
  local capacity = options.capacity or 4
  assert(capacity >= 1 and capacity == math.floor(capacity), "map capacity must be a positive integer")
  -- The visual scene loader and the finite neighbor ring are presentation
  -- collaborators: a simulation-only runtime leaves both out and still gets
  -- collision and terrain through the shared asset paths.
  return setmetatable({
    cacheFs = cacheFs,
    world = world,
    capacity = capacity,
    sceneLoader = options.sceneLoader,
    neighborLoader = options.neighborLoader,
    sceneOptions = options.sceneOptions,
    fieldCellIndex = nil,
    entries = {},
    protectedMaps = {},
    clock = 0,
    released = false,
  }, FieldMapLoader)
end

function FieldMapLoader:_touch(entry)
  self.clock = self.clock + 1
  entry.lastUsed = self.clock
end

function FieldMapLoader:_evict(skipMapId)
  while self:residentCount() > self.capacity do
    local victim
    for mapId, entry in pairs(self.entries) do
      if mapId ~= skipMapId and not self.protectedMaps[mapId] and (not victim or entry.lastUsed < victim.lastUsed) then
        victim = entry
      end
    end
    if not victim then
      return
    end
    self.entries[victim.runtimeMap.mapId] = nil
    releaseAggregate(victim.runtimeMap)
  end
end

function FieldMapLoader:load(idOrSymbol, _)
  assert(not self.released, "field map loader is released")
  local record = worldRecord(self.world, idOrSymbol)
  local existing = self.entries[record.id]
  if existing then
    self:_touch(existing)
    return existing.runtimeMap
  end

  -- The generated world manifest is the sole source of map compatibility
  -- metadata. A stale world without the exact native section identity and
  -- source follow mode fails here; the header id is never a substitute.
  local FOLLOW_MODES = { ALLOW = true, HEIGHT_RESTRICT = true, PREVENT = true }
  if
    type(record.mapSectionNativeId) ~= "number"
    or record.mapSectionNativeId % 1 ~= 0
    or record.mapSectionNativeId < 0
    or record.mapSectionNativeId > 65535
  then
    Errors.raise(
      FieldErrors.FIELD_MAP_WORLD_INVALID,
      "world manifest map section native identity is missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if FOLLOW_MODES[record.followMode] ~= true then
    Errors.raise(
      FieldErrors.FIELD_MAP_WORLD_INVALID,
      "world manifest follow mode is missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end

  local mapDir = MapAssetCache.mapDir(record.id)
  local scene = loadRequired(self.cacheFs, mapDir .. "/scene.lua", FieldErrors.FIELD_MAP_VISUAL_CACHE_MISSING)
  local fieldData =
    loadRequired(self.cacheFs, FieldMapDataCache.fieldPath(record.id), FieldErrors.FIELD_MAP_DATA_CACHE_MISSING)
  local terrainArtifact
  if scene.schema ~= MapAssetCache.SCENE_SCHEMA or scene.mapId ~= record.id then
    Errors.raise(
      FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
      "visual cache identity or schema mismatch",
      { mapId = record.id, schema = scene.schema }
    )
  end
  if type(scene.neighbors) ~= "table" then
    Errors.raise(
      FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
      "scene neighbors record is missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if fieldData.schema ~= FieldMapDataCache.FIELD_SCHEMA or fieldData.mapId ~= record.id then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache identity or schema mismatch",
      { mapId = record.id, schema = fieldData.schema }
    )
  end
  if not FieldMapDataCache.hasRequiredEvents(fieldData.events) then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache event collections are missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if not FieldMapDataCache.hasRequiredInitScripts(fieldData) then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache initScripts array is missing or malformed; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  if not FieldMapDataCache.isTransitionEnvironment(fieldData.transitionEnvironment) then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache transition environment is missing or malformed; rebuild the derived cache",
      { mapId = record.id, transitionEnvironment = fieldData.transitionEnvironment }
    )
  end
  if fieldData.cameraType ~= scene.cameraType then
    Errors.raise(
      FieldErrors.FIELD_MAP_CAMERA_MISMATCH,
      "visual and field camera types disagree",
      { mapId = record.id, visualCameraType = scene.cameraType, fieldCameraType = fieldData.cameraType }
    )
  end

  local physicalCells = scene.type == "outdoor"
  if physicalCells and not self.fieldCellIndex then
    self.fieldCellIndex = loadFieldCellIndex(self.cacheFs)
  end
  if not physicalCells then
    terrainArtifact =
      loadRequired(self.cacheFs, MapAssetCache.terrainPath(record.id), FieldErrors.FIELD_MAP_TERRAIN_CACHE_MISSING)
    if terrainArtifact.schema ~= MapAssetCache.TERRAIN_SCHEMA then
      Errors.raise(
        FieldErrors.FIELD_MAP_TERRAIN_CACHE_INVALID,
        "terrain cache schema mismatch",
        { mapId = record.id, schema = terrainArtifact.schema }
      )
    end
    requireTerrainSource(terrainArtifact, { mapId = record.id })
  end

  -- Outdoor cells own collision, terrain, and geometry through the physical
  -- coverage window; the logical scene contributes only environment state,
  -- so no central collision or mapProps exists until coverage is
  -- established. Every other (indoor) map decodes its central collision
  -- through the same pure project-owned asset path whether or not
  -- presentation is enabled, so simulation and rendering can never disagree
  -- about blocking, and mapProps (the semantic door/prop resolver) is built
  -- from it and the scene's building placements the same way regardless of
  -- presentation -- one authority, built once, never reconstructed per
  -- presentation state.
  local centralCollision
  local mapProps
  if not physicalCells then
    if not scene.collision or type(scene.collision.file) ~= "string" then
      Errors.raise(
        FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
        "scene collision descriptor is missing; rebuild the derived cache",
        { mapId = record.id }
      )
    end
    if type(scene.buildingInstances) ~= "table" then
      Errors.raise(
        FieldErrors.FIELD_MAP_VISUAL_CACHE_INVALID,
        "scene buildingInstances is missing or malformed; rebuild the derived cache",
        { mapId = record.id }
      )
    end
    centralCollision = loadCollision(self.cacheFs, scene.collision, FieldErrors.FIELD_MAP_COLLISION_CACHE_MISSING, {
      mapId = record.id,
      worldOriginX = scene.matrix.worldOriginX,
      worldOriginZ = scene.matrix.worldOriginZ,
    })
    mapProps = buildMapProps(self.cacheFs, scene, fieldData, centralCollision)
  end

  -- The visual scene runtime is optional: only a presentation composition
  -- supplies a scene loader. For indoor maps it attaches its live
  -- ModelInstances into the SAME mapProps rather than building a second door
  -- census; an outdoor map's presentation instead loads the environment
  -- shell and defers physical geometry to the coverage window.
  local sceneRuntime
  if self.sceneLoader then
    sceneRuntime = physicalCells and self.sceneLoader.loadEnvironment(scene)
      or self.sceneLoader.load(self.cacheFs, scene, { mapProps = mapProps })
  end
  -- One transaction covers every step after the scene runtime is acquired:
  -- neighbor-ring load, terrain construction, neighbor decoding, region
  -- assembly, and aggregate construction. Any failure releases the neighbor
  -- runtime (if created) and the scene runtime exactly once before the error
  -- propagates; a failure inside the scene loader itself is that loader's own
  -- transaction.
  local neighborRuntime
  local runtimeMap
  local ok, loadErr = pcall(function()
    if not physicalCells and self.neighborLoader and #scene.neighbors > 0 then
      neighborRuntime = self.neighborLoader.load(self.cacheFs, scene.neighbors, {
        textureSrt = scene.terrainAnimations.textureSrt,
      })
    end

    local region
    if not physicalCells then
      local centralTerrain = TerrainSurface.new(assert(terrainArtifact))
      region = loadNeighborRegion(self.cacheFs, scene, centralCollision, centralTerrain)
    end
    runtimeMap = {
      mapId = record.id,
      mapSymbol = record.symbol,
      mapSection = record.mapSection,
      mapSectionNativeId = record.mapSectionNativeId,
      followMode = record.followMode,
      sceneRuntime = sceneRuntime,
      mapProps = mapProps,
      scene = scene,
      fieldData = fieldData,
      collision = region and region.collision or nil,
      terrain = region and region.terrain or nil,
      terrainDependencyHash = region and terrainDependencyHash(region) or nil,
      fieldRegion = region,
      cameraType = scene.cameraType,
      coordinateOrigin = { x = scene.matrix.worldOriginX, z = scene.matrix.worldOriginZ },
      physicalOrigin = nil,
      neighborRuntime = neighborRuntime,
      released = false,
    }
    function runtimeMap:probePhysicalCell(_, _)
      return nil
    end
    function runtimeMap:release()
      releaseAggregate(self)
    end
    -- The one fixed-tick entry FieldSession steps: fans out to the central
    -- scene runtime and the neighbor ring runtime (each guarded so a
    -- simulation-only aggregate stays a safe no-op), and the semantic door
    -- index when this is a logical (non-outdoor) map, which advances
    -- regardless of presentation. An outdoor map's physical window is
    -- stepped separately once coverage composes over this logical entry.
    function runtimeMap:updateAnimated()
      if self.sceneRuntime and self.sceneRuntime.updateAnimated then
        self.sceneRuntime:updateAnimated()
      end
      if self.neighborRuntime then
        self.neighborRuntime:updateAnimated()
      end
      if self.mapProps then
        self.mapProps:updateFixed()
      end
    end

    local entry = { runtimeMap = runtimeMap }
    self.entries[record.id] = entry
    self:_touch(entry)
  end)
  if not ok then
    if neighborRuntime then
      neighborRuntime:release()
    end
    if sceneRuntime then
      sceneRuntime:release()
    end
    error(loadErr)
  end

  self:_evict(record.id)
  return runtimeMap
end

-- Construct the session-owned physical window for an outdoor logical map.
-- The loader provides validated cache access and presentation construction,
-- but never stores or releases the returned owner.
---@param runtimeMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@return FieldCoverage
function FieldMapLoader:createPhysicalCoverage(runtimeMap, position)
  assert(not self.released, "field map loader is released")
  assert(runtimeMap and runtimeMap.scene and runtimeMap.scene.type == "outdoor", "outdoor logical map required")
  local fieldCellIndex = assert(self.fieldCellIndex, "field cell cache is unavailable")
  assert(type(position) == "table", "physical coverage position required")
  local record = worldRecord(self.world, runtimeMap.mapId)
  local matrix = assert(record.matrix, "outdoor map matrix metadata is required")
  local matrixMemberId = assert(matrix.memberId, "outdoor matrix member is required")
  local presentationLoader
  local presentationTaskFactory
  if self.sceneLoader and self.sceneLoader.beginCell then
    local function beginCell(_, cell)
      return self.sceneLoader.beginCell(self.cacheFs, cell, self.sceneOptions)
    end
    presentationTaskFactory = beginCell
  elseif self.sceneLoader and self.sceneLoader.loadCell then
    local function loadCell(_, cell)
      return self.sceneLoader.loadCell(self.cacheFs, cell, self.sceneOptions)
    end
    presentationLoader = loadCell
  end
  return FieldCoverage.new({
    cacheFs = self.cacheFs,
    index = fieldCellIndex,
    matrixMemberId = matrixMemberId,
    anchorX = math.floor(position.fieldX / 32),
    anchorZ = math.floor(position.fieldZ / 32),
    presentationLoader = presentationLoader,
    presentationTaskFactory = presentationTaskFactory,
  })
end

-- Read only the generated semantic metadata needed to choose a transition.
-- This deliberately does not load a scene, collision grid, terrain, or GPU
-- resource, so profile selection cannot acquire destination ownership.
function FieldMapLoader:transitionEnvironment(idOrSymbol)
  assert(not self.released, "field map loader is released")
  local record = worldRecord(self.world, idOrSymbol)
  local fieldData =
    loadRequired(self.cacheFs, FieldMapDataCache.fieldPath(record.id), FieldErrors.FIELD_MAP_DATA_CACHE_MISSING)
  if
    fieldData.schema ~= FieldMapDataCache.FIELD_SCHEMA
    or fieldData.mapId ~= record.id
    or not FieldMapDataCache.hasRequiredEvents(fieldData.events)
    or not FieldMapDataCache.isTransitionEnvironment(fieldData.transitionEnvironment)
  then
    Errors.raise(
      FieldErrors.FIELD_MAP_DATA_CACHE_INVALID,
      "field cache identity, event collections, or transition environment is invalid; rebuild the derived cache",
      { mapId = record.id }
    )
  end
  return fieldData.transitionEnvironment
end

function FieldMapLoader:get(mapId)
  local entry = self.entries[mapId]
  return entry and entry.runtimeMap or nil
end

-- Whether the generated world manifest defines a loadable logical map for
-- the id or symbol. Matrix filler headers own physical cells but no logical
-- map assets (the producer deliberately excludes them from rendering), so
-- logical-map consumers use this to avoid acquiring a shell that cannot
-- exist instead of failing the load.
---@param idOrSymbol string|integer
---@return boolean
function FieldMapLoader:definesMap(idOrSymbol)
  assert(not self.released, "field map loader is released")
  return findRecord(self.world, idOrSymbol) ~= nil
end

-- Counts currently resident map entries without acquiring or releasing them.
function FieldMapLoader:residentCount()
  local count = 0
  for _ in pairs(self.entries) do
    count = count + 1
  end
  return count
end

function FieldMapLoader:protectMap(mapId, protected)
  assert(type(mapId) == "number", "mapId required")
  self.protectedMaps[mapId] = protected and true or nil
  if not protected then
    self:_evict()
  end
end

function FieldMapLoader:release()
  if self.released then
    return
  end
  self.released = true
  for _, entry in pairs(self.entries) do
    releaseAggregate(entry.runtimeMap)
  end
  self.entries, self.protectedMaps = {}, {}
end

return FieldMapLoader
