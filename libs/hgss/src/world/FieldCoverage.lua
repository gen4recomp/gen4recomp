-- Owns the bounded resident physical-cell window used by outdoor maps. A
-- recenter stages all missing cells and the composite region before replacing
-- the active window, so acquisition failures cannot damage the current world.

local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local FieldRegion = require("libs.hgss.src.world.FieldRegion")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class PhysicalProbeContext
---@field currentCellKey string
---@field currentSourceSurfaceId integer
---@field currentY number
---@field fromFieldX integer
---@field fromFieldZ integer
---@class FieldCoverage
---@field cacheFs CacheFs?
---@field index table<string, unknown>
---@field matrixMemberId integer
---@field loadCell fun(descriptor: table<string, unknown>): table<string, unknown>
---@field presentationLoader fun(runtime: table<string, unknown>, descriptor: table<string, unknown>): table<string, unknown>?
---@field presentationTaskFactory fun(runtime: table<string, unknown>, descriptor: table<string, unknown>): table<string, unknown>?
---@field derivedAssets table<string, function>?
---@field cells table<string, table<string, unknown>>
---@field prefetched table<string, table<string, unknown>>
---@field prefetchQueue table[]
---@field prefetchError unknown?
---@field synchronousPhysicalFallbackLoads integer
---@field anchorX integer
---@field anchorZ integer
---@field origin { x: number, y: number, z: number }
---@field region table<string, unknown>
---@field terrainDependencyHash string
---@field released boolean
---@field pendingPrefetch table<string, unknown>?
local FieldCoverage = {}
FieldCoverage.__index = FieldCoverage

local function key(x, z)
  return string.format("%d:%d", x, z)
end

