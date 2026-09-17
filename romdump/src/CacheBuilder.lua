-- Exhaustive and targeted cache preparation through the common generation
-- session. buildVersions prepares every listed version with the complete
-- scope; prepareVersion prepares one version with a declared closure. Both
-- drive InteractiveCacheBuild jobs and validate the requested scope. Full
-- attestation at data/generated/build.lua is published only after strict
-- exhaustive success validated by the generation-aware audit; a targeted
-- scope never attests completeness no matter its exit status.

local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local GameVersion = require("romdump.src.source.GameVersion")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local ArtifactState = require("romdump.src.build.ArtifactState")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local CompilerPool = require("romdump.src.build.CompilerPool")
local Schema = require("libs.script.src.Schema")
local LuaWriter = require("libs.codec.src.LuaWriter")

local CacheBuilder = {}

-- Closed preparation scopes: the fixed milestones plus the exhaustive scope.
-- Anything else must be a canonical kind:key pair owned by ArtifactState.
local SCOPES = {
  bootstrap = true,
  ["field-core"] = true,
  complete = true,
}

local PROFILE_SCHEMA = "g4-cache-execution-v2"

local epochCounter = 0

---@class CacheBuilder.Requirement
---@field scope string|nil closed scope word when the requirement names a milestone scope
---@field kind string|nil canonical job kind when the requirement names a job
---@field key string|nil canonical job key when the requirement names a job
---@field jobKey string|nil canonical kind:key identity when the requirement names a job

---@param text string
---@return CacheBuilder.Requirement|nil entry
---@return Errors.Error|string|nil err
function CacheBuilder.parseRequirement(text)
  if type(text) ~= "string" or text == "" then
    return nil, Errors.new("INVALID_CACHE_REQUIREMENT", "cache requirement must be a non-empty string", {})
  end
  if SCOPES[text] then
    return { scope = text }
  end
  local kind, key = text:match("^([^:]+):(.+)$")
  if kind == nil or not pcall(ArtifactState.path, kind, key) then
    return nil, Errors.new("INVALID_CACHE_REQUIREMENT", "unknown cache requirement: " .. text, { requirement = text })
  end
  return { kind = kind, key = key, jobKey = kind .. ":" .. key }
end

---@param requirements string[]
---@return string[]|nil ordered
---@return CacheBuilder.Requirement[]|nil parsed
---@return Errors.Error|string|nil err
local function parseRequirements(requirements)
  if type(requirements) ~= "table" or #requirements == 0 then
    return nil, nil, Errors.new("INVALID_CACHE_REQUIREMENT", "preparation requires at least one requirement", {})
  end
  local seen, ordered, parsed = {}, {}, {}
  for _, text in ipairs(requirements) do
    local entry, err = CacheBuilder.parseRequirement(text)
    if entry == nil then
      return nil, nil, err
    end
    if not seen[text] then
      seen[text] = true
      ordered[#ordered + 1] = text
      parsed[#parsed + 1] = entry
    end
  end
  return ordered, parsed, nil
end

local JSON_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
}

---@param value string
---@return string
local function jsonString(value)
  return '"'
    .. value:gsub('[%z\1-\31\\"]', function(char)
      if JSON_ESCAPES[char] then
        return JSON_ESCAPES[char]
      end
      return string.format("\\u%04x", char:byte())
    end)
    .. '"'
end

-- Explicit JSON null for profile rows: Lua tables cannot hold nil, so
-- missing measurements use this marker to encode as null instead of being
-- omitted. Report outcomes (Lua tables) keep plain nil.
local function jsonNullToString()
  return "null"
end

local JSON_NULL = setmetatable({}, {
  __tostring = jsonNullToString,
})

---@param value unknown
---@return string
local function jsonValue(value)
  if value == nil or value == JSON_NULL then
    return "null"
  end
  local kind = type(value)
  if kind == "string" then
    return jsonString(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, "profile timings must be finite")
    return tostring(value)
  end
  if kind == "table" then
    local array = true
    local count = 0
    for key in pairs(value) do
      count = count + 1
      if type(key) ~= "number" or key ~= count then
        array = false
        break
      end
    end
    if array then
      local parts = {}
      for index, entry in ipairs(value) do
        parts[index] = jsonValue(entry)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for index, key in ipairs(keys) do
      parts[index] = jsonString(tostring(key)) .. ":" .. jsonValue(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("profile values must be scalars, arrays, or records", 0)
end

---@return integer|nil pid
---@return string|nil reason
local function processPid()
  local handle = io.open("/proc/self/stat", "r")
  if handle == nil then
    return nil, "process identity is unavailable outside Linux procfs"
  end
  local body = handle:read("*a")
  handle:close()
  local pid = body ~= nil and body:match("^(%d+)") or nil
  if pid == nil then
    return nil, "process stat has no leading pid"
  end
  local value = tonumber(pid)
  assert(type(value) == "number" and value % 1 == 0, "process stat pid must be an integer")
  return math.floor(value)
end

---@return integer|nil count
---@return string|nil reason
local function logicalCpus()
  local host = rawget(_G, "love")
  if host and host.system and type(host.system.getProcessorCount) == "function" then
    local ok, count = pcall(host.system.getProcessorCount)
    if ok and type(count) == "number" and count >= 1 then
      return math.floor(count)
    end
  end
  local handle = io.open("/proc/cpuinfo", "r")
  if handle == nil then
    return nil, "processor count is unavailable on this host"
  end
  local body = handle:read("*a")
  handle:close()
  local count = 0
  for _ in (body or ""):gmatch("^processor%s*:") do
    count = count + 1
  end
  if count == 0 then
    return nil, "processor count is unavailable on this host"
  end
  return count
end

---@return string|nil version
---@return string|nil reason
local function loveVersion()
  local host = rawget(_G, "love")
  if host == nil or type(host.getVersion) ~= "function" then
    return nil, "the command is not running under LOVE"
  end
  local ok, major, minor, revision = pcall(host.getVersion)
  if not ok or type(major) ~= "number" or type(minor) ~= "number" then
    return nil, "the LOVE version is unreadable"
  end
  if type(revision) == "number" then
    return string.format("%d.%d.%d", major, minor, revision)
  end
  return string.format("%d.%d", major, minor)
end

---@param identity table<string, unknown>
---@param command string
---@param requirements string[]
---@param epoch integer
---@return table<string, unknown>
local function profileHeader(identity, command, requirements, epoch)
  local pid, pidReason = processPid()
  local cpus, cpuReason = logicalCpus()
  local love, loveReason = loveVersion()
  local jitVersion = rawget(_G, "jit") and _G.jit.version or nil
  return {
    type = "header",
    schema = PROFILE_SCHEMA,
    versionId = identity.versionId,
    generationId = identity.generationId,
    romSha1 = identity.romSha1,
    romSha1Reason = identity.romSha1 == nil and "the generation identity carries no ROM hash" or nil,
    producerId = identity.producerId,
    mode = identity.mode,
    modeReason = identity.mode == nil and "the generation identity carries no execution mode" or nil,
    repositoryCommit = nil,
    repositoryCommitReason = "the checkout revision is recorded externally alongside producer identity",
    processPid = pid,
    processPidReason = pid == nil and pidReason or nil,
    logicalCpus = cpus,
    logicalCpusReason = cpus == nil and cpuReason or nil,
    loveVersion = love,
    loveVersionReason = love == nil and loveReason or nil,
    luaVersion = jitVersion or _VERSION,
    timingMode = "wall",
    command = command,
    requirements = requirements,
    epoch = epoch,
  }
end

-- Resolve per-job observation timings from the pool's exact outcome snapshot
-- taken at finalization time. Missing measurements stay null with reasons,
-- never zero. The bounded diagnostic ring is diagnostics-only and never
-- consulted here.
---@param pool table<string, unknown>|nil
---@param jobKey string
---@return table<string, unknown>
local function observeTimings(pool, jobKey)
  if type(pool) == "table" and type(pool.jobOutcome) == "function" then
    local ok, outcome = pcall(pool.jobOutcome, pool, jobKey)
    if ok and type(outcome) == "table" then
      return {
        compileSeconds = outcome.compileSeconds,
        compileSecondsReason = outcome.compileSeconds == nil and "timing is unavailable for this job" or nil,
        stageSeconds = outcome.stageSeconds,
        stageSecondsReason = outcome.stageSeconds == nil and "timing is unavailable for this job" or nil,
        publicationSeconds = nil,
        publicationSecondsReason = "publication time is not separated from worker reports",
        workSeconds = outcome.workSeconds,
        workSecondsReason = outcome.workSeconds == nil and "timing is unavailable for this job" or nil,
        stagedBytes = outcome.stagedBytes,
        stagedBytesReason = outcome.stagedBytes == nil and "timing is unavailable for this job" or nil,
        timingReason = outcome.timingReason,
        timingReasonReason = outcome.timingReason == nil and "per-job timing detail is not published by the pool"
          or nil,
        workerId = outcome.workerId,
        workerIdReason = outcome.workerId == nil and "the job did not execute through the compiler pool" or nil,
      }
    end
  end
  return {
    compileSeconds = nil,
    compileSecondsReason = "timing is unavailable for this job",
    stageSeconds = nil,
    stageSecondsReason = "timing is unavailable for this job",
    publicationSeconds = nil,
    publicationSecondsReason = "publication time is not separated from worker reports",
    workSeconds = nil,
    workSecondsReason = "timing is unavailable for this job",
    stagedBytes = nil,
    stagedBytesReason = "timing is unavailable for this job",
    timingReason = nil,
    timingReasonReason = "per-job timing detail is not published by the pool",
    workerId = nil,
    workerIdReason = "the job did not execute through the compiler pool",
  }
end

---@param handle table<string, function>|nil
---@param record table<string, unknown>
---@return Errors.Error|string|nil err
local function writeProfileLine(handle, record)
  if handle == nil then
    return nil
  end
  local ok, encoded = pcall(jsonValue, record)
  if not ok then
    return Errors.new("PROFILE_ENCODE_FAILED", "execution evidence cannot be encoded", {})
  end
  local callOk, result, writeErr = pcall(handle.write, handle, encoded .. "\n")
  if not callOk then
    return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be written: " .. tostring(result), {})
  end
  if result == nil then
    return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be written: " .. tostring(writeErr), {})
  end
  return nil
end

---@param versionId string
---@return Errors.Error|string|nil err
local function checkVersion(versionId)
  if type(versionId) ~= "string" or GameVersion.VERSIONS[versionId] == nil then
    return Errors.new("UNSUPPORTED_VERSION", "unsupported version: " .. tostring(versionId), { versionId = versionId })
  end
  return nil
end

---@param identity table<string, unknown>|nil
---@param versionId string
---@return Errors.Error|string|nil err
local function checkIdentity(identity, versionId)
  if type(identity) ~= "table" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "preparation requires a generation identity", {})
  end
  if identity.versionId ~= versionId then
    return Errors.new(
      "INVALID_GENERATION_IDENTITY",
      "generation identity version does not match the prepared version",
      { versionId = versionId }
    )
  end
  if type(identity.generationId) ~= "string" or identity.generationId == "" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "generation identity carries no generation", {})
  end
  if type(identity.producerId) ~= "string" or identity.producerId == "" then
    return Errors.new("INVALID_GENERATION_IDENTITY", "generation identity carries no producer", {})
  end
  return nil
