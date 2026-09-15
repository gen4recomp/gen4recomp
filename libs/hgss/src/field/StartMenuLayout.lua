-- StartMenuLayout places the canonical 256x192 Start Menu surface on a
-- ScreenTopology without reflowing its internal geometry: only the whole
-- surface is positioned and scaled. resolve() takes the actual world
-- reference frame the FieldViewport computes and returns one complete
-- placement record ({ surfaceId, frame, scale, logicalWidth,
-- logicalHeight }): the auxiliary display is the menu screen when one
-- exists; a landscape host gets a side panel in the real right gutter
-- (reference frame right edge to safe right); a single 4:3 host is a
-- full-surface modal overlay; a portrait host partitions vertically with
-- the menu as a full-width lower panel below the reference frame, subject
-- to minimum usable region sizes. The canonical surface is always scaled
-- uniformly, centered in the chosen region, with only the host origin
-- snapped to integer pixels at the host boundary. The frame extent stays the
-- exact canonical dimensions times the uniform scale. Hit testing and
-- rendering consume the same record
-- through hostToLogical(), so there is never a second set of scaled
-- rectangles. Pure: no LÖVE, no I/O.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PixelScale = require("libs.ui.src.PixelScale")

local StartMenuLayout = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

---@param value unknown
---@param name string
local function assertFiniteNumber(value, name)
  assert(
    type(value) == "number" and value == value and value > -math.huge and value < math.huge,
    name .. " must be finite"
  )
end

---@param value unknown
---@param name string
local function assertInteger(value, name)
  assertFiniteNumber(value, name)
  assert(value == math.floor(value), name .. " must be an integer")
end

-- The chosen surface's safe rectangle must be an integer host-space rect: the
-- deterministic rounding contract floors at the host boundary, so fractional
-- inputs cannot produce a frame that stays inside the safe bounds.
---@param surface ScreenTopology.Surface
---@return ScreenTopology.Rectangle
local function assertSafeRect(surface)
  assert(type(surface) == "table" and type(surface.safeRect) == "table", "the placed surface needs a safe rect")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assertInteger(surface.safeRect[field], "safe rect " .. field)
  end
  return surface.safeRect
end

-- The placement surface: the auxiliary display when one exists, else the
-- first surface, mirroring the sibling MenuLayout surface selection.
---@param topology ScreenTopology
---@return ScreenTopology.Surface
function StartMenuLayout.selectSurface(topology)
  assert(
    type(topology) == "table" and type(topology.surfaces) == "table" and #topology.surfaces > 0,
    "StartMenuLayout requires a ScreenTopology"
  )
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" then
      return surface
    end
  end
  return topology.surfaces[1]
end

-- The uniform fit inside a usable region chooses an integer scale bounded by
-- the field authority and centers the exact canonical extent. A region below
-- the 1x floor is not a valid partition candidate.
---@param region ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer? scale
---@return integer? width
---@return integer? height
---@return integer? x
---@return integer? y
local function integerFit(region, preferredScale)
  if region.width < CANONICAL_WIDTH or region.height < CANONICAL_HEIGHT then
    return nil
  end
  local scale = PixelScale.fitPreferred(region, CANONICAL_WIDTH, CANONICAL_HEIGHT, preferredScale)
  local width = CANONICAL_WIDTH * scale
  local height = CANONICAL_HEIGHT * scale
  local x = math.floor(region.x + (region.width - width) / 2)
  local y = math.floor(region.y + (region.height - height) / 2)
  x = math.max(math.ceil(region.x), math.min(x, math.floor(region.x + region.width - width)))
  y = math.max(math.ceil(region.y), math.min(y, math.floor(region.y + region.height - height)))
  return scale, width, height, x, y
end

-- The centered fallback uses the whole safe rectangle and therefore remains
-- valid only on hosts that can present the canonical surface at 1x.
---@param safe ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer? scale
---@return integer? width
---@return integer? height
---@return integer? x
---@return integer? y
local function centeredFit(safe, preferredScale)
  return integerFit(safe, preferredScale)
end

---@param safe ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer scale
---@return integer width
---@return integer height
---@return integer? x
---@return integer? y
local function requireFit(safe, preferredScale)
  local scale, width, height, x, y = centeredFit(safe, preferredScale)
  assert(scale ~= nil, "the safe surface cannot contain the Start Menu at 1x")
  return assert(scale), assert(width), assert(height), assert(x), assert(y)
end

