-- HGSS-inspired Main Menu presentation using the generated field font.

---@class MainMenuGraphics
---@field setColor fun(red: number, green: number, blue: number, alpha: number)
---@field clear fun(...)
---@field rectangle fun(mode: string, x: number, y: number, width: number, height: number)
---@field setLineWidth fun(width: number)
---@field getScissor fun(): number?, number?, number?, number?
---@field setScissor fun(x?: number, y?: number, width?: number, height?: number)
---@class MainMenuRenderer
---@field text table<string, function>
---@field graphics MainMenuGraphics
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

local function drawPanel(graphics, rect, focused)
  graphics.setColor(0.93, 0.94, 0.88, 1)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  graphics.setColor(focused and 0.45 or 0.68, focused and 0.2 or 0.72, focused and 0.2 or 0.72, 1)
  graphics.setLineWidth(3)
  graphics.rectangle("line", rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  graphics.setColor(0.7, 0.6, 0.4, 1)
  graphics.setLineWidth(1)
  graphics.rectangle("line", rect.x + 5, rect.y + 5, rect.width - 10, rect.height - 10)
end

local function title(item)
  if item.id == "new-game" then
    return "New Game"
  end
  return item.playerName or "Save unavailable"
end

local function subtitle(item)
  if item.id == "new-game" then
    return "Start a new adventure"
  end
  if item.canContinue then
    return item.playTimeLabel or "0:00"
  end
  return item.errorSummary or "Save unavailable"
end

---@param options { text: table<string, function>, graphics?: MainMenuGraphics }
---@return MainMenuRenderer
function MainMenuRenderer.new(options)
  assert(type(options) == "table" and options.text, "Main Menu renderer requires FieldTextRenderer")
  local graphics = options.graphics or love.graphics
  ---@cast graphics MainMenuGraphics
  assert(graphics, "Main Menu renderer requires graphics")
  assert(type(options.text.drawText) == "function", "Main Menu renderer requires generated text drawing")
  return setmetatable({ text = options.text, graphics = graphics }, MainMenuRenderer)
end

---@param view table<string, unknown>
function MainMenuRenderer:draw(view)
  local graphics = self.graphics
  local layout = assert(view.layout)
  local text = self.text
  graphics.setColor(0.08, 0.1, 0.15, 1)
  graphics.clear(0.08, 0.1, 0.15, 1)
  setColor(graphics, { 0.95, 0.9, 0.65, 1 })
  text:drawText("g4recomp", layout.viewport.x + 16, 16)

  local oldX, oldY, oldWidth, oldHeight = graphics.getScissor()
  local saves = assert(layout.saves)
  graphics.setScissor(saves.viewport.x, saves.viewport.y, saves.viewport.width, saves.viewport.height)
  local ok, err = xpcall(function()
    if view.catalogError and view.catalogError ~= "" then
      local errorRect = assert(layout.catalogErrorRect)
      setColor(graphics, { 1, 0.35, 0.35, 1 })
      text:drawText("Save catalog unavailable", errorRect.x + 8, errorRect.y + 4)
    end
    for _, item in ipairs(assert(view.saves)) do
      local card = saves.cards[item.id]
      if card then
        local focus = assert(view.focus)
        local bodyFocused = focus.region == "saves" and focus.saveId == item.id and focus.lane == "body"
        local overflowFocused = focus.region == "saves" and focus.saveId == item.id and focus.lane == "overflow"
        drawPanel(graphics, card.frame, bodyFocused)
        setColor(graphics, item.canContinue and { 0.12, 0.18, 0.25, 1 } or { 0.45, 0.18, 0.18, 1 })
        text:drawText(title(item), card.body.x + 12, card.body.y + 12)
        setColor(graphics, item.canContinue and { 0.3, 0.38, 0.42, 1 } or { 0.65, 0.22, 0.22, 1 })
        text:drawText(subtitle(item), card.body.x + 12, card.body.y + 36)
        if card.overflow then
          graphics.setColor(overflowFocused and 0.65 or 0.78, overflowFocused and 0.2 or 0.72, 0.25, 1)
          graphics.rectangle("fill", card.overflow.x, card.overflow.y, card.overflow.width, card.overflow.height)
          setColor(graphics, { 0.12, 0.18, 0.25, 1 })
          text:drawText("...", card.overflow.x + 10, card.overflow.y + 8)
        end
      end
    end
  end, debug.traceback)
  if oldX ~= nil then
    graphics.setScissor(oldX, oldY, oldWidth, oldHeight)
  else
    graphics.setScissor()
  end
  if not ok then
    error(err, 0)
  end

  local globalFocus = view.focus.region == "global"
  local global = assert(layout.global)
  local newGame = assert(global.actions["new-game"])
  drawPanel(graphics, newGame, globalFocus)
  setColor(graphics, { 0.12, 0.18, 0.25, 1 })
  text:drawText("New Game", newGame.x + 12, newGame.y + 16)

  if view.popup then
    local popup = assert(layout.popup)
    graphics.setColor(0, 0, 0, 0.45)
    graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
    drawPanel(graphics, popup.box, true)
    setColor(graphics, { 0.12, 0.18, 0.25, 1 })
    text:drawText("Delete", popup.actions.delete.x + 12, popup.actions.delete.y + 8)
  end
  if view.confirmation then
    local confirmation = assert(layout.confirmation)
    graphics.setColor(0, 0, 0, 0.62)
    graphics.rectangle("fill", 0, 0, layout.viewport.width, layout.viewport.height)
    drawPanel(graphics, confirmation.box, true)
    setColor(graphics, { 0.12, 0.18, 0.25, 1 })
    text:drawText("Delete this save?", confirmation.box.x + 16, confirmation.box.y + 16)
    local cancelFocus = view.confirmation.focusedAction == "cancel"
    local deleteFocus = view.confirmation.focusedAction == "delete"
    drawPanel(graphics, confirmation.cancel, cancelFocus)
    drawPanel(graphics, confirmation.delete, deleteFocus)
    setColor(graphics, { 0.12, 0.18, 0.25, 1 })
    text:drawText("Cancel", confirmation.cancel.x + 10, confirmation.cancel.y + 10)
    text:drawText("Delete", confirmation.delete.x + 10, confirmation.delete.y + 10)
  end
end

function MainMenuRenderer:dispose()
  if self.text and self.text.release then
    self.text:release()
  end
  self.text = nil
end

return MainMenuRenderer
