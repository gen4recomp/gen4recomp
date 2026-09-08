-- Pure host placement for the authentic 256 x 48 dialogue window. Local
-- geometry remains source-sized; only this record knows the host rectangle.
-- Source-local box/text/line metrics derive from FieldDialogueTheme, the
-- canonical HGSS geometry owner; this module only maps them into host bounds.

local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")

local Layout = {}

---@class DialoguePresentationLayout.Rect
---@field x number
---@field y number
---@field width number
---@field height number

---@class DialoguePresentationLayout.Presentation
---@field bounds DialoguePresentationLayout.Rect
---@field origin { x: number, y: number }
---@field scale number
---@field outerRect DialoguePresentationLayout.Rect
---@field box DialoguePresentationLayout.Rect
---@field text DialoguePresentationLayout.Rect
---@field cursor DialoguePresentationLayout.Rect
---@field lineHeight number

local WIDTH = FieldDialogueTheme.referenceWidth
local HEIGHT = 48
local SOURCE_HEIGHT = FieldDialogueTheme.referenceHeight
-- The dialogue window strip is the bottom 48 pixels of the 256x192 source
-- canvas, so source-relative local Y is converted by subtracting 144.
local SOURCE_WINDOW_Y = SOURCE_HEIGHT - HEIGHT
local BOX = {
  x = FieldDialogueTheme.box.x,
  y = FieldDialogueTheme.box.y - SOURCE_WINDOW_Y,
  width = FieldDialogueTheme.box.width,
  height = FieldDialogueTheme.box.height,
}
local TEXT = {
  x = FieldDialogueTheme.box.x + FieldDialogueTheme.textInsetX,
  y = FieldDialogueTheme.box.y - SOURCE_WINDOW_Y + FieldDialogueTheme.textInsetY,
  width = FieldDialogueTheme.textWidth,
  height = FieldDialogueTheme.textHeight,
}
local LINE_HEIGHT = FieldDialogueTheme.lineHeight
local EPSILON = 1e-9

local function finitePositive(value, name)
  assert(
    type(value) == "number" and value > 0 and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be a finite positive number"
  )
end

local function finite(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite"
  )
end

local function validateBounds(bounds)
  assert(type(bounds) == "table", "dialogue presentation bounds must be a table")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    finite(bounds[key], "dialogue presentation bounds." .. key)
  end
  finitePositive(bounds.width, "dialogue presentation bounds.width")
  finitePositive(bounds.height, "dialogue presentation bounds.height")
end

local function validateCursorPlacement(placement)
  assert(type(placement) == "table", "dialogue cursor placement must be a rectangle")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    finite(placement[key], "dialogue cursor placement." .. key)
  end
  finitePositive(placement.width, "dialogue cursor placement.width")
  finitePositive(placement.height, "dialogue cursor placement.height")
  assert(placement.x >= 0 and placement.y >= SOURCE_WINDOW_Y, "dialogue cursor placement is outside the source window")
  assert(
    placement.x + placement.width <= WIDTH and placement.y + placement.height <= SOURCE_HEIGHT,
    "dialogue cursor placement is outside the source canvas"
  )
end

