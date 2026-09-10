-- Persists the derived script class through the shared staged publication
-- primitive: the provenance record, the index, the coverage report, and one
-- file per translated script are written into a disposable staging root,
-- readback-validated there, and only then is the completed stage published
-- with the marker last. Staging and validation are one step; publication
-- happens outside that step's error handler, so a publish failure never
-- triggers writer-level stage cleanup that could delete the last remaining
-- copy of the previous artifact.

local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Coverage = require("romdump.src.digest.script.Coverage")
local CacheFs = require("libs.storage.src.CacheFs")

local ScriptCacheWriter = {}

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
  error("unknown planned script member: " .. tostring(memberId), 3)
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
  assert(member.marker == planned.marker, "script member marker mismatch")
  assert(type(member.coverage) == "table", "script member coverage is missing")
  local expected = memberResourceIndex(plan, member.memberId)
  assert(#expected == #member.resources, "script member resource count mismatch")
  local seen = {}
  for _, entry in ipairs(member.resources) do
    assert(type(entry.id) == "string" and not seen[entry.id], "script member resource identity is invalid")
    seen[entry.id] = true
    local found
    for _, candidate in ipairs(expected) do
      if candidate.id == entry.id and candidate.scriptIndex == entry.scriptIndex then
        found = candidate
        break
      end
    end
    assert(found ~= nil, "script member resource is not in the plan")
    assert(type(entry.resource) == "table" and entry.resource.id == entry.id, "script member resource is malformed")
  end
end

local function validateCoverage(plan, memberId, coverage)
  local expected = memberResourceIndex(plan, memberId)
  assert(type(coverage) == "table", "script member coverage is malformed")
  assert(type(coverage.source) == "table", "script member coverage source is missing")
  assert(type(coverage.totals) == "table", "script member coverage totals are missing")
  assert(coverage.totals.members == 1, "script member coverage must describe one member")
  assert(coverage.totals.scripts == #expected, "script member coverage script count mismatch")
  assert(type(coverage.opcodes) == "table", "script member coverage opcodes are missing")
  assert(
    type(coverage.scripts) == "table" and #coverage.scripts == #expected,
    "script member coverage scripts are invalid"
  )
  local expectedById = {}
  for _, entry in ipairs(expected) do
    expectedById[entry.id] = entry
  end
  local seen = {}
  for _, entry in ipairs(coverage.scripts) do
    assert(type(entry) == "table" and type(entry.publicId) == "string", "script member coverage identity is invalid")
    assert(not seen[entry.publicId], "script member coverage contains a duplicate resource")
    local planned = expectedById[entry.publicId]
    assert(planned ~= nil, "script member coverage resource is not in the plan")
    local sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, planned.scriptIndex)
    assert(entry.sourceId == sourceId, "script member coverage source identity mismatch")
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

local function readbackResource(cacheFs, plan, entry)
  local resource = cacheFs:loadModule(ScriptCache.scriptPath(plan.generationKey, entry.member, entry.id))
  assert(resourceMatchesEntry(resource, entry), "script resource readback identity mismatch")
end

local function memberIsComplete(cacheFs, plan, member)
  if cacheFs:read(ScriptCache.memberMarkerPath(plan.generationKey, member.memberId)) ~= member.marker then
    return false
  end
  local coverage = cacheFs:loadLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId))
  local ok = pcall(validateCoverage, plan, member.memberId, coverage)
  if not ok then
    return false
  end
  for _, entry in ipairs(memberResourceIndex(plan, member.memberId)) do
    local loaded = cacheFs:loadModule(ScriptCache.scriptPath(plan.generationKey, member.memberId, entry.id))
    if not resourceMatchesEntry(loaded, entry) then
      return false
    end
  end
  return true
end

local function activeGeneration(cacheFs)
  local liveCache = CacheFs.forVersion(cacheFs.versionId, cacheFs.backend)
  local active = liveCache:loadLua(ScriptCache.activeIndexPath())
  if type(active) == "table" and type(active.generation) == "string" then
    return active.generation
  end
  return nil
end

function ScriptCacheWriter.stageMember(cacheFs, plan, member)
  assert(cacheFs and cacheFs.writeLua and plan and member, "stageMember requires a cache and member")
  validateMember(plan, member)
  if activeGeneration(cacheFs) == plan.generationKey and not memberIsComplete(cacheFs, plan, member) then
    error("cannot stage a member into the active script generation", 2)
  end
  if memberIsComplete(cacheFs, plan, member) then
    return true
  end
  local root = ScriptCache.memberDir(plan.generationKey, member.memberId)
  cacheFs:removeTree(root)
  local emitOpts = {
    sourcePath = plan.sourcePath,
    romSha1 = plan.romSha1,
    game = plan.version,
  }
  for _, entry in ipairs(member.resources) do
    local path = ScriptCache.scriptPath(plan.generationKey, member.memberId, entry.id)
    cacheFs:write(path, ScriptCompiler.emit(entry, emitOpts))
    readbackResource(cacheFs, plan, entry)
  end
  cacheFs:writeLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId), member.coverage)
  validateCoverage(
    plan,
    member.memberId,
    assert(cacheFs:loadLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId)))
  )
  cacheFs:write(ScriptCache.memberMarkerPath(plan.generationKey, member.memberId), member.marker)
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

