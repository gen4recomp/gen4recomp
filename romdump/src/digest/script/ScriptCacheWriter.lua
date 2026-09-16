-- Persists the derived script class through worker-owned prepared stages:
-- each member job stages exactly its own member directory into a private
-- stage, readback-validated there, and only the controller publishes it, so
-- a private repair of an already selected generation never mutates live
-- files. A final summary job proves every planned member is current in the
-- live cache, then stages the generation summary (under the generation's
-- `metadata/` child, disjoint from `members/`) together with the active
-- selector in one transaction. Staging and validation are one step;
-- publication happens outside that step's error handler, so a publish
-- failure never triggers writer-level stage cleanup that could delete the
-- last remaining copy of the previous artifact.

local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Coverage = require("romdump.src.digest.script.Coverage")
local Errors = require("libs.errors.src.Errors")

local ScriptCacheWriter = {}

---@param cacheFs CacheFs
---@param marker string
---@return boolean
function ScriptCacheWriter.isReady(cacheFs, marker)
  return ScriptCache.isReady(cacheFs, marker)
end

-- A dependency-free JSON writer for the coverage record (LuaWriter encodes
-- Lua, not JSON). Strings escape control characters properly.
local function jsonValue(value)
  local ty = type(value)
  if ty == "nil" then
    return "null"
  end
  if ty == "boolean" then
    return value and "true" or "false"
  end
  if ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    local escaped = value:gsub('["\\\n\r\t\b\f]', {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
    })
    return '"' .. escaped .. '"'
  end
  if ty == "table" then
    -- A contiguous 1-based array becomes a JSON array; anything with
    -- non-array keys (including numeric-keyed hash tables like the opcode
    -- map) becomes an object with stringified keys.
    local isArray = true
    local maxKey = 0
    for key in pairs(value) do
      if type(key) ~= "number" then
        isArray = false
        break
      end
      if key > maxKey then
        maxKey = key
      end
    end
    if isArray and maxKey == #value then
      local parts = {}
      for i = 1, #value do
        parts[#parts + 1] = jsonValue(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = '"' .. tostring(key) .. '":' .. jsonValue(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function memberFor(plan, memberId)
  for _, member in ipairs(plan.members) do
    if member.memberId == memberId then
      return member
    end
  end
  Errors.raise("SCRIPT_MEMBER_INVALID", "unknown planned script member: " .. tostring(memberId), {
    memberId = memberId,
  })
end

local function memberResourceIndex(plan, memberId)
  local ids = {}
  for _, entry in ipairs(plan.resources) do
    if entry.member == memberId then
      ids[#ids + 1] = entry
    end
  end
  return ids
end

local function validateMember(plan, member)
  local planned = memberFor(plan, member.memberId)
  if member.marker ~= planned.marker then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member marker mismatch", { memberId = member.memberId })
  end
  if type(member.coverage) ~= "table" then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member coverage is missing", { memberId = member.memberId })
  end
  local expected = memberResourceIndex(plan, member.memberId)
  if #expected ~= #member.resources then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource count mismatch", { memberId = member.memberId })
  end
  local seen = {}
  for _, entry in ipairs(member.resources) do
    if type(entry.id) ~= "string" or seen[entry.id] then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource identity is invalid", {
        memberId = member.memberId,
      })
    end
    seen[entry.id] = true
    local found
    for _, candidate in ipairs(expected) do
      if candidate.id == entry.id and candidate.scriptIndex == entry.scriptIndex then
        found = candidate
        break
      end
    end
    if found == nil then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource is not in the plan", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
    if type(entry.resource) ~= "table" or entry.resource.id ~= entry.id then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource is malformed", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
  end
end

local function validateCoverage(plan, memberId, coverage)
  local context = { memberId = memberId }
  local function invalid(message)
    Errors.raise("SCRIPT_MEMBER_COVERAGE_INVALID", message, context)
  end
  local expected = memberResourceIndex(plan, memberId)
  if type(coverage) ~= "table" then
    invalid("script member coverage is malformed")
  end
  if type(coverage.source) ~= "table" then
    invalid("script member coverage source is missing")
  end
  if type(coverage.totals) ~= "table" then
    invalid("script member coverage totals are missing")
  end
  if coverage.totals.members ~= 1 then
    invalid("script member coverage must describe one member")
  end
  if coverage.totals.scripts ~= #expected then
    invalid("script member coverage script count mismatch")
  end
  if type(coverage.opcodes) ~= "table" then
    invalid("script member coverage opcodes are missing")
  end
  if type(coverage.scripts) ~= "table" or #coverage.scripts ~= #expected then
    invalid("script member coverage scripts are invalid")
  end
  local expectedById = {}
  for _, entry in ipairs(expected) do
    expectedById[entry.id] = entry
  end
  local seen = {}
  for _, entry in ipairs(coverage.scripts) do
    if type(entry) ~= "table" or type(entry.publicId) ~= "string" then
      invalid("script member coverage identity is invalid")
    end
    if seen[entry.publicId] then
      invalid("script member coverage contains a duplicate resource")
    end
    local planned = expectedById[entry.publicId]
    if type(planned) ~= "table" then
      invalid("script member coverage resource is not in the plan")
    end
    local sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, planned.scriptIndex)
    if entry.sourceId ~= sourceId then
      invalid("script member coverage source identity mismatch")
    end
    seen[entry.publicId] = true
  end
