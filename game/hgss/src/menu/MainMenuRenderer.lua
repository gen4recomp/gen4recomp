-- Recomp-owned Main Menu presentation over the shared image-button chrome
-- and the generated field font. Launcher colors live here; the Oak
-- selector owns its own tone recipe separately.

local ImageButton = require("libs.ui.src.ImageButton")

---@class MainMenuRenderer
---@field text table<string, function>
---@field graphics love.graphics
---@field versionId string
---@field background number[]
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer
local INK = { 0.12, 0.18, 0.25, 1 }
local MUTED = { 0.3, 0.38, 0.42, 1 }
local ERROR_INK = { 0.65, 0.22, 0.22, 1 }
local MARK = { 0.85, 0.88, 0.9, 1 }
local MARK_EDGE = { 0.35, 0.4, 0.45, 1 }

local CARD_FACE = { 0xFB / 255, 0xFB / 255, 0xFB / 255, 1 }
local CARD_INNER_BORDER = { 0xA2 / 255, 0xE3 / 255, 0xDB / 255, 1 }
local CARD_BORDER = { 0x30 / 255, 0x49 / 255, 0x61 / 255, 1 }
local CARD_RIM = CARD_BORDER
local CARD_SELECTED_RIM = { 255 / 255, 58 / 255, 58 / 255, 1 }

local MAIN_MENU_BACKGROUNDS = {
  heartgold = { 0xFF / 255, 0xD6 / 255, 0x94 / 255 },
  soulsilver = { 0x61 / 255, 0x61 / 255, 0xFB / 255 },
}

local CARD_RADIUS = 6
local CARD_INNER_WIDTH = 2
local CARD_INSET = 10

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

local function byteRole(color)
  return { r = color[1] * 255, g = color[2] * 255, b = color[3] * 255 }
end

