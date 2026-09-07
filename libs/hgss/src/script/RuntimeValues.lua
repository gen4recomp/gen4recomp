-- Script value, message, condition, actor, and reference evaluation. This
-- pure module owns runtime data resolution independently of graph execution.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local RuntimeValues = {}

local PLAYER_GENDER_MALE = 0
local SPRITE_HERO = 0
local SPRITE_HEROINE = 97

local SEMANTIC_STYLES = {
  sign = "hgss.signpost",
  trainer_tip = "hgss.trainer_tip",
}

---@param appearance string
---@return string|nil
function RuntimeValues.semanticStyleId(appearance)
  return SEMANTIC_STYLES[appearance]
end

-- Write a value reference: locals and vars are writable; args are read-only
-- call data (writing one is an invalid reference). Shared by node handlers
-- and the scheduler's task-result write.
---@param ref unknown
---@param value unknown
---@param run table<string, unknown>
function RuntimeValues.writeRef(ref, value, run)
  if type(ref) ~= "table" or ref.value == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "result reference is not a value",
      { scriptId = run.instance.scriptId, nodeId = run.node.nodeId }
    )
  end
  if ref.value == "local" then
    run.instance.locals[ref.name] = value
    return
  end
  if ref.value == "var" then
    run.services.world:setVar(ref.id, value)
    return
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "cannot write to a " .. ref.value .. " reference",
    { scriptId = run.instance.scriptId, nodeId = run.node.nodeId }
  )
end

-- Evaluate a value reference to a runtime scalar.
---@param v unknown
---@param run table<string, unknown>
---@return unknown
function RuntimeValues.evaluateValue(v, run)
  if type(v) ~= "table" or v.value == nil then
    return v
  end
  local kind = v.value
  if kind == "var" then
    return run.services.world:getVar(v.id)
  elseif kind == "local" then
    local value = run.instance.locals[v.name]
    if value == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unset local " .. v.name,
        { scriptId = run.instance.scriptId, localName = v.name }
      )
    end
    return value
  elseif kind == "arg" then
    local frame = run.instance:topFrame()
    local value = frame and frame.args and frame.args[v.name]
    if value == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unset argument " .. v.name,
        { scriptId = run.instance.scriptId, argName = v.name }
      )
    end
    return value
  elseif kind == "flag_value" then
    local flagId = RuntimeValues.resolveIdOperand(v.flag, run)
    return run.services.world:isFlagSet(flagId) and 1 or 0
  elseif kind == "player_gender_value" then
    return run.services.player:gender()
  elseif kind == "friend_sprite_value" then
    -- The opening friend uses the sprite for the gender opposite the player.
    if run.services.player:gender() ~= PLAYER_GENDER_MALE then
      return SPRITE_HERO
    end
    return SPRITE_HEROINE
  elseif kind == "object_id" then
    local actorId = RuntimeValues.resolveActor(v.ref, run)
    local id = run.services.actors:id(actorId)
    if id == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "actor has no numeric id",
        { scriptId = run.instance.scriptId, actor = tostring(actorId) }
      )
    end
    return id
  elseif kind == "trigger_background_id" then
    local backgroundId = run.instance.trigger and run.instance.trigger.backgroundId
    if backgroundId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "no background trigger context",
        { scriptId = run.instance.scriptId }
      )
    end
    return backgroundId
  elseif kind == "trigger_direction" then
    local playerFacing = run.instance.trigger and run.instance.trigger.playerFacing
    if playerFacing == nil then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "no trigger context", { scriptId = run.instance.scriptId })
    end
    return playerFacing
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "unknown value kind " .. tostring(kind),
    { scriptId = run.instance.scriptId }
  )
  return nil
end

-- Resolve an id_or_var operand to the world id it names. A variable
-- reference names its own variable (the translator emits var refs for
-- var-range operands, e.g. copy_var/set_var, and the source operand IS the
-- variable id); every other form evaluates as before (a direct string or
-- numeric id passes through, local/arg references dereference).
---@param v unknown
---@param run table<string, unknown>
---@return unknown
function RuntimeValues.resolveIdOperand(v, run)
  if type(v) == "table" and v.value == "var" then
    return v.id
  end
  return RuntimeValues.evaluateValue(v, run)
end

-- Resolve a semantic message descriptor before it crosses into a host. This
-- keeps dynamic operands and gender selection in the runtime, while the
-- dialogue/menu hosts retain one concrete-message resolution contract.
---@param message unknown
---@param run table<string, unknown>
---@return unknown
function RuntimeValues.evaluateMessage(message, run)
  if type(message) ~= "table" then
    return message
  end
  if message.value ~= nil then
    return RuntimeValues.evaluateValue(message, run)
  end
  if message.message == "external" then
    return {
      message = "external",
      bank = RuntimeValues.evaluateValue(message.bank, run),
      id = RuntimeValues.evaluateValue(message.id, run),
    }
  end
  if message.text == "gendered_message" then
    local gender = run.services.player:gender()
    return RuntimeValues.evaluateMessage(gender == 0 and message.male or message.female, run)
  end
  Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unknown message reference form", { message = message })
  return nil
