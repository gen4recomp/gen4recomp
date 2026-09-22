-- Real-driver proof for the shared logical drawing boundary: a double-density
-- host renders the same physical pixels as the unit-density reference, the
-- visible clip hides cropped margins while nested clips compose with an
-- active outer scissor, and borrowed graphics state survives callback
-- failure. Only axis-aligned fills are compared pixel for pixel, with every
-- painted edge on whole host pixels at both densities; fractional scissor
-- quantization at the outermost boundary rows is driver-defined and stays
-- outside the compared interior.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

local function pixelScaleFor(behavior)
  local ok, moduleOrError = pcall(require, "libs.ui.src.PixelScale")
  Assert.isTrue(ok, behavior .. " is missing: the pixel-scale primitive is unavailable")
  local PixelScale = moduleOrError
  Assert.isTrue(
    type(PixelScale.placeFixed) == "function",
    behavior .. " is missing: bounded fixed-surface fitting is unavailable"
  )
  return PixelScale
end

local function logicalSurfaceFor(behavior)
  local ok, moduleOrError = pcall(require, "libs.ui.src.LogicalSurface")
  Assert.isTrue(ok, behavior .. " is missing: the shared logical drawing scope is unavailable")
  local Surface = moduleOrError
  Assert.isTrue(type(Surface.draw) == "function", behavior .. " is missing: the root placement scope is unavailable")
  Assert.isTrue(type(Surface.clip) == "function", behavior .. " is missing: the nested logical clip is unavailable")
  return Surface
end

-- Nested axis-aligned blocks strictly inside the visible logical area, every
-- edge on a whole host pixel at unit density (scale 3) and at double density
-- (scale 1.5 from a half-integer origin): odd left/right columns, even
-- top/bottom rows.
local function paintNestedBlocks(lg)
  lg.setColor(0.8, 0.1, 0.1, 1)
  lg.rectangle("fill", 3, 4, 248, 184)
  lg.setColor(0.1, 0.8, 0.1, 1)
  lg.rectangle("fill", 9, 8, 238, 176)
  lg.setColor(0.1, 0.1, 0.8, 1)
  lg.rectangle("fill", 21, 20, 212, 152)
end

local function renderToCanvas(scope, width, height, paint)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  paint()
  lg.setCanvas()
  return canvas
end

local function quantize(channel)
  return math.floor(channel * 255 + 0.5)
end

local function assertInteriorEqual(expected, actual, inset, label)
  for y = inset, expected:getHeight() - 1 - inset do
    for x = inset, expected:getWidth() - 1 - inset do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          ),
          0
        )
      end
    end
  end
end

local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  assertInteriorEqual(expected, actual, 0, label)
end

local function assertPixelNear(data, x, y, r, g, b, a, label)
  local ar, ag, ab, aa = data:getPixel(x, y)
  Assert.near(ar, r, 1e-2, label .. " red")
  Assert.near(ag, g, 1e-2, label .. " green")
  Assert.near(ab, b, 1e-2, label .. " blue")
  Assert.near(aa, a, 1e-2, label .. " alpha")
end

function T.double_density_host_matches_unit_density_physical_pixels(scope)
  local PixelScale = pixelScaleFor("bounded fixed-surface fitting")
  local Surface = logicalSurfaceFor("shared logical drawing")
  local lg = love.graphics
  local reference = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192))
  Assert.equal(reference.pixelScale, 3)
  local dense = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 375, height = 280 }, 256, 192, { pixelRatio = 2 }))
  Assert.equal(dense.pixelScale, 3, "physical magnification is integral at double density")
  Assert.near(dense.scale, 1.5, 1e-9, "host units per logical pixel divide the pixel scale by the ratio")
  Assert.deepEqual(dense.crop, { left = 3, right = 3, top = 3, bottom = 3 })
  Assert.deepEqual(dense.visibleLogicalRect, { x = 3, y = 3, width = 250, height = 186 })
  Assert.near(dense.clipRect.x, 0, 1e-9)
  Assert.near(dense.clipRect.y, 0.5, 1e-9, "physical clip rows convert once into host units")
  Assert.near(dense.clipRect.width, 375, 1e-9)
  Assert.near(dense.clipRect.height, 279, 1e-9)

  local canvasA = renderToCanvas(scope, 750, 560, function()
    Surface.draw(lg, reference, function()
      paintNestedBlocks(lg)
    end)
  end)
  local canvasB = renderToCanvas(scope, 375, 280, function()
    Surface.draw(lg, dense, function()
      paintNestedBlocks(lg)
    end)
  end)
  canvasB:setFilter("nearest", "nearest")
  local upscaled = renderToCanvas(scope, 750, 560, function()
    lg.setColor(1, 1, 1, 1)
    lg.draw(canvasB, 0, 0, 0, 2, 2)
  end)
  -- The outermost boundary rows stay outside the comparison: the host-unit
  -- scissor quantizes the half-integer clip edge in the driver, while the
  -- placement contract pins the exact clip numerically above.
  assertInteriorEqual(
    scope:own(canvasA:newImageData()),
    scope:own(upscaled:newImageData()),
    2,
    "double density physical image"
  )
