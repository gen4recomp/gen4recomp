-- Readiness and paths for the derived field-bag presentation cache. The bag
-- class is one independently rebuildable derived class (manifest, pane and
-- sprite images, registration markers, semantic text, hero models with
-- pocket-indexed animation states): changing
-- the bag compilers must not disturb the raw ROM dump or any other compiled
-- class. A class is ready only when the completion marker matches exactly
-- and the manifest plus every referenced artifact is present with the
-- expected schema, so a partial build never reads as complete. Item icons
-- stay in the item class; the bag manifest references no icon pixels.
-- Paths are cache-relative; all IO goes through a CacheFs.

---@class BagCache
local BagCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

BagCache.FORMAT = Contract.bag.cacheFormat
BagCache.SCHEMA = Contract.bag.schema

local DATA_DIR = "data/generated/bag"
local ASSET_DIR = "assets/generated/bag"

function BagCache.dir()
  return DATA_DIR
end
function BagCache.assetDir()
  return ASSET_DIR
end
function BagCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end
function BagCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function BagCache.markerPath()
  return DATA_DIR .. "/complete"
end

function BagCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", BagCache.FORMAT, romSha1, depHash)
end

-- Every cache-relative path the manifest references: pane/sprite images
-- plus each hero model's geometry and textures.
---@param manifest table<string, unknown>
---@return string[]
function BagCache.referencedPaths(manifest)
  BagAssetSchema.assertManifest(manifest)
  local paths = {}
  local function addVisual(visual)
    assert(type(visual) == "table", "bag manifest visual is malformed")
    assert(type(visual.image) == "string", "bag manifest visual carries one realized image")
    paths[#paths + 1] = visual.image
  end
  local function addImage(ref)
    assert(type(ref) == "table" and type(ref.image) == "string", "bag manifest image reference is malformed")
    paths[#paths + 1] = ref.image
  end
  local hero = manifest.hero
  addImage(hero.background.male)
  addImage(hero.background.female)
  paths[#paths + 1] = hero.description.frame.image
  paths[#paths + 1] = hero.description.frame.alternateImage
  for _, gender in ipairs({ "male", "female" }) do
    for _, path in ipairs(ModelAsset.referencedPaths(hero.model[gender])) do
      paths[#paths + 1] = path
    end
  end
  local interactive = manifest.interactive
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    addVisual(interactive.backgrounds[state])
  end
  for _, visual in ipairs(interactive.pocketTabs.normal) do
    addVisual(visual)
  end
  addVisual(interactive.pocketTabs.selected)
  addVisual(interactive.itemSlots.focus)
  addVisual(interactive.widgets.sourceStrip)
  addImage(interactive.itemSlots.registration.slot1)
  addImage(interactive.itemSlots.registration.slot2)
  return paths
end

-- True only when the marker is exact, the manifest loads with the expected
-- schema, and every referenced artifact is present.
function BagCache.isReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(BagCache.markerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #BagCache.FORMAT + 1) ~= BagCache.FORMAT .. ":"
  then
    return false
  end
  local manifest = cacheFs:loadLua(BagCache.manifestPath())
  if not BagAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(BagCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= BagCache.FORMAT
    or provenance.schema ~= BagCache.SCHEMA
  then
    return false
  end
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  if not ok then
    return false
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

function BagCache.validateManifest(manifest)
  return BagAssetSchema.assertManifest(manifest)
end

function BagCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(BagCache.manifestPath())
  BagAssetSchema.assertManifest(manifest)
  return manifest
end

return BagCache
