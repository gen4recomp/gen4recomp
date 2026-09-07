-- Validates the versioned HGSS field-object save bucket.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

local FieldObjectSave = {}
FieldObjectSave.SCHEMA = "g4-field-objects-v1"

local FACINGS = { north = true, south = true, west = true, east = true }
local DIRECTIONS = FACINGS
local ROOT_FIELDS = { schema = true, rng = true, actors = true }
local ACTOR_FIELDS = {
  actorId = true,
  mapId = true,
  objectEventId = true,
  sourceMovementType = true,
  movementType = true,
  fieldX = true,
  fieldZ = true,
  cellKey = true,
  sourceSurfaceId = true,
  facing = true,
  controller = true,
  action = true,
  managerOrder = true,
}
local CONTROLLER_FIELDS = {
  kind = true,
  timer = true,
  sequenceIndex = true,
  rotationIndex = true,
  shuttleDirection = true,
  pendingMovementType = true,
  spinMode = true,
  spinIndex = true,
}
local ACTION_FIELDS = {
  owner = true,
  kind = true,
  direction = true,
  start = true,
  destination = true,
  progressTicks = true,
}
local POINT_FIELDS = { fieldX = true, fieldZ = true, cellKey = true, sourceSurfaceId = true }
local AUTONOMOUS_STEP_TICKS = assert(MovementCalibration.SPEED_TICKS.normal)

local function fail(message, context)
  return nil, Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context or {})
end

