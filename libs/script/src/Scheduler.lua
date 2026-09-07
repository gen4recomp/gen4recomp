-- The authoritative fixed-tick field-script scheduler. One step per field tick implements the source-derived order: advance
-- engine-owned asynchronous work, poll eligible tasks once in deterministic
-- creation order (a task never polls in its creation tick; a completing task
-- marks its owner `resume_pending` for the next tick), promote older
-- `resume_pending` contexts, run every ready context to yield (at most once
-- per tick, visiting environment context slots 0..2 dynamically so a later
-- common child can start in the caller's tick), then resolve at most one new
-- foreground interaction trigger. Node outcomes are the internal contract
-- between scheduler and runtime; the per-run node budget faults instead of
-- injecting delays.
-- Cancellation is explicit and terminal: a cancelled context never runs or
-- polls again. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local Runtime = require("libs.script.src.Runtime")
local ScriptInstance = require("libs.script.src.ScriptInstance")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")
local ScriptTask = require("libs.script.src.ScriptTask")

---@class SchedulerServices
---@field world table<string, unknown>
---@field actors table<string, unknown>
---@field player table<string, unknown>
---@field dialogue table<string, unknown>|nil
---@field audio table<string, unknown>|nil
---@field camera table<string, unknown>|nil
---@field maps table<string, unknown>|nil
---@field screen table<string, unknown>|nil
---@field events table<string, unknown>|nil
---@field advanceAsync fun(tick: integer)|nil
---@field foreground table<string, unknown>|nil { resolve(input) -> {trigger, composed}|nil }

---@class Scheduler
---@field private _services SchedulerServices
---@field private _semantics table<string, unknown>|nil
---@field private _taskRegistry TaskRegistry
---@field private _traceSink fun(record: table<string, unknown>)|nil
---@field private _resolveComposition fun(scriptId: string): table<string, unknown>|nil
---@field private _maxNodes integer
---@field private _environments table<string, ScriptEnvironment>
---@field private _backgrounds ScriptEnvironment[]
---@field private _foregroundEnvironmentId string|nil
---@field private _instances table<string, ScriptInstance> live instances
---@field private _endedInstances table<string, ScriptInstance> archived child records, pruned when no task observes them
---@field private _tasks ScriptTask[] active and completed-but-unconsumed tasks
---@field private _tasksById table<string, ScriptTask>
---@field private _nextEnvironmentId integer
---@field private _nextInstanceId integer
---@field private _nextTaskId integer
local Scheduler = {}
Scheduler.__index = Scheduler

-- Run-phase safety budget : a context that cannot yield
-- faults with SCRIPT_STEP_BUDGET_EXCEEDED; the runtime never converts budget
-- exhaustion into an implicit yield.
Scheduler.MAX_NONBLOCKING_NODES_PER_TICK = 1024

---@param opts table<string, unknown>
---@return Scheduler
function Scheduler.new(opts)
  assert(opts and opts.services, "scheduler services required")
  assert(opts.taskRegistry, "scheduler task registry required")
  return setmetatable({
    _services = opts.services,
    _semantics = opts.semantics,
    _taskRegistry = opts.taskRegistry,
    _traceSink = opts.trace,
    _resolveComposition = opts.resolveComposition,
    _maxNodes = opts.maxNonBlockingNodesPerTick or Scheduler.MAX_NONBLOCKING_NODES_PER_TICK,
    _environments = {},
    _backgrounds = {},
    _foregroundEnvironmentId = nil,
    _instances = {},
    _endedInstances = {},
    _tasks = {},
    _tasksById = {},
    _deferredFaults = {},
    _nextEnvironmentId = 0,
    _nextInstanceId = 0,
    _nextTaskId = 0,
  }, Scheduler)
end

-- --- Diagnostics -------------------------------------------------------------

function Scheduler:_trace(kind, fields)
  if self._traceSink == nil then
    return
  end
  fields = fields or {}
  fields.tick = fields.tick or self._currentTick
  fields.kind = kind
  self._traceSink(fields)
end

function Scheduler:_emit(name, payload)
  local events = self._services.events
  if events and events.emit then
    events:emit(name, payload)
  end
end

-- --- Composition resolution ---------------------------------------------------

-- Resolve a public script id to its effective composed chain; the game layer
-- wires this to the registry/composition pair. Unknown ids resolve to
-- nil and produce attributed call errors.
---@param scriptId string
---@return table<string, unknown>|nil
function Scheduler:resolveComposition(scriptId)
  if self._resolveComposition == nil then
    return nil
  end
  return self._resolveComposition(scriptId)
end

-- --- Instance and environment creation ---------------------------------------

---@param state { _nextEnvironmentId: integer }
---@return string
local function environmentIdFor(state)
  state._nextEnvironmentId = state._nextEnvironmentId + 1
  return string.format("script-env-%08d", state._nextEnvironmentId)
end

---@param state { _nextInstanceId: integer }
---@return string
local function instanceIdFor(state)
  state._nextInstanceId = state._nextInstanceId + 1
  return string.format("script-%08d", state._nextInstanceId)
end

---@param state { _nextTaskId: integer }
---@return string
local function taskIdFor(state)
  state._nextTaskId = state._nextTaskId + 1
  return string.format("task-%08d", state._nextTaskId)
end

-- Push the entry frame of a composed chain onto a fresh instance.
---@param instance ScriptInstance
---@param composed table<string, unknown>
---@param args table<string, unknown>
local function pushEntryFrame(instance, composed, args)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  if entry.graph.entry ~= nil then
    instance:pushFrame(instance:makeFrame(entry.graph, entry.graph.entry, {
      args = args,
      chain = entries,
      chainScriptId = composed.scriptId,
      chainRevision = composed.revision,
      composition = {
        entryIndex = 0,
        operation = entry.operation,
        owner = entry.owner,
      },
    }))
  end
end

---@param env ScriptEnvironment
---@param composed table<string, unknown>
---@param trigger table<string, unknown>|nil
---@param args table<string, unknown>|nil
---@param tick integer
---@return ScriptInstance
function Scheduler:_createInstance(env, composed, trigger, args, tick)
  local instance = ScriptInstance.new({
    instanceId = instanceIdFor(self),
    environmentId = env.environmentId,
    contextSlot = 0,
    scriptId = composed.scriptId,
    revision = composed.revision,
    owner = composed.entries[1].owner,
    mode = env.mode,
    trigger = trigger,
    args = args or {},
    createdAtTick = tick,
    readyAtTick = tick,
  })
  pushEntryFrame(instance, composed, instance.args)
  self._instances[instance.instanceId] = instance
  self:_emit("script.started", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    mode = instance.mode,
    trigger = instance.trigger,
    revision = instance.revision,
  })
  return instance
