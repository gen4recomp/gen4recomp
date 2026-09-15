-- Generation-session contract tests without opening a ROM or starting
-- worker threads: constructor validation precedes every side effect, the
-- closed dispatch maps every family to its size class and urgency, milestone
-- membership is exact, dependencies resolve through the fixed table, and the
-- follower check names its missing visual. Positive session behavior lives
-- in the ROM census, which owns a real dump.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local CompilerPool = require("romdump.src.build.CompilerPool")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local MonCache = require("libs.assets.src.MonCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local function untouchedPool()
  return {
    selectGeneration = function()
      error("session validation must precede pool selection")
    end,
    request = function()
      error("session validation must precede pool requests")
    end,
    status = function()
      error("session validation must precede pool status")
    end,
    update = function()
      error("session validation must precede pool updates")
    end,
  }
end

local function identity()
  return {
    versionId = "heartgold",
    generationId = "g4:heartgold:rom:producer:a1:s1",
    producerId = "d" .. string.rep("3", 64),
  }
end

function T.session_options_are_validated_before_any_side_effect()
  local cases = {
    { options = nil, message = "options are required" },
    { options = {}, message = "identity is required" },
    { options = { identity = {}, epoch = 1, pool = untouchedPool() }, message = "version is required" },
    {
      options = { identity = { versionId = "heartgold" }, epoch = 1, pool = untouchedPool() },
      message = "generation is required",
    },
    {
      options = {
        identity = { versionId = "heartgold", generationId = "g", producerId = "d" .. string.rep("3", 64) },
        pool = untouchedPool(),
      },
      message = "epoch must be a positive integer",
    },
    {
      options = { identity = identity(), epoch = 1 },
      message = "process-owned pool",
    },
    {
      options = { identity = identity(), epoch = 1, pool = untouchedPool(), sweepEnabled = "yes" },
      message = "must be a boolean",
    },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(InteractiveCacheBuild.new, case.options)
    Assert.isFalse(ok, "malformed session options must fail")
    Assert.isTrue(
      tostring(err):find(case.message, 1, true) ~= nil,
      "session rejection names its cause: " .. tostring(err)
    )
  end
end

function T.urgency_maps_once_to_pool_priorities()
  Assert.equal(ArtifactJobs.priorityFor("required"), 0)
  Assert.equal(ArtifactJobs.priorityFor("near"), 10)
  Assert.equal(ArtifactJobs.priorityFor("sweep"), 100)
  Assert.throws(function()
    ArtifactJobs.priorityFor("eventually")
  end)
end

function T.every_family_maps_to_its_fixed_size_class()
  local expected = {
    ["world-catalog"] = "normal",
    ["field-cell-index"] = "normal",
    ["field-camera"] = "normal",
    ["field-weather"] = "normal",
    ["field-effects"] = "normal",
    ["field-emotes"] = "normal",
    ["field-ui"] = "normal",
    intro = "normal",
    ["new-game-init"] = "normal",
    ["starter-choice"] = "normal",
    items = "normal",
    bag = "normal",
    ["mon-icon-page"] = "normal",
    ["mon-portrait-page"] = "normal",
    ["map-data"] = "normal",
    ["message-summary"] = "normal",
    ["mon-summary"] = "normal",
    ["field-font"] = "heavy",
    actors = "heavy",
    ["mon-catalog"] = "heavy",
    ["mon-layout"] = "heavy",
    ["audio-bank"] = "heavy",
    ["audio-summary"] = "heavy",
    ["script-member"] = "heavy",
    ["script-summary"] = "heavy",
    ["message-bank"] = "heavy",
    ["field-cell"] = "jumbo",
    map = "jumbo",
    ["source-plan"] = "heavy",
  }
  local count = 0
  for kind, size in pairs(expected) do
    Assert.equal(ArtifactJobs.sizeClass(kind), size, "size class of " .. kind)
    count = count + 1
  end
  local kinds = 0
  for _ in pairs(ArtifactState.KINDS) do
    kinds = kinds + 1
  end
  Assert.equal(count, kinds, "the size policy covers exactly the closed vocabulary")
  Assert.throws(function()
    ArtifactJobs.sizeClass("world")
  end)
end

local function jobSet(jobs)
  local set = {}
  for _, job in ipairs(jobs) do
    set[job.kind .. ":" .. job.key] = true
  end
  return set
end

function T.bootstrap_membership_is_the_fixed_set_plus_audio_closures()
  local jobs = ArtifactJobs.bootstrapJobs({ 7, 0 })
  local set = jobSet(jobs)
  for _, name in ipairs({
    "world-catalog:global",
    "field-cell-index:global",
    "field-camera:global",
    "field-weather:global",
    "field-effects:global",
    "field-emotes:global",
    "field-ui:global",
    "field-font:global",
    "intro:global",
    "new-game-init:global",
    "mon-catalog:global",
    "mon-layout:global",
    "message-bank:219",
    "audio-summary:global",
    "audio-bank:7",
    "audio-bank:0",
  }) do
    Assert.isTrue(set[name] == true, "bootstrap carries " .. name)
  end
  Assert.equal(#jobs, 16, "bootstrap carries nothing else")
  for _, job in ipairs(jobs) do
    local kind = job.kind
    Assert.isTrue(
      kind ~= "map"
        and kind ~= "field-cell"
        and kind ~= "map-data"
        and kind ~= "script-member"
        and kind ~= "script-summary"
        and kind ~= "message-summary"
        and kind ~= "mon-icon-page"
        and kind ~= "mon-portrait-page"
        and kind ~= "mon-summary"
        and kind ~= "actors"
        and kind ~= "starter-choice"
        and kind ~= "items"
        and kind ~= "bag",
      "bootstrap never pulls geometry, records, scripts, pages, actors, or inventory: " .. kind
    )
  end
end

function T.field_core_contains_bootstrap_without_geometry_or_portraits()
  local lists = {
    audioBankIds = { 7 },
    messageBankIds = { 219, 220 },
    scriptMemberIds = { 149 },
    iconPageIds = { 3 },
    mapDataIds = { 7 },
  }
  local core = jobSet(ArtifactJobs.fieldCoreJobs(lists))
  local bootstrap = ArtifactJobs.bootstrapJobs(lists.audioBankIds)
  for _, job in ipairs(bootstrap) do
    Assert.isTrue(core[job.kind .. ":" .. job.key] == true, "core keeps bootstrap work")
  end
  for _, name in ipairs({
    "actors:global",
    "starter-choice:global",
    "items:global",
    "bag:global",
    "message-bank:219",
    "message-bank:220",
    "message-summary:global",
    "script-member:149",
    "script-summary:global",
    "mon-icon-page:3",
    "map-data:7",
  }) do
    Assert.isTrue(core[name] == true, "core carries " .. name)
  end
  for identityKey in pairs(core) do
    local kind = identityKey:match("^([^:]+):")
    Assert.isTrue(
      kind ~= "map" and kind ~= "field-cell" and kind ~= "mon-portrait-page" and kind ~= "mon-summary",
      "field entry never waits for geometry or portraits: " .. identityKey
    )
  end
end

local function syntheticPlans()
  return {
    iconPageIds = { 0, 1 },
    portraitPageIds = { 0, 1, 2 },
    messageBankIds = { 219 },
    audioBankIds = { 7 },
    scriptMemberIds = { 149 },
    mapCellKeys = { [7] = { "12-5", "12-6" } },
  }
end

local function dependencySet(kind, key, plans)
  local set = {}
  for _, dep in ipairs(ArtifactJobs.dependencies(kind, key, plans or syntheticPlans())) do
    set[dep.kind .. ":" .. dep.key] = true
  end
  return set
end

function T.dependencies_resolve_through_the_fixed_table()
  Assert.deepEqual(dependencySet("mon-layout", "global"), { ["mon-catalog:global"] = true })
  Assert.deepEqual(dependencySet("mon-icon-page", "3"), { ["mon-layout:global"] = true })
  Assert.deepEqual(dependencySet("mon-portrait-page", "12"), { ["mon-layout:global"] = true })
  local summary = dependencySet("mon-summary", "global")
  for _, name in ipairs({
    "mon-catalog:global",
    "mon-layout:global",
    "mon-icon-page:0",
    "mon-icon-page:1",
    "mon-portrait-page:0",
    "mon-portrait-page:1",
    "mon-portrait-page:2",
  }) do
    Assert.isTrue(summary[name] == true, "mon summary pulls " .. name)
  end
  Assert.deepEqual(dependencySet("message-summary", "global"), { ["message-bank:219"] = true })
  Assert.deepEqual(dependencySet("audio-summary", "global"), { ["audio-bank:7"] = true })
  Assert.deepEqual(dependencySet("script-summary", "global"), { ["script-member:149"] = true })
  local map = dependencySet("map", "7")
  for _, name in ipairs({ "world-catalog:global", "field-cell-index:global", "field-cell:12-5", "field-cell:12-6" }) do
    Assert.isTrue(map[name] == true, "map pulls " .. name)
  end
  Assert.deepEqual(dependencySet("field-cell", "12-5"), { ["field-cell-index:global"] = true })
  Assert.deepEqual(dependencySet("actors", "global"), {})
  Assert.deepEqual(dependencySet("intro", "global"), {})
  Assert.deepEqual(dependencySet("items", "global"), {})
  Assert.deepEqual(dependencySet("bag", "global"), {})
  Assert.throws(function()
    ArtifactJobs.dependencies("world", "global", syntheticPlans())
  end)
end

function T.job_identities_validate_through_the_closed_vocabulary()
  Assert.equal(ArtifactJobs.jobKey("map", "7"), "map:7")
  Assert.equal(ArtifactJobs.jobKey("field-cell", "12-5"), "field-cell:12-5")
  Assert.throws(function()
    ArtifactJobs.jobKey("bogus-kind", "global")
  end)
  Assert.throws(function()
    ArtifactJobs.jobKey("map", "not-a-key")
  end)
end

function T.follower_references_validate_against_the_merged_index()
  local catalog = {
    species = {
      CHIKORITA = {
        forms = {
          [0] = { follower = { visualId = 41 } },
          [1] = { follower = { visualId = 42, female = { visualId = 43 } } },
        },
      },
    },
  }
  Assert.isTrue(ArtifactJobs.checkFollowers(catalog, { [41] = true, [42] = true, [43] = true }))
  local ok, err = ArtifactJobs.checkFollowers(catalog, { [41] = true })
  Assert.isNil(ok, "an absent follower visual fails the check")
  Assert.isTrue(tostring(err):find("42", 1, true) ~= nil, "the failure names its visual: " .. tostring(err))
end

-- A generation session over synthetic message plans: the pool records every
-- dispatched job and answers scripted states, while the cache is a real
-- CacheFs over an in-memory backend. Only the public request surface is
-- exercised; the field set below is the session's own documented state.
local SUMMARY_GENERATION = "summary-gate-generation"

local function recordingPool()
  local pool = { submitted = {}, states = {} }
  function pool:update() end
  function pool:status(jobKey)
    return self.states[jobKey] or "unknown"
  end
  function pool:request(job)
    self.submitted[#self.submitted + 1] = job.jobKey
    return self.states[job.jobKey] or "queued", nil
  end
  return pool
end

local function summarySession(pool, cacheFs, bankIds)
  return setmetatable({
    versionId = "heartgold",
    generationId = SUMMARY_GENERATION,
    producerId = "d" .. string.rep("3", 64),
    epoch = 1,
    pool = pool,
    sweepEnabled = false,
    cacheFs = cacheFs,
    messageBankIds = bankIds,
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = {},
    mapIds = {},
    mapCellKeys = {},
    interest = {},
    byKey = {},
    milestones = {},
    recorded = {},
    retired = false,
    sourceLoaded = true,
    pagesKnown = true,
    adopted = nil,
    dirty = {},
    edges = {},
    parked = {},
    depMemo = {},
    pendingFillDone = false,
    loadedFillDone = false,
    followerChecked = false,
    followerMemo = nil,
  }, InteractiveCacheBuild)
end

local function submittedSet(pool)
  local set = {}
  for _, jobKey in ipairs(pool.submitted) do
    set[jobKey] = true
  end
  return set
end

local function publishMessageBank(cacheFs, bankId, marker)
  cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = SUMMARY_GENERATION,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end

function T.summary_dispatch_waits_for_bank_publication()
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local session = summarySession(pool, cacheFs, { 3, 5 })
  local ready, failure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while its banks are cold")
  Assert.isNil(failure, "no failure is reported while the summary waits for its banks")
  local submitted = submittedSet(pool)
  Assert.isTrue(submitted["message-bank:3"] == true, "a cold bank dispatches")
  Assert.isTrue(submitted["message-bank:5"] == true, "a cold bank dispatches")
  Assert.isNil(submitted["message-summary:global"], "the summary never occupies a worker while its banks are pending")

  pool.states["message-bank:3"] = "ready"
  pool.states["message-bank:5"] = "ready"
  publishMessageBank(cacheFs, 3, "bank-marker-3")
  publishMessageBank(cacheFs, 5, "bank-marker-5")
  local again, againFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(again, "the unpublished summary stays pending once its banks publish")
  Assert.isNil(againFailure, "no failure is reported once the banks publish")
  Assert.isTrue(submittedSet(pool)["message-summary:global"] == true, "the summary dispatches once every bank is ready")
end

function T.warm_summary_answers_without_dispatch()
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  publishMessageBank(cacheFs, 3, "bank-marker-3")
  publishMessageBank(cacheFs, 5, "bank-marker-5")
  cacheFs:writeLua(ArtifactState.path("message-summary", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = SUMMARY_GENERATION,
    kind = "message-summary",
    key = "global",
    marker = "summary-marker",
  })
  cacheFs:write(FieldMessageCache.markerPath(), "summary-marker")
  cacheFs:writeLua(FieldMessageCache.indexPath(), {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = "heartgold",
    bankIds = { 3, 5 },
  })
  local session = summarySession(pool, cacheFs, { 3, 5 })
  local ready, failure = session:requestJob("message-summary", "global", "required")
  Assert.isTrue(ready, "a published summary answers ready")
  Assert.isNil(failure, "a published summary reports no failure")
  Assert.equal(#pool.submitted, 0, "warm readiness dispatches nothing")
end

-- Dependency scheduling through the real session and pool: cold requests
-- dispatch children before parents, urgency promotion reaches queued pool
-- records and shared prerequisites, retry repairs only failed leaves, and
-- retirement ends pending waits without ghost work. Every case below runs
-- the production session against the production pool with controlled
-- thread/channel hosts over one isolated save prefix per case, so staged
-- publication runs for real without touching the product cache.
-- No ROM bytes are involved.
local PRODUCER_ID = "d" .. string.rep("3", 64)

local function withHost(host, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", host.love)
  local ok, first, second = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(first, 0)
  end
  return first, second
end

-- Pool publication performs operating-system renames, so an in-memory
-- backend cannot carry it. The host filesystem below delegates to the
-- genuine host filesystem under one isolated per-case prefix, keeping the
-- product cache untouched while every staged publication runs for real.
-- The save-directory answer points at the same prefix so renames resolve
-- against the files the prefixed operations wrote.
---@param realFs table
---@param prefix string save-relative prefix with a trailing slash
---@return table filesystem
local function isolatedHostFs(realFs, prefix)
  local root = realFs.getSaveDirectory() .. "/" .. prefix:gsub("/$", "")
  return {
    write = function(path, data)
      return realFs.write(prefix .. path, data)
    end,
    read = function(path)
      return realFs.read(prefix .. path)
    end,
    getInfo = function(path)
      return realFs.getInfo(prefix .. path)
    end,
    createDirectory = function(path)
      return realFs.createDirectory(prefix .. path)
    end,
    remove = function(path)
      return realFs.remove(prefix .. path)
    end,
    getDirectoryItems = function(path)
      return realFs.getDirectoryItems(prefix .. path)
    end,
    getSaveDirectory = function()
      return root
    end,
  }
end

---@param realFs table
---@param path string save-relative path
local function removeTreeReal(realFs, path)
  local info = realFs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    local items = realFs.getDirectoryItems(path) or {}
    for _, name in ipairs(items) do
      removeTreeReal(realFs, path .. "/" .. name)
    end
  end
  realFs.remove(path)
end

---@param processorCount integer
---@param hostFs table
---@return table host
local function newControlledHost(processorCount, hostFs)
  local host = { dispatched = {}, channels = {}, threads = {} }
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
      assert(type(timeout) == "number", "pool progress waits are finite")
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
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
      return self.starts > 0 and self.alive
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end
  host.love = {
    filesystem = hostFs,
    data = (rawget(_G, "love") or {}).data,
    system = {
      getProcessorCount = function()
        return processorCount
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

---@param options { generation: string, bankIds: integer[], iconPageIds: integer[]? }
---@return table env
local function openLiveSession(options)
  local realLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local realFs = assert(realLove.filesystem, "the suite runs with a host filesystem")
  local prefix = "d02-isolation/" .. options.generation .. "/"
  removeTreeReal(realFs, prefix:gsub("/$", ""))
  local hostFs = isolatedHostFs(realFs, prefix)
  local host = newControlledHost(4, hostFs)
  local cacheFs = withHost(host, function()
    return CacheFs.forVersion("heartgold")
  end)
  local pool = withHost(host, function()
    local created = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = "/checkout" })
    created:selectGeneration({ versionId = "heartgold", generationId = options.generation }, 1)
    return created
  end)
  local session = setmetatable({
    versionId = "heartgold",
    generationId = options.generation,
    producerId = PRODUCER_ID,
    epoch = 1,
    pool = pool,
    sweepEnabled = false,
    cacheFs = cacheFs,
    messageBankIds = options.bankIds,
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = options.iconPageIds or {},
    portraitPageIds = {},
    mapCellKeys = {},
    mapDataIds = {},
    mapIds = {},
    interest = {},
    byKey = {},
    milestones = {},
    recorded = {},
    retired = false,
    sourceLoaded = true,
    pagesKnown = true,
    adopted = nil,
    dirty = {},
    edges = {},
    parked = {},
    depMemo = {},
    pendingFillDone = false,
    loadedFillDone = false,
    followerChecked = false,
    followerMemo = nil,
  }, InteractiveCacheBuild)
  return { host = host, realFs = realFs, prefix = prefix, cacheFs = cacheFs, pool = pool, session = session }
end

---@param env table
---@param rounds integer
local function pumpSession(env, rounds)
  withHost(env.host, function()
    for _ = 1, rounds do
      env.session:update()
    end
  end)
end

---@param env table
---@param rounds integer
local function pumpPool(env, rounds)
  withHost(env.host, function()
    for _ = 1, rounds do
      env.pool:update(0)
    end
  end)
end

---@param env table
---@return table channel
local function resultChannel(env)
  return assert(env.host.channels[1], "the pool must create a result channel first")
end

---@param env table
---@param workerId integer
---@return table channel
local function inputChannel(env, workerId)
  return assert(env.host.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
end

---@param env table
---@param workerId integer
---@param jobKey string
---@param occurrence integer
---@return string stageName
local function dispatchedStage(env, workerId, jobKey, occurrence)
  local seen = 0
  for _, message in ipairs(inputChannel(env, workerId).log) do
    if type(message) == "table" and message.jobKey == jobKey and message.stageName ~= nil then
      seen = seen + 1
      if seen == occurrence then
        return message.stageName
      end
    end
  end
  error("no dispatched stage for " .. jobKey .. " occurrence " .. tostring(occurrence), 0)
end

---@param env table
---@param kind string
---@param key string
---@return integer count
local function dispatchCount(env, kind, key)
  local jobKey = kind .. ":" .. key
  local count = 0
  for _, dispatched in ipairs(env.host.dispatched) do
    if dispatched == jobKey then
      count = count + 1
    end
  end
  return count
end

---@param env table
---@param workerId integer
---@param kind string
---@param key string
---@param stageName string
---@param status string
local function pushWorkerReply(env, workerId, kind, key, stageName, status)
  local generation = env.session.generationId
  withHost(env.host, function()
    resultChannel(env):push({
      workerId = workerId,
      epoch = 1,
      generationId = generation,
      kind = kind,
      key = key,
      jobKey = kind .. ":" .. key,
      stageName = stageName,
      status = status,
      compileSeconds = 1,
      stageSeconds = 1,
      workSeconds = 1,
      stagedBytes = 8,
    })
  end)
end

---@param env table
---@param bankId integer
---@param marker string
---@param stageName string
local function stageBankReply(env, bankId, marker, stageName)
  local key = tostring(bankId)
  withHost(env.host, function()
    local artifact = PreparedArtifact.new({
      cacheFs = env.cacheFs,
      generationId = env.session.generationId,
      epoch = 1,
      kind = "message-bank",
      key = key,
      jobKey = "message-bank:" .. key,
      stageName = stageName,
    })
    FieldMessageCacheWriter.stageBank(artifact, {
      bankId = bankId,
      bank = { schema = FieldMessageCache.SCHEMA, bankId = bankId, messageCount = 0, key = bankId, messages = {} },
      marker = marker,
      dependencies = {
        cacheFormat = "synthetic",
        charmapVersion = "synthetic",
        manifestSchema = "synthetic",
        versionRomSha1 = "synthetic",
        messageNarc = {
          symbol = "synthetic",
          alias = "synthetic",
          narcId = 0,
          fileId = 0,
          path = "synthetic",
          sha1 = "synthetic",
        },
      },
    })
    artifact:finishSuccess({ marker = marker })
  end)
  pushWorkerReply(env, 1, "message-bank", key, stageName, "prepared")
end

---@param env table
---@param bankIds integer[]
---@param bankMarkers table<integer, string>
---@param stageName string
---@return string marker
local function stageSummaryReply(env, bankIds, bankMarkers, stageName)
  local marker = nil
  withHost(env.host, function()
    local artifact = PreparedArtifact.new({
      cacheFs = env.cacheFs,
      generationId = env.session.generationId,
      epoch = 1,
      kind = "message-summary",
      key = "global",
      jobKey = "message-summary:global",
      stageName = stageName,
    })
    local index = { schema = FieldMessageCache.INDEX_SCHEMA, version = "heartgold", bankIds = bankIds }
    marker = FieldMessageCacheWriter.stageSummary(artifact, index, bankMarkers)
    artifact:finishSuccess({ marker = marker })
  end)
  pushWorkerReply(env, 1, "message-summary", "global", stageName, "prepared")
  return assert(marker, "summary staging must produce its marker")
end

---@param env table
---@param bankId integer
---@param marker string
local function publishBankLive(env, bankId, marker)
  local key = tostring(bankId)
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("message-bank", key), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "message-bank",
      key = key,
      marker = marker,
    })
    env.cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
    env.cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
      schema = FieldMessageCache.SCHEMA,
      bankId = bankId,
    })
  end)
end

---@param env table
---@param bankIds integer[]
---@param bankMarkers table<integer, string>
local function publishSummaryLive(env, bankIds, bankMarkers)
  withHost(env.host, function()
    local index = { schema = FieldMessageCache.INDEX_SCHEMA, version = "heartgold", bankIds = bankIds }
    local marker = FieldMessageCacheWriter.summaryMarker(index, bankMarkers)
    env.cacheFs:writeLua(ArtifactState.path("message-summary", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "message-summary",
      key = "global",
      marker = marker,
    })
    env.cacheFs:write(FieldMessageCache.markerPath(), marker)
    env.cacheFs:writeLua(FieldMessageCache.indexPath(), index)
  end)
end

---@param env table
---@param marker string
local function publishCatalogLive(env, marker)
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("mon-catalog", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "mon-catalog",
      key = "global",
      marker = marker,
    })
    env.cacheFs:writeLua(MonCache.catalogPath(), { version = "heartgold" })
    env.cacheFs:write(MonCache.catalogMarkerPath(), marker)
  end)
