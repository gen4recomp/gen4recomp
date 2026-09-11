-- Script actor world adapter: the script layer's stable view of field actors,
-- backed by an injected actor manager (the concrete NPC implementation is
-- never imported here). The adapter resolves the special `player` actor
-- through the injected player facade and keeps a serializable read-only
-- snapshot contract. The constructor requires the complete manager interface:
-- a missing capability is a construction error, never a silent nil. Missing
-- actors surface as nil from `get`/`exists`; the runtime converts them into
-- attributed errors. Pure domain module: no love dependency.

---@class ScriptActorManager
---@field getActor fun(self: ScriptActorManager, actorId: string): table<string, unknown>|nil
---@field show fun(self: ScriptActorManager, actorId: string)
---@field hide fun(self: ScriptActorManager, actorId: string)
---@field setPosition fun(self: ScriptActorManager, actorId: string, position: table<string, unknown>, options: { scripted: boolean }?)
---@field setFacing fun(self: ScriptActorManager, actorId: string, direction: string)
---@field setMovementType fun(self: ScriptActorManager, actorId: string, movementType: string)
---@field setAnimationPaused fun(self: ScriptActorManager, actorId: string, paused: boolean)
---@field getPosition fun(self: ScriptActorManager, actorId: string): table<string, unknown>
---@field getFacing fun(self: ScriptActorManager, actorId: string): string
---@field numericId fun(self: ScriptActorManager, actorId: string): integer|nil
---@field actorIdForMapIndex fun(self: ScriptActorManager, index: integer): string|nil
---@field cameraTargetId fun(self: ScriptActorManager): string|nil
---@field partnerId fun(self: ScriptActorManager): string|nil
---@field beginScriptedAction fun(self: ScriptActorManager, actorId: string, action: table<string, unknown>)
---@field advanceScriptedAction fun(self: ScriptActorManager, actorId: string, progressTicks: integer, durationTicks: integer)
---@field commitScriptedAction fun(self: ScriptActorManager, actorId: string)
---@field cancelScriptedMovement fun(self: ScriptActorManager, actorId: string)
---@field isScriptedMoving fun(self: ScriptActorManager, actorId: string): boolean
---@field isPausable fun(self: ScriptActorManager, actorId: string): boolean
---@field allPausable fun(self: ScriptActorManager): boolean
---@field syncEventStateChanges fun(self: ScriptActorManager)?
---@field isVisible fun(self: ScriptActorManager, actorId: string): boolean
---@field setPresentationOffset fun(self: ScriptActorManager, actorId: string, offset: { x: number, y: number, z: number })
---@field clearPresentationOffset fun(self: ScriptActorManager, actorId: string)

-- The manager methods the actor world calls; every one must be present.
-- `syncEventStateChanges` is forwarded only when the manager provides it, so
-- lightweight fakes (e.g. binding tests) do not need to stub presence sync.
local REQUIRED_MANAGER_METHODS = {
  "getActor",
  "show",
  "hide",
  "setPosition",
  "setFacing",
  "setMovementType",
  "setAnimationPaused",
  "getPosition",
  "getFacing",
  "numericId",
  "actorIdForMapIndex",
  "cameraTargetId",
  "partnerId",
  "isVisible",
  "setPresentationOffset",
  "clearPresentationOffset",
}

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class ScriptActorWorld
---@field private _manager ScriptActorManager
---@field private _player table<string, unknown> player facade { position, facing, gender, name }
local ScriptActorWorld = {}
ScriptActorWorld.__index = ScriptActorWorld

---@param manager ScriptActorManager
---@param player table<string, unknown> player facade { position, facing, gender, name }
---@return ScriptActorWorld
function ScriptActorWorld.new(manager, player)
  assert(manager and type(manager) == "table", "actor world requires an actor manager")
  for _, method in ipairs(REQUIRED_MANAGER_METHODS) do
    assert(type(manager[method]) == "function", "actor manager must implement " .. method)
  end
  assert(
    player and type(player.position) == "function" and type(player.facing) == "function",
    "actor world requires the player facade (position, facing)"
  )
  return setmetatable({
    _manager = manager,
    _player = player,
  }, ScriptActorWorld)
