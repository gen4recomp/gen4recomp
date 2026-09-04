-- Marker-last publication tests for the mon cache writer, against an
-- in-memory cache and synthetic bundles. Covers readiness, rejection of a
-- malformed class, and failed-rebuild preservation of the previous artifact.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function contracts()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.MonCacheWriter")
  return MonCache, MonCacheWriter
end

local function manifestFor(schema, image)
  return {
    schema = schema,
    image = image,
    entries = {
      ["K/f0"] = { x = 0, y = 0, width = 4, height = 1, frames = { { x = 0, y = 0, width = 4, height = 1 } } },
    },
    representative = { "K/f0" },
  }
end

local function fullItems()
  local items = {}
  for nativeId = 0, 536 do
    items["ITEM_" .. nativeId] = { nativeId = nativeId, isBall = false, friendshipBoost = false }
  end
  items["ITEM_0"] = nil
  items["NONE"] = { nativeId = 0, isBall = false, friendshipBoost = false }
  return items
end

local function bundle(marker)
  local MonCache = require("libs.assets.src.MonCache")
  local pixels = string.rep("\0", 16)
  local zeroCurve = {}
  for level = 1, 100 do
    zeroCurve[level] = 0
  end
  local catalog = {
    schema = "g4-mon-catalog-v2",
    version = { id = "heartgold", language = "english" },
    species = {},
    moves = {},
    abilities = {},
    growthCurves = {
      medium_fast = zeroCurve,
      erratic = zeroCurve,
      fluctuating = zeroCurve,
      medium_slow = zeroCurve,
      fast = zeroCurve,
      slow = zeroCurve,
      unused_6 = zeroCurve,
      unused_7 = zeroCurve,
    },
    items = fullItems(),
  }
  local iconManifest = manifestFor("g4-mon-icon-manifest-v1", MonCache.iconImagePath())
  local portraitManifest = manifestFor("g4-mon-portrait-manifest-v1", MonCache.portraitImagePath())
  return {
    marker = marker,
    index = {
      schema = "g4-mon-index-v1",
      version = { id = "heartgold", language = "english" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(PngWriter.encode(4, 1, pixels)),
      portraitHash = Hashing.sha1hex(PngWriter.encode(4, 1, pixels)),
      catalog = MonCache.catalogPath(),
      icons = MonCache.iconImagePath(),
      iconManifest = MonCache.iconManifestPath(),
      portraits = MonCache.portraitImagePath(),
      portraitManifest = MonCache.portraitManifestPath(),
    },
    catalog = catalog,
    icons = { width = 4, height = 1, pixels = pixels },
    iconManifest = iconManifest,
    portraits = { width = 4, height = 1, pixels = pixels },
    portraitManifest = portraitManifest,
    provenance = {},
  }
end

function T.writes_the_class_and_reports_ready()
  local MonCache, MonCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = MonCache.marker("abc", "dep")
  Assert.equal(MonCacheWriter.write(cache, bundle(marker)), marker)
  Assert.isTrue(MonCache.isReady(cache, marker), "ready after write")
end

function T.rejects_a_malformed_class_without_publishing()
  local MonCache, MonCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = bundle(MonCache.marker("abc", "dep"))
  bad.catalog = { species = { { notASpeciesRecord = true } } }
  local err = Assert.throws(function()
    MonCacheWriter.write(cache, bad)
  end)
  Assert.isTrue(Errors.is(err), "malformed class must fail structurally")
  Assert.isNil(cache:read(MonCache.markerPath()), "no ready marker after rejection")
end

-- Malformed or truncated required source data cannot replace ready content:
-- the rebuild fails structurally, the stage is cleaned, and the prior ready
-- tree stays unchanged and loadable with no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local MonCache, MonCacheWriter = contracts()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = MonCache.marker("abc", "dep")
  MonCacheWriter.write(cache, bundle(firstMarker))

  local broken = bundle(MonCache.marker("abc", "new-dep"))
  broken.catalog = nil
  Assert.throws(function()
    MonCacheWriter.write(cache, broken)
  end)
  Assert.isTrue(MonCache.isReady(cache, firstMarker), "the previous artifact remains ready")
  Assert.equal(cache:read(MonCache.markerPath()), firstMarker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/mons"), "the stage is cleaned on failure")
end

return { tests = T }