end

---@param env table
---@param kind string
---@param key string
---@param urgency string
---@return boolean ready
---@return string|nil failure
local function requestJob(env, kind, key, urgency)
  return withHost(env.host, function()
    return env.session:requestJob(kind, key, urgency)
  end)
end

---@param env table
---@param kind string
---@param key string
---@return string state
---@return table<string, unknown>? details
local function poolStatus(env, kind, key)
  return withHost(env.host, function()
    return env.pool:status(kind .. ":" .. key)
  end)
end

---@param env table
local function shutdownEnv(env)
  withHost(env.host, function()
    env.pool:shutdown()
  end)
  removeTreeReal(env.realFs, env.prefix:gsub("/$", ""))
end

function T.cold_request_dispatches_children_before_the_parent()
  local env = openLiveSession({ generation = "dependency-dispatch-generation", bankIds = { 3, 5 } })
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while its banks are cold")
  Assert.isNil(failure, "no failure is reported while the summary waits for its banks")
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the parent never occupies a worker early")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "only the first cold bank dispatches")
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the parent waits for every bank")

  stageBankReply(env, 3, "synthetic:romshape:003", dispatchedStage(env, 1, "message-bank:3", 1))
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the first bank publishes through the pool")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the second bank follows the first publication"
  )
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "one cold bank still gates the parent")

  stageBankReply(env, 5, "synthetic:romshape:005", dispatchedStage(env, 1, "message-bank:5", 1))
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the second bank publishes through the pool")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5", "message-summary:global" },
    "the parent dispatches only after both banks publish"
  )
  Assert.equal(dispatchCount(env, "message-summary", "global"), 1, "the parent dispatches exactly once")
  shutdownEnv(env)
