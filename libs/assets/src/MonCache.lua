-- Readiness and paths for the derived mon cache. The mons class is one
-- independently rebuildable derived class: a coarse semantic catalog, one
-- selector layout manifest per presentation kind, one bounded atlas page
-- image per declared page, and a summary index binding them. Changing the
-- mon compilers must not disturb the raw ROM dump or any other compiled
-- class. The catalog, the layout, the icon set, one page, and the whole
-- family report readiness separately: a partial page set never reads as a
-- complete family, and layout presence alone never reads as page readiness.
-- Paths are cache-relative; all IO goes through a CacheFs. Following-mon
-- drawable definitions live in FieldActorCache, never here: the catalog
-- references field-actor visual IDs only.

---@class MonCache
local MonCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")

MonCache.FORMAT = Contract.mons.cacheFormat
MonCache.CATALOG_SCHEMA = Contract.mons.catalogSchema
MonCache.INDEX_SCHEMA = Contract.mons.indexSchema
MonCache.ICON_MANIFEST_SCHEMA = Contract.mons.iconManifestSchema
MonCache.PORTRAIT_MANIFEST_SCHEMA = Contract.mons.portraitManifestSchema

local DATA_DIR = "data/generated/mon"
local ASSET_DIR = "assets/generated/mon"

function MonCache.dir()
  return DATA_DIR
end
function MonCache.assetDir()
  return ASSET_DIR
end
function MonCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function MonCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end
function MonCache.iconManifestPath()
  return DATA_DIR .. "/icons.lua"
end
function MonCache.portraitManifestPath()
  return DATA_DIR .. "/portraits.lua"
end
function MonCache.iconImagePath()
  return ASSET_DIR .. "/icons.png"
end
function MonCache.portraitImagePath()
  return ASSET_DIR .. "/portraits.png"
end
-- The retired whole-atlas paths above name no staged output: page images
-- below are the only presentation pixels, and no reader falls back to the
-- global paths.

---@param pageId integer zero-based page identity
---@return integer the checked page identity
local function checkPageId(pageId)
  assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "mon page id must be a non-negative integer")
  return pageId
end

---@param pageId integer zero-based icon page identity
---@return string cache-relative page image path
function MonCache.iconPagePath(pageId)
  return ASSET_DIR .. "/icons/" .. checkPageId(pageId) .. ".png"
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative page image path
function MonCache.portraitPagePath(pageId)
  return ASSET_DIR .. "/portraits/" .. checkPageId(pageId) .. ".png"
end

---@return string cache-relative catalog completion marker path
function MonCache.catalogMarkerPath()
  return DATA_DIR .. "/catalog.complete"
end

---@return string cache-relative layout completion marker path
function MonCache.layoutMarkerPath()
  return DATA_DIR .. "/layout.complete"
end

---@param pageId integer zero-based icon page identity
---@return string cache-relative icon page marker path
function MonCache.iconPageMarkerPath(pageId)
  return DATA_DIR .. "/icon-pages/" .. checkPageId(pageId) .. ".complete"
end

---@param pageId integer zero-based portrait page identity
---@return string cache-relative portrait page marker path
function MonCache.portraitPageMarkerPath(pageId)
  return DATA_DIR .. "/portrait-pages/" .. checkPageId(pageId) .. ".complete"
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@return string cache-relative page marker path
function MonCache.pageMarkerPath(kind, pageId)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if kind == "icons" then
    return MonCache.iconPageMarkerPath(pageId)
  end
  return MonCache.portraitPageMarkerPath(pageId)
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@return string cache-relative page image path
function MonCache.pageImagePath(kind, pageId)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if kind == "icons" then
    return MonCache.iconPagePath(pageId)
  end
  return MonCache.portraitPagePath(pageId)
end
function MonCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function MonCache.markerPath()
  return DATA_DIR .. "/complete"
end

function MonCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", MonCache.FORMAT, romSha1, depHash)
end

-- Canonical presentation selectors. Icon variants cover the default form
-- icon plus the egg icon; portrait variants cover gender and shininess for
-- every form. Consumers build selectors only through these constructors so a
-- catalog selection and its manifest entry can never disagree on spelling.
function MonCache.iconSelector(speciesKey, form, isEgg)
  assert(type(speciesKey) == "string" and speciesKey ~= "", "icon selector requires a species key")
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "icon selector requires a form")
  if isEgg then
    return speciesKey .. "/egg"
  end
  return speciesKey .. "/f" .. form
end

function MonCache.portraitSelector(speciesKey, form, gender, shiny)
  assert(type(speciesKey) == "string" and speciesKey ~= "", "portrait selector requires a species key")
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "portrait selector requires a form")
  assert(gender == "male" or gender == "female", "portrait selector requires a gender")
  if shiny then
    return speciesKey .. "/f" .. form .. "/" .. gender .. "/shiny"
  end
  return speciesKey .. "/f" .. form .. "/" .. gender .. "/plain"
end

-- True only when the catalog stage marker is exact and the catalog payload
-- is present. Pixel or page stages never satisfy this on their own.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isCatalogReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.catalogMarkerPath()) ~= expectedMarker then
    return false
  end
  return cacheFs:exists(MonCache.catalogPath(), "file")
end

