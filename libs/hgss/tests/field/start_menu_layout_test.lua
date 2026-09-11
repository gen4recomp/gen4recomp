-- Responsive Start Menu placement: the canonical 256x192 surface is mapped
-- through ScreenTopology as one whole surface relative to the actual world
-- reference frame the FieldViewport computes -- dual-screen auxiliary,
-- landscape/ultrawide right gutter (reference frame right edge to safe
-- right), single 4:3 overlay, portrait lower panel below the reference
-- frame, safe areas -- with the internal geometry invariant. The tests pin
-- the placement record shape ({ surfaceId, frame, scale, logicalWidth,
-- logicalHeight }), uniform-scale/center/deterministic-rounding invariants,
-- and the pointer transform (reject outside frame, map host to canonical
-- 0..255 x 0..191) over the one record shared by hit testing and rendering.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")

local T = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function display(id, width, height, opts)
  opts = opts or {}
  return {
    id = id,
    rect = opts.rect or rect(0, 0, width, height),
    safeRect = opts.safeRect,
    role = opts.role or "world",
    touch = opts.touch == true,
  }
end

local function oneDisplay(width, height, opts)
  return ScreenTopology.oneDisplay(display(opts and opts.id or "main", width, height, opts))
end

-- The world reference frame production derives: FieldViewport in expanded
-- mode, exactly what FieldRuntime passes to StartMenuLayout.resolve.
local function referenceFor(width, height)
  return FieldViewport.new(width, height, { mode = "expanded" }).referenceFrame
end