end

function T.visible_clip_hides_cropped_margins_and_nested_clip_composes(scope)
  local PixelScale = pixelScaleFor("bounded fixed-surface fitting")
  local Surface = logicalSurfaceFor("shared logical drawing")
  local lg = love.graphics
  local placement = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192))
  local canvas = renderToCanvas(scope, 750, 560, function()
    Surface.draw(lg, placement, function()
      lg.setColor(0.5, 0.5, 0.5, 1)
      lg.rectangle("fill", 0, 0, 256, 192)
      paintNestedBlocks(lg)
    end)
  end)
  local data = scope:own(canvas:newImageData())
  for _, x in ipairs({ 0, 100, 375, 749 }) do
    assertPixelNear(data, x, 0, 0, 0, 0, 0, "cropped top margin stays clear at x=" .. x)
    assertPixelNear(data, x, 559, 0, 0, 0, 0, "cropped bottom margin stays clear at x=" .. x)
  end
  assertPixelNear(data, 375, 300, 0.1, 0.1, 0.8, 1, "visible content renders inside the clip")

  local nested = renderToCanvas(scope, 750, 560, function()
    lg.setScissor(0, 0, 40, 40)
    Surface.draw(lg, placement, function()
      lg.setColor(0.5, 0.5, 0.5, 1)
      lg.rectangle("fill", 0, 0, 256, 192)
      Surface.clip(lg, { x = 10, y = 10, width = 20, height = 20 }, function()
        lg.setColor(1, 0, 0, 1)
        lg.rectangle("fill", 0, 0, 256, 192)
      end)
    end)
    lg.setScissor()
  end)
  local clipped = scope:own(nested:newImageData())
  assertPixelNear(clipped, 36, 37, 1, 0, 0, 1, "content inside both the nested clip and the outer scissor paints")
  assertPixelNear(
    clipped,
    70,
    70,
    0,
    0,
    0,
    0,
    "content inside the nested clip but outside the outer scissor stays hidden"
  )
end

function T.borrowed_state_restored_and_callback_failure_propagates(scope)
  local PixelScale = pixelScaleFor("bounded fixed-surface fitting")
  local Surface = logicalSurfaceFor("shared logical drawing")
  local lg = love.graphics
  local placement = assert(PixelScale.placeFixed({ x = 8, y = 12, width = 512, height = 384 }, 256, 192))
  Assert.equal(placement.pixelScale, 2)

  lg.push()
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setBlendMode("add")
  local entryLineWidth = lg.getLineWidth()
  lg.setLineWidth(3)
  lg.translate(11, 13)
  local target = scope:own(lg.newCanvas(64, 64))
  lg.setCanvas(target)
  local function captureState()
    local r, g, b, a = lg.getColor()
    local blend, blendAlpha = lg.getBlendMode()
    local sx, sy, sw, sh = lg.getScissor()
    return {
      color = { r, g, b, a },
      blend = { blend, blendAlpha },
      lineWidth = lg.getLineWidth(),
      scissor = { sx, sy, sw, sh },
      canvas = lg.getCanvas(),
    }
  end
  local before = captureState()
  local function assertStateRestored(label)
    local after = captureState()
    Assert.deepEqual(after.color, before.color, label .. " color")
    Assert.deepEqual(after.blend, before.blend, label .. " blend")
    Assert.equal(after.lineWidth, before.lineWidth, label .. " line width")
    Assert.deepEqual(after.scissor, before.scissor, label .. " scissor")
    Assert.isTrue(after.canvas == before.canvas, label .. " render target")
  end

  local function paintReference()
    Surface.draw(lg, placement, function()
      paintNestedBlocks(lg)
    end)
  end
  lg.setCanvas()
  local first = renderToCanvas(scope, 512, 384, paintReference)
  lg.setCanvas(target)
  lg.setScissor(4, 8, 32, 16)
  before = captureState()

  local marker = {}
  local ok, err = pcall(Surface.draw, lg, placement, function()
    error(marker, 0)
  end)
  Assert.isFalse(ok, "a callback failure fails the scope")
  Assert.isTrue(err == marker, "the original error object propagates unwrapped")
  assertStateRestored("failed draw restores")

  local nestedMarker = {}
  local nestedOk, nestedErr = pcall(Surface.draw, lg, placement, function()
    Surface.clip(lg, { x = 10, y = 10, width = 20, height = 20 }, function()
      error(nestedMarker, 0)
    end)
  end)
  Assert.isFalse(nestedOk, "a nested failure fails the root scope")
  Assert.isTrue(nestedErr == nestedMarker, "the nested error object propagates unwrapped")
  assertStateRestored("failed nested clip restores")

  lg.setScissor()
  lg.setCanvas()
  local second = renderToCanvas(scope, 512, 384, paintReference)
  lg.pop()
  lg.setLineWidth(entryLineWidth)
  assertPixelsEqual(scope:own(first:newImageData()), scope:own(second:newImageData()), "balanced scope draws")
end

return GraphicsSmoke.suite(T)