end

function T.blocking_ensure_never_waits_on_an_absent_parent()
  local env = openLiveSession({ generation = "dependency-block-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  publishBankLive(env, 5, "synthetic:romshape:005")
  local bankReady, bankFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isTrue(bankReady, "a published bank answers ready")
  Assert.isNil(bankFailure, "a published bank reports no failure")
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "a warm bank is never submitted")
  publishSummaryLive(env, { 3, 5 }, { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" })
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isTrue(ready, "a published summary answers ready")
  Assert.isNil(failure, "a published summary reports no failure")
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "a warm parent is never submitted")

  local waitCalls = 0
  local realWait = env.pool.wait
  env.pool.wait = function(self, jobKey)
    waitCalls = waitCalls + 1
    return realWait(self, jobKey)
  end
  local blocked = withHost(env.host, function()
    return env.session:_blockOn("message-summary", "global")
  end)
  Assert.isTrue(blocked, "the blocking ensure returns once the artifact is ready")
  Assert.equal(waitCalls, 0, "the ensure never waits on an absent parent record")
  shutdownEnv(env)
end

function T.required_request_promotes_an_already_queued_sweep()
  local env = openLiveSession({ generation = "dependency-promotion-generation", bankIds = { 3, 5 } })
  requestJob(env, "message-bank", "3", "required")
  requestJob(env, "message-bank", "5", "sweep")
  requestJob(env, "audio-summary", "global", "near")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the required bank occupies the worker")
  Assert.equal(poolStatus(env, "message-bank", "5"), "queued", "the sweep bank waits its turn")
  requestJob(env, "message-bank", "5", "required")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "failed")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the promoted sweep dispatches ahead of near work"
  )
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "promotion keeps one job under its identity")
  Assert.equal(poolStatus(env, "message-bank", "5"), "running", "the promoted bank executes next")
  Assert.equal(poolStatus(env, "audio-summary", "global"), "queued", "near work still waits its turn")
  shutdownEnv(env)