-- The placement record exactly per the layout contract: the chosen surface
-- id, the host-space frame (snapped origin, exact scale-derived extent), the uniform scale, and the fixed logical
-- dimensions. No extra keys, so hit testing and rendering share one record.
function T.placement_record_has_exactly_the_pinned_shape()
  local record = StartMenuLayout.resolve(oneDisplay(256, 192), referenceFor(256, 192))
  Assert.deepEqual(record, {
    surfaceId = "main",
    frame = { x = 0, y = 0, width = 256, height = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
  })
end

-- The responsive matrix: every topology row pins its exact record plus the
-- uniform-scale/inside-safe/snapped-origin/exact-extent invariants. Reference frames
-- mirror the FieldViewport derivation for the same host size.
function T.responsive_matrix_places_every_topology_as_a_whole_surface()
  local dual = ScreenTopology.dualDisplay(display("world", 256, 192), display("aux", 256, 192, { role = "auxiliary" }))
  local matrix = {
    {
      name = "256x192 canonical",
      topology = oneDisplay(256, 192),
      host = { 256, 192 },
      expected = { surfaceId = "main", frame = { 0, 0, 256, 192 }, scale = 1 },
    },
    {
      name = "1280x960 4:3",
      topology = oneDisplay(1280, 960),
      host = { 1280, 960 },
      expected = { surfaceId = "main", frame = { 0, 0, 1280, 960 }, scale = 5 },
    },
    {
      name = "1920x1080 16:9",
      topology = oneDisplay(1920, 1080),
      host = { 1920, 1080 },
      expected = { surfaceId = "main", frame = { 1680, 450, 240, 180 }, scale = 0.9375 },
    },
    {
      name = "2560x1080 ultrawide",
      topology = oneDisplay(2560, 1080),
      host = { 2560, 1080 },
      expected = { surfaceId = "main", frame = { 2000, 330, 560, 420 }, scale = 2.1875 },
    },
    {
      name = "1080x1920 portrait",
      topology = oneDisplay(1080, 1920),
      host = { 1080, 1920 },
      expected = { surfaceId = "main", frame = { 170, 1365, 740, 555 }, scale = 2.890625 },
    },
    {
      name = "390x844 phone portrait",
      topology = oneDisplay(390, 844),
      host = { 390, 844 },
      expected = { surfaceId = "main", frame = { 11, 568, 368, 276 }, scale = 1.4375 },
    },
    {
      name = "844x390 phone landscape",
      topology = oneDisplay(844, 390),
      host = { 844, 390 },
      expected = { surfaceId = "main", frame = { 682, 134, 162, 121.5 }, scale = 0.6328125 },
    },
    {
      name = "dual 256x192-style surfaces",
      topology = dual,
      expected = { surfaceId = "aux", frame = { 0, 0, 256, 192 }, scale = 1 },
    },
  }
  for _, row in ipairs(matrix) do
    local reference = row.host and referenceFor(row.host[1], row.host[2]) or rect(0, 0, 256, 192)
    local record = StartMenuLayout.resolve(row.topology, reference)
    Assert.deepEqual(record, {
      surfaceId = row.expected.surfaceId,
      frame = {
        x = row.expected.frame[1],
        y = row.expected.frame[2],
        width = row.expected.frame[3],
        height = row.expected.frame[4],
      },
      scale = row.expected.scale,
      logicalWidth = 256,
      logicalHeight = 192,
    }, row.name .. " placement record")
    local safe = StartMenuLayout.selectSurface(row.topology).safeRect
    local frame = record.frame
    Assert.isTrue(
      frame.x >= safe.x
        and frame.y >= safe.y
        and frame.x + frame.width <= safe.x + safe.width
        and frame.y + frame.height <= safe.y + safe.height,
      row.name .. " frame must stay inside the safe rectangle"
    )
    for _, value in ipairs({ frame.x, frame.y }) do
      Assert.equal(value, math.floor(value), row.name .. " origin must be integer at the host boundary")
    end
    Assert.near(frame.width, 256 * record.scale, 1e-9, row.name .. " width is the exact rendered extent")
    Assert.near(frame.height, 192 * record.scale, 1e-9, row.name .. " height is the exact rendered extent")
    Assert.isTrue(record.scale > 0, row.name .. " scale must be positive")
  end
end

-- The dual-screen rule: the auxiliary display is the menu screen, and the
-- whole surface fills a 4:3 auxiliary at its own origin.
function T.dual_display_places_the_menu_on_the_auxiliary_surface()
  local auxiliary = display("bottom", 256, 192, { rect = rect(256, 240, 256, 192), role = "auxiliary" })
  local record =
    StartMenuLayout.resolve(ScreenTopology.dualDisplay(display("top", 256, 192), auxiliary), rect(0, 0, 256, 192))
  Assert.equal(record.surfaceId, "bottom")
  Assert.deepEqual(record.frame, { x = 256, y = 240, width = 256, height = 192 })

  local large = StartMenuLayout.resolve(
    ScreenTopology.dualDisplay(display("world", 256, 192), display("aux", 512, 384, { role = "auxiliary" })),
    rect(0, 0, 256, 192)
  )
  Assert.equal(large.surfaceId, "aux")
  Assert.deepEqual(large.frame, { x = 0, y = 0, width = 512, height = 384 })
  Assert.equal(large.scale, 2)
end

-- Wide landscape: the menu is a side panel in the actual right gutter --
-- the real world reference frame's right edge to the safe right -- scaled
-- to fit, still 4:3 internally.
function T.wide_landscape_uses_the_real_right_gutter_of_the_world_frame()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080))
  local reference = referenceFor(1920, 1080)
  Assert.deepEqual(reference, { x = 240, y = 0, width = 1440, height = 1080 })
  Assert.deepEqual(record.frame, { x = 1680, y = 450, width = 240, height = 180 })
  Assert.equal(record.scale, 0.9375)
  Assert.isTrue(
    record.frame.x >= reference.x + reference.width,
    "the menu must sit in the right gutter, clear of the reference frame"
  )
  Assert.equal(record.frame.height / record.frame.width, 3 / 4, "the surface must stay 4:3 internally")
end

-- Ultrawide uses the same model: the menu never stretches across the unused
-- horizontal space and never overlaps the canonical frame.
function T.ultrawide_keeps_the_menu_panel_without_horizontal_stretch()
  local record = StartMenuLayout.resolve(oneDisplay(2560, 1080), referenceFor(2560, 1080))
  local reference = referenceFor(2560, 1080)
  Assert.deepEqual(record.frame, { x = 2000, y = 330, width = 560, height = 420 })
  Assert.isTrue(record.frame.width < 2560, "the menu must not stretch across the host width")
  Assert.isTrue(record.frame.x >= reference.x + reference.width, "the panel must stay right of the reference frame")
  Assert.equal(record.frame.height / record.frame.width, 3 / 4)
end

