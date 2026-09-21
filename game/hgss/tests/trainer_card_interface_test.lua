-- Leaf adaptation for the Trainer Card: four display cases resolve complete
-- matched plans over the canonical 256x192 card surface. Dual takes the
-- auxiliary fullscreen and nativeLike the single-surface fullscreen, both
-- with the default four-edge crop budget guarded by the protected text
-- rect; wide and tall center the card in a static framed box with zero
-- crop and a native-like fallback below 1x. Input forwards the
-- existing semantic events and discards pointer content, so outside clicks
-- never close the card.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local TrainerCardInterface = require("game.hgss.src.field.TrainerCardInterface")

local T = {}

local CASES = { "dualDisplay", "nativeLike", "wide", "tall" }

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "card-interface-test:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
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
      id = "main",
      rect = { x = 400, y = 100, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "sub",
      rect = { x = 100, y = 300, width = 256, height = 192 },
      role = "auxiliary",
      touch = false,
    })
  )
end

local function contextFor(m, configuration)
  return {
    measurement = m,
    configuration = configuration,
  }
end

function T.exposes_four_function_cases()
  local set = TrainerCardInterface.withOverrides(nil)
  for _, case in ipairs(CASES) do
    Assert.equal(type(set[case]), "function", "the card interface resolves case " .. case)
  end
end

function T.native_like_exact_fit_stays_doubled_without_crop()
  local plan = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), {})
  local placement = assert(plan.panes[1].placement, "the card pane carries its placement")
  Assert.equal(placement.pixelScale, 2, "the exact-fit host stays doubled")
  Assert.deepEqual(placement.crop, { left = 0, right = 0, top = 0, bottom = 0 }, "exact fits never crop")
  Assert.equal(placement.logicalWidth, 256, "the card content stays source-sized")
  Assert.equal(placement.logicalHeight, 192, "the card content stays source-sized")
  Assert.equal(plan.inputKey, "trainer-card", "the plan names its input geometry")
end

function T.native_like_near_fit_crops_margins_with_protected_text()
  local plan = TrainerCardInterface.nativeLike(contextFor(singleDisplay(750, 560), "nativeLike"), {})
  local placement = assert(plan.panes[1].placement, "the card pane carries its placement")
  Assert.equal(placement.pixelScale, 3, "the near-fit host uses triple pixels")
  Assert.deepEqual(placement.crop, { left = 3, right = 3, top = 3, bottom = 3 }, "near fits crop margins only")
  local clip = assert(placement.clipRect, "the cropped placement carries its visible clip")
  local function insideClip(lx, ly)
    local hx = placement.origin.x + lx * placement.scale
    local hy = placement.origin.y + ly * placement.scale
    return hx >= clip.x and hy >= clip.y and hx < clip.x + clip.width and hy < clip.y + clip.height
  end
  for _, anchor in ipairs({ { 16, 24 }, { 136, 24 }, { 16, 48 }, { 240, 24 }, { 112, 24 }, { 240, 128 } }) do
    Assert.isTrue(
      insideClip(anchor[1], anchor[2]),
      string.format("protected anchor (%d,%d) stays visible", anchor[1], anchor[2])
    )
  end
end

function T.dual_display_takes_the_auxiliary_fullscreen()
  local plan = TrainerCardInterface.dualDisplay(contextFor(translatedPair(), "dualDisplay"), {})
  Assert.equal(#plan.panes, 1, "the auxiliary card shows one content pane")
  local frame = assert(plan.panes[1].placement, "the card pane carries its placement").frame
  Assert.isTrue(
    frame.x >= 100 and frame.y >= 300 and frame.x + frame.width <= 356 and frame.y + frame.height <= 492,
    "the pair hosts the card on the auxiliary surface"
  )
end

local function assertNoCrop(placement, what)
  -- The crop budget is an optional placement field: framed bodies carry
  -- no crop record, which is the zero-crop case.
  Assert.deepEqual(
    placement.crop or { left = 0, right = 0, top = 0, bottom = 0 },
    { left = 0, right = 0, top = 0, bottom = 0 },
    what
  )
end

function T.wide_and_tall_center_a_static_framed_box()
  local wide = TrainerCardInterface.wide(contextFor(singleDisplay(1280, 720), "wide"), {})
  local wideFrame = assert(wide.frames, "the wide card owns its static frame")[1]
  Assert.notNil(wideFrame, "one outer frame decorates the wide pane")
  Assert.deepEqual(
    wideFrame.contentBox,
    { x = 8, y = 24, width = 256, height = 192 },
    "the wide content box sits inside the rotated insets"
  )
  assertNoCrop(assert(wide.panes[1].placement, "the card pane carries its placement"), "static frames never crop")
  local tall = TrainerCardInterface.tall(contextFor(singleDisplay(600, 1000), "tall"), {})
  Assert.equal(#tall.frames, 1, "the tall card owns its static frame")
  assertNoCrop(assert(tall.panes[1].placement, "the tall pane carries its placement"), "tall frames never crop")
end

function T.small_framed_hosts_fall_back_to_native_like()
  local plan = TrainerCardInterface.wide(contextFor(singleDisplay(200, 150), "wide"), {})
  Assert.deepEqual(plan.frames, {}, "the fallback interface is a fullscreen, not a frame")
  Assert.equal(plan.inputKey, "trainer-card", "the fallback keeps the card input geometry")
  Assert.equal(#plan.panes, 1, "the fallback shows its single content pane")
end

function T.equivalent_measurements_resolve_the_same_geometry()
  local first = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), {})
  local second = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), {})
  Assert.deepEqual(
    first.panes[1].placement.frame,
    second.panes[1].placement.frame,
    "a fresh equivalent measurement resolves the same frame"
  )
  Assert.equal(first.inputKey, second.inputKey, "a fresh equivalent measurement keeps the input key")
