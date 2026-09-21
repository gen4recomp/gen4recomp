-- The current Trainer Card's four function references with matching
-- render and input callbacks. DualDisplay takes the auxiliary fullscreen
-- and nativeLike the single-surface fullscreen, both with the default
-- four-edge crop budget guarded by the protected text rect; wide and tall
-- center the canonical 256x192 pane in a static framed box with zero
-- crop and a native-like fallback below 1x. The renderer is the existing
-- card surface invoked through the resolved placement; input forwards the
-- existing semantic events and discards pointer content, while a true
-- outside press maps to the terminal dismiss edge. A per-case override
-- replaces the whole render/input pair, never a mode token.
-- Resolvers require the measured context
-- production sessions supply; helper-derived surface selections fill the
-- remaining fields.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class TrainerCardInterface
local TrainerCardInterface = {}

local NATIVE = { id = "content", width = 256, height = 192 }
local INPUT_KEY = "trainer-card"
local FULL_CROP = { left = 4, right = 4, top = 4, bottom = 4 }
local PROTECTED = { x = 8, y = 8, width = 240, height = 176 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderCard(resources, view, plan)
  local renderer = assert(resources.trainerCardRenderer, "the card render borrows its renderer")
  assert(resources.graphics, "the card render borrows its host graphics")
  local pane = assert(plan.panes[1], "the card plan carries its content pane")
  renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, placement: table<string, unknown>) }]].draw(
    renderer,
    view,
    assert(pane.placement, "the card pane carries its placement")
  )
end

-- The card has no pointer controls: ordinary pointer content and pointer
-- cancellation reach no semantic action, while the existing semantic events
-- (the close edge and its siblings) travel to the controller unchanged.
---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the card ignores it
local function mapCardInput(event, _, _)
  local eventType = event.type
  if eventType == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  if
    eventType == "pointer_down"
    or eventType == "pointer_move"
    or eventType == "pointer_up"
    or eventType == "pointer_scroll"
    or eventType == "pointer_cancel"
  then
    return nil
  end
  return event
end

local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return ApplicationPlan a valid inactive plan: no panes, no targets, cancellation still deliverable
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = { width = NATIVE.width, height = NATIVE.height },
    inputKey = "trainer-card-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Completes a measured production context with helper-derived surface
-- selections. The effective nativeLike entry (including an override) backs
-- the below-1x framed fallback.
---@param context ApplicationLayout.Context
---@return ApplicationLayout.Context the production context with helper-derived selections
local function completeContext(context)
  assert(type(context) == "table", "a resolver needs its context")
  local measurement = assert(context.measurement, "a resolver needs its display measurement")
  local selection = ApplicationLayout.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = context.configuration,
    primary = context.primary or selection.primary,
    secondary = context.secondary or selection.secondary,
    nativeLikeInterface = context.nativeLikeInterface or TrainerCardInterface.fullscreen,
  }
end

---@return { width: number, height: number } the canonical card content descriptor
local function cardContent()
  return { width = NATIVE.width, height = NATIVE.height }
end

---@param context ApplicationLayout.Context
---@return LayoutGeometry.Rect? the fullscreen target bounds
local function fullscreenTarget(context)
  local target = context.secondary or context.primary
  if target == nil then
    return nil
  end
  return target.usableBounds
end

-- Fullscreen card for the dualDisplay and nativeLike cases: one canonical
-- pane over the owned target region with the default four-edge crop budget
-- guarded by the protected text rect, so only borders and margins can hide
-- in a near fit. A frame is attached only when the pane leaves target
-- background visible.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function TrainerCardInterface.fullscreen(context, view)
  local _ = view
  local complete = completeContext(context)
  local geometry =
    ApplicationLayout.fullscreen(complete, NATIVE, { maxOverdraw = FULL_CROP, protectedRect = PROTECTED })
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local frames = {}
  local target = fullscreenTarget(complete)
  if target ~= nil then
    local frame = ApplicationLayout.frameAround(target, placement)
    if frame ~= nil then
      frames = { frame }
    end
  end
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = frames,
    content = cardContent(),
    inputKey = INPUT_KEY,
    render = renderCard,
    mapInput = mapCardInput,
  }
end

-- Static framed card for the wide and tall cases: the canonical pane
-- centered with its complete outer frame and zero crop. A frame that cannot
-- fit 1x falls back to the effective nativeLike case with the same context
-- and view; the configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function TrainerCardInterface.framed(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.framed(complete, NATIVE, {})
  if geometry == nil then
    return complete.nativeLikeInterface(complete, view)
  end
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = cardContent(),
    inputKey = INPUT_KEY,
    render = renderCard,
    mapInput = mapCardInput,
  }
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The four resolver functions behind one case per display configuration:
-- dual and native-like own their fullscreen region, wide and tall center
-- the canonical pane in a static frame.
TrainerCardInterface.dualDisplay = TrainerCardInterface.fullscreen
TrainerCardInterface.nativeLike = TrainerCardInterface.fullscreen
TrainerCardInterface.wide = TrainerCardInterface.framed
TrainerCardInterface.tall = TrainerCardInterface.framed

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function TrainerCardInterface.withOverrides(overrides)
  local set = {
    dualDisplay = TrainerCardInterface.fullscreen,
    nativeLike = TrainerCardInterface.fullscreen,
    wide = TrainerCardInterface.framed,
    tall = TrainerCardInterface.framed,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the card overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown card override case " .. tostring(key))
      assert(type(fn) == "function", "the card override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return TrainerCardInterface