-- Role palettes for generated-font copy: the current foreground role colors
-- plus an explicit light shadow and a transparent background so the card
-- face stays visible beneath the glyph masks. All text draws at identity
-- tint through the palette path, never through modulated plain draws.
local function rolePalette(foreground)
  return {
    foreground = byteRole(foreground),
    shadow = { r = 140, g = 140, b = 140 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

local TEXT_PALETTE = rolePalette(INK)
local MUTED_PALETTE = rolePalette(MUTED)
local ERROR_PALETTE = rolePalette(ERROR_INK)

local function drawNoContent() end

local function drawCard(graphics, rect, scale, selected)
  local resolved =
    ImageButton.resolve({ rect = rect, scale = scale, cornerRadius = CARD_RADIUS, innerBorderWidth = CARD_INNER_WIDTH })
  local content = assert(resolved.contentRect)
  ImageButton.draw(graphics, resolved, {
    selected = selected,
    colors = {
      face = CARD_FACE,
      border = CARD_BORDER,
      rim = CARD_RIM,
      selectedRim = CARD_SELECTED_RIM,
      innerBorder = CARD_INNER_BORDER,
    },
    imageRect = { x = content.x, y = content.y, width = content.width, height = content.height },
    drawImage = drawNoContent,
  })
end

-- Selected rim ring around a save frame whose overflow child stays neutral.
-- The ring is the resolved rim rectangle minus the resolved inner-border
-- rectangle, so no selected fill is ever painted underneath the child
-- control. Rim/inner insets come from the shared resolve; only the
-- ring-minus-hole composition lives here.
---@param graphics love.graphics
---@param rect { x: number, y: number, width: number, height: number }
---@param scale number
local function drawFrameOutline(graphics, rect, scale)
  local resolved =
    ImageButton.resolve({ rect = rect, scale = scale, cornerRadius = CARD_RADIUS, innerBorderWidth = CARD_INNER_WIDTH })
  local rimCell = assert(resolved.rim, "resolved card rim is required")
  local innerCell = assert(resolved.innerBorder, "resolved card inner border is required")
  ---@cast rimCell { rect: { x: number, y: number, width: number, height: number } }
  ---@cast innerCell { rect: { x: number, y: number, width: number, height: number } }
  local rim, inner = rimCell.rect, innerCell.rect
  setColor(graphics, CARD_SELECTED_RIM)
  graphics.rectangle("fill", rim.x, rim.y, rim.width, inner.y - rim.y)
  graphics.rectangle("fill", rim.x, inner.y + inner.height, rim.width, rim.y + rim.height - inner.y - inner.height)
  graphics.rectangle("fill", rim.x, inner.y, inner.x - rim.x, inner.height)
  graphics.rectangle("fill", inner.x + inner.width, inner.y, rim.x + rim.width - inner.x - inner.width, inner.height)
end

local function drawPaletteText(graphics, text, value, x, y, scale, palette)
  graphics.setColor(1, 1, 1, 1)
  graphics.push()
  graphics.translate(x, y)
  graphics.scale(scale, scale)
  local ok, err = pcall(text.drawTextWithPalette, text, value, 0, 0, palette)
  graphics.pop()
  graphics.setColor(1, 1, 1, 1)
  if not ok then
    error(err, 0)
  end
end

local function cardTitle(item)
  if item.canContinue then
    return item.playerName or "Save unavailable"
  end
  return item.errorSummary or "Save unavailable"
end

-- Presentation-only ASCII casing: saved names and model values keep their
-- stored form; only the drawn copy is uppercased. Bytes without an ASCII
-- lowercase pair pass through unchanged.
local function displayUpper(value)
  return (value:gsub("[a-z]", function(c)
    return string.char(c:byte() - 32)
  end))
end

local function textScaleFor(uiScale)
  if uiScale == 1 then
    return 1
  end
  return math.min(3, uiScale + 1)
end

---@param options { text: table<string, function>, versionId: string, graphics?: love.graphics }
---@return MainMenuRenderer
function MainMenuRenderer.new(options)
  assert(type(options) == "table" and options.text, "Main Menu renderer requires FieldTextRenderer")
  local graphics = options.graphics or love.graphics
  ---@cast graphics love.graphics
  assert(graphics, "Main Menu renderer requires graphics")
  assert(type(options.text.drawTextWithPalette) == "function", "Main Menu renderer requires palette text drawing")
  local versionId =
    assert(type(options.versionId) == "string" and options.versionId, "Main Menu renderer requires a game version")
  local background = assert(
    MAIN_MENU_BACKGROUNDS[versionId],
    "Main Menu renderer does not support game version: " .. tostring(versionId)
  )
  return setmetatable({
    text = options.text,
    graphics = graphics,
    versionId = versionId,
    background = { background[1], background[2], background[3] },
  }, MainMenuRenderer)
end

---@param view table<string, unknown>
function MainMenuRenderer:draw(view)
  local graphics = self.graphics
  local layout = assert(view.layout)
  local text = self.text
  ---@type integer
  local scale = layout.uiScale or 1
  assert(type(scale) == "number" and scale == math.floor(scale) and scale >= 1, "Main Menu scale must be an integer")
  -- Generated-font glyph transform only; card geometry and padding stay on
  -- the layout integer scale so hit rectangles never move with typography.
  local textScale = textScaleFor(scale)

  local red, green, blue, alpha = graphics.getColor()
  local lineWidth = graphics.getLineWidth()
  local oldX, oldY, oldWidth, oldHeight = graphics.getScissor()
  local background = self.background
  local ok, err = xpcall(function()
    graphics.setColor(background[1], background[2], background[3], 1)
    graphics.clear(background[1], background[2], background[3], 1)

    local focus = assert(view.focus)
    local saves = assert(layout.saves)
    graphics.setScissor(saves.viewport.x, saves.viewport.y, saves.viewport.width, saves.viewport.height)
    if view.catalogError and view.catalogError ~= "" then
      local errorRect = assert(layout.catalogErrorRect)
      drawPaletteText(
        graphics,
        text,
        displayUpper("Save catalog unavailable"),
        errorRect.x + CARD_INSET * scale,
        errorRect.y + CARD_INSET * scale,
        textScale,
        ERROR_PALETTE
      )
    end
    for _, item in ipairs(assert(view.saves)) do
      local card = saves.cards[item.saveId or item.id]
      if card then
        local bodyFocused = focus.region == "saves"
          and focus.saveId == (item.saveId or item.id)
          and focus.lane == "body"
        local overflowFocused = focus.region == "saves"
          and focus.saveId == (item.saveId or item.id)
          and focus.lane == "overflow"
        drawCard(graphics, card.frame, scale, false)
        if bodyFocused then
          drawFrameOutline(graphics, card.frame, scale)
        end
        local pad = CARD_INSET * scale
        local headingY = card.frame.y + CARD_INSET * scale
        drawPaletteText(graphics, text, displayUpper("CONTINUE"), card.frame.x + pad, headingY, textScale, TEXT_PALETTE)
        if item.canContinue then
          drawPaletteText(
            graphics,
            text,
            displayUpper(cardTitle(item)),
            card.frame.x + pad,
            headingY + 20 * scale,
            textScale,
            TEXT_PALETTE
          )
          drawPaletteText(
            graphics,
            text,
            displayUpper(item.playTimeLabel or "0:00"),
            card.frame.x + pad,
            headingY + 40 * scale,
            textScale,
            MUTED_PALETTE
          )
        else
          drawPaletteText(
            graphics,
            text,
            displayUpper(cardTitle(item)),
            card.frame.x + pad,
            headingY + 20 * scale,
            textScale,
            ERROR_PALETTE
          )
        end
        if card.overflow then
          drawCard(graphics, card.overflow, scale, overflowFocused)
          drawPaletteText(
            graphics,
            text,
            "...",
            card.overflow.x + 3 * scale,
            card.overflow.y + 4 * scale,
            textScale,
            TEXT_PALETTE
          )
        end
      end
    end
    if oldX ~= nil then
      graphics.setScissor(oldX, oldY, oldWidth, oldHeight)
    else
      graphics.setScissor()
    end

    self:_drawScrollIndicators(layout)

    local globalFocus = view.focus.region == "global"
    local global = assert(layout.global)
    local newGame = assert(global.actions["new-game"])
    drawCard(graphics, newGame, scale, globalFocus)
    drawPaletteText(
      graphics,
      text,
      displayUpper("NEW GAME"),
      newGame.x + CARD_INSET * scale,
      newGame.y + 10 * scale,
      textScale,
      TEXT_PALETTE
    )

    if view.popup then
      local popup = assert(layout.popup)
      graphics.setColor(0, 0, 0, 0.45)
      graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
      drawCard(graphics, popup.box, scale, false)
      drawCard(graphics, popup.actions.delete, scale, true)
      drawPaletteText(
        graphics,
        text,
        displayUpper("Delete"),
        popup.actions.delete.x + 4 * scale,
        popup.actions.delete.y + 4 * scale,
        textScale,
        TEXT_PALETTE
      )
    end
    if view.confirmation then
      local confirmation = assert(layout.confirmation)
      graphics.setColor(0, 0, 0, 0.62)
      graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
      drawCard(graphics, confirmation.box, scale, false)
      drawPaletteText(
        graphics,
        text,
        displayUpper("Delete this save?"),
        confirmation.box.x + CARD_INSET * scale,
        confirmation.box.y + CARD_INSET * scale,
        textScale,
        TEXT_PALETTE
      )
      local cancelFocus = view.confirmation.focusedAction == "cancel"
      local deleteFocus = view.confirmation.focusedAction == "delete"
      drawCard(graphics, confirmation.cancel, scale, cancelFocus)
      drawCard(graphics, confirmation.delete, scale, deleteFocus)
      drawPaletteText(
        graphics,
        text,
        displayUpper("Cancel"),
        confirmation.cancel.x + 4 * scale,
        confirmation.cancel.y + 4 * scale,
        textScale,
        TEXT_PALETTE
      )
      drawPaletteText(
        graphics,
        text,
        displayUpper("Delete"),
        confirmation.delete.x + 4 * scale,
        confirmation.delete.y + 4 * scale,
        textScale,
        TEXT_PALETTE
      )
    end
  end, debug.traceback)
  if oldX ~= nil then
    graphics.setScissor(oldX, oldY, oldWidth, oldHeight)
  else
    graphics.setScissor()
  end
  graphics.setColor(red, green, blue, alpha)
  graphics.setLineWidth(lineWidth)
  if not ok then
    error(err, 0)
  end
end

---@param layout table<string, unknown>
function MainMenuRenderer:_drawScrollIndicators(layout)
  local saves = assert(layout.saves)
  local marks = saves.scrollIndicators
  if marks and marks.up then
    self:_drawScrollMark(marks.up, true)
  end
  if marks and marks.down then
    self:_drawScrollMark(marks.down, false)
  end
end

---@param rect table<string, number>
---@param isUp boolean
function MainMenuRenderer:_drawScrollMark(rect, isUp)
  local graphics = self.graphics
  setColor(graphics, MARK)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  setColor(graphics, MARK_EDGE)
  local middleX = rect.x + rect.width / 2
  if isUp then
    graphics.polygon(
      "fill",
      rect.x + 2,
      rect.y + rect.height - 2,
      middleX,
      rect.y + 2,
      rect.x + rect.width - 2,
      rect.y + rect.height - 2
    )
  else
    graphics.polygon(
      "fill",
      rect.x + 2,
      rect.y + 2,
      middleX,
      rect.y + rect.height - 2,
      rect.x + rect.width - 2,
      rect.y + 2
    )
  end
end

function MainMenuRenderer:dispose()
  if self.text and self.text.release then
    self.text:release()
  end
  self.text = nil
end

return MainMenuRenderer
