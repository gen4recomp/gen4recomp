-- Script generation publication contract: a failed member leaves the last
-- active generation complete and usable while the failed generation remains
-- inert.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

local function resource(id, generation)
  return {
    api = 1,
    id = id,
    metadata = {
      generated = true,
      generation = generation,
      source = { sourceHash = generation },
      coverage = { complete = true, unsupportedCount = 0 },
    },
    steps = { { op = "stop" } },
  }
end

local function member(memberId, id, generation)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    sourceHash = generation,
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
        sourceHash = generation,
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

local function writeGeneration(cache, generation, marker)
  local currentPlan = plan(generation, marker)
  Assert.isTrue(ScriptCacheWriter.stageMember(cache, currentPlan, member(0, "stable.script", generation)))
  Assert.isTrue(ScriptCacheWriter.stageMember(cache, currentPlan, member(1, "second.script", generation)))
  Assert.isTrue(ScriptCacheWriter.finalizeGeneration(cache, currentPlan))
  Assert.isTrue(ScriptCacheWriter.activateGeneration(cache, generation))
end

function T.failed_member_keeps_the_previous_active_generation_ready()
  Assert.isTrue(
    type(ScriptCacheWriter.stageMember) == "function",
    "generation publication must expose a member staging boundary"
  )
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeGeneration(cache, GENERATION_A, "marker-a")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the initial generation must be ready")

  local nextPlan = plan(GENERATION_B, "marker-b")
  Assert.isTrue(ScriptCacheWriter.stageMember(cache, nextPlan, member(0, "stable.script", GENERATION_B)))

  local failed = member(1, "second.script", GENERATION_B)
  failed.resources[1].resource.id = "wrong.script"
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(cache, nextPlan, failed)
  end, "a malformed member must fail before generation finalization")
  Assert.notNil(failure)

  Assert.throws(function()
    ScriptCacheWriter.finalizeGeneration(cache, nextPlan)
  end, "an incomplete generation must not finalize")
  Assert.equal(cache:read(ScriptCache.markerPath()), "marker-a", "member failure must not replace active selection")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the previous generation remains complete and readable")
  Assert.isFalse(ScriptCache.isReady(cache, "marker-b"), "the failed generation is never active-ready")
end

function T.same_generation_member_failure_cannot_mutate_the_active_generation()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeGeneration(cache, GENERATION_A, "marker-a")
  local original = assert(cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")))
  local rebuild = plan(GENERATION_A, "marker-a")
  rebuild.resources[1].id = "replacement.script"
  rebuild.index.resources[1].id = "replacement.script"
  local replacement = member(0, "replacement.script", GENERATION_A)
  backend.write = function()
    error("injected same-generation member failure")
  end

  Assert.throws(function()
    ScriptCacheWriter.stageMember(cache, rebuild, replacement)
  end, "a member build must reject the active generation before mutation")
  Assert.equal(
    cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")),
    original,
    "a failed same-generation build must preserve the active resource"
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

  Assert.throws(function()
    ScriptCacheWriter.stageMember(cache, currentPlan, member(0, "stable.script", GENERATION_A))
  end, "a member must not complete when an emitted resource fails readback")
  Assert.isNil(cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
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

  Assert.throws(function()
    ScriptCacheWriter.stageMember(cache, currentPlan, member(0, "stable.script", GENERATION_A))
  end, "a member must not complete when its serialized source identity is wrong")
  Assert.isNil(cache:read(ScriptCache.memberMarkerPath(GENERATION_A, 0)))
end

function T.matching_complete_member_is_reused_without_rewriting()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local currentPlan = plan(GENERATION_A, "marker-a")
  local completed = member(0, "stable.script", GENERATION_A)
  ScriptCacheWriter.stageMember(cache, currentPlan, completed)

  local originalWrite = backend.write
  backend.write = function(_, path)
    error("matching complete member was rewritten: " .. path)
  end
  Assert.isTrue(ScriptCacheWriter.stageMember(cache, currentPlan, completed))
  backend.write = originalWrite
end

function T.finalization_attests_member_coverage_and_plan_identity()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  ScriptCacheWriter.stageMember(cache, currentPlan, member(0, "stable.script", GENERATION_A))
  ScriptCacheWriter.stageMember(cache, currentPlan, member(1, "second.script", GENERATION_A))

  local coverage = assert(cache:loadLua(ScriptCache.memberCoveragePath(GENERATION_A, 0)))
  coverage = coverage --[[@as { scripts: { [1]: { publicId: string } } }]]
  coverage.scripts[1].publicId = "wrong.script"
  cache:writeLua(ScriptCache.memberCoveragePath(GENERATION_A, 0), coverage)
  Assert.throws(function()
    ScriptCacheWriter.finalizeGeneration(cache, currentPlan)
  end, "finalization must attest member coverage against the plan")

  coverage.scripts[1].publicId = "stable.script"
  cache:writeLua(ScriptCache.memberCoveragePath(GENERATION_A, 0), coverage)
  currentPlan.index.resources[1].id = "wrong.script"
  Assert.throws(function()
    ScriptCacheWriter.finalizeGeneration(cache, currentPlan)
  end, "finalization must attest the complete plan identity")
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
