-- ROM-backed script generation contract: member completion order must not
-- change the complete immutable generation published to the cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function requireMemberSession()
  local ok, session = pcall(require, "romdump.src.digest.script.ScriptCompileSession")
  Assert.isTrue(ok, "member compilation must expose a production compile session")
  return assert(session)
end

local function memberIds(plan)
  local ids = {}
  for _, member in ipairs(assert(plan.members)) do
    ids[#ids + 1] = assert(member.memberId)
  end
  return ids
end

local function buildGeneration(romFs, plan, order, cache)
  local Session = requireMemberSession()
  local session = assert(Session.new(romFs, plan))
  for _, memberId in ipairs(order) do
    local member = assert(session:compileMember(memberId))
    Assert.isTrue(
      ScriptCacheWriter.stageMember(cache, plan, member),
      "a completed member must publish only inside its inert generation"
    )
  end
  Assert.isTrue(ScriptCacheWriter.finalizeGeneration(cache, plan), "the complete generation must finalize")
  Assert.isTrue(
    ScriptCacheWriter.activateGeneration(cache, plan.generationKey),
    "the complete generation must activate"
  )
end

local function publishedGeneration(cache, plan)
  local active = assert(cache:loadLua(ScriptCache.activeIndexPath()))
  local generation = assert(active.generation)
  local generationIndex = assert(cache:loadLua(ScriptCache.generationIndexPath(generation)))
  local resources = {}
  for _, entry in ipairs(generationIndex.resources) do
    resources[entry.id] = assert(cache:read(ScriptCache.scriptPath(generation, entry.member, entry.id)))
  end
  return {
    active = active,
    marker = cache:read(ScriptCache.markerPath()),
    generationIndex = generationIndex,
    provenance = cache:read(ScriptCache.generationDir(generation) .. "/provenance.lua"),
    coverage = cache:read(ScriptCache.generationDir(generation) .. "/coverage.json"),
    coverageMarkdown = cache:read(ScriptCache.generationDir(generation) .. "/coverage.md"),
    resources = resources,
    planMarker = plan.marker,
  }
end

function T.member_completion_order_preserves_the_published_corpus(romFs, versionId)
  local plan = assert(
    ScriptCompiler.plan(romFs, "acceptance-test-producer-fingerprint"),
    "script planning must produce one immutable generation plan"
  )
  local ascending = memberIds(plan)
  local shuffled = {}
  for index = #ascending, 1, -1 do
    shuffled[#shuffled + 1] = ascending[index]
  end

  local firstCache = CacheFs.forVersion(versionId, FakeCache.new())
  local secondCache = CacheFs.forVersion(versionId, FakeCache.new())
  buildGeneration(romFs, plan, ascending, firstCache)
  buildGeneration(romFs, plan, shuffled, secondCache)

  Assert.deepEqual(
    publishedGeneration(firstCache, plan),
    publishedGeneration(secondCache, plan),
    "member completion order must not change generation marker, index, coverage, or resource bytes"
  )
end

local suite = RomSuite.fromFacts(T)
suite.metadata.slow = true
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "script", "corpus", "generation" }
return suite
