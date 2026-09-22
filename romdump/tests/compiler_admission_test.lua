-- Bounded compiler admission scenarios prove priority promotion, size-class
-- exclusion, epoch retirement, worker liveness, prepared backpressure, and
-- stale-completion rejection through the public pool boundary. All transport
-- is a controlled real-shaped thread/channel fake; readiness is observed only
-- through dispatch traffic and public status, never worker internals.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local REQUIRED = 0
local NEAR = 10
local SWEEP = 100

---@return table
local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return assert(pool)
end

local function withLove(fakeLove, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", fakeLove)
  local ok, result = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(result, 0)
  end
  return result
end

local function fakeFilesystem(backend)
  return {
    write = function(path, data)
      return backend:write(path, data)
    end,
    read = function(path)
      return backend:read(path)
    end,
    getInfo = function(path)
      return backend:getInfo(path)
    end,
    createDirectory = function(path)
      return backend:createDirectory(path)
    end,
    remove = function(path)
      return backend:remove(path)
    end,
    getDirectoryItems = function(path)
      return backend:getDirectoryItems(path)
    end,
  }
end

---@param processorCount integer
---@param hooks table|nil
---@return { dispatched: unknown[], channels: table[], threads: table[], demandTimeouts: unknown[], demandCalls: integer, workerDead: boolean, love: table<string, unknown> }
local function newThreadHost(processorCount, hooks)
  hooks = hooks or {}
  local host = {
    dispatched = {},
    channels = {},
    threads = {},
    demandTimeouts = {},
    demandCalls = 0,
    workerDead = false,
  }

  local function newChannel()
    local values = {}
    local channel = { log = {} }
    function channel:push(value)
      values[#values + 1] = value
      channel.log[#channel.log + 1] = value
      if type(value) == "table" and value.jobKey ~= nil and value.status == nil then
        host.dispatched[#host.dispatched + 1] = value.jobKey
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand(timeout)
      host.demandCalls = host.demandCalls + 1
      host.demandTimeouts[#host.demandTimeouts + 1] = timeout
      if hooks.onDemand ~= nil then
        return hooks.onDemand(channel, values, timeout, host)
      end
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    host.channels[#host.channels + 1] = channel
    return channel
  end

  local function spawnThread()
    local thread = { starts = 0, waits = 0, alive = true, threadError = nil }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.threadError
    end
    function thread:isRunning()
      if hooks.isRunning ~= nil then
        return hooks.isRunning(thread, host)
      end
      return self.starts > 0 and self.alive
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end

  host.love = {
    filesystem = fakeFilesystem(FakeCache.new()),
    system = {
      getProcessorCount = function()
        return processorCount
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
    thread = {
      newChannel = newChannel,
      newThread = function()
        return spawnThread()
      end,
    },
  }
  return host
end

local function resultChannel(host)
  return assert(host.channels[1], "the pool must create a result channel first")
end

local function inputChannel(host, workerId)
  return assert(host.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
end

local function openPool(host, mode)
  local CompilerPool = requirePool()
  return withLove(host.love, function()
    return CompilerPool.new({ mode = mode, developmentRepositoryRoot = "/checkout" })
  end)
end

local function selectGeneration(pool, host, generation, epoch)
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, epoch)
  end)
end

local function canonicalKey(kind, key)
  return kind .. ":" .. key
end

local function makeJob(options)
  return {
    generationId = options.generation,
    epoch = options.epoch,
    versionId = "heartgold",
    kind = options.kind,
    key = options.key,
    jobKey = canonicalKey(options.kind, options.key),
    priority = options.priority,
    sizeClass = options.sizeClass,
    payload = options.payload,
  }
end

local function mapPayload(mapId)
  return { mapId = mapId }
end

local function memberPayload(memberId)
  return { memberId = memberId, generationKey = "test-script-plan", producerFingerprint = "test-producer" }
end

local function requestJob(pool, host, job)
  withLove(host.love, function()
    pool:request(job)
  end)
end

local function updatePool(pool, host, budget)
  withLove(host.love, function()
    pool:update(budget)
  end)
end

local function poolStatus(pool, host, jobKey)
  return withLove(host.love, function()
    return pool:status(jobKey)
  end)
end

local function shutdownPool(pool, host)
  withLove(host.love, function()
    pool:shutdown()
  end)
end

local function pushCompletion(host, message)
  resultChannel(host):push(message)
end

local function preparedCompletion(options)
  return {
    workerId = options.workerId,
    epoch = options.epoch,
    generationId = options.generation,
    kind = options.kind,
    key = options.key,
    jobKey = canonicalKey(options.kind, options.key),
    stageName = options.stageName,
    status = "prepared",
    compileSeconds = 1,
    stageSeconds = 1,
    stagedBytes = 8,
    retiring = options.retiring or false,
  }
end

local function dispatchedStage(host, workerId, index)
  local message = inputChannel(host, workerId).log[index]
  Assert.notNil(message, "expected a dispatched job for worker " .. tostring(workerId))
  Assert.notNil(message.stageName, "dispatched work must carry its stage identity")
  return message.stageName
end

function T.promotion_reuses_a_single_queued_job()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-promotion"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = SWEEP,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "7",
      priority = REQUIRED,
      sizeClass = "heavy",
      payload = memberPayload(7),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60", "script-member:7" })
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "script-member:7"), "running")
  shutdownPool(pool, host)
end

-- The jumbo label admits no exclusivity: the jumbo dispatches first on
-- priority, the next queued job overlaps it on the second worker, and
-- only the third job waits.
function T.jumbo_work_dispatches_like_any_job()
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  local generation = "test-generation-jumbo-target"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "8",
      priority = NEAR,
      sizeClass = "heavy",
      payload = memberPayload(8),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  local first = inputChannel(host, 1).log
  Assert.equal(#first, 1, "the strongest priority dispatches first")
  Assert.equal(first[1].jobKey, "map:60")
  local second = inputChannel(host, 2).log
  Assert.equal(#second, 1, "the second worker overlaps the jumbo immediately")
  Assert.equal(second[1].jobKey, "map:61")
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  Assert.equal(poolStatus(pool, host, "script-member:8"), "queued")
  shutdownPool(pool, host)
end

function T.heavy_work_never_overlaps()
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  local generation = "test-generation-heavy-exclusion"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "8",
      priority = REQUIRED,
      sizeClass = "heavy",
      payload = memberPayload(8),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "9",
      priority = NEAR,
      sizeClass = "heavy",
      payload = memberPayload(9),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  Assert.equal(poolStatus(pool, host, "script-member:8"), "running")
  Assert.equal(poolStatus(pool, host, "script-member:9"), "queued")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "61",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(#inputChannel(host, 1).log, 1, "no second heavy job may start while one is active")
  Assert.equal(poolStatus(pool, host, "script-member:9"), "queued")
  shutdownPool(pool, host)
end

function T.retired_interest_frees_no_phantom_worker()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-retire"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60" })
  selectGeneration(pool, host, generation, 2)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 2,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:60" }, "the still-executing job keeps its worker occupied")
  Assert.equal(poolStatus(pool, host, "map:61"), "queued")
  local starts = 0
  for _, thread in ipairs(host.threads) do
    starts = starts + thread.starts
  end
  Assert.equal(#host.threads, 2, "retiring interest starts no replacement thread")
  Assert.equal(starts, 2, "retiring interest starts no replacement thread")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "eligible new work proceeds after the old slot settles")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  updatePool(pool, host, 0)
  Assert.isTrue(poolStatus(pool, host, "map:61") ~= "ready", "the stale completion publishes nothing new")
  shutdownPool(pool, host)
end

-- A drained slot takes the next queued job whatever its family: the
-- jumbo waits only while both workers are physically occupied and takes
-- the first freed slot without any drain reservation.
function T.drained_capacity_dispatches_the_waiting_jumbo()
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  local generation = "test-generation-jumbo-reservation"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "62",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(62),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:61", "map:62" })
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "63",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(63),
    })
  )
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "61",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(#inputChannel(host, 1).log, 1, "the pinned slot dispatches nothing new")
  Assert.equal(poolStatus(pool, host, "map:61"), "prepared", "the completion pins its worker")
  Assert.equal(poolStatus(pool, host, "map:60"), "queued")
  Assert.equal(poolStatus(pool, host, "map:63"), "queued")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 2,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "62",
      stageName = dispatchedStage(host, 2, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:62"), "prepared", "the second completion pins its worker too")
  Assert.equal(poolStatus(pool, host, "map:60"), "queued", "no free worker remains")
  -- Draining settles the pinned results (this harness stages no worker
  -- bytes, so publication fails them diagnosably) and the jumbo takes
  -- the first freed slot like any other job.
  updatePool(pool, host)
  local first = inputChannel(host, 1).log
  Assert.equal(#first, 2, "the jumbo job takes the first drained slot")
  Assert.equal(first[2].jobKey, "map:60")
  Assert.equal(poolStatus(pool, host, "map:63"), "queued")
  shutdownPool(pool, host)
end

function T.blocking_waits_use_bounded_demands()
  local state = { calls = 0 }
  local host = newThreadHost(4, {
    isRunning = function(_, probe)
      return not probe.workerDead
    end,
    onDemand = function(_, values, timeout, probe)
      if timeout == nil then
        error("unbounded channel wait", 0)
      end
      state.calls = state.calls + 1
      if state.calls >= 3 then
        probe.workerDead = true
        probe.threads[1].threadError = "worker exited"
      end
      if state.calls > 200 then
        error("demand budget exhausted", 0)
      end
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end,
  })
  local pool = openPool(host, "interactive")
  local generation = "test-generation-liveness"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  local ok = pcall(function()
    withLove(host.love, function()
      pool:wait("map:61")
    end)
  end)
  Assert.isFalse(ok, "a dead worker must end the blocking wait with a terminal error")
  Assert.isTrue(#host.demandTimeouts > 0, "the blocking wait must actually wait on the channel")
  for _, timeout in ipairs(host.demandTimeouts) do
    Assert.equal(type(timeout), "number", "blocking waits use finite channel demands")
  end
  local admissionOk = pcall(function()
    withLove(host.love, function()
      pool:update(0)
    end)
  end)
  Assert.isFalse(admissionOk, "an infrastructure failure stops further admission")
  shutdownPool(pool, host)
end

function T.prepared_results_hold_dispatch_slots()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-backpressure"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "7",
      priority = NEAR,
      sizeClass = "heavy",
      payload = memberPayload(7),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60" })
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:60" }, "undrained prepared output blocks new dispatch")
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared")
  Assert.equal(poolStatus(pool, host, "script-member:7"), "queued")
  shutdownPool(pool, host)
end

-- A prepared completion never retires its worker: the VM persists, no
-- replacement thread starts, and the settled worker takes new work.
function T.prepared_completion_keeps_its_worker_without_replacement()
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  local generation = "test-generation-retire-worker"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(#inputChannel(host, 1).log, 1, "the jumbo dispatches to the first worker")
  Assert.equal(inputChannel(host, 1).log[1].jobKey, "map:60")
  Assert.equal(#inputChannel(host, 2).log, 1, "the second worker admits the overlapping job")
  Assert.equal(inputChannel(host, 2).log[1].jobKey, "map:61")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared", "the completion pins its worker")
  updatePool(pool, host, 0)
  Assert.equal(host.threads[1].waits, 0, "the persistent worker is never joined")
  local starts = 0
  for _, thread in ipairs(host.threads) do
    starts = starts + thread.starts
  end
  Assert.equal(#host.threads, 2, "no replacement worker starts")
  Assert.equal(starts, 2, "no replacement worker starts")
  Assert.equal(host.threads[2].waits, 0, "the overlapping worker is never joined")
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "no completion spawns fresh capacity")
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "62",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(62),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:60"), "failed", "draining settles the unstaged harness result")
  Assert.equal(#inputChannel(host, 1).log, 2, "the settled worker takes new work itself")
  Assert.equal(inputChannel(host, 1).log[2].jobKey, "map:62")
  Assert.equal(#host.threads, 2, "settling never replaces the worker")
  shutdownPool(pool, host)
end

function T.stale_completion_cannot_settle_new_interest()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-epoch-isolation"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "7",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(7),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:7" })
  Assert.equal(poolStatus(pool, host, "map:7"), "running")
  selectGeneration(pool, host, generation, 2)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 2,
      kind = "map",
      key = "7",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(7),
    })
  )
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "7",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:7", "map:7" }, "the new interest dispatches on the settled slot")
  Assert.equal(poolStatus(pool, host, "map:7"), "running")
  updatePool(pool, host, 1)
  Assert.equal(poolStatus(pool, host, "map:7"), "running", "the stale completion settles nothing new")
  shutdownPool(pool, host)
end

function T.reversed_order_still_shares_normal_and_heavy()
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  local generation = "test-generation-order-swap"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "8",
      priority = REQUIRED,
      sizeClass = "heavy",
      payload = memberPayload(8),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "script-member:8"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  Assert.equal(#inputChannel(host, 1).log, 1)
  Assert.equal(#inputChannel(host, 2).log, 1)
  Assert.deepEqual(host.dispatched, { "script-member:8", "map:61" })
  shutdownPool(pool, host)
end

function T.promotion_while_blocked_keeps_one_queued_job()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-blocked-promotion"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "62",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(62),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60", "map:62" })
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = SWEEP,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:60", "map:62" }, "the promoted job never bypasses the executing jobs")
  Assert.equal(poolStatus(pool, host, "map:61"), "queued")
  shutdownPool(pool, host)
end

function T.mismatched_stage_stops_admission_visibly()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-stage-mismatch"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "61",
      stageName = "not-the-dispatched-stage",
    })
  )
  local first = pcall(function()
    withLove(host.love, function()
      pool:update(0)
    end)
  end)
  Assert.isFalse(first, "a stage mismatch is a terminal protocol failure")
  local second = pcall(function()
    withLove(host.love, function()
      pool:update(0)
    end)
  end)
  Assert.isFalse(second, "a protocol failure stops further admission")
  Assert.equal(#host.threads, 2, "a protocol failure starts no replacement worker")
  Assert.isTrue(poolStatus(pool, host, "map:61") ~= "ready", "the mismatched completion publishes nothing")
  shutdownPool(pool, host)
end

function T.failed_work_settles_once_and_retries_explicitly()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-explicit-retry"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = SWEEP,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  local stage = dispatchedStage(host, 1, 1)
  local failed = preparedCompletion({
    workerId = 1,
    epoch = 1,
    generation = generation,
    kind = "map",
    key = "61",
    stageName = stage,
  })
  failed.status = "failed"
  pushCompletion(host, failed)
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:61"), "failed")
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:61"), "failed", "a failed job is never retried implicitly")
  Assert.equal(#inputChannel(host, 1).log, 1, "no implicit retry dispatches new work")
  withLove(host.love, function()
    pool:retry("map:61", REQUIRED)
  end)
  Assert.equal(poolStatus(pool, host, "map:61"), "queued")
  updatePool(pool, host, 0)
  Assert.equal(#inputChannel(host, 1).log, 2, "an explicit retry creates exactly one new attempt")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  shutdownPool(pool, host)
end

function T.dropped_prepared_output_frees_its_worker_slot()
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-drop-prepared"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "7",
      priority = REQUIRED,
      sizeClass = "heavy",
      payload = memberPayload(7),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "script-member:7" })
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "script-member",
      key = "7",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "script-member:7"), "prepared")
  selectGeneration(pool, host, generation, 2)
  local diagnostics = pool:diagnostics()
  Assert.equal(diagnostics.workerStates, "idle", "a dropped prepared result releases its pinned worker")
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 2,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host, 0)
  Assert.deepEqual(
    host.dispatched,
    { "script-member:7", "map:60" },
    "jumbo work dispatches once the stale slot is freed"
  )
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  shutdownPool(pool, host)
end

