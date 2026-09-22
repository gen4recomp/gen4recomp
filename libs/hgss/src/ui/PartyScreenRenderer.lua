-- The party-screen renderer: draws one controller presentation snapshot
-- through the resolved layout. Draw order is frame, slot surfaces, icons,
-- text/HP/status, cursor/focus, then the action overlay. Occupied slots
-- show icon, display name, level, gender, HP values with the source-threshold
-- HP bar, and the status code; empty slots paint a dim surface only;
-- ineligible slots keep their icon under dimmed chrome. The renderer owns
-- no selection, layout, or icon-selection policy and never decodes source
-- graphics: quads arrive through the icon provider.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class PartyScreenRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown> the borrowed generated-font collaborator
local PartyScreenRenderer = {}
PartyScreenRenderer.__index = PartyScreenRenderer

-- The canonical generated-font line advance shared by every card row.
local LINE_ADVANCE = 16
-- A normal source icon region inside a compact card.
local ICON_REGION = 32
local ELLIPSIS = "…"

local COLORS = {
  frame = { 0.08, 0.08, 0.12, 1 },
  frameBorder = { 0.75, 0.75, 0.85, 1 },
  slot = { 0.16, 0.16, 0.22, 1 },
  slotLead = { 0.2, 0.2, 0.28, 1 },
  slotEmpty = { 0.1, 0.1, 0.14, 1 },
  text = { 0.95, 0.95, 0.95, 1 },
  textDim = { 0.55, 0.55, 0.6, 1 },
  cursor = { 0.95, 0.85, 0.3, 1 },
  switchSource = { 0.35, 0.8, 1, 1 },
  hpEmpty = { 0.25, 0.1, 0.1, 1 },
  hpFull = { 0.25, 0.85, 0.35, 1 },
  hpGreen = { 0.25, 0.85, 0.35, 1 },
  hpYellow = { 0.95, 0.85, 0.25, 1 },
  hpRed = { 0.9, 0.3, 0.25, 1 },
  hpFainted = { 0.3, 0.3, 0.35, 1 },
  overlayDim = { 0, 0, 0, 0.6 },
  overlayBox = { 0.12, 0.12, 0.18, 1 },
  overlaySelected = { 0.3, 0.3, 0.45, 1 },
}

local HP_ZONE_COLORS = {
  full = "hpFull",
  green = "hpGreen",
  yellow = "hpYellow",
  red = "hpRed",
  fainted = "hpFainted",
}

local GENDER_TEXT = { male = "M", female = "F", genderless = "" }

---@param opts { graphics?: love.graphics, text?: table<string, unknown> }?
---@return PartyScreenRenderer
function PartyScreenRenderer.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "party renderer options must be a table")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.draw and graphics.setColor,
    "PartyScreenRenderer requires love.graphics"
  )
  local text = assert(opts.text, "the party renderer requires the generated font")
  assert(
    type(text.drawText) == "function" and type(text.textWidth) == "function",
    "the party renderer borrows generated text drawing and measurement"
  )
  return setmetatable({ _graphics = graphics, _text = text }, PartyScreenRenderer)
end

-- Shortens a card string to a measured width with an ellipsis at UTF-8
-- glyph boundaries; strings that already fit return unchanged.
---@param text table<string, unknown> the borrowed generated-font collaborator
---@param value string
---@param maxWidth number
---@return string
local function truncateToWidth(text, value, maxWidth)
  local measure = assert(text.textWidth, "truncation measures through the generated font")
  if measure(text, value) <= maxWidth then
    return value
  end
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(value) do
    glyphs[#glyphs + 1] = glyph
  end
  for kept = #glyphs - 1, 0, -1 do
    local candidate = table.concat(glyphs, "", 1, kept) .. ELLIPSIS
    if measure(text, candidate) <= maxWidth then
      return candidate
    end
  end
  return ""
end

---@param graphics love.graphics
---@param color number[]
local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4])
end

---@param presentation table<string, unknown>
---@param record table<string, unknown>
---@return boolean
local function isDisabled(presentation, record)
  return presentation.mode == "select" and record.occupied and not record.eligible
end

