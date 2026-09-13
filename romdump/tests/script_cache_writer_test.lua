-- Script cache writer tests: member staging through worker-owned
-- preparations, single-transaction summary publication, and rollback on
-- readback or publish failure.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)
local SOURCE_HASH = string.rep("c", 40)

local function memberCoverage(memberId, id, scriptIndex)
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = 1,
      reachableInstructions = 1,
      supportedInstructions = 1,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = {
      {
        sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, scriptIndex or 0),
        publicId = id,
        status = "complete",
        unsupported = {},
      },
    },
  }
end

local function memberResource(memberId, id, scriptIndex)
  return {
    id = id,
    member = memberId,
    scriptIndex = scriptIndex,
    sourceHash = SOURCE_HASH,
    resource = {
      api = 1,
      id = id,
      metadata = {
        generated = true,
        source = { sourceHash = SOURCE_HASH },
        coverage = { complete = true, unsupportedCount = 0 },
      },
      steps = { { op = "stop" } },
    },
    report = { complete = true, unsupportedCount = 0 },
  }
end

local function member(memberId, id, scriptIndex, generation)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    sourceHash = SOURCE_HASH,
    coverage = memberCoverage(memberId, id, scriptIndex),
    resources = { memberResource(memberId, id, scriptIndex) },
  }
end

local function plan(generation, marker)
  local result = {
    generationKey = generation,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/a/0/1/2",
    romSha1 = "rom-sha",
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    coverageRecord = {
      source = { repository = "portemon", romSha1 = "rom-sha" },
      totals = {
        members = 1,
        scripts = 2,
        reachableInstructions = 2,
        supportedInstructions = 2,
        unsupportedInstructions = 0,
        malformedInstructions = 0,
      },
      opcodes = {},
      scripts = {},
    },
    memberCount = 2,
    members = {
      { memberId = 3, marker = generation .. ":member:3" },
      { memberId = 843, marker = generation .. ":member:843" },
    },
    resources = {
      { id = "common.signpost", member = 3, scriptIndex = 0 },
      { id = "new_bark.lab_sign", member = 843, scriptIndex = 9 },
    },
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = 2,
    scriptMemberCount = 2,
    skippedMemberCount = 0,
    scriptCount = 2,
    resourceCount = 2,
    resources = result.resources,
  }
  return result
end

local function preparation(cache, key, stageName, outerGeneration, epoch)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = key,
    jobKey = "script-member:" .. key,
    stageName = stageName,
  })
end

local function publishMember(cache, currentPlan, staged, stageName, outerGeneration)
  local artifact = preparation(cache, tostring(staged.memberId), stageName, outerGeneration)
  local marker = assert(ScriptCacheWriter.stageMember(artifact, currentPlan, staged))
  Assert.equal(marker, staged.marker)
  artifact:finishSuccess({ marker = staged.marker })
  Assert.isTrue(artifact:publish({
    generationId = outerGeneration,
    epoch = 1,
    kind = "script-member",
    key = tostring(staged.memberId),
    jobKey = "script-member:" .. tostring(staged.memberId),
  }))
end

local function publishSummary(cache, currentPlan, stageName, outerGeneration)
  local artifact = preparation(cache, "global", stageName, outerGeneration)
  local marker = assert(ScriptCacheWriter.stageSummary(artifact, currentPlan))
  Assert.equal(marker, currentPlan.marker)
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.isTrue(artifact:publish({
    generationId = outerGeneration,
    epoch = 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
  }))
end

local function publishGeneration(cache, generation, marker, prefix, outerGeneration)
  local currentPlan = plan(generation, marker)
  publishMember(cache, currentPlan, member(3, "common.signpost", 0, generation), prefix .. "-member-3", outerGeneration)
  publishMember(
    cache,
    currentPlan,
    member(843, "new_bark.lab_sign", 9, generation),
    prefix .. "-member-843",
    outerGeneration
  )
  publishSummary(cache, currentPlan, prefix .. "-summary", outerGeneration)
  return currentPlan
end

