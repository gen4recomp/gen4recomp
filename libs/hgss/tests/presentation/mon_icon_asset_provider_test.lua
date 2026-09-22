-- Lifecycle tests for the mon icon asset provider, driven against an
-- in-memory cache and a stub graphics namespace so no GPU resource is
-- created. Covers per-page image acquisition, per-key quad caching,
-- unknown keys failing as structured errors (never blank icons), and
-- exactly-once image release.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")

local T = {}

local function entry(pageId, x, y)
  return {
    x = x,
    y = y,
    width = 32,
    height = 32,
    frames = {
      { x = x, y = y, width = 32, height = 32, duration = 1 },
      { x = x + 32, y = y, width = 32, height = 32, duration = 1 },
    },
    pageId = pageId,
  }
end

local function manifest()
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["CHIKORITA/f0"] = entry(0, 0, 0),
      ["CHIKORITA/egg"] = entry(0, 0, 32),
    },
    representative = { "CHIKORITA/f0", "CHIKORITA/egg" },
  }
end

local function seed(manifestOverride, imageBytes)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), manifestOverride or manifest())
  cache:write(MonCache.iconPagePath(0), imageBytes or "png-bytes")
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

local function readyDerivedAssets()
  return {
    requestIconPage = function(pageId, _)
      assert(type(pageId) == "number", "icon demand carries its page")
      return true
    end,
  }
end

local function readyImageQueue()
  local nextToken = 0
  local live = {}
  local queue = {}
  function queue:request(kind, _, priority)
    assert(kind == "image", "icon pages decode as images")
    assert(priority == "demand", "visible party pages decode as demand")
    nextToken = nextToken + 1
    live[nextToken] = true
    return nextToken
  end
  function queue:poll(token)
    assert(live[token], "poll observes a live token")
    return "ready"
  end
  function queue:take(token)
    assert(live[token], "take transfers a live token once")
    live[token] = nil
    return { imageData = { ready = true } }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  return queue
end

local function preparedProvider(cache, graphics)
  local provider = MonIconAssetProvider.new(cache, {
    graphics = graphics,
    preparationQueue = readyImageQueue(),
    derivedAssets = readyDerivedAssets(),
  })
  return provider
end

local function prepareUntilReady(provider, keys)
  local ready, failure = false, nil
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded pages prepare: " .. tostring(failure))
  Assert.isNil(failure, "preparation reports no failure")
  return provider
end

function T.atlas_loads_once_and_quads_cache_per_key()
  local created = {}
  local provider = preparedProvider(seed(), stubGraphics(created))
  Assert.equal(#created, 0, "construction realizes no page image")
  prepareUntilReady(provider, { "CHIKORITA/f0", "CHIKORITA/egg" })
  Assert.equal(#created, 1, "the page image loads once for the provider lifetime")
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
  local provider = preparedProvider(seed(), stubGraphics(created))
  prepareUntilReady(provider, { "CHIKORITA/f0" })
  provider:quadFor("CHIKORITA/f0")
  provider:release()
  Assert.isTrue(created[1].released, "release frees the page image")
  provider:release()
  Assert.isTrue(created[1].released, "a second release stays a safe no-op")
end

function T.missing_artifacts_fail_at_construction()
  local created = {}
  local cache = seed()
  cache:remove(MonCache.iconPagePath(0))
  local provider = MonIconAssetProvider.new(cache, { graphics = stubGraphics(created) })
  Assert.equal(#created, 0, "missing page bytes never fail metadata construction")
  local ready, failure = preparedProvider(cache, stubGraphics(created)):prepareKeys({ "CHIKORITA/f0" })
  Assert.isFalse(ready, "a page without compiled bytes never reports ready")
  Assert.isTrue(
    tostring(failure):find("mon icon page missing", 1, true) ~= nil,
    "the missing page surfaces as a visible preparation error: " .. tostring(failure)
  )
  provider:release()
  throwsCode("MON_ICON_MANIFEST_UNAVAILABLE", function()
    MonIconAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {
      graphics = stubGraphics(created),
    })
  end)
end

local function pagedManifest()
  local function pageEntry(pageId, x, y)
    return {
      x = x,
      y = y,
      width = 32,
      height = 32,
      frames = {
        { x = x, y = y, width = 32, height = 32, duration = 6 },
        { x = x + 32, y = y, width = 32, height = 32, duration = 6 },
      },
      pageId = pageId,
    }
  end
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
      [1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 },
    },
    pageIds = { 0, 1 },
    entries = {
      ["CHIKORITA/f0"] = pageEntry(0, 0, 0),
      ["CHIKORITA/egg"] = pageEntry(0, 64, 0),
      ["TOTODILE/f0"] = pageEntry(1, 0, 0),
    },
    representative = { "CHIKORITA/f0", "TOTODILE/f0" },
  }
end

