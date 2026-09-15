-- HGSS naming surface renderer using geometric controls and shared field text.

local PixelScale = require("libs.ui.src.PixelScale")

local NamingScreenRenderer = {}

---@class NamingScreenRendererOptions
---@field graphics table<string, function>
---@field text table<string, function>
---@field subjectImages table<string, unknown>?

---@class NamingScreenRenderer
---@field new fun(options: NamingScreenRendererOptions): NamingScreenRenderer
---@field draw fun(self: NamingScreenRenderer, view: NamingScreenSnapshot, layout: NamingScreenLayoutResult)
---@field dispose fun(self: NamingScreenRenderer)
NamingScreenRenderer.__index = NamingScreenRenderer

---@param options { graphics: table<string, function>, text: table<string, function>, subjectImages?: table<string, unknown> }
---@return NamingScreenRenderer
function NamingScreenRenderer.new(options)
  assert(type(options) == "table" and options.graphics and options.text, "naming renderer requires graphics and text")
  assert(type(options.text.drawText) == "function", "naming renderer requires FieldTextRenderer.drawText")
  ---@type NamingScreenRenderer
  local renderer = setmetatable(
    { graphics = options.graphics, text = options.text, subjectImages = options.subjectImages or {}, released = false },
    NamingScreenRenderer
  )
  return renderer
end

local function center(text, region, measure)
  return PixelScale.snapLogical(region.x + (region.width - measure(text)) / 2)
end

function NamingScreenRenderer:draw(view, layout)
  assert(not self.released, "naming renderer is released")
  assert(type(view) == "table" and type(layout) == "table", "naming draw requires view and layout")
  local g = self.graphics
  local placement = assert(layout.placement, "naming layout placement is required")
  assert(
    placement.scale > 0 and placement.scale == math.floor(placement.scale),
    "naming placement scale must be a positive integer"
  )
  g.push()
  g.translate(placement.frame.x, placement.frame.y)
  g.scale(placement.scale, placement.scale)
  g.setColor(0.10, 0.14, 0.25, 1)
  g.rectangle("fill", 0, 0, 256, 192)
  g.setColor(0.80, 0.88, 0.98, 1)
  g.rectangle("fill", layout.nameSlots.x, layout.nameSlots.y, layout.nameSlots.width, layout.nameSlots.height)
  g.setColor(0.04, 0.06, 0.12, 1)
  g.rectangle("line", layout.nameSlots.x, layout.nameSlots.y, layout.nameSlots.width, layout.nameSlots.height)
  local text = view.text or ""
  self.text:drawText(
    text,
    center(text, layout.nameSlots, function(value)
      return self.text.textWidth and self.text:textWidth(value) or 0
    end),
    layout.nameSlots.y + 4
  )
  local subject = view.subject or {}
  local image = self.subjectImages[subject.gender == 1 and "female" or "male"]
  if image and g.draw then
    g.setColor(1, 1, 1, 1)
    g.draw(image, layout.subject.x, layout.subject.y)
  end
  g.setColor(0.16, 0.22, 0.36, 1)
  g.rectangle("fill", layout.keyboard.x, layout.keyboard.y, layout.keyboard.width, layout.keyboard.height)
  for row = 1, 6 do
    for column = 1, 13 do
      local cell = view.grid[row][column]
      local cellRect = layout.cells[row][column]
      local selected = view.cursor.row == row and view.cursor.column == column
      g.setColor(selected and 0.96 or 0.28, selected and 0.82 or 0.36, selected and 0.40 or 0.48, 1)
      g.rectangle("line", cellRect.x, cellRect.y, cellRect.width, cellRect.height)
      if cell.kind == "glyph" then
        local glyphWidth = self.text.textWidth and self.text:textWidth(cell.glyph) or 0
        g.setColor(1, 1, 1, 1)
        self.text:drawText(cell.glyph, cellRect.x + (cellRect.width - glyphWidth) / 2, cellRect.y + 2)
      end
    end
  end
  local labels = { upper = "Upper", lower = "Lower", symbols = "Symbols", back = "Back", ok = "OK" }
  for id, region in pairs(layout.controls) do
    local label = labels[id]
    local labelWidth = self.text.textWidth and self.text:textWidth(label) or 0
    g.setColor(1, 1, 1, 1)
    self.text:drawText(label, region.x + (region.width - labelWidth) / 2, region.y + 2)
  end
  g.pop()
end

function NamingScreenRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  self.subjectImages = {}
end

NamingScreenRenderer.release = NamingScreenRenderer.dispose
return NamingScreenRenderer
