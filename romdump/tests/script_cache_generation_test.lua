-- Script generation publication contract: members stage through
-- worker-owned preparations, the summary activates only a complete
-- generation, and a failed member leaves the last active generation complete
-- and usable while the failed generation remains inert.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)
local SOURCE_HASH = string.rep("c", 40)

local function resource(id, generation)
  return {
    api = 1,
    id = id,
    metadata = {
      generated = true,
      generation = generation,
      source = { sourceHash = SOURCE_HASH },
      coverage = { complete = true, unsupportedCount = 0 },
    },
    steps = { { op = "stop" } },
  }
end

local function member(memberId, id, generation)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    sourceHash = SOURCE_HASH,
    coverage = {
      source = { repository = "g4recomp", romSha1 = generation },
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
          sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, 0),
          publicId = id,
          status = "complete",
          unsupported = {},
        },
      },
    },
    resources = {
      {
        id = id,
        member = memberId,
        scriptIndex = 0,
        sourceHash = SOURCE_HASH,
        resource = resource(id, generation),
        report = { complete = true, unsupportedCount = 0 },
      },
    },
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
    memberCount = 2,
    members = {
      { memberId = 0, marker = generation .. ":member:0" },
      { memberId = 1, marker = generation .. ":member:1" },
    },
    resources = {
      { id = "stable.script", member = 0, scriptIndex = 0 },
      { id = "second.script", member = 1, scriptIndex = 0 },
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
  Assert.isTrue(ScriptCacheWriter.stageMember(artifact, currentPlan, staged))
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
  Assert.isTrue(ScriptCacheWriter.stageSummary(artifact, currentPlan) ~= nil)
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.isTrue(artifact:publish({
    generationId = outerGeneration,
    epoch = 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
  }))
end

local function writeGeneration(cache, generation, marker, prefix, outerGeneration)
  local currentPlan = plan(generation, marker)
  publishMember(cache, currentPlan, member(0, "stable.script", generation), prefix .. "-member-0", outerGeneration)
  publishMember(cache, currentPlan, member(1, "second.script", generation), prefix .. "-member-1", outerGeneration)
  publishSummary(cache, currentPlan, prefix .. "-summary", outerGeneration)
end

function T.failed_member_keeps_the_previous_active_generation_ready()
  Assert.isTrue(
    type(ScriptCacheWriter.stageMember) == "function",
    "generation publication must expose a member staging boundary"
  )
  Assert.isTrue(
    type(ScriptCacheWriter.stageSummary) == "function",
    "generation publication must expose a summary staging boundary"
  )
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the initial generation must be ready")

  local nextPlan = plan(GENERATION_B, "marker-b")
  publishMember(cache, nextPlan, member(0, "stable.script", GENERATION_B), "next-member-0", "outer-b")

  local failed = member(1, "second.script", GENERATION_B)
  failed.resources[1].resource.id = "wrong.script"
  local artifact = preparation(cache, "1", "next-member-1", "outer-b")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, nextPlan, failed)
  end, "a malformed member must fail before summary publication")
  failure = failure --[[@as { code: string }]]
  Assert.isTrue(Errors.is(failure))
  artifact:abort()

  local summary = preparation(cache, "global", "next-summary", "outer-b")
  local summaryFailure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, nextPlan)
  end, "an incomplete generation must not publish a summary")
  summaryFailure = summaryFailure --[[@as { code: string }]]
  Assert.equal(summaryFailure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()
  Assert.equal(cache:read(ScriptCache.markerPath()), "marker-a", "member failure must not replace active selection")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the previous generation remains complete and readable")
  Assert.isFalse(ScriptCache.isReady(cache, "marker-b"), "the failed generation is never active-ready")
end

function T.failed_repair_stage_leaves_the_live_member_untouched()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  local original = assert(cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")))
  local rebuild = member(0, "stable.script", GENERATION_A)
  local realWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("/scripts/", 1, true) then
      error("injected repair failure")
    end
    return realWrite(self, path, data)
  end
  local artifact = preparation(cache, "0", "repair-member", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, rebuild, plan(GENERATION_A, "marker-a"))
  end, "a failed repair stage must not complete")
  backend.write = realWrite
  artifact:abort()
  Assert.equal(
    cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")),
    original,
    "a failed repair stage must preserve the live resource"
  )
  Assert.equal(cache:read(ScriptCache.markerPath()), "marker-a", "the active marker must remain selected")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the last-known-good generation remains ready")
end

function T.member_completion_requires_resource_readback_before_marker()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local currentPlan = plan(GENERATION_A, "marker-a")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    local result = originalWrite(self, path, data)
    if path:find("/scripts/", 1, true) then
      self.files[path] = "not a generated script"
    end
    return result
  end

  local artifact = preparation(cache, "0", "tampered-member", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, member(0, "stable.script", GENERATION_A))
  end, "a member must not complete when an emitted resource fails readback")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_MEMBER_READBACK_FAILED")
  backend.write = originalWrite
  Assert.isNil(artifact:stageFs():read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
  artifact:abort()
end

function T.member_readback_requires_the_planned_source_identity()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local currentPlan = plan(GENERATION_A, "marker-a")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    local result = originalWrite(self, path, data)
    if path:find("/scripts/", 1, true) then
      self.files[path] = data:gsub("      member = 0,", "      member = 1,")
    end
    return result
  end

  local artifact = preparation(cache, "0", "mistaken-member", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, member(0, "stable.script", GENERATION_A))
  end, "a member must not complete when its serialized source identity is wrong")
  backend.write = originalWrite
  Assert.isNil(artifact:stageFs():read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
  artifact:abort()
end

function T.repaired_member_stages_into_the_private_stage_without_touching_live()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  local liveBefore = assert(cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")))

  local artifact = preparation(cache, "0", "repair-private", "outer-a")
  local staged = ScriptCacheWriter.stageMember(artifact, currentPlan, member(0, "stable.script", GENERATION_A))
  Assert.equal(staged, GENERATION_A .. ":member:0", "repair staging returns the exact member marker")
  Assert.equal(
    cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")),
    liveBefore,
    "repair staging must not rewrite the live member"
  )
  Assert.equal(
    artifact:stageFs():read(ScriptCache.memberMarkerPath(GENERATION_A, 0)),
    GENERATION_A .. ":member:0",
    "the repair lands in the private stage"
  )
  artifact:abort()
end

function T.summary_attests_member_coverage_and_plan_identity()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "coverage-member-0", "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "coverage-member-1", "outer-a")

  local coverage = assert(cache:loadLua(ScriptCache.memberCoveragePath(GENERATION_A, 0)))
  coverage = coverage --[[@as { scripts: { [1]: { publicId: string } } }]]
  coverage.scripts[1].publicId = "wrong.script"
  cache:writeLua(ScriptCache.memberCoveragePath(GENERATION_A, 0), coverage)
  local summary = preparation(cache, "global", "coverage-summary", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, currentPlan)
  end, "summary staging must attest member coverage against the plan")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()

  coverage.scripts[1].publicId = "stable.script"
  cache:writeLua(ScriptCache.memberCoveragePath(GENERATION_A, 0), coverage)
  currentPlan.index.resources[1].id = "wrong.script"
  local mismatch = preparation(cache, "global", "identity-summary", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageSummary(mismatch, currentPlan)
  end, "summary staging must attest the complete plan identity")
  mismatch:abort()
end

function T.member_with_no_resources_stages_without_a_fake_job()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  currentPlan.members[2].memberId = 7
  currentPlan.members[2].marker = GENERATION_A .. ":member:7"
  currentPlan.resources = { { id = "stable.script", member = 0, scriptIndex = 0 } }
  currentPlan.index.resources = currentPlan.resources
  currentPlan.index.scriptCount = 1
  currentPlan.index.resourceCount = 1
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "empty-member-0", "outer-a")

  local empty = {
    memberId = 7,
    marker = GENERATION_A .. ":member:7",
    sourceHash = SOURCE_HASH,
    coverage = {
      source = { repository = "g4recomp", romSha1 = GENERATION_A },
      totals = {
        members = 1,
        scripts = 0,
        reachableInstructions = 0,
        supportedInstructions = 0,
        unsupportedInstructions = 0,
        malformedInstructions = 0,
      },
      opcodes = {},
      scripts = {},
    },
    resources = {},
  }
  local artifact = preparation(cache, "7", "empty-member-7", "outer-a")
  Assert.equal(ScriptCacheWriter.stageMember(artifact, currentPlan, empty), GENERATION_A .. ":member:7")
  artifact:finishSuccess({ marker = GENERATION_A .. ":member:7" })
  Assert.isTrue(artifact:publish({
    generationId = "outer-a",
    epoch = 1,
    kind = "script-member",
    key = "7",
    jobKey = "script-member:7",
  }))
  publishSummary(cache, currentPlan, "empty-summary", "outer-a")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"))
