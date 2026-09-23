-- Script interaction client : the construction
-- point that replaced the pre-script interaction adapter. It resolves an
-- immutable InteractionIntent through the bindings manifest into a trigger
-- descriptor, composes the bound script, and starts it as the foreground
-- root through the scheduler so a newly resolved interaction may execute
-- during its trigger tick. The binding audit at load time guarantees every
-- interactable event is bound, so an unmapped intent reaching this client is
-- a composition fault (the session asserts on it) — there is no fallback.
-- Pure domain module: no love dependency.

---@class ScriptInteractionClient
---@field private _bindings table<string, unknown>
---@field private _compose fun(scriptId: string): table<string, unknown>|nil
---@field private _scheduler Scheduler
---@field private _initLifecycleActive boolean
---@field private _initLifecycleInstanceId string|nil
local ScriptInteractionClient = {}
ScriptInteractionClient.__index = ScriptInteractionClient
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

-- The consume() outcome protocol shared with FieldSession: a consumed intent
-- either started a foreground script, found the field already owned, or was
-- unmapped (a composition fault the session asserts on). The session and
-- every consumer read these constants, never the literal strings.
ScriptInteractionClient.RESULTS = {
  started = "started",
  blocked = "blocked",
  unmapped = "unmapped",
}

---@param opts table<string, unknown>
---@return ScriptInteractionClient
function ScriptInteractionClient.new(opts)
  assert(
    opts and opts.bindings and opts.compose and opts.scheduler,
    "interaction client requires bindings, compose, and scheduler"
  )
  return setmetatable({
    _bindings = opts.bindings,
    _compose = opts.compose,
    _scheduler = opts.scheduler,
    _scriptBankId = opts.scriptBankId,
    _initLifecycleActive = false,
    _initLifecycleInstanceId = nil,
  }, ScriptInteractionClient)
end

---@param target string|integer canonical script identity or zero-based index
---@param tick integer
---@return boolean started
function ScriptInteractionClient:startInitScript(target, tick)
  local scriptId = target
  if type(target) == "number" then
    scriptId = ScriptIdentity.formatVanilla(assert(self._scriptBankId), target)
  end
  assert(type(scriptId) == "string", "map init target identity required")
  if self._scheduler:foregroundEnvironmentId() ~= nil then
    return false
  end
  local composed = self._compose(scriptId)
  if composed == nil then
    error("missing generated map-init script " .. scriptId)
  end
  -- Map initialization never implicitly owns player input; only an explicit
  -- source lock opcode executed by this script can acquire it.
  local instanceId = self._scheduler:startInteraction({ type = "map_init", scriptId = scriptId }, composed, tick, false)
  assert(instanceId ~= nil, "map-init scheduler start did not create an instance")
  self._initLifecycleActive = true
  self._initLifecycleInstanceId = instanceId
  return true
end

-- A map-init lifecycle remains active until its own root completes. The entry
-- controller consumes this boundary after the scheduler has advanced the
-- current tick; cancellation and failure are not readiness.
---@return boolean
function ScriptInteractionClient:isInitLifecycleSettled()
  if not self._initLifecycleActive then
    return true
  end
  local instanceId = assert(self._initLifecycleInstanceId, "active map-init lifecycle instance missing")
  if self._scheduler.isInitLifecycleSettled ~= nil then
    return self._scheduler:isInitLifecycleSettled(instanceId)
  end
  local instance = self._scheduler:instance(instanceId)
  if instance == nil or instance.status ~= "completed" then
    return false
  end
  self._initLifecycleActive = false
  self._initLifecycleInstanceId = nil
  return true
end

function ScriptInteractionClient:setScriptBankId(scriptBankId)
  assert(
    type(scriptBankId) == "number" and scriptBankId >= 0 and scriptBankId % 1 == 0,
    "script bank id must be an integer"
  )
  self._scriptBankId = scriptBankId
end

-- Resolve one intent into a trigger + composed descriptor, or nil when the
-- map event is not bound or the bound script cannot be composed.
---@param intent table<string, unknown> InteractionIntent
---@return table<string, unknown>|nil { trigger, composed }
function ScriptInteractionClient:resolve(intent)
  local hit = self._bindings:resolveIntent(intent, intent.playerFacing)
  if hit == nil then
    return nil
  end
  local composed = self._compose(hit.scriptId)
  if composed == nil then
    return nil
  end
  return { trigger = hit.trigger, composed = composed }
end

-- Consume one interaction intent. Returns the RESULTS.started outcome when a
-- script now owns the field, RESULTS.blocked when a foreground script already
-- owns it, or RESULTS.unmapped when nothing is bound (the session treats that
-- as a composition fault: the binding audit guarantees every interactable
-- event is bound). A started script may execute during this tick.
---@param intent table<string, unknown> InteractionIntent
---@param tick integer
---@return string started|blocked|unmapped
function ScriptInteractionClient:consume(intent, tick)
  if self._scheduler:foregroundEnvironmentId() ~= nil then
    return ScriptInteractionClient.RESULTS.blocked
  end
  local hit = self:resolve(intent)
  if hit == nil then
    return ScriptInteractionClient.RESULTS.unmapped
  end
  -- The root was selected by field/player/world event arbitration: it owns
  -- player input for its whole environment lifetime, with or without an
  -- explicit LOCK_PLAYER/LockAll opcode.
  self._scheduler:startInteraction(hit.trigger, hit.composed, tick, true)
  return ScriptInteractionClient.RESULTS.started
end

return ScriptInteractionClient
