-- Adapts HGSS field presentation state into the frame consumed by
-- the concrete Nintendo DS LÖVE renderer.

local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

---@class FieldRenderer
---@field gxRenderer GxRenderer
---@field stats table<string, unknown>
---@field sceneColor GxRenderer.Canvas?
---@field renderState GxRenderer.Canvas?
---@field _ownsRenderer boolean
---@field _queueScratch RenderQueueScratch
---@field clearColor number[]?
local FieldRenderer = {}
FieldRenderer.__index = FieldRenderer

local function selectedLighting(sceneRuntime)
  local profile = sceneRuntime.lighting
  if profile == nil or profile.records == nil then
    return nil
  end
  return FieldLightProfile.select(profile, sceneRuntime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
end

---@param opts table<string, unknown>?
---@return FieldRenderer
function FieldRenderer.new(opts)
  opts = opts or {}
  local gxRenderer = opts.gxRenderer
  local ownsRenderer = gxRenderer == nil
  if gxRenderer == nil then
    gxRenderer = GxRenderer.new(opts)
  end
  return setmetatable({
    gxRenderer = gxRenderer,
    stats = gxRenderer.stats,
    _ownsRenderer = ownsRenderer,
    clearColor = opts.clearColor,
    _queueScratch = {
      opaque = {},
      cutout = {},
      mixedOpaque = {},
      wireframe = {},
      blended = {},
    },
  }, FieldRenderer)
end

---@param sceneRuntime table<string, unknown>
---@param camera table<string, unknown>
---@param worldParts table[][]?
---@param spriteItems table[]?
---@param viewport table<string, unknown>
---@param alpha number
function FieldRenderer:draw(sceneRuntime, camera, worldParts, spriteItems, viewport, alpha)
  assert(type(sceneRuntime) == "table", "field scene presentation is required")
  assert(type(camera) == "table", "field presentation camera is required")
  assert(type(camera.far) == "number" and camera.far > 0, "FieldRenderer requires camera.far to be a positive number")
  local viewMatrix = camera:view(alpha)
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, self._queueScratch)
  self.gxRenderer:draw({
    lighting = selectedLighting(sceneRuntime),
    edgeColors = sceneRuntime.edgeColors,
    fog = sceneRuntime.fog,
    viewMatrix = viewMatrix,
    cameraZoom = camera.zoom,
    worldProjection = worldProjection,
    billboardProjection = billboardProjection,
    clearColor = self.clearColor,
    queue = queue,
    spriteItems = spriteItems,
    viewport = viewport,
  })
  self.sceneColor = self.gxRenderer.sceneColor
  self.renderState = self.gxRenderer.renderState
end

function FieldRenderer:release()
  if self._ownsRenderer then
    self.gxRenderer:release()
    self._ownsRenderer = false
  end
end

return FieldRenderer
