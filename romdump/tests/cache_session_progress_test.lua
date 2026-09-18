-- Convergent generation-session progress: local runnable work versus named
-- external waits, FIFO fairness within urgency, acknowledged sweep
-- admission, and truthful settlement. The real session runs against the
-- real dependency, milestone and canonical inventory functions over
-- synthetic membership; the pool is a test-local epoch-conformant boundary
-- that holds and completes chosen physical jobs on demand.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local SourcePlan = require("romdump.src.build.SourcePlan")

local T = {}

local PRODUCER_ID = "d" .. string.rep("3", 64)
local SYNTHETIC_SHA1 = string.rep("a", 40)
local FIXTURE_MARKER = "fixture-ready-marker"

-- Production-conformant pool boundary: current-epoch lookup only, queued
-- promotion, no live inheritance across selections. History is an
-- append-only epoch-labeled trace and never answers lookups.
local function epochPool(workerCount)
  local pool = {
    records = {},
    order = {},
    created = {},
    calls = {},
    history = {},
    physical = {},
    selected = nil,
    retired = false,
    waitCalls = 0,
    workerCount = workerCount or 2,
    peakSweep = 0,
    onWait = nil,
  }
  local function noteSweep(self)
    local outstanding = 0
    for _, record in pairs(self.records) do
      if record.priority == 100 and (record.state == "queued" or record.state == "running") then
        outstanding = outstanding + 1
      end
    end
    if outstanding > self.peakSweep then
      self.peakSweep = outstanding
    end
  end
  function pool:selectGeneration(identity, epoch)
    assert(type(identity) == "table", "pool generation identity is required")
    assert(type(epoch) == "number" and epoch % 1 == 0, "pool epoch must be an integer")
    local current = self.selected
    if
      current ~= nil
      and current.epoch == epoch
      and current.versionId == identity.versionId
      and current.generationId == identity.generationId
    then
      return
    end
    local archivedEpoch = current ~= nil and current.epoch or 0
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      self.history[#self.history + 1] = {
        epoch = archivedEpoch,
        jobKey = jobKey,
        event = "archived:" .. record.state,
      }
      if record.state == "running" or record.state == "prepared" then
        self.physical[jobKey] = record.state
      end
    end
    self.records = {}
    self.order = {}
    self.selected = {
      versionId = identity.versionId,
      generationId = identity.generationId,
      epoch = epoch,
    }
    self.retired = false
    noteSweep(self)
  end
  function pool:retireSelection(epoch)
    local selected = self.selected
    if selected == nil or self.retired or epoch ~= selected.epoch then
      return false
    end
    self.retired = true
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      if record.state == "queued" then
        record.state = "cancelled"
        self.history[#self.history + 1] = { epoch = selected.epoch, jobKey = jobKey, event = "retired" }
      elseif record.state == "running" or record.state == "prepared" then
        self.physical[jobKey] = record.state
      end
    end
    noteSweep(self)
    return true
  end
  function pool:request(job)
    assert(not self.retired, "pool selection is retired")
    local selected = assert(self.selected, "pool has no selected generation")
    assert(job.epoch == selected.epoch, "pool job epoch does not match the selected generation")
    self.calls[job.jobKey] = (self.calls[job.jobKey] or 0) + 1
    local record = self.records[job.jobKey]
    if record ~= nil then
      if record.state == "failed" then
        error(record.details and record.details.error or "compiler job failed", 0)
      end
      if record.state == "cancelled" then
        self.records[job.jobKey] = nil
      else
        if record.state == "queued" and job.priority < record.priority then
          record.priority = job.priority
        end
        return record.state, record.details
      end
    end
    record = {
      kind = job.kind,
      key = job.key,
      jobKey = job.jobKey,
      priority = job.priority,
      epoch = job.epoch,
      job = job,
      state = "queued",
      details = nil,
    }
    self.records[job.jobKey] = record
    self.order[#self.order + 1] = job.jobKey
    self.created[#self.created + 1] = { epoch = job.epoch, jobKey = job.jobKey }
    noteSweep(self)
    return record.state, nil
  end
  function pool:status(jobKey)
    local record = self.records[jobKey]
    if record == nil then
      return "unknown"
    end
    return record.state, record.details
  end
  function pool:retry(jobKey, priority)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    assert(record.state == "failed", "only failed compiler jobs can be retried")
    record.state = "queued"
    record.priority = priority
    record.details = nil
    noteSweep(self)
    return record.state
  end
  function pool:update()
    return true
  end
  function pool:waitForProgress()
    self.waitCalls = self.waitCalls + 1
    if self.onWait ~= nil then
      self.onWait(self)
    end
  end
  function pool:diagnostics()
    local counts = { queued = 0, running = 0, prepared = 0, ready = 0, failed = 0, cancelled = 0 }
    for _, record in pairs(self.records) do
      if counts[record.state] ~= nil then
        counts[record.state] = counts[record.state] + 1
      end
    end
    return { workerCount = self.workerCount, counts = counts, error = nil }
  end
  function pool:shutdown()
    return true
  end
  -- Test driver operations below: hold and complete chosen physical jobs.
  function pool:startRunning(jobKey)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    assert(record.state == "queued", "only queued jobs start running")
    record.state = "running"
    noteSweep(self)
  end
  function pool:complete(jobKey)
    local record = self.records[jobKey]
    assert(
      record ~= nil and (record.state == "queued" or record.state == "running"),
      "only a current job completes: " .. tostring(jobKey)
    )
    if self.physical[jobKey] ~= nil then
      error("a retired physical slot never completes as current work: " .. tostring(jobKey), 0)
    end
    record.state = "ready"
    record.details = nil
    self.physical[jobKey] = nil
    noteSweep(self)
  end
  function pool:fail(jobKey, message)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    record.state = "failed"
    record.details = { error = message }
    noteSweep(self)
  end
  function pool:releasePhysical(jobKey)
    assert(self.physical[jobKey] ~= nil, "no such physical slot: " .. tostring(jobKey))
    self.physical[jobKey] = nil
  end
  function pool:createdCount(epoch, jobKey)
    local count = 0
    for _, entry in ipairs(self.created) do
      if entry.epoch == epoch and (jobKey == nil or entry.jobKey == jobKey) then
        count = count + 1
      end
    end
    return count
  end
  return pool
end

local function withPatched(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.name]
    patch.target[patch.name] = patch.replacement
  end
  local ok, first, second = pcall(fn)
  for index, patch in ipairs(patches) do
    patch.target[patch.name] = originals[index]
  end
  if not ok then
    error(first, 0)
  end
  return first, second
end

local function newEnv(generation, workerCount)
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local pool = epochPool(workerCount)
  return {
    generation = generation,
    identity = { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID },
    epoch = 1,
    backend = backend,
    cacheFs = cacheFs,
    pool = pool,
  }
end

local function openSession(env, sweepEnabled)
  local realForVersion = CacheFs.forVersion
  return withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", env.backend)
      end,
    },
  }, function()
    return InteractiveCacheBuild.new({
      identity = env.identity,
      epoch = env.epoch,
      pool = env.pool,
      sweepEnabled = sweepEnabled == true,
    })
  end)
