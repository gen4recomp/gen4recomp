-- Shared application display policy: actual host surfaces classify into one
-- of four configurations before any application geometry is fitted. A
-- genuine world/auxiliary pair is dual; a near-4:3 single surface stays a
-- fullscreen native surface across decorations (enter within 12 logical
-- pixels per edge, retain within 14); anything else is a wide or tall
-- surface that frames the application in a static centered box. The band and
-- its hysteresis are one shared contract, not per-application heuristics.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local function surface(id, width, height, opts)
  opts = opts or {}
  return {
    id = id,
    rect = { x = 0, y = 0, width = width, height = height },
    role = opts.role or "world",
    touch = opts.touch == true,
  }
end

local function singleSurface(width, height, opts)
  return ScreenTopology.oneDisplay(surface("main", width, height, opts))
end

local function worldAuxiliaryPair()
  return ScreenTopology.dualDisplay(
    surface("upper", 256, 192, { role = "world" }),
    surface("lower", 256, 192, { role = "auxiliary", touch = true })
  )
end

-- The shared policy module owns classification; the per-application gutter
-- heuristics it replaces cannot answer it.
local function sharedPolicy()
  local ok, module = pcall(require, "game.hgss.src.ui.ApplicationLayout")
  Assert.isTrue(ok, "one shared policy must classify actual host surfaces into display configurations")
  return module
end

local function measure(topology, width, height, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
  }
end

function T.tests.near_native_single_surfaces_stay_fullscreen_instead_of_framing()
  local policy = sharedPolicy()
  for _, size in ipairs({
    { width = 640, height = 480 },
    { width = 640, height = 456 },
    { width = 750, height = 560 },
  }) do
    local configuration = policy.classify(measure(singleSurface(size.width, size.height), size.width, size.height))
    Assert.equal(configuration, "nativeLike", size.width .. "x" .. size.height .. " stays a fullscreen native surface")
  end
end

function T.tests.far_surfaces_fall_to_wide_or_tall_by_aspect()
  local policy = sharedPolicy()
  local wide = policy.classify(measure(singleSurface(1920, 1080), 1920, 1080))
  Assert.equal(wide, "wide", "a 16:9 host frames the application in a static box")
  for _, size in ipairs({
    { width = 390, height = 844 },
    { width = 512, height = 512 },
  }) do
    local configuration = policy.classify(measure(singleSurface(size.width, size.height), size.width, size.height))
    Assert.equal(configuration, "tall", size.width .. "x" .. size.height .. " frames the application in a static box")
  end
end

function T.tests.a_genuine_world_auxiliary_pair_is_dual()
  local policy = sharedPolicy()
  Assert.equal(
    policy.classify(measure(worldAuxiliaryPair(), 256, 384)),
    "dualDisplay",
    "a world/auxiliary role pair classifies before any aspect heuristic"
  )
end

function T.tests.native_classification_has_stable_hysteresis()
  local policy = sharedPolicy()
  -- Aspect errors just inside the entry band hold the native surface, just
  -- past the retain band leave it, and re-entry needs the entry band again.
  local held = policy.classify(measure(singleSurface(640, 480), 640, 480))
  Assert.equal(held, "nativeLike", "the reference surface starts native")
  local function classifyAt(width, height, previous)
    return policy.classify(measure(singleSurface(width, height), width, height), previous)
  end
  -- 640x458 is a ~6.1 error: inside both bands, so it stays native.
  Assert.equal(classifyAt(640, 458, held), "nativeLike", "an error inside the entry band stays native")
  -- 640x436 is a ~12.9 error: past entry, inside retain, so it stays native.
  Assert.equal(classifyAt(640, 436, held), "nativeLike", "an error inside the retain band stays native")
  -- 640x430 is a ~14.9 error: past retain, so it leaves native for a static frame.
  local framed = classifyAt(640, 430, held)
  Assert.isTrue(framed == "wide" or framed == "tall", "an error past the retain band leaves native")
  -- Back at a ~12.9 error without native history, the entry band refuses it.
  Assert.equal(classifyAt(640, 436, framed), framed, "re-entry into native needs the entry band again")
end

local function selectionFor(topology, width, height, pixelRatio)
  local policy = sharedPolicy()
  return policy.selectSurfaces(measure(topology, width, height, pixelRatio))
end

