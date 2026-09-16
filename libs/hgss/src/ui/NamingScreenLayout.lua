-- Canonical HGSS naming surface geometry using the source integer cursor and
-- touch layout. Pinned source: pret/pokeheartgold `src/naming_screen.c`
-- (`NamingScreen_UpdateCursorSpritePosition`, `sTouchHitboxDef`).

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local NamingScreenLayout = {}
local WIDTH, HEIGHT = 256, 192
local ROWS, COLUMNS = 6, 13

---@class NamingScreenLayoutResult
---@field surface table<string, number>
---@field keyboard table<string, number>
---@field cells table<integer, table<integer, table<string, number>>>
---@field cursorCenters table<integer, table<integer, table<string, number>>>
---@field controls table<string, table<string, number>>
---@field nameSlots table<string, number>
---@field subject table<string, number>
---@field placement nil
---@field scale nil

local function rect(x, y, width, height)
  assert(width > 0 and height > 0)
  return { x = x, y = y, width = width, height = height }
end

local HOME_CONTROLS = {
  upper = { x = 25, y = 60, width = 32, height = 23 },
  lower = { x = 57, y = 60, width = 32, height = 23 },
  symbols = { x = 89, y = 60, width = 32, height = 23 },
  back = { x = 157, y = 60, width = 33, height = 23 },
  ok = { x = 197, y = 60, width = 33, height = 23 },
}

local HOME_CENTERS = {
  upper = 25,
  lower = 57,
  symbols = 89,
  back = 158,
  ok = 198,
}

local CONTROL_COLUMNS = {
  upper = { 1, 2 },
  lower = { 3, 4 },
  symbols = { 5, 6 },
  back = { 9, 10, 11 },
  ok = { 12, 13 },
}

local function controlIdAt(column)
  for id, span in pairs(CONTROL_COLUMNS) do
    for _, member in ipairs(span) do
      if member == column then
        return id
      end
    end
  end
  return nil
end

---@param viewport LayoutGeometry.Rect
---@return NamingScreenLayoutResult
function NamingScreenLayout.compute(viewport)
  assert(type(viewport) == "table", "naming layout viewport is required")
  assert(
    type(viewport.width) == "number" and type(viewport.height) == "number",
    "naming layout viewport dimensions are required"
  )
  assert(viewport.width >= WIDTH and viewport.height >= HEIGHT, "naming surface cannot fit in the host viewport")
  local surface = rect(
    math.floor(viewport.x + (viewport.width - WIDTH) / 2),
    math.floor(viewport.y + (viewport.height - HEIGHT) / 2),
    WIDTH,
    HEIGHT
  )
  local cells = {}
  local cursorCenters = {}
  for row = 1, ROWS do
    cells[row] = {}
    cursorCenters[row] = {}
    for column = 1, COLUMNS do
      if row == 1 then
        local id = controlIdAt(column)
        if id == nil then
          -- The source home row leaves a blank gap between Symbols and
          -- Back; those columns own no hit region and no cursor center.
          cells[row][column] = { x = 121, y = 60, width = 0, height = 0 }
          cursorCenters[row][column] = { x = 121, y = 68 }
        else
          cells[row][column] =
            rect(HOME_CONTROLS[id].x, HOME_CONTROLS[id].y, HOME_CONTROLS[id].width, HOME_CONTROLS[id].height)
          cursorCenters[row][column] = { x = HOME_CENTERS[id], y = 68 }
        end
      else
        cells[row][column] = rect(28 + (column - 1) * 16, 88 + (row - 2) * 19, 17, 20)
        cursorCenters[row][column] = { x = 26 + (column - 1) * 16, y = 91 + (row - 2) * 19 }
      end
    end
  end
  local controls = {}
  for id, region in pairs(HOME_CONTROLS) do
    controls[id] = rect(region.x, region.y, region.width, region.height)
  end
  return {
    surface = surface,
    keyboard = rect(8, 58, 240, 106),
    cells = cells,
    cursorCenters = cursorCenters,
    controls = controls,
    nameSlots = rect(32, 22, 192, 24),
    subject = rect(8, 8, 48, 42),
  }
end

function NamingScreenLayout.contains(region, x, y)
  if region == nil or region.width <= 0 or region.height <= 0 then
    return false
  end
  return LayoutGeometry.containsPoint(region, x, y)
end

return NamingScreenLayout
