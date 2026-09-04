-- Lifecycle tests for the mon icon asset provider, driven against an
-- in-memory cache and a stub graphics namespace so no GPU resource is
-- created. Covers single atlas acquisition, per-key quad caching, unknown
-- keys failing as structured errors (never blank icons), and exactly-once
-- image release.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")

local T = {}

local function entry(x, y)
  return {
    x = x,
    y = y,
    width = 32,
    height = 32,
    frames = {
      { x = x, y = y, width = 32, height = 32, duration = 1 },
      { x = x + 32, y = y, width = 32, height = 32, duration = 1 },
    },
  }
end

local function manifest()
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["CHIKORITA/f0"] = entry(0, 0),
      ["CHIKORITA/egg"] = entry(0, 32),
    },
    representative = { "CHIKORITA/f0", "CHIKORITA/egg" },
  }
end

local function seed(manifestOverride, imageBytes)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), manifestOverride or manifest())
  cache:write(MonCache.iconImagePath(), imageBytes or "png-bytes")
  return cache
end

local function stubGraphics(created)
  return {
    newImage = function(_)
      local image = { released = false }
      function image:getWidth()
        return 128
      end
      function image:getHeight()
        return 64
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
  local provider = MonIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  Assert.equal(#created, 1, "the atlas image loads once for the provider lifetime")
  local first = provider:quadFor("CHIKORITA/f0") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(provider:quadFor("CHIKORITA/f0") == first, "quads reuse per icon key")
  Assert.equal(first.x, 0)
  Assert.equal(first.w, 32)
  local egg = provider:quadFor("CHIKORITA/egg") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.isTrue(egg ~= first)
  Assert.equal(egg.y, 32)
  Assert.deepEqual(provider:dimensions("CHIKORITA/f0"), { width = 32, height = 32 })
  provider:release()
end

function T.unknown_keys_fail_loudly()
  local created = {}
  local provider = MonIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  throwsCode("MON_ICON_UNKNOWN_KEY", function()
    provider:quadFor("MISSINGNO/f0")
  end)
  throwsCode("MON_ICON_UNKNOWN_KEY", function()
    provider:dimensions("MISSINGNO/f0")
  end)
  provider:release()
end

function T.release_frees_the_image_exactly_once()
  local created = {}
  local provider = MonIconAssetProvider.new(seed(), { graphics = stubGraphics(created) })
  provider:quadFor("CHIKORITA/f0")
  provider:release()
  Assert.isTrue(created[1].released, "release frees the atlas image")
  provider:release()
  Assert.isTrue(created[1].released, "a second release stays a safe no-op")
end

function T.missing_artifacts_fail_at_construction()
  local created = {}
  local cache = seed()
  cache:remove(MonCache.iconImagePath())
  throwsCode("MON_ICON_ATLAS_MISSING", function()
    MonIconAssetProvider.new(cache, { graphics = stubGraphics(created) })
  end)
  throwsCode("MON_ICON_MANIFEST_UNAVAILABLE", function()
    MonIconAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {
      graphics = stubGraphics(created),
    })
  end)
end

return { tests = T }
