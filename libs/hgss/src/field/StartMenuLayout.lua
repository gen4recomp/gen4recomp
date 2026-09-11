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

local StartMenuLayout = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

-- Minimum usable region sizes: the landscape side panel must be at least
-- half the canonical width, and a portrait partition must leave both the
-- world reference frame and the lower panel at least half the canonical
-- height. Below those floors the layout falls back to the centered uniform
-- fit.
local MIN_SIDE_PANEL_WIDTH = CANONICAL_WIDTH / 2
local MIN_PANEL_HEIGHT = CANONICAL_HEIGHT / 2
local MIN_WORLD_HEIGHT = CANONICAL_HEIGHT / 2

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

-- The uniform centered fit inside the safe rectangle delegates to the
-- shared geometry helper: the canonical surface scaled by
-- min(safeWidth/256, safeHeight/192) and centered, with only the origin
-- snapped at the host boundary so the exact frame stays inside safe bounds.
---@param safe ScreenTopology.Rectangle
---@return number scale
---@return number width
---@return number height
---@return integer x
---@return integer y
local function centeredFit(safe)
  local placement = LayoutGeometry.centeredFit(safe, CANONICAL_WIDTH, CANONICAL_HEIGHT, { integer = "floor" })
  local scale = placement.scale
  local frame = placement.frame
  local width = frame.width
  local height = frame.height
  local x = frame.x --[[@as integer]]
  local y = frame.y --[[@as integer]]
  return scale, width, height, x, y
end

-- The landscape side panel: the actual right gutter -- the world reference
-- frame's right edge to the safe right -- and the menu scales into it while
-- staying 4:3 internally. Returns nil when the gutter is too narrow to be
-- usable.
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@return number? scale
---@return number? width
---@return number? height
---@return integer? x
---@return integer? y
local function sidePanel(safe, referenceFrame)
  local gutterStart = referenceFrame.x + referenceFrame.width
  local panelWidth = safe.x + safe.width - gutterStart
  if panelWidth < MIN_SIDE_PANEL_WIDTH then
    return nil
  end
  local placement = LayoutGeometry.centeredFit(
    { x = gutterStart, y = safe.y, width = panelWidth, height = safe.height },
    CANONICAL_WIDTH,
    CANONICAL_HEIGHT,
    { integer = "floor" }
  )
  local panelScale = placement.scale
  local panelFrame = placement.frame
  local width = panelFrame.width
  local height = panelFrame.height
  local x = panelFrame.x --[[@as integer]]
  local y = panelFrame.y --[[@as integer]]
  return panelScale, width, height, x, y
end

-- The portrait lower panel: the region below the world reference frame
-- becomes a full-width bottom panel. Returns nil when either region would
-- drop below its minimum usable size.
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@return number? scale
---@return number? width
---@return number? height
---@return integer? x
---@return integer? y
local function bottomPanel(safe, referenceFrame)
  local panelTop = math.floor(referenceFrame.y + referenceFrame.height)
  local panelHeight = safe.y + safe.height - panelTop
  if referenceFrame.height < MIN_WORLD_HEIGHT then
    return nil
  end
  if panelHeight <= 0 then
    return nil
  end
  local placement = LayoutGeometry.centeredFit(
    { x = safe.x, y = panelTop, width = safe.width, height = panelHeight },
    CANONICAL_WIDTH,
    CANONICAL_HEIGHT,
    { integer = "floor" }
  )
  local frame = placement.frame
  if frame.height < MIN_PANEL_HEIGHT then
    return nil
  end
  local scale = placement.scale
  local width = frame.width
  local height = frame.height
  local x = frame.x --[[@as integer]]
  local y = frame.y --[[@as integer]]
  return scale, width, height, x, y
end

---@class StartMenuLayout.Frame
---@field x integer
---@field y integer
---@field width number
---@field height number

---@class StartMenuLayout.Placement
---@field surfaceId string
---@field frame StartMenuLayout.Frame
---@field scale number
---@field logicalWidth integer
---@field logicalHeight integer

-- Resolves the chosen partition (bottom panel / side panel) or falls back to
-- the centered uniform fit when the partition is unusable. The helper calls
-- return multiple values, so they must not flow through `or`, which would
-- collapse them to one.

---@param builder fun(safe: ScreenTopology.Rectangle, referenceFrame: ScreenTopology.Rectangle): number?, number?, number?, integer?, integer?
---@param safe ScreenTopology.Rectangle
---@param referenceFrame ScreenTopology.Rectangle
---@return number scale
---@return number width
---@return number height
---@return integer x
---@return integer y
local function panelOrCentered(builder, safe, referenceFrame)
  local scale, width, height, x, y = builder(safe, referenceFrame)
  if scale == nil then
    return centeredFit(safe)
  end
  return scale, assert(width), assert(height), assert(x), assert(y)
end

-- Resolves the complete placement record for the canonical 256x192 Start
-- Menu surface against the actual world reference frame (FieldViewport's
-- referenceFrame). Internal menu geometry is invariant; only the whole
-- surface is positioned and scaled.

---@param topology ScreenTopology
---@param referenceFrame ScreenTopology.Rectangle the world reference frame
---@return StartMenuLayout.Placement
function StartMenuLayout.resolve(topology, referenceFrame)
  assert(
    type(referenceFrame) == "table"
      and type(referenceFrame.x) == "number"
      and type(referenceFrame.y) == "number"
      and type(referenceFrame.width) == "number"
      and type(referenceFrame.height) == "number",
    "StartMenuLayout requires the world reference frame"
  )
  local surface = StartMenuLayout.selectSurface(topology)
  local safe = assertSafeRect(surface)
  local scale, width, height, x, y
  if surface.role == "auxiliary" then
    scale, width, height, x, y = centeredFit(safe)
  elseif safe.width < safe.height then
    scale, width, height, x, y = panelOrCentered(bottomPanel, safe, referenceFrame)
  else
    scale, width, height, x, y = panelOrCentered(sidePanel, safe, referenceFrame)
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
