-- Persists compiled mon artifacts through the shared staged publication
-- primitive, one stage per level: the semantic catalog, the selector layout
-- manifests, one bounded page image at a time, and the family summary. Each
-- stage is written into a disposable staging root, read back and validated
-- there (schemas, pixel sizes, image dimensions, and page coverage), and
-- only then published with its marker last. A failure at any point leaves
-- the previous live output untouched; the stage is discarded. The raw ROM
-- dump and any other derived class are never touched. Page buffers live
-- only through their own staging; no whole-corpus pixel array is retained.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local MonCache = require("libs.assets.src.MonCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Hashing = require("romdump.src.digest.Hashing")

---@class MonCacheWriter
local MonCacheWriter = {}

---@class MonFamilyIndex
---@field schema string
---@field version { id: string, language: string }
---@field catalogHash string 40-character hex digest of the semantic catalog
---@field catalog string cache-relative catalog path
---@field iconManifest string cache-relative icon manifest path
---@field portraitManifest string cache-relative portrait manifest path
---@field iconPages string[] one marker per icon page in ascending page order
---@field portraitPages string[] one marker per portrait page in ascending page order

function MonCacheWriter.isReady(cacheFs, marker)
  return MonCache.isReady(cacheFs, marker)
end

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

-- Deterministic pre-pixel markers: the catalog marker binds the semantic
-- catalog, the layout marker binds both selector manifests, and each page
-- marker binds its kind, page id, and layout manifest. Pixel bytes stay
-- page-owned; markers bind the layout that staged them.
---@param romSha1 string
---@param catalog table<string, unknown>
---@return string
function MonCacheWriter.catalogMarker(romSha1, catalog)
  return MonCache.marker(romSha1, Hashing.hashLua(catalog))
end

---@param romSha1 string
---@param icons table<string, unknown> planned icon manifest
---@param portraits table<string, unknown> planned portrait manifest
---@return string
function MonCacheWriter.layoutMarker(romSha1, icons, portraits)
  return MonCache.marker(romSha1, Hashing.hashLua({ icons = icons, portraits = portraits }))
end

---@param romSha1 string
---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param manifest table<string, unknown> planned manifest of the page kind
---@return string
function MonCacheWriter.pageMarker(romSha1, kind, pageId, manifest)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  return MonCache.marker(romSha1, Hashing.hashLua({ kind = kind, pageId = pageId, manifest = manifest }))
end

---@param version { id: string, language: string }
---@param catalogHash string
---@param iconPageMarkers string[]
---@param portraitPageMarkers string[]
---@return MonFamilyIndex
function MonCacheWriter.buildIndex(version, catalogHash, iconPageMarkers, portraitPageMarkers)
  local index = {
    schema = MonCache.INDEX_SCHEMA,
    version = version,
    catalogHash = catalogHash,
    catalog = MonCache.catalogPath(),
    iconManifest = MonCache.iconManifestPath(),
    portraitManifest = MonCache.portraitManifestPath(),
    iconPages = iconPageMarkers,
    portraitPages = portraitPageMarkers,
  }
  MonAssetSchema.assertIndex(index)
  return index
end

-- The deterministic completion marker for one covered family: the page
-- markers already bind each page's layout identity, so the summary binds
-- the index selection to those markers. The ROM identity is carried by the
-- page markers themselves.
---@param index MonFamilyIndex
---@return string
function MonCacheWriter.summaryMarker(index)
  MonAssetSchema.assertIndex(index)
  local firstMarker = index.iconPages[1]
  assert(type(firstMarker) == "string", "family index carries no icon page marker")
  local romSha1 = firstMarker:match("^[^:]+:([^:]+):.+$")
  assert(type(romSha1) == "string", "page markers carry no ROM identity")
  return MonCache.marker(romSha1, Hashing.hashLua(index))
end

---@param marker unknown
---@param what string
local function checkMarker(marker, what)
  if type(marker) ~= "string" or marker == "" then
    fail("MON_WRITER_BAD_MARKER", what .. " marker must be a non-empty string", {})
  end
end

local function persistCatalog(stage, catalog, marker)
  MonAssetSchema.assertCatalog(catalog)
  checkMarker(marker, "catalog")
  stage:writeLua(MonCache.catalogPath(), catalog)
  stage:write(MonCache.catalogMarkerPath(), marker)
  local readCatalog = stage:loadLua(MonCache.catalogPath())
  MonAssetSchema.assertCatalog(readCatalog)
  if stage:read(MonCache.catalogMarkerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "catalog marker readback failed", {})
  end
  return marker
end

-- Stage the semantic catalog through a caller-owned prepared artifact: the
-- stage owns exactly the catalog payload and its marker, so no pixel
-- payload is touched. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param args { catalog: table<string, unknown>, marker: string }
---@return string
function MonCacheWriter.stageCatalog(artifact, args)
  assert(artifact and artifact.stageFs, "catalog staging requires a PreparedArtifact")
  assert(type(args) == "table", "catalog staging requires its catalog and marker")
  artifact:addOwnedRoot(MonCache.catalogPath())
  artifact:addOwnedRoot(MonCache.catalogMarkerPath())
  return persistCatalog(artifact:stageFs(), args.catalog, args.marker)
end

function MonCacheWriter.writeCatalog(cacheFs, catalog, marker)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-catalog", {
    MonCache.catalogPath(),
    MonCache.catalogMarkerPath(),
  })
  local ok, result = pcall(persistCatalog, tx.stage, catalog, marker)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