end

function T.dpi_two_matches_the_physical_fit()
  local thin = TrainerCardInterface.nativeLike(contextFor(singleDisplay(750, 560), "nativeLike"), {})
  local dense = TrainerCardInterface.nativeLike(contextFor(singleDisplay(375, 280, 2), "nativeLike"), {})
  Assert.equal(
    dense.panes[1].placement.pixelScale,
    thin.panes[1].placement.pixelScale,
    "the DPI-2 host matches the physical triple pixels"
  )
  Assert.deepEqual(
    dense.panes[1].placement.crop,
    thin.panes[1].placement.crop,
    "the DPI-2 host matches the physical crop"
  )
end

function T.render_invokes_the_borrowed_renderer_with_view_and_placement()
  local seen = {}
  local resources = {
    graphics = {},
    trainerCardRenderer = {
      draw = function(_, view, placement)
        seen.view = view
        seen.placement = placement
      end,
    },
    text = {},
  }
  local view = { name = "GOLD" }
  local plan = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), view)
  plan.render(resources, view, plan)
  Assert.isTrue(seen.view == view, "the render borrows the semantic snapshot")
  Assert.isTrue(seen.placement == plan.panes[1].placement, "the render draws through the planned pane placement")
end

function T.map_input_discards_pointer_content_and_forwards_semantics()
  local plan = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), {})
  local map = assert(plan.mapInput, "the plan carries its input mapper")
  Assert.isNil(map({ type = "pointer_down", pointerId = "touch:1" }, {}, plan), "body taps never close the card")
  Assert.isNil(map({ type = "pointer_move", pointerId = "touch:1" }, {}, plan), "moves never close the card")
  Assert.isNil(map({ type = "pointer_up", pointerId = "touch:1" }, {}, plan), "releases never close the card")
  Assert.isNil(map({ type = "pointer_cancel", pointerId = "touch:1" }, {}, plan), "cancellation stays gestural")
  local cancel = { type = "cancel" }
  Assert.isTrue(map(cancel, {}, plan) == cancel, "the semantic close edge reaches the controller")
end

function T.an_outside_press_maps_to_a_terminal_dismiss()
  local plan = TrainerCardInterface.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike"), {})
  local map = assert(plan.mapInput, "the plan carries its input mapper")
  Assert.deepEqual(
    map({ type = "pointer_down", pointerId = "touch:1", outside = true }, {}, plan),
    { type = "dismiss" },
    "an outside press dismisses the card while body taps stay inert"
  )
end

function T.case_override_replaces_one_complete_interface()
  local wide = {
    panes = {},
    content = {},
    inputKey = "custom",
    render = function(_, _, _) end,
    mapInput = function(_, _, _)
      return nil
    end,
    frames = {},
  }
  local function customWide(_, _)
    return wide
  end
  local set = TrainerCardInterface.withOverrides({ wide = customWide })
  Assert.isTrue(
    set.wide(contextFor(singleDisplay(1280, 720), "wide"), {}) == wide,
    "the wide override replaces the whole interface"
  )
  Assert.isTrue(set.nativeLike ~= customWide, "the other cases keep their default functions")
end

function T.unknown_override_cases_and_non_functions_fail()
  Assert.throws(function()
    TrainerCardInterface.withOverrides({ sideways = function(_, _) end })
  end)
  Assert.throws(function()
    TrainerCardInterface.withOverrides({ wide = "framed" })
  end)
end

function T.missing_measurement_fails_without_a_partial_plan()
  local measure = singleDisplay(640, 480)
  local selection = ApplicationLayout.selectSurfaces(measure)
  local interfaces = TrainerCardInterface.withOverrides(nil)
  local incomplete = {
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaces.nativeLike,
  }
  Assert.throws(function()
    interfaces.nativeLike(incomplete --[[@as ApplicationLayout.Context]], {})
  end, "a resolver without its display measurement fails")
end

return { tests = T }
