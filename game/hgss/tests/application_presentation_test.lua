-- Shared presentation input lifetime: pointer batches map in event order,
-- a press that leaves its visible clip cancels instead of activating
-- something stale, and a failed candidate never replaces the published
-- plan. Cancellation reaches the gameplay controller as an ordered
-- pointer_cancel event the controller must absorb without changing
-- selection; the session owns content capture and focus loss.

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
      frames = {},
    }
  end
  return { dualDisplay = full, nativeLike = full, wide = full, tall = full }
end

local function stubSession()
  local sessionModule = sharedSession()
  return sessionModule.new(stubInterfaces())
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
  local session = sessionModule.new(StartMenuInterface.withOverrides(nil))
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

-- Static content fixtures: one canonical interactive pane with no window
-- memory, title strip, or grab geometry.
local function staticInterfaces(spy, spoil)
  local render = function(_, _, _) end
  local map = function(event, _, _)
    spy.calls[#spy.calls + 1] = event
    return event
  end
  local function resolver(_, _)
    local body = {
      frame = { x = 100, y = 100, width = 512, height = 384 },
      origin = { x = 100, y = 100 },
      scale = 2,
      logicalWidth = 256,
      logicalHeight = 192,
      clipRect = { x = 100, y = 100, width = 512, height = 384 },
    }
    local frames = {}
    if spoil.mode == "origin" then
      body.origin = { x = 0 / 0, y = 100 }
    elseif spoil.mode == "clip" then
      body.clipRect = { x = 100, y = 100, width = -4, height = 10 }
    elseif spoil.mode == "logical" then
      body.logicalWidth = 0
    elseif spoil.mode == "pane" then
      body.logicalHeight = 0 / 0
    elseif spoil.mode == "frame" then
      frames = {
        {
          placement = {
            frame = { x = 0, y = 0, width = -4, height = 10 },
            origin = { x = 0, y = 0 },
            scale = 1,
            logicalWidth = 1,
            logicalHeight = 1,
            clipRect = { x = 0, y = 0, width = -4, height = 10 },
          },
          contentBox = { x = 0, y = 0, width = 1, height = 1 },
        },
      }
    end
    return {
      panes = { { id = "content", placement = body, interactive = true } },
      content = {},
      inputKey = "static-stub",
      render = render,
      mapInput = map,
      frames = frames,
    }
  end
  return { dualDisplay = resolver, nativeLike = resolver, wide = resolver, tall = resolver }
end

local function staticSession(spy, spoil)
  local sessionModule = sharedSession()
  return sessionModule.new(staticInterfaces(spy, spoil))
end

-- Static content fixtures without any transition coverage: one canonical
-- interactive pane and no fade region. Plans publish, draw, and map input
-- with no host-owned fade metadata.
local function coveragelessInterfaces()
  local render = function(_, _, _) end
  local map = function(event, _, _)
    return event
  end
  local function resolver(_, _)
    return {
      panes = {
        {
          id = "content",
          placement = {
            frame = { x = 100, y = 100, width = 512, height = 384 },
            origin = { x = 100, y = 100 },
            scale = 2,
            logicalWidth = 256,
            logicalHeight = 192,
            clipRect = { x = 100, y = 100, width = 512, height = 384 },
          },
          interactive = true,
        },
      },
      content = {},
      inputKey = "static-stub",
      render = render,
      mapInput = map,
      frames = {},
    }
  end
  return { dualDisplay = resolver, nativeLike = resolver, wide = resolver, tall = resolver }
end

-- Application plans carry no transition coverage: a candidate without the
-- retired region still validates and publishes.
function T.tests.plans_publish_without_transition_coverage()
  local sessionModule = sharedSession()
  local session = sessionModule.new(coveragelessInterfaces())
  local plan = session:resolve(stubMeasurement(1280, 720), {})
  Assert.equal(#plan.panes, 1, "the coverageless candidate publishes its pane")
  local untyped = plan --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "no transition coverage remains on the plan")
end

function T.tests.content_capture_survives_consecutive_equivalent_reflows()
  local spy = { calls = {} }
  local spoil = {}
  local session = staticSession(spy, spoil)
  local view = {}
  local measurement = stubMeasurement(1280, 720)
  session:resolve(measurement, view)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = 200, y = 200 } }, view)
  Assert.equal(#spy.calls, 1, "a content press reaches the leaf mapper")
  session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = 276, y = 200 } }, view)
  Assert.equal(#spy.calls, 2, "a content move reaches the leaf mapper")
  session:resolve(measurement, view)
  local moved = session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = 352, y = 200 } }, view)
  Assert.equal(#spy.calls, 3, "the move stays inside the retained content capture")
  Assert.equal(moved[1].type, "pointer_move", "the second move still maps")
  local released = session:mapInput({ { type = "pointer_up", pointerId = "mouse:1", x = 352, y = 200 } }, view)
  Assert.equal(released[1].type, "pointer_up", "a content release ends capture with leaf input")
  Assert.equal(#spy.calls, 4, "content input still reaches the leaf mapper")
end

function T.tests.external_reflow_cancels_an_active_content_press()
  local spy = { calls = {} }
  local spoil = {}
  local session = staticSession(spy, spoil)
  local view = {}
  session:resolve(stubMeasurement(1280, 720), view)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = 200, y = 200 } }, view)
  Assert.equal(#spy.calls, 1, "a content press reaches the leaf mapper")
  -- No move yet, so the re-resolution is geometrically identical: only the
  -- changed measurement signature may terminate the held press.
  session:resolve(stubMeasurement(1920, 1080), view)
  local cancelled = session:mapInput({}, view)
  Assert.equal(#cancelled, 1, "the reflow queues cancellation for the held press")
  Assert.equal(cancelled[1].type, "pointer_cancel", "the queued event cancels the held press")
  local stale = session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = 352, y = 200 } }, view)
  Assert.deepEqual(stale, {}, "the stale move maps to nothing")
  Assert.deepEqual(
    session:mapInput({ { type = "pointer_up", pointerId = "mouse:1", x = 352, y = 200 } }, view),
    {},
    "a stale release activates nothing"
  )
  session:resolve(stubMeasurement(1920, 1080), view)
  session:mapInput({ { type = "pointer_down", pointerId = "mouse:1", x = 200, y = 200 } }, view)
  session:mapInput({ { type = "pointer_move", pointerId = "mouse:1", x = 276, y = 200 } }, view)
  Assert.isTrue(#spy.calls >= 3, "a fresh press starts a new content gesture")
end

function T.tests.a_failed_candidate_keeps_the_previous_plan()
  local spy = { calls = {} }
  local spoil = {}
  local session = staticSession(spy, spoil)
  local view = {}
  local measurement = stubMeasurement(1280, 720)
  local plan = session:resolve(measurement, view)
  for _, mode in ipairs({ "origin", "clip", "logical", "pane", "frame" }) do
    spoil.mode = mode
    Assert.throws(function()
      session:resolve(measurement, view)
    end, "a malformed " .. mode .. " placement fails before publication")
    Assert.isTrue(session:plan() == plan, "the failed candidate never replaces the published plan")
  end
  spoil.mode = nil
  Assert.notNil(session:resolve(measurement, view), "the session still resolves after rejected candidates")
end

local function staticStubInterfaces()
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
      frames = {},
      content = {},
      inputKey = "static-stub",
      render = render,
      mapInput = map,
    }
  end
  return { dualDisplay = full, nativeLike = full, wide = full, tall = full }