local function persistLayout(stage, icons, portraits, marker)
  MonAssetSchema.assertIconManifest(icons)
  MonAssetSchema.assertPortraitManifest(portraits)
  checkMarker(marker, "layout")
  stage:writeLua(MonCache.iconManifestPath(), icons)
  stage:writeLua(MonCache.portraitManifestPath(), portraits)
  stage:write(MonCache.layoutMarkerPath(), marker)
  local readIcons = stage:loadLua(MonCache.iconManifestPath())
  MonAssetSchema.assertIconManifest(readIcons)
  local readPortraits = stage:loadLua(MonCache.portraitManifestPath())
  MonAssetSchema.assertPortraitManifest(readPortraits)
  if stage:read(MonCache.layoutMarkerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "layout marker readback failed", {})
  end
  return marker
end

-- Stage the selector layout through a caller-owned prepared artifact: the
-- stage owns exactly the two normalized manifests and the layout marker.
-- Normalized manifests list every selector even when no page image is
-- staged yet. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param args { icons: table<string, unknown>, portraits: table<string, unknown>, marker: string }
---@return string
function MonCacheWriter.stageLayout(artifact, args)
  assert(artifact and artifact.stageFs, "layout staging requires a PreparedArtifact")
  assert(type(args) == "table", "layout staging requires its manifests and marker")
  artifact:addOwnedRoot(MonCache.iconManifestPath())
  artifact:addOwnedRoot(MonCache.portraitManifestPath())
  artifact:addOwnedRoot(MonCache.layoutMarkerPath())
  return persistLayout(artifact:stageFs(), args.icons, args.portraits, args.marker)
end

function MonCacheWriter.writeLayout(cacheFs, icons, portraits, marker)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-layout", {
    MonCache.iconManifestPath(),
    MonCache.portraitManifestPath(),
    MonCache.layoutMarkerPath(),
  })
  local ok, result = pcall(persistLayout, tx.stage, icons, portraits, marker)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

---@param bundle unknown
---@return { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }
local function checkPageBundle(bundle)
  if type(bundle) ~= "table" then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle must be a record", {})
  end
  ---@cast bundle table<string, unknown>
  if bundle.kind ~= "icons" and bundle.kind ~= "portraits" then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle kind must be icons or portraits", {})
  end
  if type(bundle.pageId) ~= "number" or bundle.pageId % 1 ~= 0 or bundle.pageId < 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle pageId must be a non-negative integer", {})
  end
  if type(bundle.width) ~= "number" or bundle.width % 1 ~= 0 or bundle.width <= 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle width must be positive", {})
  end
  if type(bundle.height) ~= "number" or bundle.height % 1 ~= 0 or bundle.height <= 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle height must be positive", {})
  end
  if type(bundle.pixels) ~= "string" or #bundle.pixels ~= bundle.width * bundle.height * 4 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle pixels must be width*height*4 bytes", {})
  end
  checkMarker(bundle.marker, "page")
  return bundle --[[@as { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }]]
end

-- Read one PNG's IHDR dimensions back without a PNG decoder: signature plus
-- the width/height words must match the staged image.
local function probePngDimensions(png, context)
  if #png < 33 or png:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page is not a PNG", context)
  end
  if png:sub(13, 16) ~= "IHDR" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page has no IHDR", context)
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

