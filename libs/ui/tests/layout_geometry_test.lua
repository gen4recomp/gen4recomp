-- Game-independent rectangle, fit, and coordinate-transform geometry. The
-- placement record carries the exact frame, scale, and logical dimensions
-- rendering uses, so pointer mapping inverts the same record with no second
-- transform.

local Assert = require("tests.support.Assert")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

function T.rect_copies_and_validates()
  local source = rect(1, 2, 256, 192)
  local copied = LayoutGeometry.rect(source, "frame")
  Assert.deepEqual(copied, source)
  copied.x = 99
  Assert.equal(source.x, 1, "the returned rectangle must be owned by the caller")
  local nothing = nil ---@type any
  Assert.throws(function()
    LayoutGeometry.rect(nothing, "frame")
  end)
  Assert.throws(function()
    LayoutGeometry.rect(rect(0, 0, 0, 10), "frame")
  end)
  Assert.throws(function()
    LayoutGeometry.rect(rect(0, 0, 10, -1), "frame")
  end)
  Assert.throws(function()
    LayoutGeometry.rect(rect(0 / 0, 0, 10, 10), "frame")
  end)
  Assert.throws(function()
    LayoutGeometry.rect(rect(0, 0, math.huge, 10), "frame")
  end)
end

function T.contains_distinguishes_inside_from_edge_and_outside()
  local outer = rect(0, 0, 100, 100)
  Assert.isTrue(LayoutGeometry.contains(outer, rect(10, 10, 20, 20)))
  Assert.isTrue(LayoutGeometry.contains(outer, rect(0, 0, 100, 100)), "touching edges are contained")
  Assert.isFalse(LayoutGeometry.contains(outer, rect(-1, 10, 20, 20)))
  Assert.isFalse(LayoutGeometry.contains(outer, rect(10, 10, 200, 20)))
  Assert.isFalse(LayoutGeometry.contains(outer, rect(90, 90, 20, 20)))
end

function T.contains_point_uses_the_render_half_open_frame()
  local frame = rect(10, 20, 100, 50)
  Assert.isTrue(LayoutGeometry.containsPoint(frame, 10, 20))
  Assert.isTrue(LayoutGeometry.containsPoint(frame, 109, 69))
  Assert.isFalse(LayoutGeometry.containsPoint(frame, 110, 69), "the far vertical edge is outside")
  Assert.isFalse(LayoutGeometry.containsPoint(frame, 109, 70), "the far horizontal edge is outside")
  Assert.isFalse(LayoutGeometry.containsPoint(frame, 9, 20))
end

function T.overlaps_matches_axis_aligned_intersection()
  Assert.isTrue(LayoutGeometry.overlaps(rect(0, 0, 10, 10), rect(5, 5, 10, 10)))
  Assert.isTrue(LayoutGeometry.overlaps(rect(0, 0, 10, 10), rect(0, 0, 10, 10)))
  Assert.isFalse(LayoutGeometry.overlaps(rect(0, 0, 10, 10), rect(10, 0, 10, 10)), "edge touch is not overlap")
  Assert.isFalse(LayoutGeometry.overlaps(rect(0, 0, 10, 10), rect(20, 20, 5, 5)))
end

function T.inset_shrinks_symmetrically_and_rejects_overflow()
  Assert.deepEqual(LayoutGeometry.inset(rect(0, 0, 100, 80), 8), rect(8, 8, 84, 64))
  Assert.throws(function()
    LayoutGeometry.inset(rect(0, 0, 10, 10), 6)
  end)
end

function T.centered_fit_of_identical_bounds_is_identity()
  local placement = LayoutGeometry.centeredFit(rect(0, 0, 256, 192), 256, 192)
  Assert.equal(placement.scale, 1)
  Assert.deepEqual(placement.frame, rect(0, 0, 256, 192))
  Assert.deepEqual(placement.origin, { x = 0, y = 0 })
  Assert.equal(placement.logicalWidth, 256)
  Assert.equal(placement.logicalHeight, 192)
end

