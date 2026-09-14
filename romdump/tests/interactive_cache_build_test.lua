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
local FakeCache = require("tests.support.FakeCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")

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
    mapCellKeys = {},
    interest = {},
    byKey = {},
    milestones = {},
    recorded = {},
    retired = false,
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

return { metadata = { capabilities = {} }, tests = T }
