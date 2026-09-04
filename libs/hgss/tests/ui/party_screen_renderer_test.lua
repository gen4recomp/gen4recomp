-- Party-screen renderer contracts, driven through an injected graphics
-- namespace and a stub icon provider so no GPU resource is created. Covers
-- the draw order (frame, slot surfaces, icons, text/HP/status, cursor,
-- action overlay), occupied/empty/disabled slot presentation, switch
-- source/destination highlight, the action overlay rows, and the closed
-- no-op. Text content rides the presentation records; the fake graphics
-- namespace records call structure, not glyphs.

local Assert = require("tests.support.Assert")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")

local T = {}

local fakeGraphics = require("tests.support.FakeGraphics").new

local function icons()
  return {
    image = function()
      return "atlas"
    end,
    quadFor = function(_, key)
      return { key = key }
    end,
    dimensions = function(_)
      return { width = 32, height = 32 }
    end,
  }
end

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function slot(slot0, overrides)
  local record = { slot = slot0, occupied = false, eligible = false }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function occupiedSlot(slot0, overrides)
  local base = {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON" .. slot0 .. "/f0",
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    hpFraction = 1,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
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
  for index = 1, 6 do
    status.view.slots[index] = slot(index - 1)
  end
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function layout()
  return PartyScreenLayout.resolve({ width = 640, height = 480, cancellable = true })
end

local function countPrints(graphics)
  local count = 0
  for _, primitive in ipairs(graphics.primitives) do
    if primitive == "print" then
      count = count + 1
    end
  end
  return count
end

function T.occupied_slots_draw_icons_text_hp_and_status()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0, { status = "poison", currentHp = 7, maxHp = 20, hpFraction = 0.35 })
  status.view.slots[2] = occupiedSlot(1, { gender = "genderless" })
  renderer:draw(status, layout(), icons())
  Assert.equal(#graphics.draws, 2, "one icon draw per occupied slot")
  Assert.equal(graphics.draws[1].quad.key, "MON0/f0")
  Assert.isTrue(countPrints(graphics) >= 8, "names, levels, HP, and status print per occupied slot")
  Assert.isTrue(#graphics.rectangles > 6, "frames, slots, HP bars, and cursor paint as rectangles")
end

function T.empty_slots_draw_no_icon_or_text()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0)
  local before = countPrints(graphics)
  renderer:draw(status, layout(), icons())
  Assert.equal(#graphics.draws, 1, "empty slots draw no icon")
  Assert.isTrue(countPrints(graphics) > before, "the occupied slot still prints")
end

function T.ineligible_slots_keep_their_icon_with_disabled_chrome()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation({ mode = "select" })
  status.view.slots[1] = occupiedSlot(0, { eligible = false })
  status.view.slots[2] = occupiedSlot(1, { eligible = true })
  renderer:draw(status, layout(), icons())
  Assert.equal(#graphics.draws, 2, "ineligible slots stay visible with their icon")
end

function T.switch_source_and_cursor_highlight()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation({ action = "switch_destination", cursorNode = 1, switchSource = 0 })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1)
  local rectangles = #graphics.rectangles
  renderer:draw(status, layout(), icons())
  Assert.isTrue(#graphics.rectangles > rectangles, "source and destination paint highlight frames")
end

function T.action_overlay_paints_both_rows()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation({ action = "action_choice", actionSelection = "switch" })
  status.view.slots[1] = occupiedSlot(0)
  local prints = countPrints(graphics)
  renderer:draw(status, layout(), icons())
  Assert.isTrue(countPrints(graphics) >= prints + 2, "the overlay prints both action rows")
end

function T.closed_presentation_draws_nothing()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  renderer:draw({ open = false }, layout(), icons())
  Assert.equal(#graphics.draws + #graphics.primitives + #graphics.rectangles, 0)
end

function T.occupied_slots_require_the_icon_provider()
  local graphics = fakeGraphics()
  local renderer = PartyScreenRenderer.new({ graphics = graphics })
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0)
  Assert.throws(function()
    renderer:draw(status, layout(), nil)
  end, "icons without a provider fail instead of drawing blanks")
end

return { tests = T }
