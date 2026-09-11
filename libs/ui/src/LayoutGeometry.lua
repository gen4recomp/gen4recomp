-- Game-independent rectangle, fit, and coordinate-transform geometry. Every operation validates finite positive dimensions, copies owned
-- rectangles, and scales uniformly; the placement record carries the exact
-- frame, scale, and logical dimensions rendering uses, so pointer mapping
-- inverts the same record with no second transform. No knowledge of
-- game surfaces, menus, pockets, love, or devices.

---@class LayoutGeometry
local LayoutGeometry = {}

-- The shared rectangle shape is a structural alias, not a distinct class, so
-- sibling layout records using the same shape convert without a second copy.
---@alias LayoutGeometry.Rect { x: number, y: number, width: number, height: number }

---@class LayoutGeometry.Placement
---@field frame LayoutGeometry.Rect
---@field origin { x: number, y: number }? the render translate point; required for logical mapping only
---@field scale number
---@field logicalWidth number
---@field logicalHeight number

-- The minimal placement `hostToLogical` consumes: the exact hit-test frame
-- plus the uniform render scale. Structural so sibling layout records share
-- the transform without copying.
---@alias LayoutGeometry.HitPlacement { frame: LayoutGeometry.Rect, scale: number }

local RECT_KEYS = { "x", "y", "width", "height" }

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param value unknown
---@param name string
local function checkRect(value, name)
  assert(type(value) == "table", name .. " must be a rectangle")
  local rect = value --[[@as LayoutGeometry.Rect]]
  for _, key in ipairs(RECT_KEYS) do
    assert(isFiniteNumber(rect[key]), name .. "." .. key .. " must be finite")
  end
  assert(rect.width > 0, name .. ".width must be positive")
  assert(rect.height > 0, name .. ".height must be positive")
end

-- Copies and validates a rectangle; the caller owns the result.
---@param value LayoutGeometry.Rect
---@param name string?
---@return LayoutGeometry.Rect
function LayoutGeometry.rect(value, name)
  name = name or "rect"
  checkRect(value, name)
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

-- Closed rect-in-rect containment: touching edges are contained.
---@param outer LayoutGeometry.Rect
---@param inner LayoutGeometry.Rect
---@return boolean
function LayoutGeometry.contains(outer, inner)
  checkRect(outer, "outer")
  checkRect(inner, "inner")
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

-- Half-open point containment matching the render frame: the origin edge is
-- inside, the far edge is outside.
---@param rect LayoutGeometry.Rect
---@param x number
---@param y number
---@return boolean
function LayoutGeometry.containsPoint(rect, x, y)
  checkRect(rect, "rect")
  assert(isFiniteNumber(x) and isFiniteNumber(y), "hit testing needs finite coordinates")
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

---@param a LayoutGeometry.Rect
---@param b LayoutGeometry.Rect
---@return boolean
function LayoutGeometry.overlaps(a, b)
  checkRect(a, "a")
  checkRect(b, "b")
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

---@param rect LayoutGeometry.Rect
---@param amount number
---@return LayoutGeometry.Rect
function LayoutGeometry.inset(rect, amount)
  checkRect(rect, "rect")
  assert(isFiniteNumber(amount) and amount >= 0, "inset amount must be a finite non-negative number")
  assert(rect.width > amount * 2 and rect.height > amount * 2, "the rectangle is too small for the inset amount")
  return {
    x = rect.x + amount,
    y = rect.y + amount,
    width = rect.width - amount * 2,
    height = rect.height - amount * 2,
  }
end

---@param value unknown
---@param name string
local function checkPositiveSize(value, name)
  assert(isFiniteNumber(value) and value --[[@as number]] > 0, name .. " must be a finite positive number")
end

---@param options unknown
---@return "floor"|"round"|nil
local function checkIntegerOption(options)
  if options == nil then
    return nil
  end
  assert(type(options) == "table", "fit options must be a table")
  local integer = (options --[[@as { integer?: string }]]).integer
  if integer == nil then
    return nil
  end
  assert(integer == "floor" or integer == "round", "fit integer rounding must be floor or round")
  return integer
end

-- Uniform centered fit of a logical surface inside host bounds. The scale is
-- always the exact min-ratio fit and the frame is always the exact logical
-- extent times that scale; `integer = "floor"` (or `"round"`) snaps only the
-- frame origin to whole host pixels, then clamps the snapped origin so the
-- exact frame stays inside the bounds.
---@param bounds LayoutGeometry.Rect
---@param logicalWidth number
---@param logicalHeight number
---@param options { integer?: "floor"|"round" }?
---@return LayoutGeometry.Placement
function LayoutGeometry.centeredFit(bounds, logicalWidth, logicalHeight, options)
  checkRect(bounds, "bounds")
  checkPositiveSize(logicalWidth, "logicalWidth")
  checkPositiveSize(logicalHeight, "logicalHeight")
  local integer = checkIntegerOption(options)
  local scale = math.min(bounds.width / logicalWidth, bounds.height / logicalHeight)
  assert(scale > 0, "the fit requires a positive scale")
  local width = logicalWidth * scale
  local height = logicalHeight * scale
  -- Integer origin snapping centers the exact surface, then snaps only the
  -- origin: the frame extent stays the exact logical dimensions times scale
  -- so clipping/hit testing and the render transform agree.
  local x = bounds.x + (bounds.width - width) / 2
  local y = bounds.y + (bounds.height - height) / 2
  if integer == "floor" then
    x, y = math.floor(x), math.floor(y)
  elseif integer == "round" then
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  end
  -- Snapping must never push the exact frame outside the bounds; for
  -- integral bounds this clamp is a no-op over the centered values above.
  x = math.max(bounds.x, math.min(x, bounds.x + bounds.width - width))
  y = math.max(bounds.y, math.min(y, bounds.y + bounds.height - height))
  local frame = { x = x, y = y, width = width, height = height }
  return {
    frame = frame,
    origin = { x = frame.x, y = frame.y },
    scale = scale,
    logicalWidth = logicalWidth,
    logicalHeight = logicalHeight,
  }
end

---@param placement LayoutGeometry.HitPlacement
local function checkPlacement(placement)
  assert(type(placement) == "table", "a placement record is required")
  checkRect(placement.frame, "placement.frame")
  assert(isFiniteNumber(placement.scale) and placement.scale > 0, "placement.scale must be a finite positive number")
end

-- Inverse of the render placement (translate(origin) + scale): nil outside
-- the half-open frame, exact logical coordinates inside.
---@param placement LayoutGeometry.HitPlacement
---@param hostX number
---@param hostY number
---@return number? logicalX
---@return number? logicalY
function LayoutGeometry.hostToLogical(placement, hostX, hostY)
  checkPlacement(placement)
  assert(isFiniteNumber(hostX) and isFiniteNumber(hostY), "host coordinates must be finite numbers")
  local frame = placement.frame
  if not LayoutGeometry.containsPoint(frame, hostX, hostY) then
    return nil
  end
  return (hostX - frame.x) / placement.scale, (hostY - frame.y) / placement.scale
end

---@param placement LayoutGeometry.Placement
---@param logicalX number
---@param logicalY number
---@return number hostX
---@return number hostY
function LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  checkPlacement(placement)
  local origin = assert(placement.origin, "logical mapping requires a placement origin")
  assert(isFiniteNumber(origin.x) and isFiniteNumber(origin.y), "placement.origin must be finite coordinates")
  assert(isFiniteNumber(logicalX) and isFiniteNumber(logicalY), "logical coordinates must be finite numbers")
  return origin.x + logicalX * placement.scale, origin.y + logicalY * placement.scale
end

return LayoutGeometry
