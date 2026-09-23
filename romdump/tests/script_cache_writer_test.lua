-- Script cache writer tests: member staging through worker-owned
-- preparations, single-transaction summary publication, and rollback on
-- readback or publish failure.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local Sha256 = require("libs.script.src.Sha256")

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

-- Acceptance fixtures for the script-audio dependency contract: members
-- built from explicit structured steps so publication must derive the
-- dependency record from the resource bodies it already holds.
local function resourceWithSteps(memberId, id, scriptIndex, steps)
  local entry = memberResource(memberId, id, scriptIndex)
  entry.resource.steps = steps
  return entry
end

local function stagedWithSteps(memberId, id, scriptIndex, steps, generation)
  local staged = member(memberId, id, scriptIndex, generation)
  staged.resources = { resourceWithSteps(memberId, id, scriptIndex, steps) }
  return staged
end

local function sidecarRecord(cache, generation, memberId, id)
  local sidecar = assert(cache:loadLua(ScriptCache.memberHashesPath(generation, memberId)))
  for _, entry in ipairs(sidecar.resources) do
    if entry.id == id then
      return entry
    end
  end
  error("sidecar has no record for " .. id, 0)
end

local function cycleCoverage(memberId, specs)
  local scripts = {}
  for _, spec in ipairs(specs) do
    scripts[#scripts + 1] = {
      sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, spec.scriptIndex),
      publicId = spec.id,
      status = "complete",
      unsupported = {},
    }
  end
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = #specs,
      reachableInstructions = #specs,
      supportedInstructions = #specs,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = scripts,
  }
end

local function cycleMember(memberId, specs, generation)
  local staged = {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    sourceHash = SOURCE_HASH,
    coverage = cycleCoverage(memberId, specs),
    resources = {},
  }
  for _, spec in ipairs(specs) do
    staged.resources[#staged.resources + 1] = resourceWithSteps(memberId, spec.id, spec.scriptIndex, spec.steps)
  end
  return staged
end

local function cyclePlan(generation, marker)
  local resources = {
    { id = "alpha.first", member = 0, scriptIndex = 0 },
    { id = "alpha.second", member = 0, scriptIndex = 1 },
    { id = "beta.third", member = 1, scriptIndex = 0 },
  }
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
        members = 2,
        scripts = 3,
        reachableInstructions = 3,
        supportedInstructions = 3,
        unsupportedInstructions = 0,
        malformedInstructions = 0,
      },
      opcodes = {},
      scripts = {},
    },
    memberCount = 2,
    members = {
      { memberId = 0, marker = generation .. ":member:0" },
      { memberId = 1, marker = generation .. ":member:1" },
    },
    resources = resources,
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = 2,
    scriptMemberCount = 2,
    skippedMemberCount = 0,
    scriptCount = 3,
    resourceCount = 3,
    resources = resources,
  }
  return result
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

-- 6. Member readiness proves the live member under its planned marker: a
-- published member reads ready, while a missing body, an unknown member, a
-- foreign generation marker, or corrupt coverage does not.
T["member readiness proves the live member body"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "member-ready", "outer-a")
  Assert.isTrue(ScriptCacheWriter.isMemberReady(cache, currentPlan, 3))
  Assert.isTrue(ScriptCacheWriter.isMemberReady(cache, currentPlan, "843"))
  cache:remove(ScriptCache.scriptPath(GENERATION_A, 843, "new_bark.lab_sign"))
  local damaged, damagedReason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 843)
  Assert.isFalse(damaged, "a member with a missing script body is not ready")
  Assert.isTrue(type(damagedReason) == "string" and damagedReason ~= "", "the refusal names its cause")
  local unknown, unknownReason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 999)
  Assert.isFalse(unknown, "an unplanned member is not ready")
  Assert.isTrue(type(unknownReason) == "string" and unknownReason ~= "", "the refusal names its cause")
  local foreignPlan = plan(GENERATION_B, "script-cache-v5:rom-sha:other-dep-sha")
  Assert.isFalse(
    ScriptCacheWriter.isMemberReady(cache, foreignPlan, 3),
    "a foreign generation marker is not ready in this cache"
  )
  cache:write(ScriptCache.memberCoveragePath(GENERATION_A, 3), "not a lua coverage{{{")
  Assert.isFalse(ScriptCacheWriter.isMemberReady(cache, currentPlan, 3), "a member with corrupt coverage is not ready")
end