-- Draws one occupied icon at its card region, constraining oversized
-- source art to the region through the shared logical clip without
-- changing the pane presentation scale.
---@param record table<string, unknown>
---@param region ScreenTopology.Rectangle the icon region in logical coordinates
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawIcon(record, region, icons, disabled)
  local graphics = self._graphics
  local iconImage = icons:image()
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(record.iconKey)
  assert(
    type(dims) == "table" and type(dims.width) == "number" and type(dims.height) == "number",
    "the icon provider reports image dimensions"
  )
  setColor(graphics, { 1, 1, 1, disabled and 0.45 or 1 })
  if dims.width > ICON_REGION or dims.height > ICON_REGION then
    LogicalSurface.clip(graphics, region, function()
      graphics.draw(iconImage, quad, region.x, region.y)
    end)
  else
    graphics.draw(iconImage, quad, region.x, region.y)
  end
end

---@param record table<string, unknown>
---@return string displayName
---@return integer level
---@return string gender
---@return string status
---@return integer currentHp
---@return integer maxHp
local function slotFacts(record)
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  local level = assert(record.level, "occupied slots carry a level")
  local gender = assert(record.gender, "occupied slots carry a gender")
  local status = assert(record.status, "occupied slots carry a status")
  local currentHp = assert(record.currentHp, "occupied slots carry current HP")
  local maxHp = assert(record.maxHp, "occupied slots carry max HP")
  assert(type(displayName) == "string", "the display name renders as text")
  return displayName, level, gender, status, currentHp, maxHp
end

---@param currentHp integer
---@param maxHp integer
---@return number fraction
local function hpFraction(currentHp, maxHp)
  local fraction = 0
  if maxHp > 0 then
    fraction = currentHp / maxHp
  end
  return fraction
end

-- Paints the HP bar trough and its zone-colored fill over one bar rect.
---@param bar ScreenTopology.Rectangle
---@param currentHp integer
---@param maxHp integer
function PartyScreenRenderer:_drawHpBar(bar, currentHp, maxHp)
  local graphics = self._graphics
  local fraction = hpFraction(currentHp, maxHp)
  setColor(graphics, COLORS.hpEmpty)
  graphics.rectangle("fill", bar.x, bar.y, bar.width, bar.height)
  if fraction > 0 then
    local zoneColor = assert(HP_ZONE_COLORS[PartyScreenTheme.hpZone(currentHp, maxHp)], "unknown HP zone")
    setColor(graphics, COLORS[zoneColor])
    graphics.rectangle("fill", bar.x, bar.y, bar.width * fraction, bar.height)
  end
end

-- Draws generated-font text in the slot color, dimmed for ineligible picks.
---@param value string
---@param x number
---@param y number
---@param disabled boolean
function PartyScreenRenderer:_drawSlotText(value, x, y, disabled)
  local graphics = self._graphics
  setColor(graphics, disabled and COLORS.textDim or COLORS.text)
  local text = self._text
  text.drawText(text, value, x, y)
end

-- One compact card: a source-sized icon, three generated-font text lines
-- with the HP bar, and no paint outside the card rectangle.
---@param record table<string, unknown>
---@param rect ScreenTopology.Rectangle
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawCompactSlot(record, rect, icons, disabled)
  local graphics = self._graphics
  if not record.occupied then
    setColor(graphics, COLORS.slotEmpty)
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    return
  end
  setColor(graphics, COLORS.slot)
  if record.slot == 0 then
    setColor(graphics, COLORS.slotLead)
  end
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  self:_drawIcon(record, { x = rect.x + 2, y = rect.y + 2, width = ICON_REGION, height = ICON_REGION }, icons, disabled)
  local displayName, level, gender, status, currentHp, maxHp = slotFacts(record)
  local secondLine = rect.y + 2 + LINE_ADVANCE
  local thirdLine = rect.y + 2 + LINE_ADVANCE * 2
  self:_drawSlotText(truncateToWidth(self._text, displayName, 86), rect.x + 36, rect.y + 2, disabled)
  self:_drawSlotText("Lv " .. level, rect.x + 36, secondLine, disabled)
  local genderText = GENDER_TEXT[gender]
  assert(genderText ~= nil, "unknown party gender " .. tostring(record.gender))
  if genderText ~= "" then
    local text = self._text
    self:_drawSlotText(genderText, rect.x + 120 - text.textWidth(text, genderText), secondLine, disabled)
  end
  self:_drawSlotText(string.format("HP %d/%d", currentHp, maxHp), rect.x + 36, thirdLine, disabled)
  local label = PartyScreenTheme.statusLabel(status)
  if label ~= nil then
    self:_drawSlotText(label, rect.x + 2, thirdLine, disabled)
  end
  self:_drawHpBar({ x = rect.x + 2, y = rect.y + 50, width = 118, height = 2 }, currentHp, maxHp)
