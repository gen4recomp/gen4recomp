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
  -- Worker-side reconciliation seals shared proof before success: a staged
  -- contradiction fails here, never reaching controller publication.
  local conflict = Assert.throws(function()
    clashing:finishSuccess({ mapId = 63, marker = "complete" })
  end)
  Assert.isTrue(
    tostring(conflict):find("PREPARED_SHARED_CONFLICT", 1, true) ~= nil,
    "the worker seals the shared contradiction"
  )
  clashing:abort()
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

-- Large-backlog dispatch keeps priority/FIFO/admission order without sorting
-- the queued corpus on the dispatch path: a promoted sweep job keeps its
-- original sequence among required jobs while weaker work waits.
function T.large_backlog_dispatch_preserves_order_without_whole_queue_sort()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "backlog-order-generation"
  local function mapJob(key, mapId, priority, sizeClass)
    return {
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass or "normal",
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    for index = 1, 1200 do
      pool:request(mapJob(tostring(30000 + index), 30000 + index, 100))
    end
    pool:request(mapJob("31201", 31201, 10))
    pool:request(mapJob("31202", 31202, 10))
    pool:request(mapJob("31203", 31203, 0))
    pool:request(mapJob("30001", 30001, 0))
    local realSort = table.sort
    table.sort = function()
      error("hot-path whole-queue sort during dispatch", 0)
    end
    local ok, sortFailure = pcall(function()
      pool:update()
    end)
    table.sort = realSort
    if not ok then
      error(sortFailure, 0)
    end
  end)
  Assert.deepEqual(
    { host.dispatched[1], host.dispatched[2] },
    { "map:30001", "map:31203" },
    "the promoted sweep job keeps its original sequence ahead of the later required job"
  )
  Assert.equal(pool:status("map:30001"), "running", "the promoted job executes")
  Assert.equal(pool:status("map:31203"), "running", "the required job executes")
  Assert.equal(pool:status("map:31201"), "queued", "weaker work waits behind required")
  Assert.equal(pool:status("map:30002"), "queued", "the backlog waits behind required")
  pool:shutdown()
end

-- A waiting jumbo reserves the drain window against same/lower priority
-- work while a stronger arrival still dispatches, all without sorting the
-- queued corpus on the dispatch path.
function T.stronger_priority_bypasses_a_reserved_jumbo_without_sort()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "jumbo-reservation-generation"
  local function mapJob(key, mapId, priority, sizeClass)
    return {
      generationId = generation,
      epoch = 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass,
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("32001", 32001, 0, "heavy"))
    pool:update()
  end)
  Assert.deepEqual(host.dispatched, { "map:32001" }, "the heavy job takes the first worker")
  withLove(host.love, function()
    pool:request(mapJob("32002", 32002, 100, "jumbo"))
    pool:request(mapJob("32003", 32003, 100, "normal"))
    pool:request(mapJob("32004", 32004, 0, "normal"))
    local realSort = table.sort
    table.sort = function()
      error("hot-path whole-queue sort during dispatch", 0)
    end
    local ok, sortFailure = pcall(function()
      pool:update()
    end)
    table.sort = realSort
    if not ok then
      error(sortFailure, 0)
    end
  end)
  Assert.deepEqual(
    host.dispatched,
    { "map:32001", "map:32004" },
    "only the stronger arrival dispatches while the jumbo waits for the drain"
  )
  Assert.equal(pool:status("map:32002"), "queued", "the jumbo waits for a full drain")
  Assert.equal(pool:status("map:32003"), "queued", "reserved same-priority work waits")
  local _, sweepDetails = pool:status("map:32003")
  Assert.equal(
    type(sweepDetails) == "table" and sweepDetails.waitingOn,
    "reserved-for-jumbo",
    "the reservation names its cause"
  )
  pool:shutdown()
end

