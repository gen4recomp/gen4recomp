-- Runtime owner of the compiled mon icon atlas. It loads and validates
-- the generated icon manifest once, acquires the atlas image once, hands out one
-- cached quad per icon key and frame, and releases the image exactly once.
-- Icon selection stays upstream (catalog form icons, egg selectors); an
-- unknown semantic key is a structured error, never a blank icon.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")

---@class MonIconAssetProvider
---@field _graphics love.Graphics|love.graphics
---@field _manifest table<string, unknown>
---@field _image love.Image?
---@field _quads table<string, love.Quad>
---@field _released boolean
local MonIconAssetProvider = {}
MonIconAssetProvider.__index = MonIconAssetProvider

---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "no compiled mon icon manifest at " .. MonCache.iconManifestPath(),
      { path = MonCache.iconManifestPath() }
    )
  end
  local ok, err = pcall(MonAssetSchema.assertManifest, manifest, MonCache.ICON_MANIFEST_SCHEMA)
  if not ok then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "the compiled mon icon manifest is invalid: " .. tostring(err),
      { path = MonCache.iconManifestPath() }
    )
  end
  assert(manifest ~= nil, "the icon manifest carries validated entries")
  return manifest
end

---@param manifest table<string, unknown>
---@param iconKey string
---@return table<string, unknown>
local function entryFor(manifest, iconKey)
  assert(type(iconKey) == "string" and iconKey ~= "", "icon selection requires a semantic key")
  local entry = manifest.entries[iconKey]
  if entry == nil then
    Errors.raise(FieldErrors.MON_ICON_UNKNOWN_KEY, "unknown mon icon key " .. iconKey, { iconKey = iconKey })
  end
  assert(entry ~= nil, "the manifest carries the resolved entry")
  return entry
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.Graphics|love.graphics }?
---@return MonIconAssetProvider
function MonIconAssetProvider.new(cacheFs, opts)
  assert(cacheFs ~= nil, "MonIconAssetProvider requires a CacheFs")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "MonIconAssetProvider requires love.graphics")
  local manifest = loadManifest(cacheFs)
  local data = cacheFs:read(MonCache.iconImagePath())
  if not data then
    Errors.raise(
      FieldErrors.MON_ICON_ATLAS_MISSING,
      "mon icon atlas missing at " .. MonCache.iconImagePath(),
      { path = MonCache.iconImagePath() }
    )
  end
  local self = setmetatable({
    _graphics = graphics,
    _manifest = manifest,
    _image = nil,
    _quads = {},
    _released = false,
  }, MonIconAssetProvider)
  local imageData = assert(data, "the icon atlas bytes are required")
  local ok, err = pcall(function()
    self._image = graphics.newImage(love.filesystem.newFileData(imageData, MonCache.iconImagePath()))
    self._image:setFilter("nearest", "nearest")
    local imageWidth, imageHeight = self._image:getWidth(), self._image:getHeight()
    for selector, entry in pairs(manifest.entries) do
      for _, frame in ipairs(entry.frames) do
        assert(
          frame.x + frame.width <= imageWidth and frame.y + frame.height <= imageHeight,
          "icon frame for " .. selector .. " exceeds the atlas"
        )
      end
    end
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

---@return love.Image the shared atlas image for draw calls
function MonIconAssetProvider:image()
  return assert(self._image, "the icon atlas is loaded")
end

---@param iconKey string
---@param frameIndex integer?
---@return love.Quad quad
function MonIconAssetProvider:quadFor(iconKey, frameIndex)
  assert(not self._released, "the icon provider is released")
  frameIndex = frameIndex or 1
  assert(type(frameIndex) == "number" and frameIndex % 1 == 0 and frameIndex >= 1, "icon frame index starts at one")
  local entry = entryFor(self._manifest, iconKey)
  assert(frameIndex <= #entry.frames, "icon frame " .. frameIndex .. " is missing for " .. iconKey)
  local cacheKey = iconKey .. "#" .. frameIndex
  local quad = self._quads[cacheKey]
  if quad == nil then
    local frame = entry.frames[frameIndex]
    local image = assert(self._image, "the icon atlas is loaded")
    quad = self._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
    self._quads[cacheKey] = quad
  end
  return quad
end

---@param iconKey string
---@return { width: integer, height: integer }
function MonIconAssetProvider:dimensions(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return { width = entry.width, height = entry.height }
end

-- Releases the atlas image exactly once; quads reference no resources of
-- their own, so dropping the cache is sufficient. Safe to call repeatedly.
function MonIconAssetProvider:release()
  local image = self._image
  self._image = nil
  self._quads = {}
  self._released = true
  if image ~= nil and image.release then
    image:release()
  end
end

return MonIconAssetProvider