end

-- Create an execution environment whose root is a fresh instance of a
-- composed script. Foreground environments
-- register as the field owner; background environments join the creation
-- order. The new context may run in this tick; the caller decides whether
-- the slot loop visits it now. `interactionClaim` grants the foreground
-- root player-input ownership for the environment's whole lifetime,
-- independent of explicit lock opcodes; it is never inferred from `trigger`
-- and is ignored (always false) for a background environment.
---@param mode string
---@param composed table<string, unknown>
---@param trigger table<string, unknown>|nil
---@param tick integer
---@param interactionClaim boolean|nil
---@return string instanceId
function Scheduler:_createEnvironment(mode, composed, trigger, tick, interactionClaim)
  local env = ScriptEnvironment.new({
    environmentId = environmentIdFor(self),
    mode = mode,
    createdAtTick = tick,
    interactionClaim = mode == "foreground" and interactionClaim == true or false,
  })
  self._environments[env.environmentId] = env
  if mode == "foreground" then
    self._foregroundEnvironmentId = env.environmentId
  else
    self._backgrounds[#self._backgrounds + 1] = env
  end
  local instance = self:_createInstance(env, composed, trigger, nil, tick)
  env:setRoot(instance.instanceId)
  self:_trace("environment_created", {
    environmentId = env.environmentId,
    mode = mode,
    instanceId = instance.instanceId,
  })
  return instance.instanceId
end

-- Start a foreground interaction: a fresh environment whose root owns the
-- field. The new context may run in this tick; the
-- caller decides whether the slot loop visits it now. `interactionClaim`
-- (default false/none) is the caller's explicit launch-origin ownership
-- descriptor; callers that omit it start a non-owning root exactly like
-- map initialization.
---@param composed table<string, unknown>
---@param trigger table<string, unknown>|nil
---@param tick integer
---@param interactionClaim boolean|nil
---@return string instanceId
function Scheduler:createForeground(composed, trigger, tick, interactionClaim)
  assert(self._foregroundEnvironmentId == nil, "a foreground environment already owns the field")
  return self:_createEnvironment("foreground", composed, trigger, tick, interactionClaim)
end

-- Start a project-native background environment.
-- Background environments run after the foreground environment in creation
-- order and may not use foreground-only operations.
---@param composed table<string, unknown>
---@param trigger table<string, unknown>|nil
---@param tick integer
---@return string instanceId
function Scheduler:createBackground(composed, trigger, tick)
  return self:_createEnvironment("background", composed, trigger, tick)
end

-- Create a verified common-script child context in a later slot of the
-- caller's environment. The child is ready for the
-- current tick; the dynamic slot loop decides whether it runs now. `args`
-- are already evaluated call arguments.
---@param composed table<string, unknown>
---@param args table<string, unknown>
---@param run table<string, unknown>
---@param slot integer
---@return ScriptInstance
function Scheduler:createChildInstance(composed, args, run, slot)
  local child = ScriptInstance.new({
    instanceId = instanceIdFor(self),
    environmentId = run.environment.environmentId,
    contextSlot = slot,
    scriptId = composed.scriptId,
    revision = composed.revision,
    owner = composed.entries[1].owner,
    mode = run.environment.mode,
    trigger = run.instance.trigger,
    args = args,
    createdAtTick = run.tick,
    readyAtTick = run.tick,
  })
  pushEntryFrame(child, composed, args)
  self._instances[child.instanceId] = child
  run.environment:placeContext(slot, child.instanceId)
  self:_emit("script.started", {
    scriptId = child.scriptId,
    instanceId = child.instanceId,
    owner = child.owner,
    mode = child.mode,
    trigger = child.trigger,
    revision = child.revision,
  })
  self:_trace("child_created", {
    instanceId = child.instanceId,
    environmentId = child.environmentId,
    slot = slot,
  })
  return child
end

-- Allocate the lowest free later slot, create the common child, and arm the
-- caller signal. Shared by the call_common node and the
-- raw `ctx.script:call` descriptor.
---@param composed table<string, unknown>
---@param args table<string, unknown>
---@param run table<string, unknown>
---@return ScriptInstance child, integer slot, integer parentSlot
function Scheduler:createCommonChild(composed, args, run)
  local parentSlot = run.instance.contextSlot
  local slot = run.environment:freeChildSlot(parentSlot)
  if slot == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CONTEXT_SLOTS_EXHAUSTED,
      "script environment has no free context slot",
      { scriptId = run.instance.scriptId, environmentId = run.environment.environmentId }
    )
  end
  slot = slot --[[@as integer]]
  local child = self:createChildInstance(composed, args, run, slot)
  run.environment:setCallerSignal(parentSlot, true)
  return child,
    slot, --[[@as integer]]
    parentSlot
end

-- --- Task creation ------------------------------------------------------------

-- The shared execution envelope passed to task implementations (poll/create)
-- and to Runtime node handlers: the scheduler, the owning instance and
-- environment, the current fixed tick, the immutable input snapshot, and the
-- injected services.
---@param instance ScriptInstance
---@param environment ScriptEnvironment
---@param tick integer
---@param input table<string, unknown>|nil
---@return table<string, unknown>
function Scheduler:_ctxFor(instance, environment, tick, input)
  return {
    scheduler = self,
    instance = instance,
    environment = environment,
    tick = tick,
    input = input,
    services = self._services,
    semantics = self._semantics,
  }
