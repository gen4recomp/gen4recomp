local Assert = require("tests.support.Assert")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}

local function pixelScaleFor(behavior)
  local ok, moduleOrError = pcall(require, "libs.ui.src.PixelScale")
  Assert.isTrue(ok, behavior .. " is missing: the pixel-scale primitive is unavailable")
  Assert.isTrue(type(moduleOrError) == "table", behavior .. " is missing: the module has no public table")
  return moduleOrError
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function fixedScaleFor(behavior)
  local PixelScale = pixelScaleFor(behavior)
  Assert.isTrue(
    type(PixelScale.placeFixed) == "function",
    behavior .. " is missing: bounded fixed-surface fitting is unavailable"
  )
  return PixelScale
end

local function rejects(fn)
  Assert.throws(fn, "invalid pixel-scale input must be rejected")
end

function T.preferred_fitting_resolves_an_integer_at_least_one()
  local PixelScale = pixelScaleFor("preferred integer fitting")
  Assert.keySet(PixelScale, "cover,fitPreferred,placeFixed,snapLogical")
  local referenceWidth, referenceHeight = 256, 192

  local exact = PixelScale.fitPreferred(rect(0, 0, 512, 384), referenceWidth, referenceHeight, 2)
  Assert.equal(exact, 2, "an exactly fitting preference is preserved")

  local capped = PixelScale.fitPreferred(rect(0, 0, 640, 480), referenceWidth, referenceHeight, 5)
  Assert.equal(capped, 2, "the greatest fitting integer is selected below the preference")

  local heightCapped = PixelScale.fitPreferred(rect(0, 0, 1280, 720), referenceWidth, referenceHeight, 5)
  Assert.equal(heightCapped, 3, "the tightest reference dimension caps the scale")

  local undersized = PixelScale.fitPreferred(rect(0, 0, 255, 191), referenceWidth, referenceHeight, 5)
  Assert.equal(undersized, 1, "the result never falls below one when one times does not fit")

  for _, candidate in ipairs({ 0, -1, 1.5, math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.fitPreferred(rect(0, 0, 640, 480), referenceWidth, referenceHeight, candidate)
    end)
  end
  for _, candidate in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.fitPreferred(rect(0, 0, 640, 480), candidate, referenceHeight, 2)
    end)
    rejects(function()
      PixelScale.fitPreferred(rect(0, 0, 640, 480), referenceWidth, candidate, 2)
    end)
  end
  for _, candidate in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.fitPreferred(rect(0, 0, candidate, 480), referenceWidth, referenceHeight, 2)
    end)
    rejects(function()
      PixelScale.fitPreferred(rect(0, 0, 640, candidate), referenceWidth, referenceHeight, 2)
    end)
  end
  local nilBounds = nil
  rejects(function()
    PixelScale.fitPreferred(nilBounds --[[@as any]], referenceWidth, referenceHeight, 2)
  end)
end