local function persistPage(stage, bundle)
  local owned = checkPageBundle(bundle)
  local png = PngWriter.encode(owned.width, owned.height, owned.pixels)
  stage:write(MonCache.pageImagePath(owned.kind, owned.pageId), png)
  stage:write(MonCache.pageMarkerPath(owned.kind, owned.pageId), owned.marker)
  local width, height = probePngDimensions(assert(stage:read(MonCache.pageImagePath(owned.kind, owned.pageId))), {})
  if width ~= owned.width or height ~= owned.height then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page dimensions mismatch", {})
  end
  if stage:read(MonCache.pageMarkerPath(owned.kind, owned.pageId)) ~= owned.marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "page marker readback failed", {})
  end
  return owned.marker
end

-- Stage one compiled page through a caller-owned prepared artifact: the
-- stage owns exactly this page's image and marker, so per-page jobs never
-- overlap and no page buffer survives staging. Publication stays with the
-- caller; a stage failure leaves the previous live page untouched once the
-- caller aborts the disposable stage.
---@param artifact PreparedArtifact
---@param bundle { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }
---@return string
function MonCacheWriter.stagePage(artifact, bundle)
  assert(artifact and artifact.stageFs, "page staging requires a PreparedArtifact")
  local owned = checkPageBundle(bundle)
  artifact:addOwnedRoot(MonCache.pageImagePath(owned.kind, owned.pageId))
  artifact:addOwnedRoot(MonCache.pageMarkerPath(owned.kind, owned.pageId))
  return persistPage(artifact:stageFs(), owned)
end

function MonCacheWriter.writePage(cacheFs, bundle)
  local owned = checkPageBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-page", {
    MonCache.pageImagePath(owned.kind, owned.pageId),
    MonCache.pageMarkerPath(owned.kind, owned.pageId),
  })
  local ok, result = pcall(persistPage, tx.stage, owned)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- The one staging step every summary entry point shares: prove every page
-- the index declares is ready in the live cache under its indexed marker,
-- then write only the index, the provenance, and the completion marker into
-- the stage. Page images are never staged here, so the summary cannot erase
-- independently published pages.
local function persistSummary(stage, liveFs, index, provenance)
  MonAssetSchema.assertIndex(index)
  assert(type(provenance) == "table", "summary staging requires the family provenance")
  local missing = {}
  for position, marker in ipairs(index.iconPages) do
    if not MonCache.isPageReady(liveFs, "icons", position - 1, marker) then
      missing[#missing + 1] = "icons:" .. (position - 1)
    end
  end
  for position, marker in ipairs(index.portraitPages) do
    if not MonCache.isPageReady(liveFs, "portraits", position - 1, marker) then
      missing[#missing + 1] = "portraits:" .. (position - 1)
    end
  end
  if #missing > 0 then
    fail("MON_SUMMARY_INCOMPLETE", "family summary refuses incomplete page coverage", { missing = missing })
  end
  local marker = MonCacheWriter.summaryMarker(index)
  stage:writeLua(MonCache.indexPath(), index)
  stage:writeLua(MonCache.provenancePath(), provenance)
  stage:write(MonCache.markerPath(), marker)
  local readIndex = stage:loadLua(MonCache.indexPath())
  MonAssetSchema.assertIndex(readIndex)
  if stage:read(MonCache.markerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "summary marker readback failed", {})
  end
  return marker
end

-- Stage the family summary through a caller-owned prepared artifact: the
-- stage owns exactly the index, the provenance, and the completion marker,
-- never the page images. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param index MonFamilyIndex
---@param provenance table<string, unknown> family provenance record
---@return string
function MonCacheWriter.stageSummary(artifact, index, provenance)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "summary staging requires a PreparedArtifact")
  artifact:addOwnedRoot(MonCache.indexPath())
  artifact:addOwnedRoot(MonCache.provenancePath())
  artifact:addOwnedRoot(MonCache.markerPath())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), index, provenance)
end

function MonCacheWriter.writeSummary(cacheFs, index, provenance)
  local tx = ArtifactPublisher.begin(cacheFs, "mons", {
    MonCache.indexPath(),
    MonCache.provenancePath(),
    MonCache.markerPath(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, index, provenance)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return MonCacheWriter