local function poolDiagnostics(pool, host)
  return withLove(host.love, function()
    return pool:diagnostics()
  end)
end

local function quiescePool(pool, host)
  withLove(host.love, function()
    pool:quiesce()
  end)
end

local function poolQuiescent(pool, host)
  return withLove(host.love, function()
    return pool:isQuiescent()
  end)
end

local function retireSelection(pool, host, epoch)
  return withLove(host.love, function()
    return pool:retireSelection(epoch)
  end)
end

local function waitForProgress(pool, host)
  withLove(host.love, function()
    pool:waitForProgress()
  end)
end

-- A demanded reply is accepted through the completion validator and
-- pins its worker: no death is classified, nothing is joined, and no
-- replacement capacity appears.
function T.demanded_result_is_accepted_and_pinned()
  local generation = "test-generation-demand-before-death"
  local armed = { ready = false, stage = nil }
  local host = newThreadHost(4, {
    onDemand = function(_, values, timeout)
      Assert.equal(type(timeout), "number", "progress waits use a finite channel demand")
      if armed.ready then
        armed.ready = false
        values[#values + 1] = preparedCompletion({
          workerId = 1,
          epoch = 1,
          generation = generation,
          kind = "map",
          key = "60",
          stageName = armed.stage,
        })
      end
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end,
  })
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  armed.stage = dispatchedStage(host, 1, 1)
  armed.ready = true
  -- waitForProgress consumes the demanded reply through the completion
  -- validator, then runs its bounded publication step. The controlled host
  -- stages no worker bytes, so the drained completion settles as a
  -- diagnosable job failure here; production stages make this ready. The
  -- lifecycle facts below are the contract under test: the reply is
  -- accepted and settled, the healthy worker is never joined, no
  -- replacement capacity appears, and no worker-death error is recorded.
  waitForProgress(pool, host)
  updatePool(pool, host, 0)
  Assert.isTrue(poolStatus(pool, host, "map:60") ~= "running", "the demanded reply settles the job")
  Assert.equal(host.threads[1].waits, 0, "the healthy worker is never joined")
  Assert.equal(#host.threads, 2, "no replacement capacity appears")
  Assert.isNil(poolDiagnostics(pool, host).error, "no fatal worker-death error is recorded")
  shutdownPool(pool, host)
end

-- A reply that arrives late (after an empty drain) is accepted exactly
-- once on the second drain: the pinned result settles singly, the
-- healthy worker is never joined, and no fatal error follows.
function T.delayed_arrival_is_accepted_exactly_once()
  local generation = "test-generation-late-arrival"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  local stage = dispatchedStage(host, 1, 1)
  local channel = resultChannel(host)
  local push = channel.push
  local origPop = channel.pop
  local first = true
  channel.pop = function(self)
    if first then
      first = false
      push(
        self,
        preparedCompletion({
          workerId = 1,
          epoch = 1,
          generation = generation,
          kind = "map",
          key = "60",
          stageName = stage,
        })
      )
      return nil
    end
    return origPop(self)
  end
  -- The first drain observes the empty channel and returns; the reply
  -- queued behind it waits for the next drain. No death is classified in
  -- between: the worker is healthy throughout.
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "running", "the delayed reply waits for the next drain")
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared", "the second drain accepts the late result")
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared", "the accepted result settles exactly once")
  Assert.equal(host.threads[1].waits, 0, "the healthy worker is never joined")
  Assert.isNil(poolDiagnostics(pool, host).error, "no fatal error follows a delayed result")
  shutdownPool(pool, host)
