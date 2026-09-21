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

function T.urgency_maps_to_three_fixed_pool_priorities()
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
    ["audio-catalog"] = "heavy",
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
  Assert.deepEqual(dependencySet("audio-summary", "global"), {
    ["source-plan:global"] = true,
    ["audio-catalog:global"] = true,
    ["audio-bank:7"] = true,
  })
  Assert.deepEqual(dependencySet("audio-catalog", "global"), { ["source-plan:global"] = true })
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

-- A published summary succeeds through pool readiness with no
-- controller-side family validation: the session admits warm demand to
-- the pool, and each ready reply is worker proof of reuse.
function T.warm_summary_succeeds_through_pool_readiness()
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
  local realValidate = ArtifactJobs.validate
  local validations = 0
  ArtifactJobs.validate = function(...)
    validations = validations + 1
    return realValidate(...)
  end
  local ok, failure = pcall(function()
    local session = summarySession(pool, cacheFs, { 3, 5 })
    local cold, coldFailure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(cold, "a newly registered warm interest answers pending until the pump admits it")
    Assert.isNil(coldFailure, "registration reports no failure")
    session:update()
    pool.states["message-bank:3"] = "ready"
    pool.states["message-bank:5"] = "ready"
    session:update()
    session:update()
    Assert.isTrue(
      submittedSet(pool)["message-summary:global"] == true,
      "the proven banks wake their parent into the pool"
    )
    pool.states["message-summary:global"] = "ready"
    local ready, readyFailure = session:requestJob("message-summary", "global", "required")
    for _ = 1, 9 do
      if ready then
        break
      end
      session:update()
      ready, readyFailure = session:requestJob("message-summary", "global", "required")
    end
    Assert.isTrue(ready, "a published summary answers ready once the pool proves it")
    Assert.isNil(readyFailure, "a published summary reports no failure")
    Assert.equal(validations, 0, "pool-proven output runs no controller validation")
  end)
  ArtifactJobs.validate = realValidate
  if not ok then
    error(failure, 0)
  end
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
  function pool:retireSelection(epoch)
    self.retiredEpoch = epoch
    return true
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

-- Construction performs no pool census: replacing diagnostics with a
-- raising stub cannot disturb demand enrollment, submission, or
-- settlement, because no scheduler path consults pool diagnostics.
function T.construction_performs_no_pool_census()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session, _ = isolatedSession("no-census-generation", pool, backend)
  pool.diagnostics = function()
    error("scheduler census must not run on the game thread")
  end
  pool.states["field-font:global"] = "ready"
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "demand stays pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(again, "demand settles without pool census")
  Assert.isNil(againFailure, "settlement reports no failure")
end

