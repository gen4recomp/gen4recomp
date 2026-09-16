-- The Naming Screen renderer keeps its focus mark on the source-shaped cell
-- under the controller cursor: the highlighted outline must be the layout's
-- own cell rectangle, exactly one cell carries the selected color, and no
-- synthetic fill or unselected outline remains now that the generated
-- base/page chrome supplies the background pixels.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

local T = { tests = {} }

local SELECTED = { 0.96, 0.82, 0.40, 1 }

local function namingManifest()
  return {
    namingScreen = {
      base = { asset = "hgss.naming_screen.base", image = "assets/generated/field/ui/naming-screen-base.png" },
      pages = {
        upper = {
          asset = "hgss.naming_screen.page_upper",
          image = "assets/generated/field/ui/naming-screen-page-upper.png",
        },
        lower = {
          asset = "hgss.naming_screen.page_lower",
          image = "assets/generated/field/ui/naming-screen-page-lower.png",
        },
        symbols = {
          asset = "hgss.naming_screen.page_symbols",
          image = "assets/generated/field/ui/naming-screen-page-symbols.png",
        },
      },
      placement = { x = 0, y = 80, width = 256, height = 112 },
    },
  }
end

local function imageLoader()
  return function(path)
    return { path = path, release = function() end }
  end
end

local function graphicsFake()
  local calls = {}
  local graphics = {
    push = function()
      calls[#calls + 1] = { name = "push" }
    end,
    pop = function()
      calls[#calls + 1] = { name = "pop" }
    end,
    translate = function()
      calls[#calls + 1] = { name = "translate" }
    end,
    scale = function()
      calls[#calls + 1] = { name = "scale" }
    end,
    setColor = function(r, g, b, a)
      calls[#calls + 1] = { name = "setColor", color = { r, g, b, a } }
    end,
    rectangle = function(mode, x, y, width, height)
      calls[#calls + 1] = { name = "rectangle", mode = mode, rect = { x = x, y = y, width = width, height = height } }
    end,
    draw = function()
      calls[#calls + 1] = { name = "draw" }
    end,
  }
  return graphics, calls
end

local function textFake()
  return {
    drawText = function() end,
    textWidth = function(value)
      return #value * 8
    end,
  }
end

local function snapshot(cursor)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    page = "upper",
    cursor = cursor,
    text = "",
    maxLength = 7,
    grid = grid,
    subject = { kind = "player", gender = 0 },
  }
end

local function lineRectsWithPrecedingColor(calls)
  local colored = {}
  local pending = nil
  for _, call in ipairs(calls) do
    if call.name == "setColor" then
      pending = call.color
    elseif call.name == "rectangle" and call.mode == "line" then
      colored[#colored + 1] = { rect = call.rect, color = pending }
      pending = nil
    end
  end
  return colored
end

local function isColor(actual, expected)
  if actual == nil then
    return false
  end
  for index = 1, 4 do
    if actual[index] ~= expected[index] then
      return false
    end
  end
  return true
end

local function assertSingleSelectedOutline(calls)
  for _, call in ipairs(calls) do
    if call.name == "rectangle" then
      Assert.isTrue(call.mode == "line", "source chrome supplies the pixels, so no synthetic fill remains")
    end
  end
  local outlined = lineRectsWithPrecedingColor(calls)
  Assert.equal(#outlined, 1, "exactly one focus mark remains")
  Assert.isTrue(isColor(outlined[1].color, SELECTED), "the remaining focus mark keeps the selected color")
  return outlined[1].rect
end

function T.tests.focus_outline_uses_the_source_shaped_cell_under_the_cursor()
  local graphics, calls = graphicsFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = namingManifest(),
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 3, column = 5 }), layout)
  renderer:dispose()

  Assert.deepEqual(assertSingleSelectedOutline(calls), layout.cells[3][5])
end

function T.tests.home_row_focus_uses_the_control_region_under_the_cursor()
  local graphics, calls = graphicsFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = namingManifest(),
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 1, column = 9 }), layout)
  renderer:dispose()

  local selected = assertSingleSelectedOutline(calls)
  Assert.deepEqual(selected, layout.cells[1][9])
  Assert.deepEqual(selected, layout.controls.back)
end

return T
