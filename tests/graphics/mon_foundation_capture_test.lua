-- Synthetic coverage for the integrated mon flow: a mixed six-slot party
-- paints every slot through the party-screen layout and renderer.
-- Production-cache variant and party-application graphics live in the
-- derived-cache suite; representative icon/portrait pixels live in the
-- manifest suite.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function decodingQueue(cache)
  local nextToken = 0
  local live = {}
  local queue = {}
  function queue:request(kind, path, priority)
    assert(kind == "image", "icon pages decode as images")
    assert(priority == "demand", "visible party pages decode as demand")
    nextToken = nextToken + 1
    live[nextToken] = path
    return nextToken
  end
  function queue:poll(token)
    assert(live[token], "poll observes a live token")
    return "ready"
  end
  function queue:take(token)
    local path = assert(live[token], "take transfers a live token once")
    live[token] = nil
    local bytes = assert(cache:read(path), "the compiled icon page is present")
    local fileData = assert(love.filesystem.newFileData(bytes, "icon-page.png"), "page bytes form a file")
    return { imageData = assert(love.image.newImageData(fileData), "page bytes decode") }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  return queue
end

local function preparedProvider(cache, keys)
  local provider = MonIconAssetProvider.new(cache, {
    preparationQueue = decodingQueue(cache),
    derivedAssets = {
      requestIconPage = function(pageId, _)
        assert(type(pageId) == "number", "icon demand carries its page")
        return true
      end,
    },
  })
  local ready, failure
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded icon pages prepare: " .. tostring(failure))
  return provider
end

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

---@param slot0 integer
---@param overrides table<string, any>
---@return table<string, any>
local function occupiedSlot(slot0, overrides)
  local record = {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON0/f0",
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    hpFraction = 1,
  }
  for key, value in pairs(overrides) do
    record[key] = value
  end
  return record
end

local function sixSlotView(cursorNode)
  return {
    open = true,
    mode = "view",
    action = "browsing",
    cursorNode = cursorNode,
    switchSource = nil,
    actionSelection = nil,
    view = {
      revision = 7,
      slots = {
        occupiedSlot(0, {}),
        occupiedSlot(1, { gender = "female", status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 }),
        occupiedSlot(2, { status = "burn", currentHp = 10, maxHp = 20, hpFraction = 0.5 }),
        occupiedSlot(3, { gender = "genderless", status = "sleep", currentHp = 20, maxHp = 20, hpFraction = 1 }),
        occupiedSlot(4, { status = "paralysis", currentHp = 1, maxHp = 20, hpFraction = 0.05 }),
        occupiedSlot(5, { status = "faint", currentHp = 0, maxHp = 20, hpFraction = 0 }),
      },
    },
    cancellable = true,
  }
end

local function opaqueCount(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        found = found + 1
      end
    end
  end
  return found
end

function T.mixed_six_slot_party_paints_every_slot(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
    Assert.equal(#layout.slotRects, 6, "all six slots resolve")
    for left = 1, 6 do
      for right = left + 1, 6 do
        local a, b = layout.slotRects[left], layout.slotRects[right]
        Assert.isTrue(
          a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y,
          "party slots never overlap"
        )
      end
    end
    local provider = preparedProvider(iconCache(), { "MON0/f0" })
    local renderer = PartyScreenRenderer.new({ graphics = love.graphics, text = text })
    local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(sixSlotView(5), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    Assert.isTrue(
      opaqueCount(image, size.width, size.height) > 0,
      "the full party paints visible surfaces at " .. size.width .. "x" .. size.height
    )
    -- The healthy lead keeps its slot surface; the damaged second slot
    -- keeps a red HP bar segment; the fainted last slot paints under the
    -- cursor without failing.
    local lead = layout.slotRects[1]
    local r, g, b, a = image:getPixel(math.floor(lead.x + 2), math.floor(lead.y + 2))
    Assert.near(r, 0.2, 0.06, "the lead slot surface paints")
    Assert.near(g, 0.2, 0.06)
    Assert.near(b, 0.28, 0.06)
    Assert.near(a, 1, 0.01)
    local ir, ig = image:getPixel(math.floor(lead.x + 6 + 4), math.floor(lead.y + lead.height / 2))
    Assert.near(ir, 200 / 255, 0.06, "the icon quad draws inside the lead slot")
    Assert.near(ig, 40 / 255, 0.06)
    local second = layout.slotRects[2]
    local hr, hg = image:getPixel(math.floor(second.x + 6 + 32 + 8 + 4), math.floor(second.y + second.height - 10 + 3))
    Assert.isTrue(hr > 0.7 and hg < 0.5, "low HP paints the red zone")
    provider:release()
  end

  -- Selection mode dims the ineligible slot while keeping its icon under
  -- dimmed chrome: a separate layout case the view capture cannot show.
  local size = { width = 640, height = 480 }
  local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
  local status = sixSlotView(0)
  status.mode = "select"
  status.view.slots[2].eligible = false
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local renderer = PartyScreenRenderer.new({ graphics = love.graphics, text = text })
  local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, layout, provider)
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  Assert.isTrue(opaqueCount(image, size.width, size.height) > 0, "selection paints with dimmed chrome")
  provider:release()
end

return GraphicsSmoke.suite(T)