-- A member whose published resource hashes are absent cannot attest its
-- content: readiness must refuse it even though every body decodes. The
-- sidecar removal below reconstructs the incompatible older artifact the
-- scenario specifies (a plain publish always attests its hashes).
T["a member without published resource hashes is not ready"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "hashless", "outer-a")
  cache:remove(ScriptCache.memberDir(GENERATION_A, 3) .. "/resource-hashes.lua")
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 3)
  Assert.isFalse(ready, "a member without published resource hashes is not ready")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the refusal names its cause")
end

-- A hash record staged for another generation must not attest this member.
T["a member hash record from another generation is not ready"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "foreign-hash", "outer-a")
  cache:writeLua(ScriptCache.memberDir(GENERATION_A, 3) .. "/resource-hashes.lua", {
    schema = ScriptCache.HASHES_SCHEMA,
    generation = GENERATION_B,
    memberId = 3,
    marker = "other-marker",
    resources = {},
  })
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 3)
  Assert.isFalse(ready, "a foreign generation hash record must not attest this member")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the refusal names its cause")
end

-- A summary over index entries without published hashes is refused before
-- publication, and the previous live member survives the refusal.
T["a summary over hashless index entries is refused and keeps the previous member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "refused-summary", "outer-a")
  local currentPlan = plan(GENERATION_A, marker)
  cache:remove(ScriptCache.memberDir(GENERATION_A, 3) .. "/resource-hashes.lua")
  local beforeMarker = cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 3))
  local beforeBody = cache:read(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost"))
  local err = Assert.throws(function()
    ScriptCacheWriter.writeSummary(cache, currentPlan)
  end)
  Assert.notNil(err, "a hashless summary must be refused")
  Assert.equal(
    cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 3)),
    beforeMarker,
    "the previous member marker survives a refused summary"
  )
  Assert.equal(
    cache:read(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost")),
    beforeBody,
    "the previous member body survives a refused summary"
  )
end

-- A body that no longer matches its published hash is not ready: the
-- sidecar is validated against the current emitted bodies, never trusted.
T["a member whose body drifted from its published hash is not ready"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "drifted", "outer-a")
  local path = ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost")
  local body = assert(cache:read(path))
  local drifted, replacements = body:gsub("complete = true", "complete = false", 1)
  Assert.equal(replacements, 1, "the drift edits emitted coverage metadata")
  cache:write(path, drifted)
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 3)
  Assert.isFalse(ready, "a drifted body must not match its published hash")
  Assert.isTrue(
    type(reason) == "string" and reason:find("hash", 1, true) ~= nil,
    "the refusal names the hash mismatch: " .. tostring(reason)
  )
end

