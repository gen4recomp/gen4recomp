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
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")
local Validate = require("libs.assets.src.Validate")

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
  return resource
end

-- The canonical content hash: exactly what the runtime registry fingerprint
-- computes for the same decoded resource, so published hashes seed it
-- without decoding bodies again.
local function canonicalResourceHash(resource)
  return Sha256.hex(LuaWriter.encode(resource))
end

-- True when the value is a sorted unique array of non-empty strings (the
-- shape of every persisted dependency list, so identical inputs always
-- encode identically and duplicates can never mask a missing edge).
local function isSortedUniqueStrings(value)
  if not Validate.isArray(value) then
    return false
  end
  local previous
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      return false
    end
    if previous ~= nil and previous >= entry then
      return false
    end
    previous = entry
  end
  return true
end

-- Validate a staged or published hash sidecar against its planned member:
-- current schema, generation, member identity and marker, plus an exact
-- bijection between the sidecar records and the planned member resources.
-- Returns the sidecar's hashes keyed by resource id, or nil plus a cause
-- when the sidecar cannot attest this member.
local function checkSidecar(plan, memberId, memberMarker, sidecar)
  if type(sidecar) ~= "table" then
    return nil, "script member " .. tostring(memberId) .. " has no published resource hashes"
  end
  if sidecar.schema ~= ScriptCache.HASHES_SCHEMA then
    return nil, "script member " .. tostring(memberId) .. " resource hashes use an unknown schema"
  end
  if sidecar.generation ~= plan.generationKey or sidecar.memberId ~= memberId or sidecar.marker ~= memberMarker then
    return nil, "script member " .. tostring(memberId) .. " resource hashes are not current"
  end
  if not Validate.isArray(sidecar.resources) then
    return nil, "script member " .. tostring(memberId) .. " resource hashes are malformed"
  end
  local expected = memberResourceIndex(plan, memberId)
  if #sidecar.resources ~= #expected then
    return nil, "script member " .. tostring(memberId) .. " resource hash coverage is incomplete"
  end
  local expectedById = {}
  for _, candidate in ipairs(expected) do
    expectedById[candidate.id] = candidate
  end
  local byId = {}
  for _, record in ipairs(sidecar.resources) do
    if type(record) ~= "table" or type(record.id) ~= "string" then
      return nil, "script member " .. tostring(memberId) .. " resource hash identity is invalid"
    end
    local planned = expectedById[record.id]
    if planned == nil or record.scriptIndex ~= planned.scriptIndex then
      return nil, "script member " .. tostring(memberId) .. " resource hash is not in the plan"
    end
    if byId[record.id] ~= nil or not Validate.isSha256Key(record.resourceHash) then
      return nil, "script member " .. tostring(memberId) .. " resource hash is invalid"
    end
    if not isSortedUniqueStrings(record.audioSequences) then
      return nil, "script member " .. tostring(memberId) .. " audio dependency metadata is malformed"
    end
    if not isSortedUniqueStrings(record.scriptTargets) then
      return nil, "script member " .. tostring(memberId) .. " script dependency metadata is malformed"
    end
    byId[record.id] = record.resourceHash
  end
  return byId
end

local function loadSidecar(reader, plan, memberId, memberMarker)
  local ok, sidecar = pcall(reader.loadLua, reader, ScriptCache.memberHashesPath(plan.generationKey, memberId))
  if not ok then
    return nil, "script member " .. tostring(memberId) .. " has no published resource hashes"
  end
  return checkSidecar(plan, memberId, memberMarker, sidecar)
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
  local hashes = {}
  for _, entry in ipairs(member.resources) do
    local path = ScriptCache.scriptPath(plan.generationKey, member.memberId, entry.id)
    stage:write(path, ScriptCompiler.emit(entry, emitOpts))
    local resource = readbackResource(stage, plan, entry)
    -- Compiler-supplied dependency facts are mandatory staging input:
    -- the writer validates and persists them but never recomputes them,
    -- so a compiler contract defect fails loudly instead of hiding
    -- behind a repaired member.
    local direct = entry.directDependencies
    if
      type(direct) ~= "table"
      or not isSortedUniqueStrings(direct.audioSequences)
      or not isSortedUniqueStrings(direct.scriptTargets)
    then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource dependency metadata is missing", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
    hashes[#hashes + 1] = {
      id = entry.id,
      scriptIndex = entry.scriptIndex,
      resourceHash = canonicalResourceHash(resource),
      audioSequences = direct.audioSequences,
      scriptTargets = direct.scriptTargets,
    }
  end
  table.sort(hashes, function(a, b)
    if a.id ~= b.id then
      return a.id < b.id
    end
    return a.scriptIndex < b.scriptIndex
  end)
  stage:writeLua(ScriptCache.memberHashesPath(plan.generationKey, member.memberId), {
    schema = ScriptCache.HASHES_SCHEMA,
    generation = plan.generationKey,
    memberId = member.memberId,
    marker = member.marker,
    resources = hashes,
  })
  local stagedHashes = assert(stage:loadLua(ScriptCache.memberHashesPath(plan.generationKey, member.memberId)))
  assert(checkSidecar(plan, member.memberId, member.marker, stagedHashes))
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

