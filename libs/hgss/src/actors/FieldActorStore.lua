-- Owns one map entry's actor identity, ordering, lookup indexes, and slots.
-- One store is created for each manager map entry; the manager alone owns map
-- publication and current-map identity. The store also owns the contiguous
-- numeric state buffer: storage slots are physical cdata identities and never
-- alias the reassignable semantic manager slots.

local FieldActorStateBuffer = require("libs.hgss.src.actors.FieldActorStateBuffer")

---@class FieldActorStore
---@field _actors table<string, FieldActorManager.Actor>
---@field _order FieldActorManager.Actor[]
---@field _byFlag table<integer, FieldActorEvent[]>
---@field _byIndex table<integer, string>
---@field _managerSlots table<integer, FieldActorManager.Actor>
---@field _managerSlotByActorId table<string, integer>
---@field _numericState FieldActorStateBuffer
local FieldActorStore = {}
FieldActorStore.__index = FieldActorStore

---@return FieldActorStore
function FieldActorStore.new()
  return setmetatable({
    _actors = {},
    _order = {},
    _byFlag = {},
    _byIndex = {},
    _managerSlots = {},
    _managerSlotByActorId = {},
    _numericState = FieldActorStateBuffer.new(),
  }, FieldActorStore)
end

---@param event FieldActorEvent
function FieldActorStore:indexEvent(event)
  local events = self._byFlag[event.eventFlag]
  if events == nil then
    events = {}
    self._byFlag[event.eventFlag] = events
  end
  events[#events + 1] = event
end

---@param eventFlag integer
---@return FieldActorEvent[]
function FieldActorStore:eventsForFlag(eventFlag)
  local indexed = self._byFlag[eventFlag]
  if indexed == nil then
    return {}
  end
  local events = {}
  for index, event in ipairs(indexed) do
    events[index] = event
  end
  return events
end

---@param actor FieldActorManager.Actor
function FieldActorStore:addActor(actor)
  assert(self._actors[actor.actorId] == nil, "field actor identity is already stored")
  assert(self._byIndex[actor.objectEventId] == nil, "field actor object index is already stored")
  self._actors[actor.actorId] = actor
  self._byIndex[actor.objectEventId] = actor.actorId
  self._order[#self._order + 1] = actor
end

---@param actor FieldActorManager.Actor
function FieldActorStore:removeActor(actor)
  assert(self._actors[actor.actorId] == actor, "field actor identity disagrees on removal")
  self._actors[actor.actorId] = nil
  assert(self._byIndex[actor.objectEventId] == actor.actorId, "field actor index disagrees on removal")
  self._byIndex[actor.objectEventId] = nil
  for index, candidate in ipairs(self._order) do
    if candidate == actor then
      table.remove(self._order, index)
      return
    end
  end
  error("field actor order is missing on removal")
end

---@param actorId string
---@return FieldActorManager.Actor?
function FieldActorStore:getActor(actorId)
  return self._actors[actorId]
end

---@param objectEventId integer
---@return string?
function FieldActorStore:getActorByIndex(objectEventId)
  return self._byIndex[objectEventId]
end

---@return FieldActorManager.Actor[]
function FieldActorStore:orderedActors()
  local result = {}
  for index, actor in ipairs(self._order) do
    result[index] = actor
  end
  return result
end

---@return FieldActorManager.Actor[]
function FieldActorStore:actorsByManagerSlot()
  local actors = {}
  for _, actor in pairs(self._actors) do
    actors[#actors + 1] = actor
  end
  table.sort(actors, function(left, right)
    return self:managerSlot(left) < self:managerSlot(right)
  end)
  return actors
end

---@param actor FieldActorManager.Actor
---@param requestedSlot integer?
---@return integer
function FieldActorStore:assignManagerSlot(actor, requestedSlot)
  assert(self._managerSlotByActorId[actor.actorId] == nil, "actor already has a manager slot")
  local slot = requestedSlot
  if slot == nil then
    slot = 0
    while self._managerSlots[slot] ~= nil do
      slot = slot + 1
    end
  else
    assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0, "requested manager slot is invalid")
    assert(self._managerSlots[slot] == nil, "requested manager slot is occupied")
  end
  self._managerSlots[slot] = actor
  self._managerSlotByActorId[actor.actorId] = slot
  return slot
end

---@param actor FieldActorManager.Actor
---@return integer
function FieldActorStore:managerSlot(actor)
  local slot = self._managerSlotByActorId[actor.actorId]
  assert(slot ~= nil, "actor manager slot is missing for " .. tostring(actor.actorId))
  assert(self._managerSlots[slot] == actor, "actor manager slot forward map disagrees")
  return slot
end

---@param actorId string
---@return boolean
function FieldActorStore:hasManagerSlot(actorId)
  return self._managerSlotByActorId[actorId] ~= nil
end

---@param actor FieldActorManager.Actor
function FieldActorStore:releaseManagerSlot(actor)
  local slot = self._managerSlotByActorId[actor.actorId]
  assert(slot ~= nil, "actor manager slot is missing on release for " .. tostring(actor.actorId))
  assert(self._managerSlots[slot] == actor, "actor manager slot forward map disagrees on release")
  self._managerSlots[slot] = nil
  self._managerSlotByActorId[actor.actorId] = nil
end

---@param assignments table<integer, FieldActorManager.Actor>
function FieldActorStore:replaceManagerSlots(assignments)
  self._managerSlots = {}
  self._managerSlotByActorId = {}
  for slot, actor in pairs(assignments) do
    self:assignManagerSlot(actor, slot)
  end
end

-- Acquires one stable numeric storage slot for an actor entering the store.
-- Slots carry no actor identity of their own.
---@return integer stable zero-based storage slot
function FieldActorStore:allocateNumericState()
  return self._numericState:allocate()
end

---@param slot integer
function FieldActorStore:releaseNumericState(slot)
  self._numericState:release(slot)
end

-- Resolves the live numeric record for a storage slot. The result is valid
-- only for immediate use: buffer growth replaces the backing array.
---@param slot integer
---@return G4FieldActorNumeric
function FieldActorStore:numericState(slot)
  return self._numericState:at(slot)
end

return FieldActorStore