end

-- Create a blocking or owner task through the registry.
-- The record's first poll is always the next tick: a task created during
-- this tick is never eligible in it.
---@param taskType string
---@param spec table<string, unknown>
---@param instance ScriptInstance
---@param tick integer
---@param input table<string, unknown>|nil
---@return string taskId
function Scheduler:createTask(taskType, spec, instance, tick, input)
  local impl, resolveErr = self._taskRegistry:resolveCurrent(taskType)
  if not impl then
    local err = resolveErr --[[@as Errors.Error]]
    Errors.raise(
      err.code,
      err.message,
      { scriptId = instance.scriptId, instanceId = instance.instanceId, taskType = taskType, cause = err }
    )
  end
  ---@cast impl TaskImplementation
  local environment = assert(self._environments[instance.environmentId], "task owner environment missing")
  local ctx = self:_ctxFor(instance, environment, tick, input)
  local state = impl.create(spec, ctx)
  local task = ScriptTask.new({
    taskId = taskIdFor(self),
    taskType = taskType,
    taskVersion = impl.version,
    ownerInstanceId = instance.instanceId,
    environmentId = environment.environmentId,
    createdAtTick = tick,
    pollAtTick = tick + 1,
    state = state,
  })
  self._tasks[#self._tasks + 1] = task
  self._tasksById[task.taskId] = task
  if taskType == "movement" then
    -- Movement tasks register in the environment's current movement
    -- generation at creation, so barriers and pause logic observe raw
    -- ctx.tasks.movement descriptors exactly like compiled move nodes.
    environment:registerMovementTask(task.taskId)
  end
  self:_emit("script.task_started", {
    taskId = task.taskId,
    taskType = taskType,
    taskVersion = task.taskVersion,
    instanceId = instance.instanceId,
    createdAtTick = tick,
  })
  self:_trace("task_created", {
    taskId = task.taskId,
    taskType = taskType,
    instanceId = instance.instanceId,
  })
  return task.taskId
end

-- Mark an engine-owned movement task complete (used by the actor world when
-- scripted movement finishes; ). Removes it from the
-- environment's current generation so barriers observe the predicate change.
---@param taskId string
---@param tick integer
function Scheduler:completeMovementTask(taskId, tick)
  local task = self._tasksById[taskId]
  if task == nil or task.status ~= "active" then
    return
  end
  local environment = self._environments[task.environmentId]
  if environment then
    environment:unregisterMovementTask(taskId)
  end
  task:complete(tick, nil)
end

-- --- Tick ---------------------------------------------------------------------

-- The authoritative per-tick step . `input` is the
-- immutable fixed-tick input snapshot; it is shared by trigger resolution and
-- input-wait tasks and never replayed.
---@param tick integer
---@param input table<string, unknown>|nil
function Scheduler:step(tick, input)
  assert(self._currentTick == nil or tick > self._currentTick, "scheduler ticks must advance monotonically")
  self._currentTick = tick
  self._currentInput = input
  local advance = self._services.advanceAsync
  if advance then
    advance(tick)
  end
  -- Contexts already in resume_pending before this tick :
  -- a task that completes during this tick must never promote in it.
  local pendingSnapshot = self:_resumePendingSnapshot()
  self:_pollTasks(tick)
  self:_promoteResumePending(tick, pendingSnapshot)
  self:_runEnvironments(tick, input)
  self:_resolveInteraction(tick, input)
end

function Scheduler:_resumePendingSnapshot()
  local out = {}
  for instanceId, instance in pairs(self._instances) do
    if instance.status == ScriptInstance.STATUSES.resume_pending then
      out[#out + 1] = instanceId
    end
  end
  table.sort(out)
  return out
end

-- Poll every active task at most once per tick, in deterministic creation
-- order. A completing task marks its owner
-- `resume_pending` with `readyAtTick = tick + 1`; graph continuation never
-- happens in the completion tick. A raising poll or onComplete callback is
-- contained by the task-callback boundary: the failure is recorded and the
-- owner fault is applied after the loop, so cancelling the broken task never
-- mutates the task array mid-iteration.
function Scheduler:_pollTasks(tick)
  for _, task in ipairs(self._tasks) do
    if task:isPollEligible(tick) then
      assert(task.lastPolledTick ~= tick, "task double-polled in one tick")
      local owner = self._instances[task.ownerInstanceId]
      assert(owner, "task owner instance missing")
      local environment = assert(self._environments[task.environmentId], "task environment missing")
      local impl = assert(self._taskRegistry:resolve(task.taskType, task.taskVersion))
      task.lastPolledTick = tick
      local ctx = self:_ctxFor(owner, environment, tick, self._currentInput)
      ctx.taskId = task.taskId
      local ok, result = pcall(impl.poll, task.state, ctx)
      if not ok then
        self:_deferTaskFault("poll", task, ctx, result)
      else
        self:_handlePollResult(task, impl, owner, ctx, result, tick)
      end
    end
  end
  self:_applyDeferredFaults()
end

-- Apply one successful poll outcome: record the state, trace, and on
-- completion mark the task, run its onComplete callback inside the boundary,
-- and hand the result to the owner.
function Scheduler:_handlePollResult(task, impl, owner, ctx, result, tick)
  task.state = result.state
  self:_trace("task_polled", {
    taskId = task.taskId,
    taskType = task.taskType,
    instanceId = owner.instanceId,
    complete = result.complete == true,
  })
  if result.complete then
    task:complete(tick, result.result)
    if impl.onComplete then
      local ok, completeErr = pcall(impl.onComplete, task.state, ctx)
      if not ok then
        self:_deferTaskFault("onComplete", task, ctx, completeErr)
        return
      end
    end
    self:_emit("script.task_ended", {
      taskId = task.taskId,
      taskType = task.taskType,
      instanceId = owner.instanceId,
      completedAtTick = tick,
      result = result.result,
    })
    local termination = type(result.result) == "table" and result.result.termination or nil
    if termination == "faulted" then
      -- A common child fault propagates to its blocked parent through the
      -- child_script task : the parent faults with the
      -- child's attributed error.
      self:_faultInstance(
        owner,
        tick,
        result.result.error
          or Errors.new(ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID, "common child faulted", {
            scriptId = owner.scriptId,
            instanceId = owner.instanceId,
          })
      )
    else
      owner.status = ScriptInstance.STATUSES.resume_pending
      owner.readyAtTick = tick + 1
      owner.taskResult = result.result
    end
    -- A completing child_script task read the child's outcome it needed:
    -- drop the archived record now that its last observer ended.
    self:_pruneArchivedInstances()
  end
end

-- One task-callback fault boundary: turn a callback raise into an owner
-- fault. A structured error is attributed as-is; anything else is wrapped
-- with the task type, task id, script id, and instance id. The fault is
-- deferred until the caller's iteration of the task array finishes.
---@param kind string
---@param task ScriptTask
---@param ctx table<string, unknown>
---@param err unknown
function Scheduler:_deferTaskFault(kind, task, ctx, err)
  local fault
  if Errors.is(err) then
    fault = err
  else
    fault = Errors.new(
      ScriptErrors.SCRIPT_TASK_CALLBACK_FAULT,
      string.format("task %s callback raised: %s", kind, tostring(err)),
      {
        taskType = task.taskType,
        taskId = task.taskId,
        scriptId = ctx.instance.scriptId,
        instanceId = ctx.instance.instanceId,
      }
    )
  end
  self._deferredFaults[#self._deferredFaults + 1] = {
    kind = kind,
    task = task,
    instance = ctx.instance,
    fault = fault,
  }
  self:_trace("task_faulted", {
    taskId = task.taskId,
    taskType = task.taskType,
    instanceId = ctx.instance.instanceId,
    kind = kind,
    code = fault.code,
  })
end

-- Apply deferred task-callback faults after the poll loop finished: cancel
-- each broken task record deterministically (its own cancel callback is
-- contained), then fault the owner if it has not already ended.
function Scheduler:_applyDeferredFaults()
  local pending = self._deferredFaults
  self._deferredFaults = {}
  for _, record in ipairs(pending) do
    if record.task ~= nil then
      self:_cancelTaskState(record.task, record.kind .. " callback faulted")
    end
    local instance = record.instance
    if instance.status ~= "completed" and instance.status ~= "faulted" and instance.status ~= "cancelled" then
      self:_faultInstance(instance, self._currentTick or 0, record.fault)
    end
  end
end

-- Write a completed task result into the blocking node's result reference
-- (ask_yes_no). The ref is evaluated
-- against the instance on the promotion tick.
function Scheduler:_writeTaskResult(instance)
  local run = {
    instance = instance,
    node = { nodeId = "<task-result>" },
    services = self._services,
    semantics = self._semantics,
  }
  if self._semantics == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "script semantics are unavailable",
      { scriptId = instance.scriptId }
    )
  end
  self._semantics.writeRef(instance.pendingResultRef, instance.taskResult, run)
end

-- Promote contexts that were already `resume_pending` before this tick and
-- whose ready deadline has arrived: consume the completed task result exactly
-- once and drop the consumed task record.
---@param tick integer
---@param pendingSnapshot string[]
function Scheduler:_promoteResumePending(tick, pendingSnapshot)
  for _, instanceId in ipairs(pendingSnapshot) do
    local instance = self._instances[instanceId]
    if
      instance ~= nil
      and instance.status == ScriptInstance.STATUSES.resume_pending
      and instance.readyAtTick <= tick
    then
      instance.status = ScriptInstance.STATUSES.ready
      instance.yieldReason = nil
      local task = self._tasksById[instance.waitingTaskId]
      if task then
        self._tasksById[task.taskId] = nil
        task:markConsumed()
        for i = #self._tasks, 1, -1 do
          if self._tasks[i] == task then
            table.remove(self._tasks, i)
            break
          end
        end
      end
      instance.waitingTaskId = nil
      if instance.pendingResultRef ~= nil and instance.taskResult ~= nil then
        self:_writeTaskResult(instance)
      end
      instance.pendingResultRef = nil
      self:_trace("resume_promoted", { instanceId = instanceId })
    end
  end
end

-- Visit every execution environment in deterministic order (the foreground
-- environment first, then background environments in creation order) and run
-- each eligible context in its slot once. The slot loop
-- is dynamic: a common child created by an earlier slot runs in this tick.
function Scheduler:_runEnvironments(tick, input)
  for _, env in ipairs(self:_orderedEnvironments()) do
    self:_runEnvironmentSlots(env, tick, input)
  end
end

function Scheduler:_runEnvironmentSlots(env, tick, input)
  for slot = 0, ScriptEnvironment.SLOT_COUNT - 1 do
    local instanceId = env:contextAt(slot)
    if instanceId ~= nil then
      local instance = assert(self._instances[instanceId], "context references a missing instance")
      if
        instance.status == ScriptInstance.STATUSES.ready
        and instance.readyAtTick <= tick
        and instance.lastRunTick ~= tick
      then
        self:_runToYield(instance, tick, input)
      end
    end
  end
end

-- Resolve at most one new foreground interaction trigger when no foreground
-- root owns the field. A newly created interaction
-- may execute during this tick, matching the source field-control ordering.
function Scheduler:_resolveInteraction(tick, input)
  if self._foregroundEnvironmentId ~= nil then
    return
  end
  local foreground = self._services.foreground
  if foreground == nil or foreground.resolve == nil then
    return
  end
  local hit = foreground.resolve(input)
  if hit == nil then
    return
  end
  local composed = hit.composed
  if composed == nil then
    return
  end
  -- This path resolves the field/world's own new interaction trigger, so the
  -- root it starts is field-interaction-origin and owns player input.
  self:createForeground(composed, hit.trigger, tick, true)
  local env = assert(self._environments[self._foregroundEnvironmentId])
  self:_runEnvironmentSlots(env, tick, input)
end

-- --- Run-to-yield -------------------------------------------------------------

-- Run one ready context to an explicit yield, block, stop, or fault.
-- The context is granted at most one run per tick; the
-- node budget counts every continue outcome and faults pathological
-- non-yielding execution instead of yielding implicitly.
function Scheduler:_runToYield(instance, tick, input)
  assert(instance.lastRunTick ~= tick, "context may run at most once per tick")
  instance.status = ScriptInstance.STATUSES.running
  instance.lastRunTick = tick
  instance.yieldReason = nil
  local environment = assert(self._environments[instance.environmentId], "instance environment missing")
  local run = self:_ctxFor(instance, environment, tick, input)
  local frame = instance:topFrame()
  self:_trace("context_run", {
    instanceId = instance.instanceId,
    slot = instance.contextSlot,
    nodeId = frame and frame.nodeId,
  })
  local budget = self._maxNodes
  while true do
    local top = instance:topFrame()
    if top == nil then
      self:_completeInstance(instance, tick)
      return
    end
    local node = top.graph.nodes[top.nodeId]
    local outcome
    if node == nil then
      outcome = Runtime.fallOffEnd(run)
    else
      -- The linear pc advances before execution; branch handlers overwrite
      -- it with their explicit edge.
      top.nodeId = node.next
      local ok, err = pcall(Runtime.executeNode, node, run)
      if not ok then
        if Errors.is(err) then
          local fault = err --[[@as Errors.Error]]
          self:_faultInstance(instance, tick, fault)
          return
        end
        error(err, 0)
      end
      outcome = err
    end
    if outcome == Runtime.OUTCOME_CONTINUE then
      budget = budget - 1
      if budget < 1 then
        self:_faultInstance(
          instance,
          tick,
          Errors.new(
            ScriptErrors.SCRIPT_STEP_BUDGET_EXCEEDED,
            "run-phase node budget exceeded",
            { scriptId = instance.scriptId, instanceId = instance.instanceId, limit = self._maxNodes }
          )
        )
        return
      end
    elseif outcome == Runtime.OUTCOME_YIELD_TICK then
      instance.status = ScriptInstance.STATUSES.ready
      instance.readyAtTick = tick + 1
      instance.yieldReason = "explicit_yield"
      self:_trace("context_yielded", {
        instanceId = instance.instanceId,
        readyAtTick = tick + 1,
      })
      return
    elseif outcome == Runtime.OUTCOME_BLOCK then
      instance.status = ScriptInstance.STATUSES.blocked
      instance.waitingTaskId = run.blockTaskId
      instance.pendingResultRef = run.blockResultRef
      instance.yieldReason = "task"
      self:_trace("context_blocked", {
        instanceId = instance.instanceId,
        taskId = run.blockTaskId,
      })
      return
    elseif outcome == Runtime.OUTCOME_STOP then
      self:_completeInstance(instance, tick)
      return
    end
  end
end

-- --- Completion, faults, and cancellation -------------------------------------

-- Release every lock the instance owns and cancel its
-- engine-owned movement tasks.
function Scheduler:_releaseInstanceOwnership(instance)
  local environment = self._environments[instance.environmentId]
  if environment then
    environment:releaseLocksFor(instance.instanceId)
    local movement = {}
    for _, task in ipairs(self._tasks) do
      if task.ownerInstanceId == instance.instanceId and task.taskType == "movement" and task.status == "active" then
        movement[#movement + 1] = task
      end
    end
    for _, task in ipairs(movement) do
      environment:unregisterMovementTask(task.taskId)
      self:_cancelTaskState(task, "owner ended")
    end
  end
end

-- Normal instance completion : release ownership,
-- clear text arguments, free the context slot, and tear down the environment
-- when the root completes.
function Scheduler:_completeInstance(instance, _)
  instance.status = ScriptInstance.STATUSES.completed
  instance.endReason = "completed"
  instance:clearInstanceState()
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = true,
    reason = "completed",
  })
  self:_trace("context_completed", { instanceId = instance.instanceId })
  self:_finishInstanceInEnvironment(instance, "completed")
  self:_archiveInstance(instance)
