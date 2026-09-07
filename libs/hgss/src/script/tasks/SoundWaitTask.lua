-- sound_wait task implementation : waits for a sound
-- effect, cry, or fanfare through the audio service's semantic completion
-- state. The wait state carries the semantic wait kind: `wait_sound` holds
-- the resolved effect sequence and polls `isEffectWaitComplete(sequence)`;
-- `wait_cry` polls `isCryFinished`; `wait_fanfare` polls
-- `isFanfarePlaying`. The audio service contract says every poll returns a
-- boolean, never nil: a nil poll result is a programming fault (assert),
-- not a recoverable task error, and the task carries no capability-
-- detection branches for the defined interface. Graph continuation follows
-- the generic one-tick handoff. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local SoundWaitTask = {}

SoundWaitTask.type = "sound_wait"
-- Serialized-state shape: kind + resolved sequence (was token strings).
SoundWaitTask.version = 2

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function SoundWaitTask.create(spec, ctx)
  local node = spec.node or {}
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "the sound wait task requires the audio service",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local kind = "effect"
  if node.op == "wait_cry" then
    kind = "cry"
  elseif node.op == "wait_fanfare" then
    kind = "fanfare"
  end
  if kind == "cry" then
    return { kind = "cry" }
  end
  if kind == "fanfare" then
    return { kind = "fanfare" }
  end
  -- The effect wait carries the resolved sequence: HGSS WaitSE always reads
  -- an explicit operand (scrcmd_sound.c ScrCmd_WaitSE via ScriptGetVar),
  -- the lowering always emits one, and the schema requires it -- an
  -- operand-less wait is not a valid producer shape and faults.
  local sequence = node.sound
  if sequence == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the effect wait has no completion sequence",
      { scriptId = ctx.instance.scriptId }
    )
  end
  sequence = ctx.semantics.evaluateValue(sequence, { services = ctx.services, instance = ctx.instance })
  if sequence == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "the effect wait has no completion sequence",
      { scriptId = ctx.instance.scriptId }
    )
  end
  return {
    kind = "effect",
    sequence = sequence,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function SoundWaitTask.poll(state, ctx)
  local audio = ctx.services.audio
  if audio == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the sound wait task requires the audio service")
  end
  -- LuaLS cannot see through Errors.raise; the nil check above never falls
  -- through, so the service is non-nil from here on. The per-branch casts
  -- name the poll the wait kind uses.
  local done
  if state.kind == "effect" then
    local service = audio --[[@as { isEffectWaitComplete: fun(self: table, sequence: unknown): boolean }]]
    local complete = service:isEffectWaitComplete(state.sequence)
    assert(complete ~= nil, "the audio service must report effect wait completion as a boolean")
    done = complete
  elseif state.kind == "cry" then
    local service = audio --[[@as { isCryFinished: fun(self: table): boolean }]]
    local finished = service:isCryFinished()
    assert(finished ~= nil, "the audio service must report cry completion as a boolean")
    done = finished
  else
    local service = audio --[[@as { isFanfarePlaying: fun(self: table): boolean }]]
    local playing = service:isFanfarePlaying()
    assert(playing ~= nil, "the audio service must report fanfare play state as a boolean")
    done = not playing
  end
  if done then
    return { complete = true, state = state, result = { completed = true } }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
function SoundWaitTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function SoundWaitTask.validate(state)
  if type(state) ~= "table" or state.kind == nil then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sound_wait state must hold its kind", context)
  end
  if state.kind ~= "effect" and state.kind ~= "cry" and state.kind ~= "fanfare" then
    local context = {
      state = state,
    }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sound_wait state holds an unknown kind", context)
  end
  if state.kind == "effect" and state.sequence == nil then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "effect wait state must hold its resolved sequence",
      context
    )
  end
  return nil
end

return SoundWaitTask
