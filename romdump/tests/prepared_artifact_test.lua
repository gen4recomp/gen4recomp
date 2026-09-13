-- Identity-sealed worker stages with atomic receipts: a stage carries its
-- generation, epoch, and canonical job identity from construction, finishes
-- only with a result marker plus a real family-owned root, publishes only
-- against the controller-supplied expected identity, and reports a staged
-- shared file that contradicts live bytes instead of silently reusing it.

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
local PREPARED_SCHEMA = "g4-prepared-artifact-v2"
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

local function newCache(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function stageOptions(kind, key, generation, epoch, stageName, cache)
  return {
    cacheFs = cache,
    generationId = generation,
    epoch = epoch,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
    stageName = stageName,
  }
end

local function expectedOf(kind, key, generation, epoch)
  return {
    generationId = generation,
    epoch = epoch,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  }
end

function T.success_manifest_seals_identity_and_stages_its_receipt()
  local receipts = requireReceipts()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("sealed-stage producer"))
  local cache = newCache()
  cache:recoverPublication()
  local artifact = stages.new(stageOptions("map", "61", generation, 1, "sealed-stage", cache))
  artifact:stageFs():write("maps/61/complete", "ready")
  artifact:addOwnedRoot("maps/61")
  artifact:finishSuccess({ marker = "complete" })
  local manifest = artifact:manifest()
  Assert.equal(manifest.schema, PREPARED_SCHEMA)
  Assert.equal(manifest.generationId, generation)
  Assert.equal(manifest.epoch, 1)
  Assert.equal(manifest.kind, "map")
  Assert.equal(manifest.key, "61")
  Assert.equal(manifest.jobKey, "map:61")
  Assert.equal(manifest.stageName, "sealed-stage")
  local receiptPath = receipts.path("map", "61")
  Assert.equal(manifest.ownedRoots[#manifest.ownedRoots], receiptPath)
  local staged = artifact:stageFs():loadLua(receiptPath)
  Assert.deepEqual(staged, {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = "map",
    key = "61",
    marker = "complete",
  })
end

function T.finish_requires_a_marker_and_a_family_root()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("empty-finish producer"))
  local cache = newCache()
  cache:recoverPublication()
  local bare = stages.new(stageOptions("map", "62", generation, 1, "empty-finish", cache))
  Assert.throws(function()
    bare:finishSuccess({ marker = "complete" })
  end)
  Assert.throws(function()
    bare:finishSuccess({ marker = "" })
  end)
  Assert.throws(function()
    bare:finishSuccess({})
  end)
  Assert.isTrue(bare:isAbortable(), "a stage that never finished stays abortable")
  Assert.isFalse(bare:stageFs():exists("data/generated/jobs/map/62.lua"), "no receipt is staged without a family root")
  bare:abort()
end

function T.unknown_kinds_and_unsafe_keys_fail_before_io()
  local receipts = requireReceipts()
  local backend = FakeCache.new()
  local cache = newCache(backend)
  local writes = 0
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    writes = writes + 1
    return originalWrite(self, path, data)
  end
  Assert.throws(function()
    receipts.path("portrait", "61")
  end)
  Assert.throws(function()
    receipts.path("map", "../escape")
  end)
  Assert.throws(function()
    receipts.path("map", "01")
  end)
  Assert.throws(function()
    receipts.path("map", "3-12")
  end)
  Assert.throws(function()
    receipts.read(cache, "generation", "portrait", "61")
  end)
  Assert.throws(function()
    receipts.read(cache, "generation", "map", "a/b")
  end)
  backend.write = originalWrite
  Assert.equal(writes, 0, "kind and key validation must precede any cache write")
  Assert.equal(receipts.path("field-cell", "3-12"), "data/generated/jobs/field-cell/3-12.lua")
  Assert.equal(receipts.path("map", "global"), "data/generated/jobs/map/global.lua")
  Assert.equal(receipts.path("map", "0"), "data/generated/jobs/map/0.lua")
end

function T.receipt_validation_names_identity_mismatches()
  local receipts = requireReceipts()
  local generation = generationIdFor(Sha256.hex("receipt-validation producer"))
  local current = {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = "map",
    key = "63",
    marker = "complete",
  }
  local ok, reason = receipts.validate(current, { generationId = generation, kind = "map", key = "63" })
  Assert.isTrue(ok)
  Assert.isNil(reason)
  ok, reason = receipts.validate("not-a-table", { generationId = generation, kind = "map", key = "63" })
  Assert.isNil(ok)
  Assert.notNil(reason)
  ok, reason = receipts.validate({ schema = RECEIPT_SCHEMA }, { generationId = generation, kind = "map", key = "63" })
  Assert.isNil(ok, "a receipt missing its identity must not validate")
  Assert.notNil(reason)
  local stale = {
    schema = RECEIPT_SCHEMA,
    generationId = generationIdFor(Sha256.hex("other producer tree")),
    kind = "map",
    key = "63",
    marker = "complete",
  }
  ok, reason = receipts.validate(stale, { generationId = generation, kind = "map", key = "63" })
  Assert.isNil(ok, "an old-generation receipt must not validate as current")
  Assert.notNil(reason)
  local wrongKey = {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = "map",
    key = "64",
    marker = "complete",
  }
  ok, reason = receipts.validate(wrongKey, { generationId = generation, kind = "map", key = "63" })
  Assert.isNil(ok, "a receipt for another key must not validate")
  local padded = {
    schema = RECEIPT_SCHEMA,
    generationId = generation,
    kind = "map",
    key = "63",
    marker = "complete",
    extra = "unowned",
  }
  ok, reason = receipts.validate(padded, { generationId = generation, kind = "map", key = "63" })
  Assert.isNil(ok, "a receipt carrying unowned fields must not validate")
end

function T.missing_receipt_reads_cold_without_writing()
  local receipts = requireReceipts()
  local backend = FakeCache.new()
  local cache = newCache(backend)
  local generation = generationIdFor(Sha256.hex("cold-read producer"))
  local writes = 0
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    writes = writes + 1
    return originalWrite(self, path, data)
  end
  local receipt, reason = receipts.read(cache, generation, "map", "65")
  backend.write = originalWrite
  Assert.isNil(receipt)
  Assert.notNil(reason)
  Assert.equal(writes, 0, "a readiness read must not write anything")
end

function T.duplicate_roots_coalesce_but_ancestors_are_rejected()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("overlap producer"))
  local cache = newCache()
  cache:recoverPublication()
  local artifact = stages.new(stageOptions("map", "66", generation, 1, "overlap-stage", cache))
  artifact:stageFs():write("maps/66/complete", "ready")
  artifact:addOwnedRoot("maps/66")
  artifact:addOwnedRoot("maps/66")
  Assert.throws(function()
    artifact:addOwnedRoot("maps/66/sub")
  end)
  Assert.throws(function()
    artifact:addOwnedRoot("maps")
  end)
  Assert.throws(function()
    artifact:addSharedFile("maps/66/extra")
  end)
  artifact:finishSuccess({ marker = "complete" })
  artifact:publish(expectedOf("map", "66", generation, 1))
  Assert.equal(cache:read("maps/66/complete"), "ready")