end

-- Evaluate a condition to a boolean.
---@param condition unknown
---@param run table<string, unknown>
---@return boolean
function RuntimeValues.evaluateCondition(condition, run)
  if type(condition) ~= "table" or condition.condition == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "expected a condition descriptor",
      { scriptId = run.instance.scriptId }
    )
  end
  local kind = condition.condition
  if kind == "compare" then
    local left = RuntimeValues.evaluateValue(condition.left, run)
    local right = RuntimeValues.evaluateValue(condition.right, run)
    local op = condition.operator
    if op == "eq" then
      return left == right
    end
    if op == "ne" then
      return left ~= right
    end
    if type(left) ~= type(right) then
      return false
    end
    if op == "lt" then
      return left < right
    end
    if op == "le" then
      return left <= right
    end
    if op == "gt" then
      return left > right
    end
    if op == "ge" then
      return left >= right
    end
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "unknown compare operator " .. tostring(op),
      { scriptId = run.instance.scriptId }
    )
  elseif kind == "flag" then
    local flagId = RuntimeValues.resolveIdOperand(condition.id, run)
    return run.services.world:isFlagSet(flagId) == condition.expected
  elseif kind == "not" then
    return not RuntimeValues.evaluateCondition(condition.operand, run)
  elseif kind == "all" then
    for _, sub in ipairs(condition.conditions) do
      if not RuntimeValues.evaluateCondition(sub, run) then
        return false
      end
    end
    return true
  elseif kind == "any" then
    for _, sub in ipairs(condition.conditions) do
      if RuntimeValues.evaluateCondition(sub, run) then
        return true
      end
    end
    return false
  elseif kind == "actor_exists" then
    return RuntimeValues.actorExists(condition.ref, run)
  elseif kind == "truthy" then
    local value = RuntimeValues.evaluateValue(condition.value, run)
    return value ~= false and value ~= nil
  end
  Errors.raise(
    ScriptErrors.SCRIPT_INVALID_REFERENCE,
    "unknown condition kind " .. tostring(kind),
    { scriptId = run.instance.scriptId }
  )
  return false
end

-- Resolve an actor reference to a concrete actor id. Special references
-- resolve through the trigger context and the actor world adapter.
---@param ref unknown
---@param run table<string, unknown>
---@return string
function RuntimeValues.resolveActor(ref, run)
  if type(ref) == "string" then
    return ref
  end
  if ref.ref ~= "actor" then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "expected an actor reference",
      { scriptId = run.instance.scriptId }
    )
  end
  if ref.mapIndex ~= nil then
    -- A numeric local map-object index: resolve against the current map
    -- through the actor adapter (the pinned
    -- MapObjectManager_GetFirstActiveObjectByID path). The actor world
    -- contract requires actorIdForMapIndex.
    local actorId = run.services.actors:actorIdForMapIndex(ref.mapIndex)
    if actorId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "map object index " .. tostring(ref.mapIndex) .. " does not resolve in the current map",
        { scriptId = run.instance.scriptId, mapIndex = ref.mapIndex }
      )
    end
    return actorId --[[@as string]]
  end
  if ref.special ~= nil then
    local trigger = run.instance.trigger
    local actorId
    if ref.special == "player" then
      actorId = "player"
    elseif ref.special == "self" then
      actorId = trigger and trigger.selfActor or nil
    elseif ref.special == "last_talked" then
      actorId = trigger and trigger.selfActor or nil
    elseif ref.special == "partner" then
      actorId = run.services.actors:partnerId()
    elseif ref.special == "camera_target" then
      actorId = run.services.actors:cameraTargetId()
    end
    if actorId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
        "actor special " .. ref.special .. " has no target in the trigger context",
        { scriptId = run.instance.scriptId, special = ref.special }
      )
    end
    return actorId
  end
  return ref.id
end

-- Resolve and require a live actor; missing actors are attributed errors.
---@param ref unknown
---@param run table<string, unknown>
---@return string actorId
function RuntimeValues.requireActor(ref, run)
  local actorId = RuntimeValues.resolveActor(ref, run)
  if not run.services.actors:exists(actorId) then
    Errors.raise(
      ScriptErrors.SCRIPT_ACTOR_NOT_FOUND,
      "no live actor " .. tostring(actorId),
      { scriptId = run.instance.scriptId, actor = tostring(actorId) }
    )
  end
  return actorId
end

---@param ref unknown
---@param run table<string, unknown>
---@return boolean
function RuntimeValues.actorExists(ref, run)
  local actorId = RuntimeValues.resolveActor(ref, run)
  return run.services.actors:exists(actorId)
end

return RuntimeValues
