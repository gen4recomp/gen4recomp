-- Coordinates identity-keyed interactive field, map, and script production.

local CacheFs = require("libs.storage.src.CacheFs")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local RomFs = require("romdump.src.source.RomFs")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CompilerPool = require("romdump.src.build.CompilerPool")

---@class InteractiveCacheBuild.Descriptor
---@field matrixMemberId integer
---@field index integer
---@field x integer
---@field z integer
---@field mapHeaderId integer
---@field altitude number
---@field landDataMemberId integer
---@field areaDataMemberId integer

---@class InteractiveCacheBuild.Matrix
---@field matrixMemberId integer
---@field cells InteractiveCacheBuild.Descriptor[]

---@class InteractiveCacheBuild.Index
---@field matrices InteractiveCacheBuild.Matrix[]

---@class InteractiveCacheBuild.FieldCellPlan
---@field descriptor InteractiveCacheBuild.Descriptor
---@field expectedMarker string
---@field failure string|Errors.Error?

---@class InteractiveCacheBuild.MapPlan
---@field cellPlans InteractiveCacheBuild.FieldCellPlan[]
---@field resolved { map: { id: integer } }
---@field expectedMarker string
---@field failure string|Errors.Error?

---@class InteractiveCacheBuild.World
---@field byId table<integer, table<string, unknown>>
---@field maps { id: integer }[]

---@class InteractiveCacheBuild.ScriptMemberPlan
---@field memberId integer
---@field marker string

---@class InteractiveCacheBuild.ScriptPlan
---@field generationKey string
---@field marker string
---@field members InteractiveCacheBuild.ScriptMemberPlan[]

---@class InteractiveCacheBuild
---@field versionId string
---@field cacheFs CacheFs
---@field romFs RomFs
---@field pool CompilerPool
---@field index InteractiveCacheBuild.Index
---@field world InteractiveCacheBuild.World
---@field producerFingerprint string
---@field scriptPlan InteractiveCacheBuild.ScriptPlan
---@field cellPlans table<string, InteractiveCacheBuild.FieldCellPlan>
---@field mapPlans table<integer, InteractiveCacheBuild.MapPlan>
---@field pendingMaps table<integer, InteractiveCacheBuild.MapPlan>
---@field scriptJobs table<integer, string|table<string, unknown>>
---@field cellCursor integer
---@field cellIndex integer?
---@field mapCursor integer
---@field scriptCursor integer
---@field farKey string?
---@field infrastructureError unknown
---@field closed boolean
local InteractiveCacheBuild = {}
InteractiveCacheBuild.__index = InteractiveCacheBuild

local REQUIRED, FIELD, MAP, SCRIPT = 0, 10, 110, 120

local function exactDescriptor(index, descriptor)
  assert(type(descriptor) == "table", "field cell descriptor is required")
  local found = FieldCellCache.find(index, descriptor.matrixMemberId, descriptor.x, descriptor.z)
  assert(found, "field cell descriptor is not in the current index")
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
    assert(found[key] == descriptor[key], "field cell descriptor does not match the current index")
  end
  return found
end

local function readyCell(cacheFs, plan)
  return FieldCellCache.isCellReady(cacheFs, plan.descriptor, plan.expectedMarker)
end

local function readyMap(cacheFs, plan)
  return MapAssetCache.isReady(cacheFs, plan.resolved.map.id, plan.expectedMarker)
end

local function allReady(self, mapPlan)
  for _, cellPlan in ipairs(mapPlan.cellPlans) do
    if not readyCell(self.cacheFs, cellPlan) then
      return false
    end
  end
  return true
end