end

-- Fault one context through attributed cleanup : record the error, release ownership, emit events, and tear
-- down the environment when the faulting context is the root.
---@param instance ScriptInstance
---@param error Errors.Error
function Scheduler:_faultInstance(instance, _, error)
  if
    instance.status == ScriptInstance.STATUSES.completed
    or instance.status == ScriptInstance.STATUSES.faulted
    or instance.status == ScriptInstance.STATUSES.cancelled
  then
    return
  end
  instance.status = ScriptInstance.STATUSES.faulted
  instance.endReason = error.code
  instance:clearInstanceState()
  self:_emit("script.error", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    code = error.code,
    message = error.message,
    context = error.context,
  })
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = false,
    reason = error.code,
  })
  self:_trace("context_faulted", {
    instanceId = instance.instanceId,
    code = error.code,
  })
  self:_finishInstanceInEnvironment(instance, error.code)
  self:_archiveInstance(instance)
end

-- Move an ended instance out of the live set. An ended root has no task
-- observer and is dropped entirely; an ended child is retained only while
-- the child_script task of its caller still polls its termination state,
-- and pruned once that task ends. Live iteration and save capture see only
-- running state.
function Scheduler:_archiveInstance(instance)
  self._instances[instance.instanceId] = nil
  if self:_hasObservingTask(instance.instanceId) then
    self._endedInstances[instance.instanceId] = instance
  end