function T.coverage_descriptor_separates_exact_visible_area_from_ceil_allocation()
  local PixelScale = pixelScaleFor("coverage and coordinate transforms")
  local bounds = rect(17, 29, 641, 479)

  for _, scale in ipairs({ 2, 3, 4, 5 }) do
    local surface = PixelScale.cover(bounds, scale)
    Assert.keySet(surface, "allocationHeight,allocationWidth,logicalViewport,placement")
    Assert.deepEqual(surface.placement.frame, bounds)
    Assert.isTrue(surface.placement.frame ~= bounds, "coverage copies the placement frame")
    Assert.equal(surface.placement.origin.x, bounds.x)
    Assert.equal(surface.placement.origin.y, bounds.y)
    Assert.equal(surface.placement.scale, scale)
    Assert.near(surface.placement.logicalWidth, bounds.width / scale)
    Assert.near(surface.placement.logicalHeight, bounds.height / scale)
    Assert.equal(surface.allocationWidth, math.ceil(bounds.width / scale))
    Assert.equal(surface.allocationHeight, math.ceil(bounds.height / scale))
    Assert.equal(surface.logicalViewport.x, 0)
    Assert.equal(surface.logicalViewport.y, 0)
    Assert.near(surface.logicalViewport.width, bounds.width / scale)
    Assert.near(surface.logicalViewport.height, bounds.height / scale)

    local overhangWidth = surface.allocationWidth * scale - bounds.width
    local overhangHeight = surface.allocationHeight * scale - bounds.height
    Assert.isTrue(overhangWidth >= 0 and overhangWidth < scale, "logical width covers by less than one block")
    Assert.isTrue(overhangHeight >= 0 and overhangHeight < scale, "logical height covers by less than one block")

    for _, point in ipairs({
      { x = bounds.x, y = bounds.y },
      { x = bounds.x + 12.25, y = bounds.y + 34.75 },
    }) do
      local logicalX, logicalY = LayoutGeometry.hostToLogical(surface.placement, point.x, point.y)
      assert(logicalX ~= nil and logicalY ~= nil, "interior points round-trip")
      local hostX, hostY = LayoutGeometry.logicalToHost(surface.placement, logicalX, logicalY)
      Assert.near(hostX, point.x, 1e-9, "host/logical conversion preserves x inside the frame")
      Assert.near(hostY, point.y, 1e-9, "host/logical conversion preserves y inside the frame")
    end

    for _, point in ipairs({
      { x = bounds.x + bounds.width + 3.5, y = bounds.y - 2.25 },
      { x = bounds.x + bounds.width, y = bounds.y },
      { x = bounds.x, y = bounds.y + bounds.height },
    }) do
      local logicalX, logicalY = LayoutGeometry.hostToLogical(surface.placement, point.x, point.y)
      Assert.isNil(logicalX, "points outside the frame, including the far edge, must not round-trip")
      Assert.isNil(logicalY, "points outside the frame, including the far edge, must not round-trip")
    end
  end

  local exact = PixelScale.cover(rect(17, 29, 640, 480), 4)
  Assert.equal(exact.allocationWidth * exact.placement.scale, exact.placement.frame.width)
  Assert.equal(exact.allocationHeight * exact.placement.scale, exact.placement.frame.height)

  local savedFrame = PixelScale.cover(bounds, 3).placement.frame
  bounds.x, bounds.y, bounds.width, bounds.height = 900, 700, 2, 3
  Assert.deepEqual(savedFrame, { x = 17, y = 29, width = 641, height = 479 })

  Assert.equal(PixelScale.snapLogical(-1.6), -2)
  Assert.equal(PixelScale.snapLogical(-1.5), -1)
  Assert.equal(PixelScale.snapLogical(-1.4), -1)
  Assert.equal(PixelScale.snapLogical(0.5), 1)
  Assert.equal(PixelScale.snapLogical(1.5), 2)
  Assert.equal(PixelScale.snapLogical(2.49), 2)

  for _, candidate in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.cover(rect(0, 0, 640, 480), candidate)
    end)
  end
  for _, candidate in ipairs({ math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.snapLogical(candidate)
    end)
  end
  local fractionalScale = 1.5
  rejects(function()
    PixelScale.cover(rect(0, 0, 640, 480), fractionalScale --[[@as integer]])
  end)
  rejects(function()
    PixelScale.cover(rect(0, 0, math.huge, 480), 2)
  end)
  rejects(function()
    PixelScale.cover(rect(0, 0, 640, 0 / 0), 2)
  end)
  rejects(function()
    PixelScale.cover(rect(0 / 0, 0, 640, 480), 2)
  end)
  rejects(function()
    PixelScale.cover(rect(0, math.huge, 640, 480), 2)
  end)
end

function T.fixed_fit_selects_bounded_integer_bump_and_inverts_through_full_origin()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local placement = assert(PixelScale.placeFixed(rect(0, 0, 750, 560), 256, 192))
  Assert.equal(placement.pixelScale, 3, "an admissible one-step bump keeps integral pixels")
  Assert.equal(placement.scale, 3, "unit density leaves host units per logical pixel equal to the pixel scale")
  Assert.deepEqual(placement.crop, { left = 3, right = 3, top = 3, bottom = 3 })
  Assert.deepEqual(
    placement.visibleLogicalRect,
    { x = 3, y = 3, width = 250, height = 186 },
    "only whole source pixels inside the budget stay visible"
  )
  Assert.deepEqual(placement.clipRect, { x = 0, y = 1, width = 750, height = 558 })
  Assert.deepEqual(placement.frame, { x = -9, y = -8, width = 768, height = 576 })
  Assert.deepEqual(placement.origin, { x = -9, y = -8 }, "inversion uses the full frame origin, never the clip origin")
  Assert.equal(placement.frame.width, 256 * placement.pixelScale, "magnification never stretches content")
  Assert.equal(placement.frame.height, 192 * placement.pixelScale, "magnification never stretches content")
  local firstX, firstY = LayoutGeometry.hostToLogical(placement, 0, 1)
  assert(firstX ~= nil, "the first visible pixel maps inside the logical surface")
  assert(firstY ~= nil, "the first visible pixel maps inside the logical surface")
  Assert.equal(firstX, 3, "the left visible edge maps to the first visible logical column")
  Assert.equal(firstY, 3, "the top visible edge maps to the first visible logical row")
  local lastX, lastY = LayoutGeometry.hostToLogical(placement, 749, 558)
  assert(lastX ~= nil, "the last visible pixel maps inside the logical surface")
  assert(lastY ~= nil, "the last visible pixel maps inside the logical surface")
  Assert.near(lastX, 252 + 2 / 3, 1e-9)
  Assert.near(lastY, 188 + 2 / 3, 1e-9)
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 0, 0), "the hidden top margin cannot hit")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 375, 559), "the hidden bottom margin cannot hit")
  Assert.isNil(LayoutGeometry.hostToLogical(placement, 750, 558), "the half-open far edge cannot hit")