local function layoutContext(measurement, configuration, nativeLikeInterface)
  local policy = sharedPolicy()
  local selection = policy.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = nativeLikeInterface,
  }
end

function T.tests.two_arbitrary_surfaces_without_an_auxiliary_role_are_not_dual()
  local policy = sharedPolicy()
  local topology = ScreenTopology.new({
    surfaces = {
      surface("left", 1920, 1080, { role = "world" }),
      surface("right", 1920, 1080, { role = "world" }),
    },
  })
  Assert.equal(
    policy.classify(measure(topology, 3840, 1080)),
    "wide",
    "two world surfaces classify by aspect, never as a DS pair"
  )
end

function T.tests.dual_pairing_ignores_touch_flags()
  local policy = sharedPolicy()
  local topology = ScreenTopology.dualDisplay(
    surface("upper", 256, 192, { role = "world", touch = false }),
    surface("lower", 256, 192, { role = "auxiliary", touch = false })
  )
  Assert.equal(
    policy.classify(measure(topology, 256, 384)),
    "dualDisplay",
    "world/auxiliary roles pair with or without touch"
  )
end

function T.tests.usable_bounds_exclude_reservations_and_prefer_the_largest_free_region()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    role = "world",
    touch = false,
    occupiedRegions = { { x = 0, y = 400, width = 640, height = 80 } },
  })
  local selection = selectionFor(topology, 640, 480)
  local usable = assert(selection.primary.usableBounds, "a reserved surface keeps its free region")
  Assert.deepEqual(
    usable,
    { x = 0, y = 0, width = 640, height = 400 },
    "the keyboard reservation leaves the largest free rectangle"
  )
end

function T.tests.a_fully_occupied_surface_is_temporarily_not_presentable()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 100, height = 100 },
    role = "world",
    touch = false,
    occupiedRegions = { { x = 0, y = 0, width = 100, height = 100 } },
  })
  local selection = selectionFor(topology, 100, 100)
  Assert.isNil(selection.primary.usableBounds, "total occlusion retains state with no pointer target")
end

function T.tests.fullscreen_fits_from_ui_bounds_with_integer_pixels()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(640, 480), 640, 480)
  local context = layoutContext(measurement, "nativeLike")
  local geometry = policy.fullscreen(context, { id = "content", width = 256, height = 192 })
  local placement = assert(geometry.placements["content"], "the native pane places")
  Assert.equal(placement.pixelScale, 2, "640x480 fits the native surface at 2x")
  Assert.equal(placement.logicalWidth, 256, "the logical surface stays canonical")
  Assert.equal(placement.logicalHeight, 192, "the logical surface stays canonical")
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "fullscreen names no transition region")
  Assert.deepEqual(geometry.frames, {}, "fullscreen carries no frame")
end

function T.tests.fullscreen_without_drawable_space_returns_an_empty_geometry()
  local policy = sharedPolicy()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 100, height = 100 },
    role = "world",
    touch = false,
    occupiedRegions = { { x = 0, y = 0, width = 100, height = 100 } },
  })
  local context = layoutContext(measure(topology, 100, 100), "nativeLike")
  local geometry = policy.fullscreen(context, { id = "content", width = 256, height = 192 })
  Assert.deepEqual(geometry.placements, {}, "occlusion publishes no panes")
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "occlusion publishes no transition coverage")
end

function T.tests.framed_static_box_carries_the_complete_rotated_outer_frame()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(1280, 720), 1280, 720)
  local context = layoutContext(measurement, "wide")
  local geometry =
    assert(policy.framed(context, { id = "content", width = 256, height = 192 }), "a 720p host frames the content")
  local frame = assert(geometry.frames, "wide carries its frame list")[1]
  Assert.notNil(frame, "one outer frame decorates the pane")
  Assert.equal(frame.placement.logicalWidth, 272, "the outer frame adds left and right room")
  Assert.equal(frame.placement.logicalHeight, 240, "the outer frame adds the 24px top and bottom")
  Assert.deepEqual(
    frame.contentBox,
    { x = 8, y = 24, width = 256, height = 192 },
    "the body starts inside the exterior insets"
  )
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "a static frame owns no transition region")
  local body = assert(geometry.placements["content"], "the framed pane places")
  Assert.deepEqual(
    { body.logicalWidth, body.logicalHeight },
    { 256, 192 },
    "the body keeps canonical content dimensions"
  )
  Assert.near(
    (body.origin.x - frame.placement.origin.x) / frame.placement.scale,
    8,
    1e-9,
    "the body starts inside the left frame edge"
  )
  Assert.near(
    (body.origin.y - frame.placement.origin.y) / frame.placement.scale,
    24,
    1e-9,
    "the body starts below the top frame edge"
  )
  Assert.deepEqual(
    body.crop or { left = 0, right = 0, top = 0, bottom = 0 },
    { left = 0, right = 0, top = 0, bottom = 0 },
    "a visible frame never coexists with body crop"
  )
