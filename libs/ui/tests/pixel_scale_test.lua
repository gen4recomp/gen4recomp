local Assert = require("tests.support.Assert")

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
  Assert.keySet(PixelScale, "cover,fitPreferred,hostToLogical,logicalToHost,snapLogical")
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
  rejects(function()
    PixelScale.fitPreferred(nil, referenceWidth, referenceHeight, 2)
  end)
end

function T.coverage_descriptor_round_trips_and_snaps_without_mutation()
  local PixelScale = pixelScaleFor("coverage and coordinate transforms")
  local bounds = rect(17, 29, 641, 479)

  for _, scale in ipairs({ 2, 3, 4, 5 }) do
    local surface = PixelScale.cover(bounds, scale)
    Assert.keySet(surface, "logicalHeight,logicalViewport,logicalWidth,physicalFrame,scale")
    Assert.equal(surface.scale, scale)
    Assert.equal(surface.logicalWidth, math.ceil(bounds.width / scale))
    Assert.equal(surface.logicalHeight, math.ceil(bounds.height / scale))
    Assert.equal(surface.logicalViewport.x, 0)
    Assert.equal(surface.logicalViewport.y, 0)
    Assert.near(surface.logicalViewport.width, bounds.width / scale)
    Assert.near(surface.logicalViewport.height, bounds.height / scale)
    Assert.equal(surface.physicalFrame.x, bounds.x)
    Assert.equal(surface.physicalFrame.y, bounds.y)
    Assert.equal(surface.physicalFrame.width, bounds.width)
    Assert.equal(surface.physicalFrame.height, bounds.height)
    Assert.isTrue(surface.physicalFrame ~= bounds, "coverage copies the physical frame")

    local overhangWidth = surface.logicalWidth * scale - bounds.width
    local overhangHeight = surface.logicalHeight * scale - bounds.height
    Assert.isTrue(overhangWidth >= 0 and overhangWidth < scale, "logical width covers by less than one block")
    Assert.isTrue(overhangHeight >= 0 and overhangHeight < scale, "logical height covers by less than one block")

    for _, point in ipairs({
      { x = bounds.x, y = bounds.y },
      { x = bounds.x + 12.25, y = bounds.y + 34.75 },
      { x = bounds.x + bounds.width + 3.5, y = bounds.y - 2.25 },
    }) do
      local logicalX, logicalY = PixelScale.hostToLogical(surface, point.x, point.y)
      local hostX, hostY = PixelScale.logicalToHost(surface, logicalX, logicalY)
      Assert.near(hostX, point.x, 1e-9, "host/logical conversion preserves x outside and inside the frame")
      Assert.near(hostY, point.y, 1e-9, "host/logical conversion preserves y outside and inside the frame")
    end
  end

  local exact = PixelScale.cover(rect(17, 29, 640, 480), 4)
  Assert.equal(exact.logicalWidth * exact.scale, exact.physicalFrame.width)
  Assert.equal(exact.logicalHeight * exact.scale, exact.physicalFrame.height)

  local savedFrame = PixelScale.cover(bounds, 3).physicalFrame
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
  rejects(function()
    PixelScale.cover(rect(0, 0, 640, 480), 1.5)
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
  rejects(function()
    PixelScale.hostToLogical(exact, 0 / 0, 4)
  end)
  rejects(function()
    PixelScale.logicalToHost(exact, 4, math.huge)
  end)
end

return { tests = T }