end

local function resourceMatchesEntry(resource, entry)
  if type(resource) ~= "table" or resource.kind ~= "field_script" or resource.id ~= entry.id then
    return false
  end
  local metadata = resource.metadata
  local source = type(metadata) == "table" and metadata.source
  return type(source) == "table" and source.member == entry.member and source.scriptIndex == entry.scriptIndex
end

local function readbackResource(reader, plan, entry)
  local resource = reader:loadModule(ScriptCache.scriptPath(plan.generationKey, entry.member, entry.id))
  if not resourceMatchesEntry(resource, entry) then
    Errors.raise("SCRIPT_MEMBER_READBACK_FAILED", "script resource readback identity mismatch", {
      memberId = entry.member,
      id = entry.id,
    })
  end
end

-- A staging handle is a worker-owned preparation, never a live cache: the
-- member writer rejects anything without a private stage before any file
-- write, so an active generation can never be edited in place.
local function assertArtifact(artifact, operation)
  if
    type(artifact) ~= "table"
    or type(artifact.stageFs) ~= "function"
    or type(artifact.cacheFs) ~= "function"
    or type(artifact.addOwnedRoot) ~= "function"
  then
    Errors.raise("SCRIPT_MEMBER_INVALID", operation .. " requires a PreparedArtifact", {})
  end
end

-- The one staging step every member entry point shares: validate the
-- compiled payload against the plan, write exactly this member's payload and
-- marker into the given stage filesystem, and prove they read back with the
-- current identity before the marker lands. Never touches a sibling member
-- or the live cache.
local function persistMember(stage, plan, member)
  validateMember(plan, member)
  local root = ScriptCache.memberDir(plan.generationKey, member.memberId)
  stage:removeTree(root)
  local emitOpts = {
    sourcePath = plan.sourcePath,
    romSha1 = plan.romSha1,
    game = plan.version,
  }
  for _, entry in ipairs(member.resources) do
    local path = ScriptCache.scriptPath(plan.generationKey, member.memberId, entry.id)
    stage:write(path, ScriptCompiler.emit(entry, emitOpts))
    readbackResource(stage, plan, entry)
  end
  stage:writeLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId), member.coverage)
  validateCoverage(
    plan,
    member.memberId,
    assert(stage:loadLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId)))
  )
  stage:write(ScriptCache.memberMarkerPath(plan.generationKey, member.memberId), member.marker)
  if stage:read(ScriptCache.memberMarkerPath(plan.generationKey, member.memberId)) ~= member.marker then
    Errors.raise("SCRIPT_MEMBER_READBACK_FAILED", "script member marker readback failed", {
      memberId = member.memberId,
    })
  end
  return member.marker
end

-- Stage one compiled member through a caller-owned prepared artifact: the
-- stage owns exactly this member's directory, so member jobs never overlap
-- and a private repair of an already selected generation never touches live
-- files. Publication stays with the caller; a stage failure leaves the
-- previous live member untouched once the caller aborts the disposable
-- stage.
---@param artifact PreparedArtifact
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@param member { memberId: integer, marker: string, coverage: table<string, unknown>, resources: unknown[] }
---@return string
function ScriptCacheWriter.stageMember(artifact, plan, member)
  assertArtifact(artifact, "stageMember")
  assert(type(plan) == "table" and type(member) == "table", "stageMember requires a plan and member")
  validateMember(plan, member)
  artifact:addOwnedRoot(ScriptCache.memberDir(plan.generationKey, member.memberId))
  return persistMember(artifact:stageFs(), plan, member)
end

