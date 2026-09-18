-- Compiler-pool component scenarios cover queue ownership, staged map
-- publication, and unsupported host capability handling.

local Assert = require("tests.support.Assert")
local BundleFixture = require("tests.support.BundleFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")

local T = {}

---@return CompilerPool
local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return assert(pool) --[[@as CompilerPool]]
end

local function requirePreparedArtifact()
  local ok, prepared = pcall(require, "romdump.src.build.PreparedArtifact")
  Assert.isTrue(ok, "the production prepared-artifact boundary is missing")
  return prepared --[[@as PreparedArtifact]]
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

local function newThreadHost(processorCount)
  local dispatched = {}
  local threads = {}
  local channels = {}
  -- Test-local liveness control: healthy threads by default. A test may arm
  -- stopOnDispatch so the first worker that receives real work reports itself
  -- stopped with no error text, exercising the production fatal path.
  local control = { stopOnDispatch = false, stopDone = false }
  local filesystemBackend = FakeCache.new()
  local filesystem = {
    write = function(path, data)
      return filesystemBackend:write(path, data)
    end,
    read = function(path)
      return filesystemBackend:read(path)
    end,
    getInfo = function(path)
      return filesystemBackend:getInfo(path)
    end,
    createDirectory = function(path)
      return filesystemBackend:createDirectory(path)
    end,
    remove = function(path)
      return filesystemBackend:remove(path)
    end,
    getDirectoryItems = function(path)
      return filesystemBackend:getDirectoryItems(path)
    end,
  }

  local function newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      if type(value) == "table" and value.jobKey ~= nil then
        dispatched[#dispatched + 1] = value.jobKey
        if control.stopOnDispatch and not control.stopDone and threads[1] ~= nil then
          control.stopDone = true
          threads[1].stopped = true
        end
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      local value = table.remove(values, 1)
      return value
    end
    function channel:demand()
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    channels[#channels + 1] = channel
    return channel
  end

  local function newThread()
    local thread = { starts = 0, waits = 0, stopped = false }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      if self.stopped then
        return false
      end
      return self.starts > 0 and self.waits == 0
    end
    threads[#threads + 1] = thread
    return thread
  end

  return {
    love = {
      filesystem = filesystem,
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
        newThread = newThread,
      },
    },
    dispatched = dispatched,
    threads = threads,
    channels = channels,
    control = control,
  }
end

-- Fixture-owned evidence paths: os.tmpname() cannot generate names under this
-- runner, while direct writes succeed, so profiles use deterministic unique
-- names under a fixture-owned root that each test removes after use.
local profileCounter = 0
local function tempProfilePath(name)
  profileCounter = profileCounter + 1
  local root = os.getenv("TMPDIR") or "/tmp"
  os.execute('mkdir -p "' .. root .. '/compiler-pool-evidence"')
  return root .. "/compiler-pool-evidence/" .. name .. "-" .. tostring(profileCounter) .. ".jsonl"
end

---@param path string
---@return string[] lines
local function readEvidenceLines(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  os.remove(path)
  local lines = {}
  for line in (body or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

function T.failed_preparation_preserves_the_previous_map()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = "failed-preparation-generation"
  local first = BundleFixture.minimal()
  local baseline = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = tostring(first.mapId),
    jobKey = "map:" .. first.mapId,
    stageName = "map-preparation-baseline",
  })
  MapCacheWriter.stage(baseline, first)
  baseline:finishSuccess({ mapId = first.mapId, marker = first.marker })
  baseline:publish({
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = tostring(first.mapId),
    jobKey = "map:" .. first.mapId,
  })
  local oldMarker = cache:read(MapAssetCache.mapDir(first.mapId) .. "/complete")
  local oldScene = cache:read(MapAssetCache.mapDir(first.mapId) .. "/scene.lua")

  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("scene.lua", 1, true) then
      error("injected preparation failure")
    end
    return originalWrite(self, path, data)
  end

  local artifact = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = tostring(first.mapId),
    jobKey = "map:" .. first.mapId,
    stageName = "map-preparation-test",
  })
  Assert.throws(function()
    MapCacheWriter.stage(artifact, BundleFixture.minimal())
  end)
  artifact:abort()
  backend.write = originalWrite

  Assert.equal(cache:read(MapAssetCache.mapDir(first.mapId) .. "/complete"), oldMarker)
  Assert.equal(cache:read(MapAssetCache.mapDir(first.mapId) .. "/scene.lua"), oldScene)
  Assert.isNil(backend:getInfo("staging/heartgold/map-preparation-test"))