end

function T.tests.framed_selects_physical_integer_scale_through_the_framebuffer_ratio()
  local policy = sharedPolicy()
  for _, case in ipairs({ { pixelRatio = 2 }, { pixelRatio = 1.25 } }) do
    local measurement = measure(singleSurface(1280, 720), 1280, 720, case.pixelRatio)
    local context = layoutContext(measurement, "wide")
    local geometry =
      assert(policy.framed(context, { id = "content", width = 256, height = 192 }), "a 720p host frames the content")
    local frame = assert(geometry.frames, "wide carries its frame list")[1]
    local outer = assert(frame and frame.placement, "the outer frame places")
    Assert.isTrue(
      outer.pixelScale ~= nil and outer.pixelScale >= 1 and outer.pixelScale % 1 == 0,
      "ratio " .. case.pixelRatio .. " fits the complete frame at an integer physical scale"
    )
    Assert.near(
      outer.scale,
      outer.pixelScale / case.pixelRatio,
      1e-9,
      "the host scale is the physical scale over the framebuffer ratio"
    )
    Assert.equal(outer.logicalWidth, 272, "the outer frame keeps its exterior width")
    Assert.equal(outer.logicalHeight, 240, "the outer frame keeps its exterior height")
  end
end

function T.tests.framed_falls_back_when_no_integer_frame_fits()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(200, 150), 200, 150)
  local context = layoutContext(measurement, "wide")
  Assert.isNil(
    policy.framed(context, { id = "content", width = 256, height = 192 }),
    "a tiny host needs the nativeLike fallback"
  )
end

function T.tests.native_dual_fits_each_surface_independently()
  local policy = sharedPolicy()
  local measurement = measure(worldAuxiliaryPair(), 256, 384)
  local context = layoutContext(measurement, "dualDisplay")
  local geometry = policy.nativeDual(
    context,
    { id = "upper", width = 256, height = 192 },
    { id = "lower", width = 256, height = 192 }
  )
  Assert.notNil(geometry.placements["upper"], "the world pane places")
  Assert.notNil(geometry.placements["lower"], "the auxiliary pane places")
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "dual geometry names no transition region")
end

function T.tests.side_by_side_shares_one_scale_with_no_gap()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(1280, 720), 1280, 720)
  local context = layoutContext(measurement, "wide")
  local geometry = assert(
    policy.sideBySide(context, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "a 720p host pairs two native panes"
  )
  local upper = assert(geometry.placements["upper"], "the upper pane places")
  local lower = assert(geometry.placements["lower"], "the lower pane places")
  Assert.equal(upper.pixelScale, lower.pixelScale, "a pair never fits its panes independently")
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "a composed pair names no transition region")
end

