-- Script member publication contract: members stage through a worker-owned
-- preparation, never through a live cache handle, and the generation summary
-- activates the complete selection only after every declared member is
-- current. Registry fingerprints stay derived from published script content,
-- so an unrelated producer rotation preserves saves while a real semantic
-- edit does not.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local Registry = require("libs.script.src.Registry")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local ScriptErrors = require("libs.script.src.errors")
local ScriptSave = require("libs.script.src.ScriptSave")

local T = {}

local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)
local MARKER_A = "script-cache-v4:rom-sha:gen-a"
local MARKER_B = "script-cache-v4:rom-sha:gen-b"
local ROM_SHA = "rom-sha"
-- The source identity of one script member is content-derived (the producer
-- hashes the member bytes), so it stays stable when only the producer
-- identity rotates. Both generations below share it; only the generation
-- key and markers differ, which are never emitted into resources.
local SOURCE_HASH = string.rep("c", 40)
local OUTER_GENERATION_A = "outer-generation-a"
local OUTER_GENERATION_B = "outer-generation-b"

local function coverageFor(memberId, id)
  return {
    source = { repository = "portemon", romSha1 = ROM_SHA },
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
  }
end

local function resourceFor(id, _, generation, steps)
  return {
    api = 1,
    id = id,
    metadata = {
      generated = true,
      generation = generation,
      source = { sourceHash = SOURCE_HASH },
      coverage = { complete = true, unsupportedCount = 0 },
    },
    steps = steps or { { op = "stop" } },
  }
end

local function memberFor(memberId, id, generation, steps)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    sourceHash = SOURCE_HASH,
    coverage = coverageFor(memberId, id),
    resources = {
      {
        id = id,
        member = memberId,
        scriptIndex = 0,
        sourceHash = SOURCE_HASH,
        resource = resourceFor(id, memberId, generation, steps),
        report = { complete = true, unsupportedCount = 0 },
        directDependencies = { audioSequences = {}, scriptTargets = {} },
      },
    },
  }
end

local function planFor(generation, marker, specs)
  local members = {}
  local resources = {}
  for _, spec in ipairs(specs) do
    members[#members + 1] = { memberId = spec.memberId, marker = generation .. ":member:" .. tostring(spec.memberId) }
    resources[#resources + 1] = { id = spec.id, member = spec.memberId, scriptIndex = 0 }
  end
  local result = {
    generationKey = generation,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/a/0/1/2",
    romSha1 = ROM_SHA,
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = ROM_SHA,
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    memberCount = #specs,
    members = members,
    resources = resources,
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = #specs,
    scriptMemberCount = #specs,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    resources = resources,
  }
  return result
end

local function memberSpecs()
  return {
    { memberId = 0, id = "stable.script" },
    { memberId = 1, id = "second.script" },
  }
end

local function memberArtifact(cache, memberId, stageName, outerGeneration, epoch)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = tostring(memberId),
    jobKey = "script-member:" .. tostring(memberId),
    stageName = stageName,
  })
end

local function summaryArtifact(cache, stageName, outerGeneration, epoch)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
    stageName = stageName,
  })
end

local function stageAndPublishMember(cache, plan, member, stageName, outerGeneration, epoch)
  local artifact = memberArtifact(cache, member.memberId, stageName, outerGeneration, epoch)
  Assert.isTrue(ScriptCacheWriter.stageMember(artifact, plan, member))
  artifact:addOwnedRoot(ScriptCache.memberDir(plan.generationKey, member.memberId))
  artifact:finishSuccess({ marker = member.marker })
  artifact:publish({
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = tostring(member.memberId),
    jobKey = "script-member:" .. tostring(member.memberId),
  })
end

local function stageAndPublishSummary(cache, plan, stageName, outerGeneration, epoch)
  local artifact = summaryArtifact(cache, stageName, outerGeneration, epoch)
  Assert.isTrue(ScriptCacheWriter.stageSummary(artifact, plan) ~= nil)
  artifact:finishSuccess({ marker = plan.marker })
  artifact:publish({
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = "global",
    jobKey = "script-member:global",
  })
end