local function desired(x, z)
  local result = {}
  for _, dz in ipairs({ 0, -1, 1 }) do
    for dx = -1, 1 do
      result[#result + 1] = { x = x + dx, z = z + dz }
    end
  end
  return result
end

local function footprint(x, z)
  local result = {}
  for offsetZ = -2, 2 do
    for offsetX = -2, 2 do
      result[#result + 1] = { x = x + offsetX, z = z + offsetZ }
    end
  end
  return result
end

local function cellOrigin(runtime, descriptor)
  local origin = assert(runtime.origin or descriptor.origin, "field cell normalized origin is missing")
  assert(type(origin.x) == "number" and type(origin.y) == "number" and type(origin.z) == "number")
  return { x = origin.x, y = origin.y, z = origin.z }
end

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function identityNumber(value, context)
  if not finiteNumber(value) then
    Errors.raise(FieldErrors.FIELD_COVERAGE_TERRAIN_CACHE_INVALID, "field cell origin is not finite", context)
  end
  return string.format("%.17g", value)
end

local function dependencyIdentity(cells, matrixMemberId, anchorX, anchorZ)
  local identities = {
    "g4-coverage-v2",
    tostring(matrixMemberId),
    tostring(anchorX),
    tostring(anchorZ),
  }
  local keys = {}
  for cellKey in pairs(cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local cell = assert(cells[cellKey])
    local origin = assert(cell.origin)
    local terrain = assert(cell.terrain)
    local artifact = assert(terrain.artifact)
    local source = artifact.source
    if type(source) ~= "table" or type(source.bdhcSha1) ~= "string" or source.bdhcSha1 == "" then
      Errors.raise(
        FieldErrors.FIELD_COVERAGE_TERRAIN_CACHE_INVALID,
        "field cell terrain source bdhcSha1 is missing; rebuild the derived cache",
        { cellKey = cellKey }
      )
    end
    identities[#identities + 1] = table.concat({
      cellKey,
      identityNumber(origin.x, { cellKey = cellKey, axis = "x" }),
      identityNumber(origin.y, { cellKey = cellKey, axis = "y" }),
      identityNumber(origin.z, { cellKey = cellKey, axis = "z" }),
      source.bdhcSha1,
    }, ":")
  end
  return table.concat(identities, "|")
end

local function ownPresentation(runtime, presentation)
  local releaseRuntime = runtime.release
  local released = false
  runtime.presentation = presentation
  local function release(self)
    if released then
      return
    end
    released = true
    if presentation and presentation ~= self and presentation.release then
      presentation:release()
    end
    if releaseRuntime then
      releaseRuntime(self)
    end
  end
  runtime.release = release
  return runtime
end

local function runtimeFromDescriptor(self, descriptor, acquirePresentation)
  local runtime
  if self.loadCell then
    runtime = self.loadCell(descriptor)
  else
    local cell = assert(self.cacheFs:loadLua(descriptor.file), "field cell descriptor is missing")
    local collisionBytes = assert(self.cacheFs:read(cell.collision.file), "field cell collision is missing")
    local collision = assert(CollisionGridAsset.decode(collisionBytes))
    local terrainArtifact = assert(self.cacheFs:loadLua(cell.terrain.file), "field cell terrain is missing")
    local function release() end
    runtime = {
      key = key(cell.x, cell.z),
      x = cell.x,
      z = cell.z,
      altitude = cell.altitude,
      origin = cell.origin,
      collision = CollisionGrid.new(collision),
      terrain = TerrainSurface.new(terrainArtifact),
      descriptor = cell,
      release = release,
    }
  end
  runtime = assert(runtime, "field cell loader returned no runtime")
  local ok, result = pcall(function()
    runtime.key = runtime.key or key(descriptor.x, descriptor.z)
    runtime.x, runtime.z = runtime.x or descriptor.x, runtime.z or descriptor.z
    runtime.altitude = runtime.altitude or descriptor.altitude
    runtime.origin = cellOrigin(runtime, descriptor)
    local presentationDescriptor = runtime.descriptor or descriptor
    local presentation
    if acquirePresentation and self.presentationLoader then
      presentation = self.presentationLoader(runtime, presentationDescriptor)
    else
      presentation = runtime.presentation
    end
    return ownPresentation(runtime, presentation)
  end)
  if not ok then
    if runtime.release then
      runtime:release()
    end
    error(result, 0)
  end
  return result
end

local function normalizeRuntime(runtime, descriptor)
  runtime = assert(runtime, "field cell loader returned no runtime")
  runtime.key = runtime.key or key(descriptor.x, descriptor.z)
  runtime.x, runtime.z = runtime.x or descriptor.x, runtime.z or descriptor.z
  runtime.altitude = runtime.altitude or descriptor.altitude
  runtime.origin = cellOrigin(runtime, descriptor)
  return runtime
end

local function newPending(self, descriptor)
  return {
    descriptor = descriptor,
    cellKey = key(descriptor.x, descriptor.z),
    phase = self.loadCell and "load" or "readCell",
  }
end

local function releasePending(pending)
  assert(pending)
  local presentationTask = pending.presentationTask
  if presentationTask then
    pending.presentationTask = nil
    presentationTask:release()
  end
  local runtime = pending.runtime
  if runtime then
    pending.runtime = nil
    if runtime.release then
      runtime:release()
    end
  end
end

local function publishPending(pending, presentation)
  local runtime = assert(pending.runtime)
  if presentation ~= nil then
    runtime = ownPresentation(runtime, presentation)
  elseif not runtime.presentation then
    runtime = ownPresentation(runtime, nil)
  end
  pending.runtime = runtime
  pending.complete = true
end

local function advancePending(self, pending, maxWorkUnits)
  local consumed = 0
  while consumed < maxWorkUnits and not pending.complete do
    if pending.phase == "load" then
      local runtime = self.loadCell(assert(pending.descriptor))
      pending.runtime = runtime
      pending.runtime = normalizeRuntime(pending.runtime, pending.descriptor)
      if not self.presentationTaskFactory and not self.presentationLoader then
        publishPending(pending, pending.runtime.presentation)
        pending.phase = "complete"
      else
        pending.phase = "presentation"
      end
      consumed = consumed + 1
    elseif pending.phase == "readCell" then
      pending.cell = assert(self.cacheFs:loadLua(assert(pending.descriptor).file), "field cell descriptor is missing")
      pending.phase = "readCollision"
      consumed = consumed + 1
    elseif pending.phase == "readCollision" then
      pending.collisionBytes =
        assert(self.cacheFs:read(assert(pending.cell).collision.file), "field cell collision is missing")
      pending.phase = "decodeCollision"
      consumed = consumed + 1
    elseif pending.phase == "decodeCollision" then
      pending.collision = assert(CollisionGridAsset.decode(assert(pending.collisionBytes)))
      pending.phase = "readTerrain"
      consumed = consumed + 1
    elseif pending.phase == "readTerrain" then
      pending.terrainArtifact =
        assert(self.cacheFs:loadLua(assert(pending.cell).terrain.file), "field cell terrain is missing")
      pending.phase = "buildRuntime"
      consumed = consumed + 1
    elseif pending.phase == "buildRuntime" then
      local cell = assert(pending.cell)
      local function release() end
      pending.runtime = {
        key = pending.cellKey,
        x = cell.x,
        z = cell.z,
        altitude = cell.altitude,
        origin = cell.origin,
        collision = CollisionGrid.new(assert(pending.collision)),
        terrain = TerrainSurface.new(assert(pending.terrainArtifact)),
        descriptor = cell,
        release = release,
      }
      pending.runtime = normalizeRuntime(pending.runtime, pending.descriptor)
      if not self.presentationTaskFactory and not self.presentationLoader then
        publishPending(pending, nil)
        pending.phase = "complete"
      else
        pending.phase = "presentation"
      end
      consumed = consumed + 1
    elseif pending.phase == "presentation" then
      local runtime = assert(pending.runtime)
      local descriptor = runtime.descriptor or pending.descriptor
      if self.presentationTaskFactory then
        pending.presentationTask = assert(self.presentationTaskFactory(runtime, descriptor))
        pending.phase = "presentationTask"
      elseif self.presentationLoader then
        pending.phase = "legacyPresentation"
      elseif runtime.presentation then
        publishPending(pending, runtime.presentation)
        pending.phase = "complete"
      else
        publishPending(pending, nil)
        pending.phase = "complete"
      end
    elseif pending.phase == "legacyPresentation" then
      local runtime = assert(pending.runtime)
      publishPending(pending, self.presentationLoader(runtime, runtime.descriptor or pending.descriptor))
      pending.phase = "complete"
      consumed = consumed + 1
    elseif pending.phase == "presentationTask" then
      local task = assert(pending.presentationTask)
      local taskConsumed = 0
      if not task:isReady() then
        taskConsumed = task:advance(maxWorkUnits - consumed)
        assert(
          type(taskConsumed) == "number"
            and taskConsumed >= 0
            and taskConsumed % 1 == 0
            and taskConsumed <= maxWorkUnits - consumed,
          "presentation task consumed an invalid work-unit count"
        )
        consumed = consumed + taskConsumed
      end
      if task:isReady() then
        publishPending(pending, task:takeResult())
        pending.presentationTask = nil
        pending.phase = "complete"
      elseif taskConsumed == 0 then
        break
      end
    else
      error("unknown pending physical phase " .. tostring(pending.phase), 0)
    end
  end
  return consumed
end

local function finishPending(self, pending)
  while not pending.complete do
    if pending.phase == "presentationTask" then
      local task = assert(pending.presentationTask)
      publishPending(pending, task:finish())
      pending.presentationTask = nil
      pending.phase = "complete"
    else
      local consumed = advancePending(self, pending, 1)
      assert(consumed > 0 or pending.complete, "pending physical build made no progress")
    end
  end
  return assert(pending.runtime)
end

local function finishPendingSafely(self, pending)
  local ok, runtime = pcall(finishPending, self, pending)
  if not ok then
    releasePending(pending)
    error(runtime, 0)
  end
  return assert(runtime)
end

local function buildRegion(cells, anchor)
  local central = assert(cells[key(anchor.x, anchor.z)], "coverage anchor cell is missing")
  local neighbors = {}
  local centralOrigin = assert(central.origin, "coverage cell origin is missing")
  for cellKey, cell in pairs(cells) do
    if cellKey ~= central.key then
      local origin = assert(cell.origin, "coverage cell origin is missing")
      neighbors[#neighbors + 1] = {
        key = cell.key,
        offsetTilesX = origin.x - centralOrigin.x,
        offsetTilesY = origin.y - centralOrigin.y,
        offsetTilesZ = origin.z - centralOrigin.z,
        collision = cell.collision,
        terrain = cell.terrain,
      }
    end
  end
  table.sort(neighbors, function(a, b)
    return a.key < b.key
  end)
  return FieldRegion.new(central.collision, central.terrain, neighbors, central.key, 1)
end

function FieldCoverage.new(options)
  assert(type(options) == "table", "FieldCoverage options required")
  assert(type(options.matrixMemberId) == "number", "field cell matrix member required")
  assert(options.loadCell or options.cacheFs, "field coverage requires loadCell or cacheFs")
  assert(options.index or options.cacheFs, "field coverage requires index or cacheFs")
  local self = setmetatable({
    cacheFs = options.cacheFs,
    index = options.index or FieldCellCache.loadIndex(options.cacheFs),
    matrixMemberId = options.matrixMemberId,
    loadCell = options.loadCell,
    presentationLoader = options.presentationLoader,
    presentationTaskFactory = options.presentationTaskFactory,
    derivedAssets = options.derivedAssets,
    cells = {},
    prefetched = {},
    prefetchQueue = {},
    pendingPrefetch = nil,
    prefetchError = nil,
    synchronousPhysicalFallbackLoads = 0,
    released = false,
  }, FieldCoverage)
  self:recenter(options.anchorX, options.anchorZ)
  return self
end

function FieldCoverage:recenter(anchorX, anchorZ)
  assert(not self.released, "coverage is released")
  assert(type(anchorX) == "number" and anchorX % 1 == 0 and type(anchorZ) == "number" and anchorZ % 1 == 0)
  if anchorX == self.anchorX and anchorZ == self.anchorZ then
    self:queuePrefetch(anchorX, anchorZ)
    return self
  end
  local targetFootprint = self:_descriptorSet(anchorX, anchorZ, 2)
  local targetCommitted = self:_descriptorSet(anchorX, anchorZ, 1)
  if self.pendingPrefetch then
    local pendingKey = self.pendingPrefetch.cellKey
    if targetCommitted[pendingKey] then
      -- The pending cell is consumed by the new committed window below.
    elseif targetFootprint[pendingKey] then
      -- The pending cell remains owned by the halo prefetch until it completes.
    else
      local pending = self.pendingPrefetch
      self.pendingPrefetch = nil
      releasePending(pending)
    end
  end
  local staged, acquired = {}, {}
  local hadCommittedCells = next(self.cells) ~= nil
  local candidate
  local ok, err = pcall(function()
    local pending = self.pendingPrefetch
    for _, position in ipairs(desired(anchorX, anchorZ)) do
      local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, position.x, position.z)
      if descriptor then
        local cellKey = key(position.x, position.z)
        if not self.cells[cellKey] and not self.prefetched[cellKey] and (not pending or pending.cellKey ~= cellKey) then
          if self.derivedAssets then
            self.derivedAssets.ensureCell(descriptor)
          end
        end
      end
    end
    for _, position in ipairs(desired(anchorX, anchorZ)) do
      local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, position.x, position.z)
      if descriptor then
        local cellKey = key(position.x, position.z)
        local existing = self.cells[cellKey] or self.prefetched[cellKey]
        if existing then
          staged[cellKey] = existing
        else
          local currentPending = self.pendingPrefetch
          local runtime
          if currentPending and currentPending.cellKey == cellKey then
            self.pendingPrefetch = nil
            runtime = finishPendingSafely(self, currentPending)
          else
            runtime = finishPendingSafely(self, newPending(self, descriptor))
          end
          runtime.key = runtime.key or cellKey
          runtime.x, runtime.z = position.x, position.z
          runtime.altitude = runtime.altitude or descriptor.altitude
          staged[cellKey] = runtime
          acquired[#acquired + 1] = runtime
          if hadCommittedCells then
            self.synchronousPhysicalFallbackLoads = self.synchronousPhysicalFallbackLoads + 1
          end
        end
      end
    end
    assert(staged[key(anchorX, anchorZ)], "coverage anchor is not a generated cell")
    candidate = {
      anchorX = anchorX,
      anchorZ = anchorZ,
      cells = staged,
      region = buildRegion(staged, { x = anchorX, z = anchorZ }),
      origin = assert(staged[key(anchorX, anchorZ)].origin),
      terrainDependencyHash = dependencyIdentity(staged, self.matrixMemberId, anchorX, anchorZ),
    }
  end)
  if not ok then
    for _, cell in ipairs(acquired) do
      if cell.release then
        cell:release()
      end
    end
    error(err, 0)
  end
  candidate = assert(candidate)
  local old = {}
  for cellKey, cell in pairs(self.cells) do
    old[cellKey] = cell
  end
  for cellKey, cell in pairs(self.prefetched) do
    old[cellKey] = cell
  end
  self.cells = candidate.cells
  self.prefetched = {}
  self.anchorX, self.anchorZ = candidate.anchorX, candidate.anchorZ
  self.region = candidate.region
  self.origin = candidate.origin
  self.terrainDependencyHash = candidate.terrainDependencyHash
  local newFootprint = targetFootprint
  for cellKey, cell in pairs(old) do
    if not self.cells[cellKey] and newFootprint[cellKey] then
      self.prefetched[cellKey] = cell
    elseif not self.cells[cellKey] and cell.release then
      cell:release()
    end
  end
  self:queuePrefetch(candidate.anchorX, candidate.anchorZ)
  return self
end

---@param anchorX integer
---@param anchorZ integer
---@param radius integer
---@return table<string, boolean>
function FieldCoverage:_descriptorSet(anchorX, anchorZ, radius)
  local result = {}
  for offsetZ = -radius, radius do
    for offsetX = -radius, radius do
      local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, anchorX + offsetX, anchorZ + offsetZ)
      if descriptor then
        result[key(descriptor.x, descriptor.z)] = true
      end
    end
  end
  return result
