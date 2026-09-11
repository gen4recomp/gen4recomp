-- Party-screen layout: responsive six-slot geometry over the current
-- viewport. The lead slot is larger and full-width, the remaining five
-- slots stack below it, the close affordance (when cancellable) anchors
-- the bottom, and the switch/cancel action rows center over the frame.
-- Slot rectangles use one-based indexes (slot0 + 1) and always resolve all
-- six positions so empty slots paint too; only occupied or eligible slots
-- become selectable, which stays the controller's decision. Neighbors walk
-- the column into the cancel node. Pure module: no love, no I/O.

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

---@class PartyScreenLayout.Hit
---@field kind "slot"|"action"|"cancel"
---@field slot integer?
---@field action string?

---@param rect ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@class PartyScreenLayout.Spec
---@field width number
---@field height number
---@field uiScale number?
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
  local uiScale = spec.uiScale or 1
  assert(type(uiScale) == "number" and uiScale > 0, "party layout ui scale must be positive")
  local cancellable = spec.cancellable
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "party layout cancel permission must be a boolean")

  local margin = 8 * uiScale
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

  local actionWidth = math.min(content.width * 0.6, 320 * uiScale)
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
  }
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
