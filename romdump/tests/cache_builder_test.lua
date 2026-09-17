-- CacheBuilder contract: buildVersions prepares every listed version with
-- the complete scope through one common generation session per version. A
-- matching attestation with a valid audit is a fast path that compiles
-- nothing; a strict success defers its new attestation until every requested
-- version satisfies the completion policy; accepted map exclusions and any
-- version failure publish no new attestation. The session, pool, cache, and
-- state modules are faked through package.loaded before CacheBuilder is
-- required, so delegation is exercised without a ROM or filesystem.

local Assert = require("tests.support.Assert")

-- Every module CacheBuilder requires at load that touches the host; each is
-- replaced with a fake. Pure vocabulary modules (ArtifactState, GameVersion,
-- contracts) stay real so requirement parsing and identity shape are proved.
local FAKE_PATHS = {
  "libs.storage.src.CacheFs",
  "romdump.src.source.RomFs",
  "romdump.src.DerivedCacheState",
  "romdump.src.ProducerFingerprint",
  "romdump.src.DerivedCacheAudit",
  "romdump.src.build.ArtifactJobs",
  "romdump.src.build.InteractiveCacheBuild",
  "romdump.src.build.CompilerPool",
}

local T = {}

local saved = {}
local env
local CacheBuilder

local function newEnv()
  return {
    identity = {
      versionId = "heartgold",
      generationId = "test-generation",
      producerId = "d" .. string.rep("1", 64),
    },
    readyKeys = {},
    failKeys = {},
    failureClasses = {},
    causeKeys = {},
    excludedKeys = {},
    milestones = {
      bootstrap = { "world-catalog:global", "field-camera:global" },
      ["field-core"] = { "world-catalog:global", "actors:global", "map:7" },
    },
    sessions = {},
    pools = {},
    shutdowns = 0,
    retires = 0,
    opens = {},
    closes = {},
    openFailures = {},
    dumpMarkers = {},
    stateStored = nil,
    stateMatches = false,
    auditAvailable = false,
    auditCalls = {},
    plansAvailable = true,
    planCalls = {},
    invalidatedVersions = {},
    publishes = {},
    updateRaise = nil,
    logLines = {},
  }
end

local function splitJobKey(jobKey)
  local kind, key = jobKey:match("^([^:]+):(.+)$")
  return kind, key
end