end

function T.missing_reply_with_a_dead_worker_stays_fatal()
  local generation = "test-generation-genuine-death"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  host.threads[1].alive = false
  host.threads[1].threadError = "worker exited"
  local ok = pcall(function()
    updatePool(pool, host)
  end)
  Assert.isFalse(ok, "a dead worker with no reply ends the update with a terminal error")
  Assert.notNil(poolDiagnostics(pool, host).error, "the genuine death stays diagnosable")
  shutdownPool(pool, host)
end

-- A quiesced jumbo closes its barrier without recycling: the prepared
-- completion pins its worker, the deferred close reaches it, and the
-- acknowledged close plus the settled result closes the barrier. No
-- worker exits and none is replaced.
function T.quiesced_jumbo_closes_its_barrier_without_recycling()
  local generation = "test-generation-quiesce-jumbo"
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  local stage = dispatchedStage(host, 1, 1)
  quiescePool(pool, host)
  Assert.isFalse(poolQuiescent(pool, host), "the barrier stays open while the jumbo executes")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = stage,
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared", "the completion pins its worker")
  Assert.equal(#host.threads, 2, "no replacement starts during quiescence")
  Assert.equal(host.threads[1].waits, 0, "the persistent worker is never joined")
  local workerClose = inputChannel(host, 1).log[2]
  Assert.notNil(workerClose, "the completed worker receives its deferred close request")
  Assert.notNil(workerClose.closeToken, "the deferred close carries its barrier identity")
  -- Draining the accepted completion settles a diagnosable job failure in
  -- this harness (no worker bytes are staged); production stages publish.
  -- The barrier facts below are the contract under test.
  updatePool(pool, host)
  Assert.isNil(poolDiagnostics(pool, host).error, "settling the pinned job raises no fatal error")
  local closeMessage = inputChannel(host, 2).log[1]
  Assert.notNil(closeMessage, "the idle worker receives a close request")
  Assert.notNil(closeMessage.closeToken, "the close request carries its barrier identity")
  pushCompletion(host, { status = "context-closed", workerId = 2, closeToken = closeMessage.closeToken })
  pushCompletion(host, { status = "context-closed", workerId = 1, closeToken = workerClose.closeToken })
  updatePool(pool, host, 0)
  Assert.isTrue(poolQuiescent(pool, host), "settled result plus both acknowledgements closes the barrier")
  selectGeneration(pool, host, generation, 2)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 2,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "new selection restores capacity after the barrier")
  shutdownPool(pool, host)