-- A sidecar carrying another marker cannot attest this member, even when
-- its hashes are well-formed.
T["a member hash record with the wrong marker is not ready"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "wrong-marker", "outer-a")
  local resource = assert(cache:loadModule(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost")))
  cache:writeLua(ScriptCache.memberDir(GENERATION_A, 3) .. "/resource-hashes.lua", {
    schema = ScriptCache.HASHES_SCHEMA,
    generation = GENERATION_A,
    memberId = 3,
    marker = "stale-marker",
    resources = {
      {
        id = "common.signpost",
        scriptIndex = 0,
        resourceHash = Sha256.hex(LuaWriter.encode(resource)),
        audioSequences = {},
        scriptTargets = {},
      },
    },
  })
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 3)
  Assert.isFalse(ready, "a stale marker must not attest this member")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the refusal names its cause")
end

-- A hand-published sidecar with valid hashes attests its member: readiness
-- validates the sidecar against the plan and the current bodies, not its
-- provenance, and record order never matters to the bijection.
T["a hand-published hash record attests its member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "unordered", "outer-a")
  local resource = assert(cache:loadModule(ScriptCache.scriptPath(GENERATION_A, 843, "new_bark.lab_sign")))
  cache:writeLua(ScriptCache.memberDir(GENERATION_A, 843) .. "/resource-hashes.lua", {
    schema = ScriptCache.HASHES_SCHEMA,
    generation = GENERATION_A,
    memberId = 843,
    marker = GENERATION_A .. ":member:843",
    resources = {
      {
        id = "new_bark.lab_sign",
        scriptIndex = 9,
        resourceHash = Sha256.hex(LuaWriter.encode(resource)),
        audioSequences = {},
        scriptTargets = {},
      },
    },
  })
  Assert.isTrue(ScriptCacheWriter.isMemberReady(cache, currentPlan, 843))
end

-- Direct script-audio dependencies are derived from the final structured
-- steps at member publication: nested operations across if/switch branches
-- publish canonical symbols (numeric spellings normalize through the
-- pinned sound catalog), while local call labels never become
-- cross-script targets.
T["member sidecar carries direct script audio and cross-script targets"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local steps = {
    { op = "play_music", music = "SEQ_GS_NAMINORI" },
    { op = "play_sound", sound = 1014 },
    { op = "label", name = "loop" },
    { op = "call", target = "loop" },
    { op = "goto", target = "loop" },
    {
      op = "if",
      condition = { condition = "flag", id = 1 },
      yes = { { op = "play_fanfare", fanfare = "SEQ_ME_HYOUKA1" } },
      no = { { op = "stop_sound", sound = "SEQ_SE_GS_N_SESERAGI" } },
    },
    {
      op = "switch",
      value = 1,
      cases = {
        [1] = { { op = "wait_sound", sound = "SEQ_SE_GS_N_SESERAGI" } },
        [2] = { { op = "call_common", target = "common.other" } },
      },
      default = { { op = "temporary_music", music = "SEQ_GS_TITLE" } },
    },
    { op = "goto_script", script = "common.other" },
    { op = "call", target = "common.other" },
    { op = "goto_compared", operator = "eq", script = "common.third" },
    { op = "call_compared", operator = "eq", script = "common.third" },
    { op = "stop" },
  }
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(3, "common.signpost", 0, steps, GENERATION_A),
    "deps-member-3",
    "outer-a"
  )
  local record = sidecarRecord(cache, GENERATION_A, 3, "common.signpost")
  Assert.deepEqual(
    record.audioSequences,
    { "SEQ_GS_NAMINORI", "SEQ_GS_TITLE", "SEQ_ME_HYOUKA1", "SEQ_SE_GS_N_SESERAGI" },
    "direct audio is the sorted unique canonical symbol set"
  )
  Assert.deepEqual(
    record.scriptTargets,
    { "common.other", "common.third" },
    "cross-script targets exclude local labels"
  )
end

-- A variable fanfare cannot name its sequence, so publication records the
-- pinned retail dex-evaluation pair instead of an empty dependency.
T["variable fanfare publishes the pinned dex-evaluation pair"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local steps = {
    { op = "play_fanfare", fanfare = { value = "var", id = "x8000" } },
    { op = "stop" },
  }
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(3, "common.signpost", 0, steps, GENERATION_A),
    "fanfare-member-3",
    "outer-a"
  )
  local record = sidecarRecord(cache, GENERATION_A, 3, "common.signpost")
  Assert.deepEqual(
    record.audioSequences,
    { "SEQ_ME_HYOUKA1", "SEQ_ME_HYOUKA6" },
    "variable fanfare expands to exactly the source-grounded pair"
  )
  Assert.deepEqual(record.scriptTargets, {}, "fanfare alone reaches no other script")
end

-- Transitive audio is a fixed point over the member graph: a cycle plus an
-- outgoing audio-bearing target converges to the complete closure for
-- every member with sorted unique sequences.
T["cyclic script graphs converge to the same transitive closure"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = cyclePlan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    cycleMember(0, {
      {
        id = "alpha.first",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_TITLE" },
          { op = "call", target = "alpha.second" },
          { op = "stop" },
        },
      },
      {
        id = "alpha.second",
        scriptIndex = 1,
        steps = {
          { op = "call_common", target = "beta.third" },
          { op = "stop" },
        },
      },
    }, GENERATION_A),
    "cycle-member-0",
    "outer-a"
  )
  publishMember(
    cache,
    currentPlan,
    cycleMember(1, {
      {
        id = "beta.third",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_NAMINORI" },
          { op = "call", target = "alpha.second" },
          { op = "stop" },
        },
      },
    }, GENERATION_A),
    "cycle-member-1",
    "outer-a"
  )
  publishSummary(cache, currentPlan, "cycle-summary", "outer-a")
  local index = assert(cache:loadLua(ScriptCache.generationIndexPath(GENERATION_A)))
  Assert.deepEqual(
    index.memberAudioSequences,
    { ["0"] = { "SEQ_GS_NAMINORI", "SEQ_GS_TITLE" }, ["1"] = { "SEQ_GS_NAMINORI" } },
    "transitive closure converges through the cycle with sorted unique sequences"
  )
end