end

function T.fixed_fit_refuses_unsafe_bump_and_honors_protection_and_cap()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local function scaleFor(hostWidth, hostHeight, options)
    local placement = assert(
      PixelScale.placeFixed(rect(0, 0, hostWidth, hostHeight), 256, 192, options),
      "these hosts can present the source"
    )
    Assert.notNil(placement, "these hosts can present the source")
    return placement
  end
  local narrow = scaleFor(640, 480)
  Assert.equal(narrow.pixelScale, 2, "a host needing wide crop stays at the fitting scale")
  Assert.deepEqual(narrow.crop, { left = 0, right = 0, top = 0, bottom = 0 })
  local tight = scaleFor(740, 548)
  Assert.equal(tight.pixelScale, 2, "a host needing ten pixels of crop per edge stays at the fitting scale")
  local protected = scaleFor(750, 560, { protectedRect = rect(0, 0, 256, 192) })
  Assert.equal(protected.pixelScale, 2, "required content refuses the bump that would hide it")
  Assert.deepEqual(protected.crop, { left = 0, right = 0, top = 0, bottom = 0 })
  local capped = scaleFor(750, 560, { preferredScale = 2 })
  Assert.equal(capped.pixelScale, 2, "the preferred cap never produces a larger scale")
  local oneSided = scaleFor(750, 560, { maxOverdraw = { left = 0, right = 4, top = 4, bottom = 4 } })
  Assert.equal(oneSided.pixelScale, 2, "centred crop cannot spend a closed edge by shifting content into the open one")
  for _, placement in ipairs({ narrow, tight, protected, capped, oneSided }) do
    Assert.equal(placement.frame.width, 256 * placement.pixelScale, "refused fits keep uniform integer magnification")
    Assert.equal(placement.frame.height, 192 * placement.pixelScale, "refused fits keep uniform integer magnification")
  end
end

function T.fixed_fit_exact_multiples_fit_without_cropping()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local placement =
    assert(PixelScale.placeFixed(rect(0, 0, 512, 384), 256, 192), "an exact multiple presents the source")
  Assert.equal(placement.pixelScale, 2)
  Assert.deepEqual(placement.crop, { left = 0, right = 0, top = 0, bottom = 0 })
  Assert.deepEqual(placement.visibleLogicalRect, { x = 0, y = 0, width = 256, height = 192 })
  Assert.deepEqual(placement.frame, { x = 0, y = 0, width = 512, height = 384 })
  Assert.deepEqual(placement.clipRect, placement.frame)
  Assert.deepEqual(placement.origin, { x = 0, y = 0 })