end

function T.executing_normal_job_closes_after_completion_during_quiescence()
  local generation = "test-generation-quiesce-normal"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  local stage = dispatchedStage(host, 1, 1)
  quiescePool(pool, host)
  local idleClose = inputChannel(host, 2).log[1]
  Assert.notNil(idleClose, "the idle worker receives a close request")
  Assert.notNil(idleClose.closeToken, "the close request carries its barrier identity")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "61",
      stageName = stage,
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:61"), "prepared", "the completion is accepted before the deferred close")
  local closeMessage = inputChannel(host, 1).log[2]
  Assert.notNil(closeMessage, "the freed worker receives its deferred close request")
  Assert.notNil(closeMessage.closeToken, "the deferred close carries the barrier identity")
  -- Draining the accepted completion settles a diagnosable job failure in
  -- this harness (no worker bytes are staged); production stages publish.
  updatePool(pool, host)
  Assert.isNil(poolDiagnostics(pool, host).error, "settling the job raises no fatal error")
  pushCompletion(host, { status = "context-closed", workerId = 1, closeToken = closeMessage.closeToken })
  pushCompletion(host, { status = "context-closed", workerId = 2, closeToken = idleClose.closeToken })
  updatePool(pool, host, 0)
  Assert.isTrue(poolQuiescent(pool, host), "the acknowledged closes settle the barrier")
  shutdownPool(pool, host)
