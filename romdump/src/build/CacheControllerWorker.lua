-- Owns the interactive cache system off the game thread: one controller
-- thread per process drives generation selection, the demand/background
-- session graph (including the retained background completion cursor),
-- compiler worker dispatch, serialized publication/recovery, retirement and
-- source-close barriers, and orderly shutdown. The game thread sees only
-- flat scalar request/status observations through its service proxy and
-- never blocks for cache production. Batch preparation stays a separate
-- synchronous client of the same build modules.
--
-- Threading contract (official LOVE semantics): worker Lua states are
-- separate; this module loads love.thread/love.timer/love.system
-- explicitly in the worker. Worker states resolve thread sources as
-- filenames only, so compiler workers boot from FileData when the
-- code-string bootstrap is rejected there. No graphics, window, input, or
-- audio calls occur below this entry.

local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local CompilerPool = require("romdump.src.build.CompilerPool")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local GameVersion = require("romdump.src.source.GameVersion")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local CacheControllerWorker = {}

-- Bounded wait cadence while progress depends on an external compiler or
-- source-close result. Those completions arrive on the pool's private
-- result channel, invisible to the control channel the worker blocks on,
-- so a waiting session polls on a short sleep-dominated tick rather than
-- blocking indefinitely. A fully idle controller (no selected session, or
-- a selected session with no runnable planning and no outstanding
-- worker/close result) blocks on the control channel with no timeout.
-- This is a static conservative cadence, not a frame governor: it never
-- inspects frame timing.
local LIVE_TICK_SECONDS = 0.005

-- Fallback sleep when no LOVE timer is present. Named (not inline
-- anonymous) per repository source policy; run's fallback semantics
-- are unchanged.
---@param _ number ignored sleep duration
local function idleSleep(_) end

-- Single-shot code bootstrap for love.thread.newThread on the game thread.
-- Code strings boot on the game thread; the development search path is
-- installed explicitly because worker states do not inherit it. Packaged
-- builds resolve requires from the source archive with an empty path.
local function bootstrapSource()
  return [[
local controlChannel, replyChannel, developmentPath = ...
if type(developmentPath) == "string" and developmentPath ~= "" then
  package.path = developmentPath
end
pcall(require, "love.thread")
pcall(require, "love.timer")
pcall(require, "love.system")
local Worker = require("romdump.src.build.CacheControllerWorker")
Worker.run(controlChannel, replyChannel)
]]
end

---@return string code bootstrap for the controller thread entry
function CacheControllerWorker.bootstrap()
  return bootstrapSource()
end

local VALID_KINDS =
  { milestone = true, field = true, ["logical-field"] = true, cell = true, portrait = true, ["icon-page"] = true }
local VALID_URGENCIES = { required = true, near = true, sweep = true }

---@class CacheControllerSelection
---@field epoch integer
---@field versionId string
---@field development boolean
---@field repositoryRoot string?

local Worker = {}
Worker.__index = Worker

---@param control table<string, function>|userdata command channel (game thread pushes)
---@param reply table<string, function>|userdata reply channel (game thread pops)
---@return table<string, unknown> controller state (test-driving uses step)
function Worker.new(control, reply)
  assert(type(control) == "table" or type(control) == "userdata", "controller requires its command channel")
  assert(type(reply) == "table" or type(reply) == "userdata", "controller requires its reply channel")
  assert(type(control.pop) == "function", "controller command channel needs pop")
  assert(type(reply.push) == "function", "controller reply channel needs push")
  return setmetatable({
    control = control,
    reply = reply,
    pool = nil,
    poolRoot = false,
    session = nil,
    liveEpoch = nil,
    lastRetiredEpoch = nil,
    generationId = nil,
    lifecycle = "starting",
    lifecycleError = nil,
    frozenProducerRoot = nil,
    frozenProducerId = nil,
    requests = {},
    deferredSelect = nil,
    pendingRetire = nil,
    pendingQuiesce = nil,
    retiredBarrierId = nil,
    quiescedBarrierId = nil,
    exiting = false,
  }, Worker)