end

---@param record table<string, unknown>
---@param rect ScreenTopology.Rectangle
---@param icons table<string, unknown>
---@param disabled boolean
function PartyScreenRenderer:_drawSlot(record, rect, icons, disabled)
  local graphics = self._graphics
  if not record.occupied then
    setColor(graphics, COLORS.slotEmpty)
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    return
  end
  setColor(graphics, COLORS.slot)
  if record.slot == 0 then
    setColor(graphics, COLORS.slotLead)
  end
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)

  local iconImage = icons:image()
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(record.iconKey)
  local iconX = rect.x + 6
  local iconY = rect.y + math.max(0, (rect.height - dims.height) / 2)
  setColor(graphics, { 1, 1, 1, disabled and 0.45 or 1 })
  graphics.draw(iconImage, quad, iconX, iconY)

  local displayName, level, gender, status, currentHp, maxHp = slotFacts(record)
  local textX = iconX + dims.width + 8
  local lineHeight = math.max(12, rect.height / 3)
  self:_drawSlotText(displayName, textX, rect.y + 2, disabled)
  self:_drawSlotText("Lv " .. level, textX, rect.y + 2 + lineHeight, disabled)
  local genderText = GENDER_TEXT[gender]
  assert(genderText ~= nil, "unknown party gender " .. tostring(record.gender))
  if genderText ~= "" then
    self:_drawSlotText(genderText, rect.x + rect.width - 20, rect.y + 2, disabled)
  end
  self:_drawSlotText(string.format("HP %d/%d", currentHp, maxHp), textX, rect.y + 2 + lineHeight * 2, disabled)
  local label = PartyScreenTheme.statusLabel(status)
  if label ~= nil then
    self:_drawSlotText(label, rect.x + rect.width - 44, rect.y + 2 + lineHeight, disabled)
  end

  self:_drawHpBar({
    x = textX,
    y = rect.y + rect.height - 10,
    width = math.max(0, rect.width - (textX - rect.x) - 8),
    height = 6,
  }, currentHp, maxHp)
end

---@param rect ScreenTopology.Rectangle
---@param label string
---@param selected boolean
function PartyScreenRenderer:_drawActionRow(rect, label, selected)
  local graphics = self._graphics
  setColor(graphics, selected and COLORS.overlaySelected or COLORS.overlayBox)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  self:_drawSlotText(label, rect.x + 8, rect.y + 4, false)
end

-- The footer band of the compact interface: the selected full name and
-- the cancel control when allowed. The name falls back to the cancel
-- return slot while the cursor rests on cancel.
---@param presentation table<string, unknown>
---@param layout table<string, unknown> the compact resolved geometry
function PartyScreenRenderer:_drawCompactFooter(presentation, layout)
  local graphics = self._graphics
  local cursorNode = presentation.cursorNode
  local named = cursorNode
  if named == "cancel" then
    named = 4
  end
  if type(named) == "number" then
    local record = assert(presentation.view.slots[named + 1], "the footer names a visible slot")
    if record.occupied then
      local displayName = assert(record.displayName, "occupied slots carry a display name")
      self:_drawSlotText(truncateToWidth(self._text, displayName, 184), layout.frame.x + 4, 172, false)
    end
  end
  if layout.cancelRect ~= nil then
    setColor(graphics, COLORS.slot)
    graphics.rectangle(
      "fill",
      layout.cancelRect.x,
      layout.cancelRect.y,
      layout.cancelRect.width,
      layout.cancelRect.height
    )
    self:_drawSlotText("Cancel", layout.cancelRect.x + 8, layout.cancelRect.y + 2, false)
  end