end

function T.stale_close_acknowledgement_keeps_the_barrier_open()
  local generation = "test-generation-stale-close"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  quiescePool(pool, host)
  local firstClose = inputChannel(host, 1).log[1]
  Assert.notNil(firstClose, "the idle worker receives a close request")
  Assert.notNil(firstClose.closeToken, "the close request carries its barrier identity")
  local secondClose = inputChannel(host, 2).log[1]
  Assert.notNil(secondClose, "the second idle worker receives a close request")
  pushCompletion(host, { status = "context-closed", workerId = 1, closeToken = firstClose.closeToken + 999 })
  updatePool(pool, host, 0)
  Assert.isFalse(poolQuiescent(pool, host), "a stale acknowledgement never closes the barrier")
  pushCompletion(host, { status = "context-closed", workerId = 1, closeToken = firstClose.closeToken })
  pushCompletion(host, { status = "context-closed", workerId = 2, closeToken = secondClose.closeToken })
  updatePool(pool, host, 0)
  Assert.isTrue(poolQuiescent(pool, host), "the matching acknowledgements close the barrier")
  quiescePool(pool, host)
  updatePool(pool, host, 0)
  Assert.isTrue(poolQuiescent(pool, host), "a repeated quiesce stays settled")
  shutdownPool(pool, host)
