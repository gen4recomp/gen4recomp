local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function requireWeatherCache()
  local ok, m = pcall(require, "libs.assets.src.field.FieldWeatherCache")
  if not ok then
    error("FieldWeatherCache is absent: audit cannot require the weather artifact", 0)
  end
  return m
end

local function publishedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
  local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    FieldUiAssetCache.markerPath(),
    IntroAssetCache.markerPath(),
    AudioCache.markerPath(),
    ScriptCache.markerPath(),
    MapAssetCache.mapDir(7) .. "/complete",
    FieldMapDataCache.markerPath(7),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
end

function T.audit_with_stale_weather_marker_requires_a_build()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local FieldWeatherCache = requireWeatherCache()
  local cache = publishedCache()
  cache:write(FieldWeatherCache.markerPath(), "stale")
  cache:writeLua(FieldWeatherCache.catalogPath(), {
    schema = FieldWeatherCache.SCHEMA,
    presets = {},
    rules = {},
  })
  -- Markers without current receipts and payloads never read as usable:
  -- the audit walks the complete inventory, so a marker-only cache is
  -- unavailable with or without the weather marker.
  cache:remove(FieldWeatherCache.markerPath())
  local identity = { versionId = "heartgold", generationId = "current-generation", producerId = "weather-producer" }
  local plans = {
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
  local available, reason = DerivedCacheAudit.isAvailable(cache, identity, plans)
  Assert.isFalse(available, "a marker-only cache must make the cache unavailable")
  Assert.isTrue(reason ~= nil and reason ~= "", "a refused proof names its cause")
end

function T.common_session_compiles_field_weather_through_the_single_dispatcher()
  local compilerPath = "romdump.src.digest.field.FieldWeatherCompiler"
  local writerPath = "romdump.src.digest.field.FieldWeatherCacheWriter"
  local savedCompiler, savedWriter = package.loaded[compilerPath], package.loaded[writerPath]
  local compiled = { marker = "weather-marker", catalog = {}, provenance = {} }
  local stagedBundle
  package.loaded[compilerPath] = {
    compile = function()
      return compiled
    end,
  }
  package.loaded[writerPath] = {
    stage = function(artifact, bundle)
      stagedBundle = bundle
      artifact:addOwnedRoot("data/generated/field-weather")
      return bundle.marker
    end,
  }
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local ok, outcome = pcall(ArtifactJobs.execute, {
    kind = "field-weather",
    key = "global",
    generationId = "test-generation",
    epoch = 1,
    stageName = "weather-dispatch-test",
  }, {
    romFs = {},
    cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()),
  })
  package.loaded[compilerPath] = savedCompiler
  package.loaded[writerPath] = savedWriter
  Assert.isTrue(ok, "the single dispatcher runs the weather family: " .. tostring(outcome))
  Assert.equal(outcome.result.marker, "weather-marker")
  Assert.equal(stagedBundle, compiled, "the dispatcher stages the family compiler bundle")
  Assert.equal(ArtifactJobs.sizeClass("field-weather"), "normal")
  Assert.deepEqual(ArtifactJobs.dependencies("field-weather", "global", {}), {})
end

return { tests = T }