local function makeSession(pool, identity, sweepEnabled)
  local session = {
    pool = pool,
    identity = identity,
    sweepEnabled = sweepEnabled,
    requested = {},
    retired = false,
  }
  function session:_answer(jobKey)
    if env.updateRaise ~= nil then
      error(env.updateRaise, 0)
    end
    if env.failKeys[jobKey] ~= nil then
      return false, jobKey .. ": " .. env.failKeys[jobKey]
    end
    if env.excludedKeys[jobKey] then
      return false, jobKey .. ": source-planned exclusion"
    end
    if env.readyKeys[jobKey] or (self.completed ~= nil and self.completed[jobKey]) then
      return true, nil
    end
    return false, nil
  end
  function session:requestJob(kind, key, urgency)
    assert(not self.retired, "generation session is retired")
    assert(type(kind) == "string" and type(key) == "string", "job needs its canonical kind and key")
    assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
    local jobKey = kind .. ":" .. key
    self.requested[#self.requested + 1] = jobKey
    self.pool.requested[#self.pool.requested + 1] = jobKey
    return self:_answer(jobKey)
  end
  function session:requestMilestone(name, urgency)
    assert(not self.retired, "generation session is retired")
    assert(name == "bootstrap" or name == "field-core", "milestones accept only bootstrap or field-core")
    local members = env.milestones[name] or {}
    local failures = {}
    local ready = true
    for _, jobKey in ipairs(members) do
      local kind, key = splitJobKey(jobKey)
      local ok, failure = self:requestJob(kind, key, urgency)
      if failure ~= nil and not env.excludedKeys[jobKey] then
        failures[#failures + 1] = failure
      end
      if not ok and env.excludedKeys[jobKey] == nil then
        ready = false
      end
    end
    if #failures > 0 then
      return false, failures[1]
    end
    return ready, nil
  end
  function session:update()
    assert(not self.retired, "generation session is retired")
    if env.updateRaise ~= nil then
      error(env.updateRaise, 0)
    end
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
        self.completed[jobKey] = true
      end
    end
  end
  function session:status()
    local ready, failed = 0, 0
    local failures = {}
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] ~= nil then
        failed = failed + 1
        failures[#failures + 1] = jobKey .. ": " .. env.failKeys[jobKey]
      elseif env.excludedKeys[jobKey] then
        failed = failed + 1
        failures[#failures + 1] = jobKey .. ": source-planned exclusion"
      elseif self.completed[jobKey] or env.readyKeys[jobKey] then
        ready = ready + 1
      end
    end
    return {
      ready = ready,
      queued = 0,
      running = 0,
      failed = failed,
      failures = failures,
      enumerated = #self.requested,
      enumerationComplete = true,
      settled = true,
      planningPending = false,
    }
  end
  function session:outcomes()
    local list = {}
    local seen = {}
    self.completed = self.completed or {}
    for _, jobKey in ipairs(self.requested) do
      if seen[jobKey] == nil then
        seen[jobKey] = true
        local kind, key = splitJobKey(jobKey)
        local state, err, cause, failureClass = nil, nil, nil, nil
        if env.failKeys[jobKey] ~= nil then
          state = "failed"
          err = jobKey .. ": " .. env.failKeys[jobKey]
          cause = env.causeKeys ~= nil and env.causeKeys[jobKey] or nil
          failureClass = (env.failureClasses ~= nil and env.failureClasses[jobKey]) or "job"
        elseif env.excludedKeys[jobKey] then
          state = "failed"
          err = jobKey .. ": source-planned exclusion"
          failureClass = "source-exclusion"
        elseif self.completed[jobKey] or env.readyKeys[jobKey] then
          state = "successful"
        else
          state = "pending"
        end
        list[#list + 1] = {
          kind = kind,
          key = key,
          jobKey = jobKey,
          state = state,
          reused = false,
          error = err,
          causeJobKey = cause,
          failureClass = failureClass,
        }
      end
    end
    table.sort(list, function(left, right)
      return left.jobKey < right.jobKey
    end)
    return list
  end
  function session:retire()
    self.retired = true
    env.retires = env.retires + 1
  end
  return session
end

local function makeFakes()
  local fakes = {}
  fakes.CacheFs = {
    forVersion = function(versionId)
      return {
        versionId = versionId,
        read = function(_, path)
          if path == "rom-dump.complete" then
            return env.dumpMarkers[versionId] or ("g4-rom-dump-v1:" .. versionId .. ":deadbeef")
          end
          return nil
        end,
        loadLua = function()
          return env.stateStored
        end,
        remove = function()
          return true
        end,
      }
    end,
  }
  fakes.RomFs = {
    open = function(versionId)
      if env.openFailures[versionId] ~= nil then
        return nil, env.openFailures[versionId]
      end
      env.opens[#env.opens + 1] = versionId
      return {
        version = versionId,
        metadata = function()
          return { sha1 = string.rep("a", 40) }
        end,
        close = function()
          env.closes[#env.closes + 1] = versionId
        end,
      }
    end,
  }
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    matches = function(stored)
      return env.stateMatches and stored == env.stateStored
    end,
    invalidate = function(cacheFs)
      env.invalidatedVersions[#env.invalidatedVersions + 1] = cacheFs.versionId
    end,
    publish = function(_, identity)
      env.publishes[#env.publishes + 1] = identity
    end,
  }
  fakes.ProducerFingerprint = {
    checkoutBackend = function()
      return {}
    end,
    appBackend = function()
      return {}
    end,
    compute = function()
      return "d" .. string.rep("1", 64)
    end,
  }
  fakes.DerivedCacheAudit = {
    isAvailable = function(_, identity, plans)
      env.auditCalls[#env.auditCalls + 1] = identity ~= nil and identity.generationId or nil
      -- The probe reflects the pre-build cache state; once the session has
      -- drained, every requested job was rebuilt, so the strict gate passes.
      -- Later probes therefore always pass: repair fixed the damage.
      if #env.auditCalls > 1 then
        return true
      end
      assert(plans ~= nil, "the generation audit requires the published inventory")
      return env.auditAvailable
    end,
  }
  fakes.ArtifactJobs = {
    publishedPlans = function(_, identity)
      env.planCalls[#env.planCalls + 1] = identity ~= nil and identity.generationId or nil
      if env.plansAvailable == false then
        return nil, "no published source inventory"
      end
      return { stubInventoryFor = identity ~= nil and identity.generationId or nil }
    end,
  }
  fakes.CompilerPool = {
    new = function()
      local pool = { requested = {}, selected = nil }
      function pool:selectGeneration(identity, epoch)
        self.selected = { identity = identity, epoch = epoch }
      end
      function pool:update() end
      function pool:drain() end
      function pool:waitForProgress() end
      function pool:jobOutcome(_)
        return nil
      end
      function pool:shutdown()
        env.shutdowns = env.shutdowns + 1
      end
      env.pools[#env.pools + 1] = pool
      return pool
    end,
  }
  fakes.InteractiveCacheBuild = {
    new = function(options)
      assert(type(options) == "table", "generation session options are required")
      assert(type(options.identity) == "table", "generation session identity is required")
      assert(type(options.epoch) == "number", "generation session epoch is required")
      assert(type(options.pool) == "table", "generation session requires the process-owned pool")
      assert(type(options.sweepEnabled) == "boolean", "generation session sweep choice is required")
      local session = makeSession(options.pool, options.identity, options.sweepEnabled)
      env.sessions[#env.sessions + 1] = session
      return session
    end,
  }
  return fakes
end

local function testLog()
  return function(line)
    env.logLines[#env.logLines + 1] = line
  end
end

local function requestedSet(session)
  local set = {}
  for _, jobKey in ipairs(session.requested) do
    set[jobKey] = true
  end
  return set
end

local module = {
  beforeAll = function()
    -- Pure identity computation stays real; only the stateful attestation
    -- behavior (match/invalidate/publish) is faked.
    local realCurrent = require("romdump.src.DerivedCacheState").current
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
    fakes.DerivedCacheState.current = realCurrent
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = fakes[path:match("([^%.]+)$")]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = saved[path]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
  end,
  tests = T,
}

-- An empty version list is part of the function contract: no build runs and
-- the caller-facing error names the empty selection.
function T.empty_version_list_returns_no_ready_version_to_compile()
  env = newEnv()
  local report, err = CacheBuilder.buildVersions({}, { log = testLog() })
  Assert.isNil(report)
  Assert.equal(err, "no ready version to compile")
  Assert.deepEqual(env.logLines, { "build: no ready version to compile" })
  Assert.equal(#env.pools, 0, "no pool is created for an empty selection")
end

-- The complete scope drives one common session per version with the sweep
-- enabled, requests field core plus the mon summary, and publishes the
-- schema-2 attestation only after every version succeeds.
function T.complete_scope_delegates_to_one_common_session_per_version()
  env = newEnv()
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.equal(#env.sessions, 1, "one common session serves the version")
  Assert.isTrue(env.sessions[1].sweepEnabled, "an exhaustive client drains the sweep")
  local requested = requestedSet(env.sessions[1])
  Assert.isTrue(requested["world-catalog:global"], "field core is requested")
  Assert.isTrue(requested["actors:global"], "field core is requested")
  Assert.isTrue(requested["mon-summary:global"], "the mon summary is requested")
  Assert.equal(#env.publishes, 1, "a strict success publishes its attestation")
  local identity = env.publishes[1]
  Assert.equal(identity.versionId, "heartgold")
  Assert.equal(identity.mode, "development")
  Assert.equal(identity.producerId, "d" .. string.rep("1", 64))
  Assert.equal(identity.romSha1, string.rep("a", 40))
  Assert.equal(env.auditCalls[#env.auditCalls], identity.generationId, "strict success proves the generation")
  Assert.equal(env.shutdowns, 1, "the command shuts its pool down")
  Assert.equal(env.retires, 1, "the command retires its session")
end

-- A matching attestation with a valid audit is a fast path: no session, no
-- pool, no invalidation, and the current-style report line.
function T.matching_attestation_with_available_cache_compiles_nothing()
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(env.logLines, { "build-cache: heartgold current" })
  Assert.equal(#env.sessions, 0, "the fast path opens no session")
  Assert.equal(#env.pools, 0, "the fast path creates no pool")
  Assert.deepEqual(env.invalidatedVersions, {}, "a current cache is never invalidated")
  Assert.equal(#env.publishes, 0, "a current cache is never republished")
end

-- A matching identity with a damaged cache enters repair: the stale
-- attestation is invalidated before the rebuild and the strict success
-- publishes the new identity.
function T.damaged_cache_invalidates_before_repair_and_republishes()
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = false
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(env.invalidatedVersions, { "heartgold" })
  Assert.equal(#env.publishes, 1, "a strict repair republishes the attestation")
end

-- Missing planning metadata bypasses the current shortcut even with a
-- matching attestation: the command drains its session, and with no
-- inventory the strict gate still refuses attestation.
function T.missing_planning_metadata_bypasses_the_current_shortcut()
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = true
  env.plansAvailable = false
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(#env.sessions, 1, "missing plans request their normal dependency jobs")
  Assert.equal(#env.publishes, 0, "no inventory means no attestation")
end

-- Map compile failures fail the batch by default; with explicitly accepted
-- exclusions the batch succeeds partially but publishes no attestation.
function T.compile_exclusions_fail_the_batch_unless_allowed()
  env = newEnv()
  env.failKeys["map:7"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#env.publishes, 0, "a failed batch publishes no attestation")

  env = newEnv()
  env.failKeys["map:7"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  env.auditAvailable = true
  local accepted, acceptedErr = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", allowCompileExclusions = true, log = testLog() }
  )
  Assert.isNil(acceptedErr)
  Assert.deepEqual(accepted, { published = true, complete = false, exclusionCount = 1 })
  Assert.equal(#env.publishes, 0, "an exclusion-accepting batch never attests completeness")
end

-- A non-map failure is never hidden by the map-exclusion option.
function T.non_map_family_failure_is_never_hidden_by_map_exclusions()
  env = newEnv()
  env.failKeys["actors:global"] = "ACTOR_SOURCE_INVALID: injected actor rejection"
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout", allowCompileExclusions = true, log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(#env.publishes, 0, "a hidden family failure must never pass as partial success")
end

-- One version whose source fails to open is reported while the remaining
-- versions still run; the batch fails and no new attestation is published
-- for any version, while previously valid attestations are untouched.
function T.a_failed_version_continues_without_publishing_new_attestations()
  local Errors = require("libs.errors.src.Errors")
  env = newEnv()
  env.openFailures.heartgold = Errors.new("ROMFS_LOAD_FAILED", "injected open failure", {})
  env.auditAvailable = true
  local report, err = CacheBuilder.buildVersions(
    { "heartgold", "soulsilver" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.deepEqual(env.opens, { "soulsilver" })
  Assert.deepEqual(env.closes, { "soulsilver" })
  Assert.equal(#env.sessions, 1, "the remaining version still prepares through its session")
  Assert.equal(#env.publishes, 0, "a failed batch defers every new attestation")
end

-- A previously valid attestation for an unaffected version is preserved when
-- another version fails: the fast path never invalidates.
function T.valid_attestations_for_unaffected_versions_are_preserved()
  local Errors = require("libs.errors.src.Errors")
  env = newEnv()
  env.stateStored = { schema = 2, generationId = "test-generation" }
  env.stateMatches = true
  env.auditAvailable = true
  env.openFailures.soulsilver = Errors.new("ROMFS_LOAD_FAILED", "injected open failure", {})
  local report, err = CacheBuilder.buildVersions(
    { "heartgold", "soulsilver" },
    { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
  )
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.deepEqual(env.invalidatedVersions, {}, "the unaffected version keeps its attestation")
  Assert.equal(env.logLines[1], "build-cache: heartgold current")
end

-- A programming fault inside a version's preparation rethrows after session
-- retirement and pool shutdown instead of becoming a failed-version report.
function T.a_programming_fault_rethrows_after_cleanup()
  env = newEnv()
  env.updateRaise = "boom"
  local raised = Assert.throws(function()
    CacheBuilder.buildVersions(
      { "heartgold" },
      { dev = true, developmentRepositoryRoot = "/checkout", log = testLog() }
    )
  end)
  Assert.equal(raised, "boom", "the original fault must propagate unchanged")
  Assert.equal(env.retires, 1, "the faulting session is retired")
  Assert.equal(env.shutdowns, 1, "the owned pool is shut down")
  Assert.equal(#env.publishes, 0, "a faulting batch publishes no attestation")
end

-- The log option defaults to print, the plain-Lua output of the CLI.
function T.log_defaults_to_print()
  env = newEnv()
  env.auditAvailable = true
  local lines = {}
  local realPrint = print
  _G.print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  local ok, report, err = pcall(
    CacheBuilder.buildVersions,
    { "heartgold" },
    { dev = true, developmentRepositoryRoot = "/checkout" }
  )
  _G.print = realPrint
  Assert.isTrue(ok, tostring(report))
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.isTrue(#lines > 0, "the build reports its progress")
end

return module