end

-- Static sessions borrow only the interface set: no caller-owned position
-- memory exists, and every plan carries frame geometry with no window,
-- settled background, or transition coverage contract.
function T.tests.static_session_publishes_frame_geometry_without_window_memory()
  local sessionModule = sharedSession()
  local session = sessionModule.new(staticStubInterfaces())
  local plan = session:resolve(stubMeasurement(1280, 720), {})
  Assert.isTrue(type(plan.frames) == "table", "the plan carries its frame list")
  local untyped = plan --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "the plan carries no transition coverage")
  Assert.isNil(untyped.window, "static plans carry no window")
  Assert.isNil(untyped.backgroundColor, "static plans carry no settled background color")
  Assert.isNil(untyped.coverage, "the renamed fade coverage leaves no legacy coverage field")
  local again = session:resolve(stubMeasurement(1280, 720), {})
  Assert.deepEqual(again.panes[1].placement.frame, plan.panes[1].placement.frame, "repeated resolves stay static")
end

-- Settled drawing only invokes the leaf render callback: nothing fills
-- the host around it.
function T.tests.settled_draw_invokes_leaf_render_without_host_chrome()
  local sessionModule = sharedSession()
  local session = sessionModule.new(staticStubInterfaces())
  local rendered = 0
  local plan = session:resolve(stubMeasurement(256, 192), {})
  plan.render = function()
    rendered = rendered + 1
  end
  local fills = 0
  local stubGraphics = {
    push = function(_) end,
    pop = function() end,
    setColor = function(_) end,
    rectangle = function(_)
      fills = fills + 1
    end,
  }
  sessionModule.draw(stubGraphics, {}, {}, plan)
  Assert.equal(rendered, 1, "settled draw invokes the leaf render exactly once")
  Assert.equal(fills, 0, "settled draw paints no host chrome")
