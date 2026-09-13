-- Runtime owner of the compiled mon icon pages. It loads and validates
-- the generated icon layout once, acquires one image per declared page,
-- hands out one cached quad per icon key and frame, and releases every
-- page image exactly once. Icon selection stays upstream (catalog form
-- icons, egg selectors); an unknown semantic key is a structured error,
-- never a blank icon. Portrait pages are never acquired here: field core
-- warms the icon set, and portraits stay on demand elsewhere.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")

---@class MonIconAssetProvider
---@field _graphics love.graphics
---@field _manifest table<string, unknown>
---@field _images table<integer, love.Image> page image by zero-based page id
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
---@param graphics love.graphics
---@param manifest table<string, unknown>
---@param pageId integer
---@return love.Image
local function acquirePage(cacheFs, graphics, manifest, pageId)
  local page = manifest.pages[pageId]
  assert(page ~= nil, "icon page " .. pageId .. " is declared")
  local path = MonCache.iconPagePath(pageId)
  local data = cacheFs:read(path)
  if not data then
    Errors.raise(FieldErrors.MON_ICON_ATLAS_MISSING, "mon icon page missing at " .. path, { path = path })
  end
  local imageData = assert(data, "the icon page bytes are required")
  local image = graphics.newImage(love.filesystem.newFileData(imageData, path))
  image:setFilter("nearest", "nearest")
  local imageWidth, imageHeight = image:getWidth(), image:getHeight()
  for selector, entry in pairs(manifest.entries) do
    if entry.pageId == pageId then
      for _, frame in ipairs(entry.frames) do
        assert(
          frame.x + frame.width <= imageWidth and frame.y + frame.height <= imageHeight,
          "icon frame for " .. selector .. " exceeds its page"
        )
      end
    end
  end
  return image
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.graphics }?
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
  local self = setmetatable({
    _graphics = graphics,
    _manifest = manifest,
    _images = {},
    _quads = {},
    _released = false,
  }, MonIconAssetProvider)
  local ok, err = pcall(function()
    local pageIds = manifest.pageIds --[[@as integer[] ]]
    for _, pageId in ipairs(pageIds) do
      self._images[pageId] = acquirePage(cacheFs, graphics, manifest, pageId)
    end
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

-- The page image carrying one icon selector. Selectors sharing a page
-- share its image; selectors on different pages resolve to their own.
---@param iconKey string
---@return love.Image the page image for draw calls
function MonIconAssetProvider:image(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return assert(self._images[entry.pageId], "the icon page is loaded for " .. iconKey)
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
    local image = assert(self._images[entry.pageId], "the icon page is loaded for " .. iconKey)
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

-- Releases every page image exactly once; quads reference no resources of
-- their own, so dropping the cache is sufficient. Safe to call repeatedly.
-- A construction failure releases only the pages acquired before it and
-- leaves unrelated shared resources live.
function MonIconAssetProvider:release()
  local images = self._images
  self._images = {}
  self._quads = {}
  self._released = true
  for _, image in pairs(images) do
    if image ~= nil and image.release then
      image:release()
    end
  end
end

return MonIconAssetProvider
