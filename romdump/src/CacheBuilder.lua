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

-- True when a session failure names a source-planned exclusion rather than a
-- genuine compilation or validation failure: the source has no such record,
-- so the job is accounted separately instead of failing the command.
---@param failure string
---@return boolean
local function isSourceExclusion(failure)
  return failure:find("source-planned exclusion", 1, true) ~= nil
    or failure:find("source has no", 1, true) ~= nil
    or failure:find("has no such", 1, true) ~= nil
    or failure:find("has no supported", 1, true) ~= nil
    or failure:find("has no field record", 1, true) ~= nil
    or failure:find("no such cell", 1, true) ~= nil
    or failure:find("not in the canonical index", 1, true) ~= nil
end

-- Attribute a session failure to its canonical kind using the explicitly
-- requested job identities first, then the kind:key prefix for dependency
-- failures that carry their own identity. Returns nil when the failure names
-- no attributable kind; such failures always fail the command.
---@param failure string
---@param requestedJobs string[]
---@return string|nil
local function attributeKind(failure, requestedJobs)
  for _, jobKey in ipairs(requestedJobs) do
    if failure:find(jobKey, 1, true) ~= nil then
      return jobKey:match("^([^:]+):")
    end
  end
  local kind = failure:match("^([%w%-]+):")
  if kind ~= nil and ArtifactState.KINDS[kind] then
    return kind
  end
  return nil
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

