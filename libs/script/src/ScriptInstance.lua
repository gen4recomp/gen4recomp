-- Script instance : one serializable execution of a
-- composed script. The instance owns the frame stack (call frames plus
-- composition frames), instance locals, text argument slots, the low-level
-- compare state, and the scheduler-visible scheduling fields (`readyAtTick`,
-- `lastRunTick`, `waitingTaskId`, `taskResult`, status). Every frame is
-- attributed to its composition entry. Frames and timing
-- capture as relative delays for the save schema. Pure domain
-- module: no love dependency.

local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")

---@class ScriptFrame
---@field graph table<string, unknown>
---@field graphRevision string
---@field nodeId string
---@field returnNodeId string|nil
---@field resultRef unknown|nil
---@field chain table<string, unknown>|nil
---@field chainScriptId string|nil
---@field chainRevision string|nil
---@field args table<string, unknown>|nil
---@field composition table<string, unknown>|nil { entryIndex, operation, owner }

---@class ScriptInstance
---@field instanceId string
---@field environmentId string
---@field contextSlot integer
---@field scriptId string composed public id
---@field revision string effective revision
---@field owner table<string, unknown>
---@field mode string foreground|background
---@field trigger table<string, unknown>|nil
---@field args table<string, unknown>
---@field locals table<string, unknown>
---@field textArgs table<string, unknown>
---@field compare unknown|nil
---@field menuBuilder table<string, unknown>|nil imported HGSS menu construction owned by this instance
---@field frames ScriptFrame[]
---@field waitingTaskId string|nil
---@field taskResult unknown
---@field pendingResultRef unknown|nil
---@field createdAtTick integer
---@field readyAtTick integer
---@field lastRunTick integer|nil
---@field yieldReason string|nil
---@field status string
---@field endReason string|nil
local ScriptInstance = {}
ScriptInstance.__index = ScriptInstance

ScriptInstance.SCHEMA_NAME = "g4-script-instance-v1"

-- The shared instance-status protocol, serialized by ScriptSave: the
-- scheduler writes and compares status through these named constants.
ScriptInstance.STATUSES = {
  ready = "ready",
  running = "running",
  blocked = "blocked",
  resume_pending = "resume_pending",
  completed = "completed",
  faulted = "faulted",
  cancelled = "cancelled",
}

---@class ScriptInstance.CreateSpec
---@field instanceId string
---@field environmentId string
---@field contextSlot integer
---@field scriptId string
---@field revision string
---@field owner table<string, unknown>
---@field mode string
---@field trigger table<string, unknown>|nil
---@field args table<string, unknown>|nil
---@field createdAtTick integer
---@field readyAtTick integer

---@param spec ScriptInstance.CreateSpec
---@return ScriptInstance
function ScriptInstance.new(spec)
  assert(spec and spec.instanceId and spec.environmentId, "instance identity required")
  assert(
    spec.contextSlot ~= nil and spec.contextSlot >= 0 and spec.contextSlot < ScriptEnvironment.SLOT_COUNT,
    "context slot must be within the environment's slot range"
  )
  assert(spec.scriptId and spec.revision, "instance script identity required")
  assert(spec.mode == "foreground" or spec.mode == "background", "instance mode must be foreground or background")
  assert(spec.createdAtTick ~= nil and spec.readyAtTick ~= nil, "instance timing required")
  return setmetatable({
    instanceId = spec.instanceId,
    environmentId = spec.environmentId,
    contextSlot = spec.contextSlot,
    scriptId = spec.scriptId,
    revision = spec.revision,
    owner = spec.owner,
    mode = spec.mode,
    trigger = spec.trigger,
    args = spec.args or {},
    locals = {},
    textArgs = {},
    compare = nil,
    menuBuilder = nil,
    frames = {},
    waitingTaskId = nil,
    taskResult = nil,
    createdAtTick = spec.createdAtTick,
    readyAtTick = spec.readyAtTick,
    lastRunTick = nil,
    yieldReason = nil,
    status = ScriptInstance.STATUSES.ready,
    endReason = nil,
  }, ScriptInstance)
end

