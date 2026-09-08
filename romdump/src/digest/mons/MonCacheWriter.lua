-- Persists a compiled mon bundle through the shared staged publication
-- primitive: the catalog, index, icon/portrait manifests and atlases, and
-- provenance are written into a disposable staging root, read back and
-- validated there (schemas, content hashes, image dimensions, and
-- catalog-to-manifest selector resolution), and only then is the completed
-- stage published over the live mon roots with the marker last. A failure
-- at any point leaves the previous live class untouched; the stage is
-- discarded. The raw ROM dump and any other derived class are never touched.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local MonCache = require("libs.assets.src.MonCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Hashing = require("romdump.src.digest.Hashing")

---@class MonCacheWriter
local MonCacheWriter = {}

function MonCacheWriter.isReady(cacheFs, marker)
  return MonCache.isReady(cacheFs, marker)
end

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

local function checkImage(image, context, code, field)
  if type(image) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if type(image.width) ~= "number" or image.width % 1 ~= 0 or image.width <= 0 then
    fail(code, field .. " width must be positive", context)
  end
  if type(image.height) ~= "number" or image.height % 1 ~= 0 or image.height <= 0 then
    fail(code, field .. " height must be positive", context)
  end
  if type(image.pixels) ~= "string" or #image.pixels ~= image.width * image.height * 4 then
    fail(code, field .. " pixels must be width*height*4 bytes", context)
  end
end

local function checkRectsInBounds(manifest, image, context, code, field)
  for selector, entry in pairs(manifest.entries) do
    for _, frame in ipairs(entry.frames) do
      if frame.x + frame.width > image.width or frame.y + frame.height > image.height then
        fail(code, field .. " entry " .. selector .. " escapes the atlas", context)
      end
    end
  end
end

local function checkSelectorsResolve(catalog, icons, portraits, context)
  for _, species in pairs(catalog.species) do
    for _, form in pairs(species.forms) do
      if icons.entries[form.icon] == nil then
        fail("MON_WRITER_UNRESOLVED_SELECTOR", "icon selector has no manifest entry: " .. form.icon, context)
      end
      if portraits.entries[form.portrait] == nil then
        fail("MON_WRITER_UNRESOLVED_SELECTOR", "portrait selector has no entry: " .. form.portrait, context)
      end
    end
  end
end

local function checkBundle(bundle)
  if type(bundle) ~= "table" then
    fail("MON_WRITER_BAD_BUNDLE", "mon bundle must be a record", {})
  end
  if type(bundle.marker) ~= "string" or bundle.marker == "" then
    fail("MON_WRITER_BAD_BUNDLE", "mon bundle marker must be a non-empty string", {})
  end
  for _, field in ipairs({ "index", "catalog", "icons", "iconManifest", "portraits", "portraitManifest", "provenance" }) do
    if type(bundle[field]) ~= "table" then
      fail("MON_WRITER_BAD_BUNDLE", "mon bundle field " .. field .. " must be a record", {})
    end
  end
  MonAssetSchema.assertCatalog(bundle.catalog)
  MonAssetSchema.assertIndex(bundle.index)
  MonAssetSchema.assertIconManifest(bundle.iconManifest)
  MonAssetSchema.assertPortraitManifest(bundle.portraitManifest)
  if bundle.index.catalog ~= MonCache.catalogPath() then
    fail("MON_WRITER_BAD_INDEX", "index catalog path does not match MonCache", {})
  end
  if bundle.index.icons ~= MonCache.iconImagePath() or bundle.index.iconManifest ~= MonCache.iconManifestPath() then
    fail("MON_WRITER_BAD_INDEX", "index icon paths do not match MonCache", {})
  end
  if
    bundle.index.portraits ~= MonCache.portraitImagePath()
    or bundle.index.portraitManifest ~= MonCache.portraitManifestPath()
  then
    fail("MON_WRITER_BAD_INDEX", "index portrait paths do not match MonCache", {})
  end
  if bundle.index.catalogHash ~= Hashing.hashLua(bundle.catalog) then
    fail("MON_WRITER_HASH_MISMATCH", "index catalog hash does not match the catalog", {})
  end
  checkImage(bundle.icons, {}, "MON_WRITER_BAD_IMAGE", "icons")
  checkImage(bundle.portraits, {}, "MON_WRITER_BAD_IMAGE", "portraits")
  local iconPng = PngWriter.encode(bundle.icons.width, bundle.icons.height, bundle.icons.pixels)
  if Hashing.sha1hex(iconPng) ~= bundle.index.iconHash then
    fail("MON_WRITER_HASH_MISMATCH", "index icon hash does not match the atlas", {})
  end
  local portraitPng = PngWriter.encode(bundle.portraits.width, bundle.portraits.height, bundle.portraits.pixels)
  if Hashing.sha1hex(portraitPng) ~= bundle.index.portraitHash then
    fail("MON_WRITER_HASH_MISMATCH", "index portrait hash does not match the atlas", {})
  end
  checkRectsInBounds(bundle.iconManifest, bundle.icons, {}, "MON_WRITER_RECT_OUT_OF_BOUNDS", "icon")
  checkRectsInBounds(bundle.portraitManifest, bundle.portraits, {}, "MON_WRITER_RECT_OUT_OF_BOUNDS", "portrait")
  checkSelectorsResolve(bundle.catalog, bundle.iconManifest, bundle.portraitManifest, {})
  return iconPng, portraitPng
end

-- Read one PNG's IHDR dimensions back without a PNG decoder: signature plus
-- the width/height words must match the staged image.
local function probePngDimensions(png, context)
  if #png < 33 or png:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged atlas is not a PNG", context)
  end
  if png:sub(13, 16) ~= "IHDR" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged atlas has no IHDR", context)
  end
  local width = 0
  for i = 17, 20 do
    width = width * 256 + string.byte(png, i)
  end
  local height = 0
  for i = 21, 24 do
    height = height * 256 + string.byte(png, i)
  end
  return width, height
end

local function persist(tx, bundle, iconPng, portraitPng)
  local stage = tx.stage
  stage:writeLua(MonCache.catalogPath(), bundle.catalog)
  stage:writeLua(MonCache.indexPath(), bundle.index)
  stage:writeLua(MonCache.iconManifestPath(), bundle.iconManifest)
  stage:writeLua(MonCache.portraitManifestPath(), bundle.portraitManifest)
  stage:write(MonCache.iconImagePath(), iconPng)
  stage:write(MonCache.portraitImagePath(), portraitPng)
  stage:writeLua(MonCache.provenancePath(), bundle.provenance)

  local catalog = stage:loadLua(MonCache.catalogPath())
  MonAssetSchema.assertCatalog(catalog)
  local index = stage:loadLua(MonCache.indexPath())
  MonAssetSchema.assertIndex(index)
  local iconManifest = stage:loadLua(MonCache.iconManifestPath())
  MonAssetSchema.assertIconManifest(iconManifest)
  local portraitManifest = stage:loadLua(MonCache.portraitManifestPath())
  MonAssetSchema.assertPortraitManifest(portraitManifest)
  checkSelectorsResolve(catalog, iconManifest, portraitManifest, {})
  local iconWidth, iconHeight = probePngDimensions(assert(stage:read(MonCache.iconImagePath())), {})
  if iconWidth ~= bundle.icons.width or iconHeight ~= bundle.icons.height then
    fail("MON_WRITER_PNG_UNREADABLE", "staged icon atlas dimensions mismatch", {})
  end
  local portraitWidth, portraitHeight = probePngDimensions(assert(stage:read(MonCache.portraitImagePath())), {})
  if portraitWidth ~= bundle.portraits.width or portraitHeight ~= bundle.portraits.height then
    fail("MON_WRITER_PNG_UNREADABLE", "staged portrait atlas dimensions mismatch", {})
  end

  stage:write(MonCache.markerPath(), bundle.marker)
  return bundle.marker
end

function MonCacheWriter.write(cacheFs, bundle)
  local iconPng, portraitPng = checkBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "mons", {
    MonCache.assetDir(),
    MonCache.dir(),
  })
  local ok, result = pcall(persist, tx, bundle, iconPng, portraitPng)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return MonCacheWriter
