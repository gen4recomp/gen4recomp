-- The current Bag's four function references with matching render and
-- input callbacks. DualDisplay maps the hero to the world surface and the
-- interaction to auxiliary; wide pairs hero left of interaction and tall
-- stacks hero above, sharing one integer scale with no synthetic gap;
-- nativeLike shows only the interaction pane with the canonical description
-- fallback. The lower pane never crops (its controls reach the source
-- edges); the hero may use the default four-edge budget only for a true
-- cover of its own physical display. A pair that cannot fit 1x falls back
-- to the nativeLike case. Underfilled panes carry fitted chrome: one
-- complete outer frame around the pair envelope, or one per underfilled
-- physical pane. Resolvers require the
-- measured context production sessions supply; helper-derived surface
-- selections fill the remaining fields.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local BagLayout = require("libs.hgss.src.ui.BagLayout")

---@class BagInterface
local BagInterface = {}

local HERO_NATIVE = { id = "hero", width = 256, height = 192 }
local INTERACTION_NATIVE = { id = "interaction", width = 256, height = 192 }
local INPUT_KEY = "bag"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderBag(resources, view, plan)
  local renderer = assert(resources.bagRenderer, "the bag render borrows its renderer")
  local icons = assert(resources.icons, "the bag render borrows its icon provider")
  renderer --[[@as { draw: fun(self: table<string, unknown>, presentation: table<string, unknown>, plan: table<string, unknown>, collaborators: table<string, unknown>) }]].draw(
    renderer,
    view,
    plan,
    { icons = icons }
  )
end

---@param event table<string, unknown> session-inverted logical input
---@return table<string, unknown>? the app event, or nil when the bag ignores it
local function mapBagInput(event, _, _)
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
    inputKey = "bag-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

---@param manifest table<string, unknown> the validated bag presentation manifest
---@param heroVisible boolean true when the resolved panes include the hero
---@param panes table<integer, table<string, unknown>> the resolved ordered panes
---@param frames table<integer, table<string, unknown>> the static outer-frame geometry
---@return ApplicationPlan
local function bagPlan(manifest, heroVisible, panes, frames)
  return {
    panes = panes,
    frames = frames,
    content = BagLayout.resolve({ manifest = manifest, heroVisible = heroVisible }),
    inputKey = INPUT_KEY,
    render = renderBag,
    mapInput = mapBagInput,
  }
end

---@param manifest table<string, unknown> the validated bag presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
local function withManifest(manifest)
  assert(type(manifest) == "table", "the bag interface requires its validated manifest")

  local set = {}

  -- Completes a measured production context with helper-derived surface
  -- selections. The manifest rides this closure; the effective nativeLike
  -- entry (including an override) backs the pair fallback below.
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
      nativeLikeInterface = context.nativeLikeInterface or set.nativeLike,
    }
  end

  -- DualDisplay: hero on the world surface, interaction on auxiliary. The
  -- hero may use the default four-edge crop budget only to cover its own
  -- display; the edge-reaching lower pane never crops. Each underfilled
  -- physical pane carries its own complete outer frame.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local _ = view
    local complete = completeContext(context)
    local geometry = ApplicationLayout.nativeDual(complete, HERO_NATIVE, INTERACTION_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  -- NativeLike: only the interaction pane with the canonical description
  -- fallback carrying the compact information the hidden hero would show.
  -- A covered target stays unframed; an underfilled one refits as a
  -- complete decorated box with zero crop.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLike(context, view)
    local _ = view
    local complete = completeContext(context)
    local geometry = ApplicationLayout.coverOrFrame(complete, INTERACTION_NATIVE, { maxOverdraw = ZERO_CROP })
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, false, {
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end
  set.nativeLike = nativeLike

  -- Wide: hero left, interaction right, one shared integer scale with no
  -- gap and one frame around the common envelope. A pair that cannot fit
  -- 1x falls back to the effective nativeLike entry without changing the
  -- measured configuration.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wide(context, view)
    local complete = completeContext(context)
    local geometry = ApplicationLayout.sideBySide(complete, HERO_NATIVE, INTERACTION_NATIVE)
    if geometry == nil then
      return complete.nativeLikeInterface(complete, view)
    end
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  -- Tall: hero above, interaction below, one shared integer scale with no
  -- gap and one fitted frame around the common envelope, with the same 1x
  -- fallback as wide.
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tall(context, view)
    local complete = completeContext(context)
    local geometry = ApplicationLayout.stacked(complete, HERO_NATIVE, INTERACTION_NATIVE)
    if geometry == nil then
      return complete.nativeLikeInterface(complete, view)
    end
    local hero = geometry.placements[HERO_NATIVE.id]
    local interaction = geometry.placements[INTERACTION_NATIVE.id]
    if hero == nil or interaction == nil then
      return inactivePlan()
    end
    return bagPlan(manifest, true, {
      { id = HERO_NATIVE.id, placement = hero, interactive = false },
      { id = INTERACTION_NATIVE.id, placement = interaction, interactive = true },
    }, geometry.frames or {})
  end

  set.dualDisplay = dualDisplay
  set.wide = wide
  set.tall = tall
  return set
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- Merges an optional per-case override into the complete default set bound
-- to the validated manifest: only the four function fields merge, unknown
-- keys and non-functions fail at composition. The gameplay controller
-- instance never changes.
---@param overrides table<string, unknown>?
---@param manifest table<string, unknown> the validated bag presentation manifest
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function BagInterface.withOverrides(overrides, manifest)
  local set = withManifest(manifest)
  if overrides ~= nil then
    assert(type(overrides) == "table", "the bag overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown bag override case " .. tostring(key))
      assert(type(fn) == "function", "the bag override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return BagInterface
