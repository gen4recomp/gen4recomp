-- ROM conformance: generated world records carry the source-exact map-section
-- identity and follow mode from the normalized map reference through analysis
-- into the runtime loader. Elm's lab pins the known section; a second header
-- sharing that section proves the section identity is never the header id.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local FOLLOW_MODES = { ALLOW = true, HEIGHT_RESTRICT = true, PREVENT = true }

-- The production analysis seam is the whole-ROM pass the cache builder
-- runs: per-record selection plus the reference copy into every result.
local analyzedByVersion = {}

local function fullAnalysis(romFs, versionId)
  if analyzedByVersion[versionId] == nil then
    analyzedByVersion[versionId] = assert(MapAnalysis.analyze(romFs))
  end
  return analyzedByVersion[versionId]
end

local function analysisFor(romFs, versionId, mapId)
  for _, result in ipairs(fullAnalysis(romFs, versionId)) do
    if result.id == mapId then
      return result
    end
  end
  error("map " .. mapId .. " is missing from map analysis", 0)
end

local function worldEntry(versionId, mapId)
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()), "the generated world manifest must load")
  local index = assert(world.byId[mapId], "map " .. mapId .. " must be in the generated world")
  return cacheFs, world, assert(world.maps[index])
end

local function assertElmLabTriple(section, nativeId, followMode, where)
  Assert.equal(section, "NEW_BARK_TOWN", where .. " must keep the semantic Elm lab section")
  Assert.notNil(nativeId, where .. " must carry the exact native map-section identity")
  Assert.equal(nativeId, 126, where .. " must resolve New Bark Town to native section 126")
  Assert.equal(followMode, "HEIGHT_RESTRICT", where .. " must carry the source Elm lab follow mode")
end

function T.elm_lab_world_record_carries_source_exact_section_identity(romFs, versionId)
  local reference = MapCatalog.require(61)
  assertElmLabTriple(reference.mapSection, reference.mapSectionNativeId, reference.followMode, "the map reference")

  local analysis = analysisFor(romFs, versionId, 61)
  Assert.equal(analysis.status, "resolved", "Elm's lab must resolve a matrix cell")
  assertElmLabTriple(analysis.mapSection, analysis.mapSectionNativeId, analysis.followMode, "map analysis")

  local cacheFs, world, entry = worldEntry(versionId, 61)
  Assert.equal(entry.symbol, "MAP_NEW_BARK_ELMS_LAB_1F")
  assertElmLabTriple(entry.mapSection, entry.mapSectionNativeId, entry.followMode, "the generated world entry")

  local loader = FieldMapLoader.new(cacheFs, world)
  local runtimeMap = loader:load(61)
  assertElmLabTriple(
    runtimeMap.mapSection,
    runtimeMap.mapSectionNativeId,
    runtimeMap.followMode,
    "the runtime field map"
  )
  Assert.equal(runtimeMap.mapId, 61)
  Assert.equal(runtimeMap.mapSymbol, "MAP_NEW_BARK_ELMS_LAB_1F")
  loader:release()
end

function T.section_identity_is_never_the_header_id(romFs, versionId)
  -- The producer path carries the same triple for the outdoor town header,
  -- which shares Elm lab's section under a different header id.
  local townAnalysis = analysisFor(romFs, versionId, 60)
  Assert.equal(townAnalysis.status, "resolved", "New Bark Town must resolve a matrix cell")
  Assert.equal(townAnalysis.mapSection, "NEW_BARK_TOWN")
  Assert.notNil(townAnalysis.mapSectionNativeId, "town analysis must carry the native section identity")
  Assert.equal(townAnalysis.mapSectionNativeId, 126)
  Assert.equal(townAnalysis.followMode, "ALLOW", "the outdoor town must allow followers")

  local newBark = MapCatalog.require(60)
  local lab = MapCatalog.require(61)
  Assert.equal(newBark.mapSection, lab.mapSection, "both headers share the New Bark Town section")
  Assert.equal(newBark.mapSectionNativeId, 126, "New Bark Town keeps one native section identity")
  Assert.equal(lab.mapSectionNativeId, 126, "Elm's lab keeps the same native section identity")
  Assert.isTrue(newBark.mapSectionNativeId ~= newBark.id, "the town section identity is not the town header id")
  Assert.isTrue(lab.mapSectionNativeId ~= lab.id, "the lab section identity is not the lab header id")

  local _, world, _ = worldEntry(versionId, 61)
  local seenModes = {}
  local aliased = 0
  for _, entry in ipairs(world.maps) do
    Assert.isTrue(
      type(entry.mapSection) == "string" and entry.mapSection ~= "",
      "map " .. tostring(entry.id) .. " must carry its semantic section"
    )
    Assert.isTrue(
      type(entry.mapSectionNativeId) == "number" and entry.mapSectionNativeId % 1 == 0 and entry.mapSectionNativeId >= 0,
      "map " .. tostring(entry.id) .. " must carry an exact native map-section identity"
    )
    Assert.isTrue(
      FOLLOW_MODES[entry.followMode] == true,
      "map " .. tostring(entry.id) .. " must carry a source follow mode"
    )
    seenModes[entry.followMode] = true
    if entry.mapSectionNativeId ~= entry.id then
      aliased = aliased + 1
    end
  end
  Assert.isTrue(aliased >= 1, "header and section identities must differ somewhere in the world")
  Assert.isTrue(seenModes.ALLOW, "an ALLOW map must reach the generated world")
  Assert.isTrue(seenModes.HEIGHT_RESTRICT, "a HEIGHT_RESTRICT map must reach the generated world")
  Assert.isTrue(seenModes.PREVENT, "a PREVENT map must reach the generated world")
  local preventEntry = assert(world.maps[assert(world.byId[198])])
  Assert.equal(preventEntry.followMode, "PREVENT", "the Goldenrod station upper floor must prevent followers")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
