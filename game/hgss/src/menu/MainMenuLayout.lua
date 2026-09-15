-- Pure responsive Main Menu geometry shared by drawing and hit testing.

local MainMenuLayout = {}

local MARGIN = 16
local HEADER_HEIGHT = 16
local GLOBAL_HEIGHT = 48
local CARD_HEIGHT = 64
local CARD_GAP = 8
local OVERFLOW_WIDTH = 40
local OVERFLOW_HEIGHT = 32
local CATALOG_ERROR_HEIGHT = 24
local MAX_CONTENT_WIDTH = 960

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

local function popupRect(anchor, width, height)
  local boxWidth, boxHeight = 144, 56
  local x = anchor.x + anchor.width - boxWidth
  local y = anchor.y + anchor.height + 4
  x = clamp(x, MARGIN, math.max(MARGIN, width - MARGIN - boxWidth))
  y = clamp(y, MARGIN, math.max(MARGIN, height - MARGIN - boxHeight))
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
  local viewport = { x = 0, y = 0, width = width, height = height }
  local contentWidth = math.max(1, math.min(MAX_CONTENT_WIDTH, width - MARGIN * 2))
  local contentX = math.floor((width - contentWidth) / 2)
  local globalRegion = {
    x = contentX,
    y = MARGIN + HEADER_HEIGHT,
    width = contentWidth,
    height = GLOBAL_HEIGHT,
  }
  local saveViewport = {
    x = contentX,
    y = globalRegion.y + GLOBAL_HEIGHT + MARGIN,
    width = contentWidth,
    height = math.max(1, height - (globalRegion.y + GLOBAL_HEIGHT + MARGIN) - MARGIN),
  }

  local errorHeight = hasCatalogError and CATALOG_ERROR_HEIGHT or 0
  local errorGap = hasCatalogError and CARD_GAP or 0
  local totalCardsHeight = #saves * CARD_HEIGHT + math.max(0, #saves - 1) * CARD_GAP
  local totalContentHeight = errorHeight + errorGap + totalCardsHeight
  local maxOffset = math.max(0, totalContentHeight - saveViewport.height)
  local offset = clamp(previousOffset or 0, 0, maxOffset)
  local focusedIndex = focusIndex(saves, focus)
  local focusedTop = errorHeight + errorGap + (focusedIndex - 1) * (CARD_HEIGHT + CARD_GAP)
  if focus.region == "saves" then
    if focusedTop < offset then
      offset = focusedTop
    elseif focusedTop + CARD_HEIGHT > offset + saveViewport.height then
      offset = focusedTop + CARD_HEIGHT - saveViewport.height
    end
  end
  offset = clamp(offset, 0, maxOffset)

  local cards = {}
  local firstCardY = saveViewport.y + errorHeight + errorGap - offset
  for index, save in ipairs(saves) do
    local id = saveId(save)
    local y = firstCardY + (index - 1) * (CARD_HEIGHT + CARD_GAP)
    local frame = { x = saveViewport.x, y = y, width = saveViewport.width, height = CARD_HEIGHT }
    local overflow
    local bodyWidth = frame.width
    if save.canDelete ~= false then
      overflow = {
        x = frame.x + frame.width - OVERFLOW_WIDTH - 8,
        y = frame.y + 8,
        width = OVERFLOW_WIDTH,
        height = OVERFLOW_HEIGHT,
      }
      bodyWidth = frame.width - OVERFLOW_WIDTH - 16
    end
    local body = { x = frame.x, y = frame.y, width = math.max(1, bodyWidth), height = frame.height }
    cards[id] = { frame = frame, body = body, overflow = overflow }
  end

  local result = {
    viewport = viewport,
    global = { region = globalRegion, actions = { [assert(globalActions[1]).id] = globalRegion } },
    saves = {
      viewport = saveViewport,
      cards = cards,
      offset = offset,
      totalContentHeight = totalContentHeight,
    },
    offset = offset,
  }
  if hasCatalogError then
    result.catalogErrorRect = {
      x = saveViewport.x,
      y = saveViewport.y,
      width = saveViewport.width,
      height = CATALOG_ERROR_HEIGHT,
    }
  end
  if popup then
    local card = assert(cards[popup.saveId], "popup save must have layout geometry")
    local box = popupRect(card.overflow, width, height)
    result.popup = {
      box = box,
      actions = { delete = { x = box.x + 8, y = box.y + 8, width = box.width - 16, height = box.height - 16 } },
    }
  end
  if confirmation then
    local boxWidth, boxHeight = math.min(420, width - MARGIN * 2), 136
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
