-- Topology-aware placement for the field bag: two canonical 256x192 panes
-- recomposed by safe geometry only, never by device names or pixel
-- breakpoints. A physical auxiliary surface splits hero (world) from
-- interaction (auxiliary); a single surface evaluates horizontal (512x192)
-- and vertical (256x384) common-scale fits and keeps the larger usable
-- candidate (unit scale or better, exact ties preferring horizontal on wide
-- safe areas); a constrained surface falls back to the interactive pane
-- alone with the description reachable through its overlay. Pointer input
-- resolves through the same placement record rendering uses: host
-- coordinates map into the interactive pane, then into the canonical tab,
-- slot, cancel, and fallback rectangles. Pure module: no love, no I/O.

local BagSave = require("libs.hgss.src.save.BagSave")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class BagLayout
local BagLayout = {}

BagLayout.PANE_WIDTH = 256
BagLayout.PANE_HEIGHT = 192
BagLayout.MIN_TWO_PANE_SCALE = 1.0

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
    assert(interactive.pocketTabs and interactive.pocketTabs.tabs, "the manifest must carry eight tab rectangles")
  assert(#tabs == 8, "the manifest must carry eight tab rectangles")
  local slots =
    assert(interactive.itemSlots and interactive.itemSlots.slots, "the manifest must carry six slot records")
  assert(#slots == 6, "the manifest must carry six slot records")
  for _, slot in ipairs(slots) do
    checkRect(assert(slot.rect, "every slot needs its rectangle"), "slot")
  end
  checkRect(assert(interactive.cancel, "the manifest must carry its cancel rectangle"), "cancel")
  local fallback = assert(
    interactive.overlays and interactive.overlays.descriptionFallback,
    "the manifest must carry its description fallback"
  )
  checkRect(assert(fallback.frame, "the fallback needs its frame"), "description fallback")
  return interactive --[[@as table<string, unknown>]]
end

---@param frame LayoutGeometry.Rect
---@param scale number
---@param surfaceId string
---@return BagLayout.Placement
local function placement(frame, scale, surfaceId)
  return {
    frame = frame,
    origin = { x = frame.x, y = frame.y },
    scale = scale,
    logicalWidth = BagLayout.PANE_WIDTH,
    logicalHeight = BagLayout.PANE_HEIGHT,
    surfaceId = surfaceId,
  }
end

-- Splits one centered combined fit into its two pane frames: horizontal
-- lays hero left of interaction, vertical stacks hero above interaction.
---@param safe ScreenTopology.Rectangle
---@param logicalWidth integer
---@param logicalHeight integer
---@param horizontal boolean
---@return LayoutGeometry.Rect first
---@return LayoutGeometry.Rect second
---@return number scale
local function splitFit(safe, logicalWidth, logicalHeight, horizontal)
  local fit = LayoutGeometry.centeredFit(safe, logicalWidth, logicalHeight)
  local scale = fit.scale
  local frame = fit.frame
  if horizontal then
    local half = frame.width / 2
    return { x = frame.x, y = frame.y, width = half, height = frame.height },
      { x = frame.x + half, y = frame.y, width = half, height = frame.height },
      scale
  end
  local half = frame.height / 2
  return { x = frame.x, y = frame.y, width = frame.width, height = half },
    { x = frame.x, y = frame.y + half, width = frame.width, height = half },
    scale
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

---@class BagLayout.Placement
---@field frame LayoutGeometry.Rect
---@field origin { x: number, y: number } the render translate point shared with logical mapping
---@field scale number
---@field logicalWidth integer
---@field logicalHeight integer
---@field surfaceId string

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
---@field topology ScreenTopology
---@field referenceFrame ScreenTopology.Rectangle? accepted for composition symmetry; selection uses safe geometry only
---@field manifest table<string, unknown> the validated bag manifest carrying canonical interactive geometry

---@class BagLayoutResolved
---@field mode "dual"|"horizontal"|"vertical"|"interactive_only"
---@field hero BagLayout.Placement? the upper-pane placement (absent when constrained)
---@field interactive BagLayout.Placement the lower-pane placement
---@field descriptionFallback ScreenTopology.Rectangle? canonical overlay frame (constrained mode only)
---@field interactiveHitTest fun(hostX: number, hostY: number, controllerState: BagLayout.ControllerState?): BagLayout.Hit?

---@param spec BagLayout.Spec
---@return BagLayoutResolved
function BagLayout.resolve(spec)
  assert(type(spec) == "table", "bag layout requires a specification")
  local topology = assert(spec.topology, "bag layout requires a screen topology")
  assert(type(topology.surfaces) == "table" and #topology.surfaces > 0, "bag layout requires topology surfaces")
  local interactive = checkManifest(assert(spec.manifest, "bag layout requires the bag manifest"))
  local world, auxiliary
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" and auxiliary == nil then
      auxiliary = surface
    elseif surface.role == "world" and world == nil then
      world = surface
    end
  end
  local single = world or topology.surfaces[1]
  assert(single ~= nil, "bag layout requires at least one surface")

  local tabs = interactive.pocketTabs.tabs
  local slots = interactive.itemSlots.slots
  local cancelRect = interactive.cancel
  local fallbackFrame = interactive.overlays.descriptionFallback.frame
  local buttons = actionButtons(interactive)

  ---@param hitPlacement BagLayout.Placement
  ---@return fun(hostX: number, hostY: number, controllerState: BagLayout.ControllerState?): BagLayout.Hit?
  local function hitTestFactory(hitPlacement)
    ---@param hostX number
    ---@param hostY number
    ---@param controllerState BagLayout.ControllerState?
    ---@return BagLayout.Hit?
    local function hitTest(hostX, hostY, controllerState)
      local logicalX, logicalY = LayoutGeometry.hostToLogical(hitPlacement, hostX, hostY)
      if logicalX == nil then
        return nil
      end
      assert(logicalY ~= nil, "host mapping returns both coordinates together")
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
    return hitTest
  end

  if auxiliary ~= nil then
    local heroFit = LayoutGeometry.centeredFit(world.safeRect, BagLayout.PANE_WIDTH, BagLayout.PANE_HEIGHT)
    local interactiveFit = LayoutGeometry.centeredFit(auxiliary.safeRect, BagLayout.PANE_WIDTH, BagLayout.PANE_HEIGHT)
    local heroPlacement = placement(heroFit.frame, heroFit.scale, world.id)
    local interactivePlacement = placement(interactiveFit.frame, interactiveFit.scale, auxiliary.id)
    return {
      mode = "dual",
      hero = heroPlacement,
      interactive = interactivePlacement,
      interactiveHitTest = hitTestFactory(interactivePlacement),
    }
  end

  local safe = single.safeRect
  local horizontalScale = math.min(safe.width / (BagLayout.PANE_WIDTH * 2), safe.height / BagLayout.PANE_HEIGHT)
  local verticalScale = math.min(safe.width / BagLayout.PANE_WIDTH, safe.height / (BagLayout.PANE_HEIGHT * 2))
  local horizontalUsable = horizontalScale >= BagLayout.MIN_TWO_PANE_SCALE
  local verticalUsable = verticalScale >= BagLayout.MIN_TWO_PANE_SCALE
  local mode = nil
  if horizontalUsable and verticalUsable then
    if horizontalScale == verticalScale then
      mode = safe.width >= safe.height and "horizontal" or "vertical"
    else
      mode = horizontalScale > verticalScale and "horizontal" or "vertical"
    end
  elseif horizontalUsable then
    mode = "horizontal"
  elseif verticalUsable then
    mode = "vertical"
  end

  if mode == "horizontal" or mode == "vertical" then
    local first, second, scale
    if mode == "horizontal" then
      first, second, scale = splitFit(safe, BagLayout.PANE_WIDTH * 2, BagLayout.PANE_HEIGHT, true)
    else
      first, second, scale = splitFit(safe, BagLayout.PANE_WIDTH, BagLayout.PANE_HEIGHT * 2, false)
    end
    local heroPlacement = placement(first, scale, single.id)
    local interactivePlacement = placement(second, scale, single.id)
    return {
      mode = mode,
      hero = heroPlacement,
      interactive = interactivePlacement,
      interactiveHitTest = hitTestFactory(interactivePlacement),
    }
  end

  local fallback = LayoutGeometry.centeredFit(safe, BagLayout.PANE_WIDTH, BagLayout.PANE_HEIGHT)
  local interactivePlacement = placement(fallback.frame, fallback.scale, single.id)
  return {
    mode = "interactive_only",
    interactive = interactivePlacement,
    descriptionFallback = {
      x = fallbackFrame.x,
      y = fallbackFrame.y,
      width = fallbackFrame.width,
      height = fallbackFrame.height,
    },
    interactiveHitTest = hitTestFactory(interactivePlacement),
  }
end

return BagLayout
