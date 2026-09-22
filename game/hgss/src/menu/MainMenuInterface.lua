-- The startup Main Menu's function-selected interface over the shared
-- responsive placement. Every display case resolves the same fullscreen
-- interface on the primary/world usable surface: the density rule picks one
-- integer physical-pixel scale, the logical viewport feeds the canonical
-- Main Menu geometry, and a complete 256x192 viewport with fractional
-- fallback keeps controls reachable on tiny hosts. Dual auxiliaries
-- receive only the neutral background, never a duplicate save menu. A
-- per-case override replaces the whole render/input pair, never a mode
-- token. Resolvers require the measured context production sessions
-- supply; helper-derived surface selections fill the remaining fields.

local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local PixelScale = require("libs.ui.src.PixelScale")

---@class MainMenuInterface
local MainMenuInterface = {}

local PANE_ID = "content"
local INPUT_KEY = "main-menu"
local DENSITY_WIDTH = 320
local DENSITY_HEIGHT = 240
local MAX_DENSITY_SCALE = 3
local FALLBACK_WIDTH = 256
local FALLBACK_HEIGHT = 192

local function clampScale(value)
  return math.max(1, math.min(MAX_DENSITY_SCALE, value))
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan
local function renderMenu(resources, view, plan)
  local renderer = assert(resources.renderer, "the menu render borrows its renderer")
  renderer:draw(view, plan)
end

-- The default mapper emits one semantic hit per content press: the shared
-- layout hit test with modal precedence over the resolved logical
-- geometry. Scroll, move and release carry no menu action; the
-- session owns capture and cancellation around this mapper.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan ApplicationPlan the resolved interface plan
---@return table<string, string|nil>? the semantic hit, or nil when the press targets nothing actionable
local function mapMenuInput(event, view, plan)
  if event.type ~= "pointer_down" then
    return nil
  end
  if event.outside == true then
    return nil
  end
  local content = assert(plan.content, "the menu plan carries its logical content")
  local layout = assert(content.layout, "the menu content carries its computed geometry")
  local hit = MainMenuLayout.hitTest(layout, view, event.x, event.y)
  if hit.region == nil then
    return nil
  end
  return hit
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
    inputKey = "main-menu-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Completes a measured production context with helper-derived surface
-- selections. The session always supplies the measurement; direct unit
-- callers must supply a complete context as well.
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
    nativeLikeInterface = context.nativeLikeInterface or MainMenuInterface.resolve,
  }
end

---@param rect table<string, number>
---@return table<string, number>
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- Responsive fullscreen menu for every display case: one primary content
-- pane over the owned target region. Dual auxiliaries join coverage with
-- the neutral background; the save interface never duplicates there.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function MainMenuInterface.resolve(context, view)
  assert(type(view) == "table", "menu resolution needs the current semantic snapshot")
  local complete = completeContext(context)
  local primary = assert(complete.primary, "menu resolution needs its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return inactivePlan()
  end
  local measurement = complete.measurement
  local ratio = measurement.pixelRatio or 1
  assert(type(ratio) == "number" and ratio > 0, "menu resolution needs a positive pixel ratio")
  local physicalWidth = usable.width * ratio
  local physicalHeight = usable.height * ratio
  local placement
  local viewportWidth
  local viewportHeight
  if physicalWidth < FALLBACK_WIDTH or physicalHeight < FALLBACK_HEIGHT then
    local downscale = math.min(usable.width / FALLBACK_WIDTH, usable.height / FALLBACK_HEIGHT)
    local frameWidth = FALLBACK_WIDTH * downscale
    local frameHeight = FALLBACK_HEIGHT * downscale
    local frameX = usable.x + (usable.width - frameWidth) / 2
    local frameY = usable.y + (usable.height - frameHeight) / 2
    placement = {
      frame = { x = frameX, y = frameY, width = frameWidth, height = frameHeight },
      origin = { x = frameX, y = frameY },
      scale = downscale,
      logicalWidth = FALLBACK_WIDTH,
      logicalHeight = FALLBACK_HEIGHT,
      clipRect = {
        x = math.max(frameX, usable.x),
        y = math.max(frameY, usable.y),
        width = math.min(frameX + frameWidth, usable.x + usable.width) - math.max(frameX, usable.x),
        height = math.min(frameY + frameHeight, usable.y + usable.height) - math.max(frameY, usable.y),
      },
      pixelScale = downscale * ratio,
      pixelRatio = ratio,
      visibleLogicalRect = { x = 0, y = 0, width = FALLBACK_WIDTH, height = FALLBACK_HEIGHT },
      crop = { left = 0, right = 0, top = 0, bottom = 0 },
    }
    viewportWidth = FALLBACK_WIDTH
    viewportHeight = FALLBACK_HEIGHT
  else
    local density = clampScale(math.floor(math.min(physicalWidth / DENSITY_WIDTH, physicalHeight / DENSITY_HEIGHT)))
    local covered = PixelScale.cover(usable, density, ratio)
    placement = covered.placement
    viewportWidth = covered.logicalViewport.width
    viewportHeight = covered.logicalViewport.height
  end
  local layout = MainMenuLayout.compute(
    assert(view.globalActions, "menu resolution needs its global actions"),
    assert(view.saves, "menu resolution needs its saves"),
    assert(view.focus, "menu resolution needs its focus"),
    viewportWidth,
    viewportHeight,
    view.scrollOffset,
    view.popup,
    view.confirmation,
    type(view.catalogError) == "string" and view.catalogError ~= ""
  )
  -- The startup surface owns no paused field beneath it, so the menu keeps
  -- painting its own host background regions leaf-locally through content.
  local hostBackgrounds = { copyRect(usable) }
  local secondary = complete.secondary
  if secondary ~= nil and secondary.usableBounds ~= nil then
    hostBackgrounds[#hostBackgrounds + 1] = copyRect(secondary.usableBounds)
  end
  return {
    panes = { { id = PANE_ID, placement = placement, interactive = true } },
    frames = {},
    content = { layout = layout, width = viewportWidth, height = viewportHeight, hostBackgrounds = hostBackgrounds },
    inputKey = INPUT_KEY,
    render = renderMenu,
    mapInput = mapMenuInput,
  }
end

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

-- One responsive function behind every display case: the startup menu is
-- fullscreen on the primary surface, never a field window.
MainMenuInterface.dualDisplay = MainMenuInterface.resolve
MainMenuInterface.nativeLike = MainMenuInterface.resolve
MainMenuInterface.wide = MainMenuInterface.resolve
MainMenuInterface.tall = MainMenuInterface.resolve

-- Merges an optional per-case override into the complete default set:
-- only the four function fields merge, unknown keys and non-functions
-- fail at composition. The gameplay controller instance never changes.
---@param overrides table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function MainMenuInterface.withOverrides(overrides)
  local set = {
    dualDisplay = MainMenuInterface.resolve,
    nativeLike = MainMenuInterface.resolve,
    wide = MainMenuInterface.resolve,
    tall = MainMenuInterface.resolve,
  }
  if overrides ~= nil then
    assert(type(overrides) == "table", "the menu overrides must be a record")
    for key, fn in pairs(overrides) do
      local known = false
      for _, case in ipairs(CASE_KEYS) do
        if key == case then
          known = true
          break
        end
      end
      assert(known, "unknown menu override case " .. tostring(key))
      assert(type(fn) == "function", "the menu override for " .. tostring(key) .. " must be a function")
      set[key] = fn
    end
  end
  return set
end

return MainMenuInterface