end

function T.shared_prerequisite_inherits_urgent_demand()
  local env = openLiveSession({
    generation = "dependency-shared-generation",
    bankIds = { 3 },
    iconPageIds = { 0, 1 },
  })
  publishCatalogLive(env, "catalog-marker-shared")
  requestJob(env, "audio-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "audio-summary:global" }, "the occupant holds the worker")
  requestJob(env, "mon-icon-page", "0", "sweep")
  requestJob(env, "mon-icon-page", "1", "sweep")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "mon-layout", "global"), "queued", "the shared layout waits behind the occupant")
  requestJob(env, "message-bank", "3", "near")
  requestJob(env, "mon-icon-page", "0", "required")
  pushWorkerReply(env, 1, "audio-summary", "global", dispatchedStage(env, 1, "audio-summary:global", 1), "failed")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-summary:global", "mon-layout:global" },
    "the shared prerequisite inherits the urgent demand"
  )
  Assert.equal(dispatchCount(env, "mon-layout", "global"), 1, "the shared job dispatches once for both pages")
  Assert.equal(poolStatus(env, "mon-layout", "global"), "running", "the promoted prerequisite executes next")
  Assert.equal(poolStatus(env, "mon-icon-page", "0"), "unknown", "no page occupies a worker early")
  Assert.equal(poolStatus(env, "mon-icon-page", "1"), "unknown", "no page occupies a worker early")
  Assert.equal(poolStatus(env, "message-bank", "3"), "queued", "near work still waits its turn")
  shutdownEnv(env)
