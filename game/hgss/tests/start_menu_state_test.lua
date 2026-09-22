-- StartMenuState ownership: the per-open wrapper binds the existing
-- gameplay controller to one presentation session. Resolution happens
-- before mapping and after the controller update; the published status
-- carries the controller snapshot plus presentation=plan; results forward
-- unchanged; disposal releases both exactly once.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local function startMenuState()
  local ok, module = pcall(require, "game.hgss.src.field.StartMenuState")
  Assert.isTrue(ok, "the Start Menu must own its controller/presentation wrapper")
  return module
end

local function manifest()
  return FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest())
end

local function entries()
  return {
    {
      id = "vanilla.save",
      targetApplication = "saving",
      actionKind = "field_action",
      displayPosition = 5,
    },
  }
end

local function interactive()
  local ui = manifest()
  return assert(ui.startMenu.interactive, "the fixture must carry the generated interactive record")
end

local function measurement(width, height)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "test:" .. width .. "x" .. height,
  }
end

local function options(overrides)
  overrides = overrides or {}
  return {
    entries = entries(),
    interactive = interactive(),
    rememberedActionId = nil,
    measureDisplay = overrides.measureDisplay or function()
      return measurement(640, 480)
    end,
    windowState = overrides.windowState or { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } },
    overrides = overrides.overrides,
  }
end

local function bodyPlacement(status)
  local plan = assert(status.presentation, "the wrapper must publish its presentation plan")
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
    if pane.interactive then
      return assert(pane.placement, "the body pane must carry its placement")
    end
  end
  error("the plan must carry an interactive body pane", 0)
end

function T.tests.construction_resolves_the_initial_plan_beside_controller_state()
  local state = startMenuState().new(options())
  local status = state:status()
  Assert.isTrue(status.open, "the wrapper starts open with its controller")
  Assert.notNil(status.presentation, "status carries presentation=plan beside semantic fields")
  Assert.notNil(bodyPlacement(status), "the initial plan places the canonical body")
  Assert.isNil(state:takeResult(), "no result before input")
  state:dispose()
end

function T.tests.body_pointer_input_maps_once_through_the_published_plan()
  local state = startMenuState().new(options())
  local placement = bodyPlacement(state:status())
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, 126, 78)
  state:updateFixed({
    { type = "pointer_down", pointerId = "touch:1", x = hostX, y = hostY },
    { type = "pointer_up", pointerId = "touch:1", x = hostX, y = hostY },
  })
  local result = assert(state:takeResult(), "a body press must produce a result")
  Assert.equal(result.kind, "field_action", "the controller result forwards unchanged")
  Assert.equal(result.actionId, "vanilla.save", "the action identity survives the wrapper")
  state:dispose()
end

function T.tests.a_press_held_across_reflow_never_activates()
  local width, current = 640, nil
  current = measurement(width, 480)
  local state = startMenuState().new(options({
    measureDisplay = function()
      return current
    end,
  }))
  local placement = bodyPlacement(state:status())
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, 126, 78)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = hostX, y = hostY } })
  current = measurement(800, 600)
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = hostX, y = hostY } })
  Assert.isNil(state:takeResult(), "the stale release must not activate")
  Assert.isTrue(state:status().open, "the menu stays open after a cancelled press")
  state:dispose()
end

function T.tests.cancellation_delegates_to_the_session_and_controller()
  local state = startMenuState().new(options())
  local placement = bodyPlacement(state:status())
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, 126, 78)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = hostX, y = hostY } })
  state:cancelPointerCapture()
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = hostX, y = hostY } })
  Assert.isNil(state:takeResult(), "a cancelled press must not activate")
  state:dispose()
end

-- A session-construction failure inside the protected override/session
-- closure must surface the original diagnostic after controller cleanup:
-- an invalid override value fails with its own assertion, not nil, and a
-- later valid construction still succeeds.
function T.tests.session_construction_failure_rethrows_the_original_diagnostic()
  local StartMenuState = startMenuState()
  local ok, err = pcall(function()
    return StartMenuState.new(options({ overrides = { wide = 42 } }))
  end)
  Assert.isTrue(ok == false, "an invalid override must fail wrapper construction")
  Assert.isTrue(
    tostring(err):find("must be a function", 1, true) ~= nil,
    "construction must surface the original override diagnostic, got: " .. tostring(err)
  )
  local state = StartMenuState.new(options())
  Assert.notNil(state:status().presentation, "a later valid construction still succeeds")
  state:dispose()
end

function T.tests.construction_is_failure_safe_and_disposal_is_exactly_once()
  local StartMenuState = startMenuState()
  Assert.throws(function()
    StartMenuState.new(options({
      measureDisplay = function()
        return nil
      end,
    }))
  end, "a missing display measurement fails wrapper construction")
  local state = StartMenuState.new(options())
  state:dispose()
  state:dispose()
  Assert.isNil(state:takeResult(), "no result is reported after disposal")
end

return T