end

---@param rebuild string[]|nil
---@param parsed CacheBuilder.Requirement[]
---@param ordered string[]
---@param dev boolean|nil
---@return { kind: string, key: string, jobKey: string }[]|nil jobs
---@return Errors.Error|string|nil err
local function checkRebuild(rebuild, parsed, ordered, dev)
  if rebuild == nil or #rebuild == 0 then
    return {}
  end
  if dev ~= true then
    return nil, Errors.new("INVALID_REBUILD", "explicit rebuild requires development mode", {})
  end
  local exhaustive = false
  local required = {}
  for index, _ in ipairs(ordered) do
    local entry = parsed[index]
    if entry.scope == "complete" then
      exhaustive = true
    elseif entry.jobKey ~= nil then
      required[entry.jobKey] = true
    end
  end
  local jobs = {}
  local seenRebuild = {}
  for _, text in ipairs(rebuild) do
    local entry, err = CacheBuilder.parseRequirement(text)
    if entry == nil then
      return nil, err
    end
    if entry.scope ~= nil or entry.jobKey == nil then
      return nil, Errors.new("INVALID_REBUILD", "rebuild accepts only a canonical job: " .. text, { job = text })
    end
    local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
    local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
    local jobKey = assert(entry.jobKey, "parsed requirements are scopes or canonical jobs")
    if not exhaustive and not required[jobKey] then
      return nil, Errors.new("INVALID_REBUILD", "rebuild job is not in the requested scope: " .. text, { job = text })
    end
    if not seenRebuild[jobKey] then
      seenRebuild[jobKey] = true
      jobs[#jobs + 1] = { kind = kind, key = key, jobKey = jobKey }
    end
  end
  return jobs
end

---@class CacheBuilder.SessionStatus
---@field ready integer|nil
---@field queued integer|nil
---@field running integer|nil
---@field failed integer|nil
---@field failures string[]|nil
---@field enumerated integer|nil
---@field settled boolean|nil
---@field planningPending boolean|nil

---@param pool CompilerPool
---@param session InteractiveCacheBuild
---@param versionId string
---@param log fun(line: string)
---@return CacheBuilder.SessionStatus status
local function drainSession(pool, session, versionId, log)
  local rounds = 0
  local lastReady, lastFailed = -1, -1
  local function poolSummary()
    if type(pool.diagnostics) ~= "function" then
      return "pool=?"
    end
    local ok, diagnostics = pcall(pool.diagnostics, pool)
    if not ok or type(diagnostics) ~= "table" or type(diagnostics.counts) ~= "table" then
      return "pool=?"
    end
    local counts = diagnostics.counts
    local active = {}
    if type(diagnostics.activeJobKeys) == "table" then
      for index, jobKey in ipairs(diagnostics.activeJobKeys) do
        if index > 3 then
          break
        end
        active[#active + 1] = tostring(jobKey)
      end
    end
    return string.format(
      "pool q=%d run=%d prep=%d workers=%s heap=%s active=%s",
      counts.queued or 0,
      counts.running or 0,
      counts.prepared or 0,
      tostring(diagnostics.workerStates),
      tostring(diagnostics.heapStates),
      table.concat(active, ",")
    )
  end
  while true do
    rounds = rounds + 1
    assert(rounds <= 100000, "preparation did not settle")
    session:update()
    local status = session:status() --[[@as CacheBuilder.SessionStatus]]
    if type(status.settled) ~= "boolean" or type(status.planningPending) ~= "boolean" then
      error("generation session reports no settled/planningPending progress facts", 0)
    end
    local failed = #(status.failures or {})
    if (status.ready or 0) ~= lastReady or failed ~= lastFailed then
      lastReady, lastFailed = status.ready or 0, failed
      log(
        string.format(
          "build-cache: %s %d/%d jobs ready (%d failed) %s",
          versionId,
          lastReady,
          status.enumerated or lastReady,
          failed,
          poolSummary()
        )
      )
    end
    if status.settled then
      return status
    end
    -- Runnable local planning repumps at once: an idle pool never blocks
    -- deferred planning work and never earns a physical wait.
    if not status.planningPending then
      if (status.queued or 0) > 0 or (status.running or 0) > 0 then
        if type(pool.waitForProgress) == "function" then
          pool:waitForProgress()
        else
          pool:drain()
        end
      else
        error("preparation is unfinished with no runnable planning or physical work", 0)
      end
    end
  end
end

---@class CacheBuilder.VersionOptions
---@field identity table<string, unknown> immutable generation identity for the selected version
---@field requirements string[] closed requirement strings
---@field allowCompileExclusions boolean|nil accept resolved map compile failures as partial success
---@field rebuild string[]|nil canonical jobs to force in development mode
---@field dev boolean|nil development mode selector for explicit rebuilds
---@field log fun(line: string)|nil progress sink
---@field developmentRepositoryRoot string|nil worker source root for compiler threads
---@field profile string|nil opt-in execution evidence path
---@field preparationRecord string|nil invocation-owned path for the builder-issued proof, written only from a satisfied closure
---@field saveDirectory string|nil actual save directory recorded in the proof; resolved from the host when absent

-- Exact command finalization helpers. Session outcomes are the only identity
-- and disposition authority; pool facts attach timing and exact physical
-- failures by equality on the canonical key. Error text is display-only.
---@param item table<string, unknown>
---@param allowCompileExclusions boolean|nil
---@return boolean
local function isToleratedMapExclusion(item, allowCompileExclusions)
  return allowCompileExclusions == true and item.kind == "map" and item.failureClass == "job"
end

---@param pool table<string, unknown>|nil
---@param jobKey string
---@return string|nil poolError exact physical failure before session propagation
local function exactPoolFailure(pool, jobKey)
  if type(pool) ~= "table" or type(pool.jobOutcome) ~= "function" then
    return nil
  end
  local ok, snapshot = pcall(pool.jobOutcome, pool, jobKey)
  if ok and type(snapshot) == "table" and snapshot.state == "failed" then
    if type(snapshot.error) == "string" then
      return snapshot.error
    end
    return jobKey .. ": compiler job failed"
  end
  return nil
end

---@class CacheBuilder.Disposition
---@field kind string
---@field key string
---@field jobKey string
---@field state string successful|failed|cancelled|excluded
---@field reused boolean
---@field error string|nil
---@field causeJobKey string|nil
---@field sourceExclusion boolean|nil true when the exclusion is a source exclusion

---@param outcomeList table<string, unknown>
---@param pool table<string, unknown>|nil live pool for exact timing/physical facts
---@param allowCompileExclusions boolean|nil
---@return CacheBuilder.Disposition[] sorted
---@return table<string, integer> counts
---@return string[] failures
---@return string[] exclusions
---@return string[] sourceExclusions
---@return table<string, table<string, unknown>> timings
local function classifyExactOutcomes(outcomeList, pool, allowCompileExclusions)
  assert(type(outcomeList) == "table", "the generation session owns an exact outcome inventory")
  local seen = {}
  local dispositions = {}
  for _, item in ipairs(outcomeList) do
    assert(type(item) == "table", "outcome rows are canonical records")
    assert(type(item.jobKey) == "string" and item.jobKey ~= "", "outcome rows carry their canonical key")
    local kind, key = item.jobKey:match("^([^:]+):(.+)$")
    assert(kind ~= nil and key ~= nil, "outcome rows carry a canonical kind:key identity")
    assert(ArtifactState.KINDS[kind], "outcome rows carry a known job kind")
    assert(item.kind == kind and item.key == key, "outcome identity must match its canonical key")
    assert(
      item.state == "pending" or item.state == "successful" or item.state == "failed",
      "outcome rows carry a known state"
    )
    if seen[item.jobKey] ~= nil then
      local prev = seen[item.jobKey]
      assert(prev.state == item.state and prev.error == item.error, "duplicate outcome identity must agree")
    else
      seen[item.jobKey] = item
      local entry = {
        kind = kind,
        key = key,
        jobKey = item.jobKey,
        reused = item.reused == true,
        causeJobKey = item.causeJobKey,
      }
      if item.state == "successful" then
        assert(item.error == nil, "successful rows carry no error")
        entry.state = "successful"
        entry.error = nil
      elseif item.state == "failed" then
        assert(type(item.error) == "string", "failed dispositions carry an error string")
        assert(type(item.failureClass) == "string", "failed rows carry their exact failure class")
        assert(item.causeJobKey == nil or type(item.causeJobKey) == "string", "causes are exact canonical keys")
        if item.failureClass == "source-exclusion" then
          entry.state = "excluded"
          entry.error = item.error
          entry.sourceExclusion = true
        elseif isToleratedMapExclusion(item, allowCompileExclusions) then
          entry.state = "excluded"
          entry.error = item.error
        else
          entry.state = "failed"
          entry.error = item.error
        end
      else
        assert(item.error == nil, "pending rows carry no error")
        local poolError = exactPoolFailure(pool, item.jobKey)
        if poolError ~= nil then
          entry.state = "failed"
          entry.error = poolError
        else
          entry.state = "cancelled"
          entry.error = nil
        end
      end
      dispositions[#dispositions + 1] = entry
    end
  end
  table.sort(dispositions, function(left, right)
    return left.jobKey < right.jobKey
  end)
  local counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 }
  local failures, exclusions, sourceExclusions = {}, {}, {}
  local timings = {}
  for _, entry in ipairs(dispositions) do
    counts.planned = counts.planned + 1
    if entry.state == "successful" then
      counts.successful = counts.successful + 1
    elseif entry.state == "failed" then
      counts.failed = counts.failed + 1
      assert(type(entry.error) == "string", "failed rows carry their error")
      failures[#failures + 1] = entry.error
    elseif entry.state == "cancelled" then
      counts.cancelled = counts.cancelled + 1
    elseif entry.state == "excluded" then
      counts.excluded = counts.excluded + 1
      assert(type(entry.error) == "string", "excluded rows carry their error")
      exclusions[#exclusions + 1] = entry.error
      if entry.sourceExclusion then
        sourceExclusions[#sourceExclusions + 1] = entry.error
      end
    end
    timings[entry.jobKey] = observeTimings(pool or {}, entry.jobKey)
  end
  return dispositions, counts, failures, exclusions, sourceExclusions, timings
end

---@class CacheBuilder.VersionRecord
---@field versionId string
---@field identity table<string, unknown>
---@field ordered string[]
---@field exhaustive boolean
---@field epoch integer
---@field enumerationComplete boolean
---@field requestedReady boolean
---@field dispositions CacheBuilder.Disposition[]
---@field counts table<string, integer>
---@field failures string[]
---@field exclusions string[]
---@field sourceExclusions string[]
---@field timings table<string, table<string, unknown>>
---@field auditPassed boolean
---@field auditReason string|nil
---@field needsAttestation boolean
---@field isCurrent boolean
---@field cacheFs table<string, unknown>|nil pending publication access
---@field primaryError Errors.Error|string|nil handled drain failure preserved for the caller

---@param session table<string, unknown> settled generation session under verification
---@param parsed CacheBuilder.Requirement[] originally parsed requirements
---@param versionId string
---@return Errors.Error|nil scopeError a pending requirement names itself when settlement claims otherwise
local function verifyOriginalRequirements(session, parsed, versionId)
  -- Final requested-scope proof: confirm every originally parsed scope or
  -- canonical job through the session's retained public answers at the
  -- same urgency. This verifies retained intent without driving new work;
  -- a count-balanced census never overrides a pending requirement.
  local pendingScope = nil
  local function confirm(label, call)
    if pendingScope ~= nil then
      return
    end
    local ok, ready, failure = pcall(call)
    if not ok then
      error(ready, 0)
    end
    if ready ~= true and failure == nil then
      pendingScope = label
    end
  end
  for _, entry in ipairs(parsed) do
    if entry.scope == "bootstrap" or entry.scope == "field-core" then
      local scope = assert(entry.scope, "parsed requirements are scopes or canonical jobs")
      confirm(scope, function()
        return session:requestMilestone(scope, "required")
      end)
    elseif entry.scope == "complete" then
      confirm("field-core", function()
        return session:requestMilestone("field-core", "required")
      end)
      confirm("mon-summary:global", function()
        return session:requestJob("mon-summary", "global", "required")
      end)
    else
      local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
      local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
      confirm(kind .. ":" .. key, function()
        return session:requestJob(kind, key, "required")
      end)
    end
  end
  if pendingScope == nil then
    return nil
  end
  return Errors.new(
    "CACHE_PREPARATION_FAILED",
    "cache preparation settled while " .. pendingScope .. " was still pending; no invocation proof is issued",
    { versionId = versionId, scope = pendingScope }
  )
end

-- A drain failure is a handled command interruption when it is an already
-- supported structured error or when it is exactly the fatal value the
-- borrowed pool recorded through its public diagnostics. Exact equality
-- keeps unrelated raw faults on the cleanup-and-rethrow path.
---@param pool table<string, unknown>|nil
---@param caught unknown
---@return boolean
local function recognizedDrainFailure(pool, caught)
  if Errors.is(caught) then
    return true
  end
  if pool == nil then
    return false
  end
  local ok, diagnostics = pcall(pool.diagnostics, pool)
  return ok and type(diagnostics) == "table" and diagnostics.error ~= nil and diagnostics.error == caught
end

---@param versionId string
---@param allowCompileExclusions boolean|nil
---@param developmentRepositoryRoot string|nil
---@param cacheFs table<string, unknown>
---@param identity table<string, unknown>
---@param ordered string[]
---@param parsed CacheBuilder.Requirement[]
---@param exhaustive boolean
---@param rebuildJobs { kind: string, key: string, jobKey: string }[]
---@param log fun(line: string)
---@return CacheBuilder.VersionRecord record
local function collectVersionFacts(
  versionId,
  allowCompileExclusions,
  developmentRepositoryRoot,
  cacheFs,
  identity,
  ordered,
  parsed,
  exhaustive,
  rebuildJobs,
  log
)
  local stored = cacheFs:loadLua(DerivedCacheState.path)
  if exhaustive and #rebuildJobs == 0 and DerivedCacheState.matches(stored, identity) then
    local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
    local plans = ArtifactJobs.publishedPlans(cacheFs, identity)
    if plans ~= nil then
      local available, _ = DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
      if available then
        return {
          versionId = versionId,
          identity = identity,
          ordered = ordered,
          exhaustive = exhaustive,
          epoch = 0,
          enumerationComplete = true,
          requestedReady = true,
          dispositions = {},
          counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 },
          failures = {},
          exclusions = {},
          sourceExclusions = {},
          timings = {},
          auditPassed = true,
          auditReason = nil,
          needsAttestation = false,
          isCurrent = true,
          cacheFs = nil,
          primaryError = nil,
        }
      end
    end
  end
  if exhaustive or #rebuildJobs > 0 then
    DerivedCacheState.invalidate(cacheFs)
  end
  for _, job in ipairs(rebuildJobs) do
    cacheFs:remove(ArtifactState.path(job.kind, job.key))
  end
  epochCounter = epochCounter + 1
  local epoch = epochCounter
  local pool = nil ---@type table<string, unknown>|nil
  local session = nil ---@type table<string, unknown>|nil
  local status = nil
  local drainOk, drainResult = pcall(function()
    pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = developmentRepositoryRoot })
    session = InteractiveCacheBuild.new({
      identity = identity,
      epoch = epoch,
      pool = pool,
      sweepEnabled = exhaustive,
    })
    for _, entry in ipairs(parsed) do
      if entry.scope == "bootstrap" or entry.scope == "field-core" then
        local scope = assert(entry.scope, "parsed requirements are scopes or canonical jobs")
        session:requestMilestone(scope, "required")
      elseif entry.scope == "complete" then
        session:requestMilestone("field-core", "required")
        session:requestJob("mon-summary", "global", "required")
      else
        local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
        local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
        session:requestJob(kind, key, "required")
      end
    end
    return drainSession(pool, session, versionId, log)
  end)
  if not drainOk then
    local drainErr = drainResult
    if recognizedDrainFailure(pool, drainErr) then
      local outcomeList = {}
      if session ~= nil and type(session.outcomes) == "function" then
        local okOut, list = pcall(session.outcomes, session)
        if okOut and type(list) == "table" then
          outcomeList = list
        end
      end
      local dispositions, counts, failures, exclusions, sourceExclusions, timings =
        classifyExactOutcomes(outcomeList, pool, allowCompileExclusions)
      if session ~= nil then
        pcall(session.retire, session)
      end
      if pool ~= nil then
        pcall(pool.shutdown, pool)
      end
      return {
        versionId = versionId,
        identity = identity,
        ordered = ordered,
        exhaustive = exhaustive,
        epoch = epoch,
        enumerationComplete = false,
        requestedReady = false,
        dispositions = dispositions,
        counts = counts,
        failures = failures,
        exclusions = exclusions,
        sourceExclusions = sourceExclusions,
        timings = timings,
        auditPassed = false,
        auditReason = nil,
        needsAttestation = false,
        isCurrent = false,
        cacheFs = nil,
        primaryError = drainErr,
      }
    end
    if session ~= nil then
      pcall(session.retire, session)
    end
    if pool ~= nil then
      pcall(pool.shutdown, pool)
    end
    error(drainErr, 0)
  end
  status = assert(drainResult, "a settled session reports its status")
  assert(session ~= nil and pool ~= nil, "a settled scope owns its pool and session")
  -- The command proves only its originally requested scope: a pending
  -- requirement behind a settled census fails proof without inventing a job.
  local scopeError = verifyOriginalRequirements(session, parsed, versionId)
  local okOut, outcomeList = pcall(session.outcomes, session)
  assert(okOut and type(outcomeList) == "table", "the generation session owns an exact outcome inventory")
  local dispositions, counts, failures, exclusions, sourceExclusions, timings =
    classifyExactOutcomes(outcomeList, pool, allowCompileExclusions)
  pcall(session.retire, session)
  pcall(pool.shutdown, pool)
  local enumerationComplete = status.enumerationComplete == true
  local requestedReady = counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0
  if scopeError ~= nil then
    requestedReady = false
  end
  local needsAttestation = exhaustive and counts.failed == 0 and counts.cancelled == 0 and counts.excluded == 0
  local auditPassed = false
  local auditReason = nil
  if needsAttestation then
    local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
    local plans, plansReason = ArtifactJobs.publishedPlans(cacheFs, identity)
    if plans == nil then
      auditPassed = false
      auditReason = plansReason
    else
      local available, reason = DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
      auditPassed = available == true
      auditReason = reason
    end
  end
  local pendingFs = needsAttestation and auditPassed and cacheFs or nil
  return {
    versionId = versionId,
    identity = identity,
    ordered = ordered,
    exhaustive = exhaustive,
    epoch = epoch,
    enumerationComplete = enumerationComplete,
    requestedReady = requestedReady,
    dispositions = dispositions,
    counts = counts,
    failures = failures,
    exclusions = exclusions,
    sourceExclusions = sourceExclusions,
    timings = timings,
    auditPassed = auditPassed,
    auditReason = auditReason,
    needsAttestation = needsAttestation,
    isCurrent = false,
    cacheFs = pendingFs,
    primaryError = scopeError,
  }
end

---@param record CacheBuilder.VersionRecord
---@param auditPassed boolean
---@param attestationPublished boolean
---@param complete boolean
---@return table<string, unknown> report
local function makeRecordReport(record, auditPassed, attestationPublished, complete)
  local outcomes = {}
  for _, entry in ipairs(record.dispositions) do
    local timings = record.timings[entry.jobKey] or observeTimings({}, entry.jobKey)
    outcomes[#outcomes + 1] = {
      kind = entry.kind,
      key = entry.key,
      jobKey = entry.jobKey,
      state = entry.state,
      reused = entry.reused,
      workerId = timings.workerId,
      error = entry.error,
      causeJobKey = entry.causeJobKey,
      timing = {
        compileSeconds = timings.compileSeconds,
        stageSeconds = timings.stageSeconds,
        workSeconds = timings.workSeconds,
        stagedBytes = timings.stagedBytes,
        timingReason = timings.timingReason,
      },
    }
  end
  return {
    enumerationComplete = record.enumerationComplete,
    requestedReady = record.requestedReady,
    complete = complete,
    auditPassed = auditPassed,
    attestationPublished = attestationPublished,
    exclusions = record.exclusions,
    sourceExclusions = record.sourceExclusions,
    failures = record.failures,
    outcomes = outcomes,
    counts = {
      planned = record.counts.planned,
      successful = record.counts.successful,
      failed = record.counts.failed,
      cancelled = record.counts.cancelled,
      excluded = record.counts.excluded,
    },
  }
end

---@param record CacheBuilder.VersionRecord
---@param auditPassed boolean
---@param attestationPublished boolean
---@param complete boolean
---@return table<string, unknown> footer
local function makeRecordFooter(record, auditPassed, attestationPublished, complete)
  return {
    type = "footer",
    schema = PROFILE_SCHEMA,
    versionId = record.versionId,
    generationId = record.identity.generationId,
    enumerationComplete = record.enumerationComplete,
    requestedReady = record.requestedReady,
    complete = complete,
    auditPassed = auditPassed,
    attestationPublished = attestationPublished,
    planned = record.counts.planned,
    successful = record.counts.successful,
    failed = record.counts.failed,
    cancelled = record.counts.cancelled,
    excluded = record.counts.excluded,
  }
end

---@param handle table<string, function>|nil
---@param record CacheBuilder.VersionRecord
---@param footer table<string, unknown>
---@return Errors.Error|string|nil err
local function emitVersionEvidence(handle, record, footer)
  if handle == nil then
    return nil
  end
  local headerErr = writeProfileLine(handle, profileHeader(record.identity, "prepare", record.ordered, record.epoch))
  if headerErr ~= nil then
    return headerErr
  end
  local function null(value)
    if value == nil then
      return JSON_NULL
    end
    return value
  end
  for _, entry in ipairs(record.dispositions) do
    local timings = record.timings[entry.jobKey] or observeTimings({}, entry.jobKey)
    local row = {
      type = "job",
      schema = PROFILE_SCHEMA,
      versionId = record.versionId,
      generationId = record.identity.generationId,
      epoch = record.epoch,
      kind = entry.kind,
      key = entry.key,
      jobKey = entry.jobKey,
      state = entry.state,
      outcome = entry.state,
      reused = entry.reused,
      workerId = null(timings.workerId),
      workerIdReason = null(timings.workerIdReason),
      error = null(entry.error),
      cause = null(entry.error),
      causeJobKey = null(entry.causeJobKey),
      compileSeconds = null(timings.compileSeconds),
      compileSecondsReason = null(timings.compileSecondsReason),
      stageSeconds = null(timings.stageSeconds),
      stageSecondsReason = null(timings.stageSecondsReason),
      publicationSeconds = null(timings.publicationSeconds),
      publicationSecondsReason = null(timings.publicationSecondsReason),
      workSeconds = null(timings.workSeconds),
      workSecondsReason = null(timings.workSecondsReason),
      stagedBytes = null(timings.stagedBytes),
      stagedBytesReason = null(timings.stagedBytesReason),
      timingReason = null(timings.timingReason),
      timingReasonReason = null(timings.timingReasonReason),
    }
    local rowErr = writeProfileLine(handle, row)
    if rowErr ~= nil then
      return rowErr
    end
  end
  return writeProfileLine(handle, footer)
end

---@param handle table<string, function>|nil
---@return Errors.Error|string|nil err
local function closeChecked(handle)
  if handle == nil then
    return nil
  end
  local ok, result, closeErr = pcall(handle.close, handle)
  if not ok then
    return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(result), {})
  end
  if result == nil then
    return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(closeErr), {})
  end
  return nil
