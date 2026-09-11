-- Owns the actor save translation seam while save schema ownership stays in save.

local Errors = require("libs.errors.src.Errors")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")
local ScriptErrors = require("libs.script.src.errors")

---@class FieldActorPersistence
local FieldActorPersistence = {}
FieldActorPersistence.__index = FieldActorPersistence

---@class FieldActorPersistence.RestorePlan
---@field actor FieldActorManager.Actor
---@field record table<string, unknown>
---@field projection FieldActorResolvedPosition
---@field destination FieldActorResolvedPosition?
---@field reservationKey string?

---@return FieldActorPersistence
function FieldActorPersistence.new()
  return setmetatable({}, FieldActorPersistence)
end

---@param actor FieldActorManager.Actor
---@param managerOrder integer
---@param controller table<string, unknown>
---@param action table<string, unknown>?
---@return table<string, unknown>
function FieldActorPersistence:captureActor(actor, managerOrder, controller, action)
  local sourceEvent = assert(actor.sourceEvent, "field actor save requires a source event")
  local fieldPosition = actor:getFieldPosition()
  local record = {
    actorId = actor.actorId,
    mapId = actor.mapId,
    objectEventId = assert(actor.objectEventId),
    sourceMovementType = assert(sourceEvent.movementType),
    movementType = actor.movementType,
    fieldX = fieldPosition.fieldX,
    fieldZ = fieldPosition.fieldZ,
    facing = actor.facing,
    controller = controller,
    managerOrder = managerOrder,
  }
  if actor.cellKey ~= nil and actor:getSourceSurfaceId() ~= nil then
    record.cellKey = actor.cellKey
    record.sourceSurfaceId = actor:getSourceSurfaceId()
  end
  if action ~= nil then
    record.action = action
  end
  return record
end

---@param entries table<integer, FieldActorManager.Entry>
---@param actorsByManagerSlot fun(entry: FieldActorManager.Entry): FieldActorManager.Actor[]
---@param captureController fun(actorId: string): table<string, unknown>
---@param captureAction fun(entry: FieldActorManager.Entry, actor: FieldActorManager.Actor): table<string, unknown>?
---@param captureRng fun(): table<string, unknown>
---@return table<string, unknown>
function FieldActorPersistence:capture(entries, actorsByManagerSlot, captureController, captureAction, captureRng)
  local actors = {}
  local mapIds = {}
  for mapId in pairs(entries) do
    mapIds[#mapIds + 1] = mapId
  end
  table.sort(mapIds)
  for _, mapId in ipairs(mapIds) do
    local entry = assert(entries[mapId])
    for ordinal, actor in ipairs(actorsByManagerSlot(entry)) do
      if actor.sourceEvent and actor.objectEventId ~= nil then
        actors[actor.actorId] =
          self:captureActor(actor, ordinal - 1, captureController(actor.actorId), captureAction(entry, actor))
      end
    end
  end
  return {
    schema = FieldObjectSave.SCHEMA,
    rng = captureRng(),
    actors = actors,
  }
end

---@param snapshot table<string, unknown>?
---@param mapId integer
---@param getActor fun(actorId: string): FieldActorManager.Actor?
---@param projectActor fun(actor: FieldActorManager.Actor, record: table<string, unknown>): FieldActorResolvedPosition
---@param projectDestination fun(actor: FieldActorManager.Actor, point: table<string, unknown>): FieldActorResolvedPosition
---@return { records: string[], plans: table<string, FieldActorPersistence.RestorePlan> }
function FieldActorPersistence:stageRestore(snapshot, mapId, getActor, projectActor, projectDestination)
  if snapshot == nil or snapshot.actors == nil or next(snapshot.actors) == nil then
    return { records = {}, plans = {} }
  end
  local plans = {}
  local records = {}
  for actorId, record in pairs(snapshot.actors) do
    if record.mapId == mapId then
      local actor = getActor(actorId)
      if actor == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
          "saved actor " .. actorId .. " is not present in the loaded field",
          { actorId = actorId }
        )
      end
      actor = assert(actor)
      local sourceEvent = assert(actor.sourceEvent)
      if actor.objectEventId ~= record.objectEventId or sourceEvent.movementType ~= record.sourceMovementType then
        Errors.raise(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "saved actor source definition changed",
          { actorId = actorId }
        )
      end
      plans[actorId] = {
        actor = actor,
        record = record,
        projection = projectActor(actor, record),
      }
      records[#records + 1] = actorId
    end
  end
  table.sort(records, function(left, right)
    return plans[left].record.managerOrder < plans[right].record.managerOrder
  end)
  for _, actorId in ipairs(records) do
    local plan = assert(plans[actorId])
    local action = plan.record.action
    if action then
      if not plan.projection.resident then
        Errors.raise(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "saved autonomous action start is outside physical residency",
          { actorId = actorId }
        )
      end
      if action.start.fieldX ~= plan.record.fieldX or action.start.fieldZ ~= plan.record.fieldZ then
        Errors.raise(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "saved autonomous action start is inconsistent",
          { actorId = actorId }
        )
      end
      plan.destination = projectDestination(plan.actor, action.destination)
    end
  end
  return { records = records, plans = plans }
end

return FieldActorPersistence
