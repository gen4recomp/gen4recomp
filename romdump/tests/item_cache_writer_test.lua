-- Marker-last publication tests for the item cache writer, against an
-- in-memory cache and synthetic bundles. Covers readiness, rejection of a
-- malformed class, and failed-rebuild preservation of the previous artifact.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function contracts()
  local ItemCache = require("libs.assets.src.ItemCache")
  local ItemCacheWriter = require("romdump.src.digest.items.ItemCacheWriter")
  return ItemCache, ItemCacheWriter
end

local function bundle(marker)
  local ItemCache = require("libs.assets.src.ItemCache")
  local pixels = string.rep("\0", 32 * 32 * 4)
  local catalog = ItemFixture.buildAssetRoot()
  local entries = {}
  for key in pairs(catalog.items) do
    entries[key] = { x = 0, y = 0, width = 32, height = 32 }
  end
  local iconManifest = {
    schema = "g4-item-icons-v1",
    atlas = ItemCache.iconImagePath(),
    entries = entries,
    representative = { "POTION" },
  }
  return {
    marker = marker,
    index = {
      schema = "g4-item-index-v1",
      version = { id = "heartgold", language = "en" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(PngWriter.encode(32, 32, pixels)),
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    },
    catalog = catalog,
    icons = { width = 32, height = 32, pixels = pixels },
    iconManifest = iconManifest,
    provenance = {},
  }
end

function T.writes_the_class_and_reports_ready()
  local ItemCache, ItemCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = ItemCache.marker("abc", "dep")
  Assert.equal(ItemCacheWriter.write(cache, bundle(marker)), marker)
  Assert.isTrue(ItemCache.isReady(cache, marker), "ready after write")
  local catalog = ItemCache.loadCatalog(cache)
  Assert.equal(catalog.items.POTION.nativeId, 17, "the published catalog loads back")
end

function T.rejects_a_malformed_class_without_publishing()
  local ItemCache, ItemCacheWriter = contracts()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = bundle(ItemCache.marker("abc", "dep"))
  bad.catalog = { items = {} }
  local err = Assert.throws(function()
    ItemCacheWriter.write(cache, bad)
  end)
  Assert.isTrue(Errors.is(err), "malformed class must fail structurally")
  Assert.isNil(cache:read(ItemCache.markerPath()), "no ready marker after rejection")
end

-- A malformed rebuild cannot replace ready content: the rebuild fails
-- structurally, the stage is cleaned, and the prior ready tree stays
-- unchanged and loadable with no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local ItemCache, ItemCacheWriter = contracts()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = ItemCache.marker("abc", "dep")
  ItemCacheWriter.write(cache, bundle(firstMarker))

  local broken = bundle(ItemCache.marker("abc", "new-dep"))
  broken.catalog = nil
  Assert.throws(function()
    ItemCacheWriter.write(cache, broken)
  end)
  Assert.isTrue(ItemCache.isReady(cache, firstMarker), "the previous artifact remains ready")
  Assert.equal(cache:read(ItemCache.markerPath()), firstMarker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/items"), "the stage is cleaned on failure")
end

return { tests = T }
