-- The party-screen renderer: draws one controller presentation snapshot
-- through the resolved layout. Draw order is frame, slot surfaces, icons,
-- text/HP/status, cursor/focus, then the action overlay. Occupied slots
-- show icon, display name, level, gender, HP values with the source-threshold
-- HP bar, and the status code; empty slots paint a dim surface only;
-- ineligible slots keep their icon under dimmed chrome. The renderer owns
-- no selection, layout, or icon-selection policy and never decodes source
-- graphics: quads arrive through the icon provider.

local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")

---@class PartyScreenRenderer
---@field _graphics love.Graphics|love.graphics
local PartyScreenRenderer = {}
PartyScreenRenderer.__index = PartyScreenRenderer

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

---@param opts { graphics?: love.Graphics|love.graphics }?
---@return PartyScreenRenderer
function PartyScreenRenderer.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "party renderer options must be a table")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    graphics and graphics.rectangle and graphics.print and graphics.draw and graphics.setColor,
    "PartyScreenRenderer requires love.graphics"
  )
  return setmetatable({ _graphics = graphics }, PartyScreenRenderer)
end

---@param graphics love.Graphics|love.graphics
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
  local textColor = disabled and COLORS.textDim or COLORS.text

  local iconImage = icons:image()
  local iconKey = assert(record.iconKey, "occupied slots carry an icon key")
  local quad = icons:quadFor(iconKey)
  local dims = icons:dimensions(record.iconKey)
  local iconX = rect.x + 6
  local iconY = rect.y + math.max(0, (rect.height - dims.height) / 2)
  setColor(graphics, { 1, 1, 1, disabled and 0.45 or 1 })
  graphics.draw(iconImage, quad, iconX, iconY)

  local textX = iconX + dims.width + 8
  local lineHeight = math.max(12, rect.height / 3)
  setColor(graphics, textColor)
  local displayName = assert(record.displayName, "occupied slots carry a display name")
  local level = assert(record.level, "occupied slots carry a level")
  local gender = assert(record.gender, "occupied slots carry a gender")
  local status = assert(record.status, "occupied slots carry a status")
  graphics.print(displayName, textX, rect.y + 2)
  graphics.print("Lv " .. level, textX, rect.y + 2 + lineHeight)
  local genderText = GENDER_TEXT[gender]
  assert(genderText ~= nil, "unknown party gender " .. tostring(record.gender))
  if genderText ~= "" then
    graphics.print(genderText, rect.x + rect.width - 20, rect.y + 2)
  end
  local currentHp = assert(record.currentHp, "occupied slots carry current HP")
  local maxHp = assert(record.maxHp, "occupied slots carry max HP")
  graphics.print(string.format("HP %d/%d", currentHp, maxHp), textX, rect.y + 2 + lineHeight * 2)
  local label = PartyScreenTheme.statusLabel(status)
  if label ~= nil then
    graphics.print(label, rect.x + rect.width - 44, rect.y + 2 + lineHeight)
  end

  local zone = PartyScreenTheme.hpZone(currentHp, maxHp)
  local bar =
    { x = textX, y = rect.y + rect.height - 10, width = math.max(0, rect.width - (textX - rect.x) - 8), height = 6 }
  setColor(graphics, COLORS.hpEmpty)
  graphics.rectangle("fill", bar.x, bar.y, bar.width, bar.height)
  local fraction = 0
  if maxHp > 0 then
    fraction = currentHp / maxHp
  end
  if fraction > 0 then
    local zoneColor = assert(HP_ZONE_COLORS[zone], "unknown HP zone " .. zone)
    setColor(graphics, COLORS[zoneColor])
    graphics.rectangle("fill", bar.x, bar.y, bar.width * fraction, bar.height)
  end
end

---@param rect ScreenTopology.Rectangle
---@param label string
---@param selected boolean
function PartyScreenRenderer:_drawActionRow(rect, label, selected)
  local graphics = self._graphics
  setColor(graphics, selected and COLORS.overlaySelected or COLORS.overlayBox)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  setColor(graphics, COLORS.text)
  graphics.print(label, rect.x + 8, rect.y + 4)
end

-- Draws one presentation snapshot through the resolved layout with quads
-- from the icon provider. A closed presentation is a no-op. Restores the
-- graphics color afterwards.
---@param presentation table<string, unknown>
---@param layout table<string, unknown>
---@param icons table<string, unknown>?
function PartyScreenRenderer:draw(presentation, layout, icons)
  assert(type(presentation) == "table", "the party renderer requires a presentation")
  assert(type(layout) == "table" and type(layout.slotRects) == "table", "the party renderer requires a resolved layout")
  if not presentation.open then
    return
  end
  assert(
    type(presentation.view) == "table" and type(presentation.view.slots) == "table",
    "the presentation needs a view"
  )
  local graphics = self._graphics
  local red, green, blue, alpha = 1, 1, 1, 1
  if graphics.getColor then
    red, green, blue, alpha = graphics.getColor()
  end
  local ok, err = pcall(function()
    setColor(graphics, COLORS.frame)
    graphics.rectangle("fill", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
    setColor(graphics, COLORS.frameBorder)
    graphics.rectangle("line", layout.frame.x, layout.frame.y, layout.frame.width, layout.frame.height)
    for slot0 = 0, 5 do
      local record = assert(presentation.view.slots[slot0 + 1], "the view carries six slots")
      local rect = assert(layout.slotRects[slot0 + 1], "the layout carries six slot rectangles")
      self:_drawSlot(
        record,
        rect,
        assert(icons, "occupied slots need the icon provider"),
        isDisabled(presentation, record)
      )
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
      setColor(graphics, COLORS.text)
      graphics.print("Cancel", layout.cancelRect.x + 8, layout.cancelRect.y + 4)
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
      graphics.rectangle("line", cursorRect.x, cursorRect.y, cursorRect.width, cursorRect.height)
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
