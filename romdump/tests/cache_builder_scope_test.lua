-- Scoped cache preparation drives one common generation session per version:
-- a targeted closure runs only its declared dependencies and never publishes
-- full-build attestation, an exhaustive scope attests only strict success,
-- and opt-in profiling observes without changing job identity. The session,
-- pool, cache, and state modules are faked through package.loaded before
-- CacheBuilder is required, so scope policy is exercised without a ROM.

local Assert = require("tests.support.Assert")

local FAKE_PATHS = {
  "libs.storage.src.CacheFs",
  "romdump.src.DerivedCacheState",
  "romdump.src.DerivedCacheAudit",
  "romdump.src.build.ArtifactJobs",
  "romdump.src.ProducerFingerprint",
  "romdump.src.build.InteractiveCacheBuild",
  "romdump.src.build.CompilerPool",
  "romdump.src.source.RomSource",
}

local saved = {}
local env
local CacheBuilder

local function newEnv()
  return {
    identity = {
      versionId = "heartgold",
      romSha1 = string.rep("b", 40),
      generationId = "test-generation",
      producerId = "d" .. string.rep("1", 64),
    },
    readyKeys = {},
    failKeys = {},
    failureClasses = {},
    causeKeys = {},
    excludedKeys = {},
    milestones = {
      bootstrap = { "field-camera:global", "message-bank:219" },
      ["field-core"] = { "field-camera:global", "map-data:7", "script-member:0" },
    },
    sessions = {},
    pools = {},
    cacheWrites = {},
    stateMatches = false,
    auditAvailable = false,
    plansAvailable = true,
    invalidations = 0,
    publishes = 0,
    publishedIdentity = nil,
    waitCalls = 0,
    localRounds = nil,
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
    if env.failKeys[jobKey] ~= nil then
      return false, jobKey .. ": " .. env.failKeys[jobKey]
    end
    if env.excludedKeys[jobKey] then
      return false, jobKey .. ": source-planned exclusion"
    end
    if env.readyKeys[jobKey] or self.completed ~= nil and self.completed[jobKey] then
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
    self.completed = self.completed or {}
    local function completeAll()
      for _, jobKey in ipairs(self.requested) do
        if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
          self.completed[jobKey] = true
        end
      end
    end
    if env.localRounds ~= nil then
      if env.localRounds > 0 then
        env.localRounds = env.localRounds - 1
      end
      if env.localRounds == 0 then
        completeAll()
      end
    else
      completeAll()
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
    local localPending = env.localRounds ~= nil and env.localRounds > 0
    local settled = true
    for _, jobKey in ipairs(self.requested) do
      if env.failKeys[jobKey] == nil and env.excludedKeys[jobKey] == nil then
        if not (self.completed[jobKey] or env.readyKeys[jobKey]) then
          settled = false
          break
        end
      end
    end
    if localPending then
      settled = false
    end
    return {
      ready = ready,
      failed = failed,
      failures = failures,
      enumerated = #self.requested,
      enumerationComplete = true,
      queued = 0,
      running = 0,
      settled = settled,
      planningPending = localPending,
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
        local state, err, cause = nil, nil, nil
        if env.failKeys[jobKey] ~= nil then
          state = "failed"
          err = jobKey .. ": " .. env.failKeys[jobKey]
          cause = env.causeKeys ~= nil and env.causeKeys[jobKey] or nil
        elseif env.excludedKeys[jobKey] then
          state = "failed"
          err = jobKey .. ": source-planned exclusion"
        elseif self.completed[jobKey] or env.readyKeys[jobKey] then
          state = "successful"
        else
          state = "pending"
        end
        local failureClass = nil
        if state == "failed" then
          if env.excludedKeys[jobKey] then
            failureClass = "source-exclusion"
          else
            failureClass = (env.failureClasses ~= nil and env.failureClasses[jobKey]) or "job"
          end
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
  end
  return session
end

local function makeFakes()
  local fakes = {}
  fakes.CacheFs = {
    forVersion = function(versionId)
      return {
        versionId = versionId,
        write = function(_, path)
          env.cacheWrites[#env.cacheWrites + 1] = versionId .. ":" .. path
        end,
        read = function()
          return nil
        end,
        loadLua = function()
          return nil
        end,
        remove = function()
          return true
        end,
      }
    end,
  }
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    current = function(inputs)
      return { versionId = inputs.versionId, generationId = env.identity.generationId }
    end,
    matches = function()
      return env.stateMatches
    end,
    invalidate = function()
      env.invalidations = env.invalidations + 1
    end,
    publish = function(_, identity)
      env.publishes = env.publishes + 1
      env.publishedIdentity = identity
    end,
  }
  fakes.DerivedCacheAudit = {
    isAvailable = function(_, identity, plans)
      assert(identity ~= nil and plans ~= nil, "the generation audit requires identity and inventory")
      return env.auditAvailable
    end,
  }
  fakes.ArtifactJobs = {
    publishedPlans = function()
      if env.plansAvailable == false then
        return nil, "no published source inventory"
      end
      return { stubInventory = true }
    end,
  }
  fakes.ProducerFingerprint = {
    appBackend = function()
      return {}
    end,
    compute = function()
      return "producer-fingerprint"
    end,
  }
  fakes.CompilerPool = {
    new = function()
      local pool = { requested = {}, selected = nil }
      function pool:selectGeneration(identity, epoch)
        self.selected = { identity = identity, epoch = epoch }
      end
      function pool:update() end
      function pool:waitForProgress()
        env.waitCalls = (env.waitCalls or 0) + 1
      end
      function pool:drain()
        env.waitCalls = (env.waitCalls or 0) + 1
      end
      function pool:jobOutcome(_)
        return nil
      end
      function pool:shutdown() end
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
  fakes.RomSource = {
    fromPath = function()
      return nil, "rom source is faked out of the scope contract"
    end,
  }
  return fakes
end

local function scopedOptions(overrides)
  local options = {
    identity = env.identity,
    requirements = { "map:7" },
    allowCompileExclusions = false,
    log = function() end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

local function requireScopedPreparation()
  Assert.equal(
    type(CacheBuilder.prepareVersion),
    "function",
    "scoped preparation must drive one common session per version"
  )
end

local T = {}

local module = {
  beforeAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
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

-- A single map request runs only its declared closure: unrelated families
-- never reach the pool, and no full-build attestation is published even
-- though the requested scope succeeds.
function T.targeted_map_request_runs_only_its_closure_without_full_attestation()
  env = newEnv()
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:7" } }))
  Assert.isNil(err)
  Assert.isTrue(report.requestedReady, "the requested closure must be ready")
  Assert.isFalse(report.complete, "a targeted scope must never report a complete cache")
  Assert.equal(#env.sessions, 1, "one common session serves the targeted scope")
  Assert.isFalse(env.sessions[1].sweepEnabled, "a targeted client must not start an unrelated sweep")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["map:7"], "the requested map must run")
  Assert.isNil(requested["map:5"], "an unrelated map must never be requested")
  Assert.isNil(requested["audio-bank:3"], "an unrelated audio bank must never be requested")
  Assert.equal(env.publishes, 0, "a targeted scope must never publish full attestation")
  local planned = report.counts.successful + report.counts.failed + report.counts.cancelled + report.counts.excluded
  Assert.equal(planned, report.counts.planned, "every planned key lands in exactly one outcome category")
end

-- A source-resolved map whose compiler fails aborts the command by default:
-- the failure names its canonical key, nothing is attested, and the staged
-- replacement never becomes authoritative.
function T.unaccepted_map_failure_fails_without_full_attestation()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:5" } }))
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(#env.sessions, 1, "the failure is observed through the common session")
  local status = env.sessions[1]:status()
  Assert.equal(status.failed, 1, "the failed job stays visible")
  Assert.isTrue(status.failures[1]:find("map:5", 1, true) ~= nil, "the failure names its canonical key")
  Assert.equal(env.publishes, 0, "a failed command publishes no full attestation")
end

-- With explicitly accepted exclusions the exploratory run succeeds partially:
-- the report carries complete=false with the excluded key listed, and no
-- complete attestation is published.
function T.accepted_map_exclusions_report_partial_success_without_full_attestation()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5", "map:7" },
      allowCompileExclusions = true,
    })
  )
  Assert.isNil(err)
  Assert.isFalse(report.complete, "an exclusion-accepting run must never claim completeness")
  Assert.equal(#report.exclusions, 1, "the excluded map is reported")
  Assert.isTrue(report.exclusions[1]:find("map:5", 1, true) ~= nil, "the exclusion names its canonical key")
  Assert.equal(env.publishes, 0, "an exclusion-accepting run must not publish full attestation")
  local planned = report.counts.successful + report.counts.failed + report.counts.cancelled + report.counts.excluded
  Assert.equal(planned, report.counts.planned, "every planned key lands in exactly one outcome category")
end

-- The map-exclusion option accepts only map compile failures: an audio
-- failure still fails the command even when exclusions are allowed.
function T.non_map_family_failure_is_never_hidden_by_map_exclusions()
  env = newEnv()
  env.failKeys["audio-bank:3"] = "AUDIO_SOURCE_INVALID: injected audio rejection"
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "audio-bank:3" },
      allowCompileExclusions = true,
    })
  )
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(env.publishes, 0, "a hidden audio failure must never pass as partial success")
end