---@param bounds { x: number, y: number, width: number, height: number }
---@param options { scale?: number, maxScale?: number, cursorPlacement: { x: number, y: number, width: number, height: number } }?
---@return DialoguePresentationLayout.Presentation
function Layout.compute(bounds, options)
  validateBounds(bounds)
  assert(type(options) == "table", "dialogue presentation options must be a table")
  if options.scale ~= nil then
    finitePositive(options.scale, "dialogue presentation scale")
  end
  if options.maxScale ~= nil then
    finitePositive(options.maxScale, "dialogue presentation maxScale")
  end
  local scale = options.scale or math.min(bounds.width / WIDTH, bounds.height / HEIGHT, options.maxScale or math.huge)
  assert(scale > 0, "dialogue presentation does not fit its bounds")
  assert(
    WIDTH * scale <= bounds.width + EPSILON and HEIGHT * scale <= bounds.height + EPSILON,
    "dialogue presentation scale does not fit its bounds"
  )
  local origin = {
    x = bounds.x + (bounds.width - WIDTH * scale) / 2,
    y = bounds.y + bounds.height - HEIGHT * scale,
  }
  local cursorPlacement = assert(options.cursorPlacement, "dialogue presentation requires generated cursor placement")
  validateCursorPlacement(cursorPlacement)
  local cursor = {
    x = cursorPlacement.x,
    y = cursorPlacement.y - SOURCE_WINDOW_Y,
    width = cursorPlacement.width,
    height = cursorPlacement.height,
  }
  -- The text pen starts at the window content origin; the continuation
  -- cursor is placed outside the content window, never clipped inside it.
  local text = { x = TEXT.x, y = TEXT.y, width = TEXT.width, height = TEXT.height }
  return {
    bounds = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height },
    origin = origin,
    scale = scale,
    outerRect = { x = origin.x, y = origin.y, width = WIDTH * scale, height = HEIGHT * scale },
    box = { x = BOX.x, y = BOX.y, width = BOX.width, height = BOX.height },
    text = text,
    cursor = cursor,
    lineHeight = LINE_HEIGHT,
  }
end

---@param presentation DialoguePresentationLayout.Presentation
function Layout.validate(presentation)
  assert(type(presentation) == "table", "dialogue presentation must be a table")
  validateBounds(presentation.bounds)
  assert(
    type(presentation.origin) == "table"
      and type(presentation.origin.x) == "number"
      and type(presentation.origin.y) == "number",
    "dialogue presentation requires an origin"
  )
  finite(presentation.origin.x, "dialogue presentation origin.x")
  finite(presentation.origin.y, "dialogue presentation origin.y")
  finitePositive(presentation.scale, "dialogue presentation scale")
  assert(type(presentation.outerRect) == "table", "dialogue presentation requires an outer rectangle")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    finite(presentation.outerRect[key], "dialogue presentation outerRect." .. key)
  end
  assert(
    presentation.outerRect.width > 0 and presentation.outerRect.height > 0,
    "dialogue presentation outer rectangle must be positive"
  )
  assert(
    math.abs(presentation.outerRect.x - presentation.origin.x) <= EPSILON
      and math.abs(presentation.outerRect.y - presentation.origin.y) <= EPSILON
      and math.abs(presentation.outerRect.width - WIDTH * presentation.scale) <= EPSILON
      and math.abs(presentation.outerRect.height - HEIGHT * presentation.scale) <= EPSILON,
    "dialogue presentation has inconsistent outer rectangle"
  )
  local function requireRect(rect, name, expected)
    assert(type(rect) == "table", "dialogue presentation requires " .. name)
    for _, key in ipairs({ "x", "y", "width", "height" }) do
      finite(rect[key], "dialogue presentation " .. name .. "." .. key)
    end
    if expected then
      for _, key in ipairs({ "x", "y", "width", "height" }) do
        assert(rect[key] == expected[key], "dialogue presentation has invalid " .. name)
      end
    end
    return rect
  end
  requireRect(presentation.box, "box", BOX)
  -- Text is the canonical theme content rect. Cursor geometry is supplied
  -- by generated field UI and has already been transformed by compute().
  requireRect(presentation.text, "text box", TEXT)
  local cursor = requireRect(presentation.cursor, "cursor")
  assert(cursor.x >= 0 and cursor.y >= 0, "dialogue cursor must be inside the local strip")
  assert(
    cursor.x + cursor.width <= WIDTH and cursor.y + cursor.height <= HEIGHT,
    "dialogue cursor must be inside the local strip"
  )
  assert(presentation.lineHeight == LINE_HEIGHT, "dialogue presentation has invalid line height")
end

return Layout