local function orderedMembers(plan)
  local ordered = {}
  for _, member in ipairs(plan.members) do
    ordered[#ordered + 1] = member
  end
  table.sort(ordered, function(a, b)
    return a.memberId < b.memberId
  end)
  return ordered
end

local function checkPlan(plan)
  assert(type(plan) == "table" and type(plan.generationKey) == "string", "script generation plan is required")
  assert(
    type(plan.marker) == "string" and type(plan.members) == "table",
    "script generation plan identity is incomplete"
  )
  local skippedMembers = plan.skippedMembers or {}
  assert(type(plan.resources) == "table", "script generation resources are missing")
  assert(plan.memberCount == #plan.members + #skippedMembers, "script generation member coverage is incomplete")
  local expectedIndex = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = plan.version,
    generation = plan.generationKey,
    marker = plan.marker,
    memberCount = plan.memberCount,
    scriptMemberCount = #plan.members,
    skippedMemberCount = #skippedMembers,
    scriptCount = #plan.resources,
    resourceCount = #plan.resources,
    resources = {},
  }
  for _, entry in ipairs(plan.resources) do
    expectedIndex.resources[#expectedIndex.resources + 1] = {
      id = entry.id,
      member = entry.member,
      scriptIndex = entry.scriptIndex,
    }
  end
  if plan.index ~= nil then
    assert(plan.index.schema == expectedIndex.schema, "script generation index schema mismatch")
    for _, key in ipairs({
      "version",
      "generation",
      "marker",
      "memberCount",
      "scriptMemberCount",
      "skippedMemberCount",
      "scriptCount",
      "resourceCount",
    }) do
      assert(plan.index[key] == expectedIndex[key], "script generation plan identity mismatch: " .. key)
    end
    assert(
      type(plan.index.resources) == "table" and #plan.index.resources == #expectedIndex.resources,
      "script generation resource plan mismatch"
    )
    for index, entry in ipairs(expectedIndex.resources) do
      local actual = plan.index.resources[index]
      assert(
        type(actual) == "table"
          and actual.id == entry.id
          and actual.member == entry.member
          and actual.scriptIndex == entry.scriptIndex,
        "script generation resource plan identity mismatch"
      )
    end
  end
  return expectedIndex
end

local function memberIsComplete(liveFs, plan, member)
  return ScriptCacheWriter.isMemberReady(liveFs, plan, member.memberId) == true
end

-- Proves one planned member is usable in the live cache under its planned
-- marker: the exact marker, the expected resource identities and the coverage
-- metadata, all read back with the current generation identity. This is the
-- same proof the generation summary demands of every member before staging,
-- exposed so readiness checks cannot drift from it.
---@param cacheFs CacheFs
---@param plan { generationKey: string, members: unknown[], resources: unknown[] }
---@param memberId integer|string
---@return boolean
---@return string|nil
function ScriptCacheWriter.isMemberReady(cacheFs, plan, memberId)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "script member readiness requires a cache filesystem")
  assert(type(plan) == "table", "script member readiness requires the generation plan")
  local id = assert(tonumber(memberId), "script member readiness requires a member identity")
  local found, member = pcall(memberFor, plan, id)
  if not found or type(member) ~= "table" then
    return false, "unknown planned script member: " .. tostring(memberId)
  end
  ---@cast member { marker: string, memberId: integer }
  if cacheFs:read(ScriptCache.memberMarkerPath(plan.generationKey, id)) ~= member.marker then
    return false, "script member " .. tostring(id) .. " has no current marker"
  end
  local coverageOk, coverage = pcall(cacheFs.loadLua, cacheFs, ScriptCache.memberCoveragePath(plan.generationKey, id))
  if not coverageOk or type(coverage) ~= "table" then
    return false, "script member " .. tostring(id) .. " has no usable coverage"
  end
  local coverageValid, coverageErr = pcall(validateCoverage, plan, id, coverage)
  if not coverageValid then
    return false, "script member " .. tostring(id) .. " coverage is not usable: " .. tostring(coverageErr)
  end
  for _, entry in ipairs(memberResourceIndex(plan, id)) do
    local readOk, readErr = pcall(readbackResource, cacheFs, plan, entry)
    if not readOk then
      return false, "script member " .. tostring(id) .. " resource is not usable: " .. tostring(readErr)
    end
  end
  return true
end

