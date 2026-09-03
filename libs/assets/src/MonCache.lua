-- Readiness and paths for the derived mon cache. The mons class is one
-- independently rebuildable derived class (catalog plus icon/portrait
-- atlases and manifests): changing the mon compilers must not disturb the
-- raw ROM dump or any other compiled class. A class is ready only when the
-- completion marker matches exactly and the catalog, both atlases, and both
-- manifests are present with the expected index schema, so a partial build
-- never reads as complete. Paths are cache-relative; all IO goes through a
-- CacheFs. Following-mon drawable definitions live in FieldActorCache, never
-- here: the catalog references field-actor visual IDs only.

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

-- True only when the marker is exact, the index loads with the expected
-- schema, and every indexed artifact is present.
function MonCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MonCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(MonCache.indexPath())
  if not MonAssetSchema.isValidIndex(index) then
    return false
  end
  if not cacheFs:exists(MonCache.catalogPath(), "file") then
    return false
  end
  if not cacheFs:exists(MonCache.iconManifestPath(), "file") then
    return false
  end
  if not cacheFs:exists(MonCache.portraitManifestPath(), "file") then
    return false
  end
  if not cacheFs:exists(MonCache.iconImagePath(), "file") then
    return false
  end
  if not cacheFs:exists(MonCache.portraitImagePath(), "file") then
    return false
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
