-- Readiness and paths for the derived item cache. The item class is one
-- independently rebuildable derived class (catalog plus the icon atlas and
-- manifest): changing the item compilers must not disturb the raw ROM dump
-- or any other compiled class. A class is ready only when the completion
-- marker matches exactly and the catalog, atlas, and manifest are present
-- with the expected index schema, so a partial build never reads as
-- complete. Paths are cache-relative; all IO goes through a CacheFs.

---@class ItemCache
local ItemCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")

ItemCache.FORMAT = Contract.items.cacheFormat
ItemCache.CATALOG_SCHEMA = Contract.items.catalogSchema
ItemCache.INDEX_SCHEMA = Contract.items.indexSchema
ItemCache.ICON_MANIFEST_SCHEMA = Contract.items.iconManifestSchema

ItemCache.POCKETS = ItemAssetSchema.POCKETS

local DATA_DIR = "data/generated/item"
local ASSET_DIR = "assets/generated/item"

function ItemCache.dir()
  return DATA_DIR
end
function ItemCache.assetDir()
  return ASSET_DIR
end
function ItemCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function ItemCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end
function ItemCache.iconManifestPath()
  return DATA_DIR .. "/icons.lua"
end
function ItemCache.iconImagePath()
  return ASSET_DIR .. "/icons.png"
end
function ItemCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function ItemCache.markerPath()
  return DATA_DIR .. "/complete"
end

function ItemCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", ItemCache.FORMAT, romSha1, depHash)
end

-- True only when the marker is exact, the index loads with the expected
-- schema, and every indexed artifact is present.
function ItemCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(ItemCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(ItemCache.indexPath())
  if not ItemAssetSchema.isValidIndex(index) then
    return false
  end
  if not cacheFs:exists(ItemCache.catalogPath(), "file") then
    return false
  end
  if not cacheFs:exists(ItemCache.iconManifestPath(), "file") then
    return false
  end
  if not cacheFs:exists(ItemCache.iconImagePath(), "file") then
    return false
  end
  return true
end

function ItemCache.loadIndex(cacheFs)
  local index = cacheFs:loadLua(ItemCache.indexPath())
  ItemAssetSchema.assertIndex(index)
  return index
end

function ItemCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(ItemCache.catalogPath())
  ItemAssetSchema.assertCatalog(catalog)
  return catalog
end

function ItemCache.loadIconManifest(cacheFs)
  local manifest = cacheFs:loadLua(ItemCache.iconManifestPath())
  ItemAssetSchema.assertIconManifest(manifest)
  return manifest
end

return ItemCache