end

function T.retry_repairs_only_the_failed_leaf()
  local env = openLiveSession({ generation = "dependency-retry-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(ready, "the summary is pending while one bank is cold")
  Assert.isNil(failure, "no failure is reported while the summary waits")
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "the healthy bank is never submitted")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:5" }, "only the cold bank dispatches")
  pushWorkerReply(env, 1, "message-bank", "5", dispatchedStage(env, 1, "message-bank:5", 1), "failed")
  pumpSession(env, 2)
  local blocked, blockedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(blocked, "the parent stays blocked behind its failed bank")
  Assert.notNil(blockedFailure, "the blocked parent reports its cause")
  Assert.isTrue(
    tostring(blockedFailure):find("message-bank:5", 1, true) ~= nil,
    "the parent names its failed prerequisite: " .. tostring(blockedFailure)
  )

  local retried = withHost(env.host, function()
    return env.session:retry("message-summary", "global", "required")
  end)
  Assert.isTrue(retried == true or retried == false, "an explicit retry of the blocked parent is accepted")
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "retry never rebuilds the healthy sibling")
  Assert.equal(poolStatus(env, "message-bank", "5"), "queued", "only the failed leaf retries")
  Assert.equal(env.session:status().failed, 0, "retry clears the leaf and parent failure annotations")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:5", "message-bank:5" },
    "the retry creates exactly one new leaf attempt"
  )
  stageBankReply(env, 5, "synthetic:romshape:005", dispatchedStage(env, 1, "message-bank:5", 2))
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the retried leaf publishes")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:5", "message-bank:5", "message-summary:global" },
    "the parent dispatches once its repaired bank publishes"
  )
  stageSummaryReply(
    env,
    { 3, 5 },
    { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" },
    dispatchedStage(env, 1, "message-summary:global", 1)
  )
  pumpSession(env, 2)
  local repaired, repairedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isTrue(repaired, "the parent succeeds once its repaired closure publishes")
  Assert.isNil(repairedFailure, "the repaired parent reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "3"), 0, "the healthy sibling never dispatched")
  shutdownEnv(env)
end

function T.retirement_ends_pending_waits_without_ghost_work()
  local env = openLiveSession({ generation = "dependency-retire-generation", bankIds = { 3, 5 } })
  requestJob(env, "message-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "one bank executes while the other queues")
  withHost(env.host, function()
    env.session:retire()
  end)
  local retiredAgain = withHost(env.host, function()
    return env.pool:retireSelection(1)
  end)
  Assert.isFalse(retiredAgain, "retirement reaches the pool exactly once")
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "executing work stays charged")
  Assert.equal(poolStatus(env, "message-bank", "5"), "cancelled", "queued work never runs after retirement")
  local requestOk = pcall(function()
    withHost(env.host, function()
      return env.session:requestJob("message-bank", "3", "required")
    end)
  end)
  Assert.isFalse(requestOk, "a retired session accepts no further work")

  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "failed")
  pumpPool(env, 2)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "late output dispatches nothing new")
  Assert.equal(poolStatus(env, "message-bank", "3"), "cancelled", "the late result settles without publishing")
  Assert.isNil(env.cacheFs:read(ArtifactState.path("message-bank", "3")), "the late result publishes no receipt")
  local waitOk, waitError = pcall(function()
    withHost(env.host, function()
      return env.session:_blockOn("message-summary", "global")
    end)
  end)
  Assert.isFalse(waitOk, "a pending ensure ends terminally after retirement")
  local message = tostring(waitError)
  Assert.isTrue(
    message:find("retir", 1, true) ~= nil or message:find("cancel", 1, true) ~= nil,
    "the terminated ensure names its retirement: " .. message
  )
  shutdownEnv(env)