-- A matching full attestation with valid receipts is a fast path: no source
-- compilation runs and the existing current state is reused.
function T.warm_matching_attestation_compiles_nothing()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(err)
  Assert.isTrue(report.complete, "the warm cache stays complete")
  Assert.equal(#env.pools, 0, "the fast path must not create a compiler pool")
  Assert.equal(#env.sessions, 0, "the fast path must not open a generation session")
  Assert.equal(env.invalidations, 0, "a current cache must not be invalidated")
  Assert.equal(env.publishes, 0, "a current cache must not be republished")
end

-- Missing planning metadata bypasses the warm shortcut: the command drains
-- its session instead of reporting current, and the strict gate still
-- refuses attestation without an inventory.
function T.missing_planning_metadata_bypasses_the_warm_shortcut()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  env.plansAvailable = false
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "complete" } }))
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.equal(#env.sessions, 1, "missing plans run the normal session")
  Assert.equal(env.publishes, 0, "no inventory means no attestation")
end

-- Opt-in profiling records every failed job with its cause and closes with a
-- partial census: observation never changes job identity or scope.
function T.profile_log_captures_failed_jobs_with_a_partial_census()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local profilePath = os.tmpname()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5", "map:7" },
      allowCompileExclusions = true,
      profile = profilePath,
    })
  )
  Assert.isNil(err)
  Assert.isFalse(report.complete, "the profiled run stays partial")
  local handle = assert(io.open(profilePath, "r"))
  local body = handle:read("*a")
  handle:close()
  os.remove(profilePath)
  Assert.isTrue(body:find("g4-cache-execution-v2", 1, true) ~= nil, "the log carries its execution schema")
  Assert.isTrue(body:find("map:5", 1, true) ~= nil, "the failed job remains in the log")
  Assert.isTrue(body:find("failed", 1, true) ~= nil, "the failed outcome remains in the log")
  Assert.isTrue(body:find("complete", 1, true) ~= nil, "the footer records completion scope")
  Assert.isNil(body:find("payload", 1, true), "profile output must not retain asset payloads")