end

function T.fixed_fit_one_pixel_beyond_budget_refuses_the_bump()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  -- At 3x, 741 host pixels show 247 of 256 columns: 9 hidden, split 4/5,
  -- so the right edge exceeds the default budget by one pixel.
  local refused =
    assert(PixelScale.placeFixed(rect(0, 0, 741, 600), 256, 192), "the refused host still presents the source")
  Assert.equal(refused.pixelScale, 2, "one pixel beyond the budget refuses the bump")
  Assert.deepEqual(refused.crop, { left = 0, right = 0, top = 0, bottom = 0 })
  -- One more pixel fits the centred 4/4 cut, so the bump applies.
  local admitted = assert(PixelScale.placeFixed(rect(0, 0, 744, 600), 256, 192), "the fitting host presents the source")
  Assert.equal(admitted.pixelScale, 3, "a cut inside the budget keeps integral pixels")
  Assert.deepEqual(admitted.crop, { left = 4, right = 4, top = 0, bottom = 0 })
  Assert.deepEqual(admitted.visibleLogicalRect, { x = 4, y = 0, width = 248, height = 192 })
end

function T.fixed_fit_tiny_hosts_crop_once_then_fall_back_to_fractional()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  -- 252x188 hides 2 pixels per edge at 1x: inside the default budget.
  local cropped =
    assert(PixelScale.placeFixed(rect(0, 0, 252, 188), 256, 192), "a nearly fitting host presents the source")
  Assert.equal(cropped.pixelScale, 1, "admissible 1x cropping applies below the natural fit")
  Assert.deepEqual(cropped.crop, { left = 2, right = 2, top = 2, bottom = 2 })
  Assert.deepEqual(cropped.visibleLogicalRect, { x = 2, y = 2, width = 252, height = 188 })
  -- 200x150 cannot keep 1x inside any budget: the exact fractional
  -- downscale keeps every control reachable instead of hiding content.
  local fractional =
    assert(PixelScale.placeFixed(rect(0, 0, 200, 150), 256, 192), "a tiny host still presents complete content")
  Assert.near(fractional.pixelScale, 200 / 256, 1e-9, "the fallback is the exact uniform downscale")
  Assert.near(fractional.scale, 200 / 256, 1e-9)
  Assert.deepEqual(fractional.crop, { left = 0, right = 0, top = 0, bottom = 0 })
  Assert.deepEqual(fractional.visibleLogicalRect, { x = 0, y = 0, width = 256, height = 192 })
  Assert.isTrue(
    fractional.pixelScale ~= math.floor(fractional.pixelScale),
    "the fractional fallback is explicitly not pixel-exact"
  )
end

function T.fixed_fit_empty_targets_have_no_placement()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local tooNarrow = PixelScale.placeFixed(rect(0, 0, 0.4, 10), 256, 192)
  Assert.isNil(tooNarrow, "a target without a whole physical pixel has no drawable placement")
  local tooShort = PixelScale.placeFixed(rect(0, 0, 10, 0.4), 256, 192)
  Assert.isNil(tooShort, "a target without a whole physical row has no drawable placement")
end

function T.fixed_fit_translated_and_scaled_hosts_keep_the_same_pixels()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local shifted =
    assert(PixelScale.placeFixed(rect(-50, -40, 750, 560), 256, 192), "a translated host presents the source")
  Assert.equal(shifted.pixelScale, 3)
  Assert.deepEqual(shifted.crop, { left = 3, right = 3, top = 3, bottom = 3 })
  Assert.deepEqual(shifted.frame, { x = -59, y = -48, width = 768, height = 576 })
  Assert.deepEqual(shifted.clipRect, { x = -50, y = -39, width = 750, height = 558 })
  Assert.deepEqual(shifted.origin, { x = -59, y = -48 })
  local firstX, firstY = LayoutGeometry.hostToLogical(shifted, -50, -39)
  Assert.equal(firstX, 3, "inversion follows the translated full origin")
  Assert.equal(firstY, 3, "inversion follows the translated full origin")
  local dense = assert(
    PixelScale.placeFixed(rect(0, 0, 600, 448), 256, 192, { pixelRatio = 1.25 }),
    "a density-scaled host presents the source"
  )
  Assert.equal(dense.pixelScale, 3, "magnification stays integral in physical pixels")
  Assert.near(dense.scale, 3 / 1.25, 1e-9, "host units per logical pixel divide out the ratio")
  Assert.deepEqual(dense.crop, { left = 3, right = 3, top = 3, bottom = 3 })
