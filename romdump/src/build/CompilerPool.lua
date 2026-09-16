-- Owns producer worker threads, priority scheduling, and serialized publication.
-- A process-owned pool admits canonical jobs for one selected game version and
-- generation epoch at a time. Each job carries its explicit version,
-- generation, epoch, kind, key, priority, and size class. Physical worker
-- occupancy is tracked separately from queued interest so retiring a game
-- epoch never frees a still-executing worker.

local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

---@class CompilerPool.Node
---@field key string
---@field priority integer
---@field sequence integer
---@field index integer?
---@class CompilerPool.Job
---@field versionId string
---@field generationId string
---@field epoch integer
---@field kind string
---@field key string
---@field jobKey string
---@field priority integer
---@field sizeClass string
---@field payload table<string, unknown>
---@field sequence integer
---@field state string
---@field node CompilerPool.Node?
---@field details table<string, unknown>?
---@field stageName string?
---@field workerId integer?
---@field timing table<string, unknown>?
---@field retired boolean?
---@class CompilerPool.Worker
---@field id integer
---@field thread table<string, function>
---@field input table<string, function>
---@field slot CompilerPool.Job?
---@field retiring boolean
---@field started boolean
---@field joined boolean
---@field closeSent boolean
---@field closeAcked boolean
---@field closeAfter boolean
---@field closeToken integer?
---@class CompilerPool.Completion
---@field record CompilerPool.Job
---@field workerId integer
---@class CompilerPool.Selected
---@field versionId string
---@field generationId string
---@field epoch integer
---@class CompilerPool
---@field mode "batch"|"interactive"
---@field developmentRepositoryRoot string?
---@field selected CompilerPool.Selected?
---@field selectedCacheFs CacheFs?
---@field resultChannel table<string, function>
---@field heap CompilerPool.Node[]
---@field jobs table<string, CompilerPool.Job>
---@field workers CompilerPool.Worker[]
---@field completions CompilerPool.Completion[]
---@field sequence integer
---@field nonce integer
---@field closed boolean
---@field quiescing boolean
---@field closeToken integer?
---@field retired boolean
---@field fatalError string|Errors.Error?
---@field recentTimings table<string, unknown>[]
local CompilerPool = {}
CompilerPool.__index = CompilerPool

local nextNonce = 0
local PUBLICATION_BUDGET = 1
local WAIT_TIMEOUT_SECONDS = 0.5
local MAX_RECENT_TIMINGS = 32

local BOOTSTRAP = [[
local developmentRepositoryRoot, workerId, inputChannel, resultChannel = ...
if developmentRepositoryRoot ~= nil then
  package.path = developmentRepositoryRoot .. "/?.lua;" .. developmentRepositoryRoot .. "/?/init.lua;" .. package.path
end
local CompilerWorker = require("romdump.src.build.CompilerWorker")
CompilerWorker.run(workerId, inputChannel, resultChannel)
]]

local FIXED_PRIORITIES = {
  [0] = true,
  [10] = true,
  [100] = true,
}

local SIZE_CLASSES = {
  normal = true,
  heavy = true,
  jumbo = true,
}

local function before(a, b)
  return a.priority < b.priority or (a.priority == b.priority and a.sequence < b.sequence)
end

---@param heap CompilerPool.Node[]
---@param left integer
---@param right integer
local function swap(heap, left, right)
  local leftNode = assert(heap[left])
  local rightNode = assert(heap[right])
  heap[left], heap[right] = rightNode, leftNode
  leftNode.index = right
  rightNode.index = left
end

---@param heap CompilerPool.Node[]
---@param index integer
local function siftUp(heap, index)
  while index > 1 do
    local parent = math.floor(index / 2)
    if before(heap[parent], heap[index]) then
      break
    end
    swap(heap, parent, index)
    index = parent
  end
end

local function siftDown(heap, index)
  local size = #heap
  while true do
    local left = index * 2
    if left > size then
      return
    end
    local right = left + 1
    local child = left
    if right <= size and before(heap[right], heap[left]) then
      child = right
    end
    if before(heap[index], heap[child]) then
      return
    end
    swap(heap, index, child)
    index = child
  end
end

---@param heap CompilerPool.Node[]
---@param node CompilerPool.Node
local function pushHeap(heap, node)
  local index = #heap + 1
  node.index = index
  heap[index] = node
  siftUp(heap, index)
end

---@param heap CompilerPool.Node[]
---@param index integer
---@return CompilerPool.Node?
local function removeHeapAt(heap, index)
  local node = heap[index]
  if not node then
    return nil
  end
  local last = table.remove(heap)
  if last ~= node then
    heap[index] = last
    last.index = index
    siftUp(heap, index)
    siftDown(heap, index)
  end
  node.index = nil
  return node
end

local function requireFunction(value, name)
  if type(value) ~= "function" then
    error("unsupported compiler pool capability: missing " .. name, 3)
  end
end

---@param value unknown
---@return string|Errors.Error
local function restoreError(value)
  if type(value) == "table" and type(value.code) == "string" and type(value.message) == "string" then
    return Errors.new(value.code, value.message, value.context)
  end
  -- A staged failure without a code carries only a message; surface the
  -- message itself, never the wrapper table's address.
  if type(value) == "table" and type(value.message) == "string" then
    return value.message
  end
  return tostring(value)
end

local function validateChannel(channel, name)
  assert(channel, "unsupported compiler pool capability: love.thread " .. name .. " is missing")
  requireFunction(channel.push, "love.thread " .. name .. ":push")
  requireFunction(channel.pop, "love.thread " .. name .. ":pop")
  requireFunction(channel.demand, "love.thread " .. name .. ":demand")
  requireFunction(channel.getCount, "love.thread " .. name .. ":getCount")
end

local function processorCount()
  local host = rawget(_G, "love")
  if host and host.system and type(host.system.getProcessorCount) == "function" then
    local count = host.system.getProcessorCount()
    if type(count) == "number" and count >= 1 then
      return math.floor(count)
    end
  end
  return 1
end