end

-- An explicit development rebuild reruns only the selected ready job: its
-- dependencies are reused, the stale completion proof is invalidated first,
-- and staged publication invariants still hold.
function T.explicit_rebuild_reruns_only_the_selected_job()
  env = newEnv()
  env.readyKeys["map:7"] = true
  env.readyKeys["map-data:7"] = true
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7" },
      rebuild = { "map:7" },
      dev = true,
    })
  )
  Assert.isNil(err)
  Assert.isTrue(report.requestedReady, "the rebuilt job must be ready")
  local requested = {}
  for _, jobKey in ipairs(env.sessions[1].requested) do
    requested[jobKey] = true
  end
  Assert.isTrue(requested["map:7"], "the selected job reruns")
  Assert.isNil(requested["map:5"], "unrelated jobs must not rerun")
  Assert.isTrue(env.invalidations >= 1, "a forced repair invalidates the stale completion proof first")
end

-- Malformed requirement strings fail before any cache mutation: unknown
-- kinds, signed keys, padded keys, paths, plan files, empty requirement
-- lists, and a missing version never open a session or write cache state.
function T.malformed_requests_fail_before_any_cache_mutation()
  env = newEnv()
  requireScopedPreparation()
  local badRequirementSets = {
    { "fused:7" },
    { "map:-7" },
    { "map: 7" },
    { "map:7 " },
    { "maps/7/complete" },
    { "plan.lua" },
    { "map:" },
    { ":7" },
  }
  for _, requirements in ipairs(badRequirementSets) do
    local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = requirements }))
    Assert.isNil(report, "malformed requirement must fail: " .. requirements[1])
    Assert.notNil(err)
  end
  local emptyReport, emptyErr = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = {} }))
  Assert.isNil(emptyReport)
  Assert.notNil(emptyErr)
  local missingReport, missingErr = CacheBuilder.prepareVersion(nil, scopedOptions({}))
  Assert.isNil(missingReport)
  Assert.notNil(missingErr)
  Assert.equal(#env.sessions, 0, "no malformed request may open a generation session")
  Assert.deepEqual(env.cacheWrites, {}, "no malformed request may mutate cache state")
  Assert.equal(env.publishes, 0, "no malformed request may publish attestation")
end

-- A successful targeted scope issues the invocation receipt from the actual
-- report: the exact revision shape names the real save directory, version,
-- source hash, current generation, and the sorted satisfied closure.
function T.successful_scope_issues_an_invocation_receipt_from_its_report()
  env = newEnv()
  requireScopedPreparation()
  local recordPath = os.tmpname()
  os.remove(recordPath)
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7", "bootstrap" },
      preparationRecord = recordPath,
      saveDirectory = "/private/test-root",
    })
  )
  Assert.isNil(err)
  assert(report, "a successful preparation returns its report")
  local handle = assert(io.open(recordPath, "r"), "a successful scope must issue its receipt")
  local source = handle:read("*a")
  handle:close()
  os.remove(recordPath)
  local chunk = assert(load(source, "@receipt", "t", {}))
  local record = chunk()
  Assert.equal(record.schema, "g4-test-preparation-v2")
  Assert.equal(record.saveDirectory, "/private/test-root")
  Assert.equal(record.versionId, "heartgold")
  Assert.equal(record.romSha1, env.identity.romSha1)
  Assert.equal(record.generationId, env.identity.generationId)
  Assert.deepEqual(record.requested, { "bootstrap", "map:7" })
  Assert.isTrue(report.requestedReady)
  Assert.equal(record.requestedReady, true)
  Assert.equal(record.complete, false)
