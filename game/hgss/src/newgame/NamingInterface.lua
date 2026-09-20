-- Parent-owned placement for the reusable Naming Screen child. One
-- canonical 256x192 crop-0 pane on the auxiliary surface for genuine pairs,
-- fullscreen for native-like, and a static centered pane for wide/tall.
-- Naming never carries outer decoration. The child layout always derives
-- from the full canonical logical region, never the visible clip; the child
-- itself carries no placement or scale. Input maps canonical pointer hits
-- to the existing controller entrypoints; activation stays on downs,
-- cancellation stays mute.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")

---@class NamingInterface
local NamingInterface = {}

local NATIVE = { id = "content", width = 256, height = 192 }
local CANONICAL_VIEWPORT = { x = 0, y = 0, width = 256, height = 192 }
local INPUT_KEY = "naming"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the naming semantic snapshot
---@param plan ApplicationPlan
local function renderNaming(resources, view, plan)
  local graphics = assert(resources.graphics, "naming render needs its borrowed graphics")
  local renderer = assert(resources.namingRenderer, "naming render needs its borrowed renderer")
  local pane = assert(plan.panes[1], "the naming plan needs its content pane")
  local content = assert(plan.content, "the naming plan needs its canonical content")
  local layout = assert(content.layout, "the naming plan needs its canonical child layout")
  LogicalSurface.draw(graphics, pane.placement, function()
    renderer.draw(renderer, view, layout)
  end)
end

---@param event table<string, unknown> session-inverted logical input
---@param _ table<string, unknown>
---@param plan ApplicationPlan
---@return table<string, unknown>? the app event, or nil when naming ignores it
local function mapNamingInput(event, _, plan)
  local eventType = event.type
  if eventType ~= "pointer_down" then
    return nil
  end
  if event.outside == true then
    return nil
  end
  local x, y = event.x, event.y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local content = assert(plan.content, "the naming plan needs its canonical content")
  local layout = assert(content.layout, "the naming plan needs its canonical child layout")
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    if NamingScreenLayout.contains(layout.controls[id], x, y) then
      return { type = "name_control", id = id }
    end
  end
  for row = 1, 6 do
    for column = 1, 13 do
      if NamingScreenLayout.contains(layout.cells[row][column], x, y) then
        return { type = "name_cell", row = row, column = column }
      end
    end
  end
  return nil
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
    fadeCoverage = {},
    content = {},
    inputKey = "naming-inactive",
    render = noopRender,
    mapInput = noopMap,
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
    nativeLikeInterface = context.nativeLikeInterface or NamingInterface.fullscreen,
  }
end

-- Fullscreen naming for the dualDisplay and nativeLike cases: one
-- canonical child pane over the owned target region, never decorated.
-- Auxiliary on a genuine pair, the single surface otherwise.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function NamingInterface.fullscreen(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.fullscreen(complete, NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local _ = view
  return {
    panes = { { id = NATIVE.id, placement = placement, interactive = true } },
    frames = {},
    fadeCoverage = geometry.fadeCoverage,
    content = { layout = NamingScreenLayout.compute(CANONICAL_VIEWPORT) },
    inputKey = INPUT_KEY,
    render = renderNaming,
    mapInput = mapNamingInput,
  }
end

-- Static centered naming for the wide and tall cases: the canonical child
-- at integer scale with no outer decoration. A pane that cannot fit 1x
-- falls back to the effective nativeLike case with the same context and
-- view; the configuration keeps describing the actual measured display.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function NamingInterface.centered(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.centered(complete, NATIVE, {})
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
    frames = {},
    fadeCoverage = geometry.fadeCoverage,
    content = { layout = NamingScreenLayout.compute(CANONICAL_VIEWPORT) },
    inputKey = INPUT_KEY,
    render = renderNaming,
    mapInput = mapNamingInput,
  }
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The four resolver functions behind one case per display configuration:
-- dual and native-like own their fullscreen region, wide and tall center
-- the canonical child with no decoration.
NamingInterface.dualDisplay = NamingInterface.fullscreen
NamingInterface.nativeLike = NamingInterface.fullscreen
NamingInterface.wide = NamingInterface.centered
NamingInterface.tall = NamingInterface.centered

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function NamingInterface.withOverrides(overrides)
  local set = {
    dualDisplay = NamingInterface.fullscreen,
    nativeLike = NamingInterface.fullscreen,
    wide = NamingInterface.centered,
    tall = NamingInterface.centered,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the naming overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown naming override case " .. tostring(key))
      assert(type(fn) == "function", "the naming override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return NamingInterface