end

---@param anchorX integer
---@param anchorZ integer
---@return table[]
function FieldCoverage:descriptorsFor(anchorX, anchorZ)
  local result = {}
  for _, position in ipairs(desired(anchorX, anchorZ)) do
    local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, position.x, position.z)
    if descriptor then
      result[#result + 1] = descriptor
    end
  end
  return result
end

---@return table[]
function FieldCoverage:committedDescriptors()
  local result = {}
  local keys = {}
  for cellKey in pairs(self.cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local cell = assert(self.cells[cellKey])
    result[#result + 1] = cell.descriptor
      or assert(FieldCellCache.find(self.index, self.matrixMemberId, cell.x, cell.z))
  end
  return result
end

---@param anchorX integer?
---@param anchorZ integer?
---@return table[]
function FieldCoverage:prefetchDescriptors(anchorX, anchorZ)
  anchorX, anchorZ = anchorX or self.anchorX, anchorZ or self.anchorZ
  local result = {}
  for _, position in ipairs(footprint(anchorX, anchorZ)) do
    local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, position.x, position.z)
    if descriptor then
      result[#result + 1] = descriptor
    end
  end
  return result
end

---@param anchorX integer?
---@param anchorZ integer?
---@return FieldCoverage
function FieldCoverage:queuePrefetch(anchorX, anchorZ)
  anchorX, anchorZ = anchorX or self.anchorX, anchorZ or self.anchorZ
  assert(anchorX and anchorZ, "coverage anchor is required before prefetching")
  local committed = self:_descriptorSet(anchorX, anchorZ, 1)
  local required = self:_descriptorSet(anchorX, anchorZ, 2)
  if self.pendingPrefetch and not required[self.pendingPrefetch.cellKey] then
    local pending = self.pendingPrefetch
    self.pendingPrefetch = nil
    releasePending(pending)
  end
  local queued = {}
  for _, descriptor in ipairs(self:prefetchDescriptors(anchorX, anchorZ)) do
    local cellKey = key(descriptor.x, descriptor.z)
    if
      not committed[cellKey]
      and not self.prefetched[cellKey]
      and (not self.pendingPrefetch or self.pendingPrefetch.cellKey ~= cellKey)
    then
      if self.derivedAssets then
        self.derivedAssets.requestCell(descriptor)
      end
      queued[#queued + 1] = descriptor
    end
  end
  self.prefetchQueue = queued
  self.prefetchError = nil
  return self
end

---@param maxWorkUnits integer
---@return integer
function FieldCoverage:updatePrefetch(maxWorkUnits)
  assert(not self.released, "coverage is released")
  assert(type(maxWorkUnits) == "number" and maxWorkUnits >= 0 and maxWorkUnits % 1 == 0)
  local consumed = 0
  while consumed < maxWorkUnits do
    if not self.pendingPrefetch then
      local descriptor = table.remove(self.prefetchQueue, 1)
      if not descriptor then
        break
      end
      if self.derivedAssets and not self.derivedAssets.requestCell(descriptor) then
        table.insert(self.prefetchQueue, 1, descriptor)
        break
      end
      self.pendingPrefetch = newPending(self, descriptor)
    end
    local pending = assert(self.pendingPrefetch)
    local ok, work = pcall(advancePending, self, pending, maxWorkUnits - consumed)
    if not ok then
      self.pendingPrefetch = nil
      releasePending(pending)
      self.prefetchError = work
      break
    end
    consumed = consumed + assert(work)
    if pending.complete then
      self.prefetched[pending.cellKey] = assert(pending.runtime)
      self.pendingPrefetch = nil
    elseif work == 0 then
      break
    end
  end
  ---@cast consumed integer
  return consumed
end

function FieldCoverage:_dependencyIdentity()
  return dependencyIdentity(self.cells, self.matrixMemberId, self.anchorX, self.anchorZ)
end

function FieldCoverage:status()
  local resident = {}
  for cellKey in pairs(self.cells) do
    resident[#resident + 1] = cellKey
  end
  table.sort(resident)
  local prefetched = {}
  for cellKey in pairs(self.prefetched) do
    prefetched[#prefetched + 1] = cellKey
  end
  table.sort(prefetched)
  return {
    matrixMemberId = self.matrixMemberId,
    anchorX = self.anchorX,
    anchorZ = self.anchorZ,
    residentCellKeys = resident,
    residentCount = #resident,
    committedCount = #resident,
    readyPrefetchCount = #prefetched,
    queuedPrefetchCount = #self.prefetchQueue,
    pendingPrefetchCellKey = self.pendingPrefetch and self.pendingPrefetch.cellKey or nil,
    prefetchedCellKeys = prefetched,
    synchronousPhysicalFallbackLoads = self.synchronousPhysicalFallbackLoads,
    prefetchError = self.prefetchError,
    terrainDependencyHash = self.terrainDependencyHash,
    physicalOrigin = { x = self.origin.x, y = self.origin.y, z = self.origin.z },
    probeCount = 0,
  }
end

function FieldCoverage:containsGlobal(fieldX, fieldZ)
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  return self.cells[key(cellX, cellZ)] ~= nil
end

---@param fieldX integer
---@param fieldZ integer
---@return integer?
function FieldCoverage:mapHeaderAt(fieldX, fieldZ)
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local cell = self.cells[key(cellX, cellZ)]
  if cell then
    return cell.mapHeaderId or (cell.descriptor and cell.descriptor.mapHeaderId)
  end
  local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ)
  return descriptor and descriptor.mapHeaderId or nil
end

function FieldCoverage:sourceSurface(cellKey, sourceSurfaceId)
  return self.region:sourceSurface(cellKey, sourceSurfaceId)
end

-- Project a stable physical surface into the current resident frame. The
-- returned world position is derived from the current composite terrain and
-- normalized physical origin; callers must not retain it as semantic state.
---@param fieldX integer
---@param fieldZ integer
---@param cellKey string
---@param sourceSurfaceId integer
---@return { fieldX: integer, fieldZ: integer, cellKey: string, sourceSurfaceId: integer, surfaceId: integer, localX: number, localZ: number, worldX: number, worldY: number, worldZ: number }
function FieldCoverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "projected fieldX must be an integer")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "projected fieldZ must be an integer")
  assert(type(cellKey) == "string", "projected cell key is required")
  assert(type(sourceSurfaceId) == "number", "projected source surface is required")
  local surfaceId =
    assert(self:sourceSurface(cellKey, sourceSurfaceId), "projected source surface is absent from coverage")
  local localX = fieldX - self.origin.x
  local localZ = fieldZ - self.origin.z
  local sampleX = localX + 0.5
  local sampleZ = localZ + 0.5
  local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    surfaceId = surfaceId,
    localX = localX,
    localZ = localZ,
    worldX = worldX,
    worldY = self.region.terrain:sampleHeight(surfaceId, sampleX, sampleZ),
    worldZ = worldZ,
  }
end

local function presentationDraws(presentation)
  if not presentation then
    return {}
  end
  if type(presentation.parts) == "table" then
    return presentation.parts
  end
  local result = {}
  for _, field in ipairs({ "mapDraws", "staticBuildingDraws", "animatedBuildingDraws", "draws" }) do
    local draws = presentation[field]
    if type(draws) == "table" then
      for _, draw in ipairs(draws) do
        result[#result + 1] = draw
      end
    end
  end
  if #result == 0 and presentation.cellKey then
    result[1] = presentation
  end
  return result
end

local function translatedPart(part, cell, origin)
  local result = {}
  for field, value in pairs(part) do
    result[field] = value
  end
  result.cellKey = cell.key
  result.translation = {
    x = cell.origin.x - origin.x,
    y = cell.origin.y - origin.y,
    z = cell.origin.z - origin.z,
  }
  if part.transform then
    result.transform = Matrix4.multiply(
      Matrix4.translate(result.translation.x, result.translation.y, result.translation.z),
      part.transform
    )
  end
  if part.billboardBase then
    result.billboardBase = Matrix4.multiply(
      Matrix4.translate(result.translation.x, result.translation.y, result.translation.z),
      part.billboardBase
    )
    result.billboardCenter, result.billboardScale = BillboardTransform.components(result.billboardBase)
  end
  return result
end

function FieldCoverage:worldParts()
  local result = {}
  local keys = {}
  for cellKey in pairs(self.cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local cell = self.cells[cellKey]
    for _, part in ipairs(presentationDraws(cell.presentation)) do
      result[#result + 1] = translatedPart(part, cell, self.origin)
    end
  end
  return result
end

function FieldCoverage:updateAnimated()
  assert(not self.released, "coverage is released")
  local keys = {}
  for cellKey in pairs(self.cells) do
    keys[#keys + 1] = cellKey
  end
  table.sort(keys)
  for _, cellKey in ipairs(keys) do
    local presentation = self.cells[cellKey].presentation
    if presentation and presentation.updateAnimated then
      presentation:updateAnimated()
    end
  end
end

-- Read-only generated-cache lookup used by route planning before a committed
-- step can recenter the resident window. It creates no resident ownership and
-- releases the temporary CPU cell immediately.
local function terrainFor(runtime)
  if runtime.terrain.candidatesAt and runtime.terrain.plate and runtime.terrain.sampleHeight then
    return runtime.terrain
  end
  return TerrainSurface.new(runtime.terrain)
end

local function resolveProbe(self, runtime, sourceRuntime, fieldX, fieldZ, context)
  local terrain
  local localX, localZ
  local region
  if context then
    local source = assert(sourceRuntime, "probe source cell runtime is missing")
    local sourceOrigin = assert(source.origin, "probe source cell origin is missing")
    if runtime == source and self.cells[context.currentCellKey] then
      region = self.region
      localX = fieldX - self.origin.x + 0.5
      localZ = fieldZ - self.origin.z + 0.5
      local fromX = context.fromFieldX - self.origin.x + 0.5
      local fromZ = context.fromFieldZ - self.origin.z + 0.5
      terrain = region.terrain
      local currentSurfaceId = assert(
        region:sourceSurface(context.currentCellKey, context.currentSourceSurfaceId),
        "probe source surface is absent from current coverage"
      )
      local sample = SurfaceResolver.new(terrain):resolve({
        localX = localX,
        localZ = localZ,
        currentSurfaceId = currentSurfaceId,
        currentY = context.currentY,
        crossing = { fromX = fromX, fromZ = fromZ, toX = localX, toZ = localZ },
      })
      return sample, terrain, region, 0
    end

    local destinationOrigin = assert(runtime.origin, "probe destination cell origin is missing")
    local neighbors = {}
    if runtime ~= source then
      neighbors[1] = {
        key = runtime.key,
        offsetTilesX = destinationOrigin.x - sourceOrigin.x,
        offsetTilesY = destinationOrigin.y - sourceOrigin.y,
        offsetTilesZ = destinationOrigin.z - sourceOrigin.z,
        collision = runtime.collision,
        terrain = runtime.terrain,
      }
    end
    region = FieldRegion.new(source.collision, source.terrain, neighbors, source.key, 1)
    local currentSurfaceId = assert(
      region:sourceSurface(context.currentCellKey, context.currentSourceSurfaceId),
      "probe source surface is absent from temporary region"
    )
    local fromX = context.fromFieldX - sourceOrigin.x + 0.5
    local fromZ = context.fromFieldZ - sourceOrigin.z + 0.5
    local destinationX = fieldX - sourceOrigin.x + 0.5
    local destinationZ = fieldZ - sourceOrigin.z + 0.5
    local frameOffsetY = sourceOrigin.y - self.origin.y
    local sample = SurfaceResolver.new(region.terrain):resolve({
      localX = destinationX,
      localZ = destinationZ,
      currentSurfaceId = currentSurfaceId,
      currentY = context.currentY - frameOffsetY,
      crossing = { fromX = fromX, fromZ = fromZ, toX = destinationX, toZ = destinationZ },
    })
    return sample, region.terrain, region, frameOffsetY
  end

  local destinationX = fieldX - math.floor(fieldX / 32) * 32 + 0.5
  local destinationZ = fieldZ - math.floor(fieldZ / 32) * 32 + 0.5
  terrain = terrainFor(runtime)
  local sample = SurfaceResolver.new(terrain):resolve({ localX = destinationX, localZ = destinationZ })
  return sample, terrain, nil, 0
end

local function cellCoordinates(cellKey)
  local x, z = string.match(cellKey, "^(-?%d+):(-?%d+)$")
  assert(x and z, "physical cell key must contain integer coordinates")
  return assert(tonumber(x)), assert(tonumber(z))
end

local function acquireProbeCell(self, cellKey)
  local runtime = self.cells[cellKey]
  if runtime then
    return runtime, false
  end
  local cellX, cellZ = cellCoordinates(cellKey)
  local descriptor = assert(
    FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ),
    "probe source cell descriptor is missing"
  )
  if self.derivedAssets then
    self.derivedAssets.ensureCell(descriptor)
  end
  return assert(runtimeFromDescriptor(self, descriptor, false)), true
end

---@param fieldX integer
---@param fieldZ integer
---@param context PhysicalProbeContext?
---@return table<string, unknown>?
function FieldCoverage:probe(fieldX, fieldZ, context)
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "probed fieldX must be an integer")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "probed fieldZ must be an integer")
  local cellX, cellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
  local descriptor = FieldCellCache.find(self.index, self.matrixMemberId, cellX, cellZ)
  if not descriptor then
    return {
      cellKey = key(cellX, cellZ),
      collision = { blocked = true, cellKey = key(cellX, cellZ) },
      sourceSurfaceId = nil,
    }
  end
  local cellKey = key(cellX, cellZ)
  local runtime = self.cells[cellKey]
  local temporary = runtime == nil
  local sourceRuntime
  local sourceTemporary = false
  local localX, localZ = fieldX - cellX * 32, fieldZ - cellZ * 32
  local ok, result = pcall(function()
    if context then
      if context.currentCellKey == cellKey then
        if runtime == nil then
          runtime, temporary = acquireProbeCell(self, cellKey)
        end
        sourceRuntime = runtime
      else
        sourceRuntime, sourceTemporary = acquireProbeCell(self, context.currentCellKey)
      end
    end
    if self.derivedAssets and runtime == nil then
      self.derivedAssets.ensureCell(descriptor)
    end
    runtime = runtime or assert(runtimeFromDescriptor(self, descriptor, false))
    local collision = runtime.collision:getLocal(localX, localZ)
    collision.cellKey = cellKey
    local sample, terrain, region, frameOffsetY = resolveProbe(self, runtime, sourceRuntime, fieldX, fieldZ, context)
    local plate = assert(terrain:plate(sample.surfaceId), "probed terrain surface is missing")
    return {
      cellKey = plate.cellKey or cellKey,
      collision = collision,
      sourceSurfaceId = plate.sourceSurfaceId ~= nil and plate.sourceSurfaceId or plate.id,
      surfaceId = context and region == self.region and sample.surfaceId or nil,
      worldY = sample.worldY + frameOffsetY,
    }
  end)
  if temporary and runtime and runtime.release then
    runtime:release()
  end
  if sourceTemporary and sourceRuntime and sourceRuntime.release then
    sourceRuntime:release()
  end
  if not ok then
    if SurfaceResolver.isStepRejection(result) then
      return nil
    end
    error(result, 0)
  end
  return result
end

function FieldCoverage:release()
  if self.released then
    return
  end
  self.released = true
  if self.pendingPrefetch then
    local pending = self.pendingPrefetch
    self.pendingPrefetch = nil
    releasePending(pending)
  end
  for _, cell in pairs(self.cells) do
    if cell.release then
      cell:release()
    end
  end
  for _, cell in pairs(self.prefetched) do
    if cell.release then
      cell:release()
    end
  end
  self.cells = {}
  self.prefetched = {}
  self.prefetchQueue = {}
end

return FieldCoverage