end

-- Malformed frame geometry fails before publication and keeps the last
-- known-good plan.
function T.tests.malformed_frame_geometry_never_replaces_the_published_plan()
  local sessionModule = sharedSession()
  local good = staticStubInterfaces()
  local session = sessionModule.new(good)
  local view = {}
  local plan = session:resolve(stubMeasurement(256, 192), view)
  local spoilFrame = { armed = false }
  local function conditional(_, _)
    local frames = {}
    if spoilFrame.armed then
      frames = {
        {
          placement = { frame = { x = 0, y = 0, width = -4, height = 10 } },
          contentBox = { x = 0, y = 0, width = 1, height = 1 },
        },
      }
    end
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
      frames = frames,
      content = {},
      inputKey = "static-stub",
      render = function(_, _, _) end,
      mapInput = function(event, _, _)
        return event
      end,
    }
  end
  local conditionalInterfaces =
    { dualDisplay = conditional, nativeLike = conditional, wide = conditional, tall = conditional }
  local failing = sessionModule.new(conditionalInterfaces)
  failing:resolve(stubMeasurement(256, 192), view)
  local published = failing:plan()
  spoilFrame.armed = true
  Assert.throws(function()
    failing:resolve(stubMeasurement(640, 480), view)
  end, "a malformed frame placement fails before publication")
  Assert.isTrue(failing:plan() == published, "the failed candidate never replaces the published plan")
  Assert.isTrue(session:plan() == plan, "the valid session keeps its published plan")
end