end

function T.shared_files_may_not_hide_inside_owned_roots()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("shared-placement producer"))
  local cache = newCache()
  cache:recoverPublication()
  local artifact = stages.new(stageOptions("map", "67", generation, 1, "shared-placement", cache))
  artifact:stageFs():write("geometry/shared67", "shared")
  artifact:addSharedFile("geometry/shared67")
  Assert.throws(function()
    artifact:addOwnedRoot("geometry")
  end)
  Assert.throws(function()
    artifact:addOwnedRoot("geometry/shared67")
  end)
  artifact:stageFs():write("maps/67/complete", "ready")
  artifact:addOwnedRoot("maps/67")
  artifact:finishSuccess({ marker = "complete" })
  artifact:publish(expectedOf("map", "67", generation, 1))
  Assert.equal(cache:read("geometry/shared67"), "shared")
end

function T.mixed_file_and_directory_roots_publish_together()
  local receipts = requireReceipts()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("mixed-roots producer"))
  local cache = newCache()
  cache:recoverPublication()
  local artifact = stages.new(stageOptions("map", "global", generation, 1, "mixed-roots", cache))
  artifact:stageFs():write("catalog/index.lua", "return {}")
  artifact:addOwnedRoot("catalog/index.lua")
  artifact:stageFs():write("maps/68/complete", "ready")
  artifact:addOwnedRoot("maps/68")
  artifact:finishSuccess({ marker = "complete" })
  artifact:publish(expectedOf("map", "global", generation, 1))
  Assert.equal(cache:read("catalog/index.lua"), "return {}")
  Assert.equal(cache:read("maps/68/complete"), "ready")
  local receipt = receipts.read(cache, generation, "map", "global")
  Assert.notNil(receipt)
  assert(receipt, "a published receipt is a record")
  Assert.equal(receipt.marker, "complete")
end

function T.overlapping_completions_serialize_without_losing_work()
  local receipts = requireReceipts()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("serialized producer"))
  local cache = newCache()
  cache:recoverPublication()
  local first = stages.new(stageOptions("map", "69", generation, 1, "overlap-first", cache))
  local second = stages.new(stageOptions("map", "70", generation, 1, "overlap-second", cache))
  first:stageFs():write("maps/69/complete", "first")
  first:addOwnedRoot("maps/69")
  second:stageFs():write("maps/70/complete", "second")
  second:addOwnedRoot("maps/70")
  first:finishSuccess({ marker = "complete" })
  second:finishSuccess({ marker = "complete" })
  first:publish(expectedOf("map", "69", generation, 1))
  second:publish(expectedOf("map", "70", generation, 1))
  Assert.equal(cache:read("maps/69/complete"), "first")
  Assert.equal(cache:read("maps/70/complete"), "second")
  Assert.notNil(receipts.read(cache, generation, "map", "69"))
  Assert.notNil(receipts.read(cache, generation, "map", "70"))

  local replacement = stages.new(stageOptions("map", "69", generation, 1, "overlap-replacement", cache))
  replacement:stageFs():write("maps/69/complete", "replaced")
  replacement:addOwnedRoot("maps/69")
  replacement:finishSuccess({ marker = "complete" })
  replacement:publish(expectedOf("map", "69", generation, 1))
  Assert.equal(cache:read("maps/69/complete"), "replaced")
  local receipt = receipts.read(cache, generation, "map", "69")
  Assert.notNil(receipt)
  assert(receipt, "a replaced receipt is a record")
  Assert.equal(receipt.marker, "complete")
