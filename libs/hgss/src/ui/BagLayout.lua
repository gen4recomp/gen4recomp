-- Canonical logical geometry for the field bag: the generated tab, slot,
-- cancel, and fallback rectangles with one logical hit test. Host
-- composition (which panes exist, where they sit, how they scale) belongs
-- to the leaf interface through the shared presentation contracts; this
-- module never sees topology or host dimensions. The interaction pane is
-- always 256x192 logical units. Pure module: no love, no I/O.

local BagSave = require("libs.hgss.src.save.BagSave")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class BagLayout
local BagLayout = {}

BagLayout.PANE_WIDTH = 256
BagLayout.PANE_HEIGHT = 192

---@param value unknown
---@param what string
local function checkRect(value, what)
  assert(type(value) == "table", what .. " must be a rectangle")
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    assert(type(value[axis]) == "number", what .. "." .. axis .. " must be a number")
  end
end

-- The canonical interactive geometry the hit test maps through. The full
-- manifest is validated once by the application state; the layout needs
-- only the tab, slot, cancel, and fallback rectangles it retains here.
---@param manifest table<string, unknown>
---@return table<string, unknown>
local function checkManifest(manifest)
  assert(type(manifest) == "table", "bag layout requires the validated bag manifest")
  local interactive = assert(manifest.interactive, "the bag manifest must carry its interactive pane")
  assert(type(interactive) == "table", "the bag manifest must carry its interactive pane")
  local tabs =
    assert(interactive.pocketTabs and interactive.pocketTabs.rects, "the manifest must carry eight tab rectangles")
  assert(#tabs == 8, "the manifest must carry eight tab rectangles")
  local slots =
    assert(interactive.itemSlots and interactive.itemSlots.slots, "the manifest must carry six slot records")
  assert(#slots == 6, "the manifest must carry six slot records")
  for _, slot in ipairs(slots) do
    checkRect(assert(slot.rect, "every slot needs its rectangle"), "slot")
  end
  checkRect(assert(interactive.cancel.rect, "the manifest must carry its cancel control rectangle"), "cancel")
  local fallback = assert(
    interactive.overlays and interactive.overlays.descriptionFallback,
    "the manifest must carry its description fallback"
  )
  checkRect(assert(fallback.frame, "the fallback needs its frame"), "description fallback")
  checkRect(assert(fallback.textRect, "the fallback needs its text rectangle"), "description fallback text")
  return interactive --[[@as table<string, unknown>]]
end

---@param state table<string, unknown>?
---@return boolean
local function overlayOpen(state)
  if type(state) ~= "table" or state.state ~= "description_overlay" then
    return false
  end
  return true
end

-- The generated action-menu button rectangles. The validated manifest
-- always carries the four compiled buttons; layout treats them as strict
-- geometry rather than an optional affordance.
---@param interactive table<string, unknown>
---@return table<integer, table<string, number>>
local function actionButtons(interactive)
  local overlays = assert(interactive.overlays, "the manifest must carry its overlay geometry")
  assert(type(overlays) == "table", "the manifest must carry its overlay geometry")
  local menu = assert(overlays.actionMenu, "the manifest must carry its action button geometry")
  assert(type(menu) == "table", "the manifest must carry its action button geometry")
  local buttons = assert(menu.buttons, "the manifest must carry its four action buttons")
  assert(type(buttons) == "table" and #buttons == 4, "the manifest must carry its four action buttons")
  for _, button in ipairs(buttons) do
    checkRect(button, "action button")
  end
  return buttons
end

---@param visibleSlots table<integer, BagLayout.VisibleSlot>?
---@param index integer
---@return boolean
local function cellOccupied(visibleSlots, index)
  if type(visibleSlots) ~= "table" then
    return true
  end
  local cell = visibleSlots[index]
  return cell ~= nil and cell.empty ~= true
end

---@class BagLayout.VisibleSlot
---@field empty boolean?

---@class BagLayout.ControllerState
---@field state string?
---@field visibleSlots table<integer, BagLayout.VisibleSlot>?

---@class BagLayout.Hit
---@field kind "description"|"pocket"|"item"|"cancel"|"action"|"quantity_delta"|"confirm"
---@field pocket string?
---@field visibleIndex integer?
---@field actionIndex integer?
---@field delta integer? -- exactly -1 or 1 only for quantity_delta

---@class BagLayout.Spec
---@field manifest table<string, unknown> the validated bag manifest carrying canonical interactive geometry
---@field heroVisible boolean true when the hero pane is composed beside the interaction pane

---@class BagLayoutResolved
---@field heroVisible boolean the leaf capability selecting the hero pane and its compact fallbacks
---@field descriptionFallback LayoutGeometry.Rect? canonical overlay frame (lower-only compositions only)
---@field descriptionTextRect LayoutGeometry.Rect? generated fallback text rectangle (lower-only compositions only)
---@field hitTest fun(logicalX: number, logicalY: number, controllerState: BagLayout.ControllerState?): BagLayout.Hit?

---@param spec BagLayout.Spec
---@return BagLayoutResolved
function BagLayout.resolve(spec)
  assert(type(spec) == "table", "bag layout requires a specification")
  local interactive = checkManifest(assert(spec.manifest, "bag layout requires the bag manifest"))
  local heroVisible = spec.heroVisible
  assert(type(heroVisible) == "boolean", "bag layout requires its hero visibility")

  local tabs = interactive.pocketTabs.rects
  local slots = interactive.itemSlots.slots
  local cancelRect = interactive.cancel.rect
  local fallback = interactive.overlays.descriptionFallback
  local fallbackFrame = fallback.frame
  local fallbackTextRect = fallback.textRect
  local buttons = actionButtons(interactive)

  ---@param logicalX number
  ---@param logicalY number
  ---@param controllerState BagLayout.ControllerState?
  ---@return BagLayout.Hit?
  local function hitTest(logicalX, logicalY, controllerState)
    assert(
      type(logicalX) == "number" and logicalX == logicalX and type(logicalY) == "number" and logicalY == logicalY,
      "bag hit testing needs finite logical coordinates"
    )
    if overlayOpen(controllerState) then
      if
        logicalX >= fallbackFrame.x
        and logicalX < fallbackFrame.x + fallbackFrame.width
        and logicalY >= fallbackFrame.y
        and logicalY < fallbackFrame.y + fallbackFrame.height
      then
        return { kind = "description" }
      end
    end
    -- The open action menu layers its buttons over the lower pane: a tap
    -- on a button carries the zero-based button position and the
    -- controller resolves it against the offered actions. Nested states
    -- reuse the same generated rectangles as responsive controls before
    -- normal browsing targets; toss states own input modally while move
    -- keeps its item cells alongside the explicit confirm.
    local buttonState = nil
    if type(controllerState) == "table" and type(controllerState.state) == "string" then
      buttonState = controllerState.state
    end
    if buttonState == "action_menu" then
      for index, button in ipairs(buttons) do
        if LayoutGeometry.containsPoint(button, logicalX, logicalY) then
          return { kind = "action", actionIndex = index - 1 }
        end
      end
    elseif buttonState == "toss_quantity" then
      if LayoutGeometry.containsPoint(buttons[1], logicalX, logicalY) then
        return { kind = "quantity_delta", delta = -1 }
      end
      if LayoutGeometry.containsPoint(buttons[2], logicalX, logicalY) then
        return { kind = "quantity_delta", delta = 1 }
      end
      if LayoutGeometry.containsPoint(buttons[3], logicalX, logicalY) then
        return { kind = "confirm" }
      end
      if LayoutGeometry.containsPoint(cancelRect, logicalX, logicalY) then
        return { kind = "cancel" }
      end
      return nil
    elseif buttonState == "toss_confirm" then
      if LayoutGeometry.containsPoint(buttons[3], logicalX, logicalY) then
        return { kind = "confirm" }
      end
      if LayoutGeometry.containsPoint(cancelRect, logicalX, logicalY) then
        return { kind = "cancel" }
      end
      return nil
    elseif buttonState == "move_select" then
      if LayoutGeometry.containsPoint(buttons[3], logicalX, logicalY) then
        return { kind = "confirm" }
      end
      for index, slot in ipairs(slots) do
        if LayoutGeometry.containsPoint(slot.rect, logicalX, logicalY) then
          if cellOccupied(controllerState and controllerState.visibleSlots, index) then
            return { kind = "item", visibleIndex = index - 1 }
          end
          return nil
        end
      end
      if LayoutGeometry.containsPoint(cancelRect, logicalX, logicalY) then
        return { kind = "cancel" }
      end
      return nil
    end
    for index, tab in ipairs(tabs) do
      if LayoutGeometry.containsPoint(tab, logicalX, logicalY) then
        return { kind = "pocket", pocket = BagSave.POCKET_ORDER[index] }
      end
    end
    -- Plain browsing exposes every visible cell to the pointer, occupied
    -- or empty, so keyboard and pointer focus stay aligned. Move-target
    -- selection keeps its occupancy gate in its own branch above.
    for index, slot in ipairs(slots) do
      if LayoutGeometry.containsPoint(slot.rect, logicalX, logicalY) then
        return { kind = "item", visibleIndex = index - 1 }
      end
    end
    if LayoutGeometry.containsPoint(cancelRect, logicalX, logicalY) then
      return { kind = "cancel" }
    end
    return nil
  end

  if heroVisible then
    return {
      heroVisible = true,
      descriptionFallback = nil,
      descriptionTextRect = nil,
      hitTest = hitTest,
    }
  end
  return {
    heroVisible = false,
    descriptionFallback = {
      x = fallbackFrame.x,
      y = fallbackFrame.y,
      width = fallbackFrame.width,
      height = fallbackFrame.height,
    },
    descriptionTextRect = {
      x = fallbackTextRect.x,
      y = fallbackTextRect.y,
      width = fallbackTextRect.width,
      height = fallbackTextRect.height,
    },
    hitTest = hitTest,
  }
end

return BagLayout