-- A gutter wide enough for the full height: the scale binds to the gutter
-- width and the menu is centered in the gutter.
function T.side_panel_scales_to_the_available_height_when_the_panel_is_tall()
  local record = StartMenuLayout.resolve(oneDisplay(4000, 1080), referenceFor(4000, 1080))
  Assert.equal(record.scale, 5)
  Assert.deepEqual(record.frame, { x = 2720, y = 60, width = 1280, height = 960 })
  Assert.equal(record.frame.height, 960, "the menu scales to the available panel height")
end

-- Single 4:3 host: the surface is a modal overlay that fills the host.
function T.single_four_by_three_host_is_a_full_surface_overlay()
  local record = StartMenuLayout.resolve(oneDisplay(1280, 960), referenceFor(1280, 960))
  Assert.deepEqual(record.frame, { x = 0, y = 0, width = 1280, height = 960 })
  Assert.equal(record.scale, 5)
end

-- Portrait partitions vertically relative to the real reference geometry:
-- the menu is a full-width lower panel below the reference frame's bottom
-- edge.
function T.portrait_partitions_vertically_into_a_lower_panel()
  local record = StartMenuLayout.resolve(oneDisplay(1080, 1920), referenceFor(1080, 1920))
  local reference = referenceFor(1080, 1920)
  Assert.deepEqual(record.frame, { x = 170, y = 1365, width = 740, height = 555 })
  Assert.equal(record.frame.y, math.floor(reference.y + reference.height), "the panel starts at the reference bottom")
  Assert.equal(
    record.frame.y + record.frame.height,
    1920,
    "the lower panel must sit at the bottom of the safe rectangle"
  )
end

-- The portrait partition is subject to minimum usable sizes: when the world
-- region or the panel would become unusable, the layout falls back to the
-- centered uniform fit so the whole surface is still placed inside bounds.
function T.portrait_partition_falls_back_when_a_region_is_too_small()
  local record = StartMenuLayout.resolve(oneDisplay(390, 370), referenceFor(390, 370))
  Assert.deepEqual(record.frame, { x = 0, y = 38, width = 390, height = 292.5 })
  Assert.equal(record.scale, 1.5234375)

  local tiny = StartMenuLayout.resolve(oneDisplay(100, 300), referenceFor(100, 300))
  Assert.deepEqual(tiny.frame, { x = 0, y = 112, width = 100, height = 75 })
  Assert.equal(tiny.scale, 0.390625)
end

-- Safe areas: the whole canonical surface is scaled and placed inside the
-- safe rectangle, never reflowed around the occupied space; the gutter is
-- the intersection of the reference frame's right edge with the safe rect.
function T.safe_areas_keep_the_whole_surface_inside_the_safe_rectangle()
  local offset = oneDisplay(1920, 1080, { safeRect = rect(100, 100, 1600, 900) })
  local record = StartMenuLayout.resolve(offset, referenceFor(1920, 1080))
  Assert.deepEqual(record.frame, { x = 300, y = 100, width = 1200, height = 900 })
  Assert.equal(record.scale, 4.6875)
  local safe = offset.surfaces[1].safeRect
  Assert.isTrue(
    record.frame.x >= safe.x
      and record.frame.y >= safe.y
      and record.frame.x + record.frame.width <= safe.x + safe.width
      and record.frame.y + record.frame.height <= safe.y + safe.height,
    "the frame must stay inside the safe rectangle"
  )

  local fractional = oneDisplay(1920, 1080, { safeRect = rect(0, 80, 1920, 920) })
  local fractionalRecord = StartMenuLayout.resolve(fractional, referenceFor(1920, 1080))
  Assert.deepEqual(fractionalRecord.frame, { x = 1680, y = 450, width = 240, height = 180 })
end

-- A same-size safe-rect change moves the placement even though the window
-- dimensions did not: the layout is derived from the safe geometry and the
-- reference frame, never from the window size alone.
function T.a_safe_rect_change_recomputes_the_placement_at_the_same_dimensions()
  local full = StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080))
  Assert.deepEqual(full.frame, { x = 1680, y = 450, width = 240, height = 180 })
  local narrowed =
    StartMenuLayout.resolve(oneDisplay(1920, 1080, { safeRect = rect(0, 0, 1600, 1080) }), referenceFor(1920, 1080))
  Assert.deepEqual(narrowed.frame, { x = 80, y = 0, width = 1440, height = 1080 })
  Assert.isTrue(
    narrowed.frame.x ~= full.frame.x or narrowed.frame.width ~= full.frame.width,
    "the safe-rect change must move the placement"
  )