end

---@param message string
function Worker:_fail(message)
  if self.lifecycle == "failed" then
    return
  end
  self.lifecycle = "failed"
  self.lifecycleError = message
  self.pendingRetire = nil
  self.pendingQuiesce = nil
  self.deferredSelect = nil
end

local function formatError(value)
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

---@param params table<string, unknown>
---@return string|nil selector error for an invalid current-epoch message
local function validateSelectors(params)
  local kind = params.requestKind
  if not VALID_KINDS[kind] then
    return "unknown cache request kind: " .. tostring(kind)
  end
  if not VALID_URGENCIES[params.urgency] then
    return "unknown cache urgency: " .. tostring(params.urgency)
  end
  if kind == "milestone" then
    if
      params.name ~= "bootstrap"
      and params.name ~= "new-game-intro"
      and params.name ~= "field-planning"
      and params.name ~= "field-runtime"
    then
      return "unknown milestone: " .. tostring(params.name)
    end
  elseif kind == "field" or kind == "logical-field" then
    if type(params.mapId) ~= "number" or params.mapId % 1 ~= 0 or params.mapId < 0 then
      return kind .. " request needs a non-negative integer mapId"
    end
  elseif kind == "cell" then
    if type(params.matrixMemberId) ~= "number" or params.matrixMemberId % 1 ~= 0 or params.matrixMemberId < 0 then
      return "cell request needs a non-negative integer matrixMemberId"
    end
    if type(params.index) ~= "number" or params.index % 1 ~= 0 or params.index < 0 then
      return "cell request needs a non-negative integer index"
    end
  elseif kind == "portrait" then
    if type(params.pageId) ~= "number" or params.pageId % 1 ~= 0 or params.pageId < 0 then
      return "portrait request needs a non-negative integer pageId"
    end
  elseif kind == "icon-page" then
    if type(params.pageId) ~= "number" or params.pageId % 1 ~= 0 or params.pageId < 0 then
      return "icon request needs a non-negative integer pageId"
    end
  end
  return nil
end

---@param params table<string, unknown>
---@return boolean ready
---@return string? failure
function Worker:_invoke(params)
  local session = assert(self.session, "controller has no selected session")
  local kind, urgency = params.requestKind, params.urgency
  if kind == "milestone" then
    return session:requestMilestone(params.name, urgency)
  elseif kind == "field" then
    return session:requestField(params.mapId, urgency)
  elseif kind == "logical-field" then
    return session:requestLogicalField(params.mapId, urgency)
  elseif kind == "cell" then
    return session:requestCell({ matrixMemberId = params.matrixMemberId, index = params.index }, urgency)
  elseif kind == "portrait" then
    return session:requestMonPortraitPage(params.pageId, urgency)
  elseif kind == "icon-page" then
    return session:requestIconPage(params.pageId, urgency)
  end
  error("unknown cache request kind: " .. tostring(kind), 0)
end

---@param params table<string, unknown>
---@return table<string, unknown> observation with state/completed/total/errorCode/errorMessage
function Worker:_observe(params)
  local observation = { state = "pending", completed = 0, total = 0, errorCode = "", errorMessage = "" }
  if self.session == nil then
    observation.state = "failed"
    observation.errorCode = "no-selection"
    observation.errorMessage = "controller has no selected session"
    return observation
  end
  local ok, ready, failure = pcall(function()
    return self:_invoke(params)
  end)
  if not ok then
    observation.state = "failed"
    observation.errorCode = "request"
    observation.errorMessage = formatError(ready)
    return observation
  end
  if failure ~= nil then
    observation.state = "failed"
    observation.errorCode = "cache"
    observation.errorMessage = formatError(failure)
    return observation
  end
  if ready then
    observation.state = "ready"
    observation.completed = 1
    observation.total = 1
  end
  if params.requestKind == "milestone" then
    local statusOk, snapshot = pcall(function()
      return self.session:milestoneStatus(params.name)
    end)
    if statusOk and type(snapshot) == "table" then
      observation.completed = tonumber(snapshot.ready) or observation.completed
      if snapshot.total ~= nil then
        observation.total = tonumber(snapshot.total) or observation.total
      end
    end
  end
  return observation
