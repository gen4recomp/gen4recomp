-- Script task record : the scheduler-owned lifecycle of a
-- serializable native-style wait. Creation invariants are
-- enforced here: a task never polls in its creation tick (`pollAtTick >=
-- createdAtTick + 1`), a task polls at most once per tick, and completed or
-- cancelled tasks are never polled. A completed task is retained until its
-- owner consumes the result on a later tick, so the completed-but-unconsumed
-- interval is serializable. The task implementation (registered in the task
-- registry) owns only the opaque `state`; the record owns all scheduling
-- fields. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class ScriptTask
---@field taskId string
---@field taskType string
---@field taskVersion integer
---@field ownerInstanceId string
---@field environmentId string
---@field createdAtTick integer
---@field pollAtTick integer
---@field lastPolledTick integer|nil
---@field completedAtTick integer|nil
---@field status string active|completed|cancelled
---@field result unknown
---@field state unknown
local ScriptTask = {}
ScriptTask.__index = ScriptTask

ScriptTask.SCHEMA_NAME = "g4-script-task-v1"

local STATUSES = { active = true, completed = true, cancelled = true }

---@class ScriptTask.CreateSpec
---@field taskId string
---@field taskType string
---@field taskVersion integer
---@field ownerInstanceId string
---@field environmentId string
---@field createdAtTick integer
---@field pollAtTick integer
---@field state unknown

-- Build a task record, enforcing the creation invariants of ScriptTask:
-- a task never polls in its creation tick, polls at most once per tick, and
-- is never polled after completion or cancellation.
---@param spec ScriptTask.CreateSpec
---@return ScriptTask
function ScriptTask.new(spec)
  assert(spec and spec.taskId and spec.taskType, "task identity required")
  assert(spec.ownerInstanceId and spec.environmentId, "task ownership required")
  assert(spec.createdAtTick ~= nil and spec.pollAtTick ~= nil, "task timing required")
  assert(spec.pollAtTick >= spec.createdAtTick + 1, "a task never polls in its creation tick")
  assert(type(spec.taskVersion) == "number", "task version required")
  return setmetatable({
    taskId = spec.taskId,
    taskType = spec.taskType,
    taskVersion = spec.taskVersion,
    ownerInstanceId = spec.ownerInstanceId,
    environmentId = spec.environmentId,
    createdAtTick = spec.createdAtTick,
    pollAtTick = spec.pollAtTick,
    lastPolledTick = nil,
    completedAtTick = nil,
    status = "active",
    result = nil,
    state = spec.state,
  }, ScriptTask)
end

-- True when the task is eligible for its one poll in the given tick.
---@param tick integer
---@return boolean
function ScriptTask:isPollEligible(tick)
  return self.status == "active" and self.pollAtTick <= tick
end

-- Mark the task as completing in the given tick. The owner consumes the
-- result on a later tick; the record is retained until then.
---@param tick integer
---@param result unknown
function ScriptTask:complete(tick, result)
  assert(self.status == "active", "only active tasks may complete")
  assert(tick >= self.pollAtTick, "a task cannot complete before its poll tick")
  self.status = "completed"
  self.completedAtTick = tick
  self.result = result
end

-- Cancel the task; cancelled tasks are never polled again.
-- The implementation state is preserved: the scheduler invokes the
-- implementation's own `cancel(state, reason)` before this record is marked.
---@param reason string
function ScriptTask:cancel(reason)
  assert(self.status == "active" or self.status == "completed", "a cancelled task is not cancelled twice")
  self.status = "cancelled"
  self.cancelledReason = reason
end

-- Mark the record consumed by its owner's continuation: a completed task is
-- retained until its owner consumes the result. Consumed
-- records leave the serializable task set.
function ScriptTask:markConsumed()
  self.consumed = true
end

-- Deterministic serialization for the save schema : absolute
-- runtime ticks are diagnostics; the poll deadline and creation tick become
-- relative delays rebased at capture time `captureTick`.
---@param captureTick integer
---@return table<string, unknown>
function ScriptTask:capture(captureTick)
  assert(captureTick ~= nil, "capture tick required")
  return {
    taskId = self.taskId,
    taskType = self.taskType,
    taskVersion = self.taskVersion,
    ownerInstanceId = self.ownerInstanceId,
    environmentId = self.environmentId,
    createdAtTick = self.createdAtTick,
    createdAtInTicks = self.createdAtTick - captureTick,
    pollInTicks = math.max(0, self.pollAtTick - captureTick),
    lastPolledTick = self.lastPolledTick,
    completedAtTick = self.completedAtTick,
    status = self.status,
    result = self.result,
    state = self.state,
  }
end

-- Restore a record from the save schema. `restoreTick` is the load tick; the
-- poll deadline and creation tick are rebased from the relative delays.
---@param record table<string, unknown>
---@param restoreTick integer
---@return ScriptTask
function ScriptTask.restore(record, restoreTick)
  assert(record and record.taskId and record.taskType, "task record required")
  assert(STATUSES[record.status] ~= nil, "unknown task status " .. tostring(record.status))
  local task = ScriptTask.new({
    taskId = record.taskId,
    taskType = record.taskType,
    taskVersion = record.taskVersion,
    ownerInstanceId = record.ownerInstanceId,
    environmentId = record.environmentId,
    createdAtTick = restoreTick + (record.createdAtInTicks or 0),
    pollAtTick = restoreTick + (record.pollInTicks or 0),
    state = record.state,
  })
  task.lastPolledTick = record.lastPolledTick
  task.completedAtTick = record.completedAtTick
  task.status = record.status
  task.result = record.result
  return task
end

-- The task implementation is responsible for validating its own state on
-- restore; the record validates the scheduling envelope.
---@param record table<string, unknown>
---@return Errors.Error|nil
function ScriptTask.validateRecord(record)
  if type(record) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task record must be a table", {})
  end
  if type(record.taskId) ~= "string" or record.taskId == "" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task id missing", { taskId = record.taskId })
  end
  if type(record.taskType) ~= "string" or record.taskType == "" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task type missing", { taskId = record.taskId })
  end
  if type(record.ownerInstanceId) ~= "string" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task owner missing", { taskId = record.taskId })
  end
  if type(record.environmentId) ~= "string" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "task environment missing", { taskId = record.taskId })
  end
  if STATUSES[record.status] == nil then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "task status unknown",
      { taskId = record.taskId, status = record.status }
    )
  end
  if type(record.pollInTicks) ~= "number" or record.pollInTicks < 0 then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "task poll delay invalid",
      { taskId = record.taskId, pollInTicks = record.pollInTicks }
    )
  end
  if record.createdAtInTicks ~= nil and type(record.createdAtInTicks) ~= "number" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "task creation offset invalid",
      { taskId = record.taskId, createdAtInTicks = record.createdAtInTicks }
    )
  end
  return nil
end

return ScriptTask
