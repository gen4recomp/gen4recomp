-- ROM-conformance test: identical raw dump and producer tree produce
-- byte-identical mon class output across two independent staging roots.
-- The semantic catalog and selector layout stage first without pixels, then
-- each page compiles and stages from its own source records; the summary
-- binds the covered family.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function sortedKeys(files)
  local keys = {}
  for key in pairs(files) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- One full streaming build into the given backend: catalog, layout, every
-- page, then the summary. Only one page buffer is live at a time; the
-- returned summary marker binds the covered family.
local function buildClass(romFs, versionId, backend)
  local Hashing = require("romdump.src.digest.Hashing")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local MonSources = require("romdump.src.config.MonSources")
  local cache = CacheFs.forVersion(versionId, backend)
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local romSha1 = romFs:metadata().sha1
  local catalogMarker = MonCacheWriter.catalogMarker(romSha1, catalog)
  MonCacheWriter.writeCatalog(cache, catalog, catalogMarker)
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  local layoutMarker = MonCacheWriter.layoutMarker(romSha1, planned.icons, planned.portraits)
  MonCacheWriter.writeLayout(
    cache,
    planned.icons,
    planned.portraits,
    layoutMarker,
    { iconPages = planned.iconPages, portraitPages = planned.portraitPages },
    "deterministic-build"
  )
  local iconMarkers, portraitMarkers = {}, {}
  for _, pageId in ipairs(planned.icons.pageIds) do
    local marker = MonCacheWriter.pageMarker(romSha1, "icons", pageId, planned.icons)
    iconMarkers[pageId + 1] = marker
    local compiled = assert(MonPresentationCompiler.compilePage(romFs, "icons", planned.iconPages[pageId]))
    -- compilePage returns pixels without a marker; the written bundle pairs
    -- the compiled page with its marker explicitly.
    MonCacheWriter.writePage(cache, {
      kind = "icons",
      pageId = compiled.pageId,
      width = compiled.width,
      height = compiled.height,
      pixels = compiled.pixels,
      marker = marker,
    })
  end
  for _, pageId in ipairs(planned.portraits.pageIds) do
    local marker = MonCacheWriter.pageMarker(romSha1, "portraits", pageId, planned.portraits)
    portraitMarkers[pageId + 1] = marker
    local compiled = assert(MonPresentationCompiler.compilePage(romFs, "portraits", planned.portraitPages[pageId]))
    MonCacheWriter.writePage(cache, {
      kind = "portraits",
      pageId = compiled.pageId,
      width = compiled.width,
      height = compiled.height,
      pixels = compiled.pixels,
      marker = marker,
    })
  end
  local index = MonCacheWriter.buildIndex(catalog.version, Hashing.hashLua(catalog), iconMarkers, portraitMarkers)
  local summaryMarker = MonCacheWriter.summaryMarker(index)
  MonCacheWriter.writeSummary(cache, index, {
    schema = "g4-mon-provenance-v1",
    source = MonSources.provenance,
    rom = { version = versionId, sha1 = romSha1 },
  })
  return summaryMarker
end

-- Two full builds into isolated backends agree on the summary marker, on
-- every sorted relative path and byte, for both Lua resources and page
-- PNGs; the ready/index hash is stable without reserializing image bytes.
function T.identical_inputs_produce_byte_identical_class_output(romFs, versionId)
  local firstBackend = FakeCache.new()
  local secondBackend = FakeCache.new()
  local firstMarker = buildClass(romFs, versionId, firstBackend)
  local secondMarker = buildClass(romFs, versionId, secondBackend)
  Assert.equal(firstMarker, secondMarker, "ready marker must be stable")

  local firstKeys = sortedKeys(firstBackend.files)
  local secondKeys = sortedKeys(secondBackend.files)
  Assert.deepEqual(firstKeys, secondKeys, "both builds must emit the same relative paths")
  Assert.isTrue(#firstKeys > 0, "a build must emit class output")
  for _, key in ipairs(firstKeys) do
    Assert.equal(secondBackend.files[key], firstBackend.files[key], "byte-identical output at " .. key)
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.slow = true
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "mon", "catalog", "determinism" }
return suite
