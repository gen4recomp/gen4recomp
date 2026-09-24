-- Executes the ordinary semantic movement profiles for one field actor.
-- Physical legality and presentation remain manager-owned; this module only
-- advances source-shaped controller state and asks its capability to act.

local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")

---@class FieldActorAutonomy
---@field rng table<string, unknown>
---@field profiles table<string, unknown>
---@field states table<string, table<string, unknown>>
local FieldActorAutonomy = {}
FieldActorAutonomy.__index = FieldActorAutonomy

local OPPOSITE = { north = "south", south = "north", west = "east", east = "west" }

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

local function directionIndex(directions, direction)
  for index, candidate in ipairs(directions) do
    if candidate == direction then
      return index
    end
  end
  return 1
end

local function validIndex(value, count)
  return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= count
end

local function wait(rng, profile)
  local choices = assert(profile.waitChoices, "movement profile wait choices are required")
  return choices[rng:nextInt(#choices) + 1]
end

local function playerDirection(state, capability)
  local player = capability.player
  if not state.profile.nearbyPlayerFacing or player == nil then
    return nil
  end
  if state.sourceEvent.type ~= 1 and state.sourceEvent.type ~= 2 then
    return nil
  end
  local radius = state.sourceEvent.param0
  assert(type(radius) == "number", "nearby-player radius is required")
  if math.abs(player.fieldX - state.fieldX) > radius or math.abs(player.fieldZ - state.fieldZ) > radius then
    return nil
  end
  if
    type(player.positionYBand) ~= "number"
    or player.positionYBand % 1 ~= 0
    or type(state.positionYBand) ~= "number"
    or state.positionYBand % 1 ~= 0
    or player.positionYBand ~= state.positionYBand
  then
    return nil
  end

  local candidates = {}
  if player.fieldZ < state.fieldZ then
    candidates.north = true
  elseif player.fieldZ > state.fieldZ then
    candidates.south = true
  end
  if player.fieldX < state.fieldX then
    candidates.west = true
  elseif player.fieldX > state.fieldX then
    candidates.east = true
  end
  for _, direction in ipairs(state.profile.directions or state.profile.sequence or {}) do
    if candidates[direction] then
      return direction
    end
  end
  return nil
end

local function resetState(state, movementType, profile)
  state.movementType = movementType
  state.profile = profile
  state.timer = 0
  state.sequenceIndex = directionIndex(profile.sequence or {}, state.initialFacing)
  state.rotationIndex = directionIndex(profile.sequence or {}, state.initialFacing)
  state.shuttleDirection = state.initialFacing
  state.spinMode = nil
  state.spinIndex = nil
  if profile.kind == "spin" then
    state.spinMode = "clockwise"
    state.spinIndex = directionIndex(assert(profile.clockwiseSequence), state.initialFacing)
    state.timer = assert(profile.spinInterval)
  end
end

---@class FieldActorAutonomyOptions
---@field rng table<string, unknown>
---@field profiles table<string, unknown>|{ require: fun(self: table<string, unknown>, movementType: string): table<string, unknown> }?

---@param opts FieldActorAutonomyOptions
---@return FieldActorAutonomy
function FieldActorAutonomy.new(opts)
  assert(type(opts) == "table" and opts.rng, "field actor autonomy requires an RNG")
  local profiles = opts.profiles or FieldObjectMovement
  assert(type(profiles.require) == "function", "field actor autonomy requires a profile lookup")
  return setmetatable({ rng = opts.rng, profiles = profiles, states = {} }, FieldActorAutonomy)
end

---@param actorId string
---@param movementType string
---@param sourceEvent table<string, unknown>
function FieldActorAutonomy:attach(actorId, movementType, sourceEvent)
  assert(self.states[actorId] == nil, "field actor autonomy is already attached: " .. actorId)
  local profile = self.profiles.require(movementType)
  local state = {
    actorId = actorId,
    movementType = movementType,
    profile = profile,
    sourceEvent = sourceEvent,
    initialFacing = sourceEvent.facingDirection,
    fieldX = sourceEvent.x,
    fieldZ = sourceEvent.z,
    timer = 0,
    sequenceIndex = 1,
    rotationIndex = 1,
    shuttleDirection = sourceEvent.facingDirection,
  }
  resetState(state, movementType, profile)
  self.states[actorId] = state
end

---@param actorId string
function FieldActorAutonomy:detach(actorId)
  self.states[actorId] = nil
end

---@param actorId string
---@param movementType string
---@param defer boolean?
function FieldActorAutonomy:setMovementType(actorId, movementType, defer)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  local profile = self.profiles.require(movementType)
  if defer then
    state.pendingMovementType = movementType
    return
  end
  resetState(state, movementType, profile)
end

function FieldActorAutonomy:applyPendingMovementType(actorId)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  if state.pendingMovementType then
    local movementType = state.pendingMovementType
    state.pendingMovementType = nil
    self:setMovementType(actorId, movementType)
  end
end

---@param actorId string
---@return table<string, unknown>
function FieldActorAutonomy:state(actorId)
  return copy(assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId))
end

---@param actorId string
---@return boolean
function FieldActorAutonomy:isOrdinary(actorId)
  return assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId).profile.kind ~= "special"
