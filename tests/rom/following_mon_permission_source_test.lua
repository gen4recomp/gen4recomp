-- Source inputs for follower map/species permission: the tower floors
-- resolve in the generated world with valid map modes (most of them
-- allow, so the burrower exception below does real work), and the
-- production catalog carries integer follower sizes for the burrowers
-- plus at least one nonzero-size follower, which is what makes height
-- restriction reachable with real data.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local TOWER_FLOORS = {
  "MAP_BELL_TOWER_1F",
  "MAP_BELL_TOWER_2F",
  "MAP_BELL_TOWER_3F",
  "MAP_BELL_TOWER_4F",
  "MAP_BELL_TOWER_5F",
  "MAP_BELL_TOWER_6F",
  "MAP_BELL_TOWER_7F",
  "MAP_BELL_TOWER_8F",
  "MAP_BELL_TOWER_9F",
  "MAP_BELL_TOWER_ROOF",
  "MAP_BELL_TOWER_10F",
}

local VALID_MODES = { ALLOW = true, HEIGHT_RESTRICT = true, PREVENT = true }

function T.tower_floors_resolve_with_valid_map_modes(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()), "the generated world manifest must load")
  local allowed = 0
  for _, symbol in ipairs(TOWER_FLOORS) do
    local mapId = assert(world.bySymbol[symbol], symbol .. " must resolve in the generated world")
    local entry = assert(world.maps[assert(world.byId[mapId])], symbol .. " must carry a world entry")
    Assert.equal(entry.symbol, symbol, "the world entry keeps its source symbol")
    Assert.isTrue(VALID_MODES[entry.followMode] == true, symbol .. " must carry a source map mode")
    if entry.followMode == "ALLOW" then
      allowed = allowed + 1
    end
  end
  Assert.isTrue(allowed >= 1, "an allowed tower floor must exist so the species exception does real work")
end

function T.burrower_and_large_followers_carry_usable_size_facts(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  for _, species in ipairs({ "DIGLETT", "DUGTRIO" }) do
    local descriptor =
      assert(catalog:followerSelection({ species = species, form = 0 }), species .. " must carry a follower descriptor")
    Assert.isTrue(type(descriptor.size) == "number", species .. " must carry an integer follower size")
    Assert.isTrue(descriptor.size % 1 == 0, species .. " follower size must be integral")
  end
  local root = MonCache.loadCatalog(cacheFs)
  local nonzero = nil
  for key, species in pairs(root.species) do
    for _, form in pairs(species.forms or {}) do
      if form.follower ~= nil and type(form.follower.size) == "number" and form.follower.size >= 1 then
        nonzero = key
        break
      end
    end
    if nonzero ~= nil then
      break
    end
  end
  Assert.notNil(nonzero, "a nonzero-size follower must exist so height restriction denies real leads")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
