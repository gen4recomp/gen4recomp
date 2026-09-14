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

local function rejects(fn)
  Assert.throws(fn, "invalid pixel-scale input must be rejected")
end

function T.preferred_fitting_resolves_an_integer_at_least_one()
  local PixelScale = pixelScaleFor("preferred integer fitting")
  Assert.keySet(PixelScale, "cover,fitPreferred,snapLogical")
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

return { tests = T }
