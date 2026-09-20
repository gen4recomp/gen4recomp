-- Leaf adaptation for the field party screen: four display cases resolve
-- complete matched plans over one canonical 256x192 pane. DualDisplay
-- takes the auxiliary fullscreen and nativeLike the single-surface
-- fullscreen, both uncropped; wide and tall center the pane in a static
-- framed box with a native-like fallback below 1x. The content is
-- the canonical compact grid; render and input callbacks match.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "party-interface-test:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
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

local function view(cancellable)
  return { cancellable = cancellable ~= false, cursorNode = 0 }
end

local function partyInterface(overrides)
  return PartyScreenInterface.withOverrides(overrides)
end

local function singlePane(plan, what)
  Assert.equal(#plan.panes, 1, "the party plan carries its single content pane " .. what)
  local pane = plan.panes[1]
  Assert.isTrue(pane.interactive, "the party pane takes pointer input " .. what)
  Assert.equal(plan.inputKey, "party", "the party plan names its stable input geometry " .. what)
  Assert.isTrue(type(plan.render) == "function", "the party plan carries its render callback " .. what)
  Assert.isTrue(type(plan.mapInput) == "function", "the party plan carries its input callback " .. what)
  local placement = assert(pane.placement, "the party pane carries its placement " .. what)
  -- Windowed body placements carry no crop-budget record; absence means the same uncropped fit.
  local crop = placement.crop or { left = 0, right = 0, top = 0, bottom = 0 }
  Assert.equal(crop.left, 0, "the party pane never crops " .. what)
  Assert.equal(crop.right, 0, "the party pane never crops " .. what)
  Assert.equal(crop.top, 0, "the party pane never crops " .. what)
  Assert.equal(crop.bottom, 0, "the party pane never crops " .. what)
  return pane
end

local function checkContent(plan, cancellable, what)
  local content = assert(plan.content, "the party plan carries its canonical content " .. what)
  Assert.equal(#content.slotRects, 6, "the party content carries six cards " .. what)
  Assert.equal(content.slotRects[1].x, 4, "the first card sits in the left column " .. what)
  Assert.equal(content.slotRects[2].x, 130, "the second card sits in the right column " .. what)
  Assert.equal(content.slotRects[1].width, 122, "cards keep their readable width " .. what)
  Assert.equal(content.slotRects[1].height, 52, "cards keep their readable height " .. what)
  if cancellable then
    Assert.isTrue(content.cancelRect ~= nil, "the cancellable content carries cancel " .. what)
  else
    Assert.isNil(content.cancelRect, "the sealed content carries no cancel " .. what)
  end
end

function T.native_like_resolves_uncropped_fullscreen()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  singlePane(plan, "nativeLike")
  checkContent(plan, true, "nativeLike")
  local sealed = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(false))
  checkContent(sealed, false, "sealed nativeLike")
end

function T.dual_display_takes_the_auxiliary_fullscreen()
  local interfaces = partyInterface()
  local plan = interfaces.dualDisplay(contextFor(translatedPair(), "dualDisplay", interfaces), view(true))
  local pane = singlePane(plan, "dualDisplay")
  checkContent(plan, true, "dualDisplay")
  local frame = pane.placement.frame
  Assert.isTrue(
    frame.x >= 100 and frame.x + frame.width <= 356,
    "the dual pane stays inside the translated auxiliary surface"
  )
end

function T.wide_and_tall_center_a_static_framed_box()
  local interfaces = partyInterface()
  local wide = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), view(true))
  singlePane(wide, "wide")
  checkContent(wide, true, "wide")
  local wideFrame = assert(wide.frames, "a wide host frames the party")[1]
  Assert.notNil(wideFrame, "one outer frame decorates the wide pane")
  Assert.deepEqual(
    wideFrame.contentBox,
    { x = 8, y = 24, width = 256, height = 192 },
    "the wide content box sits inside the rotated insets"
  )
  local tall = interfaces.tall(contextFor(singleDisplay(600, 1000), "tall", interfaces), view(true))
  singlePane(tall, "tall")
  Assert.equal(#tall.frames, 1, "a tall host frames the party in a static box")
end

function T.small_framed_hosts_fall_back_to_native_like()
  local interfaces = partyInterface()
  local plan = interfaces.wide(contextFor(singleDisplay(200, 150), "wide", interfaces), view(true))
  singlePane(plan, "small wide")
  Assert.deepEqual(plan.frames, {}, "a frame that cannot fit falls back to fullscreen")
end

function T.equivalent_measurements_resolve_the_same_geometry()
  local interfaces = partyInterface()
  local first = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  local fresh = measurement(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      role = "world",
      touch = false,
    }),
    1
  )
  local second = interfaces.nativeLike(contextFor(fresh, "nativeLike", interfaces), view(true))
  Assert.equal(first.inputKey, second.inputKey, "a fresh measurement keeps the input geometry")
  Assert.equal(
    first.panes[1].placement.pixelScale,
    second.panes[1].placement.pixelScale,
    "a fresh measurement keeps the pixel scale"
  )