-- Explicit complete enrollment advances a bounded chunk per update
-- without materializing the complete corpus: with the materialized
-- inventory patched to raise, one update visits only a small prefix,
-- while many updates still cover exactly the canonical union.
function T.complete_enrollment_advances_bounded_chunks_without_materializing_the_corpus()
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local matrices = {}
  for matrixMemberId = 1, 3 do
    local cells = {}
    for index = 0, 199 do
      cells[#cells + 1] = {
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
    matrices[#matrices + 1] = { matrixMemberId = matrixMemberId, cells = cells }
  end
  local messageBankIds = FieldMessageCompiler.requiredBankIds()
  local mapDataIds = FieldMapDataCompiler.supportedMapIds()
  local mapIds = {}
  local mapCellKeys = {}
  for mapId = 1, 10 do
    mapIds[#mapIds + 1] = mapId
    mapCellKeys[mapId] = { "1-0", "2-0" }
  end
  local plans = {
    indexBundle = { index = { matrices = matrices }, indexMarker = "incremental-index-marker" },
    scriptPlan = { members = { { memberId = 149 }, { memberId = 150 } }, generationKey = "inc-script-generation" },
    audioPlan = { index = {}, bankPlans = { { bankId = 7 }, { bankId = 8 } } },
    messageBankIds = messageBankIds,
    audioBankIds = { 7, 8 },
    scriptMemberIds = { 149, 150 },
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = mapDataIds,
    mapIds = mapIds,
    mapCellKeys = mapCellKeys,
    world = { maps = {} },
  }
  local expected = ArtifactJobs.completeJobs(plans)
  Assert.isTrue(#expected > 600, "the loaded fixture spans hundreds of jobs")
  local backend = FakeCache.new()
  local pool = recordingPool()
  pool.diagnostics = nil
  local session, _ = isolatedSession("incremental-complete-generation", pool, backend)
  session.adopted = plans
  session.sourceLoaded = true
  session.pagesKnown = true
  local requested, requestFailure = session:requestComplete("required")
  Assert.isFalse(requested, "the complete build stays pending until the pump runs")
  Assert.isNil(requestFailure, "registration reports no failure")
  local realCompleteJobs = ArtifactJobs.completeJobs
  ArtifactJobs.completeJobs = function()
    error("explicit complete enrollment must not materialize the complete corpus")
  end
  local ok, failure = pcall(function()
    session:update()
    local firstPass = session:outcomes()
    Assert.isTrue(#firstPass < 40, "one update visits only a bounded chunk, not the corpus: " .. tostring(#firstPass))
    -- Enrollment shares the bounded planning slice with every enrolled
    -- entry, so later updates enroll less per turn; iterate to quiescence
    -- (no growth across sustained pumping) rather than a fixed turn
    -- count, which a loaded machine can outlast without product change.
    local lastCount, stagnant = 0, 0
    for _ = 1, 20000 do
      if #session:outcomes() >= #expected then
        break
      end
      session:update()
      if #session:outcomes() == lastCount then
        stagnant = stagnant + 1
        if stagnant >= 500 then
          break
        end
      else
        lastCount, stagnant = #session:outcomes(), 0
      end
    end
    local outcomes = session:outcomes()
    Assert.equal(#outcomes, #expected, "complete enrollment covers the canonical union")
    local seen = {}
    for _, outcome in ipairs(outcomes) do
      seen[outcome.jobKey] = true
    end
    for _, job in ipairs(expected) do
      Assert.isTrue(seen[job.jobKey] == true, "complete enrollment covers " .. job.jobKey)
    end
  end)
  ArtifactJobs.completeJobs = realCompleteJobs
  if not ok then
    error(failure, 0)
  end
end

-- A ready pool reply is worker proof, not a request for controller
-- validation: the entry succeeds with zero family-validator calls on
-- the session thread.
function T.ready_pool_results_succeed_without_controller_revalidation()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("ready-without-revalidation", pool, backend)
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function()
    error("controller must not deep-validate fresh pool output")
  end
  local ok, failure = pcall(function()
    local ready, requestFailure = session:requestJob("message-bank", "219", "required")
    Assert.isFalse(ready, "the undispatched bank answers pending")
    Assert.isNil(requestFailure, "registration reports no failure")
    session:update()
    Assert.equal(submissionCount(pool, "message-bank:219"), 1, "the cold bank dispatches once")
    pool.states["message-bank:219"] = "ready"
    session:update()
    local established, establishedFailure = session:requestJob("message-bank", "219", "required")
    Assert.isTrue(established, "the pool-proven bank answers ready")
    Assert.isNil(establishedFailure, "the proven bank reports no failure")
  end)
  ArtifactJobs.validate = realValidate
  if not ok then
    error(failure, 0)
  end
end

-- The nonblocking surface registers interest and reports retained state:
-- repeated requests, readiness polls and outcome snapshots perform no
-- cache reads and no family validation. A newly registered warm interest
-- answers pending until the update pump admits it; once staged pool
-- replies prove ready, later polls answer ready without further work.
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
    -- The update pump admits warm banks to the pool within a bounded
    -- per-update budget; staged ready replies stand in for worker reuse
    -- proof, so poll until every bank answers ready.
    for _, bankId in ipairs(bankIds) do
      pool.states["message-bank:" .. tostring(bankId)] = "ready"
    end
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
    local ready, failure = session:requestMilestone("new-game-intro", "required")
    Assert.isFalse(ready, "the intro stays pending while the inventory is cold")
    Assert.isNil(failure, "the intro reports no failure while the inventory is pending")
    session:update()
    Assert.isTrue(submissionCount(pool, "source-plan:global") >= 1, "intro demand schedules the source inventory job")
    local waitingReady, waitingFailure = session:requestJob("audio-summary", "global", "required")
    Assert.isFalse(waitingReady, "audio demand waits while the inventory is cold")
    Assert.isNil(waitingFailure, "audio demand reports no failure while the inventory is pending")
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
      audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
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
    pool.states["source-plan:global"] = "ready"
    pool.states["mon-catalog:global"] = "ready"
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
    Assert.equal(submissionCount(pool, "message-bank:5"), 1, "only the cold bank dispatches past its warm sibling")
    Assert.equal(submissionCount(pool, "message-bank:3"), 1, "the warm bank is admitted once for worker proof")
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
    pool.states["field-font:global"] = "failed"
    for _ = 1, 3 do
      session:update()
    end
    local failedReady, failedFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(failedReady, "the milestone never answers ready behind a failed member")
    Assert.isTrue(
      tostring(failedFailure):find("field-font:global", 1, true) ~= nil,
      "the milestone failure wins over pending siblings: " .. tostring(failedFailure)
    )
    local retried = session:retry("message-summary", "global", "required")
    Assert.isFalse(retried, "the retry stays pending until the leaf republishes")
    -- The retry records intent; the budgeted admission step performs the
    -- pool operation on the next pump, never inside the public call.
    session:update()
    Assert.deepEqual(pool.retried, { "message-bank:5" }, "exactly the failed leaf retries once")
    Assert.equal(submissionCount(pool, "message-bank:3"), 1, "retry never rebuilds the healthy sibling")
    publishWarmBank(cacheFs, generation, 5)
    pool.states["message-bank:3"] = "ready"
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

-- Warm parents wake their dependents through pool proof: published banks
-- are admitted once each for worker reuse validation, and the summary
-- dispatches exactly once its prerequisites prove ready.
function T.proven_prerequisites_wake_their_parent_through_the_pool()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local generation = "reuse-wake-generation"
  local session, cacheFs = isolatedSession(generation, pool, backend)
  session.messageBankIds = { 3, 5 }
  publishWarmBank(cacheFs, generation, 3)
  publishWarmBank(cacheFs, generation, 5)
  local summaryReady, summaryFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(summaryReady, "the unpublished summary stays pending while its banks prove out")
  Assert.isNil(summaryFailure, "proving prerequisites report no failure")
  for _ = 1, 2 do
    session:update()
  end
  Assert.equal(submissionCount(pool, "message-bank:3"), 1, "a warm bank is admitted once for worker proof")
  Assert.equal(submissionCount(pool, "message-bank:5"), 1, "a warm bank is admitted once for worker proof")
  Assert.isNil(submittedSet(pool)["message-summary:global"], "the parent waits for proven prerequisites")
  pool.states["message-bank:3"] = "ready"
  pool.states["message-bank:5"] = "ready"
  for _ = 1, 4 do
    session:update()
  end
  Assert.equal(submissionCount(pool, "message-bank:3"), 1, "a proven bank never resubmits")
  Assert.equal(submissionCount(pool, "message-bank:5"), 1, "a proven bank never resubmits")
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
---@param jobKey string
---@return integer workerId first worker that dispatched the job
local function dispatchedWorker(env, jobKey)
  for workerId = 1, math.max(1, #env.host.channels - 1) do
    for _, message in ipairs(inputChannel(env, workerId).log) do
      if type(message) == "table" and message.jobKey == jobKey and message.stageName ~= nil then
        return workerId
      end
    end
  end
  error("no dispatched worker for " .. jobKey, 0)
end

---@param env table
---@param jobKey string
---@param knownStage string already-consumed stage name
---@return string stageName a later dispatch of the same job
local function nextDispatchedStage(env, jobKey, knownStage)
  for workerId = 1, math.max(1, #env.host.channels - 1) do
    for _, message in ipairs(inputChannel(env, workerId).log) do
      if
        type(message) == "table"
        and message.jobKey == jobKey
        and message.stageName ~= nil
        and message.stageName ~= knownStage
      then
        return message.stageName
      end
    end
  end
  error("no redispatched stage for " .. jobKey, 0)
end

---@param env table
---@param jobKey string
---@return string stageName the most recently dispatched stage for the job
local function latestDispatchedStage(env, jobKey)
  local latest = nil
  for workerId = 1, math.max(1, #env.host.channels - 1) do
    for _, message in ipairs(inputChannel(env, workerId).log) do
      if type(message) == "table" and message.jobKey == jobKey and message.stageName ~= nil then
        latest = message.stageName
      end
    end
  end
  if latest == nil then
    error("no dispatched stage for " .. jobKey, 0)
  end
  return latest
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

-- The audio catalog reads ready from a structurally valid index plus its
-- exact completion marker, so the family summary tests publish it live
-- instead of routing its source planning through the worker pool.
---@param env table
---@param marker string
local function publishAudioCatalogLive(env, marker)
  local bundle = require("tests.support.AudioFixture").bundle()
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  withHost(env.host, function()
    env.cacheFs:writeLua(ArtifactState.path("audio-catalog", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = env.session.generationId,
      kind = "audio-catalog",
      key = "global",
      marker = marker,
    })
    env.cacheFs:writeLua(AudioCache.indexPath(), bundle.index)
    env.cacheFs:write(AudioCache.catalogMarkerPath(), marker)
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
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the warm bank dispatches for worker proof")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  local bankReady, bankFailure = requestJob(env, "message-bank", "3", "required")
  Assert.isTrue(bankReady, "a proven bank answers ready")
  Assert.isNil(bankFailure, "a proven bank reports no failure")
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "a proven bank holds no worker")
  requestJob(env, "message-bank", "5", "required")
  pumpSession(env, 1)
  pushWorkerReply(env, 1, "message-bank", "5", dispatchedStage(env, 1, "message-bank:5", 1), "reused")
  pumpSession(env, 2)
  publishSummaryLive(env, { 3, 5 }, { [3] = "synthetic:romshape:003", [5] = "synthetic:romshape:005" })
  requestJob(env, "message-summary", "global", "required")
  pumpSession(env, 1)
  pushWorkerReply(env, 1, "message-summary", "global", dispatchedStage(env, 1, "message-summary:global", 1), "reused")
  pumpSession(env, 2)
  local ready, failure = requestJob(env, "message-summary", "global", "required")
  Assert.isTrue(ready, "a proven summary answers ready")
  Assert.isNil(failure, "a proven summary reports no failure")
  Assert.equal(poolStatus(env, "message-summary", "global"), "ready", "a proven parent holds no worker")

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
  publishAudioCatalogLive(env, "audio-catalog-marker-promotion")
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
  Assert.equal(poolStatus(env, "audio-summary", "global"), "unknown", "near work never occupies a worker early")
  shutdownEnv(env)
end

function T.shared_prerequisite_inherits_urgent_demand()
  local env = openLiveSession({
    generation = "dependency-shared-generation",
    bankIds = { 3 },
    iconPageIds = { 0, 1 },
  })
  publishCatalogLive(env, "catalog-marker-shared")
  publishAudioCatalogLive(env, "audio-catalog-marker-shared")
  requestJob(env, "audio-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "audio-catalog:global" }, "the catalog proves first for worker reuse")
  pushWorkerReply(env, 1, "audio-catalog", "global", dispatchedStage(env, 1, "audio-catalog:global", 1), "reused")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global" },
    "the occupant holds the worker"
  )
  requestJob(env, "mon-icon-page", "0", "sweep")
  requestJob(env, "mon-icon-page", "1", "sweep")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "mon-catalog", "global"), "queued", "the shared catalog waits behind the occupant")
  requestJob(env, "mon-icon-page", "0", "required")
  -- Required urgency cascades through the waiting layout to its queued
  -- catalog before the occupant releases the worker.
  pumpSession(env, 4)
  pushWorkerReply(env, 1, "audio-summary", "global", dispatchedStage(env, 1, "audio-summary:global", 1), "failed")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global" },
    "the required catalog inherits the urgent demand"
  )
  pushWorkerReply(env, 1, "mon-catalog", "global", dispatchedStage(env, 1, "mon-catalog:global", 1), "reused")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "mon-layout", "global"), "queued", "the proven catalog wakes its layout")
  requestJob(env, "message-bank", "3", "near")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global", "mon-layout:global" },
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
  Assert.equal(poolStatus(env, "message-bank", "3"), "unknown", "the healthy bank is never submitted before admission")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the warm bank dispatches first for worker proof")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the reused bank proves ready without publication")
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the cold bank dispatches once the worker frees"
  )
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
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "retry never rebuilds the proven sibling")
  Assert.equal(env.session:status().failed, 0, "retry clears the leaf and parent failure annotations")
  -- The retry records intent; the budgeted admission step performs the
  -- pool operation on the next pump, which dispatches exactly one new
  -- attempt for the failed leaf while the healthy sibling stays idle.
  pumpSession(env, 1)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5", "message-bank:5" },
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
    { "message-bank:3", "message-bank:5", "message-bank:5", "message-summary:global" },
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
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "the healthy sibling dispatched once for proof")
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
  publishAudioCatalogLive(env, "audio-catalog-marker-mixed")
  requestJob(env, "audio-summary", "global", "required")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "audio-catalog:global" }, "the catalog proves first for worker reuse")
  pushWorkerReply(env, 1, "audio-catalog", "global", dispatchedStage(env, 1, "audio-catalog:global", 1), "reused")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global" },
    "the occupant holds the worker"
  )
  requestJob(env, "mon-icon-page", "0", "sweep")
  requestJob(env, "mon-icon-page", "1", "sweep")
  pumpSession(env, 2)
  Assert.equal(poolStatus(env, "mon-catalog", "global"), "queued", "the shared catalog waits behind the occupant")
  requestJob(env, "mon-icon-page", "1", "required")
  -- Required urgency cascades through the waiting layout to its queued
  -- catalog before the occupant releases the worker.
  pumpSession(env, 4)
  pushWorkerReply(env, 1, "audio-summary", "global", dispatchedStage(env, 1, "audio-summary:global", 1), "failed")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global" },
    "the required catalog outranks later near demand"
  )
  pushWorkerReply(env, 1, "mon-catalog", "global", dispatchedStage(env, 1, "mon-catalog:global", 1), "reused")
  pumpSession(env, 1)
  Assert.equal(poolStatus(env, "mon-layout", "global"), "queued", "the proven catalog wakes its layout")
  -- Near demand arriving after the required job queued still waits its
  -- turn behind the shared prerequisite.
  requestJob(env, "message-bank", "3", "near")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "audio-catalog:global", "audio-summary:global", "mon-catalog:global", "mon-layout:global" },
    "the required layout outranks the near bank"
  )
  Assert.equal(dispatchCount(env, "mon-layout", "global"), 1, "the shared job dispatches once for both pages")
  Assert.equal(poolStatus(env, "message-bank", "3"), "queued", "the near bank still waits its turn")
  shutdownEnv(env)