local function workerCount(mode)
  local spare = processorCount() - 1
  if mode == "interactive" then
    return math.max(1, math.min(4, math.floor(spare / 2)))
  end
  return math.max(1, math.min(8, spare))
end

local function cleanupWorkers(workers)
  for _, worker in ipairs(workers) do
    if worker.started and not worker.joined then
      pcall(worker.input.push, worker.input, { kind = "stop" })
    end
  end
  for _, worker in ipairs(workers) do
    if worker.started and not worker.joined then
      pcall(worker.thread.wait, worker.thread)
      worker.joined = true
    end
  end
end

---@param resultChannel table<string, function>
---@param workerId integer
---@param developmentRepositoryRoot string?
---@return CompilerPool.Worker
local function startWorker(resultChannel, workerId, developmentRepositoryRoot)
  local host = rawget(_G, "love")
  local threadApi = host and host.thread
  assert(type(threadApi) == "table", "unsupported compiler pool capability: love.thread is required")
  requireFunction(threadApi.newThread, "love.thread.newThread")
  requireFunction(threadApi.newChannel, "love.thread.newChannel")
  local input = threadApi.newChannel()
  validateChannel(input, "worker input channel")
  local thread = threadApi.newThread(BOOTSTRAP)
  requireFunction(thread.start, "Thread:start")
  requireFunction(thread.wait, "Thread:wait")
  requireFunction(thread.getError, "Thread:getError")
  if thread.isRunning ~= nil then
    requireFunction(thread.isRunning, "Thread:isRunning")
  end
  local worker = {
    id = workerId,
    thread = thread,
    input = input,
    slot = nil,
    retiring = false,
    started = false,
    joined = false,
    closeSent = false,
    closeAcked = false,
    closeAfter = false,
    closeToken = nil,
  }
  thread:start(developmentRepositoryRoot, workerId, input, resultChannel)
  worker.started = true
  return worker
end

---@param options table<string, unknown>
---@return CompilerPool
local function newPool(options)
  assert(type(options) == "table", "compiler pool options are required")
  assert(options.mode == "batch" or options.mode == "interactive", "compiler pool mode is invalid")
  if options.versionId ~= nil then
    assert(type(options.versionId) == "string", "compiler pool versionId must be a string")
  end
  local host = rawget(_G, "love")
  local threadApi = host and host.thread
  if type(threadApi) ~= "table" then
    error("unsupported compiler pool capability: love.thread is required", 2)
  end
  requireFunction(threadApi.newThread, "love.thread.newThread")
  requireFunction(threadApi.newChannel, "love.thread.newChannel")

  local resultChannel = threadApi.newChannel()
  validateChannel(resultChannel, "result channel")
  nextNonce = nextNonce + 1
  local pool = setmetatable({
    mode = options.mode,
    developmentRepositoryRoot = options.developmentRepositoryRoot,
    selected = nil,
    selectedCacheFs = nil,
    resultChannel = resultChannel,
    heap = {},
    jobs = {},
    workers = {},
    completions = {},
    sequence = 0,
    nonce = nextNonce,
    closed = false,
    quiescing = false,
    closeToken = nil,
    retired = false,
    fatalError = nil,
    recentTimings = {},
  }, CompilerPool)

  local ok, failure = pcall(function()
    for workerId = 1, workerCount(options.mode) do
      pool.workers[#pool.workers + 1] = startWorker(resultChannel, workerId, options.developmentRepositoryRoot)
    end
  end)
  if not ok then
    cleanupWorkers(pool.workers)
    error(failure, 0)
  end
  return pool
end

function CompilerPool.new(options)
  return newPool(options)
end

---@param identity table<string, unknown>
---@param epoch integer
function CompilerPool:selectGeneration(identity, epoch)
  assert(not self.closed, "compiler pool is shut down")
  assert(type(identity) == "table", "compiler pool generation identity is required")
  assert(type(identity.versionId) == "string" and identity.versionId ~= "", "compiler pool versionId is required")
  assert(
    type(identity.generationId) == "string" and identity.generationId ~= "",
    "compiler pool generationId is required"
  )
  assert(type(epoch) == "number" and epoch % 1 == 0 and epoch >= 1, "compiler pool epoch must be a positive integer")
  local current = self.selected
  if
    current
    and current.versionId == identity.versionId
    and current.generationId == identity.generationId
    and current.epoch == epoch
  then
    return
  end
  if self.quiescing and not self:isQuiescent() then
    error("compiler pool quiescence barrier is incomplete", 0)
  end
  for _, node in ipairs(self.heap) do
    local record = self.jobs[node.key]
    if record then
      record.state = "cancelled"
      record.node = nil
    end
  end
  self.heap = {}
  for _, completion in ipairs(self.completions) do
    self:_abortStage(completion.record)
    if self.jobs[completion.record.jobKey] == completion.record then
      completion.record.state = "cancelled"
    end
    -- A prepared heavy/jumbo result pins its worker until publication drains
    -- it. Dropping the completion queue must release that pin: the worker
    -- would otherwise stay busy forever behind a cancelled record, and the
    -- jumbo exclusivity rule would block all future jumbo dispatch.
    self:_freeSlot(completion.record, completion.workerId)
  end
  self.completions = {}
  -- Running slots stay physically busy under their old identity but leave the
  -- selected lookup, so an equal kind:key requested for the new epoch is new
  -- interest rather than a promotion of the retired record.
  self.jobs = {}
  self.selected = { versionId = identity.versionId, generationId = identity.generationId, epoch = epoch }
  self.selectedCacheFs = CacheFs.forVersion(identity.versionId)
  self.quiescing = false
  self.retired = false
  for _, worker in ipairs(self.workers) do
    worker.closeSent = false
    worker.closeAcked = false
    worker.closeAfter = false
    worker.closeToken = nil
  end
  -- A completed barrier may have joined exiting workers without restarting
  -- them; recreate that capacity for the new owner.
  for _, worker in ipairs(self.workers) do
    if worker.joined then
      local ok, replacement = pcall(startWorker, self.resultChannel, worker.id, self.developmentRepositoryRoot)
      if not ok then
        self.fatalError = restoreError(replacement)
        error(replacement, 0)
      end
      self.workers[worker.id] = replacement
    end
  end
end

---@param epoch integer
---@return boolean
function CompilerPool:retireSelection(epoch)
  assert(not self.closed, "compiler pool is shut down")
  local selected = self.selected
  if selected == nil or self.retired then
    return false
  end
  assert(type(epoch) == "number" and epoch % 1 == 0, "compiler pool epoch must be an integer")
  if epoch ~= selected.epoch then
    return false
  end
  -- Logical interest is cancelled; executing physical slots stay charged
  -- under their old identity until their terminal reply or joined exit.
  self.retired = true
  for _, node in ipairs(self.heap) do
    local record = self.jobs[node.key]
    if record then
      record.state = "cancelled"
      record.node = nil
    end
  end
  self.heap = {}
  for _, completion in ipairs(self.completions) do
    self:_abortStage(completion.record)
    if self.jobs[completion.record.jobKey] == completion.record then
      completion.record.state = "cancelled"
    end
    self:_freeSlot(completion.record, completion.workerId)
  end
  self.completions = {}
  return true
end

local function assertJobShape(job, selected)
  assert(type(job) == "table", "compiler job must be a table")
  assert(type(job.versionId) == "string" and job.versionId ~= "", "compiler job versionId is required")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "compiler job generationId is required")
  assert(type(job.epoch) == "number" and job.epoch % 1 == 0, "compiler job epoch must be an integer")
  assert(ArtifactState.KINDS[job.kind], "unsupported compiler job kind: " .. tostring(job.kind))
  assert(type(job.key) == "string" and job.key ~= "", "compiler job key is required")
  ArtifactState.path(job.kind, job.key)
  assert(type(job.jobKey) == "string" and job.jobKey ~= "", "compiler job jobKey is required")
  assert(job.jobKey == job.kind .. ":" .. job.key, "compiler job identity must match its kind and key")
  assert(
    type(job.priority) == "number" and job.priority % 1 == 0 and FIXED_PRIORITIES[job.priority],
    "compiler job priority must be 0, 10, or 100"
  )
  assert(SIZE_CLASSES[job.sizeClass], "compiler job sizeClass must be normal, heavy, or jumbo")
  assert(type(job.payload) == "table", "compiler job payload is required")
  if selected then
    assert(job.versionId == selected.versionId, "compiler job version does not match the selected generation")
    assert(job.generationId == selected.generationId, "compiler job generation does not match the selected generation")
    assert(job.epoch == selected.epoch, "compiler job epoch does not match the selected generation")
  end
  if job.kind == "map" then
    assert(type(job.payload.mapId) == "number" and job.payload.mapId % 1 == 0, "map job requires an integer mapId")
  elseif job.kind == "field-cell" then
    for _, key in ipairs({
      "matrixMemberId",
      "index",
      "x",
      "z",
      "mapHeaderId",
      "altitude",
      "landDataMemberId",
      "areaDataMemberId",
    }) do
      assert(type(job.payload[key]) == "number" and job.payload[key] % 1 == 0, "field-cell job requires " .. key)
    end
  elseif job.kind == "script-member" then
    assert(
      type(job.payload.memberId) == "number" and job.payload.memberId % 1 == 0,
      "script member job requires an integer memberId"
    )
    assert(
      type(job.payload.generationKey) == "string" and job.payload.generationKey ~= "",
      "script member generation is required"
    )
  end