end

function T.selection_before_source_closure_is_rejected()
  local generation = "test-generation-early-select"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  quiescePool(pool, host)
  Assert.isFalse(poolQuiescent(pool, host), "the barrier stays open without acknowledgement")
  local ok = pcall(function()
    selectGeneration(pool, host, generation, 2)
  end)
  Assert.isFalse(ok, "a new selection is rejected while the barrier is incomplete")
  local firstClose = inputChannel(host, 1).log[1]
  local secondClose = inputChannel(host, 2).log[1]
  pushCompletion(host, { status = "context-closed", workerId = 1, closeToken = firstClose.closeToken })
  pushCompletion(host, { status = "context-closed", workerId = 2, closeToken = secondClose.closeToken })
  updatePool(pool, host, 0)
  Assert.isTrue(poolQuiescent(pool, host), "the barrier closes once acknowledged")
  selectGeneration(pool, host, generation, 2)
  shutdownPool(pool, host)
end

-- A worker that dies mid-job is terminal infrastructure failure: the
-- running job settles with the worker-death attribution, the failure
-- stays diagnosable, further admission stops, and no replacement thread
-- silently restores phantom capacity.
function T.dead_running_worker_is_terminal_without_replacement()
  local generation = "test-generation-replacement-failure"
  local host = newThreadHost(3)
  local pool = openPool(host, "batch")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:60"), "running", "the job executes")
  host.threads[1].alive = false
  local ok = pcall(function()
    updatePool(pool, host, 0)
  end)
  Assert.isFalse(ok, "a dead worker ends the update visibly")
  Assert.equal(poolStatus(pool, host, "map:60"), "failed", "the running job settles with the death attribution")
  Assert.notNil(poolDiagnostics(pool, host).error, "the worker death stays diagnosable")
  local threadsAfterFailure = #host.threads
  local second = pcall(function()
    updatePool(pool, host, 0)
  end)
  Assert.isFalse(second, "a terminal pool stops further admission")
  Assert.equal(#host.threads, threadsAfterFailure, "no silent reattempt creates phantom capacity")
  shutdownPool(pool, host)
  Assert.equal(host.threads[1].waits, 1, "shutdown joins the exited worker exactly once")
  shutdownPool(pool, host)
end

function T.close_send_failure_is_terminal()
  local generation = "test-generation-close-failure"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  inputChannel(host, 1).push = function()
    error("injected close failure")
  end
  local ok = pcall(function()
    quiescePool(pool, host)
  end)
  Assert.isFalse(ok, "a failed close request ends quiescence visibly")
  Assert.notNil(poolDiagnostics(pool, host).error, "the close failure stays diagnosable")
  local admission = pcall(function()
    requestJob(
      pool,
      host,
      makeJob({
        generation = generation,
        epoch = 1,
        kind = "map",
        key = "61",
        priority = NEAR,
        sizeClass = "normal",
        payload = mapPayload(61),
      })
    )
  end)
  Assert.isFalse(admission, "a terminal pool stops further admission")
  shutdownPool(pool, host)
  shutdownPool(pool, host)
end

function T.retirement_cancels_interest_without_freeing_the_slot()
  local generation = "test-generation-retire-selection"
  local host = newThreadHost(4)
  local pool = openPool(host, "interactive")
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "script-member",
      key = "7",
      priority = REQUIRED,
      sizeClass = "heavy",
      payload = memberPayload(7),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "script-member:7"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "queued")
  Assert.isTrue(retireSelection(pool, host, 1), "retiring the selected epoch reports its release")
  Assert.isFalse(retireSelection(pool, host, 1), "a repeated retirement is a no-op")
  Assert.isFalse(retireSelection(pool, host, 999), "a stale retirement is a no-op")
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "script-member:7" }, "queued work never starts after retirement")
  Assert.equal(poolStatus(pool, host, "script-member:7"), "running", "executing work stays charged")
  Assert.equal(poolStatus(pool, host, "map:61"), "cancelled")
  local waitState = withLove(host.love, function()
    return pool:wait("map:61")
  end)
  Assert.equal(waitState, "cancelled", "a blocking wait ends terminally for retired interest")
  local submit = pcall(function()
    requestJob(
      pool,
      host,
      makeJob({
        generation = generation,
        epoch = 1,
        kind = "map",
        key = "62",
        priority = NEAR,
        sizeClass = "normal",
        payload = mapPayload(62),
      })
    )
  end)
  Assert.isFalse(submit, "a retired selection accepts no new submission")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "script-member",
      key = "7",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.deepEqual(host.dispatched, { "script-member:7" }, "the late result dispatches nothing new")
  Assert.equal(poolStatus(pool, host, "script-member:7"), "cancelled", "late output never publishes")
  shutdownPool(pool, host)
