-- ROM-backed script generation contract: member completion order must not
-- change the complete immutable generation published to the cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
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
    local artifact = PreparedArtifact.new({
      cacheFs = cache,
      generationId = "rom-outer-generation",
      epoch = 1,
      kind = "script-member",
      key = tostring(memberId),
      jobKey = "script-member:" .. tostring(memberId),
      stageName = "rom-member-" .. tostring(memberId),
    })
    Assert.isTrue(
      ScriptCacheWriter.stageMember(artifact, plan, member),
      "a completed member must stage only inside its own preparation"
    )
    artifact:finishSuccess({ marker = member.marker })
    Assert.isTrue(artifact:publish({
      generationId = "rom-outer-generation",
      epoch = 1,
      kind = "script-member",
      key = tostring(memberId),
      jobKey = "script-member:" .. tostring(memberId),
    }))
  end
  local summary = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "rom-outer-generation",
    epoch = 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
    stageName = "rom-summary",
  })
  Assert.isTrue(
    ScriptCacheWriter.stageSummary(summary, plan) ~= nil,
    "the complete generation must publish its summary"
  )
  summary:finishSuccess({ marker = plan.marker })
  Assert.isTrue(
    summary:publish({
      generationId = "rom-outer-generation",
      epoch = 1,
      kind = "script-member",
      key = "global",
      jobKey = "script-member:global",
    }),
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
    provenance = cache:read(ScriptCache.generationProvenancePath(generation)),
    coverage = cache:read(ScriptCache.generationCoverageJsonPath(generation)),
    coverageMarkdown = cache:read(ScriptCache.generationCoverageMdPath(generation)),
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