-- Framed-application hit fixtures: one interactive content pane, one
-- noninteractive visual pane, and one decorative frame whose visible clip
-- extends past the content pane on every side. Geometry-only interior
-- classification must consume border and hero presses without leaf events.
local function framedInterfaces(spy)
  local render = function(_, _, _) end
  local map = function(event, _, _)
    spy.calls[#spy.calls + 1] = event
    return event
  end
  local function resolver(_, _)
    local body = {
      frame = { x = 100, y = 100, width = 256, height = 192 },
      origin = { x = 100, y = 100 },
      scale = 1,
      logicalWidth = 256,
      logicalHeight = 192,
      clipRect = { x = 100, y = 100, width = 256, height = 192 },
    }
    local hero = {
      frame = { x = 100, y = 300, width = 256, height = 96 },
      origin = { x = 100, y = 300 },
      scale = 1,
      logicalWidth = 256,
      logicalHeight = 96,
      clipRect = { x = 100, y = 300, width = 256, height = 96 },
    }
    local framePlacement = {
      frame = { x = 92, y = 76, width = 272, height = 232 },
      origin = { x = 92, y = 76 },
      scale = 1,
      logicalWidth = 272,
      logicalHeight = 232,
      clipRect = { x = 92, y = 76, width = 272, height = 232 },
    }
    return {
      panes = {
        { id = "content", placement = body, interactive = true },
        { id = "hero", placement = hero, interactive = false },
      },
      content = {},
      inputKey = "framed-stub",
      render = render,
      mapInput = map,
      frames = {
        { placement = framePlacement, contentBox = { x = 8, y = 24, width = 256, height = 192 } },
      },
    }
  end
  return { dualDisplay = resolver, nativeLike = resolver, wide = resolver, tall = resolver }
end

local function framedSession(spy)
  local sessionModule = sharedSession()
  local session = sessionModule.new(framedInterfaces(spy))
  session:resolve(stubMeasurement(512, 512), {})
  return session
end

function T.tests.a_press_on_the_decorative_frame_border_is_consumed_as_interior()
  local spy = { calls = {} }
  local session = framedSession(spy)
  local view = {}
  local mapped = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 94, y = 80 } }, view)
  Assert.deepEqual(mapped, {}, "a border press maps to no leaf event")
  Assert.equal(#spy.calls, 0, "a border press never reaches the leaf mapper")
  local release = session:mapInput({ { type = "pointer_up", pointerId = "touch:1", x = 94, y = 80 } }, view)
  Assert.deepEqual(release, {}, "a border press acquires no capture, so its release maps to nothing")
  local outside = session:mapInput({ { type = "pointer_down", pointerId = "touch:2", x = 10, y = 10 } }, view)
  Assert.equal(#outside, 1, "the interior press must not suppress a later true outside press")
  Assert.equal(outside[1].outside, true, "the later press still reaches the leaf as outside")
end

function T.tests.a_press_on_a_noninteractive_pane_is_consumed_as_interior()
  local spy = { calls = {} }
  local session = framedSession(spy)
  local mapped = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 150, y = 330 } }, {})
  Assert.deepEqual(mapped, {}, "a hero-pane press maps to no leaf event")
  Assert.equal(#spy.calls, 0, "a hero-pane press never reaches the leaf mapper")
end

function T.tests.a_press_outside_every_pane_and_frame_reaches_the_leaf_as_outside()
  local spy = { calls = {} }
  local session = framedSession(spy)
  local mapped = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } }, {})
  Assert.equal(#mapped, 1, "a true outside press reaches the leaf mapper")
  Assert.equal(mapped[1].outside, true, "the leaf sees the outside marker")
  Assert.equal(#spy.calls, 1, "the mapper records the outside press")
end

function T.tests.a_captured_move_leaving_its_pane_cancels_instead_of_dismissing()
  local spy = { calls = {} }
  local session = framedSession(spy)
  local view = {}
  local held = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = 150, y = 150 } }, view)
  Assert.equal(#held, 1, "content still captures its pane")
  local moved = session:mapInput({ { type = "pointer_move", pointerId = "touch:1", x = 10, y = 10 } }, view)
  Assert.equal(#moved, 1, "leaving the pane emits exactly one event")
  Assert.equal(moved[1].type, "pointer_cancel", "the gesture cancels rather than dismissing")
end

local function wideMenuSession()
  local sessionModule = sharedSession()
  local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
  local session = sessionModule.new(StartMenuInterface.withOverrides(nil))
  local plan = session:resolve(stubMeasurement(1280, 720), {})
  Assert.isTrue(#plan.frames >= 1, "the wide menu must publish its outer frame")
  return session, plan
end

---@param frame table<string, unknown>
---@param lx number
---@param ly number
---@return number hostX
---@return number hostY
local function frameLocalToHost(frame, lx, ly)
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local placement = assert(frame.placement, "the frame carries its placement")
  return LayoutGeometry.logicalToHost(placement, lx, ly)
end

-- A press on the production top frame band stays inert interior: the
-- band is decorative frame above the content box, outside the
-- interactive pane but inside the published frame placement.
function T.tests.a_press_on_the_top_frame_band_stays_interior()
  local session, plan = wideMenuSession()
  local frame = assert(plan.frames[1], "the wide menu carries its frame record")
  local contentBox = assert(frame.contentBox, "the frame carries its content box")
  local hx, hy =
    frameLocalToHost(frame, contentBox.x + contentBox.width / 4, contentBox.y - 8)
  local mapped = session:mapInput({ { type = "pointer_down", pointerId = "touch:1", x = hx, y = hy } }, {})
  Assert.deepEqual(mapped, {}, "a top-band press maps to no leaf event")
  local release = session:mapInput({ { type = "pointer_up", pointerId = "touch:1", x = hx, y = hy } }, {})
  Assert.deepEqual(release, {}, "a top-band press acquires no capture")
end

local function leafMeasurement(width, height)
  return stubMeasurement(width, height)
end

local function leafContext(measured, configuration, interfaceTable)
  local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
  local selection = ApplicationLayout.selectSurfaces(measured)
  return {
    measurement = measured,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaceTable.nativeLike,
  }
end

local function bagManifest()
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  for index = 1, 6 do
    slots[index] = { rect = { x = 0, y = 32 + (index - 1) * 24, width = 128, height = 22 } }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      cancel = { rect = { x = 192, y = 168, width = 64, height = 24 } },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
      },
    },
  }