end

-- The player is a valid script actor only while the facade is live.
---@param actorId string
---@return boolean
function ScriptActorWorld:exists(actorId)
  if actorId == "player" then
    return self._player ~= nil
  end
  return self._manager:getActor(actorId) ~= nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path); nil when the map has no such object.
---@param index integer
---@return string|nil
function ScriptActorWorld:actorIdForMapIndex(index)
  return self._manager:actorIdForMapIndex(index)
end

-- The field camera target actor (pinned HGSS object id 241); nil when the
-- session has no camera target.
---@return string|nil
function ScriptActorWorld:cameraTargetId()
  return self._manager:cameraTargetId()
end

-- The walking partner actor (pinned HGSS object id 253); nil while no
-- Pokémon follows the player.
---@return string|nil
function ScriptActorWorld:partnerId()
  return self._manager:partnerId()
end

-- Serializable read-only snapshot of one actor; nil when
-- the actor is not live.
---@param actorId string
---@return table<string, unknown>|nil
function ScriptActorWorld:snapshot(actorId)
  if actorId == "player" then
    local player = self._player
    if player == nil then
      return nil
    end
    local position = player:position()
    return {
      actorId = "player",
      position = position,
      facing = player:facing(),
      visible = true,
    }
  end
  local actor = self._manager:getActor(actorId)
  if actor == nil then
    return nil
  end
  local position = self._manager:getPosition(actorId)
  local facing = self._manager:getFacing(actorId)
  return {
    actorId = actorId,
    mapId = actor.mapId,
    position = position,
    facing = facing,
    -- Scripted hide_object is transient visibility on the live actor: the
    -- snapshot reports the same state collision sees (hidden actors remain
    -- solid), so the two views never contradict.
    visible = self:isVisible(actorId),
  }
end

function ScriptActorWorld:show(actorId)
  if actorId == "player" then
    return
  end
  self._manager:show(actorId)
end

function ScriptActorWorld:hide(actorId)
  if actorId == "player" then
    return
  end
  self._manager:hide(actorId)
end

-- Every position set reaching the manager through this adapter is
-- script-driven (`ApplyMovement`/`set_object_position`); pinned source never
-- checks inter-object collision during scripted movement, so the manager is
-- told to skip its hard occupancy-conflict check for these calls.
---@param actorId string
---@param position table<string, unknown> { fieldX, fieldZ, worldY? }
function ScriptActorWorld:setPosition(actorId, position)
  if actorId == "player" then
    if self._player.setPosition ~= nil then
      self._player:setPosition(position)
    end
    return
  end
  self._manager:setPosition(actorId, position, { scripted = true })
end

---@param actorId string
---@param direction string
function ScriptActorWorld:setFacing(actorId, direction)
  if actorId == "player" then
    if self._player.turn ~= nil then
      self._player:turn(direction)
    end
    return
  end
  self._manager:setFacing(actorId, direction)
end

---@param actorId string
---@param movementType string
function ScriptActorWorld:setMovementType(actorId, movementType)
  if actorId == "player" then
    return
  end
  self._manager:setMovementType(actorId, movementType)
end

---@param actorId string
---@param paused boolean
function ScriptActorWorld:setAnimationPaused(actorId, paused)
  if actorId == "player" then
    return
  end
  self._manager:setAnimationPaused(actorId, paused)
end

---@param actorId string
---@return table<string, unknown>
function ScriptActorWorld:getPosition(actorId)
  if actorId == "player" then
    assert(self._player, "no player facade for the script actor world")
    return self._player:position()
  end
  local position = self._manager:getPosition(actorId)
  assert(position ~= nil, "actor world position missing for " .. actorId)
  return position
