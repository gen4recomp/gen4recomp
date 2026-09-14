-- FieldPixelScale owns the integer field presentation scale and its camera projection.

---@class FieldPixelScale
---@field _baseCameraZoom number
---@field _minCameraZoom number
---@field _maxCameraZoom number
---@field _referenceHeight number
---@field _resizeCompensation number
---@field _height number
---@field _automaticScale integer
---@field _minScale integer
---@field _maxScale integer
---@field _manualOffset integer
local FieldPixelScale = {}
FieldPixelScale.__index = FieldPixelScale

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function positiveFinite(value, name)
  assert(isFinite(value) and value > 0, name .. " must be finite and positive")
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function scaleState(self, height)
  local autoCameraZoom = clamp(
    self._baseCameraZoom * (self._referenceHeight / height) ^ self._resizeCompensation,
    self._minCameraZoom,
    self._maxCameraZoom
  )
  local automaticScale = math.max(1, math.floor((height / 192) * autoCameraZoom + 0.5))
  local minScale = math.max(1, math.ceil(self._minCameraZoom * height / 192))
  local maxScale = math.floor(self._maxCameraZoom * height / 192)
  if maxScale < minScale then
    return automaticScale, minScale, maxScale, 1, 0
  end
  automaticScale = clamp(automaticScale, minScale, maxScale)
  local minimumOffset = minScale - automaticScale
  local maximumOffset = maxScale - automaticScale
  local offset = clamp(self._manualOffset, minimumOffset, maximumOffset)
  return automaticScale, minScale, maxScale, automaticScale + offset, offset
end

---@param config table<string, unknown>?
---@return FieldPixelScale
function FieldPixelScale.new(config)
  if config == nil then
    config = {}
  else
    assert(type(config) == "table", "field pixel-scale configuration must be a table")
  end

  local baseCameraZoom = config.baseCameraZoom
  if baseCameraZoom == nil then
    baseCameraZoom = 1
  end
  local minCameraZoom = config.minCameraZoom
  if minCameraZoom == nil then
    minCameraZoom = 0.5
  end
  local maxCameraZoom = config.maxCameraZoom
  if maxCameraZoom == nil then
    maxCameraZoom = 1.5
  end
  local referenceHeight = config.referenceHeight
  if referenceHeight == nil then
    referenceHeight = 600
  end
  local resizeCompensation = config.resizeCompensation
  if resizeCompensation == nil then
    resizeCompensation = 0.7
  end

  positiveFinite(baseCameraZoom, "base camera zoom")
  positiveFinite(minCameraZoom, "minimum camera zoom")
  positiveFinite(maxCameraZoom, "maximum camera zoom")
  assert(maxCameraZoom >= minCameraZoom, "maximum camera zoom must not be below minimum")
  positiveFinite(referenceHeight, "reference height")
  assert(
    isFinite(resizeCompensation) and resizeCompensation >= 0 and resizeCompensation <= 1,
    "resize compensation must be between zero and one"
  )

  local self = setmetatable({
    _baseCameraZoom = baseCameraZoom,
    _minCameraZoom = minCameraZoom,
    _maxCameraZoom = maxCameraZoom,
    _referenceHeight = referenceHeight,
    _resizeCompensation = resizeCompensation,
    _height = referenceHeight,
    _automaticScale = 1,
    _minScale = 1,
    _maxScale = 1,
    _manualOffset = 0,
  }, FieldPixelScale)
  self:resize(referenceHeight)
  return self
end

---@param height number
function FieldPixelScale:resize(height)
  positiveFinite(height, "field reference height")
  local automaticScale, minScale, maxScale, _, offset = scaleState(self, height)
  self._height = height
  self._automaticScale = math.floor(automaticScale)
  self._minScale = math.floor(minScale)
  self._maxScale = math.floor(maxScale)
  self._manualOffset = math.floor(offset)
end

---@return integer
function FieldPixelScale:resolvedScale()
  if self._maxScale < self._minScale then
    return 1
  end
  return math.floor(clamp(self._automaticScale + self._manualOffset, self._minScale, self._maxScale))
end

---@return number
function FieldPixelScale:cameraZoom()
  return self:resolvedScale() * 192 / self._height
end

function FieldPixelScale:zoomIn()
  if self._maxScale < self._minScale then
    self._manualOffset = 0
    return
  end
  self._manualOffset = math.floor(
    clamp(self._manualOffset + 1, self._minScale - self._automaticScale, self._maxScale - self._automaticScale)
  )
end

function FieldPixelScale:zoomOut()
  if self._maxScale < self._minScale then
    self._manualOffset = 0
    return
  end
  self._manualOffset = math.floor(
    clamp(self._manualOffset - 1, self._minScale - self._automaticScale, self._maxScale - self._automaticScale)
  )
end

function FieldPixelScale:reset()
  self._manualOffset = 0
end

return FieldPixelScale