end

local function pump(session, rounds)
  for _ = 1, rounds do
    session:update()
  end
end

-- Pumps until no runnable local work remains; false when the cap runs out.
-- The first update always runs: retained status lags one pump behind intent.
local function drainLocal(session, cap)
  for _ = 1, cap or 500 do
    session:update()
    if not session:status().planningPending then
      return true
    end
  end
  return not session:status().planningPending
end

local function acceptedCount(pool)
  local count = 0
  for _ in pairs(pool.calls) do
    count = count + 1
  end
  return count
end

-- Synthetic source membership through the real inventory compiler: the
-- aggregate planners answer fixed synthetic data while the real
-- SourcePlan assembly, staging and publication stay in the path.
local function cellDescriptor(matrixMemberId, index)
  return {
    matrixMemberId = matrixMemberId,
    index = index,
    x = 0,
    z = 0,
    mapHeaderId = 0,
    altitude = 0,
    landDataMemberId = 1,
    areaDataMemberId = 2,
  }
end

local function syntheticIndexBundle()
  return {
    index = {
      matrices = {
        { matrixMemberId = 11, cells = { cellDescriptor(11, 0), cellDescriptor(11, 1) } },
      },
    },
    indexMarker = "synthetic-index-marker",
  }
end

local function syntheticRomFs()
  return {
    metadata = function()
      return { sha1 = SYNTHETIC_SHA1 }
    end,
    version = function()
      return "heartgold"
    end,
    openNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    read = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    resolvedNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
  }
end

local function syntheticWorld()
  return {
    maps = { { id = 7 }, { id = 9 } },
    bySymbol = { MAP_SEVEN = 7, MAP_NINE = 9 },
    byId = { [7] = 1, [9] = 2 },
    analysis = {
      mapHeaderCount = 3,
      renderableCount = 2,
      excluded = { { id = 3, symbol = "MAP_NOTHING", reason = "placeholder header" } },
    },
  }
end

local function compileSynthetic(env, scriptIds)
  local calls = { world = 0, index = 0, script = 0, audio = 0, mapPlans = 0 }
  local members = {}
  for _, memberId in ipairs(scriptIds or { 4, 6 }) do
    members[#members + 1] = { memberId = memberId }
  end
  local WorldManifest = require("romdump.src.digest.map.WorldManifest")
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
  return withPatched({
    {
      target = WorldManifest,
      name = "compileCatalog",
      replacement = function()
        calls.world = calls.world + 1
        return syntheticWorld()
      end,
    },
    {
      target = FieldCellCompiler,
      name = "compileIndex",
      replacement = function()
        calls.index = calls.index + 1
        return syntheticIndexBundle()
      end,
    },
    {
      target = ScriptCompiler,
      name = "plan",
      replacement = function()
        calls.script = calls.script + 1
        return { members = members, generationKey = "synthetic-generation" }
      end,
    },
    {
      target = AudioCompiler,
      name = "plan",
      replacement = function()
        calls.audio = calls.audio + 1
        return { index = { version = "heartgold" }, bankPlans = { { bankId = 2 }, { bankId = 5 } } }
      end,
    },
    {
      target = MapCompilePlan,
      name = "plan",
      replacement = function(_, _, mapId)
        calls.mapPlans = calls.mapPlans + 1
        if mapId == 7 then
          return {
            cellPlans = {
              { descriptor = { matrixMemberId = 11, index = 1 } },
              { descriptor = { matrixMemberId = 11, index = 0 } },
            },
          }
        end
        return { cellPlans = {} }
      end,
    },
  }, function()
    return SourcePlan.compile(syntheticRomFs(), env.identity), calls
  end)
end

local function stageSynthetic(env, scriptIds)
  local plan = compileSynthetic(env, scriptIds)
  local artifact = PreparedArtifact.new({
    cacheFs = env.cacheFs,
    generationId = env.generation,
    epoch = env.epoch,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    stageName = "inventory-stage",
  })
  local marker = SourcePlan.stage(artifact, plan)
  Assert.equal(marker, SourcePlan.marker(env.generation), "staging returns the generation marker")
  artifact:finishSuccess({ marker = marker })
  artifact:publish({
    generationId = env.generation,
    epoch = env.epoch,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
  })
  return plan
end

local function writeReceipt(env, kind, key)
  env.cacheFs:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = kind,
    key = key,
    marker = FIXTURE_MARKER,
  })
end