end

-- Deterministic pixel rounding at the host-space boundary: odd host sizes
-- snap only the origin to integer pixels, and repeated resolution returns
-- the same record.
function T.placement_is_deterministic_and_rounds_at_the_host_boundary()
  local odd = oneDisplay(999, 800)
  local first = StartMenuLayout.resolve(odd, referenceFor(999, 800))
  local second = StartMenuLayout.resolve(odd, referenceFor(999, 800))
  Assert.deepEqual(first, second)
  Assert.deepEqual(first.frame, { x = 0, y = 25, width = 999, height = 749.25 })
  Assert.equal(first.scale, 999 / 256)
end

-- A landscape host too narrow for a usable side panel falls back to the
-- centered overlay instead of shrinking the menu next to the world frame.
function T.narrow_side_panels_fall_back_to_the_centered_overlay()
  local record = StartMenuLayout.resolve(oneDisplay(1280, 900), referenceFor(1280, 900))
  Assert.deepEqual(record.frame, { x = 40, y = 0, width = 1200, height = 900 })
  Assert.equal(record.scale, 4.6875)
end

-- Surface selection follows the sibling MenuLayout shape: auxiliary first,
-- else the first surface.
function T.selection_prefers_the_auxiliary_surface_and_falls_back_to_the_first()
  local three = ScreenTopology.new({
    surfaces = {
      display("world-a", 256, 192),
      display("world-b", 256, 192),
      display("bottom", 256, 192, { role = "auxiliary" }),
    },
  })
  Assert.equal(StartMenuLayout.selectSurface(three).id, "bottom")
  Assert.equal(StartMenuLayout.resolve(three, rect(0, 0, 256, 192)).surfaceId, "bottom")

  local worlds = ScreenTopology.new({ surfaces = { display("world-a", 256, 192), display("world-b", 256, 192) } })
  Assert.equal(StartMenuLayout.selectSurface(worlds).id, "world-a")
  Assert.equal(StartMenuLayout.resolve(worlds, rect(0, 0, 256, 192)).surfaceId, "world-a")
end

-- The pointer transform: hit testing rejects every point outside the frame,
-- then maps inside points back to canonical 0..255 x 0..191 logical space.
function T.host_to_logical_rejects_outside_the_frame_and_maps_inside_points()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080))
  local outside = {
    { 100, 100 },
    { 1500, 100 },
    { 1500, 1000 },
    { 2000, 500 },
    { 1679, 540 },
    { 1920, 540 },
    { 1680, 449 },
    { 1680, 631 },
  }
  for _, point in ipairs(outside) do
    Assert.isNil(StartMenuLayout.hostToLogical(record, point[1], point[2]), "points outside the frame must be rejected")
  end
  local canonicalX, canonicalY = StartMenuLayout.hostToLogical(record, 1680, 540)
  Assert.equal(canonicalX, 0)
  Assert.equal(canonicalY, 96)
end

