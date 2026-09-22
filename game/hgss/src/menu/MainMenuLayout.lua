-- Pure logical Main Menu geometry shared by drawing and hit testing. All
-- dimensions are logical pixels: the single presentation transform lives
-- at the outer draw/input boundary, never inside these metrics.

local PixelScale = require("libs.ui.src.PixelScale")

local MainMenuLayout = {}

local BASE_MARGIN = 8
local BASE_REGION_GAP = 6
-- Card budget: the 10px top inset plus the 16px heading plus three 16px
-- profile rows plus the 10px bottom inset the renderer reserves below them.
local BASE_CARD_HEIGHT = 84
local BASE_CARD_GAP = 6
local BASE_NEW_GAME_HEIGHT = 36
local BASE_OVERFLOW_SIZE = 24
local BASE_OVERFLOW_INSET = 6
local BASE_CATALOG_ERROR_HEIGHT = 24
local BASE_CONTENT_WIDTH = 320
local BASE_POPUP_WIDTH = 144
local BASE_POPUP_HEIGHT = 56
local BASE_POPUP_INSET = 8
local BASE_POPUP_ANCHOR_GAP = 4
local BASE_CONFIRM_WIDTH = 420
local BASE_CONFIRM_HEIGHT = 136
local BASE_CONFIRM_INSET = 8
local BASE_CONFIRM_ACTION_GAP = 8
local BASE_CONFIRM_ACTION_HEIGHT = 36
local BASE_CONFIRM_BOTTOM_OFFSET = 48
local BASE_INDICATOR_WIDTH = 12
local BASE_INDICATOR_HEIGHT = 10
local BASE_INDICATOR_GUTTER = 14

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---@param rect table<string, number>
---@param x number
---@param y number
---@return boolean
function MainMenuLayout.contains(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

local function saveId(save)
  return assert(save.saveId or save.id)
end

local function focusIndex(saves, focus)
  if focus.region ~= "saves" then
    return 1
  end
  for index, save in ipairs(saves) do
    if saveId(save) == focus.saveId then
      return index
    end
  end
  return 1
end

local function popupRect(anchor, width, height, margin)
  local boxWidth, boxHeight = BASE_POPUP_WIDTH, BASE_POPUP_HEIGHT
  local x = anchor.x + anchor.width - boxWidth
  local y = anchor.y + anchor.height + BASE_POPUP_ANCHOR_GAP
  x = clamp(x, margin, math.max(margin, width - margin - boxWidth))
  y = clamp(y, margin, math.max(margin, height - margin - boxHeight))
  return { x = x, y = y, width = boxWidth, height = boxHeight }
end

---@param globalActions table[]
---@param saves table[]
---@param focus table<string, string>
---@param width number logical viewport width
---@param height number logical viewport height
---@param previousOffset number|nil logical scroll offset retained from the previous layout
---@param popup table<string, string>|nil
---@param confirmation table<string, string>|nil
---@param hasCatalogError boolean|nil
---@return table<string, unknown>
function MainMenuLayout.compute(
  globalActions,
  saves,
  focus,
  width,
  height,
  previousOffset,
  popup,
  confirmation,
  hasCatalogError
)
  assert(type(globalActions) == "table" and #globalActions > 0, "Main Menu needs a global action")
  assert(type(saves) == "table", "Main Menu saves must be an array")
  assert(type(focus) == "table" and type(focus.region) == "string", "Main Menu focus is required")
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  assert(
    previousOffset == nil or (type(previousOffset) == "number" and previousOffset == previousOffset),
    "Main Menu scroll offset must be a number"
  )
  local margin = BASE_MARGIN
  local regionGap = BASE_REGION_GAP
  local cardHeight = BASE_CARD_HEIGHT
  local cardGap = BASE_CARD_GAP
  local newGameHeight = BASE_NEW_GAME_HEIGHT
  local overflowSize = BASE_OVERFLOW_SIZE
  local overflowInset = BASE_OVERFLOW_INSET
  local errorHeight = hasCatalogError and BASE_CATALOG_ERROR_HEIGHT or 0
  local errorGap = hasCatalogError and cardGap or 0

  local viewport = { x = 0, y = 0, width = width, height = height }
  local contentWidth = math.max(1, math.min(width - margin * 2, BASE_CONTENT_WIDTH))
  local contentX = PixelScale.snapLogical((width - contentWidth) / 2)
  local newGame = {
    x = contentX,
    y = height - margin - newGameHeight,
    width = contentWidth,
    height = newGameHeight,
  }
  local saveViewport = {
    x = contentX,
    y = margin,
    width = contentWidth,
    height = math.max(1, newGame.y - regionGap - margin),
  }

  local totalCardsHeight = #saves * cardHeight + math.max(0, #saves - 1) * cardGap
  local totalContentHeight = errorHeight + errorGap + totalCardsHeight
  local maxOffset = math.max(0, totalContentHeight - saveViewport.height)
  -- The retained offset survives resize verbatim in logical units: a
  -- viewport that grew can leave the offset past its own maximum until
  -- navigation or another resize moves it. Only invalid input clamps low.
  local offset = math.max(0, previousOffset or 0)
  local focusedIndex = focusIndex(saves, focus)
  local focusedTop = errorHeight + errorGap + (focusedIndex - 1) * (cardHeight + cardGap)
  if focus.region == "saves" then
    if focusedTop < offset then
      offset = focusedTop
    elseif focusedTop + cardHeight > offset + saveViewport.height then
      offset = focusedTop + cardHeight - saveViewport.height
    end
  end
  offset = math.max(0, offset)

  local gutter = maxOffset > 0 and BASE_INDICATOR_GUTTER or 0
  local frameWidth = math.max(1, saveViewport.width - gutter)

  local cards = {}
  local firstCardY = saveViewport.y + errorHeight + errorGap - offset
  for index, save in ipairs(saves) do
    local id = saveId(save)
    local y = firstCardY + (index - 1) * (cardHeight + cardGap)
    local frame = { x = saveViewport.x, y = y, width = frameWidth, height = cardHeight }
    local overflow
    local bodyWidth = frame.width
    if save.canDelete == true then
      overflow = {
        x = frame.x + frame.width - overflowInset - overflowSize,
        y = frame.y + overflowInset,
        width = overflowSize,
        height = overflowSize,
      }
      bodyWidth = frame.width - overflowSize - overflowInset * 2
    end
    local body = { x = frame.x, y = frame.y, width = math.max(1, bodyWidth), height = frame.height }
    cards[id] = { frame = frame, body = body, overflow = overflow }
  end

  local indicatorWidth = BASE_INDICATOR_WIDTH
  local indicatorHeight = BASE_INDICATOR_HEIGHT
  local indicatorX = saveViewport.x + saveViewport.width - gutter + math.floor((gutter - indicatorWidth) / 2)
  local scrollIndicators = {
    up = offset > 0 and {
      x = indicatorX,
      y = saveViewport.y + BASE_REGION_GAP - 1,
      width = indicatorWidth,
      height = indicatorHeight,
    } or nil,
    down = offset < maxOffset and {
      x = indicatorX,
      y = saveViewport.y + saveViewport.height - BASE_REGION_GAP + 1 - indicatorHeight,
      width = indicatorWidth,
      height = indicatorHeight,
    } or nil,
  }

  local result = {
    viewport = viewport,
    global = { region = newGame, actions = { [assert(globalActions[1]).id] = newGame } },
    saves = {
      viewport = saveViewport,
      cards = cards,
      offset = offset,
      totalContentHeight = totalContentHeight,
      scrollIndicators = scrollIndicators,
    },
    offset = offset,
  }
  if hasCatalogError then
    result.catalogErrorRect = {
      x = saveViewport.x,
      y = saveViewport.y - offset,
      width = frameWidth,
      height = BASE_CATALOG_ERROR_HEIGHT,
    }
  end
  if popup then
    local card = assert(cards[popup.saveId], "popup save must have layout geometry")
    local box = popupRect(card.overflow or card.frame, width, height, margin)
    local inset = BASE_POPUP_INSET
    result.popup = {
      box = box,
      actions = {
        delete = {
          x = box.x + inset,
          y = box.y + inset,
          width = math.max(1, box.width - inset * 2),
          height = math.max(1, box.height - inset * 2),
        },
      },
    }
  end
  if confirmation then
    local boxWidth, boxHeight = math.min(BASE_CONFIRM_WIDTH, width - margin * 2), math.min(BASE_CONFIRM_HEIGHT, height)
    local box = {
      x = math.floor((width - boxWidth) / 2),
      y = math.floor((height - boxHeight) / 2),
      width = math.max(1, boxWidth),
      height = math.max(1, boxHeight),
    }
    local inset = BASE_CONFIRM_INSET
    local gap = BASE_CONFIRM_ACTION_GAP
    local actionHeight = BASE_CONFIRM_ACTION_HEIGHT
    local actionWidth = math.max(1, math.floor((box.width - inset * 2 - gap) / 2))
    local actionY = math.max(box.y + inset, box.y + box.height - BASE_CONFIRM_BOTTOM_OFFSET)
    actionY = math.min(actionY, math.max(box.y + inset, box.y + box.height - actionHeight))
    result.confirmation = {
      box = box,
      cancel = { x = box.x + inset, y = actionY, width = actionWidth, height = actionHeight },
      delete = { x = box.x + inset + actionWidth + gap, y = actionY, width = actionWidth, height = actionHeight },
    }
  end
  return result
end

-- Centralized semantic hit resolution over the returned geometry with the
-- existing modal precedence: confirmation beats popup beats global action
-- beats save cards, and cards clipped by the save viewport never hit. The
-- coordinates are logical units in the layout viewport. Modal ownership
-- (which save a popup or confirmation belongs to) comes from the semantic
-- view beside the layout.
---@param layout table<string, unknown> the computed logical geometry
---@param view table<string, unknown> the semantic snapshot carrying popup/confirmation ownership
---@param x number logical x
---@param y number logical y
---@return table<string, string|nil> hit descriptor: global action, save body/overflow, popup delete/outside, confirmation cancel/delete, or all nil
function MainMenuLayout.hitTest(layout, view, x, y)
  assert(type(layout) == "table", "Main Menu hit testing needs its layout")
  assert(type(view) == "table", "Main Menu hit testing needs its semantic view")
  assert(type(x) == "number" and type(y) == "number", "Main Menu hit testing needs logical coordinates")
  local function miss()
    return { region = nil, actionId = nil, saveId = nil, lane = nil }
  end
  local confirmation = layout.confirmation
  if confirmation ~= nil then
    local shaped = confirmation --[[@as { box: table<string, number>, cancel: table<string, number>, delete: table<string, number> }]]
    local confirmSaveId = view.confirmation ~= nil and view.confirmation.saveId or nil
    if MainMenuLayout.contains(shaped.delete, x, y) then
      return { region = "confirmation", actionId = nil, saveId = confirmSaveId, lane = "delete" }
    end
    if MainMenuLayout.contains(shaped.cancel, x, y) then
      return { region = "confirmation", actionId = nil, saveId = confirmSaveId, lane = "cancel" }
    end
    return miss()
  end
  local popup = layout.popup
  if popup ~= nil then
    local shaped = popup --[[@as { box: table<string, number>, actions: { delete: table<string, number> } }]]
    local popupSaveId = view.popup ~= nil and view.popup.saveId or nil
    if MainMenuLayout.contains(shaped.actions.delete, x, y) then
      return { region = "popup", actionId = nil, saveId = popupSaveId, lane = "delete" }
    end
    if not MainMenuLayout.contains(shaped.box, x, y) then
      return { region = "popup", actionId = nil, saveId = popupSaveId, lane = "outside" }
    end
    return miss()
  end
  local global = layout.global
  if global ~= nil then
    local actions = global.actions
    if type(actions) == "table" then
      for actionId, rect in pairs(actions) do
        if MainMenuLayout.contains(rect, x, y) then
          return { region = "global", actionId = actionId, saveId = nil, lane = nil }
        end
      end
    end
  end
  local saves = layout.saves
  if saves ~= nil then
    local shaped = saves --[[@as { viewport: table<string, number>, cards: table<string, table<string, table<string, number>>> }]]
    if MainMenuLayout.contains(shaped.viewport, x, y) then
      for cardId, card in pairs(shaped.cards) do
        if card.overflow ~= nil and MainMenuLayout.contains(card.overflow, x, y) then
          return { region = "saves", actionId = nil, saveId = cardId, lane = "overflow" }
        end
        if MainMenuLayout.contains(card.body, x, y) then
          return { region = "saves", actionId = nil, saveId = cardId, lane = "body" }
        end
      end
    end
  end
  return miss()
end

return MainMenuLayout