end

-- The warm shortcut still issues proof: reuse is decided by the strong
-- check, and the receipt records the complete corpus it verified.
function T.warm_reuse_issues_an_invocation_receipt_without_recompiling()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  requireScopedPreparation()
  local recordPath = os.tmpname()
  os.remove(recordPath)
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "complete" },
      preparationRecord = recordPath,
      saveDirectory = "/private/test-root",
    })
  )
  Assert.isNil(err)
  assert(report, "a warm preparation returns its report")
  Assert.equal(#env.sessions, 0, "the fast path must not open a generation session")
  local handle = assert(io.open(recordPath, "r"), "warm reuse must still issue its receipt")
  handle:close()
  os.remove(recordPath)
end

-- A receipt that cannot be written fails the command: no readiness is
-- forged and the failure is structured.
function T.unwritable_receipt_fails_the_command_without_forging_readiness()
  env = newEnv()
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:7" },
      preparationRecord = "/nonexistent-dir-xyz/preparation.lua",
      saveDirectory = "/private/test-root",
    })
  )
  Assert.isNil(report)
  Assert.notNil(err)
  local Errors = require("libs.errors.src.Errors")
  Assert.isTrue(Errors.is(err), "receipt failures are structured")
end

-- A failed scope issues no receipt: only a satisfied closure proves
-- readiness.
function T.failed_scope_issues_no_receipt()
  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local recordPath = os.tmpname()
  os.remove(recordPath)
  local report, err = CacheBuilder.prepareVersion(
    "heartgold",
    scopedOptions({
      requirements = { "map:5" },
      preparationRecord = recordPath,
      saveDirectory = "/private/test-root",
    })
  )
  Assert.isNil(report)
  Assert.notNil(err)
  local handle = io.open(recordPath, "r")
  Assert.isNil(handle, "a failed scope must leave no successful receipt behind")
  if handle ~= nil then
    handle:close()
  end
  os.remove(recordPath)
end

-- Deferred planning is local progress, not physical waiting: the drain
-- repumps a session with runnable planning work while its pool is idle,
-- never waits on nonexistent work, terminates an ordinary producer
-- failure with its actual cause, and retires the session so no further
-- work is accepted.
function T.drain_distinguishes_local_planning_from_physical_waiting()
  env = newEnv()
  env.localRounds = 3
  requireScopedPreparation()
  local report, err = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:7" } }))
  Assert.isNil(err)
  assert(report, "local planning must drain to a report")
  Assert.isTrue(report.requestedReady, "deferred planning repumps until the session settles")
  Assert.equal(env.waitCalls, 0, "the drain never waits on nonexistent physical work")
  Assert.isTrue(env.sessions[1].retired, "the drained session retires")
  local requestOk = pcall(function()
    env.sessions[1]:requestJob("map", "7", "required")
  end)
  Assert.isFalse(requestOk, "a retired session accepts no further work")

  env = newEnv()
  env.failKeys["map:5"] = "MAP_SCHEMA_INVALID: injected compile rejection"
  requireScopedPreparation()
  local badReport, badErr = CacheBuilder.prepareVersion("heartgold", scopedOptions({ requirements = { "map:5" } }))
  Assert.isNil(badReport)
  Assert.isTrue(
    tostring(badErr):find("map:5", 1, true) ~= nil,
    "an ordinary producer failure terminates with its actual cause"
  )
end

return module
