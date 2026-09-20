-- Recomp-owned Main Menu presentation over the shared image-button chrome
-- and the generated field font. All drawing is logical pixels inside one
-- root placement: text, chrome and hit bounds share the transform, and no
-- inner helper multiplies by a presentation scale. Launcher colors live
-- here; the Oak selector owns its own tone recipe separately.

local ImageButton = require("libs.ui.src.ImageButton")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class MainMenuRenderer
---@field text table<string, function>
---@field graphics love.graphics
---@field versionId string
---@field background number[]
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer
local INK = { 0.12, 0.18, 0.25, 1 }
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
local ERROR_PALETTE = rolePalette(ERROR_INK)

-- Retail profile-information palette sampled from the reference card: bright
-- blue copy with a dark blue shadow over a transparent background so the
-- card face stays visible beneath the glyph masks. Only the three profile
-- rows use it; headings, errors, and popups keep their existing palettes.
local PROFILE_INFO_PALETTE = {
  foreground = { r = 0, g = 113, b = 251 },
  shadow = { r = 0, g = 81, b = 251 },
  background = { r = 0, g = 0, b = 0, a = 0 },
}

-- Centered profile-block share of the Continue body width.
local PROFILE_BLOCK_WIDTH_FRACTION = 0.62

-- Generated font defs carry their ROM line advance (font-0: 16). Headless
-- text doubles carry no fontDef, so fall back to that same advance rather
-- than inventing per-scale offsets; every use below is logical units.
local FALLBACK_LINE_HEIGHT = 16

local function drawNoContent() end

local function drawColoredCard(graphics, rect, selected, colors)
  local resolved =
    ImageButton.resolve({ rect = rect, scale = 1, cornerRadius = CARD_RADIUS, innerBorderWidth = CARD_INNER_WIDTH })
  local content = assert(resolved.contentRect)
  ImageButton.draw(graphics, resolved, {
    selected = selected,
    colors = colors,
    imageRect = { x = content.x, y = content.y, width = content.width, height = content.height },
    drawImage = drawNoContent,
  })
end

local function drawCard(graphics, rect, selected)
  drawColoredCard(graphics, rect, selected, {
    face = CARD_FACE,
    border = CARD_BORDER,
    rim = CARD_RIM,
    selectedRim = CARD_SELECTED_RIM,
    innerBorder = CARD_INNER_BORDER,
  })
end

-- Inset actions nested inside another card keep the card chrome but paint
-- the inner border in the face color so no contrasting ring separates the
-- nested control from its parent card.
local function drawInset(graphics, rect, selected)
  drawColoredCard(graphics, rect, selected, {
    face = CARD_FACE,
    border = CARD_BORDER,
    rim = CARD_RIM,
    selectedRim = CARD_SELECTED_RIM,
    innerBorder = CARD_FACE,
  })
end

local function drawPaletteText(graphics, text, value, x, y, palette)
  graphics.setColor(1, 1, 1, 1)
  local ok, err = pcall(text.drawTextWithPalette, text, value, x, y, palette)
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

-- Continue-card profile rows in one centered block: labels share the block
-- left edge while values right-align to the block right edge through the
-- generated-font measure. The vertical area below the heading splits into
-- three equal bands with each row vertically centered by the canonical
-- font line advance. The badge count is presentation-only.
---@param graphics love.graphics
---@param text table<string, function>
---@param body { x: number, y: number, width: number, height: number }
---@param regionTop number
---@param lineHeight number
---@param playerName string
---@param playTimeLabel string
local function drawProfileRows(graphics, text, body, regionTop, lineHeight, playerName, playTimeLabel)
  local blockWidth = body.width * PROFILE_BLOCK_WIDTH_FRACTION
  local blockLeft = body.x + (body.width - blockWidth) / 2
  local blockRight = blockLeft + blockWidth
  local bandHeight = (body.y + body.height - regionTop) / 3
  local rows = {
    { label = "PLAYER", value = playerName },
    { label = "TIME", value = playTimeLabel },
    { label = "BADGES", value = "0" },
  }
  for index, row in ipairs(rows) do
    local y = regionTop + (index - 1) * bandHeight + (bandHeight - lineHeight) / 2
    local valueWidth = text:textWidth(row.value)
    drawPaletteText(graphics, text, row.label, blockLeft, y, PROFILE_INFO_PALETTE)
    drawPaletteText(graphics, text, row.value, blockRight - valueWidth, y, PROFILE_INFO_PALETTE)
  end
end