-- Fixture-owned publication facts at the family validation boundary: jobs
-- with a staged fixture receipt validate ready without their payload
-- compilers running. Families without fixture facts use the real
-- validator. The session pump, status and outcomes are never stubbed.
local function withFixtureFacts(env, fn)
  local realValidate = ArtifactJobs.validate
  return withPatched({
    {
      target = ArtifactJobs,
      name = "validate",
      replacement = function(cacheFs, generationId, kind, key, plans, identity)
        if generationId == env.generation then
          local receipt = ArtifactState.read(cacheFs, generationId, kind, key)
          if receipt ~= nil and receipt.marker == FIXTURE_MARKER then
            return true
          end
        end
        return realValidate(cacheFs, generationId, kind, key, plans, identity)
      end,
    },
  }, fn)
end

local function publishBank(env, bankId, marker)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  env.cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  env.cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  env.cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end

-- Missing knowledge backed by a held worker is blocked, not runnable: the
-- scope stays pending, idle polling performs no cache IO, source planning
-- or validation, and publishing the source resumes progress.
function T.held_source_work_leaves_local_planning_idle()
  local env = newEnv("held-source-generation", 2)
  local session = openSession(env, false)
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "bootstrap stays pending while its inventory is cold")
  Assert.isNil(failure, "bootstrap must not fail while cold")
  Assert.isTrue(drainLocal(session, 500), "locally eligible work must drain")
  local status = session:status()
  Assert.isFalse(status.planningPending, "a held worker leaves no runnable local work")
  Assert.isFalse(status.settled, "a held scope never settles")
  local reads, validations = 0, 0
  local realRead, realValidate = SourcePlan.read, ArtifactJobs.validate
  SourcePlan.read = function(...)
    reads = reads + 1
    return realRead(...)
  end
  ArtifactJobs.validate = function(...)
    validations = validations + 1
    return realValidate(...)
  end
  local callsBefore = acceptedCount(env.pool)
  local ok, err = pcall(function()
    for _ = 1, 100 do
      session:update()
    end
  end)
  SourcePlan.read, ArtifactJobs.validate = realRead, realValidate
  Assert.isTrue(ok, tostring(err))
  status = session:status()
  Assert.isFalse(status.planningPending, "repeated idle updates stay idle")
  Assert.isFalse(status.settled, "repeated idle updates never settle a held scope")
  Assert.equal(reads, 0, "idle polling performs no source reads")
  Assert.equal(validations, 0, "idle polling performs no validation")
  Assert.equal(acceptedCount(env.pool), callsBefore, "idle polling submits no duplicate work")
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(again, "an unchanged poll stays pending")
  Assert.isNil(againFailure, "an unchanged poll reports no failure")
  Assert.equal(acceptedCount(env.pool), callsBefore, "an unchanged poll registers nothing")
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  session:update()
  Assert.isTrue(session.sourceLoaded, "publishing the source adopts membership")
  local sourceReady, sourceFailure = session:requestJob("source-plan", "global", "required")
  Assert.isTrue(sourceReady, "the published source validates ready: " .. tostring(sourceFailure))
  local mapReady, mapFailure = session:requestJob("map", "7", "required")
  Assert.isFalse(mapReady, "adopted map demand stays pending while cold")
  Assert.isNil(mapFailure, "adopted map demand reports no failure")
  pump(session, 10)
  withFixtureFacts(env, function()
    writeReceipt(env, "world-catalog", "global")
    writeReceipt(env, "field-cell-index", "global")
    env.pool:complete("world-catalog:global")
    env.pool:complete("field-cell-index:global")
    pump(session, 10)
    Assert.isTrue(env.pool.calls["field-cell:11-0"] ~= nil, "adopted membership dispatches new demand")
  end)
end

-- A wide pending family cannot monopolize the pump: resumable expansion
-- gives a trailing runnable leaf its turn, held children are planned once,
-- and the pump goes idle without busy-spinning.
function T.wide_pending_family_leaves_room_for_ready_leaves()
  local env = newEnv("wide-family-generation", 2)
  local session = openSession(env, false)
  session:requestJob("message-summary", "global", "required")
  session:requestJob("audio-summary", "global", "required")
  pump(session, 5)
  stageSynthetic(env)
  env.pool:complete("source-plan:global")
  pump(session, 5)
  local validations = 0
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function(...)
    validations = validations + 1
    return realValidate(...)
  end
  local ok, err = pcall(function()
    local ready, failure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(ready, "the wide summary stays pending while its banks are held")
    Assert.isNil(failure, "the wide summary must not fail while cold")
    -- Hundreds of required banks dwarf two 32-unit slices; the trailing
    -- leaf below still earns its submission while the parent expands.
    local leafReady, leafFailure = session:requestJob("mon-catalog", "global", "required")
    Assert.isFalse(leafReady, "the trailing leaf stays pending while held")
    Assert.isNil(leafFailure, "the trailing leaf must not fail while held")
    -- Hundreds of required banks need dozens of slices to expand; the
    -- trailing leaf still earns its submission once finite work drains.
    pump(session, 150)
    local submitted = 0
    for _ in pairs(env.pool.calls) do
      submitted = submitted + 1
    end
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the trailing leaf gets its turn")
    Assert.isTrue(submitted > 64, "the wide family actually spans several slices")
    Assert.isTrue(drainLocal(session, 2000), "finite held work drains to idle")
    local settled = session:status()
    Assert.isFalse(settled.planningPending, "held children do not keep the pump runnable")
    Assert.isFalse(settled.settled, "held work never settles")
    local validationsAfterDrain = validations
    pump(session, 50)
    Assert.equal(validations, validationsAfterDrain, "drained children are never revalidated")
    for jobKey, calls in pairs(env.pool.calls) do
      Assert.equal(calls, 1, "no held child is resubmitted: " .. jobKey)
    end
  end)
  ArtifactJobs.validate = realValidate
  Assert.isTrue(ok, tostring(err))
end

