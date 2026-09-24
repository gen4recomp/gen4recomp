-- Starter Choice interface selection: each display configuration resolves
-- through its own function returning a complete render/input pair. Wide
-- pairs info left of the machine, tall stacks info above the machine, a
-- genuine world/auxiliary pair keeps info on world and the machine on
-- auxiliary, and nativeLike resolves one complete compact portrait/action/
-- message interface. No central mode switch can replace one case without
-- replacing its matched rendering and input together.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local CASES = { "dualDisplay", "nativeLike", "wide", "tall" }

-- The leaf interface module owns the four resolver functions; rendering and
-- input dispatch cannot be replaced one case at a time without it.
local function starterChoiceInterface()
  local ok, module = pcall(require, "game.hgss.src.starters.StarterChoiceInterface")
  Assert.isTrue(ok, "the starter choice must expose one resolver function per display configuration")
  return module
end

-- A complete caller-owned measurement for one drawable, following the same
-- construction the product session uses: host-unit bounds, actual topology,
-- uniform pixel ratio, and a stable signature.
local function measurementFor(width, height, topology, pixelRatio, signature)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio,
    signature = signature,
  }
end

-- A complete context around a measurement, exactly as the owning session
-- supplies it: measured display, configuration, selected surfaces, and the
-- effective nativeLike function.
local function contextFor(measurement, configuration, interfaceModule)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaceModule.nativeLike,
  }
end

-- The semantic snapshot the resolvers read: a plain controller-shaped
-- record with no behavior, mirroring the retail null-state shape.
local function nullView()
  return { selection = 0, selectionState = "null", transition = "idle", done = false }
end

local function wideMeasurement()
  return measurementFor(
    1280,
    720,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 100, y = 50, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-wide-actual"
  )
end

local function tallMeasurement()
  return measurementFor(
    390,
    844,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 20, y = 30, width = 390, height = 844 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-tall-actual"
  )
end

local function dualMeasurement()
  return measurementFor(
    912,
    684,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 400, y = 100, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 100, y = 300, width = 256, height = 192 },
      role = "auxiliary",
      touch = true,
    }),
    1,
    "starter-dual-actual"
  )
end

local function nativeLikeMeasurement()
  return measurementFor(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-compact-actual"
  )
end

local function frameOf(pane)
  local placement = assert(pane.placement, "every interface pane carries its complete placement")
  return assert(placement.frame, "every interface placement carries its full host frame")
end

function T.tests.every_display_case_resolves_through_its_own_function()
  local interface = starterChoiceInterface()
  for _, case in ipairs(CASES) do
    Assert.isTrue(
      type(interface[case]) == "function",
      "the " .. case .. " case must be a resolver function, not a mode token"
    )
  end
end