end

-- True when an active task still polls the instance's termination state
-- (the child_script task of a common-call caller).
---@param instanceId string
---@return boolean
function Scheduler:_hasObservingTask(instanceId)
  for _, task in ipairs(self._tasks) do
    if task.status == "active" and task.state ~= nil and task.state.childInstanceId == instanceId then
      return true
    end
  end
  return false
end

-- Remove archived child records whose last observing task ended: the
-- completing poll already captured the child's outcome, so the record is
-- no longer reachable by anything.
function Scheduler:_pruneArchivedInstances()
  if next(self._endedInstances) == nil then
    return
  end
  for instanceId in pairs(self._endedInstances) do
    if not self:_hasObservingTask(instanceId) then
      self._endedInstances[instanceId] = nil
    end
  end
end

-- Free the context slot of a finished child, or tear down the whole
-- environment when the finishing instance is the root.
function Scheduler:_finishInstanceInEnvironment(instance, reason)
  local environment = self._environments[instance.environmentId]
  if environment == nil then
    return
  end
  if instance.contextSlot > 0 then
    environment:clearContext(instance.contextSlot)
  else
    self:_teardownEnvironment(environment, reason)
  end
end

-- Cancel a task: invoke the implementation's own `cancel(state, reason, ctx)`
-- cleanup (implementations own engine resources such as an open dialogue
-- window) inside the task-callback boundary, mark the record cancelled, and
-- drop it from the live task sets (cancelled tasks are never referenced
-- again). A cancel raise is contained -- the record is still cancelled and
-- removed -- and returned so the caller can fault the owning instance.
---@param task ScriptTask
---@param reason string
---@return unknown|nil
function Scheduler:_cancelTaskState(task, reason)
  if task.status == "cancelled" then
    return nil
  end
  local containedErr
  local impl = self._taskRegistry:resolve(task.taskType, task.taskVersion)
  if impl ~= nil and impl.cancel ~= nil then
    local owner = self._instances[task.ownerInstanceId]
    local environment = self._environments[task.environmentId]
    local ctx = nil
    if owner ~= nil and environment ~= nil then
      ctx = self:_ctxFor(owner, environment, self._currentTick or 0, self._currentInput)
      ctx.taskId = task.taskId
    end
    local ok, err = pcall(impl.cancel, task.state, reason, ctx)
    if not ok then
      containedErr = err
    end
  end
  task:cancel(reason)
  for i = #self._tasks, 1, -1 do
    if self._tasks[i] == task then
      table.remove(self._tasks, i)
      break
    end
  end
  self._tasksById[task.taskId] = nil
  -- A cancelled child_script task never polls again: prune the child
  -- record it observed, if no other task still does.
  self:_pruneArchivedInstances()
  return containedErr