local function aggregateCoverage(records, plan)
  if #records == 0 then
    return { source = { repository = "g4recomp", romSha1 = plan.romSha1 or "" }, totals = { members = 0, scripts = 0 } }
  end
  if records[1].totals ~= nil then
    return Coverage.aggregate(records)
  end
  local scripts = 0
  for _, record in ipairs(records) do
    scripts = scripts + (record.scripts or 0)
  end
  return {
    source = { repository = "g4recomp", romSha1 = plan.romSha1 or "" },
    totals = {
      members = #records,
      scripts = scripts,
      reachableInstructions = 0,
      supportedInstructions = 0,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = {},
  }
end

-- The one staging step every summary entry point shares: prove every planned
-- member is current in the live cache under its planned marker, then write
-- the generation summary into the generation's `metadata/` child plus the
-- active selector into the stage. Member directories are never staged here,
-- so the summary cannot erase independently published members, and the
-- parent generation directory is never replaced.
local function persistSummary(stage, liveFs, plan)
  local expectedIndex = checkPlan(plan)
  local missing = {}
  for _, member in ipairs(orderedMembers(plan)) do
    if not memberIsComplete(liveFs, plan, member) then
      missing[#missing + 1] = member.memberId
    end
  end
  if #missing > 0 then
    Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses incomplete member coverage", {
      generation = plan.generationKey,
      missingMemberIds = missing,
    })
  end
  local records = {}
  for _, member in ipairs(orderedMembers(plan)) do
    records[#records + 1] = assert(liveFs:loadLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId)))
  end
  local coverage = aggregateCoverage(records, plan)
  local coverageJson = jsonValue(coverage) .. "\n"
  local coverageMd = Coverage.markdown(coverage)
  local provenance = {
    schema = ScriptCache.PROVENANCE_SCHEMA,
    generation = plan.generationKey,
    marker = plan.marker,
    dependencies = plan.dependencies,
  }
  stage:writeLua(ScriptCache.generationIndexPath(plan.generationKey), expectedIndex)
  stage:writeLua(ScriptCache.generationProvenancePath(plan.generationKey), provenance)
  stage:write(ScriptCache.generationCoverageJsonPath(plan.generationKey), coverageJson)
  stage:write(ScriptCache.generationCoverageMdPath(plan.generationKey), coverageMd)
  stage:write(ScriptCache.generationMarkerPath(plan.generationKey), plan.marker)
  local stagedIndex = stage:loadLua(ScriptCache.generationIndexPath(plan.generationKey))
  if
    type(stagedIndex) ~= "table"
    or stagedIndex.schema ~= ScriptCache.INDEX_SCHEMA
    or stagedIndex.generation ~= plan.generationKey
    or stagedIndex.marker ~= plan.marker
  then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script summary index readback failed", {
      generation = plan.generationKey,
    })
  end
  if stage:read(ScriptCache.generationMarkerPath(plan.generationKey)) ~= plan.marker then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script summary marker readback failed", {
      generation = plan.generationKey,
    })
  end
  stage:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = plan.generationKey,
    marker = plan.marker,
  })
  stage:writeLua(ScriptCache.provenancePath(), provenance)
  stage:write(ScriptCache.coverageJsonPath(), coverageJson)
  stage:write(ScriptCache.coverageMdPath(), coverageMd)
  stage:write(ScriptCache.markerPath(), plan.marker)
  local stagedActive = stage:loadLua(ScriptCache.activeIndexPath())
  if
    type(stagedActive) ~= "table"
    or stagedActive.schema ~= ScriptCache.INDEX_SCHEMA
    or stagedActive.generation ~= plan.generationKey
    or stagedActive.marker ~= plan.marker
  then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script active selection readback failed", {
      generation = plan.generationKey,
    })
  end
  if stage:read(ScriptCache.markerPath()) ~= plan.marker then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script active marker readback failed", {
      generation = plan.generationKey,
    })
  end
  return plan.marker
end

-- Stage the generation summary through a caller-owned prepared artifact: the
-- stage owns exactly the generation metadata directory plus the active
-- selector directory in one publication transaction, never the member
-- directories. Publication stays with the caller; a summary failure leaves
-- the previous active selector usable for its old identity.
---@param artifact PreparedArtifact
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@return string
function ScriptCacheWriter.stageSummary(artifact, plan)
  assertArtifact(artifact, "stageSummary")
  assert(type(plan) == "table", "stageSummary requires a generation plan")
  artifact:addOwnedRoot(ScriptCache.generationMetadataDir(plan.generationKey))
  artifact:addOwnedRoot(ScriptCache.activeDir())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), plan)
end

-- Publish the generation summary straight into the live cache for the batch
-- build. Refuses while any planned member is unpublished; raises like every
-- other writer boundary.
---@param cacheFs CacheFs
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@return string
function ScriptCacheWriter.writeSummary(cacheFs, plan)
  assert(cacheFs and cacheFs.writeLua, "writeSummary requires a cache")
  assert(type(plan) == "table" and type(plan.generationKey) == "string", "writeSummary requires a generation plan")
  local tx = ArtifactPublisher.begin(cacheFs, "scripts", {
    ScriptCache.generationMetadataDir(plan.generationKey),
    ScriptCache.activeDir(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, plan)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

function ScriptCacheWriter.cleanupGenerations(cacheFs, keepSet)
  local protected = {}
  for generation in pairs(keepSet or {}) do
    protected[generation] = true
  end
  local active = cacheFs:loadLua(ScriptCache.activeIndexPath())
  if type(active) == "table" and type(active.generation) == "string" then
    protected[active.generation] = true
  end
  local names = cacheFs:getDirectoryItems(ScriptCache.generationsDir())
  for _, generation in ipairs(names) do
    if not protected[generation] then
      cacheFs:removeTree(ScriptCache.generationDir(generation))
    end
  end
  return true
end

return ScriptCacheWriter