local function orderedPendingMapPlans(pendingMaps)
  local plans = {}
  for _, plan in pairs(pendingMaps) do
    plans[#plans + 1] = plan
  end
  table.sort(plans, function(left, right)
    return left.resolved.map.id < right.resolved.map.id
  end)
  return plans
end

---@param options table<string, unknown>
---@return InteractiveCacheBuild
function InteractiveCacheBuild.new(options)
  assert(type(options) == "table", "interactive cache build options are required")
  local versionId = assert(options.versionId, "interactive cache build version is required")
  assert(
    type(options.producerFingerprint) == "string" and options.producerFingerprint ~= "",
    "interactive cache build producer fingerprint is required"
  )
  local producerFingerprint = options.producerFingerprint
  local developmentRoot = options.developmentRepositoryRoot
  local cacheFs = CacheFs.forVersion(versionId)
  local romFs, openError = RomFs.open(versionId)
  assert(romFs, openError)
  local function initialize()
    local indexBundle = assert(FieldCellCompiler.compileIndex(romFs, producerFingerprint))
    if cacheFs:read(FieldCellCache.indexMarkerPath()) ~= indexBundle.indexMarker then
      FieldCellCacheWriter.writeIndex(cacheFs, indexBundle)
    end
    local index = FieldCellCache.loadIndex(cacheFs)
    local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world manifest is missing")
    local scriptPlan = ScriptCompiler.plan(romFs, producerFingerprint)
    if
      not ScriptCache.isReady(cacheFs, scriptPlan.marker)
      and ScriptCache.isGenerationReady(cacheFs, scriptPlan.generationKey, scriptPlan.marker)
    then
      ScriptCacheWriter.activateGeneration(cacheFs, scriptPlan.generationKey)
    end
    local pool = CompilerPool.new({
      versionId = versionId,
      mode = "interactive",
      developmentRepositoryRoot = developmentRoot,
    })
    return setmetatable({
      versionId = versionId,
      cacheFs = cacheFs,
      romFs = romFs,
      pool = pool,
      index = index,
      world = world,
      producerFingerprint = producerFingerprint,
      scriptPlan = scriptPlan,
      cellPlans = {},
      mapPlans = {},
      pendingMaps = {},
      scriptJobs = {},
      cellCursor = 1,
      mapCursor = 1,
      scriptCursor = 1,
      farKey = nil,
      closed = false,
    }, InteractiveCacheBuild)
  end
  local ok, result = pcall(initialize)
  if not ok then
    romFs:close()
    error(result, 0)
  end
  return result
end

function InteractiveCacheBuild:_cellPlan(descriptor)
  local authoritative = exactDescriptor(self.index, descriptor)
  local key = authoritative.matrixMemberId .. ":" .. authoritative.index
  local plan = self.cellPlans[key]
  if not plan then
    plan = assert(FieldCellCompiler.planCell(self.romFs, authoritative, self.producerFingerprint))
    self.cellPlans[key] = plan
  end
  return plan
end

function InteractiveCacheBuild:_requestCellPlan(plan, priority)
  if readyCell(self.cacheFs, plan) then
    return true
  end
  local key = "field-cell:"
    .. plan.descriptor.matrixMemberId
    .. ":"
    .. plan.descriptor.index
    .. ":"
    .. plan.expectedMarker
  local ok, stateOrError = pcall(self.pool.request, self.pool, {
    kind = "field-cell",
    key = key,
    priority = priority,
    payload = {
      matrixMemberId = plan.descriptor.matrixMemberId,
      index = plan.descriptor.index,
      x = plan.descriptor.x,
      z = plan.descriptor.z,
      mapHeaderId = plan.descriptor.mapHeaderId,
      altitude = plan.descriptor.altitude,
      landDataMemberId = plan.descriptor.landDataMemberId,
      areaDataMemberId = plan.descriptor.areaDataMemberId,
      producerFingerprint = self.producerFingerprint,
    },
  })
  if not ok then
    plan.failure = stateOrError
    return false
  end
  if stateOrError == "failed" then
    plan.failure = "field cell compilation failed"
    return false
  end
  return readyCell(self.cacheFs, plan)
end

function InteractiveCacheBuild:requestCell(descriptor, priority)
  assert(not self.closed, "interactive cache build is disposed")
  local plan = self:_cellPlan(descriptor)
  if readyCell(self.cacheFs, plan) then
    return true
  end
  return self:_requestCellPlan(plan, priority or FIELD)
end

function InteractiveCacheBuild:ensureCell(descriptor)
  assert(not self.closed, "interactive cache build is disposed")
  local plan = self:_cellPlan(descriptor)
  if readyCell(self.cacheFs, plan) then
    return true
  end
  self:_requestCellPlan(plan, REQUIRED)
  if plan.failure then
    error(plan.failure, 0)
  end
  local key = "field-cell:"
    .. plan.descriptor.matrixMemberId
    .. ":"
    .. plan.descriptor.index
    .. ":"
    .. plan.expectedMarker
  local state, details = self.pool:wait(key)
  if state ~= "ready" or not readyCell(self.cacheFs, plan) then
    error(details and details.error or plan.failure or "field cell publication failed", 0)
  end
  return true
end

function InteractiveCacheBuild:_mapPlan(mapId)
  assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0, "map ID must be a non-negative integer")
  assert(self.world.byId[mapId] ~= nil, "map ID is not present in the world manifest")
  local plan = self.mapPlans[mapId]
  if not plan then
    plan = assert(MapCompilePlan.plan(self.romFs, self.index, mapId, self.producerFingerprint))
    self.mapPlans[mapId] = plan
  end
  return plan
