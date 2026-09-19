-- Party-screen layout: logical six-slot geometry. The field interface
-- resolves one native 256x192 pane to a compact two-column grid of
-- readable cards with a footer band and a centred action overlay; other
-- logical viewports keep the responsive column with a larger lead slot.
-- Slot rectangles use one-based indexes (slot0 + 1) and always resolve all
-- six positions so empty slots paint too; only occupied or eligible slots
-- become selectable, which stays the controller's decision. The rendered
-- grid carries its own neighbors into the cancel node while the shared
-- default column order stays available to nonvisual script selection.
-- Pure module: no love, no I/O.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class PartyScreenLayout
local PartyScreenLayout = {}

---@class PartyScreenLayoutResolved
---@field frame ScreenTopology.Rectangle
---@field slotRects table<integer, ScreenTopology.Rectangle>
---@field actionRects table<string, ScreenTopology.Rectangle>
---@field cancelRect ScreenTopology.Rectangle?
---@field neighbors table<integer|string, table<string, integer|string>>
---@field hitTest fun(x: number, y: number, actionsActive: boolean?): PartyScreenLayout.Hit?
---@field compact boolean true for the native two-column field interface

---@class PartyScreenLayout.Hit
---@field kind "slot"|"action"|"cancel"
---@field slot integer?
---@field action string?

---@param rect ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- The native compact field interface: two columns and three rows of
-- 122x52 cards, a footer band with the selected name and cancel, and a
-- centred 128x40 action overlay. Row-major source slot order is unchanged.
local COMPACT_WIDTH = 256
local COMPACT_HEIGHT = 192
local COMPACT_CARD_X = { 4, 130 }
local COMPACT_CARD_Y = { 4, 60, 116 }
local COMPACT_CARD_WIDTH = 122
local COMPACT_CARD_HEIGHT = 52
local COMPACT_CANCEL = { x = 192, y = 172, width = 60, height = 16 }
local COMPACT_ACTION = { x = 64, y = 76, width = 128, height = 40 }

---@param cancellable boolean
---@return table<integer, ScreenTopology.Rectangle> slotRects
---@return ScreenTopology.Rectangle? cancelRect
---@return table<string, ScreenTopology.Rectangle> actionRects
---@return table<integer|string, table<string, integer|string>> neighbors
local function compactGeometry(cancellable)
  local slotRects = {}
  for slot0 = 0, 5 do
    slotRects[slot0 + 1] = {
      x = COMPACT_CARD_X[(slot0 % 2) + 1],
      y = COMPACT_CARD_Y[math.floor(slot0 / 2) + 1],
      width = COMPACT_CARD_WIDTH,
      height = COMPACT_CARD_HEIGHT,
    }
  end
  local cancelRect
  if cancellable then
    cancelRect = {
      x = COMPACT_CANCEL.x,
      y = COMPACT_CANCEL.y,
      width = COMPACT_CANCEL.width,
      height = COMPACT_CANCEL.height,
    }
  end
  local actionRects = {
    switch = { x = COMPACT_ACTION.x, y = COMPACT_ACTION.y, width = COMPACT_ACTION.width, height = 20 },
    cancel = { x = COMPACT_ACTION.x, y = COMPACT_ACTION.y + 20, width = COMPACT_ACTION.width, height = 20 },
  }
  local neighbors = {}
  for slot0 = 0, 5 do
    local column = slot0 % 2
    local row = math.floor(slot0 / 2)
    local links = {}
    if column == 0 then
      links.right = slot0 + 1
    else
      links.left = slot0 - 1
    end
    if row > 0 then
      links.up = slot0 - 2
    end
    if row < 2 then
      links.down = slot0 + 2
    elseif cancellable then
      links.down = "cancel"
    end
    neighbors[slot0] = links
  end
  if cancellable then
    neighbors.cancel = { up = 4 }
  end
  return slotRects, cancelRect, actionRects, neighbors
end