-- Resolve per-job observation timings from the pool's exact outcome
-- snapshot when it exposes one; otherwise every timing is null with a
-- reason, never zero masquerading as a measurement. The bounded diagnostic
-- ring is never profiling authority.
---@param pool CompilerPool
---@param jobKey string
---@param observed table<string, table<string, unknown>> timings accumulated across drain rounds
---@return table<string, unknown>
local function observeTimings(pool, jobKey, observed)
  local function fromOutcome(outcome)
    if type(outcome) ~= "table" then
      return nil
    end
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
      timingReasonReason = outcome.timingReason == nil and "per-job timing detail is not published by the pool" or nil,
      workerId = outcome.workerId,
      workerIdReason = outcome.workerId == nil and "the job did not execute through the compiler pool" or nil,
    }
  end
  if type(pool.jobOutcome) == "function" then
    local ok, outcome = pcall(pool.jobOutcome, pool, jobKey)
    if ok and type(outcome) == "table" then
      local timings = fromOutcome(outcome)
      if timings ~= nil then
        return timings
      end
    end
    local known = observed[jobKey]
    if known ~= nil then
      local timings = fromOutcome(known)
      if timings ~= nil then
        return timings
      end
    end
  else
    local known = observed[jobKey]
    if known ~= nil then
      return {
        compileSeconds = known.compileSeconds,
        compileSecondsReason = known.compileSeconds == nil and "streaming input/output cannot be separated reliably"
          or nil,
        stageSeconds = known.stageSeconds,
        stageSecondsReason = known.stageSeconds == nil and "streaming input/output cannot be separated reliably" or nil,
        publicationSeconds = nil,
        publicationSecondsReason = "publication time is not separated from worker reports",
        workSeconds = known.workSeconds,
        workSecondsReason = known.workSeconds == nil and "timing is unavailable for this job" or nil,
        stagedBytes = known.stagedBytes,
        stagedBytesReason = known.stagedBytes == nil and "timing is unavailable for this job" or nil,
        timingReason = nil,
        timingReasonReason = "per-job timing detail is not published by the pool",
        workerId = known.workerId,
        workerIdReason = known.workerId == nil and "the job did not execute through the compiler pool" or nil,
      }
    end
  end
  local empty = {
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
  if type(pool.diagnostics) ~= "function" then
    return empty
  end
  local ok, diagnostics = pcall(pool.diagnostics, pool)
  if not ok or type(diagnostics) ~= "table" or type(diagnostics.recentTimings) ~= "table" then
    return empty
  end
  for _, entry in ipairs(diagnostics.recentTimings) do
    if type(entry) == "table" and entry.jobKey == jobKey then
      return {
        compileSeconds = entry.compileSeconds,
        compileSecondsReason = entry.compileSeconds == nil and "streaming input/output cannot be separated reliably"
          or nil,
        stageSeconds = entry.stageSeconds,
        stageSecondsReason = entry.stageSeconds == nil and "streaming input/output cannot be separated reliably" or nil,
        publicationSeconds = nil,
        publicationSecondsReason = "publication time is not separated from worker reports",
        workSeconds = entry.workSeconds,
        workSecondsReason = entry.workSeconds == nil and "timing is unavailable for this job" or nil,
        stagedBytes = entry.stagedBytes,
        stagedBytesReason = entry.stagedBytes == nil and "timing is unavailable for this job" or nil,
        timingReason = nil,
        timingReasonReason = "per-job timing detail is not published by the pool",
        workerId = entry.workerId,
        workerIdReason = entry.workerId == nil and "the job did not execute through the compiler pool" or nil,
      }
    end
  end
  return empty
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

---@param pool CompilerPool
---@param session InteractiveCacheBuild
---@param versionId string
---@param log fun(line: string)
---@param observed table<string, table<string, unknown>> per-job timings accumulated across rounds
---@return CacheBuilder.SessionStatus status
local function drainSession(pool, session, versionId, log, observed)
  local rounds = 0
  local lastReady, lastFailed = -1, -1
  -- Exact outcome snapshots stay available until the generation is retired,
  -- so accumulate every terminal fact by canonical key instead of sampling
  -- the bounded diagnostic ring.
  local function accumulate()
    if type(pool.jobOutcome) == "function" and type(session.outcomes) == "function" then
      local okOutcomes, list = pcall(session.outcomes, session)
      if okOutcomes and type(list) == "table" then
        for _, item in ipairs(list) do
          if type(item) == "table" and type(item.jobKey) == "string" and observed[item.jobKey] == nil then
            local okOutcome, snapshot = pcall(pool.jobOutcome, pool, item.jobKey)
            if okOutcome and type(snapshot) == "table" then
              observed[item.jobKey] = snapshot
            end
          end
        end
      end
      return
    end
    if type(pool.jobOutcome) == "function" then
      return
    end
    if type(pool.diagnostics) ~= "function" then
      return
    end
    local ok, diagnostics = pcall(pool.diagnostics, pool)
    if not ok or type(diagnostics) ~= "table" or type(diagnostics.recentTimings) ~= "table" then
      return
    end
    for _, entry in ipairs(diagnostics.recentTimings) do
      if type(entry) == "table" and type(entry.jobKey) == "string" and observed[entry.jobKey] == nil then
        observed[entry.jobKey] = entry
      end
    end
  end
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
    if (status.queued or 0) == 0 and (status.running or 0) == 0 then
      accumulate()
      return status
    end
    if type(pool.waitForProgress) == "function" then
      pool:waitForProgress()
    else
      pool:drain()
    end
    accumulate()
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

---@param versionId string
---@param options CacheBuilder.VersionOptions
---@param command { pending: { cacheFs: table<string, unknown>, identity: table<string, unknown> }[]|nil, profileHandle: table<string, function>|nil, profilePath: string|nil }
---@return table<string, unknown>|nil report
---@return Errors.Error|string|nil err
local function runScopedVersion(versionId, options, command)
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
  local stored = cacheFs:loadLua(DerivedCacheState.path)
  if exhaustive and #rebuildJobs == 0 and DerivedCacheState.matches(stored, identity) then
    -- The current shortcut still proves usability: an identity match plus
    -- the exhaustive generation audit over the published inventory. Missing
    -- planning metadata or any invalid payload falls through to repair
    -- instead of reporting current.
    local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
    local plans = ArtifactJobs.publishedPlans(cacheFs, identity)
    if plans ~= nil and DerivedCacheAudit.isAvailable(cacheFs, identity, plans) then
      log(string.format("build-cache: %s current", versionId))
      local footer = {
        type = "footer",
        schema = PROFILE_SCHEMA,
        versionId = versionId,
        generationId = identity.generationId,
        enumerationComplete = true,
        requestedReady = true,
        complete = true,
        auditPassed = true,
        attestationPublished = false,
        planned = 0,
        successful = 0,
        failed = 0,
        cancelled = 0,
        excluded = 0,
      }
      if command.profileHandle ~= nil then
        local headerErr = writeProfileLine(command.profileHandle, profileHeader(identity, "prepare", ordered, 0))
        if headerErr == nil then
          headerErr = writeProfileLine(command.profileHandle, footer)
        end
        if headerErr ~= nil then
          return nil, headerErr
        end
      end
      return {
        enumerationComplete = true,
        complete = true,
        requestedReady = true,
        auditPassed = true,
        attestationPublished = false,
        exclusions = {},
        sourceExclusions = {},
        failures = {},
        outcomes = {},
        counts = { planned = 0, successful = 0, failed = 0, cancelled = 0, excluded = 0 },
      }
    end
  end

  local profileHandle = command.profileHandle
  local ownsProfile = false
  if profileHandle == nil and command.profilePath ~= nil then
    local handle, openErr = io.open(command.profilePath, "w")
    if handle == nil then
      return nil,
        Errors.new(
          "PROFILE_OPEN_FAILED",
          "execution evidence cannot be opened: " .. tostring(openErr),
          { path = command.profilePath }
        )
    end
    profileHandle = handle
    ownsProfile = true
  end
  local function closeProfile()
    if ownsProfile and profileHandle ~= nil then
      local handle = profileHandle
      profileHandle = nil
      local ok, result, closeErr = pcall(handle.close, handle)
      if not ok then
        return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(result), {})
      end
      if result == nil then
        return Errors.new("PROFILE_WRITE_FAILED", "execution evidence cannot be closed: " .. tostring(closeErr), {})
      end
    end
    return nil
  end

  epochCounter = epochCounter + 1
  local epoch = epochCounter
  if profileHandle ~= nil then
    local headerErr = writeProfileLine(profileHandle, profileHeader(identity, "prepare", ordered, epoch))
    if headerErr ~= nil then
      closeProfile()
      return nil, headerErr
    end
  end

  -- A stale full attestation is never trusted once this command changes
  -- artifacts: an exhaustive scope always rebuilds stale work, and an
  -- explicit rebuild forces its selected jobs past their readiness memo by
  -- dropping their current receipts. Dependencies still validate, so only
  -- the selected jobs recompile; staged publication keeps the last good data
  -- live until its replacement publishes. Pure targeted validation preserves
  -- the last known-good attestation.
  if exhaustive or #rebuildJobs > 0 then
    DerivedCacheState.invalidate(cacheFs)
  end
  for _, job in ipairs(rebuildJobs) do
    cacheFs:remove(ArtifactState.path(job.kind, job.key))
  end

  local pool = nil ---@type CompilerPool|nil
  local session = nil ---@type InteractiveCacheBuild|nil
  local observedTimings = {}

  local requestedJobs = {}
  local requestExcluded = {}
  ---@param reason string
  local function noteRequestExclusion(reason)
    requestExcluded[#requestExcluded + 1] = reason
  end
  local function requestAll()
    assert(session ~= nil, "generation session is required before requesting scope")
    for _, entry in ipairs(parsed) do
      if entry.scope == "bootstrap" or entry.scope == "field-core" then
        local scope = assert(entry.scope, "parsed requirements are scopes or canonical jobs")
        local _, failure = session:requestMilestone(scope, "required")
        if failure ~= nil then
          noteRequestExclusion(failure)
        end
      elseif entry.scope == "complete" then
        local _, coreFailure = session:requestMilestone("field-core", "required")
        if coreFailure ~= nil then
          noteRequestExclusion(coreFailure)
        end
        local _, summaryFailure = session:requestJob("mon-summary", "global", "required")
        if summaryFailure ~= nil then
          noteRequestExclusion(summaryFailure)
        end
      else
        local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
        local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
        local jobKey = assert(entry.jobKey, "parsed requirements are scopes or canonical jobs")
        requestedJobs[#requestedJobs + 1] = jobKey
        local _, failure = session:requestJob(kind, key, "required")
        if failure ~= nil then
          noteRequestExclusion(failure)
        end
      end
    end
  end

  local drainOk, status = pcall(function()
    pool = CompilerPool.new({ mode = "batch", developmentRepositoryRoot = options.developmentRepositoryRoot })
    session = InteractiveCacheBuild.new({
      identity = identity,
      epoch = epoch,
      pool = pool,
      sweepEnabled = exhaustive,
    })
    requestAll()
    return drainSession(pool, session, versionId, log, observedTimings)
  end)
  if not drainOk then
    if session ~= nil then
      pcall(session.retire, session)
    end
    if pool ~= nil then
      pcall(pool.shutdown, pool)
    end
    closeProfile()
    if Errors.is(status) then
      return nil, status --[[@as Errors.Error]]
    end
    error(status, 0)
  end
  assert(status ~= nil, "a settled session reports its status")
  assert(session ~= nil and pool ~= nil, "a settled scope owns its pool and session")

  -- Snapshot exact pool facts for every known job before retiring the owner
  -- that retains them. The bounded diagnostic ring never decides evidence.
  if type(pool.jobOutcome) == "function" then
    for _, jobKey in ipairs(requestedJobs) do
      if observedTimings[jobKey] == nil then
        local okOutcome, snapshot = pcall(pool.jobOutcome, pool, jobKey)
        if okOutcome and type(snapshot) == "table" then
          observedTimings[jobKey] = snapshot
        end
      end
    end
  end
  local sessionOutcomes = nil
  local sessionByKey = {}
  if type(session.outcomes) == "function" then
    local okOutcomes, list = pcall(session.outcomes, session)
    if okOutcomes and type(list) == "table" then
      sessionOutcomes = list
      for _, item in ipairs(list) do
        if type(item) == "table" and type(item.jobKey) == "string" then
          sessionByKey[item.jobKey] = item
          if type(pool.jobOutcome) == "function" and observedTimings[item.jobKey] == nil then
            local okOutcome, snapshot = pcall(pool.jobOutcome, pool, item.jobKey)
            if okOutcome and type(snapshot) == "table" then
              observedTimings[item.jobKey] = snapshot
            end
          end
        end
      end
    end
  end
  local enumerationComplete = status.enumerationComplete
  if enumerationComplete == nil then
    enumerationComplete = true
  else
    enumerationComplete = enumerationComplete == true
  end

  -- Split session failures into source-planned exclusions, accepted map
  -- compile exclusions, and genuine failures. Only map compile failures are
  -- ever accepted by the exclusion option; other families always fail.
  local exclusions = {}
  ---@param message string
  local function noteExclusion(message)
    for _, existing in ipairs(exclusions) do
      if existing == message then
        return
      end
    end
    exclusions[#exclusions + 1] = message
  end
  local failures = {}
  for _, reason in ipairs(requestExcluded) do
    noteExclusion(reason)
  end
  for _, failure in ipairs(status.failures or {}) do
    local message = tostring(failure)
    if isSourceExclusion(message) then
      noteExclusion(message)
    else
      local kind = attributeKind(message, requestedJobs)
      if kind == "map" and options.allowCompileExclusions then
        noteExclusion(message)
      else
        failures[#failures + 1] = message
      end
    end
  end
  -- Exact session dispositions classify their own failures without substring
  -- matching: a failed disposition whose error is a source exclusion (or an
  -- accepted map compile exclusion) is an exclusion, otherwise a failure.
  -- Doubles without an outcome inventory keep the string-matching behavior
  -- below.
  if sessionOutcomes ~= nil then
    for _, item in ipairs(sessionOutcomes) do
      if item.state == "failed" and type(item.error) == "string" then
        local message = item.error
        assert(type(message) == "string", "failed dispositions carry an error string")
        local already = false
        for _, existing in ipairs(failures) do
          if existing == message then
            already = true
            break
          end
        end
        if not already then
          for _, existing in ipairs(exclusions) do
            if existing == message then
              already = true
              break
            end
          end
        end
        if not already then
          if isSourceExclusion(message) then
            noteExclusion(message)
          else
            local kind = attributeKind(message, requestedJobs)
            if kind == "map" and options.allowCompileExclusions then
              noteExclusion(message)
            else
              failures[#failures + 1] = message
            end
          end
        end
      end
    end
  end

  -- Re-query every requested closure so readiness reflects the drained
  -- session rather than the first request round.
  local requestedReady = #failures == 0
  if requestedReady then
    for _, entry in ipairs(parsed) do
      local ready, failure
      if entry.scope == "bootstrap" or entry.scope == "field-core" then
        local scope = assert(entry.scope, "parsed requirements are scopes or canonical jobs")
        ready, failure = session:requestMilestone(scope, "required")
      elseif entry.scope == "complete" then
        local coreReady, coreFailure = session:requestMilestone("field-core", "required")
        ready, failure = session:requestJob("mon-summary", "global", "required")
        if coreFailure ~= nil then
          ready, failure = coreReady, coreFailure
        end
      else
        local kind = assert(entry.kind, "parsed requirements are scopes or canonical jobs")
        local key = assert(entry.key, "parsed requirements are scopes or canonical jobs")
        assert(entry.jobKey ~= nil, "parsed requirements are scopes or canonical jobs")
        ready, failure = session:requestJob(kind, key, "required")
      end
      if failure ~= nil or ready == false then
        -- A requested closure that is excluded or still pending is not ready,
        -- but exclusions are reported rather than failed. Member failures
        -- attribute to their own canonical kind, never to the scope name.
        if failure ~= nil and not isSourceExclusion(tostring(failure)) then
          local kind = attributeKind(tostring(failure), requestedJobs)
          if not (kind == "map" and options.allowCompileExclusions) then
            local message = tostring(failure)
            local seen = false
            for _, existing in ipairs(failures) do
              if existing == message then
                seen = true
                break
              end
            end
            if not seen then
              failures[#failures + 1] = message
            end
          end
        end
        requestedReady = false
      end
    end
  end
  for _, reason in ipairs(requestExcluded) do
    requestedReady = false
    noteExclusion(reason)
  end

  -- Refresh the exact inventory after the readiness re-query: re-querying
  -- can register new interests (milestone members, dependencies).
  if type(session.outcomes) == "function" then
    local okOutcomes, list = pcall(session.outcomes, session)
    if okOutcomes and type(list) == "table" then
      sessionOutcomes = list
      sessionByKey = {}
      for _, item in ipairs(list) do
        if type(item) == "table" and type(item.jobKey) == "string" then
          sessionByKey[item.jobKey] = item
          if type(pool.jobOutcome) == "function" and observedTimings[item.jobKey] == nil then
            local okOutcome, snapshot = pcall(pool.jobOutcome, pool, item.jobKey)
            if okOutcome and type(snapshot) == "table" then
              observedTimings[item.jobKey] = snapshot
            end
          end
        end
      end
    end
  end

  -- One canonical ledger: every planned key appears exactly once. Sources are
  -- the requested closure, the exact session inventory, observed pool facts,
  -- and attributed failure/exclusion identities. Cancellation is explicit
  -- for work that never reached a terminal disposition, never a residual
  -- count subtraction.
  local plannedSet = {}
  local function notePlanned(jobKey)
    if type(jobKey) == "string" and jobKey ~= "" then
      plannedSet[jobKey] = true
    end
  end
  for _, jobKey in ipairs(requestedJobs) do
    notePlanned(jobKey)
  end
  for jobKey in pairs(sessionByKey) do
    notePlanned(jobKey)
  end
  for jobKey in pairs(observedTimings) do
    notePlanned(jobKey)
  end
  local failedByKey, excludedByKey = {}, {}
  local function mapMessageToPlanned(message, target)
    for jobKey in pairs(plannedSet) do
      if message:find(jobKey, 1, true) ~= nil then
        target[jobKey] = message
      end
    end
    for _, jobKey in ipairs(requestedJobs) do
      if message:find(jobKey, 1, true) ~= nil then
        target[jobKey] = message
      end
    end
  end
  for _, message in ipairs(failures) do
    mapMessageToPlanned(message, failedByKey)
  end
  for _, message in ipairs(exclusions) do
    local kind = message:match("^([%w%-]+):")
    local key = kind ~= nil and message:sub(#kind + 2):match("^([^:]+)") or nil
    local mapped = false
    if kind ~= nil and key ~= nil and ArtifactState.KINDS[kind] then
      local jobKey = kind .. ":" .. key
      if plannedSet[jobKey] or sessionByKey[jobKey] ~= nil then
        excludedByKey[jobKey] = message
        mapped = true
      end
    end
    if not mapped then
      mapMessageToPlanned(message, excludedByKey)
    end
  end
  -- Exact dispositions win over substring matching whenever they exist.
  for jobKey, item in pairs(sessionByKey) do
    if item.state == "failed" and type(item.error) == "string" then
      if excludedByKey[jobKey] == nil and failedByKey[jobKey] == nil then
        if isSourceExclusion(item.error) then
          excludedByKey[jobKey] = item.error
        else
          local kind = attributeKind(item.error, requestedJobs)
          if kind == "map" and options.allowCompileExclusions then
            excludedByKey[jobKey] = item.error
          else
            failedByKey[jobKey] = item.error
          end
        end
      end
    end
  end
  for jobKey in pairs(plannedSet) do
    notePlanned(jobKey)
  end
  for jobKey in pairs(failedByKey) do
    notePlanned(jobKey)
  end
  for jobKey in pairs(excludedByKey) do
    notePlanned(jobKey)
  end

  local dispositions = {}
  for jobKey in pairs(plannedSet) do
    local kind, key = jobKey:match("^([^:]+):(.+)$")
    if kind ~= nil and key ~= nil then
      local state, reused, err, causeJobKey = nil, false, nil, nil
      if failedByKey[jobKey] ~= nil then
        state = "failed"
        err = failedByKey[jobKey]
      elseif excludedByKey[jobKey] ~= nil then
        state = "excluded"
        err = excludedByKey[jobKey]
      else
        local sessionItem = sessionByKey[jobKey]
        if sessionItem ~= nil then
          if sessionItem.state == "failed" then
            state = "failed"
            err = sessionItem.error
          elseif sessionItem.state == "successful" then
            state = "successful"
            reused = sessionItem.reused == true
          else
            state = "cancelled"
            causeJobKey = sessionItem.causeJobKey
          end
          if sessionItem.causeJobKey ~= nil then
            causeJobKey = sessionItem.causeJobKey
          end
        elseif observedTimings[jobKey] ~= nil then
          local snapshot = observedTimings[jobKey]
          if type(snapshot) == "table" and snapshot.state == "failed" then
            state = "failed"
            err = snapshot.error ~= nil and tostring(snapshot.error) or (jobKey .. ": compiler job failed")
          else
            state = "successful"
            reused = false
          end
        else
          state = "cancelled"
        end
      end
      -- A reused valid job never fabricates pool timing: reuse is set when
      -- the session reports success without pool execution.
      if state == "successful" and reused == false then
        local sessionItem = sessionByKey[jobKey]
        if sessionItem ~= nil and sessionItem.reused == true then
          reused = true
        elseif type(pool.jobOutcome) == "function" then
          local okOutcome, snapshot = pcall(pool.jobOutcome, pool, jobKey)
          if not (okOutcome and type(snapshot) == "table") then
            reused = true
          end
        elseif observedTimings[jobKey] == nil then
          reused = true
        end
      end
      dispositions[jobKey] = {
        kind = kind,
        key = key,
        jobKey = jobKey,
        state = state,
        reused = reused,
        error = err,
        causeJobKey = causeJobKey,
      }
    end
  end

  local planned, successful, failed, cancelled, excluded = 0, 0, 0, 0, 0
  for _, item in pairs(dispositions) do
    planned = planned + 1
    if item.state == "successful" then
      successful = successful + 1
    elseif item.state == "failed" then
      failed = failed + 1
    elseif item.state == "cancelled" then
      cancelled = cancelled + 1
    elseif item.state == "excluded" then
      excluded = excluded + 1
    end
  end

  -- Observation rows cover every ledger disposition exactly once, ordered
  -- by canonical job key. Observation never changes job identity and
  -- carries no payloads. Unmeasured metrics stay null with reasons.
  local rows = {}
  local rowKeys = {}
  local function addRow(item)
    local jobKey = item.jobKey
    if rowKeys[jobKey] then
      return
    end
    rowKeys[jobKey] = true
    local timings = observeTimings(pool, jobKey, observedTimings)
    local cause = item.error
    local function null(value)
      if value == nil then
        return JSON_NULL
      end
      return value
    end
    rows[#rows + 1] = {
      type = "job",
      schema = PROFILE_SCHEMA,
      versionId = versionId,
      generationId = identity.generationId,
      epoch = epoch,
      kind = item.kind,
      key = item.key,
      jobKey = jobKey,
      state = item.state,
      outcome = item.state,
      reused = item.reused,
      workerId = null(timings.workerId),
      workerIdReason = null(timings.workerIdReason),
      error = null(item.error),
      cause = null(cause),
      causeJobKey = null(item.causeJobKey),
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
  end
  local orderedDispositions = {}
  for _, item in pairs(dispositions) do
    orderedDispositions[#orderedDispositions + 1] = item
  end
  table.sort(orderedDispositions, function(left, right)
    return left.jobKey < right.jobKey
  end)
  for _, item in ipairs(orderedDispositions) do
    addRow(item)
  end

  local sourceExclusions = {}
  for _, message in ipairs(exclusions) do
    if isSourceExclusion(message) then
      sourceExclusions[#sourceExclusions + 1] = message
    end
  end

  local reportOutcomes = {}
  for _, item in ipairs(orderedDispositions) do
    local timings = observeTimings(pool, item.jobKey, observedTimings)
    reportOutcomes[#reportOutcomes + 1] = {
      kind = item.kind,
      key = item.key,
      jobKey = item.jobKey,
      state = item.state,
      reused = item.reused,
      workerId = timings.workerId,
      error = item.error,
      causeJobKey = item.causeJobKey,
      timing = {
        compileSeconds = timings.compileSeconds,
        stageSeconds = timings.stageSeconds,
        workSeconds = timings.workSeconds,
        stagedBytes = timings.stagedBytes,
        timingReason = timings.timingReason,
      },
    }
  end

  local function makeReport(auditPassed, attestationPublished, complete)
    return {
      enumerationComplete = enumerationComplete,
      requestedReady = requestedReady,
      complete = complete,
      auditPassed = auditPassed,
      attestationPublished = attestationPublished,
      exclusions = exclusions,
      sourceExclusions = sourceExclusions,
      failures = failures,
      outcomes = reportOutcomes,
      counts = {
        planned = planned,
        successful = successful,
        failed = failed,
        cancelled = cancelled,
        excluded = excluded,
      },
    }
  end

  local function makeFooter(auditPassed, attestationPublished, complete)
    return {
      type = "footer",
      schema = PROFILE_SCHEMA,
      versionId = versionId,
      generationId = identity.generationId,
      enumerationComplete = enumerationComplete,
      requestedReady = requestedReady,
      complete = complete,
      auditPassed = auditPassed,
      attestationPublished = attestationPublished,
      planned = planned,
      successful = successful,
      failed = failed,
      cancelled = cancelled,
      excluded = excluded,
    }
  end

  local function writeEvidence(footer)
    if profileHandle == nil then
      return nil
    end
    for _, row in ipairs(rows) do
      local err = writeProfileLine(profileHandle, row)
      if err ~= nil then
        return err
      end
    end
    return writeProfileLine(profileHandle, footer)
  end

  local function finish(profileErr, report, logLine, err)
    pcall(session.retire, session)
    pcall(pool.shutdown, pool)
    local closeErr = closeProfile()
    if profileErr ~= nil then
      -- No success claim accompanies observation failures.
      return nil, profileErr
    end
    if closeErr ~= nil then
      return nil, closeErr
    end
    if err ~= nil then
      return nil, err
    end
    if logLine ~= nil then
      log(logLine)
    end
    return report
  end

  for _, message in ipairs(exclusions) do
    log(string.format("build-cache: %s excluded %s", versionId, message))
  end
  for _, message in ipairs(failures) do
    log(string.format("build-cache: %s failed: %s", versionId, message))
  end

  if #failures > 0 then
    local footer = makeFooter(false, false, false)
    local profileErr = writeEvidence(footer)
    local err =
      Errors.new("CACHE_PREPARATION_FAILED", "cache preparation failed", { versionId = versionId, failures = failures })
    if profileErr ~= nil then
      return finish(profileErr, nil, nil, nil)
    end
    return finish(nil, nil, nil, err)
  end

  local needsAttestation = exhaustive and failed == 0 and cancelled == 0 and excluded == 0
  if needsAttestation then
    -- Full attestation only after exhaustive strict validation: the
    -- published inventory must exist for this exact generation and every
    -- expected receipt must validate with a usable payload. A damaged cache
    -- fails here and is never reattested. The successful footer follows the
    -- audit and the attestation, never precedes them.
    local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
    local plans, plansReason = ArtifactJobs.publishedPlans(cacheFs, identity)
    local available, reason
    if plans == nil then
      available, reason = false, plansReason
    else
      available, reason = DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
    end
    if not available then
      local footer = makeFooter(false, false, false)
      local profileErr = writeEvidence(footer)
      local err = Errors.new(
        "CACHE_PREPARATION_FAILED",
        "cache preparation failed: " .. tostring(reason),
        { versionId = versionId }
      )
      if profileErr ~= nil then
        return finish(profileErr, nil, nil, nil)
      end
      return finish(nil, nil, nil, err)
    end
    if command.pending ~= nil then
      command.pending[#command.pending + 1] = { cacheFs = cacheFs, identity = identity }
    else
      local publishOk, publishErr = pcall(DerivedCacheState.publish, cacheFs, identity)
      if not publishOk then
        local footer = makeFooter(true, false, false)
        local profileErr = writeEvidence(footer)
        local err
        if Errors.is(publishErr) then
          err = publishErr --[[@as Errors.Error]]
        else
          err = Errors.new(
            "CACHE_PREPARATION_FAILED",
            "cache preparation failed: " .. tostring(publishErr),
            { versionId = versionId }
          )
        end
        if profileErr ~= nil then
          return finish(profileErr, nil, nil, nil)
        end
        return finish(nil, nil, nil, err)
      end
    end
    local footer = makeFooter(true, true, true)
    local profileErr = writeEvidence(footer)
    if profileErr ~= nil then
      return finish(profileErr, nil, nil, nil)
    end
    local report = makeReport(true, true, true)
    return finish(nil, report, string.format("build-cache: %s complete (%d jobs)", versionId, successful), nil)
  end

  local footer = makeFooter(false, false, false)
  local profileErr = writeEvidence(footer)
  if profileErr ~= nil then
    return finish(profileErr, nil, nil, nil)
  end
  local report = makeReport(false, false, false)
  local logLine
  if exhaustive then
    logLine = string.format("build-cache: %s partial (%d jobs, %d excluded)", versionId, successful, excluded)
  else
    logLine = string.format("build-cache: %s prepared (%d jobs)", versionId, successful)
  end
  return finish(nil, report, logLine, nil)
end

---@param versionId string
---@param options CacheBuilder.VersionOptions
---@return table<string, unknown>|nil report
---@return Errors.Error|string|nil err
function CacheBuilder.prepareVersion(versionId, options)
  return runScopedVersion(
    versionId,
    options or {},
    { pending = nil, profileHandle = nil, profilePath = (options or {}).profile }
  )
end

---@param versionId string
---@param dev boolean|nil
---@param producerFingerprint string|nil working-tree digest; present exactly when dev is true
---@return table<string, unknown>|nil identity
---@return Errors.Error|string|nil err
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

  -- Development identity hashes the producer working tree resolved
  -- against the caller's checkout root: none of the default source roots
  -- resolve under the packaged VFS root, so the VFS backend would hash the
  -- empty manifest and dirty bytes would never invalidate the cache. Release
  -- identity uses the explicit per-game counter and reads no producer
  -- sources.
  local producerFingerprint
  if options.dev == true then
    local repositoryRoot =
      assert(options.developmentRepositoryRoot, "development builds require the repository root the process runs from")
    producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(repositoryRoot))
  end
  -- Each version prepares through its own pool and session; new full-build
  -- attestations wait until every requested version satisfies the strict
  -- completion policy.
  local pending = {}
  local profileHandle
  if options.profile ~= nil then
    local handle, openErr = io.open(options.profile, "w")
    if handle == nil then
      log("build-cache: execution evidence cannot be opened: " .. tostring(openErr))
      return nil, "cache preparation failed"
    end
    profileHandle = handle
  end
  local function closeShared()
    if profileHandle ~= nil then
      pcall(profileHandle.close, profileHandle)
      profileHandle = nil
    end
  end

  local allOk, hasCompileExclusions, exclusionCount = true, false, 0
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
      local report, prepareErr = runScopedVersion(version, {
        identity = identity,
        requirements = { "complete" },
        allowCompileExclusions = options.allowCompileExclusions,
        log = log,
        developmentRepositoryRoot = options.developmentRepositoryRoot,
      }, { pending = pending, profileHandle = profileHandle, profilePath = nil })
      if report == nil then
        assert(prepareErr ~= nil, "a failed scope reports its cause")
        return nil, prepareErr
      end
      local scopeExclusions = report.exclusions
      assert(type(scopeExclusions) == "table", "scoped preparation reports its exclusions")
      if #scopeExclusions > 0 then
        hasCompileExclusions = true
        exclusionCount = exclusionCount + #scopeExclusions
      end
      return true
    end)
    if not ok then
      -- A structured source failure fails its version and lets the remaining
      -- versions run; only a programming fault aborts the batch.
      if Errors.is(result) then
        allOk = false
        log("build-cache: " .. version .. " failed: " .. Errors.format(result))
      else
        closeShared()
        error(result, 0)
      end
    elseif result == nil then
      allOk = false
      log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
    end
  end

  if hasCompileExclusions and not options.allowCompileExclusions then
    log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    allOk = false
  end
  if not allOk then
    closeShared()
    return nil, "cache preparation failed"
  end
  -- New full-build attestations wait until every requested version satisfies
  -- the strict completion policy; independently published artifacts stay
  -- resumable and previously valid attestations are untouched.
  for _, attestation in ipairs(pending) do
    DerivedCacheState.publish(attestation.cacheFs, attestation.identity)
  end
  closeShared()
  return { published = true, complete = not hasCompileExclusions, exclusionCount = exclusionCount }
end

return CacheBuilder
