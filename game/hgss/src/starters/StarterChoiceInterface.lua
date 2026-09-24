-- The current Starter Choice's four function references with matching
-- render and input callbacks. DualDisplay maps info to the world surface
-- and the machine interaction to auxiliary irrespective of either
-- region's touch flag; wide pairs info left of the machine and tall
-- stacks info above it, sharing one integer scale with no synthetic gap;
-- nativeLike resolves one complete compact portrait/action/message
-- interface. A pair that cannot fit 1x falls back to the effective
-- nativeLike case. Underfilled panes carry fitted chrome: one complete
-- outer frame around the pair envelope, or one per underfilled pane.
-- Resolvers require the measured context production sessions supply;
-- helper-derived surface selections fill the remaining fields. The native
-- mapper reads the state-owned scene presentation from the session view
-- for source-space hit mapping; resolution alone never touches it. A
-- per-case override replaces the whole render/input pair, never a mode
-- token.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class StarterChoiceInterface
local StarterChoiceInterface = {}

local INFO_NATIVE = { id = "info", width = 256, height = 192 }
local MACHINE_NATIVE = { id = "machine", width = 256, height = 192 }
local COMPACT_NATIVE = { id = "compact", width = 256, height = 192 }
local INPUT_KEY = "starter"
local COMPACT_INPUT_KEY = "starter-compact"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

-- Locked compact portrait/action geometry in native logical pixels:
-- three source-order portraits and the primary/Back actions. The message
-- region lives with the compact painter reusing the same constants.
local COMPACT_PORTRAITS = {
  { x = 8, y = 60, width = 80, height = 80 },
  { x = 88, y = 60, width = 80, height = 80 },
  { x = 168, y = 60, width = 80, height = 80 },
}
local COMPACT_PRIMARY = { x = 8, y = 164, width = 112, height = 24 }
local COMPACT_BACK = { x = 136, y = 164, width = 112, height = 24 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderNative(resources, view, plan)
  local presentation = assert(resources.presentation, "the starter render borrows its presentation")
  local text = assert(resources.text, "the starter render borrows its text provider")
  local windowRenderer = assert(resources.windowRenderer, "the starter render borrows the field window renderer")
  local renderAlpha = assert(resources.renderAlpha, "the starter render borrows the field interpolation alpha")
  assert(type(view.selectionState) == "string", "the starter render reads the controller snapshot")
  local snapshot = view
  presentation --[[@as { drawNative: fun(self: table<string, unknown>, snapshot: table<string, unknown>, view: table<string, unknown>, text: table<string, unknown>, plan: table<string, unknown>, windowRenderer: table<string, unknown>, renderAlpha: number) }]].drawNative(
    presentation,
    snapshot,
    view,
    text,
    plan,
    windowRenderer,
    renderAlpha
  )
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderCompact(resources, view, plan)
  local presentation = assert(resources.presentation, "the starter render borrows its presentation")
  local text = assert(resources.text, "the starter render borrows its text provider")
  local windowRenderer = assert(resources.windowRenderer, "the starter render borrows the field window renderer")
  assert(type(view.selectionState) == "string", "the starter render reads the controller snapshot")
  local snapshot = view
  presentation --[[@as { drawCompact: fun(self: table<string, unknown>, snapshot: table<string, unknown>, view: table<string, unknown>, text: table<string, unknown>, plan: table<string, unknown>, windowRenderer: table<string, unknown>) }]].drawCompact(
    presentation,
    snapshot,
    view,
    text,
    plan,
    windowRenderer
  )
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
    inputKey = "starter-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param panes table<integer, table<string, unknown>> the resolved ordered panes
---@param frames table<integer, table<string, unknown>> the static outer-frame geometry
---@param render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan)
---@param mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan): table<string, unknown>?
---@param inputKey string the stable input-geometry identity
---@return ApplicationPlan
local function starterPlan(panes, frames, render, mapInput, inputKey)
  return {
    panes = panes,
    frames = frames,
    -- The blocking choice never dismisses: outside presses stay blocking
    -- under the existing mapper.
    content = {},
    inputKey = inputKey,
    render = render,
    mapInput = mapInput,
  }
end

-- Completes a measured production context with helper-derived surface
-- selections. The effective nativeLike entry (including an override)
-- backs the pair fallback below.
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
    nativeLikeInterface = context.nativeLikeInterface or StarterChoiceInterface.nativeLike,
  }
end

-- The state-owned scene presentation plus the controller snapshot behind
-- one mapping view. Resolution never needs them; only native hit mapping
-- does.
---@param view table<string, unknown> the session view
---@return table<string, unknown> presentation, table<string, unknown> snapshot
local function mappingInputs(view)
  assert(type(view) == "table", "native hit mapping reads the session view")
  local presentation = assert(view.presentation, "native hit mapping needs the scene presentation")
  assert(type(presentation.ballAt) == "function", "native hit mapping needs source-space projection")
  assert(type(view.selectionState) == "string", "native hit mapping needs the controller snapshot")
  return presentation, view
end

