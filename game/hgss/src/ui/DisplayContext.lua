-- Actual drawable/topology measurement shared by the HGSS entry states. The
-- context owns the graphics boundary (dimensions and framebuffer ratio) and
-- the topology provider; every measurement is a fresh caller-owned record
-- with a stable structural signature, so entry states reconcile on content
-- rather than on timestamps. Defaults are acquired at construction, never
-- at module load. Pure otherwise: no layout, no gameplay state.

local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

---@class DisplayContext
---@field _graphics table<string, unknown> the host graphics namespace behind getDimensions/getDPIScale
---@field _topologyProvider (fun(width: number, height: number): ScreenTopology)? injected actual-surface provider
local DisplayContext = {}
DisplayContext.__index = DisplayContext

---@class DisplayContext.Options
---@field graphics table<string, unknown>? must supply getDimensions/getDPIScale; defaults to love.graphics
---@field topologyProvider (fun(width: number, height: number): ScreenTopology)? actual host surfaces

---@class DisplayMeasurement
---@field width number host-unit drawable width
---@field height number host-unit drawable height
---@field topology ScreenTopology validated caller-owned copy of the actual surfaces
---@field pixelRatio number framebuffer pixels per host unit
---@field signature string stable structural identity (never a timestamp)

-- The actual host default: one main/world surface over the whole drawable
-- with the current mobile touch capability. This is the previous
-- FieldState-local default, moved here so every entry state shares it.
---@param width number
---@param height number
---@return ScreenTopology
local function defaultTopology(width, height)
  local os = love.system and love.system.getOS and love.system.getOS() or ""
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = os == "Android" or os == "iOS",
    role = "world",
  })
end

---@param value unknown
---@param name string
local function assertPositiveFinite(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value > 0,
    name .. " must be a positive finite number"
  )
end

---@param width number
---@param height number
---@param pixelRatio number
---@param topology ScreenTopology
---@return string
local function signatureFor(width, height, pixelRatio, topology)
  local parts = { tostring(width), tostring(height), tostring(pixelRatio) }
  for _, surface in ipairs(topology.surfaces) do
    local rect = surface.rect
    local safe = surface.safeRect or rect
    parts[#parts + 1] = string.format(
      "|%s:%s:%g:%g:%g:%g:%g:%g:%g:%g:%s",
      tostring(surface.id),
      tostring(surface.role),
      rect.x,
      rect.y,
      rect.width,
      rect.height,
      safe.x,
      safe.y,
      safe.width,
      safe.height,
      tostring(surface.touch)
    )
    for _, region in ipairs(surface.occupiedRegions or {}) do
      parts[#parts + 1] = string.format(";%g:%g:%g:%g", region.x, region.y, region.width, region.height)
    end
  end
  return table.concat(parts)
end

---@param opts DisplayContext.Options?
---@return DisplayContext
function DisplayContext.new(opts)
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(
    type(graphics) == "table"
      and type(graphics.getDimensions) == "function"
      and type(graphics.getDPIScale) == "function",
    "DisplayContext requires a graphics namespace with getDimensions/getDPIScale"
  )
  local provider = opts.topologyProvider
  if provider ~= nil then
    assert(type(provider) == "function", "DisplayContext topologyProvider must be a function")
  end
  return setmetatable({ _graphics = graphics, _topologyProvider = provider }, DisplayContext)
end

-- Measures the current drawable: dimensions (explicit or from graphics),
-- the uniform framebuffer ratio, and a validated copy of the actual
-- topology. Never infers two screens from an application layout; a custom
-- provider's record is validated and copied, never retained.
---@param width number?
---@param height number?
---@return DisplayMeasurement
function DisplayContext:measure(width, height)
  local graphics = assert(self._graphics, "the display context requires its graphics namespace")
  local measuredWidth, measuredHeight = width, height
  if measuredWidth == nil or measuredHeight == nil then
    local dimensionsWidth, dimensionsHeight = (graphics --[[@as { getDimensions: fun(): number, number }]]).getDimensions()
    if measuredWidth == nil then
      measuredWidth = dimensionsWidth
    end
    if measuredHeight == nil then
      measuredHeight = dimensionsHeight
    end
  end
  assertPositiveFinite(measuredWidth, "drawable width")
  assertPositiveFinite(measuredHeight, "drawable height")
  local pixelRatio = (graphics --[[@as { getDPIScale: fun(): number }]]).getDPIScale()
  assertPositiveFinite(pixelRatio, "pixel ratio")
  local provided
  if self._topologyProvider ~= nil then
    provided = self._topologyProvider(measuredWidth, measuredHeight)
  else
    provided = defaultTopology(measuredWidth, measuredHeight)
  end
  assert(
    type(provided) == "table" and type(provided.surfaces) == "table",
    "the topology provider must return actual surfaces"
  )
  local topology = ScreenTopology.new({ surfaces = provided.surfaces })
  return {
    width = measuredWidth,
    height = measuredHeight,
    topology = topology,
    pixelRatio = pixelRatio,
    signature = signatureFor(measuredWidth, measuredHeight, pixelRatio, topology),
  }
end

return DisplayContext
