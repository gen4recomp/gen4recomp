-- Parent-owned Naming Screen placement: one canonical 256x192 crop-0 pane
-- on the auxiliary surface for genuine pairs, fullscreen for native-like,
-- and a static centered pane for wide/tall. The child layout always
-- derives from the full canonical logical region, never the visible clip;
-- the child itself carries no placement or scale.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local CASES = { "dualDisplay", "nativeLike", "wide", "tall" }

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "naming-interface-test:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

local function singleDisplay(width, height, pixelRatio)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
    }),
    pixelRatio
  )
end

local function translatedPair()
  return measurement(
    800,
    600,
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
    1
  )
end

---@param measured table<string, unknown>
---@param configuration string
---@param interfaceTable table<string, unknown>
---@return ApplicationLayout.Context
local function contextFor(measured, configuration, interfaceTable)
  local selection = ApplicationLayout.selectSurfaces(measured)
  return {
    measurement = measured,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaceTable.nativeLike,
  }
end

local function namingInterface()
  return NamingInterface.withOverrides(nil)
end

local function semanticView()
  return { kind = "naming" }
end

local function contentPane(plan, what)
  Assert.equal(#plan.panes, 1, "naming resolves one logical pane " .. what)
  local pane = assert(plan.panes[1], "the naming plan carries its content pane " .. what)
  Assert.isTrue(pane.interactive, "the naming pane is interactive " .. what)
  return pane
end

local function assertCanonicalChild(plan, what)
  local layout = assert(plan.content.layout, "the naming plan carries its canonical child layout " .. what)
  Assert.deepEqual(
    { x = layout.surface.x, y = layout.surface.y, width = layout.surface.width, height = layout.surface.height },
    { x = 0, y = 0, width = 256, height = 192 },
    "the child stays canonical " .. what
  )
  Assert.isNil(layout.placement, "the naming child must not own a placement " .. what)
  Assert.isNil(layout.scale, "the naming child must not own a scale " .. what)
  return layout
end

function T.tests.all_cases_resolve_one_matched_canonical_pane()
  local interfaces = namingInterface()
  local cases = {
    dualDisplay = translatedPair(),
    nativeLike = singleDisplay(640, 480),
    wide = singleDisplay(1280, 720),
    tall = singleDisplay(500, 900),
  }
  for _, key in ipairs(CASES) do
    local plan = interfaces[key](contextFor(cases[key], key, interfaces), semanticView())
    local pane = contentPane(plan, key)
    local placement = assert(pane.placement, "the naming pane carries its host placement " .. key)
    Assert.equal(placement.logicalWidth, 256, "the naming pane is canonically wide " .. key)
    Assert.equal(placement.logicalHeight, 192, "the naming pane is canonically tall " .. key)
    Assert.equal(plan.inputKey, "naming", "the naming plan names stable input geometry " .. key)
    Assert.equal(type(plan.render), "function", "the naming plan carries its render callback " .. key)
    Assert.equal(type(plan.mapInput), "function", "the naming plan carries its input callback " .. key)
    assertCanonicalChild(plan, key)
  end
end

function T.tests.dual_case_hosts_naming_on_the_auxiliary_surface()
  local interfaces = namingInterface()
  local plan = interfaces.dualDisplay(contextFor(translatedPair(), "dualDisplay", interfaces), semanticView())
  local pane = contentPane(plan, "dual")
  local frame = assert(pane.placement, "the dual naming pane carries its host placement").frame
  Assert.isTrue(
    frame.x >= 100 and frame.y >= 300 and frame.x + frame.width <= 356 and frame.y + frame.height <= 492,
    "dual naming stays inside the auxiliary surface"
  )
end

function T.tests.native_like_case_owns_its_fullscreen_region()
  local interfaces = namingInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), semanticView())
  contentPane(plan, "nativeLike")
  local untyped = plan --[[@as table<string, unknown>]]
  Assert.isNil(untyped.window, "fullscreen naming carries no window chrome")
  Assert.isTrue(#plan.fadeCoverage > 0, "fullscreen naming names its transition region")
end

function T.tests.tiny_host_keeps_complete_canonical_content_without_a_fit_error()
  local interfaces = namingInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(240, 180), "nativeLike", interfaces), semanticView())
  local pane = contentPane(plan, "tiny")
  local placement = assert(pane.placement, "the tiny-host naming pane carries its host placement")
  Assert.equal(placement.logicalWidth, 256, "cropping never shrinks the canonical logical width")
  Assert.equal(placement.logicalHeight, 192, "cropping never shrinks the canonical logical height")
  assertCanonicalChild(plan, "tiny")
end

function T.tests.equivalent_physical_size_at_ratio_two_matches_ratio_one()
  local interfaces = namingInterface()
  local one = interfaces.nativeLike(contextFor(singleDisplay(750, 560, 1), "nativeLike", interfaces), semanticView())
  local two = interfaces.nativeLike(contextFor(singleDisplay(375, 280, 2), "nativeLike", interfaces), semanticView())
  local onePane = contentPane(one, "ratio1")
  local twoPane = contentPane(two, "ratio2")
  Assert.equal(
    assert(onePane.placement, "ratio-1 placement").pixelScale,
    assert(twoPane.placement, "ratio-2 placement").pixelScale,
    "equal physical bounds select equal integer magnification"
  )
end