end

---@param actorId string
---@return table<string, unknown>
function FieldActorAutonomy:capture(actorId)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  local controller = {
    kind = state.profile.kind,
    timer = state.timer,
    pendingMovementType = state.pendingMovementType,
  }
  if state.profile.kind == "pattern" then
    controller.sequenceIndex = state.sequenceIndex
  elseif state.profile.kind == "rotate" then
    controller.rotationIndex = state.rotationIndex
  elseif state.profile.kind == "shuttle" then
    controller.shuttleDirection = state.shuttleDirection
  elseif state.profile.kind == "spin" then
    controller.spinMode = state.spinMode
    controller.spinIndex = state.spinIndex
  end
  return controller
end

---@param actorId string
---@param movementType string
---@param controller table<string, unknown>
function FieldActorAutonomy:restore(actorId, movementType, controller)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  local profile = self.profiles.require(movementType)
  assert(type(controller) == "table", "field actor autonomy controller is required")
  assert(controller.kind == profile.kind, "field actor autonomy controller kind does not match movement type")
  assert(
    type(controller.timer) == "number" and controller.timer % 1 == 0 and controller.timer >= 0,
    "field actor autonomy timer is invalid"
  )
  resetState(state, movementType, profile)
  state.timer = controller.timer
  state.pendingMovementType = controller.pendingMovementType
  assert(
    state.pendingMovementType == nil or self.profiles.isType == nil or self.profiles.isType(state.pendingMovementType),
    "field actor autonomy pending movement type is invalid"
  )
  if profile.kind == "pattern" then
    local sequence = assert(profile.sequence)
    assert(validIndex(controller.sequenceIndex, #sequence), "field actor autonomy sequence index is invalid")
    state.sequenceIndex = controller.sequenceIndex
  elseif profile.kind == "rotate" then
    local sequence = assert(profile.sequence)
    assert(validIndex(controller.rotationIndex, #sequence), "field actor autonomy rotation index is invalid")
    state.rotationIndex = controller.rotationIndex
  elseif profile.kind == "shuttle" then
    assert(OPPOSITE[controller.shuttleDirection] ~= nil, "field actor autonomy shuttle direction is invalid")
    state.shuttleDirection = controller.shuttleDirection
  elseif profile.kind == "spin" then
    assert(controller.spinMode == "clockwise" or controller.spinMode == "counterclockwise", "spin mode is invalid")
    local sequence = controller.spinMode == "clockwise" and assert(profile.clockwiseSequence)
      or assert(profile.counterclockwiseSequence)
    assert(validIndex(controller.spinIndex, #sequence), "spin index is invalid")
    state.spinMode = controller.spinMode
    state.spinIndex = controller.spinIndex
  else
    state.spinMode = nil
    state.spinIndex = nil
  end
end

---@return table<string, unknown>
function FieldActorAutonomy:captureRng()
  return self.rng:serialize()
end

---@param record table<string, unknown>
function FieldActorAutonomy:restoreRng(record)
  self.rng = ScriptRng.restore(record)
end

local function stepLook(self, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local direction = playerDirection(state, capability)
  if direction == nil then
    local directions = assert(state.profile.directions)
    direction = directions[self.rng:nextInt(#directions) + 1]
  end
  capability:setFacing(state.actorId, direction)
  state.timer = wait(self.rng, state.profile)
end

local function stepWander(self, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local directions = assert(state.profile.directions)
  local direction = directions[self.rng:nextInt(#directions) + 1]
  capability:setFacing(state.actorId, direction)
  capability:walk(state.actorId, direction)
  state.timer = wait(self.rng, state.profile)
end

local function stepRotate(_, state, capability)
  if state.timer > 0 then
    state.timer = state.timer - 1
    return
  end
  local sequence = assert(state.profile.sequence)
  state.rotationIndex = state.rotationIndex % #sequence + 1
  local direction = playerDirection(state, capability) or sequence[state.rotationIndex]
  capability:setFacing(state.actorId, direction)
  state.timer = assert(state.profile.rotationInterval, "rotation interval is required")
end

local function stepPattern(state, capability)
  local sequence = assert(state.profile.sequence)
  local direction = sequence[state.sequenceIndex]
  if capability:patternStep(state.actorId, direction) then
    state.sequenceIndex = state.sequenceIndex % #sequence + 1
  end
end

local function stepShuttle(state, capability)
  local direction = state.shuttleDirection
  capability:setFacing(state.actorId, direction)
  if capability:walk(state.actorId, direction) then
    return
  end
  state.shuttleDirection = OPPOSITE[direction]
  capability:setFacing(state.actorId, state.shuttleDirection)
  capability:walk(state.actorId, state.shuttleDirection)
end

local function stepSpin(state, capability)
  local profile = state.profile
  local interval = assert(profile.spinInterval, "spin interval is required")
  state.timer = state.timer - 1
  if state.timer > 0 then
    return
  end
  state.timer = interval
  local sequence = state.spinMode == "clockwise" and assert(profile.clockwiseSequence)
    or assert(profile.counterclockwiseSequence)
  state.spinIndex = state.spinIndex % #sequence + 1
  local direction = sequence[state.spinIndex]
  capability:setFacing(state.actorId, direction)
  if direction == state.initialFacing then
    state.spinMode = state.spinMode == "clockwise" and "counterclockwise" or "clockwise"
    sequence = state.spinMode == "clockwise" and assert(profile.clockwiseSequence)
      or assert(profile.counterclockwiseSequence)
    state.spinIndex = directionIndex(sequence, direction)
  end
end

---@param actorId string
---@param capability table<string, unknown>
function FieldActorAutonomy:step(actorId, capability)
  local state = assert(self.states[actorId], "field actor autonomy is not attached: " .. actorId)
  state.fieldX = assert(capability.fieldX)
  state.fieldZ = assert(capability.fieldZ)
  state.positionYBand = capability.positionYBand
  if state.profile.kind == "special" then
    return
  elseif state.profile.kind == "stationary" then
    if state.profile.fixedFacing and not capability.facingOverride then
      capability:setFacing(actorId, state.profile.fixedFacing)
    end
  elseif state.profile.kind == "look" then
    stepLook(self, state, capability)
  elseif state.profile.kind == "wander" then
    stepWander(self, state, capability)
  elseif state.profile.kind == "rotate" then
    stepRotate(self, state, capability)
  elseif state.profile.kind == "pattern" then
    stepPattern(state, capability)
  elseif state.profile.kind == "shuttle" then
    stepShuttle(state, capability)
  elseif state.profile.kind == "spin" then
    stepSpin(state, capability)
  else
    error("unsupported field actor autonomy profile kind " .. tostring(state.profile.kind))
  end
end

return FieldActorAutonomy