end

-- Epoch ownership pins the census contract: a new selection inherits no
-- live lookup, the same selection is idempotent, and identical keys
-- restart as new-epoch interest while old physical slots stay busy.
function T.selected_epoch_resets_current_lookup()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority, epoch)
    return {
      generationId = "epoch-generation",
      epoch = epoch,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    pool:request(mapJob("60", 60, 100, 1))
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "one job exists per identity within its epoch")
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "epoch-generation" }, 2)
  end)
  Assert.equal(pool:status("map:60"), "unknown", "the new epoch inherits no live lookup")
  withLove(host.love, function()
    pool:request(mapJob("60", 60, 100, 2))
    pool:update()
  end)
  Assert.equal(pool:status("map:60"), "queued", "identical keys restart as new-epoch interest")
  Assert.deepEqual(host.dispatched, { "map:60" }, "the new record waits on the still-busy old slot")
  local diagnostics = pool:diagnostics()
  Assert.isTrue(
    tostring(diagnostics.workerStates):find("busy", 1, true) ~= nil,
    "old physical slots stay busy across selections: " .. tostring(diagnostics.workerStates)
  )
  pool:shutdown()
end

-- Queued promotion reorders dispatch while running work holds its slot:
-- strengthening a queued record promotes it, strengthening a running
-- record neither preempts nor resubmits it.
function T.queued_promotion_reorders_dispatch_while_running_holds()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority)
    return {
      generationId = "promotion-generation",
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "promotion-generation" }, 1)
    pool:request(mapJob("60", 60, 100))
    pool:request(mapJob("61", 61, 100))
    pool:request(mapJob("60", 60, 0))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "the promoted queued job dispatches first")
  Assert.equal(pool:status("map:60"), "running", "the promoted job executes")
  Assert.equal(pool:status("map:61"), "queued", "unpromoted work waits")
  withLove(host.love, function()
    pool:request(mapJob("60", 60, 0))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:60" }, "strengthening a running job resubmits nothing")
  Assert.equal(pool:status("map:60"), "running", "running work is never preempted")
  Assert.equal(pool:status("map:61"), "queued", "the waiter still waits on the busy slot")
  pool:shutdown()
end

-- Retirement cancels logical queued work: the record reads cancelled, no
-- new work is accepted into the retired selection, and the next epoch
-- starts clean.
function T.retired_selection_cancels_queued_work()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local function mapJob(key, mapId, priority, epoch)
    return {
      generationId = "retirement-generation",
      epoch = epoch,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "retirement-generation" }, 1)
    pool:request(mapJob("60", 60, 100, 1))
    Assert.isTrue(pool:retireSelection(1), "retirement accepts its epoch")
    Assert.isFalse(pool:retireSelection(1), "retirement does not repeat")
  end)
  Assert.equal(pool:status("map:60"), "cancelled", "retired queued work reads cancelled")
  local ok = pcall(function()
    withLove(host.love, function()
      pool:request(mapJob("61", 61, 100, 1))
    end)
  end)
  Assert.isFalse(ok, "the retired selection accepts no later work")
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "retirement-generation" }, 2)
    pool:request(mapJob("60", 60, 100, 2))
  end)
  Assert.equal(pool:status("map:60"), "queued", "the next epoch accepts the key as new work")
  pool:shutdown()
end

function T.queued_jobs_are_deduplicated_and_priority_fifo()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = "deduplication-generation" }, 1)
  end)

  local function mapJob(key, mapId, priority)
    return {
      generationId = "deduplication-generation",
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = "normal",
      payload = { mapId = mapId },
    }
  end

  withLove(host.love, function()
    pool:request(mapJob("60", 60, 100))
    pool:request(mapJob("61", 61, 10))
    pool:request(mapJob("60", 60, 0))
    pool:request(mapJob("62", 62, 10))
    pool:update()
  end)

  Assert.deepEqual(host.dispatched, { "map:60", "map:61", "map:62" })
  Assert.equal(pool:status("map:60"), "running")
  Assert.equal(pool:status("map:61"), "running")
  Assert.equal(pool:status("map:62"), "running")
  pool:shutdown()