-- True only when the layout stage marker is exact and both selector
-- manifests are present. Manifest presence alone never reads as page
-- readiness.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isLayoutReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.layoutMarkerPath()) ~= expectedMarker then
    return false
  end
  if not cacheFs:exists(MonCache.iconManifestPath(), "file") then
    return false
  end
  return cacheFs:exists(MonCache.portraitManifestPath(), "file")
end

-- Minimum structural envelope for a standalone page PNG (W3C PNG file
-- structure and chunks): signature, one IHDR, at least one IDAT byte, and
-- a terminal IEND with nothing after it. This rejects empty and truncated
-- bodies without decoding pixels or allocating host image resources.
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local MAX_PNG_DIMENSION = 2147483647

---@param bytes string
---@param position integer 1-based offset of a 4-byte big-endian length
---@return integer
local function readU32(bytes, position)
  local a, b, c, d = string.byte(bytes, position, position + 3)
  assert(a ~= nil and b ~= nil and c ~= nil and d ~= nil, "chunk header must be present")
  return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param bytes string?
---@return boolean
local function isPngEnvelope(bytes)
  if type(bytes) ~= "string" then
    return false
  end
  if #bytes < 8 or bytes:sub(1, 8) ~= PNG_SIGNATURE then
    return false
  end
  local cursor = 9
  if cursor + 8 - 1 > #bytes then
    return false
  end
  if bytes:sub(cursor + 4, cursor + 7) ~= "IHDR" then
    return false
  end
  if readU32(bytes, cursor) ~= 13 then
    return false
  end
  if cursor + 8 + 13 + 4 - 1 > #bytes then
    return false
  end
  local width = readU32(bytes, cursor + 8)
  local height = readU32(bytes, cursor + 12)
  if width < 1 or height < 1 or width > MAX_PNG_DIMENSION or height > MAX_PNG_DIMENSION then
    return false
  end
  cursor = cursor + 8 + 13 + 4
  local seenIdat = false
  local idatTotal = 0
  while true do
    if cursor + 8 - 1 > #bytes then
      return false
    end
    local length = readU32(bytes, cursor)
    local chunkType = bytes:sub(cursor + 4, cursor + 7)
    if length > MAX_PNG_DIMENSION then
      return false
    end
    if cursor + 8 + length + 4 - 1 > #bytes then
      return false
    end
    if chunkType == "IHDR" then
      return false
    elseif chunkType == "IDAT" then
      seenIdat = true
      idatTotal = idatTotal + length
    elseif chunkType == "IEND" then
      if length ~= 0 then
        return false
      end
      if not seenIdat or idatTotal <= 0 then
        return false
      end
      return cursor + 8 + length + 4 - 1 == #bytes
    end
    cursor = cursor + 8 + length + 4
  end
end

-- True only when one page's marker is exact and its page image carries a
-- complete PNG envelope.
---@param cacheFs CacheFs
---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param expectedMarker string
---@return boolean
function MonCache.isPageReady(cacheFs, kind, pageId, expectedMarker)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  if cacheFs:read(MonCache.pageMarkerPath(kind, pageId)) ~= expectedMarker then
    return false
  end
  return isPngEnvelope(cacheFs:read(MonCache.pageImagePath(kind, pageId)))
end

-- True only when the layout manifest is loadable and every icon page it
-- declares is ready under its expected marker. Portrait coverage is never
-- required here: the icon set covers party-demanded pages without the portraits.
---@param cacheFs CacheFs
---@param expectedMarkers table<integer, string> expected marker by zero-based page id
---@return boolean
function MonCache.isIconSetReady(cacheFs, expectedMarkers)
  if type(expectedMarkers) ~= "table" then
    return false
  end
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  if not MonAssetSchema.isValidIconManifest(manifest) then
    return false
  end
  assert(manifest ~= nil, "the icon manifest carries its page inventory")
  for _, pageId in ipairs(manifest.pageIds) do
    if not MonCache.isPageReady(cacheFs, "icons", pageId, expectedMarkers[pageId]) then
      return false
    end
  end
  return true
end

-- True only when the summary marker is exact, the page-inventory index
-- loads with the expected schema, the catalog and both manifests are
-- present, and every page the index declares is ready under its indexed
-- marker. Any partial page set reads as incomplete.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function MonCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(MonCache.indexPath())
  if not MonAssetSchema.isValidIndex(index) then
    return false
  end
  assert(index ~= nil, "the mon index carries its page inventory")
  if not cacheFs:exists(MonCache.catalogPath(), "file") then
    return false
  end
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  if not MonAssetSchema.isValidIconManifest(icons) then
    return false
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if not MonAssetSchema.isValidPortraitManifest(portraits) then
    return false
  end
  assert(icons ~= nil and portraits ~= nil, "the mon manifests carry their page inventories")
  if #index.iconPages ~= #icons.pageIds or #index.portraitPages ~= #portraits.pageIds then
    return false
  end
  for position, marker in ipairs(index.iconPages) do
    if not MonCache.isPageReady(cacheFs, "icons", position - 1, marker) then
      return false
    end
  end
  for position, marker in ipairs(index.portraitPages) do
    if not MonCache.isPageReady(cacheFs, "portraits", position - 1, marker) then
      return false
    end
  end
  return true
end

function MonCache.loadIndex(cacheFs)
  local index = cacheFs:loadLua(MonCache.indexPath())
  MonAssetSchema.assertIndex(index)
  return index
end

function MonCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(MonCache.catalogPath())
  MonAssetSchema.assertCatalog(catalog)
  return catalog
end

return MonCache
