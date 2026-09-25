-- Process-owned transport to the single off-main cache controller. The
-- service owns channel identities, a bounded outbox, one outstanding
-- eight-ID status round, deduplicated semantic observations, and epoch and
-- barrier bookkeeping only. It mirrors no dependency graph, performs no
-- producer hashing, filesystem traversal, publication, recovery, or
-- source-plan parsing, and never waits on a channel: requests return cached
-- ready/error observations, lifecycle progress arrives through exact barrier
-- acknowledgements, and process shutdown alone joins the controller thread.

local ORDINARY_PER_UPDATE = 8
local POLL_IDS_PER_ROUND = 8
local ABSORB_PER_UPDATE = 32

local VALID_KINDS =
  { milestone = true, field = true, ["logical-field"] = true, cell = true, portrait = true, ["icon-page"] = true }
local VALID_URGENCIES = { required = true, near = true, sweep = true }
local URGENCY_ORDER = { required = 0, near = 10, sweep = 100 }

---@class CacheService
---@field _threadHost table<string, function>
---@field _command table<string, function>
---@field _reply table<string, function>
---@field _worker table<string, unknown>?
---@field _started boolean
---@field _joined boolean
---@field _nextEpoch integer
---@field _liveEpoch integer?
---@field _retiring boolean
---@field _nextRequestId integer
---@field _nextRoundId integer
---@field _nextBarrierId integer
---@field _records table<integer, table<string, unknown>> requestId -> record
---@field _byKey table<string, integer> epoch:key -> requestId
---@field _controls table<string, unknown>[] lifecycle commands awaiting emission
---@field _ordinary table<string, unknown>[] request/promote commands awaiting emission
---@field _outstanding table<string, unknown>? the one in-flight poll round
---@field _barriers table<string, table<string, unknown>> "epoch:barrier" -> waiter
---@field _failure string? terminal controller failure, never restarted
---@field _generations table<integer, string> controller-derived generation token by epoch
---@field _sweepSent table<integer, boolean> epochs with queued warmup authorization
local CacheService = {}
CacheService.__index = CacheService

---@param options table<string, unknown>? { thread = love.thread-shaped host }
---@return CacheService
function CacheService.new(options)
  options = options or {}
  local host = options.thread
  if host == nil then
    local loveGlobal = rawget(_G, "love")
    host = loveGlobal and loveGlobal.thread
  end
  assert(
    type(host) == "table" and type(host.newChannel) == "function" and type(host.newThread) == "function",
    "cache service requires love.thread"
  )
  local command = assert(host.newChannel(), "cache service requires its command channel")
  local reply = assert(host.newChannel(), "cache service requires its reply channel")
  return setmetatable({
    _threadHost = host,
    _command = command,
    _reply = reply,
    _worker = nil,
    _started = false,
    _joined = false,
    _nextEpoch = 0,
    _liveEpoch = nil,
    _retiring = false,
    _nextRequestId = 0,
    _nextRoundId = 0,
    _nextBarrierId = 0,
    _records = {},
    _byKey = {},
    _controls = {},
    _ordinary = {},
    _outstanding = nil,
    _barriers = {},
    _generations = {},
    _failure = nil,
    _sweepSent = {},
  }, CacheService)
end

---@param versionId unknown
local function checkVersion(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "cache selection requires a version")
end

---@param selector table<string, unknown>
---@return string dedup key for the semantic request
local function selectorKey(selector)
  assert(type(selector) == "table", "cache request requires its selectors")
  local kind = selector.requestKind
  assert(VALID_KINDS[kind], "unknown cache request kind: " .. tostring(kind))
  -- Observations may omit urgency: the dedup key never carries it, so a
  -- status probe addresses the same record its request registered.
  local urgency = selector.urgency
  if urgency ~= nil then
    assert(VALID_URGENCIES[urgency], "unknown cache urgency: " .. tostring(urgency))
  end
  if kind == "milestone" then
    assert(type(selector.name) == "string" and selector.name ~= "", "milestone request requires its name")
    return "milestone:" .. selector.name
  elseif kind == "field" or kind == "logical-field" then
    assert(
      type(selector.mapId) == "number" and selector.mapId % 1 == 0 and selector.mapId >= 0,
      kind .. " request requires a non-negative integer mapId"
    )
    return kind .. ":" .. tostring(selector.mapId)
  elseif kind == "cell" then
    assert(
      type(selector.matrixMemberId) == "number" and selector.matrixMemberId % 1 == 0 and selector.matrixMemberId >= 0,
      "cell request requires a non-negative integer matrixMemberId"
    )
    assert(
      type(selector.index) == "number" and selector.index % 1 == 0 and selector.index >= 0,
      "cell request requires a non-negative integer index"
    )
    return "cell:" .. tostring(selector.matrixMemberId) .. ":" .. tostring(selector.index)
  else
    assert(
      type(selector.pageId) == "number" and selector.pageId % 1 == 0 and selector.pageId >= 0,
      kind .. " request requires a non-negative integer pageId"
    )
    return kind .. ":" .. tostring(selector.pageId)
  end