end

-- Draws one presentation snapshot through the resolved layout with quads
-- from the icon provider. A matched interface plan carries its canonical
-- content; a resolved layout draws directly. The caller owns the logical
-- boundary: all coordinates here are logical. A closed presentation is a
-- no-op. Restores the graphics color afterwards.
---@param presentation table<string, unknown>
---@param planOrLayout table<string, unknown> the matched plan or a resolved layout
---@param icons table<string, unknown>?
function PartyScreenRenderer:draw(presentation, planOrLayout, icons)
  assert(type(presentation) == "table", "the party renderer requires a presentation")
  assert(type(planOrLayout) == "table", "the party renderer requires a plan or resolved layout")
  local layout = planOrLayout
  if type(layout.panes) == "table" then
    layout = assert(layout.content, "the party plan carries its canonical content")
  end
  assert(type(layout.slotRects) == "table", "the party renderer requires a resolved layout")
  if not presentation.open then
    return
  end
  assert(
    type(presentation.view) == "table" and type(presentation.view.slots) == "table",
    "the presentation needs a view"
  )
  local compact = layout.compact == true
  local graphics = self._graphics
  local red, green, blue, alpha = 1, 1, 1, 1
  if graphics.getColor then
    red, green, blue, alpha = graphics.getColor()
  end
  local ok, err = pcall(function()
    setColor(graphics, COLORS.frame)
    graphics.rectangle("fill", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
    if not compact then
      setColor(graphics, COLORS.frameBorder)
      graphics.rectangle("line", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
    end
    for slot0 = 0, 5 do
      local record = assert(presentation.view.slots[slot0 + 1], "the view carries six slots")
      local rect = assert(layout.slotRects[slot0 + 1], "the layout carries six slot rectangles")
      if compact then
        self:_drawCompactSlot(
          record,
          rect,
          assert(icons, "occupied slots need the icon provider"),
          isDisabled(presentation, record)
        )
      else
        self:_drawSlot(
          record,
          rect,
          assert(icons, "occupied slots need the icon provider"),
          isDisabled(presentation, record)
        )
      end
    end
    if compact then
      self:_drawCompactFooter(presentation, layout)
    elseif layout.cancelRect ~= nil then
      setColor(graphics, COLORS.slot)
      graphics.rectangle(
        "fill",
        layout.cancelRect.x,
        layout.cancelRect.y,
        layout.cancelRect.width,
        layout.cancelRect.height
      )
      self:_drawSlotText("Cancel", layout.cancelRect.x + 8, layout.cancelRect.y + 4, false)
    end
    local cursorNode = presentation.cursorNode
    local cursorRect = nil
    if cursorNode == "cancel" then
      cursorRect = layout.cancelRect
    elseif type(cursorNode) == "number" then
      cursorRect = layout.slotRects[cursorNode + 1]
    end
    if cursorRect ~= nil then
      setColor(graphics, COLORS.cursor)
      graphics.rectangle("line", cursorRect.x + 1, cursorRect.y + 1, cursorRect.width - 2, cursorRect.height - 2)
    end
    if presentation.switchSource ~= nil then
      local sourceRect = layout.slotRects[presentation.switchSource + 1]
      if sourceRect ~= nil then
        setColor(graphics, COLORS.switchSource)
        graphics.rectangle("line", sourceRect.x + 2, sourceRect.y + 2, sourceRect.width - 4, sourceRect.height - 4)
      end
    end
    if presentation.action == "action_choice" then
      setColor(graphics, COLORS.overlayDim)
      graphics.rectangle("fill", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
      local selection = presentation.actionSelection or "switch"
      self:_drawActionRow(layout.actionRects.switch, "Switch", selection == "switch")
      self:_drawActionRow(layout.actionRects.cancel, "Cancel", selection == "cancel")
    end
  end)
  if graphics.setColor then
    graphics.setColor(red, green, blue, alpha)
  end
  if not ok then
    error(err, 0)
  end
end

return PartyScreenRenderer