function ScriptCacheWriter.finalizeGeneration(cacheFs, plan)
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

  local orderedMembers = {}
  for _, member in ipairs(plan.members) do
    orderedMembers[#orderedMembers + 1] = member
  end
  table.sort(orderedMembers, function(a, b)
    return a.memberId < b.memberId
  end)
  local records = {}
  for _, member in ipairs(orderedMembers) do
    assert(cacheFs:read(ScriptCache.memberMarkerPath(plan.generationKey, member.memberId)) == member.marker)
    local coverage = assert(cacheFs:loadLua(ScriptCache.memberCoveragePath(plan.generationKey, member.memberId)))
    validateCoverage(plan, member.memberId, coverage)
    records[#records + 1] = coverage
    for _, entry in ipairs(memberResourceIndex(plan, member.memberId)) do
      readbackResource(cacheFs, plan, entry)
    end
  end
  local coverage = aggregateCoverage(records, plan)
  cacheFs:writeLua(ScriptCache.generationIndexPath(plan.generationKey), expectedIndex)
  cacheFs:writeLua(ScriptCache.generationProvenancePath(plan.generationKey), {
    schema = ScriptCache.PROVENANCE_SCHEMA,
    generation = plan.generationKey,
    marker = plan.marker,
    dependencies = plan.dependencies,
  })
  cacheFs:write(ScriptCache.generationCoverageJsonPath(plan.generationKey), jsonValue(coverage) .. "\n")
  cacheFs:write(ScriptCache.generationCoverageMdPath(plan.generationKey), Coverage.markdown(coverage))
  cacheFs:write(ScriptCache.generationMarkerPath(plan.generationKey), plan.marker)
  return true
end

function ScriptCacheWriter.activateGeneration(cacheFs, generationKey)
  local index = assert(cacheFs:loadLua(ScriptCache.generationIndexPath(generationKey)))
  local marker = assert(cacheFs:read(ScriptCache.generationMarkerPath(generationKey)))
  assert(index.schema == ScriptCache.INDEX_SCHEMA and index.generation == generationKey and index.marker == marker)
  local tx = ArtifactPublisher.begin(cacheFs, "scripts", { ScriptCache.activeDir() })
  local stage = tx.stage
  local activeIndex = {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = generationKey,
    marker = marker,
  }
  stage:writeLua(ScriptCache.activeIndexPath(), activeIndex)
  local provenance = cacheFs:loadLua(ScriptCache.generationProvenancePath(generationKey))
  assert(provenance ~= nil)
  stage:writeLua(ScriptCache.provenancePath(), provenance)
  stage:write(
    ScriptCache.coverageJsonPath(),
    assert(cacheFs:read(ScriptCache.generationCoverageJsonPath(generationKey)))
  )
  stage:write(ScriptCache.coverageMdPath(), assert(cacheFs:read(ScriptCache.generationCoverageMdPath(generationKey))))
  stage:write(ScriptCache.markerPath(), marker)
  tx:publish()
  return true
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

function ScriptCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.index and bundle.resources, "write requires a script bundle")
  assert(bundle.index.schema == ScriptCache.INDEX_SCHEMA, "bundle index schema mismatch")
  if ScriptCache.isReady(cacheFs, bundle.marker) then
    return true
  end
  local members = {}
  for _, entry in ipairs(bundle.resources) do
    local target = members[entry.member]
    if target == nil then
      target = {
        memberId = entry.member,
        resources = {},
        coverage = assert(
          bundle.memberCoverage and bundle.memberCoverage[entry.member],
          "script bundle member coverage is required"
        ),
      }
      members[entry.member] = target
    end
    target.resources[#target.resources + 1] = entry
  end
  local orderedMembers = {}
  for memberId, member in pairs(members) do
    member.marker = bundle.marker .. ":member:" .. tostring(memberId)
    orderedMembers[#orderedMembers + 1] = member
  end
  table.sort(orderedMembers, function(a, b)
    return a.memberId < b.memberId
  end)
  local generationKey = assert(bundle.index.generation, "script bundle generation is required")
  assert(bundle.index.marker == bundle.marker, "script bundle marker does not match its index")
  local plan = {
    generationKey = generationKey,
    marker = bundle.marker,
    version = bundle.index.version,
    sourcePath = "romfs/" .. bundle.dependencies.scrSeqNarc.path,
    romSha1 = bundle.dependencies.versionRomSha1,
    dependencies = bundle.dependencies,
    memberCount = bundle.index.memberCount,
    members = orderedMembers,
    resources = bundle.index.resources,
    index = bundle.index,
  }
  plan.index.generation = generationKey
  plan.index.marker = bundle.marker
  for _, member in ipairs(orderedMembers) do
    ScriptCacheWriter.stageMember(cacheFs, plan, member)
  end
  ScriptCacheWriter.finalizeGeneration(cacheFs, plan)
  ScriptCacheWriter.activateGeneration(cacheFs, generationKey)
  return true
end

return ScriptCacheWriter