end

function T.fixed_fit_rejects_invalid_inputs()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local bounds = rect(0, 0, 750, 560)
  for _, candidate in ipairs({ 0, -256, 256.5, math.huge, -math.huge, 0 / 0 }) do
    rejects(function()
      PixelScale.placeFixed(bounds, candidate, 192)
    end)
    rejects(function()
      PixelScale.placeFixed(bounds, 256, candidate)
    end)
  end
  local nothing = nil ---@type any
  rejects(function()
    PixelScale.placeFixed(nothing, 256, 192)
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { pixelRatio = 0 })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { pixelRatio = math.huge })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { preferredScale = 0 })
  end)
  local fractionalCap = 1.5
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, {
      preferredScale = fractionalCap --[[@as integer]],
    })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { maxOverdraw = { left = 0, right = 0, top = 0 } })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { maxOverdraw = { left = -1, right = 4, top = 4, bottom = 4 } })
  end)
  local fractionalBudget = 1.5
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, {
      maxOverdraw = {
        left = fractionalBudget --[[@as integer]],
        right = 4,
        top = 4,
        bottom = 4,
      },
    })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 4, 4, { maxOverdraw = { left = 2, right = 2, top = 0, bottom = 0 } })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { protectedRect = rect(200, 100, 100, 100) })
  end)
  rejects(function()
    PixelScale.placeFixed(bounds, 256, 192, { protectedRect = rect(-1, 0, 10, 10) })
  end)
end

function T.fixed_fit_copies_instead_of_mutating_inputs()
  local PixelScale = fixedScaleFor("bounded fixed-surface fitting")
  local bounds = rect(0, 0, 750, 560)
  local options = { maxOverdraw = { left = 4, right = 4, top = 4, bottom = 4 } }
  local placement = assert(PixelScale.placeFixed(bounds, 256, 192, options), "the fitting host presents the source")
  Assert.deepEqual(bounds, { x = 0, y = 0, width = 750, height = 560 }, "the target bounds are never mutated")
  Assert.deepEqual(
    options.maxOverdraw,
    { left = 4, right = 4, top = 4, bottom = 4 },
    "the crop budget is never mutated"
  )
  placement.frame.x = 9999
  local again =
    assert(PixelScale.placeFixed(bounds, 256, 192, options), "placements are independent caller-owned records")
  Assert.equal(again.frame.x, -9, "mutating a placement never affects later resolutions")
end

function T.coverage_with_explicit_ratio_separates_host_from_physical_pixels()
  local PixelScale = pixelScaleFor("coverage and coordinate transforms")
  local surface = PixelScale.cover(rect(0, 0, 375, 280), 3, 2)
  Assert.near(surface.placement.scale, 1.5, 1e-9, "the effective scale divides out the ratio")
  Assert.equal(surface.placement.pixelScale, 3)
  Assert.equal(surface.placement.pixelRatio, 2)
  Assert.near(surface.placement.logicalWidth, 250, 1e-9)
  Assert.near(surface.placement.logicalHeight, 280 / 1.5, 1e-9)
  Assert.equal(surface.allocationWidth, math.ceil(250))
  Assert.deepEqual(surface.logicalViewport, { x = 0, y = 0, width = 250, height = 280 / 1.5 })
  local untouched = PixelScale.cover(rect(0, 0, 641, 479), 2)
  Assert.equal(untouched.placement.scale, 2, "an omitted ratio keeps the existing scale meaning")
  Assert.equal(untouched.placement.pixelScale, 2)
  Assert.equal(untouched.placement.pixelRatio, 1)
  rejects(function()
    PixelScale.cover(rect(0, 0, 640, 480), 2, 0)
  end)
  rejects(function()
    PixelScale.cover(rect(0, 0, 640, 480), 2, math.huge)
  end)
end

return { tests = T }
