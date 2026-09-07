-- The test-runner cache probe accepts fully published artifacts and rejects a
-- partial cache without invoking the expensive source compilers. Availability
-- is marker presence only: per-artifact freshness belongs to the cache
-- builder, and implementation freshness belongs to the producer fingerprint.

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
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")

local T = {}

local function publishedCache()
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
    FieldCellCache.markerPath(),
    MonCache.markerPath(),
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

function T.published_artifacts_are_available_without_recompiling()
  Assert.isTrue(DerivedCacheAudit.isAvailable(publishedCache()))
end

function T.a_missing_published_artifact_requires_a_build()
  local cache = publishedCache()
  cache:remove(ScriptCache.markerPath())

  local available, reason = DerivedCacheAudit.isAvailable(cache)

  Assert.isFalse(available)
  Assert.equal(reason, "missing completion marker " .. ScriptCache.markerPath())
end

-- The audio class is one of the required markers: without it the global fast
-- path must never declare the cache usable.
function T.a_missing_audio_marker_requires_a_build()
  local cache = publishedCache()
  cache:remove(AudioCache.markerPath())

  local available, reason = DerivedCacheAudit.isAvailable(cache)

  Assert.isFalse(available)
  Assert.equal(reason, "missing completion marker " .. AudioCache.markerPath())
end

function T.availability_ignores_producer_version_metadata()
  -- Compiler-version provenance must never gate availability: implementation
  -- freshness is owned by the producer fingerprint, which forces a full
  -- rebuild whenever romdump/src changes.
  local cache = publishedCache()
  cache:writeLua(ScriptCache.provenancePath(), {
    schema = ScriptCache.PROVENANCE_SCHEMA,
    dependencies = { compilerVersion = "script-compiler-v0" },
  })

  local available, reason = DerivedCacheAudit.isAvailable(cache)

  Assert.isTrue(available, reason)
end

return { tests = T }