end

function T.failed_dependency_blocks_parent_before_submission()
  local env = openLiveSession({ generation = "dependency-blocked-generation", bankIds = { 3, 5 } })
  publishBankLive(env, 3, "synthetic:romshape:003")
  local pending, pendingFailure = requestJob(env, "message-summary", "global", "required")
  Assert.isFalse(pending, "the summary stays pending while one bank is cold")
  Assert.isNil(pendingFailure, "no failure is reported while the summary waits")
  pumpSession(env, 1)
  Assert.deepEqual(env.host.dispatched, { "message-bank:3" }, "the warm bank dispatches first for worker proof")
  pushWorkerReply(env, 1, "message-bank", "3", dispatchedStage(env, 1, "message-bank:3", 1), "reused")
  pumpSession(env, 2)
  Assert.deepEqual(
    env.host.dispatched,
    { "message-bank:3", "message-bank:5" },
    "the cold bank dispatches once the worker frees"
  )
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
  -- Readiness arrives through the owned pool transition: the staged ready
  -- reply stands in for worker proof. The scope assertions below are
  -- unchanged.
  pool.states["field-font:global"] = "ready"
  for _ = 1, 4 do
    session:update()
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

function T.bootstrap_membership_is_exactly_the_menu_font()
  local jobs = ArtifactJobs.bootstrapJobs()
  Assert.equal(#jobs, 1, "bootstrap carries only the menu prerequisite")
  Assert.equal(jobs[1].kind, "field-font", "the menu prerequisite is the field font")
  Assert.equal(jobs[1].key, "global", "the menu prerequisite is the global font")
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
  local bootstrap = ArtifactJobs.bootstrapJobs()
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

-- Decoupling bootstrap from field core must not silently shrink field
-- readiness: the decoupled roster carries every previously inherited
-- member plus the audio catalog the current summary dependency requires.
function T.field_core_preserves_the_decoupled_closure()
  local lists = {
    audioBankIds = { 7 },
    messageBankIds = { 219, 220 },
    scriptMemberIds = { 149 },
    iconPageIds = { 3 },
    mapDataIds = { 7 },
  }
  local core = jobSet(ArtifactJobs.fieldCoreJobs(lists))
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
    "mon-catalog:global",
    "mon-layout:global",
    "items:global",
    "message-bank:219",
    "message-bank:220",
    "audio-catalog:global",
    "audio-summary:global",
    "audio-bank:7",
    "actors:global",
    "starter-choice:global",
    "bag:global",
    "message-summary:global",
    "script-member:149",
    "script-summary:global",
    "mon-icon-page:3",
    "map-data:7",
  }
  for _, name in ipairs(expected) do
    Assert.isTrue(core[name] == true, "decoupled core keeps " .. name)
  end
  local count = 0
  for _ in pairs(core) do
    count = count + 1
  end
  Assert.equal(count, #expected, "decoupled core carries nothing else")
end

-- A cold bootstrap request enrolls only the menu font: no source
-- inventory, no page layout, and no work beyond the font reaches the pool.
function T.bootstrap_registers_no_source_or_page_metadata()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = isolatedSession("bootstrap-metadata-generation", pool, backend)
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "bootstrap stays pending until the font is ready")
  Assert.isNil(failure, "bootstrap reports no failure while pending")
  for _ = 1, 4 do
    session:update()
  end
  Assert.isNil(session.byKey["source-plan:global"], "bootstrap schedules no source inventory")
  Assert.isNil(session.byKey["mon-layout:global"], "bootstrap schedules no page layout")
  Assert.isNil(session.milestones["field-core"], "bootstrap enrolls no field-core intent")
  for jobKey in pairs(session.byKey) do
    Assert.equal(jobKey, "field-font:global", "bootstrap interest stays font-scoped: " .. jobKey)
  end
  for _, jobKey in ipairs(pool.submitted) do
    Assert.equal(jobKey, "field-font:global", "bootstrap work stays font-scoped: " .. jobKey)
  end
end

-- Bootstrap readiness must not enroll field-core interest on its own:
-- explicit field preparation owns that demand. This drives a demand-only
-- session to readiness and proves no field-core intent appears.
function T.bootstrap_readiness_registers_no_automatic_field_core()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  CacheFs.forVersion = function(versionId)
    assert(versionId == "heartgold", "session fixture stays on heartgold")
    return cacheFs
  end
  local session
  local ok, err = pcall(function()
    session = InteractiveCacheBuild.new({
      identity = { versionId = "heartgold", generationId = "bootstrap-autocore-generation", producerId = PRODUCER_ID },
      epoch = 1,
      pool = pool,
    })
  end)
  CacheFs.forVersion = realForVersion
  if not ok then
    error(err, 0)
  end
  session:requestMilestone("bootstrap", "required")
  pool.states["field-font:global"] = "ready"
  for _ = 1, 4 do
    session:update()
  end
  local ready, failure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(ready, "bootstrap answers ready from the font alone")
  Assert.isNil(failure, "bootstrap reports no failure on success")
  Assert.isNil(session.milestones["field-core"], "ready bootstrap never auto-requests field core")
end