end

---@param options table<string, unknown> { versionId, development?, repositoryRoot? }
---@return integer? epoch, nil when the controller cannot select
function CacheService:select(options)
  assert(type(options) == "table", "cache selection requires its selectors")
  checkVersion(options.versionId)
  if self._failure ~= nil then
    return nil
  end
  local host = self._threadHost
  if not self._started then
    local Worker = require("romdump.src.build.CacheControllerWorker")
    local bootstrap = assert(Worker.bootstrap(), "cache controller has no thread entry")
    local worker = host.newThread(bootstrap)
    local started, startError = pcall(function()
      worker:start(self._command, self._reply, package.path)
    end)
    if not started then
      self._failure = "controller thread failed to start: " .. tostring(startError)
      return nil
    end
    self._worker = worker
    self._started = true
  end
  self._nextEpoch = self._nextEpoch + 1
  local epoch = self._nextEpoch
  self._liveEpoch = epoch
  self._retiring = false
  local command = {
    op = "select",
    epoch = epoch,
    versionId = options.versionId,
    development = options.development == true,
  }
  if options.repositoryRoot ~= nil then
    assert(type(options.repositoryRoot) == "string", "cache repository root must be a string")
    command.repositoryRoot = options.repositoryRoot
  end
  self._controls[#self._controls + 1] = command
  return epoch
end

-- Record (or strengthen) one semantic request. Only emission sends: repeats
-- for a pending record never queue another ensure command, and a
-- background-to-required strengthening queues a single promote for the
-- existing identity.
---@param epoch integer
---@param selector table<string, unknown>
---@return integer? request identity, nil for a stale epoch
function CacheService:request(epoch, selector)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  local key = selectorKey(selector)
  assert(VALID_URGENCIES[selector.urgency], "cache request requires its urgency")
  local mapKey = tostring(epoch) .. ":" .. key
  local existingId = self._byKey[mapKey]
  if existingId ~= nil then
    local record = assert(self._records[existingId], "cache request record is missing")
    if record.terminal then
      return existingId
    end
    local wanted = URGENCY_ORDER[selector.urgency]
    if wanted < URGENCY_ORDER[record.urgency] then
      record.urgency = selector.urgency
      if record.sent then
        self._ordinary[#self._ordinary + 1] =
          { op = "promote", epoch = epoch, requestId = existingId, urgency = "required" }
      else
        record.command.urgency = selector.urgency
      end
    end
    return existingId
  end
  self._nextRequestId = self._nextRequestId + 1
  local id = self._nextRequestId
  local command = {
    op = "request",
    epoch = epoch,
    requestId = id,
    requestKind = selector.requestKind,
    urgency = selector.urgency,
  }
  if selector.requestKind == "milestone" then
    command.name = selector.name
  elseif selector.requestKind == "field" or selector.requestKind == "logical-field" then
    command.mapId = selector.mapId
  elseif selector.requestKind == "cell" then
    command.matrixMemberId = selector.matrixMemberId
    command.index = selector.index
  else
    command.pageId = selector.pageId
  end
  self._records[id] = {
    id = id,
    epoch = epoch,
    key = key,
    selector = selector,
    urgency = selector.urgency,
    command = command,
    sent = false,
    terminal = false,
    ready = nil,
    failure = nil,
  }
  self._byKey[mapKey] = id
  self._ordinary[#self._ordinary + 1] = command
  return id
end

-- Cached observation only: never drains, sends, or waits. A retired epoch
-- grants no observation rights; a terminal controller failure reports its
-- cause instead of readiness.
---@param epoch integer
---@param selector table<string, unknown>
---@return boolean? ready
---@return string? failure
function CacheService:observe(epoch, selector)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil, nil
  end
  if self._failure ~= nil then
    return nil, self._failure
  end
  local key = selectorKey(selector)
  local id = self._byKey[tostring(epoch) .. ":" .. key]
  if id == nil then
    return nil, nil
  end
  local record = assert(self._records[id], "cache request record is missing")
  if record.terminal then
    if record.ready then
      return true, nil
    end
    return false, record.failure
  end
  return nil, nil
end

-- Cached controller-derived generation token for the epoch, or nil while
-- the selection answer is still in flight, the epoch is stale or retiring,
-- or the controller failed. Never scans, never waits: durability checks
-- treat an unknown generation as incomplete and prepare again.
---@param epoch integer
---@return string?
function CacheService:generationId(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  return self._generations[epoch]
end

-- Authorize lowest-priority background corpus completion for the epoch.
-- Idempotent per epoch: the controller authorization itself is idempotent
-- and performs no cache work in the call.
---@param epoch integer
function CacheService:enableSweep(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if self._failure ~= nil or self._sweepSent[epoch] then
    return
  end
  self._sweepSent[epoch] = true
  self._controls[#self._controls + 1] = { op = "enableSweep", epoch = epoch }
end

-- Retire the live epoch: observation rights end immediately while physical
-- retirement is acknowledged asynchronously through the exact barrier.
---@param epoch integer
---@return integer? barrier identity, nil for a stale epoch
function CacheService:retire(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  self._retiring = true
  self._generations[epoch] = nil
  for position = #self._ordinary, 1, -1 do
    if self._ordinary[position].epoch == epoch then
      table.remove(self._ordinary, position)
    end
  end
  self._nextBarrierId = self._nextBarrierId + 1
  local barrier = self._nextBarrierId
  self._barriers[tostring(epoch) .. ":" .. tostring(barrier)] = { epoch = epoch, barrier = barrier, state = "pending" }
  self._controls[#self._controls + 1] = { op = "retire", epoch = epoch, barrierId = barrier }
  return barrier
end

-- Ask the controller to close every worker source context so a later source
-- replacement cannot race a live reader. Import waits for the exact
-- acknowledgement, never for an empty queue or a timeout.
---@param epoch integer
---@return integer? barrier identity, nil for a stale epoch
function CacheService:quiesce(epoch)
  if type(epoch) ~= "number" then
    return nil
  end
  if epoch ~= self._liveEpoch and not self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  self._nextBarrierId = self._nextBarrierId + 1
  local barrier = self._nextBarrierId
  self._barriers[tostring(epoch) .. ":" .. tostring(barrier)] =
    { epoch = epoch, barrier = barrier, state = "pending", quiesce = true }
  self._controls[#self._controls + 1] = { op = "quiesce", epoch = epoch, barrierId = barrier }
  return barrier
end

---@param epoch integer
---@param barrier integer
---@return string? "pending", "ready", "failed", or nil for an unknown barrier
function CacheService:barrierStatus(epoch, barrier)
  local waiter = self._barriers[tostring(epoch) .. ":" .. tostring(barrier)]
  if waiter == nil then
    return nil
  end
  if waiter.state == "ready" then
    return "ready"
  end
  if self._failure ~= nil then
    return "failed"
  end
  return "pending"
end

-- Authorize a source import behind an acknowledged quiescence barrier. The
-- acknowledgement is consumed exactly once: a second import needs a fresh
-- barrier.
---@param epoch integer
---@param barrier integer
---@return boolean ok
---@return string? refusal
function CacheService:importSource(epoch, barrier)
  local waiter = self._barriers[tostring(epoch) .. ":" .. tostring(barrier)]
  if waiter == nil or waiter.quiesce ~= true then
    return false, "no quiescence barrier authorizes the import"
  end
  if waiter.state ~= "ready" then
    return false, "no import crosses an unacknowledged quiescence barrier"
  end
  if waiter.consumed then
    return false, "the quiescence barrier authorized exactly one import"
  end
  waiter.consumed = true
  return true
end

-- Test-only transport injection: script a controller answer without a
-- thread. Production never calls this; it exists so composition tests can
-- drive barrier and readiness boundaries deterministically.
---@param packet table<string, unknown>
function CacheService:injectReply(packet)
  assert(type(packet) == "table", "injected reply must be a record")
  self._reply:push(packet)
end

---@param cause string?
function CacheService:_enterTerminalFailure(cause)
  if self._failure ~= nil then
    return
  end
  if cause == nil or cause == "" then
    cause = "controller thread exited"
  end
  self._failure = "controller thread stopped: " .. tostring(cause)
  self._controls = {}
  self._ordinary = {}
  self._outstanding = nil
end

function CacheService:_checkWorkerHealth()
  if not self._started or self._joined or self._failure ~= nil then
    return
  end
  local worker = assert(self._worker, "cache controller thread is missing")
  if type(worker.isRunning) ~= "function" then
    return
  end
  local ok, running = pcall(function()
    return worker:isRunning()
  end)
  if ok and running then
    return
  end
  local cause = nil
  if not ok then
    cause = running
  elseif type(worker.getError) == "function" then
    local _, workerError = pcall(function()
      return worker:getError()
    end)
    cause = workerError
  end
  self:_enterTerminalFailure(cause)
end

---@param packet unknown
function CacheService:_absorb(packet)
  if type(packet) ~= "table" then
    return
  end
  local op = packet.op
  if op == "poll-result" then
    self:_absorbPollResult(packet)
    return
  end
  if op == "select-result" then
    self:_absorbSelectResult(packet)
    return
  end
  self:_absorbObservation(packet)
end

---@param packet table<string, unknown>
function CacheService:_absorbPollResult(packet)
  local outstanding = self._outstanding
  if outstanding == nil or packet.roundId ~= outstanding.round then
    return
  end
  -- The round is over whether or not its epoch is still live: clearing a
  -- stale round lets a new epoch poll again instead of wedging behind an
  -- obsolete answer.
  self._outstanding = nil
  -- Barrier acknowledgements are lifecycle facts, not request
  -- observations: a retiring selection or an already-retired epoch still
  -- needs its retirement/quiescence answers, or the import wait behind
  -- them can never complete. Barrier identities are process-monotone, so
  -- a late duplicate can only confirm an already-settled waiter, never
  -- satisfy a newer one early.
  if packet.retiredBarrierId ~= nil then
    for _, waiter in pairs(self._barriers) do
      if waiter.quiesce ~= true and waiter.state == "pending" and waiter.barrier <= packet.retiredBarrierId then
        waiter.state = "ready"
      end
    end
    if self._retiring then
      self._liveEpoch = nil
      self._retiring = false
    end
  end
  if packet.quiescedBarrierId ~= nil then
    for _, waiter in pairs(self._barriers) do
      if waiter.quiesce == true and waiter.state == "pending" and waiter.barrier <= packet.quiescedBarrierId then
        waiter.state = "ready"
      end
    end
  end
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if type(packet.generationId) == "string" and packet.generationId ~= "" then
    self._generations[packet.epoch] = packet.generationId
  end
  local count = math.min(tonumber(packet.count) or 0, POLL_IDS_PER_ROUND)
  for position = 1, count do
    local tag = tostring(position)
    local id = packet["id" .. tag]
    local record = self._records[id]
    if record ~= nil and record.epoch == self._liveEpoch and not record.terminal then
      local state = packet["state" .. tag]
      if state == "ready" then
        record.terminal = true
        record.ready = true
        record.failure = nil
      elseif state == "failed" then
        record.terminal = true
        record.ready = false
        local message = packet["errorMessage" .. tag]
        if message == nil or message == "" then
          message = packet["errorCode" .. tag]
        end
        record.failure = message
      end
    end
  end
  if packet.lifecycle == "failed" and (packet.lifecycleError or "") ~= "" then
    self:_enterTerminalFailure(packet.lifecycleError)
    return
  end
end

---@param packet table<string, unknown>
function CacheService:_absorbSelectResult(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if packet.ok ~= true then
    local message = packet.errorMessage
    if message == nil or message == "" then
      message = "controller selection failed"
    end
    self:_enterTerminalFailure(message)
    return
  end
  -- The controller-derived generation token is the canonical identity for
  -- durability decisions (first-play completion): it already reflects the
  -- ROM SHA, producer identity/mode, asset revision, and script API the
  -- game thread must never re-derive by scanning sources.
  if type(packet.generationId) == "string" and packet.generationId ~= "" then
    self._generations[packet.epoch] = packet.generationId
  end
end

---@param packet table<string, unknown>
function CacheService:_absorbObservation(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  local key
  if packet.requestKind == "milestone" then
    key = "milestone:" .. tostring(packet.name)
  elseif packet.requestKind == "field" or packet.requestKind == "logical-field" then
    key = packet.requestKind .. ":" .. tostring(packet.mapId)
  elseif packet.requestKind == "cell" then
    key = "cell:" .. tostring(packet.matrixMemberId) .. ":" .. tostring(packet.index)
  elseif packet.requestKind == "portrait" then
    key = "portrait:" .. tostring(packet.pageId)
  elseif packet.requestKind == "icon-page" then
    key = "icon-page:" .. tostring(packet.pageId)
  else
    return
  end
  local id = self._byKey[tostring(packet.epoch) .. ":" .. key]
  if id == nil then
    return
  end
  local record = self._records[id]
  if record == nil or record.terminal then
    return
  end
  if packet.state == "ready" then
    record.terminal = true
    record.ready = true
  elseif packet.state == "failed" then
    record.terminal = true
    record.ready = false
    record.failure = packet.errorMessage or packet.errorCode
  end
end

---@return integer[] pending request identities for the live epoch
function CacheService:_pendingPollIds()
  local ids = {}
  for id, record in pairs(self._records) do
    if record.epoch == self._liveEpoch and not record.terminal then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

---@return boolean waiter true while an unacknowledged barrier needs polling
function CacheService:_barrierWaiter()
  for _, waiter in pairs(self._barriers) do
    if waiter.state == "pending" then
      return true
    end
  end
  return false
end

---@return table<string, integer> emitted counts for the frame
function CacheService:_emit()
  local sent = { ordinary = 0, polls = 0 }
  for _, command in ipairs(self._controls) do
    self._command:push(command)
  end
  self._controls = {}
  for _, command in ipairs(self._ordinary) do
    if sent.ordinary >= ORDINARY_PER_UPDATE then
      break
    end
    self._command:push(command)
    local record = self._records[command.requestId]
    if record ~= nil then
      record.sent = true
    end
    sent.ordinary = sent.ordinary + 1
  end
  if sent.ordinary >= #self._ordinary then
    self._ordinary = {}
  else
    local waiting = {}
    for position = sent.ordinary + 1, #self._ordinary do
      waiting[#waiting + 1] = self._ordinary[position]
    end
    self._ordinary = waiting
  end
  -- Barrier acknowledgements must keep flowing while retiring and after
  -- retirement clears the live epoch: those rounds carry no request
  -- observations (count 0), only the latest barrier identities, so a
  -- quiescence wait behind them can complete instead of wedging.
  local epoch = self._liveEpoch
  local ids = {}
  if epoch ~= nil and not self._retiring then
    ids = self:_pendingPollIds()
  elseif epoch == nil then
    epoch = self:_pendingBarrierEpoch()
  end
  if self._outstanding == nil and epoch ~= nil and (#ids > 0 or self:_barrierWaiter()) then
    self._nextRoundId = self._nextRoundId + 1
    local packet = { op = "poll", roundId = self._nextRoundId, epoch = epoch, count = 0 }
    local take = math.min(#ids, POLL_IDS_PER_ROUND)
    packet.count = take
    for position = 1, take do
      packet["id" .. tostring(position)] = ids[position]
    end
    self._command:push(packet)
    self._outstanding = { round = self._nextRoundId }
    sent.polls = 1
  end
  return sent
end

-- Pump the transport once: absorb at most one result packet, emit at most
-- eight queued ordinary records plus one poll packet. Never blocks, never
-- performs producer or filesystem work.
---@return integer? epoch of the oldest pending barrier waiter, when one waits
function CacheService:_pendingBarrierEpoch()
  local found = nil
  for _, waiter in pairs(self._barriers) do
    if waiter.state == "pending" and (found == nil or waiter.epoch < found) then
      found = waiter.epoch
    end
  end
  return found
end

---@return table<string, integer> emitted counts for the frame
function CacheService:update()
  self:_checkWorkerHealth()
  local absorbed = 0
  local processedResult = false
  while absorbed < ABSORB_PER_UPDATE do
    local packet = self._reply:pop()
    if packet == nil then
      break
    end
    absorbed = absorbed + 1
    if type(packet) == "table" and packet.op == "poll-result" then
      if not processedResult then
        processedResult = true
        self:_absorb(packet)
      end
    else
      self:_absorb(packet)
    end
  end
  if self._failure ~= nil then
    return { ordinary = 0, polls = 0 }
  end
  return self:_emit()
end

-- Join the controller thread exactly once. Process shutdown alone joins;
-- selection retirement never does. Unsent interest is discarded: shutdown
-- is final and nothing after it can observe this process.
function CacheService:shutdown()
  if self._joined then
    return
  end
  self._joined = true
  self._controls = {}
  self._ordinary = {}
  self._outstanding = nil
  if not self._started then
    return
  end
  pcall(function()
    self._command:push({ op = "shutdown" })
  end)
  local worker = self._worker
  if worker ~= nil and type(worker.wait) == "function" then
    pcall(function()
      worker:wait()
    end)
  end
end

return CacheService
