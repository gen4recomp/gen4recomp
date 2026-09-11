-- ROM-gated follower visual resolution: the production catalog's follower
-- descriptors for representative species (starters, a gendered species)
-- resolve to visuals present in the compiled field-actor bundle, so the
-- controller installs real follower presentation rather than a placeholder.
-- Reads only the prebuilt cache indexes, never the all-follower producer;
-- the producer-backed starter-pose checks live in the slow sibling.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local MonBucket = require("tests.support.MonBucket")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function bundleSprites(cacheFs)
  local index = assert(cacheFs:loadLua(FieldActorCache.indexPath()), "field actor index is required")
  local known = {}
  for _, spriteId in ipairs(assert(index.spriteIds, "field actor index carries its sprite set")) do
    known[spriteId] = true
  end
  return known
end

T["starter and gendered follower visuals resolve to compiled actor visuals"] = function(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonBucket.openCatalogs(versionId)
  local known = bundleSprites(cacheFs)
  local representatives = { "CHIKORITA", "CYNDAQUIL", "TOTODILE", "PIKACHU" }
  for _, species in ipairs(representatives) do
    local descriptor =
      assert(catalog:followerSelection({ species = species, form = 0 }), species .. " carries a follower descriptor")
    Assert.isTrue(
      type(descriptor.visualId) == "number" and descriptor.visualId > 0,
      species .. " descriptor carries a visual id"
    )
    Assert.isTrue(
      known[descriptor.visualId] == true,
      species .. " visual " .. descriptor.visualId .. " is a compiled actor visual, not a placeholder"
    )
    local female = descriptor.female
    if female ~= nil then
      Assert.isTrue(
        known[female.visualId] == true,
        species .. " female visual " .. female.visualId .. " is a compiled actor visual"
      )
    end
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "mon", "following-mon", "visual" }
return suite