-- Explicit complete intent is an idempotent owner operation: it records
-- the demand, performs no pool or cache work synchronously, and rejects
-- on a retired session.
function T.complete_request_is_idempotent_and_performs_no_synchronous_work()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session = isolatedSession("complete-request-generation", pool, backend)
  session:update()
  local submittedBefore = #pool.submitted
  local first, firstFailure = session:requestComplete("required")
  Assert.isFalse(first, "the complete build stays pending until the pump runs")
  Assert.isNil(firstFailure, "registration reports no failure")
  Assert.equal(#pool.submitted, submittedBefore, "requesting enrolls nothing synchronously")
  local second, secondFailure = session:requestComplete("required")
  Assert.isFalse(second, "a repeated request stays pending")
  Assert.isNil(secondFailure, "a repeated request reports no failure")
  Assert.equal(#pool.submitted, submittedBefore, "repeated requesting stays work-free")
  session:retire()
  local ok, err = pcall(session.requestComplete, session, "required")
  Assert.isFalse(ok, "requesting on a retired session rejects")
  Assert.isTrue(tostring(err):find("retired", 1, true) ~= nil, "the rejection names retirement")
end

local function oakAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_GS_STARTING", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_GS_STARTING2", bankId = 20 },
        [102] = { id = 102, symbol = "SEQ_SE_DP_BOWA2", bankId = 30 },
        [103] = { id = 103, symbol = "SEQ_SE_DP_SELECT", bankId = 30 },
        [104] = { id = 104, symbol = "SEQ_SE_GS_HERO_SHUKUSHOU", bankId = 40 },
      },
      sequenceBySymbol = {
        SEQ_GS_STARTING = 100,
        SEQ_GS_STARTING2 = 101,
        SEQ_SE_DP_BOWA2 = 102,
        SEQ_SE_DP_SELECT = 103,
        SEQ_SE_GS_HERO_SHUKUSHOU = 104,
      },
    },
  }
end

-- The New Game intro milestone stays pending before source adoption with a
-- unresolved roster, and it never schedules mon page membership: the
-- intro closure needs the source inventory but no page layout.
function T.new_game_intro_stays_unresolved_without_source_knowledge()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("new-game-unresolved-generation", pool, backend)
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro milestone stays pending while the inventory is cold")
  Assert.isNil(failure, "the intro milestone reports no failure while pending")
  -- Enrollment is update-owned and bounded: pump until the unresolved
  -- roster drains instead of assuming one update converges it.
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["new-game-intro"], "the intro roster builds from retained intent")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  Assert.isTrue(set["source-plan:global"] == true, "the unresolved roster keeps its source owner")
  Assert.isTrue(set["audio-catalog:global"] == true, "the unresolved roster keeps the catalog")
  Assert.isNil(set["audio-bank:184"], "no bank closure is final before source adoption")
  Assert.isNil(session.byKey["mon-layout:global"], "the intro milestone schedules no page layout")
  for _, entry in pairs(session.byKey) do
    if type(entry) == "table" and entry.failure == nil then
      entry.ready = true
    end
  end
  local again, againFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(again, "ready members never certify the intro scope before source adoption")
  Assert.isNil(againFailure, "no failure is reported while the scope is unresolved")
end

-- With adopted source audio membership the intro roster resolves exactly
-- the Oak bank closures, excludes the full summary and field work, and
-- reaches ready from its own members.
function T.new_game_intro_resolves_exact_bank_closures_after_adoption()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("new-game-final-generation", pool, backend)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30, 40, 184 }
  session.adopted = { audioPlan = oakAudioPlan() }
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro milestone stays pending while cold")
  Assert.isNil(failure, "the intro milestone reports no failure while pending")
  -- The hand-adopted inventory stands in for the published source record,
  -- so its owner is retained ready without a worker round trip. Member
  -- readiness below still arrives through the owned pool transition.
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "required",
    priority = 0,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["new-game-intro"], "the adopted roster rebuilds from source knowledge")
  local set = {}
  for _, member in ipairs(roster) do
    set[member.kind .. ":" .. member.key] = true
  end
  for _, expected in ipairs({
    "audio-bank:10",
    "audio-bank:20",
    "audio-bank:30",
    "audio-bank:40",
    "audio-bank:184",
  }) do
    Assert.isTrue(set[expected] == true, "the adopted roster carries " .. expected)
  end
  Assert.isNil(set["audio-summary:global"], "the full summary stays out of the intro roster")
  Assert.isNil(set["actors:global"], "field actors stay out of the intro roster")
  -- Readiness arrives through the owned pool transition: staged ready
  -- replies stand in for worker proof for every enrolled member.
  for _, member in ipairs(roster) do
    pool.states[member.kind .. ":" .. member.key] = "ready"
  end
  for _ = 1, 10 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isTrue(again, "the intro scope certifies once its own members are ready")
  Assert.isNil(againFailure, "the intro scope reports no failure on success")
end

-- A later required request for an already-prefetched intro closure
-- strengthens the retained entries instead of duplicating submissions:
-- queued members promote to priority 0 while the pool sees each identity
-- at most once for submission plus once for promotion.
function T.new_game_intro_required_promotes_near_prefetch_without_duplicates()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local priorities = {}
  local baseRequest = pool.request
  pool.request = function(self, job)
    priorities[job.jobKey] = job.priority
    return baseRequest(self, job)
  end
  local session, _ = isolatedSession("new-game-promotion-generation", pool, backend)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30, 40, 184 }
  session.adopted = { audioPlan = oakAudioPlan() }
  local first, firstFailure = session:requestMilestone("new-game-intro", "near")
  Assert.isFalse(first, "the prefetched intro closure stays pending while cold")
  Assert.isNil(firstFailure, "the prefetch reports no failure")
  for _ = 1, 6 do
    session:update()
  end
  local second, secondFailure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(second, "the promoted closure stays pending while cold")
  Assert.isNil(secondFailure, "the promotion reports no failure")
  for _ = 1, 6 do
    session:update()
  end
  local counts = {}
  for _, jobKey in ipairs(pool.submitted) do
    counts[jobKey] = (counts[jobKey] or 0) + 1
  end
  local promoted = 0
  for _, entry in pairs(session.byKey) do
    if type(entry) == "table" and entry.failure == nil and entry.submitted then
      Assert.equal(entry.priority, 0, "a promoted member reaches required priority: " .. entry.jobKey)
      Assert.equal(priorities[entry.jobKey], 0, "the pool observes the promoted priority: " .. entry.jobKey)
      promoted = promoted + 1
    end
  end
  Assert.isTrue(promoted > 0, "the promotion reaches submitted members")
  for jobKey, count in pairs(counts) do
    Assert.isTrue(count <= 2, "no identity resubmits across promotion: " .. jobKey)
  end
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