end

---@param versionId string
---@param development boolean
---@param repositoryRoot string?
---@return string|nil producerId
---@return string|nil failure
function Worker:_producerId(versionId, development, repositoryRoot)
  if not development then
    local counter = DerivedCacheVersions[versionId]
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 1 then
      return nil, "release counter must be a positive integer for version: " .. tostring(versionId)
    end
    return "r" .. tostring(counter), nil
  end
  if type(repositoryRoot) ~= "string" or repositoryRoot == "" then
    return nil, "development selection requires its repository root"
  end
  if self.frozenProducerRoot == repositoryRoot and self.frozenProducerId ~= nil then
    return self.frozenProducerId, nil
  end
  local ok, backend = pcall(ProducerFingerprint.checkoutBackend, repositoryRoot)
  if not ok then
    return nil, "development producer backend is unavailable: " .. formatError(backend)
  end
  local digestOk, producerId = pcall(ProducerFingerprint.compute, backend)
  if not digestOk then
    return nil, "development producer digest failed: " .. formatError(producerId)
  end
  self.frozenProducerRoot = repositoryRoot
  self.frozenProducerId = producerId
  return producerId, nil
end

---@param command table<string, unknown>
function Worker:_answerSelect(command)
  self.reply:push({
    op = "select-result",
    epoch = command.epoch,
    ok = command.ok == true,
    generationId = command.generationId or "",
    lifecycle = self.lifecycle,
    errorMessage = command.errorMessage or "",
  })
end

---@param command table<string, unknown>
function Worker:_applySelect(command)
  local epoch = command.epoch
  local versionId = command.versionId
  if type(versionId) ~= "string" or versionId == "" then
    self:_fail("controller select requires a version")
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller select requires a version" })
    return
  end
  local infoOk, info = pcall(GameVersion.info, versionId)
  if not infoOk or type(info) ~= "table" or type(info.sha1) ~= "string" then
    self:_fail("unsupported version: " .. tostring(versionId))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "unsupported version: " .. tostring(versionId) })
    return
  end
  local development = command.development == true
  local repositoryRoot = command.repositoryRoot
  local producerId, producerError = self:_producerId(versionId, development, repositoryRoot)
  if producerId == nil then
    assert(type(producerError) == "string", "controller producer identity failed without a cause")
    self:_fail(producerError)
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = producerError })
    return
  end
  local identityOk, identity = pcall(DerivedCacheState.currentForSelection, {
    versionId = versionId,
    romSha1 = info.sha1,
    producerId = producerId,
    developmentRepositoryRoot = development and repositoryRoot or nil,
  })
  if not identityOk then
    self:_fail("controller selection identity failed: " .. formatError(identity))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller selection identity failed" })
    return
  end
  local poolOk, poolError = pcall(function()
    return self:_ensurePool(development and repositoryRoot or nil)
  end)
  if not poolOk then
    self:_fail("controller compiler pool is unavailable: " .. formatError(poolError))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller compiler pool is unavailable" })
    return
  end
  local selectOk, selectError = pcall(function()
    self:_replaceSession(identity, epoch)
  end)
  if not selectOk then
    self:_fail("controller generation selection failed: " .. formatError(selectError))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller generation selection failed" })
    return
  end
  self.liveEpoch = epoch
  self.lastRetiredEpoch = nil
  self.generationId = identity.generationId
  self.lifecycle = "active"
  self.requests = {}
  self.retiredBarrierId = nil
  self.quiescedBarrierId = nil
  self:_answerSelect({ epoch = epoch, ok = true, generationId = identity.generationId })
end

