-- Owns logical field-map preparation and residency around the committed
-- physical coverage. Map loading, actor lifetime, and physical-cell ownership
-- remain with their existing owners; this module only coordinates membership
-- and transaction order. Object actors belong to FieldActorManager alone: a
-- logical resident never implies a live actor entry, and the only actor
-- collaboration here is reprojecting the already-active entry when committed
-- physical coverage recenters.

---@class FieldResidencyCoordinator
---@field coverage FieldCoverage?
---@field mapLoader FieldMapLoader
---@field actors FieldActorManager
---@field zoneController FieldZoneController
---@field composeMap fun(runtimeMap: RuntimeFieldMap, coverage: FieldCoverage?): RuntimeFieldMap
---@field onPreparedMap fun(runtimeMap: RuntimeFieldMap)?
---@field residents table<integer, FieldResidencyCoordinator.Resident>
---@field synchronousLogicalFallbackLoads integer
---@field initialized boolean
---@field disposed boolean
local FieldResidencyCoordinator = {}
FieldResidencyCoordinator.__index = FieldResidencyCoordinator

---@class FieldResidencyCoordinator.Resident
---@field logicalMap RuntimeFieldMap
---@field runtimeMap RuntimeFieldMap

---@class FieldResidencyCoordinator.ComposedRuntimeMap : RuntimeFieldMap
---@field logicalMap RuntimeFieldMap

---@class FieldResidencyCoordinator.StagedResident
---@field mapId integer
---@field resident FieldResidencyCoordinator.Resident
---@field protected boolean

---@class FieldResidencyCoordinator.Transition
---@field coordinator FieldResidencyCoordinator
---@field sourceCoverage FieldCoverage?
---@field sourceResidents table<integer, FieldResidencyCoordinator.Resident>
---@field targetCoverage FieldCoverage?
---@field destinationMapId integer
---@field targetResidents table<integer, FieldResidencyCoordinator.Resident>
---@field staged FieldResidencyCoordinator.StagedResident[]
---@field state "prepared"|"committed"|"discarded"

---@class FieldResidencyPlayer
---@field fieldX integer
---@field fieldZ integer
---@field currentMap RuntimeFieldMap