function T.centered_fit_centers_wide_and_tall_bounds()
  local wide = LayoutGeometry.centeredFit(rect(0, 0, 512, 192), 256, 192)
  Assert.equal(wide.scale, 1)
  Assert.deepEqual(wide.frame, rect(128, 0, 256, 192))
  local tall = LayoutGeometry.centeredFit(rect(0, 0, 256, 384), 256, 192)
  Assert.equal(tall.scale, 1)
  Assert.deepEqual(tall.frame, rect(0, 96, 256, 192))
  local scaled = LayoutGeometry.centeredFit(rect(10, 20, 640, 480), 256, 192)
  Assert.equal(scaled.scale, 2.5)
  Assert.deepEqual(scaled.frame, rect(10, 20, 640, 480))
end

function T.centered_fit_never_exceeds_bounds_and_rejects_invalid_input()
  local placement = LayoutGeometry.centeredFit(rect(5, 5, 100, 100), 256, 192)
  Assert.isTrue(placement.frame.width <= 100 and placement.frame.height <= 100)
  Assert.isTrue(LayoutGeometry.contains(rect(5, 5, 100, 100), placement.frame))
  local nothing = nil ---@type any
  Assert.throws(function()
    LayoutGeometry.centeredFit(nothing, 256, 192)
  end)
  Assert.throws(function()
    LayoutGeometry.centeredFit(rect(0, 0, 100, 100), 0, 192)
  end)
  Assert.throws(function()
    LayoutGeometry.centeredFit(rect(0, 0, 0 / 0, 100), 256, 192)
  end)
end

function T.centered_fit_integer_option_stays_inside_bounds()
  local boundsSet = {
    rect(0, 0, 999, 800),
    rect(0, 0, 100, 100),
    rect(17, 31, 844, 390),
    rect(0, 0, 390, 844),
  }
  for _, bounds in ipairs(boundsSet) do
    local placement = LayoutGeometry.centeredFit(bounds, 256, 192, { integer = "floor" })
    local frame = placement.frame
    Assert.equal(frame.x, math.floor(frame.x), "only the origin x is snapped")
    Assert.equal(frame.y, math.floor(frame.y), "only the origin y is snapped")
    Assert.near(frame.width, 256 * placement.scale, 1e-9, "the frame width is the exact logical width times scale")
    Assert.near(frame.height, 192 * placement.scale, 1e-9, "the frame height is the exact logical height times scale")
    Assert.isTrue(LayoutGeometry.contains(bounds, frame), "the exact frame must stay inside bounds")
  end
  local odd = LayoutGeometry.centeredFit(rect(0, 0, 999, 800), 256, 192, { integer = "floor" })
  Assert.equal(odd.scale, 999 / 256)
  Assert.near(odd.frame.width, 999, 1e-9)
  Assert.near(odd.frame.height, 192 * (999 / 256), 1e-9)
  Assert.deepEqual({ x = odd.frame.x, y = odd.frame.y }, { x = 0, y = 25 })
  -- Origin snapping centers the exact dimensions: centering the exact height
  -- (292.5) leaves (370 - 292.5) / 2 = 38.75, which floors to 38.
  local snapped = LayoutGeometry.centeredFit(rect(0, 0, 390, 370), 256, 192, { integer = "floor" })
  Assert.near(snapped.frame.width, 390, 1e-9)
  Assert.near(snapped.frame.height, 192 * (390 / 256), 1e-9)
  Assert.deepEqual({ x = snapped.frame.x, y = snapped.frame.y }, { x = 0, y = 38 })
end

function T.centered_fit_floor_keeps_exact_dimensions_and_snaps_only_the_origin()
  local placement = LayoutGeometry.centeredFit(rect(0, 0, 999, 800), 256, 192, { integer = "floor" })
  Assert.equal(placement.scale, 999 / 256)
  Assert.near(
    placement.frame.width,
    256 * placement.scale,
    1e-9,
    "the frame width is the exact logical width times scale"
  )
  Assert.near(
    placement.frame.height,
    192 * placement.scale,
    1e-9,
    "the frame height is the exact logical height times scale"
  )
  Assert.equal(placement.frame.x, math.floor(placement.frame.x), "floor mode snaps the origin x")
  Assert.equal(placement.frame.y, math.floor(placement.frame.y), "floor mode snaps the origin y")
  Assert.deepEqual(placement.origin, { x = placement.frame.x, y = placement.frame.y })
  Assert.isTrue(
    LayoutGeometry.contains(rect(0, 0, 999, 800), placement.frame),
    "the exact frame must stay inside bounds"
  )
  local rounded = LayoutGeometry.centeredFit(rect(0, 0, 390, 370), 256, 192, { integer = "round" })
  Assert.near(rounded.frame.width, 256 * rounded.scale, 1e-9, "round mode keeps the exact width")
  Assert.near(rounded.frame.height, 192 * rounded.scale, 1e-9, "round mode keeps the exact height")
  Assert.equal(rounded.frame.x, math.floor(rounded.frame.x + 0.5), "round mode snaps the origin x")
  Assert.equal(rounded.frame.y, math.floor(rounded.frame.y + 0.5), "round mode snaps the origin y")
