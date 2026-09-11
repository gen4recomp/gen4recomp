-- Runtime owner of the compiled item icon atlas. It loads and validates
-- the generated icon manifest once, acquires the atlas image once, hands
-- out one cached quad per icon key, and releases the image exactly once.
-- Icon selection stays upstream (the catalog icon key); an unknown semantic
-- key is a structured error, never a blank icon. Mirrors the mon icon
-- provider for the item icon manifest shape (one atlas rectangle per key).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemCache = require("libs.assets.src.ItemCache")

---@class ItemIconAssetProvider
---@field _graphics love.Graphics|love.graphics
---@field _manifest table<string, unknown>
---@field _image love.Image?
---@field _quads table<string, love.Quad>
---@field _released boolean
local ItemIconAssetProvider = {}
ItemIconAssetProvider.__index = ItemIconAssetProvider

---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(ItemCache.iconManifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.ITEM_ICON_MANIFEST_UNAVAILABLE,
      "no compiled item icon manifest at " .. ItemCache.iconManifestPath(),
      { path = ItemCache.iconManifestPath() }
    )
  end
  local ok, err = pcall(ItemAssetSchema.assertIconManifest, manifest)
  if not ok then
    Errors.raise(
      FieldErrors.ITEM_ICON_MANIFEST_UNAVAILABLE,
      "the compiled item icon manifest is invalid: " .. tostring(err),
      { path = ItemCache.iconManifestPath() }
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
    Errors.raise(FieldErrors.ITEM_ICON_UNKNOWN_KEY, "unknown item icon key " .. iconKey, { iconKey = iconKey })
  end
  assert(entry ~= nil, "the manifest carries the resolved entry")
  return entry
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.Graphics|love.graphics }?
---@return ItemIconAssetProvider
function ItemIconAssetProvider.new(cacheFs, opts)
  assert(cacheFs ~= nil, "ItemIconAssetProvider requires a CacheFs")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "ItemIconAssetProvider requires love.graphics")
  local manifest = loadManifest(cacheFs)
  local data = cacheFs:read(ItemCache.iconImagePath())
  if not data then
    Errors.raise(
      FieldErrors.ITEM_ICON_ATLAS_MISSING,
      "item icon atlas missing at " .. ItemCache.iconImagePath(),
      { path = ItemCache.iconImagePath() }
    )
  end
  local self = setmetatable({
    _graphics = graphics,
    _manifest = manifest,
    _image = nil,
    _quads = {},
    _released = false,
  }, ItemIconAssetProvider)
  local imageData = assert(data, "the icon atlas bytes are required")
  local ok, err = pcall(function()
    self._image = graphics.newImage(love.filesystem.newFileData(imageData, ItemCache.iconImagePath()))
    self._image:setFilter("nearest", "nearest")
    local imageWidth, imageHeight = self._image:getWidth(), self._image:getHeight()
    for selector, entry in pairs(manifest.entries) do
      assert(
        entry.x + entry.width <= imageWidth and entry.y + entry.height <= imageHeight,
        "icon frame for " .. selector .. " exceeds the atlas"
      )
    end
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

---@return love.Image the shared atlas image for draw calls
function ItemIconAssetProvider:image()
  return assert(self._image, "the icon atlas is loaded")
end

---@param iconKey string
---@return love.Quad quad
function ItemIconAssetProvider:quadFor(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  local quad = self._quads[iconKey]
  if quad == nil then
    local image = assert(self._image, "the icon atlas is loaded")
    quad = self._graphics.newQuad(entry.x, entry.y, entry.width, entry.height, image:getWidth(), image:getHeight())
    self._quads[iconKey] = quad
  end
  return quad
end

---@param iconKey string
---@return { width: integer, height: integer }
function ItemIconAssetProvider:dimensions(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return { width = entry.width, height = entry.height }
end

-- Releases the atlas image exactly once; quads reference no resources of
-- their own, so dropping the cache is sufficient. Safe to call repeatedly.
function ItemIconAssetProvider:release()
  local image = self._image
  self._image = nil
  self._quads = {}
  self._released = true
  if image ~= nil and image.release then
    image:release()
  end
end

return ItemIconAssetProvider