end

function CompilerPool:request(job)
  assert(not self.closed, "compiler pool is shut down")
  if self.fatalError then
    error(self.fatalError, 0)
  end
  assert(not self.quiescing, "compiler pool is quiescing")
  assert(not self.retired, "compiler pool selection is retired")
  local selected = assert(self.selected, "compiler pool has no selected generation")
  assertJobShape(job, selected)
  local existing = self.jobs[job.jobKey]
  if existing then
    if existing.state == "failed" then
      error(existing.details and existing.details.error or "compiler job failed", 2)
    end
    if existing.state == "cancelled" then
      self.jobs[job.jobKey] = nil
    else
      if existing.state == "queued" and job.priority < existing.priority then
        existing.priority = job.priority
        existing.node.priority = job.priority
        siftUp(self.heap, existing.node.index)
      end
      return existing.state, existing.details
    end
  end

  self.sequence = self.sequence + 1
  local record = {
    versionId = job.versionId,
    generationId = job.generationId,
    epoch = job.epoch,
    key = job.key,
    kind = job.kind,
    jobKey = job.jobKey,
    payload = job.payload,
    priority = job.priority,
    sizeClass = job.sizeClass,
    sequence = self.sequence,
    state = "queued",
    node = nil,
    details = nil,
  }
  record.node = { key = record.jobKey, priority = record.priority, sequence = record.sequence }
  self.jobs[record.jobKey] = record
  pushHeap(self.heap, record.node)
  return record.state
end

function CompilerPool:retry(jobKey, priority)
  assert(not self.closed, "compiler pool is shut down")
  if self.fatalError then
    error(self.fatalError, 0)
  end
  assert(not self.quiescing, "compiler pool is quiescing")
  assert(not self.retired, "compiler pool selection is retired")
  local record = assert(self.jobs[jobKey], "unknown compiler job: " .. tostring(jobKey))
  assert(record.state == "failed", "only failed compiler jobs can be retried")
  assert(
    type(priority) == "number" and priority % 1 == 0 and FIXED_PRIORITIES[priority],
    "retry priority must be 0, 10, or 100"
  )
  self.sequence = self.sequence + 1
  record.priority = priority
  record.sequence = self.sequence
  record.details = nil
  record.state = "queued"
  record.node = { key = record.jobKey, priority = priority, sequence = self.sequence }
  pushHeap(self.heap, record.node)
  return record.state
end

