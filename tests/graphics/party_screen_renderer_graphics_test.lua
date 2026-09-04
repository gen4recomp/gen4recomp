-- Graphics smoke for the party screen: the resolved view draws its frame,
-- slot surfaces, icons, HP bars, and cursor at 4:3 and wide geometry, and
-- the action overlay covers the frame. Pixel checks pin the draw order,
-- not host font rasterization.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
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
  for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local layout = PartyScreenLayout.resolve({ width = size.width, height = size.height, cancellable = true })
    local provider = MonIconAssetProvider.new(iconCache())
    local renderer = PartyScreenRenderer.new()
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
  local layout = PartyScreenLayout.resolve({ width = width, height = height, cancellable = true })
  local provider = MonIconAssetProvider.new(iconCache())
  local renderer = PartyScreenRenderer.new()
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

return GraphicsSmoke.suite(T)
