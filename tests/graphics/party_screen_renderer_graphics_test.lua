-- Graphics smoke for the party screen: the resolved view draws its frame,
-- slot surfaces, icons, HP bars, and cursor at 4:3 and wide geometry, and
-- the action overlay covers the frame. Pixel checks pin the draw order,
-- not host font rasterization.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

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

local function readyDerivedAssets()
  return {
    requestIconPage = function(pageId, _)
      assert(type(pageId) == "number", "icon demand carries its page")
      return true
    end,
  }
end

local function preparedProvider(cache, keys)
  local provider = MonIconAssetProvider.new(cache, {
    preparationQueue = decodingQueue(cache),
    derivedAssets = readyDerivedAssets(),
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

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function slot(slot0, overrides)
  local record = { slot = slot0, occupied = false, eligible = false }
  if overrides ~= nil then
    record.occupied = true
    record.eligible = true
    record.iconKey = "MON0/f0"
    record.displayName = "MON" .. slot0
    record.level = 5
    record.gender = "male"
    record.status = "ok"
    record.currentHp = 20
    record.maxHp = 20
    record.hpFraction = 1
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table<string, any>?
---@return table<string, any>
local function presentation(overrides)
  local status = {
    open = true,
    mode = "view",
    action = "browsing",
    cursorNode = 0,
    switchSource = nil,
    actionSelection = nil,
    view = { revision = 1, slots = {} },
    cancellable = true,
  }
  status.view.slots[1] = slot(0, {})
  status.view.slots[2] = slot(1, { status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 })
  for index = 3, 6 do
    status.view.slots[index] = slot(index - 1)
  end
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

function T.party_view_paints_frame_slots_icons_hp_and_cursor(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
    local provider = preparedProvider(iconCache(), { "MON0/f0" })
    local renderer = PartyScreenRenderer.new({ graphics = love.graphics, text = text })
    local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(presentation(), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local lead = layout.slotRects[1]
    local r, g, b, a = image:getPixel(math.floor(lead.x + 2), math.floor(lead.y + 2))
    Assert.near(r, 0.2, 0.06, "the lead slot surface paints")
    Assert.near(g, 0.2, 0.06)
    Assert.near(b, 0.28, 0.06)
    Assert.near(a, 1, 0.01)
    -- The lead icon comes from the red fixture atlas.
    local ir, ig = image:getPixel(math.floor(lead.x + 6 + 4), math.floor(lead.y + lead.height / 2))
    Assert.near(ir, 200 / 255, 0.06, "the icon quad draws inside the lead slot")
    Assert.near(ig, 40 / 255, 0.06)
    -- The damaged second slot keeps a red HP bar segment.
    local second = layout.slotRects[2]
    local barY = math.floor(second.y + second.height - 10 + 3)
    local barX = math.floor(second.x + 6 + 32 + 8 + 4)
    local hr, hg = image:getPixel(barX, barY)
    Assert.isTrue(hr > 0.7 and hg < 0.5, "low HP paints the red zone")
    provider:release()
  end
end

function T.action_overlay_covers_the_frame(scope)
  local width, height = 640, 480
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local layout = PartyScreenLayout.resolve({ width = width, height = height, cancellable = true })
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local renderer = PartyScreenRenderer.new({ graphics = love.graphics, text = text })
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(presentation({ action = "action_choice", actionSelection = "cancel" }), layout, provider)
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  local box = layout.actionRects.cancel
  local r, g, b = image:getPixel(math.floor(box.x + 2), math.floor(box.y + 2))
  Assert.near(r, 0.3, 0.08, "the selected action row highlights")
  Assert.near(g, 0.3, 0.08)
  Assert.near(b, 0.45, 0.08)
  provider:release()
end

-- The native compact interface paints through a matched plan: six
-- 122x52 cards in two columns and three rows, source-sized icons, three
-- generated-font text lines with the HP bar, the selected full name in
-- the footer band, and background-only gutters between the cards. The
-- same content magnifies uniformly at an integral second scale.
local COMPACT_NAMES = {
  "ABCDEFGHIJ",
  "BCDEFGHIJK",
  "CDEFGHIJKL",
  "DEFGHIJKLM",
  "EFGHIJKLMN",
  "FGHIJKLMNO",
}
local COMPACT_STATUSES = { "ok", "poison", "burn", "paralysis", "sleep", "freeze" }

---@param slot0 integer
---@return table<string, any>
local function compactRecord(slot0)
  return {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON0/f0",
    displayName = COMPACT_NAMES[slot0 + 1],
    level = 5 + slot0,
    gender = (slot0 % 2 == 0) and "male" or "female",
    status = COMPACT_STATUSES[slot0 + 1],
    currentHp = 20 - slot0 * 3,
    maxHp = 20,
    hpFraction = (20 - slot0 * 3) / 20,
  }
end

---@param cancellable boolean
---@return table<string, any>
local function compactPresentation(cancellable)
  local slots = {}
  for slot0 = 0, 5 do
    slots[slot0 + 1] = compactRecord(slot0)
  end
  slots[2].currentHp = 4
  slots[2].hpFraction = 0.2
  return {
    open = true,
    mode = "view",
    action = "browsing",
    cursorNode = 0,
    switchSource = nil,
    actionSelection = nil,
    view = { revision = 1, slots = slots },
    cancellable = cancellable,
  }
end

---@param content table<string, any>
---@param placement table<string, any>
---@return table<string, any>
local function singlePanePlan(content, placement)
  return {
    panes = { { id = "content", placement = placement, interactive = true } },
    content = content,
    inputKey = "party",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    coverage = {},
    backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
  }
end

---@param value number
---@return integer
local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

---@param data love.ImageData
---@param cornerR number
---@param cornerG number
---@param cornerB number
---@param x0 integer
---@param y0 integer
---@param width integer
---@param height integer
---@return integer, integer
local function scanRegion(data, cornerR, cornerG, cornerB, x0, y0, width, height)
  local other = 0
  local seen = {}
  local distinct = 0
  for y = y0, y0 + height - 1 do
    for x = x0, x0 + width - 1 do
      local r, g, b = data:getPixel(x, y)
      local qr, qg, qb = quantize(r), quantize(g), quantize(b)
      if qr ~= cornerR or qg ~= cornerG or qb ~= cornerB then
        other = other + 1
        local key = qr * 65536 + qg * 256 + qb
        if not seen[key] then
          seen[key] = true
          distinct = distinct + 1
        end
      end
    end
  end
  return other, distinct
end

---@param scope table<string, any>
---@param text table<string, any>
---@param provider table<string, any>
---@param cancellable boolean
---@param canvasWidth integer
---@param canvasHeight integer
---@return love.ImageData
local function drawCompact(scope, text, provider, cancellable, canvasWidth, canvasHeight)
  local content = PartyScreenLayout.resolve({ width = 256, height = 192, cancellable = cancellable })
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = canvasWidth, height = canvasHeight }, 256, 192),
    "the compact canvas fits its single pane"
  )
  local renderer = PartyScreenRenderer.new({ graphics = love.graphics, text = text })
  local canvas = scope:own(love.graphics.newCanvas(canvasWidth, canvasHeight))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  LogicalSurface.draw(love.graphics, placement, function()
    renderer:draw(compactPresentation(cancellable), singlePanePlan(content, placement), provider)
  end)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

function T.compact_native_cards_render_all_slots_text_and_hp_without_overlap(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local image = drawCompact(scope, text, provider, false, 256, 192)
  local cr, cg, cb = image:getPixel(0, 0)
  local cornerR, cornerG, cornerB = quantize(cr), quantize(cg), quantize(cb)
  -- The lead card keeps its identity color on a blank part of its surface.
  local lr, lg, lb = image:getPixel(10, 50)
  Assert.near(lr, 0.2, 0.06, "the lead card keeps its surface color")
  Assert.near(lg, 0.2, 0.06)
  Assert.near(lb, 0.28, 0.06)
  -- A non-lead card keeps the standard surface color on blank chrome.
  local sr, sg, sb = image:getPixel(30, 100)
  Assert.near(sr, 0.16, 0.06, "a follower card keeps its surface color")
  Assert.near(sg, 0.16, 0.06)
  Assert.near(sb, 0.22, 0.06)
  -- The source-sized icon lands at the card's top-left icon region.
  local ir, ig, ib = image:getPixel(10, 10)
  Assert.near(ir, 200 / 255, 0.06, "the icon quad draws inside the lead card")
  Assert.near(ig, 40 / 255, 0.06)
  Assert.near(ib, 40 / 255, 0.06)
  -- The damaged second card keeps a red HP bar segment.
  local hr, hg = image:getPixel(136, 55)
  Assert.isTrue(hr > 0.7 and hg < 0.5, "low HP paints the red zone in the compact card")
  -- The inter-column gutter carries only background: no card, icon, or
  -- text may cross its card's logical rectangle.
  local gutter, gutterColors = scanRegion(image, cornerR, cornerG, cornerB, 128, 4, 2, 164)
  Assert.equal(gutter, 0, "the inter-column gutter stays background")
  Assert.equal(gutterColors, 0, "the inter-column gutter carries no painted colors")
  -- The inter-row gutter carries only background as well.
  local rowGutter, _ = scanRegion(image, cornerR, cornerG, cornerB, 4, 56, 248, 4)
  Assert.equal(rowGutter, 0, "the inter-row gutter stays background")
  -- The footer band shows the selected full name through the generated
  -- font even with no cancel control on screen.
  local footer, footerColors = scanRegion(image, cornerR, cornerG, cornerB, 4, 172, 184, 16)
  Assert.isTrue(footer > 20, "the footer band paints the selected name")
  Assert.isTrue(footerColors >= 2, "the footer band carries more than flat background")
  provider:release()
end

function T.compact_native_cards_render_cancel_and_magnify_uniformly_at_two_x(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local cancellable = drawCompact(scope, text, provider, true, 256, 192)
  local cr, cg, cb = cancellable:getPixel(0, 0)
  local cornerR, cornerG, cornerB = quantize(cr), quantize(cg), quantize(cb)
  -- The allowed cancel control paints inside the footer band.
  local cancel, _ = scanRegion(cancellable, cornerR, cornerG, cornerB, 192, 172, 60, 16)
  Assert.isTrue(cancel > 5, "the allowed cancel control paints in the footer band")
  -- At an integral second scale the same content magnifies uniformly:
  -- gutters stay background and the footer name stays painted.
  local doubled = drawCompact(scope, text, provider, false, 512, 384)
  local dr, dg, db = doubled:getPixel(0, 0)
  local dCornerR, dCornerG, dCornerB = quantize(dr), quantize(dg), quantize(db)
  local gutter, _ = scanRegion(doubled, dCornerR, dCornerG, dCornerB, 256, 8, 4, 328)
  Assert.equal(gutter, 0, "the doubled gutter stays background")
  local footer, footerColors = scanRegion(doubled, dCornerR, dCornerG, dCornerB, 8, 344, 368, 32)
  Assert.isTrue(footer > 40, "the doubled footer band paints the selected name")
  Assert.isTrue(footerColors >= 2, "the doubled footer band carries more than flat background")
  provider:release()
end

return GraphicsSmoke.suite(T)