-- Presentation-only ASCII casing: saved names and model values keep their
-- stored form; only the drawn copy is uppercased. Bytes without an ASCII
-- lowercase pair pass through unchanged.
local function displayUpper(value)
  return (value:gsub("[a-z]", function(c)
    return string.char(c:byte() - 32)
  end))
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
---@param plan ApplicationPlan the resolved interface plan carrying the content pane
function MainMenuRenderer:draw(view, plan)
  local graphics = self.graphics
  local layout = assert(view.layout)
  local shaped = layout --[[@as { viewport: table<string, number>, saves: table<string, unknown>, global: table<string, unknown> }]]
  local panes = assert(plan.panes, "Main Menu draws its content pane")
  local pane = assert(panes[1], "Main Menu draws its content pane")
  local placement = assert(pane.placement, "the menu pane carries its placement")
  local text = self.text
  local shapedText = text --[[@as { fontDef: FieldFontDef|nil }]]
  local fontDef = shapedText.fontDef
  local lineHeight = (fontDef and fontDef.lineHeight) or FALLBACK_LINE_HEIGHT

  local red, green, blue, alpha = graphics.getColor()
  local lineWidth = graphics.getLineWidth()
  local background = self.background
  LogicalSurface.draw(graphics, placement, function()
    local ok, err = xpcall(function()
      -- The menu owns exactly its logical viewport: fill it, never clear
      -- an unrelated host surface.
      local viewport = shaped.viewport
      graphics.setColor(background[1], background[2], background[3], 1)
      graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)

      local focus = assert(view.focus)
      local saves = assert(shaped.saves)
      local shapedSaves = saves --[[@as { viewport: table<string, number>, cards: table<string, table<string, unknown>> }]]
      LogicalSurface.clip(graphics, shapedSaves.viewport, function()
        if view.catalogError and view.catalogError ~= "" then
          local errorRect = assert(layout.catalogErrorRect)
          local shapedError = errorRect --[[@as table<string, number>]]
          drawPaletteText(
            graphics,
            text,
            displayUpper("Save catalog unavailable"),
            shapedError.x + CARD_INSET,
            shapedError.y + CARD_INSET,
            ERROR_PALETTE
          )
        end
        for _, item in ipairs(assert(view.saves)) do
          local card = shapedSaves.cards[item.saveId or item.id]
          if card then
            local shapedCard = card --[[@as { frame: table<string, number>, body: table<string, number>, overflow: table<string, number>|nil }]]
            local bodyFocused = focus.region == "saves"
              and focus.saveId == (item.saveId or item.id)
              and focus.lane == "body"
            local overflowFocused = focus.region == "saves"
              and focus.saveId == (item.saveId or item.id)
              and focus.lane == "overflow"
            -- Body focus selects the outer card through the shared rounded rim;
            -- overflow focus leaves the parent neutral for its own inset chrome.
            drawCard(graphics, shapedCard.frame, bodyFocused)
            local headingY = shapedCard.frame.y + CARD_INSET
            drawPaletteText(
              graphics,
              text,
              displayUpper("CONTINUE"),
              shapedCard.frame.x + CARD_INSET,
              headingY,
              TEXT_PALETTE
            )
            if item.canContinue then
              -- Stored values keep their exact form; only headings and labels
              -- are uppercased presentation copy. The badge count is the only
              -- count current gameplay supports, rendered without a save field.
              drawProfileRows(
                graphics,
                text,
                shapedCard.body,
                headingY + lineHeight,
                lineHeight,
                item.playerName or "Save unavailable",
                item.playTimeLabel or "0:00"
              )
            else
              drawPaletteText(
                graphics,
                text,
                displayUpper(cardTitle(item)),
                shapedCard.frame.x + CARD_INSET,
                headingY + 20,
                ERROR_PALETTE
              )
            end
            if shapedCard.overflow then
              drawInset(graphics, shapedCard.overflow, overflowFocused)
              drawPaletteText(graphics, text, "...", shapedCard.overflow.x + 3, shapedCard.overflow.y + 4, TEXT_PALETTE)
            end
          end
        end
      end)

      self:_drawScrollIndicators(layout)

      local globalFocus = view.focus.region == "global"
      local global = assert(shaped.global)
      local shapedGlobal = global --[[@as { actions: table<string, table<string, number>> }]]
      local newGame = assert(shapedGlobal.actions["new-game"])
      drawCard(graphics, newGame, globalFocus)
      drawPaletteText(graphics, text, displayUpper("NEW GAME"), newGame.x + CARD_INSET, newGame.y + 10, TEXT_PALETTE)

      if view.popup then
        local popup = assert(layout.popup)
        local shapedPopup = popup --[[@as { box: table<string, number>, actions: { delete: table<string, number> } }]]
        graphics.setColor(0, 0, 0, 0.45)
        graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)
        drawCard(graphics, shapedPopup.box, false)
        drawInset(graphics, shapedPopup.actions.delete, true)
        drawPaletteText(
          graphics,
          text,
          displayUpper("Delete"),
          shapedPopup.actions.delete.x + 4,
          shapedPopup.actions.delete.y + 4,
          TEXT_PALETTE
        )
      end
      if view.confirmation then
        local confirmation = assert(layout.confirmation)
        local shapedConfirm = confirmation --[[@as { box: table<string, number>, cancel: table<string, number>, delete: table<string, number> }]]
        graphics.setColor(0, 0, 0, 0.62)
        graphics.rectangle("fill", 0, 0, viewport.width, viewport.height)
        drawCard(graphics, shapedConfirm.box, false)
        drawPaletteText(
          graphics,
          text,
          displayUpper("Delete this save?"),
          shapedConfirm.box.x + CARD_INSET,
          shapedConfirm.box.y + CARD_INSET,
          TEXT_PALETTE
        )
        local cancelFocus = view.confirmation.focusedAction == "cancel"
        local deleteFocus = view.confirmation.focusedAction == "delete"
        drawInset(graphics, shapedConfirm.cancel, cancelFocus)
        drawInset(graphics, shapedConfirm.delete, deleteFocus)
        drawPaletteText(
          graphics,
          text,
          displayUpper("Cancel"),
          shapedConfirm.cancel.x + 4,
          shapedConfirm.cancel.y + 4,
          TEXT_PALETTE
        )
        drawPaletteText(
          graphics,
          text,
          displayUpper("Delete"),
          shapedConfirm.delete.x + 4,
          shapedConfirm.delete.y + 4,
          TEXT_PALETTE
        )
      end
    end, debug.traceback)
    graphics.setColor(red, green, blue, alpha)
    graphics.setLineWidth(lineWidth)
    if not ok then
      error(err, 0)
    end
  end)
  graphics.setColor(red, green, blue, alpha)
  graphics.setLineWidth(lineWidth)
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