-- A v2 sidecar with unsorted dependency arrays cannot attest its member:
-- persistence order is part of the contract, not cosmetic.
T["a member sidecar with unsorted dependencies is not ready"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "unsorted", "outer-a")
  local resource = assert(cache:loadModule(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost")))
  cache:writeLua(ScriptCache.memberDir(GENERATION_A, 3) .. "/resource-hashes.lua", {
    schema = ScriptCache.HASHES_SCHEMA,
    generation = GENERATION_A,
    memberId = 3,
    marker = GENERATION_A .. ":member:3",
    resources = {
      {
        id = "common.signpost",
        scriptIndex = 0,
        resourceHash = Sha256.hex(LuaWriter.encode(resource)),
        audioSequences = { "SEQ_GS_TITLE", "SEQ_GS_NAMINORI" },
        scriptTargets = {},
      },
    },
  })
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 3)
  Assert.isFalse(ready, "an unsorted dependency array must not attest its member")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the refusal names its cause")
end

-- An unknown numeric sequence reference fails staging instead of
-- serializing a bare number: sequence identity must always be canonical.
T["an unknown numeric sequence reference fails member staging"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local staged = stagedWithSteps(3, "common.signpost", 0, {
    { op = "play_sound", sound = 999999 },
    { op = "stop" },
  }, GENERATION_A)
  local artifact = preparation(cache, "3", "unknown-numeric", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, staged)
  end, "an unknown numeric sequence must fail staging")
  artifact:abort()
end

-- A dynamic sound operand has no source-grounded expansion, so staging
-- fails instead of publishing an empty dependency.
T["a dynamic sound operand fails member staging"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local staged = stagedWithSteps(3, "common.signpost", 0, {
    { op = "play_sound", sound = { value = "var", id = "x8000" } },
    { op = "stop" },
  }, GENERATION_A)
  local artifact = preparation(cache, "3", "dynamic-sound", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, staged)
  end, "a dynamic sound operand must fail staging")
  artifact:abort()
end

-- Music operands are constants in the current corpus; a dynamic music
-- value fails staging rather than weakening the dependency record.
T["a dynamic music operand fails member staging"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local staged = stagedWithSteps(3, "common.signpost", 0, {
    { op = "play_music", music = { value = "var", id = "x4000" } },
    { op = "stop" },
  }, GENERATION_A)
  local artifact = preparation(cache, "3", "dynamic-music", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, staged)
  end, "a dynamic music operand must fail staging")
  artifact:abort()
end

-- A resource with no audio operations or cross-script calls publishes
-- explicit empty dependency arrays, never missing fields.
T["a silent resource publishes explicit empty dependencies"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A),
    "silent-member-3",
    "outer-a"
  )
  local record = sidecarRecord(cache, GENERATION_A, 3, "common.signpost")
  Assert.deepEqual(record.audioSequences, {}, "silence carries an explicit empty audio set")
  Assert.deepEqual(record.scriptTargets, {}, "silence reaches no other script")
end

-- A declared cross-script target that resolves to no planned resource
-- fails the summary before any selector is replaced.
T["a summary over an unknown script target is refused"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  publishMember(cache, currentPlan, member(3, "common.signpost", 0, GENERATION_A), "known-member-3", "outer-a")
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(843, "new_bark.lab_sign", 9, {
      { op = "call_common", target = "nope.missing" },
      { op = "stop" },
    }, GENERATION_A),
    "dangling-member-843",
    "outer-a"
  )
  local summary = preparation(cache, "global", "dangling-summary", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, currentPlan)
  end, "an unknown script target must refuse the summary")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()
end

-- A resource that targets itself converges: its own audio appears exactly
-- once in its member closure.
T["a self-targeting resource converges to its own audio"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v5:rom-sha:dep-sha"
  local currentPlan = cyclePlan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    cycleMember(0, {
      {
        id = "alpha.first",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_TITLE" },
          { op = "call", target = "alpha.first" },
          { op = "stop" },
        },
      },
      {
        id = "alpha.second",
        scriptIndex = 1,
        steps = { { op = "stop" } },
      },
    }, GENERATION_A),
    "self-member-0",
    "outer-a"
  )
  publishMember(
    cache,
    currentPlan,
    cycleMember(1, {
      {
        id = "beta.third",
        scriptIndex = 0,
        steps = { { op = "stop" } },
      },
    }, GENERATION_A),
    "self-member-1",
    "outer-a"
  )
  publishSummary(cache, currentPlan, "self-summary", "outer-a")
  local index = assert(cache:loadLua(ScriptCache.generationIndexPath(GENERATION_A)))
  Assert.deepEqual(
    index.memberAudioSequences,
    { ["0"] = { "SEQ_GS_TITLE" }, ["1"] = {} },
    "a self-cycle converges without duplication"
  )
end

return { tests = T }