end

function T.missing_thread_support_fails_before_cache_mutation()
  local CompilerPool = requirePool()
  for _, mode in ipairs({ "batch", "interactive" }) do
    local createdWorkers = 0
    local fakeLove = {
      system = {
        getProcessorCount = function()
          return 4
        end,
      },
      thread = {
        newThread = function()
          createdWorkers = createdWorkers + 1
          return {}
        end,
        newChannel = function()
          return {}
        end,
      },
    }
    withLove(fakeLove, function()
      local err = Assert.throws(function()
        CompilerPool.new({ versionId = "heartgold", mode = mode })
      end)
      Assert.isTrue(tostring(err):lower():find("thread", 1, true) ~= nil, "error names missing thread support")
    end)
    Assert.equal(createdWorkers, 0, "capability preflight starts no workers")
  end
end

function T.constructor_failure_joins_started_workers()
  local CompilerPool = requirePool()
  local started = {}
  local threads = {}
  local function channel()
    local values = {}
    return {
      push = function(_, value)
        values[#values + 1] = value
        return true
      end,
      pop = function()
        if #values == 0 then
          return nil
        end
        return table.remove(values, 1)
      end,
      demand = function(self)
        return self:pop()
      end,
      getCount = function()
        return #values
      end,
    }
  end
  local fakeLove = {
    system = {
      getProcessorCount = function()
        return 4
      end,
    },
    thread = {
      newChannel = channel,
      newThread = function()
        if #threads == 2 then
          error("injected worker construction failure")
        end
        local thread = { waits = 0 }
        function thread:start()
          started[#started + 1] = self
        end
        function thread:wait()
          self.waits = self.waits + 1
        end
        function thread:getError()
          return nil
        end
        threads[#threads + 1] = thread
        return thread
      end,
    },
  }

  withLove(fakeLove, function()
    Assert.throws(function()
      CompilerPool.new({ versionId = "heartgold", mode = "batch" })
    end)
  end)
  Assert.equal(#started, 2, "workers before the failed construction were started")
  for _, thread in ipairs(threads) do
    Assert.equal(thread.waits, 1, "each acquired worker is joined exactly once")
  end
end

function T.staged_shared_files_promote_once_and_conflicts_fail()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = "shared-promotion-generation"
  local function publishShared(key, stageName, sharedBytes)
    local artifact = prepared.new({
      cacheFs = cache,
      generationId = generation,
      epoch = 1,
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      stageName = stageName,
    })
    artifact:stageFs():write("geometry/shared", sharedBytes)
    artifact:addSharedFile("geometry/shared")
    artifact:stageFs():write("maps/" .. key .. "/complete", "ready")
    artifact:addOwnedRoot("maps/" .. key)
    artifact:finishSuccess({ mapId = tonumber(key), marker = "complete" })
    artifact:publish({
      generationId = generation,
      epoch = 1,
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
    })
  end
  publishShared("61", "promotion-first", "first")
  Assert.equal(cache:read("geometry/shared"), "first")

  publishShared("62", "promotion-second", "first")
  Assert.equal(cache:read("geometry/shared"), "first", "identical shared bytes promote once")
  Assert.equal(cache:read("maps/62/complete"), "ready")

  local clashing = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = "63",
    jobKey = "map:63",
    stageName = "promotion-conflict",
  })
  clashing:stageFs():write("geometry/shared", "different")
  clashing:addSharedFile("geometry/shared")
  clashing:stageFs():write("maps/63/complete", "ready")
  clashing:addOwnedRoot("maps/63")
  clashing:finishSuccess({ mapId = 63, marker = "complete" })
  Assert.throws(function()
    clashing:publish({
      generationId = generation,
      epoch = 1,
      kind = "map",
      key = "63",
      jobKey = "map:63",
    })
  end)
  Assert.equal(cache:read("geometry/shared"), "first", "a shared conflict never overwrites live bytes")
  Assert.isFalse(cache:exists("maps/63/complete"), "a shared conflict never exposes the staged family")
end

function T.shutdown_is_idempotent_and_joins_workers()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ versionId = "heartgold", mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  pool:shutdown()
  pool:shutdown()
  for _, thread in ipairs(host.threads) do
    Assert.equal(thread.waits, 1, "shutdown joins every worker once")
  end
end

function T.worker_dispatcher_rejects_unknown_job_kinds()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  Assert.throws(function()
    CompilerWorker.execute({ kind = "unknown", key = "unknown:1" }, {})
  end)
end

function T.plain_worker_failures_keep_their_message()
  local CompilerPool = requirePool()
  local prepared = requirePreparedArtifact()
  local ScopedFs = require("libs.storage.src.ScopedFs")
  local backendStore = FakeCache.new()
  local filesystem = {
    write = function(path, data)
      return backendStore:write(path, data)
    end,
    read = function(path)
      return backendStore:read(path)
    end,
    getInfo = function(path)
      return backendStore:getInfo(path)
    end,
    createDirectory = function(path)
      return backendStore:createDirectory(path)
    end,
    remove = function(path)
      return backendStore:remove(path)
    end,
    getDirectoryItems = function(path)
      return backendStore:getDirectoryItems(path)
    end,
  }
  local resultChannel = nil
  local inputChannels = {}
  local channels = {}
  local function newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand()
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread()
    local thread = { starts = 0, waits = 0 }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return nil
    end
    function thread:isRunning()
      return self.starts > 0 and self.waits == 0
    end
    return thread
  end
  local fakeLove = {
    filesystem = filesystem,
    system = {
      getProcessorCount = function()
        return 2
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
    thread = {
      newChannel = newChannel,
      newThread = newThread,
    },
  }
  local generationId = "plain-failure-generation"
  local pool = assert(withLove(fakeLove, function()
    local instance = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
    instance:selectGeneration({ versionId = "heartgold", generationId = generationId }, 1)
    instance:request({
      versionId = "heartgold",
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = "60",
      jobKey = "map:60",
      priority = 0,
      sizeClass = "normal",
      payload = { mapId = 60 },
    })
    instance:update()
    return instance
  end))
  resultChannel = channels[1]
  for index = 2, #channels do
    inputChannels[#inputChannels + 1] = channels[index]
  end
  local stageName, workerId = nil, nil
  for offset, channel in ipairs(inputChannels) do
    local dispatched = channel:pop()
    if type(dispatched) == "table" and dispatched.jobKey == "map:60" then
      stageName = dispatched.stageName
      workerId = offset
    end
  end
  Assert.notNil(stageName, "the pool dispatched the job with a stage name")
  Assert.notNil(workerId, "the pool dispatched the job to a known worker")
  local backend = withLove(fakeLove, function()
    return ScopedFs.loveBackend()
  end)
  local cache = CacheFs.forVersion("heartgold", backend)
  local artifact = prepared.new({
    cacheFs = cache,
    generationId = generationId,
    epoch = 1,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    stageName = stageName,
  })
  artifact:finishFailure("plain worker boom")
  resultChannel:push({
    workerId = workerId,
    epoch = 1,
    generationId = generationId,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    stageName = stageName,
    status = "failed",
  })
  withLove(fakeLove, function()
    pool:update()
  end)
  local state, details = pool:status("map:60")
  Assert.equal(state, "failed", "the worker failure settles the job")
  local message = tostring(details and details.error or "")
  Assert.isTrue(
    message:find("plain worker boom", 1, true) ~= nil,
    "the surfaced failure keeps the worker message: " .. message
  )
  Assert.isTrue(
    message:find("table: 0x", 1, true) == nil,
    "the surfaced failure is never an opaque table address: " .. message
  )
  pool:shutdown()
end

function T.dispatched_stages_skip_names_left_by_an_earlier_process()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local nonce = pool.nonce
  Assert.equal(type(nonce), "number", "the pool carries its process-local allocation identity")
  local generation = "orphan-stage-generation"
  local occupied = {}
  withLove(host.love, function()
    for suffix = 1, 8 do
      local name = string.format("run%d-w1-j%d", nonce, suffix)
      occupied[#occupied + 1] = name
      CacheFs.forArtifactStage("heartgold", name):write("orphan", "busy")
    end
    CacheFs.forVersion("heartgold"):write("maps/61/complete", "live")
  end)
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request({
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = "61",
      jobKey = "map:61",
      priority = 10,
      sizeClass = "normal",
      payload = { mapId = 61 },
    })
    pool:update()
  end)
  local dispatched = host.channels[2]:pop()
  Assert.notNil(dispatched, "the pool dispatched the job to the first worker")
  assert(type(dispatched) == "table", "a dispatched job is a record")
  local stageName = assert(dispatched.stageName, "dispatched work carries its stage identity")
  withLove(host.love, function()
    Assert.isNil(
      CacheFs.forArtifactStage("heartgold", stageName):read("orphan"),
      "the dispatched stage is absent from the version staging namespace"
    )
    for _, name in ipairs(occupied) do
      Assert.equal(
        CacheFs.forArtifactStage("heartgold", name):read("orphan"),
        "busy",
        "an earlier stage is left untouched: " .. name
      )
    end
    Assert.equal(
      CacheFs.forVersion("heartgold"):read("maps/61/complete"),
      "live",
      "live bytes stay untouched until a valid publication"
    )
  end)
  pool:shutdown()
end

-- A worker thread that stops behind a real command keeps truthful evidence:
-- the pool records the unexpected stop, the command finalizes every known
-- row with an unsuccessful footer instead of escaping, and the worker joins
-- exactly once. Real command, session, dependencies, and pool; only the
-- thread transport is controlled.
function T.stopped_worker_thread_finalizes_command_evidence()
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function(versionId)
    return realForVersion(versionId, backend)
  end
  local host = newThreadHost(2)
  host.control.stopOnDispatch = true
  local profilePath = tempProfilePath("stopped-worker")
  local ok, outcome = pcall(function()
    return withLove(host.love, function()
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = {
          versionId = "heartgold",
          generationId = "stopped-worker-generation",
          producerId = "d" .. string.rep("1", 64),
        },
        requirements = { "field-camera:global", "field-weather:global" },
        profile = profilePath,
        log = function() end,
      })
      -- Box both returns: the transport helper keeps only the first value.
      return { report = report, failure = err }
    end)
  end)
  local report = ok and outcome.report or nil
  local err = ok and outcome.failure or outcome
  CacheFs.forVersion = realForVersion
  Assert.isTrue(ok, "a recorded pool failure must finalize evidence instead of escaping: " .. tostring(report))
  Assert.isNil(report, "an interrupted command returns no success report")
  Assert.equal(err, "compiler worker stopped unexpectedly", "the command preserves the recorded fatal value")
  local lines = readEvidenceLines(profilePath)
  local header, footer
  local rows = {}
  for _, line in ipairs(lines) do
    if line:find('"type":"header"', 1, true) ~= nil then
      header = line
    elseif line:find('"type":"footer"', 1, true) ~= nil then
      footer = line
    elseif line:find('"type":"job"', 1, true) ~= nil then
      rows[#rows + 1] = line
    end
  end
  assert(header ~= nil, "the interrupted run still opens its evidence")
  assert(footer ~= nil, "the interrupted run still closes with a footer")
  Assert.equal(#rows, 2, "every known key keeps exactly one row")
  local failed, cancelled = nil, nil
  for _, row in ipairs(rows) do
    if row:find('"state":"failed"', 1, true) ~= nil then
      failed = row
    elseif row:find('"state":"cancelled"', 1, true) ~= nil then
      cancelled = row
    end
  end
  assert(failed ~= nil, "the dispatched job keeps its failed row")
  Assert.isTrue(
    failed:find("stopped unexpectedly", 1, true) ~= nil,
    "the failed row keeps the recorded value, got: " .. tostring(failed)
  )
  assert(cancelled ~= nil, "work that never ran keeps an explicit cancelled row")
  Assert.isTrue(
    footer:find('"complete":false', 1, true) ~= nil,
    "the interrupted run never claims completeness, got: " .. tostring(footer)
  )
  Assert.equal(#host.dispatched, 1, "only the first job reaches a worker before the stop")
  Assert.equal(#host.threads, 1, "one physical worker serves the command")
  Assert.equal(host.threads[1].waits, 1, "the stopped worker joins exactly once")
end

return { tests = T }
