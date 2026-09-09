-- movement_pause task implementation: the native-style pause wait behind
-- `lock_all` (all actors) and `lock_actor(waitUntilPausable)` (one actor).
-- The task completes when every movement task of the watched generation (or
-- the scoped actor's movement task) is at a pausable boundary: completed or
-- between the ticks of a plan action (an action is mid-tick while
-- `progressTicks > 0`). An actor with no outstanding movement is already
-- pausable. Graph continuation follows the generic one-tick handoff. Pure
-- domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local MovementPauseTask = {}

MovementPauseTask.type = "movement_pause"
MovementPauseTask.version = 1

-- The actor-scoped registration alias of this implementation: `actor_pause`
-- (lock_actor waitUntilPausable) shares the movement-pause task, scoped to
-- one actor, and is registered and created under this name.
MovementPauseTask.actorType = "actor_pause"

-- True when one movement task's state is at a pausable boundary: completed,
-- or no plan action is mid-tick.
---@param state table<string, unknown>
---@return boolean
function MovementPauseTask.atBoundary(state)
  return state.completed == true or (state.progressTicks or 0) == 0
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function MovementPauseTask.create(spec, ctx)
  return {
    paused = false,
    actor = spec.actor, -- nil watches the whole current generation
    generation = ctx.environment:currentGeneration(),
  }
end

-- The watched movement task ids: the scoped actor's task, or every task of
-- the watched generation.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return string[]
local function watchedTaskIds(state, ctx)
  if state.actor ~= nil then
    local taskId = ctx.scheduler:activeMovementForActor(ctx.environment.environmentId, state.actor)
    if taskId == nil then
      return {}
    end
    return { taskId }
  end
  return ctx.environment:movementTasksInGeneration(state.generation)
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MovementPauseTask.poll(state, ctx)
  local ids = watchedTaskIds(state, ctx)
  for _, taskId in ipairs(ids) do
    local task = ctx.scheduler:taskById(taskId)
    if task ~= nil and task.status == "active" then
      if not MovementPauseTask.atBoundary(task.state) then
        return { complete = false, state = state }
      end
    end
  end
  assert(ctx.services and ctx.services.actors, "movement pause actor service required")
  local actors = ctx.services.actors
  local pausable
  if state.actor ~= nil then
    assert(type(actors.isPausable) == "function", "movement pause actor query required")
    pausable = actors:isPausable(state.actor)
  else
    assert(type(actors.allPausable) == "function", "movement pause actor query required")
    pausable = actors:allPausable()
  end
  if not pausable then
    return { complete = false, state = state }
  end
  if state.actor == nil then
    local followingMon = ctx.services.followingMon
    if followingMon ~= nil and not followingMon:isMovementSettled() then
      return { complete = false, state = state }
    end
  end
  return { complete = true, state = state, result = { paused = true } }
end

---@param state table<string, unknown>
---@param reason string
function MovementPauseTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function MovementPauseTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "movement pause state must be a table",
      { state = state }
    )
  end
  return nil
end

return MovementPauseTask