function T.tests.fresh_equivalent_measurement_resolves_identical_geometry()
  local interfaces = namingInterface()
  local first = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), semanticView())
  local second = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), semanticView())
  local firstPane = contentPane(first, "first")
  local secondPane = contentPane(second, "second")
  local firstFrame = assert(firstPane.placement, "first placement").frame
  local secondFrame = assert(secondPane.placement, "second placement").frame
  Assert.deepEqual(
    { x = secondFrame.x, y = secondFrame.y, width = secondFrame.width, height = secondFrame.height },
    { x = firstFrame.x, y = firstFrame.y, width = firstFrame.width, height = firstFrame.height },
    "a fresh equivalent measurement resolves identical geometry"
  )
end

function T.tests.missing_measurement_fails_without_a_partial_plan()
  local interfaces = namingInterface()
  Assert.throws(function()
    local incomplete = {
      configuration = "nativeLike",
      nativeLikeInterface = interfaces.nativeLike,
    }
    interfaces.nativeLike(incomplete --[[@as ApplicationLayout.Context]], semanticView())
  end, "a resolver without its display measurement fails")
end

function T.tests.unknown_override_case_fails_at_composition()
  Assert.throws(function()
    NamingInterface.withOverrides({ sideways = NamingInterface.fullscreen })
  end, "an unknown naming override case fails")
end

function T.tests.per_case_override_replaces_the_whole_pair()
  local wideRender = function(_, _, _) end
  local wideMap = function(_, _, _)
    return nil
  end
  local interfaces = NamingInterface.withOverrides({
    wide = function(_, _)
      return {
        panes = {},
        frames = {},
        fadeCoverage = {},
        content = {},
        inputKey = "custom-wide",
        render = wideRender,
        mapInput = wideMap,
      }
    end,
  })
  local wide = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), semanticView())
  Assert.equal(wide.inputKey, "custom-wide", "the wide override supplies its own pair")
  local native = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), semanticView())
  Assert.equal(native.inputKey, "naming", "other cases keep their original pair")
end

local function planForMapper()
  local interfaces = namingInterface()
  return interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), semanticView())
end

function T.tests.mapper_routes_logical_pointer_hits_to_existing_semantics()
  local plan = planForMapper()
  local map = assert(plan.mapInput, "the naming plan carries its input callback")
  local control = assert(
    map({ type = "pointer_down", pointerId = "mouse", x = 30, y = 70 }, semanticView(), plan),
    "a control hit maps"
  )
  Assert.equal(control.type, "name_control", "control hits dispatch by control id")
  Assert.equal(control.id, "upper", "the upper control hit dispatches upper")
  local cell =
    assert(map({ type = "pointer_down", pointerId = "mouse", x = 29, y = 89 }, semanticView(), plan), "a cell hit maps")
  Assert.equal(cell.type, "name_cell", "cell hits dispatch by row and column")
  Assert.equal(cell.row, 2, "the probed glyph dispatches its row")
  Assert.equal(cell.column, 1, "the probed glyph dispatches its column")
  Assert.isNil(
    map({ type = "pointer_down", pointerId = "mouse", x = 121, y = 68 }, semanticView(), plan),
    "the source home-row gap owns no hit region"
  )
end

function T.tests.mapper_ignores_non_content_pointer_traffic()
  local plan = planForMapper()
  local map = assert(plan.mapInput, "the naming plan carries its input callback")
  Assert.isNil(
    map({ type = "pointer_down", pointerId = "mouse", outside = true }, semanticView(), plan),
    "outside downs never enter the editor"
  )
  Assert.isNil(
    map({ type = "pointer_move", pointerId = "mouse", x = 29, y = 89 }, semanticView(), plan),
    "moves never activate: the editor acts on downs"
  )
  Assert.isNil(
    map({ type = "pointer_up", pointerId = "mouse", x = 29, y = 89 }, semanticView(), plan),
    "releases never activate: the editor acts on downs"
  )
  Assert.isNil(
    map({ type = "pointer_scroll", pointerId = "mouse", x = 0, y = 0 }, semanticView(), plan),
    "scroll deltas are not editor input"
  )
  Assert.isNil(map({ type = "pointer_cancel", pointerId = "mouse" }, semanticView(), plan), "cancellation stays mute")
end

-- Wide/tall naming centers canonical content with no outer decoration:
-- an empty frame list and no window chrome on any host.
function T.tests.wide_and_tall_naming_centers_without_outer_decoration()
  local interfaces = namingInterface()
  for _, case in ipairs({
    { key = "wide", measured = singleDisplay(1280, 720) },
    { key = "tall", measured = singleDisplay(500, 900) },
  }) do
    local plan = interfaces[case.key](contextFor(case.measured, case.key, interfaces), semanticView())
    local pane = contentPane(plan, case.key)
    local placement = assert(pane.placement, "the naming pane carries its host placement " .. case.key)
    Assert.equal(placement.logicalWidth, 256, "the naming pane is canonically wide " .. case.key)
    Assert.equal(placement.logicalHeight, 192, "the naming pane is canonically tall " .. case.key)
    Assert.deepEqual(plan.frames or "missing", {}, "naming publishes no outer frame " .. case.key)
    local untyped = plan --[[@as table<string, unknown>]]
    Assert.isNil(untyped.window, "naming carries no window chrome " .. case.key)
  end
end

return T
