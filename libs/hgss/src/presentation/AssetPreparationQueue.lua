-- One persistent presentation preparation worker behind a two-priority
-- request queue. Cache I/O, mesh decode/validation/upload packing, and image
-- CPU decode run on the worker thread; the main thread only resolves cache
-- paths, polls non-blocking (or waits where its caller already requires a
-- synchronous result), and realizes prepared payloads into GPU objects it
-- owns. Demand requests dispatch ahead of queued prefetch requests, but a
-- running worker job is never preempted. Channel messages stay flat; bulk
-- memory crosses as love Data/ImageData userdata.

---@class AssetPreparationQueue
---@field _cacheFs table<string, unknown>
---@field _request table<string, unknown>
---@field _reply table<string, unknown>
---@field _worker table<string, unknown>
---@field _tokens table<integer, table<string, unknown>>
---@field _demand integer[]
---@field _prefetch integer[]
---@field _active integer?
---@field _nextToken integer
---@field _released boolean
---@field _joined boolean
local AssetPreparationQueue = {}
AssetPreparationQueue.__index = AssetPreparationQueue

local WORKER_MODULE = "libs.hgss.src.presentation.asset_preparation_worker"

local VALID_KINDS = { mesh = true, image = true }
local VALID_PRIORITIES = { demand = true, prefetch = true }

-- Read the worker entry source through the process require path. A LÖVE
-- Thread resolves filenames against the source directory, where this
-- module's sibling file is not visible, so the queue loads the code itself
-- and hands it to the thread as FileData. Plain io keeps this usable
-- alongside injected fake thread hosts (which ignore the argument).
---@return string?
local function loadWorkerCode()
  local relative = WORKER_MODULE:gsub("%.", "/")
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", relative)
    local handle = io.open(candidate, "r")
    if handle then
      local code = handle:read("*a")
      handle:close()
      if code then
        return code
      end
    end
  end
  return nil
end

---@class AssetPreparationQueueOptions
---@field thread table<string, unknown>? injectable love.thread-shaped namespace (defaults to the global one)
---@field workerSource unknown? worker entry point override, passed to the thread constructor

-- cacheFs resolves and confines every logical path on the main thread before
-- dispatch; the worker only ever sees the confined save-relative path.
---@param cacheFs table<string, unknown>
---@param options AssetPreparationQueueOptions?
---@return AssetPreparationQueue
function AssetPreparationQueue.new(cacheFs, options)
  assert(cacheFs and cacheFs.resolve, "AssetPreparationQueue requires a CacheFs-shaped object")
  options = options or {}
  local threadHost = options.thread or (love and love.thread)
  assert(threadHost and threadHost.newChannel and threadHost.newThread, "AssetPreparationQueue requires love.thread")
  local requestChannel = threadHost.newChannel()
  local replyChannel = threadHost.newChannel()
  local workerSource = options.workerSource
  if workerSource == nil then
    local code = assert(loadWorkerCode(), "asset preparation worker source is unavailable")
    if love.filesystem and love.filesystem.newFileData then
      workerSource = love.filesystem.newFileData(code, "asset_preparation_worker.lua")
    else
      workerSource = code
    end
  end
  local worker = threadHost.newThread(workerSource)
  local self = setmetatable({
    _cacheFs = cacheFs,
    _request = requestChannel,
    _reply = replyChannel,
    _worker = worker,
    _tokens = {},
    _demand = {},
    _prefetch = {},
    _active = nil,
    _nextToken = 0,
    _released = false,
    _joined = false,
  }, AssetPreparationQueue)
  worker:start(requestChannel, replyChannel)
  return self
end

-- Drop an already-cancelled head entry; cancellation removes queued tokens
-- eagerly, so this only guards against stale references.
---@param pending integer[]
---@return integer?
function AssetPreparationQueue:_shiftLive(pending)
  while #pending > 0 do
    local token = table.remove(pending, 1)
    if self._tokens[token] then
      return token
    end
  end
  return nil
end

-- Dispatch one job while the worker is idle, choosing queued demand work
-- before queued prefetch work.
function AssetPreparationQueue:_dispatch()
  if self._released or self._active ~= nil then
    return
  end
  local token = self:_shiftLive(self._demand) or self:_shiftLive(self._prefetch)
  if token == nil then
    return
  end
  local record = assert(self._tokens[token], "dispatched an unknown preparation token")
  record.state = "running"
  self._active = token
  self._request:push({ op = "prepare", token = token, kind = record.kind, path = record.path })
end

