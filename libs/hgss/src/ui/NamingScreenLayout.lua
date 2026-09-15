-- Canonical HGSS naming surface geometry and integer host placement.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PixelScale = require("libs.ui.src.PixelScale")

local NamingScreenLayout = {}
local WIDTH, HEIGHT = 256, 192
local ROWS, COLUMNS = 6, 13
local KEYBOARD = { x = 8, y = 58, width = 240, height = 106 }
local CONTROL_SPANS = { upper = { 1, 2 }, lower = { 3, 4 }, symbols = { 5, 6 }, back = { 9, 11 }, ok = { 12, 13 } }

---@class NamingScreenLayoutResult
---@field placement table<string, unknown>
---@field surface table<string, number>
---@field keyboard table<string, number>
---@field cells table<integer, table<integer, table<string, number>>>
---@field controls table<string, table<string, number>>
---@field nameSlots table<string, number>
---@field subject table<string, number>

local function rect(x, y, width, height)
  assert(width > 0 and height > 0)
  return { x = x, y = y, width = width, height = height }
end

local function copyRect(value)
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function cellRects()
  local result = {}
  local cellWidth = KEYBOARD.width / COLUMNS
  local cellHeight = KEYBOARD.height / ROWS
  for row = 1, ROWS do
    result[row] = {}
    for column = 1, COLUMNS do
      result[row][column] =
        rect(KEYBOARD.x + (column - 1) * cellWidth, KEYBOARD.y + (row - 1) * cellHeight, cellWidth, cellHeight)
    end
  end
  return result
end

---@param bounds LayoutGeometry.Rect
---@param preferredScale integer
---@return NamingScreenLayoutResult
function NamingScreenLayout.compute(bounds, preferredScale)
  assert(type(bounds) == "table", "naming layout bounds are required")
  assert(
    type(preferredScale) == "number" and preferredScale % 1 == 0 and preferredScale > 0,
    "naming preferred scale must be a positive integer"
  )
  assert(bounds.width >= WIDTH and bounds.height >= HEIGHT, "naming surface cannot fit at 1x")
  local scale = PixelScale.fitPreferred(bounds, WIDTH, HEIGHT, preferredScale)
  local frameWidth, frameHeight = WIDTH * scale, HEIGHT * scale
  local frame = {
    x = math.floor(bounds.x + (bounds.width - frameWidth) / 2),
    y = math.floor(bounds.y + (bounds.height - frameHeight) / 2),
    width = frameWidth,
    height = frameHeight,
  }
  local placement = {
    frame = frame,
    origin = { x = frame.x, y = frame.y },
    scale = scale,
    logicalWidth = WIDTH,
    logicalHeight = HEIGHT,
  }
  local cells = cellRects()
  local controls = {}
  for id, span in pairs(CONTROL_SPANS) do
    controls[id] = rect(
      KEYBOARD.x + (span[1] - 1) * KEYBOARD.width / COLUMNS,
      KEYBOARD.y,
      (span[2] - span[1] + 1) * KEYBOARD.width / COLUMNS,
      KEYBOARD.height / ROWS
    )
  end
  return {
    placement = placement,
    surface = rect(0, 0, WIDTH, HEIGHT),
    keyboard = copyRect(KEYBOARD),
    cells = cells,
    controls = controls,
    nameSlots = rect(32, 22, 192, 24),
    subject = rect(8, 8, 48, 42),
  }
end

NamingScreenLayout.resolve = NamingScreenLayout.compute

function NamingScreenLayout.contains(region, x, y)
  return region ~= nil and LayoutGeometry.containsPoint(region, x, y)
end

return NamingScreenLayout
