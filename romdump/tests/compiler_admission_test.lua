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
  Assert.deepEqual(host.dispatched, { "map:60" })
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "script-member:7"), "queued")
  shutdownPool(pool, host)
end

function T.jumbo_work_admits_only_the_first_worker()
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
  Assert.equal(#first, 1, "only the jumbo job may dispatch while it waits")
  Assert.equal(first[1].jobKey, "map:60")
  Assert.equal(#inputChannel(host, 2).log, 0, "the second worker never takes jumbo-adjacent work")
  Assert.equal(poolStatus(pool, host, "map:60"), "running")
  Assert.equal(poolStatus(pool, host, "map:61"), "queued")
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
  Assert.equal(#host.threads, 1, "retiring interest starts no replacement thread")
  Assert.equal(starts, 1, "retiring interest starts no replacement thread")
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

function T.drained_capacity_waits_for_the_blocked_jumbo()
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
  Assert.equal(#inputChannel(host, 1).log, 1, "the drained slot is reserved for the waiting jumbo")
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
  local first = inputChannel(host, 1).log
  Assert.equal(#first, 2, "the jumbo job takes the fully drained window")
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

function T.jumbo_completion_retires_its_worker()
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
  Assert.equal(#inputChannel(host, 1).log, 1, "jumbo work dispatches only to the first worker")
  Assert.equal(inputChannel(host, 1).log[1].jobKey, "map:60")
  Assert.equal(#inputChannel(host, 2).log, 0, "no other compiler is admitted beside jumbo")
  host.threads[1].alive = false
  pushCompletion(
    host,
    preparedCompletion({
      workerId = 1,
      epoch = 1,
      generation = generation,
      kind = "map",
      key = "60",
      stageName = dispatchedStage(host, 1, 1),
      retiring = true,
    })
  )
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  updatePool(pool, host, 0)
  Assert.equal(host.threads[1].waits, 1, "the retired worker is joined exactly once")
  local starts = 0
  for _, thread in ipairs(host.threads) do
    starts = starts + thread.starts
  end
  Assert.equal(#host.threads, 3, "one replacement worker restarts the retired slot")
  Assert.equal(starts, 3, "one replacement worker restarts the retired slot")
  Assert.equal(host.threads[2].waits, 0, "the idle worker is never joined while work remains")
  Assert.deepEqual(host.dispatched, { "map:60", "map:61" }, "queued work resumes on the replacement slot")
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
  updatePool(pool, host)
  Assert.deepEqual(host.dispatched, { "map:60" })
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
  Assert.deepEqual(host.dispatched, { "map:60" }, "the promoted job never bypasses the executing job")
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
  Assert.equal(#host.threads, 1, "a protocol failure starts no replacement worker")
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

return { tests = T }
