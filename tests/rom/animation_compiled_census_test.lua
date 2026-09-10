-- ROM-conformance census behind the clip contract: the engine requires a
-- `compiled` payload on every clip (AnimationClip.new and
-- ModelDefinition.validateAnimations), so the requirement must be
-- corpus-safe -- every animated descriptor the real pipeline emits must
-- carry one. The census walks the derived cache through its production
-- linkage (world manifest -> per-map scene -> building instance -> model
-- descriptor -> animations), the exact path the game loads, and asserts
-- shape, never payload contents. Read-only; green today because the
-- corpus is clean, and it pins that the contract cannot break real data.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = {
    slow = true,
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "census", "animation" },
  },
  tests = {},
}

local handles = nil

function T.beforeAll()
  local opened = {}
  handles = opened
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      opened[#opened + 1] = { versionId = versionId, cache = CacheFs.forVersion(versionId) }
    end
  end
  if #opened == 0 then
    error("no ready game dump to census", 0)
  end
end

function T.afterAll()
  handles = nil
end

-- One pass over the whole corpus; every postcondition is asserted against the
-- same walk (world -> scene -> descriptor), so the expensive per-map loads
-- happen once.
function T.tests.every_emitted_clip_carries_a_compiled_payload()
  for _, handle in ipairs(assert(handles, "the census suite has no open cache")) do
    local cache = handle.cache
    local world = assert(cache:loadLua(MapAssetCache.worldPath()), "derived cache world manifest is loadable")
    local maps = world.maps
    assert(type(maps) == "table", "world manifest carries the map list")

    local seenModels = {}
    local mapCount = 0
    local animatedDescriptors = 0
    local clipCount = 0
    for _, entry in ipairs(maps) do
      local dir = MapAssetCache.mapDir(entry.id)
      if cache:exists(dir .. "/complete") then
        mapCount = mapCount + 1
        local scene = assert(cache:loadLua(dir .. "/scene.lua"), "scene " .. entry.id .. " is loadable")
        for _, inst in ipairs(scene.buildingInstances) do
          if type(inst.modelKey) ~= "string" then
            error("scene " .. entry.id .. " carries a building instance without a modelKey", 0)
          end
          if not seenModels[inst.modelKey] then
            seenModels[inst.modelKey] = true
            local desc = assert(
              cache:loadLua(MapAssetCache.modelPath(inst.modelKey)),
              "descriptor " .. inst.modelKey .. " is loadable"
            )
            if type(desc.animations) == "table" then
              animatedDescriptors = animatedDescriptors + 1
              for _, clip in ipairs(desc.animations) do
                Assert.equal(
                  type(clip.compiled),
                  "table",
                  "clip " .. tostring(clip.id) .. " of descriptor " .. inst.modelKey .. " carries a compiled payload"
                )
                clipCount = clipCount + 1
              end
            end
          end
        end
      end
    end

    -- Coverage: the census reached the whole manifest and met real animated
    -- data; a walk that saw nothing asserts nothing.
    Assert.equal(mapCount, #maps, handle.versionId .. ": every catalog map is ready")
    Assert.isTrue(mapCount > 0, handle.versionId .. ": the census reached ready maps")
    Assert.isTrue(animatedDescriptors > 0, handle.versionId .. ": the census reached animated model descriptors")
    Assert.isTrue(clipCount > 0, handle.versionId .. ": the census counted emitted clips")
  end
end

return T