function T.tests.stacked_returns_nil_when_the_envelope_cannot_fit()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(300, 200), 300, 200)
  local context = layoutContext(measurement, "tall")
  Assert.isNil(
    policy.stacked(context, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "an unfittable envelope needs the nativeLike fallback"
  )
end

-- Static single-pane boxes fit the complete symmetric outer frame
-- (content plus the 8/24/8/24 exterior around the body)
-- centered at integer scale with no remembered position
function T.tests.framed_single_pane_centers_the_complete_rotated_frame()
  local policy = sharedPolicy()
  for _, size in ipairs({ { width = 1280, height = 720 }, { width = 390, height = 844 } }) do
    local measurement = measure(singleSurface(size.width, size.height), size.width, size.height)
    local configuration = policy.classify(measurement)
    local context = layoutContext(measurement, configuration)
    local geometry =
      assert(policy.framed(context, { id = "content", width = 256, height = 192 }), "a host frames the content")
    local placement = assert(geometry.placements["content"], "the framed pane places")
    Assert.equal(placement.logicalWidth, 256, "the framed body keeps its canonical width")
    Assert.equal(placement.logicalHeight, 192, "the framed body keeps its canonical height")
    Assert.isTrue(
      placement.pixelScale ~= nil and placement.pixelScale >= 1,
      "the framed body keeps an integer scale at or above 1x"
    )
    local frame = assert(geometry.frames, "framed geometry carries its frame list")[1]
    Assert.notNil(frame, "one outer frame decorates the pane")
    Assert.deepEqual(
      frame.contentBox,
      { x = 8, y = 24, width = 256, height = 192 },
      "the content box sits inside the exterior insets"
    )
    local bodyPlacement = assert(geometry.placements["content"], "the framed pane places")
    local crop = bodyPlacement.crop or { left = 0, right = 0, top = 0, bottom = 0 }
    Assert.deepEqual(crop, { left = 0, right = 0, top = 0, bottom = 0 }, "decorated bodies never crop")
    Assert.deepEqual(
      bodyPlacement.visibleLogicalRect,
      { x = 0, y = 0, width = 256, height = 192 },
      "decorated bodies keep every source pixel visible"
    )
    local untyped = geometry --[[@as table<string, unknown>]]
    Assert.isNil(untyped.window, "static frames carry no window state")
    local first = geometry.placements["content"].frame
    local second =
      assert(policy.framed(context, { id = "content", width = 256, height = 192 }), "a second resolve places")
    Assert.deepEqual(second.placements["content"].frame, first, "repeated resolves stay centered")
  end
end

function T.tests.framed_returns_nil_when_no_complete_frame_fits()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(200, 150), 200, 150)
  local context = layoutContext(measurement, "wide")
  Assert.isNil(
    policy.framed(context, { id = "content", width = 256, height = 192 }),
    "a tiny host needs the nativeLike fallback"
  )
end

