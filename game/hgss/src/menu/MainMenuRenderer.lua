-- HGSS-styled Main Menu presentation over Button chrome and the generated field font.

local Button = require("libs.ui.src.Button")

---@class MainMenuRenderer
---@field text table<string, function>
---@field graphics love.graphics
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer

local BORDER = { 58 / 255, 58 / 255, 58 / 255, 1 }
local NEUTRAL_RIM = { 222 / 255, 230 / 255, 230 / 255, 1 }
local SELECTED_RIM = { 255 / 255, 58 / 255, 58 / 255, 1 }
local FACE_TOP = { 0.97, 0.96, 0.9, 1 }
local FACE_BOTTOM = { 0.89, 0.87, 0.77, 1 }
local OVERFLOW_FACE_TOP = { 1, 0.87, 0.82, 1 }
local OVERFLOW_FACE_BOTTOM = { 0.94, 0.72, 0.66, 1 }
local INK = { 0.12, 0.18, 0.25, 1 }
local MUTED = { 0.3, 0.38, 0.42, 1 }
local ERROR_INK = { 0.65, 0.22, 0.22, 1 }
local MARK = { 0.85, 0.88, 0.9, 1 }
local MARK_EDGE = { 0.35, 0.4, 0.45, 1 }

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

local function drawPanel(graphics, rect, scale, selected, faceTop, faceBottom)
  local resolved = Button.resolve({
    rect = rect,
    borderWidth = 2 * scale,
    rimWidth = 2 * scale,
    innerBorderWidth = 1 * scale,
    cornerRadius = 3 * scale,
    faceSplit = 0.5,
    contentInsetX = 0,
    contentInsetY = 0,
  })
  Button.draw(graphics, resolved, {
    border = BORDER,
    rim = selected and SELECTED_RIM or NEUTRAL_RIM,
    innerBorder = faceTop,
    faceTop = faceTop,
    faceBottom = faceBottom,
  })
end

local function drawText(graphics, text, value, x, y, scale)
  graphics.push()
  graphics.translate(x, y)
  graphics.scale(scale, scale)
  local ok, err = pcall(text.drawText, text, value, 0, 0)
  graphics.pop()
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

---@param options { text: table<string, function>, graphics?: love.graphics }
---@return MainMenuRenderer
function MainMenuRenderer.new(options)
  assert(type(options) == "table" and options.text, "Main Menu renderer requires FieldTextRenderer")
  local graphics = options.graphics or love.graphics
  ---@cast graphics love.graphics
  assert(graphics, "Main Menu renderer requires graphics")
  assert(type(options.text.drawText) == "function", "Main Menu renderer requires generated text drawing")
  return setmetatable({ text = options.text, graphics = graphics }, MainMenuRenderer)
end

---@param view table<string, unknown>
function MainMenuRenderer:draw(view)
  local graphics = self.graphics
  local layout = assert(view.layout)
  local text = self.text
  ---@type integer
  local scale = layout.uiScale or 1
  assert(type(scale) == "number" and scale == math.floor(scale) and scale >= 1, "Main Menu scale must be an integer")

  local red, green, blue, alpha = graphics.getColor()
  local lineWidth = graphics.getLineWidth()
  local oldX, oldY, oldWidth, oldHeight = graphics.getScissor()
  local ok, err = xpcall(function()
    graphics.setColor(0.08, 0.1, 0.15, 1)
    graphics.clear(0.08, 0.1, 0.15, 1)

    local focus = assert(view.focus)
    local saves = assert(layout.saves)
    graphics.setScissor(saves.viewport.x, saves.viewport.y, saves.viewport.width, saves.viewport.height)
    if view.catalogError and view.catalogError ~= "" then
      local errorRect = assert(layout.catalogErrorRect)
      setColor(graphics, ERROR_INK)
      drawText(graphics, text, "Save catalog unavailable", errorRect.x + 6 * scale, errorRect.y + 4 * scale, scale)
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
        drawPanel(graphics, card.frame, scale, false, FACE_TOP, FACE_BOTTOM)
        if bodyFocused then
          drawPanel(graphics, card.body, scale, true, FACE_TOP, FACE_BOTTOM)
        end
        local pad = 6 * scale
        local headingY = card.frame.y + 5 * scale
        setColor(graphics, INK)
        drawText(graphics, text, "CONTINUE", card.frame.x + pad, headingY, scale)
        if item.canContinue then
          setColor(graphics, INK)
          drawText(graphics, text, cardTitle(item), card.frame.x + pad, headingY + 20 * scale, scale)
          setColor(graphics, MUTED)
          drawText(graphics, text, item.playTimeLabel or "0:00", card.frame.x + pad, headingY + 40 * scale, scale)
        else
          setColor(graphics, ERROR_INK)
          drawText(graphics, text, cardTitle(item), card.frame.x + pad, headingY + 20 * scale, scale)
        end
        if card.overflow then
          if overflowFocused then
            drawPanel(graphics, card.overflow, scale, true, OVERFLOW_FACE_TOP, OVERFLOW_FACE_BOTTOM)
          else
            drawPanel(graphics, card.overflow, scale, false, FACE_TOP, FACE_BOTTOM)
          end
          setColor(graphics, INK)
          drawText(graphics, text, "...", card.overflow.x + 3 * scale, card.overflow.y + 4 * scale, scale)
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
    drawPanel(graphics, newGame, scale, globalFocus, FACE_TOP, FACE_BOTTOM)
    setColor(graphics, INK)
    drawText(graphics, text, "NEW GAME", newGame.x + 6 * scale, newGame.y + 10 * scale, scale)

    if view.popup then
      local popup = assert(layout.popup)
      graphics.setColor(0, 0, 0, 0.45)
      graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
      drawPanel(graphics, popup.box, scale, false, FACE_TOP, FACE_BOTTOM)
      drawPanel(graphics, popup.actions.delete, scale, true, FACE_TOP, FACE_BOTTOM)
      setColor(graphics, INK)
      drawText(graphics, text, "Delete", popup.actions.delete.x + 4 * scale, popup.actions.delete.y + 4 * scale, scale)
    end
    if view.confirmation then
      local confirmation = assert(layout.confirmation)
      graphics.setColor(0, 0, 0, 0.62)
      graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
      drawPanel(graphics, confirmation.box, scale, false, FACE_TOP, FACE_BOTTOM)
      setColor(graphics, INK)
      drawText(
        graphics,
        text,
        "Delete this save?",
        confirmation.box.x + 6 * scale,
        confirmation.box.y + 5 * scale,
        scale
      )
      local cancelFocus = view.confirmation.focusedAction == "cancel"
      local deleteFocus = view.confirmation.focusedAction == "delete"
      drawPanel(graphics, confirmation.cancel, scale, cancelFocus, FACE_TOP, FACE_BOTTOM)
      drawPanel(graphics, confirmation.delete, scale, deleteFocus, FACE_TOP, FACE_BOTTOM)
      setColor(graphics, INK)
      drawText(graphics, text, "Cancel", confirmation.cancel.x + 4 * scale, confirmation.cancel.y + 4 * scale, scale)
      drawText(graphics, text, "Delete", confirmation.delete.x + 4 * scale, confirmation.delete.y + 4 * scale, scale)
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