local function seedPaged()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), pagedManifest())
  cache:write(MonCache.iconPagePath(0), "page-0-bytes")
  cache:write(MonCache.iconPagePath(1), "page-1-bytes")
  return cache
end

local function countingGraphics(created, failOnCall)
  local calls = 0
  return {
    newImage = function(_)
      calls = calls + 1
      if failOnCall ~= nil and calls == failOnCall then
        error("injected image construction failure", 0)
      end
      local image = { released = false }
      function image:getWidth()
        return 256
      end
      function image:getHeight()
        return 128
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

function T.page_images_are_owned_per_selector_with_exact_release_on_late_failure()
  Assert.equal(type(MonCache.iconPagePath), "function", "icon pages have their own path constructor")
  local created = {}
  local provider = MonIconAssetProvider.new(seedPaged(), {
    graphics = countingGraphics(created),
    preparationQueue = readyImageQueue(),
    derivedAssets = readyDerivedAssets(),
  })
  Assert.equal(#created, 0, "construction acquires no page image")
  prepareUntilReady(provider, { "CHIKORITA/f0", "CHIKORITA/egg", "TOTODILE/f0" })
  Assert.equal(#created, 2, "preparation realizes one image per demanded page")
  Assert.isTrue(
    provider:image("CHIKORITA/f0") ~= provider:image("TOTODILE/f0"),
    "selectors on different pages resolve to their own page image"
  )
  Assert.isTrue(
    provider:image("CHIKORITA/f0") == provider:image("CHIKORITA/egg"),
    "selectors sharing a page share its image"
  )
  local quad = provider:quadFor("TOTODILE/f0") --[[@as { x: number, y: number, w: number, h: number }]]
  Assert.equal(quad.x, 0)
  Assert.equal(quad.w, 32)
  provider:release()
  Assert.isTrue(created[1].released, "release frees the first page image")
  Assert.isTrue(created[2].released, "release frees the second page image")

  -- A GPU realization failure after an earlier page succeeded keeps the
  -- earlier page and surfaces the failure instead of a half-ready icon.
  local failed = {}
  local failing = MonIconAssetProvider.new(seedPaged(), {
    graphics = countingGraphics(failed, 2),
    preparationQueue = readyImageQueue(),
    derivedAssets = readyDerivedAssets(),
  })
  local ready, failure = failing:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
  for _ = 1, 8 do
    if ready or failure ~= nil then
      break
    end
    ready, failure = failing:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
  end
  Assert.isFalse(ready, "a failed realization never reports ready")
  Assert.notNil(failure, "the realization failure carries a diagnosable cause")
  Assert.isTrue(#failed >= 1, "the earlier page realized before the failure")
  Assert.isFalse(failed[1].released, "the earlier page stays live through the sibling failure")
  failing:release()
  Assert.isTrue(failed[1].released, "release frees the earlier page exactly once")
end

-- Construction loads and validates layout metadata without realizing any
-- page image: GPU realization happens only for pages the visible party
-- actually demands, one page per preparation update.
function T.construction_creates_no_page_images()
  local created = {}
  local provider = MonIconAssetProvider.new(seedPaged(), { graphics = countingGraphics(created) })
  Assert.equal(#created, 0, "construction loads metadata without realizing page images")
  provider:release()
end

local function threePageManifest()
  local function pageEntry(pageId, x, y)
    return {
      x = x,
      y = y,
      width = 32,
      height = 32,
      frames = {
        { x = x, y = y, width = 32, height = 32, duration = 6 },
      },
      pageId = pageId,
    }
  end
  return {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
      [1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 },
      [2] = { pageId = 2, image = MonCache.iconPagePath(2), width = 256, height = 128 },
    },
    pageIds = { 0, 1, 2 },
    entries = {
      ["CHIKORITA/f0"] = pageEntry(0, 0, 0),
      ["CYNDAQUIL/f0"] = pageEntry(0, 64, 0),
      ["CHIKORITA/egg"] = pageEntry(1, 0, 0),
      ["TOTODILE/f0"] = pageEntry(1, 64, 0),
      ["MEW/f0"] = pageEntry(2, 0, 0),
    },
    representative = { "CHIKORITA/f0", "TOTODILE/f0", "MEW/f0" },
  }
end

local function seedThreePages()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), threePageManifest())
  cache:write(MonCache.iconPagePath(0), "page-0-bytes")
  cache:write(MonCache.iconPagePath(1), "page-1-bytes")
  cache:write(MonCache.iconPagePath(2), "page-2-bytes")
  return cache
end

local function fakeDerivedAssets(requested)
  return {
    requestIconPage = function(pageId, _)
      requested[#requested + 1] = pageId
      return true
    end,
  }
end

local function fakeImageQueue(requested, decoded)
  local tokens = {}
  local nextToken = 0
  return {
    request = function(_, kind, path, priority)
      assert(kind == "image", "icon pages decode as images")
      assert(priority == "demand", "visible party pages decode as demand")
      nextToken = nextToken + 1
      requested[#requested + 1] = path
      tokens[nextToken] = true
      return nextToken
    end,
    poll = function(_, token)
      assert(tokens[token], "poll observes a live token")
      return "ready"
    end,
    take = function(_, token)
      assert(tokens[token], "take transfers a live token once")
      tokens[token] = nil
      decoded[#decoded + 1] = token
      return { imageData = { fake = true } }
    end,
    cancel = function(_, token)
      tokens[token] = nil
    end,
  }
end

-- Only the pages behind the given icon keys become compilation and decode
-- work: two slots sharing a page deduplicate to one request, egg and form
-- variants on another page share that page, and the unrelated third page
-- is never requested, decoded, or realized. Realization stays bounded to
-- one GPU page per preparation update.
function T.preparation_requests_only_the_pages_behind_the_given_keys()
  local created = {}
  local compiled = {}
  local decodedPaths = {}
  local decodedTokens = {}
  local provider = MonIconAssetProvider.new(seedThreePages(), {
    graphics = countingGraphics(created),
    preparationQueue = fakeImageQueue(decodedPaths, decodedTokens),
    derivedAssets = fakeDerivedAssets(compiled),
  })
  local ready, failure = provider:prepareKeys({ "CHIKORITA/f0", "CYNDAQUIL/f0", "CHIKORITA/egg", "TOTODILE/f0" })
  table.sort(compiled)
  Assert.deepEqual(compiled, { 0, 1 }, "two slots sharing a page deduplicate; the unrelated page is never compiled")
  Assert.equal(#decodedPaths, 2, "only demanded pages reach image decoding")
  Assert.isTrue(ready == true or ready == false, "preparation reports its readiness")
  Assert.isNil(failure, "no failure while demanded pages prepare: " .. tostring(failure))
  Assert.isTrue(#created <= 1, "one preparation update realizes at most one GPU page")
  provider:release()
end

-- Draw-time getters must not synthesize unprepared pages: a page the
-- visible party never demanded stays unavailable until preparation, so a
-- missing page can never silently render as another page or blank icon.
function T.getters_require_prepared_pages_instead_of_loading_on_draw()
  local created = {}
  local provider = MonIconAssetProvider.new(seedPaged(), { graphics = countingGraphics(created) })
  local ok = pcall(function()
    return provider:quadFor("TOTODILE/f0")
  end)
  Assert.isFalse(ok, "draw-time getters must not synthesize unprepared pages")
  provider:release()
end

-- An unknown icon key fails the round as a visible error instead of
-- enrolling partial page work or raising through the update boundary.
function T.unknown_keys_fail_preparation_loudly()
  local provider = MonIconAssetProvider.new(seedThreePages(), {
    graphics = countingGraphics({}),
    preparationQueue = fakeImageQueue({}, {}),
    derivedAssets = fakeDerivedAssets({}),
  })
  local ready, failure = provider:prepareKeys({ "MISSINGNO/f0" })
  Assert.isFalse(ready, "an unknown key never reports ready")
  Assert.isTrue(
    tostring(failure):find("MON_ICON_UNKNOWN_KEY", 1, true) ~= nil,
    "the unknown key carries its structured cause: " .. tostring(failure)
  )
  provider:release()
end

-- Bounds validate per realized page against the decoded image: an
-- undersized page image fails its own pages while healthy pages still
-- prepare, and an undemanded page never blocks the demanded ones.
function T.bounds_validate_only_the_realized_page()
  local function smallGraphics(created)
    local graphics = countingGraphics(created)
    local stub = {}
    function stub.newImage(_)
      local image = graphics.newImage(nil)
      function image:getWidth()
        return 16
      end
      function image:getHeight()
        return 16
      end
      return image
    end
    stub.newQuad = graphics.newQuad
    return stub
  end
  local fresh = function(graphics)
    return MonIconAssetProvider.new(seedThreePages(), {
      graphics = graphics,
      preparationQueue = fakeImageQueue({}, {}),
      derivedAssets = fakeDerivedAssets({}),
    })
  end
  local healthy = fresh(countingGraphics({}))
  local ready, failure = false, nil
  for _ = 1, 8 do
    ready, failure = healthy:prepareKeys({ "CHIKORITA/f0", "TOTODILE/f0" })
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded pages prepare: " .. tostring(failure))
  healthy:release()
  local created = {}
  local broken = fresh(smallGraphics(created))
  local brokenReady, brokenFailure = broken:prepareKeys({ "CHIKORITA/f0" })
  Assert.isFalse(brokenReady, "the undersized page image never reports ready")
  Assert.notNil(brokenFailure, "the bounds failure carries a cause")
  broken:release()
end

return { tests = T }
