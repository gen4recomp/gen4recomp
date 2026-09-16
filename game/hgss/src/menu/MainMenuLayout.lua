-- Pure responsive Main Menu geometry shared by drawing and hit testing.

local PixelScale = require("libs.ui.src.PixelScale")

local MainMenuLayout = {}

local BASE_MARGIN = 8
local BASE_REGION_GAP = 6
local BASE_CARD_HEIGHT = 72
local BASE_CARD_GAP = 6
local BASE_NEW_GAME_HEIGHT = 36
local BASE_OVERFLOW_SIZE = 24
local BASE_OVERFLOW_INSET = 6
local BASE_CATALOG_ERROR_HEIGHT = 24
local BASE_CONTENT_WIDTH = 320
local BASE_INDICATOR_WIDTH = 12
local BASE_INDICATOR_HEIGHT = 10
local BASE_INDICATOR_GUTTER = 14
local MAX_UI_SCALE = 3

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
  local boxWidth, boxHeight = 144, 56
  local x = anchor.x + anchor.width - boxWidth
  local y = anchor.y + anchor.height + 4
  x = clamp(x, margin, math.max(margin, width - margin - boxWidth))
  y = clamp(y, margin, math.max(margin, height - margin - boxHeight))
  return { x = x, y = y, width = boxWidth, height = boxHeight }
end

---@param globalActions table[]
---@param saves table[]
---@param focus table<string, string>
---@param width number
---@param height number
---@param previousOffset number|nil
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
  local uiScale = clamp(math.floor(math.min(width / 320, height / 240)), 1, MAX_UI_SCALE)
  local margin = BASE_MARGIN * uiScale
  local regionGap = BASE_REGION_GAP * uiScale
  local cardHeight = BASE_CARD_HEIGHT * uiScale
  local cardGap = BASE_CARD_GAP * uiScale
  local newGameHeight = BASE_NEW_GAME_HEIGHT * uiScale
  local overflowSize = BASE_OVERFLOW_SIZE * uiScale
  local overflowInset = BASE_OVERFLOW_INSET * uiScale
  local errorHeight = hasCatalogError and BASE_CATALOG_ERROR_HEIGHT * uiScale or 0
  local errorGap = hasCatalogError and cardGap or 0

  local viewport = { x = 0, y = 0, width = width, height = height }
  local contentWidth = math.max(1, math.min(width - margin * 2, BASE_CONTENT_WIDTH * uiScale))
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
  local offset = clamp(previousOffset or 0, 0, maxOffset)
  local focusedIndex = focusIndex(saves, focus)
  local focusedTop = errorHeight + errorGap + (focusedIndex - 1) * (cardHeight + cardGap)
  if focus.region == "saves" then
    if focusedTop < offset then
      offset = focusedTop
    elseif focusedTop + cardHeight > offset + saveViewport.height then
      offset = focusedTop + cardHeight - saveViewport.height
    end
  end
  offset = clamp(offset, 0, maxOffset)

  local gutter = maxOffset > 0 and BASE_INDICATOR_GUTTER * uiScale or 0
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

  local indicatorWidth = BASE_INDICATOR_WIDTH * uiScale
  local indicatorHeight = BASE_INDICATOR_HEIGHT * uiScale
  local indicatorX = saveViewport.x + saveViewport.width - gutter + math.floor((gutter - indicatorWidth) / 2)
  local scrollIndicators = {
    up = offset > 0 and {
      x = indicatorX,
      y = saveViewport.y + BASE_REGION_GAP * uiScale - uiScale,
      width = indicatorWidth,
      height = indicatorHeight,
    } or nil,
    down = offset < maxOffset and {
      x = indicatorX,
      y = saveViewport.y + saveViewport.height - BASE_REGION_GAP * uiScale + uiScale - indicatorHeight,
      width = indicatorWidth,
      height = indicatorHeight,
    } or nil,
  }

  local result = {
    viewport = viewport,
    uiScale = uiScale,
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
      height = BASE_CATALOG_ERROR_HEIGHT * uiScale,
    }
  end
  if popup then
    local card = assert(cards[popup.saveId], "popup save must have layout geometry")
    local box = popupRect(card.overflow or card.frame, width, height, margin)
    result.popup = {
      box = box,
      actions = { delete = { x = box.x + 8, y = box.y + 8, width = box.width - 16, height = box.height - 16 } },
    }
  end
  if confirmation then
    local boxWidth, boxHeight = math.min(420, width - margin * 2), 136
    local box = {
      x = math.floor((width - boxWidth) / 2),
      y = math.floor((height - boxHeight) / 2),
      width = math.max(1, boxWidth),
      height = math.min(boxHeight, height),
    }
    local actionWidth = math.max(1, math.floor((box.width - 24) / 2))
    result.confirmation = {
      box = box,
      cancel = { x = box.x + 8, y = box.y + box.height - 48, width = actionWidth, height = 36 },
      delete = { x = box.x + 16 + actionWidth, y = box.y + box.height - 48, width = actionWidth, height = 36 },
    }
  end
  return result
end

return MainMenuLayout
