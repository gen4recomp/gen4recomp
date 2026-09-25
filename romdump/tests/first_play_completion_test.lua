-- FirstPlayCompletion: the durable attestation that the bounded first-play
-- closure for one immutable cache generation reached ready. Proves the
-- attestation is generation-scoped (a producer or contract change makes an
-- older completion stale), that missing or malformed state is incomplete,
-- that publication is atomic, and that a failed publication never disturbs
-- the previous state. Uses FakeCache-backed version caches; no ROM data.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")

local T = {}

local GENERATION = "g4:heartgold:4fcded0e2713dc03929845de631d0932ea2b5a37:r3:a99:s1"
local STALE_GENERATION = "g4:heartgold:4fcded0e2713dc03929845de631d0932ea2b5a37:r2:a99:s1"

local function freshCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

function T.attestation_path_is_distinct_from_the_whole_corpus_attestation()
  Assert.isFalse(
    FirstPlayCompletion.path == DerivedCacheState.path,
    "first-play completion must never share the strict whole-corpus build attestation"
  )
end

function T.published_completion_round_trips_with_its_exact_record()
  local cache = freshCache()
  FirstPlayCompletion.publish("heartgold", GENERATION, cache)
  Assert.isTrue(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
  local stored = cache:loadLua(FirstPlayCompletion.path)
  Assert.deepEqual(stored, { schema = FirstPlayCompletion.schema, generationId = GENERATION })
end

function T.missing_state_is_incomplete()
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, freshCache()))
  Assert.isFalse(FirstPlayCompletion.hasStored("heartgold", freshCache()))
end

function T.completion_for_another_generation_is_stale()
  local cache = freshCache()
  FirstPlayCompletion.publish("heartgold", STALE_GENERATION, cache)
  Assert.isTrue(FirstPlayCompletion.hasStored("heartgold", cache))
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
end

function T.malformed_state_is_incomplete_without_raising()
  local cache = freshCache()
  cache:write(FirstPlayCompletion.path, "this is not lua {{{")
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
  cache:write(FirstPlayCompletion.path, "return 42")
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
end

function T.record_from_another_schema_or_with_extra_fields_is_stale()
  local cache = freshCache()
  cache:writeLua(FirstPlayCompletion.path, { schema = FirstPlayCompletion.schema + 1, generationId = GENERATION })
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
  cache:writeLua(
    FirstPlayCompletion.path,
    { schema = FirstPlayCompletion.schema, generationId = GENERATION, extra = true }
  )
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
end

function T.empty_generation_never_matches()
  local cache = freshCache()
  FirstPlayCompletion.publish("heartgold", GENERATION, cache)
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", "", cache))
end

function T.failed_publication_preserves_the_previous_completion()
  local cache = freshCache()
  FirstPlayCompletion.publish("heartgold", GENERATION, cache)
  Assert.throws(function()
    FirstPlayCompletion.publish("heartgold", "", cache)
  end)
  Assert.isTrue(
    FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache),
    "a failed publication must leave the previous attestation in place"
  )
end

function T.republication_moves_the_attestation_to_the_new_generation()
  local cache = freshCache()
  FirstPlayCompletion.publish("heartgold", STALE_GENERATION, cache)
  FirstPlayCompletion.publish("heartgold", GENERATION, cache)
  Assert.isTrue(FirstPlayCompletion.isCurrent("heartgold", GENERATION, cache))
  Assert.isFalse(FirstPlayCompletion.isCurrent("heartgold", STALE_GENERATION, cache))
end

function T.release_identity_matches_the_interactive_selection_token()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local expected = DerivedCacheState.currentForSelection({
      versionId = versionId,
      romSha1 = require("romdump.src.source.GameVersion").info(versionId).sha1,
      producerId = "r" .. tostring(require("romdump.src.config.DerivedCacheVersions")[versionId]),
    })
    Assert.equal(
      FirstPlayCompletion.releaseGenerationId(versionId),
      expected.generationId,
      "the release completion token must be the interactive selection generation for " .. versionId
    )
  end
end

return { tests = T }