end

---@param actorId string
---@return string
function ScriptActorWorld:getFacing(actorId)
  if actorId == "player" then
    assert(self._player, "no player facade for the script actor world")
    return self._player:facing()
  end
  local facing = self._manager:getFacing(actorId)
  assert(facing ~= nil, "actor world facing missing for " .. actorId)
  return facing
end

function ScriptActorWorld:beginScriptedAction(actorId, action)
  if actorId == "player" then
    assert(self._player.beginScriptedAction, "player facade missing beginScriptedAction")
    self._player:beginScriptedAction(action)
    return
  end
  assert(self._manager.beginScriptedAction, "actor manager missing beginScriptedAction")
  self._manager:beginScriptedAction(actorId, action)
end

function ScriptActorWorld:advanceScriptedAction(actorId, progressTicks, durationTicks)
  if actorId == "player" then
    assert(self._player.advanceScriptedAction, "player facade missing advanceScriptedAction")
    self._player:advanceScriptedAction(progressTicks, durationTicks)
    return
  end
  assert(self._manager.advanceScriptedAction, "actor manager missing advanceScriptedAction")
  self._manager:advanceScriptedAction(actorId, progressTicks, durationTicks)
end

function ScriptActorWorld:commitScriptedAction(actorId)
  if actorId == "player" then
    assert(self._player.commitScriptedAction, "player facade missing commitScriptedAction")
    self._player:commitScriptedAction()
    return
  end
  assert(self._manager.commitScriptedAction, "actor manager missing commitScriptedAction")
  self._manager:commitScriptedAction(actorId)
end

function ScriptActorWorld:cancelScriptedMovement(actorId)
  if actorId == "player" then
    assert(self._player.cancelScriptedMovement, "player facade missing cancelScriptedMovement")
    self._player:cancelScriptedMovement()
    return
  end
  assert(self._manager.cancelScriptedMovement, "actor manager missing cancelScriptedMovement")
  self._manager:cancelScriptedMovement(actorId)
end

function ScriptActorWorld:isScriptedMoving(actorId)
  if actorId == "player" then
    assert(self._player.isScriptedMoving, "player facade missing isScriptedMoving")
    return self._player:isScriptedMoving()
  end
  assert(self._manager.isScriptedMoving, "actor manager missing isScriptedMoving")
  return self._manager:isScriptedMoving(actorId)
end

function ScriptActorWorld:isPausable(actorId)
  assert(type(self._manager.isPausable) == "function", "actor manager pausable query required")
  return self._manager:isPausable(actorId)
end

function ScriptActorWorld:allPausable()
  assert(type(self._manager.allPausable) == "function", "actor manager pausable query required")
  return self._manager:allPausable()
end

function ScriptActorWorld:isVisible(actorId)
  if actorId == "player" then
    return true
  end
  return self._manager:isVisible(actorId)
end

function ScriptActorWorld:syncPresence()
  if self._manager.syncEventStateChanges then
    self._manager:syncEventStateChanges()
  end
end

---@param actorId string
---@param offset { x: number, y: number, z: number }
function ScriptActorWorld:setPresentationOffset(actorId, offset)
  if actorId == "player" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "actor oscillation does not support the player", {
      actor = actorId,
    })
  end
  assert(
    type(offset) == "table" and type(offset.x) == "number" and type(offset.y) == "number" and type(offset.z) == "number",
    "presentation offset requires x,y,z"
  )
  self._manager:setPresentationOffset(actorId, offset)
end

---@param actorId string
function ScriptActorWorld:clearPresentationOffset(actorId)
  if actorId == "player" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "actor oscillation does not support the player", {
      actor = actorId,
    })
  end
  self._manager:clearPresentationOffset(actorId)
end

---@param actorId string
---@return integer|nil
function ScriptActorWorld:id(actorId)
  return self._manager:numericId(actorId)
end

return ScriptActorWorld