local function integer(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function fields(value, allowed, name)
  if type(value) ~= "table" then
    return fail(name .. " must be a table")
  end
  for key in pairs(value) do
    if not allowed[key] then
      return fail(name .. " contains an unknown field", { field = key })
    end
  end
  return true
end

local function validatePoint(point, name)
  local ok, err = fields(point, POINT_FIELDS, name)
  if not ok then
    return nil, err
  end
  if not integer(point.fieldX) or not integer(point.fieldZ) then
    return fail(name .. " coordinates must be integers")
  end
  if point.cellKey == nil or point.sourceSurfaceId == nil then
    return fail(name .. " source surface identity is required")
  end
  if type(point.cellKey) ~= "string" or point.cellKey == "" then
    return fail(name .. " cell key is invalid")
  end
  if not integer(point.sourceSurfaceId) or point.sourceSurfaceId < 0 then
    return fail(name .. " source surface id is invalid")
  end
  return copy(point)
end

local function validateIndex(value, count, name)
  if not integer(value) or value < 1 or value > count then
    return fail(name .. " is invalid")
  end
  return true
end

local function rejectField(controller, key, name)
  if controller[key] ~= nil then
    return fail(name .. " contains an irrelevant " .. key)
  end
  return true
end

local function validateController(controller, movementType, hasAction)
  local ok, err = fields(controller, CONTROLLER_FIELDS, "controller")
  if not ok then
    return nil, err
  end
  if type(controller.kind) ~= "string" or controller.kind == "" then
    return fail("controller kind is required")
  end
  local profile = FieldObjectMovement.require(movementType)
  if controller.kind ~= profile.kind then
    return fail("controller kind does not match movement type")
  end
  if not integer(controller.timer) or controller.timer < 0 then
    return fail("controller timer is invalid")
  end
  local kind = profile.kind
  if kind == "pattern" then
    if controller.sequenceIndex == nil then
      return fail("controller sequence index is required")
    end
    local indexOk, indexErr =
      validateIndex(controller.sequenceIndex, #assert(profile.sequence), "controller sequence index")
    if not indexOk then
      return nil, indexErr
    end
    for _, key in ipairs({ "rotationIndex", "shuttleDirection", "spinMode", "spinIndex" }) do
      local fieldOk, fieldErr = rejectField(controller, key, "controller")
      if not fieldOk then
        return nil, fieldErr
      end
    end
  elseif kind == "rotate" then
    if controller.rotationIndex == nil then
      return fail("controller rotation index is required")
    end
    local indexOk, indexErr =
      validateIndex(controller.rotationIndex, #assert(profile.sequence), "controller rotation index")
    if not indexOk then
      return nil, indexErr
    end
    for _, key in ipairs({ "sequenceIndex", "shuttleDirection", "spinMode", "spinIndex" }) do
      local fieldOk, fieldErr = rejectField(controller, key, "controller")
      if not fieldOk then
        return nil, fieldErr
      end
    end
  elseif kind == "spin" then
    if controller.spinMode ~= "clockwise" and controller.spinMode ~= "counterclockwise" then
      return fail("controller spin mode is invalid")
    end
    if controller.spinIndex == nil then
      return fail("controller spin index is required")
    end
    local sequence = controller.spinMode == "clockwise" and assert(profile.clockwiseSequence)
      or assert(profile.counterclockwiseSequence)
    local indexOk, indexErr = validateIndex(controller.spinIndex, #sequence, "controller spin index")
    if not indexOk then
      return nil, indexErr
    end
    for _, key in ipairs({ "sequenceIndex", "rotationIndex", "shuttleDirection" }) do
      local fieldOk, fieldErr = rejectField(controller, key, "controller")
      if not fieldOk then
        return nil, fieldErr
      end
    end
  elseif kind == "shuttle" then
    if not DIRECTIONS[controller.shuttleDirection] then
      return fail("controller shuttle direction is invalid")
    end
    for _, key in ipairs({ "sequenceIndex", "rotationIndex", "spinMode", "spinIndex" }) do
      local fieldOk, fieldErr = rejectField(controller, key, "controller")
      if not fieldOk then
        return nil, fieldErr
      end
    end
  else
    for _, key in ipairs({ "sequenceIndex", "rotationIndex", "shuttleDirection", "spinMode", "spinIndex" }) do
      local fieldOk, fieldErr = rejectField(controller, key, "controller")
      if not fieldOk then
        return nil, fieldErr
      end
    end
  end
  if controller.pendingMovementType ~= nil and not FieldObjectMovement.isType(controller.pendingMovementType) then
    return fail("controller pending movement type is invalid")
  end
  if controller.pendingMovementType ~= nil and not hasAction then
    return fail("controller pending movement type requires an active action")
  end
  return copy(controller)
end

local function validateAction(action)
  local ok, err = fields(action, ACTION_FIELDS, "action")
  if not ok then
    return nil, err
  end
  if action.direction == nil or not DIRECTIONS[action.direction] then
    return fail("action direction is invalid")
  end
  if action.owner ~= "autonomous" then
    return fail("action owner is invalid")
  end
  if action.kind ~= "walk" then
    return fail("action kind is invalid")
  end
  local start, startErr = validatePoint(action.start, "action start")
  if not start then
    return nil, startErr
  end
  local destination, destinationErr = validatePoint(action.destination, "action destination")
  if not destination then
    return nil, destinationErr
  end
  if not integer(action.progressTicks) or action.progressTicks < 0 or action.progressTicks >= AUTONOMOUS_STEP_TICKS then
    return fail("action progress is invalid")
  end
  return {
    owner = action.owner,
    kind = action.kind,
    direction = action.direction,
    start = start,
    destination = destination,
    progressTicks = action.progressTicks,
  }
end

local function validateActor(actor, key)
  local ok, err = fields(actor, ACTOR_FIELDS, "actor")
  if not ok then
    return nil, err
  end
  if type(key) ~= "string" or key == "" or actor.actorId ~= key then
    return fail("actor identity does not match its key", { actorId = key })
  end
  if not integer(actor.mapId) or not integer(actor.objectEventId) or actor.mapId < 0 or actor.objectEventId < 0 then
    return fail("actor source identity is invalid")
  end
  for _, movementType in ipairs({ "sourceMovementType", "movementType" }) do
    if not FieldObjectMovement.isType(actor[movementType]) then
      return fail("actor " .. movementType .. " is invalid")
    end
  end
  if not integer(actor.fieldX) or not integer(actor.fieldZ) then
    return fail("actor coordinates must be integers")
  end
  if not FACINGS[actor.facing] then
    return fail("actor facing is invalid")
  end
  if not integer(actor.managerOrder) or actor.managerOrder < 0 then
    return fail("actor manager order is invalid")
  end
  local hasCell = actor.cellKey ~= nil
  local hasSurface = actor.sourceSurfaceId ~= nil
  if hasCell ~= hasSurface then
    return fail("actor cell key and source surface id must be present together")
  end
  if hasCell then
    if type(actor.cellKey) ~= "string" or actor.cellKey == "" then
      return fail("actor cell key is invalid")
    end
    if not integer(actor.sourceSurfaceId) or actor.sourceSurfaceId < 0 then
      return fail("actor source surface id is invalid")
    end
  end
  local controller, controllerErr = validateController(actor.controller, actor.movementType, actor.action ~= nil)
  if not controller then
    return nil, controllerErr
  end
  local action
  if actor.action ~= nil then
    local actionErr
    action, actionErr = validateAction(actor.action)
    if not action then
      return nil, actionErr
    end
    if not hasCell then
      return fail("active autonomous action requires actor source surface identity")
    end
    if action.start.fieldX ~= actor.fieldX or action.start.fieldZ ~= actor.fieldZ then
      return fail("action start does not match actor position")
    end
    if action.start.cellKey ~= actor.cellKey or action.start.sourceSurfaceId ~= actor.sourceSurfaceId then
      return fail("action start does not match actor source surface identity")
    end
  end
  local result = copy(actor)
  result.controller = controller
  result.action = action
  return result
end

---@param record unknown
---@return table<string, unknown>|nil, Errors.Error?
function FieldObjectSave.validate(record)
  if type(record) ~= "table" then
    return fail("field object save bucket must be a table")
  end
  if next(record) == nil then
    return {}
  end
  local ok, err = fields(record, ROOT_FIELDS, "field object save bucket")
  if not ok then
    return nil, err
  end
  if record.schema ~= FieldObjectSave.SCHEMA then
    return fail("unsupported field object save schema")
  end
  local rng, rngErr = ScriptRng.validate(record.rng)
  if not rng then
    return nil, rngErr
  end
  if type(record.actors) ~= "table" then
    return fail("field object actors must be a table")
  end
  local actors = {}
  local ordersByMap = {}
  for key, value in pairs(record.actors) do
    local validated, actorErr = validateActor(value, key)
    if not validated then
      return nil, actorErr
    end
    actors[key] = validated
    local mapId = validated.mapId
    local order = validated.managerOrder
    local byMap = ordersByMap[mapId]
    if not byMap then
      byMap = {}
      ordersByMap[mapId] = byMap
    end
    if byMap[order] then
      return fail("actor manager order duplicates in map " .. tostring(mapId), { mapId = mapId, managerOrder = order })
    end
    byMap[order] = true
  end
  for mapId, byMap in pairs(ordersByMap) do
    local count = 0
    for _ in pairs(byMap) do
      count = count + 1
    end
    for order = 0, count - 1 do
      if not byMap[order] then
        return fail("actor manager order gap in map " .. tostring(mapId), { mapId = mapId, managerOrder = order })
      end
    end
  end
  return { schema = FieldObjectSave.SCHEMA, rng = rng, actors = actors }
end

return FieldObjectSave