end

---@param record CacheBuilder.VersionRecord
---@param log fun(line: string)
local function logRecordOutcomes(record, log)
  for _, message in ipairs(record.exclusions) do
    log(string.format("build-cache: %s excluded %s", record.versionId, message))
  end
  for _, message in ipairs(record.failures) do
    log(string.format("build-cache: %s failed: %s", record.versionId, message))
  end
end

-- The private invocation-proof schema. Consumers validate it strictly and
-- reject every predecessor; it is never a runtime or mod-facing contract.
CacheBuilder.PREPARATION_SCHEMA = "g4-test-preparation-v2"

---@param requirements string[]
---@return string[]
local function sortedUniqueRequirements(requirements)
  assert(type(requirements) == "table", "the invocation proof requires its satisfied closure")
  local seen, ordered = {}, {}
  for _, requirement in ipairs(requirements) do
    assert(
      type(requirement) == "string" and requirement ~= "",
      "the invocation proof requirements must be non-empty strings"
    )
    if not seen[requirement] then
      seen[requirement] = true
      ordered[#ordered + 1] = requirement
    end
  end
  table.sort(ordered)
  return ordered
end

---@param saveDirectory string|nil
---@return string
local function invocationSaveDirectory(saveDirectory)
  if type(saveDirectory) == "string" and saveDirectory ~= "" then
    return saveDirectory
  end
  local host = rawget(_G, "love")
  if host ~= nil and host.filesystem ~= nil and type(host.filesystem.getSaveDirectory) == "function" then
    local directory = host.filesystem.getSaveDirectory()
    assert(type(directory) == "string" and directory ~= "", "the invocation proof requires the actual save directory")
    return directory
  end
  error("the invocation proof requires the actual save directory", 0)
end

---@param encoded string
---@return table<string, unknown>|nil record
local function decodePreparationRecord(encoded)
  local chunk = load(encoded, "@preparation-record", "t", {})
  if chunk == nil then
    return nil
  end
  local ok, record = pcall(chunk)
  if not ok or type(record) ~= "table" then
    return nil
  end
  return record
end

-- Atomically issue the invocation proof for one successful scoped
-- preparation. The record carries the actual save directory and the current
-- generation, never an inherited claim; only a satisfied closure is ever
-- recorded. The proof is encoded with the shared deterministic writer,
-- staged to a temporary sibling, read back for its schema and generation,
-- and atomically renamed over the requested output. Any I/O failure is a
-- structured error that fails the command without forging readiness or
-- deleting valid cache output.
---@param path string invocation-owned output path
---@param params { versionId: string, romSha1: string, generationId: string, requested: string[], complete: boolean, saveDirectory: string|nil }
---@return boolean|nil ok
---@return Errors.Error|string|nil err
function CacheBuilder.writePreparationRecord(path, params)
  assert(type(path) == "string" and path ~= "", "the invocation proof requires its output path")
  assert(type(params) == "table", "the invocation proof requires its preparation facts")
  assert(type(params.versionId) == "string" and params.versionId ~= "", "the invocation proof requires its version")
  assert(type(params.romSha1) == "string" and #params.romSha1 == 40, "the invocation proof requires its ROM identity")
  assert(
    type(params.generationId) == "string" and params.generationId ~= "",
    "the invocation proof requires its generation"
  )
  assert(type(params.complete) == "boolean", "the invocation proof requires its exhaustive result")
  local record = {
    schema = CacheBuilder.PREPARATION_SCHEMA,
    saveDirectory = invocationSaveDirectory(params.saveDirectory),
    versionId = params.versionId,
    romSha1 = params.romSha1,
    generationId = params.generationId,
    requested = sortedUniqueRequirements(params.requested),
    requestedReady = true,
    complete = params.complete,
  }
  local encodeOk, encoded = pcall(LuaWriter.encode, record)
  if not encodeOk then
    return nil, Errors.new("PREPARATION_RECORD_FAILED", "the invocation proof cannot be encoded", { path = path })
  end
  local staging = path .. ".tmp"
  local handle, openErr = io.open(staging, "w")
  if handle == nil then
    return nil,
      Errors.new(
        "PREPARATION_RECORD_FAILED",
        "the invocation proof cannot be opened: " .. tostring(openErr),
        { path = path }
      )
  end
  assert(type(encoded) == "string", "the invocation proof encoding is required")
  local _, writeErr = handle:write(encoded)
  if writeErr ~= nil then
    handle:close()
    os.remove(staging)
    return nil,
      Errors.new(
        "PREPARATION_RECORD_FAILED",
        "the invocation proof cannot be written: " .. tostring(writeErr),
        { path = path }
      )
  end
  local _, closeErr = handle:close()
  if closeErr ~= nil then
    os.remove(staging)
    return nil,
      Errors.new(
        "PREPARATION_RECORD_FAILED",
        "the invocation proof cannot be closed: " .. tostring(closeErr),
        { path = path }
      )
  end
  local staged, readErr = io.open(staging, "r")
  if staged == nil then
    os.remove(staging)
    return nil,
      Errors.new(
        "PREPARATION_RECORD_FAILED",
        "the invocation proof cannot be read back: " .. tostring(readErr),
        { path = path }
      )
  end
  local stagedSource = staged:read("*a")
  staged:close()
  local stagedRecord = type(stagedSource) == "string" and decodePreparationRecord(stagedSource) or nil
  if
    stagedRecord == nil
    or stagedRecord.schema ~= record.schema
    or stagedRecord.generationId ~= record.generationId
  then
    os.remove(staging)
    return nil,
      Errors.new("PREPARATION_RECORD_FAILED", "the invocation proof failed its read-back check", { path = path })
  end
  local _, renameErr = os.rename(staging, path)
  if renameErr ~= nil then
    os.remove(staging)
    return nil,
      Errors.new(
        "PREPARATION_RECORD_FAILED",
        "the invocation proof cannot be published: " .. tostring(renameErr),
        { path = path }
      )
  end
  return true
end

---@param versionId string
---@param options CacheBuilder.VersionOptions
---@return table<string, unknown>|nil report
---@return Errors.Error|string|nil err
function CacheBuilder.prepareVersion(versionId, options)
  options = options or {}
  local log = options.log or print
  local versionErr = checkVersion(versionId)
  if versionErr ~= nil then
    return nil, versionErr
  end
  local identityErr = checkIdentity(options.identity, versionId)
  if identityErr ~= nil then
    return nil, identityErr
  end
  local ordered, parsed, requirementsErr = parseRequirements(options.requirements)
  if ordered == nil or parsed == nil then
    return nil, requirementsErr
  end
  local rebuildJobs, rebuildErr = checkRebuild(options.rebuild, parsed, ordered, options.dev)
  if rebuildJobs == nil then
    return nil, rebuildErr
  end
  local identity = options.identity
  local exhaustive = false
  for _, entry in ipairs(parsed) do
    if entry.scope == "complete" then
      exhaustive = true
    end
  end
  local cacheFs = CacheFs.forVersion(versionId)
  local profileHandle = nil
  if options.profile ~= nil then
    local handle, openErr = io.open(options.profile, "w")
    if handle == nil then
      return nil,
        Errors.new(
          "PROFILE_OPEN_FAILED",
          "execution evidence cannot be opened: " .. tostring(openErr),
          { path = options.profile }
        )
    end
    profileHandle = handle
  end
  local function finishHandle(opened)
    if opened == nil then
      return nil
    end
    local err = closeChecked(opened)
    return err
  end
  local collectOk, record = pcall(
    collectVersionFacts,
    versionId,
    options.allowCompileExclusions,
    options.developmentRepositoryRoot,
    cacheFs,
    identity,
    ordered,
    parsed,
    exhaustive,
    rebuildJobs,
    log
  )
  if not collectOk then
    local progErr = record
    if profileHandle ~= nil then
      pcall(profileHandle.close, profileHandle)
    end
    error(progErr, 0)
  end
  assert(record ~= nil, "scoped collection returns its scalar record")
  if record.isCurrent then
    log(string.format("build-cache: %s current", versionId))
    local footer = makeRecordFooter(record, true, false, true)
    local emitErr = emitVersionEvidence(profileHandle, record, footer)
    local closeErr = finishHandle(profileHandle)
    profileHandle = nil
    if emitErr ~= nil then
      return nil, emitErr
    end
    if closeErr ~= nil then
      return nil, closeErr
    end
    local report = makeRecordReport(record, true, false, true)
    if options.preparationRecord ~= nil and report.requestedReady == true then
      local _, recordErr = CacheBuilder.writePreparationRecord(options.preparationRecord, {
        versionId = versionId,
        romSha1 = identity.romSha1,
        generationId = identity.generationId,
        requested = options.requirements,
        complete = report.complete == true,
        saveDirectory = options.saveDirectory,
      })
      if recordErr ~= nil then
        return nil, recordErr
      end
    end
    return report
  end
  logRecordOutcomes(record, log)
  if record.primaryError ~= nil then
    local footer = makeRecordFooter(record, false, false, false)
    local emitErr = emitVersionEvidence(profileHandle, record, footer)
    local closeErr = finishHandle(profileHandle)
    profileHandle = nil
    if emitErr ~= nil then
      return nil, emitErr
    end
    if closeErr ~= nil then
      return nil, closeErr
    end
    return nil, record.primaryError
  end
  if record.counts.failed > 0 or record.counts.cancelled > 0 then
    local footer = makeRecordFooter(record, false, false, false)
    local emitErr = emitVersionEvidence(profileHandle, record, footer)
    local closeErr = finishHandle(profileHandle)
    profileHandle = nil
    if emitErr ~= nil then
      return nil, emitErr
    end
    if closeErr ~= nil then
      return nil, closeErr
    end
    return nil,
      Errors.new(
        "CACHE_PREPARATION_FAILED",
        "cache preparation failed",
        { versionId = versionId, failures = record.failures }
      )
  end
  if record.needsAttestation then
    if not record.auditPassed then
      local footer = makeRecordFooter(record, false, false, false)
      local emitErr = emitVersionEvidence(profileHandle, record, footer)
      local closeErr = finishHandle(profileHandle)
      profileHandle = nil
      if emitErr ~= nil then
        return nil, emitErr
      end
      if closeErr ~= nil then
        return nil, closeErr
      end
      return nil,
        Errors.new(
          "CACHE_PREPARATION_FAILED",
          "cache preparation failed: " .. tostring(record.auditReason),
          { versionId = versionId }
        )
    end
    local publishOk, publishErr = pcall(DerivedCacheState.publish, cacheFs, identity)
    if not publishOk then
      local footer = makeRecordFooter(record, true, false, false)
      local emitErr = emitVersionEvidence(profileHandle, record, footer)
      local closeErr = finishHandle(profileHandle)
      profileHandle = nil
      if emitErr ~= nil then
        return nil, emitErr
      end
      if closeErr ~= nil then
        return nil, closeErr
      end
      if Errors.is(publishErr) then
        return nil, publishErr
      end
      return nil,
        Errors.new(
          "CACHE_PREPARATION_FAILED",
          "cache preparation failed: " .. tostring(publishErr),
          { versionId = versionId }
        )
    end
    local footer = makeRecordFooter(record, true, true, true)
    local emitErr = emitVersionEvidence(profileHandle, record, footer)
    local closeErr = finishHandle(profileHandle)
    profileHandle = nil
    if emitErr ~= nil then
      return nil, emitErr
    end
    if closeErr ~= nil then
      return nil, closeErr
    end
    local report = makeRecordReport(record, true, true, true)
    log(string.format("build-cache: %s complete (%d jobs)", versionId, record.counts.successful))
    if options.preparationRecord ~= nil and report.requestedReady == true then
      local _, recordErr = CacheBuilder.writePreparationRecord(options.preparationRecord, {
        versionId = versionId,
        romSha1 = identity.romSha1,
        generationId = identity.generationId,
        requested = options.requirements,
        complete = report.complete == true,
        saveDirectory = options.saveDirectory,
      })
      if recordErr ~= nil then
        return nil, recordErr
      end
    end
    return report
  end
  local footer = makeRecordFooter(record, false, false, false)
  local emitErr = emitVersionEvidence(profileHandle, record, footer)
  local closeErr = finishHandle(profileHandle)
  profileHandle = nil
  if emitErr ~= nil then
    return nil, emitErr
  end
  if closeErr ~= nil then
    return nil, closeErr
  end
  local report = makeRecordReport(record, false, false, false)
  local logLine
  if exhaustive then
    logLine = string.format(
      "build-cache: %s partial (%d jobs, %d excluded)",
      versionId,
      record.counts.successful,
      record.counts.excluded
    )
  else
    logLine = string.format("build-cache: %s prepared (%d jobs)", versionId, record.counts.successful)
  end
  log(logLine)
  if options.preparationRecord ~= nil and report.requestedReady == true then
    local _, recordErr = CacheBuilder.writePreparationRecord(options.preparationRecord, {
      versionId = versionId,
      romSha1 = identity.romSha1,
      generationId = identity.generationId,
      requested = options.requirements,
      complete = report.complete == true,
      saveDirectory = options.saveDirectory,
    })
    if recordErr ~= nil then
      return nil, recordErr
    end
  end
  return report
end

local function versionIdentity(versionId, dev, producerFingerprint)
  local romFs, openErr = RomFs.open(versionId)
  if romFs == nil then
    assert(Errors.is(openErr), "source-data stage failure must be a structured error")
    return nil, openErr --[[@as Errors.Error]]
  end
  local metadata = romFs:metadata()
  romFs:close()
  local sha1 = metadata ~= nil and metadata.sha1 or nil
  if type(sha1) ~= "string" or #sha1 ~= 40 or sha1:find("[^0-9a-f]") ~= nil then
    return nil,
      Errors.new("INVALID_ROM_IDENTITY", "the published dump carries no validated ROM hash", { versionId = versionId })
  end
  local mode = dev == true and "development" or "release"
  local producerId
  if dev == true then
    producerId = assert(producerFingerprint, "development identity requires the working-tree digest")
  else
    producerId = "r" .. tostring(assert(DerivedCacheVersions[versionId], "release counter is required"))
  end
  local ok, identity = pcall(DerivedCacheState.current, {
    versionId = versionId,
    romSha1 = sha1,
    mode = mode,
    producerId = producerId,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  if not ok then
    if Errors.is(identity) then
      return nil, identity
    end
    error(identity, 0)
  end
  return identity
end

---@param versionIds string[]
---@param options { allowCompileExclusions?: boolean, dev?: boolean, log?: fun(line: string), developmentRepositoryRoot?: string, profile?: string }|nil
---@return table<string, unknown>|nil report, string|nil err
function CacheBuilder.buildVersions(versionIds, options)
  options = options or {}
  local log = options.log or print
  if #versionIds == 0 then
    log("build: no ready version to compile")
    return nil, "no ready version to compile"
  end
  local producerFingerprint
  if options.dev == true then
    local repositoryRoot =
      assert(options.developmentRepositoryRoot, "development builds require the repository root the process runs from")
    producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(repositoryRoot))
  end
  local profileHandle = nil
  if options.profile ~= nil then
    local handle, openErr = io.open(options.profile, "w")
    if handle == nil then
      log("build-cache: execution evidence cannot be opened: " .. tostring(openErr))
      return nil, "cache preparation failed"
    end
    profileHandle = handle
  end
  local function closeShared()
    if profileHandle == nil then
      return nil
    end
    local handle = profileHandle
    profileHandle = nil
    local ok, result, closeErr = pcall(handle.close, handle)
    if not ok then
      return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(result), {})
    end
    if result == nil then
      return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(closeErr), {})
    end
    return nil
  end
  ---@type CacheBuilder.VersionRecord[]
  local records = {}
  local allOk = true
  local exclusionCount = 0
  for _, version in ipairs(versionIds) do
    local ok, result, failureErr = pcall(function()
      local cacheFs = CacheFs.forVersion(version)
      local dumpMarker = cacheFs:read(RawDumpContract.MARKER_PATH)
      assert(type(dumpMarker) == "string", "a ready version must have a published dump marker")
      local identity, identityErr = versionIdentity(version, options.dev, producerFingerprint)
      if identity == nil then
        assert(Errors.is(identityErr), "source-data stage failure must be a structured error")
        return nil, identityErr
      end
      local ordered = { "complete" }
      local parsed = {
        { scope = "complete" },
      }
      local record = collectVersionFacts(
        version,
        options.allowCompileExclusions,
        options.developmentRepositoryRoot,
        cacheFs,
        identity,
        ordered,
        parsed,
        true,
        {},
        log
      )
      return record
    end)
    if not ok then
      if Errors.is(result) then
        allOk = false
        log("build-cache: " .. version .. " failed: " .. Errors.format(result))
      else
        local closeErr = closeShared()
        if closeErr ~= nil then
          log("build-cache: execution evidence cannot be closed: " .. tostring(closeErr))
        end
        error(result, 0)
      end
    elseif result == nil then
      allOk = false
      if failureErr ~= nil then
        log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
      else
        log("build-cache: " .. version .. " failed")
      end
    else
      ---@cast result CacheBuilder.VersionRecord
      records[#records + 1] = result
      if result.isCurrent then
        log(string.format("build-cache: %s current", version))
      else
        logRecordOutcomes(result, log)
      end
      if result.primaryError ~= nil then
        allOk = false
        log("build-cache: " .. version .. " failed: " .. Errors.format(result.primaryError))
      elseif result.counts.failed > 0 or result.counts.cancelled > 0 then
        allOk = false
      elseif result.counts.excluded > 0 then
        exclusionCount = exclusionCount + result.counts.excluded
        if not options.allowCompileExclusions then
          allOk = false
        end
      end
      if not result.isCurrent and result.needsAttestation and not result.auditPassed then
        allOk = false
      end
    end
  end
  if #records ~= 0 then
    local counted = 0
    for _, record in ipairs(records) do
      counted = counted + record.counts.excluded
    end
    exclusionCount = counted
  end
  local function emitAll(finalize)
    local emitErr = nil
    for _, record in ipairs(records) do
      local flags = finalize(record)
      local footer = makeRecordFooter(record, flags.auditPassed, flags.attestationPublished, flags.complete)
      if emitErr == nil then
        emitErr = emitVersionEvidence(profileHandle, record, footer)
      end
    end
    return emitErr
  end
  if not allOk then
    local emitErr = emitAll(function(record)
      return {
        auditPassed = record.auditPassed,
        attestationPublished = false,
        complete = record.isCurrent and record.auditPassed or false,
      }
    end)
    local closeErr = closeShared()
    if emitErr ~= nil then
      log("build-cache: execution evidence cannot be written: " .. tostring(emitErr))
    end
    if closeErr ~= nil then
      log("build-cache: execution evidence cannot be closed: " .. tostring(closeErr))
    end
    if emitErr ~= nil or closeErr ~= nil then
      return nil, "cache preparation failed"
    end
    if exclusionCount > 0 and not options.allowCompileExclusions then
      log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    end
    return nil, "cache preparation failed"
  end
  ---@type table<string, unknown>[] pending
  local pending = {}
  for _, record in ipairs(records) do
    if record.needsAttestation and not record.isCurrent then
      pending[#pending + 1] = record
    end
  end
  ---@type table<string, boolean> publishedOk
  local publishedOk = {}
  local publishFailed = false
  for _, record in ipairs(pending) do
    if publishFailed then
      publishedOk[record.versionId] = false
    else
      local ok, err = pcall(DerivedCacheState.publish, assert(record.cacheFs), record.identity)
      if ok then
        publishedOk[record.versionId] = true
      else
        publishFailed = true
        publishedOk[record.versionId] = false
        log("build-cache: " .. record.versionId .. " failed: " .. Errors.format(err))
      end
    end
  end
  if publishFailed then
    local emitErr = emitAll(function(record)
      if record.isCurrent then
        return { auditPassed = record.auditPassed, attestationPublished = false, complete = true }
      end
      if record.needsAttestation then
        return {
          auditPassed = record.auditPassed,
          attestationPublished = publishedOk[record.versionId] == true,
          complete = publishedOk[record.versionId] == true,
        }
      end
      return { auditPassed = record.auditPassed, attestationPublished = false, complete = false }
    end)
    local closeErr = closeShared()
    if emitErr ~= nil then
      log("build-cache: execution evidence cannot be written: " .. tostring(emitErr))
    end
    if closeErr ~= nil then
      log("build-cache: execution evidence cannot be closed: " .. tostring(closeErr))
    end
    return nil, "cache preparation failed"
  end
  local emitErr = emitAll(function(record)
    if record.isCurrent then
      return { auditPassed = record.auditPassed, attestationPublished = false, complete = true }
    end
    if record.needsAttestation then
      return { auditPassed = record.auditPassed, attestationPublished = true, complete = true }
    end
    return { auditPassed = record.auditPassed, attestationPublished = false, complete = false }
  end)
  local closeErr = closeShared()
  if emitErr ~= nil then
    log("build-cache: execution evidence cannot be written: " .. tostring(emitErr))
    return nil, "cache preparation failed"
  end
  if closeErr ~= nil then
    log("build-cache: execution evidence cannot be closed: " .. tostring(closeErr))
    return nil, "cache preparation failed"
  end
  local complete = exclusionCount == 0
  return { published = true, complete = complete, exclusionCount = exclusionCount }
end

return CacheBuilder
