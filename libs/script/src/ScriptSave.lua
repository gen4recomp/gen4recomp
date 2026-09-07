-- Script save and resume : the serializable `scripts`
-- bucket of the g4-field-save-v4 schema. Capture happens only at a fixed-tick
-- phase boundary (no context in `running` status); absolute scheduling ticks
-- become relative delays rebased at restore, so no tick is duplicated or
-- skipped. The bucket carries the registry fingerprint, the task-registry
-- fingerprint, and the id counters; restore rejects a fingerprint mismatch
-- (SCRIPT_REGISTRY_FINGERPRINT_MISMATCH) and the scheduler reattaches every
-- frame's graph through current compositions, rejecting unknown revisions
-- (SCRIPT_SAVE_REVISION_MISMATCH). Validation is the complete load
-- boundary: the whole bucket and every cross-record reference are checked
-- before any live scheduler state is constructed, and restore stages every
-- object and installs only after the entire bucket has restored. Input
-- edges are never serialized. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptTask = require("libs.script.src.ScriptTask")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")
local ScriptInstance = require("libs.script.src.ScriptInstance")

local ScriptSave = {}

ScriptSave.SCHEMA_NAME = "g4-script-save-v1"

---@param scheduler Scheduler
---@param tick integer
---@param opts table<string, unknown>
---@return table<string, unknown> bucket
function ScriptSave.capture(scheduler, tick, opts)
  assert(opts and type(opts.registryFingerprint) == "string", "registry fingerprint required for capture")
  for _, instance in ipairs(scheduler:liveInstances()) do
    assert(
      instance.status ~= ScriptInstance.STATUSES.running,
      "capture requires a fixed-tick phase boundary (no running context)"
    )
  end
  local environments = {}
  for _, environment in ipairs(scheduler:environments()) do
    environments[#environments + 1] = environment:capture(tick)
  end
  local instances = {}
  for _, instance in ipairs(scheduler:liveInstances()) do
    instances[#instances + 1] = instance:capture(tick)
  end
  local tasks = {}
  for _, task in ipairs(scheduler:tasks()) do
    tasks[#tasks + 1] = task:capture(tick)
  end
  local counters = scheduler:counters()
  return {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = opts.registryFingerprint,
    taskFingerprint = scheduler:taskRegistryFingerprint(),
    capturedAtSimulationTick = tick,
    nextEnvironmentId = counters.nextEnvironmentId,
    nextInstanceId = counters.nextInstanceId,
    nextTaskId = counters.nextTaskId,
    environments = environments,
    instances = instances,
    tasks = tasks,
  }
end

local ENVIRONMENT_MODES = { foreground = true, background = true }
local INSTANCE_MODES = { foreground = true, background = true }

---@param message string
---@param context table<string, unknown>
---@return Errors.Error
local function invalid(message, context)
  return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context)
end

---@param value unknown
---@return boolean
local function nonNegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

-- Validate one environment record; duplicate ids are rejected and the id is
-- registered. Cross-record references are checked after every record has
-- been seen.
---@param record unknown
---@param environmentIds table<string, boolean>
---@return Errors.Error|nil
local function validateEnvironmentRecord(record, environmentIds)
  if type(record) ~= "table" then
    return invalid("environment record must be a table", {})
  end
  if type(record.environmentId) ~= "string" or record.environmentId == "" then
    return invalid("environment id missing", {})
  end
  if environmentIds[record.environmentId] then
    return invalid("duplicate environment id", { environmentId = record.environmentId })
  end
  environmentIds[record.environmentId] = true
  if not ENVIRONMENT_MODES[record.mode] then
    return invalid(
      "unknown environment mode " .. tostring(record.mode),
      { environmentId = record.environmentId, mode = record.mode }
    )
  end
  if record.createdAtInTicks ~= nil and type(record.createdAtInTicks) ~= "number" then
    return invalid("environment creation offset invalid", { environmentId = record.environmentId })
  end
  if record.movementGeneration ~= nil and not nonNegativeInteger(record.movementGeneration) then
    return invalid("environment movement generation invalid", { environmentId = record.environmentId })
  end
  if record.contextSlots ~= nil then
    if type(record.contextSlots) ~= "table" then
      return invalid("environment context slots must be a table", { environmentId = record.environmentId })
    end
    for slot, instanceId in pairs(record.contextSlots) do
      if not nonNegativeInteger(slot) or slot >= ScriptEnvironment.SLOT_COUNT then
        return invalid("environment context slot out of range", {
          environmentId = record.environmentId,
          slot = slot,
        })
      end
      if type(instanceId) ~= "string" then
        return invalid("environment context slot instance id invalid", {
          environmentId = record.environmentId,
          slot = slot,
        })
      end
    end
  end
  if record.rootInstanceId ~= nil and type(record.rootInstanceId) ~= "string" then
    return invalid("environment root instance id invalid", { environmentId = record.environmentId })
  end
  if record.movementTasksByGeneration ~= nil then
    if type(record.movementTasksByGeneration) ~= "table" then
      return invalid("environment movement tasks must be a table", { environmentId = record.environmentId })
    end
    for _, tasks in pairs(record.movementTasksByGeneration) do
      if type(tasks) ~= "table" then
        return invalid("environment movement generation entry must be a table", {
          environmentId = record.environmentId,
        })
      end
    end
  end
  if record.callerSignals ~= nil and type(record.callerSignals) ~= "table" then
    return invalid("environment caller signals must be a table", { environmentId = record.environmentId })
  end
  if record.locks ~= nil then
    if type(record.locks) ~= "table" then
      return invalid("environment locks must be a table", { environmentId = record.environmentId })
    end
    for key, entry in pairs(record.locks) do
      if type(entry) ~= "table" or not nonNegativeInteger(entry.count) or type(entry.owners) ~= "table" then
        return invalid("environment lock entry is malformed", {
          environmentId = record.environmentId,
          lock = key,
        })
      end
      for ownerId, n in pairs(entry.owners) do
        if type(ownerId) ~= "string" or not nonNegativeInteger(n) then
          return invalid("environment lock owner is malformed", {
            environmentId = record.environmentId,
            lock = key,
          })
        end
      end
    end
  end
  return nil
end

-- Validate one instance record; duplicate ids are rejected and the id is
-- registered. Cross-record references are checked after every record has
-- been seen.
---@param record unknown
---@param instanceIds table<string, boolean>
---@return Errors.Error|nil
local function validateInstanceRecord(record, instanceIds)
  if type(record) ~= "table" then
    return invalid("instance record must be a table", {})
  end
  if type(record.instanceId) ~= "string" or record.instanceId == "" then
    return invalid("instance id missing", {})
  end
  if instanceIds[record.instanceId] then
    return invalid("duplicate instance id", { instanceId = record.instanceId })
  end
  instanceIds[record.instanceId] = true
  if type(record.environmentId) ~= "string" or record.environmentId == "" then
    return invalid("instance environment id missing", { instanceId = record.instanceId })
  end
  if not nonNegativeInteger(record.contextSlot) or record.contextSlot >= ScriptEnvironment.SLOT_COUNT then
    return invalid("instance context slot out of range", {
      instanceId = record.instanceId,
      contextSlot = record.contextSlot,
    })
  end
  if not INSTANCE_MODES[record.mode] then
    return invalid(
      "unknown instance mode " .. tostring(record.mode),
      { instanceId = record.instanceId, mode = record.mode }
    )
  end
  if type(record.scriptId) ~= "string" or record.scriptId == "" then
    return invalid("instance script identity missing", { instanceId = record.instanceId })
  end
  if type(record.revision) ~= "string" then
    return invalid("instance script revision missing", { instanceId = record.instanceId })
  end
  if not ScriptInstance.STATUSES[record.status] then
    return invalid(
      "unknown instance status " .. tostring(record.status),
      { instanceId = record.instanceId, status = record.status }
    )
  end
  if type(record.frames) ~= "table" then
    return invalid("instance frames must be a table", { instanceId = record.instanceId })
  end
  for _, frame in ipairs(record.frames) do
    -- A frame below the top is a suspended caller: its nodeId is nil while
    -- its continuation lives in the callee's returnNodeId, so only a
    -- present nodeId must be a string. The graph revision is the identity
    -- the scheduler reattaches through current compositions, and the
    -- composition entry index is the pre-pass's frame-chain position.
    if
      type(frame) ~= "table"
      or (frame.nodeId ~= nil and type(frame.nodeId) ~= "string")
      or type(frame.chainScriptId) ~= "string"
      or frame.chainScriptId == ""
      or type(frame.chainRevision) ~= "string"
      or type(frame.graphRevision) ~= "string"
      or type(frame.composition) ~= "table"
      or not nonNegativeInteger(frame.composition.entryIndex)
    then
      return invalid("instance frame record is malformed", { instanceId = record.instanceId })
    end
  end
  if record.createdAtInTicks ~= nil and type(record.createdAtInTicks) ~= "number" then
    return invalid("instance creation offset invalid", { instanceId = record.instanceId })
  end
  if record.readyInTicks ~= nil and type(record.readyInTicks) ~= "number" then
    return invalid("instance ready delay invalid", { instanceId = record.instanceId })
  end
  if record.waitingTaskId ~= nil and type(record.waitingTaskId) ~= "string" then
    return invalid("instance waiting task id invalid", { instanceId = record.instanceId })
  end
  return nil
end

-- The whole-bucket checks: id counters, record shapes, and every
-- cross-record reference.
---@param bucket table<string, unknown>
---@return Errors.Error|nil
local function validateBucket(bucket)
  for _, counter in ipairs({ "nextEnvironmentId", "nextInstanceId", "nextTaskId" }) do
    if not nonNegativeInteger(bucket[counter]) then
      return invalid("scripts bucket " .. counter .. " must be a non-negative integer", {
        [counter] = bucket[counter],
      })
    end
  end

  if type(bucket.environments) ~= "table" then
    return invalid("scripts bucket environments must be a table", {})
  end
  local environmentIds = {}
  local foregroundCount = 0
  for _, record in ipairs(bucket.environments) do
    local err = validateEnvironmentRecord(record, environmentIds)
    if err ~= nil then
      return err
    end
    if record.mode == "foreground" then
      foregroundCount = foregroundCount + 1
    end
  end
  if foregroundCount > 1 then
    return invalid("scripts bucket has multiple foreground environments", { count = foregroundCount })
  end

  if type(bucket.instances) ~= "table" then
    return invalid("scripts bucket instances must be a table", {})
  end
  local instanceIds = {}
  for _, record in ipairs(bucket.instances) do
    local err = validateInstanceRecord(record, instanceIds)
    if err ~= nil then
      return err
    end
  end

  if type(bucket.tasks) ~= "table" then
    return invalid("scripts bucket tasks must be a table", {})
  end
  local taskIds = {}
  for _, record in ipairs(bucket.tasks) do
    local err = ScriptTask.validateRecord(record)
    if err ~= nil then
      return err
    end
    if taskIds[record.taskId] then
      return invalid("duplicate task id", { taskId = record.taskId })
    end
    taskIds[record.taskId] = true
  end

  for _, record in ipairs(bucket.instances) do
    if not environmentIds[record.environmentId] then
      return invalid("instance references a missing environment", {
        instanceId = record.instanceId,
        environmentId = record.environmentId,
      })
    end
    if record.waitingTaskId ~= nil and not taskIds[record.waitingTaskId] then
      return invalid("instance references a missing task", {
        instanceId = record.instanceId,
        taskId = record.waitingTaskId,
      })
    end
  end
  for _, record in ipairs(bucket.environments) do
    if record.rootInstanceId ~= nil and not instanceIds[record.rootInstanceId] then
      return invalid("environment references a missing root instance", {
        environmentId = record.environmentId,
        rootInstanceId = record.rootInstanceId,
      })
    end
    for _, instanceId in pairs(record.contextSlots or {}) do
      if not instanceIds[instanceId] then
        return invalid("environment context slot references a missing instance", {
          environmentId = record.environmentId,
          instanceId = instanceId,
        })
      end
    end
    for key, entry in pairs(record.locks or {}) do
      for ownerId in pairs(entry.owners or {}) do
        if not instanceIds[ownerId] then
          return invalid("environment lock references a missing owner", {
            environmentId = record.environmentId,
            lock = key,
            ownerId = ownerId,
          })
        end
      end
    end
    for _, tasks in pairs(record.movementTasksByGeneration or {}) do
      for taskId in pairs(tasks) do
        if not taskIds[taskId] then
          return invalid("environment movement generation references a missing task", {
            environmentId = record.environmentId,
            taskId = taskId,
          })
        end
      end
    end
  end
  for _, record in ipairs(bucket.tasks) do
    if not instanceIds[record.ownerInstanceId] then
      return invalid("task references a missing owner instance", {
        taskId = record.taskId,
        ownerInstanceId = record.ownerInstanceId,
      })
    end
    if not environmentIds[record.environmentId] then
      return invalid("task references a missing environment", {
        taskId = record.taskId,
        environmentId = record.environmentId,
      })
    end
  end
  return nil
end

-- Validate the whole scripts bucket: the envelope, the id counters, every
-- environment/instance/task record, and the cross-record references. Returns
-- nil when valid, else an Errors object; raising variants of the checks are
-- used by restore. Task-record shape validation lives here; restore adds
-- the task-registry resolution and the scheduler adds the graph-revision
-- checks against current compositions.
---@param bucket unknown
---@param opts table<string, unknown>
---@return Errors.Error|nil
function ScriptSave.validate(bucket, opts)
  opts = opts or {}
  if type(bucket) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "scripts bucket must be a table", {})
  end
  if bucket.schema ~= ScriptSave.SCHEMA_NAME then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "unknown scripts bucket schema " .. tostring(bucket.schema),
      { schema = bucket.schema }
    )
  end
  for _, field in ipairs({ "registryFingerprint", "taskFingerprint" }) do
    if type(bucket[field]) ~= "string" or bucket[field] == "" then
      return Errors.new(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "scripts bucket fingerprint is required",
        { field = field }
      )
    end
  end
  if opts.expectedRegistryFingerprint ~= nil and bucket.registryFingerprint ~= opts.expectedRegistryFingerprint then
    return Errors.new(
      ScriptErrors.SCRIPT_REGISTRY_FINGERPRINT_MISMATCH,
      "scripts bucket registry fingerprint does not match the loaded registry",
      { expected = opts.expectedRegistryFingerprint, actual = bucket.registryFingerprint }
    )
  end
  if opts.expectedTaskFingerprint ~= nil and bucket.taskFingerprint ~= opts.expectedTaskFingerprint then
    return Errors.new(
      ScriptErrors.SCRIPT_REGISTRY_FINGERPRINT_MISMATCH,
      "scripts bucket task fingerprint does not match the loaded task registry",
      { expected = opts.expectedTaskFingerprint, actual = bucket.taskFingerprint }
    )
  end
  local err = validateBucket(bucket)
  if err ~= nil then
    return err
  end
  if opts.resolveTask ~= nil then
    for _, taskRecord in ipairs(bucket.tasks) do
      local impl, resolveErr = opts.resolveTask(taskRecord.taskType, taskRecord.taskVersion)
      if impl == nil then
        return resolveErr
          or Errors.new(
            ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
            "saved task implementation is unavailable",
            { taskType = taskRecord.taskType, version = taskRecord.taskVersion }
          )
      end
      local stateErr = impl.validate(taskRecord.state)
      if stateErr ~= nil then
        return stateErr
      end
    end
  end
  if opts.resolveComposition ~= nil then
    for _, instanceRecord in ipairs(bucket.instances) do
      for _, frameRecord in ipairs(instanceRecord.frames) do
        local composed = opts.resolveComposition(frameRecord.chainScriptId)
        if composed == nil or composed.revision ~= frameRecord.chainRevision then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown composed script revision",
            {
              scriptId = frameRecord.chainScriptId,
              revision = frameRecord.chainRevision,
              composedRevision = composed and composed.revision or nil,
            }
          )
        end
        local entry = composed.entries[frameRecord.composition.entryIndex + 1]
        if entry == nil then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown composition entry",
            { scriptId = frameRecord.chainScriptId, entryIndex = frameRecord.composition.entryIndex + 1 }
          )
        end
        if entry.graph.revision ~= frameRecord.graphRevision then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown graph revision",
            { scriptId = frameRecord.chainScriptId, revision = frameRecord.graphRevision }
          )
        end
      end
    end
  end
  return nil
