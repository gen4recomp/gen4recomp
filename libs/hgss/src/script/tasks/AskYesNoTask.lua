-- ask_yes_no task implementation : opens the
-- yes/no menu on the current message box, polls selection edges (never the
-- same tick the menu becomes eligible), writes the canonical boolean result
-- through the task result, and completes with the generic one-tick
-- continuation handoff. Import adapters convert the canonical true/false
-- back to the original numeric convention when a later variable comparison
-- requires it. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local AskYesNoTask = {}

AskYesNoTask.type = "ask_yes_no"
AskYesNoTask.version = 1

---@param spec table<string, unknown>
---@param _ table<string, unknown>
---@return table<string, unknown> state
function AskYesNoTask.create(spec, _)
  local node = assert(spec.node, "ask_yes_no requires its graph node")
  return {
    message = node.message,
    bindings = node.bindings or {},
    phase = "opening",
    phaseReadyInTicks = 1,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function AskYesNoTask.poll(state, ctx)
  local host = assert(ctx.services.dialogue, "ask_yes_no requires the dialogue host")
  if state.phase == "opening" then
    state.phaseReadyInTicks = state.phaseReadyInTicks - 1
    if state.phaseReadyInTicks <= 0 then
      host:askYesNo(state.message, state.bindings)
      state.phase = "waiting_selection"
      state.phaseReadyInTicks = 1
    end
    return { complete = false, state = state }
  end
  -- waiting_selection: the menu opened; a selection edge cannot be consumed
  -- in the tick the menu becomes eligible.
  state.phaseReadyInTicks = state.phaseReadyInTicks - 1
  if state.phaseReadyInTicks > 0 then
    return { complete = false, state = state }
  end
  local input = ctx.input or {}
  host:handleYesNoInput({
    pressedDirection = input.pressedDirection,
    pressedAction = input.pressedAction,
    pressedCancel = input.pressedCancel,
  })
  local result = host:takeYesNoResult()
  if result == nil then
    state.phaseReadyInTicks = 1
    return { complete = false, state = state }
  end
  host:closeYesNo()
  return {
    complete = true,
    state = state,
    result = result.accepted and 1 or 0,
  }
end

---@param state table<string, unknown>
---@param reason string
function AskYesNoTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function AskYesNoTask.validate(state)
  if type(state) ~= "table" or (state.phase ~= "opening" and state.phase ~= "waiting_selection") then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "ask_yes_no state must hold a known phase", context)
  end
  return nil
end

return AskYesNoTask