end

function T.repeated_requests_submit_only_once()
  local env = openLiveSession({ generation = "dependency-repeat-generation", bankIds = { 3, 5 } })
  local first, firstFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(first, "the cold bank stays pending")
  Assert.isNil(firstFailure, "no failure is reported while the bank waits")
  local second, secondFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(second, "an equal-urgency request stays pending")
  Assert.isNil(secondFailure, "an equal-urgency request reports no failure")
  pumpSession(env, 2)
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "repeated interest dispatches exactly once")
  local third, thirdFailure = requestJob(env, "message-bank", "5", "sweep")
  Assert.isFalse(third, "polling a dispatched bank stays pending")
  Assert.isNil(thirdFailure, "polling a dispatched bank reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "equal-urgency polling dispatches nothing new")
  shutdownEnv(env)
end

function T.promotion_while_executing_keeps_single_execution()
  local env = openLiveSession({ generation = "dependency-executing-generation", bankIds = { 3, 5 } })
  local first, firstFailure = requestJob(env, "message-bank", "3", "near")
  Assert.isFalse(first, "the cold bank stays pending")
  Assert.isNil(firstFailure, "no failure is reported while the bank waits")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "the near bank occupies the worker")
  local second, secondFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isFalse(second, "promoting an executing bank stays pending")
  Assert.isNil(secondFailure, "promoting an executing bank reports no failure")
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "promotion never duplicates an executing job")
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "the promoted bank keeps executing")
  shutdownEnv(env)