-- A background retry re-enters through the single admission point: the
-- failed leaf retries promptly while older queued work keeps its order
-- and every leaf dispatches exactly once.
function T.background_retry_readmits_through_the_single_admission_point()
  local env = openLiveSession({ generation = "retry-admission-generation", bankIds = { 3, 5 } })
  requestJob(env, "message-bank", "3", "sweep")
  requestJob(env, "message-bank", "5", "sweep")
  pumpSession(env, 3)
  Assert.isTrue(poolStatus(env, "message-bank", "3") ~= "unknown", "background demand submits without parking")
  Assert.isTrue(poolStatus(env, "message-bank", "5") ~= "unknown", "queued background work submits in turn")
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "the single worker takes the first leaf")
  local worker = dispatchedWorker(env, "message-bank:3")
  local firstStage = dispatchedStage(env, worker, "message-bank:3", 1)
  pushWorkerReply(env, worker, "message-bank", "3", firstStage, "failed")
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
  Assert.equal(retryCalls, 0, "the retry reaches the pool through the pump, not the call")
  pumpSession(env, 2)
  Assert.equal(retryCalls, 1, "the pump readmits the failed leaf once")
  -- FIFO order holds the readmitted leaf behind the earlier queued bank:
  -- the worker takes bank 5 first, then the retry.
  pumpSession(env, 3)
  publishBankLive(env, 5, "synthetic:romshape:005")
  stageBankReply(env, 5, "synthetic:romshape:005", latestDispatchedStage(env, "message-bank:5"))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the earlier leaf publishes")
  pumpSession(env, 3)
  publishBankLive(env, 3, "synthetic:romshape:003")
  stageBankReply(env, 3, "synthetic:romshape:003", nextDispatchedStage(env, "message-bank:3", firstStage))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the retried leaf publishes")
  pumpSession(env, 3)
  local repaired, repairedFailure = requestJob(env, "message-bank", "3", "sweep")
  Assert.isTrue(repaired, "the retried leaf succeeds: " .. tostring(repairedFailure))
  Assert.equal(dispatchCount(env, "message-bank", "3"), 2, "the retry dispatches the failed leaf once more")
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the queued leaf still publishes in turn")
  Assert.equal(dispatchCount(env, "message-bank", "5"), 1, "the queued leaf dispatches exactly once")
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
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
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
  for _, member in ipairs(ArtifactJobs.bootstrapJobs()) do
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
  -- Every family answers through pool proof: staged ready replies stand
  -- in for worker reuse validation, so the pump settles the scope once
  -- every admitted entry proves out.
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
    })
    local cold, coldFailure = session:requestMilestone("bootstrap", "required")
    Assert.isFalse(cold, "bootstrap stays pending until the pump admits its roster")
    Assert.isNil(coldFailure, "bootstrap reports no failure while pending")
    local settled = false
    for _ = 1, 40 do
      session:update()
      for _, jobKey in ipairs(pool.submitted) do
        pool.states[jobKey] = "ready"
      end
      session:update()
      if session:status().settled then
        settled = true
        break
      end
    end
    Assert.isTrue(settled, "the pool-proven bootstrap settles")
    Assert.isTrue(#pool.submitted > 0, "warm demand reaches the pool for worker proof")
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
    -- Enrollment is update-owned: admit the roster first, then establish
    -- readiness through the owned pool transition. The poll contract
    -- below is unchanged.
    pool.states["field-font:global"] = "ready"
    session:update()
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
    })
    for _, memberId in ipairs(scriptIds) do
      session:requestJob("script-member", tostring(memberId), "near")
    end
    -- The inventory proves through one staged pool reply, so adoption
    -- populates membership and every member submits: the session holds no
    -- admission gate, the pool owns physical queueing.
    pool.states["source-plan:global"] = "ready"
    for _ = 1, 8 do
      session:update()
    end
    local submitted, unsubmitted = 0, 0
    for _, memberId in ipairs(scriptIds) do
      local entry = session.byKey["script-member:" .. tostring(memberId)]
      Assert.notNil(entry, "near demand registers every member")
      if entry.submitted then
        submitted = submitted + 1
      elseif entry.failure == nil and not entry.ready then
        unsubmitted = unsubmitted + 1
      end
    end
    Assert.equal(submitted, #scriptIds, "demand submits every member without session parking")
    Assert.equal(unsubmitted, 0, "no member waits on session admission")
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

-- Normal updates poll only submitted frontier work: hundreds of retained
-- terminal entries stay untouched while one pending job is observed.
function T.normal_update_polls_only_submitted_frontier_entries()
  local pool = recordingPool()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local session = summarySession(pool, cacheFs, { 3 })
  local ready, failure = session:requestJob("message-bank", "3", "near")
  Assert.isFalse(ready, "the bank stays pending while its worker is cold")
  Assert.isNil(failure, "no failure is reported while the bank waits")
  session:update()
  local entry = assert(session.byKey["message-bank:3"], "the bank keeps its retained entry")
  Assert.isTrue(entry.submitted, "the bank reached the pool")
  for index = 1, 200 do
    local sentinel = setmetatable({ jobKey = "retained-sentinel:" .. index }, {
      __index = function(_, _)
        error("retained-history sentinel touched by normal update: retained-sentinel:" .. index, 0)
      end,
    })
    session.interest[#session.interest + 1] = sentinel
  end
  session:update()
  Assert.isFalse(entry.ready, "the submitted bank stays pending")
  Assert.isNil(entry.failure, "the submitted bank reports no failure")
  Assert.equal(entry.poolState, "queued", "the submitted bank is still observed")
  local frontier = assert(session.submittedPending, "the session indexes its submitted frontier for normal updates")
  Assert.isTrue(frontier["message-bank:3"] == entry, "the frontier holds the pending job")
  local frontierSize = 0
  for _ in pairs(frontier) do
    frontierSize = frontierSize + 1
  end
  Assert.equal(frontierSize, 1, "the frontier holds only submitted work")
end

-- Background demand submits without session parking: every requested leaf
-- reaches the pool, required promotion strengthens the retained entry
-- without resubmission, and every leaf publishes exactly once.
-- Background demand submits without session parking: every requested leaf
-- reaches the pool while physical execution stays single-worker bound.
-- Required promotion jumps the pool queue without resubmission, and every
-- leaf publishes exactly once.
function T.background_demand_submits_without_session_parking()
  local env = openLiveSession({ generation = "background-order-generation", bankIds = { 3, 5, 7 } })
  requestJob(env, "message-bank", "3", "sweep")
  requestJob(env, "message-bank", "5", "sweep")
  requestJob(env, "message-bank", "7", "sweep")
  pumpSession(env, 3)
  -- Submission is the session contract: every requested leaf reaches the
  -- pool instead of parking behind session-side credit. The single
  -- interactive worker executes one leaf while the rest queue at the pool.
  for _, bankId in ipairs({ 3, 5, 7 }) do
    local key = tostring(bankId)
    Assert.isTrue(
      poolStatus(env, "message-bank", key) ~= "unknown",
      "background demand submits without parking: " .. key
    )
  end
  Assert.equal(dispatchCount(env, "message-bank", "3"), 1, "the first leaf dispatches")
  requestJob(env, "message-bank", "7", "required")
  pumpSession(env, 2)
  local entry = assert(env.session.byKey["message-bank:7"], "the promoted leaf keeps its retained entry")
  Assert.equal(entry.urgency, "required", "promotion strengthens the retained entry")
  local worker3 = dispatchedWorker(env, "message-bank:3")
  publishBankLive(env, 3, "synthetic:romshape:003")
  stageBankReply(env, 3, "synthetic:romshape:003", dispatchedStage(env, worker3, "message-bank:3", 1))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "3"), "ready", "the first leaf publishes")
  Assert.equal(dispatchCount(env, "message-bank", "7"), 1, "promotion jumps the pool queue without resubmission")
  local worker7 = dispatchedWorker(env, "message-bank:7")
  publishBankLive(env, 7, "synthetic:romshape:007")
  stageBankReply(env, 7, "synthetic:romshape:007", dispatchedStage(env, worker7, "message-bank:7", 1))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "7"), "ready", "the promoted leaf publishes")
  local worker5 = dispatchedWorker(env, "message-bank:5")
  publishBankLive(env, 5, "synthetic:romshape:005")
  stageBankReply(env, 5, "synthetic:romshape:005", dispatchedStage(env, worker5, "message-bank:5", 1))
  pumpSession(env, 3)
  Assert.equal(poolStatus(env, "message-bank", "5"), "ready", "the last leaf publishes")
  for _, bankId in ipairs({ 3, 5, 7 }) do
    Assert.equal(
      dispatchCount(env, "message-bank", tostring(bankId)),
      1,
      "the leaf dispatches exactly once: " .. bankId
    )
  end
  shutdownEnv(env)
end

