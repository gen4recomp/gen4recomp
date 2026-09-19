-- The current Start Menu's four function references with matching render and
-- input callbacks. Fullscreen owns the auxiliary region on a genuine pair
-- and the single surface otherwise; wide and tall frame the canonical
-- 256x192 body in a draggable window with zero crop (the source
-- header/cancel target reaches the edge). The renderer is the existing
-- generated surface invoked through the resolved placement; input passes canonical body
-- coordinates to the existing controller and ignores matte and scroll. A
-- per-case override replaces the whole render/input pair, never a mode
-- token. Resolvers require the measured context production sessions supply;
-- helper-derived surface selections fill the remaining fields.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class StartMenuInterface
local StartMenuInterface = {}

local NATIVE = { id = "content", width = 256, height = 192 }
local INPUT_KEY = "start-menu"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }
local MATTE = { r = 0, g = 0, b = 0, a = 1 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderStartMenu(resources, view, plan)
  local renderer = assert(resources.startMenuRenderer, "the start menu needs its renderer")
  local pane = assert(plan.panes[1], "the start menu plan needs its content pane")
  renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, placement: table<string, unknown>) }]].draw(
    renderer,
    view,
    pane.placement
  )
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the menu ignores it
local function mapStartInput(event, _, _)
  if event.type == "pointer_scroll" then
    return nil
  end
  if event.outside == true then
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
    content = {},
    inputKey = "start-menu-inactive",
    render = noopRender,
    mapInput = noopMap,
    coverage = {},
    backgroundColor = MATTE,
  }
end

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
    windowPosition = context.windowPosition or { x = 0.5, y = 0.5 },
    nativeLikeInterface = context.nativeLikeInterface or StartMenuInterface.fullscreen,
  }
end

-- Fullscreen Start Menu for the dualDisplay and nativeLike cases: one
-- canonical interactive body pane over the owned target region.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StartMenuInterface.fullscreen(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.fullscreen(complete, NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local _ = view
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    content = { body = { x = 0, y = 0, width = NATIVE.width, height = NATIVE.height } },
    inputKey = INPUT_KEY,
    render = renderStartMenu,
    mapInput = mapStartInput,
    coverage = geometry.coverage,
    backgroundColor = MATTE,
  }
end

-- Windowed Start Menu for the wide and tall cases: the canonical body in a
-- shared draggable window. A window that cannot fit 1x falls back to the
-- effective nativeLike case with the same context and view; the
-- configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StartMenuInterface.windowed(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.windowed(complete, NATIVE, {})
  if geometry == nil then
    return complete.nativeLikeInterface(complete, view)
  end
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local _ = view
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    content = { body = { x = 0, y = 0, width = NATIVE.width, height = NATIVE.height } },
    inputKey = INPUT_KEY,
    render = renderStartMenu,
    mapInput = mapStartInput,
    coverage = geometry.coverage,
    backgroundColor = MATTE,
    window = geometry.window,
  }
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The four resolver functions behind one case per display configuration:
-- dual and native-like own their fullscreen region, wide and tall frame
-- the canonical body in a draggable window.
StartMenuInterface.dualDisplay = StartMenuInterface.fullscreen
StartMenuInterface.nativeLike = StartMenuInterface.fullscreen
StartMenuInterface.wide = StartMenuInterface.windowed
StartMenuInterface.tall = StartMenuInterface.windowed

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function StartMenuInterface.withOverrides(overrides)
  local set = {
    dualDisplay = StartMenuInterface.fullscreen,
    nativeLike = StartMenuInterface.fullscreen,
    wide = StartMenuInterface.windowed,
    tall = StartMenuInterface.windowed,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the start menu overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown start menu override case " .. tostring(key))
      assert(type(fn) == "function", "the start menu override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return StartMenuInterface
