-- ROM-gated follower visual resolution: the production catalog's follower
-- descriptors for representative species (starters, a gendered species)
-- resolve to visuals present in the compiled field-actor bundle, so the
-- controller installs real follower presentation rather than a placeholder.
-- The starter entries additionally prove follower capability, not just
-- presence: each must be a directional atlas whose cardinal idle and walk
-- clips select resident frames through the production pose lookup, so a
-- follower can visibly face and walk instead of holding one static frame.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local FollowingMonVisualCompiler = require("romdump.src.digest.actor.FollowingMonVisualCompiler")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local CARDINAL_DIRECTIONS = { "north", "south", "west", "east" }
local LOCOMOTION_POSES = { "idle", "walk" }

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
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
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

T["starter follower visuals are directional atlases with cardinal idle and walk poses"] = function(romFs, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  local compiled = assert(FollowingMonVisualCompiler.compile(romFs))
  for _, species in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
    local descriptor =
      assert(catalog:followerSelection({ species = species, form = 0 }), species .. " carries a follower descriptor")
    local visual = assert(
      compiled.visuals[descriptor.visualId],
      species .. " follower visual " .. descriptor.visualId .. " is compiled by the follower producer"
    )
    Assert.equal(
      visual.render.kind,
      "atlas",
      species .. " follower presents as a directional atlas, never a static model"
    )
    Assert.isTrue(
      FieldActorCache.isValidVisual(visual, descriptor.visualId),
      species .. " follower visual stays structurally valid"
    )
    Assert.isTrue(visual.render.frameCount > 1, species .. " follower atlas carries more than one frame")
    local observedFrames = {}
    for _, direction in ipairs(CARDINAL_DIRECTIONS) do
      for _, poseName in ipairs(LOCOMOTION_POSES) do
        local pose, fellBack = FieldActorPose.select(visual, direction, poseName)
        Assert.isFalse(
          fellBack,
          species .. " " .. direction .. " " .. poseName .. " is a compiled clip, never an idle substitution"
        )
        for tick = 0, pose.durationTicks - 1 do
          local frameIndex = FieldActorPose.frameIndexAt(pose, tick)
          Assert.isTrue(
            frameIndex >= 1 and frameIndex <= visual.render.frameCount,
            species .. " " .. direction .. " " .. poseName .. " selects a resident atlas frame"
          )
          observedFrames[frameIndex] = true
        end
      end
      local walk = FieldActorPose.select(visual, direction, "walk")
      Assert.isTrue(walk.durationTicks > 1, species .. " " .. direction .. " walk animates across ticks")
    end
    local distinct = 0
    for _ in pairs(observedFrames) do
      distinct = distinct + 1
    end
    Assert.isTrue(
      distinct > 1,
      species
        .. " follower varies atlas frames across facing and locomotion instead of aliasing every pose to one static frame"
    )
  end
end

return RomSuite.fromFacts(T)