-- Absorb one worker reply: publish ready/failed state, free the worker, and
-- dispatch the next queued job. Replies for unknown tokens (cancelled,
-- transferred, or released work) are discarded.
---@param response unknown
function AssetPreparationQueue:_absorb(response)
  if type(response) ~= "table" then
    return
  end
  local record = self._tokens[response.token]
  if record == nil then
    return
  end
  if self._active == response.token then
    self._active = nil
  end
  if response.ok then
    record.state = "ready"
    record.payload = {
      vertexData = response.vertexData,
      indexData = response.indexData,
      vertexCount = response.vertexCount,
      indexCount = response.indexCount,
      indexType = response.indexType,
      centerX = response.centerX,
      centerY = response.centerY,
      centerZ = response.centerZ,
      minX = response.minX,
      maxX = response.maxX,
      minY = response.minY,
      maxY = response.maxY,
      minZ = response.minZ,
      maxZ = response.maxZ,
      imageData = response.imageData,
    }
  else
    record.state = "failed"
    record.failure = response.error
  end
  self:_dispatch()
end

-- Drain every pending worker reply without blocking.
function AssetPreparationQueue:_drain()
  while true do
    local response = self._reply:pop()
    if response == nil then
      return
    end
    self:_absorb(response)
  end
end

---@param kind "mesh"|"image"
---@param logicalPath string
---@param priority "demand"|"prefetch"
---@return integer
function AssetPreparationQueue:request(kind, logicalPath, priority)
  assert(not self._released, "asset preparation queue is released")
  assert(VALID_KINDS[kind], "unknown preparation kind " .. tostring(kind))
  assert(VALID_PRIORITIES[priority], "unknown preparation priority " .. tostring(priority))
  assert(type(logicalPath) == "string", "preparation path is required")
  self:_drain()
  local resolved = self._cacheFs:resolve(logicalPath)
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  self._tokens[token] =
    { kind = kind, logicalPath = logicalPath, path = resolved, priority = priority, state = "queued" }
  if priority == "demand" then
    self._demand[#self._demand + 1] = token
  else
    self._prefetch[#self._prefetch + 1] = token
  end
  self:_dispatch()
  return token
end

-- Non-blocking state probe; never transfers the payload. Returns "pending",
-- "ready", or "failed" plus the worker's failure cause for failed work.
---@param token integer
---@return string, string?
function AssetPreparationQueue:poll(token)
  local record = self._tokens[token]
  assert(record, "unknown preparation token")
  self:_drain()
  record = self._tokens[token]
  assert(record, "unknown preparation token")
  if record.state == "ready" then
    return "ready"
  end
  if record.state == "failed" then
    return "failed", record.failure
  end
  return "pending"
end

-- Transfer a ready payload exactly once. Unknown, pending, failed, or
-- already-transferred tokens fail loudly instead of reviving work.
---@param token integer
---@return table<string, unknown>
function AssetPreparationQueue:take(token)
  local record = self._tokens[token]
  assert(record, "unknown preparation token")
  self:_drain()
  record = self._tokens[token]
  assert(record, "unknown preparation token")
  assert(record.state == "ready", "preparation result is not ready")
  self._tokens[token] = nil
  return assert(record.payload, "ready preparation has no payload")
end

-- Drop queued interest; a running job is not preempted but its late result
-- is discarded when it returns, and the worker is immediately reusable.
---@param token integer
function AssetPreparationQueue:cancel(token)
  assert(self._tokens[token], "unknown preparation token")
  self._tokens[token] = nil
  for _, pending in ipairs({ self._demand, self._prefetch }) do
    for index, queued in ipairs(pending) do
      if queued == token then
        table.remove(pending, index)
        break
      end
    end
  end
  if self._active == token then
    self._active = nil
    self:_dispatch()
  end
end

-- Block efficiently until one token's payload is transferred, absorbing any
-- unrelated token results along the way. Only synchronous callers whose path
-- already requires the result may wait; staged work polls instead.
---@param token integer
---@return table<string, unknown>
function AssetPreparationQueue:wait(token)
  assert(self._tokens[token], "unknown preparation token")
  while true do
    self:_drain()
    local record = self._tokens[token]
    assert(record, "unknown preparation token")
    if record.state == "ready" then
      self._tokens[token] = nil
      return assert(record.payload, "ready preparation has no payload")
    end
    if record.state == "failed" then
      error("asset preparation failed for " .. tostring(record.logicalPath) .. ": " .. tostring(record.failure), 0)
    end
    if self._worker.isRunning and not self._worker:isRunning() then
      local workerError = self._worker.getError and self._worker:getError()
      error("asset preparation worker stopped: " .. tostring(workerError), 0)
    end
    local response = self._reply:demand()
    if response ~= nil then
      self:_absorb(response)
    end
  end
end

-- Stop accepting work, drop every outstanding token, ask the worker to stop
-- after its current job, join it, and discard unclaimed payloads.
-- Idempotent: the worker is joined exactly once.
function AssetPreparationQueue:release()
  if self._released then
    return
  end
  self._released = true
  self._tokens = {}
  self._demand = {}
  self._prefetch = {}
  self._active = nil
  pcall(function()
    self._request:push({ op = "shutdown" })
  end)
  if not self._joined then
    self._joined = true
    self._worker:wait()
  end
  while self._reply:pop() ~= nil do
  end
end

return AssetPreparationQueue