end

function InteractiveCacheBuild:_requestMapPlan(plan, priority)
  if readyMap(self.cacheFs, plan) then
    return true
  end
  local key = "field-map:" .. plan.resolved.map.id .. ":" .. plan.expectedMarker
  local ok, stateOrError = pcall(self.pool.request, self.pool, {
    kind = "map",
    key = key,
    priority = priority,
    payload = { mapId = plan.resolved.map.id, producerFingerprint = self.producerFingerprint },
  })
  if not ok then
    plan.failure = stateOrError
    return false
  end
  if stateOrError == "failed" then
    plan.failure = "map compilation failed"
    return false
  end
  return readyMap(self.cacheFs, plan)
end

function InteractiveCacheBuild:requestField(mapId, priority)
  assert(not self.closed, "interactive cache build is disposed")
  local plan = self:_mapPlan(mapId)
  if readyMap(self.cacheFs, plan) then
    return true
  end
  self.pendingMaps[mapId] = plan
  for _, cellPlan in ipairs(plan.cellPlans) do
    self:_requestCellPlan(cellPlan, priority or FIELD)
  end
  return false
end

function InteractiveCacheBuild:ensureField(mapId)
  assert(not self.closed, "interactive cache build is disposed")
  local plan = self:_mapPlan(mapId)
  if readyMap(self.cacheFs, plan) then
    return true
  end
  for _, cellPlan in ipairs(plan.cellPlans) do
    self:_requestCellPlan(cellPlan, REQUIRED)
  end
  for _, cellPlan in ipairs(plan.cellPlans) do
    self:ensureCell(cellPlan.descriptor)
  end
  self:_requestMapPlan(plan, REQUIRED)
  if plan.failure then
    error(plan.failure, 0)
  end
  local key = "field-map:" .. plan.resolved.map.id .. ":" .. plan.expectedMarker
  local state, details = self.pool:wait(key)
  if state ~= "ready" or not readyMap(self.cacheFs, plan) then
    error(details and details.error or plan.failure or "map publication failed", 0)
  end
  return true
end

function InteractiveCacheBuild:_advancePendingMaps()
  for _, plan in ipairs(orderedPendingMapPlans(self.pendingMaps)) do
    local mapId = plan.resolved.map.id
    if readyMap(self.cacheFs, plan) then
      self.pendingMaps[mapId] = nil
    elseif allReady(self, plan) then
      self:_requestMapPlan(plan, FIELD)
      self.pendingMaps[mapId] = nil
    end
  end
end