end

-- Fault the owner of a task whose cancel callback raised, with the same
-- task/script/instance attribution as the poll boundary.
---@param task ScriptTask
---@param err unknown
---@return Errors.Error
function Scheduler:_cancelFault(task, err)
  if Errors.is(err) then
    return err
  end
  local owner = self._instances[task.ownerInstanceId]
  return Errors.new(ScriptErrors.SCRIPT_TASK_CALLBACK_FAULT, "task cancel callback raised: " .. tostring(err), {
    taskType = task.taskType,
    taskId = task.taskId,
    scriptId = owner and owner.scriptId or nil,
    instanceId = task.ownerInstanceId,
  })
end

-- Tear down an environment : cancel its remaining active
-- or completed-but-unconsumed tasks, cancel every context, release movement
-- ownership and barrier generations, release locks, clear slots and caller
-- signals, and drop the environment from the scheduler.
---@param environment ScriptEnvironment
---@param reason string
function Scheduler:_teardownEnvironment(environment, reason)
  local doomed = {}
  for _, task in ipairs(self._tasks) do
    if task.environmentId == environment.environmentId and (task.status == "active" or task.status == "completed") then
      doomed[#doomed + 1] = task
    end
  end
  for _, task in ipairs(doomed) do
    local err = self:_cancelTaskState(task, reason)
    if err ~= nil then
      local owner = self._instances[task.ownerInstanceId]
      if owner ~= nil then
        -- A raising cancel is contained; the live owner faults with the
        -- attributed error instead of the raise escaping the teardown. The
        -- doomed list is a local copy, so the fault's own cleanup (which
        -- mutates the task arrays) is safe here.
        self:_faultInstance(owner, self._currentTick or 0, self:_cancelFault(task, err))
      end
    end
  end
  for slot = 0, ScriptEnvironment.SLOT_COUNT - 1 do
    local instanceId = environment:contextAt(slot)
    if instanceId ~= nil then
      local instance = self._instances[instanceId]
      if instance and instance.status ~= "completed" and instance.status ~= "faulted" then
        self:_cancelInstance(instance, reason)
      end
    end
  end
  for _, generation in pairs(environment.movementTasksByGeneration) do
    for taskId in pairs(generation) do
      local task = self._tasksById[taskId]
      if task and task.status == "active" then
        self:_cancelTaskState(task, reason)
      end
    end
  end
  environment.locks = {}
  environment.callerSignals = {}
  self._environments[environment.environmentId] = nil
  if environment.mode == "foreground" then
    self._foregroundEnvironmentId = nil
  else
    for i = #self._backgrounds, 1, -1 do
      if self._backgrounds[i] == environment then
        table.remove(self._backgrounds, i)
        break
      end
    end
  end
  self:_trace("environment_torn_down", { environmentId = environment.environmentId })
end

