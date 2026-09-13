-- Draws a resolved field-menu presentation snapshot. It neither reads item
-- result values nor decides cancellation policy; those stay in the controller
-- and script task respectively.

local FieldMenuTheme = require("libs.hgss.src.ui.FieldMenuTheme")

---@class FieldMenuRenderer
---@field _graphics love.graphics
---@field _theme FieldMenuTheme
local FieldMenuRenderer = {}
FieldMenuRenderer.__index = FieldMenuRenderer

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4])
end

local function intersects(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function assertPresentation(presentation)
  assert(type(presentation) == "table" and type(presentation.status) == "table", "field menu renderer requires status")
  local status = presentation.status
  assert(type(status.selectedIndex) == "number", "field menu status requires a selected index")
  local layout = presentation.layout
  assert(
    type(layout) == "table" and layout.frame and layout.scrollViewport,
    "field menu renderer requires a resolved layout"
  )
  assert(
    type(layout.itemCount) == "number"
      and layout.itemCount % 1 == 0
      and layout.itemCount >= 0
      and type(layout.itemRects) == "table"
      and type(layout.itemTexts) == "table",
    "resolved layout requires item geometry and text"
  )
  assert(
    status.selectedIndex % 1 == 0 and status.selectedIndex >= 0 and status.selectedIndex < layout.itemCount,
    "field menu selected index is outside the resolved layout"
  )
  return status, layout
end

---@param opts { graphics?: love.graphics, theme?: FieldMenuTheme }?
---@return FieldMenuRenderer
function FieldMenuRenderer.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "field menu renderer options must be a table")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.print and graphics.polygon,
    "FieldMenuRenderer requires love.graphics"
  )
  assert(
    graphics.getColor and graphics.setColor and graphics.getScissor and graphics.setScissor,
    "FieldMenuRenderer requires graphics state access"
  )
  local theme = opts.theme or FieldMenuTheme
  assert(type(theme) == "table" and type(theme.colors) == "table", "field menu renderer requires a theme")
  return setmetatable({ _graphics = graphics, _theme = theme }, FieldMenuRenderer)
end

function FieldMenuRenderer:_drawFrame(layout)
  local graphics = self._graphics
  setColor(graphics, self._theme.colors.fill)
  graphics.rectangle("fill", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
  setColor(graphics, self._theme.colors.border)
  graphics.rectangle("line", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
end

function FieldMenuRenderer:_drawItems(status, layout)
  local graphics = self._graphics
  local viewport = layout.scrollViewport
  graphics.setScissor(viewport.x, viewport.y, viewport.width, viewport.height)
  for itemIndex = 0, layout.itemCount - 1 do
    local itemRect = assert(layout.itemRects[itemIndex], "resolved layout item geometry is missing")
    if intersects(itemRect, viewport) then
      if itemIndex == status.selectedIndex then
        setColor(graphics, self._theme.colors.selected)
        graphics.rectangle("fill", itemRect.x, itemRect.y, itemRect.width, itemRect.height)
        setColor(graphics, self._theme.colors.cursor)
        graphics.polygon(
          "fill",
          itemRect.x + 3,
          itemRect.y + itemRect.height / 2,
          itemRect.x + 8,
          itemRect.y + 4,
          itemRect.x + 8,
          itemRect.y + itemRect.height - 4
        )
      end
      setColor(graphics, self._theme.colors.text)
      graphics.print(
        assert(layout.itemTexts[itemIndex], "resolved layout item text is missing"),
        itemRect.x + self._theme.textInsetX,
        itemRect.y + self._theme.textInsetY
      )
    end
  end
  graphics.setScissor()
end

function FieldMenuRenderer:_drawScrollIndicators(layout)
  if layout.maxScrollOffset <= 0 then
    return
  end
  local graphics = self._graphics
  local viewport = layout.scrollViewport
  setColor(graphics, self._theme.colors.cursor)
  if layout.scrollOffset > 0 then
    graphics.polygon(
      "fill",
      viewport.x + viewport.width - 10,
      viewport.y + 7,
      viewport.x + viewport.width - 4,
      viewport.y + 7,
      viewport.x + viewport.width - 7,
      viewport.y + 2
    )
  end
  if layout.scrollOffset < layout.maxScrollOffset then
    graphics.polygon(
      "fill",
      viewport.x + viewport.width - 10,
      viewport.y + viewport.height - 7,
      viewport.x + viewport.width - 4,
      viewport.y + viewport.height - 7,
      viewport.x + viewport.width - 7,
      viewport.y + viewport.height - 2
    )
  end
end

function FieldMenuRenderer:_drawCancel(layout)
  if not layout.cancelRect then
    return
  end
  local graphics = self._graphics
  local rect = layout.cancelRect
  setColor(graphics, self._theme.colors.cancel)
  graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
  graphics.print("Cancel", rect.x + self._theme.textInsetX, rect.y + self._theme.textInsetY)
end

-- Draws one active menu from an immutable presentation snapshot. The renderer
-- does not resolve text, reconstruct interaction state, or mutate the snapshot.

---@param presentation { status: { selectedIndex: integer }, layout: table<string, unknown> }
function FieldMenuRenderer:draw(presentation)
  local status, layout = assertPresentation(presentation)
  local graphics = self._graphics
  local color = { graphics.getColor() }
  local scissor = { graphics.getScissor() }
  local ok, err = pcall(function()
    self:_drawFrame(layout)
    self:_drawItems(status, layout)
    self:_drawScrollIndicators(layout)
    self:_drawCancel(layout)
  end)
  graphics.setColor(color[1], color[2], color[3], color[4])
  if scissor[1] then
    graphics.setScissor(scissor[1], scissor[2], scissor[3], scissor[4])
  else
    graphics.setScissor()
  end
  if not ok then
    error(err)
  end
end

return FieldMenuRenderer
