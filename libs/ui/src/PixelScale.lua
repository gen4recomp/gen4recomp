-- Integer-pixel presentation policy layered on `LayoutGeometry`: preferred
-- integer scale selection, ceil-covered logical allocations, and
-- logical-pixel snapping. Generic rectangle validation, fit geometry, and
-- host/logical transforms are owned by `LayoutGeometry`.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class PixelScale.Surface
---@field placement LayoutGeometry.Placement
---@field allocationWidth integer
---@field allocationHeight integer
---@field logicalViewport LayoutGeometry.Rect

local PixelScale = {}

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function assertFiniteNumber(value, name)
  assert(isFiniteNumber(value), name .. " must be finite")
end

local function assertScale(scale)
  assertFiniteNumber(scale, "scale")
  assert(scale > 0 and scale == math.floor(scale), "scale must be a positive integer")
end

---@param bounds LayoutGeometry.Rect
---@param referenceWidth number
---@param referenceHeight number
---@param preferredScale integer
---@return integer
function PixelScale.fitPreferred(bounds, referenceWidth, referenceHeight, preferredScale)
  assertScale(preferredScale)

  local fit = LayoutGeometry.centeredFit(bounds, referenceWidth, referenceHeight)
  local capacity = math.floor(fit.scale)

  return math.max(1, math.min(preferredScale, capacity))
end

---@param bounds LayoutGeometry.Rect
---@param scale integer
---@return PixelScale.Surface
function PixelScale.cover(bounds, scale)
  assertScale(scale)

  local frame = LayoutGeometry.rect(bounds, "bounds")
  local visibleWidth = frame.width / scale
  local visibleHeight = frame.height / scale

  return {
    placement = {
      frame = frame,
      origin = { x = frame.x, y = frame.y },
      scale = scale,
      logicalWidth = visibleWidth,
      logicalHeight = visibleHeight,
    },
    allocationWidth = math.ceil(visibleWidth),
    allocationHeight = math.ceil(visibleHeight),
    logicalViewport = {
      x = 0,
      y = 0,
      width = visibleWidth,
      height = visibleHeight,
    },
  }
end

---@param value number
---@return integer
function PixelScale.snapLogical(value)
  assertFiniteNumber(value, "value")
  return math.floor(value + 0.5)
end

return PixelScale