-- Same-display pairs frame their common envelope once: one 16x48 exterior
-- around the combined envelope, never once per pane.
function T.tests.same_display_pair_frames_its_envelope_once()
  local policy = sharedPolicy()
  local wide = layoutContext(measure(singleSurface(1280, 720), 1280, 720), "wide")
  local side = assert(
    policy.sideBySide(wide, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "a 720p host pairs two native panes"
  )
  local frame = assert(side.frames, "the pair carries its frame list")[1]
  Assert.notNil(frame, "one outer frame decorates the pair envelope")
  Assert.equal(frame.placement.logicalWidth, 528, "the pair frame adds side room once")
  Assert.equal(frame.placement.logicalHeight, 240, "the pair frame adds caps once")
  Assert.deepEqual(
    frame.contentBox,
    { x = 8, y = 24, width = 512, height = 192 },
    "the pair envelope starts inside the full exterior frame"
  )
  local tall = layoutContext(measure(singleSurface(390, 844), 390, 844), "tall")
  local stacked = assert(
    policy.stacked(tall, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "a tall host stacks two native panes"
  )
  local vertical = assert(stacked.frames, "the stack carries its frame list")[1]
  Assert.notNil(vertical, "one outer frame decorates the stacked envelope")
  Assert.equal(vertical.placement.logicalWidth, 272, "the stacked frame adds side room once")
  Assert.equal(vertical.placement.logicalHeight, 432, "the stacked frame adds caps once")
  Assert.deepEqual(
    vertical.contentBox,
    { x = 8, y = 24, width = 256, height = 384 },
    "the stacked envelope starts inside the full exterior frame"
  )
end

-- Undecorated centering keeps canonical content at integer scale with no
-- frame record for surfaces that publish no outer decoration.
function T.tests.centered_pane_carries_no_decoration()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(1280, 720), 1280, 720)
  local context = layoutContext(measurement, "wide")
  local geometry =
    assert(policy.centered(context, { id = "content", width = 256, height = 192 }), "a host centers the content")
  local placement = assert(geometry.placements["content"], "the centered pane places")
  Assert.equal(placement.logicalWidth, 256, "the centered body keeps its canonical width")
  Assert.equal(placement.logicalHeight, 192, "the centered body keeps its canonical height")
  Assert.deepEqual(geometry.frames or {}, {}, "centered geometry carries no frame")
end

-- Cover-or-frame never pairs crop with chrome: a placement whose visible
-- clip already fills its target publishes with no frame, an underfilled
-- target refits as a complete zero-crop decorated box, and a host below
-- any complete frame keeps its constrained candidate instead of a clipped
-- border.
function T.tests.cover_or_frame_prefers_full_coverage_then_decoration()
  local policy = sharedPolicy()
  local native = { id = "content", width = 256, height = 192 }
  local exact = layoutContext(measure(singleSurface(512, 384), 512, 384), "nativeLike")
  local covered = policy.coverOrFrame(exact, native, {})
  Assert.deepEqual(covered.frames, {}, "full target coverage publishes no frame")
  local wide = layoutContext(measure(singleSurface(750, 560), 750, 560), "nativeLike")
  local decorated = policy.coverOrFrame(wide, native, {})
  local body = assert(decorated.placements["content"], "the underfilled pane refits")
  Assert.deepEqual(
    body.crop or { left = 0, right = 0, top = 0, bottom = 0 },
    { left = 0, right = 0, top = 0, bottom = 0 },
    "a visible frame never coexists with body crop"
  )
  local frame = assert(decorated.frames, "the refit owns its frame list")[1]
  Assert.notNil(frame, "one outer frame decorates the refit pane")
  Assert.equal(frame.placement.logicalWidth, 272, "the refit frame adds side room")
  Assert.equal(frame.placement.logicalHeight, 240, "the refit frame reserves the top and bottom")
  Assert.deepEqual(
    frame.contentBox,
    { x = 8, y = 24, width = 256, height = 192 },
    "the refit body starts inside the exterior insets"
  )
  local tiny = layoutContext(measure(singleSurface(200, 150), 200, 150), "nativeLike")
  local constrained = policy.coverOrFrame(tiny, native, {})
  Assert.deepEqual(constrained.frames, {}, "a host below any frame keeps no clipped chrome")
  Assert.notNil(constrained.placements["content"], "the constrained host still places its body")
end

-- Same-display pairs share one integer scale with no synthetic gap: the
-- lower pane starts exactly where the upper pane ends, and the common
-- envelope is 512x192 horizontal or 256x384 vertical.
function T.tests.paired_panes_are_edge_adjacent_with_a_common_envelope()
  local policy = sharedPolicy()
  local wide = layoutContext(measure(singleSurface(1280, 720), 1280, 720), "wide")
  local side = assert(
    policy.sideBySide(wide, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "a 720p host pairs two native panes"
  )
  local upper = assert(side.placements["upper"], "the upper pane places")
  local lower = assert(side.placements["lower"], "the lower pane places")
  Assert.near(upper.frame.x + upper.frame.width, lower.frame.x, 1e-6, "horizontal panes touch with no gap")
  local wideEnvelope = assert(side.envelope, "the pair publishes its common envelope")
  Assert.equal(wideEnvelope.logicalWidth, 512, "the horizontal envelope spans both panes")
  Assert.equal(wideEnvelope.logicalHeight, 192, "the horizontal envelope keeps pane height")
  local tall = layoutContext(measure(singleSurface(390, 844), 390, 844), "tall")
  local stacked = assert(
    policy.stacked(tall, { id = "upper", width = 256, height = 192 }, { id = "lower", width = 256, height = 192 }),
    "a tall host stacks two native panes"
  )
  local top = assert(stacked.placements["upper"], "the top pane places")
  local bottom = assert(stacked.placements["lower"], "the bottom pane places")
  Assert.near(top.frame.y + top.frame.height, bottom.frame.y, 1e-6, "vertical panes touch with no gap")
  local tallEnvelope = assert(stacked.envelope, "the stack publishes its common envelope")
  Assert.equal(tallEnvelope.logicalWidth, 256, "the vertical envelope keeps pane width")
  Assert.equal(tallEnvelope.logicalHeight, 384, "the vertical envelope spans both panes")
end

-- Geometry names no transition coverage and never a settled background
-- contract: placement and frames are the whole geometry record.
function T.tests.geometry_names_no_transition_coverage_and_no_settled_background()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(640, 480), 640, 480)
  local geometry =
    policy.fullscreen(layoutContext(measurement, "nativeLike"), { id = "content", width = 256, height = 192 })
  local untyped = geometry --[[@as table<string, unknown>]]
  Assert.isNil(untyped.fadeCoverage, "geometry carries no transition coverage")
  Assert.isNil(untyped.backgroundColor, "geometry carries no settled background color")
end

return T
