-- Graphics smoke for the generated-font Main Menu and save viewport clipping.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")

local T = {}

local function renderer(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return MainMenuRenderer.new({ text = text }), text
end

local function view(content, errorText)
  local card = {
    frame = { x = 16, y = 80, width = 128, height = 64 },
    body = { x = 16, y = 80, width = 72, height = 64 },
    overflow = { x = 96, y = 88, width = 40, height = 32 },
  }
  return {
    focusedId = "new-game",
    focus = { region = "global", actionId = "new-game" },
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = {},
    catalogError = errorText,
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 120 },
      global = {
        region = { x = 16, y = 32, width = 128, height = 40 },
        actions = { ["new-game"] = { x = 16, y = 32, width = 128, height = 40 } },
      },
      saves = {
        viewport = content,
        cards = { ["save-1"] = card },
        offset = 0,
      },
      catalogErrorRect = errorText and content or nil,
    },
  }
end

function T.cards_are_clipped_to_the_save_viewport_and_scissor_is_restored(scope)
  local content = { x = 16, y = 80, width = 128, height = 16 }
  local current = view(content)
  current.saves =
    { { id = "save-1", saveId = "save-1", playerName = "PLAYER", canContinue = true, playTimeLabel = "1:00" } }
  current.focus = { region = "saves", saveId = "save-1", lane = "body" }
  current.focusedId = "save-1"
  current.layout.global.actions["new-game"] = { x = 16, y = 32, width = 128, height = 40 }

  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  lg.setScissor(0, 0, 160, 120)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)

  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 0)
  Assert.equal(sy, 0)
  Assert.equal(sw, 160)
  Assert.equal(sh, 120)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(20, 100)
  Assert.near(r, 0.08, 1 / 255)
  Assert.near(g, 0.1, 1 / 255)
  Assert.near(b, 0.15, 1 / 255)
end

function T.catalog_errors_are_drawn_inside_the_returned_error_rectangle(scope)
  local errorRect = { x = 16, y = 80, width = 128, height = 24 }
  local current = view(errorRect, "catalog unreadable")
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0.08, 0.1, 0.15, 1)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local foundErrorPixel = false
  for y = errorRect.y, errorRect.y + errorRect.height - 1 do
    for x = errorRect.x, errorRect.x + errorRect.width - 1 do
      local r, g, b, a = pixels:getPixel(x, y)
      if a > 0 and r > g and r > b then
        foundErrorPixel = true
      end
    end
  end
  Assert.isTrue(foundErrorPixel, "catalog error text must draw inside its returned rectangle")
end

function T.focus_lanes_have_distinct_visual_regions(scope)
  local content = { x = 16, y = 80, width = 128, height = 40 }
  local current = view(content)
  current.saves =
    { { id = "save-1", saveId = "save-1", playerName = "PLAYER", canContinue = true, playTimeLabel = "1:00" } }
  current.layout.saves.cards["save-1"] = {
    frame = { x = 16, y = 80, width = 128, height = 64 },
    body = { x = 16, y = 80, width = 72, height = 64 },
    overflow = { x = 96, y = 88, width = 40, height = 32 },
  }
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  current.focus = { region = "saves", saveId = "save-1", lane = "body" }
  current.focusedId = "save-1"
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
  lg.setCanvas()
  local bodyFocused = scope:own(canvas:newImageData()):getPixel(18, 82)
  current.focus = { region = "saves", saveId = "save-1", lane = "overflow" }
  lg.setCanvas(canvas)
  menuRenderer:draw(current)
  lg.setCanvas()
  local overflowFocused = scope:own(canvas:newImageData()):getPixel(100, 92)
  Assert.isTrue(bodyFocused ~= overflowFocused, "body and overflow focus must render differently")
end

return GraphicsSmoke.suite(T)