-- Promotion never leaves a dispatchable stale queue node and retry rejoins
-- behind older same-priority work with a fresh sequence.
function T.promotion_stale_nodes_never_dispatch_and_retry_takes_a_fresh_sequence()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "stale-node-generation"
  local function mapJob(key, mapId, priority)
    return {
      generationId = generation,
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
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("33001", 33001, 100))
    pool:request(mapJob("33002", 33002, 100))
    pool:request(mapJob("33001", 33001, 0))
    pool:update()
  end)
  local dispatchedOrder = {}
  withLove(host.love, function()
    local dispatched = host.channels[2]:pop()
    assert(type(dispatched) == "table", "the worker received a job record")
    dispatchedOrder[#dispatchedOrder + 1] = assert(dispatched.jobKey, "dispatched work names its job")
    local stageName = assert(dispatched.stageName, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33001",
      jobKey = "map:33001",
      stageName = stageName,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:33001"), "failed", "the worker failure settles the job")
    Assert.equal(pool:status("map:33002"), "running", "the waiter takes the freed worker")
    pool:request(mapJob("33003", 33003, 100))
    pool:retry("map:33001", 100)
    local runningMessage = host.channels[2]:pop()
    assert(type(runningMessage) == "table", "the waiter reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(runningMessage.jobKey, "dispatched work names its job")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33002",
      jobKey = "map:33002",
      stageName = assert(runningMessage.stageName, "dispatched work carries its stage identity"),
      status = "failed",
    })
    pool:update()
    local thirdMessage = host.channels[2]:pop()
    assert(type(thirdMessage) == "table", "the third job reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(thirdMessage.jobKey, "dispatched work names its job")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "33003",
      jobKey = "map:33003",
      stageName = assert(thirdMessage.stageName, "dispatched work carries its stage identity"),
      status = "failed",
    })
    pool:update()
    local retriedMessage = host.channels[2]:pop()
    assert(type(retriedMessage) == "table", "the retried job reached the worker")
    dispatchedOrder[#dispatchedOrder + 1] = assert(retriedMessage.jobKey, "dispatched work names its job")
  end)
  Assert.deepEqual(
    dispatchedOrder,
    { "map:33001", "map:33002", "map:33003", "map:33001" },
    "the stale promotion node never dispatches and the retry rejoins last"
  )
  pool:shutdown()
end

-- Heavy/jumbo admission survives prepared pinning, selection retirement,
-- and late terminal replies: a prepared heavy blocks a second heavy, a
-- jumbo waits for the drain, an old physical heavy keeps blocking across a
-- new epoch, and its late reply releases exactly once.
function T.heavy_and_jumbo_activity_survives_prepared_retirement_and_late_completion()
  local CompilerPool = requirePool()
  local host = newThreadHost(3)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "scheduler-lifecycle-generation"
  local function mapJob(key, mapId, priority, sizeClass, epoch)
    return {
      generationId = generation,
      epoch = epoch or 1,
      versionId = "heartgold",
      kind = "map",
      key = key,
      jobKey = "map:" .. key,
      priority = priority,
      sizeClass = sizeClass,
      payload = { mapId = mapId },
    }
  end
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(mapJob("61", 61, 0, "heavy"))
    pool:update()
    Assert.equal(pool:status("map:61"), "running", "the heavy job executes")
    pool:request(mapJob("62", 62, 0, "normal"))
    pool:update()
    Assert.equal(pool:status("map:62"), "running", "a normal job coexists with the heavy job")
    local normalMessage = host.channels[3]:pop()
    assert(type(normalMessage) == "table", "the second worker received the normal job")
    local normalStage = assert(normalMessage.stageName, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 2,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "62",
      jobKey = "map:62",
      stageName = normalStage,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:62"), "failed", "the normal job settles without holding activity")
    Assert.equal(pool:status("map:61"), "running", "the heavy job still executes")
    pool:request(mapJob("63", 63, 0, "heavy"))
    local secondState, secondDetails = pool:status("map:63")
    Assert.equal(secondState, "queued", "the second heavy waits")
    Assert.equal(
      type(secondDetails) == "table" and secondDetails.waitingOn,
      "active-job",
      "the wait names heavy activity"
    )
    pool:request(mapJob("64", 64, 0, "jumbo"))
    local jumboState, jumboDetails = pool:status("map:64")
    Assert.equal(jumboState, "queued", "the jumbo waits for a full drain")
    Assert.equal(
      type(jumboDetails) == "table" and jumboDetails.waitingOn,
      "active-job",
      "the jumbo wait names activity"
    )
    local heavyMessage = host.channels[2]:pop()
    assert(type(heavyMessage) == "table", "the first worker received the heavy job")
    local heavyStage = assert(heavyMessage.stageName, "dispatched work carries its stage identity")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "61",
      jobKey = "map:61",
      stageName = heavyStage,
      status = "prepared",
      compileSeconds = 1,
      stageSeconds = 1,
      workSeconds = 1,
      stagedBytes = 8,
    })
    pool:update(0)
    Assert.equal(pool:status("map:61"), "prepared", "the prepared heavy stays pinned")
    Assert.equal(pool:status("map:63"), "queued", "a prepared heavy still blocks the next heavy")
    Assert.equal(pool:status("map:64"), "queued", "a prepared heavy still blocks the jumbo")
    pool:update()
    Assert.equal(
      pool:status("map:61"),
      "failed",
      "the terminal heavy releases admission even when publication finds no staged bytes"
    )
    Assert.equal(pool:status("map:63"), "running", "the second heavy dispatches after the release")
    Assert.equal(pool:status("map:64"), "queued", "the jumbo still waits while the heavy runs")
    Assert.isTrue(pool:retireSelection(1), "the selection retires while work executes")
    Assert.equal(pool:status("map:63"), "running", "retirement keeps the executing record")
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 2)
    pool:request(mapJob("65", 65, 0, "heavy", 2))
    local nextState, nextDetails = pool:status("map:65")
    Assert.equal(nextState, "queued", "the new epoch heavy waits")
    Assert.equal(
      type(nextDetails) == "table" and nextDetails.waitingOn,
      "active-job",
      "the retired physical heavy still counts"
    )
    local retiredMessage = host.channels[2]:pop()
    assert(type(retiredMessage) == "table", "the retired heavy reached the first worker")
    local retiredStage = assert(retiredMessage.stageName, "retired work carries its stage identity")
    host.channels[1]:push({
      workerId = 1,
      epoch = 1,
      generationId = generation,
      kind = "map",
      key = "63",
      jobKey = "map:63",
      stageName = retiredStage,
      status = "failed",
    })
    pool:update()
    Assert.equal(pool:status("map:65"), "running", "the late reply releases the retired heavy exactly once")
    pool:request(mapJob("66", 66, 0, "heavy", 2))
    Assert.equal(pool:status("map:66"), "queued", "a further heavy still waits behind the running one")
  end)
  pool:shutdown()
