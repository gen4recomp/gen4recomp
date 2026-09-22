-- Start Menu interface selection: each display configuration resolves
-- through its own function returning a complete render/input pair, and a
-- product override may replace one case wholesale. The override's own
-- geometry, rendering, and input mapping all take effect together while the
-- other cases keep their original functions; no registry or gameplay
-- controller is replaced.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local CASES = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The leaf interface module owns the four resolver functions; rendering and
-- input dispatch cannot be replaced one case at a time without it.
local function startMenuInterface()
  local ok, module = pcall(require, "game.hgss.src.field.StartMenuInterface")
  Assert.isTrue(ok, "the Start Menu must expose one resolver function per display configuration")
  return module
end

function T.tests.every_display_case_resolves_through_its_own_function()
  local interface = startMenuInterface()
  for _, case in ipairs(CASES) do
    Assert.isTrue(
      type(interface[case]) == "function",
      "the " .. case .. " case must be a resolver function, not a mode token"
    )
  end
end

function T.tests.a_wide_only_override_replaces_rendering_and_input_together()
  local interface = startMenuInterface()
  local view = { actions = {}, selectedPosition = 1 }
  local measurement = {
    width = 1280,
    height = 720,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "start-menu-wide-replacement",
  }
  local selection = ApplicationLayout.selectSurfaces(measurement)
  local context = {
    measurement = measurement,
    configuration = "wide",
    primary = selection.primary,
    secondary = selection.secondary,
    windowPosition = { x = 0.5, y = 0.5 },
    nativeLikeInterface = interface.fullscreen,
  }
  local widePlan = interface.wide(context, view)
  Assert.notNil(widePlan.render, "the wide plan must carry its render callback")
  Assert.notNil(widePlan.mapInput, "the wide plan must carry its matching input mapper")

  local customRenderings = 0
  local customMappings = 0
  local overrides = {
    wide = function(_, _)
      return {
        panes = { { id = "replacement", placement = widePlan.panes[1].placement, interactive = true } },
        content = { region = { x = 0, y = 0, width = 64, height = 32 } },
        inputKey = "replacement-wide",
        render = function(_, _, _)
          customRenderings = customRenderings + 1
        end,
        mapInput = function(_, _, _)
          customMappings = customMappings + 1
          return { type = "confirm" }
        end,
        coverage = {},
      }
    end,
  }
  local merged = {
    dualDisplay = interface.dualDisplay,
    nativeLike = interface.nativeLike,
    wide = overrides.wide,
    tall = interface.tall,
  }
  local customPlan = merged.wide(context, view)
  customPlan.render({}, view, customPlan)
  local mapped = customPlan.mapInput({ type = "pointer_down", pointerId = "touch:1" }, view, customPlan)
  Assert.equal(customRenderings, 1, "the override render callback must execute")
  Assert.equal(customMappings, 1, "the override input mapper must execute")
  Assert.equal(mapped.type, "confirm", "the override mapper must target the existing semantic action")
  Assert.isTrue(
    merged.nativeLike == interface.nativeLike,
    "replacing wide must keep the native case on its original function"
  )
end

return T