end

-- Worker counts are a fixed physical cap, not a function of job families:
-- batch and interactive pools run at most two compilers on capable hosts,
-- and a single processor still runs one worker. No family label changes this.
function T.fixed_worker_counts_bound_batch_and_interactive_pools()
  local batchHost = newThreadHost(6)
  local batchPool = openPool(batchHost, "batch")
  Assert.equal(#batchHost.threads, 2, "a batch pool on six processors runs exactly two workers")
  shutdownPool(batchPool, batchHost)
  local interactiveHost = newThreadHost(6)
  local interactivePool = openPool(interactiveHost, "interactive")
  Assert.equal(#interactiveHost.threads, 2, "an interactive pool on six processors runs two workers")
  shutdownPool(interactivePool, interactiveHost)
  local singleHost = newThreadHost(1)
  local singlePool = openPool(singleHost, "batch")
  Assert.equal(#singleHost.threads, 1, "a single-processor batch pool still runs one worker")
  shutdownPool(singlePool, singleHost)
end

-- Family labels never serialize the bounded workers: two jumbo jobs
-- dispatch together onto the two batch workers instead of draining the
-- pool for the first one.
function T.jumbo_jobs_overlap_on_bounded_batch_workers()
  local host = newThreadHost(6)
  local pool = openPool(host, "batch")
  local generation = "test-generation-jumbo-overlap"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "jumbo",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  updatePool(pool, host)
  Assert.deepEqual(
    host.dispatched,
    { "map:60", "map:61" },
    "two jumbo jobs dispatch together without family exclusivity"
  )
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  shutdownPool(pool, host)
end

-- Independent jobs overlap on the bounded workers and settled workers are
-- never replaced: completing both jobs spawns no fresh worker.
function T.independent_jobs_overlap_and_settle_without_worker_replacement()
  local host = newThreadHost(6)
  local pool = openPool(host, "batch")
  local workersAtOpen = #host.threads
  local generation = "test-generation-overlap-settle"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "two independent jobs overlap")
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = dispatchedStage(host, 1, 1),
    })
  )
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 2,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "61",
      stageName = dispatchedStage(host, 2, 1),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:60"), "prepared")
  Assert.equal(poolStatus(pool, host, "map:61"), "prepared")
  Assert.equal(#host.threads, workersAtOpen, "settled workers are not replaced")
  shutdownPool(pool, host)
end

-- Two required jobs overlap on a capable interactive pool: both bounded
-- workers take one required job each without replacement capacity.
function T.two_required_jobs_overlap_on_a_capable_interactive_pool()
  local host = newThreadHost(6)
  local pool = openPool(host, "interactive")
  Assert.equal(#host.threads, 2, "a capable interactive pool runs two workers")
  local generation = "test-generation-required-overlap"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(60),
    })
  )
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "61",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(61),
    })
  )
  updatePool(pool, host)
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "both required jobs dispatch together")
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "running")
  Assert.equal(#inputChannel(host, 1).log, 1, "the first worker takes exactly one job")
  Assert.equal(#inputChannel(host, 2).log, 1, "the second worker takes exactly one job")
  Assert.equal(#host.threads, 2, "overlap uses the bounded workers without replacement")
  shutdownPool(pool, host)
end

-- Interactive worker capacity follows the bounded processor formula: one
-- worker below three processors and two workers above, while batch keeps
-- its current one-or-two ceiling.
function T.processor_count_bounds_interactive_worker_capacity()
  local oneHost = newThreadHost(1)
  local onePool = openPool(oneHost, "interactive")
  Assert.equal(#oneHost.threads, 1, "a single-processor interactive pool runs one worker")
  shutdownPool(onePool, oneHost)
  local twoHost = newThreadHost(2)
  local twoPool = openPool(twoHost, "interactive")
  Assert.equal(#twoHost.threads, 1, "a two-processor interactive pool runs one worker")
  shutdownPool(twoPool, twoHost)
  local sixHost = newThreadHost(6)
  local sixPool = openPool(sixHost, "interactive")
  Assert.equal(#sixHost.threads, 2, "a six-processor interactive pool runs two workers")
  shutdownPool(sixPool, sixHost)
  local batchHost = newThreadHost(6)
  local batchPool = openPool(batchHost, "batch")
  Assert.equal(#batchHost.threads, 2, "a six-processor batch pool keeps two workers")
  shutdownPool(batchPool, batchHost)
end

-- Non-required interactive work keeps a single physical slot: a second
-- near/sweep job waits while the first runs, including while the first
-- result is prepared but unpublished, and proceeds once the slot drains.
-- Both background priorities share one parametrized pass plus one mixed
-- sweep-then-near pass.
function T.non_required_work_keeps_a_single_interactive_slot()
  for _, priority in ipairs({ NEAR, SWEEP }) do
    local host = newThreadHost(6)
    local pool = openPool(host, "interactive")
    local generation = "test-generation-single-slot-" .. tostring(priority)
    selectGeneration(pool, host, generation, 1)
    requestJob(
      pool,
      host,
      makeJob({
        generation = generation,
        epoch = 1,
        kind = "map",
        key = "60",
        priority = priority,
        sizeClass = "normal",
        payload = mapPayload(60),
      })
    )
    requestJob(
      pool,
      host,
      makeJob({
        generation = generation,
        epoch = 1,
        kind = "map",
        key = "61",
        priority = priority,
        sizeClass = "normal",
        payload = mapPayload(61),
      })
    )
    updatePool(pool, host)
    Assert.equal(poolStatus(pool, host, "map:60"), "running", "the first background job runs")
    Assert.equal(poolStatus(pool, host, "map:61"), "queued", "the second background job waits for the single slot")
    if priority == NEAR then
      pushCompletion(
        host,
        preparedCompletion({
          workerId = 1,
          epoch = 1,
          generation = generation,
          kind = "map",
          key = "60",
          stageName = dispatchedStage(host, 1, 1),
        })
      )
      updatePool(pool, host, 0)
      Assert.equal(poolStatus(pool, host, "map:60"), "prepared", "the completion pins its worker")
      Assert.equal(
        poolStatus(pool, host, "map:61"),
        "queued",
        "a prepared background result still holds the single slot"
      )
      updatePool(pool, host)
      Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "the waiting job proceeds once the slot drains")
      Assert.equal(poolStatus(pool, host, "map:61"), "running")
    end
    shutdownPool(pool, host)
  end
  local host = newThreadHost(6)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-single-slot-mixed"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "70",
      priority = SWEEP,
      sizeClass = "normal",
      payload = mapPayload(70),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:70"), "running")
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "71",
      priority = NEAR,
      sizeClass = "normal",
      payload = mapPayload(71),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(poolStatus(pool, host, "map:71"), "queued", "near work waits while the single background slot is held")
  shutdownPool(pool, host)
end

-- Required work takes the free slot beside running background work: the
-- background job keeps its worker, the required job dispatches to the
-- other worker, and a further background job stays queued.
function T.required_work_dispatches_beside_running_background_work()
  local host = newThreadHost(6)
  local pool = openPool(host, "interactive")
  local generation = "test-generation-required-beside-background"
  selectGeneration(pool, host, generation, 1)
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "70",
      priority = SWEEP,
      sizeClass = "normal",
      payload = mapPayload(70),
    })
  )
  updatePool(pool, host)
  Assert.equal(poolStatus(pool, host, "map:70"), "running", "the background job occupies its worker")
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "71",
      priority = REQUIRED,
      sizeClass = "normal",
      payload = mapPayload(71),
    })
  )
  updatePool(pool, host)
  Assert.deepEqual(
    host.dispatched,
    { "map:70", "map:71" },
    "required work uses the free slot without preempting background work"
  )
  Assert.equal(poolStatus(pool, host, "map:70"), "running", "the background job keeps its worker")
  Assert.equal(poolStatus(pool, host, "map:71"), "running")
  Assert.equal(#inputChannel(host, 2).log, 1, "the required job takes the second worker")
  requestJob(
    pool,
    host,
    makeJob({
      generation = generation,
      epoch = 1,
      kind = "map",
      key = "72",
      priority = SWEEP,
      sizeClass = "normal",
      payload = mapPayload(72),
    })
  )
  updatePool(pool, host, 0)
  Assert.equal(
    poolStatus(pool, host, "map:72"),
    "queued",
    "a second background job waits while the single background slot is held"
  )
  shutdownPool(pool, host)
end

return { tests = T }