end

-- A worker reuse completion carries no stage and publishes nothing: the
-- pool marks the current-epoch record ready at once and frees the worker
-- for the next dispatch.
function T.reused_completions_become_ready_without_publication()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "reuse-completion-generation"
  local job = {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = "60",
    jobKey = "map:60",
    priority = 0,
    sizeClass = "normal",
    payload = { mapId = 60 },
  }
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(job)
    pool:update()
  end)
  Assert.equal(pool:status("map:60"), "running", "the job dispatches to a worker")
  local dispatched = host.channels[2]:pop()
  assert(type(dispatched) == "table", "the worker received the job")
  local stageName = assert(dispatched.stageName, "dispatched work carries its stage identity")
  host.channels[1]:push({
    workerId = 1,
    epoch = 1,
    generationId = generation,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    stageName = stageName,
    status = "reused",
    workSeconds = 0,
    timingReason = "reused",
    retiring = false,
  })
  withLove(host.love, function()
    pool:update()
  end)
  Assert.equal(pool:status("map:60"), "ready", "the reused result settles ready")
  Assert.equal(pool:diagnostics().pendingPublications, 0, "reuse enters no publication queue")
  local followup = {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = "61",
    jobKey = "map:61",
    priority = 0,
    sizeClass = "normal",
    payload = { mapId = 61 },
  }
  withLove(host.love, function()
    pool:request(followup)
    pool:update()
  end)
  Assert.equal(pool:status("map:61"), "running", "the reuse freed its worker for new work")
  pool:shutdown()
end

-- A reused jumbo validation retires no worker: the VM stays available
-- for the next dispatch instead of recycling.
function T.reused_jumbo_completions_keep_their_worker()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "reuse-jumbo-generation"
  local job = {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = "70",
    jobKey = "map:70",
    priority = 0,
    sizeClass = "jumbo",
    payload = { mapId = 70 },
  }
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(job)
    pool:update()
  end)
  Assert.equal(pool:status("map:70"), "running", "the jumbo job dispatches while idle")
  local dispatched = host.channels[2]:pop()
  assert(type(dispatched) == "table", "the worker received the jumbo job")
  host.channels[1]:push({
    workerId = 1,
    epoch = 1,
    generationId = generation,
    kind = "map",
    key = "70",
    jobKey = "map:70",
    stageName = assert(dispatched.stageName, "dispatched work carries its stage identity"),
    status = "reused",
    workSeconds = 0,
    timingReason = "reused",
    retiring = false,
  })
  withLove(host.love, function()
    pool:update()
  end)
  Assert.equal(pool:status("map:70"), "ready", "the reused jumbo settles ready")
  local followup = {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = "71",
    jobKey = "map:71",
    priority = 0,
    sizeClass = "jumbo",
    payload = { mapId = 71 },
  }
  withLove(host.love, function()
    pool:request(followup)
    pool:update()
  end)
  Assert.equal(pool:status("map:71"), "running", "a reuse-only jumbo retires no worker VM")
  pool:shutdown()