---@param repositoryRoot string?
---@return table<string, unknown> process compiler pool for the controller
function Worker:_ensurePool(repositoryRoot)
  if self.pool ~= nil and self.poolRoot == (repositoryRoot or false) then
    return self.pool
  end
  if self.pool ~= nil then
    pcall(function()
      self.pool:shutdown()
    end)
    self.pool = nil
  end
  local pool = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = repositoryRoot })
  self.pool = pool
  self.poolRoot = repositoryRoot or false
  return pool
end

---@param identity table<string, unknown>
---@param epoch integer
function Worker:_replaceSession(identity, epoch)
  if self.session ~= nil then
    pcall(function()
      self.session:retire()
    end)
    self.session = nil
  end
  if self.pool ~= nil and self.liveEpoch ~= nil then
    pcall(function()
      self.pool:retireSelection(self.liveEpoch)
    end)
  end
  local pool = assert(self.pool, "controller has no compiler pool")
  pool:selectGeneration(identity, epoch)
  self.session = InteractiveCacheBuild.new({ identity = identity, epoch = epoch, pool = pool })
end

---@param command table<string, unknown>
function Worker:_applyRequest(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local params = {
    requestKind = command.requestKind,
    urgency = command.urgency,
    name = command.name,
    mapId = command.mapId,
    matrixMemberId = command.matrixMemberId,
    index = command.index,
    pageId = command.pageId,
  }
  local selectorError = validateSelectors(params)
  self.requests[command.requestId] = { params = params, observation = nil, invalid = selectorError }
  if selectorError ~= nil then
    return
  end
  local observation = self:_observe(params)
  self.requests[command.requestId].observation = observation
end

---@param command table<string, unknown>
function Worker:_applyPromote(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local record = self.requests[command.requestId]
  if record == nil or record.invalid ~= nil then
    return
  end
  record.params.urgency = "required"
  record.observation = self:_observe(record.params)
end

---@param command table<string, unknown>
function Worker:_applyEnableSweep(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local ok, failure = pcall(function()
    self.session:enableSweep()
  end)
  if not ok then
    self:_fail("controller background authorization failed: " .. formatError(failure))
  end
end

---@param command table<string, unknown>
function Worker:_applyRetire(command)
  if command.epoch ~= self.liveEpoch then
    return
  end
  local pool = self.pool
  if pool ~= nil then
    local ok, failure = pcall(function()
      pool:retireSelection(command.epoch)
    end)
    if not ok then
      self:_fail("controller retirement failed: " .. formatError(failure))
      return
    end
  end
  if self.session ~= nil then
    pcall(function()
      self.session:retire()
    end)
    self.session = nil
  end
  if pool ~= nil then
    pcall(function()
      pool:update()
    end)
  end
  self.lastRetiredEpoch = command.epoch
  self.liveEpoch = nil
  self.generationId = nil
  self.requests = {}
  self.lifecycle = "retiring"
  self.retiredBarrierId = command.barrierId
  self.pendingRetire = nil
end

---@return boolean
function Worker:_pumpQuiesce()
  local pending = self.pendingQuiesce
  if pending == nil then
    return false
  end
  local pool = self.pool
  if pool == nil then
    self.quiescedBarrierId = pending.barrierId
    self.lifecycle = "quiescent"
    self.pendingQuiesce = nil
    return true
  end
  local ok, failure = pcall(function()
    pool:update()
  end)
  if not ok then
    self:_fail("controller quiescence drain failed: " .. formatError(failure))
    return false
  end
  local quietOk, quiet = pcall(function()
    return pool:isQuiescent()
  end)
  if not quietOk then
    self:_fail("controller quiescence observation failed: " .. formatError(quiet))
    return false
  end
  if quiet then
    self.quiescedBarrierId = pending.barrierId
    self.lifecycle = "quiescent"
    self.pendingQuiesce = nil
    local deferred = self.deferredSelect
    self.deferredSelect = nil
    if deferred ~= nil then
      self:_applySelect(deferred)
    end
    return true
  end
  return false
end

---@param command table<string, unknown>
function Worker:_applyQuiesce(command)
  if command.epoch ~= self.liveEpoch and command.epoch ~= self.lastRetiredEpoch then
    return
  end
  if self.pendingQuiesce ~= nil then
    return
  end
  local pool = self.pool
  if pool ~= nil then
    local ok, failure = pcall(function()
      pool:quiesce()
    end)
    if not ok then
      self:_fail("controller quiescence failed: " .. formatError(failure))
      return
    end
  end
  self.lifecycle = "quiescing"
  self.pendingQuiesce = { epoch = command.epoch, barrierId = command.barrierId }
  self:_pumpQuiesce()
end

---@param command table<string, unknown>
function Worker:_answerPoll(command)
  local entries = {}
  local count = math.min(tonumber(command.count) or 0, 8)
  for position = 1, count do
    local id = command["id" .. tostring(position)]
    local record = self.requests[id]
    local observation
    if command.epoch ~= self.liveEpoch or record == nil then
      observation =
        { state = "failed", completed = 0, total = 0, errorCode = "stale", errorMessage = "unknown request" }
    elseif record.invalid ~= nil then
      observation =
        { state = "failed", completed = 0, total = 0, errorCode = "protocol", errorMessage = record.invalid }
    elseif self.pendingQuiesce ~= nil then
      observation = record.observation
        or { state = "pending", completed = 0, total = 0, errorCode = "", errorMessage = "" }
    else
      observation = self:_observe(record.params)
      record.observation = observation
    end
    entries[#entries + 1] = { id = id, observation = observation }
  end
  local packet = {
    op = "poll-result",
    roundId = command.roundId,
    epoch = command.epoch,
    count = #entries,
    lifecycle = self.lifecycle,
    generationId = self.generationId or "",
    lifecycleError = self.lifecycleError or "",
  }
  for position, entry in ipairs(entries) do
    local tag = tostring(position)
    packet["id" .. tag] = entry.id
    packet["state" .. tag] = entry.observation.state
    packet["completed" .. tag] = entry.observation.completed
    packet["total" .. tag] = entry.observation.total
    packet["errorCode" .. tag] = entry.observation.errorCode
    packet["errorMessage" .. tag] = entry.observation.errorMessage
  end
  if self.retiredBarrierId ~= nil then
    packet.retiredBarrierId = self.retiredBarrierId
  end
  if self.quiescedBarrierId ~= nil then
    packet.quiescedBarrierId = self.quiescedBarrierId
  end
  self.reply:push(packet)
end

---@param command unknown
function Worker:_handle(command)
  if type(command) ~= "table" then
    return
  end
  if self.exiting then
    return
  end
  local op = command.op
  if op == "shutdown" then
    self:_shutdown()
    return
  end
  if self.lifecycle == "failed" then
    if op == "poll" then
      self:_answerPoll(command)
    end
    return
  end
  if op == "select" then
    if self.pendingQuiesce ~= nil then
      self.deferredSelect = command
      return
    end
    local ok, failure = pcall(function()
      self:_applySelect(command)
    end)
    if not ok then
      self:_fail("controller select failed: " .. formatError(failure))
      self:_answerSelect({ epoch = command.epoch, ok = false, errorMessage = "controller select failed" })
    end
  elseif op == "request" then
    local ok, failure = pcall(function()
      self:_applyRequest(command)
    end)
    if not ok then
      self:_fail("controller request failed: " .. formatError(failure))
    end
  elseif op == "promote" then
    local ok, failure = pcall(function()
      self:_applyPromote(command)
    end)
    if not ok then
      self:_fail("controller promotion failed: " .. formatError(failure))
    end
  elseif op == "enableSweep" then
    self:_applyEnableSweep(command)
  elseif op == "retire" then
    local ok, failure = pcall(function()
      self:_applyRetire(command)
    end)
    if not ok then
      self:_fail("controller retirement failed: " .. formatError(failure))
    end
  elseif op == "quiesce" then
    local ok, failure = pcall(function()
      self:_applyQuiesce(command)
    end)
    if not ok then
      self:_fail("controller quiescence failed: " .. formatError(failure))
    end
  elseif op == "poll" then
    local ok, failure = pcall(function()
      self:_answerPoll(command)
    end)
    if not ok then
      self:_fail("controller status observation failed: " .. formatError(failure))
    end
  end
end

function Worker:_shutdown()
  self.exiting = true
  self.session = nil
  if self.pool ~= nil then
    pcall(function()
      self.pool:shutdown()
    end)
    self.pool = nil
  end
end

-- Drain available commands (bounded), advance quiescence, then pump the
-- session or settle pool work. Test-driving calls step directly with fake
-- channels; the thread entry below adds blocking waits around it.
function Worker:step()
  local drained = 0
  while drained < 16 do
    local command = self.control:pop()
    if command == nil then
      break
    end
    drained = drained + 1
    self:_handle(command)
    if self.exiting then
      return
    end
  end
  if self.pendingQuiesce ~= nil then
    self:_pumpQuiesce()
    return
  end
  if self.session ~= nil then
    local ok, failure = pcall(function()
      self.session:update()
    end)
    if not ok then
      self:_fail("controller session pump failed: " .. formatError(failure))
    end
    return
  end
  if self.pool ~= nil then
    pcall(function()
      self.pool:update()
    end)
  end
end

-- One wait/drive decision: an already-queued command outranks every wait
-- choice, immediately runnable local work pumps with no sleep, an
-- external compiler or close wait keeps one bounded sleep before polling,
-- a session clock wait sleeps at most one live cadence before repumping,
-- and only a fully idle controller blocks on its control channel. A
-- quiescence barrier that can settle now pumps at once; one still waiting
-- on worker or close results keeps polling instead of blocking, since
-- those results arrive on pool-private channels. The injected timer
-- exists only for deterministic tests; production passes love.timer.
---@param timer table<string, function> provides sleep(seconds)
function Worker:driveOnce(timer)
  assert(type(timer) == "table" and type(timer.sleep) == "function", "controller drive needs its sleep timer")
  local command = self.control:pop()
  if command ~= nil then
    self:_handle(command)
    if not self.exiting then
      self:step()
    end
    return
  end
  local activity = "idle"
  if self.pool ~= nil then
    activity = self.pool:activityState()
  end
  local quiesceSettleable = self.pendingQuiesce ~= nil and (self.pool == nil or activity == "idle")
  local sessionRunnable = self.session ~= nil and self.session:hasRunnablePlanning()
  if quiesceSettleable or sessionRunnable or activity == "runnable" then
    self:step()
    return
  end
  if activity == "waiting" then
    timer.sleep(LIVE_TICK_SECONDS)
    self:step()
    return
  end
  if self.session ~= nil and self.session.nextPlanningWakeDelay ~= nil then
    local wakeDelay = self.session:nextPlanningWakeDelay()
    if wakeDelay ~= nil then
      assert(
        type(wakeDelay) == "number" and wakeDelay >= 0 and wakeDelay < math.huge,
        "session planning wake delay must be a finite non-negative number"
      )
      if wakeDelay <= 0 then
        self:step()
        return
      end
      timer.sleep(math.min(wakeDelay, LIVE_TICK_SECONDS))
      self:step()
      return
    end
  end
  local awakened = self.control:demand()
  self:_handle(awakened)
  if not self.exiting then
    self:step()
  end
end

-- Thread entry: every loop iteration is one drive decision above, so a
-- selected settled session blocks on its control channel instead of
-- polling on a fixed tick. Exits only on shutdown.
---@param control table<string, function>
---@param reply table<string, function>
function CacheControllerWorker.run(control, reply)
  local worker = Worker.new(control, reply)
  while not worker.exiting do
    local host = rawget(_G, "love")
    local timer = host and host.timer
    if type(timer) ~= "table" or type(timer.sleep) ~= "function" then
      timer = { sleep = idleSleep }
    end
    worker:driveOnce(timer)
  end
  worker:_shutdown()
end

CacheControllerWorker.Worker = Worker

return CacheControllerWorker