-- Capacity waiters cannot strand work: each observed release admits the
-- oldest eligible waiter, the peak never exceeds the bound, and finite
-- work eventually covers its union.
function T.released_frontier_credit_wakes_the_oldest_waiter()
  local env = newEnv("frontier-wait-generation", 1)
  local session = openSession(env, false)
  local leaves = { "mon-catalog", "items", "bag", "field-camera" }
  withFixtureFacts(env, function()
    for _, kind in ipairs(leaves) do
      local ready, failure = session:requestJob(kind, "global", "sweep")
      Assert.isFalse(ready, "capacity work starts pending: " .. kind)
      Assert.isNil(failure, "capacity work must not fail: " .. kind)
    end
    pump(session, 20)
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the first waiter is admitted")
    Assert.isTrue(env.pool.calls["items:global"] ~= nil, "the second waiter is admitted")
    Assert.isNil(env.pool.calls["bag:global"], "a full frontier parks later waiters")
    Assert.isNil(env.pool.calls["field-camera:global"], "a full frontier parks later waiters")
    Assert.isTrue(drainLocal(session, 500), "a full frontier with no local work goes idle")
    Assert.isTrue(env.pool.peakSweep <= 2, "the frontier never exceeds twice the worker count")
    for _, kind in ipairs(leaves) do
      writeReceipt(env, kind, "global")
    end
    env.pool:complete("mon-catalog:global")
    pump(session, 20)
    Assert.isTrue(env.pool.calls["bag:global"] ~= nil, "one release admits the oldest waiter")
    Assert.isNil(env.pool.calls["field-camera:global"], "one release admits exactly one waiter")
    env.pool:complete("items:global")
    pump(session, 20)
    Assert.isTrue(env.pool.calls["field-camera:global"] ~= nil, "the next release admits the next waiter")
    Assert.isTrue(env.pool.peakSweep <= 2, "the peak stays bounded across releases")
  end)
end

-- Desired urgency never rewrites acknowledged running priority: promoting
-- a running sweep job admits nothing new until a real credit is released.
function T.running_promotion_keeps_its_admission_credit()
  local env = newEnv("running-promotion-generation", 1)
  local session = openSession(env, false)
  withFixtureFacts(env, function()
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      session:requestJob(kind, "global", "sweep")
    end
    pump(session, 20)
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the first sweep job is admitted")
    Assert.isTrue(env.pool.calls["items:global"] ~= nil, "the second sweep job is admitted")
    Assert.isNil(env.pool.calls["bag:global"], "the waiter parks behind the full frontier")
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      writeReceipt(env, kind, "global")
    end
    env.pool:startRunning("mon-catalog:global")
    local ready, failure = session:requestJob("mon-catalog", "global", "required")
    Assert.isFalse(ready, "a running job stays pending")
    Assert.isNil(failure, "promotion reports no failure")
    Assert.isTrue(drainLocal(session, 500), "promotion of running work goes idle")
    Assert.isNil(env.pool.calls["bag:global"], "promoting a running job frees no phantom credit")
    Assert.equal(env.pool.calls["mon-catalog:global"], 1, "a running job is never resubmitted")
    Assert.isTrue(env.pool.peakSweep <= 2, "the frontier stays bounded")
    env.pool:complete("items:global")
    pump(session, 20)
    Assert.isTrue(env.pool.calls["bag:global"] ~= nil, "a real release still admits the waiter")
  end)
end

-- Queued promotion releases a credit only on acknowledgement: the freed
-- slot admits exactly one replacement with no duplicate job.
function T.queued_promotion_releases_a_credit_on_acknowledgement()
  local env = newEnv("queued-promotion-generation", 1)
  local session = openSession(env, false)
  withFixtureFacts(env, function()
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      session:requestJob(kind, "global", "sweep")
    end
    pump(session, 20)
    for _, kind in ipairs({ "mon-catalog", "items", "bag" }) do
      writeReceipt(env, kind, "global")
    end
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "the first sweep job is admitted")
    Assert.isTrue(env.pool.calls["items:global"] ~= nil, "the second sweep job is admitted")
    Assert.isNil(env.pool.calls["bag:global"], "the waiter parks behind the full frontier")
    local ready, failure = session:requestJob("items", "global", "required")
    Assert.isFalse(ready, "a queued job stays pending after promotion")
    Assert.isNil(failure, "promotion reports no failure")
    pump(session, 20)
    Assert.equal(env.pool.records["items:global"].priority, 0, "the queued record carries the stronger urgency")
    Assert.isTrue(env.pool.calls["bag:global"] ~= nil, "one acknowledged promotion frees exactly one credit")
    Assert.equal(env.pool:createdCount(1, "items:global"), 1, "promotion creates no duplicate job")
    Assert.isTrue(env.pool.peakSweep <= 2, "the replacement respects the bound")
  end)
end

-- Mon page membership through the real layout writers: catalog and layout
-- files are staged exactly as the digesters write them, so page adoption
-- reads authentic published plans.
local function zeroCurve()
  local curve = {}
  for level = 1, 100 do
    curve[level] = 0
  end
  return curve
end

local function minimalCatalog()
  return {
    schema = "g4-mon-catalog-v3",
    version = { id = "heartgold", language = "english" },
    species = {},
    moves = {},
    abilities = {},
    growthCurves = {
      medium_fast = zeroCurve(),
      erratic = zeroCurve(),
      fluctuating = zeroCurve(),
      medium_slow = zeroCurve(),
      fast = zeroCurve(),
      slow = zeroCurve(),
      unused_6 = zeroCurve(),
      unused_7 = zeroCurve(),
    },
  }
end

local function layoutManifest(schema, imagePath, width, height, cell)
  return {
    schema = schema,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = imagePath, width = width, height = height },
    },
    pageIds = { 0 },
    entries = {
      ["K/f0"] = {
        x = 0,
        y = 0,
        width = cell,
        height = cell,
        frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } },
        pageId = 0,
      },
    },
    representative = { "K/f0" },
  }
