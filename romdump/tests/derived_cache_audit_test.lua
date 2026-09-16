-- The generation audit proves one exact generation usable: every job in the
-- complete canonical inventory must carry a current-generation receipt and
-- pass its family validator. Markers alone prove nothing, expected
-- membership is never inferred from published directories, and the
-- full-build attestation is published only after the audit passes, so it is
-- never consulted here. The walk is read-only.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCache = require("libs.assets.src.ItemCache")
local BagCache = require("libs.assets.src.BagCache")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")

local T = {}

local IDENTITY = { versionId = "heartgold", generationId = "current-generation", producerId = "audit-producer" }

-- The smallest well-formed inventory the walk accepts: no cells, no maps,
-- no members, no banks, no pages, so the first global job decides.
local function minimalPlans()
  return {
    indexBundle = { index = { matrices = {} } },
    scriptPlan = { generationKey = string.rep("e", 40), members = {}, resources = {} },
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = {},
    mapIds = {},
  }
end

local function publishedMarkers()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    FieldUiAssetCache.markerPath(),
    IntroAssetCache.markerPath(),
    StarterChoiceAssetCache.markerPath(),
    FieldWeatherCache.markerPath(),
    FieldEffectAssetCache.markerPath(),
    FieldEmoteAssetCache.markerPath(),
    NewGameInitCache.markerPath(),
    FieldCellCache.indexMarkerPath(),
    MonCache.markerPath(),
    ItemCache.markerPath(),
    BagCache.markerPath(),
    ScriptCache.markerPath(),
    AudioCache.markerPath(),
    MapAssetCache.mapDir(7) .. "/complete",
    FieldMapDataCache.markerPath(7),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
end

local function snapshot(backend)
  local copy = {}
  for path, data in pairs(backend.files) do
    copy[path] = data
  end
  return copy
end

function T.availability_requires_an_identity_and_an_inventory()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.isFalse(pcall(DerivedCacheAudit.isAvailable, cache))
  Assert.isFalse(pcall(DerivedCacheAudit.isAvailable, cache, IDENTITY))
end

-- With no receipts at all, the walk refuses the first canonical job and
-- writes nothing.
function T.an_empty_cache_is_unavailable_and_names_its_first_job()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local before = snapshot(backend)
  local available, reason = DerivedCacheAudit.isAvailable(cache, IDENTITY, minimalPlans())
  Assert.isFalse(available)
  Assert.isTrue(
    reason ~= nil and reason:find("actors:global", 1, true) ~= nil,
    "the failure names the first exact job, got: " .. tostring(reason)
  )
  Assert.deepEqual(snapshot(backend), before, "a read-only audit performs no writes")
end

-- Completion markers without current receipts and payloads never read as
-- usable, no matter how many families left them behind.
function T.markers_alone_never_prove_usability()
  local cache = publishedMarkers()
  local available, reason = DerivedCacheAudit.isAvailable(cache, IDENTITY, minimalPlans())
  Assert.isFalse(available, "markers without receipts must not read usable")
  Assert.isTrue(reason ~= nil and reason ~= "", "a refused proof names its cause")
end

-- The audit never consults the attestation file itself (it is published
-- only after the audit passes): with a stale attestation on disk, the
-- failure names the missing receipt instead.
function T.a_stale_attestation_is_never_consulted()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local cache = publishedMarkers()
  cache:writeLua(DerivedCacheState.path, {
    schema = DerivedCacheState.schema,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    mode = "development",
    producerId = "d" .. string.rep("1", 64),
    assetRevision = 11,
    scriptApi = 1,
    generationId = "stale-generation",
  })
  local available, reason = DerivedCacheAudit.isAvailable(cache, IDENTITY, minimalPlans())
  Assert.isFalse(available)
  assert(reason, "a refused proof names its cause")
  Assert.isTrue(reason:find("has no current receipt", 1, true) ~= nil, tostring(reason))
  Assert.isNil(reason:find("build.lua", 1, true), "the attestation is never evidence: " .. tostring(reason))
end

-- A receipt file that no longer parses is damaged data, not a failure:
-- the walk refuses the job with its identity instead of raising.
function T.a_corrupt_receipt_is_unavailable_not_an_error()
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:write(ArtifactState.path("actors", "global"), "not a lua receipt{{{")
  local available, reason = DerivedCacheAudit.isAvailable(cache, IDENTITY, minimalPlans())
  Assert.isFalse(available)
  Assert.isTrue(
    reason ~= nil and reason:find("actors:global", 1, true) ~= nil,
    "the failure names the exact job, got: " .. tostring(reason)
  )
end

-- A malformed inventory is unavailable data, not a programming fault that
-- escapes the read-only boundary.
function T.a_malformed_inventory_is_unavailable()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local available, reason = DerivedCacheAudit.isAvailable(cache, IDENTITY, {})
  Assert.isFalse(available)
  Assert.isTrue(reason ~= nil and reason ~= "", "a refused proof names its cause")
end

return { tests = T }