end

function T.duplicate_resource_ids_fail_member_staging()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local duplicated = member(0, "stable.script", GENERATION_A)
  duplicated.resources[#duplicated.resources + 1] = duplicated.resources[1]
  local artifact = preparation(cache, "0", "duplicated-member", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, duplicated)
  end, "a member with duplicate resource ids must fail before any write")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_MEMBER_INVALID")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
end

function T.malformed_coverage_fails_member_staging()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local malformed = member(0, "stable.script", GENERATION_A)
  malformed.coverage.totals.scripts = 7
  local artifact = preparation(cache, "0", "malformed-member", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, malformed)
  end, "a member with malformed coverage must fail before any write")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_MEMBER_COVERAGE_INVALID")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
end

function T.stale_summary_publication_is_rejected()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "stale-member-0", "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "stale-member-1", "outer-a")

  local artifact = preparation(cache, "global", "stale-summary", "outer-a")
  Assert.isTrue(ScriptCacheWriter.stageSummary(artifact, currentPlan) ~= nil)
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.throws(function()
    artifact:publish({
      generationId = "stale-outer-generation",
      epoch = 1,
      kind = "script-member",
      key = "global",
      jobKey = "script-member:global",
    })
  end, "a stale generation must not publish a staged summary")
  Assert.throws(function()
    artifact:publish({
      generationId = "outer-a",
      epoch = 2,
      kind = "script-member",
      key = "global",
      jobKey = "script-member:global",
    })
  end, "a stale epoch must not publish a staged summary")
  Assert.isFalse(ScriptCache.isReady(cache, "marker-a"), "a staged summary is not live before publication")
  Assert.isTrue(artifact:publish({
    generationId = "outer-a",
    epoch = 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
  }))
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the current summary publication activates")
end

function T.cleanup_propagates_generation_listing_failure()
  local backend = FakeCache.new()
  backend.getDirectoryItems = function()
    return nil, "injected directory listing failure"
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function()
    ScriptCacheWriter.cleanupGenerations(cache, {})
  end, "cleanup must not treat a failed generation listing as an empty directory")
end

return { tests = T }