function T.tests.wide_pairs_info_left_of_the_machine_with_one_shared_scale()
  local interface = starterChoiceInterface()
  local plan = interface.wide(contextFor(wideMeasurement(), "wide", interface), nullView())
  Assert.equal(#plan.panes, 2, "the wide case pairs exactly two logical panes")
  local left = frameOf(plan.panes[1])
  local right = frameOf(plan.panes[2])
  Assert.isTrue(left.x + left.width <= right.x, "the wide pair places two panes side by side")
  local leftScale = assert(plan.panes[1].placement.scale, "the left pane carries its host scale")
  local rightScale = assert(plan.panes[2].placement.scale, "the right pane carries its host scale")
  Assert.equal(leftScale, rightScale, "a single-display pair shares one integer presentation scale")
  Assert.near(right.x - (left.x + left.width), 0, 1e-6, "paired starter panes touch with no synthetic gap")
  Assert.equal(type(plan.inputKey), "string", "the wide plan names its stable input geometry")
  Assert.isTrue(type(plan.render) == "function", "the wide plan carries its render callback")
  Assert.isTrue(type(plan.mapInput) == "function", "the wide plan carries its matching input mapper")
end

function T.tests.tall_stacks_info_above_the_machine_with_one_shared_scale()
  local interface = starterChoiceInterface()
  local plan = interface.tall(contextFor(tallMeasurement(), "tall", interface), nullView())
  Assert.equal(#plan.panes, 2, "the tall case pairs exactly two logical panes")
  local upper = frameOf(plan.panes[1])
  local lower = frameOf(plan.panes[2])
  Assert.isTrue(upper.y + upper.height <= lower.y, "the tall pair stacks two panes vertically")
  Assert.equal(
    plan.panes[1].placement.scale,
    plan.panes[2].placement.scale,
    "a single-display pair shares one integer presentation scale"
  )
  Assert.isTrue(type(plan.render) == "function", "the tall plan carries its render callback")
  Assert.isTrue(type(plan.mapInput) == "function", "the tall plan carries its matching input mapper")
end

function T.tests.dual_maps_info_to_world_and_the_machine_to_auxiliary()
  local interface = starterChoiceInterface()
  local plan = interface.dualDisplay(contextFor(dualMeasurement(), "dualDisplay", interface), nullView())
  Assert.equal(#plan.panes, 2, "the dual case keeps both physical surfaces")
  local worldRect = { x = 400, y = 100, width = 256, height = 192 }
  local auxRect = { x = 100, y = 300, width = 256, height = 192 }
  local inWorld = 0
  local inAux = 0
  for _, pane in ipairs(plan.panes) do
    local frame = frameOf(pane)
    local cx = frame.x + frame.width / 2
    local cy = frame.y + frame.height / 2
    if
      cx >= worldRect.x
      and cx <= worldRect.x + worldRect.width
      and cy >= worldRect.y
      and cy <= worldRect.y + worldRect.height
    then
      inWorld = inWorld + 1
    end
    if cx >= auxRect.x and cx <= auxRect.x + auxRect.width and cy >= auxRect.y and cy <= auxRect.y + auxRect.height then
      inAux = inAux + 1
    end
  end
  Assert.equal(inWorld, 1, "exactly one dual pane lives on the world surface")
  Assert.equal(inAux, 1, "exactly one dual pane lives on the auxiliary surface")
end

function T.tests.native_like_resolves_one_complete_compact_pane_without_cropping()
  local interface = starterChoiceInterface()
  local plan = interface.nativeLike(contextFor(nativeLikeMeasurement(), "nativeLike", interface), nullView())
  Assert.equal(#plan.panes, 1, "the compact case is one complete interface, not a machine-only view")
  local placement = assert(plan.panes[1].placement, "the compact pane carries its complete placement")
  Assert.equal(placement.logicalWidth, 256, "the compact pane keeps native logical width")
  Assert.equal(placement.logicalHeight, 192, "the compact pane keeps native logical height")
  local crop = assert(placement.crop, "the compact placement reports its crop budget")
  Assert.equal(crop.left, 0, "the compact interface never crops its left edge")
  Assert.equal(crop.right, 0, "the compact interface never crops its right edge")
  Assert.equal(crop.top, 0, "the compact interface never crops its top edge")
  Assert.equal(crop.bottom, 0, "the compact interface never crops its bottom edge")
  Assert.isTrue(type(plan.render) == "function", "the compact plan carries its render callback")
  Assert.isTrue(type(plan.mapInput) == "function", "the compact plan carries its matching input mapper")
end

function T.tests.a_wide_only_override_replaces_rendering_and_input_together()
  local interface = starterChoiceInterface()
  local context = contextFor(wideMeasurement(), "wide", interface)
  local baseline = interface.wide(context, nullView())
  local customRenderings = 0
  local customMappings = 0
  local function customWide(_, _)
    return {
      panes = { { id = "replacement", placement = baseline.panes[1].placement, interactive = true } },
      content = {},
      inputKey = "replacement-wide",
      render = function(_, _, _)
        customRenderings = customRenderings + 1
      end,
      mapInput = function(_, _, _)
        customMappings = customMappings + 1
        return { type = "confirm" }
      end,
      frames = {},
    }
  end
  local merged = {
    dualDisplay = interface.dualDisplay,
    nativeLike = interface.nativeLike,
    wide = customWide,
    tall = interface.tall,
  }
  local customPlan = merged.wide(context, nullView())
  customPlan.render({}, nullView(), customPlan)
  local mapped = customPlan.mapInput({ type = "pointer_down", pointerId = "touch:1" }, nullView(), customPlan)
  Assert.equal(customRenderings, 1, "the override render callback must execute")
  Assert.equal(customMappings, 1, "the override input mapper must execute")
  Assert.equal(mapped.type, "confirm", "the override mapper replaces the interaction model")
  Assert.isTrue(
    interface.nativeLike == merged.nativeLike,
    "replacing one case must not replace the nativeLike function"
  )
end

-- A translated wide measurement resolves the same pair policy in
-- host-unit bounds far from the origin.
function T.tests.translated_safe_rectangles_keep_the_pair_policy()
  local interface = starterChoiceInterface()
  local measurement = measurementFor(
    1280,
    720,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 2000, y = 1500, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-translated-wide"
  )
  local plan = interface.wide(contextFor(measurement, "wide", interface), nullView())
  Assert.equal(#plan.panes, 2, "a translated wide host still pairs two panes")
  local left = frameOf(plan.panes[1])
  Assert.isTrue(left.x >= 2000, "the translated pair stays inside the translated drawable")
  Assert.equal(
    plan.panes[1].placement.scale,
    plan.panes[2].placement.scale,
    "translation never changes the shared pair scale"
  )
end

-- A freshly allocated but equivalent measurement resolves without
-- disturbing capture: structural identity ignores table identity.
function T.tests.equivalent_fresh_measurements_resolve_stably()
  local interface = starterChoiceInterface()
  local first = interface.wide(contextFor(wideMeasurement(), "wide", interface), nullView())
  local second = interface.wide(contextFor(wideMeasurement(), "wide", interface), nullView())
  Assert.equal(#second.panes, #first.panes, "an equivalent measurement resolves the same pane count")
  Assert.equal(
    frameOf(second.panes[1]).x,
    frameOf(first.panes[1]).x,
    "an equivalent measurement resolves the same geometry"
  )
end

-- A DPI-2 dual pair keeps info on world with the machine on auxiliary
-- at integer physical magnification.
function T.tests.dpi2_dual_pairs_keep_physical_roles()
  local interface = starterChoiceInterface()
  local measurement = measurementFor(
    512,
    384,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 600, y = 0, width = 512, height = 384 },
      role = "auxiliary",
      touch = false,
    }),
    2,
    "starter-dpi2-dual"
  )
  local plan = interface.dualDisplay(contextFor(measurement, "dualDisplay", interface), nullView())
  Assert.equal(#plan.panes, 2, "a DPI-2 pair keeps both physical surfaces")
  for _, pane in ipairs(plan.panes) do
    local placement = assert(pane.placement, "every dual pane carries its placement")
    Assert.equal(placement.pixelScale, 4, "equivalent physical bounds keep integer magnification")
  end
end

-- A host below 1x still resolves one complete compact interface through
-- the fractional fallback so controls remain reachable.
function T.tests.tiny_hosts_fall_back_to_a_complete_compact_interface()
  local interface = starterChoiceInterface()
  local measurement = measurementFor(
    200,
    150,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 200, height = 150 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-tiny"
  )
  local plan = interface.nativeLike(contextFor(measurement, "nativeLike", interface), nullView())
  Assert.equal(#plan.panes, 1, "a tiny host still resolves one complete pane")
  local placement = assert(plan.panes[1].placement, "the tiny pane carries its placement")
  Assert.equal(placement.logicalWidth, 256, "the fallback keeps the full logical width")
  Assert.equal(placement.logicalHeight, 192, "the fallback keeps the full logical height")
end

-- Input clipping: native taps outside the machine keep the tap(nil)
-- reversal contract while compact presses outside every actionable
-- region map to nothing.
function T.tests.clipped_input_cannot_reach_offscreen_controls()
  local interface = starterChoiceInterface()
  local native = interface.wide(contextFor(wideMeasurement(), "wide", interface), nullView())
  local matte = native.mapInput({ type = "pointer_down", pointerId = "touch:1", outside = true }, nullView(), native)
  Assert.deepEqual(matte, { type = "tap", index = nil }, "matte taps keep the tap(nil) contract")
  Assert.isNil(
    native.mapInput({ type = "pointer_move", pointerId = "touch:1", x = 0, y = 0 }, nullView(), native),
    "machine moves carry no starter semantics"
  )
  local compact = interface.nativeLike(contextFor(nativeLikeMeasurement(), "nativeLike", interface), nullView())
  Assert.isNil(
    compact.mapInput({ type = "pointer_down", pointerId = "touch:1", x = 250, y = 186 }, nullView(), compact),
    "compact presses outside every region map to nothing"
  )
  Assert.isNil(
    compact.mapInput({ type = "pointer_down", pointerId = "touch:1", outside = true }, nullView(), compact),
    "compact outside downs map to nothing"
  )
end

-- Both render callbacks draw framed surfaces through the field-owned
-- window renderer: a resources record without it fails before any draw,
-- and a supplied renderer reaches the presentation entrypoint untouched.
function T.tests.render_callbacks_borrow_the_field_window_renderer()
  local interface = starterChoiceInterface()
  local view = nullView()
  local native = interface.wide(contextFor(wideMeasurement(), "wide", interface), view)
  local compact = interface.nativeLike(contextFor(nativeLikeMeasurement(), "nativeLike", interface), view)
  local nativeCalls, compactCalls = {}, {}
  local nativeAlpha
  local resources = {
    presentation = {
      drawNative = function(_, _, _, _, _, windowRenderer, renderAlpha)
        nativeCalls[#nativeCalls + 1] = windowRenderer
        nativeAlpha = renderAlpha
      end,
      drawCompact = function(_, _, _, _, _, windowRenderer)
        compactCalls[#compactCalls + 1] = windowRenderer
      end,
    },
    text = {},
    renderAlpha = 0.37,
  }
  local nativeErr = Assert.throws(function()
    native.render(resources, view, native)
  end, "native rendering without the field renderer fails instead of drawing")
  Assert.isTrue(
    tostring(nativeErr):find("window renderer", 1, true) ~= nil,
    "the native render names the missing borrower: " .. tostring(nativeErr)
  )
  local compactErr = Assert.throws(function()
    compact.render(resources, view, compact)
  end, "compact rendering without the field renderer fails instead of drawing")
  Assert.isTrue(
    tostring(compactErr):find("window renderer", 1, true) ~= nil,
    "the compact render names the missing borrower: " .. tostring(compactErr)
  )
  local borrowed = {}
  resources.windowRenderer = borrowed
  native.render(resources, view, native)
  compact.render(resources, view, compact)
  Assert.equal(#nativeCalls, 1, "the native render reaches its presentation entrypoint")
  Assert.isTrue(nativeCalls[1] == borrowed, "the native render lends the field renderer untouched")
  Assert.equal(nativeAlpha, resources.renderAlpha, "the native render forwards the field interpolation alpha")
  Assert.equal(#compactCalls, 1, "the compact render reaches its presentation entrypoint")
  Assert.isTrue(compactCalls[1] == borrowed, "the compact render lends the field renderer untouched")
end

return T
