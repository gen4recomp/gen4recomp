-- Starter-choice cache publication through the production writer: a real-ROM
-- compiler bundle must publish atomically into one source-independent cache
-- boundary the runtime can trust, and the derived-cache audit must account
-- for the family. A missing reference, a stale marker, or a failure before
-- marker publication must never read ready. Source basis:
-- pret/pokeheartgold src/choose_starter_app.c and src/choose_starter.c.
-- Requires a ready user-owned dump (rom_dump capability); skips otherwise.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local AudioCache = require("libs.assets.src.audio.AudioCache")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.StarterChoiceAssetCompiler")
  if not ok then
    error("the ROM-derived starter-choice compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function cache()
  local ok, module = pcall(require, "libs.assets.src.StarterChoiceAssetCache")
  if not ok then
    error("the starter-choice cache contract is missing: " .. tostring(module), 0)
  end
  return module
end

local function writer()
  local ok, module = pcall(require, "romdump.src.digest.StarterChoiceAssetCacheWriter")
  if not ok then
    error("the starter-choice cache has no failure-safe publication path: " .. tostring(module), 0)
  end
  return module
end

-- Every sibling family marker plus the world harness the audit fast path
-- requires, so the audit result below isolates the starter-choice family.
local function publishedCache(versionId)
  local cacheFs = CacheFs.forVersion(versionId, FakeCache.new())
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    FieldUiAssetCache.markerPath(),
    IntroAssetCache.markerPath(),
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
    cacheFs:write(path, "complete")
  end
  cacheFs:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cacheFs
end

local function backdropImage(bundle)
  local entry = assert(bundle.manifest.background, "backdrop entry is present")
  Assert.keySet(entry, "height,image,width", "the backdrop is one flat record")
  Assert.isTrue(type(entry.image) == "string", "backdrop entry carries a generated image path")
  Assert.notNil(bundle.assets[entry.image], "backdrop payload is compiled")
  return entry.image
end

function T.published_bundle_is_ready_and_audited(romFs, versionId)
  local bundle = assert(compiler().compile(romFs))
  local cacheFs = publishedCache(versionId)

  Assert.isTrue(writer().write(cacheFs, bundle), "publication succeeds")
  Assert.isTrue(cache().isReady(cacheFs, bundle.marker), "the published family reads ready")
  Assert.isTrue(DerivedCacheAudit.isAvailable(cacheFs), "the audit reports the published cache usable")
end

function T.missing_reference_or_stale_marker_is_not_ready(romFs, versionId)
  local starter = cache()
  local bundle = assert(compiler().compile(romFs))

  local cacheFs = CacheFs.forVersion(versionId, FakeCache.new())
  Assert.isTrue(writer().write(cacheFs, bundle))
  Assert.isTrue(starter.isReady(cacheFs, bundle.marker), "the complete family reads ready first")

  cacheFs:remove(backdropImage(bundle))
  Assert.isFalse(starter.isReady(cacheFs, bundle.marker), "a missing referenced file is not ready")

  local fresh = CacheFs.forVersion(versionId, FakeCache.new())
  Assert.isTrue(writer().write(fresh, bundle))
  Assert.isFalse(starter.isReady(fresh, "stale-marker"), "a stale marker is not ready")

  local audited = publishedCache(versionId)
  local available, reason = DerivedCacheAudit.isAvailable(audited)
  Assert.isFalse(available, "the audit requires the starter-choice family")
  Assert.isTrue(
    tostring(reason):find(starter.markerPath(), 1, true) ~= nil,
    "the audit names the starter-choice marker: " .. tostring(reason)
  )
end

function T.failed_publication_preserves_the_previous_ready_family(romFs, versionId)
  local starter = cache()
  local bundle = assert(compiler().compile(romFs))

  local brokenAssets = {}
  for path, bytes in pairs(bundle.assets) do
    brokenAssets[path] = bytes
  end
  brokenAssets[backdropImage(bundle)] = nil
  local broken = {
    marker = bundle.marker .. ":replacement",
    manifest = bundle.manifest,
    dependencies = bundle.dependencies,
    assets = brokenAssets,
  }

  local pristine = CacheFs.forVersion(versionId, FakeCache.new())
  local pristineOk = pcall(writer().write, pristine, broken)
  Assert.isFalse(pristineOk, "publication with a missing reference must fail")
  Assert.isFalse(starter.isReady(pristine, broken.marker), "a partial family never reads ready")

  local live = CacheFs.forVersion(versionId, FakeCache.new())
  Assert.isTrue(writer().write(live, bundle))
  local liveMarker = live:read(starter.markerPath())
  local liveManifest = live:read(starter.manifestPath())
  Assert.isTrue(starter.isReady(live, bundle.marker), "the previous family reads ready first")

  local replacementOk = pcall(writer().write, live, broken)
  Assert.isFalse(replacementOk, "a failed replacement must reach the caller")
  Assert.equal(live:read(starter.markerPath()), liveMarker, "the previous marker survives")
  Assert.equal(live:read(starter.manifestPath()), liveManifest, "the previous manifest survives")
  Assert.isTrue(starter.isReady(live, liveMarker), "the previous family remains ready")
end

return RomSuite.fromFacts(T)
