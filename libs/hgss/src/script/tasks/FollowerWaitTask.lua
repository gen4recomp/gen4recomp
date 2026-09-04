-- follower_wait task implementation: the native-style wait behind
-- ScrCmd_WaitFollowingPokemonMovement. The task completes when the one
-- following controller reports settlement (no in-flight presentation and no
-- source-required pending movement); a paused follower settles immediately
-- so the wait never hangs on a paused queue. State is empty and therefore
-- trivially serializable: a save made while waiting resumes polling the
-- reconstructed controller after continue. Pure domain module: no love
-- dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local FollowerWaitTask = {}

FollowerWaitTask.type = "follower_wait"
FollowerWaitTask.version = 1

---@param _ table<string, unknown>
---@return table<string, unknown> state
function FollowerWaitTask.create(_, _)
  return {}
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function FollowerWaitTask.poll(state, ctx)
  local followingMon = ctx.services and ctx.services.followingMon --[[@as FollowingMonController]]
  assert(followingMon and followingMon.isMovementSettled, "follower wait requires the following-mon collaborator")
  if followingMon:isMovementSettled() then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
function FollowerWaitTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function FollowerWaitTask.validate(state)
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "follower wait state must be a table", context)
  end
  return nil
end

return FollowerWaitTask