end

-- A late reuse from a retired selection can never become ready: the
-- stale result is cancelled and no live root moves.
function T.stale_reused_completions_cannot_publish()
  local CompilerPool = requirePool()
  local host = newThreadHost(2)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))
  local generation = "stale-reuse-generation"
  local job = {
    generationId = generation,
    epoch = 1,
    versionId = "heartgold",
    kind = "map",
    key = "60",
    jobKey = "map:60",
    priority = 0,
    sizeClass = "normal",
    payload = { mapId = 60 },
  }
  local stageName = nil
  withLove(host.love, function()
    pool:selectGeneration({ versionId = "heartgold", generationId = generation }, 1)
    pool:request(job)
    pool:update()
  end)
  local dispatched = host.channels[2]:pop()
  assert(type(dispatched) == "table", "the worker received the job")
  stageName = assert(dispatched.stageName, "dispatched work carries its stage identity")
  withLove(host.love, function()
    Assert.isTrue(pool:retireSelection(1), "the selection retires while the worker runs")
  end)
  host.channels[1]:push({
    workerId = 1,
    epoch = 1,
    generationId = generation,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    stageName = stageName,
    status = "reused",
    workSeconds = 0,
    timingReason = "reused",
    retiring = false,
  })
  withLove(host.love, function()
    pool:update()
  end)
  Assert.equal(pool:status("map:60"), "cancelled", "the retired reuse never becomes ready")
  Assert.equal(pool:diagnostics().pendingPublications, 0, "the stale reuse enters no publication queue")
  pool:shutdown()
end

-- Controller publication is metadata and renames only: with backend
-- counters armed after the worker-side finish, publishing a prepared
-- artifact with owned and shared payload reads and writes no payload
-- bytes while the final live bytes equal the staged bytes.
function T.controller_publication_moves_payload_without_byte_copies()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = "payload-free-publication-generation"
  local artifact = prepared.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map",
    key = "60",
    jobKey = "map:60",
    stageName = "payload-free-stage",
  })
  local scene = string.rep("scene-payload", 64)
  local shared = string.rep("shared-payload", 64)
  artifact:stageFs():write("maps/60/scene.lua", scene)
  artifact:addOwnedRoot("maps/60")
  artifact:stageFs():write("geometry/shared", shared)
  artifact:addSharedFile("geometry/shared")
  artifact:finishSuccess({ mapId = 60, marker = "payload-free-marker" })
  local reads, writes = {}, {}
  local realBackendRead = backend.read
  local realBackendWrite = backend.write
  backend.read = function(self, path)
    reads[#reads + 1] = path
    return realBackendRead(self, path)
  end
  backend.write = function(self, path, data)
    writes[#writes + 1] = path
    return realBackendWrite(self, path, data)
  end
  local ok, failure = pcall(function()
    artifact:publish({
      generationId = generation,
      epoch = 1,
      kind = "map",
      key = "60",
      jobKey = "map:60",
    })
  end)
  backend.read = realBackendRead
  backend.write = realBackendWrite
  if not ok then
    error(failure, 0)
  end
  for _, path in ipairs(reads) do
    Assert.isFalse(
      path:find("maps/60", 1, true) ~= nil or path:find("geometry/shared", 1, true) ~= nil,
      "controller publication reads no payload bytes: " .. tostring(path)
    )
  end
  for _, path in ipairs(writes) do
    Assert.isFalse(
      path:find("maps/60", 1, true) ~= nil or path:find("geometry/shared", 1, true) ~= nil,
      "controller publication copies no payload bytes: " .. tostring(path)
    )
  end
  Assert.equal(cache:read("maps/60/scene.lua"), scene, "the owned payload moves intact")
  Assert.equal(cache:read("geometry/shared"), shared, "the shared install lands intact")
end

return { tests = T }