-- Push one frame; the top frame is the current execution point.
---@param frame ScriptFrame
function ScriptInstance:pushFrame(frame)
  assert(frame and frame.graph and frame.nodeId, "frame requires graph and nodeId")
  self.frames[#self.frames + 1] = frame
end

-- Build one call/composition frame (the shared shape used by same-graph
-- calls, composed entry frames, and chain advancement). The graph revision
-- always mirrors the graph; the remaining fields default to nil.
---@param graph table<string, unknown>
---@param nodeId string
---@param opts table<string, unknown>|nil { returnNodeId, resultRef, args, chain, chainScriptId,
--- chainRevision, composition }
---@return ScriptFrame
function ScriptInstance:makeFrame(graph, nodeId, opts)
  opts = opts or {}
  return {
    graph = graph,
    graphRevision = graph.revision,
    nodeId = nodeId,
    returnNodeId = opts.returnNodeId,
    resultRef = opts.resultRef,
    args = opts.args,
    chain = opts.chain,
    chainScriptId = opts.chainScriptId,
    chainRevision = opts.chainRevision,
    composition = opts.composition,
  }
end

-- Pop the top frame; returns it, or nil when the stack is empty.
---@return ScriptFrame|nil
function ScriptInstance:popFrame()
  local frame = self.frames[#self.frames]
  self.frames[#self.frames] = nil
  return frame
end

---@return ScriptFrame|nil
function ScriptInstance:topFrame()
  return self.frames[#self.frames]
end

-- Resume the caller after a callee frame is popped: the popped frame carries
-- the caller's continuation (set when the call was made), and the new top
-- frame resumes there.
---@param poppedFrame ScriptFrame
function ScriptInstance:resumeCaller(poppedFrame)
  local top = self:topFrame()
  if top ~= nil and poppedFrame.returnNodeId ~= nil then
    top.nodeId = poppedFrame.returnNodeId
  end
end

-- Release instance-scoped state: text argument slots are cleared when the
-- script instance ends, and temporary locals are not
-- persisted after completion.
function ScriptInstance:clearInstanceState()
  self.textArgs = {}
  self.locals = {}
  self.menuBuilder = nil
end

-- Deterministic capture for the save schema. Absolute scheduling ticks become
-- relative delays rebased at capture time `captureTick`; `lastRunTick` is
-- diagnostic data and is not restored.
---@param captureTick integer
---@return table<string, unknown>
function ScriptInstance:capture(captureTick)
  local frames = {}
  for _, frame in ipairs(self.frames) do
    frames[#frames + 1] = {
      graphScriptId = frame.graph.scriptId,
      graphRevision = frame.graph.revision,
      nodeId = frame.nodeId,
      returnNodeId = frame.returnNodeId,
      resultRef = frame.resultRef,
      args = frame.args,
      composition = frame.composition,
      chainScriptId = frame.chainScriptId,
      chainRevision = frame.chainRevision,
    }
  end
  return {
    instanceId = self.instanceId,
    environmentId = self.environmentId,
    contextSlot = self.contextSlot,
    scriptId = self.scriptId,
    revision = self.revision,
    owner = self.owner,
    mode = self.mode,
    trigger = self.trigger,
    args = self.args,
    locals = self.locals,
    textArgs = self.textArgs,
    compare = self.compare,
    menuBuilder = self.menuBuilder,
    frames = frames,
    waitingTaskId = self.waitingTaskId,
    taskResult = self.taskResult,
    pendingResultRef = self.pendingResultRef,
    createdAtTick = self.createdAtTick,
    createdAtInTicks = self.createdAtTick - captureTick,
    readyInTicks = math.max(0, self.readyAtTick - captureTick),
    yieldReason = self.yieldReason,
    status = self.status,
    endReason = self.endReason,
  }
end

-- Rebuild an instance from the save schema. `restoreTick` rebases the ready
-- deadline and the creation tick; the caller reattaches graphs by revision
-- and reconnects environment and task references.
---@param record table<string, unknown>
---@param restoreTick integer
---@param graphs table<string, table<string, unknown>> graphRevision -> graph
---@return ScriptInstance
function ScriptInstance.restore(record, restoreTick, graphs)
  assert(record and record.instanceId, "instance record required")
  assert(ScriptInstance.STATUSES[record.status] ~= nil, "unknown instance status " .. tostring(record.status))
  local instance = ScriptInstance.new({
    instanceId = record.instanceId,
    environmentId = record.environmentId,
    contextSlot = record.contextSlot,
    scriptId = record.scriptId,
    revision = record.revision,
    owner = record.owner,
    mode = record.mode,
    trigger = record.trigger,
    args = record.args or {},
    createdAtTick = restoreTick + (record.createdAtInTicks or 0),
    readyAtTick = restoreTick + (record.readyInTicks or 0),
  })
  instance.locals = record.locals or {}
  instance.textArgs = record.textArgs or {}
  instance.compare = record.compare
  instance.menuBuilder = record.menuBuilder
  instance.waitingTaskId = record.waitingTaskId
  instance.taskResult = record.taskResult
  instance.pendingResultRef = record.pendingResultRef
  instance.yieldReason = record.yieldReason
  instance.status = record.status
  instance.endReason = record.endReason
  for _, frameRecord in ipairs(record.frames or {}) do
    local graph = graphs[frameRecord.graphRevision]
    assert(graph ~= nil, "save references an unknown graph revision: " .. tostring(frameRecord.graphRevision))
    local frame = {
      graph = graph,
      graphRevision = frameRecord.graphRevision,
      nodeId = frameRecord.nodeId,
      returnNodeId = frameRecord.returnNodeId,
      resultRef = frameRecord.resultRef,
      args = frameRecord.args,
      composition = frameRecord.composition,
      chainScriptId = frameRecord.chainScriptId,
      chainRevision = frameRecord.chainRevision,
    }
    instance.frames[#instance.frames + 1] = frame
  end
  return instance
end

-- Collect every graph revision referenced by the instance frames (for save
-- revision checks).
---@return string[]
function ScriptInstance:graphRevisions()
  local out = {}
  for _, frame in ipairs(self.frames) do
    out[#out + 1] = frame.graph.revision
  end
  return out
end

return ScriptInstance