end

function T.dpi_two_matches_the_physical_fit()
  local interfaces = partyInterface()
  local ratioOne = interfaces.nativeLike(contextFor(singleDisplay(750, 560, 1), "nativeLike", interfaces), view(true))
  local ratioTwo = interfaces.nativeLike(contextFor(singleDisplay(375, 280, 2), "nativeLike", interfaces), view(true))
  Assert.equal(
    ratioOne.panes[1].placement.pixelScale,
    ratioTwo.panes[1].placement.pixelScale,
    "equal physical bounds keep the physical magnification"
  )
end

function T.render_invokes_the_borrowed_renderer_with_plan_and_icons()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  local calls = {}
  local graphics = FakeGraphics.new({})
  local resources = {
    graphics = graphics,
    partyScreenRenderer = {
      draw = function(_, presentation, resolved, collaborators)
        calls[#calls + 1] = { presentation = presentation, resolved = resolved, collaborators = collaborators }
      end,
    },
    icons = { sentinel = "icons" },
  }
  plan.render(resources, view(true), plan)
  Assert.equal(#calls, 1, "the render callback draws once")
  Assert.isTrue(calls[1].resolved == plan, "the render callback draws the published plan")
  Assert.isTrue(calls[1].collaborators == resources.icons, "the render callback borrows the icon provider")
  Assert.equal(graphics:pushDepth(), 0, "the render scope restores the graphics stack")
end

function T.map_input_drops_outside_points_and_forwards_the_rest()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "p", outside = true }, view(true), plan),
    "outside points never reach the controller"
  )
  local event = { type = "pointer_down", pointerId = "p", x = 10, y = 10 }
  Assert.isTrue(
    plan.mapInput(event, view(true), plan) == event,
    "visible logical points reach the controller unchanged"
  )
end

function T.case_override_replaces_one_complete_interface()
  local replacement = {
    panes = {},
    content = {},
    inputKey = "party-custom",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    frames = {},
    fadeCoverage = {},
  }
  local function customWide(_, _)
    return replacement
  end
  local interfaces = partyInterface({ wide = customWide })
  local plan = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), view(true))
  Assert.isTrue(plan == replacement, "the override supplies the whole interface")
  local native = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  Assert.equal(native.inputKey, "party", "other cases keep their default interface")
end

function T.unknown_override_cases_and_non_functions_fail()
  Assert.throws(function()
    partyInterface({
      overlay = function(_, _)
        return nil
      end,
    })
  end, "unknown override cases fail at composition")
  Assert.throws(function()
    partyInterface({ wide = "framed" })
  end, "non-function overrides fail at composition")
end

function T.closed_snapshots_resolve_a_disposable_plan()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), { open = false })
  singlePane(plan, "closed")
  checkContent(plan, true, "closed")
end

function T.missing_measurement_fails_without_a_partial_plan()
  local interfaces = partyInterface()
  Assert.throws(function()
    local incomplete = {
      configuration = "nativeLike",
      windowPosition = { x = 0.5, y = 0.5 },
      nativeLikeInterface = interfaces.nativeLike,
    }
    interfaces.nativeLike(incomplete --[[@as ApplicationLayout.Context]], view(true))
  end, "a resolver without its display measurement fails")
end

return { tests = T }
