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
    "items:global",
    "message-bank:219",
    "audio-summary:global",
    "audio-bank:7",
    "audio-bank:0",
  }) do
    Assert.isTrue(set[name] == true, "bootstrap carries " .. name)
  end
  Assert.equal(#jobs, 17, "bootstrap carries nothing else")
  local itemsCount = 0
  for _, job in ipairs(jobs) do
    if job.kind == "items" and job.key == "global" then
      itemsCount = itemsCount + 1
    end
  end
  Assert.equal(itemsCount, 1, "bootstrap carries exactly one canonical items job")
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
        and kind ~= "bag",
      "bootstrap never pulls geometry, records, scripts, pages, actors, or bag: " .. kind
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
  local coreJobs = ArtifactJobs.fieldCoreJobs(lists)
  local core = jobSet(coreJobs)
  local bootstrap = ArtifactJobs.bootstrapJobs(lists.audioBankIds)
  for _, job in ipairs(bootstrap) do
    Assert.isTrue(core[job.kind .. ":" .. job.key] == true, "core keeps bootstrap work")
  end
  local coreItemsCount = 0
  for _, job in ipairs(coreJobs) do
    if job.kind == "items" and job.key == "global" then
      coreItemsCount = coreItemsCount + 1
    end
  end
  Assert.equal(coreItemsCount, 1, "field core carries exactly one canonical items job")
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
  local deps, complete = ArtifactJobs.dependencies(kind, key, plans or syntheticPlans())
  Assert.isTrue(complete, "the fixed planning table is complete for " .. kind .. ":" .. key)
  for _, dep in ipairs(assert(deps, "complete planning reports its edges")) do
    set[dep.kind .. ":" .. dep.key] = true
  end
  return set
end

function T.dependencies_resolve_through_the_fixed_table()
  Assert.deepEqual(dependencySet("mon-layout", "global"), { ["mon-catalog:global"] = true })
  Assert.deepEqual(dependencySet("mon-icon-page", "3"), { ["source-plan:global"] = true, ["mon-layout:global"] = true })
  Assert.deepEqual(
    dependencySet("mon-portrait-page", "12"),
    { ["source-plan:global"] = true, ["mon-layout:global"] = true }
  )
  local summary = dependencySet("mon-summary", "global")
  for _, name in ipairs({
    "source-plan:global",
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
  Assert.deepEqual(dependencySet("audio-summary", "global"), { ["source-plan:global"] = true, ["audio-bank:7"] = true })
  Assert.deepEqual(
    dependencySet("script-summary", "global"),
    { ["source-plan:global"] = true, ["script-member:149"] = true }
  )
  local map = dependencySet("map", "7")
  for _, name in ipairs({
    "source-plan:global",
    "world-catalog:global",
    "field-cell-index:global",
    "field-cell:12-5",
    "field-cell:12-6",
  }) do
    Assert.isTrue(map[name] == true, "map pulls " .. name)
  end
  Assert.deepEqual(
    dependencySet("field-cell", "12-5"),
    { ["source-plan:global"] = true, ["field-cell-index:global"] = true }
  )
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
  function pool:selectGeneration(selection, epoch)
    self.selected = { identity = selection, epoch = epoch }
  end
  function pool:retireSelection(epoch)
    self.retiredEpoch = epoch
    return true
  end
  function pool:status(jobKey)
    local state = self.states[jobKey]
    if state ~= nil then
      return state
    end
    -- A submitted job with no test-driven reply is still queued: only
    -- never-submitted identities read unknown, matching the production
    -- pool where request and status agree.
    if self.accepted ~= nil and self.accepted[jobKey] then
      return "queued"
    end
    return "unknown"
  end
  function pool:request(job)
    if self.accepted == nil or not self.accepted[job.jobKey] then
      self.submitted[#self.submitted + 1] = job.jobKey
    end
    self.accepted = self.accepted or {}
    self.accepted[job.jobKey] = true
    return self.states[job.jobKey] or "queued", nil
  end
  function pool:retry(jobKey, _)
    self.states[jobKey] = "queued"
    return "queued", nil
  end
  function pool:waitForProgress() end
  function pool:diagnostics()
    return { workerCount = 2, counts = {} }
  end
  return pool
end

local function selectableRecordingPool()
  local pool = recordingPool()
  function pool:selectGeneration(_, _) end
  return pool
end

local function summarySession(pool, cacheFs, bankIds)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function()
    return cacheFs
  end
  local session
  local ok, err = pcall(function()
    session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = SUMMARY_GENERATION, producerId = "d" .. string.rep("3", 64) },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(err, 0)
  end
  session.messageBankIds = bankIds
  session.sourceLoaded = true
  session.pagesKnown = true
  return session
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
  session:update()
  local submitted = submittedSet(pool)
  Assert.isTrue(submitted["message-bank:3"] == true, "a cold bank dispatches")
  Assert.isTrue(submitted["message-bank:5"] == true, "a cold bank dispatches")
  Assert.isNil(submitted["message-summary:global"], "the summary never occupies a worker while its banks are pending")

  pool.states["message-bank:3"] = "ready"
  pool.states["message-bank:5"] = "ready"
  publishMessageBank(cacheFs, 3, "bank-marker-3")
  publishMessageBank(cacheFs, 5, "bank-marker-5")
  session:update()
  session:update()
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
  local cold, coldFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(cold, "a newly registered warm interest answers pending until the pump validates it")
  Assert.isNil(coldFailure, "registration reports no failure")
  session:update()
  local ready, failure = session:requestJob("message-summary", "global", "required")
  for _ = 1, 9 do
    if ready then
      break
    end
    session:update()
    ready, failure = session:requestJob("message-summary", "global", "required")
  end
  Assert.isTrue(ready, "a published summary answers ready once the pump establishes it")
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

local function retryCapablePool()
  local pool = { submitted = {}, states = {}, retried = {}, selects = 0 }
  function pool:selectGeneration(_, _)
    self.selects = self.selects + 1
  end
  function pool:update() end
  function pool:status(jobKey)
    local state = self.states[jobKey]
    if type(state) == "table" then
      return state.state, state.details
    end
    if state ~= nil then
      return state
    end
    -- Request and status agree, matching the production pool: an accepted
    -- submission without a staged reply reads queued, while a
    -- never-submitted identity reads unknown.
    if self.accepted ~= nil and self.accepted[jobKey] then
      return "queued", nil
    end
    return "unknown", nil
  end
  function pool:request(job)
    self.submitted[#self.submitted + 1] = job.jobKey
    self.accepted = self.accepted or {}
    self.accepted[job.jobKey] = true
    return self:status(job.jobKey)
  end
  function pool:retry(jobKey, _)
    self.retried[#self.retried + 1] = jobKey
    self.states[jobKey] = "queued"
    return "queued", nil
  end
  return pool
end

local function isolatedSession(generation, pool, backend)
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  CacheFs.forVersion = function(versionId)
    assert(versionId == "heartgold", "session fixture stays on heartgold")
    return cacheFs
  end
  local session
  local ok, err = pcall(function()
    session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(err, 0)
  end
  return session, cacheFs
end

local function publishWarmBank(cacheFs, generation, bankId)
  local marker = "synthetic-warm-marker-" .. tostring(bankId)
  cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
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

local function submissionCount(pool, jobKey)
  local count = 0
  for _, submitted in ipairs(pool.submitted) do
    if submitted == jobKey then
      count = count + 1
    end
  end
  return count
end

-- The nonblocking surface registers interest and reports retained state:
-- repeated requests, readiness polls and outcome snapshots perform no
-- cache reads and no family validation. A newly registered warm interest
-- answers pending until the update pump validates it; once the pump
-- establishes ready, later polls answer ready without further work.
function T.public_observations_register_without_cache_or_validation_io()
  local backend = FakeCache.new()
  local cacheReads = 0
  local realBackendRead = backend.read
  function backend.read(self, path)
    cacheReads = cacheReads + 1
    return realBackendRead(self, path)
  end
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  local calls = { validate = 0, dependencies = 0, planRead = 0, publishedPlans = 0 }
  local realValidate = ArtifactJobs.validate
  local realDependencies = ArtifactJobs.dependencies
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local realPlanRead = SourcePlan.read
  local realPublishedPlans = ArtifactJobs.publishedPlans
  CacheFs.forVersion = function(versionId)
    assert(versionId == "heartgold", "session fixture stays on heartgold")
    return cacheFs
  end
  ArtifactJobs.validate = function(...)
    calls.validate = calls.validate + 1
    return realValidate(...)
  end
  ArtifactJobs.dependencies = function(...)
    calls.dependencies = calls.dependencies + 1
    return realDependencies(...)
  end
  SourcePlan.read = function(...)
    calls.planRead = calls.planRead + 1
    return realPlanRead(...)
  end
  ArtifactJobs.publishedPlans = function(...)
    calls.publishedPlans = calls.publishedPlans + 1
    return realPublishedPlans(...)
  end
  local ok, failure = pcall(function()
    local generation = "public-no-io-generation"
    local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
    local bankIds = FieldMessageCompiler.requiredBankIds()
    Assert.isTrue(#bankIds > 0, "the warm fixture needs required banks")
    for _, bankId in ipairs(bankIds) do
      local marker = "synthetic-warm-marker-" .. tostring(bankId)
      cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
        schema = ArtifactState.RECEIPT_SCHEMA,
        generationId = generation,
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
    local pool = retryCapablePool()
    local session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
    cacheReads = 0
    calls.validate, calls.dependencies, calls.planRead, calls.publishedPlans = 0, 0, 0, 0
    for _, bankId in ipairs(bankIds) do
      local ready, err = session:requestJob("message-bank", tostring(bankId), "required")
      Assert.isFalse(ready, "a newly registered warm interest answers pending until the pump validates it")
      Assert.isNil(err, "registration reports no failure")
    end
    local milestoneReady, milestoneFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(milestoneReady, "the milestone stays pending until the pump runs")
    Assert.isNil(milestoneFailure, "the milestone reports no failure while pending")
    session:status()
    session:outcomes()
    session:status()
    Assert.equal(cacheReads, 0, "public observations perform no cache reads")
    Assert.equal(calls.validate, 0, "public observations run no family validation")
    Assert.equal(calls.dependencies, 0, "public observations expand no dependencies")
    Assert.equal(calls.planRead, 0, "public observations read no source inventory")
    Assert.equal(calls.publishedPlans, 0, "public observations adopt no published plans")
    Assert.equal(#pool.submitted, 0, "registration submits no worker jobs")
    -- The update pump establishes warm banks within a bounded per-update
    -- budget, so poll until every bank answers ready.
    local established = false
    for _ = 1, 100 do
      session:update()
      established = true
      for _, bankId in ipairs(bankIds) do
        local ready = session:requestJob("message-bank", tostring(bankId), "required")
        if not ready then
          established = false
          break
        end
      end
      if established then
        break
      end
    end
    Assert.isTrue(established, "the pump establishes every warm bank")
    for _, bankId in ipairs(bankIds) do
      local ready, err = session:requestJob("message-bank", tostring(bankId), "required")
      Assert.isTrue(ready, "the pump-established warm answer is immediate")
      Assert.isNil(err, "the established answer reports no failure")
    end
    local settled = {
      validate = calls.validate,
      dependencies = calls.dependencies,
      reads = cacheReads,
    }
    session:status()
    session:outcomes()
    for _, bankId in ipairs(bankIds) do
      session:requestJob("message-bank", tostring(bankId), "required")
    end
    Assert.equal(calls.validate, settled.validate, "retained answers revalidate nothing")
    Assert.equal(calls.dependencies, settled.dependencies, "retained answers re-expand nothing")
    Assert.equal(cacheReads, settled.reads, "retained observations reread nothing")
  end)
  CacheFs.forVersion = realForVersion
  ArtifactJobs.validate = realValidate
  ArtifactJobs.dependencies = realDependencies
  SourcePlan.read = realPlanRead
  ArtifactJobs.publishedPlans = realPublishedPlans
  if not ok then
    error(failure, 0)
  end
end

-- Deferred source and layout work carries real failure edges: a failed
-- source inventory settles audio demand with its causal identity, a failed
-- mon layout settles portrait demand, a milestone reports its failed member
-- instead of pending forever, and an explicit retry repairs only the failed
-- leaf while healthy siblings are never resubmitted.
function T.deferred_prerequisite_failure_reaches_the_waiting_demand()
  local SourcePlan = require("romdump.src.build.SourcePlan")

  -- A failed source inventory settles deferred audio demand with its cause.
  do
    local backend = FakeCache.new()
    local pool = retryCapablePool()
    local session = isolatedSession("deferred-source-generation", pool, backend)
    local ready, failure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(ready, "bootstrap stays pending while the inventory is cold")
    Assert.isNil(failure, "bootstrap reports no failure while the inventory is pending")
    session:update()
    Assert.isTrue(
      submissionCount(pool, "source-plan:global") >= 1,
      "bootstrap demand schedules the source inventory job"
    )
    pool.states["source-plan:global"] = "failed"
    for _ = 1, 3 do
      session:update()
    end
    local audioReady, audioFailure = session:requestJob("audio-summary", "global", "required")
    Assert.isFalse(audioReady, "audio demand never answers ready behind a failed inventory")
    Assert.notNil(audioFailure, "audio demand carries its failed prerequisite")
    Assert.isTrue(
      tostring(audioFailure):find("source-plan:global", 1, true) ~= nil,
      "audio demand names its failed inventory: " .. tostring(audioFailure)
    )
  end

  -- A failed mon layout settles deferred portrait demand with its cause.
  do
    local backend = FakeCache.new()
    local pool = retryCapablePool()
    local session, cacheFs = isolatedSession("deferred-layout-generation", pool, backend)
    local generation = "deferred-layout-generation"
    local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
    local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
    cacheFs:writeLua(SourcePlan.PATH, {
      schema = SourcePlan.SCHEMA,
      versionId = "heartgold",
      romSha1 = string.rep("a", 40),
      generationId = generation,
      producerId = PRODUCER_ID,
      world = { maps = { { id = 7 }, { id = 9 } }, analysis = { excluded = { { id = 3, reason = "placeholder" } } } },
      fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
      scriptPlan = { members = {}, generationKey = "synthetic-generation" },
      audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
      messageBankIds = FieldMessageCompiler.requiredBankIds(),
      mapDataIds = FieldMapDataCompiler.supportedMapIds(),
      mapCellKeys = { [7] = {}, [9] = {} },
    })
    cacheFs:writeLua(ArtifactState.path("source-plan", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = generation,
      kind = "source-plan",
      key = "global",
      marker = SourcePlan.marker(generation),
    })
    local catalogMarker = "synthetic-catalog-marker"
    cacheFs:write(MonCache.catalogMarkerPath(), catalogMarker)
    cacheFs:write(MonCache.catalogPath(), "synthetic-catalog")
    cacheFs:writeLua(ArtifactState.path("mon-catalog", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = generation,
      kind = "mon-catalog",
      key = "global",
      marker = catalogMarker,
    })
    local ready, failure = session:requestJob("mon-portrait-page", "0", "required")
    Assert.isFalse(ready, "the portrait stays pending while its layout is cold")
    Assert.isNil(failure, "the portrait reports no failure while its layout is pending")
    session:update()
    Assert.isTrue(session.sourceLoaded, "the staged inventory is adopted before layout work")
    pool.states["mon-layout:global"] = "failed"
    for _ = 1, 3 do
      session:update()
    end
    local again, againFailure = session:requestJob("mon-portrait-page", "0", "required")
    Assert.isFalse(again, "the portrait never answers ready behind a failed layout")
    Assert.notNil(againFailure, "the portrait carries its failed prerequisite")
    Assert.isTrue(
      tostring(againFailure):find("mon-layout:global", 1, true) ~= nil,
      "the portrait names its failed layout: " .. tostring(againFailure)
    )
  end

  -- A milestone failure wins over a pending sibling, and an explicit retry
  -- repairs only the failed leaf while healthy siblings are never rerun.
  do
    local backend = FakeCache.new()
    local pool = retryCapablePool()
    local generation = "deferred-retry-generation"
    local session, cacheFs = isolatedSession(generation, pool, backend)
    session.messageBankIds = { 3, 5 }
    publishWarmBank(cacheFs, generation, 3)
    local ready, failure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(ready, "the summary stays pending while one bank is cold")
    Assert.isNil(failure, "the summary reports no failure while its banks are pending")
    session:update()
    Assert.equal(submissionCount(pool, "message-bank:5"), 1, "only the cold bank dispatches")
    Assert.equal(submissionCount(pool, "message-bank:3"), 0, "the warm bank never dispatches")
    pool.states["message-bank:5"] = "failed"
    for _ = 1, 2 do
      session:update()
    end
    local blocked, blockedFailure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(blocked, "the summary stays blocked behind its failed bank")
    Assert.isTrue(
      tostring(blockedFailure):find("message-bank:5", 1, true) ~= nil,
      "the summary names its failed bank: " .. tostring(blockedFailure)
    )
    local milestoneReady, milestoneFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(milestoneReady, "the milestone never answers ready while its members are pending")
    Assert.isNil(milestoneFailure, "an unrelated bank failure never poisons the milestone")
    pool.states["message-bank:219"] = "failed"
    for _ = 1, 3 do
      session:update()
    end
    local failedReady, failedFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(failedReady, "the milestone never answers ready behind a failed member")
    Assert.isTrue(
      tostring(failedFailure):find("message-bank:219", 1, true) ~= nil,
      "the milestone failure wins over pending siblings: " .. tostring(failedFailure)
    )
    local retried = session:retry("message-summary", "global", "required")
    Assert.isFalse(retried, "the retry stays pending until the leaf republishes")
    -- The retry records intent; the budgeted admission step performs the
    -- pool operation on the next pump, never inside the public call.
    session:update()
    Assert.deepEqual(pool.retried, { "message-bank:5" }, "exactly the failed leaf retries once")
    Assert.equal(submissionCount(pool, "message-bank:3"), 0, "retry never rebuilds the healthy sibling")
    publishWarmBank(cacheFs, generation, 5)
    pool.states["message-bank:5"] = "ready"
    for _ = 1, 2 do
      session:update()
    end
    Assert.equal(submissionCount(pool, "message-summary:global"), 1, "the parent dispatches once its bank heals")
    local repaired, repairedFailure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(repaired, "the unpublished parent stays pending after its banks heal")
    Assert.isNil(repairedFailure, "the healing parent reports no failure")
  end
end

-- Warm parents wake their dependents without resubmission: published banks
-- answer through reuse, and the summary dispatches exactly once while its
-- healthy prerequisites never occupy a worker.
function T.reused_prerequisites_wake_their_parent_without_resubmission()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local generation = "reuse-wake-generation"
  local session, cacheFs = isolatedSession(generation, pool, backend)
  session.messageBankIds = { 3, 5 }
  publishWarmBank(cacheFs, generation, 3)
  publishWarmBank(cacheFs, generation, 5)
  for _ = 1, 2 do
    session:update()
  end
  local summaryReady, summaryFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(summaryReady, "the unpublished summary stays pending while its banks are reused")
  Assert.isNil(summaryFailure, "reused prerequisites report no failure")
  for _ = 1, 2 do
    session:update()
  end
  Assert.equal(submissionCount(pool, "message-bank:3"), 0, "a reused bank never occupies a worker")
  Assert.equal(submissionCount(pool, "message-bank:5"), 0, "a reused bank never occupies a worker")
  Assert.equal(submissionCount(pool, "message-summary:global"), 1, "the woken parent dispatches exactly once")
end

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
  local session = withHost(host, function()
    local realForVersion = CacheFs.forVersion
    CacheFs.forVersion = function()
      return cacheFs
    end
    local ok, created = pcall(InteractiveCacheBuild.new, {
      identity = { versionId = "heartgold", generationId = options.generation, producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
    CacheFs.forVersion = realForVersion
    assert(ok, created)
    return created
  end)
  -- The fixture models a post-adoption session: source inventory and page
  -- membership read ready without worker work, so page and summary
  -- prerequisites proceed.
  session.messageBankIds = options.bankIds
  session.iconPageIds = options.iconPageIds or {}
  session.sourceLoaded = true
  session.pagesKnown = true
  local sourcePlanEntry = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "sweep",
    priority = 100,
    submitted = false,
    ready = true,
    validated = true,
    validationPending = false,
    failure = nil,
    failureClass = nil,
    causeJobKey = nil,
    poolState = nil,
    phase = "ready",
    await = nil,
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
    propagateIndex = nil,
    retryPending = false,
  }
  session.byKey["source-plan:global"] = sourcePlanEntry
  session.interest[#session.interest + 1] = sourcePlanEntry
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
  requestJob(env, "message-bank", "3", "required")
  pumpSession(env, 2)
  local bankReady, bankFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isTrue(bankReady, "a published bank answers ready once the pump establishes it")
  Assert.isNil(bankFailure, "a published bank reports no failure")
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "a warm bank is never submitted")
  publishSummaryLive(env, { 3, 5 }, { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" })
  requestJob(env, "message-summary", "global", "required")
  pumpSession(env, 2)
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
  Assert.equal(env.session:status().failed, 0, "retry clears the leaf and parent failure annotations")
  -- The retry records intent; the budgeted admission step performs the
  -- pool operation on the next pump, which dispatches exactly one new
  -- attempt for the failed leaf while the healthy sibling stays idle.
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:5", "message-bank:5" },
    "the retry creates exactly one new leaf attempt"
  )
  local retriedStatus = poolStatus(env, "message-bank", "5")
  Assert.isTrue(
    retriedStatus == "queued" or retriedStatus == "running",
    "only the failed leaf retries: " .. tostring(retriedStatus)
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
      return { { kind = "message-summary", key = "global" } }, true
    end
    return originalDependencies(kind, key, plans)
  end
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local session = summarySession(pool, cacheFs, { 3, 5 })
  local callOk, ready, failure = pcall(session.requestJob, session, "message-summary", "global", "required")
  Assert.isTrue(callOk, "registration answers instead of overflowing: " .. tostring(ready))
  Assert.isFalse(ready, "a cyclic plan stays pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  session:update()
  local again, againFailure = session:requestJob("message-summary", "global", "required")
  ArtifactJobs.dependencies = originalDependencies
  Assert.isFalse(again, "a cyclic plan never answers ready")
  Assert.isTrue(
    tostring(againFailure):find("cycle", 1, true) ~= nil,
    "the cyclic plan names its cycle: " .. tostring(againFailure)
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
  Assert.isTrue(requestOk, "registration never touches the pool: " .. tostring(requestError))
  local pumpOk, pumpError = pcall(function()
    withHost(env.host, function()
      return env.session:update()
    end)
  end)
  Assert.isFalse(pumpOk, "demand from a stale epoch never dispatches")
  Assert.isTrue(
    tostring(pumpError):find("epoch", 1, true) ~= nil,
    "the stale demand names its epoch: " .. tostring(pumpError)
  )
  shutdownEnv(env)
end

-- Scope-relative completion from the bootstrap side: a bootstrap demand
-- never enrolls icon/portrait pages or geometry, and it can succeed from
-- its own roster while page membership stays unknown. It is still not
-- exhaustive completion.
function T.bootstrap_finishes_without_pages_or_geometry()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = isolatedSession("bootstrap-scope-generation", pool, backend)
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "bootstrap stays pending until its own members are ready")
  Assert.isNil(failure, "bootstrap reports no failure while pending")
  -- Enrollment is update-owned: admit the roster before staging readiness
  -- through the backdoor. The scope assertions below are unchanged.
  session:update()
  for _, entry in pairs(session.byKey) do
    if type(entry) == "table" and entry.failure == nil then
      entry.ready = true
    end
  end
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(again, "bootstrap succeeds from its own scope without page membership")
  Assert.isNil(againFailure, "bootstrap reports no failure on success")
  for jobKey in pairs(session.byKey) do
    local kind = jobKey:match("^([^:]+):")
    Assert.isTrue(kind ~= "mon-icon-page", "bootstrap enrolls no icon page: " .. jobKey)
    Assert.isTrue(kind ~= "mon-portrait-page", "bootstrap enrolls no portrait page: " .. jobKey)
    Assert.isTrue(kind ~= "field-cell", "bootstrap enrolls no geometry: " .. jobKey)
    Assert.isTrue(kind ~= "map", "bootstrap enrolls no field records: " .. jobKey)
  end
  Assert.isFalse(session:status().complete, "a targeted bootstrap is never exhaustive completion")
end

-- Promotion reaches already traversed prerequisites: a near summary whose
-- dependency cursor is incomplete upgrades every prerequisite to required
-- without duplicate dispatch or lost physical ownership.
-- A first milestone demand reconciles stronger urgency for members the
-- session already tracks: present weaker leaves strengthen in place while
-- unchanged polls register nothing.
function T.first_milestone_demand_promotes_existing_members()
  local env = openLiveSession({ generation = "milestone-promotion-generation", bankIds = { 3, 5 } })
  requestJob(env, "actors", "global", "sweep")
  requestJob(env, "bag", "global", "sweep")
  pumpSession(env, 2)
  Assert.equal(dispatchCount(env, "actors", "global"), 1, "the coarse leaf dispatches once")
  Assert.equal(poolStatus(env, "bag", "global"), "queued", "the second leaf waits its turn")
  local before = #env.host.dispatched
  local first, second = withHost(env.host, function()
    return env.session:requestMilestone("field-core", "required")
  end)
  Assert.isFalse(first, "field core stays pending while cold")
  Assert.isNil(second, "field core reports no failure while cold")
  pumpSession(env, 5)
  local actors = env.session.byKey["actors:global"]
  local bag = env.session.byKey["bag:global"]
  Assert.notNil(actors, "the existing member keeps its retained entry")
  Assert.notNil(bag, "the existing member keeps its retained entry")
  Assert.equal(actors.urgency, "required", "the existing member strengthens to the milestone urgency")
  Assert.equal(bag.urgency, "required", "the existing member strengthens to the milestone urgency")
  Assert.equal(dispatchCount(env, "actors", "global"), 1, "promotion never resubmits")
  Assert.equal(poolStatus(env, "bag", "global"), "queued", "the second leaf still waits its turn")
  local calls = #env.host.dispatched
  withHost(env.host, function()
    local again, againFailure = env.session:requestMilestone("field-core", "required")
    Assert.isFalse(again, "an unchanged poll stays pending")
    Assert.isNil(againFailure, "an unchanged poll reports no failure")
  end)
  pumpSession(env, 2)
  Assert.equal(#env.host.dispatched, calls, "an unchanged poll enrolls nothing new")
  Assert.isTrue(calls >= before, "dispatch accounting stays monotone")
  shutdownEnv(env)
end

-- A sweep-urgency retry passes through sweep admission like any other
-- waiter: it joins behind older capacity waiters instead of requeueing
-- ahead of them.
function T.sweep_retry_waits_behind_older_capacity_waiters()
  local env = openLiveSession({ generation = "retry-admission-generation", bankIds = { 3, 5, 7 } })
  requestJob(env, "message-bank", "3", "sweep")
  requestJob(env, "message-bank", "5", "sweep")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "3"), "running", "the first sweep job executes")
  Assert.equal(poolStatus(env, "message-bank", "5"), "queued", "the second sweep job waits its turn")
  requestJob(env, "message-bank", "7", "sweep")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "7"), "unknown", "a full frontier parks the waiter")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "failed")
  pumpSession(env, 2)
  local failed, failedFailure = requestJob(env, "message-bank", "3", "sweep")
  Assert.isFalse(failed, "the failed job answers false")
  Assert.notNil(failedFailure, "the failed job names its error")
  local retryCalls = 0
  local realRetry = env.pool.retry
  env.pool.retry = function(self, jobKey, priority)
    retryCalls = retryCalls + 1
    return realRetry(self, jobKey, priority)
  end
  local retried = withHost(env.host, function()
    return env.session:retry("message-bank", "3", "sweep")
  end)
  Assert.isTrue(retried == true or retried == false, "the retry registers")
  Assert.equal(retryCalls, 0, "a sweep retry waits behind older capacity waiters")
  Assert.equal(poolStatus(env, "message-bank", "7"), "queued", "the older waiter holds the freed credit")
  publishBankLive(env, 5, "synthetic:romshape:005")
  stageBankReply(env, 5, "synthetic:romshape:005", dispatchedStage(env, 1, "message-bank:5", 1))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the release publishes")
  Assert.equal(dispatchCount(env, "message-bank", "7"), 1, "the older waiter dispatches exactly once")
  Assert.equal(retryCalls, 1, "the release credit admits the retried waiter next")
  publishBankLive(env, 7, "synthetic:romshape:007")
  stageBankReply(env, 7, "synthetic:romshape:007", dispatchedStage(env, 1, "message-bank:7", 1))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "7"), "ready", "the older waiter publishes")
  Assert.equal(retryCalls, 1, "the next freed credit admits the retried waiter")
  publishBankLive(env, 3, "synthetic:romshape:003")
  stageBankReply(env, 3, "synthetic:romshape:003", dispatchedStage(env, 1, "message-bank:3", 2))
  pumpSession(env, 3)
  local repaired, repairedFailure = requestJob(env, "message-bank", "3", "sweep")
  Assert.isTrue(repaired, "the retried leaf succeeds: " .. tostring(repairedFailure))
  env.pool.retry = realRetry
  shutdownEnv(env)
end

function T.promotion_revisits_already_queued_prerequisites()
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local bankIds = {}
  for bankId = 3, 42 do
    bankIds[#bankIds + 1] = bankId
  end
  local session = summarySession(pool, cacheFs, bankIds)
  local ready, failure = session:requestJob("message-summary", "global", "near")
  Assert.isFalse(ready, "the summary stays pending while its banks are cold")
  Assert.isNil(failure, "no failure is reported while the summary waits")
  session:update()
  local firstSubmitted = submittedSet(pool)
  local visited, unvisited = 0, 0
  for _, bankId in ipairs(bankIds) do
    if firstSubmitted["message-bank:" .. tostring(bankId)] then
      visited = visited + 1
    else
      unvisited = unvisited + 1
    end
  end
  Assert.isTrue(visited > 0, "the first pass visits some prerequisites")
  Assert.isTrue(unvisited > 0, "the first pass leaves the cursor incomplete")
  local promoted, promotedFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(promoted, "the promoted summary stays pending while its banks are cold")
  Assert.isNil(promotedFailure, "promotion reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local counts = {}
  for _, jobKey in ipairs(pool.submitted) do
    counts[jobKey] = (counts[jobKey] or 0) + 1
  end
  for _, bankId in ipairs(bankIds) do
    local jobKey = "message-bank:" .. tostring(bankId)
    Assert.equal(counts[jobKey], 1, "promotion keeps one job under its identity: " .. jobKey)
    local entry = session.byKey[jobKey]
    Assert.notNil(entry, "the promoted prerequisite keeps its retained entry: " .. jobKey)
    Assert.equal(entry.urgency, "required", "every prerequisite inherits the stronger urgency: " .. jobKey)
  end
end

-- Transition-driven planning: once a scope settles, unchanged updates and
-- repeated polls perform no membership reconstruction, enrollment,
-- readiness reads, or worker submissions. Retained answers stay observable
-- through status and outcomes while the pump alone advances new transitions.
local function smallInventoryPlan(generation, scriptIds)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local members = {}
  for _, memberId in ipairs(scriptIds) do
    members[#members + 1] = { memberId = memberId }
  end
  return {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = generation,
    producerId = "d" .. string.rep("3", 64),
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = members, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapCellKeys = { [7] = {}, [9] = {} },
  }
end

local function stageInventoryRecord(cacheFs, generation, scriptIds)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  cacheFs:writeLua(SourcePlan.PATH, smallInventoryPlan(generation, scriptIds))
  cacheFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
end

local function countWork(counts, backend)
  local realBootstrapJobs = ArtifactJobs.bootstrapJobs
  local realFieldCoreJobs = ArtifactJobs.fieldCoreJobs
  ArtifactJobs.bootstrapJobs = function(...)
    counts.bootstrap = counts.bootstrap + 1
    return realBootstrapJobs(...)
  end
  ArtifactJobs.fieldCoreJobs = function(...)
    counts.core = counts.core + 1
    return realFieldCoreJobs(...)
  end
  local realBackendRead = backend.read
  function backend.read(self, path)
    counts.backendRead = counts.backendRead + 1
    return realBackendRead(self, path)
  end
  local realBackendWrite = backend.write
  function backend.write(self, path, data)
    counts.backendWrite = counts.backendWrite + 1
    return realBackendWrite(self, path, data)
  end
  return {
    bootstrapJobs = realBootstrapJobs,
    fieldCoreJobs = realFieldCoreJobs,
  }
end

function T.settled_updates_reuse_retained_membership_without_new_work()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local generation = "idle-membership-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageInventoryRecord(cacheFs, generation, {})
  for _, member in ipairs(ArtifactJobs.bootstrapJobs({})) do
    cacheFs:writeLua(ArtifactState.path(member.kind, member.key), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = generation,
      kind = member.kind,
      key = member.key,
      marker = "idle-marker-" .. member.kind .. "-" .. member.key,
    })
  end
  local counts = { bootstrap = 0, core = 0, backendRead = 0, backendWrite = 0 }
  local originals = countWork(counts, backend)
  local realValidate = ArtifactJobs.validate
  local realPlanRead = SourcePlan.read
  local realPublishedPlans = ArtifactJobs.publishedPlans
  local planReads, publishedReads = 0, 0
  SourcePlan.read = function(...)
    planReads = planReads + 1
    return realPlanRead(...)
  end
  ArtifactJobs.publishedPlans = function(...)
    publishedReads = publishedReads + 1
    return realPublishedPlans(...)
  end
  -- Every family except the adopted inventory answers from its staged
  -- record, so the pump can settle the scope without worker execution.
  ArtifactJobs.validate = function(first, second, kind, ...)
    if kind ~= "source-plan" then
      return true
    end
    return realValidate(first, second, kind, ...)
  end
  local ok, failure = pcall(function()
    CacheFs.forVersion = function(versionId)
      assert(versionId == "heartgold", "session fixture stays on heartgold")
      return cacheFs
    end
    local pool = selectableRecordingPool()
    local session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = generation, producerId = "d" .. string.rep("3", 64) },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
    local cold, coldFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(cold, "bootstrap stays pending until the pump validates its roster")
    Assert.isNil(coldFailure, "bootstrap reports no failure while pending")
    local settled = false
    for _ = 1, 40 do
      session:update()
      if session:status().settled then
        settled = true
        break
      end
    end
    Assert.isTrue(settled, "the stub-validated bootstrap settles with an idle pool")
    Assert.equal(#pool.submitted, 0, "validation success never occupies a worker")
    local before = {
      bootstrap = counts.bootstrap,
      core = counts.core,
      planReads = planReads,
      publishedReads = publishedReads,
      backendRead = counts.backendRead,
      backendWrite = counts.backendWrite,
      submitted = #pool.submitted,
      status = session:status(),
    }
    Assert.isTrue(before.status.settled, "the snapshot observes the settled scope")
    for _ = 1, 5 do
      session:update()
    end
    session:outcomes()
    Assert.equal(counts.bootstrap, before.bootstrap, "idle updates rebuild no bootstrap roster")
    Assert.equal(counts.core, before.core, "idle updates rebuild no field-core roster")
    Assert.equal(planReads, before.planReads, "idle updates reread no source inventory")
    Assert.equal(publishedReads, before.publishedReads, "idle updates readopt no published plans")
    Assert.equal(counts.backendRead, before.backendRead, "idle updates perform no readiness reads")
    Assert.equal(counts.backendWrite, before.backendWrite, "idle updates rewrite no milestone record")
    Assert.equal(#pool.submitted, before.submitted, "idle updates submit no worker jobs")
    local after = session:status()
    Assert.equal(after.settled, before.status.settled, "settlement survives idle updates")
    Assert.equal(after.bootstrap, before.status.bootstrap, "the retained bootstrap answer is stable")
    Assert.equal(after.ready, before.status.ready, "the retained ready count is stable")
    Assert.equal(after.failed, before.status.failed, "the retained failure count is stable")
  end)
  CacheFs.forVersion = realForVersion
  ArtifactJobs.bootstrapJobs = originals.bootstrapJobs
  ArtifactJobs.fieldCoreJobs = originals.fieldCoreJobs
  ArtifactJobs.validate = realValidate
  SourcePlan.read = realPlanRead
  ArtifactJobs.publishedPlans = realPublishedPlans
  if not ok then
    error(failure, 0)
  end
end

function T.repeated_scope_polls_observe_retained_answers_without_new_work()
  local generation = "observational-poll-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  local counts = { bootstrap = 0, core = 0, backendRead = 0, backendWrite = 0 }
  local originals = countWork(counts, backend)
  local realValidate = ArtifactJobs.validate
  local validates = 0
  ArtifactJobs.validate = function(...)
    validates = validates + 1
    return realValidate(...)
  end
  local ok, failure = pcall(function()
    CacheFs.forVersion = function(versionId)
      assert(versionId == "heartgold", "session fixture stays on heartgold")
      return cacheFs
    end
    local pool = selectableRecordingPool()
    local session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = generation, producerId = "d" .. string.rep("3", 64) },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
    local cold, coldFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(cold, "the first request registers pending demand")
    Assert.isNil(coldFailure, "registration reports no failure")
    local before = {
      bootstrap = counts.bootstrap,
      core = counts.core,
      validates = validates,
      backendRead = counts.backendRead,
      backendWrite = counts.backendWrite,
      submitted = #pool.submitted,
    }
    for _ = 1, 4 do
      local pending, pendingFailure = session:requestMilestone("bootstrap", "required")
      Assert.isFalse(pending, "a repeated required poll still answers pending")
      Assert.isNil(pendingFailure, "a repeated required poll reports no failure")
      local lower, lowerFailure = session:requestMilestone("bootstrap", "near")
      Assert.isFalse(lower, "a lower-urgency poll still answers pending")
      Assert.isNil(lowerFailure, "a lower-urgency poll reports no failure")
    end
    session:status()
    session:outcomes()
    Assert.equal(counts.bootstrap, before.bootstrap, "polls rebuild no bootstrap roster")
    Assert.equal(counts.core, before.core, "polls rebuild no field-core roster")
    Assert.equal(validates, before.validates, "polls run no family validation")
    Assert.equal(counts.backendRead, before.backendRead, "polls perform no cache reads")
    Assert.equal(counts.backendWrite, before.backendWrite, "polls publish no milestone record")
    Assert.equal(#pool.submitted, before.submitted, "polls submit no worker jobs")
    -- Enrollment is update-owned: admit the roster first so the backdoor
    -- covers enrolled members, then establish through the pump. The poll
    -- contract below is unchanged.
    session:update()
    for _, entry in pairs(session.byKey) do
      if type(entry) == "table" and entry.failure == nil then
        entry.ready = true
      end
    end
    session:update()
    local established, establishedFailure = session:requestMilestone("bootstrap", "required")
    Assert.isTrue(established, "the pump-established scope answers ready")
    Assert.isNil(establishedFailure, "the established scope reports no failure")
    local settledCounts = {
      bootstrap = counts.bootstrap,
      core = counts.core,
      validates = validates,
      backendRead = counts.backendRead,
      backendWrite = counts.backendWrite,
      submitted = #pool.submitted,
    }
    for _ = 1, 2 do
      local again, againFailure = session:requestMilestone("bootstrap", "required")
      Assert.isTrue(again, "a repeated poll of the ready scope still answers ready")
      Assert.isNil(againFailure, "a repeated poll of the ready scope reports no failure")
    end
    Assert.equal(counts.bootstrap, settledCounts.bootstrap, "ready polls rebuild no bootstrap roster")
    Assert.equal(counts.core, settledCounts.core, "ready polls rebuild no field-core roster")
    Assert.equal(validates, settledCounts.validates, "ready polls run no family validation")
    Assert.equal(counts.backendRead, settledCounts.backendRead, "ready polls perform no cache reads")
    Assert.equal(counts.backendWrite, settledCounts.backendWrite, "ready polls publish no milestone record")
    Assert.equal(#pool.submitted, settledCounts.submitted, "ready polls submit no worker jobs")
  end)
  CacheFs.forVersion = realForVersion
  ArtifactJobs.bootstrapJobs = originals.bootstrapJobs
  ArtifactJobs.fieldCoreJobs = originals.fieldCoreJobs
  ArtifactJobs.validate = realValidate
  if not ok then
    error(failure, 0)
  end
end

function T.required_promotion_reaches_paused_near_enrollment()
  local generation = "paused-promotion-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  local scriptIds = {}
  for memberId = 1, 40 do
    scriptIds[#scriptIds + 1] = memberId
  end
  local planIds = {}
  for memberId = 1, 41 do
    planIds[#planIds + 1] = memberId
  end
  stageInventoryRecord(cacheFs, generation, planIds)
  local ok, failure = pcall(function()
    CacheFs.forVersion = function(versionId)
      assert(versionId == "heartgold", "session fixture stays on heartgold")
      return cacheFs
    end
    local pool = { submitted = {}, requests = {}, states = {} }
    function pool:selectGeneration(_, _) end
    function pool:update() end
    function pool:status(jobKey)
      if self.states[jobKey] ~= nil then
        return self.states[jobKey]
      end
      for _, submitted in ipairs(self.submitted) do
        if submitted == jobKey then
          return "queued"
        end
      end
      return "unknown"
    end
    function pool:request(job)
      self.requests[#self.requests + 1] = { jobKey = job.jobKey, priority = job.priority }
      self.submitted[#self.submitted + 1] = job.jobKey
      return self.states[job.jobKey] or "queued", nil
    end
    local session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = generation, producerId = "d" .. string.rep("3", 64) },
      epoch = 1,
      pool = pool,
      sweepEnabled = false,
    })
    for _, memberId in ipairs(scriptIds) do
      session:requestJob("script-member", tostring(memberId), "near")
    end
    -- Children wait for the inventory entry to become ready, so the first
    -- passes register and validate while later bounded passes submit: keep
    -- pumping until some members are queued while others still wait.
    local submitted, unsubmitted = 0, 0
    for _ = 1, 8 do
      session:update()
      submitted, unsubmitted = 0, 0
      for _, memberId in ipairs(scriptIds) do
        local entry = session.byKey["script-member:" .. tostring(memberId)]
        Assert.notNil(entry, "near demand registers every member")
        if entry.submitted then
          submitted = submitted + 1
        elseif entry.failure == nil and not entry.ready then
          unsubmitted = unsubmitted + 1
        end
      end
      if submitted > 0 and unsubmitted > 0 then
        break
      end
    end
    Assert.isTrue(submitted > 0, "bounded passes queue some near work")
    Assert.isTrue(unsubmitted > 0, "bounded passes leave near work paused")
    for _, memberId in ipairs(scriptIds) do
      local entry = session.byKey["script-member:" .. tostring(memberId)]
      Assert.equal(entry.urgency, "near", "paused demand keeps its near urgency")
    end
    for _, memberId in ipairs(scriptIds) do
      session:requestJob("script-member", tostring(memberId), "required")
    end
    local sweepReady, sweepFailure = session:requestJob("script-member", "41", "sweep")
    Assert.isFalse(sweepReady, "the sweep member stays pending behind required demand")
    Assert.isNil(sweepFailure, "the sweep member reports no failure")
    for _ = 1, 6 do
      session:update()
    end
    for _, memberId in ipairs(scriptIds) do
      local entry = session.byKey["script-member:" .. tostring(memberId)]
      Assert.equal(entry.urgency, "required", "promotion upgrades every paused member")
    end
    local latestPriority, firstRequiredAt, firstSweepAt = {}, {}, nil
    for index, request in ipairs(pool.requests) do
      latestPriority[request.jobKey] = request.priority
      if request.priority == 0 and firstRequiredAt[request.jobKey] == nil then
        firstRequiredAt[request.jobKey] = index
      end
      if request.jobKey == "script-member:41" and firstSweepAt == nil then
        firstSweepAt = index
      end
    end
    for _, memberId in ipairs(scriptIds) do
      local jobKey = "script-member:" .. tostring(memberId)
      Assert.equal(latestPriority[jobKey], 0, "every promoted member last requested at required priority: " .. jobKey)
      Assert.notNil(firstRequiredAt[jobKey], "every promoted member requested at required priority: " .. jobKey)
    end
    Assert.notNil(firstSweepAt, "the sweep member eventually requests at its lower priority")
    local sweepEntry = session.byKey["script-member:41"]
    Assert.notNil(sweepEntry, "the sweep member keeps its retained entry")
    Assert.equal(sweepEntry.urgency, "sweep", "sweep demand never inherits the required urgency")
    Assert.equal(sweepEntry.priority, 100, "sweep demand keeps its lower priority")
    local seen = {}
    for jobKey in pairs(session.byKey) do
      Assert.isNil(seen[jobKey], "promotion keeps one retained job per identity: " .. tostring(jobKey))
      seen[jobKey] = true
    end
    Assert.isFalse(session:status().settled, "queued demand never settles around waiting workers")
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(failure, 0)
  end
end

return { metadata = { capabilities = {} }, tests = T }