end

-- Restore a scripts bucket into an idle scheduler. `restoreTick` is the load
-- boundary: the caller resumes with the first step at restoreTick + 1, so
-- relative delays rebase exactly. The whole bucket is validated first
-- (raising SCRIPT_TASK_UNSERIALIZABLE on malformed records or dangling
-- cross-references), then task types and versions must resolve and each task
-- implementation must accept the serialized state; the scheduler stages
-- every restored object and installs it only after the whole bucket has
-- restored. Raises on fingerprint mismatch, unknown task types or versions,
-- invalid task state, or unknown graph revisions.
---@param bucket table<string, unknown>
---@param scheduler Scheduler
---@param restoreTick integer
---@param opts table<string, unknown>
function ScriptSave.restore(bucket, scheduler, restoreTick, opts)
  opts = opts or {}
  local function resolveTask(taskType, version)
    return scheduler:resolveTask(taskType, version)
  end
  local function resolveComposition(scriptId)
    return scheduler:resolveComposition(scriptId)
  end
  local envelopeErr = ScriptSave.validate(bucket, {
    expectedRegistryFingerprint = opts.expectedRegistryFingerprint,
    expectedTaskFingerprint = scheduler:taskRegistryFingerprint(),
    resolveTask = resolveTask,
    resolveComposition = resolveComposition,
  })
  if envelopeErr ~= nil then
    Errors.raise(envelopeErr.code, envelopeErr.message, envelopeErr.context)
  end

  scheduler:restoreScriptState(bucket, restoreTick)
end

return ScriptSave