end

function T.fractional_fit_round_trips_near_edge_points_and_rejects_the_rendered_far_edge()
  local placement = LayoutGeometry.centeredFit(rect(0, 0, 999, 800), 256, 192, { integer = "floor" })
  local logicalX, logicalY = 128, 191.99
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  local backX, backY = LayoutGeometry.hostToLogical(placement, hostX, hostY)
  assert(backX ~= nil, "a rendered interior point near the far edge must hit-test inside the frame")
  assert(backY ~= nil, "a rendered interior point near the far edge must hit-test inside the frame")
  Assert.near(backX, logicalX, 1e-9)
  Assert.near(backY, logicalY, 1e-9)
  local edgeX, edgeY = LayoutGeometry.logicalToHost(placement, 256, 192)
  Assert.near(edgeX, placement.frame.x + placement.frame.width, 1e-9, "the logical far corner is the rendered edge")
  Assert.near(edgeY, placement.frame.y + placement.frame.height, 1e-9, "the logical far corner is the rendered edge")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, edgeX, edgeY), "the rendered far edge is half-open")
  local insideX, insideY = LayoutGeometry.hostToLogical(placement, edgeX - 1e-4, edgeY - 1e-4)
  Assert.notNil(insideX, "a point just inside the rendered edge must hit-test")
  Assert.notNil(insideY, "a point just inside the rendered edge must hit-test")
end

function T.host_logical_transforms_round_trip_and_reject_outside_points()
  local placement = LayoutGeometry.centeredFit(rect(0, 0, 640, 480), 256, 192)
  local points = { { 0, 0 }, { 255, 191 }, { 128, 96 }, { 10, 180 } }
  for _, point in ipairs(points) do
    local hostX, hostY = LayoutGeometry.logicalToHost(placement, point[1], point[2])
    local logicalX, logicalY = LayoutGeometry.hostToLogical(placement, hostX, hostY)
    Assert.notNil(logicalX, "a rendered point must map back inside the frame")
    Assert.notNil(logicalY, "a rendered point must map back inside the frame")
    Assert.equal(logicalX, point[1])
    Assert.equal(logicalY, point[2])
  end
  Assert.isNil(LayoutGeometry.hostToLogical(placement, -1, 10), "points left of the frame are rejected")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 640, 480), "the far corner maps to the rejected frame boundary")
  local offset = LayoutGeometry.centeredFit(rect(100, 50, 640, 480), 256, 192)
  local hostX, hostY = LayoutGeometry.logicalToHost(offset, 0, 0)
  Assert.equal(hostX, offset.frame.x)
  Assert.equal(hostY, offset.frame.y)
end

function T.minimal_placements_without_origin_or_clip_map_the_whole_frame()
  local placement = { frame = rect(10, 20, 100, 50), scale = 2 }
  local logicalX, logicalY = LayoutGeometry.hostToLogical(placement, 10, 20)
  Assert.equal(logicalX, 0, "legacy records invert through the frame origin")
  Assert.equal(logicalY, 0, "legacy records invert through the frame origin")
  local edgeX, edgeY = LayoutGeometry.hostToLogical(placement, 109, 69)
  Assert.notNil(edgeX, "legacy records hit-test the whole frame")
  Assert.notNil(edgeY, "legacy records hit-test the whole frame")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 110, 69), "the half-open far edge stays outside")
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, 5, 5)
  Assert.equal(hostX, 20, "the forward transform defaults to the frame origin")
  Assert.equal(hostY, 30, "the forward transform defaults to the frame origin")