end

function T.identical_shared_bytes_promote_once_but_conflicts_fail()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("shared-bytes producer"))
  local cache = newCache()
  cache:recoverPublication()
  local first = stages.new(stageOptions("map", "71", generation, 1, "shared-first", cache))
  first:stageFs():write("geometry/shared", "first")
  first:addSharedFile("geometry/shared")
  first:stageFs():write("maps/71/complete", "ready")
  first:addOwnedRoot("maps/71")
  first:finishSuccess({ marker = "complete" })
  first:publish(expectedOf("map", "71", generation, 1))

  local same = stages.new(stageOptions("map", "72", generation, 1, "shared-same", cache))
  same:stageFs():write("geometry/shared", "first")
  same:addSharedFile("geometry/shared")
  same:stageFs():write("maps/72/complete", "ready")
  same:addOwnedRoot("maps/72")
  same:finishSuccess({ marker = "complete" })
  same:publish(expectedOf("map", "72", generation, 1))
  Assert.equal(cache:read("geometry/shared"), "first")
  Assert.equal(cache:read("maps/72/complete"), "ready")

  local clashing = stages.new(stageOptions("map", "73", generation, 1, "shared-clash", cache))
  clashing:stageFs():write("geometry/shared", "different")
  clashing:addSharedFile("geometry/shared")
  clashing:stageFs():write("maps/73/complete", "ready")
  clashing:addOwnedRoot("maps/73")
  clashing:finishSuccess({ marker = "complete" })
  Assert.throws(function()
    clashing:publish(expectedOf("map", "73", generation, 1))
  end)
  Assert.equal(cache:read("geometry/shared"), "first", "a shared conflict must keep the live bytes")
  Assert.isFalse(cache:exists("maps/73/complete"), "a shared conflict must not expose the staged family")
end

function T.publish_checks_each_identity_field_before_live_mutation()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("identity-check producer"))
  local otherGeneration = generationIdFor(Sha256.hex("identity-check rival"))
  local cache = newCache()
  cache:recoverPublication()
  local artifact = stages.new(stageOptions("map", "74", generation, 1, "identity-check", cache))
  artifact:stageFs():write("maps/74/complete", "ready")
  artifact:addOwnedRoot("maps/74")
  artifact:finishSuccess({ marker = "complete" })
  local candidates = {
    expectedOf("map", "74", otherGeneration, 1),
    expectedOf("map", "74", generation, 2),
    expectedOf("map", "75", generation, 1),
  }
  local wrongJob = expectedOf("map", "74", generation, 1)
  wrongJob.jobKey = "map:75"
  candidates[#candidates + 1] = wrongJob
  for _, expected in ipairs(candidates) do
    Assert.throws(function()
      artifact:publish(expected)
    end)
  end
  Assert.isFalse(cache:exists("maps/74/complete"), "a rejected identity must leave live bytes untouched")
  Assert.isTrue(artifact:isAbortable(), "a stage rejected before publication stays abortable")
  artifact:publish(expectedOf("map", "74", generation, 1))
  Assert.equal(cache:read("maps/74/complete"), "ready")
end

function T.reopened_stage_publishes_through_the_controller_path()
  local receipts = requireReceipts()
  local stages = requireStages()
  local generation = generationIdFor(Sha256.hex("reopen producer"))
  local cache = newCache()
  cache:recoverPublication()
  local worker = stages.new(stageOptions("map", "75", generation, 1, "reopen-stage", cache))
  worker:stageFs():write("maps/75/complete", "ready")
  worker:addOwnedRoot("maps/75")
  worker:finishSuccess({ marker = "complete" })

  Assert.throws(function()
    stages.open(stageOptions("map", "75", generation, 2, "reopen-stage", cache))
  end, "a retired epoch must not reopen a stage")
  local controller = stages.open(stageOptions("map", "75", generation, 1, "reopen-stage", cache))
  Assert.equal(controller:manifest().result.marker, "complete")
  controller:publish(expectedOf("map", "75", generation, 1))
  Assert.equal(cache:read("maps/75/complete"), "ready")
  local receipt = receipts.read(cache, generation, "map", "75")
  Assert.notNil(receipt, "a controller publication must leave the current receipt")
  assert(receipt, "a controller-published receipt is a record")
  Assert.equal(receipt.marker, "complete")
end

return { tests = T }
