-- Shared application display policy: actual host surfaces classify into one
-- of four configurations before any application geometry is fitted. A
-- genuine world/auxiliary pair is dual; a near-4:3 single surface stays a
-- fullscreen native surface across decorations (enter within 12 logical
-- pixels per edge, retain within 14); anything else is a wide or tall
-- surface that frames the application in a draggable window. The band and
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

function T.tests.near_native_single_surfaces_stay_fullscreen_instead_of_windowing()
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
  Assert.equal(wide, "wide", "a 16:9 host frames the application in a window")
  for _, size in ipairs({
    { width = 390, height = 844 },
    { width = 512, height = 512 },
  }) do
    local configuration = policy.classify(measure(singleSurface(size.width, size.height), size.width, size.height))
    Assert.equal(configuration, "tall", size.width .. "x" .. size.height .. " frames the application in a window")
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
  -- 640x430 is a ~14.9 error: past retain, so it leaves native for a window.
  local windowed = classifyAt(640, 430, held)
  Assert.isTrue(windowed == "wide" or windowed == "tall", "an error past the retain band leaves native")
  -- Back at a ~12.9 error without native history, the entry band refuses it.
  Assert.equal(classifyAt(640, 436, windowed), windowed, "re-entry into native needs the entry band again")
end

local function selectionFor(topology, width, height, pixelRatio)
  local policy = sharedPolicy()
  return policy.selectSurfaces(measure(topology, width, height, pixelRatio))
end

local function layoutContext(measurement, configuration, windowPosition, nativeLikeInterface)
  local policy = sharedPolicy()
  local selection = policy.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    windowPosition = windowPosition or { x = 0.5, y = 0.5 },
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
  Assert.equal(#geometry.coverage, 1, "fullscreen owns its target region")
  Assert.isNil(geometry.window, "fullscreen carries no window")
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
  Assert.deepEqual(geometry.coverage, {}, "occlusion publishes no coverage")
end

function T.tests.windowed_frames_content_with_border_title_and_grab_rect()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(1280, 720), 1280, 720)
  local context = layoutContext(measurement, "wide")
  local geometry =
    assert(policy.windowed(context, { id = "content", width = 256, height = 192 }), "a 720p host frames a window")
  local window = assert(geometry.window, "wide carries a window")
  Assert.equal(window.outer.logicalWidth, 258, "the outer frame adds the 1px border on both sides")
  Assert.equal(window.outer.logicalHeight, 206, "the outer frame adds border plus the 12px title strip")
  Assert.deepEqual(
    { window.body.logicalWidth, window.body.logicalHeight },
    { 256, 192 },
    "the body keeps canonical content dimensions"
  )
  Assert.deepEqual(geometry.coverage, {}, "a window owns no fullscreen coverage")
  Assert.isTrue(window.grabRect.width > 0 and window.grabRect.height > 0, "the title strip grabs")
  local bodyOriginX, bodyOriginY =
    window.body.origin.x - window.outer.origin.x, window.body.origin.y - window.outer.origin.y
  Assert.isTrue(math.abs(bodyOriginX / window.outer.scale - 1) < 1e-9, "the body starts past the left border")
  Assert.isTrue(math.abs(bodyOriginY / window.outer.scale - 13) < 1e-9, "the body starts below the title strip")
end

function T.tests.windowed_falls_back_when_no_integer_frame_fits()
  local policy = sharedPolicy()
  local measurement = measure(singleSurface(200, 150), 200, 150)
  local context = layoutContext(measurement, "wide")
  Assert.isNil(
    policy.windowed(context, { id = "content", width = 256, height = 192 }),
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
  Assert.equal(#geometry.coverage, 2, "dual coverage owns one region per actual surface")
end

function T.tests.side_by_side_shares_one_scale_across_the_gap()
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
  Assert.equal(#geometry.coverage, 1, "a composed pair owns its single-display region")
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

return T