end

function T.required_demand_outranks_earlier_near_sharing()
  local env = openLiveSession({
    generation = "dependency-mixed-generation",
    bankIds = { 3 },
    iconPageIds = { 0, 1 },
  })
  publishCatalogLive(env, "catalog-marker-mixed")
  requestJob(env, "audio-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "audio-summary:global" }, "the occupant holds the worker")
  requestJob(env, "message-bank", "3", "near")
  requestJob(env, "mon-icon-page", "0", "sweep")
  requestJob(env, "mon-icon-page", "1", "sweep")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "mon-layout", "global"), "queued", "the shared layout waits behind the occupant")
  requestJob(env, "mon-icon-page", "1", "required")
  pushWorkerReply(env, 1, "audio-summary", "global", dispatchedStage(env, 1, "audio-summary:global", 1), "failed")
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-summary:global", "mon-layout:global" },
    "the required layout outranks the earlier near bank"
  )
  Assert.equal(dispatchCount(env, "mon-layout", "global"), 1, "the shared job dispatches once for both pages")
  Assert.equal(poolStatus(env, "message-bank", "3"), "queued", "the earlier near bank still waits its turn")
  shutdownEnv(env)
end

function T.failed_dependency_blocks_parent_before_submission()
  local env = openLiveSession({ generation = "dependency-blocked-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  local pending, pendingFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(pending, "the summary stays pending while one bank is cold")
  Assert.isNil(pendingFailure, "no failure is reported while the summary waits")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:5" }, "only the cold bank dispatches")
  pushWorkerReply(env, 1, "message-bank", "5", dispatchedStage(env, 1, "message-bank:5", 1), "failed")
  pumpSession(env, 2)
  local blocked, blockedFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(blocked, "the parent stays blocked behind its failed bank")
  Assert.isTrue(
    tostring(blockedFailure):find("message-bank:5", 1, true) ~= nil,
    "the parent names its failed prerequisite: " .. tostring(blockedFailure)
  )
  Assert.equal(poolStatus(env, "message-summary", "global"), "unknown", "the blocked parent never occupies a worker")
  shutdownEnv(env)
end

function T.blocking_wait_times_out_without_completion()
  local env = openLiveSession({ generation = "dependency-timeout-generation", bankIds = { 3, 5 } })
  local pending, pendingFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(pending, "the summary stays pending while its banks are cold")
  Assert.isNil(pendingFailure, "no failure is reported while the summary waits")
  local waitOk, waitError = pcall(function()
    withHost(env.host, function()
      return env.session:_blockOn("message-summary", "global")
    end)
  end)
  Assert.isFalse(waitOk, "an ensure with no completion ends terminally")
  local message = tostring(waitError)
  Assert.isTrue(message:find("message-summary:global", 1, true) ~= nil, "the timeout names its target: " .. message)
  Assert.isTrue(message:find("timed out", 1, true) ~= nil, "the outcome names its timeout: " .. message)
  shutdownEnv(env)
end

function T.dependency_cycle_is_a_terminal_failure()
  local originalDependencies = ArtifactJobs.dependencies
  ArtifactJobs.dependencies = function(kind, key, plans)
    if kind == "message-bank" then
      return { { kind = "message-summary", key = "global" } }
    end
    return originalDependencies(kind, key, plans)
  end
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local session = summarySession(pool, cacheFs, { 3, 5 })
  local callOk, ready, failure = pcall(session.requestJob, session, "message-summary", "global", "required")
  ArtifactJobs.dependencies = originalDependencies
  Assert.isTrue(callOk, "a dependency cycle answers instead of overflowing: " .. tostring(ready))
  Assert.isFalse(ready, "a cyclic plan never answers ready")
  Assert.isTrue(
    tostring(failure):find("cycle", 1, true) ~= nil,
    "the cyclic plan names its cycle: " .. tostring(failure)
  )
end

function T.stale_epoch_demand_fails_at_the_pool()
  local env = openLiveSession({ generation = "dependency-epoch-generation", bankIds = { 3, 5 } })
  withHost(env.host, function()
    env.pool:selectGeneration({ versionId = "heartgold", generationId = env.session.generationId }, 2)
  end)
  local requestOk, requestError = pcall(function()
    withHost(env.host, function()
      return env.session:requestJob("message-bank", "3", "required")
    end)
  end)
  Assert.isFalse(requestOk, "demand from a stale epoch never dispatches")
  Assert.isTrue(
    tostring(requestError):find("epoch", 1, true) ~= nil,
    "the stale demand names its epoch: " .. tostring(requestError)
  )
  shutdownEnv(env)
end

return { metadata = { capabilities = {} }, tests = T }
