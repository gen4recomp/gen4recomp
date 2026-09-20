-- Shared presentation input lifetime: pointer batches map in event order,
-- a press that leaves its visible clip cancels instead of activating
-- something stale, and a failed candidate never replaces the published
-- plan. Cancellation reaches the gameplay controller as an ordered
-- pointer_cancel event the controller must absorb without changing
-- selection; the session owns capture, header drags, and focus loss.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")

local T = { tests = {} }

-- The shared session owns capture and cancellation; per-application pointer
-- math cannot provide it.
local function sharedSession()
  local ok, module = pcall(require, "game.hgss.src.ui.ApplicationPresentation")
  Assert.isTrue(ok, "one shared session must own pointer capture and ordered cancellation")
  return module
end

local function manifest()
  return FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest())
end

local function controller()
  local ui = manifest()
  local interactive = assert(ui.startMenu.interactive, "the fixture must carry the generated interactive record")
  return StartMenuController.new({
    entries = {
      {
        id = "vanilla.save",
        targetApplication = "saving",
        displayPosition = 5,
      },
    },
    interactive = interactive,
  })
end

function T.tests.cancellation_reaches_the_controller_in_batch_order_without_changing_selection()
  local menu = controller()
  local before = menu:status()
  Assert.isTrue(before.open, "the menu must start open")
  local selected = before.selectedPosition
  menu:updateFixed({
    { type = "pointer_down", pointerId = "touch:1", x = 120, y = 70 },
    { type = "pointer_cancel", pointerId = "touch:1" },
  })
  local after = menu:status()
  Assert.isTrue(after.open, "cancellation must not close the menu")
  Assert.equal(after.selectedPosition, selected, "cancellation must not move selection")
  Assert.isNil(menu:takeResult(), "cancellation must not produce a result")
end

function T.tests.a_press_cancelled_by_reflow_never_activates_on_release()
  local menu = controller()
  menu:updateFixed({
    { type = "pointer_down", pointerId = "touch:1", x = 120, y = 70 },
  })
  -- Geometry change invalidates the held press before any later release can
  -- activate something: the existing capture contract clears the hold.
  menu:cancelPointerCapture()
  menu:updateFixed({
    { type = "pointer_up", pointerId = "touch:1", x = 120, y = 70 },
  })
  Assert.isNil(menu:takeResult(), "a release after cancellation must not activate")
  Assert.isTrue(menu:status().open, "the menu must stay open after a cancelled press")
end

local function stubMeasurement(width, height, signature)
  local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
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
    signature = signature or ("stub:" .. width .. "x" .. height),
  }
end

local function stubInterfaces()
  local render = function(_, _, _) end
  local map = function(event, _, _)
    return event
  end
  local full = function(_, _)
    return {
      panes = {
        {
          id = "content",
          placement = {
            frame = { x = 0, y = 0, width = 256, height = 192 },
            origin = { x = 0, y = 0 },
            scale = 1,
            logicalWidth = 256,
            logicalHeight = 192,
            clipRect = { x = 0, y = 0, width = 256, height = 192 },
          },
          interactive = true,
        },
      },
      content = {},
      inputKey = "stub",
      render = render,
      mapInput = map,
      coverage = {},
      backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
    }
  end
  return { dualDisplay = full, nativeLike = full, wide = full, tall = full }
end

local function stubSession()
  local sessionModule = sharedSession()
  return sessionModule.new(stubInterfaces(), { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } })
end

