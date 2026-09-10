-- Owns producer worker threads, priority scheduling, and serialized publication.

local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

---@class CompilerPool.Node
---@field key string
---@field priority integer
---@field sequence integer
---@field index integer?
---@class CompilerPool.Job
---@field key string
---@field kind string
---@field payload table<string, unknown>
---@field priority integer
---@field sequence integer
---@field state string
---@field node CompilerPool.Node?
---@field details table<string, unknown>?
---@field stageName string?
---@class CompilerPool.Worker
---@field id integer
---@field thread table<string, function>
---@field input table<string, function>
---@field busyKey string?
---@field started boolean
---@class CompilerPool.Completion
---@field record CompilerPool.Job
---@field workerId integer
---@class CompilerPool
---@field versionId string
---@field mode "batch"|"interactive"
---@field developmentRepositoryRoot string?
---@field cacheFs CacheFs
---@field resultChannel table<string, function>
---@field heap CompilerPool.Node[]
---@field jobs table<string, CompilerPool.Job>
---@field workers CompilerPool.Worker[]
---@field completions CompilerPool.Completion[]
---@field sequence integer
---@field nonce integer
---@field closed boolean
---@field fatalError string|Errors.Error?
local CompilerPool = {}
CompilerPool.__index = CompilerPool

local nextNonce = 0
local PUBLICATION_BUDGET = 1

local BOOTSTRAP = [[
local developmentRepositoryRoot, versionId, workerId, inputChannel, resultChannel = ...
if developmentRepositoryRoot ~= nil then
  package.path = developmentRepositoryRoot .. "/?.lua;" .. developmentRepositoryRoot .. "/?/init.lua;" .. package.path
end
local CompilerWorker = require("romdump.src.build.CompilerWorker")
CompilerWorker.run(workerId, versionId, inputChannel, resultChannel)
]]

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

local function popHeap(heap)
  local first = heap[1]
  if not first then
    return nil
  end
  local last = table.remove(heap)
  if last ~= first then
    heap[1] = last
    last.index = 1
    siftDown(heap, 1)
  end
  first.index = nil
  return first
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
  return tostring(value)
end

local function removeStage(cacheFs, stageName)
  if type(stageName) == "string" and stageName ~= "" then
    CacheFs.forArtifactStage(cacheFs.versionId, stageName, cacheFs.backend):removeTree("")
  end
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
    if worker.started then
      pcall(worker.input.push, worker.input, { kind = "stop" })
    end
  end
  for _, worker in ipairs(workers) do
    if worker.started then
      pcall(worker.thread.wait, worker.thread)
    end
  end
end

