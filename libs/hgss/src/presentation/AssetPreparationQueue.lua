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
---@field _workerBusyToken integer?
---@field _workerFailure string?
---@field _nextToken integer
---@field _released boolean
---@field _joined boolean
local AssetPreparationQueue = {}
AssetPreparationQueue.__index = AssetPreparationQueue

local WORKER_MODULE = "libs.hgss.src.presentation.asset_preparation_worker"
local WORKER_PATH = "libs/hgss/src/presentation/asset_preparation_worker.lua"
local WORKER_ENTRY_NAME = "asset_preparation_worker.lua"

local VALID_KINDS = { mesh = true, image = true }
local VALID_PRIORITIES = { demand = true, prefetch = true }

-- Read the worker entry source through the LÖVE virtual filesystem first so
-- packaged .love/fused builds resolve it from the source archive, then
-- through the host file under the source base directory for checkout runs
-- where the app source mount does not include the repo-root library tree,
-- and finally through the process require path for headless/fake hosts with
-- no usable love.filesystem. A LÖVE Thread resolves filenames against the
-- source directory, where this module's sibling file is not visible, so the
-- queue loads the code itself and hands it to the thread as FileData.
---@return string?
local function loadWorkerCode()
  local hostLove = love
  local filesystem = (type(hostLove) == "table") and hostLove.filesystem or nil
  if filesystem and filesystem.read then
    local ok, source = pcall(filesystem.read, WORKER_PATH)
    if ok and type(source) == "string" then
      return source
    end
    if filesystem.getSourceBaseDirectory then
      local okBase, base = pcall(filesystem.getSourceBaseDirectory)
      if okBase and type(base) == "string" and base ~= "" then
        local handle = io.open(base .. "/" .. WORKER_PATH, "rb")
        if handle then
          local code = handle:read("*a")
          handle:close()
          if code then
            return code
          end
        end
      end
    end
  end
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
    local hostLove = love
    local filesystem = (type(hostLove) == "table") and hostLove.filesystem or nil
    if filesystem and filesystem.newFileData then
      workerSource = filesystem.newFileData(code, WORKER_ENTRY_NAME)
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
    _workerBusyToken = nil,
    _workerFailure = nil,
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

-- Dispatch one job while the worker is physically idle, choosing queued
-- demand work before queued prefetch work. Physical idleness is authoritative:
-- a token cancelled after dispatch keeps occupying the worker until its late
-- reply (or the worker's death) frees the slot.
function AssetPreparationQueue:_dispatch()
  if self._released or self._workerFailure ~= nil or self._workerBusyToken ~= nil then
    return
  end
  local token = self:_shiftLive(self._demand) or self:_shiftLive(self._prefetch)
  if token == nil then
    return
  end
  local record = assert(self._tokens[token], "dispatched an unknown preparation token")
  record.state = "running"
  self._workerBusyToken = token
  self._request:push({ op = "prepare", token = token, kind = record.kind, path = record.path })
end

-- Record an unexpected worker exit exactly once: every still-live queued or
-- running token fails with the terminal cause while already-ready payloads
-- stay transferable. The queue never restarts the worker.
---@param cause string?
function AssetPreparationQueue:_enterTerminalFailure(cause)
  if self._workerFailure ~= nil then
    return
  end
  if cause == nil then
    cause = "worker exited without an error"
  end
  self._workerFailure = "asset preparation worker stopped: " .. tostring(cause)
  for _, record in pairs(self._tokens) do
    if record.state == "queued" or record.state == "running" then
      record.state = "failed"
      record.failure = self._workerFailure
    end
  end
  self._demand = {}
  self._prefetch = {}
  self._workerBusyToken = nil
end

-- Detect an unexpected worker exit after draining replies. Thread hosts
-- without an isRunning probe stay usable; a production LÖVE Thread reporting
-- a stopped worker terminalizes the queue.
function AssetPreparationQueue:_checkWorkerHealth()
  if self._released or self._workerFailure ~= nil then
    return
  end
  local worker = self._worker
  if type(worker.isRunning) ~= "function" then
    return
  end
  local ok, running = pcall(function()
    return worker:isRunning()
  end)
  if ok and running then
    return
  end
  if not ok then
    self:_enterTerminalFailure(running)
    return
  end
  local cause = nil
  if type(worker.getError) == "function" then
    local _, workerError = pcall(function()
      return worker:getError()
    end)
    cause = workerError
  end
  self:_enterTerminalFailure(cause)
end

-- Absorb one worker reply: free the matching physical slot first (even when
-- the logical token was cancelled and no longer exists), then publish or
-- discard the logical result, then dispatch the next queued job. Already
-- resolved tokens are never overwritten by late replies.
---@param response unknown
function AssetPreparationQueue:_absorb(response)
  if type(response) ~= "table" then
    return
  end
  if self._workerBusyToken == response.token then
    self._workerBusyToken = nil
  end
  local record = self._tokens[response.token]
  if record == nil then
    self:_dispatch()
    return
  end
  if record.state ~= "queued" and record.state ~= "running" then
    self:_dispatch()
    return
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
  self:_checkWorkerHealth()
  if self._workerFailure ~= nil then
    error(self._workerFailure, 0)
  end
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
  self:_checkWorkerHealth()
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

-- Drop logical interest; a running job is not preempted and its late result
-- is discarded when it returns. The physical slot stays occupied until that
-- reply (or the worker's death) frees it, so cancellation never fabricates
-- worker idleness and priority is decided at the next physical dispatch.
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
    self:_checkWorkerHealth()
    local record = self._tokens[token]
    assert(record, "unknown preparation token")
    if record.state == "ready" then
      self._tokens[token] = nil
      return assert(record.payload, "ready preparation has no payload")
    end
    if record.state == "failed" then
      error("asset preparation failed for " .. tostring(record.logicalPath) .. ": " .. tostring(record.failure), 0)
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
  self._workerBusyToken = nil
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
