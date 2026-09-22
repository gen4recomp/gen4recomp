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
---@field frame LayoutGeometry.Rect the complete transformed logical surface, possibly outside the target bounds
---@field origin { x: number, y: number }? the render translate point; defaults to the frame origin for legacy mapping-only records
---@field scale number host units per logical pixel
---@field logicalWidth number
---@field logicalHeight number
---@field clipRect LayoutGeometry.Rect? the visible host region; defaults to the frame for legacy mapping-only records
---@field pixelScale number? framebuffer pixels per logical pixel
---@field pixelRatio number? framebuffer pixels per host unit
---@field visibleLogicalRect LayoutGeometry.Rect? the visible logical region
---@field crop { left: number, right: number, top: number, bottom: number }? whole source pixels hidden per edge

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

-- The full-frame origin is the single inversion origin: legacy records
-- without an explicit origin invert through their frame origin, and legacy
-- records without a clip hit-test the whole frame.
---@alias LayoutGeometry.Point { x: number, y: number }

---@param placement LayoutGeometry.Placement
---@return LayoutGeometry.Point
local function placementOrigin(placement)
  local origin = placement.origin or placement.frame
  assert(isFiniteNumber(origin.x) and isFiniteNumber(origin.y), "placement.origin must be finite coordinates")
  return { x = origin.x, y = origin.y }
end

---@param placement LayoutGeometry.Placement
---@return LayoutGeometry.Rect
local function placementClip(placement)
  if placement.clipRect == nil then
    return LayoutGeometry.rect(placement.frame, "placement.frame")
  end
  return LayoutGeometry.rect(placement.clipRect, "placement.clipRect")
end

-- Inverse of the render placement (translate(origin) + scale): nil outside
-- the half-open intersection of the full frame and the visible clip, exact
-- logical coordinates inside. Cropping never moves the inversion origin, so
-- a visible point near a cropped edge maps to its true logical coordinate.
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
  local clip = placementClip(placement --[[@as LayoutGeometry.Placement]])
  if not LayoutGeometry.containsPoint(clip, hostX, hostY) then
    return nil
  end
  local origin = placementOrigin(placement --[[@as LayoutGeometry.Placement]])
  return (hostX - origin.x) / placement.scale, (hostY - origin.y) / placement.scale
end

---@param placement LayoutGeometry.Placement
---@param logicalX number
---@param logicalY number
---@return number hostX
---@return number hostY
function LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  checkPlacement(placement)
  local origin = placementOrigin(placement)
  assert(isFiniteNumber(logicalX) and isFiniteNumber(logicalY), "logical coordinates must be finite numbers")
  return origin.x + logicalX * placement.scale, origin.y + logicalY * placement.scale
end

-- Full, un-clipped transformed extents of a logical rectangle: the forward
-- transform of its edges through the placement origin and scale. Never
-- selects a scale and never mutates either record.
---@param placement LayoutGeometry.Placement
---@param rect LayoutGeometry.Rect
---@return LayoutGeometry.Rect
function LayoutGeometry.logicalRectToHost(placement, rect)
  checkPlacement(placement)
  local source = LayoutGeometry.rect(rect, "rect")
  local origin = placementOrigin(placement)
  return {
    x = origin.x + source.x * placement.scale,
    y = origin.y + source.y * placement.scale,
    width = source.width * placement.scale,
    height = source.height * placement.scale,
  }
end

---@param a LayoutGeometry.Rect
---@param b LayoutGeometry.Rect
---@return LayoutGeometry.Rect? the intersection; nil when the rectangles do not overlap
local function intersectRects(a, b)
  local x = math.max(a.x, b.x)
  local y = math.max(a.y, b.y)
  local farX = math.min(a.x + a.width, b.x + b.width)
  local farY = math.min(a.y + a.height, b.y + b.height)
  if farX <= x or farY <= y then
    return nil
  end
  return { x = x, y = y, width = farX - x, height = farY - y }
end

-- A child placement for a logical subregion of its parent: the child's
-- logical origin is the subregion's top-left in parent space, its logical
-- dimensions are the subregion dimensions, and its clip is the intersection
-- of the parent clip with the child full frame. Returns nil when the child
-- is wholly invisible instead of a malformed zero-size placement.
---@param parent LayoutGeometry.Placement
---@param rect LayoutGeometry.Rect a logical subregion in parent coordinates
---@return LayoutGeometry.Placement?
function LayoutGeometry.subPlacement(parent, rect)
  checkPlacement(parent --[[@as LayoutGeometry.HitPlacement]])
  assert(
    isFiniteNumber(parent.logicalWidth)
      and parent.logicalWidth > 0
      and isFiniteNumber(parent.logicalHeight)
      and parent.logicalHeight > 0,
    "subPlacement requires a parent with finite positive logical dimensions"
  )
  local source = LayoutGeometry.rect(rect, "rect")
  local origin = placementOrigin(parent)
  local frame = {
    x = origin.x + source.x * parent.scale,
    y = origin.y + source.y * parent.scale,
    width = source.width * parent.scale,
    height = source.height * parent.scale,
  }
  local clip = intersectRects(placementClip(parent), frame)
  if clip == nil then
    return nil
  end
  local child = {
    frame = frame,
    origin = { x = frame.x, y = frame.y },
    scale = parent.scale,
    logicalWidth = source.width,
    logicalHeight = source.height,
    clipRect = clip,
  }
  if parent.pixelScale ~= nil then
    child.pixelScale = parent.pixelScale
  end
  if parent.pixelRatio ~= nil then
    child.pixelRatio = parent.pixelRatio
  end
  return child
end

return LayoutGeometry