-- 1. Members stage through preparations and the summary publishes
-- provenance, index, coverage, and the active selector at once; isReady then
-- reports the class complete.
T["member and summary publication completes the class"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "complete", "outer-a")
  Assert.notNil(cache:read(ScriptCache.provenancePath()))
  Assert.notNil(cache:read(ScriptCache.coverageJsonPath()))
  local index = cache:loadLua(ScriptCache.generationIndexPath(GENERATION_A))
  index = index --[[@as { schema: string, resourceCount: integer, resources: table[] }]]
  Assert.equal(index.schema, ScriptCache.INDEX_SCHEMA)
  Assert.equal(index.resourceCount, 2)
  local signpost = cache:loadModule(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost"))
  signpost = signpost --[[@as { kind: string, id: string }]]
  Assert.equal(signpost.kind, "field_script")
  Assert.equal(signpost.id, "common.signpost")
  Assert.equal(cache:read(ScriptCache.markerPath()), marker)
  local coverage = assert(cache:read(ScriptCache.generationCoverageMdPath(GENERATION_A)))
  Assert.isTrue(coverage:find("| Members | 2 |", 1, true) ~= nil)
  Assert.isTrue(coverage:find("| Scripts | 2 |", 1, true) ~= nil)
  Assert.isTrue(ScriptCache.isReady(cache, marker))
  Assert.equal(currentPlan.marker, marker)
end

-- 2. A missing script file fails readiness.
T["readiness requires every indexed script"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "ready", "outer-a")
  cache:remove(ScriptCache.scriptPath(GENERATION_A, 843, "new_bark.lab_sign"))
  Assert.isFalse(ScriptCache.isReady(cache, marker))
end

-- 3. A readback failure fails the member stage before any marker lands and
-- publishes nothing.
T["readback failure stages no member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "script-cache-v5:rom-sha:dep-sha")
  local bad = member(3, "common.signpost", 0, GENERATION_A)
  bad.resources[1].resource = { api = 1, id = "other", steps = {} }
  local artifact = preparation(cache, "3", "bad-member", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, bad)
  end)
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 3)))
  Assert.isNil(cache:read(ScriptCache.markerPath()))
  Assert.isNil(cache:loadLua(ScriptCache.activeIndexPath()))
end

-- 4. A failed member rebuild leaves the previous ready artifact untouched,
-- the disposable stage is aborted, and a retry publishes the new artifact.
T["failed member rebuild preserves the previous script artifact"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local marker = "script-cache-v5:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "previous", "outer-a")
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("/scripts/", 1, true) then
      error("injected member write failure")
    end
    return original(self, path, data)
  end
  local nextPlan = plan(GENERATION_B, "script-cache-v5:rom-sha:new-dep-sha")
  local failed = preparation(cache, "3", "failed-member", "outer-b")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(failed, nextPlan, member(3, "common.signpost", 0, GENERATION_B))
  end)
  failed:abort()
  backend.write = original
  Assert.isTrue(ScriptCache.isReady(cache, marker), "the previous artifact remains ready")
  Assert.equal(cache:read(ScriptCache.markerPath()), marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/failed-member"), "the failed stage is discarded")
  publishMember(cache, nextPlan, member(3, "common.signpost", 0, GENERATION_B), "retry-member-3", "outer-b")
  publishMember(cache, nextPlan, member(843, "new_bark.lab_sign", 9, GENERATION_B), "retry-member-843", "outer-b")
  publishSummary(cache, nextPlan, "retry-summary", "outer-b")
  Assert.isTrue(ScriptCache.isReady(cache, "script-cache-v5:rom-sha:new-dep-sha"), "a retry publishes the new artifact")
end

-- 5. A publish failure after ownership begins must not delete recovery
-- material: the adjacent old root keeps the last-known-good selector for
-- journal recovery, and a retried direct summary then activates.
T["publish failure keeps recovery material for the journal"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local marker = "script-cache-v5:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "recovery-old", "outer-a")
  local nextPlan = plan(GENERATION_B, "script-cache-v5:rom-sha:new-dep-sha")
  publishMember(cache, nextPlan, member(3, "common.signpost", 0, GENERATION_B), "recovery-member-3", "outer-b")
  publishMember(cache, nextPlan, member(843, "new_bark.lab_sign", 9, GENERATION_B), "recovery-member-843", "outer-b")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local nextPrefix = "heartgold/" .. ScriptCache.activeDir() .. ".__g4next."
    local oldPrefix = "heartgold/" .. ScriptCache.activeDir() .. ".__g4old."
    if sourcePath:sub(1, #nextPrefix) == nextPrefix or sourcePath:sub(1, #oldPrefix) == oldPrefix then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    ScriptCacheWriter.writeSummary(cache, nextPlan)
  end)
  err = err --[[@as { code: string }]]
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  backend.replace = originalReplace
  local oldPrefix = "heartgold/" .. ScriptCache.activeDir() .. ".__g4old."
  local oldMarker
  for path, data in pairs(backend.files) do
    if path:sub(1, #oldPrefix) == oldPrefix and path:sub(-#"/complete") == "/complete" then
      oldMarker = data
    end
  end
  Assert.equal(oldMarker, marker, "the last-known-good selector stays as recovery material")
  cache:recoverPublication()
  Assert.isTrue(ScriptCache.isReady(cache, marker), "journal recovery restores the previous artifact")
  Assert.isTrue(ScriptCacheWriter.writeSummary(cache, nextPlan))
  Assert.isTrue(
    ScriptCache.isReady(cache, "script-cache-v5:rom-sha:new-dep-sha"),
    "a retried summary activates the new artifact"
  )
end

return { tests = T }
