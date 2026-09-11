-- Lifecycle tests for the item icon asset provider, driven against an
-- in-memory cache and a stub graphics namespace so no GPU resource is
-- created. Covers single atlas acquisition, per-key quad caching, unknown
-- keys failing as structured errors (never blank icons), and exactly-once
-- image release. Mirrors the mon icon provider contract for the item
-- icon manifest shape (one atlas rectangle per icon key).

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")

local T = {}

local function manifest()
  return {
    schema = ItemCache.ICON_MANIFEST_SCHEMA,
    atlas = ItemCache.iconImagePath(),
    entries = {
      POTION = { x = 608, y = 352, width = 32, height = 32 },
      POKE_BALL = { x = 0, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION", "POKE_BALL" },
  }
end

local function seed(manifestOverride, imageBytes)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ItemCache.iconManifestPath(), manifestOverride or manifest())
  cache:write(ItemCache.iconImagePath(), imageBytes or "png-bytes")
  return cache
end

local function stubGraphics(created)
  return {
    newImage = function(_)
      local image = { released = false }
      function image:getWidth()
        return 672
      end
      function image:getHeight()
        return 640
      end
      function image:setFilter(_, _) end
      function image:release()
        self.released = true
      end
      created[#created + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
  }
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  if not ok and Errors.is(err) then
    Assert.equal((err --[[@as Errors.Error]]).code, code)
    return
  end
  error("expected structured error " .. code .. ", got: " .. tostring(err), 2)
end

function T.atlas_loads_once_and_quads_cache_per_key()
  local created = {}
  local provider = ItemIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  Assert.equal(#created, 1, "the atlas image loads once for the provider lifetime")
  local first = provider:quadFor("POTION") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(provider:quadFor("POTION") == first, "quads reuse per icon key")
  Assert.equal(first.x, 608)
  Assert.equal(first.y, 352)
  Assert.equal(first.w, 32)
  local ball = provider:quadFor("POKE_BALL") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(ball ~= first)
  Assert.deepEqual(provider:dimensions("POTION"), { width = 32, height = 32 })
  provider:release()
end

function T.unknown_keys_fail_loudly()
  local created = {}
  local provider = ItemIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  throwsCode("ITEM_ICON_UNKNOWN_KEY", function()
    provider:quadFor("MISSINGNO")
  end)
  throwsCode("ITEM_ICON_UNKNOWN_KEY", function()
    provider:dimensions("MISSINGNO")
  end)
  provider:release()
end

function T.release_frees_the_image_exactly_once()
  local created = {}
  local provider = ItemIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  provider:quadFor("POTION")
  provider:release()
  Assert.isTrue(created[1].released, "release frees the atlas image")
  provider:release()
  Assert.isTrue(created[1].released, "a second release stays a safe no-op")
end

function T.missing_artifacts_fail_at_construction()
  local created = {}
  local cache = seed()
  cache:remove(ItemCache.iconImagePath())
  throwsCode("ITEM_ICON_ATLAS_MISSING", function()
    ItemIconAssetProvider.new(cache, { graphics = stubGraphics(created) })
  end)
  throwsCode("ITEM_ICON_MANIFEST_UNAVAILABLE", function()
    ItemIconAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {
      graphics = stubGraphics(created),
    })
  end)
end

return { tests = T }