local function newPool(options)
  assert(type(options) == "table", "compiler pool options are required")
  assert(type(options.versionId) == "string", "compiler pool versionId is required")
  assert(options.mode == "batch" or options.mode == "interactive", "compiler pool mode is invalid")
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
    versionId = options.versionId,
    mode = options.mode,
    developmentRepositoryRoot = options.developmentRepositoryRoot,
    cacheFs = CacheFs.forVersion(options.versionId),
    resultChannel = resultChannel,
    heap = {},
    jobs = {},
    workers = {},
    completions = {},
    sequence = 0,
    nonce = nextNonce,
    closed = false,
    fatalError = nil,
  }, CompilerPool)

  local ok, failure = pcall(function()
    for workerId = 1, workerCount(options.mode) do
      local input = threadApi.newChannel()
      validateChannel(input, "worker input channel")
      local thread = threadApi.newThread(BOOTSTRAP)
      requireFunction(thread.start, "Thread:start")
      requireFunction(thread.wait, "Thread:wait")
      requireFunction(thread.getError, "Thread:getError")
      if thread.isRunning ~= nil then
        requireFunction(thread.isRunning, "Thread:isRunning")
      end
      local worker = { id = workerId, thread = thread, input = input, busyKey = nil, started = false }
      pool.workers[#pool.workers + 1] = worker
      thread:start(options.developmentRepositoryRoot, options.versionId, workerId, input, resultChannel)
      worker.started = true
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

local function assertJob(job)
  assert(type(job) == "table", "compiler job must be a table")
  assert(job.kind == "map", "unsupported compiler job kind: " .. tostring(job.kind))
  assert(type(job.key) == "string" and job.key ~= "", "compiler job key is required")
  assert(type(job.priority) == "number" and job.priority % 1 == 0, "compiler job priority must be an integer")
  assert(type(job.payload) == "table", "compiler job payload is required")
  assert(type(job.payload.mapId) == "number" and job.payload.mapId % 1 == 0, "map job requires an integer mapId")
end

function CompilerPool:request(job)
  assert(not self.closed, "compiler pool is shut down")
  assertJob(job)
  local existing = self.jobs[job.key]
  if existing then
    if existing.state == "failed" then
      error(existing.details and existing.details.error or "compiler job failed", 2)
    end
    if existing.state == "queued" and job.priority < existing.priority then
      existing.priority = job.priority
      existing.node.priority = job.priority
      siftUp(self.heap, existing.node.index)
    end
    return existing.state, existing.details
  end

  self.sequence = self.sequence + 1
  local record = {
    key = job.key,
    kind = job.kind,
    payload = job.payload,
    priority = job.priority,
    sequence = self.sequence,
    state = "queued",
    node = nil,
    details = nil,
  }
  record.node = { key = record.key, priority = record.priority, sequence = record.sequence }
  self.jobs[record.key] = record
  pushHeap(self.heap, record.node)
  return record.state
end

function CompilerPool:retry(key, priority)
  assert(not self.closed, "compiler pool is shut down")
  local record = assert(self.jobs[key], "unknown compiler job: " .. tostring(key))
  assert(record.state == "failed", "only failed compiler jobs can be retried")
  assert(type(priority) == "number" and priority % 1 == 0, "retry priority must be an integer")
  self.sequence = self.sequence + 1
  record.priority = priority
  record.sequence = self.sequence
  record.details = nil
  record.state = "queued"
  record.node = { key = record.key, priority = priority, sequence = self.sequence }
  pushHeap(self.heap, record.node)
  return record.state
end

function CompilerPool:status(key)
  local record = self.jobs[key]
  if not record then
    return "unknown"
  end
  return record.state, record.details
end

function CompilerPool:_idleWorker()
  for _, worker in ipairs(self.workers) do
    if worker.busyKey == nil then
      return worker
    end
  end
  return nil
end

function CompilerPool:_dispatch()
  while true do
    local worker = self:_idleWorker()
    local node = worker and popHeap(self.heap)
    if not worker or not node then
      return
    end
    local record = assert(self.jobs[node.key], "heap references an unknown compiler job")
    assert(record.state == "queued", "heap contains a settled compiler job")
    self.sequence = self.sequence + 1
    local stageName = string.format("run%d-w%d-j%d", self.nonce, worker.id, self.sequence)
    worker.busyKey = record.key
    record.state = "running"
    record.stageName = stageName
    local ok, pushError = pcall(worker.input.push, worker.input, {
      kind = record.kind,
      jobKey = record.key,
      mapId = record.payload.mapId,
      stageName = stageName,
    })
    if not ok then
      worker.busyKey = nil
      record.state = "failed"
      record.details = { error = pushError }
      error(pushError, 0)
    end
  end
end

function CompilerPool:_settleFailure(record, workerId, failure)
  record.state = "failed"
  record.details = { workerId = workerId, error = failure }
end

function CompilerPool:_readFailure(record, message)
  local failure = "worker failed" ---@type string|Errors.Error
  local ok, artifact = pcall(PreparedArtifact.open, {
    cacheFs = self.cacheFs,
    kind = record.kind,
    jobKey = record.key,
    stageName = message.stageName,
  })
  if ok then
    local manifest = artifact:manifest()
    failure = restoreError(manifest.error or failure)
    if artifact:isAbortable() then
      artifact:abort()
    end
  else
    removeStage(self.cacheFs, message.stageName)
  end
  self:_settleFailure(record, message.workerId, failure)
end

function CompilerPool:_collectResults()
  while true do
    local message = self.resultChannel:pop()
    if message == nil then
      return
    end
    assert(type(message) == "table", "worker completion must be a table")
    local record = self.jobs[message.jobKey]
    assert(record, "worker completed an unknown job")
    assert(record.state == "running", "worker completed an already-settled job")
    local worker = self.workers[message.workerId]
    assert(worker and worker.busyKey == record.key, "worker completion ownership mismatch")
    worker.busyKey = nil
    if message.status == "failed" then
      self:_readFailure(record, message)
    elseif message.status == "prepared" then
      assert(message.stageName == record.stageName, "worker completion stage mismatch")
      record.state = "prepared"
      self.completions[#self.completions + 1] = { record = record, workerId = message.workerId }
    else
      error("unknown worker completion status: " .. tostring(message.status), 0)
    end
  end
end

function CompilerPool:_pollWorkerFailures()
  for _, worker in ipairs(self.workers) do
    if worker.busyKey ~= nil then
      local errorText = worker.thread:getError()
      local dead = type(worker.thread.isRunning) == "function" and not worker.thread:isRunning()
      if errorText or dead then
        local record = self.jobs[worker.busyKey]
        removeStage(self.cacheFs, record.stageName)
        self:_settleFailure(record, worker.id, errorText or "compiler worker stopped unexpectedly")
        worker.busyKey = nil
        self.fatalError = errorText or "compiler worker stopped unexpectedly"
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
  local artifact = PreparedArtifact.open({
    cacheFs = self.cacheFs,
    kind = record.kind,
    jobKey = record.key,
    stageName = record.stageName,
  })
  local ok, failure = pcall(artifact.publish, artifact)
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
  end
  return true
end

function CompilerPool:update(publicationBudget)
  assert(not self.closed, "compiler pool is shut down")
  self:_pollWorkerFailures()
  self:_collectResults()
  local budget = publicationBudget or PUBLICATION_BUDGET
  while budget > 0 and self:_publishOne() do
    budget = budget - 1
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
  return false
end

function CompilerPool:_waitForResult()
  self:_pollWorkerFailures()
  if self.fatalError then
    error(self.fatalError, 0)
  end
  local message = self.resultChannel:demand()
  if message ~= nil then
    self.resultChannel:push(message)
  end
end

function CompilerPool:wait(key)
  assert(not self.closed, "compiler pool is shut down")
  local record = assert(self.jobs[key], "unknown compiler job: " .. tostring(key))
  while record.state ~= "ready" and record.state ~= "failed" do
    self:update(math.huge)
    if record.state ~= "ready" and record.state ~= "failed" then
      self:_waitForResult()
    end
  end
  return record.state, record.details
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

function CompilerPool:shutdown()
  if self.closed then
    return true
  end
  for _, node in ipairs(self.heap) do
    local record = self.jobs[node.key]
    record.state = "cancelled"
    record.node = nil
  end
  self.heap = {}
  cleanupWorkers(self.workers)
  self:_collectResults()
  while self:_publishOne() do
  end
  for _, worker in ipairs(self.workers) do
    if worker.busyKey ~= nil then
      local record = self.jobs[worker.busyKey]
      local ok, artifact = pcall(PreparedArtifact.open, {
        cacheFs = self.cacheFs,
        kind = record.kind,
        jobKey = record.key,
        stageName = record.stageName,
      })
      if ok and artifact:isAbortable() then
        artifact:abort()
      elseif not ok then
        removeStage(self.cacheFs, record.stageName)
      end
      self:_settleFailure(record, worker.id, "compiler worker stopped during shutdown")
      worker.busyKey = nil
    end
  end
  self.closed = true
  return true
end

return CompilerPool