---@param jobKey string
---@return string
---@return table<string, unknown>?
function CompilerPool:status(jobKey)
  local record = self.jobs[jobKey]
  if not record then
    return "unknown"
  end
  if record.state == "queued" then
    local reason = self:_admissionBlockReason(record)
    if reason then
      return record.state, { waitingOn = reason }
    end
  end
  return record.state, record.details
end

---@param jobKey string
---@return table<string, unknown>|nil
function CompilerPool:jobOutcome(jobKey)
  local record = self.jobs[jobKey]
  if record == nil then
    return nil
  end
  local workerId = record.workerId
  if workerId == nil and type(record.details) == "table" then
    local detailWorker = record.details.workerId
    if type(detailWorker) == "number" then
      workerId = detailWorker
    end
  end
  local snapshot = {
    jobKey = record.jobKey,
    generationId = record.generationId,
    epoch = record.epoch,
    state = record.state,
  }
  if workerId ~= nil then
    snapshot.workerId = workerId
  end
  if record.state == "failed" and type(record.details) == "table" and record.details.error ~= nil then
    snapshot.error = record.details.error
  end
  if type(record.timing) == "table" then
    snapshot.compileSeconds = record.timing.compileSeconds
    snapshot.stageSeconds = record.timing.stageSeconds
    snapshot.workSeconds = record.timing.workSeconds
    snapshot.stagedBytes = record.timing.stagedBytes
    snapshot.timingReason = record.timing.timingReason
  end
  return snapshot
end

---@param record CompilerPool.Job
---@return string?
function CompilerPool:_admissionBlockReason(record)
  if self.fatalError then
    return "infrastructure-failure"
  end
  if self.quiescing then
    return "quiescing"
  end
  if self:_runningCount() + #self.completions > #self.workers then
    return "prepared-backpressure"
  end
  local heavyActive, jumboActive = self:_activeSizes()
  if record.sizeClass == "jumbo" then
    if jumboActive > 0 or heavyActive > 0 then
      return "active-job"
    end
    for _, worker in ipairs(self.workers) do
      if worker.slot ~= nil or worker.retiring then
        return "active-job"
      end
    end
    return nil
  end
  if jumboActive > 0 then
    return "active-job"
  end
  if record.sizeClass == "heavy" and heavyActive > 0 then
    return "active-job"
  end
  local root = self.heap[1]
  if root and root.key ~= record.jobKey then
    local rootRecord = self.jobs[root.key]
    if rootRecord and rootRecord.sizeClass == "jumbo" and rootRecord.priority <= record.priority then
      local allIdle = true
      for _, worker in ipairs(self.workers) do
        if worker.slot ~= nil or worker.retiring then
          allIdle = false
          break
        end
      end
      if not allIdle then
        return "reserved-for-jumbo"
      end
    end
  end
  local idle = false
  for _, worker in ipairs(self.workers) do
    if worker.slot == nil and not worker.retiring then
      idle = true
      break
    end
  end
  if not idle then
    return "active-job"
  end
  return nil
end

---@return integer, integer
function CompilerPool:_activeSizes()
  local heavy, jumbo = 0, 0
  local seen = {}
  local function count(record)
    if record == nil or seen[record] then
      return
    end
    seen[record] = true
    if record.state == "running" then
      if record.sizeClass == "heavy" then
        heavy = heavy + 1
      elseif record.sizeClass == "jumbo" then
        jumbo = jumbo + 1
      end
    elseif record.state == "prepared" and not record.retired then
      -- A prepared heavy/jumbo result keeps counting until publication drains
      -- it. Normal results join the bounded backlog without holding activity,
      -- and a recycled jumbo worker's queued result no longer blocks admission.
      if record.sizeClass == "heavy" then
        heavy = heavy + 1
      elseif record.sizeClass == "jumbo" then
        jumbo = jumbo + 1
      end
    end
  end
  for _, record in pairs(self.jobs) do
    count(record)
  end
  -- Detached slots from a retired epoch stay physically busy and keep counting
  -- against size admission until their completion or termination is observed.
  for _, worker in ipairs(self.workers) do
    count(worker.slot)
  end
  return heavy, jumbo
end

---@return integer
function CompilerPool:_runningCount()
  local running = 0
  for _, worker in ipairs(self.workers) do
    if worker.slot ~= nil then
      running = running + 1
    end
  end
  return running
end

---@param versionId string
---@return CacheFs
function CompilerPool:_cacheFsFor(versionId)
  if self.selected and self.selectedCacheFs and versionId == self.selected.versionId then
    return self.selectedCacheFs
  end
  return CacheFs.forVersion(versionId)
end

---@param record CompilerPool.Job
function CompilerPool:_abortStage(record)
  if type(record.stageName) ~= "string" or record.stageName == "" then
    return
  end
  local ok, artifact = pcall(PreparedArtifact.open, {
    cacheFs = self:_cacheFsFor(record.versionId),
    generationId = record.generationId,
    epoch = record.epoch,
    kind = record.kind,
    key = record.key,
    jobKey = record.jobKey,
    stageName = record.stageName,
  })
  if ok and artifact:isAbortable() then
    pcall(artifact.abort, artifact)
  end
end

---@param worker CompilerPool.Worker
---@return boolean
local function workerIdle(worker)
  return worker.started and not worker.joined and worker.slot == nil and not worker.retiring
end