function InteractiveCacheBuild:_advanceSweep()
  if self.farKey ~= nil then
    local state = self.pool:status(self.farKey)
    if state == "queued" or state == "running" or state == "prepared" then
      return
    end
    self.farKey = nil
  end
  while self.cellCursor <= #self.index.matrices do
    local matrix = self.index.matrices[self.cellCursor]
    if self.cellIndex == nil then
      self.cellIndex = 1
    end
    local descriptor = matrix.cells[self.cellIndex]
    if descriptor == nil then
      self.cellCursor = self.cellCursor + 1
      self.cellIndex = 1
    else
      self.cellIndex = self.cellIndex + 1
      local plan = self:_cellPlan(descriptor)
      if not readyCell(self.cacheFs, plan) then
        self:_requestCellPlan(plan, 100)
        self.farKey = "field-cell:"
          .. descriptor.matrixMemberId
          .. ":"
          .. descriptor.index
          .. ":"
          .. plan.expectedMarker
        return
      end
    end
  end
  while self.mapCursor <= #self.world.maps do
    local mapId = self.world.maps[self.mapCursor].id
    self.mapCursor = self.mapCursor + 1
    local plan = self:_mapPlan(mapId)
    if not readyMap(self.cacheFs, plan) then
      self.pendingMaps[mapId] = plan
      if allReady(self, plan) then
        self:_requestMapPlan(plan, MAP)
        self.farKey = "field-map:" .. mapId .. ":" .. plan.expectedMarker
      end
      return
    end
  end
  while self.scriptCursor <= #self.scriptPlan.members do
    local member = self.scriptPlan.members[self.scriptCursor]
    self.scriptCursor = self.scriptCursor + 1
    local key = "script-member:" .. self.scriptPlan.generationKey .. ":" .. member.memberId .. ":" .. member.marker
    if
      self.cacheFs:read(ScriptCache.memberMarkerPath(self.scriptPlan.generationKey, member.memberId)) ~= member.marker
    then
      local ok, state = pcall(self.pool.request, self.pool, {
        kind = "script-member",
        key = key,
        priority = SCRIPT,
        payload = {
          memberId = member.memberId,
          generationKey = self.scriptPlan.generationKey,
          producerFingerprint = self.producerFingerprint,
        },
      })
      if ok then
        self.farKey = key
        self.scriptJobs[member.memberId] = state
      end
      return
    end
  end
end

function InteractiveCacheBuild:update()
  assert(not self.closed, "interactive cache build is disposed")
  local ok, failure = pcall(self.pool.update, self.pool)
  if not ok then
    self.infrastructureError = failure
    return
  end
  self:_advancePendingMaps()
  self:_advanceSweep()
end

function InteractiveCacheBuild:dispose()
  if self.closed then
    return
  end
  self.closed = true
  local first
  local shutdownOk, shutdownErr = pcall(self.pool.shutdown, self.pool)
  if not shutdownOk then
    first = shutdownErr
  else
    local cleanupOk, cleanupErr = pcall(function()
      local complete = true
      for _, member in ipairs(self.scriptPlan.members) do
        if
          self.cacheFs:read(ScriptCache.memberMarkerPath(self.scriptPlan.generationKey, member.memberId))
          ~= member.marker
        then
          complete = false
          break
        end
      end

      if complete then
        if not ScriptCache.isGenerationReady(self.cacheFs, self.scriptPlan.generationKey, self.scriptPlan.marker) then
          ScriptCacheWriter.finalizeGeneration(self.cacheFs, self.scriptPlan)
        end
        if not ScriptCache.isReady(self.cacheFs, self.scriptPlan.marker) then
          ScriptCacheWriter.activateGeneration(self.cacheFs, self.scriptPlan.generationKey)
        end
      end
      ScriptCacheWriter.cleanupGenerations(self.cacheFs, { [self.scriptPlan.generationKey] = true })
    end)
    if not cleanupOk then
      first = cleanupErr
    end
  end
  local closeOk, closeErr = pcall(self.romFs.close, self.romFs)
  if not closeOk and first == nil then
    first = closeErr
  end
  if first ~= nil then
    error(first, 0)
  end
end

return InteractiveCacheBuild