local function publishCompleteGeneration(cache, generation, marker, specs, prefix, outerGeneration)
  local plan = planFor(generation, marker, specs or memberSpecs())
  for _, spec in ipairs(specs or memberSpecs()) do
    stageAndPublishMember(
      cache,
      plan,
      memberFor(spec.memberId, spec.id, generation),
      prefix .. "-member-" .. tostring(spec.memberId),
      outerGeneration
    )
  end
  stageAndPublishSummary(cache, plan, prefix .. "-summary", outerGeneration)
  return plan
end

local function registryFromPublished(cache, generation, specs)
  local registry = Registry.new()
  for _, spec in ipairs(specs or memberSpecs()) do
    local resource = assert(cache:loadModule(ScriptCache.scriptPath(generation, spec.memberId, spec.id)))
    registry:installBase(spec.id, resource, "generated")
  end
  return registry
end

local function saveBucket(fingerprint)
  return {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = fingerprint,
    taskFingerprint = "tasks",
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

-- A private repair of the already selected member stages through a
-- worker-owned preparation: staging succeeds, live bytes are untouched until
-- publication, and only the current generation and epoch may publish.
function T.selected_member_repairs_stage_without_touching_live_files()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local plan = publishCompleteGeneration(cache, GENERATION_A, MARKER_A, nil, "repair-setup", OUTER_GENERATION_A)
  local liveBefore = assert(cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")))

  local artifact = memberArtifact(cache, 0, "repair-private", OUTER_GENERATION_A)
  Assert.isTrue(ScriptCacheWriter.stageMember(artifact, plan, memberFor(0, "stable.script", GENERATION_A)))
  Assert.equal(
    cache:read(ScriptCache.scriptPath(GENERATION_A, 0, "stable.script")),
    liveBefore,
    "private staging must not rewrite the live member"
  )
  Assert.equal(
    artifact:stageFs():read(ScriptCache.memberMarkerPath(GENERATION_A, 0)),
    GENERATION_A .. ":member:0",
    "the staged member carries its marker in the private stage"
  )
  artifact:addOwnedRoot(ScriptCache.memberDir(GENERATION_A, 0))
  artifact:finishSuccess({ marker = GENERATION_A .. ":member:0" })

  Assert.throws(function()
    artifact:publish({
      generationId = "stale-outer-generation",
      epoch = 1,
      kind = "script-member",
      key = "0",
      jobKey = "script-member:0",
    })
  end, "a stale generation must not publish a staged member")
  Assert.throws(function()
    artifact:publish({
      generationId = OUTER_GENERATION_A,
      epoch = 2,
      kind = "script-member",
      key = "0",
      jobKey = "script-member:0",
    })
  end, "a stale epoch must not publish a staged member")
  Assert.isTrue(artifact:publish({
    generationId = OUTER_GENERATION_A,
    epoch = 1,
    kind = "script-member",
    key = "0",
    jobKey = "script-member:0",
  }))
  Assert.isTrue(ScriptCache.isReady(cache, MARKER_A), "the repaired member keeps the selection ready")
end

-- A live cache handle is not a staging surface: the member writer rejects it
-- before any file write, so active generations can never be edited in place.
function T.live_cache_is_rejected_before_any_member_write()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local plan = planFor(GENERATION_A, MARKER_A, memberSpecs())
  local writes = 0
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    writes = writes + 1
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    -- Deliberately pass the live surface where a stage is required: the
    -- writer must reject it before any file write.
    ScriptCacheWriter.stageMember(cache --[[@as PreparedArtifact]], plan, memberFor(0, "stable.script", GENERATION_A))
  end, "a live cache handle must not stage a member")
  Assert.notNil(err)
  Assert.equal(writes, 0, "the rejected live staging must not write any file")
  backend.write = originalWrite
end

-- The summary activates the whole selection at once: after publication both
-- member directories remain intact and the unchanged selection loader
-- resolves the complete generation.
function T.summary_activation_keeps_both_member_directories()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local plan = planFor(GENERATION_A, MARKER_A, memberSpecs())
  for _, spec in ipairs(memberSpecs()) do
    stageAndPublishMember(
      cache,
      plan,
      memberFor(spec.memberId, spec.id, GENERATION_A),
      "activation-member-" .. tostring(spec.memberId),
      OUTER_GENERATION_A
    )
  end
  Assert.isFalse(ScriptCache.isReady(cache, MARKER_A), "members alone must not read as a ready selection")

  stageAndPublishSummary(cache, plan, "activation-summary", OUTER_GENERATION_A)

  for _, spec in ipairs(memberSpecs()) do
    local resource = assert(cache:loadModule(ScriptCache.scriptPath(GENERATION_A, spec.memberId, spec.id)))
    resource = resource --[[@as { kind: string, id: string }]]
    Assert.equal(resource.kind, "field_script")
    Assert.equal(resource.id, spec.id)
    Assert.equal(
      cache:read(ScriptCache.memberMarkerPath(GENERATION_A, spec.memberId)),
      GENERATION_A .. ":member:" .. tostring(spec.memberId)
    )
  end
  local selection = assert(ScriptCache.loadActive(cache))
  Assert.equal(selection.generation, GENERATION_A)
  Assert.equal(selection.marker, MARKER_A)
  Assert.isTrue(ScriptCache.isReady(cache, MARKER_A), "the summary must activate the complete selection")
end

-- A generation missing one declared member cannot activate: the summary
-- fails identifying the missing coverage and publishes no active selection.
function T.summary_refuses_to_activate_with_a_missing_member()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local specs = {
    { memberId = 0, id = "stable.script" },
    { memberId = 7, id = "second.script" },
  }
  local plan = planFor(GENERATION_A, MARKER_A, specs)
  stageAndPublishMember(
    cache,
    plan,
    memberFor(0, "stable.script", GENERATION_A),
    "partial-member-0",
    OUTER_GENERATION_A
  )

  local artifact = summaryArtifact(cache, "partial-summary", OUTER_GENERATION_A)
  local err = Assert.throws(function()
    ScriptCacheWriter.stageSummary(artifact, plan)
  end, "a summary with a missing member must fail")
  local detail = tostring(err)
  if type(err) == "table" and type(err.context) == "table" then
    for _, value in pairs(err.context) do
      detail = detail .. " " .. tostring(value)
    end
    if type(err.message) == "string" then
      detail = detail .. " " .. err.message
    end
  end
  Assert.isTrue(
    detail:find("7") ~= nil or detail:lower():find("coverage") ~= nil or detail:lower():find("member") ~= nil,
    "the summary failure must identify the missing coverage: " .. detail
  )
  artifact:abort()
  Assert.isFalse(ScriptCache.isReady(cache, MARKER_A), "an incomplete generation must never read as ready")
  local selection = ScriptCache.loadActive(cache)
  Assert.isNil(selection, "an incomplete generation must publish no active selection")
end

-- Rebuilding byte-equivalent resources under a rotated producer identity
-- keeps the content-derived registry fingerprint, so a save recorded under
-- the first generation validates unchanged under the second.
function T.identical_content_under_two_producer_identities_keeps_the_saved_fingerprint()
  local firstCache = CacheFs.forVersion("heartgold", FakeCache.new())
  publishCompleteGeneration(firstCache, GENERATION_A, MARKER_A, nil, "producer-first", OUTER_GENERATION_A)
  local secondCache = CacheFs.forVersion("heartgold", FakeCache.new())
  publishCompleteGeneration(secondCache, GENERATION_B, MARKER_B, nil, "producer-second", OUTER_GENERATION_B)

  local first = registryFromPublished(firstCache, GENERATION_A)
  local second = registryFromPublished(secondCache, GENERATION_B)
  local firstFingerprint = first:fingerprint()
  Assert.equal(second:fingerprint(), firstFingerprint, "producer-only rotation must not change the content fingerprint")

  local saved = saveBucket(firstFingerprint)
  Assert.isNil(
    ScriptSave.validate(saved, { expectedRegistryFingerprint = firstFingerprint }),
    "the save validates under its own generation"
  )
  Assert.isNil(
    ScriptSave.validate(saved, { expectedRegistryFingerprint = second:fingerprint() }),
    "the same save validates after a producer-only rebuild"
  )
end

-- A genuine semantic edit changes the content fingerprint, so a save
-- recorded under the old registry stays rejected with the existing
-- incompatibility error and no cache-version fallback accepts it.
function T.changed_script_content_stays_incompatible_with_the_saved_fingerprint()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  publishCompleteGeneration(cache, GENERATION_A, MARKER_A, nil, "baseline", OUTER_GENERATION_A)
  local baselineFingerprint = registryFromPublished(cache, GENERATION_A):fingerprint()

  local editedCache = CacheFs.forVersion("heartgold", FakeCache.new())
  local editedPlan = planFor(GENERATION_B, MARKER_B, memberSpecs())
  stageAndPublishMember(
    editedCache,
    editedPlan,
    memberFor(0, "stable.script", GENERATION_B, { { op = "stop" }, { op = "stop" } }),
    "edited-member-0",
    OUTER_GENERATION_B
  )
  stageAndPublishMember(
    editedCache,
    editedPlan,
    memberFor(1, "second.script", GENERATION_B),
    "edited-member-1",
    OUTER_GENERATION_B
  )
  stageAndPublishSummary(editedCache, editedPlan, "edited-summary", OUTER_GENERATION_B)
  local editedFingerprint = registryFromPublished(editedCache, GENERATION_B):fingerprint()
  Assert.isTrue(editedFingerprint ~= baselineFingerprint, "a semantic edit must change the content fingerprint")

  local saved = saveBucket(baselineFingerprint)
  local err = ScriptSave.validate(saved, { expectedRegistryFingerprint = editedFingerprint })
  Assert.isTrue(Errors.is(err), "the stale save must be rejected under the edited registry")
  err = err --[[@as { code: string }]]
  Assert.equal(err.code, ScriptErrors.SCRIPT_REGISTRY_FINGERPRINT_MISMATCH)
end

-- A summary publication interrupted after ownership begins recovers through
-- the existing journal: the previous complete selection stays live, the
-- interrupted stage is recovery material rather than disposable scratch, and
-- a fresh summary stage then activates the new generation.
function T.interrupted_summary_publication_recovers_the_previous_selection()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  publishCompleteGeneration(cache, GENERATION_A, MARKER_A, nil, "recovery-old", OUTER_GENERATION_A)
  Assert.isTrue(ScriptCache.isReady(cache, MARKER_A))

  local nextPlan = planFor(GENERATION_B, MARKER_B, memberSpecs())
  for _, spec in ipairs(memberSpecs()) do
    stageAndPublishMember(
      cache,
      nextPlan,
      memberFor(spec.memberId, spec.id, GENERATION_B),
      "recovery-member-" .. tostring(spec.memberId),
      OUTER_GENERATION_B
    )
  end
  local artifact = summaryArtifact(cache, "recovery-summary", OUTER_GENERATION_B)
  Assert.isTrue(ScriptCacheWriter.stageSummary(artifact, nextPlan) ~= nil)
  artifact:finishSuccess({ marker = MARKER_B })

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
    artifact:publish({
      generationId = OUTER_GENERATION_B,
      epoch = 1,
      kind = "script-member",
      key = "global",
      jobKey = "script-member:global",
    })
  end, "an interrupted summary publication must report failure")
  err = err --[[@as { code: string }]]
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  backend.replace = originalReplace

  -- The interrupted publication moved the previous selection aside into
  -- journal recovery material instead of leaving it live: the complete old
  -- marker remains under the adjacent old root, while no selector is live
  -- until the existing journal recovery runs.
  local oldPrefix = "heartgold/" .. ScriptCache.activeDir() .. ".__g4old."
  local oldMarker
  for path, data in pairs(backend.files) do
    if path:sub(1, #oldPrefix) == oldPrefix and path:sub(-#"/complete") == "/complete" then
      oldMarker = data
    end
  end
  Assert.equal(oldMarker, MARKER_A, "the previous complete selection must remain as recovery material")
  Assert.isFalse(
    ScriptCache.isReady(cache, MARKER_A),
    "a rolled-back selection is not live until journal recovery runs"
  )
  Assert.throws(function()
    artifact:abort()
  end, "an interrupted summary stage is recovery material, not disposable scratch")

  cache:recoverPublication()
  Assert.isTrue(ScriptCache.isReady(cache, MARKER_A), "recovery must preserve the previous selection")
  stageAndPublishSummary(cache, nextPlan, "recovery-summary-retry", OUTER_GENERATION_B)
  Assert.isTrue(ScriptCache.isReady(cache, MARKER_B), "a fresh summary stage must activate the new generation")
end

return { tests = T }
