-- The Naming Screen renderer keeps its focus mark on the source-shaped cell
-- under the controller cursor: the highlighted outline must be the layout's
-- own cell rectangle, and exactly one cell carries the selected color.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

local T = { tests = {} }

local SELECTED = { 0.96, 0.82, 0.40, 1 }
local UNSELECTED = { 0.28, 0.36, 0.48, 1 }

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

function T.tests.focus_outline_uses_the_source_shaped_cell_under_the_cursor()
  local graphics, calls = graphicsFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 3, column = 5 }), layout)
  renderer:dispose()

  local outlined = lineRectsWithPrecedingColor(calls)
  local cellKey = {}
  for row = 1, 6 do
    for column = 1, 13 do
      local cell = layout.cells[row][column]
      cellKey[string.format("%s/%s/%s/%s", cell.x, cell.y, cell.width, cell.height)] = true
    end
  end
  local selected = {}
  for _, entry in ipairs(outlined) do
    local key = string.format("%s/%s/%s/%s", entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height)
    if cellKey[key] then
      if isColor(entry.color, SELECTED) then
        selected[#selected + 1] = entry.rect
      else
        Assert.isTrue(isColor(entry.color, UNSELECTED), "every other cell outline keeps the unselected color")
      end
    end
  end
  Assert.equal(#selected, 1, "exactly one cell carries the selected color")
  Assert.deepEqual(selected[1], layout.cells[3][5])
end

function T.tests.home_row_focus_uses_the_control_region_under_the_cursor()
  local graphics, calls = graphicsFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 1, column = 9 }), layout)
  renderer:dispose()

  local outlined = lineRectsWithPrecedingColor(calls)
  local selected = {}
  for _, entry in ipairs(outlined) do
    if isColor(entry.color, SELECTED) then
      selected[#selected + 1] = entry.rect
    end
  end
  Assert.equal(#selected, 1, "exactly one home control carries the selected color")
  Assert.deepEqual(selected[1], layout.cells[1][9])
  Assert.deepEqual(selected[1], layout.controls.back)
end

return T
