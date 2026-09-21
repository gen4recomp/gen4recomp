-- The current party screen's four function references with matching
-- render and input callbacks. DualDisplay takes the auxiliary fullscreen
-- and nativeLike the single-surface fullscreen, both uncropped; wide and
-- tall center the canonical 256x192 pane in a static framed box with
-- a native-like fallback below 1x. The content is the canonical compact
-- grid resolved against the controller's cancel permission; input passes
-- visible logical points to the existing controller and drops matte taps.
-- A per-case override replaces the whole render/input pair, never a mode
-- token. Resolvers require the measured context production sessions
-- supply; helper-derived surface selections fill the remaining fields.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

---@class PartyScreenInterface
local PartyScreenInterface = {}

local NATIVE = { id = "content", width = 256, height = 192 }
local INPUT_KEY = "party"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderParty(resources, view, plan)
  local renderer = assert(resources.partyScreenRenderer, "the party render borrows its renderer")
  local icons = assert(resources.icons, "the party render borrows its icon provider")
  local graphics = assert(resources.graphics, "the party render borrows its host graphics")
  local pane = assert(plan.panes[1], "the party plan carries its content pane")
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  LogicalSurface.draw(graphics, assert(pane.placement, "the party pane carries its placement"), function()
    renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, plan: table<string, unknown>, collaborators: table<string, unknown>) }]].draw(
      renderer,
      view,
      plan,
      icons
    )
  end)
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the party ignores it
local function mapPartyInput(event, _, _)
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
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
    content = {},
    inputKey = "party-inactive",
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
    nativeLikeInterface = context.nativeLikeInterface or PartyScreenInterface.fullscreen,
  }
end

---@param view table<string, unknown> the wrapper semantic snapshot
---@return table<string, unknown> the canonical compact content for the controller's cancel permission
local function partyContent(view)
  -- A closed snapshot carries no cancel permission; its plan is discarded
  -- at disposal, so the controller default applies without changing
  -- visible behavior.
  local cancellable = view.cancellable
  if type(cancellable) ~= "boolean" then
    cancellable = true
  end
  return PartyScreenLayout.resolve({ width = NATIVE.width, height = NATIVE.height, cancellable = cancellable })
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

-- Fullscreen party for the dualDisplay and nativeLike cases: one canonical
-- interactive pane over the owned target region, never cropped, framed only
-- when the pane leaves target background visible.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PartyScreenInterface.fullscreen(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.fullscreen(complete, NATIVE, { maxOverdraw = ZERO_CROP })
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
    content = partyContent(view),
    inputKey = INPUT_KEY,
    render = renderParty,
    mapInput = mapPartyInput,
  }
end

-- Static framed party for the wide and tall cases: the canonical pane
-- centered with its complete outer frame. A frame that cannot fit 1x falls
-- back to the effective nativeLike case with the same context and view; the
-- configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PartyScreenInterface.framed(context, view)
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
    content = partyContent(view),
    inputKey = INPUT_KEY,
    render = renderParty,
    mapInput = mapPartyInput,
  }
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The four resolver functions behind one case per display configuration:
-- dual and native-like own their fullscreen region, wide and tall center
-- the canonical pane in a static frame.
PartyScreenInterface.dualDisplay = PartyScreenInterface.fullscreen
PartyScreenInterface.nativeLike = PartyScreenInterface.fullscreen
PartyScreenInterface.wide = PartyScreenInterface.framed
PartyScreenInterface.tall = PartyScreenInterface.framed

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function PartyScreenInterface.withOverrides(overrides)
  local set = {
    dualDisplay = PartyScreenInterface.fullscreen,
    nativeLike = PartyScreenInterface.fullscreen,
    wide = PartyScreenInterface.framed,
    tall = PartyScreenInterface.framed,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the party overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown party override case " .. tostring(key))
      assert(type(fn) == "function", "the party override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return PartyScreenInterface