-- Native machine mapper: source-space hits become controller taps
-- through the unchanged canonical projection; taps outside the machine
-- keep the current tap(nil) reversal contract. Only the press edge
-- dispatches; moves, releases, and scrolls carry no starter semantics.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the session view carrying the scene presentation
---@return table<string, unknown>? the app event, or nil when the machine ignores it
local function mapNativeInput(event, view, _)
  if event.type ~= "pointer_down" then
    return nil
  end
  if event.outside == true then
    return { type = "tap", index = nil }
  end
  local x, y = event.x, event.y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local presentation, snapshot = mappingInputs(view)
  local ball = presentation:ballAt(x, y, snapshot)
  if ball == nil then
    return { type = "tap", index = nil }
  end
  return { type = "tap", index = ball - 1 }
end

-- Compact mapper: portrait presses tap their candidate, primary
-- confirms, and Back cancels only from an idle confirmation. Presses
-- outside every actionable region map to nothing so they can never
-- confirm a choice. Only the press edge dispatches.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the controller snapshot for Back gating
---@return table<string, unknown>? the app event, or nil when the compact interface ignores it
local function mapCompactInput(event, view, _)
  if event.type ~= "pointer_down" or event.outside == true then
    return nil
  end
  local x, y = event.x, event.y
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  for index, portrait in ipairs(COMPACT_PORTRAITS) do
    if x >= portrait.x and x < portrait.x + portrait.width and y >= portrait.y and y < portrait.y + portrait.height then
      return { type = "tap", index = index - 1 }
    end
  end
  if
    x >= COMPACT_PRIMARY.x
    and x < COMPACT_PRIMARY.x + COMPACT_PRIMARY.width
    and y >= COMPACT_PRIMARY.y
    and y < COMPACT_PRIMARY.y + COMPACT_PRIMARY.height
  then
    return { type = "confirm" }
  end
  if
    x >= COMPACT_BACK.x
    and x < COMPACT_BACK.x + COMPACT_BACK.width
    and y >= COMPACT_BACK.y
    and y < COMPACT_BACK.y + COMPACT_BACK.height
  then
    if type(view) == "table" and view.selectionState == "confirm" and view.transition == "idle" then
      return { type = "cancel" }
    end
    return nil
  end
  return nil
end

-- DualDisplay: info on the world surface, machine interaction on
-- auxiliary irrespective of touch flags. The machine never crops; the
-- info pane may use the default four-edge budget only to cover its own
-- display (its message and portrait content stays at least eight logical
-- pixels inside every edge, so bounded overdraw cannot hide it). Each
-- underfilled physical pane carries its own complete outer frame.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.dualDisplay(context, view)
  local _ = view
  local complete = completeContext(context)
  local geometry = ApplicationLayout.nativeDual(complete, INFO_NATIVE, MACHINE_NATIVE, {
    lower = { maxOverdraw = ZERO_CROP },
  })
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

-- NativeLike: one complete compact portrait/action/message interface,
-- fullscreen with no crop. A covered target stays unframed; an
-- underfilled one refits as a complete decorated box with zero crop.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.nativeLike(context, view)
  local _ = view
  local complete = completeContext(context)
  local geometry = ApplicationLayout.coverOrFrame(complete, COMPACT_NATIVE, { maxOverdraw = ZERO_CROP })
  local pane = geometry.placements[COMPACT_NATIVE.id]
  if pane == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = COMPACT_NATIVE.id, placement = pane, interactive = true },
  }, geometry.frames or {}, renderCompact, mapCompactInput, COMPACT_INPUT_KEY)
end

-- Wide: info left, machine right, one shared integer scale with no gap and
-- one fitted frame around the common envelope. A pair that cannot fit 1x
-- falls back to the effective nativeLike entry without changing the
-- measured configuration.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.wide(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.sideBySide(complete, INFO_NATIVE, MACHINE_NATIVE)
  if geometry == nil then
    return complete.nativeLikeInterface(complete, view)
  end
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

-- Tall: info above, machine below, one shared integer scale with no gap
-- and one fitted frame around the common envelope, with the same 1x
-- fallback as wide.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function StarterChoiceInterface.tall(context, view)
  local complete = completeContext(context)
  local geometry = ApplicationLayout.stacked(complete, INFO_NATIVE, MACHINE_NATIVE)
  if geometry == nil then
    return complete.nativeLikeInterface(complete, view)
  end
  local info = geometry.placements[INFO_NATIVE.id]
  local machine = geometry.placements[MACHINE_NATIVE.id]
  if info == nil or machine == nil then
    return inactivePlan()
  end
  return starterPlan({
    { id = INFO_NATIVE.id, placement = info, interactive = false },
    { id = MACHINE_NATIVE.id, placement = machine, interactive = true },
  }, geometry.frames or {}, renderNative, mapNativeInput, INPUT_KEY)
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function StarterChoiceInterface.withOverrides(overrides)
  local set = {
    dualDisplay = StarterChoiceInterface.dualDisplay,
    nativeLike = StarterChoiceInterface.nativeLike,
    wide = StarterChoiceInterface.wide,
    tall = StarterChoiceInterface.tall,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the starter overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown starter override case " .. tostring(key))
      assert(type(fn) == "function", "the starter override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return StarterChoiceInterface
