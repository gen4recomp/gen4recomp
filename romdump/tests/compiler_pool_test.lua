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
  }
end

function T.failed_preparation_preserves_the_previous_map()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = BundleFixture.minimal()
  MapCacheWriter.write(cache, first)
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
    kind = "map",
    jobKey = "map:61",
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

function T.queued_jobs_are_deduplicated_and_priority_fifo()
  local CompilerPool = requirePool()
  local host = newThreadHost(4)
  local pool = assert(withLove(host.love, function()
    return CompilerPool.new({ versionId = "heartgold", mode = "batch", developmentRepositoryRoot = "/checkout" })
  end))

  pool:request({ kind = "map", key = "map:A", priority = 100, payload = { mapId = 60 } })
  pool:request({ kind = "map", key = "map:B", priority = 20, payload = { mapId = 61 } })
  pool:request({ kind = "map", key = "map:A", priority = 5, payload = { mapId = 60 } })
  pool:request({ kind = "map", key = "map:C", priority = 20, payload = { mapId = 62 } })
  withLove(host.love, function()
    pool:update()
  end)

  Assert.deepEqual(host.dispatched, { "map:A", "map:B", "map:C" })
  Assert.equal(pool:status("map:A"), "running")
  Assert.equal(pool:status("map:B"), "running")
  Assert.equal(pool:status("map:C"), "running")
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

function T.staged_shared_files_promote_once_and_keep_existing_bytes()
  local prepared = requirePreparedArtifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = prepared.new({
    cacheFs = cache,
    kind = "map",
    jobKey = "map:61",
    stageName = "promotion-first",
  })
  first:stageFs():write("geometry/shared", "first")
  first:addSharedFile("geometry/shared")
  first:stageFs():write("maps/61/complete", "ready")
  first:addOwnedRoot("maps/61")
  first:finishSuccess({ mapId = 61 })
  first:publish()
  Assert.equal(cache:read("geometry/shared"), "first")

  local second = prepared.new({
    cacheFs = cache,
    kind = "map",
    jobKey = "map:62",
    stageName = "promotion-second",
  })
  second:stageFs():write("geometry/shared", "different")
  second:addSharedFile("geometry/shared")
  second:stageFs():write("maps/62/complete", "ready")
  second:addOwnedRoot("maps/62")
  second:finishSuccess({ mapId = 62 })
  second:publish()
  Assert.equal(cache:read("geometry/shared"), "first", "an existing immutable file is not overwritten")
  Assert.equal(cache:read("maps/62/complete"), "ready")
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

return { tests = T }
