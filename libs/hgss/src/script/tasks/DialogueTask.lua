-- dialogue task implementation : the serialized
-- dialogue state machine behind `say` and blocking `message`. `say` owns
-- the complete print + fresh-input + close lifecycle. A blocking `message`
-- (the unfolded NPCMsg primitive) owns print completion only: it completes
-- once the printer reports done, consumes no input, and leaves the box open
-- for the following `wait_input` / parent `close_message` owners. The mode
-- is fixed at creation from the graph node op. Gendered messages resolve at
-- creation from the player's gender. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local DialogueTask = {}

DialogueTask.type = "dialogue"
-- Serialized-state shape: mode + message/bindings/phase (was modeless full
-- dialogue lifecycle state).
DialogueTask.version = 2

-- Phases: typing, print_complete_delay, input_armed, waiting_input,
-- close_delay, closing. v1 merges waiting_input into
-- input_armed (the host owns the text box; the task owns the wait) and
-- resolves the close in close_delay. Print-only messages never leave typing:
-- they complete on print completion instead of arming input.
local PHASES = {
  typing = true,
  print_complete_delay = true,
  input_armed = true,
  close_delay = true,
}

local MODES = {
  say = true,
  print = true,
}

-- Resolve a gendered message descriptor against the player's gender:
-- male for gender 0, female otherwise.
---@param message unknown
---@param ctx table<string, unknown>
---@return unknown
local function resolveMessage(message, ctx)
  if type(message) == "table" and message.text == "gendered_message" then
    local gender = ctx.services.player:gender()
    return gender == 0 and message.male or message.female
  end
  return message
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function DialogueTask.create(spec, ctx)
  local node = assert(spec.node, "dialogue task requires its graph node")
  local op = node.op
  if op ~= "say" and op ~= "message" then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "dialogue task requires a say or blocking message node",
      { scriptId = ctx.instance.scriptId, op = op }
    )
  end
  local message = resolveMessage(node.message, ctx)
  local host = assert(ctx.services.dialogue, "dialogue task requires the dialogue host")
  local mode = op == "message" and "print" or "say"
  if mode == "print" and host:isOpen() then
    -- Consecutive NPCMsg prints share one window: the new print replaces the
    -- still-open content in the same tick, so no empty-box tick is ever
    -- observable. `say` keeps the strict open-only creation (its fold
    -- guarantees the previous box was closed).
    host:close(true)
  end
  host:openMessage(node)
  -- The instance's buffered text arguments (buffer_text) ride alongside the
  -- node's own bindings so the host can resolve STRVAR slots.
  host:startPrint(message, node.bindings or {}, ctx.instance.textArgs or {})
  return {
    message = message,
    bindings = node.bindings or {},
    mode = mode,
    phase = "typing",
    phaseReadyInTicks = 0,
  }
end

-- Advance one tick of the phase machine; returns a completion record or nil.
-- A print-only message completes on printer completion: no input wait is
-- armed and the host is never closed here.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>|nil
function DialogueTask._advance(state, ctx)
  local host = assert(ctx.services.dialogue, "dialogue task requires the dialogue host")
  local phase = state.phase
  if phase == "typing" then
    local progress = host:printProgress()
    if progress and progress.done then
      if state.mode == "print" then
        return { complete = true, state = state, result = { printed = true } }
      end
      state.phase = "print_complete_delay"
      state.phaseReadyInTicks = 1
    end
    return nil
  end
  if state.mode == "print" then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "print-only dialogue state left its typing phase",
      { phase = phase, taskId = ctx.instance.instanceId }
    )
  end
  if phase == "print_complete_delay" then
    state.phaseReadyInTicks = state.phaseReadyInTicks - 1
    if state.phaseReadyInTicks <= 0 then
      state.phase = "input_armed"
    end
    return nil
  end
  if phase == "input_armed" then
    local input = ctx.input or {}
    local edge = (input.pressedAction or input.pressedCancel) and true or false
    if edge then
      state.phase = "close_delay"
      state.phaseReadyInTicks = 1
    end
    return nil
  end
  if phase == "close_delay" then
    state.phaseReadyInTicks = state.phaseReadyInTicks - 1
    if state.phaseReadyInTicks <= 0 then
      host:close(true)
      return { complete = true, state = state, result = { closed = true } }
    end
    return nil
  end
  Errors.raise(
    ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
    "unknown dialogue phase",
    { phase = phase, taskId = ctx.instance.instanceId }
  )
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function DialogueTask.poll(state, ctx)
  local result = DialogueTask._advance(state, ctx)
  if result ~= nil then
    return result
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function DialogueTask.cancel(state, reason, ctx)
  state.cancelled = reason
  -- The host owns the engine window; leave no box open when the task is
  -- cancelled before its close delay ran.
  if ctx ~= nil and ctx.services ~= nil and ctx.services.dialogue ~= nil and ctx.services.dialogue:isOpen() then
    ctx.services.dialogue:close(false)
  end
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function DialogueTask.validate(state)
  if type(state) ~= "table" or PHASES[state.phase] ~= true or MODES[state.mode] ~= true then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "dialogue state must hold a known mode and phase",
      context
    )
  end
  if state.mode == "print" and state.phase ~= "typing" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "print-only dialogue state never leaves typing", context)
  end
  return nil
end

return DialogueTask