end

local function hostRectOwnsPoint(rect, x, y)
  return rect ~= nil
    and x >= rect.x
    and x < rect.x + rect.width
    and y >= rect.y
    and y < rect.y + rect.height
end

local function planOwnsPoint(plan, x, y)
  for _, pane in ipairs(plan.panes or {}) do
    local placement = pane.placement
    if hostRectOwnsPoint(placement and placement.frame, x, y) then
      return true
    end
  end
  for _, frame in ipairs(plan.frames or {}) do
    local placement = frame.placement
    if hostRectOwnsPoint(placement and placement.frame, x, y) then
      return true
    end
  end
  return false
end

local function assertOutsidePoint(plan)
  for _, candidate in ipairs({ { 8, 8 }, { 1272, 8 }, { 8, 712 }, { 1272, 712 } }) do
    if not planOwnsPoint(plan, candidate[1], candidate[2]) then
      return candidate[1], candidate[2]
    end
  end
  error("the framed plan leaves no outside margin on this host", 0)
end

-- Framed plans publish outer frames, and the blocking starter choice
-- still ignores outside presses instead of dismissing.
function T.tests.framed_plans_publish_outer_frames_and_starter_ignores_outside_presses()
  local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
  local BagInterface = require("game.hgss.src.field.BagInterface")
  local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
  local TrainerCardInterface = require("game.hgss.src.field.TrainerCardInterface")
  local StarterChoiceInterface = require("game.hgss.src.starters.StarterChoiceInterface")
  local measured = leafMeasurement(1280, 720)
  local startMenu = StartMenuInterface.withOverrides(nil)
  local bag = BagInterface.withOverrides(nil, bagManifest())
  local party = PartyScreenInterface.withOverrides(nil)
  local card = TrainerCardInterface.withOverrides(nil)
  local starter = StarterChoiceInterface.withOverrides(nil)
  local starterView = { selection = 0, selectionState = "null", transition = "idle", done = false }
  local cases = {
    { name = "start menu", plan = startMenu.wide(leafContext(measured, "wide", startMenu), {}) },
    { name = "bag", plan = bag.wide(leafContext(measured, "wide", bag), {}) },
    {
      name = "party",
      plan = party.wide(leafContext(measured, "wide", party), { cancellable = true, cursorNode = 0 }),
    },
    { name = "trainer card", plan = card.wide(leafContext(measured, "wide", card), {}) },
    { name = "starter choice", plan = starter.wide(leafContext(measured, "wide", starter), starterView) },
  }
  for _, case in ipairs(cases) do
    Assert.isTrue(#case.plan.frames >= 1, "the wide " .. case.name .. " must publish its outer frame")
  end
  local starterPlan = cases[#cases].plan
  local sessionModule = sharedSession()
  local session = sessionModule.new((function()
    local function resolver(_, _)
      return starterPlan
    end
    return { dualDisplay = resolver, nativeLike = resolver, wide = resolver, tall = resolver }
  end)())
  session:resolve(leafMeasurement(1280, 720), starterView)
  local outsideX, outsideY = assertOutsidePoint(starterPlan)
  local mapped =
    session:mapInput({ { type = "pointer_down", pointerId = "touch:9", x = outsideX, y = outsideY } }, starterView)
  for _, event in ipairs(mapped) do
    Assert.isTrue(event.type ~= "dismiss", "an outside press never dismisses the blocking choice")
  end
end

return T