function T.tests.equivalent_fresh_resolutions_preserve_capture()
  local session = stubSession()
  local view = {}
  session:resolve(stubMeasurement(256, 192), view)
  local mapped = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } }, view)
  Assert.equal(#mapped, 1, "the down captures its pane")
  session:resolve(stubMeasurement(256, 192), view)
  local release = session:mapInput({ { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } }, view)
  Assert.equal(#release, 1, "an equivalent re-resolution never cancels the held press")
  Assert.equal(release[1].type, "pointer_up", "the release still maps")
end

function T.tests.plan_callbacks_keep_stable_identities_across_resolves()
  local session = stubSession()
  local view = {}
  local first = session:resolve(stubMeasurement(256, 192), view)
  local second = session:resolve(stubMeasurement(256, 192), view)
  Assert.isTrue(first.render == second.render, "render stays a stable reference")
  Assert.isTrue(first.mapInput == second.mapInput, "input mapping stays a stable reference")
  Assert.deepEqual(session:mapInput({}, view), {}, "no cancellation without a geometry change")
end

function T.tests.failed_measurement_validation_keeps_the_previous_plan()
  local session = stubSession()
  local view = {}
  local plan = session:resolve(stubMeasurement(256, 192), view)
  local bad = stubMeasurement(256, 192)
  bad.topology, bad.signature = nil, nil
  Assert.throws(function()
    session:resolve(bad, view)
  end, "a measurement without surfaces fails validation")
  Assert.isTrue(session:plan() == plan, "the failed candidate never replaces the published plan")
end

function T.tests.unpresentable_space_publishes_an_inactive_plan()
  local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
  local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
  local sessionModule = sharedSession()
  local session = sessionModule.new(
    StartMenuInterface.withOverrides(nil),
    { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } }
  )
  local measurement = {
    width = 100,
    height = 100,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 100, height = 100 },
      role = "world",
      touch = true,
      occupiedRegions = { { x = 0, y = 0, width = 100, height = 100 } },
    }),
    pixelRatio = 1,
    signature = "occluded",
  }
  local plan = session:resolve(measurement, {})
  Assert.deepEqual(plan.panes, {}, "occlusion publishes no pointer targets")
  Assert.deepEqual(
    session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } }, {}),
    {},
    "pointer input cannot advance through missing controls"
  )
  local semantic = session:mapInput({ { type = "cancel" } }, {})
  Assert.equal(#semantic, 1, "semantic cancellation remains deliverable")
  Assert.equal(semantic[1].type, "cancel")
end

local function windowedInterfaces(spy, spoil)
  local render = function(_, _, _) end
  local map = function(event, _, _)
    spy.calls[#spy.calls + 1] = event
    return event
  end
  local function resolver(context, _)
    local position = context.windowPosition
    local originX = 100 + position.x * 200
    local originY = 100 + position.y * 100
    local outer = {
      frame = { x = originX, y = originY, width = 516, height = 412 },
      origin = { x = originX, y = originY },
      scale = 2,
      logicalWidth = 258,
      logicalHeight = 206,
      clipRect = { x = originX, y = originY, width = 516, height = 412 },
    }
    local body = {
      frame = { x = originX + 2, y = originY + 26, width = 512, height = 384 },
      origin = { x = originX + 2, y = originY + 26 },
      scale = 2,
      logicalWidth = 256,
      logicalHeight = 192,
      clipRect = { x = originX + 2, y = originY + 26, width = 512, height = 384 },
    }
    if spoil.mode == "origin" then
      outer.origin = { x = 0 / 0, y = originY }
    elseif spoil.mode == "clip" then
      outer.clipRect = { x = originX, y = originY, width = -4, height = 10 }
    elseif spoil.mode == "logical" then
      outer.logicalWidth = 0
    elseif spoil.mode == "pane" then
      body.logicalHeight = 0 / 0
    elseif spoil.mode == "window" then
      outer.scale = 0
    end
    return {
      panes = { { id = "content", placement = body, interactive = true } },
      content = {},
      inputKey = "windowed-stub",
      render = render,
      mapInput = map,
      coverage = {},
      backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
      window = {
        outer = outer,
        body = body,
        grabRect = { x = originX + 2, y = originY + 2, width = 512, height = 24 },
      },
    }
  end
  return { dualDisplay = resolver, nativeLike = resolver, wide = resolver, tall = resolver }
end

local function windowedSession(spy, spoil, windowState)
  local sessionModule = sharedSession()
  return sessionModule.new(windowedInterfaces(spy, spoil), windowState)
end

local function freshWindowState()
  return { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } }
end

local function grabCenter(plan)
  local grab = assert(plan.window, "the stub publishes a window").grabRect
  return grab.x + grab.width / 2, grab.y + grab.height / 2
end

function T.tests.header_drag_survives_consecutive_self_reflows()
  local spy = { calls = {} }
  local spoil = {}
  local windowState = freshWindowState()
  local session = windowedSession(spy, spoil, windowState)
  local view = {}
  local measurement = stubMeasurement(1280, 720)
  local plan = session:resolve(measurement, view)
  local startX, startY = grabCenter(plan)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = startX, y = startY } }, view)
  Assert.equal(#spy.calls, 0, "a header press never reaches the leaf mapper")
  local firstX = startX + 76
  session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = firstX, y = startY } }, view)
  Assert.equal(#spy.calls, 0, "a header move never reaches the leaf mapper")
  local afterFirst = windowState.wide.x
  Assert.isTrue(afterFirst > 0.5, "the first move contributes to the drag")
  session:resolve(measurement, view)
  local secondX = firstX + 76
  local moved = session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = secondX, y = startY } }, view)
  Assert.deepEqual(moved, {}, "the second move stays inside the retained header capture")
  Assert.isTrue(windowState.wide.x > afterFirst, "the second move contributes to the same gesture")
  Assert.equal(#spy.calls, 0, "neither move reaches the leaf mapper")
  local released = session:mapInput({ { type = "pointer_up", pointerId = "mouse:1", x = secondX, y = startY } }, view)
  Assert.deepEqual(released, {}, "a header release ends capture without leaf input")
  local fresh = session:resolve(measurement, view)
  local body = assert(fresh.window, "the stub still publishes a window").body.frame
  local mapped =
    session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = body.x + 256, y = body.y + 192 } }, view)
  Assert.equal(#mapped, 1, "a fresh press works after the drag ends")
  Assert.equal(#spy.calls, 1, "content input still reaches the leaf mapper")
end

function T.tests.external_reflow_cancels_an_active_header_drag()
  local spy = { calls = {} }
  local spoil = {}
  local windowState = freshWindowState()
  local session = windowedSession(spy, spoil, windowState)
  local view = {}
  local plan = session:resolve(stubMeasurement(1280, 720), view)
  local startX, startY = grabCenter(plan)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = startX, y = startY } }, view)
  -- No move yet, so the re-resolution is geometrically identical: only the
  -- changed measurement signature may terminate the held press.
  local held = windowState.wide.x
  session:resolve(stubMeasurement(1920, 1080), view)
  local stale =
    session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = startX + 152, y = startY } }, view)
  Assert.equal(windowState.wide.x, held, "a stale move cannot continue the old drag")
  Assert.deepEqual(
    session:mapInput({ { type = "pointer_up", pointerId = "mouse:1", x = startX + 152, y = startY } }, view),
    {},
    "a stale release activates nothing"
  )
  Assert.deepEqual(stale, {}, "the stale move maps to nothing")
  local resettled = session:resolve(stubMeasurement(1920, 1080), view)
  local freshX, freshY = grabCenter(resettled)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = freshX, y = freshY } }, view)
  session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = freshX + 76, y = freshY } }, view)
  Assert.isTrue(windowState.wide.x > held, "a fresh press starts a new drag")
  Assert.equal(#spy.calls, 0, "header input never reaches the leaf mapper")
end

function T.tests.a_failed_candidate_keeps_the_previous_plan_and_window_memory()
  local spy = { calls = {} }
  local spoil = {}
  local windowState = freshWindowState()
  local session = windowedSession(spy, spoil, windowState)
  local view = {}
  local measurement = stubMeasurement(1280, 720)
  local plan = session:resolve(measurement, view)
  local beforeX, beforeY = windowState.wide.x, windowState.wide.y
  for _, mode in ipairs({ "origin", "clip", "logical", "pane", "window" }) do
    spoil.mode = mode
    Assert.throws(function()
      session:resolve(measurement, view)
    end, "a malformed " .. mode .. " placement fails before publication")
    Assert.isTrue(session:plan() == plan, "the failed candidate never replaces the published plan")
  end
  Assert.deepEqual(windowState.wide, { x = beforeX, y = beforeY }, "a failed resolution never touches window memory")
  spoil.mode = nil
  Assert.notNil(session:resolve(measurement, view), "the session still resolves after rejected candidates")
end

return T