end

function T.cropped_placements_reject_hidden_margins_but_invert_through_the_full_origin()
  local placement = {
    frame = rect(-9, -8, 768, 576),
    origin = { x = -9, y = -8 },
    scale = 3,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = rect(0, 1, 750, 558),
  }
  local visibleX, visibleY = LayoutGeometry.hostToLogical(placement, 0, 1)
  Assert.equal(visibleX, 3, "a visible edge maps past the hidden margin, never from the clip origin")
  Assert.equal(visibleY, 3, "a visible edge maps past the hidden margin, never from the clip origin")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 0, 0), "the hidden top margin cannot hit")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, -9, -8), "the hidden frame corner cannot hit")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 750, 558), "the half-open far edge cannot hit")
  local snapshot = {
    frame = { x = -9, y = -8, width = 768, height = 576 },
    clipRect = { x = 0, y = 1, width = 750, height = 558 },
  }
  LayoutGeometry.hostToLogical(placement, 100, 100)
  Assert.deepEqual(
    { frame = placement.frame, clipRect = placement.clipRect },
    snapshot,
    "hit testing never mutates the placement record"
  )
end

function T.logical_rectangles_map_to_full_unclipped_host_extents()
  local placement = {
    frame = rect(-9, -8, 768, 576),
    origin = { x = -9, y = -8 },
    scale = 3,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = rect(0, 1, 750, 558),
  }
  local mapped = LayoutGeometry.logicalRectToHost(placement, rect(10, 20, 30, 40))
  Assert.deepEqual(mapped, { x = 21, y = 52, width = 90, height = 120 })
  local source = rect(10, 20, 30, 40)
  LayoutGeometry.logicalRectToHost(placement, source)
  Assert.deepEqual(source, { x = 10, y = 20, width = 30, height = 40 }, "mapping copies, never mutates")
  local nothing = nil ---@type any
  Assert.throws(function()
    LayoutGeometry.logicalRectToHost(placement, nothing)
  end)
end

function T.sub_placements_clip_to_the_parent_and_vanish_when_invisible()
  local parent = {
    frame = rect(-9, -8, 768, 576),
    origin = { x = -9, y = -8 },
    scale = 3,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = rect(0, 1, 750, 558),
    pixelScale = 3,
    pixelRatio = 1,
  }
  local child = LayoutGeometry.subPlacement(parent, rect(10, 20, 30, 40))
  Assert.notNil(child, "an overlapping subregion resolves")
  assert(child ~= nil, "the child placement is required below")
  Assert.deepEqual(child.frame, { x = 21, y = 52, width = 90, height = 120 })
  Assert.deepEqual(child.origin, { x = 21, y = 52 }, "the child origin is the subregion top-left")
  Assert.equal(child.scale, 3, "subregions never reselect the scale")
  Assert.equal(child.logicalWidth, 30)
  Assert.equal(child.logicalHeight, 40)
  Assert.deepEqual(child.clipRect, { x = 21, y = 52, width = 90, height = 120 })
  Assert.equal(child.pixelScale, 3, "pixel metadata carries into the child")
  local edged = LayoutGeometry.subPlacement(parent, rect(0, 0, 10, 10))
  Assert.notNil(edged, "a partially visible subregion resolves")
  assert(edged ~= nil, "the edged placement is required below")
  Assert.deepEqual(
    edged.clipRect,
    { x = 0, y = 1, width = 21, height = 21 },
    "the child clip is the parent clip intersected with the child frame"
  )
  Assert.isNil(
    LayoutGeometry.subPlacement(parent, rect(0, 0, 2, 2)),
    "a wholly cropped subregion returns nil instead of a malformed placement"
  )
  Assert.isNil(
    LayoutGeometry.subPlacement(parent, rect(300, 300, 10, 10)),
    "a subregion outside the parent returns nil"
  )
  local parentSnapshot = { x = parent.frame.x, y = parent.frame.y }
  LayoutGeometry.subPlacement(parent, rect(10, 20, 30, 40))
  Assert.equal(parent.frame.x, parentSnapshot.x, "subregions never mutate the parent")
  Assert.equal(parent.frame.y, parentSnapshot.y, "subregions never mutate the parent")
end

return { tests = T }
