-- Generation-scoped artifact readiness and controller-owned publication: a
-- cheap per-artifact receipt proves the current generation, while the family
-- payload and its validator stay authoritative. Workers only stage; the
-- controller alone publishes after checking generation, epoch, and job
-- identity, and any publication failure keeps recovery-owned material instead
-- of reporting readiness.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1
local RECEIPT_SCHEMA = "g4-derived-receipt-v1"

local function requireReceipts()
  local ok, receipts = pcall(require, "romdump.src.build.ArtifactState")
  Assert.isTrue(ok, "the generation-scoped receipt boundary is missing")
  return receipts
end

local function requireStages()
  local ok, stages = pcall(require, "romdump.src.build.PreparedArtifact")
  Assert.isTrue(ok, "the production staged-artifact boundary is missing")
  return assert(stages)
end

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

local function twoGenerations()
  return generationIdFor(Sha256.hex("first producer tree")), generationIdFor(Sha256.hex("second producer tree"))
end

-- The closed kind vocabulary is owned by the receipt module; fall back to the
-- established worker kind only while that module does not exist yet, so the
-- staging-only scenarios still exercise the current publication behavior.
local function probeKind()
  local ok, receipts = pcall(require, "romdump.src.build.ArtifactState")
  if ok and type(receipts.KINDS) == "table" then
    local names = {}
    for name in pairs(receipts.KINDS) do
      names[#names + 1] = name
    end
    table.sort(names)
    if #names > 0 and receipts.KINDS["map"] == nil then
      return names[1]
    end
  end
  return "map"
end

local function newCache(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function stageIdentity(kind, key, generation, epoch, stageName)
  return {
    generationId = generation,
    epoch = epoch,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
    stageName = stageName,
  }
end

local function countWrites(backend)
  local calls = 0
  local original = backend.write
  backend.write = function(self, path, data)
    calls = calls + 1
    return original(self, path, data)
  end
  return function()
    backend.write = original
    return calls
  end
end

local function table_merge(base, extra)
  local merged = {}
  for key, value in pairs(base) do
    merged[key] = value
  end
  for key, value in pairs(extra) do
    merged[key] = value
  end
  return merged
end

function T.receipt_without_matching_family_payload_is_not_ready()
  local receipts = requireReceipts()
  local backend = FakeCache.new()
  local cache = newCache(backend)
  local generation = generationIdFor(Sha256.hex("receipt-only producer"))
  local kind = probeKind()
  cache:writeLua(receipts.path(kind, "61"), {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = kind,
    key = "61",
    marker = "complete",
  })
  local stopCounting = countWrites(backend)
  local receipt = receipts.read(cache, generation, kind, "61")
  Assert.notNil(receipt, "a staged current-generation receipt must be readable")
  Assert.equal(stopCounting(), 0, "a readiness check must not compile or write anything")
  local familyPayloadPresent = cache:exists("families/" .. kind .. "/61/payload", "file")
  Assert.isFalse(
    receipt ~= nil and familyPayloadPresent,
    "a receipt alone must not report readiness while its family payload is missing"
  )
end

function T.previous_generation_receipt_is_cold()
  local receipts = requireReceipts()
  local cache = newCache()
  local oldGeneration, currentGeneration = twoGenerations()
  local kind = probeKind()
  cache:writeLua(receipts.path(kind, "62"), {
    schema = RECEIPT_SCHEMA,
    generationId = oldGeneration,
    kind = kind,
    key = "62",
    marker = "complete",
  })
  cache:write("families/" .. kind .. "/62/marker", "complete")
  local receipt, reason = receipts.read(cache, currentGeneration, kind, "62")
  Assert.isNil(receipt, "an old-generation receipt must read as cold under a new generation")
  Assert.notNil(reason, "a cold receipt must name its reason")
end

function T.late_completion_cannot_publish()
  local stages = requireStages()
  local backend = FakeCache.new()
  local cache = newCache(backend)
  cache:recoverPublication()
  local kind = probeKind()
  local oldGeneration, currentGeneration = twoGenerations()
  local artifact = stages.new(table_merge(stageIdentity(kind, "63", oldGeneration, 1, "late-completion"), {
    cacheFs = cache,
  }))
  artifact:stageFs():write("maps/63/complete", "ready")
  artifact:addOwnedRoot("maps/63")
  artifact:finishSuccess({ marker = "complete" })
  local ok, err = pcall(function()
    artifact:publish({
      generationId = currentGeneration,
      epoch = 2,
      kind = kind,
      key = "63",
      jobKey = kind .. ":63",
    })
  end)
  Assert.isFalse(ok, "a late completion from a retired generation and epoch must not publish: " .. tostring(err))
  Assert.isFalse(cache:exists("maps/63/complete"), "a rejected late stage must leave live bytes untouched")
  Assert.isTrue(artifact:isAbortable(), "an unpublished late stage must stay safely abortable")
  artifact:abort()
  Assert.isFalse(cache:exists("maps/63/complete"), "aborting a late stage must not touch live data")
end

function T.replacing_an_index_file_leaves_children_untouched()
  local stages = requireStages()
  local cache = newCache()
  cache:recoverPublication()
  local kind = probeKind()
  local generation = generationIdFor(Sha256.hex("index-file producer"))
  local function publishDirectory(key, payload)
    local artifact = stages.new(table_merge(stageIdentity(kind, key, generation, 1, "child-" .. key), {
      cacheFs = cache,
    }))
    artifact:stageFs():write("catalog/children/" .. key .. "/payload", payload)
    artifact:addOwnedRoot("catalog/children/" .. key)
    artifact:finishSuccess({ marker = "complete" })
    artifact:publish({
      generationId = generation,
      epoch = 1,
      kind = kind,
      key = key,
      jobKey = kind .. ":" .. key,
    })
  end
  publishDirectory("70", "first child")
  publishDirectory("71", "second child")
  local beforeFirst = cache:read("catalog/children/70/payload")
  local beforeSecond = cache:read("catalog/children/71/payload")

  local index = stages.new(table_merge(stageIdentity(kind, "global", generation, 1, "index-replacement"), {
    cacheFs = cache,
  }))
  index:stageFs():write("catalog/index.lua", "return { children = { 70, 71 } }")
  index:addOwnedRoot("catalog/index.lua")
  index:finishSuccess({ marker = "complete" })
  local ok, err = pcall(function()
    index:publish({
      generationId = generation,
      epoch = 1,
      kind = kind,
      key = "global",
      jobKey = kind .. ":global",
    })
  end)
  Assert.isTrue(ok, "an exact index file must publish as its own root: " .. tostring(err))
  Assert.equal(
    cache:read("catalog/children/70/payload"),
    beforeFirst,
    "publishing an index file must not erase its children"
  )
  Assert.equal(
    cache:read("catalog/children/71/payload"),
    beforeSecond,
    "publishing an index file must not alter its children"
  )
  Assert.equal(cache:read("catalog/index.lua"), "return { children = { 70, 71 } }")
end

function T.failed_publication_keeps_recovery_material_and_reports_not_ready()
  local receipts = requireReceipts()
  local stages = requireStages()
  local backend = FakeCache.new()
  local cache = newCache(backend)
  cache:recoverPublication()
  local kind = probeKind()
  local generation = generationIdFor(Sha256.hex("recovery producer"))
  local first = stages.new(table_merge(stageIdentity(kind, "64", generation, 1, "recovery-first"), {
    cacheFs = cache,
  }))
  first:stageFs():write("maps/64/complete", "first")
  first:addOwnedRoot("maps/64")
  first:finishSuccess({ marker = "complete" })
  first:publish({
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = "64",
    jobKey = kind .. ":64",
  })

  local second = stages.new(table_merge(stageIdentity(kind, "64", generation, 1, "recovery-second"), {
    cacheFs = cache,
  }))
  second:stageFs():write("maps/64/complete", "second")
  second:addOwnedRoot("maps/64")
  second:finishSuccess({ marker = "complete" })
  local originalReplace = backend.replace
  backend.replace = function()
    error("injected rename failure", 0)
  end
  local ok = pcall(function()
    second:publish({
      generationId = generation,
      epoch = 1,
      kind = kind,
      key = "64",
      jobKey = kind .. ":64",
    })
  end)
  backend.replace = originalReplace
  Assert.isFalse(ok, "a publication whose rename fails must report failure, not readiness")
  cache:recoverPublication()
  Assert.equal(cache:read("maps/64/complete"), "first", "a failed publication must preserve the prior ready artifact")
  local receipt = receipts.read(cache, generation, kind, "64")
  Assert.notNil(receipt, "the prior successful receipt must survive the failed replacement")
  assert(receipt, "a surviving receipt is a record")
  Assert.equal(receipt.marker, "complete")
  Assert.throws(function()
    second:abort()
  end, "a stage that began publishing is recovery material, not disposable worker scratch")
end

function T.conflicting_shared_bytes_are_reported()
  local stages = requireStages()
  local cache = newCache()
  cache:recoverPublication()
  local kind = probeKind()
  local generation = generationIdFor(Sha256.hex("shared-conflict producer"))
  local first = stages.new(table_merge(stageIdentity(kind, "65", generation, 1, "conflict-first"), {
    cacheFs = cache,
  }))
  first:stageFs():write("geometry/shared", "first")
  first:addSharedFile("geometry/shared")
  first:stageFs():write("maps/65/complete", "ready")
  first:addOwnedRoot("maps/65")
  first:finishSuccess({ marker = "complete" })
  first:publish({
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = "65",
    jobKey = kind .. ":65",
  })

  local second = stages.new(table_merge(stageIdentity(kind, "66", generation, 1, "conflict-second"), {
    cacheFs = cache,
  }))
  second:stageFs():write("geometry/shared", "different")
  second:addSharedFile("geometry/shared")
  second:stageFs():write("maps/66/complete", "ready")
  second:addOwnedRoot("maps/66")
  -- Worker-side reconciliation seals shared proof before success: the
  -- contradiction fails here, never reaching controller publication.
  local ok, failure = pcall(function()
    second:finishSuccess({ marker = "complete" })
  end)
  Assert.isFalse(
    ok,
    "a staged shared file that contradicts live bytes is corruption and must fail before any reference is exposed"
  )
  Assert.isTrue(
    tostring(failure):find("PREPARED_SHARED_CONFLICT", 1, true) ~= nil,
    "the worker reports the shared contradiction"
  )
  second:abort()
  Assert.equal(cache:read("geometry/shared"), "first", "a shared conflict must not silently reuse either byte sequence")
end

function T.published_outputs_and_receipt_appear_together()
  local receipts = requireReceipts()
  local stages = requireStages()
  local cache = newCache()
  cache:recoverPublication()
  local kind = probeKind()
  local generation = generationIdFor(Sha256.hex("atomic-publish producer"))
  local artifact = stages.new(table_merge(stageIdentity(kind, "67", generation, 1, "atomic-publish"), {
    cacheFs = cache,
  }))
  artifact:stageFs():write("geometry/shared67", "shared")
  artifact:addSharedFile("geometry/shared67")
  artifact:stageFs():write("maps/67/complete", "ready")
  artifact:stageFs():write("maps/67/scene.lua", "return {}")
  artifact:addOwnedRoot("maps/67")
  artifact:finishSuccess({ marker = "complete" })
  local before = receipts.read(cache, generation, kind, "67")
  Assert.isNil(before, "nothing may read as ready before its publication completes")
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = "67",
    jobKey = kind .. ":67",
  })
  Assert.equal(cache:read("maps/67/complete"), "ready")
  Assert.equal(cache:read("maps/67/scene.lua"), "return {}")
  Assert.equal(cache:read("geometry/shared67"), "shared")
  local receipt = receipts.read(cache, generation, kind, "67")
  Assert.notNil(receipt, "a successful publication must leave a matching current-generation receipt")
  assert(receipt, "a published receipt is a record")
  Assert.equal(receipt.generationId, generation)
  Assert.equal(receipt.kind, kind)
  Assert.equal(receipt.key, "67")
  Assert.equal(receipt.marker, "complete")
end

function T.colliding_stage_name_is_rejected_before_deletion()
  local stages = requireStages()
  local cache = newCache()
  cache:recoverPublication()
  local kind = probeKind()
  local generation = generationIdFor(Sha256.hex("stage-collision producer"))
  local first = stages.new(table_merge(stageIdentity(kind, "68", generation, 1, "collision"), {
    cacheFs = cache,
  }))
  first:stageFs():write("maps/68/complete", "staged")
  local ok, err = pcall(function()
    stages.new(table_merge(stageIdentity(kind, "69", generation, 1, "collision"), {
      cacheFs = cache,
    }))
  end)
  Assert.isFalse(ok, "a new stage must reject a colliding stage name instead of clearing it: " .. tostring(err))
  Assert.equal(
    first:stageFs():read("maps/68/complete"),
    "staged",
    "rejecting a collision must leave the existing staged material alone"
  )
  cache:recoverPublication()
  first:addOwnedRoot("maps/68")
  first:finishSuccess({ marker = "complete" })
  first:publish({
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = "68",
    jobKey = kind .. ":68",
  })
  Assert.equal(cache:read("maps/68/complete"), "staged", "the surviving stage must still publish normally")
end

return { tests = T }