local function aggregateCoverage(records, plan)
  if #records == 0 then
    return { source = { repository = "portemon", romSha1 = plan.romSha1 or "" }, totals = { members = 0, scripts = 0 } }
  end
  if records[1].totals ~= nil then
    return Coverage.aggregate(records)
  end
  local scripts = 0
  for _, record in ipairs(records) do
    scripts = scripts + (record.scripts or 0)
  end
  return {
    source = { repository = "portemon", romSha1 = plan.romSha1 or "" },
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

-- Join every planned resource's published canonical hash and the
-- transitive script-audio closure into the generation index in one member
-- sidecar traversal: each current member's sidecar must attest exactly its
-- planned resources, so the published index describes precisely the current
-- member bodies with no missing, extra, or duplicate records, and every
-- declared cross-script target must resolve to a planned resource before a
-- deterministic fixed point unions each resource's direct audio with its
-- targets' closures (cycles converge because iteration only grows sets over
-- a sorted resource order), aggregated per member as sorted unique arrays
-- keyed by decimal member id. Audio-free members carry an explicit empty
-- array. Loads each already-required member sidecar exactly once; never
-- resource bodies.
local function joinMemberMetadata(liveFs, plan, expectedIndex)
  local directAudio, directTargets, memberOf = {}, {}, {}
  for _, entry in ipairs(plan.resources) do
    memberOf[entry.id] = entry.member
  end
  local hashesByMember = {}
  for _, member in ipairs(orderedMembers(plan)) do
    local ok, sidecar = pcall(liveFs.loadLua, liveFs, ScriptCache.memberHashesPath(plan.generationKey, member.memberId))
    if not ok then
      Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses a member without published hashes", {
        generation = plan.generationKey,
        missingMemberIds = { member.memberId },
      })
    end
    local hashes, hashesErr = checkSidecar(plan, member.memberId, member.marker, sidecar)
    if hashes == nil then
      Errors.raise(
        "SCRIPT_SUMMARY_INCOMPLETE",
        "script summary refuses invalid published hashes: " .. tostring(hashesErr),
        {
          generation = plan.generationKey,
          missingMemberIds = { member.memberId },
        }
      )
    end
    hashesByMember[member.memberId] = hashes
    for _, record in ipairs(sidecar.resources) do
      directAudio[record.id] = record.audioSequences
      directTargets[record.id] = record.scriptTargets
    end
  end
  for _, entry in ipairs(expectedIndex.resources) do
    local memberHashes = hashesByMember[entry.member]
    local resourceHash = memberHashes and memberHashes[entry.id]
    if resourceHash == nil then
      Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses an unattested resource", {
        generation = plan.generationKey,
        id = entry.id,
      })
    end
    entry.resourceHash = resourceHash
  end
  local resourceIds = {}
  for _, entry in ipairs(plan.resources) do
    resourceIds[#resourceIds + 1] = entry.id
  end
  table.sort(resourceIds)
  for _, id in ipairs(resourceIds) do
    for _, target in ipairs(directTargets[id]) do
      if memberOf[target] == nil then
        Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses an unknown script target: " .. target, {
          generation = plan.generationKey,
          id = id,
        })
      end
    end
  end
  local closure = {}
  for _, id in ipairs(resourceIds) do
    local seen = {}
    for _, symbol in ipairs(directAudio[id]) do
      seen[symbol] = true
    end
    closure[id] = seen
  end
  local changed = true
  while changed do
    changed = false
    for _, id in ipairs(resourceIds) do
      local seen = closure[id]
      for _, target in ipairs(directTargets[id]) do
        for symbol in pairs(closure[target]) do
          if seen[symbol] == nil then
            seen[symbol] = true
            changed = true
          end
        end
      end
    end
  end
  local memberAudioSequences = {}
  for _, member in ipairs(orderedMembers(plan)) do
    memberAudioSequences[tostring(member.memberId)] = {}
  end
  for _, id in ipairs(resourceIds) do
    local union = memberAudioSequences[tostring(memberOf[id])]
    for symbol in pairs(closure[id]) do
      union[symbol] = true
    end
  end
  for key, union in pairs(memberAudioSequences) do
    local list = {}
    for symbol in pairs(union) do
      list[#list + 1] = symbol
    end
    table.sort(list)
    memberAudioSequences[key] = list
  end
  expectedIndex.memberAudioSequences = memberAudioSequences
end

local function memberIsComplete(liveFs, plan, member)
  return ScriptCacheWriter.isMemberReady(liveFs, plan, member.memberId) == true
end

-- Proves one planned member is usable in the live cache under its planned
-- marker: the exact marker, the expected resource identities and the coverage
-- metadata, the published canonical resource hashes, all read back with the
-- current generation identity. The sidecar hashes are validated against the
-- current emitted bodies, never trusted blindly. This is the same proof the
-- generation summary demands of every member before staging, exposed so
-- readiness checks cannot drift from it.
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
  local hashes, hashesErr = loadSidecar(cacheFs, plan, id, member.marker)
  if hashes == nil then
    return false, tostring(hashesErr)
  end
  for _, entry in ipairs(memberResourceIndex(plan, id)) do
    local readOk, resource = pcall(readbackResource, cacheFs, plan, entry)
    if not readOk then
      return false, "script member " .. tostring(id) .. " resource is not usable: " .. tostring(resource)
    end
    if
      canonicalResourceHash(resource --[[@as table<string, unknown>]]) ~= hashes[entry.id]
    then
      return false, "script member " .. tostring(id) .. " resource hash does not match its body"
    end
  end
  return true
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
  joinMemberMetadata(liveFs, plan, expectedIndex)
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
