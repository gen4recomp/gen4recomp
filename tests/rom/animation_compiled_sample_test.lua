-- Bounded compiled-animation sample: two explicitly named retail maps are
-- compiled through the production map compiler and every animated model
-- descriptor they emit must carry a table `compiled` payload on each clip.
-- New Bark town exercises the outdoor animated door descriptors; Elm's Lab
-- first floor exercises an indoor compiled-map path. This is the fast
-- analogue of the whole-cache clip census, not corpus evidence: it asserts
-- nothing about maps outside the sample.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")

local T = {}

-- Explicit sample with a rationale per map; literal data, never discovered.
local SAMPLE_MAPS = {
  { symbol = "MAP_NEW_BARK", reason = "outdoor animated town door descriptors" },
  { symbol = "MAP_NEW_BARK_ELMS_LAB_1F", reason = "indoor compiled-map path" },
}

function T.named_maps_emit_clips_with_compiled_payloads(romFs)
  local animatedDescriptors = 0
  local clipCount = 0
  for _, sample in ipairs(SAMPLE_MAPS) do
    local assets = assert(
      MapAssetCompiler.compile(romFs, sample.symbol),
      sample.symbol .. " (" .. sample.reason .. ") compiles through the production compiler"
    )
    Assert.notNil(assets.models, sample.symbol .. " bundle carries its model descriptors")
    local animatedHere = 0
    for modelKey, desc in pairs(assets.models) do
      if type(desc.animations) == "table" then
        animatedHere = animatedHere + 1
        for _, clip in ipairs(desc.animations) do
          Assert.equal(
            type(clip.compiled),
            "table",
            sample.symbol .. ": clip " .. tostring(clip.id) .. " of " .. modelKey .. " carries a compiled payload"
          )
          clipCount = clipCount + 1
        end
      end
    end
    Assert.isTrue(animatedHere > 0, sample.symbol .. " (" .. sample.reason .. ") emits animated descriptors")
    animatedDescriptors = animatedDescriptors + animatedHere
  end
  Assert.isTrue(animatedDescriptors > 0, "the sample reached animated model descriptors")
  Assert.isTrue(clipCount > 0, "the sample counted emitted clips")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