-- The intro progress projection reads only its own retained roster: with
-- the adopted bank closures fixed, hundreds of unrelated sweep
-- registrations and state flips leave the returned record identical.
function T.intro_progress_ignores_unrelated_sweep_interest()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("intro-progress-isolation-generation", pool, backend)
  session.sourceLoaded = true
  session.audioBankIds = { 10, 20, 30, 40, 184 }
  session.adopted = { audioPlan = oakAudioPlan() }
  local ready, failure = session:requestMilestone("new-game-intro", "required")
  Assert.isFalse(ready, "the intro closure stays pending while cold")
  Assert.isNil(failure, "the intro closure reports no failure while pending")
  -- The hand-adopted inventory stands in for the published source record;
  -- member readiness below arrives through the owned pool transition.
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "required",
    priority = 0,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
  for _ = 1, 6 do
    session:update()
  end
  local roster = assert(session.roster["new-game-intro"], "the adopted intro roster is retained")
  Assert.isTrue(#roster > 0, "the adopted roster names its closure")
  for _, member in ipairs(roster) do
    pool.states[member.kind .. ":" .. member.key] = "ready"
  end
  for _ = 1, 10 do
    session:update()
  end
  local before = session:milestoneStatus("new-game-intro")
  Assert.deepEqual(
    { state = before.state, ready = before.ready, total = before.total },
    { state = "ready", ready = #roster, total = #roster },
    "the settled intro closure reports its exact membership"
  )
  for bankId = 300, 599 do
    session:requestJob("message-bank", tostring(bankId), "sweep")
  end
  for memberId = 1, 200 do
    session:requestJob("script-member", tostring(memberId), "sweep")
  end
  for pageId = 0, 99 do
    session:requestJob("mon-icon-page", tostring(pageId), "sweep")
  end
  for _ = 1, 4 do
    session:update()
  end
  local after = session:milestoneStatus("new-game-intro")
  Assert.deepEqual(after, before, "unrelated sweep work never perturbs the intro record")
end

-- Progress observation is a bounded read-only projection: unrelated
-- retained entries raise if touched, and pool, cache, and validator
-- traffic stays at zero across repeated calls.
function T.intro_progress_observation_touches_only_its_roster()
  local backend = FakeCache.new()
  local cacheReads = 0
  local realBackendRead = backend.read
  function backend.read(self, path)
    cacheReads = cacheReads + 1
    return realBackendRead(self, path)
  end
  local innerPool = retryCapablePool()
  local poolCalls = 0
  local pool = setmetatable({}, {
    __index = function(_, key)
      if key == "request" or key == "status" or key == "update" or key == "retry" then
        return function(_, ...)
          poolCalls = poolCalls + 1
          local real = innerPool[key]
          assert(type(real) == "function", "pool lacks spied method")
          return real(innerPool, ...)
        end
      end
      return innerPool[key]
    end,
  })
  local realValidate = ArtifactJobs.validate
  local validateCalls = 0
  ArtifactJobs.validate = function(...)
    validateCalls = validateCalls + 1
    return realValidate(...)
  end
  local ok, failure = pcall(function()
    local session, _ = isolatedSession("intro-progress-bounds-generation", pool, backend)
    session.sourceLoaded = true
    session.audioBankIds = { 10, 20, 30, 40, 184 }
    session.adopted = { audioPlan = oakAudioPlan() }
    session:requestMilestone("new-game-intro", "required")
    for _ = 1, 6 do
      session:update()
    end
    session.byKey["actors:global"] = setmetatable({}, {
      __index = function()
        error("progress observation touched an unrelated entry", 0)
      end,
    })
    session.byKey["audio-summary:global"] = setmetatable({}, {
      __index = function()
        error("progress observation touched an unrelated entry", 0)
      end,
    })
    cacheReads, poolCalls, validateCalls = 0, 0, 0
    local first = session:milestoneStatus("new-game-intro")
    local second = session:milestoneStatus("new-game-intro")
    local third = session:milestoneStatus("bootstrap")
    Assert.deepEqual(second, first, "repeated observation is stable")
    Assert.equal(third.total, nil, "an unbuilt roster reports no denominator")
    Assert.equal(cacheReads, 0, "observation performs no cache reads")
    Assert.equal(poolCalls, 0, "observation polls no pool state")
    Assert.equal(validateCalls, 0, "observation runs no family validation")
    Assert.isTrue(first.ready <= (first.total or first.ready), "the numerator never exceeds its denominator")
  end)
  ArtifactJobs.validate = realValidate
  backend.read = nil
  if not ok then
    error(failure, 0)
  end
end

-- Idle demand enrolls nothing: an interactive session with no explicit
-- requests submits no worker jobs across sustained pumping and never
-- materializes the complete corpus. A later explicit near-cell demand
-- then submits only its own dependency closure.
function T.idle_session_without_requests_submits_no_work()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session, _ = isolatedSession("idle-without-requests", pool, backend)
  session.adopted = {
    indexBundle = {
      index = {
        matrices = {
          {
            matrixMemberId = 1,
            cells = {
              {
                matrixMemberId = 1,
                index = 0,
                x = 0,
                z = 0,
                mapHeaderId = 0,
                altitude = 0,
                landDataMemberId = 1,
                areaDataMemberId = 2,
              },
            },
          },
        },
      },
      indexMarker = "idle-index-marker",
    },
  }
  session.sourceLoaded = true
  session.byKey["source-plan:global"] = {
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    urgency = "sweep",
    priority = 100,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
  session.interest[#session.interest + 1] = session.byKey["source-plan:global"]
  pool.states["field-cell-index:global"] = "ready"
  local realCompleteJobs = ArtifactJobs.completeJobs
  ArtifactJobs.completeJobs = function()
    error("an idle interactive session must not materialize the complete corpus", 0)
  end
  local ok, failure = pcall(function()
    for _ = 1, 50 do
      session:update()
    end
    Assert.equal(#pool.submitted, 0, "idle updates with no requests submit no jobs")
    local ready, requestFailure = session:requestCell({ matrixMemberId = 1, index = 0 }, "near")
    Assert.isFalse(ready, "the cold cell answers pending until the pump runs")
    Assert.isNil(requestFailure, "registration reports no failure")
    for _ = 1, 50 do
      session:update()
    end
    local submitted = submittedSet(pool)
    Assert.isTrue(submitted["field-cell:1-0"] == true, "the explicit cell dispatches")
    Assert.isTrue(
      #pool.submitted < 20,
      "the cell closure stays bounded, never the corpus: " .. tostring(#pool.submitted)
    )
  end)
  ArtifactJobs.completeJobs = realCompleteJobs
  if not ok then
    error(failure, 0)
  end
end

-- A scoped demand never attests exhaustive completion: bootstrap
-- enrollment covers only its own roster while the complete flag stays
-- down. Explicit complete builds alone may attest it.
function T.scoped_demand_covers_only_its_roster_without_complete_attestation()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session, _ = isolatedSession("scoped-without-complete", pool, backend)
  pool.states["field-font:global"] = "ready"
  local ready, requestFailure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(ready, "the scope stays pending until the pump runs")
  Assert.isNil(requestFailure, "registration reports no failure")
  for _ = 1, 20 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("bootstrap", "required")
  Assert.isTrue(again, "the satisfied scope answers ready")
  Assert.isNil(againFailure, "the satisfied scope reports no failure")
  for _, outcome in ipairs(session:outcomes()) do
    Assert.equal(outcome.jobKey, "field-font:global", "the scope enrolls only its roster")
  end
  Assert.isFalse(session:status().complete, "a runtime subset never attests complete")
end

-- Required and background are the only scheduling classes: required
-- runs first while near and sweep spellings share the background lane.
function T.required_near_and_sweep_use_three_scheduling_lanes()
  Assert.equal(ArtifactJobs.priorityFor("required"), 0)
  Assert.equal(ArtifactJobs.priorityFor("near"), 10)
  Assert.equal(ArtifactJobs.priorityFor("sweep"), 100)
  Assert.throws(function()
    ArtifactJobs.priorityFor("eventually")
  end)
end

-- Scope settlement follows the scope's own dependencies: a required
-- milestone settles while an unrelated blocked background leaf stays
-- pending, each key submits once, and repeated notifications settle
-- nothing twice.
function T.required_scope_settles_while_unrelated_background_waits()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("scope-settlement-generation", pool, backend)
  session.messageBankIds = { 31511 }
  pool.states["field-font:global"] = "ready"
  local coldKey = "message-bank:31511"
  local ready, requestFailure = session:requestJob("message-bank", "31511", "near")
  Assert.isFalse(ready, "the cold background bank answers pending")
  Assert.isNil(requestFailure, "registration reports no failure")
  local milestoneReady, milestoneFailure = session:requestMilestone("bootstrap", "required")
  Assert.isFalse(milestoneReady, "the milestone stays pending until the pump runs")
  Assert.isNil(milestoneFailure, "the milestone reports no failure while pending")
  local settled = false
  for _ = 1, 100 do
    session:update()
    local again = session:requestMilestone("bootstrap", "required")
    local coldAgain = session:requestJob("message-bank", "31511", "near")
    if again and not coldAgain then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "the required scope settles while the unrelated leaf waits")
  Assert.equal(submissionCount(pool, coldKey), 1, "the blocked leaf submits exactly once")
  for _ = 1, 20 do
    session:update()
    session:requestMilestone("bootstrap", "required")
    session:requestJob("message-bank", "31511", "near")
  end
  Assert.equal(submissionCount(pool, coldKey), 1, "repeated notifications resubmit nothing")
  local stillPending = session:requestJob("message-bank", "31511", "near")
  Assert.isFalse(stillPending, "the unreplied leaf never borrows the scope's readiness")
end

-- An unproven wait stays pending: only a genuine dependency back-edge
-- fails, and it names the concrete key path. A failed child settles
-- its dependent once with the original cause.
function T.unproven_wait_stays_pending_without_a_cycle_path()
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
  Assert.isTrue(
    tostring(againFailure):find("message-bank", 1, true) ~= nil,
    "the cycle names the concrete key path: " .. tostring(againFailure)
  )
end

function T.unexpanded_inventory_waits_without_a_cycle()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session, _ = isolatedSession("unexpanded-inventory", pool, backend)
  local ready, requestFailure = session:requestMilestone("field-core", "required")
  Assert.isFalse(ready, "the core stays pending until its inventory arrives")
  Assert.isNil(requestFailure, "registration reports no failure")
  for _ = 1, 20 do
    session:update()
  end
  local again, againFailure = session:requestMilestone("field-core", "required")
  Assert.isFalse(again, "unexpanded inventory never answers ready")
  Assert.isNil(againFailure, "a wait for inventory is pending, never a cycle")
end

function T.failed_child_settles_its_dependent_once_with_its_cause()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session, _ = isolatedSession("failed-child-cause", pool, backend)
  local ready, requestFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(ready, "the summary stays pending until the pump runs")
  Assert.isNil(requestFailure, "registration reports no failure")
  session:update()
  pool.states["message-bank:3"] = { state = "failed", details = { error = "synthetic bank failure" } }
  session:update()
  local again, againFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(again, "a failed child never answers ready")
  Assert.isTrue(
    tostring(againFailure):find("synthetic bank failure", 1, true) ~= nil,
    "the dependent carries the original cause: " .. tostring(againFailure)
  )
  for _ = 1, 10 do
    session:update()
  end
  local repeated, repeatedFailure = session:requestJob("message-summary", "global", "required")
  Assert.isFalse(repeated, "the failure is terminal")
  Assert.equal(tostring(repeatedFailure), tostring(againFailure), "repeated polls settle nothing twice")
end

-- Opportunistic background corpus completion over the canonical demand
-- graph. A synthetic fully adopted inventory lets the background cursor
-- enumerate every corpus artifact through the same registration path as
-- explicit demand: the source and layout owners below are already ready,
-- so discovery is satisfied and the cursor itself is the only new work.
local function readyOwnerEntry(kind)
  return {
    kind = kind,
    key = "global",
    jobKey = kind .. ":global",
    urgency = "sweep",
    priority = 100,
    submitted = false,
    ready = true,
    failure = nil,
    phase = "ready",
    finalDeps = {},
    depsFinal = true,
    depIndex = 1,
    pendingDeps = {},
  }
end

local function warmingAdopted()
  return {
    messageBankIds = { 1, 2 },
    audioBankIds = { 3 },
    scriptMemberIds = { 4 },
    iconPageIds = { 0 },
    portraitPageIds = { 1 },
    mapDataIds = {},
    mapIds = { 7 },
    mapCellKeys = { [7] = {} },
    indexBundle = { index = { matrices = {} }, indexMarker = "warming-index-marker" },
    scriptPlan = { members = { { memberId = 4 } }, generationKey = "warming-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = { { bankId = 3 } } },
  }
end

local function warmingSession(generation, pool, backend)
  local session, _ = isolatedSession(generation, pool, backend)
  session.adopted = warmingAdopted()
  session.sourceLoaded = true
  session.pagesKnown = true
  session.messageBankIds = { 1, 2 }
  session.audioBankIds = { 3 }
  session.scriptMemberIds = { 4 }
  session.iconPageIds = { 0 }
  session.portraitPageIds = { 1 }
  session.mapDataIds = {}
  session.mapIds = { 7 }
  session.mapCellKeys = { [7] = {} }
  for _, kind in ipairs({ "source-plan", "mon-layout" }) do
    local owner = readyOwnerEntry(kind)
    session.byKey[owner.jobKey] = owner
    session.interest[#session.interest + 1] = owner
  end
  return session
end

local function expectedWarmingCoverage()
  local covered = {}
  local iterate = ArtifactJobs.completeIterator(warmingAdopted())
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    if job.jobKey ~= "source-plan:global" and job.jobKey ~= "mon-layout:global" then
      covered[job.jobKey] = true
    end
  end
  return covered
end

local function pumpUntilSubmitted(session, pool, rounds)
  for _ = 1, rounds do
    session:update()
    if #pool.submitted > 0 then
      return pool.submitted[1]
    end
  end
  error("background warmup submitted no candidate", 0)
end

-- Idle authorized play converges on full corpus coverage, but the corpus
-- is never enrolled at once: a later candidate appears only after the
-- previous sweep-origin candidate settles.
function T.authorized_warmup_eventually_covers_the_corpus_one_candidate_at_a_time()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-coverage-generation", pool, backend)
  session:enableSweep()
  local seen = {}
  local outstanding = nil
  local rounds = 0
  while session:status().sweepState ~= "exhausted" and rounds < 600 do
    rounds = rounds + 1
    session:update()
    for _, jobKey in ipairs(pool.submitted) do
      if not seen[jobKey] then
        seen[jobKey] = true
        Assert.isNil(outstanding, "a later candidate enrolls only after the previous one settles: " .. jobKey)
        outstanding = jobKey
      end
    end
    if outstanding ~= nil then
      pool.states[outstanding] = "ready"
      outstanding = nil
    end
  end
  Assert.equal(session:status().sweepState, "exhausted", "idle warmup drains the corpus cursor")
  local covered = expectedWarmingCoverage()
  local readyCount = 0
  for jobKey in pairs(covered) do
    local entry = session.byKey[jobKey]
    Assert.notNil(entry, "every corpus artifact registers: " .. jobKey)
    Assert.isTrue(entry.ready, "every corpus artifact reaches ready: " .. jobKey)
    readyCount = readyCount + 1
  end
  local submittedCount = 0
  for _ in pairs(seen) do
    submittedCount = submittedCount + 1
  end
  Assert.equal(submittedCount, readyCount, "warmup submits exactly the corpus coverage")
end

-- Required demand submits ahead of a queued background candidate, and
-- requesting the queued candidate itself promotes the same record.
function T.required_demand_overtakes_a_queued_background_candidate()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-overtake-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  local ready, failure = session:requestJob("script-member", "4", "required")
  Assert.isFalse(ready, "required demand answers pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local submittedAfter = false
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey == "script-member:4" then
      submittedAfter = true
    end
  end
  Assert.isTrue(submittedAfter, "required demand submits while the background candidate waits")
  Assert.isNil(pool.states[candidate], "the background candidate still awaits execution")
  pool.states["script-member:4"] = "ready"
  for _ = 1, 10 do
    session:update()
  end
  Assert.isTrue(session.byKey["script-member:4"].ready, "required demand settles first")
  Assert.isNil(session.byKey[candidate].ready or nil, "the background candidate stays outstanding")
  pool.states[candidate] = "ready"
  for _ = 1, 10 do
    session:update()
  end
  Assert.isTrue(session.byKey[candidate].ready, "background progression resumes after required work")
end

function T.required_request_promotes_the_queued_background_record()
  local backend = FakeCache.new()
  local pool = recordingPool()
  local session = warmingSession("warming-promotion-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  local kind, key = candidate:match("^([^:]+):(.+)$")
  local ready, failure = session:requestJob(kind, key, "required")
  Assert.isFalse(ready, "the queued candidate answers pending")
  Assert.isNil(failure, "promotion reports no failure")
  local entry = assert(session.byKey[candidate], "the candidate keeps its canonical record")
  Assert.equal(entry.urgency, "required", "promotion strengthens the same record")
  Assert.equal(entry.priority, 0, "promotion moves the same record to the required lane")
  for _ = 1, 10 do
    session:update()
  end
  local submissions = 0
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey == candidate then
      submissions = submissions + 1
    end
  end
  Assert.equal(submissions, 1, "promotion never duplicates the background job")
end

-- Near prefetch submits before queued exhaustive work on its own lane.
function T.near_prefetch_submits_before_queued_sweep_work()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-near-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  local ready, failure = session:requestJob("audio-bank", "3", "near")
  Assert.isFalse(ready, "near prefetch answers pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local nearSubmitted = false
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey == "audio-bank:3" then
      nearSubmitted = true
    end
  end
  Assert.isTrue(nearSubmitted, "near prefetch submits while sweep work waits")
  Assert.isNil(pool.states[candidate], "the sweep candidate still awaits execution")
  local nearEntry = assert(session.byKey["audio-bank:3"], "near demand keeps its record")
  Assert.equal(nearEntry.priority, 10, "near demand runs on its own middle lane")
end

-- A background candidate already executing is never cancelled: required
-- work queues behind it and no second sweep candidate jumps ahead.
function T.running_background_work_is_never_preempted()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-preemption-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  pool.states[candidate] = "running"
  for _ = 1, 5 do
    session:update()
  end
  local ready, failure = session:requestJob("script-member", "4", "required")
  Assert.isFalse(ready, "required demand answers pending")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 10 do
    session:update()
  end
  local requiredSubmitted = false
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey == "script-member:4" then
      requiredSubmitted = true
    end
  end
  Assert.isTrue(requiredSubmitted, "required demand submits behind the running background job")
  Assert.equal(pool.states[candidate], "running", "the running background job is never cancelled")
  local submissionsBefore = #pool.submitted
  pool.states[candidate] = "ready"
  for _ = 1, 5 do
    session:update()
  end
  Assert.isTrue(session.byKey[candidate].ready, "the running job completes normally")
  local laterSubmissions = {}
  for index = submissionsBefore + 1, #pool.submitted do
    laterSubmissions[#laterSubmissions + 1] = pool.submitted[index]
  end
  Assert.equal(#laterSubmissions, 0, "no second sweep candidate jumps ahead of required work")
end

-- Aggregate summaries never bulk-enroll their leaf families: every leaf
-- submits before its summary does.
function T.background_warmup_registers_leaves_before_summaries()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-leaves-generation", pool, backend)
  session:enableSweep()
  local rounds = 0
  while session:status().sweepState ~= "exhausted" and rounds < 600 do
    rounds = rounds + 1
    session:update()
    for _, jobKey in ipairs(pool.submitted) do
      if pool.states[jobKey] == nil then
        pool.states[jobKey] = "ready"
      end
    end
  end
  Assert.equal(session:status().sweepState, "exhausted", "warmup drains with leaves first")
  local position = {}
  for index, jobKey in ipairs(pool.submitted) do
    if position[jobKey] == nil then
      position[jobKey] = index
    end
  end
  local families = {
    ["message-summary:global"] = { "message-bank:1", "message-bank:2" },
    ["audio-summary:global"] = { "audio-bank:3" },
    ["script-summary:global"] = { "script-member:4" },
    ["mon-summary:global"] = { "mon-icon-page:0", "mon-portrait-page:1" },
  }
  for summary, leaves in pairs(families) do
    local summaryAt = assert(position[summary], "the summary submits: " .. summary)
    for _, leaf in ipairs(leaves) do
      local leafAt = assert(position[leaf], "the leaf submits: " .. leaf)
      Assert.isTrue(leafAt < summaryAt, leaf .. " submits before " .. summary)
    end
  end
end

-- The complete inventory still enumerates every corpus artifact with
-- summaries ordered after their leaves.
function T.complete_inventory_yields_summaries_after_their_leaves()
  local order = {}
  local iterate = ArtifactJobs.completeIterator(warmingAdopted())
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    order[#order + 1] = job.jobKey
  end
  local position = {}
  for index, jobKey in ipairs(order) do
    if position[jobKey] == nil then
      position[jobKey] = index
    end
  end
  local families = {
    ["message-summary:global"] = { "message-bank:1", "message-bank:2" },
    ["audio-summary:global"] = { "audio-bank:3" },
    ["script-summary:global"] = { "script-member:4" },
    ["mon-summary:global"] = { "mon-icon-page:0", "mon-portrait-page:1" },
  }
  for summary, leaves in pairs(families) do
    local summaryAt = assert(position[summary], "the inventory yields " .. summary)
    for _, leaf in ipairs(leaves) do
      local leafAt = assert(position[leaf], "the inventory yields " .. leaf)
      Assert.isTrue(leafAt < summaryAt, "the inventory yields " .. leaf .. " before " .. summary)
    end
  end
  local covered = expectedWarmingCoverage()
  local count, matched = 0, 0
  for _, jobKey in ipairs(order) do
    count = count + 1
    if covered[jobKey] then
      matched = matched + 1
    end
  end
  local expected = 0
  for _ in pairs(covered) do
    expected = expected + 1
  end
  Assert.equal(count, expected + 2, "the inventory still enumerates the whole corpus")
  Assert.equal(matched, expected, "every corpus artifact stays enumerated")
end

-- Authorization itself performs no cache work: no submission, no corpus
-- materialization.
function T.sweep_authorization_itself_enqueues_no_work()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-authorization-generation", pool, backend)
  local realCompleteJobs = ArtifactJobs.completeJobs
  ArtifactJobs.completeJobs = function()
    error("authorization must not materialize the corpus", 0)
  end
  local ok, err = pcall(function()
    session:enableSweep()
  end)
  ArtifactJobs.completeJobs = realCompleteJobs
  if not ok then
    error(err, 0)
  end
  Assert.equal(#pool.submitted, 0, "authorization submits nothing by itself")
  session:enableSweep()
  Assert.equal(#pool.submitted, 0, "repeated authorization stays quiet")
end

-- Explicit complete builds keep bulk enrollment: several candidates enroll
-- before the first settles, without any warmup authorization.
function T.explicit_complete_build_enrolls_without_background_throttle()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-batch-generation", pool, backend)
  local ready, failure = session:requestComplete("required")
  Assert.isFalse(ready, "the complete build answers pending until the pump runs")
  Assert.isNil(failure, "registration reports no failure")
  for _ = 1, 3 do
    session:update()
  end
  Assert.isTrue(#pool.submitted >= 2, "explicit complete enrolls several candidates before the first settles")
  Assert.equal(session:status().sweepState, "idle", "batch completion needs no warmup authorization")
  for _, jobKey in ipairs(pool.submitted) do
    pool.states[jobKey] = "ready"
  end
  for _ = 1, 60 do
    session:update()
    for _, jobKey in ipairs(pool.submitted) do
      if pool.states[jobKey] == nil then
        pool.states[jobKey] = "ready"
      end
    end
  end
  local done, doneFailure = session:requestComplete("required")
  Assert.isTrue(done, "the complete build attests once drained")
  Assert.isNil(doneFailure, "attestation reports no failure")
end

-- Retirement drops the background cursor and authorization: no further
-- enrollment follows and authorization calls reject.
function T.retirement_stops_background_enrollment()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-retirement-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  session:retire()
  Assert.equal(pool.retiredEpoch, 1, "retirement releases the pool selection")
  local status = session:status()
  Assert.equal(status.enumerated, 0, "retirement drops every retained record")
  Assert.equal(status.sweepState, "idle", "retirement clears background authorization")
  local enableOk = pcall(function()
    session:enableSweep()
  end)
  Assert.isFalse(enableOk, "authorization after retirement rejects")
  local requestOk = pcall(function()
    session:requestJob("message-bank", "1", "sweep")
  end)
  Assert.isFalse(requestOk, "requests after retirement reject")
  pool.states[candidate] = "ready"
  Assert.equal(#pool.submitted, 1, "no enrollment follows retirement")
end

-- A failed background candidate stays an attributed terminal record, the
-- cursor moves on without retrying it, and exhaustion reports the
-- incomplete state instead of failing unrelated scopes.
function T.failed_background_candidate_advances_the_cursor_once()
  local backend = FakeCache.new()
  local pool = retryCapablePool()
  local session = warmingSession("warming-failure-generation", pool, backend)
  session:enableSweep()
  local candidate = pumpUntilSubmitted(session, pool, 20)
  pool.states[candidate] = { state = "failed", details = { error = "synthetic warming failure" } }
  for _ = 1, 10 do
    session:update()
  end
  local entry = assert(session.byKey[candidate], "the failed candidate keeps its record")
  Assert.isTrue(
    tostring(entry.failure):find("synthetic warming failure", 1, true) ~= nil,
    "the failure stays attributed: " .. tostring(entry.failure)
  )
  local submissions = 0
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey == candidate then
      submissions = submissions + 1
    end
  end
  Assert.equal(submissions, 1, "the failed background job never retries itself")
  local advanced = false
  for _, jobKey in ipairs(pool.submitted) do
    if jobKey ~= candidate then
      advanced = true
    end
  end
  Assert.isTrue(advanced, "the cursor moves past the failed candidate")
  local rounds = 0
  while session:status().sweepState == "warming" and rounds < 600 do
    rounds = rounds + 1
    session:update()
    for _, jobKey in ipairs(pool.submitted) do
      if pool.states[jobKey] == nil then
        pool.states[jobKey] = "ready"
      end
    end
  end
  Assert.equal(session:status().sweepState, "incomplete", "exhaustion reports the background failure")
  Assert.isTrue(
    tostring(session:status().sweepFailure):find("synthetic warming failure", 1, true) ~= nil,
    "the incomplete state names its cause"
  )
  Assert.equal(
    session.byKey[candidate].failure,
    session:status().sweepFailure,
    "the reported cause is the canonical record failure"
  )
end

return { metadata = { capabilities = {} }, tests = T }