-- Cancel one instance : cancel its tasks, release its
-- ownership, and emit `script.ended` with `completed = false`. A raising
-- task-cancel callback faults the instance instead of escaping.
---@param instance ScriptInstance
---@param reason string
function Scheduler:_cancelInstance(instance, reason)
  if
    instance.status == ScriptInstance.STATUSES.completed
    or instance.status == ScriptInstance.STATUSES.cancelled
    or instance.status == ScriptInstance.STATUSES.faulted
  then
    return
  end
  local doomed = {}
  for _, task in ipairs(self._tasks) do
    if task.ownerInstanceId == instance.instanceId and (task.status == "active" or task.status == "completed") then
      doomed[#doomed + 1] = task
    end
  end
  for _, task in ipairs(doomed) do
    local err = self:_cancelTaskState(task, reason)
    if err ~= nil then
      self:_faultInstance(instance, self._currentTick or 0, self:_cancelFault(task, err))
      return
    end
  end
  instance.status = ScriptInstance.STATUSES.cancelled
  instance.endReason = reason
  instance:clearInstanceState()
  self:_releaseInstanceOwnership(instance)
  self:_emit("script.ended", {
    scriptId = instance.scriptId,
    instanceId = instance.instanceId,
    owner = instance.owner,
    completed = false,
    reason = reason,
  })
  self:_trace("context_cancelled", { instanceId = instance.instanceId })
  self:_archiveInstance(instance)
end

-- Cancel a whole environment and everything it owns.
---@param environmentId string
---@param reason string
function Scheduler:cancelEnvironment(environmentId, reason)
  local environment = self._environments[environmentId]
  if environment == nil then
    return
  end
  self:_teardownEnvironment(environment, reason)
end

-- Cancel one instance and, when it is a root, its environment.
---@param instanceId string
---@param reason string
function Scheduler:cancelInstance(instanceId, reason)
  local instance = self._instances[instanceId]
  if instance == nil then
    return
  end
  self:_cancelInstance(instance, reason)
  if instance.contextSlot == 0 then
    local environment = self._environments[instance.environmentId]
    if environment then
      self:_teardownEnvironment(environment, reason)
    end
  end
end

-- Override the run-phase node budget (tests and diagnostics only; the
-- production default is Scheduler.MAX_NONBLOCKING_NODES_PER_TICK).
---@param maxNodes integer
function Scheduler:setMaxNodes(maxNodes)
  assert(type(maxNodes) == "number" and maxNodes > 0, "node budget must be positive")
  self._maxNodes = maxNodes
end

-- Start a foreground root outside the scheduler's own tick resolution (used
-- by the session's interaction client): creates the environment and runs
-- its slots so the new context may execute during its trigger tick. Returns
-- nil when a foreground root already owns the field. `interactionClaim`
-- (default false/none) is the caller's explicit launch-origin ownership
-- descriptor -- it is never inferred from `trigger`. `ScriptInteractionClient`
-- passes true from `consume()` (field/world interaction) and omits it from
-- `startInitScript()` (map initialization).
---@param trigger table<string, unknown>
---@param composed table<string, unknown>
---@param tick integer
---@param interactionClaim boolean|nil
---@return string|nil instanceId
function Scheduler:startInteraction(trigger, composed, tick, interactionClaim)
  if self._foregroundEnvironmentId ~= nil then
    return nil
  end
  local instanceId = self:createForeground(composed, trigger, tick, interactionClaim)
  local environment = assert(self._environments[self._foregroundEnvironmentId])
  self:_runEnvironmentSlots(environment, tick, self._currentInput)
  return instanceId
end

-- Explicit source LOCK_PLAYER/LockAll state only, independent of launch
-- origin. Callers that need combined ownership should read
-- `interactionOwnsPlayerInput` or `playerInputOwned` instead.
---@return boolean
function Scheduler:explicitPlayerLocked()
  local envId = self._foregroundEnvironmentId
  if envId == nil then
    return false
  end
  local env = self._environments[envId]
  return env ~= nil and env:playerLocked() or false
end

-- True only when the active foreground environment's root was launched by
-- field interaction/event arbitration (`ScriptInteractionClient:consume`),
-- independent of explicit lock state. False for a map-init root and for
-- every background environment.
---@return boolean
function Scheduler:interactionOwnsPlayerInput()
  local envId = self._foregroundEnvironmentId
  if envId == nil then
    return false
  end
  local env = self._environments[envId]
  return env ~= nil and env:interactionOwnsPlayerInput() or false
end

-- Combined player-input ownership: explicit lock OR interaction claim. The
-- one fact `FieldSession` consumes to suppress manual player input.
---@return boolean
function Scheduler:playerInputOwned()
  return self:explicitPlayerLocked() or self:interactionOwnsPlayerInput()
end

---@return boolean
function Scheduler:autonomousActorsLocked()
  local envId = self._foregroundEnvironmentId
  if envId == nil then
    return false
  end
  local env = self._environments[envId]
  return env ~= nil and env:autonomousLocked() or false
end

-- Read-only foreground fact for the field actor service. The environment owns
-- the lock table; callers receive only the queried boolean.
---@param actorId string
---@return boolean
function Scheduler:autonomousActorLocked(actorId)
  assert(type(actorId) == "string", "actor lock query requires an actor id")
  local envId = self._foregroundEnvironmentId
  if envId == nil then
    return false
  end
  local env = self._environments[envId]
  return env ~= nil and env:lockCount(ScriptEnvironment.LOCK_ACTOR_PREFIX .. actorId) > 0 or false
end

-- --- Accessors -----------------------------------------------------------------

-- Live instances only: the scheduler's own tick work and save capture
-- operate on running state; ended roots are dropped and ended children are
-- archived only while a task observes them.
---@return ScriptInstance[]
function Scheduler:liveInstances()
  local out = {}
  for _, instance in pairs(self._instances) do
    out[#out + 1] = instance
  end
  table.sort(out, function(a, b)
    return a.instanceId < b.instanceId
  end)
  return out
end

-- Live instances plus archived children still observed by a task (the
-- child-task termination checks); a retained ended record is pruned once its
-- observer ends.
---@return ScriptInstance[]
function Scheduler:instances()
  local out = self:liveInstances()
  for _, instance in pairs(self._endedInstances) do
    out[#out + 1] = instance
  end
  table.sort(out, function(a, b)
    return a.instanceId < b.instanceId
  end)
  return out
end

---@return ScriptTask[]
function Scheduler:tasks()
  local out = {}
  for _, task in ipairs(self._tasks) do
    if task.status ~= "cancelled" and not task.consumed then
      out[#out + 1] = task
    end
  end
  return out
end

---@return ScriptEnvironment[]
function Scheduler:environments()
  return self:_orderedEnvironments()
end

function Scheduler:_orderedEnvironments()
  local out = {}
  if self._foregroundEnvironmentId ~= nil then
    out[#out + 1] = self._environments[self._foregroundEnvironmentId]
  end
  for _, env in ipairs(self._backgrounds) do
    out[#out + 1] = env
  end
  return out
end

---@param instanceId string
---@return ScriptInstance|nil
function Scheduler:instance(instanceId)
  return self._instances[instanceId] or self._endedInstances[instanceId]
end

---@param taskId string
---@return ScriptTask|nil
function Scheduler:taskById(taskId)
  return self._tasksById[taskId]
end

-- The active movement task for one actor in one environment, or nil
-- (two foreground tasks cannot own the same actor).
---@param environmentId string
---@param actorId string
---@return string|nil
function Scheduler:activeMovementForActor(environmentId, actorId)
  for _, task in ipairs(self._tasks) do
    if
      task.status == "active"
      and task.environmentId == environmentId
      and task.taskType == "movement"
      and task.state ~= nil
      and task.state.actor == actorId
    then
      return task.taskId
    end
  end
  return nil
end

---@return string|nil
function Scheduler:foregroundEnvironmentId()
  return self._foregroundEnvironmentId
end

-- The script identity of the foreground environment's root instance, or nil
-- when no foreground environment owns the field. A thin public query over
-- the same instance/environment bookkeeping `createForeground` and
-- `cancelEnvironment` already use, so callers needing failure attribution
-- (diagnostics, acceptance traces) do not read scheduler-private tables.
---@return string|nil
function Scheduler:foregroundScriptId()
  local environmentId = self._foregroundEnvironmentId
  if environmentId == nil then
    return nil
  end
  local environment = self._environments[environmentId]
  local root = environment and environment.rootInstanceId
  local instance = root and self._instances[root]
  return instance and instance.scriptId or nil
end

-- The immutable input snapshot of the current step (the game's dialogue host
-- consumes it from the engine-owned async phase).
---@return table<string, unknown>|nil
function Scheduler:currentInput()
  return self._currentInput
end

-- --- Save hooks -----------------------------------------------------------------

---@return string
function Scheduler:taskRegistryFingerprint()
  return self._taskRegistry:fingerprint()
end

---@param taskType string
---@param version integer
---@return TaskImplementation|nil, Errors.Error|nil
function Scheduler:resolveTask(taskType, version)
  return self._taskRegistry:resolve(taskType, version)
end

function Scheduler:counters()
  return {
    nextEnvironmentId = self._nextEnvironmentId,
    nextInstanceId = self._nextInstanceId,
    nextTaskId = self._nextTaskId,
  }
end

-- Rebuild the scheduler's script state from a ScriptSave scripts bucket.
-- The restore tick is the load boundary: the caller
-- resumes with the first step at restoreTick + 1, so relative delays rebase
-- exactly and no tick is duplicated or skipped. The caller is responsible
-- for the whole-bucket and registry/task-registry fingerprint checks
-- (ScriptSave.restore performs them); this method verifies every frame's
-- graph revision against the current compositions, then stages every
-- restored environment, instance, and task as a fresh object and installs
-- them only after the entire bucket has restored, so a raise anywhere in
-- the stage leaves the scheduler idle.
---@param bucket table<string, unknown>
---@param restoreTick integer
function Scheduler:restoreScriptState(bucket, restoreTick)
  assert(self._foregroundEnvironmentId == nil and next(self._instances) == nil, "restore requires an idle scheduler")
  local graphs = {}

  -- Collect graph objects through identities already checked by ScriptSave.
  for _, instanceRecord in ipairs(bucket.instances or {}) do
    for _, frameRecord in ipairs(instanceRecord.frames or {}) do
      local composed = self:resolveComposition(frameRecord.chainScriptId)
      assert(composed and composed.revision == frameRecord.chainRevision, "validated frame chain must resolve")
      local entry = composed.entries[frameRecord.composition.entryIndex + 1]
      assert(entry ~= nil, "validated composition entry must resolve")
      assert(entry.graph.revision == frameRecord.graphRevision, "validated graph revision must resolve")
      graphs[frameRecord.graphRevision] = entry.graph
    end
  end

  -- Stage: restore every record into fresh objects; nothing is installed
  -- until the whole bucket has restored.
  local environments = {}
  local backgrounds = {}
  local foregroundEnvironmentId = nil
  for _, envRecord in ipairs(bucket.environments) do
    local environment = ScriptEnvironment.restore(envRecord, restoreTick)
    environments[environment.environmentId] = environment
    if environment.mode == "foreground" then
      foregroundEnvironmentId = environment.environmentId
    else
      backgrounds[#backgrounds + 1] = environment
    end
  end

  local instances = {}
  for _, instanceRecord in ipairs(bucket.instances) do
    local instance = ScriptInstance.restore(instanceRecord, restoreTick, graphs)
    for _, frame in ipairs(instance.frames) do
      local composed = self:resolveComposition(frame.chainScriptId)
      assert(composed and composed.revision == frame.chainRevision, "frame chain must resolve after the revision check")
      frame.chain = composed.entries
      frame.graph = graphs[frame.graphRevision]
    end
    instances[instance.instanceId] = instance
  end

  local tasks = {}
  local tasksById = {}
  for _, taskRecord in ipairs(bucket.tasks) do
    local task = ScriptTask.restore(taskRecord, restoreTick)
    tasks[#tasks + 1] = task
    tasksById[task.taskId] = task
  end

  -- Publish: install the staged state and the id counters.
  self._environments = environments
  self._backgrounds = backgrounds
  self._foregroundEnvironmentId = foregroundEnvironmentId
  self._instances = instances
  self._tasks = tasks
  self._tasksById = tasksById
  self._nextEnvironmentId = bucket.nextEnvironmentId
  self._nextInstanceId = bucket.nextInstanceId
  self._nextTaskId = bucket.nextTaskId
end

return Scheduler