function CompilerPool:_eligibleRecord()
  if self.quiescing or #self.heap == 0 then
    return nil
  end
  if self:_runningCount() + #self.completions > #self.workers then
    return nil
  end
  local heavyActive, jumboActive = self:_activeSizes()
  local ordered = {}
  for _, node in ipairs(self.heap) do
    ordered[#ordered + 1] = node
  end
  table.sort(ordered, before)
  local rootRecord = self.jobs[ordered[1].key]
  local reserveJumbo = false
  if rootRecord and rootRecord.sizeClass == "jumbo" then
    local allIdle = true
    for _, worker in ipairs(self.workers) do
      if not workerIdle(worker) then
        allIdle = false
        break
      end
    end
    if not allIdle or heavyActive > 0 or jumboActive > 0 then
      reserveJumbo = true
    end
  end
  for _, node in ipairs(ordered) do
    local record = self.jobs[node.key]
    if record and record.state == "queued" then
      if record.sizeClass == "jumbo" then
        local allIdle = true
        for _, worker in ipairs(self.workers) do
          if not workerIdle(worker) then
            allIdle = false
            break
          end
        end
        if allIdle and heavyActive == 0 and jumboActive == 0 then
          return record
        end
      else
        if jumboActive == 0 then
          if record.sizeClass == "heavy" and heavyActive > 0 then
            -- At most one heavy job executes at a time.
          elseif reserveJumbo and rootRecord and record.priority >= rootRecord.priority then
            -- The drained window is reserved for the waiting jumbo job unless
            -- higher-priority work arrives first.
          else
            for _, worker in ipairs(self.workers) do
              if workerIdle(worker) then
                return record
              end
            end
            return nil
          end
        end
      end
    end
  end
  return nil
end

---@param record CompilerPool.Job
---@return CompilerPool.Worker?
function CompilerPool:_idleWorkerFor(record)
  if record.sizeClass == "jumbo" then
    local first = self.workers[1]
    if first and workerIdle(first) then
      return first
    end
    return nil
  end
  for _, worker in ipairs(self.workers) do
    if workerIdle(worker) then
      return worker
    end
  end
  return nil
end

---@param versionId string
---@param workerId integer
---@param sequence integer
---@return string
function CompilerPool:_allocateStageName(versionId, workerId, sequence)
  -- The process-local run/worker/job counter can collide with a stage left
  -- behind by an interrupted earlier process. Advance a private allocation
  -- suffix past existing names without touching the logical FIFO sequence
  -- and without removing, adopting, or overwriting the old stage.
  local suffix = 0
  while true do
    local name = string.format("run%d-w%d-j%d", self.nonce, workerId, sequence)
    if suffix > 0 then
      name = name .. "-s" .. tostring(suffix)
    end
    if not CacheFs.forArtifactStage(versionId, name):exists("") then
      return name
    end
    suffix = suffix + 1
  end
end

function CompilerPool:_dispatch()
  while true do
    local record = self:_eligibleRecord()
    if not record then
      return
    end
    local worker = self:_idleWorkerFor(record)
    if not worker then
      return
    end
    assert(record.node and record.node.index, "queued compiler job is missing its heap position")
    removeHeapAt(self.heap, record.node.index)
    record.node = nil
    self.sequence = self.sequence + 1
    local stageName = self:_allocateStageName(record.versionId, worker.id, self.sequence)
    record.state = "running"
    record.stageName = stageName
    record.workerId = worker.id
    worker.slot = record
    local ok, pushError = pcall(worker.input.push, worker.input, {
      kind = record.kind,
      key = record.key,
      jobKey = record.jobKey,
      versionId = record.versionId,
      generationId = record.generationId,
      epoch = record.epoch,
      sizeClass = record.sizeClass,
      payload = record.payload,
      producerFingerprint = record.payload.producerFingerprint,
      mapId = record.payload.mapId,
      matrixMemberId = record.payload.matrixMemberId,
      index = record.payload.index,
      x = record.payload.x,
      z = record.payload.z,
      mapHeaderId = record.payload.mapHeaderId,
      altitude = record.payload.altitude,
      landDataMemberId = record.payload.landDataMemberId,
      areaDataMemberId = record.payload.areaDataMemberId,
      memberId = record.payload.memberId,
      generationKey = record.payload.generationKey,
      bankId = record.payload.bankId,
      pageKind = record.payload.pageKind,
      pageId = record.payload.pageId,
      stageName = stageName,
    })
    if not ok then
      worker.slot = nil
      record.state = "failed"
      record.details = { error = pushError }
      record.stageName = nil
      record.workerId = nil
      self.fatalError = pushError
      error(pushError, 0)
    end
  end
end

function CompilerPool:_settleFailure(record, workerId, failure)
  record.state = "failed"
  record.details = { workerId = workerId, error = failure }
end

---@param message table<string, unknown>
---@param reason string
---@noreturn
function CompilerPool:_stopWithProtocolFailure(message, reason)
  local failure = "compiler protocol failure: " .. reason
  if type(message) == "table" and message.jobKey ~= nil then
    failure = failure .. " for " .. tostring(message.jobKey)
  end
  self.fatalError = failure
  error(failure, 0)
end

---@param record CompilerPool.Job
---@param message table<string, unknown>
function CompilerPool:_readFailure(record, message)
  local failure = "worker failed" ---@type string|Errors.Error
  local stageName = message.stageName
  local opened = false
  if type(stageName) == "string" and stageName ~= "" then
    local ok, artifact = pcall(PreparedArtifact.open, {
      cacheFs = self:_cacheFsFor(record.versionId),
      generationId = record.generationId,
      epoch = record.epoch,
      kind = record.kind,
      key = record.key,
      jobKey = record.jobKey,
      stageName = stageName,
    })
    if ok then
      opened = true
      local manifest = artifact:manifest()
      failure = restoreError(manifest.error or failure)
      if artifact:isAbortable() then
        artifact:abort()
      end
    end
  end
  if not opened then
    failure = restoreError(failure)
  end
  self:_settleFailure(record, message.workerId, failure)
end

---@param message table<string, unknown>
---@return table<string, unknown>
local function messageIdentity(message)
  return {
    workerId = message.workerId,
    epoch = message.epoch,
    generationId = message.generationId,
    kind = message.kind,
    key = message.key,
    jobKey = message.jobKey,
    stageName = message.stageName,
  }
end

---@param message table<string, unknown>
function CompilerPool:_acceptMessage(message)
  if type(message) == "table" and message.status == "context-closed" then
    local worker = self.workers[message.workerId]
    -- Only a matching barrier token proves source closure. Stale tokens
    -- from an earlier barrier and unknown senders are ignored, never
    -- mistaken for closure of the current barrier.
    if worker ~= nil and worker.closeSent and message.closeToken == worker.closeToken then
      worker.closeAcked = true
    end
  elseif type(message) == "table" and (message.status == "prepared" or message.status == "failed") then
    self:_acceptCompletion(message)
  else
    self:_stopWithProtocolFailure(message, "unknown worker message")
  end
end

function CompilerPool:_drainAvailable()
  while true do
    local message = self.resultChannel:pop()
    if message == nil then
      break
    end
    self:_acceptMessage(message)
  end
end

function CompilerPool:_collectResults()
  self:_drainAvailable()
  -- Reaping retired workers cannot wait for unrelated message traffic: once
  -- every other job settles, no further completion arrives to trigger the
  -- check above, and jumbo work would stall behind the unreaped worker.
  self:_replaceRetiredWorkers()
end

---@param message table<string, unknown>
function CompilerPool:_acceptCompletion(message)
  assert(type(message) == "table", "worker completion must be a table")
  local workerId = message.workerId
  local worker = self.workers[workerId]
  if type(workerId) ~= "number" or not worker then
    self:_stopWithProtocolFailure(message, "unknown worker")
  end
  assert(worker, "compiler worker is required")
  local slot = worker.slot
  if not slot then
    self:_stopWithProtocolFailure(message, "duplicate completion for an idle worker")
  end
  assert(slot, "compiler worker slot is required")
  local identity = messageIdentity(message)
  if
    identity.workerId ~= worker.id
    or identity.epoch ~= slot.epoch
    or identity.generationId ~= slot.generationId
    or identity.kind ~= slot.kind
    or identity.key ~= slot.key
    or identity.jobKey ~= slot.jobKey
    or identity.stageName ~= slot.stageName
  then
    self:_stopWithProtocolFailure(message, "completion does not match its worker slot")
  end
  if slot.state ~= "running" then
    self:_stopWithProtocolFailure(message, "worker completed an already-settled job")
  end
  local selected = self.selected
  local current = selected and self.jobs[slot.jobKey]
  local obsolete = current ~= slot
  if not obsolete then
    if selected == nil or self.retired then
      obsolete = true
    else
      obsolete = slot.generationId ~= selected.generationId
        or slot.epoch ~= selected.epoch
        or slot.versionId ~= selected.versionId
    end
  end
  -- A prepared heavy/jumbo result keeps its worker until publication drains
  -- it. Normal results and recycled workers release the slot at once; the
  -- queued result keeps counting through the finite prepared backlog instead
  -- of a pinned worker.
  local function release()
    worker.slot = nil
    if worker.closeAfter and not message.retiring then
      self:_sendCloseContext(worker)
    end
  end
  if message.status == "failed" then
    release()
    if obsolete then
      self:_abortStage(slot)
      slot.state = "cancelled"
      if message.retiring then
        worker.retiring = true
      end
      return
    end
    self:_readFailure(slot, message)
    if message.retiring then
      worker.retiring = true
    end
    self:_recordTiming(slot, message)
    return
  end
  if obsolete then
    release()
    self:_abortStage(slot)
    slot.state = "cancelled"
    if message.retiring then
      worker.retiring = true
    end
    return
  end
  slot.state = "prepared"
  slot.timing = {
    compileSeconds = message.compileSeconds,
    stageSeconds = message.stageSeconds,
    workSeconds = message.workSeconds,
    stagedBytes = message.stagedBytes,
    timingReason = message.timingReason,
  }
  self.completions[#self.completions + 1] = { record = slot, workerId = worker.id }
  if message.retiring then
    slot.retired = true
    release()
    worker.retiring = true
  elseif slot.sizeClass == "normal" then
    release()
  end
end

---@param record CompilerPool.Job
---@param message table<string, unknown>
function CompilerPool:_recordTiming(record, message)
  record.timing = {
    compileSeconds = message.compileSeconds,
    stageSeconds = message.stageSeconds,
    workSeconds = message.workSeconds,
    stagedBytes = message.stagedBytes,
    timingReason = message.timingReason,
  }
end

---@param worker CompilerPool.Worker
function CompilerPool:_sendCloseContext(worker)
  if worker.closeSent or not worker.started or worker.joined then
    return
  end
  assert(self.closeToken ~= nil, "compiler pool close barrier identity is required")
  local token = self.closeToken
  local ok, sendError = pcall(worker.input.push, worker.input, { kind = "close-context", closeToken = token })
  if not ok then
    self.fatalError = sendError
    error(sendError, 0)
  end
  worker.closeSent = true
  worker.closeToken = token
end

function CompilerPool:_replaceRetiredWorkers()
  for _, worker in ipairs(self.workers) do
    if worker.retiring and not worker.joined then
      local threadError = worker.thread:getError()
      local dead = type(worker.thread.isRunning) == "function" and not worker.thread:isRunning()
      if threadError or dead then
        -- Join exactly once. A failed join is terminal infrastructure
        -- failure, reported like any other replacement failure below.
        local joinOk, joinError = pcall(worker.thread.wait, worker.thread)
        worker.joined = true
        if not joinOk then
          self.fatalError = joinError
          error(joinError, 0)
        end
        -- Never restart while quiescing, shut down, terminally failed, or
        -- without a live selected owner that could use the capacity.
        if
          not self.closed
          and not self.quiescing
          and self.fatalError == nil
          and not self.retired
          and self.selected ~= nil
        then
          local created, replacement = pcall(startWorker, self.resultChannel, worker.id, self.developmentRepositoryRoot)
          if not created then
            self.fatalError = restoreError(replacement)
            error(replacement, 0)
          end
          self.workers[worker.id] = replacement
        end
      end
    end
  end
end

function CompilerPool:_pollWorkerFailures()
  local slotSuspects = {}
  local idleSuspects = {}
  for _, worker in ipairs(self.workers) do
    if not worker.retiring and not worker.joined and worker.started then
      local errorText = worker.thread:getError()
      local dead = type(worker.thread.isRunning) == "function" and not worker.thread:isRunning()
      if errorText or dead then
        if worker.slot ~= nil then
          slotSuspects[#slotSuspects + 1] = { worker = worker, slot = worker.slot }
        else
          idleSuspects[#idleSuspects + 1] = worker
        end
      end
    end
  end
  if #slotSuspects == 0 and #idleSuspects == 0 then
    return
  end
  -- A terminal reply queued ahead of its sender's exit is accepted here,
  -- before any dead observation below may classify that sender.
  self:_drainAvailable()
  for _, suspect in ipairs(slotSuspects) do
    local worker = suspect.worker
    -- Recheck the original physical slot: a later replacement or job must
    -- never inherit this dead observation.
    if self.workers[worker.id] == worker and worker.slot == suspect.slot and suspect.slot.state == "running" then
      local errorText = worker.thread:getError()
      local dead = type(worker.thread.isRunning) == "function" and not worker.thread:isRunning()
      if errorText or dead then
        local record = suspect.slot
        local failure = errorText or "compiler worker stopped unexpectedly"
        self:_settleFailure(record, worker.id, failure)
        worker.slot = nil
        self.fatalError = failure
      end
    end
  end
  for _, worker in ipairs(idleSuspects) do
    if self.workers[worker.id] == worker and worker.slot == nil and not worker.joined then
      local errorText = worker.thread:getError()
      local dead = type(worker.thread.isRunning) == "function" and not worker.thread:isRunning()
      if errorText or dead then
        local failure
        if worker.closeSent and not worker.closeAcked then
          failure = "compiler source close failed: " .. tostring(errorText or "compiler worker stopped unexpectedly")
        else
          failure = errorText or "compiler worker stopped unexpectedly"
        end
        pcall(worker.thread.wait, worker.thread)
        worker.joined = true
        self.fatalError = failure
      end
    end
  end
end

function CompilerPool:_publishOne()
  local completion = table.remove(self.completions, 1)
  if not completion then
    return false
  end
  local record = completion.record
  if record.state ~= "prepared" then
    self:_abortStage(record)
    self:_freeSlot(record, completion.workerId)
    return true
  end
  local openOk, artifact = pcall(PreparedArtifact.open, {
    cacheFs = self:_cacheFsFor(record.versionId),
    generationId = record.generationId,
    epoch = record.epoch,
    kind = record.kind,
    key = record.key,
    jobKey = record.jobKey,
    stageName = record.stageName,
  })
  if not openOk then
    self:_settleFailure(record, completion.workerId, artifact)
    self:_freeSlot(record, completion.workerId)
    return true
  end
  local ok, failure = pcall(artifact.publish, artifact, {
    generationId = record.generationId,
    epoch = record.epoch,
    kind = record.kind,
    key = record.key,
    jobKey = record.jobKey,
    stageName = record.stageName,
  })
  if not ok then
    if artifact:isAbortable() then
      artifact:abort()
    end
    self:_settleFailure(record, completion.workerId, failure)
  else
    local manifest = artifact:manifest()
    record.state = "ready"
    record.details = {
      workerId = completion.workerId,
      result = manifest.result,
      stageName = record.stageName,
    }
    self.recentTimings[#self.recentTimings + 1] = {
      jobKey = record.jobKey,
      workerId = completion.workerId,
      compileSeconds = record.timing and record.timing.compileSeconds,
      stageSeconds = record.timing and record.timing.stageSeconds,
      workSeconds = record.timing and record.timing.workSeconds,
      stagedBytes = record.timing and record.timing.stagedBytes,
      timingReason = record.timing and record.timing.timingReason,
    }
    if #self.recentTimings > MAX_RECENT_TIMINGS then
      table.remove(self.recentTimings, 1)
    end
  end
  self:_freeSlot(record, completion.workerId)
  return true
end

---@param record CompilerPool.Job
---@param workerId integer
function CompilerPool:_freeSlot(record, workerId)
  local worker = self.workers[workerId]
  if worker and worker.slot == record then
    worker.slot = nil
    if worker.closeAfter and not worker.retiring then
      self:_sendCloseContext(worker)
    end
  else
    for _, other in ipairs(self.workers) do
      if other.slot == record then
        other.slot = nil
        if other.closeAfter and not other.retiring then
          self:_sendCloseContext(other)
        end
        break
      end
    end
  end
end

---@param budget number?
function CompilerPool:update(budget)
  assert(not self.closed, "compiler pool is shut down")
  if self.fatalError then
    error(self.fatalError, 0)
  end
  -- Collect worker reports before polling liveness so a completion that
  -- arrived ahead of its worker's exit is accepted on its slot instead of
  -- being mistaken for a death.
  self:_collectResults()
  self:_pollWorkerFailures()
  if self.fatalError then
    error(self.fatalError, 0)
  end
  local remaining = budget
  if remaining == nil then
    remaining = PUBLICATION_BUDGET
  end
  assert(type(remaining) == "number", "publication budget must be a number")
  while remaining > 0 and self:_publishOne() do
    remaining = remaining - 1
  end
  self:_dispatch()
  if self.fatalError then
    error(self.fatalError, 0)
  end
end

function CompilerPool:_hasUnsettled()
  if #self.heap > 0 or #self.completions > 0 then
    return true
  end
  for _, record in pairs(self.jobs) do
    if record.state == "running" or record.state == "prepared" then
      return true
    end
  end
  for _, worker in ipairs(self.workers) do
    if worker.slot ~= nil or worker.retiring then
      return true
    end
  end
  return false
end

function CompilerPool:_waitForResult()
  self:_drainAvailable()
  if self.fatalError then
    error(self.fatalError, 0)
  end
  -- A reply returned by the bounded wait is accepted through the same
  -- validator as nonblocking collection, never pushed back onto the queue.
  local message = self.resultChannel:demand(WAIT_TIMEOUT_SECONDS)
  if message ~= nil then
    self:_acceptMessage(message)
  end
  self:_pollWorkerFailures()
  if self.fatalError then
    error(self.fatalError, 0)
  end
end

---@param jobKey string
---@return string
---@return table<string, unknown>?
function CompilerPool:wait(jobKey)
  assert(not self.closed, "compiler pool is shut down")
  local record = assert(self.jobs[jobKey], "unknown compiler job: " .. tostring(jobKey))
  while record.state ~= "ready" and record.state ~= "failed" and record.state ~= "cancelled" do
    if self.fatalError then
      error(self.fatalError, 0)
    end
    self:update(math.huge)
    if record.state ~= "ready" and record.state ~= "failed" and record.state ~= "cancelled" then
      self:_waitForResult()
    end
  end
  return record.state, record.details
end

function CompilerPool:waitForProgress()
  assert(not self.closed, "compiler pool is shut down")
  self:_waitForResult()
  if self.fatalError then
    error(self.fatalError, 0)
  end
  -- Bounded publication only: never dispatch new work here, and never admit
  -- after retirement or quiescence. Synchronous session callers use this to
  -- drive dependency progress without naming a submitted parent.
  local remaining = PUBLICATION_BUDGET
  while remaining > 0 and self:_publishOne() do
    remaining = remaining - 1
  end
  if self.fatalError then
    error(self.fatalError, 0)
  end
end

function CompilerPool:drain()
  assert(not self.closed, "compiler pool is shut down")
  self:_dispatch()
  while self:_hasUnsettled() do
    self:update(math.huge)
    if self:_hasUnsettled() then
      self:_waitForResult()
    end
  end
  return true
end

function CompilerPool:quiesce()
  assert(not self.closed, "compiler pool is shut down")
  if self.quiescing and self:isQuiescent() then
    return
  end
  self.quiescing = true
  self.closeToken = (self.closeToken or 0) + 1
  for _, node in ipairs(self.heap) do
    local record = self.jobs[node.key]
    if record then
      record.state = "cancelled"
      record.node = nil
    end
  end
  self.heap = {}
  for _, worker in ipairs(self.workers) do
    if worker.joined then
      -- An exited, joined worker needs no acknowledgement: its exit proves
      -- its source context is closed.
    elseif worker.slot == nil and not worker.retiring then
      worker.closeSent = false
      worker.closeAcked = false
      self:_sendCloseContext(worker)
    else
      worker.closeAfter = true
    end
  end
end

---@return boolean
function CompilerPool:isQuiescent()
  if not self.quiescing then
    return false
  end
  if self.fatalError ~= nil then
    return false
  end
  if #self.heap > 0 or #self.completions > 0 then
    return false
  end
  for _, record in pairs(self.jobs) do
    if record.state == "running" or record.state == "prepared" or record.state == "queued" then
      return false
    end
  end
  for _, worker in ipairs(self.workers) do
    if worker.joined then
      -- Joined exit satisfies closure without an acknowledgement.
    elseif worker.slot ~= nil or worker.retiring then
      return false
    elseif not worker.closeAcked then
      return false
    end
  end
  return true
end

---@return table<string, unknown>
function CompilerPool:diagnostics()
  local counts = { queued = 0, running = 0, prepared = 0, ready = 0, failed = 0, cancelled = 0 }
  local sizes = { normal = 0, heavy = 0, jumbo = 0 }
  local active = {}
  for _, record in pairs(self.jobs) do
    if counts[record.state] ~= nil then
      counts[record.state] = counts[record.state] + 1
    end
    if sizes[record.sizeClass] ~= nil then
      sizes[record.sizeClass] = sizes[record.sizeClass] + 1
    end
    if record.state == "running" or record.state == "prepared" then
      active[#active + 1] = record.jobKey
    end
  end
  table.sort(active)
  local selected = nil
  if self.selected then
    selected = {
      versionId = self.selected.versionId,
      generationId = self.selected.generationId,
      epoch = self.selected.epoch,
    }
  end
  local workerStates = {}
  for _, worker in ipairs(self.workers) do
    if worker.slot ~= nil or worker.retiring then
      workerStates[#workerStates + 1] = "w" .. tostring(worker.id) .. ":busy"
    end
  end
  local heapStates = {}
  for index, node in ipairs(self.heap) do
    if index > 12 then
      heapStates[#heapStates + 1] = "+" .. tostring(#self.heap - 12) .. " more"
      break
    end
    local record = self.jobs[node.key]
    if record == nil then
      heapStates[#heapStates + 1] = "orphan"
    else
      heapStates[#heapStates + 1] = tostring(record.state) .. ":" .. tostring(record.sizeClass)
    end
  end
  return {
    mode = self.mode,
    selected = selected,
    quiescing = self.quiescing,
    workerCount = #self.workers,
    counts = counts,
    sizes = sizes,
    activeJobKeys = active,
    workerStates = #workerStates > 0 and table.concat(workerStates, ",") or "idle",
    heapStates = table.concat(heapStates, ","),
    pendingPublications = #self.completions,
    error = self.fatalError,
    recentTimings = self.recentTimings,
  }
end

function CompilerPool:shutdown()
  if self.closed then
    return true
  end
  for _, node in ipairs(self.heap) do
    local record = self.jobs[node.key]
    if record then
      record.state = "cancelled"
      record.node = nil
    end
  end
  self.heap = {}
  for _, worker in ipairs(self.workers) do
    if worker.started and not worker.joined then
      pcall(worker.input.push, worker.input, { kind = "stop" })
    end
  end
  for _, worker in ipairs(self.workers) do
    if worker.started and not worker.joined then
      pcall(worker.thread.wait, worker.thread)
      worker.joined = true
    end
  end
  pcall(function()
    self:_collectResults()
  end)
  while true do
    local ok, more = pcall(function()
      return self:_publishOne()
    end)
    if not ok or not more then
      break
    end
  end
  for _, worker in ipairs(self.workers) do
    if worker.slot ~= nil then
      local record = assert(worker.slot, "compiler worker slot is required")
      pcall(function()
        self:_abortStage(record)
      end)
      if record.state == "running" or record.state == "prepared" then
        record.state = "failed"
        record.details = { workerId = worker.id, error = "compiler worker stopped during shutdown" }
      end
      worker.slot = nil
    end
  end
  self.closed = true
  return true
end

return CompilerPool