---@param frame ScreenTopology.Rectangle
---@param slotRects table<integer, ScreenTopology.Rectangle>
---@param cancelRect ScreenTopology.Rectangle?
---@param actionRects table<string, ScreenTopology.Rectangle>
---@param neighbors table<integer|string, table<string, integer|string>>
---@param compact boolean
---@return PartyScreenLayoutResolved
local function finish(frame, slotRects, cancelRect, actionRects, neighbors, compact)
  ---@param x number
  ---@param y number
  ---@param actionsActive boolean?
  ---@return PartyScreenLayout.Hit?
  local function hitTest(x, y, actionsActive)
    assert(type(x) == "number" and type(y) == "number", "hit testing needs coordinates")
    if actionsActive == true then
      if LayoutGeometry.containsPoint(actionRects.switch, x, y) then
        return { kind = "action", action = "switch" }
      end
      if LayoutGeometry.containsPoint(actionRects.cancel, x, y) then
        return { kind = "action", action = "cancel" }
      end
    end
    for slot0 = 0, 5 do
      if LayoutGeometry.containsPoint(slotRects[slot0 + 1], x, y) then
        return { kind = "slot", slot = slot0 }
      end
    end
    if cancelRect ~= nil and LayoutGeometry.containsPoint(cancelRect, x, y) then
      return { kind = "cancel" }
    end
    return nil
  end

  return {
    frame = frame,
    slotRects = slotRects,
    actionRects = actionRects,
    cancelRect = cancelRect ~= nil and copyRect(cancelRect) or nil,
    neighbors = neighbors,
    hitTest = hitTest,
    compact = compact,
  }
end

---@class PartyScreenLayout.Spec
---@field width number logical viewport width
---@field height number logical viewport height
---@field cancellable boolean?

---@param spec PartyScreenLayout.Spec
---@return PartyScreenLayoutResolved
function PartyScreenLayout.resolve(spec)
  assert(type(spec) == "table", "party layout requires a specification")
  local validated =
    LayoutGeometry.rect({ x = 0, y = 0, width = spec.width, height = spec.height }, "party layout frame")
  ---@type ScreenTopology.Rectangle
  local frame = { x = validated.x, y = validated.y, width = validated.width, height = validated.height }
  local width, height = frame.width, frame.height
  local cancellable = spec.cancellable
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "party layout cancel permission must be a boolean")

  if width == COMPACT_WIDTH and height == COMPACT_HEIGHT then
    local compactSlots, compactCancel, compactActions, gridNeighbors = compactGeometry(cancellable)
    return finish(frame, compactSlots, compactCancel, compactActions, gridNeighbors, true)
  end

  local margin = 8
  assert(width > margin * 2 and height > margin * 2, "the viewport is too small for the party frame")
  local content = { x = margin, y = margin, width = width - margin * 2, height = height - margin * 2 }

  -- One unit per list row, two for the lead, one for the close affordance.
  local units = 7 + (cancellable and 1 or 0)
  local unit = content.height / units
  assert(unit > 0, "the party rows require positive height")

  local slotRects = {}
  slotRects[1] = { x = content.x, y = content.y, width = content.width, height = unit * 2 }
  for index = 2, 6 do
    slotRects[index] = {
      x = content.x,
      y = content.y + unit * index,
      width = content.width,
      height = unit,
    }
  end

  local cancelRect
  if cancellable then
    cancelRect = {
      x = content.x,
      y = content.y + content.height - unit,
      width = content.width,
      height = unit,
    }
  end

  local actionWidth = math.min(content.width * 0.6, 320)
  local actionHeight = unit * 2
  local actionFrame = {
    x = frame.x + (frame.width - actionWidth) / 2,
    y = frame.y + (frame.height - actionHeight) / 2,
    width = actionWidth,
    height = actionHeight,
  }
  local actionRects = {
    switch = { x = actionFrame.x, y = actionFrame.y, width = actionFrame.width, height = unit },
    cancel = { x = actionFrame.x, y = actionFrame.y + unit, width = actionFrame.width, height = unit },
  }

  local neighbors = PartyScreenLayout.defaultNeighbors(cancellable)
  return finish(frame, slotRects, cancelRect, actionRects, neighbors, false)
end

-- The canonical navigation order shared by compositions without live
-- viewport geometry (script selection): the slot column into cancel.
---@param cancellable boolean?
---@return table<integer|string, table<string, integer|string>>
function PartyScreenLayout.defaultNeighbors(cancellable)
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  local neighbors = {}
  for slot0 = 0, 5 do
    local links = {}
    if slot0 > 0 then
      links.up = slot0 - 1
    end
    if slot0 < 5 then
      links.down = slot0 + 1
    elseif cancellable then
      links.down = "cancel"
    end
    neighbors[slot0] = links
  end
  if cancellable then
    neighbors.cancel = { up = 5 }
  end
  return neighbors
end

return PartyScreenLayout