end

local function iconPagePlan(pageId)
  return {
    pageId = pageId,
    width = 256,
    height = 128,
    cell = 32,
    combos = { { naix = 0, palette = 0, key = "icons-" .. tostring(pageId), selectors = { "K/f0" } } },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 32, height = 32 } },
  }
end

local function portraitPagePlan(pageId)
  return {
    pageId = pageId,
    width = 640,
    height = 320,
    cell = 80,
    combos = {
      {
        narc = "synthetic",
        charMemberId = 0,
        palMemberId = 0,
        key = "portraits-" .. tostring(pageId),
        selectors = { "K/f0" },
      },
    },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 80, height = 80 } },
  }
end

local function stageLayout(env, catalogMarker, layoutMarker)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  MonCacheWriter.writeCatalog(env.cacheFs, minimalCatalog(), catalogMarker)
  env.cacheFs:writeLua(ArtifactState.path("mon-catalog", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "mon-catalog",
    key = "global",
    marker = catalogMarker,
  })
  MonCacheWriter.writeLayout(
    env.cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    env.generation
  )
  env.cacheFs:writeLua(ArtifactState.path("mon-layout", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = env.generation,
    kind = "mon-layout",
    key = "global",
    marker = layoutMarker,
  })
end

-- Completes every currently queued pool job, staging fixture facts first
-- so validation observes published output. Returns the completed count.
local function completeQueued(env)
  local completed = 0
  local queued = {}
  for _, jobKey in ipairs(env.pool.order) do
    local record = env.pool.records[jobKey]
    if record ~= nil and record.state == "queued" then
      queued[#queued + 1] = jobKey
    end
  end
  for _, jobKey in ipairs(queued) do
    local kind, key = jobKey:match("^([^:]+):(.+)$")
    writeReceipt(env, kind, key)
    env.pool:complete(jobKey)
    completed = completed + 1
  end
  return completed
end

-- Drives a sweep session to successful settlement: discovery, page
-- adoption, exhaustive enrollment and controlled completion of the whole
-- synthetic corpus.
local function finishCorpus(env, session, cap)
  for _ = 1, cap or 5000 do
    local status = session:status()
    if status.settled then
      return true
    end
    completeQueued(env)
    session:update()
  end
  return session:status().settled
end

local function canonicalKeySet(jobs)
  local set = {}
  for _, job in ipairs(jobs) do
    set[job.kind .. ":" .. job.key] = true
  end
  return set
end

local function outcomeKeySet(session)
  local set = {}
  for _, outcome in ipairs(session:outcomes()) do
    set[outcome.jobKey] = true
  end
  return set
end

-- The real command consumes accurate session progress: local work drains,
-- a physical wait occurs while the bank is held, completion resumes and
-- the scope succeeds with exact outcomes.
function T.command_takes_physical_wait_for_delayed_completion()
  local env = newEnv("command-wait-generation", 2)
  local savedPool = package.loaded["romdump.src.build.CompilerPool"]
  local savedBuilder = package.loaded["romdump.src.CacheBuilder"]
  local realForVersion = CacheFs.forVersion
  local CacheBuilder
  local ok, err = pcall(function()
    package.loaded["romdump.src.build.CompilerPool"] = {
      new = function()
        return env.pool
      end,
    }
    CacheFs.forVersion = function()
      return realForVersion("heartgold", env.backend)
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
    env.pool.onWait = function(pool)
      if pool:status("message-bank:219") == "queued" then
        publishBank(env, 219, "command-marker")
        pool:complete("message-bank:219")
      end
    end
    local report, reportErr = CacheBuilder.prepareVersion("heartgold", {
      identity = env.identity,
      requirements = { "message-bank:219" },
      log = function() end,
    })
    Assert.isNil(reportErr, "the delayed scope must succeed")
    assert(report ~= nil, "the command returns its report")
    Assert.isTrue(report.requestedReady, "the waited scope proves ready")
    Assert.isTrue(env.pool.waitCalls >= 1, "completion arrives through a physical wait")
    Assert.equal(report.counts.successful, 1, "exactly the requested job succeeds")
    Assert.equal(report.counts.failed, 0, "nothing fails")
    local seen = {}
    for _, outcome in ipairs(report.outcomes) do
      seen[outcome.jobKey] = outcome
    end
    local bank = assert(seen["message-bank:219"], "the exact outcome carries its identity")
    Assert.equal(bank.state, "successful", "the bank outcome is successful")
    Assert.isFalse(bank.reused, "a compiled job is not reuse")
  end)
  package.loaded["romdump.src.build.CompilerPool"] = savedPool
  package.loaded["romdump.src.CacheBuilder"] = savedBuilder
  CacheFs.forVersion = realForVersion
  env.pool.onWait = nil
  Assert.isTrue(ok, tostring(err))
end

-- Epoch ownership follows production: a new selection inherits no live
-- lookup, validated receipts answer without recompilation, and missing
-- work is requested exactly once per epoch.
function T.epoch_lookup_resets_while_receipts_stay_reusable()
  local env = newEnv("epoch-reuse-generation", 2)
  local session = openSession(env, false)
  session:requestJob("message-bank", "219", "required")
  pump(session, 5)
  publishBank(env, 219, "epoch-marker")
  env.pool:complete("message-bank:219")
  pump(session, 10)
  local ready, failure = session:requestJob("message-bank", "219", "required")
  Assert.isTrue(ready, "the compiled bank validates ready: " .. tostring(failure))
  session:requestJob("message-bank", "3", "required")
  pump(session, 5)
  session:retire()
  Assert.isTrue(env.pool.retired, "retirement reaches the pool")
  env.epoch = 2
  Assert.equal(env.pool:status("message-bank:3"), "cancelled", "retired queued work does not leak as current")
  Assert.equal(env.pool:status("message-bank:219"), "ready", "published output persists past retirement")
  local resumed = openSession(env, false)
  Assert.equal(env.pool:status("message-bank:219"), "unknown", "the new epoch starts with no live lookup")
  Assert.isTrue(#env.pool.history > 0, "history keeps the epoch-labeled trace")
  for _, entry in ipairs(env.pool.history) do
    Assert.isTrue(entry.epoch ~= 2, "no historical trace poses as current work")
  end
  local reready, refailure = resumed:requestJob("message-bank", "219", "required")
  Assert.isFalse(reready, "reuse still starts pending")
  Assert.isNil(refailure, "reuse reports no failure")
  pump(resumed, 10)
  reready, refailure = resumed:requestJob("message-bank", "219", "required")
  Assert.isTrue(reready, "a validated receipt answers without recompilation")
  Assert.isNil(refailure, "reuse reports no failure")
  Assert.equal(env.pool:createdCount(2, "message-bank:219"), 0, "reuse submits nothing new")
  local missing, missingFailure = resumed:requestJob("message-bank", "3", "required")
  Assert.isFalse(missing, "missing work stays pending")
  Assert.isNil(missingFailure, "missing work reports no failure")
  pump(resumed, 10)
  Assert.equal(env.pool:createdCount(2, "message-bank:3"), 1, "one accepted request per identity per epoch")
  resumed:requestJob("message-bank", "3", "required")
  pump(resumed, 10)
  Assert.equal(env.pool:createdCount(2, "message-bank:3"), 1, "a second request deduplicates within its epoch")
end

-- Retirement drops logical work without erasing physical ownership: queued
-- interest cancels, a running slot stays charged, late old output cannot
-- publish as new, and identical keys restart as new-epoch interest.
function T.retirement_drops_logical_work_without_erasing_physical_ownership()
  local env = newEnv("retirement-generation", 2)
  local session = openSession(env, false)
  session:requestJob("message-bank", "219", "required")
  session:requestJob("message-bank", "3", "required")
  pump(session, 10)
  Assert.isTrue(env.pool.calls["message-bank:219"] ~= nil, "the queued job submits")
  Assert.isTrue(env.pool.calls["message-bank:3"] ~= nil, "the running job submits")
  env.pool:startRunning("message-bank:3")
  session:retire()
  Assert.equal(env.pool:status("message-bank:219"), "cancelled", "queued logical work cancels")
  Assert.equal(env.pool.physical["message-bank:3"], "running", "the physical slot stays charged")
  Assert.throws(function()
    session:requestJob("message-bank", "219", "required")
  end, "generation session is retired")
  local ok = pcall(env.pool.complete, env.pool, "message-bank:219")
  Assert.isFalse(ok, "a cancelled record never completes as current work")
  env.epoch = 2
  local resumed = openSession(env, false)
  Assert.equal(env.pool.physical["message-bank:3"], "running", "selection keeps old physical occupancy separate")
  resumed:requestJob("message-bank", "219", "required")
  resumed:requestJob("message-bank", "3", "required")
  pump(resumed, 10)
  Assert.equal(env.pool:createdCount(2, "message-bank:219"), 1, "identical keys restart as new interest")
  Assert.equal(env.pool:createdCount(2, "message-bank:3"), 1, "identical keys restart as new interest")
  env.pool:releasePhysical("message-bank:3")
  pump(resumed, 10)
  local reready, refailure = resumed:requestJob("message-bank", "3", "required")
  Assert.isFalse(reready, "stale output never satisfies the new epoch")
  Assert.isNil(refailure, "the new epoch stays pending on its own record")
end

-- A failed required metadata owner fails its scopes with the canonical
-- cause while unrelated independent work still succeeds.
function T.metadata_failure_reaches_scopes_without_success_wait()
  local env = newEnv("metadata-failure-generation", 2)
  local session = openSession(env, false)
  session:requestMilestone("bootstrap", "required")
  pump(session, 5)
  env.pool:fail("source-plan:global", "WORKER_FAILED: synthetic source failure")
  pump(session, 20)
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "the scope never succeeds behind its failed owner")
  Assert.isTrue(failure ~= nil, "the scope carries its failure")
  Assert.isTrue(
    tostring(failure):find("source-plan:global", 1, true) ~= nil,
    "the failure names its canonical cause: " .. tostring(failure)
  )
  withFixtureFacts(env, function()
    writeReceipt(env, "field-camera", "global")
    env.pool:complete("field-camera:global")
    pump(session, 10)
    local cameraReady, cameraFailure = session:requestJob("field-camera", "global", "required")
    Assert.isTrue(cameraReady, "unrelated work still succeeds: " .. tostring(cameraFailure))
  end)
  local status = session:status()
  Assert.isTrue(#status.failures >= 1, "the failure stays visible")
  Assert.isFalse(status.complete, "failure never reports successful completion")
end

-- An independent leaf stays independent: camera-only preparation touches
-- no source inventory, while a map still demands its actual dependency.
function T.independent_leaf_needs_no_inventory()
  local env = newEnv("leaf-isolation-generation", 2)
  local session = openSession(env, false)
  local reads = 0
  local realRead = SourcePlan.read
  SourcePlan.read = function()
    reads = reads + 1
    error("camera preparation must not read the source inventory", 0)
  end
  local ok, err = pcall(function()
    withFixtureFacts(env, function()
      writeReceipt(env, "field-camera", "global")
      local ready, failure = session:requestJob("field-camera", "global", "required")
      Assert.isFalse(ready, "the camera starts pending")
      Assert.isNil(failure, "the camera reports no failure")
      pump(session, 10)
      ready, failure = session:requestJob("field-camera", "global", "required")
      Assert.isTrue(reads == 0, "no source read backs camera preparation")
    end)
  end)
  SourcePlan.read = realRead
  Assert.isTrue(ok, tostring(err))
  Assert.equal(reads, 0, "camera preparation performs no inventory reads")
  local mapReady, mapFailure = session:requestJob("map", "7", "required")
  Assert.isFalse(mapReady, "map demand stays pending")
  Assert.isNil(mapFailure, "map demand reports no failure")
  pump(session, 5)
  Assert.isTrue(env.pool.calls["source-plan:global"] ~= nil, "a map still demands its actual source dependency")
end

-- Fairness is not an accident of registration or completion order: every
-- deterministic order covers the same union once with a bounded peak.
function T.finite_work_stays_fair_under_varied_completion_orders()
  local leaves = { "bag", "field-camera", "field-effects", "field-emotes", "field-ui", "field-font" }
  local function reversed(list)
    local out = {}
    for index = #list, 1, -1 do
      out[#out + 1] = list[index]
    end
    return out
  end
  local runs = 0
  for _, registerOrder in ipairs({ leaves, reversed(leaves) }) do
    for _, completionOrder in ipairs({ leaves, reversed(leaves) }) do
      runs = runs + 1
      local env = newEnv("fairness-generation-" .. tostring(runs), 2)
      local session = openSession(env, false)
      withFixtureFacts(env, function()
        for _, kind in ipairs(registerOrder) do
          session:requestJob(kind, "global", "required")
        end
        pump(session, 30)
        for _, kind in ipairs(completionOrder) do
          local jobKey = kind .. ":global"
          if env.pool.records[jobKey] ~= nil and env.pool.records[jobKey].state == "queued" then
            writeReceipt(env, kind, "global")
            env.pool:complete(jobKey)
            pump(session, 5)
          end
        end
        Assert.isTrue(drainLocal(session, 2000), "every order drains to idle")
        local outcomes = session:outcomes()
        local readySet = {}
        for _, outcome in ipairs(outcomes) do
          if outcome.state == "successful" then
            readySet[outcome.jobKey] = true
          end
          Assert.isTrue(outcome.state ~= "failed", "no order fails finite work: " .. outcome.jobKey)
        end
        for _, kind in ipairs(leaves) do
          Assert.isTrue(readySet[kind .. ":global"], "every order covers " .. kind)
        end
        for jobKey, calls in pairs(env.pool.calls) do
          Assert.equal(calls, 1, "no order duplicates an admission: " .. jobKey)
        end
        Assert.isTrue(env.pool.peakSweep <= 4, "every order respects the bound")
      end)
    end
  end
  Assert.equal(runs, 4, "the matrix covers both orders twice")
end

-- Logical enumeration is complete without forging physical execution
-- claims: the outcome inventory matches the canonical membership while
-- the accepted pool union stays bounded, and finite controlled releases
-- eventually cover the corpus.
function T.logical_enumeration_completes_without_forging_dispatch()
  local env = newEnv("dispatch-census-generation", 4)
  local session = openSession(env, true)
  withFixtureFacts(env, function()
    pump(session, 10)
    Assert.isTrue(env.pool.calls["source-plan:global"] ~= nil, "exhaustive intent discovers its inventory work")
    stageSynthetic(env)
    env.pool:complete("source-plan:global")
    pump(session, 10)
    local spins = 0
    while env.pool.calls["mon-catalog:global"] == nil and spins < 200 do
      pump(session, 5)
      spins = spins + 1
    end
    Assert.isTrue(env.pool.calls["mon-catalog:global"] ~= nil, "catalog work submits")
    stageLayout(env, "catalog-marker", "layout-marker")
    env.pool:complete("mon-catalog:global")
    pump(session, 30)
    local layoutReady, layoutFailure = session:requestJob("mon-layout", "global", "required")
    Assert.isTrue(layoutReady, "staged layout validates ready without redispatch: " .. tostring(layoutFailure))
    Assert.isTrue(session.pagesKnown, "page membership adopts from authentic published plans")
    local canonical = canonicalKeySet(
      ArtifactJobs.completeJobs(
        assert(ArtifactJobs.publishedPlans(env.cacheFs, env.identity), "the adopted inventory enumerates canonically")
      )
    )
    local enumerated = false
    spins = 0
    while not enumerated and spins < 20 do
      pump(session, 10)
      spins = spins + 1
      local observed = outcomeKeySet(session)
      enumerated = true
      for key in pairs(canonical) do
        if observed[key] == nil then
          enumerated = false
          break
        end
      end
    end
    Assert.isTrue(enumerated, "logical enumeration covers the canonical inventory")
    local readyCount, pendingCount = 0, 0
    for _, outcome in ipairs(session:outcomes()) do
      if outcome.state == "successful" then
        readyCount = readyCount + 1
      elseif outcome.state == "pending" then
        pendingCount = pendingCount + 1
      end
    end
    Assert.isTrue(pendingCount > 0, "enrollment alone compiles nothing")
    Assert.isTrue(env.pool.peakSweep <= 8, "physical dispatch stays bounded during enumeration")
    Assert.isTrue(finishCorpus(env, session, 8000), "finite controlled releases cover the corpus")
    Assert.isTrue(env.pool.peakSweep <= 8, "the peak stays bounded across releases")
    local final = session:status()
    Assert.isTrue(final.settled, "the covered corpus settles")
    Assert.isFalse(final.complete, "an unenrolled milestone never attests completeness")
  end)
end

-- Exhaustive intent owns its discovery: no later milestone request is
-- needed to start inventory work, finish enumeration, or settle.
function T.exhaustive_intent_progresses_without_later_rescue()
  local env = newEnv("exhaustive-intent-generation", 4)
  local session = openSession(env, true)
  withFixtureFacts(env, function()
    pump(session, 10)
    Assert.isTrue(env.pool.calls["source-plan:global"] ~= nil, "discovery starts from sweep intent alone")
    Assert.isFalse(session:status().settled, "an undiscovered corpus never settles")
    stageSynthetic(env)
    env.pool:complete("source-plan:global")
    pump(session, 10)
    local spins = 0
    while env.pool.calls["mon-catalog:global"] == nil and spins < 200 do
      pump(session, 5)
      spins = spins + 1
    end
    stageLayout(env, "catalog-marker", "layout-marker")
    env.pool:complete("mon-catalog:global")
    pump(session, 30)
    local layoutReady, layoutFailure = session:requestJob("mon-layout", "global", "required")
    Assert.isTrue(layoutReady, "staged layout validates ready without redispatch: " .. tostring(layoutFailure))
    Assert.isTrue(finishCorpus(env, session, 8000), "enumeration finishes without a later caller rescue")
    local final = session:status()
    Assert.isTrue(final.settled, "the exhausted sweep settles")
    Assert.isFalse(final.complete, "sweep success without milestones claims no completion")
  end)
end

-- A failed exhaustive discovery settles unsuccessfully: the terminal cause
-- is visible, unrelated published work is untouched, and success is never
-- forged.
function T.failed_discovery_settles_unsuccessfully()
  local env = newEnv("failed-discovery-generation", 2)
  local session = openSession(env, true)
  session:requestMilestone("bootstrap", "required")
  pump(session, 5)
  env.pool:fail("source-plan:global", "WORKER_FAILED: synthetic source failure")
  withFixtureFacts(env, function()
    local spins = 0
    while spins < 200 do
      completeQueued(env)
      pump(session, 5)
      spins = spins + 1
      local status = session:status()
      if status.settled then
        break
      end
    end
    local final = session:status()
    Assert.isTrue(final.settled, "a failed discovery settles instead of spinning")
    Assert.isFalse(final.complete, "a failed discovery never reports success")
    Assert.isTrue(#final.failures >= 1, "the terminal cause stays visible")
    local ready, failure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(ready, "the failed scope stays failed")
    Assert.isTrue(
      tostring(failure):find("source-plan:global", 1, true) ~= nil,
      "the scope names its failed owner: " .. tostring(failure)
    )
  end)
end

-- Command safeguards stay independent of session facts: pending scopes get
-- no proof, a recorded fatal keeps its failure evidence, and an unrelated
-- programming fault still propagates.
function T.command_proof_and_recorded_fatal_behavior()
  local realForVersion = CacheFs.forVersion
  local savedPool = package.loaded["romdump.src.build.CompilerPool"]
  local savedBuilder = package.loaded["romdump.src.CacheBuilder"]
  local function acquireScratch()
    local handle = assert(io.popen("mktemp -d", "r"))
    local path = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    handle:close()
    assert(path ~= "", "scratch acquisition requires mktemp")
    return path
  end
  local function withCommand(env, fn)
    package.loaded["romdump.src.build.CompilerPool"] = {
      new = function()
        return env.pool
      end,
    }
    CacheFs.forVersion = function()
      return realForVersion("heartgold", env.backend)
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    local CacheBuilder = require("romdump.src.CacheBuilder")
    local ok, first, second = pcall(fn, CacheBuilder)
    package.loaded["romdump.src.build.CompilerPool"] = savedPool
    package.loaded["romdump.src.CacheBuilder"] = savedBuilder
    CacheFs.forVersion = realForVersion
    env.pool.onWait = nil
    if not ok then
      error(first, 0)
    end
    return first, second
  end
  -- A scope held in the pool proves nothing: the wait fires, the failure
  -- is structured, and no invocation proof is issued.
  do
    local env = newEnv("proof-pending-generation", 2)
    local scratch = acquireScratch()
    local recordPath = scratch .. "/preparation.lua"
    withCommand(env, function(CacheBuilder)
      env.pool.onWait = function(pool)
        if pool.waitCalls >= 3 and pool:status("message-bank:219") == "queued" then
          pool:fail("message-bank:219", "WORKER_FAILED: synthetic held failure")
        end
      end
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        preparationRecord = recordPath,
        log = function() end,
      })
      Assert.isNil(report, "a pending scope issues no success report")
      Assert.isTrue(err ~= nil, "a pending scope reports its failure")
      local Errors = require("libs.errors.src.Errors")
      Assert.isTrue(Errors.is(err), "command failures stay structured")
      Assert.isTrue(env.pool.waitCalls >= 1, "the held scope waits physically")
      Assert.isNil(io.open(recordPath, "r"), "no proof is issued for a failed scope")
    end)
    os.execute("rm -rf -- '" .. scratch:gsub("'", "'\\''") .. "'")
  end
  -- A recorded fatal keeps its exact failure evidence.
  do
    local env = newEnv("proof-fatal-generation", 2)
    local fatal = "synthetic pool fatal"
    env.pool.diagnostics = function(self)
      return { workerCount = self.workerCount, counts = {}, error = fatal }
    end
    local realRequest = env.pool.request
    env.pool.request = function(self, job)
      if job.jobKey == "message-bank:219" then
        error(fatal, 0)
      end
      return realRequest(self, job)
    end
    withCommand(env, function(CacheBuilder)
      local report, err = CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        log = function() end,
      })
      Assert.isNil(report, "a fatal pool failure proves nothing")
      Assert.isTrue(err ~= nil, "the fatal failure is reported")
      Assert.isTrue(
        tostring(err):find("synthetic pool fatal", 1, true) ~= nil,
        "the recorded fatal keeps its evidence: " .. tostring(err)
      )
    end)
  end
  -- An unrelated programming fault is not a handled drain failure.
  do
    local env = newEnv("proof-raw-generation", 2)
    local realUpdate = env.pool.update
    env.pool.update = function()
      error("unexpected boom", 0)
    end
    local ok = pcall(withCommand, env, function(CacheBuilder)
      return CacheBuilder.prepareVersion("heartgold", {
        identity = env.identity,
        requirements = { "message-bank:219" },
        log = function() end,
      })
    end)
    env.pool.update = realUpdate
    Assert.isFalse(ok, "an unrelated fault still propagates")
  end
end

return { tests = T }
