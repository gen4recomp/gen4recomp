-- Census over the common generation session through the real ROM-derived
-- plans: bootstrap requests its exact fixed set with no geometry, field core
-- arrives as near work while geometry stays cold, demand promotes
-- dependencies, the sweep frontier stays bounded while every canonical key
-- is accounted for, failures stay visible without global collapse, and a
-- restarted generation reuses ready jobs.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local CacheFs = require("libs.storage.src.CacheFs")
local CompilerWorker = require("romdump.src.build.CompilerWorker")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FakeCache = require("tests.support.FakeCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local Schema = require("libs.script.src.Schema")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

local T = {}

local activeBackend = nil
local savedCacheFs = nil

local PRODUCER_BODY = string.rep("1", 64)

local function processorBound()
  local count = 1
  if love.system ~= nil and love.system.getProcessorCount ~= nil then
    count = math.max(1, math.floor(love.system.getProcessorCount()))
  end
  return 2 * math.max(1, math.min(4, math.floor((count - 1) / 2)))
end

local function identityFor(versionId, romSha1)
  return DerivedCacheState.current({
    versionId = versionId,
    romSha1 = romSha1,
    mode = "development",
    producerId = "d" .. PRODUCER_BODY,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
end

-- Synchronous in-process stand-in for the compiler pool: it records every
-- request with its urgency, never runs work by itself, and completes jobs
-- through the real worker entrypoint plus the real publication path, so
-- readiness observed by the session is production readiness.
local function FakePool()
  local pool = { records = {}, order = {}, selected = nil, peakSweep = 0 }
  function pool:selectGeneration(identity, epoch)
    self.selected = { identity = identity, epoch = epoch }
    self.retired = false
  end
  function pool:retireSelection(epoch)
    assert(type(epoch) == "number" and epoch % 1 == 0, "pool epoch must be an integer")
    if self.retired then
      return false
    end
    self.retired = true
    return true
  end
  function pool:request(job)
    assert(type(job) == "table", "pool job must be a table")
    assert(type(job.jobKey) == "string" and job.jobKey ~= "", "pool job needs an identity")
    local record = self.records[job.jobKey]
    if record ~= nil and record.state ~= "cancelled" then
      if record.state == "failed" then
        error(record.details and record.details.error or "compiler job failed", 0)
      end
      if record.state == "queued" and job.priority < record.priority then
        record.priority = job.priority
      end
      return record.state, record.details
    end
    record = { kind = job.kind, key = job.key, jobKey = job.jobKey, priority = job.priority, job = job }
    record.state = "queued"
    self.records[job.jobKey] = record
    self.order[#self.order + 1] = job.jobKey
    local outstanding = self:outstandingSweep()
    if outstanding > self.peakSweep then
      self.peakSweep = outstanding
    end
    return record.state
  end
  function pool:status(jobKey)
    local record = self.records[jobKey]
    if record == nil then
      return "unknown"
    end
    return record.state, record.details
  end
  function pool:update()
    return true
  end
  function pool:retry(jobKey, priority)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    assert(record.state == "failed", "only failed compiler jobs can be retried")
    record.state = "queued"
    record.priority = priority
    record.details = nil
    return record.state
  end
  function pool:quiesce()
    self.quiescing = true
  end
  function pool:isQuiescent()
    return self.quiescing == true
  end
  function pool:diagnostics()
    local counts = { queued = 0, running = 0, prepared = 0, ready = 0, failed = 0, cancelled = 0 }
    for _, record in pairs(self.records) do
      if counts[record.state] ~= nil then
        counts[record.state] = counts[record.state] + 1
      end
    end
    return counts
  end
  function pool:shutdown() end
  function pool:fail(jobKey, message)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    record.state = "failed"
    record.details = { error = message }
  end
  function pool:markReady(jobKey)
    local record = assert(self.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
    record.state = "ready"
    record.details = nil
  end
  function pool:outstandingSweep()
    local count = 0
    for _, record in pairs(self.records) do
      if record.priority == 100 and (record.state == "queued" or record.state == "running") then
        count = count + 1
      end
    end
    return count
  end
  function pool:requestSet()
    local set = {}
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      set[record.kind .. ":" .. record.key] = record.priority
    end
    return set
  end
  function pool:recordsForKind(kind)
    local found = {}
    for _, jobKey in ipairs(self.order) do
      local record = self.records[jobKey]
      if record.kind == kind then
        found[#found + 1] = record
      end
    end
    return found
  end
  return pool
end

local function openSession(identity, epoch, pool, sweepEnabled)
  -- Resolved at call time so the suite hooks' filesystem routing applies to
  -- the session's internally built owner.
  local SessionBuild = require("romdump.src.build.InteractiveCacheBuild")
  local ok, session = pcall(SessionBuild.new, {
    identity = identity,
    epoch = epoch,
    pool = pool,
    sweepEnabled = sweepEnabled,
  })
  if not ok then
    error("common generation session is unavailable: " .. tostring(session), 0)
  end
  assert(type(session.requestMilestone) == "function", "common session has no milestone requests")
  assert(type(session.status) == "function", "common session has no status")
  assert(type(session.retire) == "function", "common session cannot retire")
  assert(type(session.requestJob) == "function", "common session has no targeted job requests")
  return session
end

local function drive(session, rounds)
  for _ = 1, rounds do
    local ok, err = pcall(session.update, session)
    if not ok then
      error("session update failed: " .. tostring(err), 0)
    end
  end
end

local function settle(session, pool, cap)
  -- Bounded planning converges over pool-silent rounds: entries sorted late
  -- still need their slice after worker completions land, so quiescence is
  -- pool order AND session progress (ready/failed counts) holding still,
  -- not pool order alone, and the pump must report no runnable local
  -- planning remains. The quiet threshold spans a full post-adoption
  -- re-drive: adopting the worker inventory resets dependency memoization,
  -- so re-planning one several-hundred-child parent (message banks here,
  -- frozen game data) takes a dozen silent passes before it resubmits.
  local lastCount = #pool.order
  local status = session:status()
  local lastReady, lastFailed = status.ready, status.failed
  local calm = 0
  for _ = 1, cap or 2000 do
    drive(session, 1)
    status = session:status()
    if
      #pool.order == lastCount
      and status.ready == lastReady
      and status.failed == lastFailed
      and not status.planningPending
    then
      calm = calm + 1
      if calm >= 25 then
        return
      end
    else
      lastCount = #pool.order
      lastReady, lastFailed = status.ready, status.failed
      calm = 0
    end
  end
  error("session kept planning beyond the round cap", 0)
end

local function checkPending(first, second, what)
  Assert.isFalse(first, what .. " stays pending while cold")
  Assert.isTrue(second == nil, what .. " must not fail while cold")
end

local function checkFailed(first, second, key, what)
  Assert.isFalse(first, what .. " must answer false once failed")
  Assert.isTrue(type(second) ~= "nil", what .. " must name its error")
  Assert.isTrue(tostring(second):find(tostring(key), 1, true) ~= nil, what .. " names its canonical key")
end

local function sortedKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function expectedBootstrapSet(audioBankIds)
  local expected = {
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
    "items:global",
    "mon-catalog:global",
    "mon-layout:global",
    "message-bank:219",
    "audio-summary:global",
  }
  for _, bankId in ipairs(audioBankIds) do
    expected[#expected + 1] = "audio-bank:" .. tostring(bankId)
  end
  table.sort(expected)
  return expected
end

local function failedCount(status)
  if type(status.failed) == "number" then
    return status.failed
  end
  return #status.failed
end

local function failuresText(status)
  local parts = {}
  if type(status.failures) == "table" then
    for _, entry in pairs(status.failures) do
      parts[#parts + 1] = tostring(entry)
    end
  elseif status.failures ~= nil then
    parts[#parts + 1] = tostring(status.failures)
  end
  return table.concat(parts, "\n")
end

local function workerContextFor(romFs, versionId, cacheFs)
  local context = {
    cacheFs = cacheFs,
    romFs = romFs,
    versionId = versionId,
    terrainScratch = {},
    fieldCellScratch = {
      geometryArena = GxGeometryBuffer.new(),
      gxScratch = GxDisplayList.newScratch(),
    },
  }
  context.fieldCellScratch.terrainScratch = context.terrainScratch
  context.geometryArena = context.fieldCellScratch.geometryArena
  context.gxScratch = context.fieldCellScratch.gxScratch
  return context
end

local function completeThroughWorker(context, pool, jobKey, stageName)
  local record = assert(pool.records[jobKey], "unknown compiler job: " .. tostring(jobKey))
  local job = record.job
  local workerJob = {
    kind = job.kind,
    key = job.key,
    generationId = job.generationId,
    epoch = job.epoch,
    versionId = job.versionId,
    stageName = stageName,
  }
  for _, source in ipairs({ job, job.payload }) do
    if type(source) == "table" then
      for field, value in pairs(source) do
        if workerJob[field] == nil and field ~= "payload" and field ~= "jobKey" then
          workerJob[field] = value
        end
      end
    end
  end
  local ok, result = pcall(CompilerWorker.execute, workerJob, context)
  if not ok then
    error("worker path cannot complete " .. tostring(jobKey) .. ": " .. tostring(result), 0)
  end
  local artifact = PreparedArtifact.open({
    cacheFs = context.cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.jobKey,
    stageName = workerJob.stageName,
  })
  artifact:publish({
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.jobKey,
  })
  pool:markReady(jobKey)
  return result
end

function T.common_session_drives_bootstrap_core_and_sweep(romFs, versionId)
  -- Writer isolation: the census borrows the real dump read-only while every
  -- receipt, milestone, and publication lands in the owned backend the suite
  -- hooks installed, so the shared prepared fixture never changes under
  -- parallel readers.
  assert(activeBackend ~= nil, "the census owns its backend for the run")
  local cache = CacheFs.forVersion(versionId, activeBackend)
  local liveCache = CacheFs.forVersion(versionId)
  local rawBefore = liveCache:read(RawDumpContract.MARKER_PATH)
  local romSha1 = assert(romFs:metadata().sha1, "dump has no SHA-1 identity")
  local identity = identityFor(versionId, romSha1)
  local generationId = assert(identity.generationId, "generation identity is required")
  local pool = FakePool()
  local context = workerContextFor(romFs, versionId, cache)
  -- Milestone files live in the private backend: the snapshot below proves
  -- this session records nothing while audio banks stay cold.
  local bootstrapBefore = cache:read("data/generated/bootstrap.lua")
  local bound = processorBound()
  local stageSeq = 0
  local function complete(jobKey)
    stageSeq = stageSeq + 1
    return completeThroughWorker(context, pool, jobKey, "census-" .. tostring(stageSeq))
  end

  -- Independent census expectations from the family planners themselves.
  local audioPlan = assert(AudioCompiler.plan(romFs), "audio plan is required")
  local audioBankIds = {}
  for _, bankPlan in ipairs(audioPlan.bankPlans) do
    audioBankIds[#audioBankIds + 1] = assert(bankPlan.bankId, "audio closure needs its bank identity")
  end
  table.sort(audioBankIds)
  local scriptPlan = ScriptCompiler.plan(romFs, "census-producer")
  local scriptMemberIds = {}
  for _, member in ipairs(scriptPlan.members) do
    scriptMemberIds[#scriptMemberIds + 1] = member.memberId
  end
  table.sort(scriptMemberIds)
  Assert.isTrue(#scriptMemberIds > 0, "the script census must be non-empty")
  local requiredBanks = FieldMessageCompiler.requiredBankIds()
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs), "mon catalog is required")
  local presentation = assert(MonPresentationCompiler.plan(romFs, catalog), "mon page plan is required")
  local iconPageIds = {}
  for _, pageId in ipairs(presentation.icons.pageIds) do
    iconPageIds[#iconPageIds + 1] = pageId
  end
  table.sort(iconPageIds)
  local portraitPageIds = {}
  for _, pageId in ipairs(presentation.portraits.pageIds) do
    portraitPageIds[#portraitPageIds + 1] = pageId
  end
  table.sort(portraitPageIds)
  Assert.isTrue(#portraitPageIds > 0, "the portrait census must be non-empty")
  local indexBundle = assert(FieldCellCompiler.compileIndex(romFs, "census-producer"), "cell index is required")
  local cellKeys = {}
  for _, matrix in ipairs(indexBundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      cellKeys[#cellKeys + 1] = descriptor.matrixMemberId .. "-" .. descriptor.index
    end
  end
  table.sort(cellKeys)
  Assert.isTrue(#cellKeys > 0, "the cell census must be non-empty")
  local mapCount = 0
  for _ in MapCatalog.all() do
    mapCount = mapCount + 1
  end
  Assert.isTrue(mapCount > 0, "the map catalog must be non-empty")
  local mapSession = assert(FieldMapDataCompiler.newSession(romFs), "field-data session is required")
  local mapDataIds = {}
  for mapId = 0, mapCount - 1 do
    if mapSession:compile(mapId) ~= nil then
      mapDataIds[#mapDataIds + 1] = mapId
    end
  end
  mapSession:close()
  Assert.isTrue(#mapDataIds > 0, "the field-data census must be non-empty")
  local resolvedMapIds = {}
  for mapId = 0, mapCount - 1 do
    local ok, plan = pcall(MapCompilePlan.plan, romFs, indexBundle.index, mapId, "census-producer")
    if ok and plan ~= nil then
      resolvedMapIds[#resolvedMapIds + 1] = mapId
    end
  end
  Assert.isTrue(#resolvedMapIds > 0, "the geometry census must be non-empty")

  -- Targeted client: bootstrap plans its exact set with sweep disabled.
  local targeted = openSession(identity, 1, pool, false)
  -- Readiness the session observes is the owned backend's state, so work the
  -- session itself completes is never resubmitted. Snapshot current-generation
  -- receipts for the whole field-core membership before the session runs so
  -- expectations below stay exact.
  local preReady = {}
  do
    local membership = expectedBootstrapSet(audioBankIds)
    for _, bankId in ipairs(requiredBanks) do
      membership[#membership + 1] = "message-bank:" .. tostring(bankId)
    end
    for _, memberId in ipairs(scriptMemberIds) do
      membership[#membership + 1] = "script-member:" .. tostring(memberId)
    end
    for _, mapId in ipairs(mapDataIds) do
      membership[#membership + 1] = "map-data:" .. tostring(mapId)
    end
    for _, pageId in ipairs(iconPageIds) do
      membership[#membership + 1] = "mon-icon-page:" .. tostring(pageId)
    end
    for _, name in ipairs({
      "message-summary:global",
      "audio-summary:global",
      "script-summary:global",
      "actors:global",
      "starter-choice:global",
      "items:global",
      "bag:global",
    }) do
      membership[#membership + 1] = name
    end
    for _, identityKey in ipairs(membership) do
      local kind, key = identityKey:match("^([^:]+):(.+)$")
      assert(kind ~= nil and key ~= nil, "census membership carries kind:key identities")
      if ArtifactState.read(cache, generationId, kind, key) ~= nil then
        preReady[identityKey] = true
      end
    end
  end
  do
    local status = targeted:status()
    Assert.keySet(
      status,
      "bootstrap,complete,enumerated,enumerationComplete,epoch,failed,failures,fieldCore,generationId,planningPending,queued,ready,running,settled"
    )
    Assert.equal(status.generationId, generationId)
    Assert.isFalse(status.complete, "an untouched session completes nothing")
  end
  do
    local first, second = targeted:requestMilestone("bootstrap", "required")
    checkPending(first, second, "bootstrap")
  end
  settle(targeted, pool)
  -- The persisted source inventory is a heavy worker job like any other:
  -- complete it through the real worker path so the session plans the
  -- census from published data rather than controller compilation. A reused
  -- root adopts the already-published inventory without resubmitting it.
  if pool.records["source-plan:global"] ~= nil and pool.records["source-plan:global"].state == "queued" then
    complete("source-plan:global")
    settle(targeted, pool)
  end
  local targetedSet
  do
    local requested = pool:requestSet()
    -- Membership, not order: the pool plans in request order while the
    -- census contract is a set. Upfront planning is also
    -- dependency-gated (ArtifactJobs.dependencies): mon-layout waits for
    -- mon-catalog and audio-summary waits for the audio banks, so a cold
    -- session plans the coarse set minus those gated parents; members
    -- already ready on a reused root are never resubmitted either.
    -- Report both directions explicitly.
    local expected = expectedBootstrapSet(audioBankIds)
    local gatedParents = { ["mon-layout:global"] = true, ["audio-summary:global"] = true }
    local expectedSet = {}
    for _, identityKey in ipairs(expected) do
      expectedSet[identityKey] = true
    end
    local missing, unexpected = {}, {}
    for _, identityKey in ipairs(expected) do
      if not gatedParents[identityKey] and not preReady[identityKey] and requested[identityKey] == nil then
        missing[#missing + 1] = identityKey
      end
    end
    for _, identityKey in ipairs(sortedKeys(requested)) do
      if expectedSet[identityKey] == nil and identityKey ~= "source-plan:global" then
        unexpected[#unexpected + 1] = identityKey
      end
    end
    Assert.equal(#missing, 0, "bootstrap must plan every census contract, missing: " .. table.concat(missing, ", "))
    Assert.equal(
      #unexpected,
      0,
      "bootstrap must plan nothing beyond its census contract, unexpected: " .. table.concat(unexpected, ", ")
    )
    targetedSet = requested
    for identityKey in pairs(requested) do
      local kind = identityKey:match("^([^:]+):")
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
          and kind ~= "starter-choice",
        "bootstrap must not compile geometry, field records, scripts, or pages: " .. identityKey
      )
    end
    for _, record in pairs(pool.records) do
      Assert.isTrue(record.priority ~= 100, "a targeted client enables no sweep work")
    end
    Assert.throws(function()
      targeted:requestMilestone("everything", "required")
    end, "milestones accept only the two fixed names")
    Assert.throws(function()
      targeted:requestJob("bogus-kind", "global", "required")
    end, "job requests validate the closed kind vocabulary")
    Assert.throws(function()
      targeted:requestJob("map", "not-a-key", "required")
    end, "job requests validate canonical keys")
  end
  targeted:retire()

  -- Full client: field core arrives as near work while geometry stays cold.
  local session = openSession(identity, 2, pool, true)
  do
    local first, second = session:requestMilestone("field-core", "required")
    checkPending(first, second, "field core")
  end
  settle(session, pool)
  do
    local requested = pool:requestSet()
    -- A restart under a new epoch re-plans the same cold bootstrap set.
    -- The pool union persists across epochs, so every upfront member
    -- planned cold stays visible; gated parents and already-ready members
    -- were never (re)submitted and stay out of the expectation.
    local gatedParents = { ["mon-layout:global"] = true, ["audio-summary:global"] = true }
    for _, identityKey in ipairs(expectedBootstrapSet(audioBankIds)) do
      if not gatedParents[identityKey] and not preReady[identityKey] then
        Assert.notNil(requested[identityKey], "restart keeps the planned bootstrap identities")
      end
    end
    for identityKey in pairs(targetedSet) do
      Assert.notNil(requested[identityKey], "restart keeps the planned bootstrap identities")
    end
    local missing = {}
    -- A gated parent is correctly deferred while any prerequisite is
    -- still pending (ArtifactJobs.dependencies; a parent never occupies a
    -- worker before its children are ready). Demand planning only for
    -- members whose prerequisites are all ready -- and never for members
    -- already ready on a reused root.
    local function expect(kind, key, depKeys)
      local identityKey = kind .. ":" .. key
      if requested[identityKey] ~= nil or preReady[identityKey] then
        return
      end
      for _, depKey in ipairs(depKeys or {}) do
        local record = pool.records[depKey]
        if record == nil or record.state ~= "ready" then
          return
        end
      end
      missing[#missing + 1] = identityKey
    end
    local messageBankKeys, audioBankKeys, scriptMemberKeys = {}, {}, {}
    for _, bankId in ipairs(requiredBanks) do
      expect("message-bank", tostring(bankId))
      messageBankKeys[#messageBankKeys + 1] = "message-bank:" .. tostring(bankId)
    end
    for _, bankId in ipairs(audioBankIds) do
      audioBankKeys[#audioBankKeys + 1] = "audio-bank:" .. tostring(bankId)
    end
    for _, memberId in ipairs(scriptMemberIds) do
      expect("script-member", tostring(memberId))
      scriptMemberKeys[#scriptMemberKeys + 1] = "script-member:" .. tostring(memberId)
    end
    for _, mapId in ipairs(mapDataIds) do
      expect("map-data", tostring(mapId))
    end
    for _, pageId in ipairs(iconPageIds) do
      expect("mon-icon-page", tostring(pageId), { "mon-layout:global" })
    end
    expect("message-summary", "global", messageBankKeys)
    expect("audio-summary", "global", audioBankKeys)
    expect("script-summary", "global", scriptMemberKeys)
    expect("actors", "global")
    expect("starter-choice", "global")
    expect("items", "global")
    expect("bag", "global")
    Assert.equal(
      #missing,
      0,
      "field core must plan every synchronous consumer contract, missing: " .. table.concat(missing, ", ")
    )
    for identityKey in pairs(requested) do
      local kind = identityKey:match("^([^:]+):")
      Assert.isTrue(
        kind ~= "map" and kind ~= "field-cell" and kind ~= "mon-portrait-page" and kind ~= "mon-summary",
        "field entry must not wait for geometry or portraits: " .. identityKey
      )
    end
  end

  -- Complete the cheap families through the real worker path.
  local completed = {}
  local function completeKind(kind)
    for _, record in ipairs(pool:recordsForKind(kind)) do
      if pool.records[record.jobKey].state == "queued" then
        complete(record.jobKey)
        completed[record.kind .. ":" .. record.key] = true
      end
    end
  end
  for _, kind in ipairs({
    "world-catalog",
    "field-cell-index",
    "field-camera",
    "field-weather",
    "field-effects",
    "field-emotes",
    "field-ui",
    "field-font",
    "intro",
    "new-game-init",
    "items",
    "bag",
    "mon-catalog",
  }) do
    completeKind(kind)
  end
  -- Let gated parents submit once their children publish: mon-layout
  -- waits for mon-catalog, so it only reaches the pool after this settle.
  settle(session, pool)
  for _, kind in ipairs({
    "mon-layout",
    "actors",
    "starter-choice",
  }) do
    completeKind(kind)
  end
  completeKind("message-bank")
  settle(session, pool)
  do
    -- The summary is planned once its banks complete; a published summary
    -- answers ready instead.
    if ArtifactState.read(cache, generationId, "message-summary", "global") == nil then
      local summaries = pool:recordsForKind("message-summary")
      Assert.isTrue(#summaries >= 1, "the message summary is planned once its banks can complete")
      complete(summaries[1].jobKey)
      completed[summaries[1].kind .. ":" .. summaries[1].key] = true
    end
  end
  completeKind("script-member")
  settle(session, pool)
  do
    if ArtifactState.read(cache, generationId, "script-summary", "global") == nil then
      local summaries = pool:recordsForKind("script-summary")
      Assert.isTrue(#summaries >= 1, "the script summary is planned once its members can complete")
      complete(summaries[1].jobKey)
      completed[summaries[1].kind .. ":" .. summaries[1].key] = true
    end
  end
  do
    local records = pool:recordsForKind("map-data")
    Assert.isTrue(#records > 0, "field records are planned")
    complete(records[1].jobKey)
    completed[records[1].kind .. ":" .. records[1].key] = true
  end

  -- Demand promotes its prerequisites to required with one job per identity.
  -- Demand runs after the cheap families complete: dependency gating holds
  -- demanded parents until their children are ready, so cells submit only
  -- once the cell index is published and portrait pages only once the
  -- layout is published.
  local demandMapId, demandPlan
  for _, mapId in ipairs(resolvedMapIds) do
    local plan = assert(MapCompilePlan.plan(romFs, indexBundle.index, mapId, "census-producer"))
    if plan.strategy == "canonical" and #plan.cellPlans > 0 then
      demandMapId, demandPlan = mapId, plan
      break
    end
  end
  Assert.notNil(demandMapId, "the census needs a canonical map with cell dependencies")
  do
    local first, second = session:requestField(demandMapId, "required")
    checkPending(first, second, "map demand")
  end
  local firstCell = assert(demandPlan.cellPlans[1], "demand map needs a cell dependency").descriptor
  do
    local first, second = session:requestCell(firstCell, "required")
    checkPending(first, second, "cell demand")
  end
  local portraitPage = portraitPageIds[1]
  do
    local first, second = session:requestMonPortraitPage(portraitPage, "required")
    checkPending(first, second, "portrait demand")
  end
  settle(session, pool)
  do
    local requested = pool:requestSet()
    local seen = {}
    for _, jobKey in ipairs(pool.order) do
      Assert.isNil(seen[jobKey], "one job exists per identity: " .. jobKey)
      seen[jobKey] = true
    end
    for _, cellPlan in ipairs(demandPlan.cellPlans) do
      local descriptor = cellPlan.descriptor
      local key = "field-cell:" .. descriptor.matrixMemberId .. "-" .. descriptor.index
      Assert.equal(
        requested[key],
        0,
        "map demand promotes its cell dependencies to required, got " .. tostring(requested[key]) .. " for " .. key
      )
    end
    Assert.equal(requested["mon-portrait-page:" .. tostring(portraitPage)], 0, "portrait demand is required work")
  end
  session:retire()

  -- A restarted generation reuses ready jobs without touching raw source.
  local resumed = openSession(identity, 3, pool, true)
  do
    local first, second = resumed:requestMilestone("bootstrap", "required")
    checkPending(first, second, "resumed bootstrap")
  end
  do
    local first, second = resumed:requestMilestone("field-core", "required")
    checkPending(first, second, "resumed core")
  end
  settle(resumed, pool)
  do
    local recompiled = {}
    for _, jobKey in ipairs(pool.order) do
      local record = pool.records[jobKey]
      if record.job.epoch == 3 and completed[record.kind .. ":" .. record.key] then
        recompiled[#recompiled + 1] = record.kind .. ":" .. record.key
      end
    end
    Assert.deepEqual(recompiled, {}, "ready jobs are skipped before any compiler runs")
    for _, memberId in ipairs(scriptMemberIds) do
      local receipt = ArtifactState.read(cache, generationId, "script-member", tostring(memberId))
      Assert.notNil(receipt, "completed script members stay published across restart")
    end
    Assert.equal(
      liveCache:read(RawDumpContract.MARKER_PATH),
      rawBefore,
      "resume never re-imports or deletes the borrowed raw source"
    )
    Assert.equal(
      cache:read("data/generated/bootstrap.lua"),
      bootstrapBefore,
      "no milestone is recorded while audio banks are cold"
    )
    local status = resumed:status()
    Assert.isFalse(status.complete, "the census never completes the whole corpus")
    Assert.equal(failedCount(status), 0, "no failure has been injected yet")
  end

  -- The sweep storm: every canonical key is accounted for while the frontier
  -- stays bounded, and failures stay visible without global collapse. The
  -- bulky geometry families arrive as required work up front (required
  -- urgency never waits on the frontier); portraits arrive as sweep under a
  -- lazily drained frontier, so held descriptors never accumulate and no
  -- settling pass is needed.
  local storm = openSession(identity, 4, pool, true)
  local shelteredPortrait = "mon-portrait-page:" .. tostring(portraitPageIds[2] or portraitPageIds[1])
  local function sweepQueuedCount()
    local count = 0
    for _, record in pairs(pool.records) do
      if record.priority == 100 and record.state == "queued" then
        count = count + 1
      end
    end
    return count
  end
  local function ensureSweepSpace()
    while sweepQueuedCount() >= bound do
      local oldest
      for _, jobKey in ipairs(pool.order) do
        local record = pool.records[jobKey]
        if record.priority == 100 and record.state == "queued" and jobKey ~= shelteredPortrait then
          oldest = jobKey
          break
        end
      end
      Assert.notNil(oldest, "bounded sweep drain must keep advancing held descriptors")
      complete(oldest)
      Assert.isTrue(pool.peakSweep <= bound, "the sweep frontier never exceeds twice the worker count")
    end
  end
  local function checkPendingOrPublished(first, second, kind, key, what)
    -- A reused root answers already-published work as ready: that is the
    -- correct session answer, so only demand pending-or-published.
    if first then
      Assert.notNil(
        ArtifactState.read(cache, generationId, kind, tostring(key)),
        what .. " answers ready only for published work"
      )
      return
    end
    checkPending(first, second, what)
  end
  local function requestSweep(kind, key)
    -- A shared identity deduplicates across urgencies, so a key the pool
    -- already holds stays covered by its existing entry in the union below.
    -- Requesting it again as sweep would pin a permanent frontier slot: the
    -- session counts the new sweep-urgency interest as outstanding while the
    -- older required or near pool record never cycles through this drain.
    if pool:status(kind .. ":" .. key) ~= "unknown" then
      return
    end
    ensureSweepSpace()
    local ok, first, second = pcall(storm.requestJob, storm, kind, key, "sweep")
    if not ok then
      error("sweep must accept canonical " .. kind .. "/" .. tostring(key) .. ": " .. tostring(first), 0)
    end
    checkPendingOrPublished(first, second, kind, key, "sweep " .. kind .. "/" .. tostring(key))
  end
  local function presubmitRequired(kind, key)
    local ok, first, second = pcall(storm.requestJob, storm, kind, key, "required")
    if not ok then
      error("presubmit must accept canonical " .. kind .. "/" .. tostring(key) .. ": " .. tostring(first), 0)
    end
    checkPendingOrPublished(first, second, kind, key, "presubmit " .. kind .. "/" .. tostring(key))
  end
  for _, key in ipairs(cellKeys) do
    presubmitRequired("field-cell", key)
  end
  for _, mapId in ipairs(resolvedMapIds) do
    presubmitRequired("map", tostring(mapId))
  end
  for _, pageId in ipairs(portraitPageIds) do
    requestSweep("mon-portrait-page", tostring(pageId))
  end
  for _, pageId in ipairs(iconPageIds) do
    requestSweep("mon-icon-page", tostring(pageId))
  end
  for _, bankId in ipairs(audioBankIds) do
    requestSweep("audio-bank", tostring(bankId))
  end
  for _, key in ipairs(cellKeys) do
    requestSweep("field-cell", key)
  end
  for _, mapId in ipairs(resolvedMapIds) do
    requestSweep("map", tostring(mapId))
  end
  for _, mapId in ipairs(mapDataIds) do
    -- The drain already completed this record through the production worker
    -- path; a ready job answers ready, so only cold records sweep here. The
    -- union below still accounts for every record through its epoch-2 entry.
    if not completed["map-data:" .. tostring(mapId)] then
      requestSweep("map-data", tostring(mapId))
    end
  end
  do
    -- Registration-only planning submits nothing by itself: required cells
    -- and maps drain first (ungated) while sweep parks behind the backlog
    -- under the session's own frontier, so pump until the sweep frontier
    -- has carried every portrait page into the pool, completing queued
    -- sweep through the real worker path to keep the frontier bounded.
    -- Portraits are the completion proxy, not the full canonical list:
    -- required cells submit ungated ahead of sweep, pool-known icons and
    -- audio were skipped at registration, cold map-data was skipped, and
    -- gated maps resolve through the re-request tracking fallback below,
    -- while portraits sort last among the newly submitted sweep families,
    -- so portrait-union coverage implies the rest have submitted. The
    -- per-iteration coverage check stays a cheap in-memory lookup against
    -- the pool union; no per-key filesystem probes in the hot loop.
    local function drainSweepRoom()
      while sweepQueuedCount() >= bound do
        local oldest
        for _, jobKey in ipairs(pool.order) do
          local record = pool.records[jobKey]
          if record.priority == 100 and record.state == "queued" and jobKey ~= shelteredPortrait then
            oldest = jobKey
            break
          end
        end
        Assert.notNil(oldest, "bounded sweep drain must keep advancing held descriptors")
        complete(oldest)
        Assert.isTrue(pool.peakSweep <= bound, "the sweep frontier never exceeds twice the worker count")
      end
    end
    local function unionCovered()
      local union = pool:requestSet()
      local missingPortraits, missingCells = 0, 0
      for _, pageId in ipairs(portraitPageIds) do
        if union["mon-portrait-page:" .. tostring(pageId)] == nil then
          missingPortraits = missingPortraits + 1
        end
      end
      for _, key in ipairs(cellKeys) do
        if union["field-cell:" .. key] == nil then
          missingCells = missingCells + 1
        end
      end
      return missingPortraits == 0 and missingCells == 0
    end
    local done = unionCovered()
    local iter = 0
    while not done and iter < 3000 do
      iter = iter + 1
      drive(storm, 1)
      drainSweepRoom()
      done = unionCovered()
    end
    Assert.isTrue(done, "the sweep frontier carries every portrait page into the pool")
  end
  do
    Assert.isTrue(pool.peakSweep <= bound, "the sweep frontier never exceeds twice the worker count")
    local union = pool:requestSet()
    -- Accounted for means planned this run or published by an earlier
    -- run under the same generation: a reused root never resubmits
    -- ready work, so receipts count alongside pool records. Maps are
    -- correctly gated behind their cells (ArtifactJobs.dependencies), so
    -- a map the pool never received still counts when the session keeps
    -- tracking it: re-requesting must accept it as pending, never lose
    -- it as a failure.
    local absent = {}
    local function expect(kind, key)
      local identityKey = kind .. ":" .. key
      if union[identityKey] ~= nil then
        return
      end
      if ArtifactState.read(cache, generationId, kind, key) ~= nil then
        return
      end
      if kind == "map" then
        local ok, _, second = pcall(storm.requestJob, storm, kind, key, "sweep")
        if ok and second == nil then
          return
        end
        absent[#absent + 1] = identityKey .. (ok and " (lost: " .. tostring(second) .. ")" or " (rejected)")
        return
      end
      absent[#absent + 1] = identityKey
    end
    for _, memberId in ipairs(scriptMemberIds) do
      expect("script-member", tostring(memberId))
    end
    for _, bankId in ipairs(requiredBanks) do
      expect("message-bank", tostring(bankId))
    end
    for _, bankId in ipairs(audioBankIds) do
      expect("audio-bank", tostring(bankId))
    end
    for _, pageId in ipairs(iconPageIds) do
      expect("mon-icon-page", tostring(pageId))
    end
    for _, pageId in ipairs(portraitPageIds) do
      expect("mon-portrait-page", tostring(pageId))
    end
    for _, key in ipairs(cellKeys) do
      expect("field-cell", key)
    end
    for _, mapId in ipairs(resolvedMapIds) do
      expect("map", tostring(mapId))
    end
    for _, mapId in ipairs(mapDataIds) do
      expect("map-data", tostring(mapId))
    end
    Assert.equal(#absent, 0, "every canonical key is eventually accounted for, absent: " .. table.concat(absent, ", "))
    local supportedRecords = {}
    for _, mapId in ipairs(mapDataIds) do
      supportedRecords[mapId] = true
    end
    for mapId = 0, mapCount - 1 do
      local _, plan = pcall(MapCompilePlan.plan, romFs, indexBundle.index, mapId, "census-producer")
      if plan == nil then
        Assert.isNil(union["map:" .. tostring(mapId)], "source-excluded maps are never requested")
      end
      if not supportedRecords[mapId] then
        Assert.isNil(union["map-data:" .. tostring(mapId)], "unsupported field records are never requested")
      end
    end
    -- Shared identities deduplicate across urgencies; promotion only
    -- strengthens the recorded urgency.
    local portraitKey = "mon-portrait-page:" .. tostring(portraitPageIds[1])
    local duplicates = 0
    for _, jobKey in ipairs(pool.order) do
      if jobKey == portraitKey then
        duplicates = duplicates + 1
      end
    end
    Assert.equal(duplicates, 1, "one job exists per identity")
    do
      local first, second = storm:requestJob("mon-portrait-page", tostring(portraitPageIds[1]), "required")
      checkPending(first, second, "promoted portrait")
    end
    Assert.equal(pool.records[portraitKey].priority, 0, "demand promotes the sweep parent")
    -- The promoted entry only submits on the next pump, so run it before
    -- failing the pool record below; an unsubmitted failure cannot be observed.
    drive(storm, 10)
  end

  -- A failed portrait stays visible while unrelated work continues.
  do
    local portraitKey = "mon-portrait-page:" .. tostring(portraitPageIds[1])
    local siblingKey = "mon-portrait-page:" .. tostring(portraitPageIds[2] or portraitPageIds[1])
    local failure = "simulated worker failure " .. generationId .. " mon-portrait-page " .. tostring(portraitPageIds[1])
    pool:fail(portraitKey, failure)
    drive(storm, 5)
    local status = storm:status()
    Assert.isTrue(failedCount(status) >= 1, "failures are reported truthfully")
    Assert.isTrue(
      failuresText(status):find(tostring(portraitPageIds[1]), 1, true) ~= nil,
      "failures name their canonical key"
    )
    if siblingKey ~= portraitKey then
      Assert.equal(pool.records[siblingKey].state, "queued", "unrelated sweep work is not cancelled")
    end
    local first, second = storm:requestJob("mon-portrait-page", tostring(portraitPageIds[1]), "required")
    checkFailed(first, second, portraitPageIds[1], "failed portrait request")
    local duplicates = 0
    for _, jobKey in ipairs(pool.order) do
      if jobKey == portraitKey then
        duplicates = duplicates + 1
      end
    end
    Assert.equal(duplicates, 1, "failed jobs are not silently retried")
  end
  storm:retire()
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
-- Self-driven census: every job is planned and completed through the
-- in-process session against the raw dump, so the suite consumes no
-- prepared scope -- only the imported dump it borrows read-only. The
-- generation session resolves its filesystem through the owned backend
-- installed below, so receipts, milestones, and publications never touch
-- the shared prepared fixture while parallel readers run.
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = {}
suite.metadata.tags = { "producer", "cache", "census" }

-- The session builds its filesystem owner internally instead of accepting
-- one, so the suite routes that single resolution at the owned backend for
-- the duration of the run. Installation precedes the first session require
-- and removal follows the last, keeping later suites on the real owner.
local suiteBeforeAll, suiteAfterAll = suite.beforeAll, suite.afterAll
function suite.beforeAll(context)
  activeBackend = FakeCache.new()
  savedCacheFs = assert(package.loaded["libs.storage.src.CacheFs"], "the cache owner is required")
  local routed = {
    forVersion = function(versionId, backendOverride)
      return savedCacheFs.forVersion(versionId, backendOverride or activeBackend)
    end,
  }
  package.loaded["libs.storage.src.CacheFs"] = routed
  package.loaded["romdump.src.build.InteractiveCacheBuild"] = nil
  if suiteBeforeAll ~= nil then
    suiteBeforeAll(context)
  end
end
function suite.afterAll(context)
  local ok, err = pcall(function()
    if suiteAfterAll ~= nil then
      suiteAfterAll(context)
    end
  end)
  package.loaded["libs.storage.src.CacheFs"] = savedCacheFs
  package.loaded["romdump.src.build.InteractiveCacheBuild"] = nil
  activeBackend = nil
  savedCacheFs = nil
  if not ok then
    error(err, 0)
  end
end
return suite
