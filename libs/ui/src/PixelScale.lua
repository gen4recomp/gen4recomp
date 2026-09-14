-- Pure integer pixel-surface geometry and coordinate conversion.

local PixelScale = {}

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function assertFiniteNumber(value, name)
  assert(isFiniteNumber(value), name .. " must be finite")
end

local function assertPositiveDimension(value, name)
  assertFiniteNumber(value, name)
  assert(value > 0, name .. " must be positive")
end

local function assertRect(bounds, name)
  assert(type(bounds) == "table", name .. " must be a table")
  assertFiniteNumber(bounds.x, name .. ".x")
  assertFiniteNumber(bounds.y, name .. ".y")
  assertPositiveDimension(bounds.width, name .. ".width")
  assertPositiveDimension(bounds.height, name .. ".height")
end

local function assertScale(scale)
  assertFiniteNumber(scale, "scale")
  assert(scale > 0 and scale == math.floor(scale), "scale must be a positive integer")
end

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function assertSurface(surface)
  assert(type(surface) == "table", "surface must be a table")
  assertScale(surface.scale)
  assertFiniteNumber(surface.logicalWidth, "surface.logicalWidth")
  assertFiniteNumber(surface.logicalHeight, "surface.logicalHeight")
  assert(
    surface.logicalWidth >= 1 and surface.logicalWidth == math.floor(surface.logicalWidth),
    "surface.logicalWidth must be a positive integer"
  )
  assert(
    surface.logicalHeight >= 1 and surface.logicalHeight == math.floor(surface.logicalHeight),
    "surface.logicalHeight must be a positive integer"
  )
  assertRect(surface.logicalViewport, "surface.logicalViewport")
  assert(surface.logicalViewport.x == 0, "surface.logicalViewport.x must be zero")
  assert(surface.logicalViewport.y == 0, "surface.logicalViewport.y must be zero")
  assertRect(surface.physicalFrame, "surface.physicalFrame")
end

function PixelScale.fitPreferred(bounds, referenceWidth, referenceHeight, preferredScale)
  assertRect(bounds, "bounds")
  assertPositiveDimension(referenceWidth, "referenceWidth")
  assertPositiveDimension(referenceHeight, "referenceHeight")
  assertScale(preferredScale)

  local widthCapacity = math.floor(bounds.width / referenceWidth)
  local heightCapacity = math.floor(bounds.height / referenceHeight)
  return math.max(1, math.min(preferredScale, widthCapacity, heightCapacity))
end

function PixelScale.cover(bounds, scale)
  assertRect(bounds, "bounds")
  assertScale(scale)

  return {
    scale = scale,
    logicalWidth = math.ceil(bounds.width / scale),
    logicalHeight = math.ceil(bounds.height / scale),
    logicalViewport = {
      x = 0,
      y = 0,
      width = bounds.width / scale,
      height = bounds.height / scale,
    },
    physicalFrame = copyRect(bounds),
  }
end

function PixelScale.snapLogical(value)
  assertFiniteNumber(value, "value")
  return math.floor(value + 0.5)
end

function PixelScale.hostToLogical(surface, x, y)
  assertSurface(surface)
  assertFiniteNumber(x, "x")
  assertFiniteNumber(y, "y")

  return (x - surface.physicalFrame.x) / surface.scale, (y - surface.physicalFrame.y) / surface.scale
end

function PixelScale.logicalToHost(surface, x, y)
  assertSurface(surface)
  assertFiniteNumber(x, "x")
  assertFiniteNumber(y, "y")

  return x * surface.scale + surface.physicalFrame.x, y * surface.scale + surface.physicalFrame.y
end

return PixelScale