-- The landscape side panel: the actual right gutter -- the world reference
-- frame's right edge to the safe right -- and the menu scales into it while
-- staying 4:3 internally. Returns nil when the gutter is too narrow to be
-- usable.
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer? scale
---@return integer? width
---@return integer? height
---@return integer? x
---@return integer? y
local function sidePanel(safe, referenceFrame, preferredScale)
  local gutterStart = referenceFrame.x + referenceFrame.width
  local panelWidth = safe.x + safe.width - gutterStart
  return integerFit({ x = gutterStart, y = safe.y, width = panelWidth, height = safe.height }, preferredScale)
end

-- The portrait lower panel: the region below the world reference frame
-- becomes a full-width bottom panel. Returns nil when either region would
-- drop below its minimum usable size.
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer? scale
---@return integer? width
---@return integer? height
---@return integer? x
---@return integer? y
local function bottomPanel(safe, referenceFrame, preferredScale)
  local panelTop = math.floor(referenceFrame.y + referenceFrame.height)
  local panelHeight = safe.y + safe.height - panelTop
  return integerFit({ x = safe.x, y = panelTop, width = safe.width, height = panelHeight }, preferredScale)
end

---@class StartMenuLayout.Frame
---@field x integer
---@field y integer
---@field width number
---@field height number

---@class StartMenuLayout.Placement
---@field surfaceId string
---@field frame StartMenuLayout.Frame
---@field scale integer
---@field logicalWidth integer
---@field logicalHeight integer

-- Resolves the chosen partition (bottom panel / side panel) or falls back to
-- the centered uniform fit when the partition is unusable. The helper calls
-- return multiple values, so they must not flow through `or`, which would
-- collapse them to one.

---@param builder fun(safe: ScreenTopology.Rectangle, referenceFrame: ScreenTopology.Rectangle, preferredScale: integer): integer?, integer?, integer?, integer?, integer?
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@param preferredScale integer
---@return integer scale
---@return integer width
---@return integer height
---@return integer? x
---@return integer? y
local function panelOrCentered(builder, safe, referenceFrame, preferredScale)
  local scale, width, height, x, y = builder(safe, referenceFrame, preferredScale)
  if scale == nil then
    return requireFit(safe, preferredScale)
  end
  return assert(scale), assert(width), assert(height), assert(x), assert(y)
end

-- Resolves the complete placement record for the canonical 256x192 Start
-- Menu surface against the actual world reference frame (FieldViewport's
-- referenceFrame). Internal menu geometry is invariant; only the whole
-- surface is positioned and scaled.

---@param topology ScreenTopology
---@param referenceFrame ScreenTopology.Rectangle the world reference frame
---@param preferredScale integer the field presentation scale cap
---@return StartMenuLayout.Placement
function StartMenuLayout.resolve(topology, referenceFrame, preferredScale)
  assert(
    type(referenceFrame) == "table"
      and type(referenceFrame.x) == "number"
      and type(referenceFrame.y) == "number"
      and type(referenceFrame.width) == "number"
      and type(referenceFrame.height) == "number",
    "StartMenuLayout requires the world reference frame"
  )
  assert(
    type(preferredScale) == "number" and preferredScale > 0 and preferredScale % 1 == 0,
    "StartMenuLayout requires a positive integer preferred scale"
  )
  local surface = StartMenuLayout.selectSurface(topology)
  local safe = assertSafeRect(surface)
  local scale, width, height, x, y
  if surface.role == "auxiliary" then
    scale, width, height, x, y = requireFit(safe, preferredScale)
  elseif safe.width < safe.height then
    scale, width, height, x, y = panelOrCentered(bottomPanel, safe, referenceFrame, preferredScale)
  else
    scale, width, height, x, y = panelOrCentered(sidePanel, safe, referenceFrame, preferredScale)
  end
  return {
    surfaceId = surface.id,
    frame = { x = x, y = y, width = width, height = height },
    scale = scale,
    logicalWidth = CANONICAL_WIDTH,
    logicalHeight = CANONICAL_HEIGHT,
  }
end

-- Maps a host-space point to canonical logical coordinates (0..255 x 0..191)
-- through the placement record. Hit testing first rejects every point outside
-- the frame, then maps inside points; the transform is the exact inverse of
-- the render placement (frame origin + canonical * scale), so hit testing and
-- rendering share one record with no second set of scaled rectangles.

---@param placement StartMenuLayout.Placement
---@param hostX number
---@param hostY number
---@return number? canonicalX
---@return number? canonicalY
function StartMenuLayout.hostToLogical(placement, hostX, hostY)
  return LayoutGeometry.hostToLogical(placement, hostX, hostY)
end

return StartMenuLayout