-- One record shared by hit testing and rendering: the renderer draws the
-- canonical surface at frame origin under uniform scale, and hostToLogical is
-- the exact inverse of that placement -- slot rects live only in canonical
-- space and are never scaled into a second set of host rectangles.
function T.hit_testing_and_rendering_share_one_record_with_an_exact_round_trip()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080))
  local points = {}
  for slotId = 1, 10 do
    local slot = FieldUiFixture.START_MENU_SLOTS[slotId]
    points[#points + 1] = { slot.x, slot.y }
    points[#points + 1] = { slot.x + slot.width - 1, slot.y + slot.height - 1 }
  end
  points[#points + 1] = { 0, 0 }
  points[#points + 1] = { 255, 191 }
  for _, point in ipairs(points) do
    local hostX = record.frame.x + point[1] * record.scale
    local hostY = record.frame.y + point[2] * record.scale
    local canonicalX, canonicalY = StartMenuLayout.hostToLogical(record, hostX, hostY)
    Assert.notNil(canonicalX, "a rendered canonical point must hit-test inside the frame")
    Assert.notNil(canonicalY, "a rendered canonical point must hit-test inside the frame")
    Assert.equal(canonicalX, point[1])
    Assert.equal(canonicalY, point[2])
  end
end

-- The rendered surface spans exactly the frame: the canonical edge maps to
-- the frame's far corner, which the transform rejects (the half-open frame).
function T.the_canonical_edge_maps_to_the_rejected_frame_boundary()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080))
  local cornerX = record.frame.x + 256 * record.scale
  local cornerY = record.frame.y + 192 * record.scale
  Assert.near(cornerX, record.frame.x + record.frame.width, 1e-9)
  Assert.near(cornerY, record.frame.y + record.frame.height, 1e-9)
  Assert.isNil(StartMenuLayout.hostToLogical(record, cornerX, cornerY), "the frame's far edge is outside the surface")
end

-- Fractional placements keep the exact render extent: the frame is the
-- logical surface times the uniform scale with only the origin snapped, so
-- the renderer's translate(origin) + scale transform lands exactly on the
-- hit-test frame and the far edge is the half-open rejection boundary.
function T.fractional_placements_keep_the_exact_render_extent_for_hit_testing()
  local cases = {
    { width = 999, height = 800 },
    { width = 844, height = 390 },
  }
  for _, size in ipairs(cases) do
    local record = StartMenuLayout.resolve(oneDisplay(size.width, size.height), referenceFor(size.width, size.height))
    local label = size.width .. "x" .. size.height
    Assert.equal(record.frame.x, math.floor(record.frame.x), label .. " origin x stays snapped")
    Assert.equal(record.frame.y, math.floor(record.frame.y), label .. " origin y stays snapped")
    Assert.near(record.frame.width, 256 * record.scale, 1e-9, label .. " width matches the rendered extent")
    Assert.near(record.frame.height, 192 * record.scale, 1e-9, label .. " height matches the rendered extent")
    local edgeX = record.frame.x + 256 * record.scale
    local edgeY = record.frame.y + 192 * record.scale
    Assert.near(edgeX, record.frame.x + record.frame.width, 1e-9, label .. " horizontal render edge meets the frame")
    Assert.near(edgeY, record.frame.y + record.frame.height, 1e-9, label .. " vertical render edge meets the frame")
    Assert.isNil(
      StartMenuLayout.hostToLogical(record, edgeX, edgeY),
      label .. " the rendered far edge is outside the half-open frame"
    )
    local insideX, insideY = StartMenuLayout.hostToLogical(record, edgeX - 0.5, edgeY - 0.5)
    assert(insideX ~= nil, label .. " a point just inside the rendered edge must hit-test")
    assert(insideY ~= nil, label .. " a point just inside the rendered edge must hit-test")
    Assert.near(insideX, 256 - 0.5 / record.scale, 1e-9, label .. " the inside point maps through the shared scale")
    Assert.near(insideY, 192 - 0.5 / record.scale, 1e-9, label .. " the inside point maps through the shared scale")
  end
end

-- Programming invariants: a malformed topology or placement record is a
-- fault, never a guessed default; the world reference frame is a required
-- input.
function T.rejects_malformed_inputs()
  local nothing = nil ---@type any
  Assert.throws(function()
    StartMenuLayout.resolve(nothing, rect(0, 0, 256, 192))
  end, "resolve requires a topology")
  Assert.throws(function()
    StartMenuLayout.resolve({ surfaces = {} }, rect(0, 0, 256, 192))
  end, "resolve requires at least one surface")
  Assert.throws(function()
    StartMenuLayout.resolve(oneDisplay(100, 100), nothing)
  end, "resolve requires the world reference frame")
  Assert.throws(function()
    StartMenuLayout.resolve(oneDisplay(100, 100, { safeRect = rect(0.5, 0, 100, 100) }), rect(0, 0, 100, 100))
  end, "fractional safe rectangles are unsupported")
  Assert.throws(function()
    StartMenuLayout.selectSurface(nothing)
  end, "selectSurface requires a topology")
  local notARecord = {} ---@type any
  Assert.throws(function()
    StartMenuLayout.hostToLogical(notARecord, 10, 10)
  end, "hostToLogical requires a placement record")
  local text = "10" ---@type any
  Assert.throws(function()
    StartMenuLayout.hostToLogical(StartMenuLayout.resolve(oneDisplay(1920, 1080), referenceFor(1920, 1080)), text, 10)
  end, "host coordinates must be numbers")
end

return { tests = T }
