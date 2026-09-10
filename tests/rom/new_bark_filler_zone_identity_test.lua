-- ROM conformance for physical vs logical identity at New Bark: the
-- north/south EVERYWHERE filler cells keep raw header 0 with real drawable
-- terrain, while the New Bark logical zone remains the behavior owner over
-- those coordinates -- no logical lookup for map 0 and no zone side effect.

local Assert = require("tests.support.Assert")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldZoneController = require("libs.hgss.src.world.FieldZoneController")

local T = {}

local NEW_BARK_MAP_ID = 60
local EVERYWHERE_HEADER = 0

function T.everywhere_filler_cells_keep_raw_header_zero_with_new_bark_as_logical_owner(romFs, versionId)
  local r = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  local cache = CacheFs.forVersion(versionId)
  local index = FieldCellCache.loadIndex(cache)

  -- Raw physical provenance for both filler neighbors, with real terrain.
  for _, dz in ipairs({ -1, 1 }) do
    local x, z = r.matrixX, r.matrixZ + dz
    local label = string.format("EVERYWHERE cell (%d,%d)", x, z)
    local source = r.matrix:cell(x, z)
    Assert.equal(source.mapHeaderId, EVERYWHERE_HEADER, label .. " is filler in the decoded matrix")
    local descriptor =
      assert(FieldCellCache.find(index, r.matrixMemberId, x, z), label .. " is published as a physical cell")
    Assert.equal(descriptor.mapHeaderId, EVERYWHERE_HEADER, label .. " preserves raw header 0")
    local cell = assert(cache:loadLua(descriptor.file), label .. " cell loads")
    Assert.isTrue(#cell.batches > 0, label .. " draws real terrain")
  end

  -- Committed headless coverage over the same coordinates.
  local coverage = FieldCoverage.new({
    cacheFs = cache,
    index = index,
    matrixMemberId = r.matrixMemberId,
    anchorX = r.matrixX,
    anchorZ = r.matrixZ,
  })
  local loader
  local ok, err = pcall(function()
    Assert.equal(
      coverage:mapHeaderAt(r.matrixX * 32 + 1, (r.matrixZ - 1) * 32 + 1),
      EVERYWHERE_HEADER,
      "committed north filler keeps raw header 0"
    )
    Assert.equal(
      coverage:mapHeaderAt(r.matrixX * 32 + 1, (r.matrixZ + 1) * 32 + 1),
      EVERYWHERE_HEADER,
      "committed south filler keeps raw header 0"
    )

    -- Logical behavior owner over a north-filler coordinate.
    local world = assert(cache:loadLua(MapAssetCache.worldPath()))
    loader = FieldMapLoader.new(cache, world)
    local newBark = loader:load(NEW_BARK_MAP_ID)
    local calls = { lookups = {} }
    local zoneController = FieldZoneController.new({
      currentMap = newBark,
      mapForId = function(mapId)
        calls.lookups[#calls.lookups + 1] = mapId
        error("logical lookup for map " .. tostring(mapId) .. " is not part of filler behavior", 0)
      end,
      rebindScripts = function(map)
        calls[#calls + 1] = "scripts:" .. map.mapId
      end,
      applyWeather = function(map)
        calls[#calls + 1] = "weather:" .. map.mapId
      end,
      enterAudio = function(map)
        calls[#calls + 1] = "audio:" .. map.mapId
      end,
      onChange = function(change)
        calls[#calls + 1] = "change:" .. change.newMapId
      end,
    })
    local player = { fieldX = r.worldOriginX + 16, fieldZ = r.worldOriginZ - 16 }
    local zoneCoverage = coverage --[[@as FieldZoneCoverage]]
    local change = zoneController:afterCoverageCommit(zoneCoverage, player)
    Assert.isNil(change, "filler coordinates publish no zone change")
    Assert.equal(zoneController.currentMap, newBark, "New Bark remains the logical behavior owner")
    Assert.deepEqual(calls.lookups, {}, "no logical load for map 0 occurs")
    Assert.deepEqual(calls, { lookups = {} }, "no zone side effect fires for filler coordinates")
  end)
  coverage:release()
  if loader then
    loader:release()
  end
  if not ok then
    error(err, 0)
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