local function sortedIds(descriptors)
  local seen = {}
  for _, descriptor in ipairs(descriptors) do
    assert(type(descriptor.mapHeaderId) == "number", "field cell map header is missing")
    seen[descriptor.mapHeaderId] = true
  end
  local result = {}
  for mapId in pairs(seen) do
    result[#result + 1] = mapId
  end
  table.sort(result)
  return result
end

-- Desired logical residents for coverage descriptors: committed headers that
-- define a loadable logical map. Matrix filler headers own physical cells
-- but no logical map, so they stay out of logical residency while their
-- cells still load, present, and collide through physical coverage. Filler
-- classification itself belongs to FieldZoneIdentity; this selection only
-- decides prefetch membership through the loader capability check.
---@param descriptors table[]
---@return integer[]
function FieldResidencyCoordinator:_desiredIds(descriptors)
  local result = {}
  for _, mapId in ipairs(sortedIds(descriptors)) do
    if self.mapLoader:definesMap(mapId) then
      result[#result + 1] = mapId
    end
  end
  return result
end

---@param options table<string, unknown>
---@return FieldResidencyCoordinator
function FieldResidencyCoordinator.new(options)
  assert(type(options) == "table", "field residency coordinator options required")
  assert(options.coverage or options.mapLoader, "field residency coordinator map owner required")
  assert(options.mapLoader and options.actors and options.zoneController, "field residency coordinator owners required")
  return setmetatable({
    coverage = options.coverage,
    mapLoader = options.mapLoader,
    actors = options.actors,
    zoneController = options.zoneController,
    composeMap = options.composeMap or function(runtimeMap)
      return runtimeMap
    end,
    onPreparedMap = options.onPreparedMap,
    residents = {},
    synchronousLogicalFallbackLoads = 0,
    initialized = false,
    disposed = false,
  }, FieldResidencyCoordinator)
end

function FieldResidencyCoordinator:_protect(mapId, protected)
  self.mapLoader:protectMap(mapId, protected)
end

function FieldResidencyCoordinator:_acquireResident(mapId)
  assert(not self.residents[mapId], "logical map is already resident")
  local logicalMap = self.mapLoader:load(mapId)
  local protected = false
  local runtimeMap
  local ok, result = pcall(function()
    self:_protect(mapId, true)
    protected = true
    runtimeMap = self.composeMap(logicalMap, self.coverage)
    if self.onPreparedMap then
      self.onPreparedMap(assert(runtimeMap))
    end
  end)
  if not ok then
    if protected then
      self:_protect(mapId, false)
    end
    error(result, 0)
  end
  self.residents[mapId] = {
    logicalMap = logicalMap,
    runtimeMap = assert(runtimeMap),
  }
end

function FieldResidencyCoordinator:_ensureResident(mapId, countFallback)
  if self.residents[mapId] then
    return
  end
  self:_acquireResident(mapId)
  if countFallback then
    self.synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads + 1
  end
end

function FieldResidencyCoordinator:_committedMapIds(anchorX, anchorZ)
  if not self.coverage then
    return {}
  end
  local descriptors
  if anchorX == nil or anchorZ == nil or type(self.coverage.descriptorsFor) ~= "function" then
    descriptors = self.coverage:committedDescriptors()
  else
    descriptors = self.coverage:descriptorsFor(anchorX, anchorZ)
  end
  if not descriptors then
    descriptors = self.coverage:committedDescriptors()
  end
  return self:_desiredIds(descriptors)
end

function FieldResidencyCoordinator:_prefetchMapIds(anchorX, anchorZ)
  if not self.coverage then
    return {}
  end
  local descriptors
  if type(self.coverage.prefetchDescriptors) == "function" then
    descriptors = self.coverage:prefetchDescriptors(anchorX, anchorZ)
  else
    descriptors = self.coverage:committedDescriptors()
  end
  if not descriptors then
    descriptors = self.coverage:committedDescriptors()
  end
  return self:_desiredIds(descriptors)
end

function FieldResidencyCoordinator:_desiredReadyMapIds(anchorX, anchorZ)
  return self:_prefetchMapIds(anchorX, anchorZ)
end

function FieldResidencyCoordinator:_syncResidentViews()
  for _, resident in pairs(self.residents) do
    if type(resident.runtimeMap.syncPhysicalFields) == "function" then
      resident.runtimeMap:syncPhysicalFields()
    end
  end
end

---@return FieldResidencyCoordinator
function FieldResidencyCoordinator:initialize()
  assert(not self.disposed and not self.initialized, "field residency coordinator is not initializable")
  for _, mapId in ipairs(self:_committedMapIds()) do
    self:_acquireResident(mapId)
  end
  self.initialized = true
  if self.coverage then
    self.coverage:queuePrefetch()
  end
  return self
end

---@return integer
---@param _ integer? legacy caller budget, intentionally ignored
function FieldResidencyCoordinator:updatePrefetch(_)
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  local completed = 0
  if self.coverage then
    completed = self.coverage:updatePrefetch(1)
  end
  for _, mapId in ipairs(self:_prefetchMapIds()) do
    if not self.residents[mapId] then
      if type(self.mapLoader.request) == "function" and not self.mapLoader:request(mapId) then
        return completed
      end
      self:_acquireResident(mapId)
      return completed + 1
    end
  end
  return completed
end

function FieldResidencyCoordinator:_releaseResident(mapId, residents)
  if not residents[mapId] then
    return
  end
  residents[mapId] = nil
  self:_protect(mapId, false)
end

function FieldResidencyCoordinator:_release(mapId)
  self:_releaseResident(mapId, self.residents)
end

---@param mapId integer
---@return RuntimeFieldMap?
function FieldResidencyCoordinator:mapForId(mapId)
  assert(not self.disposed, "field residency coordinator is disposed")
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
  end
  return nil
end

function FieldResidencyCoordinator:mapForPreflight(mapId)
  local resident = self.residents[mapId]
  if resident then
    return resident.runtimeMap
  end
  -- Collision preflight is read-only. If movement outruns logical prefetch,
  -- borrow a map-loader entry without attaching actors or changing active
  -- state; the next committed boundary counts its own fallback.
  local logicalMap = self.mapLoader:load(mapId)
  self.synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads + 1
  return self.composeMap(logicalMap, self.coverage)
end

---@param mapId integer
---@param targetCoverage FieldCoverage?
---@param suppliedRuntimeMap RuntimeFieldMap?
---@return FieldResidencyCoordinator.StagedResident
function FieldResidencyCoordinator:_stageResident(mapId, targetCoverage, suppliedRuntimeMap)
  assert(not self.residents[mapId], "logical map is already resident")
  local logicalMap
  if suppliedRuntimeMap then
    local composedRuntimeMap = suppliedRuntimeMap --[[@as FieldResidencyCoordinator.ComposedRuntimeMap]]
    logicalMap = composedRuntimeMap.logicalMap or suppliedRuntimeMap
  else
    logicalMap = self.mapLoader:load(mapId)
  end
  assert(logicalMap.mapId == mapId, "staged logical map identity mismatch")
  local runtimeMap = suppliedRuntimeMap or self.composeMap(logicalMap, targetCoverage)
  assert(runtimeMap.mapId == mapId, "staged runtime map identity mismatch")
  local protected = false
  local ok, result = pcall(function()
    self:_protect(mapId, true)
    protected = true
    if self.onPreparedMap then
      self.onPreparedMap(runtimeMap)
    end
  end)
  if not ok then
    if protected then
      self:_protect(mapId, false)
    end
    error(result, 0)
  end
  return {
    mapId = mapId,
    resident = {
      logicalMap = logicalMap,
      runtimeMap = assert(runtimeMap),
    },
    protected = protected,
  }
end

---@param staged FieldResidencyCoordinator.StagedResident
function FieldResidencyCoordinator:_discardStagedResident(staged)
  if staged.protected then
    self:_protect(staged.mapId, false)
    staged.protected = false
  end
end

---@param destinationRuntimeMap RuntimeFieldMap
---@param destinationCoverage FieldCoverage?
---@return FieldResidencyCoordinator.Transition
function FieldResidencyCoordinator:prepareTransition(destinationRuntimeMap, destinationCoverage)
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  assert(destinationRuntimeMap and type(destinationRuntimeMap.mapId) == "number", "transition destination map required")
  local destinationMapId = destinationRuntimeMap.mapId
  local targetReadyMapIds
  if destinationCoverage then
    targetReadyMapIds = self:_prefetchMapIdsFrom(destinationCoverage)
  else
    targetReadyMapIds = { destinationMapId }
  end
  local readySet = {}
  for _, mapId in ipairs(targetReadyMapIds) do
    readySet[mapId] = true
  end
  if not readySet[destinationMapId] then
    targetReadyMapIds[#targetReadyMapIds + 1] = destinationMapId
    table.sort(targetReadyMapIds)
  end
  local sourceResidents = {}
  for mapId, resident in pairs(self.residents) do
    sourceResidents[mapId] = resident
  end
  local transaction = {
    coordinator = self,
    sourceCoverage = self.coverage,
    sourceResidents = sourceResidents,
    targetCoverage = destinationCoverage,
    destinationMapId = destinationMapId,
    targetResidents = {},
    staged = {},
    state = "prepared",
  } ---@type FieldResidencyCoordinator.Transition

  local ok, result = pcall(function()
    for _, mapId in ipairs(targetReadyMapIds) do
      local existing = self.residents[mapId]
      if existing then
        local runtimeMap
        if mapId == destinationMapId then
          runtimeMap = destinationRuntimeMap
        else
          runtimeMap = self.composeMap(existing.logicalMap, destinationCoverage)
        end
        assert(runtimeMap.mapId == mapId, "reused runtime map identity mismatch")
        transaction.targetResidents[mapId] = {
          logicalMap = existing.logicalMap,
          runtimeMap = runtimeMap,
        }
      else
        local supplied = mapId == destinationMapId and destinationRuntimeMap or nil
        local staged = self:_stageResident(mapId, destinationCoverage, supplied)
        transaction.staged[#transaction.staged + 1] = staged
        transaction.targetResidents[mapId] = staged.resident
      end
    end
  end)
  if not ok then
    self:discardTransition(transaction)
    error(result, 0)
  end
  return transaction
end

---@param destinationCoverage FieldCoverage
---@return integer[]
function FieldResidencyCoordinator:_prefetchMapIdsFrom(destinationCoverage)
  local descriptors
  if type(destinationCoverage.prefetchDescriptors) == "function" then
    descriptors = destinationCoverage:prefetchDescriptors()
  else
    descriptors = destinationCoverage:committedDescriptors()
  end
  return self:_desiredIds(descriptors)
end

---@param transaction FieldResidencyCoordinator.Transition
function FieldResidencyCoordinator:discardTransition(transaction)
  assert(transaction and transaction.coordinator == self, "foreign field residency transition")
  if transaction.state ~= "prepared" then
    return
  end
  for index = #transaction.staged, 1, -1 do
    self:_discardStagedResident(transaction.staged[index])
  end
  transaction.state = "discarded"
end

---@param transaction FieldResidencyCoordinator.Transition
---@return RuntimeFieldMap
function FieldResidencyCoordinator:commitTransition(transaction)
  assert(transaction and transaction.coordinator == self, "foreign field residency transition")
  assert(transaction.state == "prepared", "field residency transition is not committable")
  assert(self.coverage == transaction.sourceCoverage, "field residency transition source coverage changed")
  for mapId, resident in pairs(transaction.sourceResidents) do
    assert(self.residents[mapId] == resident, "field residency transition residents changed")
  end
  for mapId, resident in pairs(self.residents) do
    assert(transaction.sourceResidents[mapId] == resident, "field residency transition residents changed")
  end

  for _, staged in ipairs(transaction.staged) do
    staged.protected = false
  end
  self.residents = transaction.targetResidents
  self.coverage = transaction.targetCoverage
  for mapId in pairs(transaction.sourceResidents) do
    if not transaction.targetResidents[mapId] then
      self:_releaseResident(mapId, transaction.sourceResidents)
    end
  end
  if self.coverage then
    self.coverage:queuePrefetch()
  end
  transaction.state = "committed"
  return transaction.targetResidents[transaction.destinationMapId].runtimeMap
end

---@param player FieldResidencyPlayer
---@param context table<string, unknown>?
---@return FieldZoneChange|table<string, unknown>
function FieldResidencyCoordinator:afterCommittedMove(player, context)
  assert(not self.disposed and self.initialized, "field residency coordinator is not ready")
  context = context or {}
  local targetX = context.targetX or math.floor(player.fieldX / 32)
  local targetZ = context.targetZ or math.floor(player.fieldZ / 32)
  local required = self:_committedMapIds(targetX, targetZ)
  for _, mapId in ipairs(required) do
    self:_ensureResident(mapId, true)
  end
  local anchorChanged = self.coverage and (self.coverage.anchorX ~= targetX or self.coverage.anchorZ ~= targetZ)
  if anchorChanged then
    self.coverage:recenter(targetX, targetZ)
    if context.onPhysicalCommit then
      context.onPhysicalCommit(self.coverage)
    end
    self:_syncResidentViews()
    self.actors:reconcilePhysicalWorld()
  end
  local zoneCoverage = assert(self.coverage) --[[@as FieldZoneCoverage]]
  local zonePlayer = player --[[@as FieldZonePlayer]]
  local result = self.zoneController:afterCoverageCommit(zoneCoverage, zonePlayer)
  if anchorChanged then
    local requiredSet = {}
    for _, mapId in ipairs(self:_desiredReadyMapIds(targetX, targetZ)) do
      requiredSet[mapId] = true
    end
    local residentIds = {}
    for mapId in pairs(self.residents) do
      residentIds[#residentIds + 1] = mapId
    end
    for _, mapId in ipairs(residentIds) do
      if not requiredSet[mapId] then
        self:_release(mapId)
      end
    end
    self.coverage:queuePrefetch(targetX, targetZ)
  end
  return result or self:status()
end

---@return table<string, unknown>
function FieldResidencyCoordinator:status()
  local residentMapIds = {}
  for mapId in pairs(self.residents) do
    residentMapIds[#residentMapIds + 1] = mapId
  end
  table.sort(residentMapIds)
  return {
    residentMapIds = residentMapIds,
    synchronousLogicalFallbackLoads = self.synchronousLogicalFallbackLoads,
    physical = self.coverage and self.coverage:status() or nil,
  }
end

function FieldResidencyCoordinator:dispose()
  if self.disposed then
    return
  end
  local residentIds = {}
  for mapId in pairs(self.residents) do
    residentIds[#residentIds + 1] = mapId
  end
  for _, mapId in ipairs(residentIds) do
    self:_release(mapId)
  end
  self.disposed = true
end

return FieldResidencyCoordinator
